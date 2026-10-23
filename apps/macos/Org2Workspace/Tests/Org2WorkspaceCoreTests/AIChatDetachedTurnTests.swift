import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor RecoveredTurnLog {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

/// OpenOrg can quit, crash, or be rebuilt while an agent turn is running.
/// Afterwards a chat must either follow the turn that is still running or show
/// it as interrupted; it must never look busy with no way to stop or retry.
final class AIChatDetachedTurnTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-detached-turn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    stopWarmServerKeepers()
    try? FileManager.default.removeItem(at: root)
  }

  /// Warm-server keepers run detached from the adapter; stop the ones a test
  /// started so their fake servers do not outlive it.
  private func stopWarmServerKeepers() {
    let directory = root.appendingPathComponent("state/openorg/opencode-servers", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for name in names where name.hasSuffix(".json") {
      guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
            let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pid = (record["pid"] as? NSNumber)?.int32Value, pid > 0
      else { continue }
      kill(pid, SIGTERM)
    }
  }

  // MARK: Stale sends

  func testStaleSendRepairInterruptsOnlyThisHostsTurnsFromAnEarlierProcess() {
    let startedAt = Date()
    let earlier = startedAt.addingTimeInterval(-60)
    func send(_ content: String, host: String?, acceptedAt: Date?, createdAt: Date = earlier) -> AIChatMessage {
      AIChatMessage(
        role: .user,
        content: content,
        createdAt: createdAt,
        deliveryStatus: .sending,
        provenance: host.map {
          AIChatMessageProvenance(executionHostRef: $0, executionHostName: $0, acceptedAt: acceptedAt)
        }
      )
    }
    let local = send("local", host: "desktop-here", acceptedAt: earlier)
    let legacy = send("legacy", host: nil, acceptedAt: nil)
    let remote = send("remote", host: "desktop-there", acceptedAt: earlier)
    let handoff = send("handoff", host: "desktop-here", acceptedAt: nil)
    let acceptedNow = send("accepted by this process", host: "desktop-here", acceptedAt: startedAt.addingTimeInterval(1))
    let thread = AIChatThread(
      title: "Mixed",
      sessionKey: "mixed",
      messages: [local, legacy, remote, handoff, acceptedNow]
    )

    let repaired = WorkspaceStore.interruptStaleLocalAIChatSends(
      in: [thread],
      processStartedAt: startedAt,
      isLocalHost: { $0 == "desktop-here" }
    )

    XCTAssertTrue(repaired.changed)
    XCTAssertEqual(repaired.threads.first?.messages.map(\.deliveryStatus), [
      .interrupted, .sending, .sending, .sending, .sending
    ])
  }

  func testStaleCodexSendIsHeldOnlyWhenManagedRemoteFenceWasPersisted() {
    let startedAt = Date()
    let earlier = startedAt.addingTimeInterval(-60)
    let provenance = AIChatMessageProvenance(
      executionHostRef: "desktop-here",
      executionHostName: "desktop-here",
      acceptedAt: earlier
    )
    let local = AIChatMessage(
      role: .user,
      content: "local Codex",
      createdAt: earlier,
      deliveryStatus: .sending,
      provenance: provenance
    )
    let managedAttemptID = UUID()
    let managed = AIChatMessage(
      role: .user,
      content: "managed remote Codex",
      createdAt: earlier,
      deliveryStatus: .sending,
      provenance: provenance
    ).replacingDeliveryAttempt(
      managedAttemptID,
      status: .sending,
      sendFailure: nil,
      attemptState: .unconfirmed
    )
    let thread = AIChatThread(
      title: "Codex transports",
      runtime: .codex,
      sessionKey: "codex-transports",
      messages: [local, managed]
    )

    let repaired = WorkspaceStore.interruptStaleLocalAIChatSends(
      in: [thread],
      processStartedAt: startedAt,
      isLocalHost: { $0 == "desktop-here" }
    )

    XCTAssertEqual(repaired.threads[0].messages[0].deliveryStatus, .interrupted)
    XCTAssertFalse(repaired.threads[0].messages[0].deliveryIsUnconfirmed)
    XCTAssertEqual(repaired.threads[0].messages[1].deliveryStatus, .sending)
    XCTAssertTrue(repaired.threads[0].messages[1].deliveryIsUnconfirmed)
    XCTAssertEqual(repaired.threads[0].messages[1].effectiveDeliveryAttemptID, managedAttemptID)
  }

  func testStaleSendRepairLeavesRecoverablePendingTurnsAndColdThreads() {
    let startedAt = Date()
    let message = AIChatMessage(
      role: .user,
      content: "Reattach me",
      createdAt: startedAt.addingTimeInterval(-60),
      deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        executionHostRef: "desktop-here",
        acceptedAt: startedAt.addingTimeInterval(-60)
      )
    )
    let recoverable = AIChatThread(
      title: "Recoverable",
      sessionKey: "recoverable",
      messages: [message],
      pendingTurn: AIChatPendingTurn(
        userMessageID: message.id,
        runID: message.id.uuidString.lowercased(),
        agentID: "opencode",
        gatewayMessage: ""
      )
    )
    let cold = AIChatThread(title: "Cold", sessionKey: "cold", messages: [message])
      .metadataOnly()

    let repaired = WorkspaceStore.interruptStaleLocalAIChatSends(
      in: [recoverable, cold],
      processStartedAt: startedAt,
      isLocalHost: { _ in true }
    )

    XCTAssertFalse(repaired.changed)
  }

  /// The reported bug: after a mid-turn restart the chat stayed "working"
  /// with no Stop or Retry. The repaired state must also be saved, or the
  /// next replica refresh brings the busy turn back.
  @MainActor
  func testRelaunchPersistsInterruptionOfThisHostsUnrecoverableTurn() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let hostRef = AIChatHostIdentity.desktop(writer: AIChatTranscriptStore.shared.writerIdentity).ref
    let earlier = Date().addingTimeInterval(-60)
    let stale = AIChatMessage(
      role: .user,
      content: "Rebuilt the app mid-turn",
      createdAt: earlier,
      deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        executionHostRef: hostRef,
        executionHostName: "AiroPress",
        acceptedAt: earlier
      )
    )
    let thread = AIChatThread(
      title: "Mid-turn restart",
      runtime: .openCode,
      destinationID: "missing-destination",
      sessionKey: "mid-turn-restart",
      messages: [stale]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [thread],
        selectedThreadID: thread.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )

    let store = try makeStore(transcriptURL: transcriptURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == thread.id })?.messages.first?.deliveryStatus,
      .interrupted
    )
    let persisted = AIChatTranscriptStore.shared.loadThread(
      id: thread.id,
      metadata: thread.metadataOnly(),
      legacyURL: transcriptURL
    )
    XCTAssertEqual(persisted?.messages.first?.deliveryStatus, .interrupted)
  }

  /// Threads outside the eager working set load without messages, so the
  /// launch repair cannot see their stale sends until they are opened.
  @MainActor
  func testOpeningAColdThreadInterruptsItsStaleLocalSend() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let hostRef = AIChatHostIdentity.desktop(writer: AIChatTranscriptStore.shared.writerIdentity).ref
    let earlier = Date().addingTimeInterval(-3_600)
    let stale = AIChatMessage(
      role: .user,
      content: "Rebuilt the app mid-turn",
      createdAt: earlier,
      deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        executionHostRef: hostRef,
        executionHostName: "AiroPress",
        acceptedAt: earlier
      )
    )
    let cold = AIChatThread(
      title: "Cold mid-turn restart",
      createdAt: earlier,
      updatedAt: earlier,
      runtime: .openCode,
      destinationID: "missing-destination",
      sessionKey: "cold-mid-turn",
      messages: [stale]
    )
    let fillers = (0..<(AIChatTranscriptStore.eagerWorkingSetLimit + 4)).map { index in
      AIChatThread(
        title: "Recent \(index)",
        sessionKey: "recent-\(index)",
        messages: [AIChatMessage(role: .user, content: "hello \(index)")]
      )
    }
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: fillers + [cold],
        selectedThreadID: fillers[0].id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )

    let store = try makeStore(transcriptURL: transcriptURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == cold.id })?.messages.count,
      0,
      "The fixture thread must start cold"
    )

    let hydrated = await store.hydratedAIChatThreadForDetail(cold.id)
    XCTAssertNotNil(hydrated)
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    XCTAssertFalse(store.isAIChatThreadRunning(cold.id))
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == cold.id })?.messages.first?.deliveryStatus,
      .interrupted
    )
    let persisted = AIChatTranscriptStore.shared.loadThread(
      id: cold.id,
      metadata: cold.metadataOnly(),
      legacyURL: transcriptURL
    )
    XCTAssertEqual(persisted?.messages.first?.deliveryStatus, .interrupted)
  }

  /// A saved remote OpenCode turn is resumed (reattached) after relaunch
  /// rather than failed as an unavailable destination.
  @MainActor
  func testRemoteOpenCodePendingTurnIsRecoveredAfterRelaunch() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let destination = AIChatDestinationConfiguration(
      name: "OpenCode",
      mention: "opencode-press",
      adapter: .openCodeRemote,
      endpoint: "press"
    )
    let user = AIChatMessage(role: .user, content: "Keep going", deliveryStatus: .sending)
    let pendingTurn = AIChatPendingTurn(
      userMessageID: user.id,
      runID: user.id.uuidString.lowercased(),
      agentID: "opencode",
      destinationID: destination.id,
      gatewayMessage: ""
    )
    let thread = AIChatThread(
      title: "Remote turn",
      runtime: .openCode,
      destinationID: destination.id,
      sessionKey: "remote-turn",
      messages: [user],
      pendingTurn: pendingTurn
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [thread],
        selectedThreadID: thread.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let recovered = RecoveredTurnLog()
    let suite = "detached-turn-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      aiChatRecoveryHandler: { turn, _ in
        await recovered.append(turn.runID)
        return "Finished while OpenOrg restarted"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.updateAIChatDestination(destination)

    await store.recoverPendingAIChatTurns()

    let runIDs = await recovered.values
    XCTAssertEqual(runIDs, [pendingTurn.runID])
    let messages = store.aiChatThreads.first(where: { $0.id == thread.id })?.messages ?? []
    XCTAssertEqual(messages.map(\.content), ["Keep going", "Finished while OpenOrg restarted"])
    XCTAssertEqual(messages.first?.deliveryStatus, .sent)
    XCTAssertNil(store.aiChatThreads.first(where: { $0.id == thread.id })?.pendingTurn)
    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))
  }

  // MARK: Remote OpenCode supervisor

  /// Runs the real remote supervisor scripts against a fake `opencode`: the
  /// turn keeps running after OpenOrg's channel closes, and `attach` replays
  /// its whole event stream and exit status.
  func testRemoteTurnOutlivesItsChannelAndAttachReplaysIt() throws {
    let python = try pythonExecutable()
    let environment = try fakeOpenCodeEnvironment(runScript: """
      echo '{"type":"step_start","sessionID":"ses_detached","part":{}}'
      echo '{"type":"text","sessionID":"ses_detached","part":{"text":"Partial"}}'
      sleep 1
      echo '{"type":"text","sessionID":"ses_detached","part":{"text":" and done."}}'
      """)
    let threadID = UUID().uuidString.lowercased()

    let run = try startPython(
      python,
      source: OpenCodeClient.managedRemotePythonBootstrap,
      input: runPayload(threadID: threadID, token: "turn-1"),
      environment: environment
    )
    // Read until the turn starts streaming, then disappear like a quitting app.
    let firstLines = try readLines(run.output, count: 2)
    XCTAssertTrue(firstLines[0].contains("openorg_server"))
    XCTAssertTrue(firstLines[1].contains("ses_detached"))
    try run.output.close()
    run.process.waitUntilExit()

    let attach = try runPython(
      python,
      source: OpenCodeClient.managedRemoteAttachPythonBootstrap,
      input: #"{"threadID":"\#(threadID)","runToken":"turn-1"}"#,
      environment: environment
    )
    XCTAssertEqual(attach.status, 0)
    XCTAssertTrue(attach.output.contains("Partial"))
    XCTAssertTrue(attach.output.contains(" and done."))

    let again = try runPython(
      python,
      source: OpenCodeClient.managedRemoteAttachPythonBootstrap,
      input: #"{"threadID":"\#(threadID)","runToken":"turn-1"}"#,
      environment: environment
    )
    XCTAssertEqual(again.status, OpenCodeClient.detachedRunMissingStatus)
  }

  /// A connected client may be asleep rather than gone, so a finished turn
  /// keeps its record and complete event stream for a later collector even
  /// when the channel stayed open.
  func testFinishedTurnKeepsItsRecordForALaterCollector() async throws {
    let python = try pythonExecutable()
    let environment = try fakeOpenCodeEnvironment(runScript: """
      echo '{"type":"step_start","sessionID":"ses_kept","part":{}}'
      echo '{"type":"text","sessionID":"ses_kept","part":{"text":"Delivered "}}'
      echo '{"type":"text","sessionID":"ses_kept","part":{"text":"while asleep."}}'
      """)
    let threadID = UUID()
    let run = try runPython(
      python,
      source: OpenCodeClient.managedRemotePythonBootstrap,
      input: runPayload(threadID: threadID.uuidString.lowercased(), token: "turn-kept"),
      environment: environment
    )
    XCTAssertEqual(run.status, 0)
    XCTAssertTrue(run.output.contains("while asleep."))

    let directory = OpenCodeClient.localRunDirectory(environment: environment)
    let wrongToken = await OpenCodeClient.finishedLocalRun(
      threadID: threadID, runToken: "other-turn", directory: directory
    )
    XCTAssertNil(wrongToken)
    let collected = await OpenCodeClient.finishedLocalRun(
      threadID: threadID, runToken: "turn-kept", directory: directory
    )
    guard case .success(let result) = collected else {
      return XCTFail("expected the finished turn, got \(String(describing: collected))")
    }
    XCTAssertEqual(result.sessionID, "ses_kept")
    XCTAssertEqual(result.reply, "Delivered while asleep.")

    // The starting host can still attach afterwards, which consumes it.
    let attach = try runPython(
      python,
      source: OpenCodeClient.managedRemoteAttachPythonBootstrap,
      input: #"{"threadID":"\#(threadID.uuidString.lowercased())","runToken":"turn-kept"}"#,
      environment: environment
    )
    XCTAssertEqual(attach.status, 0)
    XCTAssertTrue(attach.output.contains("while asleep."))
  }

  /// When the laptop that started a managed remote OpenCode turn is asleep,
  /// the OpenOrg host on the harness machine delivers the finished turn, and
  /// the laptop's own delivery on waking merges into the same reply.
  @MainActor
  func testHarnessHostDeliversATurnWhoseStartingHostIsOffline() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let runDirectory = root.appendingPathComponent("runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let user = AIChatMessage(
      role: .user,
      content: "Fix it",
      deliveryStatus: .sending,
      provenance: AIChatMessageProvenance(
        originClient: .desktop,
        receivedByHostRef: "desktop-laptop",
        receivedByHostName: "Laptop",
        executionHostRef: "desktop-laptop",
        executionHostName: "Laptop",
        acceptedAt: Date()
      )
    )
    let pendingTurn = AIChatPendingTurn(
      userMessageID: user.id,
      runID: user.id.uuidString.lowercased(),
      idempotencyKey: user.id.uuidString.lowercased(),
      dispatchOwnerID: "laptop.local",
      agentID: "opencode",
      destinationID: "laptop-only-opencode-on-press",
      gatewayMessage: ""
    )
    let thread = AIChatThread(
      title: "Orphaned turn",
      runtime: .openCode,
      destinationID: "laptop-only-opencode-on-press",
      sessionKey: "orphaned-turn",
      messages: [user],
      pendingTurn: pendingTurn
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [thread],
        selectedThreadID: thread.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let base = runDirectory.appendingPathComponent(thread.id.uuidString.lowercased())
    try #"{"version":1,"threadID":"\#(thread.id.uuidString.lowercased())","token":"\#(pendingTurn.runID)","pid":1,"updatedAt":0,"state":"finished","exitCode":0}"#
      .write(to: base.appendingPathExtension("json"), atomically: true, encoding: .utf8)
    try """
      {"type":"step_start","sessionID":"ses_orphan","part":{}}
      {"type":"text","sessionID":"ses_orphan","part":{"text":"Fixed while the laptop slept."}}

      """.write(to: base.appendingPathExtension("events.jsonl"), atomically: true, encoding: .utf8)

    let store = try makeStore(transcriptURL: transcriptURL)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.openCodeLocalRunDirectory = runDirectory

    let replyID = WorkspaceStore.openCodeRemoteReplyID(for: user.id)
    let deadline = Date().addingTimeInterval(10)
    var messages: [AIChatMessage] = []
    while Date() < deadline {
      store.adoptOrphanedOpenCodeTurns()
      try await Task.sleep(nanoseconds: 50_000_000)
      messages = store.aiChatThreads.first(where: { $0.id == thread.id })?.messages ?? []
      if messages.count == 2 { break }
    }
    XCTAssertEqual(messages.map(\.content), ["Fix it", "Fixed while the laptop slept."])
    XCTAssertEqual(messages.last?.id, replyID)
    XCTAssertEqual(messages.first?.deliveryStatus, .sent)
    let adopted = store.aiChatThreads.first(where: { $0.id == thread.id })
    XCTAssertNil(adopted?.pendingTurn)
    XCTAssertEqual(adopted?.runtimeThreadID(forDestinationID: "laptop-only-opencode-on-press"), "ses_orphan")
    // The record stays for the laptop, which collects it when it wakes.
    XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathExtension("json").path))

    // Running again must not deliver a second copy.
    store.adoptOrphanedOpenCodeTurns()
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == thread.id })?.messages.count, 2)
  }

  /// A host that recovers a remote OpenCode turn another host already
  /// delivered settles it instead of adding a duplicate reply.
  @MainActor
  func testRecoveredRemoteOpenCodeReplyMergesWithAnAdoptedCopy() async throws {
    let transcriptURL = root.appendingPathComponent("chat.json")
    let destination = AIChatDestinationConfiguration(
      name: "OpenCode",
      mention: "opencode-press",
      adapter: .openCodeRemote,
      endpoint: "press"
    )
    let user = AIChatMessage(role: .user, content: "Keep going", deliveryStatus: .sending)
    let adoptedReply = AIChatMessage(
      id: WorkspaceStore.openCodeRemoteReplyID(for: user.id),
      role: .assistant,
      content: "Finished while the laptop slept"
    )
    let pendingTurn = AIChatPendingTurn(
      userMessageID: user.id,
      runID: user.id.uuidString.lowercased(),
      agentID: "opencode",
      destinationID: destination.id,
      gatewayMessage: ""
    )
    let thread = AIChatThread(
      title: "Remote turn",
      runtime: .openCode,
      destinationID: destination.id,
      sessionKey: "remote-turn",
      messages: [user, adoptedReply],
      pendingTurn: pendingTurn
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [thread],
        selectedThreadID: thread.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let suite = "detached-turn-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      aiChatRecoveryHandler: { _, _ in "Finished while the laptop slept" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.updateAIChatDestination(destination)

    await store.recoverPendingAIChatTurns()

    let recovered = store.aiChatThreads.first(where: { $0.id == thread.id })
    XCTAssertEqual(recovered?.messages.map(\.content), ["Keep going", "Finished while the laptop slept"])
    XCTAssertEqual(recovered?.messages.first?.deliveryStatus, .sent)
    XCTAssertNil(recovered?.pendingTurn)
  }

  func testRemoteStopEndsADetachedTurn() throws {
    let python = try pythonExecutable()
    let environment = try fakeOpenCodeEnvironment(runScript: """
      echo '{"type":"step_start","sessionID":"ses_stop","part":{}}'
      exec sleep 60
      """)
    let threadID = UUID().uuidString.lowercased()
    let run = try startPython(
      python,
      source: OpenCodeClient.managedRemotePythonBootstrap,
      input: runPayload(threadID: threadID, token: "turn-2"),
      environment: environment
    )
    _ = try readLines(run.output, count: 2)

    let stop = try runPython(
      python,
      source: OpenCodeClient.managedRemoteStopPythonBootstrap,
      input: #"{"threadID":"\#(threadID)"}"#,
      environment: environment
    )
    XCTAssertEqual(stop.status, 0)
    let deadline = Date().addingTimeInterval(10)
    while run.process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    XCTAssertFalse(run.process.isRunning, "stop must end the supervisor and its turn")
    if run.process.isRunning { run.process.terminate() }
    // The session runs inside the shared warm server, which outlives the
    // turn's client; stopping must interrupt the session there too.
    let apiCalls = (try? String(
      contentsOf: root.appendingPathComponent("api-calls"),
      encoding: .utf8
    )) ?? ""
    XCTAssertTrue(apiCalls.contains("session.interrupt"), apiCalls)
    XCTAssertTrue(apiCalls.contains("sessionID=ses_stop"), apiCalls)
  }

  /// A cold `opencode serve` costs about a second per turn. Turns with the
  /// same configuration reuse one warm server; its password reaches the
  /// client for steering. A different configuration gets its own server.
  func testRemoteTurnsReuseOneWarmServerPerConfiguration() throws {
    let python = try pythonExecutable()
    let environment = try fakeOpenCodeEnvironment(runScript: """
      echo '{"type":"step_start","sessionID":"ses_warm","part":{}}'
      echo '{"type":"text","sessionID":"ses_warm","part":{"text":"ok"}}'
      """)
    func server(_ output: String) throws -> (url: String, password: String) {
      let line = try XCTUnwrap(output.split(separator: "\n").first)
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      )
      XCTAssertEqual(object["type"] as? String, "openorg_server")
      return (
        try XCTUnwrap(object["url"] as? String),
        try XCTUnwrap(object["password"] as? String)
      )
    }

    let first = try runPython(
      python,
      source: OpenCodeClient.managedRemotePythonBootstrap,
      input: runPayload(threadID: UUID().uuidString.lowercased(), token: "warm-1"),
      environment: environment
    )
    let second = try runPython(
      python,
      source: OpenCodeClient.managedRemotePythonBootstrap,
      input: runPayload(threadID: UUID().uuidString.lowercased(), token: "warm-2"),
      environment: environment
    )
    XCTAssertEqual(first.status, 0)
    XCTAssertEqual(second.status, 0)
    XCTAssertTrue(second.output.contains("ok"))
    let firstServer = try server(first.output)
    let secondServer = try server(second.output)
    XCTAssertEqual(firstServer.url, secondServer.url)
    XCTAssertEqual(firstServer.password, secondServer.password)
    XCTAssertGreaterThanOrEqual(firstServer.password.count, 32)
    let serves = { (try? String(contentsOf: self.root.appendingPathComponent("serves"), encoding: .utf8)) ?? "" }
    XCTAssertEqual(serves().split(separator: "\n").count, 1, "the second turn reused the warm server")

    let other = try runPython(
      python,
      source: OpenCodeClient.managedRemotePythonBootstrap,
      input: runPayload(
        threadID: UUID().uuidString.lowercased(),
        token: "warm-3",
        configuration: "read-only sandbox"
      ),
      environment: environment
    )
    XCTAssertEqual(other.status, 0)
    XCTAssertNotEqual(try server(other.output).url, firstServer.url)
    XCTAssertEqual(serves().split(separator: "\n").count, 2)
    let apiCalls = (try? String(contentsOf: root.appendingPathComponent("api-calls"), encoding: .utf8)) ?? ""
    XCTAssertFalse(apiCalls.contains("session.interrupt"), "finished turns are not interrupted")
  }

  func testAttachReportsAMissingTurn() throws {
    let python = try pythonExecutable()
    let environment = try fakeOpenCodeEnvironment(runScript: "true")
    let attach = try runPython(
      python,
      source: OpenCodeClient.managedRemoteAttachPythonBootstrap,
      input: #"{"threadID":"\#(UUID().uuidString.lowercased())"}"#,
      environment: environment
    )
    XCTAssertEqual(attach.status, OpenCodeClient.detachedRunMissingStatus)
  }

  // MARK: Helpers

  @MainActor
  private func makeStore(transcriptURL: URL) throws -> WorkspaceStore {
    let suite = "detached-turn-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    return store
  }

  private func pythonExecutable() throws -> URL {
    for path in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
    where FileManager.default.isExecutableFile(atPath: path) {
      let probe = Process()
      probe.executableURL = URL(fileURLWithPath: path)
      probe.arguments = ["-c", "import sys"]
      probe.standardOutput = FileHandle.nullDevice
      probe.standardError = FileHandle.nullDevice
      try? probe.run()
      probe.waitUntilExit()
      if probe.terminationStatus == 0 { return URL(fileURLWithPath: path) }
    }
    throw XCTSkip("python3 is not available")
  }

  /// `serve` really listens (the adapter probes a reused server) and logs each
  /// launch to `$HOME/serves`; `api` logs its arguments to `$HOME/api-calls`.
  private func fakeOpenCodeEnvironment(runScript: String) throws -> [String: String] {
    let python = try pythonExecutable()
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let opencode = bin.appendingPathComponent("opencode")
    try """
      #!/bin/sh
      case "$1" in
        serve)
          echo serve >> "$HOME/serves"
          exec "\(python.path)" -c 'import socket, time; s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(8); print("server listening on http://127.0.0.1:%d" % s.getsockname()[1], flush=True); time.sleep(120)'
          ;;
        api)
          echo "$*" >> "$HOME/api-calls"
          exit 0
          ;;
      esac
      \(runScript)
      """.write(to: opencode, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opencode.path)
    return [
      "PATH": "\(bin.path):/usr/bin:/bin",
      "HOME": root.path,
      "XDG_STATE_HOME": root.appendingPathComponent("state").path
    ]
  }

  private func runPayload(threadID: String, token: String, configuration: String = "{}") -> String {
    let workspace = root.appendingPathComponent("workspace").path
    return #"{"workspacePath":"\#(workspace)","threadID":"\#(threadID)","runToken":"\#(token)","arguments":["run","--format","json"],"message":"hi","configuration":"\#(configuration)","attachments":[]}"#
  }

  private func startPython(
    _ python: URL,
    source: String,
    input: String,
    environment: [String: String]
  ) throws -> (process: Process, output: FileHandle) {
    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    process.executableURL = python
    process.arguments = ["-c", source]
    process.environment = environment
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice
    try process.run()
    try standardInput.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try standardInput.fileHandleForWriting.close()
    addTeardownBlock { if process.isRunning { process.terminate() } }
    return (process, standardOutput.fileHandleForReading)
  }

  private func runPython(
    _ python: URL,
    source: String,
    input: String,
    environment: [String: String]
  ) throws -> (status: Int32, output: String) {
    let run = try startPython(python, source: source, input: input, environment: environment)
    let data = try run.output.readToEnd() ?? Data()
    run.process.waitUntilExit()
    return (run.process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private func readLines(_ handle: FileHandle, count: Int) throws -> [String] {
    var lines: [String] = []
    var buffer = Data()
    while lines.count < count, let byte = try handle.read(upToCount: 1), !byte.isEmpty {
      if byte[byte.startIndex] == 0x0A {
        lines.append(String(decoding: buffer, as: UTF8.self))
        buffer.removeAll()
      } else {
        buffer.append(byte)
      }
    }
    return lines
  }
}
