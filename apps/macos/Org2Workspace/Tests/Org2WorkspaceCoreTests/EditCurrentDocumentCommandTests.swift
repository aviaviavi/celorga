import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// *File → Edit Document* (Command-E) opens the Source editor for the
/// document in the document pane, like the pane header's Edit button.
@MainActor
final class EditCurrentDocumentCommandTests: XCTestCase {
  func testEditDocumentOpensTheSourceEditorForTheViewedDocument() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store

    XCTAssertTrue(store.canEditCurrentDocument)
    store.editCurrentDocument()

    XCTAssertTrue(store.isEditingEntry)
    // Already editing: the command is disabled so Command-E reaches the text view.
    XCTAssertFalse(store.canEditCurrentDocument)
  }

  func testEditDocumentIsUnavailableWhenNothingEditableIsInView() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store

    store.isWorkspaceDetailPaneClosed = true
    XCTAssertFalse(store.canEditCurrentDocument)
    store.editCurrentDocument()
    XCTAssertFalse(store.isEditingEntry)
    store.isWorkspaceDetailPaneClosed = false

    let source = try XCTUnwrap(store.selectedEntrySource)
    store.selectedEntrySource = EntrySource(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.endLineExclusive,
      text: source.text,
      isSubtree: false,
      isEditable: false
    )
    XCTAssertFalse(store.canEditCurrentDocument)
    store.editCurrentDocument()
    XCTAssertFalse(store.isEditingEntry)
  }

  /// *Publish…* in a file's context menu opens the publisher for that file.
  func testPublishFromFileContextMenuOpensThePublisherForThatFile() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    store.selectedSurface = .aiChat

    let other = fixture.root.appendingPathComponent("other.org")
    try "* Other\n".write(to: other, atomically: true, encoding: .utf8)
    store.publishCorpusFile(CorpusFile(
      path: other.path,
      relativePath: other.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))

    XCTAssertTrue(store.isDocumentPublisherPresented)
    XCTAssertEqual(store.currentOrgSourceFile?.path, other.standardizedFileURL.path)
    // The surface the user right-clicked from stays in place.
    XCTAssertEqual(store.selectedSurface, .aiChat)
  }

  func testPublishIsOfferedOnlyForOrgDocuments() throws {
    XCTAssertTrue(WorkspaceStore.isPublishableDocument(path: "/c/notes/a.org"))
    XCTAssertTrue(WorkspaceStore.isPublishableDocument(path: "/c/notes/a.ORG2"))
    XCTAssertFalse(WorkspaceStore.isPublishableDocument(path: "/c/data/a.csv"))
    XCTAssertFalse(WorkspaceStore.isPublishableDocument(path: "/c/board.canvas"))

    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    fixture.store.publishCorpusFile(CorpusFile(
      path: fixture.root.appendingPathComponent("data.csv").path,
      relativePath: "data.csv",
      modifiedAt: nil,
      byteCount: nil
    ))
    XCTAssertFalse(fixture.store.isDocumentPublisherPresented)
  }

  private struct Fixture {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String
    let store: WorkspaceStore

    func cleanUp() {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func makeFixture() throws -> Fixture {
    let text = "#+TITLE: Notes\n\n* Heading\nBody\n"
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-edit-current-document-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("notes.org")
    try text.write(to: file, atomically: true, encoding: .utf8)
    let suiteName = "org2-edit-current-document-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: root.appendingPathComponent("missing-runtime", isDirectory: true)),
      defaults: defaults,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.selectCorpusFile(CorpusFile(
      path: file.path,
      relativePath: file.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    store.selectedEntrySource = EntrySource(
      file: file.path,
      startLine: 1,
      endLineExclusive: 5,
      text: text,
      isSubtree: false
    )
    store.editableEntryText = text
    store.isLoadingEntrySource = false
    return Fixture(root: root, defaults: defaults, suiteName: suiteName, store: store)
  }
}
