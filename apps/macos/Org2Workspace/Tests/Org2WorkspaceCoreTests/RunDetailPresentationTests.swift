import XCTest
@testable import Org2WorkspaceCore

final class RunDetailPresentationTests: XCTestCase {
  private func step(_ id: String, kind: String = "agent", status: String) -> AgentRunStepItem {
    AgentRunStepItem(id: id, title: id, kind: kind, status: status, capability: nil, detail: nil)
  }

  func testApprovalStepWaitingOnAPersonIsDistinctFromAgentWork() {
    let approval = step("approve", kind: "approval", status: "running")
    XCTAssertEqual(RunDetailPresentation.stepState(approval, hasPendingApproval: true), .waitingOnYou)
    XCTAssertEqual(RunDetailPresentation.stepState(approval, hasPendingApproval: false), .current)
    XCTAssertEqual(RunDetailPresentation.stepState(step("draft", status: "running"), hasPendingApproval: true), .current)
    XCTAssertEqual(RunDetailPresentation.stepState(step("later", status: "pending"), hasPendingApproval: true), .upcoming)
    XCTAssertEqual(RunDetailPresentation.stepState(step("x", status: "failed"), hasPendingApproval: false), .failed)
  }

  func testProgressCountsCompletedAndSkippedSteps() {
    let plan = [
      step("a", status: "completed"),
      step("b", status: "skipped"),
      step("c", kind: "approval", status: "running"),
      step("d", status: "pending"),
    ]
    XCTAssertEqual(RunDetailPresentation.finishedStepCount(plan), 2)
    XCTAssertEqual(RunDetailPresentation.progressFraction(plan), 0.5)
    XCTAssertEqual(RunDetailPresentation.progressValue(plan), "2 of 4 steps")
    XCTAssertEqual(RunDetailPresentation.focusStep(plan, hasPendingApproval: true)?.step.id, "c")
    XCTAssertEqual(RunDetailPresentation.focusStep(plan, hasPendingApproval: true)?.state, .waitingOnYou)
    XCTAssertEqual(RunDetailPresentation.progressValue([]), "No plan")
  }

  func testShortPlansUseTheStepTrackAndLongPlansUseTheList() {
    XCTAssertFalse(RunDetailPresentation.usesStepTrack(stepCount: 1))
    XCTAssertTrue(RunDetailPresentation.usesStepTrack(stepCount: 4))
    XCTAssertTrue(RunDetailPresentation.usesStepTrack(stepCount: RunDetailPresentation.maxTrackSteps))
    XCTAssertFalse(RunDetailPresentation.usesStepTrack(stepCount: RunDetailPresentation.maxTrackSteps + 1))
  }

  func testElapsedTimeUsesStartAndLastActivityNotTheWallClock() {
    XCTAssertEqual(
      RunDetailPresentation.elapsedText(start: "2026-06-15T16:05:00.000Z", end: "2026-06-15T16:23:00.000Z"),
      "18 min"
    )
    XCTAssertEqual(
      RunDetailPresentation.elapsedText(start: "2026-06-15T16:00:00Z", end: "2026-06-15T18:30:00Z"),
      "2 hr 30 min"
    )
    XCTAssertEqual(
      RunDetailPresentation.elapsedText(start: "2026-06-15T16:00:00Z", end: "2026-06-18T16:00:00Z"),
      "3 days"
    )
    XCTAssertNil(RunDetailPresentation.elapsedText(start: nil, end: "2026-06-15T16:00:00Z"))
  }

  func testDecisionCountIsOnlyShownForMultipleApprovals() {
    XCTAssertNil(RunDetailPresentation.approvalCountText(pending: 1, total: 1))
    XCTAssertEqual(RunDetailPresentation.approvalCountText(pending: 1, total: 3), "1 of 3 needs a decision")
    XCTAssertEqual(RunDetailPresentation.approvalCountText(pending: 2, total: 3), "2 of 3 need a decision")
  }

  func testBadgesAndRiskMapToTones() {
    XCTAssertEqual(RunDetailPresentation.reviewBadge("review-required", runFinished: false)?.tone, .caution)
    XCTAssertEqual(RunDetailPresentation.reviewBadge("review-required", runFinished: true)?.text, "Review was pending")
    XCTAssertNil(RunDetailPresentation.reviewBadge(nil, runFinished: false))
    XCTAssertEqual(RunDetailPresentation.checkBadge("failed").tone, .critical)
    XCTAssertEqual(RunDetailPresentation.risk("external-action").tone, .caution)
    XCTAssertEqual(RunDetailPresentation.risk("read-only").tone, .positive)
    XCTAssertEqual(RunDetailPresentation.risk("custom-class").label, "Custom Class")
  }

  func testAgentLabelsPreferTheAssigneeAndHideThePlaceholderModel() {
    XCTAssertEqual(RunDetailPresentation.agentName(assignee: "OpenClaw", provider: "openclaw", destinationTitle: nil), "OpenClaw")
    XCTAssertEqual(RunDetailPresentation.agentName(assignee: " ", provider: "claude-code", destinationTitle: nil), "Claude Code")
    XCTAssertEqual(RunDetailPresentation.agentDetail(model: "configured-agent", provider: "openclaw"), "Default model")
    XCTAssertEqual(RunDetailPresentation.agentDetail(model: "gpt-5.5", provider: "codex"), "gpt-5.5")
    XCTAssertEqual(RunDetailPresentation.initials("Open Claw"), "OC")
  }
}
