import Foundation

/// Org link search options (`file:PATH::SEARCH`, and since Org 10 `id:ID::SEARCH`).
///
/// This mirrors `src/linkSearch.ts`, which defines the semantics: a number is
/// a 1-based file line; `*Heading` matches a heading title; `#custom-id`
/// matches a `:CUSTOM_ID:` line; plain text matches `<<text>>`, then
/// `#+NAME:`, then a heading title, then the first line containing the text.
/// Matching is case-insensitive. ID searches look inside the ID's subtree
/// first and then the rest of its file.
public enum OrgLinkSearchOption {
  public struct IDTarget: Equatable, Sendable {
    public let id: String
    public let search: String?
  }

  /// Splits `id:ID` or `id:ID::SEARCH`; nil for any other target.
  public static func parseIDTarget(_ raw: String) -> IDTarget? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.lowercased().hasPrefix("id:") else { return nil }
    let body = String(value.dropFirst(3))
    let id: String
    let search: String
    if let separator = body.range(of: "::") {
      id = String(body[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      search = String(body[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      id = body.trimmingCharacters(in: .whitespacesAndNewlines)
      search = ""
    }
    guard !id.isEmpty else { return nil }
    return IDTarget(id: id, search: search.isEmpty ? nil : search)
  }

  /// True when resolving `target` needs the linked file's text, not just the node index.
  public static func idTargetNeedsFileSearch(_ target: String) -> Bool {
    guard let search = parseIDTarget(target)?.search else { return false }
    return Int(search) == nil
  }

  /// 1-based line for `search` in `source`, or nil when nothing matches.
  /// `scope` (1-based, inclusive) is searched before the whole file.
  public static func line(
    for rawSearch: String,
    in source: String,
    scope: ClosedRange<Int>? = nil
  ) -> Int? {
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    return line(for: rawSearch, lines: lines, scope: scope)
  }

  static func line(for rawSearch: String, lines: [String], scope: ClosedRange<Int>?) -> Int? {
    let search = rawSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !search.isEmpty, !lines.isEmpty else { return nil }

    if search.allSatisfy(\.isASCII), search.allSatisfy(\.isNumber), let number = Int(search) {
      guard number >= 1 else { return nil }
      return min(number, lines.count)
    }

    let whole = 1...lines.count
    let ranges = [scope.map { $0.clamped(to: whole) }, whole].compactMap { $0 }
    func first(_ matches: (String, Bool) -> Bool) -> Int? {
      for range in ranges {
        var inBlock = false
        for number in range {
          let line = lines[number - 1]
          let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
          if trimmed.hasPrefix("#+begin_") { inBlock = true; continue }
          if trimmed.hasPrefix("#+end_") { inBlock = false; continue }
          if matches(line, inBlock) { return number }
        }
      }
      return nil
    }

    if search.hasPrefix("*") {
      let wanted = normalized(search.replacingOccurrences(of: #"^\*+\s*"#, with: "", options: .regularExpression))
      guard !wanted.isEmpty else { return nil }
      return first { line, _ in headingMatches(line, wanted) }
    }

    if search.hasPrefix("#") {
      let wanted = String(search.dropFirst()).trimmingCharacters(in: .whitespaces).lowercased()
      guard !wanted.isEmpty else { return nil }
      return first { line, _ in propertyValue("CUSTOM_ID", in: line)?.lowercased() == wanted }
    }

    let wanted = normalized(search)
    if let target = first({ line, inBlock in
      !inBlock && dedicatedTargets(in: line).contains(wanted)
    }) {
      return target
    }
    if let name = first({ line, _ in
      guard let match = line.range(of: #"^\s*#\+[Nn][Aa][Mm][Ee]:"#, options: .regularExpression) else { return false }
      return normalized(String(line[match.upperBound...])) == wanted
    }) {
      return name
    }
    if let heading = first({ line, _ in headingMatches(line, wanted) }) {
      return heading
    }
    let lowered = search.lowercased()
    return first { line, _ in line.lowercased().contains(lowered) }
  }

  /// The heading line that owns `id` and its subtree, or line 1 and the whole
  /// file for a file-level ID.
  static func owner(of rawID: String, lines: [String]) -> (line: Int, scope: ClosedRange<Int>)? {
    let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !id.isEmpty, !lines.isEmpty else { return nil }
    for (index, line) in lines.enumerated() {
      let isProperty = propertyValue("ID", in: line)?.lowercased() == id
      let isKeyword = !isProperty && keywordValue("ID", in: line)?.lowercased() == id
      guard isProperty || isKeyword else { continue }
      guard let heading = (0..<index).reversed().first(where: { headingLevel(lines[$0]) > 0 }) else {
        return (1, 1...lines.count)
      }
      if isKeyword { continue }
      return (heading + 1, subtree(startingAt: heading + 1, lines: lines))
    }
    return nil
  }

  /// 1-based line for `id:ID::SEARCH` inside `source`, the file that contains ID.
  public static func line(forIDTarget target: IDTarget, in source: String) -> Int? {
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    guard let owner = owner(of: target.id, lines: lines) else { return nil }
    guard let search = target.search else { return owner.line }
    return line(for: search, lines: lines, scope: owner.scope)
  }

  static func subtree(startingAt headingLine: Int, lines: [String]) -> ClosedRange<Int> {
    let level = headingLevel(lines[headingLine - 1])
    var end = lines.count
    if headingLine < lines.count {
      for number in (headingLine + 1)...lines.count {
        let other = headingLevel(lines[number - 1])
        if other > 0, other <= level { end = number - 1; break }
      }
    }
    return headingLine...max(headingLine, end)
  }

  private static func headingLevel(_ line: String) -> Int {
    let stars = line.prefix { $0 == "*" }.count
    guard stars > 0, line.dropFirst(stars).first == " " || line.dropFirst(stars).first == "\t" else { return 0 }
    return stars
  }

  /// Mirrors `headingMatches` in `src/linkSearch.ts`: tags, an optional
  /// priority and statistics cookies are ignored, and a leading upper-case
  /// word may be a TODO keyword from any workflow.
  private static func headingMatches(_ line: String, _ wanted: String) -> Bool {
    guard headingLevel(line) > 0 else { return false }
    let base = line.trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: #"^\*+\s+"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\s+:[^\s:]+(?::[^\s:]+)*:\s*$"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    var candidates = [base]
    if let keyword = base.range(of: #"^[A-Z][A-Z0-9_-]*\s+"#, options: .regularExpression),
       keyword.upperBound < base.endIndex {
      candidates.append(String(base[keyword.upperBound...]))
    }
    return candidates.contains { candidate in
      normalized(candidate.replacingOccurrences(of: #"^\[#[A-Za-z0-9]\]\s+"#, with: "", options: .regularExpression)) == wanted
    }
  }

  private static func normalized(_ value: String) -> String {
    value
      .replacingOccurrences(of: #"\[\d*/\d*\]|\[\d*%\]"#, with: " ", options: .regularExpression)
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
  }

  private static func dedicatedTargets(in line: String) -> [String] {
    guard line.contains("<<") else { return [] }
    let ns = line as NSString
    guard let regex = try? NSRegularExpression(pattern: #"<<<?([^<>\n]+?)>>>?"#) else { return [] }
    return regex.matches(in: line, range: NSRange(location: 0, length: ns.length)).map {
      normalized(ns.substring(with: $0.range(at: 1)))
    }
  }

  private static func propertyValue(_ key: String, in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let prefix = ":\(key):"
    guard trimmed.uppercased().hasPrefix(prefix) else { return nil }
    let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    return value.isEmpty || value.contains(" ") ? nil : value
  }

  private static func keywordValue(_ key: String, in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let prefix = "#+\(key):"
    guard trimmed.uppercased().hasPrefix(prefix) else { return nil }
    let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    return value.isEmpty || value.contains(" ") ? nil : value
  }
}
