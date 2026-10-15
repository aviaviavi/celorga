import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor AIChatRoomSteerGate {
  private var isOpen = false
  private(set) var isEntered = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    isEntered = true
    if isOpen { return }
    await withCheckedContinuation { continuations.append($0) }
  }

  func open() {
    isOpen = true
    let waiting = continuations
    continuations.removeAll()
    waiting.forEach { $0.resume() }
  }
}

private actor AIChatRoomSteerRecorder {
  private(set) var steers: [String] = []

  func record(runtime: AIChatRuntime, content: String) {
    steers.append("\(runtime.rawValue):\(content)")
  }
}

final class AIChatSharedRoomSteeringTests: XCTestCase {
  @MainActor
  func testSharedRoomSteersTheRunningAgentAndQueuesOtherAgents() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-room-steer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoomSteering.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let gate = AIChatRoomSteerGate()
    let recorder = AIChatRoomSteerRecorder()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { _, _, _, _ in "OpenClaw answer" },
      codexSendHandlerForTesting: { _, _, _ in
        await gate.wait()
        return "Codex answer"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.aiChatSteerHandlerForTesting = { runtime, _, content, _ in
      await recorder.record(runtime: runtime, content: content)
    }
    store.createAIChatSharedRoom()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)

    let firstTurn = Task { @MainActor in
      await store.sendAIChatMessage(text: "@codex Start a long task")
    }
    // Wait for the Codex handler itself. `aiChatActiveDestinationID` already
    // reports Codex from the queued message before the drain records the
    // running agent, and a steer sent in that window is queued instead.
    for _ in 0..<500 {
      if await gate.isEntered { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let codexTurnStarted = await gate.isEntered
    XCTAssertTrue(codexTurnStarted)
    XCTAssertEqual(store.aiChatActiveDestinationID(for: threadID), AIChatDestinationConfiguration.localCodexID)
    XCTAssertTrue(store.isAIChatThreadRunning(threadID))

    // Un-mentioned guidance goes to the room's default agent (Codex), which is
    // the agent running, so it steers instead of queueing.
    store.sendComposedAIChatMessage(text: "Also check the tests", delivery: .steer)
    for _ in 0..<200 where store.aiChatMessages.last?.deliveryStatus != .sent {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let steered = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(steered.content, "Also check the tests")
    XCTAssertEqual(steered.deliveryKind, .steer)
    XCTAssertEqual(steered.deliveryStatus, .sent)
    XCTAssertEqual(steered.targetDestinationID, AIChatDestinationConfiguration.localCodexID)
    var steers = await recorder.steers
    XCTAssertEqual(steers, ["codex:Also check the tests"])

    // Guidance for another participant cannot steer Codex's turn; it queues.
    store.sendComposedAIChatMessage(text: "@openclaw weigh in after", delivery: .steer)
    let queuedForOpenClaw = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(queuedForOpenClaw.deliveryKind, .followUp)
    XCTAssertEqual(queuedForOpenClaw.targetDestinationID, AIChatDestinationConfiguration.openClawID)
    XCTAssertTrue(store.isAIChatMessageQueued(queuedForOpenClaw.id))
    XCTAssertFalse(store.canSteerQueuedAIChatMessage(queuedForOpenClaw.id))

    // A queued message for the running agent can be promoted to a steer.
    store.sendComposedAIChatMessage(text: "@codex one more thing")
    let queuedForCodex = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(queuedForCodex.deliveryKind, .followUp)
    XCTAssertTrue(store.canSteerQueuedAIChatMessage(queuedForCodex.id))
    await store.steerQueuedAIChatMessage(queuedForCodex.id)
    steers = await recorder.steers
    XCTAssertEqual(steers.last, "codex:@codex one more thing")
    XCTAssertFalse(store.isAIChatMessageQueued(queuedForCodex.id))

    await gate.open()
    await firstTurn.value
    for _ in 0..<300 where store.isAIChatThreadRunning(threadID) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let thread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID }))
    XCTAssertTrue(thread.messages.contains {
      $0.role == .assistant && $0.content == "OpenClaw answer"
    })
    steers = await recorder.steers
    XCTAssertEqual(steers.count, 2)
  }

  @MainActor
  func testUnmentionedSteerReachesTheRunningAgentWhenItIsNotTheRoomDefault() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-room-steer-default-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatSharedRoomSteeringDefault.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let gate = AIChatRoomSteerGate()
    let recorder = AIChatRoomSteerRecorder()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { _, _, _, _ in "OpenClaw answer" },
      codexSendHandlerForTesting: { _, _, _ in
        await gate.wait()
        return "Codex answer"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.aiChatSteerHandlerForTesting = { runtime, _, content, _ in
      await recorder.record(runtime: runtime, content: content)
    }
    store.createAIChatSharedRoom()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.setSelectedAIChatRoomDefaultDestination(AIChatDestinationConfiguration.openClawID)
    XCTAssertEqual(store.selectedAIChatRoomDefaultDestinationID, AIChatDestinationConfiguration.openClawID)

    let firstTurn = Task { @MainActor in
      await store.sendAIChatMessage(text: "@codex Start a long task")
    }
    // Wait for the Codex handler itself. `aiChatActiveDestinationID` already
    // reports Codex from the queued message before the drain records the
    // running agent, and a steer sent in that window is queued instead.
    for _ in 0..<500 {
      if await gate.isEntered { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let codexTurnStarted = await gate.isEntered
    XCTAssertTrue(codexTurnStarted)
    XCTAssertEqual(store.aiChatActiveDestinationID(for: threadID), AIChatDestinationConfiguration.localCodexID)
    XCTAssertTrue(store.isAIChatThreadRunning(threadID))

    // The room default is OpenClaw, but Codex is mid-turn: un-mentioned
    // guidance steers Codex rather than queueing a turn for OpenClaw.
    store.sendComposedAIChatMessage(text: "Use the staging config", delivery: .steer)
    for _ in 0..<200 where store.aiChatMessages.last?.deliveryStatus != .sent {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let steered = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(steered.deliveryKind, .steer)
    XCTAssertEqual(steered.deliveryStatus, .sent)
    XCTAssertEqual(steered.targetDestinationID, AIChatDestinationConfiguration.localCodexID)
    let steers = await recorder.steers
    XCTAssertEqual(steers, ["codex:Use the staging config"])

    await gate.open()
    await firstTurn.value
    for _ in 0..<300 where store.isAIChatThreadRunning(threadID) {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }
}
