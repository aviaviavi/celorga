import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor FakeSecretSealer: SecretSealing {
  private(set) var fulfilled: [(id: String, value: Data, options: SecretSealOptions)] = []
  private(set) var declined: [String] = []
  var failure: Error?

  func setFailure(_ error: Error?) { failure = error }

  func fulfill(_ request: SecretRequest, value: Data, options: SecretSealOptions, corpusRoot: URL) async throws -> SecretFulfillment {
    if let failure { throw failure }
    fulfilled.append((request.id, value, options))
    // Mirror the CLI: write ciphertext-only state and a receipt, never the value.
    try writeReceipt(request, status: "fulfilled", corpusRoot: corpusRoot)
    return SecretFulfillment(status: "fulfilled", name: request.name, file: request.destination.file, headingID: "heading-1", rotated: false)
  }

  func decline(_ request: SecretRequest, corpusRoot: URL) async throws {
    declined.append(request.id)
    try writeReceipt(request, status: "declined", corpusRoot: corpusRoot)
  }

  private func writeReceipt(_ request: SecretRequest, status: String, corpusRoot: URL) throws {
    let url = SecretRequestQueue.receiptURL(corpusRoot: corpusRoot, requestID: request.id)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"schema":"org2:secret-request-receipt:v1","id":"\#(request.id)","name":"\#(request.name)","status":"\#(status)"}"#.utf8).write(to: url)
  }
}

private struct SealFailure: LocalizedError {
  var errorDescription: String? { "no encryption recipient: GPG has no default-key configured. Nothing was written." }
}

final class SecretRequestTests: XCTestCase {
  private let syntheticValue = "sk-synthetic-EXAMPLE-swift-0001"

  private func makeCorpus() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-secret-request-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".org2", isDirectory: true),
      withIntermediateDirectories: true
    )
    return root
  }

  @discardableResult
  private func writeRequest(
    in root: URL,
    id: String = UUID().uuidString.lowercased(),
    name: String = "EXAMPLE_API_TOKEN",
    destination: String = "secrets.org",
    recipientFile: String = "public-keys/example.asc",
    createdAt: String = "2026-10-26T12:00:00.000Z"
  ) throws -> String {
    let directory = SecretRequestQueue.directory(corpusRoot: root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let envelope: [String: Any] = [
      "schema": "org2:secret-request:v1",
      "id": id,
      "name": name,
      "reason": "Call the example API for the weekly report",
      "createdAt": createdAt,
      "authorLabel": "Example Builder",
      "authorAgentRef": "agent-profile-example-builder",
      "destination": ["file": destination],
      "recipients": [
        "defaultKey": true,
        "entries": [["kind": "file", "value": recipientFile, "source": "agent"]],
      ],
    ]
    try JSONSerialization.data(withJSONObject: envelope).write(to: directory.appendingPathComponent("\(id).json"))
    return id
  }

  func testQueueLoadsPendingRequestsAndRejectsUnsafeEnvelopes() throws {
    let root = try makeCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try writeRequest(in: root, createdAt: "2026-10-26T12:00:00.000Z")
    let second = try writeRequest(in: root, name: "SECOND_TOKEN", createdAt: "2026-10-26T12:05:00.000Z")
    try writeRequest(in: root, destination: "../outside.org")
    try writeRequest(in: root, recipientFile: "/etc/attacker.asc")
    try writeRequest(in: root, name: "bad-name")

    var scan = SecretRequestQueue.loadPending(corpusRoot: root)
    XCTAssertEqual(scan.requests.map(\.id), [first, second])
    XCTAssertEqual(scan.errors.count, 3)

    let receipt = SecretRequestQueue.receiptURL(corpusRoot: root, requestID: first)
    try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: receipt)
    scan = SecretRequestQueue.loadPending(corpusRoot: root)
    XCTAssertEqual(scan.requests.map(\.id), [second])
  }

  func testCLISealerSendsTheValueOnlyOnStandardInput() {
    let settings = OrgCryptSettings(
      recipients: ["device@example.invalid"],
      recipientFiles: ["/keys/device.asc"],
      gpgProgram: "/opt/fake/gpg",
      useDefaultGpgKey: false
    )
    let arguments = CLISecretSealer.fulfillArguments(
      requestID: "00000000-0000-4000-8000-000000000001",
      options: SecretSealOptions(settings: settings),
      corpusRoot: URL(fileURLWithPath: "/tmp/example-corpus")
    )
    XCTAssertEqual(Array(arguments.prefix(6)), ["secret", "fulfill", "00000000-0000-4000-8000-000000000001", "--value-stdin", "--apply", "--json"])
    XCTAssertTrue(arguments.contains("--no-default-recipient-self"))
    XCTAssertTrue(arguments.contains("device@example.invalid"))
    XCTAssertTrue(arguments.contains("/keys/device.asc"))
    XCTAssertFalse(arguments.contains { $0.contains("synthetic") })
  }

  @MainActor
  func testStorePresentsSealsAndDeclinesRequestsThroughTheSealer() async throws {
    let root = try makeCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "SecretRequestTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent(".org2/openclaw-chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let sealer = FakeSecretSealer()
    store.secretSealerForTesting = sealer

    let first = try writeRequest(in: root, createdAt: "2026-10-26T12:00:00.000Z")
    let second = try writeRequest(in: root, name: "SECOND_TOKEN", createdAt: "2026-10-26T12:05:00.000Z")
    await store.refreshSecretRequests()
    XCTAssertEqual(store.activeSecretRequest?.id, first)
    XCTAssertTrue(store.secretRequestRecipientSummary(try XCTUnwrap(store.activeSecretRequest)).contains("public-keys/example.asc"))

    // A sealing failure stays on the sheet with an actionable message.
    await sealer.setFailure(SealFailure())
    let failed = await store.submitSecretRequest(try XCTUnwrap(store.activeSecretRequest), value: syntheticValue)
    XCTAssertFalse(failed)
    XCTAssertEqual(store.activeSecretRequest?.id, first)
    XCTAssertTrue(store.secretRequestErrorText?.contains("no encryption recipient") == true)
    XCTAssertFalse(store.secretRequestErrorText?.contains(syntheticValue) == true)

    await sealer.setFailure(nil)
    let stored = await store.submitSecretRequest(try XCTUnwrap(store.activeSecretRequest), value: syntheticValue)
    XCTAssertTrue(stored)
    let fulfilled = await sealer.fulfilled
    XCTAssertEqual(fulfilled.map(\.id), [first])
    XCTAssertEqual(fulfilled.first?.value, Data(syntheticValue.utf8))
    XCTAssertEqual(fulfilled.first?.options.useDefaultGpgKey, true)
    XCTAssertEqual(store.activeSecretRequest?.id, second)
    XCTAssertFalse(store.statusText.contains(syntheticValue))

    // Deferring hides a request for the session; declining records it.
    store.deferSecretRequest(try XCTUnwrap(store.activeSecretRequest))
    XCTAssertNil(store.activeSecretRequest)
    await store.refreshSecretRequests()
    XCTAssertNil(store.activeSecretRequest)
    store.presentPendingSecretRequests()
    await store.declineSecretRequest(try XCTUnwrap(store.activeSecretRequest))
    let declined = await sealer.declined
    XCTAssertEqual(declined, [second])
    XCTAssertNil(store.activeSecretRequest)
    await store.refreshSecretRequests()
    XCTAssertTrue(store.pendingSecretRequests.isEmpty)

    // Nothing the store wrote contains the plaintext value.
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      XCTAssertFalse(text.contains(syntheticValue), url.path)
    }
  }
}
