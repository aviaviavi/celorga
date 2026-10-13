import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Records requests and replies with canned relay responses.
private final class FakeRelay: @unchecked Sendable {
  struct Call: Equatable {
    let endpoint: String
    let method: String
    let path: String
    let token: String?
  }

  private let lock = NSLock()
  private var calls: [Call] = []
  private var bodies: [Data?] = []
  private let reply: @Sendable (OpenOrgServerHTTPRequest) throws -> (Int, Encodable)

  init(reply: @escaping @Sendable (OpenOrgServerHTTPRequest) throws -> (Int, Encodable)) {
    self.reply = reply
  }

  var recorded: [Call] { lock.withLock { calls } }
  var recordedBodies: [Data?] { lock.withLock { bodies } }

  var transport: OpenOrgServerTransport {
    { [self] request in
      lock.withLock {
        calls.append(Call(
          endpoint: request.endpoint,
          method: request.method,
          path: request.path,
          token: request.accessToken
        ))
        bodies.append(request.body)
      }
      let (status, value) = try reply(request)
      return OpenOrgServerHTTPResponse(
        statusCode: status,
        body: try MobileRemoteProtocol.encoder().encode(value)
      )
    }
  }
}

@MainActor
final class OpenOrgServerConnectionTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!

  override func setUp() async throws {
    suiteName = "openorg-server-connection-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
  }

  func testPairingInputAcceptsTheServerPairLinkAndBareAddresses() {
    let link = OpenOrgServerPairingInput.parse(
      "org2-remote://pair?endpoint=http%3A%2F%2F100.79.252.51%3A48922&code=123456&name=OpenOrg%20on%20press"
    )
    XCTAssertEqual(link, OpenOrgServerPairingInput(
      endpoint: "http://100.79.252.51:48922",
      code: "123456",
      name: "OpenOrg on press"
    ))
    XCTAssertEqual(OpenOrgServerPairingInput.parse(" 100.64.0.9 ")?.endpoint, "http://100.64.0.9:48922")
    XCTAssertEqual(OpenOrgServerPairingInput.parse("http://Press.local:5000")?.endpoint, "http://press.local:5000")
    XCTAssertNil(OpenOrgServerPairingInput.parse("https://100.64.0.9"))
    XCTAssertNil(OpenOrgServerPairingInput.parse("http://100.64.0.9/v1/status"))
    XCTAssertNil(OpenOrgServerPairingInput.parse("http://user@100.64.0.9"))
    XCTAssertNil(OpenOrgServerPairingInput.parse(""))
  }

  func testPairShareAndStopUseTheStoredCredentialAndSurviveRelaunch() async throws {
    let deviceID = UUID()
    let threadID = UUID()
    let sharePath = "/v1/threads/\(threadID.uuidString.lowercased())/share"
    let relay = FakeRelay { request in
      switch (request.method, request.path) {
      case ("POST", "/v1/pair"):
        return (201, MobileRemotePairResponse(serverName: "OpenOrg on press", deviceID: deviceID, accessToken: "secret-token"))
      case ("GET", "/v1/status"):
        return (200, MobileRemoteServerStatus(serverName: "OpenOrg on press", hostRef: "press", hostKind: "server", corpusName: "avi.org2", threadCount: 3, runningThreadCount: 0))
      case ("POST", sharePath):
        return (201, MobileRemoteThreadShare(threadID: threadID, isShared: true, url: "http://100.79.252.51:51000/a/token", sharedAt: Date(timeIntervalSince1970: 1_000)))
      case ("POST", sharePath + "/stop"):
        return (200, MobileRemoteThreadShare(threadID: threadID, isShared: false))
      default:
        return (404, MobileRemoteErrorEnvelope(error: "Not found."))
      }
    }
    let credentials = OpenOrgServerMemoryCredentials()
    let connection = OpenOrgServerConnection(defaults: defaults, credentials: credentials, transport: relay.transport)
    XCTAssertEqual(connection.effectiveDefaultShareLocation, .thisMac)

    try await connection.pair(
      endpointText: "org2-remote://pair?endpoint=http%3A%2F%2F100.79.252.51%3A48922&code=123456",
      code: "",
      deviceName: "AiroPress"
    )
    XCTAssertEqual(connection.pairing?.endpoint, "http://100.79.252.51:48922")
    XCTAssertEqual(connection.pairing?.hostRef, "press")
    XCTAssertEqual(connection.reachability, .online)
    XCTAssertEqual(credentials.token(for: deviceID), "secret-token")
    let pairBody = try MobileRemoteProtocol.decoder().decode(
      MobileRemotePairRequest.self,
      from: try XCTUnwrap(relay.recordedBodies.first ?? nil)
    )
    XCTAssertEqual(pairBody, MobileRemotePairRequest(code: "123456", deviceName: "AiroPress"))
    XCTAssertNil(relay.recorded[0].token)
    XCTAssertEqual(relay.recorded[1].token, "secret-token")

    connection.setDefaultShareLocation(.server)
    let share = try await connection.share(
      threadID: threadID,
      appearance: AIChatThreadShareAppearance(appearanceMode: "dark", lightThemeID: "openorg-paper", darkThemeID: "openorg-night")
    )
    XCTAssertEqual(share.url.absoluteString, "http://100.79.252.51:51000/a/token")
    XCTAssertEqual(share.serverName, "OpenOrg on press")
    let shareBody = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteThreadShareRequest.self,
      from: try XCTUnwrap(relay.recordedBodies.last ?? nil)
    )
    XCTAssertEqual(shareBody.appearanceMode, "dark")
    XCTAssertEqual(relay.recorded.last?.token, "secret-token")

    // A relaunch restores the pairing, default, and hosted link without secrets in defaults.
    let relaunched = OpenOrgServerConnection(defaults: defaults, credentials: credentials, transport: relay.transport)
    XCTAssertEqual(relaunched.pairing?.deviceID, deviceID)
    XCTAssertEqual(relaunched.effectiveDefaultShareLocation, .server)
    XCTAssertEqual(relaunched.threadShare(for: threadID)?.url, share.url)
    let persisted = defaults.dictionaryRepresentation()
      .compactMap { $0.value as? Data }
      .map { String(decoding: $0, as: UTF8.self) }
      .joined()
    XCTAssertFalse(persisted.contains("secret-token"))

    try await relaunched.stopSharing(threadID: threadID)
    XCTAssertNil(relaunched.threadShare(for: threadID))
    XCTAssertEqual(relay.recorded.last?.path, sharePath + "/stop")
  }

  func testSharingAThreadTheServerHasNotSyncedExplainsTheWait() async throws {
    let deviceID = UUID()
    let relay = FakeRelay { request in
      switch request.path {
      case "/v1/pair":
        return (201, MobileRemotePairResponse(serverName: "Home Server", deviceID: deviceID, accessToken: "token"))
      case "/v1/status":
        return (200, MobileRemoteServerStatus(serverName: "Home Server", corpusName: nil, threadCount: 0, runningThreadCount: 0))
      default:
        return (404, MobileRemoteErrorEnvelope(error: "This host doesn’t have that thread yet."))
      }
    }
    let connection = OpenOrgServerConnection(
      defaults: defaults,
      credentials: OpenOrgServerMemoryCredentials(),
      transport: relay.transport
    )
    try await connection.pair(endpointText: "100.64.0.2", code: "654321", deviceName: "Mac")

    do {
      try await connection.share(
        threadID: UUID(),
        appearance: AIChatThreadShareAppearance(appearanceMode: "system", lightThemeID: "a", darkThemeID: "b")
      )
      XCTFail("Expected the share to fail")
    } catch let error as OpenOrgServerError {
      XCTAssertEqual(error, .threadNotOnServer("Home Server"))
    }
  }

  func testOlderServersWithoutThreadSharingAreReportedBeforeSending() async throws {
    let deviceID = UUID()
    let relay = FakeRelay { request in
      switch request.path {
      case "/v1/pair":
        return (201, MobileRemotePairResponse(serverName: "Old Server", deviceID: deviceID, accessToken: "token"))
      default:
        return (200, MobileRemoteServerStatus(
          serverName: "Old Server",
          corpusName: nil,
          threadCount: 0,
          runningThreadCount: 0,
          supportsThreadSharing: nil
        ))
      }
    }
    let connection = OpenOrgServerConnection(
      defaults: defaults,
      credentials: OpenOrgServerMemoryCredentials(),
      transport: relay.transport
    )
    try await connection.pair(endpointText: "100.64.0.3", code: "111111", deviceName: "Mac")
    do {
      try await connection.share(
        threadID: UUID(),
        appearance: AIChatThreadShareAppearance(appearanceMode: "system", lightThemeID: "a", darkThemeID: "b")
      )
      XCTFail("Expected the share to fail")
    } catch let error as OpenOrgServerError {
      XCTAssertEqual(error, .unsupported)
    }
    XCTAssertFalse(relay.recorded.contains { $0.path.contains("/share") })
  }

  func testUnpairStopsServerLinksRevokesTheDeviceAndForgetsTheToken() async throws {
    let deviceID = UUID()
    let threadID = UUID()
    let relay = FakeRelay { request in
      switch request.path {
      case "/v1/pair":
        return (201, MobileRemotePairResponse(serverName: "Server", deviceID: deviceID, accessToken: "token"))
      case "/v1/status":
        return (200, MobileRemoteServerStatus(serverName: "Server", corpusName: nil, threadCount: 1, runningThreadCount: 0))
      case "/v1/device/revoke":
        return (200, MobileRemoteMutationResponse(accepted: true))
      default:
        return request.path.hasSuffix("/stop")
          ? (200, MobileRemoteThreadShare(threadID: threadID, isShared: false))
          : (201, MobileRemoteThreadShare(threadID: threadID, isShared: true, url: "http://100.64.0.4:5000/a/x"))
      }
    }
    let credentials = OpenOrgServerMemoryCredentials()
    let connection = OpenOrgServerConnection(defaults: defaults, credentials: credentials, transport: relay.transport)
    try await connection.pair(endpointText: "100.64.0.4", code: "222222", deviceName: "Mac")
    connection.setDefaultShareLocation(.server)
    try await connection.share(
      threadID: threadID,
      appearance: AIChatThreadShareAppearance(appearanceMode: "system", lightThemeID: "a", darkThemeID: "b")
    )

    await connection.unpair()

    XCTAssertFalse(connection.isPaired)
    XCTAssertTrue(connection.threadShares.isEmpty)
    XCTAssertNil(credentials.token(for: deviceID))
    XCTAssertEqual(connection.effectiveDefaultShareLocation, .thisMac)
    XCTAssertEqual(
      relay.recorded.suffix(2).map(\.path),
      ["/v1/threads/\(threadID.uuidString.lowercased())/share/stop", "/v1/device/revoke"]
    )
  }
}

final class LocalPublicationAdvertisedHostTests: XCTestCase {
  func testLinksPreferTheLiveTailscaleAddressAndFallBackToTheMachineName() async throws {
    let preferred = PreferredHostBox()
    let host = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "press.local",
      preferredAdvertisedHost: { preferred.value }
    )
    defer { host.stop() }

    preferred.value = "100.79.252.51"
    let tailscale = try await host.publish(html: Data("<p>Hi</p>".utf8), title: "Plan")
    XCTAssertEqual(tailscale.url.host, "100.79.252.51")
    XCTAssertEqual(tailscale.localURL.host, "127.0.0.1")

    preferred.value = nil
    let restored = try await host.restorePublications()
    XCTAssertEqual(restored.first?.id, tailscale.id)
    XCTAssertEqual(restored.first?.url.host, "press.local")
    XCTAssertEqual(restored.first?.url.port, tailscale.url.port)
  }
}

private final class PreferredHostBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: String?
  var value: String? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

@MainActor
final class ChatThreadRelayShareTests: XCTestCase {
  func testRelayPublishesAThreadWithTheClientsAppearanceAndStopsIt() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-relay-share-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "openorg-relay-share-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let publicationHost = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1",
      preferredAdvertisedHost: { "100.64.0.7" }
    )
    defer { publicationHost.stop() }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      legacyDefaultsDomains: [],
      localDocumentPublicationHost: publicationHost
    )
    store.aiChatMessages = [AIChatMessage(role: .user, content: "Ship the relay share")]
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    let coordinator = MobileRemoteCoordinator(
      defaults: defaults,
      credentialFile: root.appendingPathComponent("devices.json")
    )
    let components = ["v1", "threads", threadID.uuidString.lowercased(), "share"]

    let missing = await coordinator.handleThreadShare(
      MobileRemoteHTTPRequest(method: "POST", path: "/v1/threads/\(UUID())/share"),
      threadID: UUID(),
      components: components,
      store: store
    )
    XCTAssertEqual(missing.statusCode, 404)

    let body = try MobileRemoteProtocol.encoder().encode(
      MobileRemoteThreadShareRequest(appearanceMode: "dark", lightThemeID: "openorg-paper", darkThemeID: "openorg-night")
    )
    let created = await coordinator.handleThreadShare(
      MobileRemoteHTTPRequest(method: "POST", path: "/", body: body),
      threadID: threadID,
      components: components,
      store: store
    )
    XCTAssertEqual(created.statusCode, 201)
    let share = try MobileRemoteProtocol.decoder().decode(MobileRemoteThreadShare.self, from: created.body)
    XCTAssertTrue(share.isShared)
    XCTAssertEqual(URL(string: share.url ?? "")?.host, "100.64.0.7")

    let publication = try XCTUnwrap(store.chatThreadPublication(for: threadID))
    let (page, _) = try await URLSession.shared.data(from: publication.localURL)
    let html = String(decoding: page, as: UTF8.self)
    XCTAssertTrue(html.contains("Ship the relay share"))
    // The client's pinned dark appearance wins over this host's System default.
    XCTAssertTrue(html.contains(":root { color-scheme: dark; }"))

    let status = await coordinator.handleThreadShare(
      MobileRemoteHTTPRequest(method: "GET", path: "/"),
      threadID: threadID,
      components: components,
      store: store
    )
    XCTAssertEqual(try MobileRemoteProtocol.decoder().decode(MobileRemoteThreadShare.self, from: status.body).url, share.url)

    let stopped = await coordinator.handleThreadShare(
      MobileRemoteHTTPRequest(method: "POST", path: "/"),
      threadID: threadID,
      components: components + ["stop"],
      store: store
    )
    XCTAssertFalse(try MobileRemoteProtocol.decoder().decode(MobileRemoteThreadShare.self, from: stopped.body).isShared)
    XCTAssertNil(store.chatThreadPublication(for: threadID))
    XCTAssertTrue(store.chatThreadShareAppearanceOverrides.isEmpty)
  }
}

@MainActor
final class MobileRemoteThreadOutputsEndpointTests: XCTestCase {
  func testOutputsEndpointServesTheThreadsEditedAndLinkedFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-thread-outputs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "openorg-thread-outputs-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let report = root.appendingPathComponent("report.org")
    try Data("* Report".utf8).write(to: report)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      legacyDefaultsDomains: []
    )
    let reply = AIChatMessage(role: .assistant, content: "Wrote [[file:\(report.path)][the report]].")
    store.aiChatMessages = [AIChatMessage(role: .user, content: "Write the report"), reply]
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    let coordinator = MobileRemoteCoordinator(
      defaults: defaults,
      credentialFile: root.appendingPathComponent("devices.json")
    )

    let response = await coordinator.handleThreadOutputs(threadID: threadID, store: store)

    XCTAssertEqual(response.statusCode, 200)
    let outputs = try MobileRemoteProtocol.decoder().decode(MobileRemoteThreadOutputs.self, from: response.body)
    XCTAssertEqual(outputs.threadID, threadID)
    let group = try XCTUnwrap(outputs.groups.first)
    XCTAssertEqual(group.files.map(\.fileExtension), ["org"])
    XCTAssertTrue(group.exists)
    XCTAssertEqual(group.lastMessageID, reply.id)
    XCTAssertEqual(group.activitySummary, "linked 1×")

    let missing = await coordinator.handleThreadOutputs(threadID: UUID(), store: store)
    XCTAssertEqual(missing.statusCode, 503)
  }
}
