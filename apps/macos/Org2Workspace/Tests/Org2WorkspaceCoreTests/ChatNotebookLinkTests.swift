import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class ChatNotebookLinkTests: XCTestCase {
  @MainActor func testExistingRefreshDataLoadsLocalChatDataset() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("celorga-notebook-\(UUID().uuidString)")
    let suite = "celorga-notebook-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("views"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".org2"), withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    try "{}".write(to: root.appendingPathComponent("celorga.json"), atomically: true, encoding: .utf8)
    let repo = try Org2CLI.defaultRepoRoot()
    let source = try String(contentsOf: repo.appendingPathComponent("examples/chat-response-queue/views/unanswered.org"), encoding: .utf8)
    let file = root.appendingPathComponent("views/unanswered.org")
    try source.write(to: file, atomically: true, encoding: .utf8)
    let now = Date().timeIntervalSinceReferenceDate
    let payload: [String: Any] = ["version": 6, "threads": [[
      "id": UUID().uuidString, "title": "Inspect draft", "createdAt": now,
      "updatedAt": now, "runtime": "codex", "destinationID": "builtin.codex",
      "messages": [["id": UUID().uuidString, "role": "user", "content": "Inspect the draft", "createdAt": now - 3600, "deliveryStatus": "failed", "sendFailure": "Connection timed out"]]
    ]]]
    try JSONSerialization.data(withJSONObject: payload).write(to: root.appendingPathComponent(".org2/openclaw-chat.json"))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: repo), defaults: defaults, legacyDefaultsDomains: [])
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(path: file.path, relativePath: "views/unanswered.org", modifiedAt: nil, byteCount: nil))
    let deadline = Date().addingTimeInterval(15)
    while !store.canRefreshSelectedDataNotebook, Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(store.canRefreshSelectedDataNotebook)
    await store.refreshSelectedDataNotebook()
    XCTAssertNil(store.errorText)
    let refreshed = try String(contentsOf: file, encoding: .utf8)
    XCTAssertTrue(refreshed.contains("Connection timed out"))
    XCTAssertFalse(refreshed.contains("status=not-run"))
    XCTAssertTrue(refreshed.contains("#+query-data: result=unanswered rows=1"))
  }

  @MainActor func testReaderOpensConversationFromMaterializedNotebookLink() throws {
    let id = UUID()
    let coordinator = OrgHTMLDocumentView.Coordinator()
    var opened: UUID?
    coordinator.openChatThread = { opened = $0 }
    XCTAssertTrue(coordinator.openChatLink(try XCTUnwrap(URL(string: AIChatThreadLinks.url(for: id.uuidString)))))
    XCTAssertEqual(opened, id)
    opened = nil
    XCTAssertFalse(coordinator.openChatLink(try XCTUnwrap(URL(string: "https://example.test/article"))))
    XCTAssertFalse(coordinator.openChatLink(try XCTUnwrap(URL(string: "org2-workspace://open-thread?id=invalid"))))
    XCTAssertNil(opened)
  }
}
