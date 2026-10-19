import XCTest
@testable import Org2WorkspaceCore

/// A plain-string editor that mimics how the source editor hosts Vim mode.
@MainActor
private final class FakeVimHost: VimEditorHost {
  let storage: NSMutableString
  var selections: [NSRange]
  var clipboard: String?
  var undoStack: [(String, Int)] = []
  var redoStack: [(String, Int)] = []
  var saveCount = 0
  var beeps = 0
  var visibleLines = 0..<10
  var sessionSnapshot: (String, Int)?
  var keySnapshot: (String, Int)?
  var commands: [VimEditorCommand] = []

  init(_ text: String, cursor: Int = 0) {
    storage = NSMutableString(string: text)
    selections = [NSRange(location: cursor, length: 0)]
  }

  var vimText: NSString { storage }
  var vimSelectedRange: NSRange { selections.first ?? NSRange(location: 0, length: 0) }
  func vimSetSelectedRanges(_ ranges: [NSRange]) { selections = ranges }
  func vimReplaceCharacters(in range: NSRange, with text: String) {
    storage.replaceCharacters(in: range, with: text)
  }
  func vimTypeText(_ text: String) {
    let location = vimSelectedRange.location
    storage.replaceCharacters(in: NSRange(location: location, length: 0), with: text)
    selections = [NSRange(location: location + (text as NSString).length, length: 0)]
  }
  func vimTypeNewline() { vimTypeText("\n") }
  func vimTypeDeleteBackward() {
    let location = vimSelectedRange.location
    guard location > 0 else { return }
    storage.replaceCharacters(in: NSRange(location: location - 1, length: 1), with: "")
    selections = [NSRange(location: location - 1, length: 0)]
  }
  func vimTypeTab() { vimTypeText("\t") }
  func vimUndo() -> Bool {
    guard let (text, cursor) = undoStack.popLast() else { return false }
    redoStack.append((storage as String, vimSelectedRange.location))
    storage.setString(text)
    selections = [NSRange(location: cursor, length: 0)]
    return true
  }
  func vimRedo() -> Bool {
    guard let (text, cursor) = redoStack.popLast() else { return false }
    undoStack.append((storage as String, vimSelectedRange.location))
    storage.setString(text)
    selections = [NSRange(location: cursor, length: 0)]
    return true
  }
  func vimSave() -> Bool { saveCount += 1; return true }
  func vimVisibleCharacterRange() -> NSRange {
    let start = VimText.startOfLine(storage, index: visibleLines.lowerBound)
    let end = VimText.startOfLine(storage, index: visibleLines.upperBound)
    return NSRange(location: start, length: max(0, (end == start ? storage.length : end) - start))
  }
  func vimScroll(lines: Int) {
    let shifted = max(0, visibleLines.lowerBound + lines)
    visibleLines = shifted..<(shifted + visibleLines.count)
  }
  func vimScrollCursor(to anchor: VimScrollAnchor) {}
  func vimDisplayLineLocation(from location: Int, down: Bool, count: Int) -> Int? { nil }
  func vimPerform(_ command: VimEditorCommand) -> Bool { commands.append(command); return true }
  func vimClipboardString() -> String? { clipboard }
  func vimSetClipboardString(_ string: String) { clipboard = string }
  func vimFlash(_ range: NSRange) {}
  func vimBeep() { beeps += 1 }
  func vimInsertSessionDidBegin() { sessionSnapshot = keySnapshot }
  func vimInsertSessionDidEnd() {
    if let sessionSnapshot, sessionSnapshot.0 != storage as String {
      undoStack.append(sessionSnapshot)
      redoStack.removeAll()
    }
    sessionSnapshot = nil
  }
  func vimStateDidChange() {}
}

@MainActor
final class VimEngineTests: XCTestCase {
  private var host: FakeVimHost!
  private var vim: VimEngine!

  private func setUp(_ text: String, cursor: Int = 0) {
    host = FakeVimHost(text, cursor: cursor)
    vim = VimEngine(host: host)
    vim.clipboardUnnamed = false
  }

  /// Feeds keys the way the editor does: keys Vim declines in Insert mode are
  /// typed into the buffer.
  private func type(_ keys: String) {
    for key in VimEngine.keys(from: keys) {
      let before = (host.storage as String, host.vimSelectedRange.location)
      host.keySnapshot = before
      let wasInsert = vim.mode == .insert
      let handled = vim.handle(key)
      if !handled {
        switch key {
        case "<CR>": host.vimTypeNewline()
        case "<BS>": host.vimTypeDeleteBackward()
        default: host.vimTypeText(VimEngine.literal(key))
        }
      }
      if !wasInsert, vim.mode != .insert, vim.mode != .replace, host.storage as String != before.0,
         key != "u", key != "<C-r>" {
        host.undoStack.append(before)
        host.redoStack.removeAll()
      }
    }
  }

  private var text: String { host.storage as String }
  private var cursor: Int { host.vimSelectedRange.location }
  private var selection: NSRange { host.vimSelectedRange }

  // MARK: Motions

  func testBasicMotions() {
    setUp("hello world\nsecond line\n")
    type("w")
    XCTAssertEqual(cursor, 6)
    type("e")
    XCTAssertEqual(cursor, 10)
    type("b")
    XCTAssertEqual(cursor, 6)
    type("0")
    XCTAssertEqual(cursor, 0)
    type("$")
    XCTAssertEqual(cursor, 10)
    type("j")
    XCTAssertEqual(cursor, 22, "keeps the end-of-line column")
    type("k0l")
    XCTAssertEqual(cursor, 1)
  }

  func testCountsAndLineMotions() {
    setUp("one\n  two\nthree\nfour\n")
    type("2j")
    XCTAssertEqual(cursor, 10)
    type("gg")
    XCTAssertEqual(cursor, 0)
    type("G")
    XCTAssertEqual(cursor, 16, "the final newline ends the last line")
    type("2G")
    XCTAssertEqual(cursor, 6, "goes to the first non-blank")
    type("3w")
    XCTAssertEqual(text, "one\n  two\nthree\nfour\n")
  }

  func testCurswantAcrossShortLines() {
    setUp("abcdef\nab\nabcdef\n", cursor: 4)
    type("j")
    XCTAssertEqual(cursor, 8)
    type("j")
    XCTAssertEqual(cursor, 14)
  }

  func testWordMotionsWithPunctuationAndBigWords() {
    setUp("foo.bar baz-qux end")
    type("w")
    XCTAssertEqual(cursor, 3)
    type("w")
    XCTAssertEqual(cursor, 4)
    type("0W")
    XCTAssertEqual(cursor, 8)
    type("E")
    XCTAssertEqual(cursor, 14)
    type("ge")
    XCTAssertEqual(cursor, 11)
  }

  func testEmptyLinesAreWordStops() {
    setUp("one\n\ntwo")
    type("w")
    XCTAssertEqual(cursor, 4)
    type("w")
    XCTAssertEqual(cursor, 5)
    type("b")
    XCTAssertEqual(cursor, 4)
  }

  func testFindAndTillWithRepeat() {
    setUp("a,b,c,d")
    type("f,")
    XCTAssertEqual(cursor, 1)
    type(";")
    XCTAssertEqual(cursor, 3)
    type(",")
    XCTAssertEqual(cursor, 1)
    type("0t,")
    XCTAssertEqual(cursor, 0)
    type(";")
    XCTAssertEqual(cursor, 2, "; after t skips the adjacent match")
    type("2f,")
    XCTAssertEqual(cursor, 5)
  }

  func testParagraphAndBracketMotions() {
    setUp("a\nb\n\nc\nd\n\ne")
    type("}")
    XCTAssertEqual(cursor, 4)
    type("}")
    XCTAssertEqual(cursor, 9)
    type("{")
    XCTAssertEqual(cursor, 4)

    setUp("call(a, [b, c])")
    type("%")
    XCTAssertEqual(cursor, 14)
    type("%")
    XCTAssertEqual(cursor, 4)
  }

  func testSearchForwardBackwardAndStar() {
    setUp("foo bar\nbaz foo\nfoo end")
    type("/foo<CR>")
    XCTAssertEqual(cursor, 12)
    type("n")
    XCTAssertEqual(cursor, 16)
    type("n")
    XCTAssertEqual(cursor, 0, "wraps around")
    type("N")
    XCTAssertEqual(cursor, 16)
    type("gg*")
    XCTAssertEqual(cursor, 12)
    type("#")
    XCTAssertEqual(cursor, 0)
    type("?bar<CR>")
    XCTAssertEqual(cursor, 4)
  }

  func testSearchPatternTranslation() {
    setUp("cat catalog concat cat")
    type("/\\<cat\\><CR>")
    XCTAssertEqual(cursor, 19)
    type("/\\(con\\)cat<CR>")
    XCTAssertEqual(cursor, 12)
    setUp("Foo foo")
    type("/\\cFOO<CR>")
    XCTAssertEqual(cursor, 4)
  }

  // MARK: Operators

  func testDeleteWordAndLine() {
    setUp("one two three\nfour\n")
    type("dw")
    XCTAssertEqual(text, "two three\nfour\n")
    type("dd")
    XCTAssertEqual(text, "four\n")
    XCTAssertEqual(vim.registers["\""], VimEngine.Register(text: "two three\n", linewise: true))
    type("p")
    XCTAssertEqual(text, "four\ntwo three\n")
    XCTAssertEqual(cursor, 5)
  }

  func testDeleteWordAtLineEndKeepsNewline() {
    setUp("one two\nthree", cursor: 4)
    type("dw")
    XCTAssertEqual(text, "one \nthree")
  }

  func testDeleteLastLineRemovesPrecedingNewline() {
    setUp("one\ntwo", cursor: 5)
    type("dd")
    XCTAssertEqual(text, "one")
    XCTAssertEqual(cursor, 0)
    type("p")
    XCTAssertEqual(text, "one\ntwo")
  }

  func testChangeWordActsLikeChangeEnd() {
    setUp("hello world")
    type("cwbye<Esc>")
    XCTAssertEqual(text, "bye world")
    XCTAssertEqual(cursor, 2)
    XCTAssertEqual(vim.mode, .normal)
  }

  func testDotRepeatsChangeAndDelete() {
    setUp("a b c d")
    type("cwX<Esc>w.")
    XCTAssertEqual(text, "X X c d")
    type("w.")
    XCTAssertEqual(text, "X X X d")
    setUp("1\n2\n3\n4\n")
    type("dd..")
    XCTAssertEqual(text, "4\n")
  }

  func testDotRepeatWithCountAndInsert() {
    setUp("x")
    type("ahi<Esc>")
    XCTAssertEqual(text, "xhi")
    type("3.")
    XCTAssertEqual(text, "xhihihihi")
  }

  func testCountedInsertAndOpenLine() {
    setUp("x")
    type("3ia<Esc>")
    XCTAssertEqual(text, "aaax")
    setUp("  item")
    type("onext<Esc>")
    XCTAssertEqual(text, "  item\n  next")
    type("2Oz<Esc>")
    XCTAssertEqual(text, "  item\n  z\n  z\n  next")
  }

  func testTextObjects() {
    setUp("call(foo, \"bar baz\") end", cursor: 13)
    type("ci\"q<Esc>")
    XCTAssertEqual(text, "call(foo, \"q\") end")
    type("di(")
    XCTAssertEqual(text, "call() end")
    setUp("word another", cursor: 1)
    type("daw")
    XCTAssertEqual(text, "another")
    setUp("p1\np1\n\np2\n", cursor: 0)
    type("dap")
    XCTAssertEqual(text, "p2\n")
  }

  func testBracesInnerBlockIsLinewise() {
    setUp("if {\n  body\n}\n", cursor: 7)
    type("di{")
    XCTAssertEqual(text, "if {\n}\n")
  }

  func testYankAndPutRegisters() {
    setUp("alpha beta")
    type("\"ayiw")
    type("w\"byiw")
    type("0\"bP")
    XCTAssertEqual(text, "betaalpha beta")
    type("$\"ap")
    XCTAssertEqual(text, "betaalpha betaalpha")
    type("\"Ayiw")
    XCTAssertEqual(vim.registers["a"]?.text, "alphabetaalpha")
  }

  func testNumberedAndSmallDeleteRegisters() {
    setUp("one\ntwo\nthree x")
    type("dd")
    type("dd")
    XCTAssertEqual(vim.registers["1"]?.text, "two\n")
    XCTAssertEqual(vim.registers["2"]?.text, "one\n")
    type("$x")
    XCTAssertEqual(vim.registers["-"]?.text, "x")
    type("\"2p")
    XCTAssertEqual(text, "three \none")
  }

  func testUnnamedRegisterUsesSystemClipboard() {
    setUp("foo")
    vim.clipboardUnnamed = true
    type("yiw")
    XCTAssertEqual(host.clipboard, "foo")
    host.clipboard = "bar"
    type("P")
    XCTAssertEqual(text, "barfoo")
  }

  func testIndentAndCaseOperators() {
    setUp("a\nb\nc")
    type(">j")
    XCTAssertEqual(text, "  a\n  b\nc")
    type("<<")
    XCTAssertEqual(text, "a\n  b\nc")
    type("gUiw")
    XCTAssertEqual(text, "A\n  b\nc")
    type("jg~~")
    XCTAssertEqual(text, "A\n  B\nc")
    type("guu")
    XCTAssertEqual(text, "A\n  b\nc")
  }

  func testSimpleEdits() {
    setUp("abc def")
    type("x")
    XCTAssertEqual(text, "bc def")
    type("rz")
    XCTAssertEqual(text, "zc def")
    type("~")
    XCTAssertEqual(text, "Zc def")
    type("D")
    XCTAssertEqual(text, "Z")
    setUp("one\n  two\nthree")
    type("J")
    XCTAssertEqual(text, "one two\nthree")
    XCTAssertEqual(cursor, 3)
    type("gJ")
    XCTAssertEqual(text, "one twothree")
    setUp("abc")
    type("sX<Esc>")
    XCTAssertEqual(text, "Xbc")
    type("SY<Esc>")
    XCTAssertEqual(text, "Y")
  }

  func testIncrementDecrement() {
    setUp("value 41 and -3")
    type("<C-a>")
    XCTAssertEqual(text, "value 42 and -3")
    type("w5<C-x>")
    XCTAssertEqual(text, "value 42 and -8")
  }

  func testReplaceMode() {
    setUp("abcdef")
    type("Rxy<Esc>")
    XCTAssertEqual(text, "xycdef")
    type("l.")
    XCTAssertEqual(text, "xyxyef")
    setUp("abc")
    type("Rxyz<BS><BS><Esc>")
    XCTAssertEqual(text, "xbc")
  }

  // MARK: Visual mode

  func testVisualCharacterAndLine() {
    setUp("one two three")
    type("vee")
    XCTAssertEqual(selection, NSRange(location: 0, length: 7))
    type("d")
    XCTAssertEqual(text, " three")
    XCTAssertEqual(vim.mode, .normal)
    setUp("a\nb\nc\n")
    type("Vjd")
    XCTAssertEqual(text, "c\n")
    setUp("a\nb\nc\n")
    type("Vj>")
    XCTAssertEqual(text, "  a\n  b\nc\n")
  }

  func testVisualTextObjectAndSwap() {
    setUp("x (inner text) y", cursor: 5)
    type("vi(")
    XCTAssertEqual(selection, NSRange(location: 3, length: 10))
    type("o")
    XCTAssertEqual(vim.visualCursor, 3)
    type("c!<Esc>")
    XCTAssertEqual(text, "x (!) y")
  }

  func testVisualBlockDeleteAndInsert() {
    setUp("abcd\nefgh\nijkl\n", cursor: 1)
    type("<C-v>jjld")
    XCTAssertEqual(text, "ad\neh\nil\n")
    setUp("abc\ndef\nghi\n")
    type("<C-v>jjI# <Esc>")
    XCTAssertEqual(text, "# abc\n# def\n# ghi\n")
    setUp("ab\ncdef\ngh\n")
    type("<C-v>jj$A;<Esc>")
    XCTAssertEqual(text, "ab;\ncdef;\ngh;\n")
  }

  func testVisualPutReplacesSelection() {
    setUp("keep this")
    type("yiwwviwp")
    XCTAssertEqual(text, "keep keep")
    XCTAssertEqual(vim.registers["\""]?.text, "this")
  }

  func testGvReselects() {
    setUp("one two")
    type("viw<Esc>gv")
    XCTAssertEqual(vim.mode, .visual)
    XCTAssertEqual(selection, NSRange(location: 0, length: 3))
  }

  // MARK: Undo, macros, marks

  func testUndoRedo() {
    setUp("one two")
    type("dw")
    XCTAssertEqual(text, "two")
    type("u")
    XCTAssertEqual(text, "one two")
    type("<C-r>")
    XCTAssertEqual(text, "two")
    type("ciwthree<Esc>u")
    XCTAssertEqual(text, "two", "an insert session undoes as one change")
  }

  func testMacroRecordAndReplay() {
    setUp("1\n2\n3\n4\n")
    type("qaA!<Esc>jq")
    XCTAssertEqual(text, "1!\n2\n3\n4\n")
    type("2@a")
    XCTAssertEqual(text, "1!\n2!\n3!\n4\n")
    type("@@")
    XCTAssertEqual(text, "1!\n2!\n3!\n4!\n")
  }

  func testMarks() {
    setUp("a\nb\nc\nd", cursor: 2)
    type("maG'a")
    XCTAssertEqual(cursor, 2)
    type("G``")
    XCTAssertEqual(cursor, 2)
    type("d'a")
    XCTAssertEqual(text, "a\nb\nc\nd".replacingOccurrences(of: "b\n", with: ""))
  }

  func testDeleteToSearchMatch() {
    setUp("keep remove until here")
    type("wd/here<CR>")
    XCTAssertEqual(text, "keep here")
  }

  // MARK: Command line

  func testSubstitute() {
    setUp("foo foo\nfoo bar\n")
    type(":s/foo/baz/<CR>")
    XCTAssertEqual(text, "baz foo\nfoo bar\n")
    type(":%s/foo/qux/g<CR>")
    XCTAssertEqual(text, "baz qux\nqux bar\n")
    type(":%s/\\(qux\\) \\(bar\\)/\\2 \\1/<CR>")
    XCTAssertEqual(text, "baz qux\nbar qux\n")
    type(":%s/qux/&!/g<CR>")
    XCTAssertEqual(text, "baz qux!\nbar qux!\n")
    type(":%s/ /\\r/<CR>")
    XCTAssertEqual(text, "baz\nqux!\nbar\nqux!\n")
  }

  func testVisualRangeSubstitute() {
    setUp("a\na\na\n")
    type("Vj:s/a/b/<CR>")
    XCTAssertEqual(text, "b\nb\na\n")
  }

  func testExLineCommands() {
    setUp("one\ntwo\nthree\nfour\n")
    type(":3<CR>")
    XCTAssertEqual(cursor, 8)
    type(":2,3d<CR>")
    XCTAssertEqual(text, "one\nfour\n")
    type(":1t$<CR>")
    XCTAssertEqual(text, "one\nfour\none\n")
    type(":1m$<CR>")
    XCTAssertEqual(text, "four\none\none\n")
    type(":sort u<CR>")
    XCTAssertEqual(text, "four\none\n")
    type(":w<CR>")
    XCTAssertEqual(host.saveCount, 1)
  }

  func testGlobalAndNormal() {
    setUp("keep\ndrop me\nkeep\ndrop\n")
    type(":g/drop/d<CR>")
    XCTAssertEqual(text, "keep\nkeep\n")
    type(":%normal A;<CR>")
    XCTAssertEqual(text, "keep;\nkeep;\n")
    setUp("a\nb\n")
    type(":v/a/s/b/c/<CR>")
    XCTAssertEqual(text, "a\nc\n")
  }

  func testUnknownCommandReportsError() {
    setUp("x")
    type(":bogus<CR>")
    XCTAssertEqual(vim.status.isError, true)
    XCTAssertEqual(vim.mode, .normal)
  }

  func testCommandLineEditingAndCancel() {
    setUp("abc")
    type(":s/b<BS>c/X/<CR>")
    XCTAssertEqual(text, "abX")
    type(":foo<Esc>")
    XCTAssertEqual(vim.mode, .normal)
    XCTAssertEqual(text, "abX")
  }

  // MARK: Insert mode keys and status

  func testInsertModeControlKeys() {
    setUp("")
    type("ifoo bar<C-w>baz<Esc>")
    XCTAssertEqual(text, "foo baz")
    type("A x y<C-u><Esc>")
    XCTAssertEqual(text, "")
  }

  func testInsertOneShotNormalCommand() {
    setUp("abc")
    type("A1<C-o>0X<Esc>")
    XCTAssertEqual(text, "Xabc1")
  }

  func testStatusLabels() {
    setUp("abc")
    XCTAssertEqual(vim.status.modeLabel, "NORMAL")
    type("i")
    XCTAssertEqual(vim.status.modeLabel, "-- INSERT --")
    type("<Esc>V")
    XCTAssertEqual(vim.status.modeLabel, "-- VISUAL LINE --")
    type("<Esc>2d")
    XCTAssertEqual(vim.status.pendingKeys, "2d")
    type("<Esc>:wq")
    XCTAssertEqual(vim.status.commandLine, ":wq")
  }

  func testNormalCursorNeverRestsOnNewline() {
    setUp("ab\ncd")
    type("$")
    XCTAssertEqual(cursor, 1)
    XCTAssertEqual(vim.selectionDidChangeExternally(NSRange(location: 2, length: 0)), NSRange(location: 1, length: 0))
    XCTAssertNil(vim.selectionDidChangeExternally(NSRange(location: 0, length: 2)))
    XCTAssertEqual(vim.mode, .visual)
  }

  func testOrgEditorCommands() {
    setUp("* Heading\nbody\n")
    type("<Tab>zR]][[")
    XCTAssertEqual(host.commands, [.toggleFold, .unfoldAll, .nextHeading, .previousHeading])
  }

  func testScrollCommandsMoveCursor() {
    setUp((1...60).map { "line \($0)" }.joined(separator: "\n"))
    type("<C-d>")
    XCTAssertEqual(VimText.lineIndex(host.storage, cursor), 5)
    XCTAssertEqual(host.visibleLines.lowerBound, 5)
    type("L")
    XCTAssertEqual(VimText.lineIndex(host.storage, cursor), 14)
    type("H")
    XCTAssertEqual(VimText.lineIndex(host.storage, cursor), 5)
  }

  func testLargeDocumentMotionsStayLocal() {
    let line = String(repeating: "word ", count: 20)
    let document = Array(repeating: line, count: 20_000).joined(separator: "\n")
    setUp(document, cursor: (document as NSString).length / 2)
    let start = Date()
    for _ in 0..<2_000 {
      for key in ["w", "j", "b", "k", "e", "f", "d", "$", "0", "l", "h"] {
        vim.handle(key)
      }
    }
    let perKey = Date().timeIntervalSince(start) / 22_000
    // Each key must stay far below a frame even in a debug build.
    XCTAssertLessThan(perKey, 0.002, "\(perKey * 1000) ms per key")
    // A paragraph motion across a 2 MB file with no blank lines is one scan.
    let paragraphStart = Date()
    vim.handle("}")
    vim.handle("{")
    XCTAssertLessThan(Date().timeIntervalSince(paragraphStart), 0.5)
    XCTAssertEqual(text, document, "motions do not edit")
  }

  func testMoveClampsOutOfRangeTarget() {
    setUp("a\nb\nc\n")
    type(":1m$+5<CR>")
    XCTAssertEqual(text, "b\nc\na\n")
  }

  /// Random key sequences must never crash or leave the cursor out of bounds.
  func testRandomKeySequencesStayConsistent() {
    var generator = SplitMix64(seed: 0x5EED)
    let pool: [VimKey] = [
      "h", "j", "k", "l", "w", "b", "e", "W", "B", "E", "0", "^", "$", "G", "g", "{", "}", "(", ")", "%",
      "f", "t", "F", "T", ";", ",", "x", "X", "d", "c", "y", "p", "P", "u", "<C-r>", ".", "i", "a", "o",
      "O", "A", "I", "<Esc>", "<Esc>", "v", "V", "<C-v>", "r", "~", "J", ">", "<", "\"", "q", "@", "m",
      "'", "`", "n", "N", "*", "#", "/", "?", ":", "s", "%", "<CR>", "<BS>", "<C-w>", "<C-u>", "<C-a>",
      "<C-x>", "<C-d>", "<C-o>", "R", "S", "C", "D", "Y", "z", "Z", "1", "2", "3", "&", " ", "i", "a",
      "(", "[", "{", "\"", "'", "<Tab>", "H", "M", "L", "-", "+", "_", "|", "#", "!"
    ]
    let documents = [
      "", "\n", "x", "* Heading\n  - item (one) \"two\"\n\n#+begin_src\ncode [a]\n#+end_src\n",
      "été 😀 naïve\n\tTab\n\n\nend", "a\nb"
    ]
    for document in documents {
      setUp(document)
      for _ in 0..<3_000 {
        let key = pool[Int(generator.next() % UInt64(pool.count))]
        type(key)
        let length = host.storage.length
        for range in host.selections {
          XCTAssertLessThanOrEqual(range.location + range.length, length)
        }
      }
    }
  }
}

private struct SplitMix64 {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
