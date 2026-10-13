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
    .task { await audio.refreshRegistration() }
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
