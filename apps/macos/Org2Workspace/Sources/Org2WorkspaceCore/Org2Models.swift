import CryptoKit
import Foundation

public struct CorpusIdentity: Codable, Hashable, Sendable {
  public let schema: String
  public let id: String
  public let name: String
  public let kind: String
}

public struct CorpusIdentityIssue: Decodable, Hashable, Sendable {
  public let path: String
  public let message: String
}

public struct CorpusIdentityStatus: Decodable, Sendable {
  public let schema: String
  public let root: String
  public let configFile: String
  public let identity: CorpusIdentity?
  public let valid: Bool
  public let issues: [CorpusIdentityIssue]
}

public struct WorkspaceCorpusMount: Codable, Hashable, Sendable, Identifiable {
  public let path: String
  public let corpusID: String?
  public let name: String
  public let kind: String?

  public var id: String { path }
  public var displayKind: String { kind?.capitalized ?? "Local" }
}

public struct WorkspaceResultCorpus: Decodable, Hashable, Sendable {
  public let schema: String
  public let id: String
  public let name: String
  public let kind: String
  public let root: String
}

public struct WorkspaceReadIssue: Decodable, Hashable, Sendable {
  public let root: String
  public let message: String
}

public enum WorkspaceReadScope: String, CaseIterable, Identifiable, Sendable {
  case activeCorpus
  case allCorpora

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .activeCorpus: "This Corpus"
    case .allCorpora: "All Corpora"
    }
  }
}

public struct AgentRunListPayload: Decodable, Sendable {
  public let schema: String?
  public let runs: [AgentRunItem]

  enum CodingKeys: String, CodingKey {
    case schema
    case runs
  }
}

enum AgentRunScope: String, CaseIterable, Identifiable, Hashable {
  case active = "Active"
  case attention = "Needs attention"
  case completed = "Completed"
  case all = "All"

  var id: String { rawValue }

  func entries(in runs: [AgentRunItem]) -> [AgentRunScopeEntry] {
    switch self {
    case .attention:
      return Self.attentionEntries(in: runs)
    case .active, .completed, .all:
      return runs.filter(includes).map { AgentRunScopeEntry(run: $0) }
    }
  }

  func count(in runs: [AgentRunItem]) -> Int {
    entries(in: runs).count
  }

  private func includes(_ run: AgentRunItem) -> Bool {
    switch self {
    case .active: ["queued", "running"].contains(run.status)
    case .attention: run.needsAttention
    case .completed: run.isFinished
    case .all: true
    }
  }

  private static func attentionEntries(in runs: [AgentRunItem]) -> [AgentRunScopeEntry] {
    let orderedRuns = runs.sorted {
      $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
    }
    var latestRunIDBySeries: [String: AgentRunItem.ID] = [:]
    var failureCountBySeries: [String: Int] = [:]

    for run in orderedRuns {
      let key = run.failureSeriesKey
      if latestRunIDBySeries[key] == nil {
        latestRunIDBySeries[key] = run.id
      }
      if run.status == "failed" {
        failureCountBySeries[key, default: 0] += 1
      }
    }

    return orderedRuns.compactMap { run in
      if run.status == "failed" {
        let key = run.failureSeriesKey
        guard latestRunIDBySeries[key] == run.id else { return nil }
        return AgentRunScopeEntry(
          run: run,
          representedFailureCount: failureCountBySeries[key, default: 1]
        )
      }
      return run.needsAttention ? AgentRunScopeEntry(run: run) : nil
    }
  }
}

// Keep these presentation collections intentionally non-Equatable. SwiftUI otherwise
// deep-compares every full AgentRunItem whenever the Runs view is rebuilt.
struct AgentRunScopeEntry: Identifiable {
  let run: AgentRunItem
  let representedFailureCount: Int

  init(run: AgentRunItem, representedFailureCount: Int = 0) {
    self.run = run
    self.representedFailureCount = representedFailureCount
  }

  var id: AgentRunItem.ID { run.id }
}

struct RunCenterSection: Identifiable {
  let id: String
  let sourceMeeting: AgentRunContextItem?
  let entries: [AgentRunScopeEntry]
}

enum RunCenterPresentation {
  static func prefixSections(
    _ sections: [RunCenterSection],
    limit: Int
  ) -> [RunCenterSection] {
    guard limit > 0 else { return [] }
    var remaining = limit
    var result: [RunCenterSection] = []
    result.reserveCapacity(sections.count)

    for section in sections where remaining > 0 {
      let entries = Array(section.entries.prefix(remaining))
      guard !entries.isEmpty else { continue }
      result.append(
        RunCenterSection(
          id: section.id,
          sourceMeeting: section.sourceMeeting,
          entries: entries
        )
      )
      remaining -= entries.count
    }
    return result
  }

  static func approvalID(
    selectedApprovalItemID: ApprovalItem.ID?,
    runID: AgentRunItem.ID
  ) -> AgentRunApprovalItem.ID? {
    guard let selectedApprovalItemID else { return nil }
    let prefix = "run:\(runID):"
    guard selectedApprovalItemID.hasPrefix(prefix) else { return nil }
    let approvalID = selectedApprovalItemID.dropFirst(prefix.count)
    return approvalID.isEmpty ? nil : String(approvalID)
  }

  static func sourceMeetingContextsByRunID(
    in runs: [AgentRunItem]
  ) -> [AgentRunItem.ID: AgentRunContextItem] {
    let runsByID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
    var contexts: [AgentRunItem.ID: AgentRunContextItem] = [:]
    contexts.reserveCapacity(runs.count)
    var resolvedRunIDs = Set<AgentRunItem.ID>()
    resolvedRunIDs.reserveCapacity(runs.count)

    for run in runs {
      guard !resolvedRunIDs.contains(run.id) else { continue }
      var chain: [AgentRunItem.ID] = []
      var chainRunIDs = Set<AgentRunItem.ID>()
      var currentRunID: AgentRunItem.ID? = run.id
      var resolvedContext: AgentRunContextItem?

      while let candidateID = currentRunID {
        if let cachedContext = contexts[candidateID] {
          resolvedContext = cachedContext
          break
        }
        if resolvedRunIDs.contains(candidateID) {
          break
        }
        guard chainRunIDs.insert(candidateID).inserted,
              let candidate = runsByID[candidateID]
        else {
          break
        }
        chain.append(candidateID)
        if let directContext = candidate.sourceMeetingContext {
          resolvedContext = directContext
          break
        }
        currentRunID = candidate.parentRunId
      }

      for candidateID in chain {
        resolvedRunIDs.insert(candidateID)
        if let resolvedContext {
          contexts[candidateID] = resolvedContext
        }
      }
    }
    return contexts
  }

  static func sections(
    for entries: [AgentRunScopeEntry],
    allRuns: [AgentRunItem]
  ) -> [RunCenterSection] {
    let sourceMeetingContexts = sourceMeetingContextsByRunID(in: allRuns)
    return sections(for: entries, sourceMeetingContexts: sourceMeetingContexts)
  }

  static func sections(
    for entries: [AgentRunScopeEntry],
    sourceMeetingContexts: [AgentRunItem.ID: AgentRunContextItem]
  ) -> [RunCenterSection] {
    var sectionOrder: [String] = []
    var sourceMeetingsBySectionID: [String: AgentRunContextItem] = [:]
    var entriesBySectionID: [String: [AgentRunScopeEntry]] = [:]
    sectionOrder.reserveCapacity(min(entries.count, 16))
    entriesBySectionID.reserveCapacity(min(entries.count, 16))

    for entry in entries {
      let sourceMeeting = sourceMeetingContexts[entry.run.id]
      let sectionID = sourceMeeting.map { "meeting:\($0.fileReference ?? $0.ref)" } ?? "other"
      if entriesBySectionID[sectionID] == nil {
        sectionOrder.append(sectionID)
        if let sourceMeeting {
          sourceMeetingsBySectionID[sectionID] = sourceMeeting
        }
      }
      entriesBySectionID[sectionID, default: []].append(entry)
    }

    return sectionOrder.map { sectionID in
      RunCenterSection(
        id: sectionID,
        sourceMeeting: sourceMeetingsBySectionID[sectionID],
        entries: entriesBySectionID[sectionID] ?? []
      )
    }
  }
}

public struct AgentWorkflowListPayload: Decodable, Sendable {
  public let schema: String
  public let workflows: [AgentWorkflowItem]
}

public struct AgentGoalListPayload: Decodable, Sendable {
  public let schema: String
  public let goals: [AgentGoalItem]
}

public struct AgentGoalItem: Identifiable, Decodable, Hashable, Sendable {
  public let schema: String
  public let id: String
  public let title: String
  public let description: String
  public let status: String
  public let parentGoalRef: String?
  public let ownerAgentRef: String?
  public let measures: [String]
  public let file: String
  public let createdAt: String
  public let updatedAt: String
}

public struct AgentProfileListPayload: Decodable, Sendable {
  public let schema: String
  public let profiles: [AgentProfileItem]
}

public struct AgentRuntimeBindingItem: Decodable, Hashable, Sendable, Identifiable {
  public let runtime: String
  public let runtimeAgentId: String

  public var id: String { "\(runtime):\(runtimeAgentId)" }
}

public struct AgentProfileItem: Identifiable, Decodable, Hashable, Sendable {
  public let schema: String
  public let id: String
  public let name: String
  public let description: String
  public let status: String
  public let responsibilities: [String]
  public let capabilities: [String]
  public let skills: [String]
  public let defaultRuntime: String?
  public let runtimeBindings: [AgentRuntimeBindingItem]
  public let goalRefs: [String]
  public let primaryGoalRef: String?
  public let reportsToAgentRef: String?
  public let file: String
  public let createdAt: String
  public let updatedAt: String

  public var preferredChatRuntime: AIChatRuntime? {
    defaultRuntime.flatMap(AIChatRuntime.init(agentProfileValue:))
  }
}

public struct AgentWorkflowInputItem: Decodable, Hashable, Sendable, Identifiable {
  public let id: String
  public let description: String
  public let required: Bool
  public let `default`: String?
}

public struct AgentWorkflowTriggerItem: Decodable, Hashable, Sendable, Identifiable {
  public let id: String
  public let type: String
  public let enabled: Bool
  public let schedule: String?
  public let timezone: String?
}

public struct AgentWorkflowDueListPayload: Decodable, Sendable {
  public let reason: String?
  public let schema: String
  public let now: String
  public let due: [AgentWorkflowDueItem]
  public let skipped: [AgentWorkflowDueItem]
  public let failures: [AgentWorkflowFailureItem]?
  public let hostRef: String?
}

public struct AgentWorkflowFailureItem: Decodable, Sendable {
  public let workflowId: String
  public let title: String
  public let runId: String
  public let failure: String
}

public struct AgentWorkflowDueItem: Decodable, Hashable, Sendable, Identifiable {
  public let workflowId: String
  public let title: String
  public let destinationRef: String?
  public let model: String?
  public let reasoningEffort: String?
  public let agentRef: String?
  public let goalRef: String?
  public let triggerId: String
  public let schedule: String?
  public let timezone: String?
  public let scheduledFor: String
  public let reason: String?
  public let activeRunId: String?

  public var id: String { "\(workflowId):\(triggerId):\(scheduledFor)" }
}

public struct AgentWorkflowRunPayload: Decodable, Sendable {
  public let schema: String?
  public let workflowId: String?
  public let reason: String?
  public let activeRunId: String?
  public let run: AgentRunItem?
  public let file: String?
  public let model: String?
  public let reasoningEffort: String?
  public let prompt: String?
}

public struct AgentRunAttemptItem: Decodable, Hashable, Sendable {
  public let id: String
  public let number: Int
  public let triggerId: String?
  public let triggerType: String?
  public let scheduledFor: String?
  public let signalIds: [String]?
}

public struct AgentWorkflowItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let version: String
  public let title: String
  public let description: String
  public let state: String
  public let instructions: String
  public let riskClass: String
  public let capabilities: [String]
  public let inputs: [AgentWorkflowInputItem]
  public let triggers: [AgentWorkflowTriggerItem]
  public let file: String
  public let legacyLocation: Bool
  public let sourceRunId: String?
  public let destinationRef: String?
  public let model: String?
  public let reasoningEffort: String?
  public let agentRef: String?
  public let goalRef: String?
  public let createdAt: String
  public let updatedAt: String

  public var scheduleTrigger: AgentWorkflowTriggerItem? {
    triggers.first { $0.id == "schedule" && $0.type == "schedule" }
      ?? triggers.first { ["openorg-schedule", "openclaw-schedule"].contains($0.id) && $0.type == "schedule" }
      ?? triggers.first { $0.type == "schedule" }
  }

  public var scheduleSummary: String {
    guard let trigger = scheduleTrigger, trigger.enabled, let schedule = trigger.schedule else {
      return "Manual"
    }
    if let timezone = trigger.timezone, !timezone.isEmpty { return "\(schedule) · \(timezone)" }
    return schedule
  }
}

public struct AgentRunItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let title: String?
  public let goal: String
  public let acceptanceCriteria: [String]
  public let status: String
  public let riskClass: String
  public let owner: String?
  public let assignee: String?
  public let agentRef: String?
  public let goalRef: String?
  public let workflowId: String?
  public let workflowVersion: String?
  public let destinationRef: String?
  public let providerPolicy: String?
  public let provider: String?
  public let model: String?
  public let capabilities: [String]
  public let context: [AgentRunContextItem]
  public let plan: [AgentRunStepItem]
  public let artifacts: [AgentRunArtifactItem]
  public let approvals: [AgentRunApprovalItem]
  public let validations: [AgentRunValidationItem]
  public let comments: [AgentRunCommentItem]
  public let events: [AgentRunEventItem]
  public let outcome: AgentRunOutcomeItem?
  public let logicalWorkId: String?
  public let attempt: AgentRunAttemptItem?
  public let parentRunId: String?
  public let createdAt: String
  public let updatedAt: String
  public let startedAt: String?
  public let completedAt: String?
  public let blockedReason: String?
  public let failure: String?

  public var displayTitle: String {
    let explicitTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let raw = explicitTitle.isEmpty ? goal : explicitTitle
    let normalized = Org2Display.cleanInline(raw)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var candidate = normalized
    if let marker = candidate.range(
      of: #"\bTask:\s*"#,
      options: [.regularExpression, .caseInsensitive]
    ) {
      candidate = String(candidate[marker.upperBound...])
    }
    if let metadata = candidate.range(
      of: #"\s+(?:Repository|Source|TODO|Dispatch ID|Acceptance criteria|Protected exclusions|Origin thread):\s*"#,
      options: [.regularExpression, .caseInsensitive]
    ) {
      candidate = String(candidate[..<metadata.lowerBound])
    }
    candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if candidate.isEmpty { candidate = "Agent run" }
    return candidate.count <= 120
      ? candidate
      : String(candidate.prefix(119)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  public var pendingApprovalCount: Int { pendingApprovals.count }
  public var currentApprovalBoundary: [AgentRunApprovalItem] {
    guard let boundaryAt = events.reversed().first(where: {
      $0.type == "status-changed"
        && $0.detail?.range(of: "-> waiting-approval", options: .caseInsensitive) != nil
    })?.at else {
      return approvals
    }
    let boundary = approvals.filter { $0.requestedAt >= boundaryAt }
    return boundary.isEmpty ? approvals : boundary
  }
  public var resumableRevisionApproval: AgentRunApprovalItem? {
    guard status == "blocked",
          pendingApprovalCount == 0,
          !currentApprovalBoundary.contains(where: {
            $0.status == "rejected" || $0.status == "canceled"
          })
    else {
      return nil
    }
    return currentApprovalBoundary
      .filter {
        $0.status == "revised"
          && $0.decisionNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      }
      .max { ($0.decidedAt ?? "") < ($1.decidedAt ?? "") }
  }
  public var openClawExecApprovalID: String? {
    for comment in comments.reversed() {
      for line in comment.body.split(whereSeparator: \.isNewline) {
        let rawLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawLine.lowercased().hasPrefix("openclaw_key:") else { continue }
        let key = rawLine.dropFirst("OPENCLAW_KEY:".count)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = key.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 4,
              components[0].lowercased() == "draft",
              components[1].lowercased() == "exec"
        else { continue }
        let approvalID = components.dropFirst(3).joined(separator: ":")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !approvalID.isEmpty { return approvalID }
      }
    }
    return nil
  }
  public var isOpenClawExternalDraft: Bool {
    comments.contains { comment in
      comment.body.split(whereSeparator: \.isNewline).contains { line in
        String(line).trimmingCharacters(in: .whitespacesAndNewlines)
          .caseInsensitiveCompare("OPENCLAW_KIND: external-draft") == .orderedSame
      }
    }
  }
  public var openClawSessionKey: String? {
    for comment in comments.reversed() {
      for line in comment.body.split(whereSeparator: \.isNewline) {
        let rawLine = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawLine.lowercased().hasPrefix("openclaw_session:") else { continue }
        let sessionKey = rawLine.dropFirst("OPENCLAW_SESSION:".count)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionKey.isEmpty,
              sessionKey.localizedCaseInsensitiveCompare("unknown") != .orderedSame
        else { continue }
        return sessionKey
      }
    }
    return nil
  }
  public var hasOpenClawApprovalContinuation: Bool {
    workflowId != nil
      || isOpenClawExternalDraft
      || openClawSessionKey != nil
      || canContinueApprovedWork
  }
  public var approvedCurrentApprovalBoundary: [AgentRunApprovalItem] {
    currentApprovalBoundary.filter { $0.status == "approved" }
  }
  public var hasApprovedProviderDraftBoundary: Bool {
    approvedCurrentApprovalBoundary.contains { approval in
      approval.action.range(
        of: #"(?im)^\s*Provider draft:\s*\S+"#,
        options: .regularExpression
      ) != nil
    }
  }
  public var canContinueApprovedWork: Bool {
    status == "running"
      && pendingApprovalCount == 0
      && !currentApprovalBoundary.isEmpty
      && !currentApprovalBoundary.contains(where: {
        $0.status == "pending" || $0.status == "revised"
      })
  }
  public var completedStepCount: Int { plan.filter { $0.status == "completed" }.count }
  public var skippedStepCount: Int { plan.filter { $0.status == "skipped" }.count }
  public var latestValidations: [AgentRunValidationItem] {
    var seen = Set<String>()
    return validations.reversed().filter { seen.insert($0.name.lowercased()).inserted }.reversed()
  }
  public var attentionValidations: [AgentRunValidationItem] {
    latestValidations.filter { $0.status == "failed" || $0.status == "warning" }
  }
  public var isFinished: Bool {
    status == "completed" || status == "canceled"
  }
  public var canMarkDoneElsewhere: Bool {
    status != "completed"
  }
  public var pendingApprovals: [AgentRunApprovalItem] {
    approvals.filter { $0.status == "pending" }
  }
  public var actionablePendingApprovals: [AgentRunApprovalItem] {
    isFinished ? [] : pendingApprovals
  }
  public var retainedPendingApprovals: [AgentRunApprovalItem] {
    isFinished ? pendingApprovals : []
  }
  public var needsAttention: Bool {
    guard !isFinished, !["queued", "running"].contains(status) else { return false }
    return pendingApprovalCount > 0
      || status == "blocked"
      || status == "failed"
      || status == "waiting-approval"
      || !attentionValidations.isEmpty
      || artifacts.contains { $0.reviewStatus == "review-required" }
  }
  public var progressText: String {
    guard !plan.isEmpty else { return "No plan" }
    if skippedStepCount > 0 {
      return "\(completedStepCount) completed · \(skippedStepCount) skipped"
    }
    return "\(completedStepCount)/\(plan.count) completed"
  }
  public var workflowDisplayName: String? { workflowId.map(Self.humanizedLabel) }
  public var sourceMeetingContext: AgentRunContextItem? {
    context.first(where: \.isMeetingReference)
  }
  public func sourceMeetingContext(in runs: [AgentRunItem]) -> AgentRunContextItem? {
    let runsByID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
    return sourceMeetingContext(in: runsByID)
  }
  func sourceMeetingContext(
    in runsByID: [AgentRunItem.ID: AgentRunItem]
  ) -> AgentRunContextItem? {
    if let sourceMeetingContext { return sourceMeetingContext }
    var visited = Set([id])
    var ancestorID = parentRunId
    while let currentID = ancestorID,
          visited.insert(currentID).inserted,
          let ancestor = runsByID[currentID] {
      if let sourceMeetingContext = ancestor.sourceMeetingContext { return sourceMeetingContext }
      ancestorID = ancestor.parentRunId
    }
    return nil
  }
  fileprivate var failureSeriesKey: String {
    let normalizedGoal = goal
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return [workflowId ?? "", normalizedGoal, assignee ?? owner ?? ""]
      .joined(separator: "\u{1f}")
  }
  public var humanOutcomeSummary: String {
    if let summary = outcome?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
      return summary
    }
    if status == "completed" {
      let outputNames = artifacts.map(\.displayTitle)
      let outputSummary: String
      switch outputNames.count {
      case 0: outputSummary = "The run finished without recording a human-readable outcome."
      case 1: outputSummary = "Produced \(outputNames[0])."
      case 2: outputSummary = "Produced \(outputNames[0]) and \(outputNames[1])."
      default: outputSummary = "Produced \(outputNames.dropLast().joined(separator: ", ")), and \(outputNames.last!)."
      }
      guard !plan.isEmpty else { return outputSummary }
      let stepSummary = skippedStepCount > 0
        ? "Completed \(completedStepCount) steps; \(skippedStepCount) optional steps were skipped."
        : "Completed \(completedStepCount) of \(plan.count) steps."
      return "\(outputSummary) \(stepSummary)"
    }
    return goal
  }
  public var humanNextAction: String? {
    if let actions = outcome?.nextActions, !actions.isEmpty { return nil }
    if status == "completed" && !needsAttention { return "No action required" }
    return nil
  }
  public var clarificationPrompt: String? {
    guard status == "blocked",
          let prompt = blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines),
          !prompt.isEmpty,
          prompt.localizedCaseInsensitiveCompare("Blocked pending clarification") != .orderedSame
    else { return nil }
    return prompt
  }

  public func matchesRunFilter(_ query: String) -> Bool {
    let terms = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !terms.isEmpty else { return true }

    return terms.allSatisfy { runFilterText.contains($0) }
  }

  var runFilterText: String {
    var values = [
      id,
      title,
      goal,
      status,
      riskClass,
      owner,
      assignee,
      agentRef,
      goalRef,
      workflowId,
      workflowVersion,
      destinationRef,
      logicalWorkId,
      attempt?.triggerId,
      attempt?.scheduledFor,
      providerPolicy,
      provider,
      model,
      parentRunId,
      blockedReason,
      failure,
      outcome?.summary,
    ].compactMap { $0 }
    values.append(contentsOf: acceptanceCriteria)
    values.append(contentsOf: capabilities)
    values.append(contentsOf: outcome?.highlights ?? [])
    values.append(contentsOf: outcome?.nextActions ?? [])

    for item in context {
      values.append(contentsOf: [item.ref, item.title, item.citation, item.sha256].compactMap { $0 })
    }
    for item in plan {
      values.append(contentsOf: [item.id, item.title, item.kind, item.status, item.capability, item.detail].compactMap { $0 })
    }
    for item in artifacts {
      values.append(contentsOf: [item.id, item.path, item.role, item.title, item.mediaType, item.reviewStatus].compactMap { $0 })
    }
    for item in approvals {
      values.append(contentsOf: [
        item.id, item.title, item.action, item.riskClass, item.status,
        item.requestedRole, item.requestedFrom, item.decidedBy, item.note, item.receipt,
      ].compactMap { $0 })
    }
    for item in validations {
      values.append(contentsOf: [item.id, item.name, item.status, item.detail].compactMap { $0 })
    }
    for item in comments {
      values.append(contentsOf: [item.author, item.body].compactMap { $0 })
    }
    for item in events {
      values.append(contentsOf: [item.type, item.actor, item.detail].compactMap { $0 })
    }

    return values.joined(separator: "\n").lowercased()
  }

  public static func humanizedLabel(_ rawValue: String) -> String {
    rawValue
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }
}

public struct AgentRunOutcomeItem: Decodable, Hashable, Sendable {
  public let summary: String
  public let highlights: [String]
  public let nextActions: [String]
}

enum AgentRunTimestampPresentation {
  static func date(from rawValue: String) -> Date? {
    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: rawValue) { return date }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: rawValue)
  }

  static func displayText(
    for rawValue: String,
    now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    guard let date = date(from: rawValue) else { return rawValue }
    var localCalendar = calendar
    localCalendar.timeZone = timeZone

    let timeFormatter = DateFormatter()
    timeFormatter.locale = locale
    timeFormatter.timeZone = timeZone
    timeFormatter.dateStyle = .none
    timeFormatter.timeStyle = .short
    let time = timeFormatter.string(from: date)

    if localCalendar.isDate(date, inSameDayAs: now) {
      return "today at \(time)"
    }
    if let yesterday = localCalendar.date(byAdding: .day, value: -1, to: now),
       localCalendar.isDate(date, inSameDayAs: yesterday) {
      return "yesterday at \(time)"
    }

    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  static func detailText(
    for rawValue: String,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    guard let date = date(from: rawValue) else { return rawValue }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.dateStyle = .full
    formatter.timeStyle = .medium
    let zone = timeZone.abbreviation(for: date).map { " \($0)" } ?? ""
    return formatter.string(from: date) + zone
  }
}

public struct AgentRunContextItem: Decodable, Hashable, Sendable {
  public let ref: String
  public let title: String?
  public let citation: String?
  public let sha256: String?

  public var fileReference: String? {
    let value = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if value.hasPrefix("file:") { return String(value.dropFirst("file:".count)) }
    if value.contains("://") || value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
      return nil
    }
    return value
  }

  public var isMeetingReference: Bool {
    guard let fileReference else { return false }
    let normalized = fileReference.replacingOccurrences(of: "\\", with: "/").lowercased()
    return normalized.contains("/meetings/") || normalized.hasPrefix("meetings/")
  }

  public var displayTitle: String {
    if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      return title
    }
    guard let fileReference else { return ref }
    let stem = URL(fileURLWithPath: fileReference).deletingPathExtension().lastPathComponent
    let parts = stem.split(separator: "-").map(String.init)
    let hasDatedMeetingPrefix = parts.count >= 5
      && parts[0].count == 4
      && parts[1].count == 2
      && parts[2].count == 2
      && parts[3].count == 6
    if hasDatedMeetingPrefix {
      let meeting = AgentRunItem.humanizedLabel(parts.dropFirst(4).joined(separator: "-"))
      return meeting.isEmpty ? "Meeting · \(parts[0])-\(parts[1])-\(parts[2])" : "\(meeting) · \(parts[0])-\(parts[1])-\(parts[2])"
    }
    let label = AgentRunItem.humanizedLabel(stem)
    return label.isEmpty ? ref : label
  }
}

public struct AgentRunStepItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let kind: String
  public let status: String
  public let capability: String?
  public let detail: String?
}

public struct AgentRunArtifactItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let path: String
  public let role: String
  public let title: String?
  public let mediaType: String?
  public let sha256: String?
  public let reviewStatus: String?
  public let createdAt: String

  public var displayTitle: String {
    if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != path {
      return title
    }
    let filename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var label = AgentRunItem.humanizedLabel(filename)
    if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf",
       !label.localizedCaseInsensitiveContains("pdf") {
      label += " PDF"
    }
    return label.isEmpty ? path : label
  }

  public var isPDF: Bool {
    if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" {
      return true
    }
    return mediaType?
      .split(separator: ";", maxSplits: 1)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() == "application/pdf"
  }

  public var roleDisplayText: String { AgentRunItem.humanizedLabel(role) }
}

public struct AgentRunApprovalItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let fingerprint: String?
  public let title: String
  public let action: String
  public let riskClass: String
  public let status: String
  public let requestedRole: String?
  public let requestedFrom: String?
  public let requestedAt: String
  public let decidedAt: String?
  public let decidedBy: String?
  public let decisionNote: String?
  public let note: String?
  public let receipt: String?
}

public struct AgentRunValidationItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let status: String
  public let checkedAt: String
  public let detail: String?

  public var displayName: String { AgentRunItem.humanizedLabel(name) }
}

public struct AgentRunCommentItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let author: String
  public let body: String
  public let createdAt: String
}

public struct AgentRunEventItem: Identifiable, Decodable, Hashable, Sendable {
  public let id: String
  public let type: String
  public let at: String
  public let actor: String?
  public let detail: String?
}

public struct AgendaPayload: Decodable, Sendable {
  public let schema: String?
  public let range: AgendaRange
  public let overdue: [AgendaDay]
  public let days: [AgendaDay]
  public let skippedFiles: Int?
  public let workload: AgendaWorkload?
  public let corpora: [WorkspaceResultCorpus]?
  public let issues: [WorkspaceReadIssue]?

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case range
    case overdue
    case days
    case skippedFiles
    case workload
    case corpora
    case issues
  }

  public var totalItemCount: Int {
    (overdue + days).reduce(0) { $0 + $1.items.count }
  }

  public var todayItemCount: Int {
    guard let today = days.first(where: { $0.date == range.start }) else { return 0 }
    return today.items.count
  }

  public var upcomingItemCount: Int {
    days.filter { $0.date != range.start }.reduce(0) { $0 + $1.items.count }
  }
}

public struct AgendaRange: Decodable, Sendable {
  public let start: String
  public let end: String
  public let days: Int
}

public struct AgendaDay: Decodable, Identifiable, Sendable {
  public let date: String
  public let weekday: String
  public let items: [AgendaItem]
  public let groups: [AgendaGroup]?

  public var id: String { date }
}

public struct AgendaGroup: Decodable, Identifiable, Sendable {
  public let label: String
  public let items: [AgendaItem]

  public var id: String { label }
}

public struct AgendaItem: Decodable, Identifiable, Hashable, Sendable {
  public let todo: String?
  public let headline: String
  public let kind: String
  public let file: String
  public let line: Int
  public let body: String?
  public let level: Int?
  public let tags: [String]
  public let properties: [String: String]
  public let priority: String?
  public let time: String?
  public let effort: String?
  public let idValue: String?
  public let habit: HabitAgendaState?
  public let corpus: WorkspaceResultCorpus?
  /// Present on the copy of an upcoming deadline that the runtime shows on
  /// today's date during its warning period.
  public let deadlineWarning: AgendaDeadlineWarning?

  enum CodingKeys: String, CodingKey {
    case todo
    case headline
    case kind
    case file
    case line
    case body
    case level
    case tags
    case properties
    case priority
    case time
    case effort
    case idValue = "id"
    case habit
    case corpus
    case deadlineWarning
  }

  public init(
    todo: String?,
    headline: String,
    kind: String,
    file: String,
    line: Int,
    body: String?,
    level: Int?,
    tags: [String],
    properties: [String: String],
    priority: String?,
    time: String?,
    effort: String?,
    idValue: String?,
    habit: HabitAgendaState?,
    corpus: WorkspaceResultCorpus? = nil,
    deadlineWarning: AgendaDeadlineWarning? = nil
  ) {
    self.todo = todo
    self.headline = headline
    self.kind = kind
    self.file = file
    self.line = line
    self.body = body
    self.level = level
    self.tags = tags
    self.properties = properties
    self.priority = priority
    self.time = time
    self.effort = effort
    self.idValue = idValue
    self.habit = habit
    self.corpus = corpus
    self.deadlineWarning = deadlineWarning
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    todo = try container.decodeIfPresent(String.self, forKey: .todo)
    headline = try container.decode(String.self, forKey: .headline)
    kind = try container.decode(String.self, forKey: .kind)
    file = try container.decode(String.self, forKey: .file)
    line = try container.decode(Int.self, forKey: .line)
    body = try container.decodeIfPresent(String.self, forKey: .body)
    level = try container.decodeIfPresent(Int.self, forKey: .level)
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    properties = try container.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
    priority = try container.decodeIfPresent(String.self, forKey: .priority)
    time = try container.decodeIfPresent(String.self, forKey: .time)
    effort = try container.decodeIfPresent(String.self, forKey: .effort)
    idValue = try container.decodeIfPresent(String.self, forKey: .idValue)
    habit = try container.decodeIfPresent(HabitAgendaState.self, forKey: .habit)
    corpus = try container.decodeIfPresent(WorkspaceResultCorpus.self, forKey: .corpus)
    deadlineWarning = try container.decodeIfPresent(AgendaDeadlineWarning.self, forKey: .deadlineWarning)
  }

  public var id: String {
    // The warning copy shown today and the row on the due date are distinct
    // rows of the same heading.
    let warningSuffix = deadlineWarning.map { ":warning:\($0.due)" } ?? ""
    return "\(file):\(line):\(kind):\(headline):\(idValue ?? "")\(warningSuffix)"
  }

  /// The planning label shown under an agenda row, for example
  /// "DEADLINE in 6 days · Oct 15" for an upcoming deadline shown today.
  public var planningLabel: String {
    let base = [kind, time].compactMap { $0 }.joined(separator: " ")
    guard let deadlineWarning else { return base }
    return "\(base) \(deadlineWarning.relativeDescription)"
  }

  public var lineForEditor: Int {
    max(1, line + 1)
  }

  public var isActionable: Bool {
    let normalized = (todo ?? "").uppercased()
    return normalized != "DONE" && normalized != "CANCELED" && normalized != "CANCELLED"
  }

  public func replacing(todo: String?) -> AgendaItem {
    AgendaItem(
      todo: todo,
      headline: headline,
      kind: kind,
      file: file,
      line: line,
      body: body,
      level: level,
      tags: tags,
      properties: properties,
      priority: priority,
      time: time,
      effort: effort,
      idValue: idValue,
      habit: habit,
      corpus: corpus,
      deadlineWarning: deadlineWarning
    )
  }

  public func matchesAgendaFilter(_ query: String) -> Bool {
    let terms = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)

    return matchesAgendaFilterTerms(terms)
  }

  func matchesAgendaFilterTerms(_ terms: [String]) -> Bool {
    guard !terms.isEmpty else { return true }

    return terms.allSatisfy { agendaFilterText.contains($0) }
  }

  var agendaFilterText: String {
    [
      todo,
      headline,
      kind,
      file,
      body,
      priority,
      effort,
      time,
      idValue,
      tags.joined(separator: " "),
      properties.map { "\($0.key) \($0.value)" }.joined(separator: "\n")
    ]
      .compactMap { $0 }
      .joined(separator: "\n")
      .lowercased()
  }
}

public struct AssignedWorkItem: Identifiable, Hashable, Sendable {
  public let file: String
  public let line: Int
  public let headline: String
  public let todo: String?
  public let assignee: String
  public let status: String
  public let assignedAt: String?
  public let lastAgentUpdate: String?
  public let tags: [String]
  public let properties: [String: String]

  public init(
    file: String,
    line: Int,
    headline: String,
    todo: String?,
    assignee: String,
    status: String,
    assignedAt: String? = nil,
    lastAgentUpdate: String? = nil,
    tags: [String] = [],
    properties: [String: String] = [:]
  ) {
    self.file = file
    self.line = line
    self.headline = headline
    self.todo = todo
    self.assignee = assignee
    self.status = status
    self.assignedAt = assignedAt
    self.lastAgentUpdate = lastAgentUpdate
    self.tags = tags
    self.properties = properties
  }

  public var id: String {
    "\(file):\(line):\(assignee):\(status):\(headline)"
  }

  public var lineForEditor: Int {
    max(1, line)
  }
}

public struct AgentRunSourceConsistencyIssue: Decodable, Hashable, Sendable {
  public let field: String
  public let readable: String?
  public let canonical: String
}

public struct AgentRunSourceReconciliationResult: Decodable, Sendable {
  public let schema: String
  public let applied: Bool
  public let changed: Bool
  public let file: String
  public let previousRevision: String
  public let revision: String
  public let sourceIssues: [AgentRunSourceConsistencyIssue]
  public let remainingSourceIssues: [AgentRunSourceConsistencyIssue]
  public let run: AgentRunItem
}

public enum RunsAndReviewPage: String, CaseIterable, Identifiable, Sendable {
  case runs = "Runs"
  case review = "Review"
  case goals = "Goals"
  case agents = "Agents"
  case workflows = "Automations"

  public var id: String { rawValue }
}

public struct ApprovalItem: Identifiable, Hashable, Sendable, Decodable {
  public let kind: String?
  public let title: String
  public let status: String
  public let todo: String?
  public let level: Int?
  public let file: String
  public let line: Int
  public let idValue: String?
  public let properties: [String: String]
  public let body: String
  public let tags: [String]
  public let approvalId: String?
  public let fingerprint: String?
  public let action: String?
  public let riskClass: String?
  public let requestedRole: String?
  public let requestedFrom: String?
  public let requestedAt: String?
  public let runId: String?
  public let runGoal: String?
  public let runStatus: String?
  public let runPendingApprovalCount: Int?
  public let runApprovalCount: Int?
  public let runDecisionEffect: String?
  public let decisionKeys: [String]?
  /// "urgent" or absent (normal). Orders interrupting prompts; never inferred from age.
  public let priority: String?

  public init(
    title: String,
    status: String,
    todo: String?,
    level: Int?,
    file: String,
    line: Int,
    idValue: String?,
    properties: [String: String],
    body: String,
    tags: [String],
    kind: String? = nil,
    approvalId: String? = nil,
    fingerprint: String? = nil,
    action: String? = nil,
    riskClass: String? = nil,
    requestedRole: String? = nil,
    requestedFrom: String? = nil,
    requestedAt: String? = nil,
    runId: String? = nil,
    runGoal: String? = nil,
    runStatus: String? = nil,
    runPendingApprovalCount: Int? = nil,
    runApprovalCount: Int? = nil,
    runDecisionEffect: String? = nil,
    decisionKeys: [String]? = nil,
    priority: String? = nil
  ) {
    self.kind = kind
    self.title = title
    self.status = status
    self.todo = todo
    self.level = level
    self.file = file
    self.line = max(1, line)
    self.idValue = idValue
    self.properties = properties
    self.body = body
    self.tags = tags
    self.approvalId = approvalId
    self.fingerprint = fingerprint
    self.action = action
    self.riskClass = riskClass
    self.requestedRole = requestedRole
    self.requestedFrom = requestedFrom
    self.requestedAt = requestedAt
    self.runId = runId
    self.runGoal = runGoal
    self.runStatus = runStatus
    self.runPendingApprovalCount = runPendingApprovalCount
    self.runApprovalCount = runApprovalCount
    self.runDecisionEffect = runDecisionEffect
    self.decisionKeys = decisionKeys
    self.priority = priority
  }

  public var isUrgent: Bool { priority == "urgent" }

  public var id: String {
    if let runId, let approvalId { return "run:\(runId):\(approvalId)" }
    return "\(file):\(line):\(idValue ?? title)"
  }

  public var isRunApproval: Bool { kind == "run" && runId != nil && approvalId != nil }

  public var sourceLabel: String {
    if let runId { return "Run \(runId)" }
    return "\(file):\(line)"
  }

  public var runDependencyText: String? {
    guard isRunApproval else { return nil }
    return runDecisionEffect
  }

  public var displayBodyPreview: String {
    Org2Display.cleanBlockPreview(body, maxCharacters: 220)
  }

  public var discussionText: String {
    """
    OpenClaw approval thread:

    \(Org2Display.cleanInline(title))
    Source: \(sourceLabel)
    Status: \(status)
    \(runGoal.map { "Run: \($0)" } ?? "")
    \(runDependencyText ?? "")

    \(Org2Display.cleanBlock(body).trimmedForDisplay(maxCharacters: 900))
    """
  }

  public func agendaItem() -> AgendaItem {
    AgendaItem(
      todo: todo,
      headline: title,
      kind: "Approval",
      file: file,
      line: line - 1,
      body: body,
      level: level,
      tags: tags,
      properties: properties,
      priority: nil,
      time: nil,
      effort: nil,
      idValue: idValue,
      habit: nil
    )
  }

  public func matchesApprovalFilter(_ query: String) -> Bool {
    let terms = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard !terms.isEmpty else { return true }

    return terms.allSatisfy { approvalFilterText.contains($0) }
  }

  var approvalFilterText: String {
    [
      title,
      status,
      todo,
      file,
      idValue,
      body,
      approvalId,
      action,
      riskClass,
      requestedRole,
      requestedFrom,
      runId,
      runGoal,
      runStatus,
      runDecisionEffect,
      decisionKeys?.joined(separator: " "),
      tags.joined(separator: " "),
      properties.map { "\($0.key) \($0.value)" }.joined(separator: "\n")
    ]
      .compactMap { $0 }
      .joined(separator: "\n")
      .lowercased()
  }
}

public struct AgendaDeadlineWarning: Decodable, Hashable, Sendable {
  public let due: String
  public let daysUntil: Int

  public init(due: String, daysUntil: Int) {
    self.due = due
    self.daysUntil = daysUntil
  }

  /// "due tomorrow" or "due in 6 days (2026-10-15)".
  public var relativeDescription: String {
    daysUntil == 1 ? "due tomorrow (\(due))" : "due in \(daysUntil) days (\(due))"
  }
}

public struct HabitAgendaState: Decodable, Hashable, Sendable {
  public let marker: String
  public let streak: Int
  public let closedDates: [String]
}

public struct AgendaWorkload: Decodable, Sendable {
  public let totalMinutes: Int
  public let byDate: [String: Int]
  public let byGroup: [String: Int]
  public let byTag: [String: Int]
}

public struct SearchPayload: Decodable, Sendable {
  public let schema: String?
  public let query: String
  public let mode: String
  public let sort: String
  public let results: [SearchResult]
  public let corpora: [WorkspaceResultCorpus]?
  public let issues: [WorkspaceReadIssue]?

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case query
    case mode
    case sort
    case results
    case corpora
    case issues
  }
}

public struct SearchResult: Decodable, Identifiable, Hashable, Sendable {
  public let file: String
  public let line: Int
  public let lineEnd: Int?
  public let heading: String?
  public let headingLine: Int?
  public let headingLevel: Int?
  public let headingAncestry: [HeadingRef]?
  public let idValue: String?
  public let todo: String?
  public let tags: [String]
  public let snippet: String
  public let sourceRange: SourceRange?
  public let matchedLines: [MatchedLine]?
  public let date: String?
  public let corpus: WorkspaceResultCorpus?

  enum CodingKeys: String, CodingKey {
    case file
    case line
    case lineEnd
    case heading
    case headingLine
    case headingLevel
    case headingAncestry
    case idValue = "id"
    case todo
    case tags
    case snippet
    case sourceRange
    case matchedLines
    case date
    case corpus
  }

  public init(
    file: String,
    line: Int,
    lineEnd: Int?,
    heading: String?,
    headingLine: Int?,
    headingLevel: Int?,
    headingAncestry: [HeadingRef]?,
    idValue: String?,
    todo: String?,
    tags: [String],
    snippet: String,
    sourceRange: SourceRange?,
    matchedLines: [MatchedLine]?,
    date: String?,
    corpus: WorkspaceResultCorpus? = nil
  ) {
    self.file = file
    self.line = line
    self.lineEnd = lineEnd
    self.heading = heading
    self.headingLine = headingLine
    self.headingLevel = headingLevel
    self.headingAncestry = headingAncestry
    self.idValue = idValue
    self.todo = todo
    self.tags = tags
    self.snippet = snippet
    self.sourceRange = sourceRange
    self.matchedLines = matchedLines
    self.date = date
    self.corpus = corpus
  }

  public var id: String {
    "\(file):\(line):\(lineEnd ?? line):\(snippet)"
  }

  public var title: String {
    heading?.isEmpty == false ? heading! : snippet
  }

  public var lineForEditor: Int {
    max(1, line)
  }

  public var isActiveTodo: Bool {
    guard let todo else { return false }
    return !Self.isTerminalTodoStatus(todo)
  }

  public var isTerminalTodo: Bool {
    guard let todo else { return false }
    return Self.isTerminalTodoStatus(todo)
  }

  private static func isTerminalTodoStatus(_ status: String) -> Bool {
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return normalized == "DONE" || normalized == "CANCELED" || normalized == "CANCELLED"
  }
}

public struct SearchResultGroup: Identifiable, Hashable, Sendable {
  public let file: String
  public let representative: SearchResult
  public let results: [SearchResult]

  public init?(file: String, results: [SearchResult]) {
    guard let representative = results.first else { return nil }
    self.file = file
    self.representative = representative
    self.results = results
  }

  public var id: String { file }

  public var additionalCount: Int {
    max(0, results.count - 1)
  }
}

public enum AIChatSearchMatchKind: String, Hashable, Sendable {
  case threadTitle
  case messageText
}

public struct AIChatSearchResult: Identifiable, Hashable, Sendable {
  public let threadID: UUID
  public let messageID: UUID?
  public let matchKind: AIChatSearchMatchKind
  public let title: String
  public let snippet: String
  public let messageCount: Int
  public let updatedAt: Date

  public init(
    threadID: UUID,
    messageID: UUID?,
    matchKind: AIChatSearchMatchKind,
    title: String,
    snippet: String,
    messageCount: Int,
    updatedAt: Date
  ) {
    self.threadID = threadID
    self.messageID = messageID
    self.matchKind = matchKind
    self.title = title
    self.snippet = snippet
    self.messageCount = messageCount
    self.updatedAt = updatedAt
  }

  public var id: String {
    "\(threadID.uuidString):\(messageID?.uuidString ?? "thread")"
  }
}

public enum WorkspaceTextSearchCategory: Int, CaseIterable, Identifiable, Hashable, Sendable {
  case activeTodos
  case files
  case chatThreads
  case approvals
  case agentRuns
  case workflows
  case goals
  case agents
  case pages
  case entries
  case chatMessages
  case corpusText

  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .activeTodos: "Active TODOs"
    case .files: "Files"
    case .chatThreads: "Chat Threads"
    case .approvals: "Approvals"
    case .agentRuns: "Runs"
    case .workflows: "Automations"
    case .goals: "Goals"
    case .agents: "Agents"
    case .pages: "Pages"
    case .entries: "Entries"
    case .chatMessages: "Chat Messages"
    case .corpusText: "Corpus Text"
    }
  }
}

public enum WorkspaceAgentWorkSearchKind: String, Hashable, Sendable {
  case approval
  case run
  case workflow
  case goal
  case agent

  public var category: WorkspaceTextSearchCategory {
    switch self {
    case .approval: .approvals
    case .run: .agentRuns
    case .workflow: .workflows
    case .goal: .goals
    case .agent: .agents
    }
  }

  public var label: String {
    switch self {
    case .approval: "Approval"
    case .run: "Run"
    case .workflow: "Workflow"
    case .goal: "Goal"
    case .agent: "Agent"
    }
  }
}

public struct WorkspaceAgentWorkSearchResult: Identifiable, Hashable, Sendable {
  public let id: String
  public let kind: WorkspaceAgentWorkSearchKind
  public let recordID: String
  public let parentRunID: String?
  public let title: String
  public let snippet: String
  public let status: String
  public let sourceReference: String

  public init(
    id: String,
    kind: WorkspaceAgentWorkSearchKind,
    recordID: String,
    parentRunID: String? = nil,
    title: String,
    snippet: String,
    status: String,
    sourceReference: String
  ) {
    self.id = id
    self.kind = kind
    self.recordID = recordID
    self.parentRunID = parentRunID
    self.title = title
    self.snippet = snippet
    self.status = status
    self.sourceReference = sourceReference
  }
}

public enum WorkspaceTextSearchItem: Identifiable, Hashable, Sendable {
  case activeTodo(SearchResult)
  case file(CorpusFile)
  case chatThread(AIChatSearchResult)
  case agentWork(WorkspaceAgentWorkSearchResult)
  case page(OrgRoamNodeReference)
  case entry(SearchResult)
  case chatMessage(AIChatSearchResult)
  case corpusText(SearchResult)

  public var id: String {
    switch self {
    case .activeTodo(let result): "todo:\(result.id)"
    case .file(let file): "file:\(file.id)"
    case .chatThread(let result): "chat-thread:\(result.id)"
    case .agentWork(let result): "agent-work:\(result.id)"
    case .page(let node): "page:\(node.id)"
    case .entry(let result): "entry:\(result.id)"
    case .chatMessage(let result): "chat-message:\(result.id)"
    case .corpusText(let result): "corpus-text:\(result.id)"
    }
  }

  public var category: WorkspaceTextSearchCategory {
    switch self {
    case .activeTodo: .activeTodos
    case .file: .files
    case .chatThread: .chatThreads
    case .agentWork(let result): result.kind.category
    case .page: .pages
    case .entry: .entries
    case .chatMessage: .chatMessages
    case .corpusText: .corpusText
    }
  }
}

public struct WorkspaceTextSearchSection: Identifiable, Hashable, Sendable {
  public let category: WorkspaceTextSearchCategory
  public let items: [WorkspaceTextSearchItem]

  public var id: WorkspaceTextSearchCategory { category }
}

public struct HeadingRef: Decodable, Hashable, Sendable {
  public let level: Int
  public let title: String
  public let line: Int
  public let lineNumber: Int
}

public struct SourceRange: Decodable, Hashable, Sendable {
  public let startLine: Int
  public let endLine: Int
}

public struct MatchedLine: Decodable, Hashable, Sendable {
  public let line: Int
  public let snippet: String
}

public struct BacklinksPayload: Decodable, Sendable {
  public let schema: String?
  public let id: String
  public let backlinks: [BacklinkItem]

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case id
    case backlinks
  }
}

public struct BacklinkItem: Decodable, Identifiable, Hashable, Sendable {
  public let srcId: String?
  public let srcTitle: String
  public let file: String
  public let line: Int
  public let context: String

  public var id: String {
    "\(file):\(line):\(srcId ?? ""):\(context)"
  }

  public var lineForEditor: Int {
    max(1, line + 1)
  }
}

public struct NodeActionItemsPayload: Decodable, Hashable, Sendable {
  public let schema: String
  public let target: NodeActionTarget
  public let policy: NodeActionPolicy
  public let counts: NodeActionCounts
  public let open: [NodeActionItem]
  public let recentlyCompleted: [NodeActionItem]

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case target
    case policy
    case counts
    case open
    case recentlyCompleted
  }
}

public struct NodeActionTarget: Decodable, Hashable, Sendable {
  public let id: String?
  public let title: String
  public let entityType: String?
  public let file: String
  public let line: Int
}

public struct Org2EntityType: Identifiable, Hashable, Sendable {
  public let rawValue: String

  public init?(_ rawValue: String) {
    let normalized = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(
        of: #"[^a-z0-9_-]+"#,
        with: "_",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    guard !normalized.isEmpty else { return nil }
    self.rawValue = normalized
  }

  public var id: String { rawValue }

  public var title: String {
    rawValue
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  public var systemImage: String {
    switch rawValue {
    case "person": "person.fill"
    case "company", "organization", "account": "building.2.fill"
    case "project": "folder.fill"
    case "meeting": "calendar"
    case "decision": "checkmark.seal.fill"
    case "topic": "tag.fill"
    default: "tag.fill"
    }
  }

  public var supportsActionItems: Bool {
    Self.actionItemTypes.contains(rawValue)
  }

  public static let common: [Org2EntityType] = [
    Org2EntityType("person")!,
    Org2EntityType("company")!,
    Org2EntityType("project")!,
    Org2EntityType("meeting")!,
    Org2EntityType("decision")!,
    Org2EntityType("topic")!,
  ]

  private static let actionItemTypes = Set(["person", "company", "project"])
}

public struct NodeActionPolicy: Decodable, Hashable, Sendable {
  public let recentDays: Int
  public let openLimit: Int
  public let completedLimit: Int
}

public struct NodeActionCounts: Decodable, Hashable, Sendable {
  public let open: Int
  public let recentlyCompleted: Int
}

public struct NodeActionMeeting: Decodable, Hashable, Sendable {
  public let id: String?
  public let title: String
  public let file: String
  public let line: Int
}

public struct NodeActionItem: Decodable, Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let todo: String
  public let file: String
  public let line: Int
  public let lineEnd: Int
  public let relationship: String
  public let meeting: NodeActionMeeting?
  public let date: String?
  public let dateKind: String?
  public let snippet: String?
}

public struct EntrySource: Identifiable, Hashable, Sendable {
  public let file: String
  public let startLine: Int
  public let endLineExclusive: Int
  public let text: String
  public let isSubtree: Bool
  public let isEditable: Bool

  public init(
    file: String,
    startLine: Int,
    endLineExclusive: Int,
    text: String,
    isSubtree: Bool,
    isEditable: Bool = true
  ) {
    self.file = file
    self.startLine = startLine
    self.endLineExclusive = endLineExclusive
    self.text = text
    self.isSubtree = isSubtree
    self.isEditable = isEditable
  }

  public var id: String {
    "\(file):\(startLine):\(endLineExclusive)"
  }

  public var displayRange: String {
    if endLineExclusive <= startLine + 1 { return "\(startLine)" }
    return "\(startLine)-\(endLineExclusive - 1)"
  }
}

public enum OrgInsertBlockKind: String, CaseIterable, Identifiable, Sendable {
  case paragraph
  case heading
  case todo
  case table
  case divider
  case image
  case video
  case properties
  case quote
  case source

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .paragraph: "Text"
    case .heading: "Heading"
    case .todo: "TODO"
    case .table: "Table"
    case .divider: "Divider"
    case .image: "Image"
    case .video: "Video"
    case .properties: "Properties"
    case .quote: "Quote"
    case .source: "Source"
    }
  }

  public var systemImage: String {
    switch self {
    case .paragraph: "text.alignleft"
    case .heading: "textformat.size"
    case .todo: "checklist"
    case .table: "tablecells"
    case .divider: "minus"
    case .image: "photo"
    case .video: "film"
    case .properties: "tag"
    case .quote: "quote.opening"
    case .source: "chevron.left.forwardslash.chevron.right"
    }
  }

  public var slashCommand: String {
    switch self {
    case .paragraph: "text"
    case .heading: "heading"
    case .todo: "todo"
    case .table: "table"
    case .divider: "divider"
    case .image: "image"
    case .video: "video"
    case .properties: "properties"
    case .quote: "quote"
    case .source: "source"
    }
  }
}

public enum OrgBlockMoveDirection: Equatable, Sendable {
  case up
  case down
}

public struct CorpusFile: Identifiable, Hashable, Sendable {
  public let path: String
  public let relativePath: String
  public let directory: String
  public let name: String
  public let modifiedAt: Date?
  public let byteCount: Int64?

  public init(path: String, relativePath: String, modifiedAt: Date?, byteCount: Int64?) {
    self.path = path
    self.relativePath = relativePath
    let directory = NSString(string: relativePath).deletingLastPathComponent
    self.directory = directory == "." || directory == "/" ? "" : directory
    self.name = NSString(string: relativePath).lastPathComponent
    self.modifiedAt = modifiedAt
    self.byteCount = byteCount
  }

  public var id: String { path }
}

public struct CorpusFileTreeNode: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let relativePath: String
  public let file: CorpusFile?
  public let children: [CorpusFileTreeNode]?
  public let descendantFileCount: Int

  public init(
    id: String,
    name: String,
    relativePath: String,
    file: CorpusFile?,
    children: [CorpusFileTreeNode]?,
    descendantFileCount: Int
  ) {
    self.id = id
    self.name = name
    self.relativePath = relativePath
    self.file = file
    self.children = children
    self.descendantFileCount = descendantFileCount
  }

  public var isDirectory: Bool { file == nil }
}

struct CorpusFileTreePresentationRow: Identifiable, Hashable, Sendable {
  let node: CorpusFileTreeNode
  let depth: Int

  var id: String { node.id }
}

enum CorpusFileTreePresentation {
  static func visibleRows(
    in roots: [CorpusFileTreeNode],
    expandedDirectoryIDs: Set<String>
  ) -> [CorpusFileTreePresentationRow] {
    var rows: [CorpusFileTreePresentationRow] = []

    func append(_ nodes: [CorpusFileTreeNode], depth: Int) {
      for node in nodes {
        rows.append(CorpusFileTreePresentationRow(node: node, depth: depth))
        guard node.isDirectory,
              expandedDirectoryIDs.contains(node.id),
              let children = node.children
        else { continue }
        append(children, depth: depth + 1)
      }
    }

    append(roots, depth: 0)
    return rows
  }
}

public struct OrgCryptRecipientFile: Identifiable, Hashable, Sendable {
  public let path: String
  public let relativePath: String
  public let name: String

  public init(path: String, relativePath: String) {
    self.path = path
    self.relativePath = relativePath
    self.name = NSString(string: relativePath).lastPathComponent
  }

  public var id: String { path }
}

public enum EntrySourceMode: String, CaseIterable, Identifiable, Sendable {
  case entry
  case page

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .entry: "Entry"
    case .page: "Page"
    }
  }
}

public struct AIChatThreadRecord: Identifiable, Hashable, Sendable {
  public let title: String
  public let file: String
  public let line: Int
  public let zone: String
  public let modifiedAt: Date?
  public let idValue: String?

  public init(title: String, file: String, line: Int = 1, zone: String, modifiedAt: Date?, idValue: String? = nil) {
    self.title = title
    self.file = file
    self.line = line
    self.zone = zone
    self.modifiedAt = modifiedAt
    self.idValue = idValue
  }

  public var id: String { file }

  public var lineForEditor: Int {
    max(1, line)
  }
}

public struct MeetingWorkspaceItem: Identifiable, Hashable, Sendable {
  public let title: String
  public let file: String
  public let line: Int
  public let recordedAt: String?
  public let modifiedAt: Date?
  public let audioArtifact: String?
  public let systemAudioArtifact: String?
  public let transcriptArtifact: String?
  public let transcriptionStatus: String?
  public let idValue: String?

  public init(
    title: String,
    file: String,
    line: Int = 1,
    recordedAt: String?,
    modifiedAt: Date?,
    audioArtifact: String?,
    systemAudioArtifact: String? = nil,
    transcriptArtifact: String?,
    transcriptionStatus: String?,
    idValue: String?
  ) {
    self.title = title
    self.file = file
    self.line = line
    self.recordedAt = recordedAt
    self.modifiedAt = modifiedAt
    self.audioArtifact = audioArtifact
    self.systemAudioArtifact = systemAudioArtifact
    self.transcriptArtifact = transcriptArtifact
    self.transcriptionStatus = transcriptionStatus
    self.idValue = idValue
  }

  public var id: String { file }

  public var lineForEditor: Int {
    max(1, line)
  }
}

public struct MeetingProcessingItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let status: String
  public let startedAt: Date

  public init(id: String, title: String, status: String, startedAt: Date) {
    self.id = id
    self.title = title
    self.status = status
    self.startedAt = startedAt
  }
}

public enum MeetingReadyAutomationThreadMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case newThread
  case existingThread

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .newThread: "New thread for each meeting"
    case .existingThread: "Existing thread"
    }
  }
}

public struct MeetingReadyAutomationSettings: Hashable, Codable, Sendable {
  public static let defaultPrompt = """
  Process this completed meeting. Extract decisions, follow-ups, and durable context; update the relevant Celorga records; and create review or approval boundaries for any external action. Do not duplicate work if this meeting was already processed. Cite the corpus files you use.
  """

  public var isEnabled: Bool
  public var destinationID: String
  public var threadMode: MeetingReadyAutomationThreadMode
  public var threadID: UUID?
  public var prompt: String

  public init(
    isEnabled: Bool = false,
    destinationID: String = AIChatDestinationConfiguration.openClawID,
    threadMode: MeetingReadyAutomationThreadMode = .newThread,
    threadID: UUID? = nil,
    prompt: String = Self.defaultPrompt
  ) {
    self.isEnabled = isEnabled
    self.destinationID = destinationID
    self.threadMode = threadMode
    self.threadID = threadID
    self.prompt = prompt
  }
}

/// Where a chat message came from and which OpenOrg host handled it. Every
/// field is optional so transcripts written by older builds (and messages
/// posted by tools) stay valid. Hosts are identified by a stable `ref` and a
/// human-readable `name`; the corpus is shared, so these are provenance and
/// routing hints, not access control.
public struct AIChatMessageProvenance: Hashable, Codable, Sendable {
  public enum Client: String, Codable, Sendable {
    case desktop
    case mobile
    case automation
    case inbox
  }

  /// The surface a person or process used to compose the message.
  public var originClient: Client?
  /// A readable device label, such as the paired iPhone's name.
  public var originDeviceName: String?
  /// The OpenOrg host that accepted the message from that client.
  public var receivedByHostRef: String?
  public var receivedByHostName: String?
  /// For user messages, the host responsible for dispatching the turn. For
  /// assistant messages, the host whose runtime produced the reply.
  public var executionHostRef: String?
  public var executionHostName: String?
  /// When the execution host took responsibility for a message another host
  /// handed to it. Absent while the hand-off is still pending.
  public var acceptedAt: Date?
  /// For a turn another agent requested in a shared room (by @mentioning it
  /// or with `org2 thread post --request-turn`): who asked. On the user-role
  /// dispatch message and on the reply it produced.
  public var requestedByLabel: String?
  /// The requesting agent's room destination, when an agent reply asked.
  public var requestedByDestinationID: String?
  /// The visible message that made the request.
  public var requestedByMessageID: UUID?

  public init(
    originClient: Client? = nil,
    originDeviceName: String? = nil,
    receivedByHostRef: String? = nil,
    receivedByHostName: String? = nil,
    executionHostRef: String? = nil,
    executionHostName: String? = nil,
    acceptedAt: Date? = nil,
    requestedByLabel: String? = nil,
    requestedByDestinationID: String? = nil,
    requestedByMessageID: UUID? = nil
  ) {
    self.originClient = originClient
    self.originDeviceName = originDeviceName
    self.receivedByHostRef = receivedByHostRef
    self.receivedByHostName = receivedByHostName
    self.executionHostRef = executionHostRef
    self.executionHostName = executionHostName
    self.acceptedAt = acceptedAt
    self.requestedByLabel = requestedByLabel
    self.requestedByDestinationID = requestedByDestinationID
    self.requestedByMessageID = requestedByMessageID
  }

  public var isEmpty: Bool {
    originClient == nil && originDeviceName == nil && receivedByHostRef == nil
      && receivedByHostName == nil && executionHostRef == nil
      && executionHostName == nil && acceptedAt == nil
      && requestedByLabel == nil && requestedByDestinationID == nil
      && requestedByMessageID == nil
  }

  /// Whether this message is a turn another agent requested.
  public var isAgentTurnRequest: Bool {
    requestedByLabel != nil || requestedByDestinationID != nil
  }

  /// A short caption such as "iPhone via press · ran on press".
  public func caption(role: AIChatMessage.Role) -> String? {
    var parts: [String] = []
    if role == .user {
      let client: String? = {
        if let originDeviceName, !originDeviceName.isEmpty { return originDeviceName }
        switch originClient {
        case .mobile: return "Phone"
        case .automation: return "Automation"
        case .inbox: return "Background agent"
        case .desktop: return receivedByHostName
        case nil: return nil
        }
      }()
      if let client {
        if let receivedByHostName, !receivedByHostName.isEmpty, receivedByHostName != client {
          parts.append("\(client) via \(receivedByHostName)")
        } else {
          parts.append(client)
        }
      } else if let receivedByHostName, !receivedByHostName.isEmpty {
        parts.append("via \(receivedByHostName)")
      }
      if let executionHostName, !executionHostName.isEmpty,
         executionHostName != receivedByHostName {
        parts.append(acceptedAt == nil ? "handing off to \(executionHostName)" : "runs on \(executionHostName)")
      }
    } else if let executionHostName, !executionHostName.isEmpty {
      parts.append("ran on \(executionHostName)")
    }
    if let requestedByLabel, !requestedByLabel.isEmpty {
      parts.insert("requested by \(requestedByLabel)", at: 0)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

public struct AIChatMessage: Identifiable, Hashable, Codable, Sendable {
  public enum Role: String, Codable, Sendable {
    case user
    case assistant
    case system
  }

  public enum DeliveryStatus: String, Codable, Sendable {
    case sent
    case sending
    case failed
    case interrupted
  }

  public enum DeliveryKind: String, Codable, Sendable {
    case turn
    case steer
    case followUp
  }

  public let id: UUID
  public let role: Role
  public let content: String
  public let attachments: [AIChatAttachment]
  public let createdAt: Date
  public let changeSummary: AIChatCorpusChangeSummary?
  public let responseTrace: AIChatResponseTrace?
  public let sendFailure: String?
  public let deliveryStatus: DeliveryStatus
  public let deliveryKind: DeliveryKind
  public let authorRuntime: AIChatRuntime?
  public let authorLabel: String?
  public let authorAgentRef: String?
  public let source: String?
  public let audience: AIChatAudience?
  public let targetRuntime: AIChatRuntime?
  public let authorDestinationID: String?
  public let audienceDestinationIDs: [String]
  public let targetDestinationID: String?
  public let isRoomDispatchCopy: Bool
  public let roomRoundID: UUID?
  public let provenance: AIChatMessageProvenance?

  public init(
    id: UUID = UUID(),
    role: Role,
    content: String,
    attachments: [AIChatAttachment] = [],
    createdAt: Date = Date(),
    changeSummary: AIChatCorpusChangeSummary? = nil,
    responseTrace: AIChatResponseTrace? = nil,
    sendFailure: String? = nil,
    deliveryStatus: DeliveryStatus = .sent,
    deliveryKind: DeliveryKind = .turn,
    authorRuntime: AIChatRuntime? = nil,
    authorLabel: String? = nil,
    authorAgentRef: String? = nil,
    source: String? = nil,
    audience: AIChatAudience? = nil,
    targetRuntime: AIChatRuntime? = nil,
    authorDestinationID: String? = nil,
    audienceDestinationIDs: [String] = [],
    targetDestinationID: String? = nil,
    isRoomDispatchCopy: Bool = false,
    roomRoundID: UUID? = nil,
    provenance: AIChatMessageProvenance? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.attachments = attachments
    self.createdAt = createdAt
    self.changeSummary = changeSummary
    self.responseTrace = responseTrace
    self.sendFailure = sendFailure
    self.deliveryStatus = role == .user ? deliveryStatus : .sent
    self.deliveryKind = role == .user ? deliveryKind : .turn
    self.authorRuntime = role == .user ? nil : authorRuntime
    self.authorLabel = role == .user ? nil : authorLabel
    self.authorAgentRef = role == .user ? nil : authorAgentRef
    self.source = role == .user ? nil : source
    self.audience = role == .user ? audience : nil
    self.targetRuntime = role == .user ? targetRuntime : nil
    self.authorDestinationID = role == .user ? nil : authorDestinationID
    self.audienceDestinationIDs = role == .user ? audienceDestinationIDs : []
    self.targetDestinationID = role == .user ? targetDestinationID : nil
    self.isRoomDispatchCopy = role == .user && isRoomDispatchCopy
    self.roomRoundID = roomRoundID
    self.provenance = provenance?.isEmpty == true ? nil : provenance
  }

  enum CodingKeys: String, CodingKey {
    case id
    case role
    case content
    case attachments
    case createdAt
    case changeSummary
    case responseTrace
    case sendFailure
    case deliveryStatus
    case deliveryKind
    case authorRuntime
    case authorLabel
    case authorAgentRef
    case source
    case audience
    case targetRuntime
    case authorDestinationID
    case audienceDestinationIDs
    case targetDestinationID
    case isRoomDispatchCopy
    case roomRoundID
    case provenance
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    role = try container.decode(Role.self, forKey: .role)
    content = try container.decode(String.self, forKey: .content)
    attachments = try container.decodeIfPresent([AIChatAttachment].self, forKey: .attachments) ?? []
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    changeSummary = try container.decodeIfPresent(AIChatCorpusChangeSummary.self, forKey: .changeSummary)
    responseTrace = try container.decodeIfPresent(AIChatResponseTrace.self, forKey: .responseTrace)
    sendFailure = try container.decodeIfPresent(String.self, forKey: .sendFailure)
    deliveryStatus = role == .user
      ? (try container.decodeIfPresent(DeliveryStatus.self, forKey: .deliveryStatus) ?? (sendFailure == nil ? .sent : .failed))
      : .sent
    deliveryKind = role == .user
      ? (try container.decodeIfPresent(DeliveryKind.self, forKey: .deliveryKind) ?? .turn)
      : .turn
    authorRuntime = role == .user
      ? nil
      : try container.decodeIfPresent(AIChatRuntime.self, forKey: .authorRuntime)
    authorLabel = role == .user
      ? nil
      : try container.decodeIfPresent(String.self, forKey: .authorLabel)
    authorAgentRef = role == .user
      ? nil
      : try container.decodeIfPresent(String.self, forKey: .authorAgentRef)
    source = role == .user
      ? nil
      : try container.decodeIfPresent(String.self, forKey: .source)
    audience = role == .user
      ? try container.decodeIfPresent(AIChatAudience.self, forKey: .audience)
      : nil
    targetRuntime = role == .user
      ? try container.decodeIfPresent(AIChatRuntime.self, forKey: .targetRuntime)
      : nil
    authorDestinationID = role == .user
      ? nil
      : (try container.decodeIfPresent(String.self, forKey: .authorDestinationID)
          ?? authorRuntime.map(AIChatDestinationConfiguration.defaultID(for:)))
    audienceDestinationIDs = role == .user
      ? (try container.decodeIfPresent([String].self, forKey: .audienceDestinationIDs)
          ?? audience?.runtimes.map(AIChatDestinationConfiguration.defaultID(for:))
          ?? [])
      : []
    targetDestinationID = role == .user
      ? (try container.decodeIfPresent(String.self, forKey: .targetDestinationID)
          ?? targetRuntime.map(AIChatDestinationConfiguration.defaultID(for:)))
      : nil
    isRoomDispatchCopy = role == .user
      ? (try container.decodeIfPresent(Bool.self, forKey: .isRoomDispatchCopy) ?? false)
      : false
    roomRoundID = try container.decodeIfPresent(UUID.self, forKey: .roomRoundID)
    provenance = try? container.decodeIfPresent(AIChatMessageProvenance.self, forKey: .provenance)
  }

  public func replacingSendFailure(_ nextSendFailure: String?) -> AIChatMessage {
    AIChatMessage(
      id: id,
      role: role,
      content: content,
      attachments: attachments,
      createdAt: createdAt,
      changeSummary: changeSummary,
      responseTrace: responseTrace,
      sendFailure: nextSendFailure,
      deliveryStatus: nextSendFailure == nil ? .sent : .failed,
      deliveryKind: deliveryKind,
      authorRuntime: authorRuntime,
      authorLabel: authorLabel,
      authorAgentRef: authorAgentRef,
      source: source,
      audience: audience,
      targetRuntime: targetRuntime,
      authorDestinationID: authorDestinationID,
      audienceDestinationIDs: audienceDestinationIDs,
      targetDestinationID: targetDestinationID,
      isRoomDispatchCopy: isRoomDispatchCopy,
      roomRoundID: roomRoundID,
      provenance: provenance
    )
  }

  public func replacingDeliveryStatus(
    _ nextDeliveryStatus: DeliveryStatus,
    sendFailure nextSendFailure: String? = nil
  ) -> AIChatMessage {
    AIChatMessage(
      id: id,
      role: role,
      content: content,
      attachments: attachments,
      createdAt: createdAt,
      changeSummary: changeSummary,
      responseTrace: responseTrace,
      sendFailure: nextSendFailure,
      deliveryStatus: nextDeliveryStatus,
      deliveryKind: deliveryKind,
      authorRuntime: authorRuntime,
      authorLabel: authorLabel,
      authorAgentRef: authorAgentRef,
      source: source,
      audience: audience,
      targetRuntime: targetRuntime,
      authorDestinationID: authorDestinationID,
      audienceDestinationIDs: audienceDestinationIDs,
      targetDestinationID: targetDestinationID,
      isRoomDispatchCopy: isRoomDispatchCopy,
      roomRoundID: roomRoundID,
      provenance: provenance
    )
  }

  public func replacingChangeSummary(_ nextChangeSummary: AIChatCorpusChangeSummary?) -> AIChatMessage {
    AIChatMessage(
      id: id,
      role: role,
      content: content,
      attachments: attachments,
      createdAt: createdAt,
      changeSummary: nextChangeSummary,
      responseTrace: responseTrace,
      sendFailure: sendFailure,
      deliveryStatus: deliveryStatus,
      deliveryKind: deliveryKind,
      authorRuntime: authorRuntime,
      authorLabel: authorLabel,
      authorAgentRef: authorAgentRef,
      source: source,
      audience: audience,
      targetRuntime: targetRuntime,
      authorDestinationID: authorDestinationID,
      audienceDestinationIDs: audienceDestinationIDs,
      targetDestinationID: targetDestinationID,
      isRoomDispatchCopy: isRoomDispatchCopy,
      roomRoundID: roomRoundID,
      provenance: provenance
    )
  }

  public func replacingProvenance(_ nextProvenance: AIChatMessageProvenance?) -> AIChatMessage {
    AIChatMessage(
      id: id,
      role: role,
      content: content,
      attachments: attachments,
      createdAt: createdAt,
      changeSummary: changeSummary,
      responseTrace: responseTrace,
      sendFailure: sendFailure,
      deliveryStatus: deliveryStatus,
      deliveryKind: deliveryKind,
      authorRuntime: authorRuntime,
      authorLabel: authorLabel,
      authorAgentRef: authorAgentRef,
      source: source,
      audience: audience,
      targetRuntime: targetRuntime,
      authorDestinationID: authorDestinationID,
      audienceDestinationIDs: audienceDestinationIDs,
      targetDestinationID: targetDestinationID,
      isRoomDispatchCopy: isRoomDispatchCopy,
      roomRoundID: roomRoundID,
      provenance: nextProvenance
    )
  }

  func replacingAttachments(_ nextAttachments: [AIChatAttachment]) -> AIChatMessage {
    AIChatMessage(
      id: id,
      role: role,
      content: content,
      attachments: nextAttachments,
      createdAt: createdAt,
      changeSummary: changeSummary,
      responseTrace: responseTrace,
      sendFailure: sendFailure,
      deliveryStatus: deliveryStatus,
      deliveryKind: deliveryKind,
      authorRuntime: authorRuntime,
      authorLabel: authorLabel,
      authorAgentRef: authorAgentRef,
      source: source,
      audience: audience,
      targetRuntime: targetRuntime,
      authorDestinationID: authorDestinationID,
      audienceDestinationIDs: audienceDestinationIDs,
      targetDestinationID: targetDestinationID,
      isRoomDispatchCopy: isRoomDispatchCopy,
      roomRoundID: roomRoundID,
      provenance: provenance
    )
  }
}

public struct AIChatResponseTrace: Hashable, Codable, Sendable {
  public let reasoning: String
  public let activities: [AIChatRunActivity]
  public let usage: AIChatTokenUsage?
  public let context: OpenOrgContextTelemetry?

  public init(
    reasoning: String = "",
    activities: [AIChatRunActivity] = [],
    usage: AIChatTokenUsage? = nil,
    context: OpenOrgContextTelemetry? = nil
  ) {
    self.reasoning = reasoning
    self.activities = activities
    self.usage = usage
    self.context = context
  }

  public var isEmpty: Bool {
    reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && activities.isEmpty
      && usage == nil
      && context == nil
  }
}

public struct AIChatAttachment: Identifiable, Hashable, Codable, Sendable {
  public enum DataError: LocalizedError, Sendable {
    case missingBlob(String)
    case unreadableBlob(String)
    case sizeMismatch(String)
    case digestMismatch(String)

    public var errorDescription: String? {
      switch self {
      case .missingBlob(let name):
        "The stored attachment \(name) is missing."
      case .unreadableBlob(let name):
        "The stored attachment \(name) could not be read."
      case .sizeMismatch(let name):
        "The stored attachment \(name) has the wrong size."
      case .digestMismatch(let name):
        "The stored attachment \(name) failed its integrity check."
      }
    }
  }

  public let id: UUID
  public let fileName: String
  public let mimeType: String
  private let inlineData: Data?
  private let blobURL: URL?
  private let storedByteCount: Int
  private let contentDigest: String

  public init(
    id: UUID = UUID(),
    fileName: String,
    mimeType: String,
    data: Data
  ) {
    self.id = id
    self.fileName = fileName
    self.mimeType = mimeType
    inlineData = data
    blobURL = nil
    storedByteCount = data.count
    contentDigest = Self.digest(for: data)
  }

  init(
    id: UUID,
    fileName: String,
    mimeType: String,
    blobURL: URL,
    byteCount: Int,
    contentDigest: String
  ) {
    self.id = id
    self.fileName = fileName
    self.mimeType = mimeType
    inlineData = nil
    self.blobURL = blobURL
    storedByteCount = max(0, byteCount)
    self.contentDigest = contentDigest
  }

  enum CodingKeys: String, CodingKey {
    case id
    case fileName
    case mimeType
    case data
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    fileName = try container.decode(String.self, forKey: .fileName)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    let data = try container.decode(Data.self, forKey: .data)
    inlineData = data
    blobURL = nil
    storedByteCount = data.count
    contentDigest = Self.digest(for: data)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(fileName, forKey: .fileName)
    try container.encode(mimeType, forKey: .mimeType)
    try container.encode(loadData(), forKey: .data)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id
      && lhs.fileName == rhs.fileName
      && lhs.mimeType == rhs.mimeType
      && lhs.storedByteCount == rhs.storedByteCount
      && lhs.contentDigest == rhs.contentDigest
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(fileName)
    hasher.combine(mimeType)
    hasher.combine(storedByteCount)
    hasher.combine(contentDigest)
  }

  /// Loads and verifies attachment bytes. Call this from background work for
  /// blob-backed attachments; SwiftUI bodies must never invoke it directly.
  public func loadData() throws -> Data {
    let loaded: Data
    if let inlineData {
      loaded = inlineData
    } else {
      guard let blobURL else { throw DataError.missingBlob(fileName) }
      guard FileManager.default.fileExists(atPath: blobURL.path) else {
        throw DataError.missingBlob(fileName)
      }
      do {
        loaded = try Data(contentsOf: blobURL, options: .mappedIfSafe)
      } catch {
        throw DataError.unreadableBlob(fileName)
      }
    }
    guard loaded.count == storedByteCount else { throw DataError.sizeMismatch(fileName) }
    guard Self.digest(for: loaded) == contentDigest else { throw DataError.digestMismatch(fileName) }
    return loaded
  }

  /// Inline bytes remain available for compatibility at ingestion boundaries.
  /// Persisted blob bytes deliberately require the throwing `loadData()` API.
  public var data: Data {
    inlineData ?? Data()
  }

  public var byteCount: Int {
    storedByteCount
  }

  public func loadedDataURLString() throws -> String {
    "data:\(mimeType);base64,\(try loadData().base64EncodedString())"
  }

  public func hasSameContent(as other: AIChatAttachment) -> Bool {
    fileName == other.fileName
      && storedByteCount == other.storedByteCount
      && contentDigest == other.contentDigest
  }

  var persistedContentDigest: String {
    contentDigest
  }

  private static func digest(for data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

public struct AIChatResourceReference: Hashable, Codable, Sendable {
  public enum Kind: String, Hashable, Codable, Sendable {
    case heading
    case file
  }

  public let key: String
  public let kind: Kind
  public let title: String
  public let file: String
  public let line: Int
  public let idValue: String?

  public init(
    key: String,
    kind: Kind,
    title: String,
    file: String,
    line: Int,
    idValue: String? = nil
  ) {
    self.key = key
    self.kind = kind
    self.title = title
    self.file = file
    self.line = max(1, line)
    self.idValue = idValue
  }
}

public struct AIChatPendingTurn: Hashable, Codable, Sendable {
  public let userMessageID: UUID
  public let runID: String
  /// Stable client-generated key used to correlate `chat.history` after the
  /// Gateway assigns a different accepted run identifier.
  public let idempotencyKey: String?
  /// Stable machine owner for dispatch/recovery. A synced peer may append a
  /// follow-up, but must not redispatch or stop this host's active provider run.
  public let dispatchOwnerID: String?
  public let agentID: String
  public let destinationID: String?
  public let gatewayMessage: String
  public let contextSectionFingerprints: [String: String]?
  public let startedAt: Date

  public init(
    userMessageID: UUID,
    runID: String,
    idempotencyKey: String? = nil,
    dispatchOwnerID: String? = nil,
    agentID: String,
    destinationID: String? = nil,
    gatewayMessage: String,
    contextSectionFingerprints: [String: String]? = nil,
    startedAt: Date = Date()
  ) {
    self.userMessageID = userMessageID
    self.runID = runID
    self.idempotencyKey = idempotencyKey
    self.dispatchOwnerID = dispatchOwnerID
    self.agentID = agentID
    self.destinationID = destinationID
    self.gatewayMessage = gatewayMessage
    self.contextSectionFingerprints = contextSectionFingerprints
    self.startedAt = startedAt
  }

  public var historyCorrelationID: String {
    idempotencyKey ?? runID
  }

  public func replacingAcceptedRunID(_ acceptedRunID: String) -> AIChatPendingTurn {
    AIChatPendingTurn(
      userMessageID: userMessageID,
      runID: acceptedRunID,
      idempotencyKey: historyCorrelationID,
      dispatchOwnerID: dispatchOwnerID,
      agentID: agentID,
      destinationID: destinationID,
      gatewayMessage: gatewayMessage,
      contextSectionFingerprints: contextSectionFingerprints,
      startedAt: startedAt
    )
  }
}

public enum AIChatAutoSettleInterval: String, CaseIterable, Identifiable, Codable, Sendable {
  case never
  case oneDay
  case threeDays
  case oneWeek
  case twoWeeks
  case thirtyDays

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .never: "Never"
    case .oneDay: "After 1 day"
    case .threeDays: "After 3 days"
    case .oneWeek: "After 1 week"
    case .twoWeeks: "After 2 weeks"
    case .thirtyDays: "After 30 days"
    }
  }

  public var seconds: TimeInterval? {
    switch self {
    case .never: nil
    case .oneDay: 86_400
    case .threeDays: 259_200
    case .oneWeek: 604_800
    case .twoWeeks: 1_209_600
    case .thirtyDays: 2_592_000
    }
  }

  public init(seconds: TimeInterval?) {
    guard let seconds, seconds > 0 else {
      self = .never
      return
    }
    self = Self.allCases
      .filter { $0.seconds != nil }
      .min { abs(($0.seconds ?? 0) - seconds) < abs(($1.seconds ?? 0) - seconds) }
      ?? .never
  }
}

public struct AIChatThreadSettlementSettings: Hashable, Codable, Sendable {
  public let autoSettleAfterSeconds: TimeInterval?

  public init(autoSettleAfterSeconds: TimeInterval? = nil) {
    self.autoSettleAfterSeconds = autoSettleAfterSeconds.flatMap { $0 > 0 ? $0 : nil }
  }

  public var interval: AIChatAutoSettleInterval {
    AIChatAutoSettleInterval(seconds: autoSettleAfterSeconds)
  }
}

public enum AIChatRuntime: String, CaseIterable, Codable, Identifiable, Sendable {
  case openClaw
  case codex
  case claude
  case pi
  case openCode

  public var id: String { rawValue }

  public init?(agentProfileValue raw: String) {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "openclaw": self = .openClaw
    case "codex": self = .codex
    case "claude": self = .claude
    case "pi": self = .pi
    case "opencode": self = .openCode
    default: return nil
    }
  }

  public var agentProfileValue: String {
    switch self {
    case .openClaw: "openclaw"
    case .codex: "codex"
    case .claude: "claude"
    case .pi: "pi"
    case .openCode: "opencode"
    }
  }

  public var title: String {
    switch self {
    case .openClaw: "OpenClaw"
    case .codex: "Codex"
    case .claude: "Claude Code"
    case .pi: "Pi"
    case .openCode: "OpenCode"
    }
  }

  public var systemImage: String {
    switch self {
    case .openClaw: "network"
    case .codex: "chevron.left.forwardslash.chevron.right"
    case .claude: "c.circle"
    case .pi: "pi"
    case .openCode: "terminal"
    }
  }
}

public enum AIChatDestinationAdapter: String, CaseIterable, Codable, Identifiable, Sendable {
  case codexLocal
  case claudeLocal
  case piLocal
  case piRemote
  case openCodeLocal
  case openCodeRemote
  case codexRemote
  case codexManagedRemote
  case openClaw
  case openAI
  case anthropic
  case openRouter
  case ollama

  public var id: String { rawValue }

  public var runtime: AIChatRuntime {
    switch self {
    case .codexLocal, .codexRemote, .codexManagedRemote: .codex
    case .claudeLocal: .claude
    case .piLocal, .piRemote: .pi
    case .openCodeLocal, .openCodeRemote: .openCode
    case .openClaw, .openAI, .anthropic, .openRouter, .ollama: .openClaw
    }
  }

  public var title: String {
    switch self {
    case .codexLocal: "Local Codex"
    case .claudeLocal: "Local Claude Code"
    case .piLocal: "Local Pi"
    case .piRemote: "Remote Pi over SSH"
    case .openCodeLocal: "Local OpenCode"
    case .openCodeRemote: "Remote OpenCode over SSH"
    case .codexRemote: "Remote Codex"
    case .codexManagedRemote: "Remote Codex over SSH"
    case .openClaw: "OpenClaw Gateway"
    case .openAI: "OpenAI API"
    case .anthropic: "Anthropic API"
    case .openRouter: "OpenRouter"
    case .ollama: "Ollama"
    }
  }

  public var systemImage: String {
    switch self {
    case .codexLocal, .codexRemote, .codexManagedRemote: AIChatRuntime.codex.systemImage
    case .claudeLocal: AIChatRuntime.claude.systemImage
    case .piLocal, .piRemote: AIChatRuntime.pi.systemImage
    case .openCodeLocal, .openCodeRemote: AIChatRuntime.openCode.systemImage
    case .openClaw: AIChatRuntime.openClaw.systemImage
    case .openAI: "sparkles"
    case .anthropic: "a.circle"
    case .openRouter: "arrow.triangle.branch"
    case .ollama: "desktopcomputer"
    }
  }

  public var isDirectProvider: Bool {
    switch self {
    case .openAI, .anthropic, .openRouter, .ollama: true
    case .codexLocal, .claudeLocal, .piLocal, .piRemote,
         .openCodeLocal, .openCodeRemote,
         .codexRemote, .codexManagedRemote, .openClaw: false
    }
  }

  public var requiresAPIKey: Bool {
    switch self {
    case .openAI, .anthropic, .openRouter: true
    case .codexLocal, .claudeLocal, .piLocal, .piRemote,
         .openCodeLocal, .openCodeRemote,
         .codexRemote, .codexManagedRemote, .openClaw, .ollama: false
    }
  }

  public var defaultEndpoint: String {
    switch self {
    case .openAI: "https://api.openai.com/v1"
    case .anthropic: "https://api.anthropic.com/v1"
    case .openRouter: "https://openrouter.ai/api/v1"
    case .ollama: "http://127.0.0.1:11434/api"
    case .codexLocal, .claudeLocal, .piLocal, .piRemote,
         .openCodeLocal, .openCodeRemote,
         .codexRemote, .codexManagedRemote, .openClaw: ""
    }
  }

  public var defaultName: String {
    switch self {
    case .codexLocal: "Codex"
    case .claudeLocal: "Claude Code"
    case .piLocal: "Pi"
    case .piRemote: "Remote Pi"
    case .openCodeLocal: "OpenCode"
    case .openCodeRemote: "Remote OpenCode"
    case .codexRemote: "Remote Codex"
    case .codexManagedRemote: "Remote Codex"
    case .openClaw: "OpenClaw"
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .openRouter: "OpenRouter"
    case .ollama: "Ollama"
    }
  }

  public var defaultMention: String {
    switch self {
    case .codexLocal: "codex"
    case .claudeLocal: "claude"
    case .piLocal: "pi"
    case .piRemote: "pi-remote"
    case .openCodeLocal: "opencode"
    case .openCodeRemote: "opencode-remote"
    case .codexRemote: "codex-remote"
    case .codexManagedRemote: "codex-managed"
    case .openClaw: "openclaw"
    case .openAI: "openai"
    case .anthropic: "anthropic"
    case .openRouter: "openrouter"
    case .ollama: "ollama"
    }
  }
}

public struct AIChatDestinationConfiguration: Identifiable, Hashable, Codable, Sendable {
  public static let localCodexID = "builtin.codex"
  public static let localClaudeID = "builtin.claude"
  public static let localPiID = "builtin.pi"
  public static let localOpenCodeID = "builtin.opencode"
  public static let openClawID = "builtin.openclaw"

  public let id: String
  public var name: String
  public var mention: String
  public var adapter: AIChatDestinationAdapter
  public var endpoint: String
  public var agentID: String
  public var workspaceRoot: String
  public var model: String?
  public var isEnabled: Bool

  /// Optional for backwards-compatible decoding of existing destinations.
  public var workspaceToolsEnabled: Bool? = nil

  public func usesBundledAgent(experimentalFeaturesEnabled: Bool) -> Bool {
    experimentalFeaturesEnabled && adapter.isDirectProvider && workspaceToolsEnabled == true
  }

  public init(
    id: String = UUID().uuidString.lowercased(),
    name: String,
    mention: String,
    adapter: AIChatDestinationAdapter,
    endpoint: String = "",
    agentID: String = "",
    workspaceRoot: String = "",
    model: String? = nil,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.mention = Self.normalizedMention(mention)
    self.adapter = adapter
    self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    self.agentID = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.workspaceRoot = workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.model = normalizedModel?.isEmpty == false ? normalizedModel : nil
    self.isEnabled = isEnabled
  }

  public var runtime: AIChatRuntime { adapter.runtime }
  public var title: String { name.isEmpty ? mention : name }
  public var systemImage: String { adapter.systemImage }
  public var mentionText: String { "@\(mention)" }
  public var requiresEndpoint: Bool {
    adapter != .codexLocal && adapter != .claudeLocal && adapter != .piLocal
      && adapter != .openCodeLocal
  }
  public var acceptsBearerToken: Bool {
    adapter != .codexLocal && adapter != .claudeLocal && adapter != .piLocal
      && adapter != .piRemote && adapter != .openCodeLocal
      && adapter != .openCodeRemote && adapter != .codexManagedRemote
  }

  /// A readable name for the machine where this destination's agent harness
  /// actually runs, when that is not the OpenOrg host driving the turn.
  /// SSH-managed remotes run on their SSH host; endpoint-based remotes run on
  /// their endpoint's host. Local and direct-provider destinations return nil.
  public var harnessHostName: String? {
    let rawHost: String?
    switch adapter {
    case .piRemote, .openCodeRemote, .codexManagedRemote:
      rawHost = Self.sshHostName(endpoint)
    case .codexRemote, .openClaw:
      rawHost = URL(string: endpoint)?.host
    case .codexLocal, .claudeLocal, .piLocal, .openCodeLocal,
         .openAI, .anthropic, .openRouter, .ollama:
      rawHost = nil
    }
    guard let host = rawHost?
      .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !host.isEmpty
    else { return nil }
    let lowered = host.lowercased()
    guard !["localhost", "127.0.0.1", "::1"].contains(lowered) else { return nil }
    // Present LAN and tailnet names as the bare machine name ("press").
    for suffix in [".local", ".ts.net"] where lowered.hasSuffix(suffix) {
      if let machine = host.split(separator: ".").first, !machine.isEmpty {
        return String(machine)
      }
    }
    return host
  }

  private static func sshHostName(_ target: String) -> String? {
    var host = Substring(target.trimmingCharacters(in: .whitespacesAndNewlines))
    if host.hasPrefix("ssh://") { host = host.dropFirst("ssh://".count) }
    if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
    if let slash = host.firstIndex(of: "/") { host = host[..<slash] }
    if !host.hasPrefix("["), host.filter({ $0 == ":" }).count == 1,
       let colon = host.firstIndex(of: ":") {
      host = host[..<colon]
    }
    return host.isEmpty ? nil : String(host)
  }

  public static var defaults: [AIChatDestinationConfiguration] {
    [
      AIChatDestinationConfiguration(
        id: localCodexID,
        name: "Codex",
        mention: "codex",
        adapter: .codexLocal
      ),
      AIChatDestinationConfiguration(
        id: openClawID,
        name: "OpenClaw",
        mention: "openclaw",
        adapter: .openClaw
      ),
      AIChatDestinationConfiguration(
        id: localClaudeID,
        name: "Claude Code",
        mention: "claude",
        adapter: .claudeLocal,
        isEnabled: false
      ),
      AIChatDestinationConfiguration(
        id: localPiID,
        name: "Pi",
        mention: "pi",
        adapter: .piLocal,
        isEnabled: false
      ),
      AIChatDestinationConfiguration(
        id: localOpenCodeID,
        name: "OpenCode",
        mention: "opencode",
        adapter: .openCodeLocal,
        isEnabled: false
      )
    ]
  }

  public static func defaultID(for runtime: AIChatRuntime) -> String {
    switch runtime {
    case .codex: localCodexID
    case .claude: localClaudeID
    case .pi: localPiID
    case .openCode: localOpenCodeID
    case .openClaw: openClawID
    }
  }

  public static func normalizedMention(_ raw: String) -> String {
    let lowered = raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
      .lowercased()
    let allowed = lowered.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    }
    let normalized = String(String.UnicodeScalarView(allowed))
      .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    return normalized.isEmpty ? "agent" : String(normalized.prefix(48))
  }
}

public struct AIChatDestinationRouting: Equatable, Sendable {
  public let destinationIDs: [String]
  public let normalizedText: String
  public let summary: String

  public init(
    _ rawText: String,
    destinations: [AIChatDestinationConfiguration],
    allDestinationIDs: [String]? = nil
  ) {
    let enabled = destinations.filter(\.isEnabled)
    let byMention = Dictionary(uniqueKeysWithValues: enabled.map { ($0.mention.lowercased(), $0) })
    let source = rawText as NSString
    let matches = Self.mentionPattern.matches(
      in: rawText,
      range: NSRange(location: 0, length: source.length)
    )
    var selected: [String] = []
    var normalized = rawText
    var expandsAll = false

    for match in matches {
      guard match.numberOfRanges > 1 else { continue }
      let mention = source.substring(with: match.range(at: 1)).lowercased()
      if mention == "all" || mention == "both" {
        expandsAll = true
      } else if let destination = byMention[mention], !selected.contains(destination.id) {
        selected.append(destination.id)
      } else if mention == "codex",
                let destination = enabled.first(where: { $0.id == AIChatDestinationConfiguration.localCodexID }),
                !selected.contains(destination.id) {
        selected.append(destination.id)
      } else if mention == "openclaw",
                let destination = enabled.first(where: { $0.id == AIChatDestinationConfiguration.openClawID }),
                !selected.contains(destination.id) {
        selected.append(destination.id)
      } else if mention == "claude",
                let destination = enabled.first(where: { $0.id == AIChatDestinationConfiguration.localClaudeID }),
                !selected.contains(destination.id) {
        selected.append(destination.id)
      }
    }

    if expandsAll {
      let allowed = Set(allDestinationIDs ?? enabled.map(\.id))
      for destination in enabled where allowed.contains(destination.id) && !selected.contains(destination.id) {
        selected.append(destination.id)
      }
    }

    for match in matches.reversed() {
      guard match.numberOfRanges > 1 else { continue }
      let mention = source.substring(with: match.range(at: 1)).lowercased()
      let replacement: String
      if mention == "all" || mention == "both" {
        replacement = selected.compactMap { id in
          enabled.first(where: { $0.id == id })?.mentionText
        }.joined(separator: " ")
      } else if let destination = byMention[mention] {
        replacement = destination.mentionText
      } else if mention == "codex",
                let destination = enabled.first(where: { $0.id == AIChatDestinationConfiguration.localCodexID }) {
        replacement = destination.mentionText
      } else if mention == "openclaw",
                let destination = enabled.first(where: { $0.id == AIChatDestinationConfiguration.openClawID }) {
        replacement = destination.mentionText
      } else if mention == "claude",
                let destination = enabled.first(where: { $0.id == AIChatDestinationConfiguration.localClaudeID }) {
        replacement = destination.mentionText
      } else if mention == "pi",
                let destination = enabled.first(where: { $0.id == AIChatDestinationConfiguration.localPiID }) {
        replacement = destination.mentionText
      } else if mention == "opencode",
                let destination = enabled.first(where: { $0.id == AIChatDestinationConfiguration.localOpenCodeID }) {
        replacement = destination.mentionText
      } else {
        continue
      }
      normalized = (normalized as NSString).replacingCharacters(in: match.range, with: replacement)
    }

    destinationIDs = selected
    normalizedText = normalized
    let names = selected.compactMap { id in enabled.first(where: { $0.id == id })?.title }
    summary = names.isEmpty
      ? "Posts to thread · no agents invoked"
      : "Invokes \(names.joined(separator: " + "))"
  }

  private static let mentionPattern = try! NSRegularExpression(
    pattern: #"(?i)(?<![A-Za-z0-9_])@([A-Za-z0-9][A-Za-z0-9_-]*)(?![A-Za-z0-9_-])"#
  )
}

public enum AIChatAudience: String, CaseIterable, Codable, Identifiable, Sendable {
  case thread
  case openClaw
  case codex
  case claude
  case pi
  case openCode
  case everyone

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .thread: "Thread"
    case .openClaw: "OpenClaw"
    case .codex: "Codex"
    case .claude: "Claude Code"
    case .pi: "Pi"
    case .openCode: "OpenCode"
    case .everyone: "All agents"
    }
  }

  public var composerTitle: String {
    switch self {
    case .thread: "Post context"
    case .openClaw: "Ask OpenClaw"
    case .codex: "Ask Codex"
    case .claude: "Ask Claude Code"
    case .pi: "Ask Pi"
    case .openCode: "Ask OpenCode"
    case .everyone: "Ask all"
    }
  }

  public var systemImage: String {
    switch self {
    case .thread: "text.bubble"
    case .openClaw: AIChatRuntime.openClaw.systemImage
    case .codex: AIChatRuntime.codex.systemImage
    case .claude: AIChatRuntime.claude.systemImage
    case .pi: AIChatRuntime.pi.systemImage
    case .openCode: AIChatRuntime.openCode.systemImage
    case .everyone: "person.2.fill"
    }
  }

  public var runtimes: [AIChatRuntime] {
    switch self {
    case .thread: []
    case .openClaw: [.openClaw]
    case .codex: [.codex]
    case .claude: [.claude]
    case .pi: [.pi]
    case .openCode: [.openCode]
    case .everyone: AIChatRuntime.allCases
    }
  }

  public init(runtime: AIChatRuntime) {
    switch runtime {
    case .codex: self = .codex
    case .claude: self = .claude
    case .pi: self = .pi
    case .openCode: self = .openCode
    case .openClaw: self = .openClaw
    }
  }
}

public struct AIChatRoomRouting: Equatable, Sendable {
  public let audience: AIChatAudience
  public let normalizedText: String

  public init(_ rawText: String) {
    let source = rawText as NSString
    let matches = Self.mentionPattern.matches(
      in: rawText,
      range: NSRange(location: 0, length: source.length)
    )
    var invokesCodex = false
    var invokesOpenClaw = false
    var invokesClaude = false
    var invokesPi = false
    var invokesOpenCode = false
    var normalized = rawText

    for match in matches {
      guard match.numberOfRanges > 1 else { continue }
      switch source.substring(with: match.range(at: 1)).lowercased() {
      case "codex":
        invokesCodex = true
      case "openclaw":
        invokesOpenClaw = true
      case "claude":
        invokesClaude = true
      case "pi":
        invokesPi = true
      case "opencode":
        invokesOpenCode = true
      case "all", "both":
        invokesCodex = true
        invokesOpenClaw = true
        invokesClaude = true
        invokesPi = true
        invokesOpenCode = true
      default:
        break
      }
    }

    for match in matches.reversed() {
      guard match.numberOfRanges > 1 else { continue }
      let mention = source.substring(with: match.range(at: 1)).lowercased()
      let replacement: String
      switch mention {
      case "codex": replacement = "@Codex"
      case "openclaw": replacement = "@OpenClaw"
      case "claude": replacement = "@Claude"
      case "pi": replacement = "@Pi"
      case "opencode": replacement = "@OpenCode"
      case "all", "both": replacement = "@Codex @Claude @Pi @OpenCode @OpenClaw"
      default: continue
      }
      normalized = (normalized as NSString).replacingCharacters(in: match.range, with: replacement)
    }

    if invokesCodex && invokesOpenClaw && invokesClaude && invokesPi && invokesOpenCode {
      audience = .everyone
    } else if invokesOpenCode {
      audience = .openCode
    } else if invokesPi {
      audience = .pi
    } else if invokesClaude {
      audience = .claude
    } else if invokesCodex {
      audience = .codex
    } else if invokesOpenClaw {
      audience = .openClaw
    } else {
      audience = .thread
    }
    normalizedText = normalized
  }

  public var summary: String {
    switch audience {
    case .thread: "Posts to thread · no agents invoked"
    case .codex: "Invokes Codex"
    case .claude: "Invokes Claude Code"
    case .pi: "Invokes Pi"
    case .openCode: "Invokes OpenCode"
    case .openClaw: "Invokes OpenClaw"
    case .everyone: "Invokes all agents"
    }
  }

  private static let mentionPattern = try! NSRegularExpression(
    pattern: #"(?i)(?<![A-Za-z0-9_])@(codex|claude|pi|opencode|openclaw|all|both)(?![A-Za-z0-9_])"#
  )
}

public enum AIChatMessageDeliveryPreference: String, Codable, Sendable {
  case automatic
  case steer
  case followUp
}

/// User-chosen harness, model, and reasoning effort for node briefs.
public struct NodeBriefAIConfiguration: Hashable, Codable, Sendable {
  public var destinationID: String?
  public var model: String?
  public var reasoningEffort: String?

  public init(destinationID: String? = nil, model: String? = nil, reasoningEffort: String? = nil) {
    self.destinationID = Self.normalized(destinationID)
    self.model = Self.normalized(model)
    self.reasoningEffort = Self.normalized(reasoningEffort)
  }

  public var isDefault: Bool {
    destinationID == nil && model == nil && reasoningEffort == nil
  }

  private static func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

public struct AIChatReasoningOption: Identifiable, Hashable, Codable, Sendable {
  public let id: String
  public let label: String
  public let detail: String?

  public init(id: String, label: String, detail: String? = nil) {
    self.id = id
    self.label = label
    self.detail = detail
  }
}

public struct AIChatModelOption: Identifiable, Hashable, Codable, Sendable {
  public let id: String
  public let label: String
  public let detail: String?
  public let supportsReasoning: Bool
  public let reasoningOptions: [AIChatReasoningOption]
  public let defaultReasoningEffort: String?
  public let isDefault: Bool

  public init(
    id: String,
    label: String,
    detail: String? = nil,
    supportsReasoning: Bool = false,
    reasoningOptions: [AIChatReasoningOption] = [],
    defaultReasoningEffort: String? = nil,
    isDefault: Bool = false
  ) {
    self.id = id
    self.label = label
    self.detail = detail
    self.supportsReasoning = supportsReasoning
    self.reasoningOptions = reasoningOptions
    self.defaultReasoningEffort = defaultReasoningEffort
    self.isDefault = isDefault
  }
}

public struct AIChatRemoteConfiguration: Sendable {
  public let models: [AIChatModelOption]
  public let effectiveModel: String?
  public let reasoningEffort: String?
  public let reasoningOptions: [AIChatReasoningOption]
  public let defaultReasoningEffort: String?

  public init(
    models: [AIChatModelOption],
    effectiveModel: String?,
    reasoningEffort: String?,
    reasoningOptions: [AIChatReasoningOption],
    defaultReasoningEffort: String?
  ) {
    self.models = models
    self.effectiveModel = effectiveModel
    self.reasoningEffort = reasoningEffort
    self.reasoningOptions = reasoningOptions
    self.defaultReasoningEffort = defaultReasoningEffort
  }
}

public struct AIChatRoomModelSelection: Hashable, Codable, Sendable {
  public let codex: String?
  public let openClaw: String?
  public let claude: String?
  public let pi: String?
  public let openCode: String?

  public init(
    codex: String? = nil,
    openClaw: String? = nil,
    claude: String? = nil,
    pi: String? = nil,
    openCode: String? = nil
  ) {
    self.codex = codex
    self.openClaw = openClaw
    self.claude = claude
    self.pi = pi
    self.openCode = openCode
  }

  public func model(for runtime: AIChatRuntime) -> String? {
    switch runtime {
    case .codex: codex
    case .openClaw: openClaw
    case .claude: claude
    case .pi: pi
    case .openCode: openCode
    }
  }

  public func replacingModel(_ model: String?, for runtime: AIChatRuntime) -> AIChatRoomModelSelection {
    switch runtime {
    case .codex:
      AIChatRoomModelSelection(codex: model, openClaw: openClaw, claude: claude, pi: pi, openCode: openCode)
    case .openClaw:
      AIChatRoomModelSelection(codex: codex, openClaw: model, claude: claude, pi: pi, openCode: openCode)
    case .claude:
      AIChatRoomModelSelection(codex: codex, openClaw: openClaw, claude: model, pi: pi, openCode: openCode)
    case .pi:
      AIChatRoomModelSelection(codex: codex, openClaw: openClaw, claude: claude, pi: model, openCode: openCode)
    case .openCode:
      AIChatRoomModelSelection(codex: codex, openClaw: openClaw, claude: claude, pi: pi, openCode: model)
    }
  }
}

public struct AIChatThread: Identifiable, Hashable, Codable, Sendable {
  public let id: UUID
  public let title: String
  public let createdAt: Date
  public let updatedAt: Date
  public let runtime: AIChatRuntime
  public let agentRef: String?
  public let destinationID: String
  public let sessionKey: String
  public let runtimeThreadID: String?
  public let runtimeThreadIDsByDestination: [String: String]
  public let model: String?
  public let reasoningEffort: String?
  public let messages: [AIChatMessage]
  public let storedMessageCount: Int?
  public let storedHasUnresolvedLatestDelivery: Bool?
  public let storedLatestDeliveryNeedsAttention: Bool?
  /// The latest visible assistant reply of a metadata-only placeholder.
  /// Remote clients key reply notifications on it, so evicting a transcript
  /// must not make its latest reply look absent and then new again.
  public let storedLatestAssistantMessageID: UUID?
  public let isPinned: Bool
  public let isArchived: Bool
  public let settledAt: Date?
  public let unreadMessageCount: Int
  public let resource: AIChatResourceReference?
  public let pendingTurn: AIChatPendingTurn?
  public let isSharedRoom: Bool
  public let roomAudience: AIChatAudience
  public let roomModels: AIChatRoomModelSelection
  public let roomDestinationIDs: [String]
  public let roomModelsByDestination: [String: String]
  /// The shared-room agent that receives messages without an @mention.
  /// `nil` means it was never chosen and follows the room's first agent;
  /// `noRoomDefaultDestinationID` means the user chose to post context only.
  public let roomDefaultDestinationID: String?
  /// How many agent-requested turns may run back to back in this shared
  /// room before a person must reply. `nil` follows
  /// `defaultRoomAgentTurnLimit`; `0` turns agent hand-offs off.
  public let roomAgentTurnLimit: Int?

  public static let noRoomDefaultDestinationID = ""
  public static let defaultRoomAgentTurnLimit = 4
  public static let maxRoomAgentTurnLimit = 50

  /// The agent-requested turn limit this room enforces.
  public var effectiveRoomAgentTurnLimit: Int {
    roomAgentTurnLimit ?? Self.defaultRoomAgentTurnLimit
  }

  public init(
    id: UUID = UUID(),
    title: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    runtime: AIChatRuntime = .openClaw,
    destinationID: String? = nil,
    sessionKey: String,
    runtimeThreadID: String? = nil,
    runtimeThreadIDsByDestination: [String: String] = [:],
    model: String? = nil,
    reasoningEffort: String? = nil,
    messages: [AIChatMessage] = [],
    storedMessageCount: Int? = nil,
    storedHasUnresolvedLatestDelivery: Bool? = nil,
    storedLatestDeliveryNeedsAttention: Bool? = nil,
    storedLatestAssistantMessageID: UUID? = nil,
    isPinned: Bool = false,
    isArchived: Bool = false,
    settledAt: Date? = nil,
    unreadMessageCount: Int = 0,
    resource: AIChatResourceReference? = nil,
    pendingTurn: AIChatPendingTurn? = nil,
    isSharedRoom: Bool = false,
    roomAudience: AIChatAudience = .thread,
    roomModels: AIChatRoomModelSelection = AIChatRoomModelSelection(),
    roomDestinationIDs: [String] = [],
    roomModelsByDestination: [String: String] = [:],
    roomDefaultDestinationID: String? = nil,
    roomAgentTurnLimit: Int? = nil,
    agentRef: String? = nil
  ) {
    self.agentRef = agentRef
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.runtime = runtime
    self.destinationID = destinationID ?? AIChatDestinationConfiguration.defaultID(for: runtime)
    self.sessionKey = sessionKey
    self.runtimeThreadID = runtimeThreadID
    self.runtimeThreadIDsByDestination = runtimeThreadIDsByDestination
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.messages = messages
    self.storedMessageCount = storedMessageCount.map { max(0, $0) }
    self.storedHasUnresolvedLatestDelivery = storedHasUnresolvedLatestDelivery
    self.storedLatestDeliveryNeedsAttention = storedLatestDeliveryNeedsAttention
    self.storedLatestAssistantMessageID = storedLatestAssistantMessageID
    self.isPinned = isPinned
    self.isArchived = isArchived
    self.settledAt = settledAt ?? (isArchived ? updatedAt : nil)
    self.unreadMessageCount = max(0, unreadMessageCount)
    self.resource = resource
    self.pendingTurn = pendingTurn
    self.isSharedRoom = isSharedRoom
    self.roomAudience = isSharedRoom ? roomAudience : AIChatAudience(runtime: runtime)
    self.roomModels = isSharedRoom ? roomModels : AIChatRoomModelSelection()
    self.roomDestinationIDs = isSharedRoom
      ? (roomDestinationIDs.isEmpty
          ? AIChatRuntime.allCases.map(AIChatDestinationConfiguration.defaultID(for:))
          : roomDestinationIDs)
      : []
    self.roomModelsByDestination = isSharedRoom ? roomModelsByDestination : [:]
    self.roomDefaultDestinationID = isSharedRoom ? roomDefaultDestinationID : nil
    self.roomAgentTurnLimit = isSharedRoom
      ? roomAgentTurnLimit.map { min(max($0, 0), Self.maxRoomAgentTurnLimit) }
      : nil
  }

  public var messageCount: Int {
    storedMessageCount ?? messages.lazy.filter { !$0.isRoomDispatchCopy }.count
  }

  public var isSettled: Bool {
    settledAt != nil || isArchived
  }

  public var canChangeAIRuntime: Bool {
    !isSharedRoom && messageCount == 0 && pendingTurn == nil
  }

  public var hasUnresolvedLatestDelivery: Bool {
    if let storedHasUnresolvedLatestDelivery { return storedHasUnresolvedLatestDelivery }
    guard let latestMessage = messages.last else { return false }
    return latestMessage.deliveryStatus == .sending
      || latestDeliveryNeedsAttention
  }

  public var latestDeliveryNeedsAttention: Bool {
    if let storedLatestDeliveryNeedsAttention { return storedLatestDeliveryNeedsAttention }
    guard let latestMessage = messages.last else { return false }
    return latestMessage.deliveryStatus == .failed
      || latestMessage.deliveryStatus == .interrupted
      || latestMessage.sendFailure != nil
  }

  /// The newest assistant message with visible text, as projected to remote
  /// clients. Placeholders report the value captured when they were evicted.
  public var latestAssistantMessageID: UUID? {
    if let storedLatestAssistantMessageID { return storedLatestAssistantMessageID }
    return messages.last(where: { message in
      message.role == .assistant && message.content.contains(where: { !$0.isWhitespace })
    })?.id
  }

  enum CodingKeys: String, CodingKey {
    case agentRef
    case id
    case title
    case createdAt
    case updatedAt
    case runtime
    case destinationID
    case sessionKey
    case runtimeThreadID
    case runtimeThreadIDsByDestination
    case model
    case reasoningEffort
    case messages
    case storedMessageCount
    case storedHasUnresolvedLatestDelivery
    case storedLatestDeliveryNeedsAttention
    case storedLatestAssistantMessageID
    case isPinned
    case isArchived
    case settledAt
    case unreadMessageCount
    case resource
    case pendingTurn
    case isSharedRoom
    case roomAudience
    case roomModels
    case roomDestinationIDs
    case roomModelsByDestination
    case roomDefaultDestinationID
    case roomAgentTurnLimit
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agentRef = try container.decodeIfPresent(String.self, forKey: .agentRef)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    runtime = try container.decodeIfPresent(AIChatRuntime.self, forKey: .runtime) ?? .openClaw
    destinationID = try container.decodeIfPresent(String.self, forKey: .destinationID)
      ?? AIChatDestinationConfiguration.defaultID(for: runtime)
    sessionKey = try container.decode(String.self, forKey: .sessionKey)
    runtimeThreadID = try container.decodeIfPresent(String.self, forKey: .runtimeThreadID)
    let decodedRuntimeThreadIDsByDestination = try container.decodeIfPresent(
      [String: String].self,
      forKey: .runtimeThreadIDsByDestination
    )
    let legacyRuntimeThreadIDsByDestination: [String: String]
    if let runtimeThreadID {
      legacyRuntimeThreadIDsByDestination = [destinationID: runtimeThreadID]
    } else {
      legacyRuntimeThreadIDsByDestination = [:]
    }
    runtimeThreadIDsByDestination = decodedRuntimeThreadIDsByDestination
      ?? legacyRuntimeThreadIDsByDestination
    model = try container.decodeIfPresent(String.self, forKey: .model)
    reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
    messages = try container.decodeIfPresent([AIChatMessage].self, forKey: .messages) ?? []
    storedMessageCount = try container.decodeIfPresent(Int.self, forKey: .storedMessageCount)
    storedHasUnresolvedLatestDelivery = try container.decodeIfPresent(
      Bool.self,
      forKey: .storedHasUnresolvedLatestDelivery
    )
    storedLatestDeliveryNeedsAttention = try container.decodeIfPresent(
      Bool.self,
      forKey: .storedLatestDeliveryNeedsAttention
    )
    storedLatestAssistantMessageID = try container.decodeIfPresent(
      UUID.self,
      forKey: .storedLatestAssistantMessageID
    )
    isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    settledAt = try container.decodeIfPresent(Date.self, forKey: .settledAt) ?? (isArchived ? updatedAt : nil)
    unreadMessageCount = max(0, try container.decodeIfPresent(Int.self, forKey: .unreadMessageCount) ?? 0)
    resource = try container.decodeIfPresent(AIChatResourceReference.self, forKey: .resource)
    pendingTurn = try container.decodeIfPresent(AIChatPendingTurn.self, forKey: .pendingTurn)
    isSharedRoom = try container.decodeIfPresent(Bool.self, forKey: .isSharedRoom) ?? false
    roomAudience = isSharedRoom
      ? (try container.decodeIfPresent(AIChatAudience.self, forKey: .roomAudience) ?? .thread)
      : AIChatAudience(runtime: runtime)
    roomModels = isSharedRoom
      ? (try container.decodeIfPresent(AIChatRoomModelSelection.self, forKey: .roomModels)
          ?? AIChatRoomModelSelection())
      : AIChatRoomModelSelection()
    roomDestinationIDs = isSharedRoom
      ? (try container.decodeIfPresent([String].self, forKey: .roomDestinationIDs)
          ?? Self.legacyRoomDestinationIDs(for: roomAudience))
      : []
    let decodedRoomModelsByDestination = try container.decodeIfPresent(
      [String: String].self,
      forKey: .roomModelsByDestination
    )
    var migratedRoomModelPairs: [(String, String)] = []
    for id in roomDestinationIDs {
        let legacyRuntime: AIChatRuntime
        switch id {
        case AIChatDestinationConfiguration.localCodexID:
          legacyRuntime = .codex
        case AIChatDestinationConfiguration.localClaudeID:
          legacyRuntime = .claude
        default:
          legacyRuntime = .openClaw
        }
        if let legacyModel = roomModels.model(for: legacyRuntime) {
          migratedRoomModelPairs.append((id, legacyModel))
        }
      }
    let migratedRoomModelsByDestination = Dictionary(uniqueKeysWithValues: migratedRoomModelPairs)
    roomModelsByDestination = isSharedRoom
      ? (decodedRoomModelsByDestination ?? migratedRoomModelsByDestination)
      : [:]
    roomDefaultDestinationID = isSharedRoom
      ? try container.decodeIfPresent(String.self, forKey: .roomDefaultDestinationID)
      : nil
    roomAgentTurnLimit = isSharedRoom
      ? (try? container.decodeIfPresent(Int.self, forKey: .roomAgentTurnLimit))
        .flatMap { $0 }
        .map { min(max($0, 0), Self.maxRoomAgentTurnLimit) }
      : nil
  }

  /// The agent that receives shared-room messages without an @mention: the
  /// user's explicit choice, or else the room's original agent (the agent of
  /// the conversation it was forked from, or the first agent it addressed).
  public var roomDefaultDestination: String? {
    guard isSharedRoom else { return nil }
    if let roomDefaultDestinationID {
      return roomDefaultDestinationID == Self.noRoomDefaultDestinationID ? nil : roomDefaultDestinationID
    }
    for message in messages where !message.isRoomDispatchCopy {
      switch message.role {
      case .user:
        if let targetDestinationID = message.targetDestinationID { return targetDestinationID }
      case .assistant:
        // Replies copied from a single-agent thread belong to no room round;
        // they came from the agent the room was forked from.
        guard message.roomRoundID != nil else { return destinationID }
        return message.authorDestinationID ?? destinationID
      case .system:
        continue
      }
    }
    return nil
  }

  private static func legacyRoomDestinationIDs(
    for audience: AIChatAudience
  ) -> [String] {
    // Shared rooms written before destination IDs existed used `everyone`
    // to mean the original Codex + OpenClaw pair. Preserve that routing when
    // decoding old transcripts instead of silently adding a new participant.
    if audience == .everyone {
      return [
        AIChatDestinationConfiguration.localCodexID,
        AIChatDestinationConfiguration.openClawID,
      ]
    }
    return audience.runtimes.map(AIChatDestinationConfiguration.defaultID(for:))
  }

  public func replacingAIChatMetadata(
    agentRef nextAgentRef: String?? = nil,
    title nextTitle: String? = nil,
    runtime nextRuntime: AIChatRuntime? = nil,
    destinationID nextDestinationID: String? = nil,
    sessionKey nextSessionKey: String? = nil,
    runtimeThreadID nextRuntimeThreadID: String?? = nil,
    runtimeThreadIDsByDestination nextRuntimeThreadIDsByDestination: [String: String]? = nil,
    model nextModel: String?? = nil,
    reasoningEffort nextReasoningEffort: String?? = nil,
    isPinned nextIsPinned: Bool? = nil,
    isArchived nextIsArchived: Bool? = nil,
    settledAt nextSettledAt: Date?? = nil,
    unreadMessageCount nextUnreadMessageCount: Int? = nil,
    roomAudience nextRoomAudience: AIChatAudience? = nil,
    roomModels nextRoomModels: AIChatRoomModelSelection? = nil,
    roomDestinationIDs nextRoomDestinationIDs: [String]? = nil,
    roomModelsByDestination nextRoomModelsByDestination: [String: String]? = nil,
    roomDefaultDestinationID nextRoomDefaultDestinationID: String?? = nil,
    roomAgentTurnLimit nextRoomAgentTurnLimit: Int?? = nil
  ) -> AIChatThread {
    let archived = nextIsArchived ?? isArchived
    let settlement = nextSettledAt ?? (archived ? settledAt : nil)
    return AIChatThread(
      id: id,
      title: nextTitle ?? title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      runtime: nextRuntime ?? runtime,
      destinationID: nextDestinationID ?? destinationID,
      sessionKey: nextSessionKey ?? sessionKey,
      runtimeThreadID: nextRuntimeThreadID ?? runtimeThreadID,
      runtimeThreadIDsByDestination: nextRuntimeThreadIDsByDestination ?? runtimeThreadIDsByDestination,
      model: nextModel ?? model,
      reasoningEffort: nextReasoningEffort ?? reasoningEffort,
      messages: messages,
      storedMessageCount: storedMessageCount,
      storedHasUnresolvedLatestDelivery: storedHasUnresolvedLatestDelivery,
      storedLatestDeliveryNeedsAttention: storedLatestDeliveryNeedsAttention,
      storedLatestAssistantMessageID: storedLatestAssistantMessageID,
      isPinned: nextIsPinned ?? isPinned,
      isArchived: archived,
      settledAt: settlement,
      unreadMessageCount: nextUnreadMessageCount ?? unreadMessageCount,
      resource: resource,
      pendingTurn: pendingTurn,
      isSharedRoom: isSharedRoom,
      roomAudience: nextRoomAudience ?? roomAudience,
      roomModels: nextRoomModels ?? roomModels,
      roomDestinationIDs: nextRoomDestinationIDs ?? roomDestinationIDs,
      roomModelsByDestination: nextRoomModelsByDestination ?? roomModelsByDestination,
      roomDefaultDestinationID: nextRoomDefaultDestinationID ?? roomDefaultDestinationID,
      roomAgentTurnLimit: nextRoomAgentTurnLimit ?? roomAgentTurnLimit,
      agentRef: nextAgentRef ?? agentRef
    )
  }

  public func replacingMessages(_ nextMessages: [AIChatMessage]) -> AIChatThread {
    AIChatThread(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: nextMessages.last?.createdAt ?? updatedAt,
      runtime: runtime,
      destinationID: destinationID,
      sessionKey: sessionKey,
      runtimeThreadID: runtimeThreadID,
      runtimeThreadIDsByDestination: runtimeThreadIDsByDestination,
      model: model,
      reasoningEffort: reasoningEffort,
      messages: nextMessages,
      storedMessageCount: nil,
      storedHasUnresolvedLatestDelivery: nil,
      storedLatestDeliveryNeedsAttention: nil,
      storedLatestAssistantMessageID: nil,
      isPinned: isPinned,
      isArchived: isArchived,
      settledAt: settledAt,
      unreadMessageCount: unreadMessageCount,
      resource: resource,
      pendingTurn: pendingTurn,
      isSharedRoom: isSharedRoom,
      roomAudience: roomAudience,
      roomModels: roomModels,
      roomDestinationIDs: roomDestinationIDs,
      roomModelsByDestination: roomModelsByDestination,
      roomDefaultDestinationID: roomDefaultDestinationID,
      roomAgentTurnLimit: roomAgentTurnLimit,
      agentRef: agentRef
    )
  }

  public func replacingPendingTurn(_ nextPendingTurn: AIChatPendingTurn?) -> AIChatThread {
    AIChatThread(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      runtime: runtime,
      destinationID: destinationID,
      sessionKey: sessionKey,
      runtimeThreadID: runtimeThreadID,
      runtimeThreadIDsByDestination: runtimeThreadIDsByDestination,
      model: model,
      reasoningEffort: reasoningEffort,
      messages: messages,
      storedMessageCount: storedMessageCount,
      storedHasUnresolvedLatestDelivery: storedHasUnresolvedLatestDelivery,
      storedLatestDeliveryNeedsAttention: storedLatestDeliveryNeedsAttention,
      storedLatestAssistantMessageID: storedLatestAssistantMessageID,
      isPinned: isPinned,
      isArchived: isArchived,
      settledAt: settledAt,
      unreadMessageCount: unreadMessageCount,
      resource: resource,
      pendingTurn: nextPendingTurn,
      isSharedRoom: isSharedRoom,
      roomAudience: roomAudience,
      roomModels: roomModels,
      roomDestinationIDs: roomDestinationIDs,
      roomModelsByDestination: roomModelsByDestination,
      roomDefaultDestinationID: roomDefaultDestinationID,
      roomAgentTurnLimit: roomAgentTurnLimit,
      agentRef: agentRef
    )
  }

  public func model(for runtime: AIChatRuntime) -> String? {
    isSharedRoom ? roomModels.model(for: runtime) : (self.runtime == runtime ? model : nil)
  }

  public func model(forDestinationID destinationID: String) -> String? {
    isSharedRoom ? roomModelsByDestination[destinationID] : (self.destinationID == destinationID ? model : nil)
  }

  public func runtimeThreadID(forDestinationID destinationID: String) -> String? {
    runtimeThreadIDsByDestination[destinationID]
      ?? (self.destinationID == destinationID ? runtimeThreadID : nil)
  }

  func metadataOnly() -> AIChatThread {
    metadataOnly(latestAssistantMessageID: latestAssistantMessageID)
  }

  /// A metadata-only copy that reports `latestAssistantMessageID` as its
  /// latest reply, for placeholders whose stored metadata predates that field.
  func metadataOnly(latestAssistantMessageID storedLatestAssistantMessageID: UUID?) -> AIChatThread {
    AIChatThread(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      runtime: runtime,
      destinationID: destinationID,
      sessionKey: sessionKey,
      runtimeThreadID: runtimeThreadID,
      runtimeThreadIDsByDestination: runtimeThreadIDsByDestination,
      model: model,
      reasoningEffort: reasoningEffort,
      messages: [],
      storedMessageCount: messageCount,
      storedHasUnresolvedLatestDelivery: hasUnresolvedLatestDelivery,
      storedLatestDeliveryNeedsAttention: latestDeliveryNeedsAttention,
      storedLatestAssistantMessageID: storedLatestAssistantMessageID,
      isPinned: isPinned,
      isArchived: isArchived,
      settledAt: settledAt,
      unreadMessageCount: unreadMessageCount,
      resource: resource,
      pendingTurn: pendingTurn,
      isSharedRoom: isSharedRoom,
      roomAudience: roomAudience,
      roomModels: roomModels,
      roomDestinationIDs: roomDestinationIDs,
      roomModelsByDestination: roomModelsByDestination,
      roomDefaultDestinationID: roomDefaultDestinationID,
      roomAgentTurnLimit: roomAgentTurnLimit,
      agentRef: agentRef
    )
  }

  func hydrating(messages nextMessages: [AIChatMessage]) -> AIChatThread {
    AIChatThread(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      runtime: runtime,
      destinationID: destinationID,
      sessionKey: sessionKey,
      runtimeThreadID: runtimeThreadID,
      runtimeThreadIDsByDestination: runtimeThreadIDsByDestination,
      model: model,
      reasoningEffort: reasoningEffort,
      messages: nextMessages,
      storedMessageCount: nil,
      storedHasUnresolvedLatestDelivery: nil,
      storedLatestDeliveryNeedsAttention: nil,
      storedLatestAssistantMessageID: nil,
      isPinned: isPinned,
      isArchived: isArchived,
      settledAt: settledAt,
      unreadMessageCount: unreadMessageCount,
      resource: resource,
      pendingTurn: pendingTurn,
      isSharedRoom: isSharedRoom,
      roomAudience: roomAudience,
      roomModels: roomModels,
      roomDestinationIDs: roomDestinationIDs,
      roomModelsByDestination: roomModelsByDestination,
      roomDefaultDestinationID: roomDefaultDestinationID,
      roomAgentTurnLimit: roomAgentTurnLimit,
      agentRef: agentRef
    )
  }

  func replacingUpdatedAt(_ nextUpdatedAt: Date) -> AIChatThread {
    guard nextUpdatedAt != updatedAt else { return self }
    return AIChatThread(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: nextUpdatedAt,
      runtime: runtime,
      destinationID: destinationID,
      sessionKey: sessionKey,
      runtimeThreadID: runtimeThreadID,
      runtimeThreadIDsByDestination: runtimeThreadIDsByDestination,
      model: model,
      reasoningEffort: reasoningEffort,
      messages: messages,
      storedMessageCount: storedMessageCount,
      storedHasUnresolvedLatestDelivery: storedHasUnresolvedLatestDelivery,
      storedLatestDeliveryNeedsAttention: storedLatestDeliveryNeedsAttention,
      storedLatestAssistantMessageID: storedLatestAssistantMessageID,
      isPinned: isPinned,
      isArchived: isArchived,
      settledAt: settledAt,
      unreadMessageCount: unreadMessageCount,
      resource: resource,
      pendingTurn: pendingTurn,
      isSharedRoom: isSharedRoom,
      roomAudience: roomAudience,
      roomModels: roomModels,
      roomDestinationIDs: roomDestinationIDs,
      roomModelsByDestination: roomModelsByDestination,
      roomDefaultDestinationID: roomDefaultDestinationID,
      roomAgentTurnLimit: roomAgentTurnLimit,
      agentRef: agentRef
    )
  }
}

public struct AIChatCorpusChangeSummary: Hashable, Codable, Sendable {
  public let files: [AIChatCorpusFileChange]

  public init(files: [AIChatCorpusFileChange]) {
    self.files = files
  }

  public var changedFileCount: Int {
    files.count
  }

  public var totalInsertions: Int {
    files.reduce(0) { $0 + $1.insertions }
  }

  public var totalDeletions: Int {
    files.reduce(0) { $0 + $1.deletions }
  }

  public var title: String {
    let noun = changedFileCount == 1 ? "file" : "files"
    if files.allSatisfy({ $0.status == .created }) {
      return "Created \(changedFileCount) \(noun)"
    }
    if files.allSatisfy({ $0.status == .deleted }) {
      return "Deleted \(changedFileCount) \(noun)"
    }
    return "Edited \(changedFileCount) \(noun)"
  }
}

public struct AIChatCorpusFileChange: Identifiable, Hashable, Codable, Sendable {
  public enum Status: String, Hashable, Codable, Sendable {
    case created
    case modified
    case deleted
  }

  public let relativePath: String
  public let status: Status
  public let insertions: Int
  public let deletions: Int

  public init(relativePath: String, status: Status, insertions: Int, deletions: Int) {
    self.relativePath = relativePath
    self.status = status
    self.insertions = insertions
    self.deletions = deletions
  }

  public var id: String {
    relativePath
  }
}

public struct OpenClawChatCompletionPayload: Decodable, Sendable {
  public let choices: [Choice]
  public let usage: Usage?

  public struct Choice: Decodable, Sendable {
    public let message: Message?
  }

  public struct Message: Decodable, Sendable {
    public let role: String?
    public let content: String?
  }

  public struct Usage: Decodable, Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let promptTokensDetails: PromptTokensDetails?

    enum CodingKeys: String, CodingKey {
      case promptTokens = "prompt_tokens"
      case completionTokens = "completion_tokens"
      case totalTokens = "total_tokens"
      case promptTokensDetails = "prompt_tokens_details"
    }
  }

  public struct PromptTokensDetails: Decodable, Sendable {
    public let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
      case cachedTokens = "cached_tokens"
    }
  }

  public var assistantText: String {
    choices
      .compactMap { $0.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }
}

public struct AIChatFileReference: Identifiable, Hashable, Sendable {
  public static let deepLinkScheme = "org2-workspace"

  public let path: String
  public let line: Int?

  public init(path: String, line: Int?) {
    let parsed = Self.cleanPathAndLine(path)
    self.path = parsed.path
    self.line = line ?? parsed.line
  }

  public var id: String {
    "\(path):\(line ?? 0)"
  }

  public var displayTitle: String {
    let title = URL(fileURLWithPath: path).lastPathComponent
    guard let line else { return title }
    return "\(title):\(line)"
  }

  public static func extract(from text: String, limit: Int = 8) -> [AIChatFileReference] {
    let pattern = #"(?<![A-Za-z0-9_./~-])((?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md|csv|pdf))(?:(?::|#)[Ll]?(\d+)(?:-[Ll]?\d+)?)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    var references: [AIChatFileReference] = []
    var seen = Set<String>()

    for match in matches {
      guard references.count < limit, match.numberOfRanges >= 2 else { break }
      let rawPath = nsText.substring(with: match.range(at: 1))
      let line: Int?
      if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
        line = Int(nsText.substring(with: match.range(at: 2)))
      } else {
        line = nil
      }

      let reference = AIChatFileReference(path: rawPath, line: line)
      guard !reference.path.isEmpty, seen.insert(reference.id).inserted else { continue }
      references.append(reference)
    }

    return references
  }

  public static func fromLinkTarget(_ raw: String) -> AIChatFileReference? {
    let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    let lowercased = target.lowercased()
    let isFileTarget = lowercased.hasPrefix("file:")
      || lowercased.range(
        of: #"\.(?:org2?|md|csv|pdf)(?:(?::|#)l?\d+(?:-l?\d+)?)?$"#,
        options: .regularExpression
      ) != nil
    guard isFileTarget else { return nil }

    return AIChatFileReference(path: target, line: nil)
  }

  public var deepLinkURL: URL? {
    var components = URLComponents()
    components.scheme = Self.deepLinkScheme
    components.host = "open-file"
    components.queryItems = [
      URLQueryItem(name: "path", value: path)
    ]
    if let line {
      components.queryItems?.append(URLQueryItem(name: "line", value: "\(line)"))
    }
    return components.url
  }

  public static func fromDeepLinkURL(_ url: URL) -> AIChatFileReference? {
    guard url.scheme == deepLinkScheme, url.host == "open-file" else { return nil }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let path = components?.queryItems?.first(where: { $0.name == "path" })?.value
    let line = components?.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
    guard let path, !path.isEmpty else { return nil }
    return AIChatFileReference(path: path, line: line)
  }

  private static func cleanPathAndLine(_ raw: String) -> (path: String, line: Int?) {
    var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.hasPrefix("file://") {
      path = String(path.dropFirst("file://".count)).removingPercentEncoding ?? String(path.dropFirst("file://".count))
    } else if path.hasPrefix("file:") {
      path = String(path.dropFirst("file:".count)).removingPercentEncoding ?? String(path.dropFirst("file:".count))
    }
    while let last = path.last, [".", ",", ";", ":"].contains(String(last)) {
      path.removeLast()
    }

    let nsPath = path as NSString
    let fullRange = NSRange(location: 0, length: nsPath.length)
    if let regex = try? NSRegularExpression(
      pattern: #"^(.*\.(?:org2?|md|csv|pdf))(?::|#)[Ll]?(\d+)(?:-[Ll]?\d+)?$"#,
      options: .caseInsensitive
    ),
       let match = regex.firstMatch(in: path, range: fullRange),
       match.numberOfRanges == 3 {
      let cleanPath = nsPath.substring(with: match.range(at: 1))
      let line = Int(nsPath.substring(with: match.range(at: 2)))
      return (cleanPath, line)
    }

    return (path, nil)
  }
}

public struct OrgRoamNodeReference: Identifiable, Hashable, Sendable {
  public let idValue: String?
  public let title: String
  public let aliases: [String]
  public let file: String
  public let line: Int
  public let isPageNode: Bool

  public init(idValue: String?, title: String, aliases: [String] = [], file: String, line: Int, isPageNode: Bool = false) {
    let trimmedID = idValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.idValue = trimmedID.isEmpty ? nil : trimmedID
    self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    self.aliases = aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    self.file = file
    self.line = max(1, line)
    self.isPageNode = isPageNode
  }

  public var id: String {
    "\(file):\(line):\(idValue ?? title)"
  }

  public var fileReference: AIChatFileReference {
    AIChatFileReference(path: file, line: line)
  }

  public var preferredLinkTarget: String {
    if let idValue {
      return "id:\(idValue)"
    }
    return file
  }
}

public struct OrgRoamResolvedLink: Equatable, Sendable {
  public let title: String
  public let fileReference: AIChatFileReference

  public init(title: String, fileReference: AIChatFileReference) {
    self.title = title
    self.fileReference = fileReference
  }
}

public struct OrgLinkAbbreviations: Equatable, Sendable {
  public static let empty = OrgLinkAbbreviations()

  public let templates: [String: String]

  public init(linearTeam: String? = nil, configured: [String: String] = [:]) {
    var templates = [
      "gh": "https://github.com/%s",
      "gl": "https://gitlab.com/%s",
      "yt": "https://www.youtube.com/watch?v=%s",
      "wiki": "https://en.wikipedia.org/wiki/%s",
    ]
    if let team = linearTeam?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty {
      templates["linear"] = "https://linear.app/\(team)/issue/%s"
    }
    for (rawPrefix, rawTemplate) in configured {
      let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let template = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.isValidPrefix(prefix), !template.isEmpty else { continue }
      templates[prefix] = template
    }
    self.templates = templates
  }

  public func expand(_ rawTarget: String) -> String {
    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let colon = target.firstIndex(of: ":") else { return target }
    let prefix = String(target[..<colon]).lowercased()
    guard !Self.reservedPrefixes.contains(prefix),
          let template = templates[prefix]
    else {
      return target
    }
    let suffix = String(target[target.index(after: colon)...])
    if template.contains("%s") {
      return template.replacingOccurrences(of: "%s", with: suffix)
    }
    return template + suffix
  }

  private static func isValidPrefix(_ prefix: String) -> Bool {
    prefix.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil
  }

  private static let reservedPrefixes = Set(["http", "https", "mailto", "file", "id"])
}

public struct OrgRoamLinkResolver: Equatable, Sendable {
  public static let empty = OrgRoamLinkResolver(nodes: [])

  public let nodes: [OrgRoamNodeReference]
  public let linkAbbreviations: OrgLinkAbbreviations
  public let signature: String
  private let nodesByID: [String: OrgRoamNodeReference]
  private let nodesByTitle: [String: OrgRoamNodeReference]
  private let nodeCandidatesByTitle: [String: [OrgRoamNodeReference]]
  private let pageNodesByFile: [String: OrgRoamNodeReference]

  public init(nodes: [OrgRoamNodeReference], linkAbbreviations: OrgLinkAbbreviations = .empty) {
    self.nodes = nodes
    self.linkAbbreviations = linkAbbreviations

    var idCandidates: [String: [OrgRoamNodeReference]] = [:]
    var titleCandidates: [String: [OrgRoamNodeReference]] = [:]
    var pageNodes: [String: OrgRoamNodeReference] = [:]
    for node in nodes {
      if node.isPageNode, pageNodes[node.file] == nil {
        pageNodes[node.file] = node
      }
      if let idValue = node.idValue {
        idCandidates[Self.normalizedID(idValue), default: []].append(node)
      }

      for title in [node.title] + node.aliases {
        let key = Self.normalizedTitle(title)
        guard !key.isEmpty else { continue }
        if titleCandidates[key]?.contains(node) != true {
          titleCandidates[key, default: []].append(node)
        }
      }
    }

    nodesByID = idCandidates.compactMapValues { candidates in
      candidates.count == 1 ? candidates[0] : nil
    }
    nodesByTitle = titleCandidates.compactMapValues { candidates in
      candidates.count == 1 ? candidates[0] : nil
    }
    nodeCandidatesByTitle = titleCandidates.mapValues(Self.rankedCandidates)
    pageNodesByFile = pageNodes
    signature = Self.makeSignature(nodes, linkAbbreviations: linkAbbreviations)
  }

  public static func == (lhs: OrgRoamLinkResolver, rhs: OrgRoamLinkResolver) -> Bool {
    // SwiftUI compares environment values frequently; walking the derived indexes
    // here can otherwise stall the main thread for large corpora.
    lhs.signature == rhs.signature
  }

  public func resolve(target rawTarget: String) -> OrgRoamResolvedLink? {
    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }

    let lowercased = target.lowercased()
    let node: OrgRoamNodeReference?
    if lowercased.hasPrefix("id:") {
      node = nodesByID[Self.normalizedID(String(target.dropFirst(3)))]
    } else {
      node = nodesByTitle[Self.normalizedTitle(target)]
    }

    guard let node else { return nil }
    return OrgRoamResolvedLink(title: node.title, fileReference: node.fileReference)
  }

  /// The file-level node for the absolute `path`, if the file has one.
  public func pageNode(forFile path: String) -> OrgRoamNodeReference? {
    pageNodesByFile[path]
  }

  /// An `id:` target for `node` when its ID identifies only that node.
  public func uniqueIDLinkTarget(for node: OrgRoamNodeReference) -> String? {
    guard let idValue = node.idValue,
          nodesByID[Self.normalizedID(idValue)] == node
    else { return nil }
    return "id:\(idValue)"
  }

  public func expandedLinkTarget(_ rawTarget: String) -> String {
    linkAbbreviations.expand(rawTarget)
  }

  public func exactCandidates(for rawTarget: String) -> [OrgRoamNodeReference] {
    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return [] }
    if target.lowercased().hasPrefix("id:") {
      return nodesByID[Self.normalizedID(String(target.dropFirst(3)))].map { [$0] } ?? []
    }
    return nodeCandidatesByTitle[Self.normalizedTitle(target)] ?? []
  }

  public func searchCandidates(matching rawQuery: String, limit: Int = 6) -> [OrgRoamNodeReference] {
    let query = Self.normalizedTitle(rawQuery)
    guard !query.isEmpty else { return [] }
    let scored = nodes.compactMap { node -> (OrgRoamNodeReference, Int)? in
      let labels = [node.title] + node.aliases
      var bestScore: Int?
      for label in labels {
        let normalized = Self.normalizedTitle(label)
        if normalized == query {
          bestScore = min(bestScore ?? 0, 0)
        } else if normalized.hasPrefix(query) {
          bestScore = min(bestScore ?? 1, 1)
        } else if normalized.contains(query) {
          bestScore = min(bestScore ?? 2, 2)
        }
      }
      return bestScore.map { (node, $0) }
    }
    return scored
      .sorted {
        if $0.1 != $1.1 { return $0.1 < $1.1 }
        return Self.compareRankedCandidates($0.0, $1.0)
      }
      .map(\.0)
      .prefix(limit)
      .map { $0 }
  }

  public static func normalizedTitle(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
  }

  private static func normalizedID(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func makeSignature(
    _ nodes: [OrgRoamNodeReference],
    linkAbbreviations: OrgLinkAbbreviations
  ) -> String {
    var hasher = Hasher()
    hasher.combine(nodes.count)
    for node in nodes.sorted(by: { $0.id < $1.id }) {
      hasher.combine(node.idValue)
      hasher.combine(node.title)
      hasher.combine(node.aliases)
      hasher.combine(node.file)
      hasher.combine(node.line)
      hasher.combine(node.isPageNode)
    }
    for (prefix, template) in linkAbbreviations.templates.sorted(by: { $0.key < $1.key }) {
      hasher.combine(prefix)
      hasher.combine(template)
    }
    return "\(nodes.count):\(linkAbbreviations.templates.count):\(hasher.finalize())"
  }

  private static func rankedCandidates(_ candidates: [OrgRoamNodeReference]) -> [OrgRoamNodeReference] {
    candidates.sorted(by: compareRankedCandidates)
  }

  private static func compareRankedCandidates(_ lhs: OrgRoamNodeReference, _ rhs: OrgRoamNodeReference) -> Bool {
    if lhs.isPageNode != rhs.isPageNode {
      return lhs.isPageNode
    }
    let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    if titleOrder != .orderedSame {
      return titleOrder == .orderedAscending
    }
    let pathOrder = lhs.file.localizedStandardCompare(rhs.file)
    if pathOrder != .orderedSame {
      return pathOrder == .orderedAscending
    }
    return lhs.line < rhs.line
  }
}

public enum OrgInlineSpan: Equatable, Sendable {
  case text(String)
  case code(String)
  case bold(String)
  case italic(String)
  case underline(String)
  case strike(String)
  case color(OrgColorBinding)
  case timestamp(OrgInlineTimestamp)
  case link(label: String, target: String, fileReference: AIChatFileReference?)
}

public struct OrgColorValue: Equatable, Sendable {
  public let source: String
  public let rgb: UInt32

  public static func parse(_ raw: String) -> OrgColorValue? {
    let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else { return nil }
    if let rgb = namedColors[source.lowercased()] {
      return OrgColorValue(source: source, rgb: rgb)
    }

    guard source.first == "#" else { return nil }
    let digits = String(source.dropFirst())
    if digits.count == 3, let compact = UInt32(digits, radix: 16) {
      let red = (compact >> 8) & 0xf
      let green = (compact >> 4) & 0xf
      let blue = compact & 0xf
      return OrgColorValue(source: source, rgb: (red * 17 << 16) | (green * 17 << 8) | (blue * 17))
    }
    guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else { return nil }
    return OrgColorValue(source: source, rgb: rgb)
  }

  private static let namedColors: [String: UInt32] = [
    "black": 0x1c1c1e, "blue": 0x007aff, "brown": 0xa2845e,
    "gray": 0x8e8e93, "green": 0x34c759, "grey": 0x8e8e93,
    "indigo": 0x5856d6, "mint": 0x00c7be, "orange": 0xff9500,
    "pink": 0xff2d55, "purple": 0xaf52de, "red": 0xff3b30,
    "teal": 0x30b0c7, "white": 0xf2f2f7, "yellow": 0xffcc00,
  ]
}

public struct OrgColorBinding: Equatable, Sendable {
  public let label: String
  public let foreground: OrgColorValue?
  public let background: OrgColorValue?

  public static func parse(target rawTarget: String, label rawLabel: String) -> OrgColorBinding? {
    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard target.lowercased().hasPrefix("color:") else { return nil }
    let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return nil }
    guard let colon = target.firstIndex(of: ":") else { return nil }
    let body = String(target[target.index(after: colon)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }

    let declarations = body.split(separator: ";", omittingEmptySubsequences: true)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    var foreground: OrgColorValue?
    var background: OrgColorValue?
    for declaration in declarations {
      guard let equals = declaration.firstIndex(of: "=") else {
        guard declarations.count == 1, foreground == nil,
              let color = OrgColorValue.parse(declaration)
        else { return nil }
        foreground = color
        continue
      }
      let key = String(declaration[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let valueStart = declaration.index(after: equals)
      guard let color = OrgColorValue.parse(String(declaration[valueStart...])) else { return nil }
      switch key {
      case "fg", "foreground", "text":
        guard foreground == nil else { return nil }
        foreground = color
      case "bg", "background":
        guard background == nil else { return nil }
        background = color
      default:
        return nil
      }
    }
    guard foreground != nil || background != nil else { return nil }
    return OrgColorBinding(label: label, foreground: foreground, background: background)
  }
}

public struct OrgInlineTimestamp: Equatable, Sendable {
  public let raw: String
  public let dateLabel: String
  public let timeLabel: String?
  public let detail: String?

  public init(raw: String, dateLabel: String, timeLabel: String? = nil, detail: String? = nil) {
    self.raw = raw
    self.dateLabel = dateLabel
    self.timeLabel = timeLabel
    self.detail = detail
  }
}

public struct OrgEditableInlineMarkupSet: Equatable, Sendable {
  public let rawText: String
  public let markups: [OrgEditableInlineMarkup]

  public init(rawText: String) {
    self.rawText = rawText
    self.markups = Self.parseMarkups(rawText)
  }

  public func replacing(
    markup: OrgEditableInlineMarkup,
    text: String? = nil,
    kind: OrgEditableInlineMarkup.Kind? = nil
  ) -> String {
    let nextKind = kind ?? markup.kind
    let normalizedText = text ?? markup.text
    guard !normalizedText.isEmpty else { return rawText }

    let marker = nextKind == markup.kind ? markup.marker : nextKind.defaultMarker
    return (rawText as NSString).replacingCharacters(
      in: NSRange(location: markup.startUTF16, length: markup.endUTF16 - markup.startUTF16),
      with: "\(marker)\(normalizedText)\(marker)"
    )
  }

  public static func wrappingSelection(
    in rawText: String,
    range: NSRange,
    kind: OrgEditableInlineMarkup.Kind
  ) -> OrgInlineSelectionEdit {
    let ns = rawText as NSString
    let location = min(max(0, range.location), ns.length)
    let length = min(max(0, range.length), ns.length - location)
    let safeRange = NSRange(location: location, length: length)
    let selectedText = ns.substring(with: safeRange)
    let replacementText = selectedText.isEmpty ? kind.placeholderText : selectedText
    let marker = kind.defaultMarker
    let wrappedText = "\(marker)\(replacementText)\(marker)"
    let updatedText = ns.replacingCharacters(in: safeRange, with: wrappedText)
    return OrgInlineSelectionEdit(
      text: updatedText,
      selectedRange: NSRange(
        location: location + (marker as NSString).length,
        length: (replacementText as NSString).length
      )
    )
  }

  private static func parseMarkups(_ raw: String) -> [OrgEditableInlineMarkup] {
    let ignoredRanges = ignoredInlineRanges(raw)
    var markups: [OrgEditableInlineMarkup] = []
    var cursor = raw.startIndex

    while cursor < raw.endIndex {
      var didParse = false
      for spec in delimiterSpecs where raw[cursor] == spec.marker {
        guard let parsed = parseDelimited(raw, at: cursor, marker: spec.marker),
              !spec.requiresOrgBoundary || markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close)
        else {
          continue
        }

        let rawRange = NSRange(
          location: cursor.utf16Offset(in: raw),
          length: parsed.end.utf16Offset(in: raw) - cursor.utf16Offset(in: raw)
        )
        guard !ignoredRanges.contains(where: { rangesOverlap(rawRange, $0) }) else {
          continue
        }

        markups.append(OrgEditableInlineMarkup(
          id: "markup:\(rawRange.location)",
          kind: spec.kind,
          marker: String(spec.marker),
          text: parsed.text,
          startUTF16: rawRange.location,
          endUTF16: rawRange.location + rawRange.length
        ))
        cursor = parsed.end
        didParse = true
        break
      }

      if !didParse {
        cursor = raw.index(after: cursor)
      }
    }

    return markups
  }

  private static func ignoredInlineRanges(_ raw: String) -> [NSRange] {
    let linkRanges = OrgEditableInlineLinkSet(rawText: raw).links.map(\.rawRange)
    let timestampRanges = OrgEditableInlineTimestampSet(rawText: raw).timestamps.map {
      NSRange(location: $0.startUTF16, length: $0.endUTF16 - $0.startUTF16)
    }
    return linkRanges + timestampRanges
  }

  private static func parseDelimited(
    _ raw: String,
    at cursor: String.Index,
    marker: Character
  ) -> (text: String, close: String.Index, end: String.Index)? {
    guard raw[cursor] == marker else { return nil }
    let contentStart = raw.index(after: cursor)
    guard contentStart < raw.endIndex, !raw[contentStart].isWhitespace else { return nil }

    var search = contentStart
    while search < raw.endIndex {
      guard let close = raw[search...].firstIndex(of: marker) else { return nil }
      let beforeClose = raw.index(before: close)
      let afterClose = raw.index(after: close)
      if !raw[beforeClose].isWhitespace {
        let text = String(raw[contentStart..<close])
        guard !text.isEmpty else { return nil }
        return (text, close, afterClose)
      }
      search = raw.index(after: close)
    }

    return nil
  }

  private static func markerLooksLikeOrgBoundary(_ raw: String, open: String.Index, close: String.Index) -> Bool {
    let beforeOpen = open > raw.startIndex ? raw.index(before: open) : nil
    let afterClose = raw.index(after: close)
    let opensAtBoundary = beforeOpen.map { isBoundary(raw[$0]) } ?? true
    let closesAtBoundary = afterClose < raw.endIndex ? isBoundary(raw[afterClose]) : true
    return opensAtBoundary && closesAtBoundary
  }

  private static func isBoundary(_ character: Character) -> Bool {
    if character.isWhitespace { return true }
    return !character.isASCIIWord
  }

  private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
  }

  private static let delimiterSpecs: [(marker: Character, kind: OrgEditableInlineMarkup.Kind, requiresOrgBoundary: Bool)] = [
    ("`", .code, false),
    ("~", .code, true),
    ("=", .code, true),
    ("*", .bold, true),
    ("/", .italic, true),
    ("_", .underline, true),
    ("+", .strike, true)
  ]
}

public struct OrgEditableInlineMarkup: Identifiable, Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case code
    case bold
    case italic
    case underline
    case strike

    var defaultMarker: String {
      switch self {
      case .code:
        return "`"
      case .bold:
        return "*"
      case .italic:
        return "/"
      case .underline:
        return "_"
      case .strike:
        return "+"
      }
    }

    var displayTitle: String {
      switch self {
      case .code:
        return "Code"
      case .bold:
        return "Bold"
      case .italic:
        return "Italic"
      case .underline:
        return "Underline"
      case .strike:
        return "Strike"
      }
    }

    var placeholderText: String {
      switch self {
      case .code:
        return "code"
      case .bold, .italic, .underline, .strike:
        return "text"
      }
    }
  }

  public let id: String
  public let kind: Kind
  public let marker: String
  public let text: String
  public let startUTF16: Int
  public let endUTF16: Int
}

public struct OrgInlineSelectionEdit: Equatable, Sendable {
  public let text: String
  public let selectedRange: NSRange
}

public enum OrgEditableInlineToken: Equatable, Sendable {
  public static let focusedScanUTF16Limit = 12_000
  public static let focusedFullParseUTF16Limit = 2_000
  public static let focusedLocalScanUTF16Radius = 1_024

  case link(OrgEditableInlineLink)
  case timestamp(OrgEditableInlineTimestamp)
  case markup(OrgEditableInlineMarkup)

  public var id: String {
    switch self {
    case .link(let link):
      return link.id
    case .timestamp(let timestamp):
      return timestamp.id
    case .markup(let markup):
      return markup.id
    }
  }

  public var range: NSRange {
    switch self {
    case .link(let link):
      return NSRange(location: link.startUTF16, length: link.endUTF16 - link.startUTF16)
    case .timestamp(let timestamp):
      return NSRange(location: timestamp.startUTF16, length: timestamp.endUTF16 - timestamp.startUTF16)
    case .markup(let markup):
      return NSRange(location: markup.startUTF16, length: markup.endUTF16 - markup.startUTF16)
    }
  }

  public static func focused(
    in rawText: String,
    selection: NSRange,
    maxUTF16Length: Int = focusedScanUTF16Limit
  ) -> OrgEditableInlineToken? {
    guard let textLength = boundedUTF16Length(in: rawText, maxUTF16Length: maxUTF16Length) else {
      return nil
    }

    let safeLocation = min(max(0, selection.location), textLength)
    let safeSelection = NSRange(
      location: safeLocation,
      length: min(max(0, selection.length), max(0, textLength - safeLocation))
    )
    guard hasFocusedInlineSyntaxCandidate(in: rawText, selection: safeSelection) else {
      return nil
    }

    if textLength > focusedFullParseUTF16Limit {
      return focusedInLocalWindow(rawText, selection: safeSelection, textLength: textLength)
    }

    let tokens = all(in: rawText)
    guard !tokens.isEmpty else { return nil }

    if safeSelection.length > 0 {
      return tokens.first { rangesOverlap($0.range, safeSelection) }
    }

    return tokens.first { token in
      let range = token.range
      return safeSelection.location >= range.location && safeSelection.location <= range.location + range.length
    }
  }

  public static func shouldScanFocusedToken(
    utf16Length: Int,
    maxUTF16Length: Int = focusedScanUTF16Limit
  ) -> Bool {
    maxUTF16Length >= 0 && utf16Length <= maxUTF16Length
  }

  public static func hasFocusedInlineSyntaxCandidate(in rawText: String, selection: NSRange) -> Bool {
    OrgInlineParser.hasInlineSyntaxCandidate(
      rawText,
      near: selection,
      radius: focusedLocalScanUTF16Radius
    )
  }

  public static func boundedUTF16Length(
    in text: String,
    maxUTF16Length: Int = focusedScanUTF16Limit
  ) -> Int? {
    guard maxUTF16Length >= 0 else { return nil }
    var count = 0
    for _ in text.utf16 {
      count += 1
      if count > maxUTF16Length {
        return nil
      }
    }
    return count
  }

  private static func focusedInLocalWindow(
    _ rawText: String,
    selection safeSelection: NSRange,
    textLength: Int
  ) -> OrgEditableInlineToken? {
    let localEnd = min(
      textLength,
      safeSelection.location + max(0, safeSelection.length) + focusedLocalScanUTF16Radius
    )
    guard let window = substringWindow(
      in: rawText,
      startUTF16: max(0, safeSelection.location - focusedLocalScanUTF16Radius),
      endUTF16: localEnd
    ) else {
      return nil
    }

    let localTokens = all(in: window.text).map { $0.shiftingUTF16Ranges(by: window.startUTF16) }
    guard !localTokens.isEmpty else { return nil }
    if safeSelection.length > 0 {
      return localTokens.first { rangesOverlap($0.range, safeSelection) }
    }
    return localTokens.first { token in
      let range = token.range
      return safeSelection.location >= range.location && safeSelection.location <= range.location + range.length
    }
  }

  private static func substringWindow(
    in text: String,
    startUTF16 requestedStart: Int,
    endUTF16 requestedEnd: Int
  ) -> (text: String, startUTF16: Int)? {
    let ns = text as NSString
    var start = min(max(0, requestedStart), ns.length)
    var end = min(max(start, requestedEnd), ns.length)

    while start >= 0 {
      while end <= ns.length {
        let range = NSRange(location: start, length: end - start)
        if let swiftRange = Range(range, in: text) {
          return (String(text[swiftRange]), start)
        }
        end += 1
      }
      start -= 1
      end = min(max(start, requestedEnd), ns.length)
    }
    return nil
  }

  private static func all(in rawText: String) -> [OrgEditableInlineToken] {
    let links = OrgEditableInlineLinkSet(rawText: rawText).links.map(OrgEditableInlineToken.link)
    let timestamps = OrgEditableInlineTimestampSet(rawText: rawText).timestamps.map(OrgEditableInlineToken.timestamp)
    let markups = OrgEditableInlineMarkupSet(rawText: rawText).markups.map(OrgEditableInlineToken.markup)
    return (links + timestamps + markups).sorted {
      if $0.range.location != $1.range.location {
        return $0.range.location < $1.range.location
      }
      return $0.range.length > $1.range.length
    }
  }

  private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
  }

  private func shiftingUTF16Ranges(by offset: Int) -> OrgEditableInlineToken {
    switch self {
    case .link(let link):
      return .link(OrgEditableInlineLink(
        id: "link:\(link.startUTF16 + offset)",
        kind: link.kind,
        label: link.label,
        target: link.target,
        startUTF16: link.startUTF16 + offset,
        endUTF16: link.endUTF16 + offset
      ))
    case .timestamp(let timestamp):
      return .timestamp(OrgEditableInlineTimestamp(
        id: "timestamp:\(timestamp.startUTF16 + offset)",
        date: timestamp.date,
        time: timestamp.time,
        detail: timestamp.detail,
        isActive: timestamp.isActive,
        startUTF16: timestamp.startUTF16 + offset,
        endUTF16: timestamp.endUTF16 + offset
      ))
    case .markup(let markup):
      return .markup(OrgEditableInlineMarkup(
        id: "markup:\(markup.startUTF16 + offset)",
        kind: markup.kind,
        marker: markup.marker,
        text: markup.text,
        startUTF16: markup.startUTF16 + offset,
        endUTF16: markup.endUTF16 + offset
      ))
    }
  }
}

public struct OrgEditableInlineLinkSet: Equatable, Sendable {
  public let rawText: String
  public let links: [OrgEditableInlineLink]

  public init(rawText: String) {
    self.rawText = rawText
    self.links = Self.parseLinks(rawText)
  }

  public func replacing(
    link: OrgEditableInlineLink,
    label: String? = nil,
    target: String? = nil
  ) -> String {
    let normalizedLabel = (label ?? link.label).trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTarget = (target ?? link.target).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTarget.isEmpty else { return rawText }

    let replacement = Self.formattedBracketLink(target: normalizedTarget, label: normalizedLabel)
    return (rawText as NSString).replacingCharacters(
      in: NSRange(location: link.startUTF16, length: link.endUTF16 - link.startUTF16),
      with: replacement
    )
  }

  private static func formattedBracketLink(target: String, label: String) -> String {
    guard !label.isEmpty, label != target else {
      return "[[\(target)]]"
    }
    return "[[\(target)][\(label)]]"
  }

  private static func parseLinks(_ raw: String) -> [OrgEditableInlineLink] {
    var links: [OrgEditableInlineLink] = []
    appendRegexLinks(
      pattern: #"\[\[([^\]\n]+)(?:\]\[([^\]\n]*))?\]\]"#,
      raw: raw,
      targetCapture: 1,
      labelCapture: 2,
      kind: .orgBracket,
      into: &links
    )
    appendRegexLinks(
      pattern: #"(?<!\[)\[([^\]\n]+)\]\(([^\)\n]+)\)"#,
      raw: raw,
      targetCapture: 2,
      labelCapture: 1,
      kind: .markdown,
      into: &links
    )
    appendRegexLinks(
      pattern: #"https?://[^\s\]\)"'`<>]+"#,
      raw: raw,
      targetCapture: 0,
      labelCapture: nil,
      kind: .plainURL,
      into: &links
    )
    appendRegexLinks(
      pattern: #"(?:(?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:[:#]\d+)?"#,
      raw: raw,
      targetCapture: 0,
      labelCapture: nil,
      kind: .fileReference,
      into: &links
    )

    return links.sorted {
      if $0.startUTF16 != $1.startUTF16 {
        return $0.startUTF16 < $1.startUTF16
      }
      return $0.endUTF16 < $1.endUTF16
    }
  }

  private static func appendRegexLinks(
    pattern: String,
    raw: String,
    targetCapture: Int,
    labelCapture: Int?,
    kind: OrgEditableInlineLink.Kind,
    into links: inout [OrgEditableInlineLink]
  ) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    let ns = raw as NSString
    let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
    for match in matches {
      let rawRange = match.range(at: 0)
      guard rawRange.location != NSNotFound,
            rawRange.length > 0,
            !links.contains(where: { rangesOverlap(rawRange, $0.rawRange) }),
            match.numberOfRanges > targetCapture,
            match.range(at: targetCapture).location != NSNotFound
      else {
        continue
      }

      var linkRange = rawRange
      var target = ns.substring(with: match.range(at: targetCapture))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      while let last = target.last, [".", ",", ";", ":"].contains(String(last)) {
        target.removeLast()
        if targetCapture == 0 {
          linkRange.length -= 1
        }
      }
      guard !target.isEmpty else { continue }

      let label: String
      if let labelCapture,
         match.numberOfRanges > labelCapture,
         match.range(at: labelCapture).location != NSNotFound {
        label = ns.substring(with: match.range(at: labelCapture))
          .trimmingCharacters(in: .whitespacesAndNewlines)
      } else if kind == .fileReference,
                let reference = AIChatFileReference.fromLinkTarget(target) {
        label = reference.displayTitle
      } else {
        label = target
      }

      links.append(OrgEditableInlineLink(
        id: "link:\(rawRange.location)",
        kind: kind,
        label: label.isEmpty ? target : label,
        target: target,
        startUTF16: linkRange.location,
        endUTF16: linkRange.location + linkRange.length
      ))
    }
  }

  private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    lhs.location < rhs.location + rhs.length && rhs.location < lhs.location + lhs.length
  }
}

public struct OrgEditableInlineLink: Identifiable, Equatable, Sendable {
  public enum Kind: String, Sendable {
    case orgBracket
    case markdown
    case plainURL
    case fileReference
  }

  public let id: String
  public let kind: Kind
  public let label: String
  public let target: String
  public let startUTF16: Int
  public let endUTF16: Int

  fileprivate var rawRange: NSRange {
    NSRange(location: startUTF16, length: endUTF16 - startUTF16)
  }
}

public struct OrgEditableInlineTimestampSet: Equatable, Sendable {
  public let rawText: String
  public let timestamps: [OrgEditableInlineTimestamp]

  public init(rawText: String) {
    self.rawText = rawText
    self.timestamps = Self.parseTimestamps(rawText)
  }

  public func replacing(
    timestamp: OrgEditableInlineTimestamp,
    date: String? = nil,
    time: String? = nil,
    detail: String? = nil,
    isActive: Bool? = nil
  ) -> String {
    let replacement = Self.formattedTimestamp(
      date: date ?? timestamp.date,
      time: time ?? timestamp.time,
      detail: detail ?? timestamp.detail,
      isActive: isActive ?? timestamp.isActive
    )
    return (rawText as NSString).replacingCharacters(
      in: NSRange(location: timestamp.startUTF16, length: timestamp.endUTF16 - timestamp.startUTF16),
      with: replacement
    )
  }

  private static func parseTimestamps(_ raw: String) -> [OrgEditableInlineTimestamp] {
    let pattern = #"([<\[])(\d{4}(?:-\d{0,2}(?:-\d{0,2})?)?)(?:\s+[A-Za-z]{3})?(?:\s+(\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?))?([^>\]]*)([>\]])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = raw as NSString
    let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
    return matches.compactMap { match in
      guard match.numberOfRanges == 6,
            match.range(at: 1).location != NSNotFound,
            match.range(at: 2).location != NSNotFound,
            match.range(at: 5).location != NSNotFound
      else {
        return nil
      }

      let open = ns.substring(with: match.range(at: 1))
      let close = ns.substring(with: match.range(at: 5))
      guard (open == "<" && close == ">") || (open == "[" && close == "]") else {
        return nil
      }

      let rawRange = match.range(at: 0)
      let time = match.range(at: 3).location == NSNotFound
        ? ""
        : ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = match.range(at: 4).location == NSNotFound
        ? ""
        : ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespacesAndNewlines)

      return OrgEditableInlineTimestamp(
        id: "timestamp:\(rawRange.location)",
        date: ns.substring(with: match.range(at: 2)),
        time: time,
        detail: detail,
        isActive: open == "<",
        startUTF16: rawRange.location,
        endUTF16: rawRange.location + rawRange.length
      )
    }
  }

  private static func formattedTimestamp(date: String, time: String, detail: String, isActive: Bool) -> String {
    let normalizedDate = date.trimmingCharacters(in: .whitespacesAndNewlines)
    let timestampDate = normalizedDate.isEmpty ? "1970-01-01" : normalizedDate
    var parts = [timestampDate]
    if let weekday = weekdayLabel(for: timestampDate) {
      parts.append(weekday)
    }

    let normalizedTime = time.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedTime.isEmpty {
      parts.append(normalizedTime)
    }

    let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedDetail.isEmpty {
      parts.append(normalizedDetail)
    }

    let body = parts.joined(separator: " ")
    return isActive ? "<\(body)>" : "[\(body)]"
  }

  private static func weekdayLabel(for date: String) -> String? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let parsed = formatter.date(from: date) else { return nil }
    formatter.dateFormat = "EEE"
    return formatter.string(from: parsed)
  }
}

public struct OrgEditableInlineTimestamp: Identifiable, Equatable, Sendable {
  public let id: String
  public let date: String
  public let time: String
  public let detail: String
  public let isActive: Bool
  public let startUTF16: Int
  public let endUTF16: Int
}

public enum OrgInlineParser {
  public static func parse(_ raw: String, linkResolver: OrgRoamLinkResolver = .empty) -> [OrgInlineSpan] {
    guard hasInlineSyntaxCandidate(raw) else {
      return raw.isEmpty ? [] : [.text(raw)]
    }

    var spans: [OrgInlineSpan] = []
    var buffer = ""
    var cursor = raw.startIndex

    func flushText() {
      guard !buffer.isEmpty else { return }
      spans.append(.text(buffer))
      buffer = ""
    }

    while cursor < raw.endIndex {
      if let parsed = parseBracketLink(raw, at: cursor, linkResolver: linkResolver) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseMarkdownLink(raw, at: cursor, linkResolver: linkResolver) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parsePlainURL(raw, at: cursor) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseTimestamp(raw, at: cursor) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseFileReference(raw, at: cursor) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "`", kind: .code) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "~", kind: .code),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "=", kind: .code),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "*", kind: .bold),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "/", kind: .italic),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "_", kind: .underline),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      if let parsed = parseDelimited(raw, at: cursor, marker: "+", kind: .strike),
         markerLooksLikeOrgBoundary(raw, open: cursor, close: parsed.close) {
        flushText()
        spans.append(parsed.span)
        cursor = parsed.end
        continue
      }

      buffer.append(raw[cursor])
      cursor = raw.index(after: cursor)
    }

    flushText()
    return coalesceText(spans)
  }

  public static func hasInlineSyntaxCandidate(_ raw: String) -> Bool {
    let bytes = raw.utf8
    var index = bytes.startIndex
    while index < bytes.endIndex {
      switch bytes[index] {
      case 0x5B, 0x5D, 0x3C, 0x3E, 0x60, 0x7E, 0x3D, 0x2A, 0x2F, 0x5F, 0x2B:
        return true
      case 0x2E:
        if utf8(bytes, at: index, matches: orgExtensionBytes)
          || utf8(bytes, at: index, matches: mdExtensionBytes) {
          return true
        }
      case 0x68, 0x48:
        if utf8(bytes, at: index, matches: httpBytes)
          || utf8(bytes, at: index, matches: httpsBytes)
          || utf8(bytes, at: index, matches: uppercaseHTTPBytes)
          || utf8(bytes, at: index, matches: uppercaseHTTPSBytes) {
          return true
        }
      default:
        break
      }
      index = bytes.index(after: index)
    }
    return false
  }

  public static func hasInlineSyntaxCandidate(
    _ raw: String,
    near range: NSRange,
    radius: Int
  ) -> Bool {
    guard !raw.isEmpty else { return false }
    let text = raw as NSString
    let safeRadius = max(0, radius)
    let textLength = text.length
    let safeLocation = min(max(0, range.location), textLength)
    let selectionEnd = min(textLength, safeLocation + min(max(0, range.length), textLength - safeLocation))
    return hasInlineSyntaxCandidate(
      text,
      startUTF16: max(0, safeLocation - safeRadius),
      endUTF16: min(textLength, selectionEnd + safeRadius)
    )
  }

  private enum DelimitedKind {
    case code
    case bold
    case italic
    case underline
    case strike
  }

  private static func parseBracketLink(
    _ raw: String,
    at cursor: String.Index,
    linkResolver: OrgRoamLinkResolver
  ) -> (span: OrgInlineSpan, end: String.Index)? {
    guard raw[cursor...].hasPrefix("[[") else { return nil }
    let bodyStart = raw.index(cursor, offsetBy: 2)
    guard let closeRange = raw[bodyStart...].range(of: "]]") else { return nil }
    let body = String(raw[bodyStart..<closeRange.lowerBound])
    let parts = body.components(separatedBy: "][")
    guard let target = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
      return nil
    }
    let expandedTarget = linkResolver.expandedLinkTarget(target)
    let label = parts.dropFirst().joined(separator: "][").trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = AIChatFileReference.fromLinkTarget(expandedTarget).map {
      OrgRoamResolvedLink(title: $0.displayTitle, fileReference: $0)
    } ?? linkResolver.resolve(target: expandedTarget)
    let display: String
    if !label.isEmpty {
      display = label
    } else if expandedTarget.lowercased().hasPrefix("id:") {
      display = resolved?.title ?? expandedTarget
    } else {
      display = target
    }
    if let colorBinding = OrgColorBinding.parse(target: target, label: display) {
      return (.color(colorBinding), closeRange.upperBound)
    }
    return (
      .link(label: display, target: expandedTarget, fileReference: resolved?.fileReference),
      closeRange.upperBound
    )
  }

  private static func parseMarkdownLink(
    _ raw: String,
    at cursor: String.Index,
    linkResolver: OrgRoamLinkResolver
  ) -> (span: OrgInlineSpan, end: String.Index)? {
    guard raw[cursor] == "[", !raw[cursor...].hasPrefix("[[") else { return nil }
    let labelStart = raw.index(after: cursor)
    guard let labelEnd = raw[labelStart...].firstIndex(of: "]") else { return nil }
    let targetOpen = raw.index(after: labelEnd)
    guard targetOpen < raw.endIndex, raw[targetOpen] == "(" else { return nil }
    let targetStart = raw.index(after: targetOpen)
    guard let targetEnd = raw[targetStart...].firstIndex(of: ")") else { return nil }
    let label = String(raw[labelStart..<labelEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    let target = String(raw[targetStart..<targetEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty, !target.isEmpty else { return nil }
    let expandedTarget = linkResolver.expandedLinkTarget(target)
    let resolved = AIChatFileReference.fromLinkTarget(expandedTarget).map {
      OrgRoamResolvedLink(title: $0.displayTitle, fileReference: $0)
    } ?? linkResolver.resolve(target: expandedTarget)
    return (
      .link(label: label, target: expandedTarget, fileReference: resolved?.fileReference),
      raw.index(after: targetEnd)
    )
  }

  private static func parsePlainURL(_ raw: String, at cursor: String.Index) -> (span: OrgInlineSpan, end: String.Index)? {
    guard raw[cursor...].hasPrefix("http://") || raw[cursor...].hasPrefix("https://") else { return nil }
    var end = cursor
    while end < raw.endIndex, !raw[end].isWhitespace, !["]", ")", "\"", "'", "`", "<", ">"].contains(raw[end]) {
      end = raw.index(after: end)
    }
    var target = String(raw[cursor..<end])
    while let last = target.last, [".", ",", ";", ":"].contains(String(last)) {
      target.removeLast()
      end = raw.index(before: end)
    }
    guard !target.isEmpty else { return nil }
    return (.link(label: target, target: target, fileReference: nil), end)
  }

  private static func parseTimestamp(_ raw: String, at cursor: String.Index) -> (span: OrgInlineSpan, end: String.Index)? {
    let open = raw[cursor]
    guard open == "<" || open == "[" else { return nil }
    let close: Character = open == "<" ? ">" : "]"
    let bodyStart = raw.index(after: cursor)
    guard let closeIndex = raw[bodyStart...].firstIndex(of: close) else { return nil }
    let body = String(raw[bodyStart..<closeIndex])
    guard let parsed = parseTimestampBody(body) else { return nil }
    return (
      .timestamp(OrgInlineTimestamp(
        raw: String(raw[cursor...closeIndex]),
        dateLabel: parsed.dateLabel,
        timeLabel: parsed.timeLabel,
        detail: parsed.detail
      )),
      raw.index(after: closeIndex)
    )
  }

  private static func parseTimestampBody(_ body: String) -> (dateLabel: String, timeLabel: String?, detail: String?)? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    let ns = trimmed as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    guard let match = timestampBodyRegex.firstMatch(in: trimmed, range: fullRange),
          match.range.location == 0,
          match.range(at: 1).location != NSNotFound
    else {
      return nil
    }

    let rawDate = ns.substring(with: match.range(at: 1))
    let timeLabel: String?
    if match.range(at: 2).location != NSNotFound {
      timeLabel = ns.substring(with: match.range(at: 2))
    } else {
      timeLabel = nil
    }
    let detail: String?
    if match.range(at: 3).location != NSNotFound {
      let parsedDetail = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
      detail = parsedDetail.isEmpty ? nil : parsedDetail
    } else {
      detail = nil
    }

    return (formattedDate(rawDate), timeLabel, detail)
  }

  private static func formattedDate(_ raw: String) -> String {
    let parts = raw.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          parts[1] >= 1,
          parts[1] <= monthNames.count
    else {
      return raw
    }
    return "\(monthNames[parts[1] - 1]) \(parts[2]), \(parts[0])"
  }

  private static func parseFileReference(_ raw: String, at cursor: String.Index) -> (span: OrgInlineSpan, end: String.Index)? {
    guard mayStartFileReference(raw, at: cursor) else { return nil }
    let remaining = String(raw[cursor...])
    let nsRemaining = remaining as NSString
    let fullRange = NSRange(location: 0, length: nsRemaining.length)
    guard let match = fileReferenceRegex.firstMatch(in: remaining, range: fullRange),
          match.range.location == 0
    else {
      return nil
    }

    let rawPath = nsRemaining.substring(with: match.range(at: 1))
    let line: Int?
    if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
      line = Int(nsRemaining.substring(with: match.range(at: 2)))
    } else {
      line = nil
    }
    let reference = AIChatFileReference(path: rawPath, line: line)
    let display = reference.displayTitle
    let end = raw.index(cursor, offsetBy: match.range.length)
    return (.link(label: display, target: reference.path, fileReference: reference), end)
  }

  private static func mayStartFileReference(_ raw: String, at cursor: String.Index) -> Bool {
    let character = raw[cursor]
    if character == "/" || character == "~" {
      return true
    }
    if raw[cursor...].hasPrefix("file:") {
      return true
    }
    guard character.isASCIIWord || character == "." || character == "-" || character == "_" else {
      return false
    }

    var hasSlash = false
    var search = cursor
    while search < raw.endIndex {
      let current = raw[search]
      if current.isWhitespace || ["]", ")", "\"", "'", "`", "<", ">"].contains(current) {
        break
      }
      if current == "/" {
        hasSlash = true
      }
      if hasSlash,
         raw[search...].hasPrefix(".org") || raw[search...].hasPrefix(".md") {
        return true
      }
      search = raw.index(after: search)
    }
    return false
  }

  private static func parseDelimited(
    _ raw: String,
    at cursor: String.Index,
    marker: Character,
    kind: DelimitedKind
  ) -> (span: OrgInlineSpan, close: String.Index, end: String.Index)? {
    guard raw[cursor] == marker else { return nil }
    let contentStart = raw.index(after: cursor)
    guard contentStart < raw.endIndex, !raw[contentStart].isWhitespace else { return nil }

    var search = contentStart
    while search < raw.endIndex {
      guard let close = raw[search...].firstIndex(of: marker) else { return nil }
      let beforeClose = raw.index(before: close)
      let afterClose = raw.index(after: close)
      if !raw[beforeClose].isWhitespace {
        let content = String(raw[contentStart..<close])
        guard !content.isEmpty else { return nil }
        return (span(for: kind, content: content), close, afterClose)
      }
      search = raw.index(after: close)
    }

    return nil
  }

  private static func markerLooksLikeOrgBoundary(_ raw: String, open: String.Index, close: String.Index) -> Bool {
    let beforeOpen = open > raw.startIndex ? raw.index(before: open) : nil
    let afterClose = raw.index(after: close)
    let opensAtBoundary = beforeOpen.map { isBoundary(raw[$0]) } ?? true
    let closesAtBoundary = afterClose < raw.endIndex ? isBoundary(raw[afterClose]) : true
    return opensAtBoundary && closesAtBoundary
  }

  private static func isBoundary(_ character: Character) -> Bool {
    if character.isWhitespace { return true }
    return !character.isASCIIWord
  }

  private static func span(for kind: DelimitedKind, content: String) -> OrgInlineSpan {
    switch kind {
    case .code:
      return .code(content)
    case .bold:
      return .bold(content)
    case .italic:
      return .italic(content)
    case .underline:
      return .underline(content)
    case .strike:
      return .strike(content)
    }
  }

  private static func coalesceText(_ spans: [OrgInlineSpan]) -> [OrgInlineSpan] {
    var output: [OrgInlineSpan] = []
    for span in spans {
      if case .text(let next) = span,
         case .text(let previous)? = output.last {
        output.removeLast()
        output.append(.text(previous + next))
      } else {
        output.append(span)
      }
    }
    return output
  }

  private static let monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
  ]
  private static let orgExtensionBytes: [UInt8] = [0x2E, 0x6F, 0x72, 0x67]
  private static let mdExtensionBytes: [UInt8] = [0x2E, 0x6D, 0x64]
  private static let httpBytes: [UInt8] = [0x68, 0x74, 0x74, 0x70, 0x3A, 0x2F, 0x2F]
  private static let httpsBytes: [UInt8] = [0x68, 0x74, 0x74, 0x70, 0x73, 0x3A, 0x2F, 0x2F]
  private static let uppercaseHTTPBytes: [UInt8] = [0x48, 0x54, 0x54, 0x50, 0x3A, 0x2F, 0x2F]
  private static let uppercaseHTTPSBytes: [UInt8] = [0x48, 0x54, 0x54, 0x50, 0x53, 0x3A, 0x2F, 0x2F]
  private static let orgExtensionUTF16: [UInt16] = [0x2E, 0x6F, 0x72, 0x67]
  private static let mdExtensionUTF16: [UInt16] = [0x2E, 0x6D, 0x64]
  private static let httpUTF16: [UInt16] = [0x68, 0x74, 0x74, 0x70, 0x3A, 0x2F, 0x2F]
  private static let httpsUTF16: [UInt16] = [0x68, 0x74, 0x74, 0x70, 0x73, 0x3A, 0x2F, 0x2F]
  private static let uppercaseHTTPUTF16: [UInt16] = [0x48, 0x54, 0x54, 0x50, 0x3A, 0x2F, 0x2F]
  private static let uppercaseHTTPSUTF16: [UInt16] = [0x48, 0x54, 0x54, 0x50, 0x53, 0x3A, 0x2F, 0x2F]

  private static func utf8(_ bytes: String.UTF8View, at start: String.UTF8View.Index, matches pattern: [UInt8]) -> Bool {
    var index = start
    for expected in pattern {
      guard index < bytes.endIndex, bytes[index] == expected else {
        return false
      }
      index = bytes.index(after: index)
    }
    return true
  }

  private static func hasInlineSyntaxCandidate(
    _ text: NSString,
    startUTF16: Int,
    endUTF16: Int
  ) -> Bool {
    let safeStart = min(max(0, startUTF16), text.length)
    let safeEnd = min(max(safeStart, endUTF16), text.length)
    guard safeStart < safeEnd else {
      return false
    }

    var index = safeStart
    let end = safeEnd
    while index < end {
      switch text.character(at: index) {
      case 0x5B, 0x5D, 0x3C, 0x3E, 0x60, 0x7E, 0x3D, 0x2A, 0x2F, 0x5F, 0x2B:
        return true
      case 0x2E:
        if utf16Matches(text, at: index, before: end, pattern: orgExtensionUTF16)
          || utf16Matches(text, at: index, before: end, pattern: mdExtensionUTF16) {
          return true
        }
      case 0x68, 0x48:
        if utf16Matches(text, at: index, before: end, pattern: httpUTF16)
          || utf16Matches(text, at: index, before: end, pattern: httpsUTF16)
          || utf16Matches(text, at: index, before: end, pattern: uppercaseHTTPUTF16)
          || utf16Matches(text, at: index, before: end, pattern: uppercaseHTTPSUTF16) {
          return true
        }
      default:
        break
      }
      index += 1
    }
    return false
  }

  private static func utf16Matches(
    _ text: NSString,
    at start: Int,
    before end: Int,
    pattern: [UInt16]
  ) -> Bool {
    var index = start
    for expected in pattern {
      guard index < end, text.character(at: index) == expected else {
        return false
      }
      index += 1
    }
    return true
  }

  private static let timestampBodyRegex = try! NSRegularExpression(
    pattern: #"^(\d{4}-\d{2}-\d{2})(?:\s+[A-Za-z]{3})?(?:\s+(\d{1,2}:\d{2}(?:-\d{1,2}:\d{2})?))?(.*)$"#
  )
  private static let fileReferenceRegex = try! NSRegularExpression(
    pattern: #"^((?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:(?::|#)[Ll]?(\d+)(?:-[Ll]?\d+)?)?"#
  )
}

public struct OrgMediaAttachment: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case image
    case video
  }

  public struct EmbeddedGroup: Equatable, Sendable {
    public let displayText: String
    public let attachments: [OrgMediaAttachment]
  }

  public let kind: Kind
  public let label: String
  public let target: String
  public let resolvedPath: String?

  public var remoteURL: URL? {
    Self.remoteURL(forTarget: target)
  }

  public var isRemote: Bool {
    remoteURL != nil
  }

  public var resolvedURL: URL? {
    if let remoteURL {
      return remoteURL
    }
    return resolvedPath.map { URL(fileURLWithPath: $0) }
  }

  public var displayName: String {
    let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedLabel.isEmpty {
      return trimmedLabel
    }
    let cleaned = Self.cleanTarget(target)
    if let url = Self.remoteURL(forTarget: cleaned) {
      let pathName = url.lastPathComponent
      if !pathName.isEmpty {
        return pathName
      }
      return url.host ?? target
    }
    let name = URL(fileURLWithPath: cleaned).lastPathComponent
    return name.isEmpty ? target : name
  }

  public static func standalone(
    raw: String,
    sourceFile: String? = nil,
    corpusRoot: URL? = nil
  ) -> OrgMediaAttachment? {
    guard mayContainStandaloneMedia(raw) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
    guard let link = standaloneLink(trimmed) else { return nil }
    guard let kind = kind(forTarget: link.target) else { return nil }

    return OrgMediaAttachment(
      kind: kind,
      label: link.label,
      target: link.target,
      resolvedPath: remoteURL(forTarget: link.target) == nil
        ? resolvePath(link.target, sourceFile: sourceFile, corpusRoot: corpusRoot)
        : nil
    )
  }

  public static func embedded(
    in raw: String,
    sourceFile: String? = nil,
    corpusRoot: URL? = nil
  ) -> EmbeddedGroup? {
    guard mayContainMediaTarget(raw) else { return nil }

    var cursor = raw.startIndex
    var displayText = ""
    var attachments: [OrgMediaAttachment] = []

    while cursor < raw.endIndex {
      if let parsed = parseEmbeddedBracketLink(raw, at: cursor, sourceFile: sourceFile, corpusRoot: corpusRoot) {
        attachments.append(parsed.attachment)
        cursor = parsed.end
        continue
      }

      if let parsed = parseEmbeddedMarkdownLink(raw, at: cursor, sourceFile: sourceFile, corpusRoot: corpusRoot) {
        attachments.append(parsed.attachment)
        cursor = parsed.end
        continue
      }

      if let parsed = parseEmbeddedPlainMediaURL(raw, at: cursor, sourceFile: sourceFile, corpusRoot: corpusRoot) {
        attachments.append(parsed.attachment)
        cursor = parsed.end
        continue
      }

      displayText.append(raw[cursor])
      cursor = raw.index(after: cursor)
    }

    guard !attachments.isEmpty else { return nil }
    return EmbeddedGroup(displayText: normalizedEmbeddedDisplayText(displayText), attachments: attachments)
  }

  public static func mayContainStandaloneMedia(_ raw: String) -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("\n") else { return false }
    if let link = standaloneLink(trimmed),
       kind(forTarget: link.target) != nil {
      return true
    }
    guard let dot = trimmed.lastIndex(of: ".") else { return false }

    let extensionStart = trimmed.index(after: dot)
    guard extensionStart < trimmed.endIndex else { return false }
    let extensionEnd = trimmed[extensionStart...].firstIndex { character in
      character == "]" || character == ")" || character == "#" || character == "?" || character.isWhitespace
    } ?? trimmed.endIndex
    let ext = String(trimmed[extensionStart..<extensionEnd]).lowercased()
    guard imageExtensions.contains(ext) || videoExtensions.contains(ext) else {
      return false
    }

    if trimmed.hasPrefix("[[") || trimmed.hasPrefix("[") {
      return true
    }
    return trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
  }

  public static func mayContainMediaTarget(_ raw: String) -> Bool {
    let range = NSRange(location: 0, length: (raw as NSString).length)
    return mediaTargetCandidateRegex.firstMatch(in: raw, range: range) != nil
  }

  private static func standaloneLink(_ raw: String) -> (label: String, target: String)? {
    if let bracket = parseBracketLink(raw) {
      return bracket
    }
    if let markdown = parseMarkdownLink(raw) {
      return markdown
    }
    guard raw.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
    return (label: "", target: raw)
  }

  private static func parseBracketLink(_ raw: String) -> (label: String, target: String)? {
    let pattern = #"^\[\[([^\]\n]+)(?:\]\[([^\]\n]*))?\]\]$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = raw as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: raw, range: range),
          match.range(at: 1).location != NSNotFound
    else {
      return nil
    }
    let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    let label = match.range(at: 2).location == NSNotFound
      ? ""
      : ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }
    return (label, target)
  }

  private static func parseMarkdownLink(_ raw: String) -> (label: String, target: String)? {
    let pattern = #"^\[([^\]\n]*)\]\(([^\)\n]+)\)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = raw as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = regex.firstMatch(in: raw, range: range),
          match.range(at: 2).location != NSNotFound
    else {
      return nil
    }
    let label = match.range(at: 1).location == NSNotFound
      ? ""
      : ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    let target = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }
    return (label, target)
  }

  private static func parseEmbeddedBracketLink(
    _ raw: String,
    at cursor: String.Index,
    sourceFile: String?,
    corpusRoot: URL?
  ) -> (attachment: OrgMediaAttachment, end: String.Index)? {
    guard raw[cursor...].hasPrefix("[[") else { return nil }
    let bodyStart = raw.index(cursor, offsetBy: 2)
    guard let closeRange = raw[bodyStart...].range(of: "]]") else { return nil }
    let linkRaw = String(raw[cursor..<closeRange.upperBound])
    guard let link = parseBracketLink(linkRaw),
          let attachment = attachment(label: link.label, target: link.target, sourceFile: sourceFile, corpusRoot: corpusRoot)
    else {
      return nil
    }
    return (attachment, closeRange.upperBound)
  }

  private static func parseEmbeddedMarkdownLink(
    _ raw: String,
    at cursor: String.Index,
    sourceFile: String?,
    corpusRoot: URL?
  ) -> (attachment: OrgMediaAttachment, end: String.Index)? {
    guard raw[cursor] == "[", !raw[cursor...].hasPrefix("[[") else { return nil }
    let labelStart = raw.index(after: cursor)
    guard let labelEnd = raw[labelStart...].firstIndex(of: "]") else { return nil }
    let targetOpen = raw.index(after: labelEnd)
    guard targetOpen < raw.endIndex, raw[targetOpen] == "(" else { return nil }
    let targetStart = raw.index(after: targetOpen)
    guard let targetEnd = raw[targetStart...].firstIndex(of: ")") else { return nil }
    let linkRaw = String(raw[cursor...targetEnd])
    guard let link = parseMarkdownLink(linkRaw),
          let attachment = attachment(label: link.label, target: link.target, sourceFile: sourceFile, corpusRoot: corpusRoot)
    else {
      return nil
    }
    return (attachment, raw.index(after: targetEnd))
  }

  private static func parseEmbeddedPlainMediaURL(
    _ raw: String,
    at cursor: String.Index,
    sourceFile: String?,
    corpusRoot: URL?
  ) -> (attachment: OrgMediaAttachment, end: String.Index)? {
    guard raw[cursor...].hasPrefix("http://") || raw[cursor...].hasPrefix("https://") else { return nil }
    var end = cursor
    while end < raw.endIndex, !raw[end].isWhitespace, !["]", ")", "\"", "'", "`", "<", ">"].contains(raw[end]) {
      end = raw.index(after: end)
    }

    var target = String(raw[cursor..<end])
    while let last = target.last, [".", ",", ";", ":"].contains(last) {
      target.removeLast()
      end = raw.index(before: end)
    }

    guard let attachment = attachment(label: "", target: target, sourceFile: sourceFile, corpusRoot: corpusRoot) else {
      return nil
    }
    return (attachment, end)
  }

  private static func attachment(
    label: String,
    target: String,
    sourceFile: String?,
    corpusRoot: URL?
  ) -> OrgMediaAttachment? {
    guard let kind = kind(forTarget: target) else { return nil }
    return OrgMediaAttachment(
      kind: kind,
      label: label,
      target: target,
      resolvedPath: remoteURL(forTarget: target) == nil
        ? resolvePath(target, sourceFile: sourceFile, corpusRoot: corpusRoot)
        : nil
    )
  }

  private static func normalizedEmbeddedDisplayText(_ raw: String) -> String {
    raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        String(line)
          .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
          .trimmingCharacters(in: .whitespaces)
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func kind(forTarget target: String) -> Kind? {
    let cleaned = cleanTarget(target)
    if isKnownVideoPageURL(cleaned) {
      return .video
    }
    let ext: String
    if let remoteURL = remoteURL(forTarget: cleaned) {
      ext = remoteURL.pathExtension.lowercased()
    } else {
      ext = URL(fileURLWithPath: cleaned).pathExtension.lowercased()
    }
    if imageExtensions.contains(ext) { return .image }
    if videoExtensions.contains(ext) { return .video }
    return nil
  }

  private static func resolvePath(_ target: String, sourceFile: String?, corpusRoot: URL?) -> String? {
    let cleaned = cleanTarget(target)
    guard !cleaned.isEmpty else { return nil }

    var candidates: [String] = []
    if cleaned.hasPrefix("~/") {
      candidates.append(NSHomeDirectory() + "/" + String(cleaned.dropFirst(2)))
    } else if NSString(string: cleaned).isAbsolutePath {
      candidates.append(cleaned)
    } else {
      if let sourceFile {
        candidates.append(URL(fileURLWithPath: sourceFile).deletingLastPathComponent().appendingPathComponent(cleaned).path)
      }
      if let corpusRoot {
        candidates.append(corpusRoot.appendingPathComponent(cleaned).standardizedFileURL.path)
      }
    }

    for candidate in candidates {
      let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
      if FileManager.default.fileExists(atPath: standardized) {
        return standardized
      }
    }
    return nil
  }

  private static func cleanTarget(_ target: String) -> String {
    var cleaned = target.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("file://") {
      cleaned = String(cleaned.dropFirst("file://".count))
    } else if cleaned.hasPrefix("file:") {
      cleaned = String(cleaned.dropFirst("file:".count))
    }
    if let fragment = cleaned.firstIndex(of: "#") {
      cleaned = String(cleaned[..<fragment])
    }
    return cleaned.removingPercentEncoding ?? cleaned
  }

  public static func remoteURL(forTarget target: String) -> URL? {
    let cleaned = cleanTarget(target)
    guard let url = URL(string: cleaned),
          let scheme = url.scheme?.lowercased()
    else {
      return nil
    }
    return scheme == "http" || scheme == "https" ? url : nil
  }

  private static func isKnownVideoPageURL(_ target: String) -> Bool {
    guard let url = remoteURL(forTarget: target),
          let host = url.host?.lowercased()
    else {
      return false
    }
    return host == "youtu.be"
      || host.hasSuffix(".youtube.com")
      || host == "youtube.com"
      || host.hasSuffix(".vimeo.com")
      || host == "vimeo.com"
  }

  private static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp"])
  private static let videoExtensions = Set(["mov", "mp4", "m4v", "avi", "webm"])
  private static let mediaTargetCandidateRegex = try! NSRegularExpression(
    pattern: #"(?:youtube\.com|youtu\.be|vimeo\.com|\.(?:png|jpg|jpeg|gif|tiff|tif|bmp|heic|heif|webp|mov|mp4|m4v|avi|webm))"#,
    options: [.caseInsensitive]
  )
}

public struct OrgEditableMediaLink: Equatable, Sendable {
  public var kind: OrgMediaAttachment.Kind
  public var target: String
  public var label: String

  public init(kind: OrgMediaAttachment.Kind, target: String, label: String = "") {
    self.kind = kind
    self.target = target
    self.label = label
  }

  public init?(rawText: String) {
    guard let attachment = OrgMediaAttachment.standalone(raw: rawText) else {
      return nil
    }
    self.kind = attachment.kind
    self.target = attachment.target
    self.label = attachment.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? attachment.displayName
      : attachment.label
  }

  public var formattedRawText: String {
    let target = normalizedTarget
    let label = normalizedLabel
    return "[[\(target)][\(label)]]"
  }

  public var normalizedTarget: String {
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = kind == .image ? "images/image.png" : "videos/video.mp4"
    let rawTarget = trimmed.isEmpty ? fallback : trimmed
    if let remoteURL = OrgMediaAttachment.remoteURL(forTarget: rawTarget) {
      return remoteURL.absoluteString
    }
    return rawTarget.lowercased().hasPrefix("file:")
      ? rawTarget
      : "file:\(rawTarget)"
  }

  private var normalizedLabel: String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return trimmed
    }
    return fallbackLabel(for: normalizedTarget)
  }

  private func fallbackLabel(for target: String) -> String {
    var cleaned = target.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.hasPrefix("file://") {
      cleaned = String(cleaned.dropFirst("file://".count))
    } else if cleaned.hasPrefix("file:") {
      cleaned = String(cleaned.dropFirst("file:".count))
    }
    if let fragment = cleaned.firstIndex(of: "#") {
      cleaned = String(cleaned[..<fragment])
    }
    cleaned = cleaned.removingPercentEncoding ?? cleaned
    if let url = OrgMediaAttachment.remoteURL(forTarget: cleaned) {
      let filename = url.lastPathComponent
      if !filename.isEmpty {
        return filename
      }
      return url.host ?? (kind == .image ? "Image" : "Video")
    }
    let filename = URL(fileURLWithPath: cleaned).lastPathComponent
    if !filename.isEmpty {
      return filename
    }
    return kind == .image ? "Image" : "Video"
  }
}

public struct SourceBlockRunPlan: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]
  public let scriptExtension: String
  public let label: String

  public var commandLabel: String {
    ([label] + arguments).joined(separator: " ")
  }

  public static func plan(for language: String?) -> SourceBlockRunPlan? {
    let normalized = language?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""

    switch normalized {
    case "sh", "shell":
      return SourceBlockRunPlan(executable: "/bin/sh", arguments: [], scriptExtension: "sh", label: "sh")
    case "bash":
      return SourceBlockRunPlan(executable: "/bin/bash", arguments: [], scriptExtension: "sh", label: "bash")
    case "zsh":
      return SourceBlockRunPlan(executable: "/bin/zsh", arguments: [], scriptExtension: "zsh", label: "zsh")
    case "python", "python3", "py":
      return SourceBlockRunPlan(executable: "/usr/bin/env", arguments: ["python3"], scriptExtension: "py", label: "python3")
    case "javascript", "js", "node":
      return SourceBlockRunPlan(executable: "/usr/bin/env", arguments: ["node"], scriptExtension: "mjs", label: "node")
    case "ruby", "rb":
      return SourceBlockRunPlan(executable: "/usr/bin/env", arguments: ["ruby"], scriptExtension: "rb", label: "ruby")
    default:
      return nil
    }
  }
}

public enum SourceBlockRunStatus: Equatable, Sendable {
  case running
  case succeeded
  case failed
  case timedOut
  case unsupported
}

public struct SourceBlockRunState: Equatable, Sendable {
  public let status: SourceBlockRunStatus
  public let language: String
  public let commandLabel: String
  public let startedAt: Date?
  public let finishedAt: Date?
  public let duration: TimeInterval?
  public let exitCode: Int32?
  public let stdout: String
  public let stderr: String
  public let message: String?

  public init(
    status: SourceBlockRunStatus,
    language: String,
    commandLabel: String,
    startedAt: Date? = nil,
    finishedAt: Date? = nil,
    duration: TimeInterval? = nil,
    exitCode: Int32? = nil,
    stdout: String = "",
    stderr: String = "",
    message: String? = nil
  ) {
    self.status = status
    self.language = language
    self.commandLabel = commandLabel
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.duration = duration
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.message = message
  }
}

public enum SourceRunOutputPresentation: Equatable, Sendable {
  case text(String)
  case table(SourceRunTable)
  case bars([SourceRunBar])
  case line(SourceRunLineChart)

  public static func make(from raw: String) -> SourceRunOutputPresentation {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .text(raw) }

    if let json = jsonPresentation(trimmed) {
      return json
    }
    if let table = pipeTablePresentation(trimmed) {
      if let line = lineChart(from: table) {
        return .line(line)
      }
      return .table(table)
    }
    if let table = separatedTablePresentation(trimmed, delimiter: "\t") {
      if let line = lineChart(from: table) {
        return .line(line)
      }
      return .table(table)
    }
    if let table = separatedTablePresentation(trimmed, delimiter: ",") {
      if let line = lineChart(from: table) {
        return .line(line)
      }
      return .table(table)
    }
    return .text(raw)
  }

  private static func jsonPresentation(_ raw: String) -> SourceRunOutputPresentation? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data)
    else {
      return nil
    }

    if let dictionary = object as? [String: Any] {
      if let bars = numericBars(from: dictionary), !bars.isEmpty {
        return .bars(bars)
      }
      return .table(SourceRunTable(
        columns: ["Key", "Value"],
        rows: dictionary.keys.sorted().map { key in [key, stringValue(dictionary[key] ?? "")] }
      ))
    }

    if let rows = object as? [[String: Any]], !rows.isEmpty {
      let columns = Array(Set(rows.flatMap(\.keys))).sorted()
      let table = SourceRunTable(
        columns: columns,
        rows: rows.map { row in columns.map { stringValue(row[$0] ?? "") } }
      )
      if let line = lineChart(from: table) {
        return .line(line)
      }
      if let bars = rowBars(from: rows, columns: columns), !bars.isEmpty {
        return .bars(bars)
      }
      return .table(table)
    }

    if let values = object as? [Any], !values.isEmpty {
      return .table(SourceRunTable(
        columns: ["Value"],
        rows: values.map { [stringValue($0)] }
      ))
    }

    return nil
  }

  private static func pipeTablePresentation(_ raw: String) -> SourceRunTable? {
    let lines = raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { String($0).trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && $0.hasPrefix("|") && $0.hasSuffix("|") }
    guard lines.count >= 2 else { return nil }

    var parsedRows: [[String]] = []
    for line in lines {
      var inner = line
      inner.removeFirst()
      inner.removeLast()
      let separatorBody = inner.trimmingCharacters(in: .whitespaces)
      if !separatorBody.isEmpty && separatorBody.allSatisfy({ $0 == "-" || $0 == "+" }) {
        continue
      }
      parsedRows.append(inner.split(separator: "|", omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: .whitespaces)
      })
    }

    guard let header = parsedRows.first,
          header.count >= 2,
          parsedRows.dropFirst().allSatisfy({ $0.count == header.count })
    else {
      return nil
    }
    return SourceRunTable(columns: header, rows: Array(parsedRows.dropFirst()))
  }

  private static func separatedTablePresentation(_ raw: String, delimiter: Character) -> SourceRunTable? {
    let lines = raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard lines.count >= 2 else { return nil }

    let parsed = lines.map { line in
      line.split(separator: delimiter, omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: .whitespaces)
      }
    }
    guard let header = parsed.first,
          header.count >= 2,
          parsed.dropFirst().allSatisfy({ $0.count == header.count })
    else {
      return nil
    }
    return SourceRunTable(columns: header, rows: Array(parsed.dropFirst()))
  }

  private static func numericBars(from dictionary: [String: Any]) -> [SourceRunBar]? {
    let bars = dictionary.keys.sorted().compactMap { key -> SourceRunBar? in
      guard let value = numericValue(dictionary[key] ?? "") else { return nil }
      return SourceRunBar(label: key, value: value)
    }
    return bars.count == dictionary.count ? bars : nil
  }

  private static func rowBars(from rows: [[String: Any]], columns: [String]) -> [SourceRunBar]? {
    guard columns.count == 2 else { return nil }
    let numericColumns = columns.filter { column in
      rows.allSatisfy { numericValue($0[column] ?? "") != nil }
    }
    guard numericColumns.count == 1,
          let numericColumn = numericColumns.first,
          let labelColumn = columns.first(where: { $0 != numericColumn })
    else {
      return nil
    }

    var bars: [SourceRunBar] = []
    var seenLabels: [String: Int] = [:]
    for row in rows {
      guard let value = numericValue(row[numericColumn] ?? "") else { return nil }
      let baseLabel = stringValue(row[labelColumn] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !baseLabel.isEmpty else { return nil }

      let count = (seenLabels[baseLabel] ?? 0) + 1
      seenLabels[baseLabel] = count
      let label = count == 1 ? baseLabel : "\(baseLabel) \(count)"
      bars.append(SourceRunBar(label: label, value: value))
    }
    return bars
  }

  private static func lineChart(from table: SourceRunTable) -> SourceRunLineChart? {
    guard table.columns.count == 2,
          table.rows.count >= 2
    else {
      return nil
    }

    var points: [SourceRunLinePoint] = []
    for row in table.rows {
      guard row.count == 2,
            let x = numericValue(row[0]),
            let y = numericValue(row[1])
      else {
        return nil
      }
      points.append(SourceRunLinePoint(x: x, y: y))
    }

    guard !points.isEmpty else { return nil }
    return SourceRunLineChart(
      xLabel: table.columns[0],
      yLabel: table.columns[1],
      points: points
    )
  }

  private static func numericValue(_ value: Any) -> Double? {
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return nil
      }
      return number.doubleValue
    }
    if let string = value as? String {
      return Double(string)
    }
    return nil
  }

  private static func stringValue(_ value: Any) -> String {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      return number.stringValue
    case _ as NSNull:
      return ""
    default:
      if JSONSerialization.isValidJSONObject([value]),
         let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
         let text = String(data: data, encoding: .utf8) {
        return text
      }
      return "\(value)"
    }
  }
}

public struct SourceRunTable: Equatable, Sendable {
  public let columns: [String]
  public let rows: [[String]]

  public init(columns: [String], rows: [[String]]) {
    self.columns = columns
    self.rows = rows
  }
}

public struct SourceRunBar: Equatable, Sendable {
  public let label: String
  public let value: Double

  public init(label: String, value: Double) {
    self.label = label
    self.value = value
  }
}

public struct SourceRunLineChart: Equatable, Sendable {
  public let xLabel: String
  public let yLabel: String
  public let points: [SourceRunLinePoint]

  public init(xLabel: String, yLabel: String, points: [SourceRunLinePoint]) {
    self.xLabel = xLabel
    self.yLabel = yLabel
    self.points = points
  }
}

public struct SourceRunLinePoint: Equatable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

private extension Character {
  var isASCIIWord: Bool {
    unicodeScalars.allSatisfy { scalar in
      (65...90).contains(Int(scalar.value))
        || (97...122).contains(Int(scalar.value))
        || (48...57).contains(Int(scalar.value))
    }
  }
}

public enum WorkspaceLocation: Hashable, Sendable {
  case agenda(AgendaItem)
  case assigned(AssignedWorkItem)
  case search(SearchResult)
  case backlink(BacklinkItem)
  case aiChatThreadRecord(AIChatThreadRecord)
  case meeting(MeetingWorkspaceItem)

  public var title: String {
    switch self {
    case .agenda(let item): Org2Display.cleanInline(item.headline)
    case .assigned(let item): Org2Display.cleanInline(item.headline)
    case .search(let result): Org2Display.cleanInline(result.title)
    case .backlink(let backlink): Org2Display.cleanInline(backlink.srcTitle)
    case .aiChatThreadRecord(let thread): Org2Display.cleanInline(thread.title)
    case .meeting(let meeting): Org2Display.cleanInline(meeting.title)
    }
  }

  public var subtitle: String {
    switch self {
    case .agenda(let item): [item.todo, item.planningLabel].compactMap { $0 }.joined(separator: " ")
    case .assigned(let item): [item.todo, item.status, item.assignee].compactMap { $0 }.joined(separator: " ")
    case .search(let result): Org2Display.cleanInline(result.snippet)
    case .backlink(let backlink): Org2Display.cleanInline(backlink.context)
    case .aiChatThreadRecord(let thread): thread.zone
    case .meeting(let meeting):
      [meeting.recordedAt, meeting.transcriptionStatus].compactMap { $0 }.joined(separator: " ")
    }
  }

  public var file: String {
    switch self {
    case .agenda(let item): item.file
    case .assigned(let item): item.file
    case .search(let result): result.file
    case .backlink(let backlink): backlink.file
    case .aiChatThreadRecord(let thread): thread.file
    case .meeting(let meeting): meeting.file
    }
  }

  public var lineForEditor: Int {
    switch self {
    case .agenda(let item): item.lineForEditor
    case .assigned(let item): item.lineForEditor
    case .search(let result): result.lineForEditor
    case .backlink(let backlink): backlink.lineForEditor
    case .aiChatThreadRecord(let thread): thread.lineForEditor
    case .meeting(let meeting): meeting.lineForEditor
    }
  }

  public var idValue: String? {
    switch self {
    case .agenda(let item): item.idValue
    case .assigned: nil
    case .search(let result): result.idValue
    case .backlink(let backlink): backlink.srcId
    case .aiChatThreadRecord(let thread): thread.idValue
    case .meeting(let meeting): meeting.idValue
    }
  }
}

public enum Org2Display {
  private static let labeledLinkRegex = try! NSRegularExpression(
    pattern: #"\[\[([^\]\n]+)\]\[([^\]\n]*)\]\]"#
  )
  private static let bareLinkRegex = try! NSRegularExpression(
    pattern: #"\[\[([^\]\n]+)\]\]"#
  )
  private static let bareIDRegex = try! NSRegularExpression(
    pattern: #"\bid:([0-9a-fA-F-]{36})\b"#
  )

  public static func cleanInline(_ raw: String) -> String {
    var text = raw
    if text.contains("[[") {
      text = replaceMatches(in: text, regex: labeledLinkRegex) { match in
        guard match.numberOfRanges >= 3 else { return match.fullText(in: text) }
        return match.string(at: 2, in: text)
      }

      text = replaceMatches(in: text, regex: bareLinkRegex) { match in
        guard match.numberOfRanges >= 2 else { return match.fullText(in: text) }
        let target = match.string(at: 1, in: text)
        return cleanTarget(target)
      }
    }

    if text.range(of: "id:", options: .caseInsensitive) != nil {
      text = replaceMatches(in: text, regex: bareIDRegex) { match in
        guard match.numberOfRanges >= 2 else { return match.fullText(in: text) }
        return "id:\(shortID(match.string(at: 1, in: text)))"
      }
    }

    return text
      .replacingOccurrences(of: #"\"#, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func cleanBlock(_ raw: String) -> String {
    raw
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { cleanInline(String($0)) }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Cleans only a bounded prefix for collection-row previews. Approval bodies
  /// can contain multi-megabyte run evidence, while their rows display just a
  /// few lines; normalizing the entire body on every SwiftUI selection update
  /// needlessly blocks the main thread.
  public static func cleanBlockPreview(_ raw: String, maxCharacters: Int) -> String {
    guard maxCharacters > 0 else { return "" }
    let sourceLimit = max(maxCharacters, maxCharacters * 4)
    let bounded = String(raw.prefix(sourceLimit))
    return cleanBlock(bounded).trimmedForDisplay(maxCharacters: maxCharacters)
  }

  public static func shortID(_ raw: String) -> String {
    String(raw.prefix(8))
  }

  private static func cleanTarget(_ target: String) -> String {
    if target.hasPrefix("id:") {
      return "id:\(shortID(String(target.dropFirst(3))))"
    }
    if target.hasPrefix("file:") {
      return URL(fileURLWithPath: String(target.dropFirst(5))).lastPathComponent
    }
    return target
  }

  private static func replaceMatches(
    in text: String,
    regex: NSRegularExpression,
    transform: (NSTextCheckingResult) -> String
  ) -> String {
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
    var output = text
    for match in matches {
      guard let range = Range(match.range, in: output) else { continue }
      output.replaceSubrange(range, with: transform(match))
    }
    return output
  }
}

extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func trimmedForDisplay(maxCharacters: Int) -> String {
    let compact = trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    guard compact.count > maxCharacters else { return compact }
    return String(compact.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }
}

private extension NSTextCheckingResult {
  func string(at index: Int, in text: String) -> String {
    guard index < numberOfRanges,
          let range = Range(range(at: index), in: text)
    else {
      return ""
    }
    return String(text[range])
  }

  func fullText(in text: String) -> String {
    guard let range = Range(range, in: text) else { return "" }
    return String(text[range])
  }
}

public struct AgendaDisplaySection: Identifiable, Sendable {
  public let id: String
  public let label: String
  public let items: [AgendaItem]
  public let hint: String?

  public init(id: String, label: String, items: [AgendaItem], hint: String? = nil) {
    self.id = id
    self.label = label
    self.items = items
    self.hint = hint
  }
}

public struct AssignedWorkSection: Identifiable, Sendable {
  public let id: String
  public let label: String
  public let items: [AssignedWorkItem]

  public init(id: String, label: String, items: [AssignedWorkItem]) {
    self.id = id
    self.label = label
    self.items = items
  }
}

public struct MeetingSection: Identifiable, Sendable {
  public let id: String
  public let label: String
  public let meetings: [MeetingWorkspaceItem]

  public init(id: String, label: String, meetings: [MeetingWorkspaceItem]) {
    self.id = id
    self.label = label
    self.meetings = meetings
  }
}

public struct WorkspaceHealthCheck: Identifiable, Equatable, Sendable {
  public enum Status: String, Sendable {
    case ready
    case warning
    case blocking

    public var title: String {
      switch self {
      case .ready: "Ready"
      case .warning: "Warning"
      case .blocking: "Blocked"
      }
    }
  }

  public let id: String
  public let title: String
  public let status: Status
  public let detail: String
  public let remediationTitle: String?

  public init(id: String, title: String, status: Status, detail: String, remediationTitle: String? = nil) {
    self.id = id
    self.title = title
    self.status = status
    self.detail = detail
    self.remediationTitle = remediationTitle
  }
}

public enum AgendaMode: String, CaseIterable, Identifiable, Sendable {
  case focus
  case today
  case range
  case assigned

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .focus: "Focus"
    case .today: "Today"
    case .range: "Range"
    case .assigned: "All Time"
    }
  }
}

public enum AgendaDateFilter: String, CaseIterable, Identifiable, Sendable {
  case any
  case overdue
  case today
  case next7
  case later

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .any: "Any date"
    case .overdue: "Overdue"
    case .today: "Today"
    case .next7: "Next 7 days"
    case .later: "Later"
    }
  }
}

public enum AgendaOverdueOrder: String, CaseIterable, Identifiable, Sendable {
  case priority
  case dueDate

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .priority: "Priority first"
    case .dueDate: "Due date"
    }
  }
}

public enum TodoEditStatus: String, Sendable {
  case todo
  case inProgress = "in_progress"
  case done
  case canceled

  public var label: String {
    switch self {
    case .todo: "TODO"
    case .inProgress: "IN_PROGRESS"
    case .done: "DONE"
    case .canceled: "CANCELED"
    }
  }
}

public enum PlanningEditKind: String, Sendable {
  case scheduled
  case deadline
}

public enum PlanningDateTarget: Sendable {
  case today
  case tomorrow
  case upcomingMonday
  case nextMonth
}

public enum DetailScrollDirection: Equatable, Sendable {
  case up
  case down
}

public enum DetailScrollTarget: Equatable, Sendable {
  case page(DetailScrollDirection)
  case block(String)
  case revealBlock(String)
  case sourceLine(Int)
}

public struct DetailScrollRequest: Equatable, Sendable {
  public let id: Int
  public let target: DetailScrollTarget

  public init(id: Int, target: DetailScrollTarget) {
    self.id = id
    self.target = target
  }

  public init(id: Int, direction: DetailScrollDirection) {
    self.init(id: id, target: .page(direction))
  }
}

public enum DailyNoteTarget: String, CaseIterable, Identifiable, Sendable {
  case today
  case yesterday
  case tomorrow

  public static let datePickerCommandShortcutTitle = "⌘⇧7"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .yesterday: "Yesterday"
    case .today: "Today"
    case .tomorrow: "Tomorrow"
    }
  }

  public var commandShortcutTitle: String {
    switch self {
    case .today: "⌘7"
    case .yesterday: "⌘8"
    case .tomorrow: "⌘9"
    }
  }
}

public struct TodoMutationPayload: Decodable, Sendable {
  public let file: String
  public let headingLine: Int
  public let oldStatus: String
  public let newStatus: String
  public let applied: Bool
  public let changed: Bool
}

public struct TodoAssignmentPayload: Decodable, Sendable {
  public let file: String
  public let headingLine: Int
  public let property: String
  public let oldAssignee: String?
  public let newAssignee: String
  public let applied: Bool
  public let changed: Bool
}

public struct PlanMutationPayload: Decodable, Sendable {
  public let file: String
  public let headingLine: Int
  public let kind: String
  public let date: String
  public let applied: Bool
  public let changed: Bool
}
