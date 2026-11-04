import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// The automation tick starts a TODO that opted in with
/// `:AGENT_START: scheduled` once, through the shared runtime.
@MainActor
final class ScheduledTodoStartTests: XCTestCase {
  func testDueAgentAutomationsStartAScheduledTodoOnce() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-scheduled-todo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "{}\n".write(to: root.appendingPathComponent("celorga.json"), atomically: true, encoding: .utf8)
    let tasks = root.appendingPathComponent("tasks.org")
    try """
    * TODO Draft the synthetic launch checklist
    SCHEDULED: <2098-01-06 Mon 09:00>
    :PROPERTIES:
    :ID: 7e2b9c40-1111-4c2d-9e3f-000000000001
    :AGENT_REF: research-assistant
    :AGENT_START: scheduled
    :END:
    Collect the open items.

    * TODO Missing a time
    SCHEDULED: <2098-01-06 Mon>
    :PROPERTIES:
    :ID: 7e2b9c40-2222-4c2d-9e3f-000000000002
    :AGENT_REF: research-assistant
    :AGENT_START: scheduled
    :END:
    """.write(to: tasks, atomically: true, encoding: .utf8)

    let suiteName = "ScheduledTodoStartTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let store = WorkspaceStore(
      cli: cli,
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chats.json"),
      claudeSendHandlerForTesting: { messages, _, _ in
        let prompt = messages.last(where: { $0.role == .user })?.content ?? ""
        XCTAssertTrue(prompt.contains("Start work on this TODO from my corpus."))
        XCTAssertTrue(prompt.contains("Task: Draft the synthetic launch checklist"))
        return ClaudeCodeTurnResult(sessionID: "scheduled-session", reply: "Started on the checklist.")
      },
      legacyDefaultsDomains: []
    )
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(root, persistsDefault: false)
    var claude = try XCTUnwrap(AIChatDestinationConfiguration.defaults.first {
      $0.id == AIChatDestinationConfiguration.localClaudeID
    })
    claude.isEnabled = true
    store.updateAIChatDestination(claude)
    store.defaultRunDestinationID = claude.id
    // Activation also checks at the real current time; the TODO is scheduled
    // far enough ahead that only the injected clock below finds it due.
    store.setAutomationSchedulerActive(true, checkIntervalNanoseconds: 3_600_000_000_000)
    defer { store.setAutomationSchedulerActive(false) }

    let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2099-01-06T12:00:00Z"))
    await store.checkDueAgentAutomations(now: now)
    XCTAssertEqual(store.automationSchedulerStatusText, "Started 1 scheduled TODO")

    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline,
          !store.agentRuns.contains(where: { $0.title == "Work: Draft the synthetic launch checklist" }) {
      await store.refreshAgentRuns()
      try await Task.sleep(for: .milliseconds(25))
    }
    let started = store.agentRuns.filter { $0.title == "Work: Draft the synthetic launch checklist" }
    XCTAssertEqual(started.count, 1)
    let run = try XCTUnwrap(started.first)
    XCTAssertEqual(run.agentRef, "research-assistant")
    XCTAssertEqual(run.attempt?.triggerType, "scheduled-todo-start")
    let text = try String(contentsOf: tasks, encoding: .utf8)
    XCTAssertTrue(text.contains("* IN_PROGRESS Draft the synthetic launch checklist"))
    XCTAssertTrue(text.contains(":ORG2_RUN_ID: \(run.id)"))
    let thread = try XCTUnwrap(store.aiChatThreads.first {
      $0.resource?.key == "id:7e2b9c40-1111-4c2d-9e3f-000000000001"
    })
    XCTAssertEqual(thread.destinationID, claude.id)

    await store.checkDueAgentAutomations(now: now.addingTimeInterval(60))
    XCTAssertEqual(
      store.agentRuns.filter { $0.title == "Work: Draft the synthetic launch checklist" }.count,
      1,
      "a later tick must not start the same occurrence again"
    )
    XCTAssertEqual(store.aiChatThreads.filter { $0.resource?.key == thread.resource?.key }.count, 1)
  }
}
