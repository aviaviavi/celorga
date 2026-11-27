import XCTest
@testable import Org2WorkspaceCore

final class AntigravityClientTests: XCTestCase {
  // MARK: Arguments and permissions

  func testArgumentsUseStdinStreamResumeAndOptions() {
    let arguments = AntigravityClient.arguments(
      conversationID: "conv-123",
      model: "gemini-3.8-flash-medium",
      reasoningEffort: "high",
      sandboxAccess: .workspaceWrite,
      attachmentDirectory: "/tmp/attachments"
    )
    XCTAssertEqual(Array(arguments.prefix(4)), [
      "--input-format", "stream-json", "--output-format", "stream-json",
    ])
    XCTAssertTrue(arguments.contains(["--conversation", "conv-123"]))
    XCTAssertTrue(arguments.contains(["--model", "gemini-3.8-flash-medium"]))
    XCTAssertTrue(arguments.contains(["--effort", "high"]))
    XCTAssertTrue(arguments.contains(["--add-dir", "/tmp/attachments"]))
    XCTAssertFalse(arguments.contains("--dangerously-skip-permissions"))
    XCTAssertFalse(arguments.contains("-p"), "The prompt travels on stdin, never in argv")
  }

  func testUnknownEffortAndEmptyValuesAreOmitted() {
    let arguments = AntigravityClient.arguments(
      conversationID: "  ",
      model: nil,
      reasoningEffort: "minimal",
      sandboxAccess: .readOnly,
      attachmentDirectory: nil
    )
    XCTAssertFalse(arguments.contains("--conversation"))
    XCTAssertFalse(arguments.contains("--model"))
    XCTAssertFalse(arguments.contains("--effort"))
    XCTAssertFalse(arguments.contains("--add-dir"))
  }

  func testSandboxAccessMapsToSessionOnlySettings() throws {
    func settings(_ access: CodexSandboxAccess) throws -> [String: Any] {
      let arguments = AntigravityClient.arguments(
        conversationID: nil, model: nil, reasoningEffort: nil,
        sandboxAccess: access, attachmentDirectory: nil
      )
      let index = try XCTUnwrap(arguments.firstIndex(of: "--settings"))
      let data = Data(arguments[index + 1].utf8)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    let readOnly = try settings(.readOnly)
    XCTAssertEqual(readOnly["agentMode"] as? String, "")
    XCTAssertEqual(readOnly["toolPermission"] as? String, "request-review")
    let deny = (readOnly["permissions"] as? [String: Any])?["deny"] as? [String]
    XCTAssertEqual(Set(deny ?? []), ["write_file(*)", "command(*)", "mcp(*)"])

    let workspace = try settings(.workspaceWrite)
    XCTAssertEqual(workspace["agentMode"] as? String, "accept-edits")
    XCTAssertEqual(workspace["toolPermission"] as? String, "proceed-in-sandbox")
    XCTAssertEqual(workspace["enableTerminalSandbox"] as? Bool, true)

    let full = try settings(.fullAccess)
    XCTAssertEqual(full["allowNonWorkspaceAccess"] as? Bool, true)
    XCTAssertTrue(AntigravityClient.arguments(
      conversationID: nil, model: nil, reasoningEffort: nil,
      sandboxAccess: .fullAccess, attachmentDirectory: nil
    ).contains("--dangerously-skip-permissions"))
  }

  func testPromptCarriesContextMessageAndAttachmentPaths() throws {
    let prompt = AntigravityClient.prompt(
      message: "Summarize the agenda",
      systemPrompt: "Corpus: /tmp/corpus",
      attachmentPaths: ["/tmp/a/notes.txt"]
    )
    XCTAssertTrue(prompt.hasPrefix("<celorga-context>\nCorpus: /tmp/corpus\n</celorga-context>"))
    XCTAssertTrue(prompt.contains("\n\nSummarize the agenda\n\n"))
    XCTAssertTrue(prompt.hasSuffix("- /tmp/a/notes.txt"))

    let line = try AntigravityClient.inputLine(prompt: "line one\nline \"two\"")
    XCTAssertEqual(line.last, 0x0A)
    XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "One NDJSON line, even for multi-line prompts")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
    XCTAssertEqual(object["event"] as? String, "user")
    XCTAssertEqual((object["message"] as? [String: Any])?["content"] as? String, "line one\nline \"two\"")
  }

  // MARK: Stream decoding

  func testStreamDecodesConversationTextToolsAndResult() async {
    var decoder = AntigravityStreamDecoder()
    let events = AntigravityEventLog()
    let lines = [
      #"{"event":"init","conversation_id":"c3b6","init":{"cwd":"/tmp","tools":["run_command"],"permission_mode":"request-review"}}"#,
      #"{"event":"step_update","step_update":{"conversation_id":"c3b6","step_index":0,"state":"DONE","step_type":"user_input"}}"#,
      #"{"event":"step_update","step_update":{"conversation_id":"c3b6","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command"}}"#,
      #"{"event":"step_update","step_update":{"conversation_id":"c3b6","step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hi"},"output":"hi\r\n"}}}"#,
      #"{"event":"step_update","step_update":{"conversation_id":"c3b6","step_index":3,"state":"ACTIVE","step_type":"agent_response","text_delta":"app"}}"#,
      #"{"event":"step_update","step_update":{"conversation_id":"c3b6","step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"le\n"}}"#,
      "not json",
      #"{"event":"result","result":{"conversation_id":"c3b6","status":"SUCCESS","response":"apple\n","num_turns":1}}"#,
    ]
    for line in lines {
      await decoder.consume(line) { event in await events.record(event) }
    }
    XCTAssertEqual(decoder.result.conversationID, "c3b6")
    XCTAssertEqual(decoder.result.reply, "apple\n")
    XCTAssertEqual(decoder.result.streamedReply, "apple\n")
    XCTAssertTrue(decoder.result.succeeded)
    let logged = await events.values
    XCTAssertEqual(logged, [
      "session:c3b6",
      "tool:c3b6-2:Running command:running",
      "tool:c3b6-2:Running command:succeeded",
      "text:app",
      "text:le\n",
    ])
  }

  func testFailedToolAndErrorResultsAreReported() async {
    var decoder = AntigravityStreamDecoder()
    let events = AntigravityEventLog()
    await decoder.consume(#"{"event":"step_update","step_update":{"conversation_id":"x","step_index":4,"state":"DONE","step_type":"tool","tool_name":"write_to_file","tool_info":{"name":"write_to_file","error":{"type":"denied","message":"no"}}}}"#) { event in
      await events.record(event)
    }
    await decoder.consume(#"{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"authentication failed or timed out"}}"#) { _ in }
    XCTAssertFalse(decoder.result.succeeded)
    XCTAssertEqual(decoder.result.errors, ["authentication failed or timed out"])
    let logged = await events.values
    XCTAssertEqual(logged, ["session:x", "tool:x-4:Editing:failed"])
    XCTAssertTrue(AntigravityClient.failureDetail(
      decoded: decoder.result, stderr: "", exitStatus: 1
    ).contains("`agy` once"))

    var waiting = AntigravityStreamDecoder()
    await waiting.consume(#"{"event":"result","result":{"conversation_id":"y","status":"WAITING","response":""}}"#) { _ in }
    XCTAssertFalse(waiting.result.succeeded)
    XCTAssertTrue(waiting.result.errors.first?.contains("waiting for input") == true)
  }

  func testModelListParsing() {
    let output = """
    gemini-4-neon-high             Gemini 4 Neon (High)
    gemini-3.8-flash-medium        Gemini 3.8 Flash (Medium)
    gemini-3.8-flash-medium        Gemini 3.8 Flash (Medium)
    ...

    """
    let models = AntigravityClient.parseModels(output)
    XCTAssertEqual(models.map(\.id), ["gemini-4-neon-high", "gemini-3.8-flash-medium"])
    XCTAssertEqual(models.first?.label, "Gemini 4 Neon (High)")
    XCTAssertEqual(AntigravityClient.configuredModelOptions(" custom ").map(\.id), ["custom"])
    XCTAssertTrue(AntigravityClient.configuredModelOptions(nil).isEmpty)
  }

  // MARK: Remote transport

  func testManagedRemoteRejectsCommandInjectionHost() {
    XCTAssertThrowsError(try AntigravityClient.managedRemoteSSHArguments(sshHost: "press.local; touch /tmp/nope"))
    XCTAssertThrowsError(try AntigravityClient.managedRemoteSSHArguments(sshHost: "-oProxyCommand=x"))
    let arguments = try? AntigravityClient.managedRemoteSSHArguments(sshHost: "user@press.local")
    XCTAssertEqual(arguments?.contains("BatchMode=yes"), true)
    XCTAssertEqual(arguments?.contains("user@press.local"), true)
  }

  func testRemoteBootstrapIsValidPython() throws {
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    guard FileManager.default.isExecutableFile(atPath: python.path) else {
      throw XCTSkip("python3 is not available")
    }
    let process = Process()
    process.executableURL = python
    process.arguments = ["-c", "import ast,sys; ast.parse(sys.stdin.read())"]
    let input = Pipe()
    process.standardInput = input
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(AntigravityClient.managedRemotePythonBootstrap.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertTrue(AntigravityClient.managedRemotePythonBootstrap
      .contains(AntigravityClient.attachmentDirectoryPlaceholder))
  }

  // MARK: End to end with a stand-in CLI

  func testRunTurnSendsPromptOnStdinAndResumesConversation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("antigravity-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("agy")
    // Records argv and stdin, checks an attachment exists, then replays a
    // documented stream for the conversation it was asked to resume.
    try """
    #!/bin/sh
    printf '%s\\n' "$@" > "\(root.path)/argv.txt"
    cat > "\(root.path)/stdin.txt"
    pwd > "\(root.path)/cwd.txt"
    conv=new-conversation
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "--conversation" ]; then conv="$arg"; fi
      if [ "$prev" = "--add-dir" ] && [ -f "$arg/notes.txt" ]; then echo yes > "\(root.path)/attachment.txt"; fi
      prev="$arg"
    done
    echo '{"event":"init","conversation_id":"'"$conv"'","init":{"cwd":"x","tools":[]}}'
    echo '{"event":"step_update","step_update":{"conversation_id":"'"$conv"'","step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"Done."}}'
    echo '{"event":"result","result":{"conversation_id":"'"$conv"'","status":"SUCCESS","response":"Done."}}'
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let corpus = root.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)

    let events = AntigravityEventLog()
    let client = AntigravityClient(executableURL: executable) { _, event in await events.record(event) }
    let first = try await client.runTurn(
      openOrgThreadID: UUID(),
      existingSessionID: nil,
      message: "Hello",
      systemPrompt: "Celorga context",
      attachments: [AIChatAttachment(fileName: "notes.txt", mimeType: "text/plain", data: Data("n".utf8))],
      cwd: corpus,
      model: nil,
      reasoningEffort: nil,
      sandboxAccess: .workspaceWrite
    )
    XCTAssertEqual(first, AntigravityTurnResult(sessionID: "new-conversation", reply: "Done."))
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("attachment.txt")), "yes\n")
    let stdin = try String(contentsOf: root.appendingPathComponent("stdin.txt"))
    XCTAssertTrue(stdin.contains(#""event":"user""#))
    XCTAssertTrue(stdin.contains("Celorga context"))
    XCTAssertTrue(stdin.contains("Hello"))
    let cwd = try String(contentsOf: root.appendingPathComponent("cwd.txt")).trimmingCharacters(in: .newlines)
    XCTAssertTrue(cwd.hasSuffix("/\(root.lastPathComponent)/corpus"), cwd)

    let resumed = try await client.runTurn(
      openOrgThreadID: UUID(),
      existingSessionID: "new-conversation",
      message: "Again",
      systemPrompt: "",
      attachments: [],
      cwd: corpus,
      model: "gemini-3.8-flash-medium",
      reasoningEffort: "low",
      sandboxAccess: .readOnly
    )
    XCTAssertEqual(resumed.sessionID, "new-conversation")
    let argv = try String(contentsOf: root.appendingPathComponent("argv.txt"))
      .split(separator: "\n").map(String.init)
    XCTAssertTrue(argv.contains(["--conversation", "new-conversation"]))
    XCTAssertTrue(argv.contains(["--model", "gemini-3.8-flash-medium"]))
    XCTAssertFalse(argv.contains("--add-dir"))
    let logged = await events.values
    XCTAssertTrue(logged.contains("session:new-conversation"))
    XCTAssertTrue(logged.contains("text:Done."))
  }

  func testRunTurnSurfacesErrorResultAndMissingExecutable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("antigravity-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("agy")
    try """
    #!/bin/sh
    cat > /dev/null
    echo "Error: authentication required. Run 'agy' to log in, then retry." >&2
    echo '{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"authentication failed or timed out"}}'
    exit 1
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let client = AntigravityClient(executableURL: executable) { _, _ in }
    do {
      _ = try await client.runTurn(
        openOrgThreadID: UUID(), existingSessionID: nil, message: "Hi", systemPrompt: "",
        attachments: [], cwd: root, model: nil, reasoningEffort: nil, sandboxAccess: .readOnly
      )
      XCTFail("An ERROR result must fail the turn")
    } catch let error as AntigravityError {
      guard case .turnFailed(let detail) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains("authentication failed"))
      XCTAssertTrue(detail.contains("Sign in"))
    }

    let missing = AntigravityClient(executableURL: nil) { _, _ in }
    do {
      _ = try await missing.runTurn(
        openOrgThreadID: UUID(), existingSessionID: nil, message: "Hi", systemPrompt: "",
        attachments: [], cwd: root, model: nil, reasoningEffort: nil, sandboxAccess: .readOnly
      )
      XCTFail("A missing CLI must fail")
    } catch AntigravityError.executableNotFound {}
  }

  // MARK: Destinations and routing

  func testBuiltInDestinationAndMentions() {
    let builtIn = AIChatDestinationConfiguration.defaults.first {
      $0.id == AIChatDestinationConfiguration.localAntigravityID
    }
    XCTAssertEqual(builtIn?.adapter, .antigravityLocal)
    XCTAssertEqual(builtIn?.isEnabled, false, "Opt-in, like the other local CLIs")
    XCTAssertEqual(AIChatDestinationConfiguration.defaultID(for: .antigravity), "builtin.antigravity")
    XCTAssertEqual(AIChatRuntime(agentProfileValue: "Antigravity"), .antigravity)
    XCTAssertEqual(AIChatDestinationAdapter.antigravityRemote.runtime, .antigravity)

    let remote = AIChatDestinationConfiguration(
      name: "Antigravity on press", mention: "agy-press", adapter: .antigravityRemote,
      endpoint: "user@press.local", workspaceRoot: "~/notes"
    )
    XCTAssertEqual(remote.harnessHostName, "press")
    XCTAssertTrue(remote.requiresEndpoint)
    XCTAssertFalse(remote.acceptsBearerToken)
    XCTAssertFalse(AIChatDestinationConfiguration(
      name: "Antigravity", mention: "antigravity", adapter: .antigravityLocal
    ).requiresEndpoint)

    XCTAssertEqual(AIChatRoomRouting("@antigravity check this").audience, .antigravity)
    XCTAssertEqual(AIChatRoomRouting("@agy check this").normalizedText, "@Antigravity check this")
    XCTAssertEqual(AIChatRoomRouting("@all go").audience, .everyone)
    XCTAssertEqual(AIChatAudience(runtime: .antigravity).runtimes, [.antigravity])
    XCTAssertEqual(
      AIChatRoomModelSelection().replacingModel("gemini-x", for: .antigravity).model(for: .antigravity),
      "gemini-x"
    )
  }

  func testOlderRoomModelSelectionsStillDecode() throws {
    let data = Data(#"{"codex":"gpt","pi":"p"}"#.utf8)
    let selection = try JSONDecoder().decode(AIChatRoomModelSelection.self, from: data)
    XCTAssertEqual(selection.codex, "gpt")
    XCTAssertNil(selection.antigravity)
  }
}

private actor AntigravityEventLog {
  private(set) var values: [String] = []

  func record(_ event: AntigravityEvent) {
    switch event {
    case .sessionStarted(let id): values.append("session:\(id)")
    case .textDelta(let text): values.append("text:\(text)")
    case .activity(let id, let title, let status): values.append("tool:\(id):\(title):\(status.rawValue)")
    case .warning(let message): values.append("warning:\(message)")
    }
  }
}

private extension Array where Element == String {
  func contains(_ adjacent: [String]) -> Bool {
    guard !adjacent.isEmpty, adjacent.count <= count else { return false }
    return indices.contains { start in
      let end = index(start, offsetBy: adjacent.count, limitedBy: endIndex) ?? endIndex
      return end - start == adjacent.count && Array(self[start..<end]) == adjacent
    }
  }
}
