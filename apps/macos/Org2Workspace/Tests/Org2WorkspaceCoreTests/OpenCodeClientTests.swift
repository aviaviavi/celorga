import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class OpenCodeClientTests: XCTestCase {
  func testArgumentsResumeSessionAndApplyModelVariant() {
    let arguments = OpenCodeClient.arguments(
      sessionID: "ses_123",
      model: "openai/gpt-5",
      reasoningEffort: "high",
      attachmentPaths: ["/tmp/file.txt"],
      message: "Review this"
    )

    XCTAssertEqual(arguments.prefix(7), [
      "run", "--format", "json", "--thinking", "--agent", "openorg", "--auto"
    ])
    XCTAssertFalse(arguments.contains("--standalone"))
    XCTAssertTrue(arguments.containsAdjacent(["--session", "ses_123"]))
    XCTAssertTrue(arguments.containsAdjacent(["--model", "openai/gpt-5#high"]))
    XCTAssertEqual(arguments.suffix(4), ["--file", "/tmp/file.txt", "--", "Review this"])
  }

  func testArgumentsKeepDashLeadingMessageAsPrompt() {
    let arguments = OpenCodeClient.arguments(
      sessionID: nil,
      model: nil,
      reasoningEffort: nil,
      attachmentPaths: [],
      message: "- header chip sounds good!\n- ship it"
    )

    XCTAssertEqual(arguments.suffix(2), ["--", "- header chip sounds good!\n- ship it"])
  }

  func testJSONStreamDecodesReasoningParts() async {
    var decoder = OpenCodeStreamDecoder()
    let events = EventLog()
    await decoder.consume(#"{"type":"reasoning","sessionID":"ses_1","part":{"id":"r-1","type":"reasoning","text":"  Weighing options.\n\n"}}"#) { event in
      if case .reasoning(let id, let text) = event { await events.append("reasoning:\(id):\(text)") }
    }
    await decoder.consume(#"{"type":"reasoning","sessionID":"ses_1","part":{"id":"r-2","text":"   "}}"#) { event in
      if case .reasoning = event { await events.append("blank") }
    }
    let recorded = await events.values
    XCTAssertTrue(recorded.contains("reasoning:r-1:Weighing options."))
    XCTAssertFalse(recorded.contains("blank"))
    XCTAssertEqual(decoder.result.reply, "")
    XCTAssertFalse(decoder.result.succeeded)
  }

  func testJSONStreamDecodesSessionTextAndTools() async {
    var decoder = OpenCodeStreamDecoder()
    let events = EventLog()
    await decoder.consume(#"{"type":"step_start","sessionID":"ses_123","part":{}}"#) { event in
      if case .sessionStarted(let id) = event { await events.append("session:\(id)") }
    }
    await decoder.consume(#"{"type":"tool_use","sessionID":"ses_123","part":{"id":"tool-1","tool":"glob","state":{"status":"completed"}}}"#) { event in
      if case .activity(let id, let title, let status) = event {
        await events.append("tool:\(id):\(title):\(status.rawValue)")
      }
    }
    await decoder.consume(#"{"type":"text","sessionID":"ses_123","part":{"text":"Yes."}}"#) { event in
      if case .textDelta(let text) = event { await events.append("text:\(text)") }
    }

    XCTAssertEqual(decoder.result.sessionID, "ses_123")
    XCTAssertEqual(decoder.result.reply, "Yes.")
    XCTAssertTrue(decoder.result.succeeded)
    let loggedEvents = await events.values
    XCTAssertEqual(loggedEvents, ["session:ses_123", "tool:tool-1:Searching:succeeded", "text:Yes."])
  }

  func testInlineConfigurationMapsReadOnlyPermissions() throws {
    let configuration = try OpenCodeClient.inlineConfiguration(
      systemPrompt: "Use the Org2 rules.",
      sandboxAccess: .readOnly
    )
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(configuration.utf8)) as? [String: Any])
    let agents = try XCTUnwrap(object["agent"] as? [String: Any])
    let agent = try XCTUnwrap(agents["openorg"] as? [String: Any])
    let permissions = try XCTUnwrap(agent["permission"] as? [String: String])
    XCTAssertEqual(agent["prompt"] as? String, "Use the Org2 rules.")
    XCTAssertEqual(permissions["edit"], "deny")
    XCTAssertEqual(permissions["bash"], "deny")
    XCTAssertEqual(permissions["external_directory"], "deny")
    XCTAssertEqual(object["permission"] as? [String: String], permissions)
  }

  func testInlineConfigurationGivesSubagentsTheTurnSandbox() throws {
    // Subagents (explore, general) do not inherit agent-level permissions. A
    // subagent "ask" in a headless run is never answered and hangs the turn.
    let configuration = try OpenCodeClient.inlineConfiguration(
      systemPrompt: "Use the Org2 rules.",
      sandboxAccess: .fullAccess
    )
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(configuration.utf8)) as? [String: Any])
    let global = try XCTUnwrap(object["permission"] as? [String: String])
    XCTAssertEqual(global["external_directory"], "allow")
    XCTAssertEqual(global["bash"], "allow")
    XCTAssertEqual(global["edit"], "allow")
    let agents = try XCTUnwrap(object["agent"] as? [String: Any])
    let agent = try XCTUnwrap(agents["openorg"] as? [String: Any])
    XCTAssertEqual(agent["permission"] as? [String: String], global)
  }

  func testManagedRemoteRejectsCommandInjectionHost() {
    XCTAssertThrowsError(try OpenCodeClient.managedRemoteSSHArguments(
      sshHost: "press.local; touch /tmp/nope"
    ))
    XCTAssertNoThrow(try OpenCodeClient.managedRemoteSSHArguments(sshHost: "press.local"))
    XCTAssertThrowsError(try OpenCodeClient.managedRemoteModelSSHArguments(
      sshHost: "press.local; touch /tmp/nope"
    ))
    XCTAssertNoThrow(try OpenCodeClient.managedRemoteModelSSHArguments(sshHost: "press.local"))
    XCTAssertThrowsError(try OpenCodeClient.managedRemoteSteerSSHArguments(
      sshHost: "press.local; touch /tmp/nope"
    ))
    XCTAssertNoThrow(try OpenCodeClient.managedRemoteSteerSSHArguments(sshHost: "press.local"))
  }

  func testSteerUsesExplicitDeliveryAndPreservesAttachments() throws {
    let attachment = AIChatAttachment(
      fileName: "note.txt",
      mimeType: "text/plain",
      data: Data("context".utf8)
    )
    let data = try OpenCodeClient.steerRequestData(
      message: "Use the new constraint",
      attachments: [attachment]
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]
    )
    XCTAssertEqual(object["text"] as? String, "Use the new constraint")
    XCTAssertEqual(object["delivery"] as? String, "steer")
    let files = try XCTUnwrap(object["files"] as? [[String: String]])
    XCTAssertEqual(files.first?["name"], "note.txt")
    XCTAssertEqual(files.first?["uri"], "data:text/plain;base64,Y29udGV4dA==")
    XCTAssertEqual(
      OpenCodeClient.steerArguments(
        serverURL: "http://127.0.0.1:54321",
        sessionID: "ses_123",
        data: data
      ),
      [
        "api", "--server", "http://127.0.0.1:54321",
        "session.prompt", "--param", "sessionID=ses_123", "--data", data
      ]
    )
  }

  func testPrivateServerCredentialsReachLocalAndRemoteCommands() {
    let environment = OpenCodeClient.privateServerEnvironment(
      ["KEEP": "yes", "OPENCODE_SERVER_PASSWORD": "stale"],
      serverPassword: "per-run-secret",
      configuration: "{\"agent\":{}}"
    )
    XCTAssertEqual(environment["KEEP"], "yes")
    XCTAssertEqual(environment["OPENCODE_SERVER_PASSWORD"], "per-run-secret")
    XCTAssertEqual(environment["OPENCODE_CONFIG_CONTENT"], "{\"agent\":{}}")
    XCTAssertTrue(OpenCodeClient.managedRemotePythonBootstrap.contains(
      #"environment["OPENCODE_SERVER_PASSWORD"] = payload["serverPassword"]"#
    ))
    XCTAssertTrue(OpenCodeClient.managedRemoteSteerPythonBootstrap.contains(
      #"environment["OPENCODE_SERVER_PASSWORD"] = payload["serverPassword"]"#
    ))
  }

  func testModelCatalogParsingKeepsOnlyProviderModelIDs() {
    XCTAssertEqual(OpenCodeClient.modelIDs(from: """
    anthropic/claude-sonnet-4-6
    log line without an id
    opencode/space-bunny-free
    anthropic/claude-sonnet-4-6
    /missing-provider
    missing-model/
    """), [
      "anthropic/claude-sonnet-4-6",
      "opencode/space-bunny-free"
    ])
  }

  func testLocalModelCatalogReloadsAnEmptyOpenCodeService() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("OpenCodeClientTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let executable = root.appendingPathComponent("opencode")
    try """
    #!/bin/sh
    if [ "$1" = "reload" ]; then
      /usr/bin/touch .reloaded
      exit 0
    fi
    if [ "$1" = "models" ] && [ -f .reloaded ]; then
      printf '%s\\n' 'anthropic/claude-sonnet-4-6' 'opencode/space-bunny-free'
    fi
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )

    let client = OpenCodeClient(
      executableURL: executable,
      environment: ["PATH": root.path]
    ) { _, _ in }
    let models = try await client.listModels(
      cwd: root,
      configuredModel: "anthropic/claude-opus-4-6"
    )

    XCTAssertEqual(models.map(\.id), [
      "anthropic/claude-opus-4-6",
      "anthropic/claude-sonnet-4-6",
      "opencode/space-bunny-free"
    ])
    XCTAssertEqual(models.first(where: \.isDefault)?.id, "anthropic/claude-opus-4-6")
  }
}

private actor EventLog {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private extension Array where Element == String {
  func containsAdjacent(_ adjacent: [String]) -> Bool {
    guard !adjacent.isEmpty, adjacent.count <= count else { return false }
    for start in 0...(count - adjacent.count) {
      if Array(self[start..<(start + adjacent.count)]) == adjacent { return true }
    }
    return false
  }
}
