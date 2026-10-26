import XCTest
@testable import Org2WorkspaceCore

final class AIChatContextBudgetTests: XCTestCase {
  func testPersistentContextUsesRecoveryThenDeltaOnly() throws {
    let transcript = "Selected AI chat thread continuation\n\n" + String(repeating: "old turn ", count: 8_000)
    let initialPrompt = [
      "Celorga working rules\n\nKeep citations stable.",
      "Project context\n\nVersion one.",
      transcript,
    ].joined(separator: "\n\n---\n\n")

    let recovery = AIChatContextBudget.persistentEnvelope(
      fullPrompt: initialPrompt,
      previousSections: nil,
      forceRecovery: false,
      includesTranscript: true
    )
    XCTAssertEqual(recovery.telemetry.mode, .recovery)
    XCTAssertLessThanOrEqual(
      recovery.telemetry.transcriptTokens,
      AIChatContextBudget.recoveryTranscriptTokenBudget
    )
    XCTAssertFalse(recovery.sectionSnapshot.keys.contains {
      $0.hasPrefix("Selected AI chat thread continuation#")
    })
    XCTAssertTrue(recovery.sectionSnapshot.values.allSatisfy { $0.count == 64 })
    XCTAssertFalse(recovery.sectionSnapshot.values.contains("Keep citations stable."))

    let unchanged = AIChatContextBudget.persistentEnvelope(
      fullPrompt: initialPrompt,
      previousSections: recovery.sectionSnapshot,
      forceRecovery: false,
      includesTranscript: true
    )
    XCTAssertEqual(unchanged.telemetry.mode, .delta)
    XCTAssertNil(unchanged.prompt)
    XCTAssertEqual(unchanged.telemetry.totalTokens, 0)

    let changedPrompt = initialPrompt.replacingOccurrences(
      of: "Project context\n\nVersion one.",
      with: "Project context\n\nVersion two."
    )
    let changed = AIChatContextBudget.persistentEnvelope(
      fullPrompt: changedPrompt,
      previousSections: recovery.sectionSnapshot,
      forceRecovery: false,
      includesTranscript: true
    )
    XCTAssertEqual(changed.telemetry.mode, .delta)
    XCTAssertTrue(try XCTUnwrap(changed.prompt).contains("Version two"))
    XCTAssertFalse(try XCTUnwrap(changed.prompt).contains("Selected AI chat thread continuation"))

    let removed = AIChatContextBudget.persistentEnvelope(
      fullPrompt: "Celorga working rules\n\nKeep citations stable.",
      previousSections: changed.sectionSnapshot,
      forceRecovery: false,
      includesTranscript: true
    )
    XCTAssertTrue(try XCTUnwrap(removed.prompt).contains("Project context"))
    XCTAssertTrue(try XCTUnwrap(removed.prompt).contains("no longer present"))
  }

  func testStatelessHistoryHasOneHardTokenBudget() {
    let messages = (0..<80).map { index in
      AIChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: String(repeating: "x", count: 1_000))
    }
    let bounded = AIChatContextBudget.boundedHistory(messages)
    let estimated = bounded.reduce(0) {
      $0 + AIChatContextBudget.estimatedTokens($1.content)
        + AIChatContextBudget.estimatedAttachmentTokens($1.attachments) + 8
    }
    XCTAssertLessThanOrEqual(estimated, AIChatContextBudget.statelessHistoryTokenBudget)
    XCTAssertLessThan(bounded.count, messages.count)
    XCTAssertEqual(bounded.last?.id, messages.last?.id)
  }

  func testStatelessHistoryNeverTruncatesCurrentRequest() throws {
    let earlier = AIChatMessage(role: .assistant, content: String(repeating: "history ", count: 2_000))
    let currentContent = "BEGIN-CURRENT\n" + String(repeating: "instruction ", count: 8_000) + "\nEND-CURRENT"
    let current = AIChatMessage(role: .user, content: currentContent)

    let bounded = AIChatContextBudget.boundedHistory(
      [earlier, current],
      tokenBudget: 100
    )

    XCTAssertEqual(bounded.count, 1)
    XCTAssertEqual(try XCTUnwrap(bounded.last).content, currentContent)
  }

  func testBoundedSuffixIsUTF8SafeAndWithinBudget() {
    let bounded = AIChatContextBudget.boundedSuffix(
      String(repeating: "🙂é", count: 1_000),
      tokenBudget: 64
    )

    XCTAssertLessThanOrEqual(bounded.utf8.count, 64 * 4)
    XCTAssertTrue(bounded.hasPrefix("[Earlier content omitted]"))
    XCTAssertFalse(bounded.contains("�"))
  }

  func testPersistentContinuationBenchmarkMeetsRegressionBudget() {
    let baseProject = "Project context\n\n" + String(repeating: "project ", count: 1_000)
    let fullPrompt = [
      "Celorga working rules\n\n" + String(repeating: "rules ", count: 2_000),
      baseProject,
      "Selected AI chat thread continuation\n\n" + String(repeating: "history ", count: 4_000),
    ].joined(separator: "\n\n---\n\n")
    let turns = 20
    let before = AIChatContextBudget.estimatedTokens(fullPrompt) * turns
    let first = AIChatContextBudget.persistentEnvelope(
      fullPrompt: fullPrompt,
      previousSections: nil,
      forceRecovery: false,
      includesTranscript: true
    )
    var after = first.telemetry.totalTokens
    var snapshot = first.sectionSnapshot
    for turn in 1..<turns {
      let projectVersion = turn.isMultiple(of: 5)
        ? baseProject + "\nProject delta \(turn)"
        : baseProject
      let turnPrompt = fullPrompt.replacingOccurrences(of: baseProject, with: projectVersion)
      let next = AIChatContextBudget.persistentEnvelope(
        fullPrompt: turnPrompt,
        previousSections: snapshot,
        forceRecovery: turn == 10,
        includesTranscript: true
      )
      after += next.telemetry.totalTokens
      snapshot = next.sectionSnapshot
    }
    let reductionPercent = 100 - (after * 100 / before)
    XCTAssertGreaterThanOrEqual(reductionPercent, 80)
  }

  func testResponseTraceRoundTripsProviderAndComponentTelemetry() throws {
    let trace = AIChatResponseTrace(
      usage: AIChatTokenUsage(
        inputTokens: 120,
        cachedInputTokens: 80,
        outputTokens: 30,
        totalTokens: 150
      ),
      context: OpenOrgContextTelemetry(
        mode: .delta,
        staticTokens: 20,
        projectTokens: 10,
        roomTokens: 5
      )
    )
    let decoded = try JSONDecoder().decode(
      AIChatResponseTrace.self,
      from: JSONEncoder().encode(trace)
    )
    XCTAssertEqual(decoded, trace)
    XCTAssertEqual(decoded.context?.totalTokens, 35)
  }

  /// Codex now receives standing instructions as developer instructions. A
  /// session that saw them in an earlier snapshot must not be told to drop them.
  func testDeltaDoesNotRetractStandingInstructionsMovedOutOfTheSnapshot() {
    let earlier = AIChatContextBudget.persistentEnvelope(
      fullPrompt: [
        "Celorga workspace UI snapshot\n\nCurrent surface: AI Chat",
        "Celorga working rules\n\nKeep citations stable.",
        "Celorga response formatting contract\n\nUse Org.",
        "Search context: launch\n- result",
      ].joined(separator: "\n\n---\n\n"),
      previousSections: nil,
      forceRecovery: true,
      includesTranscript: true
    )
    let delta = AIChatContextBudget.persistentEnvelope(
      fullPrompt: "Celorga workspace UI snapshot\n\nCurrent surface: AI Chat",
      previousSections: earlier.sectionSnapshot,
      forceRecovery: false,
      includesTranscript: true
    )
    let prompt = try? XCTUnwrap(delta.prompt)
    XCTAssertTrue(prompt?.contains("Search context: launch") == true)
    XCTAssertFalse(prompt?.contains("Celorga working rules") == true)
    XCTAssertFalse(prompt?.contains("Celorga response formatting contract") == true)
  }

  func testTelemetryClassifiesDynamicWorkspaceContextAndExcludesCurrentRequest() {
    let system = [
      "Celorga workspace operating context\n\nCorpus roots",
      "Project notes linked to this chat\n\nProject brief",
      "Celorga working rules\n\nStable instruction",
    ].joined(separator: "\n\n---\n\n")
    let history = [
      AIChatMessage(role: .assistant, content: "Earlier answer"),
      AIChatMessage(role: .user, content: "Current request"),
    ]

    let telemetry = AIChatContextBudget.statelessTelemetry(
      systemPrompt: system,
      history: history
    )

    XCTAssertGreaterThan(telemetry.projectTokens, 0)
    XCTAssertGreaterThan(telemetry.staticTokens, 0)
    XCTAssertEqual(
      telemetry.transcriptTokens,
      AIChatContextBudget.estimatedTokens("Earlier answer") + 8
    )
  }

  func testPersistentContextStateCommitsSuccessfulTurnThenUsesEmptyDelta() {
    var state = AIChatPersistentContextState()
    let key = persistentKey()
    let first = state.envelope(
      for: key,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    XCTAssertEqual(first.telemetry.mode, .recovery)

    state.commit(first, for: key)
    let second = state.envelope(
      for: key,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    XCTAssertEqual(second.telemetry.mode, .delta)
    XCTAssertNil(second.prompt)
  }

  func testPersistentContextStateRestoresAcceptedSnapshotAfterProcessRelaunch() {
    let key = persistentKey(destinationID: "openclaw:main")
    var originalState = AIChatPersistentContextState()
    let accepted = originalState.envelope(
      for: key,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )

    var restoredState = AIChatPersistentContextState()
    restoredState.commit(accepted.sectionSnapshot, for: key)
    let continuation = restoredState.envelope(
      for: key,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )

    XCTAssertEqual(continuation.telemetry.mode, .delta)
    XCTAssertNil(continuation.prompt)
  }

  func testPersistentContextStateForcesExactlyOneRecoveryAfterCompaction() {
    var state = AIChatPersistentContextState()
    let key = persistentKey()
    let first = state.envelope(
      for: key,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    state.commit(first, for: key)
    state.requireRecovery(for: Set([key]))

    let recovery = state.envelope(
      for: key,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    XCTAssertEqual(recovery.telemetry.mode, .recovery)
    state.commit(recovery, for: key)

    let next = state.envelope(
      for: key,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    XCTAssertEqual(next.telemetry.mode, .delta)
    XCTAssertNil(next.prompt)
  }

  func testPersistentContextStateDoesNotCommitFailedTurn() {
    var state = AIChatPersistentContextState()
    let key = persistentKey()
    let failed = state.envelope(
      for: key,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    XCTAssertEqual(failed.telemetry.mode, .recovery)

    let retry = state.envelope(
      for: key,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    XCTAssertEqual(retry.telemetry.mode, .recovery)
  }

  func testPersistentContextStateIsolatesCorpusThreadDestinationAndRuntimeSession() {
    var state = AIChatPersistentContextState()
    let base = persistentKey()
    let first = state.envelope(
      for: base,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    state.commit(first, for: base)

    let isolatedKeys = [
      persistentKey(transcriptPath: "/corpus-b/chat.org"),
      persistentKey(threadID: UUID()),
      persistentKey(destinationID: "openclaw:reviewer"),
    ]
    for key in isolatedKeys {
      let envelope = state.envelope(
        for: key,
        fullPrompt: { _ in self.persistentPrompt },
        includesTranscript: true,
        roomPrompt: "",
        attachments: []
      )
      XCTAssertEqual(envelope.telemetry.mode, .recovery)
    }

    let unchangedBase = state.envelope(
      for: base,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    XCTAssertEqual(unchangedBase.telemetry.mode, .delta)
    XCTAssertNil(unchangedBase.prompt)

    let replacementRuntime = persistentKey(runtimeSessionID: "runtime-2")
    let replacement = state.envelope(
      for: replacementRuntime,
      fullPrompt: { _ in self.persistentPrompt },
      includesTranscript: true,
      roomPrompt: "",
      attachments: []
    )
    XCTAssertEqual(replacement.telemetry.mode, .recovery)
  }

  private var persistentPrompt: String {
    [
      "Celorga working rules\n\nKeep citations stable.",
      "Selected AI chat thread continuation\n\nEarlier turn.",
    ].joined(separator: "\n\n---\n\n")
  }

  private func persistentKey(
    transcriptPath: String = "/corpus-a/chat.org",
    threadID: UUID = UUID(uuidString: "A13F4E0E-55C7-49E1-AC3D-333954411D17")!,
    destinationID: String = "codex:local",
    runtimeSessionID: String = "runtime-1"
  ) -> AIChatPersistentContextKey {
    AIChatPersistentContextKey(
      transcriptPath: transcriptPath,
      threadID: threadID,
      destinationID: destinationID,
      runtimeSessionID: runtimeSessionID
    )
  }
}
