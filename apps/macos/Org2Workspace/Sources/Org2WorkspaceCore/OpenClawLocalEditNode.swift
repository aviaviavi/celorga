import Foundation

public enum OpenClawLocalEditNodeState: String, Sendable {
  case disabled
  case connecting
  case pairingRequired
  case connected
  case reconnecting
  case stopped

  public var label: String {
    switch self {
    case .disabled: "Off"
    case .connecting: "Connecting"
    case .pairingRequired: "Pairing required"
    case .connected: "Connected"
    case .reconnecting: "Reconnecting"
    case .stopped: "Stopped"
    }
  }
}

/// A narrow OpenClaw node that exposes only Org2's typed local edit protocol.
///
/// It intentionally does not expose `system.run` or a generic filesystem
/// command. The Gateway remains the agent runtime, while reads and writes are
/// executed by `AIChatLocalEditBroker` against the corpus selected in the app.
public actor OpenClawLocalEditNode {
  public typealias StateHandler =
    @MainActor @Sendable (OpenClawLocalEditNodeState, String?) -> Void

  private let settings: OpenClawGatewaySettings
  private let broker: AIChatLocalEditBroker
  private let displayName: String
  private let stateHandler: StateHandler
  private let session: URLSession
  private var socket: URLSessionWebSocketTask?
  private var isStopping = false

  public init(
    settings: OpenClawGatewaySettings,
    broker: AIChatLocalEditBroker,
    displayName: String,
    stateHandler: @escaping StateHandler
  ) {
    self.settings = settings
    self.broker = broker
    self.displayName = displayName
    self.stateHandler = stateHandler
    self.session = URLSession(configuration: OpenClawChatClient.sessionConfiguration())
  }

  public func run() async {
    isStopping = false
    var retrySeconds: UInt64 = 1
    while !Task.isCancelled, !isStopping {
      do {
        await publishState(retrySeconds == 1 ? .connecting : .reconnecting, nil)
        try await connectAndServe()
        retrySeconds = 1
      } catch is CancellationError {
        break
      } catch {
        guard !Task.isCancelled, !isStopping else { break }
        let detail = error.localizedDescription
        let pairingRequired = Self.isPairingRequired(error)
        await publishState(pairingRequired ? .pairingRequired : .reconnecting, detail)
        do {
          try await Task.sleep(for: .seconds(pairingRequired ? 10 : retrySeconds))
        } catch {
          break
        }
        retrySeconds = min(retrySeconds * 2, 30)
      }
    }
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    await publishState(isStopping ? .stopped : .disabled, nil)
  }

  public func stop() async {
    isStopping = true
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  nonisolated static func connectionClaims(displayName: String) -> [String: Any] {
    [
      "clientId": "org2-workspace-node",
      "displayName": displayName,
      "role": "node",
      "mode": "node",
      "caps": ["org2"],
      "commands": AIChatLocalEditBroker.commands
    ]
  }

  private func connectAndServe() async throws {
    let socket = try makeSocket()
    self.socket = socket
    socket.resume()
    // Every exit cancels this attempt's task. A failed handshake (for example
    // while pairing is required) otherwise left the closed socket's descriptor
    // open, and the retry loop leaked one per attempt for the life of the host.
    defer {
      socket.cancel(with: .goingAway, reason: nil)
      if self.socket === socket { self.socket = nil }
    }
    let nonce = try await awaitChallenge(on: socket)
    let identity = try OpenClawDeviceIdentity.loadOrCreate()
    try await connect(on: socket, nonce: nonce, identity: identity)
    await publishState(.connected, "Local Celorga reads and previewed edits are available.")

    while !Task.isCancelled, !isStopping {
      let frame = try await receiveObject(on: socket)
      guard Self.string(frame["type"]) == "event",
            Self.string(frame["event"]) == "node.invoke.request",
            let payload = Self.dictionary(frame["payload"]),
            let requestID = Self.string(payload["id"]),
            let nodeID = Self.string(payload["nodeId"]),
            let command = Self.string(payload["command"])
      else {
        continue
      }

      let result = await broker.handle(
        command: command,
        paramsJSON: Self.string(payload["paramsJSON"])
      )
      var params: [String: Any] = [
        "id": requestID,
        "nodeId": nodeID,
        "ok": result.ok
      ]
      if let payloadJSON = result.payloadJSON {
        params["payloadJSON"] = payloadJSON
      }
      if let message = result.errorMessage {
        var error: [String: Any] = ["message": message]
        if let code = result.errorCode { error["code"] = code }
        params["error"] = error
      }
      try await sendRequest(
        id: UUID().uuidString.lowercased(),
        method: "node.invoke.result",
        params: params,
        on: socket
      )
    }
  }

  private func connect(
    on socket: URLSessionWebSocketTask,
    nonce: String,
    identity: OpenClawDeviceIdentity
  ) async throws {
    let requestID = UUID().uuidString.lowercased()
    let clientID = "org2-workspace-node"
    let signedAt = Int(Date().timeIntervalSince1970 * 1_000)
    let token = settings.bearerToken ?? ""
    let signaturePayload = [
      "v3",
      identity.deviceID,
      clientID,
      "node",
      "node",
      "",
      String(signedAt),
      token,
      nonce,
      "darwin",
      "mac"
    ].joined(separator: "|")
    var params: [String: Any] = [
      "minProtocol": 4,
      "maxProtocol": 4,
      "client": [
        "id": clientID,
        "displayName": displayName,
        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        "platform": "darwin",
        "deviceFamily": "Mac",
        "mode": "node"
      ],
      "role": "node",
      "scopes": [],
      "caps": ["org2"],
      "commands": AIChatLocalEditBroker.commands,
      "permissions": [
        AIChatLocalEditBroker.readCommand: true,
        AIChatLocalEditBroker.previewCommand: true,
        AIChatLocalEditBroker.applyCommand: true
      ],
      "locale": Locale.current.identifier,
      "device": [
        "id": identity.deviceID,
        "publicKey": identity.publicKeyBase64URL,
        "signature": try identity.signature(for: signaturePayload),
        "signedAt": signedAt,
        "nonce": nonce
      ]
    ]
    if let bearerToken = settings.bearerToken {
      params["auth"] = ["token": bearerToken]
    }

    try await sendRequest(id: requestID, method: "connect", params: params, on: socket)
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
      guard Self.string(Self.dictionary(frame["payload"])?["type"]) == "hello-ok" else {
        throw OpenClawGatewayError.protocolFailure("node connect did not return hello-ok")
      }
      return
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

  private func sendRequest(
    id: String,
    method: String,
    params: [String: Any],
    on socket: URLSessionWebSocketTask
  ) async throws {
    let frame: [String: Any] = [
      "type": "req",
      "id": id,
      "method": method,
      "params": params
    ]
    let data = try JSONSerialization.data(withJSONObject: frame)
    guard let text = String(data: data, encoding: .utf8) else {
      throw OpenClawGatewayError.protocolFailure("could not encode node request")
    }
    try await socket.send(.string(text))
  }

  private func receiveObject(on socket: URLSessionWebSocketTask) async throws -> [String: Any] {
    let message = try await socket.receive()
    let data: Data
    switch message {
    case .data(let value):
      data = value
    case .string(let value):
      data = Data(value.utf8)
    @unknown default:
      throw OpenClawGatewayError.protocolFailure("unsupported node WebSocket frame")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OpenClawGatewayError.protocolFailure("node Gateway frame was not an object")
    }
    return object
  }

  private func publishState(_ state: OpenClawLocalEditNodeState, _ detail: String?) async {
    await stateHandler(state, detail)
  }

  private nonisolated static func gatewayError(from frame: [String: Any]) -> OpenClawGatewayError {
    let error = dictionary(frame["error"])
    return .gateway(
      code: string(error?["code"]),
      message: string(error?["message"]) ?? "OpenClaw rejected the local edit node request."
    )
  }

  private nonisolated static func isPairingRequired(_ error: Error) -> Bool {
    guard case let OpenClawGatewayError.gateway(code, message) = error else {
      return false
    }
    return code == "NOT_PAIRED"
      || message.localizedCaseInsensitiveContains("pairing")
      || message.localizedCaseInsensitiveContains("not paired")
  }

  private nonisolated static func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  private nonisolated static func string(_ value: Any?) -> String? {
    value as? String
  }

  private nonisolated static func bool(_ value: Any?) -> Bool? {
    value as? Bool
  }
}
