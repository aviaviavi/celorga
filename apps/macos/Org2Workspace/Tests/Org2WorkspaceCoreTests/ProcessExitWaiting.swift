import Darwin
import Foundation

extension Process {
  /// Waits for the process to exit without `waitUntilExit()`.
  ///
  /// `waitUntilExit()` spins the calling thread's run loop until Foundation
  /// reports the exit. Called from an async test on a Swift concurrency thread
  /// it can miss that report and block forever, even after the child is gone,
  /// which stalls the whole test run. Polling `isRunning` cannot miss the exit,
  /// and a child that outlives `timeout` is killed so the test fails instead of
  /// hanging. Returns whether the process exited on its own.
  @discardableResult
  func waitForExit(timeout: TimeInterval = 30) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while isRunning, Date() < deadline { usleep(10_000) }
    guard isRunning else { return true }
    kill(processIdentifier, SIGKILL)
    let killDeadline = Date().addingTimeInterval(5)
    while isRunning, Date() < killDeadline { usleep(10_000) }
    return false
  }

  /// Terminates a fixture process (if it is still running) and waits for it.
  func terminateAndWaitForExit(timeout: TimeInterval = 5) {
    if isRunning { terminate() }
    waitForExit(timeout: timeout)
  }
}
