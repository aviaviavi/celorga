import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  func localWhisperConfiguration(includeCustomCommand: Bool) -> LocalWhisperConfiguration {
    LocalWhisperConfiguration(
      modelOverride: whisperModelPathText,
      commandOverride: includeCustomCommand ? customTranscriptionCommandText : nil,
      languageOverride: transcriptionLanguageText
    )
  }

  public func installFastMeetingTranscriber() async {
    guard !isInstallingFastTranscriber else { return }
    isInstallingFastTranscriber = true
    audioSettingsStatusText = "Installing whisper.cpp and base English model..."

    do {
      try await Task.detached(priority: .userInitiated) {
        try Self.installWhisperCppAndDefaultModel()
      }.value
      audioSettingsStatusText = "Installed whisper.cpp and base English model"
      statusText = "Audio transcription fast path installed"
    } catch {
      audioSettingsStatusText = error.localizedDescription
      errorText = error.localizedDescription
      statusText = "Audio transcription install failed"
    }
    isInstallingFastTranscriber = false
    await refreshAudioSettingsStatusAsync(preserveStatusText: true)
  }

  public func refreshWorkspaceHealth() {
    isCheckingWorkspaceHealth = true
    defer { isCheckingWorkspaceHealth = false }
    workspaceHealthChecks = Self.workspaceHealthChecks(cli: cli, corpusRoot: corpusRoot)
    let blockingCount = workspaceHealthChecks.filter { $0.status == .blocking }.count
    let warningCount = workspaceHealthChecks.filter { $0.status == .warning }.count
    if blockingCount > 0 {
      statusText = "\(blockingCount) setup blocker\(blockingCount == 1 ? "" : "s")"
    } else if warningCount > 0 {
      statusText = "\(warningCount) setup warning\(warningCount == 1 ? "" : "s")"
    } else {
      statusText = "Workspace setup looks ready"
    }
  }

  public func refreshCorpusFiles() async {
    guard let corpusRoot else {
      resetCorpusFileCatalogMutations()
      corpusFiles = []
      pinnedFileRelativePaths = []
      orgRoamLinkResolverGeneration &+= 1
      orgRoamLinkResolverRefreshTask?.cancel()
      orgRoamLinkResolverRefreshTask = nil
      publishEmptyOrgRoamSearchProjection()
      searchIndexTask?.cancel()
      searchIndexTask = nil
      searchIndexGeneration += 1
      isBuildingSearchIndex = false
      searchIndexStatusText = ""
      return
    }

    let root = corpusRoot.standardizedFileURL
    let sessionGeneration = corpusSessionGeneration
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.files, default: 0]
    let canvasDirtyGeneration = workspaceSurfaceDirtyGenerations[.canvases, default: 0]
    isScanningCorpusFiles = true
    defer {
      if isCurrentCorpusSession(root: root, generation: sessionGeneration) {
        isScanningCorpusFiles = false
      }
    }

    do {
      let files: [CorpusFile]
      if let corpusFileScanForTesting {
        files = try await corpusFileScanForTesting(root)
      } else {
        files = try await Task.detached(priority: .utility) {
          try Self.scanCorpusFiles(corpusRoot: root)
        }.value
      }
      guard !Task.isCancelled,
            isCurrentCorpusSession(root: root, generation: sessionGeneration)
      else { return }
      let currentFiles = corpusFiles
      let filesChanged = await Task.detached(priority: .utility) {
        currentFiles != files
      }.value
      guard !Task.isCancelled,
            isCurrentCorpusSession(root: root, generation: sessionGeneration)
      else { return }
      if filesChanged {
        corpusFiles = files
        corpusFilesAwaitingProjection = true
      }
      // Projection is tracked apart from the file list: a scan cancelled after
      // publishing files but before projecting them must not leave links and
      // search empty until some file changes again.
      if corpusFilesAwaitingProjection {
        await awaitCorpusFilePublication()
        guard !Task.isCancelled,
              isCurrentCorpusSession(root: root, generation: sessionGeneration)
        else { return }
        corpusFilesAwaitingProjection = false
        refreshOrgRoamLinkResolver(files: corpusFiles)
        scheduleSearchIndexBuild(corpusRoot: root, sessionGeneration: sessionGeneration)
      }
      await reconcilePinnedFiles(for: root)
      markWorkspaceSurfaceCleanIfUnchanged(.files, generation: dirtyGeneration)
      markWorkspaceSurfaceCleanIfUnchanged(.canvases, generation: canvasDirtyGeneration)
      if selectedSurface == .files {
        statusText = "\(files.count) corpus file\(files.count == 1 ? "" : "s")"
      }
    } catch {
      guard !Task.isCancelled,
            isCurrentCorpusSession(root: root, generation: sessionGeneration)
      else { return }
      orgRoamLinkResolverGeneration &+= 1
      orgRoamLinkResolverRefreshTask?.cancel()
      orgRoamLinkResolverRefreshTask = nil
      publishEmptyOrgRoamSearchProjection()
      errorText = error.localizedDescription
      statusText = "File scan failed"
    }
  }

  public func refreshAgenda(preserveSelection: Bool = false, updatesStatus: Bool = true, clearsError: Bool = true) async {
    guard agendaTodoShortcutMutationTask == nil,
          pendingAgendaTodoShortcutMutations.isEmpty
    else {
      // Keyboard TODO shortcuts remove rows optimistically. Replacing that
      // coherent local snapshot with a partially-written disk snapshot makes
      // completed rows briefly reappear and moves the cursor underneath the
      // user. Reconcile once the entire key burst has settled instead.
      agendaRefreshDeferredForTodoShortcutBurst = true
      return
    }

    guard !isRefreshingAgenda else {
      if updatesStatus {
        statusText = "Agenda already refreshing"
      }
      return
    }

    guard let corpusRoot else {
      if updatesStatus {
        statusText = "No corpus selected"
      }
      return
    }

    let sessionGeneration = corpusSessionGeneration
    let todoMutationGeneration = agendaTodoShortcutMutationGeneration
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.agenda, default: 0]
    isRefreshingAgenda = true
    let showsLoading = updatesStatus || agenda == nil
    if showsLoading {
      isLoadingAgenda = true
    }
    if clearsError { errorText = nil }
    defer {
      if isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) {
        isRefreshingAgenda = false
        if showsLoading { isLoadingAgenda = false }
      }
    }

    do {
      let now = Date()
      let today = Self.formatDate(now)
      let end = Self.formatDate(
        Self.agendaRefreshEndDate(from: now)
      )
      let federates = agendaReadScope == .allCorpora && workspaceMountPaths().count > 1
      var arguments = federates
        ? ["workspace", "agenda"] + workspaceMountArguments()
        : ["agenda", "--dir", corpusRoot.path]
      arguments += [
        "--recursive",
        "--from", today,
        "--to", end,
        "--format", "json",
        "--workload"
      ]
      let payload: AgendaPayload
      if let agendaRefreshLoaderForTesting {
        payload = try await agendaRefreshLoaderForTesting(arguments)
      } else {
        payload = try await cli.runJSON(arguments)
      }
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      guard todoMutationGeneration == agendaTodoShortcutMutationGeneration else {
        agendaRefreshDeferredForTodoShortcutBurst = true
        scheduleAgendaRefresh(preserveSelection: true, updatesStatus: false)
        return
      }
      guard agendaTodoShortcutMutationTask == nil,
            pendingAgendaTodoShortcutMutations.isEmpty
      else {
        agendaRefreshDeferredForTodoShortcutBurst = true
        return
      }
      agenda = payload
      syncAgendaSelectionAfterRefresh(preserveSelection: preserveSelection)
      markWorkspaceSurfaceCleanIfUnchanged(.agenda, generation: dirtyGeneration)
      if updatesStatus {
        let issueSuffix = payload.issues?.isEmpty == false ? ", \(payload.issues!.count) corpus issue\(payload.issues!.count == 1 ? "" : "s")" : ""
        statusText = "\(payload.totalItemCount) agenda item\(payload.totalItemCount == 1 ? "" : "s")\(issueSuffix)"
      }
    } catch {
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      errorText = error.localizedDescription
      if updatesStatus {
        statusText = "Agenda failed"
      }
    }
  }

  public func refreshApprovals(updatesStatus: Bool = false, clearsError: Bool = true) async {
    guard !isRefreshingApprovals else {
      // Never drop a refresh request. The in-flight scan may have read the
      // corpus before a decision was written, so a follow-up scan must run.
      approvalRefreshRequestedAfterCurrent = true
      if updatesStatus {
        approvalRefreshFollowUpUpdatesStatus = true
        isLoadingApprovals = true
        statusText = "Refreshing approvals next..."
      }
      return
    }

    guard let corpusRoot else {
      if updatesStatus {
        statusText = "No corpus selected"
      }
      return
    }
    guard let refreshContext = captureRunReviewPageRefresh(.review) else { return }

    isRefreshingApprovals = true
    let mutationGenerationAtStart = approvalMutationGeneration
    approvalLoadErrorText = nil
    let showsLoading = updatesStatus
      || (approvalItems.isEmpty && !runReviewPageLoadState(for: .review).isLoaded)
    if showsLoading {
      isLoadingApprovals = true
    }
    if clearsError { errorText = nil }
    defer {
      if isCurrentRunReviewPageRefresh(refreshContext) {
        let shouldRefreshAgain = approvalRefreshRequestedAfterCurrent
        let followUpUpdatesStatus = approvalRefreshFollowUpUpdatesStatus
        approvalRefreshRequestedAfterCurrent = false
        approvalRefreshFollowUpUpdatesStatus = false
        isRefreshingApprovals = false
        hasCompletedApprovalsLoad = true
        markRunReviewPageRefreshTerminal(refreshContext)
        if shouldRefreshAgain {
          if followUpUpdatesStatus {
            isLoadingApprovals = true
          } else if showsLoading {
            isLoadingApprovals = false
          }
          Task { @MainActor [weak self] in
            await self?.refreshApprovals(updatesStatus: followUpUpdatesStatus)
          }
        } else if showsLoading {
          isLoadingApprovals = false
        }
      }
    }
    if updatesStatus {
      statusText = "Scanning approvals..."
    }
    let runDetailIDsBeforeRefresh = approvalRunDetailIDsForRefresh()

    do {
      do {
        var arguments = [
          "approvals",
          "--dir", corpusRoot.path,
          "--recursive",
          "--include-snoozed",
          "--format", "json"
        ]
        for runID in runDetailIDsBeforeRefresh.sorted() {
          arguments.append(contentsOf: ["--run-detail", runID])
        }
        let payload: ApprovalPayload
        if let approvalQueueLoaderForTesting {
          let loaded = try await approvalQueueLoaderForTesting()
          payload = ApprovalPayload(count: loaded.items.count, items: loaded.items, runDetails: loaded.runDetails)
        } else {
          payload = try await cli.runJSON(arguments)
        }
        guard !Task.isCancelled,
              isCurrentRunReviewPageRefresh(refreshContext)
        else { return }
        guard approvalMutationGeneration == mutationGenerationAtStart else {
          requestApprovalRefreshAfterStaleScan(updatesStatus: updatesStatus)
          return
        }
        let partitionedApprovalItems = Self.partitionSnoozedApprovalItems(
          Self.sortedApprovalItems(payload.items)
        )
        let nextApprovalItems = partitionedApprovalItems.awake
        let nextSnoozedApprovalItems = partitionedApprovalItems.snoozed
        let currentApprovalItems = approvalItems
        let approvalsChanged = await Task.detached(priority: .utility) {
          currentApprovalItems != nextApprovalItems
        }.value
        guard !Task.isCancelled,
              isCurrentRunReviewPageRefresh(refreshContext)
        else { return }
        guard approvalMutationGeneration == mutationGenerationAtStart else {
          requestApprovalRefreshAfterStaleScan(updatesStatus: updatesStatus)
          return
        }
        if approvalsChanged {
          approvalItems = nextApprovalItems
        }
        if snoozedApprovalItems != nextSnoozedApprovalItems {
          snoozedApprovalItems = nextSnoozedApprovalItems
        }
        scheduleApprovalSnoozeWake()
        syncApprovalSelectionAfterRefresh()
        let inlineRunDetails = payload.runDetails ?? []
        applyRefreshedApprovalRuns(inlineRunDetails)
        let inlineRunDetailIDs = Set(inlineRunDetails.map(\.id))
        let detailError = await refreshApprovalRunDetails(
          runDetailIDsBeforeRefresh
            .union(approvalRunDetailIDsForRefresh())
            .subtracting(inlineRunDetailIDs),
          context: refreshContext
        )
        guard !Task.isCancelled,
              isCurrentRunReviewPageRefresh(refreshContext)
        else { return }
        if let detailError {
          approvalLoadErrorText = detailError
          errorText = detailError
          if updatesStatus {
            statusText = "Approval details failed to refresh"
          }
          return
        }
        if updatesStatus {
          statusText = "\(payload.count) approval\(payload.count == 1 ? "" : "s")"
        }
        return
      } catch {
        guard isCurrentRunReviewPageRefresh(refreshContext) else { return }
        if updatesStatus {
          statusText = "Falling back to local approval scan..."
        }
      }

      let candidateSources: [ApprovalCandidateSource]
      if corpusFiles.isEmpty {
        let indexedCandidates = await Task.detached(priority: .utility) {
          return Self.approvalCandidateSourcesFromStoredIndex(corpusRoot: corpusRoot)
        }.value
        guard !Task.isCancelled,
              isCurrentRunReviewPageRefresh(refreshContext)
        else { return }
        if let indexedCandidates {
          candidateSources = indexedCandidates
        } else {
          if updatesStatus {
            statusText = "Scanning approval candidates..."
          }
          let files = try await Task.detached(priority: .utility) {
            try Self.scanCorpusFiles(corpusRoot: corpusRoot)
          }.value
          guard !Task.isCancelled,
                isCurrentRunReviewPageRefresh(refreshContext)
          else { return }
          corpusFiles = files
          await awaitCorpusFilePublication()
          guard !Task.isCancelled,
                isCurrentRunReviewPageRefresh(refreshContext)
          else { return }
          candidateSources = await approvalCandidateSources(
            files: files,
            corpusRoot: corpusRoot,
            updatesStatus: updatesStatus
          )
          guard !Task.isCancelled,
                isCurrentRunReviewPageRefresh(refreshContext)
          else { return }
        }
      } else {
        candidateSources = await approvalCandidateSources(
          files: corpusFiles,
          corpusRoot: corpusRoot,
          updatesStatus: updatesStatus
        )
        guard !Task.isCancelled,
              isCurrentRunReviewPageRefresh(refreshContext)
        else { return }
      }
      if updatesStatus {
        statusText = candidateSources.isEmpty
          ? "0 approval candidates"
          : "Checking \(candidateSources.count) approval candidate file\(candidateSources.count == 1 ? "" : "s")"
      }
      var items: [ApprovalItem] = []
      for candidate in candidateSources {
        guard FileManager.default.fileExists(atPath: candidate.file.path) else {
          continue
        }
        let document: Org2CanonicalDocument = try await cli.parseTextJSON(
          candidate.parseText,
          sourceRanges: true,
          sourceLineOffset: candidate.sourceLineOffset,
          sourcePath: candidate.file.path
        )
        guard !Task.isCancelled,
              isCurrentRunReviewPageRefresh(refreshContext)
        else { return }
        items.append(contentsOf: Self.approvalItems(
          in: document,
          file: candidate.file.path,
          sourceText: candidate.sourceText,
          sourceLineOffset: candidate.sourceLineOffset
        ))
      }
      let nextApprovalItems = Self.sortedApprovalItems(items)
      let currentApprovalItems = approvalItems
      let approvalsChanged = await Task.detached(priority: .utility) {
        currentApprovalItems != nextApprovalItems
      }.value
      guard !Task.isCancelled,
            isCurrentRunReviewPageRefresh(refreshContext)
      else { return }
      guard approvalMutationGeneration == mutationGenerationAtStart else {
        requestApprovalRefreshAfterStaleScan(updatesStatus: updatesStatus)
        return
      }
      if approvalsChanged {
        approvalItems = nextApprovalItems
      }
      syncApprovalSelectionAfterRefresh()
      let detailError = await refreshApprovalRunDetails(
        runDetailIDsBeforeRefresh.union(approvalRunDetailIDsForRefresh()),
        context: refreshContext
      )
      guard !Task.isCancelled,
            isCurrentRunReviewPageRefresh(refreshContext)
      else { return }
      if let detailError {
        approvalLoadErrorText = detailError
        errorText = detailError
        if updatesStatus {
          statusText = "Approval details failed to refresh"
        }
        return
      }
      if updatesStatus {
        statusText = "\(approvalItems.count) approval\(approvalItems.count == 1 ? "" : "s")"
      }
    } catch {
      guard isCurrentRunReviewPageRefresh(refreshContext) else { return }
      approvalLoadErrorText = error.localizedDescription
      errorText = error.localizedDescription
      if updatesStatus {
        statusText = "Approvals failed"
      }
    }
  }

  private func approvalRunDetailIDsForRefresh() -> Set<AgentRunItem.ID> {
    var runIDs = Set<AgentRunItem.ID>()
    if let presentedAgentRunID {
      runIDs.insert(presentedAgentRunID)
    }
    if let selectedApprovalItemID,
       let selectedItem = approvalItems.first(where: { $0.id == selectedApprovalItemID }),
       let runID = selectedItem.runId {
      runIDs.insert(runID)
    }
    return runIDs
  }

  private func refreshApprovalRunDetails(
    _ runIDs: Set<AgentRunItem.ID>,
    context: RunReviewPageRefreshContext
  ) async -> String? {
    guard !runIDs.isEmpty,
          isCurrentRunReviewPageRefresh(context)
    else { return nil }
    let corpusRoot = URL(fileURLWithPath: context.corpusRootPath)

    var refreshedRuns: [AgentRunItem] = []
    refreshedRuns.reserveCapacity(runIDs.count)
    for runID in runIDs.sorted() {
      guard !mutatingAgentRunIDs.contains(runID) else { continue }
      do {
        let run: AgentRunItem
        if let agentRunDetailLoaderForTesting {
          run = try await agentRunDetailLoaderForTesting(runID)
        } else {
          run = try await cli.runJSON([
            "run", "show", runID,
            "--dir", corpusRoot.path,
            "--json"
          ])
        }
        guard !Task.isCancelled,
              isCurrentRunReviewPageRefresh(context)
        else { return nil }
        refreshedRuns.append(run)
      } catch {
        guard isCurrentRunReviewPageRefresh(context) else { return nil }
        return "The approval list refreshed, but run \(runID) did not: \(error.localizedDescription)"
      }
    }
    guard !Task.isCancelled,
          isCurrentRunReviewPageRefresh(context),
          !refreshedRuns.isEmpty
    else { return nil }

    applyRefreshedApprovalRuns(refreshedRuns)
    return nil
  }

  private func applyRefreshedApprovalRuns(_ refreshedRuns: [AgentRunItem]) {
    guard !refreshedRuns.isEmpty else { return }
    var nextRuns = agentRuns
    for refreshedRun in refreshedRuns {
      if let index = nextRuns.firstIndex(where: { $0.id == refreshedRun.id }) {
        // Keep a newer local copy (for example, the run returned by a decision
        // that landed while this scan was reading older files).
        guard !Self.isAgentRun(nextRuns[index], newerThan: refreshedRun) else { continue }
        nextRuns[index] = refreshedRun
      } else {
        nextRuns.insert(refreshedRun, at: 0)
      }
    }
    if nextRuns != agentRuns {
      agentRuns = nextRuns
    }

    if runsAndReviewPage == .review,
       selectedSurface == .approvals,
       let selectedApprovalItemID,
       let selectedItem = approvalItems.first(where: { $0.id == selectedApprovalItemID }),
       let runID = selectedItem.runId,
       let run = agentRunsByID[runID] {
      selectAgentRun(run)
      self.selectedApprovalItemID = selectedItem.id
    }
  }

  public func refreshRunReviewData() async {
    guard let corpusRoot else { return }
    let sessionGeneration = corpusSessionGeneration
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.approvals, default: 0]
    await refreshApprovals()
    guard isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
    await refreshAgentRuns()
    guard isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
    await refreshAgentWorkflows()
    guard isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
    await refreshAgentGoals()
    guard isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
    await refreshAgentProfiles()
    guard isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
    markWorkspaceSurfaceCleanIfUnchanged(.approvals, generation: dirtyGeneration)
  }

  public func refreshSelectedRunReviewPage(updatesStatus: Bool = false) async {
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.approvals, default: 0]
    await refreshRunReviewPage(runsAndReviewPage, updatesStatus: updatesStatus)
    markWorkspaceSurfaceCleanIfUnchanged(.approvals, generation: dirtyGeneration)
  }

  public func refreshSelectedRunReviewPageIfNeeded(updatesStatus: Bool = false) async {
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.approvals, default: 0]
    let page = runsAndReviewPage
    guard runReviewPageNeedsRefresh(page) else {
      markWorkspaceSurfaceCleanIfUnchanged(.approvals, generation: dirtyGeneration)
      return
    }
    await refreshRunReviewPage(page, updatesStatus: updatesStatus)
    markWorkspaceSurfaceCleanIfUnchanged(.approvals, generation: dirtyGeneration)
  }

  private func refreshRunReviewPage(
    _ page: RunsAndReviewPage,
    updatesStatus: Bool
  ) async {
    if let runReviewPageRefreshOperationForTesting,
       let context = captureRunReviewPageRefresh(page) {
      await runReviewPageRefreshOperationForTesting(page)
      guard isCurrentRunReviewPageRefresh(context) else { return }
      markRunReviewPageRefreshTerminal(context)
      return
    }

    switch page {
    case .runs:
      await refreshAgentRuns(updatesStatus: updatesStatus)
    case .review:
      await refreshApprovals(updatesStatus: updatesStatus)
    case .goals:
      await refreshAgentGoals(updatesStatus: updatesStatus)
    case .agents:
      await refreshAgentProfiles(updatesStatus: updatesStatus)
    case .workflows:
      await refreshAgentWorkflows(updatesStatus: updatesStatus)
    }
  }

  func replaceAgentRunsForTesting(
    _ runs: [AgentRunItem],
    buildsProjectionSynchronously: Bool = true
  ) {
    agentRuns = runs
    if buildsProjectionSynchronously, runs.count > 256 {
      agentRunProjectionTask?.cancel()
      agentRunProjectionGeneration &+= 1
      publishAgentRunProjection(Self.agentRunProjection(
        runs: runs,
        filterTerms: agentRunFilterTerms
      )!)
      agentRunProjectionTask = nil
    }
    markRunReviewPageLoaded(.runs)
  }

  func replaceExternalThreadsForTesting(_ threads: [ExternalThreadSummary]) {
    externalThreads = threads
  }

  func replaceApprovalItemsForTesting(_ items: [ApprovalItem]) {
    approvalItems = items
    markRunReviewPageLoaded(.review)
  }

  func removeFinishedRunApprovalsFromQueue(_ runID: String) {
    let removedQueueItemIDs = Set(
      approvalItems.lazy
        .filter { $0.runId == runID }
        .map(\.id)
    )
    let removedSelection = selectedApprovalItemID.flatMap { selectedID in
      removedQueueItemIDs.contains(selectedID)
        ? (selectedID, visibleApprovalItems.firstIndex(where: { $0.id == selectedID }))
        : nil
    }
    if !removedQueueItemIDs.isEmpty {
      noteApprovalDecisionLanded()
      approvalItems.removeAll { removedQueueItemIDs.contains($0.id) }
    }
    if let (selectedID, visibleIndex) = removedSelection {
      preserveApprovalSelectionAfterMutation(
        mutatedID: selectedID,
        originalVisibleIndex: visibleIndex
      )
    }
  }

  public func setRunReviewAutoRefreshActive(
    _ isActive: Bool,
    intervalNanoseconds: UInt64 = WorkspaceStore.runReviewAutoRefreshIntervalNanoseconds,
    refreshImmediately: Bool = true
  ) {
    isRunReviewAutoRefreshActive = isActive
    guard isActive else {
      runReviewAutoRefreshTask?.cancel()
      runReviewAutoRefreshTask = nil
      return
    }

    if refreshImmediately {
      markWorkspaceSurfacesDirty(
        [.approvals],
        refreshVisible: selectedSurface == .approvals
      )
    }

    guard runReviewAutoRefreshTask == nil else { return }
    runReviewAutoRefreshTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: intervalNanoseconds)
        } catch {
          return
        }
        guard let self else { return }
        guard self.isRunReviewAutoRefreshActive else { continue }
        self.markWorkspaceSurfacesDirty(
          [.approvals],
          refreshVisible: self.selectedSurface == .approvals
        )
      }
    }
  }

  public func refreshAgentRuns(updatesStatus: Bool = false, prefetched: WorkspaceAgentStateSection<AgentRunListPayload>? = nil) async {
    guard !isRefreshingAgentRuns else {
      // The in-flight list may predate a decision; scan again when it ends.
      if prefetched == nil { agentRunsRefreshRequestedAfterCurrent = true }
      return
    }
    guard let corpusRoot else {
      if updatesStatus { statusText = "No corpus selected" }
      return
    }
    guard let refreshContext = captureRunReviewPageRefresh(.runs) else { return }

    isRefreshingAgentRuns = true
    let showsLoading = updatesStatus
      || (agentRuns.isEmpty && !runReviewPageLoadState(for: .runs).isLoaded)
    if showsLoading {
      isLoadingAgentRuns = true
    }
    if updatesStatus { statusText = "Loading agent runs..." }
    defer {
      if isCurrentRunReviewPageRefresh(refreshContext) {
        isRefreshingAgentRuns = false
        if showsLoading {
          isLoadingAgentRuns = false
        }
        markRunReviewPageRefreshTerminal(refreshContext)
        if agentRunsRefreshRequestedAfterCurrent {
          agentRunsRefreshRequestedAfterCurrent = false
          Task { @MainActor [weak self] in
            await self?.refreshAgentRuns()
          }
        }
      }
    }

    do {
      let nextRunsFromList: [AgentRunItem]
      if let agentRunListLoaderForTesting {
        nextRunsFromList = try await agentRunListLoaderForTesting()
      } else {
        let payload: AgentRunListPayload
        if let prefetched {
          payload = try prefetched.get()
        } else {
          payload = try await cli.runJSON([
            "run", "list", "--dir", corpusRoot.path, "--json"
          ])
        }
        nextRunsFromList = payload.runs
      }
      guard !Task.isCancelled,
            isCurrentRunReviewPageRefresh(refreshContext)
      else { return }
      let nextRuns = mergingNewerLocalRuns(into: nextRunsFromList)
      let currentRuns = agentRuns
      let runsChanged = await Task.detached(priority: .utility) {
        currentRuns != nextRuns
      }.value
      guard !Task.isCancelled,
            isCurrentRunReviewPageRefresh(refreshContext)
      else { return }
      if runsChanged {
        agentRuns = nextRuns
      }
      if let selectedAgentRunID,
         !nextRuns.contains(where: { $0.id == selectedAgentRunID }) {
        self.selectedAgentRunID = nil
      }
      if let presentedAgentRunID,
         !nextRuns.contains(where: { $0.id == presentedAgentRunID }) {
        self.presentedAgentRunID = nil
      }
      if self.selectedAgentRunID == nil {
        self.selectedAgentRunID = nextRuns.first?.id
      }
      if updatesStatus {
        statusText = "\(nextRuns.count) agent run\(nextRuns.count == 1 ? "" : "s")"
      }
    } catch {
      guard !Task.isCancelled, isCurrentRunReviewPageRefresh(refreshContext) else { return }
      errorText = error.localizedDescription
      if updatesStatus { statusText = "Agent runs failed" }
    }
  }

  public func refreshAgentWorkflows(updatesStatus: Bool = false, prefetched: WorkspaceAgentStateSection<AgentWorkflowListPayload>? = nil) async {
    guard !isRefreshingAgentWorkflows else { return }
    guard let corpusRoot else {
      agentWorkflows = []
      selectedAgentWorkflowID = nil
      if updatesStatus { statusText = "No corpus selected" }
      return
    }
    guard let refreshContext = captureRunReviewPageRefresh(.workflows) else { return }
    isRefreshingAgentWorkflows = true
    // Background refreshes of a loaded empty list must not flash the loading
    // placeholder; only the first load or an explicit refresh shows it.
    let showsLoading = updatesStatus
      || (agentWorkflows.isEmpty && !runReviewPageLoadState(for: .workflows).isLoaded)
    if showsLoading { isLoadingAgentWorkflows = true }
    if updatesStatus { statusText = "Loading workflows..." }
    defer {
      if isCurrentRunReviewPageRefresh(refreshContext) {
        isRefreshingAgentWorkflows = false
        if showsLoading { isLoadingAgentWorkflows = false }
        markRunReviewPageRefreshTerminal(refreshContext)
      }
    }
    do {
      let payload: AgentWorkflowListPayload
      if let prefetched {
        payload = try prefetched.get()
      } else {
        payload = try await cli.runJSON([
          "workflow", "list", "--dir", corpusRoot.path, "--json"
        ])
      }
      guard !Task.isCancelled,
            isCurrentRunReviewPageRefresh(refreshContext)
      else { return }
      let currentWorkflows = agentWorkflows
      let nextWorkflows = payload.workflows
      let workflowsChanged = await Task.detached(priority: .utility) {
        currentWorkflows != nextWorkflows
      }.value
      guard !Task.isCancelled,
            isCurrentRunReviewPageRefresh(refreshContext)
      else { return }
      if workflowsChanged {
        agentWorkflows = nextWorkflows
      }
      if let selectedAgentWorkflowID,
         !nextWorkflows.contains(where: { $0.id == selectedAgentWorkflowID }) {
        self.selectedAgentWorkflowID = nil
      }
      if self.selectedAgentWorkflowID == nil { self.selectedAgentWorkflowID = nextWorkflows.first?.id }
      if updatesStatus {
        statusText = "\(nextWorkflows.count) workflow\(nextWorkflows.count == 1 ? "" : "s")"
      }
    } catch {
      guard !Task.isCancelled, isCurrentRunReviewPageRefresh(refreshContext) else { return }
      errorText = error.localizedDescription
      if updatesStatus { statusText = "Workflows failed" }
    }
  }

  func applyProjectList(_ payload: WorkspaceProjectList) {
    projectNotes = payload.projects
    projectStatus = payload.diagnostics.isEmpty ? "" : "\(payload.diagnostics.count) project note(s) need attention: \(payload.diagnostics[0].message)"
  }

  func refreshProjects() async {
    guard let root = corpusRoot else { projectNotes = []; return }
    let requestID = UUID()
    projectRefreshID = requestID
    isRefreshingProjects = true
    if projectStatus.hasPrefix("Could not load projects:") {
      projectStatus = ""
    }
    defer {
      if corpusRoot == root, projectRefreshID == requestID {
        isRefreshingProjects = false
      }
    }
    var lastError: Error?
    for attempt in 0..<2 {
      do {
        let payload: WorkspaceProjectList
        if let projectListLoaderForTesting {
          payload = try await projectListLoaderForTesting(root)
        } else {
          payload = try await cli.runJSON(["project", "list", "--dir", root.path, "--json"])
        }
        guard corpusRoot == root, projectRefreshID == requestID, !Task.isCancelled else { return }
        applyProjectList(payload)
        return
      } catch is CancellationError {
        return
      } catch {
        guard corpusRoot == root, projectRefreshID == requestID, !Task.isCancelled else { return }
        lastError = error
        if attempt == 0 {
          do {
            try await Task.sleep(for: .milliseconds(150))
          } catch {
            return
          }
          guard corpusRoot == root, projectRefreshID == requestID, !Task.isCancelled else { return }
        }
      }
    }
    guard let lastError,
          corpusRoot == root,
          projectRefreshID == requestID,
          !Task.isCancelled
    else { return }
    projectStatus = "Could not load projects: \(lastError.localizedDescription)"
  }

  private func finishProjectRefreshTask(id: UUID) {
    guard projectRefreshTask?.id == id else { return }
    projectRefreshTask = nil
  }

  func refreshProjectsIfIdle() async {
    if let active = projectRefreshTask {
      await active.task.value
      return
    }
    guard !isRefreshingProjects else { return }
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.refreshProjects()
    }
    projectRefreshTask = (id, task)
    await task.value
    finishProjectRefreshTask(id: id)
  }

  func openProjectNote(_ project: WorkspaceProjectNote) {
    let location = AIChatThreadRecord(title: project.title, file: project.file, line: 1,
      zone: "project", modifiedAt: nil, idValue: project.id)
    activateDetailLocation(.aiChatThreadRecord(location), mode: .page, surface: nil, recordsHistory: true)
  }

  func createProject(title: String, color: String, details: String = "", refinesWithAI: Bool = false) async -> Bool {
    guard let root = corpusRoot else { return false }
    do {
      let args = ["project", "create", "--title", title, "--color", color, "--description=\(details)", "--dir", root.path, "--json"]
      let preview: WorkspaceProjectEdit = try await cli.runJSON(args)
      guard corpusRoot == root, !Task.isCancelled else { return false }
      let result: WorkspaceProjectEdit = try await cli.runJSON(args + ["--file", preview.project.relativePath, "--id", preview.project.id, "--apply"])
      guard corpusRoot == root else { return true }
      await refreshProjects()
      guard corpusRoot == root else { return true }
      openProjectNote(result.project)
      if refinesWithAI && !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let threadID = createAIChatThread(destinationID: selectedAIChatDestination.id)
        await updateProject(result.project, threadID: threadID)
        guard corpusRoot == root else { return true }
        guard projectNotes.contains(where: { $0.id == result.project.id && $0.contains(threadID) }) else {
          projectStatus = "Project created with your details, but the brief chat could not be linked."
          return true
        }
        makeSurfacePrimary(.aiChat)
        let prompt = """
        Help me initialize this project's note: \(result.project.relativePath).
        Read its current contents and turn the supplied description into a concise project brief.
        Preserve the project metadata, stable ID, and chat membership. Use only the information I supplied;
        do not invent goals, decisions, sources, or tasks. Add structure only where the details justify it,
        and omit empty sections and placeholder TODOs. Apply the note edit using the workspace's reviewed edit tools.
        """
        if !sendAIChatRemoteMessage(
          prompt,
          threadID: threadID,
          origin: AIChatMessageProvenance(originClient: .automation)
        ) {
          projectStatus = "Project created with your details. AI refinement could not start; you can retry in its chat."
        }
      }
      return true
    } catch { if corpusRoot == root { projectStatus = error.localizedDescription }; return false }
  }

  @discardableResult
  func updateProject(
    _ project: WorkspaceProjectNote,
    threadID: UUID? = nil,
    color: String? = nil
  ) async -> Bool {
    guard let root = corpusRoot else {
      projectStatus = "Select a corpus before changing a project."
      return false
    }
    guard !projectMutationIDs.contains(project.id) else {
      projectStatus = "That project is already being updated."
      return false
    }
    if selectedEntrySource?.file == project.file,
       liveFileEditorHasUnsavedChanges || entryEditorHasUnsavedChanges || activeEditingBlock != nil {
      projectStatus = "Save the project note before changing its chat links or color."
      return false
    }
    projectMutationIDs.insert(project.id)
    defer { projectMutationIDs.remove(project.id) }
    // Fix the intended membership from the state the caller acted on, so a
    // retry against a newer revision cannot invert a toggle.
    let addsThread = threadID.map { !project.contains($0) }
    var current = project
    for attempt in 0..<2 {
      do {
        var args = ["project", "update", current.id, "--dir", root.path, "--json", "--if-revision", current.revision]
        if let threadID, let addsThread {
          args += ["--thread", threadID.uuidString.lowercased()]
          if !addsThread { args += ["--remove"] }
        }
        if let color { args += ["--color", color] }
        let _: WorkspaceProjectEdit = try await cli.runJSON(args)
        guard corpusRoot == root, !Task.isCancelled else { return false }
        let _: WorkspaceProjectEdit = try await cli.runJSON(args + ["--apply"])
        guard corpusRoot == root else { return false }
        await refreshProjects()
        return corpusRoot == root && !Task.isCancelled
      } catch {
        guard corpusRoot == root else { return false }
        guard attempt == 0, !Task.isCancelled, Self.isStaleProjectRevisionError(error) else {
          projectStatus = error.localizedDescription
          return false
        }
        // The note changed on disk after the cached project list was read:
        // another device, a sync, or a manual edit. A headless OpenOrg server
        // has no project sidebar to refresh that list, so its cached revision
        // can stay stale indefinitely. Membership and color edits are
        // idempotent set operations, so reapply them to the current revision.
        await refreshProjects()
        guard corpusRoot == root, !Task.isCancelled else { return false }
        guard let fresh = projectNotes.first(where: { $0.id == project.id }) else {
          projectStatus = "That project is no longer available."
          return false
        }
        current = fresh
      }
    }
    return false
  }

  nonisolated static func isStaleProjectRevisionError(_ error: Error) -> Bool {
    let text = "\(error.localizedDescription) \(String(describing: error))"
    return text.contains("changed after it was read")
  }

  /// Resolves a project by ID, reloading the list once when the cached copy
  /// predates the project (for example, a note created on another device
  /// while a headless host was running).
  func currentProject(id: String) async -> WorkspaceProjectNote? {
    if let project = projectNotes.first(where: { $0.id == id }) { return project }
    await refreshProjects()
    return projectNotes.first(where: { $0.id == id })
  }

  func setProjectMembership(
    _ isMember: Bool,
    projectID: String,
    threadID: UUID
  ) async -> Bool {
    guard aiChatThreads.contains(where: { $0.id == threadID }),
          let project = await currentProject(id: projectID)
    else {
      projectStatus = "That project or chat is no longer available."
      return false
    }
    guard project.contains(threadID) != isMember else { return true }
    return await updateProject(project, threadID: threadID)
  }

  func createChatInProject(_ project: WorkspaceProjectNote) async {
    let root = corpusRoot
    let id = createAIChatThread(destinationID: selectedAIChatDestination.id)
    await updateProject(project, threadID: id)
    guard corpusRoot == root else { return }
    makeSurfacePrimary(.aiChat)
  }

  public func refreshAgentGoals(updatesStatus: Bool = false, prefetched: WorkspaceAgentStateSection<AgentGoalListPayload>? = nil) async {
    guard !isRefreshingAgentGoals else { return }
    guard let corpusRoot else {
      agentGoals = []
      selectedAgentGoalID = nil
      if updatesStatus { statusText = "No corpus selected" }
      return
    }
    guard let refreshContext = captureRunReviewPageRefresh(.goals) else { return }
    isRefreshingAgentGoals = true
    let showsLoading = updatesStatus
      || (agentGoals.isEmpty && !runReviewPageLoadState(for: .goals).isLoaded)
    if showsLoading { isLoadingAgentGoals = true }
    if updatesStatus { statusText = "Loading goals..." }
    defer {
      if isCurrentRunReviewPageRefresh(refreshContext) {
        isRefreshingAgentGoals = false
        if showsLoading { isLoadingAgentGoals = false }
        markRunReviewPageRefreshTerminal(refreshContext)
      }
    }
    do {
      let payload: AgentGoalListPayload
      if let prefetched {
        payload = try prefetched.get()
      } else {
        payload = try await cli.runJSON([
          "goal", "list", "--dir", corpusRoot.path, "--json"
        ])
      }
      guard !Task.isCancelled,
            isCurrentRunReviewPageRefresh(refreshContext)
      else { return }
      agentGoals = payload.goals
      if let selectedAgentGoalID,
         !payload.goals.contains(where: { $0.id == selectedAgentGoalID }) {
        self.selectedAgentGoalID = nil
      }
      if self.selectedAgentGoalID == nil { self.selectedAgentGoalID = payload.goals.first?.id }
      if updatesStatus {
        statusText = "\(payload.goals.count) goal\(payload.goals.count == 1 ? "" : "s")"
      }
    } catch {
      guard !Task.isCancelled, isCurrentRunReviewPageRefresh(refreshContext) else { return }
      errorText = error.localizedDescription
      if updatesStatus { statusText = "Goals failed" }
    }
  }

  public func refreshAgentProfiles(updatesStatus: Bool = false, prefetched: WorkspaceAgentStateSection<AgentProfileListPayload>? = nil) async {
    guard !isRefreshingAgentProfiles else { return }
    guard let corpusRoot else {
      agentProfiles = []
      selectedAgentProfileID = nil
      if updatesStatus { statusText = "No corpus selected" }
      return
    }
    guard let refreshContext = captureRunReviewPageRefresh(.agents) else { return }
    isRefreshingAgentProfiles = true
    let showsLoading = updatesStatus
      || (agentProfiles.isEmpty && !runReviewPageLoadState(for: .agents).isLoaded)
    if showsLoading { isLoadingAgentProfiles = true }
    if updatesStatus { statusText = "Loading agents..." }
    defer {
      if isCurrentRunReviewPageRefresh(refreshContext) {
        isRefreshingAgentProfiles = false
        if showsLoading { isLoadingAgentProfiles = false }
        markRunReviewPageRefreshTerminal(refreshContext)
      }
    }
    do {
      let payload: AgentProfileListPayload
      if let prefetched {
        payload = try prefetched.get()
      } else {
        payload = try await cli.runJSON([
          "agent-profile", "list", "--dir", corpusRoot.path, "--json"
        ])
      }
      guard !Task.isCancelled,
            isCurrentRunReviewPageRefresh(refreshContext)
      else { return }
      agentProfiles = payload.profiles
      if let selectedAgentProfileID,
         !payload.profiles.contains(where: { $0.id == selectedAgentProfileID }) {
        self.selectedAgentProfileID = nil
      }
      if self.selectedAgentProfileID == nil { self.selectedAgentProfileID = payload.profiles.first?.id }
      if updatesStatus {
        statusText = "\(payload.profiles.count) agent\(payload.profiles.count == 1 ? "" : "s")"
      }
    } catch {
      guard !Task.isCancelled, isCurrentRunReviewPageRefresh(refreshContext) else { return }
      errorText = error.localizedDescription
      if updatesStatus { statusText = "Agents failed" }
    }
  }

  public func selectAgentGoal(_ goal: AgentGoalItem) {
    selectedAgentGoalID = goal.id
    selectCoordinationRecord(file: goal.file)
  }

  public func selectAgentProfile(_ profile: AgentProfileItem) {
    selectedAgentProfileID = profile.id
    selectCoordinationRecord(file: profile.file)
  }

  public func showAgentGoal(_ id: String) {
    guard let goal = agentGoals.first(where: { $0.id == id }) else { return }
    runsAndReviewPage = .goals
    selectAgentGoal(goal)
  }

  public func showAgentProfile(_ id: String) {
    guard let profile = agentProfiles.first(where: { $0.id == id }) else { return }
    runsAndReviewPage = .agents
    selectAgentProfile(profile)
  }

  public func showAgentRuns(goalRef: String? = nil, agentRef: String? = nil) {
    runsAndReviewPage = .runs
    agentRunFilter = goalRef ?? agentRef ?? ""
    if let run = agentRuns.first(where: { candidate in
      (goalRef == nil || candidate.goalRef == goalRef)
        && (agentRef == nil || candidate.agentRef == agentRef)
    }) {
      selectAgentRun(run)
    }
  }

  public func setAgentGoalStatus(_ goal: AgentGoalItem, status: String) async {
    guard let corpusRoot,
          ["planned", "active", "achieved", "canceled"].contains(status),
          !mutatingAgentGoalIDs.contains(goal.id) else { return }
    mutatingAgentGoalIDs.insert(goal.id)
    defer { mutatingAgentGoalIDs.remove(goal.id) }
    do {
      _ = try await cli.run([
        "goal", "update", goal.id,
        "--status", status,
        "--apply",
        "--dir", corpusRoot.path,
        "--json"
      ])
      await refreshAgentGoals()
      if let refreshed = agentGoals.first(where: { $0.id == goal.id }) {
        selectAgentGoal(refreshed)
      }
      statusText = "\(goal.title): \(status)"
    } catch {
      errorText = error.localizedDescription
      statusText = "Goal update failed"
    }
  }

  public func setAgentProfileStatus(_ profile: AgentProfileItem, status: String) async {
    guard let corpusRoot,
          ["active", "paused", "retired"].contains(status),
          !mutatingAgentProfileIDs.contains(profile.id) else { return }
    mutatingAgentProfileIDs.insert(profile.id)
    defer { mutatingAgentProfileIDs.remove(profile.id) }
    do {
      _ = try await cli.run([
        "agent-profile", "update", profile.id,
        "--status", status,
        "--apply",
        "--dir", corpusRoot.path,
        "--json"
      ])
      await refreshAgentProfiles()
      if let refreshed = agentProfiles.first(where: { $0.id == profile.id }) {
        selectAgentProfile(refreshed)
      }
      statusText = "\(profile.name): \(status)"
    } catch {
      errorText = error.localizedDescription
      statusText = "Agent update failed"
    }
  }

  public func setAgentProfileDefaultRuntime(
    _ profile: AgentProfileItem,
    runtime: AIChatRuntime?
  ) async {
    guard let corpusRoot,
          !mutatingAgentProfileIDs.contains(profile.id) else { return }
    mutatingAgentProfileIDs.insert(profile.id)
    defer { mutatingAgentProfileIDs.remove(profile.id) }
    do {
      _ = try await cli.run([
        "agent-profile", "update", profile.id,
        "--default-runtime", runtime?.agentProfileValue ?? "none",
        "--apply",
        "--dir", corpusRoot.path,
        "--json"
      ])
      await refreshAgentProfiles()
      if let refreshed = agentProfiles.first(where: { $0.id == profile.id }) {
        selectAgentProfile(refreshed)
      }
      statusText = "\(profile.name): \(runtime.map { "defaults to \($0.title)" } ?? "no default runtime")"
    } catch {
      errorText = error.localizedDescription
      statusText = "Agent update failed"
    }
  }

  private func selectCoordinationRecord(file path: String) {
    let url = URL(fileURLWithPath: path)
    let file = CorpusFile(
      path: url.path,
      relativePath: relativePath(url.path),
      modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
      byteCount: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    )
    selectCorpusFile(file, surface: .approvals)
  }

  public func selectAgentWorkflow(_ workflow: AgentWorkflowItem) {
    selectedAgentWorkflowID = workflow.id
    let url = URL(fileURLWithPath: workflow.file)
    let file = CorpusFile(
      path: url.path,
      relativePath: relativePath(url.path),
      modifiedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
      byteCount: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    )
    selectCorpusFile(file, surface: .approvals)
  }

  public func setAgentWorkflowState(_ workflow: AgentWorkflowItem, state: String) async {
    guard let corpusRoot, ["active", "paused", "draft"].contains(state),
          !mutatingAgentWorkflowIDs.contains(workflow.id) else { return }
    mutatingAgentWorkflowIDs.insert(workflow.id)
    defer { mutatingAgentWorkflowIDs.remove(workflow.id) }
    do {
      let action = state == "active" ? "activate" : state == "paused" ? "pause" : "draft"
      _ = try await cli.run(["workflow", action, workflow.id, "--dir", corpusRoot.path, "--json"])
      await refreshAgentWorkflows()
      statusText = "\(workflow.title): \(state)"
      if let refreshed = agentWorkflows.first(where: { $0.id == workflow.id }) { selectAgentWorkflow(refreshed) }
    } catch {
      errorText = error.localizedDescription
      statusText = "Workflow update failed"
    }
  }

  public func validateAgentWorkflow(_ workflow: AgentWorkflowItem) async {
    guard let corpusRoot else { return }
    do {
      _ = try await cli.run(["workflow", "validate", workflow.id, "--dir", corpusRoot.path, "--json"])
      statusText = "\(workflow.title) is valid"
    } catch {
      errorText = error.localizedDescription
      statusText = "Workflow validation failed"
    }
  }

  public func setAgentWorkflowSchedule(
    _ workflow: AgentWorkflowItem,
    cron: String,
    timezone: String,
    destinationID: String?,
    model: String?,
    reasoningEffort: String?,
    enabled: Bool,
    skipWhileRunning: Bool? = nil
  ) async -> Bool {
    guard let corpusRoot else {
      errorText = "Choose a corpus before scheduling an automation."
      return false
    }
    guard !mutatingAgentWorkflowIDs.contains(workflow.id) else {
      errorText = "This automation is already being updated."
      return false
    }
    errorText = nil
    mutatingAgentWorkflowIDs.insert(workflow.id)
    defer { mutatingAgentWorkflowIDs.remove(workflow.id) }
    do {
      var arguments = ["workflow", "schedule", workflow.id, "--dir", corpusRoot.path, "--json"]
      if enabled {
        arguments += ["--cron", cron.trimmingCharacters(in: .whitespacesAndNewlines)]
        let timezone = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !timezone.isEmpty { arguments += ["--timezone", timezone] }
        if let skipWhileRunning {
          arguments += ["--when-running", skipWhileRunning ? "wait" : "continue"]
        }
      } else {
        arguments.append("--disable")
      }
      if let destinationID = destinationID?.trimmingCharacters(in: .whitespacesAndNewlines),
         !destinationID.isEmpty {
        arguments += ["--destination-ref", destinationID]
      }
      let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if model.isEmpty {
        if workflow.model != nil { arguments.append("--clear-model") }
      } else {
        arguments += ["--model", model]
      }
      let reasoningEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if reasoningEffort.isEmpty {
        if workflow.reasoningEffort != nil { arguments.append("--clear-reasoning-effort") }
      } else {
        arguments += ["--reasoning-effort", reasoningEffort]
      }
      _ = try await cli.run(arguments)
      if enabled && workflow.state != "active" {
        _ = try await cli.run(["workflow", "activate", workflow.id, "--dir", corpusRoot.path, "--json"])
      }
      await refreshAgentWorkflows()
      statusText = enabled ? "Scheduled \(workflow.title)" : "Disabled \(workflow.title) schedule"
      if let refreshed = agentWorkflows.first(where: { $0.id == workflow.id }) { selectAgentWorkflow(refreshed) }
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = "Workflow schedule failed"
      return false
    }
  }

  public func deleteAgentWorkflow(_ workflow: AgentWorkflowItem) async -> Bool {
    guard let corpusRoot else {
      errorText = "Choose a corpus before deleting an automation."
      return false
    }
    guard !mutatingAgentWorkflowIDs.contains(workflow.id) else {
      errorText = "This automation is already being updated."
      return false
    }
    errorText = nil
    mutatingAgentWorkflowIDs.insert(workflow.id)
    defer { mutatingAgentWorkflowIDs.remove(workflow.id) }
    do {
      _ = try await cli.run([
        "workflow", "delete", workflow.id,
        "--dir", corpusRoot.path,
        "--apply",
        "--json",
      ])
      if selectedAgentWorkflowID == workflow.id {
        selectedAgentWorkflowID = nil
      }
      await refreshAgentWorkflows()
      statusText = "Deleted \(workflow.title)"
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = "Automation deletion failed"
      return false
    }
  }

  public func runAgentWorkflow(_ workflow: AgentWorkflowItem, inputs: [String: String]) async {
    _ = await prepareAndDispatchAgentAutomation(
      workflowID: workflow.id,
      title: workflow.title,
      destinationRef: workflow.destinationRef,
      inputs: inputs,
      presentsThread: true
    )
  }

  public func createAgentAutomation(
    title: String,
    prompt: String,
    destinationID: String,
    model: String?,
    reasoningEffort: String?,
    agentRef: String?,
    schedule: String?,
    timezone: String
  ) async -> Bool {
    guard let corpusRoot else {
      errorText = "Choose a corpus before creating an automation."
      return false
    }
    errorText = nil
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSchedule = schedule?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTitle.isEmpty, !normalizedPrompt.isEmpty else {
      errorText = "Enter an automation name and prompt."
      return false
    }
    let id = Self.automationIdentifier(
      title: normalizedTitle,
      existingIDs: Set(agentWorkflows.map(\.id))
    )
    do {
      var arguments = [
        "workflow", "create", id,
        "--title", normalizedTitle,
        "--prompt", normalizedPrompt,
        "--destination-ref", destinationID,
        "--dir", corpusRoot.path,
        "--json"
      ]
      if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
         !model.isEmpty {
        arguments += ["--model", model]
      }
      if let reasoningEffort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
         !reasoningEffort.isEmpty {
        arguments += ["--reasoning-effort", reasoningEffort]
      }
      if let agentRef = agentRef?.trimmingCharacters(in: .whitespacesAndNewlines),
         !agentRef.isEmpty {
        arguments += ["--agent-ref", agentRef]
      }
      if let schedule = normalizedSchedule,
         !schedule.isEmpty {
        arguments += ["--schedule", schedule]
        let timezone = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !timezone.isEmpty { arguments += ["--timezone", timezone] }
      } else {
        arguments += ["--state", "draft"]
      }
      _ = try await cli.run(arguments)
      await refreshAgentWorkflows()
      if let created = agentWorkflows.first(where: { $0.id == id }) {
        selectAgentWorkflow(created)
      }
      statusText = normalizedSchedule?.isEmpty == false
        ? "Created and scheduled \(normalizedTitle)"
        : "Created \(normalizedTitle)"
      await checkDueAgentAutomations()
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = "Automation creation failed"
      return false
    }
  }

  nonisolated static func automationIdentifier(title: String, existingIDs: Set<String>) -> String {
    let scalars = title.lowercased().unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    var base = String(scalars)
      .split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-")
    if base.isEmpty { base = "automation" }
    base = String(base.prefix(56))
    if !existingIDs.contains(base) { return base }
    var suffix = 2
    while existingIDs.contains("\(base)-\(suffix)") { suffix += 1 }
    return "\(base)-\(suffix)"
  }

  public func showAgentWorkflowHistory(_ workflow: AgentWorkflowItem) {
    runsAndReviewPage = .runs
    agentRunFilter = workflow.id
    if let run = agentRuns.first(where: { $0.workflowId == workflow.id }) {
      selectAgentRun(run)
    }
  }

  public func agentRunCount(workflowID: String) -> Int {
    agentRuns.lazy.filter { $0.workflowId == workflowID }.count
  }

  func dispatchScheduledAgentAutomation(_ item: AgentWorkflowDueItem) async -> Bool {
    await prepareAndDispatchAgentAutomation(
      workflowID: item.workflowId,
      title: item.title,
      destinationRef: item.destinationRef,
      inputs: [:],
      triggerID: item.triggerId,
      scheduledFor: item.scheduledFor,
      presentsThread: false
    ) != nil
  }

  func prepareAndDispatchAgentAutomation(
    workflowID: String,
    title: String,
    destinationRef: String?,
    inputs: [String: String],
    triggerID: String? = nil,
    scheduledFor: String? = nil,
    presentsThread: Bool
  ) async -> UUID? {
    guard let corpusRoot, !dispatchingAutomationIDs.contains(workflowID) else { return nil }
    dispatchingAutomationIDs.insert(workflowID)
    mutatingAgentWorkflowIDs.insert(workflowID)
    defer {
      dispatchingAutomationIDs.remove(workflowID)
      mutatingAgentWorkflowIDs.remove(workflowID)
    }
    var preparedRunID: String?
    do {
      var arguments = ["workflow", "run", workflowID, "--dir", corpusRoot.path, "--json"]
      for (name, value) in inputs.sorted(by: { $0.key < $1.key }) {
        arguments += ["--input", "\(name)=\(value)"]
      }
      if let triggerID {
        arguments += ["--trigger", triggerID, "--host-ref", automationHostRef]
      }
      if let scheduledFor {
        arguments += ["--scheduled-for", scheduledFor]
      }
      let prepared: AgentWorkflowRunPayload = try await cli.runJSON(arguments)
      guard let run = prepared.run, let prompt = prepared.prompt else {
        automationSchedulerStatusText = prepared.reason ?? "Automation attempt was skipped"
        return nil
      }
      preparedRunID = run.id
      guard let destination = resolvedAutomationDestination(destinationRef ?? run.destinationRef) else {
        let requestedDestination = destinationRef ?? run.destinationRef ?? "default"
        await failAgentAutomationRun(
          run.id,
          reason: "AI destination \"\(requestedDestination)\" is unavailable or disabled on automation host \"\(automationHostRef)\". Choose a destination available on this host or enable it in the host configuration."
        )
        return nil
      }
      if let reasoningEffort = prepared.reasoningEffort,
         !Self.automationDestinationSupportsReasoning(destination) {
        await failAgentAutomationRun(
          run.id,
          reason: "\(destination.title) cannot apply the configured reasoning effort \(reasoningEffort). Choose Codex or OpenClaw, or clear REASONING_EFFORT in the automation file."
        )
        return nil
      }

      _ = try await cli.run([
        "run", "start", run.id,
        "--actor", "Celorga Automation Scheduler",
        "--dir", corpusRoot.path,
        "--json"
      ])
      let thread = createAIChatThread(
        title: "Automation: \(title)",
        statusText: presentsThread ? "Starting \(title)" : "",
        runtime: destination.runtime,
        destinationID: destination.id,
        inheritsChatConfiguration: false,
        modelOverride: prepared.model,
        reasoningEffortOverride: prepared.reasoningEffort,
        defersPersistence: true,
        selectsThread: presentsThread
      )
      automationRunIDsByThreadID[thread.id] = run.id
      _ = try? await cli.run([
        "run", "comment", run.id,
        "--author", "Celorga Automation Scheduler",
        "--body", "AI destination: \(destination.id)\nAI chat thread: \(thread.id.uuidString.lowercased())",
        "--dir", corpusRoot.path,
        "--json"
      ])
      guard sendAIChatRemoteMessage(
        prompt,
        threadID: thread.id,
        origin: AIChatMessageProvenance(originClient: .automation)
      ) else {
        automationRunIDsByThreadID.removeValue(forKey: thread.id)
        await failAgentAutomationRun(run.id, reason: "Celorga could not enqueue the automation prompt for \(destination.title).")
        return nil
      }
      if presentsThread {
        navigateToSurface(.aiChat)
        selectAIChatThread(thread.id)
      }
      statusText = "Sent \(title) to \(destination.title)"
      await refreshAgentRuns()
      await refreshAgentWorkflows()
      return thread.id
    } catch {
      if let preparedRunID {
        await failAgentAutomationRun(
          preparedRunID,
          reason: "Celorga could not dispatch this automation: \(error.localizedDescription)"
        )
      }
      errorText = error.localizedDescription
      statusText = "Automation dispatch failed"
      return nil
    }
  }

  private func resolvedAutomationDestination(_ destinationRef: String?) -> AIChatDestinationConfiguration? {
    if let destinationRef = destinationRef?.trimmingCharacters(in: .whitespacesAndNewlines),
       !destinationRef.isEmpty {
      return enabledAIChatDestinations.first(where: { $0.id == destinationRef })
    }
    return enabledAIChatDestinations.first(where: { $0.id == AIChatDestinationConfiguration.openClawID })
      ?? enabledAIChatDestinations.first
  }

  nonisolated static func automationDestinationSupportsReasoning(
    _ destination: AIChatDestinationConfiguration
  ) -> Bool {
    switch destination.adapter {
    case .codexLocal, .codexRemote, .codexManagedRemote, .piLocal, .piRemote,
         .openCodeLocal, .openCodeRemote, .openClaw:
      true
    case .openAI:
      destination.providerPreset != nil
    case .claudeLocal, .anthropic, .openRouter, .ollama, .openAIDot:
      false
    }
  }

  private func failAgentAutomationRun(_ runID: String, reason: String) async {
    guard let corpusRoot else { return }
    automationSchedulerErrorText = reason
    _ = try? await cli.run([
      "run", "fail", runID,
      "--reason", reason,
      "--actor", "Celorga Automation Scheduler",
      "--dir", corpusRoot.path,
      "--json"
    ])
    await refreshAgentRuns()
  }

  func recordAgentAutomationReply(
    threadID: UUID,
    destination: AIChatDestinationConfiguration,
    reply: String
  ) async {
    guard let runID = automationRunIDsByThreadID.removeValue(forKey: threadID),
          let corpusRoot
    else { return }
    let normalizedReply = String(
      reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000)
    )
    _ = try? await cli.run([
      "run", "comment", runID,
      "--author", destination.title,
      "--body", "AI chat thread \(threadID.uuidString.lowercased()) replied:\n\(normalizedReply)",
      "--dir", corpusRoot.path,
      "--json"
    ])
    let currentRun: AgentRunItem? = try? await cli.runJSON([
      "run", "show", runID,
      "--dir", corpusRoot.path,
      "--json"
    ])
    // A successful transport reply is not proof that the delegated sweep ran.
    // Honor the executor's explicit terminal failure even if its host-local run
    // mutation has not yet synchronized back to this scheduler's corpus.
    if currentRun?.status == "running",
       AutomationRunReplyOutcome.parse(reply) == .failed {
      await failAgentAutomationRun(runID, reason: String(normalizedReply.prefix(4_000)))
      return
    }
    if currentRun?.status == "running" {
      let summary = String(normalizedReply.prefix(4_000))
      _ = try? await cli.run([
        "run", "complete", runID,
        "--summary", summary.isEmpty ? "The AI destination returned an empty response." : summary,
        "--actor", "Celorga Automation Scheduler",
        "--dir", corpusRoot.path,
        "--json"
      ])
    }
    await refreshAgentRuns()
  }

  func failAgentAutomationThread(threadID: UUID, reason: String) async {
    guard let runID = automationRunIDsByThreadID.removeValue(forKey: threadID) else { return }
    await failAgentAutomationRun(runID, reason: reason)
  }

  public func syncAgentWorkflowsWithOpenClaw() async throws {
    let gateway = OpenClawGatewayClient(settings: currentOpenClawSettings(allowKeychainRead: true))
    try await gateway.syncWorkflows(corpusID: activeCorpusIdentity?.id)
  }

  public func mutateAgentRun(_ run: AgentRunItem, action: String, reason: String? = nil) async {
    guard let corpusRoot, !mutatingAgentRunIDs.contains(run.id) else { return }
    mutatingAgentRunIDs.insert(run.id)
    defer { mutatingAgentRunIDs.remove(run.id) }
    do {
      var arguments = ["run", action, run.id, "--dir", corpusRoot.path, "--json", "--actor", "Org2Workspace"]
      if let reason, !reason.isEmpty { arguments.append(contentsOf: ["--reason", reason]) }
      let updated: AgentRunItem = try await cli.runJSON(arguments)
      if let index = agentRuns.firstIndex(where: { $0.id == updated.id }) {
        agentRuns[index] = updated
      } else {
        agentRuns.insert(updated, at: 0)
      }
      statusText = "\(updated.goal): \(updated.status)"
    } catch {
      errorText = error.localizedDescription
      statusText = "Run update failed"
    }
  }

  public func completeAgentRun(_ run: AgentRunItem, summary: String) async {
    guard let corpusRoot, run.status == "running", !mutatingAgentRunIDs.contains(run.id) else { return }
    let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedSummary.isEmpty else {
      errorText = "Describe what happened before completing this run."
      statusText = "Outcome summary required"
      return
    }
    mutatingAgentRunIDs.insert(run.id)
    defer { mutatingAgentRunIDs.remove(run.id) }
    do {
      let updated: AgentRunItem = try await cli.runJSON([
        "run", "complete", run.id,
        "--summary", normalizedSummary,
        "--actor", "Org2Workspace",
        "--dir", corpusRoot.path,
        "--json"
      ])
      if let index = agentRuns.firstIndex(where: { $0.id == updated.id }) {
        agentRuns[index] = updated
      }
      statusText = "Completed \(updated.goal)"
    } catch {
      errorText = error.localizedDescription
      statusText = "Run completion failed"
    }
  }

  public func completeAgentRunExternally(_ run: AgentRunItem, summary: String) async {
    guard corpusRoot != nil, run.canMarkDoneElsewhere, !mutatingAgentRunIDs.contains(run.id) else { return }
    let normalizedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    mutatingAgentRunIDs.insert(run.id)
    defer { mutatingAgentRunIDs.remove(run.id) }
    do {
      let updated = try await performAgentRunExternalCompletion(
        runID: run.id,
        summary: normalizedSummary
      )
      recordAgentRunExternalCompletion(updated)
      statusText = "Recorded external completion for \(updated.goal)"
    } catch {
      errorText = error.localizedDescription
      statusText = "External completion failed"
    }
  }

  private func performAgentRunExternalCompletion(
    runID: String,
    summary: String
  ) async throws -> AgentRunItem {
    guard let corpusRoot else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No corpus is selected."])
    }
    if let agentRunExternalCompletionForTesting {
      return try await agentRunExternalCompletionForTesting(runID, summary)
    }
    // The note is optional: the runtime records a default outcome when it is omitted.
    var arguments = ["run", "complete-external", runID]
    if !summary.isEmpty { arguments += ["--summary", summary] }
    arguments += ["--actor", "Org2Workspace", "--dir", corpusRoot.path, "--json"]
    return try await cli.runJSON(arguments)
  }

  private func recordAgentRunExternalCompletion(_ updated: AgentRunItem) {
    if let index = agentRuns.firstIndex(where: { $0.id == updated.id }) {
      agentRuns[index] = updated
    } else {
      agentRuns.insert(updated, at: 0)
    }
    removeFinishedRunApprovalsFromQueue(updated.id)
    scheduleApprovalsRefresh()
  }

  public func decideAgentRunApproval(
    _ run: AgentRunItem,
    approval: AgentRunApprovalItem,
    decision: String,
    note: String? = nil
  ) async {
    guard corpusRoot != nil else { return }
    let queueItemID = Self.runApprovalQueueItemID(runID: run.id, approvalID: approval.id)
    guard !isApprovalActionInProgress(queueItemID) else { return }
    let actionKind: ApprovalActionKind = decision == "approved" ? .approve : .reject
    beginApprovalAction(queueItemID, kind: actionKind)
    defer { endApprovalAction(queueItemID, kind: actionKind) }
    do {
      try await waitForAgentRunMutationAvailability(run.id)
      defer { mutatingAgentRunIDs.remove(run.id) }
      let updated = try await performAgentRunApprovalDecision(
        runID: run.id,
        approvalID: approval.id,
        fingerprint: approval.fingerprint,
        decision: decision,
        requestedRole: approval.requestedRole,
        requestedFrom: approval.requestedFrom,
        note: note
      )
      if let index = agentRuns.firstIndex(where: { $0.id == updated.id }) {
        agentRuns[index] = updated
      } else {
        agentRuns.insert(updated, at: 0)
      }
      noteApprovalDecisionLanded()
      approvalItems.removeAll { $0.id == queueItemID }
      if selectedApprovalItemID == queueItemID {
        selectedApprovalItemID = nil
        approvalSelectionAnchor = nil
      }
      scheduleApprovalsRefresh()
      statusText = "\(approval.title): \(decision) · \(updated.pendingApprovalCount) pending"
      if Self.approvalDecisionStartsAgentTurn(decision: decision, run: updated) {
        await continueOpenClawAfterApprovalBoundary(updated)
      }
    } catch {
      var errors = approvalActionErrorsByItemID
      errors[queueItemID] = error.localizedDescription
      approvalActionErrorsByItemID = errors
      errorText = error.localizedDescription
      statusText = "Approval update failed"
    }
  }

  public func requestAgentRunChanges(
    _ run: AgentRunItem,
    approval: AgentRunApprovalItem,
    feedback: String
  ) async {
    guard let feedback = Self.normalizedApprovalRevisionFeedback(feedback) else {
      errorText = "Describe what the agent should change."
      statusText = "Revision feedback required"
      return
    }
    await decideAgentRunApproval(run, approval: approval, decision: "revised", note: feedback)
  }

  public func openClawExecApprovalDetails(for run: AgentRunItem) async throws -> OpenClawExecApprovalDetails? {
    guard let approvalID = run.openClawExecApprovalID else { return nil }
    let gateway = OpenClawGatewayClient(settings: currentOpenClawSettings(allowKeychainRead: true))
    return try await gateway.execApprovalDetails(id: approvalID)
  }

  private func approvedRunContinuation(
    for run: AgentRunItem
  ) async throws -> OpenClawApprovedRunContinuation {
    if let agentRunApprovalContinuationForTesting {
      return try await agentRunApprovalContinuationForTesting(run)
    }
    let gateway = OpenClawGatewayClient(settings: currentOpenClawSettings(allowKeychainRead: true))
    do {
      return try await gateway.resumeApprovedRun(
        runID: run.id,
        corpusID: activeCorpusIdentity?.id,
        expectedUpdatedAt: run.updatedAt
      )
    } catch {
      guard Self.shouldUseLocalApprovalContinuationFallback(for: error) else { throw error }
      if run.workflowId != nil {
        let continuation = try await gateway.resumeWorkflowRun(
          runID: run.id,
          corpusID: activeCorpusIdentity?.id
        )
        return OpenClawApprovedRunContinuation(
          runID: continuation.runID,
          sessionKey: continuation.sessionKey,
          prompt: continuation.prompt,
          kind: "workflow"
        )
      }
      if run.isOpenClawExternalDraft {
        let continuation = try await gateway.resumeDraftRun(
          runID: run.id,
          corpusID: activeCorpusIdentity?.id
        )
        return OpenClawApprovedRunContinuation(
          runID: continuation.runID,
          sessionKey: continuation.sessionKey,
          prompt: continuation.prompt,
          kind: "external-draft"
        )
      }
      return OpenClawApprovedRunContinuation(
        runID: run.id,
        sessionKey: run.openClawSessionKey,
        prompt: Self.agentRunApprovalContinuationPrompt(run: run),
        kind: "run"
      )
    }
  }

  private func continueOpenClawAfterApproval(
    _ run: AgentRunItem,
    presentThread: Bool = false
  ) async throws -> Bool {
    let continuation = try await approvedRunContinuation(for: run)
    if continuation.alreadyResumed, continuation.continuationKey == nil { return false }
    let dedupeContext = captureAIChatCorpusContext()
    let transcriptMetadata = aiChatThreads
    let transcriptURL = aiChatTranscriptURL
    let persistedThreads = await Task.detached(priority: .utility) {
      AIChatTranscriptStore.shared.loadAllThreads(
        replacingMetadata: transcriptMetadata,
        legacyURL: transcriptURL
      )
    }.value
    guard isCurrentAIChatCorpusContext(dedupeContext) else { return false }
    if continuation.continuationKey != nil,
       (aiChatThreads + persistedThreads).contains(where: { thread in
         thread.messages.contains(where: { message in
           message.role == .user
             && AIChatContextPresentation(message.content).contexts.contains {
               $0.automaticPrompt == continuation.prompt
             }
         })
       }) {
      return false
    }
    let thread: AIChatThread
    if let sessionKey = continuation.sessionKey,
       let existing = aiChatThreads.first(where: { $0.sessionKey == sessionKey }) {
      if existing.isSettled { reopenAIChatThread(existing.id) }
      thread = aiChatThreads.first(where: { $0.id == existing.id }) ?? existing
    } else {
      let (titlePrefix, continuationStatus) = Self.approvalContinuationThreadLabels(
        kind: continuation.kind,
        hasSessionKey: continuation.sessionKey != nil,
        hasApprovedAction: !run.approvedCurrentApprovalBoundary.isEmpty
      )
      thread = createAIChatThread(
        title: "\(titlePrefix): \(run.goal)",
        statusText: continuationStatus,
        sessionKey: continuation.sessionKey ?? Self.approvedRunContinuationSessionKey(
          runID: run.id,
          agentID: openClawAgentID
        )
      )
    }
    if presentThread {
      navigateToSurface(.aiChat)
      selectAIChatThread(thread.id)
    }
    guard let pointer = aiChatContextPointer(for: run, requiresExistingRecord: false) else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [
        NSLocalizedDescriptionKey: "The approved run could not be attached to its continuation thread."
      ])
    }
    let actionText = automaticAIChatActionText(
      pointer,
      prompt: continuation.prompt
    )
    let context = captureAIChatCorpusContext()
    let outcome = await awaitAIChatEnqueueAndImmediateDrain(
      enqueueAIChatMessage(
        actionText,
        attachments: [],
        in: thread.id,
        context: context
      )
    )
    switch outcome {
    case .enqueued:
      return true
    case .superseded:
      return false
    case .rejected:
      throw AIChatEnqueueFailure.rejected
    }
  }

  public func continueApprovedAgentRun(_ run: AgentRunItem) async {
    guard run.canContinueApprovedWork, !mutatingAgentRunIDs.contains(run.id) else { return }
    mutatingAgentRunIDs.insert(run.id)
    defer { mutatingAgentRunIDs.remove(run.id) }
    do {
      let continued = try await continueOpenClawAfterApproval(run, presentThread: true)
      statusText = continued
        ? "Continuing approved work for \(run.goal)"
        : "\(run.goal) is already continuing"
    } catch {
      errorText = error.localizedDescription
      do {
        let blocked = try await recordAgentRunApprovalContinuationFailure(run)
        statusText = "Approved work could not be continued; \(blocked.goal) is blocked"
      } catch {
        statusText = "Approved work could not be continued or durably blocked"
      }
    }
  }

  /// Sends a run's recorded Request Changes note to an agent when the run is still
  /// blocked on that revision, for example after an earlier hand-off failed.
  public func continueRequestedRevision(_ run: AgentRunItem) async {
    guard run.revisionAwaitingHandoff != nil, !mutatingAgentRunIDs.contains(run.id) else { return }
    mutatingAgentRunIDs.insert(run.id)
    defer { mutatingAgentRunIDs.remove(run.id) }
    await continueOpenClawAfterApprovalBoundary(run)
  }

  private func recordAgentRunApprovalContinuationFailure(
    _ run: AgentRunItem,
    reason: String = WorkspaceStore.agentRunApprovalContinuationFailureReason
  ) async throws -> AgentRunItem {
    guard let corpusRoot else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No corpus is selected."])
    }
    let updated: AgentRunItem
    if let agentRunApprovalContinuationFailureForTesting {
      updated = try await agentRunApprovalContinuationFailureForTesting(run, reason)
    } else {
      updated = try await cli.runJSON([
        "run", "block", run.id,
        "--reason", reason,
        "--actor", "Org2Workspace",
        "--dir", corpusRoot.path,
        "--json"
      ])
    }
    if let index = agentRuns.firstIndex(where: { $0.id == updated.id }) {
      agentRuns[index] = updated
    } else {
      agentRuns.insert(updated, at: 0)
    }
    scheduleApprovalsRefresh()
    return updated
  }

  private func continueOpenClawWorkflowAfterRevision(
    _ run: AgentRunItem,
    approval: AgentRunApprovalItem
  ) async throws -> Bool {
    let gateway = OpenClawGatewayClient(settings: currentOpenClawSettings(allowKeychainRead: true))
    let continuation = try await gateway.resumeWorkflowRevision(
      runID: run.id,
      approvalID: approval.id,
      corpusID: activeCorpusIdentity?.id
    )
    let thread: AIChatThread
    if let existing = aiChatThreads.first(where: { $0.sessionKey == continuation.sessionKey }) {
      if existing.isSettled { reopenAIChatThread(existing.id) }
      thread = aiChatThreads.first(where: { $0.id == existing.id }) ?? existing
    } else {
      thread = createAIChatThread(
        title: "Workflow: \(run.goal)",
        statusText: "Continuing requested revision",
        sessionKey: continuation.sessionKey
      )
    }
    navigateToSurface(.aiChat)
    selectAIChatThread(thread.id)
    guard let pointer = aiChatContextPointer(for: run, requiresExistingRecord: false) else {
      return false
    }
    let actionText = automaticAIChatActionText(
      pointer,
      prompt: continuation.prompt
    )
    let context = captureAIChatCorpusContext()
    let outcome = await awaitAIChatEnqueueAndImmediateDrain(
      enqueueAIChatMessage(
        actionText,
        attachments: [],
        in: thread.id,
        context: context
      )
    )
    switch outcome {
    case .enqueued:
      return true
    case .superseded:
      return false
    case .rejected:
      throw AIChatEnqueueFailure.rejected
    }
  }

  /// Only Approve and Request Changes hand work back to an agent. Rejecting an
  /// approval or marking it done elsewhere just records the decision in the run's
  /// source; it starts an agent turn only when it settles a batch whose earlier
  /// Approve is still waiting on it, so that approved action is not orphaned.
  nonisolated static func approvalDecisionStartsAgentTurn(
    decision: String,
    run: AgentRunItem
  ) -> Bool {
    switch decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "approved", "revised":
      return true
    default:
      return !run.approvedCurrentApprovalBoundary.isEmpty
    }
  }

  func continueAfterApprovalBoundary(
    _ run: AgentRunItem,
    decision: String,
    waits: Bool
  ) async {
    guard Self.approvalDecisionStartsAgentTurn(decision: decision, run: run) else { return }
    if waits {
      await continueOpenClawAfterApprovalBoundary(run)
      return
    }
    Task { @MainActor [weak self] in
      await self?.continueOpenClawAfterApprovalBoundary(run)
    }
  }

  /// Resumes the requesting agent after a decision when the run supports it, and reports
  /// what happened. `nil` means no automatic continuation applies to this run.
  @discardableResult
  func continueOpenClawAfterApprovalBoundary(_ run: AgentRunItem) async -> MobileRemoteApprovalContinuation? {
    if run.status == "running",
       run.pendingApprovalCount == 0,
       run.hasOpenClawApprovalContinuation {
      do {
        let continued = try await continueOpenClawAfterApproval(run)
        statusText = continued
          ? "Review decisions recorded; continued \(run.goal)"
          : "Review decisions recorded; \(run.goal) is already continuing"
        return continued ? .continued : .alreadyContinuing
      } catch {
        errorText = error.localizedDescription
        do {
          let blocked = try await recordAgentRunApprovalContinuationFailure(run)
          statusText = "Review decisions recorded; \(blocked.goal) is blocked because continuation failed"
          return .continuationFailedBlocked
        } catch {
          statusText = "Review decisions recorded; continuation failed and the run could not be durably blocked"
          return .continuationFailed
        }
      }
    }
    guard run.workflowId != nil else {
      guard let revision = run.revisionAwaitingHandoff else { return nil }
      return await continueAgentRunAfterRevision(run, approval: revision)
    }
    guard let revision = run.resumableRevisionApproval else { return nil }
    do {
      guard try await continueOpenClawWorkflowAfterRevision(run, approval: revision) else {
        return nil
      }
      await refreshAgentRuns()
      statusText = "Changes requested; continuing \(run.goal)"
      return .revisionContinuing
    } catch {
      errorText = error.localizedDescription
      statusText = "Changes recorded; OpenClaw continuation pending"
      return .continuationFailed
    }
  }

  /// Hands a Request Changes note on a run that is not a workflow back to an agent.
  /// The run returns to `running`, the note goes to the run's correlated OpenClaw
  /// session (or a per-run session) in a "Revision" chat thread, and the agent is told
  /// to request a replacement approval on the same run. If the hand-off fails, the run
  /// is durably blocked with a reason that says so.
  private func continueAgentRunAfterRevision(
    _ run: AgentRunItem,
    approval: AgentRunApprovalItem
  ) async -> MobileRemoteApprovalContinuation? {
    let resumed: AgentRunItem
    do {
      resumed = try await resumeAgentRunForRevision(run)
    } catch {
      errorText = error.localizedDescription
      statusText = "Changes recorded; \(run.goal) could not be resumed for revision"
      return .continuationFailed
    }
    if let index = agentRuns.firstIndex(where: { $0.id == resumed.id }) {
      agentRuns[index] = resumed
    } else {
      agentRuns.insert(resumed, at: 0)
    }
    let sessionKey = run.openClawSessionKey ?? Self.approvedRunContinuationSessionKey(
      runID: run.id,
      agentID: openClawAgentID
    )
    let prompt = Self.agentRunRevisionContinuationPrompt(run: run, approval: approval)
    do {
      try await dispatchAgentRunRevision(
        resumed,
        approval: approval,
        prompt: prompt,
        sessionKey: sessionKey
      )
      statusText = "Changes requested; the agent is revising \(run.goal)"
      return .revisionContinuing
    } catch {
      errorText = error.localizedDescription
      do {
        let blocked = try await recordAgentRunApprovalContinuationFailure(
          resumed,
          reason: Self.agentRunRevisionDispatchFailureReason
        )
        statusText = "Changes recorded; \(blocked.goal) is blocked because the revision could not be handed to an agent"
        return .continuationFailedBlocked
      } catch {
        statusText = "Changes recorded; the revision could not be handed to an agent or durably blocked"
        return .continuationFailed
      }
    }
  }

  private func resumeAgentRunForRevision(_ run: AgentRunItem) async throws -> AgentRunItem {
    if let agentRunRevisionResumeForTesting {
      return try await agentRunRevisionResumeForTesting(run)
    }
    guard let corpusRoot else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No corpus is selected."])
    }
    return try await cli.runJSON([
      "run", "resume", run.id,
      "--actor", "Org2Workspace",
      "--dir", corpusRoot.path,
      "--json"
    ])
  }

  private func dispatchAgentRunRevision(
    _ run: AgentRunItem,
    approval: AgentRunApprovalItem,
    prompt: String,
    sessionKey: String
  ) async throws {
    if let agentRunRevisionDispatchForTesting {
      try await agentRunRevisionDispatchForTesting(run, approval, prompt, sessionKey)
      return
    }
    let thread: AIChatThread
    if let existing = aiChatThreads.first(where: { $0.sessionKey == sessionKey }) {
      if existing.isSettled { reopenAIChatThread(existing.id) }
      thread = aiChatThreads.first(where: { $0.id == existing.id }) ?? existing
    } else {
      thread = createAIChatThread(
        title: "Revision: \(run.goal)",
        statusText: "Revising after requested changes",
        sessionKey: sessionKey
      )
    }
    guard let pointer = aiChatContextPointer(for: run, requiresExistingRecord: false) else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [
        NSLocalizedDescriptionKey: "The run could not be attached to its revision thread."
      ])
    }
    let actionText = automaticAIChatActionText(
      pointer,
      prompt: prompt,
      userText: approval.decisionNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    )
    let context = captureAIChatCorpusContext()
    let outcome = await awaitAIChatEnqueueAndImmediateDrain(
      enqueueAIChatMessage(
        actionText,
        attachments: [],
        in: thread.id,
        context: context
      )
    )
    switch outcome {
    case .enqueued:
      return
    case .superseded, .rejected:
      throw AIChatEnqueueFailure.rejected
    }
  }

  public func saveAgentRunAsWorkflow(_ run: AgentRunItem) async {
    guard let corpusRoot, run.status == "completed", !mutatingAgentRunIDs.contains(run.id) else { return }
    mutatingAgentRunIDs.insert(run.id)
    defer { mutatingAgentRunIDs.remove(run.id) }
    do {
      _ = try await cli.run([
        "workflow", "save", run.id,
        "--id", "workflow-\(run.id)",
        "--dir", corpusRoot.path,
        "--json"
      ])
      await refreshAgentWorkflows()
      if let workflow = agentWorkflows.first(where: { $0.id == "workflow-\(run.id)" }) {
        selectAgentWorkflow(workflow)
      }
      statusText = "Created draft workflow from \(run.goal)"
    } catch {
      errorText = error.localizedDescription
      statusText = "Save as workflow failed"
    }
  }

  public func openAgentRunRecord(_ run: AgentRunItem) {
    guard let corpusRoot else { return }
    let relativePath = CelorgaNames.runRecordRelativePath(runID: run.id, corpusRoot: corpusRoot)
    let recordURL = corpusRoot.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: recordURL.path) else {
      errorText = "The run record could not be found at \(relativePath)."
      statusText = "Run record missing"
      return
    }
    let values = try? recordURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    selectCorpusFile(CorpusFile(
      path: recordURL.path,
      relativePath: relativePath,
      modifiedAt: values?.contentModificationDate,
      byteCount: values?.fileSize.map(Int64.init)
    ), surface: .approvals)
  }

  public func askAIChatAboutAgentRun(
    _ run: AgentRunItem,
    threadMode: AIChatThreadMode = .newThread
  ) {
    guard let pointer = aiChatContextPointer(for: run, requiresExistingRecord: true) else { return }
    addAIChatContext(pointer, threadMode: threadMode)
  }

  @discardableResult
  public func respondToAgentRunClarification(_ run: AgentRunItem, response: String) async -> Bool {
    guard let corpusRoot, run.status == "blocked", !mutatingAgentRunIDs.contains(run.id) else { return false }
    guard let response = Self.normalizedAgentRunClarificationResponse(response) else {
      errorText = "Enter a response before resuming this run."
      statusText = "Clarification response required"
      return false
    }

    mutatingAgentRunIDs.insert(run.id)
    agentRunClarificationPhases[run.id] = .recording
    defer {
      mutatingAgentRunIDs.remove(run.id)
      agentRunClarificationPhases[run.id] = nil
    }
    do {
      let continuation: OpenClawRunContinuation
      do {
        if let agentRunClarificationReplyForTesting {
          continuation = try await agentRunClarificationReplyForTesting(run, response)
        } else {
          let gateway = OpenClawGatewayClient(settings: currentOpenClawSettings(allowKeychainRead: true))
          continuation = try await gateway.replyAndResumeRun(
            runID: run.id,
            response: response,
            corpusID: activeCorpusIdentity?.id,
            expectedUpdatedAt: run.updatedAt
          )
        }
      } catch {
        guard Self.shouldUseLocalClarificationResumeFallback(for: error) else { throw error }
        let commented: AgentRunItem = try await cli.runJSON([
          "run", "comment", run.id,
          "--author", "Workspace user",
          "--body", response,
          "--dir", corpusRoot.path,
          "--json"
        ])
        agentRunClarificationPhases[run.id] = .resuming
        let resumed: AgentRunItem = try await cli.runJSON([
          "run", "resume", run.id,
          "--actor", "Org2Workspace",
          "--dir", corpusRoot.path,
          "--json"
        ])
        if let index = agentRuns.firstIndex(where: { $0.id == resumed.id }) {
          agentRuns[index] = resumed
        }
        continuation = OpenClawRunContinuation(
          runID: resumed.id,
          sessionKey: run.openClawSessionKey,
          prompt: Self.agentRunClarificationContinuationPrompt(
            run: commented,
            response: response
          )
        )
      }
      agentRunClarificationPhases[run.id] = .resuming
      await refreshAgentRuns()

      agentRunClarificationPhases[run.id] = .handingOff
      let thread: AIChatThread
      if let sessionKey = continuation.sessionKey,
         let existing = aiChatThreads.first(where: { $0.sessionKey == sessionKey }) {
        if existing.isSettled { reopenAIChatThread(existing.id) }
        thread = aiChatThreads.first(where: { $0.id == existing.id }) ?? existing
      } else {
        thread = createAIChatThread(
          title: "Resume: \(run.goal)",
          statusText: continuation.sessionKey == nil
            ? "Continuing in a new OpenClaw session"
            : "Continuing after clarification",
          sessionKey: continuation.sessionKey
        )
      }
      selectAIChatThread(thread.id)
      guard let pointer = aiChatContextPointer(for: run, requiresExistingRecord: false) else {
        statusText = "Run context could not be resolved"
        return false
      }
      let actionText = automaticAIChatActionText(
        pointer,
        prompt: continuation.prompt,
        userText: response
      )
      let context = captureAIChatCorpusContext()
      let outcome = await awaitAIChatEnqueueAndImmediateDrain(
        enqueueAIChatMessage(
          actionText,
          attachments: [],
          in: thread.id,
          context: context
        )
      )
      switch outcome {
      case .enqueued:
        break
      case .superseded:
        return false
      case .rejected:
        throw AIChatEnqueueFailure.rejected
      }
      statusText = continuation.sessionKey == nil
        ? "Response recorded; continuing \(run.goal) in a new OpenClaw session"
        : "Response recorded and sent; continuing \(run.goal)"
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = "Clarification response failed"
      return false
    }
  }

  nonisolated static func normalizedAgentRunClarificationResponse(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  nonisolated static func shouldUseLocalClarificationResumeFallback(for error: Error) -> Bool {
    guard case let OpenClawGatewayError.gateway(code, message) = error else { return false }
    let normalizedCode = (code ?? "").uppercased()
    if normalizedCode.contains("METHOD")
        && (normalizedCode.contains("UNKNOWN")
          || normalizedCode.contains("NOT_FOUND")
          || normalizedCode.contains("UNSUPPORTED")) {
      return true
    }
    let normalizedMessage = message.lowercased()
    if normalizedMessage.contains("missing scope")
        && normalizedMessage.contains("operator.admin") {
      return true
    }
    return normalizedMessage.contains("org2.run.replyandresume")
      && (normalizedMessage.contains("unknown")
        || normalizedMessage.contains("not found")
        || normalizedMessage.contains("not registered")
        || normalizedMessage.contains("unsupported"))
  }

  nonisolated static func shouldUseLocalApprovalContinuationFallback(for error: Error) -> Bool {
    guard case let OpenClawGatewayError.gateway(code, message) = error else { return false }
    let normalizedCode = (code ?? "").uppercased()
    if normalizedCode.contains("METHOD")
        && (normalizedCode.contains("UNKNOWN")
          || normalizedCode.contains("NOT_FOUND")
          || normalizedCode.contains("UNSUPPORTED")) {
      return true
    }
    let normalizedMessage = message.lowercased()
    return normalizedMessage.contains("org2.run.resumeapproved")
      && (normalizedMessage.contains("unknown")
        || normalizedMessage.contains("not found")
        || normalizedMessage.contains("not registered")
        || normalizedMessage.contains("unsupported"))
  }

  nonisolated static func agentRunApprovalContinuationPrompt(run: AgentRunItem) -> String {
    [
      "ORG2_RUN_ID: \(run.id)",
      "ORG2_RUN_RESUME: approval-decided",
      "",
      "Continue the existing Celorga run “\(run.goal)” after every item in its approval boundary was decided.",
      "Re-read the durable run with the Celorga CLI and continue from the first incomplete step. Do not create a replacement run or request the same approval again.",
      "Perform only exact actions whose review material is approved. Skip every rejected or canceled action, and do not substitute a new recipient, payload, command, or attachment.",
      "For provider drafts, resolve the exact authority through `celorga run approval-resolve --decision-key artifact:PROVIDER:TOOL:DRAFT_ID --json` and verify provider state before any retry.",
      "Record external receipts and the final outcome on this durable run, or record the next specific blocker if the work cannot continue."
    ].joined(separator: "\n")
  }

  nonisolated static func agentRunRevisionContinuationPrompt(
    run: AgentRunItem,
    approval: AgentRunApprovalItem
  ) -> String {
    let note = approval.decisionNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return [
      "ORG2_RUN_ID: \(run.id)",
      "ORG2_RUN_RESUME: revision-requested",
      "ORG2_REVISION_APPROVAL_ID: \(approval.id)",
      "",
      "Revise the existing Celorga run “\(run.goal)”. The reviewer requested changes instead of approving “\(approval.title)”.",
      "Requested changes:",
      note,
      "",
      "Material that was not approved:",
      approval.action.trimmingCharacters(in: .whitespacesAndNewlines),
      "",
      "Re-read the durable run with the Celorga CLI (`celorga run show \(run.id) --json`). The run is running again; do not create a replacement run.",
      "Do not perform the protected action. A revision request is not approval, and the earlier approval stays revised as history.",
      "Address every requested change and prepare new review material. If a provider draft is still the right vehicle, update it and keep the exact `Provider draft: PROVIDER:TOOL:DRAFT_ID` line; otherwise create the material the reviewer asked for.",
      "When the revision is ready, request a replacement approval on this run with `celorga run approval-request \(run.id) --title TEXT --action TEXT` containing the exact revised material. That puts the run back in the reviewer's queue.",
      "If the requested changes cannot be addressed, record the specific blocker with `celorga run block \(run.id) --reason TEXT`."
    ].joined(separator: "\n")
  }

  nonisolated static let agentRunRevisionDispatchFailureReason =
    AgentRunItem.revisionDispatchFailureReason

  nonisolated static let agentRunApprovalContinuationFailureReason =
    "Approved actions are recorded, but OpenClaw did not accept the continuation. After restoring the OpenClaw connection, choose Resume and then Continue approved work; do not repeat the approval or create a replacement run."

  /// Title prefix and status for the chat thread that continues a run after its
  /// approval boundary is decided. A boundary with no approved item (every item
  /// rejected or canceled) must not be labeled as approved work.
  nonisolated static func approvalContinuationThreadLabels(
    kind: String,
    hasSessionKey: Bool,
    hasApprovedAction: Bool
  ) -> (titlePrefix: String, status: String) {
    switch kind {
    case "workflow":
      return ("Workflow", "Continuing approved workflow")
    case "external-draft":
      return hasApprovedAction
        ? ("Approved draft", "Sending approved draft")
        : ("Declined draft", "Recording the declined draft")
    default:
      guard hasApprovedAction else {
        return ("Declined run", hasSessionKey
          ? "Recording the declined approval"
          : "Recording the declined approval in a new OpenClaw session")
      }
      return ("Approved run", hasSessionKey
        ? "Continuing approved run"
        : "Continuing approved run in a new OpenClaw session")
    }
  }

  nonisolated static func approvedRunContinuationSessionKey(
    runID: String,
    agentID: String
  ) -> String {
    agentScopedOpenClawSessionKey("org2-run:\(runID)", agentID: agentID)
  }

  nonisolated static func agentRunClarificationContinuationPrompt(
    run: AgentRunItem,
    response: String
  ) -> String {
    [
      "ORG2_RUN_ID: \(run.id)",
      "ORG2_RUN_RESUME: clarification-answered",
      "",
      "Continue the existing Celorga run “\(run.goal)” after the user's clarification.",
      "Clarification: \(run.blockedReason ?? "Clarification requested")",
      "User response:",
      response.trimmingCharacters(in: .whitespacesAndNewlines),
      "",
      "Re-read the durable run before acting. The response is already recorded on that run and the run is now running; do not create a replacement run.",
      "If this lifecycle run coordinates a more specific child run carrying the same clarification, record the answer on that child and resume it rather than leaving the underlying work blocked.",
      "Continue from the blocked step, preserve existing context and review boundaries, and update this durable run with the outcome or the next actionable blocker."
    ].joined(separator: "\n")
  }

  public func openAgentRunArtifact(_ artifact: AgentRunArtifactItem) {
    let path = artifact.path.hasPrefix("/")
      ? artifact.path
      : corpusRoot?.appendingPathComponent(artifact.path).path ?? artifact.path
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
      errorText = "The run output could not be found at \(artifact.path)."
      statusText = "Run output missing"
      return
    }
    if artifact.isPDF {
      NSWorkspace.shared.open(url)
      statusText = "Opened \(artifact.displayTitle)"
      return
    }
    let inAppExtensions = Set(["org", "org2", "md", "markdown", "txt"])
    guard inAppExtensions.contains(url.pathExtension.lowercased())
            || Self.isMediaFile(url.path)
    else {
      openFile(path: url.path, line: 1)
      statusText = "Opened \(artifact.displayTitle)"
      return
    }
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    selectCorpusFile(CorpusFile(
      path: url.path,
      relativePath: corpusRoot.map { root in
        url.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
      } ?? artifact.path,
      modifiedAt: values?.contentModificationDate,
      byteCount: values?.fileSize.map(Int64.init)
    ), surface: .approvals)
  }

  public func openAgentRunContext(_ context: AgentRunContextItem) {
    guard let corpusRoot, let reference = context.fileReference else {
      errorText = "This run context is not a local file reference."
      statusText = "Run context unavailable"
      return
    }
    let url = (reference.hasPrefix("/")
      ? URL(fileURLWithPath: reference)
      : corpusRoot.appendingPathComponent(reference)).standardizedFileURL
    let rootPath = corpusRoot.standardizedFileURL.path
    guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
      errorText = "The run context is outside the active corpus."
      statusText = "Run context unavailable"
      return
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
      errorText = "The run context could not be found at \(reference)."
      statusText = "Run context missing"
      return
    }
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    selectCorpusFile(CorpusFile(
      path: url.path,
      relativePath: url.path.replacingOccurrences(of: rootPath + "/", with: ""),
      modifiedAt: values?.contentModificationDate,
      byteCount: values?.fileSize.map(Int64.init)
    ), surface: .approvals)
  }

  private func approvalCandidateSources(
    files: [CorpusFile],
    corpusRoot: URL,
    updatesStatus: Bool
  ) async -> [ApprovalCandidateSource] {
    if updatesStatus {
      statusText = searchIndexTask == nil
        ? "Scanning approval candidates..."
        : "Scanning approvals while search index updates..."
    }

    let scanOperation = approvalCandidateScanOperationForTesting
    return await Task.detached(priority: .utility) {
      scanOperation?()
      if let indexedCandidates = Self.approvalCandidateSourcesFromFreshIndex(
        files: files,
        corpusRoot: corpusRoot
      ) {
        return indexedCandidates
      }
      return Self.approvalCandidateSourcesByScanningFiles(files: files)
    }.value
  }

  nonisolated private static func approvalCandidateSourcesFromFreshIndex(
    files: [CorpusFile],
    corpusRoot: URL
  ) -> [ApprovalCandidateSource]? {
    guard let index = freshWorkspaceSearchIndex(files: files, corpusRoot: corpusRoot) else {
      return nil
    }
    let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    var candidates: [ApprovalCandidateSource] = []
    for indexedFile in index.files {
      guard let file = filesByPath[indexedFile.path],
            isApprovalIndexableFile(file)
      else {
        continue
      }
      candidates.append(contentsOf: approvalCandidateSources(
        file: file,
        sourceLines: indexedFile.lines
      ))
    }
    return candidates
  }

  nonisolated private static func approvalCandidateSourcesFromStoredIndex(corpusRoot: URL) -> [ApprovalCandidateSource]? {
    guard let index = storedWorkspaceSearchIndex(corpusRoot: corpusRoot) else {
      return nil
    }
    var candidates: [ApprovalCandidateSource] = []
    for indexedFile in index.files {
      let file = CorpusFile(
        path: indexedFile.path,
        relativePath: indexedFile.relativePath,
        modifiedAt: Date(timeIntervalSince1970: Double(indexedFile.modifiedMs) / 1000),
        byteCount: indexedFile.byteCount
      )
      guard isApprovalIndexableFile(file) else { continue }
      candidates.append(contentsOf: approvalCandidateSources(
        file: file,
        sourceLines: indexedFile.lines
      ))
    }
    return candidates
  }

  nonisolated private static func approvalCandidateSourcesByScanningFiles(files: [CorpusFile]) -> [ApprovalCandidateSource] {
    var candidates: [ApprovalCandidateSource] = []
    for file in files {
      guard isApprovalIndexableFile(file),
            let raw = try? String(contentsOfFile: file.path, encoding: .utf8)
      else {
        continue
      }
      let lines = normalizeLineEndings(raw)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      candidates.append(contentsOf: approvalCandidateSources(file: file, sourceLines: lines))
    }
    return candidates
  }

  nonisolated private static func approvalCandidateSources(
    file: CorpusFile,
    sourceLines: [String]
  ) -> [ApprovalCandidateSource] {
    approvalCandidateSourceSlices(sourceLines).map { slice in
      ApprovalCandidateSource(
        file: file,
        sourceText: slice.sourceText,
        parseText: slice.sourceText,
        sourceLineOffset: slice.sourceLineOffset
      )
    }
  }

  nonisolated static func approvalCandidateSourceSlices(
    _ sourceLines: [String]
  ) -> [ApprovalCandidateSourceSlice] {
    var ranges: [Range<Int>] = []
    for index in sourceLines.indices {
      guard let level = approvalHeadingLevel(sourceLines[index]) else { continue }

      let directEnd = firstHeadingIndex(in: sourceLines, after: index) ?? sourceLines.count
      let directText = sourceLines[index..<directEnd].joined(separator: "\n")
      guard approvalCandidateTextMayContainItem(directText) else { continue }

      let subtreeEnd = firstHeadingIndex(in: sourceLines, after: index, maxLevel: level) ?? sourceLines.count
      ranges.append(index..<subtreeEnd)
    }
    guard !ranges.isEmpty else { return [] }

    return mergedApprovalCandidateRanges(ranges).map { range in
      ApprovalCandidateSourceSlice(
        sourceText: sourceLines[range].joined(separator: "\n"),
        sourceLineOffset: range.lowerBound
      )
    }
  }

  nonisolated private static func mergedApprovalCandidateRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
    let sorted = ranges.sorted { lhs, rhs in
      lhs.lowerBound == rhs.lowerBound
        ? lhs.upperBound < rhs.upperBound
        : lhs.lowerBound < rhs.lowerBound
    }
    var merged: [Range<Int>] = []
    for range in sorted {
      guard let last = merged.last else {
        merged.append(range)
        continue
      }
      if range.lowerBound <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  nonisolated private static func firstHeadingIndex(
    in lines: [String],
    after index: Int,
    maxLevel: Int? = nil
  ) -> Int? {
    guard index + 1 < lines.count else { return nil }
    for candidateIndex in (index + 1)..<lines.count {
      guard let level = approvalHeadingLevel(lines[candidateIndex]) else { continue }
      if let maxLevel {
        if level <= maxLevel {
          return candidateIndex
        }
      } else {
        return candidateIndex
      }
    }
    return nil
  }

  nonisolated private static func approvalHeadingLevel(_ line: String) -> Int? {
    var count = 0
    for character in line {
      if character == "*" {
        count += 1
      } else {
        break
      }
    }
    guard count > 0,
          line.dropFirst(count).first?.isWhitespace == true
    else {
      return nil
    }
    return count
  }

  nonisolated private static func freshWorkspaceSearchIndex(files: [CorpusFile], corpusRoot: URL) -> WorkspaceSearchIndex? {
    let root = corpusRoot.standardizedFileURL
    let indexableFiles = files.filter { isApprovalIndexableFile($0) }
    let indexURL = searchIndexURL(corpusRoot: root)
    guard let data = try? Data(contentsOf: indexURL),
          let index = try? JSONDecoder().decode(WorkspaceSearchIndex.self, from: data),
          CelorgaNames.schemaMatches(index.schema, "org2:search-index:v1"),
          index.version == 1,
          URL(fileURLWithPath: index.rootDir).standardizedFileURL.path == root.path,
          index.recursive,
          !index.includeArchives,
          index.files.count == indexableFiles.count
    else {
      return nil
    }

    let expected = Dictionary(uniqueKeysWithValues: indexableFiles.map { ($0.path, $0) })
    for indexedFile in index.files {
      guard let file = expected[indexedFile.path],
            freshSearchIndexMetadataMatches(file: file, indexedFile: indexedFile)
      else {
        return nil
      }
    }
    return index
  }

  nonisolated private static func storedWorkspaceSearchIndex(corpusRoot: URL) -> WorkspaceSearchIndex? {
    let root = corpusRoot.standardizedFileURL
    let indexURL = searchIndexURL(corpusRoot: root)
    guard let data = try? Data(contentsOf: indexURL),
          let index = try? JSONDecoder().decode(WorkspaceSearchIndex.self, from: data),
          CelorgaNames.schemaMatches(index.schema, "org2:search-index:v1"),
          index.version == 1,
          URL(fileURLWithPath: index.rootDir).standardizedFileURL.path == root.path,
          index.recursive,
          !index.includeArchives
    else {
      return nil
    }
    return index
  }

  nonisolated private static func isApprovalIndexableFile(_ file: CorpusFile) -> Bool {
    guard !isDefaultIgnoredSyncArtifactPath(file.path) else { return false }
    let pathExtension = URL(fileURLWithPath: file.path).pathExtension.lowercased()
    return pathExtension == "org" || pathExtension == "org2"
  }

  nonisolated private static func freshSearchIndexMetadataMatches(
    file: CorpusFile,
    indexedFile: WorkspaceSearchIndexFile
  ) -> Bool {
    if let modifiedAt = file.modifiedAt,
       let byteCount = file.byteCount {
      return Int64(modifiedAt.timeIntervalSince1970 * 1000) == indexedFile.modifiedMs
        && byteCount == indexedFile.byteCount
    }

    guard let values = try? URL(fileURLWithPath: file.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modifiedAt = values.contentModificationDate,
          let byteCount = values.fileSize
    else {
      return false
    }
    return Int64(modifiedAt.timeIntervalSince1970 * 1000) == indexedFile.modifiedMs
      && Int64(byteCount) == indexedFile.byteCount
  }

  nonisolated private static func searchIndexURL(corpusRoot: URL) -> URL {
    let configuredIndexHome = CelorgaNames.environment("ORG2_INDEX_HOME")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let indexHome: URL
    if let configuredIndexHome, !configuredIndexHome.isEmpty {
      let expanded = expandHomePath(configuredIndexHome)
      indexHome = URL(fileURLWithPath: expanded).standardizedFileURL
    } else {
      indexHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".org2", isDirectory: true)
        .appendingPathComponent("index", isDirectory: true)
    }

    return indexHome
      .appendingPathComponent(corpusIndexDirectoryName(corpusRoot: corpusRoot), isDirectory: true)
      .appendingPathComponent("search-v1.json")
  }

  nonisolated private static func corpusIndexDirectoryName(corpusRoot: URL) -> String {
    let resolvedPath = corpusRoot.standardizedFileURL.path
    let base = corpusRoot.lastPathComponent
    let slug = base
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let digest = SHA256.hash(data: Data(resolvedPath.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
      .prefix(12)
    return "\((slug.isEmpty ? "corpus" : slug))-\(digest)"
  }

  nonisolated private static func expandHomePath(_ path: String) -> String {
    if path == "~" {
      return FileManager.default.homeDirectoryForCurrentUser.path
    }
    if path.hasPrefix("~/") {
      return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(String(path.dropFirst(2)))
        .path
    }
    return path
  }

  nonisolated static func approvalCandidateTextMayContainItem(_ raw: String) -> Bool {
    let normalized = raw.lowercased()
    guard normalized.contains(":") else { return false }

    let hasHumanApprovalTitle = approvalTextHasHumanApprovalTitle(normalized)
    let hasPendingStatus = approvalStatusNeedles.contains { normalized.contains($0) }
    let hasSpecificReviewStatusKey = approvalSpecificReviewStatusKeys.contains {
      normalized.contains($0)
    }
    if hasSpecificReviewStatusKey && hasPendingStatus && hasHumanApprovalTitle {
      return true
    }

    if normalized.contains(":status:"),
       hasPendingStatus,
       hasHumanApprovalTitle {
      return true
    }

    let hasGateKey = approvalGateKeys.contains { normalized.contains($0) }
    if hasGateKey && containsApprovalSignal(normalized) {
      return true
    }

    let hasAccessPolicyKey = approvalAccessPolicyKeys.contains { normalized.contains($0) }
    return hasAccessPolicyKey && (hasPendingStatus || containsApprovalSignal(normalized))
  }

  nonisolated private static let approvalSpecificReviewStatusKeys = [
    ":org2_review_status:",
    ":review_status:",
    ":review:",
    ":followup_status:",
    ":reply_status:"
  ]

  nonisolated private static let approvalGateKeys = [
    ":waiting_on:",
    ":blocked_by:",
    ":org2_waiting_on:",
    ":next_action:",
    ":action_required:",
    ":org2_next_action:",
    ":handoff_summary:",
    ":org2_handoff_summary:"
  ]

  nonisolated private static let approvalAccessPolicyKeys = [
    ":access_policy:",
    ":review_policy:"
  ]

  nonisolated private static let approvalStatusNeedles = [
    "review-required",
    "requires-review",
    "approval-required",
    "needs-approval",
    "need-approval",
    "needs-review",
    "need-review",
    "pending-review",
    "pending-approval",
    "require-approval",
    "waiting-on-approval",
    "draft-needs-review",
    "draft-needs-approval",
    "reply-review",
    "needs-avi",
    "avi-approval",
    "needs-human",
    "human-review",
    "generated",
    "draft"
  ]

  nonisolated private static let humanApprovalTitleRegex = try? NSRegularExpression(
    pattern: #"(?m)^\*+\s+(?:(?:todo|in_progress|prog|wait|hold|paused)\s+)?(?:\[#[a-z0-9]\]\s+)?(?:approve|review|review/|review-send|review and approve|review/approve)\b"#
  )

  nonisolated private static func approvalTextHasHumanApprovalTitle(_ normalizedText: String) -> Bool {
    guard let humanApprovalTitleRegex else { return false }
    let range = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
    return humanApprovalTitleRegex.firstMatch(in: normalizedText, range: range) != nil
  }
}
