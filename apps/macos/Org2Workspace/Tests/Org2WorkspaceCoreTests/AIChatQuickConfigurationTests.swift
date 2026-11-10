import XCTest
@testable import Org2WorkspaceCore

final class AIChatQuickConfigurationTests: XCTestCase {
  func testSteppedModelStartsAtDefaultAndWraps() {
    let options = ["alpha", "beta"]
    XCTAssertEqual(AIChatQuickConfiguration.steppedModel(current: nil, options: options, by: 1), "alpha")
    XCTAssertEqual(AIChatQuickConfiguration.steppedModel(current: "alpha", options: options, by: 1), "beta")
    XCTAssertNil(AIChatQuickConfiguration.steppedModel(current: "beta", options: options, by: 1))
    XCTAssertEqual(AIChatQuickConfiguration.steppedModel(current: nil, options: options, by: -1), "beta")
    // An unknown override (a model the catalog no longer reports) steps from the default.
    XCTAssertEqual(AIChatQuickConfiguration.steppedModel(current: "gone", options: options, by: 1), "alpha")
    XCTAssertEqual(AIChatQuickConfiguration.steppedModel(current: "gone", options: [], by: 1), "gone")
  }

  func testSteppedReasoningEffortClampsFromEffectiveLevel() {
    let options = ["low", "medium", "high"]
    XCTAssertEqual(
      AIChatQuickConfiguration.steppedReasoningEffort(current: nil, defaultEffort: "medium", options: options, by: 1),
      "high"
    )
    XCTAssertEqual(
      AIChatQuickConfiguration.steppedReasoningEffort(current: "high", defaultEffort: "medium", options: options, by: 1),
      "high"
    )
    XCTAssertEqual(
      AIChatQuickConfiguration.steppedReasoningEffort(current: "low", defaultEffort: nil, options: options, by: -1),
      "low"
    )
    XCTAssertEqual(
      AIChatQuickConfiguration.steppedReasoningEffort(current: nil, defaultEffort: nil, options: options, by: -1),
      "high"
    )
    XCTAssertEqual(
      AIChatQuickConfiguration.steppedReasoningEffort(current: nil, defaultEffort: nil, options: options, by: 1),
      "low"
    )
  }

  @MainActor
  func testNumberedRuntimeCountsEnabledDestinationsAndConfiguresNewThread() throws {
    let suiteName = "AIChatQuickConfigurationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ai-chat-quick-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )

    let providerID = store.addAIChatDestination(adapter: .anthropic)
    let enabled = store.enabledAIChatDestinations
    let providerNumber = try XCTUnwrap(enabled.firstIndex(where: { $0.id == providerID })) + 1
    XCTAssertGreaterThanOrEqual(enabled.count, 2)
    XCTAssertNil(store.aiChatQuickDestination(number: 0))
    XCTAssertNil(store.aiChatQuickDestination(number: enabled.count + 1))
    XCTAssertEqual(store.aiChatQuickDestination(number: providerNumber)?.id, providerID)
    let other = try XCTUnwrap(enabled.first(where: { $0.id != providerID }))

    store.createAIChatThread(destinationID: other.id)
    store.selectAIChatQuickDestination(number: providerNumber)
    XCTAssertEqual(store.selectedAIChatDestination.id, providerID)

    store.aiChatModelOptions = [
      AIChatModelOption(id: "model-a", label: "Model A"),
      AIChatModelOption(id: "model-b", label: "Model B"),
    ]
    XCTAssertTrue(store.canStepAIChatModel)
    store.stepAIChatModel(by: 1)
    XCTAssertEqual(store.selectedAIChatModel, "model-a")
    store.stepAIChatModel(by: -1)
    XCTAssertNil(store.selectedAIChatModel)
  }
}
