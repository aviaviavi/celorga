import Foundation

/// Finds the parts of a search result that match the query so result rows can
/// emphasize them. Matching is literal and case- and diacritic-insensitive,
/// one term per whitespace-separated query word.
enum WorkspaceSearchHighlight {
  /// Query words worth emphasizing, longest first so a longer word wins when
  /// two words overlap.
  static func terms(in query: String) -> [String] {
    var seen = Set<String>()
    return query
      .split(whereSeparator: { $0.isWhitespace })
      .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
      .sorted { $0.count > $1.count }
  }

  /// Non-overlapping ranges of `text` that match a query word, in order.
  static func ranges(in text: String, query: String) -> [Range<String.Index>] {
    let terms = terms(in: query)
    guard !terms.isEmpty, !text.isEmpty else { return [] }
    var matches: [Range<String.Index>] = []
    for term in terms {
      var searchStart = text.startIndex
      while searchStart < text.endIndex,
            let range = text.range(
              of: term,
              options: [.caseInsensitive, .diacriticInsensitive],
              range: searchStart..<text.endIndex
            ) {
        if !matches.contains(where: { $0.overlaps(range) }) {
          matches.append(range)
        }
        searchStart = range.upperBound
      }
    }
    return matches.sorted { $0.lowerBound < $1.lowerBound }
  }

  /// The snippet worth showing under a result title, or nil when it only
  /// repeats the title. A matched heading line loses its stars, TODO keyword,
  /// priority cookie, and trailing tags so it reads as prose.
  static func displaySnippet(_ snippet: String, title: String, todo: String? = nil) -> String? {
    var text = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
    if let stars = text.range(of: #"^\*+\s+"#, options: .regularExpression) {
      text.removeSubrange(stars)
      if let todo, !todo.isEmpty, text.hasPrefix(todo + " ") || text == todo {
        text = String(text.dropFirst(todo.count))
          .trimmingCharacters(in: .whitespaces)
      }
      if let priority = text.range(of: #"^\[#[A-Za-z0-9]\]\s*"#, options: .regularExpression) {
        text.removeSubrange(priority)
      }
      if let tags = text.range(of: #"\s+:[^\s:]+(:[^\s:]+)*:\s*$"#, options: .regularExpression) {
        text.removeSubrange(tags)
      }
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.compare(normalizedTitle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
      return nil
    }
    return text
  }

  /// `text` with each query match marked as emphasized.
  static func attributed(_ text: String, query: String) -> AttributedString {
    var attributed = AttributedString(text)
    for range in ranges(in: text, query: query) {
      guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed)
      else { continue }
      attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
    }
    return attributed
  }
}

/// Typing and keyboard behavior for the Search surface's query field.
enum WorkspaceSearchInput {
  /// Text search runs as the user types once the query has this many
  /// characters; Return searches a shorter query immediately.
  static let liveSearchMinimumLength = 2
  /// Pause before a typed text query runs; text search reads the whole corpus.
  static let liveTextSearchDelay: UInt64 = 250_000_000
  /// Node search filters an in-memory index, so it can follow typing closely.
  static let liveNodeSearchDelay: UInt64 = 120_000_000

  /// The result selected after an arrow key. Moving down from no selection
  /// selects the first result, moving up from the first clears the selection
  /// so focus returns to the query, and a vanished selection restarts.
  static func movedSelection(from current: String?, by offset: Int, in ids: [String]) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else {
      return offset > 0 ? ids.first : nil
    }
    let next = index + offset
    if next < 0 { return nil }
    return ids[min(next, ids.count - 1)]
  }
}
