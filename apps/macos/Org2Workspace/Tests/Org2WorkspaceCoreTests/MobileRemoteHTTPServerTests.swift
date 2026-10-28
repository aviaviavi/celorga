import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class MobileRemoteHTTPServerTests: XCTestCase {
  func testParsesAuthenticatedJSONRequestAfterFullBodyArrives() throws {
    let body = try MobileRemoteProtocol.encoder().encode(
      MobileRemoteSendMessageRequest(
        content: "Continue the review",
        attachments: [
          MobileRemoteAttachment(
            fileName: "whiteboard.jpg",
            mimeType: "image/jpeg",
            data: Data([0x01, 0x02, 0x03])
          )
        ],
        delivery: "steer"
      )
    )
    let header =
      "POST /v1/threads/123/messages HTTP/1.1\r\n" +
      "Host: 100.64.0.1:48922\r\n" +
      "Authorization: Bearer secret-token\r\n" +
      "Content-Type: application/json\r\n" +
      "Content-Length: \(body.count)\r\n\r\n"
    var bytes = Data(header.utf8)
    bytes.append(body)

    let request = try XCTUnwrap(MobileRemoteHTTPConnection.parseRequestIfComplete(bytes))
    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/v1/threads/123/messages")
    XCTAssertEqual(request.bearerToken, "secret-token")
    let decoded = try request.decode(MobileRemoteSendMessageRequest.self)
    XCTAssertEqual(decoded.content, "Continue the review")
    XCTAssertEqual(decoded.delivery, "steer")
    XCTAssertEqual(decoded.attachments.first?.fileName, "whiteboard.jpg")
    XCTAssertEqual(decoded.attachments.first?.data, Data([0x01, 0x02, 0x03]))
  }

  func testWaitsForTheDeclaredBodyLength() {
    let rawRequest =
      "POST /v1/pair HTTP/1.1\r\n" +
      "Content-Length: 12\r\n\r\n" +
      "{\"code\":\"1\""
    let partial = Data(rawRequest.utf8)

    XCTAssertNil(MobileRemoteHTTPConnection.parseRequestIfComplete(partial))
  }

  func testWireDatesRoundTripWithSharedEncoding() throws {
    let assistantMessageID = UUID()
    let expected = MobileRemoteThreadSummary(
      id: UUID(),
      title: "Remote chat",
      runtime: "codex",
      destinationID: "remote.press-codex",
      destinationName: "Codex Remote",
      isSharedRoom: true,
      model: "gpt-test",
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      isSettled: false,
      isPinned: true,
      isRunning: true,
      unreadMessageCount: 2,
      preview: "Working",
      latestAssistantMessageID: assistantMessageID,
      latestAssistantPreview: "I finished the focused checks."
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(MobileRemoteThreadSummary.self, from: data)

    XCTAssertEqual(restored, expected)
  }

  func testActiveDestinationNameRoundTripsInThreadDetail() throws {
    let summary = MobileRemoteThreadSummary(
      id: UUID(),
      title: "Shared room",
      runtime: "openClaw",
      destinationID: "openclaw",
      destinationName: "Shared AI Room",
      isSharedRoom: true,
      model: nil,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      isSettled: false,
      isPinned: false,
      isRunning: true,
      unreadMessageCount: 0,
      preview: "You → Codex",
      latestAssistantMessageID: nil,
      latestAssistantPreview: nil
    )
    let expected = MobileRemoteThreadDetail(
      thread: summary,
      messages: [],
      activeDestinationName: "Codex",
      streamingReply: "",
      reasoning: "",
      activities: [],
      connectionState: "connected",
      connectionDetail: nil
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(MobileRemoteThreadDetail.self, from: data)

    XCTAssertEqual(restored, expected)
    XCTAssertEqual(restored.activeDestinationName, "Codex")
  }

  func testNamedAIDestinationsRoundTripWithoutChangingTheWireVersion() throws {
    let expected = MobileRemoteServerStatus(
      serverName: "Org2 on Press",
      corpusName: "avi.org2",
      threadCount: 3,
      runningThreadCount: 1,
      aiChatDestinations: [
        MobileRemoteAIDestination(
          id: "remote.press-codex",
          name: "Codex Remote",
          mention: "codex-remote",
          runtime: "codex"
        )
      ],
      pushNotificationsSupported: true,
      pushNotificationsConfigured: true
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteServerStatus.self,
      from: data
    )

    XCTAssertEqual(restored, expected)
    XCTAssertEqual(restored.protocolVersion, 2)
  }

  func testProjectChatMetadataAndMutationsRoundTripWithoutChangingTheWireVersion() throws {
    let threadID = UUID()
    let project = MobileRemoteProjectSummary(
      id: "project-openorg",
      title: "OpenOrg",
      color: "purple",
      threadIDs: [threadID]
    )
    let list = MobileRemoteThreadList(threads: [], projects: [project])
    let listData = try MobileRemoteProtocol.encoder().encode(list)
    let restoredList = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteThreadList.self,
      from: listData
    )

    XCTAssertEqual(restoredList, list)
    XCTAssertTrue(try XCTUnwrap(restoredList.projects?.first).contains(threadID))

    let create = MobileRemoteCreateThreadRequest(
      runtime: "codex",
      destinationID: "builtin.codex",
      projectID: project.id
    )
    let createData = try MobileRemoteProtocol.encoder().encode(create)
    XCTAssertEqual(
      try MobileRemoteProtocol.decoder().decode(
        MobileRemoteCreateThreadRequest.self,
        from: createData
      ),
      create
    )

    let update = MobileRemoteUpdateThreadProjectRequest(
      projectID: project.id,
      isMember: false
    )
    let updateData = try MobileRemoteProtocol.encoder().encode(update)
    XCTAssertEqual(
      try MobileRemoteProtocol.decoder().decode(
        MobileRemoteUpdateThreadProjectRequest.self,
        from: updateData
      ),
      update
    )
    let legacyList = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteThreadList.self,
      from: Data(#"{"threads":[]}"#.utf8)
    )
    XCTAssertNil(legacyList.projects)
    let legacyCreate = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteCreateThreadRequest.self,
      from: Data(#"{"runtime":"codex","destinationID":"builtin.codex"}"#.utf8)
    )
    XCTAssertNil(legacyCreate.projectID)
    XCTAssertEqual(MobileRemoteProtocol.version, 2)
  }

  func testPushRegistrationRoundTripsWithoutChangingTheWireVersion() throws {
    let request = MobileRemotePushRegistrationRequest(
      deviceToken: String(repeating: "a1", count: 32),
      environment: "sandbox",
      enabled: true
    )
    let requestData = try MobileRemoteProtocol.encoder().encode(request)
    XCTAssertEqual(
      try MobileRemoteProtocol.decoder().decode(
        MobileRemotePushRegistrationRequest.self,
        from: requestData
      ),
      request
    )

    let response = MobileRemotePushRegistrationResponse(
      enabled: true,
      providerConfigured: true
    )
    let responseData = try MobileRemoteProtocol.encoder().encode(response)
    XCTAssertEqual(
      try MobileRemoteProtocol.decoder().decode(
        MobileRemotePushRegistrationResponse.self,
        from: responseData
      ),
      response
    )
    XCTAssertEqual(MobileRemoteProtocol.version, 2)
  }

  func testFilePreviewRoundTrips() throws {
    let expected = MobileRemoteFilePreview(
      title: "talk.org2",
      relativePath: "notes/talk.org2",
      startLine: 23,
      highlightedLine: 31,
      content: "* Opening\nThe experiment gap"
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(MobileRemoteFilePreview.self, from: data)

    XCTAssertEqual(restored, expected)
  }

  @MainActor
  func testFilePreviewReturnsCompleteAuthorizedFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-complete-file-\(UUID().uuidString)", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let documentURL = notes.appendingPathComponent("long.org2")
    let markdownURL = notes.appendingPathComponent("readme.md")
    let content = (1...80).map { "Line \($0) with a complete source row" }.joined(separator: "\n")
    try content.write(to: documentURL, atomically: true, encoding: .utf8)
    try "# Read me\nAll text is visible.".write(to: markdownURL, atomically: true, encoding: .utf8)

    let suiteName = "org2-mobile-complete-file-defaults-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    store.setCorpusRoot(root, persistsDefault: false)

    let preview = try await store.mobileRemoteFilePreview(path: "notes/long.org2", line: 60)
    XCTAssertEqual(preview.startLine, 1)
    XCTAssertEqual(preview.highlightedLine, 60)
    XCTAssertEqual(preview.content, content)
    XCTAssertTrue(preview.content.contains("Line 1 with"))
    XCTAssertTrue(preview.content.contains("Line 80 with"))

    let markdown = try await store.mobileRemoteFilePreview(path: "notes/readme.md", line: nil)
    XCTAssertEqual(markdown.content, "# Read me\nAll text is visible.")
  }

  @MainActor
  func testMobileRemoteImageServesCorpusImagesOnly() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-image-\(UUID().uuidString)", isDirectory: true)
    let images = root.appendingPathComponent("images", isDirectory: true)
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    try bytes.write(to: images.appendingPathComponent("chart.png"))
    try "secret".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let suiteName = "org2-mobile-image-defaults-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(root, persistsDefault: false)

    let image = try await store.mobileRemoteImage(path: "images/chart.png")
    XCTAssertEqual(image.data, bytes)
    XCTAssertEqual(image.mimeType, "image/png")
    let decoded = try JSONDecoder().decode(MobileRemoteImage.self, from: JSONEncoder().encode(image))
    XCTAssertEqual(decoded.data, bytes)

    do {
      _ = try await store.mobileRemoteImage(path: "notes.txt")
      XCTFail("Non-image files must not be served")
    } catch {}
    do {
      _ = try await store.mobileRemoteImage(path: "../etc/hosts.png")
      XCTFail("Paths outside the corpus must be rejected")
    } catch {}
  }

  func testCanonicalWorkspaceSnapshotAndMutationsRoundTrip() throws {
    let snapshot = MobileRemoteWorkspaceSnapshot(
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      agenda: [
        MobileRemoteAgendaItem(
          id: "notes/today.org2:4:Scheduled:Ship:",
          title: "Ship the mobile review update",
          todo: "TODO",
          file: "notes/today.org2",
          line: 5,
          date: "2026-08-10",
          kind: "Scheduled",
          tags: ["mobile"],
          body: "Use the canonical projection.",
          priority: "A",
          time: "10:00",
          effort: "0:30"
        )
      ],
      approvals: [
        MobileRemoteApprovalItem(
          id: "run:run-1:approval-1",
          title: "Send the customer update",
          status: "pending",
          todo: nil,
          level: nil,
          file: ".org2/runs/run-1.org2",
          line: 1,
          sourceID: "approval-1",
          properties: [:],
          body: "Review the exact message.",
          tags: [],
          kind: "run",
          runID: "run-1",
          approvalID: "approval-1",
          fingerprint: "sha256:example",
          action: "send",
          riskClass: "external-write",
          requestedRole: "owner",
          requestedFrom: "Avi",
          requestedAt: "2026-08-10T12:00:00Z",
          runGoal: "Close the loop",
          runStatus: "waiting-approval",
          runDecisionEffect: "Approval resumes the run."
        )
      ],
      workflows: [
        MobileRemoteWorkflowItem(
          id: "daily-review",
          title: "Daily review",
          description: "Review new work.",
          state: "active",
          riskClass: "read-only",
          scheduleSummary: "0 9 * * * · America/Los_Angeles",
          file: "workflows/daily-review.org2",
          agentRef: "agent:reviewer",
          goalRef: "goal:inbox-zero",
          inputs: [
            MobileRemoteWorkflowInput(
              id: "scope",
              description: "Review scope",
              required: true,
              defaultValue: "today"
            )
          ]
        )
      ]
    )

    let data = try MobileRemoteProtocol.encoder().encode(snapshot)
    XCTAssertEqual(
      try MobileRemoteProtocol.decoder().decode(MobileRemoteWorkspaceSnapshot.self, from: data),
      snapshot
    )

    let decision = MobileRemoteApprovalDecisionRequest(
      decision: "rejected",
      note: "Use the revised copy.",
      endStatus: "canceled"
    )
    let decisionData = try MobileRemoteProtocol.encoder().encode(decision)
    XCTAssertEqual(
      try MobileRemoteProtocol.decoder().decode(MobileRemoteApprovalDecisionRequest.self, from: decisionData),
      decision
    )
  }

  func testModelConfigurationRoundTripsWithProtocolVersionTwo() throws {
    let threadID = UUID()
    let expected = MobileRemoteThreadConfiguration(
      threadID: threadID,
      model: "gpt-test",
      models: [
        MobileRemoteModelOption(
          id: "gpt-test",
          label: "GPT Test",
          detail: "A test model",
          isDefault: true
        )
      ],
      reasoningEffort: "high",
      reasoningOptions: [
        MobileRemoteReasoningOption(id: "medium", label: "Medium", detail: nil),
        MobileRemoteReasoningOption(id: "high", label: "High", detail: "More reasoning")
      ],
      defaultReasoningEffort: "medium"
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteThreadConfiguration.self,
      from: data
    )

    XCTAssertEqual(MobileRemoteProtocol.version, 2)
    XCTAssertEqual(restored, expected)
  }

  func testExternalThreadDetailRoundTripsOverMobileRemoteJSON() throws {
    let summary = ExternalThreadSummary(
      harness: .codex,
      externalID: "019f-thread",
      title: "Native task",
      preview: "Inspect it",
      workspacePath: "/tmp/org2",
      source: "vscode",
      modelProvider: "openai",
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 120),
      status: "notLoaded",
      isPinned: false
    )
    let expected = ExternalThreadDetail(
      thread: summary,
      messages: [
        ExternalThreadMessage(
          id: "message-1",
          role: .assistant,
          content: "Read-only response",
          createdAt: Date(timeIntervalSince1970: 121)
        )
      ]
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(ExternalThreadDetail.self, from: data)

    XCTAssertEqual(restored, expected)
  }

  func testReasoningConfigurationMutationRoundTrips() throws {
    let expected = MobileRemoteUpdateThreadConfigurationRequest(reasoningEffort: "high")

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteUpdateThreadConfigurationRequest.self,
      from: data
    )

    XCTAssertEqual(restored, expected)
    XCTAssertEqual(restored.setting, "reasoning")
    XCTAssertEqual(restored.value, "high")
  }

  func testThreadStateMutationRoundTrips() throws {
    let expected = MobileRemoteUpdateThreadStateRequest(
      isPinned: true,
      isSettled: false
    )

    let data = try MobileRemoteProtocol.encoder().encode(expected)
    let restored = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteUpdateThreadStateRequest.self,
      from: data
    )

    XCTAssertEqual(restored, expected)
  }

  func testMobileActivityPresentationHidesEmptyLifecycleAndGroupsUsefulWork() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let activities = [
      AIChatRunActivity(
        id: "lifecycle-start",
        runID: "run-1",
        kind: .lifecycle,
        title: "Agent started",
        status: .running,
        updatedAt: now
      ),
      AIChatRunActivity(
        id: "shell-1",
        runID: "run-1",
        kind: .tool,
        title: "Shell command",
        status: .succeeded,
        updatedAt: now.addingTimeInterval(1)
      ),
      AIChatRunActivity(
        id: "shell-2",
        runID: "run-1",
        kind: .tool,
        title: "Shell command",
        status: .failed,
        updatedAt: now.addingTimeInterval(2)
      )
    ]

    let presented = MobileRemoteActivityPresentation.items(from: activities)

    let item = try XCTUnwrap(presented.first)
    XCTAssertEqual(presented.count, 1)
    XCTAssertEqual(item.title, "2 shell command calls")
    XCTAssertEqual(item.detail, "1 completed · 1 failed")
    XCTAssertEqual(item.status, "succeeded")
    XCTAssertEqual(item.updatedAt, now.addingTimeInterval(2))
    XCTAssertFalse(presented.contains(where: { $0.title == "Agent started" }))
  }

  /// iPhone builds keyed reply alerts on the summary's latest assistant ID
  /// and forgot a thread whose ID went missing. An evicted transcript must
  /// keep reporting the same ID, or the old reply is announced again each
  /// time the conversation is loaded back into memory.
  func testEvictedThreadSummaryKeepsItsLatestReplyIdentity() throws {
    let reply = AIChatMessage(role: .assistant, content: "Milk, eggs, and bread.")
    let thread = AIChatThread(
      title: "Groceries today",
      sessionKey: "groceries",
      messages: [
        AIChatMessage(role: .user, content: "What do I need?"),
        reply,
        AIChatMessage(role: .assistant, content: "  \n"),
        AIChatMessage(role: .user, content: "Thanks"),
      ],
      isArchived: true
    )
    let context = MobileRemoteThreadProjectionContext(destinationNamesByID: [:], runningThreadIDs: [])
    let loaded = MobileRemoteThreadProjection.summary(thread: thread, context: context)
    XCTAssertEqual(loaded.latestAssistantMessageID, reply.id)

    let evicted = thread.metadataOnly()
    XCTAssertTrue(evicted.messages.isEmpty)
    XCTAssertEqual(
      MobileRemoteThreadProjection.summary(thread: evicted, context: context).latestAssistantMessageID,
      reply.id
    )
    // Placeholders round-trip through the transcript manifest and survive
    // metadata-only edits such as settling or renaming.
    let decoded = try JSONDecoder().decode(AIChatThread.self, from: JSONEncoder().encode(evicted))
    XCTAssertEqual(decoded.latestAssistantMessageID, reply.id)
    XCTAssertEqual(
      decoded.replacingAIChatMetadata(title: "Renamed").metadataOnly().latestAssistantMessageID,
      reply.id
    )
    // Rehydrated messages are authoritative again.
    let newer = AIChatMessage(role: .assistant, content: "Also coffee.")
    let rehydrated = decoded.hydrating(messages: thread.messages + [newer])
    XCTAssertNil(rehydrated.storedLatestAssistantMessageID)
    XCTAssertEqual(
      MobileRemoteThreadProjection.summary(thread: rehydrated, context: context).latestAssistantMessageID,
      newer.id
    )
  }

  @MainActor
  func testRemoteThreadCreationDoesNotChangeTheMacSelection() throws {
    let suiteName = "MobileRemoteHTTPServerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcriptURL) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL
    )

    let selectedID = store.createAIChatThread(runtime: .openClaw)
    let remoteID = store.createAIChatRemoteThread(runtime: .codex)

    var claude = try XCTUnwrap(
      AIChatDestinationConfiguration.defaults.first(where: {
        $0.id == AIChatDestinationConfiguration.localClaudeID
      })
    )
    claude.isEnabled = true
    store.updateAIChatDestination(claude)
    let claudeRemoteID = store.createAIChatRemoteThread(
      destinationID: AIChatDestinationConfiguration.localClaudeID
    )

    XCTAssertEqual(store.selectedAIChatThreadID, selectedID)
    XCTAssertNotEqual(remoteID, selectedID)
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == remoteID })?.runtime, .codex)
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == claudeRemoteID })?.runtime,
      .claude
    )
  }

  @MainActor
  func testRemoteThreadCreationDefersTranscriptPersistence() throws {
    let suiteName = "MobileRemoteHTTPServerTests.DeferredCreate.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-deferred-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcriptURL) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL
    )
    var saveCount = 0
    store.aiChatTranscriptPersistenceDelayNanoseconds = 5_000_000_000
    store.aiChatTranscriptSaverForTesting = { saveCount += 1 }

    let remoteID = store.createAIChatRemoteThread(runtime: .codex)

    XCTAssertNotNil(store.aiChatThreads.first(where: { $0.id == remoteID }))
    XCTAssertEqual(saveCount, 0)
    store.flushDeferredAIChatTranscriptPersistence()
    XCTAssertEqual(saveCount, 1)
  }

  @MainActor
  func testRemoteCrossAgentMentionReturnsForkWithoutChangingMacSelection() throws {
    let suiteName = "MobileRemoteHTTPServerTests.MentionFork.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-mention-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcriptURL) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL
    )
    let selectedID = store.createAIChatThread(runtime: .openClaw)
    let remoteID = store.createAIChatRemoteThread(runtime: .openClaw)

    let destinationID = try XCTUnwrap(store.sendAIChatRemoteMessageDestination(
      "@Codex take a look",
      threadID: remoteID
    ))

    XCTAssertNotEqual(destinationID, remoteID)
    XCTAssertEqual(store.selectedAIChatThreadID, selectedID)
    XCTAssertTrue(store.aiChatThreads.first(where: { $0.id == destinationID })?.isSharedRoom == true)
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == destinationID })?.messages.first?.audience,
      .codex
    )
  }

  @MainActor
  func testRemoteEmptyChatSwitchesAgentWithoutCreatingARoom() throws {
    let suiteName = "MobileRemoteHTTPServerTests.Destination.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-destination-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcriptURL) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL
    )
    var openCode = try XCTUnwrap(
      AIChatDestinationConfiguration.defaults.first(where: {
        $0.id == AIChatDestinationConfiguration.localOpenCodeID
      })
    )
    openCode.isEnabled = true
    store.updateAIChatDestination(openCode)
    let threadCount = store.aiChatThreads.count
    let remoteID = store.createAIChatRemoteThread(runtime: .codex)

    try store.setAIChatRemoteDestination(
      AIChatDestinationConfiguration.localOpenCodeID,
      threadID: remoteID
    )

    let moved = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == remoteID }))
    XCTAssertEqual(moved.destinationID, AIChatDestinationConfiguration.localOpenCodeID)
    XCTAssertEqual(moved.runtime, .openCode)
    XCTAssertFalse(moved.isSharedRoom)
    XCTAssertEqual(store.aiChatThreads.count, threadCount + 1, "switching reuses the chat")

    XCTAssertThrowsError(try store.setAIChatRemoteDestination("missing.destination", threadID: remoteID))

    let index = try XCTUnwrap(store.aiChatThreads.firstIndex(where: { $0.id == remoteID }))
    store.aiChatThreads[index] = store.aiChatThreads[index].replacingMessages([
      AIChatMessage(role: .user, content: "Hello")
    ])
    XCTAssertThrowsError(try store.setAIChatRemoteDestination(
      AIChatDestinationConfiguration.localCodexID,
      threadID: remoteID
    )) { error in
      XCTAssertEqual(
        error.localizedDescription,
        AIChatRemoteConfigurationError.destinationLocked.localizedDescription
      )
    }
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == remoteID })?.destinationID,
      AIChatDestinationConfiguration.localOpenCodeID
    )
  }

  @MainActor
  func testRemoteConfigurationAnswersFromTheCachedModelCatalog() async throws {
    let suiteName = "MobileRemoteHTTPServerTests.ModelCache.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-model-cache-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcriptURL) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL
    )
    var openCode = try XCTUnwrap(
      AIChatDestinationConfiguration.defaults.first(where: {
        $0.id == AIChatDestinationConfiguration.localOpenCodeID
      })
    )
    openCode.isEnabled = true
    store.updateAIChatDestination(openCode)
    store.cacheAIChatConfigurationForTesting(
      destinationID: AIChatDestinationConfiguration.localOpenCodeID,
      models: [
        AIChatModelOption(id: "example/fast", label: "example/fast"),
        AIChatModelOption(id: "example/deep", label: "example/deep")
      ],
      effectiveModel: nil,
      reasoningOptions: [],
      defaultReasoningEffort: nil
    )
    let remoteID = store.createAIChatRemoteThread(
      destinationID: AIChatDestinationConfiguration.localOpenCodeID
    )

    // Without a corpus a live `opencode models` listing would throw, so this
    // only succeeds by answering from the cached catalog.
    let configuration = try await store.aiChatRemoteConfiguration(for: remoteID)
    XCTAssertEqual(configuration.models.map(\.id), ["example/fast", "example/deep"])
  }

  @MainActor
  func testFilePreviewReadsCompleteFilesOnlyInsideMountedCorpora() async throws {
    let suiteName = "MobileRemoteHTTPServerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-preview-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("demo.org2", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let source = notes.appendingPathComponent("talk.org2")
    let sourceText = (1...30).map { "Line \($0)" }.joined(separator: "\n")
    try sourceText.write(to: source, atomically: true, encoding: .utf8)
    let outside = container.appendingPathComponent("outside.org2")
    try "Private".write(to: outside, atomically: true, encoding: .utf8)
    let symlink = notes.appendingPathComponent("escape.org2")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: container.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root)

    let relativePreview = try await store.mobileRemoteFilePreview(
      path: "notes/talk.org2",
      line: 12
    )
    XCTAssertEqual(relativePreview.title, "talk.org2")
    XCTAssertEqual(relativePreview.relativePath, "notes/talk.org2")
    XCTAssertEqual(relativePreview.startLine, 1)
    XCTAssertEqual(relativePreview.highlightedLine, 12)
    XCTAssertEqual(relativePreview.content, sourceText)

    let absolutePreview = try await store.mobileRemoteFilePreview(path: source.path, line: 1)
    XCTAssertEqual(absolutePreview.relativePath, "notes/talk.org2")

    do {
      _ = try await store.mobileRemoteFilePreview(path: outside.path, line: 1)
      XCTFail("Expected an absolute path outside mounted corpora to be rejected")
    } catch let error as MobileRemoteFilePreviewError {
      XCTAssertEqual(error, .invalidPath)
    }
    do {
      _ = try await store.mobileRemoteFilePreview(path: symlink.path, line: 1)
      XCTFail("Expected a symlink escaping mounted corpora to be rejected")
    } catch let error as MobileRemoteFilePreviewError {
      XCTAssertEqual(error, .invalidPath)
    }
    do {
      _ = try await store.mobileRemoteFilePreview(path: "../outside.org2", line: 1)
      XCTFail("Expected a relative path escaping mounted corpora to be rejected")
    } catch let error as MobileRemoteFilePreviewError {
      XCTAssertEqual(error, .invalidPath)
    }
  }

  @MainActor
  func testLargeFilePreviewReadsAndValidatesItsLineOffMain() async throws {
    let suiteName = "MobileRemoteHTTPServerTests.large-preview.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-large-preview-\(UUID().uuidString)", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = notes.appendingPathComponent("large.org2")
    let lineCount = 150_000
    let sourceText = String(
      repeating: "A complete large-file preview row 0123456789\n",
      count: lineCount
    )
    try sourceText.write(to: source, atomically: true, encoding: .utf8)

    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let threadRecorder = MobileRemotePreviewThreadRecorder()
    store.mobileRemoteFilePreviewDidReadForTesting = { isMainThread in
      threadRecorder.append(isMainThread)
    }

    let preview = try await store.mobileRemoteFilePreview(
      path: "notes/large.org2",
      line: lineCount
    )
    XCTAssertEqual(preview.highlightedLine, lineCount)
    XCTAssertEqual(preview.content.utf8.count, sourceText.utf8.count)
    XCTAssertTrue(preview.content.hasPrefix("A complete large-file preview row"))

    let invalidLinePreview = try await store.mobileRemoteFilePreview(
      path: "notes/large.org2",
      line: lineCount + 2
    )
    XCTAssertNil(invalidLinePreview.highlightedLine)
    XCTAssertEqual(threadRecorder.values, [false, false])
  }

  @MainActor
  func testFilePreviewRejectsAResultFromThePreviousCorpus() async throws {
    let suiteName = "MobileRemoteHTTPServerTests.stale-preview.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-stale-preview-\(UUID().uuidString)", isDirectory: true)
    let firstRoot = container.appendingPathComponent("first.org2", isDirectory: true)
    let secondRoot = container.appendingPathComponent("second.org2", isDirectory: true)
    let firstNotes = firstRoot.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: firstNotes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    try "* First corpus\n".write(
      to: firstNotes.appendingPathComponent("stale.org2"),
      atomically: true,
      encoding: .utf8
    )

    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: container.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(firstRoot, persistsDefault: false)
    let gate = MobileRemotePreviewGate()
    let threadRecorder = MobileRemotePreviewThreadRecorder()
    store.mobileRemoteFilePreviewPreparationForTesting = {
      await gate.wait()
    }
    store.mobileRemoteFilePreviewDidReadForTesting = { isMainThread in
      threadRecorder.append(isMainThread)
    }

    let previewTask = Task { @MainActor in
      try await store.mobileRemoteFilePreview(path: "notes/stale.org2", line: 1)
    }
    await gate.waitUntilStarted()
    store.setCorpusRoot(secondRoot, persistsDefault: false)
    await gate.release()

    do {
      _ = try await previewTask.value
      XCTFail("Expected a preview from the previous corpus session to be rejected")
    } catch let error as MobileRemoteFilePreviewError {
      XCTAssertEqual(error, .invalidPath)
    }
    XCTAssertEqual(threadRecorder.values, [false])
  }

  @MainActor
  func testRemoteThreadStateUpdatesAreExplicitAndIdempotent() throws {
    let suiteName = "MobileRemoteHTTPServerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-state-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcriptURL) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcriptURL
    )
    let threadID = store.createAIChatRemoteThread(runtime: .openClaw)

    XCTAssertTrue(store.updateAIChatRemoteThreadState(
      threadID: threadID,
      isPinned: true,
      isSettled: true
    ))
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.isPinned, true)
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.isSettled, true)

    XCTAssertTrue(store.updateAIChatRemoteThreadState(
      threadID: threadID,
      isPinned: true,
      isSettled: true
    ))
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.isPinned, true)
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.isSettled, true)

    XCTAssertTrue(store.updateAIChatRemoteThreadState(
      threadID: threadID,
      isPinned: false,
      isSettled: false
    ))
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.isPinned, false)
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.isSettled, false)
  }

  @MainActor
  func testRemoteAndMacSendsShareThreadContextWithoutRemoteNavigationLeak() async throws {
    let suiteName = "MobileRemoteHTTPServerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-mobile-remote-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let unrelatedNote = root.appendingPathComponent("unrelated-meeting.org2")
    try "#+TITLE: Unrelated Meeting\n".write(to: unrelatedNote, atomically: true, encoding: .utf8)
    let recorder = MobileRemoteWorkspaceContextRecorder()
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { _, _, _, context in
        await recorder.record(context)
        return "Remote reply"
      }
    )
    store.setCorpusRoot(root)
    let threadID = store.createAIChatRemoteThread(runtime: .openClaw)
    store.renameAIChatThread(threadID, title: "Render Atlanta Talk")

    XCTAssertTrue(store.sendAIChatRemoteMessage(
      "Use selected page “Opening” at notes/render-atlanta.org2:1 as context.\n\nImprove the talk.",
      threadID: threadID
    ))
    let firstReplyDeadline = Date().addingTimeInterval(5)
    while (
      store.aiChatThreads.first(where: { $0.id == threadID })?.messages.count != 2
        || store.isAIChatThreadRunning(threadID)
    ),
          Date() < firstReplyDeadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    store.selectCorpusFile(CorpusFile(
      path: unrelatedNote.path,
      relativePath: unrelatedNote.lastPathComponent,
      modifiedAt: nil,
      byteCount: 0
    ))
    XCTAssertEqual(store.selectedLocation?.file, unrelatedNote.path)

    XCTAssertTrue(store.sendAIChatRemoteMessage("Continue this thread", threadID: threadID))
    let deadline = Date().addingTimeInterval(5)
    while await recorder.contexts().count < 2, Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    let recordedContext = await recorder.contexts().last
    let context = try XCTUnwrap(recordedContext)
    XCTAssertEqual(context.selectedSurface, WorkspaceSurface.aiChat.title)
    XCTAssertNil(context.selectedLocation)
    XCTAssertNil(context.selectedEntrySource)
    XCTAssertNil(context.backlinks)
    XCTAssertNil(context.agenda)
    XCTAssertTrue(context.searchQuery.isEmpty)
    XCTAssertTrue(context.searchResults.isEmpty)
    XCTAssertEqual(context.authorizedCorpora.first?.localRoot, root.standardizedFileURL.path)
    let prompt = context.systemPrompt()
    XCTAssertTrue(prompt.contains("Selected AI chat thread continuation"))
    XCTAssertTrue(prompt.contains("Thread title: Render Atlanta Talk"))
    XCTAssertTrue(prompt.contains("Improve the talk."))
    XCTAssertTrue(prompt.contains("Remote reply"))
    XCTAssertTrue(prompt.contains("notes/render-atlanta.org2:1"))
    XCTAssertTrue(prompt.contains("Celorga response formatting contract"))
    XCTAssertTrue(prompt.contains("|-------+--------------|"))
    XCTAssertFalse(prompt.contains("unrelated-meeting.org2"))
    let codexPrompt = context.codexSystemPrompt()
    XCTAssertTrue(codexPrompt.contains("Thread title: Render Atlanta Talk"))
    XCTAssertTrue(codexPrompt.contains("Improve the talk."))
    XCTAssertTrue(codexPrompt.contains("notes/render-atlanta.org2:1"))
    // Codex carries the formatting contract in its developer instructions.
    XCTAssertFalse(codexPrompt.contains("Celorga response formatting contract"))
    XCTAssertFalse(codexPrompt.contains("unrelated-meeting.org2"))

    let secondReplyDeadline = Date().addingTimeInterval(5)
    while (
      store.aiChatThreads.first(where: { $0.id == threadID })?.messages.count != 4
        || store.isAIChatThreadRunning(threadID)
    ),
          Date() < secondReplyDeadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    store.selectAIChatThread(threadID)
    store.sendComposedAIChatMessage(text: "Continue from the Mac")
    let macContextDeadline = Date().addingTimeInterval(5)
    while await recorder.contexts().count < 3, Date() < macContextDeadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    let recordedMacContext = await recorder.contexts().last
    let macContext = try XCTUnwrap(recordedMacContext)
    XCTAssertNil(macContext.selectedLocation)
    XCTAssertEqual(macContext.threadContinuation?.title, context.threadContinuation?.title)
    XCTAssertEqual(
      macContext.threadContinuation?.org2References,
      context.threadContinuation?.org2References
    )
    let macPrompt = macContext.systemPrompt()
    XCTAssertTrue(macPrompt.contains("Thread title: Render Atlanta Talk"))
    XCTAssertTrue(macPrompt.contains("Continue this thread"))
    XCTAssertTrue(macPrompt.contains("notes/render-atlanta.org2:1"))
    XCTAssertFalse(macPrompt.contains("unrelated-meeting.org2"))
  }
}

private actor MobileRemoteWorkspaceContextRecorder {
  private var recordedContexts: [AIChatWorkspaceContext] = []

  func record(_ context: AIChatWorkspaceContext?) {
    if let context {
      recordedContexts.append(context)
    }
  }

  func contexts() -> [AIChatWorkspaceContext] {
    recordedContexts
  }
}

private actor MobileRemotePreviewGate {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    started = true
    startWaiters.forEach { $0.resume() }
    startWaiters = []
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private final class MobileRemotePreviewThreadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Bool] = []

  var values: [Bool] {
    lock.withLock { storage }
  }

  func append(_ isMainThread: Bool) {
    lock.withLock { storage.append(isMainThread) }
  }
}
