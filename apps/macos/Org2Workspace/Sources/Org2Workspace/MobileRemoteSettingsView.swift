import AppKit
import CoreImage
import Org2WorkspaceCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceSettingsView: View {
  @ObservedObject var softwareUpdates: SoftwareUpdateController
  @ObservedObject var telemetry: OpenOrgLaunchTelemetry
  @AppStorage(WorkspaceSettingsNavigation.selectionKey) private var selection = WorkspaceSettingsNavigation.workspace

  var body: some View {
    TabView(selection: $selection) {
      GeneralSettingsView(telemetry: telemetry)
        .tag(WorkspaceSettingsNavigation.workspace)
        .tabItem {
          Label("General", systemImage: "gearshape")
        }

      AppearanceSettingsView()
        .tag("appearance")
        .tabItem {
          Label("Appearance", systemImage: "circle.lefthalf.filled")
        }

      WorkspaceAppsSettingsView()
        .tag(WorkspaceSettingsNavigation.apps)
        .tabItem {
          Label("Apps", systemImage: "square.grid.2x2")
        }

      DocumentSettingsView()
        .tag("documents")
        .tabItem {
          Label("Documents", systemImage: "doc.richtext")
        }

      SharingSettingsView()
        .tag("sharing")
        .tabItem {
          Label("Sharing", systemImage: "network")
        }

      MeetingSettingsView()
        .tag("meetings")
        .tabItem {
          Label("Meetings", systemImage: "waveform")
        }

      AIChatSettingsView()
        .tag("aiChat")
        .tabItem {
          Label("AI Chat", systemImage: "text.bubble")
        }

      AttentionSettingsView()
        .tag("attention")
        .tabItem {
          Label("Attention", systemImage: "bell.badge")
        }

      MobileRemoteSettingsView()
        .tag("mobileRemote")
        .tabItem {
          Label("Mobile Remote", systemImage: "iphone")
        }

      SoftwareUpdateSettingsView(softwareUpdates: softwareUpdates)
        .tag("updates")
        .tabItem {
          Label("Updates", systemImage: "arrow.triangle.2.circlepath")
        }
    }
    .frame(width: 660, height: 620)
  }
}

private struct GeneralSettingsView: View {
  @ObservedObject var telemetry: OpenOrgLaunchTelemetry
  @Environment(WorkspaceStore.self) private var store
  @State private var corpusName = ""
  @State private var corpusKind = "personal"
  @State private var isSaving = false

  var body: some View {
    Form {
      Section {
        if let root = store.corpusRoot {
          TextField("Name", text: $corpusName)

          Picker("Kind", selection: $corpusKind) {
            Text("Personal").tag("personal")
            Text("Project").tag("project")
            Text("Shared").tag("shared")
          }

          LabeledContent("Location") {
            Text(root.path)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }

          HStack {
            Button("Reveal in Finder") {
              store.launchGuideRevealWorkspace()
            }
            Button("Open Another Corpus…") {
              store.chooseCorpus()
            }
            Spacer()
            Button {
              isSaving = true
              Task {
                _ = await store.updateActiveCorpusIdentity(
                  name: corpusName,
                  kind: corpusKind
                )
                isSaving = false
              }
            } label: {
              if isSaving {
                HStack(spacing: 6) {
                  ProgressView().controlSize(.small)
                  Text("Saving")
                }
              } else {
                Text("Save Corpus Info")
              }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || corpusName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        } else {
          ContentUnavailableView(
            "No Workspace Open",
            systemImage: "folder.badge.questionmark",
            description: Text("Open a corpus to edit its name, kind, or location.")
          )
          Button("Open Corpus…") { store.chooseCorpus() }
        }
      } header: {
        Label("Corpus", systemImage: "folder")
      } footer: {
        SettingsFooterText("The corpus remains an ordinary folder. Move or rename it in Finder, then open its new location here. Its portable name and kind are stored in the corpus's celorga.json.")
      }
      if store.corpusRoot != nil {
        Section {
          Toggle("Disable automatic daily note creation", isOn: Binding(
            get: { store.automaticDailyNoteCreationDisabled },
            set: { store.automaticDailyNoteCreationDisabled = $0 }
          ))
        } header: {
          Label("Daily Notes", systemImage: "calendar")
        } footer: {
          SettingsFooterText("When enabled, Daily links open existing files only. If a note is missing, Celorga shows a Create Daily Note button instead. This preference applies to this workspace on this Mac.")
        }
      }
      if store.corpusRoot != nil { DailyNoteFormatSettingsSection() }
      if store.corpusRoot != nil {
        Section {
          LabeledContent("Scheduler") {
            Label(
              scheduler.title.replacingOccurrences(of: "Scheduler: ", with: ""),
              systemImage: scheduler.systemImage
            )
          }
          Text(scheduler.detail)
            .foregroundStyle(.secondary)
        } header: {
          Label("Automations", systemImage: "clock.arrow.circlepath")
        } footer: {
          SettingsFooterText("Scheduler ownership applies to every automation in this corpus and is configured in the corpus's celorga.json.")
        }
      }
      if store.corpusRoot != nil { CorpusTodoSettingsSection() }
      // App-wide preferences stay below the workspace settings: experimental
      // features second from the bottom, telemetry last.
      Section {
        Toggle("Experimental features", isOn: Binding(
          get: { store.experimentalFeaturesEnabled },
          set: { store.experimentalFeaturesEnabled = $0 }
        ))
      } header: {
        Label("Experimental", systemImage: "flask")
      } footer: {
        SettingsFooterText("Try features still in development, including Paste as Org in the Source editor and the bundled agent in AI Chat. Applies to all workspaces on this Mac. Turning this off stops an active bundled agent turn.")
      }
      OpenOrgUsageLogSettingsSection(log: store.usageLog)
      Section {
        Toggle("Send launch telemetry", isOn: $telemetry.enabled)
      } header: {
        Label("Telemetry", systemImage: "chart.bar")
      } footer: {
        SettingsFooterText("Help us understand Celorga usage. Each app launch sends the app version, macOS version, and CPU architecture to Scarf. Scarf receives your network address to process the request. No notes, chats, file paths, or installation identifiers are sent. Enabled by default; turning this off applies to all workspaces on this Mac.")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 620)
    .frame(minHeight: 460)
    .onAppear(perform: loadCorpusInfo)
    .onChange(of: store.corpusRoot?.standardizedFileURL.path) {
      loadCorpusInfo()
    }
    .onChange(of: store.activeCorpusIdentity) {
      loadCorpusInfo()
    }
  }

  private func loadCorpusInfo() {
    corpusName = store.activeCorpusIdentity?.name
      ?? store.corpusRoot?.lastPathComponent
      ?? ""
    corpusKind = store.activeCorpusIdentity?.kind ?? "personal"
  }

  private var scheduler: AutomationSchedulerOwnershipPresentation {
    AutomationSchedulerOwnershipPresentation(
      ownerHostRef: store.automationOwnerHostRef,
      currentHostRef: store.automationHostRef,
      corpusName: store.activeCorpusIdentity?.name
        ?? store.corpusRoot?.lastPathComponent
    )
  }
}

private struct MeetingSettingsView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var meetingAutomationEnabled = false
  @State private var meetingAutomationDestinationID = AIChatDestinationConfiguration.openClawID
  @State private var meetingAutomationThreadMode = MeetingReadyAutomationThreadMode.newThread
  @State private var meetingAutomationThreadID: UUID?
  @State private var meetingAutomationPrompt = MeetingReadyAutomationSettings.defaultPrompt

  var body: some View {
    Form {
      Section {
        MeetingTranscriptionSettingsView()
      } header: {
        Label("Meeting Transcription", systemImage: "waveform.badge.mic")
      } footer: {
        SettingsFooterText("These settings apply to recorded and imported meetings. Automatic prefers local Whisper and falls back to macOS Speech when necessary.")
      }

      Section {
        Toggle("Process every completed meeting", isOn: $meetingAutomationEnabled)

        if meetingAutomationEnabled {
          Picker("Send to", selection: $meetingAutomationDestinationID) {
            ForEach(store.enabledAIChatDestinations) { destination in
              Text(destination.title).tag(destination.id)
            }
          }

          Picker("Thread", selection: $meetingAutomationThreadMode) {
            ForEach(MeetingReadyAutomationThreadMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }

          if meetingAutomationThreadMode == .existingThread {
            Picker("Target thread", selection: $meetingAutomationThreadID) {
              Text("Choose a thread").tag(UUID?.none)
              ForEach(store.meetingReadyAutomationThreads(destinationID: meetingAutomationDestinationID)) { thread in
                Text(thread.title + (thread.isSettled ? " (settled)" : ""))
                  .tag(Optional(thread.id))
              }
            }
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("Processing prompt")
              .font(.callout.weight(.medium))
            TextEditor(text: $meetingAutomationPrompt)
              .font(.body)
              .frame(minHeight: 90)
              .overlay {
                RoundedRectangle(cornerRadius: 6)
                  .stroke(.separator, lineWidth: 1)
              }
          }
        }

        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(store.meetingReadyAutomationStatusText)
              .font(.callout)
              .foregroundStyle(meetingAutomationStatusColor)
            Text("Only successful transcriptions completed by this Mac after automation is enabled are queued. Opening, refreshing, or relaunching with existing meetings never triggers it.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
          Button("Save Automation") {
            saveMeetingAutomation()
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.corpusRoot == nil)
        }
      } header: {
        Label("Meeting Automation", systemImage: "calendar.badge.clock")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 620)
    .frame(minHeight: 460)
    .onAppear {
      loadMeetingAutomation()
    }
    .onChange(of: store.corpusRoot?.standardizedFileURL.path) {
      loadMeetingAutomation()
    }
    .onChange(of: meetingAutomationDestinationID) { _, destinationID in
      guard meetingAutomationThreadMode == .existingThread else { return }
      if !store.meetingReadyAutomationThreads(destinationID: destinationID)
        .contains(where: { $0.id == meetingAutomationThreadID }) {
        meetingAutomationThreadID = nil
      }
    }
  }

  private var meetingAutomationStatusColor: Color {
    if store.meetingReadyAutomationStatusText.hasPrefix("Meeting delivery pending")
      || store.meetingReadyAutomationStatusText.hasPrefix("Meeting delivery needs attention") {
      return .orange
    }
    return .secondary
  }

  private func loadMeetingAutomation() {
    let settings = store.meetingReadyAutomationSettings
    meetingAutomationEnabled = settings.isEnabled
    meetingAutomationDestinationID = settings.destinationID
    meetingAutomationThreadMode = settings.threadMode
    meetingAutomationThreadID = settings.threadID
    meetingAutomationPrompt = settings.prompt
  }

  private func saveMeetingAutomation() {
    _ = store.saveMeetingReadyAutomationConfiguration(
      isEnabled: meetingAutomationEnabled,
      destinationID: meetingAutomationDestinationID,
      threadMode: meetingAutomationThreadMode,
      threadID: meetingAutomationThreadID,
      prompt: meetingAutomationPrompt
    )
  }
}

private struct DocumentSettingsView: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    @Bindable var store = store
    Form {
      Section {
        Toggle(
          "Expand property drawers by default",
          isOn: $store.propertyDrawersExpandedByDefault
        )

        Text("Controls the initial presentation of property drawers in rendered documents. You can still expand or collapse individual drawers while reading.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Rendered Documents", systemImage: "doc.text.magnifyingglass")
      }

      Section {
        Toggle("Format Org files on save", isOn: $store.formatOrgFilesOnSave)

        Text("Runs the shared Celorga formatter before saving a full .org page. Turn this off to preserve layout as typed; .org typing conveniences such as code fences are still saved as standard Org syntax.")
          .font(.callout)
          .foregroundStyle(.secondary)

        Toggle("Vim mode", isOn: $store.sourceEditorVimModeEnabled)

        Text("Edits files in the Source, Split, and Prose editors with Vim keybindings: Normal, Insert, Visual (character, line, and block), and Replace modes, operators and text objects, counts, registers, macros, marks, search, and : commands such as :w and :s. Keys follow your keyboard layout. ⌘ shortcuts keep working.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Source Editing", systemImage: "text.cursor")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 560)
    .frame(minHeight: 460)
  }
}

private struct SharingSettingsView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isConfirmingStopAll = false

  var body: some View {
    Form {
      OpenOrgServerSettingsSection()

      if !store.openOrgServer.sortedThreadShares.isEmpty {
        Section {
          ForEach(store.openOrgServer.sortedThreadShares) { share in
            serverShareRow(share)
          }
        } header: {
          Label("Links Hosted by \(store.openOrgServer.serverName)", systemImage: "server.rack")
        } footer: {
          SettingsFooterText("The server renders these pages from its own synced copy of the corpus, so they stay live while this Mac sleeps.")
        }
      }

      Section {
        if store.localDocumentPublications.isEmpty {
          ContentUnavailableView(
            "No Active Local Links",
            systemImage: "network.slash",
            description: Text("Publish a document to Local Link or share an AI chat thread and it will appear here while Celorga is hosting it.")
          )
          .frame(maxWidth: .infinity, minHeight: 180)
        } else {
          ForEach(store.localDocumentPublications) { publication in
            publicationRow(publication)
          }
        }
      } header: {
        Label("Active Local Links", systemImage: "network")
      } footer: {
        SettingsFooterText("Document links serve sealed exports. Chat thread links show the conversation and update as new messages arrive. Neither exposes source files or corpus access. Links stop working when Celorga quits or when you stop hosting them here. While Tailscale is connected, links use this Mac’s Tailscale address.")
      }

      if !store.localDocumentPublications.isEmpty {
        Section {
          Button("Stop Hosting All", role: .destructive) {
            isConfirmingStopAll = true
          }
        }
      }

      Section {
        Label("Local links use unencrypted HTTP and an unguessable bearer URL. Share them only over a trusted local or private network.", systemImage: "lock.open.trianglebadge.exclamationmark")
          .foregroundStyle(.orange)
      } header: {
        Label("Local Link Security", systemImage: "lock.shield")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 620)
    .frame(minHeight: 460)
    .task {
      await store.refreshLocalDocumentPublicationURLs()
    }
    .confirmationDialog(
      "Stop hosting every local publication?",
      isPresented: $isConfirmingStopAll
    ) {
      Button("Stop Hosting All", role: .destructive) {
        store.revokeAllLocalDocumentPublications()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every active link will stop working immediately. You can publish the files again later with new links.")
    }
  }

  private func publicationRow(_ publication: LocalDocumentPublication) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: publication.chatThreadID != nil ? "text.bubble" : publication.format?.systemImage ?? "doc")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(publication.title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(publication.chatThreadID != nil ? "Live Chat Thread" : publication.format?.title ?? publication.mediaType)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }

        if let sourcePath = publication.sourcePath {
          Text(abbreviatedPath(sourcePath))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        }

        Text(publication.url.absoluteString)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .textSelection(.enabled)

        Text("Hosted \(publication.createdAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: 8)

      HStack(spacing: 8) {
        Button {
          NSWorkspace.shared.open(publication.openURL)
        } label: {
          Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(.borderless)
        .help("Open shareable link")

        Button {
          copyToPasteboard(publication.url.absoluteString)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy link")

        Button(role: .destructive) {
          store.revokeLocalDocumentPublication(publication.id)
        } label: {
          Image(systemName: "stop.circle")
        }
        .buttonStyle(.borderless)
        .help("Stop hosting")
      }
    }
    .padding(.vertical, 5)
  }

  private func serverShareRow(_ share: OpenOrgServerThreadShare) -> some View {
    let title = store.aiChatThreads.first(where: { $0.id == share.threadID })?.title ?? "AI Chat Thread"
    return HStack(alignment: .top, spacing: 12) {
      Image(systemName: "text.bubble")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.callout.weight(.semibold))
          .lineLimit(1)
        Text(share.url.absoluteString)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .textSelection(.enabled)
        Text("Shared \(share.sharedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      Spacer(minLength: 8)

      HStack(spacing: 8) {
        Button {
          NSWorkspace.shared.open(share.url)
        } label: {
          Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(.borderless)
        .help("Open shareable link")

        Button {
          copyToPasteboard(share.url.absoluteString)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy link")

        Button(role: .destructive) {
          Task { await store.stopSharingChatThreadOnServer(share.threadID) }
        } label: {
          Image(systemName: "stop.circle")
        }
        .buttonStyle(.borderless)
        .disabled(store.openOrgServer.isBusy(share.threadID))
        .help("Stop sharing from the server")
      }
    }
    .padding(.vertical, 5)
  }

  private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}

/// Pairs this Mac with a headless OpenOrg server and picks where new thread
/// links are hosted by default.
private struct OpenOrgServerSettingsSection: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var endpointDraft = ""
  @State private var codeDraft = ""
  @State private var pairingError: String?
  @State private var isConfirmingForget = false

  var body: some View {
    let server = store.openOrgServer
    Section {
      if let pairing = server.pairing {
        LabeledContent("Server") {
          Text(server.serverName)
        }
        LabeledContent("Address") {
          Text(pairing.endpoint)
            .font(.callout.monospaced())
            .textSelection(.enabled)
        }
        LabeledContent("Status") {
          HStack(spacing: 6) {
            switch server.reachability {
            case .checking:
              ProgressView().controlSize(.small)
              Text("Checking…")
            case .online:
              Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green)
              Text(onlineDetail(server))
            case .offline(let reason):
              Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.orange)
              Text(reason).lineLimit(2)
            case .unknown:
              Text("Not checked")
            }
          }
          .foregroundStyle(.secondary)
        }
        HStack {
          Button("Check Connection") {
            Task { await server.refreshStatus() }
          }
          .disabled(server.reachability == .checking)
          Spacer()
          Button("Forget Server…", role: .destructive) {
            isConfirmingForget = true
          }
        }
      } else {
        TextField("Server address or pairing link", text: $endpointDraft, prompt: Text("http://100.x.y.z:48922"))
          .textFieldStyle(.roundedBorder)
          .onChange(of: endpointDraft) { _, value in
            if let input = OpenOrgServerPairingInput.parse(value), let code = input.code {
              codeDraft = code
            }
          }
        HStack {
          TextField("Pairing code", text: $codeDraft, prompt: Text("6-digit code"))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 160)
            .onSubmit { Task { await pair() } }
          Spacer()
          Button {
            Task { await pair() }
          } label: {
            if server.isPairing {
              HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Pairing")
              }
            } else {
              Text("Pair")
            }
          }
          .disabled(server.isPairing || endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let pairingError {
          Text(pairingError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Picker("Share new thread links from", selection: Binding(
        get: { server.effectiveDefaultShareLocation },
        set: { server.setDefaultShareLocation($0) }
      )) {
        Text("This Mac").tag(ChatThreadShareLocation.thisMac)
        Text(server.isPaired ? server.serverName : "Celorga Server")
          .tag(ChatThreadShareLocation.server)
          .selectionDisabled(!server.isPaired)
      }
    } header: {
      Label("Celorga Server", systemImage: "server.rack")
    } footer: {
      SettingsFooterText(server.isPaired
        ? "The server hosts thread links from its synced copy of the corpus on its Tailscale address. You can still pick a location each time you share."
        : "Run “celorga server pair” on the server, then paste the pairing link or enter its address and code here. Both machines must be on the same tailnet. The access token is stored in this Mac’s Keychain.")
    }
    .task {
      if server.isPaired, server.reachability == .unknown {
        await server.refreshStatus()
      }
    }
    .confirmationDialog(
      "Forget \(server.serverName)?",
      isPresented: $isConfirmingForget
    ) {
      Button("Forget Server", role: .destructive) {
        Task { await server.unpair() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Celorga stops the thread links this server hosts, revokes this Mac’s access on the server when it is reachable, and removes the pairing.")
    }
  }

  private func onlineDetail(_ server: OpenOrgServerConnection) -> String {
    guard let status = server.serverStatus else { return "Connected" }
    if status.supportsThreadSharing != true {
      return "Connected · update the server to host thread links"
    }
    return status.corpusName.map { "Connected · \($0)" } ?? "Connected"
  }

  private func pair() async {
    pairingError = nil
    do {
      try await store.openOrgServer.pair(
        endpointText: endpointDraft,
        code: codeDraft,
        deviceName: Host.current().localizedName ?? "Mac"
      )
      endpointDraft = ""
      codeDraft = ""
    } catch {
      pairingError = error.localizedDescription
    }
  }
}

private struct MobileRemoteSettingsView: View {
  @EnvironmentObject private var remote: MobileRemoteCoordinator
  @State private var hostDraft = ""
  @State private var pushTeamIDDraft = ""
  @State private var pushKeyIDDraft = ""
  @State private var isImportingPushKey = false

  var body: some View {
    Form {
      Section {
        Toggle("Allow Celorga for iOS to connect", isOn: Binding(
          get: { remote.isEnabled },
          set: { remote.setEnabled($0) }
        ))

        HStack {
          TextField("100.x.y.z", text: $hostDraft)
            .textFieldStyle(.roundedBorder)
            .onSubmit { remote.setBindHost(hostDraft) }
          Button("Use Detected") {
            remote.useDetectedTailscaleAddress()
            hostDraft = remote.bindHost
          }
          Button("Apply") {
            remote.setBindHost(hostDraft)
          }
          .disabled(hostDraft.trimmingCharacters(in: .whitespacesAndNewlines) == remote.bindHost)
        }

        LabeledContent("Port", value: String(MobileRemoteProtocol.defaultPort))
        LabeledContent("Status", value: remote.statusText)

        Text("The listener binds only to this Mac’s Tailscale IPv4 address. Tailscale encrypts the connection; pairing credentials authorize the phone.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Tailscale Connection", systemImage: "network")
      }

      Section {
        Button("Create Pairing Code") {
          remote.generatePairingCode()
        }
        .disabled(!remote.isEnabled || !remote.isListening || remote.endpoint == nil)

        if let code = remote.pairingCode,
           let payload = remote.pairingPayload {
          HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
              Text(code)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
              if let expiration = remote.pairingExpirationText {
                Text("Expires at \(expiration) and works once.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Button("Copy Pairing Details") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(payload, forType: .string)
              }
            }
            Spacer(minLength: 0)
            if let image = pairingQRCode(payload) {
              Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 132, height: 132)
                .accessibilityLabel("Mobile Remote pairing QR code")
            }
          }
          .padding(.vertical, 6)
        } else {
          Text("Open Remote on the iPhone, then scan the one-time code created here.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } header: {
        Label("Pair iPhone", systemImage: "qrcode")
      }

      Section {
        TextField("Apple Team ID", text: $pushTeamIDDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { remote.setPushTeamID(pushTeamIDDraft) }
        TextField("APNs Key ID", text: $pushKeyIDDraft)
          .textFieldStyle(.roundedBorder)
          .onSubmit { remote.setPushKeyID(pushKeyIDDraft) }

        HStack {
          Button("Apply IDs") {
            remote.setPushTeamID(pushTeamIDDraft)
            remote.setPushKeyID(pushKeyIDDraft)
          }
          Button("Import APNs Key…") {
            isImportingPushKey = true
          }
          if remote.pushProviderConfigured {
            Button("Remove Key", role: .destructive) {
              remote.clearPushPrivateKey()
            }
          }
        }

        LabeledContent("Status", value: remote.pushStatusText)
        Text("The APNs authentication key is stored only in this Mac’s Keychain. Celorga sends a real-time push directly to Apple when an AI reply completes; the key and device token are never written to the corpus.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Real-time Reply Notifications", systemImage: "bell.badge")
      }

      Section {
        if remote.pairedDevices.isEmpty {
          Text("No paired mobile devices")
            .foregroundStyle(.secondary)
        } else {
          ForEach(remote.pairedDevices) { device in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if let registeredAt = device.pushRegisteredAt {
                  Text("Push active · registered \(registeredAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.green)
                }
              }
              Spacer()
              Button("Revoke", role: .destructive) {
                remote.revoke(device)
              }
            }
          }
          Button("Revoke All Devices", role: .destructive) {
            remote.revokeAllDevices()
          }
        }
      } header: {
        Label("Paired Devices", systemImage: "lock.shield")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .onAppear {
      hostDraft = remote.bindHost
      pushTeamIDDraft = remote.pushTeamID
      pushKeyIDDraft = remote.pushKeyID
    }
    .onChange(of: remote.bindHost) { _, value in
      hostDraft = value
    }
    .onChange(of: remote.pushTeamID) { _, value in
      pushTeamIDDraft = value
    }
    .onChange(of: remote.pushKeyID) { _, value in
      pushKeyIDDraft = value
    }
    .fileImporter(
      isPresented: $isImportingPushKey,
      allowedContentTypes: [.data],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      guard let data = try? Data(contentsOf: url) else { return }
      remote.importPushPrivateKey(data)
    }
  }

  private func pairingQRCode(_ payload: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(payload.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
      return nil
    }
    let representation = NSCIImageRep(ciImage: output)
    let image = NSImage(size: representation.size)
    image.addRepresentation(representation)
    return image
  }
}
