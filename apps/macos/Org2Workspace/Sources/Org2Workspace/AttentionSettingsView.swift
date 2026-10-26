import Org2WorkspaceCore
import SwiftUI

struct AttentionSettingsView: View {
  @EnvironmentObject private var attention: AttentionDigestMonitor

  var body: some View {
    Form {
      Section {
        Toggle("Notify me when something needs me", isOn: Binding(
          get: { attention.isEnabled },
          set: { attention.setEnabled($0) }
        ))
        Text("Celorga runs the attention digest at your morning brief time and on your check interval, outside quiet hours, and posts one notification only when there are new approvals, blocked runs, replies, or due items. Nothing is decided by a model.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("Schedule") {
        LabeledContent("Current", value: attention.scheduleSummary)
        Text("Set morningBrief, checkIntervalMinutes, quietHours, and category, tag, or path filters under \"attention\" in the corpus celorga.json.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("Status") {
        LabeledContent("Last result", value: attention.statusText)
        if let lastRunAt = attention.lastRunAt {
          LabeledContent("Last checked", value: lastRunAt.formatted(date: .omitted, time: .shortened))
        }
        if let error = attention.errorText {
          Text(error).font(.callout).foregroundStyle(.red)
        }
        HStack {
          Button("Check Now") { Task { await attention.run(.check, notify: attention.isEnabled) } }
            .disabled(attention.isRunning)
          Button("Show Items") { attention.showDigestWindow() }
        }
      }
    }
    .formStyle(.grouped)
  }
}
