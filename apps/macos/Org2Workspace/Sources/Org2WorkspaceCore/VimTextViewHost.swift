import AppKit

/// Per-editor Vim state kept beside the native text view.
@MainActor
final class VimTextViewState {
  enum MarkerKind {
    case start
    case end
  }

  let engine: VimEngine
  let statusView = VimStatusView()
  var isProcessingKey = false
  var isPerformingHistory = false
  var editCounter = 0
  var editCounterAtKeyStart = 0
  var nextSessionID = 0
  var activeSessionID: Int?
  var sessionHasStartMarker = false
  var pendingStartMarker = false
  var undoneStartMarkers: Set<Int> = []
  var firedMarkers: [(kind: MarkerKind, id: Int)] = []

  init(engine: VimEngine) {
    self.engine = engine
  }
}

/// The compact mode line drawn over the bottom edge of the source editor.
final class VimStatusView: NSView {
  private var text = ""
  private var tint: NSColor = .controlAccentColor
  private var isError = false
  private var isCommandLine = false
  private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
  private static let padding = NSSize(width: 7, height: 3)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityIdentifier("vim-mode-status")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private var attributes: [NSAttributedString.Key: Any] {
    [.font: Self.font, .foregroundColor: isError && !isCommandLine ? NSColor.systemRed : NSColor.labelColor]
  }

  override var fittingSize: NSSize {
    let size = (text as NSString).size(withAttributes: attributes)
    return NSSize(width: ceil(size.width) + Self.padding.width * 2, height: ceil(size.height) + Self.padding.height * 2)
  }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 5, yRadius: 5)
    NSColor.textBackgroundColor.withAlphaComponent(0.92).setFill()
    path.fill()
    tint.withAlphaComponent(isCommandLine ? 0.10 : 0.16).setFill()
    path.fill()
    tint.withAlphaComponent(0.4).setStroke()
    path.lineWidth = 0.5
    path.stroke()
    let textRect = bounds.insetBy(dx: Self.padding.width, dy: Self.padding.height)
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingHead
    var drawAttributes = attributes
    drawAttributes[.paragraphStyle] = style
    (text as NSString).draw(in: textRect, withAttributes: drawAttributes)
  }

  func update(_ status: VimStatus) {
    var parts: [String] = []
    if let commandLine = status.commandLine {
      parts.append(commandLine + "▏")
    } else if let message = status.message {
      parts.append(message)
    } else {
      parts.append(status.modeLabel)
    }
    if !status.pendingKeys.isEmpty, status.commandLine == nil {
      parts.append(status.pendingKeys)
    }
    if let register = status.recordingRegister {
      parts.append("recording @\(register)")
    }
    text = parts.joined(separator: "   ")
    switch status.mode {
    case .insert: tint = .systemGreen
    case .replace: tint = .systemRed
    case .visual, .visualLine, .visualBlock: tint = .systemOrange
    case .commandLine: tint = .labelColor
    case .normal: tint = .controlAccentColor
    }
    isError = status.isError
    isCommandLine = status.commandLine != nil
    setAccessibilityValue(text)
    needsDisplay = true
  }
}

extension OrgSyntaxTextView {
  var isVimModeEnabled: Bool { vimState != nil }

  func setVimModeEnabled(_ enabled: Bool) {
    if enabled == isVimModeEnabled {
      if enabled { attachVimStatusViewIfNeeded() }
      return
    }
    if enabled {
      let engine = VimEngine(host: self)
      let state = VimTextViewState(engine: engine)
      vimState = state
      attachVimStatusViewIfNeeded()
      let location = VimText.clampNormal(vimText, selectedRange().location)
      if selectedRange().length == 0 {
        state.isProcessingKey = true
        setSelectedRange(NSRange(location: location, length: 0))
        state.isProcessingKey = false
      }
      vimStateDidChange()
    } else {
      if let state = vimState {
        if state.engine.mode == .insert || state.engine.mode == .replace {
          state.engine.reset()
        }
        state.statusView.removeFromSuperview()
      }
      vimState = nil
      updateInsertionPointStateAndRestartTimer(true)
      needsDisplay = true
    }
  }

  func attachVimStatusViewIfNeeded() {
    guard let state = vimState, let scrollView = enclosingScrollView else { return }
    let statusView = state.statusView
    guard statusView.superview !== scrollView else { return }
    statusView.removeFromSuperview()
    scrollView.addSubview(statusView, positioned: .above, relativeTo: nil)
    statusView.update(state.engine.status)
    layoutVimStatusView()
  }

  /// Pins the mode line to the scroll view's lower-right corner.
  func layoutVimStatusView() {
    guard let state = vimState, let scrollView = state.statusView.superview else { return }
    let statusView = state.statusView
    let fitting = statusView.fittingSize
    let bounds = scrollView.bounds
    let width = min(ceil(fitting.width), max(60, bounds.width * 0.9))
    let height = ceil(fitting.height)
    let x = bounds.maxX - width - 14
    let y = scrollView.isFlipped ? bounds.maxY - height - 8 : bounds.minY + 8
    statusView.autoresizingMask = [.minXMargin, scrollView.isFlipped ? .minYMargin : .maxYMargin]
    statusView.frame = NSRect(x: x, y: y, width: width, height: height)
  }

  // MARK: Key handling

  /// Routes a key event through Vim. Returns true when Vim consumed it.
  func handleVimKeyDown(_ event: NSEvent) -> Bool {
    guard let state = vimState else { return false }
    if hasMarkedText() { return false }
    let engine = state.engine
    guard let keys = Self.vimKeys(for: event) else {
      return false
    }
    if keys.isEmpty {
      return engine.mode != .insert
    }
    state.isProcessingKey = true
    state.editCounterAtKeyStart = state.editCounter
    defer { state.isProcessingKey = false }
    if engine.mode == .insert, keys.first == "<Esc>" || keys.first == "<C-c>" {
      // Let an open completion panel dismiss before leaving Insert mode.
      _ = delegate?.textView?(self, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }
    var handledAll = true
    for key in keys where !engine.handle(key) {
      handledAll = false
    }
    return handledAll
  }

  func handleVimKeyEquivalent(_ event: NSEvent) -> Bool {
    guard let state = vimState else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if state.engine.mode == .commandLine, modifiers == .command,
       event.charactersIgnoringModifiers?.lowercased() == "v" {
      state.engine.pasteIntoCommandLine(NSPasteboard.general.string(forType: .string) ?? "")
      return true
    }
    return false
  }

  /// Translates an AppKit key event into Vim keys. Typed characters come
  /// from the active keyboard layout, so Dvorak, Colemak, AZERTY, and other
  /// layouts map to the characters printed on their keys.
  static func vimKeys(for event: NSEvent) -> [VimKey]? {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command) { return nil }
    let plain = modifiers.subtracting([.function, .numericPad, .capsLock]).isEmpty
    switch event.keyCode {
    case 53: return ["<Esc>"]
    case 36, 76: return modifiers.intersection([.shift, .option, .control]).isEmpty ? ["<CR>"] : nil
    case 48: return plain ? ["<Tab>"] : nil
    case 51: return plain ? ["<BS>"] : nil
    case 117: return plain ? ["<Del>"] : nil
    case 123: return plain ? ["<Left>"] : nil
    case 124: return plain ? ["<Right>"] : nil
    case 125: return plain ? ["<Down>"] : nil
    case 126: return plain ? ["<Up>"] : nil
    case 115: return plain ? ["<Home>"] : nil
    case 119: return plain ? ["<End>"] : nil
    case 116: return plain ? ["<PageUp>"] : nil
    case 121: return plain ? ["<PageDown>"] : nil
    default: break
    }
    if modifiers.contains(.control) {
      guard let characters = event.charactersIgnoringModifiers?.lowercased(),
            characters.count == 1,
            let character = characters.first
      else { return nil }
      if character == "[" { return ["<Esc>"] }
      guard character.isASCII, character.isLetter else { return nil }
      return ["<C-\(character)>"]
    }
    guard let characters = event.characters else { return [] }
    if characters.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains(Int($0.value)) }) {
      return nil
    }
    return characters.map { character -> VimKey in
      switch character {
      case "\u{1b}": return "<Esc>"
      case "\r": return "<CR>"
      case "\t": return "<Tab>"
      case "\u{7f}": return "<BS>"
      default: return String(character)
      }
    }
  }

  /// Keeps Vim's mode consistent with selections made outside Vim.
  func vimSelectionDidChange(stillSelecting: Bool) {
    guard let state = vimState, !state.isProcessingKey, !stillSelecting else { return }
    let range = selectedRange()
    if state.isPerformingHistory || undoManager?.isUndoing == true || undoManager?.isRedoing == true {
      guard state.engine.mode == .normal || state.engine.mode.isVisual else { return }
      if state.engine.mode.isVisual { state.engine.mode = .normal }
      applyVimCorrection(NSRange(location: VimText.clampNormal(vimText, range.location), length: 0))
      vimStateDidChange()
      return
    }
    if let corrected = state.engine.selectionDidChangeExternally(range) {
      applyVimCorrection(corrected)
    }
  }

  private func applyVimCorrection(_ range: NSRange) {
    guard let state = vimState else { return }
    let wasProcessing = state.isProcessingKey
    state.isProcessingKey = true
    setSelectedRange(range)
    state.isProcessingKey = wasProcessing
  }

  func vimNoteShouldChangeText() {
    guard let state = vimState, state.pendingStartMarker else { return }
    state.pendingStartMarker = false
    if let id = state.activeSessionID {
      registerVimUndoMarker(.start, id: id)
      state.sessionHasStartMarker = true
    }
  }

  func vimNoteDidChangeText() {
    vimState?.editCounter &+= 1
  }

  func vimFocusDidResign() {
    guard let state = vimState else { return }
    if state.engine.mode == .commandLine || !state.engine.pending.isEmpty {
      state.engine.reset()
    }
  }

  // MARK: Block cursor

  func vimCursorRect(for rect: NSRect) -> NSRect? {
    guard let state = vimState else { return nil }
    let engine = state.engine
    guard engine.usesBlockCursor || engine.mode == .replace else { return nil }
    var block = rect
    block.size.width = vimCharacterWidth(at: selectedRange().location)
    if engine.mode == .replace {
      block.origin.y = rect.maxY - 2
      block.size.height = 2
    }
    return block
  }

  func vimCharacterWidth(at location: Int) -> CGFloat {
    let text = vimText
    let fallbackFont = font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let fallback = max(2, (" " as NSString).size(withAttributes: [.font: fallbackFont]).width)
    guard location < text.length,
          text.character(at: location) != VimText.newline,
          let layoutManager,
          let textContainer
    else { return fallback }
    let characterRange = text.rangeOfComposedCharacterSequence(at: location)
    let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return fallback }
    let bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    return bounds.width > 0.5 ? bounds.width : fallback
  }

  // MARK: Undo markers

  /// Marks the edges of an Insert session in the undo stack so `u` undoes the
  /// whole change (deletion plus typing) the way Vim does, while ⌘Z keeps
  /// AppKit's finer steps.
  func registerVimUndoMarker(_ kind: VimTextViewState.MarkerKind, id: Int) {
    undoManager?.registerUndo(withTarget: self) { target in
      MainActor.assumeIsolated {
        target.vimUndoMarkerFired(kind, id: id)
      }
    }
  }

  private func vimUndoMarkerFired(_ kind: VimTextViewState.MarkerKind, id: Int) {
    vimState?.firedMarkers.append((kind, id))
    if kind == .start, undoManager?.isUndoing == true, vimState?.activeSessionID == id {
      vimState?.undoneStartMarkers.insert(id)
    }
    registerVimUndoMarker(kind, id: id)
  }
}

extension OrgSyntaxTextView: VimEditorHost {
  var vimText: NSString {
    textStorage?.mutableString ?? (string as NSString)
  }

  var vimSelectedRange: NSRange {
    selectedRange()
  }

  func vimSetSelectedRanges(_ ranges: [NSRange]) {
    guard !ranges.isEmpty else { return }
    let length = vimText.length
    let clamped = ranges.map { range -> NSValue in
      let location = min(max(0, range.location), length)
      return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
    }
    let wasProcessing = vimState?.isProcessingKey ?? false
    vimState?.isProcessingKey = true
    selectedRanges = clamped
    vimState?.isProcessingKey = wasProcessing
    let caret = vimState.map { $0.engine.mode.isVisual ? $0.engine.visualCursor : clamped[0].rangeValue.location } ?? 0
    scrollRangeToVisible(NSRange(location: min(caret, length), length: 0))
  }

  func vimReplaceCharacters(in range: NSRange, with text: String) {
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: text) else { return }
    let attributed = NSAttributedString(string: text, attributes: typingAttributes)
    textStorage?.replaceCharacters(in: range, with: attributed)
    didChangeText()
  }

  func vimTypeText(_ text: String) {
    insertText(text, replacementRange: selectedRange())
  }

  func vimOpenLineBelowPrefix(forLineAt location: Int) -> String? {
    guard continuesOrgStructure else { return nil }
    return OrgSourceTextEditing.openLineBelowPrefix(in: vimText, location: location)
  }

  func vimTypeNewline() {
    doCommand(by: #selector(NSResponder.insertNewline(_:)))
  }

  func vimTypeDeleteBackward() {
    doCommand(by: #selector(NSResponder.deleteBackward(_:)))
  }

  func vimTypeTab() {
    doCommand(by: #selector(NSResponder.insertTab(_:)))
  }

  func vimUndo() -> Bool {
    guard let state = vimState, let undoManager, undoManager.canUndo else { return false }
    state.isPerformingHistory = true
    defer { state.isPerformingHistory = false }
    state.firedMarkers = []
    undoManager.undo()
    if let end = state.firedMarkers.first(where: { $0.kind == .end }),
       !state.firedMarkers.contains(where: { $0.kind == .start && $0.id == end.id }) {
      var steps = 0
      while undoManager.canUndo, steps < 500,
            !state.firedMarkers.contains(where: { $0.kind == .start }) {
        undoManager.undo()
        steps += 1
      }
    }
    return true
  }

  func vimRedo() -> Bool {
    guard let state = vimState, let undoManager, undoManager.canRedo else { return false }
    state.isPerformingHistory = true
    defer { state.isPerformingHistory = false }
    state.firedMarkers = []
    undoManager.redo()
    if let start = state.firedMarkers.first(where: { $0.kind == .start }),
       !state.firedMarkers.contains(where: { $0.kind == .end && $0.id == start.id }) {
      var steps = 0
      while undoManager.canRedo, steps < 500,
            !state.firedMarkers.contains(where: { $0.kind == .end }) {
        undoManager.redo()
        steps += 1
      }
    }
    return true
  }

  func vimSave() -> Bool {
    performSaveShortcut()
  }

  func vimVisibleCharacterRange() -> NSRange {
    guard let layoutManager, let textContainer else {
      return NSRange(location: 0, length: vimText.length)
    }
    var rect = visibleRect
    rect.origin.x -= textContainerOrigin.x
    rect.origin.y -= textContainerOrigin.y
    let glyphRange = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: rect, in: textContainer)
    return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
  }

  private var vimLineHeight: CGFloat {
    let lineFont = font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    return layoutManager?.defaultLineHeight(for: lineFont) ?? 16
  }

  func vimScroll(lines: Int) {
    guard let scrollView = enclosingScrollView else { return }
    let clipView = scrollView.contentView
    var origin = clipView.bounds.origin
    let maxY = max(0, frame.height - clipView.bounds.height)
    origin.y = min(max(0, origin.y + CGFloat(lines) * vimLineHeight), maxY)
    clipView.scroll(to: origin)
    scrollView.reflectScrolledClipView(clipView)
  }

  func vimScrollCursor(to anchor: VimScrollAnchor) {
    guard let scrollView = enclosingScrollView, let layoutManager, let textContainer, vimText.length > 0 else { return }
    let location = min(selectedRange().location, vimText.length)
    let glyphIndex = layoutManager.glyphIndexForCharacter(at: max(0, min(location, max(0, vimText.length - 1))))
    var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    lineRect.origin.y += textContainerOrigin.y
    _ = textContainer
    let clipView = scrollView.contentView
    let height = clipView.bounds.height
    var y: CGFloat
    switch anchor {
    case .top: y = lineRect.minY - textContainerInset.height
    case .center: y = lineRect.midY - height / 2
    case .bottom: y = lineRect.maxY - height + textContainerInset.height
    }
    y = min(max(0, y), max(0, frame.height - height))
    clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
    scrollView.reflectScrolledClipView(clipView)
  }

  func vimDisplayLineLocation(from location: Int, down: Bool, count: Int) -> Int? {
    let saved = selectedRanges
    let wasProcessing = vimState?.isProcessingKey ?? false
    vimState?.isProcessingKey = true
    defer { vimState?.isProcessingKey = wasProcessing }
    setSelectedRange(NSRange(location: location, length: 0))
    for _ in 0..<max(1, count) {
      if down { moveDown(nil) } else { moveUp(nil) }
    }
    let result = selectedRange().location
    selectedRanges = saved
    return result == location ? nil : result
  }

  func vimPerform(_ command: VimEditorCommand) -> Bool {
    let sourceCommand: OrgSourceEditorCommand
    switch command {
    case .toggleFold: sourceCommand = .toggleFold
    case .unfoldAll: sourceCommand = .unfoldAll
    case .previousHeading: sourceCommand = .previousHeading
    case .nextHeading: sourceCommand = .nextHeading
    }
    return onSourceEditorCommand?(sourceCommand, self) == true
  }

  func vimClipboardString() -> String? {
    NSPasteboard.general.string(forType: .string)
  }

  func vimSetClipboardString(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }

  func vimFlash(_ range: NSRange) {
    guard range.length > 0, range.location + range.length <= vimText.length else { return }
    showFindIndicator(for: range)
  }

  func vimBeep() {}

  func vimInsertSessionDidBegin() {
    guard let state = vimState else { return }
    state.nextSessionID += 1
    state.activeSessionID = state.nextSessionID
    state.sessionHasStartMarker = false
    state.pendingStartMarker = false
    if state.editCounter != state.editCounterAtKeyStart {
      // The command already edited text in this event (c, o, O).
      registerVimUndoMarker(.start, id: state.nextSessionID)
      state.sessionHasStartMarker = true
    } else {
      state.pendingStartMarker = true
    }
  }

  func vimInsertSessionDidEnd() {
    guard let state = vimState, let id = state.activeSessionID else { return }
    if state.sessionHasStartMarker, !state.undoneStartMarkers.contains(id) {
      registerVimUndoMarker(.end, id: id)
    }
    state.undoneStartMarkers.remove(id)
    state.activeSessionID = nil
    state.pendingStartMarker = false
    state.sessionHasStartMarker = false
    breakUndoCoalescing()
  }

  func vimStateDidChange() {
    guard let state = vimState else { return }
    state.statusView.update(state.engine.status)
    layoutVimStatusView()
    updateInsertionPointStateAndRestartTimer(true)
    let location = min(selectedRange().location, vimText.length)
    if let layoutManager, let textContainer, vimText.length > 0 {
      let glyph = layoutManager.glyphIndexForCharacter(at: max(0, min(location, vimText.length - 1)))
      var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      _ = textContainer
      rect.origin.y += textContainerOrigin.y
      rect.origin.x = 0
      rect.size.width = bounds.width
      setNeedsDisplay(rect, avoidAdditionalLayout: true)
    } else {
      needsDisplay = true
    }
  }
}
