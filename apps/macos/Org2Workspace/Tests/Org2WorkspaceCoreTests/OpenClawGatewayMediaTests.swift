import Foundation
import Network
import XCTest
@testable import Org2WorkspaceCore

/// A harmless 1x1 PNG used wherever a delivered image is needed.
private let pixelPNGBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
private let pixelPNG = Data(base64Encoded: pixelPNGBase64)!

/// A scripted protocol-v4 Gateway. Each request method maps to the frames it
/// answers with; unknown methods get an error response, as a real Gateway does.
private final class ScriptedOpenClawGateway: @unchecked Sendable {
  typealias Script = @Sendable (_ method: String, _ id: String, _ params: [String: Any]) -> [[String: Any]]

  private let queue = DispatchQueue(label: "scripted-openclaw-gateway")
  private var listener: NWListener?
  private let lock = NSLock()
  private var methods: [String] = []
  private let script: Script

  init(script: @escaping Script) { self.script = script }

  var requestedMethods: [String] { lock.withLock { methods } }

  func start() throws -> UInt16 {
    let parameters = NWParameters.tcp
    let websocket = NWProtocolWebSocket.Options()
    websocket.autoReplyPing = true
    parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
    let listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      connection.start(queue: self.queue)
      self.send(["type": "event", "event": "connect.challenge", "payload": ["nonce": "nonce-1"]], on: connection)
      self.receive(on: connection)
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    self.listener = listener
    return listener.port!.rawValue
  }

  func stop() { listener?.cancel() }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self, error == nil, let data,
            let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return }
      let id = frame["id"] as? String ?? ""
      let method = frame["method"] as? String ?? ""
      let params = frame["params"] as? [String: Any] ?? [:]
      self.lock.withLock { self.methods.append(method) }
      if method == "connect" {
        self.send(["type": "res", "id": id, "ok": true, "payload": ["type": "hello-ok"]], on: connection)
      } else {
        let frames = self.script(method, id, params)
        if frames.isEmpty {
          self.send([
            "type": "res", "id": id, "ok": false,
            "error": ["code": "INVALID_REQUEST", "message": "unknown method: \(method)"],
          ], on: connection)
        }
        for frame in frames { self.send(frame, on: connection) }
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

/// Serves managed media the way the Gateway does: only with a media ticket.
private final class TicketedMediaServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "ticketed-media-server")
  private var listener: NWListener?
  let body: Data
  let ticket: String

  init(body: Data, ticket: String) {
    self.body = body
    self.ticket = ticket
  }

  func start() throws -> UInt16 {
    let listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      connection.start(queue: self.queue)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
        let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let authorized = request.hasPrefix("GET ") && request.contains("mediaTicket=\(self.ticket)")
        var response = Data(
          (authorized
            ? "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(self.body.count)\r\nConnection: close\r\n\r\n"
            : "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").utf8
        )
        if authorized { response.append(self.body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    self.listener = listener
    return listener.port!.rawValue
  }

  func stop() { listener?.cancel() }
}

private actor AttachmentEventLog {
  private(set) var attachments: [AIChatAttachment] = []
  func record(_ event: OpenClawGatewayRunEvent) {
    if case .attachments(let delivered) = event { attachments.append(contentsOf: delivered) }
  }
}

final class OpenClawGatewayMediaTests: XCTestCase {
  private static let sessionKey = "agent:org2:org2-workspace:media-test"

  /// The transcript shape OpenClaw 2026.9 records when an agent sends an
  /// image with the `message` tool mid-turn and then ends with an image-only
  /// assistant message.
  private static func managedImageBlock(_ attachmentID: String) -> [String: Any] {
    let url = "/api/chat/media/outgoing/agent%3Aorg2%3Aorg2-workspace%3Amedia-test/\(attachmentID)/full"
    return [
      "type": "image",
      "artifactId": "artifact_managed_image_\(attachmentID)",
      "url": url,
      "openUrl": url,
      "alt": "pixel.png",
      "mimeType": "image/png",
      "width": 1,
      "height": 1,
      "sizeBytes": pixelPNG.count,
    ]
  }

  private static func runHistory(runID: String, finalContent: [[String: Any]]) -> [String: Any] {
    [
      "messages": [
        ["role": "assistant", "content": [managedImageBlock("00000000-0000-4000-8000-0000000000aa")]],
        ["role": "user", "content": "send me the picture", "__openclaw": ["idempotencyKey": "\(runID):user"]],
        ["role": "assistant", "content": [["type": "toolCall", "id": "call-1", "name": "message"]]],
        [
          "role": "assistant",
          "content": [
            ["type": "text", "text": "Here it is."],
            managedImageBlock("00000000-0000-4000-8000-000000000001"),
          ],
          "__openclaw": ["idempotencyKey": "msg:message-tool:call-1"],
        ],
        ["role": "toolResult", "content": [["type": "text", "text": "Sent visible reply"]]],
        ["role": "assistant", "content": finalContent],
      ],
      "sessionInfo": ["status": "done", "hasActiveRun": false],
    ]
  }

  private func settings(port: UInt16, directory: URL) -> OpenClawGatewaySettings {
    OpenClawGatewaySettings(
      endpoint: URL(string: "ws://127.0.0.1:\(port)")!,
      bearerToken: nil,
      chatCompletionsEnabled: nil,
      deviceIdentityFileURL: directory.appendingPathComponent("identity.key")
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("openclaw-media-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Answers artifact downloads: the message-tool image as inline bytes and
  /// the final image as a ticketed HTTP URL on the media server.
  private static func artifactDownloadFrames(id: String, params: [String: Any], mediaPort: UInt16) -> [[String: Any]] {
    let artifactID = params["artifactId"] as? String ?? ""
    if artifactID.hasSuffix("000000000001") {
      return [["type": "res", "id": id, "ok": true, "payload": ["encoding": "base64", "data": pixelPNGBase64]]]
    }
    if artifactID.hasSuffix("000000000002") {
      return [[
        "type": "res", "id": id, "ok": true,
        "payload": [
          "url": "http://127.0.0.1:\(mediaPort)/api/chat/media/outgoing/x/000000000002/full?mediaTicket=ticket-1",
        ],
      ]]
    }
    return [["type": "res", "id": id, "ok": false, "error": ["code": "NOT_FOUND", "message": "artifact not found"]]]
  }

  // MARK: - Decoding

  func testManagedImageBlocksBecomeMediaReferences() throws {
    let message: [String: Any] = [
      "role": "assistant",
      "content": [
        ["type": "text", "text": "QR below"],
        Self.managedImageBlock("00000000-0000-4000-8000-000000000001"),
        ["type": "image", "data": pixelPNGBase64, "mimeType": "image/png"],
        [
          "type": "attachment",
          "attachment": [
            "artifactId": "artifact_managed_file_1", "url": "/api/x", "label": "report.pdf",
            "mimeType": "application/pdf", "kind": "document",
          ],
        ],
      ],
    ]
    let references = OpenClawGatewayClient.mediaReferences(in: message)
    XCTAssertEqual(references.count, 3)
    XCTAssertEqual(references[0].artifactID, "artifact_managed_image_00000000-0000-4000-8000-000000000001")
    XCTAssertEqual(references[0].fileName, "pixel.png")
    XCTAssertEqual(references[0].mimeType, "image/png")
    XCTAssertEqual(references[1].inlineData, pixelPNG)
    XCTAssertEqual(references[1].fileName, "openclaw-image-3.png")
    XCTAssertEqual(references[2].fileName, "report.pdf")
    XCTAssertEqual(OpenClawGatewayClient.messageText(message, includeThinking: false), "QR below")
  }

  func testRunMediaIncludesMessageToolDeliveriesAndIgnoresEarlierTurns() {
    let payload = Self.runHistory(
      runID: "run-1",
      finalContent: [Self.managedImageBlock("00000000-0000-4000-8000-000000000002")]
    )
    let references = OpenClawGatewayClient.runMediaReferences(from: payload, runID: "run-1")
    XCTAssertEqual(
      references.map(\.artifactID),
      [
        "artifact_managed_image_00000000-0000-4000-8000-000000000001",
        "artifact_managed_image_00000000-0000-4000-8000-000000000002",
      ]
    )
    XCTAssertTrue(OpenClawGatewayClient.runMediaReferences(from: payload, runID: "other-run").isEmpty)
  }

  func testImageOnlyFinalMessageReconcilesAsAReply() {
    let payload = Self.runHistory(
      runID: "run-1",
      finalContent: [Self.managedImageBlock("00000000-0000-4000-8000-000000000002")]
    )
    XCTAssertEqual(
      OpenClawGatewayClient.chatHistoryReconciliation(from: payload, runID: "run-1", requestStartedAtMilliseconds: 0),
      .completed("")
    )
  }

  func testGatewayMediaURLsResolveAgainstTheGatewayOrigin() throws {
    let endpoint = URL(string: "wss://gateway.example.ts.net:8443/socket")!
    XCTAssertEqual(
      OpenClawGatewayClient.gatewayHTTPURL(for: "/api/chat/media/outgoing/a/b/full?mediaTicket=t", endpoint: endpoint)?
        .absoluteString,
      "https://gateway.example.ts.net:8443/api/chat/media/outgoing/a/b/full?mediaTicket=t"
    )
    let local = try XCTUnwrap(
      OpenClawGatewayClient.gatewayHTTPURL(for: "/api/x", endpoint: URL(string: "ws://127.0.0.1:18789")!)
    )
    XCTAssertEqual(local.absoluteString, "http://127.0.0.1:18789/api/x")
    XCTAssertTrue(OpenClawGatewayClient.isSameOrigin(local, as: URL(string: "ws://127.0.0.1:18789")!))
    XCTAssertFalse(
      OpenClawGatewayClient.isSameOrigin(URL(string: "https://elsewhere.example/api/x")!, as: endpoint)
    )
    XCTAssertNil(OpenClawGatewayClient.gatewayHTTPURL(for: "file:///tmp/picture.png", endpoint: endpoint))
  }

  // MARK: - Live turns

  func testLiveImageOnlyReplyDeliversMessageToolAndFinalImages() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let media = TicketedMediaServer(body: pixelPNG, ticket: "ticket-1")
    let mediaPort = try media.start()
    defer { media.stop() }
    let runID = UUID().uuidString.lowercased()
    nonisolated(unsafe) let finalContent: [[String: Any]] = [Self.managedImageBlock("00000000-0000-4000-8000-000000000002")]
    let gateway = ScriptedOpenClawGateway { method, id, params in
      switch method {
      case "chat.send":
        return [
          ["type": "res", "id": id, "ok": true, "payload": ["runId": runID, "status": "started"]],
          [
            "type": "event", "event": "chat",
            "payload": ["runId": runID, "state": "final", "message": ["role": "assistant", "content": finalContent]],
          ],
        ]
      case "chat.history":
        return [["type": "res", "id": id, "ok": true, "payload": Self.runHistory(runID: runID, finalContent: finalContent)]]
      case "artifacts.download":
        return Self.artifactDownloadFrames(id: id, params: params, mediaPort: mediaPort)
      default:
        return []
      }
    }
    let port = try gateway.start()
    defer { gateway.stop() }
    let client = OpenClawGatewayClient(settings: settings(port: port, directory: directory))
    let log = AttachmentEventLog()

    let reply = try await client.send(
      message: "send me the QR",
      attachments: [],
      agentID: "org2",
      sessionKey: Self.sessionKey,
      idempotencyKey: runID
    ) { event in await log.record(event) }
    await client.shutdown()

    XCTAssertEqual(reply, "", "an image-only reply is not an empty response")
    let attachments = await log.attachments
    XCTAssertEqual(attachments.map(\.fileName), ["pixel.png", "pixel.png"])
    XCTAssertEqual(try attachments.map { try $0.loadData() }, [pixelPNG, pixelPNG])
    XCTAssertTrue(gateway.requestedMethods.contains("artifacts.download"))
  }

  func testLiveTextPlusImageReplyKeepsTextAndReportsUndownloadableMedia() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runID = UUID().uuidString.lowercased()
    nonisolated(unsafe) let finalContent: [[String: Any]] = [
      ["type": "text", "text": "Scan this."],
      Self.managedImageBlock("00000000-0000-4000-8000-000000000001"),
      // Expired on the Gateway: the download is refused and there is no URL.
      Self.managedImageBlock("00000000-0000-4000-8000-0000000000ff")
        .filter { $0.key != "url" && $0.key != "openUrl" },
    ]
    let gateway = ScriptedOpenClawGateway { method, id, params in
      switch method {
      case "chat.send":
        return [
          ["type": "res", "id": id, "ok": true, "payload": ["runId": runID, "status": "started"]],
          [
            "type": "event", "event": "chat",
            "payload": ["runId": runID, "state": "final", "message": ["role": "assistant", "content": finalContent]],
          ],
        ]
      case "artifacts.download":
        return Self.artifactDownloadFrames(id: id, params: params, mediaPort: 9)
      default:
        // chat.history is unavailable; the final message's media still counts.
        return []
      }
    }
    let port = try gateway.start()
    defer { gateway.stop() }
    let client = OpenClawGatewayClient(settings: settings(port: port, directory: directory))
    let log = AttachmentEventLog()

    let reply = try await client.send(
      message: "send me the QR",
      attachments: [],
      agentID: "org2",
      sessionKey: Self.sessionKey,
      idempotencyKey: runID
    ) { event in await log.record(event) }
    await client.shutdown()

    XCTAssertTrue(reply.hasPrefix("Scan this."))
    XCTAssertTrue(reply.contains("could not download"), "a missing image is reported, not silently dropped")
    let attachments = await log.attachments
    XCTAssertEqual(attachments.count, 1)
    XCTAssertEqual(try attachments.first?.loadData(), pixelPNG)
  }

  func testReconnectedRunRecoversImageOnlyReplyFromHistory() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let media = TicketedMediaServer(body: pixelPNG, ticket: "ticket-1")
    let mediaPort = try media.start()
    defer { media.stop() }
    let runID = UUID().uuidString.lowercased()
    nonisolated(unsafe) let finalContent: [[String: Any]] = [Self.managedImageBlock("00000000-0000-4000-8000-000000000002")]
    let gateway = ScriptedOpenClawGateway { method, id, params in
      switch method {
      case "agent.wait":
        return [["type": "res", "id": id, "ok": true, "payload": ["status": "ok"]]]
      case "chat.history":
        return [["type": "res", "id": id, "ok": true, "payload": Self.runHistory(runID: runID, finalContent: finalContent)]]
      case "artifacts.download":
        return Self.artifactDownloadFrames(id: id, params: params, mediaPort: mediaPort)
      default:
        return []
      }
    }
    let port = try gateway.start()
    defer { gateway.stop() }
    let client = OpenClawGatewayClient(settings: settings(port: port, directory: directory))
    let log = AttachmentEventLog()

    let reply = try await client.reconnectAcceptedRun(
      runID: runID,
      sessionKey: Self.sessionKey,
      agentID: "org2",
      requestStartedAt: Date(timeIntervalSince1970: 0)
    ) { event in await log.record(event) }
    await client.shutdown()

    XCTAssertEqual(reply, "")
    let attachments = await log.attachments
    XCTAssertEqual(attachments.count, 2)
    XCTAssertEqual(try attachments.map { try $0.loadData() }, [pixelPNG, pixelPNG])
  }

  // MARK: - Persistence

  @MainActor
  func testDeliveredMediaIsStoredWithTheReplyAndSurvivesReload() async throws {
    for replyText in ["Here is the QR.", ""] {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let transcript = root.appendingPathComponent("openclaw-chat.json")
      let suiteName = "openclaw-media-\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suiteName)!
      defer { defaults.removePersistentDomain(forName: suiteName) }
      let image = AIChatAttachment(fileName: "pixel.png", mimeType: "image/png", data: pixelPNG)

      var storeReference: WorkspaceStore?
      let store = try WorkspaceStore(
        cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
        defaults: defaults,
        aiChatTranscriptURL: transcript,
        aiChatSendHandler: { _, _, _, _ in
          await MainActor.run {
            guard let store = storeReference, let threadID = store.selectedAIChatThreadID else { return }
            store.handleOpenClawGatewayEvent(.attachments([image]), threadID: threadID)
          }
          return replyText
        }
      )
      storeReference = store
      store.createAIChatThread(runtime: .openClaw)
      store.aiChatDraft = "send me the QR"
      await store.sendAIChatMessage()

      let reply = try XCTUnwrap(store.aiChatMessages.last)
      XCTAssertEqual(reply.role, .assistant)
      XCTAssertEqual(reply.content, replyText)
      XCTAssertEqual(reply.attachments.map(\.fileName), ["pixel.png"])

      let restored = try WorkspaceStore(
        cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
        defaults: defaults,
        aiChatTranscriptURL: transcript
      )
      let restoredReply = try XCTUnwrap(restored.aiChatMessages.last)
      XCTAssertEqual(restoredReply.content, replyText)
      XCTAssertEqual(try restoredReply.attachments.map { try $0.loadData() }, [pixelPNG])
    }
  }
}
