import Foundation

/// A chat turn that failed because the agent's provider account is out of
/// usage, with the time it resets when the provider said so.
///
/// Delivery stores `failureText` as the message's send failure. That text
/// stays readable on every client, and `init?(failureText:)` reads it back,
/// so a reset time computed from a relative "try again in 2 hours" is fixed
/// at the moment the turn failed rather than when the chat is reopened.
public struct AIChatUsageLimit: Equatable, Sendable {
  public static let canonicalPrefix = "Usage limit reached"

  public let resetsAt: Date?
  /// The provider's own explanation, kept for the details line.
  public let detail: String

  public init(resetsAt: Date?, detail: String) {
    self.resetsAt = resetsAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded()) }
    self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The persisted send failure, for example
  /// `Usage limit reached (resets 2026-11-04T15:40:00Z): You've hit your usage limit.`
  public var failureText: String {
    var text = Self.canonicalPrefix
    if let resetsAt { text += " (resets \(Self.isoFormatter.string(from: resetsAt)))" }
    return detail.isEmpty ? text + "." : text + ": " + detail
  }

  /// Reads a persisted `failureText` back. Only the canonical form matches;
  /// arbitrary provider text is classified by `AIChatUsageLimitClassifier`.
  public init?(failureText: String) {
    let text = failureText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix(Self.canonicalPrefix) else { return nil }
    var rest = text.dropFirst(Self.canonicalPrefix.count)
    var resetsAt: Date?
    if rest.hasPrefix(" (resets "), let close = rest.firstIndex(of: ")") {
      let stamp = rest[rest.index(rest.startIndex, offsetBy: " (resets ".count)..<close]
      guard let date = Self.isoFormatter.date(from: String(stamp)) else { return nil }
      resetsAt = date
      rest = rest[rest.index(after: close)...]
    }
    if rest.isEmpty || rest == "." {
      self.init(resetsAt: resetsAt, detail: "")
    } else if rest.hasPrefix(": ") {
      self.init(resetsAt: resetsAt, detail: String(rest.dropFirst(2)))
    } else {
      return nil
    }
  }

  /// One line for the thread and the chat status, for example
  /// "Usage limit reached · resets 3:40 PM".
  public func headline(
    now: Date = Date(),
    timeZone: TimeZone = .current,
    locale: Locale = .current
  ) -> String {
    guard let resetsAt else { return Self.canonicalPrefix }
    let time = Self.resetTimeText(resetsAt, now: now, timeZone: timeZone, locale: locale)
    return resetsAt > now
      ? "\(Self.canonicalPrefix) · resets \(time)"
      : "\(Self.canonicalPrefix) · reset \(time)"
  }

  static func resetTimeText(
    _ date: Date,
    now: Date,
    timeZone: TimeZone,
    locale: Locale
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.calendar = calendar
    formatter.setLocalizedDateFormatFromTemplate(
      calendar.isDate(date, inSameDayAs: now) ? "jmm" : "MMMdjmm"
    )
    return formatter.string(from: date)
  }

  nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}

/// Thrown by adapters that see a usage limit with structured detail (HTTP
/// headers or a stream event) that the error text alone would lose.
public struct AIChatUsageLimitError: LocalizedError, Equatable, Sendable {
  public let limit: AIChatUsageLimit

  public init(_ limit: AIChatUsageLimit) {
    self.limit = limit
  }

  public var errorDescription: String? { limit.failureText }
}

/// Recognizes usage-limit and quota failures in what chat runtimes report:
/// HTTP status and headers from direct providers, error JSON bodies, and the
/// text that Codex, Claude Code, OpenCode, Pi, and OpenClaw print. Pure: the
/// caller supplies the clock and time zone.
public enum AIChatUsageLimitClassifier {
  public static func classify(
    _ text: String,
    statusCode: Int? = nil,
    headers: [String: String] = [:],
    now: Date = Date(),
    timeZone: TimeZone = .current
  ) -> AIChatUsageLimit? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let canonical = embeddedCanonical(in: trimmed)
    if let canonical, canonical.resetsAt != nil { return canonical }
    let detail = canonical?.detail ?? trimmed
    guard canonical != nil || statusCode == 429 || mentionsUsageLimit(detail) else {
      return nil
    }
    let resetsAt = resetDate(fromHeaders: headers, now: now)
      ?? resetDate(inText: detail, now: now, timeZone: timeZone)
    return AIChatUsageLimit(resetsAt: resetsAt, detail: detail)
  }

  /// A wrapped canonical failure, such as an adapter error that prefixes
  /// "OpenCode turn failed: " to a failure the stream decoder already
  /// classified.
  static func embeddedCanonical(in text: String) -> AIChatUsageLimit? {
    guard let range = text.range(of: AIChatUsageLimit.canonicalPrefix) else { return nil }
    return AIChatUsageLimit(failureText: String(text[range.lowerBound...]))
  }

  static func mentionsUsageLimit(_ text: String) -> Bool {
    let lowered = text.lowercased()
    if usagePhrases.contains(where: lowered.contains) { return true }
    let range = NSRange(lowered.startIndex..., in: lowered)
    return usagePatterns.contains { $0.firstMatch(in: lowered, range: range) != nil }
  }

  private static let usagePhrases = [
    "usage limit", "usage_limit", "usagelimitexceeded", "freeusagelimiterror",
    "insufficient_quota", "exceeded your current quota", "exceeded your quota",
    "quota exceeded", "quota_exceeded", "resource_exhausted", "resource exhausted",
    "rate_limit_exceeded", "rate_limit_error", "rate limit reached", "rate limit exceeded",
    "ratelimitexceeded", "too many requests", "hit your limit", "billing_hard_limit_reached",
    "credit balance is too low", "insufficient balance", "insufficient credits", "out of credits",
  ]

  private static let usagePatterns: [NSRegularExpression] = [
    // "HTTP 429", "status 429", "API Error: 429", or a bare leading 429.
    #"(?:http|status|error|code)[^0-9a-z]{0,3}429\b|^429\b"#,
    // Claude Code and similar plan limits: "5-hour limit reached ∙ resets 3pm".
    #"\b(?:5-hour|five-hour|weekly|daily|monthly|session|opus|sonnet|plan|spend|spending|credit)s? limit (?:reached|exceeded|hit)"#,
    #"\blimit (?:reached|exceeded)[^\n]{0,40}\breset"#,
  ].map { try! NSRegularExpression(pattern: $0) }

  // MARK: Reset time

  private static let retryAfterHeaders = ["retry-after-ms", "retry-after"]
  private static let resetHeaders = [
    "x-ratelimit-reset", "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens", "ratelimit-reset",
    "anthropic-ratelimit-unified-reset", "anthropic-ratelimit-requests-reset",
    "anthropic-ratelimit-tokens-reset", "anthropic-ratelimit-input-tokens-reset",
    "anthropic-ratelimit-output-tokens-reset",
  ]

  /// `Retry-After` wins when present; otherwise the latest of the provider's
  /// reset headers, since it cannot be known which limit was exhausted.
  static func resetDate(fromHeaders headers: [String: String], now: Date) -> Date? {
    guard !headers.isEmpty else { return nil }
    var lowered: [String: String] = [:]
    for (key, value) in headers { lowered[key.lowercased()] = value }
    if let milliseconds = lowered["retry-after-ms"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
      return now.addingTimeInterval(milliseconds / 1_000)
    }
    if let retryAfter = lowered["retry-after"],
       let date = parseResetValue(retryAfter, now: now, smallNumbersAreRelative: true) {
      return date
    }
    return resetHeaders
      .compactMap { lowered[$0].flatMap { parseResetValue($0, now: now, smallNumbersAreRelative: true) } }
      .max()
  }

  static func resetDate(inText text: String, now: Date, timeZone: TimeZone) -> Date? {
    if let match = firstCapture(jsonResetAtPattern, in: text),
       let date = parseResetValue(match, now: now, smallNumbersAreRelative: false) {
      return date
    }
    if let match = firstCapture(jsonResetInPattern, in: text), let seconds = Double(match) {
      return now.addingTimeInterval(seconds)
    }
    if let match = firstCapture(pipeEpochPattern, in: text),
       let date = parseResetValue(match, now: now, smallNumbersAreRelative: false) {
      return date
    }
    if let match = firstCapture(isoResetPattern, in: text), let date = parseISODate(match) {
      return date
    }
    if let span = firstCapture(relativePattern, in: text), let seconds = durationSeconds(span) {
      return now.addingTimeInterval(seconds)
    }
    return clockResetDate(in: text, now: now, timeZone: timeZone)
  }

  private static let jsonResetAtPattern = try! NSRegularExpression(
    pattern: #""(?:resets_at|reset_at|resetsAt|resetAt)"\s*:\s*"?([^",}\s]+)"?"#
  )
  private static let jsonResetInPattern = try! NSRegularExpression(
    pattern: #""(?:resets_in_seconds|reset_in_seconds|resets_in|retry_after_seconds|retry_after|retryAfter)"\s*:\s*"?(\d+(?:\.\d+)?)"#
  )
  /// Claude Code's machine-readable form: "Claude AI usage limit reached|1762275600".
  private static let pipeEpochPattern = try! NSRegularExpression(
    pattern: #"limit reached\|(\d{10,13})\b"#, options: [.caseInsensitive]
  )
  private static let isoResetPattern = try! NSRegularExpression(
    pattern: #"\bresets?(?:\s+at)?\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2}))"#,
    options: [.caseInsensitive]
  )
  private static let durationUnit = #"(?:ms|days?|hours?|hrs?|minutes?|mins?|seconds?|secs?|[dhms])(?![a-z])"#
  private static let relativePattern = try! NSRegularExpression(
    pattern: #"(?:try again|retry|resets?|reset|available again|again)\s+(?:in|after)\s+((?:\d+(?:\.\d+)?\s*"#
      + durationUnit + #"[\s,]*(?:and\s+)?)+)"#,
    options: [.caseInsensitive]
  )
  private static let durationTokenPattern = try! NSRegularExpression(
    pattern: #"(\d+(?:\.\d+)?)\s*("# + durationUnit + ")",
    options: [.caseInsensitive]
  )
  private static let clockPattern = try! NSRegularExpression(
    pattern: #"(?:try again|resets?|reset|available again)\s+(?:at\s+|on\s+)?"#
      + #"(?:(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s*(\d{4}))?,?\s+(?:at\s+)?)?"#
      + #"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?![\d:])(?:\s*\(([^)]+)\))?"#,
    options: [.caseInsensitive]
  )

  static func durationSeconds(_ span: String) -> Double? {
    let range = NSRange(span.startIndex..., in: span)
    var total = 0.0
    var matched = false
    for match in durationTokenPattern.matches(in: span, range: range) {
      guard let valueRange = Range(match.range(at: 1), in: span),
            let unitRange = Range(match.range(at: 2), in: span),
            let value = Double(span[valueRange])
      else { continue }
      let unit = span[unitRange].lowercased()
      let scale: Double
      if unit == "ms" { scale = 0.001 }
      else if unit.hasPrefix("d") { scale = 86_400 }
      else if unit.hasPrefix("h") { scale = 3_600 }
      else if unit.hasPrefix("m") { scale = 60 }
      else { scale = 1 }
      total += value * scale
      matched = true
    }
    return matched ? total : nil
  }

  private static func clockResetDate(in text: String, now: Date, timeZone defaultTimeZone: TimeZone) -> Date? {
    let range = NSRange(text.startIndex..., in: text)
    for match in clockPattern.matches(in: text, range: range) {
      func capture(_ index: Int) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
      }
      guard var hour = capture(4).flatMap(Int.init) else { continue }
      let minute = capture(5).flatMap(Int.init)
      let meridiem = capture(6)?.lowercased().replacingOccurrences(of: ".", with: "")
      // "resets 5" is too ambiguous to be a clock time.
      guard minute != nil || meridiem != nil else { continue }
      if let meridiem {
        guard (1...12).contains(hour) else { continue }
        if meridiem == "pm", hour != 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
      }
      guard (0...23).contains(hour), (0...59).contains(minute ?? 0) else { continue }
      let zone = capture(7).flatMap(timeZone(named:)) ?? defaultTimeZone
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = zone
      var components = calendar.dateComponents([.year, .month, .day], from: now)
      components.hour = hour
      components.minute = minute ?? 0
      components.second = 0
      if let monthName = capture(1)?.lowercased(),
         let month = monthNames.firstIndex(of: String(monthName.prefix(3))).map({ $0 + 1 }),
         let day = capture(2).flatMap(Int.init) {
        components.month = month
        components.day = day
        let explicitYear = capture(3).flatMap(Int.init)
        if let explicitYear { components.year = explicitYear }
        guard var date = calendar.date(from: components) else { continue }
        if explicitYear == nil, date < now.addingTimeInterval(-86_400),
           let next = calendar.date(byAdding: .year, value: 1, to: date) {
          date = next
        }
        return date
      }
      guard var date = calendar.date(from: components) else { continue }
      if date <= now, let next = calendar.date(byAdding: .day, value: 1, to: date) {
        date = next
      }
      return date
    }
    return nil
  }

  private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

  private static func timeZone(named raw: String) -> TimeZone? {
    let name = raw.trimmingCharacters(in: .whitespaces)
    return TimeZone(identifier: name) ?? TimeZone(abbreviation: name.uppercased())
  }

  /// Epoch seconds or milliseconds, a Go-style duration ("6m0s"), an ISO 8601
  /// timestamp, or an HTTP date. Small bare numbers are seconds from now only
  /// where the format means that (header values such as `Retry-After`).
  static func parseResetValue(_ raw: String, now: Date, smallNumbersAreRelative: Bool) -> Date? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if let number = Double(value) {
      if number >= 1e12 { return Date(timeIntervalSince1970: number / 1_000) }
      if number >= 1e9 { return Date(timeIntervalSince1970: number) }
      return smallNumbersAreRelative && number >= 0 ? now.addingTimeInterval(number) : nil
    }
    if value.range(of: #"^(?:\d+(?:\.\d+)?(?:ms|h|m|s))+$"#, options: .regularExpression) != nil,
       let seconds = durationSeconds(value) {
      return now.addingTimeInterval(seconds)
    }
    if let date = parseISODate(value) { return date }
    return httpDateFormatter.date(from: value)
  }

  private static func parseISODate(_ value: String) -> Date? {
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: value) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value)
  }

  nonisolated(unsafe) private static let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
  }()

  private static func firstCapture(_ pattern: NSRegularExpression, in text: String) -> String? {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = pattern.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          let captured = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[captured])
  }
}
