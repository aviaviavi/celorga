import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Org2WorkspaceCore

/// A new render of the file on screen must change only the entries that
/// differ. The patched page has to match a fresh load of the new render,
/// while nodes outside the change (and the reader's folds) stay put.
@MainActor
final class OrgHTMLDocumentPatchTests: XCTestCase {
  private let sample = """
  #+TITLE: Patch

  * Today
  ** TODO First task
  SCHEDULED: <2026-11-16 Mon>
  ** TODO Second task
  - [ ] alpha
  - [ ] beta
  - [ ] gamma

  * Notes
  A paragraph about things.

  | a | b |
  |---+---|
  | 1 | 2 |
  * Later
  ** TODO Third task
  """

  private var windows: [NSWindow] = []

  override func tearDown() async throws {
    for window in windows { window.orderOut(nil) }
    windows.removeAll()
  }

  // MARK: Shell

  func testDocumentShellIgnoresViewStylesButNotOtherHeadChanges() {
    let page = { (head: String, body: String) in
      "<!doctype html><html><head><title>T</title>\(head)</head><body class=\"x\">\(body)</body></html>"
    }
    let layout = OrgHTMLDocumentLayout(width: .comfortable, margin: .standard)
    let plain = page("", "<p>one</p>")
    let styled = layout.injecting(into: WorkspaceThemeDocumentStyle.injecting(":root { color: red; }", into: page("", "<p>two</p>")))
    XCTAssertTrue(OrgHTMLDocumentPatch.sharesDocumentShell(plain, styled))
    XCTAssertFalse(OrgHTMLDocumentPatch.sharesDocumentShell(plain, page("<script>chart()</script>", "<p>one</p>")))
    XCTAssertFalse(OrgHTMLDocumentPatch.sharesDocumentShell(plain, plain.replacingOccurrences(of: "class=\"x\"", with: "")))
    XCTAssertFalse(OrgHTMLDocumentPatch.sharesDocumentShell(plain, "<p>no head</p>"))
  }

  func testRendersOfTheSameFileShareAShellUnlessAChartAddsItsScript() async throws {
    let before = try await render(sample)
    let after = try await render(markFirstDone(sample))
    XCTAssertTrue(OrgHTMLDocumentPatch.sharesDocumentShell(before, after))
    let chart = try await render(sample + "\n\n#+begin_src chart bar\nx: a\ny: b\n#+end_src\n")
    XCTAssertFalse(OrgHTMLDocumentPatch.sharesDocumentShell(before, chart))
  }

  // MARK: Patching

  func testMarkingDoneUpdatesOnlyThatEntryAndRenumbersTheRest() async throws {
    let next = markFirstDone(sample)
    let page = try await loadedPage(sample)
    try await tag("details.org2-headline[data-org2-start-line='6']", in: page)
    try await tag("details.org2-headline[data-org2-start-line='11']", in: page)

    let outcome = try await patch(page, to: next)
    XCTAssertEqual(outcome, "patched")
    try await assertMatchesFreshLoad(page, of: next)
    // Later entries keep their nodes and move down one line for CLOSED.
    let kept = try await taggedLines(in: page)
    XCTAssertEqual(kept, ["7", "12"])
  }

  func testReschedulingAndReorderingListItemsMatchAFreshLoad() async throws {
    let rescheduled = sample.replacingOccurrences(of: "<2026-11-16 Mon>", with: "<2026-11-20 Fri>")
    let page = try await loadedPage(sample)
    try await tag("details.org2-headline[data-org2-start-line='11']", in: page)
    let outcome = try await patch(page, to: rescheduled)
    XCTAssertEqual(outcome, "patched")
    try await assertMatchesFreshLoad(page, of: rescheduled)

    let reordered = rescheduled.replacingOccurrences(
      of: "- [ ] alpha\n- [ ] beta\n- [ ] gamma",
      with: "- [ ] gamma\n- [ ] alpha\n- [ ] beta"
    )
    let reorderOutcome = try await patch(page, to: reordered)
    XCTAssertEqual(reorderOutcome, "patched")
    try await assertMatchesFreshLoad(page, of: reordered)
    let kept = try await taggedLines(in: page)
    XCTAssertEqual(kept, ["11"])
  }

  func testInsertingRemovingAndEditingEntriesMatchAFreshLoad() async throws {
    let page = try await loadedPage(sample)
    try await tag("details.org2-headline[data-org2-start-line='17']", in: page)

    let inserted = sample.replacingOccurrences(of: "* Notes\n", with: "* Inbox\n** TODO Captured\n* Notes\n")
    let insertOutcome = try await patch(page, to: inserted)
    XCTAssertEqual(insertOutcome, "patched")
    try await assertMatchesFreshLoad(page, of: inserted)

    let edited = inserted.replacingOccurrences(of: "A paragraph about things.", with: "A paragraph about *other* things.")
    let editOutcome = try await patch(page, to: edited)
    XCTAssertEqual(editOutcome, "patched")
    try await assertMatchesFreshLoad(page, of: edited)

    let removed = edited.replacingOccurrences(of: "** TODO Second task\n- [ ] alpha\n- [ ] beta\n- [ ] gamma\n", with: "")
    let removeOutcome = try await patch(page, to: removed)
    XCTAssertEqual(removeOutcome, "patched")
    try await assertMatchesFreshLoad(page, of: removed)
    let kept = try await taggedLines(in: page)
    XCTAssertEqual(kept, ["15"])

    let unchangedOutcome = try await patch(page, to: removed)
    XCTAssertEqual(unchangedOutcome, "unchanged")
  }

  func testFoldedSectionsAndPageDecorationsSurviveAPatch() async throws {
    let page = try await loadedPage(sample)
    _ = try await page.callAsyncJavaScript(
      "document.querySelector(\"details[data-org2-start-line='11']\").open = false; return true;",
      arguments: [:], in: nil, contentWorld: .page
    )
    let outcome = try await patch(page, to: markFirstDone(sample))
    XCTAssertEqual(outcome, "patched")
    let state = try await page.callAsyncJavaScript(
      """
      const notes = document.querySelector("details[data-org2-start-line='12']");
      const first = document.querySelector("details[data-org2-start-line='4']");
      return [
        String(notes.open),
        String(document.querySelectorAll('.org2-table-controls').length),
        String(first.querySelectorAll(':scope > summary > .org2-heading-ai-action').length)
      ];
      """,
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String]
    // The folded section stays folded, the table keeps one set of controls,
    // and the replaced heading gets its Ask AI action back.
    XCTAssertEqual(state, ["false", "1", "1"])
  }

  func testProvisionalEffectsAreReplacedByTheNextRenderOrRestoredOnRevert() async throws {
    let page = try await loadedPage(sample)
    let effect = OrgHTMLEntryEffect(
      id: 1,
      file: "/tmp/patch.org",
      line: 4,
      change: .todo(keyword: "DONE", state: .done, closedTimestamp: "<2026-11-16 Mon 09:30>")
    )
    _ = try await page.evaluateJavaScript(try XCTUnwrap(OrgHTMLEntryEffectScript.invocation(for: effect)) + "\ntrue;")
    try await Task.sleep(nanoseconds: UInt64((OrgHTMLEntryEffectScript.animationDuration + 0.2) * 1_000_000_000))

    // A failed write re-presents the last render, which must undo the effect.
    let revertOutcome = try await patch(page, to: sample)
    XCTAssertEqual(revertOutcome, "patched")
    try await assertMatchesFreshLoad(page, of: sample)

    _ = try await page.evaluateJavaScript(try XCTUnwrap(OrgHTMLEntryEffectScript.invocation(for: effect)) + "\ntrue;")
    let next = markFirstDone(sample)
    let outcome = try await patch(page, to: next)
    XCTAssertEqual(outcome, "patched")
    try await assertMatchesFreshLoad(page, of: next)
  }

  func testDocumentViewPatchesANewRenderOfTheSameFileWithoutReloading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-document-patch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("patch.org")
    let source = EntrySource(file: file.path, startLine: 1, endLineExclusive: 19, text: sample, isSubtree: false)
    let next = markFirstDone(sample)
    let nextSource = EntrySource(file: file.path, startLine: 1, endLineExclusive: 20, text: next, isSubtree: false)

    let hosting = NSHostingView(rootView: documentView(html: try await render(sample), identity: "one", source: source, root: root))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    windows.append(window)

    var found: WKWebView?
    try await waitUntil {
      found = Self.firstWebView(in: window.contentView)
      guard let found else { return false }
      return (try? await found.callAsyncJavaScript(
        "return document.readyState === 'complete' && !!document.querySelector('.org2-heading-ai-action');",
        arguments: [:], in: nil, contentWorld: .page
      )) as? Bool == true
    }
    let page = try XCTUnwrap(found)
    _ = try await page.callAsyncJavaScript("window.__org2SamePage = true; return true;", arguments: [:], in: nil, contentWorld: .page)

    hosting.rootView = documentView(html: try await render(next), identity: "two", source: nextSource, root: root)
    try await waitUntil {
      (try? await page.callAsyncJavaScript(
        "return document.querySelector(\"details[data-org2-start-line='4'] .org2-todo\")?.textContent === 'DONE';",
        arguments: [:], in: nil, contentWorld: .page
      )) as? Bool == true
    }
    let samePage = try await page.callAsyncJavaScript(
      "return window.__org2SamePage === true;",
      arguments: [:], in: nil, contentWorld: .page
    ) as? Bool
    XCTAssertEqual(samePage, true, "The view must update the page in place, not load a new one")
  }

  // MARK: Helpers

  private func markFirstDone(_ text: String) -> String {
    text.replacingOccurrences(
      of: "** TODO First task\nSCHEDULED: <2026-11-16 Mon>\n",
      with: "** DONE First task\nCLOSED: <2026-11-16 Mon 09:30> SCHEDULED: <2026-11-16 Mon>\nFinished early.\n"
    )
  }

  private func render(_ text: String) async throws -> String {
    try await Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()).renderAppHTML(text, sourcePath: "/tmp/patch.org")
  }

  private func documentView(html: String, identity: String, source: EntrySource, root: URL) -> OrgHTMLDocumentView {
    OrgHTMLDocumentView(
      html: html,
      renderIdentity: identity,
      source: source,
      corpusRoot: root,
      searchQuery: nil,
      searchOccurrenceIndex: nil,
      searchOccurrenceCount: 0,
      scrollRequest: nil,
      layout: OrgHTMLDocumentLayout(width: .comfortable, margin: .standard),
      askAIAboutHeading: { _ in },
      performEntryAction: { _, _ in },
      reportStatus: { _ in }
    )
  }

  private func loadedPage(_ text: String) async throws -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.addUserScript(WKUserScript(
      source: OrgHTMLDocumentPatch.installationScript,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: true
    ))
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 800), configuration: configuration)
    view.loadHTMLString(try await render(text), baseURL: nil)
    try await waitUntil {
      guard !view.isLoading else { return false }
      return (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete"
    }
    return view
  }

  private func patch(_ page: WKWebView, to text: String) async throws -> String? {
    let html = try await render(text)
    return try await page.callAsyncJavaScript(
      OrgHTMLDocumentPatch.invocation,
      arguments: ["html": html],
      in: nil,
      contentWorld: .page
    ) as? String
  }

  private func tag(_ selector: String, in page: WKWebView) async throws {
    let tagged = try await page.callAsyncJavaScript(
      "const element = document.querySelector(selector); if (!element) return false; element.__org2Kept = true; return true;",
      arguments: ["selector": selector], in: nil, contentWorld: .page
    ) as? Bool
    XCTAssertEqual(tagged, true, selector)
  }

  /// Start lines of the elements tagged before patching that are still in
  /// the page.
  private func taggedLines(in page: WKWebView) async throws -> [String] {
    try await page.callAsyncJavaScript(
      """
      return Array.from(document.querySelectorAll('[data-org2-start-line]'))
        .filter((element) => element.__org2Kept === true)
        .map((element) => element.dataset.org2StartLine);
      """,
      arguments: [:], in: nil, contentWorld: .page
    ) as? [String] ?? []
  }

  /// The page's content with what scripts add removed, for comparing a
  /// patched page with a fresh load.
  private static let normalizedBodyScript = """
  const clone = document.body.cloneNode(true);
  clone.querySelectorAll('.org2-heading-ai-action, .org2-table-controls, .org2-column-resizer, .org2-drag-grip, colgroup')
    .forEach((element) => element.remove());
  clone.querySelectorAll('*').forEach((element) => {
    element.removeAttribute('style');
    element.classList.remove('org2-section-label', 'org2-resizable-table', 'org2-table-resize-anchor');
    for (const name of Array.from(element.getAttributeNames())) {
      if (name.startsWith('data-org2-interactive') || name === 'data-org2-resizable') element.removeAttribute(name);
    }
    if (element.getAttribute('class') === '') element.removeAttribute('class');
  });
  return clone.innerHTML.replace(/>\\s+</g, '><').trim();
  """

  private func assertMatchesFreshLoad(
    _ page: WKWebView,
    of text: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let fresh = try await loadedPage(text)
    let expected = try await fresh.callAsyncJavaScript(Self.normalizedBodyScript, arguments: [:], in: nil, contentWorld: .page) as? String
    let actual = try await page.callAsyncJavaScript(Self.normalizedBodyScript, arguments: [:], in: nil, contentWorld: .page) as? String
    XCTAssertNotNil(expected, file: file, line: line)
    XCTAssertEqual(actual, expected, file: file, line: line)
  }

  private func waitUntil(
    timeout: TimeInterval = 8,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
  }

  private static func firstWebView(in view: NSView?) -> WKWebView? {
    guard let view else { return nil }
    if let webView = view as? WKWebView { return webView }
    for subview in view.subviews {
      if let webView = firstWebView(in: subview) { return webView }
    }
    return nil
  }
}
