import SwiftUI

/// Opens ready to type: one tap to send a message to the chosen agent. The
/// chat is created only when the message is sent, and recent chats are one
/// tap away below the composer.
struct MobileQuickChatView: View {
  @EnvironmentObject private var remote: MobileRemoteStore
  let openThread: (UUID) -> Void
  @State private var draft = ""
  @State private var model: String?
  @State private var effort: String?
  @State private var isStarting = false
  @FocusState private var isComposerFocused: Bool

  var body: some View {
    Group {
      if remote.isPaired {
        content
      } else {
        ConnectHostView()
      }
    }
    .navigationTitle("Quick Chat")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        MobileSidebarToolbarButton()
      }
    }
  }

  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 8) {
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
            chip(remote.quickChatDestination?.name ?? "Agent", systemImage: "person.crop.circle")
          }
          .accessibilityLabel("Agent, \(remote.quickChatDestination?.name ?? "none")")
          if !models.isEmpty {
            Menu {
              Button("Default") { model = nil }
              ForEach(models) { option in
                Button(option.label) { model = option.id }
              }
            } label: {
              chip(modelLabel, systemImage: "cpu")
            }
            .accessibilityLabel("Model, \(modelLabel)")
          }
          if !reasoningOptions.isEmpty {
            Menu {
              Button("Default") { effort = nil }
              ForEach(reasoningOptions) { option in
                Button(option.label) { effort = option.id }
              }
            } label: {
              chip(effortLabel, systemImage: "brain")
            }
            .accessibilityLabel("Reasoning, \(effortLabel)")
          }
        }

        HStack(alignment: .bottom, spacing: 10) {
          TextField("Message \(remote.quickChatDestination?.name ?? "agent")", text: $draft, axis: .vertical)
            .lineLimit(1...8)
            .focused($isComposerFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            .submitLabel(.send)
          Button(action: send) {
            if isStarting {
              ProgressView()
                .frame(width: 34, height: 34)
            } else {
              Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 34))
            }
          }
          .disabled(!canSend)
          .accessibilityLabel("Send")
        }

        if !recentThreads.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("Continue")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(recentThreads) { thread in
              Button {
                openThread(thread.id)
              } label: {
                HStack {
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
                  Spacer()
                  if thread.isRunning {
                    ProgressView().controlSize(.small)
                  } else if thread.unreadMessageCount > 0 {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                  }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              Divider()
            }
          }
        }
      }
      .padding()
    }
    .scrollDismissesKeyboard(.interactively)
    .onAppear {
      restoreChoice()
      isComposerFocused = true
    }
    .onChange(of: remote.quickChatDestination?.id) { _, _ in restoreChoice() }
  }

  private var models: [MobileRemoteModelOption] {
    remote.quickChatDestination.flatMap { remote.cachedModels(for: $0.id)?.models } ?? []
  }

  private var reasoningOptions: [MobileRemoteReasoningOption] {
    remote.quickChatDestination.flatMap { remote.cachedModels(for: $0.id)?.reasoningOptions } ?? []
  }

  private var modelLabel: String {
    if let model { return models.first { $0.id == model }?.label ?? model }
    return models.first(where: \.isDefault)?.label ?? "Default model"
  }

  private var effortLabel: String {
    effort.flatMap { id in reasoningOptions.first { $0.id == id }?.label } ?? "Default"
  }

  private var recentThreads: [MobileRemoteThreadSummary] {
    Array(remote.threads.filter { !$0.isSettled }
      .sorted { $0.updatedAt > $1.updatedAt }
      .prefix(6))
  }

  private var canSend: Bool {
    !isStarting && remote.isConnected && remote.quickChatDestination != nil
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func restoreChoice() {
    guard let destination = remote.quickChatDestination else { return }
    let choice = remote.quickChatChoice(for: destination.id)
    model = choice.model.flatMap { saved in models.contains { $0.id == saved } ? saved : nil }
    effort = choice.effort.flatMap { saved in reasoningOptions.contains { $0.id == saved } ? saved : nil }
  }

  private func send() {
    guard canSend, let destination = remote.quickChatDestination else { return }
    let message = draft
    isStarting = true
    Task {
      if let threadID = await remote.startQuickChat(
        message: message, destination: destination, model: model, effort: effort
      ) {
        draft = ""
        openThread(threadID)
      }
      isStarting = false
    }
  }

  private func chip(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
      Image(systemName: "chevron.up.chevron.down")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .font(.subheadline.weight(.medium))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(.tertiarySystemFill), in: Capsule())
  }
}
