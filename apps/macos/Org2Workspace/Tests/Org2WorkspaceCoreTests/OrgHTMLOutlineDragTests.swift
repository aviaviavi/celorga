import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
private final class OutlineMoveRecorder {
  var requests: [OrgOutlineMoveRequest] = []
  var shouldPersist = false
}

@MainActor
final class OrgHTMLOutlineDragTests: XCTestCase {
  private var windows: [NSWindow] = []

  private func closeWindows() {
    for window in windows { window.orderOut(nil) }
    windows.removeAll()
  }

  private func renderedPage(
    text: String = OrgOutlineMoveTests.sample,
    startLine: Int = 1,
    isSubtree: Bool = false,
    recorder: OutlineMoveRecorder
  ) async throws -> (WKWebView, EntrySource) {
    closeWindows()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-outline-drag-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("drag.org")
    let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
    let source = EntrySource(
      file: file.path,
      startLine: startLine,
      endLineExclusive: startLine + lineCount,
      text: text,
      isSubtree: isSubtree
    )
    let html = try await Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()).renderAppHTML(
      text,
      sourcePath: file.path,
      sourceLineOffset: startLine - 1
    )
    let content = OrgHTMLDocumentView(
      html: html,
      source: source,
      corpusRoot: root,
      searchQuery: nil,
      searchOccurrenceIndex: nil,
      searchOccurrenceCount: 0,
      scrollRequest: nil,
      layout: OrgHTMLDocumentLayout(width: .comfortable, margin: .standard),
      askAIAboutHeading: { _ in },
      performEntryAction: { _, _ in },
      reportStatus: { _ in },
      allowsOutlineMoves: true,
      moveOutlineEntry: { request in
        recorder.requests.append(request)
        return recorder.shouldPersist
      }
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 1100),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.contentView = NSHostingView(rootView: content)
    window.makeKeyAndOrderFront(nil)
    windows.append(window)

    var webView: WKWebView?
    try await waitUntil {
      webView = Self.firstWebView(in: window.contentView)
      return webView != nil
    }
    let page = try XCTUnwrap(webView)
    try await waitUntil {
      (try? await page.callAsyncJavaScript(
        "return document.querySelectorAll('.org2-drag-grip').length;",
        arguments: [:], in: nil, contentWorld: .page
      )) as? Int ?? 0 > 0
    }
    if ProcessInfo.processInfo.environment["CELORGA_OUTLINE_DRAG_SNAPSHOTS"] != nil {
      // An offscreen test window does not advance CSS transitions.
      _ = try await page.callAsyncJavaScript(
        "const s = document.createElement('style'); s.textContent = '*, *::before { transition: none !important; }'; document.head.appendChild(s); return true;",
        arguments: [:], in: nil, contentWorld: .page
      )
    }
    return (page, source)
  }

  /// Presses the entry's grip, drags to the top edge of `destination`
  /// (`dx` pixels sideways), and optionally releases.
  @discardableResult
  private func drag(
    _ entry: String,
    to destination: String,
    edge: String = "top",
    dx: Double = 0,
    release: Bool = true,
    in page: WKWebView
  ) async throws -> String? {
    let result = try await page.callAsyncJavaScript(
      """
      const entry = document.querySelector(entrySelector);
      const grip = entry.matches('details')
        ? entry.querySelector(':scope > summary > .org2-drag-grip')
        : entry.querySelector(':scope > .org2-drag-grip');
      const fire = (type, x, y) => grip.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, pointerId: 7, pointerType: 'mouse',
        isPrimary: true, button: 0, buttons: type === 'pointerup' ? 0 : 1, clientX: x, clientY: y
      }));
      const box = grip.getBoundingClientRect();
      const x = box.left + box.width / 2;
      const y = box.top + box.height / 2;
      fire('pointerdown', x, y);
      fire('pointermove', x + 1, y + 6);
      const target = document.querySelector(destinationSelector).getBoundingClientRect();
      const ty = edge === 'top' ? target.top + 2 : target.bottom - 2;
      fire('pointermove', x + dx, ty);
      const label = document.querySelector('.org2-drag-indicator-label')?.textContent ?? null;
      if (release) fire('pointerup', x + dx, ty);
      return label;
      """,
      arguments: ["entrySelector": entry, "destinationSelector": destination, "edge": edge, "dx": dx, "release": release],
      in: nil,
      contentWorld: .page
    )
    return result as? String
  }

  private func snapshot(_ page: WKWebView, named name: String) async throws {
    guard let directory = ProcessInfo.processInfo.environment["CELORGA_OUTLINE_DRAG_SNAPSHOTS"] else { return }
    // Let hover and indicator transitions settle.
    try await Task.sleep(nanoseconds: 300_000_000)
    let image = try await page.takeSnapshot(configuration: nil)
    guard let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
  }

  func testDraggingAHeadingAboveAnEarlierSiblingProposesThatMove() async throws {
    let recorder = OutlineMoveRecorder()
    let (page, _) = try await renderedPage(recorder: recorder)
    _ = try await page.callAsyncJavaScript(
      """
      const summary = document.querySelector('details[data-org2-start-line="15"] > summary');
      summary.dispatchEvent(new PointerEvent('pointermove', { bubbles: true, clientX: 100, clientY: 10 }));
      return true;
      """,
      arguments: [:], in: nil, contentWorld: .page
    )
    try await snapshot(page, named: "1-hover")
    let label = try await drag(
      "details[data-org2-start-line=\"15\"]",
      to: "details[data-org2-start-line=\"3\"]",
      release: false,
      in: page
    )
    XCTAssertEqual(label, "")
    try await snapshot(page, named: "2-dragging-heading")
    _ = try await page.callAsyncJavaScript(
      "document.querySelector('.org2-drag-grip').dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerId: 7, clientX: 0, clientY: 0 })); return true;",
      arguments: [:], in: nil, contentWorld: .page
    )
    try await waitUntil { recorder.requests.count == 1 }
    XCTAssertEqual(recorder.requests.first, OrgOutlineMoveRequest(
      kind: .heading, startLine: 15, endLine: 18, targetLine: 3, level: 1, headingLines: [15]
    ))

    // The refused move puts the heading back where it was.
    try await waitUntil {
      (try? await page.callAsyncJavaScript(
        """
        const order = [...document.querySelectorAll('main > details.org2-headline')].map((el) => el.dataset.org2StartLine);
        return order.join(',') === '3,15,19,23' && !document.querySelector('.org2-drag-pending');
        """,
        arguments: [:], in: nil, contentWorld: .page
      )) as? Bool == true
    }
  }

  func testDraggingRightNestsAHeadingAndAnEndDropKeepsItsSubtree() async throws {
    let recorder = OutlineMoveRecorder()
    let (page, _) = try await renderedPage(recorder: recorder)
    let label = try await drag(
      "details[data-org2-start-line=\"23\"]",
      to: "details[data-org2-start-line=\"23\"]",
      dx: 30,
      release: false,
      in: page
    )
    XCTAssertEqual(label, "Inside “Reading list”")
    try await snapshot(page, named: "3-nesting-heading")
    _ = try await drag("details[data-org2-start-line=\"23\"]", to: "details[data-org2-start-line=\"23\"]", dx: 30, in: page)
    try await waitUntil { recorder.requests.count == 1 }
    XCTAssertEqual(recorder.requests.last, OrgOutlineMoveRequest(
      kind: .heading, startLine: 23, endLine: 23, targetLine: 23, level: 2, headingLines: [23]
    ))

    _ = try await drag(
      "details[data-org2-start-line=\"21\"]",
      to: "details[data-org2-start-line=\"23\"]",
      edge: "bottom",
      dx: -30,
      in: page
    )
    try await waitUntil { recorder.requests.count == 2 }
    let endMove = try XCTUnwrap(recorder.requests.last)
    XCTAssertEqual(endMove.headingLines, [21, 22])
    XCTAssertEqual(endMove.level, 1)
    let moved = try OrgOutlineMove.apply(endMove, to: OrgOutlineMoveTests.sample)
    XCTAssertTrue(moved.hasSuffix("* Archive\n* Book two\n** Notes on two\n"), moved)
  }

  func testDraggingListItemsReordersAndIndentsThem() async throws {
    let recorder = OutlineMoveRecorder()
    let (page, _) = try await renderedPage(recorder: recorder)
    let label = try await drag(
      "li[data-org2-start-line=\"9\"]",
      to: "li[data-org2-start-line=\"9\"]",
      dx: 30,
      release: false,
      in: page
    )
    XCTAssertEqual(label, "Inside “Draft outline”")
    try await snapshot(page, named: "4-nesting-list-item")
    _ = try await drag("li[data-org2-start-line=\"9\"]", to: "li[data-org2-start-line=\"9\"]", dx: 30, in: page)
    try await waitUntil { recorder.requests.count == 1 }
    let indent = try XCTUnwrap(recorder.requests.last)
    XCTAssertEqual(try lines(OrgOutlineMove.apply(indent, to: OrgOutlineMoveTests.sample))[8], "  - Get review")

    _ = try await drag("li[data-org2-start-line=\"10\"]", to: "li[data-org2-start-line=\"6\"]", in: page)
    try await waitUntil { recorder.requests.count == 2 }
    XCTAssertEqual(recorder.requests.last, OrgOutlineMoveRequest(
      kind: .listItem, startLine: 10, endLine: 10, targetLine: 6,
      referenceLine: 6, relation: .sibling, listStartLine: 6, listEndLine: 10
    ))

    _ = try await drag("li[data-org2-start-line=\"14\"]", to: "li[data-org2-start-line=\"12\"]", in: page)
    try await waitUntil { recorder.requests.count == 3 }
    let reordered = try OrgOutlineMove.apply(try XCTUnwrap(recorder.requests.last), to: OrgOutlineMoveTests.sample)
    XCTAssertEqual(Array(lines(reordered)[11...13]), ["1. Edit", "2. Script", "3. Record"])
  }

  func testNestedHeadingGripSitsLeftOfItsGuideLineOnAnOpaqueBackground() async throws {
    let recorder = OutlineMoveRecorder()
    let (page, _) = try await renderedPage(recorder: recorder)
    let result = try await page.callAsyncJavaScript(
      """
      return ['20', '22'].map((line) => {
        const details = document.querySelector(`details[data-org2-start-line="${line}"]`);
        const grip = details.querySelector(':scope > summary > .org2-drag-grip');
        const style = getComputedStyle(details);
        const guide = details.getBoundingClientRect().left;
        return {
          line,
          hasGuide: style.borderLeftStyle === 'solid',
          gap: guide - grip.getBoundingClientRect().right,
          background: getComputedStyle(grip).backgroundColor,
        };
      });
      """,
      arguments: [:], in: nil, contentWorld: .page
    ) as? [[String: Any]]
    let rows = try XCTUnwrap(result)
    XCTAssertEqual(rows.count, 2)
    for row in rows {
      let line = row["line"] as? String ?? "?"
      XCTAssertEqual(row["hasGuide"] as? Bool, true, "heading \(line) should draw a guide line")
      let gap = try XCTUnwrap(row["gap"] as? Double, "heading \(line)")
      XCTAssertGreaterThanOrEqual(gap, 2, "heading \(line)'s grip overlaps its guide line")
      let background = row["background"] as? String ?? ""
      XCTAssertTrue(background.hasPrefix("rgb("), "heading \(line)'s grip background is translucent: \(background)")
    }
  }

  func testSubtreeViewKeepsItsRootHeadingFixed() async throws {
    let recorder = OutlineMoveRecorder()
    let text = "* Reading list\n** Book one\n** Book two\n*** Notes on two"
    let (page, _) = try await renderedPage(text: text, startLine: 19, isSubtree: true, recorder: recorder)
    let rootHasGrip = try await page.callAsyncJavaScript(
      "return Boolean(document.querySelector('details[data-org2-start-line=\"19\"] > summary > .org2-drag-grip'));",
      arguments: [:], in: nil, contentWorld: .page
    ) as? Bool
    XCTAssertEqual(rootHasGrip, false)
    // Dragging far left still keeps the heading inside the root.
    _ = try await drag(
      "details[data-org2-start-line=\"21\"]",
      to: "details[data-org2-start-line=\"20\"]",
      dx: -120,
      in: page
    )
    try await waitUntil { recorder.requests.count == 1 }
    XCTAssertEqual(recorder.requests.last?.level, 2)
    XCTAssertEqual(recorder.requests.last?.targetLine, 20)
  }

  private func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private func waitUntil(
    timeout: TimeInterval = 5,
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
