import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  func refileRenderedEntry(
    _ block: OrgEditableBlock,
    from source: EntrySource,
    to destination: URL
  ) async {
    do {
      guard let context = captureDocumentCorpusContext(forFile: source.file) else {
        throw WorkspaceDocumentMutationError.outsideCorpus(
          file: source.file,
          root: corpusRoot?.path ?? "(none)"
        )
      }
      let cli = self.cli
      let payload: RefileMutationPayload = try await performDocumentMutation(
        context: context,
        files: [source.file, destination.path]
      ) { _ in
        try await cli.runJSON([
          "refile",
          "--file", source.file,
          "--pos", "\(block.startLine)",
          "--to-file", destination.path,
          "--format", "json",
          "--apply",
        ])
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      invalidateCanonicalDocumentCache(for: source.file)
      invalidateCanonicalDocumentCache(for: destination.path)
      if let selectedLocation, selectedEntrySource?.file == source.file {
        scheduleEntrySourceLoad(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
      Task { await refreshCorpusFiles() }
      statusText = payload.changed
        ? "Refiled entry to \(relativePath(destination.path))"
        : "Entry was already in place"
    } catch {
      errorText = error.localizedDescription
      statusText = "Refile failed"
    }
  }

  /// The archive file `celorga archive` uses by default for an Org file.
  nonisolated static func renderedEntryArchiveFile(for sourceFile: String) -> String {
    "\(sourceFile)_archive"
  }

  func archiveRenderedEntry(_ block: OrgEditableBlock) async {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "This entry is read-only"
      return
    }
    let archiveFile = Self.renderedEntryArchiveFile(for: source.file)
    do {
      guard let context = captureDocumentCorpusContext(forFile: source.file) else {
        throw WorkspaceDocumentMutationError.outsideCorpus(
          file: source.file,
          root: corpusRoot?.path ?? "(none)"
        )
      }
      let cli = self.cli
      let payload: ArchiveMutationPayload = try await performDocumentMutation(
        context: context,
        files: [source.file, archiveFile]
      ) { _ in
        try await cli.runJSON([
          "archive",
          "--file", source.file,
          "--pos", "\(block.startLine)",
          "--archive-file", archiveFile,
          "--format", "json",
          "--apply",
        ])
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      invalidateCanonicalDocumentCache(for: source.file)
      invalidateCanonicalDocumentCache(for: archiveFile)
      if let selectedLocation, selectedEntrySource?.file == source.file {
        scheduleEntrySourceLoad(for: selectedLocation)
      }
      scheduleAgendaRefresh(preserveSelection: true)
      Task { await refreshCorpusFiles() }
      statusText = payload.wrote
        ? "Archived entry to \(relativePath(archiveFile))"
        : "Entry was not archived"
    } catch {
      errorText = error.localizedDescription
      statusText = "Archive failed"
    }
  }

  nonisolated static func renderedEntrySubtreeText(
    for block: OrgEditableBlock,
    in source: EntrySource
  ) throws -> String {
    let range = try deletionRange(for: block, in: source)
    let lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let startIndex = range.startLine - source.startLine
    let endIndex = range.endLineExclusive - source.startLine
    guard startIndex >= 0,
          endIndex >= startIndex,
          endIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: block.startLine)
    }
    return lines[startIndex..<endIndex].joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
  }

  nonisolated static func sourceAIContextBlock(
    at line: Int,
    in blocks: [OrgEditableBlock]
  ) -> OrgEditableBlock? {
    blocks.first { block in
      guard block.startLine == line else { return false }
      switch block.rendered {
      case .heading, .paragraph:
        return true
      default:
        return false
      }
    }
  }

  public func briefCurrentNode() async {
    guard let location = selectedLocation else {
      statusText = "Select a node first"
      return
    }
    guard let corpusRoot else {
      statusText = "Open a corpus first"
      return
    }

    let initialLookup = await nodeBriefLookup(for: location)
    let briefTitle = initialLookup?.title ?? location.title
    if let artifact = initialLookup?.artifact {
      currentNodeBriefArtifact = artifact
      openNodeBriefArtifact(
        url: URL(fileURLWithPath: artifact.file).standardizedFileURL,
        relativePath: artifact.relativePath,
        title: briefTitle,
        modifiedAt: artifact.modifiedAt
      )
      return
    }

    isBuildingNodeBrief = true
    aiChatStatusText = "Sending node brief request..."
    statusText = "Sending node brief request..."
    defer { isBuildingNodeBrief = false }

    do {
      let id = try await backlinkTargetID(for: location)
      if let lookup = await nodeBriefLookup(for: location, sourceID: id),
         let artifact = lookup.artifact {
        currentNodeBriefArtifact = artifact
        openNodeBriefArtifact(
          url: URL(fileURLWithPath: artifact.file).standardizedFileURL,
          relativePath: artifact.relativePath,
          title: lookup.title,
          modifiedAt: artifact.modifiedAt
        )
        return
      }
      let artifactRelativePath = Self.nodeBriefArtifactRelativePath(
        id: id,
        file: relativePath(location.file),
        line: location.lineForEditor
      )
      let artifactURL = corpusRoot.appendingPathComponent(artifactRelativePath).standardizedFileURL
      if let artifact = await Task.detached(priority: .userInitiated, operation: {
        Self.nodeBriefArtifact(at: artifactURL, relativePath: artifactRelativePath)
      }).value {
        currentNodeBriefArtifact = artifact
        openNodeBriefArtifact(
          url: artifactURL,
          relativePath: artifactRelativePath,
          title: briefTitle,
          modifiedAt: artifact.modifiedAt
        )
        return
      }

      let prompt = Self.nodeBriefPrompt(
        title: briefTitle,
        reference: "\(relativePath(location.file)):\(location.lineForEditor)",
        artifactRelativePath: artifactRelativePath,
        artifactLocalPath: artifactURL.path,
        artifactRuntimePath: mappedPathForOpenClaw(artifactURL.path),
        sourceID: id
      )
      pendingNodeBriefArtifactRelativePath = artifactRelativePath
      pendingNodeBriefTitle = briefTitle
      setAIChatAssistantPanelPresented(true)
      prepareAIChatThreadForNodeBrief(title: briefTitle)
      let runtimeTitle = selectedAIChatDestinationTitle
      let briefContext: AIChatWorkspaceContext?
      if let thread = selectedAIChatThread {
        briefContext = currentAIChatWorkspaceContext(
          threadContinuation: aiChatThreadContinuation(for: thread)
        )
      } else {
        briefContext = nil
      }
      await sendAIChatMessage(
        automaticAIChatActionText(
          aiChatContextPointer(for: location),
          prompt: prompt
        ),
        attachments: [],
        workspaceContext: briefContext
      )
      if await openNodeBriefArtifactWhenAvailable(url: artifactURL, relativePath: artifactRelativePath, title: briefTitle) {
        return
      }
      if aiChatStatusText == "\(runtimeTitle) replied" || aiChatStatusText.hasPrefix("Edited ") {
        pendingNodeBriefArtifactRelativePath = nil
        pendingNodeBriefTitle = nil
        aiChatStatusText = "\(runtimeTitle) replied without writing the node brief artifact"
        statusText = "Node brief artifact was not written"
      }
    } catch {
      errorText = error.localizedDescription
      aiChatStatusText = "Node brief failed"
      statusText = "Node brief failed"
    }
  }

  private func openNodeBriefArtifactWhenAvailable(url: URL, relativePath: String, title: String) async -> Bool {
    let expectedPath = url.standardizedFileURL.path
    for delay in Self.nodeBriefArtifactRetryDelays {
      if delay > 0 {
        try? await Task.sleep(nanoseconds: delay)
      }
      if case .aiChatThreadRecord(let thread) = selectedLocation,
         URL(fileURLWithPath: thread.file).standardizedFileURL.path == expectedPath {
        return true
      }
      guard let artifact = await Task.detached(priority: .userInitiated, operation: {
        Self.nodeBriefArtifact(at: url, relativePath: relativePath)
      }).value else { continue }
      currentNodeBriefArtifact = artifact
      await refreshCorpusFiles()
      Task { await refreshAIChatThreadRecords(showsLoading: false) }
      openNodeBriefArtifact(
        url: url,
        relativePath: relativePath,
        title: title,
        modifiedAt: artifact.modifiedAt
      )
      return true
    }
    return false
  }

  func rebuildMeetingDisplayCache() {
    let grouped = Dictionary(grouping: meetings) { item -> String in
      guard let recordedAt = item.recordedAt, recordedAt.count >= 10 else {
        return "Unknown date"
      }
      return String(recordedAt.prefix(10))
    }
    meetingDisplaySections = grouped.keys.sorted(by: >).map { key in
      let items = (grouped[key] ?? []).sorted {
        ($0.recordedAt ?? "") > ($1.recordedAt ?? "")
      }
      return MeetingSection(id: key, label: key, meetings: items)
    }
  }

  public var pendingMeetingProcessingItems: [MeetingProcessingItem] {
    let existingMeetingIDs = Set(meetings.map(Self.meetingProcessingID(for:)))
    return processingMeetings.filter { !existingMeetingIDs.contains($0.id) }
  }

  public func isMeetingProcessing(_ meeting: MeetingWorkspaceItem) -> Bool {
    activeMeetingProcessingIDs.contains(Self.meetingProcessingID(for: meeting))
  }

  public func select(_ location: WorkspaceLocation, surface: WorkspaceSurface? = nil) {
    let nextMode = resolvedEntrySourceMode(for: location, requestedMode: nil)
    let nextSurface = surface ?? selectedSurface
    if isCurrentNavigationDestination(
      location: location,
      surface: nextSurface,
      mode: nextMode
    ), !isWorkspaceDetailPaneClosed {
      applyDetailSelectionMetadata(for: location)
      return
    }

    if case .search = location {
      isPageSearchPresented = false
      pageSearchQuery = ""
      renderedSearchHighlightQuery = Self.normalizedRenderedSearchHighlightQuery(searchQuery)
      resetPageSearchMatches()
    } else {
      isPageSearchPresented = false
      pageSearchQuery = ""
      renderedSearchHighlightQuery = nil
      resetPageSearchMatches()
    }
    activateDetailLocation(location, mode: nil, surface: surface, recordsHistory: true)
  }

  public func selectSearchResult(_ result: SearchResult) {
    if activateCorpusIfNeeded(for: result.corpus, location: .search(result), surface: .search) {
      return
    }
    select(.search(result), surface: .search)
  }

  @discardableResult
  func activateCorpusIfNeeded(
    for corpus: WorkspaceResultCorpus?,
    location: WorkspaceLocation,
    surface: WorkspaceSurface
  ) -> Bool {
    guard let corpus else { return false }
    let destination = URL(fileURLWithPath: corpus.root).standardizedFileURL
    guard destination.path != corpusRoot?.standardizedFileURL.path else { return false }
    guard !isSwitchingCorpus && !isRefreshingWorkspace else {
      statusText = "Wait for the current workspace refresh before opening another corpus."
      return true
    }
    guard !hasActiveEdit && !liveFileEditorHasUnsavedChanges else {
      errorText = "Save or cancel the current edit before opening another corpus."
      statusText = "Unsaved edit"
      return true
    }
    guard isDirectory(destination.path) else {
      errorText = "The mounted corpus is not available at \(destination.path)."
      statusText = "Corpus unavailable"
      return true
    }

    isSwitchingCorpus = true
    setCorpusRoot(destination)
    statusText = "Opening \(corpus.name)..."
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.refreshWorkspace()
      if case .search = location,
         !self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        await self.runSearch()
      }
      self.isSwitchingCorpus = false
      self.select(location, surface: surface)
      self.statusText = "Opened \(corpus.name)"
    }
    return true
  }

  public func isResultInActiveCorpus(_ corpus: WorkspaceResultCorpus?) -> Bool {
    guard let corpus else { return true }
    return URL(fileURLWithPath: corpus.root).standardizedFileURL.path == corpusRoot?.standardizedFileURL.path
  }

  public func corpusQualifiedPath(_ file: String, corpus: WorkspaceResultCorpus?) -> String {
    guard let corpus else { return relativePath(file) }
    let relative = Self.relativePath(for: file, root: URL(fileURLWithPath: corpus.root))
    return "\(corpus.name) · \(relative)"
  }

  public func selectAgentRun(_ run: AgentRunItem) {
    activateAgentRunDetail(run.id, recordsHistory: true)
  }

  public func handleAgentRunClick(
    _ run: AgentRunItem,
    visibleRunIDs: [AgentRunItem.ID],
    modifiers: NSEvent.ModifierFlags = []
  ) {
    selectedAgentRunIDsForAIContext = Self.updatedAIContextSelection(
      selectedAgentRunIDsForAIContext,
      activeID: selectedAgentRunID,
      clickedID: run.id,
      visibleIDs: visibleRunIDs,
      modifiers: modifiers
    )
    selectAgentRun(run)
  }

  public func isAgentRunSelectedForAIContext(_ run: AgentRunItem) -> Bool {
    selectedAgentRunIDsForAIContext.isEmpty
      ? selectedAgentRunID == run.id
      : selectedAgentRunIDsForAIContext.contains(run.id)
  }

  public func reconcileAgentRunAIContextSelection(visibleIDs: [AgentRunItem.ID]) {
    selectedAgentRunIDsForAIContext.formIntersection(visibleIDs)
  }

  func selectAllVisibleAgentRunsForAIContext() {
    let visibleIDs = agentRunIDs(for: agentRunSelectionScope)
    selectedAgentRunIDsForAIContext = Set(visibleIDs)
    statusText = Self.listSelectionStatus(count: visibleIDs.count, singular: "run")
  }

  func clearAgentRunAIContextSelection() {
    guard !selectedAgentRunIDsForAIContext.isEmpty else { return }
    selectedAgentRunIDsForAIContext = []
    statusText = "Run selection cleared"
  }

  func extendAgentRunAIContextSelection(by delta: Int) {
    let visibleIDs = agentRunIDs(for: agentRunSelectionScope)
    let result = Self.extendedKeyboardSelection(
      selectedAgentRunIDsForAIContext,
      activeID: selectedAgentRunID,
      visibleIDs: visibleIDs,
      delta: delta
    )
    guard let targetID = result.targetID, let target = agentRun(for: targetID) else {
      statusText = "No visible runs"
      return
    }
    selectedAgentRunIDsForAIContext = result.selection
    selectAgentRun(target)
    statusText = Self.listSelectionStatus(count: result.selection.count, singular: "run")
  }

  static func updatedAIContextSelection<ID: Hashable>(
    _ selection: Set<ID>,
    activeID: ID?,
    clickedID: ID,
    visibleIDs: [ID],
    modifiers: NSEvent.ModifierFlags
  ) -> Set<ID> {
    let modifiers = modifiers.intersection([.command, .shift])
    if modifiers.contains(.shift),
       let activeID,
       let anchorIndex = visibleIDs.firstIndex(of: activeID),
       let clickedIndex = visibleIDs.firstIndex(of: clickedID) {
      let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
      return Set(bounds.map { visibleIDs[$0] })
    }

    if modifiers.contains(.command) {
      var next = selection
      if next.isEmpty, let activeID, activeID != clickedID {
        next.insert(activeID)
      }
      if next.contains(clickedID) {
        next.remove(clickedID)
      } else {
        next.insert(clickedID)
      }
      return next
    }

    return [clickedID]
  }

  static func extendedKeyboardSelection<ID: Hashable>(
    _ selection: Set<ID>,
    activeID: ID?,
    visibleIDs: [ID],
    delta: Int
  ) -> (selection: Set<ID>, targetID: ID?) {
    guard !visibleIDs.isEmpty else { return (selection, nil) }

    let currentIndex = activeID.flatMap { visibleIDs.firstIndex(of: $0) }
    let targetIndex: Int
    if let currentIndex {
      targetIndex = max(0, min(visibleIDs.count - 1, currentIndex + delta))
    } else {
      targetIndex = delta < 0 ? visibleIDs.count - 1 : 0
    }

    var nextSelection = selection
    if let currentIndex {
      nextSelection.insert(visibleIDs[currentIndex])
    }
    let targetID = visibleIDs[targetIndex]
    nextSelection.insert(targetID)
    return (nextSelection, targetID)
  }

  static func listSelectionStatus(count: Int, singular: String) -> String {
    if count == 0 { return "No visible \(singular)s" }
    return count == 1 ? "1 \(singular) selected" : "\(count) \(singular)s selected"
  }

  /// Presents a run in the detail pane. Opening a run from the Runs list
  /// makes Agent Work the surface, but restoring a tab or back-history
  /// snapshot must keep the surface that was showing beside the run (for
  /// example an AI chat thread with a run open in the detail pane); otherwise
  /// the tab silently turns into an Agent Work tab.
  private func activateAgentRunDetail(
    _ runID: AgentRunItem.ID,
    surface: WorkspaceSurface = .approvals,
    recordsHistory: Bool
  ) {
    guard agentRunsByID[runID] != nil else { return }
    if selectedSurface == surface,
       selectedAgentRunID == runID,
       presentedAgentRunID == runID,
       !isWorkspaceDetailPaneClosed {
      return
    }
    if recordsHistory,
       presentedAgentRunID != runID || selectedSurface != surface {
      recordCurrentNavigationDestination()
    }
    clearDetailForNavigation()
    selectedSurface = surface
    selectedAgentRunID = runID
    presentedAgentRunID = runID
    isWorkspaceDetailPaneClosed = false
    isWorkspaceDetailPaneExpanded = false
    statusText = "Opened agent run"
  }

  /// Opens a web link as a page in the detail pane, the way file links open
  /// documents, recording it in back/forward history.
  public func openWebPage(_ url: URL) {
    presentWebPage(url, surface: nil, recordsHistory: true)
  }

  /// ⌘-click on a web link: open the page in a new tab.
  public func openWebPageInNewTab(_ url: URL) {
    usageLog.record(.linkOpenInNewTab)
    newWorkspaceTab()
    presentWebPage(url, surface: nil, recordsHistory: true)
  }

  private func presentWebPage(
    _ url: URL,
    surface: WorkspaceSurface?,
    recordsHistory: Bool
  ) {
    let nextSurface = surface ?? selectedSurface
    if presentedWebPageURL != nil,
       currentWebPageNavigationURL == url,
       selectedSurface == nextSurface,
       !isWorkspaceDetailPaneClosed {
      return
    }
    cancelPendingDailyNoteNavigation()
    if recordsHistory,
       hasWorkspaceDetailContent || selectedSurface != nextSurface {
      recordCurrentNavigationDestination()
    }
    clearDetailForNavigation()
    if selectedSurface != nextSurface { selectedSurface = nextSurface }
    presentedWebPageURL = url
    browser.load(url)
    isWorkspaceDetailPaneClosed = false
    isWorkspaceDetailPaneExpanded = false
    activeWorkspacePane = .detail
    statusText = "Opened \(url.host ?? url.absoluteString)"
  }

  public var hasRenderedSearchHighlight: Bool {
    renderedSearchHighlightQuery?.isEmpty == false
  }

  public func clearRenderedSearchHighlight() {
    renderedSearchHighlightQuery = nil
    pageSearchQuery = ""
    isPageSearchPresented = false
    resetPageSearchMatches()
  }

  public func selectEntrySourceMode(_ mode: EntrySourceMode) {
    guard selectedEntrySourceMode != mode else { return }
    _ = OrgSyntaxTextEditorLifecycle.checkpointPendingTextChanges()
    recordCurrentNavigationDestination()
    selectedEntrySourceMode = mode
  }

  @discardableResult
  public func focusPageSearch() -> Bool {
    if presentedWebPageURL != nil {
      browser.presentFind()
      return true
    }
    guard selectedLocation != nil else { return false }
    isPageSearchPresented = true
    pageSearchQuery = renderedSearchHighlightQuery ?? ""
    schedulePageSearchRefresh(selectFirst: true, debounce: false)
    pageSearchFocusToken += 1
    return true
  }

  public var pageSearchOccurrenceSummary: String {
    guard let query = Self.normalizedRenderedSearchHighlightQuery(pageSearchQuery) else { return "" }
    guard query == renderedSearchHighlightQuery else { return "Searching…" }
    let total = max(pageSearchOccurrenceCount, pageSearchRenderedMatches.count)
    guard total > 0 else { return "0 matches" }
    if let pageSearchSelectedOccurrenceIndex {
      return "\(min(pageSearchSelectedOccurrenceIndex + 1, total)) of \(total)"
    }
    return "\(total) matches"
  }

  public var canNavigatePageSearchOccurrences: Bool {
    Self.normalizedRenderedSearchHighlightQuery(pageSearchQuery) == renderedSearchHighlightQuery
      && pageSearchRenderedMatches.count > 1
  }

  public func selectNextPageSearchOccurrence() {
    selectAdjacentPageSearchOccurrence(delta: 1)
  }

  public func selectPreviousPageSearchOccurrence() {
    selectAdjacentPageSearchOccurrence(delta: -1)
  }

  private func selectAdjacentPageSearchOccurrence(delta: Int) {
    guard Self.normalizedRenderedSearchHighlightQuery(pageSearchQuery) == renderedSearchHighlightQuery else {
      schedulePageSearchRefresh(selectFirst: true, debounce: false)
      return
    }
    guard !pageSearchRenderedMatches.isEmpty else { return }
    let current = pageSearchSelectedOccurrenceIndex ?? 0
    let count = pageSearchRenderedMatches.count
    let next = (current + delta + count) % count
    selectPageSearchOccurrence(at: next)
  }

  func schedulePageSearchRefresh(selectFirst: Bool, debounce: Bool = true) {
    pageSearchRefreshGeneration += 1
    let generation = pageSearchRefreshGeneration
    pageSearchRefreshTask?.cancel()

    guard let query = Self.normalizedRenderedSearchHighlightQuery(pageSearchQuery) else {
      renderedSearchHighlightQuery = nil
      resetPageSearchMatches()
      pageSearchRefreshTask = nil
      return
    }

    let blocks = selectedRenderedBlocks
    let fallbackText = selectedEntrySource?.text ?? ""
    let liveText = isLiveFileEditorSelected ? editableEntryText : nil
    let filePath = isLiveFileEditorSelected ? nil : selectedEntrySource?.file
    pageSearchRefreshTask = Task { [blocks, fallbackText, filePath, generation, liveText, query] in
      if debounce {
        try? await Task.sleep(nanoseconds: 80_000_000)
      }
      guard !Task.isCancelled else { return }

      let result = await Task.detached(priority: .userInitiated) {
        let text: String
        if let liveText {
          text = liveText
        } else if let filePath,
                  let fileText = try? String(contentsOf: URL(fileURLWithPath: filePath), encoding: .utf8) {
          text = fileText
        } else {
          text = fallbackText
        }
        return PageSearchComputation(
          matches: Self.renderedPageSearchMatches(in: blocks, query: query),
          occurrenceCount: Self.countSearchOccurrences(in: text, query: query)
        )
      }.value
      guard !Task.isCancelled else { return }

      await MainActor.run { [weak self] in
        guard let self,
              self.pageSearchRefreshGeneration == generation,
              Self.normalizedRenderedSearchHighlightQuery(self.pageSearchQuery) == query,
              self.isPageSearchPresented
        else { return }
        self.renderedSearchHighlightQuery = query
        self.pageSearchRenderedMatches = result.matches
        self.pageSearchOccurrenceCount = result.occurrenceCount
        self.pageSearchRefreshTask = nil

        guard !result.matches.isEmpty else {
          self.pageSearchSelectedOccurrenceIndex = nil
          return
        }
        let nextIndex = selectFirst
          ? 0
          : min(self.pageSearchSelectedOccurrenceIndex ?? 0, result.matches.count - 1)
        self.selectPageSearchOccurrence(at: nextIndex)
      }
    }
  }

  private func resetPageSearchMatches() {
    pageSearchRefreshGeneration += 1
    pageSearchRefreshTask?.cancel()
    pageSearchRefreshTask = nil
    pageSearchRenderedMatches = []
    pageSearchOccurrenceCount = 0
    pageSearchSelectedOccurrenceIndex = nil
  }

  private func selectPageSearchOccurrence(at index: Int) {
    guard pageSearchRenderedMatches.indices.contains(index) else { return }
    let match = pageSearchRenderedMatches[index]
    pageSearchSelectedOccurrenceIndex = index
    selectedBlockID = match.blockID
    requestDetailScroll(toBlock: match.blockID)
  }

  public func workspaceTabDisplayTitle(for tab: WorkspaceTab) -> String {
    tab.id == selectedWorkspaceTabID
      ? currentWorkspaceTabMetadata().title
      : tab.title
  }

  public func workspaceTabDisplaySystemImage(for tab: WorkspaceTab) -> String {
    tab.id == selectedWorkspaceTabID
      ? currentWorkspaceTabMetadata().systemImage
      : tab.systemImage
  }

  @discardableResult
  public func newWorkspaceTab() -> WorkspaceTab.ID {
    saveSelectedWorkspaceTabState()
    let tab = WorkspaceTab(
      title: WorkspaceSurface.home.title,
      systemImage: WorkspaceSurface.home.systemImage
    )
    let insertionIndex = workspaceTabs.firstIndex(where: {
      $0.id == selectedWorkspaceTabID
    }).map { $0 + 1 } ?? workspaceTabs.endIndex
    workspaceTabs.insert(tab, at: insertionIndex)
    workspaceTabStates[tab.id] = initialWorkspaceTabState()
    activateWorkspaceTab(tab.id)
    return tab.id
  }

  @discardableResult
  public func duplicateWorkspaceTab(_ tabID: WorkspaceTab.ID? = nil) -> WorkspaceTab.ID {
    saveSelectedWorkspaceTabState()
    let sourceID = tabID.flatMap { requestedID in
      workspaceTabs.contains(where: { $0.id == requestedID }) ? requestedID : nil
    } ?? selectedWorkspaceTabID
    let sourceState = workspaceTabStates[sourceID] ?? initialWorkspaceTabState()
    let sourceTab = workspaceTabs.first(where: { $0.id == sourceID })
      ?? WorkspaceTab(
        title: WorkspaceSurface.home.title,
        systemImage: WorkspaceSurface.home.systemImage
      )
    let duplicate = WorkspaceTab(
      title: sourceTab.title,
      systemImage: sourceTab.systemImage
    )
    let insertionIndex = workspaceTabs.firstIndex(where: {
      $0.id == sourceID
    }).map { $0 + 1 } ?? workspaceTabs.endIndex
    workspaceTabs.insert(duplicate, at: insertionIndex)
    workspaceTabStates[duplicate.id] = sourceState
    activateWorkspaceTab(duplicate.id)
    return duplicate.id
  }

  public func selectWorkspaceTab(_ tabID: WorkspaceTab.ID) {
    guard tabID != selectedWorkspaceTabID,
          workspaceTabs.contains(where: { $0.id == tabID })
    else { return }
    saveSelectedWorkspaceTabState()
    activateWorkspaceTab(tabID)
  }

  public func selectPreviousWorkspaceTab() {
    selectAdjacentWorkspaceTab(offset: -1)
  }

  public func selectNextWorkspaceTab() {
    selectAdjacentWorkspaceTab(offset: 1)
  }

  public func closeWorkspaceTab(_ tabID: WorkspaceTab.ID) {
    guard workspaceTabs.count > 1,
          let closingIndex = workspaceTabs.firstIndex(where: { $0.id == tabID })
    else { return }

    if tabID != selectedWorkspaceTabID {
      workspaceTabs.remove(at: closingIndex)
      workspaceTabStates.removeValue(forKey: tabID)
      return
    }

    let replacementIndex = closingIndex < workspaceTabs.count - 1
      ? closingIndex + 1
      : closingIndex - 1
    let replacementID = workspaceTabs[replacementIndex].id
    workspaceTabs.remove(at: closingIndex)
    workspaceTabStates.removeValue(forKey: tabID)
    activateWorkspaceTab(replacementID)
  }

  public func closeOtherWorkspaceTabs(keeping tabID: WorkspaceTab.ID) {
    guard workspaceTabs.count > 1,
          workspaceTabs.contains(where: { $0.id == tabID })
    else { return }
    if selectedWorkspaceTabID != tabID {
      selectWorkspaceTab(tabID)
    } else {
      saveSelectedWorkspaceTabState()
    }
    let keptTab = workspaceTabs.first(where: { $0.id == tabID })
      ?? WorkspaceTab(
        id: tabID,
        title: WorkspaceSurface.home.title,
        systemImage: WorkspaceSurface.home.systemImage
      )
    workspaceTabs = [keptTab]
    workspaceTabStates = workspaceTabStates.filter { $0.key == tabID }
  }

  @discardableResult
  public func moveWorkspaceTab(
    _ tabID: WorkspaceTab.ID,
    to targetID: WorkspaceTab.ID
  ) -> Bool {
    guard tabID != targetID,
          let sourceIndex = workspaceTabs.firstIndex(where: { $0.id == tabID }),
          let targetIndex = workspaceTabs.firstIndex(where: { $0.id == targetID })
    else { return false }
    let tab = workspaceTabs.remove(at: sourceIndex)
    workspaceTabs.insert(tab, at: min(targetIndex, workspaceTabs.endIndex))
    return true
  }

  public func moveWorkspaceTab(_ tabID: WorkspaceTab.ID, offset: Int) {
    guard offset != 0,
          let sourceIndex = workspaceTabs.firstIndex(where: { $0.id == tabID })
    else { return }
    let targetIndex = sourceIndex + offset
    guard workspaceTabs.indices.contains(targetIndex) else { return }
    workspaceTabs.swapAt(sourceIndex, targetIndex)
  }

  public func navigateBack() {
    guard let snapshot = workspaceNavigationBackStack.popLast() else { return }
    let current = currentWorkspaceNavigationSnapshot()
    if workspaceNavigationForwardStack.last != current {
      workspaceNavigationForwardStack.append(current)
      trimNavigationHistory(&workspaceNavigationForwardStack)
    }
    usageLog.record(.navigateHistory, ["direction": "back"])
    pendingNavigationSource = "history_back"
    restoreWorkspaceNavigationSnapshot(snapshot)
    pendingNavigationSource = nil
  }

  /// Re-applies the location most recently left with Back. A new navigation
  /// clears this stack, matching browser history semantics.
  public func navigateForward() {
    guard let snapshot = workspaceNavigationForwardStack.popLast() else { return }
    let current = currentWorkspaceNavigationSnapshot()
    if workspaceNavigationBackStack.last != current {
      workspaceNavigationBackStack.append(current)
      trimNavigationHistory(&workspaceNavigationBackStack)
    }
    usageLog.record(.navigateHistory, ["direction": "forward"])
    pendingNavigationSource = "history_forward"
    restoreWorkspaceNavigationSnapshot(snapshot)
    pendingNavigationSource = nil
  }

  private func trimNavigationHistory(_ stack: inout [WorkspaceNavigationSnapshot]) {
    if stack.count > Self.detailNavigationHistoryLimit {
      stack.removeFirst(stack.count - Self.detailNavigationHistoryLimit)
    }
  }

  private func restoreWorkspaceNavigationSnapshot(_ snapshot: WorkspaceNavigationSnapshot) {
    if let runID = snapshot.agentRunDetailID,
       agentRunsByID[runID] != nil {
      activateAgentRunDetail(
        runID,
        surface: snapshot.selectedSurface,
        recordsHistory: false
      )
    } else if let webPageURL = snapshot.webPageURL {
      presentWebPage(webPageURL, surface: snapshot.selectedSurface, recordsHistory: false)
    } else if let missingDailyNote = snapshot.missingDailyNote,
              let corpusRoot {
      presentMissingDailyNote(
        at: URL(fileURLWithPath: missingDailyNote.file),
        corpusRoot: corpusRoot,
        opensHome: missingDailyNote.opensHome,
        surface: snapshot.selectedSurface,
        recordsHistory: false
      )
    } else if let location = snapshot.location {
      activateDetailLocation(
        location,
        mode: snapshot.selectedEntrySourceMode,
        surface: snapshot.selectedSurface,
        recordsHistory: false
      )
    } else {
      selectedSurface = snapshot.selectedSurface
      clearDetailForNavigation()
    }
    restoreWorkspaceSelection(from: snapshot)
    restoreWorkspacePaneLayout(from: snapshot)
  }

  private func saveSelectedWorkspaceTabState() {
    let metadata = currentWorkspaceTabMetadata()
    if let index = workspaceTabs.firstIndex(where: {
      $0.id == selectedWorkspaceTabID
    }), workspaceTabs[index].title != metadata.title
      || workspaceTabs[index].systemImage != metadata.systemImage {
      workspaceTabs[index].title = metadata.title
      workspaceTabs[index].systemImage = metadata.systemImage
    }
    let editorState: WorkspaceTabEditorState
    if let target = workspaceTabEditorRestoreTarget,
       target.tabID == selectedWorkspaceTabID,
       target.surface == selectedSurface,
       selectedLocation.map({ Self.selectionIdentity(for: $0) }) == target.locationIdentity,
       let pendingState = workspaceTabStates[selectedWorkspaceTabID]?.editor,
       pendingState.isEditingEntry,
       !isEditingEntry {
      // Loading a tab's source editor is asynchronous. If the user switches
      // away again before it mounts, retain the tab's intended editor state
      // instead of snapshotting that brief loading state as "not editing."
      editorState = pendingState
    } else {
      editorState = WorkspaceTabEditorState(
        isEditingEntry: isEditingEntry,
        selection: sourceEditorSelection,
        presentation: sourceEditorPresentation,
        isPreviewPaused: isSourceEditorPreviewPaused
      )
    }
    workspaceTabStates[selectedWorkspaceTabID] = WorkspaceTabState(
      navigation: currentWorkspaceNavigationSnapshot(),
      backStack: workspaceNavigationBackStack,
      forwardStack: workspaceNavigationForwardStack,
      surface: currentWorkspaceTabSurfaceState(),
      editor: editorState,
      documentViewportSourceLines: documentViewportSourceLines,
      documentSlidePageIndexes: documentSlidePageIndexes,
      aiChatScrollPositionsByThreadID: aiChatScrollPositionsByThreadID,
      aiChatAssistantChatScrollPositionsByThreadID: aiChatAssistantChatScrollPositionsByThreadID
    )
  }

  private func activateWorkspaceTab(_ tabID: WorkspaceTab.ID) {
    guard workspaceTabs.contains(where: { $0.id == tabID }) else { return }
    let state = workspaceTabStates[tabID] ?? initialWorkspaceTabState()
    _ = supersedeDailyNoteNavigation()
    cancelWorkspaceTabEditorRestore()
    // A tab switch is a session boundary even when both tabs point at the
    // same file. Tear down the outgoing detail first so editor drafts,
    // in-flight loads, and view-local state cannot leak into the next tab.
    clearDetailForNavigation()
    selectedWorkspaceTabID = tabID
    pendingNavigationSource = "tab_switch"
    restoreWorkspaceTabSurfaceState(state.surface)
    documentViewportSourceLines = state.documentViewportSourceLines
    documentSlidePageIndexes = state.documentSlidePageIndexes
    aiChatScrollPositionsByThreadID = state.aiChatScrollPositionsByThreadID
    aiChatAssistantChatScrollPositionsByThreadID = state.aiChatAssistantChatScrollPositionsByThreadID
    defaults.set(documentViewportSourceLines, forKey: documentViewportSourceLinesKey)
    defaults.set(documentSlidePageIndexes, forKey: documentSlidePageIndexesKey)
    workspaceNavigationBackStack = state.backStack
    workspaceNavigationForwardStack = state.forwardStack
    restoreWorkspaceNavigationSnapshot(state.navigation)
    restoreWorkspaceTabEditorState(state.editor, tabID: tabID)
  }

  private func restoreWorkspaceTabEditorState(
    _ state: WorkspaceTabEditorState,
    tabID: WorkspaceTab.ID
  ) {
    sourceEditorPresentation = state.presentation
    isSourceEditorPreviewPaused = state.isPreviewPaused
    guard state.isEditingEntry,
          let location = selectedLocation,
          !Self.isNativePreviewFile(location.file)
    else { return }

    workspaceTabEditorRestoreGeneration += 1
    let generation = workspaceTabEditorRestoreGeneration
    let expectedSurface = selectedSurface
    let expectedLocationIdentity = Self.selectionIdentity(for: location)
    workspaceTabEditorRestoreTarget = (
      tabID: tabID,
      surface: expectedSurface,
      locationIdentity: expectedLocationIdentity
    )
    workspaceTabEditorRestoreTask = Task { @MainActor [weak self] in
      await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
      guard !Task.isCancelled, let self else { return }
      defer {
        if self.workspaceTabEditorRestoreGeneration == generation {
          self.workspaceTabEditorRestoreTask = nil
          self.workspaceTabEditorRestoreTarget = nil
        }
      }
      guard self.workspaceTabEditorRestoreGeneration == generation,
            self.selectedWorkspaceTabID == tabID,
            self.selectedSurface == expectedSurface,
            self.selectedLocation.map(Self.selectionIdentity(for:)) == expectedLocationIdentity
      else { return }
      guard await self.awaitPendingEditorPersistence() else {
        self.statusText = "Could not restore the editor until its saved draft is resolved"
        return
      }
      guard !Task.isCancelled,
            self.workspaceTabEditorRestoreGeneration == generation,
            self.selectedWorkspaceTabID == tabID,
            self.selectedSurface == expectedSurface,
            self.selectedLocation.map(Self.selectionIdentity(for:)) == expectedLocationIdentity
      else { return }

      if !self.isEditingEntry {
        await self.loadEntrySource(for: location)
        guard !Task.isCancelled,
              self.workspaceTabEditorRestoreGeneration == generation,
              self.selectedWorkspaceTabID == tabID,
              self.selectedSurface == expectedSurface,
              self.selectedLocation.map(Self.selectionIdentity(for:)) == expectedLocationIdentity
        else { return }
        self.beginEditingSelectedEntry(initialSelection: state.selection)
      }
      self.sourceEditorPresentation = state.presentation
      self.isSourceEditorPreviewPaused = state.isPreviewPaused
    }
  }

  private func cancelWorkspaceTabEditorRestore() {
    workspaceTabEditorRestoreTask?.cancel()
    workspaceTabEditorRestoreTask = nil
    workspaceTabEditorRestoreTarget = nil
    workspaceTabEditorRestoreGeneration += 1
  }

  private func selectAdjacentWorkspaceTab(offset: Int) {
    guard workspaceTabs.count > 1,
          let selectedIndex = workspaceTabs.firstIndex(where: {
            $0.id == selectedWorkspaceTabID
          })
    else { return }
    let count = workspaceTabs.count
    let nextIndex = (selectedIndex + offset % count + count) % count
    selectWorkspaceTab(workspaceTabs[nextIndex].id)
  }

  private func initialWorkspaceTabState() -> WorkspaceTabState {
    WorkspaceTabState(
      navigation: WorkspaceNavigationSnapshot(
        location: nil,
        missingDailyNote: nil,
        agentRunDetailID: nil,
        selectedSurface: .home,
        activeWorkspacePane: .surface,
        selectedEntrySourceMode: .entry,
        agendaMode: .focus,
        runsAndReviewPage: .runs,
        expandedWorkspaceSurface: nil,
        isWorkspaceSurfacePaneClosed: false,
        isWorkspaceDetailPaneClosed: false,
        isWorkspaceDetailPaneExpanded: false,
        isAIChatAssistantPresented: false,
        isNodeContextPanePresented: false,
        selectedAgendaItemID: nil,
        selectedAssignedWorkItemID: nil,
        selectedApprovalItemID: nil,
        selectedAgentRunID: nil,
        selectedAgentWorkflowID: nil,
        selectedAgentGoalID: nil,
        selectedAgentProfileID: nil,
        selectedCorpusFileID: nil,
        selectedMeetingID: nil,
        selectedAIChatThreadID: nil,
        selectedExternalThreadID: nil,
        selectedWorkspaceSkillID: nil
      ),
      backStack: [],
      surface: initialWorkspaceTabSurfaceState(),
      editor: WorkspaceTabEditorState(
        isEditingEntry: false,
        selection: NSRange(location: 0, length: 0),
        presentation: sourceEditorPresentation,
        isPreviewPaused: false
      ),
      documentViewportSourceLines: documentViewportSourceLines,
      documentSlidePageIndexes: documentSlidePageIndexes,
      aiChatScrollPositionsByThreadID: aiChatScrollPositionsByThreadID,
      aiChatAssistantChatScrollPositionsByThreadID: aiChatAssistantChatScrollPositionsByThreadID
    )
  }

  private func currentWorkspaceTabSurfaceState() -> WorkspaceTabSurfaceState {
    WorkspaceTabSurfaceState(
      agendaFilter: agendaFilter,
      agendaDateFilter: agendaDateFilter,
      agendaAssigneeFilter: agendaAssigneeFilter,
      agendaStatusFilter: agendaStatusFilter,
      agendaPriorityFilter: agendaPriorityFilter,
      agendaTopicFilter: agendaTopicFilter,
      agendaReadScope: agendaReadScope,
      bulkSelectedAgendaItemIDs: bulkSelectedAgendaItemIDs,
      approvalFilter: approvalFilter,
      selectedApprovalItemIDsForAIContext: selectedApprovalItemIDsForAIContext,
      bulkSelectedApprovalItemIDs: bulkSelectedApprovalItemIDs,
      agentRunFilter: agentRunFilter,
      agentRunSelectionScope: agentRunSelectionScope,
      selectedAgentRunIDsForAIContext: selectedAgentRunIDsForAIContext,
      corpusFileFilter: corpusFileFilter,
      selectedCorpusFileIDsForAIContext: selectedCorpusFileIDsForAIContext,
      searchMode: searchMode,
      searchReadScope: searchReadScope,
      searchQuery: searchQuery,
      searchResults: searchResults,
      aiChatSearchResults: aiChatSearchResults,
      workspaceFileSearchResults: workspaceFileSearchResults,
      workspacePageSearchResults: workspacePageSearchResults,
      workspaceAgentWorkSearchResults: workspaceAgentWorkSearchResults,
      searchNodes: searchNodes,
      externalThreadSearchQuery: externalThreadSearchQuery,
      selectedExternalThreadDetail: selectedExternalThreadDetail
    )
  }

  private func initialWorkspaceTabSurfaceState() -> WorkspaceTabSurfaceState {
    WorkspaceTabSurfaceState(
      agendaFilter: "",
      agendaDateFilter: .any,
      agendaAssigneeFilter: "",
      agendaStatusFilter: "",
      agendaPriorityFilter: "",
      agendaTopicFilter: "",
      agendaReadScope: .activeCorpus,
      bulkSelectedAgendaItemIDs: [],
      approvalFilter: "",
      selectedApprovalItemIDsForAIContext: [],
      bulkSelectedApprovalItemIDs: [],
      agentRunFilter: "",
      agentRunSelectionScope: .active,
      selectedAgentRunIDsForAIContext: [],
      corpusFileFilter: "",
      selectedCorpusFileIDsForAIContext: [],
      searchMode: .text,
      searchReadScope: .activeCorpus,
      searchQuery: "",
      searchResults: [],
      aiChatSearchResults: [],
      workspaceFileSearchResults: [],
      workspacePageSearchResults: [],
      workspaceAgentWorkSearchResults: [],
      searchNodes: [],
      externalThreadSearchQuery: "",
      selectedExternalThreadDetail: nil
    )
  }

  private func restoreWorkspaceTabSurfaceState(_ state: WorkspaceTabSurfaceState) {
    agendaFilter = state.agendaFilter
    isUpdatingAgendaStructuredFilters = true
    agendaDateFilter = state.agendaDateFilter
    agendaAssigneeFilter = state.agendaAssigneeFilter
    agendaStatusFilter = state.agendaStatusFilter
    agendaPriorityFilter = state.agendaPriorityFilter
    agendaTopicFilter = state.agendaTopicFilter
    isUpdatingAgendaStructuredFilters = false
    agendaReadScope = state.agendaReadScope
    bulkSelectedAgendaItemIDs = state.bulkSelectedAgendaItemIDs
    rebuildAgendaDisplayCache()
    rebuildAssignedWorkDisplayCache()

    approvalFilter = state.approvalFilter
    selectedApprovalItemIDsForAIContext = state.selectedApprovalItemIDsForAIContext
    bulkSelectedApprovalItemIDs = state.bulkSelectedApprovalItemIDs
    agentRunFilter = state.agentRunFilter
    agentRunSelectionScope = state.agentRunSelectionScope
    selectedAgentRunIDsForAIContext = state.selectedAgentRunIDsForAIContext
    corpusFileFilter = state.corpusFileFilter
    selectedCorpusFileIDsForAIContext = state.selectedCorpusFileIDsForAIContext

    searchMode = state.searchMode
    searchReadScope = state.searchReadScope
    searchQuery = state.searchQuery
    searchResults = state.searchResults
    aiChatSearchResults = state.aiChatSearchResults
    workspaceFileSearchResults = state.workspaceFileSearchResults
    workspacePageSearchResults = state.workspacePageSearchResults
    workspaceAgentWorkSearchResults = state.workspaceAgentWorkSearchResults
    searchNodes = state.searchNodes
    externalThreadSearchQuery = state.externalThreadSearchQuery
    selectedExternalThreadDetail = state.selectedExternalThreadDetail
  }

  func resetWorkspaceTabsForCorpusChange() {
    cancelWorkspaceTabEditorRestore()
    workspaceTabStates = [:]
    let metadata = currentWorkspaceTabMetadata()
    workspaceTabs = [WorkspaceTab(
      id: selectedWorkspaceTabID,
      title: metadata.title,
      systemImage: metadata.systemImage
    )]
  }

  private func currentWorkspaceTabMetadata() -> (title: String, systemImage: String) {
    let rawTitle: String
    if activeWorkspacePane == .surface, !isWorkspaceSurfacePaneClosed {
      if selectedSurface == .skills,
         let selectedWorkspaceSkillID,
         let skill = workspaceSkills.first(where: { $0.id == selectedWorkspaceSkillID }) {
        rawTitle = "/\(skill.name)"
      } else if selectedSurface == .aiChat,
                let threadID = selectedAIChatThreadID,
                let thread = aiChatThreads.first(where: { $0.id == threadID }) {
        rawTitle = thread.title
      } else {
        rawTitle = selectedSurface.title
      }
    } else if let presentedAgentRun {
      rawTitle = presentedAgentRun.goal
    } else if let presentedWebPageURL {
      rawTitle = browser.title.isEmpty ? (presentedWebPageURL.host ?? presentedWebPageURL.absoluteString) : browser.title
    } else if let missingDailyNote {
      rawTitle = missingDailyNote.title
    } else if let selectedLocation {
      rawTitle = selectedLocation.title
    } else {
      rawTitle = selectedSurface.title
    }
    return (
      Self.normalizedWorkspaceTabTitle(rawTitle, fallback: selectedSurface.title),
      selectedSurface.systemImage
    )
  }

  nonisolated private static func normalizedWorkspaceTabTitle(
    _ rawTitle: String,
    fallback: String
  ) -> String {
    let cleaned = Org2Display.cleanInline(rawTitle)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = cleaned.isEmpty ? fallback : cleaned
    let limit = 48
    guard resolved.count > limit else { return resolved }
    return String(resolved.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }

  func activateDetailLocation(
    _ location: WorkspaceLocation,
    mode: EntrySourceMode?,
    surface: WorkspaceSurface?,
    recordsHistory: Bool
  ) {
    cancelPendingDailyNoteNavigation()
    missingDailyNote = nil
    let checkpointedDocumentIdentities = OrgSyntaxTextEditorLifecycle.checkpointPendingTextChanges()
    let nextMode = resolvedEntrySourceMode(for: location, requestedMode: mode)
    let nextSurface = surface ?? selectedSurface
    noteDocumentNavigation(to: location, recordsHistory: recordsHistory)
    if recordsHistory,
       !isCurrentNavigationDestination(
         location: location,
         surface: nextSurface,
         mode: nextMode
       ),
       hasWorkspaceDetailContent || selectedSurface != nextSurface {
      recordCurrentNavigationDestination()
    }
    if presentedAgentRunID != nil { presentedAgentRunID = nil }
    if presentedWebPageURL != nil { presentedWebPageURL = nil }
    if selectedSurface != nextSurface { selectedSurface = nextSurface }
    if isWorkspaceDetailPaneClosed { isWorkspaceDetailPaneClosed = false }
    if isWorkspaceDetailPaneExpanded { isWorkspaceDetailPaneExpanded = false }
    if canReuseActiveDetail(for: location, mode: nextMode) {
      pendingDocumentReadyMeasurement = nil
      applyDetailSelectionMetadata(for: location)
      selectedLocation = location
      scheduleSelectedDetailFreshnessCheck(for: location, mode: nextMode)
      return
    }

    persistLiveFileEditorDraftBeforeNavigation(
      checkpointedDocumentIdentities: checkpointedDocumentIdentities
    )
    cancelLiveFileEditorAutosave(resetStatus: false)
    switch location {
    case .search:
      break
    default:
      isPageSearchPresented = false
      pageSearchQuery = ""
      renderedSearchHighlightQuery = nil
      resetPageSearchMatches()
    }

    applyDetailSelectionMetadata(for: location)
    selectedLocation = location
    detailScrollRequest = nil
    cancelSourceEditorPreviewRender(clearStatus: true)
    cancelLinkedPDFPreview(clearStatus: true)
    isEditingEntry = false
    replaceEditableEntryTextFromModel("")
    sourceEditorSelection = NSRange(location: 0, length: 0)
    resetBlockState()
    selectedEntrySourceMode = nextMode
    selectedEntrySource = nil
    selectedEntryHTML = nil
    selectedEntryRenderError = nil
    entityActionItemsLoadGeneration += 1
    entityActionItems = nil
    isLoadingEntityActionItems = false
    selectedEntryHTMLRenderKey = nil
    selectedRenderedBlocks = []
    entryHTMLRenderTask?.cancel()
    entryHTMLRenderTask = nil
    entryHTMLRenderWatchdogTask?.cancel()
    entryHTMLRenderWatchdogTask = nil
    isRenderingEntrySource = false
    entryHTMLRenderGeneration += 1
    if Self.isPDFFile(location.file) {
      cancelBacklinksLoad(clearResults: true)
      scheduleLinkedPDFPreviewLoad(for: location)
    } else if Self.isMediaFile(location.file) {
      // Images and videos render natively from the file URL; there is no Org
      // source to parse or render.
      cancelBacklinksLoad(clearResults: true)
      cancelLinkedPDFPreview(clearStatus: false)
      linkedPDFPreviewData = nil
      linkedPDFPreviewError = nil
    } else {
      scheduleBacklinksLoad(for: location)
      scheduleEntrySourceLoad(for: location)
    }
  }

  func recordCurrentNavigationDestination() {
    let snapshot = currentWorkspaceNavigationSnapshot()
    // Any new destination invalidates the forward branch.
    if !workspaceNavigationForwardStack.isEmpty { workspaceNavigationForwardStack = [] }
    guard workspaceNavigationBackStack.last != snapshot else { return }
    workspaceNavigationBackStack.append(snapshot)
    trimNavigationHistory(&workspaceNavigationBackStack)
  }

  private func currentWorkspaceNavigationSnapshot() -> WorkspaceNavigationSnapshot {
    let locationAgendaItemID: String? = {
      guard case .agenda(let item) = selectedLocation else { return nil }
      return item.id
    }()
    let locationAssignedItemID: AssignedWorkItem.ID? = {
      guard case .assigned(let item) = selectedLocation else { return nil }
      return item.id
    }()
    let locationApprovalItemID: ApprovalItem.ID? = {
      guard selectedSurface == .approvals, let selectedLocation else { return nil }
      return approvalItems.first(where: {
        $0.file == selectedLocation.file && $0.line == selectedLocation.lineForEditor
      })?.id
    }()
    let locationCorpusFileID: String? = {
      guard selectedSurface == .files, let selectedLocation else { return nil }
      let path = URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path
      return corpusFilesByPath[path]?.id
    }()
    let locationMeetingID: String? = {
      guard case .meeting(let meeting) = selectedLocation else { return nil }
      return meeting.id
    }()

    return WorkspaceNavigationSnapshot(
      location: selectedLocation,
      missingDailyNote: missingDailyNote,
      agentRunDetailID: presentedAgentRunID,
      webPageURL: currentWebPageNavigationURL,
      selectedSurface: selectedSurface,
      activeWorkspacePane: activeWorkspacePane,
      selectedEntrySourceMode: selectedEntrySourceMode,
      agendaMode: agendaMode,
      runsAndReviewPage: runsAndReviewPage,
      expandedWorkspaceSurface: expandedWorkspaceSurface,
      isWorkspaceSurfacePaneClosed: isWorkspaceSurfacePaneClosed,
      isWorkspaceDetailPaneClosed: isWorkspaceDetailPaneClosed,
      isWorkspaceDetailPaneExpanded: isWorkspaceDetailPaneExpanded,
      isAIChatAssistantPresented: isAIChatAssistantPresented,
      isNodeContextPanePresented: isNodeContextPanePresented,
      selectedAgendaItemID: locationAgendaItemID ?? selectedAgendaItemID,
      selectedAssignedWorkItemID: locationAssignedItemID ?? selectedAssignedWorkItemID,
      selectedApprovalItemID: locationApprovalItemID ?? selectedApprovalItemID,
      selectedAgentRunID: selectedAgentRunID,
      selectedAgentWorkflowID: selectedAgentWorkflowID,
      selectedAgentGoalID: selectedAgentGoalID,
      selectedAgentProfileID: selectedAgentProfileID,
      selectedCorpusFileID: locationCorpusFileID ?? selectedCorpusFileID,
      selectedMeetingID: locationMeetingID ?? selectedMeetingID,
      selectedAIChatThreadID: selectedAIChatThreadID,
      selectedExternalThreadID: selectedExternalThreadID,
      selectedWorkspaceSkillID: selectedWorkspaceSkillID
    )
  }

  func isCurrentNavigationDestination(
    location: WorkspaceLocation?,
    surface: WorkspaceSurface,
    mode: EntrySourceMode
  ) -> Bool {
    guard selectedSurface == surface,
          presentedAgentRunID == nil,
          presentedWebPageURL == nil,
          selectedEntrySourceMode == mode
    else {
      return false
    }
    switch (selectedLocation, location) {
    case (nil, nil):
      return true
    case (.some(let current), .some(let next)):
      return Self.selectionIdentity(for: current) == Self.selectionIdentity(for: next)
    default:
      return false
    }
  }

  func navigateToSurface(_ surface: WorkspaceSurface, recordsHistory: Bool = true) {
    if surface != .home {
      cancelPendingDailyNoteNavigation()
    }
    if recordsHistory, selectedSurface != surface {
      recordCurrentNavigationDestination()
    }
    if selectedSurface != surface {
      usageLog.record(.surfaceOpen, ["surface": .string(surface.rawValue)])
      selectedSurface = surface
    }
  }

  private func restoreWorkspaceSelection(from snapshot: WorkspaceNavigationSnapshot) {
    selectedEntrySourceMode = snapshot.selectedEntrySourceMode
    agendaMode = snapshot.agendaMode
    runsAndReviewPage = snapshot.runsAndReviewPage
    selectedAgendaItemID = snapshot.selectedAgendaItemID
    agendaSelectionAnchor = selectedAgendaItemID.flatMap { selectedID in
      visibleAgendaItems.first(where: { $0.id == selectedID }).map(AgendaSelectionAnchor.init)
    }
    selectedAssignedWorkItemID = snapshot.selectedAssignedWorkItemID
    selectedApprovalItemID = snapshot.selectedApprovalItemID
    selectedAgentRunID = snapshot.selectedAgentRunID
    selectedAgentWorkflowID = snapshot.selectedAgentWorkflowID
    selectedAgentGoalID = snapshot.selectedAgentGoalID
    selectedAgentProfileID = snapshot.selectedAgentProfileID
    selectedCorpusFileID = snapshot.selectedCorpusFileID
    selectedMeetingID = snapshot.selectedMeetingID
    selectedExternalThreadID = snapshot.selectedExternalThreadID
    selectedWorkspaceSkillID = snapshot.selectedWorkspaceSkillID
    if let threadID = snapshot.selectedAIChatThreadID,
       aiChatThreads.contains(where: { $0.id == threadID }) {
      selectAIChatThread(threadID, persistsSelection: false)
    } else {
      selectedAIChatThreadID = nil
    }
  }

  private func restoreWorkspacePaneLayout(from snapshot: WorkspaceNavigationSnapshot) {
    expandedWorkspaceSurface = snapshot.expandedWorkspaceSurface
    isWorkspaceSurfacePaneClosed = snapshot.isWorkspaceSurfacePaneClosed
    isWorkspaceDetailPaneClosed = snapshot.isWorkspaceDetailPaneClosed
    isWorkspaceDetailPaneExpanded = snapshot.isWorkspaceDetailPaneExpanded
    isAIChatAssistantPresented = snapshot.isAIChatAssistantPresented
    isNodeContextPanePresented = snapshot.isNodeContextPanePresented
    activeWorkspacePane = snapshot.activeWorkspacePane
    if snapshot.isNodeContextPanePresented, let selectedLocation {
      scheduleBacklinksLoad(for: selectedLocation)
    } else {
      cancelBacklinksLoad(clearResults: false)
    }
  }

  func clearDetailForNavigation() {
    persistLiveFileEditorDraftBeforeNavigation()
    cancelLiveFileEditorAutosave(resetStatus: false)
    selectedLocation = nil
    missingDailyNote = nil
    presentedAgentRunID = nil
    presentedWebPageURL = nil
    cancelSourceEditorPreviewRender(clearStatus: true)
    cancelLinkedPDFPreview(clearStatus: true)
    selectedEntrySource = nil
    selectedEntryHTML = nil
    selectedEntryRenderError = nil
    selectedEntryHTMLRenderKey = nil
    selectedRenderedBlocks = []
    detailScrollRequest = nil
    entryHTMLRenderTask?.cancel()
    entryHTMLRenderTask = nil
    entryHTMLRenderWatchdogTask?.cancel()
    entryHTMLRenderWatchdogTask = nil
    isRenderingEntrySource = false
    entrySourceLoadWatchdogTask?.cancel()
    entrySourceLoadWatchdogTask = nil
    selectedDetailFreshnessTask?.cancel()
    selectedDetailFreshnessTask = nil
    activeEntrySourceLoadingGeneration = nil
    isLoadingEntrySource = false
    entrySourceLoadGeneration += 1
    cancelBacklinksLoad(clearResults: true)
    isEditingEntry = false
    replaceEditableEntryTextFromModel("")
    sourceEditorSelection = NSRange(location: 0, length: 0)
    resetBlockState()
    entryHTMLRenderGeneration += 1
  }

  private func resolvedEntrySourceMode(
    for location: WorkspaceLocation,
    requestedMode: EntrySourceMode?
  ) -> EntrySourceMode {
    if let requestedMode {
      return requestedMode
    }
    if case .meeting = location {
      return .page
    }
    return .entry
  }

  private func canReuseActiveDetail(for location: WorkspaceLocation, mode: EntrySourceMode) -> Bool {
    guard let selectedLocation,
          Self.selectionIdentity(for: selectedLocation) == Self.selectionIdentity(for: location),
          selectedEntrySourceMode == mode
    else {
      return false
    }
    if Self.isPDFFile(location.file) {
      return linkedPDFPreviewData != nil || isLoadingLinkedPDFPreview
    }
    if Self.isMediaFile(location.file) {
      return true
    }
    return selectedEntrySource != nil || isRenderingEntrySource
  }

  func scheduleSelectedDetailFreshnessCheck(
    for location: WorkspaceLocation,
    mode: EntrySourceMode
  ) {
    guard !Self.isNativePreviewFile(location.file),
          editingBlockID == nil,
          !isEditingEntry,
          (!isLiveFileEditorSelected || !liveFileEditorHasUnsavedChanges)
    else { return }

    selectedDetailFreshnessTask?.cancel()
    selectedDetailFreshnessTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let isCurrent = await self.cachedEntrySourceMatchesCurrentFileContents(
        for: location,
        mode: mode
      )
      guard !Task.isCancelled,
            self.selectedLocationMatches(location),
            self.selectedEntrySourceMode == mode
      else { return }
      self.selectedDetailFreshnessTask = nil
      guard !isCurrent else { return }
      self.invalidateCanonicalDocumentCache(for: location.file)
      await self.loadEntrySource(for: location)
    }
  }

  private func applyDetailSelectionMetadata(for location: WorkspaceLocation) {
    if case .agenda(let item) = location {
      if selectedAgendaItemID != item.id {
        selectedAgendaItemID = item.id
      }
      agendaSelectionAnchor = AgendaSelectionAnchor(item: item)
    }
    if case .assigned(let item) = location {
      if selectedAssignedWorkItemID != item.id {
        selectedAssignedWorkItemID = item.id
      }
    }
    if case .aiChatThreadRecord(let thread) = location {
      if selectedAIChatThreadRecordID != thread.id {
        selectedAIChatThreadRecordID = thread.id
      }
    }
    if case .meeting(let meeting) = location {
      if selectedMeetingID != meeting.id {
        selectedMeetingID = meeting.id
      }
    }
  }

  public func loadEntrySource(for location: WorkspaceLocation) async {
    if Self.isPDFFile(location.file) {
      linkedPDFLoadGeneration += 1
      await loadLinkedPDFPreview(for: location, generation: linkedPDFLoadGeneration)
      return
    }
    if Self.isMediaFile(location.file) {
      return
    }
    entrySourceLoadGeneration += 1
    let generation = entrySourceLoadGeneration
    await loadEntrySource(for: location, generation: generation, recoveryAttempt: 0)
  }

  func scheduleEntrySourceLoad(for location: WorkspaceLocation) {
    entrySourceLoadGeneration += 1
    let generation = entrySourceLoadGeneration
    applyCachedEntrySourceIfAvailable(for: location, generation: generation)
    Task { await loadEntrySource(for: location, generation: generation, recoveryAttempt: 0) }
  }

  func refreshSelectedMediaPreview(for changedPaths: [String]) {
    guard let selectedLocation,
          Self.isMediaFile(selectedLocation.file),
          changedPaths.contains(URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path)
    else { return }
    linkedMediaPreviewRevision &+= 1
  }

  public func retryLinkedMediaPreview() {
    linkedMediaPreviewRevision &+= 1
  }

  func scheduleSelectedPDFPreviewRefresh(for changedPaths: [String]) {
    guard let selectedLocation,
          Self.isPDFFile(selectedLocation.file),
          changedPaths.contains(URL(fileURLWithPath: selectedLocation.file).standardizedFileURL.path)
    else { return }
    scheduleLinkedPDFPreviewLoad(
      for: selectedLocation,
      delayNanoseconds: 150_000_000,
      isBackgroundRefresh: true
    )
  }

  private func scheduleLinkedPDFPreviewLoad(
    for location: WorkspaceLocation,
    delayNanoseconds: UInt64 = 0,
    isBackgroundRefresh: Bool = false
  ) {
    linkedPDFLoadTask?.cancel()
    linkedPDFLoadGeneration += 1
    let generation = linkedPDFLoadGeneration
    linkedPDFLoadTask = Task { @MainActor [weak self] in
      if delayNanoseconds > 0 {
        do {
          try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
          return
        }
      }
      await self?.loadLinkedPDFPreview(
        for: location,
        generation: generation,
        isBackgroundRefresh: isBackgroundRefresh
      )
    }
  }

  private func loadLinkedPDFPreview(
    for location: WorkspaceLocation,
    generation: Int,
    isBackgroundRefresh: Bool = false
  ) async {
    guard generation == linkedPDFLoadGeneration,
          selectedLocationMatches(location),
          Self.isPDFFile(location.file)
    else { return }

    isLoadingLinkedPDFPreview = true
    linkedPDFPreviewError = nil
    defer {
      if generation == linkedPDFLoadGeneration {
        isLoadingLinkedPDFPreview = false
        linkedPDFLoadTask = nil
      }
    }

    do {
      let url = URL(fileURLWithPath: location.file).standardizedFileURL
      let loader = linkedPDFDataLoaderForTesting
      let data = try await Task.detached(priority: .userInitiated) {
        if let loader {
          return try await loader(url)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
      }.value
      guard data.starts(with: Data("%PDF".utf8)) else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [
          NSLocalizedDescriptionKey: "\(relativePath(location.file)) is not a complete PDF file (it may still be syncing)."
        ])
      }
      guard generation == linkedPDFLoadGeneration,
            selectedLocationMatches(location)
      else { return }
      let clearsSharedError = !isBackgroundRefresh
        || errorText?.hasPrefix("The linked PDF could not be loaded") == true
      linkedPDFPreviewData = data
      linkedPDFPreviewError = nil
      if clearsSharedError {
        errorText = nil
        statusText = "Opened \(relativePath(location.file))"
      }
    } catch is CancellationError {
      return
    } catch {
      guard generation == linkedPDFLoadGeneration,
            selectedLocationMatches(location)
      else { return }
      if isBackgroundRefresh {
        // File-watcher refreshes fire while the user is elsewhere (for example
        // in a chat) and often observe a partially synced or rewritten file.
        // Keep the last good preview and never raise the global error banner;
        // the next file event or an explicit open retries the load.
        if linkedPDFPreviewData == nil {
          linkedPDFPreviewError = "The linked PDF could not be loaded: \(error.localizedDescription)"
        }
        return
      }
      linkedPDFPreviewData = nil
      linkedPDFPreviewError = "The linked PDF could not be loaded: \(error.localizedDescription)"
      errorText = linkedPDFPreviewError
      statusText = "PDF preview failed"
    }
  }

  public func retryLinkedPDFPreview() {
    guard let selectedLocation, Self.isPDFFile(selectedLocation.file) else { return }
    scheduleLinkedPDFPreviewLoad(for: selectedLocation)
  }

  public func cancelLinkedPDFPreview() {
    cancelLinkedPDFPreview(clearStatus: false)
    linkedPDFPreviewError = "PDF loading stopped. The file is unchanged; retry the preview when ready."
    statusText = "PDF loading stopped"
  }

  private func cancelLinkedPDFPreview(clearStatus: Bool) {
    linkedPDFLoadTask?.cancel()
    linkedPDFLoadTask = nil
    linkedPDFLoadGeneration += 1
    isLoadingLinkedPDFPreview = false
    if clearStatus {
      linkedPDFPreviewData = nil
      linkedPDFPreviewError = nil
    }
  }

  func loadEntrySource(
    for location: WorkspaceLocation,
    generation: Int,
    recoveryAttempt: Int
  ) async {
    guard generation == entrySourceLoadGeneration else { return }
    if URL(fileURLWithPath: location.file).pathExtension.lowercased() == "canvas" {
      selectedEntrySource = nil
      selectedEntryHTML = nil
      isLoadingEntrySource = false
      isRenderingEntrySource = false
      return
    }
    activeEntrySourceLoadingGeneration = generation
    isLoadingEntrySource = true
    isRenderingEntrySource = false
    scheduleEntrySourceLoadWatchdog(
      for: location,
      generation: generation,
      recoveryAttempt: recoveryAttempt
    )
    defer {
      if activeEntrySourceLoadingGeneration == generation {
        entrySourceLoadWatchdogTask?.cancel()
        entrySourceLoadWatchdogTask = nil
        activeEntrySourceLoadingGeneration = nil
        isLoadingEntrySource = false
      }
    }

    do {
      let mode = selectedEntrySourceMode
      let testLoader = entrySourceLoaderForTesting
      let stylesheetRoot = corpusRoot
      let stylesheetPreparation = appHTMLStylesheetSnapshotPreparationForTesting
      let loaded = try await Task.detached(priority: .userInitiated) {
        let source: EntrySource
        if let testLoader {
          source = try await testLoader(location.file, location.lineForEditor, mode)
        } else {
          switch mode {
          case .entry:
            source = try Self.entrySource(file: location.file, line: location.lineForEditor)
          case .page:
            source = try Self.pageSource(file: location.file)
          }
        }
        let fileURL = URL(fileURLWithPath: source.file).standardizedFileURL
        if let stylesheetRoot, let stylesheetPreparation {
          await stylesheetPreparation(stylesheetRoot)
        }
        return EntrySourceLoadResult(
          source: source,
          fileContentDigest: Self.fileContentDigest(for: fileURL),
          fileFreshnessSignature: Self.fileFreshnessSignature(for: fileURL),
          appHTMLStylesheetSnapshot: Self.loadAppHTMLStylesheetSnapshot(
            corpusRoot: stylesheetRoot
          ),
          firstOrgID: Self.firstOrgID(in: source.text),
          sourceLineIndex: OrgSourceLineIndex(text: source.text as NSString)
        )
      }.value
      let source = loaded.source
      guard generation == entrySourceLoadGeneration,
            selectedLocationMatches(location)
      else {
        return
      }
      publishAppHTMLStylesheetSnapshot(loaded.appHTMLStylesheetSnapshot)
      cacheEntrySource(
        source,
        for: location,
        mode: mode,
        modifiedAt: loaded.fileFreshnessSignature?.contentModificationDate,
        fileContentDigest: loaded.fileContentDigest,
        fileFreshnessSignature: loaded.fileFreshnessSignature,
        firstOrgID: loaded.firstOrgID,
        sourceLineIndex: loaded.sourceLineIndex
      )
      guard !shouldDeferEntrySourceApplicationDuringActiveEdit(for: location) else {
        return
      }
      let previousSource = selectedEntrySource
      nextSelectedEntrySourceRenderIdentity = loaded.fileContentDigest.map {
        "file:\($0)|\(source.startLine)|\(source.endLineExclusive)"
      }
      nextSelectedEntrySourceLineIndex = loaded.sourceLineIndex
      nextSelectedEntrySourceModifiedAt = loaded.fileFreshnessSignature?.contentModificationDate
      selectedEntrySource = source
      noteDocumentReady(for: location, cached: false)
      if location.idValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
         let id = loaded.firstOrgID {
        applyResolvedID(id, to: location)
      }
      updateEditableEntryTextFromLoadedSourceIfSafe(source, previousSource: previousSource)
      renderEntrySource(source, generation: generation)
    } catch {
      guard generation == entrySourceLoadGeneration,
            selectedLocationMatches(location)
      else {
        return
      }
      selectedEntrySource = nil
      selectedEntryHTML = nil
      selectedEntryRenderError = error.localizedDescription
      selectedEntryHTMLRenderKey = nil
      selectedRenderedBlocks = []
      selectedBlockID = nil
      isRenderingEntrySource = false
      errorText = error.localizedDescription
    }
  }

  private func scheduleEntrySourceLoadWatchdog(
    for location: WorkspaceLocation,
    generation: Int,
    recoveryAttempt: Int
  ) {
    entrySourceLoadWatchdogTask?.cancel()
    let timeout = entrySourceLoadTimeoutNanoseconds
    entrySourceLoadWatchdogTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: timeout)
      } catch {
        return
      }
      guard let self,
            generation == self.entrySourceLoadGeneration,
            self.isLoadingEntrySource,
            self.selectedEntrySource == nil,
            self.selectedLocationMatches(location)
      else {
        return
      }

      self.entrySourceLoadGeneration += 1
      let nextGeneration = self.entrySourceLoadGeneration
      self.activeEntrySourceLoadingGeneration = nil
      self.isLoadingEntrySource = false
      self.entrySourceLoadWatchdogTask = nil

      if recoveryAttempt == 0 {
        self.statusText = "Source load stalled; retrying"
        Task {
          await self.loadEntrySource(
            for: location,
            generation: nextGeneration,
            recoveryAttempt: 1
          )
        }
      } else {
        let message = "Source loading timed out. Reload the entry to try again."
        self.selectedEntryRenderError = message
        self.errorText = message
        self.statusText = "Source load failed"
      }
    }
  }

  private func applyCachedEntrySourceIfAvailable(for location: WorkspaceLocation, generation: Int) {
    let mode = selectedEntrySourceMode
    guard let cached = cachedEntrySource(for: location, mode: mode) else { return }
    let source = cached.source
    guard !shouldDeferEntrySourceApplicationDuringActiveEdit(for: location) else {
      return
    }
    let previousSource = selectedEntrySource
    nextSelectedEntrySourceRenderIdentity = cached.fileContentDigest.map {
      "file:\($0)|\(source.startLine)|\(source.endLineExclusive)"
    }
    nextSelectedEntrySourceLineIndex = cached.sourceLineIndex
    nextSelectedEntrySourceModifiedAt = cached.modifiedAt
    selectedEntrySource = source
    noteDocumentReady(for: location, cached: true)
    updateEditableEntryTextFromLoadedSourceIfSafe(source, previousSource: previousSource)
    renderEntrySource(source, generation: generation)
  }

  private func shouldDeferEntrySourceApplicationDuringActiveEdit(for location: WorkspaceLocation) -> Bool {
    guard selectedLocationMatches(location), selectedEntrySource != nil else { return false }
    if editingBlockID != nil { return true }
    if isEditingEntry { return true }
    if isLiveFileEditorSelected && liveFileEditorHasUnsavedChanges {
      return true
    }
    return false
  }

  func updateEditableEntryTextFromLoadedSourceIfSafe(_ source: EntrySource, previousSource: EntrySource?) {
    if isEditingEntry {
      let hadUnsavedChanges = sourceEditorDraftGeneration != sourceEditorSavedDraftGeneration
      if !hadUnsavedChanges {
        replaceEditableEntryTextFromModel(source.text)
      }
    } else if isLiveFileEditorSelected {
      let hadUnsavedChanges = liveFileEditorDraftGeneration != liveFileEditorSavedDraftGeneration
      guard !hadUnsavedChanges else { return }
      replaceEditableEntryTextFromModel(source.text)
    }
  }

  public func reloadSelectedEntrySource() async {
    let checkpointedDocumentIdentities = OrgSyntaxTextEditorLifecycle.checkpointPendingTextChanges()
    persistLiveFileEditorDraftBeforeNavigation(
      checkpointedDocumentIdentities: checkpointedDocumentIdentities
    )
    cancelLiveFileEditorAutosave(resetStatus: false)
    await OrgSyntaxTextEditorLifecycle.waitForPendingTextCheckpoints()
    guard await awaitPendingEditorPersistence() else {
      statusText = "Could not save the current editor draft before reloading"
      return
    }
    isEditingEntry = false
    replaceEditableEntryTextFromModel("")
    detailScrollRequest = nil
    resetBlockState()
    guard let selectedLocation else { return }
    await loadEntrySource(for: selectedLocation)
  }

  public func cancelSelectedEntryLoading() {
    guard isLoadingEntrySource || isRenderingEntrySource else { return }
    entrySourceLoadGeneration += 1
    entryHTMLRenderGeneration += 1
    entrySourceLoadWatchdogTask?.cancel()
    entrySourceLoadWatchdogTask = nil
    entryHTMLRenderWatchdogTask?.cancel()
    entryHTMLRenderWatchdogTask = nil
    entryHTMLRenderTask?.cancel()
    entryHTMLRenderTask = nil
    activeEntrySourceLoadingGeneration = nil
    isLoadingEntrySource = false
    isRenderingEntrySource = false
    selectedEntryHTML = nil
    let message = "Loading stopped. The file is unchanged; retry the preview when ready."
    selectedEntryRenderError = message
    statusText = "Preview loading stopped"
  }

  func updateSelectedFileDataNotebookState(
    for file: String?,
    sourceText: String?
  ) {
    selectedFileMetadataGeneration &+= 1
    let generation = selectedFileMetadataGeneration
    let sessionGeneration = corpusSessionGeneration
    selectedFileDataNotebookTask?.cancel()
    selectedFileDataNotebookTask = nil
    guard let file else {
      selectedFileIsDataNotebook = false
      return
    }

    let url = URL(fileURLWithPath: file).standardizedFileURL
    selectedFileIsDataNotebook = false
    let inspection = selectedFileDataNotebookInspectionForTesting
    let didInspect = selectedFileDataNotebookDidInspectForTesting
    selectedFileDataNotebookTask = Task { @MainActor [weak self] in
      let isNotebook = await Task.detached(priority: .utility) {
        didInspect?(Self.currentThreadIsMainForTesting())
        if let inspection {
          return await inspection(url, sourceText)
        }
        if let sourceText {
          return Self.isDataNotebookText(sourceText)
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return Self.isDataNotebookText(text)
      }.value
      let isStillSelected = [self?.selectedLocation?.file, self?.selectedEntrySource?.file]
        .compactMap { $0 }
        .contains(where: {
          URL(fileURLWithPath: $0).standardizedFileURL.path == url.path
        })
      guard let self,
            !Task.isCancelled,
            self.selectedFileMetadataGeneration == generation,
            self.corpusSessionGeneration == sessionGeneration,
            isStillSelected
      else { return }
      self.selectedFileIsDataNotebook = isNotebook
      self.selectedFileDataNotebookTask = nil
    }
  }

  nonisolated private static func isDataNotebookText(_ text: String) -> Bool {
    text.range(
      of: #"```sql[^\n]*\bresults\s*="#,
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }

  /// Keeps test-only thread probes synchronous so Swift 6 does not treat
  /// `Thread.current` access as an unavailable async operation.
  nonisolated static func currentThreadIsMainForTesting() -> Bool {
    Thread.isMainThread
  }

  public var canRefreshSelectedDataNotebook: Bool {
    selectedFileIsDataNotebook
      && !hasActiveEdit
      && !liveFileEditorHasUnsavedChanges
      && !isLoadingEntrySource
      && !isRefreshingDataNotebook
  }

  nonisolated static func dataNotebookRefreshArguments(for file: String) -> [String] {
    [
      "query-data",
      "--file", file,
      "--all-results",
      "--apply",
      "--format", "json"
    ]
  }

  nonisolated static func dataNotebookLocationByRefreshingModificationDate(
    _ location: WorkspaceLocation?,
    file: String,
    modifiedAt: Date?
  ) -> WorkspaceLocation? {
    guard case .aiChatThreadRecord(let thread)? = location,
          URL(fileURLWithPath: thread.file).standardizedFileURL.path
            == URL(fileURLWithPath: file).standardizedFileURL.path
    else {
      return location
    }
    return .aiChatThreadRecord(AIChatThreadRecord(
      title: thread.title,
      file: thread.file,
      line: thread.lineForEditor,
      zone: thread.zone,
      modifiedAt: modifiedAt,
      idValue: thread.idValue
    ))
  }

  private func refreshSelectedDataNotebookModificationDate(for file: String) async {
    let url = URL(fileURLWithPath: file).standardizedFileURL
    let modifiedAt = await Task.detached(priority: .utility) {
      Self.modificationDate(for: url)
    }.value
    let refreshedLocation = Self.dataNotebookLocationByRefreshingModificationDate(
      selectedLocation,
      file: file,
      modifiedAt: modifiedAt
    )
    guard refreshedLocation != selectedLocation else { return }
    selectedLocation = refreshedLocation
  }

  public func refreshSelectedDataNotebook() async {
    if !selectedFileIsDataNotebook,
       let pendingInspection = selectedFileDataNotebookTask {
      await pendingInspection.value
    }
    guard canRefreshSelectedDataNotebook,
          let file = selectedEntrySource?.file ?? selectedLocation?.file
    else {
      statusText = "Open a saved data notebook to refresh it"
      return
    }

    isRefreshingDataNotebook = true
    dataNotebookRefreshFailure = nil
    errorText = nil
    statusText = "Refreshing data…"
    defer { isRefreshingDataNotebook = false }

    do {
      let environment = dataSourceEnvironment()
      guard let context = captureDocumentCorpusContext(forFile: file) else {
        throw WorkspaceDocumentMutationError.outsideCorpus(
          file: file,
          root: corpusRoot?.path ?? "(none)"
        )
      }
      let cli = self.cli
      let result: DataQueryApplyPayload = try await performDocumentMutation(
        context: context,
        files: [file]
      ) { _ in
        try await cli.runJSON(
          Self.dataNotebookRefreshArguments(for: file),
          environment: environment
        )
      }
      guard isCurrentDocumentCorpusContext(context) else { return }

      invalidateCanonicalDocumentCache(for: file)
      await refreshSelectedDataNotebookModificationDate(for: file)
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      await refreshCorpusFiles()
      dataNotebookRefreshFailure = nil
      statusText = result.changedResultCount == 0
        ? "Data is already current"
        : "Refreshed \(result.changedResultCount) of \(result.resultCount) data results"
    } catch {
      let message = error.localizedDescription
      let failure = Self.dataNotebookRefreshFailure(for: message)
      dataNotebookRefreshFailure = failure
      errorText = message
      statusText = failure.title
      if failure.needsCredentialUpdate {
        presentScarfMetabaseConfiguration()
      }
    }
  }

  public func presentScarfMetabaseConfiguration() {
    dataSourceConfigurationError = nil
    scarfMetabaseHasStoredAPIKey = DataSourceCredentialsKeychain.containsScarfMetabaseAPIKey()
    isDataSourceConfigurationPresented = true
  }

  public func dismissDataNotebookRefreshFailure() {
    dataNotebookRefreshFailure = nil
  }

  nonisolated static func dataNotebookRefreshFailure(for rawMessage: String) -> DataNotebookRefreshFailure {
    let message = rawMessage
      .replacingOccurrences(of: #"^Error:\s*"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = message.lowercased()
    let authenticationFailure = normalized.contains("authentication failed")
      || normalized.contains("http 401")
      || normalized.contains("http 403")
      || normalized.contains("unauthorized")
      || normalized.contains("invalid api key")
    if authenticationFailure {
      return DataNotebookRefreshFailure(
        kind: .authentication,
        title: "Metabase authentication failed",
        message: "Metabase rejected the saved API key or it lacks permission. Enter a current API key, then retry the refresh."
      )
    }

    if normalized.contains("scarf_metabase_api_key") {
      return DataNotebookRefreshFailure(
        kind: .configuration,
        title: "Metabase credentials required",
        message: "Add the Metabase API key used by this notebook, then retry the refresh."
      )
    }

    let databaseConfigurationFailure = normalized.contains("scarf_metabase_database_id")
      || normalized.contains("requires a positive metabase databaseid")
    if databaseConfigurationFailure {
      return DataNotebookRefreshFailure(
        kind: .query,
        title: "Notebook data source is misconfigured",
        message: "The Metabase profile needs a positive numeric databaseId in celorga.json. Database IDs are non-secret and should not be stored as app credentials."
      )
    }

    return DataNotebookRefreshFailure(
      kind: .query,
      title: "Data refresh failed",
      message: message.isEmpty ? "The data query failed without an error message." : message
    )
  }

  @discardableResult
  public func saveScarfMetabaseConfiguration(
    apiKey: String,
    clearAPIKey: Bool
  ) -> Bool {
    dataSourceConfigurationError = nil
    let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let requiresNewAPIKey = dataNotebookRefreshFailure?.kind == .authentication
      || (dataNotebookRefreshFailure?.kind == .configuration && !scarfMetabaseHasStoredAPIKey)
    if requiresNewAPIKey,
       (normalizedAPIKey.isEmpty || clearAPIKey) {
      let message = dataNotebookRefreshFailure?.kind == .authentication
        ? "Enter a new Metabase API key to replace the key that was rejected."
        : "Enter a Metabase API key."
      dataSourceConfigurationError = message
      errorText = message
      return false
    }

    do {
      if clearAPIKey {
        try DataSourceCredentialsKeychain.deleteScarfMetabaseAPIKey()
      } else {
        if !normalizedAPIKey.isEmpty {
          try DataSourceCredentialsKeychain.saveScarfMetabaseAPIKey(normalizedAPIKey)
        }
      }
      scarfMetabaseHasStoredAPIKey = DataSourceCredentialsKeychain.containsScarfMetabaseAPIKey()
      dataNotebookRefreshFailure = nil
      dataSourceConfigurationError = nil
      errorText = nil
      statusText = "Saved data refresh credentials"
      return true
    } catch {
      dataSourceConfigurationError = error.localizedDescription
      errorText = error.localizedDescription
      statusText = "Could not save data refresh credentials"
      return false
    }
  }

  private func dataSourceEnvironment() -> [String: String] {
    var environment: [String: String] = [:]
    if ProcessInfo.processInfo.environment["SCARF_METABASE_API_KEY"]?.isEmpty != false,
       let apiKey = DataSourceCredentialsKeychain.readScarfMetabaseAPIKey() {
      environment["SCARF_METABASE_API_KEY"] = apiKey
    }
    return environment
  }

  public func linkConnectionMention(_ mention: NodeUnlinkedMention, target: String, root: String) async throws {
    guard corpusRoot?.path == root,
          let context = captureDocumentCorpusContext(forFile: mention.file),
          context.mutationRootPath == root else {
      throw WorkspaceDocumentMutationError.outsideCorpus(file: mention.file, root: root)
    }
    if selectedEntrySource?.file == mention.file && (hasActiveEdit || liveFileEditorHasUnsavedChanges) {
      throw NSError(domain: "OpenOrg.Connections", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish editing this source, then refresh connections before linking."])
    }
    let cli = self.cli
    let result: NodeMentionLinkPayload = try await performDocumentMutation(context: context, files: [mention.file]) { _ in
      try await cli.runJSON([
        "roam", "mention-link", "--dir", root, "--file", mention.file,
        "--mention", mention.id, "--target", target, "--if-revision", mention.revision,
        "--apply", "--format", "json"
      ])
    }
    guard isCurrentDocumentCorpusContext(context) else { return }
    if result.applied {
      invalidateCanonicalDocumentCache(for: mention.file)
      if let selectedLocation { await loadEntrySource(for: selectedLocation) }
      await refreshCorpusFiles()
      if let selectedLocation { await loadBacklinks(for: selectedLocation) }
      statusText = "Linked ‘\(mention.text)’ in \(relativePath(mention.file))"
    }
  }

  public func linkifyCurrentFile() async {
    guard !selectedFileIsCanvas else {
      statusText = "Edit Canvas connections on the board"
      return
    }
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    guard let file = selectedEntrySource?.file ?? selectedLocation?.file else {
      statusText = "Open a file first"
      return
    }

    do {
      guard let context = captureDocumentCorpusContext(forFile: file) else {
        throw WorkspaceDocumentMutationError.outsideCorpus(file: file, root: corpusRoot.path)
      }
      let cli = self.cli
      let payload: RoamLinkifyPayload = try await performDocumentMutation(
        context: context,
        files: [file]
      ) { _ in
        try await cli.runJSON([
          "roam", "linkify",
          "--dir", corpusRoot.path,
          "--recursive",
          "--file", file,
          "--apply",
          "--format", "json"
        ])
      }
      guard isCurrentDocumentCorpusContext(context) else { return }
      invalidateCanonicalDocumentCache(for: file)
      if let selectedLocation {
        await loadEntrySource(for: selectedLocation)
      }
      await refreshCorpusFiles()
      let relative = relativePath(file)
      statusText = payload.replacementCount > 0
        ? "Linkified \(relative): \(payload.replacementCount) link\(payload.replacementCount == 1 ? "" : "s")"
        : "No linkify changes in \(relative)"
      if payload.ambiguousSkipCount > 0 || payload.representedSuggestionCount > 0 {
        statusText += " (\(payload.ambiguousSkipCount) ambiguous, \(payload.representedSuggestionCount) suggestions)"
      }
    } catch {
      errorText = error.localizedDescription
      statusText = "Linkify failed"
    }
  }

  public func beginEditingSelectedEntry(initialSelection: NSRange? = nil) {
    guard let source = selectedEntrySource, source.isEditable else {
      statusText = "No editable source loaded"
      return
    }
    prepareSourceEditor(
      source: source,
      initialSelection: initialSelection,
      initialSourceLine: nil,
      block: nil
    )
  }

  private func prepareSourceEditor(
    source: EntrySource,
    initialSelection: NSRange?,
    initialSourceLine: Int?,
    block: OrgEditableBlock?
  ) {
    sourceEditorPreparationTask?.cancel()
    sourceEditorPreparationGeneration &+= 1
    let generation = sourceEditorPreparationGeneration

    if let sourceLineIndex = selectedEntrySourceLineIndex {
      finishPreparingSourceEditor(
        source: source,
        sourceLineIndex: sourceLineIndex,
        initialSelection: initialSelection,
        initialSourceLine: initialSourceLine,
        block: block
      )
      return
    }

    // Directly injected/test sources and small locally-created replacements do
    // not pass through the detached file loader. Keep their setup synchronous,
    // but cap the work so a multi-megabyte document can never be scanned on the
    // main actor. Large replacements take the same detached preparation path as
    // normal file loads.
    if OrgEditableInlineToken.boundedUTF16Length(
      in: source.text,
      maxUTF16Length: 65_536
    ) != nil {
      let sourceLineIndex = OrgSourceLineIndex(text: source.text as NSString)
      selectedEntrySourceLineIndex = sourceLineIndex
      finishPreparingSourceEditor(
        source: source,
        sourceLineIndex: sourceLineIndex,
        initialSelection: initialSelection,
        initialSourceLine: initialSourceLine,
        block: block
      )
      return
    }

    sourceEditorPreparationTask = Task { @MainActor [weak self] in
      let sourceLineIndex = await Task.detached(priority: .userInitiated) {
        OrgSourceLineIndex(text: source.text as NSString)
      }.value
      guard !Task.isCancelled,
            let self,
            generation == self.sourceEditorPreparationGeneration,
            self.selectedEntrySource?.id == source.id
      else { return }
      self.sourceEditorPreparationTask = nil
      self.selectedEntrySourceLineIndex = sourceLineIndex
      self.finishPreparingSourceEditor(
        source: source,
        sourceLineIndex: sourceLineIndex,
        initialSelection: initialSelection,
        initialSourceLine: initialSourceLine,
        block: block
      )
    }
  }

  private func finishPreparingSourceEditor(
    source: EntrySource,
    sourceLineIndex: OrgSourceLineIndex,
    initialSelection: NSRange?,
    initialSourceLine: Int?,
    block: OrgEditableBlock?
  ) {
    guard selectedEntrySource?.id == source.id else { return }
    replaceEditableEntryTextFromModel(source.text)
    sourceEditorLocalDraftText = source.text
    let requestedSelection: NSRange
    if let block {
      requestedSelection = Self.sourceEditorSelectionRange(
        for: block,
        in: source,
        sourceLineIndex: sourceLineIndex,
        selection: initialSelection
      )
    } else if let initialSelection {
      requestedSelection = initialSelection
    } else if let initialSourceLine {
      requestedSelection = NSRange(
        location: Self.sourceEditorUTF16Offset(
          forAbsoluteLine: initialSourceLine,
          in: source,
          sourceLineIndex: sourceLineIndex
        ),
        length: 0
      )
    } else if let restoredSourceLine = documentViewportSourceLine(for: source) {
      requestedSelection = NSRange(
        location: Self.sourceEditorUTF16Offset(
          forAbsoluteLine: restoredSourceLine,
          in: source,
          sourceLineIndex: sourceLineIndex
        ),
        length: 0
      )
    } else {
      requestedSelection = NSRange(location: 0, length: 0)
    }
    let initialEditorSelection = Self.clampedSourceEditorSelection(
      requestedSelection,
      utf16Length: sourceLineIndex.documentUTF16Length
    )
    sourceEditorInteraction.reset(text: source.text, selection: initialEditorSelection)
    sourceEditorSavedDraftGeneration = sourceEditorDraftGeneration
    resetBlockState()
    sourceEditorDiagnostics = []
    sourceEditorPreviewHTML = selectedEntryHTML
    sourceEditorPreviewError = nil
    isSourceEditorPreviewPaused = false
    detailScrollRequest = nil
    isEditingEntry = true
  }

  public func requestSourceEditorCommand(_ command: OrgSourceEditorCommand) {
    guard isEditingEntry else {
      statusText = "Open source editing first"
      return
    }
    sourceEditorCommandGeneration += 1
    sourceEditorCommandRequest = OrgSourceEditorCommandRequest(
      id: sourceEditorCommandGeneration,
      command: command
    )
  }

  public func analyzeSourceEditorText(_ text: String) async -> OrgSourceEditorSemanticSnapshot? {
    do {
      return try await cli.analyzeEditorText(text, sourcePath: selectedEntrySource?.file)
    } catch {
      return nil
    }
  }

  public func scheduleSourceEditorPreview(immediate: Bool = false) {
    scheduleSourceEditorPreview(text: editableEntryText, immediate: immediate)
  }

  public func scheduleSourceEditorPreview(text: String, immediate: Bool = false) {
    guard isEditingEntry,
          sourceEditorPresentation == .split,
          !isSourceEditorPreviewPaused,
          let source = selectedEntrySource
    else {
      cancelSourceEditorPreviewRender(clearStatus: false)
      return
    }

    if documentPreviewKind == .slides {
      scheduleSlidePreview(text: text, source: source, immediate: immediate)
      return
    }

    cancelSlidePreviewRender(clearStatus: false)
    sourceEditorPreviewTask?.cancel()
    if isRenderingSourceEditorPreview {
      isRenderingSourceEditorPreview = false
    }
    sourceEditorPreviewGeneration += 1
    let generation = sourceEditorPreviewGeneration
    sourceEditorPreviewTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if !immediate {
        do {
          try await Task.sleep(nanoseconds: Self.sourceEditorPreviewIdleDelayNanoseconds)
        } catch {
          return
        }
      }
      guard !Task.isCancelled,
            generation == self.sourceEditorPreviewGeneration,
            self.isEditingEntry,
            self.sourceEditorPresentation == .split,
            !self.isSourceEditorPreviewPaused,
            self.selectedEntrySource?.id == source.id
      else { return }

      self.isRenderingSourceEditorPreview = true
      self.sourceEditorPreviewError = nil
      do {
        let html = try await self.cli.renderAppHTML(
          text,
          sourcePath: source.file,
          sourceLineOffset: max(0, source.startLine - 1),
          stylesheetPath: self.appHTMLStylesheetPath,
          corpusRootPath: self.corpusRoot?.path
        )
        guard !Task.isCancelled,
              generation == self.sourceEditorPreviewGeneration,
              self.isEditingEntry,
              self.sourceEditorPresentation == .split,
              !self.isSourceEditorPreviewPaused,
              self.selectedEntrySource?.id == source.id
        else { return }
        self.sourceEditorPreviewHTML = Self.applyingPropertyDrawerDefault(
          to: html,
          expanded: self.propertyDrawersExpandedByDefault
        )
        self.sourceEditorPreviewError = nil
      } catch {
        guard generation == self.sourceEditorPreviewGeneration,
              self.isEditingEntry,
              self.sourceEditorPresentation == .split,
              !self.isSourceEditorPreviewPaused,
              self.selectedEntrySource?.id == source.id
        else { return }
        self.sourceEditorPreviewError = error.localizedDescription
      }
      if generation == self.sourceEditorPreviewGeneration {
        self.isRenderingSourceEditorPreview = false
      }
    }
  }

  public var canPreviewSlides: Bool {
    guard let source = selectedEntrySource else { return false }
    return Self.canPreviewSlides(source: source)
  }

  public func setDocumentPreviewPreference(_ preference: OrgDocumentPreviewPreference) {
    guard let source = selectedEntrySource else { return }
    let key = Self.documentViewportKey(for: source)
    documentPreviewPreference = preference
    switch preference {
    case .automatic:
      documentPreviewOverrides.removeValue(forKey: key)
    case .document, .slides:
      documentPreviewOverrides[key] = preference.rawValue
    }
    defaults.set(documentPreviewOverrides, forKey: documentPreviewOverridesKey)
      applyDocumentPreviewPreferenceForSelectedSource()

    if documentPreviewKind == .slides {
      let text = isEditingEntry ? (sourceEditorLocalDraftText ?? editableEntryText) : source.text
      scheduleSlidePreview(text: text, source: source, immediate: true)
    } else if isEditingEntry, sourceEditorPresentation == .split {
      scheduleSourceEditorPreview(immediate: true)
    }
  }

  public var inferredDocumentPreviewKind: OrgDocumentPreviewKind {
    guard let source = selectedEntrySource else { return .document }
    return inferredDocumentPreviewKinds[Self.documentViewportKey(for: source)] ?? .document
  }

  public var documentPreviewPreferenceLabel: String {
    if documentPreviewPreference == .automatic {
      return "Automatic (\(documentPreviewKind.title))"
    }
    return documentPreviewPreference.title
  }

  func applyDocumentPreviewPreferenceForSelectedSource() {
    guard let source = selectedEntrySource else {
      documentPreviewPreference = .automatic
      if documentPreviewKind != .document {
        documentPreviewKind = .document
      }
      return
    }
    let key = Self.documentViewportKey(for: source)
    let preference = documentPreviewOverrides[key]
      .flatMap(OrgDocumentPreviewPreference.init(rawValue:)) ?? .automatic
    documentPreviewPreference = preference

    let preferredKind: OrgDocumentPreviewKind
    switch preference {
    case .automatic:
      preferredKind = inferredDocumentPreviewKinds[key] ?? .document
    case .document:
      preferredKind = .document
    case .slides:
      preferredKind = .slides
    }
    let effectiveKind: OrgDocumentPreviewKind = preferredKind == .slides && Self.canPreviewSlides(source: source)
      ? .slides
      : .document
    if documentPreviewKind != effectiveKind {
      documentPreviewKind = effectiveKind
    }
  }

  func updateInferredDocumentPreviewKind(from html: String?) {
    guard let source = selectedEntrySource,
          let kind = Self.documentPreviewKind(fromAppHTML: html)
    else { return }
    let key = Self.documentViewportKey(for: source)
    inferredDocumentPreviewKinds[key] = kind
    if documentPreviewPreference == .automatic {
      let previousKind = documentPreviewKind
      applyDocumentPreviewPreferenceForSelectedSource()
      if previousKind != documentPreviewKind, documentPreviewKind == .slides {
        let text = isEditingEntry ? (sourceEditorLocalDraftText ?? editableEntryText) : source.text
        scheduleSlidePreview(text: text, source: source, immediate: true)
      }
    }
  }

  nonisolated static func documentPreviewKind(fromAppHTML html: String?) -> OrgDocumentPreviewKind? {
    guard let html else { return nil }
    if html.contains("<meta name=\"org2-document-kind\" content=\"slides\"") {
      return .slides
    }
    if html.contains("<meta name=\"org2-document-kind\" content=\"document\"") {
      return .document
    }
    return nil
  }

  public func zoomSlidePreviewIn() {
    setSlidePreviewZoomScale(Self.nextSlidePreviewZoomScale(after: slidePreviewZoomScale))
  }

  public func zoomSlidePreviewOut() {
    setSlidePreviewZoomScale(Self.previousSlidePreviewZoomScale(before: slidePreviewZoomScale))
  }

  public func resetSlidePreviewZoom() {
    setSlidePreviewZoomScale(1)
  }

  public func setSlidePreviewPageCount(_ count: Int) {
    slidePreviewPageCount = max(0, count)
  }

  func requestSlidePreviewNavigation(_ target: OrgPDFPageNavigationTarget) {
    guard documentPreviewKind == .slides, slidePreviewPageCount > 0 else { return }
    slidePreviewNavigationGeneration += 1
    slidePreviewNavigationRequest = OrgPDFPageNavigationRequest(
      id: slidePreviewNavigationGeneration,
      target: target
    )
  }

  private func setSlidePreviewZoomScale(_ scale: CGFloat) {
    let normalized = min(max(0.25, scale), 4)
    guard abs(normalized - slidePreviewZoomScale) > 0.001 else { return }
    slidePreviewZoomScale = normalized
    if let source = selectedEntrySource {
      slidePreviewZoomScales[Self.documentViewportKey(for: source)] = normalized
    }
  }

  nonisolated private static let slidePreviewZoomSteps: [CGFloat] = [
    0.4, 0.5, 0.625, 0.75, 0.875, 1, 1.25, 1.5, 2, 3, 4,
  ]

  nonisolated static func nextSlidePreviewZoomScale(after scale: CGFloat) -> CGFloat {
    slidePreviewZoomSteps.first(where: { $0 > scale + 0.001 }) ?? slidePreviewZoomSteps.last!
  }

  nonisolated static func previousSlidePreviewZoomScale(before scale: CGFloat) -> CGFloat {
    slidePreviewZoomSteps.last(where: { $0 < scale - 0.001 }) ?? slidePreviewZoomSteps.first!
  }

  public func scheduleSlidePreview(
    text: String,
    source: EntrySource,
    immediate: Bool = false
  ) {
    guard documentPreviewKind == .slides,
          Self.canPreviewSlides(source: source)
    else {
      cancelSlidePreviewRender(clearStatus: false)
      return
    }

    slidePreviewTask?.cancel()
    isRenderingSlidePreview = false
    slidePreviewGeneration += 1
    let generation = slidePreviewGeneration
    if slidePreviewSourceID != source.id {
      slidePreviewSourceID = source.id
      slidePreviewPDF = nil
      slidePreviewError = nil
    }

    slidePreviewTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if !immediate {
        do {
          try await Task.sleep(nanoseconds: Self.slidePreviewIdleDelayNanoseconds)
        } catch {
          return
        }
      }
      guard !Task.isCancelled,
            self.documentPreviewKind == .slides,
            generation == self.slidePreviewGeneration,
            self.selectedEntrySource?.id == source.id
      else { return }

      self.isRenderingSlidePreview = true
      self.slidePreviewError = nil
      do {
        let pdf: Data
        if let renderer = self.slidePreviewRendererForTesting {
          pdf = try await renderer(text, source.file, 1)
        } else {
          pdf = try await self.cli.renderPresentationPDF(
            text,
            sourcePath: source.file,
            sourceLineOffset: max(0, source.startLine - 1),
            passes: 1
          )
        }
        guard !Task.isCancelled,
              generation == self.slidePreviewGeneration,
              self.documentPreviewKind == .slides,
              self.selectedEntrySource?.id == source.id
        else { return }
        self.slidePreviewPDF = pdf
        self.slidePreviewError = nil
      } catch is CancellationError {
        return
      } catch {
        guard generation == self.slidePreviewGeneration,
              self.documentPreviewKind == .slides,
              self.selectedEntrySource?.id == source.id
        else { return }
        self.slidePreviewError = error.localizedDescription
      }
      if generation == self.slidePreviewGeneration {
        self.isRenderingSlidePreview = false
      }
    }
  }

  public func retrySlidePreview() {
    guard let source = selectedEntrySource else { return }
    let text = isEditingEntry ? (sourceEditorLocalDraftText ?? editableEntryText) : source.text
    scheduleSlidePreview(text: text, source: source, immediate: true)
  }

  public func setSourceEditorPreviewPaused(_ paused: Bool) {
    isSourceEditorPreviewPaused = paused
    if paused {
      cancelSourceEditorPreviewRender(clearStatus: false)
    } else {
      scheduleSourceEditorPreview(immediate: true)
    }
  }

  public func showSourceEditorBacklinks(at line: Int) {
    guard isEditingEntry, let source = selectedEntrySource else { return }
    nodeContextTab = .references
    isNodeContextPanePresented = true
    let absoluteLine = source.startLine + max(1, line) - 1
    statusText = "Loading references for line \(absoluteLine)"
    Task { await loadSourceEditorBacklinks(source: source, line: absoluteLine) }
  }

  private func loadSourceEditorBacklinks(source: EntrySource, line: Int) async {
    backlinksLoadTask?.cancel()
    backlinksLoadTask = nil
    backlinksLoadGeneration += 1
    let generation = backlinksLoadGeneration
    guard let corpusRoot else {
      backlinks = nil
      return
    }
    isLoadingBacklinks = true
    defer {
      if generation == backlinksLoadGeneration {
        isLoadingBacklinks = false
      }
    }

    do {
      let lookup: OrgIDLookupPayload = try await cli.runJSON([
        "id", "get",
        "--file", source.file,
        "--line", "\(line)",
        "--format", "json"
      ])
      let payload: BacklinksPayload = try await cli.runJSON([
        "backlinks",
        "--id", lookup.id,
        "--dir", corpusRoot.path,
        "--recursive",
        "--format", "json"
      ])
      guard generation == backlinksLoadGeneration,
            isEditingEntry,
            selectedEntrySource?.id == source.id
      else { return }
      backlinks = payload
      statusText = payload.backlinks.isEmpty
        ? "No references for this heading"
        : "Loaded \(payload.backlinks.count) reference\(payload.backlinks.count == 1 ? "" : "s")"
    } catch {
      guard generation == backlinksLoadGeneration,
            isEditingEntry,
            selectedEntrySource?.id == source.id
      else { return }
      backlinks = nil
      statusText = "This heading has no ID-backed references"
    }
  }

  func cancelSourceEditorPreviewRender(clearStatus: Bool) {
    sourceEditorPreviewTask?.cancel()
    sourceEditorPreviewTask = nil
    sourceEditorPreviewGeneration += 1
    isRenderingSourceEditorPreview = false
    cancelSlidePreviewRender(clearStatus: clearStatus)
    if clearStatus {
      sourceEditorPreviewHTML = nil
      sourceEditorPreviewError = nil
    }
  }

  public func cancelSlidePreview() {
    cancelSlidePreviewRender(clearStatus: false)
  }

  func cancelSlidePreviewRender(clearStatus: Bool) {
    slidePreviewTask?.cancel()
    slidePreviewTask = nil
    slidePreviewGeneration += 1
    isRenderingSlidePreview = false
    if clearStatus {
      slidePreviewPDF = nil
      slidePreviewError = nil
      slidePreviewSourceID = nil
    }
  }

  nonisolated private static func canPreviewSlides(source: EntrySource) -> Bool {
    let extensionName = URL(fileURLWithPath: source.file).pathExtension.lowercased()
    return ["org", "org2"].contains(extensionName)
      && source.startLine == 1
      && !source.isSubtree
  }

  public func beginEditingCurrentScope(atSourceLine sourceLine: Int? = nil) {
    if let sourceLine,
       let source = selectedEntrySource {
      recordDocumentViewportSourceLine(sourceLine, for: source)
      prepareSourceEditor(
        source: source,
        initialSelection: nil,
        initialSourceLine: sourceLine,
        block: nil
      )
      return
    }
    if let selectedBlock {
      beginEditingSource(for: selectedBlock)
      return
    }
    if let sourceLine = currentDocumentViewportSourceLine,
       let source = selectedEntrySource {
      recordDocumentViewportSourceLine(sourceLine, for: source)
      prepareSourceEditor(
        source: source,
        initialSelection: nil,
        initialSourceLine: sourceLine,
        block: nil
      )
      return
    }
    beginEditingSelectedEntry()
  }

  public func beginEditingVisibleBlock() {
    guard selectedEntrySource?.isEditable == true else {
      statusText = "No editable source loaded"
      return
    }

    if let selectedBlock {
      beginEditingSource(for: selectedBlock)
      return
    }

    guard let firstEditableBlock = selectableBlocks.first else {
      beginEditingSelectedEntry()
      return
    }
    beginEditingSource(for: firstEditableBlock)
  }

  public func cancelEditingSelectedEntry() {
    cancelSourceEditorPreviewRender(clearStatus: true)
    let selectedText = selectedEntrySource?.text ?? ""
    replaceEditableEntryTextFromModel(selectedText)
    sourceEditorLocalDraftText = nil
    sourceEditorInteraction.reset(
      text: selectedText,
      selection: NSRange(location: 0, length: 0)
    )
    sourceEditorSavedDraftGeneration = sourceEditorDraftGeneration
    sourceEditorDiagnostics = []
    sourceEditorCommandRequest = nil
    isEditingEntry = false
  }

  public func beginEditingSource(for block: OrgEditableBlock, selection: NSRange? = nil) {
    guard block.isEditable,
          let source = selectedEntrySource,
          source.isEditable
    else {
      statusText = "Block is read-only"
      return
    }
    recordDocumentViewportSourceLine(block.startLine, for: source)
    prepareSourceEditor(
      source: source,
      initialSelection: selection,
      initialSourceLine: nil,
      block: block
    )
  }

  nonisolated static func sourceEditorSelectionRange(
    for block: OrgEditableBlock,
    in source: EntrySource,
    sourceLineIndex: OrgSourceLineIndex,
    selection: NSRange? = nil
  ) -> NSRange {
    let blockStartOffset = sourceEditorUTF16Offset(
      forAbsoluteLine: block.startLine,
      in: source,
      sourceLineIndex: sourceLineIndex
    )
    let sourceLength = sourceLineIndex.documentUTF16Length
    let indexedBlockEnd = sourceEditorUTF16Offset(
      forAbsoluteLine: block.endLineExclusive,
      in: source,
      sourceLineIndex: sourceLineIndex
    )
    let blockLength = OrgEditableInlineToken.boundedUTF16Length(
      in: block.rawText,
      maxUTF16Length: 65_536
    ) ?? max(0, indexedBlockEnd - blockStartOffset)
    let localSelection = selection ?? NSRange(location: 0, length: 0)
    let localLocation = min(max(0, localSelection.location), blockLength)
    let localLength = min(max(0, localSelection.length), max(0, blockLength - localLocation))
    let sourceLocation = min(sourceLength, blockStartOffset + localLocation)
    let sourceLengthRemaining = max(0, sourceLength - sourceLocation)
    return NSRange(
      location: sourceLocation,
      length: min(localLength, sourceLengthRemaining)
    )
  }
}
