import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class OrgHTMLRichCopyTests: XCTestCase {
  private let tableHTML = """
    <html><body>
    <p id="intro">Intro prose</p>
    <table>
      <thead><tr><th>Name</th><th>Role</th><th>City</th></tr></thead>
      <tbody>
        <tr><td id="ada">Ada Lovelace</td><td id="analyst">Analyst</td><td>London</td></tr>
        <tr><td>Grace Hopper</td><td id="admiral">Admiral</td><td id="arlington">Arlington</td></tr>
        <tr hidden><td>Hidden</td><td>Row</td><td>Here</td></tr>
      </tbody>
    </table>
    <p id="outro">Closing prose</p>
    </body></html>
    """

  private func loadedView() async throws -> WKWebView {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    view.loadHTMLString(tableHTML, baseURL: nil)
    for _ in 0..<100 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    try await view.evaluateJavaScript(OrgHTMLRichCopy.installationScript + "; null;")
    return view
  }

  private func payload(_ view: WKWebView, select: String) async throws -> [String: String] {
    let result = try await view.evaluateJavaScript("""
      (() => {
        const range = document.createRange();
        \(select)
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        return window.__org2RichCopyPayload();
      })()
      """)
    return try XCTUnwrap(result as? [String: String])
  }

  func testCopyingInsideOneCellCopiesOnlyThatCellText() async throws {
    let view = try await loadedView()

    // Part of a cell's text.
    let partial = try await payload(view, select: """
      const text = document.getElementById('ada').firstChild;
      range.setStart(text, 0); range.setEnd(text, 3);
      """)
    XCTAssertEqual(partial["text"], "Ada")
    XCTAssertFalse(partial["html"]?.contains("<table") ?? true)

    // A triple-click selection ends at the start of the next cell.
    let tripleClick = try await payload(view, select: """
      range.setStart(document.getElementById('ada').firstChild, 0);
      range.setEnd(document.getElementById('analyst'), 0);
      """)
    XCTAssertEqual(tripleClick["text"], "Ada Lovelace")
    XCTAssertFalse(tripleClick["html"]?.contains("<table") ?? true)
  }

  func testCopyingSeveralCellsCopiesOnlyTheirRowsAndColumns() async throws {
    let view = try await loadedView()

    // Two cells in one row: no header, other rows, or other columns.
    let row = try await payload(view, select: """
      range.setStart(document.getElementById('analyst').firstChild, 0);
      range.setEnd(document.getElementById('analyst').nextElementSibling.firstChild, 6);
      """)
    XCTAssertEqual(row["text"], "Analyst\tLondon")
    XCTAssertTrue(row["html"]?.contains("<table") ?? false)
    XCTAssertFalse(row["html"]?.contains("Ada Lovelace") ?? true)
    XCTAssertFalse(row["html"]?.contains("Role") ?? true)

    // A drag across rows spans the rows it touches; hidden rows stay out.
    let rows = try await payload(view, select: """
      range.setStart(document.getElementById('ada').firstChild, 0);
      range.setEnd(document.getElementById('arlington').firstChild, 9);
      """)
    XCTAssertEqual(rows["text"], "Ada Lovelace\tAnalyst\tLondon\nGrace Hopper\tAdmiral\tArlington")
    XCTAssertFalse(rows["html"]?.contains("Hidden") ?? true)
    XCTAssertFalse(rows["html"]?.contains("Name") ?? true)
  }

  func testSelectionFromOneCellIntoProseCopiesNormally() async throws {
    let view = try await loadedView()

    let mixed = try await payload(view, select: """
      range.setStart(document.getElementById('arlington').firstChild, 0);
      range.setEnd(document.getElementById('outro').firstChild, 7);
      """)
    XCTAssertTrue(mixed["text"]?.contains("Arlington") ?? false)
    XCTAssertTrue(mixed["text"]?.contains("Closing") ?? false)
  }
}
