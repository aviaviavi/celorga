import AppKit
import Foundation

enum WorkspaceSound {
  nonisolated static let bundledNewMessageSoundURL =
    WorkspaceResources.url(forResource: "NewMessage", withExtension: "mp3")

  nonisolated static var isPlaybackSuppressed: Bool {
    NSClassFromString("XCTestCase") != nil
  }

  @MainActor
  private static let bundledNewMessageSound = bundledNewMessageSoundURL.flatMap {
    NSSound(contentsOf: $0, byReference: true)
  }

  @MainActor
  static func play(named name: NSSound.Name) {
    guard !isPlaybackSuppressed else { return }
    NSSound(named: name)?.play()
  }

  @MainActor
  static func playBundledNewMessageSound() {
    guard !isPlaybackSuppressed else { return }
    bundledNewMessageSound?.play()
  }

  @MainActor
  static func beep() {
    guard !isPlaybackSuppressed else { return }
    NSSound.beep()
  }
}
