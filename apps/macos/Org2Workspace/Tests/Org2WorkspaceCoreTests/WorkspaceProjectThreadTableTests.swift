import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceProjectThreadTableTests: XCTestCase {
  private let utc = TimeZone(identifier: "UTC")!
  private let older = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  private let newer = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  private let settled = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  private let unknown = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

  private func threads() -> [UUID: AIChatThread] {
    let day: TimeInterval = 86_400
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    return [
      older: AIChatThread(id: older, title: "Plan the launch", createdAt: base, updatedAt: base + day,
        runtime: .codex, sessionKey: "a", storedMessageCount: 4, unreadMessageCount: 2),
      newer: AIChatThread(id: newer, title: "  ", createdAt: base + day, updatedAt: base + 3 * day,
        runtime: .claude, sessionKey: "b", storedMessageCount: 12),
      settled: AIChatThread(id: settled, title: "Old idea", createdAt: base, updatedAt: base + 2 * day,
        runtime: .codex, sessionKey: "c", storedMessageCount: 1, settledAt: base + 2 * day),
    ]
  }

  private func rows() -> [WorkspaceProjectThreadTable.Row] {
    let known = threads()
    return WorkspaceProjectThreadTable.rows(
      threadIDs: [unknown, older, settled, newer, older].map { $0.uuidString.lowercased() } + ["not-a-thread"],
      thread: { known[$0] },
      isRunning: { $0 == self.newer },
      agentTitle: { $0.runtime.title },
      timeZone: utc
    )
  }

  func testRowsListMembersByRecentActivityWithUnknownChatsLast() {
    let rows = rows()
    XCTAssertEqual(rows.map(\.id), [newer, settled, older, unknown].map { $0.uuidString.lowercased() })
    XCTAssertEqual(rows.map(\.status), ["Working", "Settled", "Active · 2 unread", "Missing"])
    XCTAssertEqual(rows.map(\.statusKind), ["working", "settled", "active", "missing"])
    XCTAssertEqual(rows[0].title, "Untitled chat")
    XCTAssertEqual(rows[0].agent, "Claude Code")
    XCTAssertEqual(rows[0].messages, 12)
    XCTAssertEqual(rows[2].updated, "2026-09-22 14:13")
    XCTAssertEqual(rows[2].created, "2026-09-21 14:13")
    XCTAssertNil(rows[3].messages)
  }

  func testOnlyTheProjectThreadsDynamicBlockRequestsTheTable() {
    XCTAssertTrue(WorkspaceProjectThreadTable.requestsTable("#+TITLE: X\n#+begin: project-threads\n#+end:\n"))
    XCTAssertTrue(WorkspaceProjectThreadTable.requestsTable("#+BEGIN: project-threads :scope all\n#+END:\n"))
    XCTAssertFalse(WorkspaceProjectThreadTable.requestsTable("#+begin: clocktable\n#+end:\n"))
    XCTAssertFalse(WorkspaceProjectThreadTable.requestsTable("Use #+begin: project-threads in a note.\n"))
  }

  func testReaderReplacesTheStaticListAndKeepsTheFilterAcrossUpdates() async throws {
    let ids = [older, newer, settled, unknown].map { $0.uuidString.lowercased() }
    let note = """
    :PROPERTIES:
    :ID: demo-project
    :END:
    #+TITLE: Demo
    #+ORG2_KIND: project
    #+PROJECT_THREADS: \(ids.joined(separator: " "))
    #+begin: project-threads
    #+end:

    * Decisions
    """
    let view = try await page(for: note)
    let staticLinks = try await evaluate(
      "Array.from(document.querySelectorAll('[data-celorga-project-threads] tbody a')).map((a) => a.getAttribute('href'))",
      in: view
    ) as? [String]
    XCTAssertEqual(staticLinks, ids.map { "org2-workspace://open-thread?id=\($0)" })

    _ = try await evaluate(try XCTUnwrap(OrgHTMLProjectThreadsScript.update(rows())), in: view)
    let headers = try await evaluate(
      "Array.from(document.querySelectorAll('[data-celorga-project-threads] thead th')).map((th) => th.firstChild.textContent)",
      in: view
    ) as? [String]
    XCTAssertEqual(headers, ["Chat", "Status", "Agent", "Messages", "Updated", "Created"])
    let titles = try await evaluate(
      "Array.from(document.querySelectorAll('[data-celorga-project-threads] tbody tr td:first-child')).map((td) => td.textContent)",
      in: view
    ) as? [String]
    XCTAssertEqual(titles, ["Untitled chat", "Old idea", "Plan the launch", unknown.uuidString.lowercased()])
    let saveButtons = try await evaluate(
      "document.querySelectorAll('[data-celorga-project-threads] [data-org2-table-save], [data-celorga-project-threads] [data-org2-table-formula]').length",
      in: view
    ) as? Int
    XCTAssertEqual(saveButtons, 0, "a live table has no source rows to save")

    _ = try await evaluate("""
      const filter = document.querySelector('[data-celorga-project-threads] .org2-table-filter');
      filter.value = 'codex';
      filter.dispatchEvent(new Event('input'));
      document.querySelectorAll('[data-celorga-project-threads] .org2-table-sort-button')[0].click();
      true;
      """, in: view)
    _ = try await evaluate(try XCTUnwrap(OrgHTMLProjectThreadsScript.update(rows())), in: view)
    let filtered = try await evaluate(
      "Array.from(document.querySelectorAll('[data-celorga-project-threads] tbody tr td:first-child')).map((td) => td.textContent)",
      in: view
    ) as? [String]
    XCTAssertEqual(filtered, ["Old idea", "Plan the launch"], "the update keeps the filter and the sort")
    let count = try await evaluate(
      "document.querySelector('.celorga-project-threads-count').textContent",
      in: view
    ) as? String
    XCTAssertEqual(count, "4")
  }

  private func page(for text: String) async throws -> WKWebView {
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let html = try await cli.renderAppHTML(text, sourcePath: "/tmp/project.org")
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
    view.loadHTMLString(html, baseURL: nil)
    for _ in 0..<250 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" {
        return view
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Rendered page did not load")
    return view
  }

  private func evaluate(_ script: String, in view: WKWebView) async throws -> Any? {
    try await view.evaluateJavaScript(script)
  }
}
