import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class WorkspaceListSelectionTests: XCTestCase {
  func testAIChatRefreshOptionsForcesModelCatalogReload() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appendingPathComponent(
        "Sources/Org2WorkspaceCore/AIChatViews.swift"
      ),
      encoding: .utf8
    )

    XCTAssertTrue(
      source.contains("refreshAIChatConfiguration(forceModelCatalogReload: true)")
    )
  }

  func testAutomationSheetsUseDestinationBackedModelAndReasoningPickers() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift"),
      encoding: .utf8
    )
    let fieldsStart = try XCTUnwrap(
      source.range(of: "private struct AutomationAIConfigurationFields: View")
    )
    let editorStart = try XCTUnwrap(
      source.range(
        of: "private struct AutomationScheduleEditor: View",
        range: fieldsStart.upperBound..<source.endIndex
      )
    )
    let fields = source[fieldsStart.lowerBound..<editorStart.lowerBound]

    XCTAssertTrue(fields.contains(#"Picker("Model", selection: $model)"#))
    XCTAssertTrue(fields.contains(#"Picker("Reasoning effort", selection: $reasoningEffort)"#))
    XCTAssertTrue(fields.contains("store.cachedAutomationModelOptions"))
    XCTAssertTrue(fields.contains("store.refreshAutomationModelOptions"))
    XCTAssertFalse(fields.contains(#"TextField("Model"#))
    XCTAssertFalse(fields.contains(#"TextField("Reasoning effort"#))
  }

  func testFirstRunLeadsWithAgentConnectionAndKeepsCorpusOptionsSecondary() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentView = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift"),
      encoding: .utf8
    )
    let settings = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Org2Workspace/MobileRemoteSettingsView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(contentView.contains(#"Text("Connect an agent")"#))
    XCTAssertTrue(contentView.contains(#"DisclosureGroup("Workspace options""#))
    XCTAssertTrue(contentView.contains(#"Button("Continue to Home")"#))
    XCTAssertFalse(contentView.contains("Five-minute launch path"))
    XCTAssertTrue(settings.contains(#"Label("General", systemImage: "gearshape")"#))
    XCTAssertTrue(settings.contains(#"TextField("Name", text: $corpusName)"#))
    XCTAssertTrue(settings.contains(#"Button("Open Another Corpus…")"#))
  }

  func testPrimaryWorkspaceViewsKeepPaneLocalRefreshActions() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)

    XCTAssertTrue(source.contains(#"Label("Refresh All", systemImage: "arrow.clockwise")"#))
    XCTAssertTrue(source.contains("Task { await store.refreshCorpusFiles() }"))
    XCTAssertTrue(source.contains("Task { await store.refreshAgentRuns(updatesStatus: true) }"))
    XCTAssertTrue(source.contains("Task { await store.refreshApprovals(updatesStatus: true) }"))
    XCTAssertTrue(source.contains("Task { await store.refreshAgentWorkflows(updatesStatus: true) }"))
    XCTAssertTrue(source.contains("Task { await store.refreshMeetings() }"))
    XCTAssertTrue(source.contains("if let error = store.approvalLoadErrorText"))
    XCTAssertFalse(source.contains("Use the toolbar Refresh to retry."))
  }

  func testMeetingCaptureControlsAreInsetFromTheHeader() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift"),
      encoding: .utf8
    )
    let meetingsStart = try XCTUnwrap(source.range(of: "private struct MeetingsView: View"))
    let nextViewStart = try XCTUnwrap(
      source.range(
        of: "private struct MeetingTranscriptionProgressView",
        range: meetingsStart.upperBound..<source.endIndex
      )
    )
    let meetingsView = source[meetingsStart.lowerBound..<nextViewStart.lowerBound]

    XCTAssertTrue(
      meetingsView.contains(
        """
        .padding(.horizontal, WorkspaceDesign.contentInset)
              .padding(.top, 12)
              .padding(.bottom, 12)
        """
      ),
      "Meeting capture controls must have breathing room below the header divider"
    )
  }

  func testSourcesExposeConnectorLocalSyncAndScheduleControls() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentView = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift"),
      encoding: .utf8
    )
    let workspaceStore = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Org2WorkspaceCore/WorkspaceStore.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(contentView.contains(#"Label(isRunning ? "Working" : "Run Now""#))
    XCTAssertTrue(contentView.contains(#"Button(schedule.enabled ? "Pause Schedule" : "Resume Schedule")"#))
    XCTAssertTrue(contentView.contains(#"Button(profile.schedule == nil ? "Add Schedule…" : "Edit Schedule…")"#))
    XCTAssertTrue(contentView.contains("DatePicker"))
    XCTAssertTrue(contentView.contains("WorkspaceSourceIntervalUnit.hours"))
    XCTAssertTrue(workspaceStore.contains("await refreshSourceConnection(profile.id)"))
    XCTAssertTrue(workspaceStore.contains(#"["source", "status", profileID"#))
  }

  func testNotebookCredentialsAreContextualInsteadOfAFileMenuCommand() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentView = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(contentView.contains(#"Label("Metabase Credentials…", systemImage: "key")"#))
    XCTAssertTrue(contentView.contains(#"Button("Update Credentials")"#))
    XCTAssertTrue(contentView.contains("if failure.needsCredentialUpdate"))
  }

  func testVerticallyStackedNodeContextPaneHasNoLeadingDividerOverlay() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)
    let contextPaneStart = try XCTUnwrap(source.range(of: "private struct NodeContextPane: View"))
    let overviewStart = try XCTUnwrap(
      source.range(of: "private struct NodeContextOverview: View", range: contextPaneStart.upperBound..<source.endIndex)
    )
    let contextPane = source[contextPaneStart.lowerBound..<overviewStart.lowerBound]

    XCTAssertFalse(
      contextPane.contains(".overlay(alignment: .leading)"),
      "The Context pane is stacked below the document; an unconstrained leading Divider resolves horizontally and draws a line through the pane"
    )
  }

  func testIOSNotificationOpenUsesStableTranscriptPresentationLifecycle() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let mobileRemoteViews = packageRoot
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("ios/Org2Mobile/Org2Mobile/MobileRemoteViews.swift")
    let source = try String(contentsOf: mobileRemoteViews, encoding: .utf8)

    XCTAssertTrue(source.contains(".task(id: remote.threadDetail?.thread.id)"))
    XCTAssertFalse(source.contains("loadingView(detailIsAvailable: true)\n            .task"))
    // Notification routing now lives above the remote list, so a cold-launch tap
    // can open a thread before the host or list refresh finishes.
    let mobileContentView = mobileRemoteViews.deletingLastPathComponent()
      .appendingPathComponent("ContentView.swift")
    let contentSource = try String(contentsOf: mobileContentView, encoding: .utf8)
    XCTAssertTrue(contentSource.contains(".onAppear { openPendingNotification() }"))
    XCTAssertTrue(contentSource.contains(".onChange(of: scenePhase) { _, phase in\n      if phase == .active { openPendingNotification() }"))
    XCTAssertTrue(contentSource.contains(".onChange(of: remote.isPaired) { _, paired in\n      if paired { openPendingNotification() }"))
    XCTAssertTrue(contentSource.contains(".onReceive(NotificationCenter.default.publisher(for: .org2NotificationDestinationPending)) { _ in\n      openPendingNotification()"))

    let routingStart = try XCTUnwrap(contentSource.range(of: "private func openPendingNotification()"))
    let routingEnd = try XCTUnwrap(contentSource.range(
      of: "private func closeSidebar()", range: routingStart.upperBound..<contentSource.endIndex
    ))
    let routing = contentSource[routingStart.lowerBound..<routingEnd.lowerBound]
    let pendingRead = try XCTUnwrap(routing.range(of: "guard let pending = inbox.pending() else { return }"))
    let pairingGuard = try XCTUnwrap(routing.range(of: "guard remote.isPaired else { route = .settings; return }"))
    let threadRoute = try XCTUnwrap(routing.range(of: "route = .thread(threadID)"))
    let agendaRoute = try XCTUnwrap(routing.range(of: "selection = .agenda"))
    let acknowledgment = try XCTUnwrap(routing.range(of: "inbox.acknowledge(pending)"))
    XCTAssertLessThan(pendingRead.lowerBound, pairingGuard.lowerBound)
    XCTAssertLessThan(pairingGuard.lowerBound, threadRoute.lowerBound)
    XCTAssertLessThan(threadRoute.lowerBound, acknowledgment.lowerBound)
    XCTAssertLessThan(agendaRoute.lowerBound, acknowledgment.lowerBound)
    XCTAssertFalse(routing.contains("await remote.refresh()"))
  }

  func testIOSSharedRoomProgressUsesTheActiveDestinationName() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let mobileRemoteViews = packageRoot
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("ios/Org2Mobile/Org2Mobile/MobileRemoteViews.swift")
    let source = try String(contentsOf: mobileRemoteViews, encoding: .utf8)

    XCTAssertTrue(source.contains("detail.activeDestinationName"))
    XCTAssertTrue(source.contains("return activeDestinationName"))
  }

  func testMeetingAutomationIsDiscoverableOnlyInMeetingSettings() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let meetingSettingsSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/MobileRemoteSettingsView.swift")
    let aiChatSettingsSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/AIChatSettingsView.swift")
    let meetingSettings = try String(contentsOf: meetingSettingsSource, encoding: .utf8)
    let aiChatSettings = try String(contentsOf: aiChatSettingsSource, encoding: .utf8)

    XCTAssertTrue(meetingSettings.contains(#"Label("Meeting Automation", systemImage: "calendar.badge.clock")"#))
    XCTAssertTrue(meetingSettings.contains("Process every completed meeting"))
    XCTAssertTrue(meetingSettings.contains("saveMeetingReadyAutomationConfiguration"))
    XCTAssertFalse(aiChatSettings.contains("Meeting Automation"))
    XCTAssertFalse(aiChatSettings.contains("Process every completed meeting"))
  }

  func testOpeningSettingsDoesNotSynchronouslyProbeTheTranscriptionRuntime() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let settingsSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/MobileRemoteSettingsView.swift")
    let settings = try String(contentsOf: settingsSource, encoding: .utf8)
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let contentView = try String(contentsOf: contentViewSource, encoding: .utf8)

    XCTAssertFalse(settings.contains(".onAppear {\n      store.refreshAudioSettingsStatus()"))
    XCTAssertTrue(contentView.contains("Task { await store.refreshAudioSettingsStatusAsync() }"))
  }

  func testFluidVoiceSetupConnectsAutomaticallyAndKeepsTheEndpointAdvanced() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)

    XCTAssertTrue(source.contains(".task(id: store.meetingTranscriptionProvider)"))
    XCTAssertTrue(source.contains("await store.connectFluidVoice()"))
    XCTAssertTrue(source.contains(#"Label("Connect Fluid Voice", systemImage: "bolt.horizontal.circle")"#))
    XCTAssertTrue(source.contains(#"DisclosureGroup("Advanced")"#))
    XCTAssertFalse(source.contains("Enable Fluid Voice Local API"))
  }

  func testRenderedApprovalTitleAndActionRemainSelectable() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)

    // Compare with whitespace collapsed so layout-only reindentation of the
    // run detail's decision card does not hide a real selection regression.
    let normalized = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    XCTAssertTrue(
      normalized.contains("Text(approval.title) .font(.title3.weight(.semibold)) .textSelection(.enabled)")
    )
    XCTAssertTrue(
      normalized.contains(
        "Text(approval.action) .font(.callout) .foregroundStyle(.secondary) .textSelection(.enabled)"
      ),
      "The full rendered approval body must support drag selection and standard Copy"
    )
  }

  func testCommandNStartsANewAIThreadInsteadOfOpeningAnotherWindow() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/Org2WorkspaceApp.swift")
    let source = try String(contentsOf: appSource, encoding: .utf8)

    XCTAssertTrue(source.contains("CommandGroup(replacing: .newItem)"))
    XCTAssertTrue(source.contains("Button(\"New AI Thread\")"))
    XCTAssertTrue(source.contains("store.createAIChatThread()"))
    XCTAssertTrue(source.contains("store.makeSurfacePrimary(.aiChat)"))
    XCTAssertTrue(source.contains(#".keyboardShortcut("n", modifiers: [.command])"#))
  }

  func testKeyboardShortcutsAreDiscoverableFromSidebarAndHelpMenu() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Org2Workspace/Org2WorkspaceApp.swift"),
      encoding: .utf8
    )
    let contentSource = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(appSource.contains("CommandGroup(after: .help)"))
    XCTAssertTrue(appSource.contains("Button(\"Getting Started\")"))
    XCTAssertTrue(appSource.contains("Button(\"Keyboard Shortcuts…\")"))
    XCTAssertTrue(appSource.contains(#".keyboardShortcut("/", modifiers: [.command])"#))
    XCTAssertTrue(contentSource.contains("Label(\"Keyboard Shortcuts\", systemImage: \"questionmark.circle\")"))
    XCTAssertTrue(contentSource.contains("store.presentKeyboardShortcuts()"))
    XCTAssertTrue(contentSource.contains("title: \"Review Queue\""))
    XCTAssertTrue(contentSource.contains("title: \"Automations\""))
    XCTAssertTrue(contentSource.contains("SidebarChatThreadGroupLabel(title: \"Running\""))
    XCTAssertTrue(appSource.contains("Button(\"Review Queue\")"))
    XCTAssertTrue(appSource.contains("Button(\"Automations\")"))
    XCTAssertTrue(appSource.contains(#".keyboardShortcut("r", modifiers: [.command, .shift])"#))
    XCTAssertTrue(appSource.contains(#".keyboardShortcut("a", modifiers: [.command, .option])"#))
  }

  func testIOSForegroundThreadRefreshDoesNotDependOnNotifications() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repositoryRoot
        .appendingPathComponent("apps/ios/Org2Mobile/Org2Mobile/MobileRemoteStore.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("guard isActive, isPaired else { return }"))
    XCTAssertTrue(source.contains("if self.threadNotificationsEnabled"))
    XCTAssertTrue(source.contains("Task.sleep(for: .seconds(4))"))

    let coordinatorSource = try String(
      contentsOf: repositoryRoot.appendingPathComponent(
        "apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/MobileRemoteCoordinator.swift"
      ),
      encoding: .utf8
    )
    XCTAssertGreaterThanOrEqual(
      coordinatorSource.components(
        separatedBy: "_ = await store.refreshSyncedAIChatTranscript()"
      ).count - 1,
      2,
      "Thread lists and individual thread requests must reconcile synced disk state before responding"
    )
  }

  func testGlobalSearchFocusWaitsForTheCachedSurfaceToAttach() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentViewSource = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentViewSource, encoding: .utf8)

    XCTAssertTrue(source.contains(".task(id: store.searchFocusToken)"))
    XCTAssertTrue(source.contains(
      """
      isSearchFocused = false
            await Task.yield()
            guard !Task.isCancelled, store.selectedSurface == .search else { return }
            isSearchFocused = true
      """
    ))
  }

  func testAppActivationDoesNotInvalidateTheEntireWorkspaceView() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let appSource = packageRoot
      .appendingPathComponent("Sources/Org2Workspace/Org2WorkspaceApp.swift")
    let source = try String(contentsOf: appSource, encoding: .utf8)

    XCTAssertFalse(source.contains(#"@Environment(\.scenePhase)"#))
    XCTAssertTrue(source.contains("NSApplication.didBecomeActiveNotification"))
    XCTAssertTrue(source.contains("refreshImmediately: false"))
  }

  func testPerpetualActivityMotionDoesNotDriveTheSwiftUIFrameClock() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcesRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
    let sourceFiles = try XCTUnwrap(
      FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: nil
      )?.allObjects as? [URL]
    )
    var offenders: [String] = []

    for sourceFile in sourceFiles where sourceFile.pathExtension == "swift" {
      let source = try String(contentsOf: sourceFile, encoding: .utf8)
      if source.contains("TimelineView(") || source.contains(".repeatForever(") {
        offenders.append(sourceFile.path.replacingOccurrences(of: packageRoot.path + "/", with: ""))
      }
    }

    XCTAssertTrue(
      offenders.isEmpty,
      "SwiftUI clocks and perpetual animations relayout the full workspace and delay app activation; use compositor-backed Core Animation or a local AppKit timer instead: \(offenders.joined(separator: ", "))"
    )
  }

  func testMainWorkspaceAvoidsUnreadableNativeListSelection() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourcesRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
    let nativeSelection = try NSRegularExpression(
      pattern: #"\bList\s*\(\s*selection\s*:"#,
      options: []
    )
    let sourceFiles = try XCTUnwrap(
      FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: nil
      )?.allObjects as? [URL]
    )
    var offenders: [String] = []
    for sourceFile in sourceFiles where sourceFile.pathExtension == "swift" {
      let source = try String(contentsOf: sourceFile, encoding: .utf8)
      if nativeSelection.firstMatch(
        in: source,
        options: [],
        range: NSRange(source.startIndex..., in: source)
      ) != nil {
        offenders.append(sourceFile.path.replacingOccurrences(of: packageRoot.path + "/", with: ""))
      }
    }

    XCTAssertTrue(
      offenders.isEmpty,
      "Use readable explicit selection instead of native List selection highlighting: \(offenders.joined(separator: ", "))"
    )
  }

  func testSidebarSelectionAddsVerticalPaddingWithoutChangingOtherLists() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentView = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentView, encoding: .utf8)

    XCTAssertNotNil(source.range(
      of: #"ReadableListSelectionModifier\(\s*isSelected:\s*isSidebarSurfaceSelected\(surface\),\s*verticalPadding:\s*4\s*\)"#,
      options: .regularExpression
    ))
    XCTAssertTrue(source.contains("var verticalPadding: CGFloat = 0"))
    XCTAssertEqual(
      source.components(separatedBy: ".workspaceSelectableRow(").count - 1,
      7,
      "Every selected-row implementation should use the shared gutter and marker chrome"
    )
    XCTAssertFalse(source.contains("WorkspaceSelectionMarker()"))
  }

  func testOrgSyntaxMarkersStayCompact() {
    XCTAssertEqual(WorkspaceSyntax.selectionMarker, "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 0), "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 1), "*")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 2), "**")
    XCTAssertEqual(WorkspaceSyntax.headingMarker(for: 8), "***")
    XCTAssertEqual(WorkspaceDesign.selectionMarkerGutterWidth, 22)
    XCTAssertEqual(WorkspaceDesign.selectionMarkerVerticalOffset, -1)
  }

  func testSettledThreadDisclosurePreservesTheUsersChoice() {
    XCTAssertFalse(
      AIChatSettledThreadDisclosure.updated(isExpanded: false, settledThreadCount: 3)
    )
    XCTAssertTrue(
      AIChatSettledThreadDisclosure.updated(isExpanded: true, settledThreadCount: 4)
    )
    XCTAssertFalse(
      AIChatSettledThreadDisclosure.updated(isExpanded: true, settledThreadCount: 0)
    )
  }

  func testSettledThreadPaginationLoadsBoundedBatches() {
    XCTAssertEqual(AIChatSettledThreadPagination.pageSize, 30)
    XCTAssertEqual(
      AIChatSettledThreadPagination.nextLimit(currentLimit: 30, totalCount: 253),
      60
    )
    XCTAssertEqual(
      AIChatSettledThreadPagination.nextLimit(currentLimit: 240, totalCount: 253),
      253
    )
    XCTAssertEqual(
      AIChatSettledThreadPagination.clampedLimit(currentLimit: 90, totalCount: 25),
      25
    )
    XCTAssertEqual(
      AIChatSettledThreadPagination.moreTitle(currentLimit: 240, totalCount: 253),
      "Show 13 more · 13 remaining"
    )
  }

  func testSidebarThreadRowIdentitySurvivesSettlementChanges() {
    let threadID = UUID()
    let activeThread = AIChatThread(
      id: threadID,
      title: "Thread",
      sessionKey: "agent:main:thread"
    )
    let settledThread = activeThread.replacingAIChatMetadata(
      isArchived: true,
      settledAt: .some(Date(timeIntervalSince1970: 1_700_000_000))
    )

    XCTAssertEqual(
      AIChatSidebarThreadRowIdentity(thread: activeThread),
      AIChatSidebarThreadRowIdentity(thread: settledThread)
    )
    XCTAssertNotEqual(
      AIChatSidebarThreadRowIdentity(thread: activeThread),
      AIChatSidebarThreadRowIdentity(
        thread: AIChatThread(title: "Other", sessionKey: "agent:main:other")
      )
    )
  }

  func testChatSidebarSummaryDoesNotRetainTranscriptContent() {
    let threadID = UUID()
    let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let firstThread = AIChatThread(
      id: threadID,
      title: "Thread",
      updatedAt: updatedAt,
      sessionKey: "agent:main:thread",
      messages: [
        AIChatMessage(role: .assistant, content: String(repeating: "a", count: 10_000))
      ]
    )
    let secondThread = AIChatThread(
      id: threadID,
      title: "Thread",
      updatedAt: updatedAt,
      sessionKey: "agent:main:thread",
      messages: [
        AIChatMessage(role: .assistant, content: String(repeating: "b", count: 10_000))
      ]
    )

    XCTAssertEqual(
      AIChatSidebarThreadSummary(thread: firstThread),
      AIChatSidebarThreadSummary(thread: secondThread),
      "Sidebar redraws should compare compact row metadata instead of entire transcript payloads"
    )
  }

  func testChatThreadContextMenusStayBoundToTheirOwnRow() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let contentView = packageRoot
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
    let source = try String(contentsOf: contentView, encoding: .utf8)

    XCTAssertFalse(source.contains("contextualThreadID"))
    XCTAssertFalse(source.contains("contextThread:"))
    XCTAssertTrue(source.contains("rename(summary.id)"))
    XCTAssertTrue(source.contains("AIChatSidebarThreadContextMenuTarget("))
    XCTAssertTrue(source.contains("NSApp.currentEvent?.type == .rightMouseDown"))
    XCTAssertTrue(source.contains("rename?(threadID)"))
    XCTAssertTrue(source.contains("presenting: chatRenameRequest"))
    XCTAssertTrue(source.contains("let threadID = request.threadID"))
    XCTAssertTrue(source.contains("store.renameAIChatThread(threadID, title: title)"))
    XCTAssertGreaterThanOrEqual(
      source.components(separatedBy: "chatRenameRequest = nil").count - 1,
      2,
      "Both cancel and commit must clear the previous rename request explicitly"
    )
    XCTAssertEqual(
      source.components(separatedBy: #".alert("Rename Thread""#).count - 1,
      0,
      "Thread rows must not each install an alert; SwiftUI can hoist the first pinned row's alert"
    )
    XCTAssertTrue(source.contains("if summary.isSettled"))
  }
}
