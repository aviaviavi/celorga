import XCTest
@testable import Org2WorkspaceCore

/// Another host commits chat changes many times an hour. Picking those up
/// must not stall the main actor in a long chat history.
@MainActor
final class SyncedAIChatRefreshPerformanceTests: XCTestCase {
  func testSyncedRefreshOfOneRemoteChangeKeepsTheMainActorResponsive() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcriptURL = root.appendingPathComponent("chat.json")
    var threads = (0..<2_000).map { index in
      AIChatThread(title: "Thread \(index)", runtime: .codex, sessionKey: "session-\(index)")
        .replacingMessages([
          AIChatMessage(role: .user, content: "Question \(index)"),
          AIChatMessage(role: .assistant, content: "Answer \(index)"),
        ])
    }
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: threads,
      selectedThreadID: threads[0].id,
      settlementSettings: AIChatThreadSettlementSettings()
    ), legacyURL: transcriptURL)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    _ = await store.refreshSyncedAIChatTranscript()

    let probe = MainActorStallProbe()
    probe.start()
    for _ in 0..<5 { _ = await store.refreshSyncedAIChatTranscript() }
    let skipStall = probe.stop()

    threads[1_000] = threads[1_000].replacingMessages(
      threads[1_000].messages + [AIChatMessage(role: .assistant, content: "Remote follow-up")]
    )
    try AIChatTranscriptStore.shared.flush(AIChatTranscriptSnapshot(
      threads: threads,
      selectedThreadID: threads[0].id,
      settlementSettings: AIChatThreadSettlementSettings()
    ), legacyURL: transcriptURL)
    probe.start()
    _ = await store.refreshSyncedAIChatTranscript()
    let importStall = probe.stop()

    print("PERFORMANCE synced-chat-refresh-main-actor-stall: skip=\(String(format: "%.1f", skipStall)) ms import=\(String(format: "%.1f", importStall)) ms")
    XCTAssertLessThan(skipStall, 100, "an unchanged synced refresh stalled the main actor")
    XCTAssertLessThan(importStall, 250, "importing one remote change stalled the main actor")
  }
}
