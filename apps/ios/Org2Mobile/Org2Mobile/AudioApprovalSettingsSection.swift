import SwiftUI

/// Settings section for the audio approval prototype. Shown only when the feature is enabled on this device.
struct AudioApprovalSettingsSection: View {
  @EnvironmentObject private var audio: AudioApprovalController

  var body: some View {
    Section {
      Toggle("Quiet mode", isOn: Binding(
        get: { audio.isQuiet },
        set: { audio.setQuiet($0) }
      ))
      if audio.channelJoined {
        Button("Leave approvals channel", role: .destructive) { audio.leave() }
      } else {
        Button("Join approvals channel") { audio.join() }
      }
      LabeledContent("Status", value: audio.phase)
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
    } header: {
      Text("Audio approvals (prototype)")
    } footer: {
      Text("Prompts play only on a connected headset and never on the speaker. Replies start with a Push to Talk press. Hardware behavior, including locked-phone playback, is not yet verified on a device.")
    }
  }
}
