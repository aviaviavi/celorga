import AppKit
import CryptoKit
import Foundation

// MARK: - Page model

/// A read-only snapshot of one AI chat thread, prepared for a live local link.
///
/// Only delivered conversation text is included. Attached corpus context,
/// reasoning, tool activity, queued drafts, and failed sends stay private,
/// and known secret patterns are redacted from what remains.
struct AIChatThreadPublicationSnapshot: Sendable {
  struct Attachment: Sendable, Equatable {
    let fileName: String
    let mimeType: String
    /// A `data:` URL for images small enough to embed; otherwise a file chip.
    let imageDataURL: String?
  }

  struct Message: Sendable, Equatable {
    let id: UUID
    let role: AIChatMessage.Role
    let author: String
    let createdAt: Date
    /// User and system text as written, or normalized Org for assistants.
    let text: String
    let formatted: Bool
    let attachments: [Attachment]
  }

  let threadID: UUID
  let title: String
  let messages: [Message]
  /// A short status such as "OpenCode is working on a reply…".
  let respondingStatus: String?
  let appearanceMode: WorkspaceAppearanceMode
  let lightTheme: WorkspaceTheme
  let darkTheme: WorkspaceTheme
  /// Present while the link accepts guest messages; guest requests echo it.
  var guestNonce: String? = nil

  static let embeddedImageByteLimit = 4 * 1_024 * 1_024

  static func publishableMessages(
    _ messages: [AIChatMessage],
    userName: String,
    queuedMessageIDs: Set<UUID> = [],
    assistantTitles: [UUID: String] = [:],
    defaultAssistantTitle: String = "Assistant"
  ) -> [Message] {
    messages.compactMap { message in
      switch message.role {
      case .user:
        guard !message.isRoomDispatchCopy,
              message.deliveryStatus == .sent || message.deliveryStatus == .interrupted,
              !queuedMessageIDs.contains(message.id)
        else { return nil }
        let text = AIChatSecretRedactor.redacted(AIChatContextPresentation(message.content).userText)
        let attachments = message.attachments.map(Self.attachment)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        else { return nil }
        return Message(
          id: message.id,
          role: .user,
          author: userName,
          createdAt: message.createdAt,
          text: text,
          formatted: false,
          attachments: attachments
        )
      case .assistant, .system:
        guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !message.attachments.isEmpty
        else { return nil }
        let formatted = message.role == .assistant
        return Message(
          id: message.id,
          role: message.role,
          author: message.role == .system
            ? WorkspaceProductIdentity.displayName
            : assistantTitles[message.id] ?? message.authorLabel ?? defaultAssistantTitle,
          createdAt: message.createdAt,
          // Redact before normalizing so a rewrite cannot split a token, and
          // after so normalization cannot reassemble one.
          text: AIChatSecretRedactor.redacted(
            formatted
              ? AIChatMessageOrgNormalizer.normalized(AIChatSecretRedactor.redacted(message.content))
              : message.content
          ),
          formatted: formatted,
          attachments: message.attachments.map(Self.attachment)
        )
      }
    }
  }

  private static func attachment(_ attachment: AIChatAttachment) -> Attachment {
    let isImage = attachment.mimeType.lowercased().hasPrefix("image/")
      && attachment.mimeType.lowercased() != "image/svg+xml"
    let dataURL = isImage && attachment.byteCount <= embeddedImageByteLimit
      ? try? attachment.loadedDataURLString()
      : nil
    return Attachment(
      fileName: AIChatSecretRedactor.redacted(attachment.fileName),
      mimeType: attachment.mimeType,
      imageDataURL: dataURL
    )
  }
}

// MARK: - HTML

enum AIChatThreadPublicationPage {
  /// Compiler output for one assistant message, reduced to its body.
  struct RenderedBody: Sendable, Equatable {
    let html: String
    let stylesheet: String?
  }

  /// Extracts the `<main>` body and document stylesheet from app HTML, then
  /// removes anything that only works inside OpenOrg: scripts, the document
  /// header, workspace links, and non-inline resources.
  static func renderedBody(fromAppHTML html: String) -> RenderedBody {
    let stylesheet = firstMatch(
      in: html,
      pattern: #"<style id="org2-app-document-style">([\s\S]*?)</style>"#
    )
    var body = firstMatch(in: html, pattern: #"<main[^>]*>([\s\S]*)</main>"#) ?? ""
    body = replacing(body, pattern: #"<script[\s\S]*?</script>"#, with: "")
    body = replacing(body, pattern: #"<header class="org2-document-header">[\s\S]*?</header>"#, with: "")
    body = sanitizedLinksAndResources(body)
    return RenderedBody(html: body, stylesheet: stylesheet)
  }

  static func sanitizedLinksAndResources(_ html: String) -> String {
    var result = replacing(
      html,
      pattern: #"\shref\s*=\s*"(?!https?:|mailto:)[^"]*""#,
      with: ""
    )
    result = replacing(result, pattern: #"\shref\s*=\s*'(?!https?:|mailto:)[^']*'"#, with: "")
    result = replacing(result, pattern: #"\s(src|srcset|poster)\s*=\s*"(?!data:)[^"]*""#, with: "")
    result = replacing(result, pattern: #"\s(src|srcset|poster)\s*=\s*'(?!data:)[^']*'"#, with: "")
    result = replacing(result, pattern: #"\son[a-z]+\s*=\s*("[^"]*"|'[^']*')"#, with: "")
    // Readers are on other machines; open web links outside the shared page.
    result = replacing(
      result,
      pattern: #"<a(\s[^>]*href\s*=\s*"https?:[^"]*")"#,
      with: #"<a target="_blank" rel="noopener noreferrer"$1"#
    )
    return result
  }

  static func revision(
    snapshot: AIChatThreadPublicationSnapshot,
    bodies: [UUID: RenderedBody]
  ) -> String {
    var hasher = SHA256()
    func add(_ value: String) {
      hasher.update(data: Data(value.utf8))
      hasher.update(data: Data([0]))
    }
    add(snapshot.title)
    add(snapshot.respondingStatus ?? "")
    add(snapshot.guestNonce ?? "")
    add(themeStylesheet(for: snapshot))
    for message in snapshot.messages {
      add(message.id.uuidString)
      add(message.author)
      add(message.text)
      add(bodies[message.id]?.html ?? "")
      for attachment in message.attachments {
        add(attachment.fileName)
        add(attachment.imageDataURL.map { String($0.utf8.count) } ?? "")
      }
    }
    return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  static func html(
    snapshot: AIChatThreadPublicationSnapshot,
    bodies: [UUID: RenderedBody],
    rendererStylesheet: String?,
    now: Date = Date()
  ) -> String {
    let revision = revision(snapshot: snapshot, bodies: bodies)
    let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "AI Chat"
      : snapshot.title
    let messages = snapshot.messages.map { article($0, body: bodies[$0.id]) }.joined(separator: "\n")
    let count = snapshot.messages.count
    let lastDate = snapshot.messages.last?.createdAt
    let updated = lastDate.map {
      " · Last message <time datetime=\"\(isoDate($0))\">\(escape(displayDate($0)))</time>"
    } ?? ""
    let responding = snapshot.respondingStatus.map {
      "<p class=\"responding\" role=\"status\"><span class=\"pulse\" aria-hidden=\"true\"></span>\(escape($0))</p>"
    } ?? ""
    let empty = snapshot.messages.isEmpty
      ? "<p class=\"empty\">No messages yet. New messages appear here automatically.</p>"
      : ""
    let guestAttribute = snapshot.guestNonce.map { " data-guest-nonce=\"\(escape($0))\"" } ?? ""
    return """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <meta name="robots" content="noindex, nofollow">
    <meta name="openorg-revision" content="\(revision)">
    <title>\(escape(title)) · \(WorkspaceProductIdentity.displayName)</title>
    \(SharePreviewMetadata.tags(title: title, description: previewDescription(snapshot)))
    <style id="org2-app-document-style">\(rendererStylesheet ?? "")</style>
    <style id="openorg-chat-page-style">\(pageStylesheet)\(AIChatGuestMessageHTTP.stylesheet)</style>
    <style id="openorg-chat-theme">\(themeStylesheet(for: snapshot))</style>
    </head>
    <body>
    <div class="live-bar"><span id="openorg-live-status" data-state="live">Live</span></div>
    <div id="openorg-live-root"\(guestAttribute)>
    <header class="thread-header">
    <h1>\(escape(title))</h1>
    <p class="thread-meta">\(count) message\(count == 1 ? "" : "s")\(updated)</p>
    </header>
    <section class="messages" aria-label="Messages">
    \(messages)
    </section>
    \(empty)\(responding)
    </div>
    \(AIChatGuestMessageHTTP.composerHTML)
    <footer class="page-footer">Shared read-only from \(WorkspaceProductIdentity.displayName). New messages appear automatically while \(WorkspaceProductIdentity.displayName) keeps sharing the thread.</footer>
    \(LocalDocumentPublicationHost.liveUpdateScriptElement)
    \(AIChatGuestMessageHTTP.scriptElement)
    </body>
    </html>

    """
  }

  /// Link-preview summary: the conversation's opening message, which names
  /// its topic, plus its size. Only text already on the page is used.
  static func previewDescription(_ snapshot: AIChatThreadPublicationSnapshot) -> String {
    let count = snapshot.messages.count
    let size = count == 0
      ? "Shared AI chat from \(WorkspaceProductIdentity.displayName)"
      : "AI chat · \(count) message\(count == 1 ? "" : "s")"
    let opening = (snapshot.messages.first { $0.role == .user } ?? snapshot.messages.first)
      .map { SharePreviewMetadata.collapsedWhitespace($0.text) } ?? ""
    guard !opening.isEmpty else { return size }
    let limit = SharePreviewMetadata.descriptionLimit - size.count - 3
    return SharePreviewMetadata.truncated(opening, limit: max(40, limit)) + " — " + size
  }

  private static func article(
    _ message: AIChatThreadPublicationSnapshot.Message,
    body: RenderedBody?
  ) -> String {
    let content: String
    if message.formatted, let body {
      content = "<main class=\"org2-document\">\(body.html)</main>"
    } else if message.text.isEmpty {
      content = ""
    } else {
      content = "<main class=\"org2-document plain-message\">\(escape(message.text))</main>"
    }
    let attachments = message.attachments.isEmpty ? "" : """
      <div class="attachments">\(message.attachments.map(attachment).joined())</div>
      """
    let badge = message.role == .system ? "<span class=\"system-badge\">System</span>" : ""
    return """
    <article class="\(message.role.rawValue)" id="message-\(message.id.uuidString.lowercased())">
    <div class="message-card">
    <header class="message-header"><strong>\(escape(message.author))</strong>\(badge)<time datetime="\(isoDate(message.createdAt))">\(escape(displayDate(message.createdAt)))</time></header>
    \(content)\(attachments)
    </div>
    </article>
    """
  }

  private static func attachment(_ attachment: AIChatThreadPublicationSnapshot.Attachment) -> String {
    if let dataURL = attachment.imageDataURL {
      return "<figure class=\"attachment image\"><img src=\"\(escape(dataURL))\" alt=\"\(escape(attachment.fileName))\"><figcaption>\(escape(attachment.fileName))</figcaption></figure>"
    }
    return "<span class=\"attachment file\">\(escape(attachment.fileName))</span>"
  }

  // MARK: Theme

  /// Mirrors the reader-visible part of the user's OpenOrg appearance:
  /// System follows the reader's light/dark preference with the selected
  /// pair, while Light or Dark pins the page to that one theme.
  static func themeStylesheet(for snapshot: AIChatThreadPublicationSnapshot) -> String {
    switch snapshot.appearanceMode {
    case .light:
      return ":root { color-scheme: light; }\n" + fullRules(for: snapshot.lightTheme)
    case .dark:
      return ":root { color-scheme: dark; }\n" + fullRules(for: snapshot.darkTheme)
    case .system:
      return ":root { color-scheme: light dark; }\n"
        + pairRules(for: snapshot.lightTheme)
        + "@media (prefers-color-scheme: dark) {\n" + pairRules(for: snapshot.darkTheme) + "}\n"
    }
  }

  /// A pinned appearance must override the export's own dark-mode palette.
  private static func fullRules(for theme: WorkspaceTheme) -> String {
    WorkspaceThemeDocumentStyle.rules(for: theme, selectorPrefix: ":root")
      + WorkspaceThemeDocumentStyle.chatRules(for: theme, selectorPrefix: ":root")
      + pageRules(for: theme)
  }

  /// Default OpenOrg themes keep the export's palette; custom themes restyle it.
  private static func pairRules(for theme: WorkspaceTheme) -> String {
    let documentRules = theme.palette.overridesBodyText
      ? WorkspaceThemeDocumentStyle.rules(for: theme, selectorPrefix: ":root")
        + WorkspaceThemeDocumentStyle.chatRules(for: theme, selectorPrefix: ":root")
      : ""
    return documentRules + pageRules(for: theme)
  }

  private static func pageRules(for theme: WorkspaceTheme) -> String {
    func c(_ role: WorkspaceThemeRole) -> String {
      WorkspaceThemeDocumentStyle.cssColor(theme.resolvedColor(role))
    }
    return """
    :root, :root body { background: \(c(.pane)); }
    :root .message-card { background: \(c(.document)); border-color: \(c(.hairline)); }
    :root .thread-header h1 { color: \(c(.text)); }
    :root .thread-meta, :root .page-footer, :root .responding, :root .empty,
    :root .attachment figcaption, :root .attachment.file { color: \(c(.secondaryText)); }
    :root .thread-header, :root .page-footer { border-color: \(c(.hairline)); }
    :root .attachment.file, :root .attachment img { border-color: \(c(.hairline)); }

    """
  }

  static let pageStylesheet = """
  html, body { margin:0; padding:0; }
  body { font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: light-dark(#202020,#e7e7e7); overflow-wrap:anywhere; -webkit-text-size-adjust:100%; }
  #openorg-live-root, .page-footer { box-sizing:border-box; max-width:860px; margin:0 auto; padding:0 20px; }
  .thread-header { padding:36px 0 16px; margin-bottom:20px; border-bottom:1px solid light-dark(#dddcd7,#444642); }
  .thread-header h1 { margin:0 0 6px; font-size:24px; line-height:1.25; font-weight:650; }
  .thread-meta { margin:0; font-size:12px; color: light-dark(#777,#aaa); }
  .live-bar { position:sticky; top:0; z-index:2; height:0; display:flex; justify-content:flex-end; max-width:860px; margin:0 auto; padding:0 20px; box-sizing:border-box; }
  #openorg-live-status { margin-top:12px; height:20px; padding:0 9px; display:inline-flex; align-items:center; gap:6px; border-radius:999px; font-size:11px; font-weight:600; color:#1f8a44; background:light-dark(#e6f5eb,#1d3325); }
  #openorg-live-status::before { content:''; width:6px; height:6px; border-radius:50%; background:currentColor; }
  #openorg-live-status[data-state="offline"] { color:light-dark(#9a6200,#e8b25c); background:light-dark(#fbf0dc,#3b2f1b); }
  #openorg-live-status[data-state="stopped"] { color:light-dark(#777,#aaa); background:light-dark(#eee,#333); }
  .messages { display:flex; flex-direction:column; gap:14px; }
  article { display:flex; min-width:0; }
  article.user { justify-content:flex-end; }
  .message-card { box-sizing:border-box; width:fit-content; max-width:min(100%, 720px); min-width:0; padding:10px 14px 13px; border:1px solid light-dark(#d8d8d3,#424442); border-radius:10px; background:light-dark(#fcfbf8,#242624); }
  article.assistant .message-card, article.system .message-card { width:100%; max-width:none; }
  article.user .message-card { background:light-dark(#eef2f9,#252d39); }
  .message-header { display:flex; align-items:center; gap:8px; font-size:12px; color:light-dark(#777,#aaa); margin-bottom:6px; }
  .message-header strong { color:light-dark(#555,#c4c4c4); font-weight:600; }
  .message-header time { opacity:.75; }
  .system-badge { padding:1px 5px; border-radius:4px; font-size:10px; font-weight:600; background:light-dark(#f9ead6,#503b26); color:light-dark(#a05b08,#f0aa5b); }
  .message-card main.org2-document { width:auto!important; max-width:none!important; margin:0!important; padding:0!important; background:transparent!important; box-shadow:none!important; border:0!important; }
  .message-card main.org2-document > :first-child { margin-top:0; }
  .message-card main.org2-document > :last-child { margin-bottom:0; }
  .plain-message { white-space:pre-wrap; }
  .message-card pre { max-height:none; overflow-x:auto; white-space:pre; }
  .message-card table { max-width:100%; }
  .message-card img { max-width:100%; height:auto; }
  li > p:first-child { margin-top:0; } li > p:last-child { margin-bottom:0; }
  .attachments { display:flex; flex-wrap:wrap; gap:10px; margin-top:10px; }
  .attachment.image { margin:0; max-width:100%; }
  .attachment.image img { display:block; max-width:100%; max-height:520px; border:1px solid light-dark(#d8d8d3,#424442); border-radius:6px; }
  .attachment figcaption { margin-top:4px; font-size:11px; color:light-dark(#777,#aaa); }
  .attachment.file { padding:4px 9px; border:1px solid light-dark(#d8d8d3,#424442); border-radius:6px; font-size:12px; color:light-dark(#666,#bbb); }
  .responding, .empty { display:flex; align-items:center; gap:8px; margin:18px 0 0; font-size:12px; color:light-dark(#777,#aaa); }
  .pulse { width:6px; height:6px; border-radius:50%; background:currentColor; animation:pulse .9s ease-in-out infinite alternate; }
  .page-footer { margin-top:36px; padding-top:14px; padding-bottom:36px; border-top:1px solid light-dark(#dddcd7,#444642); font-size:11px; color:light-dark(#888,#999); }
  @keyframes pulse { from { opacity:.45; transform:scale(.8); } to { opacity:1; transform:scale(1); } }
  @media (prefers-reduced-motion: reduce) { .pulse { animation:none; } }
  @media (max-width: 600px) { #openorg-live-root, .page-footer, .live-bar { padding-left:12px; padding-right:12px; } .thread-header { padding-top:40px; } }
  """

  // MARK: Helpers

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private static func isoDate(_ date: Date) -> String {
    date.formatted(.iso8601)
  }

  private static func displayDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func firstMatch(in text: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  private static func replacing(_ text: String, pattern: String, with template: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return text
    }
    return expression.stringByReplacingMatches(
      in: text,
      range: NSRange(text.startIndex..., in: text),
      withTemplate: template
    )
  }
}

// MARK: - Rendering

/// Renders publication pages off the main actor and remembers each assistant
/// message's compiled body, so a new message only compiles that message.
actor AIChatThreadPublicationRenderer {
  private struct CachedBody {
    let source: String
    let body: AIChatThreadPublicationPage.RenderedBody
  }

  private var bodies: [UUID: [UUID: CachedBody]] = [:]
  private var rendererStylesheet: String?
  private let render: @Sendable (String) async throws -> String

  init(render: @escaping @Sendable (String) async throws -> String) {
    self.render = render
  }

  func page(for snapshot: AIChatThreadPublicationSnapshot) async -> (html: String, revision: String) {
    var threadBodies = bodies[snapshot.threadID] ?? [:]
    var rendered: [UUID: AIChatThreadPublicationPage.RenderedBody] = [:]
    for message in snapshot.messages where message.formatted {
      if let cached = threadBodies[message.id], cached.source == message.text {
        rendered[message.id] = cached.body
        continue
      }
      // A compiler failure leaves that message as selectable plain text.
      guard let appHTML = try? await render(message.text) else { continue }
      let body = AIChatThreadPublicationPage.renderedBody(fromAppHTML: appHTML)
      if let stylesheet = body.stylesheet, !stylesheet.isEmpty {
        rendererStylesheet = stylesheet
      }
      threadBodies[message.id] = CachedBody(source: message.text, body: body)
      rendered[message.id] = body
    }
    let liveIDs = Set(snapshot.messages.map(\.id))
    bodies[snapshot.threadID] = threadBodies.filter { liveIDs.contains($0.key) }
    if rendererStylesheet == nil, let appHTML = try? await render("") {
      rendererStylesheet = AIChatThreadPublicationPage.renderedBody(fromAppHTML: appHTML).stylesheet
    }
    let html = AIChatThreadPublicationPage.html(
      snapshot: snapshot,
      bodies: rendered,
      rendererStylesheet: rendererStylesheet
    )
    return (html, AIChatThreadPublicationPage.revision(snapshot: snapshot, bodies: rendered))
  }

  func forget(_ threadID: UUID) {
    bodies[threadID] = nil
  }
}

/// What the monitor compares to decide whether a shared page is stale.
struct AIChatThreadPublicationSignature: Equatable, Sendable {
  let title: String
  let updatedAt: Date
  let messageCount: Int
  let storedMessageCount: Int?
  let lastMessageID: UUID?
  let lastMessageLength: Int
  let respondingStatus: String?
  let appearance: String
}

/// The OpenOrg appearance a shared thread page mirrors. A client sharing
/// through a server sends its own so the page matches the sharer's app.
public struct AIChatThreadShareAppearance: Codable, Hashable, Sendable {
  public let appearanceMode: String
  public let lightThemeID: String
  public let darkThemeID: String

  public init(appearanceMode: String, lightThemeID: String, darkThemeID: String) {
    self.appearanceMode = appearanceMode
    self.lightThemeID = lightThemeID
    self.darkThemeID = darkThemeID
  }

  init?(_ request: MobileRemoteThreadShareRequest) {
    guard let mode = request.appearanceMode.flatMap(WorkspaceAppearanceMode.init(rawValue:)) else {
      return nil
    }
    self.init(
      appearanceMode: mode.rawValue,
      lightThemeID: request.lightThemeID ?? WorkspaceThemeCatalog.defaultLightID,
      darkThemeID: request.darkThemeID ?? WorkspaceThemeCatalog.defaultDarkID
    )
  }

  var signature: String { "\(appearanceMode)|\(lightThemeID)|\(darkThemeID)" }
}

public enum AIChatThreadPublishingError: LocalizedError, Sendable {
  case missingThread

  public var errorDescription: String? {
    switch self {
    case .missingThread:
      "Celorga could not load that chat thread for sharing."
    }
  }
}

// MARK: - Store integration

extension WorkspaceStore {
  /// The live local link for a thread, if it is currently shared.
  public func chatThreadPublication(for threadID: UUID) -> LocalDocumentPublication? {
    localDocumentPublications.first { $0.chatThreadID == threadID }
  }

  public func isPublishingChatThread(_ threadID: UUID) -> Bool {
    publishingChatThreadIDs.contains(threadID) || openOrgServer.isBusy(threadID)
  }

  /// Whether this thread has a live link on this Mac or the paired server.
  public func isChatThreadShared(_ threadID: UUID) -> Bool {
    chatThreadPublication(for: threadID) != nil || openOrgServer.threadShare(for: threadID) != nil
  }

  /// The link to copy for a shared thread, preferring the server's link
  /// because it stays live while this Mac sleeps.
  public func chatThreadShareURL(for threadID: UUID) -> URL? {
    openOrgServer.threadShare(for: threadID)?.url ?? chatThreadPublication(for: threadID)?.url
  }

  /// The appearance this Mac's shared pages mirror.
  public var chatThreadShareAppearance: AIChatThreadShareAppearance {
    AIChatThreadShareAppearance(
      appearanceMode: appearanceMode.rawValue,
      lightThemeID: lightThemeID,
      darkThemeID: darkThemeID
    )
  }

  /// Creates or refreshes the thread's live link. The URL stays stable until
  /// the user stops sharing it.
  ///
  /// `appearance` is set when another client shares through this host; the
  /// page then mirrors that client's theme instead of this host's.
  @discardableResult
  public func publishChatThread(
    _ threadID: UUID,
    appearance: AIChatThreadShareAppearance? = nil
  ) async throws -> LocalDocumentPublication {
    let wasShared = chatThreadPublication(for: threadID) != nil
    let previousAppearance = chatThreadShareAppearanceOverrides[threadID]
    if let appearance {
      chatThreadShareAppearanceOverrides[threadID] = appearance
    }
    let publication: LocalDocumentPublication
    do {
      publication = try await republishChatThread(threadID, force: true)
    } catch {
      if !wasShared {
        chatThreadShareAppearanceOverrides[threadID] = previousAppearance
      }
      throw error
    }
    statusText = wasShared ? "Updated the shared thread link" : "Shared the thread on the local network"
    ensureChatThreadPublicationMonitor()
    return publication
  }

  /// Creates a live link at `location` and returns its URL.
  @discardableResult
  public func shareChatThread(
    _ threadID: UUID,
    from location: ChatThreadShareLocation
  ) async throws -> URL {
    switch location {
    case .thisMac:
      return try await publishChatThread(threadID).url
    case .server:
      let share = try await openOrgServer.share(
        threadID: threadID,
        appearance: chatThreadShareAppearance
      )
      statusText = "Shared the thread from \(share.serverName)"
      return share.url
    }
  }

  /// Shares the thread from the default location if needed, then copies its link.
  public func copyChatThreadShareLink(_ threadID: UUID) async {
    do {
      let url: URL
      if let serverShare = openOrgServer.threadShare(for: threadID) {
        url = serverShare.url
      } else if chatThreadPublication(for: threadID) != nil {
        url = try await republishChatThread(threadID, force: false).url
      } else {
        url = try await shareChatThread(threadID, from: openOrgServer.effectiveDefaultShareLocation)
      }
      AIChatMessageClipboard.write(url.absoluteString)
      statusText = "Copied the shared thread link"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not share the thread"
    }
  }

  /// Stops every live link for the thread, on this Mac and on the server.
  public func stopSharingChatThread(_ threadID: UUID) {
    stopSharingChatThreadLocally(threadID)
    if openOrgServer.threadShare(for: threadID) != nil {
      Task { await stopSharingChatThreadOnServer(threadID) }
    }
  }

  public func stopSharingChatThreadLocally(_ threadID: UUID) {
    chatThreadShareAppearanceOverrides[threadID] = nil
    guard let publication = chatThreadPublication(for: threadID) else { return }
    revokeLocalDocumentPublication(publication.id)
    chatThreadPublicationSignatures[threadID] = nil
    let renderer = chatThreadPublicationRenderer
    Task { await renderer.forget(threadID) }
    statusText = "Stopped sharing the thread"
  }

  public func stopSharingChatThreadOnServer(_ threadID: UUID) async {
    do {
      try await openOrgServer.stopSharing(threadID: threadID)
      statusText = "Stopped sharing the thread from \(openOrgServer.serverName)"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not stop sharing the thread from \(openOrgServer.serverName)"
    }
  }

  /// Re-advertises existing local links, for example after Tailscale connects
  /// and links should use its address instead of this Mac's network name.
  public func refreshLocalDocumentPublicationURLs() async {
    guard !localDocumentPublications.isEmpty,
          let refreshed = try? await localDocumentPublicationHost.restorePublications(),
          refreshed != localDocumentPublications
    else { return }
    localDocumentPublications = refreshed
  }

  /// Starts the lightweight loop that keeps shared thread pages current. It
  /// exits by itself once no thread links remain.
  func ensureChatThreadPublicationMonitor() {
    guard chatThreadPublicationMonitor == nil,
          localDocumentPublications.contains(where: { $0.chatThreadID != nil })
    else { return }
    chatThreadPublicationMonitor = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let threadIDs = self.localDocumentPublications.compactMap(\.chatThreadID)
        guard !threadIDs.isEmpty else { break }
        for threadID in threadIDs {
          guard !Task.isCancelled else { return }
          _ = try? await self.republishChatThread(threadID, force: false)
        }
        do {
          try await Task.sleep(for: .seconds(2))
        } catch {
          return
        }
      }
      self?.chatThreadPublicationMonitor = nil
    }
  }

  @discardableResult
  private func republishChatThread(
    _ threadID: UUID,
    force: Bool
  ) async throws -> LocalDocumentPublication {
    let existing = chatThreadPublication(for: threadID)
    guard let metadata = aiChatThreads.first(where: { $0.id == threadID }) else {
      if let existing, !force { return existing }
      throw AIChatThreadPublishingError.missingThread
    }
    let signature = chatThreadPublicationSignature(for: metadata)
    if !force, let existing, chatThreadPublicationSignatures[threadID] == signature {
      return existing
    }
    if publishingChatThreadIDs.contains(threadID) {
      if let existing { return existing }
      throw DocumentPublishingError.busy
    }
    publishingChatThreadIDs.insert(threadID)
    defer { publishingChatThreadIDs.remove(threadID) }

    guard let thread = await hydratedAIChatThreadForDetail(threadID) else {
      throw AIChatThreadPublishingError.missingThread
    }
    let snapshot = chatThreadPublicationSnapshot(for: thread)
    let page = await chatThreadPublicationRenderer.page(for: snapshot)
    // A person may stop sharing while the page renders; do not resurrect it.
    if existing != nil, chatThreadPublication(for: threadID) == nil {
      throw AIChatThreadPublishingError.missingThread
    }
    let publication = try await localDocumentPublicationHost.publish(
      data: Data(page.html.utf8),
      title: snapshot.title,
      mediaType: "text/html",
      stableKey: LocalDocumentPublication.chatThreadStableKey(threadID),
      revision: page.revision
    )
    chatThreadPublicationSignatures[threadID] = signature
    if let index = localDocumentPublications.firstIndex(where: { $0.id == publication.id }) {
      if localDocumentPublications[index] != publication {
        localDocumentPublications[index] = publication
      }
    } else {
      localDocumentPublications.insert(publication, at: 0)
    }
    return publication
  }

  private func chatThreadRespondingStatus(for threadID: UUID) -> String? {
    guard aiChatSendingThreadIDs.contains(threadID) || aiChatRemoteLiveTurn(for: threadID) != nil,
          let thread = aiChatThreads.first(where: { $0.id == threadID })
    else { return nil }
    return "\(aiChatDestinationTitle(thread.destinationID)) is working on a reply…"
  }

  private func chatThreadPublicationSignature(
    for thread: AIChatThread
  ) -> AIChatThreadPublicationSignature {
    AIChatThreadPublicationSignature(
      title: thread.title,
      updatedAt: thread.updatedAt,
      messageCount: thread.messages.count,
      storedMessageCount: thread.storedMessageCount,
      lastMessageID: thread.messages.last?.id,
      lastMessageLength: thread.messages.last?.content.utf8.count ?? 0,
      respondingStatus: chatThreadRespondingStatus(for: thread.id),
      appearance: chatThreadPageAppearance(for: thread.id).signature
    )
  }

  private func chatThreadPublicationSnapshot(
    for thread: AIChatThread
  ) -> AIChatThreadPublicationSnapshot {
    let appearance = chatThreadPageAppearance(for: thread.id)
    let userName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    var queuedMessageIDs = Set<UUID>()
    var assistantTitles: [UUID: String] = [:]
    for message in thread.messages {
      if message.role == .user, isAIChatMessageQueued(message.id) {
        queuedMessageIDs.insert(message.id)
      } else if message.role == .assistant {
        assistantTitles[message.id] = message.authorLabel
          ?? message.authorDestinationID.map(aiChatDestinationTitle)
          ?? message.authorRuntime?.title
      }
    }
    let messages = AIChatThreadPublicationSnapshot.publishableMessages(
      thread.messages,
      userName: userName.isEmpty ? "You" : userName,
      queuedMessageIDs: queuedMessageIDs,
      assistantTitles: assistantTitles,
      defaultAssistantTitle: aiChatDestinationTitle(thread.destinationID)
    )
    return AIChatThreadPublicationSnapshot(
      threadID: thread.id,
      title: AIChatSecretRedactor.redacted(thread.title),
      messages: messages,
      respondingStatus: chatThreadRespondingStatus(for: thread.id),
      appearanceMode: WorkspaceAppearanceMode(rawValue: appearance.appearanceMode) ?? appearanceMode,
      lightTheme: WorkspaceThemeCatalog.theme(id: appearance.lightThemeID, for: .light),
      darkTheme: WorkspaceThemeCatalog.theme(id: appearance.darkThemeID, for: .dark),
      guestNonce: aiChatGuestMessageQueue.nonce(forThread: thread.id)
    )
  }

  private func chatThreadPageAppearance(for threadID: UUID) -> AIChatThreadShareAppearance {
    chatThreadShareAppearanceOverrides[threadID] ?? chatThreadShareAppearance
  }
}
