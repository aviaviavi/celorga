import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceSearchSpeedTests: XCTestCase {
  func testLowercasedSearchTermsMatchEveryTermByteForByte() {
    let terms = LowercasedSearchTerms(query: "  Harbor   ÉCLAIR ")
    XCTAssertEqual(terms.terms, ["harbor", "éclair"])
    XCTAssertTrue(terms.allOccur(in: "the harbor café sells an éclair"))
    XCTAssertFalse(terms.allOccur(in: "the harbor café"))
    XCTAssertFalse(terms.allOccur(in: ""))
    XCTAssertTrue(LowercasedSearchTerms(query: "   ").allOccur(in: "anything"))
    XCTAssertTrue(LowercasedSearchTerms(query: "a").allOccur(in: "a"))
    XCTAssertFalse(LowercasedSearchTerms(query: "abc").allOccur(in: "ab"))
  }

  /// Workspace search matches runs against the run list's cached filter
  /// text instead of rebuilding every run's text on every query, which took
  /// seconds over a large run archive.
  func testAgentWorkSearchUsesTheRunListsCachedFilterText() throws {
    let runs = try JSONDecoder().decode(AgentRunListPayload.self, from: Data(#"""
    {
      "schema": "org2:run-list:v1",
      "runs": [
        {"id": "run-a", "goal": "Draft the harbor brief", "acceptanceCriteria": [], "status": "running",
         "riskClass": "internal", "capabilities": [], "context": [], "plan": [], "artifacts": [],
         "approvals": [], "validations": [], "comments": [], "events": [],
         "createdAt": "2026-08-08T15:00:00.000Z", "updatedAt": "2026-08-08T16:00:00.000Z"},
        {"id": "run-b", "goal": "Plan the lighthouse visit", "acceptanceCriteria": [], "status": "running",
         "riskClass": "internal", "capabilities": [], "context": [], "plan": [], "artifacts": [],
         "approvals": [], "validations": [], "comments": [],
         "events": [{"id": "event-1", "type": "note", "actor": "agent", "detail": "Checked the Harbor tide table", "at": "2026-08-08T15:30:00.000Z"}],
         "createdAt": "2026-08-08T15:00:00.000Z", "updatedAt": "2026-08-08T16:00:00.000Z"}
      ]
    }
    """#.utf8)).runs

    func search(_ query: String, cached: [AgentRunItem.ID: String] = [:], limit: Int = 25) -> [String] {
      WorkspaceStore.searchAgentWorkForWorkspace(
        runs: runs, approvals: [], workflows: [], goals: [], profiles: [],
        query: query, limitPerCategory: limit, runFilterTextByID: cached
      ).map(\.recordID)
    }

    // Without a cache, each run's filter text is built as before.
    XCTAssertEqual(search("HARBOR"), ["run-a", "run-b"])
    XCTAssertEqual(search("harbor tide"), ["run-b"])
    XCTAssertEqual(search("harbor", limit: 1), ["run-a"])

    // The run list's cached text is what is matched when present.
    let cached = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0.runFilterText) })
    XCTAssertEqual(search("harbor", cached: cached), ["run-a", "run-b"])
    XCTAssertEqual(search("ferry", cached: ["run-b": "ferry schedule"]), ["run-b"])
    XCTAssertTrue(run(runs, "run-b").matchesRunFilter("tide HARBOR"))
    XCTAssertFalse(run(runs, "run-b").matchesRunFilter("tide ferry"))
  }

  /// The worker keeps the active corpus's index current itself, so a change
  /// does not mean rebuilding the whole index in a new process.
  func testSearchServiceRefreshBuildsTheIndexAndPicksUpChanges() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    try XCTSkipUnless(cli.hasSearchService, "dist/search-service.js is not built")
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-search-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "* Harbor plan\nHarbor body.\n".write(to: root.appendingPathComponent("notes.org"), atomically: true, encoding: .utf8)

    let built = try await WorkspaceStore.refreshCorpusSearchIndex(cli: cli, corpusRoot: root)
    XCTAssertEqual(built.fileCount, 1)
    XCTAssertEqual(built.lineCount, 3)
    let first = try await cli.searchIndexedCorpus("harbor", corpusRoot: root, limit: 50, context: 0)
    XCTAssertEqual(first.results.map(\.line), [1, 2])

    try "* Lighthouse\n".write(to: root.appendingPathComponent("later.org"), atomically: true, encoding: .utf8)
    let refreshed = try await WorkspaceStore.refreshCorpusSearchIndex(cli: cli, corpusRoot: root, changedPaths: [root.appendingPathComponent("later.org").path])
    XCTAssertEqual(refreshed.fileCount, 2)
    let later = try await cli.searchIndexedCorpus("lighthouse", corpusRoot: root, limit: 50, context: 0)
    XCTAssertEqual(later.results.count, 1)
  }

  private func run(_ runs: [AgentRunItem], _ id: String) -> AgentRunItem {
    runs.first { $0.id == id }!
  }
}
