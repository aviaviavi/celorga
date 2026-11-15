import Foundation
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class DocumentServerPublishingTests: XCTestCase {
  func testPairedServerAcceptsASealedDocument() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "DocumentServerPublishingTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let host = LocalDocumentPublicationHost(bindHost: "127.0.0.1", advertisedHost: "127.0.0.1", storageDirectory: root.appendingPathComponent("host"))
    defer {
      host.stop()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()), defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"), legacyDefaultsDomains: [],
      localDocumentPublicationHost: host
    )
    let remote = MobileRemoteCoordinator(defaults: defaults, credentialFile: root.appendingPathComponent("devices.json"))
    remote.attach(to: store)
    remote.setPairingCodeForTesting("515151")
    let paired = await remote.handle(MobileRemoteHTTPRequest(
      method: "POST", path: "/v1/pair",
      body: try MobileRemoteProtocol.encoder().encode(MobileRemotePairRequest(code: "515151", deviceName: "Test Mac"))
    ))
    let token = try MobileRemoteProtocol.decoder().decode(MobileRemotePairResponse.self, from: paired.body).accessToken
    let body = try JSONSerialization.data(withJSONObject: [
      "stableKey": "test-document", "title": "Test document", "format": "html",
      "sourcePath": "notes/example.org", "data": Data("<!doctype html><p>Sealed content</p>".utf8).base64EncodedString(),
    ])
    let response = await remote.handle(MobileRemoteHTTPRequest(
      method: "POST", path: "/v1/document-publications", headers: ["authorization": "Bearer \(token)"], body: body
    ))
    XCTAssertEqual(response.statusCode, 201, String(decoding: response.body, as: UTF8.self))
    let publication = try MobileRemoteProtocol.decoder().decode(MobileRemoteDocumentPublication.self, from: response.body)
    let unauthenticated = await remote.handle(MobileRemoteHTTPRequest(
      method: "POST", path: "/v1/document-publications", body: body))
    XCTAssertEqual(unauthenticated.statusCode, 401)
    for (format, data, expectedStatus) in [
      ("googleDocs", Data("sealed".utf8), 400),
      ("pdf", Data("not a PDF".utf8), 503),
      ("html", Data(repeating: 65, count: 8_000_001), 400),
    ] {
      let invalidBody = try JSONSerialization.data(withJSONObject: [
        "stableKey": "invalid", "title": "Invalid", "format": format,
        "sourcePath": "notes/example.org", "data": data.base64EncodedString(),
      ])
      let invalid = await remote.handle(MobileRemoteHTTPRequest(
        method: "POST", path: "/v1/document-publications", headers: ["authorization": "Bearer \(token)"], body: invalidBody))
      XCTAssertEqual(invalid.statusCode, expectedStatus)
    }
    XCTAssertEqual(store.localDocumentPublications.count, 1)
    await host.stopAndWait()
    let restoredHost = LocalDocumentPublicationHost(bindHost: "127.0.0.1", advertisedHost: "127.0.0.1", storageDirectory: root.appendingPathComponent("host"))
    defer { restoredHost.stop() }
    let restored = try await restoredHost.restorePublications()
    XCTAssertEqual(restored.map(\.url), [publication.url])
    let (served, _) = try await URLSession.shared.data(from: publication.url)
    XCTAssertTrue(String(decoding: served, as: UTF8.self).contains("Sealed content"))

  }
  func testConfiguredServerNeverSilentlyPublishesOnThisMac() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "DocumentServerPublishingTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let host = LocalDocumentPublicationHost(bindHost: "127.0.0.1", advertisedHost: "127.0.0.1")
    defer {
      host.stop()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let pairing = OpenOrgServerPairing(
      endpoint: "http://127.0.0.1:48922", serverName: "Test server", hostRef: nil,
      deviceID: UUID(), pairedAt: Date()
    )
    defaults.set(try MobileRemoteProtocol.encoder().encode(pairing), forKey: OpenOrgServerConnection.pairingKey)
    defaults.set("server", forKey: OpenOrgServerConnection.defaultLocationKey)
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()), defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"), legacyDefaultsDomains: [],
      localDocumentPublicationHost: host
    )
    let text = "#+TITLE: Test document\n* Example\nPublic content.\n"
    let source = root.appendingPathComponent("example.org")
    try text.write(to: source, atomically: true, encoding: .utf8)
    store.selectedEntrySource = EntrySource(file: source.path, startLine: 1, endLineExclusive: 4, text: text, isSubtree: false)
    XCTAssertEqual(store.openOrgServer.effectiveDefaultShareLocation, .server)
    do {
      _ = try await store.publishDocument(DocumentPublishRequest(destination: .localLink, format: .html))
      XCTFail("A missing server credential must fail instead of starting this Mac's host")
    } catch OpenOrgServerError.notPaired {
      // The test intentionally supplies no credential. Hosting must not fall back.
    }
    XCTAssertTrue(store.localDocumentPublications.isEmpty)
    let hosted = try await host.restorePublications()
    XCTAssertTrue(hosted.isEmpty)
  }

  func testDocumentPublisherUsesConfiguredServerAndExplicitMacOverride() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "DocumentServerPublishingTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let localHost = LocalDocumentPublicationHost(bindHost: "127.0.0.1", advertisedHost: "127.0.0.1")
    let serverHost = LocalDocumentPublicationHost(bindHost: "127.0.0.1", advertisedHost: "127.0.0.1", storageDirectory: root.appendingPathComponent("host"))
    defer {
      localHost.stop()
      serverHost.stop()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let serverStore = WorkspaceStore(cli: cli, defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("server-chat.json"), legacyDefaultsDomains: [],
      localDocumentPublicationHost: serverHost)
    let remote = MobileRemoteCoordinator(defaults: defaults, credentialFile: root.appendingPathComponent("devices.json"))
    remote.attach(to: serverStore)
    remote.setPairingCodeForTesting("515151")
    let connection = OpenOrgServerConnection(defaults: defaults, credentials: OpenOrgServerMemoryCredentials()) { request in
      let response = await remote.handle(MobileRemoteHTTPRequest(
        method: request.method, path: request.path,
        headers: request.accessToken.map { ["authorization": "Bearer \($0)"] } ?? [:], body: request.body ?? Data()
      ))
      return OpenOrgServerHTTPResponse(statusCode: response.statusCode, body: response.body)
    }
    try await connection.pair(endpointText: "http://127.0.0.1:48922", code: "515151", deviceName: "Test Mac")
    connection.setDefaultShareLocation(.server)
    let store = WorkspaceStore(cli: cli, defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("client-chat.json"), legacyDefaultsDomains: [],
      localDocumentPublicationHost: localHost, openOrgServerConnection: connection)
    let text = "#+TITLE: Test document\n* Example\n:PROPERTIES:\n:PRIVATE: hidden-marker\n:END:\nPublic content.\n"
    let source = root.appendingPathComponent("example.org")
    try text.write(to: source, atomically: true, encoding: .utf8)
    store.selectedEntrySource = EntrySource(file: source.path, startLine: 1, endLineExclusive: 7, text: text, isSubtree: false)
    let request = DocumentPublishRequest(destination: .localLink, format: .html)
    // Preview does not create a link on either host.
    _ = try await store.previewDocumentPublication(request)
    XCTAssertTrue(serverStore.localDocumentPublications.isEmpty)
    XCTAssertTrue(store.localDocumentPublications.isEmpty)
    let outcome = try await store.publishDocument(request)
    guard case .serverLink(let publication, _) = outcome else { return XCTFail("Ignored configured server") }
    XCTAssertTrue(store.localDocumentPublications.isEmpty)
    XCTAssertEqual(publication.openURL, publication.url)
    XCTAssertEqual(serverStore.localDocumentPublications.map(\.id), [publication.id])
    let (data, _) = try await URLSession.shared.data(from: publication.url)
    let html = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(html.contains("Public content."))
    XCTAssertFalse(html.contains("hidden-marker"))
    let changedText = text.replacingOccurrences(of: "Public content.", with: "Changed content.")
    try changedText.write(to: source, atomically: true, encoding: .utf8)
    store.selectedEntrySource = EntrySource(file: source.path, startLine: 1, endLineExclusive: 7, text: changedText, isSubtree: false)
    let again = try await store.publishDocument(request)
    guard case .serverLink(let updated, _) = again else { return XCTFail("Ignored configured server on republish") }
    XCTAssertEqual(publication.url, updated.url)
    let (updatedData, _) = try await URLSession.shared.data(from: updated.url)
    XCTAssertTrue(String(decoding: updatedData, as: UTF8.self).contains("Changed content."))
    let local = try await store.publishDocument(DocumentPublishRequest(destination: .localLink, format: .html, host: .thisMac))
    guard case .localLink(let localPublication, _) = local else { return XCTFail("Ignored explicit Mac override") }
    XCTAssertNotEqual(localPublication.url, publication.url)
    XCTAssertEqual(connection.effectiveDefaultShareLocation, .server)
    await connection.refreshDocumentPublications()
    XCTAssertEqual(connection.documentPublications.map(\.id), [publication.id])
    try await store.revokeServerDocumentPublication(publication.id)
    XCTAssertTrue(connection.documentPublications.isEmpty)
    let (_, stoppedResponse) = try await URLSession.shared.data(from: publication.url)
    XCTAssertEqual((stoppedResponse as? HTTPURLResponse)?.statusCode, 404)
    let (localData, _) = try await URLSession.shared.data(from: localPublication.url)
    XCTAssertTrue(String(decoding: localData, as: UTF8.self).contains("Changed content."))
  }

  func testOldServerExplainsUpgradeWithoutStartingMacHost() async throws {
    let suite = "DocumentServerPublishingTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let connection = OpenOrgServerConnection(defaults: defaults, credentials: OpenOrgServerMemoryCredentials()) { request in
      let body: Data
      if request.path == "/v1/pair" {
        body = try MobileRemoteProtocol.encoder().encode(MobileRemotePairResponse(
          serverName: "Test server", deviceID: UUID(), accessToken: "test-credential"))
      } else if request.path == "/v1/status" {
        body = try JSONSerialization.data(withJSONObject: [
          "protocolVersion": 2, "serverName": "Test server", "threadCount": 0, "runningThreadCount": 0,
        ])
      } else {
        XCTFail("Must not upload to a server that lacks document hosting")
        throw OpenOrgServerError.connection("Unexpected upload")
      }
      return OpenOrgServerHTTPResponse(statusCode: 200, body: body)
    }
    try await connection.pair(endpointText: "http://127.0.0.1:48922", code: "515151", deviceName: "Test Mac")
    do {
      _ = try await connection.publishDocument(MobileRemoteDocumentPublishRequest(
        stableKey: "example", title: "Example", format: "html", sourcePath: "example.org", data: Data("sealed".utf8)))
      XCTFail("Expected upgrade requirement")
    } catch OpenOrgServerError.documentPublishingUnsupported {}
  }

}
