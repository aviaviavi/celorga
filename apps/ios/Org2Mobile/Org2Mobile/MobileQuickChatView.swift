import PhotosUI
import SwiftUI

/// The Chat tab's new chat: the same bottom composer as a chat, with the
/// agent, model, and reasoning chosen above it, photos, the camera, and
/// dictation. The chat is created only when the message is sent, so no
/// empty chats are left behind; recent chats are one tap away above it.
struct MobileQuickChatView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  @Environment(\.colorScheme) private var colorScheme
  let openThread: (UUID) -> Void
  @StateObject private var voiceTranscriber = MobileVoiceTranscriber()
  @State private var draft = ""
  @State private var dictationPrefix = ""
  @State private var model: String?
  @State private var effort: String?
  @State private var attachments: [MobileRemoteAttachment] = []
  @State private var selectedPhotoItems: [PhotosPickerItem] = []
  @State private var isPhotoPickerPresented = false
  @State private var isCameraPresented = false
  @State private var isPreparingPhotos = false
  @State private var isStarting = false
  @State private var isFinishingDictation = false

  var body: some View {
    Group {
      if remote.isPaired {
        recentChats
      } else {
        ConnectHostView()
      }
    }
    .navigationTitle("New Chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        MobileSidebarToolbarButton()
      }
    }
    .safeAreaInset(edge: .bottom) {
      if remote.isPaired {
        composer
      }
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
    .sheet(isPresented: $isCameraPresented) {
      ImagePicker(sourceType: .camera) { image in
        addCameraPhoto(image)
      }
      .ignoresSafeArea()
    }
    .onChange(of: voiceTranscriber.transcript) { _, transcript in
      draft = MobileRemoteThreadView.appendingDictation(transcript, to: dictationPrefix)
    }
    .alert("Voice Transcription", isPresented: Binding(
      get: { voiceTranscriber.errorMessage != nil },
      set: { if !$0 { voiceTranscriber.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(voiceTranscriber.errorMessage ?? "")
    }
    .onAppear {
      restoreChoice()
      remote.refreshChatDestinationModels()
    }
    .onDisappear {
      voiceTranscriber.cancel()
    }
    .onChange(of: remote.quickChatDestination?.id) { _, _ in restoreChoice() }
    .onChange(of: model) { _, _ in
      // Keep a reasoning level only while the chosen model offers it.
      if let effort, !reasoningOptions.contains(where: { $0.id == effort }) {
        self.effort = nil
      }
    }
  }

  // MARK: Recent chats

  private var recentChats: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        VStack(spacing: 8) {
          Image(systemName: "bubble.left.and.text.bubble.right")
            .font(.system(size: 34, weight: .regular))
            .foregroundStyle(.tertiary)
          Text("Message \(agentName)")
            .font(.title3.weight(.semibold))
          Text("Your message starts a new chat.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
        .padding(.bottom, 28)

        if !recentThreads.isEmpty {
          Text("Recent")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
          ForEach(recentThreads) { thread in
            Button {
              openThread(thread.id)
            } label: {
              HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                  Text(thread.title)
                    .lineLimit(1)
                  if let preview = thread.latestAssistantPreview ?? thread.preview {
                    Text(preview)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                Spacer(minLength: 0)
                if thread.isRunning {
                  ProgressView().controlSize(.small)
                } else if thread.unreadMessageCount > 0 {
                  Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                }
              }
              .padding(.vertical, 9)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()
          }
        }
      }
      .padding(.horizontal)
    }
    .scrollDismissesKeyboard(.interactively)
  }

  private var recentThreads: [MobileRemoteThreadSummary] {
    Array(remote.threads.filter { !$0.isSettled }
      .sorted { $0.updatedAt > $1.updatedAt }
      .prefix(8))
  }

  // MARK: Composer

  private var composer: some View {
    VStack(spacing: 8) {
      choiceChips

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
        Menu {
          Button {
            isPhotoPickerPresented = true
          } label: {
            Label("Add Photos", systemImage: "photo.on.rectangle")
          }
          Button {
            isCameraPresented = true
          } label: {
            Label("Take Photo", systemImage: "camera")
          }
          .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(Color(.tertiarySystemFill), in: Circle())
        }
        .disabled(isStarting || isPreparingPhotos || attachments.count >= 4)
        .accessibilityLabel("Add photos")

        MobileRemoteComposerTextView(
          text: draft,
          placeholder: "Message \(agentName)",
          isEnabled: !isStarting,
          maximumLines: 6
        ) { draft = $0 }

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
        .disabled(isStarting || isFinishingDictation)
        .accessibilityLabel(voiceTranscriber.isRecording ? "Stop transcription" : "Transcribe voice")

        Button {
          if voiceTranscriber.isRecording {
            finishDictationAndSend()
          } else {
            send()
          }
        } label: {
          if isStarting || isFinishingDictation {
            ProgressView()
              .frame(width: 30, height: 30)
          } else {
            Image(systemName: "arrow.up.circle.fill")
              .font(.system(size: 30, weight: .semibold))
              .foregroundStyle(Color.accentColor)
              .frame(width: 30, height: 30)
          }
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(voiceTranscriber.isRecording ? "Finish transcription and send" : "Send message")
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
      .background(
        Color(.secondarySystemGroupedBackground),
        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(Color.primary.opacity(colorScheme == .light ? 0.11 : 0.09), lineWidth: 1)
      }
      .shadow(color: Color.black.opacity(colorScheme == .light ? 0.055 : 0.025), radius: 4, x: 0, y: 2)

      if !remote.isConnected {
        Text(remote.connectionError.map { "Not connected to your host. \($0)" } ?? "Connecting to your host…")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }

  /// Agent, model, and reasoning, each one tap from the composer.
  private var choiceChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        Menu {
          ForEach(remote.chatDestinations) { destination in
            Button {
              remote.setQuickChatDestination(destination)
              restoreChoice()
            } label: {
              if destination.id == remote.quickChatDestination?.id {
                Label(destination.name, systemImage: "checkmark")
              } else {
                Text(destination.name)
              }
            }
          }
        } label: {
          chip(agentName, systemImage: "person.crop.circle")
        }
        .accessibilityLabel("Agent, \(agentName)")

        Menu {
          Button {
            model = nil
          } label: {
            choiceLabel(defaultModelTitle, isSelected: model == nil)
          }
          if !models.isEmpty {
            Divider()
            ForEach(models) { option in
              Button {
                model = option.id
              } label: {
                choiceLabel(option.label, isSelected: model == option.id)
              }
            }
          } else {
            Text("Models load from your host")
          }
        } label: {
          chip(modelLabel, systemImage: "cpu")
        }
        .accessibilityLabel("Model, \(modelLabel)")

        if !reasoningOptions.isEmpty {
          Menu {
            Button {
              effort = nil
            } label: {
              choiceLabel(defaultReasoningTitle, isSelected: effort == nil)
            }
            Divider()
            ForEach(reasoningOptions) { option in
              Button {
                effort = option.id
              } label: {
                choiceLabel(option.label, isSelected: effort == option.id)
              }
            }
          } label: {
            chip(reasoningLabel, systemImage: "brain")
          }
          .accessibilityLabel("Reasoning, \(reasoningLabel)")
        }
      }
      .padding(.horizontal, 2)
    }
  }

  @ViewBuilder
  private func choiceLabel(_ title: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  private func chip(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: systemImage)
        .font(.caption.weight(.semibold))
      Text(title)
        .lineLimit(1)
      Image(systemName: "chevron.up.chevron.down")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
    }
    .font(.footnote.weight(.medium))
    .foregroundStyle(.primary)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Color(.tertiarySystemFill), in: Capsule())
  }

  // MARK: Choices

  private var agentName: String {
    remote.quickChatDestination?.name ?? "agent"
  }

  private var configuration: MobileRemoteThreadConfiguration? {
    remote.quickChatDestination.flatMap { remote.cachedModels(for: $0.id) }
  }

  private var models: [MobileRemoteModelOption] {
    configuration?.models ?? []
  }

  private var reasoningChoices: (options: [MobileRemoteReasoningOption], defaultEffort: String?) {
    configuration?.reasoningChoices(forModel: model) ?? ([], nil)
  }

  private var reasoningOptions: [MobileRemoteReasoningOption] {
    reasoningChoices.options
  }

  private var defaultModelTitle: String {
    models.first(where: \.isDefault).map { "Default (\($0.label))" } ?? "Default model"
  }

  private var modelLabel: String {
    if let model { return models.first { $0.id == model }?.label ?? model }
    return models.first(where: \.isDefault)?.label ?? "Default model"
  }

  private var defaultReasoningTitle: String {
    guard let id = reasoningChoices.defaultEffort else { return "Default" }
    let label = reasoningOptions.first { $0.id == id }?.label ?? id.capitalized
    return "Default (\(label))"
  }

  private var reasoningLabel: String {
    guard let id = effort ?? reasoningChoices.defaultEffort else { return "Reasoning" }
    return reasoningOptions.first { $0.id == id }?.label ?? id.capitalized
  }

  private func restoreChoice() {
    guard let destination = remote.quickChatDestination else { return }
    let choice = remote.quickChatChoice(for: destination.id)
    model = choice.model.flatMap { saved in models.contains { $0.id == saved } ? saved : nil }
    effort = choice.effort.flatMap { saved in reasoningOptions.contains { $0.id == saved } ? saved : nil }
  }

  // MARK: Sending

  private var hasContent: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
  }

  private var canSend: Bool {
    !isStarting && !isFinishingDictation && !isPreparingPhotos
      && remote.isConnected && remote.quickChatDestination != nil
      && (voiceTranscriber.isRecording || hasContent)
  }

  private func finishDictationAndSend() {
    guard voiceTranscriber.isRecording, !isFinishingDictation else { return }
    isFinishingDictation = true
    Task {
      let transcript = await voiceTranscriber.finish()
      draft = MobileRemoteThreadView.appendingDictation(transcript, to: dictationPrefix)
      isFinishingDictation = false
      send()
    }
  }

  private func send() {
    guard canSend, hasContent, let destination = remote.quickChatDestination else { return }
    voiceTranscriber.cancel()
    let message = draft
    let sentAttachments = attachments
    isStarting = true
    Task {
      if let threadID = await remote.startQuickChat(
        message: message,
        attachments: sentAttachments,
        destination: destination,
        model: model,
        effort: effort
      ) {
        draft = ""
        dictationPrefix = ""
        attachments = []
        openThread(threadID)
      }
      isStarting = false
    }
  }

  // MARK: Photos

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
        for item in items.prefix(4 - next.count) {
          guard let data = try await item.loadTransferable(type: Data.self) else {
            throw MobileRemotePhotoError.unreadable
          }
          try append(data, to: &next)
        }
        attachments = Array(next.prefix(4))
      } catch {
        remote.errorMessage = error.localizedDescription
      }
    }
  }

  private func addCameraPhoto(_ image: UIImage) {
    guard attachments.count < 4, let data = image.jpegData(compressionQuality: 0.9) else { return }
    do {
      var next = attachments
      try append(data, to: &next)
      attachments = next
    } catch {
      remote.errorMessage = error.localizedDescription
    }
  }

  private func append(_ data: Data, to next: inout [MobileRemoteAttachment]) throws {
    let attachment = try MobileRemotePhotoPreparation.attachment(from: data, sequence: next.count + 1)
    guard !next.contains(where: { $0.data == attachment.data }) else { return }
    guard next.reduce(attachment.data.count, { $0 + $1.data.count }) <= 7_500_000 else {
      throw MobileRemotePhotoError.totalTooLarge
    }
    next.append(attachment)
  }
}
