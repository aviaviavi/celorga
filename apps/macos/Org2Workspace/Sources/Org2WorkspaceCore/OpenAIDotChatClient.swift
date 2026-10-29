import Foundation

/// Messages an OpenAI dot (the always-on ChatGPT agent) through the same
/// ChatGPT messaging room the ChatGPT apps use.
///
/// OpenAI does not publish an API for dots. This client uses the private
/// ChatGPT backend routes that the ChatGPT desktop app calls, authenticated
/// with the ChatGPT sign-in that Codex already stores. Those routes can change
/// without notice, so every unexpected response becomes a readable error
/// rather than a silent failure.
public struct OpenAIDotChatClient: Sendable {
  public static let defaultBaseURL = "https://chatgpt.com/backend-api"

  public struct Settings: Sendable, Equatable {
    public let baseURL: URL
    /// A dot ID or display name. Empty selects the account's primary dot.
    public let dotSelector: String

    public init(endpoint: String, dotSelector: String) throws {
      let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
      let raw = trimmed.isEmpty ? OpenAIDotChatClient.defaultBaseURL : trimmed
      guard let url = URL(string: raw),
            url.scheme?.lowercased() == "https",
            url.host != nil
      else {
        throw OpenAIDotChatError.invalidEndpoint(raw)
      }
      self.baseURL = url
      self.dotSelector = dotSelector.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  public struct Timing: Sendable, Equatable {
    public var pollInterval: TimeInterval
    /// How long the dot must stay quiet after its latest message before the
    /// turn is considered finished.
    public var settleInterval: TimeInterval
    /// How long to wait for the dot's first reply before ending the turn.
    public var firstReplyTimeout: TimeInterval
    /// After a turn ends, how often to check for later messages. The check
    /// slows from the first interval to the second while the dot is quiet.
    public var followUpPollInterval: TimeInterval
    public var followUpMaxPollInterval: TimeInterval
    /// How long to keep checking for later messages after the dot's latest one.
    public var followUpWindow: TimeInterval

    public init(
      pollInterval: TimeInterval = 2,
      settleInterval: TimeInterval = 10,
      firstReplyTimeout: TimeInterval = 15 * 60,
      followUpPollInterval: TimeInterval = 5,
      followUpMaxPollInterval: TimeInterval = 30,
      followUpWindow: TimeInterval = 3 * 60 * 60
    ) {
      self.pollInterval = pollInterval
      self.settleInterval = settleInterval
      self.firstReplyTimeout = firstReplyTimeout
      self.followUpPollInterval = followUpPollInterval
      self.followUpMaxPollInterval = max(followUpPollInterval, followUpMaxPollInterval)
      self.followUpWindow = followUpWindow
    }
  }

  public let settings: Settings
  public let timing: Timing
  private let session: URLSession
  private let credentials: @Sendable () throws -> OpenAIDotCredentials
  private let clock: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  public init(
    settings: Settings,
    timing: Timing = Timing(),
    session: URLSession = .shared,
    credentials: @escaping @Sendable () throws -> OpenAIDotCredentials = {
      try OpenAIDotCredentials.loadFromCodex()
    },
    clock: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
  ) {
    self.settings = settings
    self.timing = timing
    self.session = session
    self.credentials = credentials
    self.clock = clock
    self.sleep = sleep
  }

  // MARK: Dots

  /// Lists the dots on the signed-in ChatGPT account.
  public func listDots() async throws -> [OpenAIDotProfile] {
    let object = try await requestJSON("GET", path: "/cloud-aeons")
    let rows = object["items"] as? [[String: Any]] ?? []
    return rows.compactMap(OpenAIDotProfile.init(json:))
  }

  /// Resolves the configured dot, or the primary dot when none is configured.
  public func resolveDot() async throws -> OpenAIDotProfile {
    let selector = settings.dotSelector
    let profile: OpenAIDotProfile?
    if selector.isEmpty {
      let object = try await requestJSON("GET", path: "/cloud-aeons/primary")
      profile = OpenAIDotProfile(primaryJSON: object)
    } else {
      let dots = try await listDots()
      profile = dots.first(where: { $0.id == selector })
        ?? dots.first(where: {
          $0.displayName.compare(selector, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        })
      if profile == nil {
        throw OpenAIDotChatError.dotNotFound(selector)
      }
    }
    guard let profile else { throw OpenAIDotChatError.noPrimaryDot }
    guard !profile.isPaused else { throw OpenAIDotChatError.dotPaused(profile.displayName) }
    guard profile.messagingRoomID?.isEmpty == false else {
      throw OpenAIDotChatError.noMessagingRoom(profile.displayName)
    }
    return profile
  }

  // MARK: Turns

  /// Sends one message to the dot and waits for its reply.
  ///
  /// The dot can answer with several messages. Each is reported through
  /// `onMessage` as it arrives, and the turn finishes once the dot has been
  /// quiet for `timing.settleInterval`. If the dot does not answer within
  /// `timing.firstReplyTimeout`, the turn ends with `timedOut` set; the message
  /// was still delivered, so callers must not resend it.
  ///
  /// Pass the position an earlier turn or follow-up watch reached as
  /// `resumingAfter` so messages the dot sent in between are not skipped.
  ///
  /// `replyTo` sends the message as a reply to an earlier message, the way
  /// ChatGPT's Reply action does; the dot then answers in that reply thread,
  /// so its answers name the message they answer. If ChatGPT rejects the
  /// reply target, the message is sent without it.
  ///
  /// `onSent` reports the posted message, and whether it went out as a
  /// reply, before any reply is read. `accept`
  /// decides whether a new message from the dot belongs to this turn; one it
  /// declines is left out of the turn, for example because it answers
  /// another chat's message.
  public func send(
    text: String,
    requestID: String,
    replyTo replyToMessageID: String? = nil,
    resumingAfter previous: OpenAIDotRoomPosition? = nil,
    onSent: (@Sendable (OpenAIDotMessage, _ isReply: Bool) async -> Void)? = nil,
    accept: (@Sendable (OpenAIDotMessage) async -> Bool)? = nil,
    onMessage: (@Sendable (OpenAIDotMessage) async -> Void)? = nil
  ) async throws -> OpenAIDotTurnResult {
    let posted = try await post(text: text, requestID: requestID, replyTo: replyToMessageID)
    let dot = posted.dot
    let sent = posted.sent
    let roomID = dot.messagingRoomID ?? ""
    let roomPath = "/messaging/rooms/\(Self.pathComponent(roomID))"
    await onSent?(sent, posted.isReply)

    let resumeCursor = previous.flatMap {
      $0.roomID == roomID && $0.selfMemberID == sent.memberID ? $0.cursor : nil
    }
    var tracker = OpenAIDotReplyTracker(
      selfMemberID: sent.memberID,
      cursor: resumeCursor ?? sent.id,
      startedAt: clock(),
      timing: timing
    )
    while true {
      try Task.checkCancellation()
      try await sleep(timing.pollInterval)
      try Task.checkCancellation()
      try await readNewMessages(roomPath: roomPath, tracker: &tracker, accept: accept, onMessage: onMessage)
      let timedOut: Bool
      switch tracker.state(at: clock()) {
      case .waiting:
        continue
      case .settled:
        timedOut = false
      case .timedOut:
        timedOut = true
      }
      return OpenAIDotTurnResult(
        dot: dot,
        sentMessageID: sent.id,
        replies: tracker.replies,
        timedOut: timedOut,
        position: OpenAIDotRoomPosition(roomID: roomID, selfMemberID: sent.memberID, cursor: tracker.cursor)
      )
    }
  }

  /// Posts one message to the dot without waiting for a reply.
  ///
  /// `replyTo` sends it as a reply to an earlier message; if ChatGPT rejects
  /// that target, the message is sent without it and `isReply` is false.
  public func post(
    text: String,
    requestID: String,
    replyTo replyToMessageID: String? = nil
  ) async throws -> (dot: OpenAIDotProfile, sent: OpenAIDotMessage, isReply: Bool) {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw OpenAIDotChatError.emptyMessage }
    let dot = try await resolveDot()
    let roomPath = "/messaging/rooms/\(Self.pathComponent(dot.messagingRoomID ?? ""))"
    let replyTo = replyToMessageID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sentObject: [String: Any]
    var sentAsReply = replyTo?.isEmpty == false
    do {
      sentObject = try await requestJSON(
        "POST",
        path: "\(roomPath)/messages",
        body: Self.sendBody(text: body, requestID: requestID, timeZone: .current, now: clock(), replyTo: replyTo)
      )
    } catch let error as OpenAIDotChatError where replyTo?.isEmpty == false && error.rejectsReplyTarget {
      // The earlier message may have been deleted. The rejected request
      // created nothing, so the same request ID is still safe to reuse.
      sentAsReply = false
      sentObject = try await requestJSON(
        "POST",
        path: "\(roomPath)/messages",
        body: Self.sendBody(text: body, requestID: requestID, timeZone: .current, now: clock())
      )
    }
    guard let sent = OpenAIDotMessage(json: sentObject) else {
      throw OpenAIDotChatError.invalidResponse("the sent message had no ID")
    }
    return (dot, sent, sentAsReply)
  }

  // MARK: Conversation history

  /// Resolves the dot and its conversation, including which member is the
  /// signed-in user, so every message can be attributed without sending one.
  public func resolveRoom() async throws -> OpenAIDotRoom {
    let dot = try await resolveDot()
    let roomID = dot.messagingRoomID ?? ""
    let object = try await requestJSON("GET", path: "/messaging/rooms/\(Self.pathComponent(roomID))")
    let members = object["members"] as? [[String: Any]] ?? []
    // The dot's member carries its agent ID; the person's does not.
    let person = members.first { member in
      let aeonID = (member["aeon_id"] as? String) ?? ""
      return aeonID.isEmpty && (member["account_user_id"] as? String)?.isEmpty == false
    }
    guard let selfMemberID = (person?["account_user_id"] as? String)
      ?? (object["creator_account_user_id"] as? String),
      !selfMemberID.isEmpty
    else {
      throw OpenAIDotChatError.invalidResponse("the conversation lists no signed-in member")
    }
    return OpenAIDotRoom(dot: dot, roomID: roomID, selfMemberID: selfMemberID)
  }

  /// Reads up to `limit` of the newest messages, oldest first. Returns fewer
  /// when the conversation is shorter.
  public func latestMessages(roomID: String, limit: Int) async throws -> OpenAIDotHistoryPage {
    try await messages(roomID: roomID, before: nil, limit: limit)
  }

  /// Reads up to `limit` messages older than `before` (or the newest when
  /// nil), oldest first. `reachedStart` is true once the first message of the
  /// conversation is included.
  public func messages(roomID: String, before: String?, limit: Int) async throws -> OpenAIDotHistoryPage {
    let roomPath = "/messaging/rooms/\(Self.pathComponent(roomID))"
    var collected: [OpenAIDotMessage] = []
    var cursor = before
    var reachedStart = false
    while collected.count < limit {
      var query = [URLQueryItem(name: "limit", value: String(min(Self.historyPageSize, limit - collected.count)))]
      if let cursor { query.append(URLQueryItem(name: "before", value: cursor)) }
      let page = try await requestJSON("GET", path: "\(roomPath)/messages", query: query)
      let items = (page["items"] as? [[String: Any]] ?? []).compactMap(OpenAIDotMessage.init(json:))
      let requested = min(Self.historyPageSize, limit - collected.count)
      // Pages are oldest first. A page that does not move the cursor would
      // loop forever, so it also counts as the start.
      guard let oldest = items.first, oldest.id != cursor else {
        reachedStart = true
        break
      }
      collected.insert(contentsOf: items.filter { $0.id != cursor }, at: 0)
      cursor = oldest.id
      if items.count < requested {
        reachedStart = true
        break
      }
    }
    return OpenAIDotHistoryPage(messages: collected, reachedStart: reachedStart)
  }

  /// Reads messages newer than `after`, oldest first, at most `maxPages`
  /// pages at a time. `hasMore` means more are waiting; call again from the
  /// returned cursor.
  public func messages(
    roomID: String,
    after: String,
    maxPages: Int = 25
  ) async throws -> (messages: [OpenAIDotMessage], cursor: String, hasMore: Bool) {
    let roomPath = "/messaging/rooms/\(Self.pathComponent(roomID))"
    var collected: [OpenAIDotMessage] = []
    var cursor = after
    for _ in 0..<max(1, maxPages) {
      let page = try await requestJSON(
        "GET",
        path: "\(roomPath)/messages",
        query: [
          URLQueryItem(name: "after", value: cursor),
          URLQueryItem(name: "limit", value: String(Self.historyPageSize)),
        ]
      )
      let items = (page["items"] as? [[String: Any]] ?? [])
        .compactMap(OpenAIDotMessage.init(json:))
        .filter { $0.id != cursor }
      guard let newest = items.last else {
        return (collected, cursor, false)
      }
      collected += items
      cursor = newest.id
      if items.count < Self.historyPageSize {
        return (collected, cursor, false)
      }
    }
    return (collected, cursor, true)
  }

  /// ChatGPT's largest accepted page.
  static let historyPageSize = 32

  /// Keeps reading the dot's conversation after a turn has ended.
  ///
  /// A dot often acknowledges a request ("I'm taking a look"), keeps working,
  /// and posts its result minutes later from a scheduled wake-up. Each later
  /// message is reported through `onMessage` with the position after it. The
  /// watch checks less often while the dot is quiet and returns the final
  /// position once `timing.followUpWindow` passes without a new message.
  /// Brief network or server failures are retried; cancel the task to stop.
  public func watchFollowUps(
    from position: OpenAIDotRoomPosition,
    onMessage: @escaping @Sendable (OpenAIDotMessage, OpenAIDotRoomPosition) async -> Void
  ) async throws -> OpenAIDotRoomPosition {
    let roomPath = "/messaging/rooms/\(Self.pathComponent(position.roomID))"
    var tracker = OpenAIDotReplyTracker(
      selfMemberID: position.selfMemberID,
      cursor: position.cursor,
      startedAt: clock(),
      timing: timing
    )
    var lastActivityAt = clock()
    var interval = timing.followUpPollInterval
    while clock().timeIntervalSince(lastActivityAt) < timing.followUpWindow {
      try Task.checkCancellation()
      try await sleep(interval)
      try Task.checkCancellation()
      let before = tracker.replies.count
      do {
        try await readNewMessages(roomPath: roomPath, tracker: &tracker, accept: nil) { message in
          await onMessage(message, OpenAIDotRoomPosition(
            roomID: position.roomID,
            selfMemberID: position.selfMemberID,
            cursor: message.id
          ))
        }
      } catch let error as OpenAIDotChatError where error.isTransient {
        interval = min(timing.followUpMaxPollInterval, interval * 2)
        continue
      }
      if tracker.replies.count > before {
        lastActivityAt = clock()
        interval = timing.followUpPollInterval
      } else {
        interval = min(timing.followUpMaxPollInterval, interval * 1.5)
      }
    }
    return OpenAIDotRoomPosition(
      roomID: position.roomID,
      selfMemberID: position.selfMemberID,
      cursor: tracker.cursor
    )
  }

  /// Reads every message after the tracker's cursor, one page at a time,
  /// and records the dot's messages that `accept` keeps.
  private func readNewMessages(
    roomPath: String,
    tracker: inout OpenAIDotReplyTracker,
    accept: (@Sendable (OpenAIDotMessage) async -> Bool)?,
    onMessage: (@Sendable (OpenAIDotMessage) async -> Void)?
  ) async throws {
    var pageFull = true
    while pageFull {
      let page = try await requestJSON(
        "GET",
        path: "\(roomPath)/messages",
        query: [
          URLQueryItem(name: "after", value: tracker.cursor),
          URLQueryItem(name: "limit", value: String(Self.pageSize)),
        ]
      )
      let items = (page["items"] as? [[String: Any]] ?? []).compactMap(OpenAIDotMessage.init(json:))
      var replies: [OpenAIDotMessage] = []
      for message in tracker.ingest(items) {
        if let accept, !(await accept(message)) { continue }
        replies.append(message)
      }
      tracker.record(replies, at: clock())
      for reply in replies {
        await onMessage?(reply)
      }
      pageFull = items.count >= Self.pageSize
    }
  }

  /// ChatGPT rejects pages larger than 32 messages.
  static let pageSize = 20

  static func sendBody(
    text: String,
    requestID: String,
    timeZone: TimeZone,
    now: Date,
    replyTo: String? = nil
  ) -> [String: Any] {
    var body: [String: Any] = [
      "content": ["text": text, "attachments": [Any]()],
      "request_id": requestID,
      "idempotency_token": requestID,
      // Matches JavaScript's Date#getTimezoneOffset: minutes behind UTC.
      "timezone_offset_min": -timeZone.secondsFromGMT(for: now) / 60,
    ]
    if let replyTo, !replyTo.isEmpty {
      body["reply_to"] = ["message_id": replyTo]
    }
    return body
  }

  static func pathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  // MARK: HTTP

  private func requestJSON(
    _ method: String,
    path: String,
    query: [URLQueryItem] = [],
    body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    let credentials = try credentials()
    let base = settings.baseURL.absoluteString.hasSuffix("/")
      ? String(settings.baseURL.absoluteString.dropLast())
      : settings.baseURL.absoluteString
    guard var components = URLComponents(string: base + path) else {
      throw OpenAIDotChatError.invalidEndpoint(base + path)
    }
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url else { throw OpenAIDotChatError.invalidEndpoint(base + path) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 60
    request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
    if let accountID = credentials.accountID {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw OpenAIDotChatError.transport(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw OpenAIDotChatError.invalidResponse("no HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw OpenAIDotChatError.http(
        status: http.statusCode,
        detail: Self.errorDetail(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
      )
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OpenAIDotChatError.invalidResponse("ChatGPT returned something other than JSON")
    }
    return object
  }

  static func errorDetail(data: Data, contentType: String?) -> String? {
    if contentType?.lowercased().contains("html") == true {
      return "ChatGPT returned a web page instead of data"
    }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let detail = object["detail"] as? String { return detail }
      if let details = object["detail"] as? [[String: Any]] {
        let messages = details.compactMap { $0["msg"] as? String }
        if !messages.isEmpty { return messages.joined(separator: "; ") }
      }
      if let detail = (object["detail"] as? [String: Any])?["message"] as? String { return detail }
      if let message = (object["error"] as? [String: Any])?["message"] as? String { return message }
      if let message = object["message"] as? String { return message }
    }
    let text = String(data: data.prefix(300), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? text : nil
  }
}

// MARK: - Models

public struct OpenAIDotProfile: Sendable, Equatable {
  public let id: String
  public let displayName: String
  public let messagingRoomID: String?
  public let isPaused: Bool

  public init(id: String, displayName: String, messagingRoomID: String?, isPaused: Bool) {
    self.id = id
    self.displayName = displayName
    self.messagingRoomID = messagingRoomID
    self.isPaused = isPaused
  }

  init?(json: [String: Any]) {
    guard let id = json["id"] as? String, !id.isEmpty else { return nil }
    let name = (json["display_name"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.init(
      id: id,
      displayName: name.isEmpty ? "Dot" : name,
      messagingRoomID: json["messaging_room_id"] as? String,
      isPaused: json["is_paused"] as? Bool ?? false
    )
  }

  /// Parses `/cloud-aeons/primary`, which pairs a selection with a profile.
  init?(primaryJSON json: [String: Any]) {
    let selection = json["selection"] as? [String: Any]
    if let available = selection?["available"] as? Bool, !available { return nil }
    guard let profileJSON = json["profile"] as? [String: Any],
          let profile = OpenAIDotProfile(json: profileJSON)
    else { return nil }
    self.init(
      id: profile.id,
      displayName: profile.displayName,
      messagingRoomID: profile.messagingRoomID ?? selection?["messaging_room_id"] as? String,
      isPaused: profile.isPaused
    )
  }
}

public struct OpenAIDotMessage: Sendable, Equatable {
  public let id: String
  public let memberID: String
  public let text: String
  public let isDeleted: Bool
  /// The message this one answers, when it was sent as a reply.
  public let replyTo: OpenAIDotReplyTarget?
  public let createdAt: Date?
  /// The client request ID. Messages Celorga sends carry the Celorga
  /// message ID here.
  public let requestID: String?
  public let attachments: [OpenAIDotAttachment]

  public init(
    id: String,
    memberID: String,
    text: String,
    isDeleted: Bool = false,
    replyTo: OpenAIDotReplyTarget? = nil,
    createdAt: Date? = nil,
    requestID: String? = nil,
    attachments: [OpenAIDotAttachment] = []
  ) {
    self.id = id
    self.memberID = memberID
    self.text = text
    self.isDeleted = isDeleted
    self.replyTo = replyTo
    self.createdAt = createdAt
    self.requestID = requestID
    self.attachments = attachments
  }

  init?(json: [String: Any]) {
    guard let id = json["id"] as? String, !id.isEmpty else { return nil }
    let content = json["content"] as? [String: Any]
    let deleted = json["deleted_at"].map { !($0 is NSNull) } ?? false
    let requestID = (json["request_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.init(
      id: id,
      memberID: json["account_user_id"] as? String ?? "",
      text: content?["text"] as? String ?? "",
      isDeleted: deleted,
      replyTo: (json["reply_to"] as? [String: Any]).flatMap(OpenAIDotReplyTarget.init(json:)),
      createdAt: (json["created_at"] as? String).flatMap(Self.timestamp),
      requestID: requestID?.isEmpty == false ? requestID : nil,
      attachments: (content?["attachments"] as? [[String: Any]] ?? []).compactMap(OpenAIDotAttachment.init(json:))
    )
  }

  /// Parses ChatGPT's ISO 8601 timestamps, which carry microseconds.
  static func timestamp(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // Foundation's parser reliably reads at most millisecond precision.
    let normalized = trimmed.replacingOccurrences(
      of: #"(\.\d{3})\d+"#,
      with: "$1",
      options: .regularExpression
    )
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: normalized) { return date }
    return ISO8601DateFormatter().date(from: normalized)
  }

  /// Whether the message has anything to show: text or an attachment.
  public var hasVisibleContent: Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
  }
}

/// A non-text item in a dot message, such as a voice call or a file.
/// Celorga shows a short description; the item itself stays in ChatGPT.
public struct OpenAIDotAttachment: Sendable, Equatable {
  public let type: String
  public let name: String?
  public let durationMilliseconds: Int?

  public init(type: String, name: String? = nil, durationMilliseconds: Int? = nil) {
    self.type = type
    self.name = name
    self.durationMilliseconds = durationMilliseconds
  }

  init?(json: [String: Any]) {
    let type = (json["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = ["file_name", "name", "title", "filename"]
      .lazy
      .compactMap { (json[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
    guard !type.isEmpty || name != nil else { return nil }
    self.init(
      type: type.isEmpty ? "file" : type,
      name: name,
      durationMilliseconds: (json["duration_ms"] as? NSNumber)?.intValue
    )
  }

  /// A one-line Org description, for example =/Call · 6 min/=.
  public var summary: String {
    if type == "call" {
      let minutes = durationMilliseconds.map { max(1, Int(($0 + 30_000) / 60_000)) }
      return "/Call\(minutes.map { " · \($0) min" } ?? "")/"
    }
    if let name { return "/Attachment: \(name)/" }
    return "/\(type.prefix(1).uppercased() + type.dropFirst()) attachment/"
  }
}

/// The earlier message a reply answers. ChatGPT includes a copy of it, so a
/// reply to a message Celorga sent carries that message's request ID, which
/// is the Celorga message ID.
public struct OpenAIDotReplyTarget: Sendable, Equatable {
  public let messageID: String
  public let memberID: String?
  public let requestID: String?

  public init(messageID: String, memberID: String? = nil, requestID: String? = nil) {
    self.messageID = messageID
    self.memberID = memberID
    self.requestID = requestID
  }

  init?(json: [String: Any]) {
    let message = json["message"] as? [String: Any]
    guard let id = (json["message_id"] as? String) ?? (message?["id"] as? String), !id.isEmpty else {
      return nil
    }
    func nonEmpty(_ value: Any?) -> String? {
      (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    self.init(
      messageID: id,
      memberID: nonEmpty(message?["account_user_id"]),
      requestID: nonEmpty(message?["request_id"])
    )
  }
}

/// A dot's ChatGPT conversation and the signed-in user's place in it.
public struct OpenAIDotRoom: Sendable, Equatable {
  public let dot: OpenAIDotProfile
  public let roomID: String
  /// The signed-in user's member ID; every other member is the dot.
  public let selfMemberID: String

  public init(dot: OpenAIDotProfile, roomID: String, selfMemberID: String) {
    self.dot = dot
    self.roomID = roomID
    self.selfMemberID = selfMemberID
  }
}

/// A run of consecutive messages, oldest first.
public struct OpenAIDotHistoryPage: Sendable, Equatable {
  public let messages: [OpenAIDotMessage]
  /// True when the run begins with the conversation's first message.
  public let reachedStart: Bool

  public init(messages: [OpenAIDotMessage], reachedStart: Bool) {
    self.messages = messages
    self.reachedStart = reachedStart
  }
}

/// The last message read in a dot's conversation, so a later read can
/// continue from it.
public struct OpenAIDotRoomPosition: Sendable, Equatable {
  public let roomID: String
  /// The signed-in user's member ID; their own messages are never replies.
  public let selfMemberID: String
  public let cursor: String

  public init(roomID: String, selfMemberID: String, cursor: String) {
    self.roomID = roomID
    self.selfMemberID = selfMemberID
    self.cursor = cursor
  }
}

public struct OpenAIDotTurnResult: Sendable, Equatable {
  public let dot: OpenAIDotProfile
  public let sentMessageID: String
  public let replies: [OpenAIDotMessage]
  public let timedOut: Bool
  /// Where the turn stopped reading; later replies follow this position.
  public let position: OpenAIDotRoomPosition

  /// The reply text for the chat transcript.
  public var transcriptText: String {
    let body = replies
      .map { Self.orgLinks($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    if timedOut {
      let note = "/\(dot.displayName) hasn't replied yet. Your message was delivered; Celorga adds later replies here while it's open, and they always appear in \(dot.displayName)'s ChatGPT conversation./"
      return body.isEmpty ? note : body + "\n\n" + note
    }
    return body
  }
}

extension OpenAIDotTurnResult {
  /// Transcript text for one message the dot sent after its turn ended.
  public static func followUpText(_ message: OpenAIDotMessage) -> String {
    orgLinks(message.text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static let markdownLink = try! NSRegularExpression(
    pattern: #"(?<!!)\[([^\]\n]+)\]\((https?://[^\s)]+)\)"#
  )

  /// Dots write Markdown; rewrite its links as Org links so they stay
  /// clickable in the transcript. Other Markdown is left as written.
  static func orgLinks(_ text: String) -> String {
    let range = NSRange(text.startIndex..., in: text)
    return markdownLink.stringByReplacingMatches(
      in: text,
      range: range,
      withTemplate: "[[$2][$1]]"
    )
  }
}

/// Decides which room messages belong to a turn and when the turn is over.
struct OpenAIDotReplyTracker {
  enum State: Equatable { case waiting, settled, timedOut }

  let selfMemberID: String
  private(set) var cursor: String
  let startedAt: Date
  let timing: OpenAIDotChatClient.Timing
  private(set) var replies: [OpenAIDotMessage] = []
  private(set) var lastReplyAt: Date?
  private var seenIDs: Set<String> = []

  init(selfMemberID: String, cursor: String, startedAt: Date, timing: OpenAIDotChatClient.Timing) {
    self.selfMemberID = selfMemberID
    self.cursor = cursor
    self.startedAt = startedAt
    self.timing = timing
    self.seenIDs = [cursor]
  }

  /// Advances past a page of messages newer than the cursor and returns the
  /// dot's new messages. The user's own messages advance the cursor but are
  /// never treated as replies.
  mutating func ingest(_ messages: [OpenAIDotMessage]) -> [OpenAIDotMessage] {
    var fresh: [OpenAIDotMessage] = []
    for message in messages {
      cursor = message.id
      guard seenIDs.insert(message.id).inserted else { continue }
      guard !message.isDeleted,
            message.memberID != selfMemberID,
            !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      fresh.append(message)
    }
    return fresh
  }

  /// Counts messages as replies to this turn; each one restarts the quiet period.
  mutating func record(_ messages: [OpenAIDotMessage], at now: Date) {
    guard !messages.isEmpty else { return }
    replies += messages
    lastReplyAt = now
  }

  func state(at now: Date) -> State {
    if let lastReplyAt {
      return now.timeIntervalSince(lastReplyAt) >= timing.settleInterval ? .settled : .waiting
    }
    return now.timeIntervalSince(startedAt) >= timing.firstReplyTimeout ? .timedOut : .waiting
  }
}

// MARK: - Credentials

/// The ChatGPT sign-in Codex stores in `auth.json`. Celorga only reads it;
/// Codex remains responsible for signing in and refreshing the token.
public struct OpenAIDotCredentials: Sendable, Equatable {
  public let accessToken: String
  public let accountID: String?
  public let expiresAt: Date?

  public init(accessToken: String, accountID: String?, expiresAt: Date?) {
    self.accessToken = accessToken
    self.accountID = accountID
    self.expiresAt = expiresAt
  }

  public static func codexAuthFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !codexHome.isEmpty {
      return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath)
        .appendingPathComponent("auth.json")
    }
    return homeDirectory.appendingPathComponent(".codex/auth.json")
  }

  public static func loadFromCodex(
    authFileURL: URL = codexAuthFileURL(),
    now: Date = Date()
  ) throws -> OpenAIDotCredentials {
    let data: Data
    do {
      data = try Data(contentsOf: authFileURL)
    } catch {
      throw OpenAIDotChatError.notSignedIn
    }
    return try parse(authJSON: data, now: now)
  }

  public static func parse(authJSON data: Data, now: Date = Date()) throws -> OpenAIDotCredentials {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = object["tokens"] as? [String: Any],
          let accessToken = (tokens["access_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !accessToken.isEmpty
    else {
      throw OpenAIDotChatError.notSignedIn
    }
    let claims = jwtClaims(accessToken)
    let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
    let accountID = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? (auth?["chatgpt_account_id"] as? String)
    let expiresAt = (claims?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    if let expiresAt, expiresAt <= now {
      throw OpenAIDotChatError.signInExpired
    }
    return OpenAIDotCredentials(accessToken: accessToken, accountID: accountID, expiresAt: expiresAt)
  }

  static func jwtClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 { payload += "=" }
    guard let data = Data(base64Encoded: payload) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}

// MARK: - Errors

public enum OpenAIDotChatError: LocalizedError, Equatable {
  case invalidEndpoint(String)
  case notSignedIn
  case signInExpired
  case noPrimaryDot
  case dotNotFound(String)
  case dotPaused(String)
  case noMessagingRoom(String)
  case emptyMessage
  case unsupportedAttachment(String)
  case http(status: Int, detail: String?)
  case invalidResponse(String)
  case transport(String)

  /// ChatGPT refused the message's reply target rather than the message.
  var rejectsReplyTarget: Bool {
    if case .http(let status, _) = self {
      return [400, 404, 409, 422].contains(status)
    }
    return false
  }

  /// A failure worth retrying later: the network or ChatGPT was briefly
  /// unavailable, rather than the sign-in or the dot being wrong.
  public var isTransient: Bool {
    switch self {
    case .transport:
      true
    case .http(let status, _):
      status == 408 || status == 429 || (500..<600).contains(status)
    default:
      false
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint(let endpoint):
      "Enter a valid https:// ChatGPT backend URL, or leave it blank (received \(endpoint))."
    case .notSignedIn:
      "Sign in to Codex with ChatGPT on this Mac first. The OpenAI Dot destination uses that sign-in."
    case .signInExpired:
      "Your Codex ChatGPT sign-in has expired. Open Codex or the ChatGPT app to refresh it, then try again."
    case .noPrimaryDot:
      "This ChatGPT account doesn't have a dot yet. Create one in ChatGPT first."
    case .dotNotFound(let selector):
      "No dot named or with the ID “\(selector)” was found on this ChatGPT account."
    case .dotPaused(let name):
      "\(name) is paused. Resume it in ChatGPT, then try again."
    case .noMessagingRoom(let name):
      "\(name) doesn't have a ChatGPT conversation yet. Open it once in ChatGPT, then try again."
    case .emptyMessage:
      "Type a message before sending it to the dot."
    case .unsupportedAttachment(let fileName):
      "The OpenAI Dot destination sends text only, so \(fileName) wasn't sent. Share the file with the dot in ChatGPT instead."
    case .http(let status, let detail):
      switch status {
      case 401:
        "ChatGPT rejected the Codex sign-in. Sign in to Codex again, then retry."
      case 403:
        "ChatGPT refused the request (HTTP 403)\(detail.map { ": \($0)" } ?? ""). OpenAI may have changed the private dot messaging routes."
      case 404:
        "ChatGPT couldn't find the dot or its conversation (HTTP 404). OpenAI may have changed the private dot messaging routes."
      default:
        "ChatGPT returned HTTP \(status)\(detail.map { ": \($0)" } ?? "")."
      }
    case .invalidResponse(let detail):
      "ChatGPT returned an unexpected response (\(detail)). OpenAI may have changed the private dot messaging routes."
    case .transport(let detail):
      "Could not reach ChatGPT: \(detail)"
    }
  }
}
