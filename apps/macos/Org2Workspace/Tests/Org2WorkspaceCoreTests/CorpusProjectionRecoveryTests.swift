import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class CorpusProjectionRecoveryTests: XCTestCase {
  /// A scan cancelled after publishing the file list but before projecting it
  /// left the link resolver and search empty: later scans saw no file change
  /// and skipped projection. The next scan must finish the projection.
  func testUnchangedRescanFinishesAnInterruptedProjection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-projection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<3 {
      try "#+title: Note \(index)\n:PROPERTIES:\n:ID: note-\(index)\n:END:\n* Heading \(index)\n"
        .write(to: root.appendingPathComponent("note-\(index).org"), atomically: true, encoding: .utf8)
    }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.setWorkspaceRealtimeRefreshActive(false)
    await store.refreshCorpusFiles()
    try await waitForResolverNodes(store)

    // Simulate the interrupted scan: files published, projection never ran.
    store.publishEmptyOrgRoamSearchProjection()
    store.corpusFilesAwaitingProjection = true
    XCTAssertTrue(store.orgRoamLinkResolver.nodes.isEmpty)

    await store.refreshCorpusFiles()
    try await waitForResolverNodes(store)
    XCTAssertFalse(store.corpusFilesAwaitingProjection)
  }

  private func waitForResolverNodes(_ store: WorkspaceStore) async throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if !store.orgRoamLinkResolver.nodes.isEmpty { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("The link resolver was never rebuilt")
  }
}
