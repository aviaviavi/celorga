import CryptoKit
import Foundation
import XCTest
@testable import Org2WorkspaceCore

private final class GuestTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_800_000_000)

  var now: Date { lock.withLock { value } }

  func advance(_ seconds: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(seconds) }
  }
}

private actor GuestSendRecorder {
  private(set) var texts: [String] = []

  func record(_ text: String) {
    texts.append(text)
  }
}

final class AIChatGuestMessagesTests: XCTestCase {
  private let shareID = "share-token-fixture"
  private let threadID = UUID()

  private func makeQueue(clock: GuestTestClock = GuestTestClock()) -> AIChatGuestMessageQueue {
    AIChatGuestMessageQueue(now: { clock.now })
  }

  // MARK: Queue lifecycle

  func testSubmissionsWaitUntilApprovedAndKeepOnlyTheirStatus() throws {
    let queue = makeQueue()
    let nonce = queue.enable(shareID: shareID, threadID: threadID)
    XCTAssertEqual(queue.enable(shareID: shareID, threadID: threadID), nonce, "Re-enabling keeps the page nonce")
    XCTAssertEqual(queue.nonce(forThread: threadID), nonce)
    XCTAssertEqual(queue.enabledThreadIDs, [threadID])

    let submission = try queue.submit(
      shareID: shareID, nonce: nonce, name: "  Dana\n Example ", text: "Can you add a summary?\r\n"
    ).get()
    XCTAssertEqual(submission.status, .pending)
    XCTAssertEqual(submission.displayName, "Dana Example")
    XCTAssertEqual(submission.text, "Can you add a summary?")
    XCTAssertEqual(submission.threadID, threadID)
    XCTAssertGreaterThanOrEqual(submission.id.count, 40)
    XCTAssertEqual(queue.pendingSubmissions.map(\.id), [submission.id])

    let approved = try XCTUnwrap(queue.resolve(submission.id, approved: true))
    XCTAssertEqual(approved.text, "Can you add a summary?")
    XCTAssertNil(queue.resolve(submission.id, approved: false), "A decision is final")
    XCTAssertTrue(queue.pendingSubmissions.isEmpty)
    XCTAssertNil(queue.pendingSubmission(submission.id))
    XCTAssertEqual(
      try queue.statuses(shareID: shareID, nonce: nonce, ids: [submission.id, "unknown"]).get(),
      [submission.id: .approved]
    )
  }

  func testDeclineDiscardsTheMessageAndReportsDeclined() throws {
    let queue = makeQueue()
    let nonce = queue.enable(shareID: shareID, threadID: threadID)
    let submission = try queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: "Hello").get()

    queue.resolve(submission.id, approved: false)

    XCTAssertTrue(queue.pendingSubmissions.isEmpty)
    XCTAssertEqual(try queue.statuses(shareID: shareID, nonce: nonce, ids: [submission.id]).get(), [submission.id: .declined])
  }

  func testDisablingRejectsNewSubmissionsAndClearsPendingOnes() throws {
    let queue = makeQueue()
    let nonce = queue.enable(shareID: shareID, threadID: threadID)
    let otherNonce = queue.enable(shareID: "other-share", threadID: UUID())
    _ = try queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: "One").get()
    let kept = try queue.submit(shareID: "other-share", nonce: otherNonce, name: "Lee", text: "Two").get()

    queue.disable(shareID: shareID)

    XCTAssertEqual(queue.pendingSubmissions.map(\.id), [kept.id])
    XCTAssertNil(queue.nonce(forThread: threadID))
    XCTAssertEqual(
      queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: "Again").failure,
      .notAccepting
    )
    XCTAssertEqual(queue.statuses(shareID: shareID, nonce: nonce, ids: []).failure, .notAccepting)

    // Turning it back on issues a new nonce; the old page nonce stops working.
    let renewed = queue.enable(shareID: shareID, threadID: threadID)
    XCTAssertNotEqual(renewed, nonce)
    XCTAssertEqual(queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: "Old").failure, .invalidNonce)

    queue.disableAll()
    XCTAssertTrue(queue.pendingSubmissions.isEmpty)
    XCTAssertTrue(queue.enabledThreadIDs.isEmpty)
  }

  func testValidatesNameTextAndNonce() {
    let queue = makeQueue()
    let nonce = queue.enable(shareID: shareID, threadID: threadID)
    XCTAssertEqual(queue.submit(shareID: shareID, nonce: nil, name: "Dana", text: "Hi").failure, .invalidNonce)
    XCTAssertEqual(queue.submit(shareID: shareID, nonce: "wrong", name: "Dana", text: "Hi").failure, .invalidNonce)
    XCTAssertEqual(queue.submit(shareID: shareID, nonce: nonce, name: " \n", text: "Hi").failure, .invalidPayload("Enter your name."))
    XCTAssertEqual(queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: " \u{0}\u{7} ").failure, .invalidPayload("Enter a message."))
    XCTAssertNotNil(queue.submit(shareID: shareID, nonce: nonce, name: String(repeating: "n", count: 41), text: "Hi").failure)
    XCTAssertEqual(
      queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: String(repeating: "m", count: 1_001)).failure,
      .tooLarge
    )
    let cleaned = try? queue.submit(shareID: shareID, nonce: nonce, name: "Da\u{202E}na", text: "a\u{0}b\tc\u{1B}[31m").get()
    XCTAssertEqual(cleaned?.displayName, "Da na")
    XCTAssertEqual(cleaned?.text, "ab\tc[31m")
  }

  func testRateLimitAndPendingCapPerShare() throws {
    let clock = GuestTestClock()
    let queue = makeQueue(clock: clock)
    let nonce = queue.enable(shareID: shareID, threadID: threadID)
    for index in 0..<AIChatGuestMessageQueue.submissionsPerWindow {
      _ = try queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: "Message \(index)").get()
    }
    XCTAssertEqual(queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: "Too soon").failure, .rateLimited)

    clock.advance(AIChatGuestMessageQueue.rateWindow)
    XCTAssertNotNil(try? queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: "Later").get())

    while queue.pendingSubmissions.count < AIChatGuestMessageQueue.maximumPendingPerShare {
      clock.advance(AIChatGuestMessageQueue.rateWindow)
      _ = try queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: "Fill").get()
    }
    clock.advance(AIChatGuestMessageQueue.rateWindow)
    XCTAssertEqual(queue.submit(shareID: shareID, nonce: nonce, name: "Dana", text: "Full").failure, .queueFull)
  }

  func testAttributionNamesTheGuest() {
    XCTAssertEqual(
      AIChatGuestMessageQueue.attributedText(name: "Dana", text: "Please add tests."),
      "Guest — Dana: Please add tests."
    )
  }

  // MARK: HTTP handler

  private func request(
    _ method: String = "POST",
    path: String = "/a/share-token-fixture/guest",
    nonce: String?,
    origin: String? = "http://studio.local:8123",
    host: String = "studio.local:8123",
    contentType: String? = "application/json",
    fetchSite: String? = nil,
    body: Data = Data(#"{"name":"Dana","text":"Hello from the page"}"#.utf8)
  ) -> MobileRemoteHTTPRequest {
    var headers = ["Host": host]
    if let nonce { headers[AIChatGuestMessageHTTP.nonceHeader] = nonce }
    if let origin { headers["Origin"] = origin }
    if let contentType { headers["Content-Type"] = contentType }
    if let fetchSite { headers["Sec-Fetch-Site"] = fetchSite }
    return MobileRemoteHTTPRequest(method: method, path: path, headers: headers, body: body)
  }

  private func respond(
    _ request: MobileRemoteHTTPRequest,
    route: [String] = [],
    queue: AIChatGuestMessageQueue
  ) -> MobileRemoteHTTPResponse {
    AIChatGuestMessageHTTP.response(to: request, shareID: shareID, route: route, queue: queue)
  }

  private func json(_ response: MobileRemoteHTTPResponse) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
  }

  func testHandlerQueuesASameOriginSubmissionAndReportsItsStatus() throws {
    let queue = makeQueue()
    let nonce = queue.enable(shareID: shareID, threadID: threadID)

    let created = respond(request(nonce: nonce, fetchSite: "same-origin"), queue: queue)
    XCTAssertEqual(created.statusCode, 201)
    XCTAssertEqual(created.headers["Cache-Control"], "no-store")
    let id = try XCTUnwrap(json(created)["id"] as? String)
    XCTAssertEqual(json(created)["status"] as? String, "pending")
    XCTAssertEqual(queue.pendingSubmissions.first?.text, "Hello from the page")

    // Non-browser clients send no Origin; the token and nonce still apply.
    XCTAssertEqual(respond(request(nonce: nonce, origin: nil), queue: queue).statusCode, 201)

    queue.resolve(id, approved: true)
    let status = respond(
      request("GET", path: "/a/share-token-fixture/guest/status?ids=\(id),missing", nonce: nonce, body: Data()),
      route: ["status"],
      queue: queue
    )
    XCTAssertEqual(status.statusCode, 200)
    XCTAssertEqual(json(status)["statuses"] as? [String: String], [id: "approved"])
  }

  func testHandlerRejectsMissingNonceAndCrossOriginPosts() {
    let queue = makeQueue()
    let nonce = queue.enable(shareID: shareID, threadID: threadID)

    XCTAssertEqual(respond(request(nonce: nil), queue: queue).statusCode, 403)
    XCTAssertEqual(respond(request(nonce: "forged"), queue: queue).statusCode, 403)
    XCTAssertEqual(respond(request(nonce: nonce, origin: "http://attacker.example"), queue: queue).statusCode, 403)
    XCTAssertEqual(respond(request(nonce: nonce, origin: "http://studio.local:9999"), queue: queue).statusCode, 403)
    XCTAssertEqual(respond(request(nonce: nonce, origin: "null"), queue: queue).statusCode, 403)
    XCTAssertEqual(respond(request(nonce: nonce, fetchSite: "cross-site"), queue: queue).statusCode, 403)
    XCTAssertEqual(respond(request(nonce: nonce, contentType: "text/plain"), queue: queue).statusCode, 415)
    XCTAssertEqual(
      respond(request("GET", path: "/a/share-token-fixture/guest/status", nonce: nil, body: Data()), route: ["status"], queue: queue)
        .statusCode,
      403
    )
    XCTAssertTrue(queue.pendingSubmissions.isEmpty)
    XCTAssertEqual(respond(request("DELETE", nonce: nonce), queue: queue).statusCode, 404)
  }

  func testHandlerEnforcesSizeRateAndAcceptanceLimits() {
    let queue = makeQueue()
    let nonce = queue.enable(shareID: shareID, threadID: threadID)

    let oversized = Data(repeating: UInt8(ascii: "a"), count: AIChatGuestMessageQueue.maximumBodyBytes + 1)
    XCTAssertEqual(respond(request(nonce: nonce, body: oversized), queue: queue).statusCode, 413)
    let longText = Data(#"{"name":"Dana","text":"\#(String(repeating: "x", count: 1_001))"}"#.utf8)
    XCTAssertEqual(respond(request(nonce: nonce, body: longText), queue: queue).statusCode, 413)
    XCTAssertEqual(respond(request(nonce: nonce, body: Data("not json".utf8)), queue: queue).statusCode, 400)

    for _ in 0..<AIChatGuestMessageQueue.submissionsPerWindow {
      XCTAssertEqual(respond(request(nonce: nonce), queue: queue).statusCode, 201)
    }
    XCTAssertEqual(respond(request(nonce: nonce), queue: queue).statusCode, 429)

    queue.disable(shareID: shareID)
    XCTAssertEqual(respond(request(nonce: nonce), queue: queue).statusCode, 403)
  }

  func testSameOriginAcceptsMatchingIPv6Hosts() {
    let ipv6 = request(nonce: "n", origin: "http://[fd7a:115c::1]:8123", host: "[fd7a:115c::1]:8123")
    XCTAssertTrue(AIChatGuestMessageHTTP.isSameOrigin(ipv6))
    let https = request(nonce: "n", origin: "https://studio.local:8123")
    XCTAssertFalse(AIChatGuestMessageHTTP.isSameOrigin(https))
  }

  // MARK: Hosted endpoint and page

  func testLiveHostRoutesGuestPostsByLinkTokenAndClearsThemOnRevoke() async throws {
    let host = LocalDocumentPublicationHost(bindHost: "127.0.0.1", advertisedHost: "127.0.0.1")
    defer { host.stop() }
    let publication = try await host.publish(
      data: Data("<p>Thread</p>".utf8),
      title: "Launch plan",
      mediaType: "text/html",
      stableKey: LocalDocumentPublication.chatThreadStableKey(threadID),
      revision: "rev-1"
    )
    let (_, pageResponse) = try await URLSession.shared.data(from: publication.localURL)
    let policy = try XCTUnwrap((pageResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Security-Policy"))
    XCTAssertTrue(policy.contains("'\(AIChatGuestMessageHTTP.scriptHash)'"))
    XCTAssertTrue(policy.contains("form-action 'none'"))

    func post(_ url: URL, nonce: String?) async throws -> Int {
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      if let nonce { request.setValue(nonce, forHTTPHeaderField: AIChatGuestMessageHTTP.nonceHeader) }
      request.httpBody = Data(#"{"name":"Dana","text":"Hello"}"#.utf8)
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    let guestURL = publication.localURL.appendingPathComponent("guest")
    let offStatus = try await post(guestURL, nonce: "anything")
    XCTAssertEqual(offStatus, 403, "Off by default")

    let nonce = host.guestMessages.enable(shareID: publication.id, threadID: threadID)
    let createdStatus = try await post(guestURL, nonce: nonce)
    XCTAssertEqual(createdStatus, 201)
    let wrongToken = publication.localURL.deletingLastPathComponent()
      .appendingPathComponent("not-a-real-token").appendingPathComponent("guest")
    let wrongTokenStatus = try await post(wrongToken, nonce: nonce)
    XCTAssertEqual(wrongTokenStatus, 404)
    XCTAssertEqual(host.guestMessages.pendingSubmissions.count, 1)

    try host.revoke(publication.id)
    XCTAssertTrue(host.guestMessages.pendingSubmissions.isEmpty)
    XCTAssertFalse(host.guestMessages.isEnabled(shareID: publication.id))
    let revokedStatus = try await post(guestURL, nonce: nonce)
    XCTAssertEqual(revokedStatus, 404)
  }

  func testPageEmbedsTheNonceOnlyWhileGuestsMaySendAndPinsBothScripts() throws {
    let message = AIChatThreadPublicationSnapshot.Message(
      id: UUID(), role: .user, author: "Dana", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      text: "Guest — <b>Lee</b>: hi", formatted: false, attachments: []
    )
    var snapshot = AIChatThreadPublicationSnapshot(
      threadID: threadID,
      title: "Launch",
      messages: [message],
      respondingStatus: nil,
      appearanceMode: .system,
      lightTheme: WorkspaceThemeCatalog.theme(id: nil, for: .light),
      darkTheme: WorkspaceThemeCatalog.theme(id: nil, for: .dark)
    )
    let closed = AIChatThreadPublicationPage.html(snapshot: snapshot, bodies: [:], rendererStylesheet: nil)
    XCTAssertTrue(closed.contains(#"<div id="openorg-live-root">"#))
    XCTAssertTrue(closed.contains(#"<section id="celorga-guest" class="guest" hidden"#))
    XCTAssertTrue(closed.contains("Guest — &lt;b&gt;Lee&lt;/b&gt;: hi"))

    snapshot.guestNonce = "nonce-fixture"
    let open = AIChatThreadPublicationPage.html(snapshot: snapshot, bodies: [:], rendererStylesheet: nil)
    XCTAssertTrue(open.contains(#"<div id="openorg-live-root" data-guest-nonce="nonce-fixture">"#))
    XCTAssertNotEqual(
      AIChatThreadPublicationPage.revision(snapshot: snapshot, bodies: [:]),
      AIChatThreadPublicationPage.revision(snapshot: { var s = snapshot; s.guestNonce = nil; return s }(), bodies: [:]),
      "Toggling guest messages refreshes open pages"
    )

    let scripts = open.components(separatedBy: "<script>").dropFirst()
      .compactMap { $0.components(separatedBy: "</script>").first }
    let hashes = scripts.map { "sha256-" + Data(SHA256.hash(data: Data($0.utf8))).base64EncodedString() }
    XCTAssertEqual(hashes, [LocalDocumentPublicationHost.liveUpdateScriptHash, AIChatGuestMessageHTTP.scriptHash])
    XCTAssertFalse(AIChatGuestMessageHTTP.script.contains("innerHTML"))
  }

  // MARK: Store

  @MainActor
  func testApprovingSendsAnAttributedMessageThroughTheThreadAndDeclineDoesNot() async throws {
    let suiteName = "AIChatGuestMessagesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-guest-messages-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = GuestSendRecorder()
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { history, text, _, _ in
        await recorder.record((history.map(\.content) + [text]).joined(separator: "\n"))
        return "Noted."
      }
    )
    store.setCorpusRoot(root)
    let threadID = store.createAIChatRemoteThread(runtime: .openClaw)
    store.observeAIChatGuestMessages()
    let queue = store.aiChatGuestMessageQueue
    let nonce = queue.enable(shareID: "fixture-share", threadID: threadID)
    let declined = try queue.submit(shareID: "fixture-share", nonce: nonce, name: "Lee", text: "Ignore this").get()
    let approved = try queue.submit(shareID: "fixture-share", nonce: nonce, name: "Dana", text: "Add a FAQ").get()

    let deadline = Date().addingTimeInterval(5)
    while store.pendingAIChatGuestMessages(for: threadID).count != 2, Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertEqual(store.pendingAIChatGuestMessages(for: threadID).map(\.id), [declined.id, approved.id])
    XCTAssertTrue(store.isChatThreadGuestMessagesEnabled(threadID))

    store.declineAIChatGuestMessage(declined.id)
    XCTAssertTrue(store.approveAIChatGuestMessage(approved.id, editedText: "Add a short FAQ"))
    XCTAssertFalse(store.approveAIChatGuestMessage(approved.id), "Approving twice sends once")
    XCTAssertTrue(store.pendingAIChatGuestMessages(for: threadID).isEmpty)

    while store.aiChatThreads.first(where: { $0.id == threadID })?.messages.count != 2
      || store.isAIChatThreadRunning(threadID),
      Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let messages = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID })?.messages)
    XCTAssertEqual(messages.first?.role, .user)
    XCTAssertEqual(messages.first?.content, "Guest — Dana: Add a short FAQ")
    let sent = await recorder.texts
    XCTAssertEqual(sent.count, 1)
    XCTAssertTrue(sent.first?.contains("Guest — Dana: Add a short FAQ") == true)
    XCTAssertFalse(sent.contains { $0.contains("Ignore this") })
  }
}

private extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
