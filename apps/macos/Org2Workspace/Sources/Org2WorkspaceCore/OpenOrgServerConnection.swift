import Foundation
import Network
import Observation
import Security

// MARK: - Share location

/// Where a new live thread link is hosted.
public enum ChatThreadShareLocation: String, CaseIterable, Identifiable, Sendable {
  /// This Mac's local publication server. The link works while this Mac is awake.
  case thisMac = "mac"
  /// The paired headless OpenOrg server, which keeps the link live on its own.
  case server

  public var id: String { rawValue }
}

// MARK: - Records

/// A pairing between this Mac and one headless OpenOrg server. The access
/// token lives in the Keychain, never in this record.
public struct OpenOrgServerPairing: Codable, Hashable, Sendable {
  public let endpoint: String
  public let serverName: String
  public let hostRef: String?
  public let deviceID: UUID
  public let pairedAt: Date

  public init(endpoint: String, serverName: String, hostRef: String?, deviceID: UUID, pairedAt: Date) {
    self.endpoint = endpoint
    self.serverName = serverName
    self.hostRef = hostRef
    self.deviceID = deviceID
    self.pairedAt = pairedAt
  }
}

/// A thread link the paired server hosts. The URL is a bearer secret, so it
/// stays in machine-local preferences and never enters the corpus.
public struct OpenOrgServerThreadShare: Codable, Hashable, Sendable, Identifiable {
  public let threadID: UUID
  public let url: URL
  public let sharedAt: Date
  public let endpoint: String
  public let serverName: String

  public var id: UUID { threadID }

  public init(threadID: UUID, url: URL, sharedAt: Date, endpoint: String, serverName: String) {
    self.threadID = threadID
    self.url = url
    self.sharedAt = sharedAt
    self.endpoint = endpoint
    self.serverName = serverName
  }
}

/// What a pasted pairing field contains: an endpoint, and possibly a code and
/// name when it is the `org2-remote://pair` link that `org2 server pair` prints.
public struct OpenOrgServerPairingInput: Equatable, Sendable {
  public let endpoint: String
  public let code: String?
  public let name: String?

  public static func parse(_ text: String) -> OpenOrgServerPairingInput? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let components = URLComponents(string: trimmed),
       components.scheme?.lowercased() == "org2-remote",
       components.host?.lowercased() == "pair" {
      let items = components.queryItems ?? []
      func value(_ name: String) -> String? {
        items.first { $0.name == name }?.value?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .nilIfEmpty
      }
      guard let endpoint = value("endpoint").flatMap(OpenOrgServerEndpoint.normalized) else { return nil }
      return OpenOrgServerPairingInput(endpoint: endpoint, code: value("code"), name: value("name"))
    }
    guard let endpoint = OpenOrgServerEndpoint.normalized(trimmed) else { return nil }
    return OpenOrgServerPairingInput(endpoint: endpoint, code: nil, name: nil)
  }
}

public enum OpenOrgServerEndpoint {
  /// Returns `http://host:port` for a server address, adding the scheme and
  /// Mobile Remote default port when they are omitted.
  public static func normalized(_ text: String) -> String? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if !trimmed.contains("://") {
      trimmed = "http://" + trimmed
    }
    guard var components = URLComponents(string: trimmed),
          components.scheme?.lowercased() == "http",
          let host = components.host?.lowercased(),
          isAllowedHost(host),
          components.user == nil,
          components.password == nil,
          components.path.isEmpty || components.path == "/",
          components.query == nil,
          components.fragment == nil
    else {
      return nil
    }
    components.scheme = "http"
    components.host = host
    if components.port == nil {
      components.port = Int(MobileRemoteProtocol.defaultPort)
    }
    guard let port = components.port, (1...65_535).contains(port) else { return nil }
    components.path = ""
    return components.string
  }

  private static func isAllowedHost(_ host: String) -> Bool {
    if host == "localhost" { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
    guard host.count <= 253, !host.contains("..") else { return false }
    return parts.allSatisfy { label in
      guard !label.isEmpty, label.count <= 63,
            label.first?.isASCII == true, label.first?.isLetter == true || label.first?.isNumber == true,
            label.last?.isASCII == true, label.last?.isLetter == true || label.last?.isNumber == true
      else { return false }
      return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
  }
}

// MARK: - Credentials

public protocol OpenOrgServerCredentialStoring: AnyObject, Sendable {
  func token(for deviceID: UUID) -> String?
  func setToken(_ token: String, for deviceID: UUID) throws
  func removeToken(for deviceID: UUID)
}

/// Keeps the server access token in this Mac's login Keychain.
public final class OpenOrgServerKeychainCredentials: OpenOrgServerCredentialStoring, @unchecked Sendable {
  private let service: String

  public init(service: String? = nil) {
    self.service = service
      ?? (Bundle.main.bundleIdentifier ?? "org.org2.workspace") + ".openorg-server"
  }

  public func token(for deviceID: UUID) -> String? {
    var query = baseQuery(deviceID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func setToken(_ token: String, for deviceID: UUID) throws {
    let query = baseQuery(deviceID)
    let attributes: [String: Any] = [
      kSecValueData as String: Data(token.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var addition = query
      attributes.forEach { addition[$0.key] = $0.value }
      let added = SecItemAdd(addition as CFDictionary, nil)
      guard added == errSecSuccess else { throw OpenOrgServerError.keychain(added) }
    } else if status != errSecSuccess {
      throw OpenOrgServerError.keychain(status)
    }
  }

  public func removeToken(for deviceID: UUID) {
    SecItemDelete(baseQuery(deviceID) as CFDictionary)
  }

  private func baseQuery(_ deviceID: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: deviceID.uuidString.lowercased(),
    ]
  }
}

/// Process-local credentials for tests and previews.
public final class OpenOrgServerMemoryCredentials: OpenOrgServerCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [UUID: String] = [:]

  public init() {}

  public func token(for deviceID: UUID) -> String? {
    lock.withLock { tokens[deviceID] }
  }

  public func setToken(_ token: String, for deviceID: UUID) throws {
    lock.withLock { tokens[deviceID] = token }
  }

  public func removeToken(for deviceID: UUID) {
    lock.withLock { tokens[deviceID] = nil }
  }
}

// MARK: - Errors

public enum OpenOrgServerError: LocalizedError, Equatable, Sendable {
  case invalidEndpoint
  case missingCode
  case notPaired
  case connection(String)
  case malformedResponse
  case server(String, statusCode: Int)
  case unsupported
  case sourcesUnsupported
  case threadNotOnServer(String)
  case keychain(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "Enter the server address, such as http://100.64.0.1:48922, or paste the pairing link from “celorga server pair”."
    case .missingCode:
      "Enter the six-digit pairing code from “celorga server pair”."
    case .notPaired:
      "Pair this Mac with a Celorga server in Settings → Sharing first."
    case .connection(let detail):
      "Could not reach the Celorga server: \(detail)"
    case .malformedResponse:
      "The Celorga server returned an unreadable response."
    case .server(let message, _):
      message
    case .unsupported:
      "This Celorga server cannot host thread links yet. Update and restart it, then try again."
    case .sourcesUnsupported:
      "This Celorga server cannot receive source sign-ins or run source syncs yet. Update and restart it, then try again."
    case .threadNotOnServer(let server):
      "\(server) doesn’t have this thread yet. Wait for the corpus to sync to the server, then try again."
    case .keychain(let status):
      "Could not save the server credential in the Keychain (error \(status))."
    }
  }
}

// MARK: - Transport

public struct OpenOrgServerHTTPResponse: Sendable {
  public let statusCode: Int
  public let body: Data

  public init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }
}

public struct OpenOrgServerHTTPRequest: Sendable {
  public let endpoint: String
  public let method: String
  public let path: String
  public let accessToken: String?
  public let body: Data?
  public let timeout: TimeInterval
}

public typealias OpenOrgServerTransport = @Sendable (OpenOrgServerHTTPRequest) async throws -> OpenOrgServerHTTPResponse

enum OpenOrgServerNetworkTransport {
  /// Plain HTTP/1.1 over Network.framework, matching the iOS client. The
  /// relay only listens on Tailscale, which encrypts the connection.
  static let transport: OpenOrgServerTransport = { request in
    guard let url = URL(string: request.endpoint),
          let host = url.host,
          let rawPort = url.port.flatMap(UInt16.init(exactly:)),
          let port = NWEndpoint.Port(rawValue: rawPort)
    else {
      throw OpenOrgServerError.invalidEndpoint
    }
    var headers = [
      "Accept: application/json",
      "Connection: close",
      "Host: \(host):\(rawPort)",
    ]
    if let token = request.accessToken {
      headers.append("Authorization: Bearer \(token)")
    }
    if let body = request.body {
      headers.append("Content-Type: application/json")
      headers.append("Content-Length: \(body.count)")
    } else {
      headers.append("Content-Length: 0")
    }
    var data = Data("\(request.method) \(request.path) HTTP/1.1\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8)
    if let body = request.body { data.append(body) }
    return try await OpenOrgServerHTTPExchange(
      host: NWEndpoint.Host(host),
      port: port,
      request: data,
      timeout: request.timeout
    ).run()
  }
}

private final class OpenOrgServerHTTPExchange: @unchecked Sendable {
  private let host: NWEndpoint.Host
  private let port: NWEndpoint.Port
  private let request: Data
  private let timeout: TimeInterval
  private let queue = DispatchQueue(label: "org.openorg.server-client", qos: .userInitiated)
  private let lock = NSLock()
  private var connection: NWConnection?
  private var continuation: CheckedContinuation<OpenOrgServerHTTPResponse, Error>?
  private var received = Data()
  private var isFinished = false

  init(host: NWEndpoint.Host, port: NWEndpoint.Port, request: Data, timeout: TimeInterval) {
    self.host = host
    self.port = port
    self.request = request
    self.timeout = timeout
  }

  func run() async throws -> OpenOrgServerHTTPResponse {
    try await withCheckedThrowingContinuation { continuation in
      lock.withLock { self.continuation = continuation }
      let connection = NWConnection(host: host, port: port, using: .tcp)
      lock.withLock { self.connection = connection }
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          self.send()
        case .failed(let error):
          self.finish(.failure(OpenOrgServerError.connection(error.localizedDescription)))
        case .waiting(let error):
          self.finish(.failure(OpenOrgServerError.connection(error.localizedDescription)))
        case .cancelled:
          self.finish(.failure(OpenOrgServerError.connection("The connection closed.")))
        default:
          break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
        self?.finish(.failure(OpenOrgServerError.connection("The request timed out.")))
      }
    }
  }

  private func send() {
    let connection = lock.withLock { self.connection }
    connection?.send(content: request, completion: .contentProcessed { [weak self] error in
      if let error {
        self?.finish(.failure(OpenOrgServerError.connection(error.localizedDescription)))
      } else {
        self?.receive()
      }
    })
  }

  private func receive() {
    let connection = lock.withLock { self.connection }
    connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      guard let self else { return }
      if let data { self.received.append(data) }
      if let parsed = Self.parse(self.received) {
        self.finish(.success(parsed))
      } else if let error {
        self.finish(.failure(OpenOrgServerError.connection(error.localizedDescription)))
      } else if complete {
        self.finish(.failure(OpenOrgServerError.malformedResponse))
      } else {
        self.receive()
      }
    }
  }

  private func finish(_ result: Result<OpenOrgServerHTTPResponse, Error>) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isFinished = true
    let continuation = continuation
    self.continuation = nil
    let connection = connection
    self.connection = nil
    lock.unlock()
    connection?.stateUpdateHandler = nil
    connection?.cancel()
    continuation?.resume(with: result)
  }

  static func parse(_ data: Data) -> OpenOrgServerHTTPResponse? {
    guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
          let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
    else { return nil }
    let lines = headerText.components(separatedBy: "\r\n")
    let statusParts = lines.first?.split(separator: " ") ?? []
    guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else { return nil }
    var contentLength: Int?
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { continue }
      if line[..<separator].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
        contentLength = Int(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
      }
    }
    guard let contentLength, contentLength >= 0 else { return nil }
    let start = headerRange.upperBound
    guard data.count >= start + contentLength else { return nil }
    return OpenOrgServerHTTPResponse(statusCode: statusCode, body: data.subdata(in: start..<(start + contentLength)))
  }
}

// MARK: - Connection

/// This Mac's client connection to a headless OpenOrg server (`org2 server`).
///
/// The Mac pairs like an iPhone does, with the one-time code from
/// `org2 server pair`, and can then ask the server to host live thread links.
/// The server renders those pages from its own synced copy of the corpus, so
/// links stay live while this Mac sleeps.
@MainActor
@Observable
public final class OpenOrgServerConnection {
  public enum Reachability: Equatable, Sendable {
    case unknown
    case checking
    case online
    case offline(String)
  }

  public private(set) var pairing: OpenOrgServerPairing?
  public private(set) var reachability: Reachability = .unknown
  public private(set) var serverStatus: MobileRemoteServerStatus?
  public private(set) var isPairing = false
  public private(set) var threadShares: [UUID: OpenOrgServerThreadShare] = [:]
  public private(set) var busyThreadIDs: Set<UUID> = []
  public private(set) var defaultShareLocation: ChatThreadShareLocation

  static let pairingKey = "Org2Workspace.openOrgServer.pairing.v1"
  static let sharesKey = "Org2Workspace.openOrgServer.threadShares.v1"
  static let defaultLocationKey = "Org2Workspace.chatThreadShare.defaultLocation.v1"

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let credentials: OpenOrgServerCredentialStoring
  @ObservationIgnored private let transport: OpenOrgServerTransport

  public init(
    defaults: UserDefaults,
    credentials: OpenOrgServerCredentialStoring,
    transport: OpenOrgServerTransport? = nil
  ) {
    self.defaults = defaults
    self.credentials = credentials
    self.transport = transport ?? OpenOrgServerNetworkTransport.transport
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    pairing = defaults.data(forKey: Self.pairingKey)
      .flatMap { try? decoder.decode(OpenOrgServerPairing.self, from: $0) }
    let shares = defaults.data(forKey: Self.sharesKey)
      .flatMap { try? decoder.decode([OpenOrgServerThreadShare].self, from: $0) } ?? []
    threadShares = Dictionary(shares.map { ($0.threadID, $0) }, uniquingKeysWith: { $1 })
    defaultShareLocation = defaults.string(forKey: Self.defaultLocationKey)
      .flatMap(ChatThreadShareLocation.init(rawValue:)) ?? .thisMac
  }

  public var isPaired: Bool { pairing != nil }

  public var serverName: String {
    serverStatus?.serverName ?? pairing?.serverName ?? "Celorga Server"
  }

  /// The location a new share should use when the person does not pick one.
  public var effectiveDefaultShareLocation: ChatThreadShareLocation {
    defaultShareLocation == .server && isPaired ? .server : .thisMac
  }

  public func setDefaultShareLocation(_ location: ChatThreadShareLocation) {
    defaultShareLocation = location
    defaults.set(location.rawValue, forKey: Self.defaultLocationKey)
  }

  /// Links this server hosts, newest first.
  public var sortedThreadShares: [OpenOrgServerThreadShare] {
    threadShares.values.sorted { $0.sharedAt > $1.sharedAt }
  }

  public func threadShare(for threadID: UUID) -> OpenOrgServerThreadShare? {
    threadShares[threadID]
  }

  public func isBusy(_ threadID: UUID) -> Bool {
    busyThreadIDs.contains(threadID)
  }

  // MARK: Pairing

  public func pair(endpointText: String, code rawCode: String, deviceName: String) async throws {
    guard let input = OpenOrgServerPairingInput.parse(endpointText) else {
      throw OpenOrgServerError.invalidEndpoint
    }
    let code = (input.code ?? rawCode).filter(\.isNumber)
    guard code.count == 6 else { throw OpenOrgServerError.missingCode }
    isPairing = true
    defer { isPairing = false }
    let body = try MobileRemoteProtocol.encoder().encode(
      MobileRemotePairRequest(code: code, deviceName: deviceName)
    )
    let response: MobileRemotePairResponse = try await send(
      endpoint: input.endpoint,
      method: "POST",
      path: "/v1/pair",
      token: nil,
      body: body
    )
    try credentials.setToken(response.accessToken, for: response.deviceID)
    let previous = pairing
    let record = OpenOrgServerPairing(
      endpoint: input.endpoint,
      serverName: response.serverName,
      hostRef: nil,
      deviceID: response.deviceID,
      pairedAt: Date()
    )
    pairing = record
    persistPairing()
    if let previous, previous.deviceID != record.deviceID {
      credentials.removeToken(for: previous.deviceID)
    }
    if previous?.endpoint != record.endpoint {
      threadShares = [:]
      persistShares()
    }
    await refreshStatus()
  }

  /// Stops this server's links, revokes this Mac's credential on the server,
  /// and forgets the pairing. Unreachable servers are forgotten locally.
  public func unpair() async {
    guard let pairing else { return }
    for threadID in Array(threadShares.keys) {
      try? await stopSharing(threadID: threadID)
    }
    let _: MobileRemoteMutationResponse? = try? await authorizedSend(
      method: "POST",
      path: "/v1/device/revoke",
      body: nil,
      timeout: 5
    )
    credentials.removeToken(for: pairing.deviceID)
    self.pairing = nil
    serverStatus = nil
    reachability = .unknown
    threadShares = [:]
    persistPairing()
    persistShares()
  }

  public func refreshStatus() async {
    guard isPaired else {
      reachability = .unknown
      return
    }
    reachability = .checking
    do {
      let status: MobileRemoteServerStatus = try await authorizedSend(
        method: "GET",
        path: "/v1/status",
        body: nil,
        timeout: 6
      )
      serverStatus = status
      reachability = .online
      if let pairing, pairing.serverName != status.serverName || pairing.hostRef != status.hostRef {
        self.pairing = OpenOrgServerPairing(
          endpoint: pairing.endpoint,
          serverName: status.serverName,
          hostRef: status.hostRef,
          deviceID: pairing.deviceID,
          pairedAt: pairing.pairedAt
        )
        persistPairing()
      }
    } catch {
      reachability = .offline(error.localizedDescription)
    }
  }

  // MARK: Thread links

  @discardableResult
  public func share(
    threadID: UUID,
    appearance: AIChatThreadShareAppearance
  ) async throws -> OpenOrgServerThreadShare {
    guard let pairing else { throw OpenOrgServerError.notPaired }
    busyThreadIDs.insert(threadID)
    defer { busyThreadIDs.remove(threadID) }
    if serverStatus == nil { await refreshStatus() }
    if serverStatus?.supportsThreadSharing != true, serverStatus != nil {
      throw OpenOrgServerError.unsupported
    }
    let body = try MobileRemoteProtocol.encoder().encode(MobileRemoteThreadShareRequest(
      appearanceMode: appearance.appearanceMode,
      lightThemeID: appearance.lightThemeID,
      darkThemeID: appearance.darkThemeID
    ))
    let response: MobileRemoteThreadShare
    do {
      response = try await authorizedSend(
        method: "POST",
        path: "/v1/threads/\(threadID.uuidString.lowercased())/share",
        body: body,
        timeout: 60
      )
    } catch OpenOrgServerError.server(_, let statusCode) where statusCode == 404 {
      throw OpenOrgServerError.threadNotOnServer(serverName)
    }
    return try record(response, pairing: pairing)
  }

  public func stopSharing(threadID: UUID) async throws {
    guard isPaired else {
      threadShares[threadID] = nil
      persistShares()
      return
    }
    busyThreadIDs.insert(threadID)
    defer { busyThreadIDs.remove(threadID) }
    let _: MobileRemoteThreadShare = try await authorizedSend(
      method: "POST",
      path: "/v1/threads/\(threadID.uuidString.lowercased())/share/stop",
      body: nil,
      timeout: 15
    )
    threadShares[threadID] = nil
    persistShares()
  }

  /// Reconciles one thread's cached link with the server, for example after
  /// another client stopped sharing it.
  public func refreshShare(threadID: UUID) async {
    guard let pairing else { return }
    guard let response: MobileRemoteThreadShare = try? await authorizedSend(
      method: "GET",
      path: "/v1/threads/\(threadID.uuidString.lowercased())/share",
      body: nil,
      timeout: 6
    ) else { return }
    if response.isShared {
      _ = try? record(response, pairing: pairing)
    } else if threadShares[threadID] != nil {
      threadShares[threadID] = nil
      persistShares()
    }
  }

  private func record(
    _ response: MobileRemoteThreadShare,
    pairing: OpenOrgServerPairing
  ) throws -> OpenOrgServerThreadShare {
    guard response.isShared,
          let rawURL = response.url,
          let url = URL(string: rawURL),
          url.scheme?.lowercased() == "http"
    else {
      throw OpenOrgServerError.malformedResponse
    }
    let share = OpenOrgServerThreadShare(
      threadID: response.threadID,
      url: url,
      sharedAt: response.sharedAt ?? threadShares[response.threadID]?.sharedAt ?? Date(),
      endpoint: pairing.endpoint,
      serverName: serverName
    )
    if threadShares[response.threadID] != share {
      threadShares[response.threadID] = share
      persistShares()
    }
    return share
  }

  // MARK: Source credentials and syncs

  /// Whether the paired server can hold source credentials and run syncs.
  /// `nil` means its status has not been read yet.
  public var supportsSourceCredentials: Bool? {
    serverStatus.map { $0.supportsSourceCredentials == true }
  }

  /// Sends one source's credential to the server, which keeps it outside the corpus.
  public func uploadSourceCredential(profileID: String, credential: String) async throws {
    guard isPaired else { throw OpenOrgServerError.notPaired }
    if serverStatus == nil { await refreshStatus() }
    if supportsSourceCredentials == false { throw OpenOrgServerError.sourcesUnsupported }
    let body = try MobileRemoteProtocol.encoder().encode(MobileRemoteSourceCredentialRequest(credential: credential))
    let _: MobileRemoteSourceCredentialResponse = try await authorizedSend(
      method: "PUT",
      path: "/v1/sources/\(Self.pathComponent(profileID))/credential",
      body: body,
      timeout: 15
    )
  }

  public func deleteSourceCredential(profileID: String) async throws {
    guard isPaired else { throw OpenOrgServerError.notPaired }
    let _: MobileRemoteSourceCredentialResponse = try await authorizedSend(
      method: "DELETE",
      path: "/v1/sources/\(Self.pathComponent(profileID))/credential",
      body: nil,
      timeout: 15
    )
  }

  public func sourceCredentialProfileIDs() async throws -> [String] {
    let list: MobileRemoteSourceCredentialList = try await authorizedSend(
      method: "GET",
      path: "/v1/sources/credentials",
      body: nil,
      timeout: 8
    )
    return list.profileIDs
  }

  /// Asks the server to sync and stage one source now. Results reach this
  /// Mac through the corpus's normal file sync.
  public func syncSource(profileID: String) async throws -> MobileRemoteSourceSyncResponse {
    guard isPaired else { throw OpenOrgServerError.notPaired }
    if serverStatus == nil { await refreshStatus() }
    if supportsSourceCredentials == false { throw OpenOrgServerError.sourcesUnsupported }
    return try await authorizedSend(
      method: "POST",
      path: "/v1/sources/\(Self.pathComponent(profileID))/sync",
      body: nil,
      timeout: 35 * 60
    )
  }

  private static func pathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? value
  }

  // MARK: Requests

  private func authorizedSend<Response: Decodable>(
    method: String,
    path: String,
    body: Data?,
    timeout: TimeInterval
  ) async throws -> Response {
    guard let pairing else { throw OpenOrgServerError.notPaired }
    let deviceID = pairing.deviceID
    let credentials = credentials
    // Keychain reads can block; keep them off the main actor.
    let token = await Task.detached(priority: .userInitiated) {
      credentials.token(for: deviceID)
    }.value
    guard let token else { throw OpenOrgServerError.notPaired }
    return try await send(
      endpoint: pairing.endpoint,
      method: method,
      path: path,
      token: token,
      body: body,
      timeout: timeout
    )
  }

  private func send<Response: Decodable>(
    endpoint: String,
    method: String,
    path: String,
    token: String?,
    body: Data?,
    timeout: TimeInterval = 15
  ) async throws -> Response {
    let response = try await transport(OpenOrgServerHTTPRequest(
      endpoint: endpoint,
      method: method,
      path: path,
      accessToken: token,
      body: body,
      timeout: timeout
    ))
    guard (200..<300).contains(response.statusCode) else {
      let envelope = try? MobileRemoteProtocol.decoder().decode(MobileRemoteErrorEnvelope.self, from: response.body)
      throw OpenOrgServerError.server(
        envelope?.error ?? "The Celorga server rejected this request (HTTP \(response.statusCode)).",
        statusCode: response.statusCode
      )
    }
    do {
      return try MobileRemoteProtocol.decoder().decode(Response.self, from: response.body)
    } catch {
      throw OpenOrgServerError.malformedResponse
    }
  }

  private func persistPairing() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let pairing, let data = try? encoder.encode(pairing) {
      defaults.set(data, forKey: Self.pairingKey)
    } else {
      defaults.removeObject(forKey: Self.pairingKey)
    }
  }

  private func persistShares() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if threadShares.isEmpty {
      defaults.removeObject(forKey: Self.sharesKey)
    } else if let data = try? encoder.encode(sortedThreadShares) {
      defaults.set(data, forKey: Self.sharesKey)
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
