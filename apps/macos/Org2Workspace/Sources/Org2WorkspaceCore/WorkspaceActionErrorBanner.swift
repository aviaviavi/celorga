import SwiftUI

/// A shared, nonmodal destination for failures reported by workspace actions.
struct WorkspaceActionErrorBanner: View {
  let error: String
  /// Starts an AI thread that diagnoses the error; nil hides the button.
  var askAI: (() -> Void)? = nil
  let dismiss: () -> Void
  @State private var expanded = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 4) {
        Text(error)
          .font(.callout)
          .lineLimit(expanded ? nil : 3)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        if error.count > 160 || error.contains("\n") {
          Button(expanded ? "Less" : "Details") { expanded.toggle() }
            .buttonStyle(.link)
            .font(.caption)
        }
      }
      if let askAI {
        Button(action: askAI) {
          Label("Ask AI to Fix", systemImage: "sparkles")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Start an AI thread that diagnoses this error and fixes it when it can")
      }
      Button(action: dismiss) { Image(systemName: "xmark") }
        .buttonStyle(.plain)
        .help("Dismiss error")
        .accessibilityLabel("Dismiss error")
    }
    .padding(10)
    .background(WorkspaceDesign.barBackground)
    .accessibilityIdentifier("workspace-action-error")
  }
}
