import SwiftUI

/// Settings › Audio approvals. Always listed so the feature is discoverable; off until turned on.
struct AudioApprovalSettingsSection: View {
  @EnvironmentObject private var audio: AudioApprovalController
  #if DEBUG
  @State private var demoReply = "yes"
  #endif

  var body: some View {
    Section {
      Toggle("Walkie-talkie approvals", isOn: Binding(
        get: { audio.isEnabled },
        set: { audio.setEnabled($0) }
      ))
      NavigationLink {
        AudioApprovalVoiceView()
      } label: {
        LabeledContent("Voice", value: audio.selectedVoice?.name ?? "Automatic")
      }
      if audio.isEnabled || !audio.replyHistory.isEmpty {
        NavigationLink("Reply and decision history") { AudioApprovalHistoryView() }
      }
      if audio.isEnabled {
        if audio.channelJoined {
          Button("Leave approvals channel", role: .destructive) { audio.leave() }
        } else {
          Button("Join approvals channel") { audio.join() }
        }
        quietControls
        Button(audio.promptText == nil ? "Play next prompt" : "Replay prompt") { audio.playNextPrompt() }
          .disabled(!audio.channelJoined || audio.isQuiet)
        LabeledContent("Status", value: audio.phase)
        LabeledContent("Mac", value: audio.registrationText)
        if let promptText = audio.promptText {
          Text(promptText)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if let acknowledgement = audio.acknowledgement {
          Text(acknowledgement)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        #if DEBUG
        demoControls
        #endif
      }
    } header: {
      Text("Audio approvals")
    } footer: {
      Text("Agents' approval requests are read to you on a connected headset, one at a time. Press the Push to Talk button and say yes, no, why, read it to me, or later. Nothing ever plays on the speaker; without a headset, prompts wait on your Mac. Decisions go to your Mac's approval queue for the exact request you heard.")
    }
    .task {
      audio.refreshVoices()
      await audio.refreshRegistration()
    }
  }

  @ViewBuilder
  private var quietControls: some View {
    if let quietUntil = audio.quietUntil, quietUntil > Date() {
      LabeledContent(
        quietUntil == .distantFuture ? "Quiet" : "Snoozed until",
        value: quietUntil == .distantFuture ? "On" : quietUntil.formatted(date: .omitted, time: .shortened)
      )
      Button("Resume prompts") { audio.setQuiet(until: nil) }
    } else {
      Menu("Quiet or snooze") {
        Button("Snooze 30 minutes") { audio.setQuiet(until: Date().addingTimeInterval(30 * 60)) }
        Button("Snooze 1 hour") { audio.setQuiet(until: Date().addingTimeInterval(60 * 60)) }
        Button("Snooze 4 hours") { audio.setQuiet(until: Date().addingTimeInterval(4 * 60 * 60)) }
        Button("Quiet until I turn it off") { audio.setQuiet(until: .distantFuture) }
      }
    }
  }

  #if DEBUG
  @ViewBuilder
  private var demoControls: some View {
    Toggle("Simulator demo (debug only)", isOn: Binding(
      get: { audio.isDemo },
      set: { audio.setDemo($0) }
    ))
    if audio.isDemo {
      Button("Demo: play next prompt") { audio.demoPlayNext() }
      TextField("Spoken reply", text: $demoReply)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Button("Demo: reply") { audio.demoReply(demoReply) }
      if let spoken = audio.demoSpoken {
        Text("Would speak: \(spoken)")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
  #endif
}

private struct AudioApprovalVoiceView: View {
  @EnvironmentObject private var audio: AudioApprovalController
  @State private var search = ""

  private var filteredVoices: [AudioApprovalVoiceOption] {
    audio.availableVoices.filter {
      search.isEmpty || "\($0.name) \($0.language) \(languageName($0)) \($0.quality.label)"
        .localizedCaseInsensitiveContains(search)
    }
  }

  var body: some View {
    List {
      Section {
        Button { audio.setVoice(nil) } label: {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Automatic")
              if let voice = audio.automaticVoice {
                Text("\(voice.name) · \(voice.quality.label)")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            if audio.voiceIdentifier == nil { Image(systemName: "checkmark") }
          }
          .foregroundStyle(.primary)
        }
        if audio.selectedVoiceUnavailable {
          Text("Your chosen voice is unavailable. Using Automatic until it is downloaded again.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      } footer: {
        Text("Automatic uses the highest-quality installed voice for your language and region. Speech is generated on your iPhone.")
      }
      Section {
        ForEach(filteredVoices) { voice in
          Button { audio.setVoice(voice.id) } label: {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(voice.name)
                Text("\(languageName(voice)) · \(voice.quality.label)")
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if audio.voiceIdentifier == voice.id { Image(systemName: "checkmark") }
            }
            .foregroundStyle(.primary)
          }
        }
      } header: {
        Text("Available voices")
      } footer: {
        Text("For more natural speech, open iPhone Settings, search for Voices, and download an Enhanced or Premium voice for your language. Return here to choose it.")
      }
    }
    .navigationTitle("Approval voice")
    .searchable(text: $search, prompt: "Name, language, or quality")
    .onAppear { audio.refreshVoices() }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
      audio.refreshVoices()
    }
  }

  private func languageName(_ voice: AudioApprovalVoiceOption) -> String {
    Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
  }
}

/// Available directly from Approvals as well as Settings, even after the audio feature is off.
struct AudioApprovalFeedbackSection: View {
  @EnvironmentObject private var audio: AudioApprovalController
  @EnvironmentObject private var remote: MobileRemoteStore

  var body: some View {
    if audio.isEnabled || !audio.replyHistory.isEmpty || !remote.approvalHistory.isEmpty {
      Section("Audio replies") {
        if audio.isEnabled {
          Text(audio.phase).font(.subheadline)
          if let prompt = audio.promptText {
            Text(prompt).font(.footnote).foregroundStyle(.secondary)
          }
        }
        if let latest = audio.replyHistory.first {
          AudioApprovalReplyRow(record: latest)
        } else if let result = audio.acknowledgement {
          Text(result).font(.subheadline)
        }
        NavigationLink("Reply and decision history") { AudioApprovalHistoryView() }
      }
    }
  }
}

private struct AudioApprovalReplyRow: View {
  let record: AudioApprovalReplyRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(record.title).font(.headline)
      Text(record.createdAt.formatted(date: .abbreviated, time: .standard))
        .font(.caption).foregroundStyle(.secondary)
      if let transcript = record.transcript {
        Text(transcript.isEmpty ? "Heard: no speech recognized" : "Heard: “\(transcript)”")
        if let interpretation = record.interpretation { Text("Interpreted as: \(interpretation)") }
      } else {
        Text("No speech was transcribed.").foregroundStyle(.secondary)
      }
      Text(record.outcome).font(.subheadline)
      if let target = record.target {
        Text("Run: \(target.runID)\nRequest: \(target.approvalID)")
          .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    .padding(.vertical, 4)
    .textSelection(.enabled)
  }
}

struct AudioApprovalHistoryView: View {
  @EnvironmentObject private var audio: AudioApprovalController
  @EnvironmentObject private var remote: MobileRemoteStore

  var body: some View {
    List {
      Section {
        if audio.replyHistory.isEmpty {
          Text("No spoken replies recorded on this phone yet.").foregroundStyle(.secondary)
        }
        ForEach(audio.replyHistory) { record in AudioApprovalReplyRow(record: record) }
      } header: {
        Text("Spoken replies on this phone")
      } footer: {
        Text("The latest 50 attempts are kept on this phone for this Mac. An interpretation is only a request; the result tells you whether the Mac confirmed it.")
      }
      Section("Recorded decisions on the Mac") {
        if remote.approvalHistory.isEmpty {
          Text("No recorded decisions returned by this Mac yet.").foregroundStyle(.secondary)
        }
        ForEach(remote.approvalHistory) { item in
          VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.headline)
            Text("\(item.status.capitalized) by \(item.decidedBy ?? "Unknown actor")")
            if let date = item.decidedAt { Text(date).font(.caption).foregroundStyle(.secondary) }
            if let note = item.decisionNote { Text(note).font(.subheadline) }
            Text("Run: \(item.runID)\nRequest: \(item.approvalID)")
              .font(.caption).foregroundStyle(.secondary)
          }
          .textSelection(.enabled)
        }
      }
    }
    .navigationTitle("Reply history")
    .refreshable { await remote.refreshWorkspace(reportsErrors: false) }
    .task { await remote.refreshWorkspace(reportsErrors: false) }
  }
}
