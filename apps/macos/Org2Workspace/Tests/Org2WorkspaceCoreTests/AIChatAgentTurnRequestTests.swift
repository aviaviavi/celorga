import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor AgentTurnRecorder {
  private(set) var calls: [String] = []
  private(set) var prompts: [String] = []

  func record(_ runtime: AIChatRuntime, _ messages: [AIChatMessage]) {
    calls.append(runtime.rawValue)
    prompts.append(messages.last(where: { $0.role == .user })?.content ?? "")
  }
}

final class AIChatAgentTurnRequestTests: XCTestCase {
  private let codex = AIChatDestinationConfiguration.localCodexID
  private let openClaw = AIChatDestinationConfiguration.openClawID

  private var destinations: [AIChatDestinationConfiguration] {
    AIChatDestinationConfiguration.defaults
  }

  // MARK: Pure rules

  func testMentionsInCodeAndVerbatimDoNotRequestTurns() {
    let reply = """
    Use =@openclaw= or ~@openclaw~ or `@openclaw` to refer to it.
    ```
    @openclaw
    ```
    #+begin_src sh
    echo @openclaw
    #+end_src
    """
    XCTAssertEqual(AIChatAgentTurnRequests.requestedDestinationIDs(
      inReply: reply,
      authorDestinationID: codex,
      roomDestinationIDs: [codex, openClaw],
      destinations: destinations
    ), [])
    XCTAssertEqual(AIChatAgentTurnRequests.requestedDestinationIDs(
      inReply: "Done with =step one=. @openclaw can you review?",
      authorDestinationID: codex,
      roomDestinationIDs: [codex, openClaw],
      destinations: destinations
    ), [openClaw])
  }

  func testAgentCannotRequestItselfOrAgentsOutsideTheRoom() {
    XCTAssertEqual(AIChatAgentTurnRequests.requestedDestinationIDs(
      inReply: "@codex @claude @all thoughts?",
      authorDestinationID: codex,
      roomDestinationIDs: [codex, openClaw],
      destinations: destinations
    ), [openClaw])
  }

  func testResponderTokensResolveByIDOrMentionWithinTheRoom() {
    let resolved = AIChatAgentTurnRequests.resolveResponderTokens(
      ["@OpenClaw", "builtin.codex", "codex", "nobody"],
      roomDestinationIDs: [codex, openClaw],
      destinations: destinations
    )
    XCTAssertEqual(resolved.destinationIDs, [openClaw, codex])
    XCTAssertEqual(resolved.unresolved, ["nobody"])
  }

  /// A person's @mention reaches any enabled agent and adds it to the room;
  /// an explicit `--request-turn` from an agent must resolve the same way
  /// (by mention or destination ID) instead of failing for a non-member.
  func testResponderTokensReachEnabledAgentsOutsideTheRoomLikeAPersonsMention() throws {
    let dot = AIChatDestinationConfiguration(
      id: "9a3e6f1c-0000-4000-8000-000000000001",
      name: "Helper",
      mention: "helper",
      adapter: .openAIDot
    )
    let disabled = AIChatDestinationConfiguration(
      id: "9a3e6f1c-0000-4000-8000-000000000002",
      name: "Off",
      mention: "off",
      adapter: .openAIDot,
      isEnabled: false
    )
    let all = destinations + [dot, disabled]
    let byMention = AIChatAgentTurnRequests.resolveResponderTokens(
      ["helper", "off"],
      roomDestinationIDs: [codex, openClaw],
      destinations: all
    )
    XCTAssertEqual(byMention.destinationIDs, [dot.id])
    XCTAssertEqual(byMention.unresolved, ["off"])
    XCTAssertEqual(AIChatAgentTurnRequests.resolveResponderTokens(
      [dot.id.uppercased()],
      roomDestinationIDs: [codex, openClaw],
      destinations: all
    ).destinationIDs, [dot.id])
    // `all` still means the agents already in the room.
    XCTAssertEqual(AIChatAgentTurnRequests.resolveResponderTokens(
      ["all"],
      roomDestinationIDs: [codex, openClaw],
      destinations: all
    ).destinationIDs.sorted(), [codex, openClaw].sorted())
  }

  func testConsecutiveCountResetsOnAPersonsMessage() {
    func requested() -> AIChatMessage {
      AIChatMessage(
        role: .user,
        content: "x",
        isRoomDispatchCopy: true,
        provenance: AIChatMessageProvenance(requestedByLabel: "Codex", requestedByDestinationID: "builtin.codex")
      )
    }
    let human = AIChatMessage(role: .user, content: "hi")
    let humanCopy = AIChatMessage(role: .user, content: "hi", isRoomDispatchCopy: true)
    let reply = AIChatMessage(role: .assistant, content: "ok")
    XCTAssertEqual(AIChatAgentTurnRequests.consecutiveRequestedTurnCount(
      in: [requested(), human, humanCopy, reply, requested(), reply, requested()]
    ), 2)
    XCTAssertEqual(AIChatAgentTurnRequests.consecutiveRequestedTurnCount(in: [human, reply]), 0)
    XCTAssertEqual(AIChatAgentTurnRequests.admittedCount(requested: 2, alreadyUsed: 3, limit: 4), 1)
    XCTAssertEqual(AIChatAgentTurnRequests.admittedCount(requested: 1, alreadyUsed: 4, limit: 4), 0)
    XCTAssertEqual(AIChatAgentTurnRequests.admittedCount(requested: 1, alreadyUsed: 0, limit: 0), 0)
  }

  func testRoomAgentTurnLimitRoundTripsAndClamps() throws {
    let room = AIChatThread(
      title: "Room",
      sessionKey: "agent:main:room",
      isSharedRoom: true,
      roomDestinationIDs: [codex, openClaw],
      roomAgentTurnLimit: 2
    )
    let decoded = try JSONDecoder().decode(AIChatThread.self, from: JSONEncoder().encode(room))
    XCTAssertEqual(decoded.roomAgentTurnLimit, 2)
    XCTAssertEqual(decoded.effectiveRoomAgentTurnLimit, 2)
    XCTAssertEqual(decoded.replacingMessages([]).roomAgentTurnLimit, 2)
    XCTAssertEqual(decoded.metadataOnly().roomAgentTurnLimit, 2)
    XCTAssertNil(decoded.replacingAIChatMetadata(roomAgentTurnLimit: .some(nil)).roomAgentTurnLimit)
    XCTAssertEqual(
      AIChatThread(title: "R", sessionKey: "k", isSharedRoom: true, roomAgentTurnLimit: 999).roomAgentTurnLimit,
      AIChatThread.maxRoomAgentTurnLimit
    )
    XCTAssertNil(AIChatThread(title: "S", sessionKey: "k", roomAgentTurnLimit: 3).roomAgentTurnLimit)
    XCTAssertEqual(
      AIChatThread(title: "D", sessionKey: "k", isSharedRoom: true).effectiveRoomAgentTurnLimit,
      AIChatThread.defaultRoomAgentTurnLimit
    )
  }

  func testRequestedTurnPromptNamesTheRequesterAndOffersHandoffs() {
    let request = AIChatMessage(
      role: .assistant,
      content: "@openclaw please review the plan.",
      authorDestinationID: codex,
      roomRoundID: UUID()
    )
    let dispatch = AIChatMessage(
      role: .user,
      content: request.content,
      audienceDestinationIDs: [openClaw],
      targetDestinationID: openClaw,
      isRoomDispatchCopy: true,
      roomRoundID: UUID(),
      provenance: AIChatMessageProvenance(
        requestedByLabel: "Codex",
        requestedByDestinationID: codex,
        requestedByMessageID: request.id
      )
    )
    let prompt = WorkspaceStore.sharedRoomRequestMessages(
      [AIChatMessage(role: .user, content: "Plan the launch"), request, dispatch],
      targetDestinationName: "OpenClaw",
      targetDestinationID: openClaw,
      destinationNamesByID: [codex: "Codex", openClaw: "OpenClaw"],
      handoffMentions: ["@codex for Codex"],
      agentTurnLimit: 4,
      through: dispatch.id
    ).last?.content ?? ""
    XCTAssertTrue(prompt.contains("Codex → OpenClaw:\n@openclaw please review the plan."), prompt)
    XCTAssertEqual(prompt.components(separatedBy: "please review the plan").count - 1, 1,
                   "the requesting message is the current request, not repeated history")
    XCTAssertTrue(prompt.contains("@mention it in your reply (@codex for Codex)"), prompt)
    XCTAssertTrue(prompt.contains("at most 4 turns in a row"), prompt)
  }

  // MARK: Store integration

  @MainActor
  private func makeStore(
    root: URL,
    recorder: AgentTurnRecorder,
    codexReply: @escaping @Sendable (Int) -> String,
    openClawReply: @escaping @Sendable (Int) -> String
  ) throws -> WorkspaceStore {
    let suiteName = "AIChatAgentTurnRequests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    let counter = AgentReplyCounter()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root
        .appendingPathComponent(".org2", isDirectory: true)
        .appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await recorder.record(.openClaw, messages)
        return openClawReply(await counter.next(.openClaw))
      },
      codexSendHandlerForTesting: { messages, _, _ in
        await recorder.record(.codex, messages)
        return codexReply(await counter.next(.codex))
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    return store
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-agent-turns-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".org2", isDirectory: true),
      withIntermediateDirectories: true
    )
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  @MainActor
  func testAgentMentionStartsTheOtherAgentsTurnUntilTheLimit() async throws {
    let root = try makeRoot()
    let recorder = AgentTurnRecorder()
    let store = try makeStore(
      root: root,
      recorder: recorder,
      codexReply: { "Codex \($0): @openclaw your turn" },
      openClawReply: { "OpenClaw \($0): @codex your turn" }
    )
    store.createAIChatSharedRoom()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertEqual(store.selectedAIChatRoomAgentTurnLimit, 4)

    await store.sendAIChatMessage(text: "@codex start the review")
    try await waitUntil { !store.isAIChatThreadRunning(threadID) }

    let calls = await recorder.calls
    // One turn the person asked for, then four agent-requested turns.
    XCTAssertEqual(calls, ["codex", "openClaw", "codex", "openClaw", "codex"])
    let prompts = await recorder.prompts
    XCTAssertTrue(prompts[1].contains("Codex → OpenClaw:\nCodex 1: @openclaw your turn"), prompts[1])

    let thread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID }))
    let requested = thread.messages.filter { $0.provenance?.isAgentTurnRequest == true && $0.role == .user }
    XCTAssertEqual(requested.count, 4)
    XCTAssertTrue(requested.allSatisfy { $0.isRoomDispatchCopy && $0.deliveryStatus == .sent })
    let visible = thread.messages.filter { !$0.isRoomDispatchCopy }
    XCTAssertEqual(visible.filter { $0.role == .assistant }.count, 5)
    let window = AIChatTranscriptWindow(
      messages: thread.messages, isSharedRoom: true,
      displayLimit: AIChatTranscriptWindow.initialLimit
    )
    XCTAssertEqual(window.visibleMessagesForPresentation.map(\.id), visible.map(\.id))

    let replyFromOpenClaw = try XCTUnwrap(visible.first { $0.authorDestinationID == openClaw })
    XCTAssertEqual(replyFromOpenClaw.provenance?.requestedByLabel, "Codex")
    XCTAssertEqual(store.aiChatProvenanceCaption(for: replyFromOpenClaw), "requested by Codex")
    let notice = try XCTUnwrap(thread.messages.last)
    XCTAssertEqual(notice.role, .system)
    XCTAssertTrue(notice.content.contains("4 turns in a row"), notice.content)

    // A person's reply resets the count.
    await store.sendAIChatMessage(text: "@openclaw one more round")
    try await waitUntil { !store.isAIChatThreadRunning(threadID) }
    let afterReset = await recorder.calls
    XCTAssertEqual(afterReset.count, 5 + 1 + 4)
  }

  /// Settings → AI Chat sets the limit for every room without its own; a
  /// room's own choice still wins, and choosing Default follows the app again.
  @MainActor
  func testAppWideDefaultLimitAppliesToRoomsWithoutTheirOwn() async throws {
    let root = try makeRoot()
    let recorder = AgentTurnRecorder()
    let store = try makeStore(
      root: root,
      recorder: recorder,
      codexReply: { _ in "@openclaw over to you" },
      openClawReply: { _ in "@codex back to you" }
    )
    store.aiChatDefaultRoomAgentTurnLimit = 2
    store.createAIChatSharedRoom()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertTrue(store.selectedAIChatRoomUsesDefaultAgentTurnLimit)
    XCTAssertEqual(store.selectedAIChatRoomAgentTurnLimit, 2)

    await store.sendAIChatMessage(text: "@codex go")
    try await waitUntil { !store.isAIChatThreadRunning(threadID) }
    let limited = await recorder.calls
    XCTAssertEqual(limited, ["codex", "openClaw", "codex"])
    let notice = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID })?.messages.last)
    XCTAssertTrue(notice.content.contains("2 turns in a row"), notice.content)
    XCTAssertTrue(notice.content.contains("Settings → AI Chat"), notice.content)

    store.setSelectedAIChatRoomAgentTurnLimit(6)
    store.aiChatDefaultRoomAgentTurnLimit = 1
    XCTAssertFalse(store.selectedAIChatRoomUsesDefaultAgentTurnLimit)
    XCTAssertEqual(store.selectedAIChatRoomAgentTurnLimit, 6)
    store.setSelectedAIChatRoomAgentTurnLimit(nil)
    XCTAssertEqual(store.selectedAIChatRoomAgentTurnLimit, 1)

    store.aiChatDefaultRoomAgentTurnLimit = 500
    XCTAssertEqual(store.aiChatDefaultRoomAgentTurnLimit, AIChatThread.maxRoomAgentTurnLimit)
  }

  @MainActor
  func testRoomLimitIsConfigurableAndZeroTurnsHandoffsOff() async throws {
    let root = try makeRoot()
    let recorder = AgentTurnRecorder()
    let store = try makeStore(
      root: root,
      recorder: recorder,
      codexReply: { _ in "@openclaw over to you" },
      openClawReply: { _ in "@codex back to you" }
    )
    store.createAIChatSharedRoom()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)

    store.setSelectedAIChatRoomAgentTurnLimit(1)
    XCTAssertEqual(store.selectedAIChatRoomAgentTurnLimit, 1)
    await store.sendAIChatMessage(text: "@codex go")
    try await waitUntil { !store.isAIChatThreadRunning(threadID) }
    let limited = await recorder.calls
    XCTAssertEqual(limited, ["codex", "openClaw"])

    store.setSelectedAIChatRoomAgentTurnLimit(0)
    await store.sendAIChatMessage(text: "@codex again")
    try await waitUntil { !store.isAIChatThreadRunning(threadID) }
    let off = await recorder.calls
    XCTAssertEqual(off, ["codex", "openClaw", "codex"])
    let thread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID }))
    XCTAssertNotEqual(thread.messages.last?.role, .system,
                      "a plain mention while hand-offs are off stays quiet")

    store.setSelectedAIChatRoomAgentTurnLimit(nil)
    XCTAssertEqual(store.selectedAIChatRoomAgentTurnLimit, AIChatThread.defaultRoomAgentTurnLimit)
  }

  @MainActor
  func testMentionInsideVerbatimDoesNotStartATurn() async throws {
    let root = try makeRoot()
    let recorder = AgentTurnRecorder()
    let store = try makeStore(
      root: root,
      recorder: recorder,
      codexReply: { _ in "You could ask =@openclaw= later." },
      openClawReply: { _ in "unexpected" }
    )
    store.createAIChatSharedRoom()
    await store.sendAIChatMessage(text: "@codex who should review?")
    let calls = await recorder.calls
    XCTAssertEqual(calls, ["codex"])
  }

  @MainActor
  func testBackgroundPostCanRequestARoomAgentsTurn() async throws {
    let root = try makeRoot()
    let recorder = AgentTurnRecorder()
    let store = try makeStore(
      root: root,
      recorder: recorder,
      codexReply: { _ in "unexpected" },
      openClawReply: { _ in "Reviewed the export." }
    )
    store.createAIChatSharedRoom()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    let inbox = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

    func post(_ id: UUID, responders: [String]?) throws {
      var payload: [String: Any] = [
        "schema": "org2:ai-chat-inbox-message:v1",
        "id": id.uuidString.lowercased(),
        "threadID": threadID.uuidString.lowercased(),
        "content": "Export finished.",
        "createdAt": "2026-10-08T12:00:00.000Z",
        "authorLabel": "Export worker",
      ]
      if let responders { payload["requestedResponders"] = responders }
      try JSONSerialization.data(withJSONObject: payload)
        .write(to: inbox.appendingPathComponent("\(id.uuidString.lowercased()).json"))
    }

    // Without a request, a post stays context only.
    try post(UUID(), responders: nil)
    await store.drainAIChatInbox()
    let contextOnly = await recorder.calls
    XCTAssertEqual(contextOnly, [])

    let requestID = UUID()
    try post(requestID, responders: ["openclaw", "ghost"])
    await store.drainAIChatInbox()
    try await waitUntil { !store.isAIChatThreadRunning(threadID) }
    let calls = await recorder.calls
    XCTAssertEqual(calls, ["openClaw"])
    let prompts = await recorder.prompts
    XCTAssertTrue(prompts[0].contains("Export worker → OpenClaw:\nExport finished."), prompts[0])

    let thread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID }))
    XCTAssertTrue(thread.messages.contains {
      $0.role == .system && $0.content.contains("@ghost")
    })
    let reply = try XCTUnwrap(thread.messages.last { $0.role == .assistant })
    XCTAssertEqual(reply.content, "Reviewed the export.")
    XCTAssertEqual(reply.provenance?.requestedByMessageID, requestID)

    // Redelivering the same envelope never runs the turn twice.
    try post(requestID, responders: ["openclaw"])
    await store.drainAIChatInbox()
    try await waitUntil { !store.isAIChatThreadRunning(threadID) }
    let afterRetry = await recorder.calls
    XCTAssertEqual(afterRetry, ["openClaw"])
  }

  @MainActor
  func testCLIOperationConfiguresTheRoomLimit() async throws {
    let root = try makeRoot()
    let store = try makeStore(
      root: root,
      recorder: AgentTurnRecorder(),
      codexReply: { _ in "" },
      openClawReply: { _ in "" }
    )
    store.createAIChatSharedRoom()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    let operations = root
      .appendingPathComponent(".org2/ai-chat-inbox/operations", isDirectory: true)
    try FileManager.default.createDirectory(at: operations, withIntermediateDirectories: true)
    let id = UUID().uuidString.lowercased()
    let payload: [String: Any] = [
      "schema": "org2:ai-chat-operation:v1",
      "id": id,
      "createdAt": "2026-10-08T12:00:00.000Z",
      "kind": "configure-room-agent-turns",
      "threadID": threadID.uuidString.lowercased(),
      "agentTurnLimit": 2,
    ]
    try JSONSerialization.data(withJSONObject: payload)
      .write(to: operations.appendingPathComponent("1791460800000-\(id).json"))
    await store.drainAIChatInbox()
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.roomAgentTurnLimit, 2)
    XCTAssertEqual(store.selectedAIChatRoomAgentTurnLimit, 2)
  }

  @MainActor
  private func waitUntil(
    timeout: TimeInterval = 10,
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(condition(), "condition not met before timeout")
  }
}

private actor AgentReplyCounter {
  private var counts: [AIChatRuntime: Int] = [:]

  func next(_ runtime: AIChatRuntime) -> Int {
    counts[runtime, default: 0] += 1
    return counts[runtime]!
  }
}
