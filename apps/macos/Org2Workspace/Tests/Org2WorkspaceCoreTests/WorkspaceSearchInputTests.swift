import XCTest
@testable import Org2WorkspaceCore

private actor RecordedSearchQueries {
  private(set) var queries: [String] = []

  func record(_ query: String) {
    queries.append(query)
  }
}

private struct StubSearchFailure: Error {}

final class WorkspaceSearchInputTests: XCTestCase {
  func testHighlightFindsEveryQueryWordIgnoringCaseAndAccents() {
    let text = "Draft the Café launch plan; the launch is Friday"
    let matched = WorkspaceSearchHighlight.ranges(in: text, query: "LAUNCH cafe")
      .map { String(text[$0]) }
    XCTAssertEqual(matched, ["Café", "launch", "launch"])
  }

  func testHighlightPrefersTheLongerOverlappingWord() {
    let text = "planning notes"
    let matched = WorkspaceSearchHighlight.ranges(in: text, query: "plan planning")
      .map { String(text[$0]) }
    XCTAssertEqual(matched, ["planning"])
  }

  func testHighlightIgnoresEmptyAndQuotedQueries() {
    XCTAssertTrue(WorkspaceSearchHighlight.ranges(in: "anything", query: "   ").isEmpty)
    let text = "budget review"
    let matched = WorkspaceSearchHighlight.ranges(in: text, query: "\"budget\"")
      .map { String(text[$0]) }
    XCTAssertEqual(matched, ["budget"])
  }

  func testHighlightMarksMatchesAsStronglyEmphasized() {
    let attributed = WorkspaceSearchHighlight.attributed("alpha beta", query: "beta")
    let emphasized = attributed.runs
      .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
      .map { String(attributed[$0.range].characters) }
    XCTAssertEqual(emphasized, ["beta"])
  }

  func testArrowSelectionMovesThroughResultsAndBackToTheQuery() {
    let ids = ["a", "b", "c"]
    XCTAssertEqual(WorkspaceSearchInput.movedSelection(from: nil, by: 1, in: ids), "a")
    XCTAssertNil(WorkspaceSearchInput.movedSelection(from: nil, by: -1, in: ids))
    XCTAssertEqual(WorkspaceSearchInput.movedSelection(from: "a", by: 1, in: ids), "b")
    XCTAssertEqual(WorkspaceSearchInput.movedSelection(from: "c", by: 1, in: ids), "c")
    XCTAssertNil(WorkspaceSearchInput.movedSelection(from: "a", by: -1, in: ids))
    XCTAssertEqual(WorkspaceSearchInput.movedSelection(from: "gone", by: 1, in: ids), "a")
    XCTAssertNil(WorkspaceSearchInput.movedSelection(from: "a", by: 1, in: []))
  }

  @MainActor
  func testQuickOpenHandsItsQueryToWorkspaceSearch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-search-handoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorded = RecordedSearchQueries()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.workspaceSearchLoaderForTesting = { query, _ in
      await recorded.record(query)
      throw StubSearchFailure()
    }
    store.searchMode = .nodes
    store.selectedSurface = .files
    store.isQuickOpenPresented = true
    let focusToken = store.searchFocusToken

    store.searchWorkspace(for: "  launch plan  ")

    XCTAssertFalse(store.isQuickOpenPresented)
    XCTAssertEqual(store.searchMode, .text)
    XCTAssertEqual(store.searchQuery, "launch plan")
    XCTAssertEqual(store.selectedSurface, .search)
    XCTAssertGreaterThan(store.searchFocusToken, focusToken)
    for _ in 0..<2_000 {
      if await recorded.queries == ["launch plan"] { break }
      await Task.yield()
    }
    let queries = await recorded.queries
    XCTAssertEqual(queries, ["launch plan"])
  }
}

final class WorkspaceSearchSnippetTests: XCTestCase {
  func testHeadingLineThatRepeatsTheTitleIsHidden() {
    XCTAssertNil(WorkspaceSearchHighlight.displaySnippet("* Launch blockers", title: "Launch blockers"))
    XCTAssertNil(WorkspaceSearchHighlight.displaySnippet(
      "*** TODO [#A] Draft launch summary :agent:review:",
      title: "Draft launch summary",
      todo: "TODO"
    ))
  }

  func testHeadingLineKeepsExtraTextWithoutSyntax() {
    XCTAssertEqual(
      WorkspaceSearchHighlight.displaySnippet("** WAIT Ship beta build :ops:", title: "Release", todo: "WAIT"),
      "Ship beta build"
    )
  }

  func testBodyTextIsKeptAsWritten() {
    XCTAssertEqual(
      WorkspaceSearchHighlight.displaySnippet("  Keep the *first* release small.  ", title: "Plan"),
      "Keep the *first* release small."
    )
    XCTAssertNil(WorkspaceSearchHighlight.displaySnippet("   ", title: "Plan"))
  }
}
