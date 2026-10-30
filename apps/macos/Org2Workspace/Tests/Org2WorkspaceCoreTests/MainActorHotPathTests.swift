import Foundation
import Combine
import Observation
import XCTest
@testable import Org2WorkspaceCore

private final class HotPathObservationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false
  var value: Bool {
    get { lock.lock(); defer { lock.unlock() }; return storage }
    set { lock.lock(); storage = newValue; lock.unlock() }
  }
}

/// Regression coverage for work that runs on the main actor many times per
/// second: per-keystroke, per-render, or per-streamed-chunk paths.
@MainActor
final class MainActorHotPathTests: XCTestCase {
  // MARK: - Message excerpts

  /// Reference implementation: the longest prefix of whole characters whose
  /// UTF-8 size fits the limit.
  private func referenceExcerpt(_ text: String, limit: Int) -> (String, Bool) {
    var end = text.startIndex
    var bytes = 0
    for character in text {
      let size = String(character).utf8.count
      if bytes + size > limit { return (String(text[..<end]), true) }
      bytes += size
      end = text.index(after: end)
    }
    return (text, false)
  }

  func testMessageExcerptMatchesCharacterWalkAtEveryLimit() {
    let samples = [
      "",
      "plain ascii text",
      "café naïve résumé",
      "e\u{301}e\u{301}e\u{301} combining marks",
      "👩‍👩‍👧‍👦 family 🇺🇸🇨🇦 flags 👍🏽 skin",
      "日本語のテキストと English mixed",
      "line one\r\nline two\r\n",
    ]
    for sample in samples {
      for limit in 0...(sample.utf8.count + 2) {
        let excerpt = AIChatMessageBodyExcerpt(sample, utf8ByteLimit: limit)
        let expected = referenceExcerpt(sample, limit: limit)
        XCTAssertEqual(excerpt.text, expected.0, "\(sample.debugDescription) at \(limit)")
        XCTAssertEqual(excerpt.isTruncated, expected.1, "\(sample.debugDescription) at \(limit)")
      }
    }
    let unlimited = AIChatMessageBodyExcerpt("anything", utf8ByteLimit: nil)
    XCTAssertEqual(unlimited.text, "anything")
    XCTAssertFalse(unlimited.isTruncated)
  }

  func testMessageExcerptOfAFittingMessageDoesNotWalkCharacters() {
    // 32 KB of multi-byte text that fits: the old character walk allocated a
    // String per character on every transcript render.
    let message = String(repeating: "é", count: 16_000)
    let started = ContinuousClock.now
    for _ in 0..<200 {
      let excerpt = AIChatMessageBodyExcerpt(
        message,
        utf8ByteLimit: AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit
      )
      XCTAssertFalse(excerpt.isTruncated)
    }
    XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(250))
  }

  // MARK: - Byte search

  func testContainsUTF8BytesMatchesLiteralSearch() {
    let html = "<p>before</p><div data-org2-live-embed=\"true\">x</div>"
    XCTAssertTrue(html.containsUTF8Bytes("data-org2-live-embed=\"true\""))
    XCTAssertFalse(html.containsUTF8Bytes("data-org2-live-embed=\"false\""))
    XCTAssertTrue(html.containsUTF8Bytes(""))
    XCTAssertFalse("".containsUTF8Bytes("x"))
    XCTAssertTrue("naïve café".containsUTF8Bytes("café"))
    let bridged = NSString(string: "bridged <img src=\"a.png\">") as String
    XCTAssertTrue(bridged.containsUTF8Bytes("<img"))
    XCTAssertTrue(html[html.startIndex...].containsUTF8Bytes("before"))
  }

  func testLiveEmbedDetectionUsesTheMarker() {
    XCTAssertTrue(LiveEmbedPresentation.containsEmbeds("<div data-org2-live-embed=\"true\"></div>"))
    XCTAssertFalse(LiveEmbedPresentation.containsEmbeds("<div></div>"))
    XCTAssertFalse(LiveEmbedPresentation.containsEmbeds(nil))
  }

  // MARK: - Wiki-link completion

  func testWikiLinkCandidatesKeepRankingAndLimit() {
    let nodes = [
      OrgRoamNodeReference(idValue: "a", title: "Project Atlas", file: "/c/atlas.org", line: 1, isPageNode: true),
      OrgRoamNodeReference(idValue: "b", title: "Atlas", aliases: ["The Map"], file: "/c/map.org", line: 1, isPageNode: true),
      OrgRoamNodeReference(idValue: "c", title: "Atlas review notes", file: "/c/review.org", line: 4),
      OrgRoamNodeReference(idValue: "d", title: "Unrelated", aliases: ["atlas-adjacent"], file: "/c/other.org", line: 9),
      OrgRoamNodeReference(idValue: "e", title: "Zebra", file: "/c/zebra.org", line: 1),
    ]
    let resolver = OrgRoamLinkResolver(nodes: nodes)
    XCTAssertEqual(
      resolver.searchCandidates(matching: "  ATLAS ", limit: 6).map(\.idValue),
      ["b", "c", "d", "a"],
      "exact, then prefix, then substring; ties by page node and title"
    )
    XCTAssertEqual(resolver.searchCandidates(matching: "atlas", limit: 2).map(\.idValue), ["b", "c"])
    XCTAssertEqual(resolver.searchCandidates(matching: "the map").map(\.idValue), ["b"])
    XCTAssertEqual(resolver.searchCandidates(matching: "atlas", limit: 0), [])
    XCTAssertEqual(resolver.searchCandidates(matching: "   "), [])
  }

  // MARK: - Text buffer snapshots

  func testBufferSnapshotsAreNativeUTF8() {
    let session = OrgSyntaxTextBufferSession(text: "* Héading\nbody")
    _ = session.replaceCharacters(in: NSRange(location: 14, length: 0), with: " — more")
    let snapshot = session.snapshot()
    XCTAssertEqual(snapshot.text, "* Héading\nbody — more")
    // A lazily bridged NSString has no contiguous UTF-8 storage; every later
    // `utf8.count` or comparison on the main actor would transcode it.
    XCTAssertTrue(snapshot.text.utf8.withContiguousStorageIfAvailable { _ in true } ?? false)
    _ = session.replaceCharacters(in: NSRange(location: 0, length: 1), with: "**")
    XCTAssertEqual(session.snapshot().text, "** Héading\nbody — more")
  }

  // MARK: - Observation

  func testUnchangedStatusWritesDoNotInvalidateObservers() throws {
    let suite = "hot-path-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(defaults: defaults)

    store.aiChatStatusText = "Codex is replying"
    store.statusText = "Saved"
    let statusChanged = HotPathObservationFlag()
    let chatStatusChanged = HotPathObservationFlag()
    withObservationTracking { _ = store.statusText } onChange: { statusChanged.value = true }
    withObservationTracking { _ = store.aiChatStatusText } onChange: { chatStatusChanged.value = true }

    store.aiChatStatusText = "Codex is replying"
    store.statusText = "Saved"
    XCTAssertFalse(statusChanged.value)
    XCTAssertFalse(chatStatusChanged.value)

    store.aiChatStatusText = "Codex replied"
    store.statusText = "Autosaved"
    XCTAssertTrue(statusChanged.value)
    XCTAssertTrue(chatStatusChanged.value)
    XCTAssertEqual(store.aiChatStatusText, "Codex replied")
    XCTAssertEqual(store.statusText, "Autosaved")
  }

  func testScrollPositionReportsDoNotInvalidateTheTranscript() throws {
    let suite = "hot-path-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(defaults: defaults)
    let threadID = UUID()

    let changed = HotPathObservationFlag()
    withObservationTracking {
      _ = store.aiChatScrollPosition(isAssistantPanel: false, threadID: threadID)
    } onChange: {
      changed.value = true
    }
    store.recordAIChatScrollPosition(0.4, threadID: threadID)
    XCTAssertFalse(changed.value, "The page reports its position on every scroll frame")
    XCTAssertEqual(try XCTUnwrap(store.aiChatScrollPosition(isAssistantPanel: false, threadID: threadID)), 0.4, accuracy: 0.001)
  }

  func testStreamingEventsCoalesceLiveUpdates() async {
    let live = AIChatLiveState()
    let threadID = UUID()
    var notifications = 0
    let cancellable = live.objectWillChange.sink { notifications += 1 }
    defer { cancellable.cancel() }
    for _ in 0..<50 {
      live.noteEvent(for: threadID, coalesced: true)
    }
    XCTAssertEqual(notifications, 0)
    XCTAssertNotNil(live.lastEventAt(for: threadID), "Readers see the pending event at once")
    live.flushPendingStreamUpdates()
    XCTAssertEqual(notifications, 1)
  }

  // MARK: - Thread lookup

  func testThreadLookupFollowsThreadListChanges() throws {
    let suite = "hot-path-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(defaults: defaults)
    let first = AIChatThread(title: "First", runtime: .codex, sessionKey: "first")
    let second = AIChatThread(title: "Second", runtime: .codex, sessionKey: "second")
    store.aiChatThreads = [first, second]
    XCTAssertEqual(store.aiChatThread(withID: second.id)?.title, "Second")
    store.aiChatThreads = [second]
    XCTAssertNil(store.aiChatThread(withID: first.id))
    XCTAssertEqual(store.aiChatThread(withID: second.id)?.title, "Second")
    let third = AIChatThread(title: "Third", runtime: .codex, sessionKey: "third")
    store.aiChatThreads.insert(third, at: 0)
    XCTAssertEqual(store.aiChatThread(withID: second.id)?.title, "Second")
    XCTAssertEqual(store.aiChatThread(withID: third.id)?.title, "Third")
  }

  func testSidebarPartitionMatchesPerThreadRunningState() throws {
    let suite = "hot-path-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(defaults: defaults)
    let threads = (0..<6).map {
      AIChatThread(title: "Thread \($0)", runtime: .codex, sessionKey: "thread-\($0)")
    }
    store.aiChatThreads = threads
    store.aiChatSendingThreadIDs = [threads[1].id, threads[4].id]
    let summaries = store.sidebarAIChatThreadSummaries
    let groups = store.partitionAIChatThreadSummariesByRunning(summaries)
    XCTAssertEqual(groups.running.map(\.id), summaries.filter { store.isAIChatThreadRunning($0.id) }.map(\.id))
    XCTAssertEqual(groups.idle.map(\.id), summaries.filter { !store.isAIChatThreadRunning($0.id) }.map(\.id))
    XCTAssertEqual(Set(groups.running.map(\.id)), [threads[1].id, threads[4].id])
  }
}
