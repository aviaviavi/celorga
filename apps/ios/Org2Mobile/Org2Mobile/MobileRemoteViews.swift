import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import VisionKit
import WebKit

private func mobileAIRuntimeTitle(_ runtime: String) -> String {
  switch runtime {
  case "codex": "Codex"
  case "claude": "Claude Code"
  default: "OpenClaw"
  }
}

private func mobileAIRuntimeSystemImage(_ runtime: String) -> String {
  switch runtime {
  case "codex": "chevron.left.forwardslash.chevron.right"
  case "claude": "c.circle"
  default: "network"
  }
}

private struct MobileRemoteProjectLabel: View {
  let project: MobileRemoteProjectSummary

  var body: some View {
    HStack(spacing: 7) {
      if project.color == "none" {
        Image(systemName: "folder")
          .foregroundStyle(.secondary)
      } else {
        Circle()
          .fill(tint)
          .frame(width: 9, height: 9)
      }
      Text(project.title)
        .lineLimit(1)
    }
  }

  private var tint: Color {
    if project.color.hasPrefix("#"),
       project.color.count == 7,
       let value = UInt64(project.color.dropFirst(), radix: 16) {
      return Color(
        red: Double((value >> 16) & 255) / 255,
        green: Double((value >> 8) & 255) / 255,
        blue: Double(value & 255) / 255
      )
    }
    return switch project.color {
    case "teal": .teal
    case "green": .green
    case "orange": .orange
    case "red": .red
    case "purple": .purple
    case "gray": .gray
    default: .blue
    }
  }
}

struct MobileAISidebarView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @State private var expandedProjectIDs: Set<String> = []
  let selectedThreadID: UUID?
  let openWorkspace: () -> Void
  let openFiles: () -> Void
  let openThread: (UUID) -> Void
  let openExternalThreads: () -> Void
  let openSettings: () -> Void
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("AI Chat")
            .font(.title2.weight(.bold))
          Text(remote.isPaired ? statusSubtitle : "Connect a Host to start chatting")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if remote.isPaired {
          Menu {
            ForEach(aiChatDestinations) { destination in
              Button {
                createThread(destination: destination)
              } label: {
                Label("New \(destination.name) Chat", systemImage: "plus.bubble")
              }
            }
            if !remote.projects.isEmpty {
              Divider()
              Menu("New Chat in Project", systemImage: "folder.badge.plus") {
                ForEach(remote.projects) { project in
                  Menu(project.title) {
                    ForEach(aiChatDestinations) { destination in
                      Button(destination.name) {
                        createThread(destination: destination, project: project)
                      }
                    }
                  }
                }
              }
            }
          } label: {
            Image(systemName: "square.and.pencil")
          }
          .disabled(!remote.isConnected)
          .accessibilityLabel("New AI chat")
        }
        Button(action: close) {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Close sidebar")
      }
      .padding(.horizontal, 18)
      .padding(.top, 18)
      .padding(.bottom, 10)

      List {
        Section {
          sidebarButton("Workspace", systemImage: "square.grid.2x2", action: openWorkspace)
          sidebarButton("Files", systemImage: "folder", action: openFiles)
          sidebarButton(
            "External Threads",
            systemImage: "rectangle.stack.badge.person.crop",
            action: openExternalThreads
          )
          .disabled(!remote.isPaired)
          sidebarButton("Settings", systemImage: "gearshape", action: openSettings)
        }

        if !remote.projects.isEmpty {
          Section("Projects") {
            ForEach(remote.projects) { project in
              DisclosureGroup(isExpanded: projectExpansionBinding(project.id)) {
                let projectThreads = activeThreads(in: project)
                ForEach(projectThreads) { thread in
                  threadButton(thread)
                }
                if projectThreads.isEmpty {
                  Text("No active chats")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Menu {
                  ForEach(aiChatDestinations) { destination in
                    Button(destination.name) {
                      createThread(destination: destination, project: project)
                    }
                  }
                } label: {
                  Label("New Chat", systemImage: "plus.bubble")
                }
              } label: {
                MobileRemoteProjectLabel(project: project)
              }
            }
          }
        }

        if !runningThreads.isEmpty {
          Section("Running") {
            ForEach(runningThreads) { thread in
              threadButton(thread)
            }
          }
        }

        if !idleThreads.isEmpty {
          Section("Threads") {
            ForEach(idleThreads) { thread in
              threadButton(thread)
            }
          }
        }

        if !settledThreads.isEmpty {
          Section("Settled") {
            ForEach(settledThreads) { thread in
              threadButton(thread)
            }
          }
        }

        if remote.isPaired && remote.threads.isEmpty && !remote.isRefreshing {
          Section {
            Text("No AI chats yet")
              .foregroundStyle(.secondary)
          }
        }
      }
      .listStyle(.sidebar)
      .refreshable {
        if remote.isPaired { await remote.refresh() }
      }
    }
    .background(.regularMaterial)
    .shadow(color: .black.opacity(0.18), radius: 18, x: 8)
    .task {
      if remote.isPaired && remote.threads.isEmpty {
        await remote.refresh(reportsErrors: false)
      }
      expandProjectContainingSelection()
    }
    .onChange(of: selectedThreadID) {
      expandProjectContainingSelection()
    }
    .onChange(of: remote.projects) {
      expandProjectContainingSelection()
    }
  }

  private func projectExpansionBinding(_ projectID: String) -> Binding<Bool> {
    Binding(
      get: { expandedProjectIDs.contains(projectID) },
      set: { isExpanded in
        if isExpanded {
          expandedProjectIDs.insert(projectID)
        } else {
          expandedProjectIDs.remove(projectID)
        }
      }
    )
  }

  private func expandProjectContainingSelection() {
    guard let selectedThreadID else { return }
    for project in remote.projects where project.contains(selectedThreadID) {
      expandedProjectIDs.insert(project.id)
    }
  }

  private func activeThreads(
    in project: MobileRemoteProjectSummary
  ) -> [MobileRemoteThreadSummary] {
    activeThreads.filter { project.contains($0.id) }
  }

  private var activeThreads: [MobileRemoteThreadSummary] {
    remote.threads.filter { !$0.isSettled }.runningFirst
  }

  private var runningThreads: [MobileRemoteThreadSummary] {
    activeThreads.filter(\.isRunning)
  }

  private var idleThreads: [MobileRemoteThreadSummary] {
    activeThreads.filter { !$0.isRunning }
  }

  private var settledThreads: [MobileRemoteThreadSummary] {
    remote.threads.filter(\.isSettled)
  }

  private func sidebarButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func threadButton(_ thread: MobileRemoteThreadSummary) -> some View {
    Button {
      openThread(thread.id)
    } label: {
      MobileRemoteThreadRow(thread: thread)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(
      selectedThreadID == thread.id ? Color.accentColor.opacity(0.12) : Color.clear
    )
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button {
        Task { await remote.setPinned(!thread.isPinned, threadID: thread.id) }
      } label: {
        Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
      }
      .tint(.orange)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button {
        Task { await remote.setSettled(!thread.isSettled, threadID: thread.id) }
      } label: {
        Label(
          thread.isSettled ? "Reopen" : "Settle",
          systemImage: thread.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle"
        )
      }
      .tint(thread.isSettled ? .blue : .green)
    }
    .contextMenu {
      Button {
        Task {
          if let forkedThreadID = await remote.forkThread(thread.id) {
            openThread(forkedThreadID)
          }
        }
      } label: {
        Label("Fork Thread", systemImage: "arrow.triangle.branch")
      }
      if !remote.projects.isEmpty {
        Menu("Projects", systemImage: "folder") {
          ForEach(remote.projects) { project in
            Button {
              Task {
                await remote.setProjectMembership(
                  !project.contains(thread.id),
                  project: project,
                  threadID: thread.id
                )
              }
            } label: {
              Label(
                project.title,
                systemImage: project.contains(thread.id) ? "checkmark.circle.fill" : "circle"
              )
            }
          }
        }
      }
      Button {
        Task { await remote.setPinned(!thread.isPinned, threadID: thread.id) }
      } label: {
        Label(thread.isPinned ? "Unpin Thread" : "Pin Thread", systemImage: thread.isPinned ? "pin.slash" : "pin")
      }
      Button {
        Task { await remote.setSettled(!thread.isSettled, threadID: thread.id) }
      } label: {
        Label(
          thread.isSettled ? "Reopen Thread" : "Settle Thread",
          systemImage: thread.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle"
        )
      }
    }
  }

  private var statusSubtitle: String {
    guard remote.isConnected else { return "Waiting for \(remote.serverName)" }
    let running = remote.status?.runningThreadCount ?? 0
    return running == 1 ? "1 chat running" : "\(running) chats running"
  }

  private var aiChatDestinations: [MobileRemoteAIDestination] {
    if let destinations = remote.status?.aiChatDestinations, !destinations.isEmpty {
      return destinations
    }
    return [
      MobileRemoteAIDestination(id: "builtin.codex", name: "Codex", mention: "codex", runtime: "codex"),
      MobileRemoteAIDestination(id: "builtin.openclaw", name: "OpenClaw", mention: "openclaw", runtime: "openClaw")
    ]
  }

  private func createThread(
    destination: MobileRemoteAIDestination,
    project: MobileRemoteProjectSummary? = nil
  ) {
    Task {
      if let threadID = await remote.createThread(
        destination: destination,
        project: project
      ) {
        if let project { expandedProjectIDs.insert(project.id) }
        openThread(threadID)
      }
    }
  }
}

struct MobileSettingsView: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var remote: MobileRemoteStore

  var body: some View {
    Form {
      Section("Corpus") {
        LabeledContent("Current corpus", value: store.rootURL == nil ? "Not selected" : store.corpusName)
        Button {
          store.isDocumentPickerPresented = true
        } label: {
          Label(store.rootURL == nil ? "Select Corpus" : "Change Corpus", systemImage: "folder")
        }
      }

      Section("Host Connection") {
        ForEach(remote.savedHosts) { host in
          Button {
            remote.selectHost(host)
          } label: {
            Label(host.name, systemImage: host.id == remote.activeHostID ? "checkmark.circle.fill" : "server.rack")
          }
          .disabled(!remote.canChangeHost)
        }
        if remote.isPaired {
          NavigationLink("Add Another Host") {
            MobileRemotePairingView()
              .navigationTitle("Connect Host")
          }
          .disabled(!remote.canChangeHost)
          Text("Each host provides chats from its configured corpus. Choose the server to keep working while your laptop is away.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if remote.isPaired {
          LabeledContent("Host", value: remote.serverName)
          LabeledContent("Status", value: remote.isConnected ? "Connected" : "Unavailable")
          LabeledContent("Endpoint", value: remote.pairedEndpoint)
          if let connectionError = remote.connectionError, !remote.isConnected {
            Text(connectionError)
              .font(.caption)
              .foregroundStyle(.orange)
          }
          Button {
            Task { await remote.refresh() }
          } label: {
            Label("Reconnect", systemImage: "arrow.clockwise")
          }
          .disabled(remote.isRefreshing)
          Button("Forget This Host", role: .destructive) {
            remote.disconnect()
          }
        } else {
          NavigationLink {
            MobileRemotePairingView()
              .navigationTitle("Connect Host")
              .navigationBarTitleDisplayMode(.inline)
          } label: {
            Label("Connect a Host", systemImage: "desktopcomputer")
          }
          Text("Pair over Tailscale to use AI chat, external tasks, and canonical approvals from your host.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if remote.isPaired {
        Section {
          Toggle(isOn: Binding(
            get: { remote.threadNotificationsEnabled },
            set: { remote.setThreadNotificationsEnabled($0) }
          )) {
            Label("Notify me about replies", systemImage: "bell")
          }

          Text(remote.pushNotificationStatusText)
            .font(.caption)
            .foregroundStyle(notificationStatusColor)

          if remote.threadNotificationsUnavailable {
            Button {
              guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
              UIApplication.shared.open(settingsURL)
            } label: {
              Label("Open Notification Settings", systemImage: "gear")
            }
          } else if remote.threadNotificationsEnabled {
            Button {
              Task { await remote.sendTestReplyNotification() }
            } label: {
              Label("Send Test Notification", systemImage: "bell.badge")
            }
            .disabled(!remote.realTimeNotificationsActive)
          }
        } header: {
          Text("Reply Notifications")
        } footer: {
          Text("Reply alerts use Apple Push Notifications when available, with background checks as a fallback.")
        }
      }
    }
    .navigationTitle("Settings")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        MobileSidebarToolbarButton()
      }
    }
  }

  private var notificationStatusColor: Color {
    if remote.threadNotificationsUnavailable { return .orange }
    if remote.realTimeNotificationsActive { return .green }
    return .secondary
  }
}

struct MobileRemoteRootView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @State private var path: [UUID] = []
  @State private var expandedProjectIDs: Set<String> = []

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if remote.isPaired {
          threadList
        } else {
          MobileRemotePairingView()
        }
      }
      .navigationTitle("Remote")
      .navigationDestination(for: UUID.self) { threadID in
        MobileRemoteThreadView(threadID: threadID) { destinationThreadID in
          navigate(to: destinationThreadID)
        }
      }
      .toolbar {
        if remote.isPaired {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              ForEach(aiChatDestinations) { destination in
                Button {
                  createThread(destination: destination)
                } label: {
                  Label("New \(destination.name) Chat", systemImage: "plus.bubble")
                }
              }
              if !remote.projects.isEmpty {
                Divider()
                Menu("New Chat in Project", systemImage: "folder.badge.plus") {
                  ForEach(remote.projects) { project in
                    Menu(project.title) {
                      ForEach(aiChatDestinations) { destination in
                        Button(destination.name) {
                          createThread(destination: destination, project: project)
                        }
                      }
                    }
                  }
                }
              }
              Divider()
              Button("Forget This Host", role: .destructive) {
                path = []
                remote.disconnect()
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
            .disabled(!remote.isConnected)
          }
        }
      }
      .task {
        if remote.isPaired {
          await remote.refresh()
        }
      }
    }
    .alert("Mobile Remote", isPresented: Binding(
      get: { remote.errorMessage != nil },
      set: { if !$0 { remote.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(remote.errorMessage ?? "")
    }
  }

  private func navigate(to threadID: UUID) {
    let destination = [threadID]
    guard path != destination else { return }
    path = destination
  }

  private var threadList: some View {
    List {
      Section {
        HStack(spacing: 12) {
          Image(systemName: "desktopcomputer")
            .font(.title3)
            .foregroundStyle(.blue)
          VStack(alignment: .leading, spacing: 2) {
            Text(remote.serverName)
              .font(.headline)
            Text(statusSubtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if remote.isRefreshing {
            ProgressView()
              .controlSize(.small)
          } else {
            Circle()
              .fill(remote.isConnected ? Color.green : Color.secondary)
              .frame(width: 8, height: 8)
              .accessibilityLabel(remote.isConnected ? "Connected" : "Host unavailable")
          }
        }
        .padding(.vertical, 3)

        if !remote.isConnected, !remote.isRefreshing {
          VStack(alignment: .leading, spacing: 8) {
            Text(remote.connectionError ?? "This phone cannot currently reach the selected host.")
              .font(.caption)
              .foregroundStyle(.orange)
            HStack {
              Button {
                Task { await remote.refresh() }
              } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
              }
              Button("Pair Again", role: .destructive) {
                path = []
                remote.disconnect()
              }
            }
          }
        }

        Toggle(isOn: Binding(
          get: { remote.threadNotificationsEnabled },
          set: { remote.setThreadNotificationsEnabled($0) }
        )) {
          VStack(alignment: .leading, spacing: 2) {
            Label("Reply notifications", systemImage: "bell")
            Text(
              remote.threadNotificationsUnavailable
                ? "Notifications are disabled in iOS Settings"
                : remote.pushNotificationStatusText
            )
            .font(.caption)
            .foregroundStyle(
              remote.threadNotificationsUnavailable
                ? Color.orange
                : remote.realTimeNotificationsActive ? Color.green : Color.secondary
            )
          }
        }

        if remote.threadNotificationsEnabled {
          if remote.threadNotificationsUnavailable {
            Button {
              guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
              UIApplication.shared.open(settingsURL)
            } label: {
              Label("Open Notification Settings", systemImage: "gear")
            }
          } else {
            Button {
              Task { await remote.sendTestReplyNotification() }
            } label: {
              Label("Send Test Push", systemImage: "bell.badge")
            }
            .disabled(!remote.realTimeNotificationsActive)
          }
        }

        Text("Real-time alerts arrive through Apple Push Notifications. Background checks remain as a fallback when push is unavailable. Alerts have no sound or badge.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("External") {
        NavigationLink {
          MobileExternalThreadListView { threadID in
            path = [threadID]
          }
        } label: {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("External Threads")
              Text("Read native Codex tasks without changing them")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "rectangle.stack.badge.person.crop")
              .foregroundStyle(.blue)
          }
        }
      }

      if !remote.projects.isEmpty {
        Section("Projects") {
          ForEach(remote.projects) { project in
            DisclosureGroup(isExpanded: projectExpansionBinding(project.id)) {
              let projectThreads = activeThreads(in: project)
              ForEach(projectThreads) { thread in
                threadLink(thread)
              }
              if projectThreads.isEmpty {
                Text("No active chats")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Menu {
                ForEach(aiChatDestinations) { destination in
                  Button(destination.name) {
                    createThread(destination: destination, project: project)
                  }
                }
              } label: {
                Label("New Chat", systemImage: "plus.bubble")
              }
            } label: {
              MobileRemoteProjectLabel(project: project)
            }
          }
        }
      }

      if !runningThreads.isEmpty {
        Section("Running") {
          ForEach(runningThreads) { thread in
            threadLink(thread)
          }
        }
      }

      if !idleThreads.isEmpty {
        Section("Chats") {
          ForEach(idleThreads) { thread in
            threadLink(thread)
          }
        }
      }

      if !settledThreads.isEmpty {
        Section("Settled") {
          ForEach(settledThreads) { thread in
            threadLink(thread)
          }
        }
      }

      if remote.isConnected && remote.threads.isEmpty && !remote.isRefreshing {
        Section("Chats") {
          VStack(spacing: 7) {
            Image(systemName: "bubble.left.and.bubble.right")
              .font(.title2)
              .foregroundStyle(.secondary)
            Text("No Remote Chats")
              .font(.headline)
            Text("Create a chat here or in Celorga on your host.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 18)
          .accessibilityElement(children: .combine)
        }
      }
    }
    .refreshable {
      await remote.refresh()
    }
  }

  private var activeThreads: [MobileRemoteThreadSummary] {
    remote.threads.filter { !$0.isSettled }.runningFirst
  }

  private var runningThreads: [MobileRemoteThreadSummary] {
    activeThreads.filter(\.isRunning)
  }

  private var idleThreads: [MobileRemoteThreadSummary] {
    activeThreads.filter { !$0.isRunning }
  }

  private func projectExpansionBinding(_ projectID: String) -> Binding<Bool> {
    Binding(
      get: { expandedProjectIDs.contains(projectID) },
      set: { isExpanded in
        if isExpanded {
          expandedProjectIDs.insert(projectID)
        } else {
          expandedProjectIDs.remove(projectID)
        }
      }
    )
  }

  private func activeThreads(
    in project: MobileRemoteProjectSummary
  ) -> [MobileRemoteThreadSummary] {
    activeThreads.filter { project.contains($0.id) }
  }

  private var settledThreads: [MobileRemoteThreadSummary] {
    remote.threads.filter(\.isSettled)
  }

  private func threadLink(_ thread: MobileRemoteThreadSummary) -> some View {
    NavigationLink(value: thread.id) {
      MobileRemoteThreadRow(thread: thread)
    }
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button {
        Task { await remote.setPinned(!thread.isPinned, threadID: thread.id) }
      } label: {
        Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin")
      }
      .tint(.orange)
      .disabled(remote.mutatingThreadIDs.contains(thread.id))
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button {
        Task { await remote.setSettled(!thread.isSettled, threadID: thread.id) }
      } label: {
        Label(
          thread.isSettled ? "Reopen" : "Settle",
          systemImage: thread.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle"
        )
      }
      .tint(thread.isSettled ? .blue : .green)
      .disabled(remote.mutatingThreadIDs.contains(thread.id))
    }
    .contextMenu {
      Button {
        Task {
          if let forkedThreadID = await remote.forkThread(thread.id) {
            path = [forkedThreadID]
          }
        }
      } label: {
        Label("Fork Thread", systemImage: "arrow.triangle.branch")
      }
      if !remote.projects.isEmpty {
        Menu("Projects", systemImage: "folder") {
          ForEach(remote.projects) { project in
            Button {
              Task {
                await remote.setProjectMembership(
                  !project.contains(thread.id),
                  project: project,
                  threadID: thread.id
                )
              }
            } label: {
              Label(
                project.title,
                systemImage: project.contains(thread.id) ? "checkmark.circle.fill" : "circle"
              )
            }
          }
        }
      }
      Button {
        Task { await remote.setPinned(!thread.isPinned, threadID: thread.id) }
      } label: {
        Label(thread.isPinned ? "Unpin Thread" : "Pin Thread", systemImage: thread.isPinned ? "pin.slash" : "pin")
      }
      Button {
        Task { await remote.setSettled(!thread.isSettled, threadID: thread.id) }
      } label: {
        Label(
          thread.isSettled ? "Reopen Thread" : "Settle Thread",
          systemImage: thread.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle"
        )
      }
    }
  }

  private var statusSubtitle: String {
    guard remote.isConnected else { return "Waiting for host over Tailscale" }
    guard let status = remote.status else { return "Connected over Tailscale" }
    let corpus = status.corpusName.map { " • \($0)" } ?? ""
    let running = status.runningThreadCount == 1
      ? "1 chat running"
      : "\(status.runningThreadCount) chats running"
    return "\(running)\(corpus)"
  }

  private var aiChatDestinations: [MobileRemoteAIDestination] {
    if let destinations = remote.status?.aiChatDestinations, !destinations.isEmpty {
      return destinations
    }
    return [
      MobileRemoteAIDestination(
        id: "builtin.codex",
        name: "Codex",
        mention: "codex",
        runtime: "codex"
      ),
      MobileRemoteAIDestination(
        id: "builtin.openclaw",
        name: "OpenClaw",
        mention: "openclaw",
        runtime: "openClaw"
      )
    ]
  }

  private func createThread(
    destination: MobileRemoteAIDestination,
    project: MobileRemoteProjectSummary? = nil
  ) {
    Task {
      if let id = await remote.createThread(destination: destination, project: project) {
        if let project { expandedProjectIDs.insert(project.id) }
        path = [id]
      }
    }
  }
}

struct MobileExternalThreadListView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @State private var query = ""
  let continueInOrg2: (UUID) -> Void

  var body: some View {
    List {
      if !filteredThreads.isEmpty {
        Section {
          ForEach(filteredThreads) { thread in
            NavigationLink {
              MobileExternalThreadDetailView(
                thread: thread,
                continueInOrg2: continueInOrg2
              )
            } label: {
              MobileExternalThreadRow(thread: thread)
            }
          }
        } footer: {
          Text("External tasks are read-only. Opening one never resumes or changes it.")
        }
      }
    }
    .overlay {
      if remote.externalThreads.isEmpty && !remote.isRefreshingExternalThreads {
        ContentUnavailableView(
          "No External Threads",
          systemImage: "rectangle.stack.badge.person.crop",
          description: Text("Recent native Codex tasks from your host will appear here.")
        )
      } else if filteredThreads.isEmpty && !query.isEmpty {
        ContentUnavailableView.search(text: query)
      }
    }
    .navigationTitle("External Threads")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        MobileSidebarToolbarButton()
      }
    }
    .searchable(text: $query, prompt: "Search external threads")
    .refreshable { await remote.refreshExternalThreads() }
    .task {
      if remote.externalThreads.isEmpty {
        await remote.refreshExternalThreads()
      }
    }
  }

  private var filteredThreads: [MobileExternalThreadSummary] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !term.isEmpty else { return remote.externalThreads }
    return remote.externalThreads.filter { thread in
      [thread.title, thread.preview, thread.workspacePath, thread.source]
        .compactMap { $0?.lowercased() }
        .contains { $0.contains(term) }
    }
  }
}

private struct MobileExternalThreadRow: View {
  let thread: MobileExternalThreadSummary

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: thread.harness.systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(.blue)
        .frame(width: 28, height: 28)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 4) {
        Text(thread.title)
          .font(.body.weight(.semibold))
          .lineLimit(2)
        if let preview = thread.preview, preview != thread.title {
          Text(preview)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        HStack(spacing: 5) {
          Text(thread.harness.title)
          Text("·")
          Text(thread.updatedAt, style: .relative)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 3)
  }
}

private struct MobileExternalThreadDetailView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  let thread: MobileExternalThreadSummary
  let continueInOrg2: (UUID) -> Void
  @State private var isContinuing = false

  var body: some View {
    Group {
      if remote.isLoadingExternalThread {
        VStack(spacing: 12) {
          ProgressView()
          Text("Loading the full read-only transcript…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let detail = remote.externalThreadDetail,
                detail.thread.id == thread.id {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
              HStack(spacing: 6) {
                Label(thread.harness.title, systemImage: thread.harness.systemImage)
                Text("READ ONLY")
                  .font(.caption2.weight(.bold))
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.secondary.opacity(0.12), in: Capsule())
              }
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              Text(thread.title)
                .font(.title2.weight(.bold))
              if let workspacePath = thread.workspacePath {
                Text(workspacePath)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)

            ForEach(detail.messages) { message in
              MobileExternalThreadMessageCard(message: message, harness: thread.harness)
            }
          }
          .padding(16)
        }
      } else {
        ContentUnavailableView(
          "Thread Unavailable",
          systemImage: "exclamationmark.bubble",
          description: Text("Pull to refresh the external thread list and try again.")
        )
      }
    }
    .navigationTitle(thread.title)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      Button {
        Task {
          isContinuing = true
          defer { isContinuing = false }
          if let threadID = await remote.continueExternalThread(thread) {
            continueInOrg2(threadID)
          }
        }
      } label: {
        HStack {
          if isContinuing { ProgressView().tint(.white) }
          Label("Fork into Celorga", systemImage: "arrow.triangle.branch")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(isContinuing || remote.isLoadingExternalThread)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.bar)
    }
    .task(id: thread.id) {
      await remote.loadExternalThread(thread)
    }
    .onDisappear {
      remote.clearExternalThreadDetail()
    }
  }
}

private struct MobileExternalThreadMessageCard: View {
  let message: MobileExternalThreadMessage
  let harness: MobileExternalThreadHarness

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Image(systemName: message.role == .user ? "person.fill" : harness.systemImage)
          .foregroundStyle(message.role == .user ? Color.blue : Color.secondary)
        Text(message.role == .user ? "You" : harness.title)
          .font(.caption.weight(.semibold))
        Spacer()
        Text(message.createdAt, style: .time)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
        ShareLink(item: message.content) {
          Image(systemName: "square.on.square")
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Copy or share message")
      }
      Text(MobileRemoteMessageMarkup.attributedString(for: message.content))
        .font(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(13)
    .background(
      message.role == .user ? Color.blue.opacity(0.08) : Color(uiColor: .secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    }
  }
}

private struct MobileRemotePairingView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @State private var isScannerPresented = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 10) {
          Image(systemName: "desktopcomputer")
            .font(.system(size: 48))
            .foregroundStyle(.blue)
          Text("Your workspace, always available")
            .font(.title2.weight(.semibold))
          Text("Connect to your Mac or an always-on Celorga server. The selected host runs your chats and provides their workspace context.")
            .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 12) {
          Label("On a Mac, open Settings → Mobile Remote. For a server, ask your agent for a pairing link.", systemImage: "1.circle.fill")
          Label("Turn it on and create a one-time pairing code.", systemImage: "2.circle.fill")
          Label("Scan the QR code below, or enter its details.", systemImage: "3.circle.fill")
        }
        .font(.callout)

        Button {
          isScannerPresented = true
        } label: {
          Label("Scan Pairing QR Code", systemImage: "qrcode.viewfinder")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable)

        VStack(alignment: .leading, spacing: 12) {
          TextField("http://100.x.y.z:48922", text: $remote.endpointDraft)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
          TextField("6-digit code", text: $remote.codeDraft)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .textFieldStyle(.roundedBorder)

          Button {
            Task { await remote.pair() }
          } label: {
            HStack {
              if remote.isPairing {
                ProgressView()
              }
              Text(remote.isPairing ? "Pairing…" : "Pair with Host")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .disabled(!remote.canChangeHost || remote.endpointDraft.isEmpty || remote.codeDraft.isEmpty)
        }

        Label(
          "Both devices must be signed into the same Tailscale network. The connection stays inside your tailnet, and the pairing credential is kept in Keychain.",
          systemImage: "lock.shield"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      .padding(24)
    }
    .sheet(isPresented: $isScannerPresented) {
      MobileRemoteScannerSheet { payload in
        if remote.applyPairingPayload(payload) {
          isScannerPresented = false
          Task { await remote.pair() }
        }
      }
    }
  }
}

private struct MobileRemoteThreadRow: View {
  let thread: MobileRemoteThreadSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 7) {
        if thread.isRunning {
          ProgressView()
            .controlSize(.mini)
        }
        if thread.isPinned {
          Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text(thread.title)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Spacer()
        Text(thread.isSharedRoom == true
          ? "Room"
          : (thread.destinationName ?? mobileAIRuntimeTitle(thread.runtime)))
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
      if let preview = thread.preview, !preview.isEmpty {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      HStack(spacing: 4) {
        Text(thread.updatedAt, style: .relative)
        if let host = thread.executionHostName, !host.isEmpty {
          Text("·")
          Text(thread.isRunning ? "running on \(host)" : "on \(host)")
            .lineLimit(1)
        }
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 3)
  }
}

private struct MobileAIMentionSuggestion: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let insertion: String

  static func all(destinations: [MobileRemoteAIDestination]) -> [MobileAIMentionSuggestion] {
    destinations.map { destination in
      MobileAIMentionSuggestion(
        id: destination.id,
        title: "@\(destination.mention)",
        systemImage: mobileAIRuntimeSystemImage(destination.runtime),
        insertion: "@\(destination.mention) "
      )
    } + [MobileAIMentionSuggestion(
      id: "all",
      title: "@all",
      systemImage: "person.2.fill",
      insertion: "@all "
    )]
  }

  static func suggestions(
    for text: String,
    destinations: [MobileRemoteAIDestination]
  ) -> [MobileAIMentionSuggestion] {
    guard let range = activeMentionRange(in: text) else { return [] }
    let query = String(text[range]).dropFirst().lowercased()
    return all(destinations: destinations).filter { suggestion in
      suggestion.id.hasPrefix(query)
        || suggestion.title.dropFirst().lowercased().hasPrefix(query)
    }
  }

  static func mentionedDestinationIDs(
    in text: String,
    destinations: [MobileRemoteAIDestination]
  ) -> Set<String> {
    let mentionByName = Dictionary(uniqueKeysWithValues: destinations.map {
      ($0.mention.lowercased(), $0.id)
    })
    let tokens = text.lowercased().split(whereSeparator: { character in
      !(character.isLetter || character.isNumber || character == "@"
        || character == "-" || character == "_")
    })
    var destinationIDs: Set<String> = []
    for token in tokens where token.first == "@" {
      let mention = String(token.dropFirst())
      if mention == "all" || mention == "both" {
        destinationIDs.formUnion(destinations.map(\.id))
      } else if let destinationID = mentionByName[mention] {
        destinationIDs.insert(destinationID)
      }
    }
    return destinationIDs
  }

  func completingMention(in text: String) -> String {
    guard let range = Self.activeMentionRange(in: text) else { return text }
    return text.replacingCharacters(in: range, with: insertion)
  }

  private static func activeMentionRange(in text: String) -> Range<String.Index>? {
    guard let atIndex = text.lastIndex(of: "@") else { return nil }
    if atIndex != text.startIndex {
      guard text[text.index(before: atIndex)].isWhitespace else { return nil }
    }
    let suffix = text[atIndex...]
    guard suffix.dropFirst().allSatisfy({
      $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
    }) else { return nil }
    return atIndex..<text.endIndex
  }
}

struct MobileRemoteThreadView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @Environment(\.colorScheme) private var colorScheme
  let threadID: UUID
  let openThread: (UUID) -> Void
  @StateObject private var voiceTranscriber = MobileVoiceTranscriber()
  @State private var draft = ""
  @State private var isSending = false
  @State private var optimisticMessage: MobileRemoteChatMessage?
  @State private var isStopping = false
  @State private var isFinishingDictation = false
  @State private var dictationPrefix = ""
  @State private var isPhotoPickerPresented = false
  @State private var isPreparingPhotos = false
  @State private var selectedPhotoItems: [PhotosPickerItem] = []
  @State private var attachments: [MobileRemoteAttachment] = []
  @State private var selectedFileCitation: MobileRemoteFileCitation?
  @State private var isNearChatBottom = true
  @State private var hasPresentedInitialContent = false
  @State private var pollingLeaseID: UUID?
  @State private var transcriptPageEndID: UUID?
  @State private var threadOutputs: MobileRemoteThreadOutputs?
  @State private var isShowingOutputs = false
  @State private var pendingScrollMessageID: UUID?

  var body: some View {
    Group {
      if let detail = remote.threadDetail, detail.thread.id == threadID {
        if hasPresentedInitialContent {
          chatContent(detail: detail)
        } else {
          loadingView(detailIsAvailable: true)
        }
      } else {
        if let message = remote.threadConnectionError {
          ContentUnavailableView(
            "Host Unavailable",
            systemImage: "wifi.exclamationmark",
            description: Text(message)
          )
        } else {
          loadingView(detailIsAvailable: false)
        }
      }
    }
    // Keep transcript presentation attached to the stable destination view.
    // A task attached to the temporary loading subtree can be cancelled while
    // a notification switches tabs or restores the navigation path, leaving
    // an already-loaded transcript behind a permanent spinner.
    .task(id: remote.threadDetail?.thread.id) {
      guard remote.threadDetail?.thread.id == threadID else {
        hasPresentedInitialContent = false
        return
      }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(40))
      guard !Task.isCancelled,
            remote.threadDetail?.thread.id == threadID
      else { return }
      hasPresentedInitialContent = true
    }
    .navigationTitle(remote.threadDetail?.thread.id == threadID ? remote.threadDetail?.thread.title ?? "Chat" : "Chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        MobileSidebarToolbarButton()
      }
      if let outputs = threadOutputs, outputs.threadID == threadID, !outputs.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          MobileRemoteThreadOutputsChip(outputs: outputs) {
            isShowingOutputs = true
          }
        }
      }
      if let thread = remote.threadDetail?.thread, thread.id == threadID {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button {
              Task {
                if let forkedThreadID = await remote.forkThread(threadID) {
                  openThread(forkedThreadID)
                }
              }
            } label: {
              Label("Fork Thread", systemImage: "arrow.triangle.branch")
            }
            Button {
              Task { await remote.setPinned(!thread.isPinned, threadID: threadID) }
            } label: {
              Label(
                thread.isPinned ? "Unpin Thread" : "Pin Thread",
                systemImage: thread.isPinned ? "pin.slash" : "pin"
              )
            }
            Button {
              Task { await remote.setSettled(!thread.isSettled, threadID: threadID) }
            } label: {
              Label(
                thread.isSettled ? "Reopen Thread" : "Settle Thread",
                systemImage: thread.isSettled ? "arrow.uturn.backward.circle" : "checkmark.circle"
              )
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .disabled(remote.mutatingThreadIDs.contains(threadID))
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if hasPresentedInitialContent,
         remote.threadDetail?.thread.id == threadID {
        composer
      }
    }
    // A MobileRemoteThreadView can be reused when its parent changes only the
    // selected thread ID. Key the polling startup to that ID instead of relying
    // on onAppear, which does not run again for an in-place destination swap.
    .task(id: threadID) {
      hasPresentedInitialContent = false
      pollingLeaseID = remote.beginPolling(threadID: threadID)
    }
    .onDisappear {
      voiceTranscriber.cancel()
      hasPresentedInitialContent = false
      if let pollingLeaseID {
        remote.endPolling(threadID: threadID, leaseID: pollingLeaseID)
      }
      pollingLeaseID = nil
    }
    .onChange(of: transcriptPageEndID) { _, _ in
      isNearChatBottom = transcriptPageEndID == nil
    }
    .onChange(of: voiceTranscriber.transcript) { _, transcript in
      draft = Self.appendingDictation(transcript, to: dictationPrefix)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
      // Preserve the draft, but release microphone capture and the screen-awake
      // hold when the user deliberately leaves the app or locks the phone.
      voiceTranscriber.stop()
    }
    .photosPicker(
      isPresented: $isPhotoPickerPresented,
      selection: $selectedPhotoItems,
      maxSelectionCount: max(1, 4 - attachments.count),
      matching: .images,
      preferredItemEncoding: .compatible
    )
    .onChange(of: selectedPhotoItems) { _, items in
      guard !items.isEmpty else { return }
      loadPhotos(items)
    }
    .alert("Voice Transcription", isPresented: Binding(
      get: { voiceTranscriber.errorMessage != nil },
      set: { if !$0 { voiceTranscriber.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(voiceTranscriber.errorMessage ?? "")
    }
    .sheet(item: $selectedFileCitation) { citation in
      MobileRemoteFilePreviewSheet(citation: citation)
        .environmentObject(remote)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $isShowingOutputs) {
      if let outputs = threadOutputs {
        MobileRemoteThreadOutputsSheet(outputs: outputs) { messageID in
          isShowingOutputs = false
          revealMessage(messageID)
        }
        .environmentObject(remote)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
      }
    }
    // Outputs are derived on the host from the stored transcript. Refresh when
    // a reply lands or the turn ends, not on every streamed token.
    .task(id: outputsSignature) {
      await refreshThreadOutputs()
    }
  }

  private struct OutputsSignature: Hashable {
    let threadID: UUID
    let isLoaded: Bool
    let messageCount: Int
    let lastMessageID: UUID?
    let isRunning: Bool
    let supportsOutputs: Bool
  }

  private var outputsSignature: OutputsSignature {
    let detail = remote.threadDetail?.thread.id == threadID ? remote.threadDetail : nil
    return OutputsSignature(
      threadID: threadID,
      isLoaded: detail != nil,
      messageCount: detail?.messages.count ?? 0,
      lastMessageID: detail?.messages.last?.id,
      isRunning: detail?.thread.isRunning ?? false,
      supportsOutputs: remote.status?.supportsThreadOutputs == true
    )
  }

  private func refreshThreadOutputs() async {
    if threadOutputs?.threadID != threadID { threadOutputs = nil }
    guard outputsSignature.isLoaded, outputsSignature.supportsOutputs else { return }
    try? await Task.sleep(for: .milliseconds(400))
    guard !Task.isCancelled else { return }
    // Keep the last known outputs when the host is briefly unreachable.
    guard let outputs = try? await remote.threadOutputs(threadID: threadID),
          !Task.isCancelled,
          outputs.threadID == threadID
    else { return }
    threadOutputs = outputs
  }

  /// Pages the transcript so the reply is loaded, then scrolls to it.
  private func revealMessage(_ messageID: UUID) {
    guard let messages = remote.threadDetail?.messages.filter({ $0.isRoomDispatchCopy != true }),
          let reveal = MobileRemoteTranscriptPage.reveal(messageID, in: messages)
    else { return }
    switch reveal {
    case .latest: transcriptPageEndID = nil
    case .endingAt(let endID): transcriptPageEndID = endID
    }
    pendingScrollMessageID = messageID
  }

  private func chatContent(detail: MobileRemoteThreadDetail) -> some View {
    ScrollViewReader { proxy in
      Group {
        if #available(iOS 18.0, *) {
          chatScrollView(detail: detail)
            .onScrollGeometryChange(for: Bool.self) { geometry in
              geometry.contentSize.height <= geometry.containerSize.height
                || geometry.visibleRect.maxY >= geometry.contentSize.height - 28
            } action: { _, nextValue in
              if isNearChatBottom != nextValue {
                isNearChatBottom = nextValue
              }
            }
        } else {
          chatScrollView(detail: detail)
        }
      }
      .onChange(of: transcriptPageEndID) { _, endID in
        if endID == nil { scrollToBottom(proxy: proxy, animated: false) }
      }
      .onChange(of: detail.messages.count) { _, _ in
        scrollToBottomIfFollowing(proxy: proxy)
      }
      .onChange(of: pendingScrollMessageID) { _, messageID in
        guard let messageID else { return }
        Task { @MainActor in
          // Let the revealed page lay out before scrolling to the reply.
          try? await Task.sleep(for: .milliseconds(350))
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(messageID, anchor: .top)
          }
          pendingScrollMessageID = nil
        }
      }
      .onChange(of: detail.streamingReply) { _, _ in
        scrollToBottomIfFollowing(proxy: proxy)
      }
      .onChange(of: detail.reasoning) { _, _ in
        scrollToBottomIfFollowing(proxy: proxy)
      }
      .onChange(of: detail.activities.count) { _, _ in
        scrollToBottomIfFollowing(proxy: proxy)
      }
      .onChange(of: isSending) { _, sending in
        if sending {
          scrollToBottom(proxy: proxy, animated: false)
        } else {
          scrollToBottomIfFollowing(proxy: proxy)
        }
      }
      .onAppear {
        isNearChatBottom = true
        scrollToBottom(proxy: proxy, animated: false)
      }
      .overlay(alignment: .bottomTrailing) {
        if !isNearChatBottom {
          Button {
            transcriptPageEndID = nil
            scrollToBottom(proxy: proxy, animated: true)
          } label: {
            Image(systemName: "arrow.down")
              .font(.system(size: 14, weight: .semibold))
              .frame(width: 36, height: 36)
              .background(.regularMaterial, in: Circle())
              .overlay {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)
              }
              .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
          }
          .buttonStyle(.plain)
          .padding(.trailing, 14)
          .padding(.bottom, 12)
          .accessibilityLabel("Jump to latest message")
          .transition(.scale.combined(with: .opacity))
        }
      }
      .animation(.easeInOut(duration: 0.16), value: isNearChatBottom)
    }
  }

  private func loadingView(detailIsAvailable: Bool) -> some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
      Text(detailIsAvailable ? "Preparing conversation…" : "Loading chat…")
        .font(.headline)
      if let title = remote.threads.first(where: { $0.id == threadID })?.title {
        Text(title)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemGroupedBackground))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(detailIsAvailable ? "Preparing conversation" : "Loading chat")
  }

  private func chatScrollView(detail: MobileRemoteThreadDetail) -> some View {
    let messages = detail.messages.filter { $0.isRoomDispatchCopy != true }
    let page = MobileRemoteTranscriptPage.make(messages: messages, endingAt: transcriptPageEndID)
    return ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        // Transcript rows change height when an optimistic send is replaced,
        // streaming content arrives, and activity sections expand. Lazy stack
        // estimates can survive those changes and create phantom space below
        // the final row. Keep exact geometry for a bounded page, never the
        // entire history: large eager transcripts can exhaust the iOS watchdog.
        VStack(alignment: .leading, spacing: 12) {
          if let connectionError = remote.threadConnectionError {
            Label(connectionError, systemImage: "wifi.exclamationmark")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
          }

          if page.lowerBound > 0 {
            Button("Earlier messages") {
              transcriptPageEndID = messages[page.lowerBound - 1].id
            }
            .buttonStyle(.bordered)
          }
          if transcriptPageEndID != nil {
            Button("Back to latest messages") {
              transcriptPageEndID = nil
              isNearChatBottom = true
            }
            .buttonStyle(.bordered)
          }

          ForEach(messages[page]) { message in
            MobileRemoteMessageBubble(message: message) { citation in
              selectedFileCitation = citation
            }
              .id(message.id)
          }

          if transcriptPageEndID == nil, let optimisticMessage,
             !detailContainsAcknowledgement(of: optimisticMessage, detail: detail) {
            MobileRemoteMessageBubble(message: optimisticMessage) { citation in
              selectedFileCitation = citation
            }
            .id(optimisticMessage.id)
          }

          if transcriptPageEndID == nil && (isSending || detail.thread.isRunning || !detail.streamingReply.isEmpty) {
            MobileRemoteInProgressBubble(
              detail: detail,
              isStarting: isSending
            )
            .id("in-progress")
          }

          if transcriptPageEndID == nil && !detail.reasoning.isEmpty {
            DisclosureGroup("Reasoning") {
              MobileRemoteBoundedMessageText(content: detail.reasoning)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
          }

          if transcriptPageEndID == nil && !detail.activities.isEmpty {
            MobileRemoteActivityView(activities: detail.activities)
          }
          if page.upperBound < messages.count {
            Button("Newer messages") {
              let next = MobileRemoteTranscriptPage.newerPage(messages: messages, after: page.upperBound)
              transcriptPageEndID = next.upperBound == messages.count ? nil : messages[next.upperBound - 1].id
            }
            .buttonStyle(.bordered)
          }
        }

        Color.clear
          .frame(height: 1)
          .id(bottomAnchorID)
          .accessibilityHidden(true)
      }
      .padding()
    }
  }

  private var composer: some View {
    VStack(spacing: 9) {
      if !mentionSuggestions.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 7) {
            ForEach(mentionSuggestions) { suggestion in
              Button {
                draft = suggestion.completingMention(in: draft)
              } label: {
                Label(suggestion.title, systemImage: suggestion.systemImage)
                  .font(.caption.weight(.semibold))
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .background(Color(.tertiarySystemFill), in: Capsule())
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 1)
        }
      }

      if mentionForksIntoSharedRoom {
        Label("Sends in a new shared room", systemImage: "arrow.triangle.branch")
          .font(.caption.weight(.medium))
          .foregroundStyle(Color.accentColor)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !attachments.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(attachments) { attachment in
              MobileRemotePhotoThumbnail(attachment: attachment) {
                attachments.removeAll { $0.id == attachment.id }
              }
            }
          }
          .padding(.horizontal, 2)
        }
      }

      if isPreparingPhotos {
        HStack(spacing: 7) {
          ProgressView()
            .controlSize(.small)
          Text("Preparing selected photos…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack(alignment: .bottom, spacing: 7) {
        composerActionsMenu

        TextField("Talk to \(agentTitle)", text: $draft, axis: .vertical)
          .lineLimit(1...6)
          .textFieldStyle(.plain)
          .padding(.vertical, 6)
          .frame(minHeight: 32)
          .disabled(isSettled)

        Button {
          if voiceTranscriber.isRecording {
            voiceTranscriber.stop()
          } else {
            dictationPrefix = draft
            Task { await voiceTranscriber.start() }
          }
        } label: {
          Image(systemName: voiceTranscriber.isRecording ? "stop.fill" : "mic.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(voiceTranscriber.isRecording ? .white : .secondary)
            .frame(width: 30, height: 30)
            .background(
              voiceTranscriber.isRecording ? Color.accentColor : Color.clear,
              in: Circle()
            )
        }
        .buttonStyle(.plain)
        .disabled(isSettled || isSending || isFinishingDictation)
        .accessibilityLabel(voiceTranscriber.isRecording ? "Stop transcription" : "Transcribe voice")
        .accessibilityHint(
          voiceTranscriber.isRecording
            ? "Places the transcript in the message field without sending"
            : "Starts voice transcription"
        )

        Button {
          if voiceTranscriber.isRecording {
            finishDictationAndSend(delivery: isRunning ? "steer" : nil)
          } else {
            sendMessage(delivery: isRunning ? "steer" : nil)
          }
        } label: {
          if isSending || isFinishingDictation {
            ProgressView()
              .frame(width: 30, height: 30)
          } else {
            Image(
              systemName: voiceTranscriber.isRecording
                ? "arrow.up.circle.fill"
                : isRunning ? "arrow.turn.up.right" : "arrow.up.circle.fill"
            )
              .font(
                .system(
                  size: voiceTranscriber.isRecording || !isRunning ? 30 : 15,
                  weight: .semibold
                )
              )
              .foregroundStyle(
                voiceTranscriber.isRecording || !isRunning ? Color.accentColor : Color.white
              )
              .frame(width: 30, height: 30)
              .background(
                isRunning && !voiceTranscriber.isRecording ? Color.accentColor : Color.clear,
                in: Circle()
              )
          }
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(
          voiceTranscriber.isRecording
            ? "Finish transcription and send"
            : isRunning ? "Steer active response" : "Send message"
        )
        .contextMenu {
          if isRunning && !voiceTranscriber.isRecording {
            Button {
              sendMessage(delivery: "followUp")
            } label: {
              Label("Queue as Follow-up", systemImage: "clock")
            }
            .disabled(!canSend)
          }
        }

        if isRunning || isStopping {
          Button {
            isStopping = true
            Task {
              await remote.stop(threadID: threadID)
              isStopping = false
            }
          } label: {
            if isStopping {
              ProgressView()
                .frame(width: 30, height: 30)
            } else {
              Image(systemName: "stop.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: Circle())
            }
          }
          .buttonStyle(.plain)
          .disabled(isStopping)
          .accessibilityLabel("Stop response")
        }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
      .background(
        Color(.secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(
            Color.primary.opacity(colorScheme == .light ? 0.11 : 0.09),
            lineWidth: 1
          )
      }
      .shadow(
        color: Color.black.opacity(colorScheme == .light ? 0.055 : 0.025),
        radius: 4,
        x: 0,
        y: 2
      )
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }

  private var composerActionsMenu: some View {
    Menu {
      Button {
        isPhotoPickerPresented = true
      } label: {
        Label("Add Photos", systemImage: "photo.on.rectangle")
      }
      .disabled(isSettled || isSending || isPreparingPhotos || attachments.count >= 4)

      Divider()

      Menu {
        modelMenuItems
      } label: {
        Label("Model · \(modelLabel)", systemImage: "cpu")
      }
      .disabled(
        isSettled || isRunning || isSending ||
        remote.threadDetail?.thread.isSharedRoom == true ||
        remote.isRefreshingConfiguration || remote.isUpdatingConfiguration ||
        remote.threadConfiguration == nil
      )

      Menu {
        reasoningMenuItems
      } label: {
        Label("Reasoning · \(reasoningLabel)", systemImage: "brain")
      }
      .disabled(
        isSettled || isRunning || isSending ||
        remote.threadDetail?.thread.isSharedRoom == true ||
        remote.isRefreshingConfiguration || remote.isUpdatingConfiguration ||
        !hasReasoningChoices
      )
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 30)
        .background(Color(.tertiarySystemFill), in: Circle())
    }
    .disabled(isSettled || isSending || isPreparingPhotos)
    .accessibilityLabel("Chat options, model \(modelLabel), reasoning \(reasoningLabel)")
  }

  @ViewBuilder
  private var modelMenuItems: some View {
    Button {
      Task { await remote.setModel(nil, threadID: threadID) }
    } label: {
      HStack {
        Text("Default model")
        if remote.threadConfiguration?.model == nil {
          Image(systemName: "checkmark")
        }
      }
    }

    if remote.isRefreshingConfiguration {
      Divider()
      Text("Loading models…")
    } else if let configuration = remote.threadConfiguration,
              !configuration.models.isEmpty {
      Divider()
      ForEach(configuration.models) { model in
        Button {
          Task { await remote.setModel(model.id, threadID: threadID) }
        } label: {
          HStack {
            Text(model.label)
            if configuration.model == model.id {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } else {
      Divider()
      Text("Models unavailable")
    }
  }

  @ViewBuilder
  private var reasoningMenuItems: some View {
    Button {
      Task { await remote.setReasoningEffort(nil, threadID: threadID) }
    } label: {
      HStack {
        Text(defaultReasoningLabel)
        if remote.threadConfiguration?.reasoningEffort == nil {
          Image(systemName: "checkmark")
        }
      }
    }

    if let configuration = remote.threadConfiguration,
       !configuration.reasoningOptions.isEmpty {
      Divider()
      ForEach(configuration.reasoningOptions) { option in
        Button {
          Task { await remote.setReasoningEffort(option.id, threadID: threadID) }
        } label: {
          HStack {
            Text(option.label)
            if configuration.reasoningEffort == option.id {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } else {
      Divider()
      Text("No reasoning levels reported")
    }
  }

  private var modelLabel: String {
    guard let configuration = remote.threadConfiguration else {
      return remote.configurationError == nil ? "Model" : "Model unavailable"
    }
    if let model = configuration.model {
      return configuration.models.first(where: { $0.id == model })?.label ?? model
    }
    return configuration.models.first(where: \.isDefault)?.label ?? "Default"
  }

  private var hasReasoningChoices: Bool {
    guard let configuration = remote.threadConfiguration else { return false }
    return !configuration.reasoningOptions.isEmpty || configuration.reasoningEffort != nil
  }

  private var reasoningLabel: String {
    guard let configuration = remote.threadConfiguration else { return "Reasoning" }
    let effort = configuration.reasoningEffort ?? configuration.defaultReasoningEffort
    guard let effort else { return "Reasoning" }
    return configuration.reasoningOptions.first(where: { $0.id == effort })?.label
      ?? effort.capitalized
  }

  private var defaultReasoningLabel: String {
    guard let configuration = remote.threadConfiguration,
          let effort = configuration.defaultReasoningEffort
    else {
      return "Default reasoning"
    }
    let label = configuration.reasoningOptions.first(where: { $0.id == effort })?.label
      ?? effort.capitalized
    return "Default reasoning (\(label))"
  }

  private var agentTitle: String {
    guard remote.threadDetail?.thread.isSharedRoom != true else { return "an agent" }
    if let destinationName = remote.threadDetail?.thread.destinationName {
      return destinationName
    }
    return mobileAIRuntimeTitle(remote.threadDetail?.thread.runtime ?? "openClaw")
  }

  private var aiChatDestinations: [MobileRemoteAIDestination] {
    if let destinations = remote.status?.aiChatDestinations, !destinations.isEmpty {
      return destinations
    }
    return [
      MobileRemoteAIDestination(
        id: "builtin.codex",
        name: "Codex",
        mention: "codex",
        runtime: "codex"
      ),
      MobileRemoteAIDestination(
        id: "builtin.openclaw",
        name: "OpenClaw",
        mention: "openclaw",
        runtime: "openClaw"
      )
    ]
  }

  private var mentionSuggestions: [MobileAIMentionSuggestion] {
    MobileAIMentionSuggestion.suggestions(for: draft, destinations: aiChatDestinations)
  }

  private var mentionForksIntoSharedRoom: Bool {
    guard let thread = remote.threadDetail?.thread,
          thread.id == threadID,
          thread.isSharedRoom != true
    else { return false }
    let mentions = MobileAIMentionSuggestion.mentionedDestinationIDs(
      in: draft,
      destinations: aiChatDestinations
    )
    let currentDestinationID = thread.destinationID
      ?? aiChatDestinations.first(where: { $0.runtime == thread.runtime })?.id
    return mentions.contains(where: { $0 != currentDestinationID })
  }

  private var isRunning: Bool {
    remote.threadDetail?.thread.id == threadID && remote.threadDetail?.thread.isRunning == true
  }

  private var isSettled: Bool {
    remote.threadDetail?.thread.id == threadID && remote.threadDetail?.thread.isSettled == true
  }

  private var canSend: Bool {
    !isSending && !isFinishingDictation && !isPreparingPhotos && !isSettled && (
      voiceTranscriber.isRecording
        ||
      !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    )
  }

  private func finishDictationAndSend(delivery: String?) {
    guard voiceTranscriber.isRecording, !isFinishingDictation else { return }
    isFinishingDictation = true
    Task {
      let transcript = await voiceTranscriber.finish()
      draft = Self.appendingDictation(transcript, to: dictationPrefix)
      isFinishingDictation = false
      guard canSend else { return }
      sendMessage(delivery: delivery)
    }
  }

  private func sendMessage(delivery: String? = nil) {
    let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let sentAttachments = attachments
    if voiceTranscriber.isRecording {
      voiceTranscriber.stop()
    }
    voiceTranscriber.cancel()
    let pendingMessage = MobileRemoteChatMessage(
      id: UUID(),
      role: "user",
      content: message,
      attachmentNames: sentAttachments.map(\.fileName),
      createdAt: Date(),
      deliveryStatus: "sending",
      deliveryKind: delivery,
      sendFailure: nil,
      authorRuntime: nil,
      authorDestinationID: nil,
      authorDestinationName: nil,
      audience: nil,
      audienceDestinationNames: nil,
      isRoomDispatchCopy: false,
      roomRoundID: nil
    )

    transcriptPageEndID = nil
    isNearChatBottom = true
    // Make send feel local even when the selected host is slow to acknowledge it.
    // The field remains focused, so the next message can be typed immediately.
    draft = ""
    dictationPrefix = ""
    attachments = []
    selectedPhotoItems = []
    optimisticMessage = pendingMessage
    isSending = true
    Task {
      if let destinationThreadID = await remote.send(
        message,
        attachments: sentAttachments,
        threadID: threadID,
        delivery: delivery
      ) {
        optimisticMessage = nil
        if destinationThreadID != threadID {
          openThread(destinationThreadID)
        }
      } else {
        optimisticMessage = nil
        draft = Self.restoringFailedSend(message, before: draft)
        attachments = Self.restoringFailedAttachments(sentAttachments, before: attachments)
      }
      isSending = false
    }
  }

  private func detailContainsAcknowledgement(
    of optimistic: MobileRemoteChatMessage,
    detail: MobileRemoteThreadDetail
  ) -> Bool {
    detail.messages.contains { message in
      message.role == "user"
        && message.content == optimistic.content
        && message.attachmentNames == optimistic.attachmentNames
        && abs(message.createdAt.timeIntervalSince(optimistic.createdAt)) < 30
    }
  }

  private static func restoringFailedSend(_ failed: String, before current: String) -> String {
    guard !failed.isEmpty else { return current }
    let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
    return current.isEmpty ? failed : "\(failed)\n\n\(current)"
  }

  private static func restoringFailedAttachments(
    _ failed: [MobileRemoteAttachment],
    before current: [MobileRemoteAttachment]
  ) -> [MobileRemoteAttachment] {
    failed + current.filter { attachment in
      !failed.contains { $0.fileName == attachment.fileName && $0.data == attachment.data }
    }
  }

  private func loadPhotos(_ items: [PhotosPickerItem]) {
    guard !isPreparingPhotos else { return }
    isPreparingPhotos = true
    Task {
      defer {
        selectedPhotoItems = []
        isPreparingPhotos = false
      }
      do {
        var next = attachments
        let initialCount = next.count
        for (index, item) in items.prefix(4 - next.count).enumerated() {
          guard let data = try await item.loadTransferable(type: Data.self) else {
            throw MobileRemotePhotoError.unreadable
          }
          let attachment = try MobileRemotePhotoPreparation.attachment(
            from: data,
            sequence: initialCount + index + 1
          )
          if !next.contains(where: { $0.data == attachment.data }) {
            guard next.reduce(attachment.data.count, { $0 + $1.data.count }) <= 7_500_000 else {
              throw MobileRemotePhotoError.totalTooLarge
            }
            next.append(attachment)
          }
        }
        attachments = Array(next.prefix(4))
      } catch {
        remote.errorMessage = error.localizedDescription
      }
    }
  }

  private static func appendingDictation(_ transcript: String, to prefix: String) -> String {
    let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if prefix.isEmpty { return transcript }
    if transcript.isEmpty { return prefix }
    return "\(prefix) \(transcript)"
  }

  private var bottomAnchorID: String {
    "mobile-remote-thread-bottom-\(threadID.uuidString)"
  }

  private func scrollToBottomIfFollowing(proxy: ScrollViewProxy) {
    guard isNearChatBottom, transcriptPageEndID == nil else { return }
    scrollToBottom(proxy: proxy, animated: false)
  }

  private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
    let target = bottomAnchorID
    Task { @MainActor in
      await Task.yield()
      if animated {
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(target, anchor: .bottom)
        }
      } else {
        proxy.scrollTo(target, anchor: .bottom)
      }
    }
  }
}

// The transcript only lays out a bounded preview; Copy still uses the complete
// original message. The full-message sheet keeps UITextView's tiling for plain
// long text, and switches to native blocks when an Org table needs layout.
private struct MobileRemoteBoundedMessageText: View {
  let content: String
  @State private var isFullTextPresented = false

  var body: some View {
    let preview = MobileRemoteTranscriptPage.preview(content)
    VStack(alignment: .leading, spacing: 8) {
      MobileRemoteRenderedMessageText(content: preview.text)
      if preview.isTruncated {
        Button("Read full message") { isFullTextPresented = true }
          .font(.callout.weight(.medium))
      }
    }
    .sheet(isPresented: $isFullTextPresented) {
      NavigationStack {
        MobileRemoteFullMessageTextView(content: content)
          .navigationTitle("Full Message")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { isFullTextPresented = false }
            }
            ToolbarItem(placement: .topBarLeading) {
              Button("Copy") { UIPasteboard.general.string = content }
            }
          }
      }
      .tint(Color.accentColor)
      .foregroundStyle(Color.primary)
    }
  }
}

private struct MobileRemoteFullMessageTextView: View {
  let content: String

  var body: some View {
    if containsTable {
      ScrollView {
        MobileRemoteRenderedMessageText(content: content)
          .padding(.horizontal, 12)
          .padding(.vertical, 16)
      }
    } else {
      MobileRemoteFullPlainMessageTextView(content: content)
    }
  }

  private var containsTable: Bool {
    MobileRemoteMessageMarkup.renderedBlocks(for: content).contains {
      switch $0 {
      case .table, .image: return true
      case .text: return false
      }
    }
  }
}

private struct MobileRemoteFullPlainMessageTextView: UIViewRepresentable {
  let content: String

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView(usingTextLayoutManager: true)
    view.isEditable = false
    view.isSelectable = true
    view.isScrollEnabled = true
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    if view.text != content { view.text = content }
  }
}

private struct MobileRemoteMessageBubble: View {
  @Environment(\.colorScheme) private var colorScheme
  let message: MobileRemoteChatMessage
  let openFileCitation: (MobileRemoteFileCitation) -> Void
  @State private var didCopy = false

  var body: some View {
    let presentation = MobileRemotePromptPresentation(
      message.content,
      extractsContexts: message.role == "user"
    )
    HStack {
      if message.role == "user" { Spacer(minLength: 44) }
      VStack(alignment: .leading, spacing: 5) {
        if let roleLabel {
          Text(roleLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(
              message.role == "user" ? Color.white.opacity(0.78) : Color.secondary
            )
        }
        if let provenance = message.provenanceCaption, !provenance.isEmpty {
          // Which device sent it, which host received it, and where it ran.
          Text(provenance)
            .font(.caption2)
            .lineLimit(2)
            .foregroundStyle(
              message.role == "user" ? Color.white.opacity(0.66) : Color.secondary.opacity(0.8)
            )
        }
        if message.role == "user",
           message.deliveryKind == "steer",
           message.deliveryStatus == "sending" {
          Label("Steering…", systemImage: "arrow.turn.up.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.82))
        } else if message.role == "user",
                  message.deliveryKind == "followUp",
                  message.deliveryStatus == "sending" {
          Label("Queued", systemImage: "clock")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.82))
        }
        if !presentation.contexts.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(presentation.contexts) { context in
                Button {
                  if let citation = context.fileCitation {
                    openFileCitation(citation)
                  }
                } label: {
                  Label(context.title, systemImage: context.isAutomatic ? "sparkles" : "scope")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                      message.role == "user"
                        ? Color.white.opacity(0.14)
                        : Color.accentColor.opacity(0.10),
                      in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(context.fileCitation == nil)
              }
            }
          }
          .fixedSize(horizontal: false, vertical: true)
        }
        if !presentation.userText.isEmpty {
          MobileRemoteBoundedMessageText(content: presentation.userText)
        }
        if !message.attachmentNames.isEmpty {
          Label(message.attachmentNames.joined(separator: ", "), systemImage: "paperclip")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let sendFailure = message.sendFailure {
          Text(sendFailure)
            .font(.caption)
            .foregroundStyle(.red)
        }
        Text(message.createdAt, style: .time)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(
            message.role == "user" ? Color.white.opacity(0.70) : Color.secondary
          )
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .padding(.trailing, 22)
      .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
      .tint(message.role == "user" ? Color.white : Color.accentColor)
      .background(
        message.role == "user" ? Color.blue : Color(.secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 15)
      )
      .overlay {
        if message.role != "user" {
          RoundedRectangle(cornerRadius: 15)
            .stroke(responseBorderColor, lineWidth: 1)
        }
      }
      .overlay(alignment: .topTrailing) {
        Button {
          UIPasteboard.general.string = clipboardText
          didCopy = true
        } label: {
          Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            .font(.caption2.weight(.semibold))
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(message.role == "user" ? Color.white.opacity(0.82) : Color.secondary)
        .accessibilityLabel(didCopy ? "Message copied" : "Copy message")
      }
      .contextMenu {
        Button {
          UIPasteboard.general.string = clipboardText
          didCopy = true
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
      }
      .sensoryFeedback(.success, trigger: didCopy)
      .environment(\.openURL, OpenURLAction { url in
        guard let citation = MobileRemoteMessageMarkup.fileCitation(from: url) else {
          return .systemAction
        }
        openFileCitation(citation)
        return .handled
      })
      if message.role != "user" { Spacer(minLength: 44) }
    }
  }

  private var clipboardText: String {
    let attachmentText = message.attachmentNames.map { "[Attachment: \($0)]" }
    let content = MobileRemotePromptPresentation(
      message.content,
      extractsContexts: message.role == "user"
    ).clipboardText
    return ([content].filter { !$0.isEmpty } + attachmentText).joined(separator: "\n")
  }

  private var roleLabel: String? {
    if message.role == "user" {
      if let names = message.audienceDestinationNames, !names.isEmpty {
        return "You → \(names.joined(separator: ", "))"
      }
      guard let audience = message.audience else { return nil }
      let target: String
      switch audience {
      case "codex": target = "Codex"
      case "claude": target = "Claude Code"
      case "openClaw": target = "OpenClaw"
      case "everyone": target = "All agents"
      default: return nil
      }
      return "You → \(target)"
    }
    if let destinationName = message.authorDestinationName {
      return destinationName
    }
    guard let runtime = message.authorRuntime else { return nil }
    return mobileAIRuntimeTitle(runtime)
  }

  private var responseBorderColor: Color {
    Color.primary.opacity(colorScheme == .light ? 0.14 : 0.10)
  }
}

private struct MobileRemotePromptContext: Identifiable, Hashable {
  private static let fileReferencePattern = try! NSRegularExpression(
    pattern: #"^(.+\.(?:org2|org))(?::([1-9][0-9]*)(?:-[1-9][0-9]*)?)?$"#,
    options: [.caseInsensitive]
  )

  let kind: String
  let title: String
  let reference: String
  let isAutomatic: Bool

  var id: String { "\(kind)|\(reference)|\(title)" }

  var fileCitation: MobileRemoteFileCitation? {
    let range = NSRange(reference.startIndex..<reference.endIndex, in: reference)
    guard let match = Self.fileReferencePattern.firstMatch(in: reference, range: range),
          let pathRange = Range(match.range(at: 1), in: reference)
    else { return nil }
    let line: Int?
    if match.range(at: 2).location != NSNotFound,
       let lineRange = Range(match.range(at: 2), in: reference) {
      line = Int(reference[lineRange])
    } else {
      line = nil
    }
    return MobileRemoteFileCitation(
      path: String(reference[pathRange]),
      line: line,
      label: title
    )
  }
}

private struct MobileRemotePromptPresentation {
  private static let automaticBegin = "#+begin_org2_ai_context"
  private static let automaticEnd = "#+end_org2_ai_context"

  let contexts: [MobileRemotePromptContext]
  let userText: String

  init(_ rawText: String, extractsContexts: Bool) {
    guard extractsContexts else {
      contexts = []
      userText = rawText
      return
    }
    var remaining = rawText.replacingOccurrences(of: "\r\n", with: "\n")
    var parsed: [MobileRemotePromptContext] = []
    while let consumed = Self.consumeContext(from: remaining) {
      parsed.append(consumed.context)
      remaining = consumed.rest
    }
    contexts = parsed
    userText = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var clipboardText: String {
    (contexts.map { "[Context: \($0.title)]" } + (userText.isEmpty ? [] : [userText]))
      .joined(separator: "\n")
  }

  private static func consumeContext(
    from source: String
  ) -> (context: MobileRemotePromptContext, rest: String)? {
    let firstNewline = source.firstIndex(of: "\n")
    let header = firstNewline.map { String(source[..<$0]) } ?? source
    guard let headerContext = parseHeader(header) else { return nil }
    var sourceEnd = firstNewline ?? source.endIndex
    var isAutomatic = false

    if let firstNewline {
      let prefix = "\n\(automaticBegin)\n"
      if source[firstNewline...].hasPrefix(prefix) {
        let promptStart = source.index(firstNewline, offsetBy: prefix.count)
        guard let endRange = source.range(
          of: "\n\(automaticEnd)",
          range: promptStart..<source.endIndex
        ) else { return nil }
        sourceEnd = endRange.upperBound
        isAutomatic = true
      } else if let separator = source.range(of: "\n\n") {
        sourceEnd = separator.lowerBound
      }
    }

    var restStart = sourceEnd
    var removedNewlines = 0
    while restStart < source.endIndex,
          source[restStart] == "\n",
          removedNewlines < 2 {
      restStart = source.index(after: restStart)
      removedNewlines += 1
    }
    return (
      MobileRemotePromptContext(
        kind: headerContext.kind,
        title: headerContext.title,
        reference: headerContext.reference,
        isAutomatic: isAutomatic
      ),
      String(source[restStart...])
    )
  }

  private static func parseHeader(
    _ line: String
  ) -> (kind: String, title: String, reference: String)? {
    guard line.hasPrefix("Use "), line.hasSuffix(" as context.") else { return nil }
    let body = String(line.dropFirst(4).dropLast(" as context.".count))
    if let quoteStart = body.range(of: " “"),
       let separator = body.range(of: "” at ", range: quoteStart.upperBound..<body.endIndex) {
      return (
        String(body[..<quoteStart.lowerBound]),
        String(body[quoteStart.upperBound..<separator.lowerBound]),
        String(body[separator.upperBound...])
      )
    }
    guard let separator = body.range(of: " at ") else { return nil }
    let kind = String(body[..<separator.lowerBound])
    return (
      kind,
      kind
        .replacingOccurrences(of: "selected ", with: "", options: [.caseInsensitive, .anchored])
        .capitalized,
      String(body[separator.upperBound...])
    )
  }
}

private struct MobileRemoteFileCitation: Identifiable, Hashable {
  let path: String
  let line: Int?
  let label: String

  var target: String? = nil
  var sourcePath: String? = nil
  var documentLink: MobileDocumentLink? { target.flatMap { MobileDocumentLink.parse($0, relativeTo: sourcePath) } }
  var id: String { "\(path)#\(line ?? 0)|\(target ?? "")|\(sourcePath ?? "")" }
}

struct CorpusFileBrowserView: View {
  @EnvironmentObject private var store: CorpusStore
  @State private var query = ""
  @State private var results: [MobileSearchEntry] = []
  @State private var resultsQuery = ""
  @State private var resultsIndexID: UUID?
  private var hasCurrentResults: Bool { resultsQuery == query && resultsIndexID == store.searchIndex.id }
  private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    List {
      Section(store.corpusName) {
        if hasQuery {
          ForEach(hasCurrentResults ? results : []) { entry in
            NavigationLink {
              CorpusFileDocumentView(
                citation: MobileRemoteFileCitation(path: entry.path, line: entry.line > 0 ? entry.line : nil, label: entry.title),
                allowsRemoteFallback: false,
                entry: entry.line > 0 ? entry : nil,
                prefersRendered: true
              )
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                Label(entry.title, systemImage: entry.line > 0 ? "text.alignleft" : "doc.text")
                  .font(.body.weight(.medium))
                Text(entry.parent.isEmpty ? entry.path : "\(entry.parent) · \(entry.path)")
                  .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !entry.body.isEmpty {
                  Text(entry.preview(query: query)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
              }.padding(.vertical, 3)
            }
          }
        } else {
          ForEach(store.corpusFiles) { file in
            NavigationLink {
              CorpusFileDocumentView(
                citation: MobileRemoteFileCitation(
                  path: file.relativePath,
                  line: nil,
                  label: file.name
                ),
                allowsRemoteFallback: false,
                prefersRendered: true
              )
            } label: {
              fileRow(file)
            }
          }
        }
      }
    }
    .overlay {
      if (store.isPreparingCorpus || store.isLoading) && store.corpusFiles.isEmpty {
        ProgressView("Loading corpus files…")
      } else if hasQuery && !hasCurrentResults {
        ProgressView("Searching…")
      } else if hasQuery && results.isEmpty {
        ContentUnavailableView.search(text: query)
      }
    }
    .navigationTitle("Files")
    .navigationBarTitleDisplayMode(.large)
    .searchable(text: $query, prompt: "Search notes, headings, and text")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        MobileSidebarToolbarButton()
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await store.refresh() }
        } label: {
          if store.isPreparingCorpus || store.isLoading {
            ProgressView()
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .disabled(store.isPreparingCorpus || store.isLoading)
      }
    }
    .refreshable {
      await store.refresh()
    }
    .task(id: "\(store.searchIndex.id)|\(query)") {
      let query = query
      let index = store.searchIndex
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      let task = Task.detached(priority: .userInitiated) { index.search(query) }
      let found = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
      guard !Task.isCancelled else { return }
      results = found
      resultsQuery = query
      resultsIndexID = index.id
    }
    .task {
      store.prepareCorpusViews()
      if store.corpusFiles.isEmpty, !store.isLoading {
        await store.refresh(showsLoading: false)
      }
    }
  }

  private func fileRow(_ file: CorpusFile) -> some View {
    HStack(spacing: 12) {
      Image(systemName: fileIcon(file))
        .foregroundStyle(.blue)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 3) {
        Text(file.name)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(file.relativePath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if let detail = fileDetail(file) {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func fileIcon(_ file: CorpusFile) -> String {
    switch URL(fileURLWithPath: file.relativePath).pathExtension.lowercased() {
    case "csv": "tablecells"
    case "md": "text.document"
    default: "doc.text"
    }
  }

  private func fileDetail(_ file: CorpusFile) -> String? {
    var parts: [String] = []
    if let byteCount = file.byteCount {
      parts.append(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
    }
    if let modifiedAt = file.modifiedAt {
      parts.append("Modified \(modifiedAt.formatted(date: .abbreviated, time: .omitted))")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

}

private enum MobileRemoteMessageMarkup {
  struct Table: Equatable {
    let rows: [[String]]
    let headerRowCount: Int

    var columnCount: Int {
      rows.map(\.count).max() ?? 0
    }
  }

  enum RenderedBlock: Equatable {
    case text(String)
    case table(Table)
    case image(ImageReference)
  }

  struct ImageReference: Equatable {
    /// Corpus-relative or absolute path for =file:= images, or nil for web images.
    let path: String?
    let remoteURL: URL?
    let label: String
  }

  private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

  /// Recognizes a line that consists only of an Org image link, which Org2
  /// renders inline rather than as a textual link.
  static func imageReference(in line: String) -> ImageReference? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let range = NSRange(location: 0, length: (trimmed as NSString).length)
    guard let match = orgLinkPattern.firstMatch(in: trimmed, range: range),
          match.range == range,
          let targetRange = Range(match.range(at: 1), in: trimmed)
    else { return nil }
    let target = String(trimmed[targetRange]).trimmingCharacters(in: .whitespaces)
    let label = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
    return imageReference(target: target, label: label)
  }

  static func imageReference(target: String, label: String) -> ImageReference? {
    let lowered = target.lowercased()
    if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
      guard let url = URL(string: target),
            imageExtensions.contains(url.pathExtension.lowercased())
      else { return nil }
      return ImageReference(path: nil, remoteURL: url, label: label)
    }
    var path = target
    if lowered.hasPrefix("file:") { path = String(path.dropFirst(5)) }
    else if lowered.contains(":") { return nil }
    path = path.components(separatedBy: "::").first ?? path
    guard !path.isEmpty,
          imageExtensions.contains((path as NSString).pathExtension.lowercased())
    else { return nil }
    return ImageReference(path: path, remoteURL: nil, label: label)
  }

  private static let markdownLinkPattern = try! NSRegularExpression(
    pattern: #"\[([^\]\n]+)\]\(([^)\n]+)\)"#
  )
  private static let orgLinkPattern = try! NSRegularExpression(
    pattern: #"\[\[([^\]\n]+)\](?:\[([^\]\n]*)\])?\]"#
  )
  private static let orderedListPattern = try! NSRegularExpression(
    pattern: #"^([0-9]+)[.)]\s+(.+)$"#
  )
  private static let inlinePatterns: [(pattern: NSRegularExpression, style: InlineStyle)] = [
    (try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])\*([^\s*](?:[^*\n]*[^\s*])?)\*(?![\p{L}\p{N}])"#), .bold),
    (try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])/([^\s/](?:[^/\n]*[^\s/])?)/(?![\p{L}\p{N}])"#), .italic),
    (try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])_([^\s_](?:[^_\n]*[^\s_])?)_(?![\p{L}\p{N}])"#), .underline),
    (try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])=([^\s=](?:[^=\n]*[^\s=])?)=(?![\p{L}\p{N}])"#), .code),
    (try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])~([^\s~](?:[^~\n]*[^\s~])?)~(?![\p{L}\p{N}])"#), .code),
    (try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])\+([^\s+](?:[^+\n]*[^\s+])?)\+(?![\p{L}\p{N}])"#), .strike)
  ]

  private enum InlineStyle {
    case bold
    case italic
    case underline
    case code
    case strike
  }

  private struct InlineToken {
    let range: NSRange
    let contentRange: NSRange
    let style: InlineStyle
  }

  private struct RenderedLink {
    let range: NSRange
    let label: String
    let url: URL?
  }

  private final class CachedMarkup {
    let value: AttributedString

    init(_ value: AttributedString) {
      self.value = value
    }
  }

  @MainActor private static let cache: NSCache<NSString, CachedMarkup> = {
    let cache = NSCache<NSString, CachedMarkup>()
    cache.countLimit = 512
    return cache
  }()

  @MainActor
  static func attributedString(for content: String) -> AttributedString {
    let key = content as NSString
    if let cached = cache.object(forKey: key) {
      return cached.value
    }

    let value = makeAttributedString(for: content)
    cache.setObject(CachedMarkup(value), forKey: key)
    return value
  }

  static func renderedBlocks(for content: String) -> [RenderedBlock] {
    let lines = content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var blocks: [RenderedBlock] = []
    var textLines: [String] = []
    var isInsideLiteralBlock = false

    func flushText() {
      guard !textLines.isEmpty else { return }
      let text = textLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
      textLines.removeAll(keepingCapacity: true)
      guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
      blocks.append(.text(text))
      textLines.removeAll(keepingCapacity: true)
    }

    var index = 0
    while index < lines.count {
      let line = normalizedBlockDirective(lines[index])
      let directive = line.trimmingCharacters(in: .whitespaces).lowercased()
      if directive.hasPrefix("#+begin_src") || directive.hasPrefix("#+begin_example") {
        isInsideLiteralBlock = true
      }

      if !isInsideLiteralBlock, let image = imageReference(in: line) {
        flushText()
        blocks.append(.image(image))
        index += 1
        continue
      }

      if !isInsideLiteralBlock, isTableLine(line) {
        var tableLines: [String] = []
        while index < lines.count {
          let candidate = normalizedBlockDirective(lines[index])
          guard isTableLine(candidate) else { break }
          tableLines.append(candidate)
          index += 1
        }
        if let table = table(from: tableLines) {
          flushText()
          blocks.append(.table(table))
          continue
        }
        textLines.append(contentsOf: tableLines)
        continue
      }

      textLines.append(line)
      if directive == "#+end_src" || directive == "#+end_example" {
        isInsideLiteralBlock = false
      }
      index += 1
    }
    flushText()
    return blocks
  }

  private static func isTableLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
  }

  private static func table(from lines: [String]) -> Table? {
    var rows: [[String]] = []
    var headerRowCount = 0
    var foundHeaderRule = false
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let inner = trimmed.dropFirst().dropLast()
      if !inner.isEmpty,
         inner.contains("-"),
         inner.allSatisfy({ $0 == "-" || $0 == "+" || $0.isWhitespace }) {
        if !foundHeaderRule {
          headerRowCount = rows.count
          foundHeaderRule = true
        }
        continue
      }
      rows.append(inner.split(separator: "|", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
      })
    }
    guard !rows.isEmpty, rows.contains(where: { !$0.allSatisfy(\.isEmpty) }) else { return nil }
    return Table(rows: rows, headerRowCount: headerRowCount)
  }

  private static func makeAttributedString(for content: String) -> AttributedString {
    let lines = content
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var output = AttributedString()
    var isInsideSourceBlock = false
    var isInsideQuoteBlock = false

    for (index, rawLine) in lines.enumerated() {
      if index > 0 {
        output.append(AttributedString("\n"))
      }

      let line = normalizedBlockDirective(rawLine)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let directive = trimmed.lowercased()
      if directive.hasPrefix("#+begin_src") || directive.hasPrefix("#+begin_example") {
        isInsideSourceBlock = true
        let language = trimmed.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init)
        var label = AttributedString(language.map { "Code · \($0)" } ?? "Code")
        label.font = .caption.monospaced().weight(.semibold)
        label.foregroundColor = .secondary
        output.append(label)
        continue
      }
      if directive == "#+end_src" || directive == "#+end_example" {
        isInsideSourceBlock = false
        continue
      }
      if directive == "#+begin_quote" {
        isInsideQuoteBlock = true
        continue
      }
      if directive == "#+end_quote" {
        isInsideQuoteBlock = false
        continue
      }

      if isInsideSourceBlock {
        var source = AttributedString(line)
        source.font = .system(.body, design: .monospaced)
        source.backgroundColor = Color.secondary.opacity(0.10)
        output.append(source)
      } else if isInsideQuoteBlock {
        var marker = AttributedString("│ ")
        marker.foregroundColor = .accentColor
        output.append(marker)
        var quote = inlineAttributedString(for: line)
        quote.font = .body.italic()
        quote.foregroundColor = .secondary
        output.append(quote)
      } else if let heading = heading(in: line) {
        var title = inlineAttributedString(for: heading.title)
        title.font = headingFont(level: heading.level)
        output.append(title)
      } else if let listItem = listItem(in: line) {
        var marker = AttributedString(listItem.marker)
        marker.foregroundColor = .accentColor
        output.append(marker)
        output.append(descriptionListAttributedString(for: listItem.body))
      } else if isHorizontalRule(trimmed) {
        var rule = AttributedString("────────────────")
        rule.foregroundColor = .secondary
        output.append(rule)
      } else if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") {
        var table = AttributedString(line)
        table.font = .system(.body, design: .monospaced)
        output.append(table)
      } else if directive.hasPrefix("#+") {
        var keyword = AttributedString(trimmed)
        keyword.font = .caption.monospaced()
        keyword.foregroundColor = .secondary
        output.append(keyword)
      } else {
        output.append(inlineAttributedString(for: line))
      }
    }
    return output
  }

  private static func inlineAttributedString(for content: String) -> AttributedString {
    let source = content as NSString
    let links = renderedLinks(in: content)
    guard !links.isEmpty else { return styledInlineAttributedString(for: content) }
    var output = AttributedString()
    var cursor = 0
    for link in links where link.range.location >= cursor {
      let prefixRange = NSRange(location: cursor, length: link.range.location - cursor)
      output.append(styledInlineAttributedString(for: source.substring(with: prefixRange)))
      var chunk = styledInlineAttributedString(for: link.label)
      if let url = link.url {
        chunk.foregroundColor = .accentColor
        chunk.link = url
      }
      output.append(chunk)
      cursor = link.range.location + link.range.length
    }
    if cursor < source.length {
      output.append(styledInlineAttributedString(for: source.substring(from: cursor)))
    }
    return output
  }

  private static func styledInlineAttributedString(for content: String) -> AttributedString {
    let source = content as NSString
    let fullRange = NSRange(location: 0, length: source.length)
    let tokens = inlinePatterns.flatMap { pattern, style in
      pattern.matches(in: content, range: fullRange).compactMap { match -> InlineToken? in
        guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return InlineToken(range: match.range, contentRange: match.range(at: 1), style: style)
      }
    }
    .sorted {
      if $0.range.location == $1.range.location { return $0.range.length > $1.range.length }
      return $0.range.location < $1.range.location
    }
    guard !tokens.isEmpty else { return AttributedString(content) }

    var output = AttributedString()
    var cursor = 0
    for token in tokens where token.range.location >= cursor {
      let prefix = NSRange(location: cursor, length: token.range.location - cursor)
      output.append(AttributedString(source.substring(with: prefix)))
      var chunk = AttributedString(source.substring(with: token.contentRange))
      switch token.style {
      case .bold:
        chunk.font = .body.weight(.semibold)
      case .italic:
        chunk.font = .body.italic()
      case .underline:
        chunk.underlineStyle = .single
      case .code:
        chunk.font = .system(.body, design: .monospaced)
        chunk.backgroundColor = Color.secondary.opacity(0.13)
      case .strike:
        chunk.strikethroughStyle = .single
      }
      output.append(chunk)
      cursor = token.range.location + token.range.length
    }
    if cursor < source.length {
      output.append(AttributedString(source.substring(from: cursor)))
    }
    return output
  }

  private static func heading(in line: String) -> (level: Int, title: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let stars = trimmed.prefix { $0 == "*" }
    guard (1...6).contains(stars.count) else { return nil }
    let remainder = trimmed.dropFirst(stars.count)
    guard let first = remainder.first, first.isWhitespace else { return nil }
    let title = remainder.trimmingCharacters(in: .whitespaces)
    return title.isEmpty ? nil : (stars.count, title)
  }

  private static func headingFont(level: Int) -> Font {
    switch level {
    case 1: return .title3.weight(.bold)
    case 2: return .headline
    default: return .subheadline.weight(.semibold)
    }
  }

  private static func listItem(in line: String) -> (marker: String, body: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    for prefix in ["- ", "+ "] where trimmed.hasPrefix(prefix) {
      return ("• ", String(trimmed.dropFirst(prefix.count)))
    }
    let source = trimmed as NSString
    let range = NSRange(location: 0, length: source.length)
    guard let match = orderedListPattern.firstMatch(in: trimmed, range: range),
          let numberRange = Range(match.range(at: 1), in: trimmed),
          let bodyRange = Range(match.range(at: 2), in: trimmed)
    else { return nil }
    return ("\(trimmed[numberRange]). ", String(trimmed[bodyRange]))
  }

  private static func descriptionListAttributedString(for body: String) -> AttributedString {
    guard let separator = body.range(of: " :: ") else {
      return inlineAttributedString(for: body)
    }
    var term = inlineAttributedString(for: String(body[..<separator.lowerBound]))
    term.font = .body.weight(.semibold)
    var output = term
    var separatorChunk = AttributedString(" — ")
    separatorChunk.foregroundColor = .secondary
    output.append(separatorChunk)
    output.append(inlineAttributedString(for: String(body[separator.upperBound...])))
    return output
  }

  private static func normalizedBlockDirective(_ line: String) -> String {
    let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
    let trimmed = line.dropFirst(indentation.count)
    let hashes = trimmed.prefix { $0 == "#" }
    guard hashes.count > 1 else { return line }
    let suffix = trimmed.dropFirst(hashes.count)
    guard suffix.first == "+" else { return line }
    return indentation + "#" + suffix
  }

  private static func isHorizontalRule(_ line: String) -> Bool {
    guard line.count >= 5 else { return false }
    return line.allSatisfy { $0 == "-" }
  }

  static func fileCitation(from url: URL) -> MobileRemoteFileCitation? {
    guard url.scheme == "org2-mobile-file",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let target = components.queryItems?.first(where: { $0.name == "target" })?.value
    let path = components.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
    guard target != nil || !path.isEmpty else { return nil }
    let line = components.queryItems?.first(where: { $0.name == "line" })?.value.flatMap(Int.init)
    let label = components.queryItems?.first(where: { $0.name == "label" })?.value ?? target ?? path
    return MobileRemoteFileCitation(path: path, line: line, label: label, target: target)
  }

  private static func renderedLinks(in content: String) -> [RenderedLink] {
    let fullRange = NSRange(content.startIndex..<content.endIndex, in: content)
    var links: [RenderedLink] = markdownLinkPattern.matches(in: content, range: fullRange).compactMap { match -> RenderedLink? in
      guard let labelRange = Range(match.range(at: 1), in: content),
            let targetRange = Range(match.range(at: 2), in: content),
            let rendered = renderedLink(
              range: match.range,
              target: String(content[targetRange]),
              label: String(content[labelRange])
            )
      else { return nil }
      return rendered
    }
    let orgLinks: [RenderedLink] = orgLinkPattern.matches(in: content, range: fullRange).compactMap { match -> RenderedLink? in
      guard let targetRange = Range(match.range(at: 1), in: content) else { return nil }
      let labelRange = Range(match.range(at: 2), in: content)
      return renderedLink(
        range: match.range,
        target: String(content[targetRange]),
        label: labelRange.map { String(content[$0]) } ?? String(content[targetRange])
      )
    }
    links.append(contentsOf: orgLinks)
    return links.sorted { $0.range.location < $1.range.location }
  }

  private static func renderedLink(
    range: NSRange,
    target rawTarget: String,
    label: String
  ) -> RenderedLink? {
    if let citation = citation(target: rawTarget, label: label),
       let url = citationURL(citation) {
      let displayLabel = citation.line.map { "\(citation.label) · L\($0)" } ?? citation.label
      return RenderedLink(range: range, label: displayLabel, url: url)
    }
    var target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    if target.hasPrefix("<"), target.hasSuffix(">") {
      target = String(target.dropFirst().dropLast())
    }
    if let url = URL(string: target),
       ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
      return RenderedLink(range: range, label: label, url: url)
    }
    // Other file links (images mid-sentence, PDFs) still read as their label.
    guard target.lowercased().hasPrefix("file:") else { return nil }
    return RenderedLink(range: range, label: label, url: nil)
  }

  private static func citation(target rawTarget: String, label: String) -> MobileRemoteFileCitation? {
    guard let link = MobileDocumentLink.parse(rawTarget) else { return nil }
    return MobileRemoteFileCitation(path: link.path, line: Int(link.selector), label: label, target: rawTarget)
  }

  private static func citationURL(_ citation: MobileRemoteFileCitation) -> URL? {
    var components = URLComponents()
    components.scheme = "org2-mobile-file"
    components.host = "preview"
    components.queryItems = [
      URLQueryItem(name: "path", value: citation.path),
      URLQueryItem(name: "label", value: citation.label)
    ]
    if let line = citation.line {
      components.queryItems?.append(URLQueryItem(name: "line", value: String(line)))
    }
    if let target = citation.target {
      components.queryItems?.append(URLQueryItem(name: "target", value: target))
    }
    return components.url
  }
}

private struct MobileRemoteRenderedMessageText: View {
  let content: String

  var body: some View {
    let blocks = MobileRemoteMessageMarkup.renderedBlocks(for: content)
    VStack(alignment: .leading, spacing: 9) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .text(let text):
          Text(MobileRemoteMessageMarkup.attributedString(for: text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .table(let table):
          MobileRemoteOrgTable(table: table)
        case .image(let image):
          MobileRemoteInlineImage(reference: image)
        }
      }
    }
  }
}

private struct MobileRemoteOrgTable: View {
  let table: MobileRemoteMessageMarkup.Table

  // A horizontal ScrollView proposes unlimited width, so a flexible frame
  // never makes text wrap to its height. Give each column a definite width
  // estimated from its longest cell instead.
  private var columnWidths: [CGFloat] {
    (0..<table.columnCount).map { column in
      let longest = table.rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
      return min(220, max(56, CGFloat(longest) * 9.5))
    }
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: true) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
          GridRow {
            ForEach(0..<table.columnCount, id: \.self) { columnIndex in
              Text(MobileRemoteMessageMarkup.attributedString(
                for: columnIndex < row.count ? row[columnIndex] : ""
              ))
              .font(rowIndex < table.headerRowCount ? .body.weight(.semibold) : .body)
              .textSelection(.enabled)
              .frame(width: columnWidths[columnIndex], alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 9)
              .padding(.vertical, 7)
              .frame(maxHeight: .infinity, alignment: .topLeading)
              .background(
                rowIndex < table.headerRowCount
                  ? Color.secondary.opacity(0.14)
                  : Color.clear
              )
              .overlay {
                Rectangle()
                  .stroke(Color.secondary.opacity(0.24), lineWidth: 0.5)
              }
            }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.secondary.opacity(0.28), lineWidth: 0.5)
      }
    }
    // A horizontal ScrollView is vertically flexible, so inside the chat's
    // vertical stack it could be measured at one height and placed at
    // another, leaving the next message drawn over the end of this one.
    // Pin it to the table's natural height.
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Table")
  }
}

@MainActor
private enum MobileRemoteInlineImageCache {
  static let images: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.totalCostLimit = 64 * 1024 * 1024
    return cache
  }()
}

/// Renders an Org image link inline. Corpus images load from the synced
/// corpus first and fall back to the paired Mac, since freshly generated
/// images often reach the Mac before they sync to the phone.
private struct MobileRemoteInlineImage: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var remote: MobileRemoteStore
  let reference: MobileRemoteMessageMarkup.ImageReference
  @State private var image: UIImage?
  @State private var failed = false
  @State private var isFullScreen = false

  private var cacheKey: String { reference.path ?? reference.remoteURL?.absoluteString ?? "" }
  private var caption: String {
    if !reference.label.isEmpty { return reference.label }
    return ((reference.path ?? reference.remoteURL?.lastPathComponent ?? "") as NSString).lastPathComponent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let image {
        Button { isFullScreen = true } label: {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 420, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(caption.isEmpty ? "Image" : caption)
        if !reference.label.isEmpty {
          Text(reference.label).font(.caption).foregroundStyle(.secondary)
        }
      } else if failed {
        Label(caption.isEmpty ? "Image unavailable" : "\(caption) (unavailable)", systemImage: "photo")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.secondary.opacity(0.10))
          .frame(height: 160)
          .overlay { ProgressView() }
      }
    }
    .task(id: cacheKey) { await load() }
    .fullScreenCover(isPresented: $isFullScreen) {
      NavigationStack {
        ScrollView([.horizontal, .vertical]) {
          if let image {
            Image(uiImage: image).resizable().scaledToFit()
              .frame(maxWidth: .infinity)
          }
        }
        .navigationTitle(caption)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { isFullScreen = false }
          }
        }
      }
    }
  }

  private func load() async {
    if let cached = MobileRemoteInlineImageCache.images.object(forKey: cacheKey as NSString) {
      image = cached
      return
    }
    var data: Data?
    if let url = reference.remoteURL {
      data = try? await URLSession.shared.data(from: url).0
    } else if let path = reference.path {
      data = try? await store.imageData(path: path)
      if data == nil, remote.isPaired {
        data = try? await remote.imageData(path: path)
      }
    }
    guard !Task.isCancelled else { return }
    guard let data, let loaded = UIImage(data: data) else {
      failed = true
      return
    }
    MobileRemoteInlineImageCache.images.setObject(loaded, forKey: cacheKey as NSString, cost: data.count)
    image = loaded
  }
}

/// Toolbar chip for the files this thread edited or linked, the phone's
/// counterpart to the Mac AI chat header's Outputs chip.
private struct MobileRemoteThreadOutputsChip: View {
  let outputs: MobileRemoteThreadOutputs
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: outputs.folderName == nil ? "doc.on.doc" : "folder")
        Text("\(outputs.groupsInFolder.count)\(outputs.isTruncated ? "+" : "")")
          .monospacedDigit()
        if outputs.staleCount > 0 {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }
      .font(.footnote.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.quaternary, in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityText)
    .accessibilityIdentifier("mobile-thread-outputs-chip")
  }

  private var accessibilityText: String {
    var parts = ["Outputs"]
    if let folder = outputs.folderName { parts.append(folder) }
    parts.append(outputs.chipCountText)
    if outputs.staleCount > 0 { parts.append("\(outputs.staleCount) stale") }
    return parts.joined(separator: ", ")
  }
}

/// The Outputs list: the working folder, its outputs grouped by source and
/// published formats, everything else the thread touched, and a jump back to
/// the reply that last touched each file.
private struct MobileRemoteThreadOutputsSheet: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var remote: MobileRemoteStore
  @Environment(\.dismiss) private var dismiss
  let outputs: MobileRemoteThreadOutputs
  let onJumpToMessage: (UUID) -> Void
  @State private var openedFile: MobileRemoteThreadOutputFile?
  @State private var quickLookURL: URL?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        if let folder = outputs.folderDisplayPath {
          Section("Folder") {
            Label(folder, systemImage: "folder.fill")
              .font(.callout.monospaced())
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
        Section(outputs.folderName == nil ? "Files" : "In this folder") {
          ForEach(outputs.groupsInFolder) { group in
            row(group)
          }
        }
        if !outputs.groupsOutsideFolder.isEmpty {
          Section("Also touched (\(outputs.groupsOutsideFolder.count))") {
            ForEach(outputs.groupsOutsideFolder) { group in
              row(group)
            }
          }
        }
        if outputs.isTruncated {
          Section {
            Text("Showing the \(outputs.maxGroups) most recently edited or linked files.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Outputs")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(item: $openedFile) { file in
        CorpusFileDocumentView(
          citation: MobileRemoteFileCitation(path: file.path, line: nil, label: file.displayPath),
          allowsRemoteFallback: true,
          prefersRendered: ["org", "org2"].contains(file.fileExtension)
        )
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .quickLookPreview($quickLookURL)
      .alert("File Unavailable", isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "")
      }
    }
    .accessibilityIdentifier("mobile-thread-outputs-sheet")
  }

  private func row(_ group: MobileRemoteThreadOutputGroup) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: group.wasCreated ? "plus.circle" : (group.editCount > 0 ? "pencil" : "link"))
          .font(.caption)
          .foregroundStyle(group.wasCreated ? Color.green : Color.secondary)
          .frame(width: 16)
        Button {
          if let primary = group.primary { open(primary) }
        } label: {
          Text(group.title)
            .font(.callout.monospaced())
            .lineLimit(2)
            .truncationMode(.middle)
            .foregroundStyle(group.exists ? Color.primary : Color.secondary)
            .strikethrough(!group.exists)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(group.primary.map(canOpen) != true)
        if let messageID = group.lastMessageID {
          Button {
            onJumpToMessage(messageID)
          } label: {
            Image(systemName: "arrow.uturn.backward")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Jump to the last reply that touched this file")
        }
      }
      HStack(spacing: 6) {
        Text(group.activitySummary)
        if !group.staleFormats.isEmpty {
          Label("\(group.staleFormats.joined(separator: ", ")) stale", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.leading, 24)
      if group.files.count > 1 {
        HStack(spacing: 6) {
          ForEach(group.files) { file in
            Button(file.fileExtension.isEmpty ? "file" : file.fileExtension) {
              open(file)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(file.isStale ? .orange : .accentColor)
            .disabled(!canOpen(file))
          }
        }
        .padding(.leading, 24)
      }
    }
    .padding(.vertical, 2)
  }

  /// Text formats use the corpus reader, which falls back to the Mac. Binary
  /// formats need the locally synced copy for Quick Look.
  private func canOpen(_ file: MobileRemoteThreadOutputFile) -> Bool {
    guard file.exists, file.isInCorpus else { return false }
    return file.opensInReader || store.rootURL != nil
  }

  private func open(_ file: MobileRemoteThreadOutputFile) {
    if file.opensInReader {
      openedFile = file
      return
    }
    Task {
      do {
        quickLookURL = try await store.quickLookCopy(path: file.path)
      } catch {
        errorMessage = "\(file.displayPath) isn't in the synced corpus on this phone yet. Let the corpus sync, then try again."
      }
    }
  }
}

private struct MobileRemoteFilePreviewSheet: View {
  @Environment(\.dismiss) private var dismiss
  let citation: MobileRemoteFileCitation

  var body: some View {
    NavigationStack {
      CorpusFileDocumentView(citation: citation, allowsRemoteFallback: true, prefersRendered: citation.documentLink != nil)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}

private struct CorpusFileDocumentView: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var remote: MobileRemoteStore
  let citation: MobileRemoteFileCitation
  let allowsRemoteFallback: Bool
  var entry: MobileSearchEntry? = nil
  var prefersRendered = false
  @State private var showsSource = false
  @State private var rendered: MobileRenderedDocument?
  @State private var renderError: String?
  @State private var linkedEntry: MobileSearchEntry?
  @State private var nextCitation: MobileRemoteFileCitation?
  private var selectedEntry: MobileSearchEntry? { linkedEntry ?? entry }
  @State private var preview: CorpusFilePreview?
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if let preview {
        previewContent(preview)
      } else if let errorMessage {
        ContentUnavailableView(
          "File Unavailable",
          systemImage: "doc.text.magnifyingglass",
          description: Text(errorMessage)
        )
      } else {
        ProgressView("Loading complete file…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(rendered?.title ?? selectedEntry?.title ?? preview?.title ?? citation.label)
    .navigationDestination(item: $nextCitation) { next in
      CorpusFileDocumentView(citation: next, allowsRemoteFallback: allowsRemoteFallback, prefersRendered: true)
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if canRender {
        ToolbarItem(placement: .topBarTrailing) {
          Button(showsSource ? "Rendered" : "Source") { showsSource.toggle() }
        }
      }
    }
    .task(id: "\(store.rootURL?.path ?? "")|\(citation.id)") {
      preview = nil
      rendered = nil
      renderError = nil
      linkedEntry = nil
      errorMessage = nil
      var path = citation.path
      do {
        if let link = citation.documentLink { path = try await store.pathForDocumentLink(link) }
      } catch {
        errorMessage = error.localizedDescription
        return
      }
      do {
        let loaded = try await store.filePreview(path: path, line: citation.line)
        guard !Task.isCancelled else { return }
        preview = loaded
      } catch let localError {
        guard !Task.isCancelled else { return }
        guard allowsRemoteFallback, remote.isPaired else {
          errorMessage = localError.localizedDescription
          return
        }
        do {
          let fetched = try await remote.filePreview(path: path, line: citation.line)
          guard !Task.isCancelled else { return }
          preview = CorpusFilePreview(
            title: fetched.title,
            relativePath: fetched.relativePath,
            startLine: fetched.startLine,
            highlightedLine: fetched.highlightedLine,
            content: fetched.content
          )
        } catch {
          errorMessage = error.localizedDescription
        }
      }
      guard !Task.isCancelled else { return }
      if canRender, let preview {
        do {
          if let link = citation.documentLink, !link.selector.isEmpty {
            let resolved = try await store.entryForDocumentLink(link, preview: preview)
            guard !Task.isCancelled else { return }
            linkedEntry = resolved
          }
          let result = try await store.renderedDocument(preview: preview, entry: selectedEntry)
          guard !Task.isCancelled else { return }
          rendered = result
        } catch {
          guard !Task.isCancelled else { return }
          renderError = error.localizedDescription
        }
      }
    }
  }

  private var canRender: Bool {
    prefersRendered && (citation.documentLink != nil || ["org", "org2"].contains(URL(fileURLWithPath: citation.path).pathExtension.lowercased()))
  }

  private func previewContent(_ preview: CorpusFilePreview) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(preview.relativePath)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        Text("\(lineCount(preview.content)) lines")
          .fixedSize()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal)
      .padding(.vertical, 10)
      Divider()
      if selectedEntry != nil {
        NavigationLink("Open full note") {
          CorpusFileDocumentView(
            citation: MobileRemoteFileCitation(path: preview.relativePath, line: nil, label: preview.title),
            allowsRemoteFallback: allowsRemoteFallback, prefersRendered: true
          )
        }.padding(.horizontal).padding(.vertical, 8)
      }
      if canRender && !showsSource {
        if let rendered {
          MobileRenderedDocumentView(html: rendered.html) { target in
            guard let link = MobileDocumentLink.parse(target, relativeTo: preview.relativePath) else { return }
            nextCitation = MobileRemoteFileCitation(path: link.path, line: Int(link.selector), label: "Linked entry", target: target, sourcePath: preview.relativePath)
          }
        } else if let renderError {
          ContentUnavailableView("Entry Unavailable", systemImage: "doc.text", description: Text(renderError))
        } else {
          ProgressView("Rendering…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        MobileRemoteSourceTextView(preview: preview)
      }
    }
  }

  private func lineCount(_ content: String) -> Int {
    content.utf8.reduce(into: 1) { count, byte in
      if byte == 0x0A { count += 1 }
    }
  }
}

private struct MobileRemoteSourceTextView: UIViewRepresentable {
  let preview: CorpusFilePreview

  final class Coordinator {
    var renderIdentity = ""
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context _: Context) -> UITextView {
    let textView = UITextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.backgroundColor = .clear
    textView.alwaysBounceHorizontal = true
    textView.alwaysBounceVertical = true
    textView.showsHorizontalScrollIndicator = true
    textView.showsVerticalScrollIndicator = true
    textView.keyboardDismissMode = .interactive
    textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 20, right: 12)
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.widthTracksTextView = false
    textView.textContainer.size = CGSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.layoutManager.allowsNonContiguousLayout = true
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    let identity = "\(preview.relativePath)|\(preview.highlightedLine ?? 0)|\(preview.content.hashValue)"
    guard context.coordinator.renderIdentity != identity else { return }
    context.coordinator.renderIdentity = identity

    let presentation = Self.presentation(for: preview)
    textView.attributedText = presentation.text
    textView.setContentOffset(.zero, animated: false)

    guard let highlightRange = presentation.highlightRange else { return }
    DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
      guard let textView, coordinator?.renderIdentity == identity else { return }
      textView.scrollRangeToVisible(NSRange(location: highlightRange.location, length: 0))
      textView.setContentOffset(
        CGPoint(x: 0, y: max(0, textView.contentOffset.y - 72)),
        animated: false
      )
    }
  }

  private static func presentation(
    for preview: CorpusFilePreview
  ) -> (text: NSAttributedString, highlightRange: NSRange?) {
    var lines = preview.content
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    if lines.isEmpty { lines = [""] }

    let font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
      for: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    )
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    let sourceAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.label,
      .paragraphStyle: paragraph
    ]
    let gutterAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.tertiaryLabel,
      .paragraphStyle: paragraph
    ]
    let numberWidth = String(preview.startLine + max(0, lines.count - 1)).count
    let output = NSMutableAttributedString()
    var highlightRange: NSRange?

    for (offset, line) in lines.enumerated() {
      let lineNumber = preview.startLine + offset
      let number = String(lineNumber)
      let padding = String(repeating: " ", count: max(0, numberWidth - number.count))
      let rowStart = output.length
      output.append(NSAttributedString(string: "\(padding)\(number)  ", attributes: gutterAttributes))
      output.append(NSAttributedString(string: line.isEmpty ? " " : line, attributes: sourceAttributes))
      let rowLength = output.length - rowStart
      if lineNumber == preview.highlightedLine {
        highlightRange = NSRange(location: rowStart, length: rowLength)
        output.addAttribute(
          .backgroundColor,
          value: UIColor.tintColor.withAlphaComponent(0.14),
          range: NSRange(location: rowStart, length: rowLength)
        )
      }
      if offset < lines.count - 1 {
        output.append(NSAttributedString(string: "\n", attributes: sourceAttributes))
      }
    }

    return (output, highlightRange)
  }
}

private struct MobileRemotePhotoThumbnail: View {
  let attachment: MobileRemoteAttachment
  let remove: () -> Void

  var body: some View {
    ZStack(alignment: .topTrailing) {
      if let image = UIImage(data: attachment.data) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: 58, height: 58)
          .clipShape(RoundedRectangle(cornerRadius: 10))
      }
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .black.opacity(0.7))
      }
      .buttonStyle(.plain)
      .offset(x: 5, y: -5)
      .accessibilityLabel("Remove \(attachment.fileName)")
    }
    .padding(.top, 5)
    .padding(.trailing, 5)
  }
}

private enum MobileRemotePhotoPreparation {
  static func attachment(from data: Data, sequence: Int) throws -> MobileRemoteAttachment {
    guard let image = UIImage(data: data) else {
      throw MobileRemotePhotoError.unreadable
    }
    let maxDimension: CGFloat = 2_048
    let longestSide = max(image.size.width, image.size.height)
    let scale = longestSide > maxDimension ? maxDimension / longestSide : 1
    let size = CGSize(
      width: max(1, floor(image.size.width * scale)),
      height: max(1, floor(image.size.height * scale))
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }

    var quality: CGFloat = 0.82
    guard var encoded = resized.jpegData(compressionQuality: quality) else {
      throw MobileRemotePhotoError.unreadable
    }
    while encoded.count > 1_500_000, quality > 0.34 {
      quality -= 0.12
      guard let next = resized.jpegData(compressionQuality: quality) else { break }
      encoded = next
    }
    guard encoded.count <= 5_000_000 else {
      throw MobileRemotePhotoError.tooLarge
    }
    return MobileRemoteAttachment(
      fileName: "mobile-photo-\(sequence).jpg",
      mimeType: "image/jpeg",
      data: encoded
    )
  }
}

private enum MobileRemotePhotoError: LocalizedError {
  case unreadable
  case tooLarge
  case totalTooLarge

  var errorDescription: String? {
    switch self {
    case .unreadable:
      "One of the selected photos could not be read."
    case .tooLarge:
      "One of the selected photos is too large to send."
    case .totalTooLarge:
      "The selected photos are too large to send together. Remove one and try again."
    }
  }
}

private struct MobileRemoteInProgressBubble: View {
  @Environment(\.colorScheme) private var colorScheme
  let detail: MobileRemoteThreadDetail
  let isStarting: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 9) {
        MobileRemoteShimmeringStatusText(
          statusTitle,
          animates: isStarting || detail.connectionState != "disconnected"
        )

        if !trimmedReply.isEmpty {
          MobileRemoteBoundedMessageText(content: detail.streamingReply)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 13)
      .padding(.vertical, 10)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
      .overlay {
        RoundedRectangle(cornerRadius: 15)
          .stroke(Color.primary.opacity(colorScheme == .light ? 0.14 : 0.10), lineWidth: 1)
      }
      .accessibilityElement(children: .combine)
      .accessibilityHint(detail.connectionDetail ?? "")
      Spacer(minLength: 36)
    }
  }

  private var runtimeTitle: String {
    // Name the host so a turn looks the same from every paired Mac or server.
    if let host = detail.thread.executionHostName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !host.isEmpty, detail.thread.isRunning {
      return "\(destinationTitle) on \(host)"
    }
    return destinationTitle
  }

  private var destinationTitle: String {
    if let activeDestinationName = detail.activeDestinationName?
      .trimmingCharacters(in: .whitespacesAndNewlines),
       !activeDestinationName.isEmpty {
      return activeDestinationName
    }
    return mobileAIRuntimeTitle(detail.thread.runtime)
  }

  private var trimmedReply: String {
    detail.streamingReply.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var statusTitle: String {
    if isStarting {
      return "Connecting to \(runtimeTitle)"
    }

    switch detail.connectionState {
    case "connecting":
      return "Connecting to \(runtimeTitle)"
    case "reconnecting":
      return "Reconnecting to \(runtimeTitle)"
    case "fallbackHTTP":
      return "\(runtimeTitle) is working over HTTP"
    case "disconnected":
      return runtimeTitle == "Codex" ? "Codex connection interrupted" : "Connection interrupted"
    default:
      if let latest = detail.activities.last(where: { $0.status == "running" }),
         !latest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "Running \(latest.title.lowercased())"
      }
      if !detail.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "\(runtimeTitle) is thinking"
      }
      return "\(runtimeTitle) is working"
    }
  }
}

private struct MobileRemoteShimmeringStatusText: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let title: String
  let animates: Bool

  init(_ title: String, animates: Bool = true) {
    self.title = title
    self.animates = animates
  }

  var body: some View {
    Text(title)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .overlay {
        if animates && !reduceMotion {
          TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            GeometryReader { geometry in
              let width = geometry.size.width
              let bandWidth = min(90, max(40, width * 0.5))
              let progress = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2.2) / 2.2

              LinearGradient(
                colors: [.clear, Color.primary.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
              )
              .frame(width: bandWidth)
              .offset(x: -bandWidth + ((width + bandWidth) * progress))
            }
            .mask(alignment: .leading) {
              Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            }
          }
        }
      }
      .contentTransition(.opacity)
      .animation(.easeInOut(duration: 0.18), value: title)
  }
}

private struct MobileRemoteActivityView: View {
  let activities: [MobileRemoteActivity]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(activities.suffix(6)) { activity in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: statusSymbol(for: activity.status))
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor(for: activity.status))
            .frame(width: 14)
          VStack(alignment: .leading, spacing: 2) {
            Text(activity.title)
              .font(.caption.weight(.medium))
            if let detail = activity.detail,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
        }
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Activity")
  }

  private func statusSymbol(for status: String) -> String {
    switch status {
    case "succeeded": "checkmark.circle.fill"
    case "failed": "exclamationmark.circle.fill"
    default: "circle.dotted"
    }
  }

  private func statusColor(for status: String) -> Color {
    switch status {
    case "failed": .orange
    case "succeeded": .secondary
    default: .secondary
    }
  }
}

private struct MobileRemoteScannerSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onScan: (String) -> Void

  var body: some View {
    NavigationStack {
      MobileRemoteQRScanner(onScan: onScan)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Scan Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
        }
    }
  }
}

private struct MobileRemoteQRScanner: UIViewControllerRepresentable {
  let onScan: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onScan: onScan)
  }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: true,
      isPinchToZoomEnabled: true,
      isGuidanceEnabled: true,
      isHighlightingEnabled: true
    )
    scanner.delegate = context.coordinator
    DispatchQueue.main.async {
      try? scanner.startScanning()
    }
    return scanner
  }

  func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

  static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
    scanner.stopScanning()
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    private let onScan: (String) -> Void
    private var hasScanned = false

    init(onScan: @escaping (String) -> Void) {
      self.onScan = onScan
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController,
      didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      guard !hasScanned else { return }
      for item in addedItems {
        guard case .barcode(let barcode) = item,
              let payload = barcode.payloadStringValue
        else {
          continue
        }
        hasScanned = true
        dataScanner.stopScanning()
        onScan(payload)
        return
      }
    }
  }
}

// Rendered by the bundled shared Org2 compiler; this view only presents its HTML.
private struct MobileRenderedDocumentView: UIViewRepresentable {
  let html: String
  let openDocumentLink: (String) -> Void
  final class Coordinator: NSObject, WKNavigationDelegate {
    var html = ""
    var openDocumentLink: (String) -> Void
    init(openDocumentLink: @escaping (String) -> Void) { self.openDocumentLink = openDocumentLink }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
      if action.navigationType == .linkActivated {
        if let url = action.request.url {
          if url.scheme == "about", url.fragment != nil {
            decisionHandler(.allow)
            return
          }
          if url.scheme == "org2-workspace", url.host == "open-link",
             let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "target" })?.value {
            openDocumentLink(target)
          } else if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
          }
        }
        decisionHandler(.cancel)
      } else { decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel) }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator(openDocumentLink: openDocumentLink) }
  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.isOpaque = false
    view.backgroundColor = .clear
    return view
  }
  func updateUIView(_ view: WKWebView, context: Context) {
    context.coordinator.openDocumentLink = openDocumentLink
    guard context.coordinator.html != html else { return }
    context.coordinator.html = html
    view.loadHTMLString(html, baseURL: nil)
  }
}
