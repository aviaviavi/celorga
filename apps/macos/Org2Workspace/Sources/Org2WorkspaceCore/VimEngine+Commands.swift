import Foundation

extension VimEngine {
  func executeSimple(_ name: String, argument: VimKey?, command: Command) {
    if mode.isVisual {
      executeVisualSimple(name, argument: argument, command: command)
      return
    }
    let text = self.text
    let location = cursor
    let count = max(1, command.count ?? 1)
    func motion(_ key: String, _ motionCount: Int? = nil) -> MotionSpec {
      MotionSpec(key: key, argument: nil, count: motionCount)
    }
    func operatorCommand(_ action: Action) -> Command {
      Command(register: command.register, count: command.count, action: action, keys: command.keys)
    }

    switch name {
    // Deletion and change shortcuts.
    case "x", "<Del>":
      guard !VimText.isEmptyLine(text, location) else { fail(); return }
      execute(operatorCommand(.operatorMotion(.delete, motion("l"))))
    case "X":
      guard location > VimText.lineStart(text, location) else { fail(); return }
      execute(operatorCommand(.operatorMotion(.delete, motion("h"))))
    case "D":
      execute(operatorCommand(.operatorMotion(.delete, motion("$"))))
    case "C":
      execute(operatorCommand(.operatorMotion(.change, motion("$"))))
    case "s":
      if VimText.isEmptyLine(text, location) {
        beginInsert(at: location, count: 1, kind: .plain, change: makeChange(command))
      } else {
        execute(operatorCommand(.operatorMotion(.change, motion("l"))))
      }
    case "S":
      execute(operatorCommand(.operatorLine(.change, count: nil)))
    case "Y":
      execute(operatorCommand(.operatorLine(.yank, count: nil)))

    // Put.
    case "p", "P":
      recordChange(command)
      put(after: name == "p", count: count, register: command.register, cursorAfter: false)
    case "gp", "gP":
      recordChange(command)
      put(after: name == "gp", count: count, register: command.register, cursorAfter: true)

    // Single-key edits.
    case "J", "gJ":
      recordChange(command)
      joinLines(count: max(2, count), insertSpaces: name == "J")
    case "r":
      guard let argument else { return }
      let lineEnd = VimText.lineEnd(text, location)
      var end = location
      for _ in 0..<count {
        guard end < lineEnd else { fail(); return }
        end = VimText.nextPosition(text, end)
      }
      recordChange(command)
      if argument == "<CR>" {
        replace(NSRange(location: location, length: end - location), with: "\n")
        setCursor(location + 1)
      } else {
        let literal = Self.literal(argument)
        replace(NSRange(location: location, length: end - location), with: String(repeating: literal, count: count))
        setCursor(location + (literal as NSString).length * count - (literal as NSString).length)
      }
    case "~":
      let lineEnd = VimText.lineEnd(text, location)
      guard location < lineEnd else { fail(); return }
      var end = location
      for _ in 0..<count where end < lineEnd { end = VimText.nextPosition(text, end) }
      recordChange(command)
      let range = NSRange(location: location, length: end - location)
      replace(range, with: transformCase(text.substring(with: range), .toggleCase))
      setCursor(end)
    case "<C-a>", "<C-x>":
      recordChange(command)
      increment(by: name == "<C-a>" ? count : -count, at: location)

    // Insert.
    case "i", "<Insert>":
      beginInsert(at: location, count: count, kind: .plain, change: makeChange(command))
    case "a":
      let target = location < text.length && text.character(at: location) != VimText.newline
        ? VimText.nextPosition(text, location)
        : location
      beginInsert(at: target, count: count, kind: .plain, change: makeChange(command))
    case "I":
      beginInsert(at: VimText.firstNonBlank(text, location), count: count, kind: .plain, change: makeChange(command))
    case "gI":
      beginInsert(at: VimText.lineStart(text, location), count: count, kind: .plain, change: makeChange(command))
    case "A":
      beginInsert(at: VimText.lineEnd(text, location), count: count, kind: .plain, change: makeChange(command))
    case "gi":
      beginInsert(at: min(lastInsertLocation ?? location, text.length), count: count, kind: .plain, change: makeChange(command))
    case "o", "O":
      let lineStart = VimText.lineStart(text, location)
      let indentEnd = VimText.firstNonBlank(text, location)
      let indent = text.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))
      let change = makeChange(command)
      if name == "o" {
        let lineEnd = VimText.lineEnd(text, location)
        // In Org text, `o` continues a list item or heading the way Return does.
        let prefix = host?.vimOpenLineBelowPrefix(forLineAt: location) ?? indent
        replace(NSRange(location: lineEnd, length: 0), with: "\n" + prefix)
        beginInsert(at: lineEnd + 1 + (prefix as NSString).length, count: count, kind: .openBelow, change: change)
      } else {
        replace(NSRange(location: lineStart, length: 0), with: indent + "\n")
        beginInsert(at: lineStart + (indent as NSString).length, count: count, kind: .openAbove, change: change)
      }
    case "R":
      beginReplaceMode(count: count, change: makeChange(command))

    // Visual mode.
    case "v":
      enterVisual(.visual)
    case "V":
      enterVisual(.visualLine)
    case "<C-v>":
      curswant = nil
      enterVisual(.visualBlock)
    case "gv":
      guard let lastVisual else { fail(); return }
      mode = lastVisual.mode
      visualAnchor = min(lastVisual.anchor, text.length)
      visualCursor = min(lastVisual.cursor, text.length)
      curswant = lastVisual.curswant
      showVisualSelection()

    // Undo and repeat.
    case "u":
      for _ in 0..<count {
        guard host?.vimUndo() == true else {
          setMessage("Already at oldest change")
          break
        }
      }
      settleCursorAfterHistoryChange()
    case "<C-r>":
      for _ in 0..<count {
        guard host?.vimRedo() == true else {
          setMessage("Already at newest change")
          break
        }
      }
      settleCursorAfterHistoryChange()
    case ".":
      repeatLastChange(count: command.count)

    // Command line and search.
    case ":":
      beginCommandLine(":", initial: command.count.map { $0 == 1 ? "." : ".,.+\($0 - 1)" } ?? "")
    case "/", "?":
      beginCommandLine(Character(name), initial: "")
    case "&":
      recordChange(command)
      repeatSubstitute(wholeFile: false, keepFlags: false)
    case "g&":
      repeatSubstitute(wholeFile: true, keepFlags: true)

    // Marks, macros, jumps.
    case "m":
      guard let argument, let mark = argument.first, mark.isLetter || mark == "'" || mark == "`" else { fail(); return }
      marks[mark == "`" ? "'" : mark] = location
    case "q":
      if recordingRegister != nil {
        stopRecording()
      } else if let argument, let register = argument.first {
        startRecording(register)
      }
    case "@":
      guard let argument, let register = argument.first else { return }
      executeMacro(register, count: count)
    case "<C-o>":
      jump(by: -count)
    case "<C-i>":
      jump(by: count)

    // Scrolling.
    case "<C-e>", "<C-y>":
      host?.vimScroll(lines: name == "<C-e>" ? count : -count)
      keepCursorVisible()
    case "<C-d>", "<C-u>":
      let visibleLines = visibleLineCount()
      let amount = command.count ?? max(1, visibleLines / 2)
      moveCursorByLines(name == "<C-d>" ? amount : -amount)
      host?.vimScroll(lines: name == "<C-d>" ? amount : -amount)
    case "<C-f>", "<C-b>", "<PageDown>", "<PageUp>":
      let page = max(1, visibleLineCount() - 2) * count
      let down = name == "<C-f>" || name == "<PageDown>"
      host?.vimScroll(lines: down ? page : -page)
      moveCursorByLines(down ? page : -page)
    case "zz", "zt", "zb", "z.", "z<CR>", "z-":
      if command.count != nil {
        setCursor(VimText.firstNonBlank(text, VimText.startOfLine(text, index: count - 1)))
      } else if ["z.", "z<CR>", "z-"].contains(name) {
        setCursor(VimText.firstNonBlank(text, location))
      }
      let anchor: VimScrollAnchor = switch name {
      case "zt", "z<CR>": .top
      case "zb", "z-": .bottom
      default: .center
      }
      host?.vimScrollCursor(to: anchor)

    // Org structure.
    case "<Tab>", "za", "zA", "zo", "zO", "zc", "zC", "zv":
      if host?.vimPerform(.toggleFold) != true { fail() }
    case "zR", "zn", "zE":
      if host?.vimPerform(.unfoldAll) != true { fail() }
    case "[[", "[{":
      for _ in 0..<count where host?.vimPerform(.previousHeading) != true { fail(); break }
    case "]]", "]}":
      for _ in 0..<count where host?.vimPerform(.nextHeading) != true { fail(); break }

    // Files and information.
    case "ZZ":
      if host?.vimSave() == true { setMessage("Saved") }
    case "ZQ":
      setMessage("Close the document with ⌘W")
    case "<C-g>":
      let line = VimText.lineIndex(text, location) + 1
      let total = VimText.lineCount(text)
      setMessage("line \(line) of \(total) --\(total == 0 ? 0 : line * 100 / total)%-- col \(column(of: location) + 1)")
    case "ga":
      guard location < text.length else { fail(); return }
      let character = text.substring(with: text.rangeOfComposedCharacterSequence(at: location))
      let scalars = character.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
      setMessage("<\(character)> \(scalars)")
    default:
      fail()
    }
  }

  func settleCursorAfterHistoryChange() {
    let location = host?.vimSelectedRange.location ?? 0
    mode = .normal
    setCursor(location)
  }

  func executeVisualSimple(_ name: String, argument: VimKey?, command: Command) {
    let visualOp: (Operator) -> Void = { op in
      self.applyVisualOperator(op, command: command)
    }
    switch name {
    case "x", "<Del>":
      visualOp(.delete)
    case "X", "D":
      if mode == .visualBlock, name == "D" {
        curswant = Int.max
        visualOp(.delete)
      } else {
        mode = .visualLine
        visualOp(.delete)
      }
    case "s":
      visualOp(.change)
    case "S", "R":
      mode = .visualLine
      visualOp(.change)
    case "C":
      if mode == .visualBlock {
        curswant = Int.max
      } else {
        mode = .visualLine
      }
      visualOp(.change)
    case "Y":
      if mode != .visualBlock { mode = .visualLine }
      visualOp(.yank)
    case "J", "gJ":
      let low = min(visualAnchor, visualCursor)
      let high = max(visualAnchor, visualCursor)
      let lines = VimText.newlineCount(text, NSRange(location: low, length: high - low)) + 1
      lastVisual = (mode, visualAnchor, visualCursor, curswant)
      mode = .normal
      recordChange(command)
      setCursor(low)
      joinLines(count: max(2, lines), insertSpaces: name == "J")
    case "~":
      visualOp(.toggleCase)
    case "u":
      visualOp(.lowercase)
    case "U":
      visualOp(.uppercase)
    case "r":
      guard let argument else { return }
      let literal = Self.literal(argument)
      let ranges: [NSRange]
      if mode == .visualBlock {
        ranges = blockRanges(anchor: visualAnchor, cursor: visualCursor, toLineEnd: curswant == Int.max)
      } else {
        let bounds = visualBounds(mode, anchor: visualAnchor, cursor: visualCursor)
        ranges = [NSRange(location: bounds.start, length: bounds.end - bounds.start)]
      }
      lastVisual = (mode, visualAnchor, visualCursor, curswant)
      mode = .normal
      recordChange(command)
      for range in ranges.reversed() where range.length > 0 {
        let original = text.substring(with: range)
        let replaced = original.split(separator: "\n", omittingEmptySubsequences: false)
          .map { String(repeating: literal, count: $0.count) }
          .joined(separator: "\n")
        replace(range, with: replaced)
      }
      setCursor(ranges.first?.location ?? cursor)
    case "p", "P":
      visualPut(command, keepRegister: name == "P")
    case "o", "O":
      swap(&visualAnchor, &visualCursor)
      showVisualSelection()
    case "I", "A":
      let append = name == "A"
      if mode == .visualBlock {
        let toLineEnd = curswant == Int.max
        let ranges = blockRanges(anchor: visualAnchor, cursor: visualCursor, toLineEnd: toLineEnd)
        let left = min(column(of: visualAnchor), column(of: visualCursor))
        let right = max(column(of: visualAnchor), column(of: visualCursor)) + 1
        let starts = ranges.map { VimText.lineStart(text, $0.location) }
        lastVisual = (mode, visualAnchor, visualCursor, curswant)
        mode = .normal
        guard let first = starts.first else { return }
        let column = append ? right : left
        var location = toLineEnd && append ? VimText.lineEnd(text, first) : first + column
        let lineEnd = VimText.lineEnd(text, first)
        if location > lineEnd {
          replace(NSRange(location: lineEnd, length: 0), with: String(repeating: " ", count: location - lineEnd))
        }
        location = min(location, text.length)
        beginInsert(
          at: location,
          count: 1,
          kind: .block(lineStarts: starts, column: column, append: append, toLineEnd: toLineEnd && append),
          change: nil
        )
      } else {
        let bounds = visualBounds(mode, anchor: visualAnchor, cursor: visualCursor)
        lastVisual = (mode, visualAnchor, visualCursor, curswant)
        let wasLine = mode == .visualLine
        mode = .normal
        let target: Int
        if append {
          target = wasLine ? VimText.lineEnd(text, max(bounds.start, bounds.end - 1)) : bounds.end
        } else {
          target = wasLine ? VimText.firstNonBlank(text, bounds.start) : bounds.start
        }
        beginInsert(at: target, count: 1, kind: .plain, change: nil)
      }
    case "v":
      enterVisual(.visual)
    case "V":
      enterVisual(.visualLine)
    case "<C-v>":
      enterVisual(.visualBlock)
    case ":":
      lastVisual = (mode, visualAnchor, visualCursor, curswant)
      let returnLocation = min(visualAnchor, visualCursor)
      mode = .normal
      setCursor(returnLocation)
      beginCommandLine(":", initial: "'<,'>")
    case "/", "?":
      commandLineReturnMode = mode
      beginCommandLine(Character(name), initial: "", fromVisual: true)
    case "gv":
      guard let previous = lastVisual else { fail(); return }
      lastVisual = (mode, visualAnchor, visualCursor, curswant)
      mode = previous.mode
      visualAnchor = previous.anchor
      visualCursor = previous.cursor
      showVisualSelection()
    case "<C-a>", "<C-x>":
      let low = min(visualAnchor, visualCursor)
      let high = max(visualAnchor, visualCursor)
      lastVisual = (mode, visualAnchor, visualCursor, curswant)
      mode = .normal
      var lineStart = VimText.lineStart(text, low)
      let lastLine = VimText.lineStart(text, high)
      let delta = (name == "<C-a>" ? 1 : -1) * max(1, command.count ?? 1)
      while true {
        increment(by: delta, at: lineStart, quiet: true)
        guard lineStart < lastLine, let next = VimText.nextLineStart(text, lineStart) else { break }
        lineStart = next
      }
      setCursor(low)
    case "<C-d>", "<C-u>", "<C-f>", "<C-b>", "<C-e>", "<C-y>":
      let lines = visibleLineCount()
      let amount: Int = switch name {
      case "<C-d>", "<C-u>": max(1, lines / 2)
      case "<C-f>", "<C-b>": max(1, lines - 2)
      default: 1
      }
      let down = ["<C-d>", "<C-f>", "<C-e>"].contains(name)
      host?.vimScroll(lines: down ? amount : -amount)
      if name != "<C-e>" && name != "<C-y>" {
        performMotion(MotionSpec(key: down ? "j" : "k", argument: nil, count: amount), count: nil)
      }
    default:
      fail()
    }
  }

  // MARK: Helpers

  func increment(by delta: Int, at location: Int, quiet: Bool = false) {
    let text = self.text
    let lineStart = VimText.lineStart(text, location)
    let lineEnd = VimText.lineEnd(text, location)
    let line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
    guard let regex = try? NSRegularExpression(pattern: "0[xX][0-9A-Fa-f]+|-?\\d+") else { return }
    let column = location - lineStart
    let matches = regex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    guard let match = matches.first(where: { $0.range.location + $0.range.length > column }) else {
      if !quiet { fail() }
      return
    }
    let literal = (line as NSString).substring(with: match.range)
    let replacement: String
    if literal.lowercased().hasPrefix("0x") {
      let digits = String(literal.dropFirst(2))
      let value = (Int(digits, radix: 16) ?? 0) + delta
      let formatted = String(max(0, value), radix: 16, uppercase: digits.contains(where: { $0.isUppercase }))
      replacement = String(literal.prefix(2)) + String(repeating: "0", count: max(0, digits.count - formatted.count)) + formatted
    } else {
      var value = Int(literal) ?? 0
      // A "-" directly after a word character is not a sign.
      var range = match.range
      if literal.hasPrefix("-"), match.range.location > 0 {
        let previous = (line as NSString).character(at: match.range.location - 1)
        if VimText.wordClass(previous, bigWord: false) == 2 {
          value = -value
          range = NSRange(location: range.location + 1, length: range.length - 1)
          let adjusted = value + delta
          let replacementText = String(adjusted)
          let absolute = NSRange(location: lineStart + range.location, length: range.length)
          replace(absolute, with: replacementText)
          if !quiet { setCursor(absolute.location + (replacementText as NSString).length - 1) }
          return
        }
      }
      replacement = String(value + delta)
    }
    let absolute = NSRange(location: lineStart + match.range.location, length: match.range.length)
    replace(absolute, with: replacement)
    if !quiet { setCursor(absolute.location + (replacement as NSString).length - 1) }
  }

  func visibleLineCount() -> Int {
    guard let visible = host?.vimVisibleCharacterRange(), visible.length > 0 else { return 20 }
    return max(1, VimText.newlineCount(text, visible))
  }

  func moveCursorByLines(_ delta: Int) {
    let text = self.text
    let location = cursor
    let column = curswant ?? self.column(of: location)
    var start = VimText.lineStart(text, location)
    for _ in 0..<abs(delta) {
      guard let next = delta > 0 ? VimText.nextLineStart(text, start) : VimText.previousLineStart(text, start) else { break }
      start = next
    }
    setCursor(VimText.position(text, lineStart: start, column: column), keepCurswant: true)
    curswant = column
  }

  func keepCursorVisible() {
    guard let visible = host?.vimVisibleCharacterRange(), visible.length > 0 else { return }
    let text = self.text
    let location = cursor
    let column = curswant ?? self.column(of: location)
    if location < visible.location {
      let start = VimText.lineStart(text, visible.location) == visible.location
        ? visible.location
        : (VimText.nextLineStart(text, visible.location) ?? visible.location)
      setCursor(VimText.position(text, lineStart: start, column: column), keepCurswant: true)
    } else if location >= visible.location + visible.length {
      let lastStart = VimText.lineStart(text, max(visible.location, visible.location + visible.length - 1))
      let start = VimText.previousLineStart(text, lastStart) ?? lastStart
      setCursor(VimText.position(text, lineStart: start, column: column), keepCurswant: true)
    }
  }

  func jump(by delta: Int) {
    let location = cursor
    if delta < 0, jumpIndex >= jumpList.count {
      if jumpList.last != location { jumpList.append(location) }
      jumpIndex = jumpList.count - 1
    }
    let index = jumpIndex + delta
    guard index >= 0, index < jumpList.count else {
      fail()
      return
    }
    jumpIndex = index
    setCursor(min(jumpList[index], text.length))
  }
}
