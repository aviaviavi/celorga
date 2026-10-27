import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class Org2SearchServiceTests: XCTestCase {
  private struct IndexBuild: Decodable { let path: String }

  func testWarmSearchServiceMatchesOneShotSearchAndAnswersQuickly() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    try XCTSkipUnless(cli.hasSearchService, "dist/search-service.js is not built")
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-search-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    * TODO Harbor plan :work:
    Harbor appears in the body.

    * Lighthouse notes
    Unrelated text.
    """.write(to: root.appendingPathComponent("notes.org"), atomically: true, encoding: .utf8)

    let build: IndexBuild = try await cli.runJSON([
      "index", "--dir", root.path, "--recursive", "--format", "json"
    ])
    defer {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: build.path).deletingLastPathComponent())
    }

    await cli.prewarmSearchService(corpusRoot: root)
    let started = Date()
    let served = try await cli.searchIndexedCorpus("harbor", corpusRoot: root, limit: 200, context: 1)
    let elapsed = Date().timeIntervalSince(started)
    let oneShot: SearchPayload = try await cli.runJSON([
      "search", "harbor", "--dir", root.path, "--recursive", "--limit", "200", "--context", "1",
      "--index", "current", "--sort", "best", "--format", "json"
    ])

    XCTAssertEqual(served.results.map(\.line), [1, 2])
    XCTAssertEqual(served.results, oneShot.results)
    XCTAssertLessThan(elapsed, 1.0, "A warm search took \(elapsed)s; it likely regressed to a process launch per query")
  }
}
