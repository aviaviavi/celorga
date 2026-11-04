import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class AIChatUsageLimitTests: XCTestCase {
  private let utc = TimeZone(identifier: "UTC")!
  private let posix = Locale(identifier: "en_US_POSIX")
  /// 2026-11-04T12:00:00Z
  private let now = Date(timeIntervalSince1970: 1_793_793_600)

  private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  /// Date formatting may use narrow no-break spaces, as in "3:40\u{202F}PM".
  private func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
  }

  private func classify(
    _ text: String,
    status: Int? = nil,
    headers: [String: String] = [:]
  ) -> AIChatUsageLimit? {
    AIChatUsageLimitClassifier.classify(text, statusCode: status, headers: headers, now: now, timeZone: utc)
  }

  // MARK: Codex

  func testCodexUsageLimitWithSameDayClockTime() throws {
    let limit = try XCTUnwrap(classify(
      "Codex turn failed: You've hit your usage limit. Upgrade to Pro (https://example.com/pro) or try again at 3:40 PM."
    ))
    XCTAssertEqual(limit.resetsAt, date("2026-11-04T15:40:00Z"))
    XCTAssertEqual(plain(limit.headline(now: now, timeZone: utc, locale: posix)), "Usage limit reached · resets 3:40 PM")
  }

  func testCodexUsageLimitWithDateAndOrdinalDay() throws {
    let limit = try XCTUnwrap(classify("You've hit your usage limit. Try again at Nov 5th, 2026 9:15 AM."))
    XCTAssertEqual(limit.resetsAt, date("2026-11-05T09:15:00Z"))
    let headline = plain(limit.headline(now: now, timeZone: utc, locale: posix))
    XCTAssertTrue(headline.hasPrefix("Usage limit reached · resets Nov 5"), headline)
    XCTAssertTrue(headline.hasSuffix("9:15 AM"), headline)
  }

  func testCodexUsageLimitWithRelativeTime() throws {
    let limit = try XCTUnwrap(classify("You've hit your usage limit. Try again in 2 hours 13 minutes."))
    XCTAssertEqual(limit.resetsAt, now.addingTimeInterval(2 * 3_600 + 13 * 60))
  }

  func testCodexBackendUsageLimitJSONWithResetsAt() throws {
    let limit = try XCTUnwrap(classify(
      #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"plus","resets_at":1793806800}}"#
    ))
    XCTAssertEqual(limit.resetsAt, date("2026-11-04T15:40:00Z"))
  }

  func testCodexTurnErrorTaggedUsageLimitExceededIsRecognized() throws {
    let message = CodexAppServerClient.turnErrorMessage(.object([
      "message": .string("Request refused."),
      "codexErrorInfo": .string("usageLimitExceeded"),
    ]))
    XCTAssertEqual(message, "Usage limit reached: Request refused.")
    XCTAssertNotNil(classify(try XCTUnwrap(message)))
    XCTAssertEqual(
      CodexAppServerClient.turnErrorMessage(.object(["message": .string("Context window exceeded.")])),
      "Context window exceeded."
    )
  }

  // MARK: Claude Code

  func testClaudeCodePipeEpochForm() throws {
    let limit = try XCTUnwrap(classify("Claude Code turn failed: Claude AI usage limit reached|1793806800"))
    XCTAssertEqual(limit.resetsAt, date("2026-11-04T15:40:00Z"))
  }

  func testClaudeCodeResetTextInNamedTimeZone() throws {
    let limit = try XCTUnwrap(classify("5-hour limit reached ∙ resets 3pm (America/New_York)"))
    // 3 PM Eastern Standard Time on 2026-11-04.
    XCTAssertEqual(limit.resetsAt, date("2026-11-04T20:00:00Z"))
    let hit = try XCTUnwrap(classify("You've hit your limit · resets 11am"))
    // 11 AM has passed today, so the next 11 AM.
    XCTAssertEqual(hit.resetsAt, date("2026-11-05T11:00:00Z"))
  }

  func testClaudeCodeStreamRejectedRateLimitEventBecomesUsageLimit() async throws {
    var decoder = ClaudeCodeStreamDecoder()
    await decoder.consume(
      #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1793806800,"rateLimitType":"five_hour"},"session_id":"session-a"}"#
    ) { _ in }
    await decoder.consume(
      #"{"type":"result","subtype":"success","is_error":true,"result":"Session limit reached","session_id":"session-a"}"#
    ) { _ in }
    XCTAssertFalse(decoder.result.succeeded)
    let error = try XCTUnwrap(decoder.result.failure(stderr: "", status: 1, now: now) as? AIChatUsageLimitError)
    XCTAssertEqual(error.limit.resetsAt, date("2026-11-04T15:40:00Z"))
    XCTAssertEqual(error.limit.detail, "Claude Code turn failed: Session limit reached")
  }

  func testClaudeCodeOrdinaryFailureStaysAGenericError() async throws {
    var decoder = ClaudeCodeStreamDecoder()
    await decoder.consume(
      #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Tool crashed"],"session_id":"s"}"#
    ) { _ in }
    let error = decoder.result.failure(stderr: "", status: 1, now: now)
    XCTAssertFalse(error is AIChatUsageLimitError)
    XCTAssertEqual(error.localizedDescription, "Claude Code turn failed: Tool crashed")
  }

  // MARK: OpenCode, Pi, OpenClaw

  func testOpenCodeAPIErrorUsesStatusAndRetryAfterHeader() throws {
    let limit = try XCTUnwrap(OpenCodeStreamDecoder.usageLimit(
      detail: "Rate limit exceeded",
      errorName: "APIError",
      data: ["statusCode": 429, "responseHeaders": ["retry-after": "120"], "responseBody": "{}"],
      now: now
    ))
    XCTAssertEqual(limit.resetsAt, now.addingTimeInterval(120))
    XCTAssertEqual(limit.detail, "Rate limit exceeded")
    XCTAssertNil(OpenCodeStreamDecoder.usageLimit(
      detail: "Bad request",
      errorName: "APIError",
      data: ["statusCode": 400],
      now: now
    ))
  }

  func testOpenCodeStreamStoresTheCanonicalFailure() async throws {
    var decoder = OpenCodeStreamDecoder()
    await decoder.consume(
      #"{"type":"error","sessionID":"ses_1","error":{"name":"APIError","data":{"message":"You exceeded your current quota","statusCode":429,"isRetryable":false}}}"#
    ) { _ in }
    let stored = try XCTUnwrap(decoder.result.errors.first)
    let limit = try XCTUnwrap(AIChatUsageLimit(failureText: stored))
    XCTAssertEqual(limit.detail, "You exceeded your current quota")
    // The adapter wraps it; delivery still recognizes the canonical form.
    let wrapped = OpenCodeError.turnFailed(stored).localizedDescription
    XCTAssertEqual(classify(wrapped), limit)
  }

  func testPiProviderRateLimitError() throws {
    let limit = try XCTUnwrap(classify(
      #"Pi turn failed: 429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization"}}"#
    ))
    XCTAssertNil(limit.resetsAt)
    XCTAssertEqual(plain(limit.headline(now: now, timeZone: utc, locale: posix)), "Usage limit reached")
  }

  func testOpenClawRateLimitText() {
    XCTAssertNotNil(classify("⚠️ API rate limit reached. Please try again later."))
    XCTAssertNotNil(classify("OpenClaw returned HTTP 429: Too Many Requests"))
  }

  // MARK: Direct providers

  func testDirectProviderQuotaUsesRetryAfter() throws {
    let response = try XCTUnwrap(HTTPURLResponse(
      url: URL(string: "https://provider.example/v1/chat/completions")!,
      statusCode: 429,
      httpVersion: nil,
      headerFields: ["Retry-After": "30"]
    ))
    let body = #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#
    let limit = try XCTUnwrap(AIProviderChatClient.usageLimit(
      .httpStatus(429, body),
      response: response,
      now: now
    ))
    XCTAssertEqual(limit.resetsAt, now.addingTimeInterval(30))
    XCTAssertTrue(limit.detail.hasPrefix("The provider returned HTTP 429:"), limit.detail)
  }

  func testDirectProviderResetHeaders() {
    XCTAssertEqual(
      classify("{}", status: 429, headers: ["x-ratelimit-reset-requests": "1s", "x-ratelimit-reset-tokens": "6m0s"])?.resetsAt,
      now.addingTimeInterval(360)
    )
    XCTAssertEqual(
      classify("{}", status: 429, headers: ["anthropic-ratelimit-unified-reset": "2026-11-04T13:00:00Z"])?.resetsAt,
      date("2026-11-04T13:00:00Z")
    )
    XCTAssertEqual(
      classify("{}", status: 429, headers: ["Retry-After": "Wed, 04 Nov 2026 12:05:00 GMT"])?.resetsAt,
      date("2026-11-04T12:05:00Z")
    )
    XCTAssertEqual(
      classify("{}", status: 429, headers: ["x-ratelimit-reset": "1793806800"])?.resetsAt,
      date("2026-11-04T15:40:00Z")
    )
  }

  func testDirectProviderInsufficientBalanceAndAnthropicCredit() {
    XCTAssertNotNil(classify(
      AIProviderChatError.httpStatus(402, #"{"error":{"message":"Insufficient Balance","type":"unknown_error"}}"#).localizedDescription
    ))
    XCTAssertNotNil(classify(
      #"The provider returned HTTP 400: {"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the API."}}"#
    ))
  }

  // MARK: Not usage limits

  func testOtherFailuresAreNotUsageLimits() {
    XCTAssertNil(classify("The provider returned HTTP 400: context_length_exceeded: maximum context length is 128000 tokens"))
    XCTAssertNil(classify("The provider returned HTTP 401: invalid api key"))
    XCTAssertNil(classify("The provider returned HTTP 500."))
    XCTAssertNil(classify("Codex disconnected."))
    XCTAssertNil(classify("Room agent turn limit reached."))
    XCTAssertNil(classify("Claude Code exited with status 1."))
  }

  // MARK: Canonical text

  func testCanonicalFailureTextRoundTrips() throws {
    let limit = AIChatUsageLimit(resetsAt: date("2026-11-04T15:40:00Z"), detail: "Try again later.")
    XCTAssertEqual(limit.failureText, "Usage limit reached (resets 2026-11-04T15:40:00Z): Try again later.")
    XCTAssertEqual(AIChatUsageLimit(failureText: limit.failureText), limit)
    XCTAssertEqual(AIChatUsageLimit(failureText: "Usage limit reached."), AIChatUsageLimit(resetsAt: nil, detail: ""))
    XCTAssertNil(AIChatUsageLimit(failureText: "Codex disconnected."))
    XCTAssertNil(AIChatUsageLimit(failureText: "Usage limit reached soon"))
    // Once stored, a reset is never recomputed from the clock.
    XCTAssertEqual(
      AIChatUsageLimitClassifier.classify(limit.failureText, now: now.addingTimeInterval(86_400)),
      limit
    )
  }

  func testHeadlineAfterTheResetTimeUsesPastTense() {
    let limit = AIChatUsageLimit(resetsAt: date("2026-11-04T11:00:00Z"), detail: "")
    XCTAssertEqual(plain(limit.headline(now: now, timeZone: utc, locale: posix)), "Usage limit reached · reset 11:00 AM")
  }

  func testSendFailureTextFixesRelativeResetAtFailureTime() throws {
    let stored = WorkspaceStore.aiChatSendFailureText(
      from: CodexAppServerError.turnFailed("You've hit your usage limit. Try again in 30 minutes."),
      now: now
    )
    let limit = try XCTUnwrap(AIChatUsageLimit(failureText: stored))
    XCTAssertEqual(limit.resetsAt, now.addingTimeInterval(1_800))
    XCTAssertEqual(limit.detail, "Codex turn failed: You've hit your usage limit. Try again in 30 minutes.")
    XCTAssertEqual(
      WorkspaceStore.aiChatSendFailureText(from: CodexAppServerError.disconnected(""), now: now),
      "Codex disconnected."
    )
    XCTAssertEqual(
      WorkspaceStore.aiChatSendFailureText(from: AIChatUsageLimitError(limit), now: now),
      limit.failureText
    )
  }

  func testTranscriptUsageLimitPresentation() throws {
    let limit = AIChatUsageLimit(resetsAt: date("2026-11-04T15:40:00Z"), detail: "Quota exhausted.")
    let destinations = AIChatDestinationConfiguration.defaults.filter {
      $0.id == AIChatDestinationConfiguration.localClaudeID
    }
    let presentation = try XCTUnwrap(AIChatTranscriptHTML.UsageLimit(
      failure: limit.failureText,
      resendDestinations: destinations,
      now: now,
      timeZone: utc,
      locale: posix
    ))
    XCTAssertEqual(plain(presentation.title), "Usage limit reached · resets 3:40 PM")
    XCTAssertEqual(presentation.detail, "Quota exhausted.")
    XCTAssertEqual(presentation.resend, [.init(id: AIChatDestinationConfiguration.localClaudeID, title: "Claude Code")])
    XCTAssertNil(AIChatTranscriptHTML.UsageLimit(failure: "Codex disconnected.", resendDestinations: destinations))
  }

  // MARK: Resend

  @MainActor
  func testResendForksTheChatToTheChosenAgentOnlyWhenAsked() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-usage-limit-resend-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "AIChatUsageLimit.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        messages.last(where: { $0.role == .user })?.content.contains("release notes") == true
          ? "Here are the release notes."
          : "Unexpected prompt"
      },
      codexSendHandlerForTesting: { _, _, _ in
        throw CodexAppServerError.turnFailed("You've hit your usage limit. Try again in 30 minutes.")
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let sourceID = store.createAIChatThread(destinationID: AIChatDestinationConfiguration.localCodexID)
    store.selectAIChatThread(sourceID)
    await store.sendAIChatMessage(text: "Draft the release notes")

    let source = try XCTUnwrap(store.aiChatThread(withID: sourceID))
    let failed = try XCTUnwrap(source.messages.last(where: { $0.role == .user }))
    let limit = try XCTUnwrap(failed.sendFailure.flatMap(AIChatUsageLimit.init(failureText:)))
    XCTAssertNotNil(limit.resetsAt)
    XCTAssertTrue(store.aiChatStatusText.contains("Usage limit reached"), store.aiChatStatusText)

    // Celorga offers other enabled agents but does not switch on its own.
    let options = store.aiChatResendDestinations(forUsageLimitedMessage: failed.id)
    XCTAssertFalse(options.contains { $0.id == AIChatDestinationConfiguration.localCodexID })
    XCTAssertTrue(options.contains { $0.id == AIChatDestinationConfiguration.openClawID })
    let threadCountBefore = store.aiChatThreads.count
    XCTAssertEqual(source.messages.filter { $0.role == .assistant }.count, 0)

    let resentID = await store.resendUsageLimitedAIChatMessage(
      failed.id,
      toDestinationID: AIChatDestinationConfiguration.openClawID
    )
    let forkID = try XCTUnwrap(resentID)
    XCTAssertEqual(store.aiChatThreads.count, threadCountBefore + 1)
    XCTAssertEqual(store.selectedAIChatThreadID, forkID)
    for _ in 0..<200 {
      if store.aiChatThread(withID: forkID)?.messages.contains(where: { $0.role == .assistant }) == true { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let fork = try XCTUnwrap(store.aiChatThread(withID: forkID))
    XCTAssertEqual(fork.destinationID, AIChatDestinationConfiguration.openClawID)
    XCTAssertEqual(fork.messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(fork.messages.first?.content, "Draft the release notes")
    XCTAssertNil(fork.messages.first?.sendFailure)
    XCTAssertEqual(fork.messages.last?.content, "Here are the release notes.")

    // The original chat keeps its failed message and its agent.
    let original = try XCTUnwrap(store.aiChatThread(withID: sourceID))
    XCTAssertEqual(original.destinationID, AIChatDestinationConfiguration.localCodexID)
    XCTAssertEqual(original.messages.last(where: { $0.role == .user })?.sendFailure, failed.sendFailure)

    // A message that did not hit a usage limit offers no resend.
    XCTAssertTrue(store.aiChatResendDestinations(forUsageLimitedMessage: UUID()).isEmpty)
  }
}
