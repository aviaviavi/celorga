import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

private final class WorkspaceObservationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedChangeCount = 0

  var changeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedChangeCount
  }

  func recordChange() {
    lock.lock()
    recordedChangeCount += 1
    lock.unlock()
  }
}

private final class WorkspaceThreadAffinityProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var observations: [Bool] = []

  func record(isMainThread: Bool) {
    lock.lock()
    observations.append(isMainThread)
    lock.unlock()
  }

  var snapshot: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return observations
  }
}

@MainActor
final class WorkspacePerformanceRegressionTests: XCTestCase {
  func testRunCenterDetailUsesBoundedProgressiveCollections() throws {
    for collection in RunCenterDetailCollection.allCases {
      XCTAssertEqual(
        RunCenterDetailCollectionPresentation.visibleCount(
          total: 50_000,
          requestedLimit: nil
        ),
        RunCenterDetailCollectionPresentation.initialItemLimit,
        "\(collection.rawValue) must start with a bounded window"
      )
    }
    XCTAssertEqual(
      RunCenterDetailCollectionPresentation.nextVisibleCount(
        total: 50_000,
        currentLimit: nil
      ),
      RunCenterDetailCollectionPresentation.initialItemLimit
        + RunCenterDetailCollectionPresentation.pageItemCount
    )
    XCTAssertEqual(
      RunCenterDetailCollectionPresentation.nextVisibleCount(
        total: 45,
        currentLimit: 32
      ),
      45
    )

    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try SplitSourceText.read(packageRoot
        .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift"))
    let detailStart = try XCTUnwrap(source.range(of: "struct RunCenterDetail: View"))
    let detailEnd = try XCTUnwrap(source.range(
      of: "struct RunCompletionSheet: View",
      range: detailStart.upperBound..<source.endIndex
    ))
    let detail = String(source[detailStart.lowerBound..<detailEnd.lowerBound])
    XCTAssertTrue(detail.contains("LazyVStack(alignment: .leading"))
    XCTAssertTrue(detail.contains("visiblePendingApprovals(pending)"))
    XCTAssertTrue(detail.contains("run.artifacts.prefix(visibleCount"))
    XCTAssertTrue(detail.contains("run.plan.prefix(visibleCount"))
    XCTAssertTrue(detail.contains("run.context\n              .prefix(visibleCount"))
    XCTAssertTrue(detail.contains("run.comments.prefix(visibleCount"))
    XCTAssertTrue(source.contains("let summary = item.listSummary"))
    XCTAssertFalse(source.contains("Org2Display.cleanBlock(item.body)"))
  }

  func testReviewSelectionMountsOnlyTheSelectedApprovalDetail() {
    let ids = (0..<10_000).map { "approval-\($0)" }

    XCTAssertEqual(
      RunCenterDetailCollectionPresentation.visiblePendingApprovalIDs(
        ids,
        selectedID: "approval-9000",
        requestedLimit: nil
      ),
      ["approval-9000"]
    )
    XCTAssertEqual(
      RunCenterDetailCollectionPresentation.visiblePendingApprovalIDs(
        ids,
        selectedID: nil,
        requestedLimit: nil
      ),
      Array(ids.prefix(RunCenterDetailCollectionPresentation.initialItemLimit))
    )
  }

  func testApprovalRowPreviewDoesNotNormalizeTheWholeBody() {
    let visiblePrefix = "Review this exact message."
    let oversizedTail = String(repeating: "\n[[https://example.com][evidence]]", count: 100_000)
    let item = ApprovalItem(
      title: "Large approval",
      status: "pending",
      todo: nil,
      level: nil,
      file: "/tmp/large-run.org2",
      line: 1,
      idValue: nil,
      properties: [:],
      body: visiblePrefix + oversizedTail,
      tags: []
    )

    XCTAssertTrue(item.displayBodyPreview.hasPrefix(visiblePrefix))
    XCTAssertLessThanOrEqual(item.displayBodyPreview.count, 223)
    XCTAssertTrue(item.listSummary.hasPrefix(visiblePrefix))
    XCTAssertLessThanOrEqual(item.listSummary.count, 203)
  }

  func testLiveChatAppendsLargeCodexTokenBurstWithoutCumulativeReplacement() {
    let liveState = AIChatLiveState()
    let threadID = UUID()
    let tokenCount = 10_000

    for _ in 0..<tokenCount {
      liveState.appendStreamingDelta("x", for: threadID)
    }

    XCTAssertEqual(liveState.streamingReply(for: threadID).count, tokenCount)
  }

  func testLiveChatMultiMegabyteStreamsKeepFlushAndPresentationWorkBounded() {
    let liveState = AIChatLiveState()
    let threadID = UUID()
    let chunk = "abcdefghijklmno🙂"
    let chunkCount = 65_536
    let expectedCharacterCount = chunk.count * chunkCount

    for index in 0..<chunkCount {
      liveState.appendStreamingDelta(chunk, for: threadID)
      liveState.appendReasoningDelta(chunk, for: threadID)
      if (index + 1).isMultiple(of: 512) {
        liveState.flushPendingStreamUpdates()
      }
    }
    liveState.flushPendingStreamUpdates()

    let snapshot = liveState.presentationSnapshot(for: threadID)
    XCTAssertTrue(snapshot.isStreamingReplyTruncated)
    XCTAssertTrue(snapshot.isReasoningTruncated)
    XCTAssertEqual(
      snapshot.streamingReply.count,
      AIChatLiveState.maximumPresentationCharacterCount
    )
    XCTAssertEqual(
      snapshot.reasoning.count,
      AIChatLiveState.maximumPresentationCharacterCount
    )
    XCTAssertLessThanOrEqual(
      liveState.retainedPresentationCharacterCountForTesting(threadID),
      AIChatLiveState.maximumPresentationCharacterCount * 2
    )
    XCTAssertLessThanOrEqual(
      liveState.maximumPresentationCharactersVisitedPerSnapshotForTesting,
      AIChatLiveState.maximumPresentationCharacterCount * 2
    )
    let maximumExpectedSegmentCount =
      expectedCharacterCount / AIChatLiveState.streamSegmentTargetCharacterCountForTesting + 1
    XCTAssertLessThanOrEqual(
      liveState.streamingSegmentCountForTesting(threadID),
      maximumExpectedSegmentCount
    )
    XCTAssertLessThanOrEqual(
      liveState.reasoningSegmentCountForTesting(threadID),
      maximumExpectedSegmentCount
    )
    XCTAssertEqual(
      liveState.fullTextMaterializationCountForTesting,
      0,
      "Publishing bounded live snapshots must not assemble either full stream"
    )

    let exact = String(repeating: chunk, count: chunkCount)
    XCTAssertEqual(liveState.streamingReply(for: threadID), exact)
    XCTAssertEqual(liveState.reasoning(for: threadID), exact)

    liveState.replaceStreamingReply("replacement🙂", for: threadID, coalesced: true)
    liveState.appendStreamingDelta(" tail", for: threadID)
    liveState.replaceReasoning("new reasoning", for: threadID, coalesced: true)
    liveState.appendReasoningDelta(" tail", for: threadID)
    liveState.flushPendingStreamUpdates()

    XCTAssertEqual(liveState.streamingReply(for: threadID), "replacement🙂 tail")
    XCTAssertEqual(liveState.reasoning(for: threadID), "new reasoning tail")
    XCTAssertEqual(
      liveState.presentationSnapshot(for: threadID),
      AIChatLivePresentationSnapshot(
        streamingReply: "replacement🙂 tail",
        reasoning: "new reasoning tail",
        isStreamingReplyTruncated: false,
        isReasoningTruncated: false
      )
    )
  }

  func testInteractionLatencyP95UsesTheSlowestFivePercentBoundary() {
    let samples = (1...100).map(Double.init)
    XCTAssertEqual(WorkspaceInteractionLatency.percentile95(samples), 95)
    XCTAssertEqual(WorkspaceInteractionLatency.percentile95([]), 0)
  }

  func testSourceEditorInteractionChangesStayScopedToTheEditor() {
    let store = WorkspaceStore()
    let editableEntryTextObservation = WorkspaceObservationProbe()
    withObservationTracking {
      _ = store.editableEntryText
    } onChange: {
      editableEntryTextObservation.recordChange()
    }

    store.sourceEditorInteraction.text = "Fast local draft"
    store.sourceEditorSelection = NSRange(location: 4, length: 6)

    XCTAssertEqual(store.sourceEditorInteraction.text, "Fast local draft")
    XCTAssertEqual(store.sourceEditorSelection, NSRange(location: 4, length: 6))
    XCTAssertEqual(
      editableEntryTextObservation.changeCount,
      0,
      "Typing and selection must not invalidate unrelated workspace editor state"
    )
  }

  func testWorkspaceObservationInvalidatesOnlyTrackedProperties() {
    let store = WorkspaceStore()
    let selectedSurfaceObservation = WorkspaceObservationProbe()
    withObservationTracking {
      _ = store.selectedSurface
    } onChange: {
      selectedSurfaceObservation.recordChange()
    }

    store.statusText = "Background status changed"
    XCTAssertEqual(
      selectedSurfaceObservation.changeCount,
      0,
      "An unrelated status update must not invalidate a selected-surface observer"
    )

    store.selectedSurface = .files
    XCTAssertEqual(
      selectedSurfaceObservation.changeCount,
      1,
      "Changing the tracked selected surface must invalidate its observer"
    )
  }

  func testWorkspaceObservationTracksComputedPropertiesAndExtensionMutations() {
    let domain = "WorkspaceObservationExtensions-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = WorkspaceStore(defaults: defaults)
    let filtersChanged = WorkspaceObservationProbe()
    let hostChanged = WorkspaceObservationProbe()
    withObservationTracking {
      _ = store.hasAgendaStructuredFilters
    } onChange: {
      filtersChanged.recordChange()
    }
    withObservationTracking {
      _ = store.automationHostRef
    } onChange: {
      hostChanged.recordChange()
    }

    store.statusText = "Unrelated background update"
    XCTAssertEqual(filtersChanged.changeCount, 0)
    XCTAssertEqual(hostChanged.changeCount, 0)

    store.setAgendaDateFilter(.next7)
    XCTAssertTrue(store.hasAgendaStructuredFilters)
    XCTAssertEqual(filtersChanged.changeCount, 1)
    XCTAssertEqual(hostChanged.changeCount, 0)

    store.automationHostRef = "test-host"
    XCTAssertEqual(hostChanged.changeCount, 1)
  }

  func testLargeSourceEditorDefersFullDocumentSnapshotUntilTypingIsIdle() async throws {
    let original = String(repeating: "* Heading\nBody with enough text to model a real source file.\n", count: 90_000)
    XCTAssertGreaterThan((original as NSString).length, 4_000_000)
    var boundText = original
    var localText: String?
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 40),
      liveHighlighting: false,
      incrementalHighlighting: false,
      semanticAnalysisDelayMilliseconds: 900,
      onLocalTextChange: { localText = $0 }
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = original
    textView.textStorage?.delegate = coordinator
    coordinator.recordKnownText(original, utf16Length: textView.textStorage?.length)
    coordinator.resetLineIndex(from: textView)

    let insertion = NSRange(location: textView.textStorage?.length ?? 0, length: 0)
    let startedAt = CACurrentMediaTime()
    XCTAssertTrue(coordinator.textView(
      textView,
      shouldChangeTextIn: insertion,
      replacementString: "x"
    ))
    textView.textStorage?.replaceCharacters(in: insertion, with: "x")
    textView.setSelectedRange(NSRange(location: insertion.location + 1, length: 0))
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    let synchronousElapsed = CACurrentMediaTime() - startedAt

    XCTAssertLessThan(
      synchronousElapsed,
      1.0 / 60.0,
      "A large-buffer edit callback must fit within one 60 Hz frame"
    )
    XCTAssertEqual(coordinator.fullDocumentSnapshotCount, 0)
    XCTAssertEqual(boundText, original)
    XCTAssertNil(localText)
    XCTAssertTrue(coordinator.hasUnpublishedLocalText)

    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, boundText == original {
      await Task.yield()
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(boundText.hasSuffix("x"))
    XCTAssertEqual(localText, boundText)
    XCTAssertEqual(coordinator.fullDocumentSnapshotCount, 1)
    XCTAssertEqual(coordinator.mainActorFullDocumentSnapshotCount, 0)
    XCTAssertFalse(coordinator.hasUnpublishedLocalText)
  }

  func testDeepSourceLineQueriesStayIndependentOfDocumentLength() {
    let text = NSString(string: String(repeating: "0123456789 source line\n", count: 250_000))
    let index = OrgSourceLineIndex(text: text)
    let startedAt = CACurrentMediaTime()
    var checksum = 0
    for query in 0..<20_000 {
      let offset = (query &* 104_729) % text.length
      checksum &+= index.lineNumber(atUTF16Offset: offset)
    }
    let elapsed = CACurrentMediaTime() - startedAt

    XCTAssertGreaterThan(checksum, 0)
    XCTAssertLessThan(
      elapsed,
      0.10,
      "Deep line lookup must use the incremental index rather than scan from byte zero"
    )
  }

  func testLargeSourceLineIndexBuildStartsWithoutBlockingTheMainActor() async {
    let text = String(repeating: "0123456789 source line\n", count: 250_000)
    var boundText = text
    let editor = OrgSyntaxTextEditor(
      text: Binding(get: { boundText }, set: { boundText = $0 }),
      liveHighlighting: false
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)

    let startedAt = CACurrentMediaTime()
    coordinator.scheduleLineIndexReset(text: text)
    let synchronousElapsed = CACurrentMediaTime() - startedAt

    XCTAssertLessThan(synchronousElapsed, 1.0 / 60.0)
    await coordinator.waitForLineIndexBuildForTesting()
    let textView = NSTextView()
    textView.string = text
    XCTAssertEqual(
      coordinator.sourceLine(atUTF16Offset: (text as NSString).length - 1, in: textView),
      250_000
    )
  }

  func testCorpusConfigurationAndUndoFileReadsStayOffMainActor() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-store-file-io-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("public-keys", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".codex/skills/sample", isDirectory: true),
      withIntermediateDirectories: true
    )
    try #"{"roam":{"dailiesDir":"daily"}}"#.write(
      to: root.appendingPathComponent("org2.json"),
      atomically: true,
      encoding: .utf8
    )
    try "PUBLIC KEY".write(
      to: root.appendingPathComponent("public-keys/sample.asc"),
      atomically: true,
      encoding: .utf8
    )
    try "# Sample\n".write(
      to: root.appendingPathComponent(".codex/skills/sample/SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
    let note = root.appendingPathComponent("large-note.org")
    try String(repeating: "* Heading\nBody\n", count: 10_000).write(
      to: note,
      atomically: true,
      encoding: .utf8
    )

    let dailyProbe = WorkspaceThreadAffinityProbe()
    let skillProbe = WorkspaceThreadAffinityProbe()
    let cryptProbe = WorkspaceThreadAffinityProbe()
    let undoProbe = WorkspaceThreadAffinityProbe()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.dailyNoteDirectoryPreparationForTesting = { dailyProbe.record(isMainThread: $0) }
    store.corpusAgentSkillDiscoveryForTesting = { skillProbe.record(isMainThread: $0) }
    store.orgCryptRecipientScanForTesting = { cryptProbe.record(isMainThread: $0) }
    store.fileUndoSnapshotReadForTesting = { undoProbe.record(isMainThread: $0) }

    store.setCorpusRoot(root, persistsDefault: false)
    await store.waitForDailyNoteDirectoryPreparationForTesting(corpusRoot: root)
    await store.waitForCorpusAgentSkillRefreshForTesting()
    await store.waitForOrgCryptRecipientRefreshForTesting()
    let preparedUndoSnapshot = await store.prepareFileUndoSnapshotForTesting(file: note.path)
    XCTAssertTrue(preparedUndoSnapshot)

    for (label, observations) in [
      ("daily configuration", dailyProbe.snapshot),
      ("skill discovery", skillProbe.snapshot),
      ("recipient scan", cryptProbe.snapshot),
      ("undo snapshot", undoProbe.snapshot),
    ] {
      XCTAssertFalse(observations.isEmpty, "Expected a \(label) observation")
      XCTAssertFalse(observations.contains(true), "\(label) performed filesystem work on MainActor")
    }
  }

  func testRuntimeIdentityReportsTheCompiledOptimizationMode() {
#if DEBUG
    XCTAssertEqual(WorkspaceRuntimeIdentity.compiledBuildConfiguration, "debug")
#else
    XCTAssertEqual(WorkspaceRuntimeIdentity.compiledBuildConfiguration, "release")
#endif
  }
}
