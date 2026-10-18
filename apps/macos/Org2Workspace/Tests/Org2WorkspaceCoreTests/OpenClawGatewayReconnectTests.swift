import Foundation
import Network
import XCTest
@testable import Org2WorkspaceCore

/// A minimal protocol-v4 Gateway: challenge, hello-ok, and one chat.send answered
/// with a final chat event. It counts chat.send requests so duplicates are visible.
private final class FakeOpenClawGateway: @unchecked Sendable {
  private let queue = DispatchQueue(label: "fake-openclaw-gateway")
  private var listener: NWListener?
  private let lock = NSLock()
  private var sends: [String] = []

  var chatSendMessages: [String] { lock.withLock { sends } }

  func start(port: UInt16) throws {
    let parameters = NWParameters.tcp
    let websocket = NWProtocolWebSocket.Options()
    websocket.autoReplyPing = true
    parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
    parameters.allowLocalEndpointReuse = true
    let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      connection.start(queue: self.queue)
      self.send(["type": "event", "event": "connect.challenge", "payload": ["nonce": "nonce-1"]], on: connection)
      self.receive(on: connection)
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  func stop() { listener?.cancel() }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self, error == nil, let data,
            let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return }
      let id = frame["id"] as? String ?? ""
      let params = frame["params"] as? [String: Any] ?? [:]
      switch frame["method"] as? String {
      case "connect":
        self.send(["type": "res", "id": id, "ok": true, "payload": ["type": "hello-ok"]], on: connection)
      case "chat.send":
        let runID = params["idempotencyKey"] as? String ?? "run"
        self.lock.withLock { self.sends.append(params["message"] as? String ?? "") }
        self.send(["type": "res", "id": id, "ok": true, "payload": ["runId": runID, "status": "started"]], on: connection)
        self.send([
          "type": "event", "event": "chat",
          "payload": ["runId": runID, "state": "final", "message": ["role": "assistant", "content": "delivered once"]],
        ], on: connection)
      default:
        break
      }
      self.receive(on: connection)
    }
  }

  private func send(_ object: [String: Any], on connection: NWConnection) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
    connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
  }
}

private actor ConnectionEventLog {
  private(set) var reconnectDetails: [String] = []
  func record(_ event: OpenClawGatewayRunEvent) {
    if case .connection(.reconnecting, let detail) = event { reconnectDetails.append(detail ?? "") }
  }
}

final class OpenClawGatewayReconnectTests: XCTestCase {
  private func freePort() throws -> UInt16 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
    }
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
  }

  func testMessageWaitsForAnUnresponsiveGatewayInsteadOfFailing() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("openclaw-reconnect-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let port = try freePort()
    let settings = OpenClawGatewaySettings(
      endpoint: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!,
      bearerToken: nil,
      chatCompletionsEnabled: nil,
      deviceIdentityFileURL: directory.appendingPathComponent("identity.key")
    )
    let client = OpenClawGatewayClient(settings: settings, preSendReconnectDelays: [0.3, 0.3, 0.3, 0.3, 0.3, 0.3])
    let gateway = FakeOpenClawGateway()
    defer { gateway.stop() }
    // The Gateway comes back after the first attempts are refused, as after a stall.
    Task {
      try? await Task.sleep(for: .milliseconds(700))
      try? gateway.start(port: port)
    }
    let log = ConnectionEventLog()

    let reply = try await client.send(
      message: "find other options",
      attachments: [],
      agentID: "main",
      sessionKey: "agent:main:test",
      idempotencyKey: UUID().uuidString.lowercased()
    ) { event in await log.record(event) }

    XCTAssertEqual(reply, "delivered once")
    XCTAssertEqual(gateway.chatSendMessages, ["find other options"], "the message is sent exactly once")
    let reconnects = await log.reconnectDetails
    XCTAssertFalse(reconnects.isEmpty)
    XCTAssertTrue(reconnects.allSatisfy { $0.contains("nothing has been sent yet") })
    await client.shutdown()
  }

  func testOnlyTransportFailuresAreRetriedBeforeSending() {
    XCTAssertTrue(OpenClawGatewayClient.shouldRetryBeforeSending(after: .connection("cancelled")))
    XCTAssertFalse(OpenClawGatewayClient.shouldRetryBeforeSending(after: .gateway(code: "NOT_PAIRED", message: "pair")))
    XCTAssertFalse(OpenClawGatewayClient.shouldRetryBeforeSending(after: .invalidEndpoint))
  }

  func testUnreachableGatewayFailureSaysTheMessageWasNotSent() {
    let text = WorkspaceStore.openClawNotSentMessage(.connection("the Gateway did not answer the handshake within 15 seconds"))
    XCTAssertTrue(text.hasPrefix("Not sent."))
    XCTAssertFalse(text.contains("Model and reasoning overrides"))
  }
}
