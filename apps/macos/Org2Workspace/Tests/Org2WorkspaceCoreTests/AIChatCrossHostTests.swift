import Foundation
import CryptoKit
import XCTest
@testable import Org2WorkspaceCore

private actor CrossHostSendCounter {
  private(set) var prompts: [String] = []

  func record(_ prompt: String) {
    prompts.append(prompt)
  }
}

/// Two OpenOrg hosts (a laptop and a headless server) sharing one corpus
/// through a file replicator such as Syncthing.
final class AIChatCrossHostTests: XCTestCase {
  private var root: URL!
  private let laptop = AIChatTranscriptWriterIdentity(id: "laptop-writer", label: "AiroPress")
  private let server = AIChatTranscriptWriterIdentity(id: "server-writer", label: "OpenOrg on press")
  private let settings = AIChatThreadSettlementSettings()

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cross-host-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Storage

  func testWritersNeverShareAMutableCommitFile() throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let thread = AIChatThread(title: "Shared", sessionKey: "shared", messages: [
      AIChatMessage(role: .user, content: "hello")
    ])
    try flush([thread], to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    let markerBefore = try Data(contentsOf: storeURL(laptopURL).appendingPathComponent("migration-marker.json"))
    for index in 0..<3 {
      try flush([thread.replacingMessages(thread.messages + [
        AIChatMessage(role: .assistant, content: "laptop \(index)")
      ])], to: laptopURL)
      try flush([thread.replacingMessages(thread.messages + [
        AIChatMessage(role: .assistant, content: "server \(index)")
      ])], to: serverURL)
    }
    let laptopFiles = try mutablePaths(laptopURL)
    let serverFiles = try mutablePaths(serverURL)
    XCTAssertEqual(laptopFiles, ["heads/laptop-writer.json"])
    XCTAssertEqual(serverFiles, ["heads/server-writer.json"])
    XCTAssertTrue(laptopFiles.isDisjoint(with: serverFiles), "No path is rewritten by both hosts")
    XCTAssertEqual(
      try Data(contentsOf: storeURL(laptopURL).appendingPathComponent("migration-marker.json")),
      markerBefore,
      "The historical marker is created once for older builds and never rewritten"
    )
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: storeURL(laptopURL).appendingPathComponent("manifest.json").path
    ))
  }

  func testConcurrentTurnsInOneConversationKeepBothHostsMessages() throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = AIChatMessage(role: .user, content: "base", createdAt: start)
    let thread = AIChatThread(
      title: "Shared", createdAt: start, updatedAt: start, sessionKey: "shared", messages: [first]
    )
    try flush([thread], to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)

    let fromPhone = AIChatMessage(
      role: .user, content: "phone via server", createdAt: start.addingTimeInterval(10)
    )
    let serverReply = AIChatMessage(
      role: .assistant, content: "server reply", createdAt: start.addingTimeInterval(20)
    )
    let fromLaptop = AIChatMessage(
      role: .user, content: "typed on the laptop", createdAt: start.addingTimeInterval(15)
    )
    try flush([thread.replacingMessages([first, fromPhone, serverReply])], to: serverURL)
    try flush([thread.replacingMessages([first, fromLaptop])], to: laptopURL)

    // Both directions replicate. Neither side has seen the other's commit.
    try syncAll(from: serverURL, to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    for url in [laptopURL, serverURL] {
      let loaded = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: url))
      XCTAssertEqual(loaded.recoveryStatus, .healthy)
      let messages = try XCTUnwrap(loaded.snapshot.threads.first).messages.map(\.content)
      XCTAssertEqual(messages, ["base", "phone via server", "typed on the laptop", "server reply"])
    }
  }

  func testStaleLocalWriteCannotEraseAReplicaReply() throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let question = AIChatMessage(
      role: .user, content: "question", createdAt: start, deliveryStatus: .sending
    )
    let thread = AIChatThread(
      title: "Remote turn", createdAt: start, updatedAt: start, sessionKey: "remote", messages: [question]
    )
    try flush([thread], to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    let reply = AIChatMessage(role: .assistant, content: "answer", createdAt: start.addingTimeInterval(5))
    try flush([thread.replacingMessages([
      question.replacingDeliveryStatus(.sent), reply,
    ])], to: serverURL)
    try syncAll(from: serverURL, to: laptopURL)

    // The laptop still holds its original copy (for example because a local
    // edit protected the conversation) and saves an unrelated change.
    try flush([thread.replacingAIChatMetadata(title: "Renamed on laptop")], to: laptopURL)
    let loaded = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: laptopURL))
    let saved = try XCTUnwrap(loaded.snapshot.threads.first)
    XCTAssertEqual(saved.messages.map(\.content), ["question", "answer"])
    XCTAssertEqual(saved.messages.first?.deliveryStatus, .sent, "A finished remote turn is not stuck as sending")
  }

  func testQueuedSnapshotCannotDeleteAReplyAdoptedAfterEnqueue() async throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let question = AIChatMessage(role: .user, content: "question")
    let thread = AIChatThread(title: "Shared", sessionKey: "shared", messages: [question])
    let transcriptStore = AIChatTranscriptStore.shared
    try flush([thread], to: laptopURL)
    transcriptStore.recordAdoptedThreads([thread], legacyURL: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    let reply = AIChatMessage(role: .assistant, content: "original reply")
    let completed = thread.replacingMessages([question, reply])
    try flush([completed], to: serverURL)

    transcriptStore.setWritesSuspendedForTesting(true, legacyURL: laptopURL)
    defer { transcriptStore.setWritesSuspendedForTesting(false, legacyURL: laptopURL) }
    let generation = transcriptStore.enqueueDurabilityBarrier(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: laptopURL
    )
    try syncAll(from: serverURL, to: laptopURL, waitForWrites: false)
    let refreshed = try XCTUnwrap(transcriptStore.loadCommittedIfAvailable(legacyURL: laptopURL))
    transcriptStore.recordAdoptedThreads(refreshed.snapshot.threads, legacyURL: laptopURL)
    transcriptStore.setWritesSuspendedForTesting(false, legacyURL: laptopURL)
    try await transcriptStore.waitUntilPersisted(generation: generation, legacyURL: laptopURL)

    let saved = try XCTUnwrap(transcriptStore.loadCommittedIfAvailable(legacyURL: laptopURL))
    XCTAssertEqual(saved.snapshot.threads.first?.messages.map(\.id), [question.id, reply.id])
    XCTAssertEqual(saved.snapshot.threads.first?.messages.last?.content, "original reply")
    // A subsequent ordinary save must preserve the same original reply too.
    try flush([completed], to: laptopURL)
    XCTAssertEqual(
      transcriptStore.loadCommittedIfAvailable(legacyURL: laptopURL)?.snapshot.threads.first?.messages.map(\.id),
      [question.id, reply.id]
    )
  }

  func testLocalDeletionIsNotResurrectedByAReplica() throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let first = AIChatMessage(role: .user, content: "keep", createdAt: start)
    let queued = AIChatMessage(
      role: .user, content: "queued then removed", createdAt: start.addingTimeInterval(1),
      deliveryStatus: .sending, deliveryKind: .followUp
    )
    let thread = AIChatThread(
      title: "Queue", createdAt: start, updatedAt: start, sessionKey: "queue", messages: [first, queued]
    )
    try flush([thread], to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    let serverNote = AIChatMessage(role: .assistant, content: "server note", createdAt: start.addingTimeInterval(2))
    try flush([thread.replacingMessages([first, queued, serverNote])], to: serverURL)
    try flush([thread.replacingMessages([first])], to: laptopURL)
    try syncAll(from: serverURL, to: laptopURL)

    let loaded = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: laptopURL))
    XCTAssertEqual(
      loaded.snapshot.threads.first?.messages.map(\.content),
      ["keep", "server note"]
    )
  }

  func testQueuedExactSavesStillHonorADeletionOfEarlierLocalQueuedText() async throws {
    let url = root.appendingPathComponent("laptop.json")
    let question = AIChatMessage(role: .user, content: "question")
    let queued = AIChatMessage(role: .user, content: "remove this queued follow-up")
    let thread = AIChatThread(title: "Shared", sessionKey: "shared", messages: [question])
    try flush([thread], to: url)
    let store = AIChatTranscriptStore.shared
    store.setWritesSuspendedForTesting(true, legacyURL: url)
    defer { store.setWritesSuspendedForTesting(false, legacyURL: url) }
    _ = store.enqueueDurabilityBarrier(AIChatTranscriptSnapshot(
      threads: [thread.replacingMessages([question, queued])], selectedThreadID: thread.id,
      settlementSettings: settings), legacyURL: url)
    let last = store.enqueueDurabilityBarrier(AIChatTranscriptSnapshot(
      threads: [thread], selectedThreadID: thread.id, settlementSettings: settings), legacyURL: url)
    store.setWritesSuspendedForTesting(false, legacyURL: url)
    try await store.waitUntilPersisted(generation: last, legacyURL: url)
    XCTAssertEqual(store.loadCommittedIfAvailable(legacyURL: url)?.snapshot.threads.first?.messages.map(\.id), [question.id])
  }

  // MARK: Presence and routing

  func testQueuedCommitsKeepTheLatestLocalDeletionBase() async throws {
    let url = root.appendingPathComponent("laptop.json")
    let question = AIChatMessage(role: .user, content: "question")
    let first = AIChatMessage(role: .user, content: "first follow-up")
    let second = AIChatMessage(role: .user, content: "second follow-up")
    let thread = AIChatThread(title: "Shared", sessionKey: "shared", messages: [question])
    try flush([thread], to: url)
    let store = AIChatTranscriptStore.shared
    store.setWritesSuspendedForTesting(true, legacyURL: url)
    defer { store.setWritesSuspendedForTesting(false, legacyURL: url) }
    _ = store.enqueueDurabilityBarrier(AIChatTranscriptSnapshot(
      threads: [thread.replacingMessages([question, first])], selectedThreadID: thread.id,
      settlementSettings: settings), legacyURL: url)
    let last = store.enqueueDurabilityBarrier(AIChatTranscriptSnapshot(
      threads: [thread.replacingMessages([question, first, second])], selectedThreadID: thread.id,
      settlementSettings: settings), legacyURL: url)
    store.setWritesSuspendedForTesting(false, legacyURL: url)
    try await store.waitUntilPersisted(generation: last, legacyURL: url)
    try flush([thread.replacingMessages([question, first])], to: url)
    XCTAssertEqual(store.loadCommittedIfAvailable(legacyURL: url)?.snapshot.threads.first?.messages.map(\.id),
      [question.id, first.id])
  }

  func testRepairAcceptsAnEmptyCommittedConversationList() throws {
    let url = root.appendingPathComponent("laptop.json")
    try flush([], to: url)
    let before = try storedBytes(url)
    let report = try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true)
    XCTAssertFalse(report.changed)
    XCTAssertEqual(report.threadCount, 0)
    XCTAssertEqual(try storedBytes(url), before)
  }

  func testDeterministicRepairPreviewsWithoutWritingAndConvergesAcrossReplicas() throws {
    let laptopURL = root.appendingPathComponent("laptop.json")
    let serverURL = root.appendingPathComponent("server.json")
    configureWriters(laptopURL: laptopURL, serverURL: serverURL)
    let question = AIChatMessage(role: .user, content: "question")
    let thread = AIChatThread(title: "Shared", sessionKey: "shared", messages: [question])
    try flush([thread], to: laptopURL)
    try syncAll(from: laptopURL, to: serverURL)
    let laptopReply = AIChatMessage(role: .assistant, content: "laptop reply")
    let serverReply = AIChatMessage(role: .assistant, content: "server reply")
    try flush([thread.replacingMessages([question, laptopReply])], to: laptopURL)
    try flush([thread.replacingMessages([question, serverReply])], to: serverURL)
    try syncAll(from: serverURL, to: laptopURL)

    let before = try storedBytes(laptopURL)
    let store = AIChatTranscriptStore.shared
    let preview = try store.repair(legacyURL: laptopURL, apply: false)
    XCTAssertTrue(preview.changed)
    XCTAssertFalse(preview.applied)
    XCTAssertEqual(try storedBytes(laptopURL), before, "Preview must not even publish a merged shard")
    let applied = try store.repair(legacyURL: laptopURL, apply: true, expectedRevision: preview.revision)
    XCTAssertTrue(applied.applied)
    for (path, bytes) in before {
      XCTAssertEqual(try storedBytes(laptopURL)[path], bytes, "Original evidence must remain intact: \(path)")
    }
    let after = try storedBytes(laptopURL)
    let verified = try store.repair(legacyURL: laptopURL, apply: true, onlyIfChanged: true)
    XCTAssertTrue(verified.checked, "Publishing a repair requires one stable follow-up check before caching")
    XCTAssertFalse(verified.changed)
    XCTAssertFalse(try store.repair(legacyURL: laptopURL, apply: true, onlyIfChanged: true).checked)
    XCTAssertEqual(try storedBytes(laptopURL), after, "Repeat repairs do not create commits")
    try syncAll(from: laptopURL, to: serverURL)
    try flush([thread.replacingMessages([question, serverReply])], to: serverURL)
    try syncAll(from: serverURL, to: laptopURL)
    for url in [laptopURL, serverURL] {
      let loaded = try XCTUnwrap(store.loadCommittedIfAvailable(legacyURL: url))
      let messages = try XCTUnwrap(loaded.snapshot.threads.first).messages
      XCTAssertEqual(Set(messages.map(\.id)), [question.id, laptopReply.id, serverReply.id])
      XCTAssertEqual(messages.first { $0.id == laptopReply.id }?.content, laptopReply.content)
      XCTAssertEqual(messages.first { $0.id == serverReply.id }?.createdAt, serverReply.createdAt)
    }
  }

  func testRepairRetainsIncompleteTipsUntilTheirShardsArrive() throws {
    let url = root.appendingPathComponent("laptop.json")
    let thread = AIChatThread(title: "Shared", sessionKey: "shared", messages: [
      AIChatMessage(role: .assistant, content: "reply")
    ])
    try flush([thread], to: url)
    let shard = try XCTUnwrap(FileManager.default.contentsOfDirectory(
      at: storeURL(url).appendingPathComponent("threads"), includingPropertiesForKeys: nil).first)
    let original = try Data(contentsOf: shard)
    try FileManager.default.removeItem(at: shard)
    let before = try storedBytes(url)
    XCTAssertThrowsError(try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true))
    XCTAssertEqual(try storedBytes(url), before)
    try original.write(to: shard)
    XCTAssertNoThrow(try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true))
  }

  func testRepairPreservesUnknownFutureFieldsByRefusingToRewrite() throws {
    let url = root.appendingPathComponent("laptop.json")
    try flush([AIChatThread(title: "Future", sessionKey: "future", messages: [])], to: url)
    let headURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
      at: storeURL(url).appendingPathComponent("heads"), includingPropertiesForKeys: nil).first)
    var head = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: headURL)) as? [String: Any])
    let manifestURL = storeURL(url).appendingPathComponent("manifests/\(try XCTUnwrap(head["currentManifest"] as? String))")
    var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    manifest["futureField"] = ["preserve": "these bytes"]
    let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    try bytes.write(to: manifestURL)
    head["currentDigest"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try JSONSerialization.data(withJSONObject: head, options: [.sortedKeys]).write(to: headURL)
    let before = try storedBytes(url)
    XCTAssertThrowsError(try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: false))
    XCTAssertThrowsError(try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true))
    XCTAssertEqual(try storedBytes(url), before)
  }

  func testUnchangedRepairSkipsShardDecodingAndStalePreviewsFailClosed() throws {
    let url = root.appendingPathComponent("laptop.json")
    let thread = AIChatThread(title: "Shared", sessionKey: "shared", messages: [
      AIChatMessage(role: .assistant, content: "reply")
    ])
    try flush([thread], to: url)
    let first = try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true, onlyIfChanged: true)
    #if DEBUG
    AIChatTranscriptStore.resetThreadShardDecodeCountForTesting()
    #endif
    XCTAssertFalse(try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true, onlyIfChanged: true).checked)
    #if DEBUG
    XCTAssertEqual(AIChatTranscriptStore.threadShardDecodeCountForTesting(), 0)
    #endif
    try flush([thread.replacingMessages(thread.messages + [AIChatMessage(role: .assistant, content: "new")])], to: url)
    let before = try storedBytes(url)
    XCTAssertThrowsError(try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true, expectedRevision: first.revision))
    XCTAssertEqual(try storedBytes(url), before)
  }

  func testChatSavesCommitWhileAPeriodicRepairIsVerifying() throws {
    let url = root.appendingPathComponent("laptop.json")
    let question = AIChatMessage(role: .user, content: "question")
    let thread = AIChatThread(title: "Shared", sessionKey: "shared", messages: [question])
    try flush([thread], to: url)

    let verifying = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    AIChatTranscriptStore.repairVerificationHookForTesting = {
      verifying.signal()
      _ = release.wait(timeout: .now() + 10)
    }
    defer { AIChatTranscriptStore.repairVerificationHookForTesting = nil }
    let repaired = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = try? AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true, onlyIfChanged: true)
      repaired.signal()
    }
    XCTAssertEqual(verifying.wait(timeout: .now() + 10), .success)

    // A phone message arriving now must commit without waiting for repair.
    let reply = AIChatMessage(role: .assistant, content: "acknowledged")
    let saved = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { [settings] in
      try? AIChatTranscriptStore.shared.flush(
        AIChatTranscriptSnapshot(
          threads: [thread.replacingMessages([question, reply])],
          selectedThreadID: thread.id,
          settlementSettings: settings,
          knownThreadIDs: [thread.id]
        ),
        legacyURL: url
      )
      saved.signal()
    }
    let savedInTime = saved.wait(timeout: .now() + 5)
    release.signal()
    XCTAssertEqual(savedInTime, .success, "Repair verification must not hold the chat save queue")
    XCTAssertEqual(repaired.wait(timeout: .now() + 10), .success)
    if savedInTime != .success { _ = saved.wait(timeout: .now() + 10) }
    XCTAssertEqual(
      AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: url)?.snapshot.threads.first?.messages.map(\.id),
      [question.id, reply.id]
    )
  }

  func testRepairSkipsAWriterHeadWhoseManifestNeverArrived() throws {
    let url = root.appendingPathComponent("laptop.json")
    let thread = AIChatThread(title: "Shared", sessionKey: "shared", messages: [
      AIChatMessage(role: .assistant, content: "reply")
    ])
    try flush([thread], to: url)
    let heads = storeURL(url).appendingPathComponent("heads")
    func writeHead(_ name: String, updatedAt: Date) throws {
      let head: [String: Any] = [
        "schema": "org2:ai-chat-transcript-head:v1",
        "version": 1,
        "writerID": name,
        "writerLabel": "Deterministic chat repair",
        "currentManifest": "recovered-\(name).json",
        "currentDigest": String(repeating: "a", count: 64),
        "currentGeneration": 1,
        "updatedAt": updatedAt.timeIntervalSinceReferenceDate,
      ]
      try JSONSerialization.data(withJSONObject: head).write(to: heads.appendingPathComponent("\(name).json"))
    }

    // A head whose manifest is still in flight keeps repair waiting for sync.
    try writeHead("repair-in-flight", updatedAt: Date())
    XCTAssertThrowsError(try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true, onlyIfChanged: true))
    try FileManager.default.removeItem(at: heads.appendingPathComponent("repair-in-flight.json"))

    // One that never arrived no longer fails every periodic pass.
    try writeHead("repair-abandoned", updatedAt: Date().addingTimeInterval(-3 * 60 * 60))
    let before = try storedBytes(url)
    let report = try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true, onlyIfChanged: true)
    XCTAssertTrue(report.checked)
    XCTAssertFalse(report.changed)
    XCTAssertTrue(report.warnings.contains { $0.contains("recovered-repair-abandoned.json") })
    XCTAssertEqual(try storedBytes(url), before, "The abandoned head's bytes are retained")
    XCTAssertFalse(
      try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: true, onlyIfChanged: true).checked,
      "A stable pass is cached instead of repeating every interval"
    )
  }

  func testSuccessiveSavesDoNotReconcileAncestorsLeavingTheWindow() throws {
    let url = root.appendingPathComponent("laptop.json")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var messages = [AIChatMessage(role: .user, content: "question", createdAt: start)]
    let thread = AIChatThread(
      title: "Long turn", createdAt: start, updatedAt: start, sessionKey: "long", messages: messages
    )
    // More commits than the bounded ancestry window, as one streamed reply makes.
    for index in 0..<45 {
      messages.append(AIChatMessage(
        role: .assistant, content: "part \(index)", createdAt: start.addingTimeInterval(Double(index + 1))
      ))
      try flush([thread.replacingMessages(messages)], to: url)
    }
    let manifests = try FileManager.default.contentsOfDirectory(
      atPath: storeURL(url).appendingPathComponent("manifests").path
    )
    XCTAssertEqual(manifests.filter { $0.hasPrefix("recovered-") }, [],
      "A single writer's linear history never needs a synthesized reconciliation")
    XCTAssertEqual(manifests.count, 45)
    let loaded = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: url))
    XCTAssertEqual(loaded.recoveryStatus, .healthy)
    XCTAssertEqual(loaded.snapshot.threads.first?.messages.count, 46)
  }

  func testLineageOverflowIsRecordedAsMerged() {
    XCTAssertEqual(
      AIChatTranscriptStore.recordingLineageOverflow(["c", "b", "a"], beyond: ["c", "b"], in: ["x"]),
      ["x", "a"]
    )
    XCTAssertEqual(
      AIChatTranscriptStore.recordingLineageOverflow(["c", "b"], beyond: ["c", "b"], in: nil),
      nil
    )
    XCTAssertEqual(
      AIChatTranscriptStore.recordingLineageOverflow(["c", "a"], beyond: ["c"], in: ["a"]),
      ["a"]
    )
  }

  @MainActor
  func testRepairIntervalIsRestoredAndCanBeDisabled() throws {
    let defaults = UserDefaults(suiteName: "org2-repair-test-\(UUID().uuidString)")!
    defaults.set(900.0, forKey: "Org2Workspace.aiChat.repairIntervalSeconds.v1")
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: root), defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("empty.json"))
    XCTAssertEqual(store.aiChatRepairIntervalSeconds, 900)
    store.aiChatRepairIntervalSeconds = 0
    XCTAssertEqual(defaults.double(forKey: "Org2Workspace.aiChat.repairIntervalSeconds.v1"), 0)
  }

  private func storedBytes(_ url: URL) throws -> [String: Data] {
    let directory = storeURL(url)
    let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
    var result: [String: Data] = [:]
    for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      result[String(file.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: file)
    }
    return result
  }

  @MainActor
  func testRemoteLiveTurnIsVisibleAsRunningOnAnotherHost() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let thread = AIChatThread(title: "Automation: digest", runtime: .codex, sessionKey: "auto")
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    let store = try makeStore(transcriptURL: transcriptURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))

    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(
        writerID: "server-writer",
        host: AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server),
        enabledDestinationIDs: [thread.destinationID],
        turns: [AIChatLiveTurnRecord(
          threadID: thread.id,
          destinationName: "Codex",
          startedAt: Date(),
          streamingReply: "Collecting today's items…"
        )]
      ),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    XCTAssertTrue(store.isAIChatThreadRunning(thread.id))
    XCTAssertFalse(store.isAIChatThreadRunningOnCurrentHost(thread.id))
    XCTAssertEqual(store.aiChatRemoteLiveTurn(for: thread.id)?.turn.streamingReply, "Collecting today's items…")
    XCTAssertEqual(store.aiChatExecutionHostName(for: thread.id), "OpenOrg on press")

    let stopped = await store.stopAIChatRemoteRun(threadID: thread.id)
    XCTAssertFalse(stopped, "Another host's provider run is not stopped from this copy")

    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(
        writerID: "server-writer",
        host: AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server),
        updatedAt: Date().addingTimeInterval(-600),
        turns: [AIChatLiveTurnRecord(threadID: thread.id)]
      ),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    XCTAssertNil(store.aiChatRemoteLiveTurn(for: thread.id), "Stale presence is ignored")
  }

  @MainActor
  func testFollowUpRoutesToTheHostRunningTheConversationAndFallsBackWhenItIsOffline() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let press = AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server)
    let earlier = Date().addingTimeInterval(-300)
    let thread = AIChatThread(
      title: "Server conversation", createdAt: earlier, updatedAt: earlier, runtime: .codex,
      sessionKey: "server-owned",
      messages: [
        AIChatMessage(role: .user, content: "start", createdAt: earlier),
        AIChatMessage(
          role: .assistant, content: "started on press", createdAt: earlier.addingTimeInterval(1),
          provenance: AIChatMessageProvenance(executionHostRef: press.ref, executionHostName: press.name)
        ),
      ]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(writerID: "server-writer", host: press, enabledDestinationIDs: [thread.destinationID]),
      transcriptURL: transcriptURL
    )
    let counter = CrossHostSendCounter()
    let store = try makeStore(transcriptURL: transcriptURL) { messages, _, _ in
      await counter.record(messages.last?.content ?? "")
      return "answered here"
    }
    await store.waitForAIChatTranscriptLoadForTesting()
    await store.refreshAIChatRemoteLiveHosts()

    await store.sendAIChatMessage(text: "follow up from the laptop")
    let routed = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(routed.content, "follow up from the laptop")
    XCTAssertEqual(routed.deliveryStatus, .sending)
    XCTAssertEqual(routed.provenance?.executionHostRef, "press")
    XCTAssertNil(routed.provenance?.acceptedAt)
    XCTAssertEqual(routed.provenance?.receivedByHostRef, store.aiChatHostIdentity.ref)
    XCTAssertTrue(store.isAIChatThreadRunning(thread.id))
    let promptsWhileRouted = await counter.prompts
    XCTAssertTrue(promptsWhileRouted.isEmpty, "The laptop must not run a server-owned turn")

    // press stops publishing presence (asleep, crashed, or unsynchronized).
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(writerID: "server-writer", host: press, isOnline: false),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    store.processAIChatHandoffs()
    for _ in 0..<300 {
      if store.aiChatMessages.last?.role == .assistant { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let prompts = await counter.prompts
    XCTAssertEqual(prompts.count, 1)
    XCTAssertEqual(store.aiChatMessages.last?.content, "answered here")
    XCTAssertEqual(store.aiChatMessages.last?.provenance?.executionHostRef, store.aiChatHostIdentity.ref)
    let reclaimed = try XCTUnwrap(store.aiChatMessages.first { $0.id == routed.id })
    XCTAssertEqual(reclaimed.deliveryStatus, .sent)
    XCTAssertEqual(reclaimed.provenance?.executionHostRef, store.aiChatHostIdentity.ref)
    XCTAssertNotNil(reclaimed.provenance?.acceptedAt)
  }

  @MainActor
  func testHandOffQueuedBehindTheTargetsRunningTurnIsNotReclaimed() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let server = AIChatHostIdentity(ref: "build-host", name: "Celorga on build-host", kind: .server)
    let laptop = AIChatHostIdentity(ref: "desktop-studio", name: "Studio Mac", kind: .desktop)
    let earlier = Date().addingTimeInterval(-600)
    let followUp = AIChatMessage(
      role: .user, content: "also check the old prompts", createdAt: earlier.addingTimeInterval(5),
      deliveryStatus: .sending, deliveryKind: .followUp,
      provenance: AIChatMessageProvenance(
        originClient: .desktop,
        receivedByHostRef: laptop.ref, receivedByHostName: laptop.name,
        executionHostRef: server.ref, executionHostName: server.name
      )
    )
    let thread = AIChatThread(
      title: "Long server turn", createdAt: earlier, updatedAt: earlier, runtime: .codex,
      sessionKey: "long-server-turn",
      messages: [
        AIChatMessage(
          role: .user, content: "start a long build", createdAt: earlier, deliveryStatus: .sending,
          provenance: AIChatMessageProvenance(
            receivedByHostRef: server.ref, receivedByHostName: server.name,
            executionHostRef: server.ref, executionHostName: server.name, acceptedAt: earlier
          )
        ),
        followUp,
      ]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    // The server runs the turn and has begun draining for an update.
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(
        writerID: "server-writer", host: server, enabledDestinationIDs: [thread.destinationID],
        turns: [AIChatLiveTurnRecord(threadID: thread.id)], isDraining: true
      ),
      transcriptURL: transcriptURL
    )
    let counter = CrossHostSendCounter()
    let store = try makeStore(transcriptURL: transcriptURL) { messages, _, _ in
      await counter.record(messages.last?.content ?? "")
      return "answered here"
    }
    store.configureAIChatHost(laptop)
    store.aiChatHandoffTimeout = 0
    await store.waitForAIChatTranscriptLoadForTesting()
    await store.refreshAIChatRemoteLiveHosts()

    store.processAIChatHandoffs()
    try await Task.sleep(for: .milliseconds(100))

    let waiting = try XCTUnwrap(store.aiChatMessages.first { $0.id == followUp.id })
    XCTAssertEqual(waiting.provenance?.executionHostRef, server.ref, "it stays with the host running the turn")
    XCTAssertNil(waiting.provenance?.acceptedAt)
    let promptsWhileRunning = await counter.prompts
    XCTAssertTrue(promptsWhileRunning.isEmpty, "the laptop must not run it beside the server's live turn")

    // Once the server's presence no longer reports the turn, the drain hand-off is reclaimed.
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(
        writerID: "server-writer", host: server, enabledDestinationIDs: [thread.destinationID],
        isDraining: true
      ),
      transcriptURL: transcriptURL
    )
    await store.refreshAIChatRemoteLiveHosts()
    store.processAIChatHandoffs()
    let reclaimed = try XCTUnwrap(store.aiChatMessages.first { $0.id == followUp.id })
    XCTAssertEqual(reclaimed.provenance?.executionHostRef, laptop.ref)
    XCTAssertNotNil(reclaimed.provenance?.acceptedAt)
  }

  @MainActor
  func testHostAcceptsAHandOffWhoseConversationArrivesBeforeItsShard() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let marker = "new conversation handed to the server \(UUID().uuidString)"
    let handedOff = AIChatMessage(
      role: .user, content: marker, createdAt: Date().addingTimeInterval(-86_400),
      deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        originClient: .desktop,
        receivedByHostRef: "desktop-studio", receivedByHostName: "Studio Mac",
        executionHostRef: "build-host", executionHostName: "Celorga on build-host"
      )
    )
    let newThread = AIChatThread(
      title: "Brand new", createdAt: handedOff.createdAt, updatedAt: handedOff.createdAt,
      runtime: .codex, sessionKey: "brand-new", messages: [handedOff]
    )
    // Newer conversations fill the eager working set, so the new one loads cold.
    let warm = (0..<AIChatTranscriptStore.eagerWorkingSetLimit).map { index in
      AIChatThread(
        title: "Warm \(index)", runtime: .codex, sessionKey: "warm-\(index)",
        messages: [AIChatMessage(role: .assistant, content: "warm \(index)")]
      )
    }
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: warm + [newThread], selectedThreadID: warm[0].id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    // Synchronization delivered the manifest but not yet the conversation's shard.
    let threadsDirectory = root.appendingPathComponent("chat.store/threads")
    let shards = try FileManager.default.contentsOfDirectory(at: threadsDirectory, includingPropertiesForKeys: nil)
      .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains(marker) == true }
    XCTAssertFalse(shards.isEmpty)
    let parked = root.appendingPathComponent("parked-shards", isDirectory: true)
    try FileManager.default.createDirectory(at: parked, withIntermediateDirectories: true)
    for shard in shards {
      try FileManager.default.moveItem(at: shard, to: parked.appendingPathComponent(shard.lastPathComponent))
    }

    let counter = CrossHostSendCounter()
    let store = try makeStore(transcriptURL: transcriptURL) { messages, _, _ in
      await counter.record(messages.last?.content ?? "")
      return "ran on the server"
    }
    store.configureAIChatHost(AIChatHostIdentity(ref: "build-host", name: "Celorga on build-host", kind: .server))
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertTrue(store.unloadedAIChatThreadIDsForTesting.contains(newThread.id))

    store.processAIChatHandoffs()
    try await Task.sleep(for: .milliseconds(300))
    let promptsBeforeShard = await counter.prompts
    XCTAssertTrue(promptsBeforeShard.isEmpty)

    for shard in shards {
      try FileManager.default.moveItem(at: parked.appendingPathComponent(shard.lastPathComponent), to: shard)
    }
    for _ in 0..<300 {
      store.processAIChatHandoffs()
      let prompts = await counter.prompts
      if !prompts.isEmpty { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let prompts = await counter.prompts
    XCTAssertEqual(prompts, [marker], "the server accepts the hand-off once the conversation can be read")
  }

  @MainActor
  func testHostAcceptsAHandOffExactlyOnce() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let handedOff = AIChatMessage(
      role: .user, content: "continue on press", deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        originClient: .mobile, originDeviceName: "Avi's iPhone",
        receivedByHostRef: "desktop-laptop", receivedByHostName: "AiroPress",
        executionHostRef: "press", executionHostName: "OpenOrg on press"
      )
    )
    let thread = AIChatThread(
      title: "Handed off", runtime: .codex, sessionKey: "handoff", messages: [handedOff]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    let counter = CrossHostSendCounter()
    let store = try makeStore(transcriptURL: transcriptURL) { messages, _, _ in
      await counter.record(messages.last?.content ?? "")
      return "ran on press"
    }
    store.configureAIChatHost(AIChatHostIdentity(ref: "press", name: "OpenOrg on press", kind: .server))
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(
      store.aiChatMessages.first?.deliveryStatus, .sending,
      "An unstarted hand-off is not an interrupted local send"
    )
    store.processAIChatHandoffs()
    for _ in 0..<300 {
      if store.aiChatMessages.last?.role == .assistant { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    store.processAIChatHandoffs()
    try await Task.sleep(for: .milliseconds(50))
    let prompts = await counter.prompts
    XCTAssertEqual(prompts, ["continue on press"])
    let accepted = try XCTUnwrap(store.aiChatMessages.first)
    XCTAssertEqual(accepted.deliveryStatus, .sent)
    XCTAssertNotNil(accepted.provenance?.acceptedAt)
    XCTAssertEqual(accepted.provenance?.originDeviceName, "Avi's iPhone")
    let reply = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(reply.provenance?.executionHostName, "OpenOrg on press")
    XCTAssertEqual(
      accepted.provenance?.caption(role: .user),
      "Avi's iPhone via AiroPress · runs on OpenOrg on press"
    )
    XCTAssertEqual(reply.provenance?.caption(role: .assistant), "ran on OpenOrg on press")
  }

  @MainActor
  func testAnotherHostsInFlightTurnIsNotMarkedInterruptedOrRedispatched() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let remoteTurn = AIChatMessage(
      role: .user, content: "running on press", deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        receivedByHostRef: "other-host", receivedByHostName: "Other host",
        executionHostRef: "other-host", executionHostName: "Other host", acceptedAt: Date()
      )
    )
    let thread = AIChatThread(title: "Remote", runtime: .codex, sessionKey: "remote", messages: [remoteTurn])
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    let counter = CrossHostSendCounter()
    let store = try makeStore(transcriptURL: transcriptURL) { messages, _, _ in
      await counter.record(messages.last?.content ?? "")
      return "should not run"
    }
    store.aiChatRoutesTurnsToThreadHost = false
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.aiChatMessages.first?.deliveryStatus, .sending)
    XCTAssertTrue(store.isAIChatThreadRunning(thread.id))

    // Import it through synchronization, then queue a local follow-up.
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    _ = await store.refreshSyncedAIChatTranscript()
    await store.sendAIChatMessage(text: "local follow-up")
    try await Task.sleep(for: .milliseconds(100))
    let prompts = await counter.prompts
    XCTAssertFalse(prompts.contains("running on press"), "Another host's turn is never dispatched twice")
  }

  func testPresenceEventsDoNotReloadTheTranscript() {
    let classified = WorkspaceStore.classifyCorpusFileEvents([
      "/tmp/corpus/.org2/openclaw-chat.store/live/server-writer.json",
    ], corpusRoot: URL(fileURLWithPath: "/tmp/corpus"))
    XCTAssertTrue(classified.hasAIChatLiveChanges)
    XCTAssertFalse(classified.hasAIChatTranscriptChanges)
    let head = WorkspaceStore.classifyCorpusFileEvents([
      "/tmp/corpus/.org2/openclaw-chat.store/heads/server-writer.json",
    ], corpusRoot: URL(fileURLWithPath: "/tmp/corpus"))
    XCTAssertTrue(head.hasAIChatTranscriptChanges)
  }

  func testOlderTranscriptsAndMessagesWithoutProvenanceStillDecode() throws {
    let json = """
    {"id":"\(UUID().uuidString)","role":"assistant","content":"legacy","createdAt":0}
    """
    let message = try JSONDecoder().decode(AIChatMessage.self, from: Data(json.utf8))
    XCTAssertNil(message.provenance)
    let encoded = try JSONEncoder().encode(message.replacingProvenance(
      AIChatMessageProvenance(executionHostRef: "press", executionHostName: "press")
    ))
    let decoded = try JSONDecoder().decode(AIChatMessage.self, from: encoded)
    XCTAssertEqual(decoded.provenance?.executionHostRef, "press")
  }

  // MARK: Helpers

  private func configureWriters(laptopURL: URL, serverURL: URL) {
    AIChatTranscriptStore.shared.setWriterIdentityForTesting(laptop, legacyURL: laptopURL)
    AIChatTranscriptStore.shared.setWriterIdentityForTesting(server, legacyURL: serverURL)
    addTeardownBlock {
      AIChatTranscriptStore.shared.setWriterIdentityForTesting(nil, legacyURL: laptopURL)
      AIChatTranscriptStore.shared.setWriterIdentityForTesting(nil, legacyURL: serverURL)
    }
  }

  private func flush(_ threads: [AIChatThread], to url: URL) throws {
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: threads.first?.id,
        settlementSettings: settings,
        knownThreadIDs: Set(threads.map(\.id))
      ),
      legacyURL: url
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
  }

  private func storeURL(_ transcriptURL: URL) -> URL {
    AIChatTranscriptStore.storeDirectory(for: transcriptURL)
  }

  /// Replicate every file the source has that the target lacks, plus the
  /// source writer's head, the way a file synchronizer would.
  private func syncAll(from source: URL, to target: URL, waitForWrites: Bool = true) throws {
    if waitForWrites { AIChatTranscriptStore.shared.waitUntilIdleForTesting() }
    let fileManager = FileManager.default
    let sourceStore = storeURL(source).resolvingSymlinksInPath()
    let targetStore = storeURL(target).resolvingSymlinksInPath()
    guard let enumerator = fileManager.enumerator(at: sourceStore, includingPropertiesForKeys: nil) else { return }
    for case let file as URL in enumerator {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
      let relative = String(file.resolvingSymlinksInPath().path.dropFirst(sourceStore.path.count + 1))
      let destination = targetStore.appendingPathComponent(relative)
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let isMutable = !relative.hasPrefix("threads/") && !relative.hasPrefix("manifests/")
        && !relative.hasPrefix("attachments/")
      if fileManager.fileExists(atPath: destination.path) {
        guard isMutable, relative.hasPrefix("heads/"),
              try Data(contentsOf: destination) != Data(contentsOf: file)
        else { continue }
        // Replicating an unchanged copy of another writer's old head must
        // not roll that writer back. Syncthing tracks per-file versions;
        // this fixture uses the writer's monotonic generation instead.
        let sourceHead = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let targetHead = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
        if let sourceGeneration = sourceHead?["currentGeneration"] as? UInt64,
           let targetGeneration = targetHead?["currentGeneration"] as? UInt64,
           sourceGeneration <= targetGeneration { continue }
        try fileManager.removeItem(at: destination)
      }
      try fileManager.copyItem(at: file, to: destination)
    }
  }

  /// Files outside the immutable, content-addressed directories.
  private func mutablePaths(_ transcriptURL: URL) throws -> Set<String> {
    let store = storeURL(transcriptURL).resolvingSymlinksInPath()
    var result = Set<String>()
    guard let enumerator = FileManager.default.enumerator(at: store, includingPropertiesForKeys: nil) else {
      return []
    }
    for case let file as URL in enumerator {
      guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
      let relative = String(file.resolvingSymlinksInPath().path.dropFirst(store.path.count + 1))
      if relative.hasPrefix("threads/") || relative.hasPrefix("manifests/")
        || relative.hasPrefix("attachments/") || relative.hasPrefix("migration-marker") {
        continue
      }
      // Only count files this writer modified after the initial replication.
      if relative.hasPrefix("heads/") {
        let name = String(relative.dropFirst("heads/".count))
        guard name == "laptop-writer.json" && transcriptURL.lastPathComponent == "laptop.json"
          || name == "server-writer.json" && transcriptURL.lastPathComponent == "server.json"
        else { continue }
      }
      result.insert(relative)
    }
    return result
  }

  func testRemoteHarnessDestinationsNameTheMachineTheHarnessRunsOn() {
    func host(_ adapter: AIChatDestinationAdapter, _ endpoint: String) -> String? {
      AIChatDestinationConfiguration(
        name: "Agent", mention: "agent", adapter: adapter, endpoint: endpoint
      ).harnessHostName
    }
    XCTAssertEqual(host(.openCodeRemote, "press"), "press")
    XCTAssertEqual(host(.openCodeRemote, "avi@press.local"), "press")
    XCTAssertEqual(host(.piRemote, "ssh://avi@press.tail1234.ts.net:22"), "press")
    XCTAssertEqual(host(.codexManagedRemote, "build-box.example.com"), "build-box.example.com")
    XCTAssertEqual(host(.codexRemote, "wss://press.local:4500"), "press")
    XCTAssertNil(host(.openClaw, "ws://127.0.0.1:18789"))
    XCTAssertNil(host(.openCodeLocal, ""))
    XCTAssertNil(host(.openAI, "https://api.openai.com/v1"))
  }

  /// A laptop drives an OpenCode-over-SSH turn whose harness runs on `press`.
  /// Provenance names the laptop, but the conversation runs on `press`.
  @MainActor
  func testRemoteHarnessThreadReportsTheHarnessHostInsteadOfTheDrivingHost() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let destination = AIChatDestinationConfiguration(
      name: "OpenCode",
      mention: "opencode-press",
      adapter: .openCodeRemote,
      endpoint: "press"
    )
    let reply = AIChatMessage(
      role: .assistant,
      content: "Done.",
      provenance: AIChatMessageProvenance(
        executionHostRef: "laptop", executionHostName: "AiroPress"
      )
    )
    let thread = AIChatThread(
      title: "Remote harness",
      runtime: .openCode,
      destinationID: destination.id,
      sessionKey: "remote-harness",
      messages: [reply]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    let store = try makeStore(transcriptURL: transcriptURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.aiChatExecutionHostName(for: thread.id), "AiroPress")

    store.updateAIChatDestination(destination)
    XCTAssertEqual(store.aiChatHarnessHostName(for: thread.id), "press")
    XCTAssertEqual(store.aiChatExecutionHostName(for: thread.id), "press")
  }

  @MainActor
  private func makeStore(
    transcriptURL: URL,
    codex: (@Sendable ([AIChatMessage], UUID, AIChatWorkspaceContext) async throws -> String)? = nil
  ) throws -> WorkspaceStore {
    let suite = "cross-host-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      codexSendHandlerForTesting: codex ?? { _, _, _ in "ok" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    return store
  }
}
