import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor WorkspaceProjectRefreshRecorder {
  private(set) var callCount = 0

  func load() async throws -> WorkspaceProjectList {
    callCount += 1
    try await Task.sleep(for: .milliseconds(100))
    return WorkspaceProjectList(projects: [], diagnostics: [])
  }
}

private enum WorkspaceProjectRefreshTestError: Error {
  case transient
  case persistent
}

private actor WorkspaceProjectFlakyRefreshRecorder {
  private(set) var callCount = 0
  let project: WorkspaceProjectNote

  init(project: WorkspaceProjectNote) {
    self.project = project
  }

  func load() async throws -> WorkspaceProjectList {
    callCount += 1
    if callCount == 1 { throw WorkspaceProjectRefreshTestError.transient }
    return WorkspaceProjectList(projects: [project], diagnostics: [])
  }
}

final class WorkspaceProjectTests: XCTestCase {
  private func project(threadID: UUID, brief: String = "* TODO Ship the thing") -> WorkspaceProjectNote {
    WorkspaceProjectNote(id: UUID().uuidString, title: "Launch", color: "blue", file: "/local/launch.org", relativePath: "launch.org", revision: "sha256:fixture", threadIDs: [threadID.uuidString.lowercased()], brief: brief, briefTruncated: false)
  }

  func testOnlyExplicitThreadMembershipSuppliesContext() {
    let linked = UUID(), unrelated = UUID()
    let note = project(threadID: linked)
    XCTAssertEqual(WorkspaceProjectContext.presentation(projects: [note], threadID: unrelated), "")
    let context = WorkspaceProjectContext.presentation(projects: [note], threadID: linked, mappedPath: { $0.replacingOccurrences(of: "/local", with: "/remote") })
    XCTAssertTrue(context.contains("/remote/launch.org:1"))
    XCTAssertTrue(context.contains("sha256:fixture"))
    XCTAssertTrue(context.contains("* TODO Ship the thing"))
    XCTAssertTrue(context.contains("does not grant access"))
  }

  func testContextBoundsBriefAcrossMultipleNotes() {
    let thread = UUID()
    let notes = (0..<10).map { _ in project(threadID: thread, brief: String(repeating: "x", count: 15000)) }
    let context = WorkspaceProjectContext.presentation(projects: notes, threadID: thread)
    XCTAssertLessThan(context.count, 16000)
    XCTAssertTrue(context.contains("truncated"))
    XCTAssertTrue(context.contains("Additional project notes omitted"))
  }

  func testProjectBriefSurvivesLocalAndGatewayPromptConstruction() {
    let context = AIChatWorkspaceContext(localCorpusRoot: "/local", remoteCorpusRoot: "/remote",
      selectedSurface: "AI Chat", selectedLocation: nil, selectedEntrySource: nil,
      backlinks: nil, agenda: nil, searchQuery: "", searchResults: [], projectContext: "Project brief fixture")
    XCTAssertTrue(context.systemPrompt().contains("Project brief fixture"))
    XCTAssertTrue(context.codexSystemPrompt().contains("Project brief fixture"))
    XCTAssertTrue(context.localAgentSystemPrompt(runtime: "claude", runtimeTitle: "Claude Code").contains("Project brief fixture"))
  }

  func testCustomProjectColorsRoundTripThroughNativePicker() {
    for hex in ["#123456", "#000000", "#FFFFFF", "#aB12eF"] {
      XCTAssertEqual(WorkspaceProjectPalette.hex(WorkspaceProjectPalette.tint(hex)), hex.uppercased())
    }
  }

  func testEmptyProjectListHasNoPromptOverhead() {
    XCTAssertEqual(WorkspaceProjectContext.presentation(projects: [], threadID: UUID()), "")
  }

  func testProjectSidebarHidesSettledThreads() {
    let activeID = UUID()
    let settledID = UUID()
    let note = WorkspaceProjectNote(
      id: UUID().uuidString,
      title: "Launch",
      color: "blue",
      file: "/local/launch.org",
      relativePath: "launch.org",
      revision: "sha256:fixture",
      threadIDs: [activeID.uuidString.lowercased(), settledID.uuidString.lowercased()],
      brief: "",
      briefTruncated: false
    )
    let active = AIChatSidebarThreadSummary(thread: AIChatThread(
      id: activeID,
      title: "Active",
      sessionKey: "active"
    ))
    let settled = AIChatSidebarThreadSummary(thread: AIChatThread(
      id: settledID,
      title: "Settled",
      sessionKey: "settled",
      settledAt: Date()
    ))

    XCTAssertEqual(
      WorkspaceProjectThreadVisibility.activeSummaries(
        for: note,
        from: [active, settled]
      ).map(\.id),
      [activeID]
    )
  }

  func testNewThreadProjectPickerShowsOnlyBeforeTheFirstMessage() {
    XCTAssertTrue(AIChatNewThreadProjectPicker.isVisible(
      hasSelectedThread: true, messageCount: 0, isLoadingTranscript: false, projectCount: 2
    ))
    XCTAssertFalse(AIChatNewThreadProjectPicker.isVisible(
      hasSelectedThread: true, messageCount: 1, isLoadingTranscript: false, projectCount: 2
    ))
    XCTAssertFalse(AIChatNewThreadProjectPicker.isVisible(
      hasSelectedThread: true, messageCount: 0, isLoadingTranscript: true, projectCount: 2
    ))
    XCTAssertFalse(AIChatNewThreadProjectPicker.isVisible(
      hasSelectedThread: true, messageCount: 0, isLoadingTranscript: false, projectCount: 0
    ))
    XCTAssertFalse(AIChatNewThreadProjectPicker.isVisible(
      hasSelectedThread: false, messageCount: 0, isLoadingTranscript: false, projectCount: 2
    ))

    let threadID = UUID()
    func note(_ title: String, _ threads: [UUID]) -> WorkspaceProjectNote {
      WorkspaceProjectNote(
        id: title, title: title, color: "blue", file: "/local/\(title).org", relativePath: "\(title).org",
        revision: "sha256:fixture", threadIDs: threads.map { $0.uuidString.lowercased() },
        brief: "", briefTruncated: false
      )
    }
    XCTAssertEqual(AIChatNewThreadProjectPicker.title(projects: [note("Launch", [])], threadID: threadID), "No project")
    XCTAssertEqual(AIChatNewThreadProjectPicker.title(
      projects: [note("Launch", [threadID]), note("Ops", [])], threadID: threadID
    ), "Launch")
    XCTAssertEqual(AIChatNewThreadProjectPicker.title(
      projects: [note("Launch", [threadID]), note("Ops", [threadID])], threadID: threadID
    ), "Launch +1")
  }

  func testNewChatInProjectDoesNotExpandTheProject() {
    let existingID = UUID()
    let newID = UUID()
    func note(_ id: String, _ threads: [UUID]) -> WorkspaceProjectNote {
      WorkspaceProjectNote(
        id: id, title: id, color: "blue", file: "/local/\(id).org", relativePath: "\(id).org",
        revision: "sha256:\(threads.count)", threadIDs: threads.map { $0.uuidString.lowercased() },
        brief: "", briefTruncated: false
      )
    }
    // "New chat" adds the selected chat to a project the user left collapsed.
    XCTAssertEqual(WorkspaceProjectSidebarExpansion.projectsRevealing(
      selectedThreadID: newID,
      previous: [note("launch", [existingID])],
      current: [note("launch", [existingID, newID])]
    ), [])
    // Loading projects still reveals the project holding the selected chat.
    XCTAssertEqual(WorkspaceProjectSidebarExpansion.projectsRevealing(
      selectedThreadID: existingID,
      previous: [],
      current: [note("launch", [existingID]), note("other", [])]
    ), ["launch"])
    // A refresh of an unchanged membership keeps revealing it.
    XCTAssertEqual(WorkspaceProjectSidebarExpansion.projectsRevealing(
      selectedThreadID: existingID,
      previous: [note("launch", [existingID])],
      current: [note("launch", [existingID, newID])]
    ), ["launch"])
    XCTAssertEqual(WorkspaceProjectSidebarExpansion.projectsRevealing(
      selectedThreadID: nil,
      previous: [],
      current: [note("launch", [existingID])]
    ), [])
  }

  func testProjectSidebarPresentationNamespacesRepeatedThreadRows() {
    let sharedThreadID = UUID()
    let first = project(threadID: sharedThreadID)
    let second = project(threadID: sharedThreadID)
    let summary = AIChatSidebarThreadSummary(thread: AIChatThread(
      id: sharedThreadID,
      title: "Shared",
      sessionKey: "shared"
    ))

    let items = WorkspaceProjectSidebarPresentation.items(
      projects: [first, second],
      summaries: [summary],
      expandedProjectIDs: [first.id, second.id]
    )

    XCTAssertEqual(items.count, 4)
    XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    XCTAssertEqual(
      items.compactMap { item -> UUID? in
        guard case .thread(let thread) = item.content else { return nil }
        return thread.id
      },
      [sharedThreadID, sharedThreadID]
    )
  }

  func testProjectSidebarPresentationStaysFlatAcrossRapidRefreshAndCollapse() {
    let threadIDs = (0..<8).map { _ in UUID() }
    let summaries = threadIDs.map { id in
      AIChatSidebarThreadSummary(thread: AIChatThread(
        id: id,
        title: id.uuidString,
        sessionKey: id.uuidString
      ))
    }
    let projects = (0..<12).map { index in
      WorkspaceProjectNote(
        id: "project-\(index)",
        title: "Project \(index)",
        color: "blue",
        file: "/local/project-\(index).org",
        relativePath: "project-\(index).org",
        revision: "sha256:\(index)",
        threadIDs: threadIDs.map { $0.uuidString.lowercased() },
        brief: "",
        briefTruncated: false
      )
    }

    for revision in 0..<500 {
      let expanded = revision.isMultiple(of: 2)
        ? Set(projects.map(\.id))
        : Set<String>()
      let items = WorkspaceProjectSidebarPresentation.items(
        projects: revision.isMultiple(of: 3) ? projects : Array(projects.reversed()),
        summaries: summaries,
        expandedProjectIDs: expanded
      )
      XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }
  }

  func testProjectSidebarAvoidsSwiftUIHierarchicalDisclosureRows() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot
        .appendingPathComponent("Sources/Org2WorkspaceCore/WorkspaceProjects.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(source.contains("DisclosureGroup("))
    XCTAssertTrue(source.contains("ForEach(sidebarItems)"))
  }

  func testProjectHeaderButtonsKeepStableHitGeometry() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot
        .appendingPathComponent("Sources/Org2WorkspaceCore/WorkspaceProjects.swift"),
      encoding: .utf8
    )
    let buttonSource = try XCTUnwrap(
      source.range(of: "private struct WorkspaceProjectHeaderButton")
    )
    let followingSource = try XCTUnwrap(
      source.range(of: "private struct WorkspaceProjectColorPicker")
    )
    let implementation = source[buttonSource.lowerBound..<followingSource.lowerBound]

    XCTAssertTrue(implementation.contains(".frame(width: 24, height: 24)"))
    XCTAssertTrue(implementation.contains(".contentShape(Rectangle())"))
    XCTAssertTrue(implementation.contains(".buttonStyle(WorkspaceQuietPressStyle())"))
    XCTAssertTrue(implementation.contains(".fixedSize()"))
  }

  @MainActor
  func testProjectRefreshPublishesProgressAndCoalescesRepeatedRequests() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-project-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = WorkspaceProjectRefreshRecorder()
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.projectListLoaderForTesting = { _ in try await recorder.load() }

    let first = Task { await store.refreshProjectsIfIdle() }
    try await Task.sleep(for: .milliseconds(10))

    XCTAssertTrue(store.isRefreshingProjects)

    let repeated = Task { await store.refreshProjectsIfIdle() }
    await repeated.value
    await first.value

    let callCount = await recorder.callCount
    XCTAssertFalse(store.isRefreshingProjects)
    XCTAssertEqual(callCount, 1)
  }

  @MainActor
  func testProjectRefreshSurvivesSidebarTaskCancellation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-project-refresh-cancellation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = project(threadID: UUID())
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.projectListLoaderForTesting = { _ in
      try await Task.sleep(for: .milliseconds(100))
      return WorkspaceProjectList(projects: [expected], diagnostics: [])
    }

    let sidebarTask = Task { await store.refreshProjectsIfIdle() }
    await Task.yield()
    sidebarTask.cancel()
    await sidebarTask.value

    XCTAssertEqual(store.projectNotes, [expected])
    XCTAssertEqual(store.projectStatus, "")
    XCTAssertFalse(store.isRefreshingProjects)
  }

  @MainActor
  func testProjectRefreshRetriesTransientFailure() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-project-refresh-retry-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = project(threadID: UUID())
    let recorder = WorkspaceProjectFlakyRefreshRecorder(project: expected)
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.projectListLoaderForTesting = { _ in try await recorder.load() }

    await store.refreshProjects()

    let callCount = await recorder.callCount
    XCTAssertEqual(callCount, 2)
    XCTAssertEqual(store.projectNotes, [expected])
    XCTAssertEqual(store.projectStatus, "")
  }

  @MainActor
  func testProjectRefreshKeepsLastGoodProjectsAfterPersistentFailure() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-project-refresh-preserve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = project(threadID: UUID())
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.projectListLoaderForTesting = { _ in
      WorkspaceProjectList(projects: [expected], diagnostics: [])
    }
    await store.refreshProjects()
    store.projectListLoaderForTesting = { _ in throw WorkspaceProjectRefreshTestError.persistent }

    await store.refreshProjects()

    XCTAssertEqual(store.projectNotes, [expected])
    XCTAssertTrue(store.projectStatus.hasPrefix("Could not load projects:"))
    XCTAssertFalse(store.isRefreshingProjects)
  }

  @MainActor
  func testHeadlessBootstrapLoadsProjectsForMobileClients() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-project-headless-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "WorkspaceProjectTests.Headless.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let expected = project(threadID: UUID())
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.projectListLoaderForTesting = { _ in
      WorkspaceProjectList(projects: [expected], diagnostics: [])
    }

    await store.bootstrapHeadless(corpusRoot: root, hostRef: "test", destinations: [])
    defer { store.setWorkspaceRealtimeRefreshActive(false) }

    XCTAssertEqual(store.projectNotes, [expected])
  }

  @MainActor
  func testForkedThreadRetainsProjectMembership() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-project-fork-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "WorkspaceProjectTests.Fork.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let sourceID = store.createAIChatThread(runtime: .openClaw)
    let projectID = UUID().uuidString.lowercased()
    let projectURL = root.appendingPathComponent("launch.org")
    let projectText = """
    #+ORG2_KIND: project
    #+TITLE: Launch
    #+PROJECT_THREADS: \(sourceID.uuidString.lowercased())
    :PROPERTIES:
    :ID: \(projectID)
    :END:

    Keep the launch coordinated.
    """
    try projectText.write(to: projectURL, atomically: true, encoding: .utf8)
    await store.refreshProjects()
    XCTAssertTrue(try XCTUnwrap(store.projectNotes.first).contains(sourceID))

    let loadedForkID = await store.forkAIChatThread(sourceID)
    let forkID = try XCTUnwrap(loadedForkID)

    let project = try XCTUnwrap(store.projectNotes.first(where: { $0.id == projectID }))
    XCTAssertTrue(project.contains(sourceID))
    XCTAssertTrue(project.contains(forkID))
    let persisted = try String(contentsOf: projectURL, encoding: .utf8)
    XCTAssertTrue(persisted.contains(forkID.uuidString.lowercased()))
  }

  @MainActor
  func testRemoteProjectThreadPersistsMembershipBeforePublishingThread() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-project-mobile-create-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "WorkspaceProjectTests.MobileCreate.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let projectID = UUID().uuidString.lowercased()
    let projectURL = root.appendingPathComponent("mobile.org")
    let projectText = """
    #+ORG2_KIND: project
    #+TITLE: Mobile
    :PROPERTIES:
    :ID: \(projectID)
    :END:

    Keep mobile chat work together.
    """
    try projectText.write(to: projectURL, atomically: true, encoding: .utf8)
    await store.refreshProjects()

    let initialThreadCount = store.aiChatThreads.count
    let missingProjectThreadID = await store.createAIChatRemoteThread(
      destinationID: AIChatDestinationConfiguration.localCodexID,
      projectID: "missing-project"
    )
    XCTAssertNil(missingProjectThreadID)
    XCTAssertEqual(store.aiChatThreads.count, initialThreadCount)

    let createdThreadID = await store.createAIChatRemoteThread(
      destinationID: AIChatDestinationConfiguration.localCodexID,
      projectID: projectID
    )
    let threadID = try XCTUnwrap(createdThreadID)

    XCTAssertNotNil(store.aiChatThreads.first(where: { $0.id == threadID }))
    XCTAssertTrue(
      try XCTUnwrap(store.projectNotes.first(where: { $0.id == projectID }))
        .contains(threadID)
    )
    let persisted = try String(contentsOf: projectURL, encoding: .utf8)
    XCTAssertTrue(persisted.contains(threadID.uuidString.lowercased()))
  }

  @MainActor
  func testRemoteProjectThreadSurvivesProjectNoteEditedAfterListing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-project-stale-revision-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "WorkspaceProjectTests.StaleRevision.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let projectID = UUID().uuidString.lowercased()
    let projectURL = root.appendingPathComponent("stale.org")
    try """
    #+ORG2_KIND: project
    #+TITLE: Stale
    :PROPERTIES:
    :ID: \(projectID)
    :END:

    Original brief.
    """.write(to: projectURL, atomically: true, encoding: .utf8)
    await store.refreshProjects()
    let staleRevision = try XCTUnwrap(store.projectNotes.first(where: { $0.id == projectID })).revision

    // A headless host has no project sidebar to notice this edit, so its
    // cached revision is stale when the phone creates a chat in the project.
    let edited = try String(contentsOf: projectURL, encoding: .utf8) + "\nEdited on another device.\n"
    try edited.write(to: projectURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(store.projectNotes.first(where: { $0.id == projectID })?.revision, staleRevision)

    let createdThreadID = await store.createAIChatRemoteThread(
      destinationID: AIChatDestinationConfiguration.localCodexID,
      projectID: projectID
    )
    let threadID = try XCTUnwrap(createdThreadID, store.projectStatus)
    let persisted = try String(contentsOf: projectURL, encoding: .utf8)
    XCTAssertTrue(persisted.contains(threadID.uuidString.lowercased()))
    XCTAssertTrue(persisted.contains("Edited on another device."))
    XCTAssertTrue(try XCTUnwrap(store.projectNotes.first(where: { $0.id == projectID })).contains(threadID))

    // A project created after the last listing is found without a restart.
    let laterID = UUID().uuidString.lowercased()
    let laterURL = root.appendingPathComponent("later.org")
    try """
    #+ORG2_KIND: project
    #+TITLE: Later
    :PROPERTIES:
    :ID: \(laterID)
    :END:
    """.write(to: laterURL, atomically: true, encoding: .utf8)
    let laterThreadID = await store.createAIChatRemoteThread(
      destinationID: AIChatDestinationConfiguration.localCodexID,
      projectID: laterID
    )
    let laterThread = try XCTUnwrap(laterThreadID, store.projectStatus)
    XCTAssertTrue(try String(contentsOf: laterURL, encoding: .utf8).contains(laterThread.uuidString.lowercased()))
  }
}
