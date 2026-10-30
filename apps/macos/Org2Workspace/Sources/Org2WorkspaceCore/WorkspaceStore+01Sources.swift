import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  /// Starts the corpus and chat lifecycle without desktop onboarding, audio, or windows.
  public func bootstrapHeadless(
    corpusRoot: URL,
    hostRef: String,
    hostName: String? = nil,
    destinations: [AIChatDestinationConfiguration]
  ) async {
    automationHostRef = hostRef
    configureAIChatHost(AIChatHostIdentity(
      ref: hostRef,
      name: hostName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? hostName! : hostRef,
      kind: .server
    ))
    configureHeadlessDestinations(destinations)
    setCorpusRoot(corpusRoot, persistsDefault: false)
    if let aiChatTranscriptLoadTask { await aiChatTranscriptLoadTask.value }
    startPendingAIChatTurnRecovery()
    setAIChatLivePresenceActive(true)
    if openClawLocalEditsEnabled {
      startOpenClawLocalEditNode()
    }
    setWorkspaceRealtimeRefreshActive(true)
    await refreshProjects()
    await refreshAgenda()
    await refreshRunReviewData()
  }

  func configureHeadlessDestinations(_ destinations: [AIChatDestinationConfiguration]) {
    guard let destination = destinations.first(where: { $0.id == AIChatDestinationConfiguration.openClawID }),
          destination.adapter == .openClaw else { return }
    // The desktop's built-in adapter reads these settings separately. A server
    // must use its original configuration, before the desktop's inherited-agent
    // migration clears the built-in destination's agentID.
    let endpoint = destination.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    openClawEndpointText = endpoint.isEmpty
      ? OpenClawGatewaySettings.resolve().endpoint.absoluteString : endpoint
    let agentID = destination.agentID.trimmingCharacters(in: .whitespacesAndNewlines)
    openClawAgentID = agentID.isEmpty ? "main" : agentID
  }

  public func bootstrap() async {
    let cli = self.cli
    Task.detached(priority: .utility) {
      await cli.prewarmAppHTMLRenderer()
    }
    await restoreLocalDocumentPublications()
    await refreshAudioSettingsStatusAsync()
    if corpusRoot == nil {
      if let screenshotCorpusRoot = screenshotCorpusRootFromEnvironment() {
        setCorpusRoot(screenshotCorpusRoot, persistsDefault: false)
      } else {
        if let restoredRoot = restoreCorpusRoot() {
          setCorpusRoot(
            restoredRoot,
            persistsDefault: false,
            aiChatMigrationSource: appAIChatTranscriptURL
          )
        } else if let automaticStarterCorpusURL {
          do {
            let root = try Self.prepareAutomaticStarterCorpus(
              preferredRoot: automaticStarterCorpusURL
            )
            setCorpusRoot(root)
            selectedSurface = .home
            statusText = "Created your \(WorkspaceProductIdentity.displayName) workspace"
          } catch {
            errorText = error.localizedDescription
            statusText = "Could not create the starter workspace"
          }
        }
      }
    }

    if let aiChatTranscriptLoadTask {
      await aiChatTranscriptLoadTask.value
    }
    startPendingAIChatTurnRecovery()
    if openClawLocalEditsEnabled {
      startOpenClawLocalEditNode()
    }

    if corpusRoot != nil {
      if selectedSurface == .home {
        ensureHomeDetailReady()
      }
      await refreshAgenda()
      await refreshMeetings()
      await refreshSourceConnections()
      await refreshCorpusFiles()
      await refreshAssignedWork()
      await refreshRunReviewData()
      refreshOrgCryptManagedRecipientFiles()
      if screenshotModeFromEnvironment() == nil {
        Task { await refreshAIChatThreadRecords() }
      } else {
        await refreshAIChatThreadRecords()
        await applyScreenshotModeFromEnvironment()
      }
      presentLaunchGuideIfNeeded()
    } else {
      statusText = "No corpus selected"
    }
  }

  private func screenshotCorpusRootFromEnvironment() -> URL? {
    guard let raw = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_CORPUS")?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      return nil
    }
    let url = URL(fileURLWithPath: raw).standardizedFileURL
    return isDirectory(url.path) ? url : nil
  }

  private func screenshotModeFromEnvironment() -> String? {
    let raw = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_MODE")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return raw?.isEmpty == false ? raw : nil
  }

  private func applyScreenshotModeFromEnvironment() async {
    guard let mode = screenshotModeFromEnvironment() else { return }
    let target = CelorgaNames.environment("ORG2_WORKSPACE_SCREENSHOT_TARGET")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    switch mode {
    case "home":
      openHome()
    case "activity", "activity-map":
      UserDefaults.standard.set(mode == "activity-map" ? "Map" : "Now", forKey: "workspaceActivityMode")
      await refreshActivitySources()
      selectedSurface = .activity
    case "calendar", "calendar-month", "calendar-day":
      UserDefaults.standard.set(
        mode == "calendar-month" ? "month" : mode == "calendar-day" ? "day" : "week",
        forKey: CalendarView.scaleDefaultsKey
      )
      if let target, let date = WorkspaceCalendarDates.date(fromKey: target) {
        calendarAnchorDate = date
      }
      selectedSurface = .calendar
      isWorkspaceDetailPaneClosed = true
      await refreshCalendar(force: true)
    case "agenda":
      selectedSurface = .agenda
      agendaMode = .focus
      if let item = visibleAgendaItems.first(where: { item in
        guard let target, !target.isEmpty else { return false }
        return item.headline.lowercased().contains(target)
      }) ?? visibleAgendaItems.first {
        selectAgendaItem(item)
      }
    case "assigned":
      selectedSurface = .agenda
      agendaMode = .assigned
      if let item = visibleAssignedWorkItems.first(where: { item in
        guard let target, !target.isEmpty else { return true }
        return item.headline.lowercased().contains(target)
          || item.status.lowercased().contains(target)
      }) ?? visibleAssignedWorkItems.first {
        selectAssignedWorkItem(item)
      }
    case "approvals":
      selectedSurface = .approvals
      if let item = visibleApprovalItems.first(where: { item in
        guard let target, !target.isEmpty else { return true }
        return item.title.lowercased().contains(target)
          || item.status.lowercased().contains(target)
          || item.file.lowercased().contains(target)
      }) ?? visibleApprovalItems.first {
        selectApprovalItem(item)
      }
    case "runs":
      selectedSurface = .approvals
      if let run = agentRuns.first(where: { run in
        guard let target, !target.isEmpty else { return true }
        return run.displayTitle.lowercased().contains(target) || run.id.lowercased().contains(target)
      }) ?? agentRuns.first {
        selectAgentRun(run)
      }
    case "review":
      selectedSurface = .approvals
      runsAndReviewPage = .review
      if let item = visibleApprovalItems.first(where: { item in
        guard let target, !target.isEmpty else { return true }
        return item.title.lowercased().contains(target)
          || item.status.lowercased().contains(target)
          || item.file.lowercased().contains(target)
      }) ?? visibleApprovalItems.first {
        selectApprovalItem(item)
      }
    case "workflows":
      selectedSurface = .approvals
      runsAndReviewPage = .workflows
      if let workflow = agentWorkflows.first(where: { workflow in
        guard let target, !target.isEmpty else { return true }
        return workflow.title.lowercased().contains(target)
          || workflow.file.lowercased().contains(target)
      }) ?? agentWorkflows.first {
        selectAgentWorkflow(workflow)
      }
    case "goals":
      selectedSurface = .approvals
      runsAndReviewPage = .goals
      if let goal = agentGoals.first(where: { goal in
        guard let target, !target.isEmpty else { return true }
        return goal.title.lowercased().contains(target)
          || goal.id.lowercased().contains(target)
      }) ?? agentGoals.first {
        selectAgentGoal(goal)
      }
    case "agents":
      selectedSurface = .approvals
      runsAndReviewPage = .agents
      if let profile = agentProfiles.first(where: { profile in
        guard let target, !target.isEmpty else { return true }
        return profile.name.lowercased().contains(target)
          || profile.id.lowercased().contains(target)
      }) ?? agentProfiles.first {
        selectAgentProfile(profile)
      }
    case "search":
      selectedSurface = .search
      searchQuery = target ?? ""
      if !searchQuery.isEmpty {
        await runSearch()
      }
    case "ai-room":
      if let target, !target.isEmpty,
         let thread = aiChatThreads.first(where: { $0.title.lowercased().contains(target) }) {
        selectAIChatThread(thread.id)
      }
      expandSurface(.aiChat)
      aiChatStatusText = "Ready for an @mention or thread post"
    case "openclaw", "chat":
      selectedSurface = .aiChat
      publishAIChatComposerDraft("Summarize the current launch plan and call out open risks.")
    case "brief":
      selectedSurface = .files
      if let thread = aiChatThreadRecords.first(where: { thread in
        guard let target, !target.isEmpty else {
          return thread.title.lowercased().contains("brief")
        }
        return thread.title.lowercased().contains(target)
      }) ?? aiChatThreadRecords.first {
        openAIChatThreadRecord(thread, surface: .files, mode: .page)
      }
    case "meetings":
      selectedSurface = .meetings
      if let meeting = meetings.first(where: { meeting in
        guard let target, !target.isEmpty else { return true }
        return meeting.title.lowercased().contains(target)
      }) {
        selectMeeting(meeting)
      }
    case "sources":
      selectedSurface = .sources
    case "files":
      selectedSurface = .files
      if let file = filteredCorpusFiles.first(where: { file in
        guard let target, !target.isEmpty else { return true }
        return file.relativePath.lowercased().contains(target)
          || file.name.lowercased().contains(target)
      }) {
        // Match the shipped flow: opening a file from the sidebar tree hides
        // the Files list pane and shows the document beside the sidebar.
        openSidebarFile(file)
      }
    case "start-work":
      applyScreenshotStartWork(fileTarget: target)
    default:
      openHome()
    }

    if let selectedLocation {
      await loadEntrySource(for: selectedLocation)
    }
  }

  /// Documentation captures of the Start work flow: the note in the detail
  /// pane and AI Chat in the surface pane, at one stage of the flow
  /// (`ORG2_WORKSPACE_SCREENSHOT_START_WORK_STAGE`: `before`, `working`, or
  /// `done`). The thread, its heading resource, the context pill, and the
  /// prompt come from the same code `startWork` uses. Nothing is sent and no
  /// run is created here; the capture script records the run and links the
  /// heading in its disposable corpus first.
  private func applyScreenshotStartWork(fileTarget: String?) {
    func env(_ name: String) -> String? {
      CelorgaNames.environment(name)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }
    guard let fileTarget, !fileTarget.isEmpty,
          let file = filteredCorpusFiles.first(where: { $0.relativePath.lowercased().contains(fileTarget) })
    else {
      openHome()
      return
    }
    openSidebarFile(file)
    isWorkspaceSurfacePaneClosed = false
    selectedSurface = .aiChat
    // The chat that was open before work started: a fresh, empty thread.
    createAIChatThread()

    let stage = env("ORG2_WORKSPACE_SCREENSHOT_START_WORK_STAGE") ?? "before"
    guard stage != "before",
          let headingTitle = env("ORG2_WORKSPACE_SCREENSHOT_START_WORK_HEADING"),
          let text = try? String(contentsOfFile: file.path, encoding: .utf8)
    else { return }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let link = HeadingWorkStatus.links(in: text, baseLine: 1).first(where: { link in
      lines.indices.contains(link.line - 1) && lines[link.line - 1].contains(headingTitle)
    }), let idValue = link.idValue,
      let destination = enabledAIChatDestinations.first(where: {
        $0.id == env("ORG2_WORKSPACE_SCREENSHOT_START_WORK_DESTINATION")
      }) ?? enabledAIChatDestinations.first
    else { return }

    let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
    let resource = AIChatResourceReference(
      key: "id:\(idValue)", kind: .heading, title: headingTitle, file: path, line: link.line, idValue: idValue
    )
    let thread = createAIChatThread(
      title: "Work: \(headingTitle)",
      statusText: "",
      resource: resource,
      runtime: destination.runtime,
      destinationID: destination.id,
      defersPersistence: true,
      selectsThread: false
    )
    let pointer = aiChatContextPointer(for: WorkspaceLocation.aiChatThreadRecord(AIChatThreadRecord(
      title: headingTitle, file: path, line: link.line, zone: "entry", modifiedAt: nil, idValue: idValue
    )))
    let prompt = injectedAIChatContext(pointer) + HeadingWorkStatus.startWorkPrompt(
      title: headingTitle,
      reference: pointer.reference,
      runID: link.runID ?? "run",
      keepsCLIInstructions: !destination.adapter.isDirectProvider
    )
    let startedAt = Date().addingTimeInterval(-42)
    let activities = Self.screenshotActivities(env("ORG2_WORKSPACE_SCREENSHOT_START_WORK_ACTIVITIES"))
    var messages = [AIChatMessage(role: .user, content: prompt, createdAt: startedAt)]
    if stage == "done", let reply = env("ORG2_WORKSPACE_SCREENSHOT_START_WORK_REPLY") {
      messages.append(AIChatMessage(
        role: .assistant,
        content: reply,
        createdAt: startedAt.addingTimeInterval(40),
        responseTrace: AIChatResponseTrace(activities: activities),
        authorRuntime: destination.runtime,
        authorDestinationID: destination.id
      ))
    }
    if let index = aiChatThreads.firstIndex(where: { $0.id == thread.id }) {
      aiChatThreads[index] = aiChatThreads[index].replacingMessages(messages)
    }
    selectAIChatThread(thread.id, persistsSelection: false)
    aiChatMessages = messages

    guard stage == "working" else { return }
    // A live turn, as the transcript shows it while the agent streams.
    aiChatSendingThreadIDs.insert(thread.id)
    isSendingAIChatMessage = true
    aiChatRequestStartedAt = startedAt
    aiChatLiveState.gatewayStateByThreadID[thread.id] = .connected
    aiChatLiveState.runActivitiesByThreadID[thread.id] = activities
    if let partial = env("ORG2_WORKSPACE_SCREENSHOT_START_WORK_PARTIAL_REPLY") {
      aiChatLiveState.replaceStreamingReply(partial, for: thread.id, coalesced: false)
    }
    aiChatLiveState.noteEvent(for: thread.id, coalesced: false)
    aiChatLiveState.flushPendingStreamUpdates()
  }

  /// Activities for a Start work capture, from a JSON array of
  /// `{"title", "detail", "status"}` objects.
  private static func screenshotActivities(_ json: String?) -> [AIChatRunActivity] {
    guard let data = json?.data(using: .utf8),
          let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]]
    else { return [] }
    return items.enumerated().map { index, item in
      AIChatRunActivity(
        id: "docs-\(index)",
        runID: "docs",
        kind: .tool,
        title: item["title"] ?? "",
        detail: item["detail"],
        status: AIChatRunActivity.Status(rawValue: item["status"] ?? "") ?? .succeeded
      )
    }
  }

  public func chooseCorpus() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a Celorga corpus directory"

    if panel.runModal() == .OK, let url = panel.url {
      setCorpusRoot(url)
      Task {
        await refreshWorkspace()
        openHome()
        presentLaunchGuideIfNeeded()
      }
    }
  }

  public func presentLaunchGuide() {
    isLaunchGuidePresented = true
  }

  public func dismissLaunchGuide() {
    isLaunchGuidePresented = false
  }

  public func completeLaunchGuide() {
    completeLaunchGuide(destinationID: nil)
  }

  public func completeLaunchGuide(destinationID: String?) {
    if let destinationID {
      let configuredDestinationID: String?
      if aiChatDestination(id: destinationID) != nil {
        configuredDestinationID = destinationID
      } else if let fallback = AIChatDestinationConfiguration.defaults.first(where: {
        $0.id == destinationID
      }) {
        configuredDestinationID = addAIChatDestination(adapter: fallback.adapter)
      } else {
        configuredDestinationID = nil
      }
      if let configuredDestinationID,
         selectedAIChatThread?.destinationID != configuredDestinationID {
        createAIChatThread(destinationID: configuredDestinationID)
      }
    }
    defaults.set(true, forKey: launchGuideCompletedKey)
    isLaunchGuidePresented = false
    selectedSurface = .home
    openHome()
  }

  public var isLocalCodexInstalled: Bool {
    CodexAppServerClient.resolveExecutableURL() != nil
  }

  public var isLocalClaudeCodeInstalled: Bool {
    ClaudeCodeClient.resolveExecutableURL() != nil
  }

  public func suggestedLaunchGuideDestinationID() -> String? {
    if isLocalCodexInstalled { return AIChatDestinationConfiguration.localCodexID }
    if isLocalClaudeCodeInstalled { return AIChatDestinationConfiguration.localClaudeID }
    return nil
  }

  public func launchGuideRevealWorkspace() {
    guard let corpusRoot else { return }
    NSWorkspace.shared.activateFileViewerSelecting([corpusRoot])
  }

  private func presentLaunchGuideIfNeeded() {
    guard !defaults.bool(forKey: launchGuideCompletedKey) else { return }
    isLaunchGuidePresented = true
  }

  public func createCorpus() {
    createCorpus(kind: "personal")
  }

  public func createSharedCorpus() {
    createCorpus(kind: "shared")
  }

  private func createCorpus(kind: String) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = kind == "shared" ? "Create Shared Corpus" : "Create Corpus"
    panel.message = kind == "shared"
      ? "Choose or create an empty folder or repository for the shared Celorga corpus"
      : "Choose or create an empty folder for the new Celorga corpus"

    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      _ = try Self.initializeStarterCorpus(at: url, kind: kind)
      setCorpusRoot(url)
      selectedSurface = .home
      statusText = "Created starter corpus at \(url.standardizedFileURL.path)"
      Task {
        await refreshWorkspace()
        openHome()
        presentLaunchGuideIfNeeded()
      }
    } catch {
      statusText = error.localizedDescription
      errorText = error.localizedDescription
    }
  }

  nonisolated static func defaultStarterCorpusURL(
    fileManager: FileManager = .default
  ) -> URL {
    let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
    return starterCorpusURL(inDocuments: documents, fileManager: fileManager)
  }

  /// New workspaces go in `Documents/Celorga`. A workspace an earlier OpenOrg
  /// release created in `Documents/OpenOrg` is reused instead of starting a second one.
  nonisolated static func starterCorpusURL(
    inDocuments documents: URL,
    fileManager: FileManager = .default
  ) -> URL {
    let legacy = documents.appendingPathComponent("OpenOrg", isDirectory: true)
    if CelorgaNames.hasConfigFile(in: legacy, fileManager: fileManager) {
      return legacy.standardizedFileURL
    }
    return documents.appendingPathComponent("Celorga", isDirectory: true).standardizedFileURL
  }

  nonisolated static func prepareAutomaticStarterCorpus(
    preferredRoot: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    let preferred = preferredRoot.standardizedFileURL
    let parent = preferred.deletingLastPathComponent()
    let baseName = preferred.lastPathComponent.isEmpty ? "Celorga" : preferred.lastPathComponent

    for suffix in 1...100 {
      let candidate = suffix == 1
        ? preferred
        : parent.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
      var isDirectory: ObjCBool = false
      if !fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
        _ = try initializeStarterCorpus(at: candidate)
        return candidate
      }
      guard isDirectory.boolValue else { continue }
      if CelorgaNames.hasConfigFile(in: candidate, fileManager: fileManager) {
        return candidate
      }
      let visibleEntries = try fileManager.contentsOfDirectory(
        at: candidate,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
      if visibleEntries.isEmpty {
        _ = try initializeStarterCorpus(at: candidate)
        return candidate
      }
    }

    throw StarterCorpusCreationError.notEmpty(preferred.path)
  }

  nonisolated static func initializeStarterCorpus(at url: URL, kind: String = "personal") throws -> URL {
    let fileManager = FileManager.default
    let root = url.standardizedFileURL
    var isDirectory: ObjCBool = false

    if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw StarterCorpusCreationError.notDirectory(root.path)
      }
    } else {
      try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    let visibleEntries = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    guard visibleEntries.isEmpty else {
      throw StarterCorpusCreationError.notEmpty(root.path)
    }

    for directory in ["notes", "daily", "views", "compiled", "workflows"] {
      try fileManager.createDirectory(
        at: root.appendingPathComponent(directory, isDirectory: true),
        withIntermediateDirectories: true
      )
    }

    let name = root.lastPathComponent.isEmpty ? "Celorga Corpus" : root.lastPathComponent
    let normalizedKind = kind == "shared" ? "shared" : kind == "project" ? "project" : "personal"
    let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)
    let identity = CorpusIdentity(
      schema: "org2:corpus:v1",
      id: "\(normalizedKind)-\(suffix)",
      name: name,
      kind: normalizedKind
    )
    let identityData = try JSONEncoder().encode(identity)
    let identityObject = try JSONSerialization.jsonObject(with: identityData)
    let config: [String: Any] = [
      "corpus": identityObject,
      "agendaFiles": ["inbox.org", "inbox.org2", "notes/**/*.org", "notes/**/*.org2", "daily/**/*.org", "daily/**/*.org2"],
      "recursive": true,
      "ignorePatterns": [".git/**", ".#*", "compiled/**"],
      "roam": ["indexDir": "notes", "nodesDir": "notes", "dailiesDir": "daily"]
    ]
    let configData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    try (configData + Data("\n".utf8)).write(to: root.appendingPathComponent(CelorgaNames.configFileName), options: .atomic)

    let inbox = """
    #+TITLE: Inbox

    * Inbox

    This optional intake buffer is for importers or sync clients that cannot safely append to an actively edited daily note. Mac capture appends to today's daily note.
    """
    try (inbox + "\n").write(
      to: root.appendingPathComponent("inbox.org"),
      atomically: true,
      encoding: .utf8
    )

    let welcomeURL = root.appendingPathComponent("notes/welcome.org")
    let welcome = """
    #+TITLE: Welcome to Celorga

    * Your workspace

    Celorga keeps its source of truth in this ordinary folder. Start on Home: ask your connected agent a question, or write directly in today's note beside the chat.

    - Daily notes live in =daily/=.
    - Longer-lived notes live in =notes/=.
    - Agent output stays reviewable in =views/= or =compiled/=.
    - Open =Help → Getting Started= whenever you want to reconnect an agent or review the basics.

    You can move or rename this folder, open the files in another editor, and change its name or location later in Celorga settings.
    """
    try (welcome + "\n").write(to: welcomeURL, atomically: true, encoding: .utf8)
    try BuiltInOrg2Skill.installIfAbsent(in: root)
    return welcomeURL
  }

  public func setCorpusRoot(_ url: URL, persistsDefault: Bool = true) {
    setCorpusRoot(url, persistsDefault: persistsDefault, aiChatMigrationSource: nil)
  }

  func isCurrentCorpusSession(root: URL, generation: UInt64) -> Bool {
    guard corpusSessionGeneration == generation,
          let corpusRoot
    else {
      return false
    }
    return corpusRoot.standardizedFileURL.path == root.standardizedFileURL.path
  }

  func captureDocumentCorpusContext(mutationRoot: URL? = nil) -> WorkspaceDocumentCorpusContext? {
    guard let effectiveMutationRoot = mutationRoot ?? corpusRoot else { return nil }
    let activeRootPath = WorkspaceDocumentMutationLane.canonicalPath(
      (corpusRoot ?? effectiveMutationRoot).path
    )
    let mutationRootPath = WorkspaceDocumentMutationLane.canonicalPath(effectiveMutationRoot.path)
    return WorkspaceDocumentCorpusContext(
      activeCorpusRootPath: activeRootPath,
      mutationRootPath: mutationRootPath,
      corpusSessionGeneration: corpusSessionGeneration
    )
  }

  func captureDocumentCorpusContext(forFile file: String) -> WorkspaceDocumentCorpusContext? {
    let filePath = WorkspaceDocumentMutationLane.canonicalPath(file)
    let owningRootPath = workspaceMountPaths()
      .map(WorkspaceDocumentMutationLane.canonicalPath)
      .filter { rootPath in
        filePath == rootPath || filePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
      }
      .max(by: { $0.count < $1.count })
    guard let owningRootPath else { return nil }
    return captureDocumentCorpusContext(mutationRoot: URL(fileURLWithPath: owningRootPath))
  }

  func isCurrentDocumentCorpusContext(_ context: WorkspaceDocumentCorpusContext) -> Bool {
    corpusSessionGeneration == context.corpusSessionGeneration
      && corpusRoot.map { WorkspaceDocumentMutationLane.canonicalPath($0.path) } == context.activeCorpusRootPath
  }

  func isCurrentAssignedWorkRefresh(_ context: AssignedWorkRefreshContext) -> Bool {
    !Task.isCancelled && activeAssignedWorkRefreshRequestID == context.requestID
      && assignedWorkRefreshRequestGeneration == context.requestGeneration
      && isCurrentDocumentCorpusContext(context.corpus)
  }

  func isCurrentSimilarTodoScan(_ context: SimilarTodoScanContext) -> Bool {
    guard !Task.isCancelled, similarTodoScanRequestGeneration == context.requestGeneration,
          isCurrentDocumentCorpusContext(context.corpus),
          let target = selectedHeadlineMutationTarget
    else {
      return false
    }
    let targetPath = WorkspaceDocumentMutationLane.canonicalPath(target.file)
    guard targetPath == context.targetFile else { return false }
    if let expectedID = context.targetID, let currentID = target.idValue {
      return expectedID == currentID
    }
    return target.line == context.targetLine
      && Self.normalizedApprovalActionTitle(target.title)
        == Self.normalizedApprovalActionTitle(context.targetTitle)
  }

  func invalidateWorkspaceSearchRequest() {
    workspaceSearchRequestGeneration &+= 1
    isSearching = false
  }

  func captureWorkspaceSearchRequest(query: String) -> WorkspaceSearchRequestContext {
    workspaceSearchRequestGeneration &+= 1
    return WorkspaceSearchRequestContext(
      requestGeneration: workspaceSearchRequestGeneration,
      corpusRootPath: corpusRoot?.standardizedFileURL.path,
      corpusSessionGeneration: corpusSessionGeneration,
      query: query,
      readScope: searchReadScope,
      transcriptPath: aiChatTranscriptURL.standardizedFileURL.path,
      transcriptLoadGeneration: aiChatTranscriptLoadGeneration
    )
  }

  func isCurrentWorkspaceSearchRequest(_ context: WorkspaceSearchRequestContext) -> Bool {
    workspaceSearchRequestGeneration == context.requestGeneration
      && corpusSessionGeneration == context.corpusSessionGeneration
      && corpusRoot?.standardizedFileURL.path == context.corpusRootPath
      && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == context.query
      && searchReadScope == context.readScope
      && aiChatTranscriptURL.standardizedFileURL.path == context.transcriptPath
      && aiChatTranscriptLoadGeneration == context.transcriptLoadGeneration
  }

  func runReviewPageLoadState(for page: RunsAndReviewPage) -> RunReviewPageLoadState {
    let rootPath = corpusRoot?.standardizedFileURL.path
    if let state = runReviewPageLoadStates[page.rawValue],
       state.corpusRootPath == rootPath,
       state.corpusSessionGeneration == corpusSessionGeneration {
      return state
    }
    return RunReviewPageLoadState(
      corpusRootPath: rootPath,
      corpusSessionGeneration: corpusSessionGeneration,
      isLoaded: false,
      isDirty: true,
      dirtyGeneration: 0
    )
  }

  func markRunReviewPagesDirty(_ pages: [RunsAndReviewPage] = RunsAndReviewPage.allCases) {
    for page in pages {
      var state = runReviewPageLoadState(for: page)
      state.isDirty = true
      state.dirtyGeneration &+= 1
      runReviewPageLoadStates[page.rawValue] = state
    }
  }

  func captureRunReviewPageRefresh(
    _ page: RunsAndReviewPage
  ) -> RunReviewPageRefreshContext? {
    guard let rootPath = corpusRoot?.standardizedFileURL.path else { return nil }
    let state = runReviewPageLoadState(for: page)
    runReviewPageLoadStates[page.rawValue] = state
    return RunReviewPageRefreshContext(
      page: page,
      corpusRootPath: rootPath,
      corpusSessionGeneration: corpusSessionGeneration,
      dirtyGeneration: state.dirtyGeneration
    )
  }

  func isCurrentRunReviewPageRefresh(_ context: RunReviewPageRefreshContext) -> Bool {
    corpusSessionGeneration == context.corpusSessionGeneration
      && corpusRoot?.standardizedFileURL.path == context.corpusRootPath
  }

  func markRunReviewPageRefreshTerminal(_ context: RunReviewPageRefreshContext) {
    guard !Task.isCancelled, isCurrentRunReviewPageRefresh(context) else { return }
    var state = runReviewPageLoadState(for: context.page)
    state.isLoaded = true
    if state.dirtyGeneration == context.dirtyGeneration {
      state.isDirty = false
    }
    runReviewPageLoadStates[context.page.rawValue] = state
  }

  func markRunReviewPageLoaded(_ page: RunsAndReviewPage) {
    var state = runReviewPageLoadState(for: page)
    state.isLoaded = true
    state.isDirty = false
    runReviewPageLoadStates[page.rawValue] = state
  }

  func runReviewPageNeedsRefresh(_ page: RunsAndReviewPage) -> Bool {
    let state = runReviewPageLoadState(for: page)
    return !state.isLoaded || state.isDirty
  }

  func isRunReviewPageLoadedForTesting(_ page: RunsAndReviewPage) -> Bool {
    runReviewPageLoadState(for: page).isLoaded
  }

  func isRunReviewPageDirtyForTesting(_ page: RunsAndReviewPage) -> Bool {
    runReviewPageLoadState(for: page).isDirty
  }

  func captureAIChatCorpusContext() -> AIChatCorpusContextToken {
    AIChatCorpusContextToken(
      corpusRootPath: corpusRoot?.standardizedFileURL.path,
      corpusSessionGeneration: corpusSessionGeneration,
      transcriptPath: aiChatTranscriptURL.standardizedFileURL.path,
      transcriptLoadGeneration: aiChatTranscriptLoadGeneration
    )
  }

  func isCurrentAIChatCorpusContext(_ context: AIChatCorpusContextToken) -> Bool {
    corpusSessionGeneration == context.corpusSessionGeneration
      && corpusRoot?.standardizedFileURL.path == context.corpusRootPath
      && aiChatTranscriptURL.standardizedFileURL.path == context.transcriptPath
      && aiChatTranscriptLoadGeneration == context.transcriptLoadGeneration
  }

  func isCurrentAIChatAttachmentContext(_ context: AIChatCorpusContextToken) -> Bool {
    corpusSessionGeneration == context.corpusSessionGeneration
      && corpusRoot?.standardizedFileURL.path == context.corpusRootPath
      && aiChatTranscriptURL.standardizedFileURL.path == context.transcriptPath
  }

  func aiChatComposerKey(
    for threadID: UUID,
    context: AIChatCorpusContextToken? = nil
  ) -> AIChatComposerKey {
    AIChatComposerKey(
      transcriptPath: context?.transcriptPath ?? aiChatTranscriptURL.standardizedFileURL.path,
      threadID: threadID
    )
  }

  private func cacheCurrentCorpusWorkspace() {
    guard let corpusRoot else { return }
    corpusWorkspaceCaches[corpusRoot.standardizedFileURL.path] = CorpusWorkspaceCache(
      cachedAt: Date(),
      identity: activeCorpusIdentity,
      agenda: agenda,
      approvalItems: approvalItems,
      agentRuns: agentRuns,
      agentWorkflows: agentWorkflows,
      agentGoals: agentGoals,
      agentProfiles: agentProfiles,
      corpusFiles: corpusFiles,
      orgRoamLinkResolver: orgRoamLinkResolver,
      searchNodeIndexRows: searchNodeIndexRows,
      assignedWorkItems: assignedWorkItems,
      meetings: meetings,
      sourceProfiles: sourceProfiles,
      sourceRuntimeStatuses: sourceRuntimeStatuses,
      sourceScheduleStates: sourceScheduleStates,
      aiChatThreadRecords: aiChatThreadRecords,
      workspaceHealthChecks: workspaceHealthChecks,
      searchIndexStatusText: searchIndexStatusText,
      dirtySurfaces: dirtyWorkspaceSurfaces,
      runReviewPageLoadStates: runReviewPageLoadStates.mapValues { state in
        CachedRunReviewPageLoadState(
          isLoaded: state.isLoaded,
          isDirty: state.isDirty,
          dirtyGeneration: state.dirtyGeneration
        )
      },
      selectedAgendaItemID: selectedAgendaItemID,
      selectedApprovalItemID: selectedApprovalItemID,
      selectedAgentRunID: selectedAgentRunID,
      selectedAgentWorkflowID: selectedAgentWorkflowID,
      selectedAgentGoalID: selectedAgentGoalID,
      selectedAgentProfileID: selectedAgentProfileID,
      selectedCorpusFileID: selectedCorpusFileID,
      selectedAssignedWorkItemID: selectedAssignedWorkItemID,
      selectedMeetingID: selectedMeetingID,
      selectedAIChatThreadRecordID: selectedAIChatThreadRecordID
    )
  }

  func invalidateCachedCorpusWorkspace(
    at path: String,
    surfaces: Set<WorkspaceSurface>
  ) {
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    guard var cache = corpusWorkspaceCaches[standardizedPath] else { return }
    cache.dirtySurfaces.formUnion(surfaces.filter { $0 != .home })
    if surfaces.contains(.approvals) {
      for page in RunsAndReviewPage.allCases {
        var state = cache.runReviewPageLoadStates[page.rawValue]
          ?? CachedRunReviewPageLoadState(
            isLoaded: false,
            isDirty: true,
            dirtyGeneration: 0
          )
        state.isDirty = true
        state.dirtyGeneration &+= 1
        cache.runReviewPageLoadStates[page.rawValue] = state
      }
    }
    corpusWorkspaceCaches[standardizedPath] = cache
  }

  @discardableResult
  func setCorpusRoot(
    _ url: URL,
    persistsDefault: Bool,
    aiChatMigrationSource: URL?
  ) -> Bool {
    persistLiveFileEditorDraftBeforeNavigation()
    cancelLiveFileEditorAutosave(resetStatus: false)
    saveAIChatComposerForSelectedThread()
    let standardized = url.standardizedFileURL
    corpusSessionGeneration &+= 1
    _ = supersedeDailyNoteNavigation()
    currentHomeDailyNotePath = nil
    assignedWorkRefreshRequestGeneration &+= 1
    activeAssignedWorkRefreshRequestID = nil
    similarTodoScanRequestGeneration &+= 1
    invalidateWorkspaceSearchRequest()
    cacheCurrentCorpusWorkspace()
    let cachedWorkspace = corpusWorkspaceCaches[standardized.path]
    resetCorpusFileCatalogMutations()
    resetCorpusFileDerivedState()
    projectNotes = []
    projectStatus = ""
    projectRefreshTask?.task.cancel()
    projectRefreshTask = nil
    isRefreshingProjects = false
    projectRefreshID = UUID()
    corpusRoot = standardized
    automaticDailyNoteCreationDisabled = restoreAutomaticDailyNoteCreationPreference(
      for: standardized
    )
    automationOwnerHostRef = nil
    prepareDailyNoteDirectory(for: standardized)
    appHTMLStylesheetSnapshotTask?.cancel()
    appHTMLStylesheetSnapshot = AppHTMLStylesheetSnapshot(
      corpusRootPath: standardized.path,
      path: nil,
      identity: "default",
      wasBuiltOnMainThread: false
    )
    scheduleAppHTMLStylesheetSnapshotRefresh()
    runReviewPageLoadStates = Dictionary(uniqueKeysWithValues: RunsAndReviewPage.allCases.map { page in
      let cachedState = cachedWorkspace?.runReviewPageLoadStates[page.rawValue]
      return (
        page.rawValue,
        RunReviewPageLoadState(
          corpusRootPath: standardized.path,
          corpusSessionGeneration: corpusSessionGeneration,
          isLoaded: cachedState?.isLoaded ?? false,
          isDirty: cachedState?.isDirty ?? true,
          dirtyGeneration: cachedState?.dirtyGeneration ?? 0
        )
      )
    })
    refreshCorpusAgentSkills()
    pluginActions = []
    pluginHooks = []
    pendingPluginProposals = []
    corpusAutomationHostRef = nil
    Task { @MainActor [weak self] in await self?.refreshPluginActions() }
    workspaceApps = []
    workspaceAppsRootPath = nil
    workspaceAppsError = nil
    selectedPluginSurface = nil
    crm.reset()
    activeCorpusIdentity = cachedWorkspace?.identity
    upsertCorpusMount(path: standardized.path, identity: nil)
    openClawRemoteCorpusPath = restoreOpenClawRemoteCorpusPath(for: standardized)
    restoreMeetingReadyAutomationState(for: standardized)
    restorePinnedFiles(for: standardized)
    if persistsDefault {
      defaults.set(standardized.path, forKey: corpusKey)
    }
    switchAIChatTranscript(
      to: Self.aiChatTranscriptURL(corpusRoot: standardized),
      migrationSource: aiChatMigrationSource
    )
    agenda = cachedWorkspace?.agenda
    approvalItems = cachedWorkspace?.approvalItems ?? []
    snoozedApprovalItems = []
    showsSnoozedApprovals = false
    approvalSnoozeWakeTask?.cancel()
    approvalSnoozeWakeTask = nil
    selectedAgendaItemID = cachedWorkspace?.selectedAgendaItemID
    agendaSelectionAnchor = selectedAgendaItemID.flatMap { selectedID in
      visibleAgendaItems.first(where: { $0.id == selectedID }).map(AgendaSelectionAnchor.init)
    }
    selectedApprovalItemID = cachedWorkspace?.selectedApprovalItemID
    approvalSelectionAnchor = nil
    approvalFilter = ""
    corpusFiles = cachedWorkspace?.corpusFiles ?? []
    orgRoamLinkResolverGeneration &+= 1
    if let cachedWorkspace {
      publishOrgRoamSearchProjection(
        OrgRoamSearchProjectionBox(
          projection: OrgRoamSearchProjection(
            resolver: cachedWorkspace.orgRoamLinkResolver,
            searchNodeIndexRows: cachedWorkspace.searchNodeIndexRows,
            wasBuiltOnMainThread: false
          ),
          releaseMetrics: orgRoamSearchProjectionReleaseMetrics
        ),
        recordsDetachedBuild: false
      )
    } else {
      publishEmptyOrgRoamSearchProjection()
    }
    selectedCorpusFileID = cachedWorkspace?.selectedCorpusFileID
    selectedCorpusFileIDsForAIContext = []
    corpusFileFilter = ""
    quickOpenQuery = ""
    searchResults = []
    aiChatSearchResults = []
    workspaceFileSearchResults = []
    workspacePageSearchResults = []
    workspaceAgentWorkSearchResults = []
    bulkSelectedAgendaItemIDs = []
    selectedApprovalItemIDsForAIContext = []
    bulkSelectedApprovalItemIDs = []
    assignedWorkItems = cachedWorkspace?.assignedWorkItems ?? []
    selectedAssignedWorkItemID = cachedWorkspace?.selectedAssignedWorkItemID
    meetings = cachedWorkspace?.meetings ?? []
    selectedMeetingID = cachedWorkspace?.selectedMeetingID
    isLoadingMeetings = false
    clearMeetingProcessingState()
    sourceProfiles = cachedWorkspace?.sourceProfiles ?? []
    sourceRuntimeStatuses = cachedWorkspace?.sourceRuntimeStatuses ?? [:]
    sourceScheduleStates = cachedWorkspace?.sourceScheduleStates ?? [:]
    sourceOperationMessages = [:]
    sourceOperationFailureIDs = []
    aiChatThreadRecords = cachedWorkspace?.aiChatThreadRecords ?? []
    selectedAIChatThreadRecordID = cachedWorkspace?.selectedAIChatThreadRecordID
    workspaceHealthChecks = cachedWorkspace?.workspaceHealthChecks ?? []
    refreshOrgCryptManagedRecipientFiles()
    selectedLocation = nil
    missingDailyNote = nil
    isCreatingMissingDailyNote = false
    cancelSourceEditorPreviewRender(clearStatus: true)
    workspaceNavigationBackStack = []
    workspaceNavigationForwardStack = []
    selectedEntrySource = nil
    selectedEntryHTML = nil
    selectedEntryRenderError = nil
    entityActionItemsLoadGeneration += 1
    entityActionItems = nil
    isLoadingEntityActionItems = false
    selectedEntryHTMLRenderKey = nil
    selectedRenderedBlocks = []
    detailScrollRequest = nil
    foldedRenderedBlockIDs = []
    sourceBlockRuns = [:]
    replaceEditableEntryTextFromModel("")
    sourceEditorSelection = NSRange(location: 0, length: 0)
    isRefreshingAgenda = false
    isRefreshingApprovals = false
    approvalRefreshRequestedAfterCurrent = false
    approvalRefreshFollowUpUpdatesStatus = false
    isRefreshingAgentRuns = false
    agentRunsRefreshRequestedAfterCurrent = false
    isRefreshingAgentWorkflows = false
    isRefreshingAgentGoals = false
    isRefreshingAgentProfiles = false
    isRefreshingWorkspace = false
    isRefreshingAssignedWork = false
    isRefreshingAIChatThreadRecords = false
    isLoadingAgenda = false
    isLoadingApprovals = false
    hasCompletedApprovalsLoad = false
    isLoadingAgentRuns = false
    agentRuns = cachedWorkspace?.agentRuns ?? []
    agentWorkflows = cachedWorkspace?.agentWorkflows ?? []
    agentGoals = cachedWorkspace?.agentGoals ?? []
    agentProfiles = cachedWorkspace?.agentProfiles ?? []
    selectedAgentWorkflowID = cachedWorkspace?.selectedAgentWorkflowID
    selectedAgentGoalID = cachedWorkspace?.selectedAgentGoalID
    selectedAgentProfileID = cachedWorkspace?.selectedAgentProfileID
    selectedAgentRunID = cachedWorkspace?.selectedAgentRunID
    selectedAgentRunIDsForAIContext = []
    presentedAgentRunID = nil
    resetWorkspaceTabsForCorpusChange()
    mutatingAgentRunIDs = []
    agentRunClarificationPhases = [:]
    approvingApprovalItemIDs = []
    rejectingApprovalItemIDs = []
    externallyCompletingApprovalItemIDs = []
    repairingApprovalSourceItemIDs = []
    approvalActionErrorsByItemID = [:]
    approvalSourceRepairRetriesByItemID = [:]
    mutatingAgentGoalIDs = []
    mutatingAgentProfileIDs = []
    isLoadingAgentGoals = false
    isLoadingAgentProfiles = false
    isLoadingAssignedWork = false
    hasAttemptedAssignedWorkLoad = false
    isLoadingAIChatThreadRecords = false
    scheduledAgendaRefreshTask?.cancel()
    scheduledAgendaRefreshTask = nil
    scheduledApprovalsRefreshTask?.cancel()
    scheduledApprovalsRefreshTask = nil
    scheduledAgentRunsRefreshTask?.cancel()
    scheduledAgentRunsRefreshTask = nil
    postAIChatWorkspaceRefreshTask?.cancel()
    postAIChatWorkspaceRefreshTask = nil
    corpusEventRefreshGeneration += 1
    runReviewFileEventGeneration += 1
    runReviewFileEventRefreshTask?.cancel()
    runReviewFileEventRefreshTask = nil
    mountedCorpusEventRefreshTask?.cancel()
    mountedCorpusEventRefreshTask = nil
    workspaceSurfaceRefreshTasks.values.forEach { $0.task.cancel() }
    workspaceSurfaceRefreshTasks = [:]
    agendaClockRefreshTask?.cancel()
    agendaClockRefreshTask = nil
    dirtyWorkspaceSurfaces = cachedWorkspace?.dirtySurfaces
      ?? Set(WorkspaceSurface.allCases.filter { $0 != .home })
    if runReviewPageNeedsRefresh(runsAndReviewPage) {
      dirtyWorkspaceSurfaces.insert(.approvals)
    }
    if let cachedWorkspace,
       !Calendar.current.isDate(cachedWorkspace.cachedAt, inSameDayAs: Date()) {
      dirtyWorkspaceSurfaces.insert(.agenda)
    }
    for surface in dirtyWorkspaceSurfaces {
      workspaceSurfaceDirtyGenerations[surface, default: 0] &+= 1
    }
    needsFullCorpusRefreshAfterEvents = false
    pendingCorpusChangedPaths = []
    activeSourceSyncEventBatchCount = 0
    sourceSyncEventBatchNeedsFallbackScan = false
    agendaTodoShortcutMutationTask?.cancel()
    agendaTodoShortcutMutationTask = nil
    pendingAgendaTodoShortcutMutations = []
    agendaRefreshDeferredForTodoShortcutBurst = false
    agendaTodoShortcutMutationGeneration &+= 1
    searchIndexTask?.cancel()
    searchIndexTask = nil
    searchIndexGeneration += 1
    isBuildingSearchIndex = false
    searchIndexStatusText = cachedWorkspace?.searchIndexStatusText ?? ""
    isScanningCorpusFiles = false
    resetBlockState()
    isEditingEntry = false
    isLoadingEntrySource = false
    isRenderingEntrySource = false
    selectedDetailFreshnessTask?.cancel()
    selectedDetailFreshnessTask = nil
    entrySourceLoadWatchdogTask?.cancel()
    entrySourceLoadWatchdogTask = nil
    entryHTMLRenderWatchdogTask?.cancel()
    entryHTMLRenderWatchdogTask = nil
    entryHTMLRenderTask?.cancel()
    entryHTMLRenderTask = nil
    entrySourceLoadGeneration += 1
    entryHTMLRenderGeneration += 1
    activeEntrySourceLoadingGeneration = nil
    backlinksLoadTask?.cancel()
    backlinksLoadTask = nil
    backlinksLoadGeneration += 1
    isLoadingBacklinks = false
    workspaceRefreshOperationTask?.cancel()
    workspaceRefreshOperationTask = nil
    workspaceRefreshSlowNoticeTask?.cancel()
    workspaceRefreshSlowNoticeTask = nil
    workspaceRefreshGeneration += 1
    backlinks = nil
    errorText = nil
    rebuildCorpusFileWatchers()
    scheduleAIChatInboxDrain()
    scheduleAgendaClockInvalidation()
    if openClawLocalEditsEnabled, openClawLocalEditNodeTask == nil {
      startOpenClawLocalEditNode()
    }
    return cachedWorkspace != nil
  }

  public func switchCorpus(to mount: WorkspaceCorpusMount) {
    guard !isSwitchingCorpus && !isRefreshingWorkspace else {
      statusText = "Wait for the current workspace refresh before switching corpora."
      return
    }
    guard !hasActiveEdit && !liveFileEditorHasUnsavedChanges else {
      errorText = "Save or cancel the current edit before switching corpora."
      statusText = "Unsaved edit"
      return
    }
    guard isDirectory(mount.path) else {
      errorText = "The mounted corpus is not available at \(mount.path)."
      statusText = "Corpus unavailable"
      return
    }
    let restoredCachedWorkspace = setCorpusRoot(
      URL(fileURLWithPath: mount.path),
      persistsDefault: true,
      aiChatMigrationSource: nil
    )
    statusText = "Switched to \(mount.name)"
    isSwitchingCorpus = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      if restoredCachedWorkspace {
        await self.refreshWorkspaceSurfaceIfDirty(self.selectedSurface)
      } else {
        await self.refreshWorkspace()
      }
      self.isSwitchingCorpus = false
    }
  }

  public func forgetCorpus(_ mount: WorkspaceCorpusMount) {
    guard corpusRoot?.standardizedFileURL.path != mount.path else {
      errorText = "Switch to another corpus before forgetting the active corpus."
      return
    }
    mountedCorpora.removeAll { $0.path == mount.path }
    corpusWorkspaceCaches.removeValue(forKey: mount.path)
    persistCorpusMounts()
    rebuildCorpusFileWatchers()
  }

  public func reloadCorpusTodoConfiguration() async {
    for file in Array(canonicalDocumentCache.keys) { invalidateCanonicalDocumentCache(for: file) }
    await refreshAgenda(preserveSelection: true, updatesStatus: false)
    if isEditingEntry { scheduleSourceEditorPreview(immediate: true) }
    else { await reloadSelectedEntrySource() }
  }

  public func refreshActiveCorpusIdentity() async {
    guard let corpusRoot else {
      activeCorpusIdentity = nil
      return
    }
    let sessionGeneration = corpusSessionGeneration
    do {
      let status: CorpusIdentityStatus = try await cli.runJSON([
        "corpus", "show", "--dir", corpusRoot.path, "--json"
      ])
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      activeCorpusIdentity = status.identity
      upsertCorpusMount(path: corpusRoot.path, identity: status.identity)
    } catch {
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      activeCorpusIdentity = nil
      upsertCorpusMount(path: corpusRoot.path, identity: nil)
    }
  }

  public func updateActiveCorpusIdentity(name rawName: String, kind rawKind: String) async -> Bool {
    guard let corpusRoot, let identity = activeCorpusIdentity else {
      errorText = "Open a corpus before changing its information."
      return false
    }
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let kind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !name.isEmpty else {
      errorText = "Corpus name cannot be empty."
      return false
    }
    guard ["personal", "project", "shared"].contains(kind) else {
      errorText = "Corpus kind must be personal, project, or shared."
      return false
    }

    let arguments = [
      "corpus", "init",
      "--dir", corpusRoot.path,
      "--id", identity.id,
      "--name", name,
      "--kind", kind,
      "--json"
    ]
    do {
      _ = try await cli.run(arguments)
      _ = try await cli.run(arguments + ["--apply"])
      await refreshActiveCorpusIdentity()
      statusText = "Updated corpus information"
      return true
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not update corpus information"
      return false
    }
  }

  private func upsertCorpusMount(path: String, identity: CorpusIdentity?) {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    let existing = mountedCorpora.first { $0.path == standardized }
    let mount = WorkspaceCorpusMount(
      path: standardized,
      corpusID: identity?.id ?? existing?.corpusID,
      name: identity?.name ?? existing?.name ?? URL(fileURLWithPath: standardized).lastPathComponent,
      kind: identity?.kind ?? existing?.kind
    )
    if let index = mountedCorpora.firstIndex(where: { $0.path == standardized }) {
      mountedCorpora[index] = mount
    } else {
      mountedCorpora.append(mount)
    }
    mountedCorpora.sort { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
    persistCorpusMounts()
    rebuildCorpusFileWatchers()
  }

  private func persistCorpusMounts() {
    guard let data = try? JSONEncoder().encode(mountedCorpora) else { return }
    defaults.set(data, forKey: corpusMountsKey)
  }

  func workspaceMountPaths() -> [String] {
    var paths: [String] = []
    if let corpusRoot {
      paths.append(corpusRoot.standardizedFileURL.path)
    }
    paths.append(contentsOf: mountedCorpora.map(\.path))
    var seen = Set<String>()
    return paths
      .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
      .filter { seen.insert($0).inserted }
  }

  private func rebuildCorpusFileWatchers() {
    guard !Self.shouldIgnoreStandardDefaultsForTests(defaults) else {
      corpusFileWatchers = [:]
      return
    }
    guard corpusRoot != nil else {
      corpusFileWatchers = [:]
      return
    }
    let desiredPaths = Set(workspaceMountPaths().filter(isDirectory))
    for path in Array(corpusFileWatchers.keys) where !desiredPaths.contains(path) {
      corpusFileWatchers.removeValue(forKey: path)
    }
    for path in desiredPaths where corpusFileWatchers[path] == nil {
      let root = URL(fileURLWithPath: path).standardizedFileURL
      corpusFileWatchers[path] = CorpusFileWatcher(rootURL: root) { [weak self] paths, requiresFullScan in
        Task { @MainActor [weak self] in
          self?.handleCorpusFileEvents(
            paths,
            corpusRoot: root,
            requiresFullScan: requiresFullScan
          )
        }
      }
    }
  }

  func handleCorpusFileEvents(
    _ paths: [String],
    corpusRoot eventRoot: URL,
    requiresFullScan: Bool
  ) {
    let classified = Self.classifyCorpusFileEvents(paths, corpusRoot: eventRoot)
    let hasAgentSkillChanges = paths.contains {
      URL(fileURLWithPath: $0).lastPathComponent == "SKILL.md"
    }
    let activeRootPath = corpusRoot?.standardizedFileURL.path
    let isActiveCorpus = eventRoot.standardizedFileURL.path == activeRootPath

    if classified.hasConfigurationChanges {
      invalidateDailyNoteDirectory(for: eventRoot)
    }

    guard isActiveCorpus else {
      var cachedSurfaces: Set<WorkspaceSurface>
      if requiresFullScan || classified.hasConfigurationChanges {
        cachedSurfaces = Set(WorkspaceSurface.allCases.filter { $0 != .home })
      } else {
        cachedSurfaces = classified.contentPaths.isEmpty
          ? []
          : Self.invalidatedWorkspaceSurfaces(
              for: classified.contentPaths,
              corpusRoot: eventRoot
            ).union([.files])
      }
      if classified.hasAgentRunStateChanges {
        cachedSurfaces.insert(.approvals)
      }
      invalidateCachedCorpusWorkspace(
        at: eventRoot.path,
        surfaces: cachedSurfaces
      )

      var surfaces = Set<WorkspaceSurface>()
      if agendaReadScope == .allCorpora,
         requiresFullScan || !classified.contentPaths.isEmpty || classified.hasConfigurationChanges {
        surfaces.insert(.agenda)
      }
      if searchReadScope == .allCorpora,
         requiresFullScan || !classified.contentPaths.isEmpty || classified.hasConfigurationChanges {
        surfaces.insert(.search)
      }
      guard !surfaces.isEmpty else { return }
      markWorkspaceSurfacesDirty(surfaces, refreshVisible: false)
      scheduleMountedCorpusProjectionRefresh()
      return
    }

    if !requiresFullScan, !classified.pdfPreviewPaths.isEmpty {
      scheduleSelectedPDFPreviewRefresh(for: classified.pdfPreviewPaths)
    }
    if !requiresFullScan, !classified.mediaPreviewPaths.isEmpty {
      refreshSelectedMediaPreview(for: classified.mediaPreviewPaths)
    }
    // A rendered HTML page reloads when its file (or a sibling asset) changes.
    if let selected = selectedLocation?.file, Self.isHTMLFile(selected) {
      let directory = URL(fileURLWithPath: selected).deletingLastPathComponent().standardizedFileURL.path + "/"
      if classified.contentPaths.contains(where: { $0.hasPrefix(directory) })
          || classified.mediaPreviewPaths.contains(where: { $0.hasPrefix(directory) }) {
        linkedMediaPreviewRevision &+= 1
      }
    }
    recordCorpusFileEvents(classified.contentPaths)
    if requiresFullScan || !classified.contentPaths.isEmpty || classified.hasConfigurationChanges {
      // Embed contents are derived from other notes. Host-text cache keys alone
      // cannot detect source edits, deletion, newly created IDs, or ambiguity.
      let embedKeys = renderedHTMLCache.compactMap { key, box in
        LiveEmbedPresentation.containsEmbeds(box.value.html) ? key : nil
      }
      releaseWorkspaceCacheBoxesOffMain(embedKeys.compactMap { renderedHTMLCache.removeValue(forKey: $0) })
      renderedHTMLCacheOrder.removeAll { embedKeys.contains($0) }
      if LiveEmbedPresentation.containsEmbeds(selectedEntryHTML)
          || (liveEmbedSourceID != nil && liveEmbedSourceID == selectedEntrySource?.id) {
        retrySelectedEntryRendering()
      }
      if isEditingEntry, LiveEmbedPresentation.containsEmbeds(sourceEditorPreviewHTML) {
        scheduleSourceEditorPreview(immediate: true)
      }
    }
    if classified.hasConfigurationChanges {
      prepareDailyNoteDirectory(for: eventRoot)
      scheduleAppHTMLStylesheetSnapshotRefresh()
      refreshOrgRoamLinkResolver(files: corpusFiles)
    }
    if classified.hasConfigurationChanges || hasAgentSkillChanges {
      refreshCorpusAgentSkills(force: true)
    }
    if classified.hasConfigurationChanges, workspaceAppsRootPath != nil {
      // Another Mac may have turned an app on or off in celorga.json.
      Task { @MainActor [weak self] in await self?.refreshWorkspaceApps() }
    }
    if requiresFullScan || !classified.contentPaths.isEmpty {
      crm.markStale()
      if isWorkspaceAppEnabled("crm"), let root = corpusRoot?.standardizedFileURL.path {
        crm.scheduleRefresh(cli: cli, root: root, visible: [.people, .companies].contains(selectedSurface))
      }
    }
    if requiresFullScan || classified.hasConfigurationChanges {
      scheduleFullCorpusFileRefreshAfterEvents()
    } else if !classified.contentPaths.isEmpty {
      markWorkspaceSurfacesDirty(
        Self.invalidatedWorkspaceSurfaces(
          for: classified.contentPaths,
          corpusRoot: eventRoot
        ),
        refreshVisible: false
      )
      scheduleIncrementalCorpusRefresh(classified.contentPaths)
    }
    if classified.hasAgentRunStateChanges {
      markWorkspaceSurfacesDirty([.approvals, .search], refreshVisible: false)
      scheduleRunReviewRefreshAfterEvents()
    }
    if requiresFullScan || classified.hasAIChatTranscriptChanges {
      scheduleSyncedAIChatTranscriptRefresh()
    }
    if requiresFullScan || classified.hasAIChatLiveChanges {
      scheduleAIChatLiveRefresh()
    }
    if requiresFullScan || classified.hasAIChatInboxChanges {
      scheduleAIChatInboxDrain()
    }
  }

  nonisolated static func invalidatedWorkspaceSurfaces(
    for changedPaths: [String],
    corpusRoot: URL
  ) -> Set<WorkspaceSurface> {
    let rootPrefix = corpusRoot.standardizedFileURL.path + "/"
    var surfaces: Set<WorkspaceSurface> = [.agenda, .approvals, .search]
    let aiChatThreadRecordDirectoryPrefixes = aiChatThreadRecordDirectories(corpusRoot: corpusRoot)
      .map { $0.standardizedFileURL.path + "/" }
    if changedPaths.contains(where: { rawPath in
      let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
      return aiChatThreadRecordDirectoryPrefixes.contains { path.hasPrefix($0) }
    }) {
      surfaces.insert(.aiChat)
    }
    if changedPaths.contains(where: { rawPath in
      let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
      guard path.hasPrefix(rootPrefix) else { return false }
      let relativePath = String(path.dropFirst(rootPrefix.count))
      return relativePath.hasPrefix("meetings/") || relativePath.hasPrefix("raw/")
    }) {
      surfaces.insert(.meetings)
    }
    return surfaces
  }

  private func scheduleMountedCorpusProjectionRefresh() {
    mountedCorpusEventRefreshTask?.cancel()
    guard isWorkspaceRealtimeRefreshActive else { return }
    mountedCorpusEventRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled, let self else { return }
      self.mountedCorpusEventRefreshTask = nil
      await self.refreshWorkspaceSurfaceIfDirty(self.selectedSurface)
    }
  }

  func workspaceMountArguments() -> [String] {
    workspaceMountPaths().flatMap { ["--mount", $0] }
  }

  static func restoreCorpusMounts(from defaults: UserDefaults, key: String) -> [WorkspaceCorpusMount] {
    guard let data = defaults.data(forKey: key),
          let mounts = try? JSONDecoder().decode([WorkspaceCorpusMount].self, from: data)
    else { return [] }
    var seen = Set<String>()
    return mounts.filter { seen.insert($0.path).inserted }
  }

  public func refreshWorkspace() async {
    guard !isRefreshingWorkspace else { return }
    workspaceRefreshGeneration += 1
    let generation = workspaceRefreshGeneration
    isRefreshingWorkspace = true
    workspaceRefreshMetrics = []
    errorText = nil

    let operation = Task { @MainActor [weak self] in
      guard let self else { return }
      if let testOperation = self.workspaceRefreshOperationForTesting {
        await testOperation()
      } else {
        await self.performWorkspaceRefresh(generation: generation)
      }
      guard generation == self.workspaceRefreshGeneration,
            !Task.isCancelled
      else { return }
      self.finishWorkspaceRefresh(generation: generation)
    }
    workspaceRefreshOperationTask = operation
    scheduleWorkspaceRefreshSlowNotice(generation: generation)

    while generation == workspaceRefreshGeneration, isRefreshingWorkspace {
      if Task.isCancelled {
        cancelWorkspaceRefresh(message: "Workspace refresh canceled")
        return
      }
      do {
        try await Task.sleep(nanoseconds: 20_000_000)
      } catch {
        cancelWorkspaceRefresh(message: "Workspace refresh canceled")
        return
      }
    }
  }

  private func performWorkspaceRefresh(generation: Int) async {
    let started = ContinuousClock.now
    // Refresh the visible document first; the remaining independent jobs use
    // two lanes. Files and assigned work remain an ordered dependency chain.
    for stage in [WorkspaceRefreshStage.audio, .document, .identity] {
      await performWorkspaceRefreshStage(stage, generation: generation)
    }
    guard shouldContinueWorkspaceRefresh(generation) else { return }
    startPendingAIChatTurnRecovery()
    await WorkspaceRefreshScheduler.run(
      stages: [.agenda, .files, .approvals, .agentState, .meetings, .sources, .threads],
      concurrency: workspaceRefreshConcurrencyForTesting
    ) { [weak self] stage in
      guard let self else { return }
      await self.performWorkspaceRefreshStage(stage, generation: generation)
      if stage == .files {
        await self.performWorkspaceRefreshStage(.assignedWork, generation: generation)
      }
    }
    guard shouldContinueWorkspaceRefresh(generation) else { return }
    refreshWorkspaceHealth()
    refreshOrgCryptManagedRecipientFiles()
    recordWorkspaceRefreshMetric(stage: "total", started: started)
  }

  private func performWorkspaceRefreshStage(_ stage: WorkspaceRefreshStage, generation: Int) async {
    guard shouldContinueWorkspaceRefresh(generation) else { return }
    let started = ContinuousClock.now
    switch stage {
    case .audio: await refreshAudioSettingsStatusAsync(preserveStatusText: true)
    case .document: await refreshSelectedDetailFromDisk()
    case .identity: await refreshActiveCorpusIdentity()
    case .agenda: await refreshAgenda(clearsError: false)
    case .meetings: await refreshMeetings()
    case .sources: await refreshSourceConnections()
    case .files: await refreshCorpusFiles()
    case .assignedWork: await refreshAssignedWork()
    case .approvals: await refreshApprovals(clearsError: false)
    case .agentState: await refreshWorkspaceAgentState(generation: generation)
    case .threads: await refreshAIChatThreadRecords()
    }
    guard shouldContinueWorkspaceRefresh(generation) else { return }
    recordWorkspaceRefreshMetric(stage: stage.rawValue, started: started)
  }

  private func recordWorkspaceRefreshMetric(stage: String, started: ContinuousClock.Instant) {
    let duration = started.duration(to: .now).components
    let metric = WorkspaceRefreshMetric(stage: stage,
      elapsedMilliseconds: Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
    workspaceRefreshMetrics.append(metric)
    WorkspaceRefreshScheduler.record(metric)
  }

  private func refreshWorkspaceAgentState(generation: Int) async {
    guard let root = corpusRoot else { return }
    if workspaceRefreshUsesBatchForTesting {
      do {
        let pages: [RunsAndReviewPage] = [.runs, .workflows, .goals, .agents]
        let revisions = Dictionary(uniqueKeysWithValues: pages.map {
          ($0, runReviewPageLoadState(for: $0).dirtyGeneration)
        })
        let projectsRevision = projectRefreshID
        let snapshot: WorkspaceAgentStateSnapshot
        if let workspaceAgentStateLoaderForTesting {
          snapshot = try await workspaceAgentStateLoaderForTesting()
        } else {
          snapshot = try await cli.runJSON([
            "workspace", "agent-state", "--dir", root.path, "--json"
          ])
        }
        // Invalidation during the batch read must not mark a stale section clean.
        func isFresh(_ page: RunsAndReviewPage) -> Bool {
          revisions[page] == runReviewPageLoadState(for: page).dirtyGeneration
        }
        guard shouldContinueWorkspaceRefresh(generation) else { return }
        await refreshAgentRuns(prefetched: isFresh(.runs) ? snapshot.runs : nil)
        guard shouldContinueWorkspaceRefresh(generation) else { return }
        await refreshAgentWorkflows(prefetched: isFresh(.workflows) ? snapshot.workflows : nil)
        guard shouldContinueWorkspaceRefresh(generation) else { return }
        await refreshAgentGoals(prefetched: isFresh(.goals) ? snapshot.goals : nil)
        guard shouldContinueWorkspaceRefresh(generation) else { return }
        await refreshAgentProfiles(prefetched: isFresh(.agents) ? snapshot.profiles : nil)
        guard shouldContinueWorkspaceRefresh(generation) else { return }
        if projectsRevision == projectRefreshID, let projects = snapshot.projects { applyProjectList(try projects.get()) }
        return
      } catch {
        // Custom/older CLI installations can still use the ordinary list APIs.
        guard shouldContinueWorkspaceRefresh(generation) else { return }
      }
    }
    await refreshAgentRuns()
    guard shouldContinueWorkspaceRefresh(generation) else { return }
    await refreshAgentWorkflows()
    guard shouldContinueWorkspaceRefresh(generation) else { return }
    await refreshAgentGoals()
    guard shouldContinueWorkspaceRefresh(generation) else { return }
    await refreshAgentProfiles()
    guard shouldContinueWorkspaceRefresh(generation) else { return }
    await refreshProjects()
  }

  private func shouldContinueWorkspaceRefresh(_ generation: Int) -> Bool {
    generation == workspaceRefreshGeneration && isRefreshingWorkspace && !Task.isCancelled
  }

  private func scheduleWorkspaceRefreshSlowNotice(generation: Int) {
    workspaceRefreshSlowNoticeTask?.cancel()
    let delay = workspaceRefreshSlowNoticeNanoseconds
    workspaceRefreshSlowNoticeTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
      } catch {
        return
      }
      guard let self,
            generation == self.workspaceRefreshGeneration,
            self.isRefreshingWorkspace
      else { return }
      // Elapsed wall time alone is not a failure: a full refresh reconciles
      // many projections sequentially. Let it finish unless the user cancels.
      if self.errorText == nil {
        self.statusText = Self.workspaceRefreshSlowNotice
      }
    }
  }

  private func finishWorkspaceRefresh(generation: Int) {
    guard generation == workspaceRefreshGeneration else { return }
    if statusText == Self.workspaceRefreshSlowNotice {
      statusText = errorText ?? "Workspace refresh finished."
    }
    workspaceRefreshSlowNoticeTask?.cancel()
    workspaceRefreshSlowNoticeTask = nil
    workspaceRefreshOperationTask = nil
    isRefreshingWorkspace = false
  }

  public func cancelWorkspaceRefresh() {
    cancelWorkspaceRefresh(message: "Workspace refresh canceled. Existing workspace data is still available.")
  }

  func cancelWorkspaceRefresh(message: String) {
    guard isRefreshingWorkspace else { return }
    workspaceRefreshGeneration += 1
    workspaceRefreshOperationTask?.cancel()
    workspaceRefreshOperationTask = nil
    workspaceRefreshSlowNoticeTask?.cancel()
    workspaceRefreshSlowNoticeTask = nil
    isRefreshingWorkspace = false
    isLoadingAgenda = false
    isLoadingApprovals = false
    isLoadingAgentRuns = false
    isLoadingAgentWorkflows = false
    isLoadingMeetings = false
    isLoadingSources = false
    isScanningCorpusFiles = false
    isLoadingAssignedWork = false
    isLoadingAIChatThreadRecords = false
    statusText = message
    errorText = message
  }

  public func refreshSourceConnections() async {
    guard let corpusRoot, !isLoadingSources else {
      if corpusRoot == nil {
        sourceProfiles = []
        sourceRuntimeStatuses = [:]
        sourceScheduleStates = [:]
      }
      return
    }
    let sessionGeneration = corpusSessionGeneration
    let dirtyGeneration = workspaceSurfaceDirtyGenerations[.sources, default: 0]
    isLoadingSources = true
    defer {
      if isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) { isLoadingSources = false }
    }
    setSourceOperationMessage(nil, profileID: "workspace")
    do {
      let profiles: [WorkspaceSourceProfileStatus] = try await cli.runJSON(
        ["source", "list", "--dir", corpusRoot.path, "--json"]
      )
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      sourceProfiles = profiles
      if profiles.isEmpty {
        sourceRuntimeStatuses = [:]
        sourceScheduleStates = [:]
        markWorkspaceSurfaceCleanIfUnchanged(.sources, generation: dirtyGeneration)
        return
      }
      let envelope: WorkspaceSourceStatusEnvelope = try await cli.runJSON(
        ["source", "status", "--dir", corpusRoot.path, "--json"]
      )
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      sourceRuntimeStatuses = Dictionary(uniqueKeysWithValues: envelope.sources.map { ($0.id, $0) })
      refreshSourceScheduleStates()
      markWorkspaceSurfaceCleanIfUnchanged(.sources, generation: dirtyGeneration)
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled, isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else { return }
      setSourceOperationMessage(error.localizedDescription, profileID: "workspace", failed: true)
    }
  }

  public func checkSourceSetup(_ profile: WorkspaceSourceProfileStatus) async {
    guard let corpusRoot, !activeSourceOperationIDs.contains(profile.id) else { return }
    activeSourceOperationIDs.insert(profile.id)
    defer { activeSourceOperationIDs.remove(profile.id) }
    setSourceOperationMessage(nil, profileID: profile.id)
    do {
      _ = try await cli.run(
        ["source", "doctor", profile.id, "--dir", corpusRoot.path, "--json"],
        environment: sourceEnvironment(for: profile)
      )
      setSourceOperationMessage("Setup check passed.", profileID: profile.id)
    } catch is CancellationError {
      return
    } catch {
      setSourceOperationMessage(error.localizedDescription, profileID: profile.id, failed: true)
    }
  }

  public func previewSourceImport(_ profile: WorkspaceSourceProfileStatus) async {
    guard let corpusRoot, !activeSourceOperationIDs.contains(profile.id) else { return }
    activeSourceOperationIDs.insert(profile.id)
    defer { activeSourceOperationIDs.remove(profile.id) }
    setSourceOperationMessage(nil, profileID: profile.id)
    do {
      let envelope: WorkspaceSourceOperationEnvelope = try await cli.runJSON(
        ["source", "import", profile.id, "--dir", corpusRoot.path, "--json"],
        environment: sourceEnvironment(for: profile)
      )
      if let summary = envelope.results.first?.imported {
        setSourceOperationMessage(
          "Preview: \(summary.acceptedCount) records across \(summary.groupCount) review packets.",
          profileID: profile.id
        )
      } else {
        let result = envelope.results.first
        setSourceOperationMessage(
          result?.error ?? result?.message ?? "Preview finished.",
          profileID: profile.id,
          failed: result?.ok == false
        )
      }
    } catch is CancellationError {
      return
    } catch {
      setSourceOperationMessage(error.localizedDescription, profileID: profile.id, failed: true)
    }
  }

  public func syncAndStageSource(_ profile: WorkspaceSourceProfileStatus) async {
    if connectedServerRunsSourceSyncs {
      await syncSourceOnConnectedServer(profile)
      return
    }
    _ = await performSyncAndStageSource(profile, trigger: .manual)
  }

  /// Run Now when the paired server owns this corpus's schedules: the server
  /// syncs with its own copy of the credential and the staged files reach
  /// this Mac through the corpus sync.
  private func syncSourceOnConnectedServer(_ profile: WorkspaceSourceProfileStatus) async {
    guard !activeSourceOperationIDs.contains(profile.id) else { return }
    activeSourceOperationIDs.insert(profile.id)
    defer { activeSourceOperationIDs.remove(profile.id) }
    let serverName = openOrgServer.serverName
    setSourceOperationMessage("Syncing on \(serverName)…", profileID: profile.id)
    do {
      if profile.usesStoredCredential, sourceHasStoredCredential(profile),
         serverSourceCredentialProfileIDs?.contains(profile.id) != true {
        // First Run Now after pairing: make sure the server has the credential.
        await refreshServerSourceCredentials()
        if serverSourceCredentialProfileIDs?.contains(profile.id) != true {
          await shareSourceCredentialWithServer(profileID: profile.id, savedMessage: nil)
        }
      }
      let result = try await openOrgServer.syncSource(profileID: profile.id)
      let detail = result.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      setSourceOperationMessage(
        result.ok
          ? "\(serverName): \(detail.isEmpty ? "Sync finished." : detail)"
          : "\(serverName) could not sync: \(detail.isEmpty ? "unknown error" : detail)",
        profileID: profile.id,
        failed: !result.ok
      )
    } catch {
      setSourceOperationMessage("Could not reach \(serverName) to sync: \(error.localizedDescription)", profileID: profile.id, failed: true)
    }
  }

  @discardableResult
  public func updateSourceSchedule(
    _ profile: WorkspaceSourceProfileStatus,
    schedule: WorkspaceSourceSchedule
  ) async -> Bool {
    var arguments = [
      "source", "schedule", profile.id,
      "--kind", schedule.kind.rawValue,
    ]
    switch schedule.kind {
    case .interval:
      arguments += ["--every-minutes", String(schedule.everyMinutes ?? 0)]
    case .daily:
      arguments += ["--time", schedule.time ?? ""]
    }
    arguments += ["--timezone", schedule.timezone, "--apply"]
    return await applySourceScheduleCommand(arguments, profile: profile)
  }

  @discardableResult
  public func setSourceScheduleEnabled(
    _ profile: WorkspaceSourceProfileStatus,
    enabled: Bool
  ) async -> Bool {
    await applySourceScheduleCommand(
      ["source", "schedule", profile.id, enabled ? "--resume" : "--pause", "--apply"],
      profile: profile
    )
  }

  @discardableResult
  private func applySourceScheduleCommand(
    _ command: [String],
    profile: WorkspaceSourceProfileStatus
  ) async -> Bool {
    guard let corpusRoot, !activeSourceOperationIDs.contains(profile.id) else { return false }
    activeSourceOperationIDs.insert(profile.id)
    defer { activeSourceOperationIDs.remove(profile.id) }
    setSourceOperationMessage(nil, profileID: profile.id)
    do {
      let envelope: WorkspaceSourceScheduleUpdateEnvelope = try await cli.runJSON(
        command + ["--dir", corpusRoot.path, "--json"]
      )
      if let index = sourceProfiles.firstIndex(where: { $0.id == profile.id }) {
        sourceProfiles[index].schedule = envelope.schedule
      }
      refreshSourceScheduleStates()
      setSourceOperationMessage(
        envelope.schedule.enabled
          ? "Scheduled sync set to \(envelope.schedule.summary)."
          : "Scheduled sync paused. Run Now remains available.",
        profileID: profile.id
      )
      return true
    } catch is CancellationError {
      return false
    } catch {
      setSourceOperationMessage(error.localizedDescription, profileID: profile.id, failed: true)
      return false
    }
  }

  @discardableResult
  private func performSyncAndStageSource(
    _ profile: WorkspaceSourceProfileStatus,
    trigger: SourceSyncTrigger
  ) async -> Bool {
    guard let corpusRoot, !activeSourceOperationIDs.contains(profile.id) else { return false }
    activeSourceOperationIDs.insert(profile.id)
    defer { activeSourceOperationIDs.remove(profile.id) }
    beginSourceSyncEventBatch()
    setSourceOperationMessage(nil, profileID: profile.id)
    do {
      guard let context = captureDocumentCorpusContext() else { return false }
      let environment = sourceEnvironment(for: profile)
      let cli = self.cli
      let envelope: WorkspaceSourceOperationEnvelope = try await performDocumentMutation(
        context: context,
        files: profile.importResourcePaths(in: corpusRoot)
      ) { _ in
        try await cli.runJSON(
          ["source", "sync", profile.id, "--ingest", "--apply", "--dir", corpusRoot.path, "--json"],
          environment: environment
        )
      }
      guard isCurrentDocumentCorpusContext(context) else { return false }
      guard let result = envelope.results.first else {
        throw NSError(
          domain: "Org2Workspace.SourceSync",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Source sync returned no result."]
        )
      }
      if result.isSyncInProgress {
        setSourceOperationMessage(
          result.message ?? "Sync already in progress on this machine.",
          profileID: profile.id
        )
        recordSourceScheduleDeferred(profile, trigger: trigger)
        await finishSourceSyncEventBatch(requiresFallbackScan: false)
        return true
      }
      guard result.ok else {
        throw NSError(
          domain: "Org2Workspace.SourceSync",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: result.error ?? result.message ?? "Source sync failed."]
        )
      }
      let recoveredSuffix = result.recoveredStaleLock == true
        ? " Recovered an abandoned sync lock."
        : ""
      if let summary = result.imported {
        setSourceOperationMessage(
          "Staged \(summary.acceptedCount) records in \(summary.groupCount) review packets.\(recoveredSuffix)",
          profileID: profile.id
        )
      } else {
        setSourceOperationMessage("Sync finished.\(recoveredSuffix)", profileID: profile.id)
      }
      recordSourceScheduleResult(profile, trigger: trigger, succeeded: true, error: nil)
      await finishSourceSyncEventBatch(requiresFallbackScan: true)
      await refreshSourceConnection(profile.id)
      return true
    } catch is CancellationError {
      setSourceOperationMessage(nil, profileID: profile.id)
      await finishSourceSyncEventBatch(requiresFallbackScan: false)
      return false
    } catch {
      setSourceOperationMessage(error.localizedDescription, profileID: profile.id, failed: true)
      recordSourceScheduleResult(
        profile,
        trigger: trigger,
        succeeded: false,
        error: error.localizedDescription
      )
      await finishSourceSyncEventBatch(requiresFallbackScan: false)
      return false
    }
  }

  private func refreshSourceConnection(_ profileID: String) async {
    guard let corpusRoot else { return }
    do {
      let profiles: [WorkspaceSourceProfileStatus] = try await cli.runJSON(
        ["source", "list", profileID, "--dir", corpusRoot.path, "--json"]
      )
      guard let profile = profiles.first else { return }
      if let index = sourceProfiles.firstIndex(where: { $0.id == profileID }) {
        sourceProfiles[index] = profile
      } else {
        sourceProfiles.append(profile)
        sourceProfiles.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
      }
      let envelope: WorkspaceSourceStatusEnvelope = try await cli.runJSON(
        ["source", "status", profileID, "--dir", corpusRoot.path, "--json"]
      )
      if let runtime = envelope.sources.first {
        sourceRuntimeStatuses[profileID] = runtime
      }
      refreshSourceScheduleStates()
    } catch is CancellationError {
      return
    } catch {
      setSourceOperationMessage(error.localizedDescription, profileID: profileID, failed: true)
    }
  }

  private func beginSourceSyncEventBatch() {
    if activeSourceSyncEventBatchCount == 0 {
      sourceSyncEventBatchNeedsFallbackScan = false
    }
    activeSourceSyncEventBatchCount += 1
  }

  private func finishSourceSyncEventBatch(requiresFallbackScan: Bool) async {
    guard activeSourceSyncEventBatchCount > 0 else { return }
    sourceSyncEventBatchNeedsFallbackScan = sourceSyncEventBatchNeedsFallbackScan
      || requiresFallbackScan

    // FSEvents may deliver the connector's final atomic replacements just
    // after the child exits. Keep the operation boundary open briefly so the
    // tail joins the same deduplicated reconciliation instead of starting a
    // second index update.
    try? await Task.sleep(nanoseconds: 350_000_000)
    activeSourceSyncEventBatchCount -= 1
    guard activeSourceSyncEventBatchCount == 0 else { return }

    let requiresFallbackScan = sourceSyncEventBatchNeedsFallbackScan
    sourceSyncEventBatchNeedsFallbackScan = false
    if needsFullCorpusRefreshAfterEvents || !pendingCorpusChangedPaths.isEmpty {
      scheduleCorpusEventRefreshTask()
      await postAIChatWorkspaceRefreshTask?.value
    } else if requiresFallbackScan {
      // Watchers are disabled in some test and recovery environments, and an
      // FSEvents drop can omit item paths. Reconcile once at the operation
      // boundary rather than leaving successful connector output invisible.
      await performFullCorpusFileRefreshAfterEvents()
    }
  }

  private func setSourceOperationMessage(
    _ message: String?,
    profileID: String,
    failed: Bool = false
  ) {
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      sourceOperationMessages.removeValue(forKey: profileID)
      sourceOperationFailureIDs.remove(profileID)
      return
    }
    sourceOperationMessages[profileID] = trimmed
    if failed {
      sourceOperationFailureIDs.insert(profileID)
    } else {
      sourceOperationFailureIDs.remove(profileID)
    }
  }

  public func revealSourceReviews(_ profile: WorkspaceSourceProfileStatus) {
    guard let corpusRoot else { return }
    let folder = corpusRoot.appendingPathComponent(profile.reviewZone).standardizedFileURL
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    NSWorkspace.shared.open(folder)
  }

  public func presentSourceCredential(for profile: WorkspaceSourceProfileStatus) {
    sourceCredentialProfileID = profile.id
    sourceCredentialDraft = ""
    isSourceCredentialPresented = true
  }

  public func sourceHasStoredCredential(_ profile: WorkspaceSourceProfileStatus) -> Bool {
    sourceCredentialStore.containsCredential(profileID: profile.id)
  }

  public func savePresentedSourceCredential() {
    guard let profileID = sourceCredentialProfileID else { return }
    let token = sourceCredentialDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      setSourceOperationMessage("Enter a token before saving.", profileID: profileID, failed: true)
      return
    }
    do {
      try sourceCredentialStore.saveCredential(token, profileID: profileID)
      setSourceOperationMessage("Credential saved securely in Keychain.", profileID: profileID)
      sourceCredentialDraft = ""
      isSourceCredentialPresented = false
      Task { await shareSourceCredentialWithServer(profileID: profileID, savedMessage: "Credential saved securely in Keychain.") }
    } catch {
      setSourceOperationMessage(error.localizedDescription, profileID: profileID, failed: true)
    }
  }

  public func deleteSourceCredential(_ profile: WorkspaceSourceProfileStatus) {
    do {
      try sourceCredentialStore.deleteCredential(profileID: profile.id)
      setSourceOperationMessage("Stored credential removed.", profileID: profile.id)
    } catch {
      setSourceOperationMessage(error.localizedDescription, profileID: profile.id, failed: true)
      return
    }
    guard openOrgServer.isPaired, serverSourceCredentialProfileIDs?.contains(profile.id) != false else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await self.openOrgServer.deleteSourceCredential(profileID: profile.id)
        self.serverSourceCredentialProfileIDs?.remove(profile.id)
        self.setSourceOperationMessage("Stored credential removed here and on \(self.openOrgServer.serverName).", profileID: profile.id)
      } catch {
        self.setSourceOperationMessage(
          "Stored credential removed on this Mac, but \(self.openOrgServer.serverName) could not be updated: \(error.localizedDescription)",
          profileID: profile.id,
          failed: true
        )
      }
    }
  }

  private func sourceEnvironment(for profile: WorkspaceSourceProfileStatus) -> [String: String] {
    // Passed only to this sync's process; never written to the corpus.
    guard let secret = profile.sourceType?.secret,
          let token = sourceCredentialStore.credential(profileID: profile.id)
    else { return [:] }
    return [secret.environmentVariable: token]
  }

  // MARK: Source credentials on the connected server

  /// Whether this Mac should hand source credentials and Run Now to the
  /// paired server: it is paired and that server owns the corpus schedules.
  public var connectedServerRunsSourceSyncs: Bool {
    guard openOrgServer.isPaired,
          let serverRef = openOrgServer.pairing?.hostRef,
          serverRef != automationHostRef
    else { return false }
    return corpusAutomationHostRef == serverRef
  }

  public func serverHasSourceCredential(_ profile: WorkspaceSourceProfileStatus) -> Bool? {
    serverSourceCredentialProfileIDs.map { $0.contains(profile.id) }
  }

  public func refreshServerSourceCredentials() async {
    guard openOrgServer.isPaired else {
      serverSourceCredentialProfileIDs = nil
      return
    }
    if let ids = try? await openOrgServer.sourceCredentialProfileIDs() {
      serverSourceCredentialProfileIDs = Set(ids)
    }
  }

  /// Sends the stored credential for one source to the paired server.
  public func sendSourceCredentialToServer(_ profile: WorkspaceSourceProfileStatus) async {
    await shareSourceCredentialWithServer(profileID: profile.id, savedMessage: nil, force: true)
  }

  /// After a credential is saved on this Mac, the paired server gets a copy
  /// so it can sync on its own. Failures leave the Mac's copy in place and
  /// say how to retry.
  private func shareSourceCredentialWithServer(profileID: String, savedMessage: String?, force: Bool = false) async {
    guard openOrgServer.isPaired else { return }
    let serverName = openOrgServer.serverName
    let credentialStore = sourceCredentialStore
    let credential = await Task.detached(priority: .userInitiated) {
      credentialStore.credential(profileID: profileID)
    }.value
    guard let credential else {
      if force { setSourceOperationMessage("There is no credential on this Mac to send.", profileID: profileID, failed: true) }
      return
    }
    let prefix = savedMessage.map { "\($0) " } ?? ""
    do {
      try await openOrgServer.uploadSourceCredential(profileID: profileID, credential: credential)
      if serverSourceCredentialProfileIDs == nil { serverSourceCredentialProfileIDs = [] }
      serverSourceCredentialProfileIDs?.insert(profileID)
      setSourceOperationMessage("\(prefix)Sent to \(serverName), which can now sync this source.", profileID: profileID)
    } catch {
      setSourceOperationMessage(
        "\(prefix)Could not send it to \(serverName): \(error.localizedDescription) Use Send to Server to try again.",
        profileID: profileID,
        failed: true
      )
    }
  }

  /// Server side of `PUT /v1/sources/ID/credential`.
  public func storeSourceCredentialFromPairedClient(_ credential: String, profileID: String) throws {
    try sourceCredentialStore.saveCredential(credential, profileID: profileID)
    setSourceOperationMessage("Credential received from a paired Mac.", profileID: profileID)
  }

  /// Server side of `DELETE /v1/sources/ID/credential`.
  public func deleteSourceCredentialFromPairedClient(profileID: String) throws {
    try sourceCredentialStore.deleteCredential(profileID: profileID)
  }

  public func storedSourceCredentialProfileIDs() -> [String] {
    sourceCredentialStore.storedProfileIDs()
  }

  /// Server side of `POST /v1/sources/ID/sync`: runs the same sync as Run
  /// Now. Long syncs keep running after the response, which returns once the
  /// sync finishes or after a bounded wait.
  public func runSourceSyncForPairedClient(
    profileID: String,
    responseWait: Duration = .seconds(90)
  ) async -> MobileRemoteSourceSyncResponse {
    if !sourceProfiles.contains(where: { $0.id == profileID }) {
      await refreshSourceConnections()
    }
    guard let profile = sourceProfiles.first(where: { $0.id == profileID }) else {
      return MobileRemoteSourceSyncResponse(profileID: profileID, ok: false, message: "This server's corpus has no source named \(profileID) yet. Wait for celorga.json to sync, then try again.")
    }
    if activeSourceOperationIDs.contains(profileID) {
      return MobileRemoteSourceSyncResponse(profileID: profileID, ok: true, message: "A sync of this source is already running on the server.")
    }
    if let missing = missingCredentialMessage(for: profile) {
      return MobileRemoteSourceSyncResponse(profileID: profileID, ok: false, message: missing)
    }
    let sync = Task { @MainActor [weak self] () -> Bool in
      guard let self else { return false }
      return await self.performSyncAndStageSource(profile, trigger: .manual)
    }
    let finished = await withTaskGroup(of: Bool?.self) { group -> Bool? in
      group.addTask { await sync.value }
      group.addTask {
        try? await Task.sleep(for: responseWait)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    guard let succeeded = finished else {
      return MobileRemoteSourceSyncResponse(profileID: profileID, ok: true, message: "Still syncing on the server; results arrive with the corpus sync.")
    }
    return MobileRemoteSourceSyncResponse(
      profileID: profileID,
      ok: succeeded && !sourceOperationFailureIDs.contains(profileID),
      message: sourceOperationMessages[profileID]
    )
  }

  /// Why a source cannot sync on this host yet, when it needs a stored credential.
  private func missingCredentialMessage(for profile: WorkspaceSourceProfileStatus) -> String? {
    guard profile.usesStoredCredential,
          profile.credentialAvailable != true,
          !sourceHasStoredCredential(profile),
          let secret = profile.sourceType?.secret
    else { return nil }
    if aiChatHostIdentity.kind == .server {
      return secret.signIn != nil
        ? "Waiting for \(secret.label.lowercased()): sign in from Celorga on your Mac, which sends it to this server."
        : "Waiting for a \(secret.label.lowercased()): add it in Celorga's Sources view on your Mac, which sends it to this server."
    }
    return "Waiting for a \(secret.label.lowercased()) in Keychain."
  }

  // MARK: Google sign-in for sources

  private static let googleSourceOAuthClientAccount = "__google-oauth-client__"

  /// Signs in with Google for a Google-backed source, stores the refresh
  /// credential like any other source secret, and sends it to the paired
  /// server so the server can sync.
  public func signInToGoogle(for profile: WorkspaceSourceProfileStatus) async {
    guard case .google(let scope)? = profile.sourceType?.secret?.signIn else { return }
    guard !activeSourceOperationIDs.contains(profile.id) else { return }
    activeSourceOperationIDs.insert(profile.id)
    defer { activeSourceOperationIDs.remove(profile.id) }
    setSourceOperationMessage("Finish signing in to Google in your browser…", profileID: profile.id)
    do {
      guard let client = try googleSourceOAuthClient() else {
        setSourceOperationMessage(nil, profileID: profile.id)
        return
      }
      let credential = try await GoogleDriveOAuthClient().authorize(
        clientID: client.clientID,
        clientSecret: client.clientSecret,
        scope: scope,
        openAuthorizationURL: { url in
          await MainActor.run { NSWorkspace.shared.open(url) }
        }
      )
      let encoded = try GoogleSourceOAuthCredential(credential).encodedString()
      try sourceCredentialStore.saveCredential(encoded, profileID: profile.id)
      let saved = "Signed in to Google."
      setSourceOperationMessage(openOrgServer.isPaired ? saved : "\(saved) Run Now to sync on this Mac, or pair a Celorga server to sync there.", profileID: profile.id)
      await shareSourceCredentialWithServer(profileID: profile.id, savedMessage: saved)
    } catch {
      setSourceOperationMessage(error.localizedDescription, profileID: profile.id, failed: true)
    }
  }

  /// The Google OAuth Desktop client for source sign-in: the build's managed
  /// client, one imported earlier, or one the user imports now. Returns nil
  /// when the user cancels the import.
  private func googleSourceOAuthClient() throws -> GoogleDriveOAuthDesktopClient? {
    if let managed = GoogleDriveOAuthConfiguration.managedClientPair(), managed.clientSecret != nil {
      return managed
    }
    if let saved = SourceCredentialsKeychain.readToken(profileID: Self.googleSourceOAuthClientAccount),
       let client = try? GoogleDriveOAuthDesktopClient.decodeGoogleClientJSON(Data(saved.utf8)) {
      return client
    }
    let alert = NSAlert()
    alert.messageText = "Choose a Google OAuth client"
    alert.informativeText = "This build of Celorga has no built-in Google sign-in client. In Google Cloud Console, enable the Google Calendar API, create an OAuth client of type “Desktop app”, download its JSON file, and choose it next. Celorga keeps it in Keychain."
    alert.addButton(withTitle: "Choose Client JSON…")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.message = "Choose the Desktop app OAuth client JSON downloaded from Google Cloud Console."
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    let data = try Data(contentsOf: url)
    let client = try GoogleDriveOAuthDesktopClient.decodeGoogleClientJSON(data)
    try SourceCredentialsKeychain.saveToken(String(decoding: data, as: UTF8.self), profileID: Self.googleSourceOAuthClientAccount)
    return client
  }

  public func presentNewSource(type: WorkspaceSourceType) {
    var draft = WorkspaceSourceDraft(type: type)
    let existing = Set(sourceProfiles.map(\.id))
    if existing.contains(draft.profileID) {
      draft.profileID = (2...).lazy.map { "\(type.defaultProfileID)-\($0)" }.first { !existing.contains($0) } ?? draft.profileID
    }
    sourceDraft = draft
  }

  public func presentSourceEditor(for profile: WorkspaceSourceProfileStatus) {
    sourceDraft = WorkspaceSourceDraft(editing: profile)
  }

  /// Adds or updates any catalog source in `celorga.json` through `celorga source add`,
  /// and stores an entered secret in Keychain. Returns an error message.
  @discardableResult
  public func saveSourceDraft(_ draft: WorkspaceSourceDraft) async -> String? {
    guard let corpusRoot else { return "Open a corpus first." }
    do {
      let arguments = try draft.arguments(corpusRoot: corpusRoot.path)
      let profileID = draft.profileID.trimmingCharacters(in: .whitespacesAndNewlines)
      _ = try await cli.run(arguments)
      let secret = draft.secret.trimmingCharacters(in: .whitespacesAndNewlines)
      if !secret.isEmpty, draft.sourceType?.secret?.signIn == nil {
        try sourceCredentialStore.saveCredential(secret, profileID: profileID)
      }
      await refreshSourceConnections()
      let message = draft.isEditing
        ? "Source updated."
        : draft.sourceType?.secret?.signIn != nil
          ? "\(draft.sourceType?.displayName ?? "Source") source added. Sign in with Google to start syncing."
          : "\(draft.sourceType?.displayName ?? "Source") source added. Use Check Setup to verify the connection."
      setSourceOperationMessage(message, profileID: profileID)
      if !secret.isEmpty, draft.sourceType?.secret?.signIn == nil {
        await shareSourceCredentialWithServer(profileID: profileID, savedMessage: message)
      }
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  /// Optional agent-assisted setup, available for every catalog type.
  public func askAIChatToSetUpSource(type: WorkspaceSourceType) {
    sourceDraft = nil
    prepareAIChatThread(
      mode: .newThread,
      title: "Set up \(type.displayName) source",
      statusText: "New source setup chat"
    )
    publishAIChatComposerDraft(type.agentSetupPrompt)
    navigateToSurface(.aiChat)
  }

  public func setSourceAutoSyncActive(
    _ isActive: Bool,
    checkIntervalNanoseconds: UInt64 = WorkspaceStore.sourceAutoSyncCheckIntervalNanoseconds
  ) {
    isSourceAutoSyncActive = isActive
    if !isActive {
      sourceAutoSyncTask?.cancel()
      sourceAutoSyncTask = nil
      sourceAutoSyncActivationTask?.cancel()
      sourceAutoSyncActivationTask = nil
      return
    }

    guard sourceAutoSyncTask == nil else { return }
    Task { @MainActor [weak self] in
      await self?.checkDueSourceSchedules(refreshProfiles: false)
    }

    sourceAutoSyncTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: checkIntervalNanoseconds)
        } catch {
          return
        }
        guard let self, self.isSourceAutoSyncActive else { continue }
        await self.checkDueSourceSchedules(refreshProfiles: false)
      }
    }
  }

  public func sourceAutoSyncDidBecomeActive() {
    guard isSourceAutoSyncActive else { return }
    sourceAutoSyncActivationTask?.cancel()
    sourceAutoSyncActivationTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.applicationActivationRefreshDelayNanoseconds)
      guard !Task.isCancelled,
            let self,
            self.isSourceAutoSyncActive,
            self.isWorkspaceRealtimeRefreshActive
      else { return }
      await self.checkDueSourceSchedules(refreshProfiles: true)
      self.sourceAutoSyncActivationTask = nil
    }
  }

  public func setAutomationSchedulerActive(
    _ isActive: Bool,
    checkIntervalNanoseconds: UInt64 = WorkspaceStore.automationScheduleCheckIntervalNanoseconds
  ) {
    isAutomationSchedulerActive = isActive
    guard isActive else {
      automationSchedulerTask?.cancel()
      automationSchedulerTask = nil
      automationSchedulerActivationTask?.cancel()
      automationSchedulerActivationTask = nil
      automationSchedulerStatusText = "Automation scheduler is off"
      automationSchedulerErrorText = nil
      return
    }

    guard automationSchedulerTask == nil else { return }
    automationSchedulerStatusText = "Checking automations…"
    automationSchedulerErrorText = nil
    Task { @MainActor [weak self] in
      await self?.checkDueAgentAutomations()
    }
    automationSchedulerTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: checkIntervalNanoseconds)
        } catch {
          return
        }
        guard let self, self.isAutomationSchedulerActive else { continue }
        await self.checkDueAgentAutomations()
      }
    }
  }

  public func automationSchedulerDidBecomeActive() {
    guard isAutomationSchedulerActive else { return }
    automationSchedulerActivationTask?.cancel()
    automationSchedulerActivationTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.applicationActivationRefreshDelayNanoseconds)
      guard !Task.isCancelled,
            let self,
            self.isAutomationSchedulerActive,
            self.isWorkspaceRealtimeRefreshActive
      else { return }
      await self.checkDueAgentAutomations()
      self.automationSchedulerActivationTask = nil
    }
  }

  func checkDueAgentAutomations(now: Date = Date()) async {
    guard isAutomationSchedulerActive, let corpusRoot else {
      automationSchedulerStatusText = corpusRoot == nil
        ? "Choose a corpus to run automations"
        : "Automation scheduler is off"
      automationSchedulerErrorText = nil
      return
    }
    // Routine minute/activation checks keep the last settled status so an
    // idle Automations surface does not flicker between states.
    if !hasSettledAutomationSchedulerStatus {
      automationSchedulerStatusText = "Checking automations…"
    }
    automationSchedulerErrorText = nil
    defer { hasSettledAutomationSchedulerStatus = true }
    await runWorkflowEventDetectors(corpusRoot: corpusRoot, now: now)
    do {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      let payload: AgentWorkflowDueListPayload = try await cli.runJSON([
        "workflow", "due",
        "--host-ref", automationHostRef,
        "--now", formatter.string(from: now),
        "--dir", corpusRoot.path,
        "--json"
      ])
      // A successful check recovers its own warning, while preserving errors
      // from another workspace action that arrived in the meantime.
      if errorText == automationSchedulerPresentedErrorText {
        errorText = nil
      }
      automationSchedulerPresentedErrorText = nil
      lastDueEventSources = payload.eventSources
      if let hostRef = payload.hostRef?.trimmingCharacters(in: .whitespacesAndNewlines),
         !hostRef.isEmpty {
        automationOwnerHostRef = hostRef
      }
      let failures = payload.failures ?? []
      if payload.due.isEmpty {
        automationSchedulerErrorText = failures.isEmpty ? nil : failures
          .map { "\($0.title): \($0.failure)" }.joined(separator: "\n")
        automationSchedulerStatusText = payload.reason ?? (!failures.isEmpty
          ? "\(failures.count) automation\(failures.count == 1 ? "" : "s") last failed"
          : payload.skipped.isEmpty
          ? "Automations are up to date"
          : "\(payload.skipped.count) automation\(payload.skipped.count == 1 ? "" : "s") waiting for an active run")
        return
      }
      automationSchedulerStatusText = "Dispatching \(payload.due.count) automation\(payload.due.count == 1 ? "" : "s")…"
      var dispatchedCount = 0
      var failureMessages = Dictionary(uniqueKeysWithValues: failures.map {
        ($0.workflowId, "\($0.title): \($0.failure)")
      })
      for item in payload.due {
        if await dispatchScheduledAgentAutomation(item) {
          dispatchedCount += 1
          failureMessages.removeValue(forKey: item.workflowId)
        } else if let failure = automationSchedulerErrorText {
          failureMessages[item.workflowId] = "\(item.title): \(failure)"
        }
        automationSchedulerErrorText = nil
      }
      automationSchedulerErrorText = failureMessages.isEmpty ? nil : failureMessages
        .sorted { $0.key < $1.key }.map { $0.value }.joined(separator: "\n")
      automationSchedulerStatusText = dispatchedCount == payload.due.count
        ? "Dispatched \(dispatchedCount) automation\(dispatchedCount == 1 ? "" : "s")"
        : "Dispatched \(dispatchedCount) of \(payload.due.count) automations"
    } catch {
      automationSchedulerStatusText = "Automation check failed"
      automationSchedulerErrorText = error.localizedDescription
      let notice = "Automation scheduler: \(error.localizedDescription)"
      automationSchedulerPresentedErrorText = notice
      errorText = notice
    }
  }

  /// Runs the deterministic event detectors that feed `workflow due`:
  /// `workflow observe` for todo-state triggers and, on its own interval,
  /// `workflow poll --source github` for pull-request triggers. Both only
  /// record signals; Celorga never asks a model whether work should run.
  private func runWorkflowEventDetectors(
    corpusRoot: URL,
    now: Date,
    changedPaths: [String]? = nil
  ) async {
    let sources = AgentWorkflowEventSources.required(by: agentWorkflows).union(lastDueEventSources)
    if !sources.todoState { workflowTodoStateStatusText = nil }
    if !sources.pullRequest {
      workflowPullRequestStatusText = nil
      lastPullRequestPollAt = nil
      lastPullRequestPollNeedsAttention = false
    }
    guard sources.todoState || sources.pullRequest, !isRunningWorkflowEventDetectors else { return }
    isRunningWorkflowEventDetectors = true
    defer { isRunningWorkflowEventDetectors = false }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let nowText = formatter.string(from: now)
    if sources.todoState {
      var arguments = [
        "workflow", "observe", "--apply",
        "--host-ref", automationHostRef,
        "--now", nowText,
        "--dir", corpusRoot.path,
        "--json"
      ]
      for path in changedPaths ?? [] {
        arguments += ["--changed", path]
      }
      do {
        let _: AgentWorkflowEventSourcePayload = try await cli.runJSON(arguments)
        workflowTodoStateStatusText = nil
      } catch {
        workflowTodoStateStatusText = "TODO-state triggers: \(error.localizedDescription)"
      }
    }
    guard changedPaths == nil,
          sources.pullRequest,
          Self.shouldPollPullRequests(
            lastPollAt: lastPullRequestPollAt,
            needsAttention: lastPullRequestPollNeedsAttention,
            now: now
          )
    else { return }
    lastPullRequestPollAt = now
    do {
      let payload: AgentWorkflowEventSourcePayload = try await cli.runJSON([
        "workflow", "poll", "--source", "github", "--apply",
        "--host-ref", automationHostRef,
        "--now", nowText,
        "--dir", corpusRoot.path,
        "--json"
      ])
      lastPullRequestPollNeedsAttention = payload.needsAttention
      workflowPullRequestStatusText = payload.pullRequestStatusText
    } catch {
      lastPullRequestPollNeedsAttention = false
      workflowPullRequestStatusText = "Pull-request triggers: \(error.localizedDescription)"
    }
  }

  nonisolated static func shouldPollPullRequests(
    lastPollAt: Date?,
    needsAttention: Bool,
    now: Date
  ) -> Bool {
    guard let lastPollAt else { return true }
    let interval = needsAttention
      ? pullRequestPollAttentionIntervalSeconds
      : pullRequestPollIntervalSeconds
    return now.timeIntervalSince(lastPollAt) >= interval
  }

  /// Observes TODO-state changes as soon as Org files change, so a quick
  /// NEXT→DONE edit between scheduler checks still records its transition.
  func scheduleTodoStateObservation(for paths: [String], corpusRoot: URL) {
    guard isAutomationSchedulerActive,
          AgentWorkflowEventSources.required(by: agentWorkflows).union(lastDueEventSources).todoState
    else { return }
    let workflowPrefix = corpusRoot.appendingPathComponent("workflows").path + "/"
    let orgPaths = paths.filter {
      ($0.hasSuffix(".org") || $0.hasSuffix(".org2")) && !$0.hasPrefix(workflowPrefix)
    }
    guard !orgPaths.isEmpty else { return }
    Task { @MainActor [weak self] in
      await self?.runWorkflowEventDetectors(corpusRoot: corpusRoot, now: Date(), changedPaths: orgPaths)
    }
  }

  /// Scheduled source syncs run only on the corpus scheduler owner
  /// (`automationHostRef`), like scheduled automations, so a desktop and a
  /// headless server sharing a corpus do not both sync the same source.
  /// Run Now still syncs on whichever host it is clicked.
  nonisolated static func ownsCorpusSchedules(ownerHostRef: String?, hostRef: String) -> Bool {
    (ownerHostRef ?? "desktop") == hostRef
  }

  var ownsScheduledSourceSync: Bool {
    Self.ownsCorpusSchedules(ownerHostRef: corpusAutomationHostRef, hostRef: automationHostRef)
  }

  private func checkDueSourceSchedules(refreshProfiles: Bool, now: Date = Date()) async {
    guard corpusRoot != nil else { return }
    refreshCorpusAutomationHostRef()
    guard ownsScheduledSourceSync else { return }
    if refreshProfiles || sourceProfiles.isEmpty {
      await refreshSourceConnections()
    }
    refreshSourceScheduleStates(now: now)
    let dueProfiles = sourceProfiles.filter { profile in
      guard let schedule = profile.schedule, schedule.enabled,
            let state = sourceScheduleStates[profile.id]
      else { return false }
      return WorkspaceSourceSchedulePlanner.isDue(state, at: now)
    }

    for profile in dueProfiles {
      if !profile.ready {
        let message = "Automatic sync is waiting for source setup to be completed."
        setSourceOperationMessage(message, profileID: profile.id, failed: true)
        recordSourceScheduleResult(
          profile,
          trigger: .scheduled,
          succeeded: false,
          error: message,
          at: now
        )
        continue
      }
      if let missing = missingCredentialMessage(for: profile) {
        let message = "Automatic sync: \(missing)"
        setSourceOperationMessage(message, profileID: profile.id, failed: true)
        recordSourceScheduleResult(
          profile,
          trigger: .scheduled,
          succeeded: false,
          error: message,
          at: now
        )
        continue
      }
      _ = await performSyncAndStageSource(profile, trigger: .scheduled)
    }
  }

  private func refreshSourceScheduleStates(now: Date = Date()) {
    guard let corpusRoot else {
      sourceScheduleStates = [:]
      return
    }
    var refreshed: [String: WorkspaceSourceScheduleState] = [:]
    for profile in sourceProfiles {
      guard let schedule = profile.schedule else { continue }
      var state = sourceScheduleStateStore.state(
        corpusPath: corpusRoot.path,
        profileID: profile.id
      )
      if state == nil || state?.scheduleFingerprint != schedule.fingerprint {
        state = WorkspaceSourceScheduleState(
          scheduleFingerprint: schedule.fingerprint,
          initializedAt: now,
          lastSuccessAt: crawlerLastSyncDate(profileID: profile.id),
          nextRunAt: WorkspaceSourceSchedulePlanner.nextRun(after: now, schedule: schedule)
        )
      } else if schedule.enabled && state?.nextRunAt == nil {
        state?.nextRunAt = WorkspaceSourceSchedulePlanner.nextRun(after: now, schedule: schedule)
      } else if !schedule.enabled {
        state?.nextRunAt = nil
      }
      guard let state else { continue }
      sourceScheduleStateStore.setState(
        state,
        corpusPath: corpusRoot.path,
        profileID: profile.id
      )
      refreshed[profile.id] = state
    }
    sourceScheduleStates = refreshed
  }

  private func recordSourceScheduleResult(
    _ profile: WorkspaceSourceProfileStatus,
    trigger: SourceSyncTrigger,
    succeeded: Bool,
    error: String?,
    at date: Date = Date()
  ) {
    guard let corpusRoot, let schedule = profile.schedule, schedule.enabled else { return }
    var state = sourceScheduleStateStore.state(
      corpusPath: corpusRoot.path,
      profileID: profile.id
    ) ?? WorkspaceSourceScheduleState(
      scheduleFingerprint: schedule.fingerprint,
      initializedAt: date
    )
    state.scheduleFingerprint = schedule.fingerprint
    state.lastAttemptAt = date
    if succeeded {
      state.lastSuccessAt = date
      state.lastError = nil
      state.nextRunAt = WorkspaceSourceSchedulePlanner.nextRun(after: date, schedule: schedule)
    } else {
      state.lastError = error
      if case .scheduled = trigger {
        state.nextRunAt = date.addingTimeInterval(15 * 60)
      } else if state.nextRunAt == nil {
        state.nextRunAt = WorkspaceSourceSchedulePlanner.nextRun(after: date, schedule: schedule)
      }
    }
    sourceScheduleStateStore.setState(
      state,
      corpusPath: corpusRoot.path,
      profileID: profile.id
    )
    sourceScheduleStates[profile.id] = state
  }

  private func recordSourceScheduleDeferred(
    _ profile: WorkspaceSourceProfileStatus,
    trigger: SourceSyncTrigger,
    at date: Date = Date()
  ) {
    guard let corpusRoot, let schedule = profile.schedule, schedule.enabled else { return }
    var state = sourceScheduleStateStore.state(
      corpusPath: corpusRoot.path,
      profileID: profile.id
    ) ?? WorkspaceSourceScheduleState(
      scheduleFingerprint: schedule.fingerprint,
      initializedAt: date
    )
    state.scheduleFingerprint = schedule.fingerprint
    state.lastAttemptAt = date
    state.lastError = nil
    if case .scheduled = trigger {
      state.nextRunAt = date.addingTimeInterval(15 * 60)
    } else if state.nextRunAt == nil {
      state.nextRunAt = WorkspaceSourceSchedulePlanner.nextRun(after: date, schedule: schedule)
    }
    sourceScheduleStateStore.setState(
      state,
      corpusPath: corpusRoot.path,
      profileID: profile.id
    )
    sourceScheduleStates[profile.id] = state
  }

  private func crawlerLastSyncDate(profileID: String) -> Date? {
    guard let value = sourceRuntimeStatuses[profileID]?.crawlerStatus?.lastSyncAt else { return nil }
    return ISO8601DateFormatter().date(from: value)
  }

  private enum SourceSyncTrigger {
    case manual
    case scheduled
  }

  func refreshSelectedDetailFromDisk() async {
    guard let selectedLocation else { return }
    guard editingBlockID == nil, !isEditingEntry else { return }
    guard !isLiveFileEditorSelected || !liveFileEditorHasUnsavedChanges else { return }

    invalidateCanonicalDocumentCache(for: selectedLocation.file)
    await loadEntrySource(for: selectedLocation)
  }

  public func refreshAudioSettingsStatusAsync(preserveStatusText: Bool = false) async {
    let configuration = localWhisperConfiguration(includeCustomCommand: false)
    let status = await Task.detached(priority: .utility) {
      LocalWhisperTranscriber.installationStatus(configuration: configuration)
    }.value
    audioSettingsStatus = status
    workspaceRuntimeIdentity = WorkspaceRuntimeIdentity.current()
    if !preserveStatusText && (audioSettingsStatusText.isEmpty || !isInstallingFastTranscriber) {
      audioSettingsStatusText = status.detailText
    }
  }

  public var meetingTranscriptionProviderDetailText: String {
    switch meetingTranscriptionProvider {
    case .automatic:
      if audioSettingsStatus.isWhisperCppReady {
        return "Automatic will use \(audioSettingsStatus.backendDescription)."
      }
      return "Automatic will use macOS Speech. \(audioSettingsStatus.detailText)"
    case .fluidVoice:
      return "Fluid Voice uses its selected model. Its Local API must be enabled and running."
    default:
      return meetingTranscriptionProvider.detailText
    }
  }

  public func testMeetingTranscriptionProvider() async {
    guard !isTestingTranscriptionProvider else { return }
    isTestingTranscriptionProvider = true
    audioSettingsStatusText = "Testing \(meetingTranscriptionProvider.label)..."
    defer { isTestingTranscriptionProvider = false }

    do {
      switch meetingTranscriptionProvider {
      case .automatic:
        await refreshAudioSettingsStatusAsync(preserveStatusText: true)
        audioSettingsStatusText = audioSettingsStatus.isWhisperCppReady
          ? "Automatic is ready: \(audioSettingsStatus.backendDescription)"
          : "Automatic is ready with macOS Speech. \(audioSettingsStatus.detailText)"
      case .localWhisper:
        let status = LocalWhisperTranscriber.installationStatus(
          configuration: localWhisperConfiguration(includeCustomCommand: false)
        )
        guard status.isWhisperCppReady || status.openAIWhisperExecutablePath != nil else {
          throw AudioSettingsError.providerUnavailable(status.detailText)
        }
        audioSettingsStatusText = "Local Whisper is ready: \(status.backendDescription)"
      case .fluidVoice:
        let transcriber = try FluidVoiceTranscriber(endpoint: fluidVoiceEndpointText)
        audioSettingsStatusText = try await transcriber.healthDescription()
      case .macOSSpeech:
        audioSettingsStatusText = "macOS Speech is available; permission is requested when first used."
      case .customCommand:
        guard !customTranscriptionCommandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw AudioSettingsError.providerUnavailable("Enter a custom transcription command first.")
        }
        audioSettingsStatusText = "Custom command is configured. It will be tested with the next recording."
      }
    } catch {
      audioSettingsStatusText = error.localizedDescription
    }
  }

  public func connectFluidVoice() async {
    guard !isConnectingFluidVoice else { return }
    isConnectingFluidVoice = true
    audioSettingsStatusText = "Connecting Fluid Voice…"
    defer { isConnectingFluidVoice = false }

    do {
      if let operation = fluidVoiceConnectionOperationForTesting {
        audioSettingsStatusText = try await operation()
        return
      }

      let transcriber = try FluidVoiceTranscriber(endpoint: fluidVoiceEndpointText)
      if let ready = try? await transcriber.healthDescription() {
        audioSettingsStatusText = ready
        return
      }

      guard let applicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: Self.fluidVoiceBundleIdentifier
      ) else {
        throw AudioSettingsError.providerUnavailable(
          "Install Fluid Voice, then return here. Celorga will configure and connect its Local API automatically."
        )
      }

      let port = transcriber.endpoint.port ?? 47_733
      try await stopFluidVoiceBeforeConfiguration()

      let result = await Task.detached(priority: .userInitiated) {
        Self.runAudioSettingsProcess(
          executable: "/usr/bin/defaults",
          arguments: ["write", Self.fluidVoiceBundleIdentifier, "LocalAPIEnabled", "-bool", "true"]
        )
      }.value
      guard result.exitCode == 0 else {
        throw AudioSettingsError.providerUnavailable(result.stderr)
      }
      let portResult = await Task.detached(priority: .userInitiated) {
        Self.runAudioSettingsProcess(
          executable: "/usr/bin/defaults",
          arguments: ["write", Self.fluidVoiceBundleIdentifier, "LocalAPIPort", "-int", "\(port)"]
        )
      }.value
      guard portResult.exitCode == 0 else {
        throw AudioSettingsError.providerUnavailable(portResult.stderr)
      }

      audioSettingsStatusText = "Starting Fluid Voice Local API…"
      try await openFluidVoiceApplication(at: applicationURL)
      audioSettingsStatusText = try await waitForFluidVoiceHealth(transcriber)
    } catch {
      audioSettingsStatusText = error.localizedDescription
    }
  }

  nonisolated private static let fluidVoiceBundleIdentifier = "com.FluidApp.app"

  private func stopFluidVoiceBeforeConfiguration() async throws {
    let applications = NSRunningApplication.runningApplications(
      withBundleIdentifier: Self.fluidVoiceBundleIdentifier
    )
    guard !applications.isEmpty else { return }

    for application in applications where !application.isTerminated {
      _ = application.terminate()
    }
    let deadline = Date().addingTimeInterval(5)
    while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard applications.allSatisfy(\.isTerminated) else {
      throw AudioSettingsError.providerUnavailable(
        "Fluid Voice must restart once to enable its Local API. Quit Fluid Voice, then click Connect Fluid Voice again."
      )
    }
  }

  private func openFluidVoiceApplication(at applicationURL: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func waitForFluidVoiceHealth(_ transcriber: FluidVoiceTranscriber) async throws -> String {
    var lastError: Error?
    for _ in 0..<40 {
      do {
        return try await transcriber.healthDescription()
      } catch {
        lastError = error
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    let diagnostic = lastError?.localizedDescription ?? "The Local API did not start."
    throw AudioSettingsError.providerUnavailable(
      "Fluid Voice was configured and reopened, but Celorga could not connect. \(diagnostic)"
    )
  }

  func persistMeetingTranscriptionValue(_ value: String, key: String) {
    guard !Self.shouldIgnoreStandardDefaultsForTests(defaults) else { return }
    defaults.set(value, forKey: key)
  }

  func meetingTranscriptionConfiguration() -> MeetingTranscriptionConfiguration {
    MeetingTranscriptionConfiguration(
      provider: meetingTranscriptionProvider,
      fluidVoiceEndpoint: fluidVoiceEndpointText,
      customCommand: customTranscriptionCommandText,
      whisperModelPath: whisperModelPathText,
      language: transcriptionLanguageText
    )
  }
}
