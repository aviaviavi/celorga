import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceSearchIndexTests: XCTestCase {
  func testChatSearchIndexReadsOnlyThreadsThatChanged() {
    let index = AIChatSearchIndex()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("chat-search-index-\(UUID().uuidString).json")
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let threads = (0..<3).map { offset in
      AIChatThread(
        title: "Thread \(offset)",
        updatedAt: start,
        sessionKey: "index-\(offset)",
        storedMessageCount: 1
      )
    }
    var loads: [UUID] = []
    func load(_ metadata: AIChatThread) -> AIChatThread? {
      loads.append(metadata.id)
      return metadata.replacingMessagesForSearchTest([
        AIChatMessage(role: .user, content: "\(metadata.title) mentions Orbitwave")
      ])
    }

    let first = index.documents(for: threads, transcriptURL: transcriptURL, load: load)
    XCTAssertEqual(loads.count, 3)
    XCTAssertEqual(first.map { $0.messages.first?.text }, threads.map { "\($0.title) mentions Orbitwave" })

    loads.removeAll()
    _ = index.documents(for: threads, transcriptURL: transcriptURL, load: load)
    XCTAssertTrue(loads.isEmpty, "Unchanged threads must come from the cache")

    var changed = threads
    changed[1] = AIChatThread(
      id: threads[1].id,
      title: threads[1].title,
      updatedAt: start.addingTimeInterval(60),
      sessionKey: threads[1].sessionKey,
      storedMessageCount: 2
    )
    loads.removeAll()
    let refreshed = index.documents(for: Array(changed.prefix(2)), transcriptURL: transcriptURL, load: load)
    XCTAssertEqual(loads, [threads[1].id])
    XCTAssertEqual(refreshed.count, 2, "Deleted threads drop out of the results")
  }

  func testQueryMatchesLiterallyWithoutCaseOrSubsequenceMatches() throws {
    let query = try XCTUnwrap(WorkspaceSearchQuery("Reddit"))
    XCTAssertEqual(query.match("Posted on REDDIT yesterday"), .phrase)
    XCTAssertNil(query.match("read the docs, did it work?"))
    XCTAssertEqual(query.titleQuality("Reddit"), WorkspaceSearchRanking.exactTitleQuality)
    XCTAssertEqual(query.titleQuality("Reddit launch"), WorkspaceSearchRanking.wordTitleQuality)
    XCTAssertEqual(query.titleQuality("subreddit ideas"), WorkspaceSearchRanking.substringTitleQuality)

    let multiWord = try XCTUnwrap(WorkspaceSearchQuery("  launch   plan "))
    XCTAssertEqual(multiWord.match("The launch plan is ready"), .phrase)
    XCTAssertEqual(multiWord.match("Plan the product launch"), .allTerms)
    XCTAssertNil(multiWord.match("Launch only"))

    let accented = try XCTUnwrap(WorkspaceSearchQuery("café"))
    XCTAssertEqual(accented.match("Meet at the CAFE"), .phrase)
    XCTAssertNil(WorkspaceSearchQuery("   "))
  }

  func testCorpusRecencyPrefersWrittenDatesOverModificationTimes() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let undated = SearchResult(
      file: "/tmp/recipes.org2", line: 3, lineEnd: nil, heading: "[[https://orbitwave.example][Buns]]",
      headingLine: 3, headingLevel: 1, headingAncestry: nil, idValue: nil, todo: nil, tags: [],
      snippet: "* [[https://orbitwave.example][Buns]]", sourceRange: nil, matchedLines: nil, date: nil
    )
    let query = WorkspaceSearchQuery("orbitwave")
    XCTAssertEqual(
      WorkspaceSearchRanking.corpusResultQuality(undated, query: query),
      WorkspaceSearchRanking.bodyPhraseQuality,
      "Hidden link targets are not heading matches"
    )
    let recency = WorkspaceSearchRanking.corpusResultRecency(undated, modifiedAt: now, now: now)
    XCTAssertEqual(
      recency.boost,
      WorkspaceSearchRanking.recencyWeight * WorkspaceSearchRanking.modifiedTimeRecencyFactor,
      accuracy: 0.001
    )
  }
}

private extension AIChatThread {
  func replacingMessagesForSearchTest(_ messages: [AIChatMessage]) -> AIChatThread {
    AIChatThread(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      sessionKey: sessionKey,
      messages: messages
    )
  }
}
