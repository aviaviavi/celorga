import AppKit
import SwiftUI

struct RunCenterView: View {
  private static let initialVisibleRunLimit = 250
  private static let visibleRunBatchSize = 250

  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID
  @State private var visibleRunLimit = Self.initialVisibleRunLimit
  @FocusState private var filterFocused: Bool

  var body: some View {
    let visibleEntries = store.agentRunEntries(for: scope)
    let visibleRunIDs = store.agentRunIDs(for: scope)
    let visibleSections = RunCenterPresentation.prefixSections(
      store.agentRunSections(for: scope),
      limit: visibleRunLimit
    )
    let selectedRun = store.selectedAgentRunID.flatMap { id in
      store.isAgentRunVisible(id, in: scope) ? store.agentRun(for: id) : nil
    } ?? visibleSections.first?.entries.first?.run
    VStack(spacing: 0) {
      HeaderBar(title: "Runs", subtitle: "Durable delegated work", surface: .approvals) {
        if store.isLoadingAgentRuns { WorkspaceActivityIndicator(size: .small) }
        Button {
          Task { await store.refreshAgentRuns(updatesStatus: true) }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoadingAgentRuns)
      }

      HStack(spacing: 10) {
        ForEach(AgentRunScope.allCases) { candidate in
          Button {
            store.agentRunSelectionScope = candidate
          } label: {
            RunCenterScopeMetric(
              title: candidate.rawValue,
              count: store.agentRunCount(for: candidate),
              isSelected: scope == candidate
            )
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(candidate.rawValue), \(store.agentRunCount(for: candidate)) runs")
          .accessibilityValue(scope == candidate ? "Selected" : "")
        }
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.top, 12)
      .padding(.bottom, 12)

      RunCenterSearch(filterFocused: $filterFocused)

      Divider()

      if store.isLoadingAgentRuns && store.agentRuns.isEmpty {
        Spacer(); WorkspaceLoadingStateView("Loading agent runs"); Spacer()
      } else if visibleEntries.isEmpty {
        if store.agentRunFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          EmptyStateView(title: "No \(scope.rawValue) Runs", detail: "Runs created by agents, schedules, and workflows appear here automatically.")
        } else {
          EmptyStateView(title: "No Matching Runs", detail: "No \(scope.rawValue.lowercased()) runs match this search.")
        }
      } else {
        WorkspaceLazyCollection {
          ForEach(visibleSections) { section in
            Section {
              ForEach(section.entries) { entry in
                Button {
                  let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                  store.handleAgentRunClick(
                    entry.run,
                    visibleRunIDs: visibleRunIDs,
                    modifiers: modifiers
                  )
                } label: {
                  RunCenterRow(
                    run: entry.run,
                    sourceMeeting: section.sourceMeeting,
                    representedFailureCount: entry.representedFailureCount,
                    isSelected: store.isAgentRunSelectedForAIContext(entry.run)
                  )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                  WorkspaceCollectionRowAccessibilityIdentity.accessibilityIdentifier(
                    kind: "run",
                    id: entry.id
                  )
                )
                .contextMenu {
                  Button {
                    store.startNewAIThreadFromAgentRunSelection(including: entry.run)
                  } label: {
                    Label("Start New AI Thread", systemImage: "sparkles")
                  }
                  Button {
                    store.openAgentRunRecord(entry.run)
                  } label: {
                    Label("View Run Record", systemImage: "doc.text")
                  }
                }
                .workspaceLazyRow(id: entry.id)
              }
            } header: {
              if let sourceMeeting = section.sourceMeeting {
                WorkspaceLazySectionHeader {
                  Label(sourceMeeting.displayTitle, systemImage: "calendar")
                }
              }
            }
          }
          if visibleEntries.count > visibleRunLimit {
            Button {
              visibleRunLimit += Self.visibleRunBatchSize
            } label: {
              let remaining = visibleEntries.count - visibleRunLimit
              Label(
                "Show \(min(Self.visibleRunBatchSize, remaining)) more · \(remaining) remaining",
                systemImage: "ellipsis.circle"
              )
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(WorkspaceCollectionRowAccessibilityIdentity.runShowMore)
            .workspaceLazyRow(id: WorkspaceCollectionRowAccessibilityIdentity.runShowMore)
          }
        }
      }
    }
    .onAppear {
      if let selectedRun {
        performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
          store.selectAgentRun(selectedRun)
        }
      }
      Task { await store.refreshSelectedRunReviewPageIfNeeded() }
    }
    .onChange(of: store.selectedAgentRunID) {
      guard let selectedRun else { return }
      let id = selectedRun.id
      performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
        guard store.selectedAgentRunID == id else { return }
        store.selectAgentRun(selectedRun)
      }
    }
    .onChange(of: store.agentRunSelectionScope) {
      visibleRunLimit = Self.initialVisibleRunLimit
      performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
        store.reconcileAgentRunAIContextSelection(visibleIDs: visibleRunIDs)
        syncVisibleRunSelection(in: visibleEntries)
      }
    }
    .onChange(of: store.agentRunDisplayRevision) {
      visibleRunLimit = Self.initialVisibleRunLimit
      performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
        store.reconcileAgentRunAIContextSelection(visibleIDs: visibleRunIDs)
        syncVisibleRunSelection(in: visibleEntries)
      }
    }
    .onChange(of: store.agentRunFilterFocusToken) {
      filterFocused = true
    }
  }

  private var scope: AgentRunScope {
    store.agentRunSelectionScope
  }

  private func syncVisibleRunSelection(in visibleEntries: [AgentRunScopeEntry]) {
    if let selected = store.selectedAgentRunID,
       !visibleEntries.contains(where: { $0.id == selected }) {
      store.selectedAgentRunID = visibleEntries.first?.id
    }
  }
}

private struct RunCenterSearch: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var draftFilter = ""
  @State private var pendingFilterUpdate: Task<Void, Never>?
  var filterFocused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.tertiary)
      TextField("Search runs", text: $draftFilter)
        .textFieldStyle(.roundedBorder)
        .focused(filterFocused)
        .onChange(of: draftFilter) {
          scheduleFilterUpdate()
        }
        .onSubmit {
          applyFilterImmediately()
          filterFocused.wrappedValue = false
        }
      if !draftFilter.isEmpty {
        Button {
          draftFilter = ""
          applyFilterImmediately()
        } label: {
          Label("Clear", systemImage: "xmark.circle.fill")
        }
        .labelStyle(.iconOnly)
        .help("Clear run search")
      }
    }
    .controlSize(.small)
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
    .onAppear {
      draftFilter = store.agentRunFilter
    }
    .onChange(of: store.agentRunFilter) {
      if draftFilter != store.agentRunFilter {
        draftFilter = store.agentRunFilter
      }
    }
    .onDisappear {
      pendingFilterUpdate?.cancel()
      pendingFilterUpdate = nil
    }
  }

  private func scheduleFilterUpdate() {
    pendingFilterUpdate?.cancel()
    let nextFilter = draftFilter
    guard nextFilter != store.agentRunFilter else { return }
    pendingFilterUpdate = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 120_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      store.agentRunFilter = nextFilter
    }
  }

  private func applyFilterImmediately() {
    pendingFilterUpdate?.cancel()
    pendingFilterUpdate = nil
    if store.agentRunFilter != draftFilter {
      store.agentRunFilter = draftFilter
    }
  }
}

private struct RunCenterScopeMetric: View {
  let title: String
  let count: Int
  let isSelected: Bool
  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(count)")
        .font(.title3.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
      Text(title)
        .font(.caption.weight(.medium))
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.10)
        : isHovered ? Color.accentColor.opacity(0.045) : WorkspaceDesign.panelFill,
      in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
        .stroke(
          isSelected
            ? Color.accentColor.opacity(0.45)
            : isHovered ? Color.accentColor.opacity(0.20) : WorkspaceDesign.hairline
        )
    }
    .contentShape(Rectangle())
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.08)) {
        isHovered = hovering
      }
    }
  }
}

private struct RunCenterRow: View {
  let run: AgentRunItem
  let sourceMeeting: AgentRunContextItem?
  let representedFailureCount: Int
  let isSelected: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        StatusPill(text: run.status)
        if representedFailureCount > 1 {
          Text("Latest of \(representedFailureCount) failed attempts")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if run.parentRunId != nil {
          Text("Outcome")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
        if run.pendingApprovalCount > 0 {
          Label("\(run.pendingApprovalCount)", systemImage: "checkmark.seal")
            .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        }
      }
      Text(run.displayTitle).font(.body.weight(.semibold)).lineLimit(2)
      if run.plan.count > 1 {
        RunSegmentedProgress(plan: run.plan, hasPendingApproval: run.pendingApprovalCount > 0, height: 3)
          .frame(maxWidth: 180)
          .accessibilityHidden(true)
      }
      HStack(spacing: 8) {
        Text(run.progressText)
        if let workflow = run.workflowDisplayName {
          Text("• Workflow: \(workflow)")
        }
        Text("• Updated \(AgentRunTimestampPresentation.displayText(for: run.updatedAt))")
      }
      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
    .workspaceSelectableRow(isSelected: isSelected, verticalPadding: 8)
    .contentShape(Rectangle())
    .accessibilityHint(sourceMeeting.map { "Meeting outcome from \($0.displayTitle)" } ?? "")
  }
}

private enum RunCompletionMode {
  case run
  case external
  case approvalExternal
  case approvalExternalBulk(Int)

  var title: String {
    switch self {
    case .run: "Complete Run"
    case .external: "Mark Done Elsewhere"
    case .approvalExternal: "Mark Approval Done Elsewhere"
    case .approvalExternalBulk(let count): "Mark \(count) Approvals Done Elsewhere"
    }
  }

  var detail: String {
    switch self {
    case .run: "Describe what happened in plain language. This is the first thing people will see when they review the run."
    case .external: "Optionally note where or how the outcome was completed. This closes the Celorga item and retains unresolved approvals and review metadata as history. It does not stop work that may still be running in another system."
    case .approvalExternal: "Optionally note where or how this exact approval action was completed. Only this approval is closed; sibling approvals and the containing run remain open."
    case .approvalExternalBulk(let count): "Optionally note where or how these \(count) approval actions were completed. Each selected approval is closed independently; sibling approvals and containing runs remain open."
    }
  }

  /// Only an in-workflow completion needs an outcome summary. A "Done Elsewhere"
  /// note is optional.
  var requiresSummary: Bool {
    if case .run = self { return true }
    return false
  }

  var actionTitle: String {
    switch self {
    case .run: "Complete Run"
    case .external: "Mark Done Elsewhere"
    case .approvalExternal: "Mark Approval Done Elsewhere"
    case .approvalExternalBulk: "Mark Selected Done Elsewhere"
    }
  }
}

enum RunCenterDetailCollection: String, CaseIterable, Hashable, Sendable {
  case relatedRuns
  case highlights
  case nextActions
  case pendingApprovals
  case retainedApprovals
  case artifacts
  case attentionValidations
  case reviewRequiredArtifacts
  case approvalReviewArtifacts
  case plan
  case acceptanceCriteria
  case latestValidations
  case context
  case comments
}

enum RunCenterDetailCollectionPresentation {
  static let initialItemLimit = 32
  static let pageItemCount = 32

  static func visibleCount(total: Int, requestedLimit: Int?) -> Int {
    min(max(0, total), max(initialItemLimit, requestedLimit ?? initialItemLimit))
  }

  static func nextVisibleCount(total: Int, currentLimit: Int?) -> Int {
    min(
      max(0, total),
      visibleCount(total: total, requestedLimit: currentLimit) + pageItemCount
    )
  }

  static func visiblePendingApprovalIDs(
    _ approvalIDs: [AgentRunApprovalItem.ID],
    selectedID: AgentRunApprovalItem.ID?,
    requestedLimit: Int?
  ) -> [AgentRunApprovalItem.ID] {
    if let selectedID, approvalIDs.contains(selectedID) {
      return [selectedID]
    }
    return Array(approvalIDs.prefix(visibleCount(
      total: approvalIDs.count,
      requestedLimit: requestedLimit
    )))
  }
}

struct RunCenterDetail: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID
  @State private var clarificationResponse = ""
  @State private var clarificationError: String?
  @State private var completionSummary = ""
  @State private var isCompletionPresented = false
  @State private var completionMode: RunCompletionMode = .run
  @State private var isWorkflowConfirmationPresented = false
  @State private var revisionApproval: AgentRunApprovalItem?
  @State private var revisionFeedback = ""
  @State private var openClawApprovalDetails: OpenClawExecApprovalDetails?
  @State private var isLoadingOpenClawApprovalDetails = false
  @State private var openClawApprovalDetailsError: String?
  @State private var collectionDisplayLimits: [RunCenterDetailCollection: Int] = [:]
  let run: AgentRunItem

  private var isMutating: Bool { store.mutatingAgentRunIDs.contains(run.id) }

  var body: some View {
    let sourceMeeting = store.agentRunSourceMeetingContext(for: run.id)
    let relatedRuns = store.relatedAgentRuns(for: run.id)

    ScrollViewReader { scrollProxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 7) {
          HStack(spacing: 8) {
            StatusPill(text: run.status)
            if let attempt = run.attempt {
              Label("Attempt \(attempt.number)", systemImage: "calendar.badge.clock")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .help(attempt.scheduledFor.map { "Scheduled for \($0)" } ?? "Scheduled automation attempt")
            }
            Spacer(minLength: 8)
            runActions
            DetailPaneControlGroup()
          }
          Text(run.displayTitle).font(.title2.weight(.semibold)).textSelection(.enabled)
          runMetaLine
            .help(AgentRunTimestampPresentation.detailText(for: run.updatedAt))
          if let sourceMeeting {
            Button {
              store.openAgentRunContext(sourceMeeting)
            } label: {
              Label("From \(sourceMeeting.displayTitle)", systemImage: "calendar")
                .font(.callout)
            }
            .buttonStyle(.link)
            .help("Open \(sourceMeeting.fileReference ?? sourceMeeting.ref) in Celorga")
          }
        }

        if run.status == "blocked" {
          clarificationSection
        } else if let failure = run.failure {
          Label(failure, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .padding(10)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }

        if run.status == "completed" {
          runSection("Outcome") {
            VStack(alignment: .leading, spacing: 10) {
              Text(run.humanOutcomeSummary)
                .font(.body)
                .textSelection(.enabled)

              if let outcome = run.outcome, !outcome.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                  Text("Highlights").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  ForEach(Array(outcome.highlights
                    .prefix(visibleCount(for: .highlights, total: outcome.highlights.count))
                    .enumerated()), id: \.offset) { _, highlight in
                    Label(highlight, systemImage: "sparkles")
                  }
                  showMoreButton(for: .highlights, total: outcome.highlights.count, noun: "highlights")
                }
              }

              if let outcome = run.outcome, !outcome.nextActions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                  Text("Next actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  ForEach(Array(outcome.nextActions
                    .prefix(visibleCount(for: .nextActions, total: outcome.nextActions.count))
                    .enumerated()), id: \.offset) { _, action in
                    Label(action, systemImage: "arrow.right.circle")
                  }
                  showMoreButton(for: .nextActions, total: outcome.nextActions.count, noun: "next actions")
                }
              } else if run.humanNextAction != nil {
                Label("No action required", systemImage: "checkmark.circle.fill")
                  .font(.callout.weight(.medium))
                  .foregroundStyle(.green)
              }

              if run.outcome == nil {
                Text("This older run did not record a completion summary, so this overview was assembled from its outputs and steps.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        let pending = run.actionablePendingApprovals
        if !pending.isEmpty {
          decisionCard(pending)
        }

        if !run.plan.isEmpty {
          progressSection
        }

        let retainedPending = run.retainedPendingApprovals
        if !retainedPending.isEmpty {
          runSection("Retained approval history") {
            Text("This finished run retained \(retainedPending.count) unresolved approval\(retainedPending.count == 1 ? "" : "s") for audit history. No decision is required, and \(retainedPending.count == 1 ? "it is" : "they are") not shown in Review.")
              .font(.caption)
              .foregroundStyle(.secondary)
            ForEach(retainedPending.prefix(visibleCount(
              for: .retainedApprovals,
              total: retainedPending.count
            ))) { approval in
              VStack(alignment: .leading, spacing: 4) {
                Text(approval.title).font(.body.weight(.semibold))
                Text(approval.action).font(.callout).foregroundStyle(.secondary)
              }
            }
            showMoreButton(
              for: .retainedApprovals,
              total: retainedPending.count,
              noun: "retained approvals"
            )
          }
        }

        // While a decision is pending, the decision card already lists the
        // outputs to review; show them once.
        if !run.artifacts.isEmpty, !(hasPendingDecision && run.openClawExecApprovalID == nil) {
          outputsSection
        }

        // Passing checks live in Technical details; only problems surface here.
        if run.plan.isEmpty, !run.isFinished, !run.attentionValidations.isEmpty {
          flatSection("Checks") { failingChecks }
        }

        if let comment = run.comments.last {
          flatSection("Latest from \(comment.author)") {
            RunHandoffBubble(comment: comment)
          }
        }

        let reviewRequiredArtifacts = run.artifacts.filter { $0.reviewStatus == "review-required" }
        if run.isFinished, !run.attentionValidations.isEmpty || !reviewRequiredArtifacts.isEmpty {
          runSection("Retained workflow history") {
            Text("These signals were unresolved when the run finished. They are retained for audit history and do not put the run back in the review queue.")
              .font(.caption)
              .foregroundStyle(.secondary)
            ForEach(run.attentionValidations.prefix(visibleCount(
              for: .attentionValidations,
              total: run.attentionValidations.count
            ))) { validation in
              Label(
                validation.detail ?? "\(validation.displayName): \(AgentRunItem.humanizedLabel(validation.status))",
                systemImage: "exclamationmark.triangle.fill"
              )
              .foregroundStyle(validation.status == "failed" ? .red : .orange)
            }
            showMoreButton(
              for: .attentionValidations,
              total: run.attentionValidations.count,
              noun: "validation signals"
            )
            ForEach(reviewRequiredArtifacts.prefix(visibleCount(
              for: .reviewRequiredArtifacts,
              total: reviewRequiredArtifacts.count
            ))) { artifact in
              Button { store.openAgentRunArtifact(artifact) } label: {
                Label("Review was still pending for \(artifact.displayTitle)", systemImage: "doc.badge.ellipsis")
              }
              .buttonStyle(.link)
            }
            showMoreButton(
              for: .reviewRequiredArtifacts,
              total: reviewRequiredArtifacts.count,
              noun: "review outputs"
            )
          }
        }

        if !relatedRuns.isEmpty {
          flatSection("Related meeting outcomes") {
            ForEach(relatedRuns.prefix(visibleCount(
              for: .relatedRuns,
              total: relatedRuns.count
            ))) { relatedRun in
              Button {
                store.selectAgentRun(relatedRun)
              } label: {
                HStack(alignment: .top, spacing: 8) {
                  StatusPill(text: relatedRun.status)
                  Text(relatedRun.displayTitle)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.leading)
                  Spacer(minLength: 8)
                  Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                }
              }
              .buttonStyle(.plain)
            }
            showMoreButton(for: .relatedRuns, total: relatedRuns.count, noun: "related outcomes")
          }
        }

          technicalDetails
        }
        .workspaceActionMotion(value: run.actionablePendingApprovals.map(\.id))
        .padding(WorkspaceDesign.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onAppear {
        scrollToSelectedApproval(using: scrollProxy, animated: false)
      }
      .onChange(of: store.selectedApprovalItemID) {
        scrollToSelectedApproval(using: scrollProxy, animated: true)
      }
    }
    .onChange(of: run.id) {
      clarificationResponse = ""
      clarificationError = nil
      completionSummary = ""
      isCompletionPresented = false
      completionMode = .run
      revisionApproval = nil
      revisionFeedback = ""
      openClawApprovalDetails = nil
      openClawApprovalDetailsError = nil
      isLoadingOpenClawApprovalDetails = false
      collectionDisplayLimits.removeAll(keepingCapacity: true)
    }
    .task(id: "\(run.id):\(run.updatedAt)") {
      await loadOpenClawApprovalDetails()
    }
    .sheet(isPresented: $isCompletionPresented) {
      RunCompletionSheet(summary: $completionSummary, mode: completionMode) { summary in
        isCompletionPresented = false
        Task {
          switch completionMode {
          case .run: await store.completeAgentRun(run, summary: summary)
          case .external: await store.completeAgentRunExternally(run, summary: summary)
          case .approvalExternal, .approvalExternalBulk: return
          }
        }
      }
    }
    .sheet(item: $revisionApproval) { approval in
      ApprovalRevisionSheet(
        title: approval.title,
        action: approval.action,
        feedback: $revisionFeedback
      ) { feedback in
        revisionApproval = nil
        Task {
          await store.requestAgentRunChanges(run, approval: approval, feedback: feedback)
        }
      }
    }
    .alert("Create a reusable workflow?", isPresented: $isWorkflowConfirmationPresented) {
      Button("Cancel", role: .cancel) {}
      Button("Create Workflow") { Task { await store.saveAgentRunAsWorkflow(run) } }
    } message: {
      Text("This creates a new reusable workflow definition from this one-off run. It does not rerun, publish, or send anything.")
    }
  }

  // MARK: Visual summary

  private var hasPendingDecision: Bool { !run.actionablePendingApprovals.isEmpty }

  /// One quiet line instead of boxed tiles: who, how risky, how fresh.
  private var runMetaLine: some View {
    let risk = RunDetailPresentation.risk(run.riskClass)
    let agent = RunDetailPresentation.agentName(
      assignee: run.assignee,
      provider: run.provider,
      destinationTitle: run.destinationRef.flatMap { store.aiChatDestination(id: $0)?.title }
    )
    let riskColor: Color = risk.tone == .caution || risk.tone == .critical
      ? risk.tone.color
      : WorkspaceDesign.secondaryText
    return (
      Text(agent).fontWeight(.semibold).foregroundColor(WorkspaceDesign.primaryText)
        + Text("  ·  ")
        + Text(risk.label).foregroundColor(riskColor)
        + Text("  ·  Updated \(AgentRunTimestampPresentation.displayText(for: run.updatedAt))")
    )
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  /// Section without a card: a small label, an optional summary, content.
  private func flatSection<Content: View>(
    _ title: String,
    trailing: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        if let trailing {
          Text(trailing)
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var progressSection: some View {
    flatSection("Progress", trailing: RunDetailPresentation.progressValue(run.plan)) {
      if RunDetailPresentation.usesStepTrack(stepCount: run.plan.count) {
        RunStepTrack(plan: run.plan, hasPendingApproval: hasPendingDecision)
      } else {
        RunSegmentedProgress(plan: run.plan, hasPendingApproval: hasPendingDecision, height: 6)
        VStack(alignment: .leading, spacing: 7) {
          ForEach(run.plan.prefix(visibleCount(for: .plan, total: run.plan.count))) { step in
            let state = RunDetailPresentation.stepState(step, hasPendingApproval: hasPendingDecision)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Image(systemName: state == .upcoming ? "circle" : stepIcon(step.status))
                .foregroundStyle(state.color)
              Text(step.title)
                .font(.callout)
                .foregroundStyle(state == .upcoming ? WorkspaceDesign.secondaryText : WorkspaceDesign.primaryText)
              if state != .done && state != .upcoming {
                Text(state.label)
                  .font(.caption.weight(.medium))
                  .foregroundStyle(state.color)
              }
            }
          }
          showMoreButton(for: .plan, total: run.plan.count, noun: "plan steps")
        }
      }
      if !run.isFinished, !run.attentionValidations.isEmpty {
        failingChecks.padding(.top, 2)
      }
    }
  }

  @ViewBuilder
  private var failingChecks: some View {
    ForEach(run.attentionValidations.prefix(visibleCount(
      for: .attentionValidations,
      total: run.attentionValidations.count
    ))) { validation in
      let badge = RunDetailPresentation.checkBadge(validation.status)
      Label(
        validation.detail ?? "\(validation.displayName): \(badge.text)",
        systemImage: badge.symbol
      )
      .font(.callout)
      .foregroundStyle(badge.tone.color)
      .textSelection(.enabled)
    }
    showMoreButton(
      for: .attentionValidations,
      total: run.attentionValidations.count,
      noun: "validation signals"
    )
  }

  /// The one emphasized card in the pane: what is being asked, what to look
  /// at, and the three answers. Run-level actions stay in the header.
  private func decisionCard(_ pending: [AgentRunApprovalItem]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        Circle().fill(Color.orange).frame(width: 7, height: 7)
        Text("Needs your decision")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
        Spacer(minLength: 8)
        if let count = RunDetailPresentation.approvalCountText(pending: pending.count, total: run.approvals.count) {
          Text(count)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .help("These are the same approvals shown in Review; deciding in either place updates this run record.")

      ForEach(Array(visiblePendingApprovals(pending).enumerated()), id: \.element.id) { index, approval in
        let approvalIsMutating = store.isAgentRunApprovalActionInProgress(
          runID: run.id,
          approvalID: approval.id
        )
        VStack(alignment: .leading, spacing: 12) {
          if index > 0 { Divider() }
          VStack(alignment: .leading, spacing: 4) {
            Text(approval.title)
              .font(.title3.weight(.semibold))
              .textSelection(.enabled)
            Text(approval.action)
              .font(.callout)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          .help([
            approval.requestedFrom.map { "Requested from \($0)" },
            AgentRunTimestampPresentation.displayText(for: approval.requestedAt),
          ].compactMap { $0 }.joined(separator: " · "))

          approvalReviewMaterial(approval)

          HStack(spacing: 8) {
            Button {
              Task { await store.decideAgentRunApproval(run, approval: approval, decision: "approved") }
            } label: {
              if approvalIsMutating {
                HStack(spacing: 6) {
                  WorkspaceActivityIndicator(size: .mini)
                  Text("Working")
                }
              } else {
                Text("Approve")
              }
            }
            .buttonStyle(RunPrimaryButtonStyle(tint: WorkspaceDesign.themed(.done)))
            .disabled(approvalIsMutating || !canApprove(approval))
            .help(canApprove(approval) ? "Approve the displayed action" : "Reviewable action details are required before approval")
            Button("Request Changes…") {
              revisionFeedback = ""
              revisionApproval = approval
            }
            .buttonStyle(RunSecondaryButtonStyle())
            .disabled(approvalIsMutating)
            .help("Describe the changes required and return the work to the agent")
            Button("Reject") { Task { await store.decideAgentRunApproval(run, approval: approval, decision: "rejected") } }
              .buttonStyle(RunSecondaryButtonStyle())
              .disabled(approvalIsMutating)
          }
          .controlSize(.small)
        }
        .id(approval.id)
        .transition(.opacity)
      }
      showMoreButton(for: .pendingApprovals, total: pending.count, noun: "approvals")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
        .fill(WorkspaceDesign.surfaceBackground)
        .overlay(
          RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
            .fill(Color.orange.opacity(0.045))
        )
    }
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous)
        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
    }
  }

  private var outputsSection: some View {
    let reviewCount = run.artifacts.reduce(0) { $0 + ($1.reviewStatus == "review-required" ? 1 : 0) }
    return flatSection(
      "Outputs",
      trailing: reviewCount > 0 && !run.isFinished
        ? "\(reviewCount) need\(reviewCount == 1 ? "s" : "") review"
        : nil
    ) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
        ForEach(run.artifacts.prefix(visibleCount(
          for: .artifacts,
          total: run.artifacts.count
        ))) { artifact in
          RunOutputTile(artifact: artifact, runFinished: run.isFinished) {
            store.openAgentRunArtifact(artifact)
          }
        }
      }
      showMoreButton(for: .artifacts, total: run.artifacts.count, noun: "outputs")
    }
  }

  @ViewBuilder
  private func approvalReviewMaterial(_ approval: AgentRunApprovalItem) -> some View {
    if let note = approval.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty,
       !RunDetailPresentation.approvalNoteRepeatsAction(note: note, action: approval.action) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Approval details").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text(note).font(.callout).textSelection(.enabled)
      }
    }

    if run.openClawExecApprovalID != nil {
      if isLoadingOpenClawApprovalDetails {
        HStack(spacing: 7) {
          WorkspaceActivityIndicator(size: .mini)
          Text("Loading the exact action from OpenClaw…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } else if let details = openClawApprovalDetails {
        VStack(alignment: .leading, spacing: 7) {
          Text("Exact action to approve")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(details.reviewText)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))

          if let preview = details.commandPreview?.trimmingCharacters(in: .whitespacesAndNewlines),
             !preview.isEmpty,
             preview != details.commandText {
            DisclosureGroup("Raw command") {
              Text(details.commandText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.top, 5)
            }
            .font(.caption)
          }

          let metadata = [
            details.host.map { "Host: \($0)" },
            details.agentID.map { "Agent: \($0)" },
          ].compactMap { $0 }
          if !metadata.isEmpty {
            Text(metadata.joined(separator: " · "))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } else {
        Label(
          "The exact OpenClaw action is unavailable, so approval is disabled. Retry after the Gateway is reachable or reject this request.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout)
        .foregroundStyle(.orange)
        if let error = openClawApprovalDetailsError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    } else if !run.artifacts.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(run.artifacts.prefix(visibleCount(
          for: .approvalReviewArtifacts,
          total: run.artifacts.count
        ))) { artifact in
          RunOutputTile(artifact: artifact, runFinished: run.isFinished, compact: true, showsReviewBadge: false) {
            store.openAgentRunArtifact(artifact)
          }
        }
        showMoreButton(
          for: .approvalReviewArtifacts,
          total: run.artifacts.count,
          noun: "review outputs"
        )
      }
    } else if requiresReviewMaterial(approval),
              approval.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
      Label(
        "No recipient, content, command, or reviewable output was attached. Approval is disabled.",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.callout)
      .foregroundStyle(.orange)
    }
  }

  private func requiresReviewMaterial(_ approval: AgentRunApprovalItem) -> Bool {
    approval.riskClass == "external-action" || approval.riskClass == "high-impact"
  }

  private func canApprove(_ approval: AgentRunApprovalItem) -> Bool {
    guard requiresReviewMaterial(approval) else { return true }
    if run.openClawExecApprovalID != nil { return openClawApprovalDetails != nil }
    if approval.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
    return !run.artifacts.isEmpty
  }

  private func scrollToSelectedApproval(
    using proxy: ScrollViewProxy,
    animated: Bool
  ) {
    guard let approvalID = RunCenterPresentation.approvalID(
      selectedApprovalItemID: store.selectedApprovalItemID,
      runID: run.id
    ), run.actionablePendingApprovals.contains(where: { $0.id == approvalID }) else {
      return
    }
    performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
      guard RunCenterPresentation.approvalID(
        selectedApprovalItemID: store.selectedApprovalItemID,
        runID: run.id
      ) == approvalID else { return }
      if animated {
        withAnimation(WorkspaceMotion.quick) {
          proxy.scrollTo(approvalID, anchor: .top)
        }
      } else {
        proxy.scrollTo(approvalID, anchor: .top)
      }
    }
  }

  @MainActor
  private func loadOpenClawApprovalDetails() async {
    openClawApprovalDetails = nil
    openClawApprovalDetailsError = nil
    guard run.pendingApprovalCount > 0, run.openClawExecApprovalID != nil else {
      isLoadingOpenClawApprovalDetails = false
      return
    }
    isLoadingOpenClawApprovalDetails = true
    do {
      let details = try await store.openClawExecApprovalDetails(for: run)
      guard !Task.isCancelled else { return }
      openClawApprovalDetails = details
    } catch {
      guard !Task.isCancelled else { return }
      openClawApprovalDetailsError = error.localizedDescription
    }
    isLoadingOpenClawApprovalDetails = false
  }

  private var clarificationSection: some View {
    runSection(run.clarificationPrompt == nil ? "Clarification missing" : "Clarification needed") {
      VStack(alignment: .leading, spacing: 10) {
        if let prompt = run.clarificationPrompt {
          Label(prompt, systemImage: "questionmark.bubble.fill")
            .foregroundStyle(.orange)
        } else {
          Label("The agent blocked this run without recording a specific question.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text("Tell it how to proceed below. Future runs must record an actionable clarification before entering the blocked state.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        TextField("Your response or direction", text: $clarificationResponse, axis: .vertical)
          .lineLimit(2...5)
          .disabled(clarificationPhase != nil)

        Button {
          let response = clarificationResponse
          Task {
            clarificationError = nil
            if await store.respondToAgentRunClarification(run, response: response) {
              clarificationResponse = ""
            } else {
              clarificationError = store.errorText ?? "The response could not be recorded or delivered."
            }
          }
        } label: {
          if let clarificationPhase {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .small)
              Text(clarificationPhase.buttonTitle)
            }
          } else {
            Label("Reply & Resume", systemImage: "paperplane.fill")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(
          isMutating
            || WorkspaceStore.normalizedAgentRunClarificationResponse(clarificationResponse) == nil
        )

        if let clarificationPhase {
          clarificationProgressBanner(clarificationPhase)
            .transition(.opacity)
        }

        if let clarificationError {
          Label(clarificationError, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
    }
  }

  private var clarificationPhase: AgentRunClarificationReplyPhase? {
    store.agentRunClarificationPhases[run.id]
  }

  private func clarificationProgressBanner(_ phase: AgentRunClarificationReplyPhase) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 10) {
        WorkspaceActivityIndicator(size: .regular)
        VStack(alignment: .leading, spacing: 2) {
          Text(phase.title)
            .font(.headline)
          Text(phase.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Text(phase.stepLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      ProgressView()
        .progressViewStyle(.linear)
        .controlSize(.small)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(phase.title) \(phase.stepLabel)")
    .animation(WorkspaceMotion.quick, value: phase)
  }

  /// Header actions. At most one primary run action is visible at a time; a
  /// pending decision is answered in its card, so Complete moves to the menu.
  private var runActions: some View {
    let canComplete = run.status == "running"
    let canCancel = ["queued", "running", "waiting-approval", "blocked"].contains(run.status)
    return HStack(spacing: 4) {
      if isMutating { WorkspaceActivityIndicator(size: .mini) }
      if run.status == "queued" { actionButton("Start", "play.fill", "start") }
      if run.status == "blocked" {
        if run.revisionAwaitingHandoff != nil {
          Button {
            Task { await store.continueRequestedRevision(run) }
          } label: {
            Label("Send Requested Changes", systemImage: "arrow.uturn.forward")
          }
          .buttonStyle(WorkspaceActionButtonStyle())
          .disabled(isMutating)
          .help("Resume this run and send your requested changes to an agent, which will request a new approval")
        } else {
          actionButton("Resume", "play.fill", "resume")
        }
      }
      if run.canContinueApprovedWork {
        Button {
          Task { await store.continueApprovedAgentRun(run) }
        } label: {
          Label(
            run.hasApprovedProviderDraftBoundary ? "Send Approved Draft" : "Continue Approved Work",
            systemImage: "paperplane.fill"
          )
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(isMutating)
        .help("Continue this run using only the actions already approved in its current review boundary")
      }
      if run.status == "failed" || run.status == "canceled" { actionButton("Retry", "arrow.clockwise", "retry") }
      if canComplete && !hasPendingDecision {
        Button {
          completionMode = .run
          isCompletionPresented = true
        } label: { Label("Complete…", systemImage: "checkmark.circle") }
          .buttonStyle(WorkspaceActionButtonStyle())
          .disabled(isMutating)
      }
      Button { store.askAIChatAboutAgentRun(run) } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .help("Start a chat with this durable run record as context")
      Menu {
        if canComplete && hasPendingDecision {
          Button("Complete Run…") {
            completionMode = .run
            isCompletionPresented = true
          }
        }
        if run.canMarkDoneElsewhere {
          Button("Mark Done Elsewhere…") {
            completionMode = .external
            isCompletionPresented = true
          }
        }
        if run.status == "failed" {
          Button("Dismiss Failure") { Task { await store.mutateAgentRun(run, action: "cancel") } }
        }
        if run.status == "completed" && run.workflowId == nil {
          Button("Create Reusable Workflow…") { isWorkflowConfirmationPresented = true }
        }
        Divider()
        if let approval = run.actionablePendingApprovals.first {
          Button("Show Decision in Review") { store.showApprovalInQueue(run: run, approval: approval) }
        }
        Button("View Run Record") { store.openAgentRunRecord(run) }
        if canCancel {
          Divider()
          Button("Cancel Run", role: .destructive) { Task { await store.mutateAgentRun(run, action: "cancel") } }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(WorkspaceDesign.secondaryText)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .tint(WorkspaceDesign.secondaryText)
      .fixedSize()
      .disabled(isMutating)
      .help("More run actions")
    }
    .controlSize(.small)
  }

  private func actionButton(_ title: String, _ image: String, _ action: String) -> some View {
    Button { Task { await store.mutateAgentRun(run, action: action) } } label: { Label(title, systemImage: image) }
      .buttonStyle(WorkspaceActionButtonStyle()).disabled(isMutating)
  }

  private func visibleCount(
    for collection: RunCenterDetailCollection,
    total: Int
  ) -> Int {
    RunCenterDetailCollectionPresentation.visibleCount(
      total: total,
      requestedLimit: collectionDisplayLimits[collection]
    )
  }

  private func visiblePendingApprovals(
    _ approvals: [AgentRunApprovalItem]
  ) -> [AgentRunApprovalItem] {
    let selectedID = store.runsAndReviewPage == .review
      ? RunCenterPresentation.approvalID(
          selectedApprovalItemID: store.selectedApprovalItemID,
          runID: run.id
        )
      : nil
    let visibleIDs = Set(RunCenterDetailCollectionPresentation.visiblePendingApprovalIDs(
      approvals.map(\.id),
      selectedID: selectedID,
      requestedLimit: collectionDisplayLimits[.pendingApprovals]
    ))
    return approvals.filter { visibleIDs.contains($0.id) }
  }

  @ViewBuilder
  private func showMoreButton(
    for collection: RunCenterDetailCollection,
    total: Int,
    noun: String
  ) -> some View {
    let current = visibleCount(for: collection, total: total)
    if current < total {
      let next = RunCenterDetailCollectionPresentation.nextVisibleCount(
        total: total,
        currentLimit: collectionDisplayLimits[collection]
      )
      Button {
        collectionDisplayLimits[collection] = next
      } label: {
        Label("Show \(next - current) more \(noun)", systemImage: "ellipsis.circle")
      }
      .buttonStyle(.plain)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
    }
  }

  private var technicalDetails: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 16) {
        if !run.acceptanceCriteria.isEmpty {
          technicalGroup("Acceptance criteria") {
            ForEach(Array(run.acceptanceCriteria
              .prefix(visibleCount(
                for: .acceptanceCriteria,
                total: run.acceptanceCriteria.count
              ))
              .enumerated()), id: \.offset) { _, criterion in
              Label(criterion, systemImage: "checkmark")
            }
            showMoreButton(
              for: .acceptanceCriteria,
              total: run.acceptanceCriteria.count,
              noun: "criteria"
            )
          }
        }

        if !run.context.isEmpty {
          technicalGroup("Cited context") {
            ForEach(Array(run.context
              .prefix(visibleCount(for: .context, total: run.context.count))
              .enumerated()), id: \.offset) { _, item in
              Text(item.citation ?? item.ref).font(.callout.monospaced()).textSelection(.enabled)
            }
            showMoreButton(for: .context, total: run.context.count, noun: "context items")
          }
        }

        if !run.comments.isEmpty {
          technicalGroup("Handoff and comments") {
            ForEach(run.comments.prefix(visibleCount(for: .comments, total: run.comments.count))) { comment in
              VStack(alignment: .leading) {
                Text(comment.author).font(.caption.weight(.semibold))
                Text(comment.body)
              }
            }
            showMoreButton(for: .comments, total: run.comments.count, noun: "comments")
          }
        }

        if !run.latestValidations.isEmpty {
          technicalGroup("Checks") {
            ForEach(run.latestValidations.prefix(visibleCount(
              for: .latestValidations,
              total: run.latestValidations.count
            ))) { validation in
              let badge = RunDetailPresentation.checkBadge(validation.status)
              Label("\(validation.displayName): \(badge.text)", systemImage: badge.symbol)
                .foregroundStyle(badge.tone.color)
                .help(validation.detail ?? badge.text)
            }
            showMoreButton(
              for: .latestValidations,
              total: run.latestValidations.count,
              noun: "validation results"
            )
          }
        }

        technicalGroup("Run details") {
          if let workflow = run.workflowDisplayName {
            Text("Workflow: \(workflow)\(run.workflowVersion.map { " v\($0)" } ?? "")")
          }
          if let elapsed = RunDetailPresentation.elapsedText(start: run.startedAt, end: run.completedAt ?? run.updatedAt) {
            Text("Active time: \(elapsed)")
          }
          if let destinationRef = run.destinationRef {
            Text("Destination: \(store.aiChatDestination(id: destinationRef)?.title ?? destinationRef)")
          }
          Text("Risk: \(AgentRunItem.humanizedLabel(run.riskClass))")
          if let assignee = run.assignee { Text("Assignee: \(assignee)") }
          if let agentRef = run.agentRef { Text("Agent ref: \(agentRef)").textSelection(.enabled) }
          if let goalRef = run.goalRef { Text("Goal ref: \(goalRef)").textSelection(.enabled) }
          Text("Run ID: \(run.id)").textSelection(.enabled)
        }
      }
      .padding(.top, 10)
    } label: {
      Text("Technical details")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .padding(.top, 10)
    .overlay(alignment: .top) { Divider() }
  }

  private func technicalGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      content()
    }
  }

  private func stepIcon(_ status: String) -> String {
    switch status {
    case "completed": return "checkmark.circle.fill"
    case "failed": return "xmark.circle.fill"
    case "running": return "play.circle.fill"
    case "skipped": return "minus.circle"
    case "blocked": return "exclamationmark.circle.fill"
    default: return "circle"
    }
  }

  private func runSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.headline)
      content()
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .workspaceCardSurface()
  }
}

private struct RunCompletionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var summary: String
  let mode: RunCompletionMode
  let complete: (String) -> Void

  private var normalizedSummary: String {
    summary.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(mode.title).font(.title2.weight(.semibold))
      Text(mode.detail)
        .foregroundStyle(.secondary)
      TextField(mode.requiresSummary ? "Outcome summary" : "Note (optional)", text: $summary, axis: .vertical)
        .lineLimit(3...7)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(mode.actionTitle) { complete(normalizedSummary) }
          .keyboardShortcut(.defaultAction)
          .disabled(mode.requiresSummary && normalizedSummary.isEmpty)
      }
    }
    .padding(22)
    .frame(width: 520)
  }
}

struct ApprovalsView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID
  @FocusState private var filterFocused: Bool
  @State private var discussionItem: ApprovalItem?
  @State private var discussionMessage = "I need to discuss this approval item before deciding."
  @State private var revisionItem: ApprovalItem?
  @State private var revisionFeedback = ""
  @State private var externalCompletionItem: ApprovalItem?
  @State private var externalCompletionSummary = ""
  @State private var bulkExternalCompletionPresented = false
  @State private var bulkExternalCompletionSummary = ""
  @State private var bulkRejectionPresented = false
  @State private var bulkRejectionReason = ""
  @State private var bulkRejectionEndStatus: TodoEditStatus = .canceled
  @State private var snoozeDateRequest: ApprovalSnoozeDateRequest?

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Approvals", subtitle: headerSubtitle, surface: .approvals) {
        if store.isLoadingApprovals {
          WorkspaceActivityIndicator(size: .small)
        }
        Button {
          Task { await store.refreshApprovals(updatesStatus: true) }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoadingApprovals)
      }

      HStack(spacing: 10) {
        ApprovalControls(filterFocused: $filterFocused)
        Picker("Queue", selection: Binding(
          get: { store.showsSnoozedApprovals },
          set: { store.showsSnoozedApprovals = $0 }
        )) {
          Text("Pending").tag(false)
          Text(store.snoozedApprovalItems.isEmpty ? "Snoozed" : "Snoozed (\(store.snoozedApprovalItems.count))").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Snoozed approvals stay pending and return on their own when the snooze ends")
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 10)

      Divider()

      if store.hasBulkApprovalSelection {
        ApprovalBulkActionBar(
          pickSnoozeDate: {
            let selected = store.visibleApprovalItems.filter { store.isApprovalItemBulkSelected($0) }
            snoozeDateRequest = ApprovalSnoozeDateRequest(
              item: nil,
              allowsTime: !selected.isEmpty && selected.allSatisfy(\.supportsTimedSnooze)
            )
          },
          markDoneElsewhere: {
            bulkExternalCompletionSummary = ""
            bulkExternalCompletionPresented = true
          },
          reject: {
            bulkRejectionReason = ""
            bulkRejectionEndStatus = .canceled
            bulkRejectionPresented = true
          }
        )
      }

      approvalList
        .workspaceActionMotion(value: store.approvalItems.map(\.id))
    }
    .sheet(item: $discussionItem) { item in
      ApprovalDiscussionSheet(
        item: item,
        message: $discussionMessage,
        discuss: { message, threadMode in
          discussionItem = nil
          Task { await store.discussApprovalInAIChat(item, message: message, threadMode: threadMode) }
        }
      )
        .environment(store)
    }
    .sheet(item: $revisionItem) { item in
      ApprovalRevisionSheet(
        title: item.title,
        action: item.action ?? item.body,
        feedback: $revisionFeedback
      ) { feedback in
        revisionItem = nil
        Task { await store.requestChanges(item, feedback: feedback) }
      }
    }
    .sheet(item: $externalCompletionItem) { item in
      RunCompletionSheet(
        summary: $externalCompletionSummary,
        mode: .approvalExternal
      ) { summary in
        externalCompletionItem = nil
        Task { await store.completeApprovalExternally(item, summary: summary) }
      }
    }
    .sheet(isPresented: $bulkExternalCompletionPresented) {
      RunCompletionSheet(
        summary: $bulkExternalCompletionSummary,
        mode: .approvalExternalBulk(store.bulkApprovalSelectionCount)
      ) { summary in
        bulkExternalCompletionPresented = false
        Task { await store.completeSelectedApprovalsExternally(summary: summary) }
      }
    }
    .sheet(item: $snoozeDateRequest) { request in
      ApprovalSnoozeDateSheet(allowsTime: request.allowsTime) { until in
        snoozeDateRequest = nil
        if let item = request.item {
          Task { await store.snoozeApproval(item, until: until) }
        } else {
          Task { await store.snoozeSelectedApprovals(until: until) }
        }
      }
    }
    .sheet(isPresented: $bulkRejectionPresented) {
      BulkApprovalRejectionSheet(
        count: store.bulkApprovalSelectionCount,
        reason: $bulkRejectionReason,
        endStatus: $bulkRejectionEndStatus
      ) { endStatus, reason in
        bulkRejectionPresented = false
        Task { await store.rejectSelectedApprovals(endStatus: endStatus, reason: reason) }
      }
    }
    .onAppear {
      Task { await store.refreshSelectedRunReviewPageIfNeeded() }
    }
    .onChange(of: store.selectedApprovalItemID) {
      guard let id = store.selectedApprovalItemID,
            let item = store.visibleApprovalItems.first(where: { $0.id == id })
      else {
        return
      }
      performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
        guard store.selectedApprovalItemID == id else { return }
        store.selectApprovalItem(item)
      }
    }
    .onChange(of: store.visibleApprovalItems.map(\.id)) { _, ids in
      store.reconcileApprovalAIContextSelection(visibleIDs: ids)
    }
    .onChange(of: store.approvalFilterFocusToken) {
      filterFocused = true
    }
    .onChange(of: filterFocused, initial: true) { _, focused in
      store.isApprovalFilterFieldFocused = focused
    }
    .onDisappear {
      store.isApprovalFilterFieldFocused = false
    }
  }

  private var headerSubtitle: String {
    let count = store.visibleApprovalItems.count
    if store.showsSnoozedApprovals {
      return "\(count) snoozed approval\(count == 1 ? "" : "s")"
    }
    let snoozed = store.snoozedApprovalItems.count
    let snoozedSuffix = snoozed == 0 ? "" : " · \(snoozed) snoozed"
    let total = store.approvalItems.count
    if !store.approvalFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, total > count {
      return "\(count) of \(total) pending\(snoozedSuffix)"
    }
    return "\(count) pending approval\(count == 1 ? "" : "s")\(snoozedSuffix)"
  }

  @ViewBuilder
  private var approvalList: some View {
    if let error = store.approvalLoadErrorText, store.approvalItems.isEmpty {
      EmptyStateView(title: "Approvals Failed", detail: error, action: "Refresh") {
        Task { await store.refreshApprovals(updatesStatus: true) }
      }
    } else if store.shouldShowInitialApprovalsLoadingState {
      Spacer()
      WorkspaceLoadingStateView("Loading approvals")
      Spacer()
    } else if store.visibleApprovalItems.isEmpty {
      if store.showsSnoozedApprovals,
         store.approvalFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        EmptyStateView(title: "Nothing Snoozed", detail: "Snoozed approvals wait here until their time comes, then return to Pending.")
      } else if store.approvalFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        EmptyStateView(title: "No Approvals", detail: "No pending approval candidates matched.", action: "Refresh") {
          Task { await store.refreshApprovals(updatesStatus: true) }
        }
      } else {
        EmptyStateView(title: "No Matching Approvals", detail: "No pending approvals match this search.")
      }
    } else {
      WorkspaceLazyCollection {
        ForEach(store.visibleApprovalItems) { item in
          ApprovalRow(
            item: item,
            sourceReference: item.isRunApproval ? item.sourceLabel : "\(store.relativePath(item.file)):\(item.line)",
            isSelected: store.isApprovalItemSelectedForAIContext(item),
            isBulkSelected: store.isApprovalItemBulkSelected(item),
            isApproving: store.isApprovingApproval(item),
            isRejecting: store.isRejectingApproval(item),
            isCompletingExternally: store.isCompletingApprovalExternally(item),
            isRepairingSource: store.isRepairingApprovalSource(item),
            isSnoozing: store.isSnoozingApproval(item),
            actionError: store.approvalActionError(item),
            toggleBulkSelection: { store.toggleApprovalItemBulkSelection(item) },
            approve: { Task { await store.approve(item) } },
            snooze: { option in Task { await store.snoozeApproval(item, option: option) } },
            pickSnoozeDate: {
              snoozeDateRequest = ApprovalSnoozeDateRequest(item: item, allowsTime: item.supportsTimedSnooze)
            },
            wake: { Task { await store.wakeApproval(item) } },
            markDoneElsewhere: {
              externalCompletionSummary = ""
              externalCompletionItem = item
            },
            requestChanges: item.isRunApproval ? {
              revisionFeedback = ""
              revisionItem = item
            } : nil,
            reject: { store.promptAndRejectApproval(item) },
            copy: { store.copyApprovalDiscussionText(item) },
            repairSource: repairSourceAction(for: item),
            discuss: {
              discussionMessage = "I need to discuss this approval item before deciding."
              discussionItem = item
            }
          )
          .transition(.opacity)
          .contentShape(Rectangle())
          .onTapGesture {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            filterFocused = false
            WorkspaceTextInputFocus.resignActiveTextInput()
            selectApprovalItem(item, modifiers: modifiers)
          }
          .workspaceAccessibleCollectionRow(
            kind: "approval",
            id: item.id,
            label: Org2Display.cleanInline(item.title),
            isSelected: store.isApprovalItemSelectedForAIContext(item),
            open: { selectApprovalItem(item) }
          )
          .contextMenu {
            if item.isRunApproval {
              Button {
                store.selectApprovalItem(item)
              } label: {
                Label("Open Run", systemImage: "clock.arrow.circlepath")
              }
            } else {
              WorkspaceLocationContextMenu(
                location: .agenda(item.agendaItem()),
                showsHeadingActions: true,
                showsAIThreadAction: false,
                select: { store.selectApprovalItem(item) }
              ) {
                Label("Open", systemImage: "checkmark.seal")
              }
            }
            Divider()
            Button {
              store.startNewAIThreadFromApprovalSelection(including: item)
            } label: {
              Label("Start New AI Thread", systemImage: "sparkles")
            }
            Divider()
            Button {
              store.toggleApprovalItemBulkSelection(item)
            } label: {
              Label(
                store.isApprovalItemBulkSelected(item) ? "Remove from Selection" : "Add to Selection",
                systemImage: store.isApprovalItemBulkSelected(item) ? "checkmark.square.fill" : "square"
              )
            }
            Button {
              Task { await store.approve(item) }
            } label: {
              Label("Approve", systemImage: "checkmark")
            }
            .disabled(store.isApprovalActionInProgress(item))
            if item.isSnoozed() {
              Button {
                Task { await store.wakeApproval(item) }
              } label: {
                Label("Wake Now", systemImage: "alarm")
              }
              .disabled(store.isApprovalActionInProgress(item))
            }
            Menu {
              ApprovalSnoozeMenuContent(
                allowsTime: item.supportsTimedSnooze,
                snooze: { option in Task { await store.snoozeApproval(item, option: option) } },
                pickDate: {
                  snoozeDateRequest = ApprovalSnoozeDateRequest(item: item, allowsTime: item.supportsTimedSnooze)
                }
              )
            } label: {
              Label(item.isSnoozed() ? "Snooze Again" : "Snooze", systemImage: "moon.zzz")
            }
            .disabled(store.isApprovalActionInProgress(item))
            Button {
              externalCompletionSummary = ""
              externalCompletionItem = item
            } label: {
              Label("Mark Done Elsewhere…", systemImage: "checkmark.circle")
            }
            .disabled(store.isApprovalActionInProgress(item))
            if item.isRunApproval {
              Button {
                revisionFeedback = ""
                revisionItem = item
              } label: {
                Label("Request Changes…", systemImage: "arrow.uturn.backward")
              }
              .disabled(store.isApprovalActionInProgress(item))
            }
            Button {
              store.promptAndRejectApproval(item)
            } label: {
              Label("Reject…", systemImage: "xmark.octagon")
            }
            .disabled(store.isApprovalActionInProgress(item))
            Divider()
            Button {
              discussionMessage = "I need to discuss this approval item before deciding."
              discussionItem = item
            } label: {
              Label("Discuss in AI Chat…", systemImage: "paperplane")
            }
            Button {
              store.copyApprovalDiscussionText(item)
            } label: {
              Label("Copy Discussion Text", systemImage: "doc.on.doc")
            }
          }
          .workspaceLazyRow(id: item.id)
        }
      }
    }
  }

  private func selectApprovalItem(
    _ item: ApprovalItem,
    modifiers: NSEvent.ModifierFlags = []
  ) {
    store.handleApprovalItemClick(item, modifiers: modifiers)
  }

  private func repairSourceAction(for item: ApprovalItem) -> (() -> Void)? {
    guard store.canRepairApprovalSource(item) else { return nil }
    return {
      Task { await store.repairApprovalSourceAndRetry(item) }
    }
  }
}

private struct ApprovalControls: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var filterDraft = ""
  @State private var pendingFilterUpdate: Task<Void, Never>?
  var filterFocused: FocusState<Bool>.Binding

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.tertiary)
      TextField("Search approvals", text: $filterDraft)
        .textFieldStyle(.roundedBorder)
        .focused(filterFocused)
        .onChange(of: filterDraft) { scheduleFilterUpdate() }
        .onSubmit {
          applyFilterImmediately()
          filterFocused.wrappedValue = false
        }
      if !filterDraft.isEmpty {
        Button {
          filterDraft = ""
          store.clearApprovalFilter()
        } label: {
          Label("Clear", systemImage: "xmark.circle.fill")
        }
        .labelStyle(.iconOnly)
        .help("Clear approval search")
      }
    }
    .controlSize(.small)
    .onAppear { filterDraft = store.approvalFilter }
    .onChange(of: store.approvalFilter) {
      if filterDraft != store.approvalFilter {
        filterDraft = store.approvalFilter
      }
    }
    .onDisappear { pendingFilterUpdate?.cancel() }
  }

  private func scheduleFilterUpdate() {
    pendingFilterUpdate?.cancel()
    let nextFilter = filterDraft
    guard nextFilter != store.approvalFilter else { return }
    pendingFilterUpdate = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
      guard !Task.isCancelled else { return }
      store.approvalFilter = nextFilter
    }
  }

  private func applyFilterImmediately() {
    pendingFilterUpdate?.cancel()
    pendingFilterUpdate = nil
    if store.approvalFilter != filterDraft {
      store.approvalFilter = filterDraft
    }
  }
}

private struct ApprovalBulkActionBar: View {
  @Environment(WorkspaceStore.self) private var store
  let pickSnoozeDate: () -> Void
  let markDoneElsewhere: () -> Void
  let reject: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Label("\(store.bulkApprovalSelectionCount) selected", systemImage: "checkmark.square")
        .font(.callout.weight(.semibold))
        .monospacedDigit()

      Spacer(minLength: 0)

      Button {
        store.selectAllVisibleApprovalItemsForBulkAction()
      } label: {
        Label("Select Visible", systemImage: "checkmark.square")
      }
      .disabled(store.visibleApprovalItems.isEmpty)

      Button {
        Task { await store.approveSelectedApprovals() }
      } label: {
        Label("Approve", systemImage: "checkmark.seal")
      }

      if store.showsSnoozedApprovals {
        Button {
          Task { await store.wakeSelectedApprovals() }
        } label: {
          Label("Wake", systemImage: "alarm")
        }
      }

      Menu {
        ApprovalSnoozeMenuContent(
          allowsTime: store.visibleApprovalItems
            .filter { store.isApprovalItemBulkSelected($0) }
            .allSatisfy(\.supportsTimedSnooze),
          snooze: { option in Task { await store.snoozeSelectedApprovals(until: option.wakeDate()) } },
          pickDate: pickSnoozeDate
        )
      } label: {
        Label("Snooze", systemImage: "moon.zzz")
      }
      .fixedSize()

      Button {
        markDoneElsewhere()
      } label: {
        Label("Done Elsewhere…", systemImage: "checkmark.circle")
      }

      Button {
        reject()
      } label: {
        Label("Reject…", systemImage: "xmark.octagon")
      }

      Button {
        store.clearApprovalBulkSelection()
      } label: {
        Label("Clear", systemImage: "xmark.circle")
      }
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.panelFill)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

private struct BulkApprovalRejectionSheet: View {
  @Environment(\.dismiss) private var dismiss
  let count: Int
  @Binding var reason: String
  @Binding var endStatus: TodoEditStatus
  let reject: (TodoEditStatus, String) -> Void

  private var normalizedReason: String {
    reason.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Reject \(count) Approvals").font(.title2.weight(.semibold))
      Text("An optional reason is recorded on every selected approval. Standalone approval headings use the chosen final TODO state; run-backed approvals are rejected through their canonical run records.")
        .foregroundStyle(.secondary)

      Picker("Final standalone TODO state", selection: $endStatus) {
        Text("Canceled").tag(TodoEditStatus.canceled)
        Text("Done").tag(TodoEditStatus.done)
      }

      TextField("Rejection reason (optional)", text: $reason, axis: .vertical)
        .lineLimit(3...7)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Reject Selected") { reject(endStatus, normalizedReason) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 560)
  }
}

private struct ApprovalRow: View {
  let item: ApprovalItem
  let sourceReference: String
  let isSelected: Bool
  let isBulkSelected: Bool
  let isApproving: Bool
  let isRejecting: Bool
  let isCompletingExternally: Bool
  let isRepairingSource: Bool
  let isSnoozing: Bool
  let actionError: String?
  let toggleBulkSelection: () -> Void
  let approve: () -> Void
  let snooze: (ApprovalSnoozeOption) -> Void
  let pickSnoozeDate: () -> Void
  let wake: () -> Void
  let markDoneElsewhere: () -> Void
  let requestChanges: (() -> Void)?
  let reject: () -> Void
  let copy: () -> Void
  let repairSource: (() -> Void)?
  let discuss: () -> Void

  @State private var isHovered = false

  private var isActionInProgress: Bool {
    isApproving || isRejecting || isCompletingExternally || isRepairingSource || isSnoozing
  }

  /// Full actions only on the row being reviewed; hover gets a compact
  /// cluster that does not change the row height. Every action is also in
  /// the context menu and the bulk bar.
  private var showsActionBar: Bool { isSelected || isActionInProgress }

  var body: some View {
    let summary = item.listSummary
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .center, spacing: 8) {
        Button {
          toggleBulkSelection()
        } label: {
          AgendaBulkSelectionCheckbox(isChecked: isBulkSelected, isEnabled: true)
        }
        .buttonStyle(.plain)
        .opacity(isBulkSelected || isHovered || isSelected ? 1 : 0.45)
        .accessibilityLabel(isBulkSelected ? "Remove from bulk selection" : "Add to bulk selection")
        .help(isBulkSelected ? "Remove from bulk selection" : "Add to bulk selection")

        if item.isUrgent {
          StatusPill(text: "urgent")
        }
        if let todo = item.todo {
          StatusPill(text: todo)
        } else if item.status != "pending" {
          StatusPill(text: item.status)
        }
        Text(Org2Display.cleanInline(item.title))
          .font(.body.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(1)

        Spacer(minLength: 8)

        ZStack(alignment: .trailing) {
          metaText.opacity(isHovered && !showsActionBar ? 0 : 1)
          if isHovered && !showsActionBar {
            hoverActions
          }
        }
        .frame(height: 18)
      }

      VStack(alignment: .leading, spacing: 3) {
        if !summary.isEmpty {
          Text(summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(isSelected ? 3 : 1)
        }

        if let context = item.listRunContext {
          Label(context, systemImage: "clock.arrow.circlepath")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        if let note = item.listDecisionNote {
          Label(note, systemImage: "exclamationmark.circle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .lineLimit(2)
        }

        if let until = item.snoozedUntilDate, item.isSnoozed() {
          Label(
            "Snoozed until \(until.formatted(date: .abbreviated, time: item.supportsTimedSnooze ? .shortened : .omitted))",
            systemImage: "moon.zzz"
          )
          .font(.caption.weight(.medium))
          .foregroundStyle(.indigo)
        }
      }
      .padding(.leading, 26)

      if showsActionBar {
        actionBar
          .padding(.leading, 26)
          .padding(.top, 4)
          .transition(.opacity)
      }

      if let actionError {
        VStack(alignment: .leading, spacing: 6) {
          Label(actionError, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
          if let repairSource {
            HStack(spacing: 8) {
              Button {
                repairSource()
              } label: {
                if isRepairingSource {
                  HStack(spacing: 6) {
                    WorkspaceActivityIndicator(size: .mini)
                    Text("Repairing")
                  }
                } else {
                  Label("Repair & Retry", systemImage: "wrench.and.screwdriver")
                }
              }
              .buttonStyle(WorkspaceActionButtonStyle())
              .disabled(isActionInProgress)
              Text("Restores generated run fields from canonical machine state, then retries this action.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .workspaceSelectableRow(isSelected: isSelected, verticalPadding: 8)
    .onHover { isHovered = $0 }
    .help(sourceReference)
  }

  private var metaText: some View {
    return Text([item.compactSourceLabel, item.compactAgeText()].compactMap { $0 }.joined(separator: " · "))
      .font(.caption)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .fixedSize()
  }

  private var hoverActions: some View {
    HStack(spacing: 2) {
      Button(action: approve) {
        Image(systemName: "checkmark")
      }
      .help("Approve")
      Menu {
        ApprovalSnoozeMenuContent(allowsTime: item.supportsTimedSnooze, snooze: snooze, pickDate: pickSnoozeDate)
      } label: {
        Image(systemName: "moon.zzz")
      }
      .menuIndicator(.hidden)
      .help("Snooze")
      Button(action: reject) {
        Image(systemName: "xmark")
      }
      .help("Reject")
    }
    .buttonStyle(.borderless)
    .menuStyle(.borderlessButton)
    .controlSize(.small)
    .fixedSize()
  }

  private var actionBar: some View {
    HStack(spacing: 6) {
      Button(action: approve) {
        if isApproving {
          HStack(spacing: 6) {
            WorkspaceActivityIndicator(size: .mini)
            Text("Approving")
          }
        } else {
          Text("Approve")
        }
      }
      .buttonStyle(RunPrimaryButtonStyle(tint: WorkspaceDesign.themed(.done)))
      .disabled(isActionInProgress)

      if item.isSnoozed() {
        Button("Wake", action: wake)
          .buttonStyle(RunSecondaryButtonStyle())
          .disabled(isActionInProgress)
          .help("Return this approval to Pending now")
      }

      Menu {
        ApprovalSnoozeMenuContent(allowsTime: item.supportsTimedSnooze, snooze: snooze, pickDate: pickSnoozeDate)
      } label: {
        if isSnoozing {
          HStack(spacing: 6) {
            WorkspaceActivityIndicator(size: .mini)
            Text("Snoozing")
          }
        } else {
          Text("Snooze")
        }
      }
      .menuStyle(.button)
      .buttonStyle(RunSecondaryButtonStyle())
      .fixedSize()
      .disabled(isActionInProgress)
      .help(item.supportsTimedSnooze
        ? "Hide this approval until later. It stays pending and returns on its own."
        : "Schedule this approval for a later day. It stays pending and returns on that day.")

      Button(action: reject) {
        if isRejecting {
          HStack(spacing: 6) {
            WorkspaceActivityIndicator(size: .mini)
            Text("Rejecting")
          }
        } else {
          Text("Reject")
        }
      }
      .buttonStyle(RunSecondaryButtonStyle())
      .disabled(isActionInProgress)

      Menu {
        if let requestChanges {
          Button("Request Changes…", action: requestChanges)
        }
        Button("Mark Done Elsewhere…", action: markDoneElsewhere)
        Divider()
        Button("Discuss in AI Chat…", action: discuss)
        Button("Copy Discussion Text", action: copy)
      } label: {
        if isCompletingExternally {
          HStack(spacing: 6) {
            WorkspaceActivityIndicator(size: .mini)
            Text("Finishing")
          }
        } else {
          Image(systemName: "ellipsis")
        }
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(RunSecondaryButtonStyle())
      .fixedSize()
      .disabled(isActionInProgress)
      .help("More actions")
    }
    .controlSize(.small)
  }
}

struct ApprovalSnoozeDateRequest: Identifiable {
  let id = UUID()
  /// nil snoozes the bulk selection.
  let item: ApprovalItem?
  let allowsTime: Bool
}

private struct ApprovalSnoozeMenuContent: View {
  let allowsTime: Bool
  let snooze: (ApprovalSnoozeOption) -> Void
  let pickDate: () -> Void

  var body: some View {
    ForEach(ApprovalSnoozeOption.allCases.filter { allowsTime || $0.isWholeDay }) { option in
      Button(option.title) { snooze(option) }
    }
    Divider()
    Button("Pick a Date…") { pickDate() }
  }
}

private struct ApprovalSnoozeDateSheet: View {
  @Environment(\.dismiss) private var dismiss
  let allowsTime: Bool
  let snooze: (Date) -> Void
  @State private var date = ApprovalSnoozeOption.tomorrowMorning.wakeDate()

  private var minimumDate: Date {
    allowsTime
      ? Date().addingTimeInterval(60)
      : Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Snooze Until").font(.title2.weight(.semibold))
      Text(allowsTime
        ? "The approval stays pending and returns to the queue at this time."
        : "Headline approvals snooze with a SCHEDULED date, so they return at the start of the chosen day.")
        .foregroundStyle(.secondary)
      DatePicker(
        "Wake",
        selection: $date,
        in: minimumDate...,
        displayedComponents: allowsTime ? [.date, .hourAndMinute] : [.date]
      )
      .datePickerStyle(.graphical)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Snooze") {
          snooze(allowsTime ? date : Calendar.current.startOfDay(for: date))
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 420)
  }
}

private struct ApprovalRevisionSheet: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let action: String
  @Binding var feedback: String
  let requestChanges: (String) -> Void

  private var normalizedFeedback: String {
    feedback.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Request Changes")
          .font(.headline)
        Text(Org2Display.cleanInline(title))
          .font(.body.weight(.semibold))
          .lineLimit(2)
        if !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(Org2Display.cleanBlock(action).trimmedForDisplay(maxCharacters: 360))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(4)
        }
      }

      Text("What should the agent change?")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      TextEditor(text: $feedback)
        .font(.body)
        .frame(minHeight: 130)
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(WorkspaceDesign.hairline)
        )

      Text("The current material will remain unapproved. Your feedback is saved on the run and sent to an agent, which revises the material and asks for your approval again.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button {
          let feedback = normalizedFeedback
          dismiss()
          requestChanges(feedback)
        } label: {
          Label("Request Changes", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.borderedProminent)
        .disabled(normalizedFeedback.isEmpty)
      }
    }
    .padding(18)
    .frame(width: 480)
  }
}

private struct ApprovalDiscussionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(WorkspaceStore.self) private var store
  let item: ApprovalItem
  @Binding var message: String
  let discuss: (String, AIChatThreadMode) -> Void
  @State private var threadMode: AIChatThreadMode = .newThread

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        StatusPill(text: item.status)
        Text(Org2Display.cleanInline(item.title))
          .font(.headline)
          .lineLimit(2)
        Text("\(store.relativePath(item.file)):\(item.line)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      Text("Discussion prompt")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      TextEditor(text: $message)
        .font(.body)
        .frame(minHeight: 120)
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(WorkspaceDesign.hairline)
        )

      Picker("Destination", selection: $threadMode) {
        ForEach(AIChatThreadMode.allCases) { mode in
          if let title = mode.discussionDestinationTitle(
            selectedThreadTitle: store.selectedAIChatThread?.title
          ) {
            Text(title).tag(mode)
          }
        }
      }
      .pickerStyle(.radioGroup)
      .horizontalRadioGroupLayout()
      .help("Start a new AI thread or continue the specifically named selected thread.")

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        Button {
          let message = message
          let threadMode = threadMode
          dismiss()
          discuss(message, threadMode)
        } label: {
          Label("Discuss", systemImage: "paperplane")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(18)
    .frame(width: 460)
    .onAppear {
      threadMode = .newThread
    }
    .onChange(of: store.selectedAIChatThreadID) {
      if threadMode == .currentThread, store.selectedAIChatThread == nil {
        threadMode = .newThread
      }
    }
  }
}

struct AgendaItemListView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID

  var body: some View {
    WorkspaceLazyCollection {
      ForEach(store.agendaDisplaySections) { section in
        Section {
          ForEach(section.items) { item in
            AgendaRow(
              item: item,
              sourceReference: store.corpusQualifiedPath(item.file, corpus: item.corpus) + ":\(item.lineForEditor)",
              isSelected: store.selectedAgendaItemID == item.id,
              isBulkSelected: store.isAgendaItemBulkSelected(item),
              isEditable: store.isResultInActiveCorpus(item.corpus),
              isAgentAssigned: store.isAgentAssignee(item.properties["ASSIGNEE"]),
              isPersonalAssigned: store.isPersonalAssignee(item.properties["ASSIGNEE"]),
              workState: CelorgaNames.property("ORG2_RUN_ID", in: item.properties) == nil
                ? nil
                : store.headingWorkState(properties: item.properties)?.state,
              toggleBulkSelection: { store.toggleAgendaItemBulkSelection(item) },
              setPriority: { priority in
                Task { await store.applyPriorityShortcut(priority, to: .agenda(item)) }
              }
            )
              .equatable()
              .contentShape(Rectangle())
              .onTapGesture {
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                selectAgendaItem(item, modifiers: modifiers)
              }
              .workspaceAccessibleCollectionRow(
                kind: "agenda",
                id: item.id,
                label: Org2Display.cleanInline(item.headline),
                isSelected: store.selectedAgendaItemID == item.id,
                open: { selectAgendaItem(item) }
              )
              .contextMenu {
                WorkspaceLocationContextMenu(
                  location: .agenda(item),
                  showsHeadingActions: store.isResultInActiveCorpus(item.corpus),
                  select: { store.selectAgendaItem(item) }
                ) {
                  Label("Open", systemImage: "calendar")
                }

                Divider()

                Button {
                  store.toggleAgendaItemBulkSelection(item)
                } label: {
                  Label(
                    store.isAgendaItemBulkSelected(item) ? "Remove from Bulk Selection" : "Add to Bulk Selection",
                    systemImage: store.isAgendaItemBulkSelected(item) ? "minus.square" : "checkmark.square"
                  )
                }
              }
              .workspaceLazyRow(id: AgendaRowIdentity.id(for: item, inSection: section.id))
          }
        } header: {
          WorkspaceLazySectionHeader {
            Text(section.label)
          }
        }
      }

      if store.agendaDisplaySections.isEmpty {
        Text("No agenda items")
          .foregroundStyle(.secondary)
          .padding(WorkspaceDesign.contentInset)
      }
    }
  }

  private func selectAgendaItem(
    _ item: AgendaItem,
    modifiers: NSEvent.ModifierFlags = []
  ) {
    performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
      store.handleAgendaItemClick(item, modifiers: modifiers)
    }
  }
}

struct AssignedAgendaListView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID

  var body: some View {
    if store.isLoadingAssignedWork {
      Spacer()
      WorkspaceLoadingStateView("Loading assigned work")
      Spacer()
    } else {
      WorkspaceLazyCollection {
        ForEach(store.assignedWorkSections) { section in
          Section {
            ForEach(section.items) { item in
              AssignedWorkRow(
                item: item,
                sourceReference: store.relativePath(item.file) + ":\(item.lineForEditor)",
                isSelected: store.selectedAssignedWorkItemID == item.id
              )
                .contentShape(Rectangle())
                .onTapGesture {
                  store.selectAssignedWorkItem(item)
                }
                .workspaceAccessibleCollectionRow(
                  kind: "assigned-agenda",
                  id: item.id,
                  label: Org2Display.cleanInline(item.headline),
                  isSelected: store.selectedAssignedWorkItemID == item.id,
                  open: { store.selectAssignedWorkItem(item) }
                )
                .contextMenu {
                  WorkspaceLocationContextMenu(
                    location: .assigned(item),
                    showsHeadingActions: true,
                    select: { store.selectAssignedWorkItem(item) }
                  ) {
                    Label("Open", systemImage: "person.crop.circle.badge.checkmark")
                  }
                }
                .workspaceLazyRow(id: item.id)
            }
          } header: {
            WorkspaceLazySectionHeader {
              Text(section.label)
            }
          }
        }

        if store.assignedWorkSections.isEmpty {
          Text("No all-time agenda items")
            .foregroundStyle(.secondary)
            .padding(WorkspaceDesign.contentInset)
        }
      }
      .onChange(of: store.selectedAssignedWorkItemID) {
        guard let id = store.selectedAssignedWorkItemID,
              let item = store.assignedWorkItems.first(where: { $0.id == id })
        else {
          return
        }
        performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
          guard store.selectedAssignedWorkItemID == id else { return }
          store.selectAssignedWorkItem(item)
        }
      }
      .onAppear {
        Task {
          await store.refreshAssignedWorkIfNeeded()
          store.syncAssignedAgendaSelectionAfterDisplayOptionsChange()
        }
      }
    }
  }
}

struct AgendaBulkActionBar: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    HStack(spacing: 8) {
      Label("\(store.bulkAgendaSelectionCount) selected", systemImage: "checkmark.square")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
        .monospacedDigit()

      Spacer(minLength: 0)

      Button {
        store.selectAllVisibleAgendaItemsForBulkAction()
      } label: {
        Label("Select Visible", systemImage: "checkmark.square")
      }
      .disabled(store.visibleAgendaItemCount == 0)

      Button {
        if let item = store.visibleAgendaItems.first(where: { store.isAgendaItemBulkSelected($0) }) {
          store.startNewAIThreadFromAgendaSelection(including: item)
        }
      } label: {
        Label("Start New AI Thread", systemImage: "sparkles")
      }

      Menu {
        Button("TODO") {
          Task { await store.applyTodoShortcut(.todo) }
        }
        Button("In Progress") {
          Task { await store.applyTodoShortcut(.inProgress) }
        }
        Button("Done") {
          Task { await store.applyTodoShortcut(.done) }
        }
        Button("Canceled") {
          Task { await store.applyTodoShortcut(.canceled) }
        }
      } label: {
        Label("Status", systemImage: "tag")
      }

      Button {
        Task { await store.applyTodoShortcut(.done) }
      } label: {
        Label("Done", systemImage: "checkmark.circle")
      }

      Menu {
        AgentHandoffMenuItems { profile in
          Task { await store.applyAgentHandoffShortcut(agentProfile: profile) }
        }
      } label: {
        Label("Pass to Agent", systemImage: "paperplane")
      }

      Button {
        Task { await store.applyApproveAndAgentHandoffShortcut() }
      } label: {
        Label("Approve & Hand Off", systemImage: "checkmark.seal")
      }

      Button {
        store.promptAndApplyRejectApprovalShortcut()
      } label: {
        Label("Reject", systemImage: "xmark.octagon")
      }

      Button {
        store.clearAgendaBulkSelection()
      } label: {
        Label("Clear", systemImage: "xmark.circle")
      }
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.panelFill)
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

/// The lazy-stack identity of an agenda row. Marking a task done removes its
/// row from Today and inserts it under Done or canceled with the same item ID;
/// with only that ID the stack could keep showing the removed row, so a DONE
/// task appeared with its old TODO state until the view was rebuilt. The
/// section and TODO state make the moved row a new view.
enum AgendaRowIdentity {
  static func id(for item: AgendaItem, inSection sectionID: String) -> String {
    "\(sectionID)\u{0}\(item.todo ?? "")\u{0}\(item.id)"
  }
}

private struct AgendaRow: View, Equatable {
  let item: AgendaItem
  let sourceReference: String
  let isSelected: Bool
  let isBulkSelected: Bool
  let isEditable: Bool
  let isAgentAssigned: Bool
  let isPersonalAssigned: Bool
  var workState: HeadingWorkState? = nil
  let toggleBulkSelection: () -> Void
  let setPriority: (String?) -> Void

  nonisolated static func == (lhs: AgendaRow, rhs: AgendaRow) -> Bool {
    lhs.item == rhs.item
      && lhs.workState == rhs.workState
      && lhs.sourceReference == rhs.sourceReference
      && lhs.isSelected == rhs.isSelected
      && lhs.isBulkSelected == rhs.isBulkSelected
      && lhs.isEditable == rhs.isEditable
      && lhs.isAgentAssigned == rhs.isAgentAssigned
      && lhs.isPersonalAssigned == rhs.isPersonalAssigned
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Button {
        toggleBulkSelection()
      } label: {
        AgendaBulkSelectionCheckbox(
          isChecked: isBulkSelected,
          isEnabled: isEditable
        )
      }
      .buttonStyle(.plain)
      .disabled(!isEditable)
      .accessibilityLabel(isBulkSelected ? "Remove from bulk selection" : "Add to bulk selection")
      .help(isBulkSelected ? "Remove from bulk selection" : "Add to bulk selection")
      .padding(.top, 1)

      HStack(spacing: 4) {
        StatusPill(text: item.todo ?? "TASK")
        AgendaPriorityControl(
          priority: item.priority,
          isEditable: isEditable,
          setPriority: setPriority
        )
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(Org2Display.cleanInline(item.headline))
            .font(.body.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
          if item.idValue != nil {
            Image(systemName: "link")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let corpus = item.corpus {
            Text(corpus.name)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkspaceDesign.subtleFill, in: Capsule())
          }
        }
        HStack(spacing: 8) {
          Text(item.planningLabel)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
          Text(sourceReference)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if let workState {
        HeadingWorkStateBadge(state: workState)
      }
      AgendaAssignmentIndicator(
        item: item,
        isAgentAssigned: isAgentAssigned,
        isPersonalAssigned: isPersonalAssigned
      )
    }
    .workspaceSelectableRow(
      isSelected: isSelected,
      showsSelectionMarker: false,
      leadingPadding: 10,
      verticalPadding: WorkspaceDesign.rowVerticalPadding
    )
  }
}

private struct AgendaPriorityControl: View {
  let priority: String?
  let isEditable: Bool
  let setPriority: (String?) -> Void

  var body: some View {
    if isEditable {
      Menu {
        priorityButton("A", priority: "A")
        priorityButton("B", priority: "B")
        priorityButton("C", priority: "C")
        Divider()
        priorityButton("No priority", priority: nil)
      } label: {
        if AgendaPriorityPill.normalizedPriority(priority) != nil {
          AgendaPriorityPill(priority: priority)
        } else {
          Image(systemName: "flag")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Change priority. The change is saved in the Org source file.")
    } else {
      AgendaPriorityPill(priority: priority)
    }
  }

  private func priorityButton(_ title: String, priority candidate: String?) -> some View {
    Button {
      setPriority(candidate)
    } label: {
      if AgendaPriorityPill.normalizedPriority(priority) == candidate {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }
}

private struct AgendaBulkSelectionCheckbox: View {
  let isChecked: Bool
  let isEnabled: Bool

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(isChecked ? Color.accentColor : WorkspaceDesign.controlFill)
        .overlay {
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(
              isChecked ? Color.accentColor : WorkspaceDesign.structuralAccent.opacity(0.48),
              lineWidth: 1
            )
        }

      if isChecked {
        Image(systemName: "checkmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.white)
      }
    }
    .frame(width: 16, height: 16)
    .frame(width: 18, height: 18)
    .contentShape(Rectangle())
    .opacity(isEnabled ? 1 : 0.5)
    .accessibilityHidden(true)
  }
}

struct AgendaPriorityPill: View {
  let priority: String?

  @ViewBuilder
  var body: some View {
    if let normalized = Self.normalizedPriority(priority) {
      Text(normalized)
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(tone.foreground)
        .frame(minWidth: 16)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(tone.background, in: Capsule())
        .accessibilityLabel("Priority \(normalized)")
        .help("Priority [#\(normalized)]")
    }
  }

  private var tone: AgendaPriorityTone {
    guard let normalized = Self.normalizedPriority(priority) else {
      return .neutral
    }
    return Self.tone(for: normalized)
  }

  nonisolated static func normalizedPriority(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else {
      return nil
    }
    value = value
      .replacingOccurrences(of: "[#", with: "")
      .replacingOccurrences(of: "]", with: "")
      .uppercased()
    guard value.range(of: #"^[A-Z0-9]$"#, options: .regularExpression) != nil else {
      return nil
    }
    return value
  }

  nonisolated static func tone(for normalizedPriority: String) -> AgendaPriorityTone {
    switch normalizedPriority {
    case "A":
      return .urgent
    case "B":
      return .elevated
    case "C":
      return .quiet
    default:
      return .neutral
    }
  }
}

enum AgendaPriorityTone: Equatable {
  case urgent
  case elevated
  case quiet
  case neutral

  var foreground: Color {
    switch self {
    case .urgent:
      return .orange
    case .elevated:
      return .indigo
    case .quiet:
      return .secondary
    case .neutral:
      return .secondary
    }
  }

  var background: Color {
    switch self {
    case .urgent:
      return Color.orange.opacity(0.13)
    case .elevated:
      return Color.indigo.opacity(0.11)
    case .quiet:
      return WorkspaceDesign.controlFill
    case .neutral:
      return WorkspaceDesign.controlFill
    }
  }
}

private struct AgendaAssignmentIndicator: View {
  let item: AgendaItem
  let isAgentAssigned: Bool
  let isPersonalAssigned: Bool

  private var assignee: String? {
    let trimmed = item.properties["ASSIGNEE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private var label: String {
    assignee ?? "Me"
  }

  private var helpText: String {
    if isAgentAssigned, let assignee {
      return "Assigned to agent: \(assignee)"
    }
    if let assignee {
      return isPersonalAssigned ? "Assigned to you: \(assignee)" : "Assigned to \(assignee)"
    }
    return "Assigned to you"
  }

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: isAgentAssigned ? "sparkles" : "person")
        .font(.caption2.weight(.semibold))
      Text(label)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .foregroundStyle(isAgentAssigned ? Color.accentColor : Color.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(
      (isAgentAssigned ? Color.accentColor.opacity(0.12) : WorkspaceDesign.subtleFill),
      in: Capsule()
    )
    .help(helpText)
  }
}
