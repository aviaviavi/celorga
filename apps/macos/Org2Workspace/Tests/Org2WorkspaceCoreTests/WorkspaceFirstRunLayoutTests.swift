import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceFirstRunLayoutTests: XCTestCase {
  func testFirstWindowFillsMostOfALaptopScreen() {
    // A 13-inch laptop's visible area at its default scaling.
    let laptop = WorkspaceWindowLayout.defaultSize(forVisibleScreenSize: CGSize(width: 1_470, height: 919))
    XCTAssertGreaterThanOrEqual(laptop.width, 1_300)
    XCTAssertLessThanOrEqual(laptop.width, 1_470)
    XCTAssertGreaterThanOrEqual(laptop.height, 800)
    XCTAssertLessThanOrEqual(laptop.height, 919)
    XCTAssertGreaterThan(laptop.width, WorkspaceWindowLayout.minimumWidth)

    let large = WorkspaceWindowLayout.defaultSize(forVisibleScreenSize: CGSize(width: 3_000, height: 1_800))
    XCTAssertEqual(large.width, 1_680)
    XCTAssertEqual(large.height, 1_080)

    let tiny = WorkspaceWindowLayout.defaultSize(forVisibleScreenSize: CGSize(width: 700, height: 500))
    XCTAssertEqual(tiny.width, WorkspaceWindowLayout.minimumWidth)
    XCTAssertEqual(tiny.height, WorkspaceWindowLayout.minimumHeight)

    let unknown = WorkspaceWindowLayout.defaultSize(forVisibleScreenSize: nil)
    XCTAssertGreaterThan(unknown.width, WorkspaceWindowLayout.minimumWidth)
  }

  func testMacOS26UsesAFlushSidebarInsteadOfTheFloatingPanel() {
    XCTAssertEqual(WorkspaceSidebarPresentation.presentation(forMacOSMajorVersion: 14), .systemSplitView)
    XCTAssertEqual(WorkspaceSidebarPresentation.presentation(forMacOSMajorVersion: 15), .systemSplitView)
    XCTAssertEqual(WorkspaceSidebarPresentation.presentation(forMacOSMajorVersion: 26), .flushColumn)
    XCTAssertEqual(WorkspaceSidebarPresentation.presentation(forMacOSMajorVersion: 27), .flushColumn)
    XCTAssertEqual(
      WorkspaceSidebarPresentation.presentation(forMacOSMajorVersion: 15, override: " Flush "),
      .flushColumn
    )
    XCTAssertEqual(
      WorkspaceSidebarPresentation.presentation(forMacOSMajorVersion: 26, override: "system"),
      .systemSplitView
    )
    XCTAssertEqual(
      WorkspaceSidebarPresentation.presentation(forMacOSMajorVersion: 26, override: "other"),
      .flushColumn
    )
  }

  func testFlushSidebarWidthDefaultsAndStaysWithinSystemSidebarBounds() {
    let container: CGFloat = 1600
    XCTAssertEqual(
      WorkspaceSidebarLayout.flushWidth(stored: nil, containerWidth: container),
      WorkspaceSidebarLayout.defaultWidth(for: container)
    )
    XCTAssertEqual(WorkspaceSidebarLayout.flushWidth(stored: 300, containerWidth: container), 300)
    XCTAssertEqual(
      WorkspaceSidebarLayout.flushWidth(stored: 100, containerWidth: container),
      WorkspaceSidebarLayout.minimumWidth
    )
    XCTAssertEqual(
      WorkspaceSidebarLayout.flushWidth(stored: 900, containerWidth: container),
      WorkspaceSidebarLayout.maximumWidth(for: container)
    )
  }

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
