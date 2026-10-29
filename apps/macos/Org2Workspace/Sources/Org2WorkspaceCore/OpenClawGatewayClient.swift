import CryptoKit
import Foundation
import Security

public enum OpenClawGatewayConnectionState: String, Sendable {
  case disconnected
  case connecting
  case connected
  case reconnecting
  case fallbackHTTP

  public var label: String {
    switch self {
    case .disconnected: return "Disconnected"
    case .connecting: return "Connecting"
    case .connected: return "Live"
    case .reconnecting: return "Reconnecting"
    case .fallbackHTTP: return "HTTP compatibility"
    }
  }
}

public struct AIChatRunActivity: Identifiable, Hashable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case lifecycle
    case tool
    case reasoning
  }

  public enum Status: String, Codable, Sendable {
    case running
    case succeeded
    case failed
  }

  public let id: String
  public let runID: String
  public let kind: Kind
  public let title: String
  public let detail: String?
  public let status: Status
  public let updatedAt: Date

  public init(
    id: String,
    runID: String,
    kind: Kind,
    title: String,
    detail: String? = nil,
    status: Status,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.runID = runID
    self.kind = kind
    self.title = title
    self.detail = detail
    self.status = status
    self.updatedAt = updatedAt
  }
}

struct AIChatActivityFeedItem: Identifiable, Equatable, Sendable {
  let id: String
  let kind: AIChatRunActivity.Kind
  let title: String
  let detail: String?
  let latestDetail: String?
  let status: AIChatRunActivity.Status
  let count: Int
  let updatedAt: Date

  init(
    id: String,
    kind: AIChatRunActivity.Kind = .tool,
    title: String,
    detail: String?,
    latestDetail: String?,
    status: AIChatRunActivity.Status,
    count: Int,
    updatedAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.detail = detail
    self.latestDetail = latestDetail
    self.status = status
    self.count = count
    self.updatedAt = updatedAt
  }
}

enum AIChatActivityFeed {
  private static let maximumDetailLength = 180

  static func items(from activities: [AIChatRunActivity]) -> [AIChatActivityFeedItem] {
    var grouped: [(key: String, activities: [AIChatRunActivity])] = []

    for activity in activities {
      if activity.kind == .lifecycle {
        guard activity.status == .failed || meaningfulDetail(activity.detail, status: activity.status) != nil else {
          continue
        }
        let key = "lifecycle:\(activity.id)"
        grouped.append((key, [activity]))
        continue
      }

      if activity.kind == .reasoning {
        guard meaningfulDetail(activity.detail, status: activity.status) != nil else { continue }
        grouped.append(("reasoning:\(activity.id)", [activity]))
        continue
      }

      let key = "\(activity.kind.rawValue):\(normalizedToolName(activity.title))"
      if grouped.last?.key == key {
        grouped[grouped.count - 1].activities.append(activity)
      } else {
        grouped.append((key, [activity]))
      }
    }

    return grouped.enumerated().compactMap { index, entry in
      let group = entry.activities
      guard let first = group.first else { return nil }
      let failures = group.filter { $0.status == .failed }.count
      let running = group.filter { $0.status == .running }.count
      let succeeded = group.count - failures - running
      // A recoverable tool error should not make an otherwise healthy group
      // look like the whole turn failed. Keep active work active, and only
      // summarize a completed group as failed when failures are the majority.
      let status: AIChatRunActivity.Status = running > 0
        ? .running
        : (failures > succeeded ? .failed : .succeeded)
      let detail: String?
      if group.count == 1 {
        detail = meaningfulDetail(first.detail, status: first.status)
      } else {
        var parts: [String] = []
        if succeeded > 0 { parts.append("\(succeeded) completed") }
        if running > 0 { parts.append("\(running) running") }
        if failures > 0 { parts.append("\(failures) failed") }
        detail = parts.joined(separator: " · ")
      }
      let latestActivity = group
        .filter { status == .running ? $0.status == .running : true }
        .max { $0.updatedAt < $1.updatedAt }
      let latestDetail = group.count > 1
        ? latestActivity.flatMap { meaningfulDetail($0.detail, status: $0.status) }
        : nil
      return AIChatActivityFeedItem(
        id: "\(entry.key):\(index)",
        kind: first.kind,
        title: displayTitle(for: first.title, count: group.count),
        detail: detail,
        latestDetail: latestDetail,
        status: status,
        count: group.count,
        updatedAt: latestActivity?.updatedAt ?? first.updatedAt
      )
    }
  }

  static func merging(_ previous: AIChatRunActivity, with update: AIChatRunActivity) -> AIChatRunActivity {
    let updateDetail = meaningfulDetail(update.detail, status: update.status)
    let previousDetail = meaningfulDetail(previous.detail, status: previous.status)
    return AIChatRunActivity(
      id: update.id,
      runID: update.runID,
      kind: update.kind,
      title: update.title,
      detail: updateDetail ?? previousDetail,
      status: update.status,
      updatedAt: update.updatedAt
    )
  }

  static func meaningfulDetail(
    _ detail: String?,
    status: AIChatRunActivity.Status
  ) -> String? {
    guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else {
      return nil
    }
    if let data = detail.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
      return meaningfulStructuredDetail(object, status: status)
    }

    return readablePlainDetail(detail, status: status)
  }

  private static func meaningfulStructuredDetail(
    _ object: Any,
    status: AIChatRunActivity.Status
  ) -> String? {
    if let encoded = object as? String {
      return readablePlainDetail(encoded, status: status)
    }
    guard let dictionary = object as? [String: Any] else {
      // Arrays and scalar tool results are machine output, not chat copy.
      return status == .failed ? "Tool call failed" : nil
    }

    let lowSignalKeys = Set(["durationMs", "exitCode", "status"])
    if Set(dictionary.keys).isSubset(of: lowSignalKeys) {
      if status == .failed, let exitCode = dictionary["exitCode"] as? Int {
        return "Exited with code \(exitCode)"
      }
      return nil
    }

    if let query = stringValue(in: dictionary, keys: ["query", "search", "pattern"]),
       let readable = readablePlainDetail(query, status: status) {
      return "Searching for \u{201c}\(readable)\u{201d}"
    }
    if let command = stringValue(in: dictionary, keys: ["cmd", "command"]),
       let readable = readablePlainDetail(command, status: status) {
      return readable
    }
    if let path = stringValue(in: dictionary, keys: ["path", "file", "filePath"]),
       let readable = readablePlainDetail(path, status: status) {
      return readable
    }
    if let url = stringValue(in: dictionary, keys: ["url"]),
       let readable = readablePlainDetail(url, status: status) {
      return readable
    }
    if status == .failed,
       let error = stringValue(in: dictionary, keys: ["error", "errorMessage", "message"]),
       let readable = readablePlainDetail(error, status: status) {
      return readable
    }

    // Command arguments and result envelopes stay in diagnostic logs. Showing
    // them here creates both unreadable JSON and accidental transcript overflow.
    return status == .failed ? "Tool call failed" : nil
  }

  private static func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = dictionary[key] as? String,
         !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
      }
    }
    return nil
  }

  private static func readablePlainDetail(
    _ raw: String,
    status: AIChatRunActivity.Status
  ) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Some gateways deliver a JSON result as an escaped string. Do not let the
    // encoding accident turn into user-visible transcript content.
    let structuredPrefixes = ["{", "[", "\\{", "\\[", "\"{", "\"["]
    let looksStructured = structuredPrefixes.contains { trimmed.hasPrefix($0) }
      || trimmed.contains("\\\"content\\\"")
      || trimmed.contains("\\\"results\\\"")
    if looksStructured {
      return status == .failed ? "Tool call failed" : nil
    }

    let readable = trimmed
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    guard readable.count > maximumDetailLength else { return readable }
    return String(readable.prefix(maximumDetailLength - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
  }

  private static func normalizedToolName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func displayTitle(for raw: String, count: Int) -> String {
    let singular: String
    let plural: String
    switch normalizedToolName(raw) {
    case "bash", "shell", "exec", "exec_command", "run_command":
      singular = "Shell command"
      plural = "Shell commands"
    case "read", "read_file":
      singular = "File read"
      plural = "Files read"
    case "write", "write_file":
      singular = "File written"
      plural = "Files written"
    case "edit", "apply_patch":
      singular = "File edit"
      plural = "File edits"
    case "search", "grep", "rg":
      singular = "Search"
      plural = "Searches"
    default:
      singular = humanized(raw)
      plural = "\(singular) calls"
    }
    return count == 1 ? singular : "\(count) \(plural.lowercased())"
  }

  private static func humanized(_ raw: String) -> String {
    let spaced = raw
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = spaced.first else { return "Tool" }
    return String(first).uppercased() + spaced.dropFirst()
  }
}

public enum OpenClawGatewayRunEvent: Sendable {
  case connection(OpenClawGatewayConnectionState, String?)
  case accepted(runID: String)
  case reconciliationHeartbeat
  case text(String, replace: Bool)
  case reasoning(String, replace: Bool)
  case activity(AIChatRunActivity)
  case usage(AIChatTokenUsage)
  case contextCompacted
}

public struct OpenClawAIChatSessionConfiguration: Sendable {
  public let model: String?
  public let reasoningEffort: String?
  public let reasoningOptions: [AIChatReasoningOption]
  public let defaultReasoningEffort: String?

  public init(
    model: String?,
    reasoningEffort: String?,
    reasoningOptions: [AIChatReasoningOption],
    defaultReasoningEffort: String?
  ) {
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.reasoningOptions = reasoningOptions
    self.defaultReasoningEffort = defaultReasoningEffort
  }
}

public struct OpenClawPreparedWorkflowRun: Sendable {
  public let runID: String
  public let prompt: String

  public init(runID: String, prompt: String) {
    self.runID = runID
    self.prompt = prompt
  }
}

public struct OpenClawWorkflowContinuation: Sendable {
  public let runID: String
  public let sessionKey: String
  public let prompt: String

  public init(runID: String, sessionKey: String, prompt: String) {
    self.runID = runID
    self.sessionKey = sessionKey
    self.prompt = prompt
  }
}

public struct OpenClawRunContinuation: Sendable {
  public let runID: String
  public let sessionKey: String?
  public let prompt: String
  /// The durable run after it left the blocked state, when the responder
  /// returned it. Lets the app show the run as running before its corpus
  /// copy catches up.
  public let run: AgentRunItem?

  public init(runID: String, sessionKey: String?, prompt: String, run: AgentRunItem? = nil) {
    self.runID = runID
    self.sessionKey = sessionKey
    self.prompt = prompt
    self.run = run
  }
}

public struct OpenClawApprovedRunContinuation: Sendable {
  public let runID: String
  public let sessionKey: String?
  public let prompt: String
  public let kind: String
  public let continuationKey: String?
  public let alreadyResumed: Bool

  public init(
    runID: String,
    sessionKey: String?,
    prompt: String,
    kind: String,
    continuationKey: String? = nil,
    alreadyResumed: Bool = false
  ) {
    self.runID = runID
    self.sessionKey = sessionKey
    self.prompt = prompt
    self.kind = kind
    self.continuationKey = continuationKey
    self.alreadyResumed = alreadyResumed
  }
}

public struct OpenClawExecApprovalDetails: Equatable, Sendable {
  public let id: String
  public let commandText: String
  public let commandPreview: String?
  public let allowedDecisions: [String]
  public let host: String?
  public let nodeID: String?
  public let agentID: String?
  public let expiresAtMilliseconds: Double?

  public init(
    id: String,
    commandText: String,
    commandPreview: String? = nil,
    allowedDecisions: [String] = [],
    host: String? = nil,
    nodeID: String? = nil,
    agentID: String? = nil,
    expiresAtMilliseconds: Double? = nil
  ) {
    self.id = id
    self.commandText = commandText
    self.commandPreview = commandPreview
    self.allowedDecisions = allowedDecisions
    self.host = host
    self.nodeID = nodeID
    self.agentID = agentID
    self.expiresAtMilliseconds = expiresAtMilliseconds
  }

  public var reviewText: String {
    let preview = commandPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return preview.isEmpty ? commandText : preview
  }
}

public enum OpenClawGatewayError: LocalizedError, Sendable {
  case invalidEndpoint
  case connection(String)
  case protocolFailure(String)
  case gateway(code: String?, message: String)
  case sessionConfigurationRejected(code: String?, message: String)
  case emptyResponse
  case aborted(String?)
  case acceptedRunTerminated(String)
  case acceptedRunRecovery(String)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "The configured OpenClaw endpoint cannot be converted to a Gateway WebSocket URL."
    case .connection(let message):
      return "Could not connect to the OpenClaw Gateway: \(message)"
    case .protocolFailure(let message):
      return "The OpenClaw Gateway protocol failed: \(message)"
    case .gateway(_, let message):
      return message
    case .sessionConfigurationRejected(_, let message):
      return message
    case .emptyResponse:
      return "OpenClaw finished without a response."
    case .aborted(let message):
      return message?.isEmpty == false ? "OpenClaw run stopped: \(message!)" : "OpenClaw run stopped."
    case .acceptedRunTerminated(let message):
      return message
    case .acceptedRunRecovery(let message):
      return "OpenClaw accepted the run but could not reconcile its result: \(message)"
    }
  }

  public var permitsHTTPFallback: Bool {
    switch self {
    case .invalidEndpoint, .connection, .protocolFailure:
      return true
    case .gateway(let code, let message):
      return code == "NOT_PAIRED"
        || (code == "INVALID_REQUEST" && message.localizedCaseInsensitiveContains("missing scope"))
    case .sessionConfigurationRejected, .emptyResponse, .aborted, .acceptedRunTerminated, .acceptedRunRecovery:
      return false
    }
  }
}

enum OpenClawChatHistoryReconciliation: Equatable {
  case pending(hasActiveRun: Bool, activeRunIDs: [String])
  case completed(String)
  case failed(String)
}

enum OpenClawGatewayIdentityStorage {
  static let service = "Org2Workspace.OpenClawGateway"
  static let legacyAccount = "gatewayDevicePrivateKey"

  static func account(bundleIdentifier: String?) -> String {
    let bundleIdentifier = bundleIdentifier?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedBundleIdentifier = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
      ?? "org.org2.workspace"
    return "gatewayDevicePrivateKey.\(resolvedBundleIdentifier)"
  }
}

struct OpenClawDeviceIdentity: Sendable {
  private static var account: String {
    OpenClawGatewayIdentityStorage.account(bundleIdentifier: Bundle.main.bundleIdentifier)
  }

  let privateKey: Curve25519.Signing.PrivateKey

  var publicKeyBase64URL: String {
    Self.base64URL(privateKey.publicKey.rawRepresentation)
  }

  var deviceID: String {
    SHA256.hash(data: privateKey.publicKey.rawRepresentation)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func loadOrCreate(fileURL: URL? = nil) throws -> OpenClawDeviceIdentity {
    if let fileURL {
      if let data = try readPrivateKey(fileURL: fileURL),
         let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
        return OpenClawDeviceIdentity(privateKey: key)
      }
      let identity = OpenClawDeviceIdentity(privateKey: Curve25519.Signing.PrivateKey())
      try savePrivateKey(identity.privateKey.rawRepresentation, fileURL: fileURL)
      return identity
    }
    if let data = try readPrivateKey(account: account),
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
      return OpenClawDeviceIdentity(privateKey: key)
    }
    // Keep the already-approved identity when upgrading from the original
    // shared account, then isolate future writes by bundle identifier so the
    // daily and Codex builds cannot rotate each other's device key.
    if let data = try readPrivateKey(account: OpenClawGatewayIdentityStorage.legacyAccount),
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
      try savePrivateKey(data, account: account)
      return OpenClawDeviceIdentity(privateKey: key)
    }
    let identity = OpenClawDeviceIdentity(privateKey: Curve25519.Signing.PrivateKey())
    try savePrivateKey(identity.privateKey.rawRepresentation, account: account)
    return identity
  }

  private static func readPrivateKey(fileURL: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
  }

  private static func savePrivateKey(_ data: Data, fileURL: URL) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  func signature(for payload: String) throws -> String {
    Self.base64URL(try privateKey.signature(for: Data(payload.utf8)))
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func readPrivateKey(account: String) throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: OpenClawGatewayIdentityStorage.service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw OpenClawKeychainError.status(status) }
    return result as? Data
  }

  private static func savePrivateKey(_ data: Data, account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: OpenClawGatewayIdentityStorage.service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: data
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let match: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: OpenClawGatewayIdentityStorage.service,
        kSecAttrAccount as String: account
      ]
      let update = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard update == errSecSuccess else { throw OpenClawKeychainError.status(update) }
      return
    }
    guard status == errSecSuccess else { throw OpenClawKeychainError.status(status) }
  }
}

private final class OpenClawWebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
  struct CloseInfo: Sendable {
    let code: URLSessionWebSocketTask.CloseCode
    let reason: Data?
  }

  private let lock = NSLock()
  private var closeInfoByTaskID: [Int: CloseInfo] = [:]

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {}

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    lock.withLock {
      closeInfoByTaskID[webSocketTask.taskIdentifier] = CloseInfo(code: closeCode, reason: reason)
    }
  }

  func takeCloseInfo(for task: URLSessionWebSocketTask) -> CloseInfo? {
    lock.withLock { closeInfoByTaskID.removeValue(forKey: task.taskIdentifier) }
  }

  func removeCloseInfo(for task: URLSessionWebSocketTask) {
    _ = lock.withLock { closeInfoByTaskID.removeValue(forKey: task.taskIdentifier) }
  }
}

private actor OpenClawRecoveryConnectionLimiter {
  static let shared = OpenClawRecoveryConnectionLimiter(limit: 3)

  private let limit: Int
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func acquire() async {
    guard active >= limit else {
      active += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    guard !waiters.isEmpty else {
      active = max(0, active - 1)
      return
    }
    waiters.removeFirst().resume()
  }
}

/// A small native client for OpenClaw Gateway protocol v4. A client represents one
/// in-flight Org2 turn, while the Gateway remains the authority for run state.
public actor OpenClawGatewayClient {
  public typealias EventHandler = @Sendable (OpenClawGatewayRunEvent) async -> Void

  static let acceptedRunRecoveryPollTimeoutMilliseconds = 5_000
  static let connectionAttemptTimeout: TimeInterval = 15

  private let settings: OpenClawGatewaySettings
  private let sessionDelegate: OpenClawWebSocketSessionDelegate
  private let session: URLSession
  private var socket: URLSessionWebSocketTask?
  private var sessionKey: String?
  private var agentID: String?
  private var runID: String?
  private var deviceID: String?
  private var awaitingHello = false
  private var stopRequested = false
  private var outstandingSteerRequestIDs: Set<String> = []
  private var pendingSteerAcknowledgements: [String: CheckedContinuation<Void, Error>] = [:]
  private var earlySteerAcknowledgements: [String: [String: Any]] = [:]
  private var commentaryTextByItemID: [String: String] = [:]
  private var isShutdown = false

  /// Reconnect delays used while nothing has been sent yet. A busy Gateway can stall
  /// its event loop for more than a minute; the message waits instead of failing.
  private let preSendReconnectDelays: [TimeInterval]
  private var timedOutSockets: Set<ObjectIdentifier> = []

  public static let defaultPreSendReconnectDelays: [TimeInterval] = [2, 4, 8, 15, 15, 15, 15, 15]

  public init(
    settings: OpenClawGatewaySettings,
    preSendReconnectDelays: [TimeInterval] = OpenClawGatewayClient.defaultPreSendReconnectDelays
  ) {
    self.settings = settings
    self.preSendReconnectDelays = preSendReconnectDelays
    let sessionDelegate = OpenClawWebSocketSessionDelegate()
    self.sessionDelegate = sessionDelegate
    self.session = URLSession(
      configuration: OpenClawChatClient.sessionConfiguration(),
      delegate: sessionDelegate,
      delegateQueue: nil
    )
  }

  public func prepare() async throws {
    let socket = try makeSocket()
    self.socket = socket
    socket.resume()
    do {
      try await establishConnection(on: socket)
      socket.cancel(with: .normalClosure, reason: nil)
    } catch let error as OpenClawGatewayError {
      socket.cancel(with: .goingAway, reason: nil)
      throw error
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
  }

  public func listCommands(agentID: String) async throws -> [AIChatSlashCommand] {
    let socket = try makeSocket()
    self.socket = socket
    socket.resume()
    do {
      try await establishConnection(on: socket)
      let requestID = UUID().uuidString.lowercased()
      try await sendRequest(
        id: requestID,
        method: "commands.list",
        params: [
          "agentId": agentID,
          "scope": "text",
          "includeArgs": true
        ],
        on: socket
      )
      while true {
        let frame = try await receiveObject(on: socket)
        guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == requestID else {
          continue
        }
        guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
        let payload = Self.dictionary(frame["payload"]) ?? [:]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let commands = try OpenClawGatewayCommandCatalog.decode(data)
        socket.cancel(with: .normalClosure, reason: nil)
        return commands
      }
    } catch let error as OpenClawGatewayError {
      socket.cancel(with: .goingAway, reason: nil)
      throw error
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
  }

  public func listModels() async throws -> [AIChatModelOption] {
    let payload = try await requestPayload(
      method: "models.list",
      params: ["view": "configured"],
      scopes: ["operator.read"]
    )
    let rows = payload["models"] as? [[String: Any]] ?? []
    return rows.compactMap { row in
      guard let id = Self.string(row["id"]),
            let provider = Self.string(row["provider"]),
            !id.isEmpty,
            !provider.isEmpty
      else {
        return nil
      }
      let reference = id.contains("/") ? id : "\(provider)/\(id)"
      return AIChatModelOption(
        id: reference,
        label: Self.string(row["name"]) ?? reference,
        detail: Self.string(row["alias"]),
        supportsReasoning: Self.bool(row["reasoning"]) ?? false
      )
    }
  }

  public func sessionConfiguration(
    sessionKey: String
  ) async throws -> OpenClawAIChatSessionConfiguration? {
    let payload = try await requestPayload(
      method: "sessions.describe",
      params: ["key": sessionKey],
      scopes: ["operator.read"]
    )
    guard let session = Self.dictionary(payload["session"]) else { return nil }
    return Self.sessionConfiguration(from: session)
  }

  @discardableResult
  public func patchSessionConfiguration(
    sessionKey: String,
    agentID: String,
    model: String?,
    reasoningEffort: String?
  ) async throws -> OpenClawAIChatSessionConfiguration {
    let payload = try await requestPayload(
      method: "sessions.patch",
      params: Self.sessionConfigurationPatchParams(
        sessionKey: sessionKey,
        agentID: agentID,
        model: model,
        reasoningEffort: reasoningEffort
      ),
      scopes: ["operator.admin"]
    )
    let resolved = Self.dictionary(payload["resolved"]) ?? [:]
    let entry = Self.dictionary(payload["entry"]) ?? [:]
    return try await sessionConfiguration(sessionKey: sessionKey)
      ?? Self.sessionConfiguration(from: resolved.merging(entry) { current, _ in current })
  }

  public func prepareWorkflowRun(
    workflowID: String,
    inputs: [String: String],
    corpusID: String?
  ) async throws -> OpenClawPreparedWorkflowRun {
    var params: [String: Any] = ["workflowId": workflowID, "inputs": inputs]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    let payload = try await requestPayload(
      method: "org2.workflow.prepareRun",
      params: params
    )
    guard let run = Self.dictionary(payload["run"]),
          let runID = Self.string(run["id"]), !runID.isEmpty,
          let prompt = Self.string(payload["prompt"]), !prompt.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("org2.workflow.prepareRun returned an invalid payload")
    }
    return OpenClawPreparedWorkflowRun(runID: runID, prompt: prompt)
  }

  public func resumeWorkflowRun(runID: String, corpusID: String?) async throws -> OpenClawWorkflowContinuation {
    var params: [String: Any] = ["runId": runID]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    let payload = try await requestPayload(method: "org2.workflow.resume", params: params)
    guard let run = Self.dictionary(payload["run"]),
          let returnedRunID = Self.string(run["id"]), !returnedRunID.isEmpty,
          let sessionKey = Self.string(payload["sessionKey"]), !sessionKey.isEmpty,
          let prompt = Self.string(payload["prompt"]), !prompt.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("org2.workflow.resume returned an invalid payload")
    }
    return OpenClawWorkflowContinuation(runID: returnedRunID, sessionKey: sessionKey, prompt: prompt)
  }

  public func resumeDraftRun(runID: String, corpusID: String?) async throws -> OpenClawWorkflowContinuation {
    var params: [String: Any] = ["runId": runID]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    let payload = try await requestPayload(method: "org2.draft.resume", params: params)
    guard let run = Self.dictionary(payload["run"]),
          let returnedRunID = Self.string(run["id"]), !returnedRunID.isEmpty,
          let sessionKey = Self.string(payload["sessionKey"]), !sessionKey.isEmpty,
          let prompt = Self.string(payload["prompt"]), !prompt.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("org2.draft.resume returned an invalid payload")
    }
    return OpenClawWorkflowContinuation(runID: returnedRunID, sessionKey: sessionKey, prompt: prompt)
  }

  /// `expectedUpdatedAt` is the run's `updatedAt` as this workspace last wrote
  /// it. The Gateway may run on another machine with a file-synced corpus; it
  /// waits until its copy is at least this new before checking run state.
  public func resumeApprovedRun(
    runID: String,
    corpusID: String?,
    expectedUpdatedAt: String? = nil
  ) async throws -> OpenClawApprovedRunContinuation {
    var params: [String: Any] = ["runId": runID]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    if let expectedUpdatedAt, !expectedUpdatedAt.isEmpty { params["expectedUpdatedAt"] = expectedUpdatedAt }
    let payload = try await requestPayload(method: "org2.run.resumeApproved", params: params)
    guard let run = Self.dictionary(payload["run"]),
          let returnedRunID = Self.string(run["id"]), !returnedRunID.isEmpty,
          let prompt = Self.string(payload["prompt"]), !prompt.isEmpty,
          let kind = Self.string(payload["kind"]), !kind.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("org2.run.resumeApproved returned an invalid payload")
    }
    let sessionKey = Self.string(payload["sessionKey"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    return OpenClawApprovedRunContinuation(
      runID: returnedRunID,
      sessionKey: sessionKey?.isEmpty == false ? sessionKey : nil,
      prompt: prompt,
      kind: kind,
      continuationKey: Self.string(payload["continuationKey"]),
      alreadyResumed: Self.bool(payload["alreadyResumed"]) ?? false
    )
  }

  public func replyAndResumeRun(
    runID: String,
    response: String,
    corpusID: String?,
    expectedUpdatedAt: String? = nil
  ) async throws -> OpenClawRunContinuation {
    var params: [String: Any] = ["runId": runID, "response": response]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    if let expectedUpdatedAt, !expectedUpdatedAt.isEmpty { params["expectedUpdatedAt"] = expectedUpdatedAt }
    let payload = try await requestPayload(method: "org2.run.replyAndResume", params: params)
    guard let run = Self.dictionary(payload["run"]),
          let returnedRunID = Self.string(run["id"]), !returnedRunID.isEmpty,
          let prompt = Self.string(payload["prompt"]), !prompt.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("org2.run.replyAndResume returned an invalid payload")
    }
    let sessionKey = Self.string(payload["sessionKey"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resumedRun = (try? JSONSerialization.data(withJSONObject: run))
      .flatMap { try? JSONDecoder().decode(AgentRunItem.self, from: $0) }
    return OpenClawRunContinuation(
      runID: returnedRunID,
      sessionKey: sessionKey?.isEmpty == false ? sessionKey : nil,
      prompt: prompt,
      run: resumedRun?.id == returnedRunID ? resumedRun : nil
    )
  }

  public func resumeWorkflowRevision(
    runID: String,
    approvalID: String,
    corpusID: String?
  ) async throws -> OpenClawWorkflowContinuation {
    var params: [String: Any] = ["runId": runID, "approvalId": approvalID]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    let payload = try await requestPayload(method: "org2.workflow.resumeRevision", params: params)
    guard let run = Self.dictionary(payload["run"]),
          let returnedRunID = Self.string(run["id"]), !returnedRunID.isEmpty,
          let sessionKey = Self.string(payload["sessionKey"]), !sessionKey.isEmpty,
          let prompt = Self.string(payload["prompt"]), !prompt.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("org2.workflow.resumeRevision returned an invalid payload")
    }
    return OpenClawWorkflowContinuation(runID: returnedRunID, sessionKey: sessionKey, prompt: prompt)
  }

  public func syncWorkflows(corpusID: String?) async throws {
    var params: [String: Any] = [:]
    if let corpusID, !corpusID.isEmpty { params["corpusId"] = corpusID }
    _ = try await requestPayload(method: "org2.workflow.sync", params: params)
  }

  public func execApprovalDetails(id: String) async throws -> OpenClawExecApprovalDetails {
    let payload = try await requestPayload(
      method: "exec.approval.get",
      params: ["id": id],
      scopes: ["operator.read", "operator.approvals"]
    )
    return try Self.execApprovalDetails(from: payload)
  }

  static func execApprovalDetails(from payload: [String: Any]) throws -> OpenClawExecApprovalDetails {
    guard let id = string(payload["id"]), !id.isEmpty,
          let commandText = string(payload["commandText"]), !commandText.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("exec.approval.get returned an invalid payload")
    }
    return OpenClawExecApprovalDetails(
      id: id,
      commandText: commandText,
      commandPreview: string(payload["commandPreview"]),
      allowedDecisions: payload["allowedDecisions"] as? [String] ?? [],
      host: string(payload["host"]),
      nodeID: string(payload["nodeId"]),
      agentID: string(payload["agentId"]),
      expiresAtMilliseconds: (payload["expiresAtMs"] as? NSNumber)?.doubleValue
    )
  }

  deinit {
    socket?.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }

  /// Releases URLSession-owned WebSocket resources as soon as a one-turn
  /// client leaves the workspace's active-client table. URLSession otherwise
  /// retains closed task descriptors until invalidation.
  public func shutdown() {
    guard !isShutdown else { return }
    isShutdown = true
    if let socket {
      socket.cancel(with: .goingAway, reason: nil)
      sessionDelegate.removeCloseInfo(for: socket)
    }
    self.socket = nil
    session.invalidateAndCancel()
  }

  public func send(
    message: String,
    attachments: [AIChatAttachment],
    agentID: String,
    sessionKey: String,
    model: String? = nil,
    reasoningEffort: String? = nil,
    idempotencyKey: String? = nil,
    requestStartedAt: Date? = nil,
    reconnectingAcceptedRun: Bool = false,
    onEvent: @escaping EventHandler
  ) async throws -> String {
    let requestStartedAtMilliseconds = (requestStartedAt ?? Date()).timeIntervalSince1970 * 1_000
    let requestIdempotencyKey = idempotencyKey ?? UUID().uuidString.lowercased()
    stopRequested = false
    runID = nil
    commentaryTextByItemID.removeAll(keepingCapacity: true)
    self.sessionKey = sessionKey
    self.agentID = agentID
    await onEvent(.connection(.connecting, nil))

    let socket = try await connectBeforeSending(
      scopes: Self.chatSendScopes(model: model, reasoningEffort: reasoningEffort),
      onEvent: onEvent
    )
    defer {
      failPendingSteerAcknowledgements(
        with: OpenClawGatewayError.protocolFailure("the active OpenClaw run ended before the steer was acknowledged")
      )
    }

    do {
      await onEvent(.connection(.connected, nil))

      if Self.shouldPatchSessionConfiguration(model: model, reasoningEffort: reasoningEffort) {
        do {
          try await patchSessionConfiguration(
            sessionKey: sessionKey,
            agentID: agentID,
            model: model,
            reasoningEffort: reasoningEffort,
            on: socket
          )
        } catch let OpenClawGatewayError.gateway(code, message) {
          throw OpenClawGatewayError.sessionConfigurationRejected(
            code: code,
            message: message
          )
        }
      }

      let proposedRunID = requestIdempotencyKey
      let sendID = UUID().uuidString.lowercased()
      var params: [String: Any] = [
        "sessionKey": sessionKey,
        "agentId": agentID,
        "message": message,
        "deliver": false,
        "timeoutMs": Int(OpenClawChatClient.requestTimeout * 1_000),
        "idempotencyKey": proposedRunID
      ]
      if !attachments.isEmpty {
        params["attachments"] = try attachments.map {
          [
            "type": $0.mimeType.hasPrefix("image/") ? "image" : "file",
            "fileName": $0.fileName,
            "mimeType": $0.mimeType,
            "content": try $0.loadData().base64EncodedString()
          ]
        }
      }
      try await sendRequest(id: sendID, method: "chat.send", params: params, on: socket)
      // Once bytes for chat.send have left the process, retrying through HTTP could
      // duplicate side effects. Reconcile this idempotency key instead.
      runID = proposedRunID

      var assembledText = ""
      var accepted = false
      while true {
        let frame = try await receiveObject(on: socket)
        if resolvePendingSteerAcknowledgement(from: frame) {
          continue
        }
        if Self.string(frame["type"]) == "res", Self.string(frame["id"]) == sendID {
          guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
          let payload = Self.dictionary(frame["payload"])
          let acceptedRunID = Self.string(payload?["runId"]) ?? proposedRunID
          runID = acceptedRunID
          accepted = true
          await onEvent(.accepted(runID: acceptedRunID))
          if Self.shouldReconcileAfterSendAcknowledgement(
            payload,
            reconnectingAcceptedRun: reconnectingAcceptedRun
          ) {
            return try await waitAndReconcile(
              runID: acceptedRunID,
              historyCorrelationID: proposedRunID,
              sessionKey: sessionKey,
              agentID: agentID,
              requestStartedAtMilliseconds: requestStartedAtMilliseconds,
              onEvent: onEvent,
              on: socket
            )
          }
          continue
        }
        guard Self.string(frame["type"]) == "event" else { continue }
        let eventName = Self.string(frame["event"]) ?? ""
        let payload = Self.dictionary(frame["payload"]) ?? [:]

        if eventName == "chat" {
          let eventRunID = Self.string(payload["runId"]) ?? ""
          guard eventRunID == (runID ?? proposedRunID) else { continue }
          let state = Self.string(payload["state"]) ?? ""
          if state == "delta" {
            let delta = Self.string(payload["deltaText"]) ?? ""
            let replace = Self.bool(payload["replace"]) ?? false
            if replace { assembledText = delta } else { assembledText += delta }
            if !delta.isEmpty { await onEvent(.text(delta, replace: replace)) }
          } else if state == "final" {
            if Self.isSteerAcknowledgement(payload["message"]) {
              // OpenClaw records a synthetic assistant message when /steer is
              // accepted. It belongs to the steer command, not to the active
              // turn whose run ID remains on the session.
              continue
            }
            let final = Self.messageText(payload["message"], includeThinking: false)
            if !final.isEmpty {
              assembledText = final
              await onEvent(.text(final, replace: true))
            }
            if let usage = Self.tokenUsage(from: payload) {
              await onEvent(.usage(usage))
            }
            socket.cancel(with: .normalClosure, reason: nil)
            let output = assembledText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw OpenClawGatewayError.emptyResponse }
            return output
          } else if state == "aborted" {
            throw OpenClawGatewayError.aborted(Self.string(payload["errorMessage"]))
          } else if state == "error" {
            throw OpenClawGatewayError.gateway(
              code: Self.string(payload["errorKind"]),
              message: Self.string(payload["errorMessage"]) ?? "OpenClaw run failed."
            )
          }
          continue
        }

        if eventName == "agent" {
          let eventRunID = Self.string(payload["runId"]) ?? ""
          guard eventRunID == (runID ?? proposedRunID) else { continue }
          if !accepted {
            runID = eventRunID
            accepted = true
            await onEvent(.accepted(runID: eventRunID))
          }
          if let event = Self.activity(from: payload) {
            await onEvent(.activity(event))
          }
          if Self.isContextCompaction(payload) {
            await onEvent(.contextCompacted)
          }
          if let event = Self.commentaryActivity(
            from: payload,
            accumulatedTextByItemID: &commentaryTextByItemID
          ) {
            await onEvent(.activity(event))
          }
          if let reasoning = Self.reasoning(from: payload), !reasoning.text.isEmpty {
            await onEvent(.reasoning(reasoning.text, replace: reasoning.replace))
          }
        }
      }
    } catch let error as OpenClawGatewayError {
      socket.cancel(with: .goingAway, reason: nil)
      if stopRequested {
        throw OpenClawGatewayError.aborted(nil)
      }
      if let runID, error.permitsHTTPFallback {
        return try await recoverAcceptedRunWithoutResending(
          runID: runID,
          historyCorrelationID: requestIdempotencyKey,
          sessionKey: sessionKey,
          agentID: agentID,
          requestStartedAtMilliseconds: requestStartedAtMilliseconds,
          onEvent: onEvent
        )
      }
      throw error
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      if stopRequested {
        throw OpenClawGatewayError.aborted(nil)
      }
      if let runID {
        return try await recoverAcceptedRunWithoutResending(
          runID: runID,
          historyCorrelationID: requestIdempotencyKey,
          sessionKey: sessionKey,
          agentID: agentID,
          requestStartedAtMilliseconds: requestStartedAtMilliseconds,
          onEvent: onEvent
        )
      }
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
  }

  /// Reattaches to a turn whose `chat.send` request was already accepted.
  /// Relaunch recovery must not submit the prompt again, even with the same
  /// idempotency key: the Gateway already gave us the durable run identifier.
  public func reconnectAcceptedRun(
    runID: String,
    idempotencyKey: String? = nil,
    sessionKey: String,
    agentID: String,
    requestStartedAt: Date,
    onEvent: @escaping EventHandler
  ) async throws -> String {
    stopRequested = false
    self.runID = runID
    self.sessionKey = sessionKey
    self.agentID = agentID
    return try await recoverAcceptedRunWithoutResending(
      runID: runID,
      historyCorrelationID: idempotencyKey ?? runID,
      sessionKey: sessionKey,
      agentID: agentID,
      requestStartedAtMilliseconds: requestStartedAt.timeIntervalSince1970 * 1_000,
      onEvent: onEvent
    )
  }

  static func shouldReconcileAfterSendAcknowledgement(
    _ payload: [String: Any]?,
    reconnectingAcceptedRun: Bool = false
  ) -> Bool {
    // A reconnect cannot rely on live chat events: the final frame may have
    // been broadcast while the app was closed. Every successful acknowledgement
    // therefore enters the durable agent.wait + chat.history reconciliation path,
    // regardless of the Gateway's status spelling.
    if reconnectingAcceptedRun { return true }
    guard let status = Self.string(payload?["status"])?.lowercased() else { return false }
    return status == "in_flight" || status == "ok"
  }

  private func recoverAcceptedRunWithoutResending(
    runID: String,
    historyCorrelationID: String,
    sessionKey: String,
    agentID: String,
    requestStartedAtMilliseconds: Double,
    onEvent: @escaping EventHandler
  ) async throws -> String {
    do {
      return try await recoverAcceptedRun(
        runID: runID,
        historyCorrelationID: historyCorrelationID,
        sessionKey: sessionKey,
        agentID: agentID,
        requestStartedAtMilliseconds: requestStartedAtMilliseconds,
        onEvent: onEvent
      )
    } catch let error as OpenClawGatewayError {
      if case .acceptedRunRecovery = error { throw error }
      if case .aborted = error { throw error }
      if case .acceptedRunTerminated = error { throw error }
      throw OpenClawGatewayError.acceptedRunRecovery(error.localizedDescription)
    } catch {
      throw OpenClawGatewayError.acceptedRunRecovery(error.localizedDescription)
    }
  }

  /// Injects guidance into the run already owned by this live Gateway client.
  /// The main receive loop consumes the acknowledgement and subsequent run
  /// events, so this method intentionally only writes the steer request.
  public func steer(
    message: String,
    attachments: [AIChatAttachment],
    idempotencyKey: String = UUID().uuidString.lowercased()
  ) async throws {
    guard let socket, let sessionKey, let agentID, runID != nil, !stopRequested else {
      throw OpenClawGatewayError.protocolFailure("there is no live OpenClaw run to steer")
    }
    let params = try Self.steerRequestParams(
      message: message,
      attachments: attachments,
      sessionKey: sessionKey,
      agentID: agentID,
      idempotencyKey: idempotencyKey
    )
    try await sendSteerRequest(params, on: socket)
  }

  private func sendSteerRequest(
    _ params: [String: Any],
    on socket: URLSessionWebSocketTask
  ) async throws {
    let requestID = UUID().uuidString.lowercased()
    outstandingSteerRequestIDs.insert(requestID)
    do {
      try await sendRequest(id: requestID, method: "chat.send", params: params, on: socket)
    } catch {
      outstandingSteerRequestIDs.remove(requestID)
      throw error
    }
    try await withCheckedThrowingContinuation { continuation in
      if let frame = earlySteerAcknowledgements.removeValue(forKey: requestID) {
        outstandingSteerRequestIDs.remove(requestID)
        if Self.bool(frame["ok"]) == true {
          continuation.resume()
        } else {
          continuation.resume(throwing: Self.gatewayError(from: frame))
        }
        return
      }
      pendingSteerAcknowledgements[requestID] = continuation
    }
  }

  /// The current OpenClaw Gateway dropped the chat.send `queueMode` parameter
  /// from its schema; steering injects a `/steer` message into the session. The
  /// earlier command form and the unused retry helper were removed because this
  /// is the only accepted wire shape.
  @discardableResult
  private func resolvePendingSteerAcknowledgement(from frame: [String: Any]) -> Bool {
    guard Self.string(frame["type"]) == "res",
          let requestID = Self.string(frame["id"]),
          outstandingSteerRequestIDs.contains(requestID)
    else {
      return false
    }
    guard let continuation = pendingSteerAcknowledgements.removeValue(forKey: requestID) else {
      earlySteerAcknowledgements[requestID] = frame
      return true
    }
    outstandingSteerRequestIDs.remove(requestID)
    if Self.bool(frame["ok"]) == true {
      continuation.resume()
    } else {
      continuation.resume(throwing: Self.gatewayError(from: frame))
    }
    return true
  }

  private func failPendingSteerAcknowledgements(with error: Error) {
    let continuations = pendingSteerAcknowledgements.values
    pendingSteerAcknowledgements.removeAll()
    outstandingSteerRequestIDs.removeAll()
    earlySteerAcknowledgements.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: error)
    }
  }

  nonisolated static func steerRequestParams(
    message: String,
    attachments: [AIChatAttachment],
    sessionKey: String,
    agentID: String,
    idempotencyKey: String
  ) throws -> [String: Any] {
    let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let command = trimmedMessage.isEmpty
      ? "/steer Use the attached context to adjust the active run."
      : "/steer \(message)"
    var params: [String: Any] = [
      "sessionKey": sessionKey,
      "agentId": agentID,
      "message": command,
      "deliver": false,
      "timeoutMs": Int(OpenClawChatClient.requestTimeout * 1_000),
      "idempotencyKey": idempotencyKey
    ]
    if !attachments.isEmpty {
      params["attachments"] = try attachments.map {
        [
          "type": $0.mimeType.hasPrefix("image/") ? "image" : "file",
          "fileName": $0.fileName,
          "mimeType": $0.mimeType,
          "content": try $0.loadData().base64EncodedString()
        ]
      }
    }
    return params
  }

  public func abort() async throws {
    guard let socket, let sessionKey else { return }
    stopRequested = true
    defer { socket.cancel(with: .goingAway, reason: nil) }
    try await sendRequest(
      id: UUID().uuidString.lowercased(),
      method: "chat.abort",
      params: Self.abortRequestParams(sessionKey: sessionKey, agentID: agentID),
      on: socket
    )
    // The live receive loop owns response consumption for this socket. Give the
    // Gateway a brief chance to emit its aborted event, then close locally so a
    // reconnected or orphaned run can never leave the UI stuck in Sending.
    try? await Task.sleep(for: .milliseconds(250))
  }

  nonisolated static func abortRequestParams(
    sessionKey: String,
    agentID: String?
  ) -> [String: Any] {
    var params: [String: Any] = ["sessionKey": sessionKey, "preserveSideRuns": true]
    if let agentID { params["agentId"] = agentID }
    return params
  }

  nonisolated static func sessionConfigurationPatchParams(
    sessionKey: String,
    agentID: String,
    model: String?,
    reasoningEffort: String?
  ) -> [String: Any] {
    [
      "key": sessionKey,
      "agentId": agentID,
      "model": model ?? NSNull(),
      "thinkingLevel": reasoningEffort ?? NSNull()
    ]
  }

  nonisolated static func shouldPatchSessionConfiguration(
    model: String?,
    reasoningEffort: String?
  ) -> Bool {
    model != nil || reasoningEffort != nil
  }

  nonisolated static func chatSendScopes(
    model: String?,
    reasoningEffort: String?
  ) -> [String] {
    var scopes = ["operator.read", "operator.write"]
    if shouldPatchSessionConfiguration(model: model, reasoningEffort: reasoningEffort) {
      scopes.append("operator.admin")
    }
    return scopes
  }

  private func patchSessionConfiguration(
    sessionKey: String,
    agentID: String,
    model: String?,
    reasoningEffort: String?,
    on socket: URLSessionWebSocketTask
  ) async throws {
    let requestID = UUID().uuidString.lowercased()
    try await sendRequest(
      id: requestID,
      method: "sessions.patch",
      params: Self.sessionConfigurationPatchParams(
        sessionKey: sessionKey,
        agentID: agentID,
        model: model,
        reasoningEffort: reasoningEffort
      ),
      on: socket
    )
    while true {
      let frame = try await receiveObject(on: socket)
      guard Self.string(frame["type"]) == "res",
            Self.string(frame["id"]) == requestID
      else {
        continue
      }
      guard Self.bool(frame["ok"]) == true else {
        throw Self.gatewayError(from: frame)
      }
      return
    }
  }

  private func requestPayload(
    method: String,
    params: [String: Any],
    scopes: [String] = ["operator.read", "operator.write"]
  ) async throws -> [String: Any] {
    let socket = try makeSocket()
    self.socket = socket
    socket.resume()
    do {
      try await establishConnection(on: socket, scopes: scopes)
      let requestID = UUID().uuidString.lowercased()
      try await sendRequest(id: requestID, method: method, params: params, on: socket)
      while true {
        let frame = try await receiveObject(on: socket)
        guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == requestID else { continue }
        guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
        let payload = Self.dictionary(frame["payload"]) ?? [:]
        socket.cancel(with: .normalClosure, reason: nil)
        return payload
      }
    } catch let error as OpenClawGatewayError {
      socket.cancel(with: .goingAway, reason: nil)
      throw error
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
  }

  nonisolated private static func sessionConfiguration(
    from value: [String: Any]
  ) -> OpenClawAIChatSessionConfiguration {
    let provider = string(value["modelProvider"])
    let rawModel = string(value["model"])
    let model = rawModel.map { raw in
      guard !raw.contains("/"), let provider else { return raw }
      return "\(provider)/\(raw)"
    }
    let reasoningOptions = (value["thinkingLevels"] as? [[String: Any]] ?? [])
      .compactMap { option -> AIChatReasoningOption? in
        guard let id = string(option["id"]) else { return nil }
        return AIChatReasoningOption(
          id: id,
          label: string(option["label"]) ?? reasoningLabel(id)
        )
      }
    return OpenClawAIChatSessionConfiguration(
      model: model,
      reasoningEffort: string(value["thinkingLevel"]),
      reasoningOptions: reasoningOptions,
      defaultReasoningEffort: string(value["thinkingDefault"])
    )
  }

  nonisolated private static func reasoningLabel(_ value: String) -> String {
    switch value.lowercased() {
    case "off", "none": return "Off"
    case "minimal": return "Minimal"
    case "low": return "Low"
    case "medium": return "Medium"
    case "high": return "High"
    case "xhigh": return "Extra high"
    case "max": return "Maximum"
    case "ultra": return "Ultra"
    case "adaptive": return "Adaptive"
    default: return value.capitalized
    }
  }

  private func makeSocket() throws -> URLSessionWebSocketTask {
    guard var components = URLComponents(url: settings.endpoint, resolvingAgainstBaseURL: false) else {
      throw OpenClawGatewayError.invalidEndpoint
    }
    switch components.scheme?.lowercased() {
    case "https": components.scheme = "wss"
    case "http": components.scheme = "ws"
    case "wss", "ws": break
    default: throw OpenClawGatewayError.invalidEndpoint
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw OpenClawGatewayError.invalidEndpoint }
    return session.webSocketTask(with: url)
  }

  private func awaitChallenge(on socket: URLSessionWebSocketTask) async throws -> String {
    let frame = try await receiveObject(on: socket)
    guard Self.string(frame["type"]) == "event",
          Self.string(frame["event"]) == "connect.challenge",
          let nonce = Self.string(Self.dictionary(frame["payload"])?["nonce"]),
          !nonce.isEmpty
    else {
      throw OpenClawGatewayError.protocolFailure("expected connect.challenge")
    }
    return nonce
  }

  /// Opens a handshaken socket for a new message. Until chat.send leaves this process
  /// nothing can have been delivered, so a refused, dropped, or stalled connection is
  /// retried for a bounded time rather than failing a message the Gateway never saw.
  private func connectBeforeSending(
    scopes: [String],
    onEvent: @escaping EventHandler
  ) async throws -> URLSessionWebSocketTask {
    var attempt = 0
    while true {
      let socket = try makeSocket()
      self.socket = socket
      socket.resume()
      do {
        try await establishConnection(on: socket, scopes: scopes)
        return socket
      } catch {
        socket.cancel(with: .goingAway, reason: nil)
        sessionDelegate.removeCloseInfo(for: socket)
        let failure = (error as? OpenClawGatewayError)
          ?? OpenClawGatewayError.connection(error.localizedDescription)
        if stopRequested || isShutdown { throw OpenClawGatewayError.aborted(nil) }
        guard Self.shouldRetryBeforeSending(after: failure),
              attempt < preSendReconnectDelays.count
        else { throw failure }
        let delay = preSendReconnectDelays[attempt]
        attempt += 1
        await onEvent(.connection(
          .reconnecting,
          "The OpenClaw Gateway is not responding (\(failure.localizedDescription)). Retrying; nothing has been sent yet."
        ))
        try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
        if stopRequested || isShutdown { throw OpenClawGatewayError.aborted(nil) }
      }
    }
  }

  /// Only transport failures are retried. A Gateway answer such as NOT_PAIRED or a
  /// rejected request is definitive and must surface immediately.
  static func shouldRetryBeforeSending(after error: OpenClawGatewayError) -> Bool {
    if case .connection = error { return true }
    return false
  }

  private func establishConnection(
    on socket: URLSessionWebSocketTask,
    scopes: [String] = ["operator.read", "operator.write"]
  ) async throws {
    let socketID = ObjectIdentifier(socket)
    let timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(Self.connectionAttemptTimeout))
      } catch {
        return
      }
      await self?.markTimedOut(socketID)
      let reason = "OpenClaw Gateway connection timed out after \(Int(Self.connectionAttemptTimeout)) seconds."
      socket.cancel(with: .goingAway, reason: Data(reason.utf8))
    }
    defer {
      timeoutTask.cancel()
      timedOutSockets.remove(socketID)
    }
    do {
      let nonce = try await awaitChallenge(on: socket)
      try await connect(on: socket, nonce: nonce, scopes: scopes)
    } catch {
      // A local cancel reports only "cancelled"; say what actually happened.
      if timedOutSockets.contains(socketID) {
        throw OpenClawGatewayError.connection(
          "the Gateway did not answer the handshake within \(Int(Self.connectionAttemptTimeout)) seconds"
        )
      }
      throw error
    }
  }

  private func markTimedOut(_ socketID: ObjectIdentifier) {
    timedOutSockets.insert(socketID)
  }

  private func connect(
    on socket: URLSessionWebSocketTask,
    nonce: String,
    scopes: [String] = ["operator.read", "operator.write"]
  ) async throws {
    let requestID = UUID().uuidString.lowercased()
    let identity = try OpenClawDeviceIdentity.loadOrCreate(
      fileURL: settings.deviceIdentityFileURL
    )
    deviceID = identity.deviceID
    let signedAt = Int(Date().timeIntervalSince1970 * 1_000)
    let signatureToken = settings.bearerToken ?? ""
    let signaturePayload = [
      "v3",
      identity.deviceID,
      "openclaw-macos",
      "ui",
      "operator",
      scopes.joined(separator: ","),
      String(signedAt),
      signatureToken,
      nonce,
      "darwin",
      "mac"
    ].joined(separator: "|")
    var params: [String: Any] = [
      "minProtocol": 4,
      "maxProtocol": 4,
      "client": [
        "id": "openclaw-macos",
        "displayName": WorkspaceProductIdentity.displayName,
        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        "platform": "darwin",
        "deviceFamily": "Mac",
        "mode": "ui"
      ],
      "caps": ["tool-events"],
      "role": "operator",
      "scopes": scopes,
      "locale": Locale.current.identifier,
      "device": [
        "id": identity.deviceID,
        "publicKey": identity.publicKeyBase64URL,
        "signature": try identity.signature(for: signaturePayload),
        "signedAt": signedAt,
        "nonce": nonce
      ]
    ]
    if let token = settings.bearerToken { params["auth"] = ["token": token] }
    awaitingHello = true
    defer { awaitingHello = false }
    try await sendRequest(id: requestID, method: "connect", params: params, on: socket)
    while true {
      let frame = try await receiveObject(on: socket)
      guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == requestID else { continue }
      guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
      let payload = Self.dictionary(frame["payload"])
      guard Self.string(payload?["type"]) == "hello-ok" else {
        throw OpenClawGatewayError.protocolFailure("connect did not return hello-ok")
      }
      return
    }
  }

  private func recoverAcceptedRun(
    runID: String,
    historyCorrelationID: String,
    sessionKey: String,
    agentID: String,
    requestStartedAtMilliseconds: Double,
    onEvent: @escaping EventHandler
  ) async throws -> String {
    await onEvent(.connection(.reconnecting, "The run was already accepted; reconnecting without resending it."))
    var lastError: Error?
    for attempt in 1...5 {
      await OpenClawRecoveryConnectionLimiter.shared.acquire()
      do {
        defer { Task { await OpenClawRecoveryConnectionLimiter.shared.release() } }
        let backoffMilliseconds = attempt > 1 ? min(attempt * 2_000, 8_000) : 0
        let jitterMilliseconds = Int.random(in: 50...750)
        try await Task.sleep(for: .milliseconds(backoffMilliseconds + jitterMilliseconds))
        let nextSocket = try makeSocket()
        socket = nextSocket
        nextSocket.resume()
        try await establishConnection(on: nextSocket)
        await onEvent(.connection(.connected, "Reconnected to accepted run \(String(runID.prefix(8)))."))
        return try await waitAndReconcile(
          runID: runID,
          historyCorrelationID: historyCorrelationID,
          sessionKey: sessionKey,
          agentID: agentID,
          requestStartedAtMilliseconds: requestStartedAtMilliseconds,
          onEvent: onEvent,
          on: nextSocket
        )
      } catch let error as OpenClawGatewayError {
        if stopRequested { throw OpenClawGatewayError.aborted(nil) }
        if case .acceptedRunTerminated = error { throw error }
        if case .aborted = error { throw error }
        lastError = error
        if let failedSocket = socket {
          failedSocket.cancel(with: .goingAway, reason: nil)
          sessionDelegate.removeCloseInfo(for: failedSocket)
        }
        socket = nil
        await onEvent(.connection(.reconnecting, "Reconnect attempt \(attempt) failed."))
      }
    }
    await onEvent(.connection(.disconnected, "The accepted run may still be working on the Gateway."))
    throw OpenClawGatewayError.connection(
      "lost contact after the run was accepted; OpenClaw may still be working (\(lastError?.localizedDescription ?? "reconnect failed"))"
    )
  }

  private func waitAndReconcile(
    runID: String,
    historyCorrelationID: String,
    sessionKey: String,
    agentID: String,
    requestStartedAtMilliseconds: Double,
    onEvent: @escaping EventHandler,
    on socket: URLSessionWebSocketTask
  ) async throws -> String {
    let deadline = Date().addingTimeInterval(OpenClawChatClient.requestTimeout)
    var waitRunID = runID
    var observedRunIDs: Set<String> = [runID]
    var terminalPollsWithoutReply = 0
    while Date() < deadline {
      let waitID = UUID().uuidString.lowercased()
      try await sendRequest(
        id: waitID,
        method: "agent.wait",
        params: ["runId": waitRunID, "timeoutMs": Self.acceptedRunRecoveryPollTimeoutMilliseconds],
        on: socket
      )
      while true {
        let frame = try await receiveObject(on: socket)
        if Self.string(frame["type"]) == "event",
           Self.string(frame["event"]) == "agent" {
          let eventPayload = Self.dictionary(frame["payload"]) ?? [:]
          let eventRunID = Self.string(eventPayload["runId"]) ?? ""
          guard observedRunIDs.contains(eventRunID) else { continue }
          if let activity = Self.activity(from: eventPayload) {
            await onEvent(.activity(activity))
          }
          if let commentary = Self.commentaryActivity(
            from: eventPayload,
            accumulatedTextByItemID: &commentaryTextByItemID
          ) {
            await onEvent(.activity(commentary))
          }
          if let reasoning = Self.reasoning(from: eventPayload), !reasoning.text.isEmpty {
            await onEvent(.reasoning(reasoning.text, replace: reasoning.replace))
          }
          continue
        }
        guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == waitID else { continue }
        guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
        let payload = Self.dictionary(frame["payload"]) ?? [:]
        let status = Self.string(payload["status"]) ?? "timeout"
        let reconciliation = try await loadReconciledSession(
          historyCorrelationID: historyCorrelationID,
          sessionKey: sessionKey,
          agentID: agentID,
          requestStartedAtMilliseconds: requestStartedAtMilliseconds,
          on: socket
        )
        await onEvent(.reconciliationHeartbeat)
        switch reconciliation {
        case .completed(let reply):
          return reply
        case .failed(let message):
          throw OpenClawGatewayError.acceptedRunTerminated(message)
        case .pending(let hasActiveRun, let activeRunIDs):
          observedRunIDs.formUnion(activeRunIDs)
          if let activeRunID = activeRunIDs.last {
            waitRunID = activeRunID
          }
          if status == "error", !hasActiveRun {
            throw OpenClawGatewayError.acceptedRunTerminated(
              Self.string(payload["error"]) ?? "OpenClaw run failed after reconnecting."
            )
          }
          if status == "ok", !hasActiveRun {
            terminalPollsWithoutReply += 1
            if terminalPollsWithoutReply >= 3 {
              throw OpenClawGatewayError.acceptedRunTerminated("OpenClaw finished without a response.")
            }
          } else {
            terminalPollsWithoutReply = 0
          }
          break
        }
        break
      }
    }
    throw OpenClawGatewayError.gateway(code: "timeout", message: "OpenClaw run timed out.")
  }

  private func loadReconciledSession(
    historyCorrelationID: String,
    sessionKey: String,
    agentID: String,
    requestStartedAtMilliseconds: Double,
    on socket: URLSessionWebSocketTask
  ) async throws -> OpenClawChatHistoryReconciliation {
    let historyID = UUID().uuidString.lowercased()
    try await sendRequest(
      id: historyID,
      method: "chat.history",
      params: ["sessionKey": sessionKey, "agentId": agentID, "limit": 100, "maxChars": 100_000],
      on: socket
    )
    while true {
      let frame = try await receiveObject(on: socket)
      guard Self.string(frame["type"]) == "res", Self.string(frame["id"]) == historyID else { continue }
      guard Self.bool(frame["ok"]) == true else { throw Self.gatewayError(from: frame) }
      let payload = Self.dictionary(frame["payload"]) ?? [:]
      return Self.chatHistoryReconciliation(
        from: payload,
        runID: historyCorrelationID,
        requestStartedAtMilliseconds: requestStartedAtMilliseconds
      )
    }
  }

  static func chatHistoryReconciliation(
    from payload: [String: Any],
    runID: String,
    requestStartedAtMilliseconds: Double
  ) -> OpenClawChatHistoryReconciliation {
    let messages = payload["messages"] as? [Any] ?? []
    let requestMarker = "\(runID):user"
    let requestIndex = messages.lastIndex { value in
      guard let message = dictionary(value) else { return false }
      if string(message["idempotencyKey"]) == requestMarker { return true }
      return string(dictionary(message["__openclaw"])?["idempotencyKey"]) == requestMarker
    }

    // Timestamps cannot safely identify a turn when the request marker has
    // fallen outside the bounded history window. Another client may have sent
    // a later turn on the same session, so remain unreconciled instead of
    // attaching an arbitrary assistant response.
    let candidateMessages: [Any] = requestIndex.map {
      Array(messages.suffix(from: messages.index(after: $0)))
    } ?? []

    for value in candidateMessages.reversed() {
      guard let message = dictionary(value), string(message["role"]) == "assistant" else { continue }
      if isSteerAcknowledgement(message) { continue }
      let text = messageText(message, includeThinking: false)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { return .completed(text) }
    }

    let sessionInfo = dictionary(payload["sessionInfo"]) ?? [:]
    let activeRunIDs = (sessionInfo["activeRunIds"] as? [Any] ?? [])
      .compactMap(string)
    let hasActiveRun = bool(sessionInfo["hasActiveRun"]) ?? !activeRunIDs.isEmpty
    let status = string(sessionInfo["status"])?.lowercased() ?? ""
    let terminalStatuses = Set(["done", "completed", "succeeded", "failed", "error", "aborted", "cancelled", "canceled", "timed_out"])
    let belongsToRequest = requestIndex != nil

    guard !hasActiveRun, terminalStatuses.contains(status), belongsToRequest else {
      return .pending(hasActiveRun: hasActiveRun, activeRunIDs: activeRunIDs)
    }
    if status == "done" || status == "completed" || status == "succeeded" {
      return .failed("OpenClaw finished without a response.")
    }
    return .failed("OpenClaw session ended with status \(status).")
  }

  static func isSteerAcknowledgement(_ value: Any?) -> Bool {
    guard let message = dictionary(value),
          string(message["role"]) == "assistant",
          string(message["provider"]) == "openclaw",
          string(message["model"]) == "gateway-injected"
    else {
      return false
    }
    return messageText(message, includeThinking: false)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() == "steered current session."
  }

  private func sendRequest(
    id: String,
    method: String,
    params: [String: Any],
    on socket: URLSessionWebSocketTask
  ) async throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "type": "req",
      "id": id,
      "method": method,
      "params": params
    ])
    guard let text = String(data: data, encoding: .utf8) else {
      throw OpenClawGatewayError.protocolFailure("could not encode request")
    }
    try await socket.send(.string(text))
  }

  private func receiveObject(on socket: URLSessionWebSocketTask) async throws -> [String: Any] {
    let message: URLSessionWebSocketTask.Message
    do {
      message = try await socket.receive()
    } catch {
      // OpenClaw replies with a structured pairing error and immediately closes
      // the socket. URLSession can report the close before delivering that last
      // response frame, but it preserves the useful reason on the task.
      var delegateCloseInfo: OpenClawWebSocketSessionDelegate.CloseInfo?
      for _ in 0..<5 where delegateCloseInfo == nil {
        delegateCloseInfo = sessionDelegate.takeCloseInfo(for: socket)
        if delegateCloseInfo == nil { try? await Task.sleep(for: .milliseconds(50)) }
      }
      if let reasonData = socket.closeReason ?? delegateCloseInfo?.reason,
         let reason = String(data: reasonData, encoding: .utf8),
         !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw Self.gatewayError(fromCloseReason: reason, deviceID: deviceID)
      }
      if awaitingHello, let deviceID {
        throw Self.gatewayHandshakeClosedError(deviceID: deviceID)
      }
      throw OpenClawGatewayError.connection(error.localizedDescription)
    }
    let data: Data
    switch message {
    case .string(let text): data = Data(text.utf8)
    case .data(let value): data = value
    @unknown default: throw OpenClawGatewayError.protocolFailure("unsupported WebSocket frame")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OpenClawGatewayError.protocolFailure("invalid JSON frame")
    }
    return object
  }

  private static func gatewayError(from frame: [String: Any]) -> OpenClawGatewayError {
    let error = dictionary(frame["error"])
    let code = string(error?["code"])
    let details = dictionary(error?["details"])
    let requestID = string(details?["requestId"])
    var message = string(error?["message"]) ?? "The OpenClaw Gateway rejected the request."
    if code == "NOT_PAIRED", let requestID {
      message += " Approve Celorga device request \(requestID) on the Gateway, then send again."
    }
    return .gateway(
      code: code,
      message: message
    )
  }

  static func gatewayError(fromCloseReason reason: String, deviceID: String? = nil) -> OpenClawGatewayError {
    let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.localizedCaseInsensitiveContains("pairing required")
      || normalized.localizedCaseInsensitiveContains("upgrade pending approval") {
      let requestID = firstMatch(in: normalized, pattern: #"\(requestId:\s*([^\s\)]+)\)"#)
      var message = normalized
      if let requestID {
        message += " Approve Celorga request \(requestID) on the Gateway"
      } else {
        message += " Approve the pending Celorga device request on the Gateway"
      }
      if let deviceID, !deviceID.isEmpty {
        message += " (device \(deviceID.prefix(12)))"
      }
      message += ", then click Save & Request Pairing again."
      return .gateway(code: "NOT_PAIRED", message: message)
    }
    return .connection(normalized)
  }

  static func gatewayHandshakeClosedError(deviceID: String) -> OpenClawGatewayError {
    .gateway(
      code: "NOT_PAIRED",
      message: "OpenClaw closed the signed device handshake before macOS delivered its final reason. "
        + "Approve the pending Celorga request for device \(deviceID.prefix(12)) on the Gateway, "
        + "then click Save & Request Pairing again."
    )
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
          ),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  static func activity(from payload: [String: Any]) -> AIChatRunActivity? {
    let runID = string(payload["runId"]) ?? ""
    let stream = string(payload["stream"]) ?? ""
    let data = dictionary(payload["data"]) ?? [:]
    if stream == "tool" {
      let callID = string(data["toolCallId"]) ?? UUID().uuidString
      let name = string(data["name"]) ?? "Tool"
      let phase = string(data["phase"]) ?? "start"
      let status: AIChatRunActivity.Status = phase == "result"
        ? ((bool(data["isError"]) ?? false) ? .failed : .succeeded)
        : .running
      let detailValue = phase == "start" ? data["args"] : (data["partialResult"] ?? data["result"])
      return AIChatRunActivity(
        id: "tool:\(callID)", runID: runID, kind: .tool, title: name,
        detail: compactDescription(detailValue), status: status
      )
    }
    if stream == "lifecycle" {
      let phase = string(data["phase"]) ?? "running"
      let status: AIChatRunActivity.Status = phase == "error" ? .failed : (phase == "end" ? .succeeded : .running)
      let title = phase == "finishing" ? "Finishing context" : (phase == "start" ? "Agent started" : "Agent \(phase)")
      return AIChatRunActivity(
        id: "lifecycle:\(runID)", runID: runID, kind: .lifecycle, title: title,
        detail: string(data["error"]) ?? string(data["errorMessage"]), status: status
      )
    }
    if stream == "item", string(data["kind"]) == "preamble" {
      let itemID = (string(data["itemId"]) ?? string(data["id"]) ?? "latest")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let progressText = (string(data["progressText"]) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !progressText.isEmpty else { return nil }
      return AIChatRunActivity(
        id: "preamble:\(itemID.isEmpty ? "latest" : itemID)",
        runID: runID, kind: .reasoning, title: "Progress update",
        detail: progressText, status: .succeeded
      )
    }
    return nil
  }

  static func tokenUsage(from payload: [String: Any]) -> AIChatTokenUsage? {
    let message = dictionary(payload["message"])
    guard let usage = dictionary(payload["usage"])
      ?? dictionary(message?["usage"])
    else { return nil }
    func tokens(_ names: [String]) -> Int {
      for name in names {
        if let value = milliseconds(usage[name]) { return max(0, Int(value)) }
      }
      return 0
    }
    let input = tokens(["input", "inputTokens", "promptTokens"])
    let cached = tokens(["cacheRead", "cachedInputTokens", "cachedTokens"])
    let output = tokens(["output", "outputTokens", "completionTokens"])
    let total = tokens(["totalTokens", "total"])
    guard input > 0 || cached > 0 || output > 0 || total > 0 else { return nil }
    return AIChatTokenUsage(
      inputTokens: input,
      cachedInputTokens: cached,
      outputTokens: output,
      totalTokens: total > 0 ? total : nil
    )
  }

  static func isContextCompaction(_ payload: [String: Any]) -> Bool {
    let stream = string(payload["stream"]) ?? ""
    let data = dictionary(payload["data"]) ?? [:]
    if stream == "compaction" { return true }
    guard stream == "lifecycle" else { return false }
    if bool(data["contextCompacted"]) == true { return true }
    return (string(data["phase"]) ?? "").lowercased().contains("compact")
  }

  static func commentaryActivity(
    from payload: [String: Any],
    accumulatedTextByItemID: inout [String: String]
  ) -> AIChatRunActivity? {
    let stream = string(payload["stream"]) ?? ""
    let data = dictionary(payload["data"]) ?? [:]
    guard stream == "assistant", string(data["phase"]) == "commentary" else { return nil }

    let runID = string(payload["runId"]) ?? ""
    let itemID = (string(data["itemId"]) ?? string(data["id"]) ?? "latest")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedItemID = itemID.isEmpty ? "latest" : itemID
    let accumulationKey = "\(runID):\(normalizedItemID)"
    let previous = accumulatedTextByItemID[accumulationKey] ?? ""
    let snapshot = string(data["text"]) ?? ""
    let delta = string(data["delta"]) ?? ""
    let next: String
    if bool(data["replace"]) == true {
      next = snapshot.isEmpty ? delta : snapshot
    } else if !snapshot.isEmpty, delta.isEmpty || snapshot.hasPrefix(previous) {
      next = snapshot
    } else if !delta.isEmpty {
      next = previous + delta
    } else {
      next = snapshot
    }
    accumulatedTextByItemID[accumulationKey] = next

    let progressText = next.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !progressText.isEmpty else { return nil }
    return AIChatRunActivity(
      id: "preamble:\(normalizedItemID)",
      runID: runID,
      kind: .reasoning,
      title: "Progress update",
      detail: progressText,
      status: .succeeded
    )
  }

  private static func reasoning(from payload: [String: Any]) -> (text: String, replace: Bool)? {
    let stream = string(payload["stream"]) ?? ""
    guard stream == "thinking" || stream == "reasoning" else { return nil }
    let data = dictionary(payload["data"]) ?? [:]
    let text = string(data["delta"]) ?? string(data["text"]) ?? ""
    return (text, bool(data["replace"]) ?? false)
  }

  static func messageText(_ value: Any?, includeThinking: Bool) -> String {
    guard let value else { return "" }
    if let text = value as? String { return text }
    guard let message = dictionary(value) else { return "" }
    if let content = message["content"] as? String { return content }
    guard let blocks = message["content"] as? [Any] else {
      return string(message["text"]) ?? ""
    }
    return blocks.compactMap { block -> String? in
      guard let block = dictionary(block) else { return nil }
      let type = string(block["type"]) ?? "text"
      guard type == "text" || (includeThinking && (type == "thinking" || type == "reasoning")) else { return nil }
      return string(block["text"]) ?? string(block["thinking"])
    }.joined(separator: "\n")
  }

  private static func compactDescription(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let string = value as? String { return String(string.prefix(2_000)) }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else { return String(describing: value) }
    return String(text.prefix(2_000))
  }

  private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
  private static func string(_ value: Any?) -> String? { value as? String }
  private static func bool(_ value: Any?) -> Bool? { value as? Bool }
  private static func milliseconds(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? String { return Double(value) }
    return nil
  }
}
