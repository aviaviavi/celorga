import Foundation
import XCTest
@testable import Org2WorkspaceCore

private final class OpenAIDotTestURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (Int, Any))?
  nonisolated(unsafe) private static var recorded: [URLRequest] = []

  static func setHandler(_ handler: @escaping (URLRequest) throws -> (Int, Any)) {
    lock.withLock {
      self.handler = handler
      recorded = []
    }
  }

  static var requests: [URLRequest] { lock.withLock { recorded } }

  static func reset() {
    lock.withLock {
      handler = nil
      recorded = []
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      var request = request
      if request.httpBody == nil, let stream = request.httpBodyStream {
        request.httpBody = Self.read(stream)
      }
      let handler = Self.lock.withLock {
        Self.recorded.append(request)
        return Self.handler
      }
      let (status, object) = try XCTUnwrap(handler)(request)
      let response = try XCTUnwrap(HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      ))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  private static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

/// A manual clock: sleeping advances time instantly.
private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_800_000_000)

  var now: Date { lock.withLock { current } }

  func advance(_ seconds: TimeInterval) {
    lock.withLock { current = current.addingTimeInterval(seconds) }
  }
}

final class OpenAIDotChatClientTests: XCTestCase {
  private let roomID = "room-juniper"
  private let selfMember = "user-self"
  private let dotMember = "member-juniper"

  override func tearDown() {
    OpenAIDotTestURLProtocol.reset()
    super.tearDown()
  }

  // MARK: Credentials

  func testCredentialsReadAccountAndRejectExpiredSignIn() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = Self.jwt(exp: now.addingTimeInterval(3_600), accountID: "account-from-claims")
    let fromClaims = try OpenAIDotCredentials.parse(
      authJSON: Self.authJSON(token: token, accountID: nil),
      now: now
    )
    XCTAssertEqual(fromClaims.accessToken, token)
    XCTAssertEqual(fromClaims.accountID, "account-from-claims")

    let explicit = try OpenAIDotCredentials.parse(
      authJSON: Self.authJSON(token: token, accountID: "account-explicit"),
      now: now
    )
    XCTAssertEqual(explicit.accountID, "account-explicit")

    let expired = Self.jwt(exp: now.addingTimeInterval(-1), accountID: "a")
    XCTAssertThrowsError(try OpenAIDotCredentials.parse(authJSON: Self.authJSON(token: expired, accountID: nil), now: now)) {
      XCTAssertEqual($0 as? OpenAIDotChatError, .signInExpired)
    }
    XCTAssertThrowsError(try OpenAIDotCredentials.parse(authJSON: Data(#"{"OPENAI_API_KEY":"x"}"#.utf8))) {
      XCTAssertEqual($0 as? OpenAIDotChatError, .notSignedIn)
    }
  }

  func testCodexAuthFileHonorsCodexHome() {
    let home = URL(fileURLWithPath: "/Users/example")
    XCTAssertEqual(
      OpenAIDotCredentials.codexAuthFileURL(environment: [:], homeDirectory: home).path,
      "/Users/example/.codex/auth.json"
    )
    XCTAssertEqual(
      OpenAIDotCredentials.codexAuthFileURL(environment: ["CODEX_HOME": "/tmp/codex-home"], homeDirectory: home).path,
      "/tmp/codex-home/auth.json"
    )
  }

  // MARK: Turns

  func testSendPostsToPrimaryDotAndCollectsRepliesUntilQuiet() async throws {
    let clock = TestClock()
    let polls = PollScript([
      // Another device's message from the same user is not a reply.
      [message("m2", member: selfMember, text: "sent from my phone"),
       message("m3", member: dotMember, text: "On it. See [the plan](https://example.test/plan).")],
      [message("m4", member: dotMember, text: "Done: three items checked.")],
    ])
    OpenAIDotTestURLProtocol.setHandler { request in
      let path = request.url?.path ?? ""
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-1")
      switch (request.httpMethod, path) {
      case ("GET", "/backend-api/cloud-aeons/primary"):
        return (200, self.primaryJSON())
      case ("POST", "/backend-api/messaging/rooms/room-juniper/messages"):
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual((body["content"] as? [String: Any])?["text"] as? String, "Check the three items")
        XCTAssertEqual(body["request_id"] as? String, "request-1")
        XCTAssertEqual(body["idempotency_token"] as? String, "request-1")
        XCTAssertNotNil(body["timezone_offset_min"] as? Int)
        return (200, self.message("m1", member: self.selfMember, text: "Check the three items"))
      case ("GET", "/backend-api/messaging/rooms/room-juniper/messages"):
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "limit" })?.value, "20")
        let after = query.first(where: { $0.name == "after" })?.value
        return (200, ["items": polls.next(after: after), "next_cursor": NSNull()])
      default:
        XCTFail("Unexpected request \(request.httpMethod ?? "") \(path)")
        return (404, [:])
      }
    }

    let streamed = StreamedMessages()
    let result = try await client(clock: clock).send(
      text: "  Check the three items  ",
      requestID: "request-1",
      onMessage: { await streamed.append($0.id) }
    )

    XCTAssertFalse(result.timedOut)
    XCTAssertEqual(result.dot.displayName, "Juniper")
    XCTAssertEqual(result.replies.map(\.id), ["m3", "m4"])
    let streamedIDs = await streamed.ids
    XCTAssertEqual(streamedIDs, ["m3", "m4"])
    XCTAssertEqual(
      result.transcriptText,
      "On it. See [[https://example.test/plan][the plan]].\n\nDone: three items checked."
    )
    XCTAssertEqual(polls.afterCursors.prefix(2), ["m1", "m3"])
    XCTAssertEqual(polls.afterCursors.dropFirst(2).first, "m4")
  }

  func testNoReplyEndsTurnWithDeliveredNote() async throws {
    let clock = TestClock()
    OpenAIDotTestURLProtocol.setHandler { request in
      switch (request.httpMethod, request.url?.path ?? "") {
      case ("GET", "/backend-api/cloud-aeons/primary"):
        return (200, self.primaryJSON())
      case ("POST", _):
        return (200, self.message("m1", member: self.selfMember, text: "hello"))
      default:
        return (200, ["items": [Any]()])
      }
    }
    let result = try await client(clock: clock, firstReplyTimeout: 30).send(text: "hello", requestID: "r")
    XCTAssertTrue(result.timedOut)
    XCTAssertTrue(result.replies.isEmpty)
    XCTAssertTrue(result.transcriptText.contains("Your message was delivered"))
  }

  func testTurnReportsPositionAndNextTurnResumesFromIt() async throws {
    let clock = TestClock()
    let polls = PollScript([
      [message("m5", member: dotMember, text: "Earlier result")],
    ])
    OpenAIDotTestURLProtocol.setHandler { request in
      switch (request.httpMethod, request.url?.path ?? "") {
      case ("GET", "/backend-api/cloud-aeons/primary"):
        return (200, self.primaryJSON())
      case ("POST", _):
        return (200, self.message("m6", member: self.selfMember, text: "Next question"))
      default:
        let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
          .queryItems?.first(where: { $0.name == "after" })?.value
        return (200, ["items": polls.next(after: after)])
      }
    }
    let previous = OpenAIDotRoomPosition(roomID: roomID, selfMemberID: selfMember, cursor: "m4")
    let result = try await client(clock: clock).send(
      text: "Next question",
      requestID: "r",
      resumingAfter: previous
    )
    // A message the dot sent between the watch ending and this turn is kept.
    XCTAssertEqual(polls.afterCursors.first, "m4")
    XCTAssertEqual(result.replies.map(\.id), ["m5"])
    XCTAssertEqual(result.position, OpenAIDotRoomPosition(roomID: roomID, selfMemberID: selfMember, cursor: "m5"))

    // A position from another room or account is ignored.
    polls.reset([])
    _ = try await client(clock: clock).send(
      text: "Next question",
      requestID: "r2",
      resumingAfter: OpenAIDotRoomPosition(roomID: "room-other", selfMemberID: selfMember, cursor: "x9")
    )
    XCTAssertEqual(polls.afterCursors.first, "m6")
  }

  func testFollowUpWatchDeliversLateRepliesAndRetriesBriefFailures() async throws {
    let clock = TestClock()
    let polls = PollScript([
      [],
      [],
      // The dot's result arrives minutes after its acknowledgement.
      [message("m4", member: dotMember, text: "Done. See [the report](https://example.test/r).")],
      [message("m5", member: selfMember, text: "thanks"), message("m6", member: dotMember, text: "One more note.")],
    ])
    let failures = FailureScript(remaining: 1)
    OpenAIDotTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.url?.path, "/backend-api/messaging/rooms/room-juniper/messages")
      if failures.take() { return (503, ["detail": "busy"]) }
      let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "after" })?.value
      return (200, ["items": polls.next(after: after)])
    }
    let streamed = StreamedMessages()
    let positions = StreamedMessages()
    let start = OpenAIDotRoomPosition(roomID: roomID, selfMemberID: selfMember, cursor: "m3")
    let final = try await client(clock: clock, followUpWindow: 600).watchFollowUps(from: start) { message, position in
      await streamed.append(OpenAIDotTurnResult.followUpText(message))
      await positions.append(position.cursor)
    }
    let texts = await streamed.ids
    XCTAssertEqual(texts, ["Done. See [[https://example.test/r][the report]].", "One more note."])
    let cursors = await positions.ids
    XCTAssertEqual(cursors, ["m4", "m6"])
    XCTAssertEqual(final.cursor, "m6")
    XCTAssertEqual(polls.afterCursors.prefix(4), ["m3", "m3", "m3", "m4"])
    XCTAssertEqual(polls.afterCursors.last, "m6")
  }

  func testFollowUpWatchStopsOnPermanentFailureAndCancellation() async throws {
    OpenAIDotTestURLProtocol.setHandler { _ in (401, ["detail": "expired"]) }
    let start = OpenAIDotRoomPosition(roomID: roomID, selfMemberID: selfMember, cursor: "m1")
    do {
      _ = try await client().watchFollowUps(from: start) { _, _ in }
      XCTFail("A rejected sign-in must end the watch")
    } catch {
      XCTAssertEqual(error as? OpenAIDotChatError, .http(status: 401, detail: "expired"))
    }
    XCTAssertTrue(OpenAIDotChatError.transport("offline").isTransient)
    XCTAssertTrue(OpenAIDotChatError.http(status: 429, detail: nil).isTransient)
    XCTAssertFalse(OpenAIDotChatError.http(status: 404, detail: nil).isTransient)

    OpenAIDotTestURLProtocol.setHandler { _ in (200, ["items": [Any]()]) }
    let watcher = client(followUpWindow: 3_600)
    let task = Task { try await watcher.watchFollowUps(from: start) { _, _ in } }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("A cancelled watch must stop")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  @MainActor
  func testFollowUpReplyJoinsTheLiveEndOnceAndRespectsStop() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-dot-follow-up-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "OpenAIDot.FollowUp.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = root.appendingPathComponent("chat.json")
    let store = WorkspaceStore(defaults: defaults, aiChatTranscriptURL: transcriptURL, legacyDefaultsDomains: [])
    store.setCorpusRoot(root, persistsDefault: false)
    let threadID = store.createAIChatThread(runtime: .openClaw)
    let queued = AIChatMessage(role: .user, content: "Queued question", deliveryStatus: .sending)
    store.updateAIChatThread(
      threadID,
      messages: [
        AIChatMessage(role: .user, content: "Check the three items"),
        AIChatMessage(role: .assistant, content: "On it, taking a look."),
        queued,
      ],
      transcriptURL: transcriptURL,
      shouldPersist: true
    )

    let replyID = WorkspaceStore.openAIDotFollowUpReplyID(destinationID: "dot-juniper", messageID: "m4")
    XCTAssertEqual(replyID, WorkspaceStore.openAIDotFollowUpReplyID(destinationID: "dot-juniper", messageID: "m4"))
    XCTAssertNotEqual(replyID, WorkspaceStore.openAIDotFollowUpReplyID(destinationID: "dot-juniper", messageID: "m5"))
    XCTAssertTrue(store.appendAIChatFollowUpReply(
      "Done: three items checked.",
      replyID: replyID,
      in: threadID,
      transcriptURL: transcriptURL
    ))
    XCTAssertFalse(store.appendAIChatFollowUpReply(
      "Done: three items checked.",
      replyID: replyID,
      in: threadID,
      transcriptURL: transcriptURL
    ))
    let messages = store.aiChatMessages(for: threadID, transcriptURL: transcriptURL)
    XCTAssertEqual(
      messages.map(\.content),
      ["Check the three items", "On it, taking a look.", "Done: three items checked.", "Queued question"]
    )
    XCTAssertEqual(messages[2].id, replyID)
    XCTAssertEqual(messages[2].role, .assistant)
    XCTAssertEqual(messages[3].deliveryStatus, .sending)

    store.markAIChatRunStopped(in: threadID, transcriptURL: transcriptURL)
    XCTAssertFalse(store.appendAIChatFollowUpReply(
      "A late note",
      replyID: UUID(),
      in: threadID,
      transcriptURL: transcriptURL
    ))
  }

  func testNamedDotAndPausedDotResolution() async throws {
    OpenAIDotTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.path, "/backend-api/cloud-aeons")
      return (200, ["items": [
        ["id": "dot-a", "display_name": "Juniper", "messaging_room_id": "room-a", "is_paused": false],
        ["id": "dot-b", "display_name": "Basil", "messaging_room_id": "room-b", "is_paused": true],
      ]])
    }
    let named = try await client(selector: "juniper").resolveDot()
    XCTAssertEqual(named.id, "dot-a")
    let byID = try await client(selector: "dot-a").resolveDot()
    XCTAssertEqual(byID.messagingRoomID, "room-a")
    do {
      _ = try await client(selector: "Basil").resolveDot()
      XCTFail("A paused dot must not receive messages")
    } catch {
      XCTAssertEqual(error as? OpenAIDotChatError, .dotPaused("Basil"))
    }
    do {
      _ = try await client(selector: "Rosemary").resolveDot()
      XCTFail("An unknown dot must fail")
    } catch {
      XCTAssertEqual(error as? OpenAIDotChatError, .dotNotFound("Rosemary"))
    }
  }

  func testEmptyMessageIsRejectedBeforeAnyRequest() async {
    OpenAIDotTestURLProtocol.setHandler { _ in
      XCTFail("No request should be made for an empty message")
      return (500, [:])
    }
    do {
      _ = try await client().send(text: " \n ", requestID: "r")
      XCTFail("Expected an empty-message error")
    } catch {
      XCTAssertEqual(error as? OpenAIDotChatError, .emptyMessage)
    }
    XCTAssertTrue(OpenAIDotTestURLProtocol.requests.isEmpty)
  }

  func testHTTPErrorsBecomeReadableMessages() async {
    OpenAIDotTestURLProtocol.setHandler { _ in
      (422, ["detail": [["msg": "Input should be less than or equal to 32"]]])
    }
    do {
      _ = try await client().resolveDot()
      XCTFail("Expected an HTTP error")
    } catch {
      XCTAssertEqual(
        error as? OpenAIDotChatError,
        .http(status: 422, detail: "Input should be less than or equal to 32")
      )
    }
    XCTAssertEqual(
      OpenAIDotChatClient.errorDetail(data: Data("<html></html>".utf8), contentType: "text/html"),
      "ChatGPT returned a web page instead of data"
    )
    XCTAssertTrue(
      OpenAIDotChatError.http(status: 401, detail: nil).errorDescription?.contains("Sign in to Codex again") == true
    )
  }

  func testSettingsRequireHTTPSAndDefaultToChatGPT() throws {
    XCTAssertEqual(
      try OpenAIDotChatClient.Settings(endpoint: "", dotSelector: " ").baseURL.absoluteString,
      "https://chatgpt.com/backend-api"
    )
    XCTAssertThrowsError(try OpenAIDotChatClient.Settings(endpoint: "http://example.test", dotSelector: ""))
  }

  func testDestinationAdapterMetadata() {
    let adapter = AIChatDestinationAdapter.openAIDot
    XCTAssertEqual(adapter.title, "OpenAI Dot")
    XCTAssertEqual(adapter.defaultMention, "dot")
    XCTAssertFalse(adapter.isDirectProvider)
    XCTAssertFalse(adapter.requiresAPIKey)
    let destination = AIChatDestinationConfiguration(name: "Juniper", mention: "juniper", adapter: adapter)
    XCTAssertFalse(destination.requiresEndpoint)
    XCTAssertFalse(destination.acceptsBearerToken)
    XCTAssertNil(destination.harnessHostName)
  }

  func testOrgLinkRewriteLeavesImagesAndPlainTextAlone() {
    XCTAssertEqual(
      OpenAIDotTurnResult.orgLinks("See [docs](https://example.test/a) and ![chart](https://example.test/c.png)."),
      "See [[https://example.test/a][docs]] and ![chart](https://example.test/c.png)."
    )
    XCTAssertEqual(OpenAIDotTurnResult.orgLinks("no links [here]"), "no links [here]")
  }

  // MARK: Helpers

  private func client(
    clock: TestClock = TestClock(),
    selector: String = "",
    firstReplyTimeout: TimeInterval = 600,
    followUpWindow: TimeInterval = 60
  ) -> OpenAIDotChatClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAIDotTestURLProtocol.self]
    return OpenAIDotChatClient(
      settings: try! OpenAIDotChatClient.Settings(endpoint: "", dotSelector: selector),
      timing: OpenAIDotChatClient.Timing(
        pollInterval: 2,
        settleInterval: 6,
        firstReplyTimeout: firstReplyTimeout,
        followUpPollInterval: 5,
        followUpMaxPollInterval: 30,
        followUpWindow: followUpWindow
      ),
      session: URLSession(configuration: configuration),
      credentials: { OpenAIDotCredentials(accessToken: "test-token", accountID: "account-1", expiresAt: nil) },
      clock: { clock.now },
      sleep: { clock.advance($0) }
    )
  }

  private func primaryJSON() -> [String: Any] {
    [
      "selection": ["available": true, "messaging_room_id": roomID],
      "profile": ["id": "dot-juniper", "display_name": "Juniper", "messaging_room_id": roomID, "is_paused": false],
    ]
  }

  private func message(_ id: String, member: String, text: String) -> [String: Any] {
    [
      "id": id,
      "account_user_id": member,
      "role": "user",
      "content": ["text": text, "attachments": [Any]()],
      "deleted_at": NSNull(),
    ]
  }

  private static func authJSON(token: String, accountID: String?) -> Data {
    var tokens: [String: Any] = ["access_token": token, "refresh_token": "unused"]
    if let accountID { tokens["account_id"] = accountID }
    return try! JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": tokens])
  }

  private static func jwt(exp: Date, accountID: String) -> String {
    let claims: [String: Any] = [
      "exp": Int(exp.timeIntervalSince1970),
      "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
    ]
    func encode(_ object: Any) -> String {
      try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(["alg": "none"])).\(encode(claims)).signature"
  }
}

private final class PollScript: @unchecked Sendable {
  private let lock = NSLock()
  private var pages: [[[String: Any]]]
  private var cursors: [String?] = []

  init(_ pages: [[[String: Any]]]) { self.pages = pages }

  func next(after: String?) -> [[String: Any]] {
    lock.withLock {
      cursors.append(after)
      return pages.isEmpty ? [] : pages.removeFirst()
    }
  }

  var afterCursors: [String?] { lock.withLock { cursors } }

  func reset(_ pages: [[[String: Any]]]) {
    lock.withLock {
      self.pages = pages
      cursors = []
    }
  }
}

private final class FailureScript: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining: Int

  init(remaining: Int) { self.remaining = remaining }

  /// Returns true while scripted failures remain.
  func take() -> Bool {
    lock.withLock {
      guard remaining > 0 else { return false }
      remaining -= 1
      return true
    }
  }
}

private actor StreamedMessages {
  private(set) var ids: [String] = []
  func append(_ id: String) { ids.append(id) }
}
