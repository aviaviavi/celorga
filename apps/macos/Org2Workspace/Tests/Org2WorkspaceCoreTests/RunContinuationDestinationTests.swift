import XCTest
@testable import Org2WorkspaceCore

/// Runs go back to the agent that carries them. No runtime, including the
/// OpenClaw Gateway, is a built-in default for new or resumed work.
@MainActor
final class RunContinuationDestinationTests: XCTestCase {
  private let codexID = AIChatDestinationConfiguration.localCodexID
  private let openClawID = AIChatDestinationConfiguration.openClawID
  private let openCodeID = AIChatDestinationConfiguration.localOpenCodeID

  func testDefaultRunDestinationIsConfiguredOrFirstEnabledNeverOpenClawByDefault() throws {
    let store = try makeStore(enabled: [openClawID, codexID], order: [openClawID, codexID])
    XCTAssertEqual(store.defaultRunDestination?.id, openClawID, "without a choice, the user's first enabled destination")

    store.defaultRunDestinationID = codexID
    XCTAssertEqual(store.defaultRunDestination?.id, codexID)

    store.defaultRunDestinationID = AIChatDestinationConfiguration.localPiID
    XCTAssertEqual(store.defaultRunDestination?.id, openClawID, "a disabled choice falls back to the first enabled destination")

    let codexOnly = try makeStore(enabled: [codexID], order: [codexID, openClawID])
    XCTAssertEqual(codexOnly.defaultRunDestination?.id, codexID)
    XCTAssertEqual(
      codexOnly.runContinuationDestination(for: try run(comments: []))?.id,
      codexID,
      "a run that records no agent never falls back to OpenClaw"
    )
  }

  func testResumedRunGoesBackToTheAgentThatCarriesIt() throws {
    let store = try makeStore(enabled: [codexID, openClawID, openCodeID], order: [codexID, openClawID, openCodeID])
    store.defaultRunDestinationID = codexID

    XCTAssertEqual(
      store.runContinuationDestination(for: try run(destinationRef: openCodeID, comments: []))?.id,
      openCodeID,
      "the run's own destination wins"
    )
    XCTAssertEqual(
      store.runContinuationDestination(for: try run(comments: [
        "AI destination: \(openClawID)\nAI chat thread: aaaaaaaa-0000-4000-8000-000000000001",
        "AI destination: \(openCodeID)\nAI chat thread: bbbbbbbb-0000-4000-8000-000000000002"
      ]))?.id,
      openCodeID,
      "the latest chat it was handed to"
    )
    XCTAssertEqual(
      store.runContinuationDestination(for: try run(comments: [
        "OPENCLAW_KEY: session:abc\nOPENCLAW_KIND: run\nOPENCLAW_SESSION: unknown"
      ]))?.id,
      openClawID,
      "a run the OpenClaw adapter created returns to OpenClaw"
    )
    store.agentProfiles = [try profile(id: "writer", defaultRuntime: "opencode")]
    XCTAssertEqual(
      store.runContinuationDestination(for: try run(agentRef: "writer", comments: []))?.id,
      openCodeID,
      "the run's agent profile picks its preferred runtime"
    )
    XCTAssertEqual(store.runContinuationDestination(for: try run(comments: []))?.id, codexID)
    XCTAssertFalse(store.runContinuationUsesOpenClawGateway(try run(comments: [])))
  }

  func testReplyAndResumeForANonOpenClawRunRecordsLocallyAndReturnsToItsAgent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-run-continuation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let originThread = "cccccccc-0000-4000-8000-000000000003"
    struct Created: Decodable { let run: AgentRunItem }
    let created: Created = try await cli.runJSON([
      "run", "create", "--goal", "Draft the quarterly summary",
      "--thread", originThread, "--destination-ref", openCodeID,
      "--dir", root.path, "--json"
    ])
    _ = try await cli.run(["run", "start", created.run.id, "--dir", root.path, "--json"])
    let blocked: AgentRunItem = try await cli.runJSON([
      "run", "block", created.run.id, "--reason", "Which quarter?", "--dir", root.path, "--json"
    ])

    let store = try makeStore(
      enabled: [openClawID, codexID, openCodeID],
      order: [openClawID, codexID, openCodeID],
      cli: cli,
      root: root
    )
    store.corpusRoot = root
    store.replaceAgentRunsForTesting([blocked])

    let succeeded = await store.respondToAgentRunClarification(blocked, response: "Use Q3.")

    XCTAssertTrue(succeeded, store.errorText ?? "")
    let thread = try XCTUnwrap(store.aiChatThreads.first { $0.title.hasPrefix("Resume: ") })
    XCTAssertEqual(thread.destinationID, openCodeID, "the run returns to the agent that created it, not OpenClaw")
    let resumed: AgentRunItem = try await cli.runJSON([
      "run", "show", blocked.id, "--dir", root.path, "--json"
    ])
    XCTAssertEqual(resumed.status, "running")
    XCTAssertTrue(resumed.comments.contains { $0.body == "Use Q3." }, "the answer is recorded without the OpenClaw Gateway")
    XCTAssertEqual(resumed.linkedAIChatThreadID, thread.id.uuidString.lowercased())
  }

  // MARK: - Helpers

  private func makeStore(
    enabled: [String],
    order: [String],
    cli: Org2CLI? = nil,
    root: URL? = nil
  ) throws -> WorkspaceStore {
    let suiteName = "RunContinuationDestination.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptRoot = root ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-run-continuation-store-\(UUID().uuidString)", isDirectory: true)
    let store = WorkspaceStore(
      cli: cli,
      defaults: defaults,
      aiChatTranscriptURL: transcriptRoot.appendingPathComponent(".org2/openclaw-chat.json"),
      aiChatSendHandler: { _, _, _, _ in "Done" },
      codexSendHandlerForTesting: { _, _, _ in "Done" },
      legacyDefaultsDomains: []
    )
    let byID = Dictionary(uniqueKeysWithValues: AIChatDestinationConfiguration.defaults.map { ($0.id, $0) })
    store.aiChatDestinations = order.compactMap { id in
      guard var destination = byID[id] else { return nil }
      destination.isEnabled = enabled.contains(id)
      return destination
    }
    return store
  }

  private func run(
    destinationRef: String? = nil,
    agentRef: String? = nil,
    comments: [String]
  ) throws -> AgentRunItem {
    var value: [String: Any] = [
      "id": "run-\(UUID().uuidString.lowercased())",
      "goal": "Prepare a cited briefing",
      "acceptanceCriteria": [],
      "status": "blocked",
      "blockedReason": "Which period?",
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [],
      "validations": [],
      "comments": comments.enumerated().map { index, body in [
        "id": "comment-\(index)",
        "author": "Example",
        "body": body,
        "createdAt": "2026-07-14T00:00:0\(index).000Z"
      ] },
      "events": [],
      "createdAt": "2026-07-14T00:00:00.000Z",
      "updatedAt": "2026-07-14T00:01:00.000Z"
    ]
    if let destinationRef { value["destinationRef"] = destinationRef }
    if let agentRef { value["agentRef"] = agentRef }
    return try JSONDecoder().decode(AgentRunItem.self, from: JSONSerialization.data(withJSONObject: value))
  }

  private func profile(id: String, defaultRuntime: String) throws -> AgentProfileItem {
    let value: [String: Any] = [
      "schema": "org2:agent-profile:v1",
      "id": id,
      "name": "Writer",
      "description": "",
      "status": "active",
      "responsibilities": [],
      "capabilities": [],
      "skills": [],
      "defaultRuntime": defaultRuntime,
      "runtimeBindings": [],
      "goalRefs": [],
      "file": "agent-profiles/\(id).org",
      "createdAt": "2026-07-14T00:00:00.000Z",
      "updatedAt": "2026-07-14T00:00:00.000Z"
    ]
    return try JSONDecoder().decode(AgentProfileItem.self, from: JSONSerialization.data(withJSONObject: value))
  }
}
