import AppKit
import SwiftUI

private struct WorkspaceTabIDEnvironmentKey: EnvironmentKey {
  static let defaultValue: WorkspaceTab.ID? = nil
}

private extension EnvironmentValues {
  var workspaceTabID: WorkspaceTab.ID? {
    get { self[WorkspaceTabIDEnvironmentKey.self] }
    set { self[WorkspaceTabIDEnvironmentKey.self] = newValue }
  }
}

@MainActor
private func performAfterSwiftUIViewUpdate(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  Task { @MainActor in
    await Task.yield()
    guard !Task.isCancelled else { return }
    operation()
  }
}

@MainActor
private func performAfterSwiftUIViewUpdate(
  for workspaceTabID: WorkspaceTab.ID?,
  in store: WorkspaceStore,
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  guard let workspaceTabID else { return }
  Task { @MainActor in
    await Task.yield()
    guard !Task.isCancelled,
          store.selectedWorkspaceTabID == workspaceTabID
    else { return }
    operation()
  }
}

public struct ContentView: View {
  @Environment(WorkspaceStore.self) private var store

  public init() {}

  public var body: some View {
    @Bindable var store = store
    GeometryReader { proxy in
      VStack(spacing: 0) {
        WorkspaceTabBar()
        NavigationSplitView {
          SidebarView()
            .navigationSplitViewColumnWidth(
              min: WorkspaceSidebarLayout.minimumWidth,
              ideal: WorkspaceSidebarLayout.defaultWidth(for: proxy.size.width),
              max: WorkspaceSidebarLayout.maximumWidth(for: proxy.size.width)
            )
        } detail: {
          WorkspaceMainArea(workspaceTabID: store.selectedWorkspaceTabID)
            .id(store.selectedWorkspaceTabID)
        }
      }
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Button {
            store.navigateBack()
          } label: {
            Label("Back", systemImage: "chevron.left")
          }
          .labelStyle(.iconOnly)
          .frame(width: 28, height: 28)
          .disabled(!store.canNavigateBack)
          .help(store.canNavigateBack ? "Back (⌘[)" : "No previous location")
        }
        ToolbarItem(placement: .navigation) {
          Button {
            store.navigateForward()
          } label: {
            Label("Forward", systemImage: "chevron.right")
          }
          .labelStyle(.iconOnly)
          .frame(width: 28, height: 28)
          .disabled(!store.canNavigateForward)
          .help(store.canNavigateForward ? "Forward (⌘])" : "No next location")
        }

        ToolbarItem {
          MeetingRecordingToolbarIndicator()
        }

        ToolbarItemGroup {
          Button {
            store.makeSurfacePrimary(.aiChat)
          } label: {
            Label("Open AI Chat", systemImage: "bubble.left")
          }

          Button {
            store.chooseCorpus()
          } label: {
            Label("Mount Corpus", systemImage: "folder.badge.plus")
          }

          Button {
            if store.isRefreshingWorkspace {
              store.cancelWorkspaceRefresh()
            } else {
              Task { await store.refreshWorkspace() }
            }
          } label: {
            if store.isRefreshingWorkspace {
              HStack(spacing: 6) {
                WorkspaceActivityIndicator(size: .small)
                Text("Cancel Refresh All")
              }
            } else {
              Label("Refresh All", systemImage: "arrow.clockwise")
            }
          }
          .disabled(store.corpusRoot == nil && !store.isRefreshingWorkspace)
          .help(store.isRefreshingWorkspace ? "Stop the current workspace refresh (⌘R)" : "Refresh every workspace view (⌘R)")
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        if let error = store.errorText, !error.isEmpty {
          WorkspaceActionErrorBanner(error: error) { store.errorText = nil }
        }
      }
      .toolbarBackground(WorkspaceDesign.barBackground, for: .windowToolbar)
      .toolbarBackground(.visible, for: .windowToolbar)
      .keyboardEventMonitor { event, scope in
        store.handleWorkspaceKeyDown(event, scope: scope)
      }
      .environment(\.openOrgFileReference) { reference in
        store.openChatFileReference(reference)
      }
      .environment(\.openOrgFileReferenceInNewTab) { reference in
        store.openChatFileReferenceInNewTab(reference)
      }
      .environment(\.openWorkspaceWebLink, store.openWorkspaceWebLinkAction)
      .environment(\.recordUsageEvent) { event, fields in
        store.usageLog.record(event, fields)
      }
      .onDisappear {
        store.flushDeferredAIChatTranscriptPersistence()
      }
      .sheet(isPresented: $store.isQuickOpenPresented) {
        QuickOpenView()
          .environment(store)
      }
      .sheet(isPresented: $store.isNodeBriefOptionsPresented) {
        NodeBriefOptionsView()
          .environment(store)
      }
      .sheet(item: $store.pendingStartWorkRequest) { request in
        StartWorkOptionsView(request: request)
          .environment(store)
      }
      .sheet(item: $store.activePluginReview) { review in
        PluginProposalReviewSheet(review: review)
          .environment(store)
      }
      .sheet(isPresented: $store.isKeyboardShortcutsPresented) {
        KeyboardShortcutsView()
          .environment(store)
      }
      .sheet(isPresented: $store.isOrgCryptConfigurationPresented) {
        OrgCryptConfigurationSheet()
          .environment(store)
      }
      .sheet(item: $store.orgCryptPeek) { peek in
        OrgCryptPeekSheet(peek: peek)
          .environment(store)
      }
      .sheet(isPresented: $store.isLaunchGuidePresented) {
        OpenOrgLaunchGuideView()
          .environment(store)
      }
      .sheet(isPresented: $store.isDataSourceConfigurationPresented) {
        DataSourceConfigurationSheet()
          .environment(store)
      }
      .sheet(isPresented: $store.isLiveEmbedInsertPresented) {
        LiveEmbedInsertSheet().environment(store)
      }
      .sheet(isPresented: $store.isDocumentPublisherPresented) {
        DocumentPublishSheet()
          .environment(store)
      }
      .sheet(isPresented: $store.isCapturePanelPresented) {
        GlobalCaptureView()
          .environment(store)
      }
      .sheet(isPresented: $store.isDailyNoteDatePickerPresented) {
        DailyNoteDatePickerSheet()
          .environment(store)
      }
      .sheet(isPresented: $store.isNewCorpusFileSheetPresented) {
        NewCorpusFileSheet()
          .environment(store)
      }
      .sheet(isPresented: $store.isSimilarTodoAssignmentPresented) {
        SimilarTodoAssignmentView()
          .environment(store)
      }
      .sheet(item: $store.editorSaveConflict, onDismiss: {
        store.keepEditingAfterSaveConflict()
      }) { conflict in
        EditorSaveConflictSheet(conflict: conflict)
          .environment(store)
      }
      .alert(item: $store.exportNotice) { notice in
        Alert(
          title: Text(notice.title),
          message: Text(notice.message),
          dismissButton: .default(Text("OK"))
        )
      }
    }
  }
}

private struct WorkspaceTabBar: View {
  @Environment(WorkspaceStore.self) private var store
  @StateObject private var dragCoordinator = WorkspaceTabDragCoordinator()

  var body: some View {
    HStack(spacing: 8) {
      WorkspaceTabStrip(
        items: store.workspaceTabs.map { tab in
          WorkspaceTabStripItem(
            id: tab.id,
            title: store.workspaceTabDisplayTitle(for: tab),
            systemImage: store.workspaceTabDisplaySystemImage(for: tab)
          )
        },
        selectedTabID: store.selectedWorkspaceTabID,
        dragCoordinator: dragCoordinator,
        select: store.selectWorkspaceTab,
        close: store.closeWorkspaceTab,
        duplicate: { tabID in
          _ = store.duplicateWorkspaceTab(tabID)
        },
        newTab: { tabID in
          store.selectWorkspaceTab(tabID)
          store.newWorkspaceTab()
        },
        move: store.moveWorkspaceTab,
        closeOthers: store.closeOtherWorkspaceTabs,
        moveTab: { sourceID, targetID in
          _ = store.moveWorkspaceTab(sourceID, to: targetID)
        }
      )

      Button {
        store.newWorkspaceTab()
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .background(WorkspaceDesign.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .help("New Tab (⌘T)")
      .accessibilityLabel("New Tab")
      .padding(.trailing, 8)
    }
    .frame(height: 36)
    .background(WorkspaceDesign.barBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(height: 1)
        .allowsHitTesting(false)
    }
  }
}

struct WorkspaceTabStripItem: Identifiable, Equatable {
  let id: WorkspaceTab.ID
  let title: String
  let systemImage: String
}

private struct WorkspaceTabStrip: NSViewRepresentable {
  let items: [WorkspaceTabStripItem]
  let selectedTabID: WorkspaceTab.ID
  let dragCoordinator: WorkspaceTabDragCoordinator
  let select: (WorkspaceTab.ID) -> Void
  let close: (WorkspaceTab.ID) -> Void
  let duplicate: (WorkspaceTab.ID) -> Void
  let newTab: (WorkspaceTab.ID) -> Void
  let move: (WorkspaceTab.ID, Int) -> Void
  let closeOthers: (WorkspaceTab.ID) -> Void
  let moveTab: (WorkspaceTab.ID, WorkspaceTab.ID) -> Void

  func makeNSView(context: Context) -> WorkspaceTabStripView {
    WorkspaceTabStripView(frame: .zero)
  }

  func updateNSView(_ view: WorkspaceTabStripView, context: Context) {
    view.update(
      items: items,
      selectedTabID: selectedTabID,
      dragCoordinator: dragCoordinator,
      select: select,
      close: close,
      duplicate: duplicate,
      newTab: newTab,
      move: move,
      closeOthers: closeOthers,
      moveTab: moveTab
    )
  }
}

@MainActor
final class WorkspaceTabStripView: NSView {
  private static let tabWidth: CGFloat = 180
  private static let tabHeight: CGFloat = 28
  private static let tabSpacing: CGFloat = 4
  private static let horizontalPadding: CGFloat = 6

  private let scrollView = NSScrollView()
  private let tabDocumentView = FlippedWorkspaceTabDocumentView()
  private var orderedTabIDs: [WorkspaceTab.ID] = []
  private var tabViews: [WorkspaceTab.ID: WorkspaceTabInteractionView] = [:]
  private var selectedTabID: WorkspaceTab.ID?
  private weak var dragCoordinator: WorkspaceTabDragCoordinator?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = false
    scrollView.horizontalScrollElasticity = .automatic
    scrollView.verticalScrollElasticity = .none
    scrollView.documentView = tabDocumentView
    addSubview(scrollView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    scrollView.frame = bounds

    let contentWidth = max(
      bounds.width,
      Self.horizontalPadding * 2
        + CGFloat(orderedTabIDs.count) * Self.tabWidth
        + CGFloat(max(0, orderedTabIDs.count - 1)) * Self.tabSpacing
    )
    tabDocumentView.frame = NSRect(
      x: 0,
      y: 0,
      width: contentWidth,
      height: bounds.height
    )
    let tabY = max(0, (bounds.height - Self.tabHeight) / 2)
    for (index, tabID) in orderedTabIDs.enumerated() {
      tabViews[tabID]?.frame = NSRect(
        x: Self.horizontalPadding + CGFloat(index) * (Self.tabWidth + Self.tabSpacing),
        y: tabY,
        width: Self.tabWidth,
        height: Self.tabHeight
      )
    }
    dragCoordinator?.restoreLiveLayout()
  }

  func update(
    items: [WorkspaceTabStripItem],
    selectedTabID: WorkspaceTab.ID,
    dragCoordinator: WorkspaceTabDragCoordinator,
    select: @escaping (WorkspaceTab.ID) -> Void,
    close: @escaping (WorkspaceTab.ID) -> Void,
    duplicate: @escaping (WorkspaceTab.ID) -> Void,
    newTab: @escaping (WorkspaceTab.ID) -> Void,
    move: @escaping (WorkspaceTab.ID, Int) -> Void,
    closeOthers: @escaping (WorkspaceTab.ID) -> Void,
    moveTab: @escaping (WorkspaceTab.ID, WorkspaceTab.ID) -> Void
  ) {
    let nextIDs = Set(items.map(\.id))
    if dragCoordinator.hasActiveDrag, Set(orderedTabIDs) != nextIDs {
      dragCoordinator.cancel()
    }
    self.dragCoordinator = dragCoordinator
    for (tabID, tabView) in tabViews where !nextIDs.contains(tabID) {
      tabView.removeFromSuperview()
      tabViews.removeValue(forKey: tabID)
    }

    let canClose = items.count > 1
    for (index, item) in items.enumerated() {
      let tabView: WorkspaceTabInteractionView
      if let existing = tabViews[item.id] {
        tabView = existing
      } else {
        tabView = WorkspaceTabInteractionView(frame: .zero)
        tabViews[item.id] = tabView
        tabDocumentView.addSubview(tabView)
      }
      tabView.tabID = item.id
      tabView.title = item.title
      tabView.systemImage = item.systemImage
      tabView.isSelected = selectedTabID == item.id
      tabView.showsCloseButton = canClose && selectedTabID == item.id
      tabView.canClose = canClose
      tabView.canMoveLeft = index > 0
      tabView.canMoveRight = index < items.count - 1
      tabView.dragCoordinator = dragCoordinator
      tabView.select = { select(item.id) }
      tabView.close = { close(item.id) }
      tabView.duplicate = { duplicate(item.id) }
      tabView.newTab = { newTab(item.id) }
      tabView.moveLeft = { move(item.id, -1) }
      tabView.moveRight = { move(item.id, 1) }
      tabView.closeOthers = { closeOthers(item.id) }
      tabView.moveTab = { sourceID in moveTab(sourceID, item.id) }
      tabView.updatePresentation()
    }

    let selectionChanged = self.selectedTabID != selectedTabID
    orderedTabIDs = items.map(\.id)
    self.selectedTabID = selectedTabID
    needsLayout = true
    if selectionChanged {
      performAfterSwiftUIViewUpdate { [weak self] in
        self?.scrollSelectedTabToVisible()
      }
    }
  }

  func tabView(for tabID: WorkspaceTab.ID) -> WorkspaceTabInteractionView? {
    tabViews[tabID]
  }

  private func scrollSelectedTabToVisible() {
    layoutSubtreeIfNeeded()
    guard let selectedTabID,
          let tabView = tabViews[selectedTabID]
    else { return }
    tabView.scrollToVisible(tabView.bounds)
  }
}

private final class FlippedWorkspaceTabDocumentView: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
    for child in subviews.reversed() {
      let childPoint = child.convert(point, from: self)
      if let hitView = child.hitTest(childPoint) {
        return hitView
      }
    }
    return self
  }
}

@MainActor
final class WorkspaceTabDragCoordinator: ObservableObject {
  private struct LiveDragState {
    let views: [WorkspaceTabInteractionView]
    let slotFrames: [NSRect]
    let sourceIndex: Int
    let grabOffsetX: CGFloat
    var targetIndex: Int
    var sourceX: CGFloat
  }

  private let reorderAnimationDuration: TimeInterval
  private weak var sourceView: WorkspaceTabInteractionView?
  private var liveDragState: LiveDragState?

  init(reorderAnimationDuration: TimeInterval = 0.12) {
    self.reorderAnimationDuration = reorderAnimationDuration
  }

  var hasActiveDrag: Bool { sourceView != nil }

  func begin(from source: WorkspaceTabInteractionView, grabOffsetX: CGFloat) {
    cancel()
    guard let container = source.superview else { return }
    let views = container.subviews
      .compactMap { $0 as? WorkspaceTabInteractionView }
      .sorted { $0.frame.minX < $1.frame.minX }
    guard views.count > 1,
          let sourceIndex = views.firstIndex(where: { $0 === source })
    else { return }

    let slotFrames = views.map(\.frame)
    sourceView = source
    liveDragState = LiveDragState(
      views: views,
      slotFrames: slotFrames,
      sourceIndex: sourceIndex,
      grabOffsetX: min(max(0, grabOffsetX), source.bounds.width),
      targetIndex: sourceIndex,
      sourceX: source.frame.minX
    )
    source.setBeingDragged(true)
  }

  func update(pointerX: CGFloat) {
    guard var state = liveDragState,
          sourceView != nil,
          let firstSlot = state.slotFrames.first,
          let lastSlot = state.slotFrames.last
    else { return }

    let sourceX = min(
      max(pointerX - state.grabOffsetX, firstSlot.minX),
      lastSlot.minX
    )
    let targetIndex = state.slotFrames.enumerated().min { first, second in
      abs(first.element.minX - sourceX) < abs(second.element.minX - sourceX)
    }?.offset ?? state.sourceIndex
    let targetChanged = targetIndex != state.targetIndex
    state.targetIndex = targetIndex
    state.sourceX = sourceX
    liveDragState = state
    applyLiveLayout(state, animatingNeighbors: targetChanged)
  }

  func finish() {
    guard let state = liveDragState,
          let source = sourceView
    else {
      cancel()
      return
    }

    let targetView = state.targetIndex == state.sourceIndex
      ? nil
      : state.views[state.targetIndex]
    applySettledLayout(state, animated: true)
    source.setBeingDragged(false)
    sourceView = nil
    liveDragState = nil
    targetView?.moveTab?(source.tabID)
  }

  func cancel() {
    if let state = liveDragState {
      applyOriginalLayout(state, animated: true)
    }
    sourceView?.setBeingDragged(false)
    sourceView = nil
    liveDragState = nil
  }

  func restoreLiveLayout() {
    guard let state = liveDragState else { return }
    applyLiveLayout(state, animatingNeighbors: false)
  }

  private func applyLiveLayout(
    _ state: LiveDragState,
    animatingNeighbors: Bool
  ) {
    guard let source = sourceView else { return }
    let visualOrder = visualOrder(for: state)
    let neighborTargets = visualOrder.enumerated().compactMap { index, view in
      view === source ? nil : (view, state.slotFrames[index])
    }
    applyFrames(
      neighborTargets,
      animated: animatingNeighbors
    )

    var sourceFrame = state.slotFrames[state.targetIndex]
    sourceFrame.origin.x = state.sourceX
    source.frame = sourceFrame
  }

  private func applySettledLayout(_ state: LiveDragState, animated: Bool) {
    let targets = visualOrder(for: state).enumerated().map { index, view in
      (view, state.slotFrames[index])
    }
    applyFrames(targets, animated: animated)
  }

  private func applyOriginalLayout(_ state: LiveDragState, animated: Bool) {
    let targets = state.views.enumerated().map { index, view in
      (view, state.slotFrames[index])
    }
    applyFrames(targets, animated: animated)
  }

  private func visualOrder(for state: LiveDragState) -> [WorkspaceTabInteractionView] {
    var visualOrder = state.views
    let source = visualOrder.remove(at: state.sourceIndex)
    visualOrder.insert(source, at: state.targetIndex)
    return visualOrder
  }

  private func applyFrames(
    _ targets: [(WorkspaceTabInteractionView, NSRect)],
    animated: Bool
  ) {
    guard animated, reorderAnimationDuration > 0 else {
      for (view, frame) in targets {
        view.frame = frame
      }
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reorderAnimationDuration
      for (view, frame) in targets {
        view.animator().frame = frame
      }
    }
  }
}

@MainActor
final class WorkspaceTabInteractionView: NSView {
  var tabID = WorkspaceTab.ID()
  var title = "Tab"
  var systemImage = "doc"
  var isSelected = false
  var showsCloseButton = false
  var canMoveLeft = false
  var canMoveRight = false
  var canClose = true
  weak var dragCoordinator: WorkspaceTabDragCoordinator?
  var select: (() -> Void)?
  var close: (() -> Void)?
  var duplicate: (() -> Void)?
  var newTab: (() -> Void)?
  var moveLeft: (() -> Void)?
  var moveRight: (() -> Void)?
  var closeOthers: (() -> Void)?
  var moveTab: ((WorkspaceTab.ID) -> Void)?

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let closeButton = NSButton()
  private var isHovered = false
  private(set) var isBeingDragged = false
  private var pointerDownLocation: NSPoint?
  private var startedDragging = false
  private var trackingAreaReference: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.borderWidth = 1

    iconView.imageScaling = .scaleProportionallyDown
    iconView.setAccessibilityElement(false)
    addSubview(iconView)

    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.isSelectable = false
    titleLabel.setAccessibilityElement(false)
    addSubview(titleLabel)

    closeButton.isBordered = false
    closeButton.bezelStyle = .regularSquare
    closeButton.focusRingType = .none
    closeButton.image = NSImage(
      systemSymbolName: "xmark",
      accessibilityDescription: "Close Tab"
    )
    closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
    closeButton.imageScaling = .scaleProportionallyDown
    closeButton.imagePosition = .imageOnly
    closeButton.contentTintColor = .secondaryLabelColor
    closeButton.refusesFirstResponder = true
    closeButton.target = self
    closeButton.action = #selector(closeTab)
    closeButton.toolTip = "Close Tab (⌘W)"
    addSubview(closeButton)

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool { true }

  // The tab strip sits next to the titlebar. Plain NSView instances default to
  // participating in background window dragging, which can consume primary
  // mouse events before this view receives mouseDown in optimized builds.
  override var mouseDownCanMoveWindow: Bool { false }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
    if !closeButton.isHidden {
      let closePoint = closeButton.convert(point, from: self)
      if closeButton.bounds.contains(closePoint) {
        return closeButton
      }
    }
    return self
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func accessibilityPerformPress() -> Bool {
    select?()
    return true
  }

  override func layout() {
    super.layout()
    iconView.frame = NSRect(
      x: 9,
      y: max(0, (bounds.height - 14) / 2),
      width: 14,
      height: 14
    )
    closeButton.frame = NSRect(
      x: max(0, bounds.maxX - 25),
      y: max(0, (bounds.height - 18) / 2),
      width: 18,
      height: 18
    )
    let titleX: CGFloat = 30
    let trailingEdge = closeButton.isHidden ? bounds.maxX - 9 : closeButton.frame.minX - 5
    titleLabel.frame = NSRect(
      x: titleX,
      y: max(0, (bounds.height - 17) / 2),
      width: max(0, trailingEdge - titleX),
      height: 17
    )
  }

  override func updateTrackingAreas() {
    if let trackingAreaReference {
      removeTrackingArea(trackingAreaReference)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingAreaReference = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
    updatePresentation()
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
    updatePresentation()
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    pointerDownLocation = convert(event.locationInWindow, from: nil)
    startedDragging = false
    select?()
  }

  override func mouseDragged(with event: NSEvent) {
    if !startedDragging, let pointerDownLocation {
      let currentLocation = convert(event.locationInWindow, from: nil)
      guard hypot(
        currentLocation.x - pointerDownLocation.x,
        currentLocation.y - pointerDownLocation.y
      ) >= 4 else { return }
      startedDragging = true
      dragCoordinator?.begin(from: self, grabOffsetX: pointerDownLocation.x)
    }
    guard dragCoordinator?.hasActiveDrag == true else { return }
    updateDragLocation(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if dragCoordinator?.hasActiveDrag == true {
      updateDragLocation(with: event)
      dragCoordinator?.finish()
    }
    pointerDownLocation = nil
    startedDragging = false
  }

  override func rightMouseDown(with event: NSEvent) {
    NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53, dragCoordinator?.hasActiveDrag == true {
      dragCoordinator?.cancel()
      pointerDownLocation = nil
      startedDragging = false
    } else if event.keyCode == 36 || event.keyCode == 49 {
      select?()
    } else {
      super.keyDown(with: event)
    }
  }

  func updatePresentation() {
    titleLabel.stringValue = title
    titleLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)
    titleLabel.textColor = .labelColor
    iconView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    iconView.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
    closeButton.isHidden = !(canClose && (showsCloseButton || isHovered))
    closeButton.isEnabled = canClose
    closeButton.menu = makeContextMenu()
    closeButton.setAccessibilityLabel("Close \(title)")
    toolTip = title
    setAccessibilityLabel(title)
    setAccessibilitySelected(isSelected)
    updateColors()
    needsLayout = true
  }

  func setBeingDragged(_ dragging: Bool) {
    guard isBeingDragged != dragging else { return }
    isBeingDragged = dragging
    alphaValue = dragging ? 0.96 : 1
    layer?.zPosition = dragging ? 1 : 0
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = dragging ? 0.28 : 0
    layer?.shadowRadius = dragging ? 4 : 0
    layer?.shadowOffset = CGSize(width: 0, height: -1)
    closeButton.isHidden = dragging || !(canClose && (showsCloseButton || isHovered))
    updateColors()
    needsLayout = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let background: NSColor
      if isBeingDragged {
        background = .selectedContentBackgroundColor.withAlphaComponent(0.18)
      } else if isSelected {
        background = .selectedContentBackgroundColor.withAlphaComponent(0.14)
      } else if isHovered {
        background = .controlAccentColor.withAlphaComponent(0.07)
      } else {
        background = .controlBackgroundColor.withAlphaComponent(0.78)
      }
      let border = isSelected || isBeingDragged
        ? NSColor.controlAccentColor.withAlphaComponent(0.34)
        : NSColor.separatorColor
      layer?.backgroundColor = background.cgColor
      layer?.borderColor = border.cgColor
    }
  }

  func makeContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(menuItem(title: "New Tab", action: #selector(createTab)))
    menu.addItem(menuItem(title: "Duplicate Tab", action: #selector(duplicateTab)))
    menu.addItem(.separator())
    menu.addItem(menuItem(
      title: "Move Tab Left",
      action: #selector(moveTabLeft),
      isEnabled: canMoveLeft
    ))
    menu.addItem(menuItem(
      title: "Move Tab Right",
      action: #selector(moveTabRight),
      isEnabled: canMoveRight
    ))
    menu.addItem(.separator())
    menu.addItem(menuItem(
      title: "Close Tab",
      action: #selector(closeTab),
      isEnabled: canClose
    ))
    menu.addItem(menuItem(
      title: "Close Other Tabs",
      action: #selector(closeOtherTabs),
      isEnabled: canClose
    ))
    return menu
  }

  private func updateDragLocation(with event: NSEvent) {
    guard let container = superview else { return }
    _ = container.autoscroll(with: event)
    let location = container.convert(event.locationInWindow, from: nil)
    dragCoordinator?.update(pointerX: location.x)
  }

  private func menuItem(
    title: String,
    action: Selector,
    isEnabled: Bool = true
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = isEnabled
    return item
  }

  @objc private func createTab() {
    newTab?()
  }

  @objc private func duplicateTab() {
    duplicate?()
  }

  @objc private func moveTabLeft() {
    moveLeft?()
  }

  @objc private func moveTabRight() {
    moveRight?()
  }

  @objc private func closeTab() {
    close?()
  }

  @objc private func closeOtherTabs() {
    closeOthers?()
  }
}

private struct OpenOrgLaunchGuideView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var selectedDestinationID: String?
  @State private var showsWorkspaceOptions = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 14) {
        WorkspaceIconBadge(
          systemImage: "text.bubble.fill",
          tint: .accentColor,
          fill: Color.accentColor.opacity(0.12)
        )
        VStack(alignment: .leading, spacing: 5) {
          Text("Connect an agent")
            .font(.title2.weight(.semibold))
          Text("Choose an agent already installed on this Mac. Celorga will take you straight to a familiar chat box with today's note beside it.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }

      VStack(spacing: 10) {
        agentOption(
          id: AIChatDestinationConfiguration.localCodexID,
          title: "Codex",
          detail: codexDetail,
          systemImage: AIChatRuntime.codex.systemImage,
          isAvailable: store.isLocalCodexInstalled,
          badge: store.codexAccountState.isReady ? "Ready" : (store.isLocalCodexInstalled ? "Sign in" : "Not installed")
        )
        agentOption(
          id: AIChatDestinationConfiguration.localClaudeID,
          title: "Claude Code",
          detail: store.isLocalClaudeCodeInstalled
            ? "Uses your existing local Claude Code installation and sign-in."
            : "Install and sign in to Claude Code first, then reopen this guide.",
          systemImage: AIChatRuntime.claude.systemImage,
          isAvailable: store.isLocalClaudeCodeInstalled,
          badge: store.isLocalClaudeCodeInstalled ? "Installed" : "Not installed"
        )
        agentOption(
          id: AIChatDestinationConfiguration.openClawID,
          title: "OpenClaw",
          detail: "Use an OpenClaw Gateway you already run locally or on your network.",
          systemImage: AIChatRuntime.openClaw.systemImage,
          isAvailable: true,
          badge: "Existing gateway"
        )
      }

      if selectedDestinationID == AIChatDestinationConfiguration.localCodexID,
         store.isLocalCodexInstalled,
         !store.codexAccountState.isReady {
        HStack(spacing: 10) {
          Text(store.codexAccountState.label)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
          Spacer()
          Button {
            Task { await store.beginCodexChatGPTLogin() }
          } label: {
            if store.isCodexSigningIn {
              HStack(spacing: 6) {
                WorkspaceActivityIndicator(size: .small, style: .signal)
                Text("Signing In")
              }
            } else {
              Text("Sign in with ChatGPT")
            }
          }
          .disabled(store.isCodexSigningIn)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      }

      DisclosureGroup("Workspace options", isExpanded: $showsWorkspaceOptions) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Celorga created a plain-text workspace automatically. You can move or rename it later, or choose another folder now.")
            .font(.callout)
            .foregroundStyle(.secondary)
          if let root = store.corpusRoot {
            Text(root.path)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          HStack {
            Button("Use Another Folder…") { store.chooseCorpus() }
            Button("Reveal in Finder") { store.launchGuideRevealWorkspace() }
          }
        }
        .padding(.top, 8)
      }

      HStack {
        Button("Continue without an agent") {
          store.completeLaunchGuide()
        }
        Spacer()
        Button("Continue to Home") {
          store.completeLaunchGuide(destinationID: selectedDestinationID)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canContinue)
      }
    }
    .padding(24)
    .frame(width: 680)
    .onAppear {
      if selectedDestinationID == nil {
        selectedDestinationID = store.selectedAIChatThread?.destinationID
          ?? store.suggestedLaunchGuideDestinationID()
      }
      if store.isLocalCodexInstalled {
        Task { await store.refreshCodexAccount() }
      }
    }
  }

  private var codexDetail: String {
    guard store.isLocalCodexInstalled else {
      return "Install Codex or the ChatGPT desktop app first, then reopen this guide."
    }
    return store.codexAccountState.isReady
      ? "Uses the Codex installation and ChatGPT sign-in already on this Mac."
      : "Sign in with ChatGPT once, then Celorga can start local Codex chats."
  }

  private var canContinue: Bool {
    switch selectedDestinationID {
    case AIChatDestinationConfiguration.localCodexID:
      store.isLocalCodexInstalled && store.codexAccountState.isReady
    case AIChatDestinationConfiguration.localClaudeID:
      store.isLocalClaudeCodeInstalled
    case AIChatDestinationConfiguration.openClawID:
      true
    default:
      false
    }
  }

  private func agentOption(
    id: String,
    title: String,
    detail: String,
    systemImage: String,
    isAvailable: Bool,
    badge: String
  ) -> some View {
    Button {
      selectedDestinationID = id
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: systemImage)
          .font(.title3)
          .foregroundStyle(selectedDestinationID == id ? Color.accentColor : Color.secondary)
          .frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
          Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        Text(badge)
          .font(.caption.weight(.medium))
          .foregroundStyle(selectedDestinationID == id ? Color.accentColor : Color.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            (selectedDestinationID == id ? Color.accentColor : Color.secondary).opacity(0.09),
            in: Capsule()
          )
      }
      .padding(14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isAvailable)
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(
          selectedDestinationID == id ? Color.accentColor.opacity(0.7) : WorkspaceDesign.hairline,
          lineWidth: selectedDestinationID == id ? 1.5 : 1
        )
    }
    .opacity(isAvailable ? 1 : 0.68)
  }
}

private struct EditorSaveConflictSheet: View {
  @Environment(WorkspaceStore.self) private var store
  let conflict: Org2EditorSaveConflict

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("File Changed on Disk", systemImage: "exclamationmark.triangle.fill")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.orange)

      Text("A newer version of this file was written after the editor loaded it. Your unsaved changes are still safe in the editor.")
        .fixedSize(horizontal: false, vertical: true)

      Text(store.relativePath(conflict.file))
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      if conflict.canOverwrite {
        Text("Reloading keeps the newer disk version and discards your editor draft. Overwriting saves your draft and first places the newer disk version in .org2-recovery.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Keep editing to copy anything you need, or reload the latest disk version. Overwrite is unavailable for a partial-file edit because it could replace unrelated changes.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()
        Button("Keep Editing") {
          store.keepEditingAfterSaveConflict()
        }
        Button("Reload from Disk", role: .destructive) {
          Task { await store.reloadAfterSaveConflict() }
        }
        if conflict.canOverwrite {
          Button("Overwrite with My Version", role: .destructive) {
            Task { await store.overwriteAfterSaveConflict() }
          }
        }
      }
    }
    .padding(20)
    .frame(width: 520)
  }
}

private struct WorkspaceMainArea: View {
  @Environment(WorkspaceStore.self) private var store
  let workspaceTabID: WorkspaceTab.ID

  var body: some View {
    if store.corpusRoot == nil {
      CorpusOnboardingView()
    } else {
      HSplitView {
        if !store.isWorkspaceSurfacePaneClosed || !store.hasWorkspaceDetailContent {
          WorkspaceSurfaceCacheView(
            selectedSurface: store.selectedSurface,
            workspaceTabID: workspaceTabID
          )
            .frame(
              minWidth: WorkspaceMainSplitLayout.surfaceMinimumWidth,
              idealWidth: WorkspaceMainSplitLayout.surfaceIdealWidth
            )
        }

        if store.hasWorkspaceDetailContent && !store.isWorkspaceDetailPaneClosed {
          WorkspaceDetailArea()
            .environment(\.workspaceTabID, workspaceTabID)
            .frame(
              minWidth: WorkspaceMainSplitLayout.detailMinimumWidth,
              idealWidth: WorkspaceMainSplitLayout.detailIdealWidth
            )
        }
      }
    }
  }
}

private struct CorpusOnboardingView: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    ScrollView {
      VStack(spacing: 26) {
        VStack(spacing: 12) {
          WorkspaceIconBadge(systemImage: "text.book.closed", tint: .accentColor, fill: Color.accentColor.opacity(0.12))
            .scaleEffect(1.45)
            .padding(.bottom, 4)
          Text("Welcome to \(WorkspaceProductIdentity.displayName)")
            .font(.largeTitle.weight(.semibold))
          Text(WorkspaceProductIdentity.productLine)
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 650)
          Text("Open an existing folder or create a starter workspace. Your files remain ordinary plain text on disk.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 650)
        }

        HStack(alignment: .top, spacing: 18) {
          onboardingCard(
            title: "Open an existing corpus",
            detail: "Choose any folder containing .org files. Celorga will scan it and derive Agenda, search, graph, and workspace views.",
            systemImage: "folder",
            actionTitle: "Choose Folder"
          ) {
            store.chooseCorpus()
          }

          onboardingCard(
            title: "Create a new corpus",
            detail: "Choose or create an empty folder. Celorga will add a Celorga config, inbox, welcome note, daily notes folder, and reviewable output zones.",
            systemImage: "sparkles.rectangle.stack",
            actionTitle: "Create Starter Corpus"
          ) {
            store.createCorpus()
          }
        }
        .frame(maxWidth: 820)

        Button {
          store.createSharedCorpus()
        } label: {
          Label("Create a shared team corpus", systemImage: "person.2")
        }
        .help("Create an identified corpus intended to be mounted by multiple collaborators")

        VStack(spacing: 5) {
          Text("Already use Org Mode?")
            .font(.callout.weight(.semibold))
          Text("No migration is required. Celorga works with your existing .org files as they are.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        if !store.statusText.isEmpty && store.statusText != "No corpus selected" {
          Text(store.statusText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
        }
      }
      .padding(.horizontal, 36)
      .padding(.vertical, 56)
      .frame(maxWidth: .infinity)
    }
    .background(WorkspaceDesign.appBackground)
  }

  private func onboardingCard(
    title: String,
    detail: String,
    systemImage: String,
    actionTitle: String,
    perform: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      WorkspaceIconBadge(systemImage: systemImage, tint: .accentColor, fill: Color.accentColor.opacity(0.10))
      Text(title)
        .font(.title3.weight(.semibold))
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Button(actionTitle, action: perform)
        .buttonStyle(WorkspaceActionButtonStyle())
    }
    .padding(22)
    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(WorkspaceDesign.panelFill)
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(WorkspaceDesign.hairline, lineWidth: 1)
        )
    )
  }
}

enum WorkspaceSurfaceMountIdentity {
  static func accessibilityIdentifier(for surface: WorkspaceSurface) -> String {
    "org.openorg.workspace.surface.\(surface.rawValue)"
  }
}

enum WorkspaceSurfaceNavigationIdentity {
  static func accessibilityIdentifier(for surface: WorkspaceSurface) -> String {
    "org.openorg.workspace.navigation.\(surface.rawValue)"
  }
}

enum CorpusFileRowAccessibilityIdentity {
  static func accessibilityIdentifier(for fileID: CorpusFile.ID) -> String {
    "org.openorg.workspace.file-row.\(fileID)"
  }
}

enum AIChatSidebarThreadAccessibilityIdentity {
  static func accessibilityIdentifier(for threadID: UUID) -> String {
    "org.openorg.workspace.ai-thread-row.\(threadID.uuidString.lowercased())"
  }

  static let settledDisclosure = "org.openorg.workspace.ai-thread-settled-disclosure"
  static let settledShowMore = "org.openorg.workspace.ai-thread-settled-show-more"
}

enum RunsAndReviewPageAccessibilityIdentity {
  static func accessibilityIdentifier(for page: RunsAndReviewPage) -> String {
    "org.openorg.workspace.agent-work-page.\(page.rawValue.lowercased())"
  }
}

@MainActor
private final class WorkspaceAccessibilityPressView: NSView {
  var activate: (() -> Void)?

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
    // Pointer input remains attached to the visible SwiftUI control. This view
    // gives UI automation a stable native press target without covering it.
    nil
  }

  override func accessibilityPerformPress() -> Bool {
    activate?()
    return true
  }
}

private struct WorkspaceAccessibilityPressTarget: NSViewRepresentable {
  let identifier: String
  let label: String
  let isSelected: Bool
  let activate: () -> Void

  func makeNSView(context: Context) -> WorkspaceAccessibilityPressView {
    WorkspaceAccessibilityPressView(frame: .zero)
  }

  func updateNSView(
    _ view: WorkspaceAccessibilityPressView,
    context: Context
  ) {
    view.activate = activate
    view.setAccessibilityIdentifier(identifier)
    view.setAccessibilityLabel(label)
    view.setAccessibilitySelected(isSelected)
  }
}

struct WorkspaceLazyCollection<Content: View>: View {
  let horizontalInset: CGFloat
  let verticalInset: CGFloat
  let rowSpacing: CGFloat
  let pinsSectionHeaders: Bool
  private let content: Content

  init(
    horizontalInset: CGFloat = 8,
    verticalInset: CGFloat = 6,
    rowSpacing: CGFloat = 2,
    pinsSectionHeaders: Bool = true,
    @ViewBuilder content: () -> Content
  ) {
    self.horizontalInset = horizontalInset
    self.verticalInset = verticalInset
    self.rowSpacing = rowSpacing
    self.pinsSectionHeaders = pinsSectionHeaders
    self.content = content()
  }

  var body: some View {
    ScrollView {
      LazyVStack(
        alignment: .leading,
        spacing: rowSpacing,
        pinnedViews: pinsSectionHeaders ? [.sectionHeaders] : []
      ) {
        content
      }
      .padding(.horizontal, horizontalInset)
      .padding(.vertical, verticalInset)
    }
    .background(WorkspaceDesign.surfaceBackground)
  }
}

struct WorkspaceLazySectionHeader<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .textCase(nil)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(WorkspaceDesign.surfaceBackground)
      .accessibilityAddTraits(.isHeader)
  }
}

struct WorkspaceLazyRowModifier<ID: Hashable>: ViewModifier {
  let id: ID

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .id(id)
  }
}

enum WorkspaceCollectionRowAccessibilityIdentity {
  static let runShowMore = "org.openorg.workspace.collection-control.run-show-more"

  static func accessibilityIdentifier<ID>(kind: String, id: ID) -> String {
    "org.openorg.workspace.collection-row.\(kind).\(String(describing: id))"
  }
}

private struct WorkspaceAccessibleCollectionRowModifier: ViewModifier {
  let identifier: String
  let label: String
  let isSelected: Bool
  let open: () -> Void

  func body(content: Content) -> some View {
    content
      .accessibilityElement(children: .contain)
      .accessibilityLabel(label)
      .accessibilityIdentifier(identifier)
      .accessibilityAction(.default) {
        open()
      }
      .accessibilityAction(named: Text("Open")) {
        open()
      }
      .background {
        WorkspaceAccessibilityPressTarget(
          identifier: identifier,
          label: label,
          isSelected: isSelected,
          activate: open
        )
      }
  }
}

extension View {
  func workspaceLazyRow<ID: Hashable>(id: ID) -> some View {
    modifier(WorkspaceLazyRowModifier(id: id))
  }

  func workspaceAccessibleCollectionRow<ID>(
    kind: String,
    id: ID,
    label: String,
    isSelected: Bool = false,
    open: @escaping () -> Void
  ) -> some View {
    modifier(WorkspaceAccessibleCollectionRowModifier(
      identifier: WorkspaceCollectionRowAccessibilityIdentity.accessibilityIdentifier(
        kind: kind,
        id: id
      ),
      label: label,
      isSelected: isSelected,
      open: open
    ))
  }
}

@MainActor
private final class WorkspaceSurfaceNavigationAccessibilityView: NSView {
  var activate: (() -> Void)?

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
    // Pointer input belongs to the visible SwiftUI Button. This native view is
    // a stable accessibility publication target and must not cover its label.
    nil
  }

  override func accessibilityPerformPress() -> Bool {
    activate?()
    return true
  }
}

private struct WorkspaceSurfaceNavigationAccessibilityTarget: NSViewRepresentable {
  let surface: WorkspaceSurface
  let isSelected: Bool
  let activate: () -> Void

  func makeNSView(context: Context) -> WorkspaceSurfaceNavigationAccessibilityView {
    WorkspaceSurfaceNavigationAccessibilityView(frame: .zero)
  }

  func updateNSView(
    _ view: WorkspaceSurfaceNavigationAccessibilityView,
    context: Context
  ) {
    view.activate = activate
    view.setAccessibilityLabel(surface.title)
    view.setAccessibilityIdentifier(
      WorkspaceSurfaceNavigationIdentity.accessibilityIdentifier(for: surface)
    )
    view.setAccessibilitySelected(isSelected)
  }
}

private struct WorkspaceSurfaceCacheView: NSViewRepresentable {
  @Environment(WorkspaceStore.self) private var store
  let selectedSurface: WorkspaceSurface
  let workspaceTabID: WorkspaceTab.ID

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    context.coordinator.install(
      in: view,
      surface: selectedSurface,
      workspaceTabID: workspaceTabID,
      store: store
    )
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.show(
      surface: selectedSurface,
      workspaceTabID: workspaceTabID,
      in: view,
      store: store
    )
  }

  @MainActor
  final class Coordinator {
    private var host: NSHostingView<AnyView>?
    private var activeSurface: WorkspaceSurface?
    private var activeWorkspaceTabID: WorkspaceTab.ID?

    func install(
      in container: NSView,
      surface: WorkspaceSurface,
      workspaceTabID: WorkspaceTab.ID,
      store: WorkspaceStore
    ) {
      guard host == nil else { return }
      let host = makeHost(
        surface: surface,
        workspaceTabID: workspaceTabID,
        store: store
      )
      container.addSubview(host)
      NSLayoutConstraint.activate([
        host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        host.topAnchor.constraint(equalTo: container.topAnchor),
        host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
      self.host = host
      activeSurface = surface
      activeWorkspaceTabID = workspaceTabID
    }

    func show(
      surface: WorkspaceSurface,
      workspaceTabID: WorkspaceTab.ID,
      in container: NSView,
      store: WorkspaceStore
    ) {
      guard let host else {
        install(
          in: container,
          surface: surface,
          workspaceTabID: workspaceTabID,
          store: store
        )
        return
      }
      guard host.superview === container else {
        assertionFailure("The workspace surface host must remain attached to its original container")
        return
      }
      guard activeSurface != surface || activeWorkspaceTabID != workspaceTabID else { return }

      resignFirstResponderIfContained(in: host)
      // Replacing the only host's explicitly identified root destroys the
      // outgoing SwiftUI graph. Inactive surfaces therefore receive normal
      // onDisappear/task cancellation without remaining hidden observers,
      // while the NSHostingView itself never leaves the window hierarchy.
      host.rootView = Self.rootView(
        surface: surface,
        workspaceTabID: workspaceTabID,
        store: store
      )
      host.setAccessibilityIdentifier(
        WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: surface)
      )
      activeSurface = surface
      activeWorkspaceTabID = workspaceTabID
    }

    private func makeHost(
      surface: WorkspaceSurface,
      workspaceTabID: WorkspaceTab.ID,
      store: WorkspaceStore
    ) -> NSHostingView<AnyView> {
      let host = NSHostingView(rootView: Self.rootView(
        surface: surface,
        workspaceTabID: workspaceTabID,
        store: store
      ))
      // The host is fully constrained to its container. Asking SwiftUI for an
      // intrinsic, minimum, and maximum size as well makes AppKit measure the
      // entire active surface during every constraint pass.
      host.sizingOptions = []
      host.translatesAutoresizingMaskIntoConstraints = false
      host.setAccessibilityIdentifier(
        WorkspaceSurfaceMountIdentity.accessibilityIdentifier(for: surface)
      )
      return host
    }

    private static func rootView(
      surface: WorkspaceSurface,
      workspaceTabID: WorkspaceTab.ID,
      store: WorkspaceStore
    ) -> AnyView {
      AnyView(
        WorkspaceSurfaceView(surface: surface)
          .environment(store)
          .environment(\.workspaceTabID, workspaceTabID)
          .environment(\.openOrgFileReference) { reference in
            store.openChatFileReference(reference)
          }
          .environment(\.openWorkspaceWebLink, store.openWorkspaceWebLinkAction)
          .workspaceThemed()
          .id("\(workspaceTabID.uuidString):\(surface.rawValue)")
      )
    }

    private func resignFirstResponderIfContained(in host: NSView) {
      guard let window = host.window,
            let firstResponder = window.firstResponder,
            Self.responder(firstResponder, isContainedIn: host)
      else { return }
      _ = window.makeFirstResponder(nil)
    }

    private static func responder(
      _ responder: NSResponder,
      isContainedIn host: NSView
    ) -> Bool {
      if let responderView = responder as? NSView,
         responderView === host || responderView.isDescendant(of: host) {
        return true
      }
      if let fieldEditor = responder as? NSTextView,
         let delegateView = fieldEditor.delegate as? NSView,
         delegateView === host || delegateView.isDescendant(of: host) {
        return true
      }
      var ancestor = responder.nextResponder
      while let current = ancestor {
        if let view = current as? NSView,
           view === host || view.isDescendant(of: host) {
          return true
        }
        ancestor = current.nextResponder
      }
      return false
    }
  }
}

struct WorkspaceSurfaceView: View {
  @Environment(WorkspaceStore.self) private var store
  let surface: WorkspaceSurface

  var body: some View {
    GeometryReader { proxy in
      Group {
        switch surface {
        case .home:
          HomeView()
        case .agenda:
          AgendaView()
        case .savedViews:
          SavedViewsView()
        case .approvals:
          RunsAndReviewView()
        case .files:
          FilesView()
        case .canvases:
          CanvasesView()
        case .search:
          SearchView()
        case .meetings:
          MeetingsView()
        case .sources:
          SourcesView()
        case .aiChat:
          AIChatView()
        case .externalThreads:
          ExternalThreadsView()
        case .skills:
          SkillsView()
        case .activity:
          WorkspaceActivityView()
        }
      }
      // Some surface controls and rows have a useful minimum content width.
      // When the split pane becomes narrower, pin that overflow to the leading
      // edge so navigation and primary actions stay visible; any unavoidable
      // clipping then happens only at the trailing edge.
      .frame(
        width: max(0, proxy.size.width),
        height: max(0, proxy.size.height),
        alignment: .topLeading
      )
      .clipped()
    }
    .background(WorkspaceDesign.surfaceBackground)
    .foregroundStyle(WorkspaceDesign.primaryText)
    .simultaneousGesture(
      TapGesture().onEnded {
        store.activateWorkspacePane(.surface)
      }
    )
  }
}

private struct HomeView: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    AIChatView(presentation: .homePane, surface: .home)
      .onAppear {
        if store.selectedSurface == .home {
          store.ensureHomeDetailReady()
        }
      }
  }
}

private struct SkillsView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isCreatingSkill = false
  @State private var skillPendingRemoval: WorkspaceSkillItem?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Skills")
            .font(.title2.weight(.semibold))
          Text("Agent procedures available to this workspace")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 12)
        Button {
          store.refreshCorpusAgentSkills(force: true)
        } label: {
          Label("Refresh Skills", systemImage: "arrow.clockwise")
        }
        .labelStyle(.iconOnly)
        .help("Refresh skills")
        Button {
          isCreatingSkill = true
        } label: {
          Label("New Skill", systemImage: "plus")
        }
        .help("Create a workspace skill")
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "info.circle")
          .foregroundStyle(.secondary)
        Text("Operating guidance is built into Celorga and available in every AI chat. This list shows additional procedures authored for this workspace.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)

      Divider()

      if store.workspaceSkills.isEmpty {
        ContentUnavailableView {
          Label("No Workspace Skills", systemImage: "wand.and.stars")
        } description: {
          Text("Create a skill to give agents a reusable workspace procedure.")
        } actions: {
          Button("New Skill") { isCreatingSkill = true }
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(store.workspaceSkills) { skill in
              WorkspaceSkillRow(
                skill: skill,
                isSelected: store.selectedWorkspaceSkillID == skill.id,
                open: { store.selectWorkspaceSkill(skill) },
                remove: { skillPendingRemoval = skill }
              )
            }
          }
          .padding(12)
        }
      }
    }
    .task {
      if store.workspaceSkills.isEmpty {
        store.refreshCorpusAgentSkills()
      }
    }
    .sheet(isPresented: $isCreatingSkill) {
      NewWorkspaceSkillSheet(isPresented: $isCreatingSkill)
        .environment(store)
    }
    .confirmationDialog(
      "Move /\(skillPendingRemoval?.name ?? "skill") to Trash?",
      isPresented: Binding(
        get: { skillPendingRemoval != nil },
        set: { if !$0 { skillPendingRemoval = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let skill = skillPendingRemoval {
        Button("Move to Trash", role: .destructive) {
          Task { await store.moveWorkspaceSkillToTrash(skill) }
          skillPendingRemoval = nil
        }
      }
      Button("Cancel", role: .cancel) { skillPendingRemoval = nil }
    } message: {
      Text("The skill folder can be recovered from the Trash.")
    }
  }
}

private struct WorkspaceSkillRow: View {
  let skill: WorkspaceSkillItem
  let isSelected: Bool
  let open: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: skill.validationMessage == nil ? "wand.and.stars" : "exclamationmark.triangle")
        .font(.title3)
        .foregroundStyle(skill.validationMessage == nil ? Color.accentColor : Color.orange)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 7) {
          Text("/\(skill.name)")
            .font(.headline.monospaced())
          Text("Workspace")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(WorkspaceDesign.panelFill, in: Capsule())
          if !skill.isUserInvocable {
            Text("Agent only")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          }
        }
        Text(skill.validationMessage ?? skill.description)
          .font(.callout)
          .foregroundStyle(skill.validationMessage == nil ? Color.secondary : Color.orange)
          .lineLimit(3)
        Text(skill.sourcePath)
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .foregroundStyle(.tertiary)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .background(
      isSelected ? Color.accentColor.opacity(0.11) : WorkspaceDesign.panelFill,
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(isSelected ? Color.accentColor.opacity(0.65) : WorkspaceDesign.hairline, lineWidth: 1)
    }
    .contextMenu {
      Button("Edit Skill", action: open)
      Button("Reveal in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.sourcePath)])
      }
      Divider()
      Button("Move to Trash", role: .destructive, action: remove)
    }
  }
}

private struct NewWorkspaceSkillSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Binding var isPresented: Bool
  @State private var name = ""
  @State private var summary = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Workspace Skill")
        .font(.title2.weight(.semibold))
      Text("Skills are plain SKILL.md files under .agents/skills. The generated file opens in the normal editor so you can finish its procedure.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Form {
        TextField("Name", text: $name, prompt: Text("weekly-review"))
        TextField("When to use it", text: $summary, axis: .vertical)
          .lineLimit(2...4)
      }
      HStack {
        Spacer()
        Button("Cancel") { isPresented = false }
        Button("Create") {
          if store.createWorkspaceSkill(name: name, description: summary) {
            isPresented = false
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
      }
    }
    .padding(20)
    .frame(width: 480)
  }
}

private struct DailyNoteDatePickerSheet: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Open Daily Note")
          .font(.title2.weight(.semibold))
        Text(store.automaticDailyNoteCreationDisabled
          ? "Choose a date to open its note. If it does not exist, you can create it explicitly."
          : "Choose a date to open or create its note in this workspace's daily folder.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      DatePicker(
        "Daily note date",
        selection: $store.dailyNotePickerDate,
        displayedComponents: .date
      )
      .datePickerStyle(.graphical)
      .labelsHidden()
      .accessibilityLabel("Daily note date")

      HStack {
        Spacer()
        Button("Cancel") {
          store.isDailyNoteDatePickerPresented = false
        }
        .keyboardShortcut(.cancelAction)
        Button("Open") {
          store.openDailyNoteFromDatePicker()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 390)
  }
}

private struct ExternalThreadsView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var searchDraft = ""
  @State private var pendingSearchUpdate: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      HeaderBar(
        title: "External Threads",
        subtitle: "Read-only tasks from Codex and other agent harnesses",
        surface: .externalThreads
      ) {
        if store.isRefreshingExternalThreads {
          WorkspaceActivityIndicator(size: .small)
        }
        Button {
          Task { await store.refreshExternalThreads() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isRefreshingExternalThreads)
      }

      HSplitView {
        externalThreadList
          .frame(minWidth: 250, idealWidth: 310)
        externalThreadDetail
          .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear { searchDraft = store.externalThreadSearchQuery }
    .onChange(of: store.externalThreadSearchQuery) {
      if searchDraft != store.externalThreadSearchQuery {
        searchDraft = store.externalThreadSearchQuery
      }
    }
    .onDisappear { pendingSearchUpdate?.cancel() }
    .task {
      if store.externalThreads.isEmpty {
        await store.refreshExternalThreads()
      }
    }
  }

  private var externalThreadList: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Filter external threads", text: $searchDraft)
          .textFieldStyle(.plain)
          .onChange(of: searchDraft) { scheduleSearchUpdate() }
          .onSubmit { applySearchImmediately() }
        if !searchDraft.isEmpty {
          Button {
            searchDraft = ""
            pendingSearchUpdate?.cancel()
            pendingSearchUpdate = Task { @MainActor in
              await store.updateExternalThreadSearchQuery("")
            }
          } label: {
            Label("Clear", systemImage: "xmark.circle.fill")
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(WorkspaceDesign.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .padding(12)

      if store.filteredExternalThreads.isEmpty {
        Spacer()
        if store.isRefreshingExternalThreads {
          WorkspaceLoadingStateView("Loading external threads")
        } else {
          ContentUnavailableView(
            store.externalThreadSearchQuery.isEmpty ? "No External Threads" : "No Matching Threads",
            systemImage: "rectangle.stack.badge.person.crop",
            description: Text(store.externalThreadError ?? "Native Codex tasks will appear here without being modified.")
          )
        }
        Spacer()
      } else {
        WorkspaceLazyCollection {
          ForEach(store.filteredExternalThreads) { thread in
            Button {
              Task { await store.selectExternalThread(thread.id) }
            } label: {
              ExternalThreadRow(
                thread: thread,
                isSelected: store.selectedExternalThreadID == thread.id
              )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
              WorkspaceCollectionRowAccessibilityIdentity.accessibilityIdentifier(
                kind: "external-thread",
                id: thread.id
              )
            )
            .workspaceLazyRow(id: thread.id)
          }
        }
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
  }

  @ViewBuilder
  private var externalThreadDetail: some View {
    if store.isLoadingExternalThread {
      VStack(spacing: 12) {
        WorkspaceActivityIndicator(size: .regular)
        Text("Loading the full read-only transcript…")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let detail = store.selectedExternalThreadDetail {
      VStack(spacing: 0) {
        HStack(alignment: .top, spacing: 12) {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
              Label(detail.thread.harness.title, systemImage: detail.thread.harness.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Text("READ ONLY")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(WorkspaceDesign.controlFill, in: Capsule())
            }
            Text(detail.thread.title)
              .font(.title3.weight(.semibold))
              .textSelection(.enabled)
            if let workspacePath = detail.thread.workspacePath {
              Text(workspacePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
          Spacer(minLength: 8)
          Button {
            Task {
              do {
                _ = try await store.saveExternalThreadToOrg2(detail)
              } catch {
                store.reportExternalThreadActionError(error)
              }
            }
          } label: {
            Label("Save to Celorga", systemImage: "square.and.arrow.down")
          }
          Button {
            Task {
              do {
                _ = try await store.continueExternalThreadInOrg2(detail)
              } catch {
                store.reportExternalThreadActionError(error)
              }
            }
          } label: {
            Label("Fork into Celorga", systemImage: "arrow.triangle.branch")
          }
          .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(14)
        .background(WorkspaceDesign.barBackground)
        .overlay(alignment: .bottom) { Divider() }

        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if detail.messages.isEmpty {
              ContentUnavailableView(
                "No Text Messages",
                systemImage: "text.bubble",
                description: Text("This task contains no user or assistant text to display.")
              )
              .frame(maxWidth: .infinity, minHeight: 260)
            } else {
              ForEach(detail.messages) { message in
                ExternalThreadMessageCard(message: message, harness: detail.thread.harness)
              }
            }
          }
          .padding(16)
        }
      }
    } else {
      ContentUnavailableView(
        "Select an External Thread",
        systemImage: "rectangle.stack.badge.person.crop",
        description: Text(store.externalThreadError ?? "Open a native agent task without resuming or changing it.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func scheduleSearchUpdate() {
    pendingSearchUpdate?.cancel()
    let nextQuery = searchDraft
    guard nextQuery != store.externalThreadSearchQuery else { return }
    store.externalThreadSearchQuery = nextQuery
    pendingSearchUpdate = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
      guard !Task.isCancelled else { return }
      await store.refreshExternalThreads()
    }
  }

  private func applySearchImmediately() {
    pendingSearchUpdate?.cancel()
    if store.externalThreadSearchQuery != searchDraft {
      let nextQuery = searchDraft
      pendingSearchUpdate = Task { @MainActor in
        await store.updateExternalThreadSearchQuery(nextQuery)
      }
    } else {
      pendingSearchUpdate = nil
    }
  }
}

private struct ExternalThreadRow: View {
  let thread: ExternalThreadSummary
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      WorkspaceIconBadge(
        systemImage: thread.harness.systemImage,
        tint: isSelected ? .accentColor : WorkspaceDesign.secondaryText,
        fill: isSelected ? Color.accentColor.opacity(0.12) : WorkspaceDesign.controlFill
      )
      VStack(alignment: .leading, spacing: 4) {
        Text(thread.title)
          .font(.body.weight(.medium))
          .lineLimit(2)
        if let preview = thread.preview, preview != thread.title {
          Text(preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack(spacing: 5) {
          Text(thread.harness.title)
          Text("·")
          Text(thread.updatedAt, style: .relative)
          if let source = thread.source {
            Text("·")
            Text(source)
          }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
    .workspaceSelectableRow(isSelected: isSelected)
  }
}

private struct ExternalThreadMessageCard: View {
  let message: ExternalThreadMessage
  let harness: ExternalThreadHarness
  @State private var didCopy = false
  @State private var copyFeedbackTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Image(systemName: message.role == .user ? "person.fill" : harness.systemImage)
          .foregroundStyle(message.role == .user ? Color.accentColor : WorkspaceDesign.structuralAccent)
        Text(message.role == .user ? "You" : harness.title)
          .font(.caption.weight(.semibold))
        Spacer(minLength: 0)
        Text(AIChatMessageTimestampPresentation.displayText(for: message.createdAt))
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
          .help(AIChatMessageTimestampPresentation.fullText(for: message.createdAt))
          .accessibilityLabel(
            "Sent \(AIChatMessageTimestampPresentation.fullText(for: message.createdAt))"
          )
        Button {
          copyFeedbackTask?.cancel()
          didCopy = AIChatMessageClipboard.write(message.content)
          if didCopy {
            copyFeedbackTask = Task { @MainActor in
              do { try await Task.sleep(for: .seconds(2)) } catch { return }
              didCopy = false
            }
          }
        } label: {
          Label(didCopy ? "Message Copied" : "Copy Message", systemImage: didCopy ? "checkmark" : "doc.on.doc")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(didCopy ? Color.green : Color.secondary)
        .help(didCopy ? "Copied" : "Copy message")
        .onDisappear {
          copyFeedbackTask?.cancel()
          copyFeedbackTask = nil
          didCopy = false
        }
      }
      Text(message.content)
        .font(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(13)
    .background(
      message.role == .user ? Color.accentColor.opacity(0.08) : WorkspaceDesign.panelFill,
      in: RoundedRectangle(cornerRadius: 13, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(WorkspaceDesign.hairline, lineWidth: 1)
    }
  }
}

private struct WorkspaceDetailArea: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    DetailView()
      .environment(\.orgRoamLinkResolver, store.orgRoamLinkResolver)
      .simultaneousGesture(
        TapGesture().onEnded {
          store.activateWorkspacePane(.detail)
        }
      )
  }
}

private struct SidebarView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(WorkspaceStore.self) private var store
  @State private var showsCommandShortcuts = false
  @State private var isChatThreadListExpanded = true
  @State private var showsSettledChatThreads = false
  @State private var settledChatThreadDisplayLimit = AIChatSettledThreadPagination.pageSize
  @State private var chatRenameRequest: AIChatThreadRenameRequest?
  @State private var chatRenameDraft = ""
  @State private var showsFileTree = false
  @State private var expandedSidebarFileDirectoryIDs: Set<String> = []
  @State private var projectSheet: WorkspaceProjectSheet?
  @AppStorage(SidebarSectionCollapseState.defaultsKey) private var collapsedSidebarSectionsStorage = ""

  private let autoSettleChatTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
  private let chatSurface = WorkspaceSurface.aiChat

  private var chatThreads: [AIChatSidebarThreadSummary] { store.sidebarAIChatThreadSummaries }
  private var settledThreads: [AIChatSidebarThreadSummary] { store.sidebarSettledAIChatThreadSummaries }
  private var runningChatThreads: [AIChatSidebarThreadSummary] {
    chatThreads.filter { store.isAIChatThreadRunning($0.id) }
  }
  private var recentChatThreads: [AIChatSidebarThreadSummary] {
    chatThreads.filter { !store.isAIChatThreadRunning($0.id) }
  }

  private func isSidebarSectionExpanded(_ section: SidebarSectionID) -> Bool {
    !SidebarSectionCollapseState(storage: collapsedSidebarSectionsStorage).isCollapsed(section)
  }

  var body: some View {
    let pinnedCorpusFiles = store.pinnedCorpusFiles
    VStack(spacing: 0) {
      SidebarHeader(showsCommandShortcuts: showsCommandShortcuts)

      List {
        let sidebarSurfaces = WorkspaceSurface.sidebarCases(
          experimentalFeaturesEnabled: store.experimentalFeaturesEnabled
        )
        Section {
          if isSidebarSectionExpanded(.workspace) {
            ForEach(sidebarSurfaces.filter { !WorkspaceSurface.sidebarTrailingCases.contains($0) }) { surface in
              sidebarSurfaceButton(surface)
            }

            Button {
              store.openReviewQueue()
            } label: {
              SidebarAgentWorkPageRow(
                title: "Review Queue",
                systemImage: "checkmark.seal",
                shortcut: "⌘⇧R",
                showsCommandShortcut: showsCommandShortcuts,
                notificationCount: store.approvalItems.count
              )
              .modifier(ReadableListSelectionModifier(
                isSelected: store.selectedSurface == .approvals && store.runsAndReviewPage == .review,
                verticalPadding: 4
              ))
            }
            .buttonStyle(.plain)
            .help("Review Queue (⌘⇧R)")

            Button {
              store.openAutomations()
            } label: {
              SidebarAgentWorkPageRow(
                title: "Automations",
                systemImage: "clock.arrow.circlepath",
                shortcut: "⌥⌘A",
                showsCommandShortcut: showsCommandShortcuts,
                notificationCount: 0
              )
              .modifier(ReadableListSelectionModifier(
                isSelected: store.selectedSurface == .approvals && store.runsAndReviewPage == .workflows,
                verticalPadding: 4
              ))
            }
            .buttonStyle(.plain)
            .help("Automations (⌥⌘A)")

            ForEach(sidebarSurfaces.filter { WorkspaceSurface.sidebarTrailingCases.contains($0) }) { surface in
              sidebarSurfaceButton(surface)
            }
          }
        } header: {
          SidebarSectionLabel("Workspace", section: .workspace)
        }

        if !pinnedCorpusFiles.isEmpty {
          Section {
            if isSidebarSectionExpanded(.pinned) {
              ForEach(pinnedCorpusFiles) { file in
                Button {
                  store.openSidebarFile(file)
                } label: {
                  SidebarPinnedFileRow(
                    file: file,
                    isSelected: store.selectedLocation?.file == file.path
                  )
                }
                .buttonStyle(.plain)
                .contextMenu {
                  CorpusFileContextMenu(file: file)
                }
                .help(file.relativePath)
              }
            }
          } header: {
            SidebarSectionLabel("Pinned", section: .pinned)
          }
        }

        Section {
          if isSidebarSectionExpanded(.daily) {
            ForEach(DailyNoteTarget.allCases) { target in
              Button {
                store.openDailyNoteFromSidebar(target)
              } label: {
                HStack(spacing: 8) {
                  Label(target.title, systemImage: target == .today ? "sun.max" : "calendar")
                    .font(.callout.weight(.medium))
                  Spacer(minLength: 0)
                  if showsCommandShortcuts {
                    KeyboardShortcutBadge(text: target.commandShortcutTitle)
                      .transition(.opacity.combined(with: .move(edge: .trailing)))
                  }
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .help("\(target.title) daily note (\(target.commandShortcutTitle))")
            }
            Button {
              store.presentDailyNoteDatePicker()
            } label: {
              HStack(spacing: 8) {
                Label("Choose Date…", systemImage: "calendar.badge.plus")
                  .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                if showsCommandShortcuts {
                  KeyboardShortcutBadge(text: DailyNoteTarget.datePickerCommandShortcutTitle)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open a daily note for any date (\(DailyNoteTarget.datePickerCommandShortcutTitle))")
          }
        } header: {
          SidebarSectionLabel("Daily", section: .daily)
        }

        Section {
          if isSidebarSectionExpanded(.files) {
            HStack(spacing: 6) {
              Button {
                showsFileTree.toggle()
              } label: {
                HStack(spacing: 7) {
                  Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(showsFileTree ? 90 : 0))
                    .frame(width: 12)
                  Image(systemName: "folder")
                    .foregroundStyle(WorkspaceDesign.structuralAccent)
                  Text("Files")
                    .font(.callout.weight(.medium))
                  Spacer(minLength: 0)
                  if showsCommandShortcuts {
                    KeyboardShortcutBadge(text: NewCorpusFileCommand.shortcutTitle)
                      .transition(.opacity.combined(with: .move(edge: .trailing)))
                  } else {
                    Text("\(store.corpusFiles.count)")
                      .font(.caption2.monospacedDigit())
                      .foregroundStyle(.tertiary)
                  }
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .help(showsFileTree ? "Hide corpus files" : "Browse the corpus as a collapsible file tree")

              Button {
                store.presentNewCorpusFileSheet()
              } label: {
                Image(systemName: "plus")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .frame(width: 18, height: 18)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(store.corpusRoot == nil)
              .help("New File… (\(NewCorpusFileCommand.shortcutTitle))")
              .accessibilityLabel("New File")
            }

            if showsFileTree {
              if store.corpusFileTree.isEmpty {
                Text(store.isScanningCorpusFiles ? "Scanning files…" : "No files")
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .padding(.leading, 18)
                  .padding(.vertical, 3)
              } else {
                ForEach(visibleSidebarFileRows) { row in
                  SidebarCorpusFileTreeRow(
                    row: row,
                    isExpanded: expandedSidebarFileDirectoryIDs.contains(row.id),
                    toggleDirectory: { toggleSidebarFileDirectory(row.id) }
                  )
                  .id("sidebar-file:\(row.id)")
                }
              }
            }
          }
        } header: {
          SidebarSectionLabel("Files", section: .files)
        }

        WorkspaceProjectSidebar(presentedSheet: $projectSheet) { summary in chatThreadRow(summary) }

        Section {
          if isSidebarSectionExpanded(.chat) {
            chatSurfaceRow
              .listRowBackground(Color.clear)

            if isChatThreadListExpanded {
              if chatThreads.isEmpty
                  && settledThreads.isEmpty {
                Text("No chat threads")
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .padding(.leading, AIChatSidebarThreadLayout.leadingPadding)
                  .padding(.vertical, 3)
                  .listRowBackground(Color.clear)
              } else {
                if !runningChatThreads.isEmpty {
                  SidebarChatThreadGroupLabel(title: "Running", count: runningChatThreads.count)
                }

                ForEach(runningChatThreads) { summary in
                  chatThreadRow(summary)
                    .id(AIChatSidebarThreadRowIdentity(summary: summary))
                    .listRowBackground(Color.clear)
                }

                if !runningChatThreads.isEmpty, !recentChatThreads.isEmpty {
                  SidebarChatThreadGroupLabel(title: "Recent", count: recentChatThreads.count)
                }

                if store.actionableAutomationAIChatThreadCount > 0 {
                  SidebarSettleAutomationThreadsRow(
                    count: store.actionableAutomationAIChatThreadCount
                  ) {
                    withAnimation(WorkspaceMotion.disclosure) {
                      _ = store.markAllAutomationAIChatThreadsReadAndSettled()
                    }
                  }
                  .listRowBackground(Color.clear)
                }

                ForEach(recentChatThreads) { summary in
                  chatThreadRow(summary)
                    .id(AIChatSidebarThreadRowIdentity(summary: summary))
                    .listRowBackground(Color.clear)
                }

                if !settledThreads.isEmpty {
                  settledChatThreadDisclosureRow
                    .listRowBackground(Color.clear)
                }

                if showsSettledChatThreads {
                  ForEach(Array(
                    settledThreads
                      .prefix(settledChatThreadDisplayLimit)
                  )) { summary in
                    chatThreadRow(summary)
                      .opacity(0.68)
                      .id(AIChatSidebarThreadRowIdentity(summary: summary))
                      .listRowBackground(Color.clear)
                  }

                  if settledChatThreadDisplayLimit
                      < settledThreads.count {
                    settledChatThreadShowMoreRow
                      .listRowBackground(Color.clear)
                  }
                }
              }
            }
          }
        } header: {
          SidebarSectionLabel("Chat", section: .chat)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)

      SidebarCorpusSwitcher()
    }
    // A Section inside List distributes presentation modifiers to its rows.
    // Keep one stable sheet host for all project actions outside that list.
    .sheet(item: $projectSheet) { sheet in sheet.content }
    .commandShortcutRevealMonitor($showsCommandShortcuts)
    .animation(WorkspaceMotion.quick, value: showsCommandShortcuts)
    .background { WorkspaceAtmosphere() }
    .onAppear {
      store.autoSettleAIChatThreads()
    }
    .onReceive(autoSettleChatTimer) { now in
      guard isChatThreadListExpanded else { return }
      store.autoSettleAIChatThreads(now: now)
    }
    .onChange(of: isChatThreadListExpanded) {
      if isChatThreadListExpanded {
        store.autoSettleAIChatThreads()
      } else {
        showsSettledChatThreads = false
        settledChatThreadDisplayLimit = AIChatSettledThreadPagination.pageSize
        chatRenameRequest = nil
      }
    }
    .onChange(of: store.corpusRoot?.path) {
      showsFileTree = false
      expandedSidebarFileDirectoryIDs = []
    }
    .onChange(of: settledThreads.count) {
      guard isChatThreadListExpanded else { return }
      settledChatThreadDisplayLimit = AIChatSettledThreadPagination.clampedLimit(
        currentLimit: settledChatThreadDisplayLimit,
        totalCount: settledThreads.count
      )
      let nextValue = AIChatSettledThreadDisclosure.updated(
        isExpanded: showsSettledChatThreads,
        settledThreadCount: settledThreads.count
      )
      guard nextValue != showsSettledChatThreads else { return }
      withAnimation(WorkspaceMotion.disclosure) { showsSettledChatThreads = nextValue }
    }
    .alert(
      "Rename Thread",
      isPresented: chatRenameAlertIsPresented,
      presenting: chatRenameRequest
    ) { request in
      TextField("Thread name", text: $chatRenameDraft)
      Button("Cancel", role: .cancel) {
        chatRenameRequest = nil
      }
      Button("Rename") {
        let threadID = request.threadID
        let title = chatRenameDraft
        chatRenameRequest = nil
        store.renameAIChatThread(threadID, title: title)
      }
    }
  }

  private var chatSurfaceRow: some View {
    HStack(spacing: 6) {
      Button {
        store.makeSurfacePrimary(chatSurface)
      } label: {
        HStack(spacing: 6) {
          Label(chatSurface.title, systemImage: chatSurface.systemImage)
            .font(.callout.weight(.medium))
          if store.aiChatUnreadMessageCount > 0 {
            AIChatUnreadBadge(count: store.aiChatUnreadMessageCount, compact: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(
        chatSurface.commandShortcutTitle.isEmpty
          ? chatSurface.title
          : "\(chatSurface.title) (\(chatSurface.commandShortcutTitle))"
      )

      Button {
        store.createAIChatThread()
        store.makeSurfacePrimary(.aiChat)
        isChatThreadListExpanded = true
      } label: {
        Image(systemName: "plus")
          .font(.caption.weight(.semibold))
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("New chat thread")

      Button {
        withAnimation(WorkspaceMotion.disclosure) {
          isChatThreadListExpanded.toggle()
        }
      } label: {
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .rotationEffect(.degrees(isChatThreadListExpanded ? 0 : -90))
          .frame(width: 16, height: 18)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(isChatThreadListExpanded ? "Hide chat threads" : "Show chat threads")

      if showsCommandShortcuts && !chatSurface.commandShortcutTitle.isEmpty {
        KeyboardShortcutBadge(text: chatSurface.commandShortcutTitle)
          .transition(.opacity.combined(with: .move(edge: .trailing)))
      }
    }
    .contextMenu {
      Button {
        store.markAllAutomationAIChatThreadsReadAndSettled()
      } label: {
        Label(AIChatAutomationThreadsAction.title, systemImage: AIChatAutomationThreadsAction.systemImage)
      }
    }
  }

  private func chatThreadRow(_ summary: AIChatSidebarThreadSummary) -> some View {
    AIChatSidebarThreadRow(
      summary: summary,
      isSending: store.isAIChatThreadRunning(summary.id),
      select: {
        store.makeSurfacePrimary(.aiChat)
        store.selectAIChatThread(summary.id)
      },
      rename: { beginRenamingChatThread(threadID: $0) },
      fork: {
        Task { @MainActor in
          _ = await store.forkAIChatThread(summary.id)
        }
      },
      togglePin: { store.toggleAIChatThreadPin(summary.id) },
      settle: {
        withAnimation(reduceMotion ? nil : WorkspaceMotion.action) {
          store.settleAIChatThread(summary.id)
        }
      },
      reopen: {
        withAnimation(reduceMotion ? nil : WorkspaceMotion.action) {
          store.reopenAIChatThread(summary.id)
        }
      }
    )
  }

  private var settledChatThreadDisclosureRow: some View {
    HStack(spacing: 4) {
      Button {
        toggleSettledChatThreads()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "checkmark.circle")
          Text("Settled")
          Text("\(settledThreads.count)")
            .foregroundStyle(.tertiary)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(showsSettledChatThreads ? 0 : -90))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
      }
      .buttonStyle(.plain)
      .help(showsSettledChatThreads ? "Hide settled chat threads" : "Show settled chat threads")
      .accessibilityIdentifier(
        AIChatSidebarThreadAccessibilityIdentity.settledDisclosure
      )
      .background {
        WorkspaceAccessibilityPressTarget(
          identifier: AIChatSidebarThreadAccessibilityIdentity.settledDisclosure,
          label: showsSettledChatThreads
            ? "Hide settled chat threads"
            : "Show settled chat threads",
          isSelected: showsSettledChatThreads,
          activate: toggleSettledChatThreads
        )
      }

      if store.canUndoAIChatThreadArchive {
        Button {
          store.undoLastAIChatThreadArchive()
        } label: {
          Image(systemName: "arrow.uturn.backward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Reopen last settled chat thread")
      }
    }
    .padding(.leading, AIChatSidebarThreadLayout.leadingPadding)
    .padding(.trailing, 8)
  }

  private var settledChatThreadShowMoreRow: some View {
    Button {
      showMoreSettledChatThreads()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "ellipsis.circle")
        Text(AIChatSettledThreadPagination.moreTitle(
          currentLimit: settledChatThreadDisplayLimit,
          totalCount: settledThreads.count
        ))
        Spacer(minLength: 0)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.leading, AIChatSidebarThreadLayout.leadingPadding)
      .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
    .help("Load more settled chat threads")
    .accessibilityIdentifier(
      AIChatSidebarThreadAccessibilityIdentity.settledShowMore
    )
    .background {
      WorkspaceAccessibilityPressTarget(
        identifier: AIChatSidebarThreadAccessibilityIdentity.settledShowMore,
        label: "Load more settled chat threads",
        isSelected: false,
        activate: showMoreSettledChatThreads
      )
    }
  }

  private var chatRenameAlertIsPresented: Binding<Bool> {
    Binding(
      get: { chatRenameRequest != nil },
      set: { isPresented in
        if !isPresented { chatRenameRequest = nil }
      }
    )
  }

  private func toggleSettledChatThreads() {
    withAnimation(WorkspaceMotion.disclosure) {
      showsSettledChatThreads.toggle()
    }
    if !showsSettledChatThreads {
      settledChatThreadDisplayLimit = AIChatSettledThreadPagination.pageSize
    }
  }

  private func showMoreSettledChatThreads() {
    settledChatThreadDisplayLimit = AIChatSettledThreadPagination.nextLimit(
      currentLimit: settledChatThreadDisplayLimit,
      totalCount: settledThreads.count
    )
  }

  private func beginRenamingChatThread(threadID: UUID) {
    guard let thread = store.aiChatThreads.first(where: { $0.id == threadID }) else { return }
    chatRenameDraft = thread.title
    chatRenameRequest = AIChatThreadRenameRequest(threadID: threadID)
  }

  private var visibleSidebarFileRows: [CorpusFileTreePresentationRow] {
    CorpusFileTreePresentation.visibleRows(
      in: store.corpusFileTree,
      expandedDirectoryIDs: expandedSidebarFileDirectoryIDs
    )
  }

  private func toggleSidebarFileDirectory(_ id: String) {
    if expandedSidebarFileDirectoryIDs.contains(id) {
      expandedSidebarFileDirectoryIDs.remove(id)
    } else {
      expandedSidebarFileDirectoryIDs.insert(id)
    }
  }

  private func isSidebarSurfaceSelected(_ surface: WorkspaceSurface) -> Bool {
    guard store.selectedSurface == surface else { return false }
    guard surface == .approvals else { return true }
    return store.runsAndReviewPage != .review && store.runsAndReviewPage != .workflows
  }

  private func sidebarSurfaceButton(_ surface: WorkspaceSurface) -> some View {
    Button {
      activateSidebarSurface(surface)
    } label: {
      SidebarSurfaceRow(
        surface: surface,
        showsCommandShortcut: showsCommandShortcuts,
        notificationCount: 0
      )
      .modifier(
        ReadableListSelectionModifier(
          isSelected: isSidebarSurfaceSelected(surface),
          verticalPadding: 4
        )
      )
      .contentShape(Rectangle())
      .background {
        WorkspaceSurfaceNavigationAccessibilityTarget(
          surface: surface,
          isSelected: isSidebarSurfaceSelected(surface),
          activate: {
            activateSidebarSurface(surface)
          }
        )
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(surface.title)
    .accessibilityIdentifier(
      WorkspaceSurfaceNavigationIdentity.accessibilityIdentifier(for: surface)
    )
    .listRowBackground(Color.clear)
    .help(surface.commandShortcutTitle.isEmpty ? surface.title : "\(surface.title) (\(surface.commandShortcutTitle))")
  }

  private func activateSidebarSurface(_ surface: WorkspaceSurface) {
    if surface == .approvals {
      store.runsAndReviewPage = .runs
      store.makeSurfacePrimary(.approvals)
      return
    }
    guard surface != store.selectedSurface else { return }
    store.makeSurfacePrimary(surface)
  }
}

private struct SidebarAgentWorkPageRow: View {
  let title: String
  let systemImage: String
  let shortcut: String
  let showsCommandShortcut: Bool
  let notificationCount: Int

  var body: some View {
    HStack(spacing: 8) {
      Label(title, systemImage: systemImage)
        .font(.callout.weight(.medium))
      Spacer(minLength: 0)
      if notificationCount > 0 {
        Text("\(notificationCount)")
          .font(.caption2.monospacedDigit().weight(.semibold))
          .foregroundStyle(.secondary)
      }
      if showsCommandShortcut {
        KeyboardShortcutBadge(text: shortcut)
      }
    }
    .contentShape(Rectangle())
  }
}

private struct SidebarChatThreadGroupLabel: View {
  let title: String
  let count: Int

  var body: some View {
    HStack(spacing: 5) {
      Text(title.uppercased())
      Text("\(count)")
        .foregroundStyle(.tertiary)
      Spacer(minLength: 0)
    }
    .font(.system(size: 9, weight: .semibold, design: .monospaced))
    .tracking(0.6)
    .foregroundStyle(WorkspaceDesign.tertiaryText)
    .padding(.leading, AIChatSidebarThreadLayout.leadingPadding)
    .padding(.top, 4)
  }
}

/// Inline, always-visible entry point for settling every automation thread at
/// once. Shown above the recent threads whenever at least one automation
/// thread is unread or still open, so the action does not hide in a menu.
private struct SidebarSettleAutomationThreadsRow: View {
  let count: Int
  let settle: () -> Void

  var body: some View {
    Button(action: settle) {
      HStack(spacing: 6) {
        Image(systemName: AIChatAutomationThreadsAction.systemImage)
          .font(.caption2.weight(.semibold))
        Text(Self.title(count: count))
          .lineLimit(1)
        Spacer(minLength: 0)
        Text("Settle all")
          .fontWeight(.semibold)
          .foregroundStyle(Color.accentColor)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.leading, AIChatSidebarThreadLayout.leadingPadding)
    .padding(.vertical, 2)
    .help(AIChatAutomationThreadsAction.title)
    .accessibilityLabel("\(AIChatAutomationThreadsAction.title), \(Self.title(count: count))")
  }

  static func title(count: Int) -> String {
    count == 1 ? "1 automation thread" : "\(count) automation threads"
  }
}

private struct SidebarCorpusFileTreeRow: View {
  @Environment(WorkspaceStore.self) private var store
  let row: CorpusFileTreePresentationRow
  let isExpanded: Bool
  let toggleDirectory: () -> Void

  var body: some View {
    let node = row.node
    if let file = node.file {
      Button {
        store.openSidebarFile(file)
      } label: {
        CorpusFileTreeNodeLabel(node: node, compact: true)
          .padding(.leading, CGFloat(row.depth + 1) * 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .contextMenu {
        CorpusFileContextMenu(file: file)
      }
      .help(file.relativePath)
    } else {
      Button(action: toggleDirectory) {
        CorpusFileTreeNodeLabel(
          node: node,
          compact: true,
          directoryIsExpanded: isExpanded
        )
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
        .help("\(node.descendantFileCount) file\(node.descendantFileCount == 1 ? "" : "s")")
    }
  }
}

private struct SidebarSectionLabel: View {
  let title: String
  let section: SidebarSectionID?

  init(_ title: String, section: SidebarSectionID? = nil) {
    self.title = title
    self.section = section
  }

  var body: some View {
    if let section {
      SidebarCollapsibleSectionHeader(title: title, section: section)
    } else {
      Text(title.uppercased())
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(0.7)
        .foregroundStyle(WorkspaceDesign.tertiaryText)
    }
  }
}

private struct SidebarHeader: View {
  @Environment(WorkspaceStore.self) private var store
  let showsCommandShortcuts: Bool

  var body: some View {
    HStack(spacing: 7) {
      WorkspaceBrandMark()
      Text(WorkspaceProductIdentity.displayName)
        .font(.system(size: 16, weight: .semibold))
        .tracking(-0.4)

      Spacer(minLength: 0)

      if showsCommandShortcuts {
        KeyboardShortcutBadge(text: WorkspaceSurface.search.commandShortcutTitle)
          .transition(.opacity.combined(with: .move(edge: .trailing)))
      }

      Button {
        store.presentKeyboardShortcuts()
      } label: {
        Label("Keyboard Shortcuts", systemImage: "questionmark.circle")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .foregroundStyle(WorkspaceDesign.secondaryText)
      .frame(width: 26, height: 26)
      .help("Keyboard Shortcuts (⌘/)")

      Button {
        store.focusSearchSurface()
      } label: {
        Label("Search", systemImage: "magnifyingglass")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .foregroundStyle(store.selectedSurface == .search ? Color.accentColor : WorkspaceDesign.secondaryText)
      .frame(width: 26, height: 26)
      .background(
        store.selectedSurface == .search ? WorkspaceDesign.selectedFill : Color.clear,
        in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
      )
      .help("Search workspace (\(WorkspaceSurface.search.commandShortcutTitle))")
    }
    .padding(.leading, 13)
    .padding(.trailing, 10)
    .padding(.top, 16)
    .padding(.bottom, 14)
  }
}

private struct SidebarCorpusSwitcher: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    Menu {
      if !store.mountedCorpora.isEmpty {
        ForEach(store.mountedCorpora) { mount in
          Button {
            store.switchCorpus(to: mount)
          } label: {
            Label(
              mount.name,
              systemImage: mount.path == store.corpusRoot?.standardizedFileURL.path
                ? "checkmark"
                : mount.kind == "shared" ? "person.2" : "folder"
            )
          }
          .disabled(mount.path == store.corpusRoot?.standardizedFileURL.path || store.isSwitchingCorpus)
        }

        Divider()

        if !forgettableCorpora.isEmpty {
          Menu {
            ForEach(forgettableCorpora) { mount in
              Button("Forget \(mount.name)", role: .destructive) {
                store.forgetCorpus(mount)
              }
            }
          } label: {
            Label("Forget Corpus", systemImage: "trash")
          }

          Divider()
        }
      }

      Button {
        store.chooseCorpus()
      } label: {
        Label("Mount Another Corpus…", systemImage: "folder.badge.plus")
      }

      if store.corpusRoot == nil {
        Button {
          store.createCorpus()
        } label: {
          Label("Create Corpus…", systemImage: "plus.square.on.folder")
        }

        Button {
          store.createSharedCorpus()
        } label: {
          Label("Create Shared Corpus…", systemImage: "person.2.fill")
        }
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: activeCorpusIcon)
          .frame(width: 16)
        Text(activeCorpusName)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
        if store.isSwitchingCorpus {
          WorkspaceActivityIndicator(size: .mini)
        } else {
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .font(.callout.weight(.medium))
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(height: 0.5)
    }
    .help(store.corpusRoot?.path ?? "Open or create a corpus")
  }

  private var activeCorpusName: String {
    if let root = store.corpusRoot {
      return store.activeCorpusIdentity?.name ?? root.lastPathComponent
    }
    return "Open Corpus"
  }

  private var activeCorpusIcon: String {
    if store.activeCorpusIdentity?.kind == "shared" {
      return "person.2"
    }
    return store.corpusRoot == nil ? "folder.badge.plus" : "folder"
  }

  private var forgettableCorpora: [WorkspaceCorpusMount] {
    store.mountedCorpora.filter { $0.path != store.corpusRoot?.standardizedFileURL.path }
  }
}

private struct SidebarPinnedFileRow: View {
  let file: CorpusFile
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text")
        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(file.name)
          .font(.callout.weight(isSelected ? .medium : .regular))
          .lineLimit(1)
          .truncationMode(.tail)
        if !file.directory.isEmpty {
          Text(file.directory)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
  }
}

private struct SidebarSurfaceRow: View {
  let surface: WorkspaceSurface
  let showsCommandShortcut: Bool
  let notificationCount: Int

  var body: some View {
    HStack(spacing: 8) {
      Label(surface.title, systemImage: surface.systemImage)
        .font(.callout.weight(.medium))
      Spacer(minLength: 0)
      if notificationCount > 0 && !showsCommandShortcut {
        Text(notificationCount > 99 ? "99+" : "\(notificationCount)")
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.orange)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Color.orange.opacity(0.10), in: Capsule())
          .accessibilityLabel(notificationCount == 1 ? "1 item needs review" : "\(notificationCount) items need review")
      }
      if showsCommandShortcut && !surface.commandShortcutTitle.isEmpty {
        KeyboardShortcutBadge(text: surface.commandShortcutTitle)
          .transition(.opacity.combined(with: .move(edge: .trailing)))
      }
    }
  }
}

private struct AIChatThreadRenameRequest: Identifiable {
  let threadID: UUID
  var id: UUID { threadID }
}

enum AIChatSettledThreadDisclosure {
  static func updated(isExpanded: Bool, settledThreadCount: Int) -> Bool {
    settledThreadCount > 0 && isExpanded
  }
}

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

private struct AIChatSidebarThreadRow: View {
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

private struct AIChatUnreadBadge: View {
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

private struct CanvasesView: View {
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

private struct FilesView: View {
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

private struct CorpusFileTreeNodeLabel: View {
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

private struct ReadableListSelectionModifier: ViewModifier {
  let isSelected: Bool
  var verticalPadding: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .workspaceSelectableRow(isSelected: isSelected, verticalPadding: verticalPadding)
  }
}

private struct CorpusFileContextMenu: View {
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

private struct WorkspaceLocationContextMenu<OpenLabel: View>: View {
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

private struct AgentHandoffMenuItems: View {
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

private struct QuickOpenView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @FocusState private var queryFocused: Bool
  @State private var query = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Quick open files and AI chats", text: $query)
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
          }
        }
      }
      .listStyle(.plain)
      .frame(minHeight: 320)

      Text("Return opens  ·  ⌘Return opens in a new tab  ·  Recent files are listed first")
        .font(.caption)
        .foregroundStyle(.tertiary)
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

  private func handleKeyDown(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
      guard let item = store.selectedQuickOpenItem else { return false }
      open(item, inNewTab: true)
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

private struct SimilarTodoAssignmentView: View {
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

private struct QuickOpenKeyboardEventMonitor: ViewModifier {
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

private struct KeyboardShortcutsView: View {
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
            ShortcutHelpItem(keys: "⌘Return", action: "Steer running turn; send when idle"),
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

private struct AgendaView: View {
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

private struct MetricView: View {
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

private struct RunsAndReviewView: View {
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
              enabled: enabled
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

private struct RunCenterView: View {
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
    case .external: "Describe where or how the outcome was completed. This closes the Celorga item and retains unresolved approvals and review metadata as history. It does not stop work that may still be running in another system."
    case .approvalExternal: "Describe where or how this exact approval action was completed. Only this approval is closed; sibling approvals and the containing run remain open."
    case .approvalExternalBulk(let count): "Describe where or how these \(count) approval actions were completed. Each selected approval is closed independently; sibling approvals and containing runs remain open."
    }
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

private struct RunCenterDetail: View {
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
    if let note = approval.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
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
      if run.status == "blocked" { actionButton("Resume", "play.fill", "resume") }
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
      TextField("Outcome summary", text: $summary, axis: .vertical)
        .lineLimit(3...7)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button(mode.actionTitle) { complete(normalizedSummary) }
          .keyboardShortcut(.defaultAction)
          .disabled(normalizedSummary.isEmpty)
      }
    }
    .padding(22)
    .frame(width: 520)
  }
}

private struct ApprovalsView: View {
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

      ApprovalControls(filterFocused: $filterFocused)

      if store.hasBulkApprovalSelection {
        ApprovalBulkActionBar(
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

      HStack(spacing: 10) {
        MetricView(title: "Visible", value: "\(store.visibleApprovalItems.count)")
        MetricView(title: "Total", value: "\(store.approvalItems.count)")
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 12)

      Divider()

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
  }

  private var headerSubtitle: String {
    "\(store.visibleApprovalItems.count) pending approval\(store.visibleApprovalItems.count == 1 ? "" : "s")"
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
      if store.approvalFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            actionError: store.approvalActionError(item),
            toggleBulkSelection: { store.toggleApprovalItemBulkSelection(item) },
            approve: { Task { await store.approve(item) } },
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
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 12)
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
      Text("The reason is recorded on every selected approval. Standalone approval headings use the chosen final TODO state; run-backed approvals are rejected through their canonical run records.")
        .foregroundStyle(.secondary)

      Picker("Final standalone TODO state", selection: $endStatus) {
        Text("Canceled").tag(TodoEditStatus.canceled)
        Text("Done").tag(TodoEditStatus.done)
      }

      TextField("Rejection reason", text: $reason, axis: .vertical)
        .lineLimit(3...7)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Reject Selected") { reject(endStatus, normalizedReason) }
          .keyboardShortcut(.defaultAction)
          .disabled(normalizedReason.isEmpty)
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
  let actionError: String?
  let toggleBulkSelection: () -> Void
  let approve: () -> Void
  let markDoneElsewhere: () -> Void
  let requestChanges: (() -> Void)?
  let reject: () -> Void
  let copy: () -> Void
  let repairSource: (() -> Void)?
  let discuss: () -> Void

  private var isActionInProgress: Bool {
    isApproving || isRejecting || isCompletingExternally || isRepairingSource
  }

  var body: some View {
    let bodyPreview = item.displayBodyPreview
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 8) {
        Button {
          toggleBulkSelection()
        } label: {
          AgendaBulkSelectionCheckbox(isChecked: isBulkSelected, isEnabled: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isBulkSelected ? "Remove from bulk selection" : "Add to bulk selection")
        .help(isBulkSelected ? "Remove from bulk selection" : "Add to bulk selection")

        StatusPill(text: item.status)
        Text(Org2Display.cleanInline(item.title))
          .font(.body.weight(.semibold))
          .lineLimit(2)
      }

      if !bodyPreview.isEmpty {
        Text(bodyPreview)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      if let runGoal = item.runGoal {
        VStack(alignment: .leading, spacing: 3) {
          Label(runGoal, systemImage: "clock.arrow.circlepath")
            .font(.callout.weight(.medium))
            .lineLimit(2)
          if let dependency = item.runDependencyText {
            Text(dependency)
              .font(.caption.weight(.medium))
              .foregroundStyle(item.runPendingApprovalCount == 1 ? Color.orange : Color.secondary)
          }
        }
      }

      HStack(spacing: 8) {
        if let todo = item.todo {
          StatusPill(text: todo)
        }
        Label(sourceReference, systemImage: "doc.text")
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 6) {
        Button {
          approve()
        } label: {
          if isApproving {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .mini)
              Text("Approving")
            }
          } else {
            Label("Approve", systemImage: "checkmark")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(isActionInProgress)

        Button {
          markDoneElsewhere()
        } label: {
          if isCompletingExternally {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .mini)
              Text("Finishing")
            }
          } else {
            Label("Done Elsewhere…", systemImage: "checkmark.circle")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(isActionInProgress)
        .help("Record that this outcome was completed outside Celorga")

        Button {
          discuss()
        } label: {
          Label("Discuss", systemImage: "paperplane")
        }
        .buttonStyle(WorkspaceActionButtonStyle())

        if let requestChanges {
          Button {
            requestChanges()
          } label: {
            Label("Request Changes…", systemImage: "arrow.uturn.backward")
          }
          .buttonStyle(WorkspaceActionButtonStyle())
          .disabled(isActionInProgress)
        }

        Button {
          reject()
        } label: {
          if isRejecting {
            HStack(spacing: 6) {
              WorkspaceActivityIndicator(size: .mini)
              Text("Rejecting")
            }
          } else {
            Label("Reject", systemImage: "xmark.octagon")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(isActionInProgress)

        Button {
          copy()
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(WorkspaceActionButtonStyle())
      }
      .controlSize(.small)

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

      Text("The current material will remain unapproved. Your feedback will be saved in the run; a correlated workflow will continue by preparing replacement material for approval.")
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

private struct AgendaItemListView: View {
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
              .workspaceLazyRow(id: item.id)
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

private struct AssignedAgendaListView: View {
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

private struct AgendaBulkActionBar: View {
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

private struct SearchView: View {
  @Environment(WorkspaceStore.self) private var store
  @FocusState private var isSearchFocused: Bool
  @State private var searchDraft = ""
  @State private var pendingSearchUpdate: Task<Void, Never>?

  var body: some View {
    @Bindable var store = store
    VStack(spacing: 0) {
      HeaderBar(title: "Search", subtitle: store.searchMode.subtitle, surface: .search) {
        if store.isSearching {
          WorkspaceActivityIndicator(size: .small)
        }

        Button {
          store.promptAndCreateKnowledgeNode()
        } label: {
          Label("New Node", systemImage: "plus.circle")
        }
      }

      HStack(spacing: 8) {
        Picker("Search mode", selection: $store.searchMode) {
          ForEach(WorkspaceSearchMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)

        if store.searchMode == .text {
          Picker("Scope", selection: $store.searchReadScope) {
            ForEach(WorkspaceReadScope.allCases) { scope in
              Text(scope.title).tag(scope)
            }
          }
          .frame(width: 135)
          .help("Search the active corpus or every mounted corpus")
        }

        TextField(store.searchMode.placeholder, text: $searchDraft)
          .textFieldStyle(.roundedBorder)
          .focused($isSearchFocused)
          .onChange(of: searchDraft) {
            if store.searchMode == .nodes { scheduleSearchUpdate() }
          }
          .onSubmit {
            runSearchIfNeeded()
          }

        if store.searchMode == .text {
          Button {
            runSearchIfNeeded()
          } label: {
            Label("Search", systemImage: "magnifyingglass")
          }
          .disabled(searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSearching)
        }
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)

      Text(store.searchMode.helpText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WorkspaceDesign.contentInset)
        .padding(.top, 4)
        .padding(.bottom, 12)

      searchResultsBody
    }
    .onAppear {
      searchDraft = store.searchQuery
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
    .onChange(of: store.searchMode) {
      applySearchImmediately()
    }
    .onChange(of: store.searchReadScope) {
      guard store.searchMode == .text,
            !store.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      Task { await store.runSearch() }
    }
    .onDisappear { pendingSearchUpdate?.cancel() }
  }

  @ViewBuilder
  private var searchResultsBody: some View {
    switch store.searchMode {
    case .text:
      if store.workspaceTextSearchSections.isEmpty {
        if store.isSearching {
          Spacer()
          WorkspaceLoadingStateView("Searching")
          Spacer()
        } else {
          EmptyStateView(title: "No Results", detail: searchEmptyStateDetail, action: "Search") {
            runSearchIfNeeded()
          }
        }
      } else {
        WorkspaceLazyCollection {
          ForEach(store.workspaceTextSearchSections) { section in
            Section {
              ForEach(section.items) { item in
                workspaceSearchRow(item)
              }
            } header: {
              WorkspaceLazySectionHeader {
                Text(section.category.title)
              }
            }
          }
        }
      }
    case .nodes:
      let nodes = store.searchNodes
      if nodes.isEmpty {
        EmptyStateView(title: "No Nodes", detail: "\(nodeEmptyStateDetail) Use the toolbar Refresh to rebuild the corpus index.")
      } else {
        WorkspaceLazyCollection {
          ForEach(nodes) { node in
            NodeSearchRow(
              node: node,
              sourceReference: store.relativePath(node.file) + ":\(node.line)"
            )
            .contentShape(Rectangle())
            .onTapGesture {
              store.selectSearchNode(node)
            }
            .workspaceAccessibleCollectionRow(
              kind: "search-node",
              id: node.id,
              label: Org2Display.cleanInline(node.title),
              open: { store.selectSearchNode(node) }
            )
            .contextMenu {
              NodeSearchContextMenu(node: node)
            }
            .workspaceLazyRow(id: node.id)
          }
        }
      }
    }
  }

  private var searchEmptyStateDetail: String {
    if store.corpusRoot == nil { return "Open a corpus to search its org files." }
    if searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Enter text to search the corpus."
    }
    return store.statusText
  }

  private var nodeEmptyStateDetail: String {
    if store.corpusRoot == nil { return "Open a corpus to search node titles, aliases, and IDs." }
    if store.orgRoamLinkResolver.nodes.isEmpty {
      return "No nodes are indexed yet. Add org files with file-level titles, IDs, or aliases."
    }
    return "No indexed node matched this query."
  }

  private func runSearchIfNeeded() {
    applySearchImmediately()
    guard store.searchMode == .text else { return }
    Task { await store.runSearch() }
  }

  private func scheduleSearchUpdate() {
    pendingSearchUpdate?.cancel()
    let nextQuery = searchDraft
    guard nextQuery != store.searchQuery else { return }
    pendingSearchUpdate = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
      guard !Task.isCancelled else { return }
      store.searchQuery = nextQuery
    }
  }

  private func applySearchImmediately() {
    pendingSearchUpdate?.cancel()
    pendingSearchUpdate = nil
    if store.searchQuery != searchDraft {
      store.searchQuery = searchDraft
    }
  }

  @ViewBuilder
  private func workspaceSearchRow(_ item: WorkspaceTextSearchItem) -> some View {
    Group {
      switch item {
      case .activeTodo(let result), .entry(let result), .corpusText(let result):
        corpusSearchRow(result)
      case .file(let file):
        CorpusFileRow(file: file)
          .padding(.horizontal, WorkspaceDesign.contentInset)
          .contextMenu {
            CorpusFileContextMenu(file: file)
          }
      case .chatThread(let result), .chatMessage(let result):
        ChatSearchRow(result: result)
      case .agentWork(let result):
        AgentWorkSearchRow(result: result)
      case .page(let node):
        NodeSearchRow(
          node: node,
          sourceReference: store.relativePath(node.file) + ":\(node.line)"
        )
          .contextMenu {
            NodeSearchContextMenu(node: node)
          }
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      selectSearchItem(item)
    }
    .workspaceAccessibleCollectionRow(
      kind: "search-result",
      id: item.id,
      label: searchAccessibilityLabel(item),
      open: { selectSearchItem(item) }
    )
    .workspaceLazyRow(id: item.id)
  }

  private func corpusSearchRow(_ result: SearchResult) -> some View {
    SearchRow(
      result: result,
      sourceReference: store.corpusQualifiedPath(result.file, corpus: result.corpus) + ":\(result.lineForEditor)"
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

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(
        systemImage: systemImage,
        tint: tint,
        fill: tint.opacity(0.10)
      )
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(result.title)
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          Text(result.status.replacingOccurrences(of: "-", with: " ").uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.10), in: Capsule())
        }
        if !result.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(result.snippet)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Text("\(result.kind.label) · \(result.sourceReference)")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
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

  private var tint: Color {
    switch result.kind {
    case .approval: .orange
    case .run: .accentColor
    case .workflow: .purple
    case .goal: .green
    case .agent: .blue
    }
  }
}

private struct ChatSearchRow: View {
  let result: AIChatSearchResult

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "bubble.left.and.bubble.right", tint: .accentColor, fill: Color.accentColor.opacity(0.10))
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(result.title)
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          Text("\(result.messageCount) message\(result.messageCount == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(result.snippet)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(Self.relativeDate(result.updatedAt))
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

private struct SearchRow: View {
  let result: SearchResult
  let sourceReference: String
  var isNested = false
  var matchCount: Int?
  var isExpanded: Bool?
  var toggleExpansion: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if let isExpanded {
        Button {
          toggleExpansion?()
        } label: {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .frame(width: 16, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isExpanded ? "Collapse file matches" : "Show file matches")
      } else if isNested {
        Spacer()
          .frame(width: 16)
      }
      WorkspaceIconBadge(systemImage: "magnifyingglass")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          if let todo = result.todo {
            StatusPill(text: todo)
          }
          Text(Org2Display.cleanInline(result.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          Spacer(minLength: 0)
          if result.idValue != nil {
            Image(systemName: "link")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let corpus = result.corpus {
            Text(corpus.name)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkspaceDesign.subtleFill, in: Capsule())
          }
          if let matchCount {
            Text("\(matchCount) matches")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(WorkspaceDesign.subtleFill, in: Capsule())
          }
        }
        Text(Org2Display.cleanInline(result.snippet))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          Text(sourceReference)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
      }
    }
    .padding(.leading, WorkspaceDesign.contentInset + (isNested ? 24 : 0))
    .padding(.trailing, WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct NodeSearchRow: View {
  let node: OrgRoamNodeReference
  let sourceReference: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "link")
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(Org2Display.cleanInline(node.title))
            .font(.body.weight(.medium))
            .lineLimit(1)
          if node.idValue != nil {
            Image(systemName: "number")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }

        if !node.aliases.isEmpty {
          Text(node.aliases.joined(separator: ", "))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        HStack(spacing: 8) {
          Text(sourceReference)
            .lineLimit(1)
            .truncationMode(.middle)
          if let idValue = node.idValue {
            Text(shortID(idValue))
              .fixedSize(horizontal: true, vertical: false)
          }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }

  private func shortID(_ idValue: String) -> String {
    idValue.count > 12 ? String(idValue.prefix(12)) + "..." : idValue
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

private struct SourcesView: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    @Bindable var store = store
    VStack(spacing: 0) {
      HeaderBar(
        title: "Sources",
        subtitle: "Slack, Notion, and email staged as reviewable Org files",
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
          detail: "Add a Slack workspace, Notion workspace, or email account. Settings go in this corpus’s celorga.json; tokens and passwords stay in macOS Keychain.",
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
    .help("Add a Slack, Notion, or email source")
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
        if let secret = type?.secret {
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
          Button(store.sourceHasStoredCredential(profile) ? "Replace \(secret.label)" : "Add \(secret.label)") {
            store.presentSourceCredential(for: profile)
          }
          if store.sourceHasStoredCredential(profile) {
            Button("Remove \(secret.label)", role: .destructive) {
              store.deleteSourceCredential(profile)
            }
          }
        }
      }
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
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

private struct MeetingsView: View {
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

private enum AIChatPresentation {
  case fullPage
  case assistantPanel
  case homePane

  var isCompact: Bool {
    self != .fullPage
  }
}

private struct AIChatView: View {
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
    VStack(spacing: 0) {
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
          ? "Shared AI Room · Experimental"
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
        Label("New Shared Room (Experimental)", systemImage: "person.2.fill")
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

private extension Array where Element == AIChatRoomTranscriptItem {
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

private struct OrgCryptConfigurationSheet: View {
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

private struct DataSourceConfigurationSheet: View {
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

private struct AssignedWorkRow: View {
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

private struct DetailView: View {
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

private struct NodeEntityTypeMenu: View {
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

private struct GoogleDrivePublicationMenu: View {
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

private struct DetailHeader: View {
  @Environment(WorkspaceStore.self) private var store
  @ObservedObject var sourceEditorInteraction: SourceEditorInteractionModel
  @FocusState private var isPageSearchFocused: Bool
  @State private var pageSearchDraft = ""
  let location: WorkspaceLocation
  let renderedViewportSourceLine: Int?

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 8) {
      // The title row matches `HeaderBar` (same insets, type, and row height)
      // so the document pane lines up with the surface pane beside it.
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 16) {
          detailIdentity
            .frame(maxWidth: .infinity, alignment: .leading)
          if !headerMetadataRows.isEmpty {
            DetailMetadataGrid(rows: headerMetadataRows)
              .fixedSize(horizontal: true, vertical: false)
          }
          inlineDetailActions
          DetailPaneControlGroup()
        }
        .frame(minHeight: WorkspaceDesign.paneHeaderRowHeight)

        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .center, spacing: 8) {
            detailIdentity
              .frame(maxWidth: .infinity, alignment: .leading)
            inlineDetailActions
            DetailPaneControlGroup()
          }
          .frame(minHeight: WorkspaceDesign.paneHeaderRowHeight)
          if !headerMetadataRows.isEmpty {
            DetailMetadataGrid(rows: headerMetadataRows)
          }
        }
      }

      if !usesInlineDetailActions {
        detailActionBar
      }

      if store.selectedFileIsDataNotebook,
         let failure = store.dataNotebookRefreshFailure {
        dataNotebookRefreshFailureBanner(failure)
      }

      if store.isPageSearchPresented {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(WorkspaceDesign.secondaryText)
          TextField("Find in page", text: $pageSearchDraft)
            .textFieldStyle(.roundedBorder)
            .focused($isPageSearchFocused)
            .task(id: pageSearchDraft) {
              try? await Task.sleep(nanoseconds: 80_000_000)
              guard !Task.isCancelled, store.pageSearchQuery != pageSearchDraft else { return }
              store.pageSearchQuery = pageSearchDraft
            }
            .onSubmit {
              if store.pageSearchQuery != pageSearchDraft {
                store.pageSearchQuery = pageSearchDraft
              }
              store.selectNextPageSearchOccurrence()
            }
          Text(pageSearchDraft == store.pageSearchQuery ? store.pageSearchOccurrenceSummary : "Searching…")
            .font(.caption.monospacedDigit())
            .foregroundStyle(store.pageSearchOccurrenceCount == 0
              ? WorkspaceDesign.secondaryText
              : WorkspaceDesign.primaryText)
            .frame(minWidth: 72, alignment: .trailing)
          Button {
            store.selectPreviousPageSearchOccurrence()
          } label: {
            Label("Previous Occurrence", systemImage: "chevron.up")
          }
          .labelStyle(.iconOnly)
          .help("Previous occurrence")
          .disabled(pageSearchDraft != store.pageSearchQuery || !store.canNavigatePageSearchOccurrences)
          Button {
            store.selectNextPageSearchOccurrence()
          } label: {
            Label("Next Occurrence", systemImage: "chevron.down")
          }
          .labelStyle(.iconOnly)
          .help("Next occurrence")
          .disabled(pageSearchDraft != store.pageSearchQuery || !store.canNavigatePageSearchOccurrences)
          if !pageSearchDraft.isEmpty {
            Button {
              store.clearRenderedSearchHighlight()
            } label: {
              Label("Clear Page Search", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .help("Clear page search")
          }
        }
        .frame(maxWidth: 560)
        .onAppear {
          pageSearchDraft = store.pageSearchQuery
          isPageSearchFocused = true
        }
      }
    }
    .padding(.horizontal, WorkspaceDesign.headerHorizontalInset)
    .padding(.vertical, WorkspaceDesign.headerVerticalInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(WorkspaceDesign.surfaceBackground)
    .onChange(of: store.pageSearchFocusToken) {
      pageSearchDraft = store.pageSearchQuery
      isPageSearchFocused = true
    }
  }

  private var detailIdentity: some View {
    HStack(alignment: .center, spacing: 9) {
      WorkspaceIconBadge(systemImage: locationIcon, tint: .accentColor, fill: Color.accentColor.opacity(0.09))
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Text(location.title)
            .font(.headline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(location.title)
          if !store.selectedFileIsNativePreview,
             !store.selectedFileIsCSV,
             store.selectedEntrySource != nil {
            NodeEntityTypeMenu()
          }
          if !store.currentDocumentGoogleDrivePublications.isEmpty {
            GoogleDrivePublicationMenu(
              publications: store.currentDocumentGoogleDrivePublications
            )
          }
        }
        detailLocationLine
      }
    }
  }

  /// Zone/subtitle and source path share one caption line so the identity
  /// block stays the same height as other pane headers.
  private var detailLocationLine: some View {
    let path = store.relativePath(location.file)
      + (store.selectedFileIsNativePreview ? "" : ":\(location.lineForEditor)")
    let subtitle = location.subtitle
    let pathText = Text(path)
      .font(.caption2.monospaced())
      .foregroundColor(WorkspaceDesign.tertiaryText)
    let line: Text = subtitle.isEmpty
      ? pathText
      : Text(subtitle)
        .font(.caption)
        .foregroundColor(WorkspaceDesign.secondaryText)
        + Text("  ·  ")
        .font(.caption)
        .foregroundColor(WorkspaceDesign.tertiaryText)
        + pathText
    return line
      .lineLimit(1)
      .truncationMode(.middle)
      .textSelection(.enabled)
      .help(subtitle.isEmpty ? path : "\(subtitle) · \(path)")
  }

  /// Previews and canvases have only a single file-level control, so it sits
  /// in the title row instead of adding a second toolbar row.
  private var usesInlineDetailActions: Bool {
    store.selectedFileIsCanvas || store.selectedFileIsNativePreview
  }

  @ViewBuilder
  private var inlineDetailActions: some View {
    if store.selectedFileIsCanvas {
      Button("Reveal Canvas", systemImage: "folder") { store.revealFile(path: location.file) }
        .labelStyle(.iconOnly)
        .help("Reveal canvas in Finder")
        .controlSize(.small)
        .buttonStyle(WorkspaceActionButtonStyle())
    } else if store.selectedFileIsNativePreview {
      WorkspaceControlStrip { sourceMenu }
        .controlSize(.small)
        .buttonStyle(WorkspaceActionButtonStyle())
        .fixedSize()
    }
  }

  private var headerMetadataRows: [(String, String)] {
    DetailMetadata.rows(for: location).filter { row in
      !(row.0 == "Zone" && row.1 == location.subtitle)
    }
  }

  private var locationIcon: String {
    switch location {
    case .agenda:
      return "calendar"
    case .assigned:
      return "person.crop.circle.badge.checkmark"
    case .search:
      return "magnifyingglass"
    case .backlink:
      return "link"
    case .aiChatThreadRecord:
      if store.selectedFileIsPDF { return "doc.richtext" }
      if store.selectedFileIsImage { return "photo" }
      if store.selectedFileIsVideo { return "film" }
      return store.selectedFileIsCSV ? "tablecells" : "doc.text"
    case .meeting:
      return "waveform.and.mic"
    }
  }

  private var detailActionBar: some View {
    // Canvas and preview controls render inline in the title row instead.
    ViewThatFits(in: .horizontal) {
      fullDetailActionBar
      condensedDetailActionBar
      compactDetailActionBar
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
  }

  private func dataNotebookRefreshFailureBanner(_ failure: DataNotebookRefreshFailure) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: failure.needsCredentialUpdate ? "key.slash.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 2) {
        Text(failure.title)
          .font(.callout.weight(.semibold))
        Text(failure.message)
          .font(.caption)
          .foregroundStyle(WorkspaceDesign.secondaryText)
          .lineLimit(3)
      }

      Spacer(minLength: 12)

      if failure.needsCredentialUpdate {
        Button("Update Credentials") {
          store.presentScarfMetabaseConfiguration()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Button {
        Task { await store.refreshSelectedDataNotebook() }
      } label: {
        Label("Retry Refresh", systemImage: "arrow.clockwise")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help("Retry data refresh")
      .disabled(store.isRefreshingDataNotebook)

      Button {
        store.dismissDataNotebookRefreshFailure()
      } label: {
        Label("Dismiss", systemImage: "xmark")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help("Dismiss refresh error")
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(Color.orange.opacity(0.24), lineWidth: 1)
    }
  }

  private var fullDetailActionBar: some View {
    HStack(spacing: 7) {
      WorkspaceControlStrip {
        detailNavigationControls
        viewAndResourceControls
      }
      Spacer(minLength: 8)
      WorkspaceControlStrip {
        primaryDocumentControls
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var compactDetailActionBar: some View {
    WorkspaceControlStrip {
      detailNavigationControls
      viewAndResourceControls
      primaryDocumentControls
    }
    .labelStyle(.iconOnly)
    .fixedSize(horizontal: true, vertical: false)
  }

  private var condensedDetailActionBar: some View {
    HStack(spacing: 7) {
      WorkspaceControlStrip {
        detailNavigationControls
        viewAndResourceControls
      }
      .labelStyle(.iconOnly)
      Spacer(minLength: 8)
      WorkspaceControlStrip {
        primaryDocumentControls
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var detailNavigationControls: some View {
    Group {
      if store.hasRenderedSearchHighlight {
        Button {
          store.clearRenderedSearchHighlight()
        } label: {
          Label("Clear Highlight", systemImage: "xmark.circle")
        }
        .labelStyle(.iconOnly)
        .help("Clear search match highlights")
      }
    }
  }

  private var viewAndResourceControls: some View {
    HStack(spacing: 7) {
      if !store.selectedFileIsCSV {
        if !store.isLiveFileEditorSelected && !store.hasActiveEdit {
          scopePicker
        }
        if !store.hasActiveEdit {
          documentLayoutMenu
        }
      }
      sourceMenu
      intelligenceMenu
    }
  }

  private var primaryDocumentControls: some View {
    HStack(spacing: 7) {
      if store.selectedFileIsDataNotebook {
        Button {
          Task { await store.refreshSelectedDataNotebook() }
        } label: {
          if store.isRefreshingDataNotebook {
            HStack(spacing: 5) {
              WorkspaceActivityIndicator(size: .small)
              Text("Refreshing Data")
            }
          } else {
            Label("Refresh Data", systemImage: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(!store.canRefreshSelectedDataNotebook)
        .help("Run every named data result in this notebook and update its generated tables")
      }
      editControls
      if !store.selectedFileIsCSV {
        organizeMenu
      }
    }
  }

  private var documentLayoutMenu: some View {
    @Bindable var store = store
    return Menu {
      Picker("Preview", selection: documentPreviewPreferenceBinding) {
        Label(
          "Automatic (\(store.inferredDocumentPreviewKind.title))",
          systemImage: OrgDocumentPreviewPreference.automatic.systemImage
        )
          .tag(OrgDocumentPreviewPreference.automatic)
        Label("Document", systemImage: OrgDocumentPreviewPreference.document.systemImage)
          .tag(OrgDocumentPreviewPreference.document)
        Label("Slides", systemImage: OrgDocumentPreviewPreference.slides.systemImage)
          .tag(OrgDocumentPreviewPreference.slides)
          .disabled(!store.canPreviewSlides)
      }

      Divider()

      Picker("Document Width", selection: $store.renderedDocumentWidth) {
        ForEach(RenderedDocumentWidth.allCases) { width in
          Text(width.title).tag(width)
        }
      }

      Picker("Side Margins", selection: $store.renderedDocumentMargin) {
        ForEach(RenderedDocumentMargin.allCases) { margin in
          Text(margin.title).tag(margin)
        }
      }

      Divider()

      Button {
        store.openAppHTMLStylesheet()
      } label: {
        Label(
          store.hasAppHTMLStylesheet ? "Edit Custom Stylesheet" : "Create Custom Stylesheet",
          systemImage: "paintbrush"
        )
      }

      if store.hasAppHTMLStylesheet {
        Button {
          store.retrySelectedEntryRendering()
        } label: {
          Label("Reload Custom Styles", systemImage: "arrow.clockwise")
        }
      }
    } label: {
      Label("View", systemImage: store.documentPreviewKind.systemImage)
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("\(store.documentPreviewPreferenceLabel) preview, width, margins, and stylesheet")
  }

  private var documentPreviewPreferenceBinding: Binding<OrgDocumentPreviewPreference> {
    Binding(
      get: { store.documentPreviewPreference },
      set: { store.setDocumentPreviewPreference($0) }
    )
  }

  private var sourceMenu: some View {
    Menu {
      LiveEmbedInsertButton()
      Divider()
      if store.selectedFileIsHTML {
        Button {
          store.showHTMLFileSource(!store.htmlFileShowsSource)
        } label: {
          Label(store.htmlFileShowsSource ? "View as Web Page" : "View HTML Source", systemImage: store.htmlFileShowsSource ? "globe" : "chevron.left.forwardslash.chevron.right")
        }
        Button {
          NSWorkspace.shared.open(URL(fileURLWithPath: location.file))
        } label: {
          Label("Open in Default Browser", systemImage: "safari")
        }
        Divider()
      }
      if !store.selectedFileIsNativePreview {
        PluginActionsMenu(context: .heading(file: location.file, line: location.lineForEditor), title: "Plugin Actions for Heading")
        PluginActionsMenu(context: .note(file: location.file), title: "Plugin Actions for Note")
      }
      Button {
        store.togglePinnedFile(path: location.file)
      } label: {
        Label(
          store.isFilePinned(path: location.file) ? "Unpin File" : "Pin File",
          systemImage: store.isFilePinned(path: location.file) ? "pin.slash" : "pin"
        )
      }

      Divider()

      Button {
        if store.selectedFileIsNativePreview {
          NSWorkspace.shared.open(URL(fileURLWithPath: location.file))
        } else {
          store.open(location)
        }
      } label: {
        Label(
          store.selectedFileIsNativePreview ? "Open in Default App" : "Open Source",
          systemImage: "arrow.up.forward.square"
        )
      }

      Button {
        store.revealSelectedLocation()
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }

      if !store.selectedFileIsNativePreview {
        Divider()

        Button {
          store.presentDocumentPublisher()
        } label: {
          Label("Publish Document…", systemImage: "square.and.arrow.up")
        }
        .disabled(!store.canPublishCurrentDocument)

        Button {
          Task { await store.exportCurrentDocumentPDF() }
        } label: {
          Label("Export Current Document as PDF…", systemImage: "doc.richtext")
        }
        .disabled(!store.canExportCurrentDocumentPDF)

        Divider()

        Button {
          Task { await store.exportSlides(format: .pdf) }
        } label: {
          Label("Export Slides as PDF…", systemImage: "rectangle.on.rectangle")
        }
        .disabled(!store.canExportSlides)

        Button {
          Task { await store.exportSlides(format: .latex) }
        } label: {
          Label("Export Slides as LaTeX…", systemImage: "doc.plaintext")
        }
        .disabled(!store.canExportSlides)

        Divider()

        Button {
          Task { await store.linkifyCurrentFile() }
        } label: {
          Label("Linkify File", systemImage: "link.badge.plus")
        }
        .disabled(!store.canLinkifyCurrentFile)
      }

    } label: {
      Label("File", systemImage: "doc.text.magnifyingglass")
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("Open, reveal, export, or linkify this file")
  }

  private var intelligenceMenu: some View {
    Menu {
      Button {
        store.askAIChatAboutCurrentSelection()
      } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      .disabled(!store.canAskAIChatAboutCurrentSelection || store.isLoadingEntrySource)

      Button {
        store.openCanonicalAIChatResourceThread()
      } label: {
        Label(
          "AI Thread",
          systemImage: store.hasCanonicalAIChatResourceThread ? "text.bubble.fill" : "text.bubble"
        )
      }
      .disabled(!store.canOpenCanonicalAIChatResourceThread)

      Divider()

      Button {
        store.toggleNodeContextPane()
      } label: {
        Label(store.isNodeContextPanePresented ? "Hide Context" : "Show Context", systemImage: "sidebar.right")
      }

      Button {
        Task { await store.briefCurrentNode() }
      } label: {
        if store.isBuildingNodeBrief {
          Label("Brief", systemImage: "hourglass")
        } else {
          Label("Brief", systemImage: "text.bubble")
        }
      }
      .disabled(!store.canBriefCurrentNode)

      Button {
        store.isNodeBriefOptionsPresented = true
      } label: {
        Label("Brief Options…", systemImage: "slider.horizontal.3")
      }

      if case .meeting = location {
        Button {
          store.askAIChatAboutSelectedMeeting()
        } label: {
          Label("Meeting", systemImage: "waveform.and.mic")
        }
      }
    } label: {
      Label("AI", systemImage: "sparkles")
    }
    .fixedSize(horizontal: true, vertical: false)
    .help("Ask AI, open this resource's thread, or inspect context")
  }

  private var scopePicker: some View {
    Menu {
      Picker("Document Scope", selection: entrySourceModeSelection) {
        ForEach(EntrySourceMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
    } label: {
      Label(store.selectedEntrySourceMode.title, systemImage: "doc.text")
    }
    .accessibilityLabel("Document scope")
    .fixedSize(horizontal: true, vertical: false)
    .onChange(of: store.selectedEntrySourceMode) {
      Task { await store.reloadSelectedEntrySource() }
    }
    .help("Render entry or full page scope")
  }

  private var entrySourceModeSelection: Binding<EntrySourceMode> {
    Binding(
      get: { store.selectedEntrySourceMode },
      set: { store.selectEntrySourceMode($0) }
    )
  }

  @ViewBuilder
  private var editControls: some View {
    HStack(spacing: 6) {
      editStatusIndicator

      if store.selectedFileIsCSV {
        Button {
          Task { await store.saveLiveFileEditor(explicit: true) }
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .disabled(!store.canSaveLiveFileEditor)
        .help("Save CSV changes (Command-S)")

        Button {
          store.revertLiveFileEditor()
        } label: {
          Label("Revert", systemImage: "arrow.uturn.backward")
        }
        .disabled(!store.liveFileEditorHasUnsavedChanges || isPersistingEditorChanges)
        .help("Discard unsaved CSV changes")
      } else if store.hasActiveEdit {
        Button {
          Task { await store.saveActiveEdit() }
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .disabled(!store.canSaveActiveEdit)
        .help("Save changes (Command-S)")

        Button {
          store.cancelActiveEdit()
        } label: {
          Label("Cancel", systemImage: "xmark")
        }
        .help(hasPendingEditorChanges ? "Discard changes" : "Close source editor")

        Button {
          Task { await store.saveAndFinishActiveEdit() }
        } label: {
          Label("Save & Done", systemImage: "checkmark.circle")
        }
        .disabled(isPersistingEditorChanges)
        .help(hasPendingEditorChanges ? "Save changes and close the editor" : "Close the editor")
      } else {
        Button {
          store.beginEditingCurrentScope(atSourceLine: renderedViewportSourceLine)
        } label: {
          Label("Edit", systemImage: "square.and.pencil")
        }
        .disabled(store.selectedEntrySource?.isEditable != true || store.isLoadingEntrySource)
        .help("Edit this file")
      }
    }
  }

  private var editStatusIndicator: some View {
    ZStack {
      if isPersistingEditorChanges {
        WorkspaceActivityIndicator(size: .small)
          .accessibilityLabel("Saving changes")
      } else if hasPendingEditorChanges {
        Image(systemName: "circle.fill")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.orange)
          .accessibilityLabel("Unsaved changes")
      } else {
        Color.clear
          .accessibilityHidden(true)
      }
    }
    .frame(width: 24, height: 24)
    .help(editStatusHelp)
  }

  private var isPersistingEditorChanges: Bool {
    store.isSavingEntry || store.isSavingBlock || store.isLiveFileEditorAutosaving
  }

  private var hasPendingEditorChanges: Bool {
    store.entryEditorHasUnsavedChanges
      || store.editingBlockID != nil
      || store.liveFileEditorHasUnsavedChanges
  }

  private var editStatusHelp: String {
    if isPersistingEditorChanges {
      return "Saving changes"
    }
    if hasPendingEditorChanges {
      return "Unsaved changes. Press Command-S to save."
    }
    return "No unsaved editor changes"
  }

  @ViewBuilder
  private var organizeMenu: some View {
    Menu {
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
        Divider()
        Button {
          Task { await store.applyTodoShortcut(nil) }
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
        Label("Deadline", systemImage: "calendar.badge.exclamationmark")
      }

      Menu {
        Button("A") {
          Task { await store.applyPriorityShortcut("A") }
        }
        Button("B") {
          Task { await store.applyPriorityShortcut("B") }
        }
        Button("C") {
          Task { await store.applyPriorityShortcut("C") }
        }
        Divider()
        Button("Clear") {
          Task { await store.applyPriorityShortcut(nil) }
        }
      } label: {
        Label("Priority", systemImage: "flag")
      }

      Divider()

      Button {
        Task { await store.presentSimilarTodoAssignment() }
      } label: {
        Label("Find Similar TODOs...", systemImage: "rectangle.stack.badge.plus")
      }

      Menu {
        AgentHandoffMenuItems { profile in
          Task { await store.applyAgentHandoffShortcut(agentProfile: profile) }
        }
      } label: {
        Label("Pass to Agent", systemImage: "person.crop.circle.badge.checkmark")
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
        store.promptAndApplyPropertyShortcut()
      } label: {
        Label("Set Property", systemImage: "tag")
      }
    } label: {
      Label("Organize", systemImage: "ellipsis.circle")
    }
    .disabled(!store.canOrganizeCurrentHeadline)
    .help("Status, schedule, deadline, priority, agent handoff, and properties")
  }

  private func planningButton(_ title: String, kind: PlanningEditKind, target: PlanningDateTarget) -> some View {
    Button(title) {
      Task { await store.applyPlanningShortcut(kind: kind, target: target) }
    }
  }
}

private struct LiveFileEditorBody: View {
  @Environment(WorkspaceStore.self) private var store
  let location: WorkspaceLocation
  let reportViewportSourceLine: @MainActor (Int?) -> Void

  var body: some View {
    Group {
      if store.isLoadingEntrySource && store.selectedEntrySource == nil {
        OrgHTMLLoadingView(label: "Loading source", onCancel: store.cancelSelectedEntryLoading)
      } else if let source = store.selectedEntrySource {
        if store.selectedFileIsCSV {
          CSVDocumentEditorView(source: source)
        } else if store.isEditingEntry {
          OrgSourceEditorWithLinkTools(interaction: store.sourceEditorInteraction)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.editingBlockID != nil {
          ScrollView {
            LegacyStructuredEntryEditorView(source: source)
              .padding(16)
          }
        } else {
          OrgRenderedDocumentPreview(
            source: source,
            loadingLabel: "Rendering page",
            reportViewportSourceLine: reportViewportSourceLine
          )
        }
      } else if let error = store.selectedEntryRenderError {
        OrgHTMLRenderFailureView(message: error)
      } else {
        EmptyStateView(title: "Source Unavailable", detail: store.statusText, action: "Reveal File") {
          store.revealFile(path: location.file)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct OrgRenderedDocumentPreview: View {
  @Environment(WorkspaceStore.self) private var store
  let source: EntrySource
  let loadingLabel: String
  let reportViewportSourceLine: @MainActor (Int?) -> Void

  private var startWorkAction: (@MainActor (Int) -> Void)? {
    guard source.isEditable else { return nil }
    let store = self.store
    return { line in store.startWork(onHeadingAt: line) }
  }

  var body: some View {
    Group {
      if store.documentPreviewKind == .slides {
        OrgSlidePreviewPane(reportViewportSourceLine: reportViewportSourceLine)
          .task(id: source) {
            store.scheduleSlidePreview(text: source.text, source: source, immediate: true)
          }
      } else if let html = store.selectedEntryHTML {
        VStack(spacing: 0) {
          if WorkspaceStore.showsEntityActionItems(for: source) {
            EntityActionItemsPanel(
              payload: store.entityActionItems,
              isLoading: store.isLoadingEntityActionItems,
              selectItem: store.selectEntityActionItem
            )
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 8)
          }
          OrgHTMLDocumentView(
            html: html,
            renderIdentity: store.selectedEntryHTMLRenderIdentity,
            source: source,
            corpusRoot: store.corpusRoot,
            searchQuery: store.renderedSearchHighlightQuery,
            searchOccurrenceIndex: store.pageSearchSelectedOccurrenceIndex,
            searchOccurrenceCount: store.pageSearchOccurrenceCount,
            scrollRequest: store.detailScrollRequest,
            restorationSourceLine: store.documentViewportSourceLine(for: source),
            layout: store.renderedDocumentLayout,
            activateWorkspacePane: { store.activateWorkspacePane(.detail) },
            askAIAboutHeading: { store.askAIChatAboutSourceHeading(at: $0) },
            performEntryAction: { store.performRenderedEntryAction($0, at: $1) },
            peekEncryptedText: { line in Task { await store.peekOrgCrypt(line: line) } },
            reportStatus: { store.statusText = $0 },
            allowsCheckboxMutations: source.isEditable,
            setCheckboxState: { line, checked in
              await store.setRenderedDocumentCheckbox(at: line, checked: checked)
            },
            allowsTablePersistence: source.isEditable,
            saveTableView: { store.requestSaveRenderedTableView($0) },
            recalculateTableFormulas: { store.requestRecalculateRenderedTableFormulas(at: $0) },
            reportViewportSourceLine: reportViewportSourceLine,
            startWorkAtHeading: startWorkAction,
            openWorkAtHeading: { store.openWork(onHeadingAt: $0) },
            headingWorkBadges: store.headingWorkBadges(for: source)
          )
          .frame(maxHeight: .infinity)
        }
      } else if store.isSelectedRenderedBlocksReady {
        nativePreview
      } else if let error = store.selectedEntryRenderError {
        OrgHTMLRenderFailureView(message: error)
      } else {
        OrgHTMLLoadingView(label: loadingLabel, onCancel: store.cancelSelectedEntryLoading)
      }
    }
    .task(id: "\(source.id):\(WorkspaceStore.entityType(for: source)?.rawValue ?? "untyped")") {
      await store.loadEntityActionItems(for: source)
    }
  }

  private var nativePreview: some View {
    VStack(spacing: 0) {
      if WorkspaceStore.showsEntityActionItems(for: source) {
        EntityActionItemsPanel(
          payload: store.entityActionItems,
          isLoading: store.isLoadingEntityActionItems,
          selectItem: store.selectEntityActionItem
        )
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 8)
      }

      if let error = store.selectedEntryRenderError {
        HStack(spacing: 8) {
          Label("Enhanced preview unavailable", systemImage: "exclamationmark.triangle")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .help(error)
          Spacer(minLength: 0)
          Button {
            store.retrySelectedEntryRendering()
          } label: {
            Label("Retry", systemImage: "arrow.clockwise")
          }
          .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(WorkspaceDesign.controlFill)
      }

      ScrollView {
        LegacyStructuredEntryEditorView(source: source)
          .padding(16)
      }
    }
  }
}

private struct EntityActionItemsPanel: View {
  let payload: NodeActionItemsPayload?
  let isLoading: Bool
  let selectItem: (NodeActionItem) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Image(systemName: "checklist")
          .foregroundStyle(.secondary)
        Text("Action items")
          .font(.callout.weight(.semibold))
        if let payload {
          Text(summary(payload))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if isLoading {
          ProgressView()
            .controlSize(.small)
        }
      }

      if let payload {
        if payload.open.isEmpty {
          Text("No open action items")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(payload.open) { item in
            actionRow(item, completed: false)
          }
        }

        if !payload.recentlyCompleted.isEmpty {
          Divider()
          Text("Recently completed")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          ForEach(payload.recentlyCompleted) { item in
            actionRow(item, completed: true)
          }
        }
      } else if !isLoading {
        Text("Action items are unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(WorkspaceDesign.panelFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
    )
  }

  private func actionRow(_ item: NodeActionItem, completed: Bool) -> some View {
    Button {
      selectItem(item)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
          .font(.caption)
          .foregroundStyle(completed ? Color.green : Color.secondary)
        if !completed {
          Text(statusLabel(item.todo))
            .font(.caption2.weight(.medium))
            .foregroundStyle(item.todo.uppercased() == "IN_PROGRESS" ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
              Capsule()
                .fill(Color.primary.opacity(0.05))
            )
        }
        Text(Org2Display.cleanInline(item.title))
          .font(.caption)
          .foregroundStyle(completed ? .secondary : .primary)
          .strikethrough(completed, color: .secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        if let metadata = metadata(item, completed: completed) {
          Text(metadata)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func summary(_ payload: NodeActionItemsPayload) -> String {
    var parts = ["\(payload.counts.open) open"]
    if payload.counts.recentlyCompleted > 0 {
      parts.append("\(payload.counts.recentlyCompleted) recent")
    }
    return parts.joined(separator: " · ")
  }

  private func metadata(_ item: NodeActionItem, completed: Bool) -> String? {
    if let date = item.date {
      if completed { return date }
      if item.dateKind == "deadline" { return "Due \(date)" }
      return date
    }
    if let meeting = item.meeting {
      return "From \(Org2Display.cleanInline(meeting.title))"
    }
    return nil
  }

  private func statusLabel(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "IN_PROGRESS": return "In progress"
    case "WAITING": return "Waiting"
    case "BLOCKED": return "Blocked"
    case "NEXT": return "Next"
    default: return "Open"
    }
  }
}

private struct LegacyStructuredEntryEditorView: View {
  @Environment(WorkspaceStore.self) private var store
  let source: EntrySource

  var body: some View {
    OrgRenderedEntryView(
      blocks: store.selectedRenderedBlocks,
      blocksRenderSignature: store.selectedRenderedBlocksRenderSignature,
      source: OrgRenderedEntrySourceContext(source),
      corpusRoot: store.corpusRoot,
      selectedBlockID: store.selectedBlockID,
      selectedBlockIndex: store.selectedBlockID.flatMap { store.selectedRenderedBlockIndexes[$0] },
      editingBlockID: store.editingBlockID,
      foldedBlockIDs: store.foldedRenderedBlockIDs,
      detailScrollRequest: store.detailScrollRequest,
      sourceBlockRunsRenderSignature: store.sourceBlockRunsRenderSignature,
      sourceBlockRuns: store.sourceBlockRuns,
      searchHighlightQuery: store.renderedSearchHighlightQuery
    )
    .equatable()
  }
}

private struct OrgHTMLLoadingView: View {
  let label: String
  var onCancel: (() -> Void)? = nil

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 8) {
        WorkspaceActivityIndicator(size: .small, style: .scan)
        Text(label)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let onCancel {
        Button("Stop Waiting", action: onCancel)
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private struct LinkedPDFPreviewPane: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var zoomScale: CGFloat = 1
  @State private var pageCount = 0
  @State private var pageIndex: Int?
  @State private var navigationGeneration = 0
  @State private var navigationRequest: OrgPDFPageNavigationRequest?

  var body: some View {
    ZStack {
      if let data = store.linkedPDFPreviewData {
        OrgPDFDocumentView(
          data: data,
          zoomScale: zoomScale,
          navigationRequest: navigationRequest,
          reportViewportPageIndex: { pageIndex = $0 },
          reportPageCount: { pageCount = $0 }
        )
      } else if store.isLoadingLinkedPDFPreview {
        OrgHTMLLoadingView(label: "Loading PDF", onCancel: store.cancelLinkedPDFPreview)
      } else {
        unavailableView
      }
    }
    .overlay(alignment: .bottom) {
      if store.linkedPDFPreviewData != nil, pageCount > 0 {
        OrgPDFPreviewControls(
          pageIndex: pageIndex,
          pageCount: pageCount,
          zoomScale: zoomScale,
          navigate: navigate,
          zoomOut: {
            zoomScale = WorkspaceStore.previousSlidePreviewZoomScale(before: zoomScale)
          },
          resetZoom: { zoomScale = 1 },
          zoomIn: {
            zoomScale = WorkspaceStore.nextSlidePreviewZoomScale(after: zoomScale)
          }
        )
        .padding(14)
      }
    }
    .overlay(alignment: .topTrailing) {
      if store.linkedPDFPreviewData != nil {
        Button {
          store.retryLinkedPDFPreview()
        } label: {
          if store.isLoadingLinkedPDFPreview {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(9)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().stroke(WorkspaceDesign.hairline))
        .padding(12)
        .disabled(store.isLoadingLinkedPDFPreview)
        .help(store.isLoadingLinkedPDFPreview ? "Refreshing PDF preview" : "Refresh PDF preview")
        .accessibilityLabel(store.isLoadingLinkedPDFPreview ? "Refreshing PDF preview" : "Refresh PDF preview")
      }
    }
    .task(id: store.selectedLocation?.file) {
      zoomScale = 1
      pageCount = 0
      pageIndex = nil
      navigationRequest = nil
    }
    .background(WorkspaceDesign.surfaceBackground)
  }

  private func navigate(_ target: OrgPDFPageNavigationTarget) {
    navigationGeneration += 1
    navigationRequest = OrgPDFPageNavigationRequest(id: navigationGeneration, target: target)
  }

  private var unavailableView: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.richtext")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)
      Text("PDF preview unavailable")
        .font(.headline)
      Text(store.linkedPDFPreviewError ?? "Preparing the linked PDF.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      Button {
        store.retryLinkedPDFPreview()
      } label: {
        Label("Retry", systemImage: "arrow.clockwise")
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private struct OrgSlidePreviewPane: View {
  @Environment(WorkspaceStore.self) private var store
  var reportViewportSourceLine: @MainActor (Int?) -> Void = { _ in }

  var body: some View {
    ZStack {
      if let pdf = store.slidePreviewPDF {
        OrgPDFDocumentView(
          data: pdf,
          scrollRequest: store.detailScrollRequest,
          restorationSourceLine: store.currentDocumentViewportSourceLine,
          restorationPageIndex: store.currentDocumentSlidePageIndex,
          zoomScale: store.slidePreviewZoomScale,
          navigationRequest: store.slidePreviewNavigationRequest,
          reportViewportSourceLine: reportViewportSourceLine,
          reportViewportPageIndex: { store.recordDocumentSlidePageIndex($0) },
          reportPageCount: { store.setSlidePreviewPageCount($0) }
        )
      } else if store.isRenderingSlidePreview {
        OrgHTMLLoadingView(label: "Compiling slides", onCancel: store.cancelSlidePreview)
      } else {
        unavailableView
      }
    }
    .overlay(alignment: .topTrailing) {
      if store.slidePreviewPDF != nil,
         store.isRenderingSlidePreview {
        HStack(spacing: 6) {
          WorkspaceActivityIndicator(size: .small)
          Text("Compiling")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
      }
    }
    .overlay(alignment: .topLeading) {
      if store.slidePreviewPDF != nil,
         let error = store.slidePreviewError {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .lineLimit(2)
          Button("Retry") {
            store.retrySlidePreview()
          }
          .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
      }
    }
    .overlay(alignment: .bottom) {
      if store.slidePreviewPDF != nil, store.slidePreviewPageCount > 0 {
        OrgPDFPreviewControls(
          pageIndex: store.currentDocumentSlidePageIndex,
          pageCount: store.slidePreviewPageCount,
          zoomScale: store.slidePreviewZoomScale,
          navigate: store.requestSlidePreviewNavigation,
          zoomOut: store.zoomSlidePreviewOut,
          resetZoom: store.resetSlidePreviewZoom,
          zoomIn: store.zoomSlidePreviewIn
        )
          .padding(14)
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
  }

  private var unavailableView: some View {
    VStack(spacing: 12) {
      Image(systemName: "rectangle.on.rectangle.slash")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Slide preview unavailable")
        .font(.headline)
      Text(unavailableMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      if store.canPreviewSlides {
        Button {
          store.retrySlidePreview()
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private var unavailableMessage: String {
    if !store.canPreviewSlides {
      return "Open the full Org page to compile its slide deck."
    }
    return store.slidePreviewError ?? "Preparing the compiled PDF."
  }
}

private struct OrgPDFPreviewControls: View {
  let pageIndex: Int?
  let pageCount: Int
  let zoomScale: CGFloat
  let navigate: (OrgPDFPageNavigationTarget) -> Void
  let zoomOut: () -> Void
  let resetZoom: () -> Void
  let zoomIn: () -> Void
  @State private var pageNumberText = "1"

  var body: some View {
    HStack(spacing: 8) {
      Button {
        navigate(.previous)
      } label: {
        Image(systemName: "chevron.left")
      }
      .disabled((pageIndex ?? 0) <= 0)
      .help("Previous page")

      TextField("Page", text: $pageNumberText)
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .frame(width: 30)
        .onSubmit(jumpToEnteredPage)
        .accessibilityLabel("Page number")

      Text("of \(pageCount)")
        .foregroundStyle(.secondary)
        .monospacedDigit()

      Button {
        navigate(.next)
      } label: {
        Image(systemName: "chevron.right")
      }
      .disabled((pageIndex ?? 0) >= pageCount - 1)
      .help("Next page")

      Divider()
        .frame(height: 16)

      Button {
        zoomOut()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .help("Zoom out (Command-Minus)")

      Button {
        resetZoom()
      } label: {
        Text("\(Int((zoomScale * 100).rounded()))%")
          .monospacedDigit()
          .frame(minWidth: 36)
      }
      .help("Fit PDF to the window")

      Button {
        zoomIn()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .help("Zoom in (Command-Plus)")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(WorkspaceDesign.hairline))
    .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
    .onAppear(perform: updatePageNumberText)
    .onChange(of: pageIndex) { updatePageNumberText() }
  }

  private func jumpToEnteredPage() {
    guard let pageNumber = Int(pageNumberText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      updatePageNumberText()
      return
    }
    let clampedPage = min(max(1, pageNumber), pageCount)
    pageNumberText = String(clampedPage)
    navigate(.page(clampedPage - 1))
  }

  private func updatePageNumberText() {
    pageNumberText = String((pageIndex ?? 0) + 1)
  }
}

private struct OrgHTMLRenderFailureView: View {
  @Environment(WorkspaceStore.self) private var store
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)
      Text("Preview unavailable")
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      HStack(spacing: 8) {
        Button {
          store.retrySelectedEntryRendering()
        } label: {
          Label("Retry", systemImage: "arrow.clockwise")
        }
        if store.selectedEntrySource?.isEditable == true {
          Button {
            store.beginEditingSelectedEntry()
          } label: {
            Label("Edit Source", systemImage: "square.and.pencil")
          }
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}

private struct OrgSourceEditorWithLinkTools: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.orgRoamLinkResolver) private var orgRoamLinkResolver
  @ObservedObject var interaction: SourceEditorInteractionModel
  @State private var sourcePreviewLine: Int?
  @State private var sourceCaretLocalLine: Int?
  @State private var sourceSelectionSnapshot: OrgSyntaxTextEditorSelectionSnapshot?
  @State private var sourcePreviewScrollTask: Task<Void, Never>?
  @State private var dateMentionState = WorkspaceDateMentionCompletionState()
  @State private var slashCommandState = WorkspaceSlashCommandCompletionState()
  @StateObject private var prose = OrgProseEditorController()
  @State private var showsProseSidebar = true

  private var isProse: Bool { store.sourceEditorPresentation == .prose }

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 8) {
      sourceEditorCommandBar

      if store.sourceEditorPresentation == .split {
        HSplitView {
          sourceColumn
            .frame(minWidth: 360)
          sourcePreview
            .frame(minWidth: 320)
        }
      } else if isProse {
        proseColumn
      } else {
        sourceColumn
      }
    }
    .sheet(item: $prose.alternativeDraft) { draft in
      OrgProseAlternativeSheet(controller: prose, draft: draft)
    }
    .onAppear {
      prose.onStatus = { [store] status in store.statusText = status }
    }
    .task {
      scheduleSourcePreviewScroll()
      if store.sourceEditorPresentation == .split {
        store.scheduleSourceEditorPreview(immediate: true)
      }
    }
    .onChange(of: interaction.text) {
      store.noteSourceEditorLocalTextChanged(interaction.text)
      store.scheduleSourceEditorPreview(text: interaction.text)
    }
    .onChange(of: store.sourceEditorPresentation) { _, presentation in
      scheduleSourcePreviewScroll()
      if presentation == .split {
        store.scheduleSourceEditorPreview(immediate: true)
      }
    }
    .onChange(of: store.documentPreviewKind) {
      scheduleSourcePreviewScroll()
      store.scheduleSourceEditorPreview(immediate: true)
    }
    .onChange(of: store.selectedEntrySource?.id) {
      sourceCaretLocalLine = nil
      sourceSelectionSnapshot = nil
      sourcePreviewLine = nil
    }
    .onDisappear {
      sourcePreviewScrollTask?.cancel()
    }
  }

  private var proseColumn: some View {
    HStack(spacing: 0) {
      ZStack {
        // Clicking the empty prose margin collapses the selection so the
        // highlight never feels stuck; clicks on text stay with the editor.
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .onTapGesture { prose.clearSelectionKeepingCaret() }
        sourceEditor(prose: true)
          .frame(maxWidth: OrgProsePresentation.measure)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(WorkspaceDesign.surfaceBackground)
      if showsProseSidebar {
        OrgProseSidebar(controller: prose)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(WorkspaceDesign.hairline)
    )
  }

  private var sourceColumn: some View {
    @Bindable var store = store
    return VStack(alignment: .leading, spacing: 8) {
      sourceEditor(prose: false)
      .frame(minHeight: 320, maxHeight: .infinity)
      .layoutPriority(1)
      .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(WorkspaceDesign.hairline)
      )

      if hasSelection && !isProse {
        ParagraphInlineFormatBar(
          text: $interaction.text,
          selectedRange: $interaction.selection,
          insertBacklink: insertBacklinkForSelection,
          createNodeFromSelection: createNodeFromSelection
        )
      }

      if let wikiLinkCompletionMatch {
        ParagraphWikiLinkCompletionPanel(
          query: wikiLinkCompletionMatch.query,
          candidates: orgRoamLinkResolver.searchCandidates(matching: wikiLinkCompletionMatch.query, limit: 6),
          choose: { node in
            resolveWikiLinkCompletion(wikiLinkCompletionMatch, to: node)
          },
          create: {
            createNodeFromWikiLinkCompletion(wikiLinkCompletionMatch)
          }
        )
      } else if let slashMatch = sourceSelectionSnapshot.flatMap(WorkspaceSlashCommands.match(in:)),
                !slashCommandState.isDismissed(slashMatch) {
        let options = WorkspaceSlashCommands.options(for: slashMatch)
        WorkspaceSlashCommandPanel(
          options: options,
          selectedIndex: slashCommandState.selectedIndex(for: slashMatch, optionCount: options.count),
          choose: { command in
            let removedNatively = OrgSyntaxTextEditorInsertionTarget.focused()?.replace(
              slashMatch.replacementRange,
              with: "",
              expectedPrefix: "/"
            ) == true
            if !removedNatively {
              OrgSyntaxTextEditor.publishPendingTextChanges()
              let text = interaction.text as NSString
              guard NSMaxRange(slashMatch.replacementRange) <= text.length else { return }
              applyInlineEdit(InlineSelectionReplacement(
                text: text.replacingCharacters(in: slashMatch.replacementRange, with: ""),
                selectedRange: NSRange(location: slashMatch.replacementRange.location, length: 0)
              ))
            }
            runSlashCommand(command)
          }
        )
      } else if let dateMentionMatch = sourceSelectionSnapshot.flatMap(WorkspaceDateMentions.match(in:)),
                !dateMentionState.isDismissed(dateMentionMatch) {
        let options = dateMentionOptions(for: dateMentionMatch)
        if !options.isEmpty {
          WorkspaceDateMentionCompletionPanel(
            options: options,
            selectedIndex: dateMentionState.selectedIndex(for: dateMentionMatch, optionCount: options.count),
            choose: { option in
              completeDateMention(dateMentionMatch, with: option)
            }
          )
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func sourceEditor(prose: Bool) -> some View {
    @Bindable var store = store
    let sourceAtMount = store.selectedEntrySource
    let activeProse: OrgProseEditorController? = prose ? self.prose : nil
    let dateMentionKeyHandler: ((OrgSyntaxTextEditorCompletionKey, OrgSyntaxTextEditorSelectionSnapshot) -> OrgSyntaxTextEditorCompletionKeyResult)? =
      prose ? nil : { key, snapshot in
        let slashResult = handleSlashCommandKey(key, snapshot: snapshot)
        if case .ignored = slashResult {
          return handleDateMentionKey(key, snapshot: snapshot)
        }
        return slashResult
      }
    // Code, markup, config, and data files are highlighted as their own
    // language and skip Org-only analysis and writing commands.
    let codeLanguage = prose ? nil : OrgCodeHighlighter.language(forPath: sourceAtMount?.file)
    let analyzer: ((String) async -> OrgSourceEditorSemanticSnapshot?)? = prose || codeLanguage != nil
      ? nil
      : { text in await store.analyzeSourceEditorText(text) }
    OrgSyntaxTextEditor(
      text: $interaction.text,
      monospaced: !prose,
      showsScrollers: true,
      textInset: prose ? NSSize(width: 28, height: 32) : NSSize(width: 12, height: 12),
      focusOnAppear: true,
      textPublishing: .deferred(milliseconds: 500),
      liveHighlighting: true,
      incrementalHighlighting: true,
      incrementalHighlightingDelayMilliseconds: 120,
      concealsSyntax: prose,
      orgWritingCommands: !prose && codeLanguage == nil,
      pasteAsOrgEnabled: { store.experimentalFeaturesEnabled && codeLanguage == nil },
      textChecking: codeLanguage == nil ? .spellingAndGrammar : .disabled,
      caretPublishingDelayMilliseconds: 180,
      semanticAnalysisDelayMilliseconds: 900,
      commandRequest: store.sourceEditorCommandRequest,
      semanticAnalyzer: analyzer,
      diagnostics: $store.sourceEditorDiagnostics,
      onCommandStatus: { status in
        store.statusText = status
      },
      selection: $interaction.selection,
      onSelectionSnapshot: { snapshot in
        sourceSelectionSnapshot = snapshot
        if sourceCaretLocalLine != snapshot.sourceLine {
          sourceCaretLocalLine = snapshot.sourceLine
          scheduleSourcePreviewScroll()
        }
      },
      onViewportSourceLine: { line in
        guard let source = store.selectedEntrySource else { return }
        store.recordDocumentViewportSourceLine(
          source.startLine + line - 1,
          for: source
        )
      },
      onGutterBacklinks: { line in
        store.showSourceEditorBacklinks(at: line)
      },
      onLocalTextChange: { text in
        store.noteSourceEditorLocalTextChanged(text)
        if store.sourceEditorPresentation == .split {
          store.scheduleSourceEditorPreview(text: text)
        }
      },
      documentIdentity: sourceAtMount?.id,
      onCheckpointText: { text in
        if let sourceAtMount {
          store.persistSourceEditorCheckpoint(text, source: sourceAtMount)
        }
      },
      documentGeneration: { interaction.documentGeneration },
      bindingGeneration: { interaction.bindingGeneration },
      onTextPublicationConflict: { text in
        if let sourceAtMount {
          store.preserveSourceEditorDraftAfterPublicationConflict(
            text,
            source: sourceAtMount
          )
        }
      },
      onSaveCommand: { context in
        interaction.text = context.text
        store.noteSourceEditorLocalTextChanged(context.text)
        Task { await store.saveEditedEntry() }
        return true
      },
      completionKeyHandler: codeLanguage == nil ? dateMentionKeyHandler : nil,
      proseController: activeProse,
      codeLanguage: codeLanguage
    )
  }

  private func dateMentionOptions(for match: WorkspaceDateMentionMatch) -> [WorkspaceDateMentionOption] {
    store.dateMentionEditorOptions(for: match, sourceFile: store.selectedEntrySource?.file)
  }

  private func handleDateMentionKey(
    _ key: OrgSyntaxTextEditorCompletionKey,
    snapshot: OrgSyntaxTextEditorSelectionSnapshot
  ) -> OrgSyntaxTextEditorCompletionKeyResult {
    guard ParagraphWikiLinkCompletion.match(in: snapshot) == nil,
          let match = WorkspaceDateMentions.match(in: snapshot)
    else { return .ignored }
    let result = dateMentionState.handle(key, match: match, options: dateMentionOptions(for: match))
    if case .replace = result {
      sourceSelectionSnapshot = nil
    }
    return result
  }

  private func handleSlashCommandKey(
    _ key: OrgSyntaxTextEditorCompletionKey,
    snapshot: OrgSyntaxTextEditorSelectionSnapshot
  ) -> OrgSyntaxTextEditorCompletionKeyResult {
    guard ParagraphWikiLinkCompletion.match(in: snapshot) == nil,
          let match = WorkspaceSlashCommands.match(in: snapshot)
    else { return .ignored }
    var accepted: WorkspaceSlashCommand?
    let result = slashCommandState.handle(
      key,
      match: match,
      options: WorkspaceSlashCommands.options(for: match),
      accepted: &accepted
    )
    if case .replace = result {
      sourceSelectionSnapshot = nil
    }
    if let accepted {
      // Let the editor remove the typed command before the picker opens.
      Task { @MainActor in runSlashCommand(accepted) }
    }
    return result
  }

  private func runSlashCommand(_ command: WorkspaceSlashCommand) {
    switch command {
    case .image:
      // Capture the editor before the picker takes focus from it.
      let target = OrgSyntaxTextEditorInsertionTarget.focused()
      guard let imageURL = WorkspaceSlashCommands.chooseImage() else { return }
      Task { @MainActor in
        guard let link = await store.importSourceEditorImage(from: imageURL) else { return }
        if let target {
          if target.replace(with: link) { return }
          // The editor closed or switched documents while the image was
          // chosen. Never drop the link silently.
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(link, forType: .string)
          store.statusText = "The editor changed before the image was inserted. Its link is on the clipboard."
          return
        }
        OrgSyntaxTextEditor.publishPendingTextChanges()
        let text = interaction.text as NSString
        let selection = interaction.selection
        let location = min(max(0, selection.location), text.length)
        let length = min(max(0, selection.length), text.length - location)
        applyInlineEdit(InlineSelectionReplacement(
          text: text.replacingCharacters(in: NSRange(location: location, length: length), with: link),
          selectedRange: NSRange(location: location + (link as NSString).length, length: 0)
        ))
      }
    }
  }

  private func completeDateMention(_ match: WorkspaceDateMentionMatch, with option: WorkspaceDateMentionOption) {
    OrgSyntaxTextEditor.publishPendingTextChanges()
    guard let edit = option.replacement(in: interaction.text, match: match) else { return }
    applyInlineEdit(edit)
  }

  private var sourcePreview: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Label("Preview", systemImage: store.documentPreviewKind.systemImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 8)

        if (store.documentPreviewKind == .slides
          ? store.isRenderingSlidePreview
          : store.isRenderingSourceEditorPreview) {
          WorkspaceActivityIndicator(size: .small)
            .help("Updating preview")
        }

        Menu {
          Picker("Preview kind", selection: documentPreviewPreferenceBinding) {
            Label(
              "Automatic (\(store.inferredDocumentPreviewKind.title))",
              systemImage: OrgDocumentPreviewPreference.automatic.systemImage
            )
              .tag(OrgDocumentPreviewPreference.automatic)
            Label("Document", systemImage: OrgDocumentPreviewPreference.document.systemImage)
              .tag(OrgDocumentPreviewPreference.document)
            Label("Slides", systemImage: OrgDocumentPreviewPreference.slides.systemImage)
              .tag(OrgDocumentPreviewPreference.slides)
              .disabled(!store.canPreviewSlides)
          }
        } label: {
          Image(systemName: store.documentPreviewKind.systemImage)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("\(store.documentPreviewPreferenceLabel) preview")

        Button {
          store.setSourceEditorPreviewPaused(!store.isSourceEditorPreviewPaused)
        } label: {
          Image(systemName: store.isSourceEditorPreviewPaused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.borderless)
        .frame(width: 24, height: 22)
        .help(store.isSourceEditorPreviewPaused ? "Resume live preview" : "Pause live preview")
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .background(WorkspaceDesign.panelFill)

      Divider()

      if store.documentPreviewKind == .slides {
        OrgSlidePreviewPane()
      } else {
        if let html = store.sourceEditorPreviewHTML,
           let source = store.selectedEntrySource {
          OrgHTMLDocumentView(
            html: html,
            source: source,
            corpusRoot: store.corpusRoot,
            searchQuery: nil,
            searchOccurrenceIndex: nil,
            searchOccurrenceCount: 0,
            scrollRequest: sourcePreviewScrollRequest,
            restorationSourceLine: store.documentViewportSourceLine(for: source),
            layout: store.renderedDocumentLayout,
            activateWorkspacePane: { store.activateWorkspacePane(.detail) },
            askAIAboutHeading: { store.askAIChatAboutSourceHeading(at: $0) },
            performEntryAction: { _, _ in },
            peekEncryptedText: { line in Task { await store.peekOrgCrypt(line: line) } },
            allowsEntryContextMenu: false,
            reportStatus: { store.statusText = $0 },
            reportViewportSourceLine: { store.recordDocumentViewportSourceLine($0, for: source) }
          )
        } else if let error = store.sourceEditorPreviewError {
          OrgHTMLRenderFailureView(message: error)
        } else {
          OrgHTMLLoadingView(label: "Preparing preview")
        }
      }
    }
    .background(WorkspaceDesign.surfaceBackground)
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(width: 1)
    }
  }

  private var documentPreviewPreferenceBinding: Binding<OrgDocumentPreviewPreference> {
    Binding(
      get: { store.documentPreviewPreference },
      set: { store.setDocumentPreviewPreference($0) }
    )
  }

  private var sourcePreviewScrollRequest: DetailScrollRequest? {
    sourcePreviewLine.map { DetailScrollRequest(id: $0, target: .sourceLine($0)) }
  }

  private func scheduleSourcePreviewScroll() {
    sourcePreviewScrollTask?.cancel()
    guard store.sourceEditorPresentation == .split,
          let source = store.selectedEntrySource,
          let localLine = sourceCaretLocalLine
    else {
      sourcePreviewLine = nil
      return
    }
    let sourceID = source.id
    let sourceStartLine = source.startLine
    sourcePreviewScrollTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 90_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled,
            store.sourceEditorPresentation == .split,
            store.selectedEntrySource?.id == sourceID
      else { return }
      sourcePreviewLine = sourceStartLine + localLine - 1
    }
  }

  private var sourceEditorCommandBar: some View {
    @Bindable var store = store
    return HStack(spacing: 8) {
      if isProse {
        OrgProseToolbar(controller: prose, showsSidebar: $showsProseSidebar)
      } else {
      HStack(spacing: 6) {
        Menu {
          Button("Heading") { store.requestSourceEditorCommand(.insertHeading) }
          Button("List Item") { store.requestSourceEditorCommand(.insertListItem) }
          Divider()
          Button("Link...") { store.requestSourceEditorCommand(.insertLink) }
          LiveEmbedInsertButton()
          Button("Property...") { store.requestSourceEditorCommand(.insertProperty) }
        } label: {
          Label("Insert", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        Button {
          store.requestSourceEditorCommand(.cycleTodo)
        } label: {
          Label("Cycle TODO", systemImage: "arrow.triangle.2.circlepath")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(width: 26, height: 24)
        .help("Cycle TODO (Command-Option-T)")

        Menu {
          Button("Schedule Today") { store.requestSourceEditorCommand(.scheduleToday) }
          Button("Deadline Today") { store.requestSourceEditorCommand(.deadlineToday) }
          Button("Clear Planning") { store.requestSourceEditorCommand(.clearPlanning) }
        } label: {
          Label("Planning", systemImage: "calendar.badge.clock")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .frame(width: 26, height: 24)
        .fixedSize()
        .help("Planning")
      }
      .fixedSize(horizontal: true, vertical: false)

      Divider()
        .frame(height: 18)

      ControlGroup {
        Button {
          store.requestSourceEditorCommand(.promote)
        } label: {
          Label("Promote", systemImage: "decrease.indent")
        }
        .labelStyle(.iconOnly)
        .help("Promote (Command-Option-Left Arrow)")

        Button {
          store.requestSourceEditorCommand(.demote)
        } label: {
          Label("Demote", systemImage: "increase.indent")
        }
        .labelStyle(.iconOnly)
        .help("Demote (Command-Option-Right Arrow)")
      }
      .fixedSize(horizontal: true, vertical: false)

      Divider()
        .frame(height: 18)

      Menu {
        Button("Toggle Current Heading") { store.requestSourceEditorCommand(.toggleFold) }
        Button("Expand All") { store.requestSourceEditorCommand(.unfoldAll) }
        Divider()
        Button("Previous Heading") { store.requestSourceEditorCommand(.previousHeading) }
        Button("Next Heading") { store.requestSourceEditorCommand(.nextHeading) }
      } label: {
        Label("Outline", systemImage: "list.bullet.indent")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Outline and folding")
      }

      Spacer(minLength: 8)

      if let diagnostic = store.sourceEditorDiagnostics.first {
        Label(
          store.sourceEditorDiagnostics.count == 1
            ? "Line \(diagnostic.line)"
            : "\(store.sourceEditorDiagnostics.count) issues",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(.orange)
        .help(diagnostic.message)
      }

      Divider()
        .frame(height: 18)

      Picker("Editor presentation", selection: $store.sourceEditorPresentation) {
        ForEach(SourceEditorPresentation.allCases) { presentation in
          Image(systemName: presentation.systemImage)
            .tag(presentation)
            .help(presentation.title)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 102)
      .help("Source, live source and HTML preview, or distraction-free Prose")
    }
    .controlSize(.small)
    .padding(.horizontal, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var hasSelection: Bool {
    interaction.selection.length > 0
  }

  private var wikiLinkCompletionMatch: ParagraphWikiLinkCompletionMatch? {
    sourceSelectionSnapshot.flatMap(ParagraphWikiLinkCompletion.match(in:))
  }

  private func insertBacklinkForSelection() {
    guard let edit = WorkspaceStore.backlinkReplacementForSelectedText(
      in: interaction.text,
      range: interaction.selection
    ) else {
      store.statusText = "Select text first"
      return
    }
    applyInlineEdit(edit)
  }

  private func createNodeFromSelection() {
    let text = interaction.text
    let range = interaction.selection
    Task {
      guard let edit = await store.createKnowledgeNodeFromSelection(text: text, range: range) else {
        return
      }
      applyInlineEdit(edit)
    }
  }

  private func resolveWikiLinkCompletion(
    _ match: ParagraphWikiLinkCompletionMatch,
    to node: OrgRoamNodeReference
  ) {
    guard let edit = ParagraphWikiLinkCompletion.replacement(
      in: interaction.text,
      match: match,
      node: node
    ) else {
      return
    }
    applyInlineEdit(edit)
  }

  private func createNodeFromWikiLinkCompletion(_ match: ParagraphWikiLinkCompletionMatch) {
    let text = interaction.text
    Task {
      guard let edit = await store.createKnowledgeNodeFromWikiLinkCompletion(text: text, match: match) else {
        return
      }
      applyInlineEdit(edit)
    }
  }

  private func applyInlineEdit(_ edit: InlineSelectionReplacement) {
    sourceSelectionSnapshot = nil
    interaction.text = edit.text
    interaction.selection = edit.selectedRange
    store.noteSourceEditorLocalTextChanged(edit.text)
  }
}

private struct EntryBodyView: View {
  @Environment(WorkspaceStore.self) private var store
  let location: WorkspaceLocation
  let reportViewportSourceLine: @MainActor (Int?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if store.isLoadingEntrySource && store.selectedEntrySource == nil {
        OrgHTMLLoadingView(label: "Loading source", onCancel: store.cancelSelectedEntryLoading)
      } else if let source = store.selectedEntrySource {
        if store.isEditingEntry {
          OrgSourceEditorWithLinkTools(interaction: store.sourceEditorInteraction)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.editingBlockID != nil {
          ScrollView {
            LegacyStructuredEntryEditorView(source: source)
              .padding(16)
          }
        } else {
          OrgRenderedDocumentPreview(
            source: source,
            loadingLabel: "Rendering preview",
            reportViewportSourceLine: reportViewportSourceLine
          )
        }
      } else if let error = store.selectedEntryRenderError {
        OrgHTMLRenderFailureView(message: error)
      } else {
        fallbackBody(location)
          .padding(16)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .contextMenu {
      Button {
        store.askAIChatAboutCurrentSelection()
      } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      .disabled(!store.canAskAIChatAboutCurrentSelection || store.isLoadingEntrySource)
    }
  }

  @ViewBuilder
  private func fallbackBody(_ location: WorkspaceLocation) -> some View {
    switch location {
    case .agenda(let item):
      Text(Org2Display.cleanBlock(item.body ?? ""))
        .font(.body)
        .textSelection(.enabled)
    case .assigned(let item):
      Text(Org2Display.cleanInline(item.headline))
        .font(.body)
        .textSelection(.enabled)
    case .search(let result):
      Text(Org2Display.cleanInline(result.snippet))
        .font(.body)
        .textSelection(.enabled)
    case .backlink(let backlink):
      Text(Org2Display.cleanInline(backlink.context))
        .font(.body)
        .textSelection(.enabled)
    case .aiChatThreadRecord:
      Text("Source unavailable")
        .font(.callout)
        .foregroundStyle(.secondary)
    case .meeting:
      Text("Meeting source unavailable")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

}

private enum DetailMetadata {
  static func rows(for location: WorkspaceLocation) -> [(String, String)] {
    switch location {
    case .agenda(let item):
      let planning = [item.kind, item.time].compactMap { $0 }.joined(separator: " ")
      let rows: [(String, String)] = [
        ("TODO", item.todo ?? ""),
        ("Planning", planning),
        ("Priority", item.priority.map { "[#\($0)]" } ?? ""),
        ("Tags", item.tags.joined(separator: ", ")),
        ("ID", item.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    case .assigned(let item):
      let rows: [(String, String)] = [
        ("TODO", item.todo ?? ""),
        ("Assignee", item.assignee),
        ("Status", item.status),
        ("Assigned", item.assignedAt ?? ""),
        ("Last Update", item.lastAgentUpdate ?? ""),
        ("Tags", item.tags.joined(separator: ", "))
      ]
      return nonEmptyRows(rows)
    case .search(let result):
      let rows: [(String, String)] = [
        ("TODO", result.todo ?? ""),
        ("Heading", result.heading.map(Org2Display.cleanInline) ?? ""),
        ("Date", result.date ?? ""),
        ("Tags", result.tags.joined(separator: ", ")),
        ("ID", result.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    case .backlink(let backlink):
      return [
        ("Source", Org2Display.cleanInline(backlink.srcTitle)),
        ("Line", "\(backlink.lineForEditor)")
      ]
    case .aiChatThreadRecord(let thread):
      let rows: [(String, String)] = [
        ("Zone", thread.zone),
        ("Modified", thread.modifiedAt.map(dateLabel) ?? ""),
        ("ID", thread.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    case .meeting(let meeting):
      let rows: [(String, String)] = [
        ("Recorded", meeting.recordedAt ?? ""),
        ("Audio", meeting.audioArtifact ?? ""),
        ("System Audio", meeting.systemAudioArtifact ?? ""),
        ("Transcript", meeting.transcriptArtifact ?? ""),
        ("Transcription", meeting.transcriptionStatus ?? ""),
        ("ID", meeting.idValue.map(Org2Display.shortID) ?? "")
      ]
      return nonEmptyRows(rows)
    }
  }

  private static func nonEmptyRows(_ rows: [(String, String)]) -> [(String, String)] {
    rows.filter { !$0.1.isEmpty }
  }

  private static func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

private struct DetailMetadataGrid: View {
  let rows: [(String, String)]

  var body: some View {
    if !rows.isEmpty {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
        ForEach(rows, id: \.0) { row in
          GridRow {
            Text(row.0)
              .font(.caption2.weight(.medium))
              .foregroundStyle(WorkspaceDesign.tertiaryText)
            Text(row.1)
              .font(.caption)
              .foregroundStyle(WorkspaceDesign.secondaryText)
              .textSelection(.enabled)
          }
        }
      }
      .padding(.vertical, 2)
    }
  }
}

private struct NodeContextPane: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    @Bindable var store = store
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Label("Context", systemImage: "sidebar.right")
          .font(.headline)
        Spacer()
        if store.isLoadingBacklinks {
          WorkspaceActivityIndicator(size: .small)
        }
        Button {
          store.toggleNodeContextPane()
        } label: {
          Label("Hide Context", systemImage: "xmark")
        }
        .labelStyle(.iconOnly)
        .help("Hide context")
      }
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.top, 12)
      .padding(.bottom, 8)

      Picker("Context view", selection: $store.nodeContextTab) {
        ForEach(NodeContextTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Context view")
      .frame(maxWidth: .infinity)
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.bottom, 10)

      Divider()

      ScrollView {
        switch store.nodeContextTab {
        case .overview:
          NodeContextOverview()
        case .references:
          NodeContextReferences()
        case .related:
          NodeContextRelated()
        case .connections:
          NodeConnectionsView()
        case .brief:
          NodeContextBrief()
        }
      }
    }
    .background(WorkspaceDesign.barBackground)
  }
}

private struct NodeContextOverview: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      NodeContextStats()

      Button {
        Task { await store.briefCurrentNode() }
      } label: {
        if store.isBuildingNodeBrief {
          Label("Building Brief", systemImage: "hourglass")
        } else {
          Label("Brief This Node", systemImage: "text.bubble")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .disabled(!store.canBriefCurrentNode)
      .help(store.nodeBriefStartsNewThread
        ? "Generate the brief in a new \(store.nodeBriefDestination.title) chat thread."
        : "Generate the brief in the current AI chat thread.")

      NodeBriefOptionsButton()

      if store.backlinkFileGroups.isEmpty {
        NodeContextEmptyText()
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Text("Top Referencing Files")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(store.backlinkFileGroups.prefix(8)) { group in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(group.displayTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
              Spacer(minLength: 0)
              CountPill(count: group.count)
            }
            Text(group.relativePath)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
      }
    }
    .padding(WorkspaceDesign.contentInset)
  }
}

private struct NodeContextReferences: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    if store.backlinkFileGroups.isEmpty {
      NodeContextEmptyText()
        .padding(WorkspaceDesign.contentInset)
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(store.backlinkFileGroups) { group in
          BacklinkFileGroupRow(group: group)
          Divider()
            .padding(.leading, WorkspaceDesign.contentInset)
        }
      }
      .padding(.bottom, 8)
    }
  }
}

private struct NodeContextRelated: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    let items = store.relatedBacklinkNodes
    if items.isEmpty {
      Text("No high-signal related nodes yet. Generic sections like Summary, Details, and Raw transcript are hidden from this list.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(WorkspaceDesign.contentInset)
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
              WorkspaceIconBadge(systemImage: "link")
              VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                  .font(.callout.weight(.medium))
                  .lineLimit(2)
                Text(item.primaryPath)
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
                  .truncationMode(.middle)
                ForEach(item.examples, id: \.self) { example in
                  Text(example)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
              Spacer(minLength: 0)
              VStack(alignment: .trailing, spacing: 4) {
                CountPill(count: item.referenceCount)
                Text(item.fileCount == 1 ? "1 file" : "\(item.fileCount) files")
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .monospacedDigit()
              }
            }
            if let idValue = item.idValue {
              Text(Org2Display.shortID(idValue))
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
          .padding(.horizontal, WorkspaceDesign.contentInset)
          .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
          Divider()
            .padding(.leading, WorkspaceDesign.contentInset)
        }
      }
    }
  }
}

private struct NodeContextBrief: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let artifact = store.currentNodeBriefArtifact {
        HStack(alignment: .top, spacing: 8) {
          WorkspaceIconBadge(systemImage: "doc.text")
          VStack(alignment: .leading, spacing: 3) {
            Text(artifact.title)
              .font(.headline)
            Text(artifact.relativePath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          Spacer(minLength: 0)
        }

        Button {
          store.openCurrentNodeBriefArtifact()
        } label: {
          Label("Open Full Brief", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(WorkspaceActionButtonStyle())

        Divider()

        NodeBriefRenderedPreview(
          artifact: artifact,
          corpusRoot: store.corpusRoot
        )
      } else {
        Text("Generate a source-cited brief for this node, save it as an agent-neutral view artifact, and show it here.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button {
          Task { await store.briefCurrentNode() }
        } label: {
          if store.isBuildingNodeBrief {
            Label("Building Brief", systemImage: "hourglass")
          } else {
            Label("Brief This Node", systemImage: "text.bubble")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .disabled(!store.canBriefCurrentNode)
        .help(store.nodeBriefStartsNewThread
          ? "Generate the brief in a new \(store.nodeBriefDestination.title) chat thread."
          : "Generate the brief in the current AI chat thread.")

        NodeBriefOptionsButton()

        Text("Generated briefs live in views/node-briefs and work with any AI runtime.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(WorkspaceDesign.contentInset)
  }
}

private struct NodeBriefRenderedPreview: View {
  let artifact: NodeBriefArtifact
  let corpusRoot: URL?
  @State private var preparation: NodeBriefPreviewPreparation?

  private var revision: NodeBriefPreviewRevision {
    NodeBriefPreviewRevision(artifact)
  }

  var body: some View {
    if artifact.body.isEmpty {
      Text("Brief artifact is present but has no body after metadata.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if preparation?.revision != revision {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Preparing brief preview…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .task(id: revision) {
        let prepared = await NodeBriefPreviewBuilder.prepare(
          body: artifact.body,
          revision: revision
        )
        guard !Task.isCancelled, prepared.revision == revision else { return }
        preparation = prepared
      }
    } else if preparation?.blocks.isEmpty != false {
      OrgInlineText(artifact.body, font: .callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      LazyVStack(alignment: .leading, spacing: 5) {
        ForEach(preparation?.blocks ?? []) { block in
          NodeBriefCompactBlockView(
            block: block,
            sourceFile: artifact.file,
            corpusRoot: corpusRoot
          )
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

struct NodeBriefPreviewRevision: Hashable, Sendable {
  let relativePath: String
  let modifiedAt: Date?
  let utf8Count: Int

  init(_ artifact: NodeBriefArtifact) {
    relativePath = artifact.relativePath
    modifiedAt = artifact.modifiedAt
    utf8Count = artifact.body.utf8.count
  }
}

struct NodeBriefPreviewPreparation: Sendable {
  let revision: NodeBriefPreviewRevision
  let blocks: [OrgEditableBlock]
}

enum NodeBriefPreviewBuilder {
  nonisolated static func prepare(
    body: String,
    revision: NodeBriefPreviewRevision,
    workThreadObserver: (@Sendable (Bool) -> Void)? = nil
  ) async -> NodeBriefPreviewPreparation {
    await Task.detached(priority: .userInitiated) {
      workThreadObserver?(currentThreadIsMainThread())
      let blocks = OrgEntryRenderer
        .parseEditable(body)
        .filter(OrgRenderedBlockDisplayPolicy.isVisible)
      return NodeBriefPreviewPreparation(revision: revision, blocks: blocks)
    }.value
  }


  private nonisolated static func currentThreadIsMainThread() -> Bool {
    Thread.isMainThread
  }
}

private struct NodeBriefCompactBlockView: View {
  let block: OrgEditableBlock
  let sourceFile: String
  let corpusRoot: URL?

  var body: some View {
    switch block.rendered {
    case .heading(let heading):
      Text(Org2Display.cleanInline(heading.title))
        .font(headingFont(level: heading.level))
        .fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, heading.level <= 1 ? 8 : 5)
    case .paragraph(let text):
      compactInlineText(block.rawText.isEmpty ? text : block.rawText)
        .font(.callout)
        .padding(.vertical, 1)
    case .listItem(let indent, let marker, let checkbox, let text):
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(listMarker(marker: marker, checkbox: checkbox))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(width: 20, alignment: .trailing)
        compactInlineText(text)
          .font(.callout)
      }
      .padding(.leading, CGFloat(max(0, indent)) * 12)
      .padding(.vertical, 2)
    case .quote(let lines):
      compactInlineText(lines.joined(separator: "\n"))
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
          Rectangle()
            .fill(Color.secondary.opacity(0.22))
            .frame(width: 2)
        }
        .padding(.vertical, 4)
    case .planning(let planning):
      HStack(spacing: 6) {
        Text(planning.kind.capitalized)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(planning.value)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 1)
    case .keyword(let key, let value):
      if key.uppercased() != "TITLE" {
        HStack(spacing: 6) {
          Text(key.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
          Text(value)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    case .properties:
      EmptyView()
    case .horizontalRule:
      Divider()
        .padding(.vertical, 8)
    case .blank:
      Spacer()
        .frame(height: 3)
    case .source, .table:
      RenderedBlockView(
        block: block.rendered,
        rawText: block.rawText,
        editableBlock: nil,
        sourceFile: sourceFile,
        corpusRoot: corpusRoot,
        inlineActions: .readOnly
      )
      .font(.callout)
      .padding(.vertical, 4)
    }
  }

  private func compactInlineText(_ raw: String) -> some View {
    OrgInlineText(raw, font: .callout)
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
  }

  private func headingFont(level: Int) -> Font {
    switch level {
    case ...1:
      return .headline
    case 2:
      return .callout
    default:
      return .caption.weight(.semibold)
    }
  }

  private func listMarker(marker: String, checkbox: OrgListCheckbox?) -> String {
    if let checkbox {
      return checkbox.rawMarker
    }
    if marker.range(of: #"^\d+[.)]$"#, options: .regularExpression) != nil {
      return marker
    }
    return "-"
  }
}

private struct NodeContextStats: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    HStack(spacing: 8) {
      StatTile(label: "Files", value: "\(store.backlinkFileCount)")
      StatTile(label: "Refs", value: "\(store.backlinkReferenceCount)")
      StatTile(label: "Related", value: "\(relatedCount)")
    }
  }

  private var relatedCount: Int {
    store.relatedBacklinkNodes.count
  }
}

private struct StatTile: View {
  let label: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value)
        .font(.headline.monospacedDigit())
      Text(label)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius, style: .continuous))
  }
}

private struct CountPill: View {
  let count: Int

  var body: some View {
    Text("\(count)")
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(WorkspaceDesign.controlFill, in: Capsule())
  }
}

private struct NodeContextEmptyText: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    Text(emptyText)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var emptyText: String {
    if store.isLoadingBacklinks { return "Loading backlinks..." }
    if store.backlinks == nil { return "No ID is available for this selection yet." }
    return "No backlinks found for this node."
  }
}

private struct BacklinkFileGroupRow: View {
  @Environment(WorkspaceStore.self) private var store
  let group: BacklinkFileGroup

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        store.toggleBacklinkFileGroup(group)
      } label: {
        HStack(alignment: .center, spacing: 8) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14)
          VStack(alignment: .leading, spacing: 3) {
            Text(group.displayTitle)
              .font(.callout.weight(.medium))
              .lineLimit(1)
            Text(group.relativePath)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
          CountPill(count: group.count)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, WorkspaceDesign.contentInset)
      .padding(.vertical, WorkspaceDesign.rowVerticalPadding)

      if isExpanded {
        ForEach(group.backlinks) { backlink in
          BacklinkRow(backlink: backlink, compact: true)
            .contentShape(Rectangle())
            .onTapGesture {
              store.selectBacklink(backlink)
            }
            .contextMenu {
              WorkspaceLocationContextMenu(
                location: .backlink(backlink),
                select: { store.selectBacklink(backlink) }
              ) {
                Label("Open", systemImage: "link")
              }
            }
          Divider()
            .padding(.leading, WorkspaceDesign.contentInset * 2)
        }
      } else if let first = group.backlinks.first {
        Text(Org2Display.cleanInline(first.context))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .padding(.horizontal, WorkspaceDesign.contentInset + 22)
          .padding(.bottom, 8)
      }
    }
  }

  private var isExpanded: Bool {
    store.expandedBacklinkFileIDs.contains(group.id)
  }
}

private struct BacklinkRow: View {
  @Environment(WorkspaceStore.self) private var store
  let backlink: BacklinkItem
  var compact = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      WorkspaceIconBadge(systemImage: "link")
      VStack(alignment: .leading, spacing: 5) {
        Text(Org2Display.cleanInline(backlink.srcTitle))
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(Org2Display.cleanInline(backlink.context))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(store.relativePath(backlink.file) + ":\(backlink.lineForEditor)")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, compact ? WorkspaceDesign.contentInset + 22 : WorkspaceDesign.contentInset)
    .padding(.vertical, WorkspaceDesign.rowVerticalPadding)
  }
}

private struct HeaderBar<Trailing: View>: View {
  let title: String
  let subtitle: String
  let surface: WorkspaceSurface?
  @ViewBuilder let trailing: Trailing

  init(
    title: String,
    subtitle: String,
    surface: WorkspaceSurface? = nil,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.surface = surface
    self.trailing = trailing()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      headerContent(compact: false)
      headerContent(compact: true)
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
    .padding(.horizontal, WorkspaceDesign.headerHorizontalInset)
    .padding(.vertical, WorkspaceDesign.headerVerticalInset)
    .background(WorkspaceDesign.surfaceBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(WorkspaceDesign.hairline)
        .frame(height: 0.5)
    }
  }

  private func headerContent(compact: Bool) -> some View {
    HStack(alignment: .center, spacing: compact ? 8 : 12) {
      HStack(spacing: 9) {
        if let surface {
          WorkspaceAsteriskMarker(
            color: surface == .approvals ? WorkspaceDesign.signalAccent : WorkspaceDesign.structuralAccent,
            size: 11
          )
          .frame(width: 16, height: 24)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .allowsTightening(true)
            .layoutPriority(1)
          if !compact {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
      .frame(minWidth: compact ? 56 : 92, alignment: .leading)

      Spacer(minLength: compact ? 4 : 0)

      if compact {
        trailing
          .labelStyle(.iconOnly)
      } else {
        trailing
          .labelStyle(.titleAndIcon)
      }

    }
    .frame(minHeight: WorkspaceDesign.paneHeaderRowHeight)
  }
}

struct DetailPaneControlGroup: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    HStack(spacing: 6) {
      Button {
        store.toggleDetailPaneExpansion()
      } label: {
        Label(
          store.isWorkspaceSurfacePaneClosed ? "Restore Document" : "Expand Document",
          systemImage: store.isWorkspaceSurfacePaneClosed
            ? "arrow.down.right.and.arrow.up.left"
            : "arrow.up.left.and.arrow.down.right"
        )
      }
      .labelStyle(.iconOnly)
      .help(store.isWorkspaceSurfacePaneClosed ? "Restore document pane" : "Expand document pane")

      Button {
        store.closeDetailPane()
      } label: {
        Label("Close Document", systemImage: "xmark")
      }
      .labelStyle(.iconOnly)
      .help("Close document pane")
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
  }
}

struct StatusPill: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .bold, design: .rounded))
      .foregroundStyle(statusForeground)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .frame(minWidth: 38)
      .background(statusColor, in: Capsule())
  }

  private var statusColor: Color {
    switch text.uppercased() {
    case "TODO", "QUEUED": WorkspaceDesign.themed(.todo, opacity: 0.13)
    case "PROG", "IN_PROGRESS", "RUNNING": .indigo.opacity(0.14)
    case "WAIT", "HOLD", "PAUSED", "WAITING-APPROVAL", "BLOCKED": .orange.opacity(0.14)
    case "DONE", "COMPLETED": WorkspaceDesign.themed(.done, opacity: 0.14)
    case "FAILED": .red.opacity(0.13)
    case "CANCELLED", "CANCELED": Color.secondary.opacity(0.11)
    default: WorkspaceDesign.subtleFill
    }
  }

  private var statusForeground: Color {
    switch text.uppercased() {
    case "TODO", "QUEUED": WorkspaceDesign.themed(.todo)
    case "PROG", "IN_PROGRESS", "RUNNING": .indigo
    case "WAIT", "HOLD", "PAUSED", "WAITING-APPROVAL", "BLOCKED": .orange
    case "DONE", "COMPLETED": WorkspaceDesign.themed(.done)
    case "FAILED": .red
    case "CANCELLED", "CANCELED": .secondary
    default: .secondary
    }
  }
}

private struct EmptyStateView: View {
  let title: String
  let detail: String
  let action: String?
  let perform: (() -> Void)?

  init(
    title: String,
    detail: String,
    action: String? = nil,
    perform: (() -> Void)? = nil
  ) {
    self.title = title
    self.detail = detail
    self.action = action
    self.perform = perform
  }

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      WorkspaceIconBadge(systemImage: emptyStateIcon, tint: .secondary, fill: WorkspaceDesign.subtleFill)
        .scaleEffect(1.25)
      Text(title)
        .font(.headline)
      if !detail.isEmpty {
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .padding(.horizontal, 24)
      }
      if let action, let perform {
        Button(action) {
          perform()
        }
        .buttonStyle(WorkspaceActionButtonStyle())
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyStateIcon: String {
    if title.localizedCaseInsensitiveContains("agenda") { return "calendar" }
    if title.localizedCaseInsensitiveContains("meeting") { return "waveform.and.mic" }
    if title.localizedCaseInsensitiveContains("result") { return "magnifyingglass" }
    if title.localizedCaseInsensitiveContains("agent") { return "tray" }
    if title.localizedCaseInsensitiveContains("selection") { return "cursorarrow" }
    return "doc.text"
  }
}

enum CommandShortcutReveal {
  static func isActive(for modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
  }
}

private struct CommandShortcutRevealMonitor: ViewModifier {
  @Binding var isCommandPressed: Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        let commandPressed = $isCommandPressed
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
          commandPressed.wrappedValue = CommandShortcutReveal.isActive(for: event.modifierFlags)
          return event
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
        isCommandPressed = false
      }
      .onDisappear {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isCommandPressed = false
      }
  }
}

private struct KeyboardEventMonitor: ViewModifier {
  let handler: (NSEvent, WorkspaceKeyboardShortcutScope) -> Bool
  @State private var monitor: Any?

  func body(content: Content) -> some View {
    content
      .onAppear {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
          if WorkspaceKeyboardEventRouting.defersToNativeSourceEditor(
            event,
            sourceEditorActive: Self.isSourceEditorActive
          ) {
            return event
          }
          let scope = WorkspaceKeyboardEventRouting.scope(
            for: event,
            textInputActive: Self.isTextInputActive
          )
          guard let scope else {
            return event
          }
          return handler(event, scope) ? nil : event
        }
      }
      .onDisappear {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
        monitor = nil
      }
  }

  private static var isTextInputActive: Bool {
    guard let responder = NSApplication.shared.keyWindow?.firstResponder else {
      return false
    }
    return responder is NSTextView || responder is NSTextField
  }

  private static var isSourceEditorActive: Bool {
    NSApplication.shared.keyWindow?.firstResponder is OrgSyntaxTextView
  }
}

enum WorkspaceKeyboardEventRouting {
  static func defersToNativeSourceEditor(_ event: NSEvent, sourceEditorActive: Bool) -> Bool {
    guard sourceEditorActive else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    let key = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()
    // Let the focused source editor handle find and link insertion before workspace shortcuts.
    return modifiers == [.command] && (key == "f" || key == "k")
  }

  static func scope(for event: NSEvent, textInputActive: Bool) -> WorkspaceKeyboardShortcutScope? {
    guard textInputActive else { return .all }
    return isCommandShortcut(event) ? .globalOnly : nil
  }

  static func isCommandShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    return modifiers == [.command] || modifiers == [.command, .shift] || modifiers == [.command, .option]
  }
}

private extension View {
  func commandShortcutRevealMonitor(_ isCommandPressed: Binding<Bool>) -> some View {
    modifier(CommandShortcutRevealMonitor(isCommandPressed: isCommandPressed))
  }

  func keyboardEventMonitor(_ handler: @escaping (NSEvent, WorkspaceKeyboardShortcutScope) -> Bool) -> some View {
    modifier(KeyboardEventMonitor(handler: handler))
  }
}
