import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class OrgProseEditorTests: XCTestCase {
  private struct Mounted {
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: OrgSyntaxTextView
    let coordinator: OrgSyntaxTextEditor.Coordinator
    let controller: OrgProseEditorController
    let undoManager: UndoManager
    var published: Box
  }

  private final class Box {
    var text: String
    init(_ text: String) { self.text = text }
  }

  private func mount(_ text: String) throws -> Mounted {
    let box = Box(text)
    let controller = OrgProseEditorController()
    let editor = OrgSyntaxTextEditor(
      text: Binding(get: { box.text }, set: { box.text = $0 }),
      textPublishing: .immediate,
      liveHighlighting: false,
      concealsSyntax: true,
      proseController: controller
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
    let textView = OrgSyntaxTextView(frame: scrollView.bounds)
    textView.isVerticallyResizable = true
    textView.allowsUndo = true
    textView.textContainer?.widthTracksTextView = true
    textView.string = text
    textView.delegate = coordinator
    scrollView.documentView = textView
    let window = NSWindow(
      contentRect: scrollView.bounds,
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    window.isReleasedWhenClosed = false
    window.contentView = scrollView
    coordinator.attach(to: textView)
    coordinator.recordKnownText(text, utf16Length: textView.textStorage?.length)
    coordinator.resetLineIndex(from: textView)
    controller.attach(to: textView)
    let undoManager = try XCTUnwrap(textView.undoManager)
    undoManager.groupsByEvent = false
    return Mounted(
      window: window,
      scrollView: scrollView,
      textView: textView,
      coordinator: coordinator,
      controller: controller,
      undoManager: undoManager,
      published: box
    )
  }

  private func select(_ needle: String, in mounted: Mounted) {
    let range = (mounted.textView.string as NSString).range(of: needle)
    XCTAssertNotEqual(range.location, NSNotFound, needle)
    mounted.textView.setSelectedRange(range)
    mounted.controller.selectionDidChange()
  }

  /// A typed edit, grouped the way the event loop would group it in the app.
  private func type(_ text: String, at range: NSRange, in mounted: Mounted) {
    mounted.undoManager.beginUndoGrouping()
    mounted.textView.insertText(text, replacementRange: range)
    mounted.undoManager.endUndoGrouping()
  }

  private func proseBody(_ text: String) throws -> String {
    try OrgProseContext(text: text).body as String
  }

  // MARK: Third presentation

  func testProseIsTheThirdEditorPresentationAndPersists() {
    XCTAssertEqual(SourceEditorPresentation.allCases, [.source, .split, .prose])
    XCTAssertEqual(SourceEditorPresentation.prose.title, "Prose")
    XCTAssertEqual(SourceEditorPresentation(rawValue: "prose"), .prose)

    let suiteName = "org2-prose-presentation-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    first.sourceEditorPresentation = .prose
    let restored = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    XCTAssertEqual(restored.sourceEditorPresentation, .prose)
  }

  func testProseTypographyIsProportionalSpacedAndConcealsSyntax() {
    let font = OrgSyntaxHighlighter.baseFont(monospaced: true, prose: true)
    XCTAssertFalse(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    XCTAssertEqual(font.pointSize, 17)

    let storage = NSTextStorage(string: "* A heading\nBody with [[https://example.com][a link]].\n")
    OrgSyntaxHighlighter.apply(to: storage, monospaced: false, concealsSyntax: true, prose: true)
    let stars = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    XCTAssertLessThan(try XCTUnwrap(stars).pointSize, 0.1)
    let title = storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
    XCTAssertGreaterThan(try XCTUnwrap(title).pointSize, 17)
    let bodyIndex = (storage.string as NSString).range(of: "Body").location
    let style = storage.attribute(.paragraphStyle, at: bodyIndex, effectiveRange: nil) as? NSParagraphStyle
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(style).lineSpacing, 8)

    let source = NSTextStorage(string: "* A heading\n")
    OrgSyntaxHighlighter.apply(to: source, monospaced: true, concealsSyntax: false)
    XCTAssertEqual((source.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, NSFont.systemFontSize)
  }

  // MARK: Selection-aware actions and persistence

  func testGhostSelectionKeepsBodyHidesStateAndPersistsAcrossReopen() throws {
    let original = "Intro.\n\nThe quick brown fox.\n"
    let mounted = try mount(original)
    select("quick brown", in: mounted)
    XCTAssertTrue(mounted.controller.selectionState.hasSelection)

    mounted.controller.ghostSelection()

    let saved = mounted.textView.string
    XCTAssertTrue(saved.hasPrefix(original))
    XCTAssertEqual(try proseBody(saved), original + "\n")
    XCTAssertEqual(mounted.controller.snapshot.state.ghosts.count, 1)
    XCTAssertEqual(mounted.controller.message, "Ghosted text")
    XCTAssertFalse(mounted.controller.messageIsError)
    XCTAssertEqual(mounted.textView.selectedRange(), (original as NSString).range(of: "quick brown"))

    // The state block is hidden from layout but still ordinary text.
    let block = try XCTUnwrap(mounted.controller.snapshot.blockRange)
    let layout = try XCTUnwrap(mounted.textView.layoutManager)
    layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: (saved as NSString).length))
    XCTAssertTrue(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: block.location)).contains(.null))
    XCTAssertFalse(layout.propertyForGlyph(at: layout.glyphIndexForCharacter(at: 0)).contains(.null))
    XCTAssertTrue(saved.contains("ORG2_PROSE_STATE_V1"))

    // Close and reopen: a fresh editor on the saved text sees the same ghost.
    let reopened = try mount(saved)
    XCTAssertEqual(reopened.controller.snapshot.state.ghosts.count, 1)
    let ghost = try XCTUnwrap(reopened.controller.snapshot.state.ghosts.first)
    XCTAssertEqual(
      reopened.controller.snapshot.resolution(for: ghost.id).range,
      (saved as NSString).range(of: "quick brown")
    )
    XCTAssertNotNil(reopened.controller.snapshot.blockRange)
  }

  func testGhostReviveAndMoveActionsAreUndoableAndRedoable() throws {
    let original = "Alpha beta gamma.\n"
    let mounted = try mount(original)

    select("beta", in: mounted)
    mounted.controller.ghostSelection()
    let ghosted = mounted.textView.string
    XCTAssertNotEqual(ghosted, original)

    mounted.undoManager.undo()
    XCTAssertEqual(mounted.textView.string, original)
    mounted.controller.textWasReplaced()
    XCTAssertTrue(mounted.controller.snapshot.state.ghosts.isEmpty)
    XCTAssertNil(mounted.controller.snapshot.blockRange)

    mounted.undoManager.redo()
    XCTAssertEqual(mounted.textView.string, ghosted)
    mounted.controller.textWasReplaced()
    XCTAssertEqual(mounted.controller.snapshot.state.ghosts.count, 1)

    select("beta", in: mounted)
    XCTAssertTrue(mounted.controller.selectionState.isInGhost)
    mounted.controller.reviveAtSelection()
    XCTAssertEqual(mounted.textView.string, original)
    mounted.undoManager.undo()
    XCTAssertEqual(mounted.textView.string, ghosted)
  }

  func testAlternativeWorkflowIsUndoableAndRevisitable() throws {
    let original = "Hello brave world.\n"
    let mounted = try mount(original)

    select("brave", in: mounted)
    mounted.controller.beginAddAlternative()
    let draft = try XCTUnwrap(mounted.controller.alternativeDraft)
    XCTAssertEqual(draft.currentText, "brave")
    XCTAssertTrue(mounted.controller.commitAlternative(draft, versionText: "bold"))
    XCTAssertNil(mounted.controller.alternativeDraft)
    XCTAssertTrue(try proseBody(mounted.textView.string).hasPrefix("Hello bold world."))
    XCTAssertEqual(mounted.controller.selectionState.alternativeIndex, 1)
    XCTAssertEqual(mounted.controller.selectionState.alternativeCount, 2)

    mounted.controller.cycleAlternative(-1)
    XCTAssertTrue(try proseBody(mounted.textView.string).hasPrefix("Hello brave world."))
    mounted.controller.cycleAlternative(1)
    XCTAssertTrue(try proseBody(mounted.textView.string).hasPrefix("Hello bold world."))

    mounted.undoManager.undo()
    XCTAssertTrue(try proseBody(mounted.textView.string).hasPrefix("Hello brave world."))
    mounted.undoManager.undo()
    XCTAssertTrue(try proseBody(mounted.textView.string).hasPrefix("Hello bold world."))
    mounted.undoManager.undo()
    XCTAssertEqual(mounted.textView.string, original)
  }

  func testOverflowParkAndRestoreThroughEditor() throws {
    let original = "Keep this.\n\nPark this paragraph.\n\nKeep that.\n"
    let mounted = try mount(original)
    select("Park this paragraph.\n\n", in: mounted)
    mounted.controller.moveSelectionToOverflow()

    XCTAssertEqual(mounted.controller.snapshot.state.overflow.count, 1)
    XCTAssertFalse(try proseBody(mounted.textView.string).contains("Park this"))
    let item = try XCTUnwrap(mounted.controller.snapshot.state.overflow.first)
    XCTAssertEqual(item.text, "Park this paragraph.\n\n")
    XCTAssertNotNil(mounted.controller.snapshot.resolution(for: item.id).range)

    mounted.controller.restoreOverflow(id: item.id, atCursor: false)
    XCTAssertEqual(mounted.textView.string, original)
    XCTAssertTrue(mounted.controller.snapshot.state.overflow.isEmpty)

    mounted.undoManager.undo()
    XCTAssertEqual(mounted.controller.snapshot.state.overflow.count, 0)
    mounted.controller.textWasReplaced()
    XCTAssertEqual(mounted.controller.snapshot.state.overflow.count, 1)
  }

  func testUnresolvedOverflowNeedsExplicitCursorRestore() throws {
    let original = "Alpha stays here.\n\nParked words.\n\nOmega stays too.\n"
    let mounted = try mount(original)
    select("Parked words.\n\n", in: mounted)
    mounted.controller.moveSelectionToOverflow()
    let id = try XCTUnwrap(mounted.controller.snapshot.state.overflow.first?.id)

    for (old, new) in [("Alpha stays here.", "New beginning."), ("Omega stays too.", "New ending.")] {
      let range = (mounted.textView.string as NSString).range(of: old)
      mounted.textView.setSelectedRange(range)
      type(new, at: range, in: mounted)
    }
    mounted.controller.refreshNow()
    XCTAssertNil(mounted.controller.snapshot.resolution(for: id).range)
    XCTAssertEqual(mounted.controller.snapshot.state.overflow.count, 1)

    let before = mounted.textView.string
    mounted.controller.restoreOverflow(id: id, atCursor: false)
    XCTAssertEqual(mounted.textView.string, before)
    XCTAssertTrue(mounted.controller.messageIsError)

    mounted.textView.setSelectedRange(NSRange(location: 0, length: 0))
    mounted.controller.restoreOverflow(id: id, atCursor: true)
    XCTAssertTrue(mounted.textView.string.hasPrefix("Parked words.\n\nNew beginning."))
    XCTAssertTrue(mounted.controller.snapshot.state.overflow.isEmpty)
  }

  // MARK: Safety

  func testHiddenStateBlockIsProtectedFromTypingButNotUndo() throws {
    let mounted = try mount("Intro text here.\n")
    select("text", in: mounted)
    mounted.controller.ghostSelection()
    let block = try XCTUnwrap(mounted.controller.snapshot.blockRange)
    let textView = mounted.textView

    XCTAssertFalse(mounted.coordinator.textView(
      textView,
      shouldChangeTextIn: NSRange(location: block.location + 5, length: 0),
      replacementString: "x"
    ))
    XCTAssertFalse(mounted.coordinator.textView(
      textView,
      shouldChangeTextIn: NSRange(location: 0, length: (textView.string as NSString).length),
      replacementString: ""
    ))
    XCTAssertFalse(mounted.coordinator.textView(
      textView,
      shouldChangeTextIn: NSRange(location: block.location, length: 0),
      replacementString: "x"
    ))
    XCTAssertTrue(mounted.coordinator.textView(
      textView,
      shouldChangeTextIn: NSRange(location: 2, length: 0),
      replacementString: "x"
    ))

    // The protected range follows ordinary edits before it.
    type("ZZ ", at: NSRange(location: 0, length: 0), in: mounted)
    XCTAssertFalse(mounted.coordinator.textView(
      textView,
      shouldChangeTextIn: NSRange(location: block.location + 3 + 5, length: 0),
      replacementString: "x"
    ))
    XCTAssertTrue(mounted.controller.messageIsError)
  }

  func testMalformedStateBlockIsNeverRewrittenByProseActions() throws {
    let text = "Body text here.\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{broken\n#+END_COMMENT\n"
    let mounted = try mount(text)
    XCTAssertNotNil(mounted.controller.snapshot.invalidReason)
    XCTAssertNil(mounted.controller.snapshot.blockRange)

    select("Body", in: mounted)
    mounted.controller.ghostSelection()
    XCTAssertEqual(mounted.textView.string, text)
    XCTAssertTrue(mounted.controller.messageIsError)
    XCTAssertTrue(mounted.controller.message?.contains("Nothing was changed") == true)

    mounted.controller.moveSelectionToOverflow()
    XCTAssertEqual(mounted.textView.string, text)
    mounted.controller.beginAddAlternative()
    if let draft = mounted.controller.alternativeDraft {
      XCTAssertFalse(mounted.controller.commitAlternative(draft, versionText: "Other"))
    }
    XCTAssertEqual(mounted.textView.string, text)
    XCTAssertFalse(mounted.controller.selectionState.hasSelection)

    // Ordinary typing still works, and the broken block is shown, not hidden.
    type("More ", at: NSRange(location: 0, length: 0), in: mounted)
    XCTAssertTrue(mounted.textView.string.hasSuffix("{broken\n#+END_COMMENT\n"))
  }

  func testDocumentWithoutStateStaysByteIdenticalUntilFirstAction() throws {
    let text = "* Heading\nPlain prose.\n"
    let mounted = try mount(text)
    mounted.controller.refreshNow()
    mounted.controller.selectionDidChange()
    XCTAssertEqual(mounted.textView.string, text)
    XCTAssertEqual(mounted.controller.snapshot.status, .absent)
    XCTAssertNil(mounted.controller.snapshot.blockRange)

    mounted.controller.reviveAtSelection()
    XCTAssertEqual(mounted.textView.string, text)
  }

  // MARK: Revise with AI

  private func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { return XCTFail("Timed out waiting for condition") }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func stubBackend(_ stub: OrgProseStubRevisionProvider) -> OrgProseRevisionBackend {
    OrgProseRevisionBackend(label: "Stub", providerKind: "ollama", model: "stub-model", provider: stub)
  }

  func testReviseWithAIAppliesOneUndoableAIAlternative() async throws {
    let original = "Hello brave world.\n"
    let mounted = try mount(original)
    select("brave", in: mounted)

    mounted.controller.beginRevision()
    let draft = try XCTUnwrap(mounted.controller.revisionDraft)
    XCTAssertEqual(draft.target.text, "brave")
    XCTAssertEqual(mounted.textView.string, original)

    let stub = OrgProseStubRevisionProvider(reply: "\"bold\"")
    mounted.controller.submitRevision(draft, instruction: " stronger ", backend: stubBackend(stub))
    XCTAssertEqual(mounted.controller.revisionJob?.instruction, "stronger")
    XCTAssertEqual(mounted.textView.string, original)
    try await waitUntil { mounted.controller.revisionJob == nil }

    XCTAssertEqual(stub.calls.count, 1)
    XCTAssertNil(mounted.controller.revisionDraft)
    XCTAssertTrue(try proseBody(mounted.textView.string).hasPrefix("Hello bold world."))
    XCTAssertEqual(mounted.controller.selectionState.alternativeIndex, 1)
    XCTAssertEqual(mounted.controller.selectionState.alternativeCount, 2)
    XCTAssertTrue(mounted.controller.selectionState.activeVariantIsAI)
    let variant = try XCTUnwrap(mounted.controller.snapshot.state.alternatives.first?.variants.last)
    XCTAssertEqual(variant.origin, OrgProseStateFormat.aiOrigin)
    XCTAssertEqual(variant.provenance?.provider, "ollama")
    XCTAssertEqual(variant.provenance?.model, "stub-model")
    XCTAssertEqual(variant.provenance?.instruction, "stronger")
    XCTAssertNotNil(variant.provenance?.createdAt)

    mounted.controller.cycleAlternative(-1)
    XCTAssertTrue(try proseBody(mounted.textView.string).hasPrefix("Hello brave world."))
    XCTAssertFalse(mounted.controller.selectionState.activeVariantIsAI)

    mounted.undoManager.undo()
    XCTAssertTrue(try proseBody(mounted.textView.string).hasPrefix("Hello bold world."))
    mounted.undoManager.undo()
    XCTAssertEqual(mounted.textView.string, original)
  }

  func testCancelledOrAbandonedRevisionChangesNothing() async throws {
    let original = "Hello brave world.\n"
    let mounted = try mount(original)
    select("brave", in: mounted)

    mounted.controller.beginRevision()
    let draft = try XCTUnwrap(mounted.controller.revisionDraft)
    let slow = OrgProseStubRevisionProvider(reply: "bold", delayNanoseconds: 5_000_000_000)
    mounted.controller.submitRevision(draft, instruction: "stronger", backend: stubBackend(slow))
    XCTAssertNotNil(mounted.controller.revisionJob)
    mounted.controller.cancelRevision()
    XCTAssertNil(mounted.controller.revisionJob)
    XCTAssertNotNil(mounted.controller.revisionDraft)
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(mounted.textView.string, original)

    // Replacing the document (switching files) drops a pending revision.
    mounted.controller.submitRevision(draft, instruction: "stronger", backend: stubBackend(slow))
    mounted.controller.textWasReplaced()
    XCTAssertNil(mounted.controller.revisionJob)
    XCTAssertNil(mounted.controller.revisionDraft)
    XCTAssertEqual(mounted.textView.string, original)
  }

  func testRevisionReplyForChangedTextIsRefused() async throws {
    let original = "Hello brave world.\n"
    let mounted = try mount(original)
    select("brave", in: mounted)
    mounted.controller.beginRevision()
    let draft = try XCTUnwrap(mounted.controller.revisionDraft)
    let slow = OrgProseStubRevisionProvider(reply: "bold", delayNanoseconds: 100_000_000)
    mounted.controller.submitRevision(draft, instruction: "stronger", backend: stubBackend(slow))
    type("sh", at: (mounted.textView.string as NSString).range(of: "ve"), in: mounted)
    try await waitUntil { mounted.controller.revisionJob == nil }
    XCTAssertEqual(mounted.textView.string, "Hello brash world.\n")
    XCTAssertEqual(mounted.controller.revisionError, OrgProseError.revisionTargetChanged.localizedDescription)
  }

  func testDetachingRemovesHidingAndPresentation() throws {
    let mounted = try mount("Some prose.\n")
    select("prose", in: mounted)
    mounted.controller.ghostSelection()
    let layout = try XCTUnwrap(mounted.textView.layoutManager)
    XCTAssertNotNil(layout.delegate)
    mounted.controller.detach(from: mounted.textView)
    XCTAssertNil(layout.delegate)
  }

  func testCaretInheritsProseFaceInsteadOfNearbyRunFonts() throws {
    let mounted = try mount("Body with a [[https://example.com][link]].\n")
    mounted.textView.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular)]
    mounted.controller.selectionDidChange()
    let font = try XCTUnwrap(mounted.textView.typingAttributes[.font] as? NSFont)
    XCTAssertGreaterThanOrEqual(font.pointSize, 17)
  }

  func testClearSelectionKeepsCaretAndDropsHighlight() throws {
    let mounted = try mount("One two three.\n")
    select("two", in: mounted)
    XCTAssertGreaterThan(mounted.textView.selectedRange().length, 0)
    mounted.controller.clearSelectionKeepingCaret()
    let range = mounted.textView.selectedRange()
    XCTAssertEqual(range.length, 0)
    XCTAssertLessThanOrEqual(range.location, mounted.textView.string.count)
  }
}
