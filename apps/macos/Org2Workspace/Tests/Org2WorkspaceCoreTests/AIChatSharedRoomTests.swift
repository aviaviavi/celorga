import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor AIChatSharedRoomRecorder {
  private var events: [String] = []
  private var prompts: [String: String] = [:]

  func record(runtime: AIChatRuntime, messages: [AIChatMessage]) {
    events.append(runtime.rawValue)
    prompts[runtime.rawValue] = messages.last(where: { $0.role == .user })?.content
  }

  func snapshot() -> (events: [String], prompts: [String: String]) {
    (events, prompts)
  }
}

private func waitForCondition(
  timeout: TimeInterval = 5,
  _ condition: @escaping @MainActor () -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if await MainActor.run(body: condition) {
      return
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  let matched = await MainActor.run(body: condition)
  XCTAssertTrue(matched)
}

private actor AIChatSharedRoomGate {
  private var isOpen = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting {
      continuation.resume()
    }
  }
}

final class AIChatSharedRoomTests: XCTestCase {
  @MainActor
  func testSharedRoomExposesTheCurrentlyDispatchedDestinationToMobileClients() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-active-destination-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoom.ActiveDestination.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let gate = AIChatSharedRoomGate()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      codexSendHandlerForTesting: { _, _, _ in
        await gate.wait()
        return "Codex answer"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)

    let sendTask = Task { @MainActor in
      await store.sendAIChatMessage(text: "@codex Check the mobile status")
    }
    for _ in 0..<100 where store.aiChatActiveDestinationID(for: threadID) == nil {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(
      store.aiChatActiveDestinationID(for: threadID),
      AIChatDestinationConfiguration.localCodexID
    )

    await gate.open()
    await sendTask.value
    XCTAssertNil(store.aiChatActiveDestinationID(for: threadID))
  }

  @MainActor
  func testConnectingCodexRequestCanStopBeforeRuntimeTurnStarts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-connecting-stop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatCodexConnectingStop.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      codexSendHandlerForTesting: { _, _, _ in
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return "This reply must never be appended."
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let threadID = store.createAIChatThread(runtime: .codex)

    let sendTask = Task { @MainActor in
      await store.sendAIChatMessage(text: "Please start connecting")
    }
    for _ in 0..<100 where !store.isAIChatThreadRunning(threadID) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(store.isAIChatThreadRunning(threadID))

    let didStop = await store.stopAIChatRemoteRun(threadID: threadID)
    XCTAssertTrue(didStop)
    await sendTask.value

    XCTAssertFalse(store.isAIChatThreadRunning(threadID))
    XCTAssertEqual(store.aiChatStatusText, "Codex stopped")
    let messages = try XCTUnwrap(
      store.aiChatThreads.first(where: { $0.id == threadID })?.messages
    )
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages[0].deliveryStatus, .interrupted)
    XCTAssertEqual(
      messages[0].sendFailure,
      "Codex was stopped by you. Retry to start this request again."
    )
  }

  @MainActor
  func testStaleCodexSteerClearsActiveTurnAndRuntimeThread() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-stale-steer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatCodexStaleSteer.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let gate = AIChatSharedRoomGate()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      codexSendHandlerForTesting: { _, _, _ in
        await gate.wait()
        return "This late reply must not be appended."
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let threadID = store.createAIChatThread(runtime: .codex)
    store.aiChatSteerHandlerForTesting = { _, _, _, _ in
      throw CodexAppServerError.server(
        code: nil,
        message: "thread not found: missing-codex-thread"
      )
    }

    let sendTask = Task { @MainActor in
      await store.sendAIChatMessage(text: "Start a long Codex task")
    }
    for _ in 0..<100 where !store.isAIChatThreadRunning(threadID) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    store.recordCodexActiveTurnForTesting(
      threadID: threadID,
      runtimeThreadID: "missing-codex-thread",
      turnID: "turn-1"
    )

    store.sendComposedAIChatMessage(text: "Are you stalled?")
    let queuedMessage = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertTrue(store.canSteerQueuedAIChatMessage(queuedMessage.id))

    await store.steerQueuedAIChatMessage(queuedMessage.id)
    try await waitForCondition {
      store.aiChatMessages.last?.deliveryStatus == .failed
        && store.isAIChatThreadRunning(threadID) == false
    }

    await gate.open()
    await sendTask.value

    let thread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID }))
    XCTAssertNil(thread.runtimeThreadID(forDestinationID: AIChatDestinationConfiguration.localCodexID))
    XCTAssertEqual(thread.messages.count, 2)
    XCTAssertEqual(thread.messages[0].deliveryStatus, .failed)
    XCTAssertTrue(thread.messages[0].sendFailure?.contains("task expired") == true)
    XCTAssertEqual(thread.messages[1].deliveryStatus, .failed)
    XCTAssertEqual(thread.messages[1].deliveryKind, .followUp)
    XCTAssertTrue(thread.messages[1].sendFailure?.contains("Retry to start a new turn") == true)
    XCTAssertFalse(store.isAIChatMessageQueued(queuedMessage.id))
    XCTAssertFalse(store.isAIChatThreadRunning(threadID))
  }

  @MainActor
  func testAskAllUsesOneVisibleQuestionAndTwoAttributedReplies() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-room-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatSharedRoomRecorder()
    let suiteName = "AIChatSharedRoom.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await recorder.record(runtime: .openClaw, messages: messages)
        return "OpenClaw answer"
      },
      codexSendHandlerForTesting: { messages, _, _ in
        await recorder.record(runtime: .codex, messages: messages)
        return "Codex answer"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()

    XCTAssertTrue(store.selectedAIChatIsSharedRoom)
    XCTAssertEqual(store.selectedAIChatAudience, .thread)

    await store.sendAIChatMessage(text: "@all What do both of you think?")

    let thread = try XCTUnwrap(store.selectedAIChatThread)
    let visibleMessages = thread.messages.filter { !$0.isRoomDispatchCopy }
    XCTAssertEqual(visibleMessages.map(\.content), [
      "@codex @openclaw What do both of you think?",
      "Codex answer",
      "OpenClaw answer"
    ])
    XCTAssertEqual(visibleMessages[0].audience, .everyone)
    XCTAssertEqual(visibleMessages[1].authorRuntime, .codex)
    XCTAssertEqual(visibleMessages[2].authorRuntime, .openClaw)
    XCTAssertEqual(thread.messageCount, 3)
    XCTAssertEqual(thread.messages.filter(\.isRoomDispatchCopy).map(\.targetRuntime), [.openClaw])
    XCTAssertNotNil(visibleMessages[0].roomRoundID)
    XCTAssertEqual(Set(thread.messages.compactMap(\.roomRoundID)).count, 1)

    let recorded = await recorder.snapshot()
    XCTAssertEqual(recorded.events, [AIChatRuntime.codex.rawValue, AIChatRuntime.openClaw.rawValue])
    XCTAssertTrue(recorded.prompts[AIChatRuntime.codex.rawValue]?.contains("Avi → Codex + OpenClaw") == true)
    XCTAssertTrue(recorded.prompts[AIChatRuntime.openClaw.rawValue]?.contains("Codex:\nCodex answer") == true)
  }

  func testSharedRoomMetadataRoundTripsAndLegacyThreadsStaySingleRuntime() throws {
    let room = AIChatThread(
      title: "Room",
      runtime: .openClaw,
      sessionKey: "room-session",
      isSharedRoom: true,
      roomAudience: .codex,
      roomModels: AIChatRoomModelSelection(
        codex: "gpt-5.6-sol",
        openClaw: "openai/gpt-5.6"
      )
    )
    let restored = try JSONDecoder().decode(
      AIChatThread.self,
      from: JSONEncoder().encode(room)
    )
    XCTAssertTrue(restored.isSharedRoom)
    XCTAssertEqual(restored.roomAudience, .codex)
    XCTAssertEqual(restored.model(for: .codex), "gpt-5.6-sol")
    XCTAssertEqual(restored.model(for: .openClaw), "openai/gpt-5.6")
    XCTAssertFalse(restored.canChangeAIRuntime)

    let legacyJSON = #"""
    {
      "id":"00000000-0000-0000-0000-000000000001",
      "title":"Legacy",
      "createdAt":0,
      "updatedAt":0,
      "runtime":"codex",
      "sessionKey":"legacy",
      "messages":[]
    }
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let legacy = try decoder.decode(AIChatThread.self, from: Data(legacyJSON.utf8))
    XCTAssertFalse(legacy.isSharedRoom)
    XCTAssertEqual(legacy.roomAudience, .codex)
    XCTAssertTrue(legacy.canChangeAIRuntime)

    let legacySharedJSON = #"""
    {
      "id":"00000000-0000-0000-0000-000000000002",
      "title":"Legacy shared room",
      "createdAt":0,
      "updatedAt":0,
      "runtime":"openClaw",
      "sessionKey":"legacy-shared",
      "messages":[],
      "isSharedRoom":true,
      "roomAudience":"everyone"
    }
    """#
    let legacyShared = try decoder.decode(
      AIChatThread.self,
      from: Data(legacySharedJSON.utf8)
    )
    XCTAssertEqual(legacyShared.roomDestinationIDs, [
      AIChatDestinationConfiguration.localCodexID,
      AIChatDestinationConfiguration.openClawID,
    ])
    XCTAssertFalse(
      legacyShared.roomDestinationIDs.contains(AIChatDestinationConfiguration.localClaudeID)
    )
  }

  @MainActor
  func testExplicitForkCopiesHistoryWithoutReusingRuntimeIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-thread-fork-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoom.Fork.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { _, _, _, _ in "Original reply" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let sourceID = store.createAIChatThread(runtime: .openClaw)
    await store.sendAIChatMessage(text: "Original question")
    let source = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == sourceID }))

    let loadedForkID = await store.forkAIChatThread(sourceID)
    let forkID = try XCTUnwrap(loadedForkID)
    let fork = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == forkID }))

    XCTAssertNotEqual(fork.id, source.id)
    XCTAssertNotEqual(fork.sessionKey, source.sessionKey)
    XCTAssertNil(fork.runtimeThreadID)
    XCTAssertEqual(fork.messages.map(\.content), source.messages.map(\.content))
    XCTAssertEqual(fork.messages.map(\.deliveryStatus), [.sent, .sent])
    XCTAssertFalse(fork.isSettled)
    XCTAssertFalse(fork.isPinned)
    XCTAssertEqual(store.selectedAIChatThreadID, forkID)
  }

  @MainActor
  func testMentioningAnotherHarnessForksSingleAgentThreadIntoSharedRoom() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mention-fork-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatSharedRoomRecorder()
    let suiteName = "AIChatSharedRoom.MentionFork.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await recorder.record(runtime: .openClaw, messages: messages)
        return "OpenClaw answer"
      },
      codexSendHandlerForTesting: { messages, _, _ in
        await recorder.record(runtime: .codex, messages: messages)
        return "Codex joined"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let sourceID = store.createAIChatThread(runtime: .openClaw)
    await store.sendAIChatMessage(text: "Start with OpenClaw")

    await store.sendAIChatMessage(text: "@Codex review this conversation")

    let destinationID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertNotEqual(destinationID, sourceID)
    let source = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == sourceID }))
    let destination = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == destinationID }))
    XCTAssertFalse(source.isSharedRoom)
    XCTAssertEqual(source.messages.map(\.content), ["Start with OpenClaw", "OpenClaw answer"])
    XCTAssertTrue(destination.isSharedRoom)
    XCTAssertEqual(destination.messages.filter { !$0.isRoomDispatchCopy }.map(\.content), [
      "Start with OpenClaw",
      "OpenClaw answer",
      "@codex review this conversation",
      "Codex joined"
    ])
    XCTAssertEqual(destination.messages.last?.authorRuntime, .codex)
    XCTAssertEqual(destination.messages.dropLast().last?.audience, .codex)

    let recorded = await recorder.snapshot()
    XCTAssertEqual(recorded.events, [AIChatRuntime.openClaw.rawValue, AIChatRuntime.codex.rawValue])
  }

  @MainActor
  func testSharedRoomStoresAnIndependentModelForEachHarness() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-models-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoom.Models.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()

    store.setSelectedAIChatRoomModel("gpt-5.6-sol", for: .codex)
    store.setSelectedAIChatRoomModel("openai/gpt-5.6", for: .openClaw)

    let thread = try XCTUnwrap(store.selectedAIChatThread)
    XCTAssertEqual(thread.model(for: .codex), "gpt-5.6-sol")
    XCTAssertEqual(thread.model(for: .openClaw), "openai/gpt-5.6")
    XCTAssertEqual(store.selectedAIChatRoomModelLabel(for: .codex), "gpt-5.6-sol")
    XCTAssertEqual(store.selectedAIChatRoomModelLabel(for: .openClaw), "gpt-5.6")
  }

  @MainActor
  func testSharedRoomStoresAnIndependentReasoningEffortForEachDestination() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-reasoning-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoom.Reasoning.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()
    let codexID = AIChatDestinationConfiguration.localCodexID
    let openClawID = AIChatDestinationConfiguration.openClawID

    store.setSelectedAIChatRoomModel("gpt-5.6-sol", forDestinationID: codexID)
    store.setSelectedAIChatRoomReasoningEffort("high", forDestinationID: codexID)
    store.setSelectedAIChatRoomReasoningEffort("low", forDestinationID: openClawID)

    var thread = try XCTUnwrap(store.selectedAIChatThread)
    XCTAssertEqual(thread.reasoningEffort(forDestinationID: codexID), "high")
    XCTAssertEqual(thread.reasoningEffort(forDestinationID: openClawID), "low")
    XCTAssertNil(thread.reasoningEffort)
    XCTAssertEqual(store.selectedAIChatRoomReasoningLabel(forDestinationID: openClawID), "Low")

    // Persisted with the room and restored on decode.
    let decoded = try JSONDecoder().decode(AIChatThread.self, from: JSONEncoder().encode(thread))
    XCTAssertEqual(decoded.roomReasoningEffortsByDestination, [codexID: "high", openClawID: "low"])

    // Changing a destination's model returns only that destination to its
    // default effort.
    store.setSelectedAIChatRoomModel("gpt-5.6", forDestinationID: codexID)
    thread = try XCTUnwrap(store.selectedAIChatThread)
    XCTAssertNil(thread.reasoningEffort(forDestinationID: codexID))
    XCTAssertEqual(thread.reasoningEffort(forDestinationID: openClawID), "low")

    store.setSelectedAIChatRoomReasoningEffort(nil, forDestinationID: openClawID)
    XCTAssertNil(store.selectedAIChatThread?.reasoningEffort(forDestinationID: openClawID))

    // Single-agent threads keep their own effort for their destination.
    let single = AIChatThread(
      title: "Single",
      runtime: .codex,
      sessionKey: "single",
      reasoningEffort: "medium"
    )
    XCTAssertEqual(single.reasoningEffort(forDestinationID: codexID), "medium")
  }

  func testSharedRoomReasoningOptionsFollowEachDestinationModel() {
    let high = AIChatReasoningOption(id: "high", label: "High")
    let low = AIChatReasoningOption(id: "low", label: "Low")
    let models = [
      AIChatModelOption(id: "default", label: "Default", reasoningOptions: [low], isDefault: true),
      AIChatModelOption(id: "big", label: "Big", reasoningOptions: [low, high])
    ]
    XCTAssertEqual(
      WorkspaceStore.aiChatRoomReasoningOptions(adapter: .codexLocal, selectedModel: nil, models: models),
      [low]
    )
    XCTAssertEqual(
      WorkspaceStore.aiChatRoomReasoningOptions(adapter: .codexLocal, selectedModel: "big", models: models),
      [low, high]
    )
    XCTAssertFalse(
      WorkspaceStore.aiChatRoomReasoningOptions(adapter: .openCodeLocal, selectedModel: nil, models: []).isEmpty
    )
    XCTAssertTrue(
      WorkspaceStore.aiChatRoomReasoningOptions(
        adapter: .openClaw,
        selectedModel: "openai/plain",
        models: [AIChatModelOption(id: "openai/plain", label: "Plain", supportsReasoning: false)]
      ).isEmpty
    )
    XCTAssertTrue(
      WorkspaceStore.aiChatRoomReasoningOptions(adapter: .claudeLocal, selectedModel: nil, models: []).isEmpty
    )
  }

  @MainActor
  func testOneHarnessFailureDoesNotPreventTheOtherHarnessFromReplying() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-room-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatSharedRoomRecorder()
    let suiteName = "AIChatSharedRoom.Failure.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await recorder.record(runtime: .openClaw, messages: messages)
        return "OpenClaw recovered the room"
      },
      codexSendHandlerForTesting: { _, _, _ in
        throw CodexAppServerError.invalidResponse("Codex test outage")
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()

    await store.sendAIChatMessage(text: "@all Keep going if one of you is unavailable")

    let thread = try XCTUnwrap(store.selectedAIChatThread)
    let visibleMessages = thread.messages.filter { !$0.isRoomDispatchCopy }
    XCTAssertEqual(visibleMessages.map(\.role), [.user, .system, .assistant])
    XCTAssertTrue(visibleMessages[1].content.contains("Codex could not respond"))
    XCTAssertEqual(visibleMessages[2].content, "OpenClaw recovered the room")
    XCTAssertEqual(visibleMessages[2].authorRuntime, .openClaw)
    XCTAssertFalse(store.isSendingAIChatMessage)

    let recorded = await recorder.snapshot()
    XCTAssertEqual(recorded.events, [AIChatRuntime.openClaw.rawValue])
  }

  func testSharedRoomPromptDoesNotConfuseTheOtherHarnessWithItself() {
    let userID = UUID()
    let messages = [
      AIChatMessage(
        id: userID,
        role: .user,
        content: "Review this plan",
        audience: .everyone,
        targetRuntime: .openClaw
      ),
      AIChatMessage(
        role: .assistant,
        content: "I would simplify it.",
        authorRuntime: .codex
      )
    ]
    let transformed = WorkspaceStore.sharedRoomRequestMessages(
      messages,
      target: .openClaw,
      through: userID
    )
    let prompt = transformed[0].content
    XCTAssertTrue(prompt.contains("You are OpenClaw"))
    XCTAssertTrue(prompt.contains("Do not impersonate the other harness"))
    XCTAssertFalse(prompt.contains("I would simplify it."))
  }

  func testSharedRoomUsesDestinationCursorSummaryAndBoundedUnseenMessages() {
    let codexID = AIChatDestinationConfiguration.localCodexID
    let openClawID = AIChatDestinationConfiguration.openClawID
    let firstUser = AIChatMessage(
      role: .user,
      content: "First room question",
      audienceDestinationIDs: [codexID, openClawID]
    )
    let codexReply = AIChatMessage(
      role: .assistant,
      content: "Codex answered the first question",
      authorDestinationID: codexID
    )
    let openClawReply = AIChatMessage(
      role: .assistant,
      content: "OpenClaw answered the first question",
      authorDestinationID: openClawID
    )
    let latest = AIChatMessage(
      role: .user,
      content: "Second room question",
      audienceDestinationIDs: [codexID, openClawID]
    )
    let messages = [firstUser, codexReply, openClawReply, latest]

    let codexPrompt = WorkspaceStore.sharedRoomRequestMessages(
      messages,
      targetDestinationName: "Codex",
      targetDestinationID: codexID,
      through: latest.id
    ).last?.content ?? ""
    let openClawPrompt = WorkspaceStore.sharedRoomRequestMessages(
      messages,
      targetDestinationName: "OpenClaw",
      targetDestinationID: openClawID,
      through: latest.id
    ).last?.content ?? ""

    XCTAssertTrue(codexPrompt.contains(codexReply.id.uuidString.lowercased()))
    XCTAssertTrue(openClawPrompt.contains(openClawReply.id.uuidString.lowercased()))
    XCTAssertTrue(codexPrompt.contains("Rolling summary"))
    XCTAssertTrue(codexPrompt.contains("Unseen transcript"))
    XCTAssertTrue(codexPrompt.contains("Current request (verbatim"))
    XCTAssertTrue(codexPrompt.contains("OpenClaw answered the first question"))
    XCTAssertTrue(codexPrompt.contains("Second room question"))
    XCTAssertFalse(openClawPrompt.contains("Codex answered the first question\n\nOpenClaw answered"))
    XCTAssertLessThanOrEqual(
      AIChatContextBudget.estimatedTokens(codexPrompt),
      AIChatContextBudget.sharedRoomSummaryTokenBudget
        + AIChatContextBudget.sharedRoomUnseenTokenBudget
        + 300
    )
  }

  func testSharedRoomPreservesLargeCurrentRequestOutsideHistoryBudgets() {
    let earlier = AIChatMessage(
      role: .assistant,
      content: String(repeating: "Earlier room context. ", count: 5_000),
      authorDestinationID: AIChatDestinationConfiguration.openClawID
    )
    let currentContent = "BEGIN-CURRENT\n"
      + String(repeating: "Keep this instruction intact. ", count: 3_000)
      + "\nEND-CURRENT"
    let current = AIChatMessage(
      role: .user,
      content: currentContent,
      audienceDestinationIDs: [AIChatDestinationConfiguration.localCodexID]
    )

    let prompt = WorkspaceStore.sharedRoomRequestMessages(
      [earlier, current],
      target: .codex,
      through: current.id
    ).last?.content ?? ""

    XCTAssertTrue(prompt.contains(currentContent))
    XCTAssertEqual(prompt.components(separatedBy: currentContent).count - 1, 1)
    XCTAssertLessThanOrEqual(
      AIChatContextBudget.estimatedTokens(
        prompt.replacingOccurrences(of: currentContent, with: "")
      ),
      AIChatContextBudget.sharedRoomSummaryTokenBudget
        + AIChatContextBudget.sharedRoomUnseenTokenBudget
        + 400
    )
  }

  func testRoomRoutingRequiresExplicitMentionsAndExpandsAll() {
    XCTAssertEqual(AIChatRoomRouting("Context for later").audience, .thread)
    XCTAssertEqual(
      AIChatRoomRouting("Context for later").summary,
      "Posts to thread · no agents invoked"
    )
    XCTAssertEqual(AIChatRoomRouting("@Codex review this").audience, .codex)
    XCTAssertEqual(AIChatRoomRouting("ask @openclaw next").audience, .openClaw)
    XCTAssertEqual(AIChatRoomRouting("ask @claude next").audience, .claude)
    XCTAssertEqual(AIChatRoomRouting("ask @pi next").audience, .pi)
    XCTAssertEqual(AIChatRoomRouting("ask @opencode next").audience, .openCode)

    let all = AIChatRoomRouting("@all compare approaches")
    XCTAssertEqual(all.audience, .everyone)
    XCTAssertEqual(all.normalizedText, "@Codex @Claude @Pi @OpenCode @OpenClaw compare approaches")
    XCTAssertEqual(all.summary, "Invokes all agents")

    let legacyBoth = AIChatRoomRouting("@both compare approaches")
    XCTAssertEqual(legacyBoth.audience, .everyone)
    XCTAssertEqual(legacyBoth.normalizedText, "@Codex @Claude @Pi @OpenCode @OpenClaw compare approaches")

    XCTAssertEqual(AIChatRoomRouting("mail me@example.com").audience, .thread)
  }

  @MainActor
  func testContextOnlyPostDoesNotInvokeEitherHarness() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatSharedRoomRecorder()
    let suiteName = "AIChatSharedRoom.Context.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await recorder.record(runtime: .openClaw, messages: messages)
        return "unexpected"
      },
      codexSendHandlerForTesting: { messages, _, _ in
        await recorder.record(runtime: .codex, messages: messages)
        return "unexpected"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatSharedRoom()

    await store.sendAIChatMessage(text: "This is context for the next round")

    let thread = try XCTUnwrap(store.selectedAIChatThread)
    XCTAssertEqual(thread.messages.count, 1)
    XCTAssertEqual(thread.messages[0].audience, .thread)
    XCTAssertEqual(thread.messages[0].deliveryStatus, .sent)
    XCTAssertNil(thread.messages[0].roomRoundID)
    XCTAssertFalse(store.isSendingAIChatMessage)
    let recorded = await recorder.snapshot()
    XCTAssertTrue(recorded.events.isEmpty)
  }

  func testMentionCompletionExpandsAllAndFiltersActiveToken() {
    XCTAssertEqual(AIChatMentionSuggestion.suggestions(for: "@").map(\.id), [
      "codex", "openclaw", "all"
    ])
    XCTAssertEqual(AIChatMentionSuggestion.suggestions(for: "Please ask @o").map(\.id), [
      "openclaw"
    ])
    let all = AIChatMentionSuggestion.all.first(where: { $0.id == "all" })
    XCTAssertEqual(all?.completingMention(in: "Please ask @a"), "Please ask @codex @openclaw ")
  }

  func testComposerMentionsIncludeCorpusFilesAndRemoveTheCompletedToken() {
    let files = [
      CorpusFile(
        path: "/tmp/example-reviewer.org2",
        relativePath: "agents/example-reviewer.org2",
        modifiedAt: nil,
        byteCount: nil
      ),
      CorpusFile(
        path: "/tmp/product-plan.org2",
        relativePath: "projects/product-plan.org2",
        modifiedAt: nil,
        byteCount: nil
      )
    ]

    let suggestions = AIChatComposerMentionSuggestion.suggestions(
      for: "Review @example",
      destinations: AIChatDestinationConfiguration.defaults,
      allDestinationIDs: AIChatDestinationConfiguration.defaults.map(\.id),
      corpusFiles: files
    )

    XCTAssertEqual(suggestions.map(\.id), ["file:/tmp/example-reviewer.org2"])
    XCTAssertEqual(suggestions.map(\.title), ["example-reviewer.org2"])
    XCTAssertEqual(suggestions.map(\.detail), ["agents/example-reviewer.org2"])
    XCTAssertEqual(
      AIChatMentionSuggestion.removingActiveMention(in: "Review @example"),
      "Review "
    )
    XCTAssertTrue(
      AIChatComposerMentionSuggestion.suggestions(
        for: "Email me@example.com",
        destinations: AIChatDestinationConfiguration.defaults,
        allDestinationIDs: AIChatDestinationConfiguration.defaults.map(\.id),
        corpusFiles: files
      ).isEmpty
    )
  }

  @MainActor
  func testTwoCodexDestinationsRemainIndependentInOneRoom() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-two-codex-destinations-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoom.TwoCodex.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { _, _, _, _ in "Unexpected OpenClaw response" },
      codexSendHandlerForTesting: { messages, _, _ in
        let destinationID = messages.last(where: { $0.role == .user })?.targetDestinationID
        return destinationID == AIChatDestinationConfiguration.localCodexID
          ? "Local answer"
          : "Remote answer"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let remoteID = store.addAIChatDestination()
    var remote = try XCTUnwrap(store.aiChatDestination(id: remoteID))
    remote.name = "Codex Remote"
    remote.mention = "codex-remote"
    remote.endpoint = "wss://codex.example.test/ws"
    store.updateAIChatDestination(remote)
    store.createAIChatSharedRoom()

    await store.sendAIChatMessage(text: "@codex @codex-remote Compare these changes")

    let thread = try XCTUnwrap(store.selectedAIChatThread)
    let visible = thread.messages.filter { !$0.isRoomDispatchCopy }
    XCTAssertEqual(visible.map(\.content), [
      "@codex @codex-remote Compare these changes",
      "Local answer",
      "Remote answer"
    ])
    XCTAssertEqual(visible.compactMap(\.authorDestinationID), [
      AIChatDestinationConfiguration.localCodexID,
      remoteID
    ])
    guard case .round(let round) = try XCTUnwrap(
      AIChatRoomTranscriptPresentation.items(messages: thread.messages, isSharedRoom: true).first
    ) else {
      return XCTFail("Expected a destination round")
    }
    XCTAssertEqual(round.expectedDestinationIDs, [
      AIChatDestinationConfiguration.localCodexID,
      remoteID
    ])
    XCTAssertEqual(round.response(forDestinationID: remoteID)?.content, "Remote answer")
  }

  func testDestinationRoutingSupportsCustomMentionsAndScopedAll() {
    let remote = AIChatDestinationConfiguration(
      id: "remote",
      name: "Codex Remote",
      mention: "codex-remote",
      adapter: .codexRemote,
      endpoint: "wss://codex.example.test/ws"
    )
    let destinations = AIChatDestinationConfiguration.defaults + [remote]
    let direct = AIChatDestinationRouting(
      "Ask @codex-remote to check",
      destinations: destinations
    )
    XCTAssertEqual(direct.destinationIDs, ["remote"])
    XCTAssertEqual(direct.summary, "Invokes Codex Remote")

    let scopedAll = AIChatDestinationRouting(
      "@all compare",
      destinations: destinations,
      allDestinationIDs: [AIChatDestinationConfiguration.localCodexID, "remote"]
    )
    XCTAssertEqual(scopedAll.destinationIDs, [
      AIChatDestinationConfiguration.localCodexID,
      "remote"
    ])
    XCTAssertEqual(scopedAll.normalizedText, "@codex @codex-remote compare")
  }

  func testRecognizedMentionsMatchRoutingAndIgnoreUnknownAgents() {
    let remote = AIChatDestinationConfiguration(
      id: "remote",
      name: "Codex Remote",
      mention: "codex-remote",
      adapter: .codexRemote,
      endpoint: "wss://codex.example.test/ws"
    )
    var destinations = AIChatDestinationConfiguration.defaults + [remote]
    // A renamed built-in still answers to its short alias.
    destinations[1].mention = "claw"

    let tokens = AIChatDestinationRouting.recognizedMentionTokens(destinations: destinations)
    XCTAssertEqual(Set(tokens), ["codex", "claw", "openclaw", "codex-remote", "all", "both"])
    XCTAssertFalse(tokens.contains("claude"), "Disabled agents are not highlighted")
    XCTAssertEqual(
      AIChatDestinationRouting("@openclaw check", destinations: destinations).destinationIDs,
      [AIChatDestinationConfiguration.openClawID]
    )

    let text = "@Codex-Remote and @claw, ask @claude or email me@codex.dev @codexy @ALL"
    let ranges = AIChatDestinationRouting.recognizedMentionRanges(in: text, recognizedTokens: Set(tokens))
    let source = text as NSString
    XCTAssertEqual(ranges.map { source.substring(with: $0) }, ["@Codex-Remote", "@claw", "@ALL"])
    XCTAssertTrue(
      AIChatDestinationRouting.recognizedMentionRanges(in: "@codex", recognizedTokens: []).isEmpty
    )
    XCTAssertTrue(
      AIChatDestinationRouting.recognizedMentionTokens(
        destinations: destinations.map { var copy = $0; copy.isEnabled = false; return copy }
      ).isEmpty
    )
  }

  func testChatPagesInstallMentionHighlighting() {
    XCTAssertTrue(AIChatDocumentHTML.style.contains(".\(AIChatMentionHighlight.className)"))
    XCTAssertTrue(AIChatTranscriptHTML.style.contains(".\(AIChatMentionHighlight.className)"))
    XCTAssertTrue(AIChatMentionHighlight.script.contains("window.__chatHighlightMentions"))
    XCTAssertTrue(AIChatMentionHighlight.script.contains("code, pre"))
    XCTAssertTrue(AIChatTranscriptHTML.script.contains("__chatHighlightMentions?.(document, messageBody, mentionTokens)"))
    XCTAssertTrue(AIChatDocumentHTML.updateScript.contains("__chatHighlightMentions?.(next, next.body, mentions)"))
  }

  func testTranscriptGroupsEachHarnessIntoOneRound() {
    let roundID = UUID()
    let trigger = AIChatMessage(
      id: roundID,
      role: .user,
      content: "@Codex @OpenClaw compare",
      deliveryStatus: .sent,
      audience: .everyone,
      targetRuntime: .codex,
      roomRoundID: roundID
    )
    let hiddenDispatch = AIChatMessage(
      role: .user,
      content: trigger.content,
      deliveryStatus: .sending,
      audience: .everyone,
      targetRuntime: .openClaw,
      isRoomDispatchCopy: true,
      roomRoundID: roundID
    )
    let codexReply = AIChatMessage(
      role: .assistant,
      content: "Codex view",
      authorRuntime: .codex,
      roomRoundID: roundID
    )
    let context = AIChatMessage(role: .user, content: "More context", audience: .thread)
    let items = AIChatRoomTranscriptPresentation.items(
      messages: [trigger, codexReply, hiddenDispatch, context],
      isSharedRoom: true
    )

    XCTAssertEqual(items.count, 2)
    guard case .round(let round) = items[0] else {
      return XCTFail("Expected an agent round")
    }
    XCTAssertEqual(round.expectedRuntimes, [.codex, .openClaw])
    XCTAssertEqual(round.response(for: .codex)?.content, "Codex view")
    XCTAssertNil(round.response(for: .openClaw))
    XCTAssertEqual(round.completedCount, 1)
    XCTAssertFalse(round.isComplete)
    guard case .message(let contextMessage) = items[1] else {
      return XCTFail("Expected the context-only post to remain standalone")
    }
    XCTAssertEqual(contextMessage.id, context.id)
  }

  func testLegacyRoundDoesNotHideAgentRequestedReplyBeforeNextHumanMessage() {
    let sourceID = "remote-opencode"
    let codexID = AIChatDestinationConfiguration.localCodexID
    let trigger = AIChatMessage(
      role: .user, content: "Finish testing", audienceDestinationIDs: [sourceID],
      targetDestinationID: sourceID
    )
    let sourceReply = AIChatMessage(
      role: .assistant, content: "@codex release now", authorDestinationID: sourceID
    )
    let handoffRoundID = UUID()
    let dispatch = AIChatMessage(
      role: .user, content: sourceReply.content,
      audienceDestinationIDs: [codexID], targetDestinationID: codexID,
      isRoomDispatchCopy: true, roomRoundID: handoffRoundID,
      provenance: AIChatMessageProvenance(requestedByLabel: "OpenCode")
    )
    let handoffReply = AIChatMessage(
      role: .assistant, content: "Release complete", authorDestinationID: codexID,
      roomRoundID: handoffRoundID,
      provenance: AIChatMessageProvenance(requestedByLabel: "OpenCode")
    )
    let nextHuman = AIChatMessage(role: .user, content: "Did the release run?")
    let window = AIChatTranscriptWindow(
      messages: [trigger, sourceReply, dispatch, handoffReply, nextHuman],
      isSharedRoom: true, displayLimit: AIChatTranscriptWindow.initialLimit
    )
    XCTAssertEqual(window.visibleMessagesForPresentation.map(\.id),
                   [trigger.id, sourceReply.id, handoffReply.id, nextHuman.id])
    XCTAssertTrue(AIChatThreadSearch.candidates(in: window.visibleItems)
      .contains { $0.messageID == handoffReply.id })
    let searchReply = AIChatThreadSearch.candidates(
      in: [trigger, sourceReply, dispatch, handoffReply, nextHuman], isSharedRoom: true
    ).first { $0.messageID == handoffReply.id }
    XCTAssertEqual(searchReply?.scrollTargetID, handoffReply.id)

    // Older hand-off replies may retain provenance without a round ID.
    let untaggedReply = AIChatMessage(
      role: .assistant, content: "Legacy hand-off reply", authorDestinationID: codexID,
      provenance: AIChatMessageProvenance(requestedByLabel: "OpenCode")
    )
    let legacyWindow = AIChatTranscriptWindow(
      messages: [trigger, sourceReply, untaggedReply, nextHuman],
      isSharedRoom: true, displayLimit: AIChatTranscriptWindow.initialLimit
    )
    XCTAssertEqual(legacyWindow.visibleMessagesForPresentation.map(\.id),
                   [trigger.id, sourceReply.id, untaggedReply.id, nextHuman.id])
    XCTAssertEqual(AIChatThreadSearch.candidates(
      in: [trigger, sourceReply, untaggedReply, nextHuman], isSharedRoom: true
    ).first { $0.messageID == untaggedReply.id }?.scrollTargetID, untaggedReply.id)
  }

}
