import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  public func applyTodoShortcut(_ status: TodoEditStatus?) async {
    let originatingSurface = selectedSurface
    let bulkItems = selectedAgendaItemsForBulkMutation()
    if !bulkItems.isEmpty {
      await applyTodoShortcut(status, to: bulkItems)
      return
    }

    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a TODO heading first"
      return
    }
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItems.firstIndex(where: { $0.id == id })
    }
    var shouldAdvanceSelection = status.map { Self.isTerminalTodoStatus($0.rawValue) } ?? false
    let context: WorkspaceDocumentCorpusContext
    do {
      context = try documentMutationContext(for: target)
    } catch {
      errorText = error.localizedDescription
      statusText = "TODO update failed"
      return
    }

    do {
      let newStatus: String
      if let status {
        newStatus = try await setTodoStatus(status, for: target)
      } else {
        newStatus = try await toggleTodoStatus(for: target)
        shouldAdvanceSelection = Self.isTerminalTodoStatus(newStatus)
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      statusText = status.map { "\($0.label) -> \(target.title)" }
        ?? "\(newStatus) -> \(target.title)"
      optimisticallyUpdateAgendaItem(id: target.agendaItemID, todo: newStatus)
      await refreshAfterHeadlineMutation(target)
      preserveAgendaSelectionAfterTodoMutation(
        target: target,
        originalVisibleIndex: originalVisibleIndex,
        shouldAdvanceSelection: shouldAdvanceSelection,
        originatingSurface: originatingSurface
      )
      if originatingSurface == .approvals, selectedSurface == .approvals {
        scheduleApprovalsRefresh()
      }
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "TODO update failed"
    }
  }

  private func applyAgendaTodoShortcut(_ status: TodoEditStatus) {
    let bulkItems = selectedAgendaItemsForBulkMutation()
    if !bulkItems.isEmpty {
      Task { await applyTodoShortcut(status, to: bulkItems) }
      return
    }

    guard selectedSurface == .agenda,
          let item = selectedAgendaItemForMutation()
    else {
      Task { await applyTodoShortcut(status) }
      return
    }

    let target = HeadlineMutationTarget(item: item)
    let visibleItemsBeforeMutation = visibleAgendaItems
    let originalVisibleIndex = visibleItemsBeforeMutation.firstIndex(where: { $0.id == item.id })
    let shouldAdvanceSelection = Self.isTerminalTodoStatus(status.rawValue)
    let nextSelection = shouldAdvanceSelection
      ? Self.nextActionableAgendaItem(
        afterMutating: item.id,
        originalVisibleIndex: originalVisibleIndex,
        in: visibleItemsBeforeMutation
      )
      : nil

    statusText = "\(status.label) -> \(target.title)"
    optimisticallyUpdateAgendaItem(id: target.agendaItemID, todo: status.label)
    if let nextSelection {
      cancelEntryPreviewWorkForAgendaKeyboardAdvance()
      preserveAgendaItemSelectionWithoutActivatingEntry(nextSelection)
    } else {
      preserveAgendaSelectionAfterTodoMutation(
        target: target,
        originalVisibleIndex: originalVisibleIndex,
        shouldAdvanceSelection: shouldAdvanceSelection,
        originatingSurface: .agenda
      )
    }

    enqueueAgendaTodoShortcutMutation(status: status, target: target)
  }

  private func enqueueAgendaTodoShortcutMutation(status: TodoEditStatus, target: HeadlineMutationTarget) {
    guard let context = try? documentMutationContext(for: target) else {
      statusText = "TODO update failed"
      return
    }
    pendingAgendaTodoShortcutMutations.append(AgendaTodoShortcutMutation(
      status: status,
      target: target,
      context: context
    ))
    agendaTodoShortcutMutationGeneration &+= 1
    guard agendaTodoShortcutMutationTask == nil else { return }

    agendaTodoShortcutMutationTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 80_000_000)
      guard !Task.isCancelled else { return }
      await self?.drainAgendaTodoShortcutMutations()
    }
  }

  private func drainAgendaTodoShortcutMutations() async {
    var needsReconciliation = false
    while !Task.isCancelled {
      guard !pendingAgendaTodoShortcutMutations.isEmpty else {
        agendaTodoShortcutMutationTask = nil
        let shouldReconcile = needsReconciliation || agendaRefreshDeferredForTodoShortcutBurst
        agendaRefreshDeferredForTodoShortcutBurst = false
        if shouldReconcile {
          if isRefreshingAgenda {
            agendaRefreshDeferredForTodoShortcutBurst = true
            scheduleAgendaRefresh(preserveSelection: true, updatesStatus: false)
          } else {
            await refreshAgenda(preserveSelection: true, updatesStatus: false)
          }
        }
        return
      }

      let batch = Self.orderedAgendaTodoShortcutMutations(pendingAgendaTodoShortcutMutations)
      pendingAgendaTodoShortcutMutations = []
      needsReconciliation = true

      for mutation in batch {
        guard !Task.isCancelled else { return }
        do {
          let newStatus = try await setTodoStatus(
            mutation.status,
            for: mutation.target,
            context: mutation.context
          )
          guard isCurrentDocumentCorpusContext(mutation.context) else { continue }
          if newStatus != mutation.status.label {
            optimisticallyUpdateAgendaItem(id: mutation.target.agendaItemID, todo: newStatus)
          }
          invalidateCanonicalDocumentCache(for: mutation.target.file)
        } catch {
          guard isCurrentDocumentCorpusContext(mutation.context) else { continue }
          errorText = error.localizedDescription
          statusText = "TODO update failed"
        }
      }

      // Keep the optimistic list stable across a natural run of repeated key
      // presses. More shortcuts append to this same task; only a quiet period
      // permits the single authoritative agenda reconciliation above.
      try? await Task.sleep(nanoseconds: 160_000_000)
    }
  }

  private func refreshedAgendaTodoShortcutTarget(
    _ target: HeadlineMutationTarget
  ) throws -> HeadlineMutationTarget {
    let url = URL(fileURLWithPath: target.file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let lines = Self.normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    if let idValue = target.idValue {
      for index in lines.indices where Self.parseTodoHeading(lines[index]) != nil {
        let properties = Self.scanPropertyDrawer(lines: lines, afterHeadingIndex: index)
        if properties["ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) == idValue {
          return HeadlineMutationTarget(
            file: target.file,
            line: index + 1,
            title: target.title,
            agendaItemID: target.agendaItemID,
            idValue: idValue
          )
        }
      }
    }

    let normalizedTitle = Self.normalizedApprovalActionTitle(target.title)
    let matchingIndexes = lines.indices.filter { index in
      guard let heading = Self.parseTodoHeading(lines[index]) else { return false }
      return Self.normalizedApprovalActionTitle(heading.title) == normalizedTitle
    }
    if let index = matchingIndexes.min(by: {
      abs(($0 + 1) - target.line) < abs(($1 + 1) - target.line)
    }), let heading = Self.parseTodoHeading(lines[index]) {
      return HeadlineMutationTarget(
        file: target.file,
        line: index + 1,
        title: heading.title,
        agendaItemID: target.agendaItemID,
        idValue: target.idValue
      )
    }

    return target
  }

  nonisolated private static func orderedAgendaTodoShortcutMutations(
    _ mutations: [AgendaTodoShortcutMutation]
  ) -> [AgendaTodoShortcutMutation] {
    mutations.sorted { lhs, rhs in
      if lhs.target.file == rhs.target.file {
        if lhs.target.line == rhs.target.line {
          return (lhs.target.agendaItemID ?? "") < (rhs.target.agendaItemID ?? "")
        }
        return lhs.target.line > rhs.target.line
      }
      return lhs.target.file < rhs.target.file
    }
  }

  public func applyTodoShortcut(_ status: TodoEditStatus?, to location: WorkspaceLocation) async {
    let originatingSurface = selectedSurface
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select a TODO heading first"
      return
    }
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItems.firstIndex(where: { $0.id == id })
    }
    var shouldAdvanceSelection = status.map { Self.isTerminalTodoStatus($0.rawValue) } ?? false
    let context: WorkspaceDocumentCorpusContext
    do {
      context = try documentMutationContext(for: target)
    } catch {
      errorText = error.localizedDescription
      statusText = "TODO update failed"
      return
    }

    do {
      let newStatus: String
      if let status {
        newStatus = try await setTodoStatus(status, for: target)
      } else {
        newStatus = try await toggleTodoStatus(for: target)
        shouldAdvanceSelection = Self.isTerminalTodoStatus(newStatus)
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      statusText = status.map { "\($0.label) -> \(target.title)" }
        ?? "\(newStatus) -> \(target.title)"
      optimisticallyUpdateAgendaItem(id: target.agendaItemID, todo: newStatus)
      await refreshAfterHeadlineMutation(target)
      preserveAgendaSelectionAfterTodoMutation(
        target: target,
        originalVisibleIndex: originalVisibleIndex,
        shouldAdvanceSelection: shouldAdvanceSelection,
        originatingSurface: originatingSurface
      )
      if originatingSurface == .approvals, selectedSurface == .approvals {
        scheduleApprovalsRefresh()
      }
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "TODO update failed"
    }
  }

  func applyTodoShortcut(_ status: TodoEditStatus?, to items: [AgendaItem]) async {
    guard let originContext = captureDocumentCorpusContext() else {
      statusText = "No corpus selected"
      return
    }
    do {
      var touchedFiles: Set<String> = []
      for item in agendaMutationOrder(items) {
        if let status {
          try await setTodoStatus(status, for: HeadlineMutationTarget(item: item))
        } else {
          _ = try await toggleTodoStatus(for: HeadlineMutationTarget(item: item))
        }
        touchedFiles.insert(item.file)
      }
      guard isCurrentDocumentCorpusContext(originContext) else { return }
      for file in touchedFiles {
        invalidateCanonicalDocumentCache(for: file)
      }
      bulkSelectedAgendaItemIDs = []
      await refreshAgenda(updatesStatus: false)
      if let status {
        statusText = "\(status.label) -> \(items.count) items"
      } else {
        statusText = "TODO updated -> \(items.count) items"
      }
    } catch {
      guard isCurrentDocumentCorpusContext(originContext) else { return }
      errorText = error.localizedDescription
      statusText = "Bulk TODO update failed"
    }
  }

  @discardableResult
  nonisolated static func previewCLIDocumentMutation(
    cli: Org2CLI,
    arguments: [String],
    basedOn snapshot: WorkspaceDocumentSnapshot
  ) async throws -> String {
    let data = try await cli.run(arguments + ["--format", "text"])
    guard var text = String(data: data, encoding: .utf8) else {
      throw WorkspaceDocumentMutationError.invalidUTF8(file: snapshot.url.path)
    }
    // The CLI's text presentation terminates stdout with a newline even when
    // the transformed source intentionally did not have one.
    if !snapshot.text.hasSuffix("\n"), text.hasSuffix("\n") {
      text.removeLast()
    }
    return text
  }

  @discardableResult
  nonisolated static func mutateTodoStatusInDocument(
    _ status: TodoEditStatus,
    target: HeadlineMutationTarget,
    cli: Org2CLI,
    execution: WorkspaceDocumentMutationExecution,
    testMutation: (@Sendable (TodoEditStatus, String, Int) async throws -> String)? = nil
  ) async throws -> (status: String, target: HeadlineMutationTarget) {
    let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
    // An explicit status can create a TODO keyword, just like `todo set`.
    // Standalone approvals can be ordinary headings (including undeclared
    // WAITING prefixes); requiring a TODO misreports them as stale files.
    let resolved = try await canonicalTodoMutationTarget(
      target, text: snapshot.text, cli: cli, requiresTodo: false
    )
    if let testMutation {
      let updatedStatus = try await testMutation(status, resolved.file, resolved.line)
      return (updatedStatus, resolved)
    }
    let replacement = try await previewCLIDocumentMutation(
      cli: cli,
      arguments: [
        "todo", "set",
        "--file", snapshot.url.path,
        "--line", "\(resolved.line)",
        "--status", status.rawValue,
      ],
      basedOn: snapshot
    )
    try await execution.commit(replacement, over: snapshot) { replacement, url, previous in
      try commitDocumentText(
        replacement,
        url: url,
        previousText: previous,
        operation: "TODO status update"
      )
    }
    return (status.label, resolved)
  }

  nonisolated private static func toggleTodoStatusInDocument(
    target: HeadlineMutationTarget,
    cli: Org2CLI,
    execution: WorkspaceDocumentMutationExecution
  ) async throws -> (status: String, target: HeadlineMutationTarget) {
    let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
    let resolved = try await canonicalTodoMutationTarget(target, text: snapshot.text, cli: cli)
    let replacement = try await previewCLIDocumentMutation(
      cli: cli,
      arguments: [
        "todo", "toggle",
        "--file", snapshot.url.path,
        "--line", "\(resolved.line)",
      ],
      basedOn: snapshot
    )
    let lines = normalizeLineEndings(replacement)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard lines.indices.contains(resolved.line - 1),
          let keyword = lines[resolved.line - 1].split(separator: " ").dropFirst().first
    else {
      throw WorkspaceEditError.noHeadline(file: resolved.file, line: resolved.line)
    }
    try await execution.commit(replacement, over: snapshot) { replacement, url, previous in
      try commitDocumentText(
        replacement,
        url: url,
        previousText: previous,
        operation: "TODO toggle"
      )
    }
    return (String(keyword), resolved)
  }

  nonisolated static func assignTodoInDocument(
    assignee: String,
    agentRef: String? = nil,
    goalRef: String? = nil,
    target: HeadlineMutationTarget,
    cli: Org2CLI,
    execution: WorkspaceDocumentMutationExecution
  ) async throws -> HeadlineMutationTarget {
    let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
    let resolved = try await canonicalTodoMutationTarget(target, text: snapshot.text, cli: cli)
    var arguments = [
      "todo", "assign",
      "--file", snapshot.url.path,
      "--line", "\(resolved.line)",
      "--assignee", assignee,
    ]
    if let agentRef, !agentRef.isEmpty {
      arguments += ["--agent-ref", agentRef]
    }
    if let goalRef, !goalRef.isEmpty {
      arguments += ["--goal-ref", goalRef]
    }
    let replacement = try await previewCLIDocumentMutation(
      cli: cli,
      arguments: arguments,
      basedOn: snapshot
    )
    try await execution.commit(replacement, over: snapshot) { replacement, url, previous in
      try commitDocumentText(
        replacement,
        url: url,
        previousText: previous,
        operation: "TODO assignment"
      )
    }
    return resolved
  }

  nonisolated static func planHeadingInDocument(
    kind: PlanningEditKind,
    date: String,
    target: HeadlineMutationTarget,
    cli: Org2CLI,
    execution: WorkspaceDocumentMutationExecution
  ) async throws -> HeadlineMutationTarget {
    let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
    let resolved = try resolveHeadlineMutationTarget(target, in: snapshot.text)
    let replacement = try await previewCLIDocumentMutation(
      cli: cli,
      arguments: [
        "plan", "set",
        "--file", snapshot.url.path,
        "--line", "\(resolved.line)",
        "--kind", kind.rawValue,
        "--date", date,
      ],
      basedOn: snapshot
    )
    try await execution.commit(replacement, over: snapshot) { replacement, url, previous in
      try commitDocumentText(
        replacement,
        url: url,
        previousText: previous,
        operation: "planning update"
      )
    }
    return resolved
  }

  nonisolated static func upsertPropertiesInDocument(
    _ properties: [String: String],
    target: HeadlineMutationTarget,
    execution: WorkspaceDocumentMutationExecution
  ) async throws -> HeadlineMutationTarget {
    let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
    let resolved = try resolveHeadlineMutationTarget(target, in: snapshot.text)
    let replacement = try textByUpsertingHeadlineProperties(
      snapshot.text,
      file: resolved.file,
      line: resolved.line,
      properties: properties
    )
    try await execution.commit(replacement, over: snapshot) { replacement, url, previous in
      try commitDocumentText(
        replacement,
        url: url,
        previousText: previous,
        operation: "headline property update"
      )
    }
    return resolved
  }

  nonisolated private static func updatePriorityInDocument(
    _ priority: String?,
    target: HeadlineMutationTarget,
    execution: WorkspaceDocumentMutationExecution
  ) async throws -> HeadlineMutationTarget {
    let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
    let resolved = try resolveHeadlineMutationTarget(target, in: snapshot.text)
    let replacement = try textByUpdatingHeadlinePriority(
      snapshot.text,
      file: resolved.file,
      line: resolved.line,
      priority: priority
    )
    try await execution.commit(replacement, over: snapshot) { replacement, url, previous in
      try commitDocumentText(
        replacement,
        url: url,
        previousText: previous,
        operation: "headline priority update"
      )
    }
    return resolved
  }

  @discardableResult
  func setTodoStatus(
    _ status: TodoEditStatus,
    for target: HeadlineMutationTarget,
    context explicitContext: WorkspaceDocumentCorpusContext? = nil
  ) async throws -> String {
    let context = try explicitContext ?? documentMutationContext(for: target)
    let cli = self.cli
    let testMutation = todoStatusMutationForTesting
    let result = try await performDocumentMutation(context: context, files: [target.file]) { execution in
      try await Self.mutateTodoStatusInDocument(
        status,
        target: target,
        cli: cli,
        execution: execution,
        testMutation: testMutation
      )
    }
    return result.status
  }

  private func toggleTodoStatus(for target: HeadlineMutationTarget) async throws -> String {
    let context = try documentMutationContext(for: target)
    let cli = self.cli
    let result = try await performDocumentMutation(context: context, files: [target.file]) { execution in
      try await Self.toggleTodoStatusInDocument(
        target: target,
        cli: cli,
        execution: execution
      )
    }
    return result.status
  }

  public func applyPlanningShortcut(kind: PlanningEditKind, target: PlanningDateTarget) async {
    guard let mutationTarget = selectedHeadlineMutationTarget else {
      statusText = "Select a heading first"
      return
    }

    await applyPlanningShortcut(kind: kind, target: target, to: mutationTarget)
  }

  public func applyPlanningShortcut(
    kind: PlanningEditKind,
    target: PlanningDateTarget,
    to location: WorkspaceLocation
  ) async {
    guard let mutationTarget = headlineMutationTarget(for: location) else {
      statusText = "Select a heading first"
      return
    }

    await applyPlanningShortcut(kind: kind, target: target, to: mutationTarget)
  }

  func applyPlanningShortcut(
    kind: PlanningEditKind,
    target: PlanningDateTarget,
    to mutationTarget: HeadlineMutationTarget
  ) async {
    let date = Self.dateString(for: target)
    let context: WorkspaceDocumentCorpusContext
    do {
      context = try documentMutationContext(for: mutationTarget)
    } catch {
      errorText = error.localizedDescription
      statusText = "Planning update failed"
      return
    }
    do {
      let cli = self.cli
      _ = try await performDocumentMutation(context: context, files: [mutationTarget.file]) { execution in
        try await Self.planHeadingInDocument(
          kind: kind,
          date: date,
          target: mutationTarget,
          cli: cli,
          execution: execution
        )
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      statusText = "\(kind.rawValue.uppercased()) \(date) -> \(mutationTarget.title)"
      await refreshAfterHeadlineMutation(mutationTarget)
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Planning update failed"
    }
  }

  public func applyAgentHandoffShortcut() async {
    await applyAgentHandoffShortcut(agentProfile: nil)
  }

  public func applyAgentHandoffShortcut(agentProfile: AgentProfileItem?) async {
    let bulkItems = selectedAgendaItemsForBulkMutation()
    if !bulkItems.isEmpty {
      await applyAgentHandoffShortcut(to: bulkItems, agentProfile: agentProfile)
      return
    }

    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a heading first"
      return
    }
    guard let context = try? documentMutationContext(for: target) else {
      statusText = "Agent handoff failed"
      return
    }

    do {
      try await markReadyForAgent(
        target,
        timestamp: Self.orgTimestamp(Date()),
        agentProfile: agentProfile
      )
      guard isCurrentDocumentCorpusContext(context) else { return }
      statusText = "Ready for \(agentProfile?.name ?? resolvedAgentHandoffAssignee()) -> \(target.title)"
      await refreshAfterHeadlineMutation(target)
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Agent handoff failed"
    }
  }

  public func applyAgentHandoffShortcut(to location: WorkspaceLocation) async {
    await applyAgentHandoffShortcut(to: location, agentProfile: nil)
  }

  public func applyAgentHandoffShortcut(
    to location: WorkspaceLocation,
    agentProfile: AgentProfileItem?
  ) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select a heading first"
      return
    }
    guard let context = try? documentMutationContext(for: target) else {
      statusText = "Agent handoff failed"
      return
    }

    do {
      try await markReadyForAgent(
        target,
        timestamp: Self.orgTimestamp(Date()),
        agentProfile: agentProfile
      )
      guard isCurrentDocumentCorpusContext(context) else { return }
      statusText = "Ready for \(agentProfile?.name ?? resolvedAgentHandoffAssignee()) -> \(target.title)"
      await refreshAfterHeadlineMutation(target)
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Agent handoff failed"
    }
  }

  private func applyAgentHandoffShortcut(
    to items: [AgendaItem],
    agentProfile: AgentProfileItem?
  ) async {
    guard let originContext = captureDocumentCorpusContext() else {
      statusText = "No corpus selected"
      return
    }
    do {
      let timestamp = Self.orgTimestamp(Date())
      var touchedFiles: Set<String> = []
      for item in agendaMutationOrder(items) {
        try await markReadyForAgent(
          HeadlineMutationTarget(item: item),
          timestamp: timestamp,
          agentProfile: agentProfile
        )
        touchedFiles.insert(item.file)
      }
      guard isCurrentDocumentCorpusContext(originContext) else { return }
      for file in touchedFiles {
        invalidateCanonicalDocumentCache(for: file)
      }
      bulkSelectedAgendaItemIDs = []
      await refreshAgenda(updatesStatus: false)
      statusText = "Ready for \(agentProfile?.name ?? resolvedAgentHandoffAssignee()) -> \(items.count) items"
    } catch {
      guard isCurrentDocumentCorpusContext(originContext) else { return }
      errorText = error.localizedDescription
      statusText = "Bulk agent handoff failed"
    }
  }

  private func markReadyForAgent(
    _ target: HeadlineMutationTarget,
    timestamp: String,
    agentProfile: AgentProfileItem?
  ) async throws {
    let context = try documentMutationContext(for: target)
    let assignee = agentProfile?.name ?? resolvedAgentHandoffAssignee()
    let cli = self.cli
    let testMutation = todoStatusMutationForTesting
    try await performDocumentMutation(context: context, files: [target.file]) { execution in
      let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
      let resolved = try Self.resolveHeadlineMutationTarget(target, in: snapshot.text)
      if Self.nestedParentSendHeading(for: resolved, in: snapshot.text) != nil {
        _ = try await Self.mutateTodoStatusInDocument(
          .done,
          target: resolved,
          cli: cli,
          execution: execution,
          testMutation: testMutation
        )
        return
      }

      let assignedTarget = try await Self.assignTodoInDocument(
        assignee: assignee,
        agentRef: agentProfile?.id,
        goalRef: agentProfile?.primaryGoalRef,
        target: resolved,
        cli: cli,
        execution: execution
      )
      _ = try await Self.upsertPropertiesInDocument(
        [
          "STATUS": "ready",
          "ASSIGNED_AT": timestamp,
        ],
        target: assignedTarget,
        execution: execution
      )
    }
  }

  public func applyApproveAndAgentHandoffShortcut() async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select an approval TODO first"
      return
    }
    guard let context = try? documentMutationContext(for: target) else {
      statusText = "Approve handoff failed"
      return
    }
    do {
      try await approveAndAgentHandoff(target)
      guard isCurrentDocumentCorpusContext(context) else { return }
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Approve handoff failed"
    }
  }

  public func applyApproveAndAgentHandoffShortcut(to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select an approval TODO first"
      return
    }
    guard let context = try? documentMutationContext(for: target) else {
      statusText = "Approve handoff failed"
      return
    }
    do {
      try await approveAndAgentHandoff(target)
      guard isCurrentDocumentCorpusContext(context) else { return }
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Approve handoff failed"
    }
  }

  public func applyRejectApprovalShortcut(endStatus: TodoEditStatus, reason: String) async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select an approval TODO first"
      return
    }
    guard let context = try? documentMutationContext(for: target) else {
      statusText = "Reject approval failed"
      return
    }
    do {
      try await rejectApproval(target, endStatus: endStatus, reason: reason)
      guard isCurrentDocumentCorpusContext(context) else { return }
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Reject approval failed"
    }
  }

  public func applyRejectApprovalShortcut(endStatus: TodoEditStatus, reason: String, to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select an approval TODO first"
      return
    }
    guard let context = try? documentMutationContext(for: target) else {
      statusText = "Reject approval failed"
      return
    }
    do {
      try await rejectApproval(target, endStatus: endStatus, reason: reason)
      guard isCurrentDocumentCorpusContext(context) else { return }
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Reject approval failed"
    }
  }

  public func promptAndApplyRejectApprovalShortcut() {
    guard selectedHeadlineMutationTarget != nil else {
      statusText = "Select an approval TODO first"
      return
    }
    guard let rejection = Self.promptForApprovalRejection() else { return }
    Task { await applyRejectApprovalShortcut(endStatus: rejection.endStatus, reason: rejection.reason) }
  }

  public func promptAndApplyRejectApprovalShortcut(to location: WorkspaceLocation) {
    guard headlineMutationTarget(for: location) != nil else {
      statusText = "Select an approval TODO first"
      return
    }
    guard let rejection = Self.promptForApprovalRejection() else { return }
    Task { await applyRejectApprovalShortcut(endStatus: rejection.endStatus, reason: rejection.reason, to: location) }
  }

  nonisolated static func approvalProperties(
    for target: HeadlineMutationTarget,
    in raw: String,
    requiresTodo: Bool = true
  ) throws -> (target: HeadlineMutationTarget, properties: [String: String]) {
    let resolved = try resolveHeadlineMutationTarget(target, in: raw, requiresTodo: requiresTodo)
    let lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let index = resolved.line - 1
    guard lines.indices.contains(index) else {
      throw WorkspaceEditError.noHeadline(file: resolved.file, line: resolved.line)
    }
    return (resolved, scanPropertyDrawer(lines: lines, afterHeadingIndex: index))
  }

  nonisolated private static func activateApprovedAgentActionInDocument(
    for target: HeadlineMutationTarget,
    timestamp: String,
    scheduledDate: String,
    assignee: String,
    cli: Org2CLI,
    execution: WorkspaceDocumentMutationExecution,
    testMutation: (@Sendable (TodoEditStatus, String, Int) async throws -> String)?
  ) async throws -> ApprovedAgentActionResult {
    let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
    let resolved = try resolveHeadlineMutationTarget(target, in: snapshot.text, requiresTodo: true)
    var lines = normalizeLineEndings(snapshot.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let headingIndex = resolved.line - 1
    guard lines.indices.contains(headingIndex),
          let headingLevel = headingLevel(lines[headingIndex])
    else {
      throw WorkspaceEditError.noHeadline(file: resolved.file, line: resolved.line)
    }

    let properties = scanPropertyDrawer(lines: lines, afterHeadingIndex: headingIndex)
    var candidateTitles = pairedApprovalActionTitleCandidates(properties: properties)
    let generatedTitle = approvedAgentActionTitle(for: resolved.title)
    candidateTitles.append(generatedTitle)

    if let existing = findExistingApprovedAgentAction(
      lines: lines,
      file: resolved.file,
      excludingHeadingIndex: headingIndex,
      candidateTitles: candidateTitles
    ) {
      let statusResult = try await mutateTodoStatusInDocument(
        .todo,
        target: existing,
        cli: cli,
        execution: execution,
        testMutation: testMutation
      )
      let assignedTarget = try await assignTodoInDocument(
        assignee: assignee,
        target: statusResult.target,
        cli: cli,
        execution: execution
      )
      let propertyTarget = try await upsertPropertiesInDocument(
        [
          "STATUS": approvedAgentActionStatus(for: assignedTarget.title),
          "APPROVED_AT": timestamp,
          "APPROVAL_TODO": resolved.title,
        ],
        target: assignedTarget,
        execution: execution
      )
      return ApprovedAgentActionResult(
        title: propertyTarget.title,
        file: propertyTarget.file,
        line: propertyTarget.line,
        created: false
      )
    }

    let insertIndex = subtreeEndIndex(lines: lines, headingIndex: headingIndex, level: headingLevel)
    let insertLine = insertIndex + 1
    var insertionLines: [String] = []
    if insertIndex > 0,
       !lines[insertIndex - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      insertionLines.append("")
    }
    let headingLineOffset = insertionLines.count
    let stars = String(repeating: "*", count: headingLevel)
    insertionLines += [
      "\(stars) TODO \(generatedTitle)",
      "SCHEDULED: \(scheduledDate)",
      ":PROPERTIES:",
      ":APPROVAL_TODO: \(resolved.title)",
      ":APPROVED_AT: \(timestamp)",
      ":ASSIGNEE: \(assignee)",
      ":STATUS: \(approvedAgentActionStatus(for: generatedTitle))",
      ":END:",
      "",
    ]
    lines.insert(contentsOf: insertionLines, at: insertIndex)
    let replacement = lines.joined(separator: "\n")
    try await execution.commit(replacement, over: snapshot) { replacement, url, previous in
      try commitDocumentText(
        replacement,
        url: url,
        previousText: previous,
        operation: "approved agent action insertion"
      )
    }

    return ApprovedAgentActionResult(
      title: generatedTitle,
      file: resolved.file,
      line: insertLine + headingLineOffset,
      created: true
    )
  }

  nonisolated private static func rejectPairedApprovedAgentActionInDocument(
    for target: HeadlineMutationTarget,
    approvalProperties: [String: String],
    endStatus: TodoEditStatus,
    reason: String?,
    timestamp: String,
    cli: Org2CLI,
    execution: WorkspaceDocumentMutationExecution,
    testMutation: (@Sendable (TodoEditStatus, String, Int) async throws -> String)?
  ) async throws -> Bool {
    let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
    let resolved = try resolveHeadlineMutationTarget(target, in: snapshot.text, requiresTodo: true)
    let lines = normalizeLineEndings(snapshot.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let approvalHeadingIndex = resolved.line - 1
    guard lines.indices.contains(approvalHeadingIndex),
          let paired = pairedApprovedAgentActionTarget(
            lines: lines,
            file: resolved.file,
            approvalHeadingIndex: approvalHeadingIndex,
            approvalProperties: approvalProperties,
            approvalTitle: resolved.title
          )
    else {
      return false
    }
    let pairedIndex = paired.line - 1
    guard lines.indices.contains(pairedIndex),
          let heading = parseTodoHeading(lines[pairedIndex]),
          !isTerminalTodoStatus(heading.todo)
    else {
      return false
    }
    let pairedProperties = scanPropertyDrawer(lines: lines, afterHeadingIndex: pairedIndex)
    guard !hasSentEvidence(in: pairedProperties) else { return false }

    let statusResult = try await mutateTodoStatusInDocument(
      endStatus,
      target: paired,
      cli: cli,
      execution: execution,
      testMutation: testMutation
    )
    var rejectionProperties = approvalRejectionProperties(
      timestamp: timestamp,
      endStatus: endStatus,
      reason: reason
    )
    rejectionProperties["REJECTED_APPROVAL_TODO"] = resolved.title
    _ = try await upsertPropertiesInDocument(
      rejectionProperties,
      target: statusResult.target,
      execution: execution
    )
    return true
  }

  func approveAndAgentHandoff(_ target: HeadlineMutationTarget) async throws {
    let originatingSurface = selectedSurface
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItems.firstIndex(where: { $0.id == id })
    }
    let timestamp = Self.orgTimestamp(Date())
    let scheduledDate = Self.orgDateTimestamp(Date())
    let assignee = resolvedAgentHandoffAssignee()
    let context = try documentMutationContext(for: target)
    let cli = self.cli
    let testMutation = todoStatusMutationForTesting
    let result = try await performDocumentMutation(context: context, files: [target.file]) { execution in
      let statusResult = try await Self.mutateTodoStatusInDocument(
        .done,
        target: target,
        cli: cli,
        execution: execution,
        testMutation: testMutation
      )
      let result = try await Self.activateApprovedAgentActionInDocument(
        for: statusResult.target,
        timestamp: timestamp,
        scheduledDate: scheduledDate,
        assignee: assignee,
        cli: cli,
        execution: execution,
        testMutation: testMutation
      )
      let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
      let current = try Self.approvalProperties(for: target, in: snapshot.text)
      var approvalProperties = current.properties
      approvalProperties.merge(Self.approvedApprovalProperties(
        existingProperties: approvalProperties,
        timestamp: timestamp,
        pairedTitle: result.title
      )) { _, new in new }
      _ = try await Self.upsertPropertiesInDocument(
        approvalProperties,
        target: current.target,
        execution: execution
      )
      return result
    }
    guard isCurrentDocumentCorpusContext(context) else { return }
    invalidateCanonicalDocumentCache(for: result.file)
    await refreshAfterHeadlineMutation(target)
    preserveAgendaSelectionAfterTodoMutation(
      target: target,
      originalVisibleIndex: originalVisibleIndex,
      shouldAdvanceSelection: true,
      originatingSurface: originatingSurface
    )
    statusText = result.created
      ? "Approved and created agent action -> \(result.title)"
      : "Approved and activated agent action -> \(result.title)"
  }

  nonisolated private static func approvedApprovalProperties(
    existingProperties: [String: String],
    timestamp: String,
    pairedTitle: String
  ) -> [String: String] {
    var properties: [String: String] = [
      "STATUS": "approved",
      "APPROVED_AT": timestamp,
      "PAIRED_SEND_TODO": pairedTitle
    ]

    for key in CelorgaNames.withAliases([
      "ORG2_REVIEW_STATUS",
      "REVIEW_STATUS",
      "REVIEW",
      "FOLLOWUP_STATUS",
      "REPLY_STATUS",
      "ACCESS_POLICY",
      "REVIEW_POLICY"
    ]) where existingProperties[key] != nil {
      properties[key] = "approved"
    }

    for key in CelorgaNames.withAliases([
      "WAITING_ON",
      "BLOCKED_BY",
      "ORG2_WAITING_ON",
      "NEXT_ACTION",
      "ACTION_REQUIRED",
      "ORG2_NEXT_ACTION",
      "HANDOFF_SUMMARY",
      "ORG2_HANDOFF_SUMMARY"
    ]) {
      guard let value = existingProperties[key]?.lowercased() else { continue }
      if value.contains("approval") || value.contains("approve") || value.contains("review") || value.contains("avi") {
        properties[key] = "approved"
      }
    }

    return properties
  }

  func completeStandaloneApprovalExternally(
    _ target: HeadlineMutationTarget,
    hasTodo: Bool,
    summary: String
  ) async throws {
    let context = try documentMutationContext(for: target)
    let cli = self.cli
    let testMutation = todoStatusMutationForTesting
    let timestamp = Self.orgTimestamp(Date())
    try await performDocumentMutation(context: context, files: [target.file]) { execution in
      let propertyTarget: HeadlineMutationTarget
      if hasTodo {
        propertyTarget = try await Self.mutateTodoStatusInDocument(
          .done,
          target: target,
          cli: cli,
          execution: execution,
          testMutation: testMutation
        ).target
      } else {
        propertyTarget = target
      }
      let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
      let current = try Self.approvalProperties(
        for: propertyTarget,
        in: snapshot.text,
        requiresTodo: hasTodo
      )
      _ = try await Self.upsertPropertiesInDocument(
        Self.completedExternallyApprovalProperties(
          existingProperties: current.properties,
          timestamp: timestamp,
          summary: summary
        ),
        target: current.target,
        execution: execution
      )
    }
    guard isCurrentDocumentCorpusContext(context) else { return }
    await refreshAfterHeadlineMutation(target)
    statusText = "Recorded external completion -> \(target.title)"
  }

  nonisolated private static func completedExternallyApprovalProperties(
    existingProperties: [String: String],
    timestamp: String,
    summary: String
  ) -> [String: String] {
    var properties: [String: String] = [
      "STATUS": "completed-externally",
      "COMPLETED_EXTERNALLY_AT": timestamp,
    ]
    let note = sanitizeOrgPropertyValue(summary)
    if !note.isEmpty {
      properties["EXTERNAL_COMPLETION_NOTE"] = note
    }

    for key in CelorgaNames.withAliases([
      "ORG2_REVIEW_STATUS",
      "REVIEW_STATUS",
      "REVIEW",
      "FOLLOWUP_STATUS",
      "REPLY_STATUS",
      "ACCESS_POLICY",
      "REVIEW_POLICY"
    ]) where existingProperties[key] != nil {
      properties[key] = "completed-externally"
    }

    for key in CelorgaNames.withAliases([
      "WAITING_ON",
      "BLOCKED_BY",
      "ORG2_WAITING_ON",
      "NEXT_ACTION",
      "ACTION_REQUIRED",
      "ORG2_NEXT_ACTION",
      "HANDOFF_SUMMARY",
      "ORG2_HANDOFF_SUMMARY"
    ]) {
      guard let value = existingProperties[key] else { continue }
      if containsApprovalSignal(value) {
        properties[key] = "completed-externally"
      }
    }

    return properties
  }

  func rejectApproval(_ target: HeadlineMutationTarget, endStatus: TodoEditStatus, reason: String) async throws {
    let reason = Self.normalizedApprovalRejectionReason(reason)
    let originatingSurface = selectedSurface
    let originalVisibleIndex = target.agendaItemID.flatMap { id in
      visibleAgendaItems.firstIndex(where: { $0.id == id })
    }
    let timestamp = Self.orgTimestamp(Date())
    let context = try documentMutationContext(for: target)
    let cli = self.cli
    let testMutation = todoStatusMutationForTesting
    let pairedRejected = try await performDocumentMutation(context: context, files: [target.file]) { execution in
      let statusResult = try await Self.mutateTodoStatusInDocument(
        endStatus,
        target: target,
        cli: cli,
        execution: execution,
        testMutation: testMutation
      )
      let snapshot = try await execution.readSnapshot(at: URL(fileURLWithPath: target.file))
      let current = try Self.approvalProperties(for: statusResult.target, in: snapshot.text)
      _ = try await Self.upsertPropertiesInDocument(
        Self.approvalRejectionProperties(
          timestamp: timestamp,
          endStatus: endStatus,
          reason: reason
        ),
        target: current.target,
        execution: execution
      )
      return try await Self.rejectPairedApprovedAgentActionInDocument(
        for: current.target,
        approvalProperties: current.properties,
        endStatus: endStatus,
        reason: reason,
        timestamp: timestamp,
        cli: cli,
        execution: execution,
        testMutation: testMutation
      )
    }
    guard isCurrentDocumentCorpusContext(context) else { return }
    await refreshAfterHeadlineMutation(target)
    preserveAgendaSelectionAfterTodoMutation(
      target: target,
      originalVisibleIndex: originalVisibleIndex,
      shouldAdvanceSelection: true,
      originatingSurface: originatingSurface
    )
    statusText = pairedRejected
      ? "Rejected approval and paired send -> \(target.title)"
      : "Rejected -> \(target.title)"
  }

  func resolvedAgentHandoffAssignee() -> String {
    let assignee = agentHandoffAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
    return assignee.isEmpty ? Self.defaultAgentHandoffAssignee : assignee
  }

  private func setTodoAssignee(_ assignee: String, for target: HeadlineMutationTarget) async throws {
    let context = try documentMutationContext(for: target)
    let cli = self.cli
    _ = try await performDocumentMutation(context: context, files: [target.file]) { execution in
      try await Self.assignTodoInDocument(
        assignee: assignee,
        target: target,
        cli: cli,
        execution: execution
      )
    }
  }

  public func applyPriorityShortcut(_ priority: String?) async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a heading first"
      return
    }

    await applyPriorityShortcut(priority, to: target)
  }

  public func applyPriorityShortcut(_ priority: String?, to location: WorkspaceLocation) async {
    guard let target = headlineMutationTarget(for: location) else {
      statusText = "Select a heading first"
      return
    }

    await applyPriorityShortcut(priority, to: target)
  }

  func applyPriorityShortcut(_ priority: String?, to target: HeadlineMutationTarget) async {
    let context: WorkspaceDocumentCorpusContext
    do {
      context = try documentMutationContext(for: target)
    } catch {
      errorText = error.localizedDescription
      statusText = "Priority update failed"
      return
    }
    do {
      _ = try await performDocumentMutation(context: context, files: [target.file]) { execution in
        try await Self.updatePriorityInDocument(
          priority,
          target: target,
          execution: execution
        )
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      statusText = priority.map { "Priority [#\($0)] -> \(target.title)" }
        ?? "Priority cleared -> \(target.title)"
      await refreshAfterHeadlineMutation(target)
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Priority update failed"
    }
  }

  public func promptAndApplyPropertyShortcut() {
    guard selectedHeadlineMutationTarget != nil else {
      statusText = "Select a heading first"
      return
    }

    let alert = NSAlert()
    alert.messageText = "Set Property"
    alert.informativeText = "Use KEY=VALUE on the selected headline."
    alert.addButton(withTitle: "Set")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "ASSIGNEE=openclaw"
    alert.accessoryView = field

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    guard let assignment = Self.parsePropertyAssignment(field.stringValue) else {
      statusText = "Property edit canceled; use KEY=VALUE"
      return
    }

    Task { await applyPropertyShortcut(key: assignment.key, value: assignment.value) }
  }

  public func promptAndCaptureTodoShortcut() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }

    presentCapturePanel(
      draft: WorkspaceCaptureDraft(kind: .task, includeScheduled: true, scheduledDate: Date())
    )
  }

  public func presentCapturePanel(draft: WorkspaceCaptureDraft = WorkspaceCaptureDraft()) {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    capturePanelPresentationID = UUID()
    captureDraft = draft
    isCapturePanelPresented = true
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  public func importPasteboardIntoCaptureDraft() {
    captureDraft = captureDraftByImportingPasteboard(into: captureDraft)
  }

  func prepareCaptureDraftForBrowserImport(
    _ draft: WorkspaceCaptureDraft,
    initialDraft: WorkspaceCaptureDraft
  ) -> Bool {
    captureDraft = draft
    return draft != initialDraft || !draft.title.isEmpty || !draft.body.isEmpty || !draft.attachments.isEmpty
  }

  public func captureDraftByImportingPasteboard(into draft: WorkspaceCaptureDraft) -> WorkspaceCaptureDraft {
    var updated = draft
    let content = Self.capturePasteboardContent(from: .general)
    Self.applyCapturePasteboardContent(content, to: &updated)
    return updated
  }

  private static func applyCapturePasteboardContent(
    _ content: WorkspaceCapturePasteboardContent,
    to draft: inout WorkspaceCaptureDraft
  ) {
    if !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
      draft.body = body.isEmpty
        ? content.text
        : "\(draft.body.trimmingCharacters(in: .newlines))\n\n\(content.text)"
    }
    draft.attachments.append(contentsOf: content.attachments)
    if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let title = Self.captureTitleCandidate(from: content.text) {
      draft.title = title
    }
  }

  public func captureTodo(title: String) async {
    await submitCaptureDraft(WorkspaceCaptureDraft(title: title))
  }

  nonisolated private static func captureEntryText(
    draft: WorkspaceCaptureDraft,
    assignee: String,
    timestamp: String,
    attachmentLines: [String]
  ) throws -> String {
    let safeTitle = draft.title
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeTitle.isEmpty else {
      throw WorkspaceEditError.emptyTitle
    }

    let priority = normalizePriority(draft.priority)
    let tagsSuffix = captureTagsSuffix(draft.tagsText)
    let headingPrefix = draft.kind == .task ? "* \(draft.todoStatus.label)" : "*"
    let priorityPart = priority.map { " [#\($0)]" } ?? ""
    var lines = ["\(headingPrefix)\(priorityPart) \(safeTitle)\(tagsSuffix)"]
    if draft.includeScheduled {
      lines.append("SCHEDULED: \(orgDateTimestamp(draft.scheduledDate))")
    }
    if draft.includeDeadline {
      lines.append("DEADLINE: \(orgDateTimestamp(draft.deadlineDate))")
    }

    var properties = ["CAPTURED_AT": timestamp]
    if draft.assignToAgent {
      properties["ASSIGNEE"] = assignee
      properties["STATUS"] = "ready"
      properties["ASSIGNED_AT"] = timestamp
    }
    lines.append(":PROPERTIES:")
    for key in properties.keys.sorted() {
      if let value = properties[key] {
        lines.append(":\(key): \(value)")
      }
    }
    lines.append(":END:")

    let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
    if !body.isEmpty {
      lines += ["", body]
    }
    if !attachmentLines.isEmpty {
      lines.append("")
      lines.append(contentsOf: attachmentLines)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  nonisolated private static func appendCaptureInDocument(
    draft: WorkspaceCaptureDraft,
    target: URL,
    corpusRoot: URL,
    assignee: String,
    timestamp: String,
    execution: WorkspaceDocumentMutationExecution
  ) async throws {
    let fileManager = FileManager.default
    let attachmentsDirectory = corpusRoot.appendingPathComponent("attachments", isDirectory: true)
    try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let snapshot = try await execution.readSnapshot(at: target, allowMissing: true)

    var stagedURLs: [URL] = []
    var promotedURLs: [URL] = []
    do {
      var attachmentLines: [String] = []
      for attachment in draft.attachments {
        if attachment.kind == .link, let sourceURL = attachment.sourceURL {
          let label = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
          attachmentLines.append(orgLink(
            target: sourceURL.absoluteString,
            label: label.isEmpty ? sourceURL.absoluteString : label
          ))
          continue
        }
        guard attachment.data != nil || attachment.sourceURL?.isFileURL == true else {
          if let sourceURL = attachment.sourceURL {
            let label = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
            attachmentLines.append(orgLink(
              target: sourceURL.absoluteString,
              label: label.isEmpty ? sourceURL.absoluteString : label
            ))
          } else {
            attachmentLines.append(attachment.name)
          }
          continue
        }

        try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let fileName = captureAttachmentFileName(for: attachment)
        let finalURL = try execution.authorizeDescendant(
          uniqueAttachmentURL(in: attachmentsDirectory, fileName: fileName),
          ofDeclaredDirectory: attachmentsDirectory
        )
        let temporaryURL = try execution.authorizeDescendant(
          attachmentsDirectory.appendingPathComponent(
            ".openorg-capture-\(execution.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).tmp"
          ),
          ofDeclaredDirectory: attachmentsDirectory
        )
        if let data = attachment.data {
          try data.write(to: temporaryURL, options: .atomic)
        } else if let sourceURL = attachment.sourceURL {
          try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        }
        stagedURLs.append(temporaryURL)
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
        stagedURLs.removeAll { $0 == temporaryURL }
        promotedURLs.append(finalURL)
        let relativePath = relativePath(
          for: finalURL.standardizedFileURL.path,
          root: corpusRoot.standardizedFileURL
        )
        let label = attachment.name.trimmingCharacters(in: .whitespacesAndNewlines)
        attachmentLines.append(orgLink(
          target: "file:\(relativePath)",
          label: label.isEmpty ? finalURL.lastPathComponent : label
        ))
      }

      let entry = try captureEntryText(
        draft: draft,
        assignee: assignee,
        timestamp: timestamp,
        attachmentLines: attachmentLines
      )
      let separator = snapshot.text.isEmpty || snapshot.text.hasSuffix("\n") ? "" : "\n"
      let replacement = snapshot.text + separator + entry
      try await execution.commit(replacement, over: snapshot) { replacement, url, previous in
        try commitDocumentText(
          replacement,
          url: url,
          previousText: previous,
          operation: "capture append"
        )
      }
    } catch {
      for url in stagedURLs + promotedURLs {
        try? fileManager.removeItem(at: url)
      }
      throw error
    }
  }

  public func submitCaptureDraft() async {
    await submitCaptureDraft(captureDraft)
  }

  public func submitCaptureDraft(_ draft: WorkspaceCaptureDraft) async {
    guard let corpusRoot,
          let context = captureDocumentCorpusContext()
    else {
      statusText = "No corpus selected"
      return
    }

    // The capture sheet edits a local copy of the draft, so compare the
    // presentation instead of the draft to decide whether to dismiss it.
    let presentationID = capturePanelPresentationID
    let target = await dailyNotePath(corpusRoot: corpusRoot, date: Date())
    let attachmentsDirectory = corpusRoot.appendingPathComponent("attachments", isDirectory: true)
    let assignee = resolvedAgentHandoffAssignee()
    let timestamp = Self.orgTimestamp(Date())
    do {
      try await performDocumentMutation(
        context: context,
        files: [target.path, attachmentsDirectory.path],
        priority: .userInitiated
      ) { execution in
        try await Self.appendCaptureInDocument(
          draft: draft,
          target: target,
          corpusRoot: corpusRoot,
          assignee: assignee,
          timestamp: timestamp,
          execution: execution
        )
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      statusText = "Captured \(draft.kind.title.lowercased()) -> \(target.lastPathComponent)"
      if capturePanelPresentationID == presentationID {
        isCapturePanelPresented = false
      }
      invalidateCanonicalDocumentCache(for: target.path)
      await refreshAgenda()
      await refreshCorpusFiles()
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Capture failed"
    }
  }

  public func captureReviewTodoForSelectedMeeting() async {
    guard let corpusRoot,
          let context = captureDocumentCorpusContext()
    else {
      statusText = "No corpus selected"
      return
    }
    let selectedMeeting = selectedMeetingID.flatMap { id in
      meetings.first { $0.id == id }
    } ?? {
      if case .meeting(let meeting) = selectedLocation {
        return meeting
      }
      return nil
    }()
    guard let meeting = selectedMeeting ?? meetings.first else {
      selectedSurface = .meetings
      statusText = "Select or record a meeting first"
      return
    }

    let target = await dailyNotePath(corpusRoot: corpusRoot, date: Date())
    let attachmentsDirectory = corpusRoot.appendingPathComponent("attachments", isDirectory: true)
    let draft = WorkspaceCaptureDraft(title: "Review meeting: \(Org2Display.cleanInline(meeting.title))")
    let assignee = resolvedAgentHandoffAssignee()
    let timestamp = Self.orgTimestamp(Date())
    do {
      try await performDocumentMutation(
        context: context,
        files: [target.path, attachmentsDirectory.path],
        priority: .userInitiated
      ) { execution in
        try await Self.appendCaptureInDocument(
          draft: draft,
          target: target,
          corpusRoot: corpusRoot,
          assignee: assignee,
          timestamp: timestamp,
          execution: execution
        )
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      statusText = "Captured meeting review TODO -> \(target.lastPathComponent)"
      invalidateCanonicalDocumentCache(for: target.path)
      selectedSurface = .agenda
      await refreshAgenda()
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Meeting review capture failed"
    }
  }

  public func applyPropertyShortcut(key: String, value: String) async {
    guard let target = selectedHeadlineMutationTarget else {
      statusText = "Select a heading first"
      return
    }

    let context: WorkspaceDocumentCorpusContext
    do {
      context = try documentMutationContext(for: target)
    } catch {
      errorText = error.localizedDescription
      statusText = "Property update failed"
      return
    }

    do {
      _ = try await performDocumentMutation(context: context, files: [target.file]) { execution in
        try await Self.upsertPropertiesInDocument(
          [key: value],
          target: target,
          execution: execution
        )
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      statusText = "\(key)=\(value) -> \(target.title)"
      await refreshAfterHeadlineMutation(target)
    } catch {
      guard isCurrentDocumentCorpusContext(context) else { return }
      errorText = error.localizedDescription
      statusText = "Property update failed"
    }
  }

  public func handleWorkspaceKeyDown(
    _ event: NSEvent,
    scope: WorkspaceKeyboardShortcutScope = .all
  ) -> Bool {
    if scope == .listNavigationFromSearchField {
      guard selectedSurface == .approvals,
            runsAndReviewPage == .review,
            isApprovalFilterFieldFocused
      else { return false }
      return handleAgentWorkListSelectionKeyDown(event)
    }
    if handleGlobalKeyDown(event, scope: scope) {
      return true
    }
    guard scope == .all else {
      return false
    }
    if handleSlidePreviewKeyDown(event) {
      return true
    }
    if selectedSurface == .agenda, handleAgendaKeyDown(event) {
      return true
    }
    if selectedSurface == .approvals, handleAgentWorkListSelectionKeyDown(event) {
      return true
    }
    if selectedSurface == .files, handleFileListSelectionKeyDown(event) {
      return true
    }
    if handleDocumentKeyDown(event) {
      return true
    }
    return false
  }

  private func handleAgentWorkListSelectionKeyDown(_ event: NSEvent) -> Bool {
    guard activeWorkspacePane == .surface else { return false }
    switch runsAndReviewPage {
    case .review:
      return handleListSelectionKeyDown(
        event,
        selectAll: selectAllVisibleApprovalItemsForBulkAction,
        clear: clearApprovalBulkSelection,
        move: moveApprovalSelection,
        extend: extendApprovalBulkSelection
      )
    case .runs:
      return handleListSelectionKeyDown(
        event,
        selectAll: selectAllVisibleAgentRunsForAIContext,
        clear: clearAgentRunAIContextSelection,
        move: nil,
        extend: extendAgentRunAIContextSelection
      )
    case .goals, .agents, .workflows:
      return false
    }
  }

  private func handleFileListSelectionKeyDown(_ event: NSEvent) -> Bool {
    guard activeWorkspacePane == .surface else { return false }
    return handleListSelectionKeyDown(
      event,
      selectAll: selectAllVisibleCorpusFilesForAIContext,
      clear: clearCorpusFileAIContextSelection,
      move: nil,
      extend: extendCorpusFileAIContextSelection
    )
  }

  private func handleListSelectionKeyDown(
    _ event: NSEvent,
    selectAll: () -> Void,
    clear: () -> Void,
    move: ((Int) -> Void)?,
    extend: (Int) -> Void
  ) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let key = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()
    if modifiers == [.command], key == "a" {
      selectAll()
      return true
    }
    if modifiers == [.command, .shift], key == "a" {
      clear()
      return true
    }
    guard event.keyCode == 125 || event.keyCode == 126 else { return false }
    let delta = event.keyCode == 125 ? 1 : -1
    if modifiers.isEmpty, let move {
      move(delta)
      return true
    }
    if modifiers == [.shift] {
      extend(delta)
      return true
    }
    return false
  }

  public func makeSurfacePrimary(_ surface: WorkspaceSurface) {
    activeWorkspacePane = .surface
    if surface == .home {
      openHome()
      return
    }
    if selectedSurface == surface,
       expandedWorkspaceSurface != nil
        || isWorkspaceSurfacePaneClosed
        || isWorkspaceDetailPaneExpanded
        || isAIChatAssistantPresented {
      recordCurrentNavigationDestination()
    }
    navigateToSurface(surface)
    if expandedWorkspaceSurface != nil { expandedWorkspaceSurface = nil }
    if isWorkspaceSurfacePaneClosed { isWorkspaceSurfacePaneClosed = false }
    if isWorkspaceDetailPaneExpanded { isWorkspaceDetailPaneExpanded = false }
    if isAIChatAssistantPresented { isAIChatAssistantPresented = false }
    if surface == .aiChat {
      markSelectedAIChatThreadRead()
    }
    statusText = "\(surface.title) is primary"
  }

  public func openReviewQueue() {
    runsAndReviewPage = .review
    makeSurfacePrimary(.approvals)
    statusText = "Review Queue is primary"
  }

  public func openAutomations() {
    runsAndReviewPage = .workflows
    makeSurfacePrimary(.approvals)
    statusText = "Automations is primary"
  }

  public func makeSelectedSurfacePrimary() {
    makeSurfacePrimary(selectedSurface)
  }

  public func expandSurface(_ surface: WorkspaceSurface) {
    activeWorkspacePane = .surface
    if surface == .home {
      openHome()
      return
    }
    if selectedSurface == surface,
       expandedWorkspaceSurface != nil
        || isWorkspaceSurfacePaneClosed
        || !isWorkspaceDetailPaneClosed
        || isWorkspaceDetailPaneExpanded
        || isAIChatAssistantPresented {
      recordCurrentNavigationDestination()
    }
    navigateToSurface(surface)
    expandedWorkspaceSurface = nil
    isWorkspaceSurfacePaneClosed = false
    isWorkspaceDetailPaneClosed = true
    isWorkspaceDetailPaneExpanded = false
    isAIChatAssistantPresented = false
    statusText = "\(surface.title) expanded"
  }

  public func toggleExpandedSurface(_ surface: WorkspaceSurface) {
    if selectedSurface == surface && isWorkspaceDetailPaneClosed && hasWorkspaceDetailContent {
      recordCurrentNavigationDestination()
      isWorkspaceSurfacePaneClosed = false
      statusText = "\(surface.title) restored"
    } else {
      expandSurface(surface)
    }
  }

  public func toggleSelectedSurfaceExpansion() {
    toggleExpandedSurface(selectedSurface)
  }

  public func closeSurfacePane(_ surface: WorkspaceSurface) {
    if expandedWorkspaceSurface != nil
      || isWorkspaceDetailPaneExpanded
      || isAIChatAssistantPresented
      || (selectedSurface == surface && hasWorkspaceDetailContent && !isWorkspaceSurfacePaneClosed) {
      recordCurrentNavigationDestination()
    }
    expandedWorkspaceSurface = nil
    isWorkspaceDetailPaneExpanded = false
    if selectedSurface == surface, hasWorkspaceDetailContent {
      isWorkspaceSurfacePaneClosed = true
      isWorkspaceDetailPaneClosed = false
      activeWorkspacePane = .detail
    }
    isAIChatAssistantPresented = false
    statusText = "\(surface.title) closed"
  }

  public func closeSelectedSurfacePane() {
    closeSurfacePane(selectedSurface)
  }

  public func makeDetailPanePrimary() {
    guard hasWorkspaceDetailContent else {
      statusText = "Open a detail first"
      return
    }
    if expandedWorkspaceSurface != nil
      || !isWorkspaceSurfacePaneClosed
      || isWorkspaceDetailPaneClosed
      || isWorkspaceDetailPaneExpanded
      || isAIChatAssistantPresented {
      recordCurrentNavigationDestination()
    }
    expandedWorkspaceSurface = nil
    isWorkspaceSurfacePaneClosed = true
    isWorkspaceDetailPaneClosed = false
    isWorkspaceDetailPaneExpanded = false
    isAIChatAssistantPresented = false
    activeWorkspacePane = .detail
    statusText = "Document is primary"
  }

  public func toggleDetailPaneExpansion() {
    guard hasWorkspaceDetailContent else {
      statusText = "Open a detail first"
      return
    }
    recordCurrentNavigationDestination()
    expandedWorkspaceSurface = nil
    isWorkspaceDetailPaneExpanded = false
    isWorkspaceDetailPaneClosed = false
    isAIChatAssistantPresented = false
    activeWorkspacePane = .detail
    if isWorkspaceSurfacePaneClosed {
      isWorkspaceSurfacePaneClosed = false
      statusText = "Document restored"
    } else {
      isWorkspaceSurfacePaneClosed = true
      statusText = "Document expanded"
    }
  }

  public func closeDetailPane() {
    if !isWorkspaceDetailPaneClosed
      || isWorkspaceDetailPaneExpanded
      || isWorkspaceSurfacePaneClosed
      || expandedWorkspaceSurface != nil {
      recordCurrentNavigationDestination()
    }
    isWorkspaceDetailPaneClosed = true
    isWorkspaceDetailPaneExpanded = false
    isWorkspaceSurfacePaneClosed = false
    expandedWorkspaceSurface = nil
    activeWorkspacePane = .surface
    statusText = "Detail closed"
  }

  func activateWorkspacePane(_ pane: WorkspacePaneFocus) {
    switch pane {
    case .surface:
      guard !isWorkspaceSurfacePaneClosed else { return }
    case .detail:
      guard hasWorkspaceDetailContent, !isWorkspaceDetailPaneClosed else { return }
    }
    activeWorkspacePane = pane
  }

  public func toggleAIChatAssistantPanel() {
    makeSurfacePrimary(.aiChat)
  }

  public func setAIChatAssistantPanelPresented(_ presented: Bool) {
    isAIChatAssistantPresented = false
    if presented {
      makeSurfacePrimary(.aiChat)
    }
  }

  public func handleGlobalKeyDown(
    _ event: NSEvent,
    scope: WorkspaceKeyboardShortcutScope = .all
  ) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

    if scope == .all,
       documentPreviewKind == .slides,
       slidePreviewPDF != nil {
      if modifiers == [.command], event.keyCode == 27 {
        zoomSlidePreviewOut()
        return true
      }
      if (modifiers == [.command] || modifiers == [.command, .shift]), event.keyCode == 24 {
        zoomSlidePreviewIn()
        return true
      }
    }

    if scope == .all,
       presentedWebPageURL != nil,
       !isWorkspaceDetailPaneClosed,
       isWorkspaceSurfacePaneClosed || activeWorkspacePane == .detail {
      if modifiers == [.command], event.keyCode == 27 {
        browser.zoomOut()
        return true
      }
      if (modifiers == [.command] || modifiers == [.command, .shift]), event.keyCode == 24 {
        browser.zoomIn()
        return true
      }
    }

    guard modifiers == [.command] || modifiers == [.command, .shift] || modifiers == [.command, .option] else {
      return false
    }

    let key = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()
    if modifiers == [.command] {
      switch key {
      case "0":
        makeSurfacePrimary(.sources)
      case "1":
        openHome()
      case "2":
        makeSurfacePrimary(.agenda)
      case "3":
        makeSurfacePrimary(.files)
      case "4":
        makeSurfacePrimary(.approvals)
      case "5":
        makeSurfacePrimary(.meetings)
      case "6":
        makeSurfacePrimary(.aiChat)
      case "m":
        makeSurfacePrimary(.meetings)
      case "7":
        openDailyNote(.today)
      case "8":
        openDailyNote(.yesterday)
      case "9":
        openDailyNote(.tomorrow)
      case "f":
        guard focusCurrentSearchField() else { return false }
      case "k", "p":
        presentQuickOpen()
      case "[":
        guard canNavigateBack else { return false }
        navigateBack()
      case "]":
        guard canNavigateForward else { return false }
        navigateForward()
      case "r":
        guard corpusRoot != nil else { return false }
        if isRefreshingWorkspace {
          cancelWorkspaceRefresh()
        } else {
          Task { await refreshWorkspace() }
        }
      case "s":
        guard scope == .all else {
          return OrgSyntaxTextView.saveFocusedTextViewIfPossible(for: event)
        }
        guard canSaveCurrentFile else { return false }
        Task { await saveActiveEdit() }
      case "t":
        newWorkspaceTab()
      case "w":
        guard workspaceTabs.count > 1 else { return false }
        closeWorkspaceTab(selectedWorkspaceTabID)
      case "/":
        presentKeyboardShortcuts()
      case "z":
        guard scope == .all else { return false }
        performUndoCommand()
      default:
        return false
      }
      return true
    }

    if modifiers == [.command, .option] {
      switch key {
      case "a":
        openAutomations()
      case "v":
        makeSurfacePrimary(.savedViews)
      case "c":
        guard isWorkspaceAppEnabled("canvases") else { return false }
        makeSurfacePrimary(.canvases)
      case "u":
        guard isWorkspaceAppEnabled("crm") else { return false }
        makeSurfacePrimary(.people)
      case "o":
        guard isWorkspaceAppEnabled("crm") else { return false }
        makeSurfacePrimary(.companies)
      case "e":
        makeSurfacePrimary(.externalThreads)
      case "n":
        makeSurfacePrimary(.activity)
      case "k":
        makeSurfacePrimary(.calendar)
      default:
        return false
      }
      return true
    }

    if modifiers == [.command, .shift] {
      if event.keyCode == 26 {
        presentDailyNoteDatePicker()
        return true
      }
      switch key {
      // `charactersIgnoringModifiers` still applies Shift, so a physical
      // ⌘⇧[ / ⌘⇧] arrives as "{" / "}". Match both forms here; otherwise
      // the shortcut misses this fast path and falls through to the SwiftUI
      // menu key-equivalent path, which lags noticeably on every tab switch.
      case "[", "{":
        selectPreviousWorkspaceTab()
        return true
      case "]", "}":
        selectNextWorkspaceTab()
        return true
      case "f":
        focusSearchSurface()
        return true
      case "k":
        makeSurfacePrimary(.skills)
        return true
      case "m":
        guard corpusRoot != nil else { return false }
        if isRecordingMeeting {
          Task { await stopMeetingRecording() }
        } else {
          promptAndStartMeetingRecording()
        }
        return true
      case "o":
        chooseCorpus()
        return true
      case "r":
        openReviewQueue()
        return true
      case "z":
        guard scope == .all else { return false }
        performRedoCommand()
        return true
      default:
        break
      }
      if key == "/" || event.characters == "?" {
        presentKeyboardShortcuts()
        return true
      }
    }

    return false
  }

  private func handleSlidePreviewKeyDown(_ event: NSEvent) -> Bool {
    guard documentPreviewKind == .slides,
          slidePreviewPDF != nil,
          slidePreviewPageCount > 0
    else { return false }

    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if modifiers == [.shift], event.keyCode == 49 {
      requestSlidePreviewNavigation(.previous)
      return true
    }
    guard modifiers.isEmpty else { return false }

    switch event.keyCode {
    case 123, 116:
      requestSlidePreviewNavigation(.previous)
    case 124, 121, 49:
      requestSlidePreviewNavigation(.next)
    case 115:
      requestSlidePreviewNavigation(.first)
    case 119:
      requestSlidePreviewNavigation(.last)
    default:
      return false
    }
    return true
  }

  public func performUndoCommand() {
    if Self.performNativeTextUndoIfPossible(firstResponder: NSApplication.shared.keyWindow?.firstResponder) {
      return
    }
    guard let action = workspaceUndoStack.popLast() else {
      statusText = "Nothing to undo"
      return
    }
    if applyImmediateWorkspaceUndo(action) {
      return
    }
    Task { @MainActor [weak self] in
      await self?.applyWorkspaceUndo(action)
    }
  }

  public func performRedoCommand() {
    if Self.performNativeTextRedoIfPossible(firstResponder: NSApplication.shared.keyWindow?.firstResponder) {
      return
    }
    guard let action = workspaceRedoStack.popLast() else {
      statusText = "Nothing to redo"
      return
    }
    if applyImmediateWorkspaceRedo(action) {
      return
    }
    Task { @MainActor [weak self] in
      await self?.applyWorkspaceRedo(action)
    }
  }

  @discardableResult
  static func performNativeTextUndoIfPossible(firstResponder: NSResponder?) -> Bool {
    guard let textView = firstResponder as? NSTextView,
          let undoManager = textView.undoManager,
          undoManager.canUndo
    else {
      return false
    }
    undoManager.undo()
    return true
  }

  @discardableResult
  static func performNativeTextRedoIfPossible(firstResponder: NSResponder?) -> Bool {
    guard let textView = firstResponder as? NSTextView,
          let undoManager = textView.undoManager,
          undoManager.canRedo
    else {
      return false
    }
    undoManager.redo()
    return true
  }

  func recordWorkspaceUndo(_ action: WorkspaceUndoAction) {
    guard workspaceUndoStack.last != action else { return }
    workspaceUndoStack.append(action)
    if workspaceUndoStack.count > Self.workspaceUndoStackLimit {
      workspaceUndoStack.removeFirst(workspaceUndoStack.count - Self.workspaceUndoStackLimit)
    }
    workspaceRedoStack.removeAll()
  }

  func fileUndoSnapshot(for file: String) async -> PendingFileUndoSnapshot? {
    let observer = fileUndoSnapshotReadForTesting
    return await Task.detached(priority: .userInitiated) {
      observer?(Self.currentThreadIsMainForTesting())
      return Self.fileUndoSnapshotOffMain(for: file)
    }.value
  }

  func prepareFileUndoSnapshotForTesting(file: String) async -> Bool {
    await fileUndoSnapshot(for: file) != nil
  }

  nonisolated static func fileUndoSnapshotOffMain(
    for file: String
  ) -> PendingFileUndoSnapshot? {
    let standardized = URL(fileURLWithPath: file).standardizedFileURL.path
    let url = URL(fileURLWithPath: standardized)
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
          let fileSize = values.fileSize,
          fileSize <= workspaceUndoSnapshotMaxBytes
    else {
      return nil
    }
    guard let previous = try? fileText(file: standardized),
          previous.utf8.count <= workspaceUndoSnapshotMaxBytes
    else {
      return nil
    }
    return PendingFileUndoSnapshot(file: standardized, previous: previous)
  }

  nonisolated private static func completedFileUndoSnapshot(
    from snapshot: PendingFileUndoSnapshot?
  ) -> CompletedFileUndoSnapshot? {
    guard let snapshot else { return nil }
    let url = URL(fileURLWithPath: snapshot.file)
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
          let fileSize = values.fileSize,
          fileSize <= workspaceUndoSnapshotMaxBytes,
          let next = try? fileText(file: snapshot.file),
          next.utf8.count <= workspaceUndoSnapshotMaxBytes
    else {
      return nil
    }
    return CompletedFileUndoSnapshot(
      file: snapshot.file,
      previous: snapshot.previous,
      next: next
    )
  }

  func recordFileUndo(from snapshot: CompletedFileUndoSnapshot?) {
    guard let snapshot else { return }
    recordFileUndo(file: snapshot.file, previous: snapshot.previous, next: snapshot.next)
  }

  func recordFileUndo(from snapshot: PendingFileUndoSnapshot?) async {
    guard snapshot != nil else { return }
    let completed = await Task.detached(priority: .utility) {
      Self.completedFileUndoSnapshot(from: snapshot)
    }.value
    recordFileUndo(from: completed)
  }

  func recordFileUndo(file: String, previous: String, next: String) {
    guard Self.normalizeLineEndings(previous) != Self.normalizeLineEndings(next) else {
      return
    }
    recordWorkspaceUndo(.fileSnapshot(file: URL(fileURLWithPath: file).standardizedFileURL.path, previous: previous, next: next))
  }

  private func applyImmediateWorkspaceUndo(_ action: WorkspaceUndoAction) -> Bool {
    switch action {
    case .aiChatDraft(let previous, _):
      publishAIChatComposerDraft(previous)
      aiChatStatusText = "Undid AI chat draft change"
      statusText = "Undid AI chat draft change"
      workspaceRedoStack.append(action)
      return true
    case .fileSnapshot:
      return false
    }
  }

  private func applyImmediateWorkspaceRedo(_ action: WorkspaceUndoAction) -> Bool {
    switch action {
    case .aiChatDraft(_, let next):
      publishAIChatComposerDraft(next)
      aiChatStatusText = "Redid AI chat draft change"
      statusText = "Redid AI chat draft change"
      workspaceUndoStack.append(action)
      return true
    case .fileSnapshot:
      return false
    }
  }

  private func applyWorkspaceUndo(_ action: WorkspaceUndoAction) async {
    switch action {
    case .aiChatDraft:
      _ = applyImmediateWorkspaceUndo(action)
    case .fileSnapshot(let file, let previous, let next):
      do {
        try await restoreFileSnapshot(
          file: file,
          text: previous,
          expectedCurrent: next,
          direction: "Undid"
        )
        workspaceRedoStack.append(action)
      } catch {
        workspaceUndoStack.append(action)
        errorText = error.localizedDescription
        statusText = "Undo failed"
      }
    }
  }

  private func applyWorkspaceRedo(_ action: WorkspaceUndoAction) async {
    switch action {
    case .aiChatDraft:
      _ = applyImmediateWorkspaceRedo(action)
    case .fileSnapshot(let file, let previous, let next):
      do {
        try await restoreFileSnapshot(
          file: file,
          text: next,
          expectedCurrent: previous,
          direction: "Redid"
        )
        workspaceUndoStack.append(action)
      } catch {
        workspaceRedoStack.append(action)
        errorText = error.localizedDescription
        statusText = "Redo failed"
      }
    }
  }

  private func restoreFileSnapshot(
    file: String,
    text: String?,
    expectedCurrent: String?,
    direction: String
  ) async throws {
    let standardized = URL(fileURLWithPath: file).standardizedFileURL.path
    let selectedFile = selectedEntrySource?.file ?? selectedLocation?.file
    let affectsSelectedFile = selectedFile.map {
      URL(fileURLWithPath: $0).standardizedFileURL.path == standardized
    } ?? false

    if affectsSelectedFile {
      cancelLiveFileEditorAutosave(resetStatus: false)
    }

    guard let context = captureDocumentCorpusContext(forFile: standardized) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(
        file: standardized,
        root: corpusRoot?.path ?? "(none)"
      )
    }
    try await performDocumentMutation(context: context, files: [standardized]) { execution in
      let url = URL(fileURLWithPath: standardized)
      let snapshot = try await execution.readSnapshot(at: url, allowMissing: true)
      let current: String? = snapshot.existed ? snapshot.text : nil
      guard current.map(Self.normalizeLineEndings)
        == expectedCurrent.map(Self.normalizeLineEndings)
      else {
        throw WorkspaceEditError.fileChanged(file: standardized)
      }
      if let text {
        try await execution.commit(text, over: snapshot) { replacement, url, previous in
          try Self.commitDocumentText(
            replacement,
            url: url,
            previousText: previous,
            operation: "file snapshot restore",
            allowDestructiveReplacement: true
          )
        }
      } else if snapshot.existed {
        try await execution.commit("", over: snapshot) { _, url, _ in
          try FileManager.default.removeItem(at: url)
        }
      }
    }
    guard isCurrentDocumentCorpusContext(context) else { return }

    if affectsSelectedFile, let text {
      isEditingEntry = false
      resetBlockState()
      if isLiveFileEditorSelected, selectedEntrySourceMode == .page {
        replaceEditableEntryTextFromModel(text)
        if let selectedEntrySource {
          self.selectedEntrySource = Self.entrySource(selectedEntrySource, replacingText: text)
        }
      }
    }

    invalidateCanonicalDocumentCache(for: standardized)
    if let corpusRoot {
      let refreshedFile = await Task.detached(priority: .utility) {
        Self.corpusFile(atPath: standardized, corpusRoot: corpusRoot)
      }.value
      if let refreshedFile {
        upsertCorpusFile(refreshedFile)
      } else {
        removeCorpusFile(atPath: standardized)
      }
    }

    if text == nil, affectsSelectedFile {
      selectedLocation = nil
      selectedEntrySource = nil
      selectedEntryHTML = nil
      replaceEditableEntryTextFromModel("")
      isEditingEntry = false
      resetBlockState()
    } else if let selectedLocation,
       URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path == standardized {
      await loadEntrySource(for: selectedLocation)
    }

    let message = "\(direction) edit in \(relativePath(standardized))"
    statusText = message
    if affectsSelectedFile && isLiveFileEditorSelected {
      liveFileEditorStatusText = direction
    }
    scheduleAgendaRefresh(preserveSelection: true)
  }

  public func handleDocumentKeyDown(_ event: NSEvent) -> Bool {
    guard selectedEntrySource?.isEditable == true,
          selectedBlock != nil,
          editingBlockID == nil,
          !isEditingEntry
    else {
      return false
    }

    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let key = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()

    if event.keyCode == 53, modifiers.isEmpty {
      clearSelectedBlock()
      return true
    }

    if event.keyCode == 36, modifiers.isEmpty {
      beginEditingSelectedBlock()
      return true
    }

    if event.keyCode == 36, modifiers == [.command] {
      Task { await insertBlockAfterSelected(.paragraph) }
      return true
    }

    if modifiers.isEmpty, key == "/" {
      Task { await insertBlockAfterSelected(.paragraph, initialText: "/") }
      return true
    }

    if modifiers.isEmpty {
      if event.keyCode == 126 || key == "k" {
        selectAdjacentBlock(.up)
        return true
      }
      if event.keyCode == 125 || key == "j" {
        selectAdjacentBlock(.down)
        return true
      }
      if event.keyCode == 123 {
        _ = collapseSelectedRenderedBlock()
        return true
      }
      if event.keyCode == 124 {
        _ = expandSelectedRenderedBlock()
        return true
      }
    }

    if modifiers == [.command] {
      if event.keyCode == 123 {
        collapseAllRenderedBlocks()
        return true
      }
      if event.keyCode == 124 {
        expandAllRenderedBlocks()
        return true
      }
    }

    if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty {
      Task { await deleteSelectedBlock() }
      return true
    }

    if modifiers == [.command], key == "d" {
      Task { await duplicateSelectedBlock() }
      return true
    }

    if modifiers == [.command, .shift] {
      if event.keyCode == 126 {
        Task { await moveSelectedBlock(.up) }
        return true
      }
      if event.keyCode == 125 {
        Task { await moveSelectedBlock(.down) }
        return true
      }
    }

    if modifiers.isEmpty,
       let insertionText = Self.directTypingInsertionText(from: event),
       beginEditingSelectedBlock(appending: insertionText) {
      return true
    }

    return false
  }

  public func handleAgendaKeyDown(_ event: NSEvent) -> Bool {
    guard selectedSurface == .agenda, activeWorkspacePane == .surface else { return false }

    let key = event.characters ?? event.charactersIgnoringModifiers ?? ""
    let keyIgnoringModifiers = event.charactersIgnoringModifiers ?? key
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

    if isAgendaFilterFocused {
      if event.keyCode == 53, modifiers.isEmpty {
        clearAgendaFilter()
        isAgendaFilterFocused = false
        return true
      }
      return false
    }

    if modifiers == [.command], keyIgnoringModifiers.lowercased() == "a" {
      selectAllVisibleAgendaItemsForBulkAction()
      return true
    }
    if modifiers == [.command, .shift], keyIgnoringModifiers.lowercased() == "a" {
      clearAgendaBulkSelection()
      return true
    }
    if modifiers == [.shift] {
      if event.keyCode == 125 {
        extendAgendaBulkSelection(by: 1)
        return true
      }
      if event.keyCode == 126 {
        extendAgendaBulkSelection(by: -1)
        return true
      }
    }

    let disallowedModifiers = event.modifierFlags.intersection([.command, .option])
    guard disallowedModifiers.isEmpty else { return false }

    if event.modifierFlags.contains(.control) {
      if event.charactersIgnoringModifiers == "d" {
        moveAgendaSelection(by: 8)
        return true
      }
      if event.charactersIgnoringModifiers == "u" {
        moveAgendaSelection(by: -8)
        return true
      }
      return false
    }

    if priorityModeActive {
      if event.keyCode == 53 {
        priorityModeActive = false
        statusText = "Priority change canceled"
        return true
      }

      switch key.lowercased() {
      case "a", "b", "c":
        priorityModeActive = false
        Task { await applyPriorityShortcut(key.uppercased()) }
      case "0":
        priorityModeActive = false
        Task { await applyPriorityShortcut(nil) }
      default:
        statusText = "Priority mode: press a, b, c, or 0 to clear"
      }
      return true
    }

    switch event.keyCode {
    case 36:
      openSelectedLocation()
      return true
    case 49:
      Task { await applyTodoShortcut(nil) }
      return true
    case 53:
      clearAgendaFilter()
      return true
    case 125:
      moveAgendaSelection(by: 1)
      return true
    case 126:
      moveAgendaSelection(by: -1)
      return true
    default:
      break
    }

    if pendingG {
      pendingG = false
      if key == "g" {
        selectFirstAgendaItem()
        return true
      }
    }

    switch key {
    case "J":
      requestDetailScroll(.down)
    case "K":
      requestDetailScroll(.up)
    case "j":
      moveAgendaSelection(by: 1)
    case "k":
      moveAgendaSelection(by: -1)
    case "g":
      pendingG = true
    case "G":
      selectLastAgendaItem()
    case "1", "2", "3", "4":
      setAgendaModeFromKey(key)
    case "/":
      focusAgendaFilter()
    case "r":
      if agendaMode == .assigned {
        Task { await refreshAssignedWork() }
      } else {
        Task { await refreshAgenda() }
      }
    case "o":
      openSelectedLocation()
    case "e":
      beginEditingVisibleBlock()
    case "p":
      priorityModeActive = true
      statusText = "Priority mode: press a, b, c, or 0 to clear"
    case "P":
      promptAndApplyPropertyShortcut()
    case "c":
      promptAndCaptureTodoShortcut()
    case "t":
      applyAgendaTodoShortcut(.todo)
    case "i":
      applyAgendaTodoShortcut(.inProgress)
    case "d":
      applyAgendaTodoShortcut(.done)
    case "x":
      applyAgendaTodoShortcut(.canceled)
    case "A":
      Task { await applyAgentHandoffShortcut() }
    case "s":
      Task { await applyPlanningShortcut(kind: .scheduled, target: .today) }
    case "n":
      Task { await applyPlanningShortcut(kind: .scheduled, target: .tomorrow) }
    case "w":
      Task { await applyPlanningShortcut(kind: .scheduled, target: .upcomingMonday) }
    case "m":
      Task { await applyPlanningShortcut(kind: .scheduled, target: .nextMonth) }
    case "S":
      Task { await applyPlanningShortcut(kind: .deadline, target: .today) }
    case "N":
      Task { await applyPlanningShortcut(kind: .deadline, target: .tomorrow) }
    case "W":
      Task { await applyPlanningShortcut(kind: .deadline, target: .upcomingMonday) }
    case "M":
      Task { await applyPlanningShortcut(kind: .deadline, target: .nextMonth) }
    case "q":
      NSApplication.shared.terminate(nil)
    default:
      return false
    }
    return true
  }

  func scheduleBacklinksLoad(for location: WorkspaceLocation) {
    backlinksLoadTask?.cancel()
    backlinksLoadTask = nil
    backlinksLoadGeneration += 1
    let generation = backlinksLoadGeneration
    isLoadingBacklinks = false
    backlinks = nil

    guard isNodeContextPanePresented else { return }
    isLoadingBacklinks = true

    let delay = backlinksSelectionIdleDelayNanoseconds
    backlinksLoadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if delay > 0 {
        do {
          try await Task.sleep(nanoseconds: delay)
        } catch {
          return
        }
      }
      guard !Task.isCancelled,
            generation == self.backlinksLoadGeneration,
            self.selectedLocationMatches(location)
      else {
        return
      }
      await self.loadBacklinks(for: location, generation: generation)
      if generation == self.backlinksLoadGeneration {
        self.backlinksLoadTask = nil
      }
    }
  }

  func cancelBacklinksLoad(clearResults: Bool) {
    backlinksLoadTask?.cancel()
    backlinksLoadTask = nil
    backlinksLoadGeneration += 1
    isLoadingBacklinks = false
    if clearResults {
      backlinks = nil
    }
  }

  public func loadBacklinks(for location: WorkspaceLocation) async {
    backlinksLoadTask?.cancel()
    backlinksLoadTask = nil
    backlinksLoadGeneration += 1
    let generation = backlinksLoadGeneration
    await loadBacklinks(for: location, generation: generation)
  }

  func loadBacklinks(for location: WorkspaceLocation, generation: Int) async {
    let testLoader = backlinksLoaderForTesting

    guard testLoader != nil || corpusRoot != nil else {
      backlinks = nil
      return
    }

    while isLoadingEntrySource || isRenderingEntrySource {
      guard !Task.isCancelled,
            generation == backlinksLoadGeneration,
            selectedLocationMatches(location)
      else { return }
      do {
        try await Task.sleep(nanoseconds: 20_000_000)
      } catch {
        return
      }
    }

    isLoadingBacklinks = true
    defer {
      if generation == backlinksLoadGeneration {
        isLoadingBacklinks = false
      }
    }

    do {
      let payload: BacklinksPayload?
      if let testLoader {
        payload = try await testLoader(location)
      } else {
        guard let corpusRoot else { return }
        guard let id = try await backlinkTargetID(for: location), !id.isEmpty else {
          guard generation == backlinksLoadGeneration, selectedLocationMatches(location) else { return }
          backlinks = nil
          return
        }

        let loadedPayload: BacklinksPayload = try await cli.runJSON([
          "backlinks",
          "--id", id,
          "--dir", corpusRoot.path,
          "--recursive",
          "--format", "json"
        ])
        payload = loadedPayload
      }

      guard !Task.isCancelled,
            generation == backlinksLoadGeneration,
            selectedLocationMatches(location)
      else { return }
      backlinks = payload
    } catch {
      guard !Task.isCancelled,
            generation == backlinksLoadGeneration,
            selectedLocationMatches(location)
      else { return }
      backlinks = nil
      errorText = error.localizedDescription
    }
  }

  func rebuildBacklinkDisplayCache() {
    guard let backlinks else {
      backlinkFileGroups = []
      relatedBacklinkNodes = []
      return
    }
    let grouped = Dictionary(grouping: backlinks.backlinks, by: \.file)
    backlinkFileGroups = grouped.map { file, items in
      let sortedItems = items.sorted {
        if $0.line != $1.line { return $0.line < $1.line }
        return $0.srcTitle.localizedCaseInsensitiveCompare($1.srcTitle) == .orderedAscending
      }
      return BacklinkFileGroup(
        file: file,
        relativePath: relativePath(file),
        backlinks: sortedItems
      )
    }
    .sorted { lhs, rhs in
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
    relatedBacklinkNodes = Self.relatedBacklinkNodes(
      from: backlinks.backlinks,
      relativePathForFile: { [weak self] file in
        self?.relativePath(file) ?? file
      }
    )
  }

  public var backlinkFileCount: Int {
    backlinkFileGroups.count
  }

  public var backlinkReferenceCount: Int {
    backlinks?.backlinks.count ?? 0
  }

  nonisolated private static func nodeBriefDisplayTitle(
    for location: WorkspaceLocation,
    source: EntrySource?
  ) -> String {
    if let source {
      let fallback = URL(fileURLWithPath: location.file).deletingPathExtension().lastPathComponent
      let title = Self.aiChatTitle(from: source.text, fallback: fallback).title
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !title.isEmpty { return title }
    }
    let title = location.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      return URL(fileURLWithPath: location.file).deletingPathExtension().lastPathComponent
    }
    return URL(fileURLWithPath: title).deletingPathExtension().lastPathComponent
  }

  func nodeBriefLookup(
    for location: WorkspaceLocation,
    sourceID explicitSourceID: String? = nil
  ) async -> NodeBriefLookupResult? {
    guard let corpusRoot else { return nil }
    let source = selectedEntrySource.flatMap { source -> EntrySource? in
      URL(fileURLWithPath: source.file).standardizedFileURL.path
        == URL(fileURLWithPath: location.file).standardizedFileURL.path ? source : nil
    }
    let input = NodeBriefLookupInput(
      corpusRoot: corpusRoot.standardizedFileURL,
      location: location,
      source: source,
      explicitSourceID: explicitSourceID,
      relativeFile: relativePath(location.file)
    )
    let observer = nodeBriefArtifactReadForTesting
    return await Task.detached(priority: .userInitiated) {
      observer?(Self.currentThreadIsMainForTesting())
      return Self.nodeBriefLookup(input)
    }.value
  }

  nonisolated static func nodeBriefLookup(
    _ input: NodeBriefLookupInput
  ) -> NodeBriefLookupResult {
    let location = input.location
    let source = input.source
    let sourceID = [
      input.explicitSourceID,
      location.idValue,
      source.flatMap { Self.firstOrgID(in: $0.text) }
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .first(where: { !$0.isEmpty })
    let file = input.relativeFile
    let line = location.lineForEditor
    let displayTitle = nodeBriefDisplayTitle(for: location, source: source)
    var relativePaths = [Self.nodeBriefArtifactRelativePath(
      id: sourceID,
      file: file,
      line: line
    )]
    var legacyTitles = [
      displayTitle,
      location.title,
      URL(fileURLWithPath: location.file).deletingPathExtension().lastPathComponent
    ]
    if let source {
      let fallback = URL(fileURLWithPath: location.file).deletingPathExtension().lastPathComponent
      legacyTitles.append(Self.aiChatTitle(from: source.text, fallback: fallback).title)
    }
    for title in legacyTitles where !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      relativePaths.append(Self.legacyNodeBriefArtifactRelativePath(
        title: title,
        id: sourceID,
        file: file,
        line: line
      ))
    }

    var seen = Set<String>()
    for relativePath in relativePaths where seen.insert(relativePath).inserted {
      let url = input.corpusRoot.appendingPathComponent(relativePath).standardizedFileURL
      if let artifact = Self.nodeBriefArtifact(at: url, relativePath: relativePath) {
        return NodeBriefLookupResult(
          title: displayTitle,
          artifact: artifact
        )
      }
    }
    return NodeBriefLookupResult(
      title: displayTitle,
      artifact: nil
    )
  }

  func scheduleCurrentNodeBriefArtifactRefresh() {
    currentNodeBriefArtifactGeneration &+= 1
    let generation = currentNodeBriefArtifactGeneration
    currentNodeBriefArtifactTask?.cancel()
    guard let location = selectedLocation, corpusRoot != nil else {
      currentNodeBriefArtifact = nil
      currentNodeBriefArtifactTask = nil
      return
    }
    currentNodeBriefArtifactTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let lookup = await self.nodeBriefLookup(for: location)
      guard !Task.isCancelled,
            self.currentNodeBriefArtifactGeneration == generation,
            self.selectedLocation == location
      else { return }
      self.currentNodeBriefArtifact = lookup?.artifact
      self.currentNodeBriefArtifactTask = nil
    }
  }

  func waitForCurrentNodeBriefArtifactForTesting() async {
    await currentNodeBriefArtifactTask?.value
  }

  public func openCurrentNodeBriefArtifact() {
    guard let location = selectedLocation,
          let artifact = currentNodeBriefArtifact else {
      statusText = "No cached node brief yet"
      return
    }
    openNodeBriefArtifact(
      url: URL(fileURLWithPath: artifact.file).standardizedFileURL,
      relativePath: artifact.relativePath,
      title: location.title,
      modifiedAt: artifact.modifiedAt
    )
  }
}
