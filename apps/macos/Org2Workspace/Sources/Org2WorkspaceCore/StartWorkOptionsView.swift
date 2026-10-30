import SwiftUI

/// Agent, harness, model, and reasoning chosen when starting work on a TODO.
/// Nil fields fall back to the harness's own defaults.
public struct StartWorkOptions: Hashable, Codable, Sendable {
  public var agentRef: String?
  public var destinationID: String?
  public var model: String?
  public var reasoningEffort: String?

  public init(
    agentRef: String? = nil,
    destinationID: String? = nil,
    model: String? = nil,
    reasoningEffort: String? = nil
  ) {
    self.agentRef = Self.normalized(agentRef)
    self.destinationID = Self.normalized(destinationID)
    self.model = Self.normalized(model)
    self.reasoningEffort = Self.normalized(reasoningEffort)
  }

  private static func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

/// Which chat receives the task.
public enum StartWorkThreadTarget: Hashable, Sendable {
  /// A fresh chat linked to the heading.
  case newThread
  /// The chat already linked to the heading.
  case taskThread(UUID)
  /// The AI chat thread that is currently selected.
  case currentThread(UUID)
}

/// A TODO waiting on the Start Work dialog.
public struct StartWorkRequest: Identifiable, Sendable {
  public let id = UUID()
  public let location: WorkspaceLocation
  public let origin: String
  public let title: String
  /// The heading's own `:AGENT_REF:`, which takes precedence over a choice.
  public let headingAgentRef: String?
  public let taskThreadID: UUID?
  public let currentThreadID: UUID?
}

/// Asks where to start work on a TODO: which agent, harness, model, and
/// reasoning effort, and whether to use a new thread or an existing one.
struct StartWorkOptionsView: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  let request: StartWorkRequest

  @State private var agentRef = ""
  @State private var destinationID = ""
  @State private var model = ""
  @State private var reasoningEffort = ""
  @State private var threadTarget: StartWorkThreadTarget = .newThread
  @State private var modelOptions: [AIChatModelOption] = []
  @State private var isLoadingModels = false
  @State private var initialAgentRef: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Start Work")
          .font(.title3.weight(.semibold))
        Text(request.title)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Form {
        Picker("Thread", selection: $threadTarget) {
          if let id = request.taskThreadID {
            Text("Task’s thread (\(threadTitle(id)))").tag(StartWorkThreadTarget.taskThread(id))
          }
          Text("New thread").tag(StartWorkThreadTarget.newThread)
          if let id = request.currentThreadID {
            Text("Current thread (\(threadTitle(id)))").tag(StartWorkThreadTarget.currentThread(id))
          }
        }

        Picker("Agent", selection: $agentRef) {
          Text("Default assistant").tag("")
          if !store.agentProfiles.isEmpty { Divider() }
          ForEach(store.agentProfiles) { profile in
            Text(profile.name).tag(profile.id)
          }
          if !agentRef.isEmpty, !store.agentProfiles.contains(where: { $0.id == agentRef }) {
            Text(agentRef).tag(agentRef)
          }
        }
        .disabled(request.headingAgentRef != nil)
        .help(request.headingAgentRef != nil
          ? "This heading sets its own AGENT_REF."
          : "The named agent profile that owns this work.")

        Picker("Harness", selection: $destinationID) {
          ForEach(store.enabledAIChatDestinations) { destination in
            Label(destination.title, systemImage: destination.systemImage)
              .tag(destination.id)
          }
        }
        .disabled(usesExistingThread)
        .help(usesExistingThread
          ? "An existing thread keeps its harness."
          : "Where the work runs.")

        HStack {
          TextField("Model", text: $model, prompt: Text(usesExistingThread ? "Thread’s model" : "Harness default"))
          Menu {
            Button("Harness default") { model = "" }
            if !modelOptions.isEmpty { Divider() }
            ForEach(modelOptions) { option in
              Button(option.isDefault ? "\(option.label) (default)" : option.label) {
                model = option.id
              }
            }
          } label: {
            if isLoadingModels {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "chevron.up.chevron.down")
            }
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .help("Choose from the harness’s available models")
        }

        Picker("Reasoning", selection: $reasoningEffort) {
          Text(usesExistingThread ? "Thread’s setting" : "Harness default").tag("")
          Divider()
          ForEach(reasoningChoices, id: \.id) { option in
            Text(option.label).tag(option.id)
          }
        }
      }
      .formStyle(.grouped)

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Start Work") {
          store.confirmStartWork(
            request,
            options: StartWorkOptions(
              agentRef: request.headingAgentRef == nil ? agentRef : nil,
              destinationID: destinationID,
              model: model,
              reasoningEffort: reasoningEffort
            ),
            threadTarget: threadTarget
          )
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(destinationID.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear(perform: loadDefaults)
    .onChange(of: threadTarget) { _, _ in applyThreadDefaults() }
    .onChange(of: agentRef) { oldValue, newValue in
      // Like the chat composer, an agent with a preferred runtime picks it.
      guard oldValue != newValue, newValue != initialAgentRef, !usesExistingThread,
            let runtime = store.agentProfiles.first(where: { $0.id == newValue })?.preferredChatRuntime,
            let destination = store.enabledAIChatDestinations.first(where: { $0.runtime == runtime })
      else { return }
      destinationID = destination.id
    }
    .task(id: destinationID) {
      guard !destinationID.isEmpty else { return }
      isLoadingModels = true
      modelOptions = await store.nodeBriefModelOptions(forDestinationID: destinationID)
      isLoadingModels = false
    }
  }

  private var usesExistingThread: Bool {
    if case .newThread = threadTarget { return false }
    return true
  }

  private func threadTitle(_ id: UUID) -> String {
    let title = store.aiChatThreads.first(where: { $0.id == id })?.title ?? "Chat"
    return title.count > 32 ? String(title.prefix(31)) + "…" : title
  }

  private func loadDefaults() {
    let last = store.startWorkLastOptions
    agentRef = request.headingAgentRef ?? last.agentRef ?? ""
    initialAgentRef = agentRef
    threadTarget = request.taskThreadID.map(StartWorkThreadTarget.taskThread) ?? .newThread
    applyThreadDefaults()
  }

  /// A new thread starts from the last choices; an existing thread shows its
  /// own harness and leaves model/reasoning as-is unless changed.
  private func applyThreadDefaults() {
    let enabled = store.enabledAIChatDestinations
    switch threadTarget {
    case .newThread:
      // A configured run destination is the user's standing choice; without
      // one, the last Start Work choice is the default.
      let last = store.startWorkLastOptions
      let configured = store.defaultRunDestinationID.flatMap { id in
        enabled.contains(where: { $0.id == id }) ? id : nil
      }
      let candidate = configured ?? last.destinationID ?? store.defaultRunDestination?.id ?? ""
      if enabled.contains(where: { $0.id == candidate }) {
        destinationID = candidate
        let keepsLastSettings = candidate == last.destinationID
        model = keepsLastSettings ? last.model ?? "" : ""
        reasoningEffort = keepsLastSettings ? last.reasoningEffort ?? "" : ""
      } else {
        destinationID = enabled.first?.id ?? ""
        model = ""
        reasoningEffort = ""
      }
    case .taskThread(let id), .currentThread(let id):
      let thread = store.aiChatThreads.first(where: { $0.id == id })
      destinationID = thread?.destinationID ?? enabled.first?.id ?? ""
      model = ""
      reasoningEffort = ""
    }
  }

  /// Reasoning levels offered by the chosen model when known, otherwise the
  /// standard effort ladder.
  private var reasoningChoices: [AIChatReasoningOption] {
    let selectedModel = modelOptions.first(where: { $0.id == model })
      ?? (model.isEmpty ? modelOptions.first(where: \.isDefault) : nil)
    var choices = selectedModel?.reasoningOptions ?? []
    if choices.isEmpty {
      choices = NodeBriefOptionsView.standardReasoningEfforts.map {
        AIChatReasoningOption(id: $0, label: $0 == "xhigh" ? "Extra high" : $0.capitalized)
      }
    }
    if !reasoningEffort.isEmpty, !choices.contains(where: { $0.id == reasoningEffort }) {
      choices.append(AIChatReasoningOption(id: reasoningEffort, label: reasoningEffort.capitalized))
    }
    return choices
  }
}
