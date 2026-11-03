import XCTest
@testable import Org2WorkspaceCore

/// The phone keeps no corpus: it lists, searches, reads, downloads, and
/// captures through the paired host.
final class MobileRemoteCorpusAccessTests: XCTestCase {
  @MainActor
  func testPhoneReadsSearchesAndCapturesThroughThePairedHost() async throws {
    let repoRoot = try Org2CLI.defaultRepoRoot()
    guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("dist/cli.js").path) else {
      throw XCTSkip("Run npm run build first; this test drives the real CLI.")
    }
    let corpus = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-mobile-corpus-\(UUID().uuidString)", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: corpus.appendingPathComponent("notes/private"), withIntermediateDirectories: true)
    try fm.createDirectory(at: corpus.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
    try fm.createDirectory(at: corpus.appendingPathComponent(".celorga"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: corpus) }
    try #"{"$schema": "org2:config:v1", "ignorePatterns": ["notes/private"], "todo": {"sequences": ["TODO WAITING | DONE"]}}"#
      .write(to: corpus.appendingPathComponent("celorga.json"), atomically: true, encoding: .utf8)
    try "* Coffee\n:PROPERTIES:\n:ID: coffee-node\n:END:\n** Pour over\nBloom for thirty seconds.\n"
      .write(to: corpus.appendingPathComponent("notes/coffee.org"), atomically: true, encoding: .utf8)
    try "* Secret\n".write(to: corpus.appendingPathComponent("notes/private/secret.org"), atomically: true, encoding: .utf8)
    try "* Dependency\n".write(to: corpus.appendingPathComponent("node_modules/pkg/readme.org"), atomically: true, encoding: .utf8)
    try "{}".write(to: corpus.appendingPathComponent(".celorga/state.json"), atomically: true, encoding: .utf8)
    try "Plain notes\n".write(to: corpus.appendingPathComponent("todo.txt"), atomically: true, encoding: .utf8)
    try Data([0x25, 0x50, 0x44, 0x46]).write(to: corpus.appendingPathComponent("report.pdf"))

    let suite = "MobileRemoteCorpusAccessTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot), defaults: defaults, legacyDefaultsDomains: [])
    store.corpusRoot = corpus
    let credentials = fm.temporaryDirectory.appendingPathComponent("celorga-mobile-devices-\(UUID().uuidString).json")
    defer { try? fm.removeItem(at: credentials) }
    let remote = MobileRemoteCoordinator(defaults: defaults, credentialFile: credentials)
    remote.attach(to: store)
    remote.setPairingCodeForTesting("515151")
    let token = try await call(remote, "POST", "/v1/pair", MobileRemotePairRequest(
      code: "515151", deviceName: "Phone"
    ), as: MobileRemotePairResponse.self).accessToken

    let status = try await call(remote, "GET", "/v1/status", Optional<String>.none, token: token,
                                as: MobileRemoteServerStatus.self)
    XCTAssertEqual(status.supportsCorpusAccess, true)

    // Unpaired requests are refused.
    let unpaired = try await rawCall(remote, "GET", "/v1/corpus/files", Optional<String>.none)
    XCTAssertEqual(unpaired.statusCode, 401)

    // The catalog lists readable text files and honors ignores and hidden folders.
    let catalog = try await call(remote, "GET", "/v1/corpus/files", Optional<String>.none, token: token,
                                 as: MobileRemoteCorpusCatalog.self)
    XCTAssertEqual(catalog.corpusName, corpus.lastPathComponent)
    XCTAssertEqual(catalog.files.map(\.path), ["celorga.json", "notes/coffee.org", "todo.txt"])
    XCTAssertEqual(catalog.todoSequences, ["TODO WAITING | DONE"])
    XCTAssertNotNil(catalog.files.first?.modifiedAt)

    // Search returns the enclosing heading, with its ancestry and ID.
    let search = try await call(remote, "POST", "/v1/corpus/search",
                                MobileRemoteCorpusSearchRequest(query: "bloom"), token: token,
                                as: MobileRemoteCorpusSearchResponse.self)
    let hit = try XCTUnwrap(search.results.first)
    XCTAssertEqual(hit.path, "notes/coffee.org")
    XCTAssertEqual(hit.title, "Pour over")
    XCTAssertEqual(hit.line, 5)
    XCTAssertEqual(hit.parent, "Coffee")

    // An id: link resolves on the host.
    let resolved = try await call(remote, "POST", "/v1/corpus/resolve-id",
                                  MobileRemoteResolveIDRequest(id: "coffee-node"), token: token,
                                  as: MobileRemoteResolvedLocation.self)
    XCTAssertEqual(resolved, MobileRemoteResolvedLocation(path: "notes/coffee.org", line: 1))
    let missingID = try await rawCall(remote, "POST", "/v1/corpus/resolve-id",
                                      MobileRemoteResolveIDRequest(id: "nope"), token: token)
    XCTAssertEqual(missingID.statusCode, 404)

    // Plain-text files read through the existing preview; binaries download.
    let text = try await call(remote, "POST", "/v1/files/preview",
                              MobileRemoteFilePreviewRequest(path: "todo.txt"), token: token,
                              as: MobileRemoteFilePreview.self)
    XCTAssertEqual(text.content, "Plain notes\n")
    let pdf = try await call(remote, "POST", "/v1/files/download",
                             MobileRemoteFileDownloadRequest(path: "report.pdf"), token: token,
                             as: MobileRemoteFileDownload.self)
    XCTAssertEqual(pdf.data, Data([0x25, 0x50, 0x44, 0x46]))
    let escape = try await rawCall(remote, "POST", "/v1/files/download",
                                   MobileRemoteFileDownloadRequest(path: "../outside.org"), token: token)
    XCTAssertEqual(escape.statusCode, 404)

    // A capture lands once in the mobile inbox, however often it is retried.
    let entry = "* TODO Call the roaster\nSCHEDULED: <2026-11-03 Tue>\n:PROPERTIES:\n:ID: mobile-20261102T1200-note-ab12\n:KIND: mobile-note\n:END:\n\nAsk about beans.\n"
    let attachment = try await call(remote, "POST", "/v1/capture/attachment",
      MobileRemoteCaptureAttachmentRequest(entryID: "20261102T1200-note-ab12", filename: "photo.jpg", data: Data([1, 2, 3])),
      token: token, as: MobileRemoteCaptureResponse.self)
    XCTAssertEqual(attachment.path, "mobile-inbox-assets/20261102T1200-note-ab12/photo.jpg")
    XCTAssertEqual(try Data(contentsOf: corpus.appendingPathComponent(attachment.path)), Data([1, 2, 3]))
    let first = try await call(remote, "POST", "/v1/capture",
      MobileRemoteCaptureRequest(entryID: "20261102T1200-note-ab12", content: entry),
      token: token, as: MobileRemoteCaptureResponse.self)
    XCTAssertEqual(first, MobileRemoteCaptureResponse(accepted: true, path: "mobile-inbox.org", duplicate: false))
    let retry = try await call(remote, "POST", "/v1/capture",
      MobileRemoteCaptureRequest(entryID: "20261102T1200-note-ab12", content: entry),
      token: token, as: MobileRemoteCaptureResponse.self)
    XCTAssertTrue(retry.duplicate)
    let inbox = try String(contentsOf: corpus.appendingPathComponent("mobile-inbox.org"), encoding: .utf8)
    XCTAssertTrue(inbox.hasPrefix("#+TITLE: Celorga Mobile Inbox\n\n* TODO Call the roaster\n"), inbox)
    XCTAssertEqual(inbox.components(separatedBy: ":ID: mobile-20261102T1200-note-ab12").count, 2)

    // Malformed captures and attachment paths are refused.
    for content in ["no heading", "* One\n:ID: mobile-x\n* Two\n", "* Missing id\n"] {
      let refused = try await rawCall(remote, "POST", "/v1/capture",
        MobileRemoteCaptureRequest(entryID: "x", content: content), token: token)
      XCTAssertEqual(refused.statusCode, 422, content)
    }
    let badName = try await rawCall(remote, "POST", "/v1/capture/attachment",
      MobileRemoteCaptureAttachmentRequest(entryID: "abc", filename: "../evil.org", data: Data()), token: token)
    XCTAssertEqual(badName.statusCode, 422)
    let badEntry = try await rawCall(remote, "POST", "/v1/capture/attachment",
      MobileRemoteCaptureAttachmentRequest(entryID: "../abc", filename: "ok.jpg", data: Data()), token: token)
    XCTAssertEqual(badEntry.statusCode, 422)
  }

  @MainActor
  func testOrgAttachmentRejectsConcurrentReplacementAndSymlinkEscape() async throws {
    let fm = FileManager.default
    let container = fm.temporaryDirectory.appendingPathComponent("mobile-attachment-\(UUID().uuidString)")
    let corpus = container.appendingPathComponent("corpus")
    let folder = corpus.appendingPathComponent("mobile-inbox-assets/entry")
    let outside = container.appendingPathComponent("outside")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: container) }
    let suite = "MobileAttachmentTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()), defaults: defaults, legacyDefaultsDomains: [])
    store.corpusRoot = corpus
    let destination = folder.appendingPathComponent("note.org")
    try "* Original\n".write(to: destination, atomically: true, encoding: .utf8)
    await store.documentMutationLane.setEventHookForTesting { event in
      guard case .willCommit(_, let path, _) = event, path == destination.path else { return }
      try? "* External\n".write(to: destination, atomically: true, encoding: .utf8)
    }
    do {
      _ = try await store.mobileRemoteCaptureAttachment(MobileRemoteCaptureAttachmentRequest(
        entryID: "entry", filename: "note.org", data: Data("* Upload\n".utf8)
      ))
      XCTFail("An Org attachment must not overwrite a concurrent document edit")
    } catch let error as WorkspaceDocumentMutationError {
      XCTAssertEqual(error, .fileChanged(file: destination.path))
    }
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "* External\n")
    await store.documentMutationLane.setEventHookForTesting(nil)
    // The binary path must also remain within the active corpus.
    try fm.removeItem(at: folder)
    try fm.createSymbolicLink(at: folder, withDestinationURL: outside)
    do {
      _ = try await store.mobileRemoteCaptureAttachment(MobileRemoteCaptureAttachmentRequest(
        entryID: "entry", filename: "photo.jpg", data: Data([1, 2, 3])
      ))
      XCTFail("An attachment directory must not escape through a symlink")
    } catch let error as WorkspaceDocumentMutationError {
      guard case .outsideCorpus = error else { return XCTFail("Unexpected error: \(error)") }
    }
    XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("photo.jpg").path))
  }

  func testIgnorePatternsMatchLikeTheCorpusConfig() {
    XCTAssertTrue(WorkspaceStore.mobileCorpusPath("archive/2024/a.org", matches: "archive"))
    XCTAssertTrue(WorkspaceStore.mobileCorpusPath("a/b/c.org", matches: "**/c.org"))
    XCTAssertTrue(WorkspaceStore.mobileCorpusPath("drafts/x.tmp.org", matches: "drafts/*.tmp.org"))
    XCTAssertFalse(WorkspaceStore.mobileCorpusPath("notes/a.org", matches: "archive"))
    XCTAssertTrue(WorkspaceStore.shouldSkipMobileCorpusPath("a.sync-conflict-1.org", name: "a.sync-conflict-1.org", ignorePatterns: []))
  }

  @MainActor
  private func rawCall<Body: Encodable>(
    _ remote: MobileRemoteCoordinator,
    _ method: String,
    _ path: String,
    _ body: Body?,
    token: String? = nil
  ) async throws -> MobileRemoteHTTPResponse {
    var headers = ["Content-Type": "application/json"]
    if let token { headers["Authorization"] = "Bearer \(token)" }
    let data = try body.map { try MobileRemoteProtocol.encoder().encode($0) } ?? Data()
    return await remote.handle(MobileRemoteHTTPRequest(method: method, path: path, headers: headers, body: data))
  }

  @MainActor
  private func call<Body: Encodable, Response: Decodable>(
    _ remote: MobileRemoteCoordinator,
    _ method: String,
    _ path: String,
    _ body: Body?,
    token: String? = nil,
    as type: Response.Type
  ) async throws -> Response {
    let response = try await rawCall(remote, method, path, body, token: token)
    XCTAssertLessThan(response.statusCode, 300, String(decoding: response.body, as: UTF8.self))
    return try MobileRemoteProtocol.decoder().decode(type, from: response.body)
  }
}
