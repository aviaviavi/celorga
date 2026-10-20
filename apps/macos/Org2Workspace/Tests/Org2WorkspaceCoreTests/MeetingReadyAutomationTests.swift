import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor MeetingAutomationSendRecorder {
  private var calls: [[AIChatMessage]] = []

  func send(_ messages: [AIChatMessage]) -> String {
    calls.append(messages)
    return "Meeting processed"
  }

  func callCount() -> Int {
    calls.count
  }
}

private actor SuspendedMeetingTranscription {
  private var started = false
  private var continuation: CheckedContinuation<MeetingTranscriptResult, Never>?

  func transcribe() async -> MeetingTranscriptResult {
    started = true
    return await withCheckedContinuation { continuation = $0 }
  }

  func waitUntilStarted() async {
    while !started { await Task.yield() }
  }

  func finish() {
    continuation?.resume(returning: MeetingTranscriptResult(
      text: "alpha transcript",
      status: .complete,
      engine: "test",
      errorMessage: nil
    ))
    continuation = nil
  }
}

final class MeetingReadyAutomationTests: XCTestCase {
  @MainActor
  func testOnlySuccessfulCompletionEventsQueueEachNewMeetingOnce() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let recorder = MeetingAutomationSendRecorder()
    let store = WorkspaceStore(
      defaults: fixture.defaults,
      aiChatTranscriptURL: fixture.transcript,
      aiChatSendHandler: { messages, _, _, _ in
        await recorder.send(messages)
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(fixture.root, persistsDefault: false)
    let oldMeeting = meeting(
      title: "Old planning call",
      file: fixture.root.appendingPathComponent("meetings/old.org2").path,
      idValue: "old-meeting"
    )
    store.meetings = [oldMeeting]

    XCTAssertTrue(store.saveMeetingReadyAutomationConfiguration(
      isEnabled: true,
      destinationID: AIChatDestinationConfiguration.openClawID,
      threadMode: .newThread,
      threadID: nil,
      prompt: "Extract the follow-ups."
    ))
    XCTAssertFalse(store.aiChatThreads.contains(where: { $0.title.contains("Old planning call") }))

    let newMeeting = meeting(
      title: "Launch review",
      file: fixture.root.appendingPathComponent("meetings/launch-review.org2").path,
      idValue: "launch-review"
    )
    let unavailableMeeting = meeting(
      title: "Transcript needs attention",
      file: fixture.root.appendingPathComponent("meetings/transcript-needs-attention.org2").path,
      idValue: "transcript-needs-attention",
      transcriptionStatus: "unavailable"
    )
    let failedMeeting = meeting(
      title: "Transcript failed",
      file: fixture.root.appendingPathComponent("meetings/transcript-failed.org2").path,
      idValue: "transcript-failed",
      transcriptionStatus: "failed"
    )
    store.meetingTranscriptionDidCompleteForTesting(newMeeting)
    store.meetingTranscriptionDidCompleteForTesting(newMeeting)
    store.meetingTranscriptionDidCompleteForTesting(unavailableMeeting)
    store.meetingTranscriptionDidCompleteForTesting(failedMeeting)

    let thread = try XCTUnwrap(
      store.aiChatThreads.first(where: { $0.title.contains("Launch review") })
    )
    let userMessages = thread.messages.filter { $0.role == .user }
    XCTAssertEqual(userMessages.count, 1)
    XCTAssertTrue(userMessages[0].content.contains(
      "#+org2_automation_event_id: meeting-ready:meeting-id:launch-review"
    ))
    XCTAssertTrue(userMessages[0].content.contains("Extract the follow-ups."))

    XCTAssertFalse(store.aiChatThreads.contains(where: {
      $0.title.contains("Transcript needs attention") || $0.title.contains("Transcript failed")
    }))
  }

  @MainActor
  func testRelaunchAndRefreshDoNotQueueHistoricalCompletedMeetings() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let firstStore = WorkspaceStore(
      defaults: fixture.defaults,
      aiChatTranscriptURL: fixture.transcript,
      legacyDefaultsDomains: []
    )
    firstStore.setCorpusRoot(fixture.root, persistsDefault: false)
    let threadID = firstStore.createAIChatThread(runtime: .openClaw)
    firstStore.settleAIChatThread(threadID)
    XCTAssertTrue(firstStore.saveMeetingReadyAutomationConfiguration(
      isEnabled: true,
      destinationID: AIChatDestinationConfiguration.openClawID,
      threadMode: .existingThread,
      threadID: threadID,
      prompt: "Process the completed meeting."
    ))
    firstStore.flushDeferredAIChatTranscriptPersistence()

    let relaunchedStore = WorkspaceStore(
      defaults: fixture.defaults,
      aiChatTranscriptURL: fixture.transcript,
      legacyDefaultsDomains: []
    )
    relaunchedStore.setCorpusRoot(fixture.root, persistsDefault: false)
    XCTAssertTrue(relaunchedStore.meetingReadyAutomationSettings.isEnabled)
    XCTAssertEqual(relaunchedStore.meetingReadyAutomationSettings.threadID, threadID)

    let meetingsDirectory = fixture.root.appendingPathComponent("meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
    let file = meetingsDirectory.appendingPathComponent("customer-sync.org2")
    try """
    #+TITLE: Meeting: Customer sync
    #+ORG2_KIND: meeting

    * Meeting: Customer sync
    :PROPERTIES:
    :ID: customer-sync
    :kind: meeting
    :recorded_at: 2026-08-19T12:00:00-07:00
    :audio_artifact: meetings/customer-sync.wav
    :transcript_artifact: meetings/customer-sync.transcript.org2
    :transcription_status: complete
    :END:
    """.write(to: file, atomically: true, encoding: .utf8)

    await relaunchedStore.refreshMeetings()
    await relaunchedStore.refreshMeetings()

    let target = try XCTUnwrap(
      relaunchedStore.aiChatThreads.first(where: { $0.id == threadID })
    )
    XCTAssertTrue(target.isSettled)
    XCTAssertEqual(target.messages.filter { $0.role == .user }.count, 0)
    XCTAssertFalse(relaunchedStore.aiChatThreads.contains(where: {
      $0.messages.contains(where: { $0.content.contains("meeting-ready:meeting-id:customer-sync") })
    }))
  }

  @MainActor
  func testLinkifiedFileLevelIDDoesNotQueueMeetingTwiceAfterRefresh() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let store = WorkspaceStore(
      defaults: fixture.defaults,
      aiChatTranscriptURL: fixture.transcript,
      aiChatSendHandler: { _, _, _, _ in "Meeting processed" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(fixture.root, persistsDefault: false)
    XCTAssertTrue(store.saveMeetingReadyAutomationConfiguration(
      isEnabled: true,
      destinationID: AIChatDestinationConfiguration.openClawID,
      threadMode: .newThread,
      threadID: nil,
      prompt: "Process the completed meeting."
    ))

    let meetingsDirectory = fixture.root.appendingPathComponent("meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
    let file = meetingsDirectory.appendingPathComponent("customer-sync.org2")
    let canonicalMeetingID = "048c73c3-b253-4964-9aee-3f3e625d55cc"
    let initialItem = meeting(
      title: "Customer sync",
      file: file.path,
      idValue: canonicalMeetingID
    )
    store.meetingTranscriptionDidCompleteForTesting(initialItem)

    try """
    :PROPERTIES:
    :ID: 3494fc49-0103-40bc-b35c-ec696a09ab8e
    :END:

    #+TITLE: Meeting: Customer sync
    #+ORG2_KIND: meeting

    * Meeting: Customer sync
    :PROPERTIES:
    :ID: \(canonicalMeetingID)
    :kind: meeting
    :recorded_at: 2026-08-20T12:00:00-07:00
    :audio_artifact: meetings/customer-sync.wav
    :transcript_artifact: meetings/customer-sync.transcript.org2
    :transcription_status: complete
    :END:
    """.write(to: file, atomically: true, encoding: .utf8)

    await store.refreshMeetings()

    XCTAssertEqual(store.meetings.first?.idValue, canonicalMeetingID)
    let automationMessages = store.aiChatThreads
      .flatMap(\.messages)
      .filter { $0.role == .user && $0.content.contains("#+org2_automation_event_id:") }
    XCTAssertEqual(automationMessages.count, 1)
    XCTAssertTrue(automationMessages[0].content.contains(
      "meeting-ready:meeting-id:\(canonicalMeetingID)"
    ))
  }

  @MainActor
  func testColdExistingThreadQueuesExactlyOnceOnlyAfterHydration() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let selected = AIChatThread(
      title: "Selected",
      sessionKey: "selected",
      messages: [AIChatMessage(role: .assistant, content: "selected")]
    )
    let warm = (0..<16).map { index in
      AIChatThread(
        title: "Warm \(index)",
        sessionKey: "warm-\(index)",
        messages: [AIChatMessage(role: .assistant, content: "warm")]
      )
    }
    let cold = AIChatThread(
      title: "Cold meeting target",
      sessionKey: "cold-meeting-target",
      messages: [AIChatMessage(role: .assistant, content: "existing history")]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [selected] + warm + [cold],
        selectedThreadID: selected.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: fixture.transcript
    )
    let store = WorkspaceStore(
      defaults: fixture.defaults,
      aiChatTranscriptURL: fixture.transcript,
      aiChatSendHandler: { _, _, _, _ in "Meeting processed" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(fixture.root, persistsDefault: false)
    XCTAssertTrue(store.unloadedAIChatThreadIDsForTesting.contains(cold.id))
    XCTAssertTrue(store.saveMeetingReadyAutomationConfiguration(
      isEnabled: true,
      destinationID: AIChatDestinationConfiguration.openClawID,
      threadMode: .existingThread,
      threadID: cold.id,
      prompt: "Process this meeting."
    ))
    let shardLoaded = expectation(description: "cold meeting shard loaded")
    let enqueueResolved = expectation(description: "meeting enqueue resolved")
    store.aiChatThreadHydrationDelayNanosecondsForTesting = 300_000_000
    store.aiChatThreadHydrationDidLoadForTesting = { id in
      if id == cold.id { shardLoaded.fulfill() }
    }
    store.meetingReadyAutomationEnqueueDidResolveForTesting = { _ in
      enqueueResolved.fulfill()
    }
    let item = meeting(
      title: "Deferred launch review",
      file: fixture.root.appendingPathComponent("meetings/deferred-launch.org2").path,
      idValue: "deferred-launch"
    )

    store.meetingTranscriptionDidCompleteForTesting(item)
    store.meetingTranscriptionDidCompleteForTesting(item)
    await fulfillment(of: [shardLoaded], timeout: 2)
    XCTAssertFalse(store.meetingReadyAutomationStatusText.hasPrefix("Queued "))
    XCTAssertFalse(store.meetingReadyAutomationStatusText.contains("pending"))
    await fulfillment(of: [enqueueResolved], timeout: 2)

    let hydrated = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == cold.id }))
    XCTAssertEqual(hydrated.messages.first?.content, "existing history")
    XCTAssertEqual(hydrated.messages.filter {
      $0.role == .user && $0.content.contains("meeting-ready:meeting-id:deferred-launch")
    }.count, 1)
    XCTAssertTrue(store.meetingReadyAutomationStatusText.hasPrefix("Queued "))
  }

  @MainActor
  func testAlphaTranscriptionCompletionCannotPublishOrAutomateInBeta() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-meeting-context-race-\(UUID().uuidString)", isDirectory: true)
    let alpha = base.appendingPathComponent("alpha", isDirectory: true)
    let beta = base.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    let sourceAudio = base.appendingPathComponent("source.m4a")
    try Data("audio".utf8).write(to: sourceAudio)
    defer { try? FileManager.default.removeItem(at: base) }
    let suiteName = "MeetingReadyAutomationTests.TranscriptionContext.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sendRecorder = MeetingAutomationSendRecorder()
    let gate = SuspendedMeetingTranscription()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatFallbackTranscriptURL: base.appendingPathComponent("fallback.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await sendRecorder.send(messages)
      },
      legacyDefaultsDomains: [],
      automaticStarterCorpusURL: nil
    )
    store.setCorpusRoot(alpha, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.meetingTranscriptionForTesting = { _ in await gate.transcribe() }
    let importTask = Task {
      await store.importMeetingAudio(url: sourceAudio, title: "Alpha planning")
    }
    await gate.waitUntilStarted()

    store.setCorpusRoot(beta, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertTrue(store.saveMeetingReadyAutomationConfiguration(
      isEnabled: true,
      destinationID: AIChatDestinationConfiguration.openClawID,
      threadMode: .newThread,
      threadID: nil,
      prompt: "This beta automation must not receive alpha."
    ))
    let betaStatusBeforeCompletion = store.statusText
    await gate.finish()
    await importTask.value

    XCTAssertTrue(store.meetings.isEmpty)
    XCTAssertFalse(store.aiChatThreads.contains(where: { thread in
      thread.messages.contains(where: { $0.content.contains("Alpha planning") })
    }))
    let sendCount = await sendRecorder.callCount()
    XCTAssertEqual(sendCount, 0)
    XCTAssertEqual(store.statusText, betaStatusBeforeCompletion)
    let alphaMeetings = alpha.appendingPathComponent("meetings", isDirectory: true)
    let writtenArtifacts = try FileManager.default.contentsOfDirectory(
      at: alphaMeetings,
      includingPropertiesForKeys: nil
    )
    XCTAssertTrue(writtenArtifacts.contains(where: {
      $0.pathExtension == OrgDocumentDefaults.preferredExtension
    }))
  }

  @MainActor
  func testFinishedTranscriptionDoesNotNavigateAwayFromCurrentPage() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-meeting-no-jump-\(UUID().uuidString)", isDirectory: true)
    let corpus = base.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    let sourceAudio = base.appendingPathComponent("source.m4a")
    try Data("audio".utf8).write(to: sourceAudio)
    defer { try? FileManager.default.removeItem(at: base) }
    let suiteName = "MeetingReadyAutomationTests.NoJump.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let gate = SuspendedMeetingTranscription()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatFallbackTranscriptURL: base.appendingPathComponent("fallback.json"),
      legacyDefaultsDomains: [],
      automaticStarterCorpusURL: nil
    )
    store.setCorpusRoot(corpus, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.meetingTranscriptionForTesting = { _ in await gate.transcribe() }
    let importTask = Task {
      await store.importMeetingAudio(url: sourceAudio, title: "Background planning")
    }
    await gate.waitUntilStarted()

    // The user moves on while the transcription runs.
    store.selectedSurface = .aiChat
    let locationBeforeCompletion = store.selectedLocation
    await gate.finish()
    await importTask.value

    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.selectedLocation?.file, locationBeforeCompletion?.file)
    XCTAssertNil(store.selectedMeetingID)
    XCTAssertTrue(store.meetings.contains(where: { $0.title.contains("Background planning") }))
  }

  private func meeting(
    title: String,
    file: String,
    idValue: String,
    transcriptionStatus: String = "complete"
  ) -> MeetingWorkspaceItem {
    MeetingWorkspaceItem(
      title: title,
      file: file,
      recordedAt: "2026-08-19T12:00:00-07:00",
      modifiedAt: Date(),
      audioArtifact: "audio.m4a",
      transcriptArtifact: "transcript.org2",
      transcriptionStatus: transcriptionStatus,
      idValue: idValue
    )
  }

  private func makeFixture() throws -> (
    root: URL,
    transcript: URL,
    defaults: UserDefaults,
    cleanup: () -> Void
  ) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-meeting-automation-\(UUID().uuidString)", isDirectory: true)
    let transcript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(
      at: transcript.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let suiteName = "MeetingReadyAutomationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    return (
      root,
      transcript,
      defaults,
      {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
      }
    )
  }
}
