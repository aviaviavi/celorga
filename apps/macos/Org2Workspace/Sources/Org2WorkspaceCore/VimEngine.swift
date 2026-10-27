import Foundation

/// A key as the Vim engine sees it: a single typed character such as `"d"`,
/// or a named key such as `"<Esc>"`, `"<CR>"`, or `"<C-r>"`.
typealias VimKey = String

enum VimMode: Equatable, Sendable {
  case normal
  case insert
  case replace
  case visual
  case visualLine
  case visualBlock
  case commandLine

  var isVisual: Bool {
    self == .visual || self == .visualLine || self == .visualBlock
  }
}

enum VimScrollAnchor: Equatable, Sendable {
  case top
  case center
  case bottom
}

/// Org editor actions Vim keys can reach (`za`, `zR`, `[[`, `]]`, Tab).
enum VimEditorCommand: Equatable, Sendable {
  case toggleFold
  case unfoldAll
  case previousHeading
  case nextHeading
}

struct VimStatus: Equatable, Sendable {
  var mode: VimMode
  var modeLabel: String
  var pendingKeys: String
  var commandLine: String?
  var message: String?
  var isError: Bool
  var recordingRegister: Character?
}

/// The editor surface the engine drives. The macOS source editor implements
/// it over `NSTextView`; tests implement it over a plain string.
@MainActor
protocol VimEditorHost: AnyObject {
  var vimText: NSString { get }
  var vimSelectedRange: NSRange { get }
  func vimSetSelectedRanges(_ ranges: [NSRange])
  /// Replaces text as one undoable edit.
  func vimReplaceCharacters(in range: NSRange, with text: String)
  /// Types into the editor as if from the keyboard (macro replay in Insert mode).
  func vimTypeText(_ text: String)
  func vimTypeNewline()
  func vimTypeDeleteBackward()
  func vimTypeTab()
  func vimUndo() -> Bool
  func vimRedo() -> Bool
  func vimSave() -> Bool
  func vimVisibleCharacterRange() -> NSRange
  func vimScroll(lines: Int)
  func vimScrollCursor(to anchor: VimScrollAnchor)
  /// Moves by wrapped display lines and returns the new location.
  func vimDisplayLineLocation(from location: Int, down: Bool, count: Int) -> Int?
  func vimPerform(_ command: VimEditorCommand) -> Bool
  func vimClipboardString() -> String?
  func vimSetClipboardString(_ string: String)
  func vimFlash(_ range: NSRange)
  func vimBeep()
  func vimInsertSessionDidBegin()
  func vimInsertSessionDidEnd()
  func vimStateDidChange()
  /// Text that `o` puts at the start of the new line below the line holding
  /// `location`, or nil for the line's plain indentation.
  func vimOpenLineBelowPrefix(forLineAt location: Int) -> String?
}

extension VimEditorHost {
  func vimOpenLineBelowPrefix(forLineAt location: Int) -> String? { nil }
}

@MainActor
final class VimEngine {
  struct Register: Equatable {
    var text: String
    var linewise: Bool
    var blockwise: Bool = false
  }

  enum Operator: String {
    case delete = "d"
    case change = "c"
    case yank = "y"
    case indent = ">"
    case outdent = "<"
    case toggleCase = "g~"
    case lowercase = "gu"
    case uppercase = "gU"
    case rot13 = "g?"
    case join = "J"
  }

  struct MotionSpec: Equatable {
    var key: String
    var argument: VimKey?
    var count: Int?
  }

  struct TextObjectSpec: Equatable {
    var around: Bool
    var kind: VimKey
    var count: Int?
  }

  enum Action: Equatable {
    case motion(MotionSpec)
    case operatorMotion(Operator, MotionSpec)
    case operatorTextObject(Operator, TextObjectSpec)
    case operatorLine(Operator, count: Int?)
    case operatorSearch(Operator, forward: Bool)
    case textObject(TextObjectSpec)
    case visualOperator(Operator)
    case command(String, argument: VimKey?)
  }

  struct Command: Equatable {
    var register: Character?
    var count: Int?
    var action: Action
    /// Keys after the register and count, for `.` repeat.
    var keys: [VimKey]
  }

  enum ParseResult: Equatable {
    case incomplete
    case invalid
    case command(Command)
  }

  struct MotionResult {
    var target: Int
    var linewise: Bool
    var inclusive: Bool
    var curswant: Int?
    var isJump = false
    /// Operator range override (text objects, `dw` at line end).
    var operatorEnd: Int?
  }

  struct RecordedChange {
    var register: Character?
    var count: Int?
    var keys: [VimKey]
    var insertedText: String?
    var visual: (mode: VimMode, lines: Int, columns: Int)?
  }

  enum InsertKind: Equatable {
    case plain
    case openBelow
    case openAbove
    case block(lineStarts: [Int], column: Int, append: Bool, toLineEnd: Bool)
  }

  struct InsertSession {
    var startLocation: Int
    var startLength: Int
    var count: Int
    var kind: InsertKind
    var change: RecordedChange?
    var replacedCharacters: [String] = []
    var typedText = ""
  }

  weak var host: VimEditorHost?

  var mode: VimMode = .normal
  var pending: [VimKey] = []
  var registers: [Character: Register] = [:]
  var marks: [Character: Int] = [:]
  var curswant: Int?
  var visualAnchor = 0
  var visualCursor = 0
  var lastVisual: (mode: VimMode, anchor: Int, cursor: Int, curswant: Int?)?
  var lastFind: (character: String, forward: Bool, till: Bool)?
  var lastSearch: (pattern: String, forward: Bool)?
  var lastSubstitute: (pattern: String, replacement: String, flags: String)?
  var lastChange: RecordedChange?
  var insertSession: InsertSession?
  var recordingRegister: Character?
  var recordedKeys: [VimKey] = []
  var lastExecutedMacro: Character?
  var commandLinePrefix: Character = ":"
  var commandLineText = ""
  var commandLineReturnMode: VimMode = .normal
  var commandHistory: [String] = []
  var searchHistory: [String] = []
  var historyIndex: Int?
  var lastCommandLine: String?
  var message: String?
  var messageIsError = false
  var isReplaying = false
  var replayDepth = 0
  var insertOneShotNormal = false
  var awaitingInsertRegister = false
  var awaitingCommandLineRegister = false
  var lastClipboardWrite: String?
  var jumpList: [Int] = []
  var jumpIndex = 0
  var lastInsertedText: String?
  var lastInsertLocation: Int?
  var lastChangeLocation: Int?
  var pendingOperatorSearch: (op: Operator, command: Command)?

  // Options (`:set`).
  var ignoreCase = false
  var smartCase = false
  var shiftWidth = 2
  var expandTab = true
  var clipboardUnnamed = true
  var wrapScan = true

  init(host: VimEditorHost? = nil) {
    self.host = host
  }

  var text: NSString { host?.vimText ?? "" }

  var cursor: Int {
    if mode.isVisual { return visualCursor }
    return host?.vimSelectedRange.location ?? 0
  }

  // MARK: Status

  var status: VimStatus {
    let label: String
    switch mode {
    case .normal: label = insertOneShotNormal ? "-- (insert) --" : "NORMAL"
    case .insert: label = "-- INSERT --"
    case .replace: label = "-- REPLACE --"
    case .visual: label = "-- VISUAL --"
    case .visualLine: label = "-- VISUAL LINE --"
    case .visualBlock: label = "-- VISUAL BLOCK --"
    case .commandLine: label = "COMMAND"
    }
    return VimStatus(
      mode: mode,
      modeLabel: label,
      pendingKeys: pending.joined(),
      commandLine: mode == .commandLine ? "\(commandLinePrefix)\(commandLineText)" : nil,
      message: message,
      isError: messageIsError,
      recordingRegister: recordingRegister
    )
  }

  /// Whether the caret should draw as a block.
  var usesBlockCursor: Bool {
    mode == .normal || mode.isVisual || mode == .commandLine
  }

  func setMessage(_ text: String?, error: Bool = false) {
    message = text
    messageIsError = error
  }

  func fail(_ text: String? = nil) {
    if let text { setMessage(text, error: true) }
    host?.vimBeep()
  }

  // MARK: Entry points

  /// Handles one key. Returns false when the editor should process the key
  /// natively (typing in Insert mode).
  @discardableResult
  func handle(_ key: VimKey) -> Bool {
    if recordingRegister != nil, !isReplaying {
      recordedKeys.append(key)
    }
    if !isReplaying, mode != .commandLine {
      message = nil
    }
    let handled: Bool
    switch mode {
    case .insert:
      handled = handleInsertKey(key)
    case .replace:
      handled = handleReplaceKey(key)
    case .commandLine:
      handled = handleCommandLineKey(key)
    case .normal, .visual, .visualLine, .visualBlock:
      handled = handleNormalKey(key)
    }
    if !isReplaying {
      host?.vimStateDidChange()
    }
    return handled
  }

  func feed(_ keys: [VimKey]) {
    for key in keys {
      handle(key)
    }
  }

  /// Splits typed text such as `dw` or `ihello<Esc>` into keys.
  static func keys(from string: String) -> [VimKey] {
    var keys: [VimKey] = []
    var index = string.startIndex
    while index < string.endIndex {
      let c = string[index]
      if c == "<", let close = string[index...].firstIndex(of: ">") {
        let name = String(string[index...close])
        if Self.namedKeys.contains(name) || name.hasPrefix("<C-") && name.count == 5 {
          keys.append(name == "<lt>" ? "<" : name)
          index = string.index(after: close)
          continue
        }
      }
      switch c {
      case "\u{1b}": keys.append("<Esc>")
      case "\r", "\n": keys.append("<CR>")
      case "\t": keys.append("<Tab>")
      default: keys.append(String(c))
      }
      index = string.index(after: index)
    }
    return keys
  }

  static let namedKeys: Set<String> = [
    "<Esc>", "<CR>", "<BS>", "<Tab>", "<Del>", "<Left>", "<Right>", "<Up>", "<Down>",
    "<Home>", "<End>", "<PageUp>", "<PageDown>", "<Space>", "<lt>"
  ]

  /// Keeps the engine consistent with a selection the user made with the
  /// mouse or another editor command. Returns a corrected selection, if any.
  func selectionDidChangeExternally(_ range: NSRange) -> NSRange? {
    switch mode {
    case .normal:
      if range.length > 0 {
        pending.removeAll()
        mode = .visual
        visualAnchor = range.location
        visualCursor = VimText.previousPosition(text, range.location + range.length)
        curswant = nil
        host?.vimStateDidChange()
        return nil
      }
      let clamped = VimText.clampNormal(text, range.location)
      curswant = nil
      return clamped == range.location ? nil : NSRange(location: clamped, length: 0)
    case .visual, .visualLine, .visualBlock:
      if range.length == 0 {
        mode = .normal
        pending.removeAll()
        let clamped = VimText.clampNormal(text, range.location)
        host?.vimStateDidChange()
        return clamped == range.location ? nil : NSRange(location: clamped, length: 0)
      }
      mode = .visual
      visualAnchor = range.location
      visualCursor = VimText.previousPosition(text, range.location + range.length)
      host?.vimStateDidChange()
      return nil
    case .insert, .replace, .commandLine:
      return nil
    }
  }

  /// Resets to Normal mode, as when the editor loses focus or reloads.
  func reset() {
    if mode == .insert || mode == .replace {
      finishInsertSession()
    }
    pending.removeAll()
    insertOneShotNormal = false
    if mode != .normal {
      mode = .normal
      setCursor(VimText.clampNormal(text, host?.vimSelectedRange.location ?? 0))
    }
    host?.vimStateDidChange()
  }

  // MARK: Cursor

  func setCursor(_ location: Int, keepCurswant: Bool = false) {
    let clamped = mode == .insert || mode == .replace
      ? min(max(0, location), text.length)
      : VimText.clampNormal(text, location)
    if !keepCurswant { curswant = nil }
    host?.vimSetSelectedRanges([NSRange(location: clamped, length: 0)])
  }

  func column(of location: Int) -> Int {
    location - VimText.lineStart(text, location)
  }

  func pushJump(from location: Int) {
    marks["'"] = location
    if jumpIndex < jumpList.count {
      jumpList.removeSubrange(jumpIndex...)
    }
    if jumpList.last != location {
      jumpList.append(location)
    }
    if jumpList.count > 100 { jumpList.removeFirst(jumpList.count - 100) }
    jumpIndex = jumpList.count
  }

  // MARK: Normal and Visual keys

  private func handleNormalKey(_ key: VimKey) -> Bool {
    if key == "<Esc>" || key == "<C-c>" || key == "<C-[>" {
      if !pending.isEmpty {
        pending.removeAll()
        return true
      }
      if mode.isVisual {
        exitVisual()
        return true
      }
      if insertOneShotNormal {
        insertOneShotNormal = false
        mode = .insert
        return true
      }
      return true
    }
    pending.append(key)
    switch parse(pending, visual: mode.isVisual) {
    case .incomplete:
      return true
    case .invalid:
      pending.removeAll()
      host?.vimBeep()
      return true
    case let .command(command):
      pending.removeAll()
      execute(command)
      if insertOneShotNormal, mode == .normal {
        insertOneShotNormal = false
        if insertSession != nil {
          mode = .insert
          host?.vimSetSelectedRanges([NSRange(location: min(cursor, text.length), length: 0)])
        }
      }
      return true
    }
  }

  // MARK: Parsing

  static let motionKeys: Set<String> = [
    "h", "l", "j", "k", "w", "W", "b", "B", "e", "E", "0", "^", "$", "G", "|",
    "{", "}", "(", ")", "%", "H", "M", "L", "n", "N", "*", "#", ";", ",", "_", "+", "-",
    "<CR>", "<BS>", "<Space>", " ", "<Left>", "<Right>", "<Up>", "<Down>", "<Home>", "<End>",
    "<C-h>", "<C-n>", "<C-p>", "<C-j>"
  ]
  static let gMotionKeys: Set<String> = ["g", "e", "E", "_", "j", "k", "0", "$", "^", "m", "<Down>", "<Up>"]
  static let argumentMotionKeys: Set<String> = ["f", "F", "t", "T", "'", "`"]
  static let textObjectKinds: Set<String> = [
    "w", "W", "s", "p", "\"", "'", "`", "(", ")", "b", "{", "}", "B", "[", "]", "<", ">", "t"
  ]

  static func isPrintableArgument(_ key: VimKey) -> Bool {
    key.count == 1 || key == "<Space>" || key == "<CR>" || key == "<Tab>" || key == "<lt>"
  }

  static func literal(_ key: VimKey) -> String {
    switch key {
    case "<Space>": " "
    case "<CR>": "\n"
    case "<Tab>": "\t"
    case "<lt>": "<"
    default: key
    }
  }

  func parse(_ keys: [VimKey], visual: Bool) -> ParseResult {
    var index = 0
    var register: Character?
    if index < keys.count, keys[index] == "\"" {
      guard index + 1 < keys.count else { return .incomplete }
      let name = keys[index + 1]
      guard name.count == 1, let c = name.first, Self.isValidRegister(c) else { return .invalid }
      register = c
      index += 2
    }
    let (count, afterCount) = parseCount(keys, from: index)
    index = afterCount
    guard index < keys.count else { return .incomplete }
    let commandStart = index
    func done(_ action: Action) -> ParseResult {
      .command(Command(register: register, count: count, action: action, keys: Array(keys[commandStart...])))
    }

    let key = keys[index]

    // Operators.
    var op: Operator?
    var opLength = 1
    switch key {
    case "d": op = .delete
    case "c": op = .change
    case "y": op = .yank
    case ">": op = .indent
    case "<", "<lt>": op = .outdent
    case "g":
      guard index + 1 < keys.count else { return .incomplete }
      switch keys[index + 1] {
      case "~": op = .toggleCase; opLength = 2
      case "u": op = .lowercase; opLength = 2
      case "U": op = .uppercase; opLength = 2
      case "?": op = .rot13; opLength = 2
      default: break
      }
    default: break
    }
    if let op {
      if visual {
        return done(.visualOperator(op))
      }
      index += opLength
      let (motionCount, afterMotionCount) = parseCount(keys, from: index)
      index = afterMotionCount
      guard index < keys.count else { return .incomplete }
      let next = keys[index]
      // Doubled operator: dd, cc, yy, >>, <<, g~~, g~g~, guu, gugu, gUU, gUgU.
      let opKeys = keys[commandStart..<(commandStart + opLength)]
      if opLength == 1, next == key || (op == .outdent && (next == "<" || next == "<lt>")) {
        return done(.operatorLine(op, count: motionCount))
      }
      if opLength == 2 {
        if next == opKeys.last! { return done(.operatorLine(op, count: motionCount)) }
        if next == "g" {
          guard index + 1 < keys.count else { return .incomplete }
          if keys[index + 1] == opKeys.last! { return done(.operatorLine(op, count: motionCount)) }
        }
      }
      if next == "/" || next == "?" {
        return done(.operatorSearch(op, forward: next == "/"))
      }
      if next == "i" || next == "a" {
        guard index + 1 < keys.count else { return .incomplete }
        let kind = keys[index + 1]
        guard Self.textObjectKinds.contains(kind) else { return .invalid }
        return done(.operatorTextObject(op, TextObjectSpec(around: next == "a", kind: kind, count: motionCount)))
      }
      switch parseMotion(keys, from: index, count: motionCount) {
      case .incomplete: return .incomplete
      case .invalid: return .invalid
      case let .motion(spec): return done(.operatorMotion(op, spec))
      }
    }

    if visual, key == "i" || key == "a" {
      guard index + 1 < keys.count else { return .incomplete }
      let kind = keys[index + 1]
      guard Self.textObjectKinds.contains(kind) else { return .invalid }
      return done(.textObject(TextObjectSpec(around: key == "a", kind: kind, count: count)))
    }

    // Commands that take an argument.
    switch key {
    case "r", "m", "q", "@":
      if key == "q", recordingRegister != nil, !visual { return done(.command("q", argument: nil)) }
      guard index + 1 < keys.count else { return .incomplete }
      let argument = keys[index + 1]
      guard Self.isPrintableArgument(argument) else { return .invalid }
      return done(.command(key, argument: argument))
    case "z", "Z", "[", "]":
      guard index + 1 < keys.count else { return .incomplete }
      return done(.command(key + keys[index + 1], argument: nil))
    case "g":
      guard index + 1 < keys.count else { return .incomplete }
      let second = keys[index + 1]
      if ["v", "i", "I", "J", "p", "P", "&", ";", "a", "8"].contains(second) {
        return done(.command("g" + second, argument: nil))
      }
    default:
      break
    }

    switch parseMotion(keys, from: index, count: nil) {
    case .incomplete: return .incomplete
    case let .motion(spec):
      return done(.motion(spec))
    case .invalid:
      break
    }

    let simpleCommands: Set<String> = visual
      ? ["x", "X", "D", "C", "s", "S", "R", "Y", "p", "P", "J", "~", "u", "U", "o", "O", "I", "A",
         "v", "V", "<C-v>", ":", "<Del>", "<C-a>", "<C-x>", "r", "<C-d>", "<C-u>", "<C-f>", "<C-b>",
         "<C-e>", "<C-y>", "/", "?"]
      : ["x", "X", "D", "C", "s", "S", "Y", "p", "P", "J", "~", "u", "<C-r>", ".", "i", "a", "I", "A",
         "o", "O", "R", "v", "V", "<C-v>", ":", "/", "?", "&", "<C-d>", "<C-u>", "<C-f>", "<C-b>",
         "<C-e>", "<C-y>", "<C-a>", "<C-x>", "<Tab>", "<Del>", "<C-o>", "<C-i>", "<C-g>",
         "<PageUp>", "<PageDown>", "<Insert>"]
    if simpleCommands.contains(key) {
      return done(.command(key, argument: nil))
    }
    return .invalid
  }

  enum MotionParse: Equatable {
    case incomplete
    case invalid
    case motion(MotionSpec)
  }

  func parseMotion(_ keys: [VimKey], from index: Int, count: Int?) -> MotionParse {
    guard index < keys.count else { return .incomplete }
    let key = keys[index]
    if Self.motionKeys.contains(key) {
      return index + 1 == keys.count ? .motion(MotionSpec(key: key, count: count)) : .invalid
    }
    if Self.argumentMotionKeys.contains(key) {
      guard index + 1 < keys.count else { return .incomplete }
      let argument = keys[index + 1]
      guard Self.isPrintableArgument(argument) else { return .invalid }
      return .motion(MotionSpec(key: key, argument: argument, count: count))
    }
    if key == "g" {
      guard index + 1 < keys.count else { return .incomplete }
      let second = keys[index + 1]
      guard Self.gMotionKeys.contains(second) else { return .invalid }
      return .motion(MotionSpec(key: "g" + second, count: count))
    }
    return .invalid
  }

  func parseCount(_ keys: [VimKey], from index: Int) -> (Int?, Int) {
    var index = index
    var value = 0
    var found = false
    while index < keys.count, let digit = Int(keys[index]), keys[index].count == 1 {
      if !found && digit == 0 { break }
      value = min(value * 10 + digit, 999_999)
      found = true
      index += 1
    }
    return (found ? value : nil, index)
  }

  static func isValidRegister(_ c: Character) -> Bool {
    c.isLetter && c.isASCII || c.isNumber && c.isASCII || "\"-+*_./:".contains(c)
  }
}
