import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Per-turn corpus snapshots and agent-record scans reuse work for unchanged
/// files while still seeing every change.
final class CorpusScanCacheTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("corpus-scan-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testSnapshotReusesUnchangedTextAndSeesEveryChange() throws {
    let past = Date().addingTimeInterval(-3_600)
    var urls: [URL] = []
    for index in 0..<20 {
      let url = root.appendingPathComponent("notes/n\(index).org")
      try "* Note \(index)\n".write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
      urls.append(url)
    }
    let listing = WorkspaceStore.aiChatCorpusSnapshotListing(corpusRoot: root)
    let first = WorkspaceStore.aiChatCorpusSnapshot(corpusRoot: root, listing: listing, modifiedBefore: Date())
    XCTAssertEqual(first.files.count, 20)
    XCTAssertEqual(first.files["notes/n3.org"]?.text, "* Note 3\n")

    // Same size and modification date: the status-change time still differs.
    let handle = try FileHandle(forWritingTo: urls[3])
    try handle.write(contentsOf: Data("* Edit 3\n".utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: urls[3].path)
    try FileManager.default.removeItem(at: urls[4])
    let second = WorkspaceStore.aiChatCorpusSnapshot(corpusRoot: root, listing: listing, modifiedBefore: Date())
    XCTAssertEqual(second.files["notes/n3.org"]?.text, "* Edit 3\n", "An in-place edit is read again")
    XCTAssertNil(second.files["notes/n4.org"])
    XCTAssertTrue(second.unknownPaths.contains("notes/n4.org"))
    XCTAssertEqual(second.files["notes/n5.org"]?.text, "* Note 5\n")

    // A file written after the turn started has no known pre-turn text.
    let turnStart = Date()
    try "* Later\n".write(to: urls[6], atomically: true, encoding: .utf8)
    let third = WorkspaceStore.aiChatCorpusSnapshot(
      corpusRoot: root, listing: listing, modifiedBefore: turnStart.addingTimeInterval(-1)
    )
    XCTAssertTrue(third.unknownPaths.contains("notes/n6.org"))
    XCTAssertNil(third.files["notes/n6.org"])
  }

  func testFileVersionCacheStaysBounded() throws {
    let cache = FileVersionCache<Int>(maximumEntries: 3, maximumCost: 100)
    let url = root.appendingPathComponent("notes/a.org")
    try "a".write(to: url, atomically: true, encoding: .utf8)
    let version = try XCTUnwrap(AIChatTranscriptStore.regularFileVersion(at: url))
    for index in 0..<10 { cache.store(index, path: "p\(index)", version: version, cost: 10) }
    XCTAssertLessThanOrEqual(cache.count, 3)
    cache.store(1, path: "big", version: version, cost: 1_000)
    XCTAssertNil(cache.value(path: "big", version: version), "An entry larger than the bound is not kept")
  }

  func testThreadRecordsListTheSameNewestRecordsWhileReadingOnlyThem() throws {
    let agents = root.appendingPathComponent("agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let base = Date().addingTimeInterval(-100_000)
    let count = WorkspaceStore.aiChatThreadRecordLimit + 60
    for index in 0..<count {
      let url = agents.appendingPathComponent("r\(index).org")
      try ":PROPERTIES:\n:ID: id-\(index)\n:END:\n#+TITLE: Record \(index)\n".write(to: url, atomically: true, encoding: .utf8)
      // Two records share the boundary date so the title tie-break matters.
      let offset = index == count - 1 ? Double(60) : Double(index)
      try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(offset)], ofItemAtPath: url.path)
    }
    let records = try WorkspaceStore.scanAIChatThreadRecords(corpusRoot: root)
    XCTAssertEqual(records.count, WorkspaceStore.aiChatThreadRecordLimit)
    XCTAssertEqual(records.first?.title, "Record \(count - 2)")
    // The newest 250 by date, ties broken by title, exactly as a full read would list them.
    var dated: [(date: Double, title: String)] = []
    for index in 0..<count {
      let date: Double = index == count - 1 ? 60 : Double(index)
      dated.append((date, "Record \(index)"))
    }
    dated.sort { left, right in
      if left.date != right.date { return left.date > right.date }
      return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
    }
    let expected: [String] = dated.prefix(WorkspaceStore.aiChatThreadRecordLimit).map { $0.title }
    XCTAssertEqual(records.map(\.title), expected)
    XCTAssertTrue(records.contains { $0.title == "Record \(count - 1)" }, "A record tied at the boundary is still considered")

    let renamed = agents.appendingPathComponent("r\(count - 2).org")
    try ":PROPERTIES:\n:ID: id-new\n:END:\n#+TITLE: Renamed\n".write(to: renamed, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(Double(count - 2))], ofItemAtPath: renamed.path)
    XCTAssertEqual(try WorkspaceStore.scanAIChatThreadRecords(corpusRoot: root).first?.title, "Renamed",
      "A changed record is parsed again")
  }
}
