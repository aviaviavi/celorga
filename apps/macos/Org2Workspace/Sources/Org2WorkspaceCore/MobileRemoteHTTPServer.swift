import Foundation
import Network

public enum MobileRemoteHTTPServerError: LocalizedError {
  case invalidHost
  case invalidPort

  public var errorDescription: String? {
    switch self {
    case .invalidHost:
      "Enter a valid Tailscale IPv4 address."
    case .invalidPort:
      "Enter a port between 1 and 65535."
    }
  }
}

public final class MobileRemoteHTTPServer: @unchecked Sendable {
  public typealias Handler = @Sendable (MobileRemoteHTTPRequest) async -> MobileRemoteHTTPResponse
  public typealias StateHandler = @Sendable (String) -> Void

  private let queue = DispatchQueue(label: "org.org2.workspace.mobile-remote", qos: .userInitiated)
  private let handler: Handler
  private let stateHandler: StateHandler?
  private let connectionLock = NSLock()
  private var listener: NWListener?
  private var connections: [UUID: MobileRemoteHTTPConnection] = [:]

  public init(handler: @escaping Handler, stateHandler: StateHandler? = nil) {
    self.handler = handler
    self.stateHandler = stateHandler
  }

  public func start(host: String, port: UInt16) throws {
    guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MobileRemoteHTTPServerError.invalidHost
    }
    guard let networkPort = NWEndpoint.Port(rawValue: port) else {
      throw MobileRemoteHTTPServerError.invalidPort
    }

    stop()
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host(host),
      port: networkPort
    )
    let listener = try NWListener(using: parameters)
    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.stateHandler?("Listening on \(host):\(port)")
      case .waiting(let error):
        self?.stateHandler?("Waiting: \(error.localizedDescription)")
      case .failed(let error):
        self?.stateHandler?("Failed: \(error.localizedDescription)")
      case .cancelled:
        self?.stateHandler?("Off")
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      let id = UUID()
      let remoteConnection = MobileRemoteHTTPConnection(
        connection: connection,
        handler: self.handler,
        completion: { [weak self] in self?.removeConnection(id) }
      )
      self.connectionLock.lock()
      self.connections[id] = remoteConnection
      self.connectionLock.unlock()
      remoteConnection.start(on: self.queue)
    }
    self.listener = listener
    listener.start(queue: queue)
  }

  public func stop() {
    listener?.cancel()
    listener = nil
    connectionLock.lock()
    let liveConnections = Array(connections.values)
    connections = [:]
    connectionLock.unlock()
    liveConnections.forEach { $0.cancel() }
  }

  deinit {
    stop()
  }

  private func removeConnection(_ id: UUID) {
    connectionLock.lock()
    connections[id] = nil
    connectionLock.unlock()
  }
}

final class MobileRemoteHTTPConnection: @unchecked Sendable {
  // Mobile photos are resized before upload, but their base64 JSON envelope can
  // still exceed the old text-only 1 MB ceiling.
  private static let maximumRequestBytes = 12_000_000

  private let connection: NWConnection
  private let handler: MobileRemoteHTTPServer.Handler
  private let completion: @Sendable () -> Void
  private let finishLock = NSLock()
  private var received = Data()
  private var isFinished = false

  init(
    connection: NWConnection,
    handler: @escaping MobileRemoteHTTPServer.Handler,
    completion: @escaping @Sendable () -> Void
  ) {
    self.connection = connection
    self.handler = handler
    self.completion = completion
  }

  func start(on queue: DispatchQueue) {
    connection.stateUpdateHandler = { [weak self] state in
      if case .ready = state {
        self?.receiveNext()
      } else if case .failed = state {
        self?.cancel()
      } else if case .cancelled = state {
        self?.finish()
      }
    }
    connection.start(queue: queue)
  }

  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
      guard let self else { return }
      if let data {
        self.received.append(data)
      }
      if self.received.count > Self.maximumRequestBytes {
        self.send(.error("Request is too large.", statusCode: 413))
        return
      }
      if let request = Self.parseRequestIfComplete(self.received) {
        Task {
          let response = await self.handler(request)
          self.send(response)
        }
        return
      }
      if complete || error != nil {
        self.send(.error("Malformed HTTP request.", statusCode: 400))
        return
      }
      self.receiveNext()
    }
  }

  static func parseRequestIfComplete(_ data: Data) -> MobileRemoteHTTPRequest? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: delimiter),
          let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8)
    else {
      return nil
    }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
      headers[key] = value
    }
    let contentLength = Int(headers["content-length"] ?? "0") ?? 0
    guard contentLength >= 0 else { return nil }
    let bodyStart = headerRange.upperBound
    guard data.count >= bodyStart + contentLength else { return nil }
    let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
    return MobileRemoteHTTPRequest(
      method: String(parts[0]),
      path: String(parts[1]),
      headers: headers,
      body: body
    )
  }

  private func send(_ response: MobileRemoteHTTPResponse) {
    var headers = response.headers
    headers["Content-Length"] = String(response.body.count)
    headers["Connection"] = "close"
    headers["Cache-Control"] = "no-store"
    let headerLines = headers
      .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
      .map { "\($0.key): \($0.value)" }
      .joined(separator: "\r\n")
    let statusText = Self.statusText(response.statusCode)
    var data = Data("HTTP/1.1 \(response.statusCode) \(statusText)\r\n\(headerLines)\r\n\r\n".utf8)
    data.append(response.body)
    connection.send(content: data, completion: .contentProcessed { [weak self] _ in
      self?.cancel()
    })
  }

  func cancel() {
    connection.cancel()
    finish()
  }

  private func finish() {
    finishLock.lock()
    guard !isFinished else {
      finishLock.unlock()
      return
    }
    isFinished = true
    finishLock.unlock()
    completion()
  }

  private static func statusText(_ statusCode: Int) -> String {
    switch statusCode {
    case 200: "OK"
    case 201: "Created"
    case 202: "Accepted"
    case 304: "Not Modified"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 404: "Not Found"
    case 409: "Conflict"
    case 413: "Payload Too Large"
    case 503: "Service Unavailable"
    default: "Internal Server Error"
    }
  }
}
