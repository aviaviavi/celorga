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

  /// The picker lists the models Claude Code reports, named with their
  /// versions, and offers each model's own effort levels, including right
  /// after switching chats, before a refresh finishes.
  func testDiscoveredClaudeCatalogDrivesModelAndEffortPickers() async throws {
    let suiteName = "ClaudeModelSelectorTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-model-catalog-\(UUID().uuidString)", isDirectory: true)
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
    let catalog = ClaudeCodeClient.modelOptions(fromReportedModels: claudeReportedModelRowsForTesting)
    store.claudeModelCatalogForTesting = { catalog }
    store.setCorpusRoot(root, persistsDefault: false)
    var claude = try XCTUnwrap(AIChatDestinationConfiguration.defaults.first {
      $0.id == AIChatDestinationConfiguration.localClaudeID
    })
    claude.isEnabled = true
    store.updateAIChatDestination(claude)

    let firstThreadID = store.createAIChatThread(destinationID: claude.id)
    await store.refreshAIChatConfiguration()
    XCTAssertEqual(
      store.aiChatModelOptions.map(\.label),
      ["Opus 5.5", "Opus 5.5 (1M context)", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"]
    )
    XCTAssertNil(store.selectedAIChatModel, "the default chat passes no --model")
    XCTAssertEqual(store.selectedAIChatModelLabel, "Opus 5.5")
    XCTAssertEqual(AIChatModelOption.defaultEntryTitle(in: store.aiChatModelOptions), "Default (Opus 5.5)")
    XCTAssertEqual(store.aiChatReasoningOptions.map(\.id), ["low", "medium", "high", "xhigh", "max"])

    store.setSelectedAIChatModel("sonnet")
    XCTAssertEqual(store.aiChatReasoningOptions.map(\.id), ["low", "medium", "high"])
    await store.refreshAIChatConfiguration(applySelection: true)
    XCTAssertEqual(store.selectedAIChatModelLabel, "Sonnet 5.5")
    XCTAssertEqual(store.aiChatReasoningOptions.map(\.id), ["low", "medium", "high"])

    let secondThreadID = store.createAIChatThread(destinationID: claude.id)
    store.setSelectedAIChatModel("fable")
    await store.refreshAIChatConfiguration(applySelection: true)
    store.setSelectedAIChatReasoningEffort("max")
    XCTAssertEqual(store.selectedAIChatModelLabel, "Fable 5.2")

    // Switching chats restores the cached catalog immediately; the effort
    // control must not read "No reasoning levels" until a refresh lands.
    store.selectAIChatThread(firstThreadID)
    XCTAssertEqual(store.selectedAIChatModelLabel, "Sonnet 5.5")
    XCTAssertEqual(store.aiChatReasoningOptions.map(\.id), ["low", "medium", "high"])
    store.selectAIChatThread(secondThreadID)
    XCTAssertEqual(store.selectedAIChatModelLabel, "Fable 5.2")
    XCTAssertEqual(store.selectedAIChatReasoningLabel, "Max")
    XCTAssertEqual(store.aiChatReasoningOptions.map(\.id), ["low", "medium", "high", "xhigh", "max"])

    store.setSelectedAIChatModel("haiku")
    XCTAssertEqual(store.aiChatReasoningOptions, [], "Haiku reports no effort levels")
    XCTAssertNil(store.selectedAIChatReasoningEffort)

    XCTAssertEqual(
      WorkspaceStore.aiChatRoomReasoningOptions(
        adapter: .claudeLocal,
        selectedModel: "sonnet",
        models: catalog
      ).map(\.id),
      ["low", "medium", "high"]
    )
  }
}
