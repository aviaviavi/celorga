import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class ClaudeModelSelectorTests: XCTestCase {
  /// Claude Code does not report its default model, so a chat on the default
  /// must not show the model another chat chose explicitly.
  func testClaudeDefaultModelIsNotLabelledWithAnEarlierExplicitChoice() async throws {
    let suiteName = "ClaudeModelSelectorTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-model-selector-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      claudeSendHandlerForTesting: { _, _, _ in
        ClaudeCodeTurnResult(sessionID: "session", reply: "ok")
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    var claude = try XCTUnwrap(AIChatDestinationConfiguration.defaults.first {
      $0.id == AIChatDestinationConfiguration.localClaudeID
    })
    claude.isEnabled = true
    store.updateAIChatDestination(claude)

    let firstThreadID = store.createAIChatThread(destinationID: claude.id)
    await store.refreshAIChatConfiguration()
    XCTAssertEqual(store.aiChatModelOptions.map(\.id), ["sonnet", "opus", "fable", "haiku"])
    XCTAssertEqual(store.selectedAIChatModelLabel, "Default model")
    // Claude Code takes --effort, so the reasoning picker has levels.
    XCTAssertEqual(store.aiChatReasoningOptions.map(\.id), ["low", "medium", "high", "xhigh", "max"])
    store.setSelectedAIChatReasoningEffort("max")
    XCTAssertEqual(store.selectedAIChatReasoningEffort, "max")
    XCTAssertEqual(store.selectedAIChatReasoningLabel, "Max")
    store.setSelectedAIChatReasoningEffort(nil)

    store.setSelectedAIChatModel("opus")
    XCTAssertEqual(
      store.aiChatReasoningOptions.map(\.id), ["low", "medium", "high", "xhigh", "max"],
      "changing the model must not hide Claude Code's effort levels"
    )
    await store.refreshAIChatConfiguration(applySelection: true)
    XCTAssertEqual(store.selectedAIChatModel, "opus")
    XCTAssertEqual(store.selectedAIChatModelLabel, "Opus")

    store.setSelectedAIChatModel("fable")
    await store.refreshAIChatConfiguration(applySelection: true)
    XCTAssertEqual(store.selectedAIChatModel, "fable")
    XCTAssertEqual(store.selectedAIChatModelLabel, "Fable")

    store.setSelectedAIChatModel(nil)
    await store.refreshAIChatConfiguration(applySelection: true)
    XCTAssertNil(store.selectedAIChatModel)
    XCTAssertNil(store.aiChatEffectiveModel)
    XCTAssertEqual(store.selectedAIChatModelLabel, "Default model")

    // Another chat's explicit choice must not leak into a default chat,
    // whether the label comes from the cache on selection or a refresh.
    let secondThreadID = store.createAIChatThread(destinationID: claude.id)
    store.setSelectedAIChatModel("haiku")
    await store.refreshAIChatConfiguration(applySelection: true)
    XCTAssertEqual(store.selectedAIChatModelLabel, "Haiku")
    store.selectAIChatThread(firstThreadID)
    XCTAssertNil(store.aiChatEffectiveModel)
    XCTAssertEqual(store.selectedAIChatModelLabel, "Default model")
    await store.refreshAIChatConfiguration()
    XCTAssertEqual(store.selectedAIChatModelLabel, "Default model")
    store.selectAIChatThread(secondThreadID)
    XCTAssertEqual(store.selectedAIChatModelLabel, "Haiku")
  }
}
