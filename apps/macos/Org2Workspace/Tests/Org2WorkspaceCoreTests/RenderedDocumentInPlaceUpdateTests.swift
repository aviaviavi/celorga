import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Acting on one entry in the rendered document (marking it DONE,
/// rescheduling it, moving a list item) used to drop the rendered page while
/// the file re-rendered, so the pane swapped to a loading view and then built
/// a new page from scratch. The page must stay up until the new render
/// arrives so the view can update only what changed.
final class RenderedDocumentInPlaceUpdateTests: XCTestCase {
  @MainActor
  func testHeadingMutationKeepsThePageOnScreenUntilTheNewRenderArrives() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-in-place-update-\(UUID().uuidString)", isDirectory: true)
    let suite = "org2-in-place-update-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    let file = root.appendingPathComponent("tasks.org")
    try "* TODO First task\n* TODO Second task\n".write(to: file, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.entryHTMLRendererForTesting = { text, _, _, _ in
      // A realistic render takes a moment; the page must stay up meanwhile.
      if text.contains("DONE") { try await Task.sleep(nanoseconds: 300_000_000) }
      return "<html><body>\(text)</body></html>"
    }
    store.selectCorpusFile(CorpusFile(path: file.path, relativePath: "tasks.org", modifiedAt: nil, byteCount: nil))
    try await waitUntil { store.selectedEntryHTML?.contains("TODO First task") == true }
    try await waitUntil { !store.selectedRenderedBlocks.isEmpty }
    let initialIdentity = store.selectedEntryHTMLRenderIdentity

    store.performRenderedEntryAction(.todo(.done), at: 1)

    var sawEmptyPage = false
    var sawStaleIdentityWithNewPage = false
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if store.selectedEntryHTML == nil { sawEmptyPage = true }
      if store.selectedEntryHTML?.contains("DONE First task") == true { break }
      if store.selectedEntryHTML?.contains("TODO First task") == true,
         store.selectedEntryHTMLRenderIdentity != initialIdentity {
        // The old page must keep the old identity, or the view would treat
        // the new render as the page it already shows.
        sawStaleIdentityWithNewPage = true
      }
      try await Task.sleep(nanoseconds: 2_000_000)
    }

    XCTAssertTrue(store.selectedEntryHTML?.contains("DONE First task") == true)
    XCTAssertFalse(sawEmptyPage, "The rendered page must not be dropped while the edited file re-renders")
    XCTAssertFalse(sawStaleIdentityWithNewPage)
    XCTAssertNotEqual(store.selectedEntryHTMLRenderIdentity, initialIdentity)
  }

  @MainActor
  private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(predicate())
  }
}
