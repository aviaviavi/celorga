import Darwin
import Foundation
import OSLog

private struct Org2JSONDecodedValue<Value>: @unchecked Sendable {
  let value: Value
}

public enum Org2SlideExportFormat: String, CaseIterable, Identifiable, Sendable {
  case pdf
  case latex

  public var id: String { rawValue }

  public var fileExtension: String {
    switch self {
    case .pdf: "pdf"
    case .latex: "tex"
    }
  }

  public var title: String {
    switch self {
    case .pdf: "PDF"
    case .latex: "LaTeX"
    }
  }
}

public enum Org2CLIInvocationOutcome: String, Equatable, Sendable {
  case succeeded
  case failed
  case timedOut = "timed-out"
  case cancelled
  case missingExecutable = "missing-executable"
  case launchFailed = "launch-failed"
}

public struct Org2CLIInvocationMetric: Equatable, Sendable {
  public let command: String
  public let elapsedMilliseconds: Double
  public let outcome: Org2CLIInvocationOutcome
  public let standardInputBytes: Int
  public let standardOutputBytes: Int
  public let standardErrorBytes: Int
  public let exitStatus: Int32?

  public init(
    command: String,
    elapsedMilliseconds: Double,
    outcome: Org2CLIInvocationOutcome,
    standardInputBytes: Int,
    standardOutputBytes: Int,
    standardErrorBytes: Int,
    exitStatus: Int32?
  ) {
    self.command = command
    self.elapsedMilliseconds = elapsedMilliseconds
    self.outcome = outcome
    self.standardInputBytes = standardInputBytes
    self.standardOutputBytes = standardOutputBytes
    self.standardErrorBytes = standardErrorBytes
    self.exitStatus = exitStatus
  }
}

public struct Org2CLI: Sendable {
  private static let ignoreBrokenPipeSignal: Void = {
    _ = Darwin.signal(SIGPIPE, SIG_IGN)
  }()

  public let repoRoot: URL
  private let cliPath: URL
  private let nodePath: String?
  private let telemetryHandler: (@Sendable (Org2CLIInvocationMetric) -> Void)?
  private static let telemetryLogger = Logger(
    subsystem: "org.org2.workspace",
    category: "CLILatency"
  )
  private static let telemetryCommandRoots: Set<String> = [
    "agent", "agent-profile", "agenda", "ai", "approvals", "archive", "artifact",
    "backlinks", "brief", "capture", "clock", "compile", "context", "corpus",
    "crypt", "data", "doctor", "entity", "eval", "export", "fmt", "goal",
    "graph", "id", "index", "ledger", "lint", "lsp", "mcp", "plan", "plugin", "publish",
    "query", "query-data", "refile", "render-chart", "review", "roam", "run",
    "search", "skill", "source", "table", "todo", "version", "workflow", "workspace"
  ]
  private static let telemetryNestedCommands: Set<String> = [
    "agent.capabilities", "agent.context", "agent.search", "agent.fetch", "agent.bundle",
    "agent-profile.list", "agent-profile.show", "agent-profile.create", "agent-profile.update",
    "agent-profile.resolve", "ai.validate-job", "ai.run", "ai.suggest-links", "ai.review",
    "ai.promote", "artifact.graph", "artifact.rebuild", "brief.today", "brief.project",
    "brief.node", "compile.corpus", "corpus.show", "corpus.validate", "corpus.init",
    "data.refresh", "entity.show", "eval.run", "eval.fixture", "export.html",
    "export.beamer", "goal.list", "goal.show", "goal.create", "goal.update",
    "graph.audit", "id.get", "id.ensure", "ledger.list", "ledger.show", "ledger.create",
    "ledger.update", "ledger.event", "mcp.serve", "mcp.clients", "mcp.client-add",
    "mcp.discover", "mcp.snapshot", "review.list", "review.show", "run.create", "skill.install",
    "plugin.list", "plugin.init", "plugin.add", "plugin.remove", "plugin.update",
    "plugin.sync", "plugin.trust", "plugin.doctor", "plugin.exec", "plugin.template",
    "run.list", "run.show", "run.validate", "run.start", "run.resume", "run.retry",
    "run.cancel", "run.complete", "run.complete-external", "run.reopen-external",
    "run.fail", "run.block", "run.fork", "run.normalize", "run.reconcile-source", "run.assign", "run.comment",
    "run.outcome", "run.runtime", "run.step", "run.artifact", "run.artifact-review",
    "run.validation", "run.approval-request", "run.approval-decide", "run.approval-snooze", "source.list",
    "source.status", "source.doctor", "source.import", "source.sync", "table.recalculate", "todo.set",
    "todo.toggle", "todo.assign", "todo.approve", "workflow.list", "workflow.show",
    "workflow.validate", "workflow.save", "workflow.run", "workflow.triggers",
    "workflow.package", "workflow.corpus-template", "workflow.install-builtin",
    "workspace.agenda", "workspace.search", "workspace.agent-state", "workspace.attention"
  ]

  public init(
    repoRoot: URL,
    nodePath: String? = nil,
    telemetryHandler: (@Sendable (Org2CLIInvocationMetric) -> Void)? = nil
  ) {
    self.repoRoot = repoRoot
    self.cliPath = repoRoot.appendingPathComponent("dist/cli.js")
    let bundledNode = repoRoot.appendingPathComponent("bin/node")
    self.nodePath = nodePath
      ?? (FileManager.default.isExecutableFile(atPath: bundledNode.path) ? bundledNode.path : nil)
    self.telemetryHandler = telemetryHandler
  }

  public static func defaultRepoRoot(
    filePath: String = #filePath,
    bundleResourceURL: URL? = Bundle.main.resourceURL
  ) throws -> URL {
    if let override = CelorgaNames.environment("ORG2_REPO_ROOT"), !override.isEmpty {
      return URL(fileURLWithPath: override).standardizedFileURL
    }

    if let bundledRoot = bundleResourceURL?.appendingPathComponent("Org2Runtime", isDirectory: true),
       FileManager.default.fileExists(atPath: bundledRoot.appendingPathComponent("dist/cli.js").path) {
      return bundledRoot.standardizedFileURL
    }

    var url = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    for _ in 0..<5 {
      url.deleteLastPathComponent()
    }
    return url.standardizedFileURL
  }

  public func runJSON<T: Decodable>(
    _ arguments: [String],
    environment: [String: String] = [:],
    standardInput: Data? = nil,
    as type: T.Type = T.self
  ) async throws -> T {
    let data = try await run(arguments, environment: environment, standardInput: standardInput)
    return try await decodeJSON(T.self, from: data)
  }

  public func runJSONSync<T: Decodable>(_ arguments: [String], as type: T.Type = T.self) throws -> T {
    let data = try runSync(arguments)
    return try JSONDecoder().decode(T.self, from: data)
  }

  public func parseFileJSON<T: Decodable>(_ file: URL, sourceRanges: Bool = false, as type: T.Type = T.self) async throws -> T {
    var arguments = [file.path]
    if sourceRanges {
      arguments.insert("--source-ranges", at: 0)
    }
    let data = try await runProcessOffPool(scriptPath: repoRoot.appendingPathComponent("dist/parse.js"), arguments: arguments)
    return try await decodeJSON(T.self, from: data)
  }

  public func parseTextJSON<T: Decodable>(
    _ text: String,
    sourceRanges: Bool = false,
    sourceLineOffset: Int = 0,
    sourcePath: String? = nil,
    as type: T.Type = T.self
  ) async throws -> T {
    var arguments = ["-"]
    if let sourcePath { arguments.insert(contentsOf: ["--source-path", sourcePath], at: 0) }
    if sourceLineOffset > 0 {
      arguments.insert("\(sourceLineOffset)", at: 0)
      arguments.insert("--source-line-offset", at: 0)
    }
    if sourceRanges {
      arguments.insert("--source-ranges", at: 0)
    }
    let data = try await runProcessOffPool(
      scriptPath: repoRoot.appendingPathComponent("dist/parse.js"),
      arguments: arguments,
      standardInput: Data(text.utf8)
    )
    return try await decodeJSON(T.self, from: data)
  }

  public func renderAppHTML(
    _ text: String,
    sourcePath: String,
    sourceLineOffset: Int = 0,
    stylesheetPath: String? = nil,
    corpusRootPath: String? = nil,
    resolveEmbeds: Bool = true,
    timeout: TimeInterval = 8
  ) async throws -> String {
    let servicePath = repoRoot.appendingPathComponent("dist/render-html-service.js")
    if FileManager.default.fileExists(atPath: servicePath.path) {
      let startedAt = DispatchTime.now().uptimeNanoseconds
      do {
        let html = try await Org2HTMLRenderServicePool.shared.render(
          text: text,
          sourcePath: sourcePath,
          sourceLineOffset: sourceLineOffset,
          stylesheetPath: stylesheetPath,
          corpusRootPath: corpusRootPath,
          resolveEmbeds: resolveEmbeds,
          repoRoot: repoRoot,
          nodePath: runtimeNodePath,
          timeout: timeout
        )
        let byteCounts = await Task.detached(priority: .utility) {
          (text.utf8.count, html.utf8.count)
        }.value
        let metric = Org2CLIInvocationMetric(
          command: "render-html-service",
          elapsedMilliseconds: Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
          ) / 1_000_000,
          outcome: .succeeded,
          standardInputBytes: byteCounts.0,
          standardOutputBytes: byteCounts.1,
          standardErrorBytes: 0,
          exitStatus: nil
        )
        Self.recordTelemetry(metric)
        telemetryHandler?(metric)
        return html
      } catch is CancellationError {
        let metric = Self.appHTMLServiceFailureMetric(
          startedAt: startedAt,
          outcome: .cancelled
        )
        Self.recordTelemetry(metric)
        telemetryHandler?(metric)
        throw CancellationError()
      } catch let error as Org2CLIError {
        let outcome: Org2CLIInvocationOutcome = if case .commandTimedOut = error {
          .timedOut
        } else {
          .failed
        }
        let metric = Self.appHTMLServiceFailureMetric(
          startedAt: startedAt,
          outcome: outcome
        )
        Self.recordTelemetry(metric)
        telemetryHandler?(metric)
        throw error
      } catch {
        let metric = Self.appHTMLServiceFailureMetric(
          startedAt: startedAt,
          outcome: .failed
        )
        Self.recordTelemetry(metric)
        telemetryHandler?(metric)
        throw error
      }
    }

    var arguments = ["--source-path", sourcePath]
    if let corpusRootPath { arguments += ["--corpus-root", corpusRootPath] }
    if !resolveEmbeds { arguments.append("--reference-embeds") }
    if sourceLineOffset > 0 {
      arguments.append(contentsOf: ["--source-line-offset", "\(sourceLineOffset)"])
    }
    if let stylesheetPath, !stylesheetPath.isEmpty {
      arguments.append(contentsOf: ["--stylesheet", stylesheetPath])
    }
    let data = try await runProcessOffPool(
      scriptPath: repoRoot.appendingPathComponent("dist/render-html.js"),
      arguments: arguments,
      standardInput: Data(text.utf8),
      timeout: timeout
    )
    return String(decoding: data, as: UTF8.self)
  }

  public func prewarmAppHTMLRenderer() async {
    let servicePath = repoRoot.appendingPathComponent("dist/render-html-service.js")
    guard FileManager.default.fileExists(atPath: servicePath.path) else { return }
    _ = try? await Org2HTMLRenderServicePool.shared.render(
      text: "",
      sourcePath: "/tmp/openorg-renderer-prewarm.org",
      sourceLineOffset: 0,
      stylesheetPath: nil,
      corpusRootPath: nil,
      resolveEmbeds: false,
      repoRoot: repoRoot,
      nodePath: runtimeNodePath,
      timeout: 8
    )
  }

  public func renderPresentationPDF(
    _ text: String,
    sourcePath: String,
    sourceLineOffset: Int = 0,
    passes: Int = 1,
    timeout: TimeInterval = 30
  ) async throws -> Data {
    var arguments = [
      "--source-path", sourcePath,
      "--passes", "\(max(1, min(4, passes)))",
    ]
    if sourceLineOffset > 0 {
      arguments.append(contentsOf: ["--source-line-offset", "\(sourceLineOffset)"])
    }
    let data = try await runProcessOffPool(
      scriptPath: repoRoot.appendingPathComponent("dist/render-presentation-pdf.js"),
      arguments: arguments,
      standardInput: Data(text.utf8),
      timeout: timeout
    )
    guard data.starts(with: Data("%PDF".utf8)) else {
      throw Org2CLIError.commandFailed(
        status: 0,
        message: "The slide renderer completed without producing a PDF."
      )
    }
    return data
  }

  public func analyzeEditorText(
    _ text: String,
    sourceLineOffset: Int = 0,
    sourcePath: String? = nil,
    timeout: TimeInterval = 5
  ) async throws -> OrgSourceEditorSemanticSnapshot {
    var arguments: [String] = []
    if let sourcePath { arguments.append(contentsOf: ["--source-path", sourcePath]) }
    if sourceLineOffset > 0 {
      arguments.append(contentsOf: ["--source-line-offset", "\(sourceLineOffset)"])
    }
    let data = try await runProcessOffPool(
      scriptPath: repoRoot.appendingPathComponent("dist/editor-analysis.js"),
      arguments: arguments,
      standardInput: Data(text.utf8),
      timeout: timeout
    )
    let payload = try await decodeJSON(Org2EditorAnalysisPayload.self, from: data)
    return OrgSourceEditorSemanticSnapshot(payload: payload)
  }

  public func parseFileJSONSync<T: Decodable>(_ file: URL, sourceRanges: Bool = false, as type: T.Type = T.self) throws -> T {
    var arguments = [file.path]
    if sourceRanges {
      arguments.insert("--source-ranges", at: 0)
    }
    let data = try runProcess(scriptPath: repoRoot.appendingPathComponent("dist/parse.js"), arguments: arguments)
    return try JSONDecoder().decode(T.self, from: data)
  }

  public func run(_ arguments: [String], environment: [String: String] = [:], standardInput: Data? = nil) async throws -> Data {
    return try await runProcessOffPool(scriptPath: cliPath, arguments: arguments, standardInput: standardInput, environment: environment)
  }

  public func runSync(_ arguments: [String]) throws -> Data {
    try runProcess(scriptPath: cliPath, arguments: arguments)
  }

  public func formatOrgText(
    _ text: String,
    canonicalOrgSyntax: Bool = false,
    timeout: TimeInterval = 8
  ) async throws -> String {
    let data = try await runProcessOffPool(
      scriptPath: cliPath,
      arguments: ["fmt", "--stdin"] + (canonicalOrgSyntax ? ["--canonical-org"] : []),
      standardInput: Data(text.utf8),
      timeout: timeout
    )
    return String(decoding: data, as: UTF8.self)
  }

  public func exportBeamer(
    file: URL,
    destination: URL,
    format: Org2SlideExportFormat
  ) async throws {
    var arguments = [
      "export", "beamer",
      "--file", file.standardizedFileURL.path,
      "--out", destination.standardizedFileURL.path,
    ]
    if format == .pdf {
      arguments.append("--pdf")
    }
    arguments.append(contentsOf: ["--format", "json", "--apply"])
    _ = try await run(arguments)
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
    let decoded = try await Task.detached(priority: .userInitiated) {
      Org2JSONDecodedValue(value: try JSONDecoder().decode(T.self, from: data))
    }.value
    return decoded.value
  }

  /// Process polling must not occupy Swift's cooperative executor.
  private func runProcessOffPool(
    scriptPath: URL,
    arguments: [String],
    standardInput: Data? = nil,
    timeout: TimeInterval? = nil,
    environment: [String: String] = [:]
  ) async throws -> Data {
    let cancellation = BlockingIOCancellation()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await BlockingIO.run {
        try runProcess(
          scriptPath: scriptPath, arguments: arguments,
          standardInput: standardInput, timeout: timeout,
          environment: environment, isCancelled: cancellation.isCancelled
        )
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private func runProcess(
    scriptPath: URL,
    arguments: [String],
    standardInput: Data? = nil,
    timeout: TimeInterval? = nil,
    environment: [String: String] = [:],
    isCancelled: () -> Bool = { Task.isCancelled }
  ) throws -> Data {
    _ = Self.ignoreBrokenPipeSignal

    let startedAt = DispatchTime.now().uptimeNanoseconds
    let command = Self.telemetryCommandIdentity(scriptPath: scriptPath, arguments: arguments)
    var outcome = Org2CLIInvocationOutcome.failed
    var standardOutputBytes = 0
    var standardErrorBytes = 0
    var exitStatus: Int32?
    defer {
      let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
      let metric = Org2CLIInvocationMetric(
        command: command,
        elapsedMilliseconds: Double(elapsedNanoseconds) / 1_000_000,
        outcome: outcome,
        standardInputBytes: standardInput?.count ?? 0,
        standardOutputBytes: standardOutputBytes,
        standardErrorBytes: standardErrorBytes,
        exitStatus: exitStatus
      )
      Self.recordTelemetry(metric)
      telemetryHandler?(metric)
    }

    guard FileManager.default.fileExists(atPath: scriptPath.path) else {
      outcome = .missingExecutable
      throw Org2CLIError.missingCLI(scriptPath.path)
    }

    let process = Process()
    // Homebrew replaces executables in place during upgrades. A Node path can
    // therefore disappear between resolution and launch. Foundation may turn
    // that invalid executable URL into an uncaught Objective-C exception
    // instead of a Swift error, terminating the whole app. Always launch the
    // stable system env binary and make Node its argument; a disappearing Node
    // then becomes an ordinary child-process failure (status 127).
    let candidateNode = nodePath ?? Self.resolveNodePath()
    let node = candidateNode.flatMap {
      Self.isLaunchableExecutable(atPath: $0) ? $0 : nil
    }
    // NSTask raises an Objective-C exception (not a catchable Swift error)
    // above 4096 arguments. Large sync batches can exceed that, or ARG_MAX in
    // bytes. A Node preload restores argv before the original script starts,
    // without consuming its stdin or requiring a newer CLI protocol.
    let argumentTransport: Org2CLIArgumentTransport
    do {
      argumentTransport = try Org2CLIArgumentTransport(arguments: arguments)
    } catch {
      outcome = .launchFailed
      throw error
    }
    defer { argumentTransport.removeTemporaryFiles() }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var processArguments: [String] = [node ?? "node"]
    processArguments.append(contentsOf: argumentTransport.nodeOptions)
    processArguments.append(scriptPath.path)
    processArguments.append(contentsOf: argumentTransport.directArguments)
    process.arguments = processArguments
    process.currentDirectoryURL = repoRoot
    process.environment = Self.processEnvironment().merging(environment) { _, override in override }

    let stdout = Pipe()
    let stderr = Pipe()
    let stdin = standardInput.map { _ in Pipe() }
    process.standardOutput = stdout
    process.standardError = stderr
    if let stdin {
      process.standardInput = stdin
    }

    // Drain on the process worker itself. Queueing blocking pipe readers on
    // GCD can exhaust its worker threads; the old one-second join then returned
    // empty/partial JSON even though the command succeeded.
    var stdoutCollector = try CLIOutputPipe(stdout.fileHandleForReading)
    var stderrCollector = try CLIOutputPipe(stderr.fileHandleForReading)
    var inputWriter = try stdin.map { try CLIInputPipe($0.fileHandleForWriting, data: standardInput!) }
    defer {
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
      try? stdin?.fileHandleForWriting.close()
    }

    do {
      try process.run()
    } catch {
      outcome = .launchFailed
      throw error
    }
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
    try? stdin?.fileHandleForReading.close()

    func drainOutput() {
      stdoutCollector.drainAvailable()
      stderrCollector.drainAvailable()
    }

    let deadline = timeout.map {
      DispatchTime.now() + .milliseconds(Int((max(0.01, $0) * 1_000).rounded(.up)))
    }
    var didTimeOut = false
    var wasCancelled = false
    while process.isRunning {
      drainOutput()
      inputWriter?.writeAvailable()
      if isCancelled() {
        wasCancelled = true
        break
      }
      if let deadline, DispatchTime.now() >= deadline {
        didTimeOut = true
        break
      }
      Thread.sleep(forTimeInterval: 0.01)
    }

    if process.isRunning && (didTimeOut || wasCancelled) {
      process.terminate()
      let terminationDeadline = DispatchTime.now() + .milliseconds(500)
      while process.isRunning && DispatchTime.now() < terminationDeadline {
        drainOutput()
        Thread.sleep(forTimeInterval: 0.01)
      }
      if process.isRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }

    process.waitUntilExit()
    exitStatus = process.terminationStatus
    // Descendants may retain stdout/stderr. Read all available bytes without
    // waiting for EOF indefinitely or leaving blocking readers behind.
    let drainDeadline = DispatchTime.now() + .seconds(1)
    repeat {
      drainOutput()
      if stdoutCollector.reachedEOF && stderrCollector.reachedEOF { break }
      Thread.sleep(forTimeInterval: 0.01)
    } while DispatchTime.now() < drainDeadline

    let outData = stdoutCollector.data
    let errData = stderrCollector.data
    standardOutputBytes = outData.count
    standardErrorBytes = errData.count

    if wasCancelled {
      outcome = .cancelled
      throw CancellationError()
    }

    if didTimeOut {
      outcome = .timedOut
      throw Org2CLIError.commandTimedOut(seconds: Int(timeout?.rounded(.up) ?? 0))
    }

    guard process.terminationStatus == 0 else {
      let stderrText = String(data: errData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let stdoutFailure = Self.commandFailureMessage(from: outData)
      throw Org2CLIError.commandFailed(
        status: Int(process.terminationStatus),
        message: stderrText?.isEmpty == false
          ? stderrText!
          : (stdoutFailure ?? "Celorga CLI exited with status \(process.terminationStatus)")
      )
    }

    outcome = .succeeded
    return outData
  }

  private static func recordTelemetry(_ metric: Org2CLIInvocationMetric) {
    let exitStatus = metric.exitStatus.map(String.init) ?? "none"
    telemetryLogger.info(
      "command=\(metric.command, privacy: .public) elapsed_ms=\(metric.elapsedMilliseconds, privacy: .public) outcome=\(metric.outcome.rawValue, privacy: .public) stdin_bytes=\(metric.standardInputBytes, privacy: .public) stdout_bytes=\(metric.standardOutputBytes, privacy: .public) stderr_bytes=\(metric.standardErrorBytes, privacy: .public) exit_status=\(exitStatus, privacy: .public)"
    )
  }

  private static func appHTMLServiceFailureMetric(
    startedAt: UInt64,
    outcome: Org2CLIInvocationOutcome
  ) -> Org2CLIInvocationMetric {
    Org2CLIInvocationMetric(
      command: "render-html-service",
      elapsedMilliseconds: Double(
        DispatchTime.now().uptimeNanoseconds - startedAt
      ) / 1_000_000,
      outcome: outcome,
      standardInputBytes: 0,
      standardOutputBytes: 0,
      standardErrorBytes: 0,
      exitStatus: nil
    )
  }

  static func telemetryCommandIdentity(scriptPath: URL, arguments: [String]) -> String {
    let script = scriptPath.deletingPathExtension().lastPathComponent
    guard script == "cli" else { return script }
    guard let root = arguments.first,
          telemetryCommandRoots.contains(root)
    else { return "cli.unknown" }

    if arguments.count > 1, arguments[1].utf8.count <= 48 {
      let nestedCommand = "\(root).\(arguments[1])"
      if telemetryNestedCommands.contains(nestedCommand) {
        return "cli.\(nestedCommand)"
      }
    }
    return "cli.\(root)"
  }

  private static func commandFailureMessage(from stdout: Data) -> String? {
    guard !stdout.isEmpty else { return nil }
    if let value = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] {
      var messages: [String] = []
      if let diagnostics = value["diagnostics"] as? [[String: Any]] {
        messages.append(contentsOf: diagnostics.compactMap { diagnostic in
          guard let message = diagnostic["message"] as? String,
                !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else { return nil }
          return message
        })
      }
      if let results = value["results"] as? [[String: Any]] {
        for result in results {
          for key in ["error", "message"] {
            if let message = result[key] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              messages.append(message)
            }
          }
        }
      }
      for key in ["error", "message"] {
        if let message = value[key] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          messages.append(message)
        }
      }
      let unique = messages.reduce(into: [String]()) { result, message in
        if !result.contains(message) { result.append(message) }
      }
      if !unique.isEmpty {
        return unique.prefix(3).joined(separator: "\n")
      }
    }

    let text = String(data: stdout, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let text, !text.isEmpty else { return nil }
    return String(text.prefix(2_000))
  }

  var runtimeNodePath: String? { nodePath ?? Self.resolveNodePath() }

  private static func resolveNodePath() -> String? {
    let candidates = [
      "/opt/homebrew/bin/node",
      "/usr/local/bin/node",
      "/usr/bin/node"
    ]
    return candidates.first { isLaunchableExecutable(atPath: $0) }
  }

  private static func isLaunchableExecutable(atPath path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && !isDirectory.boolValue
      && FileManager.default.isExecutableFile(atPath: path)
  }

  static func processEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let defaultPath = "/Library/TeX/texbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if let existing = environment["PATH"], !existing.isEmpty {
      environment["PATH"] = "\(defaultPath):\(existing)"
    } else {
      environment["PATH"] = defaultPath
    }
    return environment
  }
}

/// The owning process worker performs nonblocking I/O for all three pipes.
/// No pipe reader depends on a free GCD thread, and the owner can close the
/// descriptors safely even when a child descendant retains a write end.
private struct CLIOutputPipe {
  let descriptor: Int32
  private(set) var data = Data()
  private(set) var reachedEOF = false

  init(_ handle: FileHandle) throws {
    descriptor = handle.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  mutating func drainAvailable() {
    guard !reachedEOF else { return }
    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
    // Bound each pass so a noisy child cannot starve cancellation or stdin.
    for _ in 0..<64 {
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
      else if count == 0 { reachedEOF = true; return }
      else if errno == EINTR { continue }
      else { return }
    }
  }
}

private struct CLIInputPipe {
  let handle: FileHandle
  let data: Data
  private var offset = 0
  private var closed = false

  init(_ handle: FileHandle, data: Data) throws {
    self.handle = handle
    self.data = data
    let flags = fcntl(handle.fileDescriptor, F_GETFL)
    guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  mutating func writeAvailable() {
    guard !closed else { return }
    for _ in 0..<64 {
      if offset == data.count { close(); return }
      let count = data.withUnsafeBytes { bytes in
        Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), min(16 * 1024, data.count - offset))
      }
      if count > 0 { offset += count }
      else if count < 0 && errno == EINTR { continue }
      else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
      else { close(); return }
    }
  }

  private mutating func close() {
    closed = true
    try? handle.close()
  }
}

/// Keeps normal invocations unchanged; only oversized argv uses a private preload.
struct Org2CLIArgumentTransport {
  let directArguments: [String]
  let nodeOptions: [String]
  let temporaryDirectory: URL?

  init(arguments: [String]) throws {
    // Leave ample room for env, Node, the script path, and inherited environment.
    let oversized = arguments.count > 2048
      || arguments.reduce(0, { $0 + $1.utf8.count + 1 }) > 64 * 1024
    guard oversized else {
      directArguments = arguments
      nodeOptions = []
      temporaryDirectory = nil
      return
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-cli-arguments-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      let preload = directory.appendingPathComponent("arguments.cjs")
      var source = Data("process.argv = process.argv.concat(".utf8)
      source.append(try JSONEncoder().encode(arguments))
      source.append(Data(");\n".utf8))
      try source.write(to: preload)
      directArguments = []
      nodeOptions = ["--require", preload.path]
      temporaryDirectory = directory
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  func removeTemporaryFiles() {
    if let temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }
}

public enum Org2CLIError: LocalizedError, Equatable {
  case missingCLI(String)
  case commandFailed(status: Int, message: String)
  case commandTimedOut(seconds: Int)

  public var errorDescription: String? {
    switch self {
    case .missingCLI(let path):
      "Celorga CLI not found at \(path). Run npm run build in the Celorga repo."
    case .commandFailed(_, let message):
      message
    case .commandTimedOut(let seconds):
      "Celorga rendering timed out after \(seconds) second\(seconds == 1 ? "" : "s")."
    }
  }
}
