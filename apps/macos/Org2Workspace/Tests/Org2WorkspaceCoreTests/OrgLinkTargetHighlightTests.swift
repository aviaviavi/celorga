import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class OrgLinkTargetHighlightTests: XCTestCase {
  func testOnlyLinkRequestsForTheLoadedFileHighlight() {
    let link = DetailScrollRequest(id: 3, target: .sourceLine(42), highlightedFile: "/srv/notes/plan.org")
    XCTAssertEqual(
      OrgHTMLLinkTargetHighlight.line(for: link, loadedSourceFile: "/srv/notes/./plan.org", isPageReady: true),
      42
    )
    XCTAssertNil(OrgHTMLLinkTargetHighlight.line(for: link, loadedSourceFile: "/srv/notes/plan.org", isPageReady: false))
    XCTAssertNil(OrgHTMLLinkTargetHighlight.line(for: link, loadedSourceFile: "/srv/notes/other.org", isPageReady: true))
    XCTAssertNil(OrgHTMLLinkTargetHighlight.line(for: link, loadedSourceFile: nil, isPageReady: true))
    let scroll = DetailScrollRequest(id: 4, target: .sourceLine(42))
    XCTAssertNil(OrgHTMLLinkTargetHighlight.line(for: scroll, loadedSourceFile: "/srv/notes/plan.org", isPageReady: true))
    let page = DetailScrollRequest(id: 5, target: .page(.down), highlightedFile: "/srv/notes/plan.org")
    XCTAssertNil(OrgHTMLLinkTargetHighlight.line(for: page, loadedSourceFile: "/srv/notes/plan.org", isPageReady: true))
  }

  func testRenderedHighlightMarksTheHeadingOrSmallestElementAtTheLine() async throws {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    view.loadHTMLString("""
      <main>
        <details class="org2-headline" open data-org2-start-line="3" data-org2-end-line="9">
          <summary><h2>Launch plan</h2></summary>
          <p data-org2-start-line="5" data-org2-end-line="6">Book the venue.</p>
          <p data-org2-start-line="8" data-org2-end-line="8">Send invites.</p>
        </details>
      </main>
      """, baseURL: nil)
    for _ in 0..<150 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
      try await Task.sleep(for: .milliseconds(20))
    }

    func flash(_ line: Int, reduceMotion: Bool = false) async throws -> [String] {
      let found = try await view.evaluateJavaScript(
        OrgHTMLLinkTargetHighlight.script(line: line, reduceMotion: reduceMotion)
      ) as? Bool
      XCTAssertEqual(found, true)
      try await Task.sleep(for: .milliseconds(120))
      return try await view.evaluateJavaScript("""
        [...document.querySelectorAll('.org2-link-target')].map(e=>e.tagName+(e.classList.contains('org2-link-target-still')?':still':''))
        """) as? [String] ?? []
    }

    let heading = try await flash(3)
    XCTAssertEqual(heading, ["H2"])
    let paragraph = try await flash(6, reduceMotion: true)
    XCTAssertTrue(paragraph.contains("P:still"), "\(paragraph)")
    let styles = try await view.evaluateJavaScript("document.querySelectorAll('style[data-org2-link-target]').length") as? Int
    XCTAssertEqual(styles, 1)

    try await Task.sleep(for: .milliseconds(Int(OrgHTMLLinkTargetHighlight.duration * 1_000) + 200))
    let remaining = try await view.evaluateJavaScript("document.querySelectorAll('.org2-link-target').length") as? Int
    XCTAssertEqual(remaining, 0)
  }

  func testSourceLineRevealRangesAndReducedMotionFlash() {
    let text = "#+TITLE: Plan\n\n* Launch\nBook the venue.\n" as NSString
    let ranges = OrgSourceTextEditing.lineRevealRanges(in: text, line: 3)
    XCTAssertEqual(text.substring(with: ranges.content), "* Launch")
    XCTAssertEqual(text.substring(with: ranges.line), "* Launch\n")
    let blank = OrgSourceTextEditing.lineRevealRanges(in: text, line: 2)
    XCTAssertEqual(blank.content.length, 0)

    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    textView.string = text as String
    OrgSourceTextEditing.flashLine(ranges, in: textView, reduceMotion: true)
    let layoutManager = textView.layoutManager
    XCTAssertNotNil(layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: ranges.content.location, effectiveRange: nil))
    XCTAssertNil(layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil))
  }

  func testLinkNavigationRequestsAHighlightAndOtherNavigationDoesNot() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-link-highlight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("plan.org")
    let text = (1...60).map { "* Step \($0)" }.joined(separator: "\n") + "\n"
    try text.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.entrySourceLoaderForTesting = { file, _, _ in
      EntrySource(file: file, startLine: 1, endLineExclusive: 61, text: text, isSubtree: false)
    }
    store.openChatFileReference(AIChatFileReference(path: note.path, line: 1))
    for _ in 0..<400 {
      if store.selectedEntrySource?.file == note.path, !store.isLoadingEntrySource { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(store.selectedEntrySource?.file, note.path)
    XCTAssertNil(store.detailScrollRequest?.highlightedFile)

    store.openChatFileReference(AIChatFileReference(path: note.path, line: 42), highlightsLine: true)
    XCTAssertEqual(store.detailScrollRequest?.target, .sourceLine(42))
    XCTAssertEqual(store.detailScrollRequest?.highlightedFile, note.path)

    store.openChatFileReference(AIChatFileReference(path: note.path, line: 12))
    XCTAssertEqual(store.detailScrollRequest?.target, .sourceLine(12))
    XCTAssertNil(store.detailScrollRequest?.highlightedFile)
  }
}
