import XCTest
@testable import Org2WorkspaceCore

final class GoalDriveTests: XCTestCase {
  func testDecodesGoalDriveAndStatus() throws {
    let payload = try JSONDecoder().decode(AgentGoalListPayload.self, from: Data(#"""
    {
      "schema": "org2:goal-list:v1",
      "goals": [{
        "schema": "org2:goal:v1",
        "id": "launch-newsletter",
        "title": "Launch the newsletter",
        "description": "",
        "status": "active",
        "measures": [],
        "drive": {
          "state": "stalled",
          "workflowRef": "goal-drive-launch-newsletter",
          "stallAfter": 3,
          "dailyCostLimitUsd": 5,
          "permissions": ["Edit drafts"],
          "passesWithoutProgress": 3,
          "stalledReason": "3 consecutive passes left the plan unchanged",
          "startedAt": "2030-01-01T00:00:00.000Z",
          "updatedAt": "2030-01-01T00:00:00.000Z"
        },
        "file": "/tmp/corpus/goals/launch-newsletter.org",
        "createdAt": "2030-01-01T00:00:00.000Z",
        "updatedAt": "2030-01-01T00:00:00.000Z"
      }, {
        "schema": "org2:goal:v1",
        "id": "undriven",
        "title": "Undriven",
        "description": "",
        "status": "active",
        "measures": [],
        "file": "/tmp/corpus/goals/undriven.org",
        "createdAt": "2030-01-01T00:00:00.000Z",
        "updatedAt": "2030-01-01T00:00:00.000Z"
      }]
    }
    """#.utf8))
    let driven = try XCTUnwrap(payload.goals.first)
    XCTAssertEqual(driven.drive?.isStalled, true)
    XCTAssertEqual(driven.drive?.dailyCostLimitUsd, 5)
    XCTAssertFalse(driven.canStartDrive)
    XCTAssertNil(payload.goals[1].drive)
    XCTAssertTrue(payload.goals[1].canStartDrive)

    let status = try JSONDecoder().decode(AgentGoalDriveStatus.self, from: Data(#"""
    {
      "schema": "org2:goal-drive-status:v1",
      "goalId": "launch-newsletter",
      "title": "Launch the newsletter",
      "goalStatus": "active",
      "file": "/tmp/corpus/goals/launch-newsletter.org",
      "drive": null,
      "plan": {"present": true, "items": [], "open": {"agent": 0, "human": 1, "external": 0}, "done": 2,
               "checkboxes": {"checked": 0, "total": 0}, "fingerprint": "abc", "issues": []},
      "spend": {"windowHours": 24, "passes": 2, "costUsd": 0.5, "tokens": 900},
      "uncheckpointedPasses": 0,
      "mode": "waiting",
      "eligible": false,
      "reason": "waiting on 1 human and 0 external plan item",
      "next": [],
      "needsYou": [{"title": "Approve the sender", "state": "TODO", "actor": "human", "open": true, "line": 30}]
    }
    """#.utf8))
    XCTAssertEqual(status.modeLabel, "Waiting on you")
    XCTAssertTrue(status.needsAttention)
    XCTAssertEqual(status.needsYou.first?.title, "Approve the sender")
    XCTAssertEqual(status.plan.open["human"], 1)
  }

  func testDriveOptionsReplacePermissionsAndOmitEmptyChoices() {
    let options = AgentGoalDriveOptions(
      schedule: "every 30m",
      stallAfter: 0,
      dailyCostLimitUsd: 2.5,
      permissions: ["  Open pull requests  ", "", "Edit drafts"],
      agentRef: "",
      destinationID: "codex"
    )
    XCTAssertEqual(options.arguments, [
      "--schedule", "every 30m", "--stall-after", "1", "--daily-cost-limit", "2.5",
      "--clear-permits", "--permit", "Open pull requests", "--permit", "Edit drafts",
      "--destination-ref", "codex",
    ])
    XCTAssertFalse(AgentGoalDriveOptions().arguments.contains("--daily-cost-limit"))
  }

  @MainActor
  func testStoreStartsPausesAndStopsAGoalDrive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("celorga-goal-drive-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("goals"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    _ = try await cli.run(["goal", "create", "launch-newsletter", "--title", "Launch the newsletter", "--apply", "--dir", root.path])
    let store = try WorkspaceStore(cli: cli)
    store.setCorpusRoot(root, persistsDefault: false)
    store.runsAndReviewPage = .goals
    await store.refreshAgentGoals()
    let goal = try XCTUnwrap(store.agentGoals.first, store.errorText ?? "no goals")
    XCTAssertTrue(goal.canStartDrive)

    let started = await store.startAgentGoalDrive(goal, options: AgentGoalDriveOptions(
      schedule: "every 1h", stallAfter: 2, dailyCostLimitUsd: 3, permissions: ["Edit drafts"], destinationID: "codex"
    ))
    XCTAssertTrue(started, store.errorText ?? "")
    let driven = try XCTUnwrap(store.agentGoals.first)
    XCTAssertEqual(driven.drive?.state, "driving")
    XCTAssertEqual(driven.drive?.permissions, ["Edit drafts"])
    XCTAssertEqual(store.agentGoalDriveStatuses[goal.id]?.mode, "plan")
    let workflow = try String(contentsOf: root.appendingPathComponent("workflows/goal-drive-launch-newsletter.org"), encoding: .utf8)
    XCTAssertTrue(workflow.contains("\"schedule\": \"every 1h\""))
    XCTAssertTrue(workflow.contains("\"destinationRef\": \"codex\""))

    await store.controlAgentGoalDrive(driven, .pause)
    XCTAssertEqual(store.agentGoals.first?.drive?.state, "paused", store.errorText ?? "")
    XCTAssertEqual(store.agentGoalDriveStatuses[goal.id]?.mode, "paused")

    await store.controlAgentGoalDrive(try XCTUnwrap(store.agentGoals.first), .stop)
    XCTAssertNil(store.agentGoals.first?.drive, store.errorText ?? "")
    XCTAssertNil(store.agentGoalDriveStatuses[goal.id])
  }
}
