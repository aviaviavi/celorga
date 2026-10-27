import AppKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceTabsTests: XCTestCase {
  func testTabsKeepNavigationAndBackHistoryIndependent() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    store.selectedSurface = .agenda
    store.makeSurfacePrimary(.files)
    XCTAssertTrue(store.canNavigateBack)

    let secondTabID = store.newWorkspaceTab()
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertFalse(store.canNavigateBack)

    store.selectedSurface = .approvals
    store.makeSurfacePrimary(.meetings)
    XCTAssertTrue(store.canNavigateBack)

    store.selectWorkspaceTab(firstTabID)
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.canNavigateBack)
    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .agenda)
    XCTAssertFalse(store.canNavigateBack)

    store.selectWorkspaceTab(secondTabID)
    XCTAssertEqual(store.selectedSurface, .meetings)
    XCTAssertTrue(store.canNavigateBack)
    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertFalse(store.canNavigateBack)
  }

  func testNewTabStartsWithoutTheOutgoingDocumentDetail() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let file = "/tmp/outgoing-tab-detail.org"

    store.selectedSurface = .agenda
    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Outgoing detail",
      file: file,
      line: 1,
      zone: "notes",
      modifiedAt: nil
    ))
    store.selectedEntrySource = EntrySource(
      file: file,
      startLine: 1,
      endLineExclusive: 2,
      text: "* Outgoing detail",
      isSubtree: false
    )
    XCTAssertTrue(store.hasWorkspaceDetailContent)

    store.newWorkspaceTab()

    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertNil(store.selectedLocation)
    XCTAssertNil(store.selectedEntrySource)
    XCTAssertFalse(store.hasWorkspaceDetailContent)
  }

  func testDuplicateTabCopiesCurrentLocationAndBackHistory() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let originalTabID = store.selectedWorkspaceTabID
    store.selectedSurface = .agenda
    store.makeSurfacePrimary(.files)

    let duplicateTabID = store.duplicateWorkspaceTab()
    XCTAssertNotEqual(duplicateTabID, originalTabID)
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.canNavigateBack)

    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .agenda)
    store.selectWorkspaceTab(originalTabID)
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.canNavigateBack)
  }

  func testTabsKeepWorkspaceSurfaceModeSelectionAndPaneLayoutIndependent() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let agendaTabID = store.selectedWorkspaceTabID
    store.selectedSurface = .agenda
    store.agendaMode = .assigned
    store.selectedAgendaItemID = "agenda:first"
    store.isWorkspaceSurfacePaneClosed = false
    store.isWorkspaceDetailPaneClosed = true

    let agentWorkTabID = store.newWorkspaceTab()
    store.selectedSurface = .approvals
    store.runsAndReviewPage = .workflows
    store.selectedAgentWorkflowID = "workflow:second"
    store.selectedApprovalItemID = "approval:second"
    store.isWorkspaceSurfacePaneClosed = true
    store.isWorkspaceDetailPaneClosed = false

    store.selectWorkspaceTab(agendaTabID)
    XCTAssertEqual(store.selectedSurface, .agenda)
    XCTAssertEqual(store.agendaMode, .assigned)
    XCTAssertEqual(store.selectedAgendaItemID, "agenda:first")
    XCTAssertNil(store.selectedAgentWorkflowID)
    XCTAssertNil(store.selectedApprovalItemID)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertTrue(store.isWorkspaceDetailPaneClosed)

    store.selectWorkspaceTab(agentWorkTabID)
    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.runsAndReviewPage, .workflows)
    XCTAssertEqual(store.selectedAgentWorkflowID, "workflow:second")
    XCTAssertEqual(store.selectedApprovalItemID, "approval:second")
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
  }

  func testTabsDoNotLeakSkillSelectionIntoAnotherSurface() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    store.selectedSurface = .skills
    store.selectedWorkspaceSkillID = "/tmp/first/SKILL.md"

    let secondTabID = store.newWorkspaceTab()
    store.selectedSurface = .agenda
    XCTAssertNil(store.selectedWorkspaceSkillID)

    store.selectWorkspaceTab(firstTabID)
    XCTAssertEqual(store.selectedSurface, .skills)
    XCTAssertEqual(store.selectedWorkspaceSkillID, "/tmp/first/SKILL.md")

    store.selectWorkspaceTab(secondTabID)
    XCTAssertEqual(store.selectedSurface, .agenda)
    XCTAssertNil(store.selectedWorkspaceSkillID)
  }

  func testTabsKeepFiltersSearchSelectionsAndViewportIndependent() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let source = EntrySource(
      file: "/tmp/tab-local-viewport.org",
      startLine: 1,
      endLineExclusive: 101,
      text: (1...100).map { "Line \($0)" }.joined(separator: "\n"),
      isSubtree: false
    )

    let firstTabID = store.selectedWorkspaceTabID
    store.agendaFilter = "first agenda"
    store.approvalFilter = "first approval"
    store.agentRunFilter = "first run"
    store.agentRunSelectionScope = .completed
    store.corpusFileFilter = "first file"
    store.searchQuery = "first search"
    store.externalThreadSearchQuery = "first external"
    store.bulkSelectedAgendaItemIDs = ["agenda:first"]
    store.selectedApprovalItemIDsForAIContext = ["approval:first"]
    store.bulkSelectedApprovalItemIDs = ["approval:first"]
    store.selectedAgentRunIDsForAIContext = ["run:first"]
    store.selectedCorpusFileIDsForAIContext = ["file:first"]
    store.selectedEntrySource = source
    store.recordDocumentViewportSourceLine(80)

    let secondTabID = store.newWorkspaceTab()
    XCTAssertEqual(store.agendaFilter, "")
    XCTAssertEqual(store.approvalFilter, "")
    XCTAssertEqual(store.agentRunFilter, "")
    XCTAssertEqual(store.agentRunSelectionScope, .active)
    XCTAssertEqual(store.corpusFileFilter, "")
    XCTAssertEqual(store.searchQuery, "")
    XCTAssertEqual(store.externalThreadSearchQuery, "")
    XCTAssertTrue(store.bulkSelectedAgendaItemIDs.isEmpty)
    XCTAssertTrue(store.selectedApprovalItemIDsForAIContext.isEmpty)
    XCTAssertTrue(store.bulkSelectedApprovalItemIDs.isEmpty)
    XCTAssertTrue(store.selectedAgentRunIDsForAIContext.isEmpty)
    XCTAssertTrue(store.selectedCorpusFileIDsForAIContext.isEmpty)

    store.approvalFilter = "second approval"
    store.searchQuery = "second search"
    store.recordDocumentViewportSourceLine(20, for: source)

    store.selectWorkspaceTab(firstTabID)
    XCTAssertEqual(store.agendaFilter, "first agenda")
    XCTAssertEqual(store.approvalFilter, "first approval")
    XCTAssertEqual(store.agentRunFilter, "first run")
    XCTAssertEqual(store.agentRunSelectionScope, .completed)
    XCTAssertEqual(store.corpusFileFilter, "first file")
    XCTAssertEqual(store.searchQuery, "first search")
    XCTAssertEqual(store.externalThreadSearchQuery, "first external")
    XCTAssertEqual(store.bulkSelectedAgendaItemIDs, ["agenda:first"])
    XCTAssertEqual(store.selectedApprovalItemIDsForAIContext, ["approval:first"])
    XCTAssertEqual(store.bulkSelectedApprovalItemIDs, ["approval:first"])
    XCTAssertEqual(store.selectedAgentRunIDsForAIContext, ["run:first"])
    XCTAssertEqual(store.selectedCorpusFileIDsForAIContext, ["file:first"])
    XCTAssertEqual(store.documentViewportSourceLine(for: source), 80)

    store.selectWorkspaceTab(secondTabID)
    XCTAssertEqual(store.approvalFilter, "second approval")
    XCTAssertEqual(store.searchQuery, "second search")
    XCTAssertEqual(store.documentViewportSourceLine(for: source), 20)
  }

  func testTabsRestoreSourceEditorModePresentationAndSelection() async throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-tab-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    store.setCorpusRoot(root, persistsDefault: false)

    let file = root.appendingPathComponent("editable.org")
    let original = "* Editable\nOriginal text\n"
    let edited = "* Editable\nEdited in the first tab\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let location = WorkspaceLocation.aiChatThreadRecord(AIChatThreadRecord(
      title: "Editable",
      file: file.path,
      line: 1,
      zone: "notes",
      modifiedAt: nil
    ))
    let source = EntrySource(
      file: file.path,
      startLine: 1,
      endLineExclusive: 4,
      text: original,
      isSubtree: false
    )

    let editorTabID = store.selectedWorkspaceTabID
    store.selectedSurface = .files
    store.selectedEntrySourceMode = .page
    store.selectedLocation = location
    store.selectedEntrySource = source
    store.beginEditingSelectedEntry()
    store.sourceEditorPresentation = .split
    let selection = NSRange(location: edited.utf16.count, length: 0)
    store.sourceEditorInteraction.text = edited
    store.noteSourceEditorLocalTextChanged(edited)
    store.sourceEditorSelection = selection
    XCTAssertTrue(store.isEditingEntry)

    let previewTabID = store.newWorkspaceTab()
    XCTAssertFalse(store.isEditingEntry)
    store.sourceEditorPresentation = .source
    let draftPersisted = await store.waitForPendingEditorPersistenceForTesting()
    XCTAssertTrue(draftPersisted, store.errorText ?? store.statusText)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)

    store.selectWorkspaceTab(editorTabID)
    for _ in 0..<100 where !store.isEditingEntry {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    XCTAssertEqual(store.selectedWorkspaceTabID, editorTabID)
    XCTAssertEqual(store.selectedLocation, location)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.sourceEditorPresentation, .split)
    XCTAssertEqual(store.sourceEditorSelection, selection)
    XCTAssertEqual(store.sourceEditorInteraction.text, edited)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)

    store.selectWorkspaceTab(previewTabID)
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.sourceEditorPresentation, .source)
  }

  func testRapidTabSwitchDoesNotLoseOrLeakPendingSourceEditorRestore() async throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-tab-editor-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    store.setCorpusRoot(root, persistsDefault: false)

    let file = root.appendingPathComponent("editable.org")
    let text = "* Editable\nOriginal text\n"
    try text.write(to: file, atomically: true, encoding: .utf8)
    let location = WorkspaceLocation.aiChatThreadRecord(AIChatThreadRecord(
      title: "Editable",
      file: file.path,
      line: 1,
      zone: "notes",
      modifiedAt: nil
    ))
    let source = EntrySource(
      file: file.path,
      startLine: 1,
      endLineExclusive: 4,
      text: text,
      isSubtree: false
    )

    let editorTabID = store.selectedWorkspaceTabID
    store.selectedSurface = .files
    store.selectedEntrySourceMode = .page
    store.selectedLocation = location
    store.selectedEntrySource = source
    store.beginEditingSelectedEntry()
    let previewTabID = store.newWorkspaceTab()
    store.entrySourceLoaderForTesting = { _, _, _ in
      try await Task.sleep(nanoseconds: 150_000_000)
      return source
    }

    store.selectWorkspaceTab(editorTabID)
    store.selectWorkspaceTab(previewTabID)
    try await Task.sleep(nanoseconds: 300_000_000)

    XCTAssertEqual(store.selectedWorkspaceTabID, previewTabID)
    XCTAssertFalse(store.isEditingEntry)

    store.selectWorkspaceTab(editorTabID)
    for _ in 0..<100 where !store.isEditingEntry {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(store.selectedWorkspaceTabID, editorTabID)
    XCTAssertTrue(store.isEditingEntry)
  }

  func testDeferredSurfaceActionsUseTheMountedTabIdentity() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try SplitSourceText.read(packageRoot.appendingPathComponent(
        "Sources/Org2WorkspaceCore/ContentView.swift"
      ))

    XCTAssertTrue(source.contains("workspaceTabID: store.selectedWorkspaceTabID"))
    XCTAssertTrue(source.contains(".environment(\\.workspaceTabID, workspaceTabID)"))
    XCTAssertFalse(
      source.contains("performAfterSwiftUIViewUpdate(for: store.selectedWorkspaceTabID"),
      "Deferred view callbacks must compare against the tab that mounted the view, not whichever tab is selected when they fire"
    )
  }

  func testActiveTabTitleRepresentsTheActiveWorkspacePane() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let tab = try XCTUnwrap(store.workspaceTabs.first)
    store.selectedSurface = .agenda
    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Project Plan",
      file: "/tmp/project-plan.org",
      line: 1,
      zone: "notes",
      modifiedAt: nil
    ))
    store.isWorkspaceDetailPaneClosed = false

    XCTAssertEqual(store.workspaceTabDisplayTitle(for: tab), "Agenda")
    store.makeDetailPanePrimary()
    XCTAssertEqual(store.workspaceTabDisplayTitle(for: tab), "Project Plan")
  }

  func testClosingTabsUsesTheAdjacentTabWithoutAddingBackHistory() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    let secondTabID = store.newWorkspaceTab()
    store.selectedSurface = .agenda
    let thirdTabID = store.newWorkspaceTab()
    store.selectedSurface = .files

    store.closeWorkspaceTab(secondTabID)
    XCTAssertEqual(store.workspaceTabs.map(\.id), [firstTabID, thirdTabID])
    XCTAssertEqual(store.selectedWorkspaceTabID, thirdTabID)

    store.closeWorkspaceTab(thirdTabID)
    XCTAssertEqual(store.workspaceTabs.map(\.id), [firstTabID])
    XCTAssertEqual(store.selectedWorkspaceTabID, firstTabID)
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertFalse(store.canNavigateBack)

    store.closeWorkspaceTab(firstTabID)
    XCTAssertEqual(store.workspaceTabs.map(\.id), [firstTabID])
  }

  func testTabReorderingPreservesSelectionAndNavigationState() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    let secondTabID = store.newWorkspaceTab()
    store.selectedSurface = .agenda
    let thirdTabID = store.newWorkspaceTab()
    store.selectedSurface = .files

    XCTAssertTrue(store.moveWorkspaceTab(firstTabID, to: thirdTabID))
    XCTAssertEqual(store.workspaceTabs.map(\.id), [secondTabID, thirdTabID, firstTabID])
    XCTAssertEqual(store.selectedWorkspaceTabID, thirdTabID)
    XCTAssertEqual(store.selectedSurface, .files)

    store.moveWorkspaceTab(thirdTabID, offset: -1)
    XCTAssertEqual(store.workspaceTabs.map(\.id), [thirdTabID, secondTabID, firstTabID])
    XCTAssertEqual(store.selectedWorkspaceTabID, thirdTabID)
  }

  func testAdjacentTabSelectionWrapsAtBothEnds() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    let secondTabID = store.newWorkspaceTab()
    let thirdTabID = store.newWorkspaceTab()

    store.selectNextWorkspaceTab()
    XCTAssertEqual(store.selectedWorkspaceTabID, firstTabID)
    store.selectPreviousWorkspaceTab()
    XCTAssertEqual(store.selectedWorkspaceTabID, thirdTabID)
    store.selectPreviousWorkspaceTab()
    XCTAssertEqual(store.selectedWorkspaceTabID, secondTabID)
  }

  func testKeyboardShortcutsCreateSelectAndCloseTabs() throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstTabID = store.selectedWorkspaceTabID
    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("t", keyCode: 17, modifiers: [.command]),
      scope: .globalOnly
    ))
    let secondTabID = store.selectedWorkspaceTabID
    XCTAssertNotEqual(secondTabID, firstTabID)
    XCTAssertEqual(store.workspaceTabs.count, 2)

    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("[", keyCode: 33, modifiers: [.command, .shift]),
      scope: .globalOnly
    ))
    XCTAssertEqual(store.selectedWorkspaceTabID, firstTabID)

    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("]", keyCode: 30, modifiers: [.command, .shift]),
      scope: .globalOnly
    ))
    XCTAssertEqual(store.selectedWorkspaceTabID, secondTabID)

    // Real ⌘⇧[ / ⌘⇧] events report the shifted brace characters. They must
    // be handled here rather than falling through to the slower menu path.
    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("{", keyCode: 33, modifiers: [.command, .shift]),
      scope: .globalOnly
    ))
    XCTAssertEqual(store.selectedWorkspaceTabID, firstTabID)

    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("}", keyCode: 30, modifiers: [.command, .shift]),
      scope: .globalOnly
    ))
    XCTAssertEqual(store.selectedWorkspaceTabID, secondTabID)

    XCTAssertTrue(store.handleGlobalKeyDown(
      keyDown("w", keyCode: 13, modifiers: [.command]),
      scope: .globalOnly
    ))
    XCTAssertEqual(store.workspaceTabs.map(\.id), [firstTabID])
    XCTAssertFalse(store.handleGlobalKeyDown(
      keyDown("w", keyCode: 13, modifiers: [.command]),
      scope: .globalOnly
    ))
  }

  func testTabSwitchDoesNotAutosaveAStaleSourceForAnotherLocation() async throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-tab-stale-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let loadedFile = root.appendingPathComponent("loaded.org2")
    let selectedFile = root.appendingPathComponent("selected.org2")
    let loadedText = "#+TITLE: Loaded\n"
    try loadedText.write(to: loadedFile, atomically: true, encoding: .utf8)
    try "#+TITLE: Selected\n".write(to: selectedFile, atomically: true, encoding: .utf8)

    store.selectedSurface = .files
    store.selectedEntrySourceMode = .page
    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Selected",
      file: selectedFile.path,
      zone: "notes",
      modifiedAt: nil
    ))
    store.selectedEntrySource = EntrySource(
      file: loadedFile.path,
      startLine: 1,
      endLineExclusive: 2,
      text: loadedText,
      isSubtree: false
    )
    store.editableEntryText = ""

    XCTAssertFalse(store.liveFileEditorHasUnsavedChanges)
    store.newWorkspaceTab()
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(try String(contentsOf: loadedFile, encoding: .utf8), loadedText)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".org2-recovery").path))
  }

  func testAIChatTabWithARunInTheDetailPaneStaysAnAIChatTab() async throws {
    let (store, defaults, suiteName) = try makeStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let run = try JSONDecoder().decode(AgentRunItem.self, from: Data("""
    {"id":"run-1","goal":"Prepare a cited briefing","acceptanceCriteria":[],
     "status":"running","riskClass":"local-draft","capabilities":[],"context":[],
     "plan":[],"artifacts":[],"approvals":[],"validations":[],"comments":[],
     "events":[],"createdAt":"2026-07-14T00:00:00.000Z",
     "updatedAt":"2026-07-14T00:01:00.000Z"}
    """.utf8))
    store.replaceAgentRunsForTesting([run])
    await store.waitForAgentRunProjectionForTesting()

    let leftTabID = store.selectedWorkspaceTabID
    let chatTabID = store.newWorkspaceTab()
    // Open a run from Agent Work, then switch the surface to an AI chat
    // thread. The run stays open in the detail pane beside the chat.
    store.selectAgentRun(run)
    XCTAssertEqual(store.selectedSurface, .approvals)
    store.makeSurfacePrimary(.aiChat)
    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.presentedAgentRun?.id, run.id)

    store.selectWorkspaceTab(leftTabID)
    XCTAssertEqual(store.selectedSurface, .home)
    let chatTab = try XCTUnwrap(store.workspaceTabs.first { $0.id == chatTabID })
    XCTAssertEqual(chatTab.systemImage, WorkspaceSurface.aiChat.systemImage)

    store.selectWorkspaceTab(chatTabID)
    XCTAssertEqual(store.selectedSurface, .aiChat, "Returning to the tab must not turn it into Agent Work")
    XCTAssertEqual(store.presentedAgentRun?.id, run.id)

    // Back history uses the same restore path.
    store.makeSurfacePrimary(.agenda)
    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.presentedAgentRun?.id, run.id)
  }

  private func makeStore() throws -> (WorkspaceStore, UserDefaults, String) {
    let suiteName = "org2-workspace-tabs-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    return (
      WorkspaceStore(defaults: defaults, legacyDefaultsDomains: []),
      defaults,
      suiteName
    )
  }

  private func keyDown(
    _ characters: String,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    )!
  }
}
