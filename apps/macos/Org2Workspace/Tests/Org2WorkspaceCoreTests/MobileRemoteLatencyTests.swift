import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// The phone's new-chat path: large JSON is compressed for clients that ask,
/// and every destination's models are available without opening a chat.
final class MobileRemoteLatencyTests: XCTestCase {
  func testLargeJSONIsDeflatedOnlyForClientsThatAskForIt() throws {
    let rows: [[String: String]] = (0..<2_000).map { _ in
      ["id": UUID().uuidString, "title": "New Chat", "runtime": "codex"]
    }
    let response = MobileRemoteHTTPResponse.json(["threads": rows])
    XCTAssertGreaterThan(response.body.count, 100_000)

    let compressed = MobileRemoteHTTPCompression.negotiated(response, acceptEncoding: "gzip, deflate, br")
    XCTAssertEqual(compressed.headers["Content-Encoding"], "deflate")
    XCTAssertEqual(compressed.headers["Vary"], "Accept-Encoding")
    XCTAssertEqual(compressed.statusCode, response.statusCode)
    XCTAssertLessThan(compressed.body.count, response.body.count / 2)
    XCTAssertEqual(try Self.inflateZlib(compressed.body), response.body)

    // Older phones send no Accept-Encoding and keep identity bodies.
    XCTAssertEqual(MobileRemoteHTTPCompression.negotiated(response, acceptEncoding: nil), response)
    XCTAssertEqual(MobileRemoteHTTPCompression.negotiated(response, acceptEncoding: "gzip"), response)
    XCTAssertEqual(MobileRemoteHTTPCompression.negotiated(response, acceptEncoding: "deflate;q=0"), response)
    let small = MobileRemoteHTTPResponse.json(["ok": true])
    XCTAssertEqual(MobileRemoteHTTPCompression.negotiated(small, acceptEncoding: "deflate"), small)
    let binary = MobileRemoteHTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/pdf"], body: Data(repeating: 1, count: 10_000)
    )
    XCTAssertEqual(MobileRemoteHTTPCompression.negotiated(binary, acceptEncoding: "deflate"), binary)
  }

  func testAdler32MatchesKnownValues() {
    XCTAssertEqual(MobileRemoteHTTPCompression.adler32(Data()), 1)
    XCTAssertEqual(MobileRemoteHTTPCompression.adler32(Data("Wikipedia".utf8)), 0x11E6_0398)
    // Long input exercises the deferred modulo.
    let long = Data(repeating: 0xFF, count: 100_000)
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in long { a = (a + UInt32(byte)) % 65_521; b = (b + a) % 65_521 }
    XCTAssertEqual(MobileRemoteHTTPCompression.adler32(long), (b << 16) | a)
  }

  @MainActor
  func testDestinationConfigurationsReturnCachedCatalogsWithoutOpeningAChat() async throws {
    let suite = "MobileRemoteLatencyTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mobile-latency-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: root), defaults: defaults, legacyDefaultsDomains: [])
    let credentials = root.appendingPathComponent("devices.json")
    let remote = MobileRemoteCoordinator(defaults: defaults, credentialFile: credentials)
    remote.attach(to: store)
    remote.setPairingCodeForTesting("424242")
    let pair = await remote.handle(MobileRemoteHTTPRequest(
      method: "POST", path: "/v1/pair", headers: ["Content-Type": "application/json"],
      body: try MobileRemoteProtocol.encoder().encode(MobileRemotePairRequest(code: "424242", deviceName: "Phone"))
    ))
    let token = try MobileRemoteProtocol.decoder().decode(MobileRemotePairResponse.self, from: pair.body).accessToken

    let codexID = AIChatDestinationConfiguration.localCodexID
    XCTAssertTrue(store.enabledAIChatDestinations.contains { $0.id == codexID })
    store.aiChatConfigurationCatalogCache[codexID] = AIChatConfigurationCatalogCacheEntry(
      requestedModel: nil,
      models: [AIChatModelOption(id: "gpt-test", label: "GPT Test", isDefault: true)],
      effectiveModel: "gpt-test",
      reasoningOptions: [AIChatReasoningOption(id: "high", label: "High")],
      defaultReasoningEffort: "high"
    )

    let response = await remote.handle(MobileRemoteHTTPRequest(
      method: "GET", path: "/v1/destinations/configurations",
      headers: ["Authorization": "Bearer \(token)"], body: Data()
    ))
    XCTAssertEqual(response.statusCode, 200)
    let decoded = try MobileRemoteProtocol.decoder().decode(MobileRemoteDestinationConfigurations.self, from: response.body)
    let codex = try XCTUnwrap(decoded.destinations.first { $0.destinationID == codexID })
    XCTAssertEqual(codex.models.map(\.id), ["gpt-test"])
    XCTAssertEqual(codex.reasoningOptions.map(\.id), ["high"])
    XCTAssertEqual(codex.defaultReasoningEffort, "high")
    XCTAssertFalse(decoded.destinations.contains { $0.destinationID == AIChatDestinationConfiguration.openClawID },
      "Destinations without a cached catalog are omitted rather than waited on")

    let unpaired = await remote.handle(MobileRemoteHTTPRequest(
      method: "GET", path: "/v1/destinations/configurations", headers: [:], body: Data()
    ))
    XCTAssertEqual(unpaired.statusCode, 401)
  }

  /// An independent RFC 1950 reader: header check, raw inflate, checksum.
  static func inflateZlib(_ data: Data) throws -> Data {
    XCTAssertEqual(data.first, 0x78)
    XCTAssertEqual((UInt16(data[0]) << 8 | UInt16(data[1])) % 31, 0)
    let raw = data.subdata(in: 2..<(data.count - 4))
    let inflated = try (raw as NSData).decompressed(using: .zlib) as Data
    let trailer = data.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    XCTAssertEqual(trailer, MobileRemoteHTTPCompression.adler32(inflated))
    return inflated
  }
}
