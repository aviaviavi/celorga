import XCTest
@testable import Org2WorkspaceCore

final class ApprovalQueuePresentationTests: XCTestCase {
  private func runItem(
    title: String,
    body: String,
    goal: String?,
    pending: Int = 1,
    status: String = "waiting-approval",
    effect: String? = ApprovalItem.ordinaryRunDecisionEffect
  ) -> ApprovalItem {
    ApprovalItem(
      title: title, status: "pending", todo: nil, level: nil,
      file: "/tmp/runs/run-1.org", line: 1, idValue: "approval-1",
      properties: [:], body: body, tags: [], kind: "run",
      approvalId: "approval-1", action: body,
      runId: "0d7494b9-72a2-44fb-a338-81c44d152a2c", runGoal: goal, runStatus: status,
      runPendingApprovalCount: pending, runApprovalCount: pending,
      runDecisionEffect: effect
    )
  }

  func testSummaryDropsEmptyFieldsMachineDetailAndValuesRepeatedInTitle() {
    let item = runItem(
      title: "Approve \u{201C}Quarterly update\u{201D} to ana@example.com, ben@example.com",
      body: """
      To: ana@example.com, ben@example.com
      Cc: (none)
      Bcc: (none)
      Subject: Quarterly update

      Body:
      (Body unavailable; open the provider draft before approving.)

      Provider draft: mail:draft:123456
      Content fingerprint:
      942e-b5f57f8266247f87582ee718cd40e2973
      """,
      goal: "Review Quarterly update draft to ana@example.com, ben@example.com"
    )
    XCTAssertEqual(item.listSummary, "(Body unavailable; open the provider draft before approving.)")
    XCTAssertNil(item.listRunContext, "a goal that restates the title is noise")
    XCTAssertNil(item.listDecisionNote, "the ordinary resume-the-run case needs no note")
    XCTAssertEqual(item.compactSourceLabel, "Run 0d7494b9")
  }

  func testDistinctGoalAndUnusualDecisionEffectsStayVisible() {
    let item = runItem(
      title: "Approve benchmark quote email",
      body: "Authorize one send of the verified draft.",
      goal: "Fulfill the October commitment to send pricing options",
      pending: 3
    )
    XCTAssertEqual(item.listSummary, "Authorize one send of the verified draft.")
    XCTAssertEqual(item.listRunContext, "Fulfill the October commitment to send pricing options")
    XCTAssertEqual(item.listDecisionNote, "1 of 3 approvals pending on this run")

    let blocked = runItem(title: "Approve", body: "x", goal: nil, status: "blocked", effect: "ignored")
    XCTAssertEqual(blocked.listDecisionNote, "Run is blocked")

    let revised = runItem(title: "Approve", body: "x", goal: nil, effect: "This is the last pending approval, but another decision requested changes.")
    XCTAssertEqual(revised.listDecisionNote, "This is the last pending approval, but another decision requested changes.")
  }

  func testDecisionCardHidesNoteThatRepeatsAction() {
    XCTAssertTrue(RunDetailPresentation.approvalNoteRepeatsAction(note: "To: a\nCc: (none)", action: "To: a\n Cc: (none)"))
    XCTAssertFalse(RunDetailPresentation.approvalNoteRepeatsAction(note: "Check the attachment hash", action: "Send the email"))
  }
}
