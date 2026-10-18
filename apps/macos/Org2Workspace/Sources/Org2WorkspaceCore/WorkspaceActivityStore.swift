import Foundation

extension WorkspaceStore {
  /// Builds the shared activity model from in-memory workspace state. Cheap
  /// enough to call from a view body: it is linear in runs, threads,
  /// approvals, workflows, and corpus files, and reads no files.
  public func activitySnapshot(now: Date = Date()) -> WorkspaceActivitySnapshot {
    var snapshot = WorkspaceActivitySnapshot()
    let root = corpusRoot?.standardizedFileURL.path
    let profileNames = Dictionary(
      agentProfiles.map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first }
    )
    func relative(_ path: String?) -> String? {
      guard let path, !path.isEmpty else { return nil }
      return WorkspaceActivityMap.relativePath(fromReference: path, corpusRoot: root)
    }
    func agentName(agentRef: String?, fallback: String?) -> String? {
      if let agentRef, let name = profileNames[agentRef] { return name }
      return fallback?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyActivity
    }

    // Live chat turns.
    var representedThreadIDs = Set<UUID>()
    for thread in aiChatThreads where !thread.isArchived {
      let running = isAIChatThreadRunning(thread.id)
      let destination = aiChatDestination(id: thread.destinationID)?.title
      if running {
        representedThreadIDs.insert(thread.id)
        snapshot.working.append(WorkspaceActivityItem(
          id: "thread:\(thread.id.uuidString)",
          kind: .working,
          title: thread.title,
          detail: thread.resource.map { "Chat on \(relativePathOrName($0.file))" } ?? "Chat turn in progress",
          agent: agentName(agentRef: thread.agentRef, fallback: destination ?? thread.runtime.title),
          relativePath: relative(thread.resource?.file),
          date: thread.updatedAt,
          state: .working,
          target: .thread(thread.id)
        ))
      } else if thread.latestDeliveryNeedsAttention {
        representedThreadIDs.insert(thread.id)
        snapshot.needsYou.append(WorkspaceActivityItem(
          id: "thread:\(thread.id.uuidString)",
          kind: .needsYou,
          title: thread.title,
          detail: "Latest message needs attention",
          agent: agentName(agentRef: thread.agentRef, fallback: destination),
          relativePath: relative(thread.resource?.file),
          date: thread.updatedAt,
          state: .needsYou,
          target: .thread(thread.id)
        ))
      }
    }

    // Unified decision queue. One run can request many decisions (a scout
    // proposing twenty outreach emails); show it once with a count.
    var runIDsWithApprovals = Set<String>()
    let runsByID = Dictionary(agentRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var approvalGroups: [String: [ApprovalItem]] = [:]
    var approvalGroupOrder: [String] = []
    for approval in approvalItems {
      if let runID = approval.runId { runIDsWithApprovals.insert(runID) }
      let key = approval.runId.map { "run:\($0)" } ?? "approval:\(approval.id)"
      if approvalGroups[key] == nil { approvalGroupOrder.append(key) }
      approvalGroups[key, default: []].append(approval)
    }
    for key in approvalGroupOrder {
      guard let group = approvalGroups[key], !group.isEmpty else { continue }
      let newest = group.max {
        ($0.requestedAt.flatMap(Self.activityDate) ?? .distantPast)
          < ($1.requestedAt.flatMap(Self.activityDate) ?? .distantPast)
      } ?? group[0]
      let run = newest.runId.flatMap { runsByID[$0] }
      // Run-backed approvals live in .org2/runs (or .celorga/runs); place them at the run's cited source.
      var approvalPath = relative(newest.file)
      if approvalPath.map(CelorgaNames.isStateRelativePath) == true,
         let cited = run?.context.lazy.compactMap({ relative($0.fileReference) }).first {
        approvalPath = cited
      }
      let title: String
      let detail: String
      if group.count == 1 {
        title = Org2Display.cleanInline(newest.title)
        detail = newest.action.map { "Approve: \($0)" } ?? "Waiting for your decision"
      } else {
        title = Self.activityApprovalGroupTitle(group.map { Org2Display.cleanInline($0.title) }, run: run)
        detail = "\(group.count) decisions waiting"
      }
      snapshot.needsYou.append(WorkspaceActivityItem(
        id: group.count == 1 ? "approval:\(newest.id)" : "approvals:\(key)",
        kind: .needsYou,
        title: title,
        detail: detail,
        agent: newest.requestedFrom,
        relativePath: approvalPath,
        date: newest.requestedAt.flatMap(Self.activityDate),
        state: .needsYou,
        target: .approval(newest.id),
        count: group.count
      ))
    }

    // Plugin proposals (from actions or lifecycle hooks) awaiting review.
    for proposal in pendingPluginProposals {
      snapshot.needsYou.append(WorkspaceActivityItem(
        id: "plugin-proposal:\(proposal.id)",
        kind: .needsYou,
        title: proposal.source.title,
        detail: "\(proposal.proposals.count) change\(proposal.proposals.count == 1 ? "" : "s") proposed by \(proposal.source.pluginName)",
        agent: proposal.source.pluginName,
        relativePath: proposal.proposals.lazy.compactMap(\.path).first,
        date: Self.activityDate(proposal.createdAt),
        state: .needsYou,
        target: .pluginProposal(proposal.id)
      ))
    }

    // Durable runs.
    for run in agentRuns where !run.isFinished {
      let threadID = Self.activityThreadID(in: run)
      let threadExists = threadID.map { id in aiChatThreads.contains { $0.id == id } } ?? false
      let threadRunning = threadID.map(isAIChatThreadRunning) ?? false
      guard let state = HeadingWorkStatus.state(for: run, threadRunning: threadRunning, hasThread: threadExists) else {
        continue
      }
      if let threadID, representedThreadIDs.contains(threadID), state == .working { continue }
      if state == .needsYou, runIDsWithApprovals.contains(run.id) { continue }
      // Old open runs are history, not current activity. Keep them out of
      // Now and the map; the Runs queue still lists every one.
      if !threadRunning,
         !WorkspaceActivityPolicy.isCurrent(state: state, updatedAt: Self.activityDate(run.updatedAt), now: now) {
        snapshot.hiddenOlderCount += 1
        continue
      }
      let path = run.context.lazy.compactMap { relative($0.fileReference) }.first
      let title = run.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyActivity ?? run.goal
      let agent = agentName(agentRef: run.agentRef, fallback: run.assignee ?? run.owner)
      let item = WorkspaceActivityItem(
        id: "run:\(run.id)",
        kind: state.needsAttention ? .needsYou : .working,
        title: title,
        detail: Self.activityRunDetail(run, state: state),
        agent: agent,
        relativePath: path,
        date: Self.activityDate(run.updatedAt),
        state: state,
        target: threadExists && state != .needsYou ? .thread(threadID!) : .run(run.id)
      )
      if item.kind == .needsYou {
        snapshot.needsYou.append(item)
      } else {
        snapshot.working.append(item)
      }
    }

    // Scheduled automations.
    for workflow in agentWorkflows {
      guard let trigger = workflow.scheduleTrigger, trigger.enabled,
            let expression = trigger.schedule,
            workflow.state.lowercased() == "active"
      else { continue }
      let schedule = AutomationScheduleDraft(expression: expression).summary
      snapshot.scheduled.append(WorkspaceActivityItem(
        id: "workflow:\(workflow.id)",
        kind: .scheduled,
        title: workflow.title,
        detail: schedule,
        agent: agentName(agentRef: workflow.agentRef, fallback: workflow.destinationRef.flatMap { aiChatDestination(id: $0)?.title }),
        relativePath: relative(workflow.file),
        date: nil,
        state: nil,
        target: .workflow(workflow.id)
      ))
    }

    // Recently changed files.
    let recentCutoff = now.addingTimeInterval(-24 * 3600)
    snapshot.changed = corpusFiles
      .lazy
      .filter { ($0.modifiedAt ?? .distantPast) >= recentCutoff }
      .filter { !WorkspaceActivityPolicy.isMachineManaged($0.relativePath) }
      .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
      .prefix(WorkspaceActivityPolicy.changedFileLimit)
      .map { file in
        WorkspaceActivityItem(
          id: "file:\(file.relativePath)",
          kind: .changed,
          title: file.name,
          detail: file.directory.isEmpty ? "Top level" : file.directory,
          relativePath: file.relativePath,
          date: file.modifiedAt,
          target: .file(path: file.path, line: nil)
        )
      }

    let byDateDescending: (WorkspaceActivityItem, WorkspaceActivityItem) -> Bool = {
      ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
    }
    snapshot.needsYou.sort(by: byDateDescending)
    snapshot.working.sort(by: byDateDescending)
    snapshot.scheduled.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    return snapshot
  }

  public func activityMapAreas(prefix: String, snapshot: WorkspaceActivitySnapshot, now: Date = Date()) -> [WorkspaceActivityArea] {
    WorkspaceActivityMap.areas(
      files: corpusFiles,
      items: snapshot.allItems,
      prefix: prefix,
      now: now,
      visitScores: fileFrecencyScores(now: now)
    )
  }

  public func openActivityItem(_ item: WorkspaceActivityItem) {
    usageLog.record(.activityOpen, ["kind": .string(item.kind.rawValue), "target": .string(Self.activityTargetKind(item.target))])
    switch item.target {
    case .thread(let id):
      openHeadingWork(threadID: id, runID: nil)
    case .run(let id):
      openHeadingWork(threadID: nil, runID: id)
    case .approval(let id):
      openReviewQueue()
      if let approval = approvalItems.first(where: { $0.id == id }) {
        selectApprovalItem(approval)
      }
    case .workflow(let id):
      openAutomations()
      if let workflow = agentWorkflows.first(where: { $0.id == id }) {
        selectAgentWorkflow(workflow)
      }
    case .file(let path, let line):
      setPendingNavigationSource("activity")
      openChatFileReference(AIChatFileReference(path: path, line: line))
    case .pluginProposal(let id):
      Task { await reviewPluginProposal(id: id) }
    }
  }

  /// Opens the full run history behind Activity's "older runs" note.
  public func openActivityRuns() {
    usageLog.record(.activityOpen, ["kind": "older", "target": "runs"])
    runsAndReviewPage = .runs
    makeSurfacePrimary(.approvals)
    statusText = "Runs is primary"
  }

  public func openActivityMapFile(relativePath: String) {
    guard let file = corpusFiles.first(where: { $0.relativePath == relativePath }) else { return }
    usageLog.record(.activityMapNavigate, ["action": "open_file"])
    setPendingNavigationSource("activity_map")
    selectCorpusFile(file, surface: selectedSurface)
  }

  func refreshActivitySources() async {
    refreshCorpusAutomationHostRef()
    scheduleAIChatLiveRefresh()
    // A paired server that is unreachable must not delay the run refresh.
    let serverStatus = Task { @MainActor [openOrgServer] in await openOrgServer.refreshStatus() }
    await refreshAgentRuns()
    await refreshApprovals()
    await refreshAgentWorkflows()
    await refreshPluginActions()
    await serverStatus.value
  }

  private func relativePathOrName(_ path: String) -> String {
    let value = relativePath(path)
    return value.hasPrefix("/") ? URL(fileURLWithPath: path).lastPathComponent : value
  }

  nonisolated static func activityThreadID(in run: AgentRunItem) -> UUID? {
    for comment in run.comments.reversed() {
      guard let range = comment.body.range(
        of: #"AI chat thread:?\s+[0-9A-Fa-f-]{36}"#,
        options: .regularExpression
      ) else { continue }
      let match = comment.body[range]
      if let id = UUID(uuidString: String(match.suffix(36))) { return id }
    }
    return nil
  }

  /// One title for several decisions requested by the same run.
  nonisolated static func activityApprovalGroupTitle(_ titles: [String], run: AgentRunItem?) -> String {
    // Titles such as "Example Reviewer review: Acme / a@acme.com" share a prefix
    // that names the batch better than the run's own title.
    let prefixes = Set(titles.map { title -> String in
      guard let colon = title.firstIndex(of: ":") else { return title }
      return String(title[..<colon]).trimmingCharacters(in: .whitespaces)
    })
    if prefixes.count == 1, let prefix = prefixes.first, !prefix.isEmpty { return prefix }
    if let runTitle = run?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !runTitle.isEmpty {
      return runTitle
    }
    return run?.goal.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyActivity ?? titles.first ?? "Decisions"
  }

  nonisolated static func activityRunDetail(_ run: AgentRunItem, state: HeadingWorkState) -> String {
    switch state {
    case .yourTurn: return "Agent replied, waiting for you"
    case .needsYou:
      if let reason = run.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
        return "Blocked: \(reason)"
      }
      return run.pendingApprovals.isEmpty ? "Needs your review" : "Waiting for approval"
    case .failed: return run.failure.map { "Failed: \($0)" } ?? "Run failed"
    case .queued: return "Queued run"
    case .working: return run.workflowId.map { "Automation \($0) running" } ?? "Run in progress"
    case .done: return "Completed"
    }
  }

  nonisolated static func activityDate(_ raw: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: raw) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: raw)
  }

  private nonisolated static func activityTargetKind(_ target: WorkspaceActivityItem.Target) -> String {
    switch target {
    case .thread: "thread"
    case .run: "run"
    case .approval: "approval"
    case .workflow: "workflow"
    case .file: "file"
    case .pluginProposal: "plugin_proposal"
    }
  }
}

private extension String {
  var nilIfEmptyActivity: String? { isEmpty ? nil : self }
}
