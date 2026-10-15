import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor SyncedChatSendGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var opened = false
  private(set) var started = false

  func wait() async {
    started = true
    if opened { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    opened = true
    continuation?.resume()
    continuation = nil
  }
}

final class SyncedAIChatTranscriptTests: XCTestCase {
  /// Manifests written before placeholders stored their latest reply ID load
  /// settled threads without messages. Their thread summaries must still
  /// report the reply, or an iPhone announces it as new once it is loaded.
  func testLegacyPlaceholderLoadsWithItsLatestReplyIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("server.json")
    let reply = AIChatMessage(role: .assistant, content: "Milk, eggs, and bread.")
    let groceries = AIChatThread(
      title: "Groceries today",
      sessionKey: "groceries",
      messages: [AIChatMessage(role: .user, content: "What do I need?"), reply],
      isArchived: true
    )
    let unanswered = AIChatThread(
      title: "Unanswered",
      sessionKey: "unanswered",
      messages: [AIChatMessage(role: .user, content: "Hello?")],
      isArchived: true
    )
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [groceries, unanswered],
      selectedThreadID: nil,
      settlementSettings: AIChatThreadSettlementSettings()
    ), legacyURL: url)
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()

    // Rewrite the placeholder the way pre-0.8.7 writers left it: a message
    // count and no latest reply ID.
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [groceries.metadataOnly(latestAssistantMessageID: nil), unanswered.metadataOnly()],
      selectedThreadID: nil,
      settlementSettings: AIChatThreadSettlementSettings()
    ), legacyURL: url)
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let manifests = try FileManager.default.contentsOfDirectory(
      at: AIChatTranscriptStore.storeDirectory(for: url).appendingPathComponent("manifests"),
      includingPropertiesForKeys: nil
    ).map { try String(contentsOf: $0, encoding: .utf8) }
    XCTAssertTrue(manifests.contains { !$0.contains(reply.id.uuidString) })

    let loaded = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: url))
    let placeholder = try XCTUnwrap(loaded.snapshot.threads.first(where: { $0.id == groceries.id }))
    XCTAssertTrue(placeholder.messages.isEmpty)
    XCTAssertTrue(loaded.unloadedThreadIDs.contains(groceries.id))
    let context = MobileRemoteThreadProjectionContext(destinationNamesByID: [:], runningThreadIDs: [])
    XCTAssertEqual(
      MobileRemoteThreadProjection.summary(thread: placeholder, context: context).latestAssistantMessageID,
      reply.id
    )
    XCTAssertEqual(placeholder.metadataOnly().storedLatestAssistantMessageID, reply.id)
    let unansweredPlaceholder = try XCTUnwrap(loaded.snapshot.threads.first(where: { $0.id == unanswered.id }))
    XCTAssertNil(unansweredPlaceholder.latestAssistantMessageID)
    XCTAssertEqual(unansweredPlaceholder.storedMessageCount, 1)
  }

  func testValidMarkerReconcilesDivergentImmutableSyncthingBranches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    let shared = AIChatThread(title: "Shared", sessionKey: "shared")
    let laptop = AIChatThread(
      title: "Laptop chat",
      sessionKey: "laptop",
      messages: [AIChatMessage(role: .assistant, content: "From the laptop")]
    )
    let server = AIChatThread(
      title: "Server chat",
      sessionKey: "server",
      messages: [AIChatMessage(role: .assistant, content: "From the server")]
    )
    let settings = AIChatThreadSettlementSettings()

    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [shared, laptop], selectedThreadID: laptop.id, settlementSettings: settings
    ), legacyURL: laptopURL)
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [shared, server], selectedThreadID: server.id, settlementSettings: settings
    ), legacyURL: serverURL)
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()

    let laptopStore = AIChatTranscriptStore.storeDirectory(for: laptopURL)
    let serverStore = AIChatTranscriptStore.storeDirectory(for: serverURL)
    try copyImmutableDirectory(
      from: serverStore.appendingPathComponent("threads", isDirectory: true),
      to: laptopStore.appendingPathComponent("threads", isDirectory: true)
    )
    try copyImmutableDirectory(
      from: serverStore.appendingPathComponent("manifests", isDirectory: true),
      to: laptopStore.appendingPathComponent("manifests", isDirectory: true)
    )

    // The decode counters are debug-only probes. Release-mode CI still runs
    // the reconciliation path but must not reference symbols omitted there.
    #if DEBUG
    AIChatTranscriptStore.resetThreadShardDecodeCountForTesting()
    #endif
    let loaded = try XCTUnwrap(
      AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: laptopURL)
    )
    XCTAssertEqual(Set(loaded.snapshot.threads.map(\.id)), [shared.id, laptop.id, server.id])
    XCTAssertEqual(
      loaded.snapshot.threads.first(where: { $0.id == server.id })?.messages.first?.content,
      "From the server"
    )
    #if DEBUG
    XCTAssertLessThanOrEqual(
      AIChatTranscriptStore.threadShardDecodeCountForTesting(),
      6,
      "Divergent manifests should validate each thread revision at most once"
    )
    #endif

    // Persisting the reconciled snapshot records every immutable branch that
    // it subsumes. Routine follow-up loads must not reopen all of those large
    // versioned manifests (and then decode every shard) forever.
    try AIChatTranscriptStore.shared.flush(loaded.snapshot, legacyURL: laptopURL)
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    #if DEBUG
    AIChatTranscriptStore.resetRecoveryCandidateDecodeCountForTesting()
    #endif
    XCTAssertNotNil(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: laptopURL))
    #if DEBUG
    XCTAssertLessThanOrEqual(
      AIChatTranscriptStore.recoveryCandidateDecodeCountForTesting(),
      2,
      "A converged store should inspect only its two mutable manifest views"
    )
    #endif
  }

  /// Mobile Remote reconciles before every thread request. With unchanged
  /// storage that must not re-decode manifests or drop hydrated threads, but
  /// any new commit must still be imported on the next request.
  @MainActor
  func testSyncedRefreshSkipsUnchangedStorageAndImportsTheNextCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("chat.json")
    let question = AIChatMessage(role: .user, content: "What is next?")
    let thread = AIChatThread(title: "Planning", runtime: .codex, sessionKey: "planning")
      .replacingMessages([question])
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [thread],
      selectedThreadID: thread.id,
      settlementSettings: AIChatThreadSettlementSettings()
    ), legacyURL: transcriptURL)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL
    )
    await store.waitForAIChatTranscriptLoadForTesting()

    let firstRefresh = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(firstRefresh)
    XCTAssertEqual(store.syncedAIChatRefreshSkipCountForTesting, 0)
    let secondRefresh = await store.refreshSyncedAIChatTranscript()
    let thirdRefresh = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(secondRefresh)
    XCTAssertTrue(thirdRefresh)
    XCTAssertEqual(
      store.syncedAIChatRefreshSkipCountForTesting,
      2,
      "Unchanged committed storage must not be reloaded on every request"
    )
    let unchanged = await store.hydratedAIChatThreadForDetail(thread.id)
    XCTAssertEqual(unchanged?.messages.map(\.id), [question.id])

    let reply = AIChatMessage(role: .assistant, content: "Ship the fix.")
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [thread.replacingMessages([question, reply])],
      selectedThreadID: thread.id,
      settlementSettings: AIChatThreadSettlementSettings()
    ), legacyURL: transcriptURL)
    let changedRefresh = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(changedRefresh)
    XCTAssertEqual(store.syncedAIChatRefreshSkipCountForTesting, 2, "A new commit must be read")
    let updated = await store.hydratedAIChatThreadForDetail(thread.id)
    XCTAssertEqual(updated?.messages.map(\.id), [question.id, reply.id])
  }

  /// A remote commit that changes one thread re-imports only that thread.
  /// Untouched threads keep their in-memory copy instead of being replaced.
  @MainActor
  func testSyncedRefreshKeepsThreadsWhoseCommittedSourceIsUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("chat.json")
    let quietQuestion = AIChatMessage(role: .user, content: "Quiet thread")
    let quiet = AIChatThread(title: "Quiet", runtime: .codex, sessionKey: "quiet")
      .replacingMessages([quietQuestion])
    let busyQuestion = AIChatMessage(role: .user, content: "Busy thread")
    let busy = AIChatThread(title: "Busy", runtime: .codex, sessionKey: "busy")
      .replacingMessages([busyQuestion])
    func commit(_ threads: [AIChatThread]) throws {
      try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: busy.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ), legacyURL: transcriptURL)
      AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    }
    try commit([quiet, busy])

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    _ = await store.refreshSyncedAIChatTranscript()

    let firstReply = AIChatMessage(role: .assistant, content: "Streaming 1")
    try commit([quiet, busy.replacingMessages([busyQuestion, firstReply])])
    _ = await store.refreshSyncedAIChatTranscript()
    let secondReply = AIChatMessage(role: .assistant, content: "Streaming 2")
    try commit([quiet, busy.replacingMessages([busyQuestion, firstReply, secondReply])])
    _ = await store.refreshSyncedAIChatTranscript()
    XCTAssertEqual(store.syncedAIChatRefreshKeptCountForTesting, 1, "The unchanged thread is kept")

    let updatedBusy = await store.hydratedAIChatThreadForDetail(busy.id)
    XCTAssertEqual(updatedBusy?.messages.map(\.id), [busyQuestion.id, firstReply.id, secondReply.id])
    let keptQuiet = await store.hydratedAIChatThreadForDetail(quiet.id)
    XCTAssertEqual(keptQuiet?.messages.map(\.id), [quietQuestion.id])

    // A metadata-only change (title) to the kept thread is still imported.
    try commit([
      AIChatThread(id: quiet.id, title: "Renamed", runtime: .codex, sessionKey: "quiet")
        .replacingMessages([quietQuestion]),
      busy.replacingMessages([busyQuestion, firstReply, secondReply]),
    ])
    _ = await store.refreshSyncedAIChatTranscript()
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == quiet.id })?.title, "Renamed")
  }

  func testSyncedRefreshSkipRequiresTheSameStorageAndStillProtectedThreads() {
    let held = UUID()
    let state = SyncedAIChatAppliedState(
      transcriptPath: "/corpus/.org2/chat.json",
      transcriptGeneration: 3,
      fingerprint: "abc",
      protectedThreadIDs: [held]
    )
    XCTAssertTrue(state.allowsSkipping(
      transcriptPath: "/corpus/.org2/chat.json", transcriptGeneration: 3,
      fingerprint: "abc", protectedThreadIDs: [held, UUID()]
    ))
    XCTAssertFalse(state.allowsSkipping(
      transcriptPath: "/corpus/.org2/chat.json", transcriptGeneration: 3,
      fingerprint: "abd", protectedThreadIDs: [held]
    ), "A new commit changes the fingerprint")
    XCTAssertFalse(state.allowsSkipping(
      transcriptPath: "/corpus/.org2/chat.json", transcriptGeneration: 3,
      fingerprint: nil, protectedThreadIDs: [held]
    ), "Unreadable storage always reloads")
    XCTAssertFalse(state.allowsSkipping(
      transcriptPath: "/corpus/.org2/chat.json", transcriptGeneration: 4,
      fingerprint: "abc", protectedThreadIDs: [held]
    ), "A full transcript reload invalidates the skip")
    XCTAssertFalse(state.allowsSkipping(
      transcriptPath: "/corpus/.org2/chat.json", transcriptGeneration: 3,
      fingerprint: "abc", protectedThreadIDs: []
    ), "A thread that lost local protection must import the replica it skipped")
  }

  @MainActor
  func testPersistedSendingTurnShowsRunningOnAnotherHostButFollowUpStaysQueued() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("chat.json")
    let activeMessage = AIChatMessage(
      role: .user,
      content: "Started from iPhone",
      deliveryStatus: .sending,
      deliveryKind: .turn
    )
    let queuedMessage = AIChatMessage(
      role: .user,
      content: "Do this next",
      deliveryStatus: .sending,
      deliveryKind: .followUp
    )
    let active = AIChatThread(
      title: "Remote active turn",
      runtime: .codex,
      sessionKey: "remote-active"
    )
    let queuedOnly = AIChatThread(
      title: "Queued only",
      runtime: .codex,
      sessionKey: "remote-queued"
    )
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [active, queuedOnly],
      selectedThreadID: active.id,
      settlementSettings: AIChatThreadSettlementSettings()
    ), legacyURL: transcriptURL)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL
    )
    await store.waitForAIChatTranscriptLoadForTesting()

    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [
        active.replacingMessages([activeMessage, queuedMessage]),
        queuedOnly.replacingMessages([queuedMessage])
      ],
      selectedThreadID: active.id,
      settlementSettings: AIChatThreadSettlementSettings()
    ), legacyURL: transcriptURL)
    let refreshed = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshed)

    XCTAssertTrue(store.isAIChatThreadRunning(active.id))
    XCTAssertFalse(
      store.isAIChatThreadRunningOnCurrentHost(active.id),
      "A synced sending marker is not live work owned by this host"
    )
    XCTAssertFalse(store.isAIChatThreadRunning(queuedOnly.id))
    XCTAssertFalse(store.isAIChatThreadRunningOnCurrentHost(queuedOnly.id))
    XCTAssertFalse(
      store.isAIChatMessageQueued(activeMessage.id),
      "The active turn imported from another host must not be labeled as queued"
    )
    XCTAssertTrue(
      store.isAIChatMessageQueued(queuedMessage.id),
      "An explicit follow-up must remain queued behind the active remote turn"
    )
    XCTAssertFalse(store.canChangeChatAgent)
  }

  @MainActor
  func testReadBadgesStayClearedAcrossRefreshAndRestartWithoutHidingNewReplies() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let localURL = root.appendingPathComponent("local.json")
    let remoteURL = root.appendingPathComponent("remote.json")
    let otherURL = root.appendingPathComponent("other.json")
    let readAt = Date(timeIntervalSince1970: 1_000)
    let selected = AIChatThread(title: "Selected", sessionKey: "selected")
    let unread = AIChatThread(
      title: "Background", updatedAt: readAt, sessionKey: "background",
      messages: [AIChatMessage(role: .assistant, content: "Already seen", createdAt: readAt)],
      unreadMessageCount: 1
    )
    let room = AIChatThread(
      title: "Shared room", updatedAt: readAt, sessionKey: "room",
      messages: [AIChatMessage(role: .assistant, content: "Room reply", createdAt: readAt)],
      unreadMessageCount: 1, isSharedRoom: true
    )
    let filler = (0..<20).map { AIChatThread(title: "Other \($0)", sessionKey: "other-\($0)") }
    let settings = AIChatThreadSettlementSettings()
    let snapshot = AIChatTranscriptSnapshot(
      threads: [selected] + filler + [unread, room], selectedThreadID: selected.id,
      settlementSettings: settings
    )
    try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: localURL)
    try AIChatTranscriptStore.shared.flush(snapshot, legacyURL: otherURL)
    let suite = "synced-chat-read-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults,
      aiChatTranscriptURL: localURL
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    XCTAssertNotNil(store.aiChatThreads.first { $0.id == unread.id }?.storedMessageCount)
    store.aiChatTranscriptPersistenceDelayNanoseconds = 60_000_000_000
    // Defer writes without simulating a corrupt store: a recovery-blocked
    // transcript intentionally reloads instead of taking the normal sync path.
    defer { store.flushDeferredAIChatTranscriptPersistence() }
    let before = try commitPointFingerprint(localURL)
    for thread in [unread, room] {
      store.selectAIChatThread(thread.id)
      await store.waitForAIChatThreadHydrationForTesting(thread.id)
    }
    store.selectAIChatThread(selected.id)
    XCTAssertEqual(store.aiChatUnreadMessageCount, 0)
    for _ in 0..<3 {
      let refreshed = await store.refreshSyncedAIChatTranscript()
      XCTAssertTrue(refreshed)
      XCTAssertEqual(store.aiChatUnreadMessageCount, 0, "App activation must not restore dismissed badges")
      XCTAssertTrue(store.sidebarAIChatThreadSummaries.allSatisfy { $0.unreadMessageCount == 0 })
    }
    XCTAssertEqual(try commitPointFingerprint(localURL), before, "Local read state must not rewrite synced history")

    let reopened = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults,
      aiChatTranscriptURL: localURL
    )
    await reopened.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(reopened.aiChatUnreadMessageCount, 0, "Read state must survive restarting OpenOrg")
    let otherCorpus = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults,
      aiChatTranscriptURL: otherURL
    )
    await otherCorpus.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(otherCorpus.aiChatUnreadMessageCount, 2, "Read state is scoped to its transcript")

    // A larger message count must remain unread even when timestamps are equal.
    let reply = AIChatMessage(role: .assistant, content: "A genuinely new reply", createdAt: readAt)
    let newer = unread.replacingMessages(unread.messages + [reply])
    // Also preserve a later revision with the same message count.
    let newerRoom = room.replacingMessages([
      AIChatMessage(role: .assistant, content: "A later room reply", createdAt: readAt.addingTimeInterval(1))
    ])
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [selected] + filler + [newer, newerRoom], selectedThreadID: selected.id,
      settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let refreshed = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(store.aiChatThreads.first { $0.id == unread.id }?.unreadMessageCount, 1)
    XCTAssertEqual(store.aiChatThreads.first { $0.id == room.id }?.unreadMessageCount, 1)
    XCTAssertEqual(store.aiChatUnreadMessageCount, 2)

    store.selectedSurface = .agenda
    let hiddenReply = selected.replacingMessages([
      AIChatMessage(role: .assistant, content: "Unread while viewing the agenda")
    ]).replacingAIChatMetadata(unreadMessageCount: 1)
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [hiddenReply] + filler + [newer, newerRoom], selectedThreadID: selected.id,
      settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let hiddenRefresh = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(hiddenRefresh)
    XCTAssertEqual(store.selectedAIChatThreadID, selected.id)
    XCTAssertEqual(store.selectedAIChatThread?.unreadMessageCount, 1,
                   "Refreshing a chat hidden behind another surface must not mark it read")
    store.makeSurfacePrimary(.aiChat)
    let visibleRefresh = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(visibleRefresh)
    XCTAssertEqual(store.selectedAIChatThread?.unreadMessageCount, 0)
  }

  /// Every writer's head plus the historical marker. A change means a commit.
  private func commitPointFingerprint(_ transcriptURL: URL) throws -> Data {
    let store = AIChatTranscriptStore.storeDirectory(for: transcriptURL)
    var data = Data()
    let heads = store.appendingPathComponent("heads", isDirectory: true)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: heads.path)) ?? []).sorted()
    for name in names {
      data.append(Data(name.utf8))
      data.append(try Data(contentsOf: heads.appendingPathComponent(name)))
    }
    if let marker = try? Data(contentsOf: store.appendingPathComponent("migration-marker.json")) {
      data.append(marker)
    }
    return data
  }

  private func replicate(_ source: URL, to target: URL) throws {
    // flush waits for the commit, but obsolete manifests are collected afterward.
    // Copy the fixture only after that cleanup has finished.
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let fm = FileManager.default
    let sourceStore = AIChatTranscriptStore.storeDirectory(for: source)
    let targetStore = AIChatTranscriptStore.storeDirectory(for: target)
    if fm.fileExists(atPath: targetStore.path) { try fm.removeItem(at: targetStore) }
    try fm.copyItem(at: sourceStore, to: targetStore)
  }

  private func copyImmutableDirectory(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    for sourceFile in try fileManager.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: nil
    ) {
      let destinationFile = destination.appendingPathComponent(sourceFile.lastPathComponent)
      if !fileManager.fileExists(atPath: destinationFile.path) {
        try fileManager.copyItem(at: sourceFile, to: destinationFile)
      }
    }
  }

  @MainActor
  func testSyncedThreadRefreshPreservesSelectionDraftAndDoesNotWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let localURL = root.appendingPathComponent("local.json")
    let remoteURL = root.appendingPathComponent("remote.json")
    let original = AIChatThread(title: "Local", sessionKey: "agent:main:local", messages: [])
    let incoming = AIChatThread(title: "Phone via server", sessionKey: "agent:main:server", messages: [
      AIChatMessage(role: .user, content: "From my phone"),
      AIChatMessage(role: .assistant, content: "From the server")
    ])
    let settings = AIChatThreadSettlementSettings()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original], selectedThreadID: original.id, settlementSettings: settings
    ), legacyURL: localURL)
    let suite = "synced-chat-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults, aiChatTranscriptURL: localURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.publishAIChatComposerDraft("Keep my unfinished message")
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, incoming], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let before = try commitPointFingerprint(localURL)
    XCTAssertFalse(store.hasUnpersistedAIChatTranscriptMutationForTesting)
    let refreshed = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshed)
    XCTAssertEqual(Set(store.aiChatThreads.map(\.id)), [original.id, incoming.id])
    XCTAssertEqual(store.selectedAIChatThreadID, original.id)
    XCTAssertEqual(store.aiChatDraft, "Keep my unfinished message")
    store.selectAIChatThread(incoming.id)
    await store.waitForAIChatThreadHydrationForTesting(incoming.id)
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["From my phone", "From the server"])
    XCTAssertEqual(try commitPointFingerprint(localURL), before, "Viewing a synced conversation must not create a commit")

    let pendingMessage = AIChatMessage(role: .user, content: "Still working", deliveryStatus: .sending)
    let working = AIChatThread(
      id: incoming.id, title: incoming.title, sessionKey: incoming.sessionKey,
      messages: [pendingMessage], pendingTurn: AIChatPendingTurn(
        userMessageID: pendingMessage.id, runID: "remote-run", agentID: "main", gatewayMessage: "Still working"
      )
    )
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, working], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let importedPending = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(importedPending)
    XCTAssertNotNil(store.aiChatThreads.first { $0.id == incoming.id }?.pendingTurn)
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, incoming], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let importedCompletion = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(importedCompletion, "A remote pending turn must not prevent refreshing its completion")
    XCTAssertNil(store.aiChatThreads.first { $0.id == incoming.id }?.pendingTurn)
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["From my phone", "From the server"])
  }

  @MainActor
  func testSyncedThreadsArriveDuringLocalTurnAndPendingMetadataSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let localURL = root.appendingPathComponent("local.json")
    let remoteURL = root.appendingPathComponent("remote.json")
    let active = AIChatThread(title: "Working locally", runtime: .codex, sessionKey: "local", messages: [])
    let idle = AIChatThread(title: "Existing phone chat", sessionKey: "idle", messages: [])
    let renamed = AIChatThread(title: "Rename me", sessionKey: "renamed", messages: [])
    let incoming = AIChatThread(title: "New phone chat", sessionKey: "phone", messages: [
      AIChatMessage(role: .assistant, content: "A new conversation from the server")
    ])
    let settings = AIChatThreadSettlementSettings()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [active, idle, renamed], selectedThreadID: active.id, settlementSettings: settings
    ), legacyURL: localURL)
    let suite = "synced-active-chat-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let gate = SyncedChatSendGate()
    let store = WorkspaceStore(
      defaults: defaults, aiChatTranscriptURL: localURL,
      codexSendHandlerForTesting: { _, _, _ in
        await gate.wait()
        return "Local answer after syncing"
      }, legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    let send = Task { @MainActor in await store.sendAIChatMessage(text: "Keep working") }
    defer { Task { await gate.open() } }
    for _ in 0..<200 {
      if await gate.started { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let started = await gate.started
    XCTAssertTrue(started)
    XCTAssertTrue(store.isAIChatThreadRunning(active.id))
    XCTAssertTrue(store.isAIChatThreadRunningOnCurrentHost(active.id))
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    let working = try XCTUnwrap(store.aiChatThreads.first { $0.id == active.id })
    let revision = store.aiChatThreadMessageMutationVersionForTesting(active.id)
    store.publishAIChatComposerDraft("Keep this draft while the agent works")
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [active, idle.replacingMessages([
        AIChatMessage(role: .assistant, content: "A remote reply in an existing chat")
      ]), renamed, incoming], selectedThreadID: incoming.id, settlementSettings: settings
    ), legacyURL: remoteURL)
    try replicate(remoteURL, to: localURL)
    let before = try commitPointFingerprint(localURL)
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(true, legacyURL: localURL)
    defer { AIChatTranscriptStore.shared.setWritesSuspendedForTesting(false, legacyURL: localURL) }
    store.renameAIChatThread(renamed.id, title: "My unsaved local title")
    XCTAssertTrue(store.hasUnpersistedAIChatTranscriptMutationForTesting)
    let refreshed = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshed, "A running local turn and queued save must not hide unrelated synced chats")
    XCTAssertEqual(Set(store.aiChatThreads.map(\.id)), [active.id, idle.id, renamed.id, incoming.id])
    XCTAssertEqual(store.aiChatThreads.first { $0.id == active.id }, working)
    // Versions come from one monotonic counter, so a refresh that mutated the
    // active thread would record a newer value. An earlier queued save may
    // legitimately be acknowledged meanwhile, which clears the entry (nil).
    XCTAssertLessThanOrEqual(
      store.aiChatThreadMessageMutationVersionForTesting(active.id) ?? 0,
      revision ?? 0,
      "Refreshing synced chats must not mutate the running local thread"
    )
    XCTAssertTrue(store.isAIChatThreadRunning(active.id))
    XCTAssertEqual(store.aiChatThreads.first { $0.id == renamed.id }?.title, "My unsaved local title")
    XCTAssertEqual(store.aiChatThreads.first { $0.id == idle.id }?.messages.last?.content, "A remote reply in an existing chat")
    XCTAssertEqual(store.selectedAIChatThreadID, active.id)
    XCTAssertEqual(store.aiChatDraft, "Keep this draft while the agent works")
    XCTAssertEqual(try commitPointFingerprint(localURL), before)
    // Repeated refreshes must keep the dirty metadata protected as well.
    let refreshedAgain = await store.refreshSyncedAIChatTranscript()
    XCTAssertTrue(refreshedAgain)
    XCTAssertEqual(store.aiChatThreads.first { $0.id == renamed.id }?.title, "My unsaved local title")
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(false, legacyURL: localURL)
    await gate.open()
    await send.value
    XCTAssertFalse(store.isAIChatThreadRunning(active.id))
    XCTAssertFalse(store.isAIChatThreadRunningOnCurrentHost(active.id))
    XCTAssertEqual(store.aiChatMessages.last?.content, "Local answer after syncing")
    store.flushDeferredAIChatTranscriptPersistence()
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
    let saved = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: localURL))
    XCTAssertEqual(Set(saved.snapshot.threads.map(\.id)), [active.id, idle.id, renamed.id, incoming.id])
  }

  func testStaleSnapshotPreservesUnseenThreadsButHonorsKnownDeletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("chat.json")
    let original = AIChatThread(title: "Known", sessionKey: "known", messages: [])
    let incoming = AIChatThread(title: "Unseen", sessionKey: "unseen", messages: [AIChatMessage(role: .assistant, content: "Preserve me")])
    let settings = AIChatThreadSettlementSettings()
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [original, incoming], selectedThreadID: original.id, settlementSettings: settings
    ), legacyURL: url)
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: [], selectedThreadID: nil, settlementSettings: settings, knownThreadIDs: [original.id]
    ), legacyURL: url)
    let actual = try XCTUnwrap(AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: url, preferPersisted: true))
    XCTAssertEqual(actual.snapshot.threads.map(\.id), [incoming.id])
    XCTAssertEqual(actual.snapshot.threads.first?.messages.first?.content, "Preserve me")
  }

  func testDeliveryUpdatesNeverMoveActivityTimeBackward() {
    let before = Date(timeIntervalSinceReferenceDate: 1_000)
    let message = AIChatMessage(role: .user, content: "Earlier message", createdAt: before.addingTimeInterval(-10))
    let thread = AIChatThread(title: "Conversation", updatedAt: before, sessionKey: "agent:main:test", messages: [message])
    let changed = WorkspaceStore.updatedAIChatThread(
      thread, messages: [message.replacingDeliveryStatus(.interrupted, sendFailure: "Stopped")],
      newAssistantMessageCount: 0, isThreadOpen: true, pendingTurnUpdate: .replace(nil)
    )
    XCTAssertEqual(changed.updatedAt, before)
    let later = AIChatMessage(role: .assistant, content: "New reply", createdAt: before.addingTimeInterval(10))
    let replied = WorkspaceStore.updatedAIChatThread(
      changed, messages: [message, later], newAssistantMessageCount: 1,
      isThreadOpen: true, pendingTurnUpdate: .preserve
    )
    XCTAssertEqual(replied.updatedAt, later.createdAt)
  }

  func testTranscriptEventsAreRecognizedWithoutRefreshingCanonicalDocuments() {
    let root = URL(fileURLWithPath: "/tmp/corpus")
    let classified = WorkspaceStore.classifyCorpusFileEvents([
      "/tmp/corpus/.org2/openclaw-chat.store/migration-marker.json",
      "/tmp/corpus/.org2/openclaw-chat.store/threads/new.json"
    ], corpusRoot: root)
    XCTAssertTrue(classified.hasAIChatTranscriptChanges)
    XCTAssertTrue(classified.contentPaths.isEmpty)
  }
}
