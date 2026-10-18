import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class ChatAgentProfileTests: XCTestCase {
  func testThreadAgentSurvivesPersistenceHydrationAndMetadataUpdates() throws {
    let ref = UUID().uuidString
    let original = AIChatThread(title: "Agent chat", sessionKey: "test", agentRef: ref)
    let restored = try JSONDecoder().decode(AIChatThread.self, from: JSONEncoder().encode(original))
    XCTAssertEqual(restored.agentRef, ref)
    XCTAssertEqual(restored.replacingAIChatMetadata(title: "Renamed").agentRef, ref)
    XCTAssertEqual(restored.replacingPendingTurn(nil).agentRef, ref)
    XCTAssertEqual(restored.hydrating(messages: []).agentRef, ref)
    XCTAssertNil(restored.replacingAIChatMetadata(agentRef: .some(nil)).agentRef)
    let legacy = AIChatThread(title: "Old chat", sessionKey: "legacy")
    XCTAssertNil(try JSONDecoder().decode(AIChatThread.self, from: JSONEncoder().encode(legacy)).agentRef)
  }

  func testAgentContextIsIncludedForEveryRuntimeAndKeepsStableIdentity() {
    let ref = UUID().uuidString, goal = UUID().uuidString
    let profile = AgentProfileItem(schema: "org2:agent-profile:v1", id: ref, name: "Example Reviewer",
      description: "Find useful revenue signals", status: "active", responsibilities: ["Research accounts"],
      capabilities: ["Research"], skills: ["account-research"], defaultRuntime: "openclaw",
      runtimeBindings: [], goalRefs: [goal],
      primaryGoalRef: goal, reportsToAgentRef: nil, file: "/local/agent-profiles/scout.org", createdAt: "today", updatedAt: "today")
    let context = AIChatWorkspaceContext(localCorpusRoot: "/local", remoteCorpusRoot: "/remote",
      selectedSurface: "AI Chat", selectedLocation: nil, selectedEntrySource: nil, backlinks: nil,
      agenda: nil, searchQuery: "", searchResults: [], chatAgentRef: ref, chatAgentProfile: profile)
    for prompt in [context.systemPrompt(), context.codexSystemPrompt(), context.localAgentSystemPrompt(runtime: "claude", runtimeTitle: "Claude Code")] {
      XCTAssertTrue(prompt.contains("Example Reviewer"))
      XCTAssertTrue(prompt.contains("Research accounts"))
      XCTAssertTrue(prompt.contains("account-research"))
      XCTAssertTrue(prompt.contains("AGENT_REF: \(ref)"))
      XCTAssertTrue(prompt.contains("GOAL_REF: \(goal)"))
    }
  }

  @MainActor
  func testSelectingAgentAdoptsDefaultRuntimeAndKeepsItOverrideable() throws {
    let suiteName = "ChatAgentProfileTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-agent-profile-chat-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.createAIChatThread(destinationID: AIChatDestinationConfiguration.localCodexID)
    let profile = AgentProfileItem(
      schema: "org2:agent-profile:v1",
      id: "example-reviewer",
      name: "Example Reviewer",
      description: "",
      status: "active",
      responsibilities: [],
      capabilities: [],
      skills: [],
      defaultRuntime: "openclaw",
      runtimeBindings: [],
      goalRefs: [],
      primaryGoalRef: nil,
      reportsToAgentRef: nil,
      file: "/tmp/example-reviewer.org2",
      createdAt: "today",
      updatedAt: "today"
    )

    store.setSelectedChatAgent(profile)

    XCTAssertEqual(store.selectedChatAgentRef, profile.id)
    XCTAssertEqual(store.selectedAIChatDestination.id, AIChatDestinationConfiguration.openClawID)
    store.setSelectedAIChatDestination(AIChatDestinationConfiguration.localCodexID)
    XCTAssertEqual(store.selectedAIChatDestination.id, AIChatDestinationConfiguration.localCodexID)
    XCTAssertEqual(store.selectedChatAgentRef, profile.id)
  }
}
