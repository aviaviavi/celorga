import Foundation

/// UTF-16 text helpers for the source editor's Vim mode.
///
/// Every helper works on the live `NSString` backing the editor and touches
/// only the lines a command needs, so motions stay fast in large files.
enum VimText {
  static let newline: unichar = 10
  static let space: unichar = 32
  static let tab: unichar = 9

  static func char(_ text: NSString, _ index: Int) -> unichar? {
    guard index >= 0, index < text.length else { return nil }
    return text.character(at: index)
  }

  static func isBlank(_ c: unichar) -> Bool {
    c == space || c == tab
  }

  static func isWhitespace(_ c: unichar) -> Bool {
    c == space || c == tab || c == newline || c == 13 || c == 0xA0 || c == 0x3000
  }

  /// Vim word classes: 0 blank, 1 punctuation, 2 keyword. WORD motions treat
  /// every non-blank as one class.
  static func wordClass(_ c: unichar, bigWord: Bool) -> Int {
    if isWhitespace(c) { return 0 }
    if bigWord { return 2 }
    if c == 95 { return 2 }
    if c < 128 {
      if (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) { return 2 }
      return 1
    }
    if UTF16.isLeadSurrogate(c) || UTF16.isTrailSurrogate(c) { return 2 }
    guard let scalar = UnicodeScalar(c) else { return 2 }
    if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
      return 1
    }
    return 2
  }

  static func wordClass(_ text: NSString, _ index: Int, bigWord: Bool) -> Int {
    guard let c = char(text, index) else { return 0 }
    return wordClass(c, bigWord: bigWord)
  }

  // MARK: Lines

  static func lineStart(_ text: NSString, _ location: Int) -> Int {
    let location = min(max(0, location), text.length)
    guard location > 0 else { return 0 }
    let found = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: location))
    return found.location == NSNotFound ? 0 : found.location + 1
  }

  /// The index of the line's newline, or the text length on the last line.
  static func lineEnd(_ text: NSString, _ location: Int) -> Int {
    let location = min(max(0, location), text.length)
    guard location < text.length else { return text.length }
    let found = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
    return found.location == NSNotFound ? text.length : found.location
  }

  /// The start of the next line, or the text length on the last line.
  static func lineEndIncludingNewline(_ text: NSString, _ location: Int) -> Int {
    let end = lineEnd(text, location)
    return end < text.length ? end + 1 : end
  }

  static func isEmptyLine(_ text: NSString, _ location: Int) -> Bool {
    lineStart(text, location) == lineEnd(text, location)
  }

  /// The last position a Normal-mode cursor may occupy on the line.
  static func lastCharPosition(_ text: NSString, _ location: Int) -> Int {
    let start = lineStart(text, location)
    let end = lineEnd(text, location)
    guard end > start else { return start }
    return text.rangeOfComposedCharacterSequence(at: end - 1).location
  }

  static func firstNonBlank(_ text: NSString, _ location: Int) -> Int {
    var index = lineStart(text, location)
    let end = lineEnd(text, location)
    while index < end, let c = char(text, index), isBlank(c) {
      index += 1
    }
    return index
  }

  /// The start of the next line. A file's final newline terminates its last
  /// line rather than starting an empty one, as in Vim.
  static func nextLineStart(_ text: NSString, _ location: Int) -> Int? {
    let end = lineEnd(text, location)
    return end + 1 < text.length ? end + 1 : nil
  }

  static func previousLineStart(_ text: NSString, _ location: Int) -> Int? {
    let start = lineStart(text, location)
    return start > 0 ? lineStart(text, start - 1) : nil
  }

  /// Zero-based line number of a location.
  static func lineIndex(_ text: NSString, _ location: Int) -> Int {
    let location = min(max(0, location), text.length)
    var count = 0
    var search = NSRange(location: 0, length: location)
    while search.length > 0 {
      let found = text.range(of: "\n", options: [], range: search)
      if found.location == NSNotFound { break }
      count += 1
      let next = found.location + 1
      search = NSRange(location: next, length: location - next)
    }
    return count
  }

  static func lineCount(_ text: NSString) -> Int {
    let endsWithNewline = text.length > 0 && text.character(at: text.length - 1) == newline
    return lineIndex(text, text.length) + (endsWithNewline ? 0 : 1)
  }

  /// The start of the last line, ignoring the empty position after a final newline.
  static func lastLineStart(_ text: NSString) -> Int {
    let endsWithNewline = text.length > 0 && text.character(at: text.length - 1) == newline
    return lineStart(text, endsWithNewline ? text.length - 1 : text.length)
  }

  /// The start of a zero-based line, clamped to the last line.
  static func startOfLine(_ text: NSString, index: Int) -> Int {
    var start = 0
    var remaining = max(0, index)
    while remaining > 0, let next = nextLineStart(text, start) {
      start = next
      remaining -= 1
    }
    return start
  }

  /// Moves a location by whole lines while keeping a desired column.
  static func position(_ text: NSString, lineStart: Int, column: Int, allowLineEnd: Bool = false) -> Int {
    let end = lineEnd(text, lineStart)
    if column == Int.max {
      return allowLineEnd ? end : lastCharPosition(text, lineStart)
    }
    let maxPosition = allowLineEnd ? end : lastCharPosition(text, lineStart)
    let target = min(lineStart + max(0, column), maxPosition)
    guard target < text.length, target > lineStart else { return target }
    return text.rangeOfComposedCharacterSequence(at: target).location
  }

  // MARK: Characters

  static func nextPosition(_ text: NSString, _ location: Int) -> Int {
    guard location < text.length else { return text.length }
    let range = text.rangeOfComposedCharacterSequence(at: location)
    return range.location + range.length
  }

  static func previousPosition(_ text: NSString, _ location: Int) -> Int {
    guard location > 0 else { return 0 }
    return text.rangeOfComposedCharacterSequence(at: min(location, text.length) - 1).location
  }

  /// Clamps a location for Normal mode: never past the last character of a
  /// non-empty line.
  static func clampNormal(_ text: NSString, _ location: Int) -> Int {
    let location = min(max(0, location), text.length)
    let end = lineEnd(text, location)
    let start = lineStart(text, location)
    if location >= end && end > start {
      return lastCharPosition(text, location)
    }
    guard location < text.length else { return location }
    return text.rangeOfComposedCharacterSequence(at: location).location
  }

  // MARK: Words

  static func wordForward(_ text: NSString, from location: Int, bigWord: Bool) -> Int {
    let length = text.length
    var index = location
    guard index < length else { return length }
    let startClass = wordClass(text, index, bigWord: bigWord)
    if startClass != 0 {
      while index < length, wordClass(text, index, bigWord: bigWord) == startClass {
        index += 1
      }
    }
    while index < length {
      let c = text.character(at: index)
      if c == newline {
        index += 1
        if index < length, text.character(at: index) == newline {
          return index
        }
        continue
      }
      if wordClass(c, bigWord: bigWord) != 0 {
        return index
      }
      index += 1
    }
    return length
  }

  static func wordEnd(_ text: NSString, from location: Int, bigWord: Bool) -> Int {
    let length = text.length
    var index = location + 1
    while index < length, wordClass(text, index, bigWord: bigWord) == 0 {
      index += 1
    }
    guard index < length else { return max(0, length - 1) }
    let currentClass = wordClass(text, index, bigWord: bigWord)
    while index + 1 < length, wordClass(text, index + 1, bigWord: bigWord) == currentClass {
      index += 1
    }
    return index
  }

  static func isEmptyLineStart(_ text: NSString, _ index: Int) -> Bool {
    guard let c = char(text, index), c == newline else {
      return index == text.length && index > 0 && char(text, index - 1) == newline
    }
    return index == 0 || char(text, index - 1) == newline
  }

  static func wordBackward(_ text: NSString, from location: Int, bigWord: Bool) -> Int {
    var index = location - 1
    guard index >= 0 else { return 0 }
    while index > 0, wordClass(text, index, bigWord: bigWord) == 0 {
      if isEmptyLineStart(text, index) {
        return index
      }
      index -= 1
    }
    let currentClass = wordClass(text, index, bigWord: bigWord)
    if currentClass == 0 { return index }
    while index > 0, wordClass(text, index - 1, bigWord: bigWord) == currentClass {
      index -= 1
    }
    return index
  }

  static func wordEndBackward(_ text: NSString, from location: Int, bigWord: Bool) -> Int {
    var index = location
    let startClass = wordClass(text, index, bigWord: bigWord)
    if startClass != 0 {
      while index > 0, wordClass(text, index - 1, bigWord: bigWord) == startClass {
        index -= 1
      }
    }
    index -= 1
    while index > 0, wordClass(text, index, bigWord: bigWord) == 0 {
      if isEmptyLineStart(text, index) {
        return index
      }
      index -= 1
    }
    return max(0, index)
  }

  // MARK: Paragraphs and sentences

  static func paragraphForward(_ text: NSString, from location: Int) -> Int {
    var start = lineStart(text, location)
    // Skip blank lines first, then find the next blank line in one search.
    while isEmptyLine(text, start), let next = nextLineStart(text, start) {
      start = next
    }
    let found = text.range(of: "\n\n", options: .literal, range: NSRange(location: start, length: text.length - start))
    return found.location == NSNotFound ? text.length : found.location + 1
  }

  static func paragraphBackward(_ text: NSString, from location: Int) -> Int {
    var start = lineStart(text, location)
    while isEmptyLine(text, start), let previous = previousLineStart(text, start) {
      start = previous
    }
    guard start > 0 else { return 0 }
    let found = text.range(of: "\n\n", options: [.literal, .backwards], range: NSRange(location: 0, length: start))
    return found.location == NSNotFound ? 0 : found.location + 1
  }

  static func isSentenceEnd(_ text: NSString, _ index: Int) -> Bool {
    guard let c = char(text, index), c == 46 || c == 33 || c == 63 else { return false }
    var next = index + 1
    while let n = char(text, next), n == 41 || n == 93 || n == 34 || n == 39 {
      next += 1
    }
    guard let after = char(text, next) else { return true }
    return isWhitespace(after)
  }

  static func sentenceForward(_ text: NSString, from location: Int) -> Int {
    let length = text.length
    var index = location
    while index < length {
      let c = text.character(at: index)
      if c == newline, isEmptyLineStart(text, index), index != location {
        return index
      }
      if isSentenceEnd(text, index) {
        var next = index + 1
        while next < length, let n = char(text, next), !isWhitespace(n) { next += 1 }
        while next < length, let n = char(text, next), isWhitespace(n) {
          if n == newline, isEmptyLineStart(text, next) { return next }
          next += 1
        }
        return min(next, length)
      }
      index += 1
    }
    return length
  }

  static func sentenceBackward(_ text: NSString, from location: Int) -> Int {
    var index = location - 1
    // Step over whitespace and the previous sentence's terminator.
    while index > 0, let c = char(text, index), isWhitespace(c) {
      if isEmptyLineStart(text, index) && index != location - 1 { return index }
      index -= 1
    }
    while index > 0 {
      if isEmptyLineStart(text, index - 1) {
        return index
      }
      if isSentenceEnd(text, index - 1) {
        var start = index
        while let c = char(text, start), isWhitespace(c) { start += 1 }
        if start < location { return start }
      }
      index -= 1
    }
    return 0
  }

  // MARK: Brackets

  static let openBrackets: [unichar: unichar] = [40: 41, 91: 93, 123: 125, 60: 62]
  static let closeBrackets: [unichar: unichar] = [41: 40, 93: 91, 125: 123, 62: 60]

  static func matchingBracket(_ text: NSString, from location: Int) -> Int? {
    let end = lineEnd(text, location)
    var index = location
    while index < end {
      let c = text.character(at: index)
      if c != 60 && c != 62, openBrackets[c] != nil || closeBrackets[c] != nil {
        break
      }
      index += 1
    }
    guard index < end else { return nil }
    let c = text.character(at: index)
    if let close = openBrackets[c] {
      return scanForward(text, from: index + 1, open: c, close: close)
    }
    if let open = closeBrackets[c] {
      return scanBackward(text, from: index - 1, open: open, close: c)
    }
    return nil
  }

  static func scanForward(_ text: NSString, from location: Int, open: unichar, close: unichar) -> Int? {
    var depth = 0
    var index = location
    while index < text.length {
      let c = text.character(at: index)
      if c == open { depth += 1 }
      if c == close {
        if depth == 0 { return index }
        depth -= 1
      }
      index += 1
    }
    return nil
  }

  static func scanBackward(_ text: NSString, from location: Int, open: unichar, close: unichar) -> Int? {
    var depth = 0
    var index = location
    while index >= 0 {
      let c = text.character(at: index)
      if c == close { depth += 1 }
      if c == open {
        if depth == 0 { return index }
        depth -= 1
      }
      index -= 1
    }
    return nil
  }

  // MARK: Text objects

  static func wordObject(_ text: NSString, at location: Int, count: Int, around: Bool, bigWord: Bool) -> NSRange? {
    let length = text.length
    guard length > 0 else { return nil }
    let location = min(location, length - 1)
    let lineStartIndex = lineStart(text, location)
    let lineEndIndex = lineEnd(text, location)
    var start = location
    var end = location
    func cls(_ i: Int) -> Int {
      guard let c = char(text, i), c != newline else { return -1 }
      return wordClass(c, bigWord: bigWord)
    }
    let startClass = cls(location)
    if startClass == -1 { return NSRange(location: location, length: 0) }
    while start > lineStartIndex, cls(start - 1) == startClass { start -= 1 }
    while end + 1 < lineEndIndex, cls(end + 1) == startClass { end += 1 }
    var remaining = count - 1
    var includedTrailingSpace = false
    if around {
      if startClass == 0 {
        // "aw" on blanks: the blanks plus the following word.
        if end + 1 < length, cls(end + 1) > 0 {
          let nextClass = cls(end + 1)
          end += 1
          while end + 1 < lineEndIndex, cls(end + 1) == nextClass { end += 1 }
        }
      } else if end + 1 < lineEndIndex, cls(end + 1) == 0 {
        while end + 1 < lineEndIndex, cls(end + 1) == 0 { end += 1 }
        includedTrailingSpace = true
      } else {
        while start > lineStartIndex, cls(start - 1) == 0 { start -= 1 }
      }
    }
    while remaining > 0 {
      var next = end + 1
      if next >= lineEndIndex { break }
      let nextClass = cls(next)
      while next + 1 < lineEndIndex, cls(next + 1) == nextClass { next += 1 }
      end = next
      if around && nextClass != 0 && !includedTrailingSpace {
        while end + 1 < lineEndIndex, cls(end + 1) == 0 { end += 1 }
      } else if around && nextClass == 0, end + 1 < lineEndIndex {
        let wordClass = cls(end + 1)
        end += 1
        while end + 1 < lineEndIndex, cls(end + 1) == wordClass { end += 1 }
      }
      remaining -= 1
    }
    return NSRange(location: start, length: nextPosition(text, end) - start)
  }

  static func quoteObject(_ text: NSString, at location: Int, quote: unichar, around: Bool) -> NSRange? {
    let start = lineStart(text, location)
    let end = lineEnd(text, location)
    var quotes: [Int] = []
    var index = start
    while index < end {
      let c = text.character(at: index)
      if c == 92 { index += 2; continue }
      if c == quote { quotes.append(index) }
      index += 1
    }
    guard quotes.count >= 2 else { return nil }
    var pair: (Int, Int)?
    var i = 0
    while i + 1 < quotes.count {
      let open = quotes[i], close = quotes[i + 1]
      if location >= open && location <= close { pair = (open, close); break }
      if location < open { pair = (open, close); break }
      i += 2
    }
    guard let (open, close) = pair else { return nil }
    if around {
      var aroundEnd = close + 1
      while aroundEnd < end, isBlank(text.character(at: aroundEnd)) { aroundEnd += 1 }
      var aroundStart = open
      if aroundEnd == close + 1 {
        while aroundStart > start, isBlank(text.character(at: aroundStart - 1)) { aroundStart -= 1 }
      }
      return NSRange(location: aroundStart, length: aroundEnd - aroundStart)
    }
    return NSRange(location: open + 1, length: close - open - 1)
  }

  static func bracketObject(_ text: NSString, at location: Int, open: unichar, close: unichar, around: Bool, count: Int) -> NSRange? {
    var searchFrom = location
    var openIndex: Int?
    var closeIndex: Int?
    for _ in 0..<max(1, count) {
      let c = char(text, searchFrom)
      let foundOpen: Int?
      if c == open, openIndex == nil {
        foundOpen = searchFrom
      } else if c == close, openIndex == nil {
        foundOpen = scanBackward(text, from: searchFrom - 1, open: open, close: close)
      } else {
        foundOpen = scanBackward(text, from: searchFrom - 1, open: open, close: close)
      }
      guard let foundOpen,
            let foundClose = scanForward(text, from: foundOpen + 1, open: open, close: close)
      else { return nil }
      openIndex = foundOpen
      closeIndex = foundClose
      searchFrom = foundOpen
    }
    guard let openIndex, let closeIndex else { return nil }
    if around {
      return NSRange(location: openIndex, length: closeIndex - openIndex + 1)
    }
    var innerStart = openIndex + 1
    var innerEnd = closeIndex
    // "i{" on a block spanning lines excludes the bracket lines' newlines.
    if char(text, innerStart) == newline { innerStart += 1 }
    if innerEnd > innerStart {
      let closeLineStart = lineStart(text, innerEnd)
      if closeLineStart > innerStart, firstNonBlank(text, closeLineStart) == innerEnd {
        innerEnd = closeLineStart
      }
    }
    return NSRange(location: innerStart, length: max(0, innerEnd - innerStart))
  }

  static func paragraphObject(_ text: NSString, at location: Int, around: Bool, count: Int) -> NSRange {
    var start = lineStart(text, location)
    let blank = isEmptyLine(text, start)
    while let previous = previousLineStart(text, start), isEmptyLine(text, previous) == blank {
      start = previous
    }
    var end = lineEndIncludingNewline(text, location)
    var groups = 1
    var currentBlank = blank
    while true {
      while end < text.length, isEmptyLine(text, end) == currentBlank {
        end = lineEndIncludingNewline(text, end)
      }
      if groups >= count * (around ? 2 : 1) || end >= text.length { break }
      currentBlank.toggle()
      groups += 1
      end = lineEndIncludingNewline(text, end)
    }
    if around, groups < 2, !blank {
      while let previous = previousLineStart(text, start), isEmptyLine(text, previous) {
        start = previous
      }
    }
    return NSRange(location: start, length: end - start)
  }

  static func sentenceObject(_ text: NSString, at location: Int, around: Bool) -> NSRange {
    var start = sentenceBackward(text, from: location + 1)
    if start > location { start = sentenceBackward(text, from: location) }
    var end = sentenceForward(text, from: location)
    if !around {
      while end > start, let c = char(text, end - 1), isWhitespace(c) { end -= 1 }
    }
    return NSRange(location: start, length: max(0, end - start))
  }

  static func tagObject(_ text: NSString, at location: Int, around: Bool) -> NSRange? {
    let pattern = try? NSRegularExpression(pattern: "<(/?)([A-Za-z][\\w:.-]*)[^<>]*?(/?)>")
    guard let pattern else { return nil }
    var stack: [(name: String, range: NSRange)] = []
    var best: NSRange?
    pattern.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
      guard let match else { return }
      let isClosing = match.range(at: 1).length > 0
      let selfClosing = match.range(at: 3).length > 0
      let name = text.substring(with: match.range(at: 2))
      if selfClosing { return }
      if !isClosing {
        stack.append((name, match.range))
        return
      }
      guard let openIndex = stack.lastIndex(where: { $0.name == name }) else { return }
      let open = stack[openIndex].range
      stack.removeSubrange(openIndex...)
      let outer = NSRange(location: open.location, length: match.range.location + match.range.length - open.location)
      guard location >= outer.location, location < outer.location + outer.length else { return }
      let candidate = around
        ? outer
        : NSRange(location: open.location + open.length, length: match.range.location - open.location - open.length)
      if best == nil || candidate.length < best!.length { best = candidate }
    }
    return best
  }
}

/// Translates Vim regular expressions to ICU patterns for NSRegularExpression.
enum VimPattern {
  struct Compiled {
    let regex: NSRegularExpression
  }

  static func translate(_ pattern: String, ignoreCase: Bool, smartCase: Bool) -> (String, Bool) {
    var output = ""
    var caseOverride: Bool?
    var veryMagic = false
    let characters = Array(pattern)
    var index = 0
    while index < characters.count {
      let c = characters[index]
      if c == "\\", index + 1 < characters.count {
        let next = characters[index + 1]
        index += 2
        switch next {
        case "c": caseOverride = true
        case "C": caseOverride = false
        case "v": veryMagic = true
        case "m", "M", "V": veryMagic = false
        case "<", ">": output += "\\b"
        case "(", ")", "|", "{", "}", "+", "?", "=":
          if veryMagic {
            output += "\\\(next)"
          } else {
            output += next == "=" ? "?" : String(next)
          }
        case "a": output += "[A-Za-z]"
        case "A": output += "[^A-Za-z]"
        case "l": output += "[a-z]"
        case "L": output += "[^a-z]"
        case "u": output += "[A-Z]"
        case "U": output += "[^A-Z]"
        case "x": output += "[0-9A-Fa-f]"
        case "X": output += "[^0-9A-Fa-f]"
        case "h": output += "[A-Za-z_]"
        case "o": output += "[0-7]"
        case "e": output += "\\x1b"
        case "/": output += "/"
        case "n": output += "\\n"
        case "t": output += "\\t"
        case "r": output += "\\r"
        default: output += "\\\(next)"
        }
        continue
      }
      if veryMagic {
        switch c {
        case "<", ">": output += "\\b"
        case "=": output += "?"
        default: output.append(c)
        }
      } else {
        switch c {
        case "(", ")", "{", "}", "+", "?", "|": output += "\\\(c)"
        default: output.append(c)
        }
      }
      index += 1
    }
    var insensitive = ignoreCase
    if ignoreCase && smartCase && pattern.contains(where: { $0.isUppercase }) {
      insensitive = false
    }
    if let caseOverride { insensitive = caseOverride }
    return (output, insensitive)
  }

  static func regex(_ pattern: String, ignoreCase: Bool, smartCase: Bool) -> NSRegularExpression? {
    let (translated, insensitive) = translate(pattern, ignoreCase: ignoreCase, smartCase: smartCase)
    var options: NSRegularExpression.Options = [.anchorsMatchLines]
    if insensitive { options.insert(.caseInsensitive) }
    return try? NSRegularExpression(pattern: translated, options: options)
  }

  /// Escapes a literal for use inside a Vim (magic) pattern.
  static func escapeLiteral(_ text: String) -> String {
    var output = ""
    for c in text {
      if "\\.*[]~^$/".contains(c) { output.append("\\") }
      output.append(c)
    }
    return output
  }

  /// Converts a Vim substitute replacement into an NSRegularExpression template.
  static func template(_ replacement: String) -> String {
    var output = ""
    let characters = Array(replacement)
    var index = 0
    while index < characters.count {
      let c = characters[index]
      if c == "\\", index + 1 < characters.count {
        let next = characters[index + 1]
        index += 2
        switch next {
        case "0"..."9": output += "$\(next)"
        case "n", "r": output += "\n"
        case "t": output += "\t"
        case "&": output += "&"
        case "\\": output += "\\\\"
        case "$": output += "\\$"
        default: output.append(next)
        }
        continue
      }
      switch c {
      case "&": output += "$0"
      case "$": output += "\\$"
      default: output.append(c)
      }
      index += 1
    }
    return output
  }
}
