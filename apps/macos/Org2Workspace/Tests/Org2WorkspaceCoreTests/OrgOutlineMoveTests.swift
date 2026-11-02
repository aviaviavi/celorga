import XCTest
@testable import Org2WorkspaceCore

final class OrgOutlineMoveTests: XCTestCase {
  static let sample = """
  #+title: Drag test

  * TODO Plan the launch
  Some body text for the launch.
  ** Write the announcement
  - Draft outline
    - Intro
    - Features
  - Get review
  - Publish
  ** Record the demo
  1. Script
  2. Record
  3. Edit
  * Groceries
  - [ ] Milk
  - [ ] Eggs
  - [X] Bread
  * Reading list
  ** Book one
  ** Book two
  *** Notes on two
  * Archive

  """

  private func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  func testMovesAHeadingSubtreeAboveAnEarlierSibling() throws {
    let output = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(kind: .heading, startLine: 15, endLine: 18, targetLine: 3, level: 1, headingLines: [15]),
      to: Self.sample
    )
    XCTAssertEqual(Array(lines(output)[2...6]), [
      "* Groceries", "- [ ] Milk", "- [ ] Eggs", "- [X] Bread", "* TODO Plan the launch",
    ])
    XCTAssertEqual(lines(output).count, lines(Self.sample).count)
    XCTAssertEqual(lines(output)[18], "* Reading list")
  }

  func testIndentsAHeadingInPlace() throws {
    let output = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(kind: .heading, startLine: 23, endLine: 23, targetLine: 23, level: 2, headingLines: [23]),
      to: Self.sample
    )
    XCTAssertEqual(lines(output)[22], "** Archive")
    XCTAssertTrue(output.hasSuffix("** Archive\n"))
  }

  func testMovesASubtreeToTheEndAndShiftsEveryHeadingInIt() throws {
    let output = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(kind: .heading, startLine: 21, endLine: 22, targetLine: 24, level: 1, headingLines: [21, 22]),
      to: Self.sample
    )
    XCTAssertEqual(Array(lines(output)[19...23]), [
      "** Book one", "* Archive", "* Book two", "** Notes on two", "",
    ])
  }

  func testHeadingLevelShiftLeavesSourceBlockLinesAlone() throws {
    let text = "* A\n** B\n#+begin_src org\n* not a heading\n#+end_src\n*** C\n* D"
    let output = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(kind: .heading, startLine: 2, endLine: 6, targetLine: 8, level: 1, headingLines: [2, 6]),
      to: text
    )
    XCTAssertEqual(output, "* A\n* D\n* B\n#+begin_src org\n* not a heading\n#+end_src\n** C")
  }

  func testRejectsATargetInsideTheMovedSubtreeAndANoOp() {
    XCTAssertThrowsError(try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(kind: .heading, startLine: 19, endLine: 22, targetLine: 21, level: 2, headingLines: [19]),
      to: Self.sample
    )) { XCTAssertEqual($0 as? OrgOutlineMoveError, .targetInsideMovedEntry) }
    XCTAssertThrowsError(try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(kind: .heading, startLine: 19, endLine: 22, targetLine: 23, level: 1, headingLines: [19]),
      to: Self.sample
    )) { XCTAssertEqual($0 as? OrgOutlineMoveError, .unchanged) }
    XCTAssertThrowsError(try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(kind: .heading, startLine: 4, endLine: 4, targetLine: 3, level: 1, headingLines: [4]),
      to: Self.sample
    )) { XCTAssertEqual($0 as? OrgOutlineMoveError, .notAHeading(line: 4)) }
  }

  func testReordersListItemsWithTheirNestedItems() throws {
    let toTop = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(
        kind: .listItem, startLine: 10, endLine: 10, targetLine: 6,
        referenceLine: 6, relation: .sibling, listStartLine: 6, listEndLine: 10
      ),
      to: Self.sample
    )
    XCTAssertEqual(Array(lines(toTop)[5...9]), [
      "- Publish", "- Draft outline", "  - Intro", "  - Features", "- Get review",
    ])

    let toBottom = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(
        kind: .listItem, startLine: 6, endLine: 8, targetLine: 11,
        referenceLine: 10, relation: .sibling, listStartLine: 6, listEndLine: 10
      ),
      to: Self.sample
    )
    XCTAssertEqual(Array(lines(toBottom)[5...10]), [
      "- Get review", "- Publish", "- Draft outline", "  - Intro", "  - Features", "** Record the demo",
    ])
  }

  func testIndentsAndOutdentsListItems() throws {
    let indented = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(
        kind: .listItem, startLine: 9, endLine: 9, targetLine: 9,
        referenceLine: 8, relation: .sibling, listStartLine: 6, listEndLine: 10
      ),
      to: Self.sample
    )
    XCTAssertEqual(lines(indented)[8], "  - Get review")

    let child = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(
        kind: .listItem, startLine: 10, endLine: 10, targetLine: 10,
        referenceLine: 9, relation: .child, listStartLine: 6, listEndLine: 10
      ),
      to: Self.sample
    )
    XCTAssertEqual(lines(child)[9], "  - Publish")

    let outdented = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(
        kind: .listItem, startLine: 8, endLine: 8, targetLine: 9,
        referenceLine: 6, relation: .sibling, listStartLine: 6, listEndLine: 10
      ),
      to: Self.sample
    )
    XCTAssertEqual(Array(lines(outdented)[5...8]), ["- Draft outline", "  - Intro", "- Features", "- Get review"])
  }

  func testRenumbersOrderedListsAfterAMove() throws {
    let output = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(
        kind: .listItem, startLine: 14, endLine: 14, targetLine: 12,
        referenceLine: 12, relation: .sibling, listStartLine: 12, listEndLine: 14
      ),
      to: Self.sample
    )
    XCTAssertEqual(Array(lines(output)[11...13]), ["1. Edit", "2. Script", "3. Record"])
  }

  func testNestedItemsAdoptTheirNewListsBulletAndContinuationLinesFollow() throws {
    let text = "1. First\n   - a\n   - b\n2. Second\n   continued\n3. Third"
    let output = try OrgOutlineMove.apply(
      OrgOutlineMoveRequest(
        kind: .listItem, startLine: 4, endLine: 5, targetLine: 4,
        referenceLine: 3, relation: .sibling, listStartLine: 1, listEndLine: 6
      ),
      to: text
    )
    XCTAssertEqual(output, "1. First\n   - a\n   - b\n   - Second\n      continued\n2. Third")
  }

  func testDecodesThePagePayloadAndOffsetsLines() throws {
    let request = try XCTUnwrap(OrgOutlineMoveRequest([
      "kind": "listItem", "startLine": NSNumber(value: 41), "endLine": NSNumber(value: 42),
      "targetLine": NSNumber(value: 40), "referenceLine": NSNumber(value: 40), "relation": "child",
      "listStartLine": NSNumber(value: 40), "listEndLine": NSNumber(value: 44),
    ] as [String: Any]))
    XCTAssertEqual(request.kind, .listItem)
    XCTAssertEqual(request.relation, .child)
    let relative = request.offsettingLines(by: -39)
    XCTAssertEqual(relative.startLine, 2)
    XCTAssertEqual(relative.referenceLine, 1)
    XCTAssertEqual(relative.listEndLine, 5)
    XCTAssertNil(OrgOutlineMoveRequest(["kind": "paragraph"]))
  }
}

@MainActor
final class OrgOutlineMoveStoreTests: XCTestCase {
  func testRenderedMoveRewritesTheFileRejectsAStalePageAndUndoes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-outline-move-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("plans.org")
    let original = "* Groceries\n- Milk\n- Eggs\n* Reading list\n** Book one\n"
    try original.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {"todo": "", "headline": "Groceries", "kind": "SCHEDULED", "file": "\(note.path)",
     "line": 1, "body": "", "level": 1, "tags": [], "properties": {}}
    """
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.entryHTMLRendererForTesting = { _, _, _, _ in "<html><body>page</body></html>" }
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    // An entry view of the first heading cannot move headings out of it.
    await store.loadEntrySource(for: .agenda(item))
    XCTAssertEqual(store.selectedEntrySource?.isSubtree, true)
    let insideEntry = await store.moveRenderedOutlineEntry(OrgOutlineMoveRequest(
      kind: .listItem, startLine: 3, endLine: 3, targetLine: 2,
      referenceLine: 2, relation: .sibling, listStartLine: 2, listEndLine: 3
    ))
    XCTAssertTrue(insideEntry)
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "* Groceries\n- Eggs\n- Milk\n* Reading list\n** Book one\n")
    try original.write(to: note, atomically: true, encoding: .utf8)

    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    XCTAssertEqual(store.selectedEntrySource?.isSubtree, false)

    let moved = await store.moveRenderedOutlineEntry(OrgOutlineMoveRequest(
      kind: .heading, startLine: 4, endLine: 5, targetLine: 1, level: 1, headingLines: [4, 5]
    ))
    XCTAssertTrue(moved)
    XCTAssertEqual(
      try String(contentsOf: note, encoding: .utf8),
      "* Reading list\n** Book one\n* Groceries\n- Milk\n- Eggs\n"
    )
    XCTAssertEqual(store.statusText, "Moved heading")
    XCTAssertTrue(store.selectedEntrySource?.text.hasPrefix("* Reading list") == true)

    store.performUndoCommand()
    let deadline = Date().addingTimeInterval(5)
    while (try? String(contentsOf: note, encoding: .utf8)) != original, Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), original)
    await store.loadEntrySource(for: .agenda(item))

    // A page rendered before an outside edit must not overwrite it.
    try "* Groceries\n- Milk\n- Oat milk\n* Reading list\n** Book one\n"
      .write(to: note, atomically: true, encoding: .utf8)
    let stale = await store.moveRenderedOutlineEntry(OrgOutlineMoveRequest(
      kind: .listItem, startLine: 3, endLine: 3, targetLine: 2,
      referenceLine: 2, relation: .sibling, listStartLine: 2, listEndLine: 3
    ))
    XCTAssertFalse(stale)
    XCTAssertEqual(
      try String(contentsOf: note, encoding: .utf8),
      "* Groceries\n- Milk\n- Oat milk\n* Reading list\n** Book one\n"
    )
  }
}
