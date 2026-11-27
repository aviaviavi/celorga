import Foundation

/// Runs Google Antigravity's terminal agent (`agy`) as a chat destination.
///
/// Each turn starts one headless `agy` process that reads a single prompt as
/// NDJSON on standard input (`--input-format stream-json`) and streams
/// `init`, `step_update`, and `result` events on standard output. Standard
/// input keeps a large Celorga context out of argv and out of remote shell
/// quoting, and, unlike `-p`, fails at once with an `ERROR` result instead of
/// waiting at an interactive sign-in prompt when the CLI is not signed in.
/// Follow-up turns resume the same Antigravity conversation by ID.
public enum AntigravityError: LocalizedError, Sendable {
  case executableNotFound
  case invalidSSHHost
  case missingRemoteWorkspace
  case launchFailed(String)
  case invalidResponse(String)
  case turnFailed(String)
  case interrupted

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "Antigravity CLI (agy) was not found. Install it from antigravity.google, then run `agy` once to sign in."
    case .invalidSSHHost:
      "Remote Antigravity needs a valid SSH host or ~/.ssh/config alias."
    case .missingRemoteWorkspace:
      "Remote Antigravity needs the Celorga corpus path on that machine."
    case .launchFailed(let detail):
      "Could not start Antigravity: \(detail)"
    case .invalidResponse(let detail):
      "Antigravity returned an invalid response: \(detail)"
    case .turnFailed(let detail):
      "Antigravity turn failed: \(detail)"
    case .interrupted:
      "Antigravity was stopped."
    }
  }
}

public enum AntigravityTransport: Equatable, Sendable {
  case local
  case managedRemote(sshHost: String, workspacePath: String)
}

public enum AntigravityEvent: Sendable {
  case sessionStarted(sessionID: String)
  case textDelta(String)
  case activity(id: String, title: String, status: AIChatRunActivity.Status)
  case warning(String)
}

public struct AntigravityTurnResult: Equatable, Sendable {
  public let sessionID: String
  public let reply: String

  public init(sessionID: String, reply: String) {
    self.sessionID = sessionID
    self.reply = reply
  }
}

struct AntigravityStreamResult: Equatable, Sendable {
  var conversationID: String?
  var reply = ""
  var streamedReply = ""
  var status: String?
  var errors: [String] = []

  var succeeded: Bool { status == "SUCCESS" && errors.isEmpty }
}

/// Decodes `agy --output-format stream-json` events.
struct AntigravityStreamDecoder: Sendable {
  private(set) var result = AntigravityStreamResult()

  mutating func consume(
    _ line: String,
    eventHandler: @Sendable (AntigravityEvent) async -> Void
  ) async {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let event = object["event"] as? String
    else { return }

    switch event {
    case "init":
      await adoptConversationID(object["conversation_id"] as? String, eventHandler: eventHandler)
    case "step_update":
      guard let step = object["step_update"] as? [String: Any] else { return }
      await adoptConversationID(step["conversation_id"] as? String, eventHandler: eventHandler)
      let stepType = step["step_type"] as? String ?? ""
      let state = step["state"] as? String ?? ""
      switch stepType {
      case "agent_response":
        // ACTIVE updates carry partial text and the final DONE carries the
        // remainder, so every fragment is incremental.
        if let delta = step["text_delta"] as? String, !delta.isEmpty {
          result.streamedReply += delta
          await eventHandler(.textDelta(delta))
        }
      case "tool":
        let toolInfo = step["tool_info"] as? [String: Any]
        let tool = (step["tool_name"] as? String) ?? (toolInfo?["name"] as? String) ?? "tool"
        let index = (step["step_index"] as? NSNumber).map { "\($0.intValue)" } ?? UUID().uuidString
        let id = "\(step["conversation_id"] as? String ?? result.conversationID ?? "agy")-\(index)"
        let status: AIChatRunActivity.Status
        if state == "DONE" {
          status = toolInfo?["error"] == nil ? .succeeded : .failed
        } else {
          status = .running
        }
        await eventHandler(.activity(id: id, title: Self.activityTitle(for: tool), status: status))
      default:
        break
      }
    case "result":
      guard let payload = object["result"] as? [String: Any] else { return }
      await adoptConversationID(payload["conversation_id"] as? String, eventHandler: eventHandler)
      let status = (payload["status"] as? String)?.uppercased() ?? "UNKNOWN"
      result.status = status
      if let response = payload["response"] as? String, !response.isEmpty {
        result.reply = response
      }
      if status != "SUCCESS" {
        let error = (payload["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        result.errors.append(error?.isEmpty == false
          ? error!
          : Self.statusDescription(status))
      }
    default:
      break
    }
  }

  private mutating func adoptConversationID(
    _ value: String?,
    eventHandler: @Sendable (AntigravityEvent) async -> Void
  ) async {
    guard let value, !value.isEmpty, result.conversationID != value else { return }
    let isFirst = result.conversationID == nil
    result.conversationID = value
    if isFirst { await eventHandler(.sessionStarted(sessionID: value)) }
  }

  nonisolated static func statusDescription(_ status: String) -> String {
    switch status {
    case "CANCELED": "Antigravity canceled the turn."
    case "INTERRUPTED": "Antigravity was interrupted."
    case "WAITING": "Antigravity stopped while waiting for input it cannot get in a chat turn."
    case "RUNNING": "Antigravity exited before the turn finished."
    case "INVALID": "Antigravity reached an invalid state."
    default: "Antigravity ended the turn with status \(status)."
    }
  }

  nonisolated static func activityTitle(for tool: String) -> String {
    let lowered = tool.lowercased()
    if lowered.contains("command") || lowered.contains("terminal") || lowered == "bash" {
      return "Running command"
    }
    if lowered.contains("write") || lowered.contains("edit") || lowered.contains("replace")
        || lowered.contains("create") {
      return "Editing"
    }
    if lowered.contains("search") || lowered.contains("grep") || lowered.contains("find")
        || lowered.contains("list") {
      return "Searching"
    }
    if lowered.contains("view") || lowered.contains("read") { return "Reading" }
    if lowered.contains("browser") || lowered.contains("url") || lowered.contains("web") {
      return "Browsing"
    }
    return "Using \(tool)"
  }
}

public actor AntigravityClient {
  public typealias EventHandler = @Sendable (UUID, AntigravityEvent) async -> Void

  /// `agy`'s reasoning-effort levels. Each model accepts a subset.
  public nonisolated static let reasoningOptions = [
    AIChatReasoningOption(id: "low", label: "Low"),
    AIChatReasoningOption(id: "medium", label: "Medium"),
    AIChatReasoningOption(id: "high", label: "High"),
    AIChatReasoningOption(id: "xhigh", label: "Extra High"),
    AIChatReasoningOption(id: "max", label: "Maximum")
  ]

  static let attachmentDirectoryPlaceholder = "__OPENORG_ATTACHMENT_DIR__"

  private let transport: AntigravityTransport
  private let executableURL: URL?
  private let environment: [String: String]
  private let eventHandler: EventHandler
  private var activeProcesses: [UUID: Process] = [:]

  public init(
    transport: AntigravityTransport = .local,
    executableURL: URL? = AntigravityClient.resolveExecutableURL(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    eventHandler: @escaping EventHandler
  ) {
    self.transport = transport
    self.executableURL = executableURL
    self.environment = environment
    self.eventHandler = eventHandler
  }

  nonisolated public static func resolveExecutableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    LocalAgentExecutableLocator.resolve(
      executableName: "agy",
      configuredKey: "ORG2_ANTIGRAVITY_EXECUTABLE",
      environment: environment,
      fileManager: fileManager
    )
  }

  /// Session-only settings (`--settings`) that map Celorga's filesystem
  /// access onto Antigravity's permission model. They are never saved to the
  /// user's `settings.json`. Deny rules apply in every Antigravity mode.
  nonisolated static func sessionSettings(for sandboxAccess: CodexSandboxAccess) -> String {
    let settings: [String: Any]
    switch sandboxAccess {
    case .readOnly:
      // Default mode asks before writes and commands, and headless runs
      // soft-deny what they cannot ask about. The deny rules keep this
      // read-only even if Antigravity treats an empty mode as unset.
      settings = [
        "agentMode": "",
        "toolPermission": "request-review",
        "enableTerminalSandbox": true,
        "permissions": ["deny": ["write_file(*)", "command(*)", "mcp(*)"]]
      ]
    case .workspaceWrite:
      // Workspace edits proceed; commands run without asking only inside the
      // terminal sandbox, as with Codex's workspace-write mode.
      settings = [
        "agentMode": "accept-edits",
        "toolPermission": "proceed-in-sandbox",
        "enableTerminalSandbox": true
      ]
    case .fullAccess:
      settings = ["allowNonWorkspaceAccess": true]
    }
    let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }

  nonisolated static func arguments(
    conversationID: String?,
    model: String?,
    reasoningEffort: String?,
    sandboxAccess: CodexSandboxAccess,
    attachmentDirectory: String?
  ) -> [String] {
    var arguments = [
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--settings", sessionSettings(for: sandboxAccess)
    ]
    if sandboxAccess == .fullAccess {
      arguments.append("--dangerously-skip-permissions")
    }
    if let conversationID = normalized(conversationID) {
      arguments.append(contentsOf: ["--conversation", conversationID])
    }
    if let model = normalized(model) {
      arguments.append(contentsOf: ["--model", model])
    }
    if let effort = normalized(reasoningEffort),
       reasoningOptions.contains(where: { $0.id == effort }) {
      arguments.append(contentsOf: ["--effort", effort])
    }
    if let attachmentDirectory = normalized(attachmentDirectory) {
      arguments.append(contentsOf: ["--add-dir", attachmentDirectory])
    }
    return arguments
  }

  /// `agy` has no system-prompt flag, so Celorga's workspace context travels
  /// with each prompt, followed by any attached files' paths.
  nonisolated static func prompt(
    message: String,
    systemPrompt: String,
    attachmentPaths: [String]
  ) -> String {
    var parts: [String] = []
    let context = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !context.isEmpty {
      parts.append("<celorga-context>\n\(context)\n</celorga-context>")
    }
    parts.append(message)
    if !attachmentPaths.isEmpty {
      parts.append("Attached files (read them as needed):\n"
        + attachmentPaths.map { "- \($0)" }.joined(separator: "\n"))
    }
    return parts.joined(separator: "\n\n")
  }

  /// One NDJSON line for `--input-format stream-json`.
  nonisolated static func inputLine(prompt: String) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: [
      "event": "user",
      "message": ["content": prompt]
    ] as [String: Any])
    data.append(0x0A)
    return data
  }

  nonisolated static func validatedSSHHost(_ rawSSHHost: String) throws -> String {
    let sshHost = rawSSHHost.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_@:%[]+"))
    guard !sshHost.isEmpty,
          !sshHost.hasPrefix("-"),
          sshHost.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else { throw AntigravityError.invalidSSHHost }
    return sshHost
  }

  nonisolated static func managedRemoteSSHArguments(sshHost: String) throws -> [String] {
    [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=12",
      try validatedSSHHost(sshHost),
      managedRemoteCommand()
    ]
  }

  private nonisolated static func managedRemoteCommand() -> String {
    let script = Data(managedRemotePythonBootstrap.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote Antigravity requires python3." >&2; exit 127; }; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(script)\"),\"<openorg-antigravity-adapter>\",\"exec\"))"'"#
  }

  /// Runs on the remote host: materializes attachments, then runs `agy` in
  /// the corpus with the prompt on its standard input.
  nonisolated static let managedRemotePythonBootstrap = #"""
import base64
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile

payload = json.load(sys.stdin)
workspace = os.path.expanduser(payload["workspacePath"])
if not os.path.isabs(workspace) or not os.path.isdir(workspace):
    sys.stderr.write("Remote Antigravity workspace does not exist: %s\n" % workspace)
    sys.exit(66)

agy = shutil.which("agy")
if not agy:
    sys.stderr.write("Antigravity CLI (agy) was not found on the remote PATH.\n")
    sys.exit(127)

placeholder = "__OPENORG_ATTACHMENT_DIR__"
temporary_root = tempfile.mkdtemp(prefix="openorg-antigravity-")
try:
    attachment_paths = []
    used = set()
    for index, attachment in enumerate(payload.get("attachments", [])):
        raw_name = os.path.basename(attachment.get("fileName") or ("attachment-%d" % (index + 1)))
        safe_name = raw_name.replace("/", "-")
        if safe_name in ("", ".", ".."):
            safe_name = "attachment-%d" % (index + 1)
        base, ext = os.path.splitext(safe_name)
        suffix = 2
        while safe_name.lower() in used:
            safe_name = "%s-%d%s" % (base, suffix, ext)
            suffix += 1
        used.add(safe_name.lower())
        path = os.path.join(temporary_root, safe_name)
        with open(path, "wb") as handle:
            handle.write(base64.b64decode(attachment["data"]))
        os.chmod(path, 0o600)
        attachment_paths.append(path)

    arguments = [temporary_root if value == placeholder else value for value in payload["arguments"]]
    prompt = payload["prompt"]
    if attachment_paths:
        prompt += "\n\nAttached files (read them as needed):\n" + "\n".join("- " + p for p in attachment_paths)
    line = json.dumps({"event": "user", "message": {"content": prompt}}) + "\n"

    process = subprocess.Popen([agy] + arguments, cwd=workspace, stdin=subprocess.PIPE)
    def forward(signum, _frame):
        if process.poll() is None:
            process.send_signal(signum)
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    process.stdin.write(line.encode("utf-8"))
    process.stdin.close()
    sys.exit(process.wait())
finally:
    shutil.rmtree(temporary_root, ignore_errors=True)
"""#

  public func runTurn(
    openOrgThreadID: UUID,
    existingSessionID: String?,
    message: String,
    systemPrompt: String,
    attachments: [AIChatAttachment],
    cwd: URL,
    model: String?,
    reasoningEffort: String?,
    sandboxAccess: CodexSandboxAccess
  ) async throws -> AntigravityTurnResult {
    if let existing = activeProcesses[openOrgThreadID], existing.isRunning {
      throw AntigravityError.launchFailed("another turn is already running in this chat")
    }

    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()
    var temporaryRoot: URL?
    let inputData: Data

    switch transport {
    case .local:
      guard let executableURL else { throw AntigravityError.executableNotFound }
      var attachmentPaths: [String] = []
      if !attachments.isEmpty {
        let root = FileManager.default.temporaryDirectory
          .appendingPathComponent("openorg-antigravity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
          at: root,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
        temporaryRoot = root
        attachmentPaths = try Self.materializeAttachments(attachments, under: root).map(\.path)
      }
      process.executableURL = executableURL
      process.arguments = Self.arguments(
        conversationID: existingSessionID,
        model: model,
        reasoningEffort: reasoningEffort,
        sandboxAccess: sandboxAccess,
        attachmentDirectory: temporaryRoot?.path
      )
      process.currentDirectoryURL = cwd.standardizedFileURL
      process.environment = LocalAgentExecutableLocator.processEnvironment(
        environment,
        executableURL: executableURL
      )
      inputData = try Self.inputLine(prompt: Self.prompt(
        message: message,
        systemPrompt: systemPrompt,
        attachmentPaths: attachmentPaths
      ))
    case .managedRemote(let sshHost, let workspacePath):
      let workspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !workspacePath.isEmpty else { throw AntigravityError.missingRemoteWorkspace }
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      process.arguments = try Self.managedRemoteSSHArguments(sshHost: sshHost)
      let payload = AntigravityRemotePayload(
        workspacePath: workspacePath,
        arguments: Self.arguments(
          conversationID: existingSessionID,
          model: model,
          reasoningEffort: reasoningEffort,
          sandboxAccess: sandboxAccess,
          attachmentDirectory: attachments.isEmpty ? nil : Self.attachmentDirectoryPlaceholder
        ),
        prompt: Self.prompt(message: message, systemPrompt: systemPrompt, attachmentPaths: []),
        attachments: try attachments.map {
          AntigravityRemoteAttachment(fileName: $0.fileName, data: try $0.loadData().base64EncodedString())
        }
      )
      inputData = try JSONEncoder().encode(payload)
      process.environment = environment
    }

    defer {
      if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.standardInput = standardInput

    do {
      try process.run()
      activeProcesses[openOrgThreadID] = process
      try standardInput.fileHandleForWriting.write(contentsOf: inputData)
      try standardInput.fileHandleForWriting.close()
    } catch {
      if process.isRunning { process.terminate() }
      activeProcesses.removeValue(forKey: openOrgThreadID)
      throw AntigravityError.launchFailed(error.localizedDescription)
    }

    let handler = eventHandler
    let outputTask = Task.detached(priority: .userInitiated) {
      try await Self.consumeOutput(
        standardOutput.fileHandleForReading,
        openOrgThreadID: openOrgThreadID,
        eventHandler: handler
      )
    }
    let errorTask = Task.detached(priority: .utility) {
      String(decoding: try await BlockingIO.readToEnd(standardError.fileHandleForReading) ?? Data(), as: UTF8.self)
    }
    let status: Int32 = await withTaskCancellationHandler {
      await BlockingIO.terminationStatus(of: process)
    } onCancel: {
      Task { await self.interrupt(openOrgThreadID: openOrgThreadID) }
    }
    let decoded: AntigravityStreamResult
    do {
      decoded = try await outputTask.value
    } catch {
      activeProcesses.removeValue(forKey: openOrgThreadID)
      throw AntigravityError.invalidResponse(error.localizedDescription)
    }
    let stderr = (try? await errorTask.value)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    activeProcesses.removeValue(forKey: openOrgThreadID)

    if Task.isCancelled || process.terminationReason == .uncaughtSignal
        || decoded.status == "INTERRUPTED" || decoded.status == "CANCELED" {
      throw AntigravityError.interrupted
    }
    guard status == 0, decoded.succeeded else {
      throw AntigravityError.turnFailed(Self.failureDetail(
        decoded: decoded, stderr: stderr, exitStatus: status
      ))
    }
    guard let conversationID = decoded.conversationID, !conversationID.isEmpty else {
      throw AntigravityError.invalidResponse("the response did not include a conversation ID")
    }
    let reply = decoded.reply.isEmpty ? decoded.streamedReply : decoded.reply
    return AntigravityTurnResult(sessionID: conversationID, reply: reply)
  }

  nonisolated static func failureDetail(
    decoded: AntigravityStreamResult,
    stderr: String,
    exitStatus: Int32
  ) -> String {
    let detail = decoded.errors.joined(separator: "\n")
    let combined = [detail, stderr].first(where: { !$0.isEmpty })
      ?? "Antigravity exited with status \(exitStatus)."
    if combined.localizedCaseInsensitiveContains("authentication") {
      return combined + "\nSign in by running `agy` once in Terminal on the machine that runs it."
    }
    return combined
  }

  public func interrupt(openOrgThreadID: UUID) {
    guard let process = activeProcesses[openOrgThreadID], process.isRunning else { return }
    process.interrupt()
  }

  public func shutdown() {
    for process in activeProcesses.values where process.isRunning { process.terminate() }
    activeProcesses.removeAll()
  }

  /// `agy models` lists one model per line: a slug, then its display name.
  public func listModels(cwd: URL, configuredModel: String?) async -> [AIChatModelOption] {
    let output: String?
    switch transport {
    case .local:
      guard let executableURL else { return Self.configuredModelOptions(configuredModel) }
      output = await Self.capture(
        executableURL: executableURL,
        arguments: ["models"],
        cwd: cwd,
        environment: LocalAgentExecutableLocator.processEnvironment(environment, executableURL: executableURL)
      )
    case .managedRemote(let sshHost, _):
      guard let host = try? Self.validatedSSHHost(sshHost) else {
        return Self.configuredModelOptions(configuredModel)
      }
      output = await Self.capture(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        arguments: [
          "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host,
          #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; exec agy models'"#
        ],
        cwd: nil,
        environment: environment
      )
    }
    let discovered = output.map(Self.parseModels) ?? []
    guard !discovered.isEmpty else { return Self.configuredModelOptions(configuredModel) }
    let defaultID = Self.normalized(configuredModel)
    var options = discovered.map { model in
      AIChatModelOption(
        id: model.id,
        label: model.label,
        supportsReasoning: true,
        reasoningOptions: Self.reasoningOptions,
        isDefault: model.id == defaultID
      )
    }
    if let defaultID, !options.contains(where: { $0.id == defaultID }) {
      options.insert(contentsOf: Self.configuredModelOptions(defaultID), at: 0)
    }
    return options
  }

  nonisolated static func parseModels(_ output: String) -> [(id: String, label: String)] {
    var seen = Set<String>()
    return output.split(whereSeparator: \.isNewline).compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("..."),
            let slugEnd = line.firstIndex(where: \.isWhitespace)
      else { return nil }
      let slug = String(line[..<slugEnd])
      let label = line[slugEnd...].trimmingCharacters(in: .whitespaces)
      let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_/:"))
      guard !label.isEmpty,
            slug.unicodeScalars.allSatisfy({ allowed.contains($0) }),
            slug.rangeOfCharacter(from: .letters) != nil,
            seen.insert(slug).inserted
      else { return nil }
      return (slug, label)
    }
  }

  nonisolated static func configuredModelOptions(_ configuredModel: String?) -> [AIChatModelOption] {
    guard let model = normalized(configuredModel) else { return [] }
    return [AIChatModelOption(
      id: model,
      label: model,
      supportsReasoning: true,
      reasoningOptions: reasoningOptions,
      isDefault: true
    )]
  }

  private nonisolated static func capture(
    executableURL: URL,
    arguments: [String],
    cwd: URL?,
    environment: [String: String]
  ) async -> String? {
    let process = Process()
    let output = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd.standardizedFileURL }
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let timeout = Task.detached {
      try? await Task.sleep(for: .seconds(30))
      if process.isRunning { process.terminate() }
    }
    let data = try? await BlockingIO.readToEnd(output.fileHandleForReading)
    let status = await BlockingIO.terminationStatus(of: process)
    timeout.cancel()
    guard status == 0, let data else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  private nonisolated static func consumeOutput(
    _ handle: FileHandle,
    openOrgThreadID: UUID,
    eventHandler: @escaping EventHandler
  ) async throws -> AntigravityStreamResult {
    var decoder = AntigravityStreamDecoder()
    var buffer = Data()
    while let chunk = try await BlockingIO.read(handle, upToCount: 16_384), !chunk.isEmpty {
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer[..<newline]
        buffer.removeSubrange(...newline)
        await decoder.consume(String(decoding: lineData, as: UTF8.self)) { event in
          await eventHandler(openOrgThreadID, event)
        }
      }
    }
    if !buffer.isEmpty {
      await decoder.consume(String(decoding: buffer, as: UTF8.self)) { event in
        await eventHandler(openOrgThreadID, event)
      }
    }
    return decoder.result
  }

  private nonisolated static func materializeAttachments(
    _ attachments: [AIChatAttachment],
    under temporaryRoot: URL
  ) throws -> [URL] {
    var usedNames = Set<String>()
    return try attachments.enumerated().map { index, attachment in
      let rawName = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
      let safeName = URL(fileURLWithPath: rawName.isEmpty ? "attachment-\(index + 1)" : rawName)
        .lastPathComponent
      var uniqueName = ["", ".", ".."].contains(safeName)
        ? "attachment-\(index + 1)"
        : safeName
      var suffix = 2
      while usedNames.contains(uniqueName.lowercased()) {
        let base = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        uniqueName = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
        suffix += 1
      }
      usedNames.insert(uniqueName.lowercased())
      let url = temporaryRoot.appendingPathComponent(uniqueName)
      try attachment.loadData().write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return url
    }
  }

  private nonisolated static func normalized(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }
}

private struct AntigravityRemotePayload: Encodable {
  let workspacePath: String
  let arguments: [String]
  let prompt: String
  let attachments: [AntigravityRemoteAttachment]
}

private struct AntigravityRemoteAttachment: Encodable {
  let fileName: String
  let data: String
}
