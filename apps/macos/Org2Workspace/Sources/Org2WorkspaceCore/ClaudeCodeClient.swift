import Foundation

public enum ClaudeCodeError: LocalizedError, Sendable {
  case executableNotFound
  case launchFailed(String)
  case invalidResponse(String)
  case turnFailed(String)
  case interrupted

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "Claude Code was not found. Install Claude Code, then sign in with `claude auth login`."
    case .launchFailed(let detail):
      "Could not start Claude Code: \(detail)"
    case .invalidResponse(let detail):
      "Claude Code returned an invalid response: \(detail)"
    case .turnFailed(let detail):
      "Claude Code turn failed: \(detail)"
    case .interrupted:
      "Claude Code was stopped."
    }
  }
}

public enum ClaudeCodeEvent: Sendable {
  case sessionStarted(sessionID: String)
  case textDelta(String)
  case activity(id: String, title: String, status: AIChatRunActivity.Status)
  case warning(String)
}

public struct ClaudeCodeTurnResult: Equatable, Sendable {
  public let sessionID: String
  public let reply: String

  public init(sessionID: String, reply: String) {
    self.sessionID = sessionID
    self.reply = reply
  }
}

struct ClaudeCodeStreamResult: Equatable, Sendable {
  var sessionID: String?
  var reply = ""
  var errors: [String] = []
  var succeeded = false
  /// How many `result` events the stream reported, one per user message.
  var resultCount = 0
  /// The `result` text of a result event marked `is_error`. A usage limit
  /// arrives this way ("Claude AI usage limit reached|…") with no `errors`.
  var errorResult: String?
  /// Set when a `rate_limit_event` reported the request as rejected.
  var rateLimitRejected = false
  var rateLimitResetsAt: Date?

  /// The failure for an unsuccessful turn, typed as a usage limit when the
  /// stream or its text says so.
  func failure(stderr: String, status: Int32, now: Date = Date()) -> Error {
    let detail = [errors.joined(separator: "\n"), errorResult ?? "", stderr]
      .first(where: { !$0.isEmpty }) ?? "Claude Code exited with status \(status)."
    let wrapped = ClaudeCodeError.turnFailed(detail)
    let classified = AIChatUsageLimitClassifier.classify(detail, now: now)
    if rateLimitRejected || classified != nil {
      return AIChatUsageLimitError(AIChatUsageLimit(
        resetsAt: rateLimitResetsAt ?? classified?.resetsAt,
        detail: wrapped.localizedDescription
      ))
    }
    return wrapped
  }
}

struct ClaudeCodeStreamDecoder: Sendable {
  private(set) var result = ClaudeCodeStreamResult()

  mutating func consume(
    _ line: String,
    eventHandler: @Sendable (ClaudeCodeEvent) async -> Void
  ) async {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }

    if let sessionID = object["session_id"] as? String, !sessionID.isEmpty {
      if result.sessionID == nil {
        await eventHandler(.sessionStarted(sessionID: sessionID))
      }
      result.sessionID = sessionID
    }

    switch object["type"] as? String {
    case "stream_event":
      guard let event = object["event"] as? [String: Any],
            let eventType = event["type"] as? String
      else { return }
      switch eventType {
      case "content_block_delta":
        guard let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String,
              !text.isEmpty
        else { return }
        await eventHandler(.textDelta(text))
      case "content_block_start":
        guard let block = event["content_block"] as? [String: Any],
              block["type"] as? String == "tool_use",
              let name = block["name"] as? String
        else { return }
        let id = block["id"] as? String ?? UUID().uuidString.lowercased()
        await eventHandler(.activity(
          id: id,
          title: Self.activityTitle(for: name),
          status: .running
        ))
      default:
        break
      }
    case "system":
      if object["subtype"] as? String == "permission_denied",
         let message = object["message"] as? String {
        await eventHandler(.warning(message))
      }
    case "result":
      // Guidance sent while a turn runs can arrive as its own result. The
      // turn succeeds only when every result did, and its reply keeps each
      // result's text in order.
      let resultSucceeded = object["subtype"] as? String == "success"
        && (object["is_error"] as? Bool != true)
      result.succeeded = (result.resultCount == 0 || result.succeeded) && resultSucceeded
      result.resultCount += 1
      if let reply = object["result"] as? String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          result.reply = reply
        } else if !trimmed.isEmpty {
          result.reply += "\n\n" + reply
        }
        if object["is_error"] as? Bool == true {
          result.errorResult = trimmed
        }
      }
      if let errors = object["errors"] as? [String] {
        result.errors.append(contentsOf: errors)
      }
    case "rate_limit_event":
      guard let info = object["rate_limit_info"] as? [String: Any],
            info["status"] as? String == "rejected"
      else { return }
      result.rateLimitRejected = true
      if let resetsAt = (info["resetsAt"] as? NSNumber)?.doubleValue, resetsAt > 0 {
        result.rateLimitResetsAt = Date(
          timeIntervalSince1970: resetsAt >= 1e12 ? resetsAt / 1_000 : resetsAt
        )
      }
    default:
      break
    }
  }

  nonisolated private static func activityTitle(for tool: String) -> String {
    switch tool {
    case "Read": "Reading"
    case "Glob", "Grep": "Searching"
    case "Edit", "Write", "NotebookEdit": "Editing"
    case "Bash": "Running command"
    case "WebFetch", "WebSearch": "Browsing"
    case "Task", "Agent": "Delegating"
    default: "Using \(tool)"
    }
  }
}

public actor ClaudeCodeClient {
  public typealias EventHandler = @Sendable (UUID, ClaudeCodeEvent) async -> Void

  private let executableURL: URL?
  private let environment: [String: String]
  private let eventHandler: EventHandler
  private var activeProcesses: [UUID: Process] = [:]
  private var activeInputs: [UUID: ActiveInput] = [:]
  /// How long the input stays open after a result while guidance is still
  /// unanswered and Claude Code is silent. Closing stdin never cancels work:
  /// Claude Code finishes what it already received, then exits.
  private let pendingGuidanceIdleTimeout: Duration

  private struct ActiveInput {
    let token: UUID
    let handle: FileHandle
    /// User messages written whose `result` has not arrived yet.
    var unansweredMessages = 1
    var lastOutputAt = ContinuousClock.now
  }

  public init(
    executableURL: URL? = ClaudeCodeClient.resolveExecutableURL(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    pendingGuidanceIdleTimeout: Duration = .seconds(30),
    eventHandler: @escaping EventHandler
  ) {
    self.executableURL = executableURL
    self.environment = environment
    self.pendingGuidanceIdleTimeout = pendingGuidanceIdleTimeout
    self.eventHandler = eventHandler
  }

  nonisolated public static func resolveExecutableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    LocalAgentExecutableLocator.resolve(
      executableName: "claude",
      configuredKey: "ORG2_CLAUDE_EXECUTABLE",
      environment: environment,
      fileManager: fileManager
    )
  }

  nonisolated static func arguments(
    sessionID: String?,
    model: String?,
    sandboxAccess: CodexSandboxAccess,
    systemPromptFile: URL,
    attachmentDirectory: URL?
  ) -> [String] {
    var arguments = [
      "-p",
      // Streaming input keeps stdin open for the turn so guidance typed
      // while Claude Code works reaches the same session (steering).
      "--input-format", "stream-json",
      "--output-format", "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--permission-mode", permissionMode(for: sandboxAccess),
      "--append-system-prompt-file", systemPromptFile.path
    ]
    if let sessionID = normalized(sessionID) {
      arguments.append(contentsOf: ["--resume", sessionID])
    }
    if let model = normalized(model) {
      arguments.append(contentsOf: ["--model", model])
    }
    if let attachmentDirectory {
      arguments.append(contentsOf: ["--add-dir", attachmentDirectory.path])
    }
    return arguments
  }

  /// One stream-json input line carrying a user message.
  nonisolated static func userMessageLine(_ text: String) throws -> Data {
    let object: [String: Any] = [
      "type": "user",
      "message": ["role": "user", "content": text]
    ]
    var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    data.append(0x0A)
    return data
  }

  nonisolated static func permissionMode(for sandboxAccess: CodexSandboxAccess) -> String {
    switch sandboxAccess {
    case .readOnly: "plan"
    case .workspaceWrite: "acceptEdits"
    case .fullAccess: "bypassPermissions"
    }
  }

  public func runTurn(
    openOrgThreadID: UUID,
    existingSessionID: String?,
    message: String,
    systemPrompt: String,
    attachments: [AIChatAttachment],
    cwd: URL,
    model: String?,
    sandboxAccess: CodexSandboxAccess
  ) async throws -> ClaudeCodeTurnResult {
    guard let executableURL else { throw ClaudeCodeError.executableNotFound }
    // Guidance may be written just as Claude Code exits; report that as an
    // error rather than letting a closed pipe terminate Celorga.
    _ = Darwin.signal(SIGPIPE, SIG_IGN)
    if let existing = activeProcesses[openOrgThreadID], existing.isRunning {
      throw ClaudeCodeError.launchFailed("another turn is already running in this chat")
    }

    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-claude-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryRoot,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let systemPromptURL = temporaryRoot.appendingPathComponent("openorg-context.txt")
    try systemPrompt.write(to: systemPromptURL, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: systemPromptURL.path
    )
    let materialized = try Self.materializeAttachments(attachments, under: temporaryRoot)
    let effectiveMessage = Self.message(message, attachmentURLs: materialized.urls)

    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = executableURL
    process.arguments = Self.arguments(
      sessionID: existingSessionID,
      model: model,
      sandboxAccess: sandboxAccess,
      systemPromptFile: systemPromptURL,
      attachmentDirectory: materialized.directory
    )
    process.currentDirectoryURL = cwd.standardizedFileURL
    process.environment = LocalAgentExecutableLocator.processEnvironment(
      environment,
      executableURL: executableURL
    )
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError

    do {
      try process.run()
    } catch {
      throw ClaudeCodeError.launchFailed(error.localizedDescription)
    }
    activeProcesses[openOrgThreadID] = process
    let inputToken = UUID()
    do {
      try standardInput.fileHandleForWriting.write(contentsOf: Self.userMessageLine(effectiveMessage))
    } catch {
      process.terminate()
      activeProcesses.removeValue(forKey: openOrgThreadID)
      try? standardInput.fileHandleForWriting.close()
      throw ClaudeCodeError.launchFailed(error.localizedDescription)
    }
    activeInputs[openOrgThreadID] = ActiveInput(
      token: inputToken,
      handle: standardInput.fileHandleForWriting
    )

    let handler = eventHandler
    let outputHandle = standardOutput.fileHandleForReading
    let errorHandle = standardError.fileHandleForReading
    let outputTask = Task.detached(priority: .userInitiated) {
      try await Self.consumeOutput(
        outputHandle,
        openOrgThreadID: openOrgThreadID,
        eventHandler: handler,
        onLine: { isResult in
          await self.noteOutput(
            openOrgThreadID: openOrgThreadID,
            token: inputToken,
            isResult: isResult
          )
        }
      )
    }
    let errorTask = Task.detached(priority: .utility) {
      String(decoding: try await BlockingIO.readToEnd(errorHandle) ?? Data(), as: UTF8.self)
    }
    let status: Int32 = await withTaskCancellationHandler {
      await BlockingIO.terminationStatus(of: process)
    } onCancel: {
      Task { await self.interrupt(openOrgThreadID: openOrgThreadID) }
    }
    closeInput(openOrgThreadID: openOrgThreadID, token: inputToken)
    let decoded: ClaudeCodeStreamResult
    do {
      decoded = try await outputTask.value
    } catch {
      activeProcesses.removeValue(forKey: openOrgThreadID)
      throw ClaudeCodeError.invalidResponse(error.localizedDescription)
    }
    let stderr = (try? await errorTask.value)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    activeProcesses.removeValue(forKey: openOrgThreadID)

    if Task.isCancelled || process.terminationReason == .uncaughtSignal {
      throw ClaudeCodeError.interrupted
    }
    guard status == 0, decoded.succeeded else {
      throw decoded.failure(stderr: stderr, status: status)
    }
    guard let sessionID = decoded.sessionID, !sessionID.isEmpty else {
      throw ClaudeCodeError.invalidResponse("the response did not include a session ID")
    }
    return ClaudeCodeTurnResult(sessionID: sessionID, reply: decoded.reply)
  }

  /// Whether a running turn in this chat can take guidance now.
  public func canSteer(openOrgThreadID: UUID) -> Bool {
    activeInputs[openOrgThreadID] != nil
      && activeProcesses[openOrgThreadID]?.isRunning == true
  }

  /// Sends guidance to the running turn's session. Claude Code reads it as
  /// the next user message in the same session, so the turn continues with
  /// it instead of a separate follow-up turn starting afterwards.
  public func steer(
    openOrgThreadID: UUID,
    message: String,
    attachments: [AIChatAttachment] = []
  ) throws {
    guard var input = activeInputs[openOrgThreadID],
          activeProcesses[openOrgThreadID]?.isRunning == true
    else {
      throw ClaudeCodeError.invalidResponse("there is no active Claude Code turn to steer")
    }
    guard attachments.isEmpty else {
      throw ClaudeCodeError.invalidResponse(
        "attachments cannot be added to a running Claude Code turn; queue a follow-up instead"
      )
    }
    do {
      try input.handle.write(contentsOf: Self.userMessageLine(message))
    } catch {
      closeInput(openOrgThreadID: openOrgThreadID, token: input.token)
      throw ClaudeCodeError.invalidResponse(
        "there is no active Claude Code turn to steer: \(error.localizedDescription)"
      )
    }
    input.unansweredMessages += 1
    input.lastOutputAt = .now
    activeInputs[openOrgThreadID] = input
  }

  private func noteOutput(openOrgThreadID: UUID, token: UUID, isResult: Bool) {
    guard var input = activeInputs[openOrgThreadID], input.token == token else { return }
    input.lastOutputAt = .now
    if isResult {
      input.unansweredMessages -= 1
    }
    activeInputs[openOrgThreadID] = input
    guard isResult else { return }
    if input.unansweredMessages <= 0 {
      // Every message has its answer: end the input so Claude Code exits.
      closeInput(openOrgThreadID: openOrgThreadID, token: token)
    } else {
      scheduleIdleInputClose(openOrgThreadID: openOrgThreadID, token: token)
    }
  }

  /// Guidance that Claude Code folded into the turn it was already running
  /// gets no result of its own. Do not wait forever for one.
  private func scheduleIdleInputClose(openOrgThreadID: UUID, token: UUID) {
    let timeout = pendingGuidanceIdleTimeout
    Task {
      while true {
        try? await Task.sleep(for: timeout)
        guard let input = self.activeInputs[openOrgThreadID], input.token == token else { return }
        if ContinuousClock.now - input.lastOutputAt >= timeout {
          self.closeInput(openOrgThreadID: openOrgThreadID, token: token)
          return
        }
      }
    }
  }

  private func closeInput(openOrgThreadID: UUID, token: UUID) {
    guard let input = activeInputs[openOrgThreadID], input.token == token else { return }
    activeInputs.removeValue(forKey: openOrgThreadID)
    try? input.handle.close()
  }

  public func interrupt(openOrgThreadID: UUID) {
    guard let process = activeProcesses[openOrgThreadID], process.isRunning else { return }
    process.interrupt()
  }

  public func shutdown() {
    for input in activeInputs.values {
      try? input.handle.close()
    }
    activeInputs.removeAll()
    for process in activeProcesses.values where process.isRunning {
      process.terminate()
    }
    activeProcesses.removeAll()
  }

  private nonisolated static func consumeOutput(
    _ handle: FileHandle,
    openOrgThreadID: UUID,
    eventHandler: @escaping EventHandler,
    onLine: @escaping @Sendable (_ isResult: Bool) async -> Void
  ) async throws -> ClaudeCodeStreamResult {
    var decoder = ClaudeCodeStreamDecoder()
    var buffer = Data()
    while let chunk = try await BlockingIO.read(handle, upToCount: 16_384), !chunk.isEmpty {
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer[..<newline]
        buffer.removeSubrange(...newline)
        let line = String(decoding: lineData, as: UTF8.self)
        let resultsBefore = decoder.result.resultCount
        await decoder.consume(line) { event in
          await eventHandler(openOrgThreadID, event)
        }
        await onLine(decoder.result.resultCount > resultsBefore)
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
  ) throws -> (directory: URL?, urls: [URL]) {
    guard !attachments.isEmpty else { return (nil, []) }
    let directory = temporaryRoot.appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    var usedNames = Set<String>()
    var urls: [URL] = []
    for (index, attachment) in attachments.enumerated() {
      let rawName = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
      let safeName = URL(fileURLWithPath: rawName.isEmpty ? "attachment-\(index + 1)" : rawName)
        .lastPathComponent
      var uniqueName = safeName
      var suffix = 2
      while usedNames.contains(uniqueName.lowercased()) {
        let base = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        uniqueName = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
        suffix += 1
      }
      usedNames.insert(uniqueName.lowercased())
      let url = directory.appendingPathComponent(uniqueName)
      try attachment.loadData().write(to: url, options: .atomic)
      urls.append(url)
    }
    return (directory, urls)
  }

  private nonisolated static func message(_ message: String, attachmentURLs: [URL]) -> String {
    guard !attachmentURLs.isEmpty else { return message }
    let paths = attachmentURLs.map { "- \($0.path)" }.joined(separator: "\n")
    return """
    \(message)

    Celorga attached temporary local copies of these files for this turn:
    \(paths)
    Read them when relevant. Do not modify these temporary copies.
    """
  }

  private nonisolated static func normalized(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }
}
