import Foundation

/// A normalized workspace search query with fast literal matching.
///
/// Matching is literal and case-insensitive, like `celorga search`. A
/// multi-word query also matches text that contains every word, scored below
/// an exact phrase. ASCII queries scan UTF-8 bytes directly so a search over
/// large chat transcripts does not walk grapheme clusters.
struct WorkspaceSearchQuery: Sendable {
  let phrase: String
  let terms: [String]
  private let asciiPhrase: [UInt8]?
  private let asciiTerms: [[UInt8]]?

  init?(_ raw: String) {
    let terms = raw
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !terms.isEmpty else { return nil }
    let phrase = terms.joined(separator: " ")
    self.phrase = phrase
    self.terms = terms
    let isASCII = phrase.utf8.allSatisfy { $0 < 0x80 }
    asciiPhrase = isASCII ? Array(phrase.utf8) : nil
    asciiTerms = isASCII ? terms.map { Array($0.utf8) } : nil
  }

  enum Match: Int, Comparable, Sendable {
    case allTerms = 1
    case phrase = 2

    static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  func match(_ text: String) -> Match? {
    guard !text.isEmpty else { return nil }
    if contains(text, phrase, ascii: asciiPhrase) { return .phrase }
    guard terms.count > 1 else { return nil }
    for (index, term) in terms.enumerated()
    where !contains(text, term, ascii: asciiTerms?[index]) {
      return nil
    }
    return .allTerms
  }

  /// The quality of a match against a short title-like field, or nil when
  /// the field does not match.
  func titleQuality(_ rawTitle: String) -> Double? {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let match = match(title) else { return nil }
    guard match == .phrase else { return WorkspaceSearchRanking.titleAllTermsQuality }
    if title == phrase { return WorkspaceSearchRanking.exactTitleQuality }
    if Self.hasWordBoundaryMatch(title, phrase) { return WorkspaceSearchRanking.wordTitleQuality }
    return WorkspaceSearchRanking.substringTitleQuality
  }

  /// The quality of a match against body text, or nil when it does not match.
  func bodyQuality(_ text: String) -> Double? {
    switch match(text) {
    case .phrase: WorkspaceSearchRanking.bodyPhraseQuality
    case .allTerms: WorkspaceSearchRanking.bodyAllTermsQuality
    case nil: nil
    }
  }

  private func contains(_ text: String, _ needle: String, ascii: [UInt8]?) -> Bool {
    guard let ascii else {
      return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    var text = text
    return text.withUTF8 { Self.asciiCaseInsensitiveContains($0, ascii) }
  }

  /// `needle` must be lowercase ASCII. Bytes of multi-byte UTF-8 sequences
  /// are always >= 0x80 and therefore never match an ASCII needle byte.
  static func asciiCaseInsensitiveContains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
    let needleCount = needle.count
    guard needleCount > 0 else { return true }
    guard haystack.count >= needleCount else { return false }
    let first = needle[0]
    let firstUpper = (first >= 0x61 && first <= 0x7A) ? first - 0x20 : first
    let last = haystack.count - needleCount
    var index = 0
    while index <= last {
      let byte = haystack[index]
      if byte == first || byte == firstUpper {
        var offset = 1
        while offset < needleCount {
          var candidate = haystack[index + offset]
          if candidate >= 0x41 && candidate <= 0x5A { candidate += 0x20 }
          if candidate != needle[offset] { break }
          offset += 1
        }
        if offset == needleCount { return true }
      }
      index += 1
    }
    return false
  }

  static func hasWordBoundaryMatch(_ text: String, _ needle: String) -> Bool {
    var searchStart = text.startIndex
    while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
      if range.lowerBound == text.startIndex { return true }
      let previous = text[text.index(before: range.lowerBound)]
      if !previous.isLetter && !previous.isNumber { return true }
      searchStart = text.index(after: range.lowerBound)
    }
    return false
  }
}

/// One ranking for every kind of workspace search result: match quality plus a
/// strong recency bias, so the best result leads regardless of its type.
///
/// Keep the weights aligned with `celorga search --sort best`, which selects
/// the corpus candidates this ranking merges with chats, files, and pages.
enum WorkspaceSearchRanking {
  static let exactTitleQuality = 50.0
  static let wordTitleQuality = 35.0
  static let substringTitleQuality = 30.0
  static let titleAllTermsQuality = 22.0
  static let bodyPhraseQuality = 10.0
  static let bodyAllTermsQuality = 6.0
  static let pathOnlyQuality = 15.0
  static let aliasPenalty = 5.0
  static let nonHeadingLinePenalty = 5.0
  static let activeTodoBonus = 10.0
  static let terminalTodoPenalty = 5.0

  /// The boost for something that happened just now. It halves every
  /// `recencyHalfLifeDays`, so a passing mention today outranks an exact
  /// title match from a few months ago.
  static let recencyWeight = 60.0
  static let recencyHalfLifeDays = 30.0
  /// A file modification time is weaker evidence than a date written in the
  /// note or a message timestamp: catch-all files change often while the
  /// matching text may be old.
  static let modifiedTimeRecencyFactor = 0.5

  static func recencyBoost(_ date: Date?, now: Date, factor: Double = 1) -> Double {
    guard let date else { return 0 }
    let ageDays = max(0, now.timeIntervalSince(date)) / 86_400
    return recencyWeight * factor * pow(0.5, ageDays / recencyHalfLifeDays)
  }

  /// Parses a leading `YYYY-MM-DD` as local noon, matching the CLI.
  static func dayDate(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let bytes = Array(raw.utf8.prefix(10))
    guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return nil }
    func number(_ range: Range<Int>) -> Int? {
      var value = 0
      for byte in bytes[range] {
        guard byte >= 0x30 && byte <= 0x39 else { return nil }
        value = value * 10 + Int(byte - 0x30)
      }
      return value
    }
    guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
          (1...12).contains(month), (1...31).contains(day)
    else { return nil }
    return Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
  }

  static func isoDate(_ raw: String?) -> Date? {
    guard let raw, !raw.isEmpty else { return nil }
    return fractionalISOFormatter.date(from: raw) ?? plainISOFormatter.date(from: raw)
  }

  nonisolated(unsafe) private static let fractionalISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  nonisolated(unsafe) private static let plainISOFormatter = ISO8601DateFormatter()

  /// Visible heading text without hidden link targets such as URLs.
  static func visibleHeadingText(_ heading: String) -> String {
    guard heading.contains("[[") else { return heading }
    return heading
      .replacingOccurrences(of: #"\[\[[^\]]*\]\[([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
  }

  static func corpusResultQuality(_ result: SearchResult, query: WorkspaceSearchQuery?) -> Double {
    var quality = bodyPhraseQuality
    if let query,
       let heading = result.heading,
       let headingQuality = query.titleQuality(visibleHeadingText(heading)) {
      quality = headingQuality
      if result.headingLine != result.line { quality -= nonHeadingLinePenalty }
    }
    if result.isActiveTodo { quality += activeTodoBonus }
    if result.isTerminalTodo { quality -= terminalTodoPenalty }
    return quality
  }

  static func corpusResultRecency(
    _ result: SearchResult,
    modifiedAt: Date?,
    now: Date
  ) -> (date: Date?, boost: Double) {
    if let written = dayDate(result.date) {
      return (written, recencyBoost(written, now: now))
    }
    return (modifiedAt, recencyBoost(modifiedAt, now: now, factor: modifiedTimeRecencyFactor))
  }

  static func fileQuality(_ file: CorpusFile, query: WorkspaceSearchQuery) -> Double? {
    let stem = (file.name as NSString).deletingPathExtension
    if let quality = query.titleQuality(stem) ?? query.titleQuality(file.name) {
      return quality
    }
    return query.match(file.relativePath) == nil ? nil : pathOnlyQuality
  }

  static func fileRecency(_ file: CorpusFile, now: Date) -> (date: Date?, boost: Double) {
    if let written = dayDate(file.name) {
      return (written, recencyBoost(written, now: now))
    }
    return (
      file.modifiedAt,
      recencyBoost(file.modifiedAt, now: now, factor: modifiedTimeRecencyFactor)
    )
  }

  static func pageQuality(_ node: OrgRoamNodeReference, query: WorkspaceSearchQuery) -> Double? {
    if let quality = query.titleQuality(node.title) { return quality }
    let aliasQuality = node.aliases.compactMap(query.titleQuality).max()
    return aliasQuality.map { $0 - aliasPenalty }
  }
}

/// Visible chat message text kept in memory for workspace search.
struct AIChatSearchMessage: Sendable {
  let id: UUID
  let createdAt: Date
  let text: String
}

struct AIChatSearchDocument: Sendable {
  let thread: AIChatThread
  let messages: [AIChatSearchMessage]
}

/// Caches the visible text of every chat thread so a workspace search reads
/// and decodes only threads that changed since the previous search, instead of
/// every transcript shard on every query.
final class AIChatSearchIndex: @unchecked Sendable {
  static let shared = AIChatSearchIndex()

  private struct Signature: Equatable {
    let updatedAt: Date
    let messageCount: Int
    let lastMessageID: UUID?
    let lastMessageLength: Int

    init(_ thread: AIChatThread) {
      updatedAt = thread.updatedAt
      messageCount = thread.messageCount
      lastMessageID = thread.messages.last?.id
      lastMessageLength = thread.messages.last?.content.utf8.count ?? 0
    }
  }

  private struct Entry {
    let signature: Signature
    let messages: [AIChatSearchMessage]
  }

  private let lock = NSLock()
  private var entriesByTranscript: [String: [UUID: Entry]] = [:]

  /// Returns a searchable document for every thread in `metadata`. `load`
  /// supplies the complete thread when only metadata is in memory.
  func documents(
    for metadata: [AIChatThread],
    transcriptURL: URL,
    load: (AIChatThread) -> AIChatThread?
  ) -> [AIChatSearchDocument] {
    let key = transcriptURL.standardizedFileURL.path
    // Held for the whole refresh so a warm-up and a search that overlap share
    // one transcript read instead of decoding every changed thread twice.
    lock.lock()
    defer { lock.unlock() }
    let cached = entriesByTranscript[key] ?? [:]

    var next: [UUID: Entry] = [:]
    next.reserveCapacity(metadata.count)
    var documents: [AIChatSearchDocument] = []
    documents.reserveCapacity(metadata.count)
    for thread in metadata {
      let signature = Signature(thread)
      let entry: Entry
      if let existing = cached[thread.id], existing.signature == signature {
        entry = existing
      } else {
        let complete = thread.storedMessageCount == nil ? thread : (load(thread) ?? thread)
        entry = Entry(signature: signature, messages: Self.searchMessages(complete))
      }
      next[thread.id] = entry
      documents.append(AIChatSearchDocument(thread: thread, messages: entry.messages))
    }

    entriesByTranscript[key] = next
    return documents
  }

  static func searchMessages(_ thread: AIChatThread) -> [AIChatSearchMessage] {
    thread.messages.compactMap { message in
      guard !message.isRoomDispatchCopy else { return nil }
      let text = WorkspaceStore.visibleAIChatMessageText(message)
      guard !text.isEmpty else { return nil }
      return AIChatSearchMessage(id: message.id, createdAt: message.createdAt, text: text)
    }
  }

  func removeAllForTesting() {
    lock.lock()
    entriesByTranscript.removeAll()
    lock.unlock()
  }
}
