import AppKit
import SwiftUI

private struct WorkspaceTabIDEnvironmentKey: EnvironmentKey {
  static let defaultValue: WorkspaceTab.ID? = nil
}

extension EnvironmentValues {
  var workspaceTabID: WorkspaceTab.ID? {
    get { self[WorkspaceTabIDEnvironmentKey.self] }
    set { self[WorkspaceTabIDEnvironmentKey.self] = newValue }
  }
}

@MainActor
func performAfterSwiftUIViewUpdate(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  Task { @MainActor in
    await Task.yield()
    guard !Task.isCancelled else { return }
    operation()
  }
}

@MainActor
func performAfterSwiftUIViewUpdate(
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
      .sheet(item: $store.activeSecretRequest) { request in
        SecretRequestSheet(request: request)
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
final class WorkspaceAccessibilityPressView: NSView {
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

struct WorkspaceAccessibilityPressTarget: NSViewRepresentable {
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
        case .calendar:
          CalendarView()
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
        case .people:
          PeopleCompaniesView(kind: .people)
        case .companies:
          PeopleCompaniesView(kind: .companies)
        case .pluginApp:
          PluginAppSurfaceView()
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
        subtitle: "Read-only tasks from Codex",
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

  private func isSidebarSectionExpanded(_ section: SidebarSectionID) -> Bool {
    !SidebarSectionCollapseState(storage: collapsedSidebarSectionsStorage).isCollapsed(section)
  }

  var body: some View {
    let pinnedCorpusFiles = store.pinnedCorpusFiles
    VStack(spacing: 0) {
      SidebarHeader(showsCommandShortcuts: showsCommandShortcuts)
        .task(id: store.corpusRoot?.standardizedFileURL.path) {
          await store.loadWorkspaceAppsIfNeeded()
        }

      List {
        let sidebarSurfaces = WorkspaceSurface.sidebarCases(
          enabledApps: store.enabledWorkspaceAppIDs
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

            ForEach(store.enabledPluginSurfaces) { surface in
              Button {
                store.openPluginSurface(surface)
              } label: {
                SidebarAgentWorkPageRow(
                  title: surface.title,
                  systemImage: surface.symbol,
                  shortcut: "",
                  showsCommandShortcut: false,
                  notificationCount: 0
                )
                .modifier(ReadableListSelectionModifier(
                  isSelected: store.selectedSurface == .pluginApp && store.selectedPluginSurface == surface,
                  verticalPadding: 4
                ))
              }
              .buttonStyle(.plain)
              .help("\(surface.title), from the \(surface.appTitle) plugin")
              .accessibilityIdentifier("sidebar-plugin-surface-\(surface.id)")
            }

            WorkspaceAppsSidebarFooter()
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
                  Text(CorpusFileTreePresentation.rootTitle(corpusRoot: store.corpusRoot))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                // Partition once per render; each group is read several times.
                let threadGroups = store.partitionAIChatThreadSummariesByRunning(chatThreads)
                let runningChatThreads = threadGroups.running
                let recentChatThreads = threadGroups.idle
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

                let actionableAutomationCount = store.actionableAutomationAIChatThreadCount
                if actionableAutomationCount > 0 {
                  SidebarSettleAutomationThreadsRow(
                    count: actionableAutomationCount
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
