import QuartzCore
import XCTest
@testable import Org2WorkspaceCore

/// Bulk-snoozing a page of run approvals in a large run archive must not
/// stall the main actor long enough to show the spinning cursor.
@MainActor
final class ApprovalBulkSnoozePerformanceTests: XCTestCase {
  func testBulkSnoozeOfFifteenRunApprovalsKeepsTheMainActorResponsive() async throws {
    let runCount = 12_600
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-bulk-snooze-\(UUID().uuidString)", isDirectory: true)
    store.deferredAgentRunsRefreshDelayNanoseconds = 60_000_000_000
    let runs = try Self.runs(count: runCount)
    store.replaceAgentRunsForTesting(runs)
    let queue = (0..<24).map { Self.queueItem(run: runs[$0], index: $0) }
    store.replaceApprovalItemsForTesting(queue)
    let snoozeUntil = Date().addingTimeInterval(3 * 3600)
    let rescannedQueue = Self.queue(queue, snoozingFirst: 15, until: snoozeUntil)
    store.approvalQueueLoaderForTesting = { (rescannedQueue, []) }
    let runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
    store.agentRunApprovalSnoozeForTesting = { runID, _, _ in
      try XCTUnwrap(runsByID[runID])
    }
    for item in queue.prefix(15) {
      store.toggleApprovalItemBulkSelection(item)
    }
    XCTAssertEqual(store.bulkApprovalSelectionCount, 15)

    let probe = MainActorStallProbe()
    probe.start()
    await store.snoozeSelectedApprovals(until: snoozeUntil)
    // Cover the debounced queue refresh that follows the batch.
    try await Task.sleep(nanoseconds: 700_000_000)
    let longest = probe.stop()

    XCTAssertEqual(store.bulkApprovalSelectionCount, 0)
    print("PERFORMANCE bulk-snooze-main-actor-stall: max=\(String(format: "%.1f", longest)) ms")
    XCTAssertLessThan(longest, 250, "bulk snooze blocked the main actor for \(longest) ms")
  }

  /// A bulk snooze applies the returned run records together, in one
  /// archive update, and keeps every one of them.
  func testBulkSnoozeAppliesEveryUpdatedRunInOneArchiveUpdate() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-bulk-snooze-batch-\(UUID().uuidString)", isDirectory: true)
    store.deferredAgentRunsRefreshDelayNanoseconds = 60_000_000_000
    let runs = try Self.runs(count: 300)
    store.replaceAgentRunsForTesting(runs)
    let queue = (0..<6).map { Self.queueItem(run: runs[$0], index: $0) }
    store.replaceApprovalItemsForTesting(queue)
    let snoozeUntil = Date().addingTimeInterval(3 * 3600)
    let rescannedQueue = Self.queue(queue, snoozingFirst: 4, until: snoozeUntil)
    store.approvalQueueLoaderForTesting = { (rescannedQueue, []) }
    let updatedByID = Dictionary(
      uniqueKeysWithValues: try Self.runs(count: 6, goalPrefix: "Snoozed outcome").map { ($0.id, $0) }
    )
    store.agentRunApprovalSnoozeForTesting = { runID, _, _ in
      try XCTUnwrap(updatedByID[runID])
    }
    for item in queue.prefix(4) {
      store.toggleApprovalItemBulkSelection(item)
    }
    let revisionBefore = store.agentRunsRevision

    await store.snoozeSelectedApprovals(until: snoozeUntil)

    XCTAssertEqual(store.agentRunsRevision, revisionBefore + 1)
    XCTAssertEqual(store.agentRuns.count, 300)
    XCTAssertEqual(
      store.agentRuns.prefix(6).map(\.goal),
      ["Snoozed outcome 0", "Snoozed outcome 1", "Snoozed outcome 2", "Snoozed outcome 3",
       "Synthetic outcome 4", "Synthetic outcome 5"]
    )
    XCTAssertNil(store.batchedAgentRunUpdates)
  }

  static func runs(count: Int, goalPrefix: String = "Synthetic outcome") throws -> [AgentRunItem] {
    let objects: [[String: Any]] = (0..<count).map { index in
      [
        "schema": "org2:agent-run:v1",
        "id": "bulk-run-\(index)",
        "goal": "\(goalPrefix) \(index)",
        "acceptanceCriteria": [],
        "status": index < 24 ? "waiting-approval" : "completed",
        "riskClass": "external-action",
        "capabilities": [], "context": [], "plan": [], "artifacts": [],
        "approvals": [], "validations": [], "comments": [], "events": [],
        "createdAt": "2026-07-28T00:00:00.000Z",
        "updatedAt": "2026-07-28T00:01:00.000Z",
      ]
    }
    return try JSONDecoder().decode(
      [AgentRunItem].self,
      from: JSONSerialization.data(withJSONObject: objects)
    )
  }

  /// The queue a rescan returns after the first `count` approvals were
  /// snoozed until `until`.
  static func queue(_ queue: [ApprovalItem], snoozingFirst count: Int, until: Date) -> [ApprovalItem] {
    let timestamp = WorkspaceStore.approvalSnoozeTimestamp(until)
    return queue.enumerated().map { index, item in
      index < count ? item.withSnoozedUntil(timestamp) : item
    }
  }

  static func queueItem(run: AgentRunItem, index: Int) -> ApprovalItem {
    ApprovalItem(
      title: "Approve synthetic send \(index)", status: "pending", todo: nil, level: nil,
      file: "/tmp/\(run.id).org2", line: 1, idValue: "approval-\(index)",
      properties: [:], body: "To: someone@example.com\nSubject: Synthetic \(index)", tags: [],
      kind: "run", approvalId: "approval-\(index)", fingerprint: "fingerprint-\(index)",
      action: "Send synthetic email \(index)", riskClass: "external-action",
      requestedAt: "2026-07-28T00:00:30.000Z", runId: run.id, runGoal: run.goal,
      runStatus: run.status, runPendingApprovalCount: 1, runApprovalCount: 1
    )
  }
}

/// Records the longest interval the main actor failed to run a 2 ms tick.
@MainActor
final class MainActorStallProbe {
  private var task: Task<Void, Never>?
  private var longest: Double = 0
  private var generation = 0

  func start() {
    generation += 1
    let current = generation
    longest = 0
    task = Task { @MainActor [weak self] in
      var last = CACurrentMediaTime()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000)
        // A cancelled tick must not report time spent after stop().
        guard !Task.isCancelled, let self, self.generation == current else { return }
        let now = CACurrentMediaTime()
        self.longest = max(self.longest, (now - last) * 1_000)
        last = now
      }
    }
  }

  func stop() -> Double {
    generation += 1
    task?.cancel()
    task = nil
    return longest
  }
}
