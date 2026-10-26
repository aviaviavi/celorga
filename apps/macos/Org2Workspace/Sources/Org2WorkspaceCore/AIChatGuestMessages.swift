import CryptoKit
import Foundation
import SwiftUI

// MARK: - Model

/// A message a guest sent from a shared thread page. It waits for the owner;
/// nothing a guest submits reaches the agent until the owner approves it.
public struct AIChatGuestSubmission: Identifiable, Hashable, Sendable {
  public enum Status: String, Codable, Sendable {
    case pending
    case approved
    case declined
  }

  /// Unguessable; the guest page polls its status with it.
  public let id: String
  /// The live link the guest used.
  public let shareID: String
  public let threadID: UUID
  public let displayName: String
  public let text: String
  public let submittedAt: Date
  public internal(set) var status: Status
}

public enum AIChatGuestMessageError: LocalizedError, Equatable, Sendable {
  case notShared
  case notAccepting
  case invalidNonce
  case crossOrigin
  case unsupportedContentType
  case tooLarge
  case invalidPayload(String)
  case rateLimited
  case queueFull

  var statusCode: Int {
    switch self {
    case .notShared: 404
    case .notAccepting, .invalidNonce, .crossOrigin: 403
    case .unsupportedContentType: 415
    case .tooLarge: 413
    case .invalidPayload: 400
    case .rateLimited, .queueFull: 429
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notShared:
      "Share this thread from this Mac before letting guests send messages."
    case .notAccepting:
      "This link is not accepting guest messages."
    case .invalidNonce, .crossOrigin, .unsupportedContentType:
      "Send messages from the shared page."
    case .tooLarge:
      "That message is too long."
    case .invalidPayload(let reason):
      reason
    case .rateLimited:
      "Too many messages. Wait a minute, then try again."
    case .queueFull:
      "The owner has too many messages to review. Try again later."
    }
  }
}

// MARK: - Queue

/// Pending guest messages for live thread links on this Mac. The HTTP host
/// writes to it from its network queue and the store reads it on the main
/// actor, so all state sits behind one lock. Nothing is persisted: guest
/// messages stay off, and the queue empty, after Celorga restarts.
final class AIChatGuestMessageQueue: @unchecked Sendable {
  static let maximumNameLength = 40
  static let maximumTextLength = 1_000
  static let maximumBodyBytes = 4_096
  static let submissionsPerWindow = 5
  static let rateWindow: TimeInterval = 60
  static let maximumPendingPerShare = 20
  static let maximumStatusIDs = 20
  static let maximumRetainedResolved = 50

  private struct Share {
    let threadID: UUID
    let nonce: String
    var recentSubmissions: [Date] = []
  }

  private let lock = NSLock()
  private let now: @Sendable () -> Date
  private var shares: [String: Share] = [:]
  private var submissions: [String: AIChatGuestSubmission] = [:]
  private var order: [String] = []
  private var changeHandler: (@Sendable () -> Void)?

  init(now: @escaping @Sendable () -> Date = { Date() }) {
    self.now = now
  }

  /// Called after any change, outside the lock and on any thread.
  func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
    lock.withLock { changeHandler = handler }
  }

  /// Starts accepting messages for a live link and returns the page nonce
  /// guest requests must echo. Enabling an enabled link keeps its nonce.
  @discardableResult
  func enable(shareID: String, threadID: UUID) -> String {
    let nonce = lock.withLock { () -> String in
      if let existing = shares[shareID], existing.threadID == threadID { return existing.nonce }
      let nonce = Self.randomToken()
      shares[shareID] = Share(threadID: threadID, nonce: nonce)
      return nonce
    }
    notify()
    return nonce
  }

  /// Stops accepting messages for a link and discards everything it queued.
  func disable(shareID: String) {
    let changed = lock.withLock { () -> Bool in
      let removed = shares.removeValue(forKey: shareID) != nil
      let before = submissions.count
      submissions = submissions.filter { $0.value.shareID != shareID }
      order.removeAll { submissions[$0] == nil }
      return removed || before != submissions.count
    }
    if changed { notify() }
  }

  func disableAll() {
    let changed = lock.withLock { () -> Bool in
      let changed = !shares.isEmpty || !submissions.isEmpty
      shares = [:]
      submissions = [:]
      order = []
      return changed
    }
    if changed { notify() }
  }

  func isEnabled(shareID: String) -> Bool {
    lock.withLock { shares[shareID] != nil }
  }

  func nonce(forThread threadID: UUID) -> String? {
    lock.withLock { shares.values.first { $0.threadID == threadID }?.nonce }
  }

  var enabledThreadIDs: Set<UUID> {
    lock.withLock { Set(shares.values.map(\.threadID)) }
  }

  /// Pending messages, oldest first.
  var pendingSubmissions: [AIChatGuestSubmission] {
    lock.withLock {
      order.compactMap { submissions[$0] }.filter { $0.status == .pending }
    }
  }

  func submit(
    shareID: String,
    nonce: String?,
    name rawName: String,
    text rawText: String
  ) -> Result<AIChatGuestSubmission, AIChatGuestMessageError> {
    let name = Self.sanitizedName(rawName)
    let text = Self.sanitizedText(rawText)
    guard !name.isEmpty else { return .failure(.invalidPayload("Enter your name.")) }
    guard name.count <= Self.maximumNameLength else {
      return .failure(.invalidPayload("Use a name of \(Self.maximumNameLength) characters or fewer."))
    }
    guard !text.isEmpty else { return .failure(.invalidPayload("Enter a message.")) }
    guard text.count <= Self.maximumTextLength else { return .failure(.tooLarge) }

    let result = lock.withLock { () -> Result<AIChatGuestSubmission, AIChatGuestMessageError> in
      guard var share = shares[shareID] else { return .failure(.notAccepting) }
      guard let nonce, Self.constantTimeEqual(nonce, share.nonce) else { return .failure(.invalidNonce) }
      let date = now()
      share.recentSubmissions.removeAll { date.timeIntervalSince($0) >= Self.rateWindow }
      guard share.recentSubmissions.count < Self.submissionsPerWindow else {
        shares[shareID] = share
        return .failure(.rateLimited)
      }
      let pendingCount = submissions.values.count { $0.shareID == shareID && $0.status == .pending }
      guard pendingCount < Self.maximumPendingPerShare else { return .failure(.queueFull) }
      share.recentSubmissions.append(date)
      shares[shareID] = share
      let submission = AIChatGuestSubmission(
        id: Self.randomToken(),
        shareID: shareID,
        threadID: share.threadID,
        displayName: name,
        text: text,
        submittedAt: date,
        status: .pending
      )
      submissions[submission.id] = submission
      order.append(submission.id)
      return .success(submission)
    }
    if case .success = result { notify() }
    return result
  }

  /// Statuses of the listed submissions on one link. Unknown IDs are omitted.
  func statuses(
    shareID: String,
    nonce: String?,
    ids: [String]
  ) -> Result<[String: AIChatGuestSubmission.Status], AIChatGuestMessageError> {
    lock.withLock {
      guard let share = shares[shareID] else { return .failure(.notAccepting) }
      guard let nonce, Self.constantTimeEqual(nonce, share.nonce) else { return .failure(.invalidNonce) }
      var result: [String: AIChatGuestSubmission.Status] = [:]
      for id in ids.prefix(Self.maximumStatusIDs) {
        if let submission = submissions[id], submission.shareID == shareID {
          result[id] = submission.status
        }
      }
      return .success(result)
    }
  }

  /// Moves a pending message to approved or declined and returns it as it
  /// was submitted. Only the status is retained afterwards.
  @discardableResult
  func resolve(_ id: String, approved: Bool) -> AIChatGuestSubmission? {
    let resolved = lock.withLock { () -> AIChatGuestSubmission? in
      guard let submission = submissions[id], submission.status == .pending else { return nil }
      submissions[id] = AIChatGuestSubmission(
        id: submission.id,
        shareID: submission.shareID,
        threadID: submission.threadID,
        displayName: "",
        text: "",
        submittedAt: submission.submittedAt,
        status: approved ? .approved : .declined
      )
      pruneResolvedLocked()
      return submission
    }
    if resolved != nil { notify() }
    return resolved
  }

  func pendingSubmission(_ id: String) -> AIChatGuestSubmission? {
    lock.withLock { submissions[id].flatMap { $0.status == .pending ? $0 : nil } }
  }

  private func pruneResolvedLocked() {
    let resolved = order.filter { submissions[$0]?.status != .pending }
    guard resolved.count > Self.maximumRetainedResolved else { return }
    for id in resolved.prefix(resolved.count - Self.maximumRetainedResolved) {
      submissions[id] = nil
    }
    order.removeAll { submissions[$0] == nil }
  }

  private func notify() {
    let handler = lock.withLock { changeHandler }
    handler?()
  }

  // MARK: Text

  /// The text the agent receives, attributed so it knows a guest wrote it.
  static func attributedText(name: String, text: String) -> String {
    "Guest — \(sanitizedName(name)): \(text)"
  }

  static func sanitizedName(_ name: String) -> String {
    let scalars = name.unicodeScalars.map { scalar -> Character in
      CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
        ? " "
        : Character(scalar)
    }
    return String(scalars)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  static func sanitizedText(_ text: String) -> String {
    let normalized = text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let kept = normalized.unicodeScalars.filter { scalar in
      scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
    }
    return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func randomToken() -> String {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices {
      difference |= left[index] ^ right[index]
    }
    return difference == 0
  }
}

// MARK: - HTTP

/// Guest endpoints under a live thread link:
///
/// - `POST /a/<token>/guest` with `{"name","text"}` queues a message.
/// - `GET /a/<token>/guest/status?ids=a,b` reports submission statuses.
///
/// The link token authorizes the request. The page nonce header, the JSON
/// content type, and the Origin check keep other sites from posting.
enum AIChatGuestMessageHTTP {
  static let nonceHeader = "X-Celorga-Guest-Nonce"

  private struct SubmitRequest: Decodable {
    let name: String
    let text: String
  }

  private struct SubmitResponse: Encodable {
    let id: String
    let status: AIChatGuestSubmission.Status
  }

  private struct StatusResponse: Encodable {
    let statuses: [String: AIChatGuestSubmission.Status]
  }

  private struct ErrorResponse: Encodable {
    let error: String
  }

  static func response(
    to request: MobileRemoteHTTPRequest,
    shareID: String,
    route: [String],
    queue: AIChatGuestMessageQueue
  ) -> MobileRemoteHTTPResponse {
    guard isSameOrigin(request) else { return failure(.crossOrigin) }
    let nonce = request.headers[nonceHeader.lowercased()]
    switch (request.method, route) {
    case ("POST", []):
      guard request.body.count <= AIChatGuestMessageQueue.maximumBodyBytes else {
        return failure(.tooLarge)
      }
      guard queue.isEnabled(shareID: shareID) else { return failure(.notAccepting) }
      guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
        return failure(.unsupportedContentType)
      }
      guard let payload = try? JSONDecoder().decode(SubmitRequest.self, from: request.body) else {
        return failure(.invalidPayload("Send a name and a message."))
      }
      switch queue.submit(shareID: shareID, nonce: nonce, name: payload.name, text: payload.text) {
      case .success(let submission):
        return json(SubmitResponse(id: submission.id, status: submission.status), statusCode: 201)
      case .failure(let error):
        return failure(error)
      }
    case ("GET", ["status"]):
      let query = URLComponents(string: request.path)?.queryItems ?? []
      let ids = (query.first { $0.name == "ids" }?.value ?? "")
        .split(separator: ",")
        .map(String.init)
      switch queue.statuses(shareID: shareID, nonce: nonce, ids: ids) {
      case .success(let statuses):
        return json(StatusResponse(statuses: statuses))
      case .failure(let error):
        return failure(error)
      }
    default:
      return json(ErrorResponse(error: "Not found."), statusCode: 404)
    }
  }

  /// Browsers send `Origin` on cross-site and same-origin POSTs; when it is
  /// present it must name this host. `Sec-Fetch-Site`, when sent, must agree.
  static func isSameOrigin(_ request: MobileRemoteHTTPRequest) -> Bool {
    if let site = request.headers["sec-fetch-site"]?.lowercased(), site != "same-origin" {
      return false
    }
    guard let origin = request.headers["origin"] else { return true }
    guard let url = URL(string: origin),
          url.scheme?.lowercased() == "http",
          let originHost = url.host,
          let host = request.headers["host"]?.lowercased()
    else { return false }
    let bracketed = originHost.contains(":") && !originHost.hasPrefix("[") ? "[\(originHost)]" : originHost
    let authority = (url.port.map { "\(bracketed):\($0)" } ?? bracketed).lowercased()
    return authority == host
  }

  private static func failure(_ error: AIChatGuestMessageError) -> MobileRemoteHTTPResponse {
    json(ErrorResponse(error: error.errorDescription ?? "Request failed."), statusCode: error.statusCode)
  }

  private static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> MobileRemoteHTTPResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return MobileRemoteHTTPResponse(
      statusCode: statusCode,
      headers: [
        "Cache-Control": "no-store",
        "Content-Type": "application/json; charset=utf-8",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "X-Robots-Tag": "noindex, nofollow, noarchive",
      ],
      body: (try? encoder.encode(value)) ?? Data("{}".utf8)
    )
  }

  // MARK: Page

  /// The composer markup. It stays hidden until the live root carries a
  /// guest nonce, so turning the option on or off updates open pages.
  static let composerHTML = """
  <section id="celorga-guest" class="guest" hidden aria-label="Send a message">
  <h2>Send a message</h2>
  <p class="guest-note">The owner reviews each message before it is added to the conversation. Text only.</p>
  <form id="celorga-guest-form">
  <input id="celorga-guest-name" name="name" maxlength="\(AIChatGuestMessageQueue.maximumNameLength)" placeholder="Your name" autocomplete="nickname" required>
  <textarea id="celorga-guest-text" name="text" maxlength="\(AIChatGuestMessageQueue.maximumTextLength)" rows="3" placeholder="Message" required></textarea>
  <div class="guest-actions"><span id="celorga-guest-error" role="alert"></span><button type="submit">Send for Approval</button></div>
  </form>
  <ol id="celorga-guest-submissions" aria-live="polite"></ol>
  </section>
  """

  /// Sends guest messages and shows their status. Guest text is only ever
  /// assigned through `textContent`.
  static let script = #"""
  (() => {
    const page = location.pathname.replace(/\/+$/, '');
    const byID = id => document.getElementById(id);
    const nonce = () => byID('openorg-live-root')?.dataset.guestNonce || '';
    const key = 'celorga-guest:' + page;
    const labels = { pending: 'Waiting for approval', approved: 'Approved', declined: 'Declined' };
    let items = [];
    try { items = JSON.parse(sessionStorage.getItem(key) || '[]'); } catch (error) { items = []; }
    if (!Array.isArray(items)) items = [];
    const save = () => { try { sessionStorage.setItem(key, JSON.stringify(items.slice(-20))); } catch (error) {} };
    const render = () => {
      const list = byID('celorga-guest-submissions'); if (!list) return;
      list.replaceChildren(...items.slice(-20).map(item => {
        const row = document.createElement('li');
        row.dataset.status = String(item.status);
        const status = document.createElement('span');
        status.className = 'guest-status';
        status.textContent = labels[item.status] || 'No longer available';
        const text = document.createElement('span');
        text.className = 'guest-text';
        text.textContent = String(item.text || '');
        row.append(status, text);
        return row;
      }));
    };
    const sync = () => { const section = byID('celorga-guest'); if (section) section.hidden = !nonce(); };
    const request = (path, options) => fetch(page + path, Object.assign({ cache: 'no-store', credentials: 'omit' }, options, {
      headers: Object.assign({ 'X-Celorga-Guest-Nonce': nonce() }, (options && options.headers) || {})
    }));
    const poll = async () => {
      sync();
      const pending = items.filter(item => item.status === 'pending').map(item => item.id);
      if (pending.length && nonce()) {
        try {
          const response = await request('/guest/status?ids=' + encodeURIComponent(pending.join(',')));
          if (response.ok) {
            const statuses = (await response.json()).statuses || {};
            for (const item of items) if (item.status === 'pending') item.status = statuses[item.id] || 'gone';
          } else if (response.status === 403 || response.status === 404) {
            for (const item of items) if (item.status === 'pending') item.status = 'gone';
          }
          save(); render();
        } catch (error) {}
      }
      setTimeout(poll, 4000);
    };
    byID('celorga-guest-form')?.addEventListener('submit', async event => {
      event.preventDefault();
      const name = byID('celorga-guest-name'), text = byID('celorga-guest-text'), error = byID('celorga-guest-error');
      const button = event.target.querySelector('button');
      error.textContent = ''; button.disabled = true;
      try {
        const response = await request('/guest', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: name.value, text: text.value })
        });
        const body = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(body.error || 'Could not send the message.');
        items.push({ id: String(body.id), status: String(body.status), text: text.value.trim() });
        text.value = ''; save(); render();
      } catch (failure) {
        error.textContent = failure.message;
      }
      button.disabled = false;
    });
    new MutationObserver(sync).observe(document.body, { childList: true });
    render(); sync(); setTimeout(poll, 1000);
  })();
  """#

  static let scriptHash: String = {
    "sha256-" + Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
  }()

  static var scriptElement: String {
    "<script>\(script)</script>"
  }

  static let stylesheet = """
  .guest { box-sizing:border-box; max-width:860px; margin:28px auto 0; padding:0 20px; }
  .guest h2 { margin:0 0 4px; font-size:14px; font-weight:650; }
  .guest-note { margin:0 0 10px; font-size:12px; color:light-dark(#777,#aaa); }
  #celorga-guest-form { display:flex; flex-direction:column; gap:8px; }
  #celorga-guest-form input, #celorga-guest-form textarea { font:inherit; padding:7px 9px; border:1px solid light-dark(#d8d8d3,#424442); border-radius:6px; background:light-dark(#fff,#1e201e); color:inherit; }
  #celorga-guest-form input { max-width:260px; }
  #celorga-guest-form textarea { resize:vertical; min-height:60px; }
  .guest-actions { display:flex; align-items:center; justify-content:flex-end; gap:10px; }
  #celorga-guest-error { flex:1; font-size:12px; color:light-dark(#b42318,#f97066); }
  .guest-actions button { font:inherit; font-weight:600; padding:6px 12px; border:0; border-radius:6px; background:#2f6fde; color:#fff; cursor:pointer; }
  .guest-actions button:disabled { opacity:.6; cursor:default; }
  #celorga-guest-submissions { list-style:none; margin:12px 0 0; padding:0; display:flex; flex-direction:column; gap:6px; }
  #celorga-guest-submissions li { display:flex; gap:8px; font-size:12px; white-space:pre-wrap; }
  .guest-status { flex:none; font-weight:600; color:light-dark(#777,#aaa); }
  #celorga-guest-submissions li[data-status="approved"] .guest-status { color:#1f8a44; }
  #celorga-guest-submissions li[data-status="declined"] .guest-status { color:light-dark(#b42318,#f97066); }
  @media (max-width: 600px) { .guest { padding-left:12px; padding-right:12px; } }
  """
}

// MARK: - Store integration

extension WorkspaceStore {
  var aiChatGuestMessageQueue: AIChatGuestMessageQueue {
    localDocumentPublicationHost.guestMessages
  }

  public func isChatThreadGuestMessagesEnabled(_ threadID: UUID) -> Bool {
    aiChatGuestMessageThreadIDs.contains(threadID)
  }

  public func pendingAIChatGuestMessages(for threadID: UUID) -> [AIChatGuestSubmission] {
    aiChatGuestSubmissions.filter { $0.threadID == threadID }
  }

  /// Turns guest messages on or off for the thread's link on this Mac, then
  /// refreshes the page so open readers see or lose the composer.
  public func setChatThreadGuestMessagesEnabled(_ enabled: Bool, for threadID: UUID) async throws {
    guard let publication = chatThreadPublication(for: threadID) else {
      throw AIChatGuestMessageError.notShared
    }
    observeAIChatGuestMessages()
    if enabled {
      aiChatGuestMessageQueue.enable(shareID: publication.id, threadID: threadID)
    } else {
      aiChatGuestMessageQueue.disable(shareID: publication.id)
    }
    refreshAIChatGuestMessages()
    try await publishChatThread(threadID)
    statusText = enabled
      ? "Guests can send messages for you to approve"
      : "Guests can no longer send messages"
  }

  /// Sends a pending guest message through the thread's normal send path,
  /// attributed to the guest. `editedText` replaces the guest's wording.
  @discardableResult
  public func approveAIChatGuestMessage(_ id: String, editedText: String? = nil) -> Bool {
    guard let submission = aiChatGuestMessageQueue.pendingSubmission(id) else {
      refreshAIChatGuestMessages()
      return false
    }
    let text = AIChatGuestMessageQueue.sanitizedText(editedText ?? submission.text)
    guard !text.isEmpty else { return false }
    let message = AIChatGuestMessageQueue.attributedText(name: submission.displayName, text: text)
    guard sendAIChatRemoteMessage(message, threadID: submission.threadID) else {
      errorText = "Celorga could not send the guest message to this thread."
      return false
    }
    aiChatGuestMessageQueue.resolve(id, approved: true)
    refreshAIChatGuestMessages()
    return true
  }

  public func declineAIChatGuestMessage(_ id: String) {
    aiChatGuestMessageQueue.resolve(id, approved: false)
    refreshAIChatGuestMessages()
  }

  func observeAIChatGuestMessages() {
    guard !isObservingAIChatGuestMessages else { return }
    isObservingAIChatGuestMessages = true
    aiChatGuestMessageQueue.setChangeHandler { [weak self] in
      Task { @MainActor [weak self] in self?.refreshAIChatGuestMessages() }
    }
  }

  func refreshAIChatGuestMessages() {
    let pending = aiChatGuestMessageQueue.pendingSubmissions
    if pending != aiChatGuestSubmissions {
      aiChatGuestSubmissions = pending
    }
    let threadIDs = aiChatGuestMessageQueue.enabledThreadIDs
    if threadIDs != aiChatGuestMessageThreadIDs {
      aiChatGuestMessageThreadIDs = threadIDs
    }
  }
}

// MARK: - Views

/// Pending guest messages for the selected thread, shown above the composer.
struct AIChatGuestMessagesPanel: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    if let threadID = store.selectedAIChatThreadID {
      let pending = store.pendingAIChatGuestMessages(for: threadID)
      if !pending.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Label(
            pending.count == 1 ? "1 guest message to review" : "\(pending.count) guest messages to review",
            systemImage: "person.crop.circle.badge.questionmark"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          ForEach(pending) { submission in
            AIChatGuestMessageRow(submission: submission)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("ai-chat-guest-messages")
      }
    }
  }
}

private struct AIChatGuestMessageRow: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var isEditing = false
  @State private var editedText = ""
  let submission: AIChatGuestSubmission

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(verbatim: "Guest — \(submission.displayName)")
          .font(.callout.weight(.semibold))
        Text(submission.submittedAt, style: .time)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      if isEditing {
        TextEditor(text: $editedText)
          .font(.callout)
          .frame(minHeight: 60, maxHeight: 160)
          .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
      } else {
        Text(verbatim: submission.text)
          .font(.callout)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        if isEditing {
          Button("Cancel") { isEditing = false }
          Button("Approve Edited") {
            if store.approveAIChatGuestMessage(submission.id, editedText: editedText) {
              isEditing = false
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(AIChatGuestMessageQueue.sanitizedText(editedText).isEmpty)
        } else {
          Button("Decline", role: .destructive) {
            store.declineAIChatGuestMessage(submission.id)
          }
          Button("Edit & Approve…") {
            editedText = submission.text
            isEditing = true
          }
          Button("Approve") {
            store.approveAIChatGuestMessage(submission.id)
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .controlSize(.small)
    }
    .padding(10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }
}
