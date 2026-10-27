import XCTest
@testable import Org2WorkspaceCore

/// Snoozing approvals: a snoozed approval stays pending, leaves the Pending queue (and
/// everything that counts it), appears under Snoozed, and returns on its own by the clock.
final class ApprovalSnoozeTests: XCTestCase {
  private func runItem(snoozedUntil: String? = nil) throws -> AgentRunItem {
    var approval: [String: Any] = [
      "id": "partner-approval",
      "fingerprint": "sha256:partner",
      "title": "Approve partner update",
      "action": "send partner update",
      "riskClass": "external-action",
      "status": "pending",
      "requestedAt": "2026-10-26T10:00:00.000Z",
    ]
    if let snoozedUntil { approval["snoozedUntil"] = snoozedUntil }
    let object: [String: Any] = [
      "id": "partner-run",
      "goal": "Send the partner update",
      "acceptanceCriteria": [],
      "status": "waiting-approval",
      "riskClass": "external-action",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [approval],
      "validations": [],
      "comments": [],
      "events": [],
      "createdAt": "2026-10-26T10:00:00.000Z",
      "updatedAt": "2026-10-26T10:00:00.000Z",
    ]
    return try JSONDecoder().decode(AgentRunItem.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func queueItem(id: String, snoozedUntil: String? = nil, root: URL) -> ApprovalItem {
    ApprovalItem(
      title: "Approve \(id)",
      status: "pending",
      todo: nil,
      level: nil,
      file: root.appendingPathComponent(".org2/runs/\(id)-run.org2").path,
      line: 1,
      idValue: "\(id)-approval",
      properties: [:],
      body: "send \(id)",
      tags: [],
      kind: "run",
      approvalId: "\(id)-approval",
      fingerprint: "sha256:\(id)",
      action: "send \(id)",
      riskClass: "external-action",
      requestedAt: "2026-10-26T10:00:00.000Z",
      runId: "\(id)-run",
      runGoal: "Send \(id)",
      runStatus: "waiting-approval",
      snoozedUntil: snoozedUntil
    )
  }

  private func iso(_ date: Date) -> String {
    WorkspaceStore.approvalSnoozeTimestamp(date)
  }

  func testPartitionKeepsOnlyFutureSnoozesHidden() {
    let root = URL(fileURLWithPath: "/tmp/celorga-snooze")
    let now = Date()
    let future = queueItem(id: "future", snoozedUntil: iso(now.addingTimeInterval(3600)), root: root)
    let expired = queueItem(id: "expired", snoozedUntil: iso(now.addingTimeInterval(-60)), root: root)
    let awake = queueItem(id: "awake", root: root)

    let partitioned = WorkspaceStore.partitionSnoozedApprovalItems([future, expired, awake], now: now)
    XCTAssertEqual(partitioned.snoozed.map(\.id), [future.id])
    XCTAssertEqual(Set(partitioned.awake.map(\.id)), [expired.id, awake.id])
    XCTAssertNil(partitioned.awake.first(where: { $0.id == expired.id })?.snoozedUntil, "an expired snooze is cleared")
  }

  func testSnoozePresetsLandOnSensibleTimes() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    // Monday 2026-10-26 15:30 local.
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15, minute: 30)))
    func components(_ option: ApprovalSnoozeOption) -> DateComponents {
      calendar.dateComponents([.year, .month, .day, .hour, .minute], from: option.wakeDate(from: now, calendar: calendar))
    }
    XCTAssertEqual(components(.threeHours).hour, 18)
    XCTAssertEqual(components(.tomorrowMorning), DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 0))
    XCTAssertEqual(components(.nextMonday), DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 0), "on a Monday, next Monday")
    XCTAssertEqual(components(.nextWeek), DateComponents(year: 2026, month: 11, day: 2, hour: 9, minute: 0))
    XCTAssertFalse(ApprovalSnoozeOption.threeHours.isWholeDay)
  }

  @MainActor
  func testSnoozingMovesARunApprovalToSnoozedAndWakingBringsItBack() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-approval-snooze-\(UUID().uuidString)", isDirectory: true)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.deferredAgentRunsRefreshDelayNanoseconds = 60_000_000_000
    let partner = queueItem(id: "partner", root: root)
    let invoice = queueItem(id: "invoice", root: root)
    store.replaceApprovalItemsForTesting([partner, invoice])
    let until = Date().addingTimeInterval(24 * 3600)

    var calls: [(String, String, Date?)] = []
    store.agentRunApprovalSnoozeForTesting = { runID, approvalID, requested in
      calls.append((runID, approvalID, requested))
      return try self.runItem(snoozedUntil: requested.map(WorkspaceStore.approvalSnoozeTimestamp))
    }
    // Later queue scans reflect the durable snooze.
    var scanSnoozedUntil: String? = iso(until)
    store.approvalQueueLoaderForTesting = {
      ([self.queueItem(id: "partner", snoozedUntil: scanSnoozedUntil, root: root), invoice], [])
    }

    await store.snoozeApproval(partner, until: until)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.0, "partner-run")
    XCTAssertEqual(calls.first?.1, "partner-approval")
    XCTAssertEqual(store.approvalItems.map(\.id), [invoice.id], "snoozed approval leaves Pending")
    XCTAssertEqual(store.snoozedApprovalItems.map(\.id), [partner.id])
    XCTAssertEqual(store.visibleApprovalItems.map(\.id), [invoice.id])

    store.showsSnoozedApprovals = true
    XCTAssertEqual(store.visibleApprovalItems.map(\.id), [partner.id])
    XCTAssertTrue(try XCTUnwrap(store.visibleApprovalItems.first).isSnoozed())

    // A refresh keeps the split.
    await store.refreshApprovals(updatesStatus: false)
    XCTAssertEqual(store.approvalItems.map(\.id), [invoice.id])
    XCTAssertEqual(store.snoozedApprovalItems.map(\.id), [partner.id])

    scanSnoozedUntil = nil
    await store.wakeApproval(try XCTUnwrap(store.snoozedApprovalItems.first))
    XCTAssertNil(calls.last?.2, "waking sends no time")
    XCTAssertTrue(store.snoozedApprovalItems.isEmpty)
    XCTAssertEqual(Set(store.approvalItems.map(\.id)), [partner.id, invoice.id])
  }

  @MainActor
  func testExpiredSnoozeReturnsWithoutARescan() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-approval-wake-\(UUID().uuidString)", isDirectory: true)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    let soon = Date().addingTimeInterval(60)
    let snoozed = queueItem(id: "partner", snoozedUntil: iso(soon), root: root)
    store.approvalQueueLoaderForTesting = { ([snoozed], []) }
    await store.refreshApprovals(updatesStatus: false)
    XCTAssertTrue(store.approvalItems.isEmpty)
    XCTAssertEqual(store.snoozedApprovalItems.map(\.id), [snoozed.id])

    store.wakeExpiredSnoozedApprovals(now: soon.addingTimeInterval(1))
    XCTAssertTrue(store.snoozedApprovalItems.isEmpty)
    XCTAssertEqual(store.approvalItems.map(\.id), [snoozed.id])
    XCTAssertNil(store.approvalItems.first?.snoozedUntil)
  }

  @MainActor
  func testPhoneSnapshotListsSnoozedApprovalsSeparately() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-approval-phone-\(UUID().uuidString)", isDirectory: true)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    let snoozed = queueItem(id: "partner", snoozedUntil: iso(Date().addingTimeInterval(3600)), root: root)
    let awake = queueItem(id: "invoice", root: root)
    store.approvalQueueLoaderForTesting = { ([snoozed, awake], []) }
    await store.refreshApprovals(updatesStatus: false)

    let snapshot = await store.mobileRemoteWorkspaceSnapshot(refreshesCanonicalState: false)
    XCTAssertEqual(snapshot.approvals.map(\.id), [awake.id])
    XCTAssertEqual(snapshot.snoozedApprovals?.map(\.id), [snoozed.id])
    XCTAssertEqual(snapshot.snoozedApprovals?.first?.snoozedUntil, snoozed.snoozedUntil)

    // Older phones decode the snapshot without knowing about snoozes.
    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(MobileRemoteWorkspaceSnapshot.self, from: encoded)
    XCTAssertEqual(decoded.snoozedApprovals?.count, 1)
  }
}
