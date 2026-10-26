import XCTest
@testable import Org2WorkspaceCore

final class WorkflowEventTriggerModelsTests: XCTestCase {
  private func workflows(_ json: String) throws -> [AgentWorkflowItem] {
    try JSONDecoder().decode(AgentWorkflowListPayload.self, from: Data(json.utf8)).workflows
  }

  private func workflowJSON(id: String, state: String, triggers: String) -> String {
    """
    {
      "id": "\(id)", "version": "1.0.0", "title": "Synthetic \(id)", "description": "",
      "state": "\(state)", "instructions": "Run.", "riskClass": "local-draft",
      "capabilities": [], "inputs": [], "triggers": \(triggers),
      "file": "/synthetic/workflows/\(id).org", "legacyLocation": false,
      "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:00.000Z"
    }
    """
  }

  func testEventSourcesRequireActiveEnabledTriggers() throws {
    let items = try workflows("""
    {"schema": "org2:workflow-list:v1", "workflows": [
      \(workflowJSON(id: "todo", state: "active", triggers: #"[{"id":"next","type":"todo-state","enabled":true,"states":["NEXT"],"coalesce":"5m"}]"#)),
      \(workflowJSON(id: "paused-pr", state: "paused", triggers: #"[{"id":"pr","type":"pull-request","enabled":true,"repo":"acme/widgets"}]"#)),
      \(workflowJSON(id: "disabled-pr", state: "active", triggers: #"[{"id":"pr","type":"pull-request","enabled":false,"repo":"acme/widgets"}]"#))
    ]}
    """)
    XCTAssertEqual(items.first?.triggers.first?.coalesce, "5m")
    XCTAssertEqual(items[1].triggers.first?.repo, "acme/widgets")
    let sources = AgentWorkflowEventSources.required(by: items)
    XCTAssertEqual(sources, AgentWorkflowEventSources(todoState: true, pullRequest: false))
    XCTAssertEqual(
      sources.union(AgentWorkflowEventSources(todoState: false, pullRequest: true)),
      AgentWorkflowEventSources(todoState: true, pullRequest: true)
    )
    XCTAssertEqual(AgentWorkflowEventSources.required(by: []), .none)
  }

  func testDueListDecodesEventTriggeredItemsAndSources() throws {
    let payload = try JSONDecoder().decode(AgentWorkflowDueListPayload.self, from: Data(#"""
    {
      "schema": "org2:automation-due-list:v1",
      "now": "2026-03-01T10:06:00Z",
      "due": [{
        "workflowId": "pr-watch", "title": "PR watch", "triggerId": "reviews",
        "triggerType": "pull-request", "coalesce": "5m",
        "scheduledFor": "2026-03-01T10:05:00.000Z", "signalIds": ["s1", "s2"]
      }],
      "skipped": [],
      "pending": [{"workflowId": "pr-watch", "triggerId": "reviews", "scheduledFor": "2026-03-01T10:12:00.000Z"}],
      "eventSources": {"todoState": false, "pullRequest": true},
      "failures": [],
      "hostRef": "desktop"
    }
    """#.utf8))
    let item = try XCTUnwrap(payload.due.first)
    XCTAssertEqual(item.triggerType, "pull-request")
    XCTAssertEqual(item.signalIds, ["s1", "s2"])
    XCTAssertNil(item.schedule)
    XCTAssertEqual(item.id, "pr-watch:reviews:2026-03-01T10:05:00.000Z")
    XCTAssertEqual(payload.eventSources, AgentWorkflowEventSources(todoState: false, pullRequest: true))
  }

  func testPollStatusExplainsMissingOrSignedOutGitHubCLI() throws {
    func decode(_ status: String) throws -> AgentWorkflowEventSourcePayload {
      try JSONDecoder().decode(AgentWorkflowEventSourcePayload.self, from: Data("""
      {"schema": "org2:workflow-poll:v1", "status": "\(status)", "message": "GitHub CLI (gh) is not authenticated. Run `gh auth login` to enable pull-request triggers.", "applied": true, "recorded": 0}
      """.utf8))
    }
    let signedOut = try decode("gh-unauthenticated")
    XCTAssertTrue(signedOut.needsAttention)
    XCTAssertEqual(signedOut.pullRequestStatusText, "Pull-request triggers: GitHub CLI (gh) is not authenticated. Run `gh auth login` to enable pull-request triggers.")
    XCTAssertTrue(try decode("gh-missing").needsAttention)
    XCTAssertNil(try decode("ok").pullRequestStatusText)
    XCTAssertNil(try decode("idle").pullRequestStatusText)
    XCTAssertNotNil(try decode("partial").pullRequestStatusText)
  }

  func testPullRequestPollingIntervalBacksOffWhenGitHubCLINeedsAttention() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertTrue(WorkspaceStore.shouldPollPullRequests(lastPollAt: nil, needsAttention: false, now: start))
    XCTAssertFalse(WorkspaceStore.shouldPollPullRequests(lastPollAt: start, needsAttention: false, now: start.addingTimeInterval(60)))
    XCTAssertTrue(WorkspaceStore.shouldPollPullRequests(lastPollAt: start, needsAttention: false, now: start.addingTimeInterval(WorkspaceStore.pullRequestPollIntervalSeconds)))
    XCTAssertFalse(WorkspaceStore.shouldPollPullRequests(lastPollAt: start, needsAttention: true, now: start.addingTimeInterval(300)))
    XCTAssertTrue(WorkspaceStore.shouldPollPullRequests(lastPollAt: start, needsAttention: true, now: start.addingTimeInterval(WorkspaceStore.pullRequestPollAttentionIntervalSeconds)))
  }
}
