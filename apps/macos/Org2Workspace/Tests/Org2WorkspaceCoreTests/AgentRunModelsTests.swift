import AppKit
import Observation
import XCTest
@testable import Org2WorkspaceCore

private final class AgentRunObservationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var changed = false

  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return changed
  }

  func set() {
    lock.lock()
    changed = true
    lock.unlock()
  }
}

private actor AgentRunListRefreshGate {
  private var continuation: CheckedContinuation<[AgentRunItem], Never>?

  func wait() async -> [AgentRunItem] {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release(with runs: [AgentRunItem]) {
    continuation?.resume(returning: runs)
    continuation = nil
  }
}

private actor ApprovalDecisionGate {
  private var startedApprovalIDs: [String] = []
  private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
  private var releasedApprovalIDs: Set<String> = []

  func wait(for approvalID: String) async {
    startedApprovalIDs.append(approvalID)
    if releasedApprovalIDs.remove(approvalID) != nil {
      return
    }
    await withCheckedContinuation { continuation in
      waiters[approvalID] = continuation
    }
  }

  func release(_ approvalID: String) {
    if let continuation = waiters.removeValue(forKey: approvalID) {
      continuation.resume()
    } else {
      releasedApprovalIDs.insert(approvalID)
    }
  }

  func started() -> [String] {
    startedApprovalIDs
  }
}

private func selectionKeyDown(
  _ characters: String = "",
  keyCode: UInt16,
  modifiers: NSEvent.ModifierFlags = []
) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: modifiers,
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: characters,
    charactersIgnoringModifiers: characters,
    isARepeat: false,
    keyCode: keyCode
  )!
}

final class AgentRunModelsTests: XCTestCase {
  func testLegacyRunDisplayTitleExtractsTaskFromExecutionBrief() throws {
    let run = try makeRun(goal: """
    Execute this newly approved engineering task exactly once.

    Task: Reduce OpenOrg per-turn context overhead across persistent Codex/OpenClaw sessions, stateless provider fallbacks, and shared AI rooms; add token telemetry and regression budgets.
    Repository: https://github.com/aviaviavi/org2
    Source: file:daily/2026-09-18.org::1
    """)

    XCTAssertTrue(run.displayTitle.hasPrefix("Reduce OpenOrg per-turn context overhead"))
    XCTAssertTrue(run.displayTitle.hasSuffix("…"))
    XCTAssertLessThanOrEqual(run.displayTitle.count, 120)
    XCTAssertFalse(run.displayTitle.contains("Repository:"))
    XCTAssertFalse(run.displayTitle.contains("Execute this newly approved"))
  }

  func testRunCenterResolvesSelectedApprovalWithinPresentedRun() {
    XCTAssertEqual(
      RunCenterPresentation.approvalID(
        selectedApprovalItemID: "run:run-1:approve-chrimle",
        runID: "run-1"
      ),
      "approve-chrimle"
    )
    XCTAssertNil(
      RunCenterPresentation.approvalID(
        selectedApprovalItemID: "run:run-2:approve-neuw",
        runID: "run-1"
      )
    )
    XCTAssertNil(
      RunCenterPresentation.approvalID(
        selectedApprovalItemID: "meetings/example.org2:12:approval",
        runID: "run-1"
      )
    )
  }

  func testRunReviewAutoRefreshUsesOneMinuteInterval() {
    XCTAssertEqual(WorkspaceStore.runReviewAutoRefreshIntervalNanoseconds, 60_000_000_000)
    XCTAssertEqual(WorkspaceStore.automationScheduleCheckIntervalNanoseconds, 60_000_000_000)
  }

  @MainActor
  func testActiveListPaneKeyboardSelectionCoversReviewRunsAndFiles() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-list-keyboard-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runs = try (0..<3).map { index in
      try makeRun(
        id: "selection-run-\(index)",
        goal: "Review selection \(index)",
        status: "waiting-approval",
        pendingApproval: true,
        updatedAt: "2026-08-28T16:0\(index):00.000Z"
      )
    }
    let approvals = try runs.map { run in
      approvalQueueItem(
        run: run,
        approval: try XCTUnwrap(run.approvals.first),
        root: root
      )
    }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting(runs)
    store.replaceApprovalItemsForTesting(approvals)
    store.selectedSurface = .approvals
    store.runsAndReviewPage = .review
    store.activateWorkspacePane(.surface)

    let visibleApprovals = store.visibleApprovalItems
    store.selectApprovalItem(visibleApprovals[1])
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown(keyCode: 125)))
    XCTAssertEqual(store.selectedApprovalItemID, visibleApprovals[2].id)
    XCTAssertEqual(store.selectedApprovalItemIDsForAIContext, [visibleApprovals[2].id])
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown(keyCode: 126)))
    XCTAssertEqual(store.selectedApprovalItemID, visibleApprovals[1].id)
    XCTAssertEqual(store.selectedApprovalItemIDsForAIContext, [visibleApprovals[1].id])
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown("a", keyCode: 0, modifiers: [.command])))
    XCTAssertEqual(store.bulkApprovalSelectionCount, 3)
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown("a", keyCode: 0, modifiers: [.command, .shift])))
    XCTAssertEqual(store.bulkApprovalSelectionCount, 0)
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown(keyCode: 125, modifiers: [.shift])))
    XCTAssertEqual(store.bulkSelectedApprovalItemIDs, [visibleApprovals[1].id, visibleApprovals[2].id])
    XCTAssertEqual(store.selectedApprovalItemID, visibleApprovals[2].id)

    store.clearApprovalBulkSelection()
    store.activateWorkspacePane(.detail)
    XCTAssertFalse(store.handleWorkspaceKeyDown(selectionKeyDown("a", keyCode: 0, modifiers: [.command])))
    XCTAssertEqual(store.bulkApprovalSelectionCount, 0)

    store.activateWorkspacePane(.surface)
    store.runsAndReviewPage = .runs
    store.agentRunSelectionScope = .attention
    let visibleRunIDs = store.agentRunIDs(for: .attention)
    store.selectAgentRun(try XCTUnwrap(store.agentRun(for: visibleRunIDs[1])))
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown("a", keyCode: 0, modifiers: [.command])))
    XCTAssertEqual(store.selectedAgentRunIDsForAIContext, Set(visibleRunIDs))
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown("a", keyCode: 0, modifiers: [.command, .shift])))
    XCTAssertTrue(store.selectedAgentRunIDsForAIContext.isEmpty)
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown(keyCode: 125, modifiers: [.shift])))
    XCTAssertEqual(store.selectedAgentRunIDsForAIContext, [visibleRunIDs[1], visibleRunIDs[2]])
    XCTAssertEqual(store.selectedAgentRunID, visibleRunIDs[2])

    let files = try (0..<3).map { index in
      let url = root.appendingPathComponent("selection-\(index).org2")
      try "* File \(index)\n".write(to: url, atomically: true, encoding: .utf8)
      return CorpusFile(path: url.path, relativePath: url.lastPathComponent, modifiedAt: nil, byteCount: nil)
    }
    store.corpusFiles = files
    store.selectedSurface = .files
    store.activateWorkspacePane(.surface)
    let visibleFiles = store.filteredCorpusFiles
    store.selectedCorpusFileID = visibleFiles[1].id
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown("a", keyCode: 0, modifiers: [.command])))
    XCTAssertEqual(store.selectedCorpusFileIDsForAIContext, Set(visibleFiles.map(\.id)))
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown("a", keyCode: 0, modifiers: [.command, .shift])))
    XCTAssertTrue(store.selectedCorpusFileIDsForAIContext.isEmpty)
    XCTAssertTrue(store.handleWorkspaceKeyDown(selectionKeyDown(keyCode: 126, modifiers: [.shift])))
    XCTAssertEqual(store.selectedCorpusFileIDsForAIContext, [visibleFiles[0].id, visibleFiles[1].id])
    XCTAssertEqual(store.selectedCorpusFileID, visibleFiles[0].id)
  }

  @MainActor
  func testApprovalRefreshReloadsSelectedRunDetailWithoutScanningRunArchive() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-approval-detail-refresh-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let staleRun = try makeRun(
      id: "revised-draft-run",
      status: "waiting-approval",
      pendingApproval: true,
      approvalAction: "Send the older draft.",
      updatedAt: "2026-08-28T16:00:00.000Z"
    )
    let currentRun = try makeRun(
      id: staleRun.id,
      status: "waiting-approval",
      pendingApproval: true,
      approvalAction: "Send the latest revised draft.",
      updatedAt: "2026-08-28T16:05:00.000Z"
    )
    let staleApproval = try XCTUnwrap(staleRun.approvals.first)
    let currentApproval = try XCTUnwrap(currentRun.approvals.first)
    let staleQueueItem = approvalQueueItem(
      run: staleRun,
      approval: staleApproval,
      root: corpus
    )

    let queuePayload: [String: Any] = [
      "count": 1,
      "items": [[
        "kind": "run",
        "title": currentApproval.title,
        "status": currentApproval.status,
        "file": corpus.appendingPathComponent(".org2/runs/\(currentRun.id).org2").path,
        "line": 1,
        "idValue": currentApproval.id,
        "properties": [:],
        "body": currentApproval.action,
        "tags": [],
        "approvalId": currentApproval.id,
        "action": currentApproval.action,
        "riskClass": currentApproval.riskClass,
        "requestedAt": currentApproval.requestedAt,
        "runId": currentRun.id,
        "runGoal": currentRun.goal,
        "runStatus": currentRun.status,
        "runPendingApprovalCount": currentRun.pendingApprovalCount,
        "runApprovalCount": currentRun.approvals.count,
      ]],
      "runDetails": [[
        "id": currentRun.id,
        "goal": currentRun.goal,
        "acceptanceCriteria": [],
        "status": currentRun.status,
        "riskClass": currentRun.riskClass,
        "capabilities": [],
        "context": [],
        "plan": [],
        "artifacts": [],
        "approvals": [[
          "id": currentApproval.id,
          "title": currentApproval.title,
          "action": currentApproval.action,
          "riskClass": currentApproval.riskClass,
          "status": currentApproval.status,
          "requestedAt": currentApproval.requestedAt,
        ]],
        "validations": [],
        "comments": [],
        "events": [],
        "createdAt": currentRun.createdAt,
        "updatedAt": currentRun.updatedAt,
      ]]
    ]
    let queueData = try JSONSerialization.data(withJSONObject: queuePayload)
    let queueBase64 = queueData.base64EncodedString()
    try """
    process.stdout.write(Buffer.from("\(queueBase64)", "base64").toString("utf8"));
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus, persistsDefault: false)
    store.runsAndReviewPage = .review
    store.replaceAgentRunsForTesting([staleRun])
    store.replaceApprovalItemsForTesting([staleQueueItem])
    store.selectApprovalItem(staleQueueItem)

    var detailRefreshCount = 0
    store.agentRunDetailLoaderForTesting = { runID in
      detailRefreshCount += 1
      XCTAssertEqual(runID, currentRun.id)
      return currentRun
    }
    var archiveRefreshCount = 0
    store.agentRunListLoaderForTesting = {
      archiveRefreshCount += 1
      return [currentRun]
    }

    await store.refreshApprovals(updatesStatus: true)

    XCTAssertEqual(detailRefreshCount, 0)
    XCTAssertEqual(archiveRefreshCount, 0)
    XCTAssertEqual(store.approvalItems.first?.action, "Send the latest revised draft.")
    XCTAssertEqual(
      store.presentedAgentRun?.actionablePendingApprovals.first?.action,
      "Send the latest revised draft."
    )
  }

  func testDecodesGoalAndAgentProfileCatalogs() throws {
    let goalPayload = try JSONDecoder().decode(AgentGoalListPayload.self, from: Data(#"""
    {
      "schema": "org2:goal-list:v1",
      "goals": [{
        "schema": "org2:goal:v1",
        "id": "qualified-meetings",
        "title": "Generate qualified meetings",
        "description": "Turn strong signals into reviewable outreach.",
        "status": "active",
        "ownerAgentRef": "example-reviewer",
        "measures": ["Qualified meetings"],
        "file": "/tmp/corpus/goals/qualified-meetings.org2",
        "createdAt": "2026-08-05T00:00:00.000Z",
        "updatedAt": "2026-08-05T00:00:00.000Z"
      }]
    }
    """#.utf8))
    let goal = try XCTUnwrap(goalPayload.goals.first)
    XCTAssertEqual(goal.ownerAgentRef, "example-reviewer")
    XCTAssertEqual(goal.file, "/tmp/corpus/goals/qualified-meetings.org2")

    let profilePayload = try JSONDecoder().decode(AgentProfileListPayload.self, from: Data(#"""
    {
      "schema": "org2:agent-profile-list:v1",
      "profiles": [{
        "schema": "org2:agent-profile:v1",
        "id": "example-reviewer",
        "name": "Example Reviewer",
        "description": "",
        "status": "active",
        "responsibilities": ["Qualify accounts"],
        "capabilities": ["agent-context"],
        "skills": ["outreach"],
        "defaultRuntime": "openclaw",
        "runtimeBindings": [{"runtime":"openclaw","runtimeAgentId":"example-reviewer-runtime"}],
        "goalRefs": ["qualified-meetings"],
        "primaryGoalRef": "qualified-meetings",
        "file": "/tmp/corpus/agent-profiles/example-reviewer.org2",
        "createdAt": "2026-08-05T00:00:00.000Z",
        "updatedAt": "2026-08-05T00:00:00.000Z"
      }]
    }
    """#.utf8))
    let profile = try XCTUnwrap(profilePayload.profiles.first)
    XCTAssertEqual(profile.primaryGoalRef, goal.id)
    XCTAssertEqual(profile.defaultRuntime, "openclaw")
    XCTAssertEqual(profile.preferredChatRuntime, .openClaw)
    XCTAssertEqual(profile.runtimeBindings.first?.id, "openclaw:example-reviewer-runtime")
    XCTAssertEqual(RunsAndReviewPage.allCases, [.runs, .review, .goals, .agents, .workflows])
  }

  func testDecodesDurableRunListPayload() throws {
    let data = Data(#"""
    {
      "schema": "org2:run-list:v1",
      "runs": [{
        "id": "run-1",
        "goal": "Prepare a cited briefing",
        "acceptanceCriteria": ["PDF exists"],
        "status": "waiting-approval",
        "riskClass": "external-action",
        "owner": "Avi",
        "assignee": "writer",
        "agentRef": "scarf-writer",
        "goalRef": "trusted-launch",
        "parentRunId": "parent-run",
        "capabilities": ["publish"],
        "context": [{"ref":"notes/source.org2","citation":"notes/source.org2:1"}],
        "plan": [{"id":"draft","title":"Draft","kind":"agent","status":"completed"}],
        "artifacts": [{"id":"pdf","path":"compiled/brief.pdf","role":"export","reviewStatus":"review-required","createdAt":"2026-07-14T00:00:00.000Z"}],
        "approvals": [{"id":"release","title":"Release","action":"publish","riskClass":"external-action","status":"pending","requestedAt":"2026-07-14T00:00:00.000Z"}],
        "validations": [{"id":"citations","name":"citations","status":"passed","checkedAt":"2026-07-14T00:00:00.000Z"}],
        "comments": [{"id":"comment","author":"Avi","body":"Please revise.","createdAt":"2026-07-14T00:00:00.000Z"}],
        "events": [{"id":"event","type":"created","at":"2026-07-14T00:00:00.000Z"}],
        "createdAt": "2026-07-14T00:00:00.000Z",
        "updatedAt": "2026-07-14T00:01:00.000Z"
      }]
    }
    """#.utf8)

    let payload = try JSONDecoder().decode(AgentRunListPayload.self, from: data)
    let run = try XCTUnwrap(payload.runs.first)
    XCTAssertEqual(run.id, "run-1")
    XCTAssertEqual(run.parentRunId, "parent-run")
    XCTAssertEqual(run.agentRef, "scarf-writer")
    XCTAssertEqual(run.goalRef, "trusted-launch")
    XCTAssertEqual(run.pendingApprovalCount, 1)
    XCTAssertEqual(run.progressText, "1/1 completed")
    XCTAssertTrue(run.needsAttention)
    XCTAssertTrue(run.matchesRunFilter("cited briefing"))
    XCTAssertTrue(run.matchesRunFilter("scarf-writer trusted-launch"))
    XCTAssertTrue(run.matchesRunFilter("notes source"))
    XCTAssertTrue(run.matchesRunFilter("brief pdf"))
    XCTAssertTrue(run.matchesRunFilter("release pending"))
    XCTAssertTrue(run.matchesRunFilter("please revise"))
    XCTAssertTrue(run.matchesRunFilter("  \n "))
    XCTAssertFalse(run.matchesRunFilter("deployment checklist"))
    XCTAssertTrue(try XCTUnwrap(run.artifacts.first).isPDF)
  }

  func testEveryRunExceptCompletedCanBeMarkedDoneElsewhere() throws {
    for status in ["queued", "running", "waiting-approval", "blocked", "failed", "canceled"] {
      XCTAssertTrue(try makeRun(status: status).canMarkDoneElsewhere, status)
    }
    XCTAssertFalse(try makeRun(status: "completed").canMarkDoneElsewhere)
  }

  func testDecodesRunApprovalAsUnifiedQueueItem() throws {
    let data = Data(#"""
    {
      "kind": "run",
      "title": "Release report",
      "status": "pending",
      "todo": null,
      "level": null,
      "file": "/tmp/corpus/.org2/runs/run-1.org2",
      "line": 1,
      "idValue": "approval-1",
      "properties": {},
      "body": "publish report",
      "tags": [],
      "approvalId": "approval-1",
      "fingerprint": "sha256:abc123",
      "action": "publish report",
      "riskClass": "external-action",
      "requestedRole": "owner",
      "requestedAt": "2026-07-21T00:00:00.000Z",
      "runId": "run-1",
      "runGoal": "Prepare report",
      "runStatus": "waiting-approval",
      "runPendingApprovalCount": 2,
      "runApprovalCount": 3,
      "runDecisionEffect": "Approving this leaves 1 other pending approval before the run can resume.",
      "decisionKeys": ["artifact:gmail:gog:r123"]
    }
    """#.utf8)

    let item = try JSONDecoder().decode(ApprovalItem.self, from: data)
    XCTAssertTrue(item.isRunApproval)
    XCTAssertEqual(item.id, "run:run-1:approval-1")
    XCTAssertEqual(item.fingerprint, "sha256:abc123")
    XCTAssertEqual(item.decisionKeys, ["artifact:gmail:gog:r123"])
    XCTAssertEqual(item.sourceLabel, "Run run-1")
    XCTAssertEqual(item.runDependencyText, "Approving this leaves 1 other pending approval before the run can resume.")
    XCTAssertTrue(item.matchesApprovalFilter("prepare report external-action"))
  }

  func testRecognizesOpenClawExternalDraftRunForApprovalContinuation() throws {
    let data = Data(#"""
    {
      "id": "draft-run-1",
      "goal": "Review provider draft",
      "acceptanceCriteria": [],
      "status": "running",
      "riskClass": "external-action",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [],
      "validations": [],
      "comments": [{
        "id": "comment-1",
        "author": "org2-lifecycle",
        "body": "OPENCLAW_KEY: draft:gmail:gog:default:r123\nOPENCLAW_KIND: external-draft",
        "createdAt": "2026-07-30T16:56:25.154Z"
      }],
      "events": [],
      "createdAt": "2026-07-30T16:56:25.154Z",
      "updatedAt": "2026-07-30T18:08:14.385Z"
    }
    """#.utf8)

    let run = try JSONDecoder().decode(AgentRunItem.self, from: data)
    XCTAssertTrue(run.isOpenClawExternalDraft)
    XCTAssertTrue(run.hasOpenClawApprovalContinuation)
  }

  func testRecognizesPlainCorrelatedOpenClawRunForApprovalContinuation() throws {
    let run = try makeRun(
      status: "running",
      comments: ["OPENCLAW_KIND: agent-turn\nOPENCLAW_SESSION: agent:main:org2:thread-1"]
    )
    XCTAssertFalse(run.isOpenClawExternalDraft)
    XCTAssertEqual(run.openClawSessionKey, "agent:main:org2:thread-1")
    XCTAssertTrue(run.hasOpenClawApprovalContinuation)
    XCTAssertFalse(try makeRun(status: "running").hasOpenClawApprovalContinuation)

    let approvedUncorrelatedRun = try makeRun(
      status: "running",
      approvalStatus: "approved"
    )
    XCTAssertTrue(approvedUncorrelatedRun.canContinueApprovedWork)
    XCTAssertTrue(approvedUncorrelatedRun.hasOpenClawApprovalContinuation)
    XCTAssertFalse(approvedUncorrelatedRun.hasApprovedProviderDraftBoundary)

    let approvedProviderDraft = try makeRun(
      status: "running",
      approvalStatus: "approved",
      approvalAction: "Send exact reviewed content\nProvider draft: gmail:gog:r-123"
    )
    XCTAssertTrue(approvedProviderDraft.canContinueApprovedWork)
    XCTAssertTrue(approvedProviderDraft.hasApprovedProviderDraftBoundary)

    let rejectedBoundary = try makeRun(
      status: "running",
      approvalStatus: "rejected"
    )
    XCTAssertTrue(rejectedBoundary.canContinueApprovedWork)
    XCTAssertTrue(rejectedBoundary.hasOpenClawApprovalContinuation)
    XCTAssertTrue(rejectedBoundary.approvedCurrentApprovalBoundary.isEmpty)
  }

  @MainActor
  func testApprovingCorrelatedPlainRunRequestsGenericContinuation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-approved-run-continuation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let correlation = "OPENCLAW_KIND: agent-turn\nOPENCLAW_SESSION: agent:main:org2:thread-1"
    let waitingRun = try makeRun(
      status: "waiting-approval",
      comments: [correlation],
      approvalStatus: "pending"
    )
    let runningRun = try makeRun(
      status: "running",
      comments: [correlation],
      approvalStatus: "approved"
    )
    let approval = try XCTUnwrap(waitingRun.approvals.first)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([waitingRun])
    store.agentRunApprovalDecisionForTesting = { _, _, _, _ in runningRun }
    var continuedRunID: String?
    store.agentRunApprovalContinuationForTesting = { run in
      continuedRunID = run.id
      return OpenClawApprovedRunContinuation(
        runID: run.id,
        sessionKey: run.openClawSessionKey,
        prompt: "already sent",
        kind: "run",
        alreadyResumed: true
      )
    }

    await store.decideAgentRunApproval(
      waitingRun,
      approval: approval,
      decision: "approved"
    )

    XCTAssertEqual(continuedRunID, waitingRun.id)
    XCTAssertEqual(store.agentRuns.first?.status, "running")
    XCTAssertTrue(store.statusText.contains("already continuing"))
  }

  @MainActor
  func testApprovingUncorrelatedPlainRunRequestsGenericContinuation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-approved-uncorrelated-run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let waitingRun = try makeRun(
      id: "plain-run",
      status: "waiting-approval",
      approvalStatus: "pending"
    )
    let runningRun = try makeRun(
      id: "plain-run",
      status: "running",
      approvalStatus: "approved"
    )
    let approval = try XCTUnwrap(waitingRun.approvals.first)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([waitingRun])
    store.agentRunApprovalDecisionForTesting = { _, _, _, _ in runningRun }
    var continuedRunID: String?
    store.agentRunApprovalContinuationForTesting = { run in
      continuedRunID = run.id
      return OpenClawApprovedRunContinuation(
        runID: run.id,
        sessionKey: nil,
        prompt: "already sent",
        kind: "run",
        alreadyResumed: true
      )
    }

    await store.decideAgentRunApproval(
      waitingRun,
      approval: approval,
      decision: "approved"
    )

    XCTAssertEqual(continuedRunID, "plain-run")
    XCTAssertTrue(store.statusText.contains("already continuing"))
  }

  @MainActor
  func testRunApprovalSourceDriftOffersRepairAndRetriesTheOriginalAction() async throws {
    struct RunSourceDrift: LocalizedError {
      var errorDescription: String? {
        "run source has out-of-band readable-state changes (title); run org2 doctor and reconcile the source before writing"
      }
    }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-source-repair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let waitingRun = try makeRun(
      id: "source-drift-run",
      status: "waiting-approval",
      approvalStatus: "pending"
    )
    let runningRun = try makeRun(
      id: "source-drift-run",
      status: "running",
      approvalStatus: "approved"
    )
    let approval = try XCTUnwrap(waitingRun.approvals.first)
    let item = approvalQueueItem(run: waitingRun, approval: approval, root: root)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([waitingRun])
    store.replaceApprovalItemsForTesting([item])

    var decisionAttempts = 0
    store.agentRunApprovalDecisionForTesting = { _, _, decision, _ in
      XCTAssertEqual(decision, "approved")
      decisionAttempts += 1
      if decisionAttempts == 1 { throw RunSourceDrift() }
      return runningRun
    }
    var repairedRunIDs: [String] = []
    store.agentRunSourceReconciliationForTesting = { runID in
      repairedRunIDs.append(runID)
    }
    store.agentRunApprovalContinuationForTesting = { run in
      OpenClawApprovedRunContinuation(
        runID: run.id,
        sessionKey: nil,
        prompt: "already sent",
        kind: "run",
        alreadyResumed: true
      )
    }

    await store.approve(item)

    XCTAssertEqual(decisionAttempts, 1)
    XCTAssertTrue(store.canRepairApprovalSource(item))
    XCTAssertTrue(store.approvalActionError(item)?.contains("out-of-band") == true)
    XCTAssertFalse(store.isRepairingApprovalSource(item))

    await store.repairApprovalSourceAndRetry(item)

    XCTAssertEqual(repairedRunIDs, [waitingRun.id])
    XCTAssertEqual(decisionAttempts, 2)
    XCTAssertFalse(store.canRepairApprovalSource(item))
    XCTAssertNil(store.approvalActionError(item))
    XCTAssertFalse(store.isRepairingApprovalSource(item))
    XCTAssertTrue(store.approvalItems.isEmpty)
    XCTAssertEqual(store.agentRuns.first?.status, "running")
  }

  @MainActor
  func testFailedAutomaticApprovalContinuationDurablyBlocksRun() async throws {
    struct DispatchFailure: LocalizedError {
      var errorDescription: String? { "OpenClaw gateway is unavailable" }
    }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-approved-run-dispatch-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let waitingRun = try makeRun(status: "waiting-approval", approvalStatus: "pending")
    let runningRun = try makeRun(status: "running", approvalStatus: "approved")
    let blockedRun = try makeRun(
      status: "blocked",
      blockedReason: WorkspaceStore.agentRunApprovalContinuationFailureReason,
      approvalStatus: "approved"
    )
    let approval = try XCTUnwrap(waitingRun.approvals.first)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([waitingRun])
    store.agentRunApprovalDecisionForTesting = { _, _, _, _ in runningRun }
    store.agentRunApprovalContinuationForTesting = { _ in throw DispatchFailure() }
    var recordedReason: String?
    store.agentRunApprovalContinuationFailureForTesting = { _, reason in
      recordedReason = reason
      return blockedRun
    }

    await store.decideAgentRunApproval(
      waitingRun,
      approval: approval,
      decision: "approved"
    )

    XCTAssertEqual(recordedReason, WorkspaceStore.agentRunApprovalContinuationFailureReason)
    XCTAssertEqual(store.agentRuns.first?.status, "blocked")
    XCTAssertEqual(store.agentRuns.first?.blockedReason, recordedReason)
    XCTAssertEqual(store.errorText, "OpenClaw gateway is unavailable")
    XCTAssertTrue(store.statusText.contains("blocked because continuation failed"))
  }

  func testApprovedRunContinuationSessionIsDeterministic() {
    let first = WorkspaceStore.approvedRunContinuationSessionKey(
      runID: "342be84b-4bb4-4a0d-b36c-a31414f4b5c4",
      agentID: "meetingbot"
    )
    let second = WorkspaceStore.approvedRunContinuationSessionKey(
      runID: "342be84b-4bb4-4a0d-b36c-a31414f4b5c4",
      agentID: "meetingbot"
    )

    XCTAssertEqual(first, second)
    XCTAssertEqual(
      first,
      "agent:meetingbot:org2-run:342be84b-4bb4-4a0d-b36c-a31414f4b5c4"
    )
  }

  @MainActor
  func testManualContinuationRecoversAnApprovedUncorrelatedRun() async throws {
    let run = try makeRun(
      id: "approved-orphan",
      goal: "Send approved provider draft",
      status: "running",
      approvalStatus: "approved",
      approvalAction: "Send exact reviewed content\nProvider draft: gmail:gog:r-123"
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.replaceAgentRunsForTesting([run])
    var requestedRunID: String?
    store.agentRunApprovalContinuationForTesting = { requestedRun in
      requestedRunID = requestedRun.id
      return OpenClawApprovedRunContinuation(
        runID: requestedRun.id,
        sessionKey: nil,
        prompt: "already sent",
        kind: "run",
        alreadyResumed: true
      )
    }

    await store.continueApprovedAgentRun(run)

    XCTAssertEqual(requestedRunID, run.id)
    XCTAssertTrue(store.statusText.contains("already continuing"))
    XCTAssertFalse(store.mutatingAgentRunIDs.contains(run.id))
  }

  @MainActor
  func testUnifiedQueueDecisionUpdatesTheCanonicalRunApproval() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-approval-queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    _ = try await cli.run([
      "run", "create", "--id", "approval-run", "--goal", "Release report",
      "--dir", root.path, "--json"
    ])
    _ = try await cli.run(["run", "start", "approval-run", "--dir", root.path, "--json"])
    _ = try await cli.run([
      "run", "approval-request", "approval-run",
      "--title", "Approve release", "--action", "publish report",
      "--risk", "external-action", "--role", "owner", "--from", "Avi",
      "--dir", root.path, "--json"
    ])

    let store = WorkspaceStore(cli: cli)
    store.setCorpusRoot(root, persistsDefault: false)
    store.agentRunApprovalContinuationForTesting = { run in
      OpenClawApprovedRunContinuation(
        runID: run.id,
        sessionKey: nil,
        prompt: "already sent",
        kind: "run",
        alreadyResumed: true
      )
    }
    await store.refreshAgentRuns()
    await store.refreshApprovals()

    let queueItem = try XCTUnwrap(store.approvalItems.first(where: { $0.isRunApproval }))
    XCTAssertEqual(queueItem.runId, "approval-run")
    XCTAssertEqual(queueItem.runPendingApprovalCount, 1)
    XCTAssertEqual(queueItem.runDependencyText, "This is the last pending approval; approving it resumes the run.")

    await store.approve(queueItem)
    await store.refreshApprovals()

    let updatedRun = try XCTUnwrap(store.agentRuns.first(where: { $0.id == "approval-run" }))
    XCTAssertEqual(updatedRun.status, "running")
    XCTAssertEqual(updatedRun.approvals.first?.status, "approved")
    XCTAssertFalse(store.approvalItems.contains(where: { $0.id == queueItem.id }))
  }

  @MainActor
  func testApprovalClearsBeforeDeferredRunArchiveReconciliationCompletes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-approval-fast-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let waitingRun = try makeRun(
      id: "fast-approval-run",
      status: "waiting-approval",
      pendingApproval: true
    )
    let updatedRun = try makeRun(
      id: waitingRun.id,
      status: "running",
      approvalStatus: "approved"
    )
    let approval = try XCTUnwrap(waitingRun.approvals.first)
    let queueItem = ApprovalItem(
      title: approval.title,
      status: approval.status,
      todo: nil,
      level: nil,
      file: root.appendingPathComponent(".org2/runs/\(waitingRun.id).org2").path,
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
      runId: waitingRun.id,
      runGoal: waitingRun.goal,
      runStatus: waitingRun.status,
      runPendingApprovalCount: waitingRun.pendingApprovalCount,
      runApprovalCount: waitingRun.approvals.count
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([waitingRun])
    store.replaceApprovalItemsForTesting([queueItem])
    store.agentRunApprovalDecisionForTesting = { _, _, _, _ in updatedRun }
    store.deferredAgentRunsRefreshDelayNanoseconds = 0

    let refreshGate = AgentRunListRefreshGate()
    let refreshStarted = expectation(description: "Deferred run archive reconciliation started")
    store.agentRunListLoaderForTesting = {
      refreshStarted.fulfill()
      return await refreshGate.wait()
    }

    let approvalTask = Task { @MainActor in
      await store.approve(queueItem)
    }
    await fulfillment(of: [refreshStarted], timeout: 2)

    XCTAssertFalse(store.approvalItems.contains(where: { $0.id == queueItem.id }))
    XCTAssertEqual(store.agentRuns.first?.status, "running")

    await refreshGate.release(with: [updatedRun])
    await approvalTask.value
  }

  @MainActor
  func testMacRunApprovalRejectionAndCancellationResolveTheirExactItems() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-approval-terminal-decisions-\(UUID().uuidString)", isDirectory: true)

    func run(id: String, status: String, approvalStatus: String) throws -> AgentRunItem {
      var approval: [String: Any] = [
        "id": "\(id)-approval",
        "fingerprint": "sha256:\(id)",
        "title": "Approve \(id)",
        "action": "perform protected action",
        "riskClass": "external-action",
        "status": approvalStatus,
        "requestedRole": "owner",
        "requestedFrom": "Avi",
        "requestedAt": "2026-07-30T18:00:01.000Z",
      ]
      if approvalStatus != "pending" {
        approval["decidedAt"] = "2026-07-30T18:00:02.000Z"
        approval["decidedBy"] = "Avi"
      }
      let object: [String: Any] = [
        "id": id,
        "goal": "Protect \(id)",
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
        "events": [[
          "id": "\(id)-waiting",
          "type": "status-changed",
          "at": "2026-07-30T18:00:01.000Z",
          "detail": "running -> waiting-approval",
        ]],
        "createdAt": "2026-07-30T18:00:00.000Z",
        "updatedAt": "2026-07-30T18:00:02.000Z",
      ]
      return try JSONDecoder().decode(
        AgentRunItem.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    }

    let rejectedRun = try run(
      id: "rejected-run",
      status: "waiting-approval",
      approvalStatus: "pending"
    )
    let rejectedApproval = try XCTUnwrap(rejectedRun.approvals.first)
    let canceledRun = try run(
      id: "canceled-run",
      status: "waiting-approval",
      approvalStatus: "pending"
    )
    let canceledApproval = try XCTUnwrap(canceledRun.approvals.first)
    let updatedRejectedRun = try run(
      id: "rejected-run",
      status: "running",
      approvalStatus: "rejected"
    )
    let updatedCanceledRun = try run(
      id: "canceled-run",
      status: "running",
      approvalStatus: "canceled"
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([rejectedRun, canceledRun])
    // This test supplies decision results without run files; keep the deferred
    // filesystem refresh from replacing those fixtures with an empty list.
    store.deferredAgentRunsRefreshDelayNanoseconds = 60_000_000_000
    store.agentRunApprovalDecisionForTesting = { runID, approvalID, decision, note in
      XCTAssertEqual(approvalID, "\(runID)-approval")
      switch decision {
      case "rejected":
        XCTAssertEqual(note, "The protected action should not proceed.")
        return updatedRejectedRun
      case "canceled":
        XCTAssertNil(note)
        return updatedCanceledRun
      default:
        XCTFail("Unexpected decision \(decision)")
        return rejectedRun
      }
    }

    func queueItem(run: AgentRunItem, approval: AgentRunApprovalItem) -> ApprovalItem {
      ApprovalItem(
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

    let rejectedItem = queueItem(run: rejectedRun, approval: rejectedApproval)
    let canceledItem = queueItem(run: canceledRun, approval: canceledApproval)
    store.replaceApprovalItemsForTesting([rejectedItem, canceledItem])
    await store.rejectApproval(
      rejectedItem,
      endStatus: .canceled,
      reason: "The protected action should not proceed."
    )

    await store.decideAgentRunApproval(
      canceledRun,
      approval: canceledApproval,
      decision: "canceled"
    )

    let displayedRejectedRun = try XCTUnwrap(store.agentRuns.first(where: {
      $0.id == "rejected-run"
    }))
    let displayedCanceledRun = try XCTUnwrap(store.agentRuns.first(where: {
      $0.id == "canceled-run"
    }))
    XCTAssertEqual(displayedRejectedRun.status, "running")
    XCTAssertEqual(displayedRejectedRun.approvals.first?.status, "rejected")
    XCTAssertEqual(displayedRejectedRun.pendingApprovalCount, 0)
    XCTAssertEqual(displayedCanceledRun.status, "running")
    XCTAssertEqual(displayedCanceledRun.approvals.first?.status, "canceled")
    XCTAssertFalse(store.approvalItems.contains(where: {
      $0.runId == "rejected-run" || $0.runId == "canceled-run"
    }))
  }

  @MainActor
  func testRapidSiblingApprovalClicksQueueWithoutBlockingEitherRow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-approval-queued-siblings-\(UUID().uuidString)", isDirectory: true)
    let waitingRun = try makeRun(
      id: "shared-run",
      status: "waiting-approval",
      approvalStatuses: ["pending", "pending"]
    )
    let afterFirstDecision = try makeRun(
      id: waitingRun.id,
      status: "waiting-approval",
      approvalStatuses: ["approved", "pending"]
    )
    let afterSecondDecision = try makeRun(
      id: waitingRun.id,
      status: "running",
      approvalStatuses: ["approved", "approved"]
    )
    let firstApproval = try XCTUnwrap(waitingRun.approvals.first)
    let secondApproval = try XCTUnwrap(waitingRun.approvals.last)
    let firstItem = approvalQueueItem(run: waitingRun, approval: firstApproval, root: root)
    let secondItem = approvalQueueItem(run: waitingRun, approval: secondApproval, root: root)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([waitingRun])
    store.replaceApprovalItemsForTesting([firstItem, secondItem])
    let gate = ApprovalDecisionGate()
    let firstStarted = expectation(description: "First approval write started")
    let secondStarted = expectation(description: "Queued sibling approval write started")
    store.agentRunApprovalDecisionForTesting = { _, approvalID, decision, _ in
      XCTAssertEqual(decision, "approved")
      if approvalID == "approval-1" {
        firstStarted.fulfill()
        await gate.wait(for: approvalID)
        return afterFirstDecision
      }
      secondStarted.fulfill()
      await gate.wait(for: approvalID)
      return afterSecondDecision
    }

    let firstTask = Task { @MainActor in
      await store.decideAgentRunApproval(waitingRun, approval: firstApproval, decision: "approved")
    }
    await fulfillment(of: [firstStarted], timeout: 2)
    let secondTask = Task { @MainActor in
      await store.decideAgentRunApproval(waitingRun, approval: secondApproval, decision: "approved")
    }
    for _ in 0..<20 where !store.isAgentRunApprovalActionInProgress(
      runID: waitingRun.id,
      approvalID: secondApproval.id
    ) {
      await Task.yield()
    }

    XCTAssertTrue(store.isAgentRunApprovalActionInProgress(
      runID: waitingRun.id,
      approvalID: firstApproval.id
    ))
    XCTAssertTrue(store.isAgentRunApprovalActionInProgress(
      runID: waitingRun.id,
      approvalID: secondApproval.id
    ))
    let startedBeforeRelease = await gate.started()
    XCTAssertEqual(startedBeforeRelease, ["approval-1"])
    XCTAssertNil(store.approvalActionError(secondItem))

    await gate.release("approval-1")
    await fulfillment(of: [secondStarted], timeout: 2)
    await gate.release("approval-2")
    await firstTask.value
    await secondTask.value

    XCTAssertTrue(store.approvalItems.isEmpty)
    XCTAssertTrue(store.approvalActionErrorsByItemID.isEmpty)
  }

  @MainActor
  func testBulkApproveRunsIndependentApprovalWritesConcurrently() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-approval-bulk-concurrent-\(UUID().uuidString)", isDirectory: true)
    let firstRun = try makeRun(id: "run-a", status: "waiting-approval", pendingApproval: true)
    let secondRun = try makeRun(id: "run-b", status: "waiting-approval", pendingApproval: true)
    let updatedFirstRun = try makeRun(id: firstRun.id, status: "running", approvalStatus: "approved")
    let updatedSecondRun = try makeRun(id: secondRun.id, status: "running", approvalStatus: "approved")
    let firstItem = approvalQueueItem(
      run: firstRun,
      approval: try XCTUnwrap(firstRun.approvals.first),
      root: root
    )
    let secondItem = approvalQueueItem(
      run: secondRun,
      approval: try XCTUnwrap(secondRun.approvals.first),
      root: root
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([firstRun, secondRun])
    store.replaceApprovalItemsForTesting([firstItem, secondItem])
    store.bulkSelectedApprovalItemIDs = [firstItem.id, secondItem.id]
    let gate = ApprovalDecisionGate()
    let bothStarted = expectation(description: "Independent approval writes overlapped")
    bothStarted.expectedFulfillmentCount = 2
    store.agentRunApprovalDecisionForTesting = { runID, approvalID, decision, _ in
      XCTAssertEqual(decision, "approved")
      let key = "\(runID):\(approvalID)"
      bothStarted.fulfill()
      await gate.wait(for: key)
      return runID == firstRun.id ? updatedFirstRun : updatedSecondRun
    }

    let bulkTask = Task { @MainActor in await store.approveSelectedApprovals() }
    await fulfillment(of: [bothStarted], timeout: 2)

    XCTAssertTrue(store.isApprovingApproval(firstItem))
    XCTAssertTrue(store.isApprovingApproval(secondItem))
    let startedApprovalIDs = await gate.started()
    XCTAssertEqual(Set(startedApprovalIDs), ["run-a:approval-1", "run-b:approval-1"])

    await gate.release("run-a:approval-1")
    await gate.release("run-b:approval-1")
    await bulkTask.value

    XCTAssertTrue(store.approvalItems.isEmpty)
    XCTAssertEqual(store.bulkApprovalSelectionCount, 0)
    XCTAssertTrue(store.approvalActionErrorsByItemID.isEmpty)
  }

  @MainActor
  func testRejectingOneRunApprovalLeavesItsSiblingInReview() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-approval-item-scoped-rejection-\(UUID().uuidString)", isDirectory: true)
    let waitingRun = try JSONDecoder().decode(AgentRunItem.self, from: Data(#"""
    {
      "id": "batch-run",
      "goal": "Review independent recipient drafts",
      "acceptanceCriteria": [],
      "status": "waiting-approval",
      "riskClass": "external-action",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [
        {"id":"dragonflyoss","title":"Approve dragonflyoss","action":"send dragonflyoss draft","riskClass":"external-action","status":"pending","requestedAt":"2026-08-12T18:00:00.000Z"},
        {"id":"neuw","title":"Approve Neuw","action":"send Neuw draft","riskClass":"external-action","status":"pending","requestedAt":"2026-08-12T18:00:01.000Z"}
      ],
      "validations": [],
      "comments": [],
      "events": [{"id":"waiting","type":"status-changed","at":"2026-08-12T18:00:00.000Z","detail":"running -> waiting-approval","data":{"to":"waiting-approval"}}],
      "createdAt": "2026-08-12T18:00:00.000Z",
      "updatedAt": "2026-08-12T18:00:01.000Z"
    }
    """#.utf8))
    let updatedRun = try JSONDecoder().decode(AgentRunItem.self, from: Data(#"""
    {
      "id": "batch-run",
      "goal": "Review independent recipient drafts",
      "acceptanceCriteria": [],
      "status": "waiting-approval",
      "riskClass": "external-action",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [
        {"id":"dragonflyoss","title":"Approve dragonflyoss","action":"send dragonflyoss draft","riskClass":"external-action","status":"rejected","requestedAt":"2026-08-12T18:00:00.000Z","decidedAt":"2026-08-12T18:01:00.000Z","decidedBy":"Avi","decisionNote":"Already in touch"},
        {"id":"neuw","title":"Approve Neuw","action":"send Neuw draft","riskClass":"external-action","status":"pending","requestedAt":"2026-08-12T18:00:01.000Z"}
      ],
      "validations": [],
      "comments": [],
      "events": [{"id":"waiting","type":"status-changed","at":"2026-08-12T18:00:00.000Z","detail":"running -> waiting-approval","data":{"to":"waiting-approval"}}],
      "createdAt": "2026-08-12T18:00:00.000Z",
      "updatedAt": "2026-08-12T18:01:00.000Z"
    }
    """#.utf8))

    func queueItem(_ approval: AgentRunApprovalItem) -> ApprovalItem {
      ApprovalItem(
        title: approval.title,
        status: approval.status,
        todo: nil,
        level: nil,
        file: root.appendingPathComponent(".org2/runs/batch-run.org2").path,
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
        runId: waitingRun.id,
        runGoal: waitingRun.goal,
        runStatus: waitingRun.status,
        runPendingApprovalCount: waitingRun.pendingApprovalCount,
        runApprovalCount: waitingRun.approvals.count
      )
    }

    let dragonflyoss = queueItem(try XCTUnwrap(waitingRun.approvals.first))
    let neuw = queueItem(try XCTUnwrap(waitingRun.approvals.last))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([waitingRun])
    store.replaceApprovalItemsForTesting([dragonflyoss, neuw])
    store.agentRunApprovalDecisionForTesting = { _, approvalID, decision, _ in
      XCTAssertEqual(approvalID, "dragonflyoss")
      XCTAssertEqual(decision, "rejected")
      return updatedRun
    }

    await store.rejectApproval(dragonflyoss, endStatus: .canceled, reason: "Already in touch")

    XCTAssertEqual(store.agentRuns.first?.status, "waiting-approval")
    XCTAssertEqual(store.approvalItems.map(\.id), [neuw.id])
  }

  @MainActor
  func testFinishedRunQueueCleanupImmediatelyRemovesAllOfItsApprovalRows() throws {
    let run = try makeRun(status: "completed", pendingApproval: true)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.replaceAgentRunsForTesting([run])
    let approval = try XCTUnwrap(run.approvals.first)
    let queueItem = ApprovalItem(
      title: approval.title,
      status: approval.status,
      todo: nil,
      level: nil,
      file: "/tmp/corpus/.org2/runs/\(run.id).org2",
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
      runPendingApprovalCount: 1,
      runApprovalCount: 1
    )
    store.replaceApprovalItemsForTesting([queueItem])
    store.selectApprovalItem(queueItem)

    store.removeFinishedRunApprovalsFromQueue(run.id)

    XCTAssertFalse(store.approvalItems.contains(where: { $0.runId == run.id }))
    XCTAssertNotEqual(store.selectedApprovalItemID, queueItem.id)
  }

  @MainActor
  func testMarkingRunApprovalDoneElsewhereCancelsOnlyThatApproval() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-approval-external-completion-\(UUID().uuidString)", isDirectory: true)
    let waitingRun = try makeRun(
      id: "external-run",
      goal: "Publish the already-sent report",
      status: "waiting-approval",
      approvalStatuses: ["pending", "pending"]
    )
    let updatedRun = try makeRun(
      id: waitingRun.id,
      goal: waitingRun.goal,
      status: "waiting-approval",
      approvalStatuses: ["canceled", "pending"]
    )
    let approval = try XCTUnwrap(waitingRun.approvals.first)
    let sibling = try XCTUnwrap(waitingRun.approvals.last)
    func queueItem(_ candidate: AgentRunApprovalItem) -> ApprovalItem {
      ApprovalItem(
        title: candidate.title,
        status: candidate.status,
        todo: nil,
        level: nil,
        file: root.appendingPathComponent(".org2/runs/\(waitingRun.id).org2").path,
        line: 1,
        idValue: candidate.id,
        properties: [:],
        body: candidate.action,
        tags: [],
        kind: "run",
        approvalId: candidate.id,
        fingerprint: candidate.fingerprint,
        action: candidate.action,
        riskClass: candidate.riskClass,
        requestedRole: candidate.requestedRole,
        requestedFrom: candidate.requestedFrom,
        requestedAt: candidate.requestedAt,
        runId: waitingRun.id,
        runGoal: waitingRun.goal,
        runStatus: waitingRun.status,
        runPendingApprovalCount: waitingRun.pendingApprovalCount,
        runApprovalCount: waitingRun.approvals.count
      )
    }
    let selectedItem = queueItem(approval)
    let siblingItem = queueItem(sibling)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([waitingRun])
    store.replaceApprovalItemsForTesting([selectedItem, siblingItem])
    store.agentRunExternalCompletionForTesting = { _, _ in
      XCTFail("An item-scoped external completion must not complete the containing run")
      return updatedRun
    }
    store.agentRunApprovalDecisionForTesting = { runID, approvalID, decision, note in
      XCTAssertEqual(runID, waitingRun.id)
      XCTAssertEqual(approvalID, approval.id)
      XCTAssertEqual(decision, "canceled")
      XCTAssertNil(note)
      return updatedRun
    }

    await store.completeApprovalExternally(
      selectedItem,
      summary: "The report was sent from Gmail."
    )

    XCTAssertEqual(store.agentRuns.first?.status, "waiting-approval")
    XCTAssertFalse(store.approvalItems.contains(where: { $0.id == selectedItem.id }))
    XCTAssertTrue(store.approvalItems.contains(where: { $0.id == siblingItem.id }))
    XCTAssertNil(store.errorText, store.statusText)
  }

  func testRevisionFeedbackNormalizationAndResumableBoundary() throws {
    XCTAssertNil(WorkspaceStore.normalizedApprovalRevisionFeedback("   \n"))
    XCTAssertEqual(
      WorkspaceStore.normalizedApprovalRevisionFeedback(
        "  Lead with the recommendation and remove the internal acronym.  "
      ),
      "Lead with the recommendation and remove the internal acronym."
    )

    let data = Data(#"""
    {
      "id": "revision-run",
      "goal": "Prepare launch copy",
      "acceptanceCriteria": [],
      "status": "blocked",
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [{
        "id": "review-copy",
        "title": "Review launch copy",
        "action": "send launch copy",
        "riskClass": "external-action",
        "status": "revised",
        "requestedAt": "2026-07-27T10:01:00.000Z",
        "decidedAt": "2026-07-27T10:02:00.000Z",
        "decisionNote": "Lead with the recommendation."
      }],
      "validations": [],
      "comments": [],
      "events": [
        {
          "id": "waiting",
          "type": "status-changed",
          "at": "2026-07-27T10:01:00.000Z",
          "detail": "running -> waiting-approval"
        }
      ],
      "createdAt": "2026-07-27T10:00:00.000Z",
      "updatedAt": "2026-07-27T10:02:00.000Z",
      "blockedReason": "One or more approvals were not approved"
    }
    """#.utf8)
    let run = try JSONDecoder().decode(AgentRunItem.self, from: data)
    XCTAssertEqual(run.currentApprovalBoundary.map(\.id), ["review-copy"])
    XCTAssertEqual(run.resumableRevisionApproval?.id, "review-copy")
  }

  @MainActor
  func testRunCenterDecisionUsesAssignedReviewerAndClearsUnifiedQueueItem() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-center-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    _ = try await cli.run([
      "run", "create", "--id", "run-center-approval", "--goal", "Release three drafts",
      "--dir", root.path, "--json"
    ])
    _ = try await cli.run(["run", "start", "run-center-approval", "--dir", root.path, "--json"])
    for index in 1...3 {
      _ = try await cli.run([
        "run", "approval-request", "run-center-approval",
        "--title", "Approve draft \(index)", "--action", "send draft \(index)",
        "--risk", "external-action", "--role", "approver", "--from", "Avi",
        "--dir", root.path, "--json"
      ])
    }

    let store = WorkspaceStore(cli: cli)
    store.setCorpusRoot(root, persistsDefault: false)
    await store.refreshAgentRuns()
    await store.refreshApprovals()

    let run = try XCTUnwrap(store.agentRuns.first(where: { $0.id == "run-center-approval" }))
    let approval = try XCTUnwrap(run.approvals.first)
    let queueItemID = "run:\(run.id):\(approval.id)"
    XCTAssertEqual(run.pendingApprovalCount, 3)
    XCTAssertTrue(store.approvalItems.contains(where: { $0.id == queueItemID }))

    await store.decideAgentRunApproval(run, approval: approval, decision: "approved")

    let updatedRun = try XCTUnwrap(store.agentRuns.first(where: { $0.id == run.id }))
    XCTAssertEqual(updatedRun.pendingApprovalCount, 2)
    XCTAssertEqual(updatedRun.approvals.first?.status, "approved")
    XCTAssertFalse(store.approvalItems.contains(where: { $0.id == queueItemID }))
  }

  func testRunApprovalDecisionActorUsesAssignedReviewerWhenPresent() {
    XCTAssertEqual(WorkspaceStore.agentRunApprovalDecisionActor(requestedFrom: " Avi "), "Avi")
    XCTAssertEqual(WorkspaceStore.agentRunApprovalDecisionActor(requestedFrom: "  "), "Org2Workspace")
    XCTAssertEqual(WorkspaceStore.agentRunApprovalDecisionActor(requestedFrom: nil), "Org2Workspace")
  }

  func testRecognizesPDFRunArtifactsFromExtensionOrMediaType() throws {
    let extensionArtifact = try JSONDecoder().decode(
      AgentRunArtifactItem.self,
      from: Data(#"{"id":"pdf","path":"compiled/BRIEF.PDF","role":"export","createdAt":"2026-07-14T00:00:00.000Z"}"#.utf8)
    )
    let mediaTypeArtifact = try JSONDecoder().decode(
      AgentRunArtifactItem.self,
      from: Data(#"{"id":"pdf","path":"compiled/brief","role":"export","mediaType":"application/pdf; charset=binary","createdAt":"2026-07-14T00:00:00.000Z"}"#.utf8)
    )
    let textArtifact = try JSONDecoder().decode(
      AgentRunArtifactItem.self,
      from: Data(#"{"id":"note","path":"compiled/brief.org2","role":"draft","mediaType":"text/plain","createdAt":"2026-07-14T00:00:00.000Z"}"#.utf8)
    )

    XCTAssertTrue(extensionArtifact.isPDF)
    XCTAssertTrue(mediaTypeArtifact.isPDF)
    XCTAssertFalse(textArtifact.isPDF)
  }

  func testFindsOpenClawExecApprovalIDInLifecycleComment() throws {
    let data = Data(#"""
    {
      "id": "run-1",
      "goal": "Prepare an external message",
      "acceptanceCriteria": [],
      "status": "waiting-approval",
      "riskClass": "external-action",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [],
      "validations": [],
      "comments": [{
        "id": "comment-1",
        "author": "org2-lifecycle",
        "body": "OPENCLAW_KEY: draft:exec:default:IC_example123\nOPENCLAW_KIND: external-draft",
        "createdAt": "2026-07-20T00:00:00.000Z"
      }],
      "events": [],
      "createdAt": "2026-07-20T00:00:00.000Z",
      "updatedAt": "2026-07-20T00:00:00.000Z"
    }
    """#.utf8)

    let run = try JSONDecoder().decode(AgentRunItem.self, from: data)
    XCTAssertEqual(run.openClawExecApprovalID, "IC_example123")
  }

  @MainActor
  func testRunsAndReviewSearchFocusSignalsBothPossibleVisibleTabs() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))

    store.focusRunsAndReviewFilter()

    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.agentRunFilterFocusToken, 1)
    XCTAssertEqual(store.approvalFilterFocusToken, 1)
  }

  func testDecodesPlainTextWorkflowCatalog() throws {
    let data = Data(#"""
    {
      "schema": "org2:workflow-list:v1",
      "workflows": [{
        "id": "weekly-review",
        "version": "1.2.0",
        "title": "Weekly review",
        "description": "Prepare a cited weekly review.",
        "state": "active",
        "instructions": "Prepare {{week}}.",
        "riskClass": "local-draft",
        "destinationRef": "builtin.claude",
        "model": "claude-opus-4-1",
        "reasoningEffort": "high",
        "capabilities": ["agent-context"],
        "inputs": [{"id":"week","description":"Week","required":true,"default":"current"}],
        "triggers": [{"id":"schedule","type":"schedule","enabled":true,"schedule":"0 9 * * 1","timezone":"America/Los_Angeles"}],
        "file": "/tmp/workflows/weekly-review.org2",
        "legacyLocation": false,
        "createdAt": "2026-07-17T00:00:00.000Z",
        "updatedAt": "2026-07-17T00:00:00.000Z"
      }]
    }
    """#.utf8)

    let workflow = try XCTUnwrap(JSONDecoder().decode(AgentWorkflowListPayload.self, from: data).workflows.first)
    XCTAssertEqual(workflow.id, "weekly-review")
    XCTAssertEqual(workflow.inputs.first?.default, "current")
    XCTAssertEqual(workflow.destinationRef, "builtin.claude")
    XCTAssertEqual(workflow.model, "claude-opus-4-1")
    XCTAssertEqual(workflow.reasoningEffort, "high")
    XCTAssertEqual(workflow.scheduleSummary, "0 9 * * 1 · America/Los_Angeles")
    XCTAssertFalse(workflow.legacyLocation)
  }

  func testDecodesDueAutomationAndLegacyScheduleCompatibility() throws {
    let dueData = Data(#"""
    {
      "schema": "org2:automation-due-list:v1",
      "now": "2026-08-31T16:00:00.000Z",
      "hostRef": "press-trial",
      "due": [{
        "workflowId": "weekly-review",
        "title": "Weekly review",
        "destinationRef": "builtin.codex",
        "model": "gpt-5.6-sol",
        "reasoningEffort": "xhigh",
        "agentRef": "product-research",
        "triggerId": "schedule",
        "schedule": "0 9 * * 1",
        "timezone": "America/Los_Angeles",
        "scheduledFor": "2026-08-31T16:00:00.000Z"
      }],
      "skipped": []
    }
    """#.utf8)
    let payload = try JSONDecoder().decode(AgentWorkflowDueListPayload.self, from: dueData)
    let due = try XCTUnwrap(payload.due.first)
    XCTAssertEqual(payload.hostRef, "press-trial")
    XCTAssertEqual(due.id, "weekly-review:schedule:2026-08-31T16:00:00.000Z")
    XCTAssertEqual(due.destinationRef, "builtin.codex")
    XCTAssertEqual(due.model, "gpt-5.6-sol")
    XCTAssertEqual(due.reasoningEffort, "xhigh")
    XCTAssertEqual(due.agentRef, "product-research")

    let legacyData = Data(#"""
    {
      "schema": "org2:workflow-list:v1",
      "workflows": [{
        "id": "legacy-review",
        "version": "1.0.0",
        "title": "Legacy review",
        "description": "Legacy schedule.",
        "state": "active",
        "instructions": "Run.",
        "riskClass": "local-draft",
        "capabilities": [],
        "inputs": [],
        "triggers": [{"id":"openclaw-schedule","type":"schedule","enabled":true,"schedule":"every 4h"}],
        "file": "/tmp/workflows/legacy-review.org2",
        "legacyLocation": false,
        "createdAt": "2026-07-17T00:00:00.000Z",
        "updatedAt": "2026-07-17T00:00:00.000Z"
      }]
    }
    """#.utf8)
    let legacy = try XCTUnwrap(JSONDecoder().decode(AgentWorkflowListPayload.self, from: legacyData).workflows.first)
    XCTAssertEqual(legacy.scheduleSummary, "every 4h")
  }

  func testAutomationIdentifierIsReadableAndAvoidsCollisions() {
    XCTAssertEqual(
      WorkspaceStore.automationIdentifier(
        title: "Weekly Product Update!",
        existingIDs: ["weekly-product-update", "weekly-product-update-2"]
      ),
      "weekly-product-update-3"
    )
    XCTAssertEqual(
      WorkspaceStore.automationIdentifier(title: "🚀", existingIDs: []),
      "automation"
    )
  }

  func testAutomationScheduleDraftRecognizesCommonSchedulesAndPreservesAdvancedCron() {
    let weekly = AutomationScheduleDraft(expression: "0 9 * * 1")
    XCTAssertEqual(weekly.frequency, .weekly)
    XCTAssertEqual(weekly.weekday, 1)
    XCTAssertEqual(weekly.hour, 9)
    XCTAssertEqual(weekly.expression, "0 9 * * 1")
    XCTAssertTrue(weekly.summary.contains("Monday"))

    var interval = AutomationScheduleDraft(expression: "every 4h")
    XCTAssertEqual(interval.frequency, .interval)
    XCTAssertEqual(interval.intervalHours, 4)
    interval.intervalHours = 6
    XCTAssertEqual(interval.expression, "every 6h")

    let weekdays = AutomationScheduleDraft(expression: "30 8 * * 1-5")
    XCTAssertEqual(weekdays.frequency, .weekdays)
    XCTAssertEqual(weekdays.expression, "30 8 * * 1-5")

    let advanced = AutomationScheduleDraft(expression: "15 10 1,15 * *")
    XCTAssertEqual(advanced.frequency, .advanced)
    XCTAssertEqual(advanced.expression, "15 10 1,15 * *")
  }

  func testAutomationSchedulerOwnershipPresentationExplainsLocalAndRemoteOwners() {
    let remote = AutomationSchedulerOwnershipPresentation(
      ownerHostRef: "press-trial",
      currentHostRef: "desktop",
      corpusName: "Avi Press"
    )
    XCTAssertEqual(remote.title, "Scheduler: press-trial")
    XCTAssertEqual(
      remote.detail,
      "press-trial runs scheduled automations for Avi Press. This desktop will not."
    )
    XCTAssertEqual(remote.systemImage, "server.rack")
    XCTAssertFalse(remote.isCurrentHost)

    let local = AutomationSchedulerOwnershipPresentation(
      ownerHostRef: "desktop",
      currentHostRef: "desktop",
      corpusName: "Avi Press"
    )
    XCTAssertEqual(local.title, "Scheduler: This Mac")
    XCTAssertEqual(local.detail, "This Mac runs scheduled automations for Avi Press.")
    XCTAssertEqual(local.systemImage, "desktopcomputer")
    XCTAssertTrue(local.isCurrentHost)
  }

  func testCompletedRunPresentsOutcomeAndCollapsesSupersededValidationResults() throws {
    let data = Data(#"""
    {
      "id": "meeting-run",
      "goal": "Process the meeting",
      "acceptanceCriteria": [],
      "status": "completed",
      "riskClass": "local-draft",
      "workflowId": "meeting-to-controlled-execution",
      "workflowVersion": "1.0.0",
      "capabilities": [],
      "context": [],
      "plan": [
        {"id":"summarize","title":"Summarize","kind":"agent","status":"completed"},
        {"id":"publish","title":"Publish","kind":"tool","status":"skipped"}
      ],
      "artifacts": [{"id":"pdf","path":"views/meeting/publication.pdf","role":"export","createdAt":"2026-07-14T00:00:00.000Z"}],
      "approvals": [],
      "validations": [
        {"id":"old","name":"artifact-files-present","status":"skipped","checkedAt":"2026-07-14T00:00:00.000Z"},
        {"id":"new","name":"artifact-files-present","status":"passed","checkedAt":"2026-07-14T00:01:00.000Z"}
      ],
      "comments": [],
      "events": [],
      "outcome": {
        "summary": "Prepared the meeting briefing and publication PDF.",
        "highlights": ["Captured the decisions."],
        "nextActions": []
      },
      "createdAt": "2026-07-14T00:00:00.000Z",
      "updatedAt": "2026-07-14T00:01:00.000Z"
    }
    """#.utf8)

    let run = try JSONDecoder().decode(AgentRunItem.self, from: data)
    XCTAssertEqual(run.humanOutcomeSummary, "Prepared the meeting briefing and publication PDF.")
    XCTAssertEqual(run.progressText, "1 completed · 1 skipped")
    XCTAssertEqual(run.workflowDisplayName, "Meeting To Controlled Execution")
    XCTAssertEqual(run.artifacts.first?.displayTitle, "Publication PDF")
    XCTAssertEqual(run.latestValidations.map(\.status), ["passed"])
    XCTAssertFalse(run.needsAttention)
    XCTAssertEqual(run.humanNextAction, "No action required")
  }

  func testRunCenterKeepsMultipleMeetingOutcomesIndependentlyVisible() throws {
    let meetingRef = "meetings/2026-07-17-080044-dev-standup.org2"
    let envelope = try makeRun(
      id: "meeting-workflow",
      goal: "Turn a provenance-preserving meeting capture into cited decisions and reviewable tasks",
      status: "blocked",
      workflowId: "meeting-to-controlled-execution",
      contextRefs: [meetingRef]
    )
    let feedbackDigest = try makeRun(
      id: "feedback-digest",
      goal: "Set up the Tuesday/Friday customer-feedback digest",
      status: "blocked",
      parentRunId: envelope.id
    )
    let runnerDocs = try makeRun(
      id: "runner-docs",
      goal: "Document hosted versus self-hosted runner recovery",
      status: "completed",
      contextRefs: [meetingRef]
    )

    let runs = [feedbackDigest, envelope, runnerDocs]
    let sections = RunCenterPresentation.sections(
      for: AgentRunScope.all.entries(in: runs),
      allRuns: runs
    )

    let section = try XCTUnwrap(sections.first)
    XCTAssertEqual(sections.count, 1)
    XCTAssertEqual(section.sourceMeeting?.displayTitle, "Dev Standup · 2026-07-17")
    XCTAssertEqual(section.entries.map(\.id), ["feedback-digest", "meeting-workflow", "runner-docs"])
    XCTAssertEqual(section.entries.map(\.run.goal), [
      "Set up the Tuesday/Friday customer-feedback digest",
      "Turn a provenance-preserving meeting capture into cited decisions and reviewable tasks",
      "Document hosted versus self-hosted runner recovery",
    ])
    XCTAssertEqual(section.entries.map(\.run.status), ["blocked", "blocked", "completed"])
  }

  func testRunCenterResolvesSharedAncestorContextOnceForLargeRunFamilies() throws {
    let meetingRef = "meetings/2026-07-17-080044-dev-standup.org2"
    let envelope = try makeRun(
      id: "meeting-workflow",
      goal: "Process the meeting",
      contextRefs: [meetingRef]
    )
    let children = try (0..<1_000).map { index in
      try makeRun(
        id: "child-\(index)",
        goal: "Child outcome \(index)",
        parentRunId: envelope.id
      )
    }

    let contexts = RunCenterPresentation.sourceMeetingContextsByRunID(
      in: children + [envelope]
    )

    XCTAssertEqual(contexts.count, children.count + 1)
    XCTAssertEqual(contexts["child-999"]?.ref, meetingRef)
  }

  func testRunCenterBuildsLargeUngroupedSectionWithinInteractiveBudget() throws {
    let runs = try (0..<4_205).map { index in
      try makeRun(
        id: "completed-\(index)",
        goal: "Completed outcome \(index)",
        status: "completed"
      )
    }
    let entries = AgentRunScope.all.entries(in: runs)
    let clock = ContinuousClock()
    let startedAt = clock.now

    let sections = RunCenterPresentation.sections(for: entries, allRuns: runs)

    let elapsed = startedAt.duration(to: clock.now)
    XCTAssertEqual(sections.count, 1)
    XCTAssertEqual(sections[0].entries.count, runs.count)
    XCTAssertLessThan(elapsed, .milliseconds(80), "Run scope switching must stay within an interactive frame budget")
  }

  func testRunCenterBoundsInitialRowsWithoutLosingSectionOrder() throws {
    let meetingRef = "meetings/2026-08-17-performance.org2"
    let meetingRuns = try (0..<200).map { index in
      try makeRun(
        id: "meeting-\(index)",
        goal: "Meeting outcome \(index)",
        status: "completed",
        contextRefs: [meetingRef]
      )
    }
    let ungroupedRuns = try (0..<200).map { index in
      try makeRun(
        id: "other-\(index)",
        goal: "Other outcome \(index)",
        status: "completed"
      )
    }
    let runs = meetingRuns + ungroupedRuns
    let sections = RunCenterPresentation.sections(
      for: AgentRunScope.all.entries(in: runs),
      allRuns: runs
    )

    let initialSections = RunCenterPresentation.prefixSections(sections, limit: 250)

    XCTAssertEqual(initialSections.flatMap(\.entries).count, 250)
    XCTAssertEqual(initialSections.map(\.id), ["meeting:\(meetingRef)", "other"])
    XCTAssertEqual(initialSections[0].entries.count, 200)
    XCTAssertEqual(initialSections[1].entries.count, 50)
    XCTAssertEqual(initialSections[1].entries.last?.id, "other-49")
  }

  func testAgentRunTimestampUsesLocalReadableTime() throws {
    let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let locale = Locale(identifier: "en_US")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let now = try XCTUnwrap(AgentRunTimestampPresentation.date(from: "2026-07-15T21:19:42.000Z"))

    let display = AgentRunTimestampPresentation.displayText(
      for: "2026-07-15T18:33:41.286Z",
      now: now,
      calendar: calendar,
      locale: locale,
      timeZone: timeZone
    )
    XCTAssertTrue(display.hasPrefix("today at "))
    XCTAssertTrue(display.contains("11:33"), display)

    let detail = AgentRunTimestampPresentation.detailText(
      for: "2026-07-15T18:33:41.286Z",
      locale: locale,
      timeZone: timeZone
    )
    XCTAssertTrue(detail.contains("11:33:41"), detail)
    XCTAssertTrue(detail.contains("PDT"), detail)
  }

  func testAgentRunTimestampSupportsSecondsAndFallsBackForInvalidInput() {
    XCTAssertNotNil(AgentRunTimestampPresentation.date(from: "2026-07-15T18:33:41Z"))
    XCTAssertEqual(
      AgentRunTimestampPresentation.displayText(for: "not-a-timestamp"),
      "not-a-timestamp"
    )
  }

  func testAgentRunClarificationDistinguishesActionableAndLegacyFallbackReasons() throws {
    XCTAssertEqual(
      try makeRun(status: "blocked", blockedReason: "Which reporting period should this cover?").clarificationPrompt,
      "Which reporting period should this cover?"
    )
    XCTAssertNil(
      try makeRun(status: "blocked", blockedReason: "Blocked pending clarification").clarificationPrompt
    )
    XCTAssertNil(try makeRun(status: "running", blockedReason: nil).clarificationPrompt)
  }

  func testAgentRunClarificationResponseRequiresText() {
    XCTAssertNil(WorkspaceStore.normalizedAgentRunClarificationResponse(" \n\t"))
    XCTAssertEqual(
      WorkspaceStore.normalizedAgentRunClarificationResponse("  Use Q3 actuals. \n"),
      "Use Q3 actuals."
    )
  }

  func testAgentRunClarificationReplyPhasesHaveProminentOrderedProgressText() {
    let phases = AgentRunClarificationReplyPhase.allCases
    XCTAssertEqual(phases, [.recording, .resuming, .handingOff])
    XCTAssertEqual(phases.map(\.stepLabel), ["Step 1 of 3", "Step 2 of 3", "Step 3 of 3"])
    for phase in phases {
      XCTAssertFalse(phase.title.isEmpty)
      XCTAssertFalse(phase.detail.isEmpty)
      XCTAssertTrue(phase.buttonTitle.hasSuffix("…"))
    }
    XCTAssertEqual(Set(phases.map(\.title)).count, phases.count)
  }

  @MainActor
  func testReplyAndResumeExposesItsCurrentPhaseUntilTheRequestFinishes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-clarification-phase-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let run = try makeRun(
      id: "blocked-run",
      status: "blocked",
      blockedReason: "Which reporting period should this cover?"
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([run])
    var phaseDuringRequest: AgentRunClarificationReplyPhase?
    var mutatingDuringRequest = false
    store.agentRunClarificationReplyForTesting = { [weak store] requestedRun, response in
      phaseDuringRequest = store?.agentRunClarificationPhases[requestedRun.id]
      mutatingDuringRequest = store?.mutatingAgentRunIDs.contains(requestedRun.id) ?? false
      XCTAssertEqual(response, "Use Q3 actuals.")
      throw OpenClawGatewayError.gateway(code: "INTERNAL", message: "gateway unavailable")
    }

    let succeeded = await store.respondToAgentRunClarification(run, response: "  Use Q3 actuals. ")

    XCTAssertFalse(succeeded)
    XCTAssertEqual(phaseDuringRequest, .recording)
    XCTAssertTrue(mutatingDuringRequest)
    XCTAssertNil(store.agentRunClarificationPhases[run.id])
    XCTAssertFalse(store.mutatingAgentRunIDs.contains(run.id))
    XCTAssertEqual(store.statusText, "Clarification response failed")
  }

  func testAgentRunClarificationFallbackOnlyAcceptsAnUnavailableGatewayMethod() {
    XCTAssertTrue(WorkspaceStore.shouldUseLocalClarificationResumeFallback(
      for: OpenClawGatewayError.gateway(
        code: "METHOD_NOT_FOUND",
        message: "Unknown method: org2.run.replyAndResume"
      )
    ))
    XCTAssertTrue(WorkspaceStore.shouldUseLocalClarificationResumeFallback(
      for: OpenClawGatewayError.gateway(
        code: "INVALID_REQUEST",
        message: "Method org2.run.replyAndResume is not registered"
      )
    ))
    XCTAssertTrue(WorkspaceStore.shouldUseLocalClarificationResumeFallback(
      for: OpenClawGatewayError.gateway(
        code: "INVALID_REQUEST",
        message: "missing scope: operator.admin"
      )
    ))
    XCTAssertFalse(WorkspaceStore.shouldUseLocalClarificationResumeFallback(
      for: OpenClawGatewayError.gateway(
        code: "ORG2_RUN_ERROR",
        message: "Org2 corpus mismatch"
      )
    ))
    XCTAssertFalse(WorkspaceStore.shouldUseLocalClarificationResumeFallback(
      for: OpenClawGatewayError.connection("offline")
    ))
  }

  func testAgentRunApprovalContinuationFallbackOnlyAcceptsAnUnavailableGatewayMethod() {
    XCTAssertTrue(WorkspaceStore.shouldUseLocalApprovalContinuationFallback(
      for: OpenClawGatewayError.gateway(
        code: "METHOD_NOT_FOUND",
        message: "Unknown method: org2.run.resumeApproved"
      )
    ))
    XCTAssertTrue(WorkspaceStore.shouldUseLocalApprovalContinuationFallback(
      for: OpenClawGatewayError.gateway(
        code: "INVALID_REQUEST",
        message: "Method org2.run.resumeApproved is not registered"
      )
    ))
    XCTAssertFalse(WorkspaceStore.shouldUseLocalApprovalContinuationFallback(
      for: OpenClawGatewayError.gateway(
        code: "ORG2_RUN_ERROR",
        message: "Org2 corpus mismatch"
      )
    ))
    XCTAssertFalse(WorkspaceStore.shouldUseLocalApprovalContinuationFallback(
      for: OpenClawGatewayError.connection("offline")
    ))
  }

  func testAgentRunApprovalFallbackPreservesRunAndApprovedBoundary() throws {
    let run = try makeRun(
      status: "running",
      comments: ["OPENCLAW_SESSION: agent:scarf-support:cron:job-1"]
    )
    let prompt = WorkspaceStore.agentRunApprovalContinuationPrompt(run: run)
    XCTAssertTrue(prompt.contains("ORG2_RUN_ID: run-1"))
    XCTAssertTrue(prompt.contains("ORG2_RUN_RESUME: approval-decided"))
    XCTAssertTrue(prompt.contains("Do not create a replacement run or request the same approval again"))
    XCTAssertTrue(prompt.contains("Skip every rejected or canceled action"))
  }

  func testAgentRunClarificationFallbackPreservesRunResponseAndKnownSession() throws {
    let run = try makeRun(
      status: "blocked",
      blockedReason: "Which plan should we use?",
      comments: [
        "OPENCLAW_KEY: turn:one\nOPENCLAW_SESSION: unknown",
        "OPENCLAW_KEY: turn:two\nOPENCLAW_SESSION: agent:scarf-support:cron:job-1"
      ]
    )

    XCTAssertEqual(run.openClawSessionKey, "agent:scarf-support:cron:job-1")
    let prompt = WorkspaceStore.agentRunClarificationContinuationPrompt(
      run: run,
      response: "  Use the current plan.  "
    )
    XCTAssertTrue(prompt.contains("ORG2_RUN_ID: run-1"))
    XCTAssertTrue(prompt.contains("Clarification: Which plan should we use?"))
    XCTAssertTrue(prompt.contains("User response:\nUse the current plan."))
    XCTAssertTrue(prompt.contains("do not create a replacement run"))
  }

  func testCanceledRunDoesNotNeedAttentionWhenOldReviewSignalsRemain() throws {
    let run = try makeRun(
      status: "canceled",
      validationStatus: "failed",
      reviewRequired: true
    )

    XCTAssertFalse(run.needsAttention)
    XCTAssertTrue(run.isFinished)
  }

  func testRunningRunDoesNotNeedAttentionWhileReviewSignalsRemain() throws {
    let run = try makeRun(
      status: "running",
      validationStatus: "warning",
      reviewRequired: true
    )

    XCTAssertFalse(run.needsAttention)
    XCTAssertFalse(run.isFinished)
    XCTAssertEqual(AgentRunScope.active.entries(in: [run]).map(\.id), [run.id])
    XCTAssertTrue(AgentRunScope.attention.entries(in: [run]).isEmpty)
  }

  func testCompletedRunDoesNotNeedAttentionWhenOldReviewSignalsRemain() throws {
    let run = try makeRun(
      status: "completed",
      validationStatus: "warning",
      reviewRequired: true,
      pendingApproval: true
    )

    XCTAssertFalse(run.needsAttention)
    XCTAssertTrue(run.isFinished)
    XCTAssertEqual(run.attentionValidations.map(\.status), ["warning"])
    XCTAssertTrue(run.actionablePendingApprovals.isEmpty)
    XCTAssertEqual(run.retainedPendingApprovals.map(\.id), ["approval-1"])
  }

  func testRunCenterScopeCountsUseTheSamePredicatesAsTheirLists() throws {
    let runs = try [
      makeRun(id: "queued", goal: "Queued work", status: "queued"),
      makeRun(id: "approval", goal: "Approval work", status: "waiting-approval"),
      makeRun(id: "blocked", goal: "Blocked work", status: "blocked"),
      makeRun(id: "failed", goal: "Failed work", status: "failed"),
      makeRun(
        id: "completed",
        goal: "Completed work",
        status: "completed",
        validationStatus: "warning",
        reviewRequired: true
      ),
      makeRun(id: "canceled", goal: "Canceled work", status: "canceled", validationStatus: "failed", reviewRequired: true),
    ]

    XCTAssertEqual(AgentRunScope.active.count(in: runs), 1)
    XCTAssertEqual(AgentRunScope.attention.count(in: runs), 3)
    XCTAssertEqual(AgentRunScope.completed.count(in: runs), 2)
    XCTAssertEqual(AgentRunScope.all.count(in: runs), 6)
  }

  func testNeedsAttentionCollapsesRepeatedFailuresAndUsesLatestSeriesState() throws {
    let oldFailure = try makeRun(
      id: "heartbeat-1",
      goal: "Agent heartbeat: MeetingBot",
      status: "failed",
      updatedAt: "2026-07-16T18:00:00.000Z"
    )
    let latestFailure = try makeRun(
      id: "heartbeat-2",
      goal: "Agent heartbeat: MeetingBot",
      status: "failed",
      updatedAt: "2026-07-16T18:15:00.000Z"
    )

    let failedEntries = AgentRunScope.attention.entries(in: [oldFailure, latestFailure])
    XCTAssertEqual(failedEntries.map(\.id), ["heartbeat-2"])
    XCTAssertEqual(failedEntries.first?.representedFailureCount, 2)
    XCTAssertEqual(AgentRunScope.all.count(in: [oldFailure, latestFailure]), 2)

    let successfulRetry = try makeRun(
      id: "heartbeat-3",
      goal: "Agent heartbeat: MeetingBot",
      status: "completed",
      updatedAt: "2026-07-16T18:30:00.000Z"
    )
    XCTAssertTrue(AgentRunScope.attention.entries(in: [oldFailure, latestFailure, successfulRetry]).isEmpty)
    XCTAssertEqual(AgentRunScope.all.count(in: [oldFailure, latestFailure, successfulRetry]), 3)
  }

  @MainActor
  func testMeetingSourceContextOpensInsideRunCenter() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-meeting-context-\(UUID().uuidString)", isDirectory: true)
    let meetings = root.appendingPathComponent("meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let meeting = meetings.appendingPathComponent("2026-07-17-080044-dev-standup.org2")
    try "#+TITLE: Meeting: Dev Standup\n".write(to: meeting, atomically: true, encoding: .utf8)
    let run = try makeRun(contextRefs: ["meetings/2026-07-17-080044-dev-standup.org2"])
    let context = try XCTUnwrap(run.sourceMeetingContext)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)

    store.openAgentRunContext(context)

    XCTAssertEqual(store.selectedLocation?.file, meeting.path)
    XCTAssertEqual(store.selectedSurface, .approvals)
  }

  @MainActor
  func testOpenAgentRunRecordUsesInAppDetailWithoutLeavingRunsSurface() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-record-navigation-\(UUID().uuidString)", isDirectory: true)
    let runs = root.appendingPathComponent(".org2/runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let record = runs.appendingPathComponent("run-1.org2")
    try "#+TITLE: Durable run\n\n* Plan\n- Review the source\n".write(
      to: record,
      atomically: true,
      encoding: .utf8
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.openAgentRunRecord(try makeRun())

    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.selectedLocation?.file, record.path)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
  }

  @MainActor
  func testAskAIAboutAgentRunStartsChatWithDurableRecordContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-ask-ai-\(UUID().uuidString)", isDirectory: true)
    let runs = root.appendingPathComponent(".org2/runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "#+TITLE: Durable run\n".write(
      to: runs.appendingPathComponent("run-1.org2"),
      atomically: true,
      encoding: .utf8
    )

    let suiteName = "org2-run-ask-ai-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.openClawRemoteCorpusPath = "/remote/org2"

    store.askAIChatAboutAgentRun(try makeRun())

    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.aiChatThreads.first?.title, "Run: Prepare a cited briefing")
    XCTAssertEqual(
      store.aiChatDraft,
      "Use agent run “Prepare a cited briefing” at /remote/org2/.org2/runs/run-1.org2:1 as context.\n\n"
    )
    XCTAssertEqual(store.aiChatStatusText, "Added .org2/runs/run-1.org2:1 to OpenClaw")
  }

  @MainActor
  func testAskAIAboutDispatchedAgentRunKeepsContextPillConcise() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-long-context-title-\(UUID().uuidString)", isDirectory: true)
    let runs = root.appendingPathComponent(".org2/runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "#+TITLE: Durable run\n".write(
      to: runs.appendingPathComponent("run-1.org2"),
      atomically: true,
      encoding: .utf8
    )
    let run = try makeRun(goal: """
    Execute this newly approved engineering task exactly once.

    Task: Reduce OpenOrg per-turn context overhead across persistent Codex/OpenClaw sessions, stateless provider fallbacks, and shared AI rooms; add token telemetry and regression budgets.
    Repository: https://github.com/aviaviavi/org2
    Source: file:daily/2026-09-18.org::1
    """)
    let suiteName = "org2-run-long-context-title-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.openClawRemoteCorpusPath = "/remote/org2"

    store.askAIChatAboutAgentRun(run)

    let presentation = AIChatContextPresentation(store.aiChatDraft)
    let title = try XCTUnwrap(presentation.contexts.first?.title)
    XCTAssertTrue(title.hasPrefix("Reduce OpenOrg per-turn context overhead"))
    XCTAssertTrue(title.hasSuffix("…"))
    XCTAssertLessThanOrEqual(title.count, 80)
    XCTAssertFalse(title.contains("Repository:"))
    XCTAssertFalse(title.contains("Execute this newly approved"))
    XCTAssertEqual(presentation.userText, "")
    let threadTitle = try XCTUnwrap(store.aiChatThreads.first?.title)
    XCTAssertTrue(threadTitle.hasPrefix("Run: Reduce OpenOrg per-turn context overhead"))
    XCTAssertLessThanOrEqual(threadTitle.count, 80)
  }

  @MainActor
  func testSelectedRunsStartFreshAIThreadWithEveryRunAsContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-multi-context-\(UUID().uuidString)", isDirectory: true)
    let runsDirectory = root.appendingPathComponent(".org2/runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try makeRun(id: "run-1", goal: "Prepare the launch brief")
    let second = try makeRun(id: "run-2", goal: "Review the launch risks")
    for run in [first, second] {
      try "#+TITLE: \(run.goal)\n".write(
        to: runsDirectory.appendingPathComponent("\(run.id).org2"),
        atomically: true,
        encoding: .utf8
      )
    }

    let suiteName = "org2-run-multi-context-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.replaceAgentRunsForTesting([first, second])
    store.createAIChatThread(runtime: .codex)

    let visibleIDs = [first.id, second.id]
    store.handleAgentRunClick(first, visibleRunIDs: visibleIDs)
    store.handleAgentRunClick(second, visibleRunIDs: visibleIDs, modifiers: [.command])
    store.startNewAIThreadFromAgentRunSelection(including: second)

    XCTAssertEqual(store.aiChatThreads.count, 2)
    XCTAssertEqual(store.selectedAIChatThread?.runtime, .codex)
    XCTAssertEqual(store.selectedAIChatThread?.title, "Context: 2 selected items")
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    let presentation = AIChatContextPresentation(store.aiChatDraft)
    XCTAssertEqual(presentation.contexts.map(\.title), [
      "Prepare the launch brief",
      "Review the launch risks"
    ])
    XCTAssertEqual(presentation.contexts.map(\.reference), [
      "/remote/org2/.org2/runs/run-1.org2:1",
      "/remote/org2/.org2/runs/run-2.org2:1"
    ])
  }

  @MainActor
  func testSelectedApprovalsStartFreshAIThreadWithEveryApprovalAsContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-approval-multi-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("approvals.org2")
    try "* TODO Approve launch\n\n* TODO Approve pricing\n".write(
      to: note,
      atomically: true,
      encoding: .utf8
    )
    let first = ApprovalItem(
      title: "Approve launch",
      status: "pending",
      todo: "TODO",
      level: 1,
      file: note.path,
      line: 1,
      idValue: "approval-launch",
      properties: [:],
      body: "Review launch material",
      tags: []
    )
    let second = ApprovalItem(
      title: "Approve pricing",
      status: "pending",
      todo: "TODO",
      level: 1,
      file: note.path,
      line: 3,
      idValue: "approval-pricing",
      properties: [:],
      body: "Review pricing material",
      tags: []
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.replaceApprovalItemsForTesting([first, second])
    store.selectedApprovalItemIDsForAIContext = [first.id, second.id]

    store.startNewAIThreadFromApprovalSelection(including: second)

    let presentation = AIChatContextPresentation(store.aiChatDraft)
    XCTAssertEqual(presentation.contexts.map(\.title), ["Approve launch", "Approve pricing"])
    XCTAssertEqual(presentation.contexts.map(\.reference), [
      "/remote/org2/approvals.org2:1",
      "/remote/org2/approvals.org2:3"
    ])
    XCTAssertEqual(store.selectedAIChatThread?.title, "Context: 2 selected items")
  }

  @MainActor
  func testRunDetailUsesWorkspaceDetailAndArtifactNavigationReturnsWithBack() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-detail-navigation-\(UUID().uuidString)", isDirectory: true)
    let runs = root.appendingPathComponent(".org2/runs", isDirectory: true)
    let views = root.appendingPathComponent("views", isDirectory: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: views, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let output = views.appendingPathComponent("brief.org2")
    try "#+TITLE: Brief\n\n* Result\nReady.\n".write(to: output, atomically: true, encoding: .utf8)
    let runValue: [String: Any] = [
      "schema": "org2:agent-run:v1",
      "id": "run-detail",
      "goal": "Prepare a cited briefing",
      "acceptanceCriteria": [],
      "status": "running",
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [[
        "id": "brief",
        "path": "views/brief.org2",
        "role": "report",
        "createdAt": "2026-07-14T00:00:00.000Z"
      ]],
      "approvals": [],
      "validations": [],
      "comments": [],
      "events": [],
      "createdAt": "2026-07-14T00:00:00.000Z",
      "updatedAt": "2026-07-14T00:01:00.000Z"
    ]
    let machineState = String(
      data: try JSONSerialization.data(withJSONObject: runValue, options: [.prettyPrinted, .sortedKeys]),
      encoding: .utf8
    )!
    try """
    #+TITLE: Run: Prepare a cited briefing
    #+ORG2_KIND: agent-run

    * TODO Prepare a cited briefing :agent-run:
    #+begin_src json :org2-agent-run
    \(machineState)
    #+end_src
    """.write(
      to: runs.appendingPathComponent("run-detail.org2"),
      atomically: true,
      encoding: .utf8
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    await store.refreshAgentRuns()
    XCTAssertNil(store.errorText, store.errorText ?? "")
    let run = try XCTUnwrap(store.agentRuns.first)

    store.selectAgentRun(run)
    XCTAssertEqual(store.presentedAgentRun?.id, run.id)
    XCTAssertNil(store.selectedLocation)
    XCTAssertEqual(store.selectedSurface, .approvals)

    let repeatedSelectionChanged = AgentRunObservationFlag()
    withObservationTracking {
      _ = store.presentedAgentRunID
      _ = store.selectedSurface
      _ = store.selectedLocation
      _ = store.isWorkspaceDetailPaneClosed
    } onChange: {
      repeatedSelectionChanged.set()
    }
    store.selectAgentRun(run)
    XCTAssertFalse(repeatedSelectionChanged.value)

    store.openAgentRunArtifact(try XCTUnwrap(run.artifacts.first))
    XCTAssertNil(store.presentedAgentRun)
    XCTAssertEqual(store.selectedLocation?.file, output.path)
    XCTAssertEqual(store.selectedSurface, .approvals)

    store.navigateBack()
    XCTAssertEqual(store.presentedAgentRun?.id, run.id)
    XCTAssertEqual(store.selectedSurface, .approvals)
  }

  private func approvalQueueItem(
    run: AgentRunItem,
    approval: AgentRunApprovalItem,
    root: URL
  ) -> ApprovalItem {
    ApprovalItem(
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

  private func makeRun(
    id: String = "run-1",
    goal: String = "Prepare a cited briefing",
    status: String = "queued",
    workflowId: String? = nil,
    parentRunId: String? = nil,
    contextRefs: [String] = [],
    blockedReason: String? = nil,
    comments: [String] = [],
    validationStatus: String? = nil,
    reviewRequired: Bool = false,
    pendingApproval: Bool = false,
    approvalStatus: String? = nil,
    approvalStatuses: [String]? = nil,
    approvalAction: String = "publish output",
    updatedAt: String = "2026-07-14T00:01:00.000Z"
  ) throws -> AgentRunItem {
    let resolvedApprovalStatuses = approvalStatuses
      ?? (approvalStatus ?? (pendingApproval ? "pending" : nil)).map { [$0] }
    var value: [String: Any] = [
      "id": id,
      "goal": goal,
      "acceptanceCriteria": [],
      "status": status,
      "riskClass": "local-draft",
      "capabilities": [],
      "context": contextRefs.map { ["ref": $0] },
      "plan": [],
      "artifacts": reviewRequired ? [[
        "id": "artifact-1",
        "path": "views/output.org2",
        "role": "report",
        "reviewStatus": "review-required",
        "createdAt": "2026-07-14T00:00:00.000Z"
      ]] : [],
      "approvals": resolvedApprovalStatuses?.enumerated().map { index, status in [
        "id": "approval-\(index + 1)",
        "title": index == 0 ? "Approve output" : "Approve output \(index + 1)",
        "action": approvalAction,
        "riskClass": "external-action",
        "status": status,
        "requestedAt": "2026-07-14T00:00:00.000Z",
        "decidedAt": status == "pending" ? NSNull() : "2026-07-14T00:00:30.000Z",
        "decidedBy": status == "pending" ? NSNull() : "Avi"
      ] } ?? [],
      "validations": validationStatus.map { status in [[
        "id": "validation-1",
        "name": "output-check",
        "status": status,
        "checkedAt": "2026-07-14T00:00:00.000Z"
      ]] } ?? [],
      "comments": comments.enumerated().map { index, body in [
        "id": "comment-\(index)",
        "author": "org2-lifecycle",
        "body": body,
        "createdAt": "2026-07-14T00:00:00.000Z"
      ] },
      "events": [],
      "createdAt": "2026-07-14T00:00:00.000Z",
      "updatedAt": updatedAt
    ]
    if let workflowId { value["workflowId"] = workflowId }
    if let parentRunId { value["parentRunId"] = parentRunId }
    if let blockedReason { value["blockedReason"] = blockedReason }
    return try JSONDecoder().decode(
      AgentRunItem.self,
      from: JSONSerialization.data(withJSONObject: value)
    )
  }
}
