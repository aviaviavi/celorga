import XCTest
@testable import Org2WorkspaceCore

/// Activity's Agents section: every connected agent with what it is doing now.
final class WorkspaceActivityAgentStatusTests: XCTestCase {
  private func item(_ id: String, _ kind: WorkspaceActivityItem.Kind, agent: String, title: String, at seconds: TimeInterval) -> WorkspaceActivityItem {
    WorkspaceActivityItem(
      id: id,
      kind: kind,
      title: title,
      detail: "",
      agent: agent,
      date: Date(timeIntervalSince1970: seconds),
      state: kind == .working ? .working : .needsYou,
      target: .run(id)
    )
  }

  func testEveryConnectedAgentGetsAStatusWithItsCurrentWorkAndStep() {
    var snapshot = WorkspaceActivitySnapshot()
    snapshot.working = [
      item("thread:old", .working, agent: "OpenCode", title: "Older turn", at: 100),
      item("thread:new", .working, agent: "OpenCode", title: "Fix Celorga items", at: 200),
      item("run:scout", .working, agent: "Product Research", title: "Competitor scan", at: 150),
    ]
    snapshot.needsYou = [
      item("thread:ask", .needsYou, agent: "Codex", title: "Approve deploy", at: 120),
      item("thread:ask2", .needsYou, agent: "OpenCode", title: "Pick a name", at: 90),
    ]
    let lastWork: [String: WorkspaceActivityAgentStatus.LastWork] = [
      "Claude Code": .init(title: "Refactor parser", date: Date(timeIntervalSince1970: 50)),
      "OpenClaw": .init(title: "Daily brief", date: Date(timeIntervalSince1970: 80)),
    ]

    let statuses = WorkspaceActivityAgentStatus.build(
      snapshot: snapshot,
      connectedAgents: ["Claude Code", "OpenCode", "Codex", "OpenClaw", "Pi"],
      steps: ["thread:new": "Running swift build"],
      lastWork: lastWork
    )

    // Working first, then needs you, then idle by most recent work.
    XCTAssertEqual(statuses.map(\.name), ["OpenCode", "Product Research", "Codex", "OpenClaw", "Claude Code", "Pi"])
    XCTAssertEqual(statuses.map(\.state), [.working, .working, .needsYou, .idle, .idle, .idle])

    let openCode = statuses[0]
    XCTAssertEqual(openCode.current?.title, "Fix Celorga items", "the newest live work is current")
    XCTAssertEqual(openCode.currentStep, "Running swift build")
    XCTAssertEqual(openCode.workingCount, 2)
    XCTAssertEqual(openCode.needsYouCount, 1)

    XCTAssertEqual(statuses[2].current?.title, "Approve deploy")
    XCTAssertNil(statuses[2].currentStep)
    XCTAssertEqual(statuses[3].lastWork?.title, "Daily brief")
    XCTAssertNil(statuses[5].current)
    XCTAssertNil(statuses[5].lastWork)
  }

  func testNoAgentsMeansNoStatuses() {
    XCTAssertTrue(WorkspaceActivityAgentStatus.build(snapshot: WorkspaceActivitySnapshot(), connectedAgents: []).isEmpty)
  }
}
