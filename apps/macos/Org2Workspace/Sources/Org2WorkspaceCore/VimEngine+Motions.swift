import Foundation

extension VimEngine {
  /// Evaluates a motion from `location`. `forOperator` enables the
  /// operator-pending variants (`l` may reach the line end, `cw` acts as `ce`).
  func evaluateMotion(_ spec: MotionSpec, count outerCount: Int?, from location: Int, operatorKey: Operator? = nil) -> MotionResult? {
    let text = self.text
    let length = text.length
    let hasCount = outerCount != nil || spec.count != nil
    let count = max(1, (outerCount ?? 1) * (spec.count ?? 1))
    let forOperator = operatorKey != nil
    let lineStart = VimText.lineStart(text, location)
    let currentColumn = curswant ?? (location - lineStart)

    func charwise(_ target: Int, inclusive: Bool = false, jump: Bool = false) -> MotionResult {
      MotionResult(target: target, linewise: false, inclusive: inclusive, isJump: jump)
    }
    func linewise(_ target: Int, jump: Bool = false, keepColumn: Bool = false) -> MotionResult {
      if keepColumn {
        return MotionResult(
          target: VimText.position(text, lineStart: VimText.lineStart(text, target), column: currentColumn),
          linewise: true,
          inclusive: false,
          curswant: currentColumn,
          isJump: jump
        )
      }
      return MotionResult(target: VimText.firstNonBlank(text, target), linewise: true, inclusive: false, isJump: jump)
    }

    switch spec.key {
    case "h", "<Left>", "<BS>", "<C-h>":
      guard location > lineStart || spec.key == "<BS>" else { return nil }
      var target = location
      for _ in 0..<count {
        if spec.key == "<BS>" {
          target = VimText.previousPosition(text, target)
        } else if target > lineStart {
          target = VimText.previousPosition(text, target)
        }
      }
      if spec.key == "<BS>", !forOperator { target = VimText.clampNormal(text, target) }
      return charwise(target)

    case "l", "<Right>", "<Space>", " ":
      let lineEnd = VimText.lineEnd(text, location)
      let limit = forOperator ? lineEnd : VimText.lastCharPosition(text, location)
      if spec.key == "<Space>" || spec.key == " " {
        var target = location
        for _ in 0..<count {
          let next = VimText.nextPosition(text, target)
          if next >= length { break }
          target = next
          if VimText.char(text, target) == VimText.newline && !VimText.isEmptyLine(text, target) {
            target += 1
          }
        }
        return target == location ? nil : charwise(min(target, length))
      }
      guard location < limit else { return nil }
      var target = location
      for _ in 0..<count where target < limit {
        target = VimText.nextPosition(text, target)
      }
      return charwise(min(target, limit))

    case "j", "<Down>", "<C-n>", "<C-j>", "k", "<Up>", "<C-p>":
      let down = ["j", "<Down>", "<C-n>", "<C-j>"].contains(spec.key)
      var start = lineStart
      var moved = 0
      for _ in 0..<count {
        let next = down ? VimText.nextLineStart(text, start) : VimText.previousLineStart(text, start)
        guard let next else { break }
        start = next
        moved += 1
      }
      guard moved > 0 else { return nil }
      return MotionResult(
        target: VimText.position(text, lineStart: start, column: currentColumn, allowLineEnd: mode.isVisual && currentColumn == Int.max),
        linewise: true,
        inclusive: false,
        curswant: currentColumn
      )

    case "gj", "gk", "g<Down>", "g<Up>":
      let down = spec.key == "gj" || spec.key == "g<Down>"
      guard let target = host?.vimDisplayLineLocation(from: location, down: down, count: count) else { return nil }
      return charwise(target)

    case "w", "W":
      let big = spec.key == "W"
      if operatorKey == .change, let c = VimText.char(text, location), !VimText.isWhitespace(c) {
        // "cw" behaves like "ce" on a word.
        var target = location
        for index in 0..<count {
          let currentClass = VimText.wordClass(text, target, bigWord: big)
          let nextClass = VimText.wordClass(text, target + 1, bigWord: big)
          if index == 0 && currentClass != nextClass { continue }
          target = VimText.wordEnd(text, from: target, bigWord: big)
        }
        return charwise(target, inclusive: true)
      }
      var target = location
      var lastStart = location
      for _ in 0..<count {
        lastStart = target
        target = VimText.wordForward(text, from: target, bigWord: big)
      }
      if forOperator {
        // The last word moved over ends at the line end, not on the next line.
        let lastLineEnd = VimText.lineEnd(text, lastStart)
        if target > lastLineEnd, lastLineEnd > lastStart || (lastLineEnd == lastStart && !VimText.isEmptyLine(text, lastStart)) {
          var result = charwise(lastLineEnd)
          result.operatorEnd = lastLineEnd
          return result
        }
      }
      if target >= length, !forOperator { return charwise(VimText.clampNormal(text, length)) }
      return charwise(target)

    case "b", "B":
      guard location > 0 else { return nil }
      var target = location
      for _ in 0..<count { target = VimText.wordBackward(text, from: target, bigWord: spec.key == "B") }
      return charwise(target)

    case "e", "E":
      guard location < length - 1 else { return nil }
      var target = location
      for _ in 0..<count { target = VimText.wordEnd(text, from: target, bigWord: spec.key == "E") }
      return charwise(target, inclusive: true)

    case "ge", "gE":
      guard location > 0 else { return nil }
      var target = location
      for _ in 0..<count { target = VimText.wordEndBackward(text, from: target, bigWord: spec.key == "gE") }
      return charwise(target, inclusive: true)

    case "0", "<Home>", "g0":
      return charwise(lineStart)

    case "^", "g^":
      return charwise(VimText.firstNonBlank(text, location))

    case "$", "<End>", "g$":
      var start = lineStart
      for _ in 1..<count {
        guard let next = VimText.nextLineStart(text, start) else { break }
        start = next
      }
      let end = VimText.lineEnd(text, start)
      var result = MotionResult(
        target: forOperator ? max(start, end - (end > start ? 1 : 0)) : VimText.lastCharPosition(text, start),
        linewise: false,
        inclusive: true,
        curswant: Int.max
      )
      if mode.isVisual { result.target = end > start ? VimText.previousPosition(text, end) : start }
      if forOperator, end == start {
        result.operatorEnd = start
      }
      return result

    case "g_":
      var start = lineStart
      for _ in 1..<count {
        guard let next = VimText.nextLineStart(text, start) else { break }
        start = next
      }
      var end = VimText.lineEnd(text, start)
      while end > start, let c = VimText.char(text, end - 1), VimText.isBlank(c) { end -= 1 }
      return charwise(max(start, end - 1), inclusive: true)

    case "gm":
      let end = VimText.lineEnd(text, location)
      return charwise(lineStart + (end - lineStart) / 2)

    case "|":
      return MotionResult(
        target: VimText.position(text, lineStart: lineStart, column: count - 1, allowLineEnd: false),
        linewise: false,
        inclusive: false,
        curswant: count - 1
      )

    case "G", "gg":
      let lineNumber: Int
      if hasCount {
        lineNumber = count - 1
      } else {
        lineNumber = spec.key == "G" ? Int.max : 0
      }
      let start = lineNumber == Int.max
        ? VimText.lastLineStart(text)
        : VimText.startOfLine(text, index: lineNumber)
      return linewise(start, jump: true)

    case "_":
      var start = lineStart
      for _ in 1..<count {
        guard let next = VimText.nextLineStart(text, start) else { break }
        start = next
      }
      return linewise(start)

    case "+", "<CR>", "-":
      var start = lineStart
      var moved = 0
      for _ in 0..<count {
        let next = spec.key == "-" ? VimText.previousLineStart(text, start) : VimText.nextLineStart(text, start)
        guard let next else { break }
        start = next
        moved += 1
      }
      guard moved > 0 else { return nil }
      return linewise(start)

    case "}":
      var target = location
      for _ in 0..<count { target = VimText.paragraphForward(text, from: target) }
      if !forOperator, target >= length { target = VimText.clampNormal(text, length) }
      var result = charwise(target, jump: true)
      if forOperator, target >= length { result.inclusive = false }
      return result

    case "{":
      var target = location
      for _ in 0..<count { target = VimText.paragraphBackward(text, from: target) }
      return charwise(target, jump: true)

    case ")":
      var target = location
      for _ in 0..<count { target = VimText.sentenceForward(text, from: target) }
      if !forOperator { target = VimText.clampNormal(text, target) }
      return charwise(target, jump: true)

    case "(":
      var target = location
      for _ in 0..<count { target = VimText.sentenceBackward(text, from: target) }
      return charwise(target, jump: true)

    case "%":
      if hasCount {
        let lines = VimText.lineCount(text)
        let lineNumber = (count * lines + 99) / 100 - 1
        return linewise(VimText.startOfLine(text, index: lineNumber), jump: true)
      }
      guard let match = VimText.matchingBracket(text, from: location) else { return nil }
      return charwise(match, inclusive: true, jump: true)

    case "H", "M", "L":
      guard let visible = host?.vimVisibleCharacterRange() else { return nil }
      let first = VimText.lineStart(text, visible.location)
      let lastLocation = max(visible.location, visible.location + visible.length - 1)
      let last = VimText.lineStart(text, min(lastLocation, length))
      var target: Int
      switch spec.key {
      case "H":
        target = first
        for _ in 1..<count { target = VimText.nextLineStart(text, target).map { min($0, last) } ?? target }
      case "L":
        target = last
        for _ in 1..<count { target = VimText.previousLineStart(text, target).map { max($0, first) } ?? target }
      default:
        let firstIndex = VimText.lineIndex(text, first)
        let lastIndex = VimText.lineIndex(text, last)
        target = VimText.startOfLine(text, index: (firstIndex + lastIndex) / 2)
      }
      return linewise(target, jump: true)

    case "f", "F", "t", "T":
      guard let argument = spec.argument else { return nil }
      lastFind = (Self.literal(argument), spec.key == "f" || spec.key == "t", spec.key == "t" || spec.key == "T")
      return findCharacter(Self.literal(argument), forward: spec.key == "f" || spec.key == "t", till: spec.key == "t" || spec.key == "T", count: count, from: location, repeating: false)

    case ";", ",":
      guard let lastFind else { return nil }
      let forward = spec.key == ";" ? lastFind.forward : !lastFind.forward
      return findCharacter(lastFind.character, forward: forward, till: lastFind.till, count: count, from: location, repeating: true)

    case "'", "`":
      guard let argument = spec.argument, let name = argument.first,
            let mark = markLocation(name, current: location)
      else {
        fail("E20: Mark not set")
        return nil
      }
      let target = min(mark, length)
      if spec.key == "'" { return linewise(target, jump: true) }
      return charwise(target, jump: true)

    case "n", "N":
      guard let lastSearch else {
        fail("E35: No previous regular expression")
        return nil
      }
      let forward = spec.key == "n" ? lastSearch.forward : !lastSearch.forward
      guard let target = search(lastSearch.pattern, forward: forward, from: location, count: count) else { return nil }
      return charwise(target, jump: true)

    case "*", "#", "g*", "g#":
      guard let word = VimText.wordObject(text, at: location, count: 1, around: false, bigWord: false),
            word.length > 0
      else {
        fail("E348: No string under cursor")
        return nil
      }
      let literal = text.substring(with: word)
      let escaped = VimPattern.escapeLiteral(literal)
      let isKeyword = VimText.wordClass(text, word.location, bigWord: false) == 2
      let pattern = isKeyword ? "\\<\(escaped)\\>" : escaped
      let forward = spec.key == "*" || spec.key == "g*"
      lastSearch = (pattern, forward)
      appendHistory(&searchHistory, pattern)
      let origin = forward ? location : word.location
      guard let target = search(pattern, forward: forward, from: origin, count: count) else { return nil }
      return charwise(target, jump: true)

    default:
      return nil
    }
  }

  func findCharacter(_ character: String, forward: Bool, till: Bool, count: Int, from location: Int, repeating: Bool) -> MotionResult? {
    let text = self.text
    let start = VimText.lineStart(text, location)
    let end = VimText.lineEnd(text, location)
    let needle = (character as NSString)
    guard needle.length > 0 else { return nil }
    var position = location
    for index in 0..<count {
      var probe: Int
      if forward {
        probe = position + 1
        // ";" after "t" must skip the character right next to the cursor.
        if till && repeating && index == 0 { probe += 1 }
        let searchRange = NSRange(location: min(probe, end), length: max(0, end - probe))
        let found = text.range(of: character, options: .literal, range: searchRange)
        guard found.location != NSNotFound else { return nil }
        position = found.location
        if till && index < count - 1 { position = found.location }
      } else {
        probe = position
        if till && repeating && index == 0 { probe -= 1 }
        let searchRange = NSRange(location: start, length: max(0, probe - start))
        let found = text.range(of: character, options: [.literal, .backwards], range: searchRange)
        guard found.location != NSNotFound else { return nil }
        position = found.location
      }
    }
    if till {
      position = forward ? position - 1 : position + 1
    }
    return MotionResult(target: position, linewise: false, inclusive: forward)
  }

  func markLocation(_ name: Character, current: Int) -> Int? {
    switch name {
    case "'", "`": return marks["'"] ?? 0
    case "[": return lastChangeLocation
    case "]": return lastChangeLocation
    case ".": return lastChangeLocation
    case "^": return lastInsertLocation
    case "<":
      guard let lastVisual else { return nil }
      return visualBounds(lastVisual.mode, anchor: lastVisual.anchor, cursor: lastVisual.cursor).start
    case ">":
      guard let lastVisual else { return nil }
      let bounds = visualBounds(lastVisual.mode, anchor: lastVisual.anchor, cursor: lastVisual.cursor)
      return max(bounds.start, bounds.end - 1)
    default:
      return marks[name]
    }
  }

  // MARK: Search

  func search(_ pattern: String, forward: Bool, from location: Int, count: Int) -> Int? {
    guard let regex = VimPattern.regex(pattern, ignoreCase: ignoreCase, smartCase: smartCase) else {
      fail("E383: Invalid search string: \(pattern)")
      return nil
    }
    let text = self.text
    let string = text as String
    let length = text.length
    var position = location
    var wrapped = false
    for _ in 0..<count {
      var found: NSRange?
      if forward {
        let start = min(position + 1, length)
        if let match = regex.firstMatch(in: string, range: NSRange(location: start, length: length - start)) {
          found = match.range
        } else if wrapScan, let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: min(start, length))) {
          found = match.range
          wrapped = true
        }
      } else {
        var last: NSRange?
        regex.enumerateMatches(in: string, range: NSRange(location: 0, length: position)) { match, _, _ in
          if let match, match.range.location < position { last = match.range }
        }
        if last == nil, wrapScan {
          regex.enumerateMatches(in: string, range: NSRange(location: position, length: length - position)) { match, _, _ in
            if let match { last = match.range }
          }
          if last != nil { wrapped = true }
        }
        found = last
      }
      guard let found else {
        fail("E486: Pattern not found: \(pattern)")
        return nil
      }
      position = found.location
      if count == 1 {
        host?.vimFlash(found)
      }
    }
    if wrapped {
      setMessage(forward ? "search hit BOTTOM, continuing at TOP" : "search hit TOP, continuing at BOTTOM", error: true)
    }
    return position
  }

  func appendHistory(_ history: inout [String], _ entry: String) {
    guard !entry.isEmpty else { return }
    history.removeAll { $0 == entry }
    history.append(entry)
    if history.count > 100 { history.removeFirst() }
  }

  // MARK: Text objects

  func evaluateTextObject(_ spec: TextObjectSpec, count outerCount: Int?, at location: Int) -> (range: NSRange, linewise: Bool)? {
    let text = self.text
    let count = max(1, (outerCount ?? 1) * (spec.count ?? 1))
    switch spec.kind {
    case "w", "W":
      guard let range = VimText.wordObject(text, at: location, count: count, around: spec.around, bigWord: spec.kind == "W") else { return nil }
      return (range, false)
    case "\"", "'", "`":
      guard let quote = spec.kind.utf16.first,
            let range = VimText.quoteObject(text, at: location, quote: quote, around: spec.around)
      else { return nil }
      return (range, false)
    case "(", ")", "b":
      return VimText.bracketObject(text, at: location, open: 40, close: 41, around: spec.around, count: count).map { ($0, false) }
    case "{", "}", "B":
      guard let range = VimText.bracketObject(text, at: location, open: 123, close: 125, around: spec.around, count: count) else { return nil }
      let linewise = !spec.around && range.length > 0
        && VimText.lineStart(text, range.location) == range.location
        && VimText.lineStart(text, range.location + range.length) == range.location + range.length
      return (range, linewise)
    case "[", "]":
      return VimText.bracketObject(text, at: location, open: 91, close: 93, around: spec.around, count: count).map { ($0, false) }
    case "<", ">":
      return VimText.bracketObject(text, at: location, open: 60, close: 62, around: spec.around, count: count).map { ($0, false) }
    case "t":
      return VimText.tagObject(text, at: location, around: spec.around).map { ($0, false) }
    case "p":
      return (VimText.paragraphObject(text, at: location, around: spec.around, count: count), true)
    case "s":
      return (VimText.sentenceObject(text, at: location, around: spec.around), false)
    default:
      return nil
    }
  }

  // MARK: Visual bounds

  /// The selected range of a visual selection (end exclusive).
  func visualBounds(_ mode: VimMode, anchor: Int, cursor: Int) -> (start: Int, end: Int) {
    let text = self.text
    let low = min(anchor, cursor)
    let high = max(anchor, cursor)
    switch mode {
    case .visualLine:
      return (VimText.lineStart(text, low), VimText.lineEndIncludingNewline(text, high))
    default:
      return (low, min(text.length, VimText.nextPosition(text, high)))
    }
  }

  /// Per-line column ranges for a block selection.
  func blockRanges(anchor: Int, cursor: Int, toLineEnd: Bool) -> [NSRange] {
    let text = self.text
    let anchorColumn = column(of: anchor)
    let cursorColumn = column(of: cursor)
    let left = min(anchorColumn, cursorColumn)
    let right = max(anchorColumn, cursorColumn) + 1
    var start = VimText.lineStart(text, min(anchor, cursor))
    let lastStart = VimText.lineStart(text, max(anchor, cursor))
    var ranges: [NSRange] = []
    while true {
      let end = VimText.lineEnd(text, start)
      let from = min(start + left, end)
      let to = toLineEnd ? end : min(start + right, end)
      ranges.append(NSRange(location: from, length: max(0, to - from)))
      guard start < lastStart, let next = VimText.nextLineStart(text, start) else { break }
      start = next
    }
    return ranges
  }

  func showVisualSelection() {
    switch mode {
    case .visual, .visualLine:
      let bounds = visualBounds(mode, anchor: visualAnchor, cursor: visualCursor)
      host?.vimSetSelectedRanges([NSRange(location: bounds.start, length: bounds.end - bounds.start)])
    case .visualBlock:
      let ranges = blockRanges(anchor: visualAnchor, cursor: visualCursor, toLineEnd: curswant == Int.max)
      let visible = ranges.filter { $0.length > 0 }
      host?.vimSetSelectedRanges(visible.isEmpty ? [NSRange(location: visualCursor, length: 0)] : visible)
    default:
      break
    }
  }

  func enterVisual(_ newMode: VimMode) {
    if mode.isVisual {
      if mode == newMode {
        exitVisual()
        return
      }
      mode = newMode
      showVisualSelection()
      return
    }
    let location = cursor
    mode = newMode
    visualAnchor = location
    visualCursor = location
    showVisualSelection()
  }

  func exitVisual(moveTo location: Int? = nil) {
    guard mode.isVisual else { return }
    lastVisual = (mode, visualAnchor, visualCursor, curswant)
    let target = location ?? visualCursor
    mode = .normal
    setCursor(target, keepCurswant: true)
  }
}
