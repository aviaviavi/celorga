import Darwin
import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Opt-in profile of chat-storage maintenance against a disposable copy of a
/// real corpus. Set OPENORG_CHAT_MAINTENANCE_BENCH_ROOT to a corpus clone whose
/// state directory holds `openclaw-chat.store`; the benchmark writes to it.
/// It reports process CPU and wall time for repair, loads, saves, and
/// collection, and is skipped when the variable is unset.
final class AIChatTranscriptMaintenanceBenchmarkTests: XCTestCase {
  func testRealStoreMaintenanceProfile() throws {
    guard let rootPath = ProcessInfo.processInfo.environment["OPENORG_CHAT_MAINTENANCE_BENCH_ROOT"],
          !rootPath.isEmpty
    else { throw XCTSkip("Set OPENORG_CHAT_MAINTENANCE_BENCH_ROOT to a disposable corpus clone") }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let legacyURL = CelorgaNames.stateDirectory(corpusRoot: root)
      .appendingPathComponent("openclaw-chat.json")
    let store = AIChatTranscriptStore.shared
    store.setWriterIdentityForTesting(
      AIChatTranscriptWriterIdentity(id: "maintenance-benchmark", label: "Benchmark"),
      legacyURL: legacyURL
    )
    defer { store.setWriterIdentityForTesting(nil, legacyURL: legacyURL) }

    var lines: [String] = []
    func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
      let cpuBefore = Self.processCPUSeconds()
      let wallBefore = Date()
      let value = try body()
      let line = String(
        format: "%@: cpu %.2fs wall %.2fs",
        label, Self.processCPUSeconds() - cpuBefore, Date().timeIntervalSince(wallBefore)
      )
      lines.append(line)
      print("[maintenance-benchmark] \(line)")
      return value
    }

    let loaded = try measure("load committed (cold)") {
      try XCTUnwrap(store.loadCommittedIfAvailable(legacyURL: legacyURL))
    }
    XCTAssertFalse(loaded.recoveryStatus.blocksWrites)
    _ = try measure("repair verify (cold)") {
      try store.repair(legacyURL: legacyURL, apply: false)
    }
    _ = try measure("repair verify (warm)") {
      try store.repair(legacyURL: legacyURL, apply: false)
    }
    _ = measure("collect garbage (cold)") {
      AIChatTranscriptStore.collectGarbageForTesting(legacyURL: legacyURL, shouldYield: { false })
    }
    _ = measure("collect garbage (warm)") {
      AIChatTranscriptStore.collectGarbageForTesting(legacyURL: legacyURL, shouldYield: { false })
    }
    _ = measure("load committed (warm)") {
      store.loadCommittedIfAvailable(legacyURL: legacyURL)
    }

    var threads = loaded.snapshot.threads
    let selectedIndex = try XCTUnwrap(threads.firstIndex { $0.storedMessageCount == nil })
    for index in 0..<3 {
      let thread = threads[selectedIndex]
      threads[selectedIndex] = thread.replacingMessages(
        thread.messages + [AIChatMessage(role: .assistant, content: "benchmark save \(index)")]
      )
      let snapshot = AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: loaded.snapshot.selectedThreadID,
        settlementSettings: loaded.snapshot.settlementSettings
      )
      try measure("save \(index) incl. post-commit maintenance") {
        try store.flush(snapshot, legacyURL: legacyURL)
        store.waitUntilIdleForTesting()
      }
    }
    _ = try measure("repair verify after saves") {
      try store.repair(legacyURL: legacyURL, apply: false)
    }
    let reloaded = try XCTUnwrap(store.loadCommittedIfAvailable(legacyURL: legacyURL))
    XCTAssertEqual(reloaded.snapshot.threads.count, threads.count)
    XCTAssertEqual(
      reloaded.snapshot.threads.first { $0.id == threads[selectedIndex].id }?.messages.last?.content,
      "benchmark save 2"
    )
    if let report = ProcessInfo.processInfo.environment["OPENORG_CHAT_MAINTENANCE_BENCH_REPORT"] {
      try (lines.joined(separator: "\n") + "\n").write(toFile: report, atomically: true, encoding: .utf8)
    }
  }

  static func processCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
  }
}
