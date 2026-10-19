import AppKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class VimTextViewHostTests: XCTestCase {
  private var window: NSWindow!
  private var scrollView: NSScrollView!
  private var textView: OrgSyntaxTextView!

  override func setUp() async throws {
    _ = NSApplication.shared
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    scrollView = NSScrollView(frame: window.contentView!.bounds)
    textView = OrgSyntaxTextView(frame: scrollView.bounds)
    textView.isEditable = true
    textView.isRichText = false
    textView.allowsUndo = true
    scrollView.documentView = textView
    window.contentView = scrollView
    window.makeFirstResponder(textView)
  }

  override func tearDown() async throws {
    textView.setVimModeEnabled(false)
    window.close()
    window = nil
    scrollView = nil
    textView = nil
  }

  private func load(_ text: String, cursor: Int = 0) {
    textView.string = text
    textView.undoManager?.removeAllActions()
    textView.setSelectedRange(NSRange(location: cursor, length: 0))
    textView.setVimModeEnabled(true)
  }

  private func press(_ keys: String) {
    for key in VimEngine.keys(from: keys) {
      let (characters, keyCode, modifiers): (String, UInt16, NSEvent.ModifierFlags) = switch key {
      case "<Esc>": ("\u{1b}", 53, [])
      case "<CR>": ("\r", 36, [])
      case "<BS>": ("\u{7f}", 51, [])
      case "<C-r>": ("r", 15, [.control])
      case "<C-v>": ("v", 9, [.control])
      case "<C-o>": ("o", 31, [.control])
      case "<C-w>": ("w", 13, [.control])
      case "<Tab>": ("\t", 48, [])
      default: (key, 0, [])
      }
      guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
      ) else {
        return XCTFail("Could not create key event for \(key)")
      }
      textView.keyDown(with: event)
      // Each key is its own event; let AppKit close its undo group.
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
  }

  private var mode: VimMode? { textView.vimState?.engine.mode }

  func testNormalModeKeysEditAndInsertModeTypes() {
    load("hello world")
    press("dw")
    XCTAssertEqual(textView.string, "world")
    press("ihey <Esc>")
    XCTAssertEqual(textView.string, "hey world")
    XCTAssertEqual(mode, .normal)
    XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))
  }

  func testUndoTreatsChangeAndTypingAsOneStep() {
    load("one two three")
    press("wciwTWO<Esc>")
    XCTAssertEqual(textView.string, "one TWO three")
    press("u")
    XCTAssertEqual(textView.string, "one two three")
    press("<C-r>")
    XCTAssertEqual(textView.string, "one TWO three")
    press("u")
    press("dd")
    XCTAssertEqual(textView.string, "")
    press("u")
    XCTAssertEqual(textView.string, "one two three")
    XCTAssertEqual(mode, .normal)
  }

  func testEmptyInsertDoesNotSwallowUndo() {
    load("abc")
    press("x")
    press("i<Esc>")
    press("u")
    XCTAssertEqual(textView.string, "abc")
  }

  func testBlockCursorOnlyOutsideInsertMode() {
    load("abc")
    let caret = NSRect(x: 0, y: 0, width: 1, height: 14)
    XCTAssertNotNil(textView.vimCursorRect(for: caret))
    XCTAssertGreaterThan(textView.vimCursorRect(for: caret)?.width ?? 0, 1)
    press("i")
    XCTAssertNil(textView.vimCursorRect(for: caret))
    press("<Esc>")
    XCTAssertNotNil(textView.vimCursorRect(for: caret))
  }

  func testStatusViewShowsModeAndCommandLine() {
    load("abc")
    let status = textView.vimState?.statusView
    XCTAssertTrue(status?.superview === scrollView)
    XCTAssertEqual(status?.accessibilityValue() as? String, "NORMAL")
    press("v")
    XCTAssertEqual(status?.accessibilityValue() as? String, "-- VISUAL --")
    press("<Esc>:s/b")
    XCTAssertEqual(status?.accessibilityValue() as? String, ":s/b▏")
    press("/X/<CR>")
    XCTAssertEqual(textView.string, "aXc")
  }

  func testMouseSelectionEntersVisualAndClicksClampToLine() {
    load("ab\ncd")
    textView.setSelectedRange(NSRange(location: 0, length: 2))
    XCTAssertEqual(mode, .visual)
    press("d")
    XCTAssertEqual(textView.string, "\ncd")
    textView.setSelectedRange(NSRange(location: 3, length: 0))
    XCTAssertEqual(mode, .normal)
    XCTAssertEqual(textView.selectedRange().location, 2, "Normal mode never rests on a line end")
  }

  func testVisualBlockShowsOneSelectionPerLine() {
    load("abcd\nefgh\nijkl", cursor: 1)
    press("<C-v>jjl")
    XCTAssertEqual(textView.selectedRanges.map(\.rangeValue), [
      NSRange(location: 1, length: 2),
      NSRange(location: 6, length: 2),
      NSRange(location: 11, length: 2)
    ])
  }

  func testDisablingVimRestoresNativeTyping() {
    load("abc")
    textView.setVimModeEnabled(false)
    XCTAssertNil(textView.vimState)
    press("x")
    XCTAssertEqual(textView.string, "xabc")
  }

  func testKeyTranslationFollowsLayoutCharacters() {
    func event(_ characters: String, ignoring: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode
      )!
    }
    // Dvorak: the physical QWERTY "d" key types "e".
    XCTAssertEqual(OrgSyntaxTextView.vimKeys(for: event("e", ignoring: "e", keyCode: 2)), ["e"])
    XCTAssertEqual(OrgSyntaxTextView.vimKeys(for: event("\u{4}", ignoring: "d", keyCode: 2, modifiers: .control)), ["<C-d>"])
    XCTAssertEqual(OrgSyntaxTextView.vimKeys(for: event("\u{1b}", ignoring: "[", keyCode: 33, modifiers: .control)), ["<Esc>"])
    XCTAssertNil(OrgSyntaxTextView.vimKeys(for: event("s", ignoring: "s", keyCode: 1, modifiers: .command)))
    XCTAssertNil(OrgSyntaxTextView.vimKeys(for: event("", ignoring: "", keyCode: 123, modifiers: [.shift, .function])))
    XCTAssertEqual(OrgSyntaxTextView.vimKeys(for: event("", ignoring: "", keyCode: 123, modifiers: [.function, .numericPad])), ["<Left>"])
  }

  /// Random keys against the real text view and undo manager must not throw.
  func testRandomKeysWithNativeUndoStayConsistent() {
    load("* Heading\n  - one (two) \"three\"\n\nlast line\n")
    var state: UInt64 = 42
    let pool = ["h", "j", "k", "l", "w", "b", "x", "d", "c", "i", "a", "o", "O", "<Esc>", "<Esc>", "u", "u",
                "<C-r>", ".", "v", "V", "<C-v>", "p", "P", "y", "J", "r", "R", "<BS>", "<CR>", "z", "q", "@",
                "A", "s", "S", "e", "$", "0", "G", "g", "/", ":", "<C-o>", "<C-w>", "1", "2", "%", "f", "t"]
    for _ in 0..<600 {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      let key = pool[Int((state >> 33) % UInt64(pool.count))]
      press(key)
      let length = (textView.string as NSString).length
      XCTAssertLessThanOrEqual(NSMaxRange(textView.selectedRange()), length)
    }
    press("<Esc><Esc>")
    while textView.undoManager?.canUndo == true { textView.undoManager?.undo() }
    XCTAssertEqual(textView.string, "* Heading\n  - one (two) \"three\"\n\nlast line\n")
  }
}
