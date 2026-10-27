import XCTest
@testable import Org2WorkspaceCore

/// A task marked done moves from Today to "Done or canceled" with the same
/// agenda item ID. Its row must get a new view identity there, or the lazy
/// stack can keep drawing the removed TODO row in the Done section.
final class AgendaRowIdentityTests: XCTestCase {
  private func item(todo: String?) -> AgendaItem {
    AgendaItem(
      todo: todo,
      headline: "Reply to the vendor",
      kind: "SCHEDULED",
      file: "/tmp/daily/2026-01-05.org",
      line: 39,
      body: nil,
      level: 1,
      tags: [],
      properties: [:],
      priority: "A",
      time: nil,
      effort: nil,
      idValue: "row-identity-fixture",
      habit: nil
    )
  }

  func testMovingATaskToDoneGivesItsRowANewIdentity() {
    let open = item(todo: "TODO")
    let done = item(todo: "DONE")
    XCTAssertEqual(open.id, done.id, "the agenda item ID ignores the TODO state")
    XCTAssertNotEqual(
      AgendaRowIdentity.id(for: open, inSection: "focus-today"),
      AgendaRowIdentity.id(for: done, inSection: "focus-closed")
    )
    XCTAssertNotEqual(
      AgendaRowIdentity.id(for: open, inSection: "today"),
      AgendaRowIdentity.id(for: done, inSection: "today"),
      "a state change within one section also redraws the row"
    )
    XCTAssertEqual(
      AgendaRowIdentity.id(for: open, inSection: "today"),
      AgendaRowIdentity.id(for: item(todo: "TODO"), inSection: "today"),
      "an unchanged row keeps its identity across refreshes"
    )
  }
}
