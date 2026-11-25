import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// In-memory S3-compatible store: signed PUT/DELETE under /BUCKET/KEY and
/// anonymous GET under /public/KEY.
private final class FakeBucketStore: @unchecked Sendable {
  private let lock = NSLock()
  private var objects: [String: (data: Data, contentType: String)] = [:]

  var keys: [String] { lock.withLock { objects.keys.sorted() } }

  func handle(_ request: MobileRemoteHTTPRequest) -> MobileRemoteHTTPResponse {
    if request.path.hasPrefix("/public/") {
      let key = String(request.path.dropFirst("/public/".count))
      guard let object = lock.withLock({ objects[key] }) else {
        return MobileRemoteHTTPResponse(statusCode: 404, body: Data("missing".utf8))
      }
      return MobileRemoteHTTPResponse(statusCode: 200, headers: ["Content-Type": object.contentType], body: object.data)
    }
    guard request.headers["authorization"]?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDTEST/") == true,
          request.path.hasPrefix("/team-links/")
    else {
      return MobileRemoteHTTPResponse(statusCode: 403, body: Data("<Error><Code>AccessDenied</Code></Error>".utf8))
    }
    let key = String(request.path.dropFirst("/team-links/".count))
    switch request.method {
    case "PUT":
      lock.withLock { objects[key] = (request.body, request.headers["content-type"] ?? "") }
      return MobileRemoteHTTPResponse(statusCode: 200)
    case "DELETE":
      _ = lock.withLock { objects.removeValue(forKey: key) }
      return MobileRemoteHTTPResponse(statusCode: 204)
    default:
      return MobileRemoteHTTPResponse(statusCode: 405)
    }
  }
}

@MainActor
final class PublicBucketPublishingTests: XCTestCase {
  func testPublicLinkOffersTheLocalFormatsAndPreviewsTheSealedProjection() {
    XCTAssertEqual(DocumentPublishDestination.publicLink.formats, DocumentPublishDestination.localLink.formats)
    XCTAssertEqual(DocumentPublishDestination.publicLink.title, "Public Link")
    let source = URL(fileURLWithPath: "/tmp/example.org")
    let preview = WorkspaceStore.documentPublishArguments(
      sourceFile: source,
      request: DocumentPublishRequest(destination: .publicLink, format: .html, line: 4),
      outputDirectory: URL(fileURLWithPath: "/tmp/preview"),
      apply: false
    )
    XCTAssertEqual(preview, [
      "publish", "document", "--file", "/tmp/example.org", "--to", "web", "--format", "json",
      "--line", "4", "--out-dir", "/tmp/preview",
    ])
  }

  func testPublishArgumentsCarryTheBucketAndReuseTheLinkWithoutSecrets() {
    let configuration = PublicBucketConfiguration(
      endpoint: " https://account.r2.cloudflarestorage.com/team-links ",
      bucket: "",
      region: "",
      publicBaseURL: "https://pub-example.r2.dev",
      keyPrefix: "p/"
    )
    XCTAssertTrue(configuration.isComplete)
    XCTAssertEqual(configuration.displayName, "team-links")
    let arguments = WorkspaceStore.publicBucketPublishArguments(
      sourceFile: URL(fileURLWithPath: "/tmp/example.org"),
      request: DocumentPublishRequest(destination: .publicLink, format: .pdf),
      configuration: configuration,
      objectID: "abcdefghijklmnopqrstuvwxyz012345",
      pdfFile: URL(fileURLWithPath: "/tmp/out.pdf")
    )
    XCTAssertEqual(arguments, [
      "publish", "document", "--file", "/tmp/example.org", "--to", "bucket", "--format", "json",
      "--endpoint", "https://account.r2.cloudflarestorage.com/team-links",
      "--public-base-url", "https://pub-example.r2.dev", "--region", "auto", "--key-prefix", "p/",
      "--object-id", "abcdefghijklmnopqrstuvwxyz012345", "--replace-existing",
      "--pdf-file", "/tmp/out.pdf", "--apply",
    ])
    let credentials = PublicBucketCredentials(accessKeyID: " AKID ", secretAccessKey: "secret-value")
    XCTAssertFalse(arguments.contains("secret-value"))
    XCTAssertEqual(credentials.environment["CELORGA_BUCKET_ACCESS_KEY_ID"], "AKID")
    XCTAssertEqual(credentials.environment["CELORGA_BUCKET_SECRET_ACCESS_KEY"], "secret-value")
  }

  func testConfigurationAndLinksPersistMachineLocally() throws {
    let suite = "PublicBucketPublishingTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertNil(PublicBucketConfiguration.load(defaults: defaults))
    let configuration = PublicBucketConfiguration(endpoint: "https://s3.us-east-1.amazonaws.com", bucket: "team-links", region: "us-east-1", publicBaseURL: "https://team-links.s3.amazonaws.com")
    PublicBucketConfiguration.save(configuration, defaults: defaults)
    XCTAssertEqual(PublicBucketConfiguration.load(defaults: defaults), configuration)
    let encoded = try XCTUnwrap(defaults.data(forKey: PublicBucketConfiguration.defaultsKey))
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).lowercased().contains("secret"))
    PublicBucketConfiguration.save(nil, defaults: defaults)
    XCTAssertNil(PublicBucketConfiguration.load(defaults: defaults))
  }

  func testPublishUpdateAndStopAPublicLinkInABucket() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "PublicBucketPublishingTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let fake = FakeBucketStore()
    let server = MobileRemoteHTTPServer { request in fake.handle(request) }
    let port = UInt16.random(in: 50_000...59_999)
    try server.start(host: "127.0.0.1", port: port)
    let host = LocalDocumentPublicationHost(bindHost: "127.0.0.1", advertisedHost: "127.0.0.1")
    defer {
      server.stop()
      host.stop()
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()), defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"), legacyDefaultsDomains: [],
      localDocumentPublicationHost: host
    )
    let configuration = PublicBucketConfiguration(
      endpoint: "http://127.0.0.1:\(port)/team-links",
      publicBaseURL: "http://127.0.0.1:\(port)/public"
    )
    let text = "#+TITLE: Field notes\n* Summary\n:PROPERTIES:\n:PRIVATE: hidden-marker\n:END:\nPublic content.\n"
    let source = root.appendingPathComponent("notes.org")
    try text.write(to: source, atomically: true, encoding: .utf8)
    store.selectedEntrySource = EntrySource(file: source.path, startLine: 1, endLineExclusive: 7, text: text, isSubtree: false)
    let request = DocumentPublishRequest(destination: .publicLink, format: .html)

    // Not configured: publishing fails before any upload.
    do {
      _ = try await store.publishDocument(request)
      XCTFail("Published without a bucket")
    } catch {
      XCTAssertEqual(error as? PublicBucketError, .notConfigured)
    }

    store.savePublicBucketConfiguration(configuration)
    store.publicBucketCredentialsForTesting = PublicBucketCredentials(accessKeyID: "AKIDTEST", secretAccessKey: "secret-test-only")
    XCTAssertTrue(store.isPublicBucketReady)

    let check = try await store.checkPublicBucket(configuration, credentials: store.publicBucketCredentialsForTesting!)
    XCTAssertTrue(check.publiclyReadable)
    XCTAssertTrue(fake.keys.isEmpty)

    // Preview uses the sealed web projection and uploads nothing.
    _ = try await store.previewDocumentPublication(request)
    XCTAssertTrue(fake.keys.isEmpty)

    let outcome = try await store.publishDocument(request)
    guard case .publicLink(let publication, _) = outcome else { return XCTFail("Expected a public link") }
    XCTAssertEqual(fake.keys, ["p/\(publication.id)/index.html"])
    XCTAssertEqual(publication.url.absoluteString, "http://127.0.0.1:\(port)/public/p/\(publication.id)/index.html")
    XCTAssertEqual(store.publicBucketPublications.map(\.id), [publication.id])
    XCTAssertEqual(store.publicBucketPublication(for: request)?.id, publication.id)
    let (data, _) = try await URLSession.shared.data(from: publication.url)
    let html = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(html.contains("Public content."))
    XCTAssertFalse(html.contains("hidden-marker"))

    // Publishing the same document again keeps the link.
    let changed = text.replacingOccurrences(of: "Public content.", with: "Changed content.")
    try changed.write(to: source, atomically: true, encoding: .utf8)
    store.selectedEntrySource = EntrySource(file: source.path, startLine: 1, endLineExclusive: 7, text: changed, isSubtree: false)
    let again = try await store.publishDocument(request)
    guard case .publicLink(let updated, _) = again else { return XCTFail("Expected a public link") }
    XCTAssertEqual(updated.id, publication.id)
    XCTAssertEqual(updated.createdAt, publication.createdAt)
    let (updatedData, _) = try await URLSession.shared.data(from: updated.url)
    XCTAssertTrue(String(decoding: updatedData, as: UTF8.self).contains("Changed content."))

    // Links survive a relaunch, and stopping deletes the object.
    let relaunched = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()), defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat2.json"), legacyDefaultsDomains: [],
      localDocumentPublicationHost: host
    )
    relaunched.reloadPublicBucketPublications()
    XCTAssertEqual(relaunched.publicBucketPublications.map(\.id), [publication.id])
    try await store.revokePublicBucketPublication(publication.id)
    XCTAssertTrue(fake.keys.isEmpty)
    XCTAssertTrue(store.publicBucketPublications.isEmpty)
    let (_, stopped) = try await URLSession.shared.data(from: publication.url)
    XCTAssertEqual((stopped as? HTTPURLResponse)?.statusCode, 404)
  }
}
