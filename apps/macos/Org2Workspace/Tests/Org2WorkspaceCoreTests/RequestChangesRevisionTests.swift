import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Request Changes on any run hands the note back to an agent: the run returns to
/// `running`, the note is sent to a revision thread, and the agent is told to request a
/// replacement approval. Before this, only workflow runs were handed back; every other
/// run stopped at `blocked` with nobody working on it.
final class RequestChangesRevisionTests: XCTestCase {
  private let note = "Never send work email from avi.press. Queue a draft from my Scarf email."
  private let action = "From: Clavi <clavi@avi.press>\nTo: ajay@example.com\n\nHi Ajay,"

  @MainActor
  func testRequestChangesOnPlainRunResumesItAndSendsTheNoteToARevisionSession() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let waiting = try makeRun(status: "waiting-approval", approvalStatus: "pending")
    let blocked = try makeRun(
      status: "blocked",
      approvalStatus: "revised",
      decisionNote: note,
      blockedReason: AgentRunItem.approvalBoundaryBlockReason
    )
    let running = try makeRun(status: "running", approvalStatus: "revised", decisionNote: note)
    store.replaceAgentRunsForTesting([waiting])
    var decidedNote: String?
    store.agentRunApprovalDecisionForTesting = { _, _, decision, note in
      XCTAssertEqual(decision, "revised")
      decidedNote = note
      return blocked
    }
    var resumedRunIDs: [String] = []
    store.agentRunRevisionResumeForTesting = { run in
      resumedRunIDs.append(run.id)
      return running
    }
    var dispatches: [(status: String, approvalID: String, prompt: String, sessionKey: String)] = []
    store.agentRunRevisionDispatchForTesting = { run, approval, prompt, sessionKey in
      dispatches.append((run.status, approval.id, prompt, sessionKey))
    }

    await store.requestAgentRunChanges(
      waiting,
      approval: try XCTUnwrap(waiting.approvals.first),
      feedback: note
    )

    XCTAssertEqual(decidedNote, note)
    XCTAssertEqual(resumedRunIDs, ["plain-run"])
    XCTAssertEqual(dispatches.count, 1)
    let dispatch = try XCTUnwrap(dispatches.first)
    XCTAssertEqual(dispatch.status, "running", "the run is running before the agent receives the note")
    XCTAssertEqual(dispatch.approvalID, "approval-1")
    XCTAssertEqual(
      dispatch.sessionKey,
      WorkspaceStore.approvedRunContinuationSessionKey(runID: "plain-run", agentID: store.openClawAgentID)
    )
    XCTAssertTrue(dispatch.prompt.contains("ORG2_RUN_RESUME: revision-requested"))
    XCTAssertTrue(dispatch.prompt.contains(note))
    XCTAssertTrue(dispatch.prompt.contains(action))
    XCTAssertTrue(dispatch.prompt.contains("celorga run approval-request plain-run"))
    XCTAssertTrue(dispatch.prompt.contains("Do not perform the protected action"))
    XCTAssertEqual(store.agentRuns.first?.status, "running")
    XCTAssertTrue(store.statusText.contains("revising"), store.statusText)
  }

  @MainActor
  func testRevisionReusesTheRunsCorrelatedOpenClawSession() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let correlation = "OPENCLAW_KIND: agent-turn\nOPENCLAW_SESSION: agent:main:org2:thread-7"
    let waiting = try makeRun(status: "waiting-approval", approvalStatus: "pending", comments: [correlation])
    let blocked = try makeRun(
      status: "blocked",
      approvalStatus: "revised",
      decisionNote: note,
      blockedReason: AgentRunItem.approvalBoundaryBlockReason,
      comments: [correlation]
    )
    store.replaceAgentRunsForTesting([waiting])
    store.agentRunApprovalDecisionForTesting = { _, _, _, _ in blocked }
    store.agentRunRevisionResumeForTesting = { _ in
      try self.makeRun(status: "running", approvalStatus: "revised", decisionNote: self.note, comments: [correlation])
    }
    var sessionKeys: [String] = []
    store.agentRunRevisionDispatchForTesting = { _, _, _, sessionKey in sessionKeys.append(sessionKey) }

    await store.requestAgentRunChanges(
      waiting,
      approval: try XCTUnwrap(waiting.approvals.first),
      feedback: note
    )

    XCTAssertEqual(sessionKeys, ["agent:main:org2:thread-7"])
  }

  @MainActor
  func testFailedRevisionHandOffBlocksTheRunWithASpecificReasonAndCanBeRetried() async throws {
    struct DispatchFailure: LocalizedError {
      var errorDescription: String? { "OpenClaw gateway is unavailable" }
    }
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let waiting = try makeRun(status: "waiting-approval", approvalStatus: "pending")
    let blocked = try makeRun(
      status: "blocked",
      approvalStatus: "revised",
      decisionNote: note,
      blockedReason: AgentRunItem.approvalBoundaryBlockReason
    )
    let dispatchBlocked = try makeRun(
      status: "blocked",
      approvalStatus: "revised",
      decisionNote: note,
      blockedReason: AgentRunItem.revisionDispatchFailureReason
    )
    store.replaceAgentRunsForTesting([waiting])
    store.agentRunApprovalDecisionForTesting = { _, _, _, _ in blocked }
    store.agentRunRevisionResumeForTesting = { _ in
      try self.makeRun(status: "running", approvalStatus: "revised", decisionNote: self.note)
    }
    var dispatchAttempts = 0
    store.agentRunRevisionDispatchForTesting = { _, _, _, _ in
      dispatchAttempts += 1
      if dispatchAttempts == 1 { throw DispatchFailure() }
    }
    var recordedReason: String?
    store.agentRunApprovalContinuationFailureForTesting = { _, reason in
      recordedReason = reason
      return dispatchBlocked
    }

    await store.requestAgentRunChanges(
      waiting,
      approval: try XCTUnwrap(waiting.approvals.first),
      feedback: note
    )

    XCTAssertEqual(recordedReason, AgentRunItem.revisionDispatchFailureReason)
    XCTAssertEqual(store.agentRuns.first?.status, "blocked")
    XCTAssertEqual(store.agentRuns.first?.blockedReason, AgentRunItem.revisionDispatchFailureReason)
    XCTAssertEqual(store.errorText, "OpenClaw gateway is unavailable")
    XCTAssertTrue(store.statusText.contains("could not be handed to an agent"), store.statusText)

    let stuck = try XCTUnwrap(store.agentRuns.first)
    XCTAssertEqual(stuck.revisionAwaitingHandoff?.id, "approval-1")
    await store.continueRequestedRevision(stuck)

    XCTAssertEqual(dispatchAttempts, 2)
    XCTAssertEqual(store.agentRuns.first?.status, "running")
  }

  @MainActor
  func testRevisionIsNotHandedOffWhileAnotherApprovalIsPendingOrOneWasRejected() async throws {
    let (store, root) = try makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    var dispatches = 0
    store.agentRunRevisionResumeForTesting = { run in run }
    store.agentRunRevisionDispatchForTesting = { _, _, _, _ in dispatches += 1 }

    let stillWaiting = try makeRun(
      status: "waiting-approval",
      approvalStatuses: ["revised", "pending"],
      decisionNote: note
    )
    let rejectedSibling = try makeRun(
      status: "blocked",
      approvalStatuses: ["revised", "rejected"],
      decisionNote: note,
      blockedReason: AgentRunItem.approvalBoundaryBlockReason
    )
    XCTAssertNil(stillWaiting.revisionAwaitingHandoff)
    XCTAssertNil(rejectedSibling.revisionAwaitingHandoff)
    await store.continueRequestedRevision(stillWaiting)
    await store.continueRequestedRevision(rejectedSibling)
    XCTAssertEqual(dispatches, 0)
  }

  func testRevisionHandOffIgnoresASeparateClarificationBlock() throws {
    let clarification = try makeRun(
      status: "blocked",
      approvalStatus: "revised",
      decisionNote: note,
      blockedReason: "Which Scarf address should the draft come from?"
    )
    XCTAssertEqual(clarification.resumableRevisionApproval?.id, "approval-1")
    XCTAssertNil(clarification.revisionAwaitingHandoff)

    let boundary = try makeRun(
      status: "blocked",
      approvalStatus: "revised",
      decisionNote: note,
      blockedReason: AgentRunItem.approvalBoundaryBlockReason
    )
    XCTAssertEqual(boundary.revisionAwaitingHandoff?.id, "approval-1")
  }

  @MainActor
  private func makeStore() throws -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-request-changes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    return (store, root)
  }

  private func makeRun(
    status: String,
    approvalStatus: String? = nil,
    approvalStatuses: [String]? = nil,
    decisionNote: String? = nil,
    blockedReason: String? = nil,
    comments: [String] = []
  ) throws -> AgentRunItem {
    let statuses = approvalStatuses ?? [approvalStatus ?? "pending"]
    var value: [String: Any] = [
      "id": "plain-run",
      "goal": "Yugabyte: quarterly sync email to Ajay",
      "acceptanceCriteria": [],
      "status": status,
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": statuses.enumerated().map { index, approvalStatus -> [String: Any] in
        var approval: [String: Any] = [
          "id": "approval-\(index + 1)",
          "title": "Send Ajay the quarterly sync invitation",
          "action": action,
          "riskClass": "external-action",
          "status": approvalStatus,
          "requestedAt": "2026-10-22T18:01:23.295Z"
        ]
        if approvalStatus != "pending" {
          approval["decidedAt"] = "2026-10-23T15:20:48.651Z"
          approval["decidedBy"] = "Org2Workspace"
          if approvalStatus == "revised", let decisionNote { approval["decisionNote"] = decisionNote }
        }
        return approval
      },
      "validations": [],
      "comments": comments.enumerated().map { index, body in [
        "id": "comment-\(index)",
        "author": "org2-lifecycle",
        "body": body,
        "createdAt": "2026-10-22T18:00:00.000Z"
      ] },
      "events": [[
        "id": "waiting",
        "type": "status-changed",
        "at": "2026-10-22T18:01:23.295Z",
        "detail": "queued -> waiting-approval"
      ]],
      "createdAt": "2026-10-22T18:00:54.887Z",
      "updatedAt": "2026-10-23T15:20:48.651Z"
    ]
    if let blockedReason { value["blockedReason"] = blockedReason }
    let data = try JSONSerialization.data(withJSONObject: value)
    return try JSONDecoder().decode(AgentRunItem.self, from: data)
  }
}
