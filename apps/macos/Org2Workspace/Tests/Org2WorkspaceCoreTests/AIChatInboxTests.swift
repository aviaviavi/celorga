import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatInboxTests: XCTestCase {
  @MainActor
  func testEmbeddedCodexThreadPostToolUsesTheSharedQueueContract() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-tool-\(UUID().uuidString)", isDirectory: true)
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatInboxToolTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let threadID = store.createAIChatThread(runtime: .codex)
    store.flushDeferredAIChatTranscriptPersistence()
    try await store.waitForAIChatTranscriptPersistenceForTesting()
    XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))
    XCTAssertTrue(try String(contentsOf: transcript).lowercased().contains(threadID.uuidString.lowercased()))

    let result = await store.handleCodexThreadPostTool(.object([
      "threadId": .string(threadID.uuidString.lowercased()),
      "message": .string("The delegated check is complete."),
      "author": .string("Build Scout"),
      "agentRef": .string("build-scout"),
      "source": .string("run:build-42"),
      "idempotencyKey": .string("build-42:complete"),
    ]))

    XCTAssertTrue(result.success, result.text)
    let delivered = try XCTUnwrap(
      store.aiChatThreads.first(where: { $0.id == threadID })?.messages.first
    )
    XCTAssertEqual(delivered.content, "The delegated check is complete.")
    XCTAssertEqual(delivered.authorLabel, "Build Scout")
    XCTAssertEqual(delivered.authorAgentRef, "build-scout")
    XCTAssertEqual(delivered.source, "run:build-42")
    XCTAssertFalse(store.isAIChatThreadRunning(threadID))
  }

  @MainActor
  func testBackgroundAgentMessageIsDeliveredWithoutStartingATurn() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-inbox-\(UUID().uuidString)", isDirectory: true)
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatInboxTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let threadID = store.createAIChatThread(runtime: .codex)
    store.settleAIChatThread(threadID)
    XCTAssertTrue(store.aiChatThreads.first(where: { $0.id == threadID })?.isSettled == true)
    let messageID = UUID()
    let inbox = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let envelope = inbox.appendingPathComponent("\(messageID.uuidString.lowercased()).json")
    let payload: [String: Any] = [
      "schema": "org2:ai-chat-inbox-message:v1",
      "id": messageID.uuidString.lowercased(),
      "threadID": threadID.uuidString.lowercased(),
      "content": "The background export finished.",
      "createdAt": "2026-08-19T19:30:00.000Z",
      "authorLabel": "Revenue Scout",
      "authorAgentRef": "agent-profile-revenue-scout",
      "source": "run:export-42"
    ]
    try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
      .write(to: envelope, options: .atomic)

    await store.drainAIChatInbox()

    let delivered = try XCTUnwrap(
      store.aiChatThreads.first(where: { $0.id == threadID })
    )
    XCTAssertEqual(delivered.messages.count, 1)
    XCTAssertEqual(delivered.messages[0].id, messageID)
    XCTAssertEqual(delivered.messages[0].role, .assistant)
    XCTAssertEqual(delivered.messages[0].content, "The background export finished.")
    XCTAssertEqual(delivered.messages[0].authorLabel, "Revenue Scout")
    XCTAssertEqual(delivered.messages[0].authorAgentRef, "agent-profile-revenue-scout")
    XCTAssertEqual(delivered.messages[0].source, "run:export-42")
    XCTAssertEqual(delivered.unreadMessageCount, 1)
    XCTAssertFalse(delivered.isSettled)
    XCTAssertFalse(store.isAIChatThreadRunning(threadID))
    XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))

    let restored = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let restoredMessage = try XCTUnwrap(
      restored.aiChatThreads.first(where: { $0.id == threadID })?.messages.first
    )
    XCTAssertEqual(restoredMessage.authorLabel, "Revenue Scout")
    XCTAssertEqual(restoredMessage.authorAgentRef, "agent-profile-revenue-scout")

    try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
      .write(to: envelope, options: .atomic)
    await store.drainAIChatInbox()
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == threadID })?.messages.count,
      1
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
  }

  @MainActor
  func testBackgroundEnvelopeRemainsWhenTranscriptCannotBeDurablySaved() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-inbox-save-failure-\(UUID().uuidString)", isDirectory: true)
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatInboxFailureTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let threadID = store.createAIChatThread(runtime: .codex)
    store.flushDeferredAIChatTranscriptPersistence()

    let inbox = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let messageID = UUID()
    let envelope = inbox.appendingPathComponent("\(messageID.uuidString.lowercased()).json")
    try JSONSerialization.data(withJSONObject: [
      "schema": "org2:ai-chat-inbox-message:v1",
      "id": messageID.uuidString.lowercased(),
      "threadID": threadID.uuidString.lowercased(),
      "content": "Keep this durable delivery queued.",
      "createdAt": "2026-08-19T19:30:00.000Z",
      "authorLabel": "Build Scout",
    ], options: [.prettyPrinted]).write(to: envelope, options: .atomic)
    store.aiChatTranscriptSaverForTesting = {
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [NSLocalizedDescriptionKey: "Injected transcript failure"]
      )
    }

    await store.drainAIChatInbox()

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: envelope.path),
      "The inbox envelope is the recovery source until the transcript write is durable"
    )
    XCTAssertTrue(store.errorText?.contains("Injected transcript failure") == true)
  }

  @MainActor
  func testManagedRemoteInboxSendPersistsBeforeStartAndReturnsExactRetryReceipt() async throws {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cgw-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatInboxManagedRemoteTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let messageID = UUID()
    let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
    let controlDirectory = codexHome.appendingPathComponent("app-server-control", isDirectory: true)
    try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
    let socketPath = controlDirectory.appendingPathComponent("app-server-control.sock")
    let startLog = root.appendingPathComponent("physical-starts.jsonl")
    let acceptedPath = root.appendingPathComponent("accepted-attempt.json")
    let daemonScript = root.appendingPathComponent("fake-daemon.py")
    try CodexAppServerClientTests.fakeManagedRemoteDaemonScript.write(
      to: daemonScript,
      atomically: true,
      encoding: .utf8
    )
    let daemon = Process()
    daemon.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3")
    daemon.arguments = [
      daemonScript.path,
      socketPath.path,
      startLog.path,
      acceptedPath.path,
      "0",
      "drop-response-first"
    ]
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = FileHandle.nullDevice
    try daemon.run()
    defer {
      if daemon.isRunning { daemon.terminate() }
      daemon.waitUntilExit()
    }
    let socketDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: socketPath.path), Date() < socketDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath.path))

    let adapterScript = root.appendingPathComponent("adapter.py")
    try CodexAppServerClient.managedRemoteJSONLAdapter.write(
      to: adapterScript,
      atomically: true,
      encoding: .utf8
    )
    let claimRoot = root.appendingPathComponent("claims", isDirectory: true)
    let fakeSSH = root.appendingPathComponent("fake-managed-ssh")
    let launcher = #"""
    #!/bin/sh
    export CODEX_HOME='\#(codexHome.path)'
    export CELORGA_MANAGED_REMOTE_CLAIM_ROOT='\#(claimRoot.path)'
    exec /usr/local/bin/python3 '\#(adapterScript.path)'
    """#
    try launcher.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      codexManagedRemoteSSHExecutableURLForTesting: fakeSSH,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let destinationID = store.addAIChatDestination(adapter: .codexManagedRemote)
    var destination = try XCTUnwrap(store.aiChatDestination(id: destinationID))
    destination.endpoint = "isolated.test"
    destination.workspaceRoot = root.path
    store.updateAIChatDestination(destination)
    store.createAIChatThread(destinationID: destinationID)
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.flushDeferredAIChatTranscriptPersistence()
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    let inbox = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let envelope = inbox.appendingPathComponent("\(messageID.uuidString.lowercased()).json")
    try JSONSerialization.data(withJSONObject: [
      "schema": "org2:ai-chat-send-message:v1",
      "id": messageID.uuidString.lowercased(),
      "threadID": threadID.uuidString.lowercased(),
      "content": "Run this managed request exactly once.",
      "createdAt": "2026-10-16T08:00:00.000Z",
      "authorLabel": "Isolated test client",
      "destinationID": destinationID,
    ]).write(to: envelope, options: .atomic)

    await store.drainAIChatInbox()
    let firstDeadline = Date().addingTimeInterval(8)
    while Date() < firstDeadline {
      if FileManager.default.fileExists(atPath: startLog.path),
         store.aiChatMessages.first(where: { $0.id == messageID })?.displayedSendFailure != nil {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    let held = try XCTUnwrap(store.aiChatMessages.first(where: { $0.id == messageID }))
    XCTAssertEqual(held.deliveryStatus, .sending)
    XCTAssertTrue(held.deliveryIsUnconfirmed)
    XCTAssertEqual(held.effectiveDeliveryAttemptID, messageID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
    let firstStarts = try String(contentsOf: startLog, encoding: .utf8)
      .split(separator: "\n")
    XCTAssertEqual(firstStarts.count, 1)

    destination.workspaceRoot = root.appendingPathComponent("changed-workspace").path
    store.updateAIChatDestination(destination)
    let drifted = await store.retryAIChatMessageAwaitingDelivery(messageID, timeout: .seconds(3))
    XCTAssertEqual(drifted.state, .unconfirmed)
    XCTAssertEqual(drifted.messageID, messageID)
    XCTAssertEqual(drifted.deliveryAttemptID, messageID)
    XCTAssertEqual(
      try String(contentsOf: startLog, encoding: .utf8).split(separator: "\n").count,
      1
    )

    destination.workspaceRoot = root.path
    store.updateAIChatDestination(destination)
    let receipt = await store.retryAIChatMessageAwaitingDelivery(messageID, timeout: .seconds(8))
    XCTAssertEqual(receipt.state, .started)
    XCTAssertEqual(receipt.messageID, messageID)
    XCTAssertEqual(receipt.deliveryAttemptID, messageID)
    XCTAssertEqual(receipt.runtimeThreadID, "thr-atomic")
    XCTAssertEqual(receipt.turnID, "turn-atomic")
#if DEBUG
    let terminalDeadline = Date().addingTimeInterval(3)
    while store.codexDeliveryReceiptForTesting(messageID)?.state != .completed,
          Date() < terminalDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let terminalReceipt = try XCTUnwrap(store.codexDeliveryReceiptForTesting(messageID))
    XCTAssertEqual(terminalReceipt.state, .completed)
    XCTAssertEqual(terminalReceipt.messageID, messageID)
    XCTAssertEqual(terminalReceipt.deliveryAttemptID, messageID)
    XCTAssertEqual(terminalReceipt.runtimeThreadID, "thr-atomic")
    XCTAssertEqual(terminalReceipt.turnID, "turn-atomic")
    let payload = terminalReceipt.openOrgServerRetryPayload()
    XCTAssertEqual(payload["turnStarted"] as? Bool, true)
    XCTAssertEqual(payload["messageID"] as? String, messageID.uuidString.lowercased())
    XCTAssertEqual(
      payload["deliveryAttemptID"] as? String,
      terminalReceipt.deliveryAttemptID?.uuidString.lowercased()
    )
#endif
    let allStarts = try String(contentsOf: startLog, encoding: .utf8)
      .split(separator: "\n")
    XCTAssertEqual(allStarts.count, 1)

    try JSONSerialization.data(withJSONObject: [
      "schema": "org2:ai-chat-send-message:v1",
      "id": messageID.uuidString.lowercased(),
      "threadID": threadID.uuidString.lowercased(),
      "content": "Run this managed request exactly once.",
      "createdAt": "2026-10-16T08:00:00.000Z",
      "authorLabel": "Isolated test client",
      "destinationID": destinationID,
    ]).write(to: envelope, options: .atomic)
    await store.drainAIChatInbox()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
    XCTAssertEqual(
      try String(contentsOf: startLog, encoding: .utf8).split(separator: "\n").count,
      1
    )
    await store.shutdownAIChatTransports()
  }

  @MainActor
  func testDurableSaveSucceedsWhenAnotherThreadChangesDuringTheBarrier() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-inbox-concurrent-\(UUID().uuidString)", isDirectory: true)
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatInboxConcurrentTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let threadID = store.createAIChatThread(runtime: .codex)
    store.flushDeferredAIChatTranscriptPersistence()

    let inbox = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let messageID = UUID()
    let envelope = inbox.appendingPathComponent("\(messageID.uuidString.lowercased()).json")
    try JSONSerialization.data(withJSONObject: [
      "schema": "org2:ai-chat-inbox-message:v1",
      "id": messageID.uuidString.lowercased(),
      "threadID": threadID.uuidString.lowercased(),
      "content": "Delivered while another chat is busy.",
      "createdAt": "2026-10-09T19:30:00.000Z",
      "authorLabel": "Build Scout",
    ], options: [.prettyPrinted]).write(to: envelope, options: .atomic)

    // Another chat changes while this state is being committed, as a
    // streaming OpenClaw or Codex turn does. The committed state still holds
    // this delivery, so the delivery must not be reported as unsaved.
    var changedAnotherThread = false
    store.aiChatTranscriptSaverForTesting = {
      guard !changedAnotherThread else { return }
      changedAnotherThread = true
      MainActor.assumeIsolated {
        _ = store.createAIChatThread(runtime: .codex)
      }
    }

    await store.drainAIChatInbox()

    XCTAssertTrue(changedAnotherThread)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: envelope.path),
      "A newer change in another thread must not fail an already durable delivery"
    )
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == threadID })?.messages.map(\.id),
      [messageID]
    )
    XCTAssertTrue(
      store.hasUnpersistedAIChatTranscriptMutationForTesting,
      "The newer change is saved on its own schedule"
    )
  }

  @MainActor
  func testOperationJournalAppliesEveryKindInOrderAndPersistsTheResult() async throws {
    let root = temporaryOperationCorpus("all-kinds")
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatOperationApplicationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let autoSettledID = store.createAIChatThread(runtime: .codex)
    let explicitlySettledID = store.createAIChatThread(runtime: .codex)
    _ = store.createAIChatThread(runtime: .codex)

    let configure = try writeOperation([
      "kind": "configure-auto-settle",
      "autoSettleAfterSeconds": 123.5,
    ], id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", createdAt: "2026-08-20T10:00:00.000Z", root: root)
    let autoSettle = try writeOperation([
      "kind": "auto-settle",
      "evaluatedAt": "2030-08-20T10:00:00.000Z",
    ], id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", createdAt: "2026-08-20T10:01:00.000Z", root: root)
    let reopen = try writeOperation([
      "kind": "reopen-thread",
      "threadID": explicitlySettledID.uuidString.lowercased(),
    ], id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", createdAt: "2026-08-20T10:02:00.000Z", root: root)
    let settle = try writeOperation([
      "kind": "settle-thread",
      "threadID": explicitlySettledID.uuidString.lowercased(),
      "settledAt": "2026-08-20T12:00:00.000Z",
    ], id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", createdAt: "2026-08-20T10:03:00.000Z", root: root)

    await store.drainAIChatInbox()

    XCTAssertEqual(store.aiChatThreadSettlementSettings.autoSettleAfterSeconds, 123.5)
    let autoSettled = try XCTUnwrap(
      store.aiChatThreads.first(where: { $0.id == autoSettledID })
    )
    XCTAssertTrue(autoSettled.isSettled)
    XCTAssertEqual(
      try XCTUnwrap(autoSettled.settledAt).timeIntervalSince1970,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-08-20T10:00:00Z"))
        .timeIntervalSince1970,
      accuracy: 0.001
    )
    let explicitlySettled = try XCTUnwrap(
      store.aiChatThreads.first(where: { $0.id == explicitlySettledID })
    )
    XCTAssertTrue(explicitlySettled.isSettled)
    XCTAssertEqual(
      try XCTUnwrap(explicitlySettled.settledAt).timeIntervalSince1970,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z"))
        .timeIntervalSince1970,
      accuracy: 0.001
    )
    for file in [configure, autoSettle, reopen, settle] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    let restored = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    await restored.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(restored.aiChatThreadSettlementSettings.autoSettleAfterSeconds, 123.5)
    XCTAssertTrue(
      restored.aiChatThreads.first(where: { $0.id == autoSettledID })?.isSettled == true
    )
    XCTAssertTrue(
      restored.aiChatThreads.first(where: { $0.id == explicitlySettledID })?.isSettled == true
    )
  }

  @MainActor
  func testOperationRemainsUntilAnIdempotentReplayIsDurable() async throws {
    let root = temporaryOperationCorpus("durability-replay")
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatOperationDurabilityTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let operation = try writeOperation([
      "kind": "configure-auto-settle",
      "autoSettleAfterSeconds": 9876,
    ], id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", createdAt: "2026-08-20T10:00:00.000Z", root: root)
    store.aiChatTranscriptSaverForTesting = {
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [NSLocalizedDescriptionKey: "Injected operation durability failure"]
      )
    }

    await store.drainAIChatInbox()

    XCTAssertEqual(store.aiChatThreadSettlementSettings.autoSettleAfterSeconds, 9876)
    XCTAssertTrue(FileManager.default.fileExists(atPath: operation.path))
    XCTAssertTrue(store.errorText?.contains("not persisted durably") == true)

    var successfulDurabilityBarriers = 0
    store.aiChatTranscriptSaverForTesting = { successfulDurabilityBarriers += 1 }
    await store.drainAIChatInbox()

    XCTAssertEqual(successfulDurabilityBarriers, 1)
    XCTAssertEqual(store.aiChatThreadSettlementSettings.autoSettleAfterSeconds, 9876)
    XCTAssertFalse(FileManager.default.fileExists(atPath: operation.path))
  }

  @MainActor
  func testInvalidAndConflictingOperationsAreRetainedWithoutBlockingValidOnes() async throws {
    let root = temporaryOperationCorpus("retained-conflicts")
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatOperationConflictTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    _ = store.createAIChatThread(runtime: .codex)

    let nonUUID = try writeOperation([
      "kind": "reopen-thread",
      "threadID": "not-a-uuid",
    ], id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", createdAt: "2026-08-20T10:00:00.000Z", root: root)
    let unknownThread = try writeOperation([
      "kind": "settle-thread",
      "threadID": "ffffffff-ffff-4fff-8fff-ffffffffffff",
      "settledAt": "2026-08-20T12:00:00.000Z",
    ], id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", createdAt: "2026-08-20T10:01:00.000Z", root: root)
    let valid = try writeOperation([
      "kind": "configure-auto-settle",
      "autoSettleAfterSeconds": 7200,
    ], id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", createdAt: "2026-08-20T10:02:00.000Z", root: root)
    let invalid = AIChatOperationJournal.operationsDirectory(corpusRoot: root)
      .appendingPathComponent("invalid.json")
    try Data("{\"schema\":\"unsupported\"}".utf8).write(to: invalid)

    await store.drainAIChatInbox()

    XCTAssertEqual(store.aiChatThreadSettlementSettings.autoSettleAfterSeconds, 7200)
    XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path))
    for file in [nonUUID, unknownThread, invalid] {
      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    XCTAssertTrue(store.errorText?.contains("retained 3 file(s)") == true)
    XCTAssertTrue(store.errorText?.contains("not a UUID") == true)
    XCTAssertTrue(store.errorText?.contains("unknown thread") == true)
  }

  @MainActor
  func testCorpusSwitchRetainsInboxEnvelopeWithSameThreadUUID() async throws {
    let fixture = try makeCorpusSwitchFixture(label: "envelope")
    defer { fixture.cleanup() }
    let threadID = UUID()
    try flushThread(
      id: threadID,
      content: "alpha history",
      transcriptURL: fixture.alphaTranscript
    )
    try flushThread(
      id: threadID,
      content: "beta history",
      transcriptURL: fixture.betaTranscript
    )
    let store = WorkspaceStore(
      defaults: fixture.defaults,
      aiChatFallbackTranscriptURL: fixture.fallbackTranscript,
      legacyDefaultsDomains: [],
      automaticStarterCorpusURL: nil
    )
    store.setCorpusRoot(fixture.alpha, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()

    let inbox = fixture.alpha
      .appendingPathComponent(".org2/ai-chat-inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let messageID = UUID()
    let envelope = inbox.appendingPathComponent("\(messageID.uuidString.lowercased()).json")
    try JSONSerialization.data(withJSONObject: [
      "schema": "org2:ai-chat-inbox-message:v1",
      "id": messageID.uuidString.lowercased(),
      "threadID": threadID.uuidString.lowercased(),
      "content": "alpha background delivery",
      "createdAt": "2026-09-01T12:00:00.000Z",
      "authorLabel": "Alpha worker",
    ], options: [.prettyPrinted]).write(to: envelope, options: .atomic)

    let barrier = expectation(description: "alpha durability barrier enqueued")
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(
      true,
      legacyURL: fixture.alphaTranscript
    )
    store.aiChatDurabilityBarrierDidEnqueueForTesting = { url in
      if url.standardizedFileURL == fixture.alphaTranscript.standardizedFileURL {
        barrier.fulfill()
      }
    }
    let drain = Task { await store.drainAIChatInbox() }
    await fulfillment(of: [barrier], timeout: 2)

    store.setCorpusRoot(fixture.beta, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(
      true,
      legacyURL: fixture.betaTranscript
    )
    defer {
      AIChatTranscriptStore.shared.setWritesSuspendedForTesting(
        false,
        legacyURL: fixture.betaTranscript
      )
    }
    store.aiChatMessages.append(AIChatMessage(role: .user, content: "beta mutation"))
    let betaMutationVersion = try XCTUnwrap(
      store.aiChatThreadMessageMutationVersionForTesting(threadID)
    )
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(
      false,
      legacyURL: fixture.alphaTranscript
    )
    await drain.value

    XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == threadID })?.messages.map(\.content),
      ["beta history", "beta mutation"]
    )
    XCTAssertEqual(
      store.aiChatThreadMessageMutationVersionForTesting(threadID),
      betaMutationVersion,
      "The stale alpha durability completion must not clear beta's mutation bookkeeping"
    )
    XCTAssertFalse(store.errorText?.contains("alpha") == true)
  }

  @MainActor
  func testCorpusSwitchRetainsOperationJournalEntry() async throws {
    let fixture = try makeCorpusSwitchFixture(label: "journal")
    defer { fixture.cleanup() }
    let threadID = UUID()
    try flushThread(id: threadID, content: "alpha", transcriptURL: fixture.alphaTranscript)
    try flushThread(id: threadID, content: "beta", transcriptURL: fixture.betaTranscript)
    let store = WorkspaceStore(
      defaults: fixture.defaults,
      aiChatFallbackTranscriptURL: fixture.fallbackTranscript,
      legacyDefaultsDomains: [],
      automaticStarterCorpusURL: nil
    )
    store.setCorpusRoot(fixture.alpha, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    let operation = try writeOperation([
      "kind": "configure-auto-settle",
      "autoSettleAfterSeconds": 4321,
    ], id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", createdAt: "2026-09-01T12:00:00.000Z", root: fixture.alpha)

    let barrier = expectation(description: "journal durability barrier enqueued")
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(
      true,
      legacyURL: fixture.alphaTranscript
    )
    store.aiChatDurabilityBarrierDidEnqueueForTesting = { url in
      if url.standardizedFileURL == fixture.alphaTranscript.standardizedFileURL {
        barrier.fulfill()
      }
    }
    let drain = Task { await store.drainAIChatInbox() }
    await fulfillment(of: [barrier], timeout: 2)

    store.setCorpusRoot(fixture.beta, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    AIChatTranscriptStore.shared.setWritesSuspendedForTesting(
      false,
      legacyURL: fixture.alphaTranscript
    )
    await drain.value

    XCTAssertTrue(FileManager.default.fileExists(atPath: operation.path))
    XCTAssertNotEqual(store.aiChatThreadSettlementSettings.autoSettleAfterSeconds, 4321)
  }

  func testCorpusEventsRecognizeAIChatInboxDeliveries() {
    let root = URL(fileURLWithPath: "/tmp/org2-ai-chat-inbox-events")
    let delivery = root
      .appendingPathComponent(".org2/ai-chat-inbox/message.json")
      .path
    let classified = WorkspaceStore.classifyCorpusFileEvents(
      [delivery],
      corpusRoot: root
    )
    XCTAssertTrue(classified.hasAIChatInboxChanges)
    XCTAssertTrue(classified.contentPaths.isEmpty)
  }

  private func temporaryOperationCorpus(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-operation-\(label)-\(UUID().uuidString)", isDirectory: true)
  }

  @MainActor
  private func makeCorpusSwitchFixture(label: String) throws -> (
    alpha: URL,
    beta: URL,
    alphaTranscript: URL,
    betaTranscript: URL,
    fallbackTranscript: URL,
    defaults: UserDefaults,
    cleanup: () -> Void
  ) {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-context-\(label)-\(UUID().uuidString)", isDirectory: true)
    let alpha = base.appendingPathComponent("alpha", isDirectory: true)
    let beta = base.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    let alphaTranscript = alpha.appendingPathComponent(".org2/openclaw-chat.json")
    let betaTranscript = beta.appendingPathComponent(".org2/openclaw-chat.json")
    let fallbackTranscript = base.appendingPathComponent("fallback-openclaw-chat.json")
    let suiteName = "AIChatInboxCorpusContextTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    return (
      alpha,
      beta,
      alphaTranscript,
      betaTranscript,
      fallbackTranscript,
      defaults,
      {
        AIChatTranscriptStore.shared.setWritesSuspendedForTesting(false, legacyURL: alphaTranscript)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: base)
      }
    )
  }

  private func flushThread(id: UUID, content: String, transcriptURL: URL) throws {
    let thread = AIChatThread(
      id: id,
      title: content,
      sessionKey: "session-\(content)",
      messages: [AIChatMessage(role: .assistant, content: content)]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [thread],
        selectedThreadID: id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
  }

  @discardableResult
  private func writeOperation(
    _ operationFields: [String: Any],
    id: String,
    createdAt: String,
    root: URL
  ) throws -> URL {
    let directory = AIChatOperationJournal.operationsDirectory(corpusRoot: root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("\(id).json")
    var payload: [String: Any] = [
      "schema": AIChatOperationJournal.schema,
      "id": id,
      "createdAt": createdAt,
    ]
    for (key, value) in operationFields { payload[key] = value }
    try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
      .write(to: file)
    return file
  }
}
