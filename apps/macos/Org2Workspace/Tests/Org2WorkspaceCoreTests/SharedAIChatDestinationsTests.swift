import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class SharedAIChatDestinationsTests: XCTestCase {
  private func makeStore(root: URL, suite: String) throws -> (WorkspaceStore, UserDefaults) {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("\(suite).json"),
      legacyDefaultsDomains: []
    )
    return (store, defaults)
  }

  /// A destination configured on one Mac reaches another Mac that opens the
  /// same corpus, without its credentials.
  func testSharedDestinationsReachAnotherMacThroughTheCorpus() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-shared-destinations-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let firstSuite = "SharedAIChatDestinationsTests.first.\(UUID().uuidString)"
    let secondSuite = "SharedAIChatDestinationsTests.second.\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults().removePersistentDomain(forName: firstSuite)
      UserDefaults().removePersistentDomain(forName: secondSuite)
    }

    let (first, _) = try makeStore(root: root, suite: firstSuite)
    first.setCorpusRoot(root, persistsDefault: false)
    XCTAssertFalse(first.aiChatDestinationsSharedWithCorpus)
    let remote = AIChatDestinationConfiguration(
      id: "remote-opencode-example",
      name: "Studio OpenCode",
      mention: "studio",
      adapter: .openCodeRemote,
      endpoint: "builder@studio.example",
      workspaceRoot: "~/notes"
    )
    first.updateAIChatDestination(remote)
    first.updateAIChatDestination(AIChatDestinationConfiguration(
      id: "gateway-example",
      name: "Lab Gateway",
      mention: "lab",
      adapter: .openClaw,
      endpoint: "https://builder:hunter2@gateway.example/v1"
    ))
    first.setAIChatDestinationsSharedWithCorpus(true)
    XCTAssertTrue(first.aiChatDestinationsSharedWithCorpus)

    let sharedURL = SharedAIChatDestinations.fileURL(corpusRoot: root)
    let sharedText = try String(contentsOf: sharedURL, encoding: .utf8)
    XCTAssertTrue(sharedText.contains("org2:ai-chat-destinations:v1"))
    XCTAssertFalse(sharedText.contains("hunter2"), "a shared corpus must not carry credentials")

    let (second, _) = try makeStore(root: root, suite: secondSuite)
    XCTAssertNil(second.aiChatDestination(id: remote.id))
    second.setCorpusRoot(root, persistsDefault: false)
    XCTAssertTrue(second.aiChatDestinationsSharedWithCorpus)
    XCTAssertEqual(second.aiChatDestination(id: remote.id)?.endpoint, "builder@studio.example")
    XCTAssertEqual(second.aiChatDestination(id: remote.id)?.workspaceRoot, "~/notes")
    XCTAssertEqual(
      second.aiChatDestination(id: "gateway-example")?.endpoint,
      "https://builder@gateway.example/v1"
    )

    // A later destination on the second Mac flows back to the first.
    second.updateAIChatDestination(AIChatDestinationConfiguration(
      id: "laptop-pi-example",
      name: "Laptop Pi",
      mention: "laptop-pi",
      adapter: .piRemote,
      endpoint: "builder@laptop.example"
    ))
    XCTAssertEqual(first.importSharedAIChatDestinations(), ["laptop-pi-example"])
    XCTAssertNotNil(first.aiChatDestination(id: "laptop-pi-example"))

    // Turning sharing off removes the corpus copy, not anyone's destinations.
    second.setAIChatDestinationsSharedWithCorpus(false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sharedURL.path))
    XCTAssertNotNil(second.aiChatDestination(id: remote.id))
    first.importSharedAIChatDestinations()
    XCTAssertFalse(first.aiChatDestinationsSharedWithCorpus)
    XCTAssertNotNil(first.aiChatDestination(id: "laptop-pi-example"))
  }

  func testMergeKeepsLocalSettingsAndRenumbersTakenMentions() {
    let local = [
      AIChatDestinationConfiguration(id: "a", name: "Local", mention: "studio", adapter: .codexManagedRemote, endpoint: "me@local.example")
    ]
    let shared = [
      AIChatDestinationConfiguration(id: "a", name: "Other", mention: "studio", adapter: .codexManagedRemote, endpoint: "me@other.example"),
      AIChatDestinationConfiguration(id: "b", name: "Studio Pi", mention: "studio", adapter: .piRemote, endpoint: "me@pi.example")
    ]
    let merged = SharedAIChatDestinations.merging(shared, into: local)
    XCTAssertEqual(merged.map(\.id), ["a", "b"])
    XCTAssertEqual(merged[0].endpoint, "me@local.example")
    XCTAssertEqual(merged[1].mention, "studio-2")
  }
}
