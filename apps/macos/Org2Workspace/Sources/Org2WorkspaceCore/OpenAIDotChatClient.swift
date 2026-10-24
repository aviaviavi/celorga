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

    public init(
      pollInterval: TimeInterval = 2,
      settleInterval: TimeInterval = 10,
      firstReplyTimeout: TimeInterval = 15 * 60
    ) {
      self.pollInterval = pollInterval
      self.settleInterval = settleInterval
      self.firstReplyTimeout = firstReplyTimeout
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
  public func send(
    text: String,
    requestID: String,
    onMessage: (@Sendable (OpenAIDotMessage) async -> Void)? = nil
  ) async throws -> OpenAIDotTurnResult {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { throw OpenAIDotChatError.emptyMessage }
    let dot = try await resolveDot()
    let roomID = dot.messagingRoomID ?? ""
    let roomPath = "/messaging/rooms/\(Self.pathComponent(roomID))"

    let sentObject = try await requestJSON(
      "POST",
      path: "\(roomPath)/messages",
      body: Self.sendBody(text: body, requestID: requestID, timeZone: .current, now: clock())
    )
    guard let sent = OpenAIDotMessage(json: sentObject) else {
      throw OpenAIDotChatError.invalidResponse("the sent message had no ID")
    }

    var tracker = OpenAIDotReplyTracker(
      selfMemberID: sent.memberID,
      cursor: sent.id,
      startedAt: clock(),
      timing: timing
    )
    while true {
      try Task.checkCancellation()
      try await sleep(timing.pollInterval)
      try Task.checkCancellation()
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
        let replies = tracker.ingest(items, at: clock())
        for reply in replies {
          await onMessage?(reply)
        }
        pageFull = items.count >= Self.pageSize
      }
      switch tracker.state(at: clock()) {
      case .waiting:
        continue
      case .settled:
        return OpenAIDotTurnResult(dot: dot, sentMessageID: sent.id, replies: tracker.replies, timedOut: false)
      case .timedOut:
        return OpenAIDotTurnResult(dot: dot, sentMessageID: sent.id, replies: tracker.replies, timedOut: true)
      }
    }
  }

  /// ChatGPT rejects pages larger than 32 messages.
  static let pageSize = 20

  static func sendBody(
    text: String,
    requestID: String,
    timeZone: TimeZone,
    now: Date
  ) -> [String: Any] {
    [
      "content": ["text": text, "attachments": [Any]()],
      "request_id": requestID,
      "idempotency_token": requestID,
      // Matches JavaScript's Date#getTimezoneOffset: minutes behind UTC.
      "timezone_offset_min": -timeZone.secondsFromGMT(for: now) / 60,
    ]
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

  public init(id: String, memberID: String, text: String, isDeleted: Bool = false) {
    self.id = id
    self.memberID = memberID
    self.text = text
    self.isDeleted = isDeleted
  }

  init?(json: [String: Any]) {
    guard let id = json["id"] as? String, !id.isEmpty else { return nil }
    let content = json["content"] as? [String: Any]
    let deleted = json["deleted_at"].map { !($0 is NSNull) } ?? false
    self.init(
      id: id,
      memberID: json["account_user_id"] as? String ?? "",
      text: content?["text"] as? String ?? "",
      isDeleted: deleted
    )
  }
}

public struct OpenAIDotTurnResult: Sendable, Equatable {
  public let dot: OpenAIDotProfile
  public let sentMessageID: String
  public let replies: [OpenAIDotMessage]
  public let timedOut: Bool

  /// The reply text for the chat transcript.
  public var transcriptText: String {
    let body = replies
      .map { Self.orgLinks($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    if timedOut {
      let note = "/\(dot.displayName) hasn't replied yet. Your message was delivered; later replies appear in \(dot.displayName)'s ChatGPT conversation./"
      return body.isEmpty ? note : body + "\n\n" + note
    }
    return body
  }
}

extension OpenAIDotTurnResult {
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

  /// Records a page of messages newer than the cursor and returns the new
  /// replies from the dot. The user's own messages advance the cursor but are
  /// never treated as replies.
  mutating func ingest(_ messages: [OpenAIDotMessage], at now: Date) -> [OpenAIDotMessage] {
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
    if !fresh.isEmpty {
      replies += fresh
      lastReplyAt = now
    }
    return fresh
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
