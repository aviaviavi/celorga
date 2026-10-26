import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class OrgProseEngineTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func ids() -> OrgProseEngine.IDGenerator {
    var next = 0
    return {
      next += 1
      return "id\(next)"
    }
  }

  /// Replaces text in the document body only, leaving the state block alone.
  private func editBody(_ text: String, _ old: String, _ new: String) -> String {
    let marker = (text as NSString).range(of: "#+BEGIN_COMMENT")
    guard marker.location != NSNotFound else {
      return text.replacingOccurrences(of: old, with: new)
    }
    let head = (text as NSString).substring(to: marker.location)
    let tail = (text as NSString).substring(from: marker.location)
    return head.replacingOccurrences(of: old, with: new) + tail
  }

  private func range(of needle: String, in text: String, occurrence: Int = 0) -> NSRange {
    let hits = OrgProseContext.occurrences(of: needle, in: text as NSString)
    return hits[occurrence]
  }

  private func state(of text: String) throws -> OrgProseState {
    try XCTUnwrap(OrgProseDocument.parse(text).state)
  }

  /// Body text with the state block removed.
  private func body(of text: String) throws -> String {
    try OrgProseContext(text: text).body as String
  }

  // MARK: Documents without state

  func testDocumentWithoutStateIsUnchangedByReading() {
    let text = "* Heading\nSome prose with ORG2_PROSE_STATE_V1 mentioned inline.\n"
    let document = OrgProseDocument.parse(text)
    XCTAssertEqual(document.status, .absent)
    XCTAssertEqual(document.text, text)
    XCTAssertEqual(OrgProseSnapshot.make(for: text).state, OrgProseState())
    XCTAssertNil(document.blockRange)
  }

  func testFailedActionsLeaveStatelessDocumentUntouched() throws {
    let text = "One two three\n"
    XCTAssertThrowsError(try OrgProseEngine.ghost(in: text, selection: NSRange(location: 3, length: 0)))
    XCTAssertThrowsError(try OrgProseEngine.moveToOverflow(in: text, selection: NSRange(location: 0, length: 0)))
    XCTAssertThrowsError(try OrgProseEngine.cycleAlternative(in: text, selection: NSRange(location: 2, length: 0), step: 1))
    XCTAssertThrowsError(try OrgProseEngine.revive(in: text, selection: NSRange(location: 2, length: 0)))
    XCTAssertEqual(OrgProseDocument.parse(text).status, .absent)
  }

  // MARK: Encoding

  func testStateEncodesDeterministicallyAndRoundTrips() throws {
    var state = OrgProseState()
    state.ghosts = [OrgProseGhost(
      id: "g1",
      anchor: OrgProseAnchor(text: "line\nbreak \u{2028} \"quoted\" /slash 🙂", prefix: "pre", suffix: "suf", offset: 7),
      created: "2026-10-01T00:00:00Z"
    )]
    state.overflow = [OrgProseOverflowItem(
      id: "o1",
      anchor: OrgProseAnchor(text: "* not a heading\n#+END_COMMENT", prefix: "", suffix: "tail", offset: 0)
    )]
    let payload = state.encodedPayload()
    XCTAssertEqual(payload, state.encodedPayload())
    XCTAssertFalse(payload.contains("\n"))
    XCTAssertFalse(payload.contains("\u{2028}"))
    XCTAssertEqual(try OrgProseState.decode(payload: payload), state)

    let rendered = OrgProseDocument.render(state)
    XCTAssertTrue(rendered.hasPrefix("#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{"))
    XCTAssertTrue(rendered.hasSuffix("\n#+END_COMMENT\n"))
    XCTAssertEqual(rendered.components(separatedBy: .newlines).count, 5)
    let document = OrgProseDocument.parse("Intro\n\n" + rendered)
    XCTAssertEqual(document.state, state)
  }

  func testUnknownFutureFieldsSurviveDecodeAndRewrite() throws {
    let payload = """
    {"version":1,"future":{"nested":[1,2.5,null,true]},"ghosts":[{"id":"g1","anchor":{"text":"brave","prefix":"Hello ","suffix":" world","offset":6,"confidence":0.5},"created":"x","tag":"keep"}],"alternatives":[{"id":"a1","anchor":{"text":"bold","prefix":"","suffix":""},"activeVariantID":"v2","variants":[{"id":"v1","text":"brave","origin":"original","model":"none"},{"id":"v2","text":"bold","origin":"ai","provenance":{"model":"x"}}],"rank":3}]}
    """
    let text = "Hello brave world bold\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n\(payload)\n#+END_COMMENT\n"
    let decoded = try state(of: text)
    XCTAssertEqual(decoded.extra["future"], .object(["nested": .array([.int(1), .double(2.5), .null, .bool(true)])]))
    XCTAssertEqual(decoded.ghosts[0].extra["tag"], .string("keep"))
    XCTAssertEqual(decoded.ghosts[0].anchor.extra["confidence"], .double(0.5))
    XCTAssertEqual(decoded.alternatives[0].extra["rank"], .int(3))
    XCTAssertEqual(decoded.alternatives[0].variants[1].origin, "ai")

    // A real action rewrites the block and must keep every unknown field.
    let edit = try OrgProseEngine.ghost(in: text, selection: range(of: "world", in: text), now: now, makeID: ids())
    let rewritten = try state(of: edit.text)
    XCTAssertEqual(rewritten.extra["future"], decoded.extra["future"])
    XCTAssertEqual(rewritten.ghosts.first { $0.id == "g1" }?.extra["tag"], .string("keep"))
    XCTAssertEqual(rewritten.ghosts.first { $0.id == "g1" }?.anchor.extra["confidence"], .double(0.5))
    XCTAssertEqual(rewritten.alternatives[0].extra["rank"], .int(3))
    XCTAssertEqual(rewritten.alternatives[0].variants[1].provenance, OrgProseAIProvenance(model: "x"))
    XCTAssertTrue(edit.text.contains("\"provenance\":{\"model\":\"x\"}"))
    XCTAssertEqual(rewritten.ghosts.count, 2)
  }

  // MARK: Malformed blocks

  func testMalformedBlocksAreNeverOverwritten() throws {
    let cases: [(String, String)] = [
      ("bad json", "Body text\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{not json\n#+END_COMMENT\n"),
      ("not object", "Body text\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n[1,2]\n#+END_COMMENT\n"),
      ("wrong version field", "Body text\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{\"version\":2}\n#+END_COMMENT\n"),
      ("bad record", "Body text\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{\"version\":1,\"ghosts\":[{\"id\":\"g\"}]}\n#+END_COMMENT\n"),
      ("unclosed", "Body text\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{\"version\":1}\n"),
      ("truncated", "Body text\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1"),
      ("future marker", "Body text\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V2\n{\"version\":2}\n#+END_COMMENT\n"),
      (
        "two blocks",
        "Body text\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{\"version\":1}\n#+END_COMMENT\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{\"version\":1}\n#+END_COMMENT\n"
      )
    ]
    for (name, text) in cases {
      let document = OrgProseDocument.parse(text)
      XCTAssertNotNil(document.invalidReason, name)
      XCTAssertNil(document.state, name)
      XCTAssertEqual(document.text, text, name)
      let selection = NSRange(location: 0, length: 4)
      XCTAssertThrowsError(try OrgProseEngine.ghost(in: text, selection: selection), name) { error in
        guard case OrgProseError.invalidState = error else {
          return XCTFail("\(name): expected invalidState, got \(error)")
        }
      }
      XCTAssertThrowsError(try OrgProseEngine.moveToOverflow(in: text, selection: selection), name)
      XCTAssertThrowsError(try OrgProseEngine.addAlternative(to: text, selection: selection, versionText: "Other"), name)
      XCTAssertNotNil(OrgProseSnapshot.make(for: text).invalidReason, name)
    }
  }

  func testMarkerOutsideACommentBlockIsOrdinaryProse() {
    let text = "ORG2_PROSE_STATE_V1\n{\"version\":1}\n"
    XCTAssertEqual(OrgProseDocument.parse(text).status, .absent)
  }

  // MARK: Alternatives

  func testAddAlternativeActivatesAuthorVersionAndKeepsOriginalRecoverable() throws {
    let text = "Hello brave world.\n"
    let edit = try OrgProseEngine.addAlternative(
      to: text,
      selection: range(of: "brave", in: text),
      versionText: "bold",
      now: now,
      makeID: ids()
    )
    XCTAssertEqual(try body(of: edit.text), "Hello bold world.\n\n")
    XCTAssertEqual(edit.selection, range(of: "bold", in: edit.text))
    let set = try XCTUnwrap(try state(of: edit.text).alternatives.first)
    XCTAssertEqual(set.variants.map(\.text), ["brave", "bold"])
    XCTAssertEqual(set.variants.map(\.origin), ["original", "author"])
    XCTAssertEqual(set.variants.first { $0.id == set.activeVariantID }?.text, "bold")
    XCTAssertEqual(set.anchor.text, "bold")
    XCTAssertEqual(set.anchor.prefix, "Hello ")
    XCTAssertEqual(set.anchor.suffix, " world.\n")
  }

  func testCyclingAlternativesReplacesOnlyAnchoredTextAndWraps() throws {
    var text = "Alpha beta gamma.\n"
    let makeID = ids()
    text = try OrgProseEngine.addAlternative(to: text, selection: range(of: "beta", in: text), versionText: "BETA", now: now, makeID: makeID).text
    text = try OrgProseEngine.addAlternative(
      to: text,
      selection: NSRange(location: range(of: "BETA", in: text).location + 1, length: 0),
      versionText: "Beta!",
      now: now,
      makeID: makeID
    ).text
    XCTAssertEqual(try state(of: text).alternatives[0].variants.map(\.text), ["beta", "BETA", "Beta!"])
    XCTAssertTrue(try body(of: text).hasPrefix("Alpha Beta! gamma."))

    let caret = NSRange(location: range(of: "Beta!", in: text).location + 2, length: 0)
    var seen: [String] = []
    for _ in 0..<3 {
      let edit = try OrgProseEngine.cycleAlternative(in: text, selection: caret, step: 1)
      text = edit.text
      seen.append(String(try body(of: text).prefix(17)))
    }
    XCTAssertEqual(seen, ["Alpha beta gamma.\n", "Alpha BETA gamma.\n", "Alpha Beta! gamma."].map { String($0.prefix(17)) })

    let back = try OrgProseEngine.cycleAlternative(
      in: text,
      selection: NSRange(location: range(of: "Beta!", in: text).location, length: 5),
      step: -1
    )
    XCTAssertTrue(try body(of: back.text).hasPrefix("Alpha BETA gamma."))
    XCTAssertEqual(try state(of: back.text).alternatives.count, 1)
  }

  func testAlternativeErrors() throws {
    let text = "Alpha beta gamma.\n"
    XCTAssertThrowsError(try OrgProseEngine.addAlternative(to: text, selection: range(of: "beta", in: text), versionText: "beta")) {
      XCTAssertEqual($0 as? OrgProseError, .unchangedText)
    }
    XCTAssertThrowsError(try OrgProseEngine.addAlternative(to: text, selection: range(of: "beta", in: text), versionText: "  \n")) {
      XCTAssertEqual($0 as? OrgProseError, .emptyText)
    }
    XCTAssertThrowsError(try OrgProseEngine.addAlternative(to: text, selection: NSRange(location: 2, length: 0), versionText: "x")) {
      XCTAssertEqual($0 as? OrgProseError, .emptySelection)
    }
    let edit = try OrgProseEngine.addAlternative(to: text, selection: range(of: "beta", in: text), versionText: "BETA", now: now, makeID: ids())
    let partial = NSRange(location: range(of: "BETA", in: edit.text).location + 2, length: 8)
    XCTAssertThrowsError(try OrgProseEngine.addAlternative(to: edit.text, selection: partial, versionText: "x")) {
      XCTAssertEqual($0 as? OrgProseError, .overlapsAlternative)
    }
    XCTAssertThrowsError(try OrgProseEngine.cycleAlternative(in: edit.text, selection: range(of: "Alpha", in: edit.text), step: 1)) {
      guard case OrgProseError.notFound = $0 else { return XCTFail() }
    }
  }

  func testChooseVariantByIDAndUnresolvedAlternativeStaysRecoverable() throws {
    let text = "Alpha beta gamma.\n"
    let edit = try OrgProseEngine.addAlternative(to: text, selection: range(of: "beta", in: text), versionText: "BETA", now: now, makeID: ids())
    let set = try XCTUnwrap(try state(of: edit.text).alternatives.first)
    let original = try XCTUnwrap(set.variants.first { $0.origin == "original" })
    let chosen = try OrgProseEngine.chooseVariant(in: edit.text, alternativeID: set.id, variantID: original.id)
    XCTAssertTrue(try body(of: chosen.text).hasPrefix("Alpha beta gamma."))

    // The author rewrites the marked words entirely; the record must survive, unresolved.
    let rewritten = editBody(edit.text, "Alpha BETA gamma.", "Totally different.")
    let snapshot = OrgProseSnapshot.make(for: rewritten)
    XCTAssertEqual(snapshot.state.alternatives.count, 1)
    XCTAssertEqual(snapshot.resolution(for: set.id), .unresolved(.missing))
    XCTAssertThrowsError(try OrgProseEngine.chooseVariant(in: rewritten, alternativeID: set.id, variantID: original.id)) {
      XCTAssertEqual($0 as? OrgProseError, .anchorUnresolved)
    }
    let dismissed = try OrgProseEngine.dismissAlternative(in: rewritten, id: set.id)
    XCTAssertEqual(try state(of: dismissed.text).alternatives.count, 0)
  }

  // MARK: Ghosts

  func testGhostKeepsBodyTextAndReviveRemovesOnlyTheRecord() throws {
    let text = "Keep this. Maybe cut this. Keep that.\n"
    let selection = range(of: "Maybe cut this.", in: text)
    let ghosted = try OrgProseEngine.ghost(in: text, selection: selection, now: now, makeID: ids())
    XCTAssertEqual(try body(of: ghosted.text), text + "\n")
    XCTAssertNil(ghosted.selection)
    let ghost = try XCTUnwrap(try state(of: ghosted.text).ghosts.first)
    XCTAssertEqual(ghost.anchor.text, "Maybe cut this.")
    XCTAssertEqual(OrgProseSnapshot.make(for: ghosted.text).resolution(for: ghost.id).range, selection)

    let caret = NSRange(location: selection.location + 3, length: 0)
    let revived = try OrgProseEngine.revive(in: ghosted.text, selection: caret)
    XCTAssertEqual(revived.text, text)
  }

  func testOverlappingGhostsMergeAndRepeatedGhostIsRejected() throws {
    let text = "One two three four five.\n"
    let makeID = ids()
    var current = try OrgProseEngine.ghost(in: text, selection: range(of: "two three", in: text), now: now, makeID: makeID).text
    XCTAssertThrowsError(try OrgProseEngine.ghost(in: current, selection: range(of: "two three", in: current), now: now))
    XCTAssertThrowsError(try OrgProseEngine.ghost(in: current, selection: range(of: "three", in: current), now: now))
    current = try OrgProseEngine.ghost(in: current, selection: range(of: "three four", in: current), now: now, makeID: makeID).text
    let ghosts = try state(of: current).ghosts
    XCTAssertEqual(ghosts.map(\.anchor.text), ["two three four"])
  }

  func testGhostsPersistAcrossReopenAndSurviveEditsBeforeThem() throws {
    let text = "Intro line.\n\nThe quick brown fox jumps.\n"
    let ghosted = try OrgProseEngine.ghost(in: text, selection: range(of: "quick brown", in: text), now: now, makeID: ids()).text
    // "Reopen" = parse the saved text, after an unrelated edit earlier in the file.
    let edited = "A brand new opening paragraph.\n\n" + ghosted
    let snapshot = OrgProseSnapshot.make(for: edited)
    let ghost = try XCTUnwrap(snapshot.state.ghosts.first)
    XCTAssertEqual(snapshot.resolution(for: ghost.id).range, range(of: "quick brown", in: edited))
  }

  // MARK: Overflow

  func testOverflowStoresExactFragmentAndRestoresAtItsAnchor() throws {
    let text = "First paragraph stays.\n\nSecond paragraph, with *markup* and ümlauts 🙂.\n\nThird stays.\n"
    let fragment = "Second paragraph, with *markup* and ümlauts 🙂.\n\n"
    let parked = try OrgProseEngine.moveToOverflow(in: text, selection: range(of: fragment, in: text), now: now, makeID: ids())
    XCTAssertEqual(try body(of: parked.text), "First paragraph stays.\n\nThird stays.\n\n")
    let item = try XCTUnwrap(try state(of: parked.text).overflow.first)
    XCTAssertEqual(item.text, fragment)
    XCTAssertEqual(item.anchor.prefix, "First paragraph stays.\n\n")
    XCTAssertEqual(item.anchor.suffix, "Third stays.\n")

    // Ordinary edits before the gap must not stop the anchor resolving.
    let shifted = "Preface.\n\n" + parked.text
    XCTAssertNotNil(OrgProseSnapshot.make(for: shifted).resolution(for: item.id).range)
    let restored = try OrgProseEngine.restoreOverflow(in: shifted, id: item.id)
    XCTAssertEqual(restored.text, "Preface.\n\n" + text)
    XCTAssertEqual(try state(of: restored.text).overflow.count, 0)
  }

  func testOverflowRestoreWithUnresolvableAnchorRequiresExplicitInsertionPoint() throws {
    let text = "Alpha stays here.\n\nParked sentence goes away.\n\nOmega stays too.\n"
    let parked = try OrgProseEngine.moveToOverflow(
      in: text,
      selection: range(of: "Parked sentence goes away.\n\n", in: text),
      now: now,
      makeID: ids()
    )
    let id = try XCTUnwrap(try state(of: parked.text).overflow.first?.id)
    // The author rewrites everything around the gap.
    var rewritten = editBody(parked.text, "Alpha stays here.", "Completely new opening.")
    rewritten = editBody(rewritten, "Omega stays too.", "Completely new ending.")
    XCTAssertEqual(OrgProseSnapshot.make(for: rewritten).resolution(for: id), .unresolved(.missing))
    XCTAssertThrowsError(try OrgProseEngine.restoreOverflow(in: rewritten, id: id)) {
      XCTAssertEqual($0 as? OrgProseError, .anchorUnresolved)
    }
    // The fragment is still recoverable at the cursor.
    let cursor = range(of: "Completely new ending.", in: rewritten).location
    let restored = try OrgProseEngine.restoreOverflow(in: rewritten, id: id, insertionPoint: cursor)
    XCTAssertTrue(restored.text.contains("Parked sentence goes away.\n\nCompletely new ending."))
    XCTAssertEqual(try state(of: restored.text).overflow.count, 0)
  }

  func testDeleteOverflowRemovesOnlyThatRecordAndEmptyStateDropsBlock() throws {
    let text = "Keep.\nDrop me.\n"
    let parked = try OrgProseEngine.moveToOverflow(in: text, selection: range(of: "Drop me.\n", in: text), now: now, makeID: ids())
    let id = try XCTUnwrap(try state(of: parked.text).overflow.first?.id)
    let deleted = try OrgProseEngine.deleteOverflow(in: parked.text, id: id)
    XCTAssertEqual(OrgProseDocument.parse(deleted.text).status, .absent)
    XCTAssertEqual(deleted.text, "Keep.\n")
  }

  func testEmptyStateBlockIsRemovedAndRestoresOriginalWhenNewlineTerminated() throws {
    let text = "Hello world\n"
    let ghosted = try OrgProseEngine.ghost(in: text, selection: range(of: "world", in: text), now: now, makeID: ids())
    XCTAssertNotEqual(ghosted.text, text)
    let revived = try OrgProseEngine.revive(in: ghosted.text, selection: range(of: "world", in: ghosted.text))
    XCTAssertEqual(revived.text, text)
  }

  // MARK: Anchor resolution

  func testAnchorWithRepeatedTextUsesContextAndNeverGuessesWhenAmbiguous() throws {
    let text = "a cat sat. a cat ran.\n"
    let ghosted = try OrgProseEngine.ghost(in: text, selection: range(of: "cat", in: text, occurrence: 1), now: now, makeID: ids()).text
    let ghost = try XCTUnwrap(try state(of: ghosted).ghosts.first)
    XCTAssertEqual(
      OrgProseSnapshot.make(for: ghosted).resolution(for: ghost.id).range,
      range(of: "cat", in: ghosted, occurrence: 1)
    )

    // Strip all usable context and the offset hint: two equal candidates remain.
    var bare = try state(of: ghosted)
    bare.ghosts[0].anchor = OrgProseAnchor(text: "cat", prefix: "zzzz", suffix: "yyyy", offset: nil)
    let ambiguous = "a cat sat. a cat ran.\n\n" + OrgProseDocument.render(bare)
    XCTAssertEqual(OrgProseSnapshot.make(for: ambiguous).resolution(for: ghost.id), .unresolved(.ambiguous))

    // One surviving candidate whose context changed is not silently adopted.
    let single = "the only cat here.\n\n" + OrgProseDocument.render(bare)
    XCTAssertEqual(OrgProseSnapshot.make(for: single).resolution(for: ghost.id), .unresolved(.contextChanged))
    let gone = "no felines.\n\n" + OrgProseDocument.render(bare)
    XCTAssertEqual(OrgProseSnapshot.make(for: gone).resolution(for: ghost.id), .unresolved(.missing))
    XCTAssertEqual(OrgProseSnapshot.make(for: gone).state.ghosts.count, 1)
  }

  func testOffsetHintBreaksTiesButIsNotTheOnlyAnchor() throws {
    var state = OrgProseState()
    state.ghosts = [OrgProseGhost(id: "g", anchor: OrgProseAnchor(text: "cat", prefix: "", suffix: "", offset: 2))]
    let text = "a cat, a cat\n\n" + OrgProseDocument.render(state)
    XCTAssertEqual(OrgProseSnapshot.make(for: text).resolution(for: "g").range, NSRange(location: 2, length: 3))
    state.ghosts[0].anchor.offset = 99
    let shifted = "a cat, a cat\n\n" + OrgProseDocument.render(state)
    XCTAssertEqual(OrgProseSnapshot.make(for: shifted).resolution(for: "g"), .unresolved(.ambiguous))
  }

  func testAnchorSurvivesEditOnOneSideOfItsContext() throws {
    let text = "Before the target sentence and after it.\n"
    let ghosted = try OrgProseEngine.ghost(in: text, selection: range(of: "target sentence", in: text), now: now, makeID: ids()).text
    let edited = editBody(ghosted, "Before the", "Well before the")
    let ghost = try XCTUnwrap(try state(of: edited).ghosts.first)
    XCTAssertEqual(OrgProseSnapshot.make(for: edited).resolution(for: ghost.id).range, range(of: "target sentence", in: edited))
  }

  func testStateBlockInMiddleOfDocumentIsRespected() throws {
    let block = OrgProseDocument.render(OrgProseState(extra: ["future": .int(1)]))
    let text = "First para.\n\n" + block + "Second para.\n"
    let selection = range(of: "Second", in: text)
    let edit = try OrgProseEngine.addAlternative(to: text, selection: selection, versionText: "Next", now: now, makeID: ids())
    XCTAssertTrue(edit.text.hasPrefix("First para.\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n"))
    XCTAssertTrue(edit.text.hasSuffix("Next para.\n"))
    XCTAssertEqual(try state(of: edit.text).extra["future"], .int(1))
    XCTAssertEqual(edit.selection.map { (edit.text as NSString).substring(with: $0) }, "Next")
    let set = try XCTUnwrap(try state(of: edit.text).alternatives.first)
    XCTAssertNotNil(OrgProseSnapshot.make(for: edit.text).resolution(for: set.id).range)

    let blockRange = try XCTUnwrap(OrgProseDocument.parse(text).blockRange)
    XCTAssertThrowsError(try OrgProseEngine.ghost(in: text, selection: NSRange(location: blockRange.location - 3, length: 10), now: now)) {
      XCTAssertEqual($0 as? OrgProseError, .selectionTouchesState)
    }
  }

  // MARK: Replacement diff

  func testMinimalReplacementReproducesNewTextWithoutSplittingSurrogates() {
    let samples = [
      ("abc", "abXc"),
      ("hello 🙂 world", "hello 🙃 world"),
      ("same", "same"),
      ("", "new"),
      ("gone", ""),
      ("a🙂b🙂c", "a🙂b🙃c")
    ]
    for (old, new) in samples {
      guard let diff = OrgProseTextDiff.replacement(from: old, to: new) else {
        XCTAssertEqual(old, new)
        continue
      }
      let rebuilt = (old as NSString).replacingCharacters(in: diff.range, with: diff.replacement)
      XCTAssertEqual(rebuilt, new)
      XCTAssertNotNil(Range(diff.range, in: old))
    }
  }
}
