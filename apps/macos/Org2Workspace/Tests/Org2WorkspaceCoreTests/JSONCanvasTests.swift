import Darwin
import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class JSONCanvasTests: XCTestCase {
  func testCanvasNavigationRequiresCanvasesApp() {
    XCTAssertFalse(WorkspaceSurface.sidebarCases(enabledApps: []).contains(.canvases))
    XCTAssertTrue(WorkspaceSurface.sidebarCases(enabledApps: ["canvases"]).contains(.canvases))
    XCTAssertFalse(WorkspaceSurface.sidebarCases.contains(.files))
  }

  func testSharedCanvasContractDecodesTypesOrderingAndGeometry() throws {
    let payload = try JSONDecoder().decode(JSONCanvasPayload.self, from: Data(Self.fixture.utf8))
    let nodes = try XCTUnwrap(payload.document.nodes)
    XCTAssertEqual(nodes.map(\.id), ["group", "note", "text"])
    XCTAssertEqual(nodes[1].org2Ref, "id:stable-heading")
    XCTAssertEqual(nodes[1].subpath, "#id:stable-heading")
    let bounds = JSONCanvasGeometry.bounds(nodes)
    XCTAssertEqual(bounds.minX, -100)
    XCTAssertEqual(bounds.minY, -60)
    XCTAssertEqual(bounds.maxX, 700)
    XCTAssertEqual(bounds.maxY, 400)
    XCTAssertEqual(JSONCanvasGeometry.anchor(nodes[1].rectangle, side: "left"), CGPoint(x: 0, y: 110))
    XCTAssertEqual(JSONCanvasGeometry.anchor(nodes[1].rectangle, side: "bottom"), CGPoint(x: 150, y: 220))
    XCTAssertEqual(payload.document.edges?.first?.fromSide, "right")
    XCTAssertEqual(payload.document.edges?.first?.toEnd, "none")
  }

  func testResolvedStableSourceRetainsExactNavigationAndRevision() throws {
    let payload = try JSONDecoder().decode(JSONCanvasPayload.self, from: Data(Self.fixture.utf8))
    let source = try XCTUnwrap(payload.resources["note"])
    XCTAssertEqual(source.location?.file, "/corpus/notes/renamed.org")
    XCTAssertEqual(source.location?.lineForEditor, 17)
    XCTAssertEqual(source.location?.idValue, "stable-heading")
    XCTAssertEqual(payload.revision, "sha256:canvas-revision")
    let draft = CanvasEditorDraft(edge: try XCTUnwrap(payload.document.edges?.first))
    XCTAssertEqual(draft.type, "edge")
    XCTAssertEqual(draft.nodeID, "connection")
    XCTAssertEqual(draft.toEnd, "none")
    XCTAssertEqual(draft.content, "Reference")
  }

  func testOptionalTopLevelArraysAndUnknownFieldsAreAcceptedByNativeProjection() throws {
    let payload = try JSONDecoder().decode(JSONCanvasPayload.self, from: Data(#"{"file":"/corpus/empty.canvas","revision":"sha256:empty","document":{"plugin":{"opaque":true}},"resources":{}}"#.utf8))
    XCTAssertNil(payload.document.nodes)
    XCTAssertNil(payload.document.edges)
    XCTAssertTrue(JSONCanvasGeometry.bounds([]).isNull)
  }

  func testTargetPickerKeepsFileIdentityDistinctFromHeadingID() throws {
    let targets = try JSONDecoder().decode(JSONCanvasTargetsPayload.self, from: Data(##"{"targets":[{"title":"Architecture","file":"notes/a.org","line":17,"id":"stable-heading","org2Ref":"id:stable-heading","subpath":"#id:stable-heading"}],"truncated":false}"##.utf8))
    XCTAssertEqual(targets.targets.first?.nodeID, "stable-heading")
    XCTAssertEqual(targets.targets.first?.id, "notes/a.org:17:stable-heading")
  }

  func testImportedGroupsRemainBehindOverlappingCardsWithoutChangingDocumentOrder() throws {
    let imported = #"""
    {"nodes":[
      {"id":"a","type":"text","text":"First","x":0,"y":0,"width":150,"height":120},
      {"id":"group-a","type":"group","x":-10,"y":-10,"width":500,"height":400},
      {"id":"b","type":"text","text":"Second","x":20,"y":20,"width":150,"height":120},
      {"id":"future","type":"future-kind","x":900,"y":0,"width":100,"height":100},
      {"id":"group-b","type":"group","x":-20,"y":-20,"width":550,"height":450}
    ]}
    """#
    let document = try JSONDecoder().decode(JSONCanvasDocument.self, from: Data(imported.utf8))
    let nodes = try XCTUnwrap(document.nodes)
    let layers = JSONCanvasLayers(nodes: nodes)
    XCTAssertEqual(layers.groups.map(\.id), ["group-a", "group-b"])
    XCTAssertEqual(layers.cards.map(\.id), ["a", "b", "future"])
    let point = CGPoint(x: 50, y: 50)
    // Both groups contain the cards, but the foreground retains the topmost card as its hit target.
    XCTAssertTrue(layers.groups.allSatisfy { $0.rectangle.contains(point) })
    XCTAssertEqual(layers.cards.reversed().first { $0.rectangle.contains(point) }?.id, "b")
    XCTAssertEqual(document.nodes?.map(\.id), ["a", "group-a", "b", "future", "group-b"])
  }

  @MainActor
  func testWorkspaceCanvasMutationsThroughCorpusAliasPersistGeometryAndRejectStaleRevision() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-native-canvas-\(UUID().uuidString)", isDirectory: true)
    let corpusDirectory = temporary.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: corpusDirectory, withIntermediateDirectories: true)
    // Match the canonical absolute paths returned by the shared runtime, including /private/var.
    let canonicalPath = try XCTUnwrap(realpath(corpusDirectory.path, nil))
    let root = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
    free(canonicalPath)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let aliasDirectory = temporary.deletingLastPathComponent().appendingPathComponent(temporary.lastPathComponent + "-alias")
    try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: root.deletingLastPathComponent())
    defer { try? FileManager.default.removeItem(at: aliasDirectory) }
    let alias = aliasDirectory.appendingPathComponent("corpus", isDirectory: true).standardizedFileURL
    let suiteName = "org2-native-canvas-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let store = WorkspaceStore(
      cli: cli,
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent(".test-state/chat.json"),
      legacyDefaultsDomains: []
    )
    store.setWorkspaceRealtimeRefreshActive(false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.aiChatTranscriptSaverForTesting = {}
    store.setCorpusRoot(alias, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.corpusRoot?.path, alias.path)

    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let source = notes.appendingPathComponent("original.org")
    let sourceText = "#+TITLE: Project\n\n* Architecture\n:PROPERTIES:\n:ID: stable-heading\n:END:\nCanonical source remains unchanged.\n"
    try sourceText.write(to: source, atomically: true, encoding: .utf8)
    XCTAssertEqual(WorkspaceStore.jsonCanvasRelativeResourcePath(file: source.path, root: alias.path), "notes/original.org")
    XCTAssertEqual(WorkspaceStore.jsonCanvasRelativeResourcePath(file: alias.appendingPathComponent("notes/original.org").path, root: alias.path), "notes/original.org")
    XCTAssertNil(WorkspaceStore.jsonCanvasRelativeResourcePath(file: root.deletingLastPathComponent().appendingPathComponent("outside.org").path, root: alias.path))
    let linkedNotes = root.appendingPathComponent("linked-notes")
    try FileManager.default.createSymbolicLink(at: linkedNotes, withDestinationURL: notes)
    // Do not resolve a selected symlink into an apparently safe resource path.
    XCTAssertEqual(WorkspaceStore.jsonCanvasRelativeResourcePath(file: linkedNotes.appendingPathComponent("original.org").path, root: alias.path), "linked-notes/original.org")
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.fixture.utf8)) as? [String: Any])
    let original = try XCTUnwrap(fixture["document"] as? [String: Any])
    let canvas = root.appendingPathComponent("work.canvas")
    try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]).write(to: canvas, options: .atomic)
    store.selectCorpusFile(CorpusFile(path: canvas.path, relativePath: "work.canvas", modifiedAt: nil, byteCount: nil), surface: .canvases)
    XCTAssertEqual(store.selectedSurface, .canvases)
    XCTAssertTrue(store.selectedFileIsCanvas)

    let before: JSONCanvasPayload = try await cli.runJSON(["canvas", "show", "--dir", alias.path, "--file", canvas.path, "--json"])
    let resolvedSource = try XCTUnwrap(before.resources["note"]?.location?.file)
    XCTAssertEqual(URL(fileURLWithPath: resolvedSource).resolvingSymlinksInPath(), source.resolvingSymlinksInPath())
    XCTAssertEqual(before.resources["note"]?.location?.lineForEditor, 3)
    let moved = try await store.mutateJSONCanvas(
      file: canvas.path, root: alias.path, revision: before.revision,
      operations: JSONSerialization.data(withJSONObject: [[
        "action": "update-node", "id": "text", "patch": ["x": -250, "y": 145],
      ]])
    )
    XCTAssertTrue(moved.applied)
    XCTAssertNotEqual(moved.revision, before.revision)
    let resized = try await store.mutateJSONCanvas(
      file: canvas.path, root: alias.path, revision: moved.revision,
      operations: JSONSerialization.data(withJSONObject: [[
        "action": "update-node", "id": "text", "patch": ["width": 420, "height": 270],
      ]])
    )
    let connection: [String: Any] = [
      "id": "native-connection", "fromNode": "note", "toNode": "text",
      "fromSide": "bottom", "toSide": "top", "toEnd": "arrow", "label": "Reviewed",
    ]
    let connected = try await store.mutateJSONCanvas(
      file: canvas.path, root: alias.path, revision: resized.revision,
      operations: JSONSerialization.data(withJSONObject: [["action": "add-edge", "edge": connection]])
    )
    let reloaded: JSONCanvasPayload = try await cli.runJSON(["canvas", "show", "--dir", alias.path, "--file", canvas.path, "--json"])
    let text = try XCTUnwrap(reloaded.document.nodes?.first { $0.id == "text" })
    XCTAssertEqual(text.rectangle, CGRect(x: -250, y: 145, width: 420, height: 270))
    XCTAssertEqual(reloaded.revision, connected.revision)
    XCTAssertEqual(reloaded.document.edges?.last?.id, "native-connection")
    XCTAssertEqual(reloaded.document.edges?.last?.fromNode, "note")
    XCTAssertEqual(reloaded.document.edges?.last?.toNode, "text")
    XCTAssertTrue(store.corpusFiles.contains {
      URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == canvas.resolvingSymlinksInPath()
    })

    // Compare the complete persisted document, including opaque fields the native models omit.
    var expected = original
    var expectedNodes = try XCTUnwrap(original["nodes"] as? [[String: Any]])
    let textIndex = try XCTUnwrap(expectedNodes.firstIndex { $0["id"] as? String == "text" })
    expectedNodes[textIndex]["x"] = -250
    expectedNodes[textIndex]["y"] = 145
    expectedNodes[textIndex]["width"] = 420
    expectedNodes[textIndex]["height"] = 270
    expected["nodes"] = expectedNodes
    expected["edges"] = try XCTUnwrap(original["edges"] as? [[String: Any]]) + [connection]
    let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: canvas)) as? [String: Any])
    XCTAssertEqual(NSDictionary(dictionary: persisted), NSDictionary(dictionary: expected))
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), sourceText)

    let linkedCanvas = root.appendingPathComponent("linked.canvas")
    try FileManager.default.createSymbolicLink(at: linkedCanvas, withDestinationURL: canvas)
    let beforeSymlinkAttempt = try Data(contentsOf: canvas)
    do {
      _ = try await store.mutateJSONCanvas(
        file: linkedCanvas.path, root: alias.path, revision: connected.revision,
        operations: JSONSerialization.data(withJSONObject: [["action": "remove-node", "id": "text"]])
      )
      XCTFail("A corpus alias must not permit Canvas symlinks below the root")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Canvas paths cannot traverse symlinks"), error.localizedDescription)
    }
    XCTAssertEqual(try Data(contentsOf: canvas), beforeSymlinkAttempt)

    var externallyChanged = persisted
    externallyChanged["otherEditor"] = ["preserve": "external change"]
    let externalBytes = try JSONSerialization.data(withJSONObject: externallyChanged, options: [.sortedKeys])
    try externalBytes.write(to: canvas, options: .atomic)
    do {
      _ = try await store.mutateJSONCanvas(
        file: canvas.path, root: alias.path, revision: connected.revision,
        operations: JSONSerialization.data(withJSONObject: [["action": "remove-node", "id": "text"]])
      )
      XCTFail("A stale Canvas revision must not replace another editor's changes")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Canvas changed since it was opened"), error.localizedDescription)
    }
    XCTAssertEqual(try Data(contentsOf: canvas), externalBytes)
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), sourceText)
  }

  private static let fixture = #"""
  {
    "file":"/corpus/work.canvas","revision":"sha256:canvas-revision",
    "document": {
      "unknown":{"preservedByRuntime":true},
      "nodes":[
        {"id":"group","type":"group","x":-100,"y":-60,"width":800,"height":460,"label":"Project"},
        {"id":"note","type":"file","x":0,"y":0,"width":300,"height":220,"file":"notes/original.org","org2Ref":"id:stable-heading","subpath":"#id:stable-heading"},
        {"id":"text","type":"text","x":350,"y":0,"width":250,"height":180,"text":"Draft","vendor":{"owner":"plugin","flags":[1,2]}}
      ],
      "edges":[{"id":"connection","fromNode":"text","toNode":"note","fromSide":"right","toSide":"left","toEnd":"none","label":"Reference","vendor":{"weight":7,"routing":{"bend":45}}}]
    },
    "resources":{"note":{"status":"ready","title":"Architecture","file":"/corpus/notes/renamed.org","line":17,"id":"stable-heading","text":"Source preview"}}
  }
  """#
}
