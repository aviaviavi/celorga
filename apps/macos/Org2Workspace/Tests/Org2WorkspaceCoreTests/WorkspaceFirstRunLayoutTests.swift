import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceFirstRunLayoutTests: XCTestCase {
  func testLaunchGuideOffersEveryLocalAgentHarness() {
    let offered = Set(WorkspaceStore.launchGuideDestinationIDs)
    let localHarnesses = AIChatDestinationConfiguration.defaults
      .filter { [.codexLocal, .claudeLocal, .piLocal, .openCodeLocal].contains($0.adapter) }
      .map(\.id)
    XCTAssertEqual(localHarnesses.count, 4)
    for id in localHarnesses {
      XCTAssertTrue(offered.contains(id), "the first-run guide must offer \(id)")
    }
    XCTAssertTrue(offered.contains(AIChatDestinationConfiguration.openClawID))
  }

  @MainActor
  func testLaunchGuideConnectsOpenCode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-launch-opencode-\(UUID().uuidString)", isDirectory: true)
    let suiteName = "celorga-launch-opencode-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try WorkspaceStore.initializeStarterCorpus(at: root)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(root)
    XCTAssertTrue(store.isLaunchGuideDestinationInstalled(AIChatDestinationConfiguration.openClawID))

    store.completeLaunchGuide(destinationID: AIChatDestinationConfiguration.localOpenCodeID)
    await store.waitForDailyNoteNavigationForTesting()

    XCTAssertEqual(store.selectedAIChatThread?.destinationID, AIChatDestinationConfiguration.localOpenCodeID)
    XCTAssertEqual(store.aiChatDestination(id: AIChatDestinationConfiguration.localOpenCodeID)?.adapter, .openCodeLocal)
  }
}
