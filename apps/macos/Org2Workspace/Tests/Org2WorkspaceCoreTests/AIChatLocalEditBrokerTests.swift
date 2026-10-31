import Foundation
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatLocalEditBrokerTests: XCTestCase {
  private final class DocumentStore {
    var documents: [String: AIChatLocalEditDocument]

    init(documents: [String: AIChatLocalEditDocument]) {
      self.documents = documents
    }

    func read(_ path: String) throws -> AIChatLocalEditDocument {
      documents[path]
        ?? AIChatLocalEditDocument(relativePath: path, text: "", origin: .missing)
    }

    func apply(
      _ replacements: [AIChatLocalEditReplacement]
    ) async throws -> AIChatLocalEditApplyResult {
      let changes = try replacements.compactMap { replacement in
        let before = try read(replacement.relativePath)
        guard replacement.createsFile
          ? before.origin == .missing
          : before.sha256 == replacement.expectedSHA256
        else {
          throw AIChatLocalEditError.staleDocument(replacement.relativePath)
        }
        let change = AIChatLocalEditBroker.fileChange(
          path: replacement.relativePath,
          before: replacement.createsFile ? nil : before.text,
          after: replacement.replacementText
        )
        documents[replacement.relativePath] = AIChatLocalEditDocument(
          relativePath: replacement.relativePath,
          text: replacement.replacementText,
          origin: .disk
        )
        return change
      }
      return AIChatLocalEditApplyResult(
        summary: AIChatCorpusChangeSummary(files: changes)
      )
    }
  }

  func testReadReturnsEffectiveEditorTextOnlyForActiveTurn() async throws {
    let store = DocumentStore(documents: [
      "notes/today.org2": AIChatLocalEditDocument(
        relativePath: "notes/today.org2",
        text: "* Draft in editor\n",
        origin: .editor
      )
    ])
    let broker = makeBroker(store)
    let params = #"{"turnId":"turn-1","path":"notes/today.org2"}"#

    let inactive = await broker.handle(
      command: AIChatLocalEditBroker.readCommand,
      paramsJSON: params
    )
    XCTAssertFalse(inactive.ok)
    XCTAssertEqual(inactive.errorCode, "INACTIVE_TURN")

    await broker.beginTurn("turn-1")
    let result = await broker.handle(
      command: AIChatLocalEditBroker.readCommand,
      paramsJSON: params
    )
    XCTAssertTrue(result.ok)
    let payload = try jsonObject(result.payloadJSON)
    XCTAssertEqual(payload["text"] as? String, "* Draft in editor\n")
    XCTAssertEqual(payload["origin"] as? String, "editor")
    XCTAssertEqual(
      payload["sha256"] as? String,
      AIChatLocalEditBroker.sha256("* Draft in editor\n")
    )
  }

  func testReadPassesAnExplicitAuthorizedCorpusRootToTheClient() async throws {
    var receivedRoot: String?
    let broker = AIChatLocalEditBroker(
      documentReader: { _, path, corpusRoot in
        receivedRoot = corpusRoot
        return AIChatLocalEditDocument(
          relativePath: path,
          text: "* Shared context\n",
          origin: .disk
        )
      },
      replacementApplier: { _, _ in
        AIChatLocalEditApplyResult(summary: AIChatCorpusChangeSummary(files: []))
      }
    )
    await broker.beginTurn("turn-shared-read")

    let result = await broker.handle(
      command: AIChatLocalEditBroker.readCommand,
      paramsJSON: #"{"turnId":"turn-shared-read","path":"notes/shared.org2","corpusRoot":"/tmp/team"}"#
    )

    XCTAssertTrue(result.ok)
    XCTAssertEqual(receivedRoot, "/tmp/team")
    XCTAssertEqual(try jsonObject(result.payloadJSON)["text"] as? String, "* Shared context\n")
  }

  func testPreviewRequiresHashAndApplyRejectsAChangedDocument() async throws {
    let initialText = "* Original\n"
    let store = DocumentStore(documents: [
      "notes/topic.org2": AIChatLocalEditDocument(
        relativePath: "notes/topic.org2",
        text: initialText,
        origin: .disk
      )
    ])
    let broker = makeBroker(store)
    await broker.beginTurn("turn-2")

    let missingHash = await broker.handle(
      command: AIChatLocalEditBroker.previewCommand,
      paramsJSON: #"{"turnId":"turn-2","edits":[{"path":"notes/topic.org2","replacementText":"* Next\n"}]}"#
    )
    XCTAssertFalse(missingHash.ok)
    XCTAssertEqual(missingHash.errorCode, "INVALID_REQUEST")

    let preview = await broker.handle(
      command: AIChatLocalEditBroker.previewCommand,
      paramsJSON: previewParams(
        turnID: "turn-2",
        path: "notes/topic.org2",
        expectedSHA256: AIChatLocalEditBroker.sha256(initialText),
        replacementText: "* Next\n"
      )
    )
    XCTAssertTrue(preview.ok)
    let previewID = try XCTUnwrap(try jsonObject(preview.payloadJSON)["previewId"] as? String)

    store.documents["notes/topic.org2"] = AIChatLocalEditDocument(
      relativePath: "notes/topic.org2",
      text: "* Background change\n",
      origin: .disk
    )
    let apply = await broker.handle(
      command: AIChatLocalEditBroker.applyCommand,
      paramsJSON: #"{"turnId":"turn-2","previewId":"\#(previewID)"}"#
    )
    XCTAssertFalse(apply.ok)
    XCTAssertEqual(apply.errorCode, "STALE_DOCUMENT")
    XCTAssertEqual(store.documents["notes/topic.org2"]?.text, "* Background change\n")
  }

  func testAppliedSummaryIsAttributedOnlyToItsTurn() async throws {
    let initialText = "* Original\n"
    let replacementText = "* Original\nNew local line\n"
    let store = DocumentStore(documents: [
      "notes/topic.org2": AIChatLocalEditDocument(
        relativePath: "notes/topic.org2",
        text: initialText,
        origin: .editor
      ),
      "notes/background.org2": AIChatLocalEditDocument(
        relativePath: "notes/background.org2",
        text: "Before\n",
        origin: .disk
      )
    ])
    let broker = makeBroker(store)
    await broker.beginTurn("turn-local")
    await broker.beginTurn("turn-background")

    let preview = await broker.handle(
      command: AIChatLocalEditBroker.previewCommand,
      paramsJSON: previewParams(
        turnID: "turn-local",
        path: "notes/topic.org2",
        expectedSHA256: AIChatLocalEditBroker.sha256(initialText),
        replacementText: replacementText
      )
    )
    let previewID = try XCTUnwrap(try jsonObject(preview.payloadJSON)["previewId"] as? String)

    // This represents unrelated work occurring while the chat turn is active.
    store.documents["notes/background.org2"] = AIChatLocalEditDocument(
      relativePath: "notes/background.org2",
      text: "After\n",
      origin: .disk
    )
    let apply = await broker.handle(
      command: AIChatLocalEditBroker.applyCommand,
      paramsJSON: #"{"turnId":"turn-local","previewId":"\#(previewID)"}"#
    )
    XCTAssertTrue(apply.ok)

    let consumedLocalSummary = await broker.consumeChangeSummary(for: "turn-local")
    let localSummary = try XCTUnwrap(consumedLocalSummary)
    XCTAssertEqual(localSummary.files.map(\.relativePath), ["notes/topic.org2"])
    XCTAssertEqual(localSummary.totalInsertions, 1)
    let backgroundSummary = await broker.consumeChangeSummary(for: "turn-background")
    XCTAssertNil(backgroundSummary)
  }

  func testAppliedSummaryUsesOriginalAndFinalTextAcrossMultipleApplies() async throws {
    let originalText = "* Original\n"
    let intermediateText = "* Intermediate\n"
    let store = DocumentStore(documents: [
      "notes/topic.org2": AIChatLocalEditDocument(
        relativePath: "notes/topic.org2",
        text: originalText,
        origin: .disk
      )
    ])
    let broker = makeBroker(store)
    await broker.beginTurn("turn-multiple")

    let firstPreview = await broker.handle(
      command: AIChatLocalEditBroker.previewCommand,
      paramsJSON: previewParams(
        turnID: "turn-multiple",
        path: "notes/topic.org2",
        expectedSHA256: AIChatLocalEditBroker.sha256(originalText),
        replacementText: intermediateText
      )
    )
    let firstPreviewID = try XCTUnwrap(
      try jsonObject(firstPreview.payloadJSON)["previewId"] as? String
    )
    let firstApply = await broker.handle(
      command: AIChatLocalEditBroker.applyCommand,
      paramsJSON: #"{"turnId":"turn-multiple","previewId":"\#(firstPreviewID)"}"#
    )
    XCTAssertTrue(firstApply.ok)

    let secondPreview = await broker.handle(
      command: AIChatLocalEditBroker.previewCommand,
      paramsJSON: previewParams(
        turnID: "turn-multiple",
        path: "notes/topic.org2",
        expectedSHA256: AIChatLocalEditBroker.sha256(intermediateText),
        replacementText: originalText
      )
    )
    let secondPreviewID = try XCTUnwrap(
      try jsonObject(secondPreview.payloadJSON)["previewId"] as? String
    )
    let secondApply = await broker.handle(
      command: AIChatLocalEditBroker.applyCommand,
      paramsJSON: #"{"turnId":"turn-multiple","previewId":"\#(secondPreviewID)"}"#
    )
    XCTAssertTrue(secondApply.ok)

    let summary = await broker.consumeChangeSummary(for: "turn-multiple")
    XCTAssertNil(summary)
  }

  func testWorkspacePromptDocumentsTheTypedNodeContract() {
    let context = AIChatLocalEditWorkspaceContext(
      nodeDisplayName: "OpenOrg Local Edits (Codex)",
      turnID: "turn-3"
    )
    let prompt = context.systemPrompt()
    XCTAssertTrue(prompt.contains(AIChatLocalEditBroker.readCommand))
    XCTAssertTrue(prompt.contains(AIChatLocalEditBroker.previewCommand))
    XCTAssertTrue(prompt.contains(AIChatLocalEditBroker.applyCommand))
    XCTAssertTrue(prompt.contains(#""turnId":"turn-3""#))
    XCTAssertTrue(prompt.contains("Do not edit corpus files with Gateway filesystem or shell tools"))
  }

  func testNodeClaimsOnlyTypedOrg2Commands() throws {
    let claims = OpenClawLocalEditNode.connectionClaims(displayName: "OpenOrg Local Edits")
    XCTAssertEqual(claims["role"] as? String, "node")
    XCTAssertEqual(claims["caps"] as? [String], ["org2"])
    XCTAssertEqual(
      claims["commands"] as? [String],
      [
        AIChatLocalEditBroker.readCommand,
        AIChatLocalEditBroker.previewCommand,
        AIChatLocalEditBroker.applyCommand
      ]
    )
  }

  func testWorkspaceReadAndApplyPreserveUnsavedPageDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-local-edit-workspace-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("draft.org2")
    try "* Original\n".write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    for _ in 0..<3 {
      await store.loadEntrySource(for: location)
      if store.selectedEntrySource != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    _ = try XCTUnwrap(store.selectedEntrySource)
    store.beginEditingCurrentScope()
    XCTAssertTrue(store.isEditingEntry)
    store.editableEntryText = "* Original\nUnsaved user line\n"
    store.noteSourceEditorLocalTextChanged(store.editableEntryText)

    let effective = try store.aiChatLocalEditDocument(at: "draft.org2")
    XCTAssertEqual(effective.origin, .editor)
    XCTAssertEqual(effective.text, "* Original\nUnsaved user line\n")
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "* Original\n")

    let replacement = effective.text + "Agent line\n"
    let applied = try await store.applyAIChatLocalEditReplacements([
      AIChatLocalEditReplacement(
        relativePath: "draft.org2",
        expectedSHA256: effective.sha256,
        replacementText: replacement,
        createsFile: false
      )
    ])

    XCTAssertEqual(applied.summary.files.map(\.relativePath), ["draft.org2"])
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), replacement)
    XCTAssertEqual(store.selectedEntrySource?.text, replacement)
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)
  }

  func testWorkspaceLocalEditRejectsPathsOutsideActiveCorpus() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-local-edit-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    XCTAssertThrowsError(try store.aiChatLocalEditDocument(at: "../outside.org2")) { error in
      XCTAssertTrue(error.localizedDescription.contains("relative to the active corpus"))
    }
  }

  func testWorkspaceLocalEditUsesExplicitOriginatingCorpusRoot() async throws {
    let firstRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-local-edit-origin-\(UUID().uuidString)", isDirectory: true)
    let secondRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-local-edit-other-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: firstRoot)
      try? FileManager.default.removeItem(at: secondRoot)
    }
    let firstNote = firstRoot.appendingPathComponent("shared-name.org2")
    let secondNote = secondRoot.appendingPathComponent("shared-name.org2")
    try "* First corpus\n".write(to: firstNote, atomically: true, encoding: .utf8)
    try "* Second corpus\n".write(to: secondNote, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let original = try store.aiChatLocalEditDocument(
      at: "shared-name.org2",
      corpusRoot: firstRoot
    )
    _ = try await store.applyAIChatLocalEditReplacements(
      [
        AIChatLocalEditReplacement(
          relativePath: "shared-name.org2",
          expectedSHA256: original.sha256,
          replacementText: "* First corpus updated\n",
          createsFile: false
        )
      ],
      corpusRoot: firstRoot
    )

    XCTAssertEqual(
      try String(contentsOf: firstNote, encoding: .utf8),
      "* First corpus updated\n"
    )
    XCTAssertEqual(
      try String(contentsOf: secondNote, encoding: .utf8),
      "* Second corpus\n"
    )
  }

  func testWorkspaceLocalEditCreateCanBeUndoneAndRedone() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-local-edit-create-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let created = root.appendingPathComponent("new/nested/created.org2")
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    _ = try await store.applyAIChatLocalEditReplacements([
      AIChatLocalEditReplacement(
        relativePath: "new/nested/created.org2",
        expectedSHA256: nil,
        replacementText: "* Created\n",
        createsFile: true
      )
    ])
    XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "* Created\n")

    store.performUndoCommand()
    try await waitForCondition {
      // File removal precedes the asynchronous catalog refresh and redo
      // registration. Wait for the command to finish before issuing redo.
      !FileManager.default.fileExists(atPath: created.path)
        && store.workspaceRedoStack.count == 1
    }

    store.performRedoCommand()
    try await waitForCondition {
      (try? String(contentsOf: created, encoding: .utf8)) == "* Created\n"
    }
  }

  func testHTMLLocalEditPreviewApplyAndStaleGuard() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-html-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    let broker = AIChatLocalEditBroker(
      documentReader: { _, path, _ in try store.aiChatLocalEditDocument(at: path) },
      replacementApplier: { _, edits in try await store.applyAIChatLocalEditReplacements(edits) }
    )
    await broker.beginTurn("html")
    for (index, ext) in ["html", "htm", "xhtml", "HTML"].enumerated() {
      let path = "views/demo-\(index).\(ext)"
      let text = "<!doctype html><p>Diagram → preview</p>\n"
      let params = try JSONSerialization.data(withJSONObject: [
        "turnId": "html", "edits": [["path": path, "createsFile": true, "replacementText": text]]
      ])
      let preview = await broker.handle(command: AIChatLocalEditBroker.previewCommand,
        paramsJSON: String(decoding: params, as: UTF8.self))
      XCTAssertTrue(preview.ok, preview.errorMessage ?? "Preview failed")
      guard preview.ok else { continue }
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
      let previewID = try XCTUnwrap(try jsonObject(preview.payloadJSON)["previewId"] as? String)
      let apply = await broker.handle(command: AIChatLocalEditBroker.applyCommand,
        paramsJSON: #"{"turnId":"html","previewId":"\#(previewID)"}"#)
      XCTAssertTrue(apply.ok, apply.errorMessage ?? "Apply failed")
      let read = try store.aiChatLocalEditDocument(at: path)
      XCTAssertEqual(read.text, text)
      XCTAssertEqual(read.origin, .disk)
      try "Changed externally".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
      do {
        _ = try await store.applyAIChatLocalEditReplacements([
          .init(relativePath: path, expectedSHA256: read.sha256, replacementText: "<p>Replacement</p>", createsFile: false)
        ])
        XCTFail("Stale HTML must not be overwritten")
      } catch {
        XCTAssertEqual(error as? AIChatLocalEditError, .staleDocument(path))
      }
    }
    XCTAssertThrowsError(try store.aiChatLocalEditDocument(at: "views/image.png"))
    XCTAssertThrowsError(try store.aiChatLocalEditDocument(at: "../outside.html"))
  }

  func testNestedLocalEditPreviewIsReadOnlyAndApplyCreatesParents() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-nested-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    let path = ".agents/skills/recall/SKILL.md"
    let broker = AIChatLocalEditBroker(
      documentReader: { _, path, _ in try store.aiChatLocalEditDocument(at: path) },
      replacementApplier: { _, edits in try await store.applyAIChatLocalEditReplacements(edits) }
    )
    await broker.beginTurn("nested")
    XCTAssertEqual(try store.aiChatLocalEditDocument(at: path).origin, .missing)
    let preview = await broker.handle(
      command: AIChatLocalEditBroker.previewCommand,
      paramsJSON: #"{"turnId":"nested","edits":[{"path":".agents/skills/recall/SKILL.md","createsFile":true,"replacementText":"Skill body\n"}]}"#
    )
    XCTAssertTrue(preview.ok, preview.errorMessage ?? "Preview failed")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".agents").path))
    let previewID = try XCTUnwrap(try jsonObject(preview.payloadJSON)["previewId"] as? String)
    let apply = await broker.handle(
      command: AIChatLocalEditBroker.applyCommand,
      paramsJSON: #"{"turnId":"nested","previewId":"\#(previewID)"}"#
    )
    XCTAssertTrue(apply.ok, apply.errorMessage ?? "Apply failed")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "Skill body\n")
  }

  func testNestedLocalEditRejectsOutsideSymlinkAncestor() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-symlink-edit-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-outside-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    XCTAssertThrowsError(try store.aiChatLocalEditDocument(at: "escape/new/deep/note.org"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))

    let broker = AIChatLocalEditBroker(
      documentReader: { _, path, _ in try store.aiChatLocalEditDocument(at: path) },
      replacementApplier: { _, edits in try await store.applyAIChatLocalEditReplacements(edits) }
    )
    await broker.beginTurn("swap")
    let preview = await broker.handle(
      command: AIChatLocalEditBroker.previewCommand,
      paramsJSON: #"{"turnId":"swap","edits":[{"path":"later/new/note.org","createsFile":true,"replacementText":"* Note\n"}]}"#
    )
    XCTAssertTrue(preview.ok, preview.errorMessage ?? "Preview failed")
    let previewID = try XCTUnwrap(try jsonObject(preview.payloadJSON)["previewId"] as? String)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("later"), withDestinationURL: outside)
    let apply = await broker.handle(
      command: AIChatLocalEditBroker.applyCommand,
      paramsJSON: #"{"turnId":"swap","previewId":"\#(previewID)"}"#
    )
    XCTAssertFalse(apply.ok)
    XCTAssertEqual(apply.errorCode, "INVALID_REQUEST")
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
  }

  func testNestedLocalEditRejectsNonDirectoryAndDanglingParents() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-invalid-parent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "file".write(to: root.appendingPathComponent("plain"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("dangling"),
      withDestinationURL: root.appendingPathComponent("absent")
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    XCTAssertThrowsError(try store.aiChatLocalEditDocument(at: "plain/new/note.org"))
    XCTAssertThrowsError(try store.aiChatLocalEditDocument(at: "dangling/new/note.org"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
  }

  private func makeBroker(_ store: DocumentStore) -> AIChatLocalEditBroker {
    AIChatLocalEditBroker(
      documentReader: { _, path, _ in try store.read(path) },
      replacementApplier: { _, replacements in try await store.apply(replacements) }
    )
  }

  private func previewParams(
    turnID: String,
    path: String,
    expectedSHA256: String,
    replacementText: String
  ) -> String {
    let object: [String: Any] = [
      "turnId": turnID,
      "edits": [[
        "path": path,
        "expectedSha256": expectedSHA256,
        "replacementText": replacementText
      ]]
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
  }

  private func jsonObject(_ json: String?) throws -> [String: Any] {
    let data = try XCTUnwrap(json?.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func waitForCondition(
    timeout: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("Timed out waiting for asynchronous workspace state")
  }
}
