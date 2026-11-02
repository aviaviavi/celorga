import AppKit
import Foundation

/// A one-time nudge to star Celorga on GitHub. After the person has sent
/// `gitHubStarPromptThreshold` prompts from the AI chat composer, a small
/// banner appears above the composer. It is marked as shown the moment it
/// appears, so it never comes back after a dismissal, a star, or a relaunch.
extension WorkspaceStore {
  static let gitHubStarPromptThreshold = 5
  static let celorgaGitHubURL = URL(string: "https://github.com/aviaviavi/celorga")!

  func noteAIChatPromptSentForGitHubStarPrompt() {
    guard !Self.shouldIgnoreStandardDefaultsForTests(defaults),
          !defaults.bool(forKey: gitHubStarPromptShownKey)
    else { return }
    let sentPromptCount = defaults.integer(forKey: gitHubStarPromptSentPromptCountKey) + 1
    guard sentPromptCount >= Self.gitHubStarPromptThreshold else {
      defaults.set(sentPromptCount, forKey: gitHubStarPromptSentPromptCountKey)
      return
    }
    defaults.set(true, forKey: gitHubStarPromptShownKey)
    defaults.removeObject(forKey: gitHubStarPromptSentPromptCountKey)
    isGitHubStarPromptPresented = true
  }

  public func starCelorgaOnGitHub() {
    isGitHubStarPromptPresented = false
    NSWorkspace.shared.open(Self.celorgaGitHubURL)
  }

  public func dismissGitHubStarPrompt() {
    isGitHubStarPromptPresented = false
  }
}
