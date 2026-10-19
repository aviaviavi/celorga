import Foundation

extension VimEngine {
  struct ExError: Error {
    let message: String
  }

  // MARK: Command-line mode

  func beginCommandLine(_ prefix: Character, initial: String, fromVisual: Bool = false) {
    if !fromVisual {
      commandLineReturnMode = .normal
    }
    commandLinePrefix = prefix
    commandLineText = initial
    historyIndex = nil
    mode = .commandLine
  }

  func handleCommandLineKey(_ key: VimKey) -> Bool {
    if awaitingCommandLineRegister {
      awaitingCommandLineRegister = false
      if key == "<C-w>" {
        if let word = VimText.wordObject(text, at: cursor, count: 1, around: false, bigWord: false) {
          commandLineText += text.substring(with: word)
        }
      } else if let name = key.first, key.count == 1, let register = readRegister(name) {
        commandLineText += register.text.trimmingCharacters(in: .newlines)
      }
      return true
    }
    switch key {
    case "<Esc>", "<C-c>", "<C-[>":
      cancelCommandLine()
    case "<CR>":
      submitCommandLine()
    case "<BS>", "<C-h>":
      if commandLineText.isEmpty {
        cancelCommandLine()
      } else {
        commandLineText.removeLast()
      }
    case "<C-u>":
      commandLineText = ""
    case "<C-w>":
      while commandLineText.last == " " { commandLineText.removeLast() }
      while let last = commandLineText.last, last != " ", last != "/" { commandLineText.removeLast() }
    case "<C-r>":
      awaitingCommandLineRegister = true
    case "<Up>", "<Down>", "<C-p>", "<C-n>":
      let history = commandLinePrefix == ":" ? commandHistory : searchHistory
      guard !history.isEmpty else { return true }
      let up = key == "<Up>" || key == "<C-p>"
      var index = historyIndex ?? history.count
      index = up ? max(0, index - 1) : min(history.count, index + 1)
      historyIndex = index
      commandLineText = index < history.count ? history[index] : ""
    case "<Space>":
      commandLineText += " "
    case "<lt>":
      commandLineText += "<"
    case "<Tab>":
      break
    default:
      if key.count == 1 {
        commandLineText += key
      }
    }
    return true
  }

  func cancelCommandLine() {
    pendingOperatorSearch = nil
    let returnMode = commandLineReturnMode
    commandLineReturnMode = .normal
    if returnMode.isVisual {
      mode = returnMode
      showVisualSelection()
    } else {
      mode = .normal
      setCursor(cursor)
    }
  }

  func pasteIntoCommandLine(_ value: String) {
    guard mode == .commandLine else { return }
    commandLineText += value.replacingOccurrences(of: "\n", with: " ")
    host?.vimStateDidChange()
  }

  func submitCommandLine() {
    let line = commandLineText
    let prefix = commandLinePrefix
    let returnMode = commandLineReturnMode
    commandLineReturnMode = .normal
    mode = returnMode.isVisual ? returnMode : .normal
    if prefix == ":" {
      appendHistory(&commandHistory, line)
      lastCommandLine = line
      executeCommandLine(line)
      return
    }
    let forward = prefix == "/"
    var pattern = line
    // Drop a trailing search offset delimiter such as "/foo/".
    if let last = pattern.last, last == prefix, !pattern.hasSuffix("\\\(prefix)") {
      pattern.removeLast()
    }
    if pattern.isEmpty {
      guard let previous = lastSearch?.pattern else {
        pendingOperatorSearch = nil
        fail("E35: No previous regular expression")
        if mode == .normal { setCursor(cursor) }
        return
      }
      pattern = previous
    } else {
      appendHistory(&searchHistory, pattern)
    }
    lastSearch = (pattern, forward)
    if let pending = pendingOperatorSearch {
      pendingOperatorSearch = nil
      let origin = cursor
      guard let target = search(pattern, forward: forward, from: origin, count: max(1, pending.command.count ?? 1)) else {
        setCursor(origin)
        return
      }
      var command = pending.command
      command.keys += VimEngine.keys(from: line.replacingOccurrences(of: "<", with: "<lt>")) + ["<CR>"]
      let start = min(origin, target)
      let end = max(origin, target)
      applyOperator(pending.op, range: NSRange(location: start, length: end - start), linewise: false, command: command, origin: origin)
      return
    }
    let origin = mode.isVisual ? visualCursor : cursor
    guard let target = search(pattern, forward: forward, from: origin, count: 1) else {
      if mode.isVisual { showVisualSelection() } else { setCursor(origin) }
      return
    }
    pushJump(from: origin)
    if mode.isVisual {
      visualCursor = target
      showVisualSelection()
    } else {
      setCursor(target)
    }
  }

  // MARK: Ex commands

  func executeCommandLine(_ input: String) {
    do {
      try runEx(input)
    } catch let error as ExError {
      fail(error.message)
      if mode == .normal { setCursor(cursor) }
    } catch {
      fail("E492: Not an editor command: \(input)")
    }
  }

  private struct ExRange {
    var first: Int
    var last: Int
    var explicit: Bool
  }

  private func runEx(_ input: String) throws {
    let characters = Array(input)
    var index = 0
    func skipSpaces() {
      while index < characters.count, characters[index] == " " || characters[index] == ":" { index += 1 }
    }
    skipSpaces()
    let text = self.text
    let currentLine = VimText.lineIndex(text, cursor)
    let lastLine = VimText.lineCount(text) - 1
    var range = ExRange(first: currentLine, last: currentLine, explicit: false)

    if index < characters.count, characters[index] == "%" {
      range = ExRange(first: 0, last: lastLine, explicit: true)
      index += 1
    } else if let first = try parseAddress(characters, &index, currentLine: currentLine, lastLine: lastLine) {
      range = ExRange(first: first, last: first, explicit: true)
      if index < characters.count, characters[index] == "," || characters[index] == ";" {
        let separator = characters[index]
        index += 1
        let base = separator == ";" ? first : currentLine
        let second = try parseAddress(characters, &index, currentLine: base, lastLine: lastLine) ?? base
        range.last = second
      }
      if range.first > range.last { swap(&range.first, &range.last) }
    }
    range.first = min(max(0, range.first), lastLine)
    range.last = min(max(0, range.last), lastLine)

    skipSpaces()
    var name = ""
    if index < characters.count, characters[index].isLetter {
      while index < characters.count, characters[index].isLetter {
        name.append(characters[index])
        index += 1
      }
      // ":s" style commands may be glued to their delimiter or flags.
      if name.count > 1, name.first == "s", !Self.isKnownExName(name), characters.count > 1 {
        index -= name.count - 1
        name = "s"
      }
    } else if index < characters.count {
      name = String(characters[index])
      index += 1
      if name == "&", index < characters.count, characters[index] == "&" {
        name = "&&"
        index += 1
      }
      if name == ">" || name == "<" {
        while index < characters.count, String(characters[index]) == name.prefix(1) {
          name.append(characters[index])
          index += 1
        }
      }
    }
    var bang = false
    if index < characters.count, characters[index] == "!" {
      bang = true
      index += 1
    }
    let argument = String(characters[index...]).trimmingCharacters(in: .whitespaces)
    let rawArgument = String(characters[index...])

    switch Self.canonicalExName(name) {
    case "":
      guard range.explicit else { return }
      pushJump(from: cursor)
      setCursor(VimText.firstNonBlank(self.text, VimText.startOfLine(self.text, index: range.last)))
    case "write", "wall", "update":
      if host?.vimSave() == true { setMessage("Saved") } else { throw ExError(message: "E212: Can't save this document") }
    case "wq", "xit", "exit", "wqall", "xall":
      if host?.vimSave() == true { setMessage("Saved — close the document with ⌘W") }
    case "quit", "qall", "close":
      setMessage(bang ? "Close the document with ⌘W" : "Close the document with ⌘W")
    case "substitute":
      try substitute(range: range.first...range.last, argument: rawArgument)
    case "&":
      try repeatSubstituteCommand(range: range.first...range.last, flags: argument, keepFlags: false)
    case "&&":
      try repeatSubstituteCommand(range: range.first...range.last, flags: argument, keepFlags: true)
    case "delete", "yank":
      var register: Character?
      var rest = Substring(argument)
      if let first = rest.first, !first.isNumber, Self.isValidRegister(first) {
        register = first
        rest = rest.dropFirst().drop(while: { $0 == " " })
      }
      var last = range.last
      var first = range.first
      if let count = Int(rest), count > 0 {
        first = range.last
        last = min(lastLine, range.last + count - 1)
      }
      let start = VimText.startOfLine(self.text, index: first)
      let end = VimText.lineEndIncludingNewline(self.text, VimText.startOfLine(self.text, index: last))
      let lineRange = NSRange(location: start, length: end - start)
      if Self.canonicalExName(name) == "delete" {
        deleteRange(lineRange, linewise: true, register: register)
      } else {
        let value = self.text.substring(with: lineRange)
        storeRegister(value.hasSuffix("\n") ? value : value + "\n", linewise: true, name: register, kind: .yank)
      }
    case "join":
      let last = range.explicit && range.first != range.last ? range.last : min(lastLine, range.first + max(1, Int(argument) ?? 2) - 1)
      setCursor(VimText.startOfLine(self.text, index: range.first))
      joinLines(count: max(2, last - range.first + 1), insertSpaces: !bang)
    case ">", ">>", ">>>", "<", "<<", "<<<":
      let start = VimText.startOfLine(self.text, index: range.first)
      let end = VimText.lineEnd(self.text, VimText.startOfLine(self.text, index: range.last))
      shiftLines(NSRange(location: start, length: end - start), by: name.first == ">" ? name.count : -name.count)
    case "move", "copy":
      var addressIndex = 0
      let addressCharacters = Array(argument)
      guard let target = try parseAddress(addressCharacters, &addressIndex, currentLine: currentLine, lastLine: lastLine, allowZero: true) else {
        throw ExError(message: "E14: Invalid address")
      }
      try moveOrCopyLines(range.first...range.last, after: target, copy: Self.canonicalExName(name) == "copy")
    case "put":
      var register: Character?
      if let first = argument.first { register = first }
      guard let value = readRegister(register) else { throw ExError(message: "E353: Nothing in register") }
      let line = range.explicit ? range.last : currentLine
      let saved = registers["\u{1}"]
      registers["\u{1}"] = Register(text: value.text, linewise: true)
      if line < 0 || (range.explicit && range.last == 0 && bang) {
        setCursor(0)
        put(after: false, count: 1, register: "\u{1}", cursorAfter: false)
      } else {
        setCursor(VimText.startOfLine(self.text, index: line))
        put(after: !bang, count: 1, register: "\u{1}", cursorAfter: false)
      }
      registers["\u{1}"] = saved
    case "normal":
      let keys = VimEngine.keys(from: rawArgument.hasPrefix(" ") ? String(rawArgument.dropFirst()) : rawArgument)
      guard !keys.isEmpty else { return }
      var line = range.first
      var remaining = range.last - range.first + 1
      isReplaying = true
      replayDepth += 1
      defer {
        replayDepth -= 1
        if replayDepth == 0 { isReplaying = false }
      }
      while remaining > 0 {
        let before = VimText.lineCount(self.text)
        mode = .normal
        setCursor(VimText.startOfLine(self.text, index: line))
        feed(keys)
        if mode == .insert || mode == .replace { finishInsertSession() }
        if mode.isVisual { exitVisual() }
        if mode == .commandLine { cancelCommandLine() }
        pending.removeAll()
        let delta = VimText.lineCount(self.text) - before
        line += 1 + delta
        remaining -= 1
      }
    case "global", "vglobal":
      try global(
        range: range.explicit ? range.first...range.last : 0...lastLine,
        argument: rawArgument.trimmingCharacters(in: .whitespaces),
        invert: bang || Self.canonicalExName(name) == "vglobal"
      )
    case "sort":
      sortLines(range.explicit ? range.first...range.last : 0...lastLine, reverse: bang, flags: argument)
    case "nohlsearch":
      break
    case "undo":
      if host?.vimUndo() != true { setMessage("Already at oldest change") }
      settleCursorAfterHistoryChange()
    case "redo":
      if host?.vimRedo() != true { setMessage("Already at newest change") }
      settleCursorAfterHistoryChange()
    case "set":
      try applySetting(argument)
    case "registers":
      let names = registers.keys.filter { $0 != "\u{1}" }.sorted()
      let summary = names.prefix(12).map { name -> String in
        let value = registers[name]?.text.replacingOccurrences(of: "\n", with: "^J") ?? ""
        return "\"\(name) \(value.prefix(24))"
      }
      setMessage(summary.isEmpty ? "No registers" : summary.joined(separator: "  "))
    case "marks":
      let summary = marks.keys.sorted().map { name -> String in
        "\(name) \(VimText.lineIndex(self.text, min(marks[name] ?? 0, self.text.length)) + 1)"
      }
      setMessage(summary.isEmpty ? "No marks set" : summary.joined(separator: "  "))
    case "mark":
      guard let mark = argument.first, mark.isLetter else { throw ExError(message: "E191: Argument must be a letter") }
      marks[mark] = VimText.startOfLine(self.text, index: range.last)
    default:
      throw ExError(message: "E492: Not an editor command: \(input)")
    }
  }

  static let exCommands: [(name: String, minimum: Int)] = [
    ("write", 1), ("wq", 2), ("wall", 2), ("wqall", 3), ("xit", 1), ("exit", 3), ("xall", 2), ("update", 2),
    ("quit", 1), ("qall", 2), ("close", 3),
    ("substitute", 1), ("delete", 1), ("yank", 1), ("join", 1), ("move", 1), ("copy", 2), ("t", 1),
    ("put", 2), ("normal", 4), ("global", 1), ("vglobal", 1), ("sort", 3), ("nohlsearch", 3),
    ("undo", 1), ("redo", 3), ("set", 2), ("registers", 3), ("display", 2), ("marks", 5), ("mark", 2), ("k", 1)
  ]

  static func isKnownExName(_ name: String) -> Bool {
    canonicalExName(name) != nil
  }

  static func canonicalExName(_ name: String) -> String? {
    if name.isEmpty { return "" }
    if !name.first!.isLetter { return name }
    if name == "x" { return "xit" }
    if name == "t" || name == "co" { return "copy" }
    if name == "k" { return "mark" }
    if name == "v" { return "vglobal" }
    if name == "g" { return "global" }
    if name == "di" || name == "display" { return "registers" }
    for command in exCommands where name.count >= command.minimum && command.name.hasPrefix(name) {
      if command.name == "t" { return "copy" }
      if command.name == "k" { return "mark" }
      if command.name == "display" { return "registers" }
      // Prefer the shortest exact abbreviation ("w" is write, not wq).
      return command.name
    }
    return nil
  }

  private func parseAddress(_ characters: [Character], _ index: inout Int, currentLine: Int, lastLine: Int, allowZero: Bool = false) throws -> Int? {
    var base: Int?
    guard index < characters.count else { return nil }
    let c = characters[index]
    switch c {
    case ".":
      base = currentLine
      index += 1
    case "$":
      base = lastLine
      index += 1
    case "0"..."9":
      var value = 0
      while index < characters.count, let digit = characters[index].wholeNumberValue, characters[index].isASCII {
        value = value * 10 + digit
        index += 1
      }
      base = allowZero && value == 0 ? -1 : max(0, value - 1)
    case "'":
      guard index + 1 < characters.count else { throw ExError(message: "E20: Mark not set") }
      let name = characters[index + 1]
      index += 2
      guard let location = markLocation(name, current: cursor) else { throw ExError(message: "E20: Mark not set") }
      base = VimText.lineIndex(text, min(location, text.length))
    case "/", "?":
      let delimiter = c
      index += 1
      var pattern = ""
      while index < characters.count, characters[index] != delimiter {
        if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == delimiter {
          pattern.append(delimiter)
          index += 2
          continue
        }
        pattern.append(characters[index])
        index += 1
      }
      if index < characters.count { index += 1 }
      if pattern.isEmpty { pattern = lastSearch?.pattern ?? "" }
      let text = self.text
      let origin = delimiter == "/"
        ? VimText.lineEnd(text, VimText.startOfLine(text, index: currentLine))
        : VimText.startOfLine(text, index: currentLine)
      let previousMessage = message
      guard let found = search(pattern, forward: delimiter == "/", from: origin, count: 1) else {
        throw ExError(message: "E486: Pattern not found: \(pattern)")
      }
      message = previousMessage
      base = VimText.lineIndex(text, found)
    case "+", "-":
      base = currentLine
    default:
      return nil
    }
    while index < characters.count, characters[index] == "+" || characters[index] == "-" {
      let sign = characters[index] == "+" ? 1 : -1
      index += 1
      var value = 0
      var hasDigits = false
      while index < characters.count, let digit = characters[index].wholeNumberValue, characters[index].isASCII {
        value = value * 10 + digit
        hasDigits = true
        index += 1
      }
      base = (base ?? currentLine) + sign * (hasDigits ? value : 1)
    }
    return base
  }

  // MARK: Substitute

  private func splitPattern(_ argument: String) -> (pattern: String, replacement: String?, flags: String)? {
    let characters = Array(argument.drop(while: { $0 == " " }))
    guard let delimiter = characters.first, !delimiter.isLetter, !delimiter.isNumber, delimiter != "\\", delimiter != "\"", delimiter != "|" else {
      return nil
    }
    var parts: [String] = [""]
    var index = 1
    while index < characters.count {
      let c = characters[index]
      if c == "\\", index + 1 < characters.count {
        if characters[index + 1] == delimiter {
          parts[parts.count - 1].append(delimiter)
        } else {
          parts[parts.count - 1].append(c)
          parts[parts.count - 1].append(characters[index + 1])
        }
        index += 2
        continue
      }
      if c == delimiter, parts.count < 3 {
        parts.append("")
        index += 1
        continue
      }
      parts[parts.count - 1].append(c)
      index += 1
    }
    let pattern = parts[0]
    let replacement = parts.count > 1 ? parts[1] : nil
    let flags = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
    return (pattern, replacement, flags)
  }

  func substitute(range: ClosedRange<Int>, argument: String) throws {
    guard let parsed = splitPattern(argument) else {
      try repeatSubstituteCommand(range: range, flags: argument.trimmingCharacters(in: .whitespaces), keepFlags: false)
      return
    }
    var pattern = parsed.pattern
    if pattern.isEmpty {
      guard let previous = lastSearch?.pattern ?? lastSubstitute?.pattern else {
        throw ExError(message: "E35: No previous regular expression")
      }
      pattern = previous
    }
    var replacement = parsed.replacement ?? ""
    if replacement == "~" { replacement = lastSubstitute?.replacement ?? "" }
    var flags = parsed.flags
    var countRange = range
    if let countStart = flags.firstIndex(where: { $0.isNumber }), let count = Int(flags[countStart...].trimmingCharacters(in: .whitespaces)) {
      flags = String(flags[..<countStart])
      let last = min(VimText.lineCount(text) - 1, range.upperBound + count - 1)
      countRange = range.upperBound...last
    }
    if flags.hasPrefix("&") {
      flags = (lastSubstitute?.flags ?? "") + flags.dropFirst()
    }
    lastSubstitute = (pattern, replacement, flags)
    lastSearch = (pattern, true)
    try performSubstitute(range: countRange, pattern: pattern, replacement: replacement, flags: flags)
  }

  func repeatSubstituteCommand(range: ClosedRange<Int>, flags: String, keepFlags: Bool) throws {
    guard let lastSubstitute else { throw ExError(message: "E35: No previous regular expression") }
    let effectiveFlags = keepFlags ? lastSubstitute.flags + flags.replacingOccurrences(of: "&", with: "") : flags.replacingOccurrences(of: "&", with: lastSubstitute.flags)
    try performSubstitute(range: range, pattern: lastSubstitute.pattern, replacement: lastSubstitute.replacement, flags: effectiveFlags)
  }

  func repeatSubstitute(wholeFile: Bool, keepFlags: Bool) {
    let line = VimText.lineIndex(text, cursor)
    let range = wholeFile ? 0...(VimText.lineCount(text) - 1) : line...line
    do {
      try repeatSubstituteCommand(range: range, flags: "", keepFlags: keepFlags)
    } catch let error as ExError {
      fail(error.message)
    } catch {
      fail()
    }
  }

  func performSubstitute(range: ClosedRange<Int>, pattern: String, replacement: String, flags: String) throws {
    let caseInsensitive = flags.contains("i") ? true : (flags.contains("I") ? false : ignoreCase)
    guard let regex = VimPattern.regex(pattern, ignoreCase: caseInsensitive, smartCase: flags.contains("i") || flags.contains("I") ? false : smartCase) else {
      throw ExError(message: "E383: Invalid search string: \(pattern)")
    }
    let global = flags.contains("g")
    let countOnly = flags.contains("n")
    let template = VimPattern.template(replacement)
    let text = self.text
    let start = VimText.startOfLine(text, index: range.lowerBound)
    let end = VimText.lineEnd(text, VimText.startOfLine(text, index: range.upperBound))
    let block = text.substring(with: NSRange(location: start, length: end - start))
    let lines = block.components(separatedBy: "\n")
    var output: [String] = []
    var substitutions = 0
    var changedLines = 0
    var lastChangedOffset: Int?
    var offset = 0
    for line in lines {
      let nsLine = line as NSString
      let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
      let applied = global ? matches : Array(matches.prefix(1))
      if applied.isEmpty {
        output.append(line)
        offset += nsLine.length + 1
        continue
      }
      substitutions += applied.count
      changedLines += 1
      if countOnly {
        output.append(line)
        offset += nsLine.length + 1
        continue
      }
      let result = NSMutableString(string: line)
      for match in applied.reversed() {
        let replacementText = regex.replacementString(for: match, in: line, offset: 0, template: template)
        result.replaceCharacters(in: match.range, with: replacementText)
      }
      lastChangedOffset = offset
      output.append(result as String)
      offset += result.length + 1
    }
    guard substitutions > 0 else {
      throw ExError(message: "E486: Pattern not found: \(pattern)")
    }
    if countOnly {
      setMessage("\(substitutions) match\(substitutions == 1 ? "" : "es") on \(changedLines) line\(changedLines == 1 ? "" : "s")")
      return
    }
    let newBlock = output.joined(separator: "\n")
    replace(NSRange(location: start, length: end - start), with: newBlock)
    let lastLine = start + (lastChangedOffset ?? 0)
    setCursor(VimText.firstNonBlank(self.text, VimText.lineStart(self.text, min(lastLine, self.text.length))))
    if substitutions > 1 {
      setMessage("\(substitutions) substitutions on \(changedLines) line\(changedLines == 1 ? "" : "s")")
    }
  }

  // MARK: Line commands

  func moveOrCopyLines(_ range: ClosedRange<Int>, after target: Int, copy: Bool) throws {
    let text = self.text
    var lines = (text as String).components(separatedBy: "\n")
    let endsWithNewline = text.length > 0 && text.character(at: text.length - 1) == VimText.newline
    if endsWithNewline { lines.removeLast() }
    guard range.upperBound < lines.count else { return }
    let target = min(max(-1, target), lines.count - 1)
    if !copy, target >= range.lowerBound, target < range.upperBound {
      throw ExError(message: "E134: Cannot move a range of lines into itself")
    }
    let moved = Array(lines[range])
    if copy {
      let insertLine = target + 1
      let insertion = moved.joined(separator: "\n")
      if insertLine >= lines.count {
        replace(NSRange(location: text.length, length: 0), with: endsWithNewline ? insertion + "\n" : "\n" + insertion)
      } else {
        replace(NSRange(location: VimText.startOfLine(text, index: insertLine), length: 0), with: insertion + "\n")
      }
      setCursor(VimText.firstNonBlank(self.text, VimText.startOfLine(self.text, index: target + moved.count)))
      return
    }
    if target == range.upperBound || target == range.lowerBound - 1 { return }
    let regionStart = min(range.lowerBound, target + 1)
    let regionEnd = max(range.upperBound, target)
    var region = Array(lines[regionStart...regionEnd])
    let localStart = range.lowerBound - regionStart
    region.removeSubrange(localStart..<(localStart + moved.count))
    let insertIndex = target < range.lowerBound ? target + 1 - regionStart : target - regionStart - moved.count + 1
    region.insert(contentsOf: moved, at: insertIndex)
    let startOffset = VimText.startOfLine(text, index: regionStart)
    let endOffset = VimText.lineEnd(text, VimText.startOfLine(text, index: regionEnd))
    replace(NSRange(location: startOffset, length: endOffset - startOffset), with: region.joined(separator: "\n"))
    let lastMovedLine = regionStart + insertIndex + moved.count - 1
    setCursor(VimText.firstNonBlank(self.text, VimText.startOfLine(self.text, index: lastMovedLine)))
  }

  func global(range: ClosedRange<Int>, argument: String, invert: Bool) throws {
    guard let parsed = splitPattern(argument) else { throw ExError(message: "E476: Invalid command") }
    var pattern = parsed.pattern
    if pattern.isEmpty { pattern = lastSearch?.pattern ?? "" }
    guard let regex = VimPattern.regex(pattern, ignoreCase: ignoreCase, smartCase: smartCase) else {
      throw ExError(message: "E383: Invalid search string: \(pattern)")
    }
    // splitPattern treats everything after the second delimiter as the command.
    var command = parsed.replacement ?? ""
    if !parsed.flags.isEmpty { command += String(argument.drop(while: { $0 == " " }).first!) + parsed.flags }
    if command.trimmingCharacters(in: .whitespaces).isEmpty { command = "" }
    lastSearch = (pattern, true)
    let lines = (text as String).components(separatedBy: "\n")
    var targets: [Int] = []
    for index in range where index < lines.count {
      let line = lines[index]
      let matched = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
      if matched != invert { targets.append(index) }
    }
    guard !targets.isEmpty else {
      throw ExError(message: "E486: Pattern not found: \(pattern)")
    }
    if command.isEmpty {
      setMessage("\(targets.count) matching line\(targets.count == 1 ? "" : "s")")
      return
    }
    var shift = 0
    for target in targets {
      let line = target + shift
      let before = VimText.lineCount(text)
      guard line >= 0, line < before else { continue }
      setCursor(VimText.startOfLine(text, index: line))
      try runEx(command)
      if mode != .normal { reset() }
      shift += VimText.lineCount(text) - before
    }
  }

  func sortLines(_ range: ClosedRange<Int>, reverse: Bool, flags: String) {
    let text = self.text
    let start = VimText.startOfLine(text, index: range.lowerBound)
    let end = VimText.lineEnd(text, VimText.startOfLine(text, index: range.upperBound))
    var lines = text.substring(with: NSRange(location: start, length: end - start)).components(separatedBy: "\n")
    let ignore = flags.contains("i")
    if flags.contains("n") {
      func number(_ line: String) -> Double {
        guard let match = line.range(of: "-?\\d+(\\.\\d+)?", options: .regularExpression) else { return -.infinity }
        return Double(line[match]) ?? -.infinity
      }
      lines.sort { number($0) < number($1) }
    } else if ignore {
      lines.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    } else {
      lines.sort()
    }
    if reverse { lines.reverse() }
    if flags.contains("u") {
      var seen = Set<String>()
      lines = lines.filter { seen.insert(ignore ? $0.lowercased() : $0).inserted }
    }
    replace(NSRange(location: start, length: end - start), with: lines.joined(separator: "\n"))
    setCursor(start)
  }

  func applySetting(_ argument: String) throws {
    for option in argument.split(separator: " ") {
      let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
      let name = parts[0]
      switch name {
      case "ic", "ignorecase": ignoreCase = true
      case "noic", "noignorecase": ignoreCase = false
      case "scs", "smartcase": smartCase = true
      case "noscs", "nosmartcase": smartCase = false
      case "ws", "wrapscan": wrapScan = true
      case "nows", "nowrapscan": wrapScan = false
      case "et", "expandtab": expandTab = true
      case "noet", "noexpandtab": expandTab = false
      case "sw", "shiftwidth":
        guard parts.count == 2, let value = Int(parts[1]), value > 0 else { throw ExError(message: "E521: Number required after =") }
        shiftWidth = value
      case "clipboard", "cb":
        clipboardUnnamed = parts.count == 2 && (parts[1].contains("unnamed"))
      case "hls", "nohls", "hlsearch", "nohlsearch", "nu", "nonu", "number", "nonumber", "rnu", "nornu":
        setMessage("'\(name)' is managed by the editor")
      default:
        throw ExError(message: "E518: Unknown option: \(name)")
      }
    }
  }
}
