import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class PinnedEntriesTests: XCTestCase {
  func testHeadingTitleIgnoresKeywordPriorityAndTags() {
    XCTAssertEqual(PinnedEntryHeading.title(ofHeadingLine: "** TODO [#A] Ship the release :work:urgent:"), "Ship the release")
    XCTAssertEqual(PinnedEntryHeading.title(ofHeadingLine: "* Plain heading"), "Plain heading")
    XCTAssertNil(PinnedEntryHeading.title(ofHeadingLine: "*bold* text"))
    XCTAssertNil(PinnedEntryHeading.title(ofHeadingLine: "- list item"))
  }

  func testNodeIDComesFromTheHeadingsOwnDrawer() {
    let entry = "* Plan\n:PROPERTIES:\n:ID: 1234-abcd\n:END:\nBody"
    XCTAssertEqual(PinnedEntryHeading.nodeID(inEntry: entry), "1234-abcd")
    let child = "* Plan\nBody\n** Child\n:PROPERTIES:\n:ID: child-id\n:END:"
    XCTAssertNil(PinnedEntryHeading.nodeID(inEntry: child))
  }

  func testPinnedEntryIsFoundAfterItMoves() {
    let entry = PinnedEntry(relativePath: "notes/a.org", title: "Ship the release", line: 2)
    XCTAssertEqual(PinnedEntryHeading.line(for: entry, in: "* Intro\n* TODO Ship the release\n"), 2)
    XCTAssertEqual(PinnedEntryHeading.line(for: entry, in: "* Intro\nNew line\n\n* DONE Ship the release :x:\n"), 4)
    XCTAssertNil(PinnedEntryHeading.line(for: entry, in: "* Something else\n"))
  }

  @MainActor
  func testPinningAnEntryPersistsPerCorpusAndFollowsARename() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-pinned-entries-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes/plan.org")
    try "* Intro\n* TODO Ship it\n".write(to: file, atomically: true, encoding: .utf8)
    let suiteName = "PinnedEntriesTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)

    store.togglePinnedEntry(file: file.path, line: 2, title: "TODO Ship it", entryText: "* TODO Ship it\n:PROPERTIES:\n:ID: ship-id\n:END:")
    XCTAssertEqual(store.pinnedEntries, [
      PinnedEntry(relativePath: "notes/plan.org", title: "Ship it", line: 2, nodeID: "ship-id")
    ])
    XCTAssertTrue(store.isEntryPinned(file: file.path, line: 2, title: "Ship it"))

    store.renameFileReferences(fromRelativePath: "notes/plan.org", toRelativePath: "notes/plans.org")
    XCTAssertEqual(store.pinnedEntries.first?.relativePath, "notes/plans.org")

    let reopened = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat2.json"),
      legacyDefaultsDomains: []
    )
    reopened.setCorpusRoot(root, persistsDefault: false)
    XCTAssertEqual(reopened.pinnedEntries.map(\.title), ["Ship it"])

    reopened.togglePinnedEntry(
      file: root.appendingPathComponent("notes/plans.org").path,
      line: 2,
      title: "Ship it"
    )
    XCTAssertTrue(reopened.pinnedEntries.isEmpty)
  }
}
