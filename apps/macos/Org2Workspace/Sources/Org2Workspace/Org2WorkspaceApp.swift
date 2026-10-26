import AppKit
import Carbon
import Org2WorkspaceCore
import Org2WorkspaceDiagnosticsCore
import SwiftUI

@main
struct Org2WorkspaceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var store = WorkspaceStore()
  @StateObject private var mobileRemote = MobileRemoteCoordinator()
  @StateObject private var softwareUpdates = SoftwareUpdateController()
  @StateObject private var attention = AttentionDigestMonitor()
  private let globalCaptureHotKey = GlobalCaptureHotKey()

  init() {
    CelorgaNames.mirrorCelorgaEnvironment()
    NSWindow.allowsAutomaticWindowTabbing = false
    AppIconInstaller.install()

    if CommandLine.arguments.contains("--smoke-test") {
      SmokeTest.run()
    }

    if CommandLine.arguments.contains("--quit-after-launch") {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
        exit(0)
      }
    }
  }

  var body: some Scene {
    WindowGroup(WorkspaceProductIdentity.displayName) {
      ContentView()
        .environment(store)
        .workspaceThemed()
        .preferredColorScheme(store.appearanceMode.colorScheme)
        .frame(minWidth: 1080, minHeight: 680)
        .background(WorkspaceWindowConfigurator())
        .onAppear {
          appDelegate.hasActiveWork = { [store] in store.hasWorkInProgressForTermination }
          appDelegate.runningAgentTurnCount = { [store] in store.aiChatRunningTurnCountOnCurrentHost }
          appDelegate.drainAgentTurns = { [store] in
            store.beginAIChatDrain()
            store.statusText = "Quitting when running agent turns finish…"
            _ = await store.waitForAIChatTurnsToFinish(timeout: 3_600)
          }
          appDelegate.prepareForTermination = { [store] in
            await store.prepareForTermination()
          }
          NSApplication.shared.setActivationPolicy(.regular)
          NSApplication.shared.activate(ignoringOtherApps: true)
          AppIconInstaller.install()
          let status = globalCaptureHotKey.register {
            NSApplication.shared.activate(ignoringOtherApps: true)
            store.presentCapturePanel()
          }
          if status != noErr {
            store.statusText = "Global capture shortcut unavailable (\(status))"
          }
          let isActive = NSApplication.shared.isActive
          store.setWorkspaceRealtimeRefreshActive(isActive)
          store.setRunReviewAutoRefreshActive(isActive, refreshImmediately: false)
          mobileRemote.attach(to: store)
          mobileRemote.startIfConfigured()
          softwareUpdates.checkAtLaunchIfEnabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
          store.setWorkspaceRealtimeRefreshActive(true)
          store.setRunReviewAutoRefreshActive(true, refreshImmediately: false)
          mobileRemote.startIfConfigured()
          Task { await store.refreshAIChatConfiguration() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
          store.setWorkspaceRealtimeRefreshActive(false)
          store.setRunReviewAutoRefreshActive(false, refreshImmediately: false)
        }
        .task {
          await store.bootstrap()
          mobileRemote.startIfConfigured()
          store.setSourceAutoSyncActive(true)
          CalendarRecordingPromptPanel.install(on: store)
          store.setCalendarRecordingPromptsActive(true)
          store.setAutomationSchedulerActive(true)
          store.setAIChatLivePresenceActive(true)
          attention.attach(to: store)
        }
    }
    .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    .commands {
      CommandGroup(after: .appInfo) {
        CheckForUpdatesCommand(softwareUpdates: softwareUpdates)
      }

      CommandGroup(after: .help) {
        Button("Getting Started") {
          store.presentLaunchGuide()
        }

        Divider()

        Button("Keyboard Shortcuts…") {
          store.presentKeyboardShortcuts()
        }
        .keyboardShortcut("/", modifiers: [.command])
      }

      CommandGroup(after: .pasteboard) {
        if store.experimentalFeaturesEnabled {
          Button("Paste as Org…") {
            if !NSApp.sendAction(NSSelectorFromString("pasteAsOrg2:"), to: nil, from: nil) {
              store.statusText = "Focus the document Source editor to Paste as Org."
            }
          }
          .keyboardShortcut("v", modifiers: [.command, .shift])
        }
      }

      CommandGroup(replacing: .undoRedo) {
        Button("Undo") {
          store.performUndoCommand()
        }
        .keyboardShortcut("z", modifiers: [.command])

        Button("Redo") {
          store.performRedoCommand()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
      }

      CommandGroup(replacing: .newItem) {
        Button("New Tab") {
          store.newWorkspaceTab()
        }
        .keyboardShortcut("t", modifiers: [.command])

        Button("New AI Thread") {
          store.createAIChatThread()
          store.makeSurfacePrimary(.aiChat)
        }
        .keyboardShortcut("n", modifiers: [.command])

        Button("New File…") {
          store.presentNewCorpusFileSheet()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(store.corpusRoot == nil)
      }

      CommandGroup(after: .newItem) {
        Button("Close Tab") {
          store.closeWorkspaceTab(store.selectedWorkspaceTabID)
        }
        .keyboardShortcut("w", modifiers: [.command])
        .disabled(store.workspaceTabs.count < 2)

        Divider()

        Button("Back") {
          store.navigateBack()
        }
        .keyboardShortcut("[", modifiers: [.command])
        .disabled(!store.canNavigateBack)

        Button("Forward") {
          store.navigateForward()
        }
        .keyboardShortcut("]", modifiers: [.command])
        .disabled(!store.canNavigateForward)

        Divider()

        Button("Show Previous Tab") {
          store.selectPreviousWorkspaceTab()
        }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled(store.workspaceTabs.count < 2)

        Button("Show Next Tab") {
          store.selectNextWorkspaceTab()
        }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled(store.workspaceTabs.count < 2)

        Divider()

        Button("Open Corpus...") {
          store.chooseCorpus()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button("Refresh") {
          Task { await store.refreshWorkspace() }
        }
        .keyboardShortcut("r", modifiers: [.command])

        Button("Quick Open...") {
          store.presentQuickOpen()
        }
        .keyboardShortcut("p", modifiers: [.command])

        Button("Capture...") {
          store.presentCapturePanel()
        }
        .keyboardShortcut(.return, modifiers: [.command, .control])
        .disabled(store.corpusRoot == nil)

        Button(store.isRecordingMeeting ? "Stop Meeting Recording" : "Record Meeting") {
          if store.isRecordingMeeting {
            Task { await store.stopMeetingRecording() }
          } else {
            store.promptAndStartMeetingRecording()
          }
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(store.corpusRoot == nil || store.isProcessingMeeting)

        Button("Import Meeting Audio...") {
          store.promptAndImportMeetingAudio()
        }
        .disabled(store.corpusRoot == nil || store.isRecordingMeeting || store.isProcessingMeeting)

        Button("Save") {
          Task { await store.saveActiveEdit() }
        }
        .keyboardShortcut("s", modifiers: [.command])
        .disabled(!store.canSaveCurrentFile)

        Divider()

        Button("Export Current Document as PDF...") {
          Task { await store.exportCurrentDocumentPDF() }
        }
        .disabled(!store.canExportCurrentDocumentPDF)

        Divider()

        Button("Export Slides as PDF...") {
          Task { await store.exportSlides(format: .pdf) }
        }
        .disabled(!store.canExportSlides)

        Button("Export Slides as LaTeX...") {
          Task { await store.exportSlides(format: .latex) }
        }
        .disabled(!store.canExportSlides)
      }

      CommandMenu("Pane") {
        Button("Review Queue") {
          store.openReviewQueue()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("Automations") {
          store.openAutomations()
        }
        .keyboardShortcut("a", modifiers: [.command, .option])

        Divider()

        Button("Make Current Pane Primary") {
          store.makeSelectedSurfacePrimary()
        }
        .keyboardShortcut("p", modifiers: [.command, .option])

        Button(store.expandedWorkspaceSurface == store.selectedSurface ? "Restore Current Pane" : "Expand Current Pane") {
          store.toggleSelectedSurfaceExpansion()
        }
        .keyboardShortcut("f", modifiers: [.command, .option])

        Button("Close Current Pane") {
          store.closeSelectedSurfacePane()
        }
        .keyboardShortcut("w", modifiers: [.command, .option])
      }

      CommandMenu("Block") {
        Button("Select Previous Block") {
          store.selectAdjacentBlock(.up)
        }
        .disabled(!store.canSelectAdjacentBlock(.up))

        Button("Select Next Block") {
          store.selectAdjacentBlock(.down)
        }
        .disabled(!store.canSelectAdjacentBlock(.down))

        Divider()

        Button("Edit Selected Block") {
          store.beginEditingSelectedBlock()
        }
        .disabled(!store.hasSelectedBlock)

        Divider()

        Button("Insert Text After") {
          Task { await store.insertBlockAfterSelected(.paragraph) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Heading After") {
          Task { await store.insertBlockAfterSelected(.heading) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert TODO After") {
          Task { await store.insertBlockAfterSelected(.todo) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Table After") {
          Task { await store.insertBlockAfterSelected(.table) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Image After") {
          Task { await store.insertBlockAfterSelected(.image) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Video After") {
          Task { await store.insertBlockAfterSelected(.video) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Properties After") {
          Task { await store.insertBlockAfterSelected(.properties) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Quote After") {
          Task { await store.insertBlockAfterSelected(.quote) }
        }
        .disabled(!store.hasSelectedBlock)

        Button("Insert Source After") {
          Task { await store.insertBlockAfterSelected(.source) }
        }
        .disabled(!store.hasSelectedBlock)

        Divider()

        Button("Move Block Up") {
          Task { await store.moveSelectedBlock(.up) }
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
        .disabled(!store.canMoveSelectedBlock(.up))

        Button("Move Block Down") {
          Task { await store.moveSelectedBlock(.down) }
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
        .disabled(!store.canMoveSelectedBlock(.down))

        Divider()

        Button("Duplicate Block") {
          Task { await store.duplicateSelectedBlock() }
        }
        .keyboardShortcut("d", modifiers: [.command])
        .disabled(!store.hasSelectedBlock)

        Button("Delete Block") {
          Task { await store.deleteSelectedBlock() }
        }
        .disabled(!store.hasSelectedBlock)
      }

      CommandMenu("Source") {
        Button("Insert Heading") {
          store.requestSourceEditorCommand(.insertHeading)
        }
        .keyboardShortcut(.return, modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Button("Insert List Item") {
          store.requestSourceEditorCommand(.insertListItem)
        }
        .keyboardShortcut("l", modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Button("Insert Link...") {
          store.requestSourceEditorCommand(.insertLink)
        }
        .keyboardShortcut("k", modifiers: [.command])
        .disabled(!store.isEditingEntry)

        Button("Set Property...") {
          store.requestSourceEditorCommand(.insertProperty)
        }
        .disabled(!store.isEditingEntry)

        Divider()

        Button("Promote") {
          store.requestSourceEditorCommand(.promote)
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Button("Demote") {
          store.requestSourceEditorCommand(.demote)
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Button("Cycle TODO") {
          store.requestSourceEditorCommand(.cycleTodo)
        }
        .keyboardShortcut("t", modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Divider()

        Button("Schedule Today") {
          store.requestSourceEditorCommand(.scheduleToday)
        }
        .keyboardShortcut("s", modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Button("Deadline Today") {
          store.requestSourceEditorCommand(.deadlineToday)
        }
        .keyboardShortcut("d", modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Button("Clear Planning") {
          store.requestSourceEditorCommand(.clearPlanning)
        }
        .disabled(!store.isEditingEntry)

        Divider()

        Button("Toggle Heading Fold") {
          store.requestSourceEditorCommand(.toggleFold)
        }
        .keyboardShortcut("[", modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Button("Expand All Headings") {
          store.requestSourceEditorCommand(.unfoldAll)
        }
        .keyboardShortcut("]", modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Button("Previous Heading") {
          store.requestSourceEditorCommand(.previousHeading)
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)

        Button("Next Heading") {
          store.requestSourceEditorCommand(.nextHeading)
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        .disabled(!store.isEditingEntry)
      }

      CommandMenu("Encryption") {
        Button("View Decrypted Subtree") {
          Task { await store.peekOrgCrypt() }
        }
        .disabled(store.selectedLocation == nil && store.selectedEntrySource == nil)

        Divider()

        Button("Decrypt Subtree in File") {
          Task { await store.runOrgCrypt(.decrypt) }
        }
        .disabled(store.selectedLocation == nil)

        Button("Encrypt Subtree") {
          Task { await store.runOrgCrypt(.encrypt) }
        }
        .disabled(store.selectedLocation == nil)

        Button("Re-encrypt Subtree") {
          Task { await store.runOrgCrypt(.reencrypt) }
        }
        .disabled(store.selectedLocation == nil)

        Divider()

        Button("Encryption Settings...") {
          store.presentOrgCryptConfiguration()
        }
      }
    }

    Settings {
      WorkspaceSettingsView(softwareUpdates: softwareUpdates, telemetry: appDelegate.telemetry)
        .environment(store)
        .environmentObject(mobileRemote)
        .environmentObject(attention)
        .preferredColorScheme(store.appearanceMode.colorScheme)
    }
  }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
  let telemetry = OpenOrgLaunchTelemetry()
  private let diagnosticsHeartbeat = WorkspaceDiagnosticsHeartbeatResponder()
  var prepareForTermination: (() async -> Bool)?
  var hasActiveWork: (() -> Bool)?
  /// Agent turns running on this Mac, for "Quit When Turns Finish".
  var runningAgentTurnCount: (() -> Int)?
  /// Stops accepting new local turns and waits for running ones to finish.
  var drainAgentTurns: (() async -> Void)?
  private var drainTask: Task<Void, Never>?
  private var mayTerminate = false
  private var quitAlert: NSAlert?
  private var quitKeyMonitor: Any?
  private var quitPromptWindow: NSWindow?
  private var storedQuitCoordinator: WorkspaceQuitCoordinator?
  private var quitCoordinator: WorkspaceQuitCoordinator {
    if let storedQuitCoordinator { return storedQuitCoordinator }
    let coordinator = WorkspaceQuitCoordinator(
      deadline: .seconds(5),
      save: { [weak self] in await self?.prepareForTermination?() ?? true },
      showPrompt: { [weak self] prompt in self?.showQuitPrompt(prompt) },
      quit: { [weak self] in
        guard let self else { return }
        self.mayTerminate = true
        self.dismissQuitPrompt()
        NSApplication.shared.terminate(nil)
      }
    )
    storedQuitCoordinator = coordinator
    return coordinator
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    AppIconInstaller.install()
    diagnosticsHeartbeat.start()
    WorkspacePointerLatencyMonitor.shared.start()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Finder-launched apps get a minimal PATH; learn the user's login-shell
    // PATH once so npm/nvm-installed agent CLIs such as Codex are found.
    LocalAgentExecutableLocator.warmUp()
    // Daily local-fast builds also use DEBUG. Telemetry checks the bundle's
    // production identity and runtime opt-outs, so Preview remains excluded.
    let os = ProcessInfo.processInfo.operatingSystemVersion
    #if arch(arm64)
    let architecture = "arm64"
    #else
    let architecture = "x86_64"
    #endif
    telemetry.recordLaunch(
      bundleIdentifier: Bundle.main.bundleIdentifier,
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
      architecture: architecture
    )
    // AppKit defers its default quit Apple event while a sheet is open.
    // Route it directly so build --restart and a second external Quit work.
    NSAppleEventManager.shared().setEventHandler(
      self, andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication)
    )
    AppIconInstaller.install()
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
    for window in NSApplication.shared.windows {
      WorkspaceWindowConfigurator.configure(window)
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard !flag else { return true }
    sender.setActivationPolicy(.regular)
    sender.activate(ignoringOtherApps: true)
    sender.sendAction(Selector(("newWindow:")), to: nil, from: nil)
    return true
  }

  @objc private func handleQuitAppleEvent(
    _ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor
  ) {
    quitCoordinator.requestQuit(hasActiveWork: hasActiveWork?() ?? false)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if mayTerminate {
      stopAppServices()
      return .terminateNow
    }
    // Cancel this AppKit request while we save/show a sheet. terminateLater
    // suppresses subsequent termination events, making an override impossible.
    Task { @MainActor in
      quitCoordinator.requestQuit(hasActiveWork: hasActiveWork?() ?? false)
    }
    return .terminateCancel
  }

  private func showQuitPrompt(_ prompt: WorkspaceQuitCoordinator.Prompt) {
    dismissQuitPrompt()
    let alert = NSAlert()
    alert.alertStyle = .warning
    switch prompt {
    case .activeWork:
      alert.messageText = "Quit Celorga while work is in progress?"
      alert.informativeText = "Active chats, recordings, and other work may be interrupted. Celorga will try to save before quitting. Choose Quit again or press ⌘Q again to quit immediately."
    case .saveFailed:
      alert.messageText = "Quit without saving everything?"
      alert.informativeText = "Some changes could not be saved. Quitting now may lose unsaved edits or recent chat output."
    case .saveTakingTooLong:
      alert.messageText = "Celorga is still preparing to quit"
      alert.informativeText = "Saving or stopping background work is taking longer than expected. You can quit now; unsaved edits or recent chat output may be lost."
    }
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: prompt == .saveTakingTooLong ? "Keep Waiting" : "Keep Open")
    let runningTurns = prompt == .activeWork ? (runningAgentTurnCount?() ?? 0) : 0
    if runningTurns > 0, drainAgentTurns != nil {
      // Updates and restarts need not interrupt live turns: stop taking new
      // ones here (they go to an online server) and quit once these finish.
      alert.addButton(withTitle: "Quit When Turns Finish")
      alert.informativeText += " Or let \(runningTurns) running agent turn\(runningTurns == 1 ? "" : "s") finish first; new turns go to an online Celorga server meanwhile."
    }
    alert.buttons[0].keyEquivalent = ""
    alert.buttons[1].keyEquivalent = "\r"
    quitAlert = alert
    // A sheet keeps the application event loop responsive to AppleScript quit.
    // Cmd-Q needs its own route because AppKit disables app menus for sheets.
    quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
         event.charactersIgnoringModifiers?.lowercased() == "q" {
        self?.quitCoordinator.requestQuit(hasActiveWork: true)
        return nil
      }
      return event
    }
    let parent: NSWindow
    if let window = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible && $0 != alert.window }) {
      parent = window
    } else {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
                            styleMask: [.titled], backing: .buffered, defer: false)
      window.title = WorkspaceProductIdentity.displayName
      window.center()
      window.makeKeyAndOrderFront(nil)
      quitPromptWindow = window
      parent = window
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    alert.beginSheetModal(for: parent) { [weak self, weak alert] response in
      guard let self, let alert, self.quitAlert === alert else { return }
      self.dismissQuitPrompt()
      if response == .alertThirdButtonReturn, let drain = self.drainAgentTurns {
        self.quitCoordinator.respond(to: prompt, quit: false)
        self.drainTask?.cancel()
        self.drainTask = Task { @MainActor [weak self] in
          await drain()
          guard let self, !Task.isCancelled else { return }
          self.quitCoordinator.requestQuit(hasActiveWork: self.hasActiveWork?() ?? false)
        }
        return
      }
      self.quitCoordinator.respond(to: prompt, quit: response == .alertFirstButtonReturn)
    }
  }

  private func dismissQuitPrompt() {
    let alert = quitAlert
    quitAlert = nil
    if let monitor = quitKeyMonitor { NSEvent.removeMonitor(monitor) }
    quitKeyMonitor = nil
    if let alert {
      alert.window.sheetParent?.endSheet(alert.window)
      alert.window.orderOut(nil)
    }
    quitPromptWindow?.close()
    quitPromptWindow = nil
  }

  func applicationWillTerminate(_ notification: Notification) {
    stopAppServices()
  }

  private func stopAppServices() {
    diagnosticsHeartbeat.stop()
    WorkspacePointerLatencyMonitor.shared.stop()
  }
}

private struct WorkspaceWindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    Task { @MainActor in
      Self.configure(view.window)
    }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    Task { @MainActor in
      Self.configure(view.window)
    }
  }

  @MainActor
  static func configure(_ window: NSWindow?) {
    guard let window else { return }
    window.titleVisibility = .hidden
    window.tabbingMode = .disallowed
    if window.tabGroup?.windows.count == 1,
       window.tabGroup?.isTabBarVisible == true {
      window.toggleTabBar(nil)
    }
  }
}

private enum AppIconInstaller {
  @MainActor
  static func install() {
    let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png")
    guard let url,
          let image = NSImage(contentsOf: url)
    else {
      return
    }

    image.isTemplate = false
    NSApplication.shared.applicationIconImage = image
    NSApplication.shared.dockTile.display()
  }
}

private enum SmokeTest {
  static func run() -> Never {
    do {
      let repoRoot = try Org2CLI.defaultRepoRoot()
      let cli = Org2CLI(repoRoot: repoRoot)
      let fixture = try makeFixture()

      let agenda: AgendaPayload = try cli.runJSONSync([
        "agenda",
        "--dir", fixture.path,
        "--recursive",
        "--from", "2026-06-12",
        "--to", "2026-06-18",
        "--format", "json"
      ])

      let search: SearchPayload = try cli.runJSONSync([
        "search", "workspace",
        "--dir", fixture.path,
        "--recursive",
        "--limit", "5",
        "--format", "json"
      ])

      let backlinks: BacklinksPayload = try cli.runJSONSync([
        "backlinks",
        "--id", "11111111-1111-4111-8111-111111111111",
        "--dir", fixture.path,
        "--recursive",
        "--format", "json"
      ])

      let todo: TodoMutationPayload = try cli.runJSONSync([
        "todo", "set",
        "--file", fixture.appendingPathComponent("project.org2").path,
        "--line", "7",
        "--status", "in_progress",
        "--format", "json",
        "--apply"
      ])

      let plan: PlanMutationPayload = try cli.runJSONSync([
        "plan", "set",
        "--file", fixture.appendingPathComponent("project.org2").path,
        "--line", "7",
        "--kind", "deadline",
        "--date", "2026-06-15",
        "--format", "json",
        "--apply"
      ])

      guard agenda.totalItemCount > 0 else { throw SmokeFailure("agenda returned no items") }
      guard !search.results.isEmpty else { throw SmokeFailure("search returned no results") }
      guard !backlinks.backlinks.isEmpty else { throw SmokeFailure("backlinks returned no results") }
      guard todo.newStatus == "in_progress" else { throw SmokeFailure("todo mutation did not apply") }
      guard plan.kind == "DEADLINE" && plan.date == "2026-06-15" else { throw SmokeFailure("plan mutation did not apply") }

      FileHandle.standardOutput.write(Data("Org2Workspace smoke test passed\n".utf8))
      exit(0)
    } catch {
      FileHandle.standardError.write(Data("Org2Workspace smoke test failed: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  private static func makeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let project = """
    #+TITLE: Workspace Fixture

    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:

    * TODO Review workspace cockpit
    :PROPERTIES:
    :ID: 22222222-2222-4222-8222-222222222222
    :END:
    SCHEDULED: <2026-06-12 Fri 09:00>
    Keep this safe fixture small.
    """

    let thread = """
    #+TITLE: Thread Fixture

    * TODO Follow up from command center
    SCHEDULED: <2026-06-13 Sat>
    Links to [[id:11111111-1111-4111-8111-111111111111][Workspace Fixture]].
    """

    try project.write(to: root.appendingPathComponent("project.org2"), atomically: true, encoding: .utf8)
    try thread.write(to: root.appendingPathComponent("thread.org2"), atomically: true, encoding: .utf8)
    return root
  }

  private struct SmokeFailure: LocalizedError {
    let message: String

    init(_ message: String) {
      self.message = message
    }

    var errorDescription: String? { message }
  }
}
