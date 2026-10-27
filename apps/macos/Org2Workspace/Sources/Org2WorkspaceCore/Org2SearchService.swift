import Darwin
import Foundation

/// One request to `dist/search-service.js`. Omitting `query` only loads the
/// corpus search index into the worker's memory.
struct Org2SearchServiceRequest: Encodable, Sendable {
  let id: String
  let rootDir: String
  let query: String?
  let limit: Int?
  let context: Int?
  let sort: String?
  let recursive: Bool
}

private struct Org2SearchServiceResponse: Decodable, Sendable {
  let id: String
  let payload: SearchPayload?
  let warmed: Bool?
  let error: String?
}

/// Keeps one long-lived Node search worker per runtime so Search does not pay
/// for process start-up and index deserialization on every query. The worker
/// rereads the index only after `celorga index` rewrites it.
actor Org2SearchServicePool {
  static let shared = Org2SearchServicePool()

  private struct Key: Hashable {
    let repoRoot: String
    let nodePath: String
  }

  private var workers: [Key: Org2SearchServiceWorker] = [:]

  private func worker(repoRoot: URL, nodePath: String?) -> Org2SearchServiceWorker {
    let resolvedNodePath = nodePath ?? "node"
    let key = Key(repoRoot: repoRoot.standardizedFileURL.path, nodePath: resolvedNodePath)
    if let existing = workers[key] { return existing }
    let worker = Org2SearchServiceWorker(repoRoot: repoRoot, nodePath: resolvedNodePath)
    workers[key] = worker
    return worker
  }

  func search(
    query: String,
    corpusRoot: URL,
    limit: Int,
    context: Int,
    sort: String,
    repoRoot: URL,
    nodePath: String?,
    timeout: TimeInterval
  ) async throws -> SearchPayload {
    let response = try await worker(repoRoot: repoRoot, nodePath: nodePath).send(
      Org2SearchServiceRequest(
        id: UUID().uuidString.lowercased(),
        rootDir: corpusRoot.standardizedFileURL.path,
        query: query,
        limit: limit,
        context: context,
        sort: sort,
        recursive: true
      ),
      timeout: timeout
    )
    guard let payload = response.payload else {
      throw Org2CLIError.commandFailed(status: 1, message: "The search service returned no results payload.")
    }
    return payload
  }

  func warm(corpusRoot: URL, repoRoot: URL, nodePath: String?, timeout: TimeInterval) async throws {
    _ = try await worker(repoRoot: repoRoot, nodePath: nodePath).send(
      Org2SearchServiceRequest(
        id: UUID().uuidString.lowercased(),
        rootDir: corpusRoot.standardizedFileURL.path,
        query: nil,
        limit: nil,
        context: nil,
        sort: nil,
        recursive: true
      ),
      timeout: timeout
    )
  }
}

private final class Org2SearchServiceOperation: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Org2SearchServiceResponse, Error>?
  private var result: Result<Org2SearchServiceResponse, Error>?

  func install(_ continuation: CheckedContinuation<Org2SearchServiceResponse, Error>) {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  @discardableResult
  func finish(_ result: Result<Org2SearchServiceResponse, Error>) -> Bool {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return false
    }
    self.result = result
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
    return true
  }
}

private final class Org2SearchServiceWorker: @unchecked Sendable {
  private let repoRoot: URL
  private let nodePath: String
  private let queue = DispatchQueue(label: "org.openorg.search-service", qos: .userInitiated)
  private let stateLock = NSLock()
  private var process: Process?
  private var inputHandle: FileHandle?
  private var outputHandle: FileHandle?
  private var outputBuffer = Data()

  init(repoRoot: URL, nodePath: String) {
    self.repoRoot = repoRoot.standardizedFileURL
    self.nodePath = nodePath
  }

  /// A cancelled caller stops waiting at once, but the worker finishes the
  /// request in the background: killing it would discard the warm index.
  func send(_ request: Org2SearchServiceRequest, timeout: TimeInterval) async throws -> Org2SearchServiceResponse {
    let operation = Org2SearchServiceOperation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        operation.install(continuation)
        queue.async { [weak self] in
          self?.execute(request, timeout: timeout, operation: operation)
        }
      }
    } onCancel: {
      operation.finish(.failure(CancellationError()))
    }
  }

  private func execute(
    _ request: Org2SearchServiceRequest,
    timeout: TimeInterval,
    operation: Org2SearchServiceOperation
  ) {
    let timeoutWork = DispatchWorkItem { [weak self] in
      if operation.finish(.failure(Org2CLIError.commandTimedOut(
        seconds: Int(max(0.01, timeout).rounded(.up))
      ))) {
        self?.resetProcess()
      }
    }
    do {
      try ensureProcess()
      stateLock.lock()
      let inputHandle = self.inputHandle
      stateLock.unlock()
      guard let inputHandle else {
        throw Org2CLIError.commandFailed(status: -1, message: "The search service did not open its input stream.")
      }
      var payload = try JSONEncoder().encode(request)
      payload.append(0x0A)
      DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + max(0.01, timeout),
        execute: timeoutWork
      )
      try inputHandle.write(contentsOf: payload)
      let line = try readResponseLine()
      timeoutWork.cancel()
      let response = try JSONDecoder().decode(Org2SearchServiceResponse.self, from: line)
      guard response.id == request.id else {
        throw Org2CLIError.commandFailed(status: -1, message: "The search service returned an out-of-order response.")
      }
      if let error = response.error, !error.isEmpty {
        throw Org2CLIError.commandFailed(status: 1, message: error)
      }
      operation.finish(.success(response))
    } catch {
      timeoutWork.cancel()
      resetProcess()
      operation.finish(.failure(error))
    }
  }

  private func ensureProcess() throws {
    stateLock.lock()
    let running = process?.isRunning == true && inputHandle != nil && outputHandle != nil
    stateLock.unlock()
    if running { return }
    resetProcess()
    _ = Darwin.signal(SIGPIPE, SIG_IGN)

    let servicePath = repoRoot.appendingPathComponent("dist/search-service.js")
    guard FileManager.default.fileExists(atPath: servicePath.path) else {
      throw Org2CLIError.missingCLI(servicePath.path)
    }
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [nodePath, servicePath.path]
    process.currentDirectoryURL = repoRoot
    process.environment = Org2CLI.processEnvironment()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()

    try? stdin.fileHandleForReading.close()
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
    DispatchQueue.global(qos: .utility).async {
      while !stderr.fileHandleForReading.availableData.isEmpty {}
      try? stderr.fileHandleForReading.close()
    }

    stateLock.lock()
    self.process = process
    inputHandle = stdin.fileHandleForWriting
    outputHandle = stdout.fileHandleForReading
    outputBuffer.removeAll(keepingCapacity: true)
    stateLock.unlock()
  }

  private func readResponseLine() throws -> Data {
    while true {
      if let newline = outputBuffer.firstIndex(of: 0x0A) {
        let line = outputBuffer[..<newline]
        outputBuffer.removeSubrange(...newline)
        return Data(line)
      }
      stateLock.lock()
      let outputHandle = self.outputHandle
      stateLock.unlock()
      guard let outputHandle else {
        throw Org2CLIError.commandFailed(status: -1, message: "The search service exited before answering.")
      }
      let chunk = outputHandle.availableData
      guard !chunk.isEmpty else {
        throw Org2CLIError.commandFailed(status: -1, message: "The search service exited before answering.")
      }
      outputBuffer.append(chunk)
    }
  }

  private func resetProcess() {
    stateLock.lock()
    let process = self.process
    self.process = nil
    let inputHandle = self.inputHandle
    self.inputHandle = nil
    let outputHandle = self.outputHandle
    self.outputHandle = nil
    outputBuffer.removeAll(keepingCapacity: true)
    stateLock.unlock()

    if let process, process.isRunning {
      let identifier = process.processIdentifier
      process.terminate()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
        if process.isRunning { _ = Darwin.kill(identifier, SIGKILL) }
      }
    }
    try? inputHandle?.close()
    try? outputHandle?.close()
  }
}

extension Org2CLI {
  /// Searches the active corpus through the warm search worker.
  public func searchIndexedCorpus(
    _ query: String,
    corpusRoot: URL,
    limit: Int,
    context: Int,
    sort: String = "best",
    timeout: TimeInterval = 20
  ) async throws -> SearchPayload {
    try await Org2SearchServicePool.shared.search(
      query: query,
      corpusRoot: corpusRoot,
      limit: limit,
      context: context,
      sort: sort,
      repoRoot: repoRoot,
      nodePath: runtimeNodePath,
      timeout: timeout
    )
  }

  /// Loads the corpus search index into the warm worker ahead of the first query.
  public func prewarmSearchService(corpusRoot: URL) async {
    try? await Org2SearchServicePool.shared.warm(
      corpusRoot: corpusRoot,
      repoRoot: repoRoot,
      nodePath: runtimeNodePath,
      timeout: 60
    )
  }

  var hasSearchService: Bool {
    FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("dist/search-service.js").path)
  }
}
