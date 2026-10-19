import AppKit
import SwiftUI

struct OrgSyntaxTextEditorSubmitContext {
  let text: String
  let selectedRange: NSRange
}

struct OrgSyntaxTextEditReplacement: Equatable {
  let range: NSRange
  let replacement: String
  let selectedRange: NSRange?

  init(range: NSRange, replacement: String, selectedRange: NSRange? = nil) {
    self.range = range
    self.replacement = replacement
    self.selectedRange = selectedRange
  }

  var selectedRangeAfterReplacement: NSRange {
    if let selectedRange {
      return selectedRange
    }
    return NSRange(location: range.location + (replacement as NSString).length, length: 0)
  }
}

enum OrgSourceTextIndentDirection {
  case indent
  case outdent
}

enum OrgSyntaxTextCheckingMode: Equatable, Sendable {
  case disabled
  case spellingAndGrammar
}

public enum OrgSourceEditorCommand: Equatable, Sendable {
  case insertHeading
  case insertListItem
  case promote
  case demote
  case cycleTodo
  case setPriority(String?)
  case scheduleToday
  case deadlineToday
  case clearPlanning
  case insertProperty
  case insertLink
  case toggleFold
  case unfoldAll
  case previousHeading
  case nextHeading
}

public struct OrgSourceEditorCommandRequest: Equatable, Sendable {
  public let id: Int
  public let command: OrgSourceEditorCommand

  public init(id: Int, command: OrgSourceEditorCommand) {
    self.id = id
    self.command = command
  }
}

enum OrgSourceTextEditing {
  static func newlineReplacement(
    in text: String,
    selectedRange: NSRange
  ) -> OrgSyntaxTextEditReplacement? {
    newlineReplacement(in: text as NSString, selectedRange: selectedRange)
  }

  static func newlineReplacement(
    in nsText: NSString,
    selectedRange: NSRange
  ) -> OrgSyntaxTextEditReplacement? {
    let selectedRange = clampedRange(selectedRange, utf16Length: nsText.length)
    let lineContext = lineContext(in: nsText, selectedRange: selectedRange)
    guard let continuation = listContinuation(for: lineContext.textBeforeSelection)
      ?? indentationContinuation(for: lineContext.textBeforeSelection)
    else {
      return nil
    }
    return OrgSyntaxTextEditReplacement(
      range: selectedRange,
      replacement: "\n" + continuation
    )
  }

  static func indentationReplacement(
    in text: String,
    selectedRange: NSRange,
    direction: OrgSourceTextIndentDirection
  ) -> OrgSyntaxTextEditReplacement? {
    indentationReplacement(
      in: text as NSString,
      selectedRange: selectedRange,
      direction: direction
    )
  }

  static func indentationReplacement(
    in nsText: NSString,
    selectedRange: NSRange,
    direction: OrgSourceTextIndentDirection
  ) -> OrgSyntaxTextEditReplacement? {
    let selectedRange = clampedRange(selectedRange, utf16Length: nsText.length)
    let affectedRange = affectedLineRange(in: nsText, selectedRange: selectedRange)
    guard affectedRange.length > 0 else { return nil }

    var replacement = ""
    var changedEdits: [(location: Int, delta: Int)] = []
    var location = affectedRange.location
    let affectedEnd = affectedRange.location + affectedRange.length

    while location < affectedEnd {
      let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
      let lineEnd = lineRange.location + lineRange.length
      let contentEnd = lineContentEnd(in: nsText, lineRange: lineRange)
      let contentRange = NSRange(
        location: lineRange.location,
        length: max(0, contentEnd - lineRange.location)
      )
      let suffixRange = NSRange(
        location: contentEnd,
        length: max(0, lineEnd - contentEnd)
      )
      let content = nsText.substring(with: contentRange)
      let suffix = nsText.substring(with: suffixRange)
      let transformed = transformedLineContent(content, direction: direction)
      replacement += transformed.text + suffix
      if transformed.text != content {
        changedEdits.append((
          location: lineRange.location + transformed.editUTF16Offset,
          delta: (transformed.text as NSString).length - (content as NSString).length
        ))
      }
      location = lineEnd
    }

    guard !changedEdits.isEmpty else { return nil }
    let selectionEnd = selectedRange.location + selectedRange.length
    let adjustedLocation = adjustedOffset(
      selectedRange.location,
      edits: changedEdits,
      includeInsertionAtOffset: selectedRange.length == 0
    )
    let adjustedEnd = adjustedOffset(
      selectionEnd,
      edits: changedEdits,
      includeInsertionAtOffset: false
    )
    return OrgSyntaxTextEditReplacement(
      range: affectedRange,
      replacement: replacement,
      selectedRange: NSRange(
        location: max(0, adjustedLocation),
        length: max(0, adjustedEnd - adjustedLocation)
      )
    )
  }

  static func headingInsertionReplacement(
    in text: String,
    selectedRange: NSRange,
    snapshot: OrgSourceEditorSemanticSnapshot?
  ) -> OrgSyntaxTextEditReplacement {
    headingInsertionReplacement(
      in: text as NSString,
      selectedRange: selectedRange,
      snapshot: snapshot,
      lineIndex: nil
    )
  }

  static func headingInsertionReplacement(
    in nsText: NSString,
    selectedRange: NSRange,
    snapshot: OrgSourceEditorSemanticSnapshot?,
    lineIndex: OrgSourceLineIndex?
  ) -> OrgSyntaxTextEditReplacement {
    let selection = clampedRange(selectedRange, utf16Length: nsText.length)
    let context = lineContext(in: nsText, selectedRange: selection)
    let line = lineNumber(in: nsText, utf16Offset: selection.location, lineIndex: lineIndex)
    let level = headingMarker(in: context.lineText)?.level
      ?? enclosingHeadline(in: snapshot, line: line)?.level
      ?? 1
    let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
    let contentEnd = lineContentEnd(in: nsText, lineRange: lineRange)
    let prefix = "\n" + String(repeating: "*", count: max(1, level)) + " "
    return OrgSyntaxTextEditReplacement(
      range: NSRange(location: contentEnd, length: 0),
      replacement: prefix
    )
  }

  static func listItemInsertionReplacement(
    in text: String,
    selectedRange: NSRange
  ) -> OrgSyntaxTextEditReplacement {
    listItemInsertionReplacement(in: text as NSString, selectedRange: selectedRange)
  }

  static func listItemInsertionReplacement(
    in nsText: NSString,
    selectedRange: NSRange
  ) -> OrgSyntaxTextEditReplacement {
    let selection = clampedRange(selectedRange, utf16Length: nsText.length)
    let context = lineContext(in: nsText, selectedRange: selection)
    let indent = leadingWhitespace(in: context.lineText)
    let rest = String(context.lineText.dropFirst(indent.count))
    let prefix = listMarker(in: rest)?.nextPrefix ?? "- "
    let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
    let contentEnd = lineContentEnd(in: nsText, lineRange: lineRange)
    return OrgSyntaxTextEditReplacement(
      range: NSRange(location: contentEnd, length: 0),
      replacement: "\n" + indent + prefix
    )
  }

  static func todoCycleReplacement(
    in text: String,
    selectedRange: NSRange,
    snapshot: OrgSourceEditorSemanticSnapshot?
  ) -> OrgSyntaxTextEditReplacement? {
    todoCycleReplacement(
      in: text as NSString,
      selectedRange: selectedRange,
      snapshot: snapshot,
      lineIndex: nil
    )
  }

  static func todoCycleReplacement(
    in nsText: NSString,
    selectedRange: NSRange,
    snapshot: OrgSourceEditorSemanticSnapshot?,
    lineIndex: OrgSourceLineIndex?
  ) -> OrgSyntaxTextEditReplacement? {
    let selection = clampedRange(selectedRange, utf16Length: nsText.length)
    let currentLine = lineNumber(in: nsText, utf16Offset: selection.location, lineIndex: lineIndex)
    let headingLine = headingMarker(in: lineText(in: nsText, line: currentLine, lineIndex: lineIndex)) != nil
      ? currentLine
      : enclosingHeadline(in: snapshot, line: currentLine)?.startLine
    guard let headingLine else { return nil }
    let range = lineRange(in: nsText, line: headingLine, lineIndex: lineIndex)
    let raw = nsText.substring(with: NSRange(
      location: range.location,
      length: max(0, lineContentEnd(in: nsText, lineRange: range) - range.location)
    ))
    guard let match = headingTodoRegex.firstMatch(
      in: raw,
      range: NSRange(location: 0, length: (raw as NSString).length)
    ) else { return nil }

    let current = match.range(at: 2).location == NSNotFound
      ? nil
      : (raw as NSString).substring(with: match.range(at: 2))
    let next: String?
    switch current {
    case nil: next = "TODO"
    case "TODO": next = "IN_PROGRESS"
    case "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED": next = "DONE"
    default: next = nil
    }
    let prefixRange = match.range(at: 1)
    let statusRange = match.range(at: 2)
    let replacementRange: NSRange
    let replacement: String
    if statusRange.location != NSNotFound {
      replacementRange = NSRange(
        location: range.location + statusRange.location,
        length: statusRange.length + 1
      )
      replacement = next.map { $0 + " " } ?? ""
    } else {
      replacementRange = NSRange(
        location: range.location + NSMaxRange(prefixRange),
        length: 0
      )
      replacement = next.map { $0 + " " } ?? ""
    }
    return OrgSyntaxTextEditReplacement(range: replacementRange, replacement: replacement)
  }

  static func priorityReplacement(
    in text: String,
    selectedRange: NSRange,
    priority: String?,
    snapshot: OrgSourceEditorSemanticSnapshot?
  ) -> OrgSyntaxTextEditReplacement? {
    priorityReplacement(
      in: text as NSString,
      selectedRange: selectedRange,
      priority: priority,
      snapshot: snapshot,
      lineIndex: nil
    )
  }

  static func priorityReplacement(
    in nsText: NSString,
    selectedRange: NSRange,
    priority: String?,
    snapshot: OrgSourceEditorSemanticSnapshot?,
    lineIndex: OrgSourceLineIndex?
  ) -> OrgSyntaxTextEditReplacement? {
    let selection = clampedRange(selectedRange, utf16Length: nsText.length)
    let currentLine = lineNumber(in: nsText, utf16Offset: selection.location, lineIndex: lineIndex)
    let headingLine = headingMarker(in: lineText(in: nsText, line: currentLine, lineIndex: lineIndex)) != nil
      ? currentLine
      : enclosingHeadline(in: snapshot, line: currentLine)?.startLine
    guard let headingLine else { return nil }

    let lineRange = lineRange(in: nsText, line: headingLine, lineIndex: lineIndex)
    let raw = nsText.substring(with: NSRange(
      location: lineRange.location,
      length: max(0, lineContentEnd(in: nsText, lineRange: lineRange) - lineRange.location)
    ))
    let nsRaw = raw as NSString
    guard let prefix = headingTodoRegex.firstMatch(
      in: raw,
      range: NSRange(location: 0, length: nsRaw.length)
    ) else { return nil }

    let normalizedPriority = priority?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
      .first
      .map(String.init)
    let replacementText = normalizedPriority.map { "[#\($0)] " } ?? ""
    let prioritySearchRange = NSRange(
      location: prefix.range.length,
      length: max(0, nsRaw.length - prefix.range.length)
    )
    if let existing = headingPriorityRegex.firstMatch(
      in: raw,
      options: .anchored,
      range: prioritySearchRange
    ) {
      return OrgSyntaxTextEditReplacement(
        range: NSRange(
          location: lineRange.location + existing.range.location,
          length: existing.range.length
        ),
        replacement: replacementText
      )
    }

    guard !replacementText.isEmpty else { return nil }
    return OrgSyntaxTextEditReplacement(
      range: NSRange(location: lineRange.location + prefix.range.length, length: 0),
      replacement: replacementText
    )
  }

  static func planningReplacement(
    in text: String,
    selectedRange: NSRange,
    kind: String,
    date: Date?,
    snapshot: OrgSourceEditorSemanticSnapshot?
  ) -> OrgSyntaxTextEditReplacement? {
    planningReplacement(
      in: text as NSString,
      selectedRange: selectedRange,
      kind: kind,
      date: date,
      snapshot: snapshot,
      lineIndex: nil
    )
  }

  static func planningReplacement(
    in nsText: NSString,
    selectedRange: NSRange,
    kind: String,
    date: Date?,
    snapshot: OrgSourceEditorSemanticSnapshot?,
    lineIndex: OrgSourceLineIndex?
  ) -> OrgSyntaxTextEditReplacement? {
    let normalizedKind = kind.uppercased()
    guard normalizedKind == "SCHEDULED" || normalizedKind == "DEADLINE" else { return nil }
    let selection = clampedRange(selectedRange, utf16Length: nsText.length)
    let currentLine = lineNumber(in: nsText, utf16Offset: selection.location, lineIndex: lineIndex)
    guard let headline = enclosingHeadline(in: snapshot, line: currentLine)
      ?? headlineRegion(startingAt: currentLine, in: snapshot)
    else { return nil }

    let endLine = min(headline.endLine, lineCount(in: nsText, lineIndex: lineIndex))
    for line in (headline.startLine + 1)...max(headline.startLine + 1, endLine) {
      let raw = lineText(in: nsText, line: line, lineIndex: lineIndex)
      if raw.range(of: #"^\s*\#(normalizedKind):"#, options: .regularExpression) != nil {
        let range = lineRange(in: nsText, line: line, lineIndex: lineIndex)
        if let date {
          return OrgSyntaxTextEditReplacement(
            range: NSRange(
              location: range.location,
              length: max(0, lineContentEnd(in: nsText, lineRange: range) - range.location)
            ),
            replacement: planningLine(kind: normalizedKind, date: date)
          )
        }
        return OrgSyntaxTextEditReplacement(range: range, replacement: "")
      }
      if headingMarker(in: raw) != nil { break }
    }

    guard let date else { return nil }
    let headingRange = lineRange(in: nsText, line: headline.startLine, lineIndex: lineIndex)
    let insertion = lineContentEnd(in: nsText, lineRange: headingRange)
    return OrgSyntaxTextEditReplacement(
      range: NSRange(location: insertion, length: 0),
      replacement: "\n" + planningLine(kind: normalizedKind, date: date)
    )
  }

  static func clearPlanningReplacement(
    in text: String,
    selectedRange: NSRange,
    snapshot: OrgSourceEditorSemanticSnapshot?
  ) -> OrgSyntaxTextEditReplacement? {
    clearPlanningReplacement(
      in: text as NSString,
      selectedRange: selectedRange,
      snapshot: snapshot,
      lineIndex: nil
    )
  }

  static func clearPlanningReplacement(
    in nsText: NSString,
    selectedRange: NSRange,
    snapshot: OrgSourceEditorSemanticSnapshot?,
    lineIndex: OrgSourceLineIndex?
  ) -> OrgSyntaxTextEditReplacement? {
    let selection = clampedRange(selectedRange, utf16Length: nsText.length)
    let currentLine = lineNumber(in: nsText, utf16Offset: selection.location, lineIndex: lineIndex)
    guard let headline = enclosingHeadline(in: snapshot, line: currentLine)
      ?? headlineRegion(startingAt: currentLine, in: snapshot)
    else { return nil }

    var planningRanges: [NSRange] = []
    let endLine = min(headline.endLine, lineCount(in: nsText, lineIndex: lineIndex))
    for line in (headline.startLine + 1)...max(headline.startLine + 1, endLine) {
      let raw = lineText(in: nsText, line: line, lineIndex: lineIndex)
      if raw.range(
        of: #"^\s*(?:SCHEDULED|DEADLINE|CLOSED):"#,
        options: [.regularExpression, .caseInsensitive]
      ) != nil {
        planningRanges.append(lineRange(in: nsText, line: line, lineIndex: lineIndex))
      } else if headingMarker(in: raw) != nil {
        break
      }
    }
    guard let first = planningRanges.first, let last = planningRanges.last else { return nil }

    let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    let replacement = NSMutableString(string: nsText.substring(with: span))
    for range in planningRanges.reversed() {
      replacement.replaceCharacters(
        in: NSRange(location: range.location - span.location, length: range.length),
        with: ""
      )
    }
    return OrgSyntaxTextEditReplacement(
      range: span,
      replacement: replacement as String,
      selectedRange: NSRange(location: span.location, length: 0)
    )
  }

  static func propertyReplacement(
    in text: String,
    selectedRange: NSRange,
    key rawKey: String,
    value: String,
    snapshot: OrgSourceEditorSemanticSnapshot?
  ) -> OrgSyntaxTextEditReplacement? {
    propertyReplacement(
      in: text as NSString,
      selectedRange: selectedRange,
      key: rawKey,
      value: value,
      snapshot: snapshot,
      lineIndex: nil
    )
  }

  static func propertyReplacement(
    in nsText: NSString,
    selectedRange: NSRange,
    key rawKey: String,
    value: String,
    snapshot: OrgSourceEditorSemanticSnapshot?,
    lineIndex: OrgSourceLineIndex?
  ) -> OrgSyntaxTextEditReplacement? {
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
      .replacingOccurrences(of: " ", with: "_")
    guard !key.isEmpty, !key.contains(":") else { return nil }
    let selection = clampedRange(selectedRange, utf16Length: nsText.length)
    let currentLine = lineNumber(in: nsText, utf16Offset: selection.location, lineIndex: lineIndex)
    guard let headline = enclosingHeadline(in: snapshot, line: currentLine)
      ?? headlineRegion(startingAt: currentLine, in: snapshot)
    else { return nil }

    var drawerStart: Int?
    let endLine = min(headline.endLine, lineCount(in: nsText, lineIndex: lineIndex))
    for line in (headline.startLine + 1)...max(headline.startLine + 1, endLine) {
      let raw = lineText(in: nsText, line: line, lineIndex: lineIndex)
      if raw == ":PROPERTIES:" {
        drawerStart = line
        continue
      }
      if drawerStart != nil {
        if raw == ":END:" {
          let endRange = lineRange(in: nsText, line: line, lineIndex: lineIndex)
          return OrgSyntaxTextEditReplacement(
            range: NSRange(location: endRange.location, length: 0),
            replacement: ":\(key): \(value)\n"
          )
        }
        if raw.uppercased().hasPrefix(":\(key):") {
          let range = lineRange(in: nsText, line: line, lineIndex: lineIndex)
          return OrgSyntaxTextEditReplacement(
            range: NSRange(
              location: range.location,
              length: max(0, lineContentEnd(in: nsText, lineRange: range) - range.location)
            ),
            replacement: ":\(key): \(value)"
          )
        }
      }
      if headingMarker(in: raw) != nil { break }
    }

    let headingRange = lineRange(in: nsText, line: headline.startLine, lineIndex: lineIndex)
    let insertion = lineContentEnd(in: nsText, lineRange: headingRange)
    return OrgSyntaxTextEditReplacement(
      range: NSRange(location: insertion, length: 0),
      replacement: "\n:PROPERTIES:\n:\(key): \(value)\n:END:"
    )
  }

  static func linkReplacement(
    in text: String,
    selectedRange: NSRange,
    target rawTarget: String,
    description rawDescription: String?
  ) -> OrgSyntaxTextEditReplacement? {
    linkReplacement(
      in: text as NSString,
      selectedRange: selectedRange,
      target: rawTarget,
      description: rawDescription
    )
  }

  static func linkReplacement(
    in nsText: NSString,
    selectedRange: NSRange,
    target rawTarget: String,
    description rawDescription: String?
  ) -> OrgSyntaxTextEditReplacement? {
    let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return nil }
    let selection = clampedRange(selectedRange, utf16Length: nsText.length)
    let selectedText = selection.length > 0 ? nsText.substring(with: selection) : ""
    let description = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = (description?.isEmpty == false ? description : selectedText.isEmpty ? nil : selectedText)
    let replacement = label.map { "[[\(target)][\($0)]]" } ?? "[[\(target)]]"
    return OrgSyntaxTextEditReplacement(range: selection, replacement: replacement)
  }

  static func headingNavigationRange(
    in text: String,
    selectedRange: NSRange,
    direction: OrgSourceEditorCommand,
    snapshot: OrgSourceEditorSemanticSnapshot?
  ) -> NSRange? {
    headingNavigationRange(
      in: text as NSString,
      selectedRange: selectedRange,
      direction: direction,
      snapshot: snapshot,
      lineIndex: nil
    )
  }

  static func headingNavigationRange(
    in nsText: NSString,
    selectedRange: NSRange,
    direction: OrgSourceEditorCommand,
    snapshot: OrgSourceEditorSemanticSnapshot?,
    lineIndex: OrgSourceLineIndex?
  ) -> NSRange? {
    guard direction == .previousHeading || direction == .nextHeading,
          let snapshot
    else { return nil }
    let currentLine = lineNumber(
      in: nsText,
      utf16Offset: selectedRange.location,
      lineIndex: lineIndex
    )
    let headlines = snapshot.regions.filter { $0.kind == .headline }
    let target = direction == .nextHeading
      ? headlines.first(where: { $0.startLine > currentLine })
      : headlines.last(where: { $0.startLine < currentLine })
    guard let target else { return nil }
    return NSRange(
      location: lineRange(in: nsText, line: target.startLine, lineIndex: lineIndex).location,
      length: 0
    )
  }

  static func sourceRange(
    for region: OrgSourceSemanticRegion,
    in text: String,
    excludingFirstLine: Bool = false
  ) -> NSRange? {
    let nsText = text as NSString
    let startLine = region.startLine + (excludingFirstLine ? 1 : 0)
    guard startLine <= region.endLine,
          startLine <= lineCount(in: nsText)
    else { return nil }
    let start = lineRange(in: nsText, line: startLine).location
    let endRange = lineRange(in: nsText, line: min(region.endLine, lineCount(in: nsText)))
    return NSRange(location: start, length: NSMaxRange(endRange) - start)
  }

  static func lineNumber(in text: NSString, utf16Offset: Int) -> Int {
    let clamped = min(max(0, utf16Offset), text.length)
    var line = 1
    var location = 0
    while location < clamped {
      if text.character(at: location) == 10 { line += 1 }
      location += 1
    }
    return line
  }

  private static func lineNumber(
    in text: NSString,
    utf16Offset: Int,
    lineIndex: OrgSourceLineIndex?
  ) -> Int {
    lineIndex?.lineNumber(atUTF16Offset: utf16Offset)
      ?? lineNumber(in: text, utf16Offset: utf16Offset)
  }

  static func lineRange(in text: NSString, line requestedLine: Int) -> NSRange {
    let target = max(1, requestedLine)
    var line = 1
    var location = 0
    while line < target, location < text.length {
      if text.character(at: location) == 10 { line += 1 }
      location += 1
    }
    return text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
  }

  private static func lineRange(
    in text: NSString,
    line requestedLine: Int,
    lineIndex: OrgSourceLineIndex?
  ) -> NSRange {
    lineIndex?.lineRange(forLine: requestedLine)
      ?? lineRange(in: text, line: requestedLine)
  }

  static func lineText(in text: NSString, line: Int) -> String {
    let range = lineRange(in: text, line: line)
    return text.substring(with: NSRange(
      location: range.location,
      length: max(0, lineContentEnd(in: text, lineRange: range) - range.location)
    ))
  }

  private static func lineText(
    in text: NSString,
    line: Int,
    lineIndex: OrgSourceLineIndex?
  ) -> String {
    let range = lineRange(in: text, line: line, lineIndex: lineIndex)
    return text.substring(with: NSRange(
      location: range.location,
      length: max(0, lineContentEnd(in: text, lineRange: range) - range.location)
    ))
  }

  static func lineCount(in text: NSString) -> Int {
    guard text.length > 0 else { return 1 }
    var count = 1
    for location in 0..<text.length where text.character(at: location) == 10 { count += 1 }
    return count
  }

  private static func lineCount(
    in text: NSString,
    lineIndex: OrgSourceLineIndex?
  ) -> Int {
    lineIndex?.lineCount ?? lineCount(in: text)
  }

  static func fallbackSemanticSnapshot(in text: String) -> OrgSourceEditorSemanticSnapshot {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var regions: [OrgSourceSemanticRegion] = []
    var stack: [(level: Int, startLine: Int, todo: String?)] = []

    func closeHeadlines(at level: Int, endLine: Int) {
      while let last = stack.last, last.level >= level {
        let closed = stack.removeLast()
        regions.append(OrgSourceSemanticRegion(
          kind: .headline,
          startLine: closed.startLine,
          endLine: max(closed.startLine, endLine),
          level: closed.level,
          todo: closed.todo
        ))
      }
    }

    for (index, slice) in lines.enumerated() {
      let line = String(slice)
      guard let marker = headingMarker(in: line) else { continue }
      closeHeadlines(at: marker.level, endLine: index)
      let nsLine = line as NSString
      let match = headingTodoRegex.firstMatch(
        in: line,
        range: NSRange(location: 0, length: nsLine.length)
      )
      let todo = match.flatMap { match -> String? in
        let range = match.range(at: 2)
        return range.location == NSNotFound ? nil : nsLine.substring(with: range)
      }
      stack.append((marker.level, index + 1, todo))
    }
    closeHeadlines(at: 0, endLine: max(1, lines.count))
    return OrgSourceEditorSemanticSnapshot(
      regions: regions.sorted { $0.startLine < $1.startLine }
    )
  }

  static func enclosingHeadline(
    in snapshot: OrgSourceEditorSemanticSnapshot?,
    line: Int
  ) -> OrgSourceSemanticRegion? {
    snapshot?.regions
      .filter { $0.kind == .headline && $0.startLine <= line && $0.endLine >= line }
      .max {
        if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
        return ($0.level ?? 0) < ($1.level ?? 0)
      }
  }

  static func headlineRegion(
    startingAt line: Int,
    in snapshot: OrgSourceEditorSemanticSnapshot?
  ) -> OrgSourceSemanticRegion? {
    snapshot?.regions.first { $0.kind == .headline && $0.startLine == line }
  }

  private static func planningLine(kind: String, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd EEE"
    return "\(kind): <\(formatter.string(from: date))>"
  }

  private static let headingTodoRegex = try! NSRegularExpression(
    pattern: #"^(\*+\s+)(?:(TODO|IN_PROGRESS|PROG|WAIT|HOLD|PAUSED|DONE|CANCELED|CANCELLED)\s+)?"#
  )

  private static let headingPriorityRegex = try! NSRegularExpression(
    pattern: #"\[#(?:[A-Za-z0-9])\]\s*"#
  )

  private static func clampedRange(_ range: NSRange, utf16Length length: Int) -> NSRange {
    let location = min(max(0, range.location), length)
    return NSRange(
      location: location,
      length: min(max(0, range.length), length - location)
    )
  }

  private static func affectedLineRange(in text: NSString, selectedRange: NSRange) -> NSRange {
    guard text.length > 0 else { return NSRange(location: 0, length: 0) }
    let start = min(max(0, selectedRange.location), text.length)
    let rawEnd = selectedRange.location + selectedRange.length
    let endProbe = selectedRange.length > 0
      ? max(selectedRange.location, rawEnd - 1)
      : rawEnd
    let end = min(max(0, endProbe), text.length)
    let startLine = text.lineRange(for: NSRange(location: start, length: 0))
    let endLine = text.lineRange(for: NSRange(location: end, length: 0))
    return NSUnionRange(startLine, endLine)
  }

  private static func lineContext(
    in text: NSString,
    selectedRange: NSRange
  ) -> (lineText: String, textBeforeSelection: String) {
    let lineRange = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
    let lineEnd = lineContentEnd(in: text, lineRange: lineRange)
    let contentRange = NSRange(location: lineRange.location, length: max(0, lineEnd - lineRange.location))
    let beforeEnd = min(selectedRange.location, lineEnd)
    let beforeRange = NSRange(location: lineRange.location, length: max(0, beforeEnd - lineRange.location))
    return (
      lineText: text.substring(with: contentRange),
      textBeforeSelection: text.substring(with: beforeRange)
    )
  }

  static func lineContentEnd(in text: NSString, lineRange: NSRange) -> Int {
    var end = lineRange.location + lineRange.length
    while end > lineRange.location {
      let character = text.character(at: end - 1)
      if character == 10 || character == 13 {
        end -= 1
      } else {
        break
      }
    }
    return end
  }

  private static func adjustedOffset(
    _ offset: Int,
    edits: [(location: Int, delta: Int)],
    includeInsertionAtOffset: Bool
  ) -> Int {
    edits.reduce(offset) { current, edit in
      if edit.location < offset || (includeInsertionAtOffset && edit.delta > 0 && edit.location == offset) {
        return current + edit.delta
      }
      return current
    }
  }

  private static func transformedLineContent(
    _ content: String,
    direction: OrgSourceTextIndentDirection
  ) -> (text: String, editUTF16Offset: Int) {
    if let heading = headingMarker(in: content) {
      switch direction {
      case .indent:
        return ("*" + content, 0)
      case .outdent:
        guard heading.level > 1 else { return (content, 0) }
        return (String(content.dropFirst()), 0)
      }
    }

    guard isListLine(content) else {
      return (content, 0)
    }
    switch direction {
    case .indent:
      return ("  " + content, 0)
    case .outdent:
      if content.hasPrefix("\t") {
        return (String(content.dropFirst()), 0)
      }
      let removableSpaces = content.prefix(2).filter { $0 == " " }.count
      guard removableSpaces > 0 else { return (content, 0) }
      return (String(content.dropFirst(removableSpaces)), 0)
    }
  }

  static func headingMarker(in text: String) -> (level: Int, consumedUTF16Length: Int)? {
    var level = 0
    var index = text.startIndex
    while index < text.endIndex, text[index] == "*" {
      level += 1
      index = text.index(after: index)
    }
    guard level > 0,
          index < text.endIndex,
          text[index].isWhitespace
    else {
      return nil
    }
    return (level, level)
  }

  private static func isListLine(_ text: String) -> Bool {
    let indent = leadingWhitespace(in: text)
    let rest = String(text.dropFirst(indent.count))
    return listMarker(in: rest) != nil
  }

  private static func indentationContinuation(for linePrefix: String) -> String? {
    let indent = leadingWhitespace(in: linePrefix)
    guard !indent.isEmpty,
          linePrefix.trimmingCharacters(in: .whitespaces).isEmpty == false
    else {
      return nil
    }
    return indent
  }

  private static func listContinuation(for linePrefix: String) -> String? {
    let indent = leadingWhitespace(in: linePrefix)
    let rest = String(linePrefix.dropFirst(indent.count))
    guard let marker = listMarker(in: rest) else { return nil }
    let content = rest.dropFirst(marker.consumedUTF16Length)
    guard content.trimmingCharacters(in: .whitespaces).isEmpty == false else {
      return nil
    }
    return indent + marker.nextPrefix
  }

  private static func leadingWhitespace(in text: String) -> String {
    String(text.prefix { $0 == " " || $0 == "\t" })
  }

  private static func listMarker(in text: String) -> (consumedUTF16Length: Int, nextPrefix: String)? {
    guard !text.isEmpty else { return nil }
    if let marker = unorderedListMarker(in: text) {
      return marker
    }
    return orderedListMarker(in: text)
  }

  private static func unorderedListMarker(in text: String) -> (consumedUTF16Length: Int, nextPrefix: String)? {
    guard let first = text.first,
          first == "-" || first == "+",
          text.dropFirst().first?.isWhitespace == true
    else {
      return nil
    }
    let basePrefix = "\(first) "
    let afterMarker = String(text.dropFirst(2))
    if let checkbox = checkboxPrefix(in: afterMarker) {
      return (
        (basePrefix + checkbox).utf16.count,
        basePrefix + checkbox
      )
    }
    return (basePrefix.utf16.count, basePrefix)
  }

  private static func orderedListMarker(in text: String) -> (consumedUTF16Length: Int, nextPrefix: String)? {
    var digits = ""
    var index = text.startIndex
    while index < text.endIndex, text[index].isNumber {
      digits.append(text[index])
      index = text.index(after: index)
    }
    guard !digits.isEmpty,
          index < text.endIndex,
          text[index] == "." || text[index] == ")"
    else {
      return nil
    }
    let delimiter = text[index]
    let afterDelimiter = text.index(after: index)
    guard afterDelimiter < text.endIndex,
          text[afterDelimiter].isWhitespace
    else {
      return nil
    }
    let number = Int(digits) ?? 0
    let basePrefix = "\(number + 1)\(delimiter) "
    let afterMarker = String(text[text.index(after: afterDelimiter)...])
    if let checkbox = checkboxPrefix(in: afterMarker) {
      return (
        "\(digits)\(delimiter) \(checkbox)".utf16.count,
        basePrefix + checkbox
      )
    }
    return ("\(digits)\(delimiter) ".utf16.count, basePrefix)
  }

  private static func checkboxPrefix(in text: String) -> String? {
    for candidate in ["[ ] ", "[X] ", "[x] ", "[-] "] where text.hasPrefix(candidate) {
      return candidate
    }
    return nil
  }
}

enum OrgSourceTextChecking {
  static func shouldSuppress(
    in text: String,
    range requestedRange: NSRange,
    snapshot: OrgSourceEditorSemanticSnapshot?,
    lineIndex: OrgSourceLineIndex? = nil
  ) -> Bool {
    shouldSuppress(
      in: text as NSString,
      range: requestedRange,
      snapshot: snapshot,
      lineIndex: lineIndex
    )
  }

  static func shouldSuppress(
    in nsText: NSString,
    range requestedRange: NSRange,
    snapshot: OrgSourceEditorSemanticSnapshot?,
    lineIndex: OrgSourceLineIndex? = nil
  ) -> Bool {
    guard nsText.length > 0 else { return false }
    let location = min(max(0, requestedRange.location), max(0, nsText.length - 1))
    let range = NSRange(
      location: location,
      length: min(max(1, requestedRange.length), nsText.length - location)
    )
    let line = lineIndex?.lineNumber(atUTF16Offset: range.location)
      ?? OrgSourceTextEditing.lineNumber(in: nsText, utf16Offset: range.location)

    if snapshot?.regions.contains(where: { region in
      guard region.startLine <= line, region.endLine >= line else { return false }
      switch region.kind {
      case .keyword, .planning, .properties, .sourceBlock, .table:
        return true
      default:
        return false
      }
    }) == true {
      return true
    }

    let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
    let lineText = nsText.substring(with: NSRange(
      location: lineRange.location,
      length: max(0, OrgSourceTextEditing.lineContentEnd(in: nsText, lineRange: lineRange) - lineRange.location)
    ))
    let trimmed = lineText.trimmingCharacters(in: CharacterSet.whitespaces)
    if isNonProseLine(trimmed) { return true }

    let relativeRange = NSRange(
      location: range.location - lineRange.location,
      length: range.length
    )
    for token in OrgSyntaxHighlighter.tokens(in: lineText)
      where NSIntersectionRange(token.range, relativeRange).length > 0 {
      switch token.kind {
      case .headingStars, .keyword, .planningKeyword, .propertyKey, .todo, .doneTodo, .canceledTodo, .priority,
           .tag, .linkTarget, .code, .timestamp, .syntaxDelimiter, .comment:
        return true
      case .link:
        if let raw = substring(in: lineText, range: token.range), isBareLink(raw) {
          return true
        }
      case .headingTitle, .doneHeadingTitle, .canceledHeadingTitle, .emphasis, .checkedListItem:
        break
      }
    }
    return false
  }

  static func excludedSemanticRanges(
    in text: String,
    snapshot: OrgSourceEditorSemanticSnapshot
  ) -> [NSRange] {
    snapshot.regions.compactMap { region in
      switch region.kind {
      case .keyword, .planning, .properties, .sourceBlock, .table:
        return OrgSourceTextEditing.sourceRange(for: region, in: text)
      default:
        return nil
      }
    }
  }

  private static func isNonProseLine(_ line: String) -> Bool {
    let uppercased = line.uppercased()
    return line.hasPrefix("#+")
      || line.hasPrefix(":")
      || line.hasPrefix("|")
      || uppercased.hasPrefix("SCHEDULED:")
      || uppercased.hasPrefix("DEADLINE:")
      || uppercased.hasPrefix("CLOSED:")
  }

  private static func isBareLink(_ raw: String) -> Bool {
    let lowercased = raw.lowercased()
    return lowercased.hasPrefix("http://")
      || lowercased.hasPrefix("https://")
      || lowercased.hasPrefix("file:")
      || lowercased.hasPrefix("mailto:")
      || (!raw.hasPrefix("[[") && !raw.hasPrefix("["))
  }

  private static func substring(in text: String, range: NSRange) -> String? {
    let nsText = text as NSString
    guard range.location != NSNotFound, NSMaxRange(range) <= nsText.length else { return nil }
    return nsText.substring(with: range)
  }
}

enum OrgSyntaxTextEditorTextPublishing: Equatable {
  case immediate
  case deferred(milliseconds: Int)
}

/// Navigation/lifecycle bridge for owners of deferred native editors.
@MainActor
enum OrgSyntaxTextEditorLifecycle {
  /// Captures every dirty native buffer without materializing it on the main
  /// actor. The returned identities let an owner avoid enqueueing a stale
  /// binding snapshot while the exact native checkpoint is in flight.
  @discardableResult
  static func checkpointPendingTextChanges() -> Set<String> {
    OrgSyntaxTextEditor.checkpointPendingTextChanges()
  }

  static func waitForPendingTextCheckpoints() async {
    await OrgSyntaxTextEditor.waitForPendingTextCheckpoints()
  }

  /// Publishes the latest native-buffer contents into each mounted editor's
  /// owner state without invoking a save or navigation checkpoint callback.
  /// App-level Save/export commands await this boundary before inspecting the
  /// owner's dirty state.
  @discardableResult
  static func publishPendingTextChanges() -> Int {
    OrgSyntaxTextEditor.publishPendingTextChanges()
  }

  /// Reserved for small synchronous submit boundaries. Navigation and app
  /// lifecycle code must use `checkpointPendingTextChanges()` instead.
  @discardableResult
  static func flushPendingTextChanges() -> Int {
    OrgSyntaxTextEditor.flushPendingTextChanges()
  }

  static var hasPendingTextChanges: Bool {
    OrgSyntaxTextEditor.hasPendingTextChanges
  }
}

final class OrgSyntaxTextEditorDraftBuffer {
  var text: String?

  func update(_ text: String) {
    self.text = text
  }

  func current(fallback: String) -> String {
    text ?? fallback
  }

  func isCurrent(_ candidate: String) -> Bool {
    text == candidate
  }
}

struct OrgSyntaxTextSelectionContext: Equatable {
  let blockID: String
  let startLine: Int
  let endLineExclusive: Int
  let editorToSourceUTF16Offset: Int
}

struct OrgSyntaxTextSelectionDocumentFragment: Equatable {
  let context: OrgSyntaxTextSelectionContext
  let editorRange: NSRange
  let editorUTF16Length: Int
  let editorText: String

  var sourceRange: NSRange {
    NSRange(
      location: context.editorToSourceUTF16Offset + editorRange.location,
      length: editorRange.length
    )
  }

  var selectsEntireEditor: Bool {
    editorRange.location == 0 && editorRange.length >= editorUTF16Length
  }
}

fileprivate enum OrgSyntaxTextBoundaryDirection {
  case previous
  case next
}

fileprivate enum OrgSyntaxTextBoundaryCaretPlacement {
  case start
  case end
}

final class OrgSyntaxTextView: NSTextView {
  var pasteAsOrgEnabled: (() -> Bool)?
  var pasteDocumentIdentity: String?
  var pasteDocumentGeneration: (() -> UInt64)?
  var pastePreviewController: PasteAsOrg2Controller?
  var documentSelectionContext: OrgSyntaxTextSelectionContext?
  var onSaveCommand: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?
  var onDeferredSaveCommand: (() -> Bool)?
  var onDeleteDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment]) -> Bool)?
  var onReplaceDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment], String) -> Bool)?
  var onSourceEditorCommand: ((OrgSourceEditorCommand, OrgSyntaxTextView) -> Bool)?
  var onMouseSelectionEnded: ((OrgSyntaxTextView) -> Void)?
  var onWindowAttachmentChanged: ((OrgSyntaxTextView) -> Void)?
  var onLifecycleBoundary: ((OrgSyntaxTextView) -> Void)?
  var isApplyingCrossEditorSelection = false
  var isTrackingMouseSelection = false
  private var crossEditorHighlightedRange: NSRange?
  private var pendingLatencyTokens: [WorkspaceInteractionLatency.Token] = []

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let tokens = pendingLatencyTokens
    pendingLatencyTokens.removeAll(keepingCapacity: true)
    for token in tokens {
      WorkspaceInteractionLatency.finish(token)
    }
  }

  /// The editor that most recently took keyboard focus. Commands that finish
  /// after a modal panel (such as `/image`) insert into it through the native
  /// editing path; see ``OrgSyntaxTextEditorInsertionTarget``.
  static weak var lastFocused: OrgSyntaxTextView?

  override func becomeFirstResponder() -> Bool {
    if let window, !window.isKeyWindow {
      window.makeKey()
    }
    let becameFirstResponder = super.becomeFirstResponder()
    if becameFirstResponder {
      Self.lastFocused = self
      needsDisplay = true
      enclosingScrollView?.needsDisplay = true
      window?.contentView?.needsDisplay = true
    }
    return becameFirstResponder
  }

  override func resignFirstResponder() -> Bool {
    let didResign = super.resignFirstResponder()
    if didResign {
      onLifecycleBoundary?(self)
    }
    return didResign
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if window != nil, newWindow == nil {
      onLifecycleBoundary?(self)
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowAttachmentChanged?(self)
  }

  override func mouseDown(with event: NSEvent) {
    let latencyToken = WorkspaceInteractionLatency.begin(.sourceEditorPointerToDraw)
    defer {
      pendingLatencyTokens.append(latencyToken)
      needsDisplay = true
    }
    if event.clickCount == 1,
       OrgSyntaxTextSelectionBridge.beginSelection(in: self, event: event) {
      isTrackingMouseSelection = true
      return
    }
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    let latencyToken = WorkspaceInteractionLatency.begin(.sourceEditorDragToDraw)
    if OrgSyntaxTextSelectionBridge.updateSelection(from: self, event: event) {
      pendingLatencyTokens.append(latencyToken)
      needsDisplay = true
      return
    }
    WorkspaceInteractionLatency.finish(latencyToken)
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if OrgSyntaxTextSelectionBridge.endSelection(from: self) {
      isTrackingMouseSelection = false
      onMouseSelectionEnded?(self)
      needsDisplay = true
      return
    }
    isTrackingMouseSelection = false
    super.mouseUp(with: event)
  }

  override func keyDown(with event: NSEvent) {
    let latencyToken = WorkspaceInteractionLatency.begin(.sourceEditorKeyToDraw)
    defer {
      pendingLatencyTokens.append(latencyToken)
      needsDisplay = true
    }
    if handlesFindShortcut(event) {
      performFindShortcut()
      return
    }
    if let command = sourceEditorCommand(for: event),
       onSourceEditorCommand?(command, self) == true {
      return
    }
    if handlesCrossEditorCopyShortcut(event) {
      copy(nil)
      return
    }
    if handlesSaveShortcut(event), performSaveShortcut() {
      return
    }
    if handlesDocumentSelectAllShortcut(event),
       OrgSyntaxTextSelectionBridge.selectAllDocumentText(containing: self) {
      return
    }
    if handlesDocumentSelectionDelete(event),
       performDocumentSelectionDelete() {
      return
    }
    if let replacement = documentSelectionReplacementText(for: event),
       performDocumentSelectionReplacement(with: replacement) {
      return
    }
    OrgSyntaxTextSelectionBridge.clearCrossEditorSelection(containing: self, preserving: self)
    super.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handlesFindShortcut(event) {
      performFindShortcut()
      return true
    }
    if let command = sourceEditorCommand(for: event),
       onSourceEditorCommand?(command, self) == true {
      return true
    }
    if handlesCrossEditorCopyShortcut(event) {
      copy(nil)
      return true
    }
    if handlesSaveShortcut(event), performSaveShortcut() {
      return true
    }
    if handlesDocumentSelectAllShortcut(event),
       OrgSyntaxTextSelectionBridge.selectAllDocumentText(containing: self) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func selectAll(_ sender: Any?) {
    if OrgSyntaxTextSelectionBridge.selectAllDocumentText(containing: self) {
      return
    }
    super.selectAll(sender)
  }

  override func deleteBackward(_ sender: Any?) {
    if performDocumentSelectionDelete() {
      return
    }
    super.deleteBackward(sender)
  }

  override func deleteForward(_ sender: Any?) {
    if performDocumentSelectionDelete() {
      return
    }
    super.deleteForward(sender)
  }

  override func paste(_ sender: Any?) {
    if let pastedText = NSPasteboard.general.string(forType: .string),
       performDocumentSelectionReplacement(with: pastedText) {
      return
    }
    super.paste(sender)
  }

  override func copy(_ sender: Any?) {
    guard let selectedText = OrgSyntaxTextSelectionBridge.selectedText(containing: self) else {
      super.copy(sender)
      return
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(selectedText, forType: .string)
  }

  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(pasteAsOrg2(_:)) {
      return pasteAsOrgEnabled?() == true && isEditable && pastePreviewController == nil
    }
    if item.action == #selector(copy(_:)),
       OrgSyntaxTextSelectionBridge.selectedText(containing: self) != nil {
      return true
    }
    return super.validateUserInterfaceItem(item)
  }

  @MainActor
  static func saveFocusedTextViewIfPossible(for event: NSEvent) -> Bool {
    guard let textView = focusedSyntaxTextView(for: event),
          textView.handlesSaveShortcut(event)
    else {
      return false
    }
    return textView.performSaveShortcut()
  }

  @MainActor
  private static func focusedSyntaxTextView(for event: NSEvent) -> OrgSyntaxTextView? {
    var windows: [NSWindow] = []
    for window in [event.window, NSApplication.shared.keyWindow, NSApplication.shared.mainWindow].compactMap(\.self) {
      if !windows.contains(where: { $0 === window }) {
        windows.append(window)
      }
    }
    for window in NSApplication.shared.windows where !windows.contains(where: { $0 === window }) {
      windows.append(window)
    }
    return windows.compactMap { $0.firstResponder as? OrgSyntaxTextView }.first
  }

  private func performSaveShortcut() -> Bool {
    if (textStorage?.length ?? 0) > OrgSyntaxTextEditor.Coordinator.synchronousTextSnapshotUTF16Limit,
       let onDeferredSaveCommand {
      return onDeferredSaveCommand()
    }
    return onSaveCommand?(
      OrgSyntaxTextEditorSubmitContext(text: string, selectedRange: selectedRange())
    ) == true
  }

  private func performFindShortcut() {
    let sender = NSMenuItem()
    sender.tag = NSTextFinder.Action.showFindInterface.rawValue
    performTextFinderAction(sender)
  }

  private func handlesFindShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command
      && event.charactersIgnoringModifiers?.lowercased() == "f"
  }

  private func handlesCrossEditorCopyShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command
      && event.charactersIgnoringModifiers?.lowercased() == "c"
      && OrgSyntaxTextSelectionBridge.selectedText(containing: self) != nil
  }

  private func sourceEditorCommand(for event: NSEvent) -> OrgSourceEditorCommand? {
    guard onSourceEditorCommand != nil else { return nil }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let characters = event.charactersIgnoringModifiers?.lowercased()

    if modifiers == .command, characters == "k" { return .insertLink }
    guard modifiers == [.command, .option] else { return nil }
    switch event.keyCode {
    case 36: return .insertHeading
    case 123: return .promote
    case 124: return .demote
    case 125: return .nextHeading
    case 126: return .previousHeading
    default: break
    }
    switch characters {
    case "l": return .insertListItem
    case "t": return .cycleTodo
    case "s": return .scheduleToday
    case "d": return .deadlineToday
    case "[": return .toggleFold
    case "]": return .unfoldAll
    default: return nil
    }
  }

  private func handlesSaveShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command
      && event.charactersIgnoringModifiers?.lowercased() == "s"
  }

  private func handlesDocumentSelectAllShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return modifiers == .command
      && event.charactersIgnoringModifiers?.lowercased() == "a"
      && documentSelectionContext != nil
  }

  private func handlesDocumentSelectionDelete(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers.subtracting([.function]).isEmpty else { return false }
    if event.keyCode == 51 || event.keyCode == 117 {
      return true
    }
    return event.charactersIgnoringModifiers == "\u{7F}"
      || event.charactersIgnoringModifiers == String(UnicodeScalar(NSDeleteCharacter)!)
  }

  private func documentSelectionReplacementText(for event: NSEvent) -> String? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard !modifiers.contains(.command),
          !modifiers.contains(.control),
          !modifiers.contains(.option),
          let characters = event.characters,
          !characters.isEmpty,
          characters.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar)
              && !(0xF700...0xF8FF).contains(Int(scalar.value))
          })
    else {
      return nil
    }
    return characters
  }

  private func performDocumentSelectionDelete() -> Bool {
    if performDocumentSelectionReplacement(with: "") {
      return true
    }
    guard let fragments = OrgSyntaxTextSelectionBridge.selectedDocumentFragments(containing: self),
          !fragments.isEmpty,
          onDeleteDocumentSelection?(fragments) == true
    else {
      return false
    }
    OrgSyntaxTextSelectionBridge.clearCrossEditorSelection(containing: self)
    return true
  }

  private func performDocumentSelectionReplacement(with replacement: String) -> Bool {
    guard let fragments = OrgSyntaxTextSelectionBridge.selectedDocumentFragments(containing: self),
          !fragments.isEmpty,
          onReplaceDocumentSelection?(fragments, replacement) == true
    else {
      return false
    }
    OrgSyntaxTextSelectionBridge.clearCrossEditorSelection(containing: self)
    return true
  }

  func applyCrossEditorHighlight(_ range: NSRange) {
    clearCrossEditorHighlight()
    if range.length > 0 {
      let clampedRange = OrgSyntaxTextEditor.clampedRange(
        range,
        utf16Length: (string as NSString).length
      )
      guard clampedRange.length > 0 else { return }
      crossEditorHighlightedRange = clampedRange
      layoutManager?.addTemporaryAttribute(
        .backgroundColor,
        value: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55),
        forCharacterRange: clampedRange
      )
    }
  }

  func clearCrossEditorHighlight() {
    guard let range = crossEditorHighlightedRange else { return }
    layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
    crossEditorHighlightedRange = nil
  }
}

@MainActor
enum OrgSyntaxTextSelectionBridge {
  private struct ActiveSelection {
    weak var anchorView: OrgSyntaxTextView?
    let anchorLocation: Int
    let initialPoint: NSPoint
    var didDrag: Bool
    var crossedEditorBoundary: Bool
  }

  private struct SelectionFragment {
    weak var view: OrgSyntaxTextView?
    let range: NSRange
  }

  private static var activeSelection: ActiveSelection?
  private static var selectedFragments: [SelectionFragment] = []

  static func beginSelection(in textView: OrgSyntaxTextView, event: NSEvent) -> Bool {
    guard let window = textView.window else { return false }
    clearCrossEditorSelection(containing: textView)
    window.makeFirstResponder(textView)
    activeSelection = ActiveSelection(
      anchorView: textView,
      anchorLocation: characterLocation(in: textView, event: event),
      initialPoint: event.locationInWindow,
      didDrag: false,
      crossedEditorBoundary: false
    )
    return true
  }

  static func updateSelection(from textView: OrgSyntaxTextView, event: NSEvent) -> Bool {
    guard var activeSelection,
          let anchorView = activeSelection.anchorView
    else {
      return false
    }

    let deltaX = event.locationInWindow.x - activeSelection.initialPoint.x
    let deltaY = event.locationInWindow.y - activeSelection.initialPoint.y
    if !activeSelection.didDrag, hypot(deltaX, deltaY) > 2 {
      activeSelection.didDrag = true
    }
    guard activeSelection.didDrag else {
      self.activeSelection = activeSelection
      return true
    }

    let anchorFrame = anchorView.convert(anchorView.bounds, to: nil).insetBy(dx: -12, dy: -6)
    let targetView: OrgSyntaxTextView?
    if !activeSelection.crossedEditorBoundary,
       anchorFrame.contains(event.locationInWindow) {
      targetView = anchorView
    } else {
      targetView = targetTextView(in: anchorView.window, at: event.locationInWindow)
    }
    guard let targetView else {
      self.activeSelection = activeSelection
      return true
    }

    if targetView === anchorView, !activeSelection.crossedEditorBoundary {
      let targetLocation = characterLocation(
        in: anchorView,
        windowPoint: event.locationInWindow
      )
      let location = min(activeSelection.anchorLocation, targetLocation)
      let length = abs(targetLocation - activeSelection.anchorLocation)
      anchorView.setSelectedRange(NSRange(location: location, length: length))
      self.activeSelection = activeSelection
      return true
    }

    activeSelection.crossedEditorBoundary = true
    self.activeSelection = activeSelection
    selectTextAcrossEditors(
      anchorView: anchorView,
      anchorLocation: activeSelection.anchorLocation,
      targetView: targetView,
      targetLocation: characterLocation(in: targetView, windowPoint: event.locationInWindow)
    )
    return true
  }

  static func endSelection(from textView: OrgSyntaxTextView) -> Bool {
    guard let selectionState = activeSelection,
          let anchorView = selectionState.anchorView,
          anchorView === textView
    else {
      self.activeSelection = nil
      return false
    }
    activeSelection = nil
    if !selectionState.didDrag {
      textView.setSelectedRange(NSRange(location: selectionState.anchorLocation, length: 0))
    }
    return true
  }

  static func clearCrossEditorSelection(containing textView: OrgSyntaxTextView, preserving preservedView: OrgSyntaxTextView? = nil) {
    // Normal typing has no cross-editor selection to clear. Avoid walking and
    // sorting the entire AppKit view hierarchy for every key event; that work
    // is especially visible as input latency on Intel Macs.
    guard shouldTraverseForCrossEditorSelectionCleanup(
      hasActiveSelection: activeSelection != nil,
      selectedFragmentCount: selectedFragments.count
    ) else {
      return
    }
    for candidate in orderedTextViews(in: textView.window) {
      candidate.clearCrossEditorHighlight()
      guard candidate !== preservedView else { continue }
      if candidate.selectedRange().length > 0 {
        candidate.setSelectedRange(NSRange(location: 0, length: 0))
      }
    }
    selectedFragments = []
    activeSelection = nil
  }

  static func shouldTraverseForCrossEditorSelectionCleanup(
    hasActiveSelection: Bool,
    selectedFragmentCount: Int
  ) -> Bool {
    hasActiveSelection || selectedFragmentCount > 0
  }

  static func selectAllDocumentText(containing textView: OrgSyntaxTextView) -> Bool {
    let textViews = orderedDocumentTextViews(in: textView.window)
    guard !textViews.isEmpty else { return false }

    var nextFragments: [SelectionFragment] = []
    for view in textViews {
      if view.selectedRange().length > 0 {
        view.setSelectedRange(NSRange(location: 0, length: 0))
      }
      let length = view.textStorage?.length ?? 0
      let range = NSRange(location: 0, length: length)
      view.applyCrossEditorHighlight(range)
      if length > 0 {
        nextFragments.append(SelectionFragment(view: view, range: range))
      }
    }

    selectedFragments = nextFragments
    activeSelection = nil
    textView.window?.makeFirstResponder(textView)
    return !nextFragments.isEmpty
  }

  static func selectTextAcrossEditors(
    anchorView: OrgSyntaxTextView,
    anchorLocation: Int,
    targetView: OrgSyntaxTextView,
    targetLocation: Int
  ) {
    let textViews = orderedTextViews(in: anchorView.window)
    guard let anchorIndex = textViews.firstIndex(where: { $0 === anchorView }),
          let targetIndex = textViews.firstIndex(where: { $0 === targetView })
    else {
      return
    }

    let lowerIndex = min(anchorIndex, targetIndex)
    let upperIndex = max(anchorIndex, targetIndex)
    var nextFragments: [SelectionFragment] = []
    for (index, view) in textViews.enumerated() {
      if view.selectedRange().length > 0 {
        view.setSelectedRange(NSRange(location: 0, length: 0))
      }
      guard lowerIndex...upperIndex ~= index else {
        view.clearCrossEditorHighlight()
        continue
      }
      let range = selectionRange(
        for: view,
        index: index,
        anchorIndex: anchorIndex,
        anchorLocation: anchorLocation,
        targetIndex: targetIndex,
        targetLocation: targetLocation
      )
      view.applyCrossEditorHighlight(range)
      if range.length > 0 {
        nextFragments.append(SelectionFragment(view: view, range: range))
      }
    }
    selectedFragments = nextFragments
  }

  static func selectedText(containing textView: OrgSyntaxTextView) -> String? {
    guard let liveFragments = liveSelectedFragments(containing: textView) else {
      return nil
    }
    let selectedText = liveFragments.compactMap { view, range -> String? in
      let text = view.string
      guard range.length > 0,
            let swiftRange = Range(range, in: text)
      else {
        return nil
      }
      return String(text[swiftRange])
    }
    guard !selectedText.isEmpty else {
      return nil
    }
    return selectedText.joined(separator: "\n")
  }

  static func selectedDocumentFragments(
    containing textView: OrgSyntaxTextView
  ) -> [OrgSyntaxTextSelectionDocumentFragment]? {
    guard let liveFragments = liveSelectedFragments(containing: textView) else {
      return nil
    }

    let documentFragments = liveFragments.compactMap { view, range -> OrgSyntaxTextSelectionDocumentFragment? in
      guard let context = view.documentSelectionContext else { return nil }
      let text = view.string
      return OrgSyntaxTextSelectionDocumentFragment(
        context: context,
        editorRange: range,
        editorUTF16Length: view.textStorage?.length ?? (text as NSString).length,
        editorText: text
      )
    }
    guard documentFragments.count == liveFragments.count,
          !documentFragments.isEmpty
    else {
      return nil
    }
    return documentFragments
  }

  fileprivate static func moveCaretAcrossDocumentEditors(
    from textView: OrgSyntaxTextView,
    direction: OrgSyntaxTextBoundaryDirection,
    placement: OrgSyntaxTextBoundaryCaretPlacement
  ) -> Bool {
    guard textView.documentSelectionContext != nil else { return false }
    let textViews = orderedDocumentTextViews(in: textView.window)
    guard let currentIndex = textViews.firstIndex(where: { $0 === textView }) else {
      return false
    }

    let targetIndex: Int
    switch direction {
    case .previous:
      targetIndex = currentIndex - 1
    case .next:
      targetIndex = currentIndex + 1
    }
    guard textViews.indices.contains(targetIndex) else {
      return false
    }

    let targetView = textViews[targetIndex]
    clearCrossEditorSelection(containing: textView, preserving: targetView)
    targetView.window?.makeFirstResponder(targetView)
    let targetLength = targetView.textStorage?.length ?? 0
    let targetLocation: Int
    switch placement {
    case .start:
      targetLocation = 0
    case .end:
      targetLocation = targetLength
    }
    targetView.setSelectedRange(NSRange(location: targetLocation, length: 0))
    targetView.scrollRangeToVisible(NSRange(location: targetLocation, length: 0))
    return true
  }

  static func orderedTextViews(in window: NSWindow?) -> [OrgSyntaxTextView] {
    guard let contentView = window?.contentView else { return [] }
    var seen = Set<ObjectIdentifier>()
    let textViews = collectTextViews(in: contentView, seen: &seen)
      .filter { !$0.isHidden && $0.window === window && $0.isEditable }
    return textViews.sorted { lhs, rhs in
      let lhsFrame = lhs.convert(lhs.bounds, to: nil)
      let rhsFrame = rhs.convert(rhs.bounds, to: nil)
      if abs(lhsFrame.midY - rhsFrame.midY) > 0.5 {
        return lhsFrame.midY > rhsFrame.midY
      }
      return lhsFrame.minX < rhsFrame.minX
    }
  }

  private static func liveSelectedFragments(
    containing textView: OrgSyntaxTextView
  ) -> [(OrgSyntaxTextView, NSRange)]? {
    guard let window = textView.window else { return nil }
    let liveFragments = selectedFragments.compactMap { fragment -> (OrgSyntaxTextView, NSRange)? in
      guard let view = fragment.view,
            view.window === window
      else {
        return nil
      }
      return (view, fragment.range)
    }
    guard !liveFragments.isEmpty else { return nil }
    if liveFragments.contains(where: { $0.0 === textView }) {
      return liveFragments
    }
    guard textView.documentSelectionContext != nil,
          orderedDocumentTextViews(in: window).contains(where: { $0 === textView })
    else {
      return nil
    }
    return liveFragments
  }

  private static func orderedDocumentTextViews(in window: NSWindow?) -> [OrgSyntaxTextView] {
    orderedTextViews(in: window).filter { $0.documentSelectionContext != nil }
  }

  private static func collectTextViews(in view: NSView, seen: inout Set<ObjectIdentifier>) -> [OrgSyntaxTextView] {
    var result: [OrgSyntaxTextView] = []
    if let textView = view as? OrgSyntaxTextView {
      let identifier = ObjectIdentifier(textView)
      if !seen.contains(identifier) {
        seen.insert(identifier)
        result.append(textView)
      }
    }
    if let scrollView = view as? NSScrollView,
       let documentView = scrollView.documentView {
      result.append(contentsOf: collectTextViews(in: documentView, seen: &seen))
    }
    for subview in view.subviews {
      result.append(contentsOf: collectTextViews(in: subview, seen: &seen))
    }
    return result
  }

  private static func targetTextView(in window: NSWindow?, at windowPoint: NSPoint) -> OrgSyntaxTextView? {
    let textViews = orderedTextViews(in: window)
    if let containing = textViews.first(where: { view in
      view.convert(view.bounds, to: nil).insetBy(dx: -12, dy: -6).contains(windowPoint)
    }) {
      return containing
    }
    return textViews.min { lhs, rhs in
      distance(from: windowPoint, to: lhs.convert(lhs.bounds, to: nil))
        < distance(from: windowPoint, to: rhs.convert(rhs.bounds, to: nil))
    }
  }

  private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return hypot(dx, dy)
  }

  private static func selectionRange(
    for textView: OrgSyntaxTextView,
    index: Int,
    anchorIndex: Int,
    anchorLocation: Int,
    targetIndex: Int,
    targetLocation: Int
  ) -> NSRange {
    let length = textView.textStorage?.length ?? 0
    if anchorIndex == targetIndex {
      let start = min(anchorLocation, targetLocation)
      let end = max(anchorLocation, targetLocation)
      return NSRange(location: start, length: end - start)
    }

    if anchorIndex < targetIndex {
      if index == anchorIndex {
        return NSRange(location: anchorLocation, length: max(0, length - anchorLocation))
      }
      if index == targetIndex {
        return NSRange(location: 0, length: min(length, targetLocation))
      }
      return NSRange(location: 0, length: length)
    }

    if index == targetIndex {
      return NSRange(location: targetLocation, length: max(0, length - targetLocation))
    }
    if index == anchorIndex {
      return NSRange(location: 0, length: min(length, anchorLocation))
    }
    return NSRange(location: 0, length: length)
  }

  private static func characterLocation(in textView: OrgSyntaxTextView, event: NSEvent) -> Int {
    characterLocation(in: textView, windowPoint: event.locationInWindow)
  }

  private static func characterLocation(in textView: OrgSyntaxTextView, windowPoint: NSPoint) -> Int {
    let localPoint = textView.convert(windowPoint, from: nil)
    let length = textView.textStorage?.length ?? 0
    return min(max(0, textView.characterIndexForInsertion(at: localPoint)), length)
  }
}

/// The focused editor and document a deferred insertion belongs to.
///
/// Opening a modal panel takes focus from the editor, which checkpoints its
/// native buffer asynchronously. Text written into the SwiftUI binding after
/// the panel closes can then be overwritten by that checkpoint or by the next
/// buffer publication, so a `/image` link silently disappeared. Inserting
/// through the text view itself (with undo) goes through the same path as
/// typing and cannot be lost that way.
@MainActor
struct OrgSyntaxTextEditorInsertionTarget {
  private weak var textView: OrgSyntaxTextView?
  private let documentGeneration: UInt64?

  /// Captures the most recently focused editor that is still on screen.
  static func focused() -> OrgSyntaxTextEditorInsertionTarget? {
    guard let view = OrgSyntaxTextView.lastFocused, view.window != nil, view.isEditable else {
      return nil
    }
    return OrgSyntaxTextEditorInsertionTarget(
      textView: view,
      documentGeneration: view.pasteDocumentGeneration?()
    )
  }

  /// Whether the editor is still mounted and still shows the same document.
  var isCurrent: Bool {
    guard let textView, textView.window != nil, textView.isEditable else { return false }
    return textView.pasteDocumentGeneration?() == documentGeneration
  }

  /// Replaces `range` (clamped to the document), or the current selection
  /// when nil, with `text` as one undoable edit, and leaves the caret after
  /// it. When `expectedPrefix` is set, the replaced text must start with it.
  @discardableResult
  func replace(
    _ range: NSRange? = nil,
    with text: String,
    expectedPrefix: String? = nil
  ) -> Bool {
    guard isCurrent, let textView, let storage = textView.textStorage else { return false }
    let target = range ?? textView.selectedRange()
    let location = min(max(0, target.location), storage.length)
    let replacement = NSRange(
      location: location,
      length: min(max(0, target.length), storage.length - location)
    )
    if let expectedPrefix,
       !storage.attributedSubstring(from: replacement).string.hasPrefix(expectedPrefix) {
      return false
    }
    guard textView.shouldChangeText(in: replacement, replacementString: text) else { return false }
    storage.replaceCharacters(in: replacement, with: text)
    textView.didChangeText()
    textView.setSelectedRange(NSRange(location: location + (text as NSString).length, length: 0))
    textView.window?.makeFirstResponder(textView)
    return true
  }
}

struct OrgSyntaxTextEditorSelectionSnapshot: Equatable {
  let selectedRange: NSRange
  let sourceLine: Int?
  let localText: String
  let localTextRange: NSRange
}

/// Keys an inline completion panel can claim from the editor before the
/// editor applies its own Tab, Return, arrow, or Escape behavior.
enum OrgSyntaxTextEditorCompletionKey: Equatable {
  case accept
  case moveUp
  case moveDown
  case dismiss

  init?(selector: Selector, modifiers: NSEvent.ModifierFlags) {
    let relevant = modifiers.intersection([.shift, .option, .control, .command])
    switch selector {
    case #selector(NSResponder.insertTab(_:)),
         #selector(NSResponder.insertNewline(_:)):
      guard relevant.isEmpty else { return nil }
      self = .accept
    case #selector(NSResponder.moveUp(_:)):
      guard relevant.isEmpty else { return nil }
      self = .moveUp
    case #selector(NSResponder.moveDown(_:)):
      guard relevant.isEmpty else { return nil }
      self = .moveDown
    case #selector(NSResponder.cancelOperation(_:)):
      self = .dismiss
    default:
      return nil
    }
  }
}

enum OrgSyntaxTextEditorCompletionKeyResult: Equatable {
  case ignored
  case handled
  /// Replace a UTF-16 range of the editor text and place the caret after it.
  case replace(range: NSRange, text: String)
}

struct OrgSyntaxTextEditor: NSViewRepresentable {
  @Binding var text: String
  let monospaced: Bool
  let showsScrollers: Bool
  let textInset: NSSize
  let focusOnAppear: Bool
  let textPublishing: OrgSyntaxTextEditorTextPublishing
  let liveHighlighting: Bool
  let incrementalHighlighting: Bool
  let incrementalHighlightingDelayMilliseconds: Int
  let concealsSyntax: Bool
  let pasteAsOrgEnabled: (() -> Bool)?
  let orgWritingCommands: Bool
  let textChecking: OrgSyntaxTextCheckingMode
  let caretPublishingDelayMilliseconds: Int
  let semanticAnalysisDelayMilliseconds: Int
  let commandRequest: OrgSourceEditorCommandRequest?
  let semanticAnalyzer: ((String) async -> OrgSourceEditorSemanticSnapshot?)?
  let diagnostics: Binding<[Org2EditorDiagnostic]>?
  let onCommandStatus: ((String) -> Void)?
  let selection: Binding<NSRange>?
  let onSelectionSnapshot: ((OrgSyntaxTextEditorSelectionSnapshot) -> Void)?
  let onViewportSourceLine: ((Int) -> Void)?
  let onGutterBacklinks: ((Int) -> Void)?
  let isFocused: Binding<Bool>?
  let contentHeight: Binding<CGFloat>?
  let onLocalTextChange: ((String) -> Void)?
  let documentIdentity: String?
  let onCheckpointText: ((String) -> Void)?
  let documentGeneration: (() -> UInt64)?
  let bindingGeneration: (() -> UInt64)?
  let onTextPublicationConflict: ((String) -> Void)?
  let shouldPublishTextImmediately: ((String) -> Bool)?
  let onSaveCommand: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?
  let onSubmit: (() -> Bool)?
  let onSubmitContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?
  let onDeleteBackwardContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)?
  let documentSelectionContext: OrgSyntaxTextSelectionContext?
  let onDeleteDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment]) -> Bool)?
  let onReplaceDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment], String) -> Bool)?
  let completionKeyHandler: ((OrgSyntaxTextEditorCompletionKey, OrgSyntaxTextEditorSelectionSnapshot) -> OrgSyntaxTextEditorCompletionKeyResult)?
  /// Present only for Prose mode. It switches the typography and drives the
  /// reversible-prose presentation over the same native text view.
  let proseController: OrgProseEditorController?
  /// A code, markup, config, or data language from the shared language table.
  /// When set, the editor highlights the text as that language instead of Org.
  let codeLanguage: String?

  var isProse: Bool { proseController != nil }

  init(
    text: Binding<String>,
    monospaced: Bool = false,
    showsScrollers: Bool = true,
    textInset: NSSize = NSSize(width: 8, height: 8),
    focusOnAppear: Bool = false,
    textPublishing: OrgSyntaxTextEditorTextPublishing = .immediate,
    liveHighlighting: Bool = true,
    incrementalHighlighting: Bool = false,
    incrementalHighlightingDelayMilliseconds: Int = 0,
    concealsSyntax: Bool = true,
    orgWritingCommands: Bool = false,
    pasteAsOrgEnabled: (() -> Bool)? = nil,
    textChecking: OrgSyntaxTextCheckingMode = .disabled,
    caretPublishingDelayMilliseconds: Int = 0,
    semanticAnalysisDelayMilliseconds: Int = 180,
    commandRequest: OrgSourceEditorCommandRequest? = nil,
    semanticAnalyzer: ((String) async -> OrgSourceEditorSemanticSnapshot?)? = nil,
    diagnostics: Binding<[Org2EditorDiagnostic]>? = nil,
    onCommandStatus: ((String) -> Void)? = nil,
    selection: Binding<NSRange>? = nil,
    onSelectionSnapshot: ((OrgSyntaxTextEditorSelectionSnapshot) -> Void)? = nil,
    onViewportSourceLine: ((Int) -> Void)? = nil,
    onGutterBacklinks: ((Int) -> Void)? = nil,
    isFocused: Binding<Bool>? = nil,
    contentHeight: Binding<CGFloat>? = nil,
    onLocalTextChange: ((String) -> Void)? = nil,
    documentIdentity: String? = nil,
    onCheckpointText: ((String) -> Void)? = nil,
    documentGeneration: (() -> UInt64)? = nil,
    bindingGeneration: (() -> UInt64)? = nil,
    onTextPublicationConflict: ((String) -> Void)? = nil,
    shouldPublishTextImmediately: ((String) -> Bool)? = nil,
    onSaveCommand: ((OrgSyntaxTextEditorSubmitContext) -> Bool)? = nil,
    onSubmit: (() -> Bool)? = nil,
    onSubmitContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)? = nil,
    onDeleteBackwardContext: ((OrgSyntaxTextEditorSubmitContext) -> Bool)? = nil,
    documentSelectionContext: OrgSyntaxTextSelectionContext? = nil,
    onDeleteDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment]) -> Bool)? = nil,
    onReplaceDocumentSelection: (([OrgSyntaxTextSelectionDocumentFragment], String) -> Bool)? = nil,
    completionKeyHandler: ((OrgSyntaxTextEditorCompletionKey, OrgSyntaxTextEditorSelectionSnapshot) -> OrgSyntaxTextEditorCompletionKeyResult)? = nil,
    proseController: OrgProseEditorController? = nil,
    codeLanguage: String? = nil
  ) {
    _text = text
    self.codeLanguage = codeLanguage
    self.monospaced = monospaced
    self.showsScrollers = showsScrollers
    self.textInset = textInset
    self.focusOnAppear = focusOnAppear
    self.textPublishing = textPublishing
    self.liveHighlighting = liveHighlighting
    self.incrementalHighlighting = incrementalHighlighting
    self.incrementalHighlightingDelayMilliseconds = incrementalHighlightingDelayMilliseconds
    self.concealsSyntax = concealsSyntax
    self.orgWritingCommands = orgWritingCommands
    self.pasteAsOrgEnabled = pasteAsOrgEnabled
    self.textChecking = textChecking
    self.caretPublishingDelayMilliseconds = caretPublishingDelayMilliseconds
    self.semanticAnalysisDelayMilliseconds = semanticAnalysisDelayMilliseconds
    self.commandRequest = commandRequest
    self.semanticAnalyzer = semanticAnalyzer
    self.diagnostics = diagnostics
    self.onCommandStatus = onCommandStatus
    self.selection = selection
    self.onSelectionSnapshot = onSelectionSnapshot
    self.onViewportSourceLine = onViewportSourceLine
    self.onGutterBacklinks = onGutterBacklinks
    self.isFocused = isFocused
    self.contentHeight = contentHeight
    self.onLocalTextChange = onLocalTextChange
    self.documentIdentity = documentIdentity
    self.onCheckpointText = onCheckpointText
    self.documentGeneration = documentGeneration
    self.bindingGeneration = bindingGeneration
    self.onTextPublicationConflict = onTextPublicationConflict
    self.shouldPublishTextImmediately = shouldPublishTextImmediately
    self.onSaveCommand = onSaveCommand
    self.onSubmit = onSubmit
    self.onSubmitContext = onSubmitContext
    self.onDeleteBackwardContext = onDeleteBackwardContext
    self.documentSelectionContext = documentSelectionContext
    self.onDeleteDocumentSelection = onDeleteDocumentSelection
    self.onReplaceDocumentSelection = onReplaceDocumentSelection
    self.completionKeyHandler = completionKeyHandler
    self.proseController = proseController
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  /// Flushes every mounted editor's unpublished text synchronously.
  ///
  /// Owners must call this before replacing navigation/editing state. AppKit
  /// teardown can happen after SwiftUI has already changed that state, which
  /// is too late for an outgoing editor to persist its draft safely.
  @MainActor
  @discardableResult
  static func flushPendingTextChanges() -> Int {
    Coordinator.flushRegisteredTextChanges()
  }

  @MainActor
  @discardableResult
  static func checkpointPendingTextChanges() -> Set<String> {
    Coordinator.checkpointRegisteredTextChanges()
  }

  @MainActor
  static func waitForPendingTextCheckpoints() async {
    await Coordinator.waitForPendingTextCheckpoints()
  }

  @MainActor
  @discardableResult
  static func publishPendingTextChanges() -> Int {
    Coordinator.publishRegisteredTextChanges()
  }

  @MainActor
  static var hasPendingTextChanges: Bool {
    Coordinator.hasRegisteredPendingTextChanges
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = showsScrollers
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = showsScrollers
    scrollView.borderType = .noBorder

    let textView = OrgSyntaxTextView()
    textView.delegate = context.coordinator
    textView.pasteAsOrgEnabled = pasteAsOrgEnabled
    textView.pasteDocumentIdentity = documentIdentity
    textView.pasteDocumentGeneration = documentGeneration
    textView.documentSelectionContext = documentSelectionContext
    textView.onSaveCommand = onSaveCommand
    textView.onDeferredSaveCommand = { [weak coordinator = context.coordinator, weak textView] in
      guard let coordinator, let textView else { return false }
      return coordinator.requestExplicitSaveCheckpoint(from: textView)
    }
    textView.onDeleteDocumentSelection = onDeleteDocumentSelection
    textView.onReplaceDocumentSelection = onReplaceDocumentSelection
    textView.onSourceEditorCommand = { [weak coordinator = context.coordinator] command, textView in
      coordinator?.performSourceEditorCommand(command, in: textView) == true
    }
    textView.onMouseSelectionEnded = { [weak coordinator = context.coordinator] textView in
      coordinator?.mouseSelectionDidEnd(in: textView)
    }
    textView.onWindowAttachmentChanged = { [weak coordinator = context.coordinator] textView in
      coordinator?.attach(to: textView)
    }
    textView.onLifecycleBoundary = { [weak coordinator = context.coordinator] textView in
      coordinator?.requestLifecycleCheckpoint(from: textView)
    }
    context.coordinator.attach(to: textView)
    proseController?.attach(to: textView)
    textView.drawsBackground = false
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    Self.configureNativeFind(in: textView)
    textView.font = OrgSyntaxHighlighter.baseFont(monospaced: monospaced, prose: isProse)
    textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: monospaced, prose: isProse)
    // Configure the empty text view first so NSTextView gives inserted source
    // its base attributes as it creates storage. Applying `font` or resetting
    // attributes after this assignment traverses a multi-megabyte document on
    // the main thread before the first frame.
    context.coordinator.isApplyingProgrammaticChange = true
    textView.string = text
    context.coordinator.isApplyingProgrammaticChange = false
    Self.configureTextChecking(
      textChecking,
      in: textView,
      utf16Length: textView.textStorage?.length
    )
    textView.textContainerInset = textInset
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    // Scrolling editors do not need TextKit to lay out an entire large file
    // before accepting the next key. Inline editors that publish their full
    // content height deliberately keep contiguous layout.
    textView.layoutManager?.allowsNonContiguousLayout = Self.shouldAllowNonContiguousLayout(
      showsScrollers: showsScrollers,
      measuresContentHeight: contentHeight != nil
    )
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    scrollView.documentView = textView
    if orgWritingCommands {
      let gutter = OrgSourceEditorGutterView(scrollView: scrollView, textView: textView)
      gutter.performAction = { [weak coordinator = context.coordinator, weak textView] action in
        guard let textView else { return }
        coordinator?.performGutterAction(action, in: textView)
      }
      scrollView.verticalRulerView = gutter
      scrollView.hasVerticalRuler = true
      scrollView.rulersVisible = true
      context.coordinator.gutterView = gutter
    }
    context.coordinator.observeScrolling(of: scrollView, textView: textView)
    context.coordinator.recordKnownText(text, utf16Length: textView.textStorage?.length)
    context.coordinator.scheduleLineIndexReset(text: text)
    context.coordinator.applyHighlighting(to: textView)
    context.coordinator.scheduleSemanticAnalysis(
      for: textView,
      expectedText: text,
      delayMilliseconds: Coordinator.initialSemanticAnalysisDelayMilliseconds(
        utf16Length: textView.textStorage?.length ?? 0,
        configuredDelayMilliseconds: semanticAnalysisDelayMilliseconds
      )
    )
    context.coordinator.publishContentHeight(for: textView)
    if let selection {
      let requestedSelection = Self.clampedRange(
        selection.wrappedValue,
        utf16Length: textView.textStorage?.length ?? OrgSyntaxHighlighter.utf16Length(of: text)
      )
      textView.setSelectedRange(requestedSelection)
      DispatchQueue.main.async { [weak textView] in
        textView?.scrollRangeToVisible(requestedSelection)
      }
    }
    context.coordinator.applyFocusRequestIfNeeded(to: textView, enabled: focusOnAppear)
    proseController?.textWasReplaced()
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? OrgSyntaxTextView else {
      context.coordinator.updateParent(self)
      return
    }
    // SwiftUI can replace the bound document while a large native-buffer
    // publication is still pending. Keep the outgoing value-type parent long
    // enough to route that checkpoint through its binding, callbacks, and
    // document identity rather than whichever document is arriving now.
    let pendingTextOwner = context.coordinator.updateParent(self)
    textView.pasteAsOrgEnabled = pasteAsOrgEnabled
    textView.pasteDocumentIdentity = documentIdentity
    textView.pasteDocumentGeneration = documentGeneration
    textView.documentSelectionContext = documentSelectionContext
    textView.onSaveCommand = onSaveCommand
    textView.onDeferredSaveCommand = { [weak coordinator = context.coordinator, weak textView] in
      guard let coordinator, let textView else { return false }
      return coordinator.requestExplicitSaveCheckpoint(from: textView)
    }
    textView.onDeleteDocumentSelection = onDeleteDocumentSelection
    textView.onReplaceDocumentSelection = onReplaceDocumentSelection
    textView.onSourceEditorCommand = { [weak coordinator = context.coordinator] command, textView in
      coordinator?.performSourceEditorCommand(command, in: textView) == true
    }
    textView.onMouseSelectionEnded = { [weak coordinator = context.coordinator] textView in
      coordinator?.mouseSelectionDidEnd(in: textView)
    }
    textView.onWindowAttachmentChanged = { [weak coordinator = context.coordinator] textView in
      coordinator?.attach(to: textView)
    }
    textView.onLifecycleBoundary = { [weak coordinator = context.coordinator] textView in
      coordinator?.requestLifecycleCheckpoint(from: textView)
    }
    context.coordinator.attach(to: textView)
    proseController?.attach(to: textView)

    var currentUTF16Length = textView.textStorage?.length
    var editorText: String?
    var appliesAuthoritativeExternalText = false
    if context.coordinator.hasUnpublishedLocalText,
       context.coordinator.hasExternalBoundTextChange(text) {
      let resolved = context.coordinator.resolvePendingLocalText(
        beforeApplyingExternalText: text,
        from: textView,
        ownedBy: pendingTextOwner
      )
      editorText = resolved
      appliesAuthoritativeExternalText = resolved == nil
    }
    if !context.coordinator.hasPendingLocalText {
      if editorText == nil {
        let cachedEditorText = context.coordinator.knownText(matchingUTF16Length: currentUTF16Length)
        editorText = cachedEditorText ?? textView.string
        if cachedEditorText == nil, let editorText {
          context.coordinator.recordKnownText(editorText, utf16Length: currentUTF16Length)
        }
      }
    }
    var appliedProgrammaticText = false
    var focusedVisibleOriginBeforeProgrammaticText: NSPoint?
    var preferredSelectionAfterProgrammaticText: NSRange?
    if appliesAuthoritativeExternalText || editorText.map({ currentEditorText in
      Self.shouldApplyProgrammaticText(
        editorText: currentEditorText,
        boundText: text,
        hasPendingLocalText: context.coordinator.hasPendingLocalText
      )
    }) == true {
      let wasFirstResponder = textView.window?.firstResponder === textView
      if wasFirstResponder {
        focusedVisibleOriginBeforeProgrammaticText = Coordinator.visibleOrigin(of: textView)
      }
      preferredSelectionAfterProgrammaticText = Coordinator.preferredSelectionAfterProgrammaticTextUpdate(
        requestedSelection: selection?.wrappedValue,
        currentSelection: textView.selectedRange(),
        isFirstResponder: wasFirstResponder,
        updatedUTF16Length: OrgSyntaxHighlighter.utf16Length(of: text)
      )
      context.coordinator.cancelDeferredHighlighting()
      context.coordinator.cancelDeferredTextPublishing()
      context.coordinator.clearSemanticState()
      context.coordinator.isApplyingProgrammaticChange = true
      textView.string = text
      context.coordinator.isApplyingProgrammaticChange = false
      context.coordinator.resetBufferSession(to: text)
      textView.undoManager?.removeAllActions()
      currentUTF16Length = textView.textStorage?.length
      if let preferredSelectionAfterProgrammaticText {
        textView.setSelectedRange(preferredSelectionAfterProgrammaticText)
      }
      context.coordinator.recordKnownText(text, utf16Length: currentUTF16Length)
      context.coordinator.scheduleLineIndexReset(text: text)
      context.coordinator.invalidateHighlighting()
      editorText = text
      appliedProgrammaticText = true
      context.coordinator.resetViewportSourceLinePublishing()
      proseController?.textWasReplaced()
    }

    if let selection {
      let requestedSelection = preferredSelectionAfterProgrammaticText ?? Self.clampedRange(
        selection.wrappedValue,
        utf16Length: currentUTF16Length
          ?? editorText.map { OrgSyntaxHighlighter.utf16Length(of: $0) }
          ?? 0
      )
      let currentSelection = textView.selectedRange()
      if currentSelection != requestedSelection,
         Coordinator.shouldApplyExternalSelection(
          requestedSelection: requestedSelection,
          currentSelection: currentSelection,
          isFirstResponder: textView.window?.firstResponder === textView,
          didApplyProgrammaticText: appliedProgrammaticText
        ) {
        textView.setSelectedRange(requestedSelection)
        if focusedVisibleOriginBeforeProgrammaticText == nil {
          textView.scrollRangeToVisible(requestedSelection)
        }
      }
    }
    context.coordinator.applyFocusRequestIfNeeded(to: textView, enabled: focusOnAppear)
    Self.configureTextChecking(
      textChecking,
      in: textView,
      utf16Length: currentUTF16Length
    )

    if appliedProgrammaticText || !context.coordinator.hasDeferredHighlightingForCurrentBuffer {
      context.coordinator.applyHighlightingIfNeeded(to: textView, currentText: editorText)
    }
    Coordinator.restoreVisibleOrigin(focusedVisibleOriginBeforeProgrammaticText, of: textView)
    context.coordinator.performRequestedCommandIfNeeded(commandRequest, in: textView)
    context.coordinator.publishContentHeight(for: textView)
  }

  static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
    guard let textView = scrollView.documentView as? OrgSyntaxTextView else { return }
    coordinator.prepareForDismantle(textView)
    coordinator.detachProseController(from: textView)
    textView.delegate = nil
    textView.pasteAsOrgEnabled = nil
    textView.pastePreviewController?.cancel()
    textView.onSaveCommand = nil
    textView.onDeferredSaveCommand = nil
    textView.onDeleteDocumentSelection = nil
    textView.onReplaceDocumentSelection = nil
    textView.onSourceEditorCommand = nil
    textView.onMouseSelectionEnded = nil
    textView.onWindowAttachmentChanged = nil
    textView.onLifecycleBoundary = nil
  }

  private static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
    clampedRange(range, utf16Length: OrgSyntaxHighlighter.utf16Length(of: text))
  }

  static func clampedRange(_ range: NSRange, utf16Length length: Int) -> NSRange {
    let location = min(max(0, range.location), length)
    return NSRange(
      location: location,
      length: min(max(0, range.length), length - location)
    )
  }

  static func shouldApplyProgrammaticText(
    editorText: String,
    boundText: String,
    hasPendingLocalText: Bool
  ) -> Bool {
    editorText != boundText && !hasPendingLocalText
  }

  static func configureTextChecking(
    _ mode: OrgSyntaxTextCheckingMode,
    in textView: NSTextView,
    utf16Length: Int? = nil
  ) {
    let isEnabled = mode == .spellingAndGrammar
      && shouldEnableContinuousTextChecking(utf16Length: utf16Length)
    if textView.isContinuousSpellCheckingEnabled != isEnabled {
      textView.isContinuousSpellCheckingEnabled = isEnabled
    }
    if textView.isGrammarCheckingEnabled != isEnabled {
      textView.isGrammarCheckingEnabled = isEnabled
    }
    let checkingTypes = isEnabled
      ? NSTextCheckingResult.CheckingType.spelling.rawValue
        | NSTextCheckingResult.CheckingType.grammar.rawValue
      : 0
    if textView.enabledTextCheckingTypes != checkingTypes {
      textView.enabledTextCheckingTypes = checkingTypes
    }
  }

  static let continuousTextCheckingUTF16Limit = 50_000

  static func shouldAllowNonContiguousLayout(
    showsScrollers: Bool,
    measuresContentHeight: Bool
  ) -> Bool {
    showsScrollers && !measuresContentHeight
  }

  static func shouldEnableContinuousTextChecking(utf16Length: Int?) -> Bool {
    guard let utf16Length else { return true }
    return utf16Length <= continuousTextCheckingUTF16Limit
  }

  static func configureNativeFind(in textView: NSTextView) {
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    private final class WeakLifecycleCoordinator {
      weak var value: Coordinator?

      init(_ value: Coordinator) {
        self.value = value
      }
    }

    private static var lifecycleCoordinators: [UUID: WeakLifecycleCoordinator] = [:]
    private static var pendingTextCheckpointTasks: [UUID: Task<Void, Never>] = [:]
    private static var textCheckpointTailsByDocument: [
      String: (identifier: UUID, task: Task<Void, Never>)
    ] = [:]
    var parent: OrgSyntaxTextEditor
    private let lifecycleID = UUID()
    var isApplyingProgrammaticChange = false
    private var lastHighlightedText: String?
    private var lastHighlightedMonospaced: Bool?
    private var lastHighlightedConcealsSyntax: Bool?
    private var lastHighlightedLiveHighlighting: Bool?
    private var hasHighlightedText = false
    private var deferredHighlightText: String?
    private var deferredHighlightMonospaced: Bool?
    private var deferredHighlightTask: Task<Void, Never>?
    private var deferredIncrementalHighlightText: String?
    private var deferredIncrementalHighlightGeneration: Int?
    private var deferredIncrementalHighlightRange: NSRange?
    private var deferredIncrementalHighlightTask: Task<Void, Never>?
    private var deferredTextPublishText: String?
    private var deferredTextPublishUTF16Length: Int?
    private var deferredTextPublishTask: Task<Void, Never>?
    private var deferredTextPublishGeneration = 0
    private var deferredCaretPublishRange: NSRange?
    private var deferredCaretPublishTask: Task<Void, Never>?
    private var deferredCaretPublishGeneration = 0
    private var lastPublishedSelectionSnapshot: OrgSyntaxTextEditorSelectionSnapshot?
    nonisolated(unsafe) private var deferredViewportPublishWorkItem: DispatchWorkItem?
    nonisolated(unsafe) private var deferredScrollRefreshWorkItem: DispatchWorkItem?
    private var deferredContentHeightPublishTask: Task<Void, Never>?
    private var deferredContentHeightPublishGeneration = 0
    private var lastPublishedViewportSourceLine: Int?
    private var lastKnownText: String?
    private var lastKnownTextUTF16Length: Int?
    private var lastKnownTextGeneration: Int?
    private var lastObservedBoundText: String
    private var localTextGeneration = 0
    private(set) var hasUnpublishedLocalText = false
    private var detachedTextCheckpointCount = 0
    var hasPendingLocalText: Bool {
      hasUnpublishedLocalText || detachedTextCheckpointCount > 0
    }
    private(set) var fullDocumentSnapshotCount = 0
    private(set) var mainActorFullDocumentSnapshotCount = 0
    private let bufferSession: OrgSyntaxTextBufferSession
    private var lineIndex = OrgSourceLineIndex()
    private var isLineIndexReady = true
    private var lineIndexBuildGeneration = 0
    private var lineIndexBuildTask: Task<Void, Never>?
    private var pendingLineIndexEdits: [(range: NSRange, replacement: String)] = []
    private var hasAppliedFocusRequest = false
    private var pendingEditedRange: NSRange?
    private var semanticAnalysisTask: Task<Void, Never>?
    private var semanticAnalysisGeneration = 0
    private var semanticSnapshot: OrgSourceEditorSemanticSnapshot?
    private var semanticSnapshotTextGeneration: Int?
    private var semanticHeadlineRegionsByStartLine: [Int: OrgSourceSemanticRegion] = [:]
    private var semanticBackgroundRegions: [OrgSourceSemanticRegion] = []
    private var semanticDiagnosticsByLine: [Org2EditorDiagnostic] = []
    private var semanticPresentationViewportLines: ClosedRange<Int>?
    var deferredTextSnapshotForTesting: (() async -> OrgSyntaxTextBufferSession.Snapshot)?
    var checkpointSnapshotForTesting: ((OrgSyntaxTextBufferSession.Capture) async -> OrgSyntaxTextBufferSession.Snapshot)?
    private var foldedHeadlineStartLines = Set<Int>()
    private var foldPresentationRanges: [NSRange] = []
    private var diagnosticPresentationRanges: [NSRange] = []
    private var semanticPresentationRanges: [NSRange] = []
    private var lastCommandRequestID: Int?
    private var observedClipView: NSClipView?
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
    private weak var activeTextView: NSTextView?
    private var viewportHighlightedCharacterIndexes = IndexSet()
    private var viewportHighlightUTF16Length: Int?
    private var viewportHighlightMonospaced: Bool?
    private var viewportHighlightConcealsSyntax: Bool?
    private var isApplyingViewportHighlighting = false
    weak var gutterView: OrgSourceEditorGutterView?

    init(parent: OrgSyntaxTextEditor) {
      self.parent = parent
      lastObservedBoundText = parent.text
      bufferSession = OrgSyntaxTextBufferSession(text: parent.text)
      super.init()
    }

    @discardableResult
    func updateParent(_ next: OrgSyntaxTextEditor) -> OrgSyntaxTextEditor {
      let previous = parent
      let presentationChanged = parent.monospaced != next.monospaced
        || parent.isProse != next.isProse
        || parent.concealsSyntax != next.concealsSyntax
        || parent.liveHighlighting != next.liveHighlighting
      let documentChanged = parent.documentIdentity != next.documentIdentity
      parent = next
      if presentationChanged {
        cancelDeferredHighlighting()
        invalidateHighlighting()
      }
      if documentChanged {
        lastPublishedSelectionSnapshot = nil
      }
      return previous
    }

    deinit {
      deferredHighlightTask?.cancel()
      deferredIncrementalHighlightTask?.cancel()
      deferredTextPublishTask?.cancel()
      deferredCaretPublishTask?.cancel()
      deferredViewportPublishWorkItem?.cancel()
      deferredScrollRefreshWorkItem?.cancel()
      deferredContentHeightPublishTask?.cancel()
      semanticAnalysisTask?.cancel()
      lineIndexBuildTask?.cancel()
      if let scrollObserver {
        NotificationCenter.default.removeObserver(scrollObserver)
      }
      let identifier = lifecycleID
      MainActor.assumeIsolated {
        Self.unregisterFromLifecycleFlush(id: identifier)
      }
    }

    func attach(to textView: NSTextView) {
      if activeTextView !== textView,
         activeTextView?.textStorage?.delegate === self {
        activeTextView?.textStorage?.delegate = nil
      }
      activeTextView = textView
      if textView.textStorage?.delegate !== self {
        textView.textStorage?.delegate = self
      }
      Self.registerForLifecycleFlush(self)
    }

    func prepareForDismantle(_ textView: NSTextView) {
      _ = checkpointActiveTextViewIfNeeded()
      // SwiftUI can dismantle the editor while its hosting graph is being
      // destroyed. Do not publish selection state back into that graph.
      cancelDeferredCaretPublishing()
      cancelDeferredHighlighting()
      deferredContentHeightPublishTask?.cancel()
      deferredContentHeightPublishTask = nil
      semanticAnalysisTask?.cancel()
      semanticAnalysisTask = nil
      if textView.textStorage?.delegate === self {
        textView.textStorage?.delegate = nil
      }
      if activeTextView === textView {
        activeTextView = nil
      }
      if let scrollObserver {
        NotificationCenter.default.removeObserver(scrollObserver)
        self.scrollObserver = nil
      }
      deferredScrollRefreshWorkItem?.cancel()
      deferredScrollRefreshWorkItem = nil
      observedClipView = nil
      Self.unregisterFromLifecycleFlush(id: lifecycleID)
    }

    @discardableResult
    private func flushActiveTextViewIfNeeded() -> Bool {
      guard let activeTextView else { return false }
      let didFlushText = hasUnpublishedLocalText
      if didFlushText {
        flushPendingTextPublishingIfNeeded(from: activeTextView)
      }
      flushCaretPublishing(from: activeTextView)
      return didFlushText
    }

    @discardableResult
    private func checkpointActiveTextViewIfNeeded() -> Bool {
      guard hasUnpublishedLocalText else { return false }
      cancelDeferredTextPublishing()

      let checkpointID = UUID()
      let session = bufferSession
      let capture = session.capture()
      let selection = activeTextView?.selectedRange() ?? NSRange(location: 0, length: 0)
      let directCheckpoint = parent.onCheckpointText
      let localChange = parent.onLocalTextChange
      let saveHandler = parent.onSaveCommand
      let binding = parent.$text
      let boundary = textPublicationBoundary()
      let conflictHandler = parent.onTextPublicationConflict
      let documentGeneration = parent.documentGeneration
      let expectedDocumentGeneration = documentGeneration?()
      let orderingKey = parent.documentIdentity ?? lifecycleID.uuidString
      let predecessor = Self.textCheckpointTailsByDocument[orderingKey]?.task
      let snapshotProvider = checkpointSnapshotForTesting

      // The persistent piece tree makes this a point-in-time capture without
      // copying the native NSTextStorage. A new edit flips the dirty bit again
      // and receives its own later checkpoint.
      hasUnpublishedLocalText = false
      detachedTextCheckpointCount += 1
      let task = Task { @MainActor [weak self, predecessor] in
        if let predecessor {
          await predecessor.value
        }
        self?.fullDocumentSnapshotCount += 1
        let snapshot = await Self.materializeCheckpoint(
          session: session,
          capture: capture,
          provider: snapshotProvider
        )
        defer {
          self?.detachedTextCheckpointCount = max(
            0,
            (self?.detachedTextCheckpointCount ?? 1) - 1
          )
          Self.pendingTextCheckpointTasks.removeValue(forKey: checkpointID)
          if Self.textCheckpointTailsByDocument[orderingKey]?.identifier == checkpointID {
            Self.textCheckpointTailsByDocument.removeValue(forKey: orderingKey)
          }
        }
        guard snapshot.revision == capture.revision else { return }

        let bindingWasCurrent = Self.bindingIsCurrent(binding, for: boundary)
        let documentWasCurrent = Self.documentIsCurrent(
          generation: documentGeneration,
          expected: expectedDocumentGeneration
        )

        if let directCheckpoint {
          if bindingWasCurrent {
            binding.wrappedValue = snapshot.text
            if session.revision == snapshot.revision {
              self?.recordKnownText(
                snapshot.text,
                utf16Length: capture.utf16Length,
                isPublished: true
              )
            }
          }
          directCheckpoint(snapshot.text)
        } else if let saveHandler {
          guard documentWasCurrent else {
            conflictHandler?(snapshot.text)
            return
          }
          localChange?(snapshot.text)
          binding.wrappedValue = snapshot.text
          if session.revision == snapshot.revision {
            self?.recordKnownText(
              snapshot.text,
              utf16Length: capture.utf16Length,
              isPublished: true
            )
          }
          _ = saveHandler(OrgSyntaxTextEditorSubmitContext(
            text: snapshot.text,
            selectedRange: selection
          ))
        } else if bindingWasCurrent {
          localChange?(snapshot.text)
          binding.wrappedValue = snapshot.text
          if session.revision == snapshot.revision {
            self?.recordKnownText(
              snapshot.text,
              utf16Length: capture.utf16Length,
              isPublished: true
            )
          }
        } else {
          conflictHandler?(snapshot.text)
        }
      }
      Self.pendingTextCheckpointTasks[checkpointID] = task
      Self.textCheckpointTailsByDocument[orderingKey] = (checkpointID, task)
      return true
    }

    @discardableResult
    private func publishOwnerTextIfNeeded() -> Bool {
      guard hasUnpublishedLocalText else { return false }
      cancelDeferredTextPublishing()

      let checkpointID = UUID()
      let session = bufferSession
      let capture = session.capture()
      let localChange = parent.onLocalTextChange
      let binding = parent.$text
      let conflictHandler = parent.onTextPublicationConflict
      let documentGeneration = parent.documentGeneration
      let expectedDocumentGeneration = documentGeneration?()
      let orderingKey = parent.documentIdentity ?? lifecycleID.uuidString
      let predecessor = Self.textCheckpointTailsByDocument[orderingKey]?.task
      let snapshotProvider = checkpointSnapshotForTesting

      hasUnpublishedLocalText = false
      detachedTextCheckpointCount += 1
      let task = Task { @MainActor [weak self, predecessor] in
        if let predecessor {
          await predecessor.value
        }
        self?.fullDocumentSnapshotCount += 1
        let snapshot = await Self.materializeCheckpoint(
          session: session,
          capture: capture,
          provider: snapshotProvider
        )
        defer {
          self?.detachedTextCheckpointCount = max(
            0,
            (self?.detachedTextCheckpointCount ?? 1) - 1
          )
          Self.pendingTextCheckpointTasks.removeValue(forKey: checkpointID)
          if Self.textCheckpointTailsByDocument[orderingKey]?.identifier == checkpointID {
            Self.textCheckpointTailsByDocument.removeValue(forKey: orderingKey)
          }
        }
        guard snapshot.revision == capture.revision else { return }
        guard Self.documentIsCurrent(
          generation: documentGeneration,
          expected: expectedDocumentGeneration
        ) else {
          conflictHandler?(snapshot.text)
          return
        }
        localChange?(snapshot.text)
        binding.wrappedValue = snapshot.text
        if session.revision == snapshot.revision {
          self?.recordKnownText(
            snapshot.text,
            utf16Length: capture.utf16Length,
            isPublished: true
          )
        }
      }
      Self.pendingTextCheckpointTasks[checkpointID] = task
      Self.textCheckpointTailsByDocument[orderingKey] = (checkpointID, task)
      return true
    }

    func requestExplicitSaveCheckpoint(from textView: NSTextView) -> Bool {
      guard let saveHandler = parent.onSaveCommand else { return false }
      cancelDeferredTextPublishing()

      let checkpointID = UUID()
      let session = bufferSession
      let capture = session.capture()
      let selection = textView.selectedRange()
      let localChange = parent.onLocalTextChange
      let binding = parent.$text
      let conflictHandler = parent.onTextPublicationConflict
      let documentGeneration = parent.documentGeneration
      let expectedDocumentGeneration = documentGeneration?()
      let orderingKey = parent.documentIdentity ?? lifecycleID.uuidString
      let predecessor = Self.textCheckpointTailsByDocument[orderingKey]?.task
      let snapshotProvider = checkpointSnapshotForTesting
      hasUnpublishedLocalText = false
      detachedTextCheckpointCount += 1

      let task = Task { @MainActor [weak self, predecessor] in
        if let predecessor {
          await predecessor.value
        }
        self?.fullDocumentSnapshotCount += 1
        let snapshot = await Self.materializeCheckpoint(
          session: session,
          capture: capture,
          provider: snapshotProvider
        )
        defer {
          self?.detachedTextCheckpointCount = max(
            0,
            (self?.detachedTextCheckpointCount ?? 1) - 1
          )
          Self.pendingTextCheckpointTasks.removeValue(forKey: checkpointID)
          if Self.textCheckpointTailsByDocument[orderingKey]?.identifier == checkpointID {
            Self.textCheckpointTailsByDocument.removeValue(forKey: orderingKey)
          }
        }
        guard snapshot.revision == capture.revision else { return }
        guard Self.documentIsCurrent(
          generation: documentGeneration,
          expected: expectedDocumentGeneration
        ) else {
          conflictHandler?(snapshot.text)
          return
        }
        localChange?(snapshot.text)
        binding.wrappedValue = snapshot.text
        if session.revision == snapshot.revision {
          self?.recordKnownText(
            snapshot.text,
            utf16Length: capture.utf16Length,
            isPublished: true
          )
        }
        _ = saveHandler(OrgSyntaxTextEditorSubmitContext(
          text: snapshot.text,
          selectedRange: selection
        ))
      }
      Self.pendingTextCheckpointTasks[checkpointID] = task
      Self.textCheckpointTailsByDocument[orderingKey] = (checkpointID, task)
      return true
    }

    @discardableResult
    static func checkpointRegisteredTextChanges() -> Set<String> {
      pruneLifecycleCoordinators()
      var identities = Set<String>()
      for box in Array(lifecycleCoordinators.values) {
        guard let coordinator = box.value,
              coordinator.hasUnpublishedLocalText
        else { continue }
        if let identity = coordinator.parent.documentIdentity {
          identities.insert(identity)
        }
        _ = coordinator.checkpointActiveTextViewIfNeeded()
      }
      return identities
    }

    @discardableResult
    static func publishRegisteredTextChanges() -> Int {
      pruneLifecycleCoordinators()
      var publishCount = 0
      for box in Array(lifecycleCoordinators.values) {
        if box.value?.publishOwnerTextIfNeeded() == true {
          publishCount += 1
        }
      }
      return publishCount
    }

    static func waitForPendingTextCheckpoints() async {
      while let task = pendingTextCheckpointTasks.values.first {
        await task.value
      }
    }

    private static func bindingIsCurrent(
      _ binding: Binding<String>,
      for boundary: TextPublicationBoundary
    ) -> Bool {
      if let generation = boundary.bindingGeneration,
         let expected = boundary.expectedBindingGeneration {
        return generation() == expected
      }
      return binding.wrappedValue == boundary.baselineText
    }

    private static func materializeCheckpoint(
      session: OrgSyntaxTextBufferSession,
      capture: OrgSyntaxTextBufferSession.Capture,
      provider: ((OrgSyntaxTextBufferSession.Capture) async -> OrgSyntaxTextBufferSession.Snapshot)?
    ) async -> OrgSyntaxTextBufferSession.Snapshot {
      if let provider {
        return await provider(capture)
      }
      return await session.snapshotAsync(from: capture, priority: .userInitiated)
    }

    private static func documentIsCurrent(
      generation: (() -> UInt64)?,
      expected: UInt64?
    ) -> Bool {
      guard let generation, let expected else { return true }
      return generation() == expected
    }

    @discardableResult
    static func flushRegisteredTextChanges() -> Int {
      pruneLifecycleCoordinators()
      var flushCount = 0
      let coordinators = Array(lifecycleCoordinators.values)
      for box in coordinators {
        if box.value?.flushActiveTextViewIfNeeded() == true {
          flushCount += 1
        }
      }
      return flushCount
    }

    static var hasRegisteredPendingTextChanges: Bool {
      pruneLifecycleCoordinators()
      return lifecycleCoordinators.values.contains {
        $0.value?.hasPendingLocalText == true
      }
    }

    private static func registerForLifecycleFlush(_ coordinator: Coordinator) {
      pruneLifecycleCoordinators()
      lifecycleCoordinators[coordinator.lifecycleID] = WeakLifecycleCoordinator(coordinator)
    }

    private static func unregisterFromLifecycleFlush(id: UUID) {
      lifecycleCoordinators.removeValue(forKey: id)
      pruneLifecycleCoordinators()
    }

    private static func pruneLifecycleCoordinators() {
      lifecycleCoordinators = lifecycleCoordinators.filter { $0.value.value != nil }
    }

    /// Resign notifications must never synchronously materialize a large
    /// native buffer before AppKit can dispatch the click or Cmd-Tab. Owner
    /// navigation uses the explicit lifecycle bridge; passive focus changes
    /// request a generation-checked background checkpoint.
    func requestLifecycleCheckpoint(from textView: NSTextView) {
      guard hasUnpublishedLocalText else {
        flushCaretPublishing(from: textView)
        return
      }
      let utf16Length = textView.textStorage?.length ?? 0
      if utf16Length <= Self.synchronousTextSnapshotUTF16Limit {
        flushPendingTextPublishingIfNeeded(from: textView)
      } else {
        scheduleDeferredTextPublishing(from: textView, milliseconds: 0)
      }
      flushCaretPublishing(from: textView)
    }

    func applyFocusRequestIfNeeded(to textView: NSTextView, enabled: Bool) {
      guard enabled else {
        hasAppliedFocusRequest = false
        return
      }
      guard !hasAppliedFocusRequest else { return }
      hasAppliedFocusRequest = true
      DispatchQueue.main.async { [weak textView] in
        guard let textView, let window = textView.window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !window.isKeyWindow {
          window.makeKey()
        }
        if window.firstResponder !== textView {
          window.makeFirstResponder(textView)
        }
      }
    }

    func detachProseController(from textView: NSTextView) {
      parent.proseController?.detach(from: textView)
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      if isApplyingProgrammaticChange {
        return
      }
      parent.proseController?.textDidChange()
      let currentUTF16Length = textView.textStorage?.length ?? 0
      synchronizeLineIndexIfNeeded(with: textView)

      hasUnpublishedLocalText = true
      invalidateKnownText()
      invalidateViewportHighlighting()
      if currentUTF16Length > OrgSyntaxTextEditor.continuousTextCheckingUTF16Limit,
         textView.isContinuousSpellCheckingEnabled || textView.isGrammarCheckingEnabled {
        OrgSyntaxTextEditor.configureTextChecking(
          parent.textChecking,
          in: textView,
          utf16Length: currentUTF16Length
        )
      }

      var currentText: String?
      if shouldSnapshotSynchronously(utf16Length: currentUTF16Length) {
        let snapshot = snapshotCurrentText(from: textView)
        currentText = snapshot
        parent.onLocalTextChange?(snapshot)
        publishTextChange(snapshot)
      } else {
        scheduleDeferredTextPublishing(
          from: textView,
          milliseconds: deferredTextPublishingDelayMilliseconds
        )
      }
      publishSelectionIfNeeded(textView.selectedRange(), from: textView)
      scheduleSemanticAnalysis(
        for: textView,
        expectedText: nil,
        delayMilliseconds: parent.semanticAnalysisDelayMilliseconds
      )
      guard parent.liveHighlighting else {
        cancelDeferredHighlighting()
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced, prose: parent.isProse)
        recordHighlightedState(text: currentText, utf16Length: currentUTF16Length)
        publishContentHeight(for: textView)
        return
      }
      if parent.incrementalHighlighting {
        let editedRange = pendingEditedRange
          ?? NSRange(location: textView.selectedRange().location, length: 0)
        pendingEditedRange = nil
        if parent.incrementalHighlightingDelayMilliseconds > 0 {
          scheduleDeferredIncrementalHighlighting(
            to: textView,
            expectedText: currentText,
            editedRange: editedRange,
            milliseconds: parent.incrementalHighlightingDelayMilliseconds
          )
        } else {
          applyIncrementalHighlighting(to: textView, editedRange: editedRange)
        }
        publishContentHeight(for: textView)
        return
      }
      if currentText == nil,
         OrgSyntaxHighlighter.shouldTokenizeLiveText(utf16Length: currentUTF16Length) {
        currentText = snapshotCurrentText(from: textView)
      }
      let shouldScheduleHighlighting = currentText.map {
        Self.shouldScheduleDeferredHighlighting(
          text: $0,
          utf16Length: currentUTF16Length,
          previousHighlightedText: lastHighlightedText,
          monospacedUnchanged: lastHighlightedMonospaced == parent.monospaced
            && lastHighlightedConcealsSyntax == parent.concealsSyntax
            && lastHighlightedLiveHighlighting == parent.liveHighlighting
        )
      } ?? false
      markUserTextChangedForHighlighting(
        in: textView,
        currentText: currentText,
        utf16Length: currentUTF16Length,
        willScheduleDeferredHighlighting: shouldScheduleHighlighting
      )
      if shouldScheduleHighlighting, let currentText {
        scheduleDeferredHighlighting(to: textView, expectedText: currentText)
      } else {
        cancelDeferredHighlighting()
      }
      publishContentHeight(for: textView)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      if let syntaxTextView = textView as? OrgSyntaxTextView,
         syntaxTextView.isApplyingCrossEditorSelection || syntaxTextView.isTrackingMouseSelection {
        return
      }
      let selectedRange = textView.selectedRange()
      parent.proseController?.selectionDidChange()
      unfoldIfSelectionEntersHiddenText(selectedRange, in: textView)
      scheduleViewportSourceLinePublishing(for: textView)
      guard shouldReadTextForSelectionPublishing(selectedRange) else { return }
      publishSelectionIfNeeded(selectedRange, from: textView)
    }

    func mouseSelectionDidEnd(in textView: OrgSyntaxTextView) {
      textViewDidChangeSelection(Notification(
        name: NSTextView.didChangeSelectionNotification,
        object: textView
      ))
    }

    func textView(
      _ textView: NSTextView,
      shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      if let prose = parent.proseController,
         !prose.allowsEdit(in: affectedCharRange, replacement: replacementString, textView: textView) {
        return false
      }
      unfoldIfEditTouchesHiddenText(affectedCharRange, in: textView)
      return true
    }

    func textView(
      _ view: NSTextView,
      menu: NSMenu,
      for event: NSEvent,
      at charIndex: Int
    ) -> NSMenu? {
      parent.proseController?.augment(menu: menu)
      return menu
    }

    func textStorage(
      _ textStorage: NSTextStorage,
      didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange,
      changeInLength delta: Int
    ) {
      guard editedMask.contains(.editedCharacters), !isApplyingProgrammaticChange else {
        return
      }

      // This callback describes the committed transaction. Deriving the old
      // range from TextKit's new range + length delta keeps the mirrors exact
      // for IME composition, undo/redo, same-length replacements, and edits
      // that never pass through NSTextView's permission callback.
      let replacementRange = OrgSyntaxTextEditor.clampedRange(
        editedRange,
        utf16Length: textStorage.length
      )
      let priorRange = NSRange(
        location: replacementRange.location,
        length: max(0, replacementRange.length - delta)
      )
      parent.proseController?.noteStorageEdit(priorRange: priorRange, delta: delta)
      let replacement = textStorage.mutableString.substring(with: replacementRange)
      pendingEditedRange = NSRange(
        location: replacementRange.location,
        length: max(1, replacementRange.length)
      )

      if !foldedHeadlineStartLines.isEmpty {
        adjustFoldedHeadlines(for: priorRange, replacement: replacement)
      }
      localTextGeneration = bufferSession.replaceCharacters(
        in: priorRange,
        with: replacement
      )
      if isLineIndexReady {
        lineIndex.replaceCharacters(in: priorRange, with: replacement)
      } else {
        pendingLineIndexEdits.append((priorRange, replacement))
      }
      // Semantic/gutter coordinates belong to the previous committed
      // revision. Disable their actions immediately; the debounced analyzer
      // will install a generation-matching replacement.
      gutterView?.items = []
    }

    func textView(
      _ textView: NSTextView,
      shouldSetSpellingState value: Int,
      range affectedCharRange: NSRange
    ) -> Int {
      guard parent.textChecking == .spellingAndGrammar, value != 0 else { return 0 }
      // Until the detached line index is ready, asking the spell checker to
      // classify a range near EOF would scan the whole document on the main
      // actor. Deferring underlines is preferable to blocking a key event.
      guard isLineIndexReady else { return 0 }
      guard let text = textView.textStorage?.mutableString else { return value }
      return OrgSourceTextChecking.shouldSuppress(
        in: text,
        range: affectedCharRange,
        snapshot: semanticSnapshotTextGeneration == localTextGeneration
          ? semanticSnapshot
          : nil,
        lineIndex: lineIndex
      ) ? 0 : value
    }

    func textDidBeginEditing(_ notification: Notification) {
      parent.isFocused?.wrappedValue = true
    }

    func textDidEndEditing(_ notification: Notification) {
      if let textView = notification.object as? NSTextView {
        requestLifecycleCheckpoint(from: textView)
      }
      parent.isFocused?.wrappedValue = false
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      if handleCompletionKeyCommand(commandSelector, in: textView) {
        return true
      }

      if handleBoundaryArrowCommand(commandSelector, in: textView) {
        return true
      }

      if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
        return handleDeleteBackwardCommand(in: textView)
      }

      if commandSelector == #selector(NSResponder.insertTab(_:)) {
        return handleOrgIndentCommand(.indent, in: textView)
      }

      if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
        return handleOrgIndentCommand(.outdent, in: textView)
      }

      guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
        return false
      }

      if let event = NSApp.currentEvent {
        let modifiers = event.modifierFlags.intersection([.shift, .option, .control, .command])
        if !modifiers.isEmpty {
          return false
        }
      }

      if handleOrgNewlineCommand(in: textView) {
        return true
      }

      guard parent.onSubmitContext != nil || parent.onSubmit != nil else {
        return false
      }
      let text = flushTextPublishing(from: textView)
      let context = OrgSyntaxTextEditorSubmitContext(
        text: text,
        selectedRange: textView.selectedRange()
      )
      if let onSubmitContext = parent.onSubmitContext,
         onSubmitContext(context) {
        return true
      }
      guard let onSubmit = parent.onSubmit else {
        return false
      }
      return onSubmit()
    }

    private func handleCompletionKeyCommand(_ commandSelector: Selector, in textView: NSTextView) -> Bool {
      guard let handler = parent.completionKeyHandler,
            !textView.hasMarkedText(),
            let key = OrgSyntaxTextEditorCompletionKey(
              selector: commandSelector,
              modifiers: NSApp.currentEvent?.modifierFlags ?? []
            ),
            let snapshot = selectionSnapshot(textView.selectedRange(), from: textView)
      else {
        return false
      }
      switch handler(key, snapshot) {
      case .ignored:
        return false
      case .handled:
        return true
      case .replace(let range, let text):
        let length = textView.textStorage?.length ?? 0
        guard range.location >= 0, NSMaxRange(range) <= length else { return false }
        textView.insertText(text, replacementRange: range)
        let caret = NSRange(location: range.location + (text as NSString).length, length: 0)
        textView.setSelectedRange(caret)
        publishSelectionIfNeeded(caret, from: textView)
        return true
      }
    }

    private func handleOrgIndentCommand(
      _ direction: OrgSourceTextIndentDirection,
      in textView: NSTextView
    ) -> Bool {
      guard parent.orgWritingCommands,
            let text = textView.textStorage?.mutableString,
            let replacement = OrgSourceTextEditing.indentationReplacement(
              in: text,
              selectedRange: textView.selectedRange(),
              direction: direction
            )
      else {
        return false
      }
      textView.insertText(replacement.replacement, replacementRange: replacement.range)
      textView.setSelectedRange(replacement.selectedRangeAfterReplacement)
      publishSelectionIfNeeded(replacement.selectedRangeAfterReplacement, from: textView)
      return true
    }

    private func handleOrgNewlineCommand(in textView: NSTextView) -> Bool {
      guard parent.orgWritingCommands,
            let text = textView.textStorage?.mutableString,
            let replacement = OrgSourceTextEditing.newlineReplacement(
              in: text,
              selectedRange: textView.selectedRange()
            )
      else {
        return false
      }
      textView.insertText(replacement.replacement, replacementRange: replacement.range)
      textView.setSelectedRange(replacement.selectedRangeAfterReplacement)
      publishSelectionIfNeeded(replacement.selectedRangeAfterReplacement, from: textView)
      return true
    }

    func performRequestedCommandIfNeeded(
      _ request: OrgSourceEditorCommandRequest?,
      in textView: OrgSyntaxTextView
    ) {
      guard let request, request.id != lastCommandRequestID else { return }
      lastCommandRequestID = request.id
      _ = performSourceEditorCommand(request.command, in: textView)
    }

    func performGutterAction(
      _ action: OrgSourceEditorGutterAction,
      in textView: OrgSyntaxTextView
    ) {
      let line: Int
      switch action {
      case .command(let targetLine, _), .backlinks(let targetLine):
        line = targetLine
      }
      synchronizeLineIndexIfNeeded(with: textView)
      let lineRange = lineIndex.lineRange(forLine: line)
      let selection = NSRange(location: lineRange.location, length: 0)
      textView.setSelectedRange(selection)
      textView.scrollRangeToVisible(selection)
      publishSelectionIfNeeded(selection, from: textView)

      switch action {
      case .command(_, let command):
        _ = performSourceEditorCommand(command, in: textView)
      case .backlinks:
        parent.onGutterBacklinks?(line)
      }
    }

    @discardableResult
    func performSourceEditorCommand(
      _ command: OrgSourceEditorCommand,
      in textView: OrgSyntaxTextView
    ) -> Bool {
      guard parent.orgWritingCommands else { return false }
      textView.window?.makeFirstResponder(textView)
      guard let text = textView.textStorage?.mutableString else { return false }
      synchronizeLineIndexIfNeeded(with: textView)
      guard isLineIndexReady else {
        reportCommandStatus("Source structure is still being indexed; try again shortly")
        return true
      }
      let selection = textView.selectedRange()
      let snapshot = currentSemanticSnapshot(for: text)
      if snapshot == nil,
         commandRequiresCurrentSemantics(command, text: text, selection: selection) {
        reportCommandStatus("Source structure is still being analyzed; try again shortly")
        return true
      }
      let replacement: OrgSyntaxTextEditReplacement?
      let actionName: String

      switch command {
      case .insertHeading:
        replacement = OrgSourceTextEditing.headingInsertionReplacement(
          in: text,
          selectedRange: selection,
          snapshot: snapshot,
          lineIndex: lineIndex
        )
        actionName = "Insert Heading"
      case .insertListItem:
        replacement = OrgSourceTextEditing.listItemInsertionReplacement(
          in: text,
          selectedRange: selection
        )
        actionName = "Insert List Item"
      case .promote:
        replacement = OrgSourceTextEditing.indentationReplacement(
          in: text,
          selectedRange: selection,
          direction: .outdent
        )
        actionName = "Promote"
      case .demote:
        replacement = OrgSourceTextEditing.indentationReplacement(
          in: text,
          selectedRange: selection,
          direction: .indent
        )
        actionName = "Demote"
      case .cycleTodo:
        replacement = OrgSourceTextEditing.todoCycleReplacement(
          in: text,
          selectedRange: selection,
          snapshot: snapshot,
          lineIndex: lineIndex
        )
        actionName = "Cycle TODO"
      case .setPriority(let priority):
        replacement = OrgSourceTextEditing.priorityReplacement(
          in: text,
          selectedRange: selection,
          priority: priority,
          snapshot: snapshot,
          lineIndex: lineIndex
        )
        actionName = priority.map { "Set Priority \($0)" } ?? "Clear Priority"
      case .scheduleToday:
        replacement = OrgSourceTextEditing.planningReplacement(
          in: text,
          selectedRange: selection,
          kind: "SCHEDULED",
          date: Calendar.current.startOfDay(for: Date()),
          snapshot: snapshot,
          lineIndex: lineIndex
        )
        actionName = "Schedule Today"
      case .deadlineToday:
        replacement = OrgSourceTextEditing.planningReplacement(
          in: text,
          selectedRange: selection,
          kind: "DEADLINE",
          date: Calendar.current.startOfDay(for: Date()),
          snapshot: snapshot,
          lineIndex: lineIndex
        )
        actionName = "Set Deadline"
      case .clearPlanning:
        replacement = OrgSourceTextEditing.clearPlanningReplacement(
          in: text,
          selectedRange: selection,
          snapshot: snapshot,
          lineIndex: lineIndex
        )
        actionName = "Clear Planning"
      case .insertProperty:
        guard let property = promptForProperty(in: textView) else { return true }
        replacement = OrgSourceTextEditing.propertyReplacement(
          in: text,
          selectedRange: selection,
          key: property.key,
          value: property.value,
          snapshot: snapshot,
          lineIndex: lineIndex
        )
        actionName = "Set Property"
      case .insertLink:
        guard let link = promptForLink(in: textView) else { return true }
        replacement = OrgSourceTextEditing.linkReplacement(
          in: text,
          selectedRange: selection,
          target: link.target,
          description: link.description
        )
        actionName = "Insert Link"
      case .toggleFold:
        guard let snapshot else { return true }
        return toggleFold(at: selection, in: textView, snapshot: snapshot)
      case .unfoldAll:
        foldedHeadlineStartLines.removeAll()
        applyFoldPresentation(to: textView)
        reportCommandStatus("Expanded all source headings")
        return true
      case .previousHeading, .nextHeading:
        guard let range = OrgSourceTextEditing.headingNavigationRange(
          in: text,
          selectedRange: selection,
          direction: command,
          snapshot: snapshot,
          lineIndex: lineIndex
        ) else {
          WorkspaceSound.beep()
          return true
        }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        publishSelectionIfNeeded(range, from: textView)
        return true
      }

      guard let replacement else {
        WorkspaceSound.beep()
        reportCommandStatus("No applicable Org structure at the cursor")
        return true
      }
      apply(replacement, actionName: actionName, to: textView)
      return true
    }

    private func apply(
      _ replacement: OrgSyntaxTextEditReplacement,
      actionName: String,
      to textView: NSTextView
    ) {
      let undoManager = textView.undoManager
      undoManager?.beginUndoGrouping()
      textView.insertText(replacement.replacement, replacementRange: replacement.range)
      textView.setSelectedRange(replacement.selectedRangeAfterReplacement)
      undoManager?.setActionName(actionName)
      undoManager?.endUndoGrouping()
      publishSelectionIfNeeded(replacement.selectedRangeAfterReplacement, from: textView)
      textView.scrollRangeToVisible(replacement.selectedRangeAfterReplacement)
      reportCommandStatus(actionName)
    }

    private func currentSemanticSnapshot(for text: NSString) -> OrgSourceEditorSemanticSnapshot? {
      if semanticSnapshotTextGeneration == localTextGeneration, let semanticSnapshot {
        return semanticSnapshot
      }
      guard text.length <= Self.synchronousSemanticFallbackUTF16Limit else {
        return nil
      }
      let fallback = OrgSourceTextEditing.fallbackSemanticSnapshot(in: text as String)
      installCurrentSemanticSnapshot(fallback)
      return fallback
    }

    private func commandRequiresCurrentSemantics(
      _ command: OrgSourceEditorCommand,
      text: NSString,
      selection: NSRange
    ) -> Bool {
      switch command {
      case .insertHeading, .cycleTodo, .setPriority:
        let line = lineIndex.lineNumber(atUTF16Offset: selection.location)
        let range = lineIndex.lineRange(forLine: line)
        let contentRange = NSRange(
          location: range.location,
          length: max(0, OrgSourceTextEditing.lineContentEnd(in: text, lineRange: range) - range.location)
        )
        return OrgSourceTextEditing.headingMarker(in: text.substring(with: contentRange)) == nil
      case .scheduleToday, .deadlineToday, .clearPlanning, .insertProperty,
           .toggleFold, .previousHeading, .nextHeading:
        return true
      case .insertListItem, .promote, .demote, .insertLink, .unfoldAll:
        return false
      }
    }

    private func installCurrentSemanticSnapshot(
      _ snapshot: OrgSourceEditorSemanticSnapshot,
      headlineRegionsByStartLine: [Int: OrgSourceSemanticRegion]? = nil,
      backgroundRegions: [OrgSourceSemanticRegion]? = nil,
      diagnosticsByLine: [Org2EditorDiagnostic]? = nil
    ) {
      semanticSnapshot = snapshot
      semanticSnapshotTextGeneration = localTextGeneration
      semanticHeadlineRegionsByStartLine = headlineRegionsByStartLine
        ?? Self.headlineRegionsByStartLine(in: snapshot)
      semanticBackgroundRegions = backgroundRegions
        ?? Self.backgroundSemanticRegions(in: snapshot)
      semanticDiagnosticsByLine = diagnosticsByLine
        ?? snapshot.diagnostics.sorted { lhs, rhs in
          lhs.line == rhs.line ? lhs.column < rhs.column : lhs.line < rhs.line
        }
      semanticPresentationViewportLines = nil
    }

    nonisolated private static func headlineRegionsByStartLine(
      in snapshot: OrgSourceEditorSemanticSnapshot
    ) -> [Int: OrgSourceSemanticRegion] {
      var result: [Int: OrgSourceSemanticRegion] = [:]
      for region in snapshot.regions where region.kind == .headline {
        result[region.startLine] = region
      }
      return result
    }

    nonisolated private static func backgroundSemanticRegions(
      in snapshot: OrgSourceEditorSemanticSnapshot
    ) -> [OrgSourceSemanticRegion] {
      snapshot.regions.filter { region in
        switch region.kind {
        case .properties, .sourceBlock, .table:
          return true
        default:
          return false
        }
      }.sorted { lhs, rhs in
        lhs.startLine == rhs.startLine
          ? lhs.endLine < rhs.endLine
          : lhs.startLine < rhs.startLine
      }
    }

    private func currentFoldedHeadlineRegions() -> [OrgSourceSemanticRegion] {
      guard semanticSnapshotTextGeneration == localTextGeneration else { return [] }
      return foldedHeadlineStartLines.sorted().compactMap {
        semanticHeadlineRegionsByStartLine[$0]
      }
    }

    private func promptForLink(in textView: NSTextView) -> (target: String, description: String?)? {
      guard let text = textView.textStorage?.mutableString else { return nil }
      let selectedRange = OrgSyntaxTextEditor.clampedRange(
        textView.selectedRange(),
        utf16Length: text.length
      )
      let selectedText = selectedRange.length > 0
        ? text.substring(with: selectedRange)
        : ""
      let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
      let targetField = NSTextField(string: clipboardLooksLikeLink(clipboard) ? clipboard : "")
      targetField.placeholderString = "URL, id:..., or file:..."
      let descriptionField = NSTextField(string: selectedText)
      descriptionField.placeholderString = "Description (optional)"
      let stack = NSStackView(views: [targetField, descriptionField])
      stack.orientation = .vertical
      stack.spacing = 8
      stack.frame = NSRect(x: 0, y: 0, width: 420, height: 54)

      let alert = NSAlert()
      alert.messageText = "Insert Org Link"
      alert.informativeText = "Enter a link target and optional visible description."
      alert.accessoryView = stack
      alert.addButton(withTitle: "Insert")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return nil }
      let target = targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !target.isEmpty else { return nil }
      return (target, descriptionField.stringValue)
    }

    private func promptForProperty(in textView: NSTextView) -> (key: String, value: String)? {
      let keyField = NSTextField()
      keyField.placeholderString = "Property name"
      let valueField = NSTextField()
      valueField.placeholderString = "Value"
      let stack = NSStackView(views: [keyField, valueField])
      stack.orientation = .vertical
      stack.spacing = 8
      stack.frame = NSRect(x: 0, y: 0, width: 420, height: 54)

      let alert = NSAlert()
      alert.messageText = "Set Org Property"
      alert.informativeText = "The property is updated or added to the current heading."
      alert.accessoryView = stack
      alert.addButton(withTitle: "Set")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return nil }
      let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else { return nil }
      return (key, valueField.stringValue)
    }

    private func clipboardLooksLikeLink(_ value: String) -> Bool {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.range(of: #"^(?:https?://|mailto:|id:|file:|\./|\.\./|/)"#, options: .regularExpression) != nil
    }

    private func reportCommandStatus(_ status: String) {
      parent.onCommandStatus?(status)
    }

    private func toggleFold(
      at selection: NSRange,
      in textView: NSTextView,
      snapshot: OrgSourceEditorSemanticSnapshot
    ) -> Bool {
      synchronizeLineIndexIfNeeded(with: textView)
      let line = lineIndex.lineNumber(atUTF16Offset: selection.location)
      guard let headline = OrgSourceTextEditing.enclosingHeadline(in: snapshot, line: line),
            indexedSourceRange(
              for: headline,
              excludingFirstLine: true
            )?.length ?? 0 > 0
      else {
        WorkspaceSound.beep()
        reportCommandStatus("The current heading has no body to fold")
        return true
      }

      if foldedHeadlineStartLines.contains(headline.startLine) {
        foldedHeadlineStartLines.remove(headline.startLine)
        reportCommandStatus("Expanded source heading")
      } else {
        foldedHeadlineStartLines.insert(headline.startLine)
        let headingRange = lineIndex.lineRange(forLine: headline.startLine)
        textView.setSelectedRange(NSRange(location: headingRange.location, length: 0))
        reportCommandStatus("Collapsed source heading")
      }
      applyFoldPresentation(to: textView)
      refreshGutterFoldState()
      publishContentHeight(for: textView)
      return true
    }

    private func applyFoldPresentation(to textView: NSTextView) {
      guard let layoutManager = textView.layoutManager else { return }
      let textLength = textView.textStorage?.length ?? 0
      for range in validPresentationRanges(foldPresentationRanges, textLength: textLength) {
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.paragraphStyle, forCharacterRange: range)
      }
      foldPresentationRanges = []
      let foldedHeadlines = currentFoldedHeadlineRegions()
      guard !foldedHeadlines.isEmpty else { return }
      let hiddenFont = NSFont.systemFont(ofSize: 0.01)
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = 0.01
      paragraph.maximumLineHeight = 0.01
      paragraph.lineSpacing = 0
      for headline in foldedHeadlines {
        guard let range = indexedSourceRange(
          for: headline,
          excludingFirstLine: true
        ), range.length > 0 else { continue }
        layoutManager.addTemporaryAttribute(.font, value: hiddenFont, forCharacterRange: range)
        layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: range)
        layoutManager.addTemporaryAttribute(.paragraphStyle, value: paragraph, forCharacterRange: range)
        foldPresentationRanges.append(range)
      }
      for range in foldPresentationRanges {
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
      }
    }

    private func adjustFoldedHeadlines(
      for affectedRange: NSRange,
      replacement: String
    ) {
      guard !foldedHeadlineStartLines.isEmpty else { return }
      let range = OrgSyntaxTextEditor.clampedRange(
        affectedRange,
        utf16Length: lineIndex.documentUTF16Length
      )
      let removed = lineIndex.newlineCount(in: range)
      let inserted = replacement.utf16.reduce(into: 0) { count, codeUnit in
        if codeUnit == 0x0A {
          count += 1
        }
      }
      let lineDelta = inserted - removed
      guard lineDelta != 0 || range.length > 0 else { return }

      var adjusted = Set<Int>()
      for startLine in foldedHeadlineStartLines {
        let headingOffset = lineIndex.utf16Offset(forLine: startLine)
        if NSMaxRange(range) <= headingOffset {
          adjusted.insert(max(1, startLine + lineDelta))
        } else if range.location > headingOffset {
          adjusted.insert(startLine)
        }
      }
      foldedHeadlineStartLines = adjusted
    }

    private func unfoldIfSelectionEntersHiddenText(_ selection: NSRange, in textView: NSTextView) {
      let foldedHeadlines = currentFoldedHeadlineRegions()
      guard !foldedHeadlines.isEmpty else { return }
      for headline in foldedHeadlines {
        guard let range = indexedSourceRange(
          for: headline,
          excludingFirstLine: true
        ) else { continue }
        if selection.location >= range.location && selection.location < NSMaxRange(range) {
          foldedHeadlineStartLines.remove(headline.startLine)
          applyFoldPresentation(to: textView)
          reportCommandStatus("Expanded source heading for editing")
          return
        }
      }
    }

    private func unfoldIfEditTouchesHiddenText(_ range: NSRange, in textView: NSTextView) {
      let foldedHeadlines = currentFoldedHeadlineRegions()
      guard !foldedHeadlines.isEmpty else { return }
      for headline in foldedHeadlines {
        guard let hidden = indexedSourceRange(
          for: headline,
          excludingFirstLine: true
        ) else { continue }
        if NSIntersectionRange(hidden, range).length > 0
            || (range.length == 0 && range.location >= hidden.location && range.location < NSMaxRange(hidden)) {
          foldedHeadlineStartLines.remove(headline.startLine)
          applyFoldPresentation(to: textView)
          return
        }
      }
    }

    func clearSemanticState() {
      semanticAnalysisTask?.cancel()
      semanticAnalysisTask = nil
      semanticAnalysisGeneration += 1
      semanticSnapshot = nil
      semanticSnapshotTextGeneration = nil
      semanticHeadlineRegionsByStartLine = [:]
      semanticBackgroundRegions = []
      semanticDiagnosticsByLine = []
      semanticPresentationViewportLines = nil
      cancelDeferredCaretPublishing()
      deferredViewportPublishWorkItem?.cancel()
      deferredViewportPublishWorkItem = nil
      if let textView = activeTextView, let layoutManager = textView.layoutManager {
        let textLength = textView.textStorage?.length ?? 0
        for range in validPresentationRanges(
          foldPresentationRanges + diagnosticPresentationRanges + semanticPresentationRanges,
          textLength: textLength
        ) {
          layoutManager.removeTemporaryAttribute(.font, forCharacterRange: range)
          layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
          layoutManager.removeTemporaryAttribute(.paragraphStyle, forCharacterRange: range)
          layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
          layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
          layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
          layoutManager.removeTemporaryAttribute(.toolTip, forCharacterRange: range)
        }
      }
      foldedHeadlineStartLines.removeAll()
      foldPresentationRanges = []
      diagnosticPresentationRanges = []
      semanticPresentationRanges = []
      gutterView?.items = []
      parent.diagnostics?.wrappedValue = []
    }

    func scheduleSemanticAnalysis(
      for textView: NSTextView,
      expectedText: String?,
      delayMilliseconds: Int = 180
    ) {
      semanticAnalysisTask?.cancel()
      semanticAnalysisGeneration += 1
      let generation = semanticAnalysisGeneration
      let documentBoundary = documentBoundary()
      let utf16Length = textView.textStorage?.length ?? 0
      let needsCurrentFallback = semanticSnapshotTextGeneration != localTextGeneration
      if needsCurrentFallback,
         delayMilliseconds == 0,
         utf16Length <= Self.synchronousSemanticFallbackUTF16Limit {
        let fallbackText = expectedText ?? snapshotCurrentText(from: textView)
        let fallback = OrgSourceTextEditing.fallbackSemanticSnapshot(in: fallbackText)
        installCurrentSemanticSnapshot(fallback)
        refreshGutter(for: textView, snapshot: fallback)
      }
      let analyzer = parent.semanticAnalyzer
      let needsDeferredFallback = analyzer == nil
        && semanticSnapshotTextGeneration != localTextGeneration
      guard analyzer != nil || needsDeferredFallback else {
        return
      }
      semanticAnalysisTask = Task { @MainActor [weak self, weak textView] in
        if delayMilliseconds > 0 {
          do {
            try await Task.sleep(nanoseconds: UInt64(delayMilliseconds) * 1_000_000)
          } catch {
            return
          }
        }
        guard !Task.isCancelled,
              let self,
              self.semanticAnalysisGeneration == generation,
              self.documentIsCurrent(for: documentBoundary),
              let textView
        else { return }

        // Snapshot the document only after the user has been idle for the
        // configured interval. Capturing it for every key made fast typing in
        // large files linearly more expensive even though all but the final
        // analysis was cancelled.
        let analysisText: String
        if let expectedText {
          analysisText = expectedText
        } else if let knownText = self.knownText(matchingUTF16Length: utf16Length) {
          analysisText = knownText
        } else if utf16Length > Self.synchronousTextSnapshotUTF16Limit {
          let bufferSnapshot = await self.bufferSession.snapshotAsync(priority: .utility)
          guard !Task.isCancelled,
                self.semanticAnalysisGeneration == generation,
                self.documentIsCurrent(for: documentBoundary),
                bufferSnapshot.revision == self.bufferSession.revision
          else { return }
          analysisText = bufferSnapshot.text
        } else {
          analysisText = self.snapshotCurrentText(from: textView)
        }
        let snapshot: OrgSourceEditorSemanticSnapshot?
        if let analyzer {
          snapshot = await analyzer(analysisText)
        } else {
          snapshot = await Task.detached(priority: .utility) {
            OrgSourceTextEditing.fallbackSemanticSnapshot(in: analysisText)
          }.value
        }
        guard let snapshot,
              !Task.isCancelled,
              self.semanticAnalysisGeneration == generation,
              self.documentIsCurrent(for: documentBoundary)
        else { return }
        let foldedHeadlineStartLines = self.foldedHeadlineStartLines
        let derivedSemantics = await Task.detached(priority: .utility) {
          (
            gutterItems: OrgSourceEditorGutterModel.items(
              text: analysisText,
              snapshot: snapshot,
              foldedHeadlineStartLines: foldedHeadlineStartLines
            ),
            headlineRegionsByStartLine: Self.headlineRegionsByStartLine(in: snapshot),
            backgroundRegions: Self.backgroundSemanticRegions(in: snapshot),
            diagnosticsByLine: snapshot.diagnostics.sorted { lhs, rhs in
              lhs.line == rhs.line ? lhs.column < rhs.column : lhs.line < rhs.line
            }
          )
        }.value
        guard !Task.isCancelled,
              self.semanticAnalysisGeneration == generation,
              self.documentIsCurrent(for: documentBoundary)
        else { return }
        if let lineIndexBuildTask = self.lineIndexBuildTask {
          await lineIndexBuildTask.value
        }
        guard !Task.isCancelled,
              self.semanticAnalysisGeneration == generation,
              self.documentIsCurrent(for: documentBoundary),
              self.isLineIndexReady
        else { return }
        self.installCurrentSemanticSnapshot(
          snapshot,
          headlineRegionsByStartLine: derivedSemantics.headlineRegionsByStartLine,
          backgroundRegions: derivedSemantics.backgroundRegions,
          diagnosticsByLine: derivedSemantics.diagnosticsByLine
        )
        self.parent.diagnostics?.wrappedValue = snapshot.diagnostics
        self.clearTextCheckingIndicators(in: textView, text: analysisText, snapshot: snapshot)
        self.refreshSemanticPresentation(to: textView)
        self.applyFoldPresentation(to: textView)
        self.gutterView?.items = derivedSemantics.gutterItems
      }
    }

    static let synchronousSemanticFallbackUTF16Limit = 64_000
    static let largeDocumentInitialSemanticIdleDelayMilliseconds = 180

    static func initialSemanticAnalysisDelayMilliseconds(
      utf16Length: Int,
      configuredDelayMilliseconds: Int
    ) -> Int {
      guard utf16Length > synchronousSemanticFallbackUTF16Limit else { return 0 }
      return max(
        largeDocumentInitialSemanticIdleDelayMilliseconds,
        configuredDelayMilliseconds
      )
    }

    private func refreshGutter(
      for textView: NSTextView,
      snapshot: OrgSourceEditorSemanticSnapshot? = nil
    ) {
      guard let gutterView else { return }
      let text = snapshotCurrentText(from: textView)
      guard let currentSnapshot = snapshot ?? currentSemanticSnapshot(for: text as NSString) else {
        gutterView.items = []
        return
      }
      gutterView.items = OrgSourceEditorGutterModel.items(
        text: text,
        snapshot: currentSnapshot,
        foldedHeadlineStartLines: foldedHeadlineStartLines
      )
    }

    private func refreshGutterFoldState() {
      guard let gutterView else { return }
      gutterView.items = gutterView.items.map { item in
        item.withFoldedState(foldedHeadlineStartLines.contains(item.line))
      }
    }

    private func clearTextCheckingIndicators(
      in textView: NSTextView,
      text: String,
      snapshot: OrgSourceEditorSemanticSnapshot
    ) {
      guard parent.textChecking == .spellingAndGrammar,
            (text as NSString).length <= OrgSyntaxTextEditor.continuousTextCheckingUTF16Limit
      else { return }
      for range in OrgSourceTextChecking.excludedSemanticRanges(in: text, snapshot: snapshot) {
        textView.setSpellingState(0, range: range)
      }
    }

    private func refreshSemanticPresentation(to textView: NSTextView) {
      guard let visibleLines = visibleSemanticPresentationLines(in: textView) else { return }
      guard semanticPresentationViewportLines != visibleLines else { return }
      semanticPresentationViewportLines = visibleLines
      applySemanticPresentation(to: textView, visibleLines: visibleLines)
      applyDiagnosticPresentation(to: textView, visibleLines: visibleLines)
    }

    private func applySemanticPresentation(
      to textView: NSTextView,
      visibleLines: ClosedRange<Int>
    ) {
      guard let layoutManager = textView.layoutManager else { return }
      let textLength = textView.textStorage?.length ?? 0
      for range in validPresentationRanges(semanticPresentationRanges, textLength: textLength) {
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
      }
      semanticPresentationRanges = []

      var index = lowerBoundBackgroundRegion(startingAtOrAfter: visibleLines.lowerBound)
      if index > 0 {
        index -= 1
      }
      while semanticBackgroundRegions.indices.contains(index) {
        let region = semanticBackgroundRegions[index]
        guard region.startLine <= visibleLines.upperBound else { break }
        defer { index += 1 }
        guard region.endLine >= visibleLines.lowerBound else { continue }
        let color: NSColor?
        switch region.kind {
        case .properties:
          color = NSColor.secondaryLabelColor.withAlphaComponent(0.035)
        case .sourceBlock:
          color = NSColor.controlAccentColor.withAlphaComponent(0.025)
        case .table:
          color = NSColor.secondaryLabelColor.withAlphaComponent(0.025)
        default:
          color = nil
        }
        guard let color,
              let range = indexedSourceRange(for: region),
              range.length > 0
        else { continue }
        layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        semanticPresentationRanges.append(range)
      }
    }

    private func applyDiagnosticPresentation(
      to textView: NSTextView,
      visibleLines: ClosedRange<Int>
    ) {
      guard let layoutManager = textView.layoutManager else { return }
      synchronizeLineIndexIfNeeded(with: textView)
      let textLength = textView.textStorage?.length ?? 0
      for range in validPresentationRanges(diagnosticPresentationRanges, textLength: textLength) {
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.toolTip, forCharacterRange: range)
      }
      diagnosticPresentationRanges = []
      guard textLength > 0 else { return }
      var index = lowerBoundDiagnostic(atOrAfter: visibleLines.lowerBound)
      while semanticDiagnosticsByLine.indices.contains(index) {
        let diagnostic = semanticDiagnosticsByLine[index]
        guard diagnostic.line <= visibleLines.upperBound else { break }
        index += 1
        let lineRange = lineIndex.lineRange(forLine: diagnostic.line)
        let contentEnd = max(lineRange.location, min(
          textLength,
          lineRange.location + lineRange.length
        ))
        let location = min(
          max(lineRange.location, lineRange.location + max(0, diagnostic.column - 1)),
          max(0, textLength - 1)
        )
        let range = NSRange(
          location: location,
          length: max(1, min(max(1, contentEnd - location), textLength - location))
        )
        layoutManager.addTemporaryAttribute(
          .underlineStyle,
          value: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
          forCharacterRange: range
        )
        layoutManager.addTemporaryAttribute(.underlineColor, value: NSColor.systemRed, forCharacterRange: range)
        layoutManager.addTemporaryAttribute(.toolTip, value: diagnostic.message, forCharacterRange: range)
        diagnosticPresentationRanges.append(range)
      }
    }

    private func visibleSemanticPresentationLines(
      in textView: NSTextView
    ) -> ClosedRange<Int>? {
      guard isLineIndexReady, lineIndex.lineCount > 0 else { return nil }
      let textLength = textView.textStorage?.length ?? 0
      guard textLength > 0,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
      else { return 1...1 }

      let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
      let expandedRect = visibleRect.insetBy(dx: 0, dy: -320)
      let glyphRange = layoutManager.glyphRange(
        forBoundingRect: expandedRect,
        in: textContainer
      )
      let characterRange = layoutManager.characterRange(
        forGlyphRange: glyphRange,
        actualGlyphRange: nil
      )
      if characterRange.length > 0 {
        let lower = lineIndex.lineNumber(atUTF16Offset: characterRange.location)
        let upper = lineIndex.lineNumber(
          atUTF16Offset: min(textLength, NSMaxRange(characterRange))
        )
        return max(1, lower)...min(lineIndex.lineCount, max(lower, upper))
      }

      let selectedLine = lineIndex.lineNumber(
        atUTF16Offset: min(textLength, textView.selectedRange().location)
      )
      return max(1, selectedLine - 80)...min(lineIndex.lineCount, selectedLine + 80)
    }

    private func lowerBoundBackgroundRegion(startingAtOrAfter line: Int) -> Int {
      var lower = 0
      var upper = semanticBackgroundRegions.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if semanticBackgroundRegions[middle].startLine < line {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      return lower
    }

    private func lowerBoundDiagnostic(atOrAfter line: Int) -> Int {
      var lower = 0
      var upper = semanticDiagnosticsByLine.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if semanticDiagnosticsByLine[middle].line < line {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      return lower
    }

    private func validPresentationRanges(_ ranges: [NSRange], textLength: Int) -> [NSRange] {
      ranges.compactMap { range in
        guard range.location < textLength else { return nil }
        return NSRange(
          location: max(0, range.location),
          length: min(range.length, textLength - max(0, range.location))
        )
      }.filter { $0.length > 0 }
    }

    private func indexedSourceRange(
      for region: OrgSourceSemanticRegion,
      excludingFirstLine: Bool = false
    ) -> NSRange? {
      let startLine = region.startLine + (excludingFirstLine ? 1 : 0)
      guard startLine <= region.endLine,
            startLine <= lineIndex.lineCount
      else { return nil }
      let start = lineIndex.utf16Offset(forLine: startLine)
      let endRange = lineIndex.lineRange(forLine: min(region.endLine, lineIndex.lineCount))
      return NSRange(location: start, length: max(0, NSMaxRange(endRange) - start))
    }

    func observeScrolling(of scrollView: NSScrollView, textView: NSTextView) {
      let clipView = scrollView.contentView
      guard observedClipView !== clipView else { return }
      if let scrollObserver {
        NotificationCenter.default.removeObserver(scrollObserver)
      }
      observedClipView = clipView
      clipView.postsBoundsChangedNotifications = true
      scrollObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: clipView,
        queue: .main
      ) { [weak self, weak textView] _ in
        MainActor.assumeIsolated {
          guard let self, let textView else { return }
          self.scheduleCoalescedScrollRefresh(for: textView)
        }
      }
      DispatchQueue.main.async { [weak self, weak textView] in
        guard let self, let textView else { return }
        if self.shouldHighlightVisibleRange(in: textView) {
          self.highlightVisibleRange(in: textView)
        }
        self.refreshSemanticPresentation(to: textView)
        self.gutterView?.invalidateVisibleGeometry()
        self.scheduleViewportSourceLinePublishing(for: textView, delayMilliseconds: 0)
      }
    }

    private func scheduleCoalescedScrollRefresh(for textView: NSTextView) {
      guard deferredScrollRefreshWorkItem == nil else { return }
      let workItem = DispatchWorkItem { [weak self, weak textView] in
        MainActor.assumeIsolated {
          guard let self, let textView else { return }
          self.deferredScrollRefreshWorkItem = nil
          if self.shouldHighlightVisibleRange(in: textView),
             !self.hasDeferredHighlightingForCurrentBuffer {
            self.highlightVisibleRange(in: textView)
          }
          self.refreshSemanticPresentation(to: textView)
          self.gutterView?.invalidateVisibleGeometry()
          self.scheduleViewportSourceLinePublishing(for: textView)
        }
      }
      deferredScrollRefreshWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8), execute: workItem)
    }

    func resetViewportSourceLinePublishing() {
      lastPublishedViewportSourceLine = nil
    }

    func scheduleViewportSourceLinePublishing(
      for textView: NSTextView,
      delayMilliseconds: Int = 80
    ) {
      guard parent.onViewportSourceLine != nil, isLineIndexReady else { return }
      deferredViewportPublishWorkItem?.cancel()
      let workItem = DispatchWorkItem { [weak self, weak textView] in
        Task { @MainActor in
          guard let self,
                let textView,
                let line = Self.visibleSourceLine(of: textView, lineIndex: self.lineIndex),
                line != self.lastPublishedViewportSourceLine
          else {
            return
          }
          self.lastPublishedViewportSourceLine = line
          self.parent.onViewportSourceLine?(line)
        }
      }
      deferredViewportPublishWorkItem = workItem
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .milliseconds(max(0, delayMilliseconds)),
        execute: workItem
      )
    }

    static func visibleSourceLine(
      of textView: NSTextView,
      lineIndex existingLineIndex: OrgSourceLineIndex? = nil
    ) -> Int? {
      let textLength = textView.textStorage?.length ?? 0
      guard textLength > 0 else { return 1 }
      let visibleRect = textView.visibleRect
      guard visibleRect.height > 0 else { return nil }
      let anchorY = min(
        max(visibleRect.minY + visibleRect.height * 0.32, visibleRect.minY + 24),
        visibleRect.maxY - 1
      )
      let characterIndex = min(
        max(0, textView.characterIndexForInsertion(
          at: NSPoint(x: textView.textContainerOrigin.x + 1, y: anchorY)
        )),
        textLength
      )
      if let existingLineIndex,
         existingLineIndex.documentUTF16Length == textLength {
        return existingLineIndex.lineNumber(atUTF16Offset: characterIndex)
      }
      // Large documents build this index off-main. Defer publication until
      // that build installs instead of reconstructing every line from a
      // scroll/first-frame callback on the main actor.
      guard textLength <= synchronousTextSnapshotUTF16Limit else { return nil }
      guard let text = textView.textStorage?.mutableString else { return 1 }
      return OrgSourceLineIndex(text: text).lineNumber(atUTF16Offset: characterIndex)
    }

    func sourceLine(atUTF16Offset offset: Int, in textView: NSTextView) -> Int {
      synchronizeLineIndexIfNeeded(with: textView)
      return lineIndex.lineNumber(atUTF16Offset: offset)
    }

    private func applyIncrementalHighlighting(to textView: NSTextView, editedRange: NSRange) {
      guard let storage = textView.textStorage else { return }
      let typingAttributes = applySyntaxHighlighting(to: storage, characterRange: editedRange)
      textView.typingAttributes = typingAttributes
      recordHighlightedState(for: textView)
    }

    /// Org highlighting, or code highlighting for files in a code language.
    @discardableResult
    func applySyntaxHighlighting(to storage: NSTextStorage, characterRange: NSRange?) -> [NSAttributedString.Key: Any] {
      if let language = parent.codeLanguage {
        return OrgCodeHighlighter.apply(
          to: storage,
          language: language,
          characterRange: characterRange,
          baseAttributes: OrgSyntaxHighlighter.baseTypingAttributes(monospaced: true)
        )
      }
      if let characterRange {
        return OrgSyntaxHighlighter.apply(
          to: storage,
          characterRange: characterRange,
          monospaced: parent.monospaced,
          concealsSyntax: parent.concealsSyntax,
          prose: parent.isProse
        )
      }
      return OrgSyntaxHighlighter.apply(
        to: storage,
        monospaced: parent.monospaced,
        concealsSyntax: parent.concealsSyntax,
        prose: parent.isProse
      )
    }

    private func scheduleDeferredIncrementalHighlighting(
      to textView: NSTextView,
      expectedText: String?,
      editedRange: NSRange,
      milliseconds: Int
    ) {
      deferredIncrementalHighlightTask?.cancel()
      deferredIncrementalHighlightText = expectedText
      let textGeneration = localTextGeneration
      let documentBoundary = documentBoundary()
      deferredIncrementalHighlightGeneration = textGeneration
      if let pendingRange = deferredIncrementalHighlightRange {
        deferredIncrementalHighlightRange = NSUnionRange(pendingRange, editedRange)
      } else {
        deferredIncrementalHighlightRange = editedRange
      }

      deferredIncrementalHighlightTask = Task { @MainActor [weak self, weak textView] in
        do {
          try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled,
              let self,
              let textView,
              self.deferredIncrementalHighlightGeneration == textGeneration,
              self.localTextGeneration == textGeneration,
              self.documentIsCurrent(for: documentBoundary)
        else { return }
        let range = self.deferredIncrementalHighlightRange
          ?? NSRange(location: textView.selectedRange().location, length: 0)
        self.deferredIncrementalHighlightTask = nil
        self.deferredIncrementalHighlightText = nil
        self.deferredIncrementalHighlightGeneration = nil
        self.deferredIncrementalHighlightRange = nil
        self.applyIncrementalHighlighting(to: textView, editedRange: range)
      }
    }

    @discardableResult
    func highlightVisibleRange(in textView: NSTextView) -> Bool {
      guard parent.liveHighlighting else { return false }
      guard !isApplyingViewportHighlighting else { return false }
      guard let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            let storage = textView.textStorage
      else { return false }
      let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? textView.visibleRect
      let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect.insetBy(dx: 0, dy: -240), in: textContainer)
      let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
      guard characterRange.length > 0 else { return false }
      let lineRange = storage.mutableString.lineRange(for: characterRange)
      prepareViewportHighlighting(for: storage)
      let coveredRange = lineRange.location..<NSMaxRange(lineRange)
      guard !viewportHighlightedCharacterIndexes.contains(integersIn: coveredRange) else {
        return false
      }

      // Record coverage before mutating NSTextStorage. Attribute edits
      // invalidate TextKit layout and can synchronously or asynchronously
      // produce another clip-view bounds notification. Remembering every
      // covered line range makes those notifications converge even if layout
      // alternates between two neighboring visible ranges.
      viewportHighlightedCharacterIndexes.insert(integersIn: coveredRange)
      isApplyingViewportHighlighting = true
      defer { isApplyingViewportHighlighting = false }
      applySyntaxHighlighting(to: storage, characterRange: lineRange)
      return true
    }

    private func shouldHighlightVisibleRange(in textView: NSTextView) -> Bool {
      guard parent.liveHighlighting else { return false }
      return parent.incrementalHighlighting
        || Self.shouldUseViewportOnlyHighlighting(
          utf16Length: textView.textStorage?.length ?? 0,
          showsScrollers: parent.showsScrollers
        )
    }

    private func handleBoundaryArrowCommand(_ commandSelector: Selector, in textView: NSTextView) -> Bool {
      guard let syntaxTextView = textView as? OrgSyntaxTextView,
            syntaxTextView.documentSelectionContext != nil
      else {
        return false
      }
      let selectedRange = textView.selectedRange()
      guard selectedRange.length == 0 else {
        return false
      }
      let textLength = textView.textStorage?.length ?? 0
      let clampedLocation = min(max(0, selectedRange.location), textLength)

      switch commandSelector {
      case #selector(NSResponder.moveUp(_:)):
        guard clampedLocation == 0 else { return false }
        return OrgSyntaxTextSelectionBridge.moveCaretAcrossDocumentEditors(
          from: syntaxTextView,
          direction: .previous,
          placement: .end
        )
      case #selector(NSResponder.moveDown(_:)):
        guard clampedLocation == textLength else { return false }
        return OrgSyntaxTextSelectionBridge.moveCaretAcrossDocumentEditors(
          from: syntaxTextView,
          direction: .next,
          placement: .end
        )
      case #selector(NSResponder.moveLeft(_:)):
        guard clampedLocation == 0 else { return false }
        return OrgSyntaxTextSelectionBridge.moveCaretAcrossDocumentEditors(
          from: syntaxTextView,
          direction: .previous,
          placement: .end
        )
      case #selector(NSResponder.moveRight(_:)):
        guard clampedLocation == textLength else { return false }
        return OrgSyntaxTextSelectionBridge.moveCaretAcrossDocumentEditors(
          from: syntaxTextView,
          direction: .next,
          placement: .start
        )
      default:
        return false
      }
    }

    private func handleDeleteBackwardCommand(in textView: NSTextView) -> Bool {
      let selectedRange = textView.selectedRange()
      guard Self.shouldOfferDeleteBackwardCommand(selectedRange: selectedRange) else {
        return false
      }

      guard let onDeleteBackwardContext = parent.onDeleteBackwardContext else {
        return false
      }

      let text = flushTextPublishing(from: textView)
      return onDeleteBackwardContext(OrgSyntaxTextEditorSubmitContext(
        text: text,
        selectedRange: selectedRange
      ))
    }

    func invalidateHighlighting() {
      lastHighlightedText = nil
      lastHighlightedMonospaced = nil
      lastHighlightedConcealsSyntax = nil
      lastHighlightedLiveHighlighting = nil
      hasHighlightedText = false
      invalidateViewportHighlighting()
    }

    private func invalidateViewportHighlighting() {
      viewportHighlightedCharacterIndexes.removeAll()
      viewportHighlightUTF16Length = nil
      viewportHighlightMonospaced = nil
      viewportHighlightConcealsSyntax = nil
    }

    private func prepareViewportHighlighting(for storage: NSTextStorage) {
      guard viewportHighlightUTF16Length != storage.length
              || viewportHighlightMonospaced != parent.monospaced
              || viewportHighlightConcealsSyntax != parent.concealsSyntax
      else {
        return
      }
      viewportHighlightedCharacterIndexes.removeAll()
      viewportHighlightUTF16Length = storage.length
      viewportHighlightMonospaced = parent.monospaced
      viewportHighlightConcealsSyntax = parent.concealsSyntax
    }

    private func recordViewportHighlighting(
      _ range: NSRange,
      in storage: NSTextStorage
    ) {
      guard range.length > 0 else { return }
      prepareViewportHighlighting(for: storage)
      viewportHighlightedCharacterIndexes.insert(
        integersIn: range.location..<NSMaxRange(range)
      )
    }

    func resetLineIndex(from textView: NSTextView) {
      guard let text = textView.textStorage?.mutableString else {
        lineIndex.reset(with: "")
        isLineIndexReady = true
        return
      }
      lineIndex.reset(with: text)
      isLineIndexReady = true
      pendingLineIndexEdits = []
    }

    func scheduleLineIndexReset(text: String) {
      lineIndexBuildTask?.cancel()
      lineIndexBuildGeneration &+= 1
      let generation = lineIndexBuildGeneration
      let utf16Length = (text as NSString).length
      guard utf16Length > Self.synchronousTextSnapshotUTF16Limit else {
        lineIndex.reset(with: text as NSString)
        isLineIndexReady = true
        pendingLineIndexEdits = []
        return
      }

      isLineIndexReady = false
      pendingLineIndexEdits = []
      lineIndexBuildTask = Task { @MainActor [weak self] in
        let built = await Task.detached(priority: .utility) {
          OrgSourceLineIndex(text: text as NSString)
        }.value
        guard !Task.isCancelled,
              let self,
              self.lineIndexBuildGeneration == generation
        else { return }
        for edit in self.pendingLineIndexEdits {
          built.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        self.lineIndex = built
        self.pendingLineIndexEdits = []
        self.isLineIndexReady = true
        self.lineIndexBuildTask = nil
        self.gutterView?.invalidateVisibleGeometry()
        if let textView = self.activeTextView {
          self.publishSelectionSnapshotIfNeeded(textView.selectedRange(), from: textView)
          self.scheduleViewportSourceLinePublishing(for: textView, delayMilliseconds: 0)
        }
      }
    }

    func waitForLineIndexBuildForTesting() async {
      await lineIndexBuildTask?.value
    }

    func installSemanticSnapshotForTesting(_ snapshot: OrgSourceEditorSemanticSnapshot) {
      installCurrentSemanticSnapshot(snapshot)
    }

    func refreshSemanticPresentationForTesting(in textView: NSTextView) {
      refreshSemanticPresentation(to: textView)
    }

    var semanticPresentationRangeCountForTesting: Int {
      semanticPresentationRanges.count + diagnosticPresentationRanges.count
    }

    func resetBufferSession(to text: String) {
      bufferSession.reset(to: text)
      localTextGeneration = bufferSession.revision
      hasUnpublishedLocalText = false
    }

    private func synchronizeLineIndexIfNeeded(with textView: NSTextView) {
      guard isLineIndexReady else { return }
      let utf16Length = textView.textStorage?.length ?? 0
      guard lineIndex.documentUTF16Length != utf16Length else { return }
      resetLineIndex(from: textView)
    }

    private func invalidateKnownText() {
      lastKnownText = nil
      lastKnownTextUTF16Length = nil
      lastKnownTextGeneration = nil
    }

    private func snapshotCurrentText(from textView: NSTextView) -> String {
      let utf16Length = textView.textStorage?.length ?? 0
      if let known = knownText(matchingUTF16Length: utf16Length) {
        return known
      }
      fullDocumentSnapshotCount += 1
      mainActorFullDocumentSnapshotCount += 1
      let snapshot = bufferSession.snapshot().text
      recordKnownText(snapshot, utf16Length: utf16Length, isPublished: false)
      return snapshot
    }

    private func shouldSnapshotSynchronously(utf16Length: Int) -> Bool {
      if utf16Length <= Self.synchronousTextSnapshotUTF16Limit {
        return true
      }
      if case .immediate = parent.textPublishing {
        return true
      }
      return false
    }

    private var deferredTextPublishingDelayMilliseconds: Int {
      switch parent.textPublishing {
      case .immediate:
        return 0
      case .deferred(let milliseconds):
        return milliseconds
      }
    }

    static let synchronousTextSnapshotUTF16Limit = 64_000

    func hasExternalBoundTextChange(_ boundText: String) -> Bool {
      boundText != lastObservedBoundText
    }

    /// Delivers pending local text before accepting an authoritative bound
    /// replacement. Publishing both values in order lets the owner preserve
    /// the outgoing draft while the editor proceeds to the incoming document.
    @discardableResult
    func resolvePendingLocalText(
      beforeApplyingExternalText externalText: String,
      from textView: NSTextView,
      ownedBy providedPendingTextOwner: OrgSyntaxTextEditor? = nil
    ) -> String? {
      let pendingTextOwner = providedPendingTextOwner ?? parent
      cancelDeferredTextPublishing()
      let utf16Length = textView.textStorage?.length ?? 0
      guard utf16Length <= Self.synchronousTextSnapshotUTF16Limit else {
        checkpointPendingLocalTextBeforeExternalReplacement(ownedBy: pendingTextOwner)
        lastObservedBoundText = externalText
        invalidateKnownText()
        return nil
      }
      let localText = snapshotCurrentText(from: textView)
      pendingTextOwner.onLocalTextChange?(localText)
      let pendingTextBinding = pendingTextOwner.$text
      if pendingTextBinding.wrappedValue != localText {
        pendingTextBinding.wrappedValue = localText
      }
      recordKnownText(localText, utf16Length: textView.textStorage?.length, isPublished: true)

      if parent.text != externalText {
        parent.text = externalText
      }
      lastObservedBoundText = externalText
      if externalText != localText {
        invalidateKnownText()
      }
      return localText
    }

    private func checkpointPendingLocalTextBeforeExternalReplacement(
      ownedBy pendingTextOwner: OrgSyntaxTextEditor
    ) {
      guard hasUnpublishedLocalText else { return }
      let checkpointID = UUID()
      let session = bufferSession
      let capture = session.capture()
      let directCheckpoint = pendingTextOwner.onCheckpointText
      let localChange = pendingTextOwner.onLocalTextChange
      let conflictHandler = pendingTextOwner.onTextPublicationConflict
      let orderingKey = pendingTextOwner.documentIdentity ?? lifecycleID.uuidString
      let predecessor = Self.textCheckpointTailsByDocument[orderingKey]?.task
      let snapshotProvider = checkpointSnapshotForTesting

      hasUnpublishedLocalText = false
      detachedTextCheckpointCount += 1
      let task = Task { @MainActor [weak self, predecessor] in
        if let predecessor {
          await predecessor.value
        }
        self?.fullDocumentSnapshotCount += 1
        let snapshot = await Self.materializeCheckpoint(
          session: session,
          capture: capture,
          provider: snapshotProvider
        )
        defer {
          self?.detachedTextCheckpointCount = max(
            0,
            (self?.detachedTextCheckpointCount ?? 1) - 1
          )
          Self.pendingTextCheckpointTasks.removeValue(forKey: checkpointID)
          if Self.textCheckpointTailsByDocument[orderingKey]?.identifier == checkpointID {
            Self.textCheckpointTailsByDocument.removeValue(forKey: orderingKey)
          }
        }
        guard snapshot.revision == capture.revision else { return }
        if let directCheckpoint {
          directCheckpoint(snapshot.text)
        } else if let conflictHandler {
          conflictHandler(snapshot.text)
        } else {
          localChange?(snapshot.text)
        }
      }
      Self.pendingTextCheckpointTasks[checkpointID] = task
      Self.textCheckpointTailsByDocument[orderingKey] = (checkpointID, task)
    }

    @discardableResult
    func flushPendingTextPublishingIfNeeded(from textView: NSTextView) -> String? {
      guard hasUnpublishedLocalText else { return nil }
      let boundText = parent.text
      if hasExternalBoundTextChange(boundText) {
        return resolvePendingLocalText(
          beforeApplyingExternalText: boundText,
          from: textView
        )
      }
      return flushTextPublishing(from: textView)
    }

    func recordKnownText(
      _ text: String,
      utf16Length providedUTF16Length: Int? = nil,
      isPublished: Bool = true
    ) {
      lastKnownText = text
      lastKnownTextUTF16Length = providedUTF16Length ?? (text as NSString).length
      lastKnownTextGeneration = localTextGeneration
      if isPublished {
        hasUnpublishedLocalText = false
        lastObservedBoundText = text
      }
    }

    func knownText(matchingUTF16Length utf16Length: Int?) -> String? {
      guard let utf16Length,
            let lastKnownText,
            lastKnownTextUTF16Length == utf16Length,
            lastKnownTextGeneration == localTextGeneration
      else {
        return nil
      }
      return lastKnownText
    }

    func markUserTextChangedForHighlighting(
      in textView: NSTextView,
      currentText: String? = nil,
      utf16Length providedUTF16Length: Int? = nil,
      willScheduleDeferredHighlighting: Bool = true
    ) {
      let utf16Length = providedUTF16Length
        ?? textView.textStorage?.length
        ?? currentText.map { ($0 as NSString).length }
        ?? 0
      if canPreserveLargeBufferAttributes(utf16Length: utf16Length) {
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced, prose: parent.isProse)
        recordHighlightedState(text: currentText, utf16Length: utf16Length)
        return
      }
      let text = currentText ?? snapshotCurrentText(from: textView)
      if !willScheduleDeferredHighlighting {
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced, prose: parent.isProse)
        recordHighlightedState(text: text, utf16Length: utf16Length)
        return
      }
      invalidateHighlighting()
    }

    func cancelDeferredHighlighting() {
      deferredHighlightTask?.cancel()
      deferredHighlightTask = nil
      deferredHighlightText = nil
      deferredHighlightMonospaced = nil
      deferredIncrementalHighlightTask?.cancel()
      deferredIncrementalHighlightTask = nil
      deferredIncrementalHighlightText = nil
      deferredIncrementalHighlightGeneration = nil
      deferredIncrementalHighlightRange = nil
    }

    func cancelDeferredTextPublishing() {
      deferredTextPublishTask?.cancel()
      deferredTextPublishTask = nil
      deferredTextPublishText = nil
      deferredTextPublishUTF16Length = nil
      deferredTextPublishGeneration += 1
    }

    func hasPendingTextPublishing(for text: String) -> Bool {
      guard deferredTextPublishTask != nil else { return false }
      if let deferredTextPublishText {
        return deferredTextPublishText == text
      }
      return deferredTextPublishUTF16Length == (text as NSString).length
    }

    func hasDeferredHighlighting(for text: String) -> Bool {
      (deferredHighlightTask != nil
        && deferredHighlightText == text
        && deferredHighlightMonospaced == parent.monospaced)
        || (deferredIncrementalHighlightTask != nil
          && deferredIncrementalHighlightGeneration == localTextGeneration
          && (deferredIncrementalHighlightText == nil
            || deferredIncrementalHighlightText == text))
    }

    var hasDeferredHighlightingForCurrentBuffer: Bool {
      (deferredHighlightTask != nil
        && deferredHighlightMonospaced == parent.monospaced)
        || (deferredIncrementalHighlightTask != nil
          && deferredIncrementalHighlightGeneration == localTextGeneration)
    }

    func applyHighlightingIfNeeded(to textView: NSTextView, currentText: String? = nil) {
      let utf16Length = textView.textStorage?.length
        ?? currentText.map { ($0 as NSString).length }
        ?? 0
      if canPreserveLargeBufferAttributes(utf16Length: utf16Length) {
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: parent.monospaced, prose: parent.isProse)
        recordHighlightedState(text: currentText, utf16Length: utf16Length)
        return
      }

      let text = currentText ?? snapshotCurrentText(from: textView)

      guard lastHighlightedText != text
              || lastHighlightedMonospaced != parent.monospaced
              || lastHighlightedConcealsSyntax != parent.concealsSyntax
              || lastHighlightedLiveHighlighting != parent.liveHighlighting
      else {
        return
      }
      applyHighlighting(to: textView)
    }

    private func canPreserveLargeBufferAttributes(utf16Length: Int) -> Bool {
      guard hasHighlightedText,
            lastHighlightedMonospaced == parent.monospaced,
            lastHighlightedConcealsSyntax == parent.concealsSyntax,
            lastHighlightedLiveHighlighting == parent.liveHighlighting
      else {
        return false
      }
      return OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
        utf16Length: utf16Length,
        hasHighlightedBefore: hasHighlightedText,
        monospacedUnchanged: lastHighlightedMonospaced == parent.monospaced
      )
    }

    private func publishTextChange(_ currentText: String) {
      guard parent.text != currentText else {
        cancelDeferredTextPublishing()
        recordKnownText(currentText, isPublished: true)
        return
      }

      if parent.shouldPublishTextImmediately?(currentText) == true {
        cancelDeferredTextPublishing()
        parent.text = currentText
        recordKnownText(currentText, isPublished: true)
        return
      }

      switch parent.textPublishing {
      case .immediate:
        cancelDeferredTextPublishing()
        parent.text = currentText
        recordKnownText(currentText, isPublished: true)
      case .deferred(let milliseconds):
        scheduleDeferredTextPublishing(currentText, milliseconds: milliseconds)
      }
    }

    private struct TextPublicationBoundary {
      let bindingGeneration: (() -> UInt64)?
      let expectedBindingGeneration: UInt64?
      let baselineText: String
      let conflictHandler: ((String) -> Void)?
    }

    private struct DocumentBoundary {
      let generation: (() -> UInt64)?
      let expectedGeneration: UInt64?
    }

    private func documentBoundary() -> DocumentBoundary {
      let generation = parent.documentGeneration
      return DocumentBoundary(
        generation: generation,
        expectedGeneration: generation?()
      )
    }

    private func documentIsCurrent(for boundary: DocumentBoundary) -> Bool {
      guard let generation = boundary.generation,
            let expected = boundary.expectedGeneration
      else { return true }
      return generation() == expected
    }

    private func textPublicationBoundary() -> TextPublicationBoundary {
      let bindingGeneration = parent.bindingGeneration
      return TextPublicationBoundary(
        bindingGeneration: bindingGeneration,
        expectedBindingGeneration: bindingGeneration?(),
        baselineText: parent.text,
        conflictHandler: parent.onTextPublicationConflict
      )
    }

    private func bindingIsCurrent(for boundary: TextPublicationBoundary) -> Bool {
      if let bindingGeneration = boundary.bindingGeneration,
         let expected = boundary.expectedBindingGeneration {
        return bindingGeneration() == expected
      }
      return parent.text == boundary.baselineText
    }

    private func finishConflictedTextPublication(
      _ text: String,
      boundary: TextPublicationBoundary
    ) {
      deferredTextPublishTask = nil
      deferredTextPublishText = nil
      deferredTextPublishUTF16Length = nil
      hasUnpublishedLocalText = false
      invalidateKnownText()
      boundary.conflictHandler?(text)
    }

    @discardableResult
    private func flushTextPublishing(from textView: NSTextView) -> String {
      let shouldNotifyLocalChange = hasUnpublishedLocalText
      cancelDeferredTextPublishing()
      let snapshot = snapshotCurrentText(from: textView)
      if shouldNotifyLocalChange {
        parent.onLocalTextChange?(snapshot)
      }
      if parent.text != snapshot {
        parent.text = snapshot
      }
      recordKnownText(snapshot, isPublished: true)
      return snapshot
    }

    private func scheduleDeferredTextPublishing(_ text: String, milliseconds: Int) {
      cancelDeferredTextPublishing()
      deferredTextPublishGeneration += 1
      let generation = deferredTextPublishGeneration
      let textGeneration = localTextGeneration
      let boundary = textPublicationBoundary()
      deferredTextPublishText = text
      deferredTextPublishUTF16Length = (text as NSString).length

      deferredTextPublishTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled,
              let self,
              self.deferredTextPublishGeneration == generation,
              self.localTextGeneration == textGeneration,
              let expectedText = self.deferredTextPublishText
        else { return }
        guard self.bindingIsCurrent(for: boundary) else {
          self.finishConflictedTextPublication(expectedText, boundary: boundary)
          return
        }
        self.deferredTextPublishTask = nil
        self.deferredTextPublishText = nil
        self.deferredTextPublishUTF16Length = nil
        if self.parent.text != expectedText {
          self.parent.text = expectedText
        }
        self.recordKnownText(expectedText, isPublished: true)
      }
    }

    private func scheduleDeferredTextPublishing(
      from textView: NSTextView,
      milliseconds: Int
    ) {
      cancelDeferredTextPublishing()
      deferredTextPublishGeneration += 1
      let generation = deferredTextPublishGeneration
      let textGeneration = localTextGeneration
      let bufferCapture = bufferSession.capture()
      let boundary = textPublicationBoundary()
      let expectedUTF16Length = textView.textStorage?.length ?? 0
      deferredTextPublishUTF16Length = expectedUTF16Length

      let session = bufferSession
      deferredTextPublishTask = Task { @MainActor [weak self, weak textView] in
        do {
          try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled,
              let self,
              let textView,
              self.deferredTextPublishGeneration == generation,
              self.localTextGeneration == textGeneration,
              textView.textStorage?.length == expectedUTF16Length
        else { return }

        self.fullDocumentSnapshotCount += 1
        let snapshot: OrgSyntaxTextBufferSession.Snapshot
        if let deferredTextSnapshotForTesting = self.deferredTextSnapshotForTesting {
          snapshot = await deferredTextSnapshotForTesting()
        } else {
          snapshot = await session.snapshotAsync(
            from: bufferCapture,
            priority: .utility
          )
        }
        guard !Task.isCancelled,
              self.deferredTextPublishGeneration == generation,
              self.localTextGeneration == textGeneration,
              snapshot.revision == bufferCapture.revision
        else { return }
        guard self.bindingIsCurrent(for: boundary) else {
          self.finishConflictedTextPublication(snapshot.text, boundary: boundary)
          return
        }
        self.deferredTextPublishTask = nil
        self.deferredTextPublishText = nil
        self.deferredTextPublishUTF16Length = nil
        self.parent.onLocalTextChange?(snapshot.text)
        self.parent.text = snapshot.text
        self.recordKnownText(snapshot.text, isPublished: true)
      }
    }

    private func scheduleDeferredHighlighting(to textView: NSTextView, expectedText: String) {
      cancelDeferredHighlighting()
      let expectedMonospaced = parent.monospaced
      let documentBoundary = documentBoundary()
      deferredHighlightText = expectedText
      deferredHighlightMonospaced = expectedMonospaced

      deferredHighlightTask = Task { @MainActor [weak self, weak textView] in
        do {
          try await Task.sleep(nanoseconds: 90_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled, let self, let textView else { return }
        guard self.deferredHighlightText == expectedText,
              self.deferredHighlightMonospaced == expectedMonospaced,
              self.documentIsCurrent(for: documentBoundary)
        else { return }

        self.deferredHighlightTask = nil
        self.deferredHighlightText = nil
        self.deferredHighlightMonospaced = nil
        self.applyHighlightingIfNeeded(to: textView, currentText: expectedText)
      }
    }

    private func publishSelectionIfNeeded(_ selectedRange: NSRange, in text: String) {
      guard let selection = parent.selection,
            selection.wrappedValue != selectedRange
      else {
        return
      }
      guard Self.shouldPublishSelection(
        selectedRange,
        previousRange: selection.wrappedValue,
        text: text
      ) else {
        return
      }
      if selectedRange.length == 0,
         parent.caretPublishingDelayMilliseconds > 0 {
        scheduleDeferredCaretPublishing(
          selectedRange,
          milliseconds: parent.caretPublishingDelayMilliseconds
        )
        return
      }
      cancelDeferredCaretPublishing()
      selection.wrappedValue = selectedRange
    }

    private func publishSelectionIfNeeded(_ selectedRange: NSRange, from textView: NSTextView) {
      let selection = parent.selection
      let selectionNeedsUpdate = selection.map { $0.wrappedValue != selectedRange } ?? false
      guard selectionNeedsUpdate || parent.onSelectionSnapshot != nil else { return }

      // A caret-only move does not need the buffer contents. Publishing it
      // after the existing debounce keeps restoration accurate without
      // copying or scanning a large file on every arrow key or click. The
      // optional local snapshot is capped to a small window and obtains its
      // line from the editor's incremental index.
      if selectedRange.length == 0,
         (selection?.wrappedValue.length ?? 0) == 0 {
        if parent.caretPublishingDelayMilliseconds > 0 {
          scheduleDeferredCaretPublishing(
            selectedRange,
            milliseconds: parent.caretPublishingDelayMilliseconds,
            textView: textView
          )
        } else {
          cancelDeferredCaretPublishing()
          publishSelectionSnapshotIfNeeded(selectedRange, from: textView)
          if selectionNeedsUpdate {
            selection?.wrappedValue = selectedRange
          }
        }
        return
      }

      if selectedRange.length == 0,
         parent.caretPublishingDelayMilliseconds > 0 {
        scheduleDeferredCaretPublishing(
          selectedRange,
          milliseconds: parent.caretPublishingDelayMilliseconds,
          textView: textView
        )
      } else {
        cancelDeferredCaretPublishing()
        publishSelectionSnapshotIfNeeded(selectedRange, from: textView)
        if selectionNeedsUpdate {
          selection?.wrappedValue = selectedRange
        }
      }
    }

    private func scheduleDeferredCaretPublishing(
      _ range: NSRange,
      milliseconds: Int,
      textView: NSTextView? = nil
    ) {
      cancelDeferredCaretPublishing()
      deferredCaretPublishGeneration += 1
      let generation = deferredCaretPublishGeneration
      let documentBoundary = documentBoundary()
      deferredCaretPublishRange = range

      deferredCaretPublishTask = Task { @MainActor [weak self, weak textView] in
        do {
          try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled,
              let self,
              self.deferredCaretPublishGeneration == generation,
              self.documentIsCurrent(for: documentBoundary),
              let expectedRange = self.deferredCaretPublishRange
        else { return }
        self.deferredCaretPublishTask = nil
        self.deferredCaretPublishRange = nil
        if let textView,
           textView.selectedRange() == expectedRange {
          self.publishSelectionSnapshotIfNeeded(expectedRange, from: textView)
        }
        if self.parent.selection?.wrappedValue != expectedRange {
          self.parent.selection?.wrappedValue = expectedRange
        }
      }
    }

    private func flushCaretPublishing(from textView: NSTextView) {
      cancelDeferredCaretPublishing()
      let range = textView.selectedRange()
      publishSelectionSnapshotIfNeeded(range, from: textView)
      if parent.selection?.wrappedValue != range {
        parent.selection?.wrappedValue = range
      }
    }

    private func cancelDeferredCaretPublishing() {
      deferredCaretPublishTask?.cancel()
      deferredCaretPublishTask = nil
      deferredCaretPublishRange = nil
      deferredCaretPublishGeneration += 1
    }

    func shouldReadTextForSelectionPublishing(_ selectedRange: NSRange) -> Bool {
      if parent.onSelectionSnapshot != nil { return true }
      guard let selection = parent.selection else { return false }
      return selection.wrappedValue != selectedRange
    }

    private func publishSelectionSnapshotIfNeeded(
      _ requestedRange: NSRange,
      from textView: NSTextView
    ) {
      guard let publish = parent.onSelectionSnapshot,
            let snapshot = selectionSnapshot(requestedRange, from: textView)
      else { return }
      guard snapshot != lastPublishedSelectionSnapshot else { return }
      lastPublishedSelectionSnapshot = snapshot
      publish(snapshot)
    }

    /// A bounded snapshot of the text before the caret. It never copies the
    /// whole buffer, so completion handlers can use it on every key command.
    func selectionSnapshot(
      _ requestedRange: NSRange,
      from textView: NSTextView
    ) -> OrgSyntaxTextEditorSelectionSnapshot? {
      guard let storage = textView.textStorage?.mutableString else { return nil }

      let selectedRange = OrgSyntaxTextEditor.clampedRange(
        requestedRange,
        utf16Length: storage.length
      )
      let caret = selectedRange.location
      var windowStart = max(0, caret - Self.selectionSnapshotLookbehindUTF16Length)
      // Do not split a surrogate pair when the bounded window begins inside
      // one. NSTextView selections themselves are already valid boundaries.
      if windowStart > 0,
         windowStart < storage.length,
         (0xDC00...0xDFFF).contains(storage.character(at: windowStart)),
         (0xD800...0xDBFF).contains(storage.character(at: windowStart - 1)) {
        windowStart -= 1
      }
      let localRange = NSRange(
        location: windowStart,
        length: max(0, caret - windowStart)
      )
      let sourceLine: Int?
      if isLineIndexReady,
         lineIndex.documentUTF16Length == storage.length {
        sourceLine = lineIndex.lineNumber(atUTF16Offset: caret)
      } else {
        sourceLine = nil
      }
      return OrgSyntaxTextEditorSelectionSnapshot(
        selectedRange: selectedRange,
        sourceLine: sourceLine,
        localText: storage.substring(with: localRange),
        localTextRange: localRange
      )
    }

    static func shouldPublishSelection(
      _ selectedRange: NSRange,
      previousRange: NSRange,
      text: String
    ) -> Bool {
      if selectedRange.length > 0 || previousRange.length > 0 {
        return true
      }
      if abs(selectedRange.location - previousRange.location) <= selectionInlineSyntaxRadius {
        return hasInlineSyntaxNearSelectionWindow(
          text,
          selectedRange: selectedRange,
          previousRange: previousRange
        )
      }
      return OrgInlineParser.hasInlineSyntaxCandidate(
        text,
        near: selectedRange,
        radius: selectionInlineSyntaxRadius
      ) || OrgInlineParser.hasInlineSyntaxCandidate(
        text,
        near: previousRange,
        radius: selectionInlineSyntaxRadius
      )
    }

    static func hasInlineSyntaxNearSelectionWindow(
      _ text: String,
      selectedRange: NSRange,
      previousRange: NSRange
    ) -> Bool {
      let midpoint = (selectedRange.location + previousRange.location) / 2
      let distance = abs(selectedRange.location - previousRange.location)
      return OrgInlineParser.hasInlineSyntaxCandidate(
        text,
        near: NSRange(location: midpoint, length: 0),
        radius: selectionInlineSyntaxRadius + (distance / 2) + 1
      )
    }

    static let selectionInlineSyntaxRadius = 512
    static let selectionSnapshotLookbehindUTF16Length = 4_096

    static func shouldApplyExternalSelection(
      requestedSelection: NSRange,
      currentSelection: NSRange,
      isFirstResponder: Bool,
      didApplyProgrammaticText: Bool
    ) -> Bool {
      if didApplyProgrammaticText {
        return true
      }
      if !isFirstResponder {
        return true
      }
      return requestedSelection.length > 0 || currentSelection.length > 0
    }

    static func preferredSelectionAfterProgrammaticTextUpdate(
      requestedSelection: NSRange?,
      currentSelection: NSRange,
      isFirstResponder: Bool,
      updatedUTF16Length: Int
    ) -> NSRange? {
      let current = OrgSyntaxTextEditor.clampedRange(
        currentSelection,
        utf16Length: updatedUTF16Length
      )
      guard let requestedSelection else {
        return isFirstResponder ? current : nil
      }
      let requested = OrgSyntaxTextEditor.clampedRange(
        requestedSelection,
        utf16Length: updatedUTF16Length
      )
      guard isFirstResponder,
            requested.length == 0,
            current.length == 0,
            abs(requested.location - current.location) > selectionInlineSyntaxRadius
      else {
        return requested
      }
      return current
    }

    static func shouldOfferDeleteBackwardCommand(selectedRange: NSRange) -> Bool {
      selectedRange.location == 0 && selectedRange.length == 0
    }

    static func shouldScheduleDeferredHighlighting(
      text: String,
      previousHighlightedText: String?,
      monospacedUnchanged: Bool
    ) -> Bool {
      shouldScheduleDeferredHighlighting(
        text: text,
        utf16Length: OrgSyntaxHighlighter.utf16Length(
          of: text,
          upTo: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1
        ),
        previousHighlightedText: previousHighlightedText,
        monospacedUnchanged: monospacedUnchanged
      )
    }

    static func shouldScheduleDeferredHighlighting(
      text: String,
      utf16Length: Int,
      previousHighlightedText: String?,
      monospacedUnchanged: Bool
    ) -> Bool {
      guard OrgSyntaxHighlighter.shouldTokenizeLiveText(utf16Length: utf16Length) else {
        return false
      }
      guard monospacedUnchanged else {
        return true
      }
      if OrgSyntaxHighlighter.hasSyntaxCandidate(text) {
        return true
      }
      if let previousHighlightedText {
        return OrgSyntaxHighlighter.hasSyntaxCandidate(previousHighlightedText)
      }
      return false
    }

    static func shouldUseViewportOnlyHighlighting(
      utf16Length: Int,
      showsScrollers: Bool
    ) -> Bool {
      showsScrollers
        && utf16Length > OrgSyntaxHighlighter.liveTokenizationUTF16Limit
    }

    func applyHighlighting(to textView: NSTextView) {
      cancelDeferredHighlighting()
      guard let storage = textView.textStorage else { return }
      invalidateViewportHighlighting()
      let selectedRanges = textView.selectedRanges
      let visibleOrigin = Self.visibleOrigin(of: textView)
      if Self.shouldUseViewportOnlyHighlighting(
        utf16Length: storage.length,
        showsScrollers: parent.showsScrollers
      ) {
        // NSTextView assigned base attributes while creating the storage.
        // Resetting the complete attributed string here is an avoidable O(N)
        // main-thread pass. Restyle only laid-out lines now and each newly
        // visible range as the user scrolls.
        textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(
          monospaced: parent.monospaced,
          prose: parent.isProse
        )
        if parent.liveHighlighting {
          highlightVisibleRange(in: textView)
        }
        textView.selectedRanges = selectedRanges
        Self.restoreVisibleOrigin(visibleOrigin, of: textView)
        recordHighlightedState(text: nil, utf16Length: storage.length)
        publishContentHeight(for: textView)
        return
      }
      let typingAttributes = applySyntaxHighlighting(to: storage, characterRange: nil)
      textView.typingAttributes = typingAttributes
      textView.selectedRanges = selectedRanges
      if OrgSyntaxHighlighter.shouldTokenizeLiveText(utf16Length: storage.length) {
        recordViewportHighlighting(
          NSRange(location: 0, length: storage.length),
          in: storage
        )
      }
      Self.restoreVisibleOrigin(visibleOrigin, of: textView)
      recordHighlightedState(for: textView)
      publishContentHeight(for: textView)
    }

    func publishContentHeight(for textView: NSTextView) {
      guard parent.contentHeight != nil else { return }
      deferredContentHeightPublishTask?.cancel()
      deferredContentHeightPublishGeneration += 1
      let generation = deferredContentHeightPublishGeneration
      deferredContentHeightPublishTask = Task { @MainActor [weak self, weak textView] in
        // Coalesce a burst into one layout pass on the next frame. Dispatching
        // one cancelled work item per key still left a visible main-queue tail.
        do {
          try await Task.sleep(nanoseconds: 16_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled,
              let self,
              self.deferredContentHeightPublishGeneration == generation,
              let textView,
              let contentHeight = self.parent.contentHeight
        else { return }
        self.deferredContentHeightPublishTask = nil
        let nextHeight = Self.measuredContentHeight(for: textView)
        guard abs(contentHeight.wrappedValue - nextHeight) > 0.5 else { return }
        contentHeight.wrappedValue = nextHeight
      }
    }

    static func measuredContentHeight(for textView: NSTextView) -> CGFloat {
      guard let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
      else {
        return 0
      }
      textContainer.containerSize = NSSize(
        width: max(1, textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width),
        height: CGFloat.greatestFiniteMagnitude
      )
      layoutManager.ensureLayout(for: textContainer)
      let usedRect = layoutManager.usedRect(for: textContainer)
      return ceil(max(0, usedRect.height) + textView.textContainerInset.height * 2 + 2)
    }

    static func visibleOrigin(of textView: NSTextView) -> NSPoint? {
      textView.enclosingScrollView?.contentView.bounds.origin
    }

    static func restoreVisibleOrigin(_ origin: NSPoint?, of textView: NSTextView) {
      guard let origin,
            let scrollView = textView.enclosingScrollView
      else {
        return
      }
      let clipView = scrollView.contentView
      guard !NSEqualPoints(clipView.bounds.origin, origin) else { return }
      clipView.scroll(to: origin)
      scrollView.reflectScrolledClipView(clipView)
    }

    private func recordHighlightedState(for textView: NSTextView) {
      let utf16Length = textView.textStorage?.length ?? 0
      hasHighlightedText = true
      lastHighlightedMonospaced = parent.monospaced
      lastHighlightedConcealsSyntax = parent.concealsSyntax
      lastHighlightedLiveHighlighting = parent.liveHighlighting
      lastHighlightedText = OrgSyntaxHighlighter.shouldTokenizeLiveText(utf16Length: utf16Length)
        ? textView.string
        : nil
    }

    private func recordHighlightedState(text: String?, utf16Length: Int) {
      hasHighlightedText = true
      lastHighlightedMonospaced = parent.monospaced
      lastHighlightedConcealsSyntax = parent.concealsSyntax
      lastHighlightedLiveHighlighting = parent.liveHighlighting
      if OrgSyntaxHighlighter.shouldTokenizeLiveText(utf16Length: utf16Length) {
        lastHighlightedText = text
      } else {
        lastHighlightedText = nil
      }
    }
  }
}

struct OrgSyntaxHighlightToken: Equatable {
  let kind: OrgSyntaxHighlightKind
  let range: NSRange
}

enum OrgSyntaxHighlightKind: String {
  case headingStars
  case headingTitle
  case keyword
  case planningKeyword
  case propertyKey
  case todo
  case priority
  case tag
  case link
  case linkTarget
  case code
  case emphasis
  case timestamp
  case syntaxDelimiter
  case comment
  /// The text of a list item whose checkbox is checked (`- [X] text`).
  case checkedListItem
  /// A finished keyword (`DONE`), drawn like Emacs `org-done`.
  case doneTodo
  /// A canceled keyword (`CANCELED`/`CANCELLED`), greyed out.
  case canceledTodo
  /// The title of a `DONE` heading, softened like `org-headline-done`.
  case doneHeadingTitle
  /// The title of a canceled heading, greyed out and struck through.
  case canceledHeadingTitle
}

/// Presentation-only tokenization for the native editor. Semantic org2 structure
/// should come from the canonical org2 parser/CLI, not this highlighter.
enum OrgSyntaxHighlighter {
  static let liveTokenizationUTF16Limit = 25_000

  static func baseTypingAttributes(monospaced: Bool, prose: Bool = false) -> [NSAttributedString.Key: Any] {
    baseAttributes(font: baseFont(monospaced: monospaced, prose: prose), prose: prose)
  }

  static func tokens(in text: String) -> [OrgSyntaxHighlightToken] {
    var tokens: [OrgSyntaxHighlightToken] = []
    collectLineTokens(in: text, into: &tokens)
    collectInlineTokens(in: text, into: &tokens)
    return tokens.sorted {
      if $0.range.location != $1.range.location {
        return $0.range.location < $1.range.location
      }
      return $0.range.length > $1.range.length
    }
  }

  @discardableResult
  static func apply(
    to storage: NSTextStorage,
    monospaced: Bool,
    concealsSyntax: Bool = true,
    prose: Bool = false
  ) -> [NSAttributedString.Key: Any] {
    let baseFont = baseFont(monospaced: monospaced, prose: prose)
    let baseAttributes = baseAttributes(font: baseFont, prose: prose)
    let fullRange = NSRange(location: 0, length: storage.length)

    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: fullRange)
    if shouldTokenizeLiveText(utf16Length: storage.length) {
      let text = storage.string
      for token in tokens(in: text) where NSMaxRange(token.range) <= storage.length {
        storage.addAttributes(
          attributes(for: token.kind, baseFont: baseFont, concealsSyntax: concealsSyntax, prose: prose),
          range: token.range
        )
      }
    }
    storage.endEditing()
    return baseAttributes
  }

  @discardableResult
  static func apply(
    to storage: NSTextStorage,
    characterRange requestedRange: NSRange,
    monospaced: Bool,
    concealsSyntax: Bool,
    prose: Bool = false
  ) -> [NSAttributedString.Key: Any] {
    let baseFont = baseFont(monospaced: monospaced, prose: prose)
    let baseAttributes = baseAttributes(font: baseFont, prose: prose)
    guard storage.length > 0 else { return baseAttributes }
    let location = min(max(0, requestedRange.location), storage.length)
    let length = min(max(0, requestedRange.length), storage.length - location)
    // NSTextStorage already exposes its mutable NSString backing. Reading
    // storage.string here materializes the entire document even though live
    // highlighting only needs the edited line.
    let nsText = storage.mutableString
    let lineRange = nsText.lineRange(for: NSRange(location: location, length: length))
    let substring = nsText.substring(with: lineRange)

    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: lineRange)
    for token in tokens(in: substring) {
      let range = NSRange(
        location: lineRange.location + token.range.location,
        length: token.range.length
      )
      guard NSMaxRange(range) <= storage.length else { continue }
      storage.addAttributes(
        attributes(for: token.kind, baseFont: baseFont, concealsSyntax: concealsSyntax, prose: prose),
        range: range
      )
    }
    storage.endEditing()
    return baseAttributes
  }

  static func shouldTokenizeLiveText(utf16Length: Int) -> Bool {
    utf16Length <= liveTokenizationUTF16Limit
  }

  static func shouldTokenizeLiveText(_ text: String) -> Bool {
    utf16Length(of: text, upTo: liveTokenizationUTF16Limit + 1) <= liveTokenizationUTF16Limit
  }

  static func utf16Length(of text: String, upTo limit: Int? = nil) -> Int {
    var count = 0
    for _ in text.utf16 {
      count += 1
      if let limit, count >= limit {
        return count
      }
    }
    return count
  }

  static func hasSyntaxCandidate(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    var httpMatchIndex = 0
    for byte in text.utf8 {
      switch byte {
      case 35, 40, 42, 43, 47, 58, 60, 61, 91, 93, 95, 96, 126:
        return true
      default:
        if byte == httpBytes[httpMatchIndex] {
          httpMatchIndex += 1
          if httpMatchIndex == httpBytes.count {
            return true
          }
        } else {
          httpMatchIndex = byte == httpBytes[0] ? 1 : 0
        }
      }
    }
    return false
  }

  private static let httpBytes: [UInt8] = [104, 116, 116, 112]

  static func shouldPreserveExistingAttributesAfterEdit(
    utf16Length: Int,
    hasHighlightedBefore: Bool,
    monospacedUnchanged: Bool
  ) -> Bool {
    hasHighlightedBefore
      && monospacedUnchanged
      && !shouldTokenizeLiveText(utf16Length: utf16Length)
  }

  /// A calm serif for Prose mode, drawn from the system's New York design.
  static func proseFont(size: CGFloat = 17, weight: NSFont.Weight = .regular) -> NSFont {
    let system = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = system.fontDescriptor.withDesign(.serif),
          let serif = NSFont(descriptor: descriptor, size: size)
    else { return system }
    return serif
  }

  static func baseFont(monospaced: Bool, prose: Bool = false) -> NSFont {
    if prose { return proseFont() }
    return monospaced
      ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      : NSFont.systemFont(ofSize: NSFont.systemFontSize)
  }

  private static func collectLineTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    guard !text.isEmpty else { return }
    var lineOffset = 0
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, lineSlice) in lines.enumerated() {
      let lineLength = lineSlice.utf16.count
      if lineMayContainBlockSyntax(lineSlice) {
        let line = String(lineSlice)
        collectHeadingTokens(line: line, lineOffset: lineOffset, into: &tokens)
        collectLineRegex(regex: keywordLineRegex, kind: .keyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
        collectLineRegex(regex: blockKeywordLineRegex, kind: .keyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
        collectLineRegex(regex: planningLineRegex, kind: .planningKeyword, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
        collectLineRegex(regex: propertyLineRegex, kind: .propertyKey, line: line, lineOffset: lineOffset, capture: 1, into: &tokens)
        collectLineRegex(regex: commentLineRegex, kind: .comment, line: line, lineOffset: lineOffset, into: &tokens)
      }
      if lineMayContainCheckedCheckbox(lineSlice) {
        collectLineRegex(
          regex: checkedListItemRegex,
          kind: .checkedListItem,
          line: String(lineSlice),
          lineOffset: lineOffset,
          capture: 1,
          into: &tokens
        )
      }
      lineOffset += lineLength
      if index < lines.count - 1 {
        lineOffset += 1
      }
    }
  }

  static func lineMayContainBlockSyntax(_ line: Substring) -> Bool {
    guard !line.isEmpty else { return false }
    if line.first == "*" {
      return true
    }

    var cursor = line.startIndex
    while cursor < line.endIndex, line[cursor].isWhitespace {
      cursor = line.index(after: cursor)
    }
    guard cursor < line.endIndex else { return false }

    switch line[cursor] {
    case "#", ":":
      return true
    case "C":
      return line[cursor...].hasPrefix("CLOSED")
    case "D":
      return line[cursor...].hasPrefix("DEADLINE")
    case "S":
      return line[cursor...].hasPrefix("SCHEDULED")
    default:
      return false
    }
  }

  /// Cheap pre-check for `[X]`/`[x]` before running the checked-item regex.
  static func lineMayContainCheckedCheckbox(_ line: Substring) -> Bool {
    line.contains("[X]") || line.contains("[x]")
  }

  private static func collectHeadingTokens(line: String, lineOffset: Int, into tokens: inout [OrgSyntaxHighlightToken]) {
    let ns = line as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    guard let match = headingLineRegex.firstMatch(in: line, range: fullRange),
          match.range.location == 0
    else {
      return
    }

    let keywordRange = match.range(at: 2)
    let todoState = keywordRange.location == NSNotFound
      ? nil
      : OrgTodoVisualState.classify(ns.substring(with: keywordRange))
    append(match.range(at: 1), kind: .headingStars, lineOffset: lineOffset, into: &tokens)
    append(
      keywordRange,
      kind: todoState == .done ? .doneTodo : todoState == .canceled ? .canceledTodo : .todo,
      lineOffset: lineOffset,
      into: &tokens
    )
    append(match.range(at: 3), kind: .priority, lineOffset: lineOffset, into: &tokens)

    let tagMatch = headingTagRegex.firstMatch(in: line, range: fullRange)
    if let tagMatch {
      append(tagMatch.range(at: 1), kind: .tag, lineOffset: lineOffset, into: &tokens)
    }

    var titleStart = match.range.location + match.range.length
    while titleStart < ns.length,
          CharacterSet.whitespaces.contains(UnicodeScalar(ns.character(at: titleStart)) ?? " ") {
      titleStart += 1
    }
    var titleEnd = tagMatch?.range.location ?? ns.length
    while titleEnd > titleStart,
          CharacterSet.whitespaces.contains(UnicodeScalar(ns.character(at: titleEnd - 1)) ?? " ") {
      titleEnd -= 1
    }
    append(
      NSRange(location: titleStart, length: titleEnd - titleStart),
      kind: todoState == .done ? .doneHeadingTitle : todoState == .canceled ? .canceledHeadingTitle : .headingTitle,
      lineOffset: lineOffset,
      into: &tokens
    )
  }

  private static func collectInlineTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    guard textMayContainInlineSyntax(text) else { return }

    collectRegex(regex: orgLinkRegex, kind: .link, text: text, into: &tokens)
    collectRegex(regex: markdownLinkRegex, kind: .link, text: text, into: &tokens)
    collectRegex(regex: urlRegex, kind: .link, text: text, into: &tokens)
    collectRegex(regex: filePathRegex, kind: .link, text: text, into: &tokens)
    collectRegex(regex: backtickCodeRegex, kind: .code, text: text, into: &tokens)
    collectRegex(regex: orgCodeRegex, kind: .code, text: text, into: &tokens)
    collectRegex(regex: emphasisRegex, kind: .emphasis, text: text, into: &tokens)
    collectRegex(regex: timestampRegex, kind: .timestamp, text: text, into: &tokens)
    collectInlineDelimiterTokens(in: text, into: &tokens)
  }

  static func textMayContainInlineSyntax(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    var httpMatchIndex = 0
    for byte in text.utf8 {
      switch byte {
      case 42, 43, 46, 47, 60, 61, 91, 95, 96, 126:
        return true
      default:
        if byte == httpBytes[httpMatchIndex] {
          httpMatchIndex += 1
          if httpMatchIndex == httpBytes.count {
            return true
          }
        } else {
          httpMatchIndex = byte == httpBytes[0] ? 1 : 0
        }
      }
    }
    return false
  }

  private static func collectInlineDelimiterTokens(in text: String, into tokens: inout [OrgSyntaxHighlightToken]) {
    let tokenCount = tokens.count
    guard tokenCount > 0 else { return }
    for index in 0..<tokenCount {
      let token = tokens[index]
      guard isInlineDelimitedKind(token.kind) else { continue }
      guard let raw = substring(in: text, range: token.range) else { continue }
      switch token.kind {
      case .link:
        collectLinkDelimiters(raw: raw, tokenRange: token.range, into: &tokens)
      case .code, .emphasis, .timestamp:
        appendEdgeDelimiters(token.range, openingLength: 1, closingLength: 1, into: &tokens)
      default:
        break
      }
    }
  }

  private static func isInlineDelimitedKind(_ kind: OrgSyntaxHighlightKind) -> Bool {
    switch kind {
    case .link, .code, .emphasis, .timestamp:
      return true
    case .headingStars, .headingTitle, .keyword, .planningKeyword, .propertyKey, .todo, .priority, .tag, .linkTarget,
         .syntaxDelimiter, .comment, .checkedListItem, .doneTodo, .canceledTodo, .doneHeadingTitle,
         .canceledHeadingTitle:
      return false
    }
  }

  private static func collectLinkDelimiters(
    raw: String,
    tokenRange: NSRange,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    if raw.hasPrefix("[["), raw.hasSuffix("]]") {
      appendSyntaxDelimiter(location: tokenRange.location, length: 2, into: &tokens)
      appendSyntaxDelimiter(location: NSMaxRange(tokenRange) - 2, length: 2, into: &tokens)
      if let separator = raw.range(of: "][") {
        appendLinkTarget(
          location: tokenRange.location + 2,
          length: separator.lowerBound.utf16Offset(in: raw) - 2,
          into: &tokens
        )
        appendSyntaxDelimiter(
          location: tokenRange.location + separator.lowerBound.utf16Offset(in: raw),
          length: 2,
          into: &tokens
        )
      }
      return
    }

    if raw.hasPrefix("["), raw.hasSuffix(")"),
       let separator = raw.range(of: "](") {
      appendSyntaxDelimiter(location: tokenRange.location, length: 1, into: &tokens)
      appendLinkTarget(
        location: tokenRange.location + separator.upperBound.utf16Offset(in: raw),
        length: raw.utf16.count - separator.upperBound.utf16Offset(in: raw) - 1,
        into: &tokens
      )
      appendSyntaxDelimiter(
        location: tokenRange.location + separator.lowerBound.utf16Offset(in: raw),
        length: 2,
        into: &tokens
      )
      appendSyntaxDelimiter(location: NSMaxRange(tokenRange) - 1, length: 1, into: &tokens)
    }
  }

  private static func appendEdgeDelimiters(
    _ tokenRange: NSRange,
    openingLength: Int,
    closingLength: Int,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    guard tokenRange.length >= openingLength + closingLength else { return }
    appendSyntaxDelimiter(location: tokenRange.location, length: openingLength, into: &tokens)
    appendSyntaxDelimiter(location: NSMaxRange(tokenRange) - closingLength, length: closingLength, into: &tokens)
  }

  private static func appendSyntaxDelimiter(
    location: Int,
    length: Int,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    guard length > 0 else { return }
    tokens.append(OrgSyntaxHighlightToken(
      kind: .syntaxDelimiter,
      range: NSRange(location: location, length: length)
    ))
  }

  private static func appendLinkTarget(
    location: Int,
    length: Int,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    guard length > 0 else { return }
    tokens.append(OrgSyntaxHighlightToken(
      kind: .linkTarget,
      range: NSRange(location: location, length: length)
    ))
  }

  private static func substring(in text: String, range: NSRange) -> String? {
    guard let swiftRange = Range(range, in: text) else { return nil }
    return String(text[swiftRange])
  }

  private static func collectLineRegex(
    regex: NSRegularExpression,
    kind: OrgSyntaxHighlightKind,
    line: String,
    lineOffset: Int,
    capture: Int = 0,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    let ns = line as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    for match in regex.matches(in: line, range: fullRange) {
      append(match.range(at: capture), kind: kind, lineOffset: lineOffset, into: &tokens)
    }
  }

  private static func collectRegex(
    regex: NSRegularExpression,
    kind: OrgSyntaxHighlightKind,
    text: String,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    let ns = text as NSString
    let fullRange = NSRange(location: 0, length: ns.length)
    for match in regex.matches(in: text, range: fullRange) {
      append(match.range, kind: kind, lineOffset: 0, into: &tokens)
    }
  }

  private static let headingLineRegex = regex(
    #"^(\*+)\s+(?:(TODO|IN_PROGRESS|PROG|WAIT|HOLD|PAUSED|DONE|CANCELED|CANCELLED)\b)?\s*(?:(\[#.\]))?"#
  )
  private static let headingTagRegex = regex(#"\s(:[A-Za-z0-9_@#%:.-]+:)\s*$"#)
  private static let keywordLineRegex = regex(#"^\s*#\+([A-Za-z0-9_-]+):"#)
  private static let blockKeywordLineRegex = regex(#"^\s*#\+(begin_src|end_src|begin_quote|end_quote|begin_example|end_example)\b"#)
  private static let planningLineRegex = regex(#"^\s*(SCHEDULED|DEADLINE|CLOSED):"#)
  private static let propertyLineRegex = regex(#"^\s*:([^:\s]+):"#)
  private static let commentLineRegex = regex(#"^\s*#(?!\+).*$"#)
  // A star bullet needs indentation; a star in column 0 starts a heading.
  private static let checkedListItemRegex = regex(
    #"^(?:\s*(?:[-+]|\d+[.)])|\s+\*)\s+\[[Xx]\]\s+(\S.*?)\s*$"#
  )
  private static let orgLinkRegex = regex(#"\[\[[^\n\]]+(?:\]\[[^\n\]]+)?\]\]"#)
  private static let markdownLinkRegex = regex(#"\[[^\n\]]+\]\([^\n\)]+\)"#)
  private static let urlRegex = regex(#"https?://[^\s\]\)"'`<>]+"#)
  private static let filePathRegex = regex(#"(?:(?:file:(?://)?)?(?:~|/|[A-Za-z0-9_.-]+/)[^\s\]\)"'`<>]*\.(?:org2?|md))(?:[:#]\d+)?"#)
  private static let backtickCodeRegex = regex(#"`[^`\n]+`"#)
  private static let orgCodeRegex = regex(#"(?<!\w)[~=][^\s~=](?:[^\n]*?[^\s~=])?[~=](?!\w)"#)
  private static let emphasisRegex = regex(#"(?<!\w)[*/_+][^\s*/_+](?:[^\n]*?[^\s*/_+])?[*/_+](?!\w)"#)
  private static let timestampRegex = regex(#"[<\[]\d{4}-\d{2}-\d{2}[^>\]]*[>\]]"#)

  private static func regex(_ pattern: String) -> NSRegularExpression {
    do {
      return try NSRegularExpression(pattern: pattern)
    } catch {
      preconditionFailure("Invalid org syntax regex: \(pattern)")
    }
  }

  private static func append(
    _ range: NSRange,
    kind: OrgSyntaxHighlightKind,
    lineOffset: Int,
    into tokens: inout [OrgSyntaxHighlightToken]
  ) {
    guard range.location != NSNotFound, range.length > 0 else { return }
    tokens.append(OrgSyntaxHighlightToken(
      kind: kind,
      range: NSRange(location: lineOffset + range.location, length: range.length)
    ))
  }

  private static var theme: WorkspaceThemeCenter { WorkspaceThemeCenter.shared }

  private static func baseAttributes(font: NSFont, prose: Bool = false) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = prose ? 8 : 2
    if prose { paragraph.paragraphSpacing = 6 }
    return [
      .font: font,
      .foregroundColor: theme.liveColor(.sourceText),
      .paragraphStyle: paragraph
    ]
  }

  private static func attributes(
    for kind: OrgSyntaxHighlightKind,
    baseFont: NSFont,
    concealsSyntax: Bool,
    prose: Bool = false
  ) -> [NSAttributedString.Key: Any] {
    if prose, let attributes = proseAttributes(for: kind, baseFont: baseFont) {
      return attributes
    }
    switch kind {
    case .headingStars:
      return concealsSyntax
        ? hiddenSyntaxAttributes(baseFont: baseFont)
        : sourceSyntaxAttributes(baseFont: baseFont)
    case .headingTitle:
      if !concealsSyntax {
        return [
          .foregroundColor: theme.liveColor(.sourceText),
          .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)
        ]
      }
      return [
        .foregroundColor: theme.liveColor(.sourceText),
        .font: NSFont.systemFont(ofSize: baseFont.pointSize + 2, weight: .semibold)
      ]
    case .keyword:
      return [
        .foregroundColor: theme.liveColor(.keyword),
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .medium)
      ]
    case .planningKeyword:
      return [
        .foregroundColor: theme.liveColor(.planning),
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)
      ]
    case .propertyKey:
      return [
        .foregroundColor: theme.liveColor(.comment),
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .medium)
      ]
    case .todo:
      return [
        .foregroundColor: theme.liveColor(.todo),
        .backgroundColor: theme.liveColor(.todo, alpha: 0.12),
        .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
      ]
    case .priority:
      return [
        .foregroundColor: theme.liveColor(.priority),
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)
      ]
    case .tag:
      return [
        .foregroundColor: theme.liveColor(.tag),
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
      ]
    case .link:
      return [
        .foregroundColor: theme.liveColor(.link),
        .underlineStyle: NSUnderlineStyle.single.rawValue
      ]
    case .linkTarget:
      return concealsSyntax
        ? hiddenSyntaxAttributes(baseFont: baseFont)
        : sourceSyntaxAttributes(baseFont: baseFont)
    case .code:
      return [
        .foregroundColor: theme.liveColor(.sourceText),
        .backgroundColor: theme.liveColor(.code, alpha: 0.12),
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
      ]
    case .emphasis:
      return [
        .foregroundColor: theme.liveColor(.sourceText),
        .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .medium)
      ]
    case .timestamp:
      return [
        .foregroundColor: theme.liveColor(.sourceText),
        .backgroundColor: theme.liveColor(.timestamp, alpha: 0.10),
        .font: NSFont.monospacedDigitSystemFont(ofSize: baseFont.pointSize, weight: .regular)
      ]
    case .syntaxDelimiter:
      return concealsSyntax
        ? hiddenSyntaxAttributes(baseFont: baseFont)
        : sourceSyntaxAttributes(baseFont: baseFont)
    case .comment:
      return [
        .foregroundColor: theme.liveColor(.comment)
      ]
    case .checkedListItem:
      return checkedListItemAttributes
    case .doneTodo:
      return [
        .foregroundColor: theme.liveColor(.done),
        .backgroundColor: theme.liveColor(.done, alpha: 0.12),
        .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
      ]
    case .canceledTodo:
      return canceledTodoAttributes(baseFont: baseFont)
    case .doneHeadingTitle, .canceledHeadingTitle:
      return finishedHeadingTitleAttributes(
        kind,
        heading: attributes(for: .headingTitle, baseFont: baseFont, concealsSyntax: concealsSyntax)
      )
    }
  }

  private static func canceledTodoAttributes(baseFont: NSFont) -> [NSAttributedString.Key: Any] {
    [
      .foregroundColor: NSColor.tertiaryLabelColor,
      .backgroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.08),
      .font: NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
    ]
  }

  /// Keeps the heading's size and weight but recedes its color: done titles
  /// soften (Emacs `org-headline-done`), canceled titles grey out and strike.
  static func finishedHeadingTitleAttributes(
    _ kind: OrgSyntaxHighlightKind,
    heading: [NSAttributedString.Key: Any]
  ) -> [NSAttributedString.Key: Any] {
    var attributes = heading
    switch kind {
    case .doneHeadingTitle:
      attributes[.foregroundColor] = NSColor.secondaryLabelColor
    case .canceledHeadingTitle:
      attributes[.foregroundColor] = NSColor.tertiaryLabelColor
      attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    default:
      break
    }
    return attributes
  }

  private static var checkedListItemAttributes: [NSAttributedString.Key: Any] {
    [
      .foregroundColor: NSColor.secondaryLabelColor,
      .strikethroughStyle: NSUnderlineStyle.single.rawValue
    ]
  }

  /// Prose mode shows words, not markup: editing syntax is concealed or muted.
  /// Returns nil for kinds that keep their ordinary presentation.
  private static func proseAttributes(
    for kind: OrgSyntaxHighlightKind,
    baseFont: NSFont
  ) -> [NSAttributedString.Key: Any]? {
    let muted: [NSAttributedString.Key: Any] = [
      .foregroundColor: NSColor.tertiaryLabelColor,
      .font: proseFont(size: baseFont.pointSize * 0.8)
    ]
    switch kind {
    case .headingStars, .linkTarget, .syntaxDelimiter:
      return hiddenSyntaxAttributes(baseFont: baseFont)
    case .headingTitle:
      return [
        .foregroundColor: theme.liveColor(.sourceText),
        .font: proseFont(size: baseFont.pointSize * 1.35, weight: .semibold)
      ]
    case .keyword, .planningKeyword, .propertyKey, .tag, .priority, .comment:
      return muted
    case .code:
      return [
        .foregroundColor: theme.liveColor(.sourceText),
        .backgroundColor: theme.liveColor(.code, alpha: 0.12),
        .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.85, weight: .regular)
      ]
    case .emphasis:
      return [
        .foregroundColor: theme.liveColor(.sourceText),
        .font: proseFont(size: baseFont.pointSize, weight: .medium)
      ]
    case .timestamp:
      return muted
    case .checkedListItem:
      return checkedListItemAttributes
    case .doneHeadingTitle, .canceledHeadingTitle:
      return finishedHeadingTitleAttributes(
        kind,
        heading: proseAttributes(for: .headingTitle, baseFont: baseFont) ?? [:]
      )
    case .todo, .doneTodo, .canceledTodo, .link:
      return nil
    }
  }

  private static func hiddenSyntaxAttributes(baseFont: NSFont) -> [NSAttributedString.Key: Any] {
    [
      .foregroundColor: NSColor.clear,
      .backgroundColor: NSColor.clear,
      .underlineStyle: 0,
      .kern: -0.1,
      .font: NSFont.monospacedSystemFont(ofSize: max(0.01, baseFont.pointSize * 0.001), weight: .regular)
    ]
  }

  private static func sourceSyntaxAttributes(baseFont: NSFont) -> [NSAttributedString.Key: Any] {
    [
      .foregroundColor: NSColor.tertiaryLabelColor,
      .font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
    ]
  }
}
