import Foundation
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AutomationChatConfigurationTests: XCTestCase {
  func testScheduledAIChatAutomationDoesNotInheritInteractiveOverrides() async throws {
    try await checkAutomationConfiguration(destinationModel: nil)
  }

  func testAutomationPreservesExplicitDestinationModel() async throws {
    try await checkAutomationConfiguration(destinationModel: "configured-destination-model")
  }

  func testAutomationFileOverridesDestinationModelAndReasoning() async throws {
    try await checkAutomationConfiguration(
      destinationModel: "configured-destination-model",
      automationModel: "automation-model",
      automationReasoningEffort: "xhigh"
    )
  }

  func testFailedAdmissionReplyFailsScheduledRun() async throws {
    try await checkAutomationConfiguration(
      destinationModel: nil,
      reply: "Run visibility retry exhausted.\nORG2_RUN_OUTCOME: failed",
      expectedStatus: "failed"
    )
  }

  func testOutcomeReceiptParsingIsExactAndFailureWins() {
    XCTAssertNil(AutomationRunReplyOutcome.parse("I saw ORG2_RUN_OUTCOME: failed in a log"))
    XCTAssertNil(AutomationRunReplyOutcome.parse("> ORG2_RUN_OUTCOME: failed"))
    XCTAssertEqual(AutomationRunReplyOutcome.parse("ORG2_RUN_OUTCOME: completed"), .completed)
    XCTAssertEqual(AutomationRunReplyOutcome.parse("ORG2_RUN_OUTCOME: completed\nORG2_RUN_OUTCOME: failed"), .failed)
  }

  private func checkAutomationConfiguration(
    destinationModel: String?,
    automationModel: String? = nil,
    automationReasoningEffort: String? = nil,
    reply: String = "Local summary ready.",
    expectedStatus: String = "completed"
  ) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("automation-chat-defaults-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AutomationChatConfigurationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let destinationID = AIChatDestinationConfiguration.openClawID
    defaults.set(try JSONEncoder().encode([
      destinationID: ["model": "interactive-model", "reasoningEffort": "high"]
    ]), forKey: "Org2Workspace.aiChat.lastConfigurations.v1")

    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    var createArguments = [
      "workflow", "create", "configuration-regression",
      "--title", "Configuration regression",
      "--prompt", "Prepare a local summary.",
      "--destination-ref", destinationID,
      "--schedule", "0 9 * * 1",
      "--timezone", "America/Los_Angeles",
      "--now", "2099-08-30T15:58:00Z",
      "--dir", root.path, "--json"
    ]
    if let automationModel {
      createArguments += ["--model", automationModel]
    }
    if let automationReasoningEffort {
      createArguments += ["--reasoning-effort", automationReasoningEffort]
    }
    _ = try await cli.run(createArguments)
    let store = WorkspaceStore(
      cli: cli,
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chats.json"),
      aiChatSendHandler: { messages, _, _, _ in
        XCTAssertTrue(messages.last(where: { $0.role == .user })?.content
          .contains("ORG2_WORKFLOW_ID: configuration-regression") == true)
        return reply
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    if let destinationModel {
      var destination = try XCTUnwrap(store.aiChatDestination(id: destinationID))
      destination.model = destinationModel
      store.updateAIChatDestination(destination)
    }
    store.setAutomationSchedulerActive(true, checkIntervalNanoseconds: 60_000_000_000)
    defer { store.setAutomationSchedulerActive(false) }
    let dueAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2099-08-31T16:00:30Z"))
    await store.checkDueAgentAutomations(now: dueAt)
    let timeout = Date().addingTimeInterval(8)
    while Date() < timeout {
      if store.agentRuns.contains(where: {
        $0.workflowId == "configuration-regression" && $0.status == expectedStatus
      }) { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    let run = try XCTUnwrap(store.agentRuns.first(where: { $0.workflowId == "configuration-regression" }))
    XCTAssertEqual(run.status, expectedStatus)
    XCTAssertEqual(run.attempt?.triggerId, "schedule")
    let automation = try XCTUnwrap(store.aiChatThreads.first(where: {
      $0.title == "Automation: Configuration regression"
    }))
    XCTAssertEqual(automation.model, automationModel ?? destinationModel)
    XCTAssertEqual(automation.reasoningEffort, automationReasoningEffort)
    XCTAssertEqual(automation.messages.last(where: { $0.role == .assistant })?.content, reply)

    // Automation dispatch must not clear the user's preferences for ordinary chats.
    store.createAIChatThread(runtime: .openClaw)
    XCTAssertEqual(store.selectedAIChatModel, "interactive-model")
    XCTAssertEqual(store.selectedAIChatReasoningEffort, "high")
  }
}
