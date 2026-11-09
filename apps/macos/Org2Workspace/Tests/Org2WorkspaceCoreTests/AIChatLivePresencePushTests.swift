import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor LivePushTurnGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}

@MainActor
private final class LivePushRecorder {
  var pushes: [AIChatLivePresencePush] = []
}

/// A laptop runs a turn while file sync to the headless server is slow or
/// disconnected. The laptop sends its live state straight to the server, so
/// a phone paired with the server still follows the conversation.
final class AIChatLivePresencePushTests: XCTestCase {
  private var root: URL!
  private let settings = AIChatThreadSettlementSettings()
  private let laptop = AIChatHostIdentity(ref: "desktop-laptop", name: "Laptop", kind: .desktop)

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-live-push-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  @MainActor
  func testPhoneSeesALaptopTurnBeforeFileSyncDeliversIt() async throws {
    let earlier = AIChatMessage(
      role: .assistant, content: "Earlier answer.", createdAt: Date().addingTimeInterval(-900)
    )
    let known = AIChatThread(title: "Known", runtime: .codex, sessionKey: "known", messages: [earlier])
    let (server, remote, token) = try await makeServer(threads: [known])

    // The laptop starts a new conversation and follows up in a known one.
    let newThreadID = UUID()
    let newPrompt = AIChatMessage(
      role: .user, content: "Draft the release notes.", deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(originClient: .desktop, executionHostRef: laptop.ref, executionHostName: laptop.name)
    )
    let followUp = AIChatMessage(
      role: .user, content: "Now shorten it.", deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(originClient: .desktop, executionHostRef: laptop.ref, executionHostName: laptop.name)
    )
    let newThread = AIChatThread(
      id: newThreadID, title: "Release notes", runtime: .codex, sessionKey: "new", messages: [newPrompt]
    )
    let push = AIChatLivePresencePush(
      record: AIChatLiveHostRecord(
        writerID: "laptop-writer",
        host: laptop,
        turns: [
          AIChatLiveTurnRecord(threadID: newThreadID, userMessageID: newPrompt.id, destinationName: "Codex",
                               startedAt: Date(), streamingReply: "Reading the changelog…"),
          AIChatLiveTurnRecord(threadID: known.id, userMessageID: followUp.id, destinationName: "Codex",
                               startedAt: Date(), streamingReply: "Shortening…"),
        ]
      ),
      threads: [
        AIChatLiveThreadSnapshot(thread: newThread, messages: newThread.messages),
        AIChatLiveThreadSnapshot(thread: known, messages: [earlier, followUp]),
      ]
    )
    let accepted = try await call(remote, "POST", "/v1/live-presence", push, token: token,
                                  as: MobileRemoteLivePresenceResponse.self)
    XCTAssertTrue(accepted.accepted)

    let list = try await call(remote, "GET", "/v1/threads", Optional<String>.none, token: token,
                              as: MobileRemoteThreadList.self)
    let listedNew = try XCTUnwrap(list.threads.first(where: { $0.id == newThreadID }))
    XCTAssertTrue(listedNew.isRunning)
    XCTAssertEqual(listedNew.executionHostName, "Laptop")
    XCTAssertEqual(listedNew.preview, "Draft the release notes.")
    XCTAssertTrue(try XCTUnwrap(list.threads.first(where: { $0.id == known.id })).isRunning)

    let newDetail = try await call(remote, "GET", "/v1/threads/\(newThreadID.uuidString)",
                                   Optional<String>.none, token: token, as: MobileRemoteThreadDetail.self)
    XCTAssertEqual(newDetail.messages.map(\.content), ["Draft the release notes."])
    XCTAssertEqual(newDetail.streamingReply, "Reading the changelog…")
    XCTAssertTrue(newDetail.thread.isRunning)

    let knownDetail = try await call(remote, "GET", "/v1/threads/\(known.id.uuidString)",
                                     Optional<String>.none, token: token, as: MobileRemoteThreadDetail.self)
    XCTAssertEqual(knownDetail.messages.map(\.content), ["Earlier answer.", "Now shorten it."])
    XCTAssertEqual(knownDetail.streamingReply, "Shortening…")

    // Display only: routing and hand-offs still read synced presence files.
    XCTAssertTrue(server.aiChatRemoteLiveHosts.isEmpty)
    XCTAssertNil(server.aiChatRemoteLiveTurn(for: known.id))
    XCTAssertFalse((server.aiChatThreads.first(where: { $0.id == known.id })?.messages ?? [])
      .contains(where: { $0.id == followUp.id }), "nothing pushed is written to this host's transcript")

    // The turn ends. The reply stays visible until file sync delivers it.
    let reply = AIChatMessage(role: .assistant, content: "Short version.", createdAt: Date().addingTimeInterval(1))
    let finished = AIChatLivePresencePush(
      record: AIChatLiveHostRecord(writerID: "laptop-writer", host: laptop),
      threads: [AIChatLiveThreadSnapshot(
        thread: known, messages: [earlier, followUp.replacingDeliveryStatus(.sent), reply]
      )]
    )
    XCTAssertTrue(server.acceptPushedAIChatLivePresence(finished))
    let after = try await call(remote, "GET", "/v1/threads/\(known.id.uuidString)",
                               Optional<String>.none, token: token, as: MobileRemoteThreadDetail.self)
    XCTAssertFalse(after.thread.isRunning)
    XCTAssertEqual(after.messages.map(\.content), ["Earlier answer.", "Now shorten it.", "Short version."])
    XCTAssertEqual(after.messages[1].deliveryStatus, "sent")
    XCTAssertEqual(after.streamingReply, "")
  }

  @MainActor
  func testPushesAreAuthenticatedValidatedAndSupersedeAStaleFile() async throws {
    let thread = AIChatThread(title: "Remote", runtime: .codex, sessionKey: "remote")
    let (server, remote, token) = try await makeServer(threads: [thread])
    let running = AIChatLivePresencePush(
      record: AIChatLiveHostRecord(
        writerID: "laptop-writer", host: laptop,
        updatedAt: Date().addingTimeInterval(-5),
        turns: [AIChatLiveTurnRecord(threadID: thread.id, streamingReply: "Working…")]
      ),
      threads: []
    )
    let unpaired = try await rawCall(remote, "POST", "/v1/live-presence", running, token: nil)
    XCTAssertEqual(unpaired.statusCode, 401)

    var spoofed = running
    spoofed.record = AIChatLiveHostRecord(writerID: "other", host: server.aiChatHostIdentity)
    let rejected = try await rawCall(remote, "POST", "/v1/live-presence", spoofed, token: token)
    XCTAssertEqual(rejected.statusCode, 400)

    // The synced file still lists the turn, but the laptop's newer push says
    // it ended.
    try AIChatLiveHostDirectory.write(running.record, transcriptURL: server.aiChatTranscriptURL)
    await server.refreshAIChatRemoteLiveHosts()
    XCTAssertEqual(server.aiChatObservedRemoteLiveTurn(for: thread.id)?.turn.streamingReply, "Working…")
    XCTAssertTrue(server.acceptPushedAIChatLivePresence(AIChatLivePresencePush(
      record: AIChatLiveHostRecord(writerID: "laptop-writer", host: laptop),
      threads: []
    )))
    XCTAssertNil(server.aiChatObservedRemoteLiveTurn(for: thread.id))

    // Pushes stop: the turn disappears once it is no longer fresh.
    XCTAssertTrue(server.acceptPushedAIChatLivePresence(running, now: Date().addingTimeInterval(-600)))
    try AIChatLiveHostDirectory.write(
      AIChatLiveHostRecord(writerID: "laptop-writer", host: laptop, updatedAt: Date().addingTimeInterval(-600)),
      transcriptURL: server.aiChatTranscriptURL
    )
    await server.refreshAIChatRemoteLiveHosts()
    XCTAssertNil(server.aiChatObservedRemoteLiveTurn(for: thread.id))
  }

  @MainActor
  func testDesktopForwardsItsRunningTurnAndTheFinishedReply() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let thread = AIChatThread(title: "Laptop turn", runtime: .codex, sessionKey: "laptop")
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: [thread], selectedThreadID: thread.id, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    let gate = LivePushTurnGate()
    let suite = "live-push-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      codexSendHandlerForTesting: { _, _, _ in
        await gate.wait()
        return "All done."
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    let recorder = LivePushRecorder()
    store.aiChatLivePresenceForwarder = { push in recorder.pushes.append(push) }

    let send = Task { @MainActor in await store.sendAIChatMessage(text: "Summarize the meeting.") }
    for _ in 0..<300 where !store.isAIChatThreadRunningOnCurrentHost(thread.id) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    for _ in 0..<100 {
      store.publishAIChatLivePresenceIfNeeded(force: true)
      await store.waitForAIChatLivePresenceForwardForTesting()
      if recorder.pushes.last?.record.turns.isEmpty == false { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let running = try XCTUnwrap(recorder.pushes.last)
    XCTAssertEqual(running.record.turns.map(\.threadID), [thread.id])
    XCTAssertEqual(running.threads.first?.id, thread.id)
    XCTAssertEqual(running.threads.first?.messages.last?.content, "Summarize the meeting.")

    await gate.open()
    await send.value
    // The presence tick may be sending an older state; the next change wins.
    for _ in 0..<100 {
      store.publishAIChatLivePresenceIfNeeded()
      await store.waitForAIChatLivePresenceForwardForTesting()
      if recorder.pushes.last?.threads.first?.messages.last?.content == "All done." { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let finished = try XCTUnwrap(recorder.pushes.last)
    XCTAssertTrue(finished.record.turns.isEmpty)
    XCTAssertEqual(finished.threads.first?.id, thread.id, "a finished turn's conversation is still sent")
    XCTAssertEqual(finished.threads.first?.messages.last?.content, "All done.")

    // Nothing changed: no further request until the heartbeat is due.
    let sent = recorder.pushes.count
    store.publishAIChatLivePresenceIfNeeded()
    await store.waitForAIChatLivePresenceForwardForTesting()
    XCTAssertEqual(recorder.pushes.count, sent)
  }

  func testSnapshotsCarryNoAttachmentBytesAndMergeByID() throws {
    let attachment = AIChatAttachment(fileName: "photo.jpg", mimeType: "image/jpeg", data: Data(repeating: 7, count: 1_000))
    let prompt = AIChatMessage(role: .user, content: "Look", attachments: [attachment], createdAt: Date(timeIntervalSince1970: 200))
    let thread = AIChatThread(title: "Photo", runtime: .codex, sessionKey: "photo", messages: [
      AIChatMessage(role: .assistant, content: "first", createdAt: Date(timeIntervalSince1970: 100)),
      AIChatMessage(role: .assistant, content: "third", createdAt: Date(timeIntervalSince1970: 300)),
    ])
    let snapshot = AIChatLiveThreadSnapshot(thread: thread, messages: [prompt])
    XCTAssertEqual(snapshot.messages.first?.attachments.first?.fileName, "photo.jpg")
    XCTAssertEqual(snapshot.messages.first?.attachments.first?.byteCount, 0)
    XCTAssertEqual(snapshot.merged(into: thread).messages.map(\.content), ["first", "Look", "third"])
  }

  // MARK: Helpers

  @MainActor
  private func makeServer(
    threads: [AIChatThread]
  ) async throws -> (WorkspaceStore, MobileRemoteCoordinator, String) {
    let transcriptURL = root.appendingPathComponent("server-chat.json")
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(threads: threads, selectedThreadID: nil, settlementSettings: settings),
      legacyURL: transcriptURL
    )
    let suite = "live-push-server-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      codexSendHandlerForTesting: { _, _, _ in "ok" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.configureAIChatHost(AIChatHostIdentity(ref: "press", name: "Celorga on press", kind: .server))
    await store.waitForAIChatTranscriptLoadForTesting()
    let remote = MobileRemoteCoordinator(
      defaults: defaults,
      credentialFile: root.appendingPathComponent("paired-\(UUID().uuidString).json")
    )
    remote.attach(to: store)
    remote.setPairingCodeForTesting("424242")
    let pair = try await call(remote, "POST", "/v1/pair",
                              MobileRemotePairRequest(code: "424242", deviceName: "Laptop"),
                              as: MobileRemotePairResponse.self)
    return (store, remote, pair.accessToken)
  }

  @MainActor
  private func rawCall<Body: Encodable>(
    _ remote: MobileRemoteCoordinator,
    _ method: String,
    _ path: String,
    _ body: Body?,
    token: String?
  ) async throws -> MobileRemoteHTTPResponse {
    var headers = ["Content-Type": "application/json"]
    if let token { headers["Authorization"] = "Bearer \(token)" }
    let data = try body.map { try MobileRemoteProtocol.encoder().encode($0) } ?? Data()
    return await remote.handle(MobileRemoteHTTPRequest(method: method, path: path, headers: headers, body: data))
  }

  @MainActor
  private func call<Body: Encodable, Response: Decodable>(
    _ remote: MobileRemoteCoordinator,
    _ method: String,
    _ path: String,
    _ body: Body?,
    token: String? = nil,
    as type: Response.Type
  ) async throws -> Response {
    let response = try await rawCall(remote, method, path, body, token: token)
    guard (200..<300).contains(response.statusCode) else {
      throw NSError(domain: "LivePushTests", code: response.statusCode, userInfo: [
        NSLocalizedDescriptionKey: String(decoding: response.body, as: UTF8.self),
      ])
    }
    return try MobileRemoteProtocol.decoder().decode(type, from: response.body)
  }
}
