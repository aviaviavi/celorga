import XCTest
@testable import Org2Mobile

/// Runs the shipped phone controller and TCP client against a real Mac host and CLI corpus.
/// Only Apple's PTT/headset/microphone callbacks are replaced by the existing debug driver.
@MainActor
final class AudioApprovalEndToEndTests: XCTestCase {
  func testPushDuringWorkspaceRefreshPlaysFreshApprovalAndRecordsExactSpokenDecision() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CELORGA_AUDIO_E2E_ENDPOINT"] else {
      XCTFail("Run npm run test:audio-approvals:e2e; a live fixture host is required.")
      return
    }
    let suite = "audio-e2e-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(false, forKey: "Org2Mobile.remote.threadNotificationsEnabled.v1")
    defer { defaults.removePersistentDomain(forName: suite) }
    let remote = MobileRemoteStore(defaults: defaults)
    defer { remote.disconnect(forgetHost: true, checksRequests: false, unregisterPush: false) }
    remote.endpointDraft = endpoint
    remote.codeDraft = "434343"
    await remote.pair()
    XCTAssertTrue(remote.isPaired, remote.errorMessage ?? "Pairing failed")
    await remote.refreshWorkspace()
    XCTAssertTrue(remote.workspaceApprovals.contains { $0.title == "Old unanswered approval" })

    let phone = AudioApprovalController()
    defer {
      let evidence = XCTAttachment(string: "Phone phase: \(phone.phase)\nPrompt: \(phone.promptText ?? "none")\nSpoken: \(phone.demoSpoken ?? "none")\nHost error: \(remote.workspaceConnectionError ?? "none")\nReply: \(phone.replyHistory.last?.outcome ?? "none")")
      evidence.lifetime = .keepAlways
      add(evidence)
    }
    phone.attach(remote: remote)
    phone.setDemo(true)
    let control = try MobileRemoteClient(endpoint: endpoint, accessToken: nil)
    // Hold a foreground refresh with the OLD snapshot already captured on the host.
    let foreground = Task { await remote.refreshWorkspace() }
    let _: Empty = try await control.get("/test/wait-for-refresh", as: Empty.self)
    let push: Push = try await control.post("/test/create-fresh", payload: Empty(), as: Push.self)
    phone.demoReceivePush(["runID": push.runID, "approvalID": push.approvalID, "fingerprint": push.fingerprint, "deliveryID": push.deliveryID.uuidString])
    try await eventually("The pushed approval must play without opening the app or tapping Play; old cached snapshots must not discard its identity") {
      phone.demoSpoken?.contains("Fresh end-to-end approval") == true
    }
    let _: Empty = try await control.post("/test/release-refresh", payload: Empty(), as: Empty.self)
    await foreground.value
    XCTAssertTrue(phone.promptText?.contains("Fresh end-to-end approval") == true, "A late older response must not replace the verified prompt")
    XCTAssertFalse(phone.demoSpoken?.contains("Old unanswered approval") ?? true)
    phone.demoReply("yes")
    try await eventually("The phone must receive the exact canonical decision receipt") {
      phone.replyHistory.first(where: { $0.target?.approvalID == push.approvalID })?.outcome.contains("Approved") == true
    }
    let receipt: Result = try await control.get("/test/result", as: Result.self)
    XCTAssertEqual(receipt.approvalID, push.approvalID)
    XCTAssertEqual(receipt.status, "approved")
    XCTAssertTrue(receipt.receipt?.hasPrefix("audio-approval:") == true)
    XCTAssertEqual(receipt.oldStatus, "pending", "A spoken yes must never answer the old approval")
    var records: [MobileRemoteAudioApprovalDeliveryRecord] = []
    let traceDeadline = Date().addingTimeInterval(12)
    repeat {
      records = try await remote.audioApprovalDeliveryDiagnostics().filter { $0.deliveryID == push.deliveryID }
      if records.contains(where: { $0.stage == "decision-confirmed" }) { break }
      try await Task.sleep(for: .milliseconds(50))
    } while Date() < traceDeadline
    let stages = Set(records.map(\.stage))
    XCTAssertTrue(Set(["apns-accepted", "push-received", "prompt-verified", "playback-started", "playback-completed", "decision-confirmed"]).isSubset(of: stages), "Every stage must have a receipt: \(stages)")
    XCTAssertTrue(records.filter { $0.stage == "playback-completed" }.allSatisfy(\.simulated), "The simulator must never emit a physical-device playback receipt")
    // An unavailable host must not fall back to cached approvals; a subsequent exact
    // delivery can recover, and spoken no must reject only that new approval.
    let _: Empty = try await control.get("/test/fail-next-workspace", as: Empty.self)
    let nextPush: Push = try await control.post("/test/create-fresh", payload: Empty(), as: Push.self)
    let coldPhone = AudioApprovalController()
    coldPhone.attach(remote: remote)
    coldPhone.setDemo(true)
    let payload: [String: Any] = ["runID": nextPush.runID, "approvalID": nextPush.approvalID,
      "fingerprint": nextPush.fingerprint, "deliveryID": nextPush.deliveryID.uuidString]
    coldPhone.demoReceivePush(payload)
    try await eventually("A failed canonical check must release audio and report the failure") {
      coldPhone.phase.contains("Could not verify")
    }
    XCTAssertNil(coldPhone.demoSpoken, "A failed host read must never play the cached older approval")
    coldPhone.demoReceivePush(payload)
    try await eventually("The exact prompt must recover after host verification succeeds") {
      coldPhone.demoSpoken?.contains("Fresh end-to-end approval") == true
    }
    coldPhone.demoReply("no")
    try await eventually("Spoken no must receive the canonical rejection receipt") {
      coldPhone.replyHistory.first(where: { $0.target?.approvalID == nextPush.approvalID })?.outcome.contains("Rejected") == true
    }
    let rejected: Result = try await control.get("/test/result", as: Result.self)
    XCTAssertEqual(rejected.approvalID, nextPush.approvalID)
    XCTAssertEqual(rejected.status, "rejected")
    XCTAssertEqual(rejected.oldStatus, "pending")
    let _: Empty = try await control.post("/test/complete", payload: Empty(), as: Empty.self)
  }

  private func eventually(_ message: String, condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(12)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(condition(), message)
    if !condition() { throw NSError(domain: "AudioE2E", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  }

  private struct Empty: Codable {}
  private struct Push: Decodable { let deliveryID: UUID; let runID: String; let approvalID: String; let fingerprint: String }
  private struct Result: Decodable { let approvalID: String; let status: String; let receipt: String?; let oldStatus: String }
}
