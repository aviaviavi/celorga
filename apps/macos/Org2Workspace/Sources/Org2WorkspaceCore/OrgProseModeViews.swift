import AppKit
import SwiftUI

enum OrgProsePresentation {
  /// The readable measure for the Prose column, in points.
  static let measure: CGFloat = 720
  static let sidebarWidth: CGFloat = 288

  static func failureDescription(_ failure: OrgProseResolutionFailure) -> String {
    switch failure {
    case .missing: "Text no longer found"
    case .ambiguous: "Matches more than one place"
    case .contextChanged: "Surrounding text changed"
    }
  }

  /// Short label shown beside an AI version.
  static func aiCaption(_ provenance: OrgProseAIProvenance?) -> String {
    guard let model = provenance?.model, !model.isEmpty else { return "AI" }
    return "AI · \(model)"
  }

  /// Full provenance for the AI version's tooltip.
  static func aiDetail(_ provenance: OrgProseAIProvenance?) -> String {
    var lines = ["Created with Revise with AI."]
    if let provider = provenance?.provider, !provider.isEmpty {
      let title = AIChatDestinationAdapter(rawValue: provider)?.title ?? provider
      lines.append("Provider: \(title)")
    }
    if let model = provenance?.model, !model.isEmpty { lines.append("Model: \(model)") }
    if let instruction = provenance?.instruction, !instruction.isEmpty {
      lines.append("Instruction: \(instruction)")
    }
    if let created = provenance?.createdAt, !created.isEmpty { lines.append("Created: \(created)") }
    return lines.joined(separator: "\n")
  }
}

struct OrgProseToolbar: View {
  @ObservedObject var controller: OrgProseEditorController
  @Binding var showsSidebar: Bool
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    let selection = controller.selectionState
    HStack(spacing: 8) {
      Button {
        controller.beginAddAlternative()
      } label: {
        Label("Add Alternative…", systemImage: "arrow.triangle.branch")
      }
      .disabled(!(selection.hasSelection || selection.isInAlternative))
      .help("Add another version of the selected text")

      Button {
        controller.beginRevision()
      } label: {
        Label("Revise with AI…", systemImage: "sparkles")
      }
      .keyboardShortcut("r", modifiers: [.control, .option])
      .disabled(!(selection.hasSelection || selection.isInAlternative) && controller.revisionJob == nil)
      .help("Revise the selection with a model you configured (Control-Option-R). The result becomes another version; the original stays recoverable.")
      .popover(item: $controller.revisionDraft, arrowEdge: .bottom) { draft in
        OrgProseRevisionPopover(
          controller: controller,
          draft: draft,
          destinations: OrgProseRevisionPreferences.candidates(from: store.aiChatDestinations)
        )
      }

      if let job = controller.revisionJob {
        ProgressView()
          .controlSize(.small)
          .help("Revising with \(job.label) (\(job.model))")
        Button {
          controller.cancelRevision()
        } label: {
          Label("Cancel Revision", systemImage: "xmark.circle")
        }
        .labelStyle(.iconOnly)
        .help("Cancel the revision. Nothing is changed.")
      }

      ControlGroup {
        Button {
          controller.cycleAlternative(-1)
        } label: {
          Label("Previous Version", systemImage: "chevron.left")
        }
        .keyboardShortcut("[", modifiers: [.control, .option])
        .help("Previous version (Control-Option-[)")

        Button {
          controller.cycleAlternative(1)
        } label: {
          Label("Next Version", systemImage: "chevron.right")
        }
        .keyboardShortcut("]", modifiers: [.control, .option])
        .help("Next version (Control-Option-])")
      }
      .labelStyle(.iconOnly)
      .disabled(selection.alternativeCount < 2)
      .fixedSize()

      Text("⌃⌥[ / ⌃⌥]")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .help("Step through versions with Control-Option-[ and Control-Option-]")

      if let index = selection.alternativeIndex {
        HStack(spacing: 3) {
          if selection.activeVariantIsAI {
            Image(systemName: "sparkles")
              .font(.caption2)
              .help("This version came from Revise with AI")
          }
          Text("\(index + 1) of \(selection.alternativeCount)")
            .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
      }

      Divider().frame(height: 18)

      Button {
        controller.ghostSelection()
      } label: {
        Label("Ghost", systemImage: "eye.slash")
      }
      .disabled(!selection.hasSelection)
      .help("Fade the selected text without deleting it")

      Button {
        controller.reviveAtSelection()
      } label: {
        Label("Revive", systemImage: "eye")
      }
      .disabled(!selection.isInGhost)
      .help("Bring ghosted text at the cursor back")

      Toggle(isOn: $controller.revealsGhosts) {
        Label("Reveal Ghosts", systemImage: "sparkle.magnifyingglass")
      }
      .toggleStyle(.button)
      .labelStyle(.iconOnly)
      .help("Show all ghosted text at reading strength")

      Divider().frame(height: 18)

      Button {
        controller.moveSelectionToOverflow()
      } label: {
        Label("Move to Overflow", systemImage: "tray.and.arrow.down")
      }
      .disabled(!selection.hasSelection)
      .help("Park the selected text in the Overflow panel")

      Toggle(isOn: $showsSidebar) {
        Label(
          "Overflow Panel",
          systemImage: "sidebar.right"
        )
      }
      .toggleStyle(.button)
      .labelStyle(.iconOnly)
      .help("Show or hide the Overflow panel")

      if let message = controller.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(controller.messageIsError ? Color.orange : Color.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(message)
      }
    }
    .buttonStyle(.borderless)
    .toggleStyle(.button)
    .controlSize(.small)
  }
}

struct OrgProseAlternativeSheet: View {
  @ObservedObject var controller: OrgProseEditorController
  let draft: OrgProseAlternativeDraft
  @State private var versionText: String

  init(controller: OrgProseEditorController, draft: OrgProseAlternativeDraft) {
    self.controller = controller
    self.draft = draft
    _versionText = State(initialValue: draft.currentText)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(draft.addsToExisting ? "Add Another Version" : "Add Alternative")
        .font(.title3.weight(.semibold))
      Text("The new version replaces the text in your document. The current text stays one keystroke away.")
        .font(.callout)
        .foregroundStyle(.secondary)

      Text("Step between versions later with the toolbar arrows or Control-Option-[ and Control-Option-], or pick one in the side panel.")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text("Current")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ScrollView {
        Text(draft.currentText)
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .frame(maxHeight: 90)
      .padding(8)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

      Text("New version")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      TextEditor(text: $versionText)
        .font(.body)
        .frame(minHeight: 110)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(WorkspaceDesign.hairline))
        .accessibilityIdentifier("proseAlternativeText")

      if controller.messageIsError, let message = controller.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.orange)
      }

      HStack {
        Spacer()
        Button("Cancel") { controller.cancelAlternativeDraft() }
          .keyboardShortcut(.cancelAction)
        Button("Add Alternative") {
          controller.commitAlternative(
            draft,
            versionText: versionText.trimmingCharacters(in: .whitespacesAndNewlines)
          )
        }
        .keyboardShortcut(.defaultAction)
        .disabled(versionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 460)
  }
}

struct OrgProseRevisionPopover: View {
  @ObservedObject var controller: OrgProseEditorController
  let draft: OrgProseRevisionDraft
  /// Enabled direct model providers from Settings → AI Chat.
  let destinations: [AIChatDestinationConfiguration]

  @Environment(\.openSettings) private var openSettings
  @AppStorage(WorkspaceSettingsNavigation.selectionKey)
  private var settingsSelection = WorkspaceSettingsNavigation.workspace
  @State private var instruction = ""
  @State private var destinationID = ""
  @State private var model = ""
  @FocusState private var instructionFocused: Bool

  static let suggestions = ["Tighter", "Friendlier", "Clearer", "More formal", "Fix grammar"]

  private var isRunning: Bool { controller.revisionJob?.draft.id == draft.id }

  private var destination: AIChatDestinationConfiguration? {
    destinations.first { $0.id == destinationID }
  }

  private var canSubmit: Bool {
    !isRunning
      && destination != nil
      && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Revise with AI", systemImage: "sparkles")
        .font(.headline)
      Text(draft.target.text.trimmingCharacters(in: .whitespacesAndNewlines))
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

      if destinations.isEmpty {
        noProvider
      } else {
        form
      }
    }
    .padding(14)
    .frame(width: 380)
    .onAppear(perform: configure)
  }

  private var noProvider: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No direct model provider is set up.")
        .font(.callout.weight(.semibold))
      Text("Revise with AI sends one request to a provider you configure: OpenAI, Anthropic, OpenRouter, Ollama, or an OpenAI-compatible endpoint. Add one in Settings → AI Chat.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel") { controller.cancelRevision() }
          .keyboardShortcut(.cancelAction)
        Button("Open AI Chat Settings…") { openAISettings() }
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("How should it change? For example: tighter", text: $instruction, axis: .vertical)
        .lineLimit(1...4)
        .textFieldStyle(.roundedBorder)
        .focused($instructionFocused)
        .disabled(isRunning)
        .onSubmit(submit)
        .accessibilityIdentifier("proseRevisionInstruction")

      HStack(spacing: 6) {
        ForEach(Self.suggestions, id: \.self) { suggestion in
          Button(suggestion) { instruction = suggestion.lowercased() }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
      }
      .disabled(isRunning)

      HStack(spacing: 8) {
        Picker("Provider", selection: $destinationID) {
          ForEach(destinations) { destination in
            Text(destination.title).tag(destination.id)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 150)
        .onChange(of: destinationID) { _, _ in
          if let destination { model = OrgProseRevisionPreferences().preferredModel(for: destination) }
        }
        TextField("Model", text: $model)
          .textFieldStyle(.roundedBorder)
          .onSubmit(submit)
      }
      .controlSize(.small)
      .disabled(isRunning)

      if isRunning, let job = controller.revisionJob {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Waiting for \(job.label) (\(job.model))…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let error = controller.revisionError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Text("Sends the instruction, the selection, and nearby text to the chosen provider. The reply becomes another version; the original stays one step away.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Button("Provider Settings…") { openAISettings() }
          .buttonStyle(.link)
          .controlSize(.small)
        Spacer()
        Button(isRunning ? "Stop" : "Cancel") { controller.cancelRevision() }
          .keyboardShortcut(.cancelAction)
        Button("Revise", action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(!canSubmit)
      }
    }
  }

  private func configure() {
    if let job = controller.revisionJob, job.draft.id == draft.id {
      instruction = job.instruction
    }
    let preferences = OrgProseRevisionPreferences()
    if let preferred = preferences.preferredDestination(among: destinations) {
      destinationID = preferred.id
      model = preferences.preferredModel(for: preferred)
    }
    instructionFocused = true
  }

  private func submit() {
    guard canSubmit, let destination else { return }
    do {
      let backend = try OrgProseRevisionPreferences.backend(for: destination, model: model)
      OrgProseRevisionPreferences().remember(destinationID: destination.id, model: backend.model)
      controller.submitRevision(draft, instruction: instruction, backend: backend)
    } catch {
      controller.reportRevisionError(error.localizedDescription)
    }
  }

  private func openAISettings() {
    controller.revisionDraft = nil
    settingsSelection = WorkspaceSettingsNavigation.aiChat
    openSettings()
  }
}

struct OrgProseSidebar: View {
  @ObservedObject var controller: OrgProseEditorController
  @State private var dismissingAlternativeID: String?

  var body: some View {
    let snapshot = controller.snapshot
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let reason = snapshot.invalidReason {
          VStack(alignment: .leading, spacing: 4) {
            Label("Prose state unavailable", systemImage: "exclamationmark.triangle")
              .font(.callout.weight(.semibold))
            Text(reason)
              .font(.caption)
            Text("Prose actions are off and your document has not been changed. Switch to Source to inspect the block.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .foregroundStyle(.orange)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }

        section("Overflow", count: snapshot.state.overflow.count) {
          if snapshot.state.overflow.isEmpty {
            emptyHint("Nothing parked. Select prose and choose Move to Overflow.")
          }
          ForEach(snapshot.state.overflow, id: \.id) { item in
            overflowRow(item, resolution: snapshot.resolution(for: item.id))
          }
        }

        section("Ghosts", count: snapshot.state.ghosts.count) {
          if snapshot.state.ghosts.isEmpty {
            emptyHint("Ghosted text stays in the document at low opacity.")
          }
          ForEach(snapshot.state.ghosts, id: \.id) { ghost in
            ghostRow(ghost, resolution: snapshot.resolution(for: ghost.id))
          }
        }

        section("Alternatives", count: snapshot.state.alternatives.count) {
          if snapshot.state.alternatives.isEmpty {
            emptyHint("Select text and choose Add Alternative or Revise with AI to try another version.")
          }
          ForEach(snapshot.state.alternatives, id: \.id) { set in
            alternativeRow(set, resolution: snapshot.resolution(for: set.id))
          }
        }
      }
      .padding(14)
    }
    .frame(width: OrgProsePresentation.sidebarWidth)
    .background(WorkspaceDesign.panelFill)
    .overlay(alignment: .leading) {
      Rectangle().fill(WorkspaceDesign.hairline).frame(width: 1)
    }
    .confirmationDialog(
      "Dismiss this alternative?",
      isPresented: Binding(
        get: { dismissingAlternativeID != nil },
        set: { if !$0 { dismissingAlternativeID = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Dismiss Alternative", role: .destructive) {
        if let id = dismissingAlternativeID { controller.dismissAlternative(id: id) }
        dismissingAlternativeID = nil
      }
      Button("Cancel", role: .cancel) { dismissingAlternativeID = nil }
    } message: {
      Text("Its other versions are discarded. The text in your document is kept. You can undo this.")
    }
  }

  private func section<Content: View>(
    _ title: String,
    count: Int,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Text("\(count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      content()
    }
  }

  private func emptyHint(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6, content: content)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
  }

  private func failureLabel(_ failure: OrgProseResolutionFailure) -> some View {
    Label(OrgProsePresentation.failureDescription(failure), systemImage: "exclamationmark.triangle")
      .font(.caption)
      .foregroundStyle(.orange)
  }

  private func overflowRow(_ item: OrgProseOverflowItem, resolution: OrgProseResolution) -> some View {
    card {
      Text(item.text)
        .font(.callout)
        .lineLimit(6)
        .frame(maxWidth: .infinity, alignment: .leading)
      if case .unresolved(let failure) = resolution {
        failureLabel(failure)
        Text("Original spot not found. You can restore it at the cursor instead.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        switch resolution {
        case .resolved:
          Button("Restore") { controller.restoreOverflow(id: item.id, atCursor: false) }
            .help("Put the text back where it was taken from")
        case .unresolved:
          Button("Restore at Cursor") { controller.restoreOverflow(id: item.id, atCursor: true) }
            .help("Insert the text at the current insertion point")
        }
        Spacer()
        Button(role: .destructive) {
          controller.deleteOverflow(id: item.id)
        } label: {
          Image(systemName: "trash")
        }
        .help("Delete this fragment (undoable)")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
  }

  private func ghostRow(_ ghost: OrgProseGhost, resolution: OrgProseResolution) -> some View {
    card {
      Text(ghost.anchor.text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
      if case .unresolved(let failure) = resolution {
        failureLabel(failure)
      }
      HStack {
        if let range = resolution.range {
          Button("Show") { controller.reveal(range: range) }
          Button("Revive") { controller.revive(ghostID: ghost.id) }
        } else {
          Button("Dismiss") { controller.revive(ghostID: ghost.id) }
            .help("Forget this ghost. The text it described is not in the document.")
        }
        Spacer()
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
  }

  private func alternativeRow(_ set: OrgProseAlternativeSet, resolution: OrgProseResolution) -> some View {
    card {
      ForEach(set.variants, id: \.id) { variant in
        let isActive = variant.id == set.activeVariantID
        Button {
          controller.chooseVariant(alternativeID: set.id, variantID: variant.id)
        } label: {
          HStack(alignment: .top, spacing: 6) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(variant.text)
                .font(.callout)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
              if variant.origin == OrgProseStateFormat.originalOrigin {
                Text("Original").font(.caption2).foregroundStyle(.secondary)
              } else if variant.isAI {
                Label(OrgProsePresentation.aiCaption(variant.provenance), systemImage: "sparkles")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .help(OrgProsePresentation.aiDetail(variant.provenance))
              }
            }
            Spacer(minLength: 0)
          }
        }
        .buttonStyle(.plain)
        .disabled(resolution.range == nil)
      }
      if case .unresolved(let failure) = resolution {
        failureLabel(failure)
        Text("Its versions are kept, but it can't be switched until the text is found again.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        if let range = resolution.range {
          Button("Show") { controller.reveal(range: range) }
        }
        Button("Dismiss") { dismissingAlternativeID = set.id }
        Spacer()
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
  }
}
