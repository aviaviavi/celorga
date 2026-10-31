import AppKit
import SwiftUI

enum AIChatSidebarThreadLayout {
  static let leadingPadding: CGFloat = 12
}

enum AIChatSettledThreadPagination {
  static let pageSize = 30

  static func nextLimit(currentLimit: Int, totalCount: Int) -> Int {
    min(max(0, totalCount), max(pageSize, currentLimit + pageSize))
  }

  static func clampedLimit(currentLimit: Int, totalCount: Int) -> Int {
    guard totalCount > 0 else { return pageSize }
    return min(totalCount, max(pageSize, currentLimit))
  }

  static func moreTitle(currentLimit: Int, totalCount: Int) -> String {
    let remaining = max(0, totalCount - currentLimit)
    let nextCount = min(pageSize, remaining)
    return "Show \(nextCount) more · \(remaining) remaining"
  }
}

struct AIChatSidebarThreadRowIdentity: Hashable {
  let threadID: UUID

  init(thread: AIChatThread) {
    self.init(summary: AIChatSidebarThreadSummary(thread: thread))
  }

  init(summary: AIChatSidebarThreadSummary) {
    threadID = summary.id
  }
}

struct AIChatSidebarThreadSummary: Identifiable, Hashable {
  let id: UUID
  let title: String
  let updatedAt: Date
  let runtime: AIChatRuntime
  let destinationID: String
  let isSharedRoom: Bool
  let messageCount: Int
  let isSettled: Bool
  let hasResource: Bool
  let latestDeliveryNeedsAttention: Bool
  let isPinned: Bool
  let unreadMessageCount: Int

  init(thread: AIChatThread, messageCount: Int? = nil) {
    id = thread.id
    title = thread.title
    updatedAt = thread.updatedAt
    runtime = thread.runtime
    destinationID = thread.destinationID
    isSharedRoom = thread.isSharedRoom
    self.messageCount = messageCount ?? thread.messageCount
    isSettled = thread.isSettled
    hasResource = thread.resource != nil
    latestDeliveryNeedsAttention = thread.latestDeliveryNeedsAttention
    isPinned = thread.isPinned
    unreadMessageCount = thread.unreadMessageCount
  }
}

struct AIChatSidebarThreadRow: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isHovered = false
  let summary: AIChatSidebarThreadSummary
  let isSending: Bool
  let select: () -> Void
  let rename: (UUID) -> Void
  let fork: () -> Void
  let togglePin: () -> Void
  let settle: () -> Void
  let reopen: () -> Void

  private var isSelected: Bool {
    store.selectedAIChatThreadID == summary.id
      && store.selectedSurface == .aiChat
  }

  var body: some View {
    HStack(spacing: 2) {
      Button(action: select) {
        HStack(alignment: .center, spacing: 8) {
          let projects = store.projectNotes.filter { $0.contains(summary.id) && $0.color != "none" }
          if !projects.isEmpty {
            HStack(spacing: 2) {
              ForEach(projects.prefix(3)) { project in
                Capsule().fill(project.tint.opacity(0.55)).frame(width: 3, height: 20)
              }
            }
            .help(projects.map(\.title).joined(separator: ", "))
            .accessibilityLabel("Projects: " + projects.map(\.title).joined(separator: ", "))
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
              .font(.callout.weight(isSelected ? .medium : .regular))
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.tail)
            HStack(spacing: 5) {
              Text(summary.messageCount == 1 ? "1 message" : "\(summary.messageCount) messages")
              Text("·")
              Text(summary.isSharedRoom ? "Room" : store.aiChatDestinationTitle(summary.destinationID))
              Text("·")
              Text(Self.relativeDate(summary.updatedAt))
              if summary.isSettled {
                Text("· Settled")
              }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
          }
          Spacer(minLength: 4)
          if isSending {
            AIChatSidebarThreadActivityView(isSelected: isSelected)
              .help("\(store.aiChatDestinationTitle(summary.destinationID)) is thinking")
          }
          if summary.hasResource {
            Image(systemName: "text.bubble.fill")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .help("Canonical resource thread")
          }
          if summary.latestDeliveryNeedsAttention {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.orange)
              .help("Latest message needs attention")
          }
          if summary.isPinned {
            Image(systemName: "pin.fill")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          if summary.unreadMessageCount > 0 {
            AIChatUnreadBadge(count: summary.unreadMessageCount)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, AIChatSidebarThreadLayout.leadingPadding)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      AIChatSidebarThreadSettlementButton(
        isSettled: summary.isSettled,
        isVisible: isSelected || isHovered
      ) {
        summary.isSettled ? reopen() : settle()
      }
    }
    .padding(.trailing, 6)
    .workspaceSelectableRow(
      isSelected: isSelected,
      showsSelectionMarker: false,
      leadingPadding: 0,
      trailingPadding: 0,
      cornerRadius: WorkspaceDesign.controlRadius
    )
    .contentShape(Rectangle())
    .onHover { hovered in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovered = hovered
      }
    }
    .contextMenu {
      if !store.projectNotes.isEmpty {
        Menu("Projects") {
          ForEach(store.projectNotes) { project in
            Button { Task { await store.updateProject(project, threadID: summary.id) } } label: {
              Label(project.title, systemImage: project.contains(summary.id) ? "checkmark.circle.fill" : "circle")
            }
          }
        }
      }
      Button {
        rename(summary.id)
      } label: {
        Label("Rename Thread", systemImage: "pencil")
      }

      Button {
        fork()
      } label: {
        Label("Fork Thread", systemImage: "arrow.triangle.branch")
      }

      Button {
        AIChatMessageClipboard.write(summary.id.uuidString.lowercased())
      } label: {
        Label("Copy Thread ID", systemImage: "doc.on.doc")
      }

      Button {
        Task { await store.copyChatThreadShareLink(summary.id) }
      } label: {
        Label("Copy Share Link", systemImage: "link")
      }

      if store.isChatThreadShared(summary.id) {
        Button {
          store.stopSharingChatThread(summary.id)
        } label: {
          Label("Stop Sharing", systemImage: "xmark.circle")
        }
      }

      Button {
        togglePin()
      } label: {
        Label(
          summary.isPinned ? "Unpin Thread" : "Pin Thread",
          systemImage: summary.isPinned ? "pin.slash" : "pin"
        )
      }

      if summary.isSettled {
        Button {
          reopen()
        } label: {
          Label("Reopen Thread", systemImage: "arrow.uturn.backward.circle")
        }
      } else {
        Button {
          settle()
        } label: {
          Label("Settle Thread", systemImage: "checkmark.circle")
        }
      }

      if WorkspaceStore.isAutomationAIChatThreadTitle(summary.title) {
        Divider()
        Button {
          store.markAllAutomationAIChatThreadsReadAndSettled()
        } label: {
          Label(AIChatAutomationThreadsAction.title, systemImage: AIChatAutomationThreadsAction.systemImage)
        }
      }
    }
    .overlay {
      // SwiftUI can reuse another recycled row's context-menu action when this
      // is opened with a physical right-click. A native hit target keeps the menu
      // attached to the NSView that was actually clicked while the SwiftUI menu
      // remains available to accessibility actions.
      AIChatSidebarThreadContextMenuTarget(
        threadID: summary.id,
        title: summary.title,
        isSelected: isSelected,
        isPinned: summary.isPinned,
        isSettled: summary.isSettled,
        select: select,
        rename: rename,
        fork: fork,
        togglePin: togglePin,
        settle: settle,
        reopen: reopen,
        isShared: store.isChatThreadShared(summary.id),
        copyShareLink: { id in Task { await store.copyChatThreadShareLink(id) } },
        stopSharing: { id in store.stopSharingChatThread(id) },
        isAutomation: WorkspaceStore.isAutomationAIChatThreadTitle(summary.title),
        markAllAutomationThreads: { store.markAllAutomationAIChatThreadsReadAndSettled() },
        projects: store.projectNotes,
        toggleProject: { id in
          guard let project = store.projectNotes.first(where: { $0.id == id }) else { return }
          Task { await store.updateProject(project, threadID: summary.id) }
        }
      )
    }
  }

  private static func relativeDate(_ date: Date) -> String {
    let elapsed = max(0, Date().timeIntervalSince(date))
    if elapsed < 60 { return "now" }
    if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
    if elapsed < 86_400 { return "\(Int(elapsed / 3600))h" }
    if elapsed < 604_800 { return "\(Int(elapsed / 86_400))d" }
    return shortDateFormatter.string(from: date)
  }

  private static let shortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter
  }()
}

struct AIChatSidebarThreadActivityView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let isSelected: Bool

  init(isSelected: Bool = true) {
    self.isSelected = isSelected
  }

  var statusTitle: String { "Working" }
  var shouldAnimate: Bool { isSelected && !reduceMotion }

  var body: some View {
    HStack(spacing: 4) {
      ZStack {
        Circle()
          .fill(Color.accentColor.opacity(0.14))
          .frame(width: 12, height: 12)
        CoreAnimationActivityDot(animates: shouldAnimate)
          .frame(width: 5, height: 5)
          .id(shouldAnimate)
      }
      .accessibilityHidden(true)

      Text(statusTitle)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.accentColor)
    }
    .fixedSize()
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Color.accentColor.opacity(0.07), in: Capsule())
    .overlay {
      Capsule()
        .stroke(Color.accentColor.opacity(0.14), lineWidth: 0.5)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(statusTitle)
  }
}

private struct AIChatSidebarThreadContextMenuTarget: NSViewRepresentable {
  let threadID: UUID
  let title: String
  let isSelected: Bool
  let isPinned: Bool
  let isSettled: Bool
  let select: () -> Void
  let rename: (UUID) -> Void
  let fork: () -> Void
  let togglePin: () -> Void
  let settle: () -> Void
  let reopen: () -> Void
  let isShared: Bool
  let copyShareLink: (UUID) -> Void
  let stopSharing: (UUID) -> Void
  let isAutomation: Bool
  let markAllAutomationThreads: () -> Void

  let projects: [WorkspaceProjectNote]
  let toggleProject: (String) -> Void

  func makeNSView(context: Context) -> ContextMenuView {
    ContextMenuView()
  }

  func updateNSView(_ view: ContextMenuView, context: Context) {
    view.projects = projects
    view.toggleProject = toggleProject
    view.threadID = threadID
    view.isPinned = isPinned
    view.isSettled = isSettled
    view.select = select
    view.rename = rename
    view.fork = fork
    view.togglePin = togglePin
    view.settle = settle
    view.reopen = reopen
    view.isShared = isShared
    view.copyShareLink = copyShareLink
    view.stopSharing = stopSharing
    view.isAutomation = isAutomation
    view.markAllAutomationThreads = markAllAutomationThreads
    view.setAccessibilityIdentifier(
      AIChatSidebarThreadAccessibilityIdentity.accessibilityIdentifier(for: threadID)
    )
    view.setAccessibilityLabel(title)
    view.setAccessibilitySelected(isSelected)
  }

  final class ContextMenuView: NSView {
    var projects: [WorkspaceProjectNote] = []
    var toggleProject: ((String) -> Void)?
    var threadID: UUID?
    var isPinned = false
    var isSettled = false
    var select: (() -> Void)?
    var rename: ((UUID) -> Void)?
    var fork: (() -> Void)?
    var togglePin: (() -> Void)?
    var settle: (() -> Void)?
    var reopen: (() -> Void)?
    var isShared = false
    var copyShareLink: ((UUID) -> Void)?
    var stopSharing: ((UUID) -> Void)?
    var isAutomation = false
    var markAllAutomationThreads: (() -> Void)?

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      setAccessibilityElement(true)
      setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard bounds.contains(point), NSApp.currentEvent?.type == .rightMouseDown else { return nil }
      return self
    }

    override func rightMouseDown(with event: NSEvent) {
      let menu = NSMenu()
      menu.autoenablesItems = false
      menu.addItem(menuItem(
        title: "Rename Thread",
        systemImage: "pencil",
        action: #selector(renameThread)
      ))
      menu.addItem(menuItem(
        title: "Fork Thread",
        systemImage: "arrow.triangle.branch",
        action: #selector(forkThread)
      ))
      menu.addItem(menuItem(
        title: "Copy Thread ID",
        systemImage: "doc.on.doc",
        action: #selector(copyThreadID)
      ))
      menu.addItem(menuItem(
        title: "Copy Share Link",
        systemImage: "link",
        action: #selector(copyThreadShareLink)
      ))
      if isShared {
        menu.addItem(menuItem(
          title: "Stop Sharing",
          systemImage: "xmark.circle",
          action: #selector(stopSharingThread)
        ))
      }
      menu.addItem(menuItem(
        title: isPinned ? "Unpin Thread" : "Pin Thread",
        systemImage: isPinned ? "pin.slash" : "pin",
        action: #selector(toggleThreadPin)
      ))
      menu.addItem(menuItem(
        title: isSettled ? "Reopen Thread" : "Settle Thread",
        systemImage: isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle",
        action: #selector(toggleThreadSettlement)
      ))
      if isAutomation {
        menu.addItem(.separator())
        menu.addItem(menuItem(
          title: AIChatAutomationThreadsAction.title,
          systemImage: AIChatAutomationThreadsAction.systemImage,
          action: #selector(markAllAutomationThreadsReadAndSettled)
        ))
      }
      if !projects.isEmpty {
        let submenu = NSMenu(title: "Projects")
        for project in projects {
          let item = menuItem(title: project.title, systemImage: "circle", action: #selector(toggleThreadProject(_:)))
          item.representedObject = project.id
          item.state = threadID.map { project.contains($0) } == true ? .on : .off
          submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Projects", action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
      }
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
      select?()
      return true
    }

    private func menuItem(title: String, systemImage: String, action: Selector) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
      item.isEnabled = true
      return item
    }

    @objc func toggleThreadProject(_ sender: NSMenuItem) {
      guard let id = sender.representedObject as? String else { return }
      toggleProject?(id)
    }

    @objc func renameThread() {
      guard let threadID else { return }
      rename?(threadID)
    }

    @objc func toggleThreadPin() {
      togglePin?()
    }

    @objc func forkThread() {
      fork?()
    }

    @objc func copyThreadID() {
      guard let threadID else { return }
      AIChatMessageClipboard.write(threadID.uuidString.lowercased())
    }

    @objc func copyThreadShareLink() {
      guard let threadID else { return }
      copyShareLink?(threadID)
    }

    @objc func stopSharingThread() {
      guard let threadID else { return }
      stopSharing?(threadID)
    }

    @objc func toggleThreadSettlement() {
      isSettled ? reopen?() : settle?()
    }

    @objc func markAllAutomationThreadsReadAndSettled() {
      markAllAutomationThreads?()
    }
  }
}

enum AIChatAutomationThreadsAction {
  static let title = "Mark All Automation Threads Read & Settled"
  static let systemImage = "checkmark.rectangle.stack"
}

struct AIChatUnreadBadge: View {
  let count: Int
  var compact = false

  var body: some View {
    ZStack {
      Circle()
        .fill(Color.red)
      if !compact {
        Text(count > 9 ? "9+" : "\(count)")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .minimumScaleFactor(0.75)
      }
    }
    .frame(width: compact ? 8 : 16, height: compact ? 8 : 16)
    .accessibilityLabel(count == 1 ? "1 unread message" : "\(count) unread messages")
  }
}

struct CanvasesView: View {
  @Environment(WorkspaceStore.self) private var store
  @FocusState private var filterFocused: Bool
  @State private var filter = ""

  private var canvases: [CorpusFile] {
    store.corpusFiles.filter {
      URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "canvas"
        && (filter.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(filter))
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Canvases", subtitle: "Spatial workspaces", surface: .canvases) {
        if store.experimentalFeaturesEnabled {
          Button("New Canvas…", systemImage: "plus") {
            Task { await store.createJSONCanvasFromPanel() }
          }
          .disabled(store.corpusRoot == nil)
          Button("Import Canvas…", systemImage: "square.and.arrow.down") {
            Task { await store.createJSONCanvasFromPanel(importing: true) }
          }
          .disabled(store.corpusRoot == nil)
        }
      }
      if !store.experimentalFeaturesEnabled {
        Text("Enable Experimental Features in Settings to use Canvases.")
          .foregroundStyle(.secondary)
          .padding()
        Spacer()
      } else {
        TextField("Filter canvases", text: $filter)
          .textFieldStyle(.roundedBorder)
          .focused($filterFocused)
          .padding(.horizontal, WorkspaceDesign.contentInset)
          .padding(.bottom, 12)
        if canvases.isEmpty {
          EmptyStateView(title: "No Canvases", detail: "Create a spatial workspace or import a .canvas file.", action: "New Canvas…") {
            Task { await store.createJSONCanvasFromPanel() }
          }
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(canvases) { file in
                Button {
                  store.selectCorpusFile(file, surface: .canvases)
                } label: {
                  HStack {
                    Label(file.name, systemImage: "rectangle.3.group")
                    Spacer()
                    Text(file.relativePath).foregroundStyle(.secondary)
                  }
                  .padding(12)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { CorpusFileContextMenu(file: file) }
              }
            }
            .padding(.horizontal, WorkspaceDesign.contentInset)
          }
        }
      }
    }
    .onChange(of: store.corpusFileFilterFocusToken) { filterFocused = true }
  }
}

struct FilesView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID
  @FocusState private var filterFocused: Bool
  @State private var filterDraft = ""
  @State private var pendingFilterUpdate: Task<Void, Never>?
  @State private var expandedFileDirectoryIDs: Set<String> = []

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(title: "Files", subtitle: store.corpusRoot?.path ?? "Corpus files", surface: .files) {
        Menu {
          Button("New Canvas…") { Task { await store.createJSONCanvasFromPanel() } }
          Button("Import Canvas…") { Task { await store.createJSONCanvasFromPanel(importing: true) } }
        } label: { Label("Canvas", systemImage: "rectangle.3.group") }
        .disabled(store.corpusRoot == nil)
        if store.isScanningCorpusFiles {
          WorkspaceActivityIndicator(size: .small)
        }

        Button {
          Task { await store.refreshCorpusFiles() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isScanningCorpusFiles)

        Button {
          store.presentQuickOpen()
        } label: {
          Label("Quick Open", systemImage: "command")
        }
      }

      HStack(spacing: 8) {
        TextField("Filter files", text: $filterDraft)
          .textFieldStyle(.roundedBorder)
          .focused($filterFocused)
          .onChange(of: filterDraft) { scheduleFilterUpdate() }
          .onSubmit { applyFilterImmediately() }
        if !filterDraft.isEmpty {
          Button {
            filterDraft = ""
            store.corpusFileFilter = ""
          } label: {
            Label("Clear", systemImage: "xmark.circle.fill")
          }
          .labelStyle(.iconOnly)
        }
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 12)

      if store.corpusRoot == nil {
        EmptyStateView(title: "No Corpus", detail: store.statusText, action: "Open Corpus") {
          store.chooseCorpus()
        }
      } else if store.corpusFiles.isEmpty && store.isScanningCorpusFiles {
        Spacer()
        WorkspaceLoadingStateView("Scanning files")
        Spacer()
      } else if store.filteredCorpusFiles.isEmpty {
        EmptyStateView(title: "No Files", detail: "No Org, Markdown, CSV, or Canvas files matched.", action: "Refresh") {
          Task { await store.refreshCorpusFiles() }
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            if filterDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              ForEach(visibleFileRows) { row in
                CorpusFileTreeRow(
                  row: row,
                  isExpanded: expandedFileDirectoryIDs.contains(row.id),
                  toggleDirectory: { toggleFileDirectory(row.id) }
                )
                  .frame(minHeight: 44)
              }
            } else {
              ForEach(store.filteredCorpusFiles) { file in
                CorpusFileTreeRow(
                  row: CorpusFileTreePresentationRow(
                    node: CorpusFileTreeNode(
                      id: file.id,
                      name: file.name,
                      relativePath: file.relativePath,
                      file: file,
                      children: nil,
                      descendantFileCount: 1
                    ),
                    depth: 0
                  ),
                  isExpanded: false,
                  toggleDirectory: {}
                )
                .frame(height: 52)
              }
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
        }
        .background(WorkspaceDesign.surfaceBackground)
        .onChange(of: store.selectedCorpusFileID) {
          guard let id = store.selectedCorpusFileID,
                let file = store.corpusFiles.first(where: { $0.id == id })
          else {
            return
          }
          performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
            store.activateSelectedCorpusFileFromList(file)
          }
        }
      }
    }
    .onChange(of: store.corpusFileFilterFocusToken) {
      filterFocused = true
    }
    .onAppear { filterDraft = store.corpusFileFilter }
    .onChange(of: store.corpusFileFilter) {
      if filterDraft != store.corpusFileFilter {
        filterDraft = store.corpusFileFilter
      }
    }
    .onChange(of: store.corpusRoot?.path) {
      expandedFileDirectoryIDs = []
    }
    .onDisappear { pendingFilterUpdate?.cancel() }
  }

  private var visibleFileRows: [CorpusFileTreePresentationRow] {
    CorpusFileTreePresentation.visibleRows(
      in: store.filteredCorpusFileTree,
      expandedDirectoryIDs: expandedFileDirectoryIDs
    )
  }

  private func toggleFileDirectory(_ id: String) {
    if expandedFileDirectoryIDs.contains(id) {
      expandedFileDirectoryIDs.remove(id)
    } else {
      expandedFileDirectoryIDs.insert(id)
    }
  }

  private func scheduleFilterUpdate() {
    pendingFilterUpdate?.cancel()
    let nextFilter = filterDraft
    guard nextFilter != store.corpusFileFilter else { return }
    pendingFilterUpdate = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
      guard !Task.isCancelled else { return }
      store.corpusFileFilter = nextFilter
    }
  }

  private func applyFilterImmediately() {
    pendingFilterUpdate?.cancel()
    pendingFilterUpdate = nil
    if store.corpusFileFilter != filterDraft {
      store.corpusFileFilter = filterDraft
    }
  }
}

private struct CorpusFileTreeRow: View {
  @Environment(WorkspaceStore.self) private var store
  let row: CorpusFileTreePresentationRow
  let isExpanded: Bool
  let toggleDirectory: () -> Void

  var body: some View {
    let node = row.node
    if let file = node.file {
      CorpusFileTreeNodeLabel(node: node)
        .padding(.leading, CGFloat(row.depth + 1) * 18)
        .contentShape(Rectangle())
        .onTapGesture {
          let modifiers = NSApp.currentEvent?.modifierFlags ?? []
          store.handleCorpusFileClick(file, modifiers: modifiers)
        }
        .modifier(ReadableListSelectionModifier(isSelected: store.isCorpusFileSelectedForAIContext(file)))
        .listRowBackground(Color.clear)
        .contextMenu {
          CorpusFileContextMenu(file: file)
        }
    } else {
      Button(action: toggleDirectory) {
        CorpusFileTreeNodeLabel(node: node, directoryIsExpanded: isExpanded)
          .padding(.leading, CGFloat(row.depth) * 18)
          .contentShape(Rectangle())
      }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
  }
}

struct CorpusFileTreeNodeLabel: View {
  let node: CorpusFileTreeNode
  var compact = false
  var directoryIsExpanded: Bool?

  init(
    node: CorpusFileTreeNode,
    compact: Bool = false,
    directoryIsExpanded: Bool? = nil
  ) {
    self.node = node
    self.compact = compact
    self.directoryIsExpanded = directoryIsExpanded
  }

  var body: some View {
    HStack(spacing: compact ? 6 : 8) {
      if let directoryIsExpanded, node.isDirectory {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .rotationEffect(.degrees(directoryIsExpanded ? 90 : 0))
          .frame(width: compact ? 10 : 12)
      }
      Image(systemName: node.isDirectory ? "folder" : "doc.text")
        .foregroundStyle(node.isDirectory ? WorkspaceDesign.structuralAccent : WorkspaceDesign.secondaryText)
        .frame(width: compact ? 14 : 18)
      VStack(alignment: .leading, spacing: compact ? 0 : 2) {
        Text(node.name)
          .font(compact ? .caption : .body.weight(.medium))
          .lineLimit(1)
        if !compact, let file = node.file {
          Text(file.directory.isEmpty ? "Corpus root" : file.directory)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 0)
      if node.isDirectory {
        Text("\(node.descendantFileCount)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      } else if !compact, let byteCount = node.file?.byteCount {
        Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, compact ? 1 : WorkspaceDesign.rowVerticalPadding)
  }
}

private struct CorpusFileRow: View {
  let file: CorpusFile

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      WorkspaceIconBadge(systemImage: "doc.text")
      VStack(alignment: .leading, spacing: 3) {
        Text(file.name)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(file.relativePath)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if let byteCount = file.byteCount {
        Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

struct ReadableListSelectionModifier: ViewModifier {
  let isSelected: Bool
  var verticalPadding: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .workspaceSelectableRow(isSelected: isSelected, verticalPadding: verticalPadding)
  }
}

struct CorpusFileContextMenu: View {
  @Environment(WorkspaceStore.self) private var store
  let file: CorpusFile
  var afterOpen: (() -> Void)? = nil

  var body: some View {
    Button {
      store.selectCorpusFile(file)
      afterOpen?()
    } label: {
      Label("Open", systemImage: "doc.text")
    }

    Button {
      store.togglePinnedFile(file)
    } label: {
      Label(
        store.isFilePinned(path: file.path) ? "Unpin File" : "Pin File",
        systemImage: store.isFilePinned(path: file.path) ? "pin.slash" : "pin"
      )
    }

    Button {
      store.openFileInEditor(path: file.path)
    } label: {
      Label("Open in Editor", systemImage: "arrow.up.forward.app")
    }

    Button {
      store.revealFile(path: file.path)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }

    Button {
      store.copyFileReference(path: file.path)
    } label: {
      Label("Copy File Path", systemImage: "doc.on.doc")
    }

    Divider()

    Button {
      store.startNewAIThreadFromCorpusFileSelection(including: file)
      afterOpen?()
    } label: {
      Label("Start New AI Thread", systemImage: "sparkles")
    }

    if URL(fileURLWithPath: file.path).pathExtension.lowercased() != "canvas" {
      Button {
        store.selectCorpusFile(file)
        afterOpen?()
        Task { await store.linkifyCurrentFile() }
      } label: {
        Label("Linkify File", systemImage: "link")
      }
    }
  }
}

struct WorkspaceLocationContextMenu<OpenLabel: View>: View {
  @Environment(WorkspaceStore.self) private var store
  let location: WorkspaceLocation
  let select: () -> Void
  let showsHeadingActions: Bool
  let showsAIThreadAction: Bool
  @ViewBuilder let openLabel: () -> OpenLabel

  init(
    location: WorkspaceLocation,
    showsHeadingActions: Bool = false,
    showsAIThreadAction: Bool = true,
    select: @escaping () -> Void,
    @ViewBuilder openLabel: @escaping () -> OpenLabel
  ) {
    self.location = location
    self.showsHeadingActions = showsHeadingActions
    self.showsAIThreadAction = showsAIThreadAction
    self.select = select
    self.openLabel = openLabel
  }

  var body: some View {
    Button {
      select()
    } label: {
      openLabel()
    }

    Button {
      store.open(location)
    } label: {
      Label("Open in Editor", systemImage: "arrow.up.forward.app")
    }

    Button {
      store.revealFile(path: location.file)
    } label: {
      Label("Reveal in Finder", systemImage: "folder")
    }

    Button {
      store.copyFileReference(path: location.file, line: location.lineForEditor)
    } label: {
      Label("Copy Reference", systemImage: "doc.on.doc")
    }

    Divider()

    if showsAIThreadAction {
      Button {
        store.startNewAIThread(from: location)
      } label: {
        Label("Start New AI Thread", systemImage: "sparkles")
      }
    }

    Button {
      select()
      Task { await store.linkifyCurrentFile() }
    } label: {
      Label("Linkify File", systemImage: "link")
    }

    if showsHeadingActions {
      Divider()
      HeadingActionsContextMenu(location: location, select: select)
    }
  }
}

private struct HeadingActionsContextMenu: View {
  @Environment(WorkspaceStore.self) private var store
  let location: WorkspaceLocation
  let select: () -> Void

  var body: some View {
    Button {
      select()
      store.requestStartWork(on: location, origin: "context_menu")
    } label: {
      Label("Start Work with AI…", systemImage: "play.circle")
    }
    Divider()

    Menu {
      todoButton("TODO", status: .todo)
      todoButton("In Progress", status: .inProgress)
      todoButton("Done", status: .done)
      todoButton("Canceled", status: .canceled)
      Divider()
      Button {
        select()
        Task { await store.applyTodoShortcut(nil, to: location) }
      } label: {
        Label("Toggle", systemImage: "arrow.triangle.2.circlepath")
      }
    } label: {
      Label("Status", systemImage: "checkmark.circle")
    }

    Menu {
      planningButton("Today", kind: .scheduled, target: .today)
      planningButton("Tomorrow", kind: .scheduled, target: .tomorrow)
      planningButton("Next Monday", kind: .scheduled, target: .upcomingMonday)
      planningButton("Next Month", kind: .scheduled, target: .nextMonth)
    } label: {
      Label("Schedule", systemImage: "calendar")
    }

    Menu {
      planningButton("Today", kind: .deadline, target: .today)
      planningButton("Tomorrow", kind: .deadline, target: .tomorrow)
      planningButton("Next Monday", kind: .deadline, target: .upcomingMonday)
      planningButton("Next Month", kind: .deadline, target: .nextMonth)
    } label: {
      Label("Deadline", systemImage: "calendar.badge.clock")
    }

    Menu {
      priorityButton("A", priority: "A")
      priorityButton("B", priority: "B")
      priorityButton("C", priority: "C")
      Divider()
      priorityButton("Clear", priority: nil)
    } label: {
      Label("Priority", systemImage: "flag")
    }

    Menu {
      AgentHandoffMenuItems { profile in
        select()
        Task { await store.applyAgentHandoffShortcut(to: location, agentProfile: profile) }
      }
    } label: {
      Label("Pass to Agent", systemImage: "person.crop.circle.badge.checkmark")
    }

    Button {
      select()
      Task { await store.applyApproveAndAgentHandoffShortcut(to: location) }
    } label: {
      Label("Approve & Hand Off", systemImage: "checkmark.seal")
    }

    Button {
      select()
      store.promptAndApplyRejectApprovalShortcut(to: location)
    } label: {
      Label("Reject", systemImage: "xmark.octagon")
    }
  }

  private func todoButton(_ title: String, status: TodoEditStatus) -> some View {
    Button(title) {
      select()
      Task { await store.applyTodoShortcut(status, to: location) }
    }
  }

  private func planningButton(_ title: String, kind: PlanningEditKind, target: PlanningDateTarget) -> some View {
    Button(title) {
      select()
      Task { await store.applyPlanningShortcut(kind: kind, target: target, to: location) }
    }
  }

  private func priorityButton(_ title: String, priority: String?) -> some View {
    Button(title) {
      select()
      Task { await store.applyPriorityShortcut(priority, to: location) }
    }
  }
}

struct AgentHandoffMenuItems: View {
  @Environment(WorkspaceStore.self) private var store
  let handOff: (AgentProfileItem?) -> Void

  private var availableProfiles: [AgentProfileItem] {
    store.agentProfiles
      .filter { $0.status.lowercased() == "active" }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    if !availableProfiles.isEmpty {
      ForEach(availableProfiles) { profile in
        Button {
          handOff(profile)
        } label: {
          Label(profile.name, systemImage: "person.crop.circle")
        }
        .help(profile.description.isEmpty ? profile.id : profile.description)
      }
      Divider()
    }

    Button {
      handOff(nil)
    } label: {
      Label("Configured default (\(store.agentHandoffAssignee))", systemImage: "gearshape")
    }
  }
}

struct QuickOpenView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @FocusState private var queryFocused: Bool
  @State private var query = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField(store.isWorkspaceAppEnabled("crm") ? "Quick open files, people, companies, and AI chats" : "Quick open files and AI chats", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($queryFocused)
          .onSubmit {
            _ = openSelectedOrFirst()
          }
      }
      .padding(10)
      .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(0.18))
      )

      if store.isScanningCorpusFiles || store.isFilteringQuickOpenFiles {
        HStack(spacing: 8) {
          WorkspaceActivityIndicator(size: .small)
          Text(store.isScanningCorpusFiles ? "Scanning files" : "Searching")
            .foregroundStyle(.secondary)
        }
      }

      ScrollViewReader { proxy in
        List {
          ForEach(store.quickOpenItems) { item in
            switch item {
            case .file(let file):
              CorpusFileRow(file: file)
                .overlay(alignment: .trailing) {
                  if store.isRecentCorpusFile(file) {
                    Image(systemName: "clock.arrow.circlepath")
                      .font(.caption)
                      .foregroundStyle(.tertiary)
                      .help("Recently opened")
                      .accessibilityLabel("Recently opened")
                  }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                  open(item)
                }
                .modifier(ReadableListSelectionModifier(isSelected: store.selectedQuickOpenFileID == item.id))
                .listRowBackground(Color.clear)
                .contextMenu {
                  CorpusFileContextMenu(file: file) {
                    store.isQuickOpenPresented = false
                    dismiss()
                  }
                }
            case .chatThread(let thread):
              QuickOpenChatThreadRow(thread: thread)
                .contentShape(Rectangle())
                .onTapGesture {
                  open(item)
                }
                .modifier(ReadableListSelectionModifier(isSelected: store.selectedQuickOpenFileID == item.id))
                .listRowBackground(Color.clear)
            case .approval(let approval):
              QuickOpenApprovalRow(approval: approval)
                .contentShape(Rectangle())
                .onTapGesture {
                  open(item)
                }
                .modifier(ReadableListSelectionModifier(isSelected: store.selectedQuickOpenFileID == item.id))
                .listRowBackground(Color.clear)
            case .crmEntity(let entity):
              QuickOpenCRMEntityRow(entity: entity)
                .contentShape(Rectangle())
                .onTapGesture {
                  open(item)
                }
                .modifier(ReadableListSelectionModifier(isSelected: store.selectedQuickOpenFileID == item.id))
                .listRowBackground(Color.clear)
            }
          }
        }
        .listStyle(.plain)
        .frame(minHeight: 320)
        // A List keeps its previous top row anchored when results change, which
        // can leave a new result list scrolled to the middle. Start each result
        // list at the top and keep keyboard selection visible.
        .onAppear { scrollToTop(proxy) }
        .onChange(of: store.quickOpenItems.map(\.id)) { previous, current in
          if QuickOpenScrollPolicy.resetsToTop(previousIDs: previous, currentIDs: current) {
            scrollToTop(proxy)
          }
        }
        .onChange(of: store.selectedQuickOpenFileID) { _, selected in
          if let selected { proxy.scrollTo(selected) } else { scrollToTop(proxy) }
        }
      }

      HStack(spacing: 8) {
        Text("Return opens  ·  ⌘Return opens in a new tab")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Button {
          searchEverywhere()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
            Text(trimmedQuery.isEmpty ? "Search Workspace" : "Search Workspace for “\(trimmedQuery)”")
              .lineLimit(1)
              .truncationMode(.middle)
            Text("⇧↩")
              .foregroundStyle(.tertiary)
          }
          .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Search headings, text, chats, and agent work across the workspace (⇧Return)")
      }
    }
    .padding(16)
    .frame(width: 720, height: 480)
    .modifier(QuickOpenKeyboardEventMonitor(handler: handleKeyDown))
    .onChange(of: query) {
      store.quickOpenQuery = query
    }
    .onAppear {
      query = store.quickOpenQuery
      queryFocused = true
      store.resetQuickOpenSelection()
    }
  }

  private func scrollToTop(_ proxy: ScrollViewProxy) {
    guard let first = store.quickOpenItems.first?.id else { return }
    proxy.scrollTo(first, anchor: .top)
  }

  private func openSelectedOrFirst() -> Bool {
    guard let item = store.selectedQuickOpenItem else { return false }
    open(item)
    return true
  }

  private func open(_ item: WorkspaceQuickOpenItem, inNewTab: Bool = false) {
    store.selectQuickOpenItem(item, inNewTab: inNewTab)
    store.isQuickOpenPresented = false
    dismiss()
  }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Quick open matches names; full Search matches content everywhere.
  private func searchEverywhere() {
    store.usageLog.record(.quickOpenDismiss, ["query_length": .int(query.count)])
    store.searchWorkspace(for: query)
    dismiss()
  }

  private func handleKeyDown(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
      guard let item = store.selectedQuickOpenItem else { return false }
      open(item, inNewTab: true)
      return true
    }
    if modifiers == .shift, event.keyCode == 36 || event.keyCode == 76 {
      searchEverywhere()
      return true
    }
    guard modifiers.isEmpty else { return false }

    switch event.keyCode {
    case 125:
      store.moveQuickOpenSelection(.down)
      return true
    case 126:
      store.moveQuickOpenSelection(.up)
      return true
    case 36, 76:
      return openSelectedOrFirst()
    case 53:
      store.usageLog.record(.quickOpenDismiss, ["query_length": .int(query.count)])
      store.isQuickOpenPresented = false
      dismiss()
      return true
    default:
      return false
    }
  }
}

private struct QuickOpenChatThreadRow: View {
  let thread: AIChatThread

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      WorkspaceIconBadge(
        systemImage: "bubble.left.and.bubble.right",
        tint: .accentColor,
        fill: Color.accentColor.opacity(0.10)
      )
      VStack(alignment: .leading, spacing: 3) {
        Text(thread.title)
          .font(.body.weight(.medium))
          .lineLimit(1)
        HStack(spacing: 6) {
          Text("AI Chat")
          Text("·")
          Text("\(thread.messageCount) message\(thread.messageCount == 1 ? "" : "s")")
          if thread.isSettled {
            Text("·")
            Text("Settled")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct QuickOpenCRMEntityRow: View {
  let entity: WorkspaceCRMSearchEntity

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      WorkspaceIconBadge(
        systemImage: entity.systemImage,
        tint: .teal,
        fill: Color.teal.opacity(0.10)
      )
      VStack(alignment: .leading, spacing: 3) {
        Text(entity.title)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text([entity.kindLabel, entity.subtitle].filter { !$0.isEmpty }.joined(separator: " · "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct QuickOpenApprovalRow: View {
  let approval: ApprovalItem

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      WorkspaceIconBadge(
        systemImage: "checkmark.seal",
        tint: .orange,
        fill: Color.orange.opacity(0.10)
      )
      VStack(alignment: .leading, spacing: 3) {
        Text(Org2Display.cleanInline(approval.title))
          .font(.body.weight(.medium))
          .lineLimit(1)
        HStack(spacing: 6) {
          Text("Approval")
          Text("·")
          Text(approval.sourceLabel)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

struct SimilarTodoAssignmentView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @FocusState private var assigneeFocused: Bool

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Assign Similar TODOs")
            .font(.title2.weight(.semibold))
          Text("\(store.selectedSimilarTodoCandidateIDs.count) of \(store.similarTodoCandidates.count) selected")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button {
          store.isSimilarTodoAssignmentPresented = false
          dismiss()
        } label: {
          Label("Close", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut(.cancelAction)
      }

      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
        GridRow {
          Text("Pattern")
            .foregroundStyle(.secondary)
          TextField("find valid contact for {{target}}", text: $store.similarTodoPattern)
            .textFieldStyle(.roundedBorder)
        }
        GridRow {
          Text("Assignee")
            .foregroundStyle(.secondary)
          TextField("contact-finder", text: $store.similarTodoAssignee)
            .textFieldStyle(.roundedBorder)
            .focused($assigneeFocused)
        }
        GridRow {
          Text("Status")
            .foregroundStyle(.secondary)
          TextField("ready", text: $store.similarTodoStatus)
            .textFieldStyle(.roundedBorder)
        }
      }

      List {
        ForEach(store.similarTodoCandidates) { candidate in
          SimilarTodoCandidateRow(candidate: candidate)
            .contentShape(Rectangle())
            .onTapGesture {
              store.toggleSimilarTodoCandidateSelection(candidate)
            }
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 300)

      HStack(spacing: 8) {
        Button {
          store.selectedSimilarTodoCandidateIDs = Set(store.similarTodoCandidates.map(\.id))
        } label: {
          Label("All", systemImage: "checkmark.square")
        }

        Button {
          store.selectedSimilarTodoCandidateIDs = []
        } label: {
          Label("None", systemImage: "square")
        }

        Spacer(minLength: 0)

        Button {
          Task { await store.assignSimilarTodos(askAIChat: false) }
        } label: {
          Label("Assign", systemImage: "person.crop.circle.badge.checkmark")
        }
        .disabled(store.selectedSimilarTodoCandidateIDs.isEmpty)

        Button {
          Task { await store.assignSimilarTodos(askAIChat: true) }
        } label: {
          Label("Assign & Ask OpenClaw", systemImage: "sparkles")
        }
        .keyboardShortcut(.defaultAction)
        .disabled(store.selectedSimilarTodoCandidateIDs.isEmpty)
      }
    }
    .padding(18)
    .frame(width: 760, height: 560)
    .onAppear {
      assigneeFocused = store.similarTodoAssignee.isEmpty
    }
  }
}

private struct SimilarTodoCandidateRow: View {
  @Environment(WorkspaceStore.self) private var store
  let candidate: SimilarTodoCandidate

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: store.selectedSimilarTodoCandidateIDs.contains(candidate.id) ? "checkmark.square.fill" : "square")
        .foregroundStyle(store.selectedSimilarTodoCandidateIDs.contains(candidate.id) ? Color.accentColor : Color.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          if let todo = candidate.todo {
            Text(todo)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text(Org2Display.cleanInline(candidate.headline))
            .font(.body.weight(.medium))
            .lineLimit(1)
        }
        HStack(spacing: 8) {
          Text(store.relativePath(candidate.file) + ":\(candidate.line)")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Text("\(Int(candidate.score * 100))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
          if let assignee = candidate.properties["ASSIGNEE"], !assignee.isEmpty {
            Text("assigned: \(assignee)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
  }
}

struct QuickOpenKeyboardEventMonitor: ViewModifier {
  let handler: (NSEvent) -> Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          handler(event) ? nil : event
        }
      }
      .onDisappear {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
        monitor = nil
      }
  }
}

struct KeyboardShortcutsView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Keyboard Shortcuts")
            .font(.title2.weight(.semibold))
          Text("Shortcuts depend on the focused pane or editor. Bare uppercase letters mean Shift (for example, J = ⇧J).")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button {
          dismiss()
        } label: {
          Label("Close", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .keyboardShortcut(.cancelAction)
      }

      ScrollView {
        LazyVGrid(columns: [
          GridItem(.flexible(), spacing: 16),
          GridItem(.flexible(), spacing: 16)
        ], alignment: .leading, spacing: 18) {
          ShortcutSection(title: "Workspace", shortcuts: [
            ShortcutHelpItem(keys: "⌘⇧O", action: "Open corpus"),
            ShortcutHelpItem(keys: "⌘R", action: "Refresh workspace; press again to cancel"),
            ShortcutHelpItem(keys: "⌘S", action: "Save active edit"),
            ShortcutHelpItem(keys: "⌘P", action: "Quick Open"),
            ShortcutHelpItem(keys: NewCorpusFileCommand.shortcutTitle, action: "New file"),
            ShortcutHelpItem(keys: "⌘K", action: "Quick Open outside the Source editor"),
            ShortcutHelpItem(keys: "⌘⌃Return", action: "Capture"),
            ShortcutHelpItem(keys: "⌘? / ⌘/", action: "Show shortcuts"),
            ShortcutHelpItem(keys: "⌘Z / ⌘⇧Z", action: "Undo / redo text or workspace edit")
          ])

          ShortcutSection(title: "Navigation", shortcuts: [
            ShortcutHelpItem(keys: "⌘[ / ⌘]", action: "Back / forward"),
            ShortcutHelpItem(keys: "⌘-click link", action: "Open link in a new tab"),
            ShortcutHelpItem(keys: "⌘Return in Quick Open", action: "Open in a new tab"),
            ShortcutHelpItem(keys: "⌥⌘N", action: "Activity (what's happening now)"),
            ShortcutHelpItem(keys: "⌘1", action: "Home"),
            ShortcutHelpItem(keys: "⌘2", action: "Agenda"),
            ShortcutHelpItem(keys: "⌥⌘K", action: "Calendar"),
            ShortcutHelpItem(keys: "⌘3", action: "Files"),
            ShortcutHelpItem(keys: "⌘4", action: "Agent Work"),
            ShortcutHelpItem(keys: "⌘⇧F", action: "Corpus search"),
            ShortcutHelpItem(keys: "⌘5 / ⌘M", action: "Meetings"),
            ShortcutHelpItem(keys: "⌘6", action: "AI Chat"),
            ShortcutHelpItem(keys: "⌘⇧K", action: "Skills"),
            ShortcutHelpItem(keys: "⌘0", action: "Sources"),
            ShortcutHelpItem(keys: "⌘⇧R", action: "Review Queue"),
            ShortcutHelpItem(keys: "⌥⌘A", action: "Automations"),
            ShortcutHelpItem(keys: "⌥⌘E", action: "External Threads"),
            ShortcutHelpItem(keys: "⌥⌘V", action: "Saved Views"),
            ShortcutHelpItem(keys: "⌥⌘C", action: "Canvases (experimental)")
          ])

          ShortcutSection(title: "Tabs", shortcuts: [
            ShortcutHelpItem(keys: "⌘T", action: "New tab"),
            ShortcutHelpItem(keys: "⌘⇧[ / ⌘⇧]", action: "Previous / next tab"),
            ShortcutHelpItem(keys: "⌘W", action: "Close current tab when multiple tabs are open")
          ])

          ShortcutSection(title: "Pane Layout", shortcuts: [
            ShortcutHelpItem(keys: "⌘⌥P", action: "Make current pane primary"),
            ShortcutHelpItem(keys: "⌘⌥F", action: "Expand or restore current pane"),
            ShortcutHelpItem(keys: "⌘⌥W", action: "Close current pane")
          ])

          ShortcutSection(title: "Page", shortcuts: [
            ShortcutHelpItem(keys: "⌘F", action: "Find in current document or AI thread"),
            ShortcutHelpItem(keys: "Esc", action: "Clear selected block")
          ])

          ShortcutSection(title: "Daily Notes", shortcuts: [
            ShortcutHelpItem(keys: "⌘7", action: "Today"),
            ShortcutHelpItem(keys: "⌘8", action: "Yesterday"),
            ShortcutHelpItem(keys: "⌘9", action: "Tomorrow"),
            ShortcutHelpItem(keys: DailyNoteTarget.datePickerCommandShortcutTitle, action: "Choose date")
          ])

          ShortcutSection(title: "Agenda", shortcuts: [
            ShortcutHelpItem(keys: "j / ↓", action: "Next item"),
            ShortcutHelpItem(keys: "k / ↑", action: "Previous item"),
            ShortcutHelpItem(keys: "⌃D / ⌃U", action: "Jump down / up"),
            ShortcutHelpItem(keys: "J / K", action: "Scroll detail pane"),
            ShortcutHelpItem(keys: "gg / G", action: "First / last item"),
            ShortcutHelpItem(keys: "1 / 2 / 3 / 4", action: "Agenda mode"),
            ShortcutHelpItem(keys: "/", action: "Filter agenda"),
            ShortcutHelpItem(keys: "Esc", action: "Clear agenda filter"),
            ShortcutHelpItem(keys: "r", action: "Refresh agenda or assigned work"),
            ShortcutHelpItem(keys: "o / Return", action: "Open item"),
            ShortcutHelpItem(keys: "e", action: "Edit item source"),
            ShortcutHelpItem(keys: "c", action: "Capture task"),
            ShortcutHelpItem(keys: "Space", action: "Clear TODO status"),
            ShortcutHelpItem(keys: "t / i / d / x", action: "TODO / in-progress / done / canceled"),
            ShortcutHelpItem(keys: "A", action: "Assign to agent"),
            ShortcutHelpItem(keys: "p then a/b/c/0", action: "Set or clear priority"),
            ShortcutHelpItem(keys: "P", action: "Apply property shortcut"),
            ShortcutHelpItem(keys: "s / n / w / m", action: "Schedule today / tomorrow / next Monday / first of next month"),
            ShortcutHelpItem(keys: "S / N / W / M", action: "Deadline today / tomorrow / next Monday / first of next month"),
            ShortcutHelpItem(keys: "q", action: "Quit app")
          ])

          ShortcutSection(title: "Agenda, Files, Runs & Review", shortcuts: [
            ShortcutHelpItem(keys: "⌘A / ⌘⇧A", action: "Select visible / clear selection"),
            ShortcutHelpItem(keys: "⇧↑ / ⇧↓", action: "Extend selection")
          ])

          ShortcutSection(title: "Document", shortcuts: [
            ShortcutHelpItem(keys: "j / k / ↑ / ↓", action: "Move block selection"),
            ShortcutHelpItem(keys: "Return", action: "Edit selected block source"),
            ShortcutHelpItem(keys: "⌘Return", action: "Insert paragraph after block"),
            ShortcutHelpItem(keys: "/", action: "Insert slash-command paragraph"),
            ShortcutHelpItem(keys: "Type", action: "Start source edit at selected block"),
            ShortcutHelpItem(keys: "← / →", action: "Collapse / expand block"),
            ShortcutHelpItem(keys: "⌘← / ⌘→", action: "Collapse / expand all"),
            ShortcutHelpItem(keys: "Delete", action: "Delete selected block"),
            ShortcutHelpItem(keys: "⌘D", action: "Duplicate selected block"),
            ShortcutHelpItem(keys: "⌘⇧↑ / ⌘⇧↓", action: "Move block"),
            ShortcutHelpItem(keys: "Esc", action: "Clear block selection")
          ])

          ShortcutSection(title: "Slides", shortcuts: [
            ShortcutHelpItem(keys: "← / Page Up / ⇧Space", action: "Previous slide"),
            ShortcutHelpItem(keys: "→ / Page Down / Space", action: "Next slide"),
            ShortcutHelpItem(keys: "Home / End", action: "First / last slide"),
            ShortcutHelpItem(keys: "⌘+ / ⌘−", action: "Zoom in / out")
          ])

          ShortcutSection(title: "Editing", shortcuts: [
            ShortcutHelpItem(keys: "⌘S", action: "Save active inline editor"),
            ShortcutHelpItem(keys: "Esc", action: "Cancel active inline editor"),
            ShortcutHelpItem(keys: "⌘B / ⌘I", action: "Bold / italic selected inline text"),
            ShortcutHelpItem(keys: "⌘U", action: "Underline selected inline text"),
            ShortcutHelpItem(keys: "⌘R", action: "Run source block while editing source")
          ])

          ShortcutSection(title: "AI Chat", shortcuts: [
            ShortcutHelpItem(keys: "⌘N", action: "New AI thread"),
            ShortcutHelpItem(keys: "Return", action: "Send; queue while a turn is running"),
            ShortcutHelpItem(keys: "⇧Return", action: "Insert newline"),
            ShortcutHelpItem(keys: "⌘Return", action: "Queue behind running turn; send when idle"),
            ShortcutHelpItem(keys: "⌘⇧Return", action: "Same as ⌘Return"),
            ShortcutHelpItem(keys: "↑ / ↓", action: "Navigate visible suggestions"),
            ShortcutHelpItem(keys: "Tab / Return", action: "Accept selected suggestion when shown")
          ])

          ShortcutSection(title: "Source Editor", shortcuts: [
            ShortcutHelpItem(keys: "⌘⌥Return", action: "Insert heading"),
            ShortcutHelpItem(keys: "⌘⌥L", action: "Insert list item"),
            ShortcutHelpItem(keys: "⌘K", action: "Insert link"),
            ShortcutHelpItem(keys: "⌘⌥← / ⌘⌥→", action: "Promote / demote"),
            ShortcutHelpItem(keys: "⌘⌥T", action: "Cycle TODO"),
            ShortcutHelpItem(keys: "⌘⌥S", action: "Schedule today"),
            ShortcutHelpItem(keys: "⌘⌥D", action: "Deadline today"),
            ShortcutHelpItem(keys: "⌘⌥[", action: "Toggle heading fold"),
            ShortcutHelpItem(keys: "⌘⌥]", action: "Expand all headings"),
            ShortcutHelpItem(keys: "⌘⌥↑ / ⌘⌥↓", action: "Previous / next heading")
          ])

          ShortcutSection(title: "Meetings", shortcuts: [
            ShortcutHelpItem(keys: "⌘⇧M", action: "Record or stop meeting")
          ])
        }
        .padding(.vertical, 2)
      }
    }
    .padding(20)
    .frame(width: 820, height: 700)
  }
}

private struct ShortcutHelpItem: Identifiable {
  let keys: String
  let action: String

  var id: String {
    "\(keys):\(action)"
  }
}

private struct ShortcutSection: View {
  let title: String
  let shortcuts: [ShortcutHelpItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)

      VStack(alignment: .leading, spacing: 6) {
        ForEach(shortcuts) { shortcut in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(shortcut.keys)
              .font(.caption.monospaced().weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 92, alignment: .leading)
            Text(shortcut.action)
              .font(.callout)
              .foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
        }
      }
    }
    .padding(12)
    .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.secondary.opacity(0.12))
    )
  }
}

struct AgendaView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID
  @FocusState private var agendaFilterFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HeaderBar(title: "Agenda", subtitle: headerSubtitle, surface: .agenda) {
        if store.agendaMode == .assigned ? store.isLoadingAssignedWork : store.isLoadingAgenda {
          WorkspaceActivityIndicator(size: .small)
        }
        Button {
          Task { await refreshVisibleAgenda() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.agendaMode == .assigned ? store.isLoadingAssignedWork : store.isLoadingAgenda)
      }

      if let error = store.errorText, store.agenda == nil {
        EmptyStateView(title: "Agenda Failed", detail: error, action: "Refresh") {
          Task { await refreshVisibleAgenda() }
        }
      } else if let agenda = store.agenda {
        AgendaControls(agendaFilterFocused: $agendaFilterFocused)

        if store.agendaMode == .assigned {
          AssignedAgendaSummaryView(count: store.visibleAssignedWorkItems.count)
        } else {
          AgendaSummaryView(agenda: agenda)
        }
        Divider()
        AgendaListView()
      } else {
        EmptyStateView(title: "No Agenda", detail: store.statusText, action: "Open Corpus") {
          store.chooseCorpus()
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onChange(of: store.agendaMode) {
      let mode = store.agendaMode
      performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
        guard store.agendaMode == mode else { return }
        if mode == .assigned, store.agendaDateFilter != .any {
          store.agendaDateFilter = .any
        }
        if mode == .assigned {
          Task {
            await store.refreshAssignedWork()
            store.syncAssignedAgendaSelectionAfterDisplayOptionsChange()
          }
        } else {
          store.syncAgendaSelectionAfterDisplayOptionsChange()
        }
      }
    }
    .onChange(of: store.agendaReadScope) {
      guard store.agendaMode != .assigned else { return }
      Task { await store.refreshAgenda() }
    }
    .onChange(of: store.agendaFilter) {
      let filter = store.agendaFilter
      performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
        guard store.agendaFilter == filter else { return }
        store.syncAgendaSelectionAfterDisplayOptionsChange()
      }
    }
    .onChange(of: store.agendaFilterFocusToken) {
      agendaFilterFocused = true
    }
    .onChange(of: agendaFilterFocused) {
      let isFocused = agendaFilterFocused
      performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
        guard store.isAgendaFilterFocused != isFocused else { return }
        store.isAgendaFilterFocused = isFocused
      }
    }
    .onChange(of: store.isAgendaFilterFocused) {
      agendaFilterFocused = store.isAgendaFilterFocused
    }
    .onDisappear {
      store.isAgendaFilterFocused = false
    }
  }

  private func refreshVisibleAgenda() async {
    if store.agendaMode == .assigned {
      await store.refreshAssignedWork()
    } else {
      await store.refreshAgenda(updatesStatus: true)
    }
  }

  private var headerSubtitle: String {
    if store.agendaMode == .assigned {
      return "\(store.visibleAssignedWorkItems.count) all-time item\(store.visibleAssignedWorkItems.count == 1 ? "" : "s")"
    }
    return store.agenda.map { "\($0.range.start) to \($0.range.end)" } ?? "Agenda"
  }
}

private struct AgendaControls: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var filterDraft = ""
  @State private var pendingFilterUpdate: Task<Void, Never>?
  var agendaFilterFocused: FocusState<Bool>.Binding

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Picker("Mode", selection: $store.agendaMode) {
          ForEach(AgendaMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 300)

        if store.agendaMode != .assigned {
          Picker("Scope", selection: $store.agendaReadScope) {
            ForEach(WorkspaceReadScope.allCases) { scope in
              Text(scope.title).tag(scope)
            }
          }
          .frame(width: 135)
          .help("Read agenda items from the active corpus or every mounted corpus")

          Menu {
            ForEach(AgendaOverdueOrder.allCases) { order in
              Button {
                store.agendaOverdueOrder = order
                store.syncAgendaSelectionAfterDisplayOptionsChange()
              } label: {
                if store.agendaOverdueOrder == order {
                  Label(order.title, systemImage: "checkmark")
                } else {
                  Text(order.title)
                }
              }
            }
          } label: {
            Label(store.agendaOverdueOrder.title, systemImage: "arrow.up.arrow.down")
          }
          .buttonStyle(WorkspaceActionButtonStyle())
          .help("Choose how overdue items are ordered. Priority changes are saved in the Org source file.")
        }

        Spacer(minLength: 0)

        Button {
          store.promptAndCaptureTodoShortcut()
        } label: {
          Label("Capture", systemImage: "square.and.pencil")
        }
        .buttonStyle(WorkspaceActionButtonStyle())
      }

      HStack(spacing: 8) {
        AgendaStructuredFiltersMenu()
          .buttonStyle(WorkspaceActionButtonStyle())
        TextField("Filter agenda", text: $filterDraft)
          .textFieldStyle(.roundedBorder)
          .focused(agendaFilterFocused)
          .onChange(of: filterDraft) { scheduleFilterUpdate() }
          .onSubmit {
            applyFilterImmediately()
            agendaFilterFocused.wrappedValue = false
          }

        if !filterDraft.isEmpty {
          Button {
            filterDraft = ""
            store.clearAgendaFilter()
          } label: {
            Label("Clear", systemImage: "xmark.circle.fill")
          }
          .labelStyle(.iconOnly)
          .help("Clear agenda filter")
        }
      }

      if store.hasAgendaStructuredFilters {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            if store.agendaDateFilter != .any {
              AgendaFilterChip(title: store.agendaDateFilter.title) {
                store.setAgendaDateFilter(.any)
              }
            }
            if !store.agendaAssigneeFilter.isEmpty {
              AgendaFilterChip(
                title: "Assignee: \(store.agendaAssigneeFilterTitle(store.agendaAssigneeFilter))"
              ) {
                store.agendaAssigneeFilter = ""
                store.syncAgendaSelectionAfterDisplayOptionsChange()
              }
            }
            if !store.agendaStatusFilter.isEmpty {
              AgendaFilterChip(
                title: "Status: \(store.agendaStatusFilterTitle(store.agendaStatusFilter))"
              ) {
                store.agendaStatusFilter = ""
                store.syncAgendaSelectionAfterDisplayOptionsChange()
              }
            }
            if !store.agendaPriorityFilter.isEmpty {
              AgendaFilterChip(
                title: "Priority: \(store.agendaPriorityFilterTitle(store.agendaPriorityFilter))"
              ) {
                store.agendaPriorityFilter = ""
                store.syncAgendaSelectionAfterDisplayOptionsChange()
              }
            }
            if !store.agendaTopicFilter.isEmpty {
              AgendaFilterChip(title: "Topic: \(store.agendaTopicFilter)") {
                store.agendaTopicFilter = ""
                store.syncAgendaSelectionAfterDisplayOptionsChange()
              }
            }
          }
        }
      }
    }
    .controlSize(.small)
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
    .onAppear { filterDraft = store.agendaFilter }
    .onChange(of: store.agendaFilter) {
      if filterDraft != store.agendaFilter {
        filterDraft = store.agendaFilter
      }
    }
    .onDisappear { pendingFilterUpdate?.cancel() }
  }

  private func scheduleFilterUpdate() {
    pendingFilterUpdate?.cancel()
    let nextFilter = filterDraft
    guard nextFilter != store.agendaFilter else { return }
    pendingFilterUpdate = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
      guard !Task.isCancelled else { return }
      store.agendaFilter = nextFilter
    }
  }

  private func applyFilterImmediately() {
    pendingFilterUpdate?.cancel()
    pendingFilterUpdate = nil
    if store.agendaFilter != filterDraft {
      store.agendaFilter = filterDraft
    }
  }
}

private struct AgendaStructuredFiltersMenu: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    Menu {
      if store.agendaMode != .assigned {
        Menu("Date") {
          ForEach(AgendaDateFilter.allCases) { filter in
            filterButton(filter.title, isSelected: store.agendaDateFilter == filter) {
              store.setAgendaDateFilter(filter)
            }
          }
        }
      }

      Menu("Assignee") {
        filterButton("Any assignee", isSelected: store.agendaAssigneeFilter.isEmpty) {
          setAssignee("")
        }
        filterButton("Unassigned", isSelected: store.agendaAssigneeFilter == WorkspaceStore.agendaUnassignedFilter) {
          setAssignee(WorkspaceStore.agendaUnassignedFilter)
        }
        if !store.agendaAssigneeFilterOptions.isEmpty { Divider() }
        ForEach(store.agendaAssigneeFilterOptions, id: \.self) { assignee in
          filterButton(assignee, isSelected: store.agendaAssigneeFilter == assignee) {
            setAssignee(assignee)
          }
        }
      }

      Menu("Status") {
        filterButton("Any status", isSelected: store.agendaStatusFilter.isEmpty) {
          setStatus("")
        }
        filterButton("Open", isSelected: store.agendaStatusFilter == WorkspaceStore.agendaOpenStatusFilter) {
          setStatus(WorkspaceStore.agendaOpenStatusFilter)
        }
        filterButton("Completed", isSelected: store.agendaStatusFilter == WorkspaceStore.agendaCompletedStatusFilter) {
          setStatus(WorkspaceStore.agendaCompletedStatusFilter)
        }
        if !store.agendaStatusFilterOptions.isEmpty { Divider() }
        ForEach(store.agendaStatusFilterOptions, id: \.self) { status in
          filterButton(status, isSelected: store.agendaStatusFilter.caseInsensitiveCompare(status) == .orderedSame) {
            setStatus(status)
          }
        }
      }

      Menu("Priority") {
        filterButton("Any priority", isSelected: store.agendaPriorityFilter.isEmpty) {
          setPriority("")
        }
        filterButton("No priority", isSelected: store.agendaPriorityFilter == WorkspaceStore.agendaNoPriorityFilter) {
          setPriority(WorkspaceStore.agendaNoPriorityFilter)
        }
        if !store.agendaPriorityFilterOptions.isEmpty { Divider() }
        ForEach(store.agendaPriorityFilterOptions, id: \.self) { priority in
          filterButton(priority, isSelected: store.agendaPriorityFilter.caseInsensitiveCompare(priority) == .orderedSame) {
            setPriority(priority)
          }
        }
      }

      Menu("Topic") {
        filterButton("Any topic", isSelected: store.agendaTopicFilter.isEmpty) {
          setTopic("")
        }
        if !store.agendaTopicFilterOptions.isEmpty { Divider() }
        ForEach(store.agendaTopicFilterOptions, id: \.self) { topic in
          filterButton(topic, isSelected: store.agendaTopicFilter.caseInsensitiveCompare(topic) == .orderedSame) {
            setTopic(topic)
          }
        }
      }

      if store.hasAgendaStructuredFilters {
        Divider()
        Button("Clear Filters") {
          store.clearAgendaStructuredFilters()
        }
      }
    } label: {
      Label(
        store.hasAgendaStructuredFilters
          ? "Filters (\(store.agendaStructuredFilterCount))"
          : "Filters",
        systemImage: "line.3.horizontal.decrease.circle"
      )
    }
    .help("Filter by date, assignee, status, priority, or topic")
  }

  private func setAssignee(_ value: String) {
    store.agendaAssigneeFilter = value
    store.syncAgendaSelectionAfterDisplayOptionsChange()
  }

  private func setStatus(_ value: String) {
    store.agendaStatusFilter = value
    store.syncAgendaSelectionAfterDisplayOptionsChange()
  }

  private func setPriority(_ value: String) {
    store.agendaPriorityFilter = value
    store.syncAgendaSelectionAfterDisplayOptionsChange()
  }

  private func setTopic(_ value: String) {
    store.agendaTopicFilter = value
    store.syncAgendaSelectionAfterDisplayOptionsChange()
  }

  private func filterButton(
    _ title: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      if isSelected {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }
}

private struct AgendaFilterChip: View {
  let title: String
  let clear: () -> Void

  var body: some View {
    Button(action: clear) {
      HStack(spacing: 4) {
        Text(title)
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
      }
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(WorkspaceDesign.controlFill, in: Capsule())
    }
    .buttonStyle(.plain)
    .help("Remove \(title) filter")
  }
}

private struct AgendaSummaryView: View {
  let agenda: AgendaPayload

  var body: some View {
    HStack(spacing: 10) {
      MetricView(title: "Overdue", value: "\(agenda.overdue.reduce(0) { $0 + $1.items.count })")
      MetricView(title: "Today", value: "\(agenda.todayItemCount)")
      MetricView(title: "Upcoming", value: "\(agenda.upcomingItemCount)")
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
  }
}

private struct AssignedAgendaSummaryView: View {
  let count: Int

  var body: some View {
    HStack(spacing: 10) {
      MetricView(title: "All Time", value: "\(count)")
      Spacer(minLength: 0)
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
  }
}

struct MetricView: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.title3.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
      Text(title)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous))
  }
}

private struct AgendaListView: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    VStack(spacing: 0) {
      if store.agendaMode != .assigned, store.hasBulkAgendaSelection {
        AgendaBulkActionBar()
      }

      if store.agendaMode == .assigned {
        AssignedAgendaListView()
      } else {
        AgendaItemListView()
      }
    }
  }
}

struct RunsAndReviewView: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    @Bindable var store = store
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        Picker("Agent work", selection: $store.runsAndReviewPage) {
          ForEach(RunsAndReviewPage.allCases) { page in Text(page.rawValue).tag(page) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 520)
        .background {
          ZStack {
            ForEach(RunsAndReviewPage.allCases) { page in
              WorkspaceAccessibilityPressTarget(
                identifier: RunsAndReviewPageAccessibilityIdentity.accessibilityIdentifier(
                  for: page
                ),
                label: "\(page.rawValue) Agent Work page",
                isSelected: store.runsAndReviewPage == page,
                activate: {
                  guard store.runsAndReviewPage != page else { return }
                  store.runsAndReviewPage = page
                }
              )
            }
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .background(WorkspaceDesign.barBackground)
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(WorkspaceDesign.hairline)
          .frame(height: 0.5)
      }

      switch store.runsAndReviewPage {
      case .runs: RunCenterView()
      case .review: ApprovalsView()
      case .goals: GoalsView()
      case .agents: AgentsView()
      case .workflows: WorkflowsView()
      }
    }
    .onChange(of: store.runsAndReviewPage) {
      Task { await store.refreshSelectedRunReviewPageIfNeeded() }
    }
  }
}

private struct GoalsView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(
        title: "Goals",
        subtitle: "Durable outcomes in goals/",
        surface: .approvals
      ) {
        if store.isLoadingAgentGoals { WorkspaceActivityIndicator(size: .small) }
        Button {
          Task { await store.refreshAgentGoals(updatesStatus: true) }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }

      if store.isLoadingAgentGoals && store.agentGoals.isEmpty {
        Spacer(); WorkspaceLoadingStateView("Loading goals"); Spacer()
      } else if store.agentGoals.isEmpty {
        EmptyStateView(
          title: "No Goals",
          detail: "Goals created in this corpus appear here automatically. Agents can create one with celorga goal create."
        )
      } else {
        WorkspaceLazyCollection {
          ForEach(store.agentGoals) { goal in
            AgentGoalRow(goal: goal)
              .contentShape(Rectangle())
              .onTapGesture {
                selectGoal(goal)
              }
              .modifier(ReadableListSelectionModifier(isSelected: store.selectedAgentGoalID == goal.id))
              .workspaceAccessibleCollectionRow(
                kind: "goal",
                id: goal.id,
                label: goal.title,
                isSelected: store.selectedAgentGoalID == goal.id,
                open: { selectGoal(goal) }
              )
              .contextMenu {
                if let ownerAgentRef = goal.ownerAgentRef {
                  Button("View Owner Agent") { store.showAgentProfile(ownerAgentRef) }
                }
                Button("Show Linked Runs") { store.showAgentRuns(goalRef: goal.id) }
                Divider()
                ForEach(["planned", "active", "achieved", "canceled"], id: \.self) { status in
                  if goal.status != status {
                    Button("Mark \(AgentRunItem.humanizedLabel(status))") {
                      Task { await store.setAgentGoalStatus(goal, status: status) }
                    }
                  }
                }
              }
              .workspaceLazyRow(id: goal.id)
          }
        }
        .onChange(of: store.selectedAgentGoalID) {
          guard let id = store.selectedAgentGoalID,
                let goal = store.agentGoals.first(where: { $0.id == id }) else { return }
          performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
            guard store.selectedAgentGoalID == id else { return }
            store.selectAgentGoal(goal)
          }
        }
      }
    }
    .task {
      await store.refreshSelectedRunReviewPageIfNeeded()
    }
    .onAppear {
      guard let id = store.selectedAgentGoalID,
            let goal = store.agentGoals.first(where: { $0.id == id }) else { return }
      performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
        guard store.selectedAgentGoalID == id else { return }
        store.selectAgentGoal(goal)
      }
    }
  }

  private func selectGoal(_ goal: AgentGoalItem) {
    if store.selectedAgentGoalID == goal.id {
      store.selectAgentGoal(goal)
    } else {
      store.selectedAgentGoalID = goal.id
    }
  }
}

private struct AgentGoalRow: View {
  @Environment(WorkspaceStore.self) private var store
  let goal: AgentGoalItem

  var body: some View {
    let linkedRunCount = store.agentRunCount(goalRef: goal.id)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(goal.title)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        if store.mutatingAgentGoalIDs.contains(goal.id) {
          WorkspaceActivityIndicator(size: .mini)
        }
        StatusPill(text: goal.status)
      }
      if !goal.description.isEmpty {
        Text(goal.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      HStack(spacing: 10) {
        if let ownerAgentRef = goal.ownerAgentRef {
          Button {
            store.showAgentProfile(ownerAgentRef)
          } label: {
            Label(ownerAgentRef, systemImage: "person.crop.circle")
          }
          .buttonStyle(.plain)
          .help("Open the owning agent profile")
        }
        Button {
          store.showAgentRuns(goalRef: goal.id)
        } label: {
          Label("\(linkedRunCount) run\(linkedRunCount == 1 ? "" : "s")", systemImage: "play.circle")
        }
        .buttonStyle(.plain)
        if !goal.measures.isEmpty {
          Label("\(goal.measures.count) measure\(goal.measures.count == 1 ? "" : "s")", systemImage: "chart.line.uptrend.xyaxis")
        }
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .lineLimit(1)
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct AgentsView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(
        title: "Agents",
        subtitle: "Portable worker profiles in agent-profiles/",
        surface: .approvals
      ) {
        if store.isLoadingAgentProfiles { WorkspaceActivityIndicator(size: .small) }
        Button {
          Task { await store.refreshAgentProfiles(updatesStatus: true) }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
      }

      if store.isLoadingAgentProfiles && store.agentProfiles.isEmpty {
        Spacer(); WorkspaceLoadingStateView("Loading agents"); Spacer()
      } else if store.agentProfiles.isEmpty {
        EmptyStateView(
          title: "No Agents",
          detail: "Named agent profiles created in this corpus appear here automatically. OpenClaw, Codex, Claude Code, Pi, and OpenCode remain runtimes, not agent identities."
        )
      } else {
        WorkspaceLazyCollection {
          ForEach(store.agentProfiles) { profile in
            AgentProfileRow(profile: profile)
              .contentShape(Rectangle())
              .onTapGesture {
                selectProfile(profile)
              }
              .modifier(ReadableListSelectionModifier(isSelected: store.selectedAgentProfileID == profile.id))
              .workspaceAccessibleCollectionRow(
                kind: "agent",
                id: profile.id,
                label: profile.name,
                isSelected: store.selectedAgentProfileID == profile.id,
                open: { selectProfile(profile) }
              )
              .contextMenu {
                if let primaryGoalRef = profile.primaryGoalRef {
                  Button("View Primary Goal") { store.showAgentGoal(primaryGoalRef) }
                }
                if let reportsToAgentRef = profile.reportsToAgentRef {
                  Button("View Manager") { store.showAgentProfile(reportsToAgentRef) }
                }
                Button("Show Linked Runs") { store.showAgentRuns(agentRef: profile.id) }
                Menu("Default Runtime") {
                  Button("No Default") {
                    Task { await store.setAgentProfileDefaultRuntime(profile, runtime: nil) }
                  }
                  Divider()
                  ForEach(AIChatRuntime.allCases) { runtime in
                    Button {
                      Task { await store.setAgentProfileDefaultRuntime(profile, runtime: runtime) }
                    } label: {
                      Label(runtime.title, systemImage: profile.preferredChatRuntime == runtime ? "checkmark" : runtime.systemImage)
                    }
                  }
                }
                Divider()
                ForEach(["active", "paused", "retired"], id: \.self) { status in
                  if profile.status != status {
                    Button("Mark \(AgentRunItem.humanizedLabel(status))") {
                      Task { await store.setAgentProfileStatus(profile, status: status) }
                    }
                  }
                }
              }
              .workspaceLazyRow(id: profile.id)
          }
        }
        .onChange(of: store.selectedAgentProfileID) {
          guard let id = store.selectedAgentProfileID,
                let profile = store.agentProfiles.first(where: { $0.id == id }) else { return }
          performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
            guard store.selectedAgentProfileID == id else { return }
            store.selectAgentProfile(profile)
          }
        }
      }
    }
    .task {
      await store.refreshSelectedRunReviewPageIfNeeded()
    }
    .onAppear {
      guard let id = store.selectedAgentProfileID,
            let profile = store.agentProfiles.first(where: { $0.id == id }) else { return }
      performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
        guard store.selectedAgentProfileID == id else { return }
        store.selectAgentProfile(profile)
      }
    }
  }

  private func selectProfile(_ profile: AgentProfileItem) {
    if store.selectedAgentProfileID == profile.id {
      store.selectAgentProfile(profile)
    } else {
      store.selectedAgentProfileID = profile.id
    }
  }
}

private struct AgentProfileRow: View {
  @Environment(WorkspaceStore.self) private var store
  let profile: AgentProfileItem

  var body: some View {
    let linkedRunCount = store.agentRunCount(agentRef: profile.id)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(profile.name)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        if store.mutatingAgentProfileIDs.contains(profile.id) {
          WorkspaceActivityIndicator(size: .mini)
        }
        StatusPill(text: profile.status)
      }
      let summary = profile.description.isEmpty ? profile.responsibilities.first ?? "" : profile.description
      if !summary.isEmpty {
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      HStack(spacing: 10) {
        if let primaryGoalRef = profile.primaryGoalRef {
          Button {
            store.showAgentGoal(primaryGoalRef)
          } label: {
            Label(primaryGoalRef, systemImage: "scope")
          }
          .buttonStyle(.plain)
          .help("Open the primary goal")
        }
        Button {
          store.showAgentRuns(agentRef: profile.id)
        } label: {
          Label("\(linkedRunCount) run\(linkedRunCount == 1 ? "" : "s")", systemImage: "play.circle")
        }
        .buttonStyle(.plain)
        if let runtime = profile.preferredChatRuntime {
          Label("Defaults to \(runtime.title)", systemImage: runtime.systemImage)
        }
        if let binding = profile.runtimeBindings.first {
          Label("\(binding.runtime):\(binding.runtimeAgentId)", systemImage: "link")
        }
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .lineLimit(1)
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct WorkflowsView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.workspaceTabID) private var workspaceTabID
  @Environment(\.openSettings) private var openSettings
  @AppStorage(WorkspaceSettingsNavigation.selectionKey)
  private var settingsSelection = WorkspaceSettingsNavigation.workspace
  @State private var runWorkflow: AgentWorkflowItem?
  @State private var scheduleWorkflow: AgentWorkflowItem?
  @State private var workflowPendingDeletion: AgentWorkflowItem?
  @State private var isCreatingAutomation = false

  var body: some View {
    let scheduler = AutomationSchedulerOwnershipPresentation(
      ownerHostRef: store.automationOwnerHostRef,
      currentHostRef: store.automationHostRef,
      corpusName: store.activeCorpusIdentity?.name
        ?? store.corpusRoot?.lastPathComponent
    )
    VStack(spacing: 0) {
      HeaderBar(
        title: "Automations",
        subtitle: "Prompt, schedule, and AI destination · plain text in workflows/",
        surface: .approvals
      ) {
        if store.isLoadingAgentWorkflows { WorkspaceActivityIndicator(size: .small) }
        Button {
          isCreatingAutomation = true
        } label: {
          Label("New Automation", systemImage: "plus")
        }
        Button(role: .destructive) {
          workflowPendingDeletion = store.agentWorkflows.first {
            $0.id == store.selectedAgentWorkflowID
          }
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .disabled(
          store.selectedAgentWorkflowID == nil
            || store.selectedAgentWorkflowID.map(store.mutatingAgentWorkflowIDs.contains) == true
        )
        .help("Delete the selected automation")
        Button {
          Task { await store.refreshAgentWorkflows(updatesStatus: true) }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isLoadingAgentWorkflows)
      }

      HStack(alignment: .top, spacing: 8) {
        Image(systemName: store.automationSchedulerErrorText == nil
          ? scheduler.systemImage
          : "exclamationmark.triangle.fill")
          .frame(width: 16, height: 16)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(scheduler.title)
              .fontWeight(.semibold)
            Spacer(minLength: 8)
            Button("Manage") {
              settingsSelection = WorkspaceSettingsNavigation.workspace
              openSettings()
            }
            .controlSize(.small)
            .help("Open Settings → General")
          }
          Text(scheduler.detail)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
          if !scheduler.isResolved || scheduler.isCurrentHost {
            Text(store.automationSchedulerStatusText)
              .foregroundStyle(.tertiary)
          }
          if let schedulerError = store.automationSchedulerErrorText {
            Text(schedulerError)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
          if let eventSourceStatus = store.workflowEventSourceStatusText {
            Text(eventSourceStatus)
              .foregroundStyle(.orange)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.vertical, 6)

      if store.isLoadingAgentWorkflows && store.agentWorkflows.isEmpty {
        Spacer(); WorkspaceLoadingStateView("Loading automations"); Spacer()
      } else if store.agentWorkflows.isEmpty {
        EmptyStateView(
          title: "No Automations",
          detail: "Create a prompt, choose an AI destination, and optionally add a schedule. Its editable Org source will appear in workflows/."
        )
      } else {
        WorkspaceLazyCollection {
          ForEach(store.agentWorkflows) { workflow in
            WorkflowRow(workflow: workflow)
              .contentShape(Rectangle())
              .onTapGesture {
                selectWorkflow(workflow)
              }
              .modifier(ReadableListSelectionModifier(isSelected: store.selectedAgentWorkflowID == workflow.id))
              .workspaceAccessibleCollectionRow(
                kind: "workflow",
                id: workflow.id,
                label: workflow.title,
                isSelected: store.selectedAgentWorkflowID == workflow.id,
                open: { selectWorkflow(workflow) }
              )
              .contextMenu {
                Button("Run Now") { runWorkflow = workflow }
                Button("View History") { store.showAgentWorkflowHistory(workflow) }
                Button("Edit Source") {
                  store.selectAgentWorkflow(workflow)
                  store.beginEditingCurrentScope()
                }
                Button("Validate") { Task { await store.validateAgentWorkflow(workflow) } }
                Divider()
                Button("Schedule…") { scheduleWorkflow = workflow }
                if workflow.state == "active" {
                  Button("Pause") { Task { await store.setAgentWorkflowState(workflow, state: "paused") } }
                } else {
                  Button("Activate") { Task { await store.setAgentWorkflowState(workflow, state: "active") } }
                }
                Divider()
                Button("Delete Automation…", role: .destructive) {
                  workflowPendingDeletion = workflow
                }
              }
              .workspaceLazyRow(id: workflow.id)
          }
        }
        .onChange(of: store.selectedAgentWorkflowID) {
          guard let id = store.selectedAgentWorkflowID,
                let workflow = store.agentWorkflows.first(where: { $0.id == id }) else { return }
          performAfterSwiftUIViewUpdate(for: workspaceTabID, in: store) {
            guard store.selectedAgentWorkflowID == id else { return }
            store.selectAgentWorkflow(workflow)
          }
        }
      }
    }
    .task {
      await store.refreshSelectedRunReviewPageIfNeeded()
    }
    .sheet(item: $runWorkflow) { workflow in
      WorkflowRunSheet(workflow: workflow)
        .environment(store)
    }
    .sheet(item: $scheduleWorkflow) { workflow in
      WorkflowScheduleSheet(workflow: workflow)
        .environment(store)
    }
    .sheet(isPresented: $isCreatingAutomation) {
      NewAutomationSheet()
        .environment(store)
    }
    .confirmationDialog(
      "Delete \(workflowPendingDeletion?.title ?? "Automation")?",
      isPresented: Binding(
        get: { workflowPendingDeletion != nil },
        set: { if !$0 { workflowPendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Automation", role: .destructive) {
        guard let workflow = workflowPendingDeletion else { return }
        workflowPendingDeletion = nil
        Task { await store.deleteAgentWorkflow(workflow) }
      }
      Button("Cancel", role: .cancel) {
        workflowPendingDeletion = nil
      }
    } message: {
      Text("This removes the workflow definition. Existing run history is preserved.")
    }
  }

  private func selectWorkflow(_ workflow: AgentWorkflowItem) {
    if store.selectedAgentWorkflowID == workflow.id {
      store.selectAgentWorkflow(workflow)
    } else {
      store.selectedAgentWorkflowID = workflow.id
    }
  }
}

private struct WorkflowRow: View {
  @Environment(WorkspaceStore.self) private var store
  let workflow: AgentWorkflowItem

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(workflow.title)
          .font(.body.weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        if store.mutatingAgentWorkflowIDs.contains(workflow.id) {
          WorkspaceActivityIndicator(size: .mini)
        }
        StatusPill(text: workflow.state)
      }
      Text(workflow.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      HStack(spacing: 8) {
        Label("v\(workflow.version)", systemImage: "point.3.connected.trianglepath.dotted")
        Label(workflow.scheduleSummary, systemImage: workflow.scheduleTrigger?.enabled == true ? "clock" : "play")
        if let destinationRef = workflow.destinationRef {
          Label(store.aiChatDestination(id: destinationRef)?.title ?? destinationRef, systemImage: "paperplane")
        }
        if let model = workflow.model {
          Label(model, systemImage: "cpu")
        }
        if let reasoningEffort = workflow.reasoningEffort {
          Label(reasoningEffort, systemImage: "brain")
        }
        let runCount = store.agentRunCount(workflowID: workflow.id)
        if runCount > 0 {
          Button {
            store.showAgentWorkflowHistory(workflow)
          } label: {
            Label("\(runCount) run\(runCount == 1 ? "" : "s")", systemImage: "clock.arrow.circlepath")
          }
          .buttonStyle(.plain)
          .help("Show this automation’s run history")
        }
        if workflow.legacyLocation {
          Label("Legacy location", systemImage: "exclamationmark.triangle")
        }
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .lineLimit(1)
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct WorkflowRunSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let workflow: AgentWorkflowItem
  @State private var values: [String: String]

  init(workflow: AgentWorkflowItem) {
    self.workflow = workflow
    _values = State(initialValue: Dictionary(uniqueKeysWithValues: workflow.inputs.map { ($0.id, $0.default ?? "") }))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Run \(workflow.title)").font(.title2.weight(.semibold))
      let destinationName = workflow.destinationRef.flatMap { store.aiChatDestination(id: $0)?.title }
        ?? "your default AI destination"
      Text("Celorga will create a durable run, then send the prompt to \(destinationName).")
        .foregroundStyle(.secondary)
      if workflow.inputs.isEmpty {
        Text("This workflow has no inputs.").foregroundStyle(.secondary)
      } else {
        Form {
          ForEach(workflow.inputs) { input in
            TextField(input.description, text: binding(for: input.id))
              .help(input.required ? "Required input: \(input.id)" : "Optional input: \(input.id)")
          }
        }
        .formStyle(.grouped)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Run Now") {
          let inputs = values.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
          dismiss()
          Task { await store.runAgentWorkflow(workflow, inputs: inputs) }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(hasMissingRequiredInput)
      }
    }
    .padding(24)
    .frame(width: 560, height: max(300, CGFloat(230 + workflow.inputs.count * 54)))
  }

  private var hasMissingRequiredInput: Bool {
    workflow.inputs.contains { $0.required && (values[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private func binding(for id: String) -> Binding<String> {
    Binding(get: { values[id] ?? "" }, set: { values[id] = $0 })
  }
}

private struct NewAutomationSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var prompt = ""
  @State private var destinationID = ""
  @State private var model = ""
  @State private var reasoningEffort = ""
  @State private var agentRef = ""
  @State private var scheduleEnabled = true
  @State private var schedule = "0 9 * * 1"
  @State private var timezone = TimeZone.current.identifier
  @State private var isCreating = false
  @State private var creationError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Automation").font(.title2.weight(.semibold))
      Text("The prompt and schedule are stored in an ordinary Org workflow file. Celorga creates a durable run before sending each occurrence to the selected AI destination.")
        .foregroundStyle(.secondary)

      Form {
        TextField("Name", text: $title)

        AutomationAIConfigurationFields(
          destinationID: $destinationID,
          model: $model,
          reasoningEffort: $reasoningEffort
        )

        Picker("Agent", selection: $agentRef) {
          Text("Destination default").tag("")
          ForEach(store.agentProfiles) { profile in
            Text(profile.name).tag(profile.id)
          }
        }

        Toggle("Run on a schedule", isOn: $scheduleEnabled)
        if scheduleEnabled {
          AutomationScheduleEditor(expression: $schedule, timezone: $timezone)
        }

        VStack(alignment: .leading, spacing: 6) {
          Text("Prompt")
          TextEditor(text: $prompt)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 180)
            .overlay {
              RoundedRectangle(cornerRadius: 6)
                .stroke(WorkspaceDesign.hairline)
            }
        }
      }
      .formStyle(.grouped)
      .disabled(isCreating)

      if let creationError {
        Label(creationError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isCreating)
        Button {
          let selectedAgent = agentRef.isEmpty ? nil : agentRef
          let selectedSchedule = scheduleEnabled ? schedule : nil
          creationError = nil
          isCreating = true
          Task { @MainActor in
            let created = await store.createAgentAutomation(
              title: title,
              prompt: prompt,
              destinationID: destinationID,
              model: model,
              reasoningEffort: reasoningEffort,
              agentRef: selectedAgent,
              schedule: selectedSchedule,
              timezone: timezone
            )
            isCreating = false
            if created {
              dismiss()
            } else {
              creationError = store.errorText ?? "Celorga could not create this automation."
            }
          }
        } label: {
          if isCreating {
            HStack(spacing: 6) {
              ProgressView().controlSize(.small)
              Text("Creating…")
            }
          } else {
            Text("Create Automation")
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(
          title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || destinationID.isEmpty
            || (scheduleEnabled && schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || isCreating
        )
      }
    }
    .padding(24)
    .frame(width: 640, height: 700)
    .onAppear {
      if destinationID.isEmpty {
        destinationID = store.enabledAIChatDestinations.first?.id ?? ""
      }
      if store.agentProfiles.isEmpty {
        Task { await store.refreshAgentProfiles() }
      }
    }
  }
}

private struct WorkflowScheduleSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let workflow: AgentWorkflowItem
  @State private var enabled: Bool
  @State private var cron: String
  @State private var timezone: String
  @State private var destinationID: String
  @State private var model: String
  @State private var reasoningEffort: String
  @State private var skipWhileRunning: Bool
  @State private var isSaving = false
  @State private var saveError: String?

  init(workflow: AgentWorkflowItem) {
    self.workflow = workflow
    let trigger = workflow.scheduleTrigger
    _enabled = State(initialValue: trigger?.enabled == true)
    _cron = State(initialValue: trigger?.schedule ?? "0 9 * * 1")
    _timezone = State(initialValue: trigger?.timezone ?? TimeZone.current.identifier)
    _destinationID = State(initialValue: workflow.destinationRef ?? "")
    _model = State(initialValue: workflow.model ?? "")
    _reasoningEffort = State(initialValue: workflow.reasoningEffort ?? "")
    _skipWhileRunning = State(initialValue: trigger?.skipsWhileRunning == true)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Schedule \(workflow.title)").font(.title2.weight(.semibold))
      Text("Celorga checks this schedule while the app is running and sends each occurrence to the selected AI destination. The definition remains plain text.")
        .foregroundStyle(.secondary)
      AutomationAIConfigurationFields(
        destinationID: $destinationID,
        model: $model,
        reasoningEffort: $reasoningEffort
      )
      Toggle("Enable schedule", isOn: $enabled)
      if enabled {
        AutomationScheduleEditor(expression: $cron, timezone: $timezone)
        VStack(alignment: .leading, spacing: 2) {
          Toggle("Skip while a previous run is still active", isOn: $skipWhileRunning)
          Text("Off by default: each occurrence starts a new run, so a run that hangs cannot hold up the schedule.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if let saveError {
        Label(saveError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
        Button {
          saveError = nil
          isSaving = true
          Task { @MainActor in
            let saved = await store.setAgentWorkflowSchedule(
              workflow,
              cron: cron,
              timezone: timezone,
              destinationID: destinationID,
              model: model,
              reasoningEffort: reasoningEffort,
              enabled: enabled,
              skipWhileRunning: skipWhileRunning
            )
            isSaving = false
            if saved {
              dismiss()
            } else {
              saveError = store.errorText ?? "Celorga could not save this schedule."
            }
          }
        } label: {
          if isSaving {
            HStack(spacing: 6) {
              ProgressView().controlSize(.small)
              Text("Saving…")
            }
          } else {
            Text("Save")
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(
          isSaving
            || (enabled
              && (destinationID.isEmpty
                || cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        )
      }
    }
    .padding(24)
    .frame(width: 560)
    .onAppear {
      if destinationID.isEmpty {
        destinationID = store.enabledAIChatDestinations.first?.id ?? ""
      }
    }
  }
}

private struct AutomationAIConfigurationFields: View {
  @Environment(WorkspaceStore.self) private var store
  @Binding var destinationID: String
  @Binding var model: String
  @Binding var reasoningEffort: String
  @State private var modelOptions: [AIChatModelOption] = []
  @State private var isLoadingModels = false
  @State private var modelLoadError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("AI destination", selection: $destinationID) {
        ForEach(store.enabledAIChatDestinations) { destination in
          Label(destination.title, systemImage: destination.systemImage)
            .tag(destination.id)
        }
      }

      Picker("Model", selection: $model) {
        Text("Destination default").tag("")
        ForEach(displayedModelOptions) { option in
          Text(option.label).tag(option.id)
        }
      }
      .disabled(destinationID.isEmpty)
      .help("The selected model identifier is stored in the automation file. Choose Destination default to leave it unset.")

      Picker("Reasoning effort", selection: $reasoningEffort) {
        Text(defaultReasoningLabel).tag("")
        ForEach(displayedReasoningOptions) { option in
          Text(option.label).tag(option.id)
        }
      }
      .disabled(destinationID.isEmpty)
      .help("The selected reasoning level is stored in the automation file. Choose Destination default to leave it unset.")

      if isLoadingModels && modelOptions.isEmpty {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Loading models…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let modelLoadError, modelOptions.isEmpty {
        Label(modelLoadError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .onChange(of: destinationID) { previousDestinationID, currentDestinationID in
      guard previousDestinationID != currentDestinationID else { return }
      model = ""
      reasoningEffort = ""
      modelOptions = store.cachedAutomationModelOptions(
        forDestinationID: currentDestinationID
      )
      modelLoadError = nil
    }
    .onChange(of: model) { previousModel, currentModel in
      guard previousModel != currentModel else { return }
      reasoningEffort = ""
    }
    .task(id: destinationID) {
      await loadModels()
    }
  }

  private var displayedModelOptions: [AIChatModelOption] {
    guard !model.isEmpty,
          !modelOptions.contains(where: { $0.id == model })
    else {
      return modelOptions
    }
    return modelOptions + [AIChatModelOption(id: model, label: "Current: \(model)")]
  }

  private var selectedModelOption: AIChatModelOption? {
    if !model.isEmpty {
      return modelOptions.first(where: { $0.id == model })
    }
    if let configuredModel = store.aiChatDestination(id: destinationID)?.model,
       let configured = modelOptions.first(where: { $0.id == configuredModel }) {
      return configured
    }
    return modelOptions.first(where: \.isDefault)
  }

  private var displayedReasoningOptions: [AIChatReasoningOption] {
    let options = selectedModelOption?.reasoningOptions ?? []
    guard !reasoningEffort.isEmpty,
          !options.contains(where: { $0.id == reasoningEffort })
    else {
      return options
    }
    return options + [AIChatReasoningOption(
      id: reasoningEffort,
      label: "Current: \(reasoningEffort)"
    )]
  }

  private var defaultReasoningLabel: String {
    guard let defaultEffort = selectedModelOption?.defaultReasoningEffort,
          !defaultEffort.isEmpty
    else {
      return "Destination default"
    }
    let label = selectedModelOption?.reasoningOptions
      .first(where: { $0.id == defaultEffort })?.label ?? defaultEffort
    return "Destination default (\(label))"
  }

  private func loadModels() async {
    guard !destinationID.isEmpty else {
      modelOptions = []
      modelLoadError = nil
      isLoadingModels = false
      return
    }

    let requestedDestinationID = destinationID
    modelOptions = store.cachedAutomationModelOptions(
      forDestinationID: requestedDestinationID
    )
    modelLoadError = nil
    isLoadingModels = true
    defer {
      if destinationID == requestedDestinationID {
        isLoadingModels = false
      }
    }
    do {
      let refreshed = try await store.refreshAutomationModelOptions(
        forDestinationID: requestedDestinationID
      )
      try Task.checkCancellation()
      guard destinationID == requestedDestinationID else { return }
      if !refreshed.isEmpty {
        modelOptions = refreshed
      }
    } catch is CancellationError {
      return
    } catch {
      if destinationID == requestedDestinationID && modelOptions.isEmpty {
        modelLoadError = error.localizedDescription
      }
    }
  }
}

private struct AutomationScheduleEditor: View {
  @Binding private var expression: String
  @Binding private var timezone: String
  @State private var draft: AutomationScheduleDraft

  init(expression: Binding<String>, timezone: Binding<String>) {
    _expression = expression
    _timezone = timezone
    _draft = State(initialValue: AutomationScheduleDraft(expression: expression.wrappedValue))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Frequency", selection: $draft.frequency) {
        ForEach(AutomationScheduleFrequency.allCases) { frequency in
          Text(frequency.title).tag(frequency)
        }
      }

      switch draft.frequency {
      case .interval:
        Stepper(
          "Every \(draft.intervalHours) hour\(draft.intervalHours == 1 ? "" : "s")",
          value: $draft.intervalHours,
          in: 1...24
        )
      case .daily, .weekdays:
        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
      case .weekly:
        Picker("Day", selection: $draft.weekday) {
          ForEach(Array(AutomationScheduleDraft.weekdayNames.enumerated()), id: \.offset) { index, name in
            Text(name).tag(index)
          }
        }
        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
      case .monthly:
        Stepper("Day \(draft.monthDay) of the month", value: $draft.monthDay, in: 1...31)
        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
      case .advanced:
        TextField("Five-field cron or every 4h", text: $draft.advancedExpression)
        Text("Use a five-field cron expression or an interval such as every 4h.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Picker("Timezone", selection: $timezone) {
        ForEach(timezoneOptions, id: \.self) { identifier in
          Text(timezoneLabel(identifier)).tag(identifier)
        }
      }
      DisclosureGroup("Advanced timezone") {
        TextField("IANA timezone identifier", text: $timezone)
          .textFieldStyle(.roundedBorder)
      }

      Label(draft.summary, systemImage: "calendar.badge.clock")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
      Text("Celorga catches up the latest missed occurrence when it reopens.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .onAppear { expression = draft.expression }
    .onChange(of: draft) { _, updatedDraft in
      expression = updatedDraft.expression
    }
  }

  private var timeBinding: Binding<Date> {
    Binding(
      get: {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = draft.hour
        components.minute = draft.minute
        return Calendar.current.date(from: components) ?? Date()
      },
      set: { date in
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        draft.hour = components.hour ?? draft.hour
        draft.minute = components.minute ?? draft.minute
      }
    )
  }

  private var timezoneOptions: [String] {
    var identifiers = [
      TimeZone.current.identifier,
      timezone,
      "UTC",
      "America/Los_Angeles",
      "America/Denver",
      "America/Chicago",
      "America/New_York",
      "Europe/London",
      "Europe/Berlin",
      "Asia/Tokyo",
      "Australia/Sydney"
    ]
    identifiers = identifiers.filter { !$0.isEmpty }
    return identifiers.reduce(into: []) { result, identifier in
      if !result.contains(identifier) { result.append(identifier) }
    }
  }

  private func timezoneLabel(_ identifier: String) -> String {
    identifier == TimeZone.current.identifier ? "Local (\(identifier))" : identifier
  }
}
