import CryptoKit
import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatThreadPublishingTests: XCTestCase {
  func testChatThreadStableKeyRoundTripsTheThreadID() {
    let threadID = UUID()
    let key = LocalDocumentPublication.chatThreadStableKey(threadID)

    XCTAssertEqual(LocalDocumentPublication.chatThreadID(fromStableKey: key), threadID)
    XCTAssertNil(LocalDocumentPublication.chatThreadID(fromStableKey: "/tmp/report.org\nscope:document"))
    XCTAssertNil(LocalDocumentPublication.chatThreadID(fromStableKey: nil))
  }

  func testLivePublicationServesItsRevisionAndOnlyThePinnedScript() async throws {
    let storageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-chat-publication-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: storageDirectory) }
    let host = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1",
      storageDirectory: storageDirectory
    )
    let threadID = UUID()
    let stableKey = LocalDocumentPublication.chatThreadStableKey(threadID)

    let first = try await host.publish(
      data: Data("<p>First</p>".utf8),
      title: "Launch plan",
      mediaType: "text/html",
      stableKey: stableKey,
      revision: "rev-1"
    )
    XCTAssertEqual(first.chatThreadID, threadID)

    let (page, pageResponse) = try await URLSession.shared.data(from: first.localURL)
    let pageHTTP = try XCTUnwrap(pageResponse as? HTTPURLResponse)
    XCTAssertEqual(String(decoding: page, as: UTF8.self), "<p>First</p>")
    let policy = try XCTUnwrap(pageHTTP.value(forHTTPHeaderField: "Content-Security-Policy"))
    XCTAssertTrue(policy.contains("script-src '\(LocalDocumentPublicationHost.liveUpdateScriptHash)'"))
    XCTAssertTrue(policy.contains("connect-src 'self'"))
    XCTAssertFalse(policy.contains("script-src 'unsafe-inline'"))

    let revisionURL = first.localURL.appendingPathComponent("revision")
    let (revision, _) = try await URLSession.shared.data(from: revisionURL)
    XCTAssertEqual(String(decoding: revision, as: UTF8.self), "rev-1")

    let updated = try await host.publish(
      data: Data("<p>Second</p>".utf8),
      title: "Launch plan",
      mediaType: "text/html",
      stableKey: stableKey,
      revision: "rev-2"
    )
    XCTAssertEqual(updated.url, first.url)
    let (nextRevision, _) = try await URLSession.shared.data(from: revisionURL)
    XCTAssertEqual(String(decoding: nextRevision, as: UTF8.self), "rev-2")

    // Restarting keeps the live revision, so readers keep polling one URL.
    await host.stopAndWait()
    let restoredHost = LocalDocumentPublicationHost(
      bindHost: "127.0.0.1",
      advertisedHost: "127.0.0.1",
      storageDirectory: storageDirectory
    )
    defer { restoredHost.stop() }
    let restoredPublications = try await restoredHost.restorePublications()
    let restored = try XCTUnwrap(restoredPublications.first)
    XCTAssertEqual(restored.chatThreadID, threadID)
    XCTAssertEqual(restored.url, first.url)
    let (restoredRevision, _) = try await URLSession.shared.data(from: revisionURL)
    XCTAssertEqual(String(decoding: restoredRevision, as: UTF8.self), "rev-2")

    try restoredHost.revoke(restored.id)
    let (_, revokedResponse) = try await URLSession.shared.data(from: revisionURL)
    XCTAssertEqual((revokedResponse as? HTTPURLResponse)?.statusCode, 404)
  }

  func testStaticPublicationsStayScriptFreeWithoutARevisionEndpoint() async throws {
    let host = LocalDocumentPublicationHost(bindHost: "127.0.0.1", advertisedHost: "127.0.0.1")
    defer { host.stop() }
    let publication = try await host.publish(html: Data("<p>Report</p>".utf8), title: "Report")

    let (_, response) = try await URLSession.shared.data(from: publication.localURL)
    let policy = try XCTUnwrap(
      (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Security-Policy")
    )
    XCTAssertFalse(policy.contains("script-src"))
    XCTAssertFalse(policy.contains("connect-src"))
    XCTAssertNil(publication.chatThreadID)

    let (_, revisionResponse) = try await URLSession.shared.data(
      from: publication.localURL.appendingPathComponent("revision")
    )
    XCTAssertEqual((revisionResponse as? HTTPURLResponse)?.statusCode, 404)
  }

  func testPublishableMessagesKeepOnlyDeliveredConversationText() {
    let context = AIChatContextPresentation.automaticContext(
      kind: "note",
      title: "Private roadmap",
      reference: "notes/roadmap.org",
      prompt: "SECRET CONTEXT BODY",
      userText: "What should we ship next?"
    )
    let queued = AIChatMessage(role: .user, content: "Queued draft")
    let messages = [
      AIChatMessage(role: .user, content: context),
      AIChatMessage(role: .user, content: "Failed send", sendFailure: "offline", deliveryStatus: .failed),
      AIChatMessage(role: .user, content: "Still sending", deliveryStatus: .sending),
      queued,
      AIChatMessage(role: .user, content: "Room copy", isRoomDispatchCopy: true),
      AIChatMessage(role: .assistant, content: "Ship *sharing*.", authorLabel: "OpenCode"),
    ]

    let published = AIChatThreadPublicationSnapshot.publishableMessages(
      messages,
      userName: "Avi Press",
      queuedMessageIDs: [queued.id],
      defaultAssistantTitle: "Assistant"
    )

    XCTAssertEqual(published.map(\.role), [.user, .assistant])
    XCTAssertEqual(published[0].author, "Avi Press")
    XCTAssertEqual(published[0].text.trimmingCharacters(in: .whitespacesAndNewlines), "What should we ship next?")
    XCTAssertFalse(published[0].text.contains("SECRET CONTEXT BODY"))
    XCTAssertFalse(published[0].formatted)
    XCTAssertEqual(published[1].author, "OpenCode")
    XCTAssertTrue(published[1].formatted)
  }

  func testRenderedBodyDropsWorkspaceOnlyLinksScriptsAndResources() {
    let appHTML = """
    <!doctype html><html><head><style id="org2-app-document-style">.x{color:red}</style>
    <script id="org2-app-document-script">alert(1)</script></head><body>
    <main class="org2-document"><header class="org2-document-header"><h1>Title</h1></header>
    <p>See <a href="org2-workspace://open-link?target=file%3Aroadmap.org">the roadmap</a>,
    <a href="https://example.com/doc">the web</a>, and <img src="file:///Users/avi/private.png" onerror="x()">.</p>
    <script>steal()</script></main></body></html>
    """

    let body = AIChatThreadPublicationPage.renderedBody(fromAppHTML: appHTML)

    XCTAssertEqual(body.stylesheet, ".x{color:red}")
    XCTAssertFalse(body.html.contains("org2-workspace://"))
    XCTAssertFalse(body.html.contains("file:///"))
    XCTAssertFalse(body.html.contains("<script"))
    XCTAssertFalse(body.html.contains("onerror"))
    XCTAssertFalse(body.html.contains("org2-document-header"))
    XCTAssertTrue(body.html.contains("the roadmap"))
    XCTAssertTrue(body.html.contains(#"<a target="_blank" rel="noopener noreferrer" href="https://example.com/doc">"#))
  }

  func testPageEscapesTextEmbedsTheHashedScriptAndChangesRevisionWithContent() throws {
    let message = AIChatThreadPublicationSnapshot.Message(
      id: UUID(),
      role: .user,
      author: "Avi <admin>",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      text: "<script>alert('x')</script> & more",
      formatted: false,
      attachments: [.init(fileName: "notes.pdf", mimeType: "application/pdf", imageDataURL: nil)]
    )
    let snapshot = makeSnapshot(title: "Plan <b>", messages: [message], appearance: .system)

    let html = AIChatThreadPublicationPage.html(snapshot: snapshot, bodies: [:], rendererStylesheet: nil)

    XCTAssertTrue(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; more"))
    XCTAssertTrue(html.contains("Avi &lt;admin&gt;"))
    XCTAssertTrue(html.contains("<title>Plan &lt;b&gt; · Celorga</title>"))
    XCTAssertTrue(html.contains("notes.pdf"))
    XCTAssertTrue(html.contains("id=\"openorg-live-root\""))
    let revision = AIChatThreadPublicationPage.revision(snapshot: snapshot, bodies: [:])
    XCTAssertTrue(html.contains("<meta name=\"openorg-revision\" content=\"\(revision)\">"))

    // Every script on the page must hash to a value the host allows.
    let scripts = html.components(separatedBy: "<script>").dropFirst()
    XCTAssertEqual(scripts.count, 2)
    let hashes = try scripts.map { part in
      let script = try XCTUnwrap(part.components(separatedBy: "</script>").first)
      return "sha256-" + Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
    }
    XCTAssertEqual(hashes, [LocalDocumentPublicationHost.liveUpdateScriptHash, AIChatGuestMessageHTTP.scriptHash])
    let policy = LocalDocumentPublicationHost.contentSecurityPolicy(isHTML: true, isLive: true)
    for hash in hashes {
      XCTAssertTrue(policy.contains("'\(hash)'"))
    }

    let longer = makeSnapshot(
      title: "Plan <b>",
      messages: [message, .init(
        id: UUID(), role: .assistant, author: "OpenCode", createdAt: Date(),
        text: "Done.", formatted: false, attachments: []
      )],
      appearance: .system
    )
    XCTAssertNotEqual(AIChatThreadPublicationPage.revision(snapshot: longer, bodies: [:]), revision)
  }

  func testPageDeclaresLinkPreviewMetadataFromItsVisibleText() {
    let question = AIChatThreadPublicationSnapshot.Message(
      id: UUID(), role: .user, author: "Avi", createdAt: Date(),
      text: "How do we \"unfurl\" <links>\nin Slack?", formatted: false, attachments: []
    )
    let reply = AIChatThreadPublicationSnapshot.Message(
      id: UUID(), role: .assistant, author: "OpenCode", createdAt: Date(),
      text: "Add Open Graph tags.", formatted: false, attachments: []
    )
    let html = AIChatThreadPublicationPage.html(
      snapshot: makeSnapshot(title: "Share & preview", messages: [question, reply], appearance: .system),
      bodies: [:],
      rendererStylesheet: nil
    )
    XCTAssertTrue(html.contains(#"<meta property="og:title" content="Share &amp; preview">"#))
    XCTAssertTrue(html.contains(#"<meta property="og:site_name" content="Celorga">"#))
    XCTAssertTrue(html.contains(#"<meta name="twitter:card" content="summary">"#))
    XCTAssertTrue(html.contains(
      #"<meta property="og:description" content="How do we &quot;unfurl&quot; &lt;links&gt; in Slack? — AI chat · 2 messages">"#
    ))
    let headEnd = html.range(of: "</head>")!.lowerBound
    XCTAssertTrue(html.range(of: "og:title")!.lowerBound < headEnd, "Crawlers read preview tags from the head")

    let empty = AIChatThreadPublicationPage.html(
      snapshot: makeSnapshot(title: "  ", messages: [], appearance: .system),
      bodies: [:],
      rendererStylesheet: nil
    )
    XCTAssertTrue(empty.contains(#"<meta property="og:title" content="AI Chat">"#))
    XCTAssertTrue(empty.contains(#"<meta property="og:description" content="Shared AI chat from Celorga">"#))
  }

  func testThemeFollowsTheSelectedAppearanceMode() {
    let dark = AIChatThreadPublicationPage.themeStylesheet(
      for: makeSnapshot(title: "T", messages: [], appearance: .dark)
    )
    XCTAssertTrue(dark.hasPrefix(":root { color-scheme: dark; }"))
    XCTAssertTrue(dark.contains("--org2-text:"))
    XCTAssertFalse(dark.contains("prefers-color-scheme"))

    let system = AIChatThreadPublicationPage.themeStylesheet(
      for: makeSnapshot(title: "T", messages: [], appearance: .system)
    )
    XCTAssertTrue(system.hasPrefix(":root { color-scheme: light dark; }"))
    XCTAssertTrue(system.contains("@media (prefers-color-scheme: dark)"))
  }

  private func makeSnapshot(
    title: String,
    messages: [AIChatThreadPublicationSnapshot.Message],
    appearance: WorkspaceAppearanceMode
  ) -> AIChatThreadPublicationSnapshot {
    AIChatThreadPublicationSnapshot(
      threadID: UUID(),
      title: title,
      messages: messages,
      respondingStatus: nil,
      appearanceMode: appearance,
      lightTheme: WorkspaceThemeCatalog.theme(id: nil, for: .light),
      darkTheme: WorkspaceThemeCatalog.theme(id: nil, for: .dark)
    )
  }
}
