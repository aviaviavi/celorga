import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor RecordedSearchArguments {
  private(set) var calls: [[String]] = []
  func record(_ arguments: [String]) { calls.append(arguments) }
}

final class WorkspaceSearchFilterTests: XCTestCase {
  @MainActor
  func testFilterNarrowsTheMergedListAtOnceAndAsksForOneKindOfMatch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-search-filter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes.org").path
    let recorded = RecordedSearchArguments()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    let heading = result(file: file, line: 3, heading: "Harbor launch", headingLine: 3, todo: "TODO", snippet: "* TODO Harbor launch")
    let body = result(file: file, line: 8, heading: "Notes", headingLine: 6, todo: nil, snippet: "Harbor mention in a note")
    store.workspaceSearchLoaderForTesting = { query, arguments in
      await recorded.record(arguments)
      let results = arguments.contains("--match") ? [heading] : [heading, body]
      return SearchPayload(schema: "org2:search:v1", query: query, mode: "line", sort: "best", results: results, corpora: nil, issues: nil)
    }

    store.searchQuery = "harbor"
    await store.runSearch()
    XCTAssertEqual(store.workspaceTextSearchItems.count, 2)
    let firstCall = await recorded.calls.first
    XCTAssertEqual(firstCall?.contains("--match"), false)

    // Switching filters narrows the current list before the next search runs.
    store.searchFilter = .text
    XCTAssertEqual(store.workspaceTextSearchItems.map(\.id), ["entry:\(body.id)"])
    store.searchFilter = .chats
    XCTAssertTrue(store.workspaceTextSearchItems.isEmpty)

    // A heading search asks the worker for heading matches only.
    store.searchFilter = .headings
    await store.runSearch()
    let lastCall = await recorded.calls.last ?? []
    XCTAssertEqual(lastCall.firstIndex(of: "--match").map { lastCall[$0 + 1] }, "heading")
    XCTAssertEqual(store.workspaceTextSearchItems.map(\.id), ["todo:\(heading.id)"])

    // Chat-only search does not run the corpus search at all.
    let callCount = await recorded.calls.count
    store.searchFilter = .chats
    await store.runSearch()
    let afterChats = await recorded.calls.count
    XCTAssertEqual(afterChats, callCount)
    XCTAssertTrue(store.searchResults.isEmpty)
  }

  func testFilterKinds() {
    XCTAssertEqual(WorkspaceSearchFilter.headings.corpusMatchKind, "heading")
    XCTAssertEqual(WorkspaceSearchFilter.todos.corpusMatchKind, "todo")
    XCTAssertEqual(WorkspaceSearchFilter.text.corpusMatchKind, "text")
    XCTAssertNil(WorkspaceSearchFilter.chats.corpusMatchKind)
    XCTAssertTrue(WorkspaceSearchFilter.all.searchesChats && WorkspaceSearchFilter.all.searchesCorpusText)
    XCTAssertFalse(WorkspaceSearchFilter.chats.searchesCorpusText)
    XCTAssertFalse(WorkspaceSearchFilter.headings.searchesChats)
    XCTAssertEqual(WorkspaceSearchFilter.all.perSourceLimit, 25)
    XCTAssertEqual(WorkspaceSearchFilter.files.perSourceLimit, 100)
  }

  /// The warm worker applies the heading filter and shortens long lines.
  func testWorkerFiltersHeadingsAndShortensLongLines() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    try XCTSkipUnless(cli.hasSearchService, "dist/search-service.js is not built")
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-search-filter-worker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let longLine = String(repeating: "x", count: 3_000) + " harbor " + String(repeating: "y", count: 3_000)
    try """
    * TODO Harbor plan
    Harbor appears in the body.
    \(longLine)
    """.write(to: root.appendingPathComponent("notes.org"), atomically: true, encoding: .utf8)
    struct IndexBuild: Decodable { let path: String }
    let build: IndexBuild = try await cli.runJSON(["index", "--dir", root.path, "--recursive", "--format", "json"])
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: build.path).deletingLastPathComponent()) }

    let headings = try await cli.searchIndexedCorpus("harbor", corpusRoot: root, limit: 50, context: 1, matchKind: "heading")
    XCTAssertEqual(headings.results.map(\.line), [1])
    let all = try await cli.searchIndexedCorpus("harbor", corpusRoot: root, limit: 50, context: 1, maxLineLength: 200)
    XCTAssertEqual(all.results.count, 3)
    let long = try XCTUnwrap(all.results.first { $0.line == 3 })
    XCTAssertLessThanOrEqual(long.snippet.count, 202)
    XCTAssertTrue(long.snippet.contains("harbor"))
  }

  private func result(file: String, line: Int, heading: String?, headingLine: Int?, todo: String?, snippet: String) -> SearchResult {
    SearchResult(
      file: file,
      line: line,
      lineEnd: nil,
      heading: heading,
      headingLine: headingLine,
      headingLevel: heading == nil ? nil : 1,
      headingAncestry: nil,
      idValue: nil,
      todo: todo,
      tags: [],
      snippet: snippet,
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
  }
}
