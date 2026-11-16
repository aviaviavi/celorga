import Foundation

/// Converts Org source to readable plain text for pasting outside Celorga.
///
/// Keeps the words a reader sees and drops Org notation: heading stars,
/// TODO keywords, priorities, tags, property and logbook drawers, planning
/// lines, keyword lines (`#+TITLE:` keeps its value), comments, block
/// delimiters, link brackets, and emphasis markers.
public enum OrgPlainText {
  public static func convert(_ source: String, todoKeywords: Set<String> = defaultTodoKeywords) -> String {
    var output: [String] = []
    var inDrawer = false
    var inVerbatimBlock = false

    for rawLine in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
      let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
      let upper = trimmed.uppercased()

      if inVerbatimBlock {
        if upper.hasPrefix("#+END_") {
          inVerbatimBlock = false
        } else {
          output.append(rawLine)
        }
        continue
      }
      if inDrawer {
        if upper == ":END:" { inDrawer = false }
        continue
      }
      if isDrawerStart(trimmed) {
        inDrawer = true
        continue
      }
      if upper.hasPrefix("#+BEGIN_") {
        let kind = upper.dropFirst("#+BEGIN_".count).prefix { !$0.isWhitespace }
        if ["SRC", "EXAMPLE", "EXPORT", "VERSE"].contains(String(kind)) {
          inVerbatimBlock = true
        }
        continue
      }
      if upper.hasPrefix("#+END_") { continue }
      if trimmed.hasPrefix("#+") {
        if upper.hasPrefix("#+TITLE:") {
          let value = trimmed.dropFirst("#+TITLE:".count).trimmingCharacters(in: .whitespaces)
          if !value.isEmpty { output.append(inline(value)) }
        }
        continue
      }
      if trimmed == "#" || trimmed.hasPrefix("# ") { continue }
      if isPlanningLine(upper) { continue }

      if let title = headingTitle(rawLine, todoKeywords: todoKeywords) {
        output.append(inline(title))
        continue
      }
      output.append(inline(rawLine))
    }

    return collapseBlankLines(output)
  }

  public static var defaultTodoKeywords: Set<String> {
    WorkspaceStore.allHeadingTodoKeywords
  }

  // MARK: Lines

  private static func isDrawerStart(_ trimmed: String) -> Bool {
    guard trimmed.count > 2, trimmed.hasPrefix(":"), trimmed.hasSuffix(":") else { return false }
    let name = trimmed.dropFirst().dropLast()
    guard name.uppercased() != "END" else { return false }
    return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
  }

  private static func isPlanningLine(_ upper: String) -> Bool {
    ["SCHEDULED:", "DEADLINE:", "CLOSED:"].contains { upper.hasPrefix($0) }
  }

  /// The visible title of a heading line, or nil when the line is not a heading.
  static func headingTitle(_ line: String, todoKeywords: Set<String>) -> String? {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty, line.dropFirst(stars.count).first == " " else { return nil }
    var words = line.dropFirst(stars.count).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if let first = words.first, todoKeywords.contains(first) { words.removeFirst() }
    if let first = words.first, first.count == 4, first.hasPrefix("[#"), first.hasSuffix("]") {
      words.removeFirst()
    }
    if let last = words.last, last.count > 2, last.hasPrefix(":"), last.hasSuffix(":"),
       !last.contains(" ") {
      words.removeLast()
    }
    return words.joined(separator: " ")
  }

  private static func collapseBlankLines(_ lines: [String]) -> String {
    var result: [String] = []
    for line in lines {
      let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
      if isBlank {
        if result.isEmpty || result.last?.isEmpty == true { continue }
        result.append("")
      } else {
        result.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
      }
    }
    while result.last?.isEmpty == true { result.removeLast() }
    return result.isEmpty ? "" : result.joined(separator: "\n") + "\n"
  }

  // MARK: Inline

  static func inline(_ text: String) -> String {
    var text = replaceLinks(in: text)
    text = stripEmphasis(in: text)
    // Statistics cookies such as [2/3] or [50%] in headings and lists.
    text = text.replacingOccurrences(
      of: #"\s*\[(\d+/\d+|\d+%)\]"#,
      with: "",
      options: .regularExpression
    )
    return text
  }

  private static let linkPattern = try! NSRegularExpression(
    pattern: #"\[\[([^\]]+)\](?:\[([^\]]*)\])?\]"#
  )

  private static func replaceLinks(in text: String) -> String {
    let ns = text as NSString
    var result = ""
    var cursor = 0
    for match in linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      let target = ns.substring(with: match.range(at: 1))
      if match.range(at: 2).location != NSNotFound,
         case let label = ns.substring(with: match.range(at: 2)),
         !label.isEmpty {
        result += label
      } else {
        result += bareLinkText(target)
      }
      cursor = match.range.location + match.range.length
    }
    result += ns.substring(from: cursor)
    return result
  }

  private static func bareLinkText(_ target: String) -> String {
    for prefix in ["file:", "id:"] where target.lowercased().hasPrefix(prefix) {
      let value = String(target.dropFirst(prefix.count))
      return value.components(separatedBy: "::").first ?? value
    }
    return target
  }

  private static let emphasisPattern = try! NSRegularExpression(
    pattern: #"(^|[\s\-({'"])([*/=~+_])([^\s*/=~+_](?:.*?[^\s])?)\2(?=$|[\s\-.,:;!?'")}\]])"#,
    options: [.anchorsMatchLines]
  )

  private static func stripEmphasis(in text: String) -> String {
    var current = text
    // Emphasis does not nest in Celorga's Org profile, but repeat once so
    // adjacent spans that share a boundary character are both removed.
    for _ in 0..<2 {
      let ns = current as NSString
      let next = emphasisPattern.stringByReplacingMatches(
        in: current,
        range: NSRange(location: 0, length: ns.length),
        withTemplate: "$1$3"
      )
      if next == current { break }
      current = next
    }
    return current
  }
}
