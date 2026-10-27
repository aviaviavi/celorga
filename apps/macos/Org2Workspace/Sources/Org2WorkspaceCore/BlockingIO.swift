import Darwin
import Foundation

/// Runs blocking pipe reads and process waits on GCD threads instead of the
/// Swift concurrency cooperative pool.
///
/// That pool has one thread per CPU core. A local agent turn used to park up
/// to four pool threads in read(2) or waitpid(2) for its whole lifetime
/// (stdout, stderr, exit status, and a private server's log drain), so two or
/// three concurrent turns could exhaust it. Every unrelated `Task.detached`
/// and actor hop then stalled: the AI chat stopped rendering Org markup and
/// the thread outputs chip never appeared while those turns ran.
enum BlockingIO {
  private static let queue = DispatchQueue(
    label: "org.openorg.blocking-io",
    qos: .userInitiated,
    attributes: .concurrent
  )

  static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try work() }) }
    }
  }

  static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: work()) }
    }
  }

  /// Waits for a child process to exit without occupying a cooperative thread.
  static func terminationStatus(of process: Process) async -> Int32 {
    return await run {
      process.waitUntilExit()
      return process.terminationStatus
    }
  }

  /// Reads the next chunk of a pipe; empty or nil at end of file.
  static func read(_ handle: FileHandle, upToCount count: Int) async throws -> Data? {
    // Foundation's read(upToCount:) can fill the entire requested buffer on
    // a pipe. A small live event then waits for more bytes (or EOF), breaking
    // interactive progress and tool request/response protocols. POSIX read
    // returns the bytes available after the first byte arrives.
    try await run {
      let capacity = max(1, count)
      var bytes = [UInt8](repeating: 0, count: capacity)
      while true {
        let received = Darwin.read(handle.fileDescriptor, &bytes, capacity)
        if received > 0 { return Data(bytes.prefix(received)) }
        if received == 0 { return nil }
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
  }

  /// Reads a pipe to end of file.
  static func readToEnd(_ handle: FileHandle) async throws -> Data? {
    try await run { try handle.readToEnd() }
  }
}

/// Carries Swift task cancellation into blocking work running on GCD, where
/// `Task.isCancelled` is always false.
final class BlockingIOCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func isCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}
