import AppKit
import WebKit
import XCTest
@testable import Org2WorkspaceCore

private actor EntryEffectGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }
}

private struct EntryEffectTestFailure: Error {}

@MainActor
final class OrgHTMLEntryEffectsTests: XCTestCase {
  private let sample = """
  #+TITLE: Effects

  * TODO First task :work:
  body
  * TODO [#B] Second task
  SCHEDULED: <2026-11-03 Tue>
  * DONE Finished task
  CLOSED: <2026-11-01 Sun 10:00>
  * Plain heading
  """

  func testTimestampsMatchTheCLIFormats() {
    XCTAssertEqual(OrgHTMLEntryEffect.planningTimestamp(date: "2026-11-09"), "<2026-11-09 Mon>")
    XCTAssertEqual(OrgHTMLEntryEffect.planningTimestamp(date: "not-a-date"), "<not-a-date>")
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone.current
    components.year = 2026
    components.month = 11
    components.day = 3
    components.hour = 13
    components.minute = 36
    let date = try! XCTUnwrap(components.date)
    XCTAssertEqual(OrgHTMLEntryEffect.closedTimestamp(date), "<2026-11-03 Tue 13:36>")
    XCTAssertEqual(
      OrgHTMLEntryEffect.todoChange(for: .done, now: date),
      .todo(keyword: "DONE", state: .done, closedTimestamp: "<2026-11-03 Tue 13:36>")
    )
    XCTAssertEqual(
      OrgHTMLEntryEffect.todoChange(for: .inProgress, now: date),
      .todo(keyword: "IN_PROGRESS", state: .open, closedTimestamp: "<2026-11-03 Tue 13:36>")
    )
  }

  func testRenderedTodoActionShowsTheChangeBeforeTheWriteFinishes() async throws {
    let (store, note) = try makeStore()
    defer { try? FileManager.default.removeItem(at: note.deletingLastPathComponent()) }
    let gate = EntryEffectGate()
    store.todoStatusMutationForTesting = { status, _, _ in
      await gate.wait()
      return status.label
    }

    store.performRenderedEntryAction(.todo(.done), at: 3)
    try await waitFor { !store.renderedEntryEffects.isEmpty }

    let provisional = try XCTUnwrap(store.renderedEntryEffects.last)
    XCTAssertEqual(provisional.file, note.path)
    XCTAssertEqual(provisional.line, 3)
    guard case .todo(let keyword, let state, _) = provisional.change else {
      return XCTFail("Expected a provisional TODO change, got \(provisional.change)")
    }
    XCTAssertEqual(keyword, "DONE")
    XCTAssertEqual(state, .done)

    await gate.open()
    try await waitFor { store.renderedEntryEffects.last?.change == .settle }
    XCTAssertEqual(store.renderedEntryEffects.last?.line, 3)
    XCTAssertGreaterThan(store.renderedEntryEffects.last?.id ?? 0, provisional.id)
  }

  func testFailedRenderedTodoActionRevertsTheProvisionalChange() async throws {
    let (store, note) = try makeStore()
    defer { try? FileManager.default.removeItem(at: note.deletingLastPathComponent()) }
    store.todoStatusMutationForTesting = { _, _, _ in throw EntryEffectTestFailure() }

    store.performRenderedEntryAction(.todo(.canceled), at: 3)
    try await waitFor { store.renderedEntryEffects.last?.change == .revert }

    XCTAssertEqual(store.renderedEntryEffects.count, 2)
    XCTAssertEqual(store.statusText, "TODO update failed")
  }

  func testRenderedPriorityAndPlanningActionsEmitProvisionalChanges() async throws {
    let (store, note) = try makeStore()
    defer { try? FileManager.default.removeItem(at: note.deletingLastPathComponent()) }

    store.performRenderedEntryAction(.priority("A"), at: 3)
    try await waitFor { store.renderedEntryEffects.contains { $0.change == .priority("A") } }
    try await waitFor { store.renderedEntryEffects.last?.change == .settle }
    XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("* TODO [#A] First task"))

    store.performRenderedEntryAction(.schedule(.tomorrow), at: 3)
    try await waitFor {
      store.renderedEntryEffects.contains {
        if case .planning(.scheduled, let timestamp) = $0.change { return timestamp.hasPrefix("<") }
        return false
      }
    }
  }

  func testEffectHistoryStaysBounded() throws {
    let (store, note) = try makeStore()
    defer { try? FileManager.default.removeItem(at: note.deletingLastPathComponent()) }
    for line in 1...40 {
      store.emitRenderedEntryEffect(.settle, file: note.path, line: line)
    }
    XCTAssertEqual(store.renderedEntryEffects.count, WorkspaceStore.renderedEntryEffectHistoryLimit)
    XCTAssertEqual(store.renderedEntryEffects.last?.id, 40)
    XCTAssertEqual(store.renderedEntryEffects.first?.line, 25)
  }

  // MARK: Rendered page

  func testProvisionalDoneMatchesTheAuthoritativeRender() async throws {
    let view = try await page(for: sample)
    try await apply(.todo(keyword: "DONE", state: .done, closedTimestamp: "<2026-11-03 Tue 13:36>"), line: 3, in: view)
    try await settleAnimations()

    let rendered = try await headingHTML(line: 3, in: view)
    let expected = try await authoritativeHeadingHTML(
      for: sample.replacingOccurrences(
        of: "* TODO First task :work:\n",
        with: "* DONE First task :work:\nCLOSED: <2026-11-03 Tue 13:36>\n"
      ),
      line: 3
    )
    XCTAssertEqual(rendered, expected)
    let value1 = try await planning(line: 3, in: view)
    XCTAssertEqual(value1, ["CLOSED <2026-11-03 Tue 13:36>"])
  }

  func testProvisionalReopenAndCancelUpdateKeywordStateAndClosedLine() async throws {
    let view = try await page(for: sample)
    try await apply(.todo(keyword: "TODO", state: .open, closedTimestamp: "<2026-11-03 Tue 13:36>"), line: 7, in: view)
    try await settleAnimations()
    let value2 = try await headingHTML(line: 7, in: view)
    XCTAssertEqual(value2, "<h1><span class=\"org2-todo todo-todo\">TODO</span> Finished task</h1>")
    let value3 = try await planning(line: 7, in: view)
    XCTAssertEqual(value3, [])

    try await apply(.todo(keyword: "CANCELED", state: .canceled, closedTimestamp: "<2026-11-03 Tue 13:36>"), line: 5, in: view)
    try await settleAnimations()
    let value4 = try await headingHTML(line: 5, in: view)
    XCTAssertEqual(value4, "<h1 class=\"org2-headline-canceled\"><span class=\"org2-todo todo-canceled\">CANCELED</span> <span class=\"org2-priority\">[#B]</span> Second task</h1>")
    let value5 = try await planning(line: 5, in: view)
    XCTAssertEqual(value5, ["SCHEDULED <2026-11-03 Tue>", "CLOSED <2026-11-03 Tue 13:36>"])
  }

  func testProvisionalToggleFollowsTheBuiltInCycleAndMarksUnknownKeywordsPending() async throws {
    let view = try await page(for: sample)
    let closed = "<2026-11-03 Tue 13:36>"
    try await apply(.toggleTodo(closedTimestamp: closed), line: 3, in: view)
    try await settleAnimations()
    let value6 = try await keyword(line: 3, in: view)
    XCTAssertEqual(value6, "IN_PROGRESS")
    try await apply(.toggleTodo(closedTimestamp: closed), line: 3, in: view)
    try await settleAnimations()
    let value7 = try await keyword(line: 3, in: view)
    XCTAssertEqual(value7, "DONE")
    try await apply(.toggleTodo(closedTimestamp: closed), line: 3, in: view)
    try await settleAnimations()
    let value8 = try await keyword(line: 3, in: view)
    XCTAssertEqual(value8, "TODO")

    try await apply(.toggleTodo(closedTimestamp: closed), line: 9, in: view)
    let value9 = try await evaluate(entry(9) + ".classList.contains('org2-effect-pending')", in: view) as? Bool
    XCTAssertEqual(value9, true)
    try await apply(.settle, line: 9, in: view)
    let value10 = try await evaluate(entry(9) + ".classList.contains('org2-effect-pending')", in: view) as? Bool
    XCTAssertEqual(value10, false)
  }

  func testProvisionalPriorityMatchesTheAuthoritativeRender() async throws {
    let view = try await page(for: sample)
    try await apply(.priority("A"), line: 3, in: view)
    try await settleAnimations()
    let value11 = try await headingHTML(line: 3, in: view)
    let value12 = try await authoritativeHeadingHTML(
        for: sample.replacingOccurrences(of: "* TODO First task", with: "* TODO [#A] First task"),
        line: 3
      )
    XCTAssertEqual(value11, value12)

    try await apply(.priority(nil), line: 5, in: view)
    try await settleAnimations()
    let value13 = try await headingHTML(line: 5, in: view)
    let value14 = try await authoritativeHeadingHTML(
        for: sample.replacingOccurrences(of: "* TODO [#B] Second task", with: "* TODO Second task"),
        line: 5
      )
    XCTAssertEqual(value13, value14)

    try await apply(.priority("C"), line: 9, in: view)
    try await settleAnimations()
    let value15 = try await headingHTML(line: 9, in: view)
    let value16 = try await authoritativeHeadingHTML(
        for: sample.replacingOccurrences(of: "* Plain heading", with: "* [#C] Plain heading"),
        line: 9
      )
    XCTAssertEqual(value15, value16)
  }

  func testProvisionalPlanningReplacesOrAddsTheLineAndArchiveHidesTheEntry() async throws {
    let view = try await page(for: sample)
    try await apply(.planning(kind: .scheduled, timestamp: "<2026-11-09 Mon>"), line: 5, in: view)
    try await apply(.planning(kind: .deadline, timestamp: "<2026-11-10 Tue>"), line: 9, in: view)
    try await settleAnimations()
    let value17 = try await planning(line: 5, in: view)
    XCTAssertEqual(value17, ["SCHEDULED <2026-11-09 Mon>"])
    let value18 = try await planning(line: 9, in: view)
    XCTAssertEqual(value18, ["DEADLINE <2026-11-10 Tue>"])

    try await apply(.remove, line: 7, in: view)
    try await settleAnimations()
    let value19 = try await evaluate(entry(7) + ".style.display", in: view) as? String
    XCTAssertEqual(value19, "none")
  }

  // MARK: Helpers

  private func makeStore() throws -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-entry-effects-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("effects.org")
    try sample.write(to: note, atomically: true, encoding: .utf8)
    let source = EntrySource(
      file: note.path,
      startLine: 1,
      endLineExclusive: 10,
      text: sample,
      isSubtree: false
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedEntrySource = source
    store.selectedRenderedBlocks = OrgEntryRenderer.parseEditable(sample, baseLine: 1)
    return (store, note)
  }

  private func waitFor(
    timeout: TimeInterval = 20,
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { return XCTFail("Timed out waiting for condition") }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func render(_ text: String) async throws -> String {
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    return try await cli.renderAppHTML(text, sourcePath: "/tmp/effects.org")
  }

  private func page(for text: String) async throws -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 600), configuration: configuration)
    view.loadHTMLString(try await render(text), baseURL: nil)
    for _ in 0..<250 {
      if !view.isLoading, (try? await view.evaluateJavaScript("document.readyState")) as? String == "complete" {
        return view
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Rendered page did not load")
    return view
  }

  private func apply(_ change: OrgHTMLEntryEffect.Change, line: Int, in view: WKWebView) async throws {
    let effect = OrgHTMLEntryEffect(id: 1, file: "/tmp/effects.org", line: line, change: change)
    let script = try XCTUnwrap(OrgHTMLEntryEffectScript.invocation(for: effect))
    _ = try await view.evaluateJavaScript(script + "\ntrue;")
  }

  private func settleAnimations() async throws {
    try await Task.sleep(nanoseconds: UInt64((OrgHTMLEntryEffectScript.animationDuration + 0.2) * 1_000_000_000))
  }

  private func entry(_ line: Int) -> String {
    "document.querySelector('details.org2-headline[data-org2-start-line=\"\(line)\"]')"
  }

  private func evaluate(_ script: String, in view: WKWebView) async throws -> Any? {
    try await view.evaluateJavaScript(script)
  }

  private func headingHTML(line: Int, in view: WKWebView) async throws -> String {
    let value = try await evaluate(entry(line) + ".querySelector(':scope > summary > h1').outerHTML", in: view) as? String
    return try XCTUnwrap(value)
  }

  private func keyword(line: Int, in view: WKWebView) async throws -> String? {
    try await evaluate(entry(line) + ".querySelector(':scope > summary > h1 > .org2-todo')?.textContent", in: view) as? String
  }

  private func planning(line: Int, in view: WKWebView) async throws -> [String] {
    let script = "Array.from(" + entry(line)
      + ".querySelectorAll(':scope > .org2-headline-body > p.org2-planning')).map((p) => p.textContent)"
    let value = try await evaluate(script, in: view) as? [String]
    return try XCTUnwrap(value)
  }

  private func authoritativeHeadingHTML(for text: String, line: Int) async throws -> String {
    let view = try await page(for: text)
    return try await headingHTML(line: line, in: view)
  }
}
