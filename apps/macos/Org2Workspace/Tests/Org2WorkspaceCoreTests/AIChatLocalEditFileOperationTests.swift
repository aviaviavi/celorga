import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Agents in a chat thread can rename and trash corpus files through the same
/// SHA-bound preview/apply boundary as text edits.
@MainActor
final class AIChatLocalEditFileOperationTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let trash: URL
    let store: WorkspaceStore
    let broker: AIChatLocalEditBroker
    let cleanup: () -> Void
  }

  private func makeFixture(files: [String: String]) async throws -> Fixture {
    let suiteName = "AIChatLocalEditFileOperations.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName, isDirectory: true)
    let root = base.appendingPathComponent("corpus", isDirectory: true)
    let trash = base.appendingPathComponent("Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    for (path, text) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: base.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.aiChatLocalEditFileTrasher = { url in
      let destination = trash.appendingPathComponent(url.lastPathComponent)
      try FileManager.default.moveItem(at: url, to: destination)
      return destination
    }
    let broker = AIChatLocalEditBroker(
      documentReader: { _, path, _ in try store.aiChatLocalEditDocument(at: path) },
      replacementApplier: { _, edits in try await store.applyAIChatLocalEditReplacements(edits) }
    )
    await broker.beginTurn("turn")
    return Fixture(root: root, trash: trash, store: store, broker: broker) {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: base)
    }
  }

  private func preview(_ fixture: Fixture, edits: [[String: Any]]) async throws -> AIChatLocalEditCommandResult {
    let params = try JSONSerialization.data(withJSONObject: ["turnId": "turn", "edits": edits])
    return await fixture.broker.handle(
      command: AIChatLocalEditBroker.previewCommand,
      paramsJSON: String(decoding: params, as: UTF8.self)
    )
  }

  private func apply(_ fixture: Fixture, preview: AIChatLocalEditCommandResult) async throws -> AIChatLocalEditCommandResult {
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try XCTUnwrap(preview.payloadJSON).utf8)) as? [String: Any]
    )
    let previewID = try XCTUnwrap(payload["previewId"] as? String)
    return await fixture.broker.handle(
      command: AIChatLocalEditBroker.applyCommand,
      paramsJSON: #"{"turnId":"turn","previewId":"\#(previewID)"}"#
    )
  }

  private func changes(_ result: AIChatLocalEditCommandResult) throws -> [String: String] {
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try XCTUnwrap(result.payloadJSON).utf8)) as? [String: Any]
    )
    let changes = try XCTUnwrap(payload["changes"] as? [[String: Any]])
    return Dictionary(uniqueKeysWithValues: changes.compactMap { change in
      (change["path"] as? String).map { ($0, change["status"] as? String ?? "") }
    })
  }

  func testRenameMovesTextTrashesTheSourceAndCarriesItsPin() async throws {
    let text = "* Recipes\n** Soup\n"
    let fixture = try await makeFixture(files: ["notes/recipes.org2": text])
    defer { fixture.cleanup() }
    let source = fixture.root.appendingPathComponent("notes/recipes.org2")
    let destination = fixture.root.appendingPathComponent("notes/recipes.org")
    fixture.store.togglePinnedFile(path: source.path)

    let preview = try await preview(fixture, edits: [[
      "path": "notes/recipes.org2",
      "expectedSha256": AIChatLocalEditBroker.sha256(text),
      "moveTo": "notes/recipes.org"
    ]])
    XCTAssertTrue(preview.ok, preview.errorMessage ?? "Preview failed")
    XCTAssertEqual(try changes(preview), ["notes/recipes.org": "created", "notes/recipes.org2": "deleted"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "preview must not move files")

    let applied = try await apply(fixture, preview: preview)
    XCTAssertTrue(applied.ok, applied.errorMessage ?? "Apply failed")
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), text)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(
      try String(contentsOf: fixture.trash.appendingPathComponent("recipes.org2"), encoding: .utf8),
      text
    )
    XCTAssertEqual(fixture.store.pinnedFileRelativePaths, ["notes/recipes.org"])
  }

  func testTrashMovesAnExistingFileToTheTrash() async throws {
    let text = "Redirect to notes/recipes.org\n"
    let fixture = try await makeFixture(files: ["recipes.org": text])
    defer { fixture.cleanup() }

    let preview = try await preview(fixture, edits: [[
      "path": "recipes.org",
      "expectedSha256": AIChatLocalEditBroker.sha256(text),
      "trashesFile": true
    ]])
    XCTAssertTrue(preview.ok, preview.errorMessage ?? "Preview failed")
    XCTAssertEqual(try changes(preview), ["recipes.org": "deleted"])
    let applied = try await apply(fixture, preview: preview)
    XCTAssertTrue(applied.ok, applied.errorMessage ?? "Apply failed")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("recipes.org").path))
    XCTAssertEqual(
      try String(contentsOf: fixture.trash.appendingPathComponent("recipes.org"), encoding: .utf8),
      text
    )
  }

  func testFileOperationsRejectUnsafeRequests() async throws {
    let fixture = try await makeFixture(files: ["a.org": "A\n", "b.org": "B\n"])
    defer { fixture.cleanup() }
    let sha = AIChatLocalEditBroker.sha256("A\n")

    let ontoExisting = try await preview(fixture, edits: [["path": "a.org", "expectedSha256": sha, "moveTo": "b.org"]])
    XCTAssertEqual(ontoExisting.errorCode, "EXISTING_DOCUMENT")
    let stale = try await preview(fixture, edits: [["path": "a.org", "expectedSha256": "0", "trashesFile": true]])
    XCTAssertEqual(stale.errorCode, "STALE_DOCUMENT")
    let unhashed = try await preview(fixture, edits: [["path": "a.org", "trashesFile": true]])
    XCTAssertEqual(unhashed.errorCode, "INVALID_REQUEST")
    let trashWithText = try await preview(fixture, edits: [[
      "path": "a.org", "expectedSha256": sha, "trashesFile": true, "replacementText": "x"
    ]])
    XCTAssertEqual(trashWithText.errorCode, "INVALID_REQUEST")
    let missing = try await preview(fixture, edits: [["path": "c.org", "expectedSha256": sha, "trashesFile": true]])
    XCTAssertEqual(missing.errorCode, "MISSING_DOCUMENT")
    let outside = try await preview(fixture, edits: [["path": "a.org", "expectedSha256": sha, "moveTo": "../a.org"]])
    XCTAssertFalse(outside.ok)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("a.org").path))
  }

  func testFailedTrashRollsBackTheRenamedCopy() async throws {
    let fixture = try await makeFixture(files: ["notes/old.org": "Old\n"])
    defer { fixture.cleanup() }
    fixture.store.aiChatLocalEditFileTrasher = { _ in
      throw CocoaError(.fileWriteNoPermission)
    }
    let preview = try await preview(fixture, edits: [[
      "path": "notes/old.org",
      "expectedSha256": AIChatLocalEditBroker.sha256("Old\n"),
      "moveTo": "notes/new.org"
    ]])
    XCTAssertTrue(preview.ok, preview.errorMessage ?? "Preview failed")
    let applied = try await apply(fixture, preview: preview)
    XCTAssertFalse(applied.ok)
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appendingPathComponent("notes/old.org"), encoding: .utf8),
      "Old\n"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("notes/new.org").path))
  }

  func testCodexToolSchemaAdvertisesRenameAndTrash() throws {
    let preview = try XCTUnwrap(CodexAppServerClient.localEditDynamicTools.first {
      $0["name"]?.stringValue == "celorga_workspace_patch_preview"
    })
    let item = try XCTUnwrap(preview["inputSchema"]?["properties"]?["edits"]?["items"])
    XCTAssertNotNil(item["properties"]?["moveTo"])
    XCTAssertNotNil(item["properties"]?["trashesFile"])
    XCTAssertEqual(item["required"]?.arrayValue?.compactMap(\.stringValue), ["path"])
    let instructions = CodexAppServerClient.developerInstructions(for: .clientWorkspaceTools)
    XCTAssertTrue(instructions.contains("moveTo"))
    XCTAssertTrue(instructions.contains("trashesFile"))
  }

  func testBundledAgentReviewNamesRenamesAndTrash() {
    let review = BundledAgentWorkspaceTools.reviewText(
      corpusRoot: URL(fileURLWithPath: "/corpus"),
      edits: [
        .object(["path": .string("notes/a.org2"), "expectedSha256": .string("s1"), "moveTo": .string("notes/a.org")]),
        .object(["path": .string("a.org"), "expectedSha256": .string("s2"), "trashesFile": .bool(true)]),
      ],
      reads: ["s1": "A\n", "s2": "Redirect\n"]
    )
    XCTAssertTrue(review.contains("RENAME: notes/a.org2 → notes/a.org"))
    XCTAssertTrue(review.contains("AFTER\nA\n"))
    XCTAssertTrue(review.contains("MOVE TO TRASH: a.org"))
  }
}
