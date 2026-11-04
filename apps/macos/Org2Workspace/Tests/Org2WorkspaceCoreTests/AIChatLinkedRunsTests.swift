import XCTest
@testable import Org2WorkspaceCore

final class AIChatLinkedRunsTests: XCTestCase {
  private let now = ISO8601DateFormatter().date(from: "2026-07-14T12:00:00Z")!
  private let threadID = UUID(uuidString: "6F0C8E7A-1B2C-4D3E-8F90-0A1B2C3D4E5F")!
  private let otherThreadID = UUID(uuidString: "0B1C2D3E-4F50-4617-8293-A4B5C6D7E8F9")!

  func testShowsActiveAndWaitingRunsAndCountsOnlyRecentlyFinishedOnes() throws {
    let runs = try [
      makeRun(id: "running", status: "running", updatedAt: "2026-07-14T11:00:00.000Z"),
      makeRun(id: "queued", status: "queued", updatedAt: "2026-07-14T11:30:00.000Z"),
      makeRun(id: "blocked", status: "blocked", updatedAt: "2026-07-01T00:00:00.000Z"),
      makeRun(id: "waiting", status: "waiting-approval", updatedAt: "2026-07-13T00:00:00.000Z"),
      makeRun(id: "failed-recent", status: "failed", updatedAt: "2026-07-14T08:00:00.000Z"),
      makeRun(id: "failed-old", status: "failed", updatedAt: "2026-07-10T08:00:00.000Z"),
      makeRun(
        id: "done-recent",
        status: "completed",
        updatedAt: "2026-07-14T09:00:00.000Z",
        completedAt: "2026-07-14T09:00:00.000Z"
      ),
      makeRun(
        id: "done-old",
        status: "completed",
        updatedAt: "2026-07-12T09:00:00.000Z",
        completedAt: "2026-07-12T09:00:00.000Z"
      ),
      makeRun(id: "canceled-recent", status: "canceled", updatedAt: "2026-07-14T10:00:00.000Z"),
    ]

    let summary = AIChatLinkedRunsSummary.make(runs: runs, queueItems: [], now: now)

    // Runs that need the user come first, then active ones; newest first in each.
    XCTAssertEqual(summary.runs.map(\.id), ["failed-recent", "waiting", "blocked", "queued", "running"])
    XCTAssertEqual(summary.recentlyFinished.map(\.id), ["canceled-recent", "done-recent"])
    XCTAssertEqual(summary.runs.first?.status.text, "Failed")
    XCTAssertEqual(summary.runs.last?.status.text, "Running")
    XCTAssertFalse(summary.isEmpty)
  }

  func testNothingToShowWhenOnlyOldFinishedRunsAreLinked() throws {
    let runs = try [
      makeRun(id: "done-old", status: "completed", updatedAt: "2026-06-01T00:00:00.000Z"),
      makeRun(id: "failed-old", status: "failed", updatedAt: "2026-06-01T00:00:00.000Z"),
    ]

    XCTAssertTrue(AIChatLinkedRunsSummary.make(runs: runs, queueItems: [], now: now).isEmpty)
    XCTAssertTrue(AIChatLinkedRunsSummary.make(runs: [], queueItems: [], now: now).isEmpty)
  }

  func testPendingApprovalsUseTheirReviewQueueItems() throws {
    let waiting = try makeRun(
      id: "needs-approval",
      status: "waiting-approval",
      approvals: [("approval-1", "pending", "fp-1"), ("approval-2", "pending", "fp-2"), ("approval-0", "approved", "fp-0")],
      updatedAt: "2026-07-01T00:00:00.000Z"
    )
    let running = try makeRun(id: "running", status: "running", updatedAt: "2026-07-14T11:00:00.000Z")
    let unrelatedQueueItem = queueItem(runID: "other-run", approvalID: "approval-1", fingerprint: "fp-x")
    let queued = queueItem(runID: waiting.id, approvalID: "approval-1", fingerprint: "fp-1")
    let snoozed = queueItem(
      runID: waiting.id,
      approvalID: "approval-2",
      fingerprint: "fp-2",
      snoozedUntil: "2026-07-15T00:00:00.000Z"
    )

    let summary = AIChatLinkedRunsSummary.make(
      runs: [running, waiting],
      queueItems: [unrelatedQueueItem, queued],
      snoozedQueueItems: [snoozed],
      now: now
    )

    XCTAssertEqual(summary.runs.map(\.id), ["needs-approval", "running"])
    let approvals = try XCTUnwrap(summary.runs.first?.approvals)
    XCTAssertEqual(approvals.map(\.approvalID), ["approval-1", "approval-2"])
    XCTAssertEqual(approvals.map(\.id), ["run:needs-approval:approval-1", "run:needs-approval:approval-2"])
    XCTAssertEqual(approvals[0].queueItem, queued)
    XCTAssertEqual(approvals[0].queueItem?.fingerprint, "fp-1")
    XCTAssertFalse(approvals[0].isSnoozed)
    XCTAssertEqual(approvals[1].queueItem, snoozed)
    XCTAssertTrue(approvals[1].isSnoozed)
    XCTAssertEqual(summary.pendingApprovalCount, 2)
    XCTAssertEqual(summary.runs.first?.status.text, "Needs approval")
  }

  func testApprovalMissingFromTheQueueOffersNoDecision() throws {
    let waiting = try makeRun(
      id: "needs-approval",
      status: "waiting-approval",
      approvals: [("approval-1", "pending", "fp-1")]
    )

    let summary = AIChatLinkedRunsSummary.make(runs: [waiting], queueItems: [], now: now)

    XCTAssertEqual(summary.runs.first?.approvals.count, 1)
    XCTAssertNil(summary.runs.first?.approvals.first?.queueItem)
  }

  func testPendingApprovalsOnFinishedRunsAreNotOffered() throws {
    let finished = try makeRun(
      id: "finished",
      status: "completed",
      approvals: [("approval-1", "pending", "fp-1")],
      updatedAt: "2026-07-14T11:00:00.000Z"
    )

    let summary = AIChatLinkedRunsSummary.make(
      runs: [finished],
      queueItems: [queueItem(runID: finished.id, approvalID: "approval-1", fingerprint: "fp-1")],
      now: now
    )

    XCTAssertTrue(summary.runs.isEmpty)
    XCTAssertEqual(summary.recentlyFinished.map(\.id), ["finished"])
    XCTAssertEqual(summary.recentlyFinished.first?.approvals, [])
  }

  @MainActor
  func testStoreListsOnlyRunsCurrentlyLinkedToTheThread() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let linked = try makeRun(id: "linked", status: "running", comments: [threadComment(threadID)])
    let elsewhere = try makeRun(id: "elsewhere", status: "running", comments: [threadComment(otherThreadID)])
    // A continuation moved this run to the other chat; the latest link wins.
    let moved = try makeRun(
      id: "moved",
      status: "blocked",
      comments: [threadComment(threadID), threadComment(otherThreadID)]
    )
    let unlinked = try makeRun(id: "unlinked", status: "running")
    let waiting = try makeRun(
      id: "waiting",
      status: "waiting-approval",
      comments: ["Created from chat.\nAI chat thread: \(threadID.uuidString.lowercased())"],
      approvals: [("approval-1", "pending", "fp-1")]
    )
    store.replaceAgentRunsForTesting([linked, elsewhere, moved, unlinked, waiting])
    let item = queueItem(runID: waiting.id, approvalID: "approval-1", fingerprint: "fp-1")
    store.replaceApprovalItemsForTesting([item])

    let summary = store.aiChatLinkedRunsSummary(for: threadID, now: now)
    XCTAssertEqual(summary.runs.map(\.id), ["waiting", "linked"])
    XCTAssertEqual(summary.runs.first?.approvals.first?.queueItem, item)
    XCTAssertEqual(
      store.aiChatLinkedRunsSummary(for: otherThreadID, now: now).runs.map(\.id),
      ["moved", "elsewhere"]
    )
    XCTAssertTrue(store.aiChatLinkedRunsSummary(for: UUID(), now: now).isEmpty)
  }

  @MainActor
  func testLinkedRunIndexIsBuiltWithTheLargeRunProjection() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    var runs = try (0..<300).map { index in
      try makeRun(id: "archive-\(index)", status: "completed", updatedAt: "2026-06-01T00:00:00.000Z")
    }
    runs.append(try makeRun(id: "linked", status: "queued", comments: [threadComment(threadID)]))

    store.replaceAgentRunsForTesting(runs)

    XCTAssertEqual(store.agentRunIDsByLinkedAIChatThreadID, [threadID.uuidString.lowercased(): ["linked"]])
    XCTAssertEqual(store.aiChatLinkedRunsSummary(for: threadID, now: now).runs.map(\.id), ["linked"])
  }

  // MARK: - Fixtures

  private func threadComment(_ id: UUID) -> String {
    "AI destination: example-agent\nAI chat thread: \(id.uuidString.lowercased())"
  }

  private func queueItem(
    runID: String,
    approvalID: String,
    fingerprint: String,
    snoozedUntil: String? = nil
  ) -> ApprovalItem {
    ApprovalItem(
      title: "Publish the weekly summary",
      status: "pending",
      todo: nil,
      level: nil,
      file: "runs/\(runID).org",
      line: 1,
      idValue: approvalID,
      properties: [:],
      body: "Post the summary to the team page",
      tags: [],
      kind: "run",
      approvalId: approvalID,
      fingerprint: fingerprint,
      action: "Post the summary to the team page",
      riskClass: "external-action",
      requestedAt: "2026-07-14T00:00:00.000Z",
      runId: runID,
      runStatus: "waiting-approval",
      snoozedUntil: snoozedUntil
    )
  }

  private func makeRun(
    id: String,
    status: String,
    comments: [String] = [],
    approvals: [(id: String, status: String, fingerprint: String)] = [],
    updatedAt: String = "2026-07-14T11:00:00.000Z",
    completedAt: String? = nil
  ) throws -> AgentRunItem {
    var value: [String: Any] = [
      "id": id,
      "goal": "Prepare the \(id) briefing",
      "acceptanceCriteria": [],
      "status": status,
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": approvals.map { approval in [
        "id": approval.id,
        "fingerprint": approval.fingerprint,
        "title": "Publish the weekly summary",
        "action": "Post the summary to the team page",
        "riskClass": "external-action",
        "status": approval.status,
        "requestedAt": "2026-07-14T00:00:00.000Z",
      ] },
      "validations": [],
      "comments": comments.enumerated().map { index, body in [
        "id": "comment-\(index)",
        "author": "Celorga",
        "body": body,
        "createdAt": "2026-07-14T00:00:0\(index).000Z",
      ] },
      "events": [],
      "createdAt": "2026-07-01T00:00:00.000Z",
      "updatedAt": updatedAt,
    ]
    if let completedAt { value["completedAt"] = completedAt }
    return try JSONDecoder().decode(AgentRunItem.self, from: JSONSerialization.data(withJSONObject: value))
  }
}
