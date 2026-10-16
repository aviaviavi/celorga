import SwiftUI
import UIKit

struct ContentView: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var remote: MobileRemoteStore

  var body: some View {
    WorkspaceTabs()
    .sheet(isPresented: $store.isDocumentPickerPresented) {
      CorpusFolderPicker { url in
        Task { await store.selectCorpus(url) }
      }
    }
    .alert("Celorga", isPresented: Binding(
      get: { store.errorMessage != nil || remote.errorMessage != nil },
      set: { _ in
        store.errorMessage = nil
        remote.errorMessage = nil
      }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(remote.errorMessage ?? store.errorMessage ?? "")
    }
  }
}

struct MobileSidebarToolbarButton: View {
  var body: some View {
    Button {
      NotificationCenter.default.post(name: .org2OpenMobileSidebar, object: nil)
    } label: {
      Image(systemName: "line.3.horizontal")
    }
    .accessibilityLabel("Open AI chat sidebar")
  }
}

private struct EmptyCorpusView: View {
  @EnvironmentObject private var store: CorpusStore

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        Image(systemName: "tray.full")
          .font(.system(size: 56))
          .foregroundStyle(.secondary)

        VStack(spacing: 8) {
          Text("Celorga")
            .font(.largeTitle.weight(.semibold))
          Text("Select a synced corpus folder from Files.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        Button {
          store.isDocumentPickerPresented = true
        } label: {
          Label("Select Corpus", systemImage: "folder")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
      .padding(24)
      .navigationTitle("Celorga")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          MobileSidebarToolbarButton()
        }
      }
    }
  }
}

private struct WorkspaceTabs: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @EnvironmentObject private var store: CorpusStore
  @Environment(\.scenePhase) private var scenePhase

  @State private var selection: WorkspaceTab = .initialSelection
  @State private var route: MobileWorkspaceRoute = .workspace
  @State private var isSidebarPresented = CelorgaNames.environment("ORG2_DEBUG_SHOW_SIDEBAR") == "1"

  var body: some View {
    ZStack(alignment: .leading) {
      destinationView
        .allowsHitTesting(!isSidebarPresented)

      if isSidebarPresented {
        Color.black.opacity(0.22)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { closeSidebar() }
          .transition(.opacity)

        MobileAISidebarView(
          selectedThreadID: selectedThreadID,
          openWorkspace: {
            selection = .newNote
            route = .workspace
            closeSidebar()
          },
          openFiles: {
            route = .workspace
            selection = .files
            closeSidebar()
          },
          openThread: { threadID in
            route = .thread(threadID)
            closeSidebar()
          },
          openExternalThreads: {
            route = .externalThreads
            closeSidebar()
          },
          openSettings: {
            route = .settings
            closeSidebar()
          },
          close: closeSidebar
        )
        .frame(width: min(UIScreen.main.bounds.width * 0.88, 360))
        .transition(.move(edge: .leading).combined(with: .opacity))
        .zIndex(1)
      }
    }
    .animation(.snappy(duration: 0.24), value: isSidebarPresented)
    .simultaneousGesture(
      DragGesture(
        minimumDistance: MobileSidebarEdgeSwipe.minimumDistance,
        coordinateSpace: .global
      )
      .onEnded { value in
        guard !isSidebarPresented,
              MobileSidebarEdgeSwipe.shouldOpen(
                startLocation: value.startLocation,
                translation: value.translation
              )
        else { return }
        isSidebarPresented = true
      }
    )
    .onAppear { openPendingNotification() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { openPendingNotification() }
    }
    .onChange(of: remote.isPaired) { _, paired in
      if paired { openPendingNotification() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .org2NotificationDestinationPending)) { _ in
      openPendingNotification()
    }
    .onReceive(NotificationCenter.default.publisher(for: .org2OpenMobileSidebar)) { _ in
      isSidebarPresented = true
    }
    .onReceive(NotificationCenter.default.publisher(for: .org2OpenRemoteThread)) { notification in
      guard let rawThreadID = notification.userInfo?["threadID"] as? String,
            let threadID = UUID(uuidString: rawThreadID)
      else { return }
      route = .thread(threadID)
      closeSidebar()
    }
  }

  @ViewBuilder
  private var destinationView: some View {
    switch route {
    case .workspace:
      workspaceTabView
    case .thread(let threadID):
      NavigationStack {
        MobileRemoteThreadView(threadID: threadID) { destinationThreadID in
          route = .thread(destinationThreadID)
        }
        // The sidebar swaps the associated thread ID in place. Give each
        // destination its own identity so SwiftUI tears down the old polling
        // lease before presenting the newly selected conversation.
        .id(threadID)
      }
    case .externalThreads:
      NavigationStack {
        MobileExternalThreadListView { threadID in
          route = .thread(threadID)
        }
      }
    case .settings:
      NavigationStack {
        MobileSettingsView()
      }
    }
  }

  private var workspaceTabView: some View {
    TabView(selection: $selection) {
      NewNoteTabView()
        .tabItem { Label("New Note", systemImage: "square.and.pencil") }
        .tag(WorkspaceTab.newNote)

      AgendaView()
        .tabItem { Label("Agenda", systemImage: "calendar") }
        .tag(WorkspaceTab.agenda)

      ApprovalsView()
        .tabItem { Label("Approvals", systemImage: "checkmark.seal") }
        .tag(WorkspaceTab.approvals)

      FilesTabView()
        .tabItem { Label("Files", systemImage: "folder") }
        .tag(WorkspaceTab.files)
    }
  }

  private var selectedThreadID: UUID? {
    guard case .thread(let threadID) = route else { return nil }
    return threadID
  }

  private func openPendingNotification() {
    let inbox = MobileNotificationInbox(defaults: .standard)
    guard let pending = inbox.pending() else { return }
    closeSidebar()
    store.isDocumentPickerPresented = false
    switch pending.destination {
    case .thread(let threadID):
      // Keep the tap while pairing is unavailable. Thread loading itself owns
      // connection retries, so navigation never waits for the host/list refresh.
      guard remote.isPaired else { route = .settings; return }
      route = .thread(threadID)
    case .agenda:
      route = .workspace
      selection = .agenda
    }
    inbox.acknowledge(pending)
  }

  private func closeSidebar() {
    isSidebarPresented = false
  }
}

private enum MobileSidebarEdgeSwipe {
  static let minimumDistance: CGFloat = 12

  private static let activationWidth: CGFloat = 24
  private static let minimumHorizontalTravel: CGFloat = 44
  private static let horizontalDominance: CGFloat = 1.25

  static func shouldOpen(startLocation: CGPoint, translation: CGSize) -> Bool {
    guard (0...activationWidth).contains(startLocation.x),
          translation.width >= minimumHorizontalTravel
    else { return false }

    return translation.width >= abs(translation.height) * horizontalDominance
  }
}

private enum MobileWorkspaceRoute: Equatable {
  case workspace
  case thread(UUID)
  case externalThreads
  case settings
}

private struct NewNoteTabView: View {
  @EnvironmentObject private var store: CorpusStore

  var body: some View {
    if store.rootURL == nil {
      EmptyCorpusView()
    } else {
      NewNoteView()
    }
  }
}

private struct FilesTabView: View {
  @EnvironmentObject private var store: CorpusStore

  var body: some View {
    if store.rootURL == nil {
      EmptyCorpusView()
    } else {
      NavigationStack {
        CorpusFileBrowserView()
      }
    }
  }
}

private enum WorkspaceTab: Hashable {
  case newNote
  case agenda
  case approvals
  case files

  static var initialSelection: WorkspaceTab {
    #if DEBUG
    switch CelorgaNames.environment("ORG2_DEBUG_INITIAL_TAB")?.lowercased() {
    case "agenda":
      return .agenda
    case "approvals":
      return .approvals
    case "files":
      return .files
    default:
      return .newNote
    }
    #else
    return .newNote
    #endif
  }
}

private struct AgendaView: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var remote: MobileRemoteStore

  private var entries: [AgendaEntry] {
    remote.isPaired ? remote.workspaceAgenda : store.agenda
  }

  private var overdue: [AgendaEntry] {
    entries.filter(\.isOverdue)
  }

  private var today: [AgendaEntry] {
    entries.filter { $0.date == Date.org2TodayString }
  }

  private var upcoming: [AgendaEntry] {
    entries.filter { !$0.isOverdue && $0.date != Date.org2TodayString }
  }

  var body: some View {
    NavigationStack {
      List {
        AgendaSection(title: "Today", entries: today)
        AgendaSection(title: "Overdue", entries: overdue)
        AgendaSection(title: "Upcoming", entries: upcoming)
      }
      .overlay {
        if entries.isEmpty && isLoading {
          LoadingCorpusView()
        } else if entries.isEmpty, let connectionError = remoteWorkspaceError {
          ContentUnavailableView(
            "Agenda Unavailable",
            systemImage: "desktopcomputer.trianglebadge.exclamationmark",
            description: Text(connectionError)
          )
        } else if entries.isEmpty {
          ContentUnavailableView("No Agenda Items", systemImage: "calendar")
        }
      }
      .navigationTitle("Agenda")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          MobileSidebarToolbarButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await refresh() }
          } label: {
            if isLoading {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .disabled(isLoading)
        }
      }
      .refreshable {
        await refresh()
      }
      .task {
        if remote.isPaired {
          await remote.refreshWorkspace(reportsErrors: false)
        } else {
          store.prepareCorpusViews()
        }
      }
    }
  }

  private var isLoading: Bool {
    remote.isPaired
      ? remote.isRefreshingWorkspace
      : (store.isPreparingCorpus || store.isLoading)
  }

  private var remoteWorkspaceError: String? {
    guard remote.isPaired, remote.workspaceUpdatedAt == nil else { return nil }
    return remote.workspaceConnectionError
      ?? "Connect to the paired Mac to load the canonical agenda."
  }

  private func refresh() async {
    if remote.isPaired {
      await remote.refreshWorkspace()
    } else {
      await store.refresh()
    }
  }
}

private struct AgendaSection: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var remote: MobileRemoteStore
  let title: String
  let entries: [AgendaEntry]

  var body: some View {
    if !entries.isEmpty {
      Section(title) {
        ForEach(entries) { entry in
          AgendaRow(entry: entry)
            .swipeActions(edge: .leading) {
              Button {
                Task { await setStatus(.done, for: entry) }
              } label: {
                Label("Done", systemImage: "checkmark")
              }
              .tint(.green)
            }
            .swipeActions(edge: .trailing) {
              Button {
                Task { await setStatus(.inProgress, for: entry) }
              } label: {
                Label("In Progress", systemImage: "play")
              }
              .tint(.yellow)

              Button {
                Task { await setStatus(.todo, for: entry) }
              } label: {
                Label("TODO", systemImage: "circle")
              }
              .tint(.blue)
            }
        }
      }
    }
  }

  private func setStatus(_ status: OrgTodoStatus, for entry: AgendaEntry) async {
    if remote.isPaired {
      await remote.setAgendaStatus(status, for: entry)
    } else {
      await store.setTodoStatus(status, for: entry)
    }
  }
}

private struct AgendaRow: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var remote: MobileRemoteStore
  let entry: AgendaEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Menu {
          ForEach(statusChoices, id: \.rawValue) { status in
            Button {
              Task {
                if remote.isPaired {
                  await remote.setAgendaStatus(status, for: entry)
                } else {
                  await store.setTodoStatus(status, for: entry)
                }
              }
            } label: {
              Label(status.rawValue, systemImage: status.rawValue == entry.todo ? "checkmark" : "circle")
            }
          }
        } label: {
          StatusPill(entry.todo)
        }
        .buttonStyle(.plain)

        Text(entry.title.prettyPrintedOrgLinks())
          .font(.body.weight(.medium))
          .lineLimit(2)
      }
      HStack(spacing: 8) {
        Label(entry.date, systemImage: entry.kind == .deadline ? "flag" : "calendar")
        Text(entry.file)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private var statusChoices: [OrgTodoStatus] {
    remote.isPaired ? [.todo, .inProgress, .done, .canceled] : OrgTodoStatus.agendaChoices
  }
}

private struct ApprovalsView: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var remote: MobileRemoteStore
  @EnvironmentObject private var audio: AudioApprovalController
  @State private var selected: ApprovalEntry?
  @State private var shareText: String?
  @State private var approvingID: ApprovalEntry.ID?
  @State private var rejection: ApprovalEntry?

  private var approvals: [ApprovalEntry] {
    remote.isPaired ? remote.workspaceApprovals : store.approvals
  }

  var body: some View {
    NavigationStack {
      List {
        AudioApprovalFeedbackSection()
        Section("Pending approvals") {
          ForEach(approvals) { item in
            Button {
              selected = item
            } label: {
              ApprovalRow(item: item, isApproving: approvingID == item.id)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .leading) {
              Button {
                Task { await approve(item) }
              } label: {
                Label(approvingID == item.id ? "Approving" : "Approve", systemImage: approvingID == item.id ? "hourglass" : "checkmark")
              }
              .tint(.green)
              .disabled(approvingID != nil)

              Button(role: .destructive) {
                rejection = item
              } label: {
                Label("Reject", systemImage: "xmark")
              }
              .disabled(approvingID != nil)
            }
            .swipeActions(edge: .trailing) {
              Button {
                openWhatsApp(text: item.whatsappText) {
                  shareText = item.whatsappText
                }
              } label: {
                Label("WhatsApp", systemImage: "message")
              }
              .tint(.teal)

              Button {
                Task { await store.sendToAIChat(.discuss, approval: item) }
              } label: {
                Label("Discuss", systemImage: "paperplane")
              }
              .tint(.blue)
            }
          }
        }
      }
      .overlay {
        if approvals.isEmpty && !audio.isEnabled && audio.replyHistory.isEmpty && remote.approvalHistory.isEmpty && isLoading {
          LoadingCorpusView()
        } else if approvals.isEmpty && !audio.isEnabled && audio.replyHistory.isEmpty && remote.approvalHistory.isEmpty, let connectionError = remoteWorkspaceError {
          ContentUnavailableView(
            "Approvals Unavailable",
            systemImage: "desktopcomputer.trianglebadge.exclamationmark",
            description: Text(connectionError)
          )
        } else if approvals.isEmpty && !audio.isEnabled && audio.replyHistory.isEmpty && remote.approvalHistory.isEmpty {
          ContentUnavailableView("No Approvals", systemImage: "checkmark.seal")
        }
      }
      .navigationTitle("Approvals")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          MobileSidebarToolbarButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await refresh() }
          } label: {
            if isLoading {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .disabled(isLoading)
        }
      }
      .refreshable {
        await refresh()
      }
      .sheet(item: $selected) { item in
        ApprovalDetailView(
          item: item,
          isApproving: approvingID == item.id,
          approve: { await approve(item) },
          requestChanges: { feedback in await requestChanges(item, feedback: feedback) },
          onReject: { rejection = item }
        ) { text in
          shareText = text
        }
      }
      .sheet(item: $rejection) { item in
        RejectApprovalView(item: item) { endStatus, reason in
          await reject(item, endStatus: endStatus, reason: reason)
        }
      }
      .sheet(item: Binding(
        get: { shareText.map(SharePayload.init(text:)) },
        set: { _ in shareText = nil }
      )) { payload in
        ActivitySheet(items: [payload.text])
      }
      .task {
        if remote.isPaired {
          await remote.refreshWorkspace(reportsErrors: false)
        } else {
          store.prepareCorpusViews()
        }
      }
    }
  }

  @MainActor
  private func approve(_ item: ApprovalEntry) async {
    guard approvingID == nil else { return }
    approvingID = item.id
    if remote.isPaired {
      await remote.decideApproval(item, decision: "approved")
    } else {
      await store.approve(item)
    }
    if approvingID == item.id {
      approvingID = nil
    }
  }

  @MainActor
  private func reject(_ item: ApprovalEntry, endStatus: OrgTodoStatus, reason: String) async {
    if remote.isPaired {
      await remote.decideApproval(
        item,
        decision: "rejected",
        note: reason,
        endStatus: endStatus
      )
    } else {
      await store.reject(item, endStatus: endStatus, reason: reason)
    }
  }

  @MainActor
  private func requestChanges(_ item: ApprovalEntry, feedback: String) async {
    guard remote.isPaired else {
      await store.sendToAIChat(.discuss, approval: item, message: feedback)
      return
    }
    await remote.decideApproval(item, decision: "revised", note: feedback)
  }

  private var isLoading: Bool {
    remote.isPaired
      ? remote.isRefreshingWorkspace
      : (store.isPreparingCorpus || store.isLoading)
  }

  private var remoteWorkspaceError: String? {
    guard remote.isPaired, remote.workspaceUpdatedAt == nil else { return nil }
    return remote.workspaceConnectionError
      ?? "Connect to the paired Mac to load canonical approvals."
  }

  private func refresh() async {
    if remote.isPaired {
      await remote.refreshWorkspace()
    } else {
      await store.refresh()
    }
  }
}

private struct WorkflowsView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @State private var selected: MobileRemoteWorkflowItem?

  var body: some View {
    NavigationStack {
      List(remote.workspaceWorkflows) { workflow in
        Button {
          selected = workflow
        } label: {
          WorkflowRow(workflow: workflow)
        }
        .buttonStyle(.plain)
      }
      .overlay {
        if !remote.isPaired {
          ContentUnavailableView(
            "Pair With Your Mac",
            systemImage: "desktopcomputer",
            description: Text("Workflows use the canonical Celorga runtime on your Mac.")
          )
        } else if remote.workspaceWorkflows.isEmpty && remote.isRefreshingWorkspace {
          LoadingCorpusView()
        } else if remote.workspaceWorkflows.isEmpty, remote.workspaceUpdatedAt == nil {
          ContentUnavailableView(
            "Workflows Unavailable",
            systemImage: "desktopcomputer.trianglebadge.exclamationmark",
            description: Text(
              remote.workspaceConnectionError
                ?? "Connect to the paired Mac to load canonical workflows."
            )
          )
        } else if remote.workspaceWorkflows.isEmpty {
          ContentUnavailableView("No Workflows", systemImage: "point.3.connected.trianglepath.dotted")
        }
      }
      .navigationTitle("Workflows")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await remote.refreshWorkspace() }
          } label: {
            if remote.isRefreshingWorkspace {
              ProgressView()
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .disabled(!remote.isPaired || remote.isRefreshingWorkspace)
        }
      }
      .refreshable {
        await remote.refreshWorkspace()
      }
      .sheet(item: $selected) { workflow in
        WorkflowDetailView(workflow: workflow)
      }
      .task {
        if remote.isPaired {
          await remote.refreshWorkspace(reportsErrors: false)
        }
      }
    }
  }
}

private struct WorkflowRow: View {
  let workflow: MobileRemoteWorkflowItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        StatusPill(workflow.state)
        Text(workflow.title.prettyPrintedOrgLinks())
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
      }
      if !workflow.description.isEmpty {
        Text(workflow.description.trimmedForDisplay(maxCharacters: 180))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      Label(workflow.scheduleSummary, systemImage: "clock")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 6)
  }
}

private struct WorkflowDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var remote: MobileRemoteStore
  let workflow: MobileRemoteWorkflowItem
  @State private var selectedState: String
  @State private var inputs: [String: String]

  init(workflow: MobileRemoteWorkflowItem) {
    self.workflow = workflow
    _selectedState = State(initialValue: workflow.state)
    _inputs = State(initialValue: Dictionary(uniqueKeysWithValues: workflow.inputs.map {
      ($0.id, $0.defaultValue ?? "")
    }))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(workflow.title.prettyPrintedOrgLinks())
            .font(.title3.weight(.semibold))
          if !workflow.description.isEmpty {
            Text(workflow.description.prettyPrintedOrgLinks())
              .foregroundStyle(.secondary)
          }
          LabeledContent("Schedule", value: workflow.scheduleSummary)
          LabeledContent("Risk", value: workflow.riskClass)
          if let agentRef = workflow.agentRef {
            LabeledContent("Agent", value: agentRef)
          }
          if let goalRef = workflow.goalRef {
            LabeledContent("Goal", value: goalRef)
          }
        }

        Section("State") {
          Picker("State", selection: $selectedState) {
            Text("Draft").tag("draft")
            Text("Active").tag("active")
            Text("Paused").tag("paused")
          }
          .pickerStyle(.segmented)

          if selectedState != workflow.state {
            Button("Save State") {
              Task {
                await remote.setWorkflowState(selectedState, for: workflow)
                dismiss()
              }
            }
            .disabled(isMutating)
          }
        }

        if !workflow.inputs.isEmpty {
          Section("Run Inputs") {
            ForEach(workflow.inputs) { input in
              VStack(alignment: .leading, spacing: 6) {
                TextField(
                  input.required ? "\(input.id) (required)" : input.id,
                  text: Binding(
                    get: { inputs[input.id, default: ""] },
                    set: { inputs[input.id] = $0 }
                  ),
                  axis: .vertical
                )
                if !input.description.isEmpty {
                  Text(input.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }

        Section {
          Button {
            Task {
              if let threadID = await remote.runWorkflow(workflow, inputs: inputs) {
                dismiss()
                NotificationCenter.default.post(
                  name: .org2OpenRemoteThread,
                  object: nil,
                  userInfo: ["threadID": threadID.uuidString]
                )
              }
            }
          } label: {
            if isMutating {
              HStack(spacing: 8) {
                ProgressView()
                Text("Starting…")
              }
              .frame(maxWidth: .infinity)
            } else {
              Label("Run Workflow", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isMutating || hasMissingRequiredInput)
        }
      }
      .navigationTitle("Workflow")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .disabled(isMutating)
        }
      }
      .interactiveDismissDisabled(isMutating)
    }
  }

  private var isMutating: Bool {
    remote.mutatingWorkspaceItemIDs.contains(workflow.id)
  }

  private var hasMissingRequiredInput: Bool {
    workflow.inputs.contains { input in
      input.required
        && inputs[input.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}

private struct ApprovalRow: View {
  let item: ApprovalEntry
  let isApproving: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        StatusPill(item.status)
        Text(item.title.prettyPrintedOrgLinks())
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
      }

      if !item.body.isEmpty {
        Text(item.body.trimmedForDisplay(maxCharacters: 180))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }

      Text(item.sourceLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)

      if isApproving {
        HStack(spacing: 6) {
          MobileActivityIndicator(style: .approval, tint: .green, label: "Approving")
          Text("Approving...")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.green)
      }
    }
    .padding(.vertical, 6)
  }
}

private struct ApprovalDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: CorpusStore
  let item: ApprovalEntry
  let isApproving: Bool
  let approve: () async -> Void
  let requestChanges: (String) async -> Void
  let onReject: () -> Void
  let fallbackShare: (String) -> Void
  @State private var message: String = ""

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            StatusPill(item.status)
            Text(item.title.prettyPrintedOrgLinks())
              .font(.title3.weight(.semibold))
            Text(item.sourceLabel)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .padding(.vertical, 4)
        }

        Section("Entry") {
          ForEach(metadataRows) { row in
            ApprovalMetadataRow(row: row)
          }
        }

        Section("Properties") {
          if sortedProperties.isEmpty {
            Text("No properties")
              .foregroundStyle(.secondary)
          } else {
            ForEach(sortedProperties, id: \.key) { property in
              ApprovalPropertyRow(key: property.key, value: property.value)
            }
          }
        }

        if !item.body.isEmpty {
          Section("Body") {
            Text(item.body.prettyPrintedOrgLinks())
              .font(.body)
              .textSelection(.enabled)
          }
        }

        Section("Message to OpenClaw") {
          TextEditor(text: $message)
            .frame(minHeight: 96)
        }

        Section {
          Button {
            Task {
              await approve()
              dismiss()
            }
          } label: {
            if isApproving {
              HStack(spacing: 8) {
                MobileActivityIndicator(style: .approval, tint: .white, label: "Approving")
                Text("Approving...")
              }
              .frame(maxWidth: .infinity)
            } else {
              Label("Approve", systemImage: "checkmark.seal")
                .frame(maxWidth: .infinity)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isApproving)

          Button(role: .destructive) {
            dismiss()
            onReject()
          } label: {
            Label("Reject", systemImage: "xmark.octagon")
              .frame(maxWidth: .infinity)
          }

          if item.isRunApproval {
            Button {
              Task {
                await requestChanges(message)
                dismiss()
              }
            } label: {
              Label("Request Changes", systemImage: "arrow.uturn.backward.circle")
                .frame(maxWidth: .infinity)
            }
            .disabled(
              isApproving
                || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
          }

          Button {
            openWhatsApp(text: item.whatsappText) {
              fallbackShare(item.whatsappText)
            }
          } label: {
            Label("WhatsApp", systemImage: "message")
              .frame(maxWidth: .infinity)
          }
          .disabled(isApproving)

          Button {
            Task {
              await store.sendToAIChat(.discuss, approval: item, message: message)
              dismiss()
            }
          } label: {
            Label("Discuss via OpenClaw", systemImage: "paperplane")
              .frame(maxWidth: .infinity)
          }
          .disabled(isApproving)
        }
      }
      .navigationTitle("Approval")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") {
            dismiss()
          }
          .disabled(isApproving)
        }
      }
      .interactiveDismissDisabled(isApproving)
      .onAppear {
        if message.isEmpty {
          message = "I need to discuss this approval item before deciding."
        }
      }
    }
  }

  private var metadataRows: [ApprovalMetadataRow.Model] {
    [
      ApprovalMetadataRow.Model(label: "Status", value: item.status),
      ApprovalMetadataRow.Model(label: "TODO", value: item.todo),
      ApprovalMetadataRow.Model(label: "Level", value: item.level.map(String.init)),
      ApprovalMetadataRow.Model(label: "Source", value: item.sourceLabel, isMonospaced: true),
      ApprovalMetadataRow.Model(label: "ID", value: item.sourceID, isMonospaced: true),
      ApprovalMetadataRow.Model(label: "Tags", value: item.tags.isEmpty ? nil : item.tags.map { ":\($0):" }.joined(separator: " ")),
    ].compactMap { $0 }
  }

  private var sortedProperties: [(key: String, value: String)] {
    item.properties.sorted {
      $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
    }
  }
}

private struct RejectApprovalView: View {
  @Environment(\.dismiss) private var dismiss
  let item: ApprovalEntry
  let reject: (OrgTodoStatus, String) async -> Void
  @State private var endStatus: OrgTodoStatus = .canceled
  @State private var reason = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(item.title.prettyPrintedOrgLinks())
            .font(.headline)
          Text(item.sourceLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Section("End Status") {
          Picker("End Status", selection: $endStatus) {
            Text("Canceled").tag(OrgTodoStatus.canceled)
            Text("Done").tag(OrgTodoStatus.done)
          }
          .pickerStyle(.segmented)
        }

        Section("Reason (optional)") {
          TextEditor(text: $reason)
            .frame(minHeight: 120)
        }

        Section {
          Button(role: .destructive) {
            Task {
              await reject(endStatus, reason)
              dismiss()
            }
          } label: {
            Label("Reject", systemImage: "xmark.octagon")
              .frame(maxWidth: .infinity)
          }
        }
      }
      .navigationTitle("Reject Approval")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }
}

private struct ApprovalMetadataRow: View {
  struct Model: Identifiable {
    let label: String
    let value: String
    let isMonospaced: Bool

    var id: String { label }

    init?(label: String, value: String?, isMonospaced: Bool = false) {
      guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
      }
      self.label = label
      self.value = value
      self.isMonospaced = isMonospaced
    }
  }

  let row: Model

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(row.label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      if row.isMonospaced {
        Text(row.value.prettyPrintedOrgLinks())
          .font(.caption.monospaced())
          .textSelection(.enabled)
      } else {
        Text(row.value.prettyPrintedOrgLinks())
          .font(.body)
          .textSelection(.enabled)
      }
    }
    .padding(.vertical, 2)
  }
}

private struct ApprovalPropertyRow: View {
  let key: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(key)
        .font(.caption.weight(.semibold).monospaced())
        .foregroundStyle(.secondary)
      Text(value.prettyPrintedOrgLinks())
        .font(.body)
        .textSelection(.enabled)
    }
    .padding(.vertical, 3)
  }
}

private struct NewNoteView: View {
  @EnvironmentObject private var store: CorpusStore
  @State private var title = ""
  @State private var bodyText = ""
  @State private var schedule: MobileNoteSchedule = .none
  @State private var customScheduledDate = Date()
  @State private var attachments: [NoteAttachment] = []
  @State private var isPhotoLibraryPresented = false
  @State private var isCameraPresented = false
  @State private var isCallImportPresented = false
  @FocusState private var focusedField: NewNoteFocusedField?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Title", text: $title)
            .font(.title3.weight(.semibold))
            .focused($focusedField, equals: .title)
          TextEditor(text: $bodyText)
            .frame(minHeight: 260)
            .focused($focusedField, equals: .body)

          if !attachments.isEmpty {
            ForEach(attachments) { attachment in
              HStack {
                Label(attachment.filename, systemImage: "photo")
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer()
                Button {
                  attachments.removeAll { $0.id == attachment.id }
                } label: {
                  Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
              }
            }
          }
        } footer: {
          Text("Saved to mobile-inbox.org for safe desktop sync.")
        }

        Section {
          HStack(spacing: 16) {
            Menu {
              ForEach(MobileNoteSchedule.allCases) { option in
                Button {
                  schedule = option
                } label: {
                  Label(option.title, systemImage: schedule == option ? "checkmark" : option.systemImage)
                }
              }
            } label: {
              Label(schedule.title, systemImage: schedule.systemImage)
            }

            Spacer()

            Menu {
              Button {
                isPhotoLibraryPresented = true
              } label: {
                Label("Photo Library", systemImage: "photo")
              }
              Button {
                isCameraPresented = true
              } label: {
                Label("Camera", systemImage: "camera")
              }
              .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            } label: {
              Label("Attach", systemImage: "paperclip")
            }
          }

          if schedule == .custom {
            DatePicker(
              "Schedule date",
              selection: $customScheduledDate,
              displayedComponents: .date
            )
          } else if let date = scheduledDate {
            LabeledContent(
              "Scheduled",
              value: MobileCaptureWriter.orgDayTimestamp(date)
            )
          }

          Button {
            focusedField = nil
            isCallImportPresented = true
          } label: {
            Label("Import Phone Call", systemImage: "phone.arrow.down.left")
          }
        }
      }
      .navigationTitle("New Note")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          MobileSidebarToolbarButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Save") {
            saveNote()
          }
          .fontWeight(.semibold)
          .disabled(isSaveDisabled)
        }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") {
            focusedField = nil
          }
        }
      }
      .sheet(isPresented: $isCameraPresented) {
        ImagePicker(sourceType: .camera) { image in
          addImage(image)
        }
      }
      .sheet(isPresented: $isPhotoLibraryPresented) {
        ImagePicker(sourceType: .photoLibrary) { image in
          addImage(image)
        }
      }
      .sheet(isPresented: $isCallImportPresented) {
        MobileCallTranscriptImportView { draft in
          applyCallTranscript(draft)
        }
      }
    }
  }

  private var isSaveDisabled: Bool {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && attachments.isEmpty
  }

  private func saveNote() {
    guard !isSaveDisabled else { return }
    Task {
      await store.saveMobileNote(
        title: title,
        body: bodyText,
        attachments: attachments,
        scheduledDate: scheduledDate
      )
      title = ""
      bodyText = ""
      schedule = .none
      customScheduledDate = Date()
      attachments = []
      focusedField = nil
    }
  }

  private func addImage(_ image: UIImage) {
    guard let data = image.jpegData(compressionQuality: 0.86) else { return }
    addImageData(data)
  }

  private func addImageData(_ data: Data) {
    let imageData = UIImage(data: data)?.jpegData(compressionQuality: 0.86) ?? data
    let filename = "photo-\(UUID().uuidString.prefix(8)).jpg"
    attachments.append(NoteAttachment(filename: filename, data: imageData))
  }

  private func applyCallTranscript(_ draft: MobileCallTranscriptDraft) {
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      title = draft.title
    }
    if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      bodyText = draft.body
    } else {
      bodyText += "\n\n\(draft.body)"
    }
    focusedField = .body
  }

  private var scheduledDate: Date? {
    schedule.scheduledDate(customDate: customScheduledDate)
  }
}

private enum NewNoteFocusedField: Hashable {
  case title
  case body
}

private struct RefreshButton: View {
  @EnvironmentObject private var store: CorpusStore

  var body: some View {
    Button {
      Task { await store.refresh() }
    } label: {
      if store.isPreparingCorpus || store.isLoading {
        MobileActivityIndicator(style: .sync, label: "Refreshing")
      } else {
        Image(systemName: "arrow.clockwise")
      }
    }
    .disabled(store.isPreparingCorpus || store.isLoading)
  }
}

private struct LoadingCorpusView: View {
  var body: some View {
    VStack(spacing: 12) {
      MobileShimmerLines()
      Text("Loading corpus")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding()
  }
}

private enum MobileActivityStyle: Equatable {
  case sync
  case approval
}

private struct MobileActivityIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let style: MobileActivityStyle
  var tint: Color = .accentColor
  var label = "Loading"

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
      let phase = reduceMotion
        ? 0.2
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.15) / 1.15

      HStack(alignment: .center, spacing: style == .approval ? 2.5 : 2) {
        ForEach(0..<3, id: \.self) { index in
          let value = wave(phase, index: index)
          activityMark(value: value)
          .frame(
            width: style == .approval ? 3.5 : 2.5,
            height: style == .approval ? 3.5 : 4 + value * 8
          )
          .offset(y: style == .approval ? -value * 2.5 : 0)
        }
      }
    }
    .frame(width: 18, height: 14)
    .accessibilityLabel(label)
  }

  private func wave(_ phase: Double, index: Int) -> CGFloat {
    let angle = phase * 2 * Double.pi - Double(index) * 0.9
    return CGFloat((sin(angle) + 1) / 2)
  }

  @ViewBuilder
  private func activityMark(value: CGFloat) -> some View {
    if style == .approval {
      Circle().fill(tint.opacity(0.35 + Double(value) * 0.65))
    } else {
      Capsule().fill(tint.opacity(0.35 + Double(value) * 0.65))
    }
  }
}

private struct MobileShimmerLines: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
      let phase = reduceMotion
        ? 0.45
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.55) / 1.55

      VStack(alignment: .leading, spacing: 7) {
        line(width: 118, phase: phase)
        line(width: 88, phase: phase)
        line(width: 104, phase: phase)
      }
    }
    .accessibilityHidden(true)
  }

  private func line(width: CGFloat, phase: Double) -> some View {
    RoundedRectangle(cornerRadius: 4, style: .continuous)
      .fill(Color.secondary.opacity(0.12))
      .frame(width: width, height: 8)
      .overlay(alignment: .leading) {
        LinearGradient(
          colors: [.clear, Color.accentColor.opacity(0.28), .clear],
          startPoint: .leading,
          endPoint: .trailing
        )
        .frame(width: 50)
        .offset(x: (width + 50) * CGFloat(phase) - 50)
      }
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
  }
}

private struct StatusPill: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(displayText.uppercased())
      .font(.caption2.weight(.bold))
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .foregroundStyle(color)
      .background(color.opacity(0.12), in: Capsule())
      .lineLimit(1)
      .minimumScaleFactor(0.75)
  }

  private var displayText: String {
    let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized == "review-required"
      || normalized == "requires-review"
      || normalized == "approval-required"
      || normalized == "needs-approval"
      || normalized == "pending-approval"
      || normalized == "approval"
      || normalized.contains("approval")
      || normalized.contains("review") {
      return "Needs Review"
    }
    return text
  }

  private var color: Color {
    let normalized = text.lowercased()
    if normalized.contains("review") || normalized.contains("approval") { return .orange }
    if normalized == "approve" || normalized == "approved" { return .green }
    if normalized == "wait" || normalized == "hold" || normalized == "paused" { return .yellow }
    if normalized == "deadline" { return .red }
    return .accentColor
  }
}

private struct SharePayload: Identifiable {
  let text: String
  var id: String { text }
}

@MainActor
private func openWhatsApp(text: String, fallback: @escaping () -> Void) {
  guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
        let url = URL(string: "whatsapp://send?text=\(encoded)") else {
    fallback()
    return
  }

  UIApplication.shared.open(url, options: [:]) { opened in
    if !opened {
      fallback()
    }
  }
}
