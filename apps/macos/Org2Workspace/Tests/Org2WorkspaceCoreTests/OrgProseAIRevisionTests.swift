import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Records the one request a revision makes and returns a canned reply.
final class OrgProseStubRevisionProvider: OrgProseRevisionProvider, @unchecked Sendable {
  struct Call: Equatable {
    let system: String
    let prompt: String
    let model: String
    let maxTokens: Int
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  let reply: String
  let delayNanoseconds: UInt64

  init(reply: String, delayNanoseconds: UInt64 = 0) {
    self.reply = reply
    self.delayNanoseconds = delayNanoseconds
  }

  var calls: [Call] { lock.withLock { recorded } }

  func complete(system: String, prompt: String, model: String, maxTokens: Int) async throws -> String {
    lock.withLock { recorded.append(Call(system: system, prompt: prompt, model: model, maxTokens: maxTokens)) }
    if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
    return reply
  }
}

final class OrgProseAIRevisionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func ids() -> OrgProseEngine.IDGenerator {
    var next = 0
    return {
      next += 1
      return "id\(next)"
    }
  }

  private func range(of needle: String, in text: String, occurrence: Int = 0) -> NSRange {
    OrgProseContext.occurrences(of: needle, in: text as NSString)[occurrence]
  }

  private func state(of text: String) throws -> OrgProseState {
    try XCTUnwrap(OrgProseDocument.parse(text).state)
  }

  private func body(of text: String) throws -> String {
    try OrgProseContext(text: text).body as String
  }

  private let provenance = OrgProseAIProvenance(provider: "anthropic", model: "test-model", instruction: "stronger")

  // MARK: Provenance encoding

  func testAIProvenanceRoundTripsAndKeepsUnknownFields() throws {
    let payload = """
    {"version":1,"alternatives":[{"id":"a1","anchor":{"text":"bold","prefix":"","suffix":""},"activeVariantID":"v2","variants":[{"id":"v1","text":"brave","origin":"original"},{"id":"v2","text":"bold","origin":"ai","created":"2026-09-01T00:00:00Z","provenance":{"provider":"openAI","model":"m-1","instruction":"tighter","createdAt":"2026-09-01T00:00:00Z","temperature":0.2,"seed":7}},{"id":"v3","text":"bolder","origin":"ai","provenance":{"model":5,"provider":"ollama"}},{"id":"v4","text":"boldest","origin":"ai","provenance":"legacy"}]}]}
    """
    let decoded = try OrgProseState.decode(payload: payload)
    let variants = decoded.alternatives[0].variants
    XCTAssertFalse(variants[0].isAI)
    XCTAssertNil(variants[0].provenance)
    XCTAssertTrue(variants[1].isAI)
    XCTAssertEqual(variants[1].provenance, OrgProseAIProvenance(
      provider: "openAI",
      model: "m-1",
      instruction: "tighter",
      createdAt: "2026-09-01T00:00:00Z",
      extra: ["temperature": .double(0.2), "seed": .int(7)]
    ))
    // A known field with an unexpected type is preserved, not rejected.
    XCTAssertEqual(variants[2].provenance?.provider, "ollama")
    XCTAssertNil(variants[2].provenance?.model)
    XCTAssertEqual(variants[2].provenance?.extra["model"], .int(5))
    // Non-object provenance stays an unknown field.
    XCTAssertNil(variants[3].provenance)
    XCTAssertEqual(variants[3].extra["provenance"], .string("legacy"))

    let reencoded = decoded.encodedPayload()
    XCTAssertEqual(try OrgProseState.decode(payload: reencoded), decoded)
    XCTAssertTrue(reencoded.contains("\"seed\":7"))
    XCTAssertTrue(reencoded.contains("\"model\":5"))
    XCTAssertTrue(reencoded.contains("\"provenance\":\"legacy\""))
  }

  func testExistingStateBlockWithoutProvenanceRewritesByteIdentically() throws {
    let payload = #"{"alternatives":[{"activeVariantID":"v2","anchor":{"offset":6,"prefix":"Hello ","suffix":" world.\n","text":"bold"},"created":"2026-09-01T00:00:00Z","id":"a1","variants":[{"created":"2026-09-01T00:00:00Z","id":"v1","origin":"original","text":"brave"},{"created":"2026-09-01T00:00:00Z","id":"v2","origin":"author","text":"bold"}]}],"ghosts":[],"overflow":[],"version":1}"#
    let decoded = try OrgProseState.decode(payload: payload)
    XCTAssertTrue(decoded.alternatives[0].variants.allSatisfy { $0.provenance == nil && !$0.isAI })
    XCTAssertEqual(decoded.encodedPayload(), payload)
  }

  // MARK: Target capture

  func testRevisionTargetCapturesSelectionAndBoundedContextWithoutState() throws {
    let text = "0123456789 Lead in. Hello brave world. Tail end.\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{\"version\":1}\n#+END_COMMENT\n"
    let target = try OrgProseEngine.revisionTarget(
      in: text,
      selection: range(of: "brave", in: text),
      contextLimit: 12
    )
    XCTAssertEqual(target.text, "brave")
    XCTAssertNil(target.alternativeID)
    XCTAssertEqual(target.contextBefore, "Lead in. Hello ".suffix(12).description)
    XCTAssertEqual(target.contextAfter, " world. Tail")
    XCTAssertEqual(target.anchor.text, "brave")

    let atEnd = try OrgProseEngine.revisionTarget(in: text, selection: range(of: "Tail end.", in: text))
    XCTAssertEqual(atEnd.contextAfter, "\n\n")
    XCTAssertFalse(atEnd.contextAfter.contains("BEGIN_COMMENT"))
    XCTAssertFalse(atEnd.contextBefore.contains("ORG2_PROSE_STATE"))
  }

  func testRevisionTargetErrors() throws {
    let text = "Alpha beta gamma.\n"
    XCTAssertThrowsError(try OrgProseEngine.revisionTarget(in: text, selection: NSRange(location: 3, length: 0))) {
      XCTAssertEqual($0 as? OrgProseError, .emptySelection)
    }
    XCTAssertThrowsError(try OrgProseEngine.revisionTarget(in: "a   b", selection: NSRange(location: 1, length: 3))) {
      XCTAssertEqual($0 as? OrgProseError, .emptySelection)
    }
    let withAlt = try OrgProseEngine.addAlternative(
      to: text, selection: range(of: "beta", in: text), versionText: "BETA", now: now, makeID: ids()
    ).text
    XCTAssertThrowsError(try OrgProseEngine.revisionTarget(in: withAlt, selection: range(of: "a BE", in: withAlt))) {
      XCTAssertEqual($0 as? OrgProseError, .overlapsAlternative)
    }
    let block = (withAlt as NSString).range(of: "ORG2_PROSE_STATE_V1")
    XCTAssertThrowsError(try OrgProseEngine.revisionTarget(in: withAlt, selection: block)) {
      XCTAssertEqual($0 as? OrgProseError, .selectionTouchesState)
    }
  }

  // MARK: Applying a revision

  func testAIRevisionBecomesActiveVersionWithProvenanceAndOriginalStaysRecoverable() throws {
    let text = "Hello brave world.\n"
    let target = try OrgProseEngine.revisionTarget(in: text, selection: range(of: "brave", in: text))
    let edit = try OrgProseEngine.addAIRevision(
      to: text,
      target: target,
      revisedText: "bold",
      provenance: provenance,
      now: now,
      makeID: ids()
    )
    XCTAssertEqual(edit.message, "Added AI alternative")
    XCTAssertEqual(try body(of: edit.text), "Hello bold world.\n\n")
    XCTAssertEqual(edit.selection, range(of: "bold", in: edit.text))
    let set = try XCTUnwrap(try state(of: edit.text).alternatives.first)
    XCTAssertEqual(set.variants.map(\.text), ["brave", "bold"])
    XCTAssertEqual(set.variants.map(\.origin), ["original", "ai"])
    XCTAssertEqual(set.activeVariantID, "id2")
    XCTAssertNil(set.variants[0].provenance)
    var expected = provenance
    expected.createdAt = OrgProseStateFormat.timestamp(now)
    XCTAssertEqual(set.variants[1].provenance, expected)
    XCTAssertEqual(set.variants[1].created, OrgProseStateFormat.timestamp(now))

    let back = try OrgProseEngine.cycleAlternative(in: edit.text, selection: edit.selection!, step: -1)
    XCTAssertEqual(try body(of: back.text), "Hello brave world.\n\n")
    XCTAssertEqual(try state(of: back.text).alternatives[0].variants[1].provenance, expected)
  }

  func testAIRevisionAtCursorJoinsTheExistingAlternative() throws {
    var text = "Alpha beta gamma.\n"
    let makeID = ids()
    text = try OrgProseEngine.addAlternative(
      to: text, selection: range(of: "beta", in: text), versionText: "BETA", now: now, makeID: makeID
    ).text
    let caret = NSRange(location: range(of: "BETA", in: text).location + 1, length: 0)
    let target = try OrgProseEngine.revisionTarget(in: text, selection: caret)
    XCTAssertEqual(target.text, "BETA")
    XCTAssertEqual(target.alternativeID, try state(of: text).alternatives[0].id)

    let edit = try OrgProseEngine.addAIRevision(
      to: text, target: target, revisedText: "Beta!", provenance: provenance, now: now, makeID: makeID
    )
    XCTAssertTrue(try body(of: edit.text).hasPrefix("Alpha Beta! gamma."))
    let set = try state(of: edit.text).alternatives[0]
    XCTAssertEqual(set.variants.map(\.origin), ["original", "author", "ai"])
    XCTAssertEqual(set.variants.first { $0.id == set.activeVariantID }?.text, "Beta!")
    XCTAssertEqual(try state(of: edit.text).alternatives.count, 1)
  }

  func testAIRevisionReanchorsAfterEditsAndRefusesWhenTargetChanged() throws {
    let text = "Hello brave world.\n"
    let target = try OrgProseEngine.revisionTarget(in: text, selection: range(of: "brave", in: text))

    let edited = "Intro line.\n" + text
    let moved = try OrgProseEngine.addAIRevision(
      to: edited, target: target, revisedText: "bold", provenance: provenance, now: now, makeID: ids()
    )
    XCTAssertTrue(try body(of: moved.text).hasPrefix("Intro line.\nHello bold world."))

    let changed = "Hello brash world.\n"
    XCTAssertThrowsError(try OrgProseEngine.addAIRevision(
      to: changed, target: target, revisedText: "bold", provenance: provenance
    )) { XCTAssertEqual($0 as? OrgProseError, .revisionTargetChanged) }

    XCTAssertThrowsError(try OrgProseEngine.addAIRevision(
      to: text, target: target, revisedText: "brave", provenance: provenance
    )) { XCTAssertEqual($0 as? OrgProseError, .unchangedText) }
    XCTAssertThrowsError(try OrgProseEngine.addAIRevision(
      to: text, target: target, revisedText: "  \n", provenance: provenance
    )) { XCTAssertEqual($0 as? OrgProseError, .emptyText) }

    // An alternative whose active version changed since the request started.
    var withAlt = try OrgProseEngine.addAlternative(
      to: text, selection: range(of: "brave", in: text), versionText: "bold", now: now, makeID: ids()
    ).text
    let altTarget = try OrgProseEngine.revisionTarget(in: withAlt, selection: range(of: "bold", in: withAlt))
    withAlt = try OrgProseEngine.cycleAlternative(in: withAlt, selection: range(of: "bold", in: withAlt), step: 1).text
    XCTAssertThrowsError(try OrgProseEngine.addAIRevision(
      to: withAlt, target: altTarget, revisedText: "daring", provenance: provenance
    )) { XCTAssertEqual($0 as? OrgProseError, .revisionTargetChanged) }
  }

  func testAIRevisionNeverRewritesMalformedStateOrTouchesStatelessDocumentsEarly() throws {
    let stateless = "Hello brave world.\n"
    let target = try OrgProseEngine.revisionTarget(in: stateless, selection: range(of: "brave", in: stateless))
    XCTAssertEqual(OrgProseDocument.parse(stateless).status, .absent)
    XCTAssertEqual(target.text, "brave")

    let malformed = "Hello brave world.\n\n#+BEGIN_COMMENT\nORG2_PROSE_STATE_V1\n{not json\n#+END_COMMENT\n"
    XCTAssertThrowsError(try OrgProseEngine.revisionTarget(in: malformed, selection: range(of: "brave", in: malformed))) {
      guard case OrgProseError.invalidState = $0 else { return XCTFail("expected invalidState, got \($0)") }
    }
    XCTAssertThrowsError(try OrgProseEngine.addAIRevision(
      to: malformed, target: target, revisedText: "bold", provenance: provenance
    )) {
      guard case OrgProseError.invalidState = $0 else { return XCTFail("expected invalidState, got \($0)") }
    }
  }

  // MARK: Request and response

  func testRequestCarriesInstructionPassageAndBoundedContextOnly() throws {
    let target = OrgProseRevisionTarget(
      text: "The quick brown fox.",
      anchor: OrgProseAnchor(text: "The quick brown fox.", prefix: "", suffix: "", offset: 0),
      alternativeID: nil,
      contextBefore: "Before text.",
      contextAfter: ""
    )
    let request = try OrgProseRevisionRequest(instruction: "  tighter \n", target: target)
    XCTAssertEqual(request.instruction, "tighter")
    let prompt = request.userPrompt
    XCTAssertTrue(prompt.contains("<instruction>\ntighter\n</instruction>"))
    XCTAssertTrue(prompt.contains("<before>\nBefore text.\n</before>"))
    XCTAssertTrue(prompt.contains("<passage>\nThe quick brown fox.\n</passage>"))
    XCTAssertFalse(prompt.contains("<after>"))
    XCTAssertTrue(OrgProseRevisionRequest.systemPrompt.contains("no tools"))

    XCTAssertThrowsError(try OrgProseRevisionRequest(instruction: " ", target: target)) {
      XCTAssertEqual($0 as? OrgProseRevisionError, .emptyInstruction)
    }
    let huge = OrgProseRevisionTarget(
      text: String(repeating: "a", count: OrgProseRevisionRequest.maxPassageLength + 1),
      anchor: target.anchor,
      alternativeID: nil,
      contextBefore: "",
      contextAfter: ""
    )
    XCTAssertThrowsError(try OrgProseRevisionRequest(instruction: "tighter", target: huge)) {
      XCTAssertEqual($0 as? OrgProseRevisionError, .passageTooLong(OrgProseRevisionRequest.maxPassageLength))
    }
  }

  func testResponseCleanupStripsWrappersAndKeepsOriginalWhitespace() throws {
    let cases: [(raw: String, original: String, expected: String)] = [
      ("Tight text.", "Loose text.", "Tight text."),
      ("```\nTight text.\n```", "Loose text.", "Tight text."),
      ("```org\nTight text.\n```", "Loose text.", "Tight text."),
      ("\"Tight text.\"", "Loose text.", "Tight text."),
      ("\u{201C}Tight text.\u{201D}", "Loose text.", "Tight text."),
      ("<passage>\nTight text.\n</passage>", "Loose text.", "Tight text."),
      ("```\n\"Tight text.\"\n```", "Loose text.", "Tight text."),
      ("\"Yes,\" she said, \"go.\"", "Loose text.", "\"Yes,\" she said, \"go.\""),
      ("\"Hello\"", "\"Hi there\"", "\"Hello\""),
      ("Para 1.", "Para one.\n", "Para 1.\n"),
      ("  w2  ", " word ", " w2 ")
    ]
    for item in cases {
      XCTAssertEqual(try OrgProseRevisionResponse.clean(item.raw, original: item.original), item.expected, item.raw)
    }
    XCTAssertThrowsError(try OrgProseRevisionResponse.clean("```\n```", original: "x")) {
      XCTAssertEqual($0 as? OrgProseRevisionError, .emptyResponse)
    }
  }

  func testReviserMakesOneRequestToTheStubProviderAndCleansTheReply() async throws {
    let text = "Hello brave world.\n"
    let target = try OrgProseEngine.revisionTarget(in: text, selection: range(of: "brave world.\n", in: text))
    let stub = OrgProseStubRevisionProvider(reply: "```\n\"bold world.\"\n```")
    let backend = OrgProseRevisionBackend(label: "Stub", providerKind: "ollama", model: "stub-model", provider: stub)
    let revised = try await OrgProseReviser.revise(target: target, instruction: "stronger", backend: backend)
    XCTAssertEqual(revised, "bold world.\n")
    XCTAssertEqual(stub.calls.count, 1)
    let call = try XCTUnwrap(stub.calls.first)
    XCTAssertEqual(call.system, OrgProseRevisionRequest.systemPrompt)
    XCTAssertEqual(call.model, "stub-model")
    XCTAssertEqual(call.maxTokens, OrgProseRevisionRequest.maxTokens)
    XCTAssertTrue(call.prompt.contains("<passage>\nbrave world.\n\n</passage>"))
    XCTAssertTrue(call.prompt.contains("<before>\nHello \n</before>"))
  }

  // MARK: Provider choice

  func testPreferencesRememberTheLastProviderAndModel() throws {
    let suite = "org2.prose.revision.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let destinations = [
      AIChatDestinationConfiguration(id: "codex", name: "Codex", mention: "codex", adapter: .codexLocal),
      AIChatDestinationConfiguration(id: "a", name: "Anthropic", mention: "anthropic", adapter: .anthropic, model: "claude-test"),
      AIChatDestinationConfiguration(id: "o", name: "Ollama", mention: "ollama", adapter: .ollama, model: "llama-test"),
      AIChatDestinationConfiguration(id: "off", name: "Off", mention: "off", adapter: .openAI, isEnabled: false)
    ]
    let candidates = OrgProseRevisionPreferences.candidates(from: destinations)
    XCTAssertEqual(candidates.map(\.id), ["a", "o"])

    let preferences = OrgProseRevisionPreferences(defaults: defaults)
    XCTAssertEqual(preferences.preferredDestination(among: candidates)?.id, "a")
    XCTAssertEqual(preferences.preferredModel(for: candidates[0]), "claude-test")

    preferences.remember(destinationID: "o", model: " llama-custom ")
    XCTAssertEqual(preferences.preferredDestination(among: candidates)?.id, "o")
    XCTAssertEqual(preferences.preferredModel(for: candidates[1]), "llama-custom")
    XCTAssertEqual(preferences.preferredModel(for: candidates[0]), "claude-test")
    XCTAssertEqual(preferences.preferredDestination(among: [candidates[0]])?.id, "a")
    XCTAssertNil(preferences.preferredDestination(among: []))
  }

  func testProvenanceCaptions() {
    XCTAssertEqual(OrgProsePresentation.aiCaption(nil), "AI")
    XCTAssertEqual(OrgProsePresentation.aiCaption(provenance), "AI · test-model")
    let detail = OrgProsePresentation.aiDetail(provenance)
    XCTAssertTrue(detail.contains("Provider: Anthropic API"))
    XCTAssertTrue(detail.contains("Instruction: stronger"))
  }
}
