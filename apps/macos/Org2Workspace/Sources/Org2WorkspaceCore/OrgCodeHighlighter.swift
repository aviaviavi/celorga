import AppKit
import Foundation

/// The shared language table generated from `src/codeHighlight.ts`
/// (`node tools/generate-code-languages.mjs`), so the native source editor
/// highlights code, markup, config, and data files with the same vocabulary as
/// the rendered view.
struct OrgCodeLanguageTable: Decodable, Sendable {
  struct Rule: Decodable, Sendable {
    let pattern: String
    let kind: String
  }

  struct Language: Decodable, Sendable {
    let lineComments: [String]?
    let blockComments: [[String]]?
    let strings: [String]?
    let multilineStrings: [String]?
    let rawStrings: [String]?
    let keywords: [String]?
    let literals: [String]?
    let types: [String]?
    let caseInsensitive: Bool?
    let capitalizedTypes: Bool?
    let decorators: Bool?
    let shellVariables: Bool?
    let keysBeforeColon: Bool?
    let preprocessor: Bool?
    let markup: Bool?
    let plainWords: Bool?
    let identifierChars: String?
    let lineRules: [Rule]?
    let inlineRules: [Rule]?
  }

  let schema: String
  let languages: [String: Language]
  let aliases: [String: String]
  let filenames: [String: String]
}

public enum OrgCodeTokenKind: String, Sendable, CaseIterable {
  case comment, string, keyword, number, literal, type, function, property, meta, tag, attr, variable
}

public struct OrgCodeToken: Equatable, Sendable {
  public let kind: OrgCodeTokenKind
  public let range: NSRange
}

/// A language definition with lookups precomputed for tokenizing.
final class OrgCompiledCodeLanguage: @unchecked Sendable {
  let lineComments: [[UInt16]]
  let blockComments: [([UInt16], [UInt16])]
  let strings: [[UInt16]]
  let multiline: Set<[UInt16]>
  let raw: Set<[UInt16]>
  let keywords: Set<String>
  let literals: Set<String>
  let types: Set<String>
  let caseInsensitive: Bool
  let capitalizedTypes: Bool
  let decorators: Bool
  let shellVariables: Bool
  let keysBeforeColon: Bool
  let preprocessor: Bool
  let markup: Bool
  let plainWords: Bool
  let identifierChars: [Bool]
  let lineRules: [(NSRegularExpression, OrgCodeTokenKind)]
  let inlineRules: [(NSRegularExpression, OrgCodeTokenKind)]

  init(_ language: OrgCodeLanguageTable.Language) {
    func units(_ value: String) -> [UInt16] { Array(value.utf16) }
    lineComments = (language.lineComments ?? []).map(units)
    blockComments = (language.blockComments ?? []).compactMap { pair in
      pair.count == 2 ? (units(pair[0]), units(pair[1])) : nil
    }
    strings = (language.strings ?? []).map(units).sorted { $0.count > $1.count }
    multiline = Set((language.multilineStrings ?? []).map(units))
    raw = Set((language.rawStrings ?? []).map(units))
    caseInsensitive = language.caseInsensitive == true
    let fold: (String) -> String = { [caseInsensitive = language.caseInsensitive == true] in caseInsensitive ? $0.lowercased() : $0 }
    keywords = Set((language.keywords ?? []).map(fold))
    literals = Set((language.literals ?? []).map(fold))
    types = Set((language.types ?? []).map(fold))
    capitalizedTypes = language.capitalizedTypes == true
    decorators = language.decorators == true
    shellVariables = language.shellVariables == true
    keysBeforeColon = language.keysBeforeColon == true
    preprocessor = language.preprocessor == true
    markup = language.markup == true
    plainWords = language.plainWords == true
    var chars = [Bool](repeating: false, count: 128)
    if let pattern = language.identifierChars, let regex = try? NSRegularExpression(pattern: pattern) {
      for code in 0..<128 {
        let string = String(UnicodeScalar(UInt8(code)))
        chars[code] = regex.firstMatch(in: string, range: NSRange(location: 0, length: 1)) != nil
      }
    } else {
      for code in 0..<128 {
        let scalar = UInt8(code)
        chars[code] = (scalar >= 48 && scalar <= 57) || (scalar >= 65 && scalar <= 90) || (scalar >= 97 && scalar <= 122) || scalar == 95 || scalar == 36
      }
    }
    identifierChars = chars
    func compile(_ rules: [OrgCodeLanguageTable.Rule]?) -> [(NSRegularExpression, OrgCodeTokenKind)] {
      (rules ?? []).compactMap { rule in
        guard let kind = OrgCodeTokenKind(rawValue: rule.kind),
              let regex = try? NSRegularExpression(pattern: rule.pattern)
        else { return nil }
        return (regex, kind)
      }
    }
    lineRules = compile(language.lineRules)
    inlineRules = compile(language.inlineRules)
  }
}

public enum OrgCodeHighlighter {
  /// Larger files are shown with base attributes only.
  public static let tokenizationUTF16Limit = 400_000

  static let table: OrgCodeLanguageTable? = {
    guard let url = WorkspaceResources.url(forResource: "CodeLanguages", withExtension: "json"),
          let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(OrgCodeLanguageTable.self, from: data)
  }()

  private static let compiledLock = NSLock()
  nonisolated(unsafe) private static var compiled: [String: OrgCompiledCodeLanguage] = [:]

  static func compiledLanguage(_ name: String) -> OrgCompiledCodeLanguage? {
    compiledLock.lock()
    defer { compiledLock.unlock() }
    if let existing = compiled[name] { return existing }
    guard let language = table?.languages[name] else { return nil }
    let value = OrgCompiledCodeLanguage(language)
    compiled[name] = value
    return value
  }

  /// Canonical language for a source-block language or alias.
  public static func normalizedLanguage(_ raw: String?) -> String? {
    let key = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !key.isEmpty, let table else { return nil }
    if let alias = table.aliases[key] { return alias }
    return table.languages[key] != nil ? key : nil
  }

  /// The language for editing `path` as highlighted source, or nil for Org
  /// documents and unknown files. Mirrors `sourceLanguageForPath`.
  public static func language(forPath path: String?) -> String? {
    guard let path, let table else { return nil }
    let base = (path as NSString).lastPathComponent.lowercased()
    guard !base.isEmpty else { return nil }
    let ext = (base as NSString).pathExtension
    if ["org", "org2"].contains(ext) { return nil }
    if ["md", "markdown", "mdx", "mkd", "rmd", "qmd"].contains(ext) { return "markdown" }
    if base == "dockerfile" || base.hasPrefix("dockerfile.") || base == "containerfile" { return "dockerfile" }
    if ["makefile", "gnumakefile", "justfile", ".justfile"].contains(base) { return "makefile" }
    if [".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".envrc", ".bash_aliases", ".zshenv", ".zlogin", "pkgbuild", "apkbuild"].contains(base)
      || base == ".env" || base.hasPrefix(".env.") {
      return "shell"
    }
    if let byName = table.filenames[base] { return byName }
    guard let dot = base.lastIndex(of: "."), dot != base.startIndex, base.index(after: dot) != base.endIndex else { return nil }
    if ["csv", "tsv", "canvas", "pdf"].contains(ext) { return nil }
    let language = table.aliases[ext]
    return language == "plaintext" ? nil : language
  }

  // MARK: Tokenizing

  public static func tokens(in text: String, language: String) -> [OrgCodeToken] {
    tokens(in: text as NSString, language: language)
  }

  public static func tokens(in text: NSString, language: String) -> [OrgCodeToken] {
    guard let canonical = normalizedLanguage(language), canonical != "plaintext",
          let spec = compiledLanguage(canonical),
          text.length <= tokenizationUTF16Limit
    else { return [] }
    // An immutable copy bridges to String without copying again for each
    // regular-expression probe.
    let immutable = (text.copy() as? NSString) ?? text
    var buffer = [UInt16](repeating: 0, count: immutable.length)
    immutable.getCharacters(&buffer, range: NSRange(location: 0, length: immutable.length))
    return spec.markup ? markupTokens(buffer) : specTokens(buffer, text: immutable as String, spec: spec)
  }

  private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
  private static func isAlpha(_ unit: UInt16) -> Bool { (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) }
  private static func isIdentStart(_ unit: UInt16) -> Bool { isAlpha(unit) || unit == 95 || unit == 36 }
  private static func isWordChar(_ unit: UInt16) -> Bool { isAlpha(unit) || isDigit(unit) || unit == 95 }

  private static let numberRegex = try! NSRegularExpression(
    pattern: #"(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|(?:\d[\d_]*)?\.?\d[\d_]*(?:[eE][+-]?\d+)?)[A-Za-z%]*"#
  )

  private static func starts(_ buffer: [UInt16], _ needle: [UInt16], at index: Int) -> Bool {
    guard !needle.isEmpty, index + needle.count <= buffer.count else { return false }
    for offset in 0..<needle.count where buffer[index + offset] != needle[offset] { return false }
    return true
  }

  private static func find(_ buffer: [UInt16], _ needle: [UInt16], from index: Int) -> Int? {
    guard !needle.isEmpty else { return nil }
    var cursor = index
    while cursor + needle.count <= buffer.count {
      if buffer[cursor] == needle[0], starts(buffer, needle, at: cursor) { return cursor }
      cursor += 1
    }
    return nil
  }

  private static func lineEnd(_ buffer: [UInt16], from index: Int) -> Int {
    var cursor = index
    while cursor < buffer.count, buffer[cursor] != 10 { cursor += 1 }
    return cursor
  }

  private static func specTokens(_ buffer: [UInt16], text: String, spec: OrgCompiledCodeLanguage) -> [OrgCodeToken] {
    var tokens: [OrgCodeToken] = []
    func push(_ start: Int, _ end: Int, _ kind: OrgCodeTokenKind?) {
      guard let kind, end > start else { return }
      if let last = tokens.last, last.kind == kind, NSMaxRange(last.range) == start {
        tokens[tokens.count - 1] = OrgCodeToken(kind: kind, range: NSRange(location: last.range.location, length: end - last.range.location))
      } else {
        tokens.append(OrgCodeToken(kind: kind, range: NSRange(location: start, length: end - start)))
      }
    }
    func identChar(_ unit: UInt16) -> Bool { unit < 128 && spec.identifierChars[Int(unit)] }
    func fold(_ value: String) -> String { spec.caseInsensitive ? value.lowercased() : value }
    let length = buffer.count
    var lineStart = true
    var i = 0

    func nextNonSpace(_ from: Int) -> UInt16? {
      var j = from
      while j < length, buffer[j] == 32 || buffer[j] == 9 { j += 1 }
      return j < length ? buffer[j] : nil
    }
    func isKeyColon(_ from: Int) -> Bool {
      var j = from
      while j < length, buffer[j] == 32 || buffer[j] == 9 { j += 1 }
      return j < length && buffer[j] == 58 && !(j + 1 < length && buffer[j + 1] == 58)
    }

    while i < length {
      let ch = buffer[i]
      if ch == 10 { lineStart = true; i += 1; continue }
      if ch == 32 || ch == 9 || ch == 13 { i += 1; continue }
      let atLineStart = lineStart
      lineStart = false

      if atLineStart, !spec.lineRules.isEmpty {
        let end = lineEnd(buffer, from: i)
        let range = NSRange(location: i, length: end - i)
        var matched = false
        for (regex, kind) in spec.lineRules {
          if let match = regex.firstMatch(in: text, options: [.anchored], range: range), match.range.length > 0 {
            push(i, NSMaxRange(match.range), kind)
            i = NSMaxRange(match.range)
            matched = true
            break
          }
        }
        if matched { continue }
      }
      if !spec.inlineRules.isEmpty {
        let end = lineEnd(buffer, from: i)
        let range = NSRange(location: i, length: end - i)
        var matched = false
        for (regex, kind) in spec.inlineRules {
          if let match = regex.firstMatch(in: text, options: [.anchored], range: range), match.range.length > 0 {
            push(i, NSMaxRange(match.range), kind)
            i = NSMaxRange(match.range)
            matched = true
            break
          }
        }
        if matched { continue }
      }

      if let block = spec.blockComments.first(where: { starts(buffer, $0.0, at: i) }) {
        let stop = find(buffer, block.1, from: i + block.0.count).map { $0 + block.1.count } ?? length
        push(i, stop, .comment)
        i = stop
        continue
      }
      if spec.lineComments.contains(where: { marker in
        starts(buffer, marker, at: i) && !(marker == [35] && spec.shellVariables && i > 0 && buffer[i - 1] == 36)
      }) {
        let stop = lineEnd(buffer, from: i)
        push(i, stop, .comment)
        i = stop
        continue
      }
      if spec.preprocessor, atLineStart, ch == 35 {
        let stop = lineEnd(buffer, from: i)
        push(i, stop, .meta)
        i = stop
        continue
      }

      if let delimiter = spec.strings.first(where: { starts(buffer, $0, at: i) }) {
        let allowsNewline = spec.multiline.contains(delimiter)
        let escapes = !spec.raw.contains(delimiter)
        var j = i + delimiter.count
        while j < length {
          if escapes, buffer[j] == 92 { j += 2; continue }
          if starts(buffer, delimiter, at: j) { j += delimiter.count; break }
          if buffer[j] == 10, !allowsNewline { break }
          j += 1
        }
        let stop = min(j, length)
        push(i, stop, spec.keysBeforeColon && isKeyColon(stop) ? .property : .string)
        i = stop
        continue
      }

      if spec.shellVariables, ch == 36 {
        if i + 1 < length, buffer[i + 1] == 123 {
          var close = i + 2
          while close < length, buffer[close] != 125, buffer[close] != 10 { close += 1 }
          if close < length, buffer[close] == 125 {
            push(i, close + 1, .variable)
            i = close + 1
          } else {
            i += 1
          }
          continue
        }
        var j = i + 1
        while j < length {
          let unit = buffer[j]
          let allowed = j == i + 1
            ? (isWordChar(unit) || [64, 35, 63, 42, 33, 36, 45].contains(unit))
            : isWordChar(unit)
          if !allowed { break }
          j += 1
        }
        if j > i + 1 { push(i, j, .variable) }
        i = max(j, i + 1)
        continue
      }

      if spec.decorators, ch == 64, i + 1 < length, isIdentStart(buffer[i + 1]) {
        var j = i + 1
        while j < length, isWordChar(buffer[j]) || buffer[j] == 46 { j += 1 }
        push(i, j, .meta)
        i = j
        continue
      }

      if spec.plainWords {
        var j = i + 1
        while j < length, isWordChar(buffer[j - 1]), isWordChar(buffer[j]) { j += 1 }
        i = j
        continue
      }

      let previous: UInt16 = i > 0 ? buffer[i - 1] : 0
      if isDigit(ch) || (ch == 46 && i + 1 < length && isDigit(buffer[i + 1]) && !identChar(previous)) {
        if !identChar(previous) {
          let range = NSRange(location: i, length: min(64, length - i))
          if let match = numberRegex.firstMatch(in: text, options: [.anchored], range: range), match.range.length > 0 {
            push(i, NSMaxRange(match.range), .number)
            i = NSMaxRange(match.range)
            continue
          }
        }
      }

      if isIdentStart(ch) {
        var j = i + 1
        while j < length, identChar(buffer[j]) { j += 1 }
        var word = String(utf16CodeUnits: Array(buffer[i..<j]), count: j - i)
        if j < length, buffer[j] == 63, spec.keywords.contains(fold(word + "?")) {
          j += 1
          word += "?"
        }
        let key = fold(word)
        var kind: OrgCodeTokenKind?
        if spec.keysBeforeColon && isKeyColon(j) { kind = .property }
        else if spec.keywords.contains(key) { kind = .keyword }
        else if spec.literals.contains(key) { kind = .literal }
        else if spec.types.contains(key) { kind = .type }
        else if spec.capitalizedTypes, isCapitalizedType(word) { kind = .type }
        else if nextNonSpace(j) == 40 { kind = .function }
        push(i, j, kind)
        i = j
        continue
      }
      i += 1
    }
    return tokens
  }

  private static func isCapitalizedType(_ word: String) -> Bool {
    guard let first = word.unicodeScalars.first, first.value >= 65, first.value <= 90 else { return false }
    return word.unicodeScalars.dropFirst().contains { $0.value >= 97 && $0.value <= 122 }
      && word.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0.value == 95 }
  }

  private static func markupTokens(_ buffer: [UInt16]) -> [OrgCodeToken] {
    var tokens: [OrgCodeToken] = []
    func push(_ start: Int, _ end: Int, _ kind: OrgCodeTokenKind) {
      if end > start { tokens.append(OrgCodeToken(kind: kind, range: NSRange(location: start, length: end - start))) }
    }
    let length = buffer.count
    let commentOpen = Array("<!--".utf16), commentClose = Array("-->".utf16)
    let cdataOpen = Array("<![CDATA[".utf16), cdataClose = Array("]]>".utf16)
    var i = 0
    while i < length {
      if starts(buffer, commentOpen, at: i) {
        let stop = find(buffer, commentClose, from: i + 4).map { $0 + 3 } ?? length
        push(i, stop, .comment)
        i = stop
        continue
      }
      if starts(buffer, cdataOpen, at: i) {
        let stop = find(buffer, cdataClose, from: i).map { $0 + 3 } ?? length
        push(i, stop, .string)
        i = stop
        continue
      }
      if buffer[i] == 60, i + 1 < length, isAlpha(buffer[i + 1]) || [47, 33, 63].contains(buffer[i + 1]) {
        var j = i + 1
        if [47, 33, 63].contains(buffer[j]) { j += 1 }
        if j < length, isAlpha(buffer[j]) {
          while j < length, isWordChar(buffer[j]) || [58, 46, 45].contains(buffer[j]) { j += 1 }
          push(i, j, .tag)
          i = j
          while i < length, buffer[i] != 62, !(buffer[i] == 47 && i + 1 < length && buffer[i + 1] == 62), !(buffer[i] == 63 && i + 1 < length && buffer[i + 1] == 62) {
            let ch = buffer[i]
            if ch == 34 || ch == 39 {
              var close = i + 1
              while close < length, buffer[close] != ch { close += 1 }
              let stop = min(close + 1, length)
              push(i, stop, .string)
              i = stop
            } else if isAlpha(ch) || ch == 95 || ch == 58 || ch == 64 {
              var end = i + 1
              while end < length, isWordChar(buffer[end]) || [58, 46, 45].contains(buffer[end]) { end += 1 }
              push(i, end, .attr)
              i = end
            } else {
              i += 1
            }
          }
          let close = i + 1 < length && (buffer[i] == 47 || buffer[i] == 63) && buffer[i + 1] == 62 ? 2 : (i < length && buffer[i] == 62 ? 1 : 0)
          push(i, i + close, .tag)
          i += close
          continue
        }
      }
      if buffer[i] == 38 {
        var j = i + 1
        while j < length, j - i < 32, buffer[j] != 59, isWordChar(buffer[j]) || buffer[j] == 35 { j += 1 }
        if j < length, buffer[j] == 59, j > i + 1 {
          push(i, j + 1, .literal)
          i = j + 1
          continue
        }
      }
      i += 1
    }
    return tokens
  }

  // MARK: Styling

  private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
  }

  private static func hex(_ value: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }

  private static let palette: [OrgCodeTokenKind: NSColor] = Dictionary(
    uniqueKeysWithValues: OrgCodeTokenKind.allCases.map { ($0, makeColor(for: $0)) }
  )

  /// The same palette as the rendered view's `org2-tok-*` classes.
  public static func color(for kind: OrgCodeTokenKind) -> NSColor {
    palette[kind] ?? .labelColor
  }

  private static func makeColor(for kind: OrgCodeTokenKind) -> NSColor {
    switch kind {
    case .comment: dynamic(light: hex(0x6B7570), dark: hex(0x87918C))
    case .string: dynamic(light: hex(0x1F7A3D), dark: hex(0x8FD19E))
    case .keyword, .tag: dynamic(light: hex(0x8A3FB8), dark: hex(0xD3A4F5))
    case .number, .literal: dynamic(light: hex(0xB0561B), dark: hex(0xF0A673))
    case .type: dynamic(light: hex(0x1D6F9E), dark: hex(0x79C5EC))
    case .function: dynamic(light: hex(0x2854D7), dark: hex(0x9DB4FF))
    case .property, .attr: dynamic(light: hex(0x9A4A12), dark: hex(0xF2C27D))
    case .meta, .variable: dynamic(light: hex(0xA33A6E), dark: hex(0xF0A0C8))
    }
  }

  static func attributes(for kind: OrgCodeTokenKind, baseFont: NSFont) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(for: kind)]
    switch kind {
    case .keyword:
      attributes[.font] = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .semibold)
    case .comment:
      let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
      attributes[.font] = italic
    default:
      break
    }
    return attributes
  }

  /// Restyles `storage` as `language` source. The whole document is
  /// tokenized so multi-line strings and comments stay correct; attributes
  /// are reset and applied only within `characterRange` (whole lines) when
  /// one is given.
  @discardableResult
  static func apply(
    to storage: NSTextStorage,
    language: String,
    characterRange requestedRange: NSRange? = nil,
    baseAttributes: [NSAttributedString.Key: Any]
  ) -> [NSAttributedString.Key: Any] {
    let fullRange = NSRange(location: 0, length: storage.length)
    let target: NSRange
    if let requestedRange {
      let location = min(max(0, requestedRange.location), storage.length)
      let length = min(max(0, requestedRange.length), storage.length - location)
      target = storage.mutableString.lineRange(for: NSRange(location: location, length: length))
    } else {
      target = fullRange
    }
    let baseFont = baseAttributes[.font] as? NSFont ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: target)
    if storage.length <= tokenizationUTF16Limit {
      for token in tokens(in: storage.mutableString, language: language) {
        let intersection = NSIntersectionRange(token.range, target)
        guard intersection.length > 0, NSMaxRange(intersection) <= storage.length else { continue }
        storage.addAttributes(attributes(for: token.kind, baseFont: baseFont), range: intersection)
      }
    }
    storage.endEditing()
    return baseAttributes
  }
}
