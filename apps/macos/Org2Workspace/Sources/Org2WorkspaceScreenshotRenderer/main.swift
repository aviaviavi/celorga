import AppKit
import Org2WorkspaceCore
import SwiftUI
import WebKit

@main
struct Org2WorkspaceScreenshotRenderer {
  static func main() async {
    CelorgaNames.mirrorCelorgaEnvironment()
    do {
      let outputPath = try outputPathArgument()
      let width = Double(CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_WIDTH") ?? "") ?? 1400
      let height = Double(CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_HEIGHT") ?? "") ?? 900
      let scale = Double(CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_SCALE") ?? "") ?? 1
      let verifiesTabs = CommandLine.arguments.contains("--verify-tabs")
      let verifiesChatSelection = CommandLine.arguments.contains("--verify-chat-selection")
      let verifiesCodeCopy = CommandLine.arguments.contains("--verify-code-copy") || verifiesChatSelection

      // ORG2_WORKSPACE_SCREENSHOT_THEME selects a catalog theme ID; the
      // window renders in that theme's own appearance.
      let themeID = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_THEME")?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let theme = themeID.flatMap { $0.isEmpty ? nil : WorkspaceThemeCatalog.theme(id: $0) }
      if let themeID, !themeID.isEmpty, theme == nil {
        throw ScreenshotRenderError.unknownTheme(themeID)
      }
      let isDarkTheme = theme?.appearance == .dark
      _ = await MainActor.run {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)
      }
      let defaults = UserDefaults(suiteName: "org2-workspace-screenshot-\(UUID().uuidString)") ?? .standard
      if let theme {
        defaults.set(isDarkTheme ? "dark" : "light", forKey: "Org2Workspace.appearance.mode.v1")
        defaults.set(
          theme.appearance == .light ? theme.id : WorkspaceThemeCatalog.defaultLightID,
          forKey: "Org2Workspace.appearance.lightTheme.v1"
        )
        defaults.set(
          theme.appearance == .dark ? theme.id : WorkspaceThemeCatalog.defaultDarkID,
          forKey: "Org2Workspace.appearance.darkTheme.v1"
        )
      }
      if verifiesCodeCopy {
        defaults.set(true, forKey: "Org2Workspace.openOrgLaunchGuideCompleted.v1")
      }
      let store = await MainActor.run {
        WorkspaceStore(defaults: defaults)
      }
      await store.bootstrap()
      await MainActor.run {
        if let rawAgendaMode = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_AGENDA_MODE"),
           let agendaMode = AgendaMode(rawValue: rawAgendaMode) {
          store.agendaMode = agendaMode
        }
        let rawContextTab = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_CONTEXT_TAB")?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        if let rawContextTab,
           let contextTab = NodeContextTab(rawValue: rawContextTab) {
          store.isNodeContextPanePresented = true
          store.nodeContextTab = contextTab
        }
      }
      // The selection was made before the Context pane opened, so request its
      // backlinks explicitly instead of relying on the selection-change load.
      if let contextLocation = await MainActor.run(body: {
        store.isNodeContextPanePresented ? store.selectedLocation : nil
      }) {
        await store.loadBacklinks(for: contextLocation)
      }
      if verifiesCodeCopy {
        await MainActor.run {
          store.selectedSurface = .aiChat
          store.aiChatMessages = [
            AIChatMessage(
              role: .assistant,
              content: """
              Added in Celorga Preview:

              - Subtle press feedback.
              - Smooth thread settlement and reopening.
              - Approval cards fade out as they resolve.
              - Reduce Motion support.

              Select across this paragraph and the list above.

              #+begin_src swift
              let answer = 42
              print(answer)
              #+end_src

              #+begin_src sh
              celorga lint --recursive
              #+end_src
              """,
              changeSummary: AIChatCorpusChangeSummary(files: [
                AIChatCorpusFileChange(
                  relativePath: "apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/AIChatTranscriptDocument.swift",
                  status: .modified,
                  insertions: 18,
                  deletions: 4
                )
              ]),
              responseTrace: AIChatResponseTrace(
                reasoning: "Preserve the established message interface while keeping one selectable transcript document.",
                activities: [
                  AIChatRunActivity(
                    id: "read", runID: "preview", kind: .tool,
                    title: "Read chat presentation", detail: "AIChatViews.swift",
                    status: .succeeded
                  ),
                  AIChatRunActivity(
                    id: "test", runID: "preview", kind: .tool,
                    title: "Run selection checks", detail: "9 tests passed",
                    status: .succeeded
                  ),
                ]
              )
            )
          ]
          if verifiesChatSelection {
            store.aiChatMessages.append(AIChatMessage(role: .user, content: "Select across this message boundary."))
            store.aiChatMessages.append(AIChatMessage(role: .assistant, content: "The third message remains in the same document."))
          }
        }
      }
      let verificationTabIDs: [WorkspaceTab.ID] = await MainActor.run {
        guard verifiesTabs else { return [] }
        let firstTabID = store.selectedWorkspaceTabID
        let secondTabID = store.newWorkspaceTab()
        let thirdTabID = store.newWorkspaceTab()
        return [firstTabID, secondTabID, thirdTabID]
      }
      for _ in 0..<100 {
        let renderState = await MainActor.run {
          (
            hasSelection: store.selectedLocation != nil,
            hasHTML: store.selectedEntryHTML != nil,
            renderError: store.selectedEntryRenderError
          )
        }
        if !renderState.hasSelection || renderState.hasHTML || renderState.renderError != nil {
          break
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      if CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_EDIT_SOURCE") != nil {
        await MainActor.run {
          store.beginEditingCurrentScope()
          if CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_SPLIT_PREVIEW") != nil {
            store.sourceEditorPresentation = .split
            store.scheduleSourceEditorPreview(immediate: true)
          }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }

      try await renderScreenshot(
        store: store,
        outputPath: outputPath,
        width: width,
        height: height,
        scale: scale,
        verificationTabIDs: verificationTabIDs,
        verifiesCodeCopy: verifiesCodeCopy
      )
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func outputPathArgument() throws -> String {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--out"),
          args.indices.contains(index + 1),
          !args[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ScreenshotRenderError.missingOutputPath
    }
    return args[index + 1]
  }

  @MainActor
  private static func renderScreenshot(
    store: WorkspaceStore,
    outputPath: String,
    width: Double,
    height: Double,
    scale: Double,
    verificationTabIDs: [WorkspaceTab.ID],
    verifiesCodeCopy: Bool
  ) async throws {
    let content = ZStack {
      Color(nsColor: .windowBackgroundColor)
      ContentView()
        .environment(store)
        .workspaceThemed()
        .frame(width: width, height: height)
    }
    .frame(width: width, height: height)
    .preferredColorScheme(store.appearanceMode.colorScheme)
    let hostingView = NSHostingView(rootView: content)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    hostingView.frame = bounds
    hostingView.setFrameSize(NSSize(width: width, height: height))
    hostingView.autoresizingMask = [.width, .height]

    let window = NSWindow(
      contentRect: bounds,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let isPlainCapture = verificationTabIDs.isEmpty && !verifiesCodeCopy
    window.setFrame(
      isPlainCapture ? pointerFreeFrame(size: bounds.size) : bounds,
      display: false
    )
    window.contentView = hostingView
    // Plain captures must not pick up hover state from wherever the real
    // pointer happens to be; interaction checks keep normal event delivery.
    window.ignoresMouseEvents = isPlainCapture
    window.makeKeyAndOrderFront(nil)
    // HTML-backed document panes are created only after the SwiftUI hierarchy is
    // attached to a window. Give WKWebView enough time to finish its first paint
    // so deterministic docs captures include the selected document body.
    let defaultSettleNanoseconds: UInt64 = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_EDIT_SOURCE") == nil
      ? 2_000_000_000
      : 2_500_000_000
    // Scenes with extra panes (such as Context) can need longer for the
    // document web view to repaint after layout.
    let renderSettleNanoseconds = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_SETTLE_MS")
      .flatMap(UInt64.init)
      .map { $0 * 1_000_000 } ?? defaultSettleNanoseconds
    try? await Task.sleep(nanoseconds: renderSettleNanoseconds)
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    await waitForVisibleContent(in: hostingView, store: store)
    await collapsePropertyDrawersIfRequested(in: hostingView)
    let startWorkSheet = await prepareStartWorkCapture(in: hostingView, window: window, store: store)
    hostingView.displayIfNeeded()

    if verifiesCodeCopy {
      for _ in 0..<200 {
        if let webView = firstWebView(in: hostingView),
           (try? await webView.evaluateJavaScript("document.querySelectorAll('.chat-copy-code').length")) as? Int == 2 { break }
        try await Task.sleep(for: .milliseconds(50))
        hostingView.layoutSubtreeIfNeeded()
      }
      try await verifyCodeCopy(in: hostingView)
      if CommandLine.arguments.contains("--verify-chat-selection"), let webView = firstWebView(in: hostingView) {
        let selected = try await webView.evaluateJavaScript("""
          const first=document.querySelector('main > p');
          const last=document.querySelector('article:last-child main');
          const range=document.createRange(); range.setStart(first,0); range.setEndAfter(last);
          getSelection().removeAllRanges(); getSelection().addRange(range); getSelection().toString();
          """) as? String
        guard selected?.contains("Reduce Motion support.") == true,
              selected?.contains("Select across this message boundary.") == true,
              selected?.contains("The third message remains in the same document.") == true else {
          throw ScreenshotRenderError.codeCopyVerificationFailed("Native selection did not span all three messages")
        }
      }
    }
    if !verificationTabIDs.isEmpty {
      try await verifyTabInteractions(
        in: window,
        hostingView: hostingView,
        store: store,
        expectedTabIDs: verificationTabIDs
      )
    }
    guard var bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
      throw ScreenshotRenderError.renderFailed
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

    // Scenes can show more than one web view (for example AI Chat beside a
    // document), and cached view drawing leaves each of them blank.
    await collapsePropertyDrawersIfRequested(in: hostingView)
    for webView in visibleWebViews(in: hostingView) {
      let configuration = WKSnapshotConfiguration()
      configuration.rect = webView.bounds
      if let webSnapshot = try? await webView.takeSnapshot(configuration: configuration),
         let composedBitmap = compose(
           base: bitmap,
           webSnapshot: webSnapshot,
           webFrame: webView.convert(webView.bounds, to: hostingView),
           size: bounds.size
         ) {
        bitmap = composedBitmap
      }
    }
    if let sheet = startWorkSheet, let composedBitmap = composeSheet(base: bitmap, sheet: sheet, size: bounds.size) {
      bitmap = composedBitmap
    }
    let expectedPixelWidth = max(1, Int(width * scale))
    let expectedPixelHeight = max(1, Int(height * scale))
    if bitmap.pixelsWide != expectedPixelWidth || bitmap.pixelsHigh != expectedPixelHeight {
      guard let normalizedBitmap = normalize(
        base: bitmap,
        size: bounds.size,
        pixelWidth: expectedPixelWidth,
        pixelHeight: expectedPixelHeight
      ) else {
        throw ScreenshotRenderError.renderFailed
      }
      bitmap = normalizedBitmap
    }
    bitmap.size = bounds.size
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw ScreenshotRenderError.renderFailed
    }

    let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try png.write(to: outputURL)
  }

  /// Start work captures for the homepage. `ORG2_WORKSPACE_SCREENSHOT_START_WORK_HOVER`
  /// shows the rendered heading's own hover button for the named TODO, and
  /// `ORG2_WORKSPACE_SCREENSHOT_START_WORK_SHEET` opens the real Start Work
  /// sheet for it. A sheet is its own window, so it is returned for
  /// compositing over the main window.
  /// `ORG2_WORKSPACE_SCREENSHOT_COLLAPSE_PROPERTIES` clicks each open
  /// Properties drawer's summary, as a reader folding them would. The app does
  /// not persist fold state, so this runs again just before the snapshot in
  /// case the document re-rendered.
  @MainActor
  private static func collapsePropertyDrawersIfRequested(in hostingView: NSView) async {
    guard CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_COLLAPSE_PROPERTIES") != nil else { return }
    var collapsed = 0
    for webView in visibleWebViews(in: hostingView) {
      let count = try? await webView.evaluateJavaScript("""
        (() => {
          const open = [...document.querySelectorAll('details.org2-properties-drawer[open] > summary')];
          open.forEach(summary => summary.click());
          return open.length;
        })()
        """) as? Int
      collapsed += count ?? 0
    }
    if collapsed > 0 {
      try? await Task.sleep(for: .milliseconds(250))
      hostingView.layoutSubtreeIfNeeded()
    }
  }

  @MainActor
  private static func prepareStartWorkCapture(
    in hostingView: NSView,
    window: NSWindow,
    store: WorkspaceStore
  ) async -> NSBitmapImageRep? {
    let hover = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_START_WORK_HOVER")
    let sheetHeading = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_START_WORK_SHEET")
    guard let heading = hover ?? sheetHeading, !heading.isEmpty else { return nil }
    var line: Int?
    for webView in visibleWebViews(in: hostingView) {
      let script = """
        (() => {
          const title = \(jsonString(heading));
          const headline = [...document.querySelectorAll('details.org2-headline[data-org2-start-line]')]
            .find(node => node.querySelector(':scope > .org2-headline-summary')?.textContent.includes(title));
          if (!headline) return 0;
          const line = Number(headline.dataset.org2StartLine);
          // The pointer is over this heading: show its hover button, hovered.
          // (The document's CSP blocks new style elements; CSSOM styles apply.)
          // Document updates reinstall these buttons, so restyle after each one.
          const hover = () => {
            const button = document.querySelector(`details.org2-headline[data-org2-start-line="${line}"] > .org2-headline-summary > .org2-heading-start-work`);
            if (!button) return;
            // Offscreen windows do not advance CSS transitions.
            button.style.setProperty('transition', 'none', 'important');
            button.style.setProperty('opacity', '1', 'important');
            button.style.setProperty('color', 'var(--org2-accent)');
            button.style.setProperty('background', 'color-mix(in srgb, var(--org2-accent) 9%, transparent)');
          };
          const install = window.__org2InstallStartWork;
          if (install && !install.__docsHover) {
            window.__org2InstallStartWork = (enabled) => { install(enabled); hover(); };
            window.__org2InstallStartWork.__docsHover = true;
          }
          hover();
          return line;
        })()
        """
      // Cached surfaces can keep more than one document web view alive.
      if let found = try? await webView.evaluateJavaScript(script) as? Int, found > 0 {
        line = line ?? found
      }
    }
    try? await Task.sleep(for: .milliseconds(300))
    guard sheetHeading != nil, let line else { return nil }
    store.startWork(onHeadingAt: line)
    for _ in 0..<50 {
      if window.attachedSheet != nil || store.pendingStartWorkRequest == nil { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    try? await Task.sleep(for: .milliseconds(800))
    guard let sheetView = window.attachedSheet?.contentView else { return nil }
    sheetView.layoutSubtreeIfNeeded()
    guard let bitmap = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) else { return nil }
    sheetView.cacheDisplay(in: sheetView.bounds, to: bitmap)
    return bitmap
  }

  private static func jsonString(_ value: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
    return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
  }

  /// Draws a captured sheet where AppKit presents it: centered at the top of
  /// the window, below the tab bar, with the system sheet shadow.
  @MainActor
  private static func composeSheet(base: NSBitmapImageRep, sheet: NSBitmapImageRep, size: NSSize) -> NSBitmapImageRep? {
    drawScaled(pixelWidth: base.pixelsWide, pixelHeight: base.pixelsHigh, size: size) {
      let baseImage = NSImage(size: size)
      baseImage.addRepresentation(base)
      baseImage.draw(in: NSRect(origin: .zero, size: size))
      let sheetSize = sheet.size
      let frame = NSRect(
        x: (size.width - sheetSize.width) / 2,
        y: size.height - 52 - sheetSize.height,
        width: sheetSize.width,
        height: sheetSize.height
      )
      let path = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
      NSGraphicsContext.saveGraphicsState()
      let shadow = NSShadow()
      shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
      shadow.shadowBlurRadius = 28
      shadow.shadowOffset = NSSize(width: 0, height: -10)
      shadow.set()
      NSColor.windowBackgroundColor.setFill()
      path.fill()
      NSGraphicsContext.restoreGraphicsState()
      NSGraphicsContext.saveGraphicsState()
      path.addClip()
      let sheetImage = NSImage(size: sheetSize)
      sheetImage.addRepresentation(sheet)
      sheetImage.draw(in: frame)
      NSGraphicsContext.restoreGraphicsState()
      NSColor.black.withAlphaComponent(0.12).setStroke()
      path.lineWidth = 0.5
      path.stroke()
    }
  }

  @MainActor
  private static func verifyCodeCopy(in hostingView: NSView) async throws {
    guard let webView = firstWebView(in: hostingView),
      (try await webView.evaluateJavaScript("document.querySelectorAll('.chat-copy-code').length")) as? Int == 2 else {
      throw ScreenshotRenderError.codeCopyVerificationFailed("Expected two document copy controls")
    }
    let pasteboard = NSPasteboard.general
    let saved = pasteboard.pasteboardItems?.map { item in
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    } ?? []
    defer {
      pasteboard.clearContents()
      let items = saved.map { values in
        let item = NSPasteboardItem()
        for (type, data) in values { item.setData(data, forType: type) }
        return item
      }
      pasteboard.writeObjects(items)
    }
    try await webView.evaluateJavaScript("document.querySelector('.chat-copy-code').click(); null;")
    for _ in 0..<40 {
      if pasteboard.string(forType: .string) == "let answer = 42\nprint(answer)" { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    guard pasteboard.string(forType: .string) == "let answer = 42\nprint(answer)" else {
      throw ScreenshotRenderError.codeCopyVerificationFailed("The document control did not copy the exact source block")
    }
    FileHandle.standardError.write(Data("Verified document code copy and exact clipboard payload\n".utf8))
  }

  @MainActor
  private static func descendantButtons(in view: NSView) -> [NSButton] {
    view.subviews.flatMap { child in
      (child as? NSButton).map { [$0] } ?? descendantButtons(in: child)
    }
  }

  @MainActor
  private static func verifyTabInteractions(
    in window: NSWindow,
    hostingView: NSView,
    store: WorkspaceStore,
    expectedTabIDs: [WorkspaceTab.ID]
  ) async throws {
    guard expectedTabIDs.count == 3 else {
      throw ScreenshotRenderError.tabVerificationFailed("expected three fixture tabs")
    }
    var tabViews = workspaceTabViews(in: hostingView)
    guard tabViews.count == expectedTabIDs.count else {
      throw ScreenshotRenderError.tabVerificationFailed(
        "rendered \(tabViews.count) tab targets instead of \(expectedTabIDs.count)"
      )
    }

    let firstTabHitView = hitView(atCenterOf: tabViews[0], in: window)
    guard firstTabHitView === tabViews[0] else {
      throw ScreenshotRenderError.tabVerificationFailed(
        "the visible first tab does not own its hit-test area"
      )
    }
    sendClick(to: tabViews[0], in: window)
    await settleTabEvents()
    guard store.selectedWorkspaceTabID == expectedTabIDs[0] else {
      throw ScreenshotRenderError.tabVerificationFailed("an AppKit mouse click did not select the first tab")
    }

    tabViews = workspaceTabViews(in: hostingView)
    let originalFrames = tabViews.map { $0.convert($0.bounds, to: nil) }
    let dragDestination = beginDrag(from: tabViews[0], to: tabViews[2], in: window)
    await settleTabEvents(durationNanoseconds: 180_000_000)
    let liveFrames = tabViews.map { $0.convert($0.bounds, to: nil) }
    guard abs(liveFrames[0].midX - dragDestination.x) < 1,
          abs(liveFrames[1].minX - originalFrames[0].minX) < 1,
          abs(liveFrames[2].minX - originalFrames[1].minX) < 1
    else {
      throw ScreenshotRenderError.tabVerificationFailed(
        "the dragged tab or its neighbors did not move before mouse-up"
      )
    }
    guard store.workspaceTabs.map(\.id) == expectedTabIDs else {
      throw ScreenshotRenderError.tabVerificationFailed("the tab order committed before drop")
    }
    finishDrag(tabViews[0], at: dragDestination, in: window)
    await settleTabEvents(durationNanoseconds: 250_000_000)
    let reorderedTabIDs = store.workspaceTabs.map(\.id)
    guard reorderedTabIDs == [expectedTabIDs[1], expectedTabIDs[2], expectedTabIDs[0]] else {
      throw ScreenshotRenderError.tabVerificationFailed(
        "a real window drag produced \(reorderedTabIDs.map(\.uuidString))"
      )
    }

    tabViews = workspaceTabViews(in: hostingView)
    guard let closeButton = tabViews[2].subviews.compactMap({ $0 as? NSButton }).first else {
      throw ScreenshotRenderError.tabVerificationFailed("the selected tab has no native close button")
    }
    guard hitView(atCenterOf: closeButton, in: window) === closeButton else {
      throw ScreenshotRenderError.tabVerificationFailed("the visible close button does not own its hit-test area")
    }
    sendClick(to: closeButton, in: window)
    await settleTabEvents()
    guard store.workspaceTabs.map(\.id) == [expectedTabIDs[1], expectedTabIDs[2]] else {
      throw ScreenshotRenderError.tabVerificationFailed("the native close action did not close the selected tab")
    }

    FileHandle.standardError.write(Data("Verified integrated tab click, live drag reordering, drop, and native close action\n".utf8))
  }

  @MainActor
  private static func workspaceTabViews(in view: NSView) -> [NSView] {
    var matches: [NSView] = []
    for child in view.subviews {
      if NSStringFromClass(type(of: child)).hasSuffix(".WorkspaceTabInteractionView") {
        matches.append(child)
      }
      matches.append(contentsOf: workspaceTabViews(in: child))
    }
    return matches.sorted {
      $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
    }
  }

  @MainActor
  private static func hitView(atCenterOf view: NSView, in window: NSWindow) -> NSView? {
    guard let contentView = window.contentView else { return nil }
    let windowPoint = view.convert(
      NSPoint(x: view.bounds.midX, y: view.bounds.midY),
      to: nil
    )
    return contentView.hitTest(windowPoint)
  }

  @MainActor
  private static func sendClick(to view: NSView, in window: NSWindow) {
    let location = view.convert(
      NSPoint(x: view.bounds.midX, y: view.bounds.midY),
      to: nil
    )
    if let button = view as? NSButton {
      button.performClick(nil)
      return
    }
    view.mouseDown(with: mouseEvent(.leftMouseDown, at: location, in: window, eventNumber: 1))
    view.mouseUp(with: mouseEvent(.leftMouseUp, at: location, in: window, eventNumber: 2))
  }

  @MainActor
  private static func beginDrag(from source: NSView, to target: NSView, in window: NSWindow) -> NSPoint {
    let start = source.convert(
      NSPoint(x: source.bounds.midX, y: source.bounds.midY),
      to: nil
    )
    let destination = target.convert(
      NSPoint(x: target.bounds.midX - 30, y: target.bounds.midY),
      to: nil
    )
    let threshold = NSPoint(x: start.x + 8, y: start.y)

    source.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: window, eventNumber: 3))
    source.mouseDragged(with: mouseEvent(.leftMouseDragged, at: threshold, in: window, eventNumber: 4))
    source.mouseDragged(with: mouseEvent(.leftMouseDragged, at: destination, in: window, eventNumber: 5))
    return destination
  }

  @MainActor
  private static func finishDrag(_ source: NSView, at location: NSPoint, in window: NSWindow) {
    source.mouseUp(with: mouseEvent(.leftMouseUp, at: location, in: window, eventNumber: 6))
  }

  @MainActor
  private static func mouseEvent(
    _ type: NSEvent.EventType,
    at location: NSPoint,
    in window: NSWindow,
    eventNumber: Int
  ) -> NSEvent {
    NSEvent.mouseEvent(
      with: type,
      location: location,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: type == .leftMouseUp ? 0 : 1
    )!
  }

  @MainActor
  private static func settleTabEvents(durationNanoseconds: UInt64 = 100_000_000) async {
    try? await Task.sleep(nanoseconds: durationNanoseconds)
  }

  // SwiftUI hover tracking follows the live pointer even when the window
  // ignores mouse events, so keep the capture window out from under it. Prefer
  // the origin; otherwise sit just beside the pointer on whichever side leaves
  // the most of the window on screen (so web content keeps rendering).
  @MainActor
  private static func pointerFreeFrame(size: NSSize) -> NSRect {
    let pointer = NSEvent.mouseLocation
    let origin = NSRect(origin: .zero, size: size)
    guard origin.insetBy(dx: -8, dy: -8).contains(pointer) else { return origin }
    let candidates = [
      NSRect(x: pointer.x + 8, y: 0, width: size.width, height: size.height),
      NSRect(x: pointer.x - 8 - size.width, y: 0, width: size.width, height: size.height),
      NSRect(x: 0, y: pointer.y + 8, width: size.width, height: size.height),
      NSRect(x: 0, y: pointer.y - 8 - size.height, width: size.width, height: size.height),
    ]
    func visibleArea(_ frame: NSRect) -> CGFloat {
      NSScreen.screens.reduce(0) { total, screen in
        let overlap = screen.frame.intersection(frame)
        return total + (overlap.isNull ? 0 : overlap.width * overlap.height)
      }
    }
    return candidates.max { visibleArea($0) < visibleArea($1) } ?? origin
  }

  // A fixed settle delay can still capture a blank document pane or a
  // spinning Action items panel when a scene opens extra panes. Poll (up to
  // ten seconds) until async panels have loaded and every visible web view has
  // painted a non-empty body.
  @MainActor
  private static func waitForVisibleContent(in hostingView: NSView, store: WorkspaceStore) async {
    for _ in 0..<100 {
      hostingView.layoutSubtreeIfNeeded()
      var ready = !store.isLoadingEntityActionItems
      if ready {
        for webView in visibleWebViews(in: hostingView) {
          let length = try? await webView.evaluateJavaScript(
            "document.readyState === 'complete' && document.body ? document.body.innerText.trim().length : 0"
          ) as? Int
          if webView.isLoading || (length ?? 0) == 0 {
            ready = false
            break
          }
        }
      }
      if ready { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    // Let the final layout paint once more before the bitmap is cached.
    try? await Task.sleep(for: .milliseconds(500))
    hostingView.layoutSubtreeIfNeeded()
  }

  @MainActor
  private static func visibleWebViews(in view: NSView) -> [WKWebView] {
    if view.isHidden || view.alphaValue == 0 { return [] }
    if let webView = view as? WKWebView {
      return webView.bounds.width > 0 && webView.bounds.height > 0 ? [webView] : []
    }
    var webViews: [WKWebView] = []
    for subview in view.subviews {
      webViews.append(contentsOf: visibleWebViews(in: subview))
    }
    return webViews
  }

  @MainActor
  private static func firstWebView(in view: NSView) -> WKWebView? {
    if let webView = view as? WKWebView { return webView }
    for subview in view.subviews {
      if let webView = firstWebView(in: subview) { return webView }
    }
    return nil
  }

  @MainActor
  private static func compose(
    base: NSBitmapImageRep,
    webSnapshot: NSImage,
    webFrame: NSRect,
    size: NSSize
  ) -> NSBitmapImageRep? {
    // Keep the cached view's backing resolution so 2x captures stay 2x after
    // the web snapshot is composited over it.
    drawScaled(pixelWidth: base.pixelsWide, pixelHeight: base.pixelsHigh, size: size) {
      let baseImage = NSImage(size: size)
      baseImage.addRepresentation(base)
      baseImage.draw(in: NSRect(origin: .zero, size: size))
      let bitmapWebFrame = NSRect(
        x: webFrame.minX,
        y: size.height - webFrame.maxY,
        width: webFrame.width,
        height: webFrame.height
      )
      webSnapshot.draw(in: bitmapWebFrame)
    }
  }

  @MainActor
  private static func normalize(
    base: NSBitmapImageRep,
    size: NSSize,
    pixelWidth: Int,
    pixelHeight: Int
  ) -> NSBitmapImageRep? {
    drawScaled(pixelWidth: pixelWidth, pixelHeight: pixelHeight, size: size) {
      let baseImage = NSImage(size: size)
      baseImage.addRepresentation(base)
      baseImage.draw(in: NSRect(origin: .zero, size: size))
    }
  }

  /// Draws point-space content into a bitmap of the requested pixel size.
  /// A bitmap-backed graphics context uses pixel coordinates, so the point
  /// geometry must be scaled explicitly or it lands in the lower-left corner.
  @MainActor
  static func drawScaled(
    pixelWidth: Int,
    pixelHeight: Int,
    size: NSSize,
    draw: () -> Void
  ) -> NSBitmapImageRep? {
    guard size.width > 0, size.height > 0,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: max(1, pixelWidth),
        pixelsHigh: max(1, pixelHeight),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
      return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(
      x: CGFloat(bitmap.pixelsWide) / size.width,
      y: CGFloat(bitmap.pixelsHigh) / size.height
    )
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = size
    return bitmap
  }

}

private enum ScreenshotRenderError: LocalizedError {
  case missingOutputPath
  case renderFailed
  case tabVerificationFailed(String)
  case codeCopyVerificationFailed(String)
  case unknownTheme(String)

  var errorDescription: String? {
    switch self {
    case .missingOutputPath:
      return "Usage: Org2WorkspaceScreenshotRenderer --out PATH"
    case .renderFailed:
      return "Could not render Celorga screenshot"
    case .tabVerificationFailed(let reason):
      return "Tab interaction verification failed: \(reason)"
    case .codeCopyVerificationFailed(let reason):
      return "Code copy interaction verification failed: \(reason)"
    case .unknownTheme(let id):
      return "Unknown ORG2_WORKSPACE_SCREENSHOT_THEME \(id)"
    }
  }
}
