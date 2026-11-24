import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor ClaudeEventRecorder {
  private var values: [String] = []

  func record(_ event: ClaudeCodeEvent) {
    switch event {
    case .sessionStarted(let sessionID): values.append("session:\(sessionID)")
    case .textDelta(let text): values.append("delta:\(text)")
    case .activity(_, let title, _): values.append("activity:\(title)")
    case .warning(let message): values.append("warning:\(message)")
    }
  }

  func snapshot() -> [String] { values }
}

final class ClaudeCodeClientTests: XCTestCase {
  func testExecutableResolutionPrefersExplicitConfiguration() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-claude-resolver-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    XCTAssertEqual(
      ClaudeCodeClient.resolveExecutableURL(environment: [
        "ORG2_CLAUDE_EXECUTABLE": executable.path,
        "HOME": root.path,
        "PATH": ""
      ]),
      executable.standardizedFileURL
    )
  }

  func testArgumentsMapLocalAgentAccessAndSessionOptions() {
    let prompt = URL(fileURLWithPath: "/tmp/context.txt")
    let attachments = URL(fileURLWithPath: "/tmp/attachments", isDirectory: true)
    let arguments = ClaudeCodeClient.arguments(
      sessionID: "session-123",
      model: "sonnet",
      sandboxAccess: .workspaceWrite,
      systemPromptFile: prompt,
      attachmentDirectory: attachments
    )

    XCTAssertTrue(arguments.contains("--include-partial-messages"))
    XCTAssertEqual(arguments.value(after: "--input-format"), "stream-json")
    XCTAssertNil(arguments.value(after: "--effort"), "an unset effort must leave Claude Code's default")
    XCTAssertEqual(arguments.value(after: "--permission-mode"), "acceptEdits")
    XCTAssertEqual(arguments.value(after: "--resume"), "session-123")
    XCTAssertEqual(arguments.value(after: "--model"), "sonnet")
    XCTAssertEqual(arguments.value(after: "--add-dir"), attachments.path)
    XCTAssertEqual(ClaudeCodeClient.permissionMode(for: .readOnly), "plan")
    XCTAssertEqual(ClaudeCodeClient.permissionMode(for: .fullAccess), "bypassPermissions")
  }

  func testStreamDecoderExtractsSessionDeltasActivitiesAndResult() async {
    let recorder = ClaudeEventRecorder()
    var decoder = ClaudeCodeStreamDecoder()
    let lines = [
      #"{"type":"system","subtype":"init","session_id":"abc"}"#,
      #"{"type":"stream_event","session_id":"abc","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"tool-1","name":"Read"}}}"#,
      #"{"type":"stream_event","session_id":"abc","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"#,
      #"{"type":"result","subtype":"success","is_error":false,"session_id":"abc","result":"Hello world"}"#
    ]
    for line in lines {
      await decoder.consume(line) { event in await recorder.record(event) }
    }

    XCTAssertEqual(decoder.result.sessionID, "abc")
    XCTAssertEqual(decoder.result.reply, "Hello world")
    XCTAssertTrue(decoder.result.succeeded)
    let events = await recorder.snapshot()
    XCTAssertEqual(events, ["session:abc", "activity:Reading", "delta:Hello"])
  }

  func testRunTurnUsesStreamJSONAndReturnsResumableSession() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-claude-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude")
    let argumentsLog = root.appendingPathComponent("arguments.txt")
    let inputLog = root.appendingPathComponent("input.txt")
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > "$ORG2_CLAUDE_TEST_ARGUMENTS"
    IFS= read -r line
    printf '%s' "$line" > "$ORG2_CLAUDE_TEST_INPUT"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"session-new"}'
    printf '%s\\n' '{"type":"stream_event","session_id":"session-new","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"session-new","result":"Hi from Claude"}'
    # Like Claude Code with streaming input, wait for more input until EOF.
    cat > /dev/null
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let recorder = ClaudeEventRecorder()
    let client = ClaudeCodeClient(
      executableURL: executable,
      environment: [
        "ORG2_CLAUDE_TEST_ARGUMENTS": argumentsLog.path,
        "ORG2_CLAUDE_TEST_INPUT": inputLog.path,
        "PATH": "/usr/bin:/bin",
        "HOME": root.path
      ]
    ) { _, event in
      await recorder.record(event)
    }

    let result = try await client.runTurn(
      openOrgThreadID: UUID(),
      existingSessionID: "session-old",
      message: "Hello Claude",
      systemPrompt: "OpenOrg context",
      attachments: [],
      cwd: root,
      model: "sonnet",
      sandboxAccess: .readOnly
    )

    XCTAssertEqual(result, ClaudeCodeTurnResult(sessionID: "session-new", reply: "Hi from Claude"))
    let input = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: inputLog)) as? [String: Any]
    )
    XCTAssertEqual(input["type"] as? String, "user")
    XCTAssertEqual((input["message"] as? [String: Any])?["content"] as? String, "Hello Claude")
    let arguments = try String(contentsOf: argumentsLog, encoding: .utf8)
    XCTAssertTrue(arguments.contains("--resume\nsession-old"))
    XCTAssertTrue(arguments.contains("--permission-mode\nplan"))
    XCTAssertTrue(arguments.contains("--model\nsonnet"))
    let events = await recorder.snapshot()
    XCTAssertEqual(events, ["session:session-new", "delta:Hi"])
  }
}

final class ClaudeCodeSteeringTests: XCTestCase {
  /// Guidance typed while Claude Code works reaches the running session's
  /// input instead of waiting for a follow-up turn.
  func testSteerWritesGuidanceToTheRunningTurn() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-claude-steer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude")
    let inputLog = root.appendingPathComponent("input.jsonl")
    let script = """
    #!/bin/sh
    IFS= read -r first
    printf '%s\\n' "$first" > "$ORG2_CLAUDE_TEST_INPUT"
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"steer-session"}'
    IFS= read -r second
    printf '%s\\n' "$second" >> "$ORG2_CLAUDE_TEST_INPUT"
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"steer-session","result":"Working on it"}'
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"steer-session","result":"Used the shorter title"}'
    cat > /dev/null
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let threadID = UUID()
    let client = ClaudeCodeClient(
      executableURL: executable,
      environment: [
        "ORG2_CLAUDE_TEST_INPUT": inputLog.path,
        "PATH": "/usr/bin:/bin",
        "HOME": root.path
      ]
    ) { _, _ in }

    async let turn = client.runTurn(
      openOrgThreadID: threadID,
      existingSessionID: nil,
      message: "Draft the note",
      systemPrompt: "Celorga context",
      attachments: [],
      cwd: root,
      model: nil,
      sandboxAccess: .readOnly
    )
    let deadline = Date().addingTimeInterval(5)
    while await !client.canSteer(openOrgThreadID: threadID), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await client.steer(openOrgThreadID: threadID, message: "Use a shorter title")
    let result = try await turn

    XCTAssertEqual(result.sessionID, "steer-session")
    XCTAssertEqual(result.reply, "Working on it\n\nUsed the shorter title")
    let lines = try String(contentsOf: inputLog, encoding: .utf8)
      .split(separator: "\n")
      .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
      .compactMap { ($0["message"] as? [String: Any])?["content"] as? String }
    XCTAssertEqual(lines, ["Draft the note", "Use a shorter title"])
    let canSteerAfterTurn = await client.canSteer(openOrgThreadID: threadID)
    XCTAssertFalse(canSteerAfterTurn)
    do {
      try await client.steer(openOrgThreadID: threadID, message: "too late")
      XCTFail("a finished turn must not accept guidance")
    } catch ClaudeCodeError.invalidResponse(let message) {
      XCTAssertTrue(message.contains("no active Claude Code turn"))
    }
  }

  /// Guidance Claude Code folds into its current answer gets no result of
  /// its own; the turn must still end.
  func testTurnEndsWhenFoldedGuidanceGetsNoResultOfItsOwn() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-claude-fold-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("claude")
    let script = """
    #!/bin/sh
    IFS= read -r first
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"fold-session"}'
    IFS= read -r second
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"session_id":"fold-session","result":"Done, with your guidance"}'
    cat > /dev/null
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let threadID = UUID()
    let client = ClaudeCodeClient(
      executableURL: executable,
      environment: ["PATH": "/usr/bin:/bin", "HOME": root.path],
      pendingGuidanceIdleTimeout: .milliseconds(200)
    ) { _, _ in }

    async let turn = client.runTurn(
      openOrgThreadID: threadID,
      existingSessionID: nil,
      message: "Draft the note",
      systemPrompt: "Celorga context",
      attachments: [],
      cwd: root,
      model: nil,
      sandboxAccess: .readOnly
    )
    let deadline = Date().addingTimeInterval(5)
    while await !client.canSteer(openOrgThreadID: threadID), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await client.steer(openOrgThreadID: threadID, message: "Mention the date")
    let result = try await turn
    XCTAssertEqual(result.reply, "Done, with your guidance")
  }
}

@MainActor
final class WorkspaceClaudeCodeDestinationTests: XCTestCase {
  func testBuiltInClaudeDestinationRoutesAndPersistsSession() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-claude-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("chats.json")
    let suiteName = "WorkspaceClaudeCodeDestinationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      claudeSendHandlerForTesting: { messages, _, _ in
        XCTAssertEqual(messages.last(where: { $0.role == .user })?.content, "Hello Claude")
        return ClaudeCodeTurnResult(sessionID: "claude-session-1", reply: "Hello from Claude")
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root)

    XCTAssertNil(store.aiChatDestination(id: AIChatDestinationConfiguration.localClaudeID))
    var claude = try XCTUnwrap(
      AIChatDestinationConfiguration.defaults.first(where: {
        $0.id == AIChatDestinationConfiguration.localClaudeID
      })
    )
    XCTAssertFalse(claude.isEnabled)
    claude.isEnabled = true
    store.updateAIChatDestination(claude)
    let threadID = store.createAIChatThread(
      destinationID: AIChatDestinationConfiguration.localClaudeID
    )
    await store.sendAIChatMessage(text: "Hello Claude")

    let thread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID }))
    XCTAssertEqual(thread.runtime, .claude)
    XCTAssertEqual(thread.destinationID, AIChatDestinationConfiguration.localClaudeID)
    XCTAssertEqual(
      thread.runtimeThreadID(forDestinationID: AIChatDestinationConfiguration.localClaudeID),
      "claude-session-1"
    )
    XCTAssertEqual(thread.messages.last(where: { $0.role == .assistant })?.content, "Hello from Claude")
  }

  func testDueAutomationCreatesDurableRunAndDispatchesToClaude() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-claude-automation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("chats.json")
    let suiteName = "WorkspaceClaudeCodeDestinationTests.automation.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    _ = try await cli.run([
      "workflow", "create", "weekly-claude-brief",
      "--title", "Weekly Claude brief",
      "--prompt", "Prepare the weekly brief from the corpus.",
      "--destination-ref", AIChatDestinationConfiguration.localClaudeID,
      "--model", "opus",
      "--schedule", "0 9 * * 1",
      "--timezone", "America/Los_Angeles",
      "--now", "2099-08-30T15:58:00Z",
      "--dir", root.path,
      "--json"
    ])
    let store = WorkspaceStore(
      cli: cli,
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      claudeSendHandlerForTesting: { messages, _, _ in
        let prompt = messages.last(where: { $0.role == .user })?.content ?? ""
        XCTAssertTrue(prompt.contains("ORG2_WORKFLOW_ID: weekly-claude-brief"))
        XCTAssertTrue(prompt.contains("ORG2_AI_DESTINATION_REF: builtin.claude"))
        XCTAssertTrue(prompt.contains("ORG2_MODEL: opus"))
        XCTAssertTrue(prompt.contains("Prepare the weekly brief from the corpus."))
        return ClaudeCodeTurnResult(sessionID: "automation-session", reply: "The weekly brief is ready.")
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    var claude = try XCTUnwrap(AIChatDestinationConfiguration.defaults.first(where: {
      $0.id == AIChatDestinationConfiguration.localClaudeID
    }))
    claude.isEnabled = true
    store.updateAIChatDestination(claude)
    store.setAutomationSchedulerActive(true, checkIntervalNanoseconds: 60_000_000_000)
    defer { store.setAutomationSchedulerActive(false) }

    let dueAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2099-08-31T16:00:30Z"))
    await store.checkDueAgentAutomations(now: dueAt)
    XCTAssertEqual(store.automationOwnerHostRef, "desktop")
    let timeout = Date().addingTimeInterval(8)
    while Date() < timeout {
      if store.agentRuns.contains(where: {
        $0.workflowId == "weekly-claude-brief" && $0.status == "completed"
      }) {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }

    let run = try XCTUnwrap(store.agentRuns.first(where: { $0.workflowId == "weekly-claude-brief" }))
    XCTAssertEqual(run.destinationRef, AIChatDestinationConfiguration.localClaudeID)
    XCTAssertEqual(run.status, "completed")
    XCTAssertEqual(run.attempt?.triggerId, "schedule")
    XCTAssertEqual(run.outcome?.summary, "The weekly brief is ready.")
    let thread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.title == "Automation: Weekly Claude brief" }))
    XCTAssertEqual(thread.destinationID, AIChatDestinationConfiguration.localClaudeID)
    XCTAssertEqual(thread.model, "opus")
    XCTAssertEqual(thread.messages.last(where: { $0.role == .assistant })?.content, "The weekly brief is ready.")
  }

  func testFailedDailyDispatchRemainsVisibleAndRecoversOnLaterDays() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-daily-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "WorkspaceClaudeCodeDestinationTests.recovery.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    _ = try await cli.run([
      "workflow", "create", "daily-repair", "--title", "Daily repair",
      "--prompt", "Repair today's items.", "--destination-ref", "missing-on-host",
      "--schedule", "45 23 * * *", "--timezone", "America/Los_Angeles",
      "--now", "2099-10-07T23:10:00Z", "--dir", root.path, "--json"
    ])
    let store = WorkspaceStore(
      cli: cli, defaults: defaults, aiChatTranscriptURL: root.appendingPathComponent("chats.json"),
      claudeSendHandlerForTesting: { _, _, _ in
        ClaudeCodeTurnResult(sessionID: "recovered-daily", reply: "Today's repair completed.")
      }, legacyDefaultsDomains: []
    )
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(root, persistsDefault: false)
    store.setAutomationSchedulerActive(true, checkIntervalNanoseconds: 3_600_000_000_000)
    defer { store.setAutomationSchedulerActive(false) }
    let formatter = ISO8601DateFormatter()
    let firstDay = try XCTUnwrap(formatter.date(from: "2099-10-08T06:46:00Z"))
    await store.checkDueAgentAutomations(now: firstDay)
    let first = try XCTUnwrap(store.agentRuns.first(where: { $0.workflowId == "daily-repair" }))
    XCTAssertEqual(first.status, "failed")
    XCTAssertTrue(first.failure?.contains("missing-on-host") == true)
    XCTAssertTrue(first.failure?.contains("desktop") == true)
    XCTAssertTrue(first.failure?.contains("available on this host") == true)
    XCTAssertTrue(store.aiChatThreads.isEmpty, "an unavailable explicit destination must not fall back")

    await store.checkDueAgentAutomations(now: firstDay)
    XCTAssertEqual(store.agentRuns.filter { $0.workflowId == "daily-repair" }.count, 1)
    XCTAssertEqual(store.automationSchedulerStatusText, "1 automation last failed")
    XCTAssertTrue(store.automationSchedulerErrorText?.contains("missing-on-host") == true)

    var claude = try XCTUnwrap(AIChatDestinationConfiguration.defaults.first {
      $0.id == AIChatDestinationConfiguration.localClaudeID
    })
    claude.isEnabled = true
    store.updateAIChatDestination(claude)
    _ = try await cli.run([
      "workflow", "create", "other-work", "--title", "Other work",
      "--prompt", "Prepare the brief.", "--destination-ref", claude.id,
      "--schedule", "0 0 * * *", "--timezone", "UTC",
      "--now", "2099-10-07T23:10:00Z", "--dir", root.path, "--json"
    ])
    await store.checkDueAgentAutomations(now: firstDay)
    XCTAssertEqual(store.automationSchedulerStatusText, "Dispatched 1 automation")
    XCTAssertTrue(store.automationSchedulerErrorText?.contains("missing-on-host") == true,
                  "dispatching unrelated work must preserve the failed job's warning")
    _ = try await cli.run(["workflow", "pause", "other-work", "--dir", root.path, "--json"])

    let secondDay = try XCTUnwrap(formatter.date(from: "2099-10-09T06:46:00Z"))
    await store.checkDueAgentAutomations(now: secondDay)
    let failed = store.agentRuns.filter { $0.workflowId == "daily-repair" }
    XCTAssertEqual(failed.count, 2)
    XCTAssertTrue(failed.allSatisfy { $0.status == "failed" })
    XCTAssertEqual(Set(failed.compactMap { $0.attempt?.number }), [1, 2])

    _ = try await cli.run([
      "workflow", "schedule", "daily-repair", "--cron", "45 23 * * *",
      "--timezone", "America/Los_Angeles", "--destination-ref", claude.id,
      "--dir", root.path, "--json"
    ])
    let thirdDay = try XCTUnwrap(formatter.date(from: "2099-10-10T06:46:00Z"))
    await store.checkDueAgentAutomations(now: thirdDay)
    let timeout = Date().addingTimeInterval(8)
    while Date() < timeout && !store.agentRuns.contains(where: {
      $0.workflowId == "daily-repair" && $0.status == "completed"
    }) {
      try await Task.sleep(for: .milliseconds(25))
    }
    let recovered = try XCTUnwrap(store.agentRuns.first {
      $0.workflowId == "daily-repair" && $0.status == "completed"
    })
    XCTAssertEqual(recovered.attempt?.number, 3)
    XCTAssertEqual(recovered.destinationRef, claude.id)
    await store.checkDueAgentAutomations(now: thirdDay)
    XCTAssertNil(store.automationSchedulerErrorText)
    XCTAssertEqual(store.automationSchedulerStatusText, "Automations are up to date")
  }
}

private extension Array where Element == String {
  func value(after flag: String) -> String? {
    guard let index = firstIndex(of: flag), indices.contains(index + 1) else { return nil }
    return self[index + 1]
  }
}
