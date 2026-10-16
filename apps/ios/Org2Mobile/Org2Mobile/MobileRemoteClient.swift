import Foundation
import Network

enum MobileRemoteClientError: LocalizedError {
  case invalidEndpoint
  case connection(String)
  case malformedResponse
  case server(String)
  case incompatibleProtocol

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      "Enter a Celorga host URL such as http://100.64.0.1:48922 or http://press.local:48922."
    case .connection(let detail):
      "Could not reach the host: \(detail)"
    case .malformedResponse:
      "The host returned an unreadable response."
    case .server(let message):
      message
    case .incompatibleProtocol:
      "This host uses a different Mobile Remote protocol version. Update Celorga on both devices."
    }
  }
}

struct MobileRemoteClient: Sendable {
  let endpoint: URL
  let accessToken: String?

  init(endpoint rawEndpoint: String, accessToken: String?) throws {
    let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
          components.scheme?.lowercased() == "http",
          let host = components.host,
          Self.isAllowedHost(host)
    else {
      throw MobileRemoteClientError.invalidEndpoint
    }
    if components.port == nil {
      components.port = Int(MobileRemoteWire.defaultPort)
    }
    components.path = ""
    components.query = nil
    components.fragment = nil
    guard let normalized = components.url else {
      throw MobileRemoteClientError.invalidEndpoint
    }
    endpoint = normalized
    self.accessToken = accessToken
  }

  func get<Response: Decodable>(
    _ path: String,
    timeout: TimeInterval = 15,
    as type: Response.Type
  ) async throws -> Response {
    try await request(method: "GET", path: path, body: nil, timeout: timeout, as: type)
  }

  func post<Payload: Encodable, Response: Decodable>(
    _ path: String,
    payload: Payload,
    timeout: TimeInterval = 15,
    as type: Response.Type
  ) async throws -> Response {
    let body = try MobileRemoteWire.encoder().encode(payload)
    return try await request(method: "POST", path: path, body: body, timeout: timeout, as: type)
  }

  private func request<Response: Decodable>(
    method: String,
    path: String,
    body: Data?,
    timeout: TimeInterval = 15,
    as type: Response.Type
  ) async throws -> Response {
    guard let host = endpoint.host else {
      throw MobileRemoteClientError.invalidEndpoint
    }
    let portValue = endpoint.port ?? Int(MobileRemoteWire.defaultPort)
    guard let rawPort = UInt16(exactly: portValue),
          let port = NWEndpoint.Port(rawValue: rawPort)
    else {
      throw MobileRemoteClientError.invalidEndpoint
    }

    var headers = [
      "Accept: application/json",
      "Connection: close",
      "Host: \(host):\(portValue)"
    ]
    if let accessToken {
      headers.append("Authorization: Bearer \(accessToken)")
    }
    if let body {
      headers.append("Content-Type: application/json")
      headers.append("Content-Length: \(body.count)")
    } else {
      headers.append("Content-Length: 0")
    }

    let cacheKey = method == "GET" ? MobileRemoteResponseCache.key(endpoint: endpoint, accessToken: accessToken, path: path) : nil
    let cached = cacheKey.flatMap { MobileRemoteResponseCache.shared.entry(for: $0) }
    if let cached {
      headers.append("If-None-Match: \(cached.entityTag)")
    }

    var requestData = Data("\(method) \(path) HTTP/1.1\r\n\(headers.joined(separator: "\r\n"))\r\n\r\n".utf8)
    if let body {
      requestData.append(body)
    }
    let response = try await MobileRemoteHTTPExchange(
      host: NWEndpoint.Host(host),
      port: port,
      request: requestData,
      timeout: timeout
    ).run()

    try Task.checkCancellation()
    if response.statusCode == 304, let cached {
      // Identical to the copy already held; the host skipped resending it.
      return try MobileRemoteWire.decoder().decode(type, from: cached.body)
    }
    if let cacheKey {
      if response.statusCode == 200, let entityTag = response.entityTag {
        MobileRemoteResponseCache.shared.store(entityTag: entityTag, body: response.body, for: cacheKey)
      } else {
        MobileRemoteResponseCache.shared.remove(cacheKey)
      }
    }
    guard (200..<300).contains(response.statusCode) else {
      let envelope = try? MobileRemoteWire.decoder().decode(MobileRemoteErrorEnvelope.self, from: response.body)
      throw MobileRemoteClientError.server(envelope?.error ?? "The host rejected this request.")
    }
    return try MobileRemoteWire.decoder().decode(type, from: response.body)
  }

  private static func isTailscaleIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".").compactMap { UInt8($0) }
    return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
  }

  private static func isAllowedHost(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty, normalized == host.lowercased() else { return false }
    if normalized == "localhost" { return true }
    if isIPv4Address(normalized) { return true }
    return isValidHostname(normalized)
  }

  private static func isIPv4Address(_ address: String) -> Bool {
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { UInt8($0) != nil }
  }

  private static func isValidHostname(_ host: String) -> Bool {
    guard host.count <= 253, !host.contains("..") else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.isEmpty else { return false }
    return labels.allSatisfy { label in
      guard !label.isEmpty, label.count <= 63 else { return false }
      guard label.first?.isASCII == true,
            label.last?.isASCII == true,
            isASCIILetterOrNumber(label.first),
            isASCIILetterOrNumber(label.last)
      else { return false }
      return label.allSatisfy { character in
        character.isASCII && (isASCIILetterOrNumber(character) || character == "-")
      }
    }
  }

  private static func isASCIILetterOrNumber(_ character: Character?) -> Bool {
    guard let character else { return false }
    return character.isASCII && (character.isLetter || character.isNumber)
  }
}

private struct MobileRemoteRawResponse: Sendable {
  let statusCode: Int
  let entityTag: String?
  let body: Data
}

/// Recent GET bodies with their entity tags. Polls send If-None-Match, and a
/// host that has nothing new answers 304 instead of resending the thread list
/// or an open thread. Bounded so a long session cannot grow it without limit.
final class MobileRemoteResponseCache: @unchecked Sendable {
  static let shared = MobileRemoteResponseCache()
  static let maximumEntries = 24
  static let maximumBodyBytes = 4_000_000

  struct Entry {
    let entityTag: String
    let body: Data
    var lastUsed: UInt64
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var clock: UInt64 = 0

  static func key(endpoint: URL, accessToken: String?, path: String) -> String {
    // The token distinguishes pairings with the same host; it never leaves memory.
    "\(endpoint.absoluteString)|\(accessToken ?? "")|\(path)"
  }

  func entry(for key: String) -> Entry? {
    lock.lock()
    defer { lock.unlock() }
    guard var entry = entries[key] else { return nil }
    clock &+= 1
    entry.lastUsed = clock
    entries[key] = entry
    return entry
  }

  func store(entityTag: String, body: Data, for key: String) {
    guard body.count <= Self.maximumBodyBytes else {
      remove(key)
      return
    }
    lock.lock()
    defer { lock.unlock() }
    clock &+= 1
    entries[key] = Entry(entityTag: entityTag, body: body, lastUsed: clock)
    while entries.count > Self.maximumEntries,
          let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
      entries.removeValue(forKey: oldest)
    }
  }

  func remove(_ key: String) {
    lock.lock()
    entries.removeValue(forKey: key)
    lock.unlock()
  }

  func removeAll() {
    lock.lock()
    entries.removeAll()
    lock.unlock()
  }
}

private final class MobileRemoteHTTPExchange: @unchecked Sendable {
  private let host: NWEndpoint.Host
  private let port: NWEndpoint.Port
  private let request: Data
  private let timeout: TimeInterval
  private let queue = DispatchQueue(label: "org.org2.mobile.remote-http", qos: .userInitiated)
  private let lock = NSLock()
  private var connection: NWConnection?
  private var continuation: CheckedContinuation<MobileRemoteRawResponse, Error>?
  private var received = Data()
  private var isFinished = false

  init(host: NWEndpoint.Host, port: NWEndpoint.Port, request: Data, timeout: TimeInterval) {
    self.host = host
    self.port = port
    self.request = request
    self.timeout = timeout
  }

  func run() async throws -> MobileRemoteRawResponse {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let connection = NWConnection(host: host, port: port, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          switch state {
          case .ready:
            self.sendRequest()
          case .failed(let error):
            self.finish(.failure(MobileRemoteClientError.connection(error.localizedDescription)))
          case .cancelled:
            self.finish(.failure(MobileRemoteClientError.connection("The connection closed.")))
          default:
            break
          }
        }
        lock.lock()
        guard !isFinished else {
          lock.unlock()
          connection.stateUpdateHandler = nil
          connection.cancel()
          continuation.resume(throwing: CancellationError())
          return
        }
        self.continuation = continuation
        self.connection = connection
        connection.start(queue: queue)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
          self?.finish(.failure(MobileRemoteClientError.connection("The request timed out.")))
        }
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
    }
  }

  private func sendRequest() {
    connection?.send(content: request, completion: .contentProcessed { [weak self] error in
      if let error {
        self?.finish(.failure(MobileRemoteClientError.connection(error.localizedDescription)))
      } else {
        self?.receiveNext()
      }
    })
  }

  private func receiveNext() {
    connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      guard let self else { return }
      if let data {
        self.received.append(data)
      }
      if let parsed = Self.parseResponseIfComplete(self.received) {
        self.finish(.success(parsed))
      } else if let error {
        self.finish(.failure(MobileRemoteClientError.connection(error.localizedDescription)))
      } else if complete {
        self.finish(.failure(MobileRemoteClientError.malformedResponse))
      } else {
        self.receiveNext()
      }
    }
  }

  private func finish(_ result: Result<MobileRemoteRawResponse, Error>) {
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

  private static func parseResponseIfComplete(_ data: Data) -> MobileRemoteRawResponse? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: delimiter),
          let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
    else {
      return nil
    }
    let lines = headerText.components(separatedBy: "\r\n")
    let statusParts = lines.first?.split(separator: " ") ?? []
    guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else { return nil }
    var contentLength: Int?
    var entityTag: String?
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      if key == "content-length" {
        contentLength = Int(value)
      } else if key == "etag", !value.isEmpty {
        entityTag = value
      }
    }
    guard let contentLength, contentLength >= 0 else { return nil }
    let bodyStart = headerRange.upperBound
    guard data.count >= bodyStart + contentLength else { return nil }
    return MobileRemoteRawResponse(
      statusCode: statusCode,
      entityTag: entityTag,
      body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
    )
  }
}
