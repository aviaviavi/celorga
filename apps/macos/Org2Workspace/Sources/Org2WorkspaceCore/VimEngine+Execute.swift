import Foundation

extension VimEngine {
  enum RegisterWrite {
    case yank
    case delete
  }

  // MARK: Editing primitives

  func replace(_ range: NSRange, with replacement: String) {
    let length = text.length
    let start = min(max(0, range.location), length)
    let clamped = NSRange(location: start, length: min(max(0, range.length), length - start))
    guard clamped.length > 0 || !replacement.isEmpty else { return }
    host?.vimReplaceCharacters(in: clamped, with: replacement)
    lastChangeLocation = clamped.location
  }

  func storeRegister(_ value: String, linewise: Bool, blockwise: Bool = false, name: Character?, kind: RegisterWrite) {
    let register = Register(text: value, linewise: linewise, blockwise: blockwise)
    if name == "_" { return }
    if let name, name.isUppercase, name.isLetter {
      let lower = Character(name.lowercased())
      var existing = registers[lower] ?? Register(text: "", linewise: linewise)
      if existing.linewise && !existing.text.hasSuffix("\n") { existing.text += "\n" }
      existing.text += value
      existing.linewise = existing.linewise || linewise
      registers[lower] = existing
      registers["\""] = existing
      return
    }
    if let name, name != "\"" {
      registers[name] = register
      registers["\""] = register
      if name == "+" || name == "*" {
        writeClipboard(value)
      }
      return
    }
    registers["\""] = register
    switch kind {
    case .yank:
      registers["0"] = register
    case .delete:
      if linewise || value.contains("\n") {
        for index in stride(from: 9, to: 1, by: -1) {
          let to = Character(String(index))
          let from = Character(String(index - 1))
          registers[to] = registers[from]
        }
        registers["1"] = register
      } else {
        registers["-"] = register
      }
    }
    if clipboardUnnamed {
      writeClipboard(value)
    }
  }

  func writeClipboard(_ value: String) {
    lastClipboardWrite = value
    host?.vimSetClipboardString(value)
  }

  func readRegister(_ name: Character?) -> Register? {
    let name = name ?? "\""
    switch name {
    case "\"":
      if clipboardUnnamed, let clipboard = host?.vimClipboardString(), !clipboard.isEmpty, clipboard != lastClipboardWrite {
        return Register(text: clipboard, linewise: clipboard.hasSuffix("\n"))
      }
      return registers["\""]
    case "+", "*":
      guard let clipboard = host?.vimClipboardString() else { return nil }
      if let stored = registers[name], stored.text == clipboard { return stored }
      return Register(text: clipboard, linewise: clipboard.hasSuffix("\n"))
    case ".":
      return lastInsertedText.map { Register(text: $0, linewise: false) }
    case "/":
      return lastSearch.map { Register(text: $0.pattern, linewise: false) }
    case ":":
      return lastCommandLine.map { Register(text: $0, linewise: false) }
    case "_":
      return nil
    default:
      return registers[Character(name.lowercased())]
    }
  }

  // MARK: Command execution

  func execute(_ command: Command) {
    switch command.action {
    case let .motion(spec):
      performMotion(spec, count: command.count)

    case let .operatorMotion(op, spec):
      let origin = cursor
      guard let result = evaluateMotion(spec, count: command.count, from: origin, operatorKey: op) else {
        fail()
        return
      }
      var start = min(origin, result.target)
      var end = max(origin, result.target)
      var linewise = result.linewise
      if let operatorEnd = result.operatorEnd {
        start = min(origin, operatorEnd)
        end = max(origin, operatorEnd)
      } else if linewise {
        start = VimText.lineStart(text, start)
        end = VimText.lineEndIncludingNewline(text, end)
      } else if result.inclusive {
        end = VimText.nextPosition(text, end)
      } else if end > start, VimText.lineStart(text, end) == end, spec.key != "<BS>" {
        // Exclusive motion ending in column 1 (":help o_v" exceptions).
        if start <= VimText.firstNonBlank(text, start), op != .yank || spec.key == "}" {
          linewise = true
          start = VimText.lineStart(text, start)
        } else {
          end -= 1
        }
      }
      if result.isJump { pushJump(from: origin) }
      applyOperator(op, range: NSRange(location: start, length: end - start), linewise: linewise, command: command, origin: origin)

    case let .operatorTextObject(op, spec):
      let origin = cursor
      guard let object = evaluateTextObject(spec, count: command.count, at: origin) else {
        fail()
        return
      }
      applyOperator(op, range: object.range, linewise: object.linewise, command: command, origin: origin)

    case let .operatorLine(op, count: motionCount):
      let origin = cursor
      let count = max(1, (command.count ?? 1) * (motionCount ?? 1))
      let start = VimText.lineStart(text, origin)
      var lastLine = start
      for _ in 1..<count {
        guard let next = VimText.nextLineStart(text, lastLine) else { break }
        lastLine = next
      }
      let end = VimText.lineEndIncludingNewline(text, lastLine)
      applyOperator(op, range: NSRange(location: start, length: end - start), linewise: true, command: command, origin: origin)

    case let .operatorSearch(op, forward):
      pendingOperatorSearch = (op, command)
      beginCommandLine(forward ? "/" : "?", initial: "")

    case let .textObject(spec):
      guard mode.isVisual, let object = evaluateTextObject(spec, count: command.count, at: visualCursor) else {
        fail()
        return
      }
      if object.range.length == 0 { return }
      if object.linewise || spec.kind == "p" {
        mode = .visualLine
      } else if mode == .visualLine {
        mode = .visual
      }
      let low = min(visualAnchor, visualCursor)
      if visualAnchor == visualCursor || object.range.location < low {
        visualAnchor = object.range.location
      }
      visualCursor = VimText.previousPosition(text, object.range.location + object.range.length)
      showVisualSelection()

    case let .visualOperator(op):
      applyVisualOperator(op, command: command)

    case let .command(name, argument):
      executeSimple(name, argument: argument, command: command)
    }
  }

  func performMotion(_ spec: MotionSpec, count: Int?) {
    let origin = cursor
    guard let result = evaluateMotion(spec, count: count, from: origin) else {
      fail()
      return
    }
    if result.isJump, result.target != origin { pushJump(from: origin) }
    if mode.isVisual {
      visualCursor = min(max(0, result.target), text.length)
      if mode != .visualBlock || result.curswant != nil || spec.key != "j" && spec.key != "k" {
        curswant = result.curswant
      }
      showVisualSelection()
    } else {
      setCursor(result.target, keepCurswant: true)
      curswant = result.curswant
    }
  }

  func recordChange(_ command: Command, visual: (mode: VimMode, lines: Int, columns: Int)? = nil) {
    guard !isReplaying else { return }
    lastChange = RecordedChange(register: command.register, count: command.count, keys: command.keys, insertedText: nil, visual: visual)
  }

  func makeChange(_ command: Command, visual: (mode: VimMode, lines: Int, columns: Int)? = nil) -> RecordedChange {
    RecordedChange(register: command.register, count: command.count, keys: command.keys, insertedText: nil, visual: visual)
  }

  // MARK: Operators

  func applyOperator(
    _ op: Operator,
    range: NSRange,
    linewise: Bool,
    command: Command,
    origin: Int,
    visual: (mode: VimMode, lines: Int, columns: Int)? = nil,
    times: Int = 1
  ) {
    let text = self.text
    switch op {
    case .yank:
      let value = text.substring(with: range)
      storeRegister(linewise && !value.hasSuffix("\n") ? value + "\n" : value, linewise: linewise, name: command.register, kind: .yank)
      let lines = value.components(separatedBy: "\n").count - (value.hasSuffix("\n") ? 1 : 0)
      if lines > 2 { setMessage("\(lines) lines yanked") }
      if linewise {
        if VimText.lineStart(text, origin) == range.location || visual != nil {
          setCursor(visual != nil ? range.location : origin)
        } else {
          setCursor(VimText.position(text, lineStart: range.location, column: column(of: origin)))
        }
      } else {
        setCursor(range.location)
      }

    case .delete:
      recordChange(command, visual: visual)
      deleteRange(range, linewise: linewise, register: command.register)

    case .change:
      let change = makeChange(command, visual: visual)
      changeRange(range, linewise: linewise, register: command.register, change: change)

    case .indent, .outdent:
      recordChange(command, visual: visual)
      let amount = op == .indent ? times : -times
      shiftLines(range, by: amount)

    case .toggleCase, .lowercase, .uppercase, .rot13:
      recordChange(command, visual: visual)
      let original = text.substring(with: range)
      replace(range, with: transformCase(original, op))
      setCursor(range.location)

    case .join:
      recordChange(command, visual: visual)
      let startLine = VimText.lineIndex(text, range.location)
      let endLine = VimText.lineIndex(text, max(range.location, range.location + range.length - 1))
      setCursor(range.location)
      joinLines(count: max(2, endLine - startLine + 1), insertSpaces: true)
    }
  }

  func transformCase(_ value: String, _ op: Operator) -> String {
    switch op {
    case .lowercase: return value.lowercased()
    case .uppercase: return value.uppercased()
    case .rot13:
      return String(value.unicodeScalars.map { scalar -> Character in
        switch scalar.value {
        case 65...90: return Character(UnicodeScalar((scalar.value - 65 + 13) % 26 + 65)!)
        case 97...122: return Character(UnicodeScalar((scalar.value - 97 + 13) % 26 + 97)!)
        default: return Character(scalar)
        }
      })
    default:
      return String(value.map { c -> String in
        let s = String(c)
        return s == s.uppercased() ? s.lowercased() : s.uppercased()
      }.joined())
    }
  }

  func deleteRange(_ range: NSRange, linewise: Bool, register: Character?) {
    let text = self.text
    var range = range
    var value = text.substring(with: range)
    if linewise {
      if !value.hasSuffix("\n") { value += "\n" }
      let end = range.location + range.length
      if end == text.length, range.location > 0,
         range.length == 0 || text.character(at: end - 1) != VimText.newline {
        range = NSRange(location: range.location - 1, length: range.length + 1)
      }
    }
    guard range.length > 0 else { return }
    storeRegister(value, linewise: linewise, name: register, kind: .delete)
    replace(range, with: "")
    let lineCount = value.components(separatedBy: "\n").count - 1
    if linewise, lineCount > 2 { setMessage("\(lineCount) fewer lines") }
    if linewise {
      setCursor(VimText.firstNonBlank(self.text, min(range.location, self.text.length)))
    } else {
      setCursor(range.location)
    }
  }

  func changeRange(_ range: NSRange, linewise: Bool, register: Character?, change: RecordedChange) {
    let text = self.text
    if linewise {
      let value = text.substring(with: range)
      storeRegister(value.hasSuffix("\n") ? value : value + "\n", linewise: true, name: register, kind: .delete)
      let indentEnd = VimText.firstNonBlank(text, range.location)
      var contentEnd = range.location + range.length
      if contentEnd > range.location, text.character(at: contentEnd - 1) == VimText.newline {
        contentEnd -= 1
      }
      let deleteStart = min(indentEnd, contentEnd)
      replace(NSRange(location: deleteStart, length: contentEnd - deleteStart), with: "")
      beginInsert(at: deleteStart, count: 1, kind: .plain, change: change)
      return
    }
    if range.length > 0 {
      storeRegister(text.substring(with: range), linewise: false, name: register, kind: .delete)
      replace(range, with: "")
    }
    beginInsert(at: range.location, count: 1, kind: .plain, change: change)
  }

  func indentUnit(_ times: Int) -> String {
    expandTab ? String(repeating: " ", count: shiftWidth * times) : String(repeating: "\t", count: times)
  }

  func shiftLines(_ range: NSRange, by amount: Int) {
    let text = self.text
    let start = VimText.lineStart(text, range.location)
    var endLocation = range.location + range.length
    if endLocation > start, range.length > 0, text.character(at: endLocation - 1) == VimText.newline { endLocation -= 1 }
    let end = VimText.lineEnd(text, max(start, endLocation))
    let block = text.substring(with: NSRange(location: start, length: end - start))
    let lines = block.components(separatedBy: "\n").map { line -> String in
      if amount > 0 {
        return line.isEmpty ? line : indentUnit(amount) + line
      }
      var remaining = shiftWidth * -amount
      var index = line.startIndex
      while remaining > 0, index < line.endIndex {
        if line[index] == " " {
          remaining -= 1
        } else if line[index] == "\t" {
          remaining -= shiftWidth
        } else {
          break
        }
        index = line.index(after: index)
      }
      return String(line[index...])
    }
    let replacement = lines.joined(separator: "\n")
    if replacement != block {
      replace(NSRange(location: start, length: end - start), with: replacement)
    }
    setCursor(VimText.firstNonBlank(self.text, start))
    if lines.count > 2 {
      setMessage("\(lines.count) lines \(amount > 0 ? ">" : "<")ed \(abs(amount)) time\(abs(amount) == 1 ? "" : "s")")
    }
  }

  func joinLines(count: Int, insertSpaces: Bool) {
    var joins = max(1, count - 1)
    var position = cursor
    var didJoin = false
    while joins > 0 {
      let text = self.text
      let lineEnd = VimText.lineEnd(text, position)
      guard lineEnd < text.length else { break }
      var next = lineEnd + 1
      if insertSpaces {
        while next < text.length, VimText.isBlank(text.character(at: next)) { next += 1 }
      }
      var separator = ""
      if insertSpaces {
        let lineStart = VimText.lineStart(text, lineEnd)
        let nextIsEmpty = next >= text.length || text.character(at: next) == VimText.newline
        let endsWithBlank = lineEnd > lineStart && VimText.isBlank(text.character(at: lineEnd - 1))
        if !nextIsEmpty && !endsWithBlank && text.character(at: next) != 41 {
          separator = " "
        }
      }
      replace(NSRange(location: lineEnd, length: next - lineEnd), with: separator)
      position = lineEnd
      didJoin = true
      joins -= 1
    }
    if !didJoin {
      fail()
      return
    }
    setCursor(position)
  }

  // MARK: Visual operators

  func visualExtent() -> (mode: VimMode, lines: Int, columns: Int) {
    let text = self.text
    let low = min(visualAnchor, visualCursor)
    let high = max(visualAnchor, visualCursor)
    let lines = VimText.newlineCount(text, NSRange(location: low, length: high - low))
    let columns = mode == .visualBlock
      ? abs(column(of: visualAnchor) - column(of: visualCursor))
      : (lines == 0 ? high - low : column(of: high))
    return (mode, lines, columns)
  }

  func applyVisualOperator(_ op: Operator, command: Command) {
    let extent = visualExtent()
    let visualMode = mode
    lastVisual = (mode, visualAnchor, visualCursor, curswant)
    if visualMode == .visualBlock {
      applyBlockOperator(op, command: command, extent: extent)
      return
    }
    let bounds = visualBounds(visualMode, anchor: visualAnchor, cursor: visualCursor)
    let range = NSRange(location: bounds.start, length: bounds.end - bounds.start)
    mode = .normal
    applyOperator(
      op,
      range: range,
      linewise: visualMode == .visualLine,
      command: command,
      origin: bounds.start,
      visual: extent,
      times: max(1, command.count ?? 1)
    )
  }

  func applyBlockOperator(_ op: Operator, command: Command, extent: (mode: VimMode, lines: Int, columns: Int)) {
    let toLineEnd = curswant == Int.max
    let ranges = blockRanges(anchor: visualAnchor, cursor: visualCursor, toLineEnd: toLineEnd)
    let leftColumn = min(column(of: visualAnchor), column(of: visualCursor))
    let topLeft = ranges.first?.location ?? cursor
    mode = .normal
    let text = self.text
    switch op {
    case .yank, .delete, .change:
      let value = ranges.map { text.substring(with: $0) }.joined(separator: "\n")
      storeRegister(value, linewise: false, blockwise: true, name: command.register, kind: op == .yank ? .yank : .delete)
      if op == .yank {
        setCursor(topLeft)
        return
      }
      if op == .delete { recordChange(command, visual: extent) }
      for range in ranges.reversed() where range.length > 0 {
        replace(range, with: "")
      }
      if op == .change {
        let starts = ranges.map { VimText.lineStart(self.text, $0.location) }
        beginInsert(
          at: topLeft,
          count: 1,
          kind: .block(lineStarts: starts, column: leftColumn, append: false, toLineEnd: false),
          change: makeChange(command, visual: extent)
        )
      } else {
        setCursor(topLeft)
      }
    case .toggleCase, .lowercase, .uppercase, .rot13:
      recordChange(command, visual: extent)
      for range in ranges.reversed() where range.length > 0 {
        replace(range, with: transformCase(text.substring(with: range), op))
      }
      setCursor(topLeft)
    case .indent, .outdent:
      recordChange(command, visual: extent)
      let first = ranges.first?.location ?? cursor
      let last = ranges.last.map { $0.location + $0.length } ?? cursor
      shiftLines(NSRange(location: first, length: last - first), by: (op == .indent ? 1 : -1) * max(1, command.count ?? 1))
    case .join:
      recordChange(command, visual: extent)
      setCursor(topLeft)
      joinLines(count: max(2, ranges.count), insertSpaces: true)
    }
  }

  // MARK: Insert sessions

  func beginInsert(at location: Int, count: Int, kind: InsertKind, change: RecordedChange?) {
    if insertOneShotNormal {
      // <C-o> followed by an insert command simply continues the insert.
      insertOneShotNormal = false
      mode = .insert
      host?.vimSetSelectedRanges([NSRange(location: min(max(0, location), text.length), length: 0)])
      return
    }
    mode = .insert
    let location = min(max(0, location), text.length)
    host?.vimSetSelectedRanges([NSRange(location: location, length: 0)])
    insertSession = InsertSession(startLocation: location, startLength: text.length, count: max(1, count), kind: kind, change: change)
    host?.vimInsertSessionDidBegin()
  }

  func beginReplaceMode(count: Int, change: RecordedChange?) {
    let location = cursor
    mode = .replace
    insertSession = InsertSession(startLocation: location, startLength: text.length, count: max(1, count), kind: .plain, change: change)
    host?.vimSetSelectedRanges([NSRange(location: location, length: 0)])
    host?.vimInsertSessionDidBegin()
  }

  func finishInsertSession() {
    let wasReplace = mode == .replace
    guard let session = insertSession else {
      mode = .normal
      setCursor(cursor)
      return
    }
    insertSession = nil
    awaitingInsertRegister = false
    let text = self.text
    let current = min(host?.vimSelectedRange.location ?? 0, text.length)
    let delta = text.length - session.startLength
    var inserted: String?
    if wasReplace {
      inserted = session.typedText
    } else if delta >= 0, current >= session.startLocation, current - session.startLocation == delta {
      inserted = text.substring(with: NSRange(location: session.startLocation, length: delta))
    }
    var finalCursor = current
    if let inserted, !inserted.isEmpty {
      switch session.kind {
      case .plain where session.count > 1:
        if wasReplace {
          for _ in 1..<session.count {
            let end = VimText.lineEnd(self.text, finalCursor)
            let length = min((inserted as NSString).length, end - finalCursor)
            replace(NSRange(location: finalCursor, length: max(0, length)), with: inserted)
            finalCursor += (inserted as NSString).length
          }
        } else {
          let extra = String(repeating: inserted, count: session.count - 1)
          replace(NSRange(location: current, length: 0), with: extra)
          finalCursor = current + (extra as NSString).length
        }
      case .openBelow, .openAbove:
        if session.count > 1 {
          let lineStart = VimText.lineStart(self.text, current)
          let indentEnd = VimText.firstNonBlank(self.text, lineStart)
          let indent = self.text.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))
          let lineEnd = VimText.lineEnd(self.text, current)
          let extra = String(repeating: "\n" + indent + inserted, count: session.count - 1)
          replace(NSRange(location: lineEnd, length: 0), with: extra)
          finalCursor = lineEnd + (extra as NSString).length
        }
      case let .block(lineStarts, column, append, toLineEnd) where !inserted.contains("\n"):
        let insertedLength = (inserted as NSString).length
        for original in lineStarts.dropFirst().reversed() {
          let lineStart = original + delta
          guard lineStart <= self.text.length else { continue }
          let lineEnd = VimText.lineEnd(self.text, lineStart)
          var position = toLineEnd ? lineEnd : lineStart + column
          var value = inserted
          if position > lineEnd {
            guard append else { continue }
            value = String(repeating: " ", count: position - lineEnd) + inserted
            position = lineEnd
          }
          replace(NSRange(location: position, length: 0), with: value)
        }
        finalCursor = min(current, self.text.length)
        _ = insertedLength
      default:
        break
      }
    }
    lastInsertedText = inserted ?? lastInsertedText
    lastInsertLocation = finalCursor
    if !isReplaying, var change = session.change {
      change.insertedText = inserted ?? ""
      lastChange = change
    }
    mode = .normal
    let lineStart = VimText.lineStart(self.text, finalCursor)
    setCursor(finalCursor > lineStart ? VimText.previousPosition(self.text, finalCursor) : finalCursor)
    host?.vimInsertSessionDidEnd()
  }

  func handleInsertKey(_ key: VimKey) -> Bool {
    if awaitingInsertRegister {
      awaitingInsertRegister = false
      if let name = key.first, key.count == 1, let register = readRegister(name) {
        insertTextAtCursor(register.text)
      }
      return true
    }
    switch key {
    case "<Esc>", "<C-c>", "<C-[>":
      finishInsertSession()
      return true
    case "<C-o>":
      insertOneShotNormal = true
      mode = .normal
      return true
    case "<C-r>":
      awaitingInsertRegister = true
      return true
    case "<C-w>":
      let text = self.text
      let location = cursor
      let lineStart = VimText.lineStart(text, location)
      if location == lineStart {
        guard location > 0 else { return true }
        replace(NSRange(location: location - 1, length: 1), with: "")
        host?.vimSetSelectedRanges([NSRange(location: location - 1, length: 0)])
        return true
      }
      var start = location
      while start > lineStart, VimText.isBlank(text.character(at: start - 1)) { start -= 1 }
      if start > lineStart {
        let cls = VimText.wordClass(text, start - 1, bigWord: false)
        while start > lineStart, VimText.wordClass(text, start - 1, bigWord: false) == cls { start -= 1 }
      }
      replace(NSRange(location: start, length: location - start), with: "")
      host?.vimSetSelectedRanges([NSRange(location: start, length: 0)])
      return true
    case "<C-u>":
      let text = self.text
      let location = cursor
      let lineStart = VimText.lineStart(text, location)
      let indentEnd = VimText.firstNonBlank(text, location)
      let start = location > indentEnd ? indentEnd : lineStart
      guard location > start else { return true }
      replace(NSRange(location: start, length: location - start), with: "")
      host?.vimSetSelectedRanges([NSRange(location: start, length: 0)])
      return true
    case "<C-t>", "<C-d>":
      let location = cursor
      let before = text.length
      let lineStart = VimText.lineStart(text, location)
      shiftLines(NSRange(location: lineStart, length: 0), by: key == "<C-t>" ? 1 : -1)
      let shift = text.length - before
      host?.vimSetSelectedRanges([NSRange(location: max(lineStart, location + shift), length: 0)])
      return true
    default:
      guard isReplaying else { return false }
      applyReplayedInsertKey(key)
      return true
    }
  }

  func insertTextAtCursor(_ value: String) {
    let location = cursor
    replace(NSRange(location: location, length: 0), with: value)
    host?.vimSetSelectedRanges([NSRange(location: location + (value as NSString).length, length: 0)])
  }

  func applyReplayedInsertKey(_ key: VimKey) {
    let location = cursor
    switch key {
    case "<CR>": host?.vimTypeNewline()
    case "<BS>", "<C-h>": host?.vimTypeDeleteBackward()
    case "<Tab>": host?.vimTypeTab()
    case "<Del>":
      if location < text.length { replace(NSRange(location: location, length: VimText.nextPosition(text, location) - location), with: "") }
    case "<Left>": host?.vimSetSelectedRanges([NSRange(location: max(VimText.lineStart(text, location), location - 1), length: 0)])
    case "<Right>": host?.vimSetSelectedRanges([NSRange(location: min(VimText.lineEnd(text, location), location + 1), length: 0)])
    case "<Up>", "<Down>":
      let column = location - VimText.lineStart(text, location)
      let target = key == "<Up>" ? VimText.previousLineStart(text, location) : VimText.nextLineStart(text, location)
      if let target {
        host?.vimSetSelectedRanges([NSRange(location: VimText.position(text, lineStart: target, column: column, allowLineEnd: true), length: 0)])
      }
    case "<Home>": host?.vimSetSelectedRanges([NSRange(location: VimText.lineStart(text, location), length: 0)])
    case "<End>": host?.vimSetSelectedRanges([NSRange(location: VimText.lineEnd(text, location), length: 0)])
    default:
      guard key.count == 1 || key == "<Space>" || key == "<lt>" else { return }
      host?.vimTypeText(Self.literal(key))
    }
  }

  func handleReplaceKey(_ key: VimKey) -> Bool {
    switch key {
    case "<Esc>", "<C-c>", "<C-[>":
      finishInsertSession()
      return true
    case "<BS>", "<C-h>":
      guard var session = insertSession, let original = session.replacedCharacters.popLast() else {
        let location = cursor
        if location > 0 { host?.vimSetSelectedRanges([NSRange(location: VimText.previousPosition(text, location), length: 0)]) }
        return true
      }
      let location = cursor
      let previous = VimText.previousPosition(text, location)
      replace(NSRange(location: previous, length: location - previous), with: original)
      host?.vimSetSelectedRanges([NSRange(location: previous, length: 0)])
      if !session.typedText.isEmpty { session.typedText.removeLast() }
      insertSession = session
      return true
    case "<CR>":
      host?.vimTypeNewline()
      insertSession?.replacedCharacters.append("")
      insertSession?.typedText += "\n"
      return true
    default:
      guard key.count == 1 || key == "<Space>" || key == "<lt>" else {
        return isReplaying
      }
      let value = Self.literal(key)
      let text = self.text
      let location = cursor
      var original = ""
      var range = NSRange(location: location, length: 0)
      if location < text.length, text.character(at: location) != VimText.newline {
        range.length = VimText.nextPosition(text, location) - location
        original = text.substring(with: range)
      }
      replace(range, with: value)
      host?.vimSetSelectedRanges([NSRange(location: location + (value as NSString).length, length: 0)])
      insertSession?.replacedCharacters.append(original)
      insertSession?.typedText += value
      return true
    }
  }

  // MARK: Put

  func put(after: Bool, count: Int, register name: Character?, cursorAfter: Bool) {
    guard let register = readRegister(name), !register.text.isEmpty || register.linewise else {
      fail("E353: Nothing in register \(name.map { String($0) } ?? "\"")")
      return
    }
    let times = max(1, count)
    let text = self.text
    let location = cursor
    if register.blockwise {
      putBlock(register.text, after: after, times: times)
      return
    }
    if register.linewise {
      var body = register.text
      if !body.hasSuffix("\n") { body += "\n" }
      body = String(repeating: body, count: times)
      var insertAt: Int
      var insertion = body
      var firstLineStart: Int
      if after {
        let lineEnd = VimText.lineEnd(text, location)
        if lineEnd >= text.length {
          insertAt = text.length
          insertion = "\n" + String(body.dropLast())
          firstLineStart = text.length + 1
        } else {
          insertAt = lineEnd + 1
          firstLineStart = insertAt
        }
      } else {
        insertAt = VimText.lineStart(text, location)
        firstLineStart = insertAt
      }
      replace(NSRange(location: insertAt, length: 0), with: insertion)
      let bodyLength = (body as NSString).length
      if cursorAfter {
        setCursor(min(firstLineStart + bodyLength, self.text.length))
      } else {
        setCursor(VimText.firstNonBlank(self.text, firstLineStart))
      }
      return
    }
    let body = String(repeating: register.text, count: times)
    var insertAt = location
    if after, insertAt < text.length, text.character(at: insertAt) != VimText.newline {
      insertAt = VimText.nextPosition(text, insertAt)
    }
    replace(NSRange(location: insertAt, length: 0), with: body)
    let bodyLength = (body as NSString).length
    if cursorAfter {
      mode = .normal
      host?.vimSetSelectedRanges([NSRange(location: insertAt + bodyLength, length: 0)])
    } else if body.contains("\n") {
      setCursor(insertAt)
    } else {
      setCursor(VimText.previousPosition(self.text, insertAt + bodyLength))
    }
  }

  func putBlock(_ value: String, after: Bool, times: Int) {
    let pieces = value.components(separatedBy: "\n")
    let width = pieces.map { ($0 as NSString).length }.max() ?? 0
    let location = cursor
    var column = column(of: location)
    if after, !VimText.isEmptyLine(text, location) { column += 1 }
    var lineStart = VimText.lineStart(text, location)
    for (index, piece) in pieces.enumerated() {
      if index > 0 {
        if let next = VimText.nextLineStart(text, lineStart) {
          lineStart = next
        } else {
          replace(NSRange(location: text.length, length: 0), with: "\n")
          lineStart = text.length
        }
      }
      let lineEnd = VimText.lineEnd(text, lineStart)
      var padded = String(repeating: piece + String(repeating: " ", count: max(0, width - (piece as NSString).length)), count: times)
      var position = lineStart + column
      if position > lineEnd {
        padded = String(repeating: " ", count: position - lineEnd) + padded
        position = lineEnd
      } else if position == lineEnd {
        padded = String(padded.reversed().drop(while: { $0 == " " }).reversed())
      }
      replace(NSRange(location: position, length: 0), with: padded)
    }
    setCursor(VimText.lineStart(text, location) + column)
  }

  func visualPut(_ command: Command, keepRegister: Bool) {
    guard let register = readRegister(command.register) else {
      fail("E353: Nothing in register")
      return
    }
    let visualMode = mode
    lastVisual = (mode, visualAnchor, visualCursor, curswant)
    var ranges: [NSRange]
    if visualMode == .visualBlock {
      ranges = blockRanges(anchor: visualAnchor, cursor: visualCursor, toLineEnd: curswant == Int.max)
    } else {
      let bounds = visualBounds(visualMode, anchor: visualAnchor, cursor: visualCursor)
      ranges = [NSRange(location: bounds.start, length: bounds.end - bounds.start)]
    }
    mode = .normal
    recordChange(command)
    let replaced = ranges.map { text.substring(with: $0) }.joined(separator: "\n")
    let times = max(1, command.count ?? 1)
    var insertion = String(repeating: register.text, count: times)
    let selectionLinewise = visualMode == .visualLine
    if register.linewise && !selectionLinewise {
      insertion = "\n" + (insertion.hasSuffix("\n") ? insertion : insertion + "\n")
    } else if !register.linewise && selectionLinewise {
      insertion += "\n"
    }
    for range in ranges.dropFirst().reversed() {
      replace(range, with: "")
    }
    let target = ranges[0]
    replace(target, with: insertion)
    if !keepRegister {
      storeRegister(selectionLinewise && !replaced.hasSuffix("\n") ? replaced + "\n" : replaced, linewise: selectionLinewise, name: nil, kind: .delete)
    }
    if register.linewise {
      let start = target.location + (insertion.hasPrefix("\n") ? 1 : 0)
      setCursor(VimText.firstNonBlank(text, start))
    } else {
      setCursor(VimText.previousPosition(text, target.location + (insertion as NSString).length - (insertion.hasSuffix("\n") ? 1 : 0)))
    }
  }

  // MARK: Dot repeat and macros

  func repeatLastChange(count: Int?) {
    guard let change = lastChange else {
      fail()
      return
    }
    isReplaying = true
    replayDepth += 1
    defer {
      replayDepth -= 1
      if replayDepth == 0 { isReplaying = false }
    }
    var keys: [VimKey] = []
    if let register = change.register {
      var name = register
      if let digit = register.wholeNumberValue, register.isNumber, digit < 9 {
        name = Character(String(digit + 1))
        lastChange?.register = name
      }
      keys += ["\"", String(name)]
    }
    let effectiveCount = count ?? change.count
    if let visual = change.visual {
      // Re-create a selection of the same size at the cursor.
      let text = self.text
      let start = cursor
      var end = start
      switch visual.mode {
      case .visualLine:
        var lineStart = VimText.lineStart(text, start)
        for _ in 0..<visual.lines { lineStart = VimText.nextLineStart(text, lineStart) ?? lineStart }
        end = lineStart
      case .visualBlock:
        var lineStart = VimText.lineStart(text, start)
        for _ in 0..<visual.lines { lineStart = VimText.nextLineStart(text, lineStart) ?? lineStart }
        end = min(VimText.lineEnd(text, lineStart), lineStart + column(of: start) + visual.columns)
      default:
        if visual.lines == 0 {
          end = min(VimText.lastCharPosition(text, start), start + visual.columns)
        } else {
          var lineStart = VimText.lineStart(text, start)
          for _ in 0..<visual.lines { lineStart = VimText.nextLineStart(text, lineStart) ?? lineStart }
          end = min(VimText.lineEnd(text, lineStart), lineStart + visual.columns)
        }
      }
      mode = visual.mode
      visualAnchor = start
      visualCursor = end
      showVisualSelection()
    } else if let effectiveCount {
      keys += String(effectiveCount).map { String($0) }
    }
    keys += change.keys
    feed(keys)
    if mode == .insert || mode == .replace {
      if let inserted = change.insertedText, !inserted.isEmpty {
        if mode == .replace {
          for character in inserted {
            _ = handleReplaceKey(character == "\n" ? "<CR>" : String(character))
          }
        } else {
          insertTextAtCursor(inserted)
        }
      }
      finishInsertSession()
    }
  }

  func startRecording(_ name: Character) {
    guard name.isLetter || name.isNumber || name == "\"" else {
      fail()
      return
    }
    recordingRegister = name
    recordedKeys = []
    if name.isUppercase, let existing = registers[Character(name.lowercased())] {
      recordedKeys = Self.keys(from: existing.text)
    }
  }

  func stopRecording() {
    guard let name = recordingRegister else { return }
    if recordedKeys.last == "q" { recordedKeys.removeLast() }
    let value = recordedKeys.map { $0 == "<" ? "<lt>" : $0 }.joined()
    registers[Character(name.lowercased())] = Register(text: value, linewise: false)
    recordingRegister = nil
    recordedKeys = []
  }

  func executeMacro(_ name: Character, count: Int) {
    var registerName = name
    if name == "@" {
      guard let last = lastExecutedMacro else {
        fail("E748: No previously used register")
        return
      }
      registerName = last
    }
    if registerName == ":" {
      guard let lastCommandLine else {
        fail("E30: No previous command line")
        return
      }
      lastExecutedMacro = ":"
      for _ in 0..<max(1, count) { executeCommandLine(lastCommandLine) }
      return
    }
    guard replayDepth < 20, let register = readRegister(registerName) else {
      fail()
      return
    }
    lastExecutedMacro = registerName
    let keys = Self.keys(from: register.text)
    isReplaying = true
    replayDepth += 1
    defer {
      replayDepth -= 1
      if replayDepth == 0 { isReplaying = false }
    }
    for _ in 0..<max(1, count) {
      feed(keys)
    }
  }
}

extension VimText {
  static func newlineCount(_ text: NSString, _ range: NSRange) -> Int {
    var count = 0
    var search = range
    let end = range.location + range.length
    while search.length > 0 {
      let found = text.range(of: "\n", options: [], range: search)
      if found.location == NSNotFound { break }
      count += 1
      search = NSRange(location: found.location + 1, length: end - found.location - 1)
    }
    return count
  }
}
