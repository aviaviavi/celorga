import XCTest
@testable import Org2WorkspaceCore

/// Refreshing a large run archive must not stall the main actor. Comparing
/// every refreshed run with its local copy used to build ISO-8601 formatters
/// for each comparison on the main actor, which stalled a 20,000-run archive
/// for several seconds on every refresh.
@MainActor
final class AgentRunArchiveRefreshPerformanceTests: XCTestCase {
  func testRefreshingALargeRunArchiveKeepsTheMainActorResponsive() async throws {
    let runCount = 20_000
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-run-archive-refresh-\(UUID().uuidString)", isDirectory: true)
    store.deferredAgentRunsRefreshDelayNanoseconds = 60_000_000_000
    // Every refreshed copy has a different stamp from its local copy, so each
    // comparison parses both timestamps (the worst case).
    var local = try Self.runs(count: runCount, updatedAt: "2026-07-28T00:01:00.000Z")
    let newerLocal = try Self.run(
      id: "archive-run-7", goal: "Decided locally", updatedAt: "2026-07-28T00:09:00.000Z"
    )
    local[7] = newerLocal
    store.replaceAgentRunsForTesting(local)
    let refreshed = try Self.runs(count: runCount, updatedAt: "2026-07-28T00:02:00Z")
    store.agentRunListLoaderForTesting = { refreshed }

    let probe = MainActorStallProbe()
    probe.start()
    // Let the probe record its first tick; otherwise a stall that begins
    // before the first suspension goes unmeasured.
    try await Task.sleep(nanoseconds: 50_000_000)
    await store.refreshAgentRuns()
    let longest = probe.stop()

    XCTAssertEqual(store.agentRuns.count, runCount)
    XCTAssertEqual(store.agentRuns[7], newerLocal, "a newer local copy must survive the refresh")
    XCTAssertEqual(store.agentRuns[8], refreshed[8], "a newer refreshed copy must replace the local one")
    print("PERFORMANCE run-archive-refresh-main-actor-stall: max=\(String(format: "%.1f", longest)) ms")
    XCTAssertLessThan(longest, 250, "refreshing the run archive blocked the main actor for \(longest) ms")
  }

  func testMergeKeepsOnlyStrictlyNewerLocalRuns() throws {
    let older = try Self.run(id: "run", goal: "Older", updatedAt: "2026-10-21T16:29:52.108Z")
    let newer = try Self.run(id: "run", goal: "Newer", updatedAt: "2026-10-21T21:24:19Z")
    let sameStamp = try Self.run(id: "run", goal: "Same stamp", updatedAt: "2026-10-21T16:29:52.108Z")

    XCTAssertEqual(WorkspaceStore.mergingNewerLocalRuns([newer], into: [older]), [newer])
    XCTAssertEqual(WorkspaceStore.mergingNewerLocalRuns([older], into: [newer]), [newer])
    XCTAssertEqual(WorkspaceStore.mergingNewerLocalRuns([sameStamp], into: [older]), [older])
    XCTAssertEqual(WorkspaceStore.mergingNewerLocalRuns([], into: [older]), [older])
  }

  static func runs(count: Int, updatedAt: String) throws -> [AgentRunItem] {
    try (0..<count).map { index in
      try run(id: "archive-run-\(index)", goal: "Synthetic outcome \(index)", updatedAt: updatedAt)
    }
  }

  static func run(id: String, goal: String, updatedAt: String) throws -> AgentRunItem {
    let object: [String: Any] = [
      "schema": "org2:agent-run:v1",
      "id": id,
      "goal": goal,
      "acceptanceCriteria": [],
      "status": "completed",
      "riskClass": "internal",
      "capabilities": [], "context": [], "plan": [], "artifacts": [],
      "approvals": [], "validations": [], "comments": [], "events": [],
      "createdAt": "2026-07-28T00:00:00.000Z",
      "updatedAt": updatedAt,
    ]
    return try JSONDecoder().decode(
      AgentRunItem.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
  }
}
