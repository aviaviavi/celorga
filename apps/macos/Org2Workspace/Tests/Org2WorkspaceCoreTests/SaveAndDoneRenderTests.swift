import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Save & Done must not hand the detail pane back to the rendered view before
/// the saved page is ready. Doing so swapped in the loading view, then the
/// native preview, then the web page — the flicker Avi saw on 2026-10-18.
final class SaveAndDoneRenderTests: XCTestCase {
  @MainActor
  func testSaveAndDoneLeavesTheEditorOnlyOnceTheSavedPageHasRendered() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-save-and-done-\(UUID().uuidString)", isDirectory: true)
    let suite = "org2-save-and-done-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    let file = root.appendingPathComponent("note.org")
    try "* Note\nOriginal body\n".write(to: file, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      legacyDefaultsDomains: []
    )
    store.formatOrgFilesOnSave = false
    store.orgCryptEncryptOnSave = false
    store.setCorpusRoot(root, persistsDefault: false)
    store.entryHTMLRendererForTesting = { text, _, _, _ in
      // A realistic render takes a moment; the pane must not change meanwhile.
      if text.contains("Edited") { try await Task.sleep(nanoseconds: 250_000_000) }
      return "<html><body>\(text)</body></html>"
    }
    store.selectCorpusFile(CorpusFile(path: file.path, relativePath: "note.org", modifiedAt: nil, byteCount: nil))
    try await waitUntil { store.selectedEntryHTML?.contains("Original body") == true }

    store.beginEditingSelectedEntry()
    XCTAssertTrue(store.isEditingEntry)
    let edited = "* Note\nEdited body\n"
    store.sourceEditorInteraction.text = edited
    store.noteSourceEditorLocalTextChanged(edited)
    XCTAssertTrue(store.entryEditorHasUnsavedChanges)

    await store.saveAndFinishActiveEdit()

    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
    XCTAssertTrue(
      store.selectedEntryHTML?.contains("Edited body") == true,
      "The rendered pane shows the saved page as soon as the editor closes, not a loading or interim view"
    )
  }

  /// The editor publishes typing and Vim commands on a short delay. A publish
  /// landing mid-save made that save stand down, and Save & Done then stayed
  /// in the editor (Avi, 2026-10-23). It must save the newest text and close.
  @MainActor
  func testSaveAndDoneClosesWhenNewerTextArrivesWhileSaving() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-save-and-done-race-\(UUID().uuidString)", isDirectory: true)
    let suite = "org2-save-and-done-race-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    let file = root.appendingPathComponent("note.org")
    try "* Note\nOriginal body\n".write(to: file, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      legacyDefaultsDomains: []
    )
    store.formatOrgFilesOnSave = false
    store.orgCryptEncryptOnSave = false
    store.setCorpusRoot(root, persistsDefault: false)
    store.entryHTMLRendererForTesting = { text, _, _, _ in "<html><body>\(text)</body></html>" }
    store.selectCorpusFile(CorpusFile(path: file.path, relativePath: "note.org", modifiedAt: nil, byteCount: nil))
    try await waitUntil { store.selectedEntryHTML?.contains("Original body") == true }

    store.beginEditingSelectedEntry()
    store.noteSourceEditorLocalTextChanged("* Note\nEdited body\n")
    let final = "* Note\nEdited body, then dd in normal mode\n"
    var deliveredLatePublish = false
    store.entrySaveDidFormatHookForTesting = {
      guard !deliveredLatePublish else { return }
      deliveredLatePublish = true
      store.sourceEditorInteraction.text = final
      store.noteSourceEditorLocalTextChanged(final)
    }

    await store.saveAndFinishActiveEdit()

    XCTAssertTrue(deliveredLatePublish)
    XCTAssertFalse(store.isEditingEntry, "Save & Done must leave the editor")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), final)
  }

  @MainActor
  func testRenderWaitIsBoundedSoASlowRenderNeverTrapsTheEditor() async throws {
    let suite = "org2-save-and-done-bound-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    let start = ContinuousClock.now
    await store.waitForInFlightEntryRender(timeoutNanoseconds: 50_000_000)
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "No render in flight returns immediately")
    XCTAssertLessThanOrEqual(WorkspaceStore.saveAndDoneRenderWaitNanoseconds, 2_000_000_000)
  }

  @MainActor
  private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(8)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertTrue(predicate())
  }
}
