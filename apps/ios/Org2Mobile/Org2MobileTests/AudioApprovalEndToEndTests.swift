import XCTest
import AVFoundation
import UIKit
@testable import Org2Mobile

/// Runs the shipped phone controller and TCP client against a real Mac host and CLI corpus.
/// Only Apple's PTT/headset/microphone callbacks are replaced by the existing debug driver.
@MainActor
final class AudioApprovalEndToEndTests: XCTestCase {
  private final class RecordingBackgroundRuntime: AudioApprovalBackgroundRuntime {
    private var next: UIBackgroundTaskIdentifier.RawValue = 1
    var active: [UIBackgroundTaskIdentifier: @MainActor @Sendable () -> Void] = [:]
    func begin(name: String, expiration: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
      let id = UIBackgroundTaskIdentifier(rawValue: next)
      next += 1
      active[id] = expiration
      return id
    }
    func end(_ identifier: UIBackgroundTaskIdentifier) { active[identifier] = nil }
    func expire() { Array(active.values).forEach { $0() } }
  }

  func testIncomingPushHoldsBackgroundTimeBeforeCheckingTheHost() async throws {
    let background = RecordingBackgroundRuntime()
    let phone = AudioApprovalController(backgroundRuntime: background)
    phone.setDemo(true)
    phone.demoReceivePush(["runID": "runtime-run", "approvalID": "runtime-approval", "fingerprint": "sha256:runtime"])
    XCTAssertEqual(background.active.count, 1, "An incoming background push must hold runtime before the first asynchronous host check")
    try await eventually("An unavailable host releases the prompt's background time") { background.active.isEmpty }
  }

  func testIncomingPushExpirationReleasesRuntimeAndDoesNotSpeak() async throws {
    let background = RecordingBackgroundRuntime()
    let phone = AudioApprovalController(backgroundRuntime: background)
    phone.setDemo(true)
    phone.demoReceivePush(["runID": "runtime-run", "approvalID": "runtime-approval", "fingerprint": "sha256:runtime"])
    background.expire()
    XCTAssertTrue(background.active.isEmpty)
    XCTAssertTrue(phone.phase.contains("Background time expired"))
    await Task.yield()
    XCTAssertNil(phone.demoSpoken, "An expired check cannot play cached data or a late response")
  }

  func testVoicePreferenceSurvivesReopenAndConfiguresTheActualUtterance() throws {
    let suite = "audio-voice-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let phone = AudioApprovalController(voiceDefaults: defaults)
    phone.refreshVoices()
    let voice = try XCTUnwrap(phone.availableVoices.first)
    phone.setVoice(voice.id)
    let reopened = AudioApprovalController(voiceDefaults: defaults)
    XCTAssertEqual(reopened.voiceIdentifier, voice.id)
    XCTAssertEqual(reopened.speechUtterance(for: "Test voice").voice?.identifier, voice.id)
    reopened.setVoice("no-longer-installed")
    XCTAssertTrue(reopened.selectedVoiceUnavailable)
    XCTAssertNotNil(reopened.speechUtterance(for: "Test fallback").voice)
    XCTAssertEqual(reopened.voiceIdentifier, "no-longer-installed", "A removed preference stays recoverable")
    reopened.setVoice(nil)
    XCTAssertNil(AudioApprovalController(voiceDefaults: defaults).voiceIdentifier)
    XCTAssertEqual(reopened.speechUtterance(for: "Test automatic").voice?.identifier, reopened.automaticVoice?.id)
  }

  func testClosingAnIdleChatDoesNotDeactivateThePushToTalkSession() {
    let audio = RecordingAudioSession()
    let transcriber = MobileVoiceTranscriber(audioSession: audio)
    // Sending, switching chats, and leaving a chat all cancel its transcriber,
    // including when this chat never started microphone capture.
    transcriber.cancel()
    transcriber.cancel()
    XCTAssertEqual(audio.deactivations, 0, "An idle chat must not deactivate audio owned by Push to Talk")
  }

  func testDictationPreservesTheJoinedChannelsBluetoothConfiguration() throws {
    let defaults = UserDefaults.standard
    let old = defaults.object(forKey: AudioApprovalFeature.defaultsKey)
    defer {
      if let old { defaults.set(old, forKey: AudioApprovalFeature.defaultsKey) }
      else { defaults.removeObject(forKey: AudioApprovalFeature.defaultsKey) }
      AudioApprovalPushToTalkBridge.configureAudioSessionCategory()
    }
    defaults.set(true, forKey: AudioApprovalFeature.defaultsKey)
    AudioApprovalPushToTalkBridge.configureAudioSessionCategory()
    try MobileVoiceAudioSession().configureForDictation()
    let session = AVAudioSession.sharedInstance()
    XCTAssertEqual(session.category, .playAndRecord)
    XCTAssertEqual(session.mode, .voiceChat)
    XCTAssertTrue(session.categoryOptions.contains(.allowBluetooth), "Chat dictation must retain the headset input/output used by approvals")
    XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers), "The joined channel interrupts other audio instead of mixing with a podcast")
  }

  private final class RecordingAudioSession: MobileVoiceAudioSessionManaging {
    var deactivations = 0
    func activateForDictation() throws {}
    func deactivate() throws { deactivations += 1 }
  }

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

    let background = RecordingBackgroundRuntime()
    let phone = AudioApprovalController(backgroundRuntime: background)
    defer {
      let evidence = XCTAttachment(string: "Phone phase: \(phone.phase)\nPrompt: \(phone.promptText ?? "none")\nSpoken: \(phone.demoSpoken ?? "none")\nHost error: \(remote.workspaceConnectionError ?? "none")\nReply: \(phone.replyHistory.last?.outcome ?? "none")")
      evidence.lifetime = .keepAlways
      add(evidence)
    }
    phone.attach(remote: remote)
    phone.setDemo(true)
    phone.setDemoMediaPlaying(true)
    let control = try MobileRemoteClient(endpoint: endpoint, accessToken: nil)
    // Hold a foreground refresh with the OLD snapshot already captured on the host.
    let foreground = Task { await remote.refreshWorkspace() }
    let _: Empty = try await control.get("/test/wait-for-refresh", as: Empty.self)
    let push: Push = try await control.post("/test/create-fresh", payload: Empty(), as: Push.self)
    let _: Empty = try await control.post("/test/hold-fresh-verification", payload: Empty(), as: Empty.self)
    phone.demoReceivePush(["runID": push.runID, "approvalID": push.approvalID, "fingerprint": push.fingerprint, "deliveryID": push.deliveryID.uuidString])
    XCTAssertEqual(background.active.count, 1, "Background runtime must bridge the pushed approval's host verification")
    let _: Empty = try await control.get("/test/wait-for-fresh-verification", as: Empty.self)
    try await Task.sleep(for: .seconds(AudioApprovalFeature.remoteParticipantHoldLimit + 1))
    XCTAssertEqual(background.active.count, 1, "Releasing an idle PTT session must not suspend a still-running host verification")
    let _: Empty = try await control.post("/test/release-fresh-verification", payload: Empty(), as: Empty.self)
    try await eventually("The pushed approval must interrupt other media without opening the app or tapping Play; old cached snapshots must not discard its identity") {
      phone.demoSpoken?.contains("Fresh end-to-end approval") == true
    }
    XCTAssertTrue(background.active.isEmpty, "Audio playback takes over runtime from the bounded incoming-push task")
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

    // Physical order from the build 56/57 phone trace: Push to Talk activates on the receiver
    // before the Mac verifies the prompt; AirPods HFP becomes the route seconds later, and a
    // backgrounded app may not receive a route-change notification for it. Verification on the
    // receiver must not consume the prompt; the headset must be found by polling.
    let routedPush: Push = try await control.post("/test/create-fresh", payload: Empty(), as: Push.self)
    let backgroundPhone = AudioApprovalController()
    backgroundPhone.attach(remote: remote)
    backgroundPhone.setDemo(true)
    backgroundPhone.setDemoRoute(headset: false, notify: false)
    backgroundPhone.demoReceivePush(["runID": routedPush.runID, "approvalID": routedPush.approvalID,
      "fingerprint": routedPush.fingerprint, "deliveryID": routedPush.deliveryID.uuidString])
    try await eventually("The pushed prompt must be verified with the Mac while the route is still the receiver") {
      backgroundPhone.promptText?.contains("Fresh end-to-end approval") == true || backgroundPhone.demoHeldPrompts > 0
    }
    try await Task.sleep(for: .seconds(1))
    XCTAssertEqual(backgroundPhone.demoHeldPrompts, 0, "A verified prompt must not be spoken into the receiver while Bluetooth settles")
    XCTAssertNil(backgroundPhone.demoSpoken, "Nothing plays before the headset route exists")
    backgroundPhone.setDemoRoute(headset: true, notify: false)
    try await eventually("The headset route must be discovered without a route-change notification") {
      backgroundPhone.demoSpoken?.contains("Fresh end-to-end approval") == true
    }
    XCTAssertEqual(backgroundPhone.demoHeldPrompts, 0)
    backgroundPhone.demoReply("yes")
    try await eventually("Spoken yes after a delayed headset route must be confirmed by the Mac") {
      backgroundPhone.replyHistory.first(where: { $0.target?.approvalID == routedPush.approvalID })?.outcome.contains("Approved") == true
    }
    let routedResult: Result = try await control.get("/test/result", as: Result.self)
    XCTAssertEqual(routedResult.approvalID, routedPush.approvalID)
    XCTAssertEqual(routedResult.status, "approved")
    var routedTrace: [MobileRemoteAudioApprovalDeliveryRecord] = []
    let routedDeadline = Date().addingTimeInterval(12)
    repeat {
      routedTrace = try await remote.audioApprovalDeliveryDiagnostics().filter { $0.deliveryID == routedPush.deliveryID }
      if routedTrace.contains(where: { $0.stage == "decision-confirmed" }) { break }
      try await Task.sleep(for: .milliseconds(50))
    } while Date() < routedDeadline
    let activation = try XCTUnwrap(routedTrace.first { $0.stage == "audio-session-active" })
    XCTAssertEqual(activation.headset, false, "The activation receipt must report the receiver route: \(routedTrace)")
    XCTAssertTrue(activation.detail?.contains("out=SimulatedReceiver") == true, "Receipts must explain the route: \(activation.detail ?? "none")")
    XCTAssertFalse(routedTrace.contains { $0.stage == "playback-failed" }, "No failed attempt may precede the headset playback: \(routedTrace.map(\.stage))")
    XCTAssertTrue(routedTrace.contains { $0.stage == "playback-completed" && $0.headset == true })

    // A cold controller must reject an exact old push even though the real host still lists
    // the canonical approval as pending. Opening/rejoining never turns that backlog into speech.
    let delayed: Push = try await control.post("/test/delayed-old-push", payload: Empty(), as: Push.self)
    let stalePhone = AudioApprovalController()
    stalePhone.attach(remote: remote)
    stalePhone.setDemo(true)
    stalePhone.demoReceivePush(["runID": delayed.runID, "approvalID": delayed.approvalID,
      "fingerprint": delayed.fingerprint, "deliveryID": delayed.deliveryID.uuidString])
    try await eventually("An old still-pending push must be suppressed after a fresh host read") {
      stalePhone.phase.contains("Ignored an old")
    }
    XCTAssertNil(stalePhone.demoSpoken, "Delayed Revenue Scout notifications must never reach synthesis")
    XCTAssertNil(stalePhone.promptText)
    XCTAssertTrue(remote.workspaceApprovals.contains { $0.approvalID == delayed.approvalID },
      "Suppressing audio must preserve the pending request for review")
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
