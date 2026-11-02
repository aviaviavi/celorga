import Foundation

/// A drag-and-drop move of one outline entry in the rendered document: a
/// heading with its whole subtree, or a plain list item with its nested items.
///
/// Line numbers are 1-based and address the text the request is applied to.
/// The rendered page supplies them from the parser's source ranges, so the
/// caller must apply a request only to the exact text that was rendered.
public struct OrgOutlineMoveRequest: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case heading
    case listItem
  }

  public enum ListRelation: String, Sendable {
    /// Take the reference item's indentation and bullet style.
    case sibling
    /// Become a nested item of the reference item.
    case child
  }

  public var kind: Kind
  /// First line of the moved entry.
  public var startLine: Int
  /// Last line of the moved entry, inclusive (its subtree or nested items).
  public var endLine: Int
  /// The moved entry is inserted before this line of the original text.
  /// One past the last line inserts at the end.
  public var targetLine: Int
  /// Heading moves: the new level of the moved heading.
  public var level: Int?
  /// Heading moves: every heading line inside the moved range, including
  /// `startLine`. Only these lines change level, so a line inside a source
  /// block that happens to start with `*` is left alone.
  public var headingLines: [Int]
  /// List moves: the item whose indentation (and bullet) the moved item takes.
  public var referenceLine: Int?
  public var relation: ListRelation?
  /// List moves: the first and last line of the whole list, so ordered
  /// items can be renumbered after the move.
  public var listStartLine: Int?
  public var listEndLine: Int?

  public init(
    kind: Kind,
    startLine: Int,
    endLine: Int,
    targetLine: Int,
    level: Int? = nil,
    headingLines: [Int] = [],
    referenceLine: Int? = nil,
    relation: ListRelation? = nil,
    listStartLine: Int? = nil,
    listEndLine: Int? = nil
  ) {
    self.kind = kind
    self.startLine = startLine
    self.endLine = endLine
    self.targetLine = targetLine
    self.level = level
    self.headingLines = headingLines
    self.referenceLine = referenceLine
    self.relation = relation
    self.listStartLine = listStartLine
    self.listEndLine = listEndLine
  }

  /// Decodes the payload posted by the rendered page.
  public init?(_ body: Any) {
    guard let payload = body as? [String: Any],
          let kind = (payload["kind"] as? String).flatMap(Kind.init(rawValue:)),
          let startLine = Self.int(payload["startLine"]),
          let endLine = Self.int(payload["endLine"]),
          let targetLine = Self.int(payload["targetLine"])
    else { return nil }
    self.init(
      kind: kind,
      startLine: startLine,
      endLine: endLine,
      targetLine: targetLine,
      level: Self.int(payload["level"]),
      headingLines: (payload["headingLines"] as? [Any])?.compactMap(Self.int) ?? [],
      referenceLine: Self.int(payload["referenceLine"]),
      relation: (payload["relation"] as? String).flatMap(ListRelation.init(rawValue:)),
      listStartLine: Self.int(payload["listStartLine"]),
      listEndLine: Self.int(payload["listEndLine"])
    )
  }

  private static func int(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
  }

  /// The same request with every line number shifted by `offset`.
  public func offsettingLines(by offset: Int) -> OrgOutlineMoveRequest {
    var copy = self
    copy.startLine += offset
    copy.endLine += offset
    copy.targetLine += offset
    copy.headingLines = headingLines.map { $0 + offset }
    copy.referenceLine = referenceLine.map { $0 + offset }
    copy.listStartLine = listStartLine.map { $0 + offset }
    copy.listEndLine = listEndLine.map { $0 + offset }
    return copy
  }
}

public enum OrgOutlineMoveError: Error, Equatable, LocalizedError {
  case invalidRange
  case notAHeading(line: Int)
  case notAListItem(line: Int)
  case invalidLevel
  case targetInsideMovedEntry
  case missingReference
  case unchanged

  public var errorDescription: String? {
    switch self {
    case .invalidRange:
      return "The dragged entry no longer matches the document."
    case .notAHeading(let line):
      return "Line \(line) is no longer a heading."
    case .notAListItem(let line):
      return "Line \(line) is no longer a list item."
    case .invalidLevel:
      return "That heading level is not allowed here."
    case .targetInsideMovedEntry:
      return "An entry cannot be moved inside itself."
    case .missingReference:
      return "The list item to align with is missing."
    case .unchanged:
      return "The entry is already there."
    }
  }
}

public enum OrgOutlineMove {
  /// Applies `request` to `text` and returns the new text. The line count
  /// never changes: the moved lines are only re-leveled, re-indented and
  /// relocated.
  public static func apply(_ request: OrgOutlineMoveRequest, to text: String) throws -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let start = request.startLine - 1
    let end = request.endLine - 1
    guard start >= 0, end >= start, end < lines.count,
          request.targetLine >= 1, request.targetLine <= lines.count + 1
    else { throw OrgOutlineMoveError.invalidRange }
    if request.targetLine > request.startLine && request.targetLine <= request.endLine {
      throw OrgOutlineMoveError.targetInsideMovedEntry
    }
    let staysInPlace = request.targetLine == request.startLine || request.targetLine == request.endLine + 1

    var moved = Array(lines[start...end])
    switch request.kind {
    case .heading:
      guard let currentLevel = headingLevel(moved[0]) else {
        throw OrgOutlineMoveError.notAHeading(line: request.startLine)
      }
      guard let level = request.level, level >= 1 else { throw OrgOutlineMoveError.invalidLevel }
      let delta = level - currentLevel
      if delta == 0 && staysInPlace { throw OrgOutlineMoveError.unchanged }
      if delta != 0 {
        var headingLines = Set(request.headingLines)
        headingLines.insert(request.startLine)
        for line in headingLines.sorted() {
          guard line >= request.startLine, line <= request.endLine else {
            throw OrgOutlineMoveError.invalidRange
          }
          let index = line - request.startLine
          guard let lineLevel = headingLevel(moved[index]) else {
            throw OrgOutlineMoveError.notAHeading(line: line)
          }
          let newLevel = lineLevel + delta
          guard newLevel >= 1 else { throw OrgOutlineMoveError.invalidLevel }
          moved[index] = String(repeating: "*", count: newLevel) + moved[index].dropFirst(lineLevel)
        }
      }
    case .listItem:
      guard let item = listItem(moved[0]) else {
        throw OrgOutlineMoveError.notAListItem(line: request.startLine)
      }
      guard let referenceLine = request.referenceLine,
            let relation = request.relation,
            referenceLine >= 1, referenceLine <= lines.count,
            referenceLine < request.startLine || referenceLine > request.endLine
      else { throw OrgOutlineMoveError.missingReference }
      guard let reference = listItem(lines[referenceLine - 1]) else {
        throw OrgOutlineMoveError.notAListItem(line: referenceLine)
      }
      let newIndent: Int
      var newBullet = item.bullet
      switch relation {
      case .sibling:
        newIndent = reference.indent
        newBullet = bullet(adopting: reference.bullet, from: item.bullet)
      case .child:
        newIndent = reference.indent + reference.bullet.count + 1
      }
      // A star bullet in the first column would turn the item into a heading.
      if newIndent == 0 && newBullet == "*" { newBullet = "-" }
      let delta = newIndent - item.indent
      if delta == 0 && newBullet == item.bullet && staysInPlace { throw OrgOutlineMoveError.unchanged }
      moved = moved.map { shiftIndentation($0, by: delta) }
      if newBullet != item.bullet {
        let first = moved[0]
        let bulletStart = first.index(first.startIndex, offsetBy: newIndent)
        let bulletEnd = first.index(bulletStart, offsetBy: item.bullet.count)
        moved[0] = String(first[..<bulletStart]) + newBullet + String(first[bulletEnd...])
      }
    }

    lines.removeSubrange(start...end)
    let insertion = request.targetLine <= request.startLine
      ? request.targetLine - 1
      : request.targetLine - 1 - moved.count
    lines.insert(contentsOf: moved, at: insertion)

    if request.kind == .listItem,
       let listStart = request.listStartLine,
       let listEnd = request.listEndLine,
       listStart >= 1, listEnd >= listStart, listEnd <= lines.count {
      renumberOrderedLists(in: &lines, range: (listStart - 1)...(listEnd - 1))
    }
    return lines.joined(separator: "\n")
  }

  // MARK: Line syntax

  static func headingLevel(_ line: String) -> Int? {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return nil }
    let rest = line.dropFirst(stars.count)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    return stars.count
  }

  struct ListItemSyntax: Equatable {
    var indent: Int
    var bullet: String
    var ordinal: Int?
  }

  static func listItem(_ line: String) -> ListItemSyntax? {
    let indent = line.prefix { $0 == " " }.count
    let rest = line.dropFirst(indent)
    guard let first = rest.first else { return nil }
    var bullet = ""
    var ordinal: Int?
    if first == "-" || first == "+" || first == "*" {
      if first == "*" && indent == 0 { return nil }
      bullet = String(first)
    } else if first.isASCII, first.isNumber {
      let digits = rest.prefix { $0.isASCII && $0.isNumber }
      let afterDigits = rest.dropFirst(digits.count)
      guard digits.count <= 9, let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else {
        return nil
      }
      bullet = String(digits) + String(delimiter)
      ordinal = Int(digits)
    } else {
      return nil
    }
    let after = rest.dropFirst(bullet.count)
    guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
    return ListItemSyntax(indent: indent, bullet: bullet, ordinal: ordinal)
  }

  /// The moved item's bullet once it joins a list whose items use
  /// `reference`: unordered lists take the reference character, and ordered
  /// lists keep the moved number (renumbered later) with the reference
  /// delimiter.
  static func bullet(adopting reference: String, from moved: String) -> String {
    let referenceOrdered = reference.first?.isNumber == true
    let movedOrdered = moved.first?.isNumber == true
    switch (referenceOrdered, movedOrdered) {
    case (false, _):
      return reference
    case (true, true):
      return String(moved.dropLast()) + String(reference.last ?? ".")
    case (true, false):
      return "1" + String(reference.last ?? ".")
    }
  }

  static func shiftIndentation(_ line: String, by delta: Int) -> String {
    guard delta != 0, !line.allSatisfy({ $0 == " " || $0 == "\t" }) else { return line }
    if delta > 0 { return String(repeating: " ", count: delta) + line }
    let removable = min(-delta, line.prefix { $0 == " " }.count)
    return String(line.dropFirst(removable))
  }

  /// Renumbers each run of ordered sibling items in `range` from its lowest
  /// number, so a reordered `1. 2. 3.` list still reads `1. 2. 3.`. Runs that
  /// use an explicit `[@N]` counter are left alone.
  static func renumberOrderedLists(in lines: inout [String], range: ClosedRange<Int>) {
    struct Group {
      var indent: Int
      var ordered: Bool
      var lineIndices: [Int]
    }
    var stack: [Group] = []
    var insideBlock = false

    func finish(_ group: Group) {
      guard group.ordered, group.lineIndices.count > 1 else { return }
      guard !group.lineIndices.contains(where: { lines[$0].contains("[@") }) else { return }
      let numbers = group.lineIndices.compactMap { listItem(lines[$0])?.ordinal }
      guard let first = numbers.min() else { return }
      for (offset, index) in group.lineIndices.enumerated() {
        guard let item = listItem(lines[index]) else { continue }
        let line = lines[index]
        let digitsStart = line.index(line.startIndex, offsetBy: item.indent)
        let digitsEnd = line.index(digitsStart, offsetBy: item.bullet.count - 1)
        lines[index] = String(line[..<digitsStart]) + String(first + offset) + String(line[digitsEnd...])
      }
    }

    for index in range where index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      let lowered = trimmed.lowercased()
      if insideBlock {
        if lowered.hasPrefix("#+end_") { insideBlock = false }
        continue
      }
      if lowered.hasPrefix("#+begin_") {
        insideBlock = true
        continue
      }
      let indent = line.prefix { $0 == " " }.count
      if let item = listItem(line) {
        while let top = stack.last, top.indent > item.indent {
          finish(stack.removeLast())
        }
        let ordered = item.ordinal != nil
        if let top = stack.last, top.indent == item.indent {
          if top.ordered == ordered {
            stack[stack.count - 1].lineIndices.append(index)
            continue
          }
          finish(stack.removeLast())
        }
        stack.append(Group(indent: item.indent, ordered: ordered, lineIndices: [index]))
      } else {
        while let top = stack.last, top.indent >= indent {
          finish(stack.removeLast())
        }
      }
    }
    while let group = stack.popLast() {
      finish(group)
    }
  }
}
