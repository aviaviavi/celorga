import SwiftUI

/// Shared selection lets chat open the AI pane even when Settings is already open.
public enum WorkspaceSettingsNavigation {
  public static let selectionKey = "workspaceSettingsSelection"
  public static let workspace = "workspace"
  public static let aiChat = "aiChat"
  public static let sharing = "sharing"
  public static let apps = "apps"
}

public struct AIChatSettingsButton: View {
  @Environment(\.openSettings) private var openSettings
  @AppStorage(WorkspaceSettingsNavigation.selectionKey) private var selection = WorkspaceSettingsNavigation.workspace

  public init() {}

  public var body: some View {
    Button {
      selection = WorkspaceSettingsNavigation.aiChat
      openSettings()
    } label: {
      Label("AI Chat Settings…", systemImage: "gearshape")
    }
    .help("Open Settings → AI Chat")
    .accessibilityIdentifier("ai-chat-settings")
  }
}
