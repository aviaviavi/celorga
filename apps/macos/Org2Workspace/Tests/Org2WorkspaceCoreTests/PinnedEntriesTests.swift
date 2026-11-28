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

  @MainActor
  func testOpeningAPinnedEntryShowsItsEntryViewNotTheDocument() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-pinned-open-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes/plan.org")
    try "* Intro\nText\n* TODO Ship it\nBody\n".write(to: file, atomically: true, encoding: .utf8)
    let suiteName = "PinnedEntriesTests.Open.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.togglePinnedEntry(file: file.path, line: 3, title: "TODO Ship it")
    let entry = try XCTUnwrap(store.pinnedEntries.first)

    store.openPinnedEntry(entry)
    for _ in 0..<200 where store.selectedLocation == nil {
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(store.selectedEntrySourceMode, .entry)
    XCTAssertEqual(store.selectedLocation?.file, file.standardizedFileURL.path)
    XCTAssertEqual(store.selectedLocation?.lineForEditor, 3)
    XCTAssertEqual(store.selectedLocation?.title, "Ship it")
  }

  @MainActor
  func testPhoneDailyNoteRequestCreatesTheNoteUnlessCreationIsOff() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-daily-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "PinnedEntriesTests.Daily.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)

    let location = try await store.mobileRemoteDailyNote(date: "2026-11-26")
    XCTAssertTrue(location.path.hasPrefix("daily/2026-11-26."), location.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(location.path).path))
    let again = try await store.mobileRemoteDailyNote(date: "2026-11-26")
    XCTAssertEqual(again, location)

    store.automaticDailyNoteCreationDisabled = true
    do {
      _ = try await store.mobileRemoteDailyNote(date: "2026-11-27")
      XCTFail("Expected a missing daily note to stay missing when creation is off")
    } catch {}
    do {
      _ = try await store.mobileRemoteDailyNote(date: "not-a-date")
      XCTFail("Expected an invalid date to be refused")
    } catch {}
  }
}
