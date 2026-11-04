import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatTurnChangeTests: XCTestCase {
  private let labels = AIChatTurnChangeMarkers.Labels(
    destinationTitle: { ["alpha": "Alpha", "beta": "Beta"][$0] ?? $0 },
    modelTitle: { model, _ in ["model-x": "Model X", "model-y": "Model Y"][model] ?? model }
  )

  func testSingleAgentThreadMarksModelEffortAndAgentChangesButNotTheFirstTurn() {
    let first = user("alpha", settings: settings("alpha"))
    let same = user("alpha", settings: settings("alpha"))
    let model = user("alpha", settings: settings("alpha", model: "model-x", effort: "high"))
    let sameAgain = user("alpha", settings: settings("alpha", model: "model-x", effort: "high"))
    let steer = user("alpha", settings: settings("alpha", model: "model-y"), kind: .steer)
    let effort = user("alpha", settings: settings("alpha", model: "model-x", effort: "low"))
    let defaultModel = user("alpha", settings: settings("alpha", effort: "low"))
    let reasoningOff = user("alpha", settings: settings("alpha", effort: "none"))
    let defaultEffort = user("alpha", settings: settings("alpha"))
    let agent = user("beta", settings: settings("beta", model: "model-y", effort: "xhigh"))
    let messages = [
      first, reply(), same, reply(), model, reply(), sameAgain, steer, reply(), effort,
      defaultModel, reasoningOff, defaultEffort, agent,
    ]

    let markers = AIChatTurnChangeMarkers.markers(for: messages, isSharedRoom: false, labels: labels)

    XCTAssertEqual(markers, [
      model.id: "Switched to Model X · high effort",
      effort.id: "Switched to low effort",
      defaultModel.id: "Switched to the default model · low effort",
      reasoningOff.id: "Switched to reasoning off",
      defaultEffort.id: "Switched to default effort",
      agent.id: "Now talking to Beta · Model Y · extra high effort",
    ])
  }

  func testTranscriptsWithoutRecordedSelectionsOnlyMarkAgentChanges() {
    let first = user("alpha")
    let same = user("alpha")
    let switched = user("beta")
    // The first turn with a recorded selection has nothing recorded to compare with.
    let recorded = user("beta", settings: settings("beta", model: "model-x", effort: "high"))
    let messages = [first, reply(), same, reply(), switched, reply(), recorded]

    let markers = AIChatTurnChangeMarkers.markers(for: messages, isSharedRoom: false, labels: labels)

    XCTAssertEqual(markers, [switched.id: "Now talking to Beta"])
  }

  func testSharedRoomMarksOnlyTheDefaultAgentAndItsSelection() {
    let first = user("alpha", settings: settings("alpha"))
    // An @mention routes one message elsewhere; the room default is unchanged.
    let mention = user("beta", settings: settings("alpha"))
    let mentionCopy = user("alpha", dispatchCopy: true)
    let contextOnly = user(nil, settings: settings(nil))
    let agentRequest = user(
      "beta",
      settings: settings("beta"),
      provenance: AIChatMessageProvenance(requestedByLabel: "Alpha", requestedByDestinationID: "alpha")
    )
    let legacy = user("beta")
    let model = user("alpha", settings: settings("alpha", model: "model-x"))
    let defaultChange = user("beta", settings: settings("beta"))
    let messages = [first, mention, mentionCopy, contextOnly, agentRequest, legacy, model, defaultChange]

    let markers = AIChatTurnChangeMarkers.markers(for: messages, isSharedRoom: true, labels: labels)

    XCTAssertEqual(markers, [
      model.id: "Switched Alpha to Model X",
      defaultChange.id: "Default agent is now Beta",
    ])
  }

  func testWindowedTranscriptComparesItsFirstTurnWithEarlierContext() {
    let hidden = user("alpha", settings: settings("alpha"))
    let firstVisible = user("alpha", settings: settings("alpha", model: "model-x"))
    let laterVisible = user("alpha", settings: settings("alpha", model: "model-x"))
    let all = [hidden, reply(), firstVisible, reply(), laterVisible]
    let visible = Array(all.suffix(3))

    let context = AIChatTurnChangeMarkers.precedingContext(before: visible.first?.id, in: all)
    XCTAssertEqual(context.map(\.id), [hidden.id, all[1].id])
    let markers = AIChatTurnChangeMarkers.markers(
      for: Array(context) + visible,
      isSharedRoom: false,
      labels: labels,
      markedMessageIDs: Set(visible.map(\.id))
    )
    XCTAssertEqual(markers, [firstVisible.id: "Switched to Model X"])

    // Without earlier context the first visible turn has nothing to compare.
    XCTAssertTrue(AIChatTurnChangeMarkers.markers(for: visible, isSharedRoom: false, labels: labels).isEmpty)
    // A message outside the scan limit yields no context rather than a long scan.
    XCTAssertTrue(AIChatTurnChangeMarkers.precedingContext(before: hidden.id, in: all, scanLimit: 2).isEmpty)
  }

  func testMessagesWithoutTurnSettingsStillDecode() throws {
    let id = UUID()
    let legacy = """
    {"id":"\(id.uuidString)","role":"user","content":"Hello","createdAt":0,
     "targetDestinationID":"alpha",
     "provenance":{"originClient":"desktop","receivedByHostRef":"host-a","receivedByHostName":"Example Mac"}}
    """
    let decoded = try JSONDecoder().decode(AIChatMessage.self, from: Data(legacy.utf8))
    XCTAssertEqual(decoded.provenance?.receivedByHostName, "Example Mac")
    XCTAssertNil(decoded.provenance?.turnSettings)

    let bare = """
    {"id":"\(UUID().uuidString)","role":"user","content":"Hi","createdAt":0}
    """
    XCTAssertNil(try JSONDecoder().decode(AIChatMessage.self, from: Data(bare.utf8)).provenance)

    let recorded = """
    {"id":"\(UUID().uuidString)","role":"user","content":"Hi","createdAt":0,
     "provenance":{"originClient":"desktop","turnSettings":{"destinationID":"alpha","model":"model-x","reasoningEffort":"high"}}}
    """
    let recordedMessage = try JSONDecoder().decode(AIChatMessage.self, from: Data(recorded.utf8))
    XCTAssertEqual(
      recordedMessage.provenance?.turnSettings,
      AIChatTurnSettings(destinationID: "alpha", model: "model-x", reasoningEffort: "high")
    )

    let partial = """
    {"id":"\(UUID().uuidString)","role":"user","content":"Hi","createdAt":0,
     "provenance":{"turnSettings":{"destinationID":"alpha"}}}
    """
    XCTAssertEqual(
      try JSONDecoder().decode(AIChatMessage.self, from: Data(partial.utf8)).provenance?.turnSettings,
      AIChatTurnSettings(destinationID: "alpha")
    )

    // A damaged value never makes the transcript unreadable.
    let damaged = """
    {"id":"\(UUID().uuidString)","role":"user","content":"Still here","createdAt":0,
     "provenance":{"turnSettings":"high"}}
    """
    XCTAssertEqual(try JSONDecoder().decode(AIChatMessage.self, from: Data(damaged.utf8)).content, "Still here")

    let roundTrip = try JSONDecoder().decode(AIChatMessage.self, from: JSONEncoder().encode(recordedMessage))
    XCTAssertEqual(roundTrip.provenance?.turnSettings, recordedMessage.provenance?.turnSettings)
    XCTAssertFalse(AIChatMessageProvenance(turnSettings: AIChatTurnSettings(destinationID: nil)).isEmpty)
  }

  func testTranscriptStorePreservesTurnSettings() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-turn-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("chat.json")
    let recorded = AIChatTurnSettings(destinationID: "alpha", model: "model-x", reasoningEffort: "high")
    let thread = AIChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [
        user("alpha", settings: recorded),
        AIChatMessage(role: .user, content: "Older message", targetDestinationID: "alpha"),
      ]
    )

    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [thread],
        selectedThreadID: thread.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let loaded = try XCTUnwrap(AIChatTranscriptStore.shared.loadIfAvailable(legacyURL: transcriptURL))
    let messages = try XCTUnwrap(loaded.snapshot.threads.first?.messages)
    XCTAssertEqual(messages.first?.provenance?.turnSettings, recorded)
    XCTAssertNil(messages.last?.provenance?.turnSettings)
  }

  @MainActor
  func testSendingRecordsTheThreadSelectionOnTheTurn() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-turn-send-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "AIChatTurnChange.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suiteName)
    }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { _, _, _, _ in "Answer" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    _ = store.createAIChatThread(runtime: .openClaw)
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    let destinationID = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID })?.destinationID)

    await store.sendAIChatMessage(text: "First question")
    let index = try XCTUnwrap(store.aiChatThreads.firstIndex(where: { $0.id == threadID }))
    store.aiChatThreads[index] = store.aiChatThreads[index].replacingAIChatMetadata(
      model: .some("model-x"),
      reasoningEffort: .some("high")
    )
    await store.sendAIChatMessage(text: "Second question")

    let turns = store.aiChatMessages(for: threadID).filter { $0.role == .user }
    XCTAssertEqual(turns.map(\.content), ["First question", "Second question"])
    XCTAssertEqual(turns.first?.provenance?.turnSettings, AIChatTurnSettings(destinationID: destinationID))
    XCTAssertEqual(
      turns.last?.provenance?.turnSettings,
      AIChatTurnSettings(destinationID: destinationID, model: "model-x", reasoningEffort: "high")
    )
    let markers = AIChatTurnChangeMarkers.markers(
      for: store.aiChatMessages(for: threadID),
      isSharedRoom: false,
      labels: labels
    )
    XCTAssertEqual(markers, [try XCTUnwrap(turns.last).id: "Switched to Model X · high effort"])
  }

  // MARK: - Fixtures

  private func settings(_ destinationID: String?, model: String? = nil, effort: String? = nil) -> AIChatTurnSettings {
    AIChatTurnSettings(destinationID: destinationID, model: model, reasoningEffort: effort)
  }

  private func user(
    _ targetDestinationID: String?,
    settings: AIChatTurnSettings? = nil,
    kind: AIChatMessage.DeliveryKind = .turn,
    dispatchCopy: Bool = false,
    provenance: AIChatMessageProvenance? = nil
  ) -> AIChatMessage {
    var provenance = provenance ?? AIChatMessageProvenance(originClient: .desktop)
    provenance.turnSettings = settings
    return AIChatMessage(
      role: .user,
      content: "Question",
      deliveryKind: kind,
      targetDestinationID: targetDestinationID,
      isRoomDispatchCopy: dispatchCopy,
      provenance: provenance
    )
  }

  private func reply() -> AIChatMessage {
    AIChatMessage(role: .assistant, content: "Answer", authorDestinationID: "alpha")
  }
}
