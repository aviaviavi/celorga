import Org2WorkspaceCore
import SwiftUI

struct AIChatSettingsView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var destinationEditor: AIChatDestinationEditorPresentation?
  @State private var destinationPendingDeletion: AIChatDestinationConfiguration?

  var body: some View {
    @Bindable var store = store
    Form {
      Section {
        Picker("Corpus access", selection: $store.aiChatCorpusAccessScope) {
          Text("Current Corpus").tag(WorkspaceReadScope.activeCorpus)
          Text("All Loaded Corpora").tag(WorkspaceReadScope.allCorpora)
        }
        .pickerStyle(.radioGroup)

        Text(corpusAccessHelp)
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("AI Chat Context", systemImage: "text.bubble")
      }

      Section {
        ForEach(store.aiChatDestinations) { destination in
          HStack(spacing: 10) {
            Image(systemName: destination.systemImage)
              .frame(width: 22)
              .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
              Text(destination.title)
                .font(.body.weight(.medium))
              Text("@\(destination.mention) · \(destination.adapterTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") {
              destinationEditor = AIChatDestinationEditorPresentation(
                destination: destination,
                isNew: false
              )
            }
            Button("Delete", role: .destructive) {
              destinationPendingDeletion = destination
            }
          }
        }

        HStack {
          Menu {
            ForEach(addableDestinationAdapters) { adapter in
              Button {
                destinationEditor = AIChatDestinationEditorPresentation(
                  destination: store.makeAIChatDestinationDraft(adapter: adapter),
                  isNew: true
                )
              } label: {
                Label(adapter.title, systemImage: adapter.systemImage)
              }
            }
            ForEach(AIChatProviderPreset.allCases) { preset in
              Button {
                destinationEditor = AIChatDestinationEditorPresentation(
                  destination: store.makeAIChatDestinationDraft(preset: preset),
                  isNew: true
                )
              } label: {
                Label(preset.title, systemImage: preset.systemImage)
              }
            }
          } label: {
            Label("Add Destination", systemImage: "plus")
          }
          Spacer()
          Text("Configured destinations are available in new chats.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let error = store.aiChatDestinationSettingsError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
        }
      } header: {
        Label("AI Destinations", systemImage: "point.3.connected.trianglepath.dotted")
      }

      Section {
        Picker("Run new agent work with", selection: Binding(
          get: { store.defaultRunDestinationID ?? "" },
          set: { store.defaultRunDestinationID = $0.isEmpty ? nil : $0 }
        )) {
          Text(store.enabledAIChatDestinations.first.map { "First enabled destination (\($0.title))" }
            ?? "First enabled destination").tag("")
          ForEach(store.enabledAIChatDestinations) { destination in
            Text(destination.title).tag(destination.id)
          }
          if let id = store.defaultRunDestinationID,
             !store.enabledAIChatDestinations.contains(where: { $0.id == id }) {
            Text("\(store.aiChatDestinationTitle(id)) (unavailable)").tag(id)
          }
        }
        Text("Start Work and automations without their own destination run here. Resuming a run, answering its question, or approving its work returns it to the agent that created it or last worked on it; this agent is used only when the run records none.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Agent Work", systemImage: "checklist")
      }

      Section {
        Picker("Filesystem access", selection: $store.codexSandboxAccess) {
          ForEach(CodexSandboxAccess.allCases) { access in
            Text(access.title).tag(access)
          }
        }
        .pickerStyle(.radioGroup)

        Text(localAgentAccessHelp)
          .font(.callout)
          .foregroundStyle(store.codexSandboxAccess == .fullAccess ? Color.orange : Color.secondary)
      } header: {
        Label("Local Agent Permissions", systemImage: "lock.shield")
      }

      Section {
        Picker("Run new agent turns on", selection: Binding(
          get: { store.aiChatPreferredExecutionHostRef ?? "" },
          set: { store.aiChatPreferredExecutionHostRef = $0.isEmpty ? nil : $0 }
        )) {
          Text("This Mac").tag("")
          ForEach(store.aiChatExecutionHostCandidates, id: \.hostRef) { host in
            Text(host.hostKind == .server ? "\(host.hostName) (server)" : host.hostName).tag(host.hostRef)
          }
          if let preferred = store.aiChatPreferredExecutionHostRef,
             !store.aiChatExecutionHostCandidates.contains(where: { $0.hostRef == preferred }) {
            Text("\(preferred) (offline)").tag(preferred)
          }
        }
        Text("A headless Celorga server can own conversations this Mac would run, so quitting, sleeping, or updating Celorga never interrupts a turn. This Mac shows the server's live progress and takes over automatically whenever the server is offline, restarting, or lacks the conversation's destination. Local agents then run on the server's machine with its files and permissions.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Execution", systemImage: "server.rack")
      }

      Section {
        Toggle("Start node briefs in a new chat thread", isOn: $store.aiChatBriefsStartNewThread)
        Picker("Settle inactive threads", selection: Binding(
          get: { store.aiChatThreadSettlementSettings.interval },
          set: { store.setAIChatAutoSettleInterval($0) }
        )) {
          ForEach(AIChatAutoSettleInterval.allCases) { interval in
            Text(interval.title).tag(interval)
          }
        }
        Text("Selected, pinned, unread, pending, or currently failed/interrupted threads stay active.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Picker("Agent turns in a row", selection: $store.aiChatDefaultRoomAgentTurnLimit) {
          ForEach(
            AIChatThread.roomAgentTurnLimitOptions(including: store.aiChatDefaultRoomAgentTurnLimit),
            id: \.self
          ) { limit in
            Text(AIChatThread.roomAgentTurnLimitTitle(limit)
              + (limit == AIChatThread.defaultRoomAgentTurnLimit ? " (default)" : "")
            ).tag(limit)
          }
        }
        .accessibilityIdentifier("ai-chat-settings-room-agent-turn-limit")
        Text("In shared rooms, how many turns agents can start for each other by @mentioning before you need to reply. A room can choose its own limit from its Default menu.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Picker("Check synced chat history", selection: $store.aiChatRepairIntervalSeconds) {
          ForEach(AIChatTranscriptRepair.intervalChoices, id: \.self) { seconds in
            Text(AIChatTranscriptRepair.intervalTitle(seconds)).tag(seconds)
          }
          if !AIChatTranscriptRepair.intervalChoices.contains(store.aiChatRepairIntervalSeconds) {
            Text(AIChatTranscriptRepair.intervalTitle(store.aiChatRepairIntervalSeconds))
              .tag(store.aiChatRepairIntervalSeconds)
          }
        }
        Text("Checks and reconciles synced chat history without AI. Longer intervals reduce background work.")
          .font(.callout)
          .foregroundStyle(.secondary)
        if let error = store.aiChatRepairError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } header: {
        Label("Conversations", systemImage: "bubble.left.and.bubble.right")
      }

      Section {
        HStack(spacing: 12) {
          Picker("Message sound", selection: $store.aiChatMessageSound) {
            ForEach(AIChatMessageSound.allCases) { sound in
              Text(sound.displayName).tag(sound)
            }
          }
          .onChange(of: store.aiChatMessageSound) {
            store.previewAIChatMessageSound()
          }

          Button {
            store.previewAIChatMessageSound()
          } label: {
            Label("Preview", systemImage: "speaker.wave.2")
          }
          .disabled(store.aiChatMessageSound == .off)
        }

        Text("Plays when an AI reply arrives, including for the thread currently open.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Notifications", systemImage: "bell")
      }

      Section {
        TextEditor(text: $store.aiChatCustomInstructions)
          .font(.body)
          .frame(minHeight: 150)
          .overlay {
            RoundedRectangle(cornerRadius: 6)
              .stroke(.separator, lineWidth: 1)
          }

        Text("These instructions are included with every new AI chat turn for OpenClaw, Codex, Claude Code, Pi, and OpenCode.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } header: {
        Label("Custom Instructions", systemImage: "text.alignleft")
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 620)
    .frame(minHeight: 560)
    .task { await store.refreshCodexAccount() }
    .sheet(item: $destinationEditor) { presentation in
      AIChatDestinationEditor(
        destination: presentation.destination,
        isNew: presentation.isNew
      )
        .environment(store)
    }
    .confirmationDialog(
      "Delete \(destinationPendingDeletion?.title ?? "Destination")?",
      isPresented: Binding(
        get: { destinationPendingDeletion != nil },
        set: { if !$0 { destinationPendingDeletion = nil } }
      ),
      presenting: destinationPendingDeletion
    ) { destination in
      Button("Delete Destination", role: .destructive) {
        _ = store.removeAIChatDestination(destination.id)
        destinationPendingDeletion = nil
      }
      Button("Cancel", role: .cancel) {
        destinationPendingDeletion = nil
      }
    } message: { destination in
      Text("@\(destination.mention) will no longer be available for new chats. A destination used by an existing chat cannot be deleted.")
    }
  }

  private var corpusAccessHelp: String {
    switch store.aiChatCorpusAccessScope {
    case .activeCorpus:
      return "Chat can read only the current corpus. Writes remain scoped to that corpus."
    case .allCorpora:
      let count = max(store.mountedCorpora.count, store.corpusRoot == nil ? 0 : 1)
      return "Chat can read all \(count) loaded \(count == 1 ? "corpus" : "corpora"). Only the current corpus can be changed."
    }
  }

  private var addableDestinationAdapters: [AIChatDestinationAdapter] {
    AIChatDestinationAdapter.allCases.filter { adapter in
      switch adapter {
      case .codexLocal, .claudeLocal, .piLocal, .openCodeLocal:
        return !store.aiChatDestinations.contains(where: { $0.adapter == adapter })
      case .piRemote, .openCodeRemote, .codexManagedRemote,
           .openClaw, .openAI, .anthropic, .openRouter, .ollama, .openAIDot:
        return true
      case .codexRemote:
        return false
      }
    }
  }

  private var localAgentAccessHelp: String {
    switch store.codexSandboxAccess {
    case .readOnly:
      return "Local coding harnesses can inspect files. Claude Code runs in Plan mode, Pi and OpenCode receive read-only tools, and Codex uses Celorga's reviewed edit tools for corpus changes."
    case .workspaceWrite:
      return "Local and SSH coding harnesses can edit through their native tools in the configured corpus workspace."
    case .fullAccess:
      return "Coding harnesses receive full tool access. Celorga does not show approval prompts in this mode; use it only for trusted threads. The change applies on the next turn, including in an existing thread."
    }
  }

}

private struct AIChatDestinationEditorPresentation: Identifiable {
  let destination: AIChatDestinationConfiguration
  let isNew: Bool

  var id: String {
    "\(isNew ? "new" : "existing")-\(destination.id)"
  }
}

private struct AIChatDestinationEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(WorkspaceStore.self) private var store
  @State private var destination: AIChatDestinationConfiguration
  @State private var token = ""
  @State private var clearsSavedToken = false
  @State private var isTestingConnection = false
  @State private var connectionStatus: String?
  @State private var isShowingOpenClawGateway = false
  @State private var isConfirmingDeletion = false
  private let isNew: Bool

  init(destination: AIChatDestinationConfiguration, isNew: Bool) {
    _destination = State(initialValue: destination)
    self.isNew = isNew
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("AI Destination", systemImage: destination.systemImage)
          .font(.title3.weight(.semibold))
        Spacer()
      }

      if destination.adapter == .codexLocal {
        codexAccountSection
      }

      Form {
        TextField("Name", text: $destination.name)
        TextField("Mention", text: $destination.mention, prompt: Text("codex-remote"))
          .textContentType(.username)

        Picker("Adapter", selection: $destination.adapter) {
          ForEach(visibleAdapters) { adapter in
            Text(adapter.title).tag(adapter)
          }
        }
        .disabled(isBuiltIn)
        .onChange(of: destination.adapter) { oldAdapter, newAdapter in
          if destination.endpoint.isEmpty || destination.endpoint == oldAdapter.defaultEndpoint {
            destination.endpoint = newAdapter.defaultEndpoint
          }
          destination.model = nil
          connectionStatus = nil
        }

        if isBuiltInOpenClaw {
          Button {
            isShowingOpenClawGateway = true
          } label: {
            Label("Configure Gateway…", systemImage: "network")
          }
        }

        if destination.adapter == .codexRemote {
          TextField(
            "WebSocket endpoint",
            text: $destination.endpoint,
            prompt: Text("wss://codex-host.example/ws")
          )
          TextField(
            "Corpus workspace on that machine",
            text: $destination.workspaceRoot,
            prompt: Text("/home/user/notes")
          )
        } else if destination.adapter == .codexManagedRemote {
          TextField(
            "Codex SSH host",
            text: $destination.endpoint,
            prompt: Text("scarfs-macbook-air")
          )
          TextField(
            "Corpus workspace on that machine",
            text: $destination.workspaceRoot,
            prompt: Text("~/notes")
          )
        } else if destination.adapter == .piRemote || destination.adapter == .openCodeRemote {
          TextField(
            "SSH host",
            text: $destination.endpoint,
            prompt: Text("press.local")
          )
          TextField(
            "Corpus workspace on that machine",
            text: $destination.workspaceRoot,
            prompt: Text("~/notes")
          )
          TextField(
            "Model (optional)",
            text: Binding(
              get: { destination.model ?? "" },
              set: { destination.model = $0 }
            ),
            prompt: Text("provider/model")
          )
        } else if destination.adapter == .piLocal || destination.adapter == .openCodeLocal {
          TextField(
            "Model (optional)",
            text: Binding(
              get: { destination.model ?? "" },
              set: { destination.model = $0 }
            ),
            prompt: Text("provider/model")
          )
        } else if destination.adapter == .openClaw && !isBuiltInOpenClaw {
          TextField(
            "Gateway endpoint",
            text: $destination.endpoint,
            prompt: Text("https://host/v1/chat/completions")
          )
          TextField("Agent ID", text: $destination.agentID, prompt: Text("main"))
        } else if destination.adapter.isDirectProvider {
          TextField(
            "API base URL",
            text: $destination.endpoint,
            prompt: Text(destination.adapter.defaultEndpoint)
          )
          TextField(
            "Model",
            text: Binding(
              get: { destination.model ?? "" },
              set: { destination.model = $0 }
            ),
            prompt: Text("Provider model ID")
          )
        } else if destination.adapter == .openAIDot {
          TextField(
            "Dot (optional)",
            text: $destination.agentID,
            prompt: Text("Primary dot")
          )
          Text("To follow the dot’s whole ChatGPT conversation in one chat, choose its “Open … Conversation” item in AI chat’s New menu.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if destination.acceptsBearerToken && !isBuiltInOpenClaw {
          SecureField(
            credentialLabel,
            text: $token,
            prompt: Text(credentialPrompt)
          )
          if hasSavedToken {
            Toggle("Clear saved token", isOn: $clearsSavedToken)
          }
        }

        if destination.adapter.isDirectProvider {
          if store.experimentalFeaturesEnabled {
            Toggle("Workspace tools (experimental)", isOn: Binding(
              get: { destination.workspaceToolsEnabled == true },
              set: { destination.workspaceToolsEnabled = $0 }
            ))
            Text("Use Celorga’s built-in agent to search, read, and propose edits. You review each patch before it is applied. Requires a model that supports tools; text only.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if destination.adapter.isDirectProvider || destination.adapter == .openAIDot {
          HStack(spacing: 10) {
            Button("Test Connection") {
              testConnection()
            }
            .disabled(isTestingConnection || missingRequiredCredential)
            if isTestingConnection {
              ProgressView()
                .controlSize(.small)
            }
            if let connectionStatus {
              Text(connectionStatus)
                .font(.caption)
                .foregroundStyle(connectionStatus.hasPrefix("Connected") ? Color.secondary : Color.red)
            }
          }
        }
      }
      .formStyle(.grouped)

      Text(helpText)
        .font(.callout)
        .foregroundStyle(.secondary)

      if let error = store.aiChatDestinationSettingsError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
      }

      HStack {
        if !isNew {
          Button("Delete Destination…", role: .destructive) {
            isConfirmingDeletion = true
          }
        }
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Save") {
          destination.isEnabled = true
          store.updateAIChatDestination(destination)
          if clearsSavedToken {
            store.saveAIChatDestinationToken("", destinationID: destination.id)
          } else if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.saveAIChatDestinationToken(token, destinationID: destination.id)
          }
          if store.aiChatDestinationSettingsError == nil {
            dismiss()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(saveIsDisabled)
      }
    }
    .padding(20)
    .frame(width: 520)
    .sheet(isPresented: $isShowingOpenClawGateway) {
      OpenClawGatewayConfigurationSheet()
        .environment(store)
    }
    .confirmationDialog(
      "Delete \(destination.title)?",
      isPresented: $isConfirmingDeletion
    ) {
      Button("Delete Destination", role: .destructive) {
        if store.removeAIChatDestination(destination.id) {
          dismiss()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("@\(destination.mention) will no longer be available for new chats. A destination used by an existing chat cannot be deleted.")
    }
  }

  private var codexAccountSection: some View {
    GroupBox {
      HStack(alignment: .center, spacing: 12) {
        Image(systemName: AIChatRuntime.codex.systemImage)
          .font(.title3)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text("Codex")
            .font(.callout.weight(.medium))
          Text(store.codexAccountState.label)
            .font(.caption)
            .foregroundStyle(
              store.codexAccountState.isReady ? Color.secondary : Color.orange
            )
            .lineLimit(2)
        }
        Spacer(minLength: 12)
        Button {
          Task {
            await store.beginCodexChatGPTLogin()
          }
        } label: {
          if store.isCodexSigningIn {
            HStack(spacing: 6) {
              ProgressView().controlSize(.small)
              Text("Signing In")
            }
          } else {
            Text(store.codexAccountState.isReady ? "Switch ChatGPT Account…" : "Sign In with ChatGPT")
          }
        }
        .disabled(store.isCodexSigningIn)
      }
      .padding(.vertical, 4)
    } label: {
      Text("Local Codex")
    }
  }

  private var isBuiltIn: Bool {
    destination.id == AIChatDestinationConfiguration.localCodexID
      || destination.id == AIChatDestinationConfiguration.localClaudeID
      || destination.id == AIChatDestinationConfiguration.localPiID
      || destination.id == AIChatDestinationConfiguration.localOpenCodeID
      || destination.id == AIChatDestinationConfiguration.openClawID
  }

  private var isBuiltInOpenClaw: Bool {
    destination.id == AIChatDestinationConfiguration.openClawID
  }

  private var hasSavedToken: Bool {
    store.aiChatDestinationHasToken(destination.id)
  }

  private var visibleAdapters: [AIChatDestinationAdapter] {
    AIChatDestinationAdapter.allCases.filter {
      $0 != .codexRemote || destination.adapter == .codexRemote
    }
  }

  private var missingRequiredCredential: Bool {
    destination.adapter.requiresAPIKey
      && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (!hasSavedToken || clearsSavedToken)
  }

  private var saveIsDisabled: Bool {
    if destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    if destination.adapter.isDirectProvider,
       destination.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
      return true
    }
    if (destination.adapter == .codexRemote
        || destination.adapter == .codexManagedRemote
        || destination.adapter == .piRemote
        || destination.adapter == .openCodeRemote),
       destination.workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    return missingRequiredCredential
  }

  private var credentialLabel: String {
    destination.adapter.isDirectProvider ? "API key" : "Bearer token"
  }

  private var credentialPrompt: String {
    if hasSavedToken && !clearsSavedToken { return "Saved credential unchanged" }
    return destination.adapter.requiresAPIKey ? "Required" : "Optional"
  }

  private func testConnection() {
    isTestingConnection = true
    connectionStatus = nil
    let enteredToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    let apiKey = enteredToken.isEmpty
      ? AIChatDestinationCredentials.readToken(
          destinationID: destination.id,
          allowUserInteraction: true
        )
      : enteredToken
    if destination.adapter == .openAIDot {
      let endpoint = destination.endpoint
      let selector = destination.agentID
      Task {
        do {
          let client = OpenAIDotChatClient(
            settings: try OpenAIDotChatClient.Settings(endpoint: endpoint, dotSelector: selector)
          )
          let dot = try await client.resolveDot()
          connectionStatus = "Connected · \(dot.displayName)"
        } catch {
          connectionStatus = error.localizedDescription
        }
        isTestingConnection = false
      }
      return
    }
    Task {
      do {
        let settings = try AIProviderChatSettings(
          adapter: destination.adapter,
          endpoint: destination.endpoint,
          apiKey: apiKey
        )
        let models = try await AIProviderChatClient(settings: settings).listModels()
        connectionStatus = models.isEmpty
          ? "Connected · no models reported"
          : "Connected · \(models.count) \(models.count == 1 ? "model" : "models")"
      } catch {
        connectionStatus = error.localizedDescription
      }
      isTestingConnection = false
    }
  }

  private var helpText: String {
    switch destination.adapter {
    case .codexLocal:
      return "Starts a local Codex App Server process on this Mac."
    case .claudeLocal:
      return "Starts the locally installed Claude Code CLI and uses its existing Anthropic sign-in. Conversations resume through Claude Code's local session history."
    case .piLocal:
      return "Starts the locally installed Pi coding-agent CLI. Conversations resume through Pi's native session history."
    case .piRemote:
      return "Runs Pi over SSH in the configured corpus workspace. Pi must already be installed and connected to a model provider on that host."
    case .openCodeLocal:
      return "Starts the locally installed OpenCode CLI with a Celorga-specific agent configuration."
    case .openCodeRemote:
      return "Runs OpenCode over SSH in the configured corpus workspace. OpenCode must already be installed and connected to a model provider on that host."
    case .codexRemote:
      return "Connects to a Codex App Server over WebSocket. Use TLS and a bearer token outside localhost. Enter the absolute path of the writable Celorga corpus checkout on that machine; Codex edits it directly."
    case .codexManagedRemote:
      return "Attaches through SSH to Codex's managed App Server daemon. Enter the writable Celorga corpus checkout on that Mac; ~ is expanded there, and Codex edits the checkout directly without waiting for Celorga. Accepted turns survive laptop sleep and reconnect after wake."
    case .openClaw:
      return isBuiltInOpenClaw
        ? "This default destination uses the existing OpenClaw Gateway configuration."
        : "Routes turns to this OpenClaw gateway and agent ID with its own saved token."
    case .openAI where destination.providerPreset == .deepSeek:
      return "Connects directly to DeepSeek's OpenAI-compatible API with your API key, for context chat and inexpensive background work. deepseek-flash is the low-cost default; deepseek-v4-pro is also available. Reasoning effort sets DeepSeek's thinking mode."
    case .openAI:
      return "Connects directly to OpenAI with your API key for context and image chat."
    case .anthropic:
      return "Connects directly to Anthropic with your API key for context and image chat."
    case .openRouter:
      return "Connects directly to any OpenRouter model available to your API key. Enter the exact OpenRouter model ID."
    case .ollama:
      return "Connects to a local or network Ollama server. The default local endpoint needs no API key; enter the model already installed in Ollama."
    case .openAIDot:
      return "Messages your OpenAI dot in its ChatGPT conversation, using the ChatGPT sign-in Codex stores on this Mac. Leave Dot blank for your primary dot, or enter a dot’s name or ID. Text only. OpenAI hasn’t published an API for dots, so this uses private ChatGPT routes that can change without notice."
    }
  }
}
