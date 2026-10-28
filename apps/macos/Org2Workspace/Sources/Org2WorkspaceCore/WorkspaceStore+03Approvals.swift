import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  public func clearApprovalFilter() {
    approvalFilter = ""
  }

  public func selectApprovalItem(_ item: ApprovalItem) {
    if selectedApprovalItemID != item.id {
      selectedApprovalItemID = item.id
    }
    approvalSelectionAnchor = ApprovalSelectionAnchor(
      item: item,
      visibleIndex: visibleApprovalItems.firstIndex(where: { $0.id == item.id })
    )
    if let runID = item.runId, let run = agentRunsByID[runID] {
      selectAgentRun(run)
      if selectedApprovalItemID != item.id {
        selectedApprovalItemID = item.id
      }
      statusText = item.runDependencyText ?? item.sourceLabel
      return
    }
    if item.isRunApproval {
      statusText = item.runDependencyText ?? item.sourceLabel
      return
    }
    select(.agenda(item.agendaItem()), surface: .approvals)
    statusText = item.sourceLabel
  }

  public func handleApprovalItemClick(
    _ item: ApprovalItem,
    modifiers: NSEvent.ModifierFlags = []
  ) {
    selectedApprovalItemIDsForAIContext = Self.updatedAIContextSelection(
      selectedApprovalItemIDsForAIContext,
      activeID: selectedApprovalItemID,
      clickedID: item.id,
      visibleIDs: visibleApprovalItems.map(\.id),
      modifiers: modifiers
    )
    selectApprovalItem(item)
  }

  public func isApprovalItemSelectedForAIContext(_ item: ApprovalItem) -> Bool {
    selectedApprovalItemIDsForAIContext.isEmpty
      ? selectedApprovalItemID == item.id
      : selectedApprovalItemIDsForAIContext.contains(item.id)
  }

  public func reconcileApprovalAIContextSelection(visibleIDs: [ApprovalItem.ID]) {
    selectedApprovalItemIDsForAIContext.formIntersection(visibleIDs)
    bulkSelectedApprovalItemIDs.formIntersection(visibleIDs)
  }

  public var bulkApprovalSelectionCount: Int {
    let selection = bulkSelectedApprovalItemIDs
    guard !selection.isEmpty else { return 0 }
    return visibleApprovalItems.reduce(0) { $0 + (selection.contains($1.id) ? 1 : 0) }
  }

  public var hasBulkApprovalSelection: Bool {
    bulkApprovalSelectionCount > 0
  }

  public func isApprovalItemBulkSelected(_ item: ApprovalItem) -> Bool {
    bulkSelectedApprovalItemIDs.contains(item.id)
  }

  public func toggleApprovalItemBulkSelection(_ item: ApprovalItem) {
    var ids = bulkSelectedApprovalItemIDs
    if ids.contains(item.id) {
      ids.remove(item.id)
    } else {
      ids.insert(item.id)
    }
    bulkSelectedApprovalItemIDs = ids
    updateApprovalBulkSelectionStatusText()
  }

  public func selectAllVisibleApprovalItemsForBulkAction() {
    bulkSelectedApprovalItemIDs = Set(visibleApprovalItems.map(\.id))
    updateApprovalBulkSelectionStatusText()
  }

  public func extendApprovalBulkSelection(by delta: Int) {
    let items = visibleApprovalItems
    let result = Self.extendedKeyboardSelection(
      bulkSelectedApprovalItemIDs,
      activeID: selectedApprovalItemID,
      visibleIDs: items.map(\.id),
      delta: delta
    )
    guard let targetID = result.targetID,
          let target = items.first(where: { $0.id == targetID })
    else {
      statusText = "No visible approvals"
      return
    }
    bulkSelectedApprovalItemIDs = result.selection
    selectApprovalItem(target)
    updateApprovalBulkSelectionStatusText()
  }

  public func moveApprovalSelection(by delta: Int) {
    let items = visibleApprovalItems
    guard !items.isEmpty else {
      statusText = "No visible approvals"
      return
    }
    let currentIndex = selectedApprovalItemID.flatMap { selectedID in
      items.firstIndex(where: { $0.id == selectedID })
    }
    let targetIndex: Int
    if let currentIndex {
      targetIndex = min(max(0, currentIndex + delta), items.count - 1)
    } else {
      targetIndex = delta < 0 ? items.count - 1 : 0
    }
    handleApprovalItemClick(items[targetIndex])
  }

  public func clearApprovalBulkSelection() {
    guard !bulkSelectedApprovalItemIDs.isEmpty else { return }
    bulkSelectedApprovalItemIDs = []
    statusText = "Approval selection cleared"
  }

  private func updateApprovalBulkSelectionStatusText() {
    let count = bulkApprovalSelectionCount
    if count == 0 {
      statusText = "No approvals selected"
    } else {
      statusText = count == 1 ? "1 approval selected" : "\(count) approvals selected"
    }
  }

  private func selectedApprovalItemsForBulkMutation() -> [ApprovalItem] {
    guard !bulkSelectedApprovalItemIDs.isEmpty else { return [] }
    return visibleApprovalItems.filter { bulkSelectedApprovalItemIDs.contains($0.id) }
  }

  public func approveSelectedApprovals() async {
    let items = selectedApprovalItemsForBulkMutation()
    guard !items.isEmpty else { return }
    await performBulkApprovalAction(items) { store, item in
      await store.approve(item, updatesApprovalQueue: false, waitsForContinuation: false)
    }
  }

  public func rejectSelectedApprovals(endStatus: TodoEditStatus, reason: String) async {
    let items = selectedApprovalItemsForBulkMutation()
    guard !items.isEmpty else { return }
    await performBulkApprovalAction(items) { store, item in
      await store.rejectApproval(
        item,
        endStatus: endStatus,
        reason: reason,
        updatesApprovalQueue: false,
        waitsForContinuation: false
      )
    }
  }

  public func completeSelectedApprovalsExternally(summary: String) async {
    let items = selectedApprovalItemsForBulkMutation()
    guard !items.isEmpty else { return }
    await performBulkApprovalAction(items) { store, item in
      await store.completeApprovalExternally(
        item,
        summary: summary,
        updatesApprovalQueue: false,
        waitsForContinuation: false
      )
    }
  }

  public func snoozeSelectedApprovals(until: Date) async {
    let items = selectedApprovalItemsForBulkMutation()
    guard !items.isEmpty else { return }
    await performBulkApprovalAction(items) { store, item in
      await store.setApprovalSnooze(item, until: until, updatesApprovalQueue: false)
    }
  }

  public func wakeSelectedApprovals() async {
    let items = selectedApprovalItemsForBulkMutation()
    guard !items.isEmpty else { return }
    await performBulkApprovalAction(items) { store, item in
      await store.setApprovalSnooze(item, until: nil, updatesApprovalQueue: false)
    }
  }

  private func performBulkApprovalAction(
    _ items: [ApprovalItem],
    action: @escaping @MainActor @Sendable (WorkspaceStore, ApprovalItem) async -> Void
  ) async {
    let selectedIDs = Set(items.map(\.id))
    await withTaskGroup(of: Void.self) { group in
      for item in items {
        group.addTask { [weak self] in
          guard let self else { return }
          await action(self, item)
        }
      }
    }

    let failedIDs = selectedIDs.filter { approvalActionErrorsByItemID[$0] != nil }
    let completedIDs = selectedIDs.subtracting(failedIDs)
    if !completedIDs.isEmpty {
      // Animating many self-sizing table rows out at once stalls the main
      // thread for hundreds of milliseconds; a batch lands in one frame.
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        approvalItems.removeAll { completedIDs.contains($0.id) }
        snoozedApprovalItems.removeAll { completedIDs.contains($0.id) }
        if let selectedApprovalItemID, completedIDs.contains(selectedApprovalItemID) {
          self.selectedApprovalItemID = nil
          approvalSelectionAnchor = nil
          syncApprovalSelectionAfterRefresh()
        }
      }
    }
    scheduleApprovalsRefresh()
    bulkSelectedApprovalItemIDs = Set(failedIDs)
    let completedCount = items.count - failedIDs.count
    if failedIDs.isEmpty {
      statusText = items.count == 1
        ? "Approval action completed"
        : "Approval actions completed for \(items.count) items"
    } else {
      statusText = "Approval actions completed: \(completedCount) succeeded, \(failedIDs.count) failed"
    }
  }

  public func showApprovalInQueue(run: AgentRunItem, approval: AgentRunApprovalItem) {
    runsAndReviewPage = .review
    approvalFilter = ""
    selectedApprovalItemID = "run:\(run.id):\(approval.id)"
    statusText = "Opened approval in Review"
  }

  public func approve(_ item: ApprovalItem) async {
    await approve(item, updatesApprovalQueue: true, waitsForContinuation: true)
  }

  func approve(
    _ item: ApprovalItem,
    updatesApprovalQueue: Bool,
    waitsForContinuation: Bool
  ) async {
    guard !isApprovalActionInProgress(item) else { return }
    let originalVisibleIndex = visibleApprovalItems.firstIndex(where: { $0.id == item.id })
    beginApprovalAction(item, kind: .approve)
    defer { endApprovalAction(item, kind: .approve) }

    let standaloneContext = item.isRunApproval ? nil : captureDocumentCorpusContext(forFile: item.file)
    do {
      if item.isRunApproval {
        let updated = try await decideRunApprovalItem(item, decision: "approved")
        if updatesApprovalQueue {
          removeApprovalItemOptimistically(item.id, originalVisibleIndex: originalVisibleIndex)
          scheduleApprovalsRefresh()
        }
        await continueAfterApprovalBoundary(updated, decision: "approved", waits: waitsForContinuation)
        return
      }
      try await approveAndAgentHandoff(HeadlineMutationTarget(
        file: item.file,
        line: item.line,
        title: Org2Display.cleanInline(item.title),
        agendaItemID: nil,
        idValue: item.idValue
      ))
      if let standaloneContext {
        guard isCurrentDocumentCorpusContext(standaloneContext) else { return }
      }
      if updatesApprovalQueue {
        removeApprovalItemOptimistically(item.id, originalVisibleIndex: originalVisibleIndex)
        scheduleApprovalsRefresh()
      }
    } catch {
      if let standaloneContext, !isCurrentDocumentCorpusContext(standaloneContext) { return }
      recordApprovalActionFailure(
        item,
        error: error,
        status: "Approve handoff failed",
        repairRetry: item.isRunApproval ? .approve : nil
      )
    }
  }

  // MARK: Snooze

  public func snoozeApproval(_ item: ApprovalItem, option: ApprovalSnoozeOption) async {
    await snoozeApproval(item, until: option.wakeDate())
  }

  public func snoozeApproval(_ item: ApprovalItem, until: Date) async {
    await setApprovalSnooze(item, until: until, updatesApprovalQueue: true)
  }

  public func wakeApproval(_ item: ApprovalItem) async {
    await setApprovalSnooze(item, until: nil, updatesApprovalQueue: true)
  }

  /// Snoozes (`until` set) or wakes (`until == nil`) one approval. Run approvals record
  /// `snoozedUntil` through `celorga run approval-snooze`; headline approvals move their
  /// SCHEDULED date, as Org does. Either way the approval stays pending.
  func setApprovalSnooze(
    _ item: ApprovalItem,
    until: Date?,
    updatesApprovalQueue: Bool
  ) async {
    guard !isApprovalActionInProgress(item) else { return }
    let originalVisibleIndex = visibleApprovalItems.firstIndex(where: { $0.id == item.id })
    beginApprovalAction(item, kind: .snooze)
    defer { endApprovalAction(item, kind: .snooze) }
    let standaloneContext = item.isRunApproval ? nil : captureDocumentCorpusContext(forFile: item.file)
    do {
      let snoozedUntil: String?
      if item.isRunApproval {
        snoozedUntil = try await setRunApprovalSnooze(item, until: until)
      } else {
        snoozedUntil = try await setHeadlineApprovalSnooze(item, until: until)
      }
      if let standaloneContext {
        guard isCurrentDocumentCorpusContext(standaloneContext) else { return }
      }
      if updatesApprovalQueue {
        moveApprovalItemAfterSnooze(item.withSnoozedUntil(snoozedUntil), originalVisibleIndex: originalVisibleIndex)
        scheduleApprovalsRefresh()
      }
      let title = Org2Display.cleanInline(item.title)
      if let until {
        statusText = "Snoozed \(title) until \(until.formatted(date: .abbreviated, time: item.supportsTimedSnooze ? .shortened : .omitted))"
      } else {
        statusText = "Woke \(title)"
      }
    } catch {
      if let standaloneContext, !isCurrentDocumentCorpusContext(standaloneContext) { return }
      recordApprovalActionFailure(item, error: error, status: until == nil ? "Wake failed" : "Snooze failed")
    }
  }

  private func setRunApprovalSnooze(_ item: ApprovalItem, until: Date?) async throws -> String? {
    guard let corpusRoot, let runID = item.runId, let approvalID = item.approvalId else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This run approval is missing its run or approval identity."])
    }
    try await waitForAgentRunMutationAvailability(runID)
    defer { mutatingAgentRunIDs.remove(runID) }
    let untilText = until.map(Self.approvalSnoozeTimestamp)
    let updated: AgentRunItem
    if let agentRunApprovalSnoozeForTesting {
      updated = try await agentRunApprovalSnoozeForTesting(runID, approvalID, until)
    } else {
      var arguments = ["run", "approval-snooze", runID, approvalID]
      if let untilText {
        arguments.append(contentsOf: ["--until", untilText])
      } else {
        arguments.append("--wake")
      }
      arguments.append(contentsOf: [
        "--actor", Self.agentRunApprovalDecisionActor(requestedFrom: item.requestedFrom),
        "--dir", corpusRoot.path,
        "--json"
      ])
      if let fingerprint = item.fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines), !fingerprint.isEmpty {
        arguments.append(contentsOf: ["--fingerprint", fingerprint])
      }
      updated = try await cli.runJSON(arguments)
    }
    if let index = agentRuns.firstIndex(where: { $0.id == updated.id }) {
      agentRuns[index] = updated
    }
    return untilText
  }

  private func setHeadlineApprovalSnooze(_ item: ApprovalItem, until: Date?) async throws -> String? {
    let target = HeadlineMutationTarget(
      file: item.file,
      line: item.line,
      title: Org2Display.cleanInline(item.title),
      agendaItemID: nil,
      idValue: item.idValue
    )
    // Org snooze: SCHEDULED on the wake day. Waking schedules it for today.
    let day = until.map { Calendar.current.startOfDay(for: $0) } ?? Calendar.current.startOfDay(for: Date())
    let date = Self.formatDate(day)
    let context = try documentMutationContext(for: target)
    let cli = self.cli
    _ = try await performDocumentMutation(context: context, files: [target.file]) { execution in
      try await Self.planHeadingInDocument(
        kind: .scheduled,
        date: date,
        target: target,
        cli: cli,
        execution: execution
      )
    }
    return day > Date() ? Self.approvalSnoozeTimestamp(day) : nil
  }

  nonisolated static func approvalSnoozeTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  /// Splits a queue scan into awake and snoozed approvals at `now`.
  nonisolated static func partitionSnoozedApprovalItems(
    _ items: [ApprovalItem],
    now: Date = Date()
  ) -> (awake: [ApprovalItem], snoozed: [ApprovalItem]) {
    var awake: [ApprovalItem] = []
    var snoozed: [ApprovalItem] = []
    for item in items {
      if item.isSnoozed(at: now) {
        snoozed.append(item)
      } else {
        awake.append(item.snoozedUntil == nil ? item : item.withSnoozedUntil(nil))
      }
    }
    return (awake, snoozed)
  }

  private func moveApprovalItemAfterSnooze(_ updated: ApprovalItem, originalVisibleIndex: Int?) {
    noteApprovalDecisionLanded()
    bulkSelectedApprovalItemIDs.remove(updated.id)
    approvalItems.removeAll { $0.id == updated.id }
    snoozedApprovalItems.removeAll { $0.id == updated.id }
    if updated.isSnoozed() {
      snoozedApprovalItems = Self.sortedApprovalItems(snoozedApprovalItems + [updated])
    } else {
      approvalItems = Self.sortedApprovalItems(approvalItems + [updated])
    }
    preserveApprovalSelectionAfterMutation(mutatedID: updated.id, originalVisibleIndex: originalVisibleIndex)
    scheduleApprovalSnoozeWake()
  }

  /// Returns snoozed approvals to the queue when their time passes, with no rescan needed:
  /// waking is a clock comparison, as with an Org SCHEDULED date.
  func scheduleApprovalSnoozeWake(now: Date = Date()) {
    approvalSnoozeWakeTask?.cancel()
    guard let next = snoozedApprovalItems.compactMap(\.snoozedUntilDate).min() else {
      approvalSnoozeWakeTask = nil
      return
    }
    let delay = min(max(next.timeIntervalSince(now), 0) + 1, 6 * 60 * 60)
    approvalSnoozeWakeTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      self.wakeExpiredSnoozedApprovals()
    }
  }

  func wakeExpiredSnoozedApprovals(now: Date = Date()) {
    let partitioned = Self.partitionSnoozedApprovalItems(snoozedApprovalItems, now: now)
    if !partitioned.awake.isEmpty {
      snoozedApprovalItems = partitioned.snoozed
      approvalItems = Self.sortedApprovalItems(approvalItems + partitioned.awake)
      statusText = partitioned.awake.count == 1
        ? "1 snoozed approval is back"
        : "\(partitioned.awake.count) snoozed approvals are back"
    }
    scheduleApprovalSnoozeWake(now: now)
  }

  public func promptAndRejectApproval(_ item: ApprovalItem) {
    guard !isApprovalActionInProgress(item) else { return }
    selectedApprovalItemID = item.id
    let rejection = item.isRunApproval
      ? Self.promptForRunApprovalRejection()
      : Self.promptForApprovalRejection()
    guard let rejection else { return }
    Task {
      await rejectApproval(
        item,
        endStatus: rejection.endStatus,
        reason: rejection.reason
      )
    }
  }

  public func rejectApproval(_ item: ApprovalItem, endStatus: TodoEditStatus, reason: String) async {
    await rejectApproval(
      item,
      endStatus: endStatus,
      reason: reason,
      updatesApprovalQueue: true,
      waitsForContinuation: true
    )
  }

  func rejectApproval(
    _ item: ApprovalItem,
    endStatus: TodoEditStatus,
    reason: String,
    updatesApprovalQueue: Bool,
    waitsForContinuation: Bool
  ) async {
    guard !isApprovalActionInProgress(item) else { return }
    let originalVisibleIndex = visibleApprovalItems.firstIndex(where: { $0.id == item.id })
    beginApprovalAction(item, kind: .reject)
    defer { endApprovalAction(item, kind: .reject) }

    let standaloneContext = item.isRunApproval ? nil : captureDocumentCorpusContext(forFile: item.file)
    do {
      if item.isRunApproval {
        let updated = try await decideRunApprovalItem(item, decision: "rejected", note: reason)
        if updatesApprovalQueue {
          removeApprovalItemOptimistically(item.id, originalVisibleIndex: originalVisibleIndex)
          scheduleApprovalsRefresh()
        }
        await continueAfterApprovalBoundary(updated, decision: "rejected", waits: waitsForContinuation)
        return
      }
      try await rejectApproval(
        HeadlineMutationTarget(
          file: item.file,
          line: item.line,
          title: Org2Display.cleanInline(item.title),
          agendaItemID: nil,
          idValue: item.idValue
        ),
        endStatus: endStatus,
        reason: reason
      )
      if let standaloneContext {
        guard isCurrentDocumentCorpusContext(standaloneContext) else { return }
      }
      if updatesApprovalQueue {
        removeApprovalItemOptimistically(item.id, originalVisibleIndex: originalVisibleIndex)
        scheduleApprovalsRefresh()
      }
    } catch {
      if let standaloneContext, !isCurrentDocumentCorpusContext(standaloneContext) { return }
      recordApprovalActionFailure(
        item,
        error: error,
        status: "Reject approval failed",
        repairRetry: item.isRunApproval ? .reject(endStatus: endStatus, reason: reason) : nil
      )
    }
  }

  public func completeApprovalExternally(_ item: ApprovalItem, summary: String) async {
    await completeApprovalExternally(
      item,
      summary: summary,
      updatesApprovalQueue: true,
      waitsForContinuation: true
    )
  }

  private func completeApprovalExternally(
    _ item: ApprovalItem,
    summary: String,
    updatesApprovalQueue: Bool,
    waitsForContinuation: Bool
  ) async {
    guard !isApprovalActionInProgress(item) else { return }
    let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    let originalVisibleIndex = visibleApprovalItems.firstIndex(where: { $0.id == item.id })
    beginApprovalAction(item, kind: .externalCompletion)
    defer { endApprovalAction(item, kind: .externalCompletion) }

    let standaloneContext = item.isRunApproval ? nil : captureDocumentCorpusContext(forFile: item.file)
    do {
      if item.isRunApproval {
        let updated = try await decideRunApprovalItem(
          item,
          decision: "canceled",
          receipt: normalizedSummary.isEmpty
            ? "Completed externally"
            : "Completed externally: \(normalizedSummary)"
        )
        if updatesApprovalQueue {
          removeApprovalItemOptimistically(item.id, originalVisibleIndex: originalVisibleIndex)
          scheduleApprovalsRefresh()
        }
        statusText = "Recorded external completion for \(item.title) · \(updated.pendingApprovalCount) pending"
        await continueAfterApprovalBoundary(updated, decision: "canceled", waits: waitsForContinuation)
        return
      }

      try await completeStandaloneApprovalExternally(
        HeadlineMutationTarget(
          file: item.file,
          line: item.line,
          title: Org2Display.cleanInline(item.title),
          agendaItemID: nil,
          idValue: item.idValue
        ),
        hasTodo: item.todo != nil,
        summary: normalizedSummary
      )
      if let standaloneContext {
        guard isCurrentDocumentCorpusContext(standaloneContext) else { return }
      }
      if updatesApprovalQueue {
        removeApprovalItemOptimistically(item.id, originalVisibleIndex: originalVisibleIndex)
        scheduleApprovalsRefresh()
      }
    } catch {
      if let standaloneContext, !isCurrentDocumentCorpusContext(standaloneContext) { return }
      recordApprovalActionFailure(
        item,
        error: error,
        status: "External completion failed",
        repairRetry: item.isRunApproval ? .externalCompletion(summary: normalizedSummary) : nil
      )
    }
  }

  public func isSnoozingApproval(_ item: ApprovalItem) -> Bool {
    snoozingApprovalItemIDs.contains(item.id)
  }

  public func isApprovingApproval(_ item: ApprovalItem) -> Bool {
    approvingApprovalItemIDs.contains(item.id)
  }

  public func isRejectingApproval(_ item: ApprovalItem) -> Bool {
    rejectingApprovalItemIDs.contains(item.id)
  }

  public func isCompletingApprovalExternally(_ item: ApprovalItem) -> Bool {
    externallyCompletingApprovalItemIDs.contains(item.id)
  }

  public func isRepairingApprovalSource(_ item: ApprovalItem) -> Bool {
    repairingApprovalSourceItemIDs.contains(item.id)
  }

  public func isApprovalActionInProgress(_ item: ApprovalItem) -> Bool {
    isApprovalActionInProgress(item.id)
  }

  public func isAgentRunApprovalActionInProgress(runID: String, approvalID: String) -> Bool {
    isApprovalActionInProgress(Self.runApprovalQueueItemID(runID: runID, approvalID: approvalID))
  }

  nonisolated static func runApprovalQueueItemID(
    runID: String,
    approvalID: String
  ) -> ApprovalItem.ID {
    ApprovalItem.ID("run:\(runID):\(approvalID)")
  }

  func isApprovalActionInProgress(_ itemID: ApprovalItem.ID) -> Bool {
    approvingApprovalItemIDs.contains(itemID)
      || rejectingApprovalItemIDs.contains(itemID)
      || externallyCompletingApprovalItemIDs.contains(itemID)
      || snoozingApprovalItemIDs.contains(itemID)
      || repairingApprovalSourceItemIDs.contains(itemID)
  }

  public func approvalActionError(_ item: ApprovalItem) -> String? {
    approvalActionErrorsByItemID[item.id]
  }

  public func canRepairApprovalSource(_ item: ApprovalItem) -> Bool {
    item.isRunApproval && approvalSourceRepairRetriesByItemID[item.id] != nil
  }

  public func repairApprovalSourceAndRetry(_ item: ApprovalItem) async {
    guard let runID = item.runId,
          let corpusRoot,
          let retry = approvalSourceRepairRetriesByItemID[item.id],
          !isApprovalActionInProgress(item)
    else {
      return
    }

    var repairingIDs = repairingApprovalSourceItemIDs
    repairingIDs.insert(item.id)
    repairingApprovalSourceItemIDs = repairingIDs
    do {
      if let agentRunSourceReconciliationForTesting {
        try await agentRunSourceReconciliationForTesting(runID)
      } else {
        let result: AgentRunSourceReconciliationResult = try await cli.runJSON([
          "run", "reconcile-source", runID,
          "--apply",
          "--dir", corpusRoot.path,
          "--json"
        ])
        guard result.remainingSourceIssues.isEmpty else {
          let fields = result.remainingSourceIssues.map(\.field).joined(separator: ", ")
          throw CocoaError(
            .fileWriteUnknown,
            userInfo: [NSLocalizedDescriptionKey: "The run still has conflicting readable fields: \(fields)."]
          )
        }
      }

      finishApprovalSourceRepair(item.id)
      statusText = "Repaired run source; retrying \(item.title)"
      switch retry {
      case .approve:
        await approve(item)
      case let .reject(endStatus, reason):
        await rejectApproval(item, endStatus: endStatus, reason: reason)
      case let .externalCompletion(summary):
        await completeApprovalExternally(item, summary: summary)
      case let .requestChanges(feedback):
        await requestChanges(item, feedback: feedback)
      }
    } catch {
      finishApprovalSourceRepair(item.id, clearsRetry: false)
      recordApprovalActionFailure(
        item,
        error: error,
        status: "Run source repair failed",
        repairRetry: retry
      )
    }
  }

  public func requestChanges(_ item: ApprovalItem, feedback: String) async {
    guard item.isRunApproval, !isApprovalActionInProgress(item) else { return }
    guard let feedback = Self.normalizedApprovalRevisionFeedback(feedback) else {
      errorText = "Describe what the agent should change."
      statusText = "Revision feedback required"
      return
    }
    let originalVisibleIndex = visibleApprovalItems.firstIndex(where: { $0.id == item.id })
    beginApprovalAction(item, kind: .reject)
    defer { endApprovalAction(item, kind: .reject) }
    statusText = "Requesting changes: \(Org2Display.cleanInline(item.title))…"
    do {
      let updated = try await decideRunApprovalItem(item, decision: "revised", note: feedback)
      removeApprovalItemOptimistically(item.id, originalVisibleIndex: originalVisibleIndex)
      scheduleApprovalsRefresh()
      await continueOpenClawAfterApprovalBoundary(updated)
    } catch {
      recordApprovalActionFailure(
        item,
        error: error,
        status: "Revision request failed",
        repairRetry: .requestChanges(feedback: feedback)
      )
    }
  }

  func decideRunApprovalItem(
    _ item: ApprovalItem,
    decision: String,
    note: String? = nil,
    receipt: String? = nil
  ) async throws -> AgentRunItem {
    guard corpusRoot != nil, let runID = item.runId, let approvalID = item.approvalId else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "This run approval is missing its run or approval identity."])
    }
    try await waitForAgentRunMutationAvailability(runID)
    defer { mutatingAgentRunIDs.remove(runID) }

    let updated = try await performAgentRunApprovalDecision(
      runID: runID,
      approvalID: approvalID,
      fingerprint: item.fingerprint,
      decision: decision,
      requestedRole: item.requestedRole,
      requestedFrom: item.requestedFrom,
      note: note,
      receipt: receipt
    )
    if let index = agentRuns.firstIndex(where: { $0.id == updated.id }) {
      agentRuns[index] = updated
    } else {
      agentRuns.insert(updated, at: 0)
    }
    statusText = "\(item.title): \(decision) · \(updated.pendingApprovalCount) pending"
    return updated
  }

  func performAgentRunApprovalDecision(
    runID: String,
    approvalID: String,
    fingerprint: String?,
    decision: String,
    requestedRole: String?,
    requestedFrom: String?,
    note: String? = nil,
    receipt: String? = nil
  ) async throws -> AgentRunItem {
    guard let corpusRoot else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No corpus is selected."])
    }
    let updated: AgentRunItem
    if let agentRunApprovalDecisionForTesting {
      updated = try await agentRunApprovalDecisionForTesting(
        runID,
        approvalID,
        decision,
        note
      )
    } else {
      var arguments = [
        "run", "approval-decide", runID, approvalID,
        "--decision", decision,
        "--actor", Self.agentRunApprovalDecisionActor(requestedFrom: requestedFrom),
        "--role", requestedRole ?? "owner",
        "--dir", corpusRoot.path,
        "--json"
      ]
      if let fingerprint = fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines), !fingerprint.isEmpty {
        arguments.append(contentsOf: ["--fingerprint", fingerprint])
      }
      if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
        arguments.append(contentsOf: ["--note", note])
      }
      if let receipt = receipt?.trimmingCharacters(in: .whitespacesAndNewlines), !receipt.isEmpty {
        arguments.append(contentsOf: ["--receipt", receipt])
      }
      updated = try await cli.runJSON(arguments)
    }
    // A provider-backed decision can also supersede and close older run
    // projections. Reconcile those in the background so a large run archive
    // never blocks the approval row from disappearing. Repeated decisions are
    // coalesced into one scan, and the filesystem watcher remains a fallback.
    scheduleAgentRunsRefresh()
    return updated
  }

  nonisolated static func agentRunApprovalDecisionActor(requestedFrom: String?) -> String {
    let reviewer = requestedFrom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return reviewer.isEmpty ? "Org2Workspace" : reviewer
  }

  nonisolated static func normalizedApprovalRevisionFeedback(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  public func discussApprovalInAIChat(
    _ item: ApprovalItem,
    message: String? = nil,
    threadMode: AIChatThreadMode = .newThread
  ) async {
    let userText = message?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
      ?? "I need to discuss this approval item before deciding."
    let text = automaticAIChatActionText(
      aiChatContextPointer(for: item),
      prompt: item.discussionText,
      userText: userText
    )
    navigateToSurface(.aiChat)
    prepareAIChatThread(
      mode: threadMode,
      title: "Discuss: \(Org2Display.cleanInline(item.title))",
      statusText: "New approval chat"
    )
    await sendAIChatMessage(text: text)
  }

  public func copyApprovalDiscussionText(_ item: ApprovalItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.discussionText, forType: .string)
    statusText = "Copied approval discussion text"
  }

  func syncApprovalSelectionAfterRefresh() {
    guard !visibleApprovalItems.isEmpty else {
      selectedApprovalItemID = nil
      approvalSelectionAnchor = nil
      return
    }
    if let selectedApprovalItemID,
       let selectedItem = visibleApprovalItems.first(where: { $0.id == selectedApprovalItemID }) {
      approvalSelectionAnchor = ApprovalSelectionAnchor(
        item: selectedItem,
        visibleIndex: visibleApprovalItems.firstIndex(where: { $0.id == selectedItem.id })
      )
      return
    }
    if selectedSurface == .approvals {
      let anchoredItem = approvalSelectionAnchor.flatMap { approvalItem(matching: $0) }
      selectApprovalItem(anchoredItem ?? visibleApprovalItems[0])
    }
  }

  private func approvalItem(matching anchor: ApprovalSelectionAnchor) -> ApprovalItem? {
    if let idValue = anchor.idValue,
       let stableIDMatch = visibleApprovalItems.first(where: {
         $0.file == anchor.file
           && $0.idValue?.trimmingCharacters(in: .whitespacesAndNewlines) == idValue
       }) {
      return stableIDMatch
    }

    let titleMatches = visibleApprovalItems.enumerated().filter { _, item in
      item.file == anchor.file && item.title == anchor.title
    }
    if !titleMatches.isEmpty {
      let preferredIndex = anchor.visibleIndex ?? titleMatches[0].offset
      return titleMatches.min(by: { lhs, rhs in
        abs(lhs.offset - preferredIndex) < abs(rhs.offset - preferredIndex)
      })?.element
    }

    guard let visibleIndex = anchor.visibleIndex else { return nil }
    return visibleApprovalItems[min(max(visibleIndex, 0), visibleApprovalItems.count - 1)]
  }

  func rebuildApprovalDisplayCache() {
    let terms = Self.filterTerms(from: approvalFilter)
    let source = showsSnoozedApprovals ? snoozedApprovalItems : approvalItems
    visibleApprovalItems = source.filter { item in
      guard !terms.isEmpty else { return true }
      let searchText = approvalFilterTextByItemID[item.id] ?? item.approvalFilterText
      return terms.allSatisfy { searchText.contains($0) }
    }
    if let selectedApprovalItemID,
       !visibleApprovalItems.contains(where: { $0.id == selectedApprovalItemID }) {
      self.selectedApprovalItemID = nil
    }
    pruneApprovalActionState()
  }

  func rebuildApprovalSearchIndex() {
    var index: [ApprovalItem.ID: String] = [:]
    index.reserveCapacity(approvalItems.count)
    for item in approvalItems {
      index[item.id] = item.approvalFilterText
    }
    approvalFilterTextByItemID = index
  }

  func beginApprovalAction(_ item: ApprovalItem, kind: ApprovalActionKind) {
    beginApprovalAction(item.id, kind: kind)
  }

  func beginApprovalAction(_ itemID: ApprovalItem.ID, kind: ApprovalActionKind) {
    if approvalActionErrorsByItemID[itemID] != nil {
      var errors = approvalActionErrorsByItemID
      errors.removeValue(forKey: itemID)
      approvalActionErrorsByItemID = errors
    }
    approvalSourceRepairRetriesByItemID.removeValue(forKey: itemID)
    switch kind {
    case .approve:
      var ids = approvingApprovalItemIDs
      ids.insert(itemID)
      approvingApprovalItemIDs = ids
    case .reject:
      var ids = rejectingApprovalItemIDs
      ids.insert(itemID)
      rejectingApprovalItemIDs = ids
    case .externalCompletion:
      var ids = externallyCompletingApprovalItemIDs
      ids.insert(itemID)
      externallyCompletingApprovalItemIDs = ids
    case .snooze:
      var ids = snoozingApprovalItemIDs
      ids.insert(itemID)
      snoozingApprovalItemIDs = ids
    }
  }

  private func recordApprovalActionFailure(
    _ item: ApprovalItem,
    error: Error,
    status: String,
    repairRetry: ApprovalSourceRepairRetry? = nil
  ) {
    var errors = approvalActionErrorsByItemID
    errors[item.id] = error.localizedDescription
    approvalActionErrorsByItemID = errors
    if item.isRunApproval,
       let repairRetry,
       Self.isAgentRunSourceDriftError(error.localizedDescription) {
      approvalSourceRepairRetriesByItemID[item.id] = repairRetry
    } else {
      approvalSourceRepairRetriesByItemID.removeValue(forKey: item.id)
    }
    errorText = error.localizedDescription
    statusText = status
  }

  nonisolated static func isAgentRunSourceDriftError(_ message: String) -> Bool {
    message.localizedCaseInsensitiveContains("run source has out-of-band readable-state changes")
  }

  private func finishApprovalSourceRepair(
    _ itemID: ApprovalItem.ID,
    clearsRetry: Bool = true
  ) {
    var repairingIDs = repairingApprovalSourceItemIDs
    repairingIDs.remove(itemID)
    repairingApprovalSourceItemIDs = repairingIDs
    if clearsRetry {
      approvalSourceRepairRetriesByItemID.removeValue(forKey: itemID)
      var errors = approvalActionErrorsByItemID
      errors.removeValue(forKey: itemID)
      approvalActionErrorsByItemID = errors
    }
  }

  func waitForAgentRunMutationAvailability(_ runID: AgentRunItem.ID) async throws {
    while mutatingAgentRunIDs.contains(runID) {
      try Task.checkCancellation()
      try await Task.sleep(nanoseconds: 15_000_000)
    }
    mutatingAgentRunIDs.insert(runID)
  }

  func endApprovalAction(_ item: ApprovalItem, kind: ApprovalActionKind) {
    endApprovalAction(item.id, kind: kind)
  }

  func endApprovalAction(_ itemID: ApprovalItem.ID, kind: ApprovalActionKind) {
    switch kind {
    case .approve:
      var ids = approvingApprovalItemIDs
      ids.remove(itemID)
      approvingApprovalItemIDs = ids
    case .reject:
      var ids = rejectingApprovalItemIDs
      ids.remove(itemID)
      rejectingApprovalItemIDs = ids
    case .externalCompletion:
      var ids = externallyCompletingApprovalItemIDs
      ids.remove(itemID)
      externallyCompletingApprovalItemIDs = ids
    case .snooze:
      var ids = snoozingApprovalItemIDs
      ids.remove(itemID)
      snoozingApprovalItemIDs = ids
    }
  }

  private func pruneApprovalActionState() {
    let itemIDs = Set(approvalItems.map(\.id)).union(snoozedApprovalItems.map(\.id))
    let nextBulkSelectedIDs = bulkSelectedApprovalItemIDs.intersection(itemIDs)
    if nextBulkSelectedIDs != bulkSelectedApprovalItemIDs {
      bulkSelectedApprovalItemIDs = nextBulkSelectedIDs
    }
    let nextErrors = approvalActionErrorsByItemID.filter { itemIDs.contains($0.key) }
    if nextErrors != approvalActionErrorsByItemID {
      approvalActionErrorsByItemID = nextErrors
    }
    approvalSourceRepairRetriesByItemID = approvalSourceRepairRetriesByItemID.filter {
      itemIDs.contains($0.key)
    }
    let nextRepairingIDs = repairingApprovalSourceItemIDs.intersection(itemIDs)
    if nextRepairingIDs != repairingApprovalSourceItemIDs {
      repairingApprovalSourceItemIDs = nextRepairingIDs
    }
  }

  func preserveApprovalSelectionAfterMutation(mutatedID: ApprovalItem.ID, originalVisibleIndex: Int?) {
    guard selectedSurface == .approvals else { return }

    if let item = nextApprovalItem(afterMutating: mutatedID, originalVisibleIndex: originalVisibleIndex) {
      selectApprovalItem(item)
    } else {
      selectedApprovalItemID = nil
      approvalSelectionAnchor = nil
    }
  }

  func requestApprovalRefreshAfterStaleScan(updatesStatus: Bool) {
    approvalRefreshRequestedAfterCurrent = true
    if updatesStatus { approvalRefreshFollowUpUpdatesStatus = true }
  }

  func noteApprovalDecisionLanded() {
    approvalMutationGeneration &+= 1
  }

  nonisolated static func isAgentRun(_ lhs: AgentRunItem, newerThan rhs: AgentRunItem) -> Bool {
    guard let lhsDate = agentRunTimestamp(lhs.updatedAt),
          let rhsDate = agentRunTimestamp(rhs.updatedAt)
    else { return false }
    return lhsDate > rhsDate
  }

  nonisolated private static func agentRunTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
  }

  /// Keeps local runs that are newer than a refreshed list. A list scan can
  /// start before a decision is written and finish after it; without this the
  /// run inspector would briefly (or until the next scan) show the decided
  /// approval as pending again.
  func mergingNewerLocalRuns(into refreshedRuns: [AgentRunItem]) -> [AgentRunItem] {
    guard !agentRuns.isEmpty else { return refreshedRuns }
    let localByID = Dictionary(agentRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return refreshedRuns.map { refreshed in
      guard let local = localByID[refreshed.id], Self.isAgentRun(local, newerThan: refreshed) else {
        return refreshed
      }
      return local
    }
  }

  private func removeApprovalItemOptimistically(_ id: ApprovalItem.ID, originalVisibleIndex: Int?) {
    noteApprovalDecisionLanded()
    bulkSelectedApprovalItemIDs.remove(id)
    approvalItems.removeAll { $0.id == id }
    snoozedApprovalItems.removeAll { $0.id == id }
    preserveApprovalSelectionAfterMutation(mutatedID: id, originalVisibleIndex: originalVisibleIndex)
  }

  func scheduleApprovalsRefresh(updatesStatus: Bool = false) {
    scheduledApprovalsRefreshTask?.cancel()
    scheduledApprovalsRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      await self.refreshApprovals(updatesStatus: updatesStatus)
      if !Task.isCancelled {
        self.scheduledApprovalsRefreshTask = nil
      }
    }
  }

  private func scheduleAgentRunsRefresh() {
    scheduledAgentRunsRefreshTask?.cancel()
    scheduledAgentRunsRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(nanoseconds: self.deferredAgentRunsRefreshDelayNanoseconds)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self.refreshAgentRuns()
      if !Task.isCancelled {
        self.scheduledAgentRunsRefreshTask = nil
      }
    }
  }

  private func nextApprovalItem(afterMutating mutatedID: ApprovalItem.ID, originalVisibleIndex: Int?) -> ApprovalItem? {
    if let current = visibleApprovalItems.first(where: { $0.id == mutatedID }) {
      return current
    }

    guard !visibleApprovalItems.isEmpty else { return nil }
    let fallbackIndex = originalVisibleIndex ?? 0
    let boundedIndex = min(max(fallbackIndex, 0), visibleApprovalItems.count - 1)
    return visibleApprovalItems[boundedIndex]
  }

  nonisolated static func approvalItems(
    in document: Org2CanonicalDocument,
    file: String,
    sourceText: String,
    sourceLineOffset: Int = 0
  ) -> [ApprovalItem] {
    let lines = normalizeLineEndings(sourceText)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var items: [ApprovalItem] = []
    appendApprovalItems(
      from: document.children,
      file: file,
      sourceLines: lines,
      sourceLineOffset: sourceLineOffset,
      into: &items
    )
    return sortedApprovalItems(items)
  }

  nonisolated private static func appendApprovalItems(
    from nodes: [Org2CanonicalNode],
    file: String,
    sourceLines: [String],
    sourceLineOffset: Int,
    into items: inout [ApprovalItem]
  ) {
    for node in nodes {
      guard case .headline(let headline) = node else { continue }
      appendApprovalItem(
        from: headline,
        file: file,
        sourceLines: sourceLines,
        sourceLineOffset: sourceLineOffset,
        into: &items
      )
      appendApprovalItems(
        from: headline.children,
        file: file,
        sourceLines: sourceLines,
        sourceLineOffset: sourceLineOffset,
        into: &items
      )
    }
  }

  nonisolated private static func appendApprovalItem(
    from headline: Org2CanonicalHeadline,
    file: String,
    sourceLines: [String],
    sourceLineOffset: Int,
    into items: inout [ApprovalItem]
  ) {
    let todo = headline.todo?.uppercased()
    guard !isTerminalTodo(todo),
          let sourceRange = headline.sourceRange
    else {
      return
    }

    let properties = canonicalHeadlineProperties(headline)
    let title = approvalTitle(canonicalInlineText(headline.title))
    guard let status = approvalStatus(title: title, properties: properties) else { return }

    items.append(ApprovalItem(
      title: title,
      status: status,
      todo: todo,
      level: headline.level,
      file: file,
      line: sourceRange.startLine,
      idValue: properties["ID"],
      properties: properties,
      body: approvalBody(
        sourceLines: sourceLines,
        sourceLineOffset: sourceLineOffset,
        sourceRange: sourceRange,
        children: headline.children
      ),
      tags: headline.tags ?? []
    ))
  }

  nonisolated private static func canonicalHeadlineProperties(_ headline: Org2CanonicalHeadline) -> [String: String] {
    for child in headline.children {
      guard case .propertyDrawer(let drawer) = child else { continue }
      return Dictionary(uniqueKeysWithValues: drawer.properties.map { ($0.key.uppercased(), $0.value) })
    }
    return [:]
  }

  nonisolated private static func approvalBody(
    sourceLines: [String],
    sourceLineOffset: Int,
    sourceRange: Org2CanonicalSourceRange,
    children: [Org2CanonicalNode]
  ) -> String {
    let startLine = max(1, sourceRange.startLine + 1)
    let endLine = max(startLine, sourceRange.endLine)
    guard startLine <= endLine, !sourceLines.isEmpty else { return "" }

    let hiddenRanges = children.compactMap { child -> ClosedRange<Int>? in
      switch child {
      case .propertyDrawer(let drawer):
        guard let range = drawer.sourceRange else { return nil }
        return range.startLine...range.endLine
      case .planning(let planning):
        guard let range = planning.sourceRange else { return nil }
        return range.startLine...range.endLine
      default:
        return nil
      }
    }

    var bodyLines: [String] = []
    for lineNumber in startLine...endLine {
      let sourceIndex = lineNumber - sourceLineOffset - 1
      guard sourceLines.indices.contains(sourceIndex),
            !hiddenRanges.contains(where: { $0.contains(lineNumber) })
      else {
        continue
      }
      bodyLines.append(sourceLines[sourceIndex])
    }
    return bodyLines
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func approvalStatus(title: String, properties: [String: String]) -> String? {
    let status = firstPropertyText(
      in: properties,
      keys: [
        "ORG2_REVIEW_STATUS",
        "REVIEW_STATUS",
        "REVIEW",
        "STATUS",
        "FOLLOWUP_STATUS",
        "REPLY_STATUS"
      ]
    )
    if let status, isPendingApprovalStatus(status), titleNeedsHumanApproval(title) {
      return status
    }

    let waitingOn = firstPropertyText(in: properties, keys: ["WAITING_ON", "BLOCKED_BY", "ORG2_WAITING_ON"]) ?? ""
    if containsApprovalSignal(waitingOn) {
      return waitingOn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "approval-required" : waitingOn
    }

    let nextAction = firstPropertyText(in: properties, keys: ["NEXT_ACTION", "ACTION_REQUIRED", "ORG2_NEXT_ACTION"]) ?? ""
    if containsApprovalSignal(nextAction) {
      return "approval-required"
    }

    let handoff = firstPropertyText(in: properties, keys: ["HANDOFF_SUMMARY", "ORG2_HANDOFF_SUMMARY"]) ?? ""
    if containsApprovalSignal(handoff) {
      return "approval-required"
    }

    let accessPolicy = firstPropertyText(in: properties, keys: ["ACCESS_POLICY", "REVIEW_POLICY"]) ?? ""
    if isPendingApprovalStatus(accessPolicy) || containsApprovalSignal(accessPolicy) {
      return accessPolicy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "approval-required" : accessPolicy
    }

    return nil
  }

  nonisolated private static func firstPropertyText(in properties: [String: String], keys: [String]) -> String? {
    for key in CelorgaNames.withAliases(keys) {
      let value = properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
      if value?.isEmpty == false {
        return value
      }
    }
    return nil
  }

  nonisolated private static func isPendingApprovalStatus(_ raw: String) -> Bool {
    let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if [
      "review-required",
      "requires-review",
      "approval-required",
      "needs-approval",
      "needs-review",
      "pending-review",
      "pending-approval",
      "require-approval",
      "generated",
      "draft"
    ].contains(normalized) {
      return true
    }

    return normalized.contains("needs-review")
      || normalized.contains("need-review")
      || normalized.contains("needs-approval")
      || normalized.contains("need-approval")
      || normalized.contains("waiting-on-approval")
      || normalized.contains("pending-review")
      || normalized.contains("pending-approval")
      || normalized.contains("draft-needs-review")
      || normalized.contains("draft-needs-approval")
      || normalized.contains("reply-review")
      || normalized.contains("needs-avi")
      || normalized.contains("avi-approval")
      || normalized.contains("needs-human")
      || normalized.contains("human-review")
  }

  nonisolated private static func titleNeedsHumanApproval(_ title: String) -> Bool {
    let normalized = approvalTitle(title).lowercased()
    return normalized.hasPrefix("approve ")
      || normalized.hasPrefix("review ")
      || normalized.hasPrefix("review/")
      || normalized.hasPrefix("review-send ")
      || normalized.hasPrefix("review and approve ")
      || normalized.hasPrefix("review/approve ")
  }

  nonisolated static func approvalTitle(_ raw: String) -> String {
    Org2Display.cleanInline(raw)
      .replacingOccurrences(
        of: #"^\s*\[#[A-Za-z0-9]\](?:\s+|$)"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated static func containsApprovalSignal(_ raw: String) -> Bool {
    let normalized = raw.lowercased()
    return normalized.contains("approval")
      || normalized.contains("approve")
      || normalized.contains("review")
      || normalized.contains("avi")
  }

  nonisolated private static func isTerminalTodo(_ todo: String?) -> Bool {
    guard let todo else { return false }
    return todo == "DONE" || todo == "CANCELED" || todo == "CANCELLED"
  }

  nonisolated static func canonicalInlineText(_ inlines: [Org2CanonicalInline]) -> String {
    inlines.map(canonicalInlineText).joined()
  }

  nonisolated static func canonicalInlineText(_ inline: Org2CanonicalInline) -> String {
    switch inline {
    case .text(let text):
      return text.value
    case .timestamp(let timestamp):
      return timestamp.raw
    case .timestampRange(let range):
      return "\(range.start.raw)\(range.separatorRaw)\(range.end.raw)"
    case .emphasis(let emphasis):
      return "\(emphasis.marker)\(emphasis.content)\(emphasis.marker)"
    case .link(let link):
      return link.descriptionRaw ?? link.targetRaw
    case .progressCookie(let raw):
      return raw
    case .unsupported(let type):
      return type
    }
  }

  nonisolated static func sortedApprovalItems(_ items: [ApprovalItem]) -> [ApprovalItem] {
    items.sorted { lhs, rhs in
      let statusOrder = lhs.status.localizedCaseInsensitiveCompare(rhs.status)
      if statusOrder != .orderedSame { return statusOrder == .orderedAscending }
      let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
      if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
      if lhs.file != rhs.file { return lhs.file.localizedStandardCompare(rhs.file) == .orderedAscending }
      return lhs.line < rhs.line
    }
  }

  func scheduleSearchIndexBuild(corpusRoot: URL, sessionGeneration: UInt64) {
    searchIndexGeneration += 1
    let generation = searchIndexGeneration
    searchIndexTask?.cancel()
    isBuildingSearchIndex = true
    searchIndexStatusText = "Indexing search..."

    searchIndexTask = Task { [cli] in
      if cli.hasSearchService {
        // Serve searches from the existing index while it is rebuilt.
        Task.detached(priority: .utility) { await cli.prewarmSearchService(corpusRoot: corpusRoot) }
      }
      do {
        let payload: SearchIndexBuildPayload = try await cli.runJSON([
          "index",
          "--dir", corpusRoot.path,
          "--recursive",
          "--format", "json"
        ])
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard self.searchIndexGeneration == generation,
                self.isCurrentCorpusSession(
                  root: corpusRoot,
                  generation: sessionGeneration
                )
          else { return }
          self.isBuildingSearchIndex = false
          let skipped = payload.skippedFiles > 0 ? ", \(payload.skippedFiles) skipped" : ""
          self.searchIndexStatusText = "\(payload.fileCount) files, \(payload.lineCount) lines indexed\(skipped)"
        }
        // Load the fresh index into the search worker now, so the first
        // query after launch or a corpus change does not pay for it.
        guard !Task.isCancelled, cli.hasSearchService else { return }
        await cli.prewarmSearchService(corpusRoot: corpusRoot)
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard self.searchIndexGeneration == generation,
                self.isCurrentCorpusSession(
                  root: corpusRoot,
                  generation: sessionGeneration
                )
          else { return }
          self.isBuildingSearchIndex = false
          self.searchIndexStatusText = "Search index unavailable"
        }
      }
    }
  }

  public func runSearch() async {
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.search, default: 0]
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = captureWorkspaceSearchRequest(query: query)
    guard !query.isEmpty else {
      isSearching = false
      searchResults = []
      aiChatSearchResults = []
      workspaceFileSearchResults = []
      workspacePageSearchResults = []
      workspaceAgentWorkSearchResults = []
      markWorkspaceSurfaceCleanIfUnchanged(.search, generation: dirtyGeneration)
      return
    }
    isSearching = true
    errorText = nil
    statusText = "Searching workspace..."
    defer {
      if isCurrentWorkspaceSearchRequest(request) {
        isSearching = false
      }
    }

    let started = Date()
    let requestedCorpusRoot = corpusRoot?.standardizedFileURL
    // Every source runs concurrently; chat search reuses cached transcript
    // text and reads only threads that changed since the last search.
    let chatSearchTask = aiChatWorkspaceSearchTask(query: query)
    guard let corpusRoot = requestedCorpusRoot else {
      let chatResults = await chatSearchTask.value
      guard !Task.isCancelled,
            isCurrentWorkspaceSearchRequest(request)
      else { return }
      workspaceSearchRankingQuery = query
      searchResults = []
      aiChatSearchResults = chatResults
      workspaceFileSearchResults = []
      workspacePageSearchResults = []
      workspaceAgentWorkSearchResults = []
      let elapsed = Date().timeIntervalSince(started)
      statusText = chatResults.isEmpty
        ? "No corpus selected"
        : "\(chatResults.count) chat result\(chatResults.count == 1 ? "" : "s") in \(String(format: "%.1f", elapsed))s"
      markWorkspaceSurfaceCleanIfUnchanged(.search, generation: dirtyGeneration)
      return
    }

    let runs = agentRuns
    let approvals = approvalItems
    let workflows = agentWorkflows
    let goals = agentGoals
    let profiles = agentProfiles
    let agentWorkSearchTask = Task.detached(priority: .userInitiated) {
      Self.searchAgentWorkForWorkspace(
        runs: runs,
        approvals: approvals,
        workflows: workflows,
        goals: goals,
        profiles: profiles,
        query: query,
        limitPerCategory: 25
      )
    }

    do {
      let files = request.readScope == .activeCorpus ? corpusFiles : []
      let pageNodes = request.readScope == .activeCorpus ? orgRoamLinkResolver.nodes.filter(\.isPageNode) : []
      async let supplementalResults = Task.detached(priority: .userInitiated) {
        let resolvedPageNodes = pageNodes.isEmpty
          ? files.compactMap(Self.scanRoamFileNode)
          : pageNodes
        return (
          Self.searchCorpusFilesForWorkspace(files, query: query, limit: 25),
          Self.searchPageNodesForWorkspace(resolvedPageNodes, query: query, limit: 25)
        )
      }.value
      let federates = request.readScope == .allCorpora && workspaceMountPaths().count > 1
      var arguments = federates
        ? ["workspace", "search", query] + workspaceMountArguments()
        : ["search", query, "--dir", corpusRoot.path]
      arguments += [
        "--recursive",
        "--limit", String(Self.workspaceSearchCandidateLimit),
        "--context", "1",
        "--index", federates ? "auto" : "current",
        "--sort", "best",
        "--format", "json"
      ]
      let payload: SearchPayload
      if let workspaceSearchLoaderForTesting {
        payload = try await workspaceSearchLoaderForTesting(query, arguments)
      } else if !federates, cli.hasSearchService {
        // The warm worker answers in well under a second; a one-shot CLI
        // process spends seconds starting Node and reading the index.
        do {
          payload = try await cli.searchIndexedCorpus(
            query,
            corpusRoot: corpusRoot,
            limit: Self.workspaceSearchCandidateLimit,
            context: 1
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          payload = try await cli.runJSON(arguments)
        }
      } else {
        payload = try await cli.runJSON(arguments)
      }
      guard !Task.isCancelled,
            isCurrentWorkspaceSearchRequest(request)
      else { return }
      let (fileResults, pageResults) = await supplementalResults
      guard !Task.isCancelled,
            isCurrentWorkspaceSearchRequest(request)
      else { return }
      let agentWorkResults = await agentWorkSearchTask.value
      let chatResults = await chatSearchTask.value
      guard !Task.isCancelled,
            isCurrentWorkspaceSearchRequest(request)
      else { return }
      let resultPaths = Set(payload.results.map(\.file))
      var modifiedAtByPath: [String: Date] = [:]
      for file in files where resultPaths.contains(file.path) {
        modifiedAtByPath[file.path] = file.modifiedAt
      }
      let prioritizedResults = Self.prioritizedSearchResultsForDisplay(
        payload.results,
        query: query,
        limit: Self.workspaceSearchDisplayLimit,
        modifiedAtByPath: modifiedAtByPath
      )
      let totalCount = prioritizedResults.count
        + chatResults.count
        + fileResults.count
        + pageResults.count
        + agentWorkResults.count
      workspaceSearchRankingQuery = query
      searchResults = prioritizedResults
      aiChatSearchResults = chatResults
      workspaceFileSearchResults = fileResults
      workspacePageSearchResults = pageResults
      workspaceAgentWorkSearchResults = agentWorkResults
      let elapsed = Date().timeIntervalSince(started)
      let issueSuffix = payload.issues?.isEmpty == false ? ", \(payload.issues!.count) corpus issue\(payload.issues!.count == 1 ? "" : "s")" : ""
      statusText = "\(totalCount) search result\(totalCount == 1 ? "" : "s") in \(String(format: "%.1f", elapsed))s\(issueSuffix)"
      markWorkspaceSurfaceCleanIfUnchanged(.search, generation: dirtyGeneration)
    } catch {
      let agentWorkResults = await agentWorkSearchTask.value
      let chatResults = await chatSearchTask.value
      guard !Task.isCancelled,
            isCurrentWorkspaceSearchRequest(request)
      else { return }
      workspaceSearchRankingQuery = query
      aiChatSearchResults = chatResults
      workspaceAgentWorkSearchResults = agentWorkResults
      errorText = error.localizedDescription
      statusText = "Search failed"
    }
  }

  private func aiChatWorkspaceSearchTask(query: String) -> Task<[AIChatSearchResult], Never> {
    let metadata = aiChatThreads
    let transcriptURL = aiChatTranscriptURL
    return Task.detached(priority: .userInitiated) {
      let documents = Self.aiChatSearchDocuments(metadata: metadata, transcriptURL: transcriptURL)
      return Self.searchAIChatDocuments(documents, query: query, limit: 25)
    }
  }

  /// Loads chat text into the search cache ahead of the first query, so
  /// opening search does not pay for decoding every transcript on Return.
  public func warmAIChatSearchIndex() {
    let metadata = aiChatThreads
    let transcriptURL = aiChatTranscriptURL
    Task.detached(priority: .utility) {
      _ = Self.aiChatSearchDocuments(metadata: metadata, transcriptURL: transcriptURL)
    }
  }

  nonisolated private static func aiChatSearchDocuments(
    metadata: [AIChatThread],
    transcriptURL: URL
  ) -> [AIChatSearchDocument] {
    AIChatSearchIndex.shared.documents(for: metadata, transcriptURL: transcriptURL) { thread in
      AIChatTranscriptStore.shared.loadThread(id: thread.id, metadata: thread, legacyURL: transcriptURL)
    }
  }

  public func refreshMeetings() async {
    guard let corpusRoot else {
      meetings = []
      return
    }
    let sessionGeneration = corpusSessionGeneration

    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.meetings, default: 0]
    isLoadingMeetings = true
    defer {
      if isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) {
        isLoadingMeetings = false
      }
    }

    do {
      let items = try await Task.detached(priority: .utility) {
        try Self.scanMeetingItems(corpusRoot: corpusRoot)
      }.value
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      meetings = items
      if selectedSurface == .meetings {
        statusText = "\(items.count) meeting\(items.count == 1 ? "" : "s")"
      }
      reconcileMeetingProcessingState(with: items)
      syncMeetingSelectionAfterRefresh()
      recoverInterruptedMeetingTranscriptions(knownItems: items)
      markWorkspaceSurfaceCleanIfUnchanged(.meetings, generation: dirtyGeneration)
    } catch {
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      errorText = error.localizedDescription
      statusText = "Meeting scan failed"
    }
  }

  public func promptAndStartMeetingRecording() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    guard !isRecordingMeeting else { return }

    let alert = NSAlert()
    alert.messageText = "Record Meeting"
    alert.informativeText = "Record local microphone audio into the selected Celorga corpus."
    alert.addButton(withTitle: "Start Recording")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = "Meeting title"
    // A meeting in progress on a synced calendar fills in the title, and
    // keeping it records the event and its attendees with the meeting.
    let currentEvent = CalendarRecordingPromptPolicy.currentMeeting(in: calendarMeetingEvents, now: Date())
    field.stringValue = meetingTitleDraft.isEmpty ? (currentEvent?.title ?? "") : meetingTitleDraft
    if let currentEvent {
      alert.informativeText += " Calendar: \(currentEvent.title), \(currentEvent.otherAttendees.count) attendee\(currentEvent.otherAttendees.count == 1 ? "" : "s")."
    }
    alert.accessoryView = field

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    meetingTitleDraft = field.stringValue
    let event = currentEvent.flatMap { event in
      field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == event.title ? event : nil
    }
    Task { await startMeetingRecording(title: field.stringValue, calendarEvent: event) }
  }

  // MARK: Calendar recording prompts

  private static let calendarPromptsEnabledKey = "Org2Workspace.calendarRecordingPrompts.enabled.v1"
  private static let calendarPromptedKeysKey = "Org2Workspace.calendarRecordingPrompts.prompted.v1"
  public static let calendarPromptCheckIntervalNanoseconds: UInt64 = 20_000_000_000

  public var calendarRecordingPromptsEnabled: Bool {
    defaults.object(forKey: Self.calendarPromptsEnabledKey) as? Bool ?? true
  }

  public func setCalendarRecordingPromptsEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.calendarPromptsEnabledKey)
    if !enabled { dismissCalendarRecordingPrompt() }
  }

  /// Desktop only: watches synced calendar events and offers to record each
  /// meeting as it starts. Headless servers never prompt.
  public func setCalendarRecordingPromptsActive(
    _ isActive: Bool,
    checkIntervalNanoseconds: UInt64 = WorkspaceStore.calendarPromptCheckIntervalNanoseconds
  ) {
    calendarRecordingPromptTask?.cancel()
    calendarRecordingPromptTask = nil
    guard isActive else { return }
    calendarRecordingPromptTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.checkCalendarRecordingPrompt()
        do { try await Task.sleep(nanoseconds: checkIntervalNanoseconds) } catch { return }
      }
    }
  }

  func reloadCalendarMeetingEvents() async {
    guard let corpusRoot else {
      calendarMeetingEvents = []
      return
    }
    let zones = sourceProfiles.filter { $0.type == "google-calendar" }.map(\.rawZone)
    let events = await Task.detached(priority: .utility) {
      CalendarMeetingEventLoader.load(corpusRoot: corpusRoot, extraRawZones: zones)
    }.value
    guard self.corpusRoot == corpusRoot else { return }
    if events != calendarMeetingEvents { calendarMeetingEvents = events }
  }

  func checkCalendarRecordingPrompt(now: Date = Date()) async {
    await reloadCalendarMeetingEvents()
    if let prompt = calendarRecordingPrompt,
       !CalendarRecordingPromptPolicy.isInPromptWindow(prompt, now: now) || isRecordingMeeting {
      dismissCalendarRecordingPrompt()
    }
    guard calendarRecordingPromptsEnabled, !isRecordingMeeting, calendarRecordingPrompt == nil else { return }
    var prompted = promptedCalendarEventKeys(now: now)
    guard let event = CalendarRecordingPromptPolicy.candidate(
      in: calendarMeetingEvents,
      now: now,
      alreadyPrompted: Set(prompted.keys)
    ) else { return }
    prompted[event.promptKey] = now.timeIntervalSince1970
    defaults.set(prompted, forKey: Self.calendarPromptedKeysKey)
    calendarRecordingPrompt = event
    calendarRecordingPromptPresenter?(event)
  }

  /// Offered occurrences from the last two days, so each is offered once.
  private func promptedCalendarEventKeys(now: Date) -> [String: Double] {
    let stored = defaults.dictionary(forKey: Self.calendarPromptedKeysKey) as? [String: Double] ?? [:]
    let cutoff = now.addingTimeInterval(-2 * 24 * 60 * 60).timeIntervalSince1970
    return stored.filter { $0.value >= cutoff }
  }

  public func dismissCalendarRecordingPrompt() {
    guard calendarRecordingPrompt != nil else { return }
    calendarRecordingPrompt = nil
    calendarRecordingPromptPresenter?(nil)
  }

  /// Starts recording the offered meeting with its title, time, link, and
  /// attendees; optionally opens its video call first.
  public func recordCalendarMeeting(_ event: CalendarMeetingEvent, joinCall: Bool = false) async {
    dismissCalendarRecordingPrompt()
    if joinCall, let raw = event.meetingUrl, let url = URL(string: raw),
       ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
      NSWorkspace.shared.open(url)
    }
    await startMeetingRecording(title: event.title, calendarEvent: event)
  }

  nonisolated private static func meetingArtifactsDirectory(corpusRoot: URL) -> URL {
    corpusRoot.standardizedFileURL.appendingPathComponent("meetings", isDirectory: true)
  }

  private func prepareMeetingArtifactPaths(
    corpusRoot: URL,
    title: String,
    recordedAt: Date,
    audioExtension: String = "wav"
  ) async throws -> MeetingArtifactPaths {
    let directory = Self.meetingArtifactsDirectory(corpusRoot: corpusRoot)
    return try await documentMutationLane.perform(
      rootPath: corpusRoot.path,
      resourcePaths: [directory.path]
    ) { execution in
      _ = try execution.authorizeDescendant(directory, ofDeclaredDirectory: directory)
      return try MeetingArtifactWriter.preparePaths(
        corpusRoot: corpusRoot,
        title: title,
        recordedAt: recordedAt,
        audioExtension: audioExtension
      )
    }
  }

  private func importMeetingArtifactPaths(
    sourceURL: URL,
    corpusRoot: URL,
    title: String,
    recordedAt: Date,
    audioExtension: String
  ) async throws -> MeetingArtifactPaths {
    let directory = Self.meetingArtifactsDirectory(corpusRoot: corpusRoot)
    return try await documentMutationLane.perform(
      rootPath: corpusRoot.path,
      resourcePaths: [directory.path]
    ) { execution in
      _ = try execution.authorizeDescendant(directory, ofDeclaredDirectory: directory)
      let paths = try MeetingArtifactWriter.preparePaths(
        corpusRoot: corpusRoot,
        title: title,
        recordedAt: recordedAt,
        audioExtension: audioExtension
      )
      let destination = try execution.authorizeDescendant(
        paths.audioURL,
        ofDeclaredDirectory: directory
      )
      try FileManager.default.copyItem(at: sourceURL, to: destination)
      return paths
    }
  }

  private func writeMeetingArtifacts(
    paths: MeetingArtifactPaths,
    corpusRoot: URL,
    duration: TimeInterval?,
    transcript: MeetingTranscriptResult,
    systemAudioURL: URL? = nil,
    captureSources: String? = nil
  ) async throws -> MeetingArtifactBundle {
    let directory = Self.meetingArtifactsDirectory(corpusRoot: corpusRoot)
    return try await documentMutationLane.perform(
      rootPath: corpusRoot.path,
      resourcePaths: [directory.path]
    ) { execution in
      _ = try execution.authorizeDescendant(paths.noteURL, ofDeclaredDirectory: directory)
      _ = try execution.authorizeDescendant(paths.transcriptURL, ofDeclaredDirectory: directory)
      return try MeetingArtifactWriter.writeArtifacts(
        paths: paths,
        corpusRoot: corpusRoot,
        duration: duration,
        transcript: transcript,
        systemAudioURL: systemAudioURL,
        captureSources: captureSources
      )
    }
  }

  private func removeMeetingArtifacts(
    _ urls: [URL],
    corpusRoot: URL
  ) async throws {
    let directory = Self.meetingArtifactsDirectory(corpusRoot: corpusRoot)
    try await documentMutationLane.perform(
      rootPath: corpusRoot.path,
      resourcePaths: [directory.path] + urls.map(\.path)
    ) { execution in
      for rawURL in urls {
        let url = try execution.authorizeDescendant(rawURL, ofDeclaredDirectory: directory)
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
      }
    }
  }

  public func startMeetingRecording(title rawTitle: String, calendarEvent: CalendarMeetingEvent? = nil) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    guard !isRecordingMeeting else {
      meetingStatusText = "A meeting is already recording"
      return
    }

    do {
      let startedAt = Date()
      var paths = try await prepareMeetingArtifactPaths(
        corpusRoot: corpusRoot,
        title: rawTitle,
        recordedAt: startedAt
      )
      if let calendarEvent {
        paths.calendar = MeetingCalendarContext(event: calendarEvent)
      }
      // The recorder creates its audio file before either capture stream has
      // fully started. Exclude that path immediately so a concurrent meeting
      // refresh cannot mistake the live file for an interrupted recording.
      meetingRecordingRecoveryExclusionPaths = paths
      cancelMeetingSystemAudioRecovery()
      meetingSystemAudioRecoverySuppressed = false
      // A prior interrupted stop must never poison the next meeting. Explicitly
      // tear down any leftover ScreenCaptureKit stream and writer before
      // starting the microphone or creating the new system-audio artifact.
      await meetingSystemAudioRecorder.discardRecording()
      try await meetingRecorder.startRecording(to: paths.audioURL)
      let systemAudioStartError: String?
      do {
        try await startMeetingSystemAudioRecordingWithRetry(to: paths.systemAudioURL)
        isCapturingSystemAudio = true
        meetingSystemAudioStatusText = "System audio recording"
        systemAudioStartError = nil
      } catch {
        isCapturingSystemAudio = false
        meetingSystemAudioStatusText = "System audio unavailable: \(error.localizedDescription)"
        systemAudioStartError = error.localizedDescription
      }
      activeMeetingRecording = PendingMeetingRecording(
        paths: paths,
        capturesSystemAudio: systemAudioStartError == nil,
        systemAudioStartError: systemAudioStartError
      )
      isRecordingMeeting = true
      dismissCalendarRecordingPrompt()
      isMeetingRecordingPaused = false
      startMeetingInputMetering()
      selectedSurface = .meetings
      meetingStatusText = "Recording \(paths.title)"
      statusText = meetingStatusText
      await openLiveMeetingNote(paths: paths, corpusRoot: corpusRoot)
    } catch {
      meetingRecordingRecoveryExclusionPaths = nil
      isCapturingSystemAudio = false
      isMeetingRecordingPaused = false
      meetingSystemAudioStatusText = "System audio not recording"
      stopMeetingInputMetering()
      errorText = error.localizedDescription
      meetingStatusText = "Recording failed: \(error.localizedDescription)"
      statusText = "Recording failed"
    }
  }

  /// Creates the meeting note as recording starts and opens it beside the
  /// meeting list, so notes can be taken during the meeting. The finished
  /// recording later fills in its metadata and transcript in place.
  private func openLiveMeetingNote(paths: MeetingArtifactPaths, corpusRoot: URL) async {
    let context = captureAIChatCorpusContext()
    let directory = Self.meetingArtifactsDirectory(corpusRoot: corpusRoot)
    let item: MeetingWorkspaceItem
    do {
      item = try await documentMutationLane.perform(
        rootPath: corpusRoot.path,
        resourcePaths: [directory.path]
      ) { execution in
        _ = try execution.authorizeDescendant(paths.noteURL, ofDeclaredDirectory: directory)
        return try MeetingArtifactWriter.writeLiveMeetingNote(paths: paths, corpusRoot: corpusRoot)
      }
    } catch {
      // Recording continues; the note is written when the recording stops.
      guard isCurrentAIChatCorpusContext(context) else { return }
      statusText = "Recording \(paths.title); live note unavailable: \(error.localizedDescription)"
      return
    }
    guard isCurrentAIChatCorpusContext(context),
          activeMeetingRecording?.paths.noteURL == paths.noteURL
    else {
      return
    }
    if let existingIndex = meetings.firstIndex(where: { $0.file == item.file }) {
      meetings[existingIndex] = item
    } else {
      meetings.insert(item, at: 0)
    }
    selectMeeting(item)
    markWorkspaceSurfacesDirty([.agenda, .files, .search], refreshVisible: false)
  }

  /// Saves pending edits to a live meeting note before the finished
  /// recording updates the same file.
  private func savePendingEditsToMeetingNote(_ noteURL: URL) async {
    guard let file = selectedLocation?.file ?? selectedEntrySource?.file,
          URL(fileURLWithPath: file).standardizedFileURL.path == noteURL.standardizedFileURL.path
    else {
      return
    }
    _ = await savePendingEditsBeforeExport(
      blockedStatus: "Meeting note has unsaved edits; resolve them to keep both versions"
    )
  }

  public func stopMeetingRecording() async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    guard let recording = activeMeetingRecording else {
      meetingStatusText = "No active recording"
      return
    }
    guard !isStoppingMeetingRecording else { return }
    isStoppingMeetingRecording = true
    defer { isStoppingMeetingRecording = false }
    let context = captureAIChatCorpusContext()
    cancelMeetingSystemAudioRecovery()

    do {
      let duration = try meetingRecorder.stopRecording()
      var systemAudioURL: URL?
      var systemAudioCaptureError = recording.systemAudioStartError
      if recording.capturesSystemAudio {
        do {
          let result = try await meetingSystemAudioRecorder.stopRecordingWithResult()
          systemAudioCaptureError = result.captureErrorDescription
          if result.hasCapturedAudio {
            systemAudioURL = recording.paths.systemAudioURL
          } else {
            try? await removeMeetingArtifacts(
              [recording.paths.systemAudioURL],
              corpusRoot: corpusRoot
            )
            systemAudioCaptureError = "No system audio samples were captured."
          }
        } catch {
          // A writer failure may still leave useful diagnostic or recoverable
          // media. Keep any non-empty artifact instead of destroying it.
          if Self.fileHasContent(recording.paths.systemAudioURL) {
            systemAudioURL = recording.paths.systemAudioURL
          } else {
            try? await removeMeetingArtifacts(
              [recording.paths.systemAudioURL],
              corpusRoot: corpusRoot
            )
          }
          systemAudioCaptureError = error.localizedDescription
        }
      }
      self.activeMeetingRecording = nil
      isRecordingMeeting = false
      isMeetingRecordingPaused = false
      isCapturingSystemAudio = false
      stopMeetingInputMetering()
      guard isCurrentAIChatCorpusContext(context) else {
        meetingRecordingRecoveryExclusionPaths = nil
        Task { [weak self] in
          await self?.finishStoppedMeetingRecording(
            recording,
            corpusRoot: corpusRoot,
            duration: duration,
            systemAudioURL: systemAudioURL,
            systemAudioCaptureError: systemAudioCaptureError,
            progressID: UUID(),
            context: context
          )
        }
        return
      }
      beginMeetingProcessing(paths: recording.paths, status: "Transcribing \(recording.paths.title) locally...")
      meetingRecordingRecoveryExclusionPaths = nil
      let progressID = startMeetingTranscriptionProgress(
        title: recording.paths.title,
        audioDuration: duration
      )
      Task { [weak self] in
        await self?.finishStoppedMeetingRecording(
          recording,
          corpusRoot: corpusRoot,
          duration: duration,
          systemAudioURL: systemAudioURL,
          systemAudioCaptureError: systemAudioCaptureError,
          progressID: progressID,
          context: context
        )
      }
    } catch {
      isRecordingMeeting = false
      isMeetingRecordingPaused = false
      // Recorder state is authoritative here. The UI flag is cleared as soon
      // as an interruption is detected, so conditioning cleanup on that flag
      // can strand a failed SCStream until the app is relaunched.
      await meetingSystemAudioRecorder.discardRecording()
      self.activeMeetingRecording = nil
      meetingRecordingRecoveryExclusionPaths = nil
      isCapturingSystemAudio = false
      stopMeetingInputMetering()
      guard isCurrentAIChatCorpusContext(context) else { return }
      meetingSystemAudioStatusText = "System audio not recording"
      errorText = error.localizedDescription
      meetingStatusText = "Stop failed: \(error.localizedDescription)"
      statusText = "Recording stop failed"
    }
  }

  public func pauseMeetingRecording() async {
    guard isRecordingMeeting, !isMeetingRecordingPaused else { return }
    guard let activeMeetingRecording else {
      meetingStatusText = "No active recording"
      return
    }

    cancelMeetingSystemAudioRecovery()
    do {
      try meetingRecorder.pauseRecording()
      if activeMeetingRecording.capturesSystemAudio {
        try await meetingSystemAudioRecorder.pauseRecording()
      }
      isMeetingRecordingPaused = true
      stopMeetingInputMetering()
      meetingStatusText = "Paused \(activeMeetingRecording.paths.title)"
      statusText = meetingStatusText
    } catch {
      errorText = error.localizedDescription
      meetingStatusText = "Pause failed: \(error.localizedDescription)"
      statusText = "Recording pause failed"
    }
  }

  public func resumeMeetingRecording() async {
    guard isRecordingMeeting, isMeetingRecordingPaused else { return }
    guard let activeMeetingRecording else {
      meetingStatusText = "No active recording"
      return
    }

    meetingSystemAudioRecoverySuppressed = false
    do {
      try meetingRecorder.resumeRecording()
      if activeMeetingRecording.capturesSystemAudio {
        try await meetingSystemAudioRecorder.resumeRecording()
        isCapturingSystemAudio = true
        meetingSystemAudioStatusText = meetingSystemAudioRecorder.captureErrorDescription == nil
          ? "System audio recording"
          : "System audio recording (recovered)"
      }
      isMeetingRecordingPaused = false
      startMeetingInputMetering()
      meetingStatusText = "Recording \(activeMeetingRecording.paths.title)"
      statusText = meetingStatusText
    } catch {
      errorText = error.localizedDescription
      meetingStatusText = "Resume failed: \(error.localizedDescription)"
      statusText = "Recording resume failed"
    }
  }

  private func finishStoppedMeetingRecording(
    _ recording: PendingMeetingRecording,
    corpusRoot: URL,
    duration: TimeInterval,
    systemAudioURL: URL?,
    systemAudioCaptureError: String?,
    progressID: UUID,
    context: AIChatCorpusContextToken
  ) async {
    defer {
      if isCurrentAIChatCorpusContext(context) {
        endMeetingProcessing(paths: recording.paths)
        stopMeetingTranscriptionProgress(id: progressID)
      }
    }

    do {
      let transcript = await transcribeRecordedMeetingAudio(
        microphoneAudioURL: recording.paths.audioURL,
        systemAudioURL: systemAudioURL,
        systemAudioCaptureError: systemAudioCaptureError
      )
      var paths = recording.paths
      if let context = paths.calendar {
        // Link attendees to person notes using the corpus as it is now.
        paths.calendar = MeetingCalendarContext(
          event: context.event,
          attendees: MeetingAttendeeResolver.attendees(for: context.event, resolver: orgRoamLinkResolver)
        )
      }
      if isCurrentAIChatCorpusContext(context) {
        await savePendingEditsToMeetingNote(paths.noteURL)
      }
      let bundle = try await writeMeetingArtifacts(
        paths: paths,
        corpusRoot: corpusRoot,
        duration: duration,
        transcript: transcript,
        systemAudioURL: systemAudioURL
      )
      guard isCurrentAIChatCorpusContext(context) else { return }
      meetingTitleDraft = ""
      meetingSystemAudioStatusText = systemAudioURL == nil
        ? "System audio not captured"
        : "System audio saved"
      let completionText = transcript.status == .complete
        ? "Saved \(bundle.noteURL.lastPathComponent)"
        : "Saved \(bundle.noteURL.lastPathComponent); transcription \(transcript.status.label)"
      if !isRecordingMeeting {
        meetingStatusText = completionText
      }
      statusText = completionText
      await refreshAfterMeetingWrite(completed: bundle.item, context: context)
    } catch {
      guard isCurrentAIChatCorpusContext(context) else { return }
      errorText = error.localizedDescription
      let failureText = "Meeting save failed: \(error.localizedDescription)"
      if !isRecordingMeeting {
        meetingStatusText = failureText
      }
      statusText = "Meeting save failed"
    }
  }

  private func recoverInterruptedMeetingTranscriptions(knownItems: [MeetingWorkspaceItem]) {
    guard let corpusRoot else { return }
    let context = captureAIChatCorpusContext()
    Task { [weak self] in
      guard let self else { return }
      let recoverable: [RecoverableMeetingRecording]
      do {
        recoverable = try await Task.detached(priority: .utility) {
          try Self.scanRecoverableMeetingRecordings(corpusRoot: corpusRoot)
        }.value
      } catch {
        await MainActor.run {
          guard self.isCurrentAIChatCorpusContext(context) else { return }
          self.errorText = error.localizedDescription
          self.statusText = "Meeting recovery scan failed"
        }
        return
      }

      await MainActor.run {
        guard self.isCurrentAIChatCorpusContext(context) else { return }
        self.startRecoveringInterruptedMeetings(
          recoverable,
          knownItems: knownItems,
          corpusRoot: corpusRoot,
          context: context
        )
      }
    }
  }

  private func startRecoveringInterruptedMeetings(
    _ recoverable: [RecoverableMeetingRecording],
    knownItems: [MeetingWorkspaceItem],
    corpusRoot: URL,
    context: AIChatCorpusContextToken
  ) {
    guard isCurrentAIChatCorpusContext(context), !recoverable.isEmpty else { return }
    // A live note left by an interrupted recording does not make its audio
    // known: the recording still needs a transcript.
    let knownAudioArtifacts = Set(knownItems.filter {
      $0.transcriptionStatus?.lowercased() != MeetingArtifactWriter.liveRecordingStatus
    }.compactMap(\.audioArtifact))
    let activeRecordingPaths = meetingRecordingRecoveryExclusionPaths
      ?? activeMeetingRecording?.paths

    for recording in recoverable {
      guard Self.shouldRecoverMeetingRecording(
        recording.paths,
        activeRecordingPaths: activeRecordingPaths
      ) else {
        continue
      }
      let processingID = Self.meetingProcessingID(for: recording.paths)
      guard !activeMeetingProcessingIDs.contains(processingID) else { continue }
      let relativeAudio = MeetingArtifactWriter.relativePath(from: corpusRoot, to: recording.paths.audioURL)
      guard !knownAudioArtifacts.contains(relativeAudio) else { continue }

      beginMeetingProcessing(
        paths: recording.paths,
        status: "Resuming transcription for \(recording.paths.title)..."
      )
      let progressID = startMeetingTranscriptionProgress(
        title: recording.paths.title,
        audioDuration: recording.duration
      )
      Task { [weak self] in
        await self?.finishRecoveredMeetingRecording(
          recording,
          corpusRoot: corpusRoot,
          progressID: progressID,
          context: context
        )
      }
    }
  }

  private func finishRecoveredMeetingRecording(
    _ recording: RecoverableMeetingRecording,
    corpusRoot: URL,
    progressID: UUID,
    context: AIChatCorpusContextToken
  ) async {
    defer {
      if isCurrentAIChatCorpusContext(context) {
        endMeetingProcessing(paths: recording.paths)
        stopMeetingTranscriptionProgress(id: progressID)
      }
    }

    let transcript = await transcribeRecordedMeetingAudio(
      microphoneAudioURL: recording.paths.audioURL,
      systemAudioURL: recording.systemAudioURL,
      systemAudioCaptureError: recording.systemAudioCaptureError
    )

    do {
      let bundle = try await writeMeetingArtifacts(
        paths: recording.paths,
        corpusRoot: corpusRoot,
        duration: recording.duration,
        transcript: transcript,
        systemAudioURL: recording.systemAudioURL,
        captureSources: recording.captureSources
      )
      guard isCurrentAIChatCorpusContext(context) else { return }
      let completionText = transcript.status == .complete
        ? "Recovered \(bundle.noteURL.lastPathComponent)"
        : "Recovered \(bundle.noteURL.lastPathComponent); transcription \(transcript.status.label)"
      if !isRecordingMeeting {
        meetingStatusText = completionText
      }
      statusText = completionText
      await refreshAfterMeetingWrite(completed: bundle.item, context: context)
    } catch {
      guard isCurrentAIChatCorpusContext(context) else { return }
      errorText = error.localizedDescription
      let failureText = "Meeting recovery failed: \(error.localizedDescription)"
      if !isRecordingMeeting {
        meetingStatusText = failureText
      }
      statusText = "Meeting recovery failed"
    }
  }

  public func promptAndImportMeetingAudio() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    guard !isRecordingMeeting else { return }

    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio, .movie]
    panel.prompt = "Import"
    panel.message = "Choose an audio or video file to transcribe into a Celorga meeting."

    if panel.runModal() == .OK, let url = panel.url {
      let title = meetingTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
        : meetingTitleDraft
      Task { await importMeetingAudio(url: url, title: title) }
    }
  }

  public func importMeetingAudio(url sourceURL: URL, title rawTitle: String) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    guard !isRecordingMeeting else {
      meetingStatusText = "Stop the active recording before importing audio"
      return
    }
    let context = captureAIChatCorpusContext()

    var processingPaths: MeetingArtifactPaths?
    var progressID: UUID?
    defer {
      if isCurrentAIChatCorpusContext(context) {
        if let processingPaths {
          endMeetingProcessing(paths: processingPaths)
        }
        if let progressID {
          stopMeetingTranscriptionProgress(id: progressID)
        }
      }
    }
    let recordedAt = Date()

    do {
      let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
      let paths = try await importMeetingArtifactPaths(
        sourceURL: sourceURL,
        corpusRoot: corpusRoot,
        title: rawTitle,
        recordedAt: recordedAt,
        audioExtension: ext
      )
      processingPaths = paths
      beginMeetingProcessing(paths: paths, status: "Importing \(paths.title)...")
      meetingStatusText = "Transcribing \(paths.title) locally..."
      progressID = startMeetingTranscriptionProgress(title: paths.title, audioDuration: nil)
      let transcript = await transcribeAudioForMeeting(paths.audioURL)
      let bundle = try await writeMeetingArtifacts(
        paths: paths,
        corpusRoot: corpusRoot,
        duration: nil,
        transcript: transcript,
        captureSources: "imported_audio"
      )
      guard isCurrentAIChatCorpusContext(context) else { return }
      meetingTitleDraft = ""
      meetingStatusText = transcript.status == .complete
        ? "Imported \(bundle.noteURL.lastPathComponent)"
        : "Imported \(bundle.noteURL.lastPathComponent); transcription \(transcript.status.label)"
      statusText = meetingStatusText
      await refreshAfterMeetingWrite(completed: bundle.item, context: context)
    } catch {
      guard isCurrentAIChatCorpusContext(context) else { return }
      errorText = error.localizedDescription
      meetingStatusText = "Import failed: \(error.localizedDescription)"
      statusText = "Meeting import failed"
    }
  }

  public func selectMeeting(_ meeting: MeetingWorkspaceItem) {
    select(.meeting(meeting), surface: .meetings)
  }

  public func askAIChatAboutSelectedMeeting(threadMode: AIChatThreadMode = .newThread) {
    guard case .meeting(let meeting) = selectedLocation else {
      statusText = "Select a meeting first"
      return
    }
    prepareAIChatThread(
      mode: threadMode,
      title: "Meeting: \(Org2Display.cleanInline(meeting.title))",
      statusText: "New meeting chat"
    )
    let pointer = aiChatContextPointer(for: .meeting(meeting))
    publishAIChatComposerDraft(automaticAIChatActionText(
      pointer,
      prompt: "Use the selected meeting note and transcript artifact as context. Summarize the meeting, extract decisions, list action items, and cite the corpus file paths you used."
    ))
    navigateToSurface(.aiChat)
  }

  public func confirmAndDeleteMeeting(_ meeting: MeetingWorkspaceItem) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Delete Meeting?"
    alert.informativeText = "This deletes the meeting note and any linked audio/transcript artifacts from the corpus."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task { await deleteMeeting(meeting) }
  }

  public func deleteMeeting(_ meeting: MeetingWorkspaceItem) async {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }

    let urls = meetingArtifactURLs(for: meeting, corpusRoot: corpusRoot)
    do {
      try await removeMeetingArtifacts(urls, corpusRoot: corpusRoot)
      meetings.removeAll { $0.id == meeting.id }
      if selectedMeetingID == meeting.id {
        selectedMeetingID = nil
      }
      if selectedLocation?.file == meeting.file {
        selectedLocation = nil
        selectedEntrySource = nil
      }
      statusText = "Deleted \(Org2Display.cleanInline(meeting.title))"
      meetingStatusText = statusText
      await refreshMeetings()
      await refreshAgenda()
      Task { await refreshAIChatThreadRecords(showsLoading: false) }
    } catch {
      errorText = error.localizedDescription
      statusText = "Meeting delete failed"
      meetingStatusText = "Delete failed: \(error.localizedDescription)"
    }
  }

  public var canAskAIChatAboutCurrentSelection: Bool {
    selectedEntrySource != nil || selectedLocation != nil
  }

  public var hasWorkspaceDetailContent: Bool {
    presentedAgentRun != nil
      || presentedWebPageURL != nil
      || selectedLocation != nil
      || selectedEntrySource != nil
      || missingDailyNote != nil
  }

  public var presentedAgentRun: AgentRunItem? {
    guard let presentedAgentRunID else { return nil }
    return agentRunsByID[presentedAgentRunID]
  }

  var renderedDocumentLayout: OrgHTMLDocumentLayout {
    OrgHTMLDocumentLayout(width: renderedDocumentWidth, margin: renderedDocumentMargin)
  }

  public var canBriefCurrentNode: Bool {
    selectedLocation != nil
      && corpusRoot != nil
      && !isBuildingNodeBrief
      && (nodeBriefStartsNewThread || !isSendingAIChatMessage)
  }

  public var canLinkifyCurrentFile: Bool {
    corpusRoot != nil && (selectedEntrySource?.file != nil || selectedLocation?.file != nil)
  }

  public func startNewAIThread(from location: WorkspaceLocation) {
    if case .agenda(let item) = location {
      startNewAIThreadFromAgendaSelection(including: item)
      return
    }
    startNewAIThread(with: [aiChatContextPointer(for: location)])
  }

  public func startNewAIThreadFromAgendaSelection(including item: AgendaItem) {
    let items: [AgendaItem]
    if bulkSelectedAgendaItemIDs.contains(item.id) {
      items = visibleAgendaItems.filter { bulkSelectedAgendaItemIDs.contains($0.id) }
    } else {
      items = [item]
    }
    startNewAIThread(with: items.map { aiChatContextPointer(for: WorkspaceLocation.agenda($0)) })
  }

  public func startNewAIThreadFromAgentRunSelection(including run: AgentRunItem) {
    let runs: [AgentRunItem]
    if selectedAgentRunIDsForAIContext.contains(run.id) {
      runs = agentRuns.filter { selectedAgentRunIDsForAIContext.contains($0.id) }
    } else {
      runs = [run]
    }
    startNewAIThread(with: runs.compactMap { aiChatContextPointer(for: $0, requiresExistingRecord: false) })
  }

  public func startNewAIThreadFromApprovalSelection(including item: ApprovalItem) {
    let items: [ApprovalItem]
    if selectedApprovalItemIDsForAIContext.contains(item.id) {
      items = approvalItems.filter { selectedApprovalItemIDsForAIContext.contains($0.id) }
    } else {
      items = [item]
    }
    startNewAIThread(with: items.map(aiChatContextPointer(for:)))
  }

  public func startNewAIThreadFromCorpusFileSelection(including file: CorpusFile) {
    let files: [CorpusFile]
    if selectedCorpusFileIDsForAIContext.contains(file.id) {
      files = corpusFiles.filter { selectedCorpusFileIDsForAIContext.contains($0.id) }
    } else {
      files = [file]
    }
    startNewAIThread(with: files.map(aiChatContextPointer(for:)))
  }

  func aiChatDraftByAddingCorpusFileContext(_ file: CorpusFile, to draft: String) -> String {
    let pointer = aiChatContextPointer(for: file)
    guard !AIChatContextPresentation(draft).contexts.contains(where: {
      $0.reference == pointer.reference
    }) else {
      return draft
    }
    return injectedAIChatContext(pointer) + draft
  }

  public func askAIChatAboutCurrentSelection(threadMode: AIChatThreadMode? = nil) {
    guard let pointer = aiChatContextPointerForCurrentSelection() else {
      statusText = "Select a page or entry first"
      return
    }

    addAIChatContext(pointer, threadMode: threadMode ?? defaultAskAIThreadMode)
  }

  public func askAIChatAboutBlock(_ block: OrgEditableBlock, threadMode: AIChatThreadMode? = nil) {
    if selectedRenderedBlockIndexes[block.id] != nil {
      selectedBlockID = block.id
    }

    guard let pointer = aiChatContextPointer(for: AIChatBlockContextPointer(source: selectedEntrySource, block: block)) else {
      askAIChatAboutCurrentSelection(threadMode: threadMode)
      return
    }

    addAIChatContext(pointer, threadMode: threadMode ?? defaultAskAIThreadMode)
  }

  private var defaultAskAIThreadMode: AIChatThreadMode {
    selectedSurface == .aiChat && selectedAIChatThreadID != nil
      ? .currentThread
      : .newThread
  }

  public func askAIChatAboutSourceHeading(at line: Int) {
    guard let source = selectedEntrySource else {
      statusText = "No source loaded"
      return
    }
    if let block = Self.sourceAIContextBlock(at: line, in: selectedRenderedBlocks) {
      askAIChatAboutBlock(block)
      return
    }

    Task { @MainActor [weak self] in
      let blocks = await Task.detached(priority: .userInitiated) {
        OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)
      }.value
      guard let self, self.selectedEntrySource?.id == source.id else { return }
      guard let block = Self.sourceAIContextBlock(at: line, in: blocks) else {
        self.statusText = "Could not resolve that section"
        return
      }
      self.askAIChatAboutBlock(block)
    }
  }

  func performRenderedEntryAction(_ action: OrgHTMLRenderedEntryAction, at line: Int) {
    guard let block = renderedHeadingBlock(at: line) else {
      statusText = "Could not resolve that entry"
      return
    }

    switch action {
    case .entryView:
      openRenderedEntryView(block)
    case .edit:
      beginEditingSource(for: block)
    case .askAI:
      askAIChatAboutBlock(block)
    case .startWork:
      guard let location = renderedHeadingLocation(for: block) else { return }
      requestStartWork(on: location, origin: "document_menu")
    case .refile:
      presentRenderedEntryRefile(block)
    case .archive:
      Task { await archiveRenderedEntry(block) }
    case .schedule(let target):
      guard let location = renderedHeadingLocation(for: block) else { return }
      Task { await applyPlanningShortcut(kind: .scheduled, target: target, to: location) }
    case .todo(let status):
      guard let location = renderedHeadingLocation(for: block) else { return }
      Task { await applyTodoShortcut(status, to: location) }
    case .deadline(let target):
      guard let location = renderedHeadingLocation(for: block) else { return }
      Task { await applyPlanningShortcut(kind: .deadline, target: target, to: location) }
    case .priority(let priority):
      guard let location = renderedHeadingLocation(for: block) else { return }
      Task { await applyPriorityShortcut(priority, to: location) }
    case .encrypt:
      Task { await runOrgCrypt(.encrypt, line: block.startLine) }
    case .decrypt:
      Task { await runOrgCrypt(.decrypt, line: block.startLine) }
    case .viewDecrypted:
      Task { await peekOrgCrypt(line: block.startLine) }
    case .copy:
      copyRenderedEntry(block)
    case .cut:
      Task { await cutRenderedEntry(block) }
    case .copyReference:
      guard let source = selectedEntrySource else { return }
      copyFileReference(path: source.file, line: block.startLine)
    case .delete:
      confirmAndDeleteRenderedEntry(block)
    }
  }

  // MARK: Start work on a TODO heading

  /// The rendered document's "Start work" heading button.
  public func startWork(onHeadingAt line: Int) {
    guard let block = renderedHeadingBlock(at: line),
          let location = renderedHeadingLocation(for: block)
    else {
      statusText = "Could not resolve that heading"
      return
    }
    requestStartWork(on: location, origin: "document_button")
  }

  /// Asks where to start work on a TODO (agent, harness, model, reasoning,
  /// thread) before starting it. A heading that already has an open run
  /// opens that work directly.
  public func requestStartWork(on location: WorkspaceLocation, origin: String) {
    guard corpusRoot != nil else {
      statusText = "Open a corpus first"
      return
    }
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select a TODO heading first"
      return
    }
    guard let fileText = try? String(contentsOfFile: target.file, encoding: .utf8),
          let link = HeadingWorkStatus.links(in: fileText, baseLine: 1)
            .last(where: { $0.line <= target.line })
    else {
      statusText = "Could not find that heading"
      return
    }
    if link.todo.map(HeadingWorkStatus.terminalTodoKeywords.contains) == true {
      statusText = "This task is already closed"
      return
    }
    if let runID = link.runID, let run = agentRunsByID[runID], !run.isFinished {
      Task { await startWork(on: location, origin: origin) }
      return
    }
    guard !enabledAIChatDestinations.isEmpty else {
      errorText = "Turn on an AI destination in Settings › AI Chat to start work from a TODO."
      statusText = "No AI destination"
      return
    }
    let taskThreadID = link.idValue
      .flatMap { resourceThreadIDsByKey()["id:\($0)"] }
      .flatMap { id in aiChatThreads.contains(where: { $0.id == id }) ? id : nil }
    let currentThreadID = selectedAIChatThread
      .flatMap { $0.isSharedRoom || $0.id == taskThreadID ? nil : $0.id }
    pendingStartWorkRequest = StartWorkRequest(
      location: location,
      origin: origin,
      title: target.title.isEmpty ? "Untitled task" : target.title,
      headingAgentRef: link.agentRef,
      taskThreadID: taskThreadID,
      currentThreadID: currentThreadID
    )
  }

  /// Starts the work chosen in the Start Work dialog.
  public func confirmStartWork(
    _ request: StartWorkRequest,
    options: StartWorkOptions,
    threadTarget: StartWorkThreadTarget
  ) {
    pendingStartWorkRequest = nil
    if case .currentThread = threadTarget {
      // The current thread's settings are not a general default.
      startWorkLastOptions.agentRef = options.agentRef
    } else {
      startWorkLastOptions = options
    }
    Task {
      await startWork(
        on: request.location,
        origin: request.origin,
        options: options,
        threadTarget: threadTarget
      )
    }
  }

  /// Opens the chat thread (or run) already attached to the heading at `line`.
  public func openWork(onHeadingAt line: Int) {
    guard let source = selectedEntrySource,
          let badge = headingWorkBadges(for: source).first(where: { $0.line == line })
    else { return }
    openHeadingWork(threadID: badge.threadID ?? runChatThreadID(badge.runID), runID: badge.runID)
  }

  /// The chat a run was started in, from its "AI chat thread:" comment.
  private func runChatThreadID(_ runID: String?) -> UUID? {
    guard let runID, let run = agentRunsByID[runID],
          let id = Self.activityThreadID(in: run),
          aiChatThreads.contains(where: { $0.id == id })
    else { return nil }
    return id
  }

  func openHeadingWork(threadID: UUID?, runID: String?) {
    if let threadID, aiChatThreads.contains(where: { $0.id == threadID }) {
      if aiChatThreads.first(where: { $0.id == threadID })?.isSettled == true {
        reopenAIChatThread(threadID)
      }
      navigateToSurface(.aiChat)
      selectAIChatThread(threadID)
      return
    }
    if let runID, let run = agentRunsByID[runID] {
      runsAndReviewPage = .runs
      makeSurfacePrimary(.approvals)
      selectAgentRun(run)
    }
  }

  /// Badges for headings in `source` that have agent work attached.
  public func headingWorkBadges(for source: EntrySource) -> [HeadingWorkBadge] {
    let links: [HeadingWorkLink]
    if let cache = headingWorkLinksCache,
       cache.file == source.file,
       cache.startLine == source.startLine,
       cache.text == source.text {
      links = cache.links
    } else {
      links = HeadingWorkStatus.links(in: source.text, baseLine: source.startLine)
      headingWorkLinksCache = (source.file, source.startLine, source.text, links)
    }
    guard links.contains(where: { $0.runID != nil || $0.idValue != nil }) else { return [] }
    return HeadingWorkStatus.badges(
      links: links,
      runsByID: agentRunsByID,
      resourceThreadIDsByKey: resourceThreadIDsByKey(),
      isThreadRunning: { self.isAIChatThreadRunning($0) },
      threadIDForRun: { self.runChatThreadID($0.id) }
    )
  }

  /// The work state for an agenda row, from its ORG2_RUN_ID and ID properties.
  public func headingWorkState(properties: [String: String]) -> HeadingWorkBadge? {
    let runID = CelorgaNames.property("ORG2_RUN_ID", in: properties)?.trimmingCharacters(in: .whitespaces).nilIfBlank
    let idValue = properties["ID"]?.trimmingCharacters(in: .whitespaces).nilIfBlank
    guard runID != nil || idValue != nil else { return nil }
    return HeadingWorkStatus.badges(
      links: [HeadingWorkLink(line: 0, todo: nil, idValue: idValue, runID: runID)],
      runsByID: agentRunsByID,
      resourceThreadIDsByKey: resourceThreadIDsByKey(),
      isThreadRunning: { self.isAIChatThreadRunning($0) },
      threadIDForRun: { self.runChatThreadID($0.id) }
    ).first
  }

  private func resourceThreadIDsByKey() -> [String: UUID] {
    var result: [String: UUID] = [:]
    for thread in aiChatThreads {
      guard let key = thread.resource?.key, result[key] == nil else { continue }
      result[key] = thread.id
    }
    return result
  }

  /// One explicit path from a TODO to agent work:
  /// 1. create and start a durable `org2 run` citing the heading,
  /// 2. link it with `:ORG2_RUN_ID:` (adding an `:ID:` if missing) and mark the
  ///    TODO in progress,
  /// 3. open the heading's canonical `id:` chat thread and send the task.
  /// The heading then shows the run's live state (Working, Your turn, Done…).
  /// If the heading already has an open run with a thread, that thread opens.
  /// `options` and `threadTarget` come from the Start Work dialog; nil uses
  /// the current chat's destination and the heading's own thread.
  public func startWork(
    on location: WorkspaceLocation,
    origin: String = "agenda",
    options: StartWorkOptions? = nil,
    threadTarget: StartWorkThreadTarget? = nil
  ) async {
    guard let corpusRoot else {
      statusText = "Open a corpus first"
      return
    }
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select a TODO heading first"
      return
    }
    let key = "\(URL(fileURLWithPath: target.file).standardizedFileURL.path):\(target.line)"
    guard !startingWorkHeadingKeys.contains(key) else { return }
    startingWorkHeadingKeys.insert(key)
    defer { startingWorkHeadingKeys.remove(key) }

    let fileText: String
    do {
      fileText = try String(contentsOfFile: target.file, encoding: .utf8)
    } catch {
      errorText = error.localizedDescription
      statusText = "Start work failed"
      return
    }
    let link = HeadingWorkStatus.links(in: fileText, baseLine: 1)
      .last(where: { $0.line <= target.line })
    guard let link else {
      statusText = "Could not find that heading"
      return
    }
    if link.todo.map(HeadingWorkStatus.terminalTodoKeywords.contains) == true {
      statusText = "This task is already closed"
      return
    }

    // Resume an open run instead of creating a duplicate.
    if let runID = link.runID, let run = agentRunsByID[runID], !run.isFinished {
      let threadID = link.idValue.flatMap { resourceThreadIDsByKey()["id:\($0)"] }
        ?? runChatThreadID(runID)
      usageLog.record(.startWork, ["origin": .string(origin), "resumed": true])
      openHeadingWork(threadID: threadID, runID: runID)
      statusText = "Opened work in progress"
      return
    }

    var currentThread: AIChatThread?
    if case .currentThread(let id) = threadTarget {
      guard let thread = aiChatThreads.first(where: { $0.id == id }), !thread.isSharedRoom else {
        statusText = "That chat is no longer available"
        return
      }
      currentThread = thread
    }
    let preferredDestinationID = currentThread?.destinationID
      ?? options?.destinationID
      ?? selectedAIChatDestination.id
    guard let destination = enabledAIChatDestinations.first(where: { $0.id == preferredDestinationID })
      ?? enabledAIChatDestinations.first
    else {
      errorText = "Turn on an AI destination in Settings › AI Chat to start work from a TODO."
      statusText = "No AI destination"
      return
    }

    let title = target.title.isEmpty ? "Untitled task" : target.title
    let relative = relativePath(target.file)
    let idValue = link.idValue ?? UUID().uuidString.lowercased()
    let standardizedFile = URL(fileURLWithPath: target.file).standardizedFileURL.path
    statusText = "Starting work on \(title)…"

    let run: AgentRunItem
    do {
      var arguments = [
        "run", "create",
        "--title", "Work: \(title)",
        "--goal", title,
        "--context", "file:\(relative):\(link.line)",
        "--owner", "Celorga",
        "--assignee", destination.title,
        "--dir", corpusRoot.path,
        "--json",
      ]
      // The heading's own AGENT_REF wins over a dialog choice.
      if let agentRef = link.agentRef ?? options?.agentRef { arguments += ["--agent-ref", agentRef] }
      if let goalRef = link.goalRef { arguments += ["--goal-ref", goalRef] }
      let created: StartWorkRunCreatePayload = try await cli.runJSON(arguments)
      run = created.run
      _ = try await cli.run([
        "run", "start", run.id,
        "--actor", "Celorga",
        "--dir", corpusRoot.path,
        "--json",
      ])
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not create a run for this task"
      return
    }

    let headingTarget = HeadlineMutationTarget(
      file: target.file,
      line: link.line,
      title: title,
      idValue: link.idValue
    )
    do {
      let context = try documentMutationContext(for: headingTarget)
      var properties = ["ORG2_RUN_ID": run.id]
      if link.idValue == nil { properties["ID"] = idValue }
      let frozenProperties = properties
      _ = try await performDocumentMutation(context: context, files: [target.file]) { execution in
        try await Self.upsertPropertiesInDocument(frozenProperties, target: headingTarget, execution: execution)
      }
      if link.todo == nil || link.todo == "TODO" || link.todo == "NEXT" {
        let cli = self.cli
        let linkedTarget = HeadlineMutationTarget(file: target.file, line: link.line, title: title, idValue: idValue)
        // Custom keyword sets may not declare IN_PROGRESS; the run still starts.
        _ = try? await performDocumentMutation(context: context, files: [target.file]) { execution in
          try await Self.mutateTodoStatusInDocument(.inProgress, target: linkedTarget, cli: cli, execution: execution)
        }
      }
      await refreshAfterHeadlineMutation(headingTarget, selectMutatedBlock: false)
    } catch {
      // The run exists; record why the heading link failed and keep going so
      // the work is not lost.
      _ = try? await cli.run([
        "run", "comment", run.id,
        "--author", "Celorga",
        "--body", "Could not link heading \(relative):\(link.line): \(error.localizedDescription)",
        "--dir", corpusRoot.path,
        "--json",
      ])
      errorText = "Started the run, but could not update the heading: \(error.localizedDescription)"
    }

    let resource = AIChatResourceReference(
      key: "id:\(idValue)",
      kind: .heading,
      title: title,
      file: standardizedFile,
      line: link.line,
      idValue: idValue
    )
    let thread: AIChatThread
    let reusableThread: AIChatThread? = switch threadTarget {
    case .currentThread: currentThread
    case .newThread: nil
    case .taskThread(let id):
      aiChatThreads.first(where: { $0.id == id })
        ?? aiChatThreads.first(where: { $0.resource?.key == resource.key })
    case nil: aiChatThreads.first(where: { $0.resource?.key == resource.key })
    }
    if let existing = reusableThread {
      if existing.isSettled { reopenAIChatThread(existing.id) }
      thread = existing
    } else {
      let model = options?.model
      let reasoningEffort = options?.reasoningEffort
      thread = createAIChatThread(
        title: "Work: \(title)",
        statusText: "",
        resource: resource,
        runtime: destination.runtime,
        destinationID: destination.id,
        inheritsChatConfiguration: model == nil && reasoningEffort == nil,
        modelOverride: model,
        reasoningEffortOverride: reasoningEffort,
        defersPersistence: true,
        selectsThread: false
      )
    }
    if let options {
      applyStartWorkSettings(options, toThread: thread.id, includesModel: reusableThread != nil)
    }
    let pointer = aiChatContextPointer(for: WorkspaceLocation.aiChatThreadRecord(AIChatThreadRecord(
      title: title,
      file: target.file,
      line: link.line,
      zone: "entry",
      modifiedAt: nil,
      idValue: idValue
    )))
    let prompt = injectedAIChatContext(pointer) + HeadingWorkStatus.startWorkPrompt(
      title: title,
      reference: pointer.reference,
      runID: run.id,
      keepsCLIInstructions: !destination.adapter.isDirectProvider
    )
    _ = try? await cli.run([
      "run", "comment", run.id,
      "--author", "Celorga",
      "--body", "AI destination: \(destination.id)\nAI chat thread: \(thread.id.uuidString.lowercased())",
      "--dir", corpusRoot.path,
      "--json",
    ])
    let sent = sendAIChatRemoteMessage(prompt, threadID: thread.id)
    navigateToSurface(.aiChat)
    selectAIChatThread(thread.id)
    usageLog.record(.startWork, [
      "origin": .string(origin),
      "resumed": false,
      "sent": .bool(sent),
      "had_id": .bool(link.idValue != nil),
    ])
    statusText = sent ? "Started work on \(title)" : "Run started; send the task from the chat"
    await refreshAgentRuns()
  }

  /// Applies Start Work dialog choices to the chat that will receive the
  /// task. A running chat keeps its model; changing it mid-turn is unsafe.
  private func applyStartWorkSettings(
    _ options: StartWorkOptions,
    toThread threadID: UUID,
    includesModel: Bool
  ) {
    guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }) else { return }
    var thread = aiChatThreads[index]
    if let agentRef = options.agentRef, thread.agentRef != agentRef {
      thread = thread.replacingAIChatMetadata(agentRef: .some(agentRef))
    }
    if includesModel, !isAIChatThreadRunning(threadID) {
      if let model = options.model, thread.model != model {
        thread = thread.replacingAIChatMetadata(model: .some(model), reasoningEffort: .some(nil))
      }
      if let reasoningEffort = options.reasoningEffort, thread.reasoningEffort != reasoningEffort {
        thread = thread.replacingAIChatMetadata(reasoningEffort: .some(reasoningEffort))
      }
    }
    guard thread != aiChatThreads[index] else { return }
    aiChatThreads[index] = thread
    persistAIChatTranscript()
  }

  private func renderedHeadingBlock(at line: Int) -> OrgEditableBlock? {
    let blocks: [OrgEditableBlock]
    if !selectedRenderedBlocks.isEmpty {
      blocks = selectedRenderedBlocks
    } else if let source = selectedEntrySource {
      blocks = OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)
    } else {
      return nil
    }
    return blocks.first { block in
      block.startLine == line && {
        if case .heading = block.rendered { return true }
        return false
      }()
    }
  }

  private func renderedHeadingLocation(for block: OrgEditableBlock) -> WorkspaceLocation? {
    guard let source = selectedEntrySource,
          source.isEditable,
          case .heading(let heading) = block.rendered
    else {
      statusText = "This entry is read-only"
      return nil
    }
    let title = Org2Display.cleanInline(heading.title).trimmingCharacters(in: .whitespacesAndNewlines)
    return .aiChatThreadRecord(AIChatThreadRecord(
      title: title.isEmpty ? relativePath(source.file) : title,
      file: source.file,
      line: block.startLine,
      zone: "entry",
      modifiedAt: nil,
      idValue: nil
    ))
  }

  private func openRenderedEntryView(_ block: OrgEditableBlock) {
    guard let location = renderedHeadingLocation(for: block) else { return }
    activateDetailLocation(location, mode: .entry, surface: nil, recordsHistory: true)
    statusText = "Opened entry view"
  }

  private func copyRenderedEntry(_ block: OrgEditableBlock) {
    guard let source = selectedEntrySource else {
      statusText = "No source loaded"
      return
    }
    do {
      let text = try Self.renderedEntrySubtreeText(for: block, in: source)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      statusText = "Copied entry"
    } catch {
      errorText = error.localizedDescription
      statusText = "Copy failed"
    }
  }

  private func cutRenderedEntry(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "This entry is read-only"
      return
    }
    do {
      let text = try Self.renderedEntrySubtreeText(for: block, in: source)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      if await deleteBlock(block) {
        statusText = "Cut entry"
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Cut failed"
    }
  }

  private func confirmAndDeleteRenderedEntry(_ block: OrgEditableBlock) {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "This entry is read-only"
      return
    }
    let title: String
    if case .heading(let heading) = block.rendered {
      title = Org2Display.cleanInline(heading.title)
    } else {
      title = "this entry"
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Delete \(title.isEmpty ? "this entry" : "“\(title)”")?"
    alert.informativeText = "This deletes the heading and its entire subtree. You can undo the change from the Edit menu."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else {
      statusText = "Delete canceled"
      return
    }
    Task { await deleteBlock(block) }
  }

  private func presentRenderedEntryRefile(_ block: OrgEditableBlock) {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "This entry is read-only"
      return
    }
    let panel = NSOpenPanel()
    panel.title = "Move / Refile Entry"
    panel.message = "Choose the Org file where this entry should be appended."
    panel.prompt = "Refile"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = corpusRoot
    panel.allowedContentTypes = [
      UTType(filenameExtension: "org2") ?? .plainText,
      UTType(filenameExtension: "org") ?? .plainText,
    ]
    guard panel.runModal() == .OK, let destination = panel.url else {
      statusText = "Refile canceled"
      return
    }
    guard destination.standardizedFileURL.path != URL(fileURLWithPath: source.file).standardizedFileURL.path else {
      statusText = "Choose a different file when refiling from the context menu"
      return
    }
    Task { await refileRenderedEntry(block, from: source, to: destination) }
  }
}
