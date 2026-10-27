import AppKit
import SwiftUI

struct SearchView: View {
  @Environment(WorkspaceStore.self) private var store
  @FocusState private var isSearchFocused: Bool
  @State private var searchDraft = ""
  @State private var pendingSearchUpdate: Task<Void, Never>?
  @State private var selectedResultID: String?

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Search", subtitle: store.searchMode.subtitle, surface: .search) {
        Button {
          store.promptAndCreateKnowledgeNode()
        } label: {
          Label("New Node", systemImage: "plus.circle")
        }
      }

      searchControls

      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(height: 0.5)

      searchResultsBody
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .background(WorkspaceDesign.surfaceBackground)
    .modifier(QuickOpenKeyboardEventMonitor(handler: handleKeyDown))
    .onAppear {
      searchDraft = store.searchQuery
      store.warmAIChatSearchIndex()
    }
    .task(id: store.searchFocusToken) {
      guard store.selectedSurface == .search else { return }
      isSearchFocused = false
      await Task.yield()
      guard !Task.isCancelled, store.selectedSurface == .search else { return }
      isSearchFocused = true
    }
    .onChange(of: store.searchQuery) {
      if searchDraft != store.searchQuery {
        searchDraft = store.searchQuery
      }
    }
    .onChange(of: searchDraft) {
      selectedResultID = nil
      scheduleSearchUpdate()
    }
    .onChange(of: store.searchMode) {
      selectedResultID = nil
      // A draft still waiting on the debounce belongs to the new mode too.
      // Without one, the store's query is current (it may have just been
      // set by Quick Open) and must not be replaced by an older draft.
      if pendingSearchUpdate != nil {
        applySearchImmediately()
      }
      runTextSearchIfNeeded()
    }
    .onChange(of: store.searchReadScope) {
      runTextSearchIfNeeded()
    }
    .onChange(of: visibleResultIDs) { _, ids in
      if let selectedResultID, !ids.contains(selectedResultID) {
        self.selectedResultID = nil
      }
    }
    .onDisappear { pendingSearchUpdate?.cancel() }
  }

  // MARK: Controls

  private var searchControls: some View {
    @Bindable var store = store
    return VStack(alignment: .leading, spacing: 10) {
      searchField

      HStack(spacing: 8) {
        Picker("Search mode", selection: $store.searchMode) {
          ForEach(WorkspaceSearchMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Text searches everything in the workspace; Nodes matches node titles, aliases, IDs, and paths")

        // Scope only matters when another corpus is mounted.
        if store.searchMode == .text, !store.mountedCorpora.isEmpty {
          Picker("Scope", selection: $store.searchReadScope) {
            ForEach(WorkspaceReadScope.allCases) { scope in
              Text(scope.title).tag(scope)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
          .help("Search the active corpus or every mounted corpus")
        }

        Spacer(minLength: 8)

        if let resultSummary {
          Text(resultSummary)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .controlSize(.small)
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.top, 12)
    .padding(.bottom, 10)
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField(store.searchMode.placeholder, text: $searchDraft)
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused($isSearchFocused)
        .onSubmit {
          submitSearch()
        }

      if store.isSearching {
        WorkspaceActivityIndicator(size: .mini)
          .accessibilityLabel("Searching")
      }

      if !searchDraft.isEmpty {
        Button {
          clearSearch()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help("Clear search")
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .background(WorkspaceDesign.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(
          isSearchFocused ? WorkspaceDesign.structuralAccent.opacity(0.5) : WorkspaceDesign.hairline,
          lineWidth: isSearchFocused ? 1 : 0.5
        )
    )
    .contentShape(Rectangle())
    .onTapGesture { isSearchFocused = true }
  }

  // MARK: Results

  @ViewBuilder
  private var searchResultsBody: some View {
    switch store.searchMode {
    case .text:
      let items = store.workspaceTextSearchItems
      if items.isEmpty {
        if trimmedDraft.isEmpty {
          SearchPlaceholderView(
            systemImage: "magnifyingglass",
            title: store.corpusRoot == nil ? "No Corpus Open" : "Search Your Workspace",
            detail: store.corpusRoot == nil
              ? "Open a corpus to search its org files."
              : "Find TODOs, headings, text, files, pages, AI chats, and agent work.",
            hint: "↑ ↓ to move  ·  Return to open"
          )
        } else if store.isSearching || pendingSearchUpdate != nil {
          SearchPlaceholderView(systemImage: nil, title: "Searching…", detail: nil)
        } else {
          SearchPlaceholderView(
            systemImage: "text.magnifyingglass",
            title: "No Results for “\(trimmedDraft)”",
            detail: noResultsDetail
          ) {
            if store.searchReadScope == .activeCorpus, !store.mountedCorpora.isEmpty {
              Button("Search All Corpora") {
                store.searchReadScope = .allCorpora
              }
              .buttonStyle(WorkspaceActionButtonStyle())
            }
          }
        }
      } else {
        // One list, best match first: quality plus recency decides the
        // order, not the kind of result.
        ScrollViewReader { proxy in
          WorkspaceLazyCollection {
            ForEach(items) { item in
              workspaceSearchRow(item)
            }
          }
          .opacity(resultsAreStale ? 0.6 : 1)
          .onChange(of: selectedResultID) { _, selected in
            if let selected { proxy.scrollTo(selected) }
          }
        }
      }
    case .nodes:
      let nodes = store.searchNodes
      if nodes.isEmpty {
        SearchPlaceholderView(
          systemImage: "doc.richtext",
          title: "No Nodes",
          detail: "\(nodeEmptyStateDetail) Use the toolbar Refresh to rebuild the corpus index."
        )
      } else {
        ScrollViewReader { proxy in
          WorkspaceLazyCollection {
            ForEach(nodes) { node in
              NodeSearchRow(
                node: node,
                sourceReference: store.relativePath(node.file) + ":\(node.line)",
                isSelected: selectedResultID == node.id
              )
              .contentShape(Rectangle())
              .onTapGesture {
                selectedResultID = node.id
                store.selectSearchNode(node)
              }
              .workspaceAccessibleCollectionRow(
                kind: "search-node",
                id: node.id,
                label: Org2Display.cleanInline(node.title),
                isSelected: selectedResultID == node.id,
                open: { store.selectSearchNode(node) }
              )
              .contextMenu {
                NodeSearchContextMenu(node: node)
              }
              .workspaceLazyRow(id: node.id)
            }
          }
          .onChange(of: selectedResultID) { _, selected in
            if let selected { proxy.scrollTo(selected) }
          }
        }
      }
    }
  }

  private var trimmedDraft: String {
    searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Results on screen still answer an earlier query while a new one runs.
  private var resultsAreStale: Bool {
    store.isSearching && trimmedDraft != store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var visibleResultIDs: [String] {
    switch store.searchMode {
    case .text: store.workspaceTextSearchItems.map(\.id)
    case .nodes: store.searchNodes.map(\.id)
    }
  }

  private var resultSummary: String? {
    switch store.searchMode {
    case .text:
      guard !trimmedDraft.isEmpty, !store.isSearching else { return nil }
      let count = store.workspaceTextSearchItems.count
      guard count > 0 else { return nil }
      return "\(count) result\(count == 1 ? "" : "s")"
    case .nodes:
      let count = store.searchNodes.count
      guard count > 0 else { return nil }
      return "\(count) node\(count == 1 ? "" : "s")"
    }
  }

  private var noResultsDetail: String {
    if store.corpusRoot == nil { return "Open a corpus to search its org files." }
    if let error = store.errorText, !error.isEmpty { return error }
    return "Try fewer or different words."
  }

  private var nodeEmptyStateDetail: String {
    if store.corpusRoot == nil { return "Open a corpus to search node titles, aliases, and IDs." }
    if store.orgRoamLinkResolver.nodes.isEmpty {
      return "No nodes are indexed yet. Add org files with file-level titles, IDs, or aliases."
    }
    return "No indexed node matched this query."
  }

  // MARK: Querying

  private func submitSearch() {
    if let selectedResultID, openResult(id: selectedResultID) { return }
    applySearchImmediately()
    guard store.searchMode == .text else { return }
    Task { await store.runSearch() }
  }

  private func clearSearch() {
    searchDraft = ""
    applySearchImmediately()
    runTextSearchIfNeeded(includingEmpty: true)
    isSearchFocused = true
  }

  /// Search as the user types. Text search waits for a short pause and at
  /// least two characters; Return searches any query immediately.
  private func scheduleSearchUpdate() {
    pendingSearchUpdate?.cancel()
    pendingSearchUpdate = nil
    let nextQuery = searchDraft
    guard nextQuery != store.searchQuery else { return }
    let isText = store.searchMode == .text
    let trimmed = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if isText, !trimmed.isEmpty, trimmed.count < WorkspaceSearchInput.liveSearchMinimumLength {
      return
    }
    pendingSearchUpdate = Task { @MainActor in
      let delay = isText ? WorkspaceSearchInput.liveTextSearchDelay : WorkspaceSearchInput.liveNodeSearchDelay
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard !Task.isCancelled else { return }
      pendingSearchUpdate = nil
      store.searchQuery = nextQuery
      if isText, store.searchMode == .text {
        await store.runSearch()
      }
    }
  }

  private func applySearchImmediately() {
    pendingSearchUpdate?.cancel()
    pendingSearchUpdate = nil
    if store.searchQuery != searchDraft {
      store.searchQuery = searchDraft
    }
  }

  private func runTextSearchIfNeeded(includingEmpty: Bool = false) {
    guard store.searchMode == .text else { return }
    let query = store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard includingEmpty || !query.isEmpty else { return }
    Task { await store.runSearch() }
  }

  // MARK: Keyboard

  private func handleKeyDown(_ event: NSEvent) -> Bool {
    guard isSearchFocused,
          store.selectedSurface == .search,
          !store.isQuickOpenPresented,
          event.window?.attachedSheet == nil,
          event.window?.sheetParent == nil
    else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    guard modifiers.isEmpty else { return false }
    switch event.keyCode {
    case 125:
      moveSelection(by: 1)
      return true
    case 126:
      moveSelection(by: -1)
      return true
    case 53:
      if selectedResultID != nil {
        selectedResultID = nil
        return true
      }
      guard !searchDraft.isEmpty else { return false }
      clearSearch()
      return true
    default:
      return false
    }
  }

  private func moveSelection(by offset: Int) {
    selectedResultID = WorkspaceSearchInput.movedSelection(
      from: selectedResultID,
      by: offset,
      in: visibleResultIDs
    )
  }

  @discardableResult
  private func openResult(id: String) -> Bool {
    switch store.searchMode {
    case .text:
      guard let item = store.workspaceTextSearchItems.first(where: { $0.id == id }) else { return false }
      selectSearchItem(item)
    case .nodes:
      guard let node = store.searchNodes.first(where: { $0.id == id }) else { return false }
      store.selectSearchNode(node)
    }
    return true
  }

  // MARK: Rows

  @ViewBuilder
  private func workspaceSearchRow(_ item: WorkspaceTextSearchItem) -> some View {
    let isSelected = selectedResultID == item.id
    let query = store.searchQuery
    Group {
      switch item {
      case .activeTodo(let result), .entry(let result), .corpusText(let result):
        corpusSearchRow(result, item: item, query: query, isSelected: isSelected)
      case .file(let file):
        SearchResultRowLayout(
          systemImage: "doc.text",
          title: file.name,
          snippet: nil,
          query: query,
          metadata: "File · \(file.relativePath)",
          isSelected: isSelected
        )
        .contextMenu {
          CorpusFileContextMenu(file: file)
        }
      case .chatThread(let result), .chatMessage(let result):
        ChatSearchRow(result: result, query: query, isSelected: isSelected)
      case .agentWork(let result):
        AgentWorkSearchRow(result: result, query: query, isSelected: isSelected)
      case .page(let node):
        NodeSearchRow(
          node: node,
          sourceReference: store.relativePath(node.file) + ":\(node.line)",
          isSelected: isSelected,
          kindLabel: "Page"
        )
        .contextMenu {
          NodeSearchContextMenu(node: node)
        }
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      selectedResultID = item.id
      selectSearchItem(item)
    }
    .workspaceAccessibleCollectionRow(
      kind: "search-result",
      id: item.id,
      label: searchAccessibilityLabel(item),
      isSelected: isSelected,
      open: { selectSearchItem(item) }
    )
    .workspaceLazyRow(id: item.id)
  }

  private func corpusSearchRow(
    _ result: SearchResult,
    item: WorkspaceTextSearchItem,
    query: String,
    isSelected: Bool
  ) -> some View {
    let title = Org2Display.cleanInline(result.title)
    let snippet = WorkspaceSearchHighlight.displaySnippet(
      Org2Display.cleanInline(result.snippet),
      title: title,
      todo: result.todo
    )
    let kind: (icon: String, label: String) = switch item {
    case .activeTodo: ("checkmark.circle", "TODO")
    case .entry: ("number", "Heading")
    default: result.todo == nil ? ("text.alignleft", "Text") : ("checkmark.circle", "TODO")
    }
    let location = store.corpusQualifiedPath(result.file, corpus: result.corpus) + ":\(result.lineForEditor)"
    return SearchResultRowLayout(
      systemImage: kind.icon,
      title: title,
      status: result.todo,
      snippet: snippet,
      query: query,
      metadata: "\(kind.label) · \(location)",
      isSelected: isSelected
    )
    .contextMenu {
      WorkspaceLocationContextMenu(
        location: .search(result),
        showsHeadingActions: result.todo != nil && store.isResultInActiveCorpus(result.corpus),
        select: { store.selectSearchResult(result) }
      ) {
        Label("Open", systemImage: "magnifyingglass")
      }
    }
  }

  private func selectSearchItem(_ item: WorkspaceTextSearchItem) {
    switch item {
    case .activeTodo(let result), .entry(let result), .corpusText(let result):
      store.selectSearchResult(result)
    case .file(let file):
      store.selectSearchFile(file)
    case .chatThread(let result), .chatMessage(let result):
      store.selectAIChatSearchResult(result)
    case .agentWork(let result):
      store.selectAgentWorkSearchResult(result)
    case .page(let node):
      store.selectSearchNode(node)
    }
  }

  private func searchAccessibilityLabel(_ item: WorkspaceTextSearchItem) -> String {
    switch item {
    case .activeTodo(let result), .entry(let result), .corpusText(let result):
      Org2Display.cleanInline(result.title)
    case .file(let file):
      file.name
    case .chatThread(let result), .chatMessage(let result):
      result.title
    case .agentWork(let result):
      result.title
    case .page(let node):
      Org2Display.cleanInline(node.title)
    }
  }
}

private struct AgentWorkSearchRow: View {
  let result: WorkspaceAgentWorkSearchResult
  let query: String
  let isSelected: Bool

  var body: some View {
    let snippet = result.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    SearchResultRowLayout(
      systemImage: systemImage,
      title: result.title,
      snippet: snippet.isEmpty ? nil : snippet,
      query: query,
      metadata: "\(result.kind.label) · \(result.sourceReference)",
      isSelected: isSelected
    ) {
      StatusPill(text: result.status.replacingOccurrences(of: "-", with: " ").uppercased())
    }
  }

  private var systemImage: String {
    switch result.kind {
    case .approval: "checkmark.seal"
    case .run: "play.circle"
    case .workflow: "point.3.connected.trianglepath.dotted"
    case .goal: "scope"
    case .agent: "person.crop.circle.badge.checkmark"
    }
  }
}

private struct ChatSearchRow: View {
  let result: AIChatSearchResult
  let query: String
  let isSelected: Bool

  var body: some View {
    SearchResultRowLayout(
      systemImage: "bubble.left.and.bubble.right",
      title: result.title,
      snippet: WorkspaceSearchHighlight.displaySnippet(result.snippet, title: result.title),
      query: query,
      metadata: "AI Chat · \(result.messageCount) message\(result.messageCount == 1 ? "" : "s") · \(Self.relativeDate(result.matchedAt))",
      isSelected: isSelected
    )
  }

  private static func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

private struct NodeSearchRow: View {
  let node: OrgRoamNodeReference
  let sourceReference: String
  var isSelected = false
  var kindLabel = "Node"

  var body: some View {
    let aliases = node.aliases.joined(separator: ", ")
    SearchResultRowLayout(
      systemImage: "doc.richtext",
      title: Org2Display.cleanInline(node.title),
      snippet: aliases.isEmpty ? nil : aliases,
      query: "",
      metadata: "\(kindLabel) · \(sourceReference)",
      isSelected: isSelected
    )
  }
}

/// The one layout every search result shares, so icons, titles, and
/// metadata line up no matter what kind of result a row shows.
private struct SearchResultRowLayout<Accessory: View>: View {
  let systemImage: String
  let title: String
  var status: String?
  let snippet: String?
  let query: String
  let metadata: String
  let isSelected: Bool
  let accessory: Accessory

  init(
    systemImage: String,
    title: String,
    status: String? = nil,
    snippet: String?,
    query: String,
    metadata: String,
    isSelected: Bool,
    @ViewBuilder accessory: () -> Accessory = { EmptyView() }
  ) {
    self.systemImage = systemImage
    self.title = title
    self.status = status
    self.snippet = snippet
    self.query = query
    self.metadata = metadata
    self.isSelected = isSelected
    self.accessory = accessory()
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      WorkspaceIconBadge(systemImage: systemImage)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .center, spacing: 6) {
          if let status {
            StatusPill(text: status)
          }
          Text(title)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 4)
          accessory
        }
        // Center the title line on the 24-point icon badge.
        .frame(minHeight: 24)

        if let snippet, !snippet.isEmpty {
          Text(highlighted(snippet))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text(metadata)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.vertical, 7)
    .workspaceSelectableRow(
      isSelected: isSelected,
      showsSelectionMarker: false,
      leadingPadding: 8,
      trailingPadding: 10
    )
  }

  private func highlighted(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    for range in WorkspaceSearchHighlight.ranges(in: text, query: query) {
      guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed)
      else { continue }
      attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
      attributed[lower..<upper].foregroundColor = WorkspaceDesign.primaryText
    }
    return attributed
  }
}

/// Top-weighted empty, loading, and no-result states for Search, so the
/// message sits near the search field instead of floating mid-pane.
private struct SearchPlaceholderView<Actions: View>: View {
  let systemImage: String?
  let title: String
  let detail: String?
  var hint: String?
  let actions: Actions

  init(
    systemImage: String?,
    title: String,
    detail: String?,
    hint: String? = nil,
    @ViewBuilder actions: () -> Actions = { EmptyView() }
  ) {
    self.systemImage = systemImage
    self.title = title
    self.detail = detail
    self.hint = hint
    self.actions = actions()
  }

  var body: some View {
    VStack(spacing: 10) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 22, weight: .regular))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      } else {
        WorkspaceActivityIndicator(size: .small)
      }
      Text(title)
        .font(.headline)
        .multilineTextAlignment(.center)
        .lineLimit(2)
      if let detail, !detail.isEmpty {
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      actions
      if let hint {
        Text(hint)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: 340)
    .padding(.horizontal, 24)
    .padding(.top, 56)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

private struct NodeSearchContextMenu: View {
  @Environment(WorkspaceStore.self) private var store
  let node: OrgRoamNodeReference

  var body: some View {
    Button {
      store.selectSearchNode(node)
    } label: {
      Label("Open", systemImage: "link")
    }

    Button {
      store.openFileInEditor(path: node.file, line: node.line)
    } label: {
      Label("Open in Editor", systemImage: "arrow.up.forward.app")
    }

    Button {
      store.revealFile(path: node.file)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }

    Button {
      store.copyFileReference(path: node.file, line: node.line)
    } label: {
      Label("Copy Reference", systemImage: "doc.on.doc")
    }

    Divider()

    Button {
      store.selectSearchNode(node)
      store.askAIChatAboutCurrentSelection()
    } label: {
      Label("Ask AI", systemImage: "sparkles")
    }

    Button {
      store.selectSearchNode(node)
      Task { await store.briefCurrentNode() }
    } label: {
      Label("Brief Node", systemImage: "doc.text.magnifyingglass")
    }

    Button {
      store.selectSearchNode(node)
      Task { await store.linkifyCurrentFile() }
    } label: {
      Label("Linkify File", systemImage: "link")
    }
  }
}

struct SourcesView: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    @Bindable var store = store
    VStack(spacing: 0) {
      HeaderBar(
        title: "Sources",
        subtitle: "Slack, Notion, email, and Google Calendar staged as reviewable Org files",
        surface: .sources
      ) {
        if store.isLoadingSources {
          WorkspaceActivityIndicator(size: .small)
        }
        AddSourceMenu()
        Button {
          Task { await store.refreshSourceConnections() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoadingSources)
      }

      if store.sourceProfiles.isEmpty {
        Spacer()
        EmptyStateView(
          title: "No Sources Configured",
          detail: "Add a Slack workspace, Notion workspace, email account, or Google Calendar. Settings go in this corpus’s celorga.json; tokens, passwords, and sign-ins stay in macOS Keychain and your connected server’s private store.",
          action: "Add Source…"
        ) {
          store.presentNewSource(type: WorkspaceSourceCatalog.types[0])
        }
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            Text("Sync updates each crawler’s private local archive. Stage writes bounded raw captures and review-required Org packets into this corpus; it never promotes them into canonical notes. Configured schedules run while Celorga is open and catch up after sleep or on the next launch.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            if store.connectedServerRunsSourceSyncs {
              Label(
                "\(store.openOrgServer.serverName) syncs these sources: scheduled syncs and Run Now run there. Tokens, passwords, and sign-ins you save on this Mac are sent to it.",
                systemImage: "server.rack"
              )
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            } else if !store.ownsScheduledSourceSync {
              Label(
                "Scheduled syncs run on \(store.corpusAutomationHostRef ?? "desktop"), the host that owns this corpus’s automations. Run Now syncs on this Mac.",
                systemImage: "server.rack"
              )
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(store.sourceProfiles) { profile in
              SourceProfileCard(
                profile: profile,
                runtime: store.sourceRuntimeStatuses[profile.id]
              )
            }

            if let workspaceMessage = store.sourceOperationMessages["workspace"] {
              Text(workspaceMessage)
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }
          }
          .padding(WorkspaceDesign.contentInset)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .task {
      if store.sourceProfiles.isEmpty {
        await store.refreshSourceConnections()
      }
      await store.refreshServerSourceCredentials()
    }
    .sheet(isPresented: $store.isSourceCredentialPresented) {
      SourceCredentialSheet()
        .environment(store)
    }
    .sheet(item: $store.sourceDraft) { draft in
      SourceEditorSheet(draft: draft)
        .environment(store)
    }
  }
}

/// One menu entry per catalog type, plus optional agent-assisted setup.
private struct AddSourceMenu: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    Menu {
      ForEach(WorkspaceSourceCatalog.types) { type in
        Button("\(type.displayName)…") { store.presentNewSource(type: type) }
      }
      Divider()
      Menu("Set Up with AI") {
        ForEach(WorkspaceSourceCatalog.types) { type in
          Button(type.displayName) { store.askAIChatToSetUpSource(type: type) }
        }
      }
    } label: {
      Label("Add Source", systemImage: "plus")
    }
    .help("Add a Slack, Notion, email, or Google Calendar source")
  }
}

/// The single add/configure form for every catalog source type.
private struct SourceEditorSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var draft: WorkspaceSourceDraft
  @State private var errorMessage: String?
  @State private var isSaving = false

  init(draft: WorkspaceSourceDraft) {
    _draft = State(initialValue: draft)
  }

  private var type: WorkspaceSourceType? { draft.sourceType }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        if let type { ConnectorBrandLogo(type: type.id, size: 24) }
        Text(draft.isEditing ? "Configure \(draft.profileID)" : (type?.addTitle ?? "Add Source"))
          .font(.title2.weight(.semibold))
        Spacer()
        if !draft.isEditing {
          Picker("Type", selection: Binding(
            get: { draft.typeID },
            set: { id in
              if let type = WorkspaceSourceCatalog.type(id), id != draft.typeID {
                draft = WorkspaceSourceDraft(type: type)
                errorMessage = nil
              }
            }
          )) {
            ForEach(WorkspaceSourceCatalog.types) { type in
              Text(type.displayName).tag(type.id)
            }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .fixedSize()
        }
      }
      if let type {
        Text(type.summary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Form {
        if !draft.isEditing {
          TextField("Source name", text: $draft.profileID)
        }
        ForEach(type?.fields ?? []) { field in
          if draft.isVisible(field) {
            fieldRow(field)
          }
        }
        if let secret = type?.secret, secret.signIn != nil {
          Text(draft.isEditing ? secret.help : "\(secret.help) After adding the source, choose Sign in with Google on its card.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if let secret = type?.secret {
          SecureField(
            draft.isEditing ? "\(secret.label) (leave empty to keep)" : secret.label,
            text: $draft.secret
          )
          .help(secret.help)
          Text(secret.help)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .formStyle(.grouped)
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .textSelection(.enabled)
      }
      HStack {
        if let type {
          Button("Set Up with AI…") { store.askAIChatToSetUpSource(type: type) }
            .help("Open an AI chat that walks through this setup instead")
        }
        Spacer()
        Button("Cancel") { store.sourceDraft = nil }
        Button(draft.isEditing ? "Save" : "Add Source") {
          isSaving = true
          Task {
            errorMessage = await store.saveSourceDraft(draft)
            isSaving = false
            if errorMessage == nil { store.sourceDraft = nil }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isSaving || draft.validationMessage != nil)
        .help(draft.validationMessage ?? "")
      }
    }
    .padding(22)
    .frame(width: 560)
  }

  @ViewBuilder
  private func fieldRow(_ field: WorkspaceSourceField) -> some View {
    let binding = Binding(
      get: { draft.value(field.id) },
      set: { draft.setValue($0, for: field.id) }
    )
    switch field.kind {
    case .choice(let choices):
      Picker(field.label, selection: binding) {
        ForEach(choices) { choice in
          Text(choice.title).tag(choice.value)
        }
      }
      .help(field.help ?? "")
    case .text, .integer, .list:
      TextField(field.label, text: binding, prompt: field.prompt.isEmpty ? nil : Text(field.prompt))
        .help(field.help ?? "")
    }
  }
}

private struct SourceProfileCard: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isSchedulePresented = false
  let profile: WorkspaceSourceProfileStatus
  let runtime: WorkspaceSourceRuntimeStatus?

  private var isRunning: Bool { store.activeSourceOperationIDs.contains(profile.id) }
  private var needsToken: Bool {
    profile.usesStoredCredential && profile.credentialAvailable != true && !store.sourceHasStoredCredential(profile)
      && !(store.connectedServerRunsSourceSyncs && store.serverHasSourceCredential(profile) == true)
  }
  private var canSync: Bool { profile.ready && !needsToken }
  private var notice: WorkspaceSourceNotice? {
    WorkspaceSourcePresentation.notice(
      scheduleError: store.sourceScheduleStates[profile.id]?.lastError,
      operationMessage: store.sourceOperationMessages[profile.id],
      operationFailed: store.sourceOperationFailureIDs.contains(profile.id)
    )
  }
  private var presentationState: WorkspaceSourcePresentationState {
    WorkspaceSourcePresentation.state(
      isRunning: isRunning,
      needsToken: needsToken,
      isReady: profile.ready,
      runtimeOK: runtime?.ok,
      notice: notice
    )
  }
  private var statusColor: Color {
    switch presentationState {
    case .configured: .green
    case .syncing: .accentColor
    case .needsToken, .needsSetup, .needsAttention: .orange
    }
  }
  private var statusSystemImage: String {
    switch presentationState {
    case .configured: "checkmark.circle.fill"
    case .syncing: "arrow.triangle.2.circlepath"
    case .needsToken, .needsSetup, .needsAttention: "exclamationmark.triangle.fill"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        ConnectorBrandLogo(type: profile.type)
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        VStack(alignment: .leading, spacing: 2) {
          Text(profile.id.capitalized)
            .font(.headline)
          Text(runtime?.crawlerStatus?.summary ?? "Crawler status unavailable")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Label(
          presentationState.title,
          systemImage: statusSystemImage
        )
          .font(.caption.weight(.semibold))
          .foregroundStyle(statusColor)
      }

      if let counts = runtime?.crawlerStatus?.counts, !counts.isEmpty {
        HStack(spacing: 16) {
          ForEach(Array(counts.prefix(4))) { count in
            VStack(alignment: .leading, spacing: 1) {
              Text(count.value.formatted())
                .font(.callout.monospacedDigit().weight(.semibold))
              Text(count.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
        GridRow {
          Text("Window").foregroundStyle(.secondary)
          Text(profile.ingestionSince ?? "All available")
        }
        if let workspaceID = profile.workspaceId {
          GridRow {
            Text("Workspace").foregroundStyle(.secondary)
            Text(workspaceID).textSelection(.enabled)
          }
        }
        if let email = profile.email {
          GridRow {
            Text("Account").foregroundStyle(.secondary)
            Text("\(email.username) · \(email.host):\(email.port) (\(email.security.uppercased()))").textSelection(.enabled)
          }
          GridRow {
            Text("Mailboxes").foregroundStyle(.secondary)
            Text(email.mailboxes.joined(separator: ", "))
          }
          if let smtp = email.smtp {
            GridRow {
              Text("SMTP").foregroundStyle(.secondary)
              Text("\(smtp.host):\(smtp.port)").textSelection(.enabled)
            }
          }
        }
        if let setupError = profile.setupError {
          GridRow {
            Text("Setup").foregroundStyle(.secondary)
            Text(setupError).foregroundStyle(.orange)
          }
        }
        GridRow {
          Text("Raw").foregroundStyle(.secondary)
          Text(profile.rawZone).lineLimit(1).truncationMode(.middle)
        }
        GridRow {
          Text("Review").foregroundStyle(.secondary)
          Text(profile.reviewZone).lineLimit(1).truncationMode(.middle)
        }
        if let lastSync = runtime?.crawlerStatus?.lastSyncAt {
          GridRow {
            Text("Last sync").foregroundStyle(.secondary)
            Text(lastSync).textSelection(.enabled)
          }
        }
        if let schedule = profile.schedule {
          GridRow {
            Text("Schedule").foregroundStyle(.secondary)
            Text(schedule.summary)
          }
          if let nextRunAt = store.sourceScheduleStates[profile.id]?.nextRunAt {
            GridRow {
              Text("Next automatic").foregroundStyle(.secondary)
              Text(nextRunAt.formatted(date: .abbreviated, time: .shortened))
            }
          }
          if let lastAttemptAt = store.sourceScheduleStates[profile.id]?.lastAttemptAt {
            GridRow {
              Text("Last attempt").foregroundStyle(.secondary)
              Text(lastAttemptAt.formatted(date: .abbreviated, time: .shortened))
            }
          }
        }
      }
      .font(.caption)

      if let notice {
        Label(
          notice.text,
          systemImage: notice.isError ? "exclamationmark.triangle.fill" : "info.circle.fill"
        )
          .font(.caption)
          .foregroundStyle(notice.isError ? Color.red : Color.secondary)
          .textSelection(.enabled)
      }

      ViewThatFits(in: .horizontal) {
        sourceActions
        VStack(alignment: .leading, spacing: 8) { sourceActions }
      }
    }
    .padding(16)
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(WorkspaceDesign.hairline, lineWidth: 1)
    }
    .sheet(isPresented: $isSchedulePresented) {
      SourceScheduleSheet(profile: profile)
        .environment(store)
    }
  }

  private var sourceActions: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Button {
          Task { await store.syncAndStageSource(profile) }
        } label: {
          Label(isRunning ? "Working" : "Run Now", systemImage: "arrow.triangle.2.circlepath")
        }
        .help("Sync this connector now and stage any new source records.")
        .disabled(isRunning || !canSync)

        if let schedule = profile.schedule {
          Button(schedule.enabled ? "Pause Schedule" : "Resume Schedule") {
            Task { await store.setSourceScheduleEnabled(profile, enabled: !schedule.enabled) }
          }
          .disabled(isRunning)
        }

        Button(profile.schedule == nil ? "Add Schedule…" : "Edit Schedule…") {
          isSchedulePresented = true
        }
        .disabled(isRunning)
      }

      HStack(spacing: 8) {
        Button("Preview") {
          Task { await store.previewSourceImport(profile) }
        }
        .disabled(isRunning || !profile.ready)

        Button("Check Setup") {
          Task { await store.checkSourceSetup(profile) }
        }
        .disabled(isRunning)

        Button("Reveal Reviews") {
          store.revealSourceReviews(profile)
        }

        if profile.sourceType != nil {
          Button("Configure…") {
            store.presentSourceEditor(for: profile)
          }
          .disabled(isRunning)
        }

        if let secret = profile.sourceType?.secret {
          if secret.signIn != nil {
            Button(store.sourceHasStoredCredential(profile) ? "Sign In Again…" : "Sign in with Google…") {
              Task { await store.signInToGoogle(for: profile) }
            }
            .disabled(isRunning)
            .help("Sign in on this Mac; the sign-in is sent to your connected server so it can sync.")
          } else {
            Button(store.sourceHasStoredCredential(profile) ? "Replace \(secret.label)" : "Add \(secret.label)") {
              store.presentSourceCredential(for: profile)
            }
          }
          if store.sourceHasStoredCredential(profile) {
            if store.openOrgServer.isPaired {
              Button("Send to Server") {
                Task { await store.sendSourceCredentialToServer(profile) }
              }
              .disabled(isRunning)
              .help("Send this source’s \(secret.label.lowercased()) to \(store.openOrgServer.serverName) so it can sync there.")
            }
            Button(secret.signIn != nil ? "Sign Out" : "Remove \(secret.label)", role: .destructive) {
              store.deleteSourceCredential(profile)
            }
          }
        }
      }

      if profile.sourceType?.secret != nil, store.openOrgServer.isPaired,
         let onServer = store.serverHasSourceCredential(profile) {
        Label(
          onServer
            ? "\(store.openOrgServer.serverName) has this source’s credential."
            : "\(store.openOrgServer.serverName) doesn’t have this source’s credential yet.",
          systemImage: onServer ? "checkmark.circle" : "exclamationmark.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if profile.type == "google-calendar" {
        CalendarPromptToggle()
      }
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
  }
}

private struct CalendarPromptToggle: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isOn = true

  var body: some View {
    Toggle("Offer to record meetings as they start", isOn: $isOn)
      .toggleStyle(.checkbox)
      .onAppear { isOn = store.calendarRecordingPromptsEnabled }
      .onChange(of: isOn) { _, value in store.setCalendarRecordingPromptsEnabled(value) }
      .help("When a synced meeting with other attendees or a call link starts, Celorga offers to record it with its title, time, and attendees filled in.")
  }
}

private struct SourceScheduleSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let profile: WorkspaceSourceProfileStatus
  @State private var draft: WorkspaceSourceScheduleDraft
  @State private var validationMessage: String?

  init(profile: WorkspaceSourceProfileStatus) {
    self.profile = profile
    _draft = State(initialValue: WorkspaceSourceScheduleDraft(schedule: profile.schedule))
  }

  private var timeZoneChoices: [String] {
    var choices = ["local", TimeZone.current.identifier, "UTC"]
    choices.append(contentsOf: TimeZone.knownTimeZoneIdentifiers)
    var seen = Set<String>()
    return choices.filter { seen.insert($0).inserted }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(profile.id.capitalized) Sync Schedule")
          .font(.title2.weight(.semibold))
        Text("The schedule is stored with this connector in the corpus's celorga.json. Run Now remains available when scheduled sync is paused.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Picker("Frequency", selection: $draft.kind) {
        Text("Repeating interval").tag(WorkspaceSourceSchedule.Kind.interval)
        Text("Once each day").tag(WorkspaceSourceSchedule.Kind.daily)
      }
      .pickerStyle(.segmented)

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
        if draft.kind == .interval {
          GridRow {
            Text("Run every")
            HStack(spacing: 8) {
              TextField("2", value: $draft.intervalValue, format: .number)
                .frame(width: 72)
                .textFieldStyle(.roundedBorder)
              Picker("Unit", selection: $draft.intervalUnit) {
                Text("Minutes").tag(WorkspaceSourceIntervalUnit.minutes)
                Text("Hours").tag(WorkspaceSourceIntervalUnit.hours)
              }
              .labelsHidden()
              .frame(width: 110)
            }
          }
        } else {
          GridRow {
            Text("Run at")
            DatePicker("", selection: $draft.dailyTime, displayedComponents: .hourAndMinute)
              .labelsHidden()
          }
        }

        GridRow {
          Text("Time zone")
          Picker("Time zone", selection: $draft.timezone) {
            ForEach(timeZoneChoices, id: \.self) { timeZone in
              Text(timeZone == "local" ? "Local time" : timeZone).tag(timeZone)
            }
          }
          .labelsHidden()
          .frame(minWidth: 240)
        }
      }

      if let validationMessage {
        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save Schedule") {
          do {
            let schedule = try draft.schedule(enabled: profile.schedule?.enabled ?? true)
            validationMessage = nil
            Task {
              if await store.updateSourceSchedule(profile, schedule: schedule) {
                dismiss()
              }
            }
          } catch {
            validationMessage = error.localizedDescription
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(store.activeSourceOperationIDs.contains(profile.id))
      }
    }
    .padding(22)
    .frame(width: 520)
  }
}

private struct SourceCredentialSheet: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    @Bindable var store = store
    let profile = store.sourceProfiles.first { $0.id == store.sourceCredentialProfileID }
    let secret = profile?.sourceType?.secret
    let label = secret?.label ?? "Credential"
    VStack(alignment: .leading, spacing: 14) {
      Text("\(profile?.sourceType?.displayName ?? "Source") \(label)")
        .font(.title2.weight(.semibold))
      Text(secret?.help ?? "Celorga stores this credential in macOS Keychain and passes it only to the sync; it is never written to the corpus.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      SecureField(label, text: $store.sourceCredentialDraft)
        .textFieldStyle(.roundedBorder)
      HStack {
        Spacer()
        Button("Cancel") {
          store.sourceCredentialDraft = ""
          store.isSourceCredentialPresented = false
        }
        Button("Save \(label)") {
          store.savePresentedSourceCredential()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(store.sourceCredentialDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(22)
    .frame(width: 480)
  }
}

struct MeetingsView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID

  var body: some View {
    @Bindable var store = store
    VStack(spacing: 0) {
      HeaderBar(title: "Meetings", subtitle: "\(store.meetings.count) local meeting\(store.meetings.count == 1 ? "" : "s")", surface: .meetings) {
        if store.isLoadingMeetings || store.isProcessingMeeting {
          WorkspaceActivityIndicator(size: .small)
        }

        Button {
          Task { await store.refreshMeetings() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoadingMeetings)

        if store.isRecordingMeeting {
          Button {
            Task {
              if store.isMeetingRecordingPaused {
                await store.resumeMeetingRecording()
              } else {
                await store.pauseMeetingRecording()
              }
            }
          } label: {
            Label(
              store.isMeetingRecordingPaused ? "Resume" : "Pause",
              systemImage: store.isMeetingRecordingPaused ? "play.fill" : "pause.fill"
            )
          }

          Button {
            Task { await store.stopMeetingRecording() }
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
        } else {
          Button {
            store.promptAndStartMeetingRecording()
          } label: {
            Label("Record", systemImage: "record.circle")
          }
          .disabled(store.corpusRoot == nil)
        }

        Button {
          store.promptAndImportMeetingAudio()
        } label: {
          Label("Import", systemImage: "tray.and.arrow.down")
        }
        .disabled(store.corpusRoot == nil || store.isRecordingMeeting)
      }

      VStack(alignment: .leading, spacing: 8) {
        TextField("Meeting title", text: $store.meetingTitleDraft)
          .textFieldStyle(.roundedBorder)
          .disabled(store.isRecordingMeeting)

        HStack(spacing: 10) {
          Text(store.meetingStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)

          Spacer(minLength: 0)

          MeetingInputStatusView(
            meterState: store.meetingInputMeterState,
            isRecording: store.isRecordingMeeting,
            isPaused: store.isMeetingRecordingPaused,
            isCapturingSystemAudio: store.isCapturingSystemAudio,
            systemAudioStatusText: store.meetingSystemAudioStatusText,
            sourceText: store.meetingCaptureSourceText
          )
        }

        if store.isProcessingMeeting {
          MeetingTranscriptionProgressView(
            progressState: store.meetingTranscriptionProgressState,
            backendText: LocalWhisperTranscriber.resolvedBackendDescription()
          )
        }

      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.top, 12)
      .padding(.bottom, 12)

      if store.meetings.isEmpty && store.pendingMeetingProcessingItems.isEmpty {
        if store.isLoadingMeetings {
          Spacer()
          WorkspaceLoadingStateView("Loading meetings")
          Spacer()
        } else {
          EmptyStateView(title: "No Meetings", detail: store.meetingStatusText, action: "Record") {
            store.promptAndStartMeetingRecording()
          }
        }
      } else {
        WorkspaceLazyCollection {
          if !store.pendingMeetingProcessingItems.isEmpty {
            Section {
              ForEach(store.pendingMeetingProcessingItems) { item in
                MeetingProcessingRow(item: item)
                  .workspaceLazyRow(id: "meeting-processing:\(item.id)")
              }
            } header: {
              WorkspaceLazySectionHeader {
                Text("Processing")
              }
            }
          }

          ForEach(store.meetingDisplaySections) { section in
            Section {
              ForEach(section.meetings) { meeting in
                MeetingRow(
                  meeting: meeting,
                  isProcessing: store.isMeetingProcessing(meeting),
                  sourceReference: store.relativePath(meeting.file) + ":\(meeting.lineForEditor)"
                  )
                  .contentShape(Rectangle())
                  .onTapGesture {
                    selectMeeting(meeting)
                  }
                  .modifier(ReadableListSelectionModifier(isSelected: store.selectedMeetingID == meeting.id))
                  .workspaceAccessibleCollectionRow(
                    kind: "meeting",
                    id: meeting.id,
                    label: Org2Display.cleanInline(meeting.title),
                    isSelected: store.selectedMeetingID == meeting.id,
                    open: { selectMeeting(meeting) }
                  )
                  .contextMenu {
                    WorkspaceLocationContextMenu(
                      location: .meeting(meeting),
                      select: { store.selectMeeting(meeting) }
                    ) {
                      Label("Open", systemImage: "waveform.and.mic")
                    }
                    Divider()
                    Button(role: .destructive) {
                      store.confirmAndDeleteMeeting(meeting)
                    } label: {
                      Label("Delete Meeting", systemImage: "trash")
                    }
                  }
                  .workspaceLazyRow(id: meeting.id)
              }
            } header: {
              WorkspaceLazySectionHeader {
                Text(section.label)
              }
            }
          }
        }
        .onChange(of: store.selectedMeetingID) {
          guard let id = store.selectedMeetingID,
                let meeting = store.meetings.first(where: { $0.id == id })
          else {
            return
          }
          performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
            guard store.selectedMeetingID == id else { return }
            store.selectMeeting(meeting)
          }
        }
      }
    }
    .onAppear {
      if store.meetings.isEmpty {
        Task { await store.refreshMeetings() }
      }
    }
  }

  private func selectMeeting(_ meeting: MeetingWorkspaceItem) {
    if store.selectedMeetingID == meeting.id {
      store.selectMeeting(meeting)
    } else {
      store.selectedMeetingID = meeting.id
    }
  }
}

public struct MeetingTranscriptionSettingsView: View {
  @Environment(WorkspaceStore.self) private var store

  public init() {}

  public var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 8) {
      Picker("Provider", selection: $store.meetingTranscriptionProvider) {
        ForEach(MeetingTranscriptionProvider.allCases) { provider in
          Text(provider.label).tag(provider)
        }
      }
      .pickerStyle(.menu)

      Text(store.meetingTranscriptionProviderDetailText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      providerSettings

      HStack(spacing: 8) {
        Button {
          Task { await store.testMeetingTranscriptionProvider() }
        } label: {
          if store.isTestingTranscriptionProvider {
            ProgressView()
              .controlSize(.small)
          } else {
            Label("Test Provider", systemImage: "stethoscope")
          }
        }
        .disabled(store.isTestingTranscriptionProvider || store.isConnectingFluidVoice)

        Button {
          Task { await store.refreshAudioSettingsStatusAsync() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isTestingTranscriptionProvider || store.isConnectingFluidVoice)
      }

      Text(store.audioSettingsStatusText.isEmpty ? store.audioSettingsStatus.detailText : store.audioSettingsStatusText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(alignment: .top, spacing: 8) {
        Image(systemName: store.workspaceRuntimeIdentity.isAppBundle ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(store.workspaceRuntimeIdentity.isAppBundle ? Color.green : Color.orange)
        VStack(alignment: .leading, spacing: 2) {
          Text(store.workspaceRuntimeIdentity.audioPermissionStatusLabel)
            .font(.caption.weight(.semibold))
          Text(store.workspaceRuntimeIdentity.audioPermissionDetailText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        audioSettingRow("Local fallback", store.audioSettingsStatus.backendDescription)
        audioSettingRow("App build", store.workspaceRuntimeIdentity.buildConfigurationLabel)
        audioSettingRow("App path", store.workspaceRuntimeIdentity.bundlePath)
        if let whisperCpp = store.audioSettingsStatus.whisperCppExecutablePath {
          audioSettingRow("whisper.cpp", whisperCpp)
        }
        if let model = store.audioSettingsStatus.whisperCppModelPath {
          audioSettingRow("GGML model", model)
        }
        if let openAIWhisper = store.audioSettingsStatus.openAIWhisperExecutablePath {
          audioSettingRow("Python Whisper", openAIWhisper)
        }
        if let overrideCommand = store.audioSettingsStatus.overrideCommand {
          audioSettingRow("Override", overrideCommand)
        }
      }
      .font(.caption)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: store.meetingTranscriptionProvider) {
      guard store.meetingTranscriptionProvider == .fluidVoice else { return }
      await store.connectFluidVoice()
    }
  }

  @ViewBuilder
  private var providerSettings: some View {
    @Bindable var store = store
    switch store.meetingTranscriptionProvider {
    case .automatic, .localWhisper:
      VStack(alignment: .leading, spacing: 6) {
        TextField("Bundled default model", text: $store.whisperModelPathText)
          .textFieldStyle(.roundedBorder)
        TextField("Language", text: $store.transcriptionLanguageText)
          .textFieldStyle(.roundedBorder)
        Text("Leave the model path empty to use the bundled model. Language defaults to en.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    case .fluidVoice:
      VStack(alignment: .leading, spacing: 6) {
        Button {
          Task { await store.connectFluidVoice() }
        } label: {
          if store.isConnectingFluidVoice {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text("Connecting Fluid Voice…")
            }
          } else {
            Label("Connect Fluid Voice", systemImage: "bolt.horizontal.circle")
          }
        }
        .disabled(store.isConnectingFluidVoice)
        Text("Celorga detects Fluid Voice, enables its Local API, briefly relaunches it when needed, and verifies the connection. Long meetings remain local and are sent only to this Mac's loopback endpoint.")
          .font(.caption2)
          .foregroundStyle(.secondary)
        DisclosureGroup("Advanced") {
          TextField("http://127.0.0.1:47733", text: $store.fluidVoiceEndpointText)
            .textFieldStyle(.roundedBorder)
          Text("Change this only if Fluid Voice is configured to use a different local port.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    case .macOSSpeech:
      EmptyView()
    case .customCommand:
      VStack(alignment: .leading, spacing: 6) {
        TextField("Command using {audio}", text: $store.customTranscriptionCommandText)
          .textFieldStyle(.roundedBorder)
        Text("Use {audio} where the quoted file path belongs. The command must emit transcript text on standard output.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func audioSettingRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(width: 78, alignment: .leading)
      Text(value)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MeetingTranscriptionProgressView: View {
  @ObservedObject var progressState: WorkspaceTranscriptionProgressState
  let backendText: String

  private var progress: Double { progressState.progress }
  private var elapsedText: String { progressState.elapsedText }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ProgressView(value: progress)
        .progressViewStyle(.linear)
      HStack(spacing: 8) {
        Text("\(Int(progress * 100))%")
          .fontWeight(.semibold)
        if !elapsedText.isEmpty {
          Text("elapsed \(elapsedText)")
        }
        Text(backendText)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Meeting transcription progress")
    .help("Estimated local transcription progress. The bar caps at 95% until the local transcriber finishes.")
  }
}

private struct MeetingInputStatusView: View {
  @ObservedObject var meterState: WorkspaceInputMeterState
  let isRecording: Bool
  let isPaused: Bool
  let isCapturingSystemAudio: Bool
  let systemAudioStatusText: String
  let sourceText: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: isPaused ? "pause.fill" : (isRecording ? "waveform" : "mic"))
        .foregroundStyle(isPaused ? .orange : (isRecording ? .red : .secondary))

      if isRecording {
        VStack(alignment: .leading, spacing: 4) {
          MeetingInputMeterRow(
            label: isPaused ? "Paused" : "Mic",
            averageLevel: isPaused ? 0 : meterState.levels.averageLevel,
            peakLevel: isPaused ? 0 : meterState.levels.peakLevel
          )
          if isCapturingSystemAudio {
            MeetingInputMeterRow(
              label: "System",
              averageLevel: isPaused ? 0 : meterState.levels.secondaryAverageLevel,
              peakLevel: isPaused ? 0 : meterState.levels.secondaryPeakLevel
            )
          } else {
            Text(systemAudioStatusText)
              .font(.caption2)
              .foregroundStyle(.orange)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      } else {
        Text(sourceText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(isRecording ? (isPaused ? "Meeting recording paused" : "Meeting audio input levels") : sourceText)
    .help(sourceText)
  }
}

private struct MeetingInputMeterRow: View {
  let label: String
  let averageLevel: Double
  let peakLevel: Double

  var body: some View {
    HStack(spacing: 6) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 48, alignment: .trailing)

      WorkspaceInputMeterView(averageLevel: averageLevel, peakLevel: peakLevel)
        .frame(width: 120, height: 7)
    }
  }
}

struct WorkspaceInputMeterView: View {
  let averageLevel: Double
  let peakLevel: Double

  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, 1)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Color.secondary.opacity(0.16))

        Capsule()
          .fill(Color.red.opacity(0.28))
          .frame(width: max(2, width * clamped(peakLevel)))

        Capsule()
          .fill(Color.red)
          .frame(width: max(2, width * clamped(averageLevel)))
      }
    }
    .frame(height: 8)
  }

  private func clamped(_ value: Double) -> Double {
    min(1, max(0, value))
  }
}

private struct MeetingRow: View {
  let meeting: MeetingWorkspaceItem
  let isProcessing: Bool
  let sourceReference: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "waveform.and.mic")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(Org2Display.cleanInline(meeting.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          if isProcessing {
            HStack(spacing: 5) {
              WorkspaceActivityIndicator(size: .mini)
              StatusPill(text: "PROCESSING")
            }
          } else if let status = meeting.transcriptionStatus {
            StatusPill(text: status.uppercased())
          }
        }

        HStack(spacing: 8) {
          if let recordedAt = meeting.recordedAt {
            Text(recordedAt)
          }
          if let modifiedAt = meeting.modifiedAt {
            Text(Self.relativeDate(modifiedAt))
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        Text(sourceReference)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }

  private static func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

private struct MeetingProcessingRow: View {
  let item: MeetingProcessingItem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "waveform.and.mic", tint: .accentColor, fill: Color.accentColor.opacity(0.1))
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(Org2Display.cleanInline(item.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          HStack(spacing: 5) {
            WorkspaceActivityIndicator(size: .mini)
            StatusPill(text: "PROCESSING")
          }
        }

        Text(item.status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Processing \(item.title)")
  }
}

enum AIChatPresentation {
  case fullPage
  case assistantPanel
  case homePane

  var isCompact: Bool {
    self != .fullPage
  }
}

struct AIChatView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isChatNearBottom = true
  @State private var isShowingThreadFind = false
  @State private var threadFindQuery = ""
  @State private var threadFindCandidates: [AIChatThreadSearchCandidate] = []
  @State private var threadFindMatches: [AIChatThreadSearchMatch] = []
  @State private var threadFindIndexTask: Task<Void, Never>?
  @State private var threadFindMatchTask: Task<Void, Never>?
  @State private var selectedThreadFindMessageID: UUID?
  @State private var threadFindNavigationGeneration = 0
  @State private var transcriptDisplayLimit = AIChatTranscriptWindow.initialLimit
  @State private var transcriptWindowAnchor: AIChatTranscriptAnchor?
  @State private var threadOutputs = AIChatThreadOutputs.empty
  @State private var threadOutputsThreadID: UUID?
  let presentation: AIChatPresentation
  let surface: WorkspaceSurface?

  init(presentation: AIChatPresentation = .fullPage, surface: WorkspaceSurface? = .aiChat) {
    self.presentation = presentation
    self.surface = surface
  }

  var body: some View {
    // Leading alignment keeps the transcript and composer pinned to the pane's
    // leading edge. With center alignment, a header wider than a narrow pane
    // pushed the whole chat column right and clipped the composer.
    VStack(alignment: .leading, spacing: 0) {
      header

      if let recoveryNotice = store.aiChatTranscriptRecoveryNotice {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Label(recoveryNotice, systemImage: "exclamationmark.triangle.fill")
            .frame(maxWidth: .infinity, alignment: .leading)
          Button(store.isLoadingAIChatTranscript ? "Retrying…" : "Retry") {
            store.retryAIChatTranscriptRecovery()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(store.isLoadingAIChatTranscript)
          .accessibilityIdentifier("ai-chat-transcript-recovery-retry")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, presentation.isCompact ? 10 : 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
        .accessibilityIdentifier("ai-chat-transcript-recovery-notice")
        Divider()
      }

      chatColumn
    }
    .environment(\.aiChatMediaCorpusRoot, store.corpusRoot)
    .environment(
      \.aiChatRecognizedMentions,
      AIChatDestinationRouting.recognizedMentionTokens(destinations: store.aiChatDestinations)
    )
    .environment(\.aiChatThreadLinks, AIChatThreadLinkResolver(
      title: { store.aiChatThreadLinkTitle($0) },
      open: { store.openAIChatThreadLink($0) }
    ))
    .task {
      await store.refreshAIChatCommands()
    }
    .task(id: threadOutputsSignature) {
      await refreshThreadOutputs()
    }
    .onChange(of: store.aiChatFindRequestGeneration) { _, _ in
      guard surface == store.selectedSurface else { return }
      isShowingThreadFind = true
      rebuildThreadFindIndex()
    }
    .onChange(of: threadFindQuery) { _, _ in
      guard isShowingThreadFind else { return }
      refreshThreadFindMatches()
    }
    .onChange(of: store.selectedAIChatThreadID) { _, _ in
      transcriptDisplayLimit = AIChatTranscriptWindow.initialLimit
      transcriptWindowAnchor = nil
      guard isShowingThreadFind else { return }
      rebuildThreadFindIndex()
    }
    .onChange(of: store.aiChatMessages.count) { previousCount, currentCount in
      if currentCount > previousCount && !isChatNearBottom {
        transcriptDisplayLimit += currentCount - previousCount
      }
      guard isShowingThreadFind else { return }
      rebuildThreadFindIndex()
    }
    .onDisappear {
      threadFindIndexTask?.cancel()
      threadFindMatchTask?.cancel()
    }
  }

  private var chatColumn: some View {
    VStack(spacing: 0) {
      if isShowingThreadFind {
        AIChatThreadFindBar(
          query: $threadFindQuery,
          selectedMatchIndex: selectedThreadFindMatchIndex,
          matchCount: threadFindMatches.count,
          focusRequest: store.aiChatFindRequestGeneration,
          compact: presentation.isCompact,
          onPrevious: { selectAdjacentThreadFindMatch(offset: -1) },
          onNext: { selectAdjacentThreadFindMatch(offset: 1) },
          onClose: closeThreadFind
        )
        Divider()
      }

      chatTranscript

      if !showsEmptyChat {
        Divider()
      }

      AIChatGuestMessagesPanel()

      AIChatComposerView(
        focusOnAppear: presentation != .assistantPanel,
        compact: presentation.isCompact
      )
      .padding(presentation.isCompact ? 10 : 16)
    }
    .background(showsEmptyChat ? WorkspaceDesign.surfaceBackground : WorkspaceDesign.paneBackground)
  }

  @ViewBuilder
  private var header: some View {
    switch presentation {
    case .fullPage:
      HeaderBar(
        title: store.selectedAIChatIsSharedRoom
          ? "Shared AI Room"
          : "\(store.selectedAIChatDestination.title) Chat",
        subtitle: store.aiChatStatusText,
        surface: surface
      ) {
        headerActions
      }
    case .homePane:
      HeaderBar(title: "AI Chat", subtitle: store.aiChatStatusText, surface: surface) {
        homeHeaderActions
      }
    case .assistantPanel:
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(store.selectedAIChatDisplayTitle)
            .font(.headline)
          Text(store.aiChatStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Spacer(minLength: 0)
        threadOutputsChip
          .controlSize(.small)

        AIChatThreadShareButton()
          .labelStyle(.iconOnly)

        AIChatThreadSettleButton()
          .labelStyle(.iconOnly)

        AIChatSettingsButton()
          .labelStyle(.iconOnly)

        Button {
          store.makeSurfacePrimary(.aiChat)
        } label: {
          Label("Make Primary", systemImage: "rectangle.split.2x1")
        }
        .labelStyle(.iconOnly)
        .help("Open AI Chat")

        Button {
          store.expandSurface(.aiChat)
        } label: {
          Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .labelStyle(.iconOnly)
        .help("Show only AI Chat")

        Button {
          store.closeSurfacePane(.aiChat)
        } label: {
          Label("Close", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .help("Close AI Chat")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(WorkspaceDesign.barBackground)
      .overlay(alignment: .bottom) {
        Divider()
      }
    }
  }

  @ViewBuilder
  private var threadOutputsChip: some View {
    if !threadOutputs.isEmpty {
      AIChatThreadOutputsChip(outputs: threadOutputs, onJumpToMessage: jumpToMessage)
    }
  }

  @ViewBuilder
  private var headerActions: some View {
    threadOutputsChip

    AIChatThreadShareButton()

    AIChatThreadSettleButton()

    newChatButton

    Button {
      store.resetAIChat()
    } label: {
      Label("Clear", systemImage: "trash")
    }
    .disabled(store.isSendingAIChatMessage || store.aiChatMessages.isEmpty)

    AIChatSettingsButton()
  }

  private var newChatButton: some View {
    Menu {
      ForEach(store.enabledAIChatDestinations) { destination in
        Button {
          store.createAIChatThread(destinationID: destination.id)
        } label: {
          Label("New \(destination.title) Chat", systemImage: destination.systemImage)
        }
      }
      Divider()
      Button {
        store.createAIChatSharedRoom()
      } label: {
        Label("New Shared Room", systemImage: "person.2.fill")
      }
    } label: {
      Label("New", systemImage: "plus")
    }
    .menuIndicator(.hidden)
    .fixedSize()
  }

  @ViewBuilder
  private var homeHeaderActions: some View {
    threadOutputsChip

    AIChatThreadShareButton()
      .labelStyle(.iconOnly)

    AIChatThreadSettleButton()
      .labelStyle(.iconOnly)

    newChatButton

    Menu {
      Button {
        store.resetAIChat()
      } label: {
        Label("Clear", systemImage: "trash")
      }
      .disabled(store.isSendingAIChatMessage || store.aiChatMessages.isEmpty)

      Button {
        store.markAllAutomationAIChatThreadsReadAndSettled()
      } label: {
        Label(AIChatAutomationThreadsAction.title, systemImage: AIChatAutomationThreadsAction.systemImage)
      }

      AIChatSettingsButton()
    } label: {
      Label("More chat actions", systemImage: "ellipsis.circle")
    }
    .menuIndicator(.hidden)
    .fixedSize()
  }

  private var showsEmptyChat: Bool {
    store.aiChatMessages.isEmpty
      && !store.isSendingAIChatMessage
      && !store.isLoadingAIChatTranscript
      && store.aiChatTranscriptRecoveryNotice == nil
  }

  @ViewBuilder private var chatTranscript: some View {
    if showsEmptyChat {
      EmptyChatView()
    } else {
      chatTranscriptDocument
    }
  }

  private var chatTranscriptDocument: some View {
    let window = AIChatTranscriptWindow(
      messages: store.aiChatMessages,
      isSharedRoom: store.selectedAIChatIsSharedRoom,
      displayLimit: transcriptDisplayLimit,
      anchor: transcriptWindowAnchor
    )
    return AIChatTranscriptDocument(
      liveState: store.aiChatLiveState,
      items: window.visibleItems,
      compact: presentation.isCompact,
      earlierTitle: window.hasEarlierMessages ? window.earlierMessagesTitle : nil,
      searchMessageID: selectedThreadFindMessageID,
      searchGeneration: threadFindNavigationGeneration,
      onEarlier: {
        if window.nextDisplayLimit > window.displayLimit {
          transcriptWindowAnchor = nil
          transcriptDisplayLimit = window.nextDisplayLimit
        } else if let anchor = window.earlierPageAnchor {
          transcriptWindowAnchor = anchor
        }
      },
      onPosition: { position in
        isChatNearBottom = position >= AIChatScrollVisibility.nearBottomThreshold
      }
    )
    .onChange(of: threadFindNavigationGeneration) { _, _ in
      guard let match = threadFindMatches.first(where: { $0.messageID == selectedThreadFindMessageID }),
            !window.contains(match.scrollTargetID) else { return }
      transcriptWindowAnchor = AIChatTranscriptAnchor(
        itemID: match.scrollTargetID, rawMessageIndex: match.anchorRawMessageIndex
      )
    }
  }

  private var selectedThreadFindMatchIndex: Int? {
    guard let selectedThreadFindMessageID else { return nil }
    return threadFindMatches.firstIndex(where: {
      $0.messageID == selectedThreadFindMessageID
    })
  }

  private func refreshThreadFindMatches() {
    threadFindMatchTask?.cancel()
    let query = threadFindQuery
    guard AIChatProgressPresentation.containsNonWhitespace(query) else {
      threadFindMatches = []
      selectedThreadFindMessageID = nil
      return
    }
    let previousSelection = selectedThreadFindMessageID
    let candidates = threadFindCandidates
    threadFindMatchTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .milliseconds(24))
      } catch {
        return
      }
      let worker = Task.detached(priority: .userInitiated) {
        AIChatThreadSearch.matches(query: query, in: candidates)
      }
      let matches = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled,
            query == threadFindQuery
      else { return }
      threadFindMatches = matches
      if let previousSelection,
         matches.contains(where: { $0.messageID == previousSelection }) {
        selectedThreadFindMessageID = previousSelection
      } else {
        selectedThreadFindMessageID = matches.first?.messageID
      }
      requestThreadFindScroll()
    }
  }

  private func rebuildThreadFindIndex() {
    threadFindIndexTask?.cancel()
    threadFindMatchTask?.cancel()
    // Array/String storage is copy-on-write, so this snapshot is constant-time.
    // Per-message search normalization and attachment-name projection happen in
    // the detached worker below instead of while the find bar is opening.
    let messages = store.aiChatMessages
    let isSharedRoom = store.selectedAIChatIsSharedRoom
    let threadID = store.selectedAIChatThreadID
    threadFindIndexTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .milliseconds(24))
      } catch {
        return
      }
      let worker = Task.detached(priority: .userInitiated) {
        AIChatThreadSearch.candidates(in: messages, isSharedRoom: isSharedRoom)
      }
      let candidates = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled,
            threadID == store.selectedAIChatThreadID
      else { return }
      threadFindCandidates = candidates
      refreshThreadFindMatches()
    }
  }

  private func selectAdjacentThreadFindMatch(offset: Int) {
    guard !threadFindMatches.isEmpty else { return }
    let currentIndex = selectedThreadFindMatchIndex ?? (offset > 0 ? -1 : 0)
    let nextIndex = (currentIndex + offset + threadFindMatches.count) % threadFindMatches.count
    selectedThreadFindMessageID = threadFindMatches[nextIndex].messageID
    requestThreadFindScroll()
  }

  private func requestThreadFindScroll() {
    guard selectedThreadFindMessageID != nil else { return }
    threadFindNavigationGeneration &+= 1
  }

  private struct ThreadOutputsSignature: Equatable {
    let threadID: UUID?
    let corpusRoot: String?
    let messageCount: Int
    let lastMessageID: UUID?
    let lastMessageLength: Int
    let lastMessageChangeCount: Int
  }

  private var threadOutputsSignature: ThreadOutputsSignature {
    let last = store.aiChatMessages.last
    return ThreadOutputsSignature(
      threadID: store.selectedAIChatThreadID,
      corpusRoot: store.corpusRoot?.path,
      messageCount: store.aiChatMessages.count,
      lastMessageID: last?.id,
      lastMessageLength: last?.content.utf8.count ?? 0,
      lastMessageChangeCount: last?.changeSummary?.files.count ?? -1
    )
  }

  private func refreshThreadOutputs() async {
    let threadID = store.selectedAIChatThreadID
    let messages = store.aiChatMessages
    let corpusRoot = store.corpusRoot?.standardizedFileURL.path
    let remoteRoot = store.aiChatOutputsRemoteCorpusPath
    if threadOutputsThreadID != threadID || threadOutputs.corpusRoot != corpusRoot || messages.isEmpty {
      threadOutputs = .empty
    }
    // Streaming replies change the signature often; settle before rescanning.
    try? await Task.sleep(for: .milliseconds(250))
    guard !Task.isCancelled else { return }
    let outputs = await Task.detached(priority: .utility) {
      AIChatThreadOutputs.derive(
        messages: messages,
        corpusRoot: corpusRoot,
        remoteCorpusRoot: remoteRoot
      ).resolvingFileStatus()
    }.value
    guard !Task.isCancelled, threadID == store.selectedAIChatThreadID else { return }
    threadOutputs = outputs
    threadOutputsThreadID = threadID
  }

  /// Scrolls the transcript to a reply, reusing the find bar's navigation.
  private func jumpToMessage(_ messageID: UUID) {
    let candidates = AIChatThreadSearch.candidates(
      in: store.aiChatMessages,
      isSharedRoom: store.selectedAIChatIsSharedRoom
    )
    guard let candidate = candidates.first(where: { $0.messageID == messageID }) else { return }
    transcriptWindowAnchor = AIChatTranscriptAnchor(
      itemID: candidate.scrollTargetID,
      rawMessageIndex: candidate.anchorRawMessageIndex
    )
    selectedThreadFindMessageID = messageID
    threadFindNavigationGeneration &+= 1
  }

  private func closeThreadFind() {
    threadFindIndexTask?.cancel()
    threadFindMatchTask?.cancel()
    isShowingThreadFind = false
    threadFindQuery = ""
    threadFindCandidates = []
    threadFindMatches = []
    selectedThreadFindMessageID = nil
    transcriptWindowAnchor = nil
  }
}

struct AIChatTranscriptAnchor: Equatable {
  let itemID: UUID
  let rawMessageIndex: Int
}

struct AIChatTranscriptStack<Content: View>: View {
  let spacing: CGFloat
  @ViewBuilder let content: () -> Content

  init(
    spacing: CGFloat,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.spacing = spacing
    self.content = content
  }

  var body: some View {
    // Chat rows change height while a turn starts and while structured content
    // finishes rendering. A LazyVStack can retain an estimated height across
    // those updates, leaving valid-looking document space below the last row.
    // Exact layout keeps ScrollViewReader and the native scroll view in sync.
    VStack(alignment: .leading, spacing: spacing) {
      content()
    }
    .textSelection(.enabled)
  }
}

struct AIChatTranscriptWindow: Equatable {
  static let initialLimit = 24
  static let pageSize = 40
  static let maximumDisplayLimit = initialLimit + (pageSize * 2)
  static let maximumRawMessageScanCount = maximumDisplayLimit * 4
  static let initialDisplayedContentUTF8ByteLimit = 256 * 1_024
  private static let pageDisplayedContentUTF8ByteLimit =
    pageSize * AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit

  let visibleItems: [AIChatRoomTranscriptItem]
  let displayLimit: Int
  let earlierBatchCount: Int
  let earlierPageAnchor: AIChatTranscriptAnchor?
  private let hasEarlierItems: Bool
  private let resolvedNextDisplayLimit: Int

  init(
    messages: [AIChatMessage],
    isSharedRoom: Bool,
    displayLimit: Int,
    anchor: AIChatTranscriptAnchor? = nil
  ) {
    let resolvedLimit = min(
      Self.maximumDisplayLimit,
      max(Self.initialLimit, displayLimit)
    )
    self.displayLimit = resolvedLimit
    let nextLimit = min(Self.maximumDisplayLimit, resolvedLimit + Self.pageSize)
    resolvedNextDisplayLimit = nextLimit
    let displayedContentLimit = Self.displayedContentUTF8ByteLimit(
      forDisplayLimit: resolvedLimit
    )
    let nextDisplayedContentLimit = Self.displayedContentUTF8ByteLimit(
      forDisplayLimit: nextLimit
    )
    let rawMessageRange = Self.boundedRawMessageRange(
      messageCount: messages.count,
      anchorRawMessageIndex: anchor?.rawMessageIndex
    )
    let boundedMessages = Array(messages[rawMessageRange])
    let candidates: [AIChatRoomTranscriptItem]
    if isSharedRoom {
      candidates = AIChatRoomTranscriptPresentation.items(
        messages: boundedMessages,
        isSharedRoom: true
      )
    } else {
      candidates = boundedMessages.compactMap { message in
        message.isRoomDispatchCopy ? nil : .message(message)
      }
    }
    let visible = Self.constrainedWindow(
      of: candidates,
      anchorItemID: anchor?.itemID,
      bubbleLimit: resolvedLimit,
      displayedContentUTF8ByteLimit: displayedContentLimit
    )
    let nextVisible = Self.constrainedWindow(
      of: candidates,
      anchorItemID: anchor?.itemID,
      bubbleLimit: nextLimit,
      displayedContentUTF8ByteLimit: nextDisplayedContentLimit
    )
    visibleItems = visible
    let hasRawMessagesBeforeWindow = rawMessageRange.lowerBound > messages.startIndex
    hasEarlierItems = hasRawMessagesBeforeWindow || Self.hasItemsBeforeVisible(
      visible,
      in: candidates
    )
    if hasEarlierItems {
      if nextVisible.visibleChatBubbleCount > visible.visibleChatBubbleCount {
        earlierBatchCount = max(
          1,
          nextVisible.visibleChatBubbleCount - visible.visibleChatBubbleCount
        )
      } else {
        earlierBatchCount = min(Self.pageSize, max(1, rawMessageRange.lowerBound))
      }
    } else {
      earlierBatchCount = 0
    }
    if hasEarlierItems,
       let firstVisibleItem = visible.first,
       let rawIndex = Self.rawMessageIndex(
         forItemID: firstVisibleItem.id,
         in: boundedMessages,
         absoluteOffset: rawMessageRange.lowerBound
       ) {
      earlierPageAnchor = AIChatTranscriptAnchor(
        itemID: firstVisibleItem.id,
        rawMessageIndex: rawIndex
      )
    } else {
      earlierPageAnchor = nil
    }
  }

  var visibleMessagesForPresentation: [AIChatMessage] {
    visibleItems.flatMap(\.visibleChatBubbleMessages)
  }

  var visibleChatBubbleCount: Int {
    visibleItems.visibleChatBubbleCount
  }

  var displayedContentUTF8ByteCount: Int {
    visibleItems.displayedContentUTF8ByteCount
  }

  var hasEarlierMessages: Bool { hasEarlierItems }

  var nextDisplayLimit: Int {
    resolvedNextDisplayLimit
  }

  var earlierMessagesTitle: String {
    earlierBatchCount == 1
      ? "Show 1 earlier message"
      : "Show \(earlierBatchCount) earlier messages"
  }

  func contains(_ id: UUID) -> Bool {
    visibleItems.contains(where: { $0.id == id })
  }

  static func displayedContentUTF8ByteLimit(forDisplayLimit displayLimit: Int) -> Int {
    let resolvedLimit = min(maximumDisplayLimit, max(initialLimit, displayLimit))
    let additionalBubbleCount = max(0, resolvedLimit - initialLimit)
    let additionalPages = (additionalBubbleCount + pageSize - 1) / pageSize
    return initialDisplayedContentUTF8ByteLimit
      + additionalPages * pageDisplayedContentUTF8ByteLimit
  }

  private static func boundedRawMessageRange(
    messageCount: Int,
    anchorRawMessageIndex: Int?
  ) -> Range<Int> {
    guard messageCount > maximumRawMessageScanCount else { return 0..<messageCount }
    guard let anchorRawMessageIndex else {
      return (messageCount - maximumRawMessageScanCount)..<messageCount
    }
    let anchorIndex = min(max(0, anchorRawMessageIndex), messageCount - 1)
    let leadingCount = maximumRawMessageScanCount / 2
    var lowerBound = max(0, anchorIndex - leadingCount)
    var upperBound = min(messageCount, lowerBound + maximumRawMessageScanCount)
    lowerBound = max(0, upperBound - maximumRawMessageScanCount)
    upperBound = min(messageCount, lowerBound + maximumRawMessageScanCount)
    return lowerBound..<upperBound
  }

  private static func hasItemsBeforeVisible(
    _ visible: [AIChatRoomTranscriptItem],
    in candidates: [AIChatRoomTranscriptItem]
  ) -> Bool {
    guard let firstVisibleID = visible.first?.id,
          let firstVisibleIndex = candidates.firstIndex(where: { $0.id == firstVisibleID })
    else { return false }
    return firstVisibleIndex > candidates.startIndex
  }

  private static func rawMessageIndex(
    forItemID itemID: UUID,
    in messages: [AIChatMessage],
    absoluteOffset: Int
  ) -> Int? {
    guard let index = messages.firstIndex(where: { message in
      message.id == itemID || message.roomRoundID == itemID
    }) else { return nil }
    return absoluteOffset + index
  }

  private static func constrainedWindow(
    of items: [AIChatRoomTranscriptItem],
    anchorItemID: UUID?,
    bubbleLimit: Int,
    displayedContentUTF8ByteLimit: Int
  ) -> [AIChatRoomTranscriptItem] {
    guard let anchorItemID,
          let anchorIndex = items.firstIndex(where: { $0.id == anchorItemID })
    else {
      return constrainedSuffix(
        of: items,
        bubbleLimit: bubbleLimit,
        displayedContentUTF8ByteLimit: displayedContentUTF8ByteLimit
      )
    }
    var lowerBound = anchorIndex
    var upperBound = anchorIndex + 1
    var bubbleCount = items[anchorIndex].visibleChatBubbleCount
    var displayedContentByteCount = items[anchorIndex].displayedContentUTF8ByteCount
    var growsBeforeNext = true
    var canGrowBefore = lowerBound > items.startIndex
    var canGrowAfter = upperBound < items.endIndex
    while canGrowBefore || canGrowAfter {
      let candidateIndex: Int
      if growsBeforeNext, canGrowBefore {
        candidateIndex = lowerBound - 1
      } else if canGrowAfter {
        candidateIndex = upperBound
      } else {
        candidateIndex = lowerBound - 1
      }
      let candidate = items[candidateIndex]
      let fits = bubbleCount + candidate.visibleChatBubbleCount <= bubbleLimit
        && displayedContentByteCount + candidate.displayedContentUTF8ByteCount
          <= displayedContentUTF8ByteLimit
      if fits {
        if candidateIndex < lowerBound {
          lowerBound = candidateIndex
        } else {
          upperBound = candidateIndex + 1
        }
        bubbleCount += candidate.visibleChatBubbleCount
        displayedContentByteCount += candidate.displayedContentUTF8ByteCount
      } else if candidateIndex < lowerBound {
        canGrowBefore = false
      } else {
        canGrowAfter = false
      }
      canGrowBefore = canGrowBefore && lowerBound > items.startIndex
      canGrowAfter = canGrowAfter && upperBound < items.endIndex
      growsBeforeNext.toggle()
    }
    return Array(items[lowerBound..<upperBound])
  }

  private static func constrainedSuffix(
    of items: [AIChatRoomTranscriptItem],
    bubbleLimit: Int,
    displayedContentUTF8ByteLimit: Int
  ) -> [AIChatRoomTranscriptItem] {
    var newestItems: [AIChatRoomTranscriptItem] = []
    newestItems.reserveCapacity(min(bubbleLimit, items.count))
    var bubbleCount = 0
    var displayedContentByteCount = 0
    for item in items.reversed() {
      let itemBubbleCount = item.visibleChatBubbleCount
      let itemContentByteCount = item.displayedContentUTF8ByteCount
      let fits = bubbleCount + itemBubbleCount <= bubbleLimit
        && displayedContentByteCount + itemContentByteCount <= displayedContentUTF8ByteLimit
      guard fits || newestItems.isEmpty else { break }
      newestItems.append(item)
      bubbleCount += itemBubbleCount
      displayedContentByteCount += itemContentByteCount
    }
    return Array(newestItems.reversed())
  }
}

extension Array where Element == AIChatRoomTranscriptItem {
  var visibleChatBubbleCount: Int {
    reduce(into: 0) { $0 += $1.visibleChatBubbleCount }
  }

  var displayedContentUTF8ByteCount: Int {
    reduce(into: 0) { $0 += $1.displayedContentUTF8ByteCount }
  }
}

struct AIChatScrollVisibility: Equatable {
  static let nearBottomThreshold = 0.985

  let position: Double
  let hasContent: Bool

  var isNearBottom: Bool {
    position >= Self.nearBottomThreshold
  }

  var showsJumpToBottom: Bool {
    hasContent && !isNearBottom
  }

  func updatedNearBottomState(after current: Bool) -> Bool? {
    isNearBottom == current ? nil : isNearBottom
  }
}

enum AIChatAutomaticScrollTarget: Equatable {
  case latestMessage
  case typingIndicator
}

struct AIChatScrollUpdate: Equatable {
  let threadID: UUID?
  let messageCount: Int
  let isSending: Bool

  func automaticTarget(after previous: Self) -> AIChatAutomaticScrollTarget? {
    guard threadID == previous.threadID else { return nil }
    if isSending && !previous.isSending {
      return .typingIndicator
    }
    if messageCount > previous.messageCount {
      return .latestMessage
    }
    return nil
  }
}

struct AIChatScrollRestoration: Equatable {
  let threadID: UUID?
  let selectionGeneration: Int
  let savedPosition: Double?

  var position: Double {
    min(1, max(0, savedPosition ?? 1))
  }

  func requiresNewRestoration(after previous: Self) -> Bool {
    threadID != previous.threadID || selectionGeneration != previous.selectionGeneration
  }
}

@MainActor
enum AIChatScrollGeometry {
  static func constrainedBounds(in scrollView: NSScrollView) -> NSRect? {
    let clipView = scrollView.contentView
    let currentBounds = clipView.bounds
    let constrainedBounds = clipView.constrainBoundsRect(currentBounds)
    guard abs(constrainedBounds.origin.x - currentBounds.origin.x) > 0.5
      || abs(constrainedBounds.origin.y - currentBounds.origin.y) > 0.5
    else {
      return nil
    }
    return constrainedBounds
  }
}

enum AIChatAccessibilityIdentity {
  static let transcriptScrollBridge = "org.openorg.chat.transcript-scroll-bridge"
}

struct OrgCryptConfigurationSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var encryptOnSave = true
  @State private var recipientsText = ""
  @State private var recipientFilesText = ""
  @State private var selectedManagedRecipientFilePaths = Set<String>()
  @State private var useDefaultGpgKey = true
  @State private var gpgProgram = "gpg"
  @State private var passphrase = ""
  @State private var clearPassphrase = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Encryption")
          .font(.title3.weight(.semibold))
        Text("Encrypt :crypt: subtrees with GPG.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Toggle("Encrypt plaintext :crypt: subtrees on explicit save", isOn: $encryptOnSave)
      Toggle("Use default GPG key as recipient", isOn: $useDefaultGpgKey)

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Recipients")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextEditor(text: $recipientsText)
            .font(.system(.body, design: .monospaced))
            .frame(width: 430, height: 72)
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(WorkspaceDesign.hairline)
            )
        }

        GridRow {
          Text("Agent Keys")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(store.orgCryptPublicKeysDirectoryURL?.path ?? "Choose a corpus to use public-keys")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 0)
              Button {
                if let imported = store.chooseOrgCryptAgentPublicKey() {
                  selectedManagedRecipientFilePaths.insert(imported.path)
                }
              } label: {
                Label("Add Agent Public Key", systemImage: "plus")
              }
              .disabled(store.corpusRoot == nil)
            }

            if store.orgCryptManagedRecipientFiles.isEmpty {
              Text("No public keys in public-keys")
                .font(.callout)
                .foregroundStyle(.tertiary)
            } else {
              ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                  ForEach(store.orgCryptManagedRecipientFiles) { file in
                    Toggle(isOn: managedRecipientFileBinding(file.path)) {
                      VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                          .font(.callout)
                        Text(file.relativePath)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                    }
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .frame(maxHeight: 140)
            }
          }
          .frame(width: 430, alignment: .leading)
        }

        GridRow {
          Text("Other Files")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextEditor(text: $recipientFilesText)
            .font(.system(.body, design: .monospaced))
            .frame(width: 430, height: 58)
            .overlay(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(WorkspaceDesign.hairline)
            )
        }

        GridRow {
          Text("GPG")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          TextField("gpg", text: $gpgProgram)
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
        }

        GridRow {
          Text("Passphrase")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          SecureField(store.orgCryptHasStoredPassphrase ? "Saved passphrase unchanged" : "Optional symmetric passphrase", text: $passphrase)
            .textFieldStyle(.roundedBorder)
            .frame(width: 430)
        }
      }

      Toggle("Clear saved passphrase", isOn: $clearPassphrase)
        .disabled(!store.orgCryptHasStoredPassphrase)

      if !store.orgCryptStatusText.isEmpty {
        Text(store.orgCryptStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        Button("Save") {
          let combinedRecipientFilesText = store.combinedOrgCryptRecipientFilesText(
            manualText: recipientFilesText,
            selectedManagedPaths: selectedManagedRecipientFilePaths
          )
          let saved = store.saveOrgCryptConfiguration(
            encryptOnSave: encryptOnSave,
            recipientsText: recipientsText,
            recipientFilesText: combinedRecipientFilesText,
            useDefaultGpgKey: useDefaultGpgKey,
            gpgProgram: gpgProgram,
            passphrase: passphrase,
            clearPassphrase: clearPassphrase
          )
          if saved {
            dismiss()
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
    .frame(width: 620)
    .onAppear {
      store.refreshOrgCryptManagedRecipientFiles()
      encryptOnSave = store.orgCryptEncryptOnSave
      recipientsText = store.orgCryptRecipientsText
      selectedManagedRecipientFilePaths = store.selectedManagedOrgCryptRecipientFilePaths(in: store.orgCryptRecipientFilesText)
      recipientFilesText = store.manualOrgCryptRecipientFilesText(from: store.orgCryptRecipientFilesText)
      useDefaultGpgKey = store.orgCryptUseDefaultGpgKey
      gpgProgram = store.orgCryptGpgProgram
      passphrase = ""
      clearPassphrase = false
    }
  }

  private func managedRecipientFileBinding(_ path: String) -> Binding<Bool> {
    Binding {
      selectedManagedRecipientFilePaths.contains(path)
    } set: { isSelected in
      if isSelected {
        selectedManagedRecipientFilePaths.insert(path)
      } else {
        selectedManagedRecipientFilePaths.remove(path)
      }
    }
  }
}

struct DataSourceConfigurationSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var apiKey = ""
  @State private var clearAPIKey = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Data Refresh Credentials")
          .font(.title3.weight(.semibold))
        Text("Used when a notebook refreshes the Scarf Metabase data source.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if let failure = store.dataNotebookRefreshFailure,
         failure.needsCredentialUpdate {
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: failure.kind == .authentication ? "key.slash.fill" : "key.fill")
            .foregroundStyle(.orange)
          VStack(alignment: .leading, spacing: 3) {
            Text(failure.title)
              .font(.callout.weight(.semibold))
            Text(failure.message)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        }
      }

      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text("API Key")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(width: 74, alignment: .trailing)
        SecureField(
          store.dataNotebookRefreshFailure?.kind == .authentication
            ? "Paste a new Metabase API key"
            : (store.scarfMetabaseHasStoredAPIKey ? "Saved key unchanged" : "Metabase API key"),
          text: $apiKey
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 360)
      }

      Toggle("Clear saved API key", isOn: $clearAPIKey)
        .disabled(!store.scarfMetabaseHasStoredAPIKey)

      Text("The API key is stored in macOS Keychain. Non-secret data-source settings live in the corpus's celorga.json.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let configurationError = store.dataSourceConfigurationError {
        Label(configurationError, systemImage: "exclamationmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(store.dataNotebookRefreshFailure == nil ? "Save" : "Save & Retry") {
          let shouldRetry = store.dataNotebookRefreshFailure != nil && store.selectedFileIsDataNotebook
          if store.saveScarfMetabaseConfiguration(
            apiKey: apiKey,
            clearAPIKey: clearAPIKey
          ) {
            dismiss()
            if shouldRetry {
              Task { await store.refreshSelectedDataNotebook() }
            }
          }
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(22)
    .frame(width: 540)
    .onAppear {
      apiKey = ""
      clearAPIKey = false
    }
  }
}

private struct EmptyChatView: View {
  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 20) {
          VStack(spacing: 10) {
            Text("What would you like to work on?")
              .font(.system(size: 27, weight: .medium, design: .serif))
              .foregroundStyle(WorkspaceDesign.primaryText)
              .multilineTextAlignment(.center)
            Text("Message your agents. Use \(contextSymbol("@")) to add an agent or file to the context, and \(contextSymbol("/")) for skills.")
              .font(.system(size: 13))
              .foregroundStyle(WorkspaceDesign.secondaryText)
              .multilineTextAlignment(.center)
              .lineSpacing(4)
          }
        }
        .frame(maxWidth: 360)
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
      }
    }
    .accessibilityIdentifier("ai-chat-empty-state")
  }

  private func contextSymbol(_ symbol: String) -> Text {
    Text(symbol)
      .font(.system(size: 13, weight: .semibold, design: .monospaced))
      .foregroundColor(WorkspaceDesign.structuralAccent)
  }

}

struct AssignedWorkRow: View {
  let item: AssignedWorkItem
  let sourceReference: String
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "person.crop.circle.badge.checkmark")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          if let todo = item.todo, !todo.isEmpty {
            Text(todo)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text(Org2Display.cleanInline(item.headline))
            .font(.body.weight(.medium))
            .lineLimit(1)
        }
        HStack(spacing: 6) {
          Text(item.status)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
          Text(sourceReference)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let last = item.lastAgentUpdate ?? item.assignedAt {
            Text(last)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .workspaceSelectableRow(
      isSelected: isSelected,
      trailingPadding: WorkspaceDesign.contentInset,
      verticalPadding: WorkspaceDesign.rowVerticalPadding
    )
  }
}

struct DetailView: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let run = store.presentedAgentRun {
        RunCenterDetail(run: run)
      } else if store.presentedWebPageURL != nil {
        WorkspaceWebPageDetailPane()
          .frame(minWidth: 420, idealWidth: 560, maxHeight: .infinity)
      } else if let missingDailyNote = store.missingDailyNote {
        MissingDailyNoteView(note: missingDailyNote)
      } else if let location = store.selectedLocation {
        DetailHeader(
          sourceEditorInteraction: store.sourceEditorInteraction,
          location: location,
          renderedViewportSourceLine: store.currentDocumentViewportSourceLine
        )
        Divider()
        VStack(spacing: 0) {
          if store.selectedFileIsCanvas {
            JSONCanvasWorkspaceView(file: location.file)
              .id(location.file)
              .frame(minWidth: 420, idealWidth: 720, maxHeight: .infinity)
          } else if store.selectedFileIsPDF {
            LinkedPDFPreviewPane()
              .frame(minWidth: 420, idealWidth: 560, maxHeight: .infinity)
          } else if store.selectedFileIsImage || store.selectedFileIsVideo {
            LinkedMediaPreviewPane(
              file: location.file,
              kind: store.selectedFileIsVideo ? .video : .image,
              revision: store.linkedMediaPreviewRevision
            )
            .id(location.file)
            .frame(minWidth: 420, idealWidth: 560, maxHeight: .infinity)
          } else if store.showsSelectedHTMLFileAsPage {
            HTMLFilePreviewPane(file: location.file, revision: store.linkedMediaPreviewRevision)
              .id(location.file)
              .frame(minWidth: 420, idealWidth: 560, maxHeight: .infinity)
          } else if store.isLiveFileEditorSelected {
            LiveFileEditorBody(
              location: location,
              reportViewportSourceLine: { store.recordDocumentViewportSourceLine($0) }
            )
              .frame(minWidth: 420, idealWidth: 560, maxHeight: .infinity)
          } else {
            EntryBodyView(
              location: location,
              reportViewportSourceLine: { store.recordDocumentViewportSourceLine($0) }
            )
            .frame(minWidth: 420, idealWidth: 560, maxHeight: .infinity)
          }

          if store.isNodeContextPanePresented {
            Divider()
            NodeContextPane()
              .frame(minWidth: 280, idealHeight: 260, maxHeight: 360)
          }
        }
      } else {
        EmptyStateView(title: "No Selection", detail: store.statusText, action: "Open Corpus") {
          store.chooseCorpus()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

}

private struct MissingDailyNoteView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isFormatSheetPresented = false
  let note: WorkspaceMissingDailyNote

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      WorkspaceIconBadge(
        systemImage: "calendar.badge.exclamationmark",
        tint: .secondary,
        fill: WorkspaceDesign.subtleFill
      )
      .scaleEffect(1.25)
      Text("No Daily File Found")
        .font(.headline)
      Text("Celorga did not find \(note.relativePath). Automatic daily note creation is disabled for this workspace.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .padding(.horizontal, 24)
      Button {
        store.createMissingDailyNote()
      } label: {
        if store.isCreatingMissingDailyNote {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Creating…")
          }
        } else {
          Text("Create Daily Note")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .disabled(store.isCreatingMissingDailyNote)
      Button("Use My Own Daily Notes…") { isFormatSheetPresented = true }
        .buttonStyle(.link)
        .help("Point Celorga at one of your existing daily notes so Today, Yesterday, and Tomorrow open your own files.")
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $isFormatSheetPresented) {
      DailyNoteFormatSheet(isPresented: $isFormatSheetPresented) {
        if note.opensHome { store.openHome() } else { store.openDailyNote(.today) }
      }
      .environment(store)
    }
  }
}

struct NodeEntityTypeMenu: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    Menu {
      ForEach(Org2EntityType.common) { entityType in
        Button {
          Task { await store.setSelectedNodeEntityType(entityType) }
        } label: {
          Label(entityType.title, systemImage: entityType.systemImage)
        }
      }

      Divider()

      Button {
        store.promptAndSetSelectedNodeEntityType()
      } label: {
        Label("Custom Type…", systemImage: "text.cursor")
      }

      if store.selectedNodeHasExplicitEntityType {
        Divider()
        Button(role: .destructive) {
          Task { await store.setSelectedNodeEntityType(nil) }
        } label: {
          Label("Remove Explicit Type", systemImage: "tag.slash")
        }
      }
    } label: {
      let entityType = store.selectedNodeEntityType
      Label(entityType?.title ?? "Set type", systemImage: entityType?.systemImage ?? "tag")
        .font(.caption.weight(.medium))
        .foregroundStyle(entityType == nil ? WorkspaceDesign.secondaryText : Color.accentColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
          (entityType == nil ? Color.secondary : Color.accentColor).opacity(0.09),
          in: Capsule()
        )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(!store.canSetSelectedNodeEntityType)
    .help(store.canSetSelectedNodeEntityType
      ? "Change this node's Celorga entity type"
      : "Node type is read-only while this document is unavailable or being edited")
  }
}

struct GoogleDrivePublicationMenu: View {
  let publications: [GoogleDrivePublicationBinding]

  var body: some View {
    Menu {
      ForEach(publications) { publication in
        Menu {
          Button("Open") {
            NSWorkspace.shared.open(publication.url)
          }
          Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(publication.url.absoluteString, forType: .string)
          }
        } label: {
          Label(
            "\(publication.format.title) · \(publication.scopeLabel)",
            systemImage: publication.format.systemImage
          )
        }
      }
    } label: {
      Label("Google Drive", systemImage: "link.circle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.green)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.09), in: Capsule())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Open or copy this document's linked Google Drive publication")
  }
}

private struct DetailScrollCommandBridge: NSViewRepresentable {
  let request: DetailScrollRequest?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let request, context.coordinator.lastRequestID != request.id else { return }
    guard case .page(let requestDirection) = request.target else { return }
    context.coordinator.lastRequestID = request.id

    DispatchQueue.main.async {
      guard let scrollView = view.enclosingScrollView,
            let documentView = scrollView.documentView
      else { return }

      let clipView = scrollView.contentView
      let visibleHeight = clipView.bounds.height
      guard visibleHeight > 0 else { return }

      let distance = max(120, visibleHeight * 0.8)
      let direction: CGFloat = requestDirection == .down ? 1 : -1
      let flippedMultiplier: CGFloat = documentView.isFlipped ? 1 : -1
      let maxY = max(0, documentView.bounds.height - visibleHeight)
      var origin = clipView.bounds.origin
      origin.y = min(max(0, origin.y + distance * direction * flippedMultiplier), maxY)
      clipView.scroll(to: origin)
      scrollView.reflectScrolledClipView(clipView)
    }
  }

  final class Coordinator {
    var lastRequestID: Int?
  }
}
