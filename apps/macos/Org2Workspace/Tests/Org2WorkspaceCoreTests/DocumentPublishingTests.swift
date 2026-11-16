import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class DocumentPublishingTests: XCTestCase {
  private actor RequestCapture {
    private(set) var request: URLRequest?

    func record(_ request: URLRequest) {
      self.request = request
    }
  }

  func testDestinationFormatMatrixKeepsLocalAndGoogleOutputsDistinct() {
    XCTAssertEqual(
      DocumentPublishDestination.localLink.formats,
      [.html, .pdf, .beamerSlides]
    )
    XCTAssertEqual(
      DocumentPublishDestination.googleDrive.formats,
      [.googleDocs, .googleSlides, .googleSheets, .pdf]
    )
    XCTAssertEqual(DocumentPublishFormat.googleDocs.googleCLIDestination, "google-docs")
    XCTAssertEqual(DocumentPublishFormat.googleSlides.googleCLIDestination, "google-slides")
    XCTAssertEqual(DocumentPublishFormat.googleSheets.googleCLIDestination, "google-sheets")
    XCTAssertEqual(DocumentPublishFormat.pdf.googleCLIDestination, "google-drive-pdf")
    XCTAssertNil(DocumentPublishFormat.beamerSlides.googleCLIDestination)
  }

  func testSlideFormatsAppearOnlyWhileViewingSlides() {
    XCTAssertEqual(
      DocumentPublishDestination.localLink.formats(showingSlides: false),
      [.html, .pdf]
    )
    XCTAssertEqual(
      DocumentPublishDestination.googleDrive.formats(showingSlides: false),
      [.googleDocs, .googleSheets, .pdf]
    )
    XCTAssertEqual(
      DocumentPublishDestination.localLink.formats(showingSlides: true),
      DocumentPublishDestination.localLink.formats
    )
    XCTAssertEqual(
      DocumentPublishDestination.googleDrive.formats(showingSlides: true),
      DocumentPublishDestination.googleDrive.formats
    )
  }

  func testGoogleDisclosurePreviewDoesNotReceiveLocalOutputArguments() {
    let arguments = WorkspaceStore.documentPublishArguments(
      sourceFile: URL(fileURLWithPath: "/tmp/recipes.org2"),
      request: DocumentPublishRequest(
        destination: .googleDrive,
        format: .googleDocs,
        googleFolderID: "folder-123"
      ),
      outputDirectory: URL(fileURLWithPath: "/tmp/openorg-publish-preview"),
      apply: false
    )

    XCTAssertEqual(
      arguments,
      [
        "publish", "document",
        "--file", "/tmp/recipes.org2",
        "--to", "google-docs",
        "--format", "json",
        "--folder-id", "folder-123",
      ]
    )
    XCTAssertFalse(arguments.contains("--out-dir"))
    XCTAssertFalse(arguments.contains("--out-file"))
  }

  func testLinkedGooglePublicationUsesGuardedUpdateArgumentsInsteadOfFolder() throws {
    let binding = GoogleDrivePublicationBinding(
      format: .googleDocs,
      fileID: "doc-stable",
      url: try XCTUnwrap(URL(string: "https://docs.google.com/document/d/doc-stable/edit")),
      version: "12"
    )
    let arguments = WorkspaceStore.documentPublishArguments(
      sourceFile: URL(fileURLWithPath: "/tmp/brief.org2"),
      request: DocumentPublishRequest(
        destination: .googleDrive,
        format: .googleDocs,
        googleFolderID: "ignored-after-linking"
      ),
      outputDirectory: nil,
      googleBinding: binding,
      apply: true
    )

    XCTAssertEqual(
      arguments,
      [
        "publish", "document",
        "--file", "/tmp/brief.org2",
        "--to", "google-docs",
        "--format", "json",
        "--document-id", "doc-stable",
        "--if-version", "12",
        "--replace-existing",
        "--apply",
      ]
    )
    XCTAssertFalse(arguments.contains("--folder-id"))
  }

  func testLinkedGooglePublicationWithoutDriveVersionStillUpdatesExistingFile() throws {
    let binding = GoogleDrivePublicationBinding(
      format: .googleDocs,
      fileID: "doc-stable",
      url: try XCTUnwrap(URL(string: "https://docs.google.com/document/d/doc-stable/edit"))
    )
    let arguments = WorkspaceStore.documentPublishArguments(
      sourceFile: URL(fileURLWithPath: "/tmp/brief.org2"),
      request: DocumentPublishRequest(
        destination: .googleDrive,
        format: .googleDocs,
        googleFolderID: "ignored-after-linking"
      ),
      outputDirectory: nil,
      googleBinding: binding,
      apply: true
    )

    XCTAssertEqual(
      arguments,
      [
        "publish", "document",
        "--file", "/tmp/brief.org2",
        "--to", "google-docs",
        "--format", "json",
        "--document-id", "doc-stable",
        "--replace-existing",
        "--apply",
      ]
    )
    XCTAssertFalse(arguments.contains("--if-version"))
    XCTAssertFalse(arguments.contains("--folder-id"))
  }

  func testGooglePublicationBindingPersistsAndUpdatesInFileProperties() throws {
    let source = """
    #+TITLE: Stable Brief
    :PROPERTIES:
    :ID: brief-id
    :END:

    * Findings
    Original source stays readable.
    """
    let url = try XCTUnwrap(URL(string: "https://docs.google.com/document/d/doc-stable/edit"))
    let first = GoogleDrivePublicationBinding(
      format: .googleDocs,
      fileID: "doc-stable",
      url: url,
      version: "7",
      publishedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-30T18:00:00Z"))
    )

    let persisted = try XCTUnwrap(
      GoogleDrivePublicationBinding.sourceText(source, upserting: first)
    )
    XCTAssertTrue(persisted.contains(":ID: brief-id"))
    XCTAssertTrue(persisted.contains(":ORG2_PUBLISH_GOOGLE_DOCS_FILE_ID: doc-stable"))
    XCTAssertTrue(persisted.contains(":ORG2_PUBLISH_GOOGLE_DOCS_URL: \(url.absoluteString)"))
    XCTAssertTrue(persisted.contains(":ORG2_PUBLISH_GOOGLE_DOCS_VERSION: 7"))

    let restored = try XCTUnwrap(
      GoogleDrivePublicationBinding.binding(for: .googleDocs, in: persisted, line: nil)
    )
    XCTAssertEqual(restored.fileID, "doc-stable")
    XCTAssertEqual(restored.url, url)
    XCTAssertEqual(restored.version, "7")
    XCTAssertNil(restored.scopeLine)

    let second = GoogleDrivePublicationBinding(
      format: .googleDocs,
      fileID: "doc-stable",
      url: url,
      version: "8",
      publishedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-30T19:00:00Z"))
    )
    let updated = try XCTUnwrap(
      GoogleDrivePublicationBinding.sourceText(persisted, upserting: second)
    )
    XCTAssertEqual(updated.components(separatedBy: ":ORG2_PUBLISH_GOOGLE_DOCS_FILE_ID:").count, 2)
    XCTAssertTrue(updated.contains(":ORG2_PUBLISH_GOOGLE_DOCS_VERSION: 8"))
    XCTAssertFalse(updated.contains(":ORG2_PUBLISH_GOOGLE_DOCS_VERSION: 7"))
  }

  func testGooglePublicationBindingCreatesAFilePropertyDrawerWhenMissing() throws {
    let source = "#+TITLE: New Brief\n\n* Findings\nBody\n"
    let url = try XCTUnwrap(URL(string: "https://drive.google.com/file/d/pdf-stable/view"))
    let binding = GoogleDrivePublicationBinding(
      format: .pdf,
      fileID: "pdf-stable",
      url: url,
      version: "1",
      publishedAt: Date(timeIntervalSince1970: 1_777_777_777)
    )

    let persisted = try XCTUnwrap(
      GoogleDrivePublicationBinding.sourceText(source, upserting: binding)
    )

    XCTAssertTrue(persisted.hasPrefix("#+TITLE: New Brief\n:PROPERTIES:\n"))
    XCTAssertTrue(persisted.contains(":ORG2_PUBLISH_GOOGLE_DRIVE_PDF_FILE_ID: pdf-stable"))
    XCTAssertTrue(persisted.hasSuffix("* Findings\nBody\n"))
    XCTAssertEqual(
      GoogleDrivePublicationBinding.binding(for: .pdf, in: persisted, line: nil)?.url,
      url
    )
  }

  func testGooglePublicationBindingUsesThePublishedSubtreePropertyDrawer() throws {
    let source = """
    #+TITLE: Scoped Brief

    * First
    Keep this separate.
    * Second
    SCHEDULED: <2026-08-31 Mon>
    :PROPERTIES:
    :ID: second-id
    :END:
    Publish this subtree.
    """
    let url = try XCTUnwrap(URL(string: "https://docs.google.com/presentation/d/slides-stable/edit"))
    let binding = GoogleDrivePublicationBinding(
      format: .googleSlides,
      fileID: "slides-stable",
      url: url,
      version: "3",
      publishedAt: Date(timeIntervalSince1970: 1_777_777_777),
      scopeLine: 10
    )

    let persisted = try XCTUnwrap(
      GoogleDrivePublicationBinding.sourceText(source, upserting: binding)
    )
    XCTAssertNil(
      GoogleDrivePublicationBinding.binding(for: .googleSlides, in: persisted, line: nil)
    )
    let restored = try XCTUnwrap(
      GoogleDrivePublicationBinding.binding(for: .googleSlides, in: persisted, line: 10)
    )
    XCTAssertEqual(restored.fileID, "slides-stable")
    XCTAssertEqual(restored.version, "3")
    XCTAssertEqual(restored.scopeLine, 5)
    XCTAssertTrue(persisted.contains(":ID: second-id\n:ORG2_PUBLISH_GOOGLE_SLIDES_FILE_ID: slides-stable"))
    XCTAssertEqual(GoogleDrivePublicationBinding.allBindings(in: persisted), [restored])
  }

  func testLocalPublicationRetainsSourceAndFormatForSettingsManagement() throws {
    let url = try XCTUnwrap(URL(string: "http://example.local:1234/a/secret"))
    let publication = LocalDocumentPublication(
      id: "secret",
      title: "Operating dashboard",
      url: url,
      localURL: url,
      sourcePath: "/Users/example/corpus/views/dashboard.org2",
      format: .html
    )

    XCTAssertEqual(publication.sourcePath, "/Users/example/corpus/views/dashboard.org2")
    XCTAssertEqual(publication.format, .html)
  }

  func testDecodesDisclosurePreviewAndDestinationState() throws {
    let payload = Data(
      #"""
      {
        "$schema": "org2:publish-document-command-result:v1",
        "applied": false,
        "source": {
          "file": "/private/report.org2",
          "selection": "document",
          "sourceHash": "source-hash"
        },
        "artifact": {
          "$schema": "org2:published-document:v1",
          "title": "Market Brief",
          "mediaType": "text/html",
          "selection": "document",
          "artifactHash": "artifact-hash",
          "bytes": 2048,
          "projectionHash": "projection-hash",
          "assets": [
            {
              "name": "chart.png",
              "mediaType": "image/png",
              "bytes": 512,
              "sha256": "asset-hash"
            }
          ]
        },
        "disclosure": {
          "redactions": {
            "metadata": 3,
            "comments": 2,
            "internalLinks": 0
          },
          "warnings": ["One linked file was omitted."]
        },
        "destination": {
          "destination": "google-docs",
          "webViewLink": "https://docs.google.com/document/d/doc-123/edit",
          "fileId": "doc-123",
          "version": "7"
        }
      }
      """#.utf8
    )

    let result = try JSONDecoder().decode(DocumentPublishCLIResult.self, from: payload)

    XCTAssertFalse(result.applied)
    XCTAssertEqual(result.artifact.title, "Market Brief")
    XCTAssertEqual(result.artifact.assets.map(\.name), ["chart.png"])
    XCTAssertEqual(result.redactionCount, 5)
    XCTAssertEqual(result.destinationString("fileId"), "doc-123")
    XCTAssertEqual(result.destinationString("version"), "7")
  }

  func testLocalHostRequiresTheSecretLinkAndSupportsRevocation() async throws {
    let host = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1"
    )
    defer { host.stop() }

    let html = Data("<!doctype html><title>Safe report</title><p>Published body</p>".utf8)
    let publication = try await host.publish(html: html, title: "Safe report")
    let second = try await host.publish(html: html, title: "Another report")

    XCTAssertNotEqual(publication.id, second.id)
    XCTAssertGreaterThanOrEqual(publication.id.count, 40)
    XCTAssertEqual(publication.url.host, "127.0.0.1")

    let (servedData, servedResponse) = try await URLSession.shared.data(from: publication.localURL)
    let servedHTTP = try XCTUnwrap(servedResponse as? HTTPURLResponse)
    XCTAssertEqual(servedHTTP.statusCode, 200)
    XCTAssertEqual(servedData, html)
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "Cache-Control"), "no-store")

    let unavailableURL = try XCTUnwrap(
      URL(string: "http://127.0.0.1:\(publication.localURL.port ?? 0)/a/not-the-secret")
    )
    let (_, unavailableResponse) = try await URLSession.shared.data(from: unavailableURL)
    XCTAssertEqual((unavailableResponse as? HTTPURLResponse)?.statusCode, 404)

    try host.revoke(publication.id)
    let (_, revokedResponse) = try await URLSession.shared.data(from: publication.localURL)
    XCTAssertEqual((revokedResponse as? HTTPURLResponse)?.statusCode, 404)

    let (secondData, secondResponse) = try await URLSession.shared.data(from: second.localURL)
    XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(secondData, html)
  }

  func testSharePreviewMetadataAnnotatesPublishedHTMLOnce() throws {
    let exported = Data("""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <title>Q4 plan</title>
    </head>
    <body>
    <main class="org2-document">
    <h1>Q4 plan</h1>
    <p>  </p>
    <p>Ship the <b>share</b> previews &amp; measure
    adoption.</p>
    </main>
    </body>
    </html>
    """.utf8)
    let annotated = SharePreviewMetadata.annotated(html: exported, title: "Q4 plan")
    let html = try XCTUnwrap(String(data: annotated, encoding: .utf8))
    XCTAssertTrue(html.contains(#"<meta property="og:title" content="Q4 plan">"#))
    XCTAssertTrue(html.contains(#"<meta property="og:description" content="Ship the share previews &amp; measure adoption.">"#))
    XCTAssertTrue(html.contains(#"<meta name="description" content="Ship the share previews &amp; measure adoption.">"#))
    XCTAssertLessThan(html.range(of: "og:title")!.lowerBound, html.range(of: "</head>")!.lowerBound)
    XCTAssertEqual(SharePreviewMetadata.annotated(html: annotated, title: "Q4 plan"), annotated, "Annotating twice is a no-op")

    // A document #+DESCRIPTION wins over the first paragraph, without a duplicate tag.
    let described = Data("""
    <!doctype html><html><head><meta charset="utf-8" />
    <meta name="description" content="Plan for &quot;Q4&quot;" />
    </head><body><main><p>Body text</p></main></body></html>
    """.utf8)
    let describedHTML = try XCTUnwrap(String(data: SharePreviewMetadata.annotated(html: described, title: "Plan"), encoding: .utf8))
    XCTAssertTrue(describedHTML.contains(#"<meta property="og:description" content="Plan for &quot;Q4&quot;">"#))
    XCTAssertEqual(describedHTML.components(separatedBy: #"name="description""#).count - 1, 1)

    let pdf = Data("%PDF-1.7".utf8)
    XCTAssertEqual(SharePreviewMetadata.annotated(html: pdf, title: "x"), pdf)
    XCTAssertEqual(SharePreviewMetadata.truncated(String(repeating: "word ", count: 80), limit: 30).count <= 30, true)
  }

  func testLocalHostServesLinkPreviewMetadataForPublishedPages() async throws {
    let host = LocalDocumentPublicationHost(bindHost: "127.0.0.1", advertisedHost: "127.0.0.1")
    defer { host.stop() }
    let html = Data("<!doctype html><html><head><meta charset=\"utf-8\"><title>Report</title></head><body><main><p>Weekly numbers.</p></main></body></html>".utf8)
    let publication = try await host.publish(html: html, title: "Weekly report")
    let (served, _) = try await URLSession.shared.data(from: publication.localURL)
    let page = try XCTUnwrap(String(data: served, encoding: .utf8))
    XCTAssertTrue(page.contains(#"<meta property="og:title" content="Weekly report">"#))
    XCTAssertTrue(page.contains(#"<meta property="og:description" content="Weekly numbers.">"#))
  }

  func testLocalPublicationOpenURLUsesTheAdvertisedShareLink() async throws {
    let host = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "shareable-host.local"
    )
    defer { host.stop() }

    let publication = try await host.publish(
      html: Data("<!doctype html><title>Shareable report</title>".utf8),
      title: "Shareable report"
    )

    XCTAssertEqual(publication.openURL, publication.url)
    XCTAssertEqual(publication.openURL.host, "shareable-host.local")
    XCTAssertNotEqual(publication.openURL, publication.localURL)
    XCTAssertEqual(publication.localURL.host, "127.0.0.1")
  }

  func testLocalPublicationRepublishUpdatesTheStableSecretURL() async throws {
    let host = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1"
    )
    defer { host.stop() }

    let first = try await host.publish(
      data: Data("<p>First version</p>".utf8),
      title: "Stable report",
      mediaType: "text/html",
      sourcePath: "/tmp/stable-report.org",
      format: .html,
      stableKey: "/tmp/stable-report.org\nscope:document\nformat:html"
    )
    let updated = try await host.publish(
      data: Data("<p>Updated version</p>".utf8),
      title: "Stable report",
      mediaType: "text/html",
      sourcePath: "/tmp/stable-report.org",
      format: .html,
      stableKey: "/tmp/stable-report.org\nscope:document\nformat:html"
    )

    XCTAssertEqual(updated.id, first.id)
    XCTAssertEqual(updated.url, first.url)
    XCTAssertEqual(updated.localURL, first.localURL)
    let (servedData, response) = try await URLSession.shared.data(from: updated.localURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(String(decoding: servedData, as: UTF8.self), "<p>Updated version</p>")
  }

  func testLocalPublicationStableKeyAdoptsTheNewestLegacyPublicationURL() async throws {
    let host = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1"
    )
    defer { host.stop() }

    let original = try await host.publish(
      data: Data("<p>Legacy version</p>".utf8),
      title: "Legacy report",
      mediaType: "text/html",
      sourcePath: "/tmp/legacy-stable-report.org",
      format: .html
    )
    let updated = try await host.publish(
      data: Data("<p>Updated version</p>".utf8),
      title: "Legacy report",
      mediaType: "text/html",
      sourcePath: "/tmp/legacy-stable-report.org",
      format: .html,
      stableKey: "/tmp/legacy-stable-report.org\nscope:document\nformat:html"
    )

    XCTAssertEqual(updated.id, original.id)
    XCTAssertEqual(updated.url, original.url)
    let (servedData, response) = try await URLSession.shared.data(from: updated.localURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(String(decoding: servedData, as: UTF8.self), "<p>Updated version</p>")
  }

  func testLocalPublicationStableKeyIncludesSourceScopeAndFormat() {
    let file = URL(fileURLWithPath: "/tmp/stable-report.org")
    let wholeHTML = WorkspaceStore.localDocumentPublicationStableKey(
      sourceFile: file,
      request: DocumentPublishRequest(destination: .localLink, format: .html)
    )
    let subtreeHTML = WorkspaceStore.localDocumentPublicationStableKey(
      sourceFile: file,
      request: DocumentPublishRequest(destination: .localLink, format: .html, line: 12)
    )
    let wholePDF = WorkspaceStore.localDocumentPublicationStableKey(
      sourceFile: file,
      request: DocumentPublishRequest(destination: .localLink, format: .pdf)
    )

    XCTAssertNotEqual(wholeHTML, subtreeHTML)
    XCTAssertNotEqual(wholeHTML, wholePDF)
  }

  func testLocalPublicationSurvivesHostRestartWithTheSameSecretURL() async throws {
    let storageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-publication-persistence-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storageDirectory) }

    let html = Data("<!doctype html><title>Persistent report</title><p>Still here</p>".utf8)
    let firstHost = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1",
      storageDirectory: storageDirectory
    )
    let original = try await firstHost.publish(
      data: html,
      title: "Persistent report",
      mediaType: "text/html",
      sourcePath: "/tmp/report.org2",
      format: .html
    )
    await firstHost.stopAndWait()

    let restoredHost = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "ignored.example",
      storageDirectory: storageDirectory
    )
    let restoredPublications = try await restoredHost.restorePublications()
    let restored = try XCTUnwrap(restoredPublications.first)
    defer { restoredHost.stop() }

    XCTAssertEqual(restored.id, original.id)
    XCTAssertEqual(restored.url, original.url)
    XCTAssertEqual(restored.localURL, original.localURL)
    XCTAssertEqual(restored.sourcePath, "/tmp/report.org2")
    XCTAssertEqual(restored.format, .html)

    let (servedData, response) = try await URLSession.shared.data(from: restored.localURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertEqual(servedData, html)

    try restoredHost.revoke(restored.id)
    restoredHost.stop()
    let emptyHost = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1",
      storageDirectory: storageDirectory
    )
    defer { emptyHost.stop() }
    let publicationsAfterRevocation = try await emptyHost.restorePublications()
    XCTAssertTrue(publicationsAfterRevocation.isEmpty)
  }

  @MainActor
  func testWorkspaceBootstrapRestoresPersistedLocalPublications() async throws {
    let storageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-bootstrap-publications-\(UUID().uuidString)", isDirectory: true)
    let suiteName = "openorg-bootstrap-publications-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: storageDirectory)
    }

    let firstHost = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1",
      storageDirectory: storageDirectory
    )
    let original = try await firstHost.publish(
      html: Data("<!doctype html><title>Restored by bootstrap</title>".utf8),
      title: "Restored by bootstrap"
    )
    await firstHost.stopAndWait()

    let restoredHost = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1",
      storageDirectory: storageDirectory
    )
    defer { restoredHost.stop() }
    let store = WorkspaceStore(
      cli: try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      automaticStarterCorpusURL: nil,
      localDocumentPublicationHost: restoredHost
    )

    await store.bootstrap()

    XCTAssertEqual(store.localDocumentPublications.map(\.url), [original.url])
  }

  func testLocalHostServesPDFWithAProtectedInlineContentType() async throws {
    let host = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1"
    )
    defer { host.stop() }

    let pdf = Data("%PDF-1.7\nsealed\n%%EOF".utf8)
    let publication = try await host.publish(
      data: pdf,
      title: "Safe PDF",
      mediaType: "application/pdf"
    )
    let (servedData, servedResponse) = try await URLSession.shared.data(from: publication.localURL)
    let servedHTTP = try XCTUnwrap(servedResponse as? HTTPURLResponse)

    XCTAssertEqual(servedHTTP.statusCode, 200)
    XCTAssertEqual(servedData, pdf)
    XCTAssertEqual(publication.mediaType, "application/pdf")
    XCTAssertEqual(servedHTTP.mimeType, "application/pdf")
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "Content-Disposition"), "inline")
    XCTAssertEqual(servedHTTP.value(forHTTPHeaderField: "X-Robots-Tag"), "noindex, nofollow, noarchive")
  }

  func testGoogleAuthorizationURLUsesLoopbackPKCEAndDriveFileScope() throws {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    let challenge = GoogleDriveOAuthClient.codeChallenge(for: verifier)
    XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

    let redirectURL = try XCTUnwrap(URL(string: "http://127.0.0.1:49152"))
    let url = try GoogleDriveOAuthClient.authorizationURL(
      clientID: "desktop-client.apps.googleusercontent.com",
      redirectURL: redirectURL,
      codeChallenge: challenge,
      state: "state-token"
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let values = Dictionary(
      uniqueKeysWithValues: try XCTUnwrap(components.queryItems).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(url.host, "accounts.google.com")
    XCTAssertEqual(values["client_id"], "desktop-client.apps.googleusercontent.com")
    XCTAssertEqual(values["redirect_uri"], redirectURL.absoluteString)
    XCTAssertEqual(values["response_type"], "code")
    XCTAssertEqual(values["scope"], GoogleDriveOAuthClient.driveFileScope)
    XCTAssertEqual(values["code_challenge"], challenge)
    XCTAssertEqual(values["code_challenge_method"], "S256")
    XCTAssertEqual(values["state"], "state-token")
  }

  func testGoogleDesktopClientJSONImportsTheCredentialPair() throws {
    let data = Data(
      #"{"installed":{"client_id":" desktop-client.apps.googleusercontent.com ","client_secret":" desktop-secret ","redirect_uris":["http://localhost"]}}"#.utf8
    )

    let client = try GoogleDriveOAuthDesktopClient.decodeGoogleClientJSON(data)

    XCTAssertEqual(client.clientID, "desktop-client.apps.googleusercontent.com")
    XCTAssertEqual(client.clientSecret, "desktop-secret")
  }

  func testManagedGoogleOAuthClientTakesPrecedenceOverSavedCustomClient() {
    let clientID = GoogleDriveOAuthConfiguration.resolvedClientID(
      managedCandidates: [nil, " bundled-client.apps.googleusercontent.com "],
      savedClientID: "custom-client.apps.googleusercontent.com"
    )

    XCTAssertEqual(clientID, "bundled-client.apps.googleusercontent.com")
  }

  func testSavedGoogleOAuthClientRemainsFallbackForUnconfiguredBuilds() {
    let clientID = GoogleDriveOAuthConfiguration.resolvedClientID(
      managedCandidates: [nil, "  "],
      savedClientID: " custom-client.apps.googleusercontent.com "
    )

    XCTAssertEqual(clientID, "custom-client.apps.googleusercontent.com")
  }

  func testGoogleDesktopClientJSONRejectsWebApplicationCredentials() throws {
    let data = Data(
      #"{"web":{"client_id":"web-client.apps.googleusercontent.com","client_secret":"web-secret"}}"#.utf8
    )

    XCTAssertThrowsError(try GoogleDriveOAuthDesktopClient.decodeGoogleClientJSON(data)) { error in
      XCTAssertEqual(error as? GoogleDriveOAuthDesktopClientError, .webClientNotSupported)
    }
  }

  func testGoogleCredentialDecodesLegacyKeychainPayloadWithoutClientSecret() throws {
    let data = Data(
      #"{"clientID":"desktop-client.apps.googleusercontent.com","accessToken":"access","refreshToken":"refresh","expirationDate":0,"scope":"https:\/\/www.googleapis.com\/auth\/drive.file","tokenType":"Bearer"}"#.utf8
    )

    let credential = try JSONDecoder().decode(GoogleDriveOAuthCredential.self, from: data)

    XCTAssertNil(credential.clientSecret)
    XCTAssertEqual(credential.clientID, "desktop-client.apps.googleusercontent.com")
  }

  func testBundledSecretHydratesOnlyAMatchingLegacyGoogleCredential() {
    XCTAssertEqual(
      GoogleDriveOAuthConfiguration.resolvedClientSecret(
        credentialClientID: "openorg-client.apps.googleusercontent.com",
        credentialClientSecret: nil,
        managedClientID: "openorg-client.apps.googleusercontent.com",
        managedClientSecret: "bundled-secret"
      ),
      "bundled-secret"
    )
    XCTAssertNil(
      GoogleDriveOAuthConfiguration.resolvedClientSecret(
        credentialClientID: "custom-client.apps.googleusercontent.com",
        credentialClientSecret: nil,
        managedClientID: "openorg-client.apps.googleusercontent.com",
        managedClientSecret: "bundled-secret"
      )
    )
  }

  func testGoogleCredentialRefreshKeepsRefreshTokenAndScope() async throws {
    let capture = RequestCapture()
    let responseData = Data(
      #"{"access_token":"new-access","expires_in":3600,"scope":"https://www.googleapis.com/auth/drive.file","token_type":"Bearer"}"#.utf8
    )
    let client = GoogleDriveOAuthClient { request in
      await capture.record(request)
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      return (responseData, response)
    }
    let original = GoogleDriveOAuthCredential(
      clientID: "desktop-client.apps.googleusercontent.com",
      clientSecret: "desktop-secret",
      accessToken: "old-access",
      refreshToken: "durable-refresh",
      expirationDate: Date(timeIntervalSince1970: 10),
      scope: GoogleDriveOAuthClient.driveFileScope
    )
    let now = Date(timeIntervalSince1970: 100)

    let refreshed = try await client.refreshingIfNeeded(original, now: now)

    XCTAssertEqual(refreshed.accessToken, "new-access")
    XCTAssertEqual(refreshed.clientSecret, "desktop-secret")
    XCTAssertEqual(refreshed.refreshToken, "durable-refresh")
    XCTAssertEqual(refreshed.expirationDate, now.addingTimeInterval(3600))
    XCTAssertTrue(refreshed.grantsDriveFileScope)
    let request = await capture.request
    XCTAssertEqual(request?.httpMethod, "POST")
    let body = String(data: try XCTUnwrap(request?.httpBody), encoding: .utf8)
    XCTAssertTrue(body?.contains("grant_type=refresh_token") == true)
    XCTAssertTrue(body?.contains("refresh_token=durable-refresh") == true)
    XCTAssertTrue(body?.contains("client_secret=desktop-secret") == true)
    XCTAssertFalse(body?.contains("old-access") == true)
  }

  func testGoogleMissingClientSecretResponseHasActionableError() async throws {
    let client = GoogleDriveOAuthClient { request in
      let response = HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: 400,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      return (Data(#"{"error":"invalid_request","error_description":"client_secret is missing."}"#.utf8), response)
    }
    let credential = GoogleDriveOAuthCredential(
      clientID: "desktop-client.apps.googleusercontent.com",
      accessToken: "expired-access",
      refreshToken: "durable-refresh",
      expirationDate: Date(timeIntervalSince1970: 10),
      scope: GoogleDriveOAuthClient.driveFileScope
    )

    do {
      _ = try await client.refreshingIfNeeded(credential, now: Date(timeIntervalSince1970: 100))
      XCTFail("Expected the missing client secret response to fail")
    } catch {
      guard case GoogleDriveOAuthError.missingClientSecret = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }
}
