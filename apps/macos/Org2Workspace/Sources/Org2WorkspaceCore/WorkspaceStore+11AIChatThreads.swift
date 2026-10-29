import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  public func workspaceDidBecomeActive() {
    guard isWorkspaceRealtimeRefreshActive else { return }
    scheduleAgendaClockInvalidation()
    scheduleSyncedAIChatTranscriptRefresh()
    scheduleAIChatLiveRefresh()

    if needsFullCorpusRefreshAfterEvents {
      scheduleFullCorpusFileRefreshAfterEvents()
      return
    }
    if !pendingCorpusChangedPaths.isEmpty {
      scheduleIncrementalCorpusRefresh([])
      return
    }

    // The filesystem event may have arrived while the app was inactive, and
    // sync software may preserve the original modification time. Verify the
    // visible file by content whenever the workspace becomes active.
    if let selectedLocation {
      scheduleSelectedDetailFreshnessCheck(
        for: selectedLocation,
        mode: selectedEntrySourceMode
      )
    }

    // Activation itself is not a data change. File events, the selected-file
    // freshness check above, source sync, and run-review polling invalidate the
    // relevant surfaces. Unconditionally invalidating the visible surface here
    // made every Cmd-Tab launch a potentially corpus-wide refresh.
  }

  var corpusFileWatcherRootPathsForTesting: Set<String> {
    Set(corpusFileWatchers.keys)
  }

  var corpusEventPipelineStateForTesting: (
    pendingChangedPathCount: Int,
    activeSourceSyncEventBatchCount: Int,
    needsFullRefresh: Bool,
    hasRefreshTask: Bool
  ) {
    (
      pendingCorpusChangedPaths.count,
      activeSourceSyncEventBatchCount,
      needsFullCorpusRefreshAfterEvents,
      postAIChatWorkspaceRefreshTask != nil
    )
  }

  func hasWorkspaceSurfaceRefreshTaskForTesting(_ surface: WorkspaceSurface) -> Bool {
    workspaceSurfaceRefreshTasks[surface] != nil
  }

  public func isWorkspaceSurfaceDirty(_ surface: WorkspaceSurface) -> Bool {
    dirtyWorkspaceSurfaces.contains(surface)
  }

  func markWorkspaceSurfacesDirty(
    _ surfaces: Set<WorkspaceSurface>,
    refreshVisible: Bool
  ) {
    var invalidatedSurfaces = surfaces.filter { $0 != .home }
    if invalidatedSurfaces.contains(.files) {
      invalidatedSurfaces.insert(.canvases)
    }
    // The calendar shows agenda items, synced events, and meeting notes.
    if !invalidatedSurfaces.isDisjoint(with: [.agenda, .meetings, .sources]) {
      invalidatedSurfaces.insert(.calendar)
    }
    if invalidatedSurfaces.contains(.approvals) {
      markRunReviewPagesDirty()
    }
    dirtyWorkspaceSurfaces.formUnion(invalidatedSurfaces)
    for surface in invalidatedSurfaces {
      workspaceSurfaceDirtyGenerations[surface, default: 0] &+= 1
    }
    guard refreshVisible,
          isWorkspaceRealtimeRefreshActive,
          dirtyWorkspaceSurfaces.contains(selectedSurface)
    else {
      return
    }
    scheduleRefreshForActivatedSurface(selectedSurface)
  }

  func markWorkspaceSurfaceCleanIfUnchanged(
    _ surface: WorkspaceSurface,
    generation: UInt64
  ) {
    guard workspaceSurfaceDirtyGenerations[surface, default: 0] == generation else { return }
    dirtyWorkspaceSurfaces.remove(surface)
  }

  func scheduleRefreshForActivatedSurface(
    _ surface: WorkspaceSurface,
    delayNanoseconds: UInt64 = 0
  ) {
    guard isWorkspaceRealtimeRefreshActive,
          dirtyWorkspaceSurfaces.contains(surface),
          workspaceSurfaceRefreshTasks[surface] == nil
    else {
      return
    }

    let token = UUID()
    let task = Task { @MainActor [weak self] in
      if delayNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
      } else {
        await Task.yield()
      }
      guard !Task.isCancelled,
            let self,
            self.workspaceSurfaceRefreshTasks[surface]?.token == token
      else { return }
      await self.refreshWorkspaceSurfaceIfDirty(surface)
      guard self.workspaceSurfaceRefreshTasks[surface]?.token == token else { return }
      self.workspaceSurfaceRefreshTasks[surface] = nil
      if self.isWorkspaceRealtimeRefreshActive,
         self.selectedSurface == surface,
         self.dirtyWorkspaceSurfaces.contains(surface) {
        self.scheduleRefreshForActivatedSurface(surface, delayNanoseconds: 150_000_000)
      }
    }
    workspaceSurfaceRefreshTasks[surface] = (token, task)
  }

  func refreshWorkspaceSurfaceIfDirty(_ surface: WorkspaceSurface) async {
    guard dirtyWorkspaceSurfaces.contains(surface),
          !workspaceSurfaceIsRefreshing(surface)
    else {
      return
    }
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[surface, default: 0]

    switch surface {
    case .home:
      break
    case .agenda:
      if agendaMode == .assigned {
        await refreshAssignedWork(showsLoading: false)
      } else {
        await refreshAgenda(preserveSelection: true, updatesStatus: false)
      }
    case .calendar:
      await refreshCalendar(force: true)
    case .savedViews:
      break
    case .approvals:
      await refreshSelectedRunReviewPageIfNeeded()
    case .files, .canvases:
      await refreshCorpusFiles()
    case .search:
      if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if dirtyWorkspaceSurfaces.contains(.approvals) {
          await refreshAgentRuns()
        }
        await runSearch()
      }
    case .meetings:
      await refreshMeetings()
    case .sources:
      await refreshSourceConnections()
    case .aiChat:
      await refreshAIChatThreadRecords(showsLoading: false)
    case .externalThreads:
      await refreshExternalThreads()
    case .skills:
      refreshCorpusAgentSkills()
    case .activity:
      await refreshActivitySources()
    case .people, .companies:
      crm.markStale()
    case .pluginApp:
      break
    }
    markWorkspaceSurfaceCleanIfUnchanged(surface, generation: dirtyGeneration)
  }

  private func workspaceSurfaceIsRefreshing(_ surface: WorkspaceSurface) -> Bool {
    switch surface {
    case .home:
      false
    case .agenda:
      agendaMode == .assigned ? isRefreshingAssignedWork : isRefreshingAgenda
    case .calendar:
      isRefreshingCalendar
    case .savedViews:
      false
    case .approvals:
      switch runsAndReviewPage {
      case .runs: isRefreshingAgentRuns
      case .review: isRefreshingApprovals
      case .goals: isRefreshingAgentGoals
      case .agents: isRefreshingAgentProfiles
      case .workflows: isRefreshingAgentWorkflows
      }
    case .files, .canvases:
      isScanningCorpusFiles
    case .search:
      isSearching
    case .meetings:
      isLoadingMeetings
    case .sources:
      isLoadingSources
    case .aiChat:
      isRefreshingAIChatThreadRecords
    case .externalThreads:
      isRefreshingExternalThreads
    case .skills:
      false
    case .activity:
      isRefreshingAgentRuns || isRefreshingApprovals || isRefreshingAgentWorkflows
    case .people, .companies:
      crm.isLoading
    case .pluginApp:
      false
    }
  }

  func scheduleAgendaClockInvalidation(now: Date = Date()) {
    agendaClockRefreshTask?.cancel()
    guard corpusRoot != nil else { return }
    let next = Self.nextAgendaClockInvalidationDate(after: now)
    let delay = max(0.1, next.timeIntervalSince(now))
    agendaClockRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      self.markWorkspaceSurfacesDirty([.agenda], refreshVisible: true)
      self.scheduleAgendaClockInvalidation()
    }
  }

  nonisolated static func nextAgendaClockInvalidationDate(
    after date: Date,
    calendar: Calendar = .current
  ) -> Date {
    let start = calendar.startOfDay(for: date)
    return calendar.date(byAdding: .day, value: 1, to: start)
      ?? date.addingTimeInterval(86_400)
  }

  func scheduleIncrementalCorpusRefresh(_ changedPaths: [String]) {
    pendingCorpusChangedPaths.formUnion(changedPaths.map {
      URL(fileURLWithPath: $0).standardizedFileURL.path
    })
    scheduleCorpusEventRefreshTask()
  }

  func scheduleRunReviewRefreshAfterEvents() {
    runReviewFileEventGeneration += 1
    guard runReviewFileEventRefreshTask == nil else { return }
    guard isWorkspaceRealtimeRefreshActive else { return }

    runReviewFileEventRefreshTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled {
        let generation = self.runReviewFileEventGeneration
        do {
          try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        guard generation == self.runReviewFileEventGeneration else { continue }
        guard self.isWorkspaceRealtimeRefreshActive,
              self.selectedSurface == .approvals || self.selectedSurface == .search else {
          self.runReviewFileEventRefreshTask = nil
          return
        }

        await self.refreshWorkspaceSurfaceIfDirty(self.selectedSurface)
        if generation == self.runReviewFileEventGeneration {
          self.runReviewFileEventRefreshTask = nil
          return
        }
      }
    }
  }

  func scheduleFullCorpusFileRefreshAfterEvents() {
    needsFullCorpusRefreshAfterEvents = true
    scheduleCorpusEventRefreshTask()
  }

  func scheduleCorpusEventRefreshTask() {
    guard isWorkspaceRealtimeRefreshActive,
          activeSourceSyncEventBatchCount == 0,
          postAIChatWorkspaceRefreshTask == nil
    else {
      return
    }
    corpusEventRefreshGeneration += 1
    let generation = corpusEventRefreshGeneration
    postAIChatWorkspaceRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 120_000_000)
      guard let self else { return }

      while !Task.isCancelled,
            self.isWorkspaceRealtimeRefreshActive,
            self.activeSourceSyncEventBatchCount == 0 {
        if self.needsFullCorpusRefreshAfterEvents {
          self.needsFullCorpusRefreshAfterEvents = false
          self.pendingCorpusChangedPaths = []
          await self.performFullCorpusFileRefreshAfterEvents()
          guard generation == self.corpusEventRefreshGeneration else { return }
        } else {
          let paths = Array(self.pendingCorpusChangedPaths)
          self.pendingCorpusChangedPaths = []
          await self.applyIncrementalCorpusChanges(paths)
          guard generation == self.corpusEventRefreshGeneration else { return }
          if Task.isCancelled {
            self.pendingCorpusChangedPaths.formUnion(paths)
            break
          }
        }

        guard self.needsFullCorpusRefreshAfterEvents ||
                !self.pendingCorpusChangedPaths.isEmpty
        else {
          break
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
      }

      guard generation == self.corpusEventRefreshGeneration else { return }
      self.postAIChatWorkspaceRefreshTask = nil
      if self.isWorkspaceRealtimeRefreshActive,
         self.needsFullCorpusRefreshAfterEvents ||
          !self.pendingCorpusChangedPaths.isEmpty {
        self.scheduleCorpusEventRefreshTask()
      }
    }
  }

  func performFullCorpusFileRefreshAfterEvents() async {
    markWorkspaceSurfacesDirty(
      [.agenda, .approvals, .files, .search, .meetings, .sources, .aiChat],
      refreshVisible: false
    )
    let filesDirtyGeneration = workspaceSurfaceDirtyGenerations[.files, default: 0]
    await refreshCorpusFiles()
    guard !Task.isCancelled else { return }
    await searchIndexTask?.value
    guard !Task.isCancelled else { return }
    markWorkspaceSurfaceCleanIfUnchanged(.files, generation: filesDirtyGeneration)
    await refreshSelectedDetailFromDisk()
    guard !Task.isCancelled else { return }
    await refreshWorkspaceSurfaceIfDirty(selectedSurface)
  }

  private func applyIncrementalCorpusChanges(_ changedPaths: [String]) async {
    guard let corpusRoot, !changedPaths.isEmpty else { return }
    let root = corpusRoot.standardizedFileURL
    let sessionGeneration = corpusSessionGeneration
    let rootPrefix = root.path + "/"
    let paths = Array(Set(changedPaths.map {
      URL(fileURLWithPath: $0).standardizedFileURL.path
    }.filter { $0.hasPrefix(rootPrefix) }))
    guard !paths.isEmpty else { return }
    scheduleTodoStateObservation(for: paths, corpusRoot: root)

    if let incrementalCorpusChangePreparationForTesting {
      await incrementalCorpusChangePreparationForTesting(root, paths)
      guard !Task.isCancelled,
            isCurrentCorpusSession(root: root, generation: sessionGeneration)
      else { return }
    }

    let currentFiles = corpusFiles
    let (refreshedFiles, catalogUpdate) = await Task.detached(priority: .utility) {
      let refreshedFiles = paths.compactMap { Self.corpusFile(atPath: $0, corpusRoot: root) }
      let update = CorpusFileCatalog.applying(
        changedPaths: Set(paths),
        refreshedFiles: refreshedFiles,
        to: currentFiles
      )
      return (refreshedFiles, update)
    }.value
    guard !Task.isCancelled,
          isCurrentCorpusSession(root: root, generation: sessionGeneration)
    else { return }
    let changedSet = Set(paths)
    if catalogUpdate.didChange {
      corpusFiles = catalogUpdate.files
      await awaitCorpusFilePublication()
      guard !Task.isCancelled,
            isCurrentCorpusSession(root: root, generation: sessionGeneration)
      else { return }
      await reconcilePinnedFiles(for: root)
    }

    await updateSearchIndex(
      changedPaths: paths,
      corpusRoot: root,
      sessionGeneration: sessionGeneration
    )
    guard !Task.isCancelled,
          isCurrentCorpusSession(root: root, generation: sessionGeneration)
    else { return }
    await updateOrgRoamLinkResolver(changedPaths: changedSet, refreshedFiles: refreshedFiles)
    guard !Task.isCancelled,
          isCurrentCorpusSession(root: root, generation: sessionGeneration)
    else { return }

    if let selectedLocation,
       changedSet.contains(URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path),
       editingBlockID == nil,
       !isEditingEntry,
       (!isLiveFileEditorSelected || !liveFileEditorHasUnsavedChanges) {
      // A user-initiated mutation may already have loaded and cached this exact
      // file version before its filesystem event arrives. Compare contents,
      // rather than modification time, so atomic sync replacements and tools
      // that preserve timestamps cannot leave the visible document stale.
      let cacheMatchesDisk = await cachedEntrySourceMatchesCurrentFileContents(
        for: selectedLocation,
        mode: selectedEntrySourceMode
      )
      guard !Task.isCancelled,
            isCurrentCorpusSession(root: root, generation: sessionGeneration)
      else { return }
      if !cacheMatchesDisk {
        invalidateCanonicalDocumentCache(for: selectedLocation.file)
        await loadEntrySource(for: selectedLocation)
        guard !Task.isCancelled,
              isCurrentCorpusSession(root: root, generation: sessionGeneration)
        else { return }
      }
    }

    guard !Task.isCancelled,
          isCurrentCorpusSession(root: root, generation: sessionGeneration)
    else { return }
    markWorkspaceSurfacesDirty(
      Self.invalidatedWorkspaceSurfaces(for: paths, corpusRoot: root),
      refreshVisible: false
    )
    await refreshWorkspaceSurfaceIfDirty(selectedSurface)
  }

  func applyIncrementalCorpusChangesForTesting(_ changedPaths: [String]) async {
    await applyIncrementalCorpusChanges(changedPaths)
  }

  private func updateSearchIndex(
    changedPaths: [String],
    corpusRoot: URL,
    sessionGeneration: UInt64
  ) async {
    guard isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
    searchIndexGeneration += 1
    let generation = searchIndexGeneration
    searchIndexTask?.cancel()
    searchIndexTask = Task { [cli] in
      do {
        let payload: SearchIndexBuildPayload = try await cli.runJSON([
          "index", "--dir", corpusRoot.path, "--recursive",
          "--files"
        ] + changedPaths + ["--incremental", "--format", "json"])
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard self.searchIndexGeneration == generation,
                self.isCurrentCorpusSession(
                  root: corpusRoot,
                  generation: sessionGeneration
                )
          else { return }
          self.searchIndexTask = nil
          self.isBuildingSearchIndex = false
          self.searchIndexStatusText = "\(payload.fileCount) files indexed"
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard self.searchIndexGeneration == generation,
                self.isCurrentCorpusSession(
                  root: corpusRoot,
                  generation: sessionGeneration
                )
          else { return }
          self.searchIndexTask = nil
          self.isBuildingSearchIndex = false
          self.searchIndexStatusText = "Search index update deferred"
        }
      }
    }
    await searchIndexTask?.value
  }

  private func updateOrgRoamLinkResolver(
    changedPaths: Set<String>,
    refreshedFiles: [CorpusFile]
  ) async {
    orgRoamLinkResolverGeneration &+= 1
    let generation = orgRoamLinkResolverGeneration
    let existingNodes = orgRoamLinkResolver.nodes
    let linkAbbreviations = orgRoamLinkResolver.linkAbbreviations
    let files = corpusFiles
    let corpusRoot = corpusRoot
    let releaseMetrics = orgRoamSearchProjectionReleaseMetrics
    orgRoamLinkResolverRefreshTask?.cancel()
    orgRoamLinkResolverRefreshTask = nil

    let projectionBox = await Task.detached(priority: .utility) {
      let unchangedNodes = existingNodes.filter { !changedPaths.contains($0.file) }
      let changedNodes = refreshedFiles.flatMap(Self.scanRoamNodes)
      let resolver = OrgRoamLinkResolver(
        nodes: unchangedNodes + changedNodes,
        linkAbbreviations: linkAbbreviations
      )
      return OrgRoamSearchProjectionBox(
        projection: Self.makeOrgRoamSearchProjection(
          resolver: resolver,
          files: files,
          corpusRoot: corpusRoot
        ),
        releaseMetrics: releaseMetrics
      )
    }.value
    guard !Task.isCancelled,
          generation == orgRoamLinkResolverGeneration
    else {
      orgRoamSearchProjectionReleaseSink.enqueue([projectionBox])
      return
    }
    publishOrgRoamSearchProjection(projectionBox)
  }

  func aiChatQueuedStatusText() -> String {
    let destinationID = selectedAIChatThreadID.flatMap { threadID in
      activeSharedRoomDestinationByThreadID[threadID]
        ?? aiChatPendingUserMessageIDs(for: threadID).first.flatMap { messageID in
          aiChatMessages(for: threadID).first(where: { $0.id == messageID })?.targetDestinationID
        }
        ?? aiChatThreads.first(where: { $0.id == threadID })?.destinationID
    } ?? selectedAIChatDestination.id
    let title = aiChatDestinationTitle(destinationID)
    if aiChatQueuedMessageCount > 1 {
      return "Sending to \(title)... \(aiChatQueuedMessageCount - 1) queued"
    }
    return "Sending to \(title)..."
  }

  public func resetAIChat() {
    ensureAIChatThread()
    let threadID = selectedAIChatThreadID
    aiChatMessages = []
    clearAIChatDraftForSelectedThread()
    clearAIChatPendingAttachments()
    if let threadID {
      cancelAIChatPendingTurnRecovery(for: threadID)
      if let index = aiChatThreads.firstIndex(where: { $0.id == threadID }),
         aiChatThreads[index].runtime == .codex
           || aiChatThreads[index].runtime == .claude
           || aiChatThreads[index].runtime == .pi
           || aiChatThreads[index].runtime == .openCode
           || aiChatThreads[index].isSharedRoom {
        aiChatThreads[index] = aiChatThreads[index]
          .replacingAIChatMetadata(
            runtimeThreadID: .some(nil),
            runtimeThreadIDsByDestination: [:]
          )
        codexActiveTurnsByThreadID.removeValue(forKey: threadID)
        activeSharedRoomRuntimeByThreadID.removeValue(forKey: threadID)
        activeSharedRoomDestinationByThreadID.removeValue(forKey: threadID)
        persistAIChatTranscript()
      }
      if let runID = aiChatThreads.first(where: { $0.id == threadID })?.pendingTurn?.runID {
        clearAIChatPendingTurn(runID, in: threadID, shouldPersist: true)
      }
      removeAllPendingAIChatUserMessages(in: threadID)
      drainingAIChatThreadIDs.remove(threadID)
      activeAIChatUserMessageIDByThreadID.removeValue(forKey: threadID)
      aiChatRequestStartedAtByThreadID.removeValue(forKey: threadID)
    }
    syncSelectedAIChatSendState()
    if let threadID {
      aiChatScrollPositionsByThreadID.removeValue(forKey: threadID)
      aiChatAssistantChatScrollPositionsByThreadID.removeValue(forKey: threadID)
    }
    aiChatScrollPosition = nil
    aiChatAssistantChatScrollPosition = nil
    aiChatStatusText = aiChatIdleStatusText(destinationID: selectedAIChatThread?.destinationID)
  }

  /// Idle composer status for a chat routed to `destinationID`, named after
  /// that destination. Only the OpenClaw Gateway adapter reports gateway
  /// configuration; direct providers and Dots share its runtime family but
  /// not its endpoint.
  func aiChatIdleStatusText(destinationID: String?) -> String {
    let destination = destinationID.flatMap(aiChatDestination(id:)) ?? selectedAIChatDestination
    return Self.aiChatIdleStatusText(
      destination: destination,
      openClawSettings: destination.adapter == .openClaw ? currentOpenClawSettings() : nil
    )
  }

  nonisolated static func aiChatIdleStatusText(
    destination: AIChatDestinationConfiguration,
    openClawSettings: OpenClawGatewaySettings?
  ) -> String {
    if destination.adapter == .openClaw, let openClawSettings {
      return aiChatStatusText(settings: openClawSettings)
    }
    return "Ready for a \(destination.title) message"
  }

  public var selectedAIChatThread: AIChatThread? {
    guard let selectedAIChatThreadID else { return nil }
    return aiChatThreads.first(where: { $0.id == selectedAIChatThreadID })
  }

  /// A brand-new chat shows a project picker in the composer before its first
  /// message is sent.
  var showsNewThreadProjectPicker: Bool {
    AIChatNewThreadProjectPicker.isVisible(
      hasSelectedThread: selectedAIChatThread != nil,
      messageCount: aiChatMessages.count,
      isLoadingTranscript: isLoadingAIChatTranscript,
      projectCount: projectNotes.count
    )
  }

  public var settledAIChatThreads: [AIChatThread] {
    archivedAIChatThreads
  }

  public var sidebarAIChatThreads: [AIChatThread] {
    guard let promotedThread = sidebarPromotedAIChatThread else {
      return visibleAIChatThreads
    }
    return [promotedThread] + visibleAIChatThreads.filter { $0.id != promotedThread.id }
  }

  var sidebarAIChatThreadSummaries: [AIChatSidebarThreadSummary] {
    guard let promotedSummary = sidebarPromotedAIChatThreadSummary else {
      return visibleAIChatThreadSummaries
    }
    return [promotedSummary] + visibleAIChatThreadSummaries.filter {
      $0.id != promotedSummary.id
    }
  }

  public var sidebarSettledAIChatThreads: [AIChatThread] {
    guard let promotedThread = sidebarPromotedAIChatThread,
          promotedThread.isSettled
    else {
      return settledAIChatThreads
    }
    return settledAIChatThreads.filter { $0.id != promotedThread.id }
  }

  var sidebarSettledAIChatThreadSummaries: [AIChatSidebarThreadSummary] {
    guard let promotedSummary = sidebarPromotedAIChatThreadSummary,
          promotedSummary.isSettled
    else {
      return archivedAIChatThreadSummaries
    }
    return archivedAIChatThreadSummaries.filter { $0.id != promotedSummary.id }
  }

  private var sidebarPromotedAIChatThread: AIChatThread? {
    guard let sidebarPromotedAIChatThreadID,
          selectedAIChatThreadID == sidebarPromotedAIChatThreadID
    else {
      return nil
    }
    return aiChatThreads.first { $0.id == sidebarPromotedAIChatThreadID }
  }

  private var sidebarPromotedAIChatThreadSummary: AIChatSidebarThreadSummary? {
    guard let thread = sidebarPromotedAIChatThread else { return nil }
    return aiChatSidebarThreadSummary(for: thread)
  }

  func rebuildAIChatThreadDisplayCache() {
    aiChatFullDisplayRebuildCountForTesting &+= 1
    visibleAIChatThreads = Self.sortedAIChatThreadsForDisplay(
      aiChatThreads.filter { !$0.isSettled }
    )
    archivedAIChatThreads = Self.sortedAIChatThreadsForDisplay(
      aiChatThreads.filter(\.isSettled)
    )
    let liveThreadIDs = Set(aiChatThreads.map(\.id))
    aiChatVisibleMessageCountCache = aiChatVisibleMessageCountCache.filter {
      liveThreadIDs.contains($0.key)
    }
    visibleAIChatThreadSummaries = visibleAIChatThreads.map {
      aiChatSidebarThreadSummary(for: $0)
    }
    archivedAIChatThreadSummaries = archivedAIChatThreads.map {
      aiChatSidebarThreadSummary(for: $0)
    }
    aiChatUnreadMessageCount = aiChatThreads.reduce(0) { $0 + $1.unreadMessageCount }
  }

  /// Updates one thread's already-sorted projections without re-filtering,
  /// sorting, recounting, or comparing any other thread's message history.
  /// Selection/read and hydration mutations do not change ordering keys.
  private func replaceAIChatThreadIncrementally(
    at index: Int,
    with thread: AIChatThread,
    messageCount: Int? = nil
  ) {
    guard aiChatThreads.indices.contains(index) else { return }
    let previous = aiChatThreads[index]
    guard previous.id == thread.id,
          previous.isSettled == thread.isSettled,
          previous.isPinned == thread.isPinned,
          previous.updatedAt == thread.updatedAt
    else {
      aiChatThreads[index] = thread
      return
    }
    isApplyingIncrementalAIChatThreadMutation = true
    aiChatThreads[index] = thread
    isApplyingIncrementalAIChatThreadMutation = false

    let nextSummary = AIChatSidebarThreadSummary(
      thread: thread,
      messageCount: messageCount
    )
    if thread.isSettled {
      if let derivedIndex = archivedAIChatThreads.firstIndex(where: { $0.id == thread.id }) {
        archivedAIChatThreads[derivedIndex] = thread
      }
      if let summaryIndex = archivedAIChatThreadSummaries.firstIndex(where: {
        $0.id == thread.id
      }), archivedAIChatThreadSummaries[summaryIndex] != nextSummary {
        archivedAIChatThreadSummaries[summaryIndex] = nextSummary
      }
    } else {
      if let derivedIndex = visibleAIChatThreads.firstIndex(where: { $0.id == thread.id }) {
        visibleAIChatThreads[derivedIndex] = thread
      }
      if let summaryIndex = visibleAIChatThreadSummaries.firstIndex(where: {
        $0.id == thread.id
      }), visibleAIChatThreadSummaries[summaryIndex] != nextSummary {
        visibleAIChatThreadSummaries[summaryIndex] = nextSummary
      }
    }
    aiChatUnreadMessageCount = max(
      0,
      aiChatUnreadMessageCount - previous.unreadMessageCount + thread.unreadMessageCount
    )
  }

  /// Inserts a freshly created thread into the sorted sidebar projections and
  /// quick-open index without re-sorting or re-summarizing every existing
  /// thread. Creating a chat must stay instant on long chat histories.
  private func insertNewAIChatThreadIncrementally(_ thread: AIChatThread) {
    guard !aiChatThreads.contains(where: { $0.id == thread.id }) else {
      aiChatThreads.removeAll { $0.id == thread.id }
      aiChatThreads.insert(thread, at: 0)
      return
    }
    isApplyingIncrementalAIChatThreadMutation = true
    aiChatThreads.insert(thread, at: 0)
    isApplyingIncrementalAIChatThreadMutation = false

    func precedes(_ lhs: AIChatThread, _ rhs: AIChatThread) -> Bool {
      if lhs.isSettled != rhs.isSettled { return !lhs.isSettled }
      if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
      return lhs.updatedAt > rhs.updatedAt
    }
    let summary = aiChatSidebarThreadSummary(for: thread)
    if thread.isSettled {
      let index = archivedAIChatThreads.firstIndex(where: { !precedes($0, thread) })
        ?? archivedAIChatThreads.count
      archivedAIChatThreads.insert(thread, at: index)
      archivedAIChatThreadSummaries.insert(
        summary,
        at: min(index, archivedAIChatThreadSummaries.count)
      )
    } else {
      let index = visibleAIChatThreads.firstIndex(where: { !precedes($0, thread) })
        ?? visibleAIChatThreads.count
      visibleAIChatThreads.insert(thread, at: index)
      visibleAIChatThreadSummaries.insert(
        summary,
        at: min(index, visibleAIChatThreadSummaries.count)
      )
    }
    aiChatUnreadMessageCount += thread.unreadMessageCount

    quickOpenChatIndexSignature.insert(
      AIChatQuickOpenChatIndexSignature(id: thread.id, title: thread.title),
      at: 0
    )
    quickOpenIndexedChatThreads.insert(
      QuickOpenIndexedChatThread(
        id: thread.id,
        title: thread.title,
        normalizedTitle: Self.normalizedQuickOpenCandidate(thread.title)
      ),
      at: 0
    )
    var shiftedIndexes = quickOpenChatThreadIndexesByID.mapValues { $0 + 1 }
    shiftedIndexes[thread.id] = 0
    quickOpenChatThreadIndexesByID = shiftedIndexes
    if isQuickOpenPresented,
       !quickOpenQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      scheduleQuickOpenSearch(debounce: false)
    }
  }

  private func aiChatSidebarThreadSummary(
    for thread: AIChatThread
  ) -> AIChatSidebarThreadSummary {
    guard thread.isSharedRoom else {
      return AIChatSidebarThreadSummary(
        thread: thread,
        messageCount: thread.messageCount
      )
    }
    if thread.storedMessageCount != nil {
      return AIChatSidebarThreadSummary(
        thread: thread,
        messageCount: thread.messageCount
      )
    }
    let visibleMessageCount: Int
    if let cached = aiChatVisibleMessageCountCache[thread.id],
       cached.rawCount == thread.messages.count {
      visibleMessageCount = cached.visibleCount
    } else {
      visibleMessageCount = thread.messageCount
      aiChatVisibleMessageCountCache[thread.id] = (
        rawCount: thread.messages.count,
        visibleCount: visibleMessageCount
      )
    }
    return AIChatSidebarThreadSummary(
      thread: thread,
      messageCount: visibleMessageCount
    )
  }

  public var canUndoAIChatThreadArchive: Bool {
    guard let lastArchivedAIChatThreadID else { return false }
    return aiChatThreads.contains {
      $0.id == lastArchivedAIChatThreadID && $0.isSettled
    }
  }

  public var canOpenCanonicalAIChatResourceThread: Bool {
    currentAIChatResourceReference() != nil
  }

  public var hasCanonicalAIChatResourceThread: Bool {
    guard let resource = currentAIChatResourceReference() else { return false }
    return aiChatThreads.contains { $0.resource?.key == resource.key }
  }

  public func openCanonicalAIChatResourceThread() {
    guard let resource = currentAIChatResourceReference() else {
      statusText = "Add an ID to this heading before creating its resource thread"
      return
    }
    let pointer = aiChatContextPointerForCurrentSelection()

    if let thread = aiChatThreads.first(where: { $0.resource?.key == resource.key }) {
      if thread.isSettled {
        reopenAIChatThread(thread.id)
      }
      navigateToSurface(.aiChat)
      selectAIChatThread(thread.id)
      aiChatStatusText = "Opened resource thread for \(resource.title)"
      statusText = "Opened resource thread"
      return
    }

    let destination = selectedAIChatDestination
    let thread = createAIChatThread(
      title: "Resource: \(resource.title)",
      statusText: "New \(destination.title) resource thread",
      resource: resource,
      runtime: destination.runtime,
      destinationID: destination.id
    )
    if let pointer {
      addAIChatContext(pointer, threadMode: .currentThread)
    }
    navigateToSurface(.aiChat)
    selectAIChatThread(thread.id)
    aiChatStatusText = "Created resource thread for \(resource.title)"
    statusText = "Created resource thread"
  }

  @discardableResult
  public func createAIChatThread(runtime: AIChatRuntime) -> UUID {
    createAIChatThread(
      title: "New Chat",
      statusText: "New \(runtime.title) chat",
      runtime: runtime,
      defersPersistence: true
    ).id
  }

  @discardableResult
  public func createAIChatThread(destinationID: String) -> UUID {
    let destination = aiChatDestination(id: destinationID)
      ?? AIChatDestinationConfiguration.defaults.first(where: { $0.id == destinationID })
      ?? AIChatDestinationConfiguration.defaults[0]
    return createAIChatThread(
      title: "New Chat",
      statusText: "New \(destination.title) chat",
      runtime: destination.runtime,
      destinationID: destination.id,
      defersPersistence: true
    ).id
  }

  @discardableResult
  public func createAIChatRemoteThread(runtime: AIChatRuntime) -> UUID {
    let destinationID = enabledAIChatDestinations.first(where: { $0.runtime == runtime })?.id
      ?? AIChatDestinationConfiguration.defaultID(for: runtime)
    return createAIChatRemoteThread(destinationID: destinationID)
  }

  @discardableResult
  public func createAIChatRemoteThread(destinationID: String) -> UUID {
    createAIChatRemoteThread(destinationID: destinationID, id: UUID())
  }

  @discardableResult
  public func createAIChatRemoteThread(destinationID: String, id: UUID) -> UUID {
    if aiChatThreads.contains(where: { $0.id == id }) { return id }
    let destination = aiChatDestination(id: destinationID)
      ?? AIChatDestinationConfiguration.defaults[0]
    return createAIChatThread(
      id: id,
      title: "New Chat",
      statusText: "",
      runtime: destination.runtime,
      destinationID: destination.id,
      defersPersistence: true,
      selectsThread: false
    ).id
  }

  func createAIChatRemoteThread(
    destinationID: String,
    projectID: String,
    id: UUID = UUID()
  ) async -> UUID? {
    guard let project = await currentProject(id: projectID) else {
      projectStatus = "That project is no longer available."
      return nil
    }
    guard await updateProject(project, threadID: id) else { return nil }
    return createAIChatRemoteThread(destinationID: destinationID, id: id)
  }

  @discardableResult
  public func forkAIChatThread(
    _ id: UUID,
    selectsThread: Bool = true,
    asSharedRoom: Bool? = nil
  ) async -> UUID? {
    guard await hydrateAIChatThreadIfNeeded(id) != nil else { return nil }
    let linkedProjects = projectNotes.filter { $0.contains(id) }
    guard let forkedID = forkHydratedAIChatThread(
      id,
      selectsThread: selectsThread,
      asSharedRoom: asSharedRoom
    ) else { return nil }
    for project in linkedProjects {
      await updateProject(project, threadID: forkedID)
    }
    return forkedID
  }

  private func forkHydratedAIChatThread(
    _ id: UUID,
    selectsThread: Bool = true,
    asSharedRoom: Bool? = nil
  ) -> UUID? {
    guard !unloadedAIChatThreadIDs.contains(id),
          let source = aiChatThreads.first(where: { $0.id == id })
    else {
      return nil
    }
    let sharedRoom = asSharedRoom ?? source.isSharedRoom
    let now = Date()
    let forkedMessages = Self.forkedAIChatMessages(
      source.messages,
      sourceRuntime: source.runtime,
      preservesRoomMetadata: source.isSharedRoom
    )
    let titlePrefix = sharedRoom && !source.isSharedRoom ? "Shared" : "Fork"
    let roomModels: AIChatRoomModelSelection
    let roomModelsByDestination: [String: String]
    let roomReasoningEffortsByDestination: [String: String]
    let roomDestinationIDs: [String]
    let roomDefaultDestinationID: String?
    if source.isSharedRoom {
      roomModels = source.roomModels
      roomModelsByDestination = source.roomModelsByDestination
      roomReasoningEffortsByDestination = source.roomReasoningEffortsByDestination
      roomDestinationIDs = source.roomDestinationIDs
      roomDefaultDestinationID = source.roomDefaultDestinationID
    } else {
      roomModels = AIChatRoomModelSelection().replacingModel(source.model, for: source.runtime)
      roomModelsByDestination = source.model.map { [source.destinationID: $0] } ?? [:]
      roomReasoningEffortsByDestination = source.reasoningEffort.map { [source.destinationID: $0] } ?? [:]
      roomDestinationIDs = [source.destinationID]
      // Pinging another agent from a thread keeps the original agent as
      // the room's default; only that one message goes to the new agent.
      roomDefaultDestinationID = source.destinationID
    }
    let forked = AIChatThread(
      title: Self.normalizedAIChatThreadTitle("\(titlePrefix): \(source.title)"),
      createdAt: now,
      updatedAt: now,
      runtime: source.runtime,
      destinationID: source.destinationID,
      sessionKey: Self.makeOpenClawSessionKey(agentID: openClawAgentID),
      runtimeThreadID: nil,
      model: sharedRoom ? nil : source.model,
      reasoningEffort: sharedRoom ? nil : source.reasoningEffort,
      messages: forkedMessages,
      isPinned: false,
      isArchived: false,
      settledAt: nil,
      unreadMessageCount: 0,
      resource: nil,
      pendingTurn: nil,
      isSharedRoom: sharedRoom,
      roomAudience: .thread,
      roomModels: roomModels,
      roomDestinationIDs: roomDestinationIDs,
      roomModelsByDestination: roomModelsByDestination,
      roomReasoningEffortsByDestination: roomReasoningEffortsByDestination,
      roomDefaultDestinationID: roomDefaultDestinationID,
      roomAgentTurnLimit: source.isSharedRoom ? source.roomAgentTurnLimit : nil,
      agentRef: source.agentRef
    )
    aiChatThreads.insert(forked, at: 0)
    advanceAIChatMessageRevision(
      for: forked.id,
      tracksPersistence: true,
      makesColdPlaceholderAuthoritative: true
    )
    if selectsThread {
      selectAIChatThread(forked.id, persistsSelection: false)
      persistSelectedAIChatThread()
      aiChatStatusText = sharedRoom && !source.isSharedRoom
        ? "Forked into a shared room"
        : "Forked \(source.title)"
    }
    persistAIChatTranscript()
    return forked.id
  }

  nonisolated private static func forkedAIChatMessages(
    _ messages: [AIChatMessage],
    sourceRuntime: AIChatRuntime,
    preservesRoomMetadata: Bool
  ) -> [AIChatMessage] {
    var roundIDs: [UUID: UUID] = [:]
    return messages.map { message in
      let roomRoundID = message.roomRoundID.map { existing in
        if let mapped = roundIDs[existing] { return mapped }
        let mapped = UUID()
        roundIDs[existing] = mapped
        return mapped
      }
      return AIChatMessage(
        role: message.role,
        content: message.content,
        attachments: message.attachments,
        createdAt: message.createdAt,
        changeSummary: message.changeSummary,
        responseTrace: message.responseTrace,
        deliveryStatus: .sent,
        deliveryKind: .turn,
        authorRuntime: message.role == .user
          ? nil
          : (message.authorRuntime ?? sourceRuntime),
        authorLabel: message.authorLabel,
        authorAgentRef: message.authorAgentRef,
        source: message.source,
        audience: preservesRoomMetadata ? message.audience : nil,
        targetRuntime: preservesRoomMetadata ? message.targetRuntime : nil,
        authorDestinationID: message.authorDestinationID,
        audienceDestinationIDs: preservesRoomMetadata ? message.audienceDestinationIDs : [],
        targetDestinationID: preservesRoomMetadata ? message.targetDestinationID : nil,
        isRoomDispatchCopy: preservesRoomMetadata && message.isRoomDispatchCopy,
        roomRoundID: preservesRoomMetadata ? roomRoundID : nil,
        provenance: message.provenance
      )
    }
  }

  func aiChatDestinationThreadID(
    for text: String,
    sourceThreadID: UUID,
    selectsFork: Bool
  ) -> UUID {
    guard let source = aiChatThreads.first(where: { $0.id == sourceThreadID }),
          !source.isSharedRoom
    else {
      return sourceThreadID
    }
    let routing = AIChatDestinationRouting(
      text,
      destinations: enabledAIChatDestinations
    )
    guard routing.destinationIDs.contains(where: { $0 != source.destinationID }) else {
      return sourceThreadID
    }
    let forkedID = forkHydratedAIChatThread(
      sourceThreadID,
      selectsThread: selectsFork,
      asSharedRoom: true
    ) ?? sourceThreadID
    guard forkedID != sourceThreadID,
          let index = aiChatThreads.firstIndex(where: { $0.id == forkedID })
    else { return forkedID }
    let participants = ([source.destinationID] + routing.destinationIDs).reduce(into: [String]()) {
      if !$0.contains($1) { $0.append($1) }
    }
    aiChatThreads[index] = aiChatThreads[index]
      .replacingAIChatMetadata(roomDestinationIDs: participants)
    persistAIChatTranscript()
    return forkedID
  }

  @discardableResult
  func createAIChatThread(
    id: UUID = UUID(),
    title: String,
    statusText: String,
    resource: AIChatResourceReference? = nil,
    sessionKey: String? = nil,
    runtime requestedRuntime: AIChatRuntime? = nil,
    destinationID: String? = nil,
    isSharedRoom: Bool = false,
    roomAudience: AIChatAudience = .thread,
    inheritsChatConfiguration: Bool = true,
    modelOverride: String? = nil,
    reasoningEffortOverride: String? = nil,
    defersPersistence: Bool = false,
    selectsThread: Bool = true
  ) -> AIChatThread {
    // Without an explicit destination, a requested runtime picks its preferred
    // destination; otherwise the user's default destination answers. OpenClaw
    // is never an implicit fallback.
    let resolvedDestinationID = destinationID
      ?? requestedRuntime.map { runtime in
        enabledAIChatDestinations.first(where: {
          $0.id == AIChatDestinationConfiguration.defaultID(for: runtime)
        })?.id
          ?? enabledAIChatDestinations.first(where: { $0.runtime == runtime })?.id
          ?? AIChatDestinationConfiguration.defaultID(for: runtime)
      }
      ?? defaultAIChatDestination.id
    let runtime = requestedRuntime ?? aiChatDestinationRuntime(resolvedDestinationID)
    let lastConfiguration: AIChatLastConfiguration?
    if isSharedRoom {
      lastConfiguration = nil
    } else if inheritsChatConfiguration {
      lastConfiguration = preferredAIChatConfiguration(forDestinationID: resolvedDestinationID)
    } else {
      // Automations use configured destination defaults, not unrelated chat
      // choices that can silently require a live Gateway and prevent fallback.
      let model = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        ?? aiChatDestination(id: resolvedDestinationID)?.model
      let reasoningEffort = reasoningEffortOverride?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      lastConfiguration = model != nil || reasoningEffort != nil
        ? AIChatLastConfiguration(model: model, reasoningEffort: reasoningEffort)
        : nil
    }
    let initialRoomDestinationIDs = isSharedRoom
      ? enabledAIChatDestinations.map(\.id)
      : []
    let thread = AIChatThread(
      id: id,
      title: title,
      runtime: runtime,
      destinationID: resolvedDestinationID,
      sessionKey: sessionKey ?? Self.makeOpenClawSessionKey(agentID: openClawAgentID),
      model: lastConfiguration?.model,
      reasoningEffort: lastConfiguration?.reasoningEffort,
      resource: resource,
      isSharedRoom: isSharedRoom,
      roomAudience: roomAudience,
      roomDestinationIDs: initialRoomDestinationIDs
    )
    insertNewAIChatThreadIncrementally(thread)
    advanceAIChatMessageRevision(
      for: thread.id,
      tracksPersistence: true,
      makesColdPlaceholderAuthoritative: true
    )
    if selectsThread {
      selectAIChatThread(thread.id, persistsSelection: false)
      persistSelectedAIChatThread()
    }
    if defersPersistence {
      scheduleAIChatTranscriptPersistenceAfterInteraction()
    } else {
      persistAIChatTranscript()
    }
    if selectsThread {
      aiChatStatusText = statusText
    }
    return thread
  }

  func prepareAIChatThread(mode: AIChatThreadMode, title: String, statusText: String) {
    guard mode == .newThread else {
      ensureAIChatThread()
      return
    }
    let destination = selectedAIChatDestination
    createAIChatThread(
      title: Self.normalizedAIChatThreadTitle(title),
      statusText: statusText.hasPrefix("New ")
        ? "New \(destination.title) " + statusText.dropFirst("New ".count)
        : statusText,
      runtime: destination.runtime,
      destinationID: destination.id
    )
  }

  /// A chosen brief harness, model, or reasoning level cannot retarget an
  /// existing conversation, so it always gets its own brief thread.
  public var nodeBriefStartsNewThread: Bool {
    aiChatBriefsStartNewThread || !nodeBriefConfiguration.isDefault
  }

  /// Destination the next brief will run on, after validating the saved one.
  public var nodeBriefDestination: AIChatDestinationConfiguration {
    if let id = nodeBriefConfiguration.destinationID,
       let destination = enabledAIChatDestinations.first(where: { $0.id == id }) {
      return destination
    }
    return selectedAIChatDestination
  }

  /// Models for the brief options picker: cached catalog first, then a live
  /// lookup against the destination. Failures return an empty list so the
  /// user can still type a model ID.
  public func nodeBriefModelOptions(forDestinationID destinationID: String) async -> [AIChatModelOption] {
    if let cached = aiChatConfigurationCatalogCache[destinationID]?.models, !cached.isEmpty {
      return cached
    }
    guard let models = try? await modelsForAIChatDestination(destinationID), !models.isEmpty else {
      return []
    }
    cacheAIChatModelCatalog(destinationID: destinationID, models: models)
    return models
  }

  func prepareAIChatThreadForNodeBrief(title: String) {
    guard nodeBriefStartsNewThread else { return }
    let configuration = nodeBriefConfiguration
    if !configuration.isDefault {
      let destination = nodeBriefDestination
      createAIChatThread(
        title: Self.normalizedAIChatThreadTitle("Brief: \(title)"),
        statusText: "New \(destination.title) brief chat",
        runtime: destination.runtime,
        destinationID: destination.id,
        inheritsChatConfiguration: configuration.model == nil && configuration.reasoningEffort == nil,
        modelOverride: configuration.model,
        reasoningEffortOverride: configuration.reasoningEffort
      )
      return
    }
    prepareAIChatThread(
      mode: .newThread,
      title: "Brief: \(title)",
      statusText: "New brief chat"
    )
  }

  public func selectAIChatThread(_ id: UUID) {
    guard aiChatThreads.contains(where: { $0.id == id }) else { return }
    sidebarPromotedAIChatThreadID = nil
    if selectedAIChatThreadID != id {
      recordCurrentNavigationDestination()
    }
    selectAIChatThread(id, persistsSelection: true)
  }

  /// Title of an existing chat thread, for rendering a pasted thread ID as a
  /// link. Unknown IDs return nil and stay plain text.
  public func aiChatThreadLinkTitle(_ id: UUID) -> String? {
    guard let thread = aiChatThreads.first(where: { $0.id == id }) else { return nil }
    let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled chat" : title
  }

  public func openAIChatThreadLink(_ id: UUID) {
    guard aiChatThreads.contains(where: { $0.id == id }) else {
      statusText = "That chat thread is not available on this Mac"
      return
    }
    navigateToSurface(.aiChat)
    selectAIChatThread(id)
  }

  public func selectAIChatSearchResult(_ result: AIChatSearchResult) {
    navigateToSurface(.aiChat)
    selectAIChatThread(result.threadID)
    sidebarPromotedAIChatThreadID = result.threadID
    statusText = "Opened chat thread"
  }

  public func toggleAIChatThreadPin(_ id: UUID) {
    guard let index = aiChatThreads.firstIndex(where: { $0.id == id }) else { return }
    let thread = aiChatThreads[index]
    aiChatThreads[index] = thread.replacingAIChatMetadata(isPinned: !thread.isPinned)
    sortAIChatThreadsForDisplay()
    persistAIChatTranscript()
  }

  public func renameAIChatThread(_ id: UUID, title rawTitle: String) {
    let title = Self.normalizedAIChatThreadTitle(rawTitle)
    guard !title.isEmpty,
          let index = aiChatThreads.firstIndex(where: { $0.id == id })
    else { return }
    let thread = aiChatThreads[index]
    guard thread.title != title else { return }
    aiChatThreads[index] = thread.replacingAIChatMetadata(title: title)
    sortAIChatThreadsForDisplay()
    persistAIChatTranscript()
  }

  /// Whether the open conversation is settled. Drives the chat header's
  /// Settle/Reopen control, which works even when the thread is hard to find
  /// in the sidebar.
  public var selectedAIChatThreadIsSettled: Bool {
    selectedAIChatThread?.isSettled ?? false
  }

  /// Settles or reopens the open conversation from the chat pane. Settling
  /// from the pane keeps the thread open, so the control flips to Reopen
  /// instead of moving to (and risking a second click on) another thread.
  public func toggleSelectedAIChatThreadSettlement(at date: Date = Date()) {
    guard let thread = selectedAIChatThread else { return }
    if thread.isSettled {
      reopenAIChatThread(thread.id)
      aiChatStatusText = "Reopened \(thread.title)"
    } else {
      settleAIChatThread(thread.id, at: date, keepsSelection: true)
      aiChatStatusText = "Settled \(thread.title)"
    }
  }

  public func settleAIChatThread(_ id: UUID, at settledAt: Date = Date(), keepsSelection: Bool = false) {
    let visibleThreadsBeforeArchive = visibleAIChatThreads
    let visibleIndex = visibleThreadsBeforeArchive.firstIndex(where: { $0.id == id })
    let selectedThreadWasSettled = selectedAIChatThreadID.flatMap { selectedID in
      aiChatThreads.first(where: { $0.id == selectedID })?.isSettled
    } ?? false
    guard let index = aiChatThreads.firstIndex(where: { $0.id == id }),
          !aiChatThreads[index].isSettled
    else { return }
    let thread = aiChatThreads[index]
    var threads = aiChatThreads
    threads[index] = thread.replacingAIChatMetadata(
      isArchived: true,
      settledAt: .some(settledAt)
    )
    aiChatThreads = Self.sortedAIChatThreadsForDisplay(threads)
    lastArchivedAIChatThreadID = id
    scheduleAIChatTranscriptPersistenceAfterInteraction()

    if keepsSelection, selectedAIChatThreadID == id { return }
    if selectedAIChatThreadID == id || selectedThreadWasSettled {
      let remainingThreads = visibleAIChatThreads
      let replacementIndex = min(visibleIndex ?? 0, max(remainingThreads.count - 1, 0))
      if remainingThreads.indices.contains(replacementIndex) {
        let next = remainingThreads[replacementIndex]
        selectAIChatThread(next.id, persistsSelection: true)
      } else {
        createAIChatThread(destinationID: thread.destinationID)
      }
    }
  }

  nonisolated static func isAutomationAIChatThreadTitle(_ title: String) -> Bool {
    title.hasPrefix("Automation:")
  }

  /// Automation threads that "Mark All Automation Threads Read & Settled"
  /// would still change: unsettled ones that are not running, plus any with
  /// unread messages. The sidebar shows its inline settle-all row from this.
  public var actionableAutomationAIChatThreadCount: Int {
    aiChatThreads.reduce(into: 0) { count, thread in
      guard Self.isAutomationAIChatThreadTitle(thread.title) else { return }
      let isRunning = thread.pendingTurn != nil
        || aiChatSendingThreadIDs.contains(thread.id)
        || drainingAIChatThreadIDs.contains(thread.id)
      if (!thread.isSettled && !isRunning) || thread.unreadMessageCount != 0 {
        count += 1
      }
    }
  }

  /// Marks every "Automation: …" thread read and settles those not running,
  /// as one in-memory update with a single receipt write and one debounced
  /// transcript save, regardless of how many threads match.
  @discardableResult
  public func markAllAutomationAIChatThreadsReadAndSettled(at settledAt: Date = Date()) -> Int {
    var threads = aiChatThreads
    var automationThreads: [AIChatThread] = []
    var changedCount = 0
    for index in threads.indices {
      let thread = threads[index]
      guard Self.isAutomationAIChatThreadTitle(thread.title) else { continue }
      automationThreads.append(thread)
      let isRunning = thread.pendingTurn != nil
        || aiChatSendingThreadIDs.contains(thread.id)
        || drainingAIChatThreadIDs.contains(thread.id)
      let settles = !thread.isSettled && !isRunning
      guard settles || thread.unreadMessageCount != 0 else { continue }
      threads[index] = thread.replacingAIChatMetadata(
        isArchived: settles ? true : thread.isArchived,
        settledAt: .some(settles ? settledAt : thread.settledAt),
        unreadMessageCount: 0
      )
      changedCount += 1
    }
    aiChatReadState.markRead(automationThreads, transcriptURL: aiChatTranscriptURL)
    guard changedCount > 0 else {
      aiChatStatusText = automationThreads.isEmpty
        ? "No automation threads"
        : "Automation threads are already read and settled"
      return 0
    }
    aiChatThreads = Self.sortedAIChatThreadsForDisplay(threads)
    scheduleAIChatTranscriptPersistenceAfterInteraction()
    aiChatStatusText = changedCount == 1
      ? "Marked 1 automation thread read and settled"
      : "Marked \(changedCount) automation threads read and settled"
    return changedCount
  }

  public func reopenAIChatThread(_ id: UUID) {
    guard let index = aiChatThreads.firstIndex(where: { $0.id == id }),
          aiChatThreads[index].isSettled
    else { return }
    let thread = aiChatThreads[index]
    var threads = aiChatThreads
    threads[index] = thread.replacingAIChatMetadata(
      isArchived: false,
      settledAt: .some(nil)
    )
    aiChatThreads = Self.sortedAIChatThreadsForDisplay(threads)
    if lastArchivedAIChatThreadID == id {
      lastArchivedAIChatThreadID = nil
    }
    scheduleAIChatTranscriptPersistenceAfterInteraction()
  }

  public func undoLastAIChatThreadArchive() {
    guard let lastArchivedAIChatThreadID else { return }
    reopenAIChatThread(lastArchivedAIChatThreadID)
  }

  public func archiveAIChatThread(_ id: UUID) {
    settleAIChatThread(id)
  }

  public func restoreAIChatThread(_ id: UUID) {
    reopenAIChatThread(id)
  }

  public func setAIChatAutoSettleInterval(_ interval: AIChatAutoSettleInterval) {
    aiChatThreadSettlementSettings = AIChatThreadSettlementSettings(
      autoSettleAfterSeconds: interval.seconds
    )
    autoSettleAIChatThreads(shouldPersist: false)
    persistAIChatTranscript()
  }

  @discardableResult
  public func autoSettleAIChatThreads(
    now: Date = Date(),
    shouldPersist: Bool = true
  ) -> [UUID] {
    let selectedID = selectedAIChatThreadID
    var settledIDs: [UUID] = []
    let updatedThreads = aiChatThreads.map { thread in
      guard Self.canAutoSettleAIChatThread(
        thread,
        settings: aiChatThreadSettlementSettings,
        selectedThreadID: selectedID,
        now: now
      ) else {
        return thread
      }
      settledIDs.append(thread.id)
      return thread.replacingAIChatMetadata(
        isArchived: true,
        settledAt: .some(now)
      )
    }
    if !settledIDs.isEmpty {
      aiChatThreads = Self.sortedAIChatThreadsForDisplay(updatedThreads)
      if shouldPersist {
        scheduleAIChatTranscriptPersistenceAfterInteraction()
      }
    }
    return settledIDs
  }

  nonisolated static func canAutoSettleAIChatThread(
    _ thread: AIChatThread,
    settings: AIChatThreadSettlementSettings,
    selectedThreadID: UUID?,
    now: Date
  ) -> Bool {
    guard let interval = settings.autoSettleAfterSeconds,
          interval > 0,
          !thread.isSettled,
          thread.id != selectedThreadID,
          !thread.isPinned,
          thread.pendingTurn == nil,
          thread.unreadMessageCount == 0,
          !thread.hasUnresolvedLatestDelivery,
          thread.updatedAt <= now.addingTimeInterval(-interval)
    else {
      return false
    }
    return true
  }

  func selectAIChatThread(_ id: UUID, persistsSelection: Bool) {
    guard let thread = aiChatThreads.first(where: { $0.id == id }) else {
      return
    }
    if let previousID = selectedAIChatThreadID, previousID != id {
      commitPendingAIChatHydration(for: previousID)
    }
    let requiresHydration = unloadedAIChatThreadIDs.contains(thread.id)
    let selectionChanged = selectedAIChatThreadID != thread.id
    saveAIChatComposerForSelectedThread()
    if selectionChanged {
      selectedAIChatThreadID = thread.id
    }
    touchHydratedAIChatThread(thread.id)
    openClawSessionKey = thread.sessionKey
    // Refreshing a hidden selection is not an acknowledgement of its replies.
    if persistsSelection || selectedSurface == .aiChat || isAIChatAssistantPresented {
      markAIChatThreadRead(thread.id)
    }
    restoreAIChatComposer(for: thread.id)
    syncSelectedAIChatSendState()
    aiChatConfigurationGeneration &+= 1
    if !applyCachedAIChatConfiguration(for: thread) {
      if !aiChatModelOptions.isEmpty { aiChatModelOptions = [] }
      if !aiChatReasoningOptions.isEmpty { aiChatReasoningOptions = [] }
      if aiChatEffectiveModel != nil { aiChatEffectiveModel = nil }
      if aiChatDefaultReasoningEffort != nil { aiChatDefaultReasoningEffort = nil }
    }
    let nextStatus = requiresHydration
      ? "Loading conversation…"
      : isSendingAIChatMessage
        ? "\(aiChatDestinationTitle(thread.destinationID)) is working"
        : aiChatIdleStatusText(destinationID: thread.destinationID)
    if aiChatStatusText != nextStatus { aiChatStatusText = nextStatus }
    aiChatScrollPosition = aiChatScrollPositionsByThreadID[thread.id]
    aiChatAssistantChatScrollPosition = aiChatAssistantChatScrollPositionsByThreadID[thread.id]
    let messageIdentity = aiChatMessagesIdentity(for: thread.id)
    if publishedAIChatMessagesIdentity != messageIdentity {
      replaceAIChatMessages(thread.messages, shouldPersist: false)
      publishedAIChatMessagesIdentity = messageIdentity
    }
    // Publish the completion token only after the ID, messages, draft, send
    // state, configuration, and per-thread scroll snapshot are coherent.
    if selectionChanged { aiChatSelectionGeneration &+= 1 }
    if requiresHydration {
      hydrateAIChatThread(thread.id)
    } else {
      enforceHydratedAIChatThreadLimit()
    }
    if persistsSelection {
      persistSelectedAIChatThread()
    }
  }

  nonisolated static func prepareInitialAIChatMessagePresentations(
    messages: [AIChatMessage],
    isSharedRoom: Bool
  ) -> [AIChatPreparedMessagePresentation] {
    prepareInitialAIChatMessagePresentations(
      inputs: initialAIChatMessagePresentationInputs(
        messages: messages,
        isSharedRoom: isSharedRoom
      )
    )
  }

  nonisolated private static func initialAIChatMessagePresentationInputs(
    messages: [AIChatMessage],
    isSharedRoom: Bool
  ) -> [AIChatMessagePresentationInput] {
    let window = AIChatTranscriptWindow(
      messages: messages,
      isSharedRoom: isSharedRoom,
      displayLimit: AIChatTranscriptWindow.initialLimit
    )
    var seenMessageIDs = Set<UUID>()
    var inputs: [AIChatMessagePresentationInput] = []
    inputs.reserveCapacity(window.visibleChatBubbleCount)
    for message in window.visibleMessagesForPresentation {
      guard !Task.isCancelled else { return [] }
      guard seenMessageIDs.insert(message.id).inserted else { continue }
      // Project before any preparation so this task never carries attachment
      // values (including legacy inline Data) into the presentation cache.
      inputs.append(AIChatMessagePresentationInput(message))
    }
    return inputs
  }

  nonisolated static func prepareInitialAIChatMessagePresentations(
    inputs: [AIChatMessagePresentationInput]
  ) -> [AIChatPreparedMessagePresentation] {
    var prepared: [AIChatPreparedMessagePresentation] = []
    prepared.reserveCapacity(inputs.count)
    for input in inputs {
      guard !Task.isCancelled else { return [] }
      prepared.append(AIChatMessagePresentationBuilder.prepare(input))
    }
    return prepared
  }

  func hydrateAIChatThread(_ id: UUID) {
    guard unloadedAIChatThreadIDs.contains(id),
          aiChatThreadHydrationTasks[id] == nil,
          let metadata = aiChatThreads.first(where: { $0.id == id })
    else { return }
    let transcriptURL = aiChatTranscriptURL.standardizedFileURL
    let transcriptGeneration = aiChatTranscriptLoadGeneration
    let mutationVersion = aiChatThreadMessageMutationVersions[id, default: 0]
    let delay = aiChatThreadHydrationDelayNanosecondsForTesting
    let token = UUID()
    aiChatThreadHydrationTaskTokens[id] = token
    let task = Task { @MainActor [weak self] in
      guard !Task.isCancelled else { return }
      let loaded = await Task.detached(priority: .userInitiated) {
        AIChatTranscriptStore.shared.loadThread(
          id: id,
          metadata: metadata,
          legacyURL: transcriptURL
        )
      }.value
      self?.aiChatThreadHydrationDidLoadForTesting?(id)
      if delay > 0 {
        do {
          try await Task.sleep(nanoseconds: delay)
        } catch {
          return
        }
      }
      guard let self,
            !Task.isCancelled,
            self.aiChatThreadHydrationTaskTokens[id] == token
      else { return }
      defer {
        if self.aiChatThreadHydrationTaskTokens[id] == token {
          self.aiChatThreadHydrationTaskTokens.removeValue(forKey: id)
          self.aiChatThreadHydrationTasks.removeValue(forKey: id)
        }
      }
      guard self.aiChatTranscriptLoadGeneration == transcriptGeneration,
            self.aiChatTranscriptURL.standardizedFileURL.path == transcriptURL.path,
            self.aiChatThreadMessageMutationVersions[id, default: 0] == mutationVersion,
            self.unloadedAIChatThreadIDs.contains(id)
      else { return }
      guard let loaded,
            let index = self.aiChatThreads.firstIndex(where: { $0.id == id })
      else {
        self.errorText = "AI chat conversation \(metadata.title) could not be loaded from storage."
        if self.selectedAIChatThreadID == id {
          self.aiChatStatusText = "Conversation unavailable"
        }
        return
      }
      let hydrated = self.aiChatThreads[index].hydrating(
        messages: Self.settlingAnsweredOpenCodeRemoteTurns(in: [loaded]).threads[0].messages
      )
      AIChatTranscriptStore.shared.recordAdoptedThreads([hydrated], legacyURL: transcriptURL)
      self.unloadedAIChatThreadIDs.remove(id)
      let cachedMessageCount = (hydrated.isSettled
        ? self.archivedAIChatThreadSummaries
        : self.visibleAIChatThreadSummaries)
        .first(where: { $0.id == id })?.messageCount
      self.advanceAIChatMessageRevision(
        for: id,
        tracksPersistence: false,
        makesColdPlaceholderAuthoritative: false
      )
      let publishesSelectedThread = self.selectedAIChatThreadID == id
      if publishesSelectedThread {
        self.replaceAIChatMessages(hydrated.messages, shouldPersist: false)
        self.syncSelectedAIChatSendState()
        self.aiChatStatusText = self.isSendingAIChatMessage
          ? "\(self.aiChatDestinationTitle(hydrated.destinationID)) is working"
          : self.aiChatIdleStatusText(destinationID: hydrated.destinationID)
      }
      if publishesSelectedThread,
         self.selectedSurface == .aiChat || self.isAIChatAssistantPresented {
        // The selected messages are sufficient to update the transcript. Defer
        // mutating the 500+ item observed thread collection until WebKit has
        // acknowledged that DOM update, so sidebar bookkeeping cannot compete
        // with the first visible frame.
        self.deferAIChatHydrationCommit(
          PendingAIChatHydrationCommit(
            thread: hydrated,
            messageCount: cachedMessageCount,
            transcriptPath: transcriptURL.path,
            transcriptGeneration: transcriptGeneration,
            mutationVersion: mutationVersion
          )
        )
      } else {
        self.replaceAIChatThreadIncrementally(
          at: index,
          with: hydrated,
          messageCount: cachedMessageCount
        )
        self.enforceHydratedAIChatThreadLimit()
      }
      // Cold threads skip launch-time interruption repair; apply it now that
      // their messages are loaded.
      self.repairStaleLocalAIChatSends(in: id, transcriptURL: transcriptURL)
      // Presentation enrichment is not required for a readable transcript:
      // AIChatTranscriptDocument immediately publishes a safe plain excerpt.
      // Warm the structured cache only after that first frame can be drawn.
      let presentationInputs = Self.initialAIChatMessagePresentationInputs(
        messages: loaded.messages,
        isSharedRoom: loaded.isSharedRoom
      )
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        let presentations = await Task.detached(priority: .utility) {
          Self.prepareInitialAIChatMessagePresentations(
            inputs: presentationInputs
          )
        }.value
        AIChatMessagePresentationCache.install(presentations)
      }
    }
    aiChatThreadHydrationTasks[id] = task
  }

  /// Persists launch-time interruption of this host's stale sends. The
  /// loader marks them in memory only, so a later replica refresh would
  /// otherwise bring back a turn that looks busy but has no driver.
  func persistStaleLocalAIChatSendRepair(_ threadIDs: Set<UUID>) {
    guard !threadIDs.isEmpty,
          hasAuthoritativeAIChatTranscriptState,
          !aiChatTranscriptWritesBlocked
    else { return }
    let transcriptURL = aiChatTranscriptURL.standardizedFileURL
    for threadID in threadIDs
    where !unloadedAIChatThreadIDs.contains(threadID)
      && !isAIChatThreadRunningOnCurrentHost(threadID) {
      guard aiChatThread(threadID, transcriptURL: transcriptURL) != nil else { continue }
      updateAIChatThread(
        threadID,
        messages: aiChatMessages(for: threadID, transcriptURL: transcriptURL),
        transcriptURL: transcriptURL,
        shouldPersist: true
      )
    }
  }

  /// Marks this host's sends from an earlier OpenOrg process as interrupted
  /// when nothing in this process drives or recovers them. Otherwise the chat
  /// looks busy forever while Stop and Retry have nothing to act on.
  func repairStaleLocalAIChatSends(in threadID: UUID, transcriptURL: URL) {
    guard !unloadedAIChatThreadIDs.contains(threadID),
          !isAIChatThreadRunningOnCurrentHost(threadID),
          let thread = aiChatThread(threadID, transcriptURL: transcriptURL)
    else { return }
    let messages = aiChatMessages(for: threadID, transcriptURL: transcriptURL)
    let repaired = Self.interruptStaleLocalAIChatSends(
      in: [thread.replacingMessages(messages)],
      processStartedAt: aiChatProcessStartedAt
    )
    guard repaired.changed, let repairedThread = repaired.threads.first else { return }
    updateAIChatThread(
      threadID,
      messages: repairedThread.messages,
      transcriptURL: transcriptURL,
      shouldPersist: true
    )
    dequeueInterruptedAIChatSends(in: repairedThread)
  }

  /// Drops interrupted sends from the in-memory dispatch queue.
  func dequeueInterruptedAIChatSends(in thread: AIChatThread) {
    for message in thread.messages
    where message.role == .user && message.deliveryStatus == .interrupted {
      aiChatForeignPendingMessageIDs.remove(message.id)
      if aiChatPendingUserMessageIDs(for: thread.id).contains(message.id) {
        removePendingAIChatUserMessage(message.id, in: thread.id)
      }
    }
    if selectedAIChatThreadID == thread.id {
      restoreInterruptedAIChatSendStatusIfNeeded()
    }
  }

  /// Interrupts sends that this host accepted before `processStartedAt`.
  /// Unlike the launch loader, this runs on synchronized replicas too, so it
  /// requires explicit local provenance. Threads with a recoverable pending
  /// turn are left for turn recovery.
  /// Metadata-only (cold) threads are skipped until their messages load.
  nonisolated static func interruptStaleLocalAIChatSends(
    in threads: [AIChatThread],
    processStartedAt: Date,
    isLocalHost: (String) -> Bool = { AIChatLocalHostRegistry.shared.isLocal($0) }
  ) -> (threads: [AIChatThread], changed: Bool) {
    var changed = false
    let repaired = threads.map { thread -> AIChatThread in
      guard thread.storedMessageCount == nil else { return thread }
      if let pendingTurn = thread.pendingTurn,
         thread.messages.contains(where: {
           $0.id == pendingTurn.userMessageID && $0.role == .user && $0.deliveryStatus == .sending
         }) {
        return thread
      }
      var threadChanged = false
      let messages = thread.messages.map { message -> AIChatMessage in
        guard message.role == .user,
              message.deliveryStatus == .sending,
              message.deliveryKind != .steer,
              (message.provenance?.acceptedAt ?? message.createdAt) < processStartedAt
        else { return message }
        // Only a turn this host explicitly accepted is known to be stale. A
        // replica's unattributed send may be another host's live turn, and a
        // hand-off nobody has started is still waiting for its host.
        guard let provenance = message.provenance,
              let executionHostRef = provenance.executionHostRef,
              provenance.acceptedAt != nil,
              isLocalHost(executionHostRef)
        else { return message }
        threadChanged = true
        if message.deliveryIsUnconfirmed {
          return message.replacingDeliveryAttempt(
            message.deliveryAttemptID ?? message.id,
            status: .sending,
            sendFailure: aiChatUnknownSendFailureText,
            attemptState: .unconfirmed
          )
        }
        return message.replacingDeliveryStatus(
          .interrupted,
          sendFailure: aiChatInterruptedSendFailureText
        )
      }
      guard threadChanged else { return thread }
      changed = true
      return thread.replacingMessages(messages)
    }
    return (repaired, changed)
  }

  func hydrateAIChatThreadIfNeeded(_ id: UUID) async -> AIChatThread? {
    guard aiChatThreads.contains(where: { $0.id == id }) else { return nil }
    if unloadedAIChatThreadIDs.contains(id) {
      hydrateAIChatThread(id)
      if let task = aiChatThreadHydrationTasks[id] { await task.value }
    }
    guard !unloadedAIChatThreadIDs.contains(id) else { return nil }
    return pendingAIChatHydrationCommits[id]?.thread
      ?? aiChatThreads.first(where: { $0.id == id })
  }

  private func deferAIChatHydrationCommit(_ commit: PendingAIChatHydrationCommit) {
    let id = commit.thread.id
    pendingAIChatHydrationCommitTasks.removeValue(forKey: id)?.cancel()
    pendingAIChatHydrationCommits[id] = commit
    pendingAIChatHydrationCommitTasks[id] = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(500))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.commitPendingAIChatHydration(for: id)
    }
  }

  private func commitPendingAIChatHydration(for id: UUID) {
    guard let commit = pendingAIChatHydrationCommits.removeValue(forKey: id) else {
      return
    }
    pendingAIChatHydrationCommitTasks.removeValue(forKey: id)?.cancel()
    guard aiChatTranscriptLoadGeneration == commit.transcriptGeneration,
          aiChatTranscriptURL.standardizedFileURL.path == commit.transcriptPath,
          aiChatThreadMessageMutationVersions[id, default: 0] == commit.mutationVersion,
          let index = aiChatThreads.firstIndex(where: { $0.id == id })
    else { return }
    replaceAIChatThreadIncrementally(
      at: index,
      with: commit.thread,
      messageCount: commit.messageCount
    )
    enforceHydratedAIChatThreadLimit()
  }

  func discardPendingAIChatHydrationCommit(for id: UUID) {
    pendingAIChatHydrationCommits.removeValue(forKey: id)
    pendingAIChatHydrationCommitTasks.removeValue(forKey: id)?.cancel()
  }

  /// Returns a complete thread for detail projections without moving file IO
  /// onto the main actor. Metadata-only chat records remain useful for lists,
  /// while callers that expose message history must cross this async boundary.
  public func hydratedAIChatThreadForDetail(_ id: UUID) async -> AIChatThread? {
    await hydrateAIChatThreadIfNeeded(id)
  }

  public func cacheAIChatComposerDraft(_ draft: String) {
    guard let selectedAIChatThreadID else { return }
    cacheAIChatDraft(draft, for: selectedAIChatThreadID)
  }

  public func publishAIChatComposerDraft(_ draft: String) {
    cacheAIChatComposerDraft(draft)
    guard aiChatDraft != draft else { return }
    aiChatDraft = draft
  }

  func saveAIChatComposerForSelectedThread() {
    guard let selectedAIChatThreadID else { return }
    let key = aiChatComposerKey(for: selectedAIChatThreadID)
    // The SwiftUI composer caches its local draft independently from
    // attachments. Treating either component as proof that both were cached
    // can discard a draft when an attachment is added before navigation (or
    // discard attachments after only the draft was cached).
    if !aiChatDraftCachedKeys.contains(key) {
      cacheAIChatDraft(aiChatDraft, for: selectedAIChatThreadID)
    }
    if !aiChatAttachmentCachedKeys.contains(key) {
      cacheAIChatAttachments(aiChatPendingAttachments, for: selectedAIChatThreadID)
    }
  }

  func currentAIChatDraftForSelectedThread() -> String {
    guard let selectedAIChatThreadID else { return aiChatDraft }
    let key = aiChatComposerKey(for: selectedAIChatThreadID)
    guard aiChatDraftCachedKeys.contains(key) else { return aiChatDraft }
    return aiChatDraftsByComposerKey[key] ?? ""
  }

  func aiChatDraft(
    for threadID: UUID,
    context: AIChatCorpusContextToken? = nil
  ) -> String {
    let key = aiChatComposerKey(for: threadID, context: context)
    if context == nil, selectedAIChatThreadID == threadID {
      return currentAIChatDraftForSelectedThread()
    }
    return aiChatDraftsByComposerKey[key] ?? ""
  }

  func cacheAIChatDraft(
    _ draft: String,
    for threadID: UUID,
    context: AIChatCorpusContextToken? = nil
  ) {
    let key = aiChatComposerKey(for: threadID, context: context)
    aiChatDraftCachedKeys.insert(key)
    let normalizedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? ""
      : draft
    if normalizedDraft.isEmpty {
      aiChatDraftsByComposerKey.removeValue(forKey: key)
    } else {
      aiChatDraftsByComposerKey[key] = normalizedDraft
    }
  }

  func cacheAIChatAttachments(
    _ attachments: [AIChatAttachment],
    for threadID: UUID,
    context: AIChatCorpusContextToken? = nil
  ) {
    let key = aiChatComposerKey(for: threadID, context: context)
    aiChatAttachmentCachedKeys.insert(key)
    if attachments.isEmpty {
      aiChatAttachmentsByComposerKey.removeValue(forKey: key)
    } else {
      aiChatAttachmentsByComposerKey[key] = attachments
    }
  }

  func restoreAIChatComposer(for threadID: UUID) {
    let key = aiChatComposerKey(for: threadID)
    aiChatDraft = aiChatDraftsByComposerKey[key] ?? ""
    aiChatPendingAttachments = aiChatAttachmentsByComposerKey[key] ?? []
  }

  func clearAIChatDraftForSelectedThread() {
    if let selectedAIChatThreadID {
      let key = aiChatComposerKey(for: selectedAIChatThreadID)
      aiChatDraftsByComposerKey.removeValue(forKey: key)
      aiChatDraftCachedKeys.insert(key)
    }
    aiChatDraft = ""
  }

  private func clearAIChatDraft(
    for threadID: UUID,
    context: AIChatCorpusContextToken? = nil
  ) {
    let key = aiChatComposerKey(for: threadID, context: context)
    aiChatDraftsByComposerKey.removeValue(forKey: key)
    aiChatDraftCachedKeys.insert(key)
    if context == nil, selectedAIChatThreadID == threadID {
      aiChatDraft = ""
    }
  }

  func ensureAIChatThread() {
    if let selectedAIChatThreadID,
       aiChatThreads.contains(where: { $0.id == selectedAIChatThreadID }) {
      return
    }
    // Legacy single-transcript migration: loose messages predate threads and
    // belong to the original OpenClaw Gateway session they were sent through.
    let thread = AIChatThread(
      title: Self.aiChatThreadTitle(from: aiChatMessages),
      sessionKey: openClawSessionKey,
      messages: aiChatMessages
    )
    aiChatThreads.insert(thread, at: 0)
    advanceAIChatMessageRevision(
      for: thread.id,
      tracksPersistence: true,
      makesColdPlaceholderAuthoritative: true
    )
    selectedAIChatThreadID = thread.id
  }

  public func markSelectedAIChatThreadRead() {
    guard let selectedAIChatThreadID else { return }
    markAIChatThreadRead(selectedAIChatThreadID)
  }

  public func previewAIChatMessageSound() {
    guard aiChatMessageSound != .off else { return }
    aiChatIncomingMessageSoundPlayer()
  }

  private func markAIChatThreadRead(_ id: UUID) {
    guard let index = aiChatThreads.firstIndex(where: { $0.id == id }) else { return }
    let thread = aiChatThreads[index]
    aiChatReadState.markRead(thread, transcriptURL: aiChatTranscriptURL)
    guard thread.unreadMessageCount != 0 else { return }
    let cachedMessageCount = (thread.isSettled
      ? archivedAIChatThreadSummaries
      : visibleAIChatThreadSummaries)
      .first(where: { $0.id == id })?.messageCount
    replaceAIChatThreadIncrementally(
      at: index,
      with: thread.replacingAIChatMetadata(unreadMessageCount: 0),
      messageCount: cachedMessageCount
    )
  }

  func updateSelectedAIChatThread(messages: [AIChatMessage]) {
    ensureAIChatThread()
    guard let selectedAIChatThreadID else {
      return
    }
    updateAIChatThread(selectedAIChatThreadID, messages: messages)
  }

  func updateAIChatThread(
    _ threadID: UUID,
    messages: [AIChatMessage],
    notifiesForNewAssistantMessages: Bool = false,
    transcriptURL: URL? = nil,
    shouldPersist: Bool = false,
    pendingTurnUpdate: AIChatPendingTurnUpdate = .preserve,
    recordsMessageMutation: Bool = true
  ) {
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    guard let current = aiChatThread(
      threadID,
      transcriptURL: targetTranscriptURL
    ) else { return }
    let newAssistantMessages = notifiesForNewAssistantMessages
      ? Self.newAssistantMessages(previousMessages: current.messages, currentMessages: messages)
      : []
    let newAssistantMessageCount = newAssistantMessages.count
    let isThreadOpen = isActiveAIChatTranscript(targetTranscriptURL)
      && selectedSurface == .aiChat
      && selectedAIChatThreadID == current.id
    let updated = Self.updatedAIChatThread(
      current,
      messages: messages,
      newAssistantMessageCount: newAssistantMessageCount,
      isThreadOpen: isThreadOpen,
      pendingTurnUpdate: pendingTurnUpdate
    )
    if isThreadOpen {
      aiChatReadState.markRead(updated, transcriptURL: targetTranscriptURL)
    }
    if recordsMessageMutation, isActiveAIChatTranscript(targetTranscriptURL) {
      advanceAIChatMessageRevision(
        for: threadID,
        tracksPersistence: true,
        makesColdPlaceholderAuthoritative: true
      )
    }
    replaceAIChatThread(
      updated,
      transcriptURL: targetTranscriptURL,
      shouldPersist: shouldPersist,
      recordsMessageMutation: recordsMessageMutation
    )
    if recordsMessageMutation,
       isActiveAIChatTranscript(targetTranscriptURL),
       selectedAIChatThreadID == threadID {
      publishedAIChatMessagesIdentity = aiChatMessagesIdentity(for: threadID)
    }
    if newAssistantMessageCount > 0 {
      if aiChatMessageSound != .off {
        aiChatIncomingMessageSoundPlayer()
      }
      aiChatIncomingMessageHandler(updated, newAssistantMessages)
    }
  }

  static func messageSoundPlayer(
    for sound: AIChatMessageSound
  ) -> @MainActor () -> Void {
    switch sound {
    case .org2:
      return { WorkspaceSound.playBundledNewMessageSound() }
    case .systemAlert:
      return { WorkspaceSound.beep() }
    case .off:
      return {}
    default:
      guard let name = sound.appKitSoundName else { return {} }
      return { WorkspaceSound.play(named: name) }
    }
  }

  nonisolated static func updatedAIChatThread(
    _ current: AIChatThread,
    messages: [AIChatMessage],
    newAssistantMessageCount: Int,
    isThreadOpen: Bool,
    pendingTurnUpdate: AIChatPendingTurnUpdate
  ) -> AIChatThread {
    let unreadMessageCount = isThreadOpen
      ? 0
      : current.unreadMessageCount + newAssistantMessageCount
    let pendingTurn: AIChatPendingTurn?
    switch pendingTurnUpdate {
    case .preserve:
      pendingTurn = current.pendingTurn
    case .replace(let nextPendingTurn):
      pendingTurn = nextPendingTurn
    }
    return AIChatThread(
      id: current.id,
      title: updatedAIChatThreadTitle(current: current, messages: messages),
      createdAt: current.createdAt,
      updatedAt: max(current.updatedAt, messages.last?.createdAt ?? Date()),
      runtime: current.runtime,
      destinationID: current.destinationID,
      sessionKey: current.sessionKey,
      runtimeThreadID: current.runtimeThreadID,
      runtimeThreadIDsByDestination: current.runtimeThreadIDsByDestination,
      model: current.model,
      reasoningEffort: current.reasoningEffort,
      messages: messages,
      isPinned: current.isPinned,
      isArchived: current.isArchived,
      settledAt: current.settledAt,
      unreadMessageCount: unreadMessageCount,
      resource: current.resource,
      pendingTurn: pendingTurn,
      isSharedRoom: current.isSharedRoom,
      roomAudience: current.roomAudience,
      roomModels: current.roomModels,
      roomDestinationIDs: current.roomDestinationIDs,
      roomModelsByDestination: current.roomModelsByDestination,
      roomReasoningEffortsByDestination: current.roomReasoningEffortsByDestination,
      roomDefaultDestinationID: current.roomDefaultDestinationID,
      roomAgentTurnLimit: current.roomAgentTurnLimit,
      agentRef: current.agentRef
    )
  }

  nonisolated private static func newAssistantMessages(
    previousMessages: [AIChatMessage],
    currentMessages: [AIChatMessage]
  ) -> [AIChatMessage] {
    let previousIDs = Set(previousMessages.map(\.id))
    return currentMessages
      .filter { $0.role == .assistant && !previousIDs.contains($0.id) }
  }

  func sortAIChatThreadsForDisplay() {
    aiChatThreads = Self.sortedAIChatThreadsForDisplay(aiChatThreads)
  }

  nonisolated static func sortedAIChatThreadsForDisplay(
    _ threads: [AIChatThread]
  ) -> [AIChatThread] {
    threads.sorted { lhs, rhs in
      if lhs.isSettled != rhs.isSettled { return !lhs.isSettled }
      if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
      return lhs.updatedAt > rhs.updatedAt
    }
  }

  nonisolated static func aiChatThreadTitle(
    from messages: [AIChatMessage],
    fallback: String = "New Chat"
  ) -> String {
    guard let firstUserMessage = messages.first(where: { $0.role == .user }) else {
      return fallback
    }
    let title = heuristicAIChatThreadTitle(from: firstUserMessage.content)
    return title.isEmpty ? fallback : title
  }

  nonisolated private static func updatedAIChatThreadTitle(
    current: AIChatThread,
    messages: [AIChatMessage]
  ) -> String {
    let heuristicTitle = aiChatThreadTitle(from: messages, fallback: current.title)
    let currentTitle = normalizedAIChatThreadTitle(current.title)
    let hasExistingUserMessage = current.messages.contains(where: { $0.role == .user })
    if currentTitle == "New Chat"
      || (hasExistingUserMessage && currentTitle == aiChatThreadTitle(from: current.messages, fallback: currentTitle)) {
      return heuristicTitle
    }
    return currentTitle
  }

  nonisolated static func normalizedAIChatThreadTitle(_ title: String) -> String {
    let clean = Org2Display.cleanInline(title)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return "New Chat" }
    return clean.count <= 80
      ? clean
      : String(clean.prefix(77)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
  }

  nonisolated private static func heuristicAIChatThreadTitle(from content: String) -> String {
    let normalized = normalizedAIChatTitleSource(content)
    guard !normalized.isEmpty else { return "" }

    let candidates = normalized
      .split(whereSeparator: { ".!?\n".contains($0) })
      .map { cleanedAIChatTitleCandidate(String($0)) }
      .filter { !$0.isEmpty && !isAIChatTitleFiller($0) }

    guard let candidate = candidates.first ?? normalized.split(separator: "\n").first.map(String.init) else {
      return ""
    }

    let words = candidate
      .split(whereSeparator: { $0.isWhitespace })
      .map { titleWord(from: String($0)) }
      .filter { !$0.isEmpty && !aiChatTitleStopWords.contains($0.lowercased()) }

    let selectedWords = Array(words.prefix(6))
    let rawTitle = (selectedWords.isEmpty ? candidate : selectedWords.joined(separator: " "))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let limitedTitle = rawTitle.count <= 56
      ? rawTitle
      : String(rawTitle.prefix(53)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    return sentenceCaseAIChatTitle(limitedTitle)
  }

  nonisolated private static func normalizedAIChatTitleSource(_ content: String) -> String {
    content
      .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\[[^\]]+\]\([^)]+\)"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"<image[^>]*>"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  nonisolated private static func cleanedAIChatTitleCandidate(_ candidate: String) -> String {
    var clean = candidate
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "#*-_`\"' "))

    let leadingPatterns = [
      #"(?i)^sure\s+let'?s\s+do\s+that\s+to\s+start\b"#,
      #"(?i)^while\s+you'?re\s+doing\s+that\b"#,
      #"(?i)^also\b"#,
      #"(?i)^can\s+you\b"#,
      #"(?i)^could\s+you\b"#,
      #"(?i)^would\s+you\b"#,
      #"(?i)^please\b"#,
      #"(?i)^i\s+think\b"#,
      #"(?i)^it\s+would\s+be\s+good\s+to\b"#,
      #"(?i)^it\s+would\s+be\s+great\s+to\b"#,
      #"(?i)^let'?s\b"#,
      #"(?i)^we\s+should\b"#,
      #"(?i)^our\b"#
    ]

    var changed = true
    while changed {
      changed = false
      for pattern in leadingPatterns {
        let next = clean
          .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if next != clean {
          clean = next
          changed = true
        }
      }
    }
    return clean
  }

  nonisolated private static func isAIChatTitleFiller(_ candidate: String) -> Bool {
    let normalized = candidate
      .lowercased()
      .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    return aiChatTitleFillerPhrases.contains(normalized)
  }

  nonisolated private static func titleWord(from raw: String) -> String {
    raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
  }

  nonisolated private static func sentenceCaseAIChatTitle(_ title: String) -> String {
    guard let first = title.first else { return title }
    return String(first).uppercased() + String(title.dropFirst())
  }

  nonisolated private static let aiChatTitleFillerPhrases = Set([
    "sure",
    "ok",
    "okay",
    "yes",
    "yeah",
    "thanks",
    "thank you",
    "sounds good",
    "that seems good",
    "lets do that",
    "let's do that",
    "sure lets do that to start",
    "sure let's do that to start"
  ])

  nonisolated private static let aiChatTitleStopWords = Set([
    "a", "able", "an", "and", "are", "as", "at", "be", "can", "could", "do", "does", "doing",
    "for", "from", "how", "i", "in", "is", "it", "just", "me", "my", "of", "on",
    "or", "our", "please", "should", "start", "that", "the", "this", "to", "we",
    "well", "what", "while", "with", "would", "you", "you're", "youre", "your"
  ])

  public nonisolated static func visibleAIChatMessageText(
    _ message: AIChatMessage
  ) -> String {
    AIChatContextPresentation(
      message.content,
      extractsContexts: message.role == .user
    ).clipboardText
  }

  nonisolated static func searchAIChatThreads(
    _ threads: [AIChatThread],
    query rawQuery: String,
    limit: Int,
    now: Date = Date()
  ) -> [AIChatSearchResult] {
    searchAIChatDocuments(
      threads.map { AIChatSearchDocument(thread: $0, messages: AIChatSearchIndex.searchMessages($0)) },
      query: rawQuery,
      limit: limit,
      now: now
    )
  }

  /// Returns at most one result per thread, ordered by match quality plus a
  /// strong recency bias. The snippet and date come from the most recent
  /// matching message, so the latest conversation about a topic leads.
  nonisolated static func searchAIChatDocuments(
    _ documents: [AIChatSearchDocument],
    query rawQuery: String,
    limit: Int,
    now: Date = Date()
  ) -> [AIChatSearchResult] {
    guard let query = WorkspaceSearchQuery(rawQuery), limit > 0 else { return [] }

    struct Candidate {
      let document: AIChatSearchDocument
      let latestMatch: AIChatSearchMessage?
      let isTitleMatch: Bool
      let matchedAt: Date
      let score: Double
    }

    var candidates: [Candidate] = []
    for document in documents {
      let thread = document.thread
      let titleQuality = query.titleQuality(thread.title)
      var latestMatch: AIChatSearchMessage?
      var latestMatchQuality: Double?
      for message in document.messages.reversed() {
        if let quality = query.bodyQuality(message.text) {
          latestMatch = message
          latestMatchQuality = quality
          break
        }
      }
      guard let quality = titleQuality ?? latestMatchQuality else { continue }
      let matchedAt = latestMatch?.createdAt ?? thread.updatedAt
      candidates.append(Candidate(
        document: document,
        latestMatch: latestMatch,
        isTitleMatch: titleQuality != nil,
        matchedAt: matchedAt,
        score: quality + WorkspaceSearchRanking.recencyBoost(matchedAt, now: now)
      ))
    }

    // Build snippets only for the results that will be shown.
    return candidates
      .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.matchedAt > rhs.matchedAt
      }
      .prefix(limit)
      .map { candidate in
        let thread = candidate.document.thread
        let snippetSource = candidate.latestMatch?.text
          ?? candidate.document.messages.first?.text
          ?? thread.title
        return AIChatSearchResult(
          threadID: thread.id,
          messageID: candidate.latestMatch?.id,
          matchKind: candidate.isTitleMatch ? .threadTitle : .messageText,
          title: thread.title,
          snippet: chatSearchSnippet(message: snippetSource, query: query),
          messageCount: thread.messageCount,
          updatedAt: thread.updatedAt,
          matchedAt: candidate.matchedAt
        )
      }
  }

  nonisolated private static func chatSearchSnippet(message: String, query: WorkspaceSearchQuery) -> String {
    let needle = query.match(message) == .phrase ? query.phrase : query.terms[0]
    return chatSearchSnippet(message: message, query: needle)
  }

  nonisolated private static func chatSearchSnippet(message: String, query: String) -> String {
    let collapsed = message
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return message }
    guard let range = collapsed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
      return String(collapsed.prefix(180))
    }

    let before = collapsed.distance(from: collapsed.startIndex, to: range.lowerBound)
    let startOffset = max(0, before - 72)
    let endOffset = min(collapsed.count, before + query.count + 108)
    let start = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
    let end = collapsed.index(collapsed.startIndex, offsetBy: endOffset)
    let prefix = startOffset > 0 ? "..." : ""
    let suffix = endOffset < collapsed.count ? "..." : ""
    return prefix + String(collapsed[start..<end]) + suffix
  }

  public func aiChatScrollPosition(
    isAssistantPanel: Bool,
    threadID: UUID? = nil
  ) -> Double? {
    let id = threadID ?? selectedAIChatThreadID
    guard let id else { return nil }
    return isAssistantPanel
      ? aiChatAssistantChatScrollPositionsByThreadID[id]
      : aiChatScrollPositionsByThreadID[id]
  }

  public func recordAIChatScrollPosition(
    _ position: Double,
    isAssistantPanel: Bool = false,
    threadID: UUID? = nil
  ) {
    guard let id = threadID ?? selectedAIChatThreadID else { return }
    let normalized = min(1, max(0, position))
    if isAssistantPanel {
      aiChatAssistantChatScrollPositionsByThreadID[id] = normalized
      if id == selectedAIChatThreadID { aiChatAssistantChatScrollPosition = normalized }
    } else {
      aiChatScrollPositionsByThreadID[id] = normalized
      if id == selectedAIChatThreadID { aiChatScrollPosition = normalized }
    }
  }

  public func completeAIChatScrollRestoration(threadID: UUID?) {
    lastCompletedAIChatScrollRestorationThreadID = threadID
    aiChatScrollRestorationCompletionGeneration &+= 1
    guard let threadID, pendingAIChatHydrationCommits[threadID] != nil else { return }
    pendingAIChatHydrationCommitTasks.removeValue(forKey: threadID)?.cancel()
    pendingAIChatHydrationCommitTasks[threadID] = Task { @MainActor [weak self] in
      do {
        // WebKit has applied the DOM mutation. Leave one display interval for
        // that frame to reach the screen before invalidating the large sidebar.
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.commitPendingAIChatHydration(for: threadID)
    }
  }

  /// ⌘-click on a workspace link: open the target in a new tab and keep the
  /// current tab where it is.
  public func openChatFileReferenceInNewTab(_ reference: AIChatFileReference) {
    usageLog.record(.linkOpenInNewTab)
    newWorkspaceTab()
    pendingNavigationSource = "link_new_tab"
    openChatFileReference(reference)
  }

  public func openChatFileReference(_ reference: AIChatFileReference) {
    guard let file = localPathForOpenClawReference(reference.path) else {
      let message = "Could not resolve file link: \(reference.path)"
      aiChatStatusText = message
      statusText = message
      return
    }

    if pendingNavigationSource == nil { pendingNavigationSource = "link" }
    if canJumpWithinActivePage(to: file) {
      pendingNavigationSource = nil
      if presentedAgentRunID != nil { presentedAgentRunID = nil }
      if isWorkspaceDetailPaneClosed { isWorkspaceDetailPaneClosed = false }
      if isWorkspaceDetailPaneExpanded { isWorkspaceDetailPaneExpanded = false }
      if let selectedLocation {
        scheduleSelectedDetailFreshnessCheck(
          for: selectedLocation,
          mode: selectedEntrySourceMode
        )
      }
      requestDetailScroll(toSourceLine: reference.line ?? 1)
      statusText = "Jumped to \(relativePath(file))"
      return
    }

    let url = URL(fileURLWithPath: file)
    let thread = AIChatThreadRecord(
      title: url.deletingPathExtension().lastPathComponent,
      file: file,
      line: reference.line ?? 1,
      zone: "chat link",
      modifiedAt: nil,
      idValue: nil
    )
    activateDetailLocation(.aiChatThreadRecord(thread), mode: .page, surface: nil, recordsHistory: true)
    if let line = reference.line {
      requestDetailScroll(toSourceLine: line)
    }
    statusText = "Opened \(relativePath(file))"
  }

  private func canJumpWithinActivePage(to file: String) -> Bool {
    guard selectedEntrySourceMode == .page,
          let source = selectedEntrySource,
          !selectedFileIsCSV
    else {
      return false
    }
    return URL(fileURLWithPath: source.file).standardizedFileURL.path
      == URL(fileURLWithPath: file).standardizedFileURL.path
  }

  public func isPersonalAssignee(_ rawAssignee: String?) -> Bool {
    guard let assignee = rawAssignee?.trimmingCharacters(in: .whitespacesAndNewlines),
          !assignee.isEmpty
    else {
      return true
    }
    return Self.personalAssigneeNames(from: personalAssigneeNamesText)
      .contains(Self.normalizedAssigneeIdentity(assignee))
  }

  public func isAgentAssignee(_ rawAssignee: String?) -> Bool {
    guard let assignee = rawAssignee?.trimmingCharacters(in: .whitespacesAndNewlines),
          !assignee.isEmpty
    else {
      return false
    }
    let normalized = Self.normalizedAssigneeIdentity(assignee)
    let agentNames = [
      agentHandoffAssignee,
      Self.defaultAgentHandoffAssignee
    ]
      .map(Self.normalizedAssigneeIdentity)
      .filter { !$0.isEmpty }
    return Set(agentNames).contains(normalized)
  }

  public func saveOpenClawConfiguration(
    endpoint: String,
    agent: String,
    handoffAssignee: String,
    personalAssigneeNames: String? = nil,
    remoteCorpusPath: String,
    briefsStartNewThread: Bool? = nil,
    autoSettleInterval: AIChatAutoSettleInterval? = nil,
    localEditsEnabled: Bool? = nil,
    token: String,
    clearToken: Bool
  ) -> Bool {
    let rawEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let normalizedEndpoint = OpenClawGatewaySettings.normalizedEndpointString(rawEndpoint) else {
      aiChatStatusText = "OpenClaw gateway endpoint is invalid"
      return false
    }

    let rawAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
    let agent = rawAgent.isEmpty ? "main" : rawAgent
    let rawHandoffAssignee = handoffAssignee.trimmingCharacters(in: .whitespacesAndNewlines)
    let handoffAssignee = rawHandoffAssignee.isEmpty ? Self.defaultAgentHandoffAssignee : rawHandoffAssignee
    let personalAssigneeNames = (personalAssigneeNames ?? personalAssigneeNamesText)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let remoteCorpusPath = remoteCorpusPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let briefsStartNewThread = briefsStartNewThread ?? aiChatBriefsStartNewThread
    let localEditsEnabled = localEditsEnabled ?? openClawLocalEditsEnabled
    let normalizedToken = OpenClawGatewaySettings.normalizedBearerToken(token)

    do {
      defaults.set(normalizedEndpoint, forKey: openClawEndpointKey)
      defaults.set(agent, forKey: openClawAgentKey)
      defaults.set(handoffAssignee, forKey: agentHandoffAssigneeKey)
      defaults.set(personalAssigneeNames, forKey: personalAssigneeNamesKey)
      defaults.set(remoteCorpusPath, forKey: openClawRemoteCorpusPathKey)
      if let corpusRoot {
        var paths = defaults.dictionary(forKey: openClawRemoteCorpusPathsByCorpusKey) as? [String: String] ?? [:]
        if remoteCorpusPath.isEmpty { paths.removeValue(forKey: corpusRoot.standardizedFileURL.path) }
        else { paths[corpusRoot.standardizedFileURL.path] = remoteCorpusPath }
        defaults.set(paths, forKey: openClawRemoteCorpusPathsByCorpusKey)
      }
      openClawEndpointText = normalizedEndpoint
      openClawAgentID = agent
      agentHandoffAssignee = handoffAssignee
      personalAssigneeNamesText = personalAssigneeNames
      openClawRemoteCorpusPath = remoteCorpusPath
      aiChatBriefsStartNewThread = briefsStartNewThread
      openClawLocalEditsEnabled = localEditsEnabled
      defaults.set(localEditsEnabled, forKey: openClawLocalEditsEnabledKey)
      if let autoSettleInterval {
        setAIChatAutoSettleInterval(autoSettleInterval)
      }

      if clearToken {
        try OpenClawKeychain.deleteToken()
        openClawBearerToken = nil
        openClawHasStoredToken = false
      } else if let token = normalizedToken {
        try OpenClawKeychain.saveToken(token)
        openClawBearerToken = token
        openClawHasStoredToken = true
      } else {
        openClawHasStoredToken = OpenClawKeychain.containsToken()
      }

      removeCachedAIChatConfiguration(
        destinationID: AIChatDestinationConfiguration.openClawID
      )
      if selectedAIChatDestination.adapter == .openClaw {
        aiChatStatusText = Self.aiChatStatusText(settings: currentOpenClawSettings())
      }
      Task { @MainActor [weak self] in
        await self?.refreshAIChatCommands(force: true)
      }
      restartOpenClawLocalEditNode()
      return true
    } catch {
      aiChatStatusText = error.localizedDescription
      return false
    }
  }

  public func meetingReadyAutomationThreads(
    destinationID: String
  ) -> [AIChatThread] {
    aiChatThreads
      .filter { !$0.isSharedRoom && $0.destinationID == destinationID }
      .sorted { lhs, rhs in
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.isSettled != rhs.isSettled { return !lhs.isSettled }
        return lhs.updatedAt > rhs.updatedAt
      }
  }

  @discardableResult
  public func saveMeetingReadyAutomationConfiguration(
    isEnabled: Bool,
    destinationID: String,
    threadMode: MeetingReadyAutomationThreadMode,
    threadID: UUID?,
    prompt: String
  ) -> Bool {
    guard corpusRoot != nil else {
      meetingReadyAutomationStatusText = "Choose a corpus before enabling meeting automation"
      return false
    }
    let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if isEnabled {
      guard enabledAIChatDestinations.contains(where: { $0.id == destinationID }) else {
        meetingReadyAutomationStatusText = "Choose an enabled AI destination"
        return false
      }
      guard !prompt.isEmpty else {
        meetingReadyAutomationStatusText = "Enter a meeting-processing prompt"
        return false
      }
      if threadMode == .existingThread {
        guard let threadID,
              aiChatThreads.contains(where: {
                $0.id == threadID && !$0.isSharedRoom && $0.destinationID == destinationID
              })
        else {
          meetingReadyAutomationStatusText = "Choose an existing thread for this destination"
          return false
        }
      }
    }

    meetingReadyAutomationSettings = MeetingReadyAutomationSettings(
      isEnabled: isEnabled,
      destinationID: destinationID,
      threadMode: threadMode,
      threadID: threadMode == .existingThread ? threadID : nil,
      prompt: prompt.isEmpty ? MeetingReadyAutomationSettings.defaultPrompt : prompt
    )
    persistMeetingReadyAutomationSettings()
    if isEnabled {
      meetingReadyAutomationStatusText = "Watching for completed meetings"
    } else {
      meetingReadyAutomationStatusText = "Meeting automation is off"
    }
    return true
  }

  func restoreMeetingReadyAutomationState(for corpusRoot: URL) {
    let corpusKey = corpusRoot.standardizedFileURL.path
    let settingsByCorpus = Self.decodeDefaultsValue(
      [String: MeetingReadyAutomationSettings].self,
      defaults: defaults,
      key: meetingReadyAutomationSettingsByCorpusKey
    ) ?? [:]
    let deliveriesByCorpus = Self.decodeDefaultsValue(
      [String: [String: MeetingReadyAutomationDeliveryRecord]].self,
      defaults: defaults,
      key: meetingReadyAutomationDeliveriesByCorpusKey
    ) ?? [:]
    meetingReadyAutomationSettings = settingsByCorpus[corpusKey] ?? MeetingReadyAutomationSettings()
    meetingReadyAutomationDeliveries = deliveriesByCorpus[corpusKey] ?? [:]
    meetingReadyAutomationDispatchingEventIDs = []
    meetingReadyAutomationStatusText = meetingReadyAutomationSettings.isEnabled
      ? "Watching for completed meetings"
      : "Meeting automation is off"
  }

  private static func decodeDefaultsValue<T: Decodable>(
    _ type: T.Type,
    defaults: UserDefaults,
    key: String
  ) -> T? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private func persistMeetingReadyAutomationSettings() {
    guard let corpusRoot else { return }
    let corpusKey = corpusRoot.standardizedFileURL.path
    var settingsByCorpus = Self.decodeDefaultsValue(
      [String: MeetingReadyAutomationSettings].self,
      defaults: defaults,
      key: meetingReadyAutomationSettingsByCorpusKey
    ) ?? [:]
    settingsByCorpus[corpusKey] = meetingReadyAutomationSettings
    if let data = try? JSONEncoder().encode(settingsByCorpus) {
      defaults.set(data, forKey: meetingReadyAutomationSettingsByCorpusKey)
    }
  }

  func persistMeetingReadyAutomationDeliveries() {
    guard let corpusRoot else { return }
    let corpusKey = corpusRoot.standardizedFileURL.path
    var deliveriesByCorpus = Self.decodeDefaultsValue(
      [String: [String: MeetingReadyAutomationDeliveryRecord]].self,
      defaults: defaults,
      key: meetingReadyAutomationDeliveriesByCorpusKey
    ) ?? [:]
    deliveriesByCorpus[corpusKey] = meetingReadyAutomationDeliveries
    if let data = try? JSONEncoder().encode(deliveriesByCorpus) {
      defaults.set(data, forKey: meetingReadyAutomationDeliveriesByCorpusKey)
    }
  }

  private func meetingReadyAutomationEventID(for item: MeetingWorkspaceItem) -> String {
    if let idValue = item.idValue?.trimmingCharacters(in: .whitespacesAndNewlines),
       !idValue.isEmpty {
      return "meeting-id:\(idValue)"
    }
    return "meeting-file:\(relativePath(item.file))"
  }

  private func meetingReadyAutomationMessageMarker(eventID: String) -> String {
    "#+org2_automation_event_id: meeting-ready:\(eventID)"
  }

  func meetingTranscriptionDidComplete(_ item: MeetingWorkspaceItem) {
    // This is an event boundary, not a projection reconciliation. Never call it
    // while scanning corpus history: an existing completed meeting is not a new
    // local transcription-completed event.
    guard meetingReadyAutomationSettings.isEnabled else { return }
    guard item.transcriptionStatus?.lowercased() == MeetingTranscriptionStatus.complete.rawValue else {
      return
    }
    dispatchMeetingReadyAutomationIfNeeded(for: item)
  }

  func meetingTranscriptionDidCompleteForTesting(_ item: MeetingWorkspaceItem) {
    meetingTranscriptionDidComplete(item)
  }

  private func dispatchMeetingReadyAutomationIfNeeded(for item: MeetingWorkspaceItem) {
    let context = captureAIChatCorpusContext()
    let eventID = meetingReadyAutomationEventID(for: item)
    if let status = meetingReadyAutomationDeliveries[eventID]?.status,
       status == .baseline || status == .queued {
      return
    }
    guard !meetingReadyAutomationDispatchingEventIDs.contains(eventID) else { return }

    let marker = meetingReadyAutomationMessageMarker(eventID: eventID)
    if let existingDelivery = aiChatThreads.lazy.compactMap({ thread in
      thread.messages.first(where: { $0.role == .user && $0.content.contains(marker) })
        .map { (thread, $0) }
    }).first {
      meetingReadyAutomationDeliveries[eventID] = MeetingReadyAutomationDeliveryRecord(
        eventID: eventID,
        meetingFile: item.file,
        destinationID: existingDelivery.0.destinationID,
        threadID: existingDelivery.0.id,
        status: .queued,
        updatedAt: Date(),
        error: nil
      )
      persistMeetingReadyAutomationDeliveries()
      if existingDelivery.1.deliveryStatus == .failed
        || existingDelivery.1.deliveryStatus == .interrupted {
        meetingReadyAutomationStatusText = "Meeting delivery needs attention: \(item.title)"
      }
      return
    }

    meetingReadyAutomationDispatchingEventIDs.insert(eventID)
    let settings = meetingReadyAutomationSettings
    guard enabledAIChatDestinations.contains(where: { $0.id == settings.destinationID }) else {
      meetingReadyAutomationDispatchingEventIDs.remove(eventID)
      recordMeetingReadyAutomationFailure(
        eventID: eventID,
        item: item,
        threadID: nil,
        error: "The configured AI destination is unavailable"
      )
      return
    }

    let targetThread: AIChatThread?
    switch settings.threadMode {
    case .newThread:
      if let retryThreadID = meetingReadyAutomationDeliveries[eventID]?.threadID,
         let retryThread = aiChatThreads.first(where: { $0.id == retryThreadID }) {
        targetThread = retryThread
      } else {
        targetThread = createAIChatThread(
          title: Self.normalizedAIChatThreadTitle("Meeting: \(item.title)"),
          statusText: "Queued completed meeting",
          runtime: aiChatDestinationRuntime(settings.destinationID),
          destinationID: settings.destinationID,
          selectsThread: false
        )
      }
    case .existingThread:
      targetThread = settings.threadID.flatMap { targetID in
        aiChatThreads.first(where: {
          $0.id == targetID && !$0.isSharedRoom && $0.destinationID == settings.destinationID
        })
      }
    }

    guard let targetThread else {
      meetingReadyAutomationDispatchingEventIDs.remove(eventID)
      recordMeetingReadyAutomationFailure(
        eventID: eventID,
        item: item,
        threadID: settings.threadID,
        error: "The configured meeting thread could not be found"
      )
      return
    }
    if targetThread.isSettled {
      reopenAIChatThread(targetThread.id)
    }

    let pointer = aiChatContextPointer(for: .meeting(item))
    let text = automaticAIChatActionText(
      pointer,
      prompt: settings.prompt + "\n\n" + marker
    )
    let enqueueResult = queueAIChatAutomationMessage(
      text,
      threadID: targetThread.id,
      marker: marker,
      context: context
    )
    switch enqueueResult {
    case .rejected:
      finishMeetingReadyAutomationEnqueue(
        .rejected,
        eventID: eventID,
        item: item,
        threadID: targetThread.id,
        settings: settings,
        context: context
      )
    case .enqueued(let acceptedThreadID, let shouldDrain):
      if shouldDrain {
        Task { @MainActor [weak self] in
          await self?.drainAIChatSendQueue(for: acceptedThreadID)
        }
      }
      finishMeetingReadyAutomationEnqueue(
        .enqueued(threadID: acceptedThreadID, shouldDrain: false),
        eventID: eventID,
        item: item,
        threadID: targetThread.id,
        settings: settings,
        context: context
      )
    case .deferred(let task):
      Task { @MainActor [weak self] in
        guard let self else { return }
        let outcome = await task.value
        self.finishMeetingReadyAutomationEnqueue(
          outcome,
          eventID: eventID,
          item: item,
          threadID: targetThread.id,
          settings: settings,
          context: context
        )
      }
    }
  }

  private func finishMeetingReadyAutomationEnqueue(
    _ outcome: AIChatEnqueueOutcome,
    eventID: String,
    item: MeetingWorkspaceItem,
    threadID: UUID,
    settings: MeetingReadyAutomationSettings,
    context: AIChatCorpusContextToken
  ) {
    guard isCurrentAIChatCorpusContext(context) else {
      let status: MeetingReadyAutomationDeliveryStatus
      let error: String?
      switch outcome {
      case .enqueued:
        status = .queued
        error = nil
      case .rejected, .superseded:
        status = .failed
        error = "Corpus changed before the meeting message could be queued; retry when this corpus is active"
      }
      persistMeetingReadyAutomationDelivery(
        MeetingReadyAutomationDeliveryRecord(
          eventID: eventID,
          meetingFile: item.file,
          destinationID: settings.destinationID,
          threadID: threadID,
          status: status,
          updatedAt: Date(),
          error: error
        ),
        corpusPath: context.corpusRootPath
      )
      meetingReadyAutomationEnqueueDidResolveForTesting?(eventID)
      return
    }
    meetingReadyAutomationDispatchingEventIDs.remove(eventID)
    switch outcome {
    case .enqueued:
      meetingReadyAutomationDeliveries[eventID] = MeetingReadyAutomationDeliveryRecord(
        eventID: eventID,
        meetingFile: item.file,
        destinationID: settings.destinationID,
        threadID: threadID,
        status: .queued,
        updatedAt: Date(),
        error: nil
      )
      persistMeetingReadyAutomationDeliveries()
      meetingReadyAutomationStatusText = "Queued \(item.title) to \(aiChatDestinationTitle(settings.destinationID))"
    case .rejected:
      recordMeetingReadyAutomationFailure(
        eventID: eventID,
        item: item,
        threadID: threadID,
        error: "The meeting message could not be queued"
      )
    case .superseded:
      break
    }
    meetingReadyAutomationEnqueueDidResolveForTesting?(eventID)
  }

  private func persistMeetingReadyAutomationDelivery(
    _ record: MeetingReadyAutomationDeliveryRecord,
    corpusPath: String?
  ) {
    guard let corpusPath else { return }
    var deliveriesByCorpus = Self.decodeDefaultsValue(
      [String: [String: MeetingReadyAutomationDeliveryRecord]].self,
      defaults: defaults,
      key: meetingReadyAutomationDeliveriesByCorpusKey
    ) ?? [:]
    var deliveries = deliveriesByCorpus[corpusPath] ?? [:]
    if let existing = deliveries[record.eventID],
       existing.status == .queued || existing.status == .baseline {
      return
    }
    deliveries[record.eventID] = record
    deliveriesByCorpus[corpusPath] = deliveries
    if let data = try? JSONEncoder().encode(deliveriesByCorpus) {
      defaults.set(data, forKey: meetingReadyAutomationDeliveriesByCorpusKey)
    }
  }
}
