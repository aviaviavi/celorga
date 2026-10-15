import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class ApprovalHeadlineMutationTests: XCTestCase {
  @MainActor
  func testRejectUndeclaredWaitingHeadingUsesStableID() async throws {
    try await assertRejection(of: "WAITING Verify service recovery")
  }

  @MainActor
  func testRejectApprovalHeadingWithoutTodoKeyword() async throws {
    try await assertRejection(of: "Review service recovery")
  }

  @MainActor
  private func assertRejection(of title: String) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-reject-heading-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("approval.org")
    try """
    * TODO Parent
    :PROPERTIES:
    :ID: parent-id
    :END:

    ** \(title)
    SCHEDULED: <2026-10-01 Thu>
    :PROPERTIES:
    :ID: approval-id
    :STATUS: blocked-on-owner-access-context
    :END:

    Keep the original evidence.
    """.write(to: note, atomically: true, encoding: .utf8)

    let item = ApprovalItem(
      title: title,
      status: "blocked-on-owner-access-context",
      todo: nil,
      level: 2,
      file: note.path,
      line: 1, // A stale line must not redirect the rejection to the parent.
      idValue: "approval-id",
      properties: ["ID": "approval-id", "STATUS": "blocked-on-owner-access-context"],
      body: "Keep the original evidence.",
      tags: []
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    await store.rejectApproval(item, endStatus: .canceled, reason: "Dismissed by the user")

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* TODO Parent\n"))
    XCTAssertTrue(updated.contains("** CANCELED \(title)\n"))
    XCTAssertTrue(updated.contains("\nCLOSED: "))
    XCTAssertTrue(updated.contains(":STATUS: rejected\n"))
    XCTAssertTrue(updated.contains(":REJECTION_END_STATUS: CANCELED\n"))
    XCTAssertTrue(updated.contains(":REJECTION_REASON: Dismissed by the user\n"))
    XCTAssertTrue(updated.contains("Keep the original evidence."))
  }
}
