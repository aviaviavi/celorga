import Foundation
import SwiftUI

// MARK: - Presentation

/// The durable runs an AI chat created (`celorga run create --thread`), as the
/// chat shows them above its composer. Pure and cheap: it reads cached run and
/// approval state and never asks the CLI for anything.
///
/// A run appears when it is still working or needs the user:
/// - queued, running, waiting for approval, or blocked;
/// - any run with an undecided approval, whatever its status;
/// - failed within the recent window (older failures stay in Agent Work).
/// Runs that completed or were canceled within the recent window are only
/// counted, behind a disclosure. Everything older is left to Agent Work.
struct AIChatLinkedRunsSummary: Equatable {
  struct Approval: Identifiable, Equatable {
    /// The Review queue item ID (`run:RUN:APPROVAL`).
    let id: ApprovalItem.ID
    let runID: AgentRunItem.ID
    let approvalID: String
    let title: String
    let action: String
    /// The Review queue item for this decision. Approve and Reject are offered
    /// only when it exists, so the chat decides through the queue's own path.
    let queueItem: ApprovalItem?
    let isSnoozed: Bool
  }

  struct Run: Identifiable, Equatable {
    let id: AgentRunItem.ID
    let title: String
    let status: RunBadgePresentation
    let needsUser: Bool
    let approvals: [Approval]
  }

  /// Active runs and runs that need the user: those needing the user first,
  /// then the rest, each most recently updated first.
  let runs: [Run]
  /// Runs that finished within the recent window, most recently updated first.
  let recentlyFinished: [Run]

  static let empty = AIChatLinkedRunsSummary(runs: [], recentlyFinished: [])
  static let recentWindow: TimeInterval = 24 * 60 * 60

  var isEmpty: Bool { runs.isEmpty && recentlyFinished.isEmpty }
  var pendingApprovalCount: Int { runs.reduce(0) { $0 + $1.approvals.count } }

  static func make(
    runs linkedRuns: [AgentRunItem],
    queueItems: [ApprovalItem],
    snoozedQueueItems: [ApprovalItem] = [],
    now: Date
  ) -> AIChatLinkedRunsSummary {
    guard !linkedRuns.isEmpty else { return .empty }
    var queueItemsByID: [ApprovalItem.ID: ApprovalItem] = [:]
    let runIDsWithPendingApprovals = Set(linkedRuns.lazy.filter { $0.pendingApprovalCount > 0 }.map(\.id))
    if !runIDsWithPendingApprovals.isEmpty {
      for item in queueItems + snoozedQueueItems
      where item.isRunApproval && runIDsWithPendingApprovals.contains(item.runId ?? "") {
        queueItemsByID[item.id] = queueItemsByID[item.id] ?? item
      }
    }

    var active: [(run: Run, updatedAt: String)] = []
    var finished: [(run: Run, updatedAt: String)] = []
    var seen = Set<AgentRunItem.ID>()
    for run in linkedRuns where seen.insert(run.id).inserted {
      let approvals = run.actionablePendingApprovals.map { approval in
        let id = WorkspaceStore.runApprovalQueueItemID(runID: run.id, approvalID: approval.id)
        let queueItem = queueItemsByID[id]
        return Approval(
          id: id,
          runID: run.id,
          approvalID: approval.id,
          title: Org2Display.cleanInline(approval.title),
          action: Org2Display.cleanInline(approval.action),
          queueItem: queueItem,
          isSnoozed: queueItem?.isSnoozed(at: now) ?? false
        )
      }
      let isRecent = isWithinRecentWindow(run, now: now)
      let entry = Run(
        id: run.id,
        title: run.displayTitle,
        status: statusBadge(for: run),
        needsUser: !approvals.isEmpty || ["waiting-approval", "blocked", "failed"].contains(run.status),
        approvals: approvals
      )
      if !approvals.isEmpty {
        active.append((entry, run.updatedAt))
      } else if run.isFinished {
        if isRecent { finished.append((entry, run.updatedAt)) }
      } else if run.status == "failed" {
        if isRecent { active.append((entry, run.updatedAt)) }
      } else {
        active.append((entry, run.updatedAt))
      }
    }
    active.sort { lhs, rhs in
      if lhs.run.needsUser != rhs.run.needsUser { return lhs.run.needsUser }
      return lhs.updatedAt == rhs.updatedAt ? lhs.run.id < rhs.run.id : lhs.updatedAt > rhs.updatedAt
    }
    finished.sort { $0.updatedAt == $1.updatedAt ? $0.run.id < $1.run.id : $0.updatedAt > $1.updatedAt }
    return AIChatLinkedRunsSummary(runs: active.map(\.run), recentlyFinished: finished.map(\.run))
  }

  static func statusBadge(for run: AgentRunItem) -> RunBadgePresentation {
    if run.actionablePendingApprovals.count > 0 {
      return RunBadgePresentation(text: "Needs approval", symbol: "hand.raised.fill", tone: .caution)
    }
    switch run.status {
    case "queued": return RunBadgePresentation(text: "Queued", symbol: "clock", tone: .neutral)
    case "running": return RunBadgePresentation(text: "Running", symbol: "play.circle", tone: .neutral)
    case "waiting-approval":
      return RunBadgePresentation(text: "Waiting for approval", symbol: "hand.raised", tone: .caution)
    case "blocked": return RunBadgePresentation(text: "Blocked", symbol: "exclamationmark.circle", tone: .caution)
    case "failed": return RunBadgePresentation(text: "Failed", symbol: "xmark.octagon", tone: .critical)
    case "completed": return RunBadgePresentation(text: "Completed", symbol: "checkmark.circle", tone: .positive)
    case "canceled": return RunBadgePresentation(text: "Canceled", symbol: "minus.circle", tone: .neutral)
    default:
      return RunBadgePresentation(text: AgentRunItem.humanizedLabel(run.status), symbol: "circle.dashed", tone: .neutral)
    }
  }

  private static func isWithinRecentWindow(_ run: AgentRunItem, now: Date) -> Bool {
    let stamp = run.completedAt ?? run.updatedAt
    guard let date = ApprovalItem.parseTimestamp(stamp) ?? ApprovalItem.parseTimestamp(run.updatedAt) else {
      return false
    }
    return now.timeIntervalSince(date) <= recentWindow
  }
}

// MARK: - Store integration

extension WorkspaceStore {
  /// The runs linked to `threadID`, from the cached run projection and the
  /// cached Review queue.
  func aiChatLinkedRunsSummary(for threadID: UUID, now: Date = Date()) -> AIChatLinkedRunsSummary {
    let runIDs = agentRunIDsByLinkedAIChatThreadID[threadID.uuidString.lowercased()] ?? []
    guard !runIDs.isEmpty else { return .empty }
    return AIChatLinkedRunsSummary.make(
      runs: runIDs.compactMap { agentRunsByID[$0] },
      queueItems: approvalItems,
      snoozedQueueItems: snoozedApprovalItems,
      now: now
    )
  }

  /// Opens a chat's run in Agent Work.
  public func openAIChatLinkedRun(_ runID: AgentRunItem.ID) {
    guard let run = agentRunsByID[runID] else { return }
    runsAndReviewPage = .runs
    makeSurfacePrimary(.approvals)
    selectAgentRun(run)
  }

  /// Opens one of a chat's run approvals in Review.
  public func openAIChatLinkedRunApprovalInReview(runID: AgentRunItem.ID, approvalID: String) {
    guard let run = agentRunsByID[runID],
          let approval = run.approvals.first(where: { $0.id == approvalID })
    else { return }
    makeSurfacePrimary(.approvals)
    showApprovalInQueue(run: run, approval: approval)
  }
}

// MARK: - Views

/// Runs the selected chat created, shown above its composer while they are
/// working or need a decision. Approve and Reject use the Review queue's own
/// actions, so Review, Agent Work, and the phone stay in step.
struct AIChatLinkedRunsStrip: View {
  @Environment(WorkspaceStore.self) private var store
  var compact = false

  var body: some View {
    if let threadID = store.selectedAIChatThreadID {
      let summary = store.aiChatLinkedRunsSummary(for: threadID)
      if !summary.isEmpty {
        // Keyed by thread so expanded sections reset when the chat changes.
        AIChatLinkedRunsList(summary: summary, compact: compact)
          .id(threadID)
      }
    }
  }
}

private struct AIChatLinkedRunsList: View {
  let summary: AIChatLinkedRunsSummary
  let compact: Bool
  @State private var showsAllRuns = false
  @State private var showsFinished = false

  private static let collapsedRunLimit = 3

  var body: some View {
    content(summary)
  }

  private func content(_ summary: AIChatLinkedRunsSummary) -> some View {
    let visibleRuns = showsAllRuns ? summary.runs : Array(summary.runs.prefix(Self.collapsedRunLimit))
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Label(headerText(summary), systemImage: "clock.arrow.circlepath")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if summary.runs.count > Self.collapsedRunLimit {
          Button(showsAllRuns ? "Show Fewer" : "Show All \(summary.runs.count)") {
            showsAllRuns.toggle()
          }
          .buttonStyle(.link)
          .font(.caption)
        }
      }
      ForEach(visibleRuns) { run in
        AIChatLinkedRunRow(run: run)
      }
      if !summary.recentlyFinished.isEmpty {
        Button {
          showsFinished.toggle()
        } label: {
          Label(
            finishedText(summary.recentlyFinished.count),
            systemImage: showsFinished ? "chevron.down" : "chevron.right"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ai-chat-linked-runs-finished-toggle")
        if showsFinished {
          ForEach(summary.recentlyFinished) { run in
            AIChatLinkedRunRow(run: run)
          }
        }
      }
    }
    .padding(.horizontal, compact ? 10 : 16)
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ai-chat-linked-runs")
  }

  private func headerText(_ summary: AIChatLinkedRunsSummary) -> String {
    let approvals = summary.pendingApprovalCount
    if approvals > 0 {
      return approvals == 1 ? "Runs from this chat · 1 approval waiting" : "Runs from this chat · \(approvals) approvals waiting"
    }
    if summary.runs.isEmpty { return "Runs from this chat" }
    return summary.runs.count == 1 ? "1 run from this chat" : "\(summary.runs.count) runs from this chat"
  }

  private func finishedText(_ count: Int) -> String {
    count == 1 ? "1 run finished in the last day" : "\(count) runs finished in the last day"
  }
}

private struct AIChatLinkedRunRow: View {
  @Environment(WorkspaceStore.self) private var store
  let run: AIChatLinkedRunsSummary.Run

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        store.openAIChatLinkedRun(run.id)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: run.status.symbol)
            .foregroundStyle(run.status.tone.color)
            .frame(width: 14)
          Text(verbatim: run.title)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(run.status.text)
            .font(.caption)
            .foregroundStyle(run.status.tone.color)
            .lineLimit(1)
          Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open this run in Agent Work")
      .accessibilityLabel("\(run.title), \(run.status.text). Open in Agent Work")

      ForEach(run.approvals) { approval in
        AIChatLinkedRunApprovalRow(approval: approval)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      (run.needsUser ? Color.orange.opacity(0.06) : Color.secondary.opacity(0.06)),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
  }
}

private struct AIChatLinkedRunApprovalRow: View {
  @Environment(WorkspaceStore.self) private var store
  let approval: AIChatLinkedRunsSummary.Approval

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: approval.title)
            .font(.callout.weight(.medium))
            .lineLimit(2)
          if !approval.action.isEmpty {
            Text(verbatim: approval.action)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 22)
        actions
      }
      if let item = approval.queueItem, let error = store.approvalActionError(item) {
        Text(verbatim: error)
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.leading, 22)
          .lineLimit(3)
      }
    }
  }

  @ViewBuilder
  private var actions: some View {
    HStack(spacing: 6) {
      if let item = approval.queueItem {
        let isBusy = store.isApprovalActionInProgress(item)
        if approval.isSnoozed {
          Text("Snoozed")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Button("Reject") { store.promptAndRejectApproval(item) }
          .disabled(isBusy)
          .help("Reject this action, as in Review")
        Button {
          Task { await store.approve(item) }
        } label: {
          if store.isApprovingApproval(item) {
            Text("Approving…")
          } else {
            Text("Approve")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
        .help("Approve this action, as in Review")
      }
      Button {
        store.openAIChatLinkedRunApprovalInReview(runID: approval.runID, approvalID: approval.approvalID)
      } label: {
        Image(systemName: "arrow.up.forward.square")
      }
      .help(approval.queueItem == nil ? "Open in Review to decide" : "Open in Review")
      .accessibilityLabel("Open in Review")
    }
    .controlSize(.small)
  }
}
