import XCTest
@testable import Org2WorkspaceCore

/// Regression coverage for Request Changes appearing to do nothing: an
/// approvals scan that started before the decision was written finished after
/// it, put the decided item back in the queue, and the post-decision refresh
/// was dropped because a scan was already in flight.
final class ApprovalDecisionRefreshRaceTests: XCTestCase {
  @MainActor
  private final class ScanGate {
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func waitIfFirst() async {
      calls += 1
      guard calls == 1, !released else { return }
      await withCheckedContinuation { continuation = $0 }
    }

    func release() {
      released = true
      continuation?.resume()
      continuation = nil
    }
  }

  private func run(status: String, approvalStatus: String, updatedAt: String) throws -> AgentRunItem {
    var approval: [String: Any] = [
      "id": "draft-approval",
      "fingerprint": "sha256:draft",
      "title": "Send benchmark options",
      "action": "Send exact reviewed content\nProvider draft: gmail:gog:r-draft",
      "riskClass": "external-action",
      "status": approvalStatus,
      "requestedRole": "owner",
      "requestedFrom": "Avi",
      "requestedAt": "2026-10-19T20:51:01.207Z",
    ]
    if approvalStatus != "pending" {
      approval["decidedAt"] = updatedAt
      approval["decidedBy"] = "Org2Workspace"
      approval["decisionNote"] = "Send an actual quote."
    }
    let object: [String: Any] = [
      "id": "draft-run",
      "goal": "Send benchmark options",
      "acceptanceCriteria": [],
      "status": status,
      "riskClass": "external-action",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [approval],
      "validations": [],
      "comments": [],
      "events": [],
      "createdAt": "2026-10-19T17:43:15.833Z",
      "updatedAt": updatedAt,
    ]
    return try JSONDecoder().decode(AgentRunItem.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func queueItem(for run: AgentRunItem, root: URL) throws -> ApprovalItem {
    let approval = try XCTUnwrap(run.approvals.first)
    return ApprovalItem(
      title: approval.title,
      status: approval.status,
      todo: nil,
      level: nil,
      file: root.appendingPathComponent(".org2/runs/\(run.id).org2").path,
      line: 1,
      idValue: approval.id,
      properties: [:],
      body: approval.action,
      tags: [],
      kind: "run",
      approvalId: approval.id,
      fingerprint: approval.fingerprint,
      action: approval.action,
      riskClass: approval.riskClass,
      requestedRole: approval.requestedRole,
      requestedFrom: approval.requestedFrom,
      requestedAt: approval.requestedAt,
      runId: run.id,
      runGoal: run.goal,
      runStatus: run.status,
      runPendingApprovalCount: run.pendingApprovalCount,
      runApprovalCount: run.approvals.count
    )
  }

  @MainActor
  func testRequestChangesIsNotUndoneByAScanThatStartedBeforeTheDecision() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-request-changes-race-\(UUID().uuidString)", isDirectory: true)
    let pendingRun = try run(status: "waiting-approval", approvalStatus: "pending", updatedAt: "2026-10-21T16:29:52.108Z")
    let revisedRun = try run(status: "blocked", approvalStatus: "revised", updatedAt: "2026-10-21T21:24:19.107Z")
    let item = try queueItem(for: pendingRun, root: root)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.deferredAgentRunsRefreshDelayNanoseconds = 60_000_000_000
    store.replaceAgentRunsForTesting([pendingRun])
    store.replaceApprovalItemsForTesting([item])
    store.agentRunApprovalDecisionForTesting = { _, _, decision, note in
      XCTAssertEqual(decision, "revised")
      XCTAssertEqual(note, "Send an actual quote.")
      return revisedRun
    }

    let gate = ScanGate()
    store.approvalQueueLoaderForTesting = {
      let isFirst = gate.calls == 0
      await gate.waitIfFirst()
      // The first scan read the corpus before the decision was written.
      return isFirst ? ([item], [pendingRun]) : ([], [revisedRun])
    }

    let staleScan = Task { @MainActor in await store.refreshApprovals() }
    while gate.calls == 0 { await Task.yield() }

    await store.requestChanges(item, feedback: "Send an actual quote.")
    XCTAssertFalse(store.approvalItems.contains(where: { $0.id == item.id }))

    // Let the post-decision refresh request arrive while the stale scan is
    // still in flight, then let the stale scan finish.
    try await Task.sleep(nanoseconds: 400_000_000)
    gate.release()
    await staleScan.value

    let deadline = Date().addingTimeInterval(5)
    while gate.calls < 2, Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertGreaterThanOrEqual(gate.calls, 2, "A follow-up scan must run after the stale one")
    XCTAssertFalse(
      store.approvalItems.contains(where: { $0.id == item.id }),
      "A scan that started before the decision must not resurrect the decided approval"
    )
    let displayedRun = try XCTUnwrap(store.agentRuns.first(where: { $0.id == "draft-run" }))
    XCTAssertEqual(displayedRun.approvals.first?.status, "revised")
    XCTAssertNil(store.approvalActionError(item))
  }

  func testNewerLocalRunWinsOverAnOlderRefreshedCopy() throws {
    let older = try run(status: "waiting-approval", approvalStatus: "pending", updatedAt: "2026-10-21T16:29:52.108Z")
    let newer = try run(status: "blocked", approvalStatus: "revised", updatedAt: "2026-10-21T21:24:19.107Z")
    XCTAssertTrue(WorkspaceStore.isAgentRun(newer, newerThan: older))
    XCTAssertFalse(WorkspaceStore.isAgentRun(older, newerThan: newer))
    XCTAssertFalse(WorkspaceStore.isAgentRun(older, newerThan: older))
  }
}
