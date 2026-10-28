import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class MacFileSearchTests: XCTestCase {
  func testDecodesWorkerPayload() throws {
    let json = """
    {"schema":"org2:file-search-result:v1","query":"report",
     "index":{"path":"/tmp/index-v1.json","builtAt":"2026-10-20T08:00:00.123Z","building":false,"entries":12,"roots":["/Users/x"],"stale":false},
     "results":[{"path":"/Users/x/Downloads/Report (2).pdf","name":"Report (2).pdf","directory":"/Users/x/Downloads",
       "kind":"pdf","extension":"pdf","isDirectory":false,"size":2048,"modifiedAt":"2026-10-19T10:00:00.000Z","score":41.5,
       "copyCount":1,"copies":[{"path":"/Users/x/Downloads/Report.pdf","directory":"/Users/x/Downloads","size":2048,
       "modifiedAt":"2026-09-01T10:00:00.000Z","identical":true}]}],
     "elapsedMs":3}
    """
    let payload = try JSONDecoder().decode(MacFileSearchPayload.self, from: Data(json.utf8))
    XCTAssertEqual(payload.index.entries, 12)
    XCTAssertNotNil(payload.index.builtAt)
    let result = try XCTUnwrap(payload.results.first)
    XCTAssertEqual(result.name, "Report (2).pdf")
    XCTAssertEqual(result.kind, "pdf")
    XCTAssertEqual(result.copyCount, 1)
    XCTAssertEqual(result.copies.first?.identical, true)
    XCTAssertEqual(result.modifiedAt, MacFileSearchDates.parse("2026-10-19T10:00:00Z"))
    XCTAssertEqual(MacFileSearchDisplay.copiesLabel(1), "+1 older copy")
    XCTAssertEqual(MacFileSearchDisplay.copiesLabel(3), "+3 older copies")
    XCTAssertEqual(MacFileSearchDisplay.orgLink("/a/b.pdf", name: "b [1].pdf"), "[[file:/a/b.pdf][b [1).pdf]]")
  }

  func testSearchModeOffersThisMac() {
    XCTAssertEqual(WorkspaceSearchMode.allCases, [.text, .nodes, .files])
    XCTAssertEqual(WorkspaceSearchMode.files.title, "This Mac")
  }

  /// The warm worker indexes the configured folders, groups repeat
  /// downloads, and answers from memory.
  func testWorkerFindsFilesAndGroupsRepeatDownloads() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    try XCTSkipUnless(cli.hasSearchService, "dist/search-service.js is not built")
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("celorga-mac-file-search-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    let filesHome = root.appendingPathComponent("files-home", isDirectory: true)
    let searched = root.appendingPathComponent("searched", isDirectory: true)
    try fileManager.createDirectory(at: searched.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: filesHome, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    try #"{"roots":["\#(searched.path)"],"exclude":[],"includeHidden":false}"#
      .write(to: filesHome.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    for (name, age) in [("Harbor Plan.pdf", 30.0), ("Harbor Plan (1).pdf", 10.0), ("Harbor Plan (2).pdf", 1.0)] {
      let file = searched.appendingPathComponent("Downloads").appendingPathComponent(name)
      try Data("plan".utf8).write(to: file)
      try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-age * 86_400)], ofItemAtPath: file.path)
    }

    // A private pool, so its worker starts with this test's file search home.
    setenv("ORG2_FILES_HOME", filesHome.path, 1)
    defer { unsetenv("ORG2_FILES_HOME") }
    let pool = Org2SearchServicePool()
    var payload = try await pool.searchFiles(
      MacFileSearchServiceRequest(query: "harbor plan", limit: 10),
      repoRoot: cli.repoRoot,
      nodePath: cli.runtimeNodePath,
      timeout: 20
    )
    let deadline = Date().addingTimeInterval(15)
    while payload.index.building, Date() < deadline {
      try await Task.sleep(nanoseconds: 100_000_000)
      payload = try await pool.searchFiles(
        MacFileSearchServiceRequest(query: "harbor plan", limit: 10),
        repoRoot: cli.repoRoot,
        nodePath: cli.runtimeNodePath,
        timeout: 20
      )
    }
    XCTAssertFalse(payload.index.building)
    XCTAssertEqual(payload.results.map(\.name), ["Harbor Plan (2).pdf"])
    XCTAssertEqual(payload.results.first?.copyCount, 2)
    XCTAssertEqual(payload.results.first?.copies.map(\.identical), [true, true])

    let started = Date()
    _ = try await pool.searchFiles(
      MacFileSearchServiceRequest(query: "harbor", limit: 10),
      repoRoot: cli.repoRoot,
      nodePath: cli.runtimeNodePath,
      timeout: 20
    )
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "a warm file search should answer from memory")
  }
}
