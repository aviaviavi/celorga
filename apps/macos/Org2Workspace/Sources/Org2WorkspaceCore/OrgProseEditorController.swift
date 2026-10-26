import AppKit
import SwiftUI

struct OrgProseSelectionState: Equatable {
  var hasSelection = false
  /// Zero-based index of the active version when the caret is in an alternative.
  var alternativeIndex: Int?
  var alternativeCount = 0
  var isInGhost = false
  /// The active version at the cursor came from a model request.
  var activeVariantIsAI = false

  var isInAlternative: Bool { alternativeIndex != nil }
}

/// The "Revise with AI" popover for one captured span.
struct OrgProseRevisionDraft: Identifiable, Equatable {
  let id = UUID()
  let target: OrgProseRevisionTarget
}

/// A revision request in flight.
struct OrgProseRevisionJob: Identifiable, Equatable {
  let id = UUID()
  let draft: OrgProseRevisionDraft
  let instruction: String
  let label: String
  let model: String
}

struct OrgProseAlternativeDraft: Identifiable, Equatable {
  let id = UUID()
  let selection: NSRange
  /// What the author is replacing (the selection or the active version).
  let currentText: String
  let addsToExisting: Bool
}

/// Hides a character range by giving its glyphs the null property. Unlike
/// text attributes this survives every highlighting pass, and the source text
/// is never touched.
@MainActor
final class OrgProseGlyphHider: NSObject, @preconcurrency NSLayoutManagerDelegate {
  var hiddenRange: NSRange?

  func layoutManager(
    _ layoutManager: NSLayoutManager,
    shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
    properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
    characterIndexes charIndexes: UnsafePointer<Int>,
    font aFont: NSFont,
    forGlyphRange glyphRange: NSRange
  ) -> Int {
    guard let hidden = hiddenRange, hidden.length > 0 else { return 0 }
    let count = glyphRange.length
    var touchesHidden = false
    for index in 0..<count where NSLocationInRange(charIndexes[index], hidden) {
      touchesHidden = true
      break
    }
    guard touchesHidden else { return 0 }
    var adjusted = Array(UnsafeBufferPointer(start: props, count: count))
    for index in 0..<count where NSLocationInRange(charIndexes[index], hidden) {
      adjusted[index] = .null
    }
    adjusted.withUnsafeBufferPointer { buffer in
      layoutManager.setGlyphs(
        glyphs,
        properties: buffer.baseAddress!,
        characterIndexes: charIndexes,
        font: aFont,
        forGlyphRange: glyphRange
      )
    }
    return count
  }
}

/// Connects the pure Prose engine to one native text view. It never owns the
/// document: every action reads the live buffer, computes a full replacement,
/// and applies it as a single undoable edit.
@MainActor
final class OrgProseEditorController: NSObject, ObservableObject, NSMenuItemValidation {
  @Published private(set) var snapshot = OrgProseSnapshot()
  @Published private(set) var selectionState = OrgProseSelectionState()
  @Published private(set) var message: String?
  @Published private(set) var messageIsError = false
  @Published var alternativeDraft: OrgProseAlternativeDraft?
  @Published var revisionDraft: OrgProseRevisionDraft?
  @Published private(set) var revisionJob: OrgProseRevisionJob?
  /// The last failure for the open revision popover, kept apart from the
  /// toolbar message so a retry starts clean.
  @Published private(set) var revisionError: String?
  @Published var revealsGhosts = false {
    didSet { applyPresentation() }
  }

  var onStatus: ((String) -> Void)?
  var now: () -> Date = { Date() }
  private(set) weak var textView: NSTextView?

  private let glyphHider = OrgProseGlyphHider()
  private var isApplyingEdit = false
  private var refreshTask: Task<Void, Never>?
  private var revisionTask: Task<Void, Never>?
  private var presentationRanges: [NSRange] = []

  // MARK: Attachment

  func attach(to textView: NSTextView) {
    guard self.textView !== textView else { return }
    detachCurrent()
    self.textView = textView
    textView.layoutManager?.delegate = glyphHider
    refreshNow()
  }

  func detach(from textView: NSTextView) {
    guard self.textView === textView else { return }
    detachCurrent()
    self.textView = nil
  }

  private func detachCurrent() {
    refreshTask?.cancel()
    abandonRevision()
    if let layoutManager = textView?.layoutManager {
      clearPresentation(in: layoutManager)
      if layoutManager.delegate === glyphHider { layoutManager.delegate = nil }
    }
    glyphHider.hiddenRange = nil
  }

  // MARK: Change tracking

  /// The document was replaced wholesale (open, switch, external change).
  func textWasReplaced() {
    // A pending revision belongs to the text it was started on; never apply
    // it to a different or externally replaced document.
    abandonRevision()
    refreshNow()
  }

  func textDidChange() {
    refreshTask?.cancel()
    refreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else { return }
      self?.refreshNow()
    }
  }

  /// Keeps the hidden range aligned with edits before the next refresh.
  func noteStorageEdit(priorRange: NSRange, delta: Int) {
    guard let hidden = glyphHider.hiddenRange else { return }
    if NSMaxRange(priorRange) <= hidden.location {
      glyphHider.hiddenRange = NSRange(location: hidden.location + delta, length: hidden.length)
    } else if priorRange.location >= NSMaxRange(hidden) {
      return
    } else {
      glyphHider.hiddenRange = nil
    }
  }

  func refreshNow() {
    refreshTask?.cancel()
    guard let textView else {
      snapshot = OrgProseSnapshot()
      return
    }
    snapshot = OrgProseSnapshot.make(for: textView.string)
    applyPresentation()
    updateSelectionState()
    normalizeTypingAttributes(in: textView)
  }

  func selectionDidChange() {
    guard let textView else { return }
    clampCaretOutOfHiddenState(in: textView)
    updateSelectionState()
    normalizeTypingAttributes(in: textView)
  }

  /// Keeps the insertion-point size tied to the base Prose face. Without this
  /// the caret inherits the font of whatever run it sits on, which swings
  /// from hidden-syntax's near-zero font to enlarged headings.
  private func normalizeTypingAttributes(in textView: NSTextView) {
    textView.typingAttributes = OrgSyntaxHighlighter.baseTypingAttributes(monospaced: false, prose: true)
  }

  /// Clicking the prose margin (outside the text column) should collapse the
  /// selection so its highlight does not stay on screen.
  func clearSelectionKeepingCaret() {
    guard let textView else { return }
    let range = textView.selectedRange()
    guard range.length > 0 else { return }
    textView.setSelectedRange(NSRange(location: range.location, length: 0))
  }

  private func clampCaretOutOfHiddenState(in textView: NSTextView) {
    guard let hidden = glyphHider.hiddenRange else { return }
    let selection = textView.selectedRange()
    guard selection.length == 0 else { return }
    let length = textView.textStorage?.length ?? 0
    let end = NSMaxRange(hidden)
    guard selection.location >= hidden.location,
          selection.location < end || end == length
    else { return }
    textView.setSelectedRange(NSRange(location: max(0, hidden.location - 1), length: 0))
  }

  private func updateSelectionState() {
    guard let textView else { return }
    let selection = textView.selectedRange()
    var next = OrgProseSelectionState()
    let touchesState = snapshot.blockRange.map { NSIntersectionRange(selection, $0).length > 0 } ?? false
    next.hasSelection = selection.length > 0 && !touchesState && snapshot.isUsable
    if let match = snapshot.alternative(containing: selection), let index = match.set.activeIndex {
      next.alternativeIndex = index
      next.alternativeCount = match.set.variants.count
      next.activeVariantIsAI = match.set.variants[index].isAI
    }
    next.isInGhost = snapshot.state.ghosts.contains { ghost in
      guard let range = snapshot.resolution(for: ghost.id).range else { return false }
      return selection.length == 0
        ? selection.location >= range.location && selection.location <= NSMaxRange(range)
        : NSIntersectionRange(selection, range).length > 0
    }
    if next != selectionState { selectionState = next }
  }

  // MARK: Edit protection

  /// Ordinary typing may not alter the hidden state block; Source mode is the
  /// place for that. Undo and redo, and the controller's own edits, pass.
  func allowsEdit(in range: NSRange, replacement: String?, textView: NSTextView) -> Bool {
    if isApplyingEdit { return true }
    if let undoManager = textView.undoManager, undoManager.isUndoing || undoManager.isRedoing {
      return true
    }
    guard let hidden = glyphHider.hiddenRange else { return true }
    let intersects = range.length > 0
      ? NSIntersectionRange(range, hidden).length > 0
      : range.location > hidden.location && range.location < NSMaxRange(hidden)
    let fusesWithStart = range.length == 0 && range.location == hidden.location
    var fusesWithEnd = false
    if range.length == 0, range.location == NSMaxRange(hidden), hidden.length > 0,
       let storage = textView.textStorage?.mutableString,
       storage.character(at: NSMaxRange(hidden) - 1) != 0x0A {
      fusesWithEnd = true
    }
    guard intersects || fusesWithStart || fusesWithEnd else { return true }
    NSSound.beep()
    report(
      "The hidden prose state is protected here. Switch to Source mode to edit it.",
      isError: true
    )
    return false
  }

  // MARK: Presentation

  private func applyPresentation() {
    guard let textView, let layoutManager = textView.layoutManager,
          let length = textView.textStorage?.length
    else { return }
    clearPresentation(in: layoutManager)

    let newHidden = snapshot.blockRange.map { clamp($0, length: length) }
    if newHidden != glyphHider.hiddenRange {
      let old = glyphHider.hiddenRange
      glyphHider.hiddenRange = newHidden
      for range in [old, newHidden].compactMap({ $0 }) {
        let valid = clamp(range, length: length)
        guard valid.length > 0 else { continue }
        layoutManager.invalidateGlyphs(forCharacterRange: valid, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: valid, actualCharacterRange: nil)
      }
    }

    let ghostColor = NSColor.textColor.withAlphaComponent(revealsGhosts ? 0.8 : 0.28)
    for ghost in snapshot.state.ghosts {
      guard let range = snapshot.resolution(for: ghost.id).range else { continue }
      let valid = clamp(range, length: length)
      guard valid.length > 0 else { continue }
      layoutManager.addTemporaryAttribute(.foregroundColor, value: ghostColor, forCharacterRange: valid)
      if revealsGhosts {
        layoutManager.addTemporaryAttribute(
          .backgroundColor,
          value: NSColor.systemOrange.withAlphaComponent(0.14),
          forCharacterRange: valid
        )
      }
      presentationRanges.append(valid)
    }
    for set in snapshot.state.alternatives {
      guard let range = snapshot.resolution(for: set.id).range else { continue }
      let valid = clamp(range, length: length)
      guard valid.length > 0 else { continue }
      layoutManager.addTemporaryAttribute(
        .underlineStyle,
        value: NSUnderlineStyle.patternDot.union(.single).rawValue,
        forCharacterRange: valid
      )
      layoutManager.addTemporaryAttribute(
        .underlineColor,
        value: NSColor.controlAccentColor.withAlphaComponent(0.75),
        forCharacterRange: valid
      )
      presentationRanges.append(valid)
    }
  }

  private func clearPresentation(in layoutManager: NSLayoutManager) {
    let length = textView?.textStorage?.length ?? 0
    for range in presentationRanges {
      let valid = clamp(range, length: length)
      guard valid.length > 0 else { continue }
      for key in [
        NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor
      ] {
        layoutManager.removeTemporaryAttribute(key, forCharacterRange: valid)
      }
    }
    presentationRanges = []
  }

  private func clamp(_ range: NSRange, length: Int) -> NSRange {
    OrgProseEngine.clamp(range, length: length)
  }

  // MARK: Actions

  func beginAddAlternative() {
    guard let textView else { return }
    let selection = textView.selectedRange()
    if let match = snapshot.alternative(containing: selection),
       let active = match.set.variants.first(where: { $0.id == match.set.activeVariantID }) {
      alternativeDraft = OrgProseAlternativeDraft(
        selection: selection,
        currentText: active.text,
        addsToExisting: true
      )
      return
    }
    guard selection.length > 0 else {
      report(OrgProseError.emptySelection.localizedDescription, isError: true)
      return
    }
    let text = (textView.string as NSString).substring(with: selection)
    alternativeDraft = OrgProseAlternativeDraft(
      selection: selection,
      currentText: text,
      addsToExisting: false
    )
  }

  @discardableResult
  func commitAlternative(_ draft: OrgProseAlternativeDraft, versionText: String) -> Bool {
    let stamp = now()
    let succeeded = run { text, _ in
      try OrgProseEngine.addAlternative(
        to: text,
        selection: draft.selection,
        versionText: versionText,
        now: stamp
      )
    }
    if succeeded { alternativeDraft = nil }
    return succeeded
  }

  func cancelAlternativeDraft() {
    alternativeDraft = nil
  }

  // MARK: Revise with AI

  /// Opens the revision popover for the selection, or for the whole
  /// alternative at the cursor. While a request runs it reopens that request.
  func beginRevision() {
    if let job = revisionJob {
      revisionDraft = job.draft
      return
    }
    guard let textView else { return }
    do {
      let target = try OrgProseEngine.revisionTarget(in: textView.string, selection: textView.selectedRange())
      revisionError = nil
      revisionDraft = OrgProseRevisionDraft(target: target)
    } catch {
      report(error.localizedDescription, isError: true)
    }
  }

  /// Sends the one model request. The reply is applied only if the request is
  /// still current when it returns, and only as a new version of the span.
  func submitRevision(
    _ draft: OrgProseRevisionDraft,
    instruction: String,
    backend: OrgProseRevisionBackend
  ) {
    revisionTask?.cancel()
    revisionError = nil
    let job = OrgProseRevisionJob(
      draft: draft,
      instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
      label: backend.label,
      model: backend.model
    )
    revisionJob = job
    report("Revising with \(backend.label)…", isError: false)
    revisionTask = Task { [weak self] in
      do {
        let revised = try await OrgProseReviser.revise(
          target: draft.target,
          instruction: job.instruction,
          backend: backend
        )
        self?.finishRevision(job, revisedText: revised, providerKind: backend.providerKind)
      } catch {
        self?.failRevision(job, error: error)
      }
    }
  }

  /// Stops a running request (nothing is changed) or closes the popover.
  func cancelRevision() {
    guard revisionJob != nil else {
      revisionDraft = nil
      return
    }
    revisionTask?.cancel()
    revisionTask = nil
    revisionJob = nil
    report("Revision cancelled. Nothing was changed.", isError: false)
  }

  /// Reports a problem found before any request is sent, such as a missing
  /// provider or key.
  func reportRevisionError(_ text: String) {
    revisionError = text
    report(text, isError: true)
  }

  private func finishRevision(_ job: OrgProseRevisionJob, revisedText: String, providerKind: String) {
    guard revisionJob?.id == job.id else { return }
    revisionJob = nil
    revisionTask = nil
    let stamp = now()
    let provenance = OrgProseAIProvenance(
      provider: providerKind,
      model: job.model,
      instruction: job.instruction
    )
    let succeeded = run { text, _ in
      try OrgProseEngine.addAIRevision(
        to: text,
        target: job.draft.target,
        revisedText: revisedText,
        provenance: provenance,
        now: stamp
      )
    }
    if succeeded {
      if revisionDraft?.id == job.draft.id { revisionDraft = nil }
    } else {
      revisionError = message
    }
  }

  private func failRevision(_ job: OrgProseRevisionJob, error: Error) {
    guard revisionJob?.id == job.id else { return }
    revisionJob = nil
    revisionTask = nil
    guard !(error is CancellationError) else { return }
    revisionError = error.localizedDescription
    report(error.localizedDescription, isError: true)
  }

  private func abandonRevision() {
    revisionTask?.cancel()
    revisionTask = nil
    revisionJob = nil
    revisionDraft = nil
    revisionError = nil
  }

  func cycleAlternative(_ step: Int) {
    run { text, selection in
      try OrgProseEngine.cycleAlternative(in: text, selection: selection, step: step)
    }
  }

  func chooseVariant(alternativeID: String, variantID: String) {
    run { text, _ in
      try OrgProseEngine.chooseVariant(in: text, alternativeID: alternativeID, variantID: variantID)
    }
  }

  func dismissAlternative(id: String) {
    run { text, _ in try OrgProseEngine.dismissAlternative(in: text, id: id) }
  }

  func ghostSelection() {
    let stamp = now()
    run { text, selection in
      try OrgProseEngine.ghost(in: text, selection: selection, now: stamp)
    }
  }

  func reviveAtSelection() {
    run { text, selection in try OrgProseEngine.revive(in: text, selection: selection) }
  }

  func revive(ghostID: String) {
    run { text, _ in try OrgProseEngine.revive(in: text, ghostID: ghostID) }
  }

  func moveSelectionToOverflow() {
    let stamp = now()
    run { text, selection in
      try OrgProseEngine.moveToOverflow(in: text, selection: selection, now: stamp)
    }
  }

  /// With `atCursor` the fragment goes to the insertion point even if its
  /// anchor is gone; that is the explicit user action the unresolved case needs.
  func restoreOverflow(id: String, atCursor: Bool) {
    let cursor = textView?.selectedRange().location
    run { text, _ in
      try OrgProseEngine.restoreOverflow(
        in: text,
        id: id,
        insertionPoint: atCursor ? cursor : nil
      )
    }
  }

  func deleteOverflow(id: String) {
    run { text, _ in try OrgProseEngine.deleteOverflow(in: text, id: id) }
  }

  func reveal(range: NSRange) {
    guard let textView else { return }
    let valid = clamp(range, length: textView.textStorage?.length ?? 0)
    textView.window?.makeFirstResponder(textView)
    textView.setSelectedRange(valid)
    textView.scrollRangeToVisible(valid)
    textView.showFindIndicator(for: valid)
  }

  @discardableResult
  private func run(_ operation: (String, NSRange) throws -> OrgProseEdit) -> Bool {
    guard let textView else { return false }
    let text = textView.string
    let selection = textView.selectedRange()
    do {
      let edit = try operation(text, selection)
      apply(edit, replacing: text, in: textView, previousSelection: selection)
      report(edit.message, isError: false)
      return true
    } catch {
      report(error.localizedDescription, isError: true)
      return false
    }
  }

  private func apply(
    _ edit: OrgProseEdit,
    replacing oldText: String,
    in textView: NSTextView,
    previousSelection: NSRange
  ) {
    guard let diff = OrgProseTextDiff.replacement(from: oldText, to: edit.text) else { return }
    isApplyingEdit = true
    defer { isApplyingEdit = false }
    textView.window?.makeFirstResponder(textView)
    let undoManager = textView.undoManager
    undoManager?.beginUndoGrouping()
    textView.insertText(diff.replacement, replacementRange: diff.range)
    let length = textView.textStorage?.length ?? 0
    if let selection = edit.selection {
      let valid = clamp(selection, length: length)
      textView.setSelectedRange(valid)
      textView.scrollRangeToVisible(valid)
    } else {
      let delta = (diff.replacement as NSString).length - diff.range.length
      var restored = previousSelection
      if NSMaxRange(diff.range) <= restored.location { restored.location += delta }
      textView.setSelectedRange(clamp(restored, length: length))
    }
    undoManager?.setActionName(edit.message)
    undoManager?.endUndoGrouping()
    refreshNow()
  }

  private func report(_ text: String, isError: Bool) {
    message = text
    messageIsError = isError
    onStatus?(text)
  }

  // MARK: Context menu

  func augment(menu: NSMenu) {
    guard snapshot.isUsable else { return }
    menu.addItem(.separator())
    let submenu = NSMenu(title: "Prose")
    for (title, action) in [
      ("Add Alternative…", #selector(menuAddAlternative(_:))),
      ("Revise with AI…", #selector(menuReviseWithAI(_:))),
      ("Next Alternative", #selector(menuNextAlternative(_:))),
      ("Previous Alternative", #selector(menuPreviousAlternative(_:))),
      ("Ghost Selection", #selector(menuGhost(_:))),
      ("Revive Ghost", #selector(menuRevive(_:))),
      ("Move to Overflow", #selector(menuOverflow(_:)))
    ] {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      submenu.addItem(item)
    }
    let parent = NSMenuItem(title: "Prose", action: nil, keyEquivalent: "")
    parent.submenu = submenu
    menu.addItem(parent)

    // Surfaces the Prose shortcuts where users read menus; the buttons in
    // the toolbar bind the actual keys.
    for (title, key) in [
      ("Revise with AI…", "r"),
      ("Next Alternative", "]"),
      ("Previous Alternative", "[")
    ] {
      if let item = submenu.items.first(where: { $0.title == title }) {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = [.control, .option]
      }
    }
  }

  @objc private func menuAddAlternative(_ sender: Any?) { beginAddAlternative() }
  @objc private func menuReviseWithAI(_ sender: Any?) { beginRevision() }
  @objc private func menuNextAlternative(_ sender: Any?) { cycleAlternative(1) }
  @objc private func menuPreviousAlternative(_ sender: Any?) { cycleAlternative(-1) }
  @objc private func menuGhost(_ sender: Any?) { ghostSelection() }
  @objc private func menuRevive(_ sender: Any?) { reviveAtSelection() }
  @objc private func menuOverflow(_ sender: Any?) { moveSelectionToOverflow() }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(menuAddAlternative(_:)), #selector(menuReviseWithAI(_:)):
      return selectionState.hasSelection || selectionState.isInAlternative
    case #selector(menuNextAlternative(_:)), #selector(menuPreviousAlternative(_:)):
      return selectionState.alternativeCount > 1
    case #selector(menuGhost(_:)), #selector(menuOverflow(_:)):
      return selectionState.hasSelection
    case #selector(menuRevive(_:)):
      return selectionState.isInGhost
    default:
      return true
    }
  }
}
