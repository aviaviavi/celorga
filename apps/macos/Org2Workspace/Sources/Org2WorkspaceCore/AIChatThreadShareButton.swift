import AppKit
import SwiftUI

/// Header control that shares the selected AI chat thread as a live,
/// read-only link hosted by this Mac or by a paired OpenOrg server.
struct AIChatThreadShareButton: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isPresented = false

  var body: some View {
    let threadID = store.selectedAIChatThreadID
    let isShared = threadID.map(store.isChatThreadShared) ?? false
    Button {
      isPresented.toggle()
    } label: {
      Label(isShared ? "Shared" : "Share", systemImage: isShared ? "link.circle.fill" : "square.and.arrow.up")
    }
    .help(isShared ? "This thread has a live link" : "Share this thread as a live link")
    .disabled(threadID == nil || store.aiChatMessages.isEmpty && !isShared)
    .accessibilityIdentifier("ai-chat-share-thread")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      if let threadID {
        AIChatThreadSharePopover(threadID: threadID)
      }
    }
  }
}

struct AIChatThreadSharePopover: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.openSettings) private var openSettings
  @AppStorage(WorkspaceSettingsNavigation.selectionKey) private var settingsSelection = WorkspaceSettingsNavigation.workspace
  @State private var errorText: String?
  @State private var copiedURL: URL?
  @State private var location: ChatThreadShareLocation?
  let threadID: UUID

  var body: some View {
    let server = store.openOrgServer
    let localPublication = store.chatThreadPublication(for: threadID)
    let serverShare = server.threadShare(for: threadID)
    let isBusy = store.isPublishingChatThread(threadID)
    VStack(alignment: .leading, spacing: 12) {
      Label("Share Thread", systemImage: "link")
        .font(.headline)

      if serverShare != nil || localPublication != nil {
        Text("Anyone who can reach this link can read the thread. New messages appear automatically.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if let serverShare {
          shareRow(
            title: serverShare.serverName,
            systemImage: "server.rack",
            detail: "Stays live while this Mac sleeps.",
            url: serverShare.url
          ) {
            Task {
              await store.stopSharingChatThreadOnServer(threadID)
              errorText = store.openOrgServer.threadShare(for: threadID) == nil ? nil : store.errorText
            }
          }
        }
        if let localPublication {
          shareRow(
            title: "This Mac",
            systemImage: "laptopcomputer",
            detail: "Works while this Mac is awake and Celorga is open.",
            url: localPublication.url
          ) {
            store.stopSharingChatThreadLocally(threadID)
          }
          guestMessagesToggle
        } else if serverShare != nil {
          Text("Guest messages are available for links shared from this Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        redactionNote
      } else {
        Text("Create a read-only link that anyone who can reach it can open in a browser. It uses your Celorga theme and shows new messages as they arrive.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        locationPicker(server: server)

        Text("Attached context, reasoning, and tool activity are not included.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        redactionNote

        HStack {
          if !server.isPaired {
            Button("Set Up Server…") {
              settingsSelection = WorkspaceSettingsNavigation.sharing
              openSettings()
            }
            .buttonStyle(.link)
            .help("Pair this Mac with a headless Celorga server to host links there")
          }
          Spacer()
          Button {
            Task { await share() }
          } label: {
            if isBusy {
              HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Creating Link")
              }
            } else {
              Text("Create Link")
            }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(isBusy)
        }
      }

      if let errorText {
        Text(errorText)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      Label("Links use unencrypted HTTP. Share them only on a trusted network or your tailnet.", systemImage: "lock.open")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(16)
    .frame(width: 380)
    .task {
      await store.refreshLocalDocumentPublicationURLs()
      if store.openOrgServer.isPaired {
        await store.openOrgServer.refreshShare(threadID: threadID)
      }
    }
  }

  private var redactionNote: some View {
    Label(
      "Known secret patterns, such as API keys, access tokens, and private keys, are redacted. Review the thread before sharing; other sensitive text is not detected.",
      systemImage: "eye.slash"
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var guestMessagesToggle: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle("Let guests send messages (you approve each one)", isOn: Binding(
        get: { store.isChatThreadGuestMessagesEnabled(threadID) },
        set: { enabled in
          Task {
            errorText = nil
            do {
              try await store.setChatThreadGuestMessagesEnabled(enabled, for: threadID)
            } catch {
              errorText = error.localizedDescription
            }
          }
        }
      ))
      .toggleStyle(.checkbox)
      .disabled(store.isPublishingChatThread(threadID))
      .accessibilityIdentifier("ai-chat-share-guest-messages")
      Text("Guests add a name and a text message on the shared page. Each one waits in this thread until you approve, edit, or decline it; nothing reaches the agent before you approve.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var selectedLocation: ChatThreadShareLocation {
    let chosen = location ?? store.openOrgServer.effectiveDefaultShareLocation
    return chosen == .server && !store.openOrgServer.isPaired ? .thisMac : chosen
  }

  @ViewBuilder
  private func locationPicker(server: OpenOrgServerConnection) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("Share from", selection: Binding(
        get: { selectedLocation },
        set: { location = $0 }
      )) {
        Label("This Mac", systemImage: "laptopcomputer")
          .tag(ChatThreadShareLocation.thisMac)
        Label(server.isPaired ? server.serverName : "Celorga Server", systemImage: "server.rack")
          .tag(ChatThreadShareLocation.server)
          .selectionDisabled(!server.isPaired)
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("ai-chat-share-location")

      Text(locationDetail(server: server))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func locationDetail(server: OpenOrgServerConnection) -> String {
    guard server.isPaired else {
      return "Hosted by this Mac while it is awake. Pair a Celorga server in Settings → Sharing to host links that stay live while this Mac sleeps."
    }
    switch selectedLocation {
    case .thisMac:
      return "Hosted by this Mac while it is awake and Celorga is open."
    case .server:
      if case .offline(let reason) = server.reachability {
        return "\(server.serverName) is unreachable right now: \(reason)"
      }
      return "Hosted by \(server.serverName) from its synced copy of this thread. Stays live while this Mac sleeps."
    }
  }

  private func shareRow(
    title: String,
    systemImage: String,
    detail: String,
    url: URL,
    stop: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Label(title, systemImage: systemImage)
          .font(.callout.weight(.semibold))
        Spacer()
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Text(url.absoluteString)
        .font(.callout.monospaced())
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

      HStack {
        Button(role: .destructive, action: stop) {
          Text("Stop Sharing")
        }
        .disabled(store.isPublishingChatThread(threadID))
        Spacer()
        Button("Open") {
          NSWorkspace.shared.open(url)
        }
        Button {
          AIChatMessageClipboard.write(url.absoluteString)
          copiedURL = url
        } label: {
          Label(copiedURL == url ? "Copied" : "Copy Link", systemImage: copiedURL == url ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  private func share() async {
    errorText = nil
    do {
      let url = try await store.shareChatThread(threadID, from: selectedLocation)
      AIChatMessageClipboard.write(url.absoluteString)
      copiedURL = url
    } catch {
      errorText = error.localizedDescription
    }
  }
}
