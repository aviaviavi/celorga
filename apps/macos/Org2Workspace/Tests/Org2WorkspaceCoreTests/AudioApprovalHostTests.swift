import CryptoKit
import Foundation
import XCTest
@testable import Org2WorkspaceCore

private final class AudioApprovalPushURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var captured: [URLRequest] = []

  static func reset() { lock.withLock { captured = [] } }
  static var requests: [URLRequest] { lock.withLock { captured } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var stored = request
    if stored.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
      }
      stream.close()
      stored.httpBody = data
    }
    Self.lock.withLock { Self.captured.append(stored) }
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Host side of walkie-talkie audio approvals. These run without Apple's servers, a phone,
/// or any external action: APNs is replaced by a URL protocol or a delivery seam, and the
/// approval is a local demo run in a temporary corpus.
final class AudioApprovalHostTests: XCTestCase {
  override func tearDown() {
    AudioApprovalPushURLProtocol.reset()
    super.tearDown()
  }

  func testHistoryShowsCanonicalActorAndReasonAndExcludesPending() throws {
    let json = """
    {"id":"run-test","title":"Test","goal":"Test","status":"waiting-approval",
     "acceptanceCriteria":[],"riskClass":"read-only","capabilities":[],"context":[],
     "plan":[],"artifacts":[],"validations":[],"comments":[],"events":[],
     "createdAt":"2026-10-14T00:00:00Z","updatedAt":"2026-10-14T01:00:00Z",
     "approvals":[
       {"id":"old","title":"Old test","action":"test","riskClass":"read-only",
        "status":"canceled","requestedAt":"2026-10-14T00:00:00Z",
        "decidedAt":"2026-10-14T01:00:00Z","decidedBy":"Codex","decisionNote":"Superseded test"},
       {"id":"new","title":"Current test","action":"test","riskClass":"read-only",
        "status":"pending","requestedAt":"2026-10-14T01:00:00Z"}]}
    """
    let run = try JSONDecoder().decode(AgentRunItem.self, from: Data(json.utf8))
    let history = WorkspaceStore.mobileRemoteApprovalHistory(from: [run])
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.first?.status, "canceled")
    XCTAssertEqual(history.first?.decidedBy, "Codex")
    XCTAssertEqual(history.first?.decisionNote, "Superseded test")
    XCTAssertEqual(history.first?.runID, "run-test")
    let oldSnapshot = Data(#"{"updatedAt":0,"agenda":[],"approvals":[],"workflows":[]}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(MobileRemoteWorkspaceSnapshot.self, from: oldSnapshot).approvalHistory,
                 "New phones remain compatible with hosts that do not return history")
  }

  // MARK: APNs Push to Talk request

  func testPushToTalkRequestFollowsApplesHeadersAndCarriesIdentityOnly() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AudioApprovalPushURLProtocol.self]
    let sender = MobileRemotePushSender(session: URLSession(configuration: configuration))
    let messageID = UUID()
    try await sender.sendPushToTalk(
      MobileRemotePushToTalkEnvelope(messageID: messageID, runID: "run-1", approvalID: "approval-1", fingerprint: "sha256:abc"),
      to: MobileRemoteStoredPushToTalkRegistration(pushToken: "abcdef0123456789", environment: "sandbox"),
      credentials: MobileRemotePushProviderCredentials(
        teamID: "TEAM123",
        keyID: "KEY123",
        privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation
      )
    )
    let request = try XCTUnwrap(AudioApprovalPushURLProtocol.requests.first)
    XCTAssertEqual(request.url?.host, "api.sandbox.push.apple.com")
    XCTAssertEqual(request.url?.path, "/3/device/abcdef0123456789")
    XCTAssertEqual(request.value(forHTTPHeaderField: "apns-push-type"), "pushtotalk")
    XCTAssertEqual(request.value(forHTTPHeaderField: "apns-topic"), "org.org2.mobile.voip-ptt")
    XCTAssertEqual(request.value(forHTTPHeaderField: "apns-priority"), "10")
    XCTAssertEqual(request.value(forHTTPHeaderField: "apns-expiration"), "0", "A stale prompt must never be delivered late")
    XCTAssertEqual(request.value(forHTTPHeaderField: "apns-id"), messageID.uuidString)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    XCTAssertEqual(body["runID"] as? String, "run-1")
    XCTAssertEqual(body["approvalID"] as? String, "approval-1")
    XCTAssertEqual(body["fingerprint"] as? String, "sha256:abc")
    XCTAssertEqual(Set(body.keys), ["aps", "runID", "approvalID", "fingerprint"], "Approval text never travels through APNs")
  }

  // MARK: Serialization across competing agents

  func testNextPromptIsTheOldestExactPendingRunApprovalAndSkipsSnoozedOnes() {
    let now = Date()
    let approvals = [
      approvalItem(run: "run-b", approval: "b1", fingerprint: "fb", requestedAt: "2026-10-13T10:05:00.000Z"),
      approvalItem(run: "run-a", approval: "a1", fingerprint: "fa", requestedAt: "2026-10-13T10:01:00.000Z"),
      approvalItem(run: "run-c", approval: "c1", fingerprint: nil, requestedAt: "2026-10-13T09:00:00.000Z"),
      approvalItem(run: "run-d", approval: "d1", fingerprint: "fd", requestedAt: "2026-10-13T08:00:00.000Z", status: "approved"),
      approvalItem(run: nil, approval: "todo", fingerprint: "ft", requestedAt: "2026-10-13T07:00:00.000Z", kind: "todo"),
    ]
    let first = MobileRemoteCoordinator.nextAudioApprovalPrompt(from: approvals, snoozed: [:], now: now)
    XCTAssertEqual(first, AudioApprovalPromptTarget(runID: "run-a", approvalID: "a1", fingerprint: "fa"),
                   "Oldest complete pending run approval wins; incomplete identity, decided, and TODO approvals are never spoken")

    let snoozed = [first!.key: now.addingTimeInterval(600)]
    XCTAssertEqual(
      MobileRemoteCoordinator.nextAudioApprovalPrompt(from: approvals, snoozed: snoozed, now: now),
      AudioApprovalPromptTarget(runID: "run-b", approvalID: "b1", fingerprint: "fb"),
      "Later on one prompt moves to the next agent's approval"
    )
    XCTAssertEqual(
      MobileRemoteCoordinator.nextAudioApprovalPrompt(from: approvals, snoozed: snoozed, now: now.addingTimeInterval(601)),
      first,
      "An expired snooze returns the prompt to its place"
    )
    // A changed fingerprint is a different prompt: snoozing the old one does not hide the new one.
    let revised = [approvalItem(run: "run-a", approval: "a1", fingerprint: "fa2", requestedAt: "2026-10-13T10:01:00.000Z")]
    XCTAssertEqual(
      MobileRemoteCoordinator.nextAudioApprovalPrompt(from: revised, snoozed: snoozed, now: now)?.fingerprint,
      "fa2"
    )
  }

  // MARK: Registration storage

  func testHeadlessPushCredentialsSurviveExecutableReplacementWithoutKeychainACLs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("apns-private-key.pem")
    let suite = "AudioApprovalHostTests.PushCredentials.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let original = MobileRemotePushCredentialStore(
      defaults: defaults,
      credentialNamespace: suite,
      privateKeyFile: file
    )
    original.setTeamID("team123")
    original.setKeyID("key123")
    let privateKey = P256.Signing.PrivateKey().pemRepresentation
    try original.importPrivateKey(Data(privateKey.utf8))

    XCTAssertTrue(original.isConfigured)
    XCTAssertEqual(original.credentials?.privateKeyPEM, privateKey)
    let permissions = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    )
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)

    let afterUpgrade = MobileRemotePushCredentialStore(
      defaults: defaults,
      credentialNamespace: suite,
      privateKeyFile: file
    )
    XCTAssertTrue(afterUpgrade.isConfigured, "A rebuilt headless executable reads the same machine-local key file")
    XCTAssertEqual(afterUpgrade.credentials?.privateKeyPEM, privateKey)

    try afterUpgrade.clearPrivateKey()
    XCTAssertFalse(afterUpgrade.isConfigured)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testVaultStoresPushToTalkTokenWithQuietUntilAndRejectsInvalidTokens() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("devices.json")
    let vault = MobileRemoteCredentialVault(credentialFile: file)
    let paired = try vault.pair(deviceName: "Test phone")

    XCTAssertThrowsError(try vault.setPushToTalkRegistration(
      MobileRemotePushToTalkRegistrationRequest(pushToken: "not-hex!", environment: "sandbox", enabled: true),
      forAccessToken: paired.token
    ))
    XCTAssertThrowsError(try vault.setPushToTalkRegistration(
      MobileRemotePushToTalkRegistrationRequest(pushToken: "abcd", environment: "staging", enabled: true),
      forAccessToken: paired.token
    ))
    XCTAssertThrowsError(try vault.setPushToTalkRegistration(
      MobileRemotePushToTalkRegistrationRequest(pushToken: "abcd", environment: "sandbox", enabled: true),
      forAccessToken: "unknown-device"
    ))
    XCTAssertTrue(vault.pushToTalkRegistrations.isEmpty)

    let quietUntil = Date().addingTimeInterval(1800)
    XCTAssertTrue(try vault.setPushToTalkRegistration(
      MobileRemotePushToTalkRegistrationRequest(pushToken: "ABCDEF01", environment: "sandbox", enabled: true, quietUntil: quietUntil),
      forAccessToken: paired.token
    ))
    let restored = MobileRemoteCredentialVault(credentialFile: file)
    let stored = try XCTUnwrap(restored.pushToTalkRegistrations.first)
    XCTAssertEqual(stored.deviceID, paired.device.id)
    XCTAssertEqual(stored.registration.pushToken, "abcdef01")
    XCTAssertEqual(stored.registration.quietUntil?.timeIntervalSince1970 ?? 0, quietUntil.timeIntervalSince1970, accuracy: 1)

    XCTAssertFalse(try restored.setPushToTalkRegistration(
      MobileRemotePushToTalkRegistrationRequest(pushToken: nil, environment: nil, enabled: false),
      forAccessToken: paired.token
    ), "Leaving the channel removes the ephemeral token")
    XCTAssertTrue(restored.pushToTalkRegistrations.isEmpty)
  }

  // MARK: End to end over the paired-host transport

  /// Reversible local demo: a temporary corpus holds one run waiting on an approval that
  /// performs no external action. The phone side is the paired-host HTTP API.
  @MainActor
  func testAudioApprovalEndToEndOverPairedHostWithRealRunState() async throws {
    let repoRoot = try Org2CLI.defaultRepoRoot()
    guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("dist/cli.js").path) else {
      throw XCTSkip("Run npm run build first; this test drives the real CLI.")
    }
    let corpus = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-audio-approval-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: corpus) }
    let older = try createWaitingRun(repoRoot: repoRoot, corpus: corpus, title: "Send demo reply A")
    let newer = try createWaitingRun(repoRoot: repoRoot, corpus: corpus, title: "Send demo reply B")

    let suite = "AudioApprovalHostTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot), defaults: defaults, legacyDefaultsDomains: [])
    store.corpusRoot = corpus
    store.agentRunApprovalContinuationForTesting = { run in
      OpenClawApprovedRunContinuation(runID: run.id, sessionKey: nil, prompt: "demo", kind: "run", alreadyResumed: true)
    }
    let remote = MobileRemoteCoordinator(
      defaults: defaults,
      credentialFile: corpus.appendingPathComponent("devices.json")
    )
    var pushes: [MobileRemotePushToTalkEnvelope] = []
    remote.pushToTalkDeliveryForTesting = { envelope, _ in pushes.append(envelope) }
    remote.attach(to: store)

    // Pair the phone exactly as the iOS app does.
    remote.setPairingCodeForTesting("424242")
    let pairing = try await call(remote, "POST", "/v1/pair", MobileRemotePairRequest(
      code: "424242", deviceName: "Demo phone"
    ), as: MobileRemotePairResponse.self)
    let token = pairing.accessToken

    // Enrollment: the ephemeral Push to Talk token reaches the host.
    let registration = try await call(remote, "POST", "/v1/push-to-talk-registration",
      MobileRemotePushToTalkRegistrationRequest(pushToken: "abcdef0123", environment: "sandbox", enabled: true),
      token: token, as: MobileRemotePushToTalkRegistrationResponse.self)
    XCTAssertTrue(registration.enabled)

    // An unknown route names itself instead of the misleading thread-lookup error.
    let unknown = try await rawCall(remote, "POST", "/v1/not-a-route", Optional<String>.none, token: token)
    XCTAssertEqual(unknown.statusCode, 404)
    let unknownText = (try JSONSerialization.jsonObject(with: unknown.body) as? [String: Any])?["error"] as? String ?? ""
    XCTAssertTrue(unknownText.contains("does not support POST /v1/not-a-route"), unknownText)
    XCTAssertFalse(unknownText.contains("Thread not found"), unknownText)

    // The host serializes: one push, for the oldest approval.
    await store.refreshApprovals(updatesStatus: false)
    try await waitUntil { pushes.count == 1 }
    XCTAssertEqual(pushes.first?.runID, older.runID)
    XCTAssertEqual(pushes.first?.approvalID, older.approvalID)
    XCTAssertEqual(pushes.first?.fingerprint, older.fingerprint)

    let snapshot = try await call(remote, "GET", "/v1/workspace", Optional<String>.none, token: token,
                                  as: MobileRemoteWorkspaceSnapshot.self)
    let item = try XCTUnwrap(snapshot.approvals.first { $0.approvalID == older.approvalID })
    let decisionPath = "/v1/workspace/approvals/\(item.id)/decision"

    // A wrong fingerprint changes nothing.
    let mismatch = try await rawCall(remote, "POST", decisionPath, MobileRemoteApprovalDecisionRequest(
      decision: "approved", runID: older.runID, approvalID: older.approvalID,
      fingerprint: "sha256:stale", receipt: "audio-approval:demo-1"
    ), token: token)
    XCTAssertGreaterThanOrEqual(mismatch.statusCode, 400)
    XCTAssertEqual(try runApproval(repoRoot: repoRoot, corpus: corpus, older)["status"] as? String, "pending")

    // The exact decision applies once and reports what happened to the run.
    let applied = try await call(remote, "POST", decisionPath, MobileRemoteApprovalDecisionRequest(
      decision: "approved", runID: older.runID, approvalID: older.approvalID,
      fingerprint: older.fingerprint, receipt: "audio-approval:demo-1"
    ), token: token, as: MobileRemoteWorkspaceSnapshot.self)
    let receipt = try XCTUnwrap(applied.approvalDecisionReceipt)
    XCTAssertEqual(receipt.runID, older.runID)
    XCTAssertEqual(receipt.approvalID, older.approvalID)
    XCTAssertEqual(receipt.decision, "approved")
    XCTAssertEqual(receipt.runStatus, "running")
    XCTAssertEqual(receipt.pendingApprovalCount, 0)
    XCTAssertEqual(receipt.continuation, MobileRemoteApprovalContinuation.alreadyContinuing.rawValue)
    XCTAssertFalse(receipt.duplicate)
    let durable = try runApproval(repoRoot: repoRoot, corpus: corpus, older)
    XCTAssertEqual(durable["status"] as? String, "approved")
    XCTAssertEqual(durable["receipt"] as? String, "audio-approval:demo-1", "The requesting agent can see the audio provenance")

    // Replaying the same receipt returns the original outcome and applies nothing.
    let replay = try await call(remote, "POST", decisionPath, MobileRemoteApprovalDecisionRequest(
      decision: "approved", runID: older.runID, approvalID: older.approvalID,
      fingerprint: older.fingerprint, receipt: "audio-approval:demo-1"
    ), token: token, as: MobileRemoteWorkspaceSnapshot.self)
    XCTAssertEqual(replay.approvalDecisionReceipt?.duplicate, true)
    // A different receipt or decision for the decided approval is refused.
    let conflicting = try await rawCall(remote, "POST", decisionPath, MobileRemoteApprovalDecisionRequest(
      decision: "rejected", note: "no", runID: older.runID, approvalID: older.approvalID,
      fingerprint: older.fingerprint, receipt: "audio-approval:demo-1"
    ), token: token)
    XCTAssertGreaterThanOrEqual(conflicting.statusCode, 400)

    // The next agent's approval is offered only now.
    try await waitUntil { pushes.count == 2 }
    XCTAssertEqual(pushes.last?.approvalID, newer.approvalID)

    // "Later" moves past it without deciding it, and quiet holds every push.
    _ = try await call(remote, "POST", "/v1/audio-approvals/snooze", MobileRemoteAudioApprovalSnoozeRequest(
      runID: newer.runID, approvalID: newer.approvalID, fingerprint: newer.fingerprint,
      until: Date().addingTimeInterval(600)
    ), token: token, as: MobileRemoteAudioApprovalSnoozeResponse.self)
    _ = try await call(remote, "POST", "/v1/push-to-talk-registration",
      MobileRemotePushToTalkRegistrationRequest(pushToken: "abcdef0123", environment: "sandbox", enabled: true,
                                                quietUntil: .distantFuture),
      token: token, as: MobileRemotePushToTalkRegistrationResponse.self)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(pushes.count, 2)
    XCTAssertEqual(try runApproval(repoRoot: repoRoot, corpus: corpus, newer)["status"] as? String, "pending",
                   "Snooze and quiet never decide anything")
  }

  func testUrgentFirstAndDeliveredPromptsDoNotBlockNewerOnes() {
    let now = Date()
    let older = approvalItem(run: "run-a", approval: "a", fingerprint: "sha256:a", requestedAt: "2026-10-13T10:00:00Z")
    let newer = approvalItem(run: "run-b", approval: "b", fingerprint: "sha256:b", requestedAt: "2026-10-13T10:05:00Z")
    let urgent = approvalItem(run: "run-u", approval: "u", fingerprint: "sha256:u", requestedAt: "2026-10-13T11:00:00Z", priority: "urgent")
    XCTAssertEqual(MobileRemoteCoordinator.nextAudioApprovalPrompt(from: [older, newer, urgent], snoozed: [:], now: now)?.approvalID, "u")
    XCTAssertEqual(MobileRemoteCoordinator.nextAudioApprovalPrompt(from: [newer, older], snoozed: [:], now: now)?.approvalID, "a",
                   "Without explicit urgency, age decides the order")
    XCTAssertEqual(MobileRemoteCoordinator.nextAudioApprovalPrompt(
      from: [older, newer], snoozed: [:], excluding: ["run-a|a|sha256:a"], now: now)?.approvalID, "b",
      "A delivered, unanswered prompt does not block the next one")
    XCTAssertNil(MobileRemoteCoordinator.nextAudioApprovalPrompt(
      from: [older], snoozed: [:], excluding: ["run-a|a|sha256:a"], now: now), "A delivered prompt is not pushed again")
    XCTAssertEqual(AudioApprovalPromptPolicy.holdEnds(delivered: ["k": now], now: now.addingTimeInterval(10)),
                   now.addingTimeInterval(AudioApprovalPromptPolicy.answerWindow))
    XCTAssertNil(AudioApprovalPromptPolicy.holdEnds(delivered: ["k": now], now: now.addingTimeInterval(AudioApprovalPromptPolicy.answerWindow + 1)))
  }

  @MainActor
  func testUnansweredPromptDoesNotStarveNewOnesAndCanonicalUrgentGoesFirst() async throws {
    let repoRoot = try Org2CLI.defaultRepoRoot()
    guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("dist/cli.js").path) else {
      throw XCTSkip("Run npm run build first; this test drives the real CLI.")
    }
    let corpus = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-audio-approval-starve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: corpus) }
    let first = try createWaitingRun(repoRoot: repoRoot, corpus: corpus, title: "Stale demo A")
    let second = try createWaitingRun(repoRoot: repoRoot, corpus: corpus, title: "Demo B")

    let suite = "AudioApprovalHostTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot), defaults: defaults, legacyDefaultsDomains: [])
    store.corpusRoot = corpus
    let remote = MobileRemoteCoordinator(defaults: defaults, credentialFile: corpus.appendingPathComponent("devices.json"))
    remote.pushToTalkAnswerWindow = 0.2
    var pushes: [MobileRemotePushToTalkEnvelope] = []
    remote.pushToTalkDeliveryForTesting = { envelope, _ in pushes.append(envelope) }
    remote.attach(to: store)
    remote.setPairingCodeForTesting("434343")
    let token = try await call(remote, "POST", "/v1/pair", MobileRemotePairRequest(code: "434343", deviceName: "Demo phone"),
                               as: MobileRemotePairResponse.self).accessToken
    // Enrollment refreshes canonical approvals itself; nothing else loads them.
    _ = try await call(remote, "POST", "/v1/push-to-talk-registration",
      MobileRemotePushToTalkRegistrationRequest(pushToken: "abcdef0123", environment: "sandbox", enabled: true),
      token: token, as: MobileRemotePushToTalkRegistrationResponse.self)
    try await waitUntil { pushes.count == 1 }
    XCTAssertEqual(pushes[0].approvalID, first.approvalID)

    // A is left unanswered. After the answer window B gets its own delivery.
    try await waitUntil { pushes.count == 2 }
    XCTAssertEqual(pushes[1].approvalID, second.approvalID)
    XCTAssertEqual(try runApproval(repoRoot: repoRoot, corpus: corpus, first)["status"] as? String, "pending")

    // Written by another process; the host's cache is not told. The urgent one goes first.
    let normal = try createWaitingRun(repoRoot: repoRoot, corpus: corpus, title: "Demo C")
    let urgent = try createWaitingRun(repoRoot: repoRoot, corpus: corpus, title: "Urgent demo D", priority: "urgent")
    XCTAssertEqual(try runApproval(repoRoot: repoRoot, corpus: corpus, urgent)["priority"] as? String, "urgent")
    try await waitUntil { pushes.count == 3 }
    XCTAssertEqual(pushes[2].approvalID, urgent.approvalID, "Canonical state is reread before choosing")
    try await waitUntil { pushes.count == 4 }
    XCTAssertEqual(pushes[3].approvalID, normal.approvalID)
    try await Task.sleep(for: .milliseconds(1_500))
    XCTAssertEqual(pushes.count, 4, "Each prompt is pushed once")
  }

  // MARK: Helpers

  private struct DemoApproval {
    let runID: String
    let approvalID: String
    let fingerprint: String
  }

  private func approvalItem(
    run: String?,
    approval: String,
    fingerprint: String?,
    requestedAt: String,
    status: String = "pending",
    kind: String = "run",
    priority: String? = nil
  ) -> ApprovalItem {
    ApprovalItem(
      title: "Approve \(approval)",
      status: status,
      todo: nil,
      level: nil,
      file: "/tmp/\(approval).org2",
      line: 1,
      idValue: approval,
      properties: [:],
      body: "",
      tags: [],
      kind: kind,
      approvalId: approval,
      fingerprint: fingerprint,
      requestedAt: requestedAt,
      runId: run,
      priority: priority
    )
  }

  private func cli(_ repoRoot: URL, _ arguments: [String]) throws -> [String: Any] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", repoRoot.appendingPathComponent("dist/cli.js").path] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "celorga \(arguments.joined(separator: " ")) failed")
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (json["run"] as? [String: Any]) ?? json
  }

  private func createWaitingRun(repoRoot: URL, corpus: URL, title: String, priority: String? = nil) throws -> DemoApproval {
    let created = try cli(repoRoot, ["run", "create", "--title", title, "--goal", "Reversible audio approval demo", "--dir", corpus.path, "--json"])
    let runID = try XCTUnwrap(created["id"] as? String)
    _ = try cli(repoRoot, ["run", "start", runID, "--dir", corpus.path, "--json"])
    let waiting = try cli(repoRoot, [
      "run", "approval-request", runID,
      "--title", title,
      "--action", "No external action; demo only",
      "--risk", "external-action",
      "--dir", corpus.path, "--json",
    ] + (priority.map { ["--priority", $0] } ?? []))
    let approval = try XCTUnwrap((waiting["approvals"] as? [[String: Any]])?.last)
    // Keep requestedAt strictly ordered between the two demo runs.
    Thread.sleep(forTimeInterval: 0.01)
    return DemoApproval(
      runID: runID,
      approvalID: try XCTUnwrap(approval["id"] as? String),
      fingerprint: try XCTUnwrap(approval["fingerprint"] as? String)
    )
  }

  private func runApproval(repoRoot: URL, corpus: URL, _ demo: DemoApproval) throws -> [String: Any] {
    let run = try cli(repoRoot, ["run", "show", demo.runID, "--dir", corpus.path, "--json"])
    return try XCTUnwrap((run["approvals"] as? [[String: Any]])?.first { $0["id"] as? String == demo.approvalID })
  }

  @MainActor
  private func rawCall<Body: Encodable>(
    _ remote: MobileRemoteCoordinator,
    _ method: String,
    _ path: String,
    _ body: Body?,
    token: String? = nil
  ) async throws -> MobileRemoteHTTPResponse {
    var headers = ["Content-Type": "application/json"]
    if let token { headers["Authorization"] = "Bearer \(token)" }
    let data = try body.map { try MobileRemoteProtocol.encoder().encode($0) } ?? Data()
    return await remote.handle(MobileRemoteHTTPRequest(method: method, path: path, headers: headers, body: data))
  }

  @MainActor
  private func call<Body: Encodable, Response: Decodable>(
    _ remote: MobileRemoteCoordinator,
    _ method: String,
    _ path: String,
    _ body: Body?,
    token: String? = nil,
    as type: Response.Type
  ) async throws -> Response {
    let response = try await rawCall(remote, method, path, body, token: token)
    XCTAssertLessThan(response.statusCode, 300, String(decoding: response.body, as: UTF8.self))
    return try MobileRemoteProtocol.decoder().decode(type, from: response.body)
  }

  @MainActor
  private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { XCTFail("Timed out"); return }
      try await Task.sleep(for: .milliseconds(25))
    }
  }
}
