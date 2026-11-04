import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatGitHubStarPromptTests: XCTestCase {
  func testPromptAppearsOnceAfterFifthSentPromptAndNeverAgain() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-star-prompt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "celorga-star-prompt-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var shownEvents = 0
    func makeStore() -> WorkspaceStore {
      let store = WorkspaceStore(
        cli: Org2CLI(repoRoot: URL(fileURLWithPath: root.path)),
        defaults: defaults,
        aiChatTranscriptURL: root.appendingPathComponent("chat-\(UUID().uuidString).json"),
        aiChatSendHandler: { _, _, _, _ in "Done" }
      )
      store.gitHubStarPromptShownHandler = { shownEvents += 1 }
      return store
    }

    let store = makeStore()
    for index in 1..<WorkspaceStore.gitHubStarPromptThreshold {
      await store.sendAIChatMessage(text: "Prompt \(index)")
      XCTAssertFalse(store.isGitHubStarPromptPresented, "shown early after prompt \(index)")
    }
    XCTAssertEqual(shownEvents, 0, "no telemetry event before the prompt is shown")

    // Local slash commands are not prompts.
    let slashSubmission = AIChatComposerSubmission(
      context: store.captureAIChatCorpusContext(),
      threadID: try XCTUnwrap(store.selectedAIChatThreadID),
      draft: "/help",
      attachments: []
    )
    store.clearAcceptedAIChatComposerSubmission(slashSubmission, countsAsPrompt: false)
    XCTAssertFalse(store.isGitHubStarPromptPresented)

    await store.sendAIChatMessage(text: "Prompt 5")
    XCTAssertTrue(store.isGitHubStarPromptPresented)
    XCTAssertEqual(shownEvents, 1, "showing the prompt sends one telemetry event")

    store.dismissGitHubStarPrompt()
    XCTAssertFalse(store.isGitHubStarPromptPresented)
    for index in 6...12 {
      await store.sendAIChatMessage(text: "Prompt \(index)")
    }
    XCTAssertFalse(store.isGitHubStarPromptPresented)

    // A relaunch with the same preferences never shows it again.
    let relaunched = makeStore()
    for index in 1...6 {
      await relaunched.sendAIChatMessage(text: "Again \(index)")
    }
    XCTAssertFalse(relaunched.isGitHubStarPromptPresented)
    XCTAssertEqual(shownEvents, 1, "the event is never sent again")
  }
}
