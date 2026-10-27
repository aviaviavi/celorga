import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatDocumentTests: XCTestCase {
  private func document(_ html: String) async throws -> WKWebView {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
    view.loadHTMLString("<html><head><style>\(AIChatDocumentHTML.style)</style></head><body><main></main></body></html>", baseURL: nil)
    for _ in 0..<100 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    // The production handler reports geometry to SwiftUI; this fixture keeps a fixed viewport.
    try await view.evaluateJavaScript("window.webkit = {messageHandlers: {chatHeight: {postMessage: function() {}}}}; null;")
    try await view.evaluateJavaScript(AIChatDocumentHTML.updateScript)
    view.callAsyncJavaScript("window.__chatUpdate(html)", arguments: ["html": html], in: nil, in: .page)
    return view
  }

  func testSharedRendererKeepsBulletsAndTextOnTheSameLine() async throws {
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML("Added in Preview:\n\n- Subtle press feedback.\n- Smooth thread settlement and reopening.\n- Reduce Motion support.\n\nBuild checks pass.", sourcePath: "/tmp/chat-test.org")
    let view = try await document(html)
    let result = try await view.evaluateJavaScript("""
      (() => {
        const items = [...document.querySelectorAll('li')];
        return {count:items.length, inline:items.every(li => {
          const range=document.createRange(); range.selectNodeContents(li);
          return Math.abs(range.getBoundingClientRect().top-li.getBoundingClientRect().top)<8;
        }), text:document.body.innerText};
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["count"] as? Int, 3)
    XCTAssertEqual(result?["inline"] as? Bool, true)
    XCTAssertTrue((result?["text"] as? String)?.contains("Reduce Motion support.") == true)
  }

  func testChatHeadingsStayCompactAndEmptyHeadingsHaveNoFoldToggle() async throws {
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML(
      "Intro.\n\n* Tests: 33 passed\n* Details\nSome text.\n** Child\n- a\n",
      sourcePath: "/tmp/chat-test.org"
    )
    let view = try await document(html)
    let result = try await view.evaluateJavaScript("""
      (() => {
        const size = node => parseFloat(getComputedStyle(node).fontSize);
        const marker = node => getComputedStyle(node.querySelector('.org2-headline-summary'), '::before').content;
        const empty = document.querySelector('.org2-headline-empty');
        const folding = [...document.querySelectorAll('details.org2-headline')];
        return {
          body: size(document.querySelector('p')),
          h1: Math.max(...[...document.querySelectorAll('h1')].map(size)),
          h2: size(document.querySelector('h2')),
          details: folding.map(node => node.querySelector('h1, h2').textContent),
          emptyTitle: empty && empty.textContent.trim(),
          emptyMarker: empty && marker(empty),
          foldingMarker: marker(folding[0]),
          text: document.body.innerText
        };
      })()
      """) as? [String: Any]
    let body = try XCTUnwrap(result?["body"] as? Double)
    XCTAssertLessThanOrEqual(try XCTUnwrap(result?["h1"] as? Double), body + 2)
    XCTAssertLessThanOrEqual(try XCTUnwrap(result?["h2"] as? Double), body + 1)
    XCTAssertEqual(result?["details"] as? [String], ["Details", "Child"])
    XCTAssertEqual(result?["emptyTitle"] as? String, "Tests: 33 passed")
    XCTAssertEqual(result?["emptyMarker"] as? String, "none")
    XCTAssertNotEqual(result?["foldingMarker"] as? String, "none")
    XCTAssertTrue((result?["text"] as? String)?.contains("Some text.") == true)
  }

  func testChatNormalizerRepairsNestedOrgCodeInsideEmphasis() async throws {
    let raw = """
    - *=celorga.app= — primary domain.* Natural for downloads.
    - /Use ~celorga run~ from the CLI./
    """
    let normalized = AIChatMessageOrgNormalizer.normalized(raw)
    XCTAssertEqual(normalized, """
    - =celorga.app= *— primary domain.* Natural for downloads.
    - /Use/ ~celorga run~ /from the CLI./
    """)

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML(normalized, sourcePath: "/tmp/chat-test.org")
    let view = try await document(html)
    let result = try await view.evaluateJavaScript("""
      (() => ({
        code:[...document.querySelectorAll('code')].map(node => node.textContent),
        strong:[...document.querySelectorAll('strong')].map(node => node.textContent),
        italic:[...document.querySelectorAll('em')].map(node => node.textContent),
        text:document.body.innerText
      }))()
      """) as? [String: Any]
    XCTAssertEqual(result?["code"] as? [String], ["celorga.app", "celorga run"])
    XCTAssertEqual(result?["strong"] as? [String], ["— primary domain."])
    XCTAssertEqual(result?["italic"] as? [String], ["Use", "from the CLI."])
    XCTAssertFalse((result?["text"] as? String ?? "").contains("=celorga.app="))
  }

  func testChatNormalizerRendersBoldMarkdownLinksInTablesAsLinks() async throws {
    // From the 2026-10-15 OpenClaw reply: Markdown strong emphasis around a
    // Markdown link rendered as raw `*[[url][label]]*` text inside table cells.
    let raw = """
    Yes—**four more worth screening**. Of these, I’d try **Santos Solano first**, because.

    | CPA / firm | Contact |
    |---|---|
    | **[Santos Solano — Sensiba](https://sensiba.com/santos-solano/)** · San Jose | **ssolano@sensiba.com** · **408-286-7780** |
    | *[[https://example.com/chad][Chad McArthur]]* · SF | [Contact BPM](https://www.bpm.com/contact-us/) |

    Keep =**literal**= and `2**3` as written.
    """
    let normalized = AIChatMessageOrgNormalizer.normalized(raw)
    let lines = normalized.components(separatedBy: "\n")
    XCTAssertEqual(lines[0], "Yes—*four more worth screening*. Of these, I’d try *Santos Solano first*, because.")
    XCTAssertEqual(lines[4], "| [[https://sensiba.com/santos-solano/][Santos Solano — Sensiba]] · San Jose | *ssolano@sensiba.com* · *408-286-7780* |")
    XCTAssertEqual(lines[5], "| [[https://example.com/chad][Chad McArthur]] · SF | [[https://www.bpm.com/contact-us/][Contact BPM]] |")
    XCTAssertEqual(lines[7], "Keep =**literal**= and `2**3` as written.")

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML(normalized, sourcePath: "/tmp/chat-test.org")
    let view = try await document(html)
    let result = try await view.evaluateJavaScript("""
      (() => ({
        links:[...document.querySelectorAll('td a')].map(node => node.textContent),
        strong:[...document.querySelectorAll('strong')].map(node => node.textContent),
        text:document.body.innerText
      }))()
      """) as? [String: Any]
    XCTAssertEqual(result?["links"] as? [String], ["Santos Solano — Sensiba", "Chad McArthur", "Contact BPM"])
    XCTAssertEqual(
      result?["strong"] as? [String],
      ["four more worth screening", "Santos Solano first", "ssolano@sensiba.com", "408-286-7780"]
    )
    let text = result?["text"] as? String ?? ""
    XCTAssertFalse(text.contains("[["), text)
    XCTAssertFalse(text.contains("*four"), text)
  }

  func testPastedThreadIDsBecomeTitledLinksOnlyForRealThreads() async throws {
    let known = UUID(uuidString: "D1DD78EA-BE29-4045-B609-624E071E4AB2")!
    let text = """
    See d1dd78ea-be29-4045-b609-624e071e4ab2 and =d1dd78ea-be29-4045-b609-624e071e4ab2=, \
    not 00000000-0000-4000-8000-000000000000.
    """
    let links = AIChatThreadLinks.links(in: text) { $0 == known ? "Automation: fix-celorga-items" : nil }
    XCTAssertEqual(links, ["d1dd78ea-be29-4045-b609-624e071e4ab2": "Automation: fix-celorga-items"])
    XCTAssertEqual(
      AIChatThreadLinks.threadID(from: try XCTUnwrap(URL(string: AIChatThreadLinks.url(for: known.uuidString)))),
      known
    )

    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 600))
    view.loadHTMLString("<html><head><style>\(AIChatDocumentHTML.style)</style></head><body><main></main></body></html>", baseURL: nil)
    for _ in 0..<100 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    try await view.evaluateJavaScript("window.webkit = {messageHandlers: {chatHeight: {postMessage: function() {}}}}; null;")
    try await view.evaluateJavaScript(AIChatThreadLinks.script)
    try await view.evaluateJavaScript(AIChatDocumentHTML.updateScript)
    let html = """
    <main><p>See d1dd78ea-be29-4045-b609-624e071e4ab2 and <code>d1dd78ea-be29-4045-b609-624e071e4ab2</code>, \
    not 00000000-0000-4000-8000-000000000000.</p><pre>d1dd78ea-be29-4045-b609-624e071e4ab2</pre></main>
    """
    view.callAsyncJavaScript(
      "window.__chatUpdate(html, [], threads)",
      arguments: ["html": html, "threads": links],
      in: nil,
      in: .page
    )
    let result = try await view.evaluateJavaScript("""
      (() => ({
        labels:[...document.querySelectorAll('a.chat-thread-link')].map(a => a.textContent),
        hrefs:[...document.querySelectorAll('a.chat-thread-link')].map(a => a.getAttribute('href')),
        pre:document.querySelector('pre').textContent,
        text:document.querySelector('p').textContent
      }))()
      """) as? [String: Any]
    XCTAssertEqual(result?["labels"] as? [String], ["Automation: fix-celorga-items", "Automation: fix-celorga-items"])
    XCTAssertEqual(
      result?["hrefs"] as? [String],
      Array(repeating: AIChatThreadLinks.url(for: known.uuidString), count: 2)
    )
    XCTAssertEqual(result?["pre"] as? String, "d1dd78ea-be29-4045-b609-624e071e4ab2")
    XCTAssertTrue((result?["text"] as? String ?? "").contains("00000000-0000-4000-8000-000000000000"))
  }

  func testSelectionSpansParagraphsListsAndTablesAndSurvivesUpdates() async throws {
    let view = try await document("<main><p>First paragraph.</p><ul><li>Second item.</li></ul><table><tr><td>Third cell.</td></tr></table></main>")
    let selected = try await view.evaluateJavaScript("""
      const range=document.createRange(); range.selectNodeContents(document.querySelector('main'));
      getSelection().removeAllRanges(); getSelection().addRange(range); getSelection().toString();
      """) as? String
    XCTAssertTrue(selected?.contains("First paragraph.") == true)
    XCTAssertTrue(selected?.contains("Second item.") == true)
    XCTAssertTrue(selected?.contains("Third cell.") == true)
    view.callAsyncJavaScript("window.__chatUpdate(html)", arguments: ["html": "<main><p>Updated response.</p></main>"], in: nil, in: .page)
    let retained = try await view.evaluateJavaScript("getSelection().toString()") as? String
    XCTAssertEqual(retained, selected)
    try await view.evaluateJavaScript("getSelection().removeAllRanges(); document.dispatchEvent(new Event('selectionchange'));")
    let updated = try await view.evaluateJavaScript("document.body.innerText") as? String
    XCTAssertEqual(updated?.trimmingCharacters(in: .whitespacesAndNewlines), "Updated response.")
  }

  func testPlainFallbackEscapesMarkupAndPreservesWhitespace() {
    let html = AIChatDocumentHTML.plain("<script>alert(1)</script>\n  literal")
    XCTAssertFalse(html.contains("<script>"))
    XCTAssertTrue(html.contains("&lt;script&gt;"))
    XCTAssertTrue(html.contains("\n  literal"))
  }
  func testWrappedProseAndTablesExpandAndCodeKeepsNaturalLines() async throws {
    let prose = String(repeating: "A sentence that should wrap naturally. ", count: 20)
    let raw = prose + "\n\n| First | Second |\n|---+---|\n| " + prose + " | A cell |\n\n#+begin_src text\n" + String(repeating: "x", count: 180) + "\n#+end_src"
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML(raw, sourcePath: "/tmp/chat-test.org")
    let view = try await document(html)
    let result = try await view.evaluateJavaScript("""
      (() => { const pre=document.querySelector('pre'); const table=document.querySelector('table');
        return {height:document.querySelector('main').getBoundingClientRect().height,
          tableHeight:table.getBoundingClientRect().height, scrolls:pre.scrollWidth>pre.clientWidth,
          copyButtons:document.querySelectorAll('.chat-copy-code').length}; })()
      """) as? [String: Any]
    XCTAssertGreaterThan(result?["height"] as? Double ?? 0, 300)
    XCTAssertGreaterThan(result?["tableHeight"] as? Double ?? 0, 100)
    XCTAssertEqual(result?["scrolls"] as? Bool, true)
    XCTAssertEqual(result?["copyButtons"] as? Int, 1)
  }

}
