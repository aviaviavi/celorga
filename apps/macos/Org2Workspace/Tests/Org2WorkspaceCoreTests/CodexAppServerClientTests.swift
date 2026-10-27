import Darwin
import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor CodexTurnStartRecorder {
  private(set) var starts: [(threadID: String, turnID: String)] = []

  func record(_ event: CodexAppServerEvent) {
    guard case .turnStarted(let threadID, let turnID) = event else { return }
    starts.append((threadID, turnID))
  }
}

final class CodexAppServerClientTests: XCTestCase {
  func testLegacyChatThreadDefaultsToOpenClawRuntime() throws {
    let id = UUID()
    let json = """
    {
      "id": "\(id.uuidString)",
      "title": "Legacy",
      "createdAt": 0,
      "updatedAt": 0,
      "sessionKey": "agent:main:org2-workspace:legacy",
      "messages": []
    }
    """

    let thread = try JSONDecoder().decode(
      AIChatThread.self,
      from: Data(json.utf8)
    )

    XCTAssertEqual(thread.runtime, .openClaw)
    XCTAssertNil(thread.runtimeThreadID)
    XCTAssertNil(thread.model)
    XCTAssertNil(thread.reasoningEffort)
  }

  func testCodexChatThreadRuntimeRoundTrips() throws {
    let thread = AIChatThread(
      title: "Local Codex",
      runtime: .codex,
      sessionKey: "unused-for-codex",
      runtimeThreadID: "thr_codex",
      model: "gpt-test",
      reasoningEffort: "high"
    )

    let data = try JSONEncoder().encode(thread)
    let restored = try JSONDecoder().decode(AIChatThread.self, from: data)

    XCTAssertEqual(restored.runtime, .codex)
    XCTAssertEqual(restored.runtimeThreadID, "thr_codex")
    XCTAssertEqual(restored.model, "gpt-test")
    XCTAssertEqual(restored.reasoningEffort, "high")
  }

  func testChatRuntimeLocksAfterFirstMessage() {
    let thread = AIChatThread(
      title: "Runtime picker",
      runtime: .openClaw,
      sessionKey: "agent:main:runtime-picker"
    )

    XCTAssertTrue(thread.canChangeAIRuntime)
    XCTAssertFalse(
      thread.replacingMessages([
        AIChatMessage(role: .user, content: "Hello")
      ]).canChangeAIRuntime
    )
  }

  func testReplacingThreadMessagesPreservesNamedDestinationRouting() {
    let destinationID = "managed-remote-codex"
    let thread = AIChatThread(
      title: "Remote Codex",
      runtime: .codex,
      destinationID: destinationID,
      sessionKey: "unused-for-codex",
      runtimeThreadID: "thr-remote",
      runtimeThreadIDsByDestination: [destinationID: "thr-remote"],
      model: "gpt-remote",
      messages: [AIChatMessage(role: .user, content: "Work remotely")]
    )
    let messages = thread.messages + [
      AIChatMessage(role: .assistant, content: "Remote work completed")
    ]

    let updated = WorkspaceStore.updatedAIChatThread(
      thread,
      messages: messages,
      newAssistantMessageCount: 1,
      isThreadOpen: true,
      pendingTurnUpdate: .preserve
    )

    XCTAssertEqual(updated.destinationID, destinationID)
    XCTAssertEqual(updated.runtimeThreadID, "thr-remote")
    XCTAssertEqual(updated.runtimeThreadIDsByDestination, [destinationID: "thr-remote"])
    XCTAssertEqual(updated.model, "gpt-remote")
    XCTAssertEqual(updated.messages, messages)
  }

  func testRepairsThreadsWhoseNamedRemoteDestinationWasResetToLocal() {
    let destination = AIChatDestinationConfiguration(
      id: "managed-remote-codex",
      name: "Remote Codex",
      mention: "codex-remote",
      adapter: .codexManagedRemote,
      endpoint: "remote-mac"
    )
    let damagedThread = AIChatThread(
      title: "Remote work",
      runtime: .codex,
      destinationID: AIChatDestinationConfiguration.localCodexID,
      sessionKey: "unused-for-codex",
      runtimeThreadID: "thr-remote",
      messages: [
        AIChatMessage(
          role: .user,
          content: "Run this remotely",
          targetRuntime: .codex,
          targetDestinationID: destination.id
        ),
        AIChatMessage(role: .assistant, content: "Done remotely")
      ]
    )

    XCTAssertEqual(
      WorkspaceStore.recoveredNamedCodexDestinationID(
        for: damagedThread,
        destinations: AIChatDestinationConfiguration.defaults + [destination]
      ),
      destination.id
    )
  }

  func testCodexStreamingTextPreservesAgentMessageBoundaries() {
    var text = CodexStreamingText.appending(
      "I’ll inspect the current delivery model.",
      itemID: "commentary-1",
      after: nil,
      to: ""
    )
    text = CodexStreamingText.appending(
      " I found the relevant package.",
      itemID: "commentary-1",
      after: "commentary-1",
      to: text
    )
    text = CodexStreamingText.appending(
      "The implementation is now taking shape.",
      itemID: "commentary-2",
      after: "commentary-1",
      to: text
    )

    XCTAssertEqual(
      text,
      "I’ll inspect the current delivery model. I found the relevant package.\n\n"
        + "The implementation is now taking shape."
    )
  }

  func testCodexStreamingDeltaAddsOnlyTheNewItemBoundary() {
    XCTAssertEqual(
      CodexStreamingText.deltaWithItemBoundary(
        " continues",
        itemID: "commentary-1",
        after: "commentary-1",
        hasExistingText: true
      ),
      " continues"
    )
    XCTAssertEqual(
      CodexStreamingText.deltaWithItemBoundary(
        "The next update",
        itemID: "commentary-2",
        after: "commentary-1",
        hasExistingText: true
      ),
      "\n\nThe next update"
    )
  }

  func testCodexWorkspaceSnapshotIncludesUnsavedSelectedSource() {
    let context = AIChatWorkspaceContext(
      localCorpusRoot: "/tmp/example-corpus",
      remoteCorpusRoot: nil,
      selectedSurface: "Files",
      selectedLocation: nil,
      selectedEntrySource: EntrySource(
        file: "/tmp/example-corpus/notes/draft.org2",
        startLine: 1,
        endLineExclusive: 3,
        text: "* Draft\nUnsaved editor text",
        isSubtree: false
      ),
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )

    let snapshot = context.codexSystemPrompt()

    XCTAssertTrue(snapshot.contains("may include unsaved edits"))
    XCTAssertTrue(snapshot.contains("notes/draft.org2"))
    XCTAssertTrue(snapshot.contains("Unsaved editor text"))
  }

  func testWorkspacePromptsDistinguishRuntimeFromPortableAgentIdentity() {
    let context = AIChatWorkspaceContext(
      localCorpusRoot: "/tmp/example-corpus",
      remoteCorpusRoot: "/srv/example-corpus",
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: EntrySource(
        file: "/tmp/example-corpus/notes/support.org2",
        startLine: 4,
        endLineExclusive: 10,
        text: """
        * TODO Resolve customer issue
        :PROPERTIES:
        :AGENT_REF: scarf-support
        :GOAL_REF: customer-trust
        :END:
        """,
        isSubtree: true
      ),
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )

    let openClaw = context.systemPrompt(runtime: "openclaw", runtimeAgentID: "scarf-support")
    XCTAssertTrue(openClaw.contains("Execution runtime: openclaw"))
    XCTAssertTrue(openClaw.contains("Runtime agent ID: scarf-support"))
    XCTAssertTrue(openClaw.contains("ORG2_SELECTED_AGENT_REF: scarf-support"))
    XCTAssertTrue(openClaw.contains("ORG2_SELECTED_GOAL_REF: customer-trust"))
    XCTAssertTrue(openClaw.contains("celorga agent-profile resolve --runtime openclaw --runtime-agent-id scarf-support --dir /srv/example-corpus --json"))
    XCTAssertTrue(openClaw.contains("Never use =openclaw=, =codex=, =claude=, a model name, or a session ID as =AGENT_REF:="))

    let codex = context.codexSystemPrompt()
    XCTAssertTrue(codex.contains("Execution runtime: codex"))
    XCTAssertTrue(codex.contains("celorga agent-profile resolve --runtime codex --runtime-agent-id default --dir /tmp/example-corpus --json"))
    // Codex gets the standing instructions once, as thread developer
    // instructions, rather than in every turn snapshot.
    XCTAssertFalse(codex.contains("Celorga agent operating guidance"))
    for corpusAccess in [CodexCorpusAccess.clientWorkspaceTools, .runtimeFilesystem] {
      let developer = CodexAppServerClient.developerInstructions(for: corpusAccess)
      XCTAssertTrue(developer.contains("Celorga agent operating guidance"))
      XCTAssertTrue(developer.contains("celorga agent capabilities"))
      XCTAssertTrue(developer.contains("Never use =openclaw=, =codex=, =claude=, a model name, or a session ID as =AGENT_REF:="))
    }

    let claude = context.localAgentSystemPrompt(runtime: "claude", runtimeTitle: "Claude Code")
    XCTAssertTrue(claude.contains("Never use =openclaw=, =codex=, =claude=, a model name, or a session ID as =AGENT_REF:="))
    // All chat destinations share the native-tool policy, including remote
    // shell-capable agents and providers with only exposed workspace tools.
    for prompt in [openClaw, claude,
      CodexAppServerClient.developerInstructions(for: .clientWorkspaceTools),
      CodexAppServerClient.developerInstructions(for: .runtimeFilesystem),
      context.systemPrompt(runtime: "bundled"),
      context.systemPrompt(runtime: "anthropic")] {
      XCTAssertTrue(prompt.contains("Use Celorga's native CLI by default"))
      XCTAssertTrue(prompt.contains("client-required effective-text reads and reviewed writes take precedence"))
      XCTAssertTrue(prompt.contains("Do not invoke =emacs=, =emacsclient="))
      XCTAssertTrue(prompt.contains("Use Emacs only when the user explicitly requests an Emacs-specific task"))
      XCTAssertTrue(prompt.contains("reproduce and fix the shortcoming"))
      XCTAssertTrue(prompt.contains("https://github.com/aviaviavi/celorga/issues"))
      XCTAssertTrue(prompt.contains("Do not publish an issue or private corpus content"))
      XCTAssertTrue(prompt.contains("If shell execution is unavailable, use the exposed tools"))
    }
    XCTAssertTrue(claude.contains("Execution runtime: claude"))
    XCTAssertTrue(claude.contains("running locally through the installed Claude Code CLI"))
    XCTAssertFalse(claude.contains("Use the client-provided Celorga workspace tools for any other corpus reads or writes."))
  }

  func testRemoteCodexPromptUsesRuntimeCorpusWithoutClientEditBroker() {
    let localRoot = "/Users/avi/avi.org2"
    let context = AIChatWorkspaceContext(
      localCorpusRoot: localRoot,
      remoteCorpusRoot: nil,
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: [],
      authorizedCorpora: [
        AIChatCorpusContext(
          name: "Avi Press",
          kind: "personal",
          localRoot: localRoot,
          isActive: true
        )
      ]
    ).replacingRuntimeCorpusRoot("~/avi.org2")

    let prompt = context.codexSystemPrompt(runtimeFilesystemAccess: true)

    XCTAssertTrue(prompt.contains("Active runtime corpus root: ~/avi.org2"))
    XCTAssertTrue(prompt.contains("Runtime root: ~/avi.org2"))
    XCTAssertTrue(prompt.contains("--dir ~/avi.org2 --json"))
    XCTAssertTrue(prompt.contains("Use normal filesystem tools there"))
    XCTAssertTrue(prompt.contains("User's Celorga machine: "))
    XCTAssertTrue(prompt.contains("only the synced corpus is shared"))
    XCTAssertTrue(CodexAppServerClient.developerInstructions(for: .runtimeFilesystem)
      .contains("link it with a corpus-relative path"))
    XCTAssertFalse(prompt.contains("accessible to the Mac"))
    XCTAssertFalse(prompt.contains("Use the client-provided Celorga workspace tools"))
  }

  func testWorkspaceSnapshotIncludesAuthorizedCorporaAndCustomInstructions() {
    let context = AIChatWorkspaceContext(
      localCorpusRoot: "/tmp/personal",
      remoteCorpusRoot: "/srv/personal",
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: [],
      authorizedCorpora: [
        AIChatCorpusContext(
          name: "Personal",
          kind: "personal",
          localRoot: "/tmp/personal",
          remoteRoot: "/srv/personal",
          isActive: true
        ),
        AIChatCorpusContext(
          name: "Team",
          kind: "shared",
          localRoot: "/tmp/team",
          remoteRoot: "/srv/team",
          isActive: false
        )
      ],
      customInstructions: "Prefer concise answers and surface open TODOs."
    )

    for prompt in [context.systemPrompt(), context.codexSystemPrompt()] {
      XCTAssertTrue(prompt.contains("Authorized Celorga corpora"))
      XCTAssertTrue(prompt.contains("Personal (active; reads and reviewed writes; kind: personal)"))
      XCTAssertTrue(prompt.contains("Team (additional; read-only; kind: shared)"))
      XCTAssertTrue(prompt.contains("/tmp/team"))
      XCTAssertTrue(prompt.contains("/srv/team"))
      XCTAssertTrue(prompt.contains("User-configured AI chat instructions"))
      XCTAssertTrue(prompt.contains("Prefer concise answers and surface open TODOs."))
    }
    // Codex receives the formatting contract as developer instructions.
    for prompt in [
      context.systemPrompt(),
      CodexAppServerClient.developerInstructions(for: .clientWorkspaceTools),
      AIChatWorkspaceContext.localAgentStandingInstructions,
    ] {
      XCTAssertTrue(prompt.contains("Celorga response formatting contract"))
      XCTAssertTrue(prompt.contains("[[file:images/qr.png][QR code]]"))
      XCTAssertTrue(prompt.contains("Celorga renders image links inline"))
      XCTAssertTrue(prompt.contains("opening Preview does not embed it"))
      XCTAssertTrue(prompt.contains("never link an absolute path outside the corpus"))
      XCTAssertTrue(prompt.contains("Inline emphasis does not nest in Celorga's Org profile"))
      XCTAssertTrue(prompt.contains("*no duplicate in* =recipes.org="))
      XCTAssertTrue(prompt.contains("|-------+--------------|"))
      XCTAssertTrue(prompt.contains("Never use a Markdown table delimiter such as |---|---|"))
      // Agents must know what the chat surface and the agent network can do.
      XCTAssertTrue(prompt.contains("Celorga chat capabilities"))
      XCTAssertTrue(prompt.contains("live, sandboxed HTML, CSS, and JavaScript app"))
      XCTAssertTrue(prompt.contains("@mention another agent in your reply"))
      XCTAssertTrue(prompt.contains("--request-turn @AGENT"))
      XCTAssertTrue(prompt.contains("celorga thread send THREAD_ID"))
      XCTAssertTrue(prompt.contains("celorga_thread_send"))
      XCTAssertTrue(prompt.contains("Do not create an automation, workflow, cron job, scheduled task, or helper script"))
      XCTAssertTrue(prompt.contains("one dash segment per column joined by +"))
      XCTAssertTrue(prompt.contains("#+begin_src sh"))
      XCTAssertTrue(prompt.contains("Never write ##+begin_src or ##+end_src"))
      XCTAssertTrue(prompt.contains("Use Org links for citations too: [[file:/absolute/path/note.org::42][source]]."))
      XCTAssertTrue(prompt.contains("[[https://example.com][label]]"))
      XCTAssertTrue(prompt.contains("Do not emit Markdown links in new replies."))
    }
  }

  func testThreadContinuationTeachesExplicitAsynchronousReporting() {
    let threadID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let context = AIChatWorkspaceContext(
      localCorpusRoot: "/tmp/personal",
      remoteCorpusRoot: "/srv/personal",
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: [],
      threadContinuation: AIChatThreadContinuation(
        id: threadID,
        title: "Async reporting",
        messages: [],
        org2References: []
      )
    )

    for prompt in [context.systemPrompt(), context.codexSystemPrompt()] {
      XCTAssertTrue(prompt.contains("ORG2_AI_CHAT_THREAD_ID: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
      XCTAssertTrue(prompt.contains("celorga_thread_post"))
      XCTAssertTrue(prompt.contains("Do not post a duplicate background message"))
    }
  }

  @MainActor
  func testAIChatContextSettingsPersist() throws {
    let suiteName = "AIChatContextSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    XCTAssertEqual(store.aiChatCorpusAccessScope, .activeCorpus)
    XCTAssertEqual(store.aiChatCustomInstructions, "")
    XCTAssertEqual(store.codexSandboxAccess, .workspaceWrite)
    XCTAssertEqual(store.aiChatMessageSound, .org2)

    store.aiChatCorpusAccessScope = .allCorpora
    store.aiChatCustomInstructions = "Always identify the source corpus."
    store.codexSandboxAccess = .fullAccess
    store.aiChatMessageSound = .purr

    let restored = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    XCTAssertEqual(restored.aiChatCorpusAccessScope, .allCorpora)
    XCTAssertEqual(restored.aiChatCustomInstructions, "Always identify the source corpus.")
    XCTAssertEqual(restored.codexSandboxAccess, .fullAccess)
    XCTAssertEqual(restored.aiChatMessageSound, .purr)
  }

  @MainActor
  func testNamedAIDestinationsPersistIndependently() throws {
    let suiteName = "AIChatDestinationSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-destination-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let id = store.addAIChatDestination()
    var destination = try XCTUnwrap(store.aiChatDestination(id: id))
    destination.name = "Codex on Press"
    destination.mention = "codex-remote"
    destination.endpoint = "wss://press.example.test/codex"
    destination.workspaceRoot = "~/dev/org2"
    store.updateAIChatDestination(destination)

    let restored = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let restoredDestination = try XCTUnwrap(restored.aiChatDestination(id: id))
    XCTAssertEqual(restoredDestination.name, "Codex on Press")
    XCTAssertEqual(restoredDestination.mention, "codex-remote")
    XCTAssertEqual(restoredDestination.adapter, .codexRemote)
    XCTAssertEqual(restoredDestination.endpoint, "wss://press.example.test/codex")
    XCTAssertEqual(restoredDestination.workspaceRoot, "~/dev/org2")
    XCTAssertTrue(restored.enabledAIChatDestinations.contains(where: { $0.id == id }))

    restored.createAIChatThread(destinationID: AIChatDestinationConfiguration.localCodexID)
    restored.setSelectedAIChatModel("local-model")
    restored.createAIChatThread(destinationID: id)
    XCTAssertNil(restored.selectedAIChatThread?.model)
    restored.setSelectedAIChatModel("remote-model")
    restored.createAIChatThread(destinationID: id)
    XCTAssertEqual(restored.selectedAIChatThread?.model, "remote-model")
  }

  @MainActor
  func testOnlyConfiguredAIDestinationsAreRestored() throws {
    let suiteName = "AIChatConfiguredDestinations.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-configured-destinations-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let initial = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    XCTAssertEqual(
      Set(initial.aiChatDestinations.map(\.id)),
      Set([
        AIChatDestinationConfiguration.localCodexID,
        AIChatDestinationConfiguration.openClawID,
      ])
    )

    var disabledClaude = try XCTUnwrap(
      AIChatDestinationConfiguration.defaults.first(where: {
        $0.id == AIChatDestinationConfiguration.localClaudeID
      })
    )
    disabledClaude.isEnabled = false
    let configuredAnthropic = AIChatDestinationConfiguration(
      name: "Anthropic",
      mention: "anthropic",
      adapter: .anthropic,
      model: "claude-test"
    )
    defaults.set(
      try JSONEncoder().encode([disabledClaude, configuredAnthropic]),
      forKey: "Org2Workspace.aiChat.destinations.v1"
    )

    let restored = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    XCTAssertNil(restored.aiChatDestination(id: disabledClaude.id))
    XCTAssertEqual(restored.aiChatDestinations.map(\.id), [configuredAnthropic.id])
    XCTAssertTrue(restored.aiChatDestinations.allSatisfy(\.isEnabled))
  }

  @MainActor
  func testDestinationDraftPersistsOnlyAfterSave() throws {
    let suiteName = "AIChatDestinationDraft.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-destination-draft-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )

    let originalCount = store.aiChatDestinations.count
    var draft = store.makeAIChatDestinationDraft(adapter: .openRouter)
    XCTAssertEqual(store.aiChatDestinations.count, originalCount)
    XCTAssertTrue(draft.isEnabled)
    draft.model = "anthropic/claude-test"
    store.updateAIChatDestination(draft)

    XCTAssertEqual(store.aiChatDestinations.count, originalCount + 1)
    XCTAssertEqual(store.aiChatDestination(id: draft.id)?.model, "anthropic/claude-test")
  }

  @MainActor
  func testBuiltInDestinationCanBeDeletedAndAddedBack() throws {
    let suiteName = "AIChatDeleteBuiltInDestination.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-delete-built-in-destination-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )

    XCTAssertTrue(store.removeAIChatDestination(AIChatDestinationConfiguration.openClawID))
    XCTAssertNil(store.aiChatDestination(id: AIChatDestinationConfiguration.openClawID))

    let draft = store.makeAIChatDestinationDraft(adapter: .openClaw)
    XCTAssertEqual(draft.id, AIChatDestinationConfiguration.openClawID)
    store.updateAIChatDestination(draft)
    XCTAssertNotNil(store.aiChatDestination(id: AIChatDestinationConfiguration.openClawID))

    let restored = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    XCTAssertNotNil(restored.aiChatDestination(id: AIChatDestinationConfiguration.openClawID))
  }

  @MainActor
  func testDestinationUsedByExistingChatCannotBeDeleted() throws {
    let suiteName = "AIChatDeleteUsedDestination.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-delete-used-destination-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let destinationID = store.addAIChatDestination(adapter: .codexManagedRemote)
    store.createAIChatThread(destinationID: destinationID)

    XCTAssertFalse(store.removeAIChatDestination(destinationID))
    XCTAssertNotNil(store.aiChatDestination(id: destinationID))
    XCTAssertEqual(
      store.aiChatDestinationSettingsError,
      "This destination is used by an existing chat. Delete that chat before deleting its destination."
    )
  }

  @MainActor
  func testManagedRemoteCodexDestinationPersistsSSHHostAndWorkspace() throws {
    let suiteName = "AIChatManagedRemoteDestination.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let id = store.addAIChatDestination(adapter: .codexManagedRemote)
    var destination = try XCTUnwrap(store.aiChatDestination(id: id))
    destination.name = "Codex on Scarf"
    destination.endpoint = "scarfs-macbook-air"
    destination.workspaceRoot = "/Users/avi/avi.org2"
    store.updateAIChatDestination(destination)

    let restored = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let restoredDestination = try XCTUnwrap(restored.aiChatDestination(id: id))
    XCTAssertEqual(restoredDestination.adapter, .codexManagedRemote)
    XCTAssertEqual(restoredDestination.endpoint, "scarfs-macbook-air")
    XCTAssertEqual(restoredDestination.workspaceRoot, "/Users/avi/avi.org2")
    XCTAssertFalse(restoredDestination.acceptsBearerToken)
  }

  @MainActor
  func testManagedRemoteCodexDefaultNameMigratesToRemoteCodex() throws {
    let suiteName = "AIChatManagedRemoteNameMigration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-name-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }
    let destination = AIChatDestinationConfiguration(
      name: "Managed Remote Codex",
      mention: "codex-scarf",
      adapter: .codexManagedRemote,
      endpoint: "scarfs-macbook-air",
      workspaceRoot: "~/avi.org2"
    )
    defaults.set(
      try JSONEncoder().encode([destination]),
      forKey: "Org2Workspace.aiChat.destinations.v1"
    )

    let restored = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )

    XCTAssertEqual(restored.aiChatDestination(id: destination.id)?.name, "Remote Codex")
  }

  @MainActor
  func testNewAIChatThreadPreservesSelectedManagedRemoteDestination() throws {
    let suiteName = "AIChatManagedRemoteNewThread.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-new-thread-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let destinationID = store.addAIChatDestination(adapter: .codexManagedRemote)
    var destination = try XCTUnwrap(store.aiChatDestination(id: destinationID))
    destination.name = "Codex on Scarf"
    destination.endpoint = "scarfs-macbook-air"
    destination.workspaceRoot = "/Users/avi/avi.org2"
    store.updateAIChatDestination(destination)

    store.createAIChatThread(destinationID: destinationID)
    store.createAIChatThread()

    XCTAssertEqual(store.selectedAIChatThread?.destinationID, destinationID)
    XCTAssertEqual(store.selectedAIChatDestination.adapter, .codexManagedRemote)
  }

  @MainActor
  func testDirectProviderDestinationPersistsEndpointAndModel() throws {
    let suiteName = "AIChatDirectProviderSettings.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-direct-provider-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let id = store.addAIChatDestination(adapter: .openRouter)
    var destination = try XCTUnwrap(store.aiChatDestination(id: id))
    XCTAssertTrue(destination.isEnabled)
    XCTAssertEqual(destination.endpoint, "https://openrouter.ai/api/v1")
    destination.model = "anthropic/claude-test"
    store.updateAIChatDestination(destination)

    let restored = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    let restoredDestination = try XCTUnwrap(restored.aiChatDestination(id: id))
    XCTAssertEqual(restoredDestination.adapter, .openRouter)
    XCTAssertEqual(restoredDestination.model, "anthropic/claude-test")
    XCTAssertTrue(restoredDestination.isEnabled)

    restored.createAIChatThread(destinationID: id)
    XCTAssertEqual(restored.selectedAIChatThread?.model, "anthropic/claude-test")
  }

  @MainActor
  func testBuiltInOpenClawDestinationInheritsConfiguredAgentAfterMigration() async throws {
    let suiteName = "AIChatDestinationAgentMigration.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-destination-agent-migration-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    defaults.set("openclaw/org2", forKey: "Org2Workspace.openClawAgent")
    let buggyDestinations = [
      AIChatDestinationConfiguration(
        id: AIChatDestinationConfiguration.localCodexID,
        name: "Codex",
        mention: "codex",
        adapter: .codexLocal
      ),
      AIChatDestinationConfiguration(
        id: AIChatDestinationConfiguration.openClawID,
        name: "OpenClaw",
        mention: "openclaw",
        adapter: .openClaw,
        agentID: "main"
      )
    ]
    defaults.set(
      try JSONEncoder().encode(buggyDestinations),
      forKey: "Org2Workspace.aiChat.destinations.v1"
    )
    let recorder = OpenClawDestinationRoutingRecorder()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, agentID, sessionKey, _ in
        await recorder.record(agentID: agentID, sessionKey: sessionKey)
        return "Routed reply"
      },
      legacyDefaultsDomains: []
    )

    XCTAssertEqual(store.openClawAgentID, "openclaw/org2")
    XCTAssertEqual(
      store.aiChatDestination(id: AIChatDestinationConfiguration.openClawID)?.agentID,
      ""
    )

    store.createAIChatThread(destinationID: AIChatDestinationConfiguration.openClawID)
    await store.sendAIChatMessage(text: "Use the configured Org2 agent")

    let routing = await recorder.value()
    XCTAssertEqual(routing?.agentID, "org2")
    XCTAssertTrue(routing?.sessionKey.hasPrefix("agent:org2:") == true)
  }

  func testCodexRemoteTransportDescribesItsWebSocketEndpoint() throws {
    let endpoint = try XCTUnwrap(URL(string: "wss://press.example.test/codex"))
    XCTAssertEqual(
      CodexAppServerTransport.remote(endpoint: endpoint, bearerToken: "secret")
        .connectionDescription,
      endpoint.absoluteString
    )
    XCTAssertEqual(CodexAppServerTransport.local.connectionDescription, "Local Codex App Server")
    XCTAssertEqual(
      CodexAppServerTransport.managedRemote(sshHost: "scarfs-macbook-air")
        .connectionDescription,
      "Remote Codex over SSH via scarfs-macbook-air"
    )
  }

  func testManagedRemoteCodexBuildsSafeKeepaliveSSHArguments() throws {
    let arguments = try CodexAppServerClient.managedRemoteSSHArguments(
      sshHost: " avi@scarfs-macbook-air "
    )

    XCTAssertEqual(arguments.prefix(2), ["-T", "-o"])
    XCTAssertTrue(arguments.contains("BatchMode=yes"))
    XCTAssertTrue(arguments.contains("ServerAliveInterval=15"))
    XCTAssertTrue(arguments.contains("ServerAliveCountMax=12"))
    XCTAssertEqual(arguments[arguments.count - 2], "avi@scarfs-macbook-air")
    XCTAssertTrue(arguments.last?.contains("codex app-server daemon start") == true)
    XCTAssertTrue(arguments.last?.contains("openorg-codex-adapter") == true)
    XCTAssertTrue(arguments.last?.contains("base64.b64decode") == true)
    XCTAssertTrue(CodexAppServerClient.managedRemoteJSONLAdapter.contains("os.path.expanduser"))
    XCTAssertFalse(arguments.last?.contains("codex app-server --listen stdio://") == true)
    XCTAssertFalse(arguments.last?.contains("codex app-server proxy") == true)
    XCTAssertThrowsError(
      try CodexAppServerClient.managedRemoteSSHArguments(
        sshHost: "-oProxyCommand=touch /tmp/unsafe"
      )
    )
  }

  func testCodexSandboxAccessBuildsAppServerPolicies() {
    let cwd = URL(fileURLWithPath: "/tmp/example-corpus", isDirectory: true)

    XCTAssertEqual(CodexSandboxAccess.readOnly.threadSandboxValue, "read-only")
    XCTAssertEqual(CodexSandboxAccess.workspaceWrite.threadSandboxValue, "workspace-write")
    XCTAssertEqual(CodexSandboxAccess.fullAccess.threadSandboxValue, "danger-full-access")
    XCTAssertEqual(
      CodexSandboxAccess.readOnly.turnSandboxPolicy(cwd: cwd),
      .object(["type": .string("readOnly")])
    )
    XCTAssertEqual(
      CodexSandboxAccess.workspaceWrite.turnSandboxPolicy(cwd: cwd),
      .object([
        "type": .string("workspaceWrite"),
        "writableRoots": .array([.string("/tmp/example-corpus")]),
        "networkAccess": .bool(false)
      ])
    )
    XCTAssertEqual(
      CodexSandboxAccess.fullAccess.turnSandboxPolicy(cwd: cwd),
      .object(["type": .string("dangerFullAccess")])
    )
    XCTAssertEqual(
      CodexSandboxAccess.workspaceWrite.turnSandboxPolicy(workspacePath: "~/avi.org2"),
      .object([
        "type": .string("workspaceWrite"),
        "writableRoots": .array([.string("~/avi.org2")]),
        "networkAccess": .bool(false)
      ])
    )
  }

  func testRemoteCodexUsesFilesystemInstructionsAndNoClientTools() {
    let instructions = CodexAppServerClient.developerInstructions(for: .runtimeFilesystem)

    XCTAssertTrue(instructions.contains("normal filesystem and shell tools"))
    XCTAssertTrue(instructions.contains("does not need to broker, preview, or apply"))
    XCTAssertFalse(instructions.contains("celorga_workspace_patch_apply"))
    XCTAssertTrue(CodexAppServerClient.dynamicTools(for: .runtimeFilesystem).isEmpty)
    XCTAssertFalse(CodexAppServerClient.dynamicTools(for: .clientWorkspaceTools).isEmpty)
  }

  func testRemoteCodexWorkspacePathsResolveOnTheRuntime() throws {
    let localRoot = URL(fileURLWithPath: "/Users/avi/avi.org2", isDirectory: true)
    let managed = AIChatDestinationConfiguration(
      name: "Codex on Scarf",
      mention: "codex-scarf",
      adapter: .codexManagedRemote,
      endpoint: "scarfdemo@scarfs-macbook-air",
      workspaceRoot: "~/avi.org2"
    )
    XCTAssertEqual(
      try WorkspaceStore.codexRuntimeWorkspacePath(
        destination: managed,
        localCorpusRoot: localRoot
      ),
      "~/avi.org2"
    )

    var missing = managed
    missing.workspaceRoot = ""
    XCTAssertThrowsError(
      try WorkspaceStore.codexRuntimeWorkspacePath(
        destination: missing,
        localCorpusRoot: localRoot
      )
    )

    var websocket = managed
    websocket.adapter = .codexRemote
    XCTAssertThrowsError(
      try WorkspaceStore.codexRuntimeWorkspacePath(
        destination: websocket,
        localCorpusRoot: localRoot
      )
    )
    websocket.workspaceRoot = "/srv/avi.org2"
    XCTAssertEqual(
      try WorkspaceStore.codexRuntimeWorkspacePath(
        destination: websocket,
        localCorpusRoot: localRoot
      ),
      "/srv/avi.org2"
    )
  }

  @MainActor
  func testAllCorporaSettingIsCapturedInTheSentTurnContext() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("ai-chat-all-corpora-\(UUID().uuidString)", isDirectory: true)
    let personal = container.appendingPathComponent("personal", isDirectory: true)
    let team = container.appendingPathComponent("team", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    _ = try WorkspaceStore.initializeStarterCorpus(at: personal, kind: "personal")
    _ = try WorkspaceStore.initializeStarterCorpus(at: team, kind: "shared")
    let suiteName = "AIChatAllCorpora.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let recorder = AIChatContextRecorder()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: container.appendingPathComponent("chat.json"),
      aiChatSendHandler: { _, _, _, context in
        await recorder.record(context)
        return "Both corpora are available."
      },
      legacyDefaultsDomains: []
    )

    store.setCorpusRoot(personal)
    await store.refreshActiveCorpusIdentity()
    store.setCorpusRoot(team)
    await store.refreshActiveCorpusIdentity()
    store.setCorpusRoot(personal)
    store.aiChatCorpusAccessScope = .allCorpora
    store.aiChatCustomInstructions = "Name the corpus for every citation."

    await store.sendAIChatMessage(text: "What can you see?")

    let recordedContext = await recorder.value()
    let context = try XCTUnwrap(recordedContext)
    XCTAssertEqual(Set(context.authorizedCorpora.map(\.localRoot)), Set([personal.path, team.path]))
    XCTAssertEqual(context.authorizedCorpora.filter(\.isActive).map(\.localRoot), [personal.path])
    XCTAssertEqual(context.customInstructions, "Name the corpus for every citation.")
  }

  @MainActor
  func testWorkspaceCreatesAndRestoresCodexThread() throws {
    let suiteName = "CodexAppServerClientTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-transcript-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: transcript) }

    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    store.createAIChatThread(runtime: .openClaw)
    XCTAssertTrue(store.canChangeSelectedAIChatRuntime)
    store.setSelectedAIChatRuntime(.codex)
    store.setSelectedAIChatModel("gpt-test")
    store.setSelectedAIChatReasoningEffort("high")
    XCTAssertEqual(store.selectedAIChatThread?.runtime, .codex)
    XCTAssertEqual(store.selectedAIChatThread?.model, "gpt-test")
    XCTAssertEqual(store.selectedAIChatThread?.reasoningEffort, "high")
    XCTAssertEqual(
      store.visibleAIChatThreads.first(where: {
        $0.id == store.selectedAIChatThreadID
      })?.runtime,
      .codex
    )

    let restored = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    XCTAssertEqual(restored.selectedAIChatThread?.runtime, .codex)
    XCTAssertEqual(restored.selectedAIChatThread?.model, "gpt-test")
    XCTAssertEqual(restored.selectedAIChatThread?.reasoningEffort, "high")
  }

  func testClientRunsCodexTurnAndAnswersDynamicToolCall() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-app-server-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex")
    try Self.fakeAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )

    let recorder = CodexTestRecorder()
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { event in
        await recorder.record(event)
      },
      dynamicToolHandler: { call in
        await recorder.record(call)
        return CodexDynamicToolResult(
          success: true,
          text: #"{"path":"notes/example.org2","text":"effective local text"}"#
        )
      }
    )

    let account = try await client.accountState()
    XCTAssertEqual(account, .chatGPT(email: "test@example.com", plan: "plus"))

    let threadID = try await client.ensureThread(
      existingThreadID: nil,
      cwd: temporaryDirectory,
      model: "gpt-test",
      sandboxAccess: .fullAccess
    )
    XCTAssertEqual(threadID, "thr-test")

    let result = try await client.runTurn(
      threadID: threadID,
      turnID: "local-turn",
      message: "Read the note.",
      workspaceContext: "Selected source includes an unsaved draft.",
      attachments: [],
      cwd: temporaryDirectory,
      attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID()),
      model: "gpt-test",
      reasoningEffort: "high",
      sandboxAccess: .fullAccess
    )
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Final reply")
    XCTAssertEqual(result.usage?.inputTokens, 123)
    XCTAssertEqual(result.usage?.cachedInputTokens, 45)
    XCTAssertEqual(result.usage?.outputTokens, 6)
    XCTAssertEqual(result.usage?.totalTokens, 129)

    var toolCall = await recorder.toolCall
    for _ in 0..<50 where toolCall == nil {
      try await Task.sleep(for: .milliseconds(10))
      toolCall = await recorder.toolCall
    }
    XCTAssertEqual(toolCall?.tool, "org2_workspace_read")
    XCTAssertEqual(toolCall?.arguments["turnId"]?.stringValue, "local-turn")
    let streamedText = await recorder.streamedText
    XCTAssertEqual(streamedText, "Working…")
    let contextCompactionCount = await recorder.contextCompactionCount
    XCTAssertEqual(contextCompactionCount, 1)

    let models = try await client.listModels()
    XCTAssertEqual(models.map(\.id), ["gpt-test"])
    XCTAssertEqual(models.first?.label, "GPT Test")
    XCTAssertEqual(models.first?.reasoningOptions.map(\.id), ["low", "high"])
    XCTAssertEqual(models.first?.defaultReasoningEffort, "low")
    XCTAssertTrue(models.first?.isDefault == true)

    await client.shutdown()
  }

  func testTransportFailureConsumesPendingTurnContinuation() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-transport-end-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-transport-end")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-transport-end"}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*)
          printf '{"id":%s,"result":{"turn":{"id":"turn-transport-end","status":"inProgress"}}}\n' "$request_id"
          printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-transport-end","turn":{"id":"turn-transport-end","status":"inProgress","items":[]}}}'
          sleep 0.15
          exit 0
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )
    let threadID = try await client.ensureThread(
      existingThreadID: nil,
      cwd: temporaryDirectory
    )

    do {
      _ = try await client.runTurn(
        threadID: threadID,
        turnID: "local-turn",
        message: "Wait for the transport to close.",
        attachments: [],
        cwd: temporaryDirectory,
        attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID())
      )
      XCTFail("A closed transport should fail its active turn")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Codex turn failed: connection closed")
    }

#if DEBUG
    // The counter is an internal debug-only probe. Release-mode CI still runs
    // this transport-close path, but must not reference a symbol omitted from
    // production builds.
    let pendingTurnCount = await client.pendingTurnCountForTesting()
    XCTAssertEqual(pendingTurnCount, 0)
#endif
    await client.shutdown()
  }

  func testLocalTurnWaitsForNotificationWithoutPollingThreadRead() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-local-no-poll-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let readMarker = temporaryDirectory.appendingPathComponent("thread-read-requested")
    let executable = temporaryDirectory.appendingPathComponent("fake-codex-local-no-poll")
    // A thread/read during the turn answers with a status Celorga does not
    // recognize. Polling it used to fail a turn Codex was still answering.
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-local"}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*)
          printf '{"id":%s,"result":{"turn":{"id":"turn-local","status":"inProgress"}}}\n' "$request_id"
          printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-local","turn":{"id":"turn-local","status":"inProgress","items":[]}}}'
          (
            sleep 2.5
            printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-local","turn":{"id":"turn-local","status":"completed","items":[{"id":"agent-final","type":"agentMessage","phase":"final_answer","text":"Finished locally"}]}}}'
          ) &
          ;;
        *'"method":"thread/read"'*)
          : > '\#(readMarker.path)'
          printf '{"id":%s,"result":{"thread":{"id":"thr-local","turns":[{"id":"turn-local","status":"waitingOnTool","items":[]}]}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )
    let threadID = try await client.ensureThread(existingThreadID: nil, cwd: temporaryDirectory)

    let result = try await client.runTurn(
      threadID: threadID,
      turnID: "local-turn",
      message: "Take a few seconds.",
      attachments: [],
      cwd: temporaryDirectory,
      attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID())
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Finished locally")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: readMarker.path),
      "a local turn must not be polled with thread/read while Codex owns it"
    )
    await client.shutdown()
  }

  func testTurnStartMergedIntoActiveTurnResolvesEveryWaiter() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-merged-turn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-merged-turn")
    // Codex appends a turn/start sent during an active turn to that turn and
    // returns the active turn's ID instead of starting a second one.
    let script = #"""
    #!/bin/sh
    starts=0
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-merged"}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*)
          starts=$((starts + 1))
          printf '{"id":%s,"result":{"turn":{"id":"turn-merged","status":"inProgress"}}}\n' "$request_id"
          if [ "$starts" = 1 ]; then
            printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-merged","turn":{"id":"turn-merged","status":"inProgress","items":[]}}}'
          else
            (
              sleep 0.5
              printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-merged","turn":{"id":"turn-merged","status":"completed","items":[{"id":"agent-final","type":"agentMessage","phase":"final_answer","text":"Answered both"}]}}}'
            ) &
          fi
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )
    let threadID = try await client.ensureThread(existingThreadID: nil, cwd: temporaryDirectory)

    async let first = client.runTurn(
      threadID: threadID,
      turnID: "local-turn-1",
      message: "First message.",
      attachments: [],
      cwd: temporaryDirectory,
      attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID())
    )
    try await Task.sleep(for: .milliseconds(300))
    let second = try await client.runTurn(
      threadID: threadID,
      turnID: "local-turn-2",
      message: "Second message during the active turn.",
      attachments: [],
      cwd: temporaryDirectory,
      attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID())
    )
    let firstResult = try await first

    XCTAssertEqual(second.status, .completed)
    XCTAssertEqual(firstResult.status, .completed, "the earlier send must not be left waiting forever")
    XCTAssertEqual(firstResult.reply, "Answered both")
    await client.shutdown()
  }

  func testManagedRemoteRecoveryKeepsWaitingThroughUnrecognizedStatus() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-unrecognized-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let readCount = temporaryDirectory.appendingPathComponent("read-count")
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    count_file='\#(readCount.path)'
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-unrecognized"}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*)
          printf '{"id":%s,"result":{"turn":{"id":"turn-unrecognized","status":"inProgress"}}}\n' "$request_id"
          ;;
        *'"method":"thread/read"'*)
          case "$line" in
            *celorgaDeliveryRead*)
              printf '{"id":%s,"result":{"thread":{"id":"thr-unrecognized","turns":[]}}}\n' "$request_id"
              continue
              ;;
          esac
          count=0
          if [ -f "$count_file" ]; then count=$(/usr/bin/sed -n '1p' "$count_file"); fi
          count=$((count + 1))
          printf '%s\n' "$count" > "$count_file"
          if [ "$count" -lt 2 ]; then
            printf '{"id":%s,"result":{"thread":{"id":"thr-unrecognized","turns":[{"id":"turn-unrecognized","items":[]}]}}}\n' "$request_id"
          else
            printf '{"id":%s,"result":{"thread":{"id":"thr-unrecognized","turns":[{"id":"turn-unrecognized","status":"completed","items":[{"id":"agent-final","type":"agentMessage","phase":"final_answer","text":"Still answered"}]}]}}}\n' "$request_id"
          fi
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      requestTimeoutNanoseconds: 5_000_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )
    let threadID = try await client.ensureThread(existingThreadID: nil, cwd: temporaryDirectory)

    let result = try await client.runTurn(
      threadID: threadID,
      turnID: "local-turn",
      message: "A status-less read is not completion.",
      attachments: [],
      cwd: temporaryDirectory,
      attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID())
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Still answered")
    await client.shutdown()
  }

  func testAgedModelCatalogRestartsIdleAppServerBeforeRefresh() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-model-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-model-refresh")
    let script = #"""
    #!/bin/sh
    count_file="$0.count"
    count=0
    if [ -f "$count_file" ]; then
      count=$(sed -n '1p' "$count_file")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"model/list"'*)
          if [ "$count" -eq 1 ]; then
            model_id="gpt-before-refresh"
            model_name="Before refresh"
          else
            model_id="gpt-after-refresh"
            model_name="After refresh"
          fi
          printf '{"id":%s,"result":{"data":[{"id":"%s","displayName":"%s","isDefault":true}],"nextCursor":null}}\n' "$request_id" "$model_id" "$model_name"
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )

    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in
        CodexDynamicToolResult(success: false, text: "No tools in this test.")
      }
    )

    let first = try await client.listModels(refreshingTransportIfOlderThan: 300)
    let refreshed = try await client.listModels(refreshingTransportIfOlderThan: 0)

    XCTAssertEqual(first.map(\.id), ["gpt-before-refresh"])
    XCTAssertEqual(refreshed.map(\.id), ["gpt-after-refresh"])
    await client.shutdown()
  }

  func testModelRefreshRediscoversRelocatedLocalExecutable() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-relocated-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let originalExecutable = temporaryDirectory.appendingPathComponent("codex-original")
    let relocatedExecutable = temporaryDirectory.appendingPathComponent("codex-relocated")
    func installFakeCodex(at executable: URL, modelID: String) throws {
      let script = #"""
      #!/bin/sh
      while IFS= read -r line; do
        request_id=$(printf '%s\n' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        case "$line" in
          *'"method":"initialize"'*)
            printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
            ;;
          *'"method":"initialized"'*)
            ;;
          *'"method":"model/list"'*)
            printf '{"id":%s,"result":{"data":[{"id":"\#(modelID)","displayName":"\#(modelID)","isDefault":true}],"nextCursor":null}}\n' "$request_id"
            ;;
        esac
      done
      """#
      try script.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
      )
    }

    try installFakeCodex(at: originalExecutable, modelID: "gpt-before-relocation")
    let client = CodexAppServerClient(
      executableResolver: {
        FileManager.default.isExecutableFile(atPath: relocatedExecutable.path)
          ? relocatedExecutable
          : originalExecutable
      },
      eventHandler: { _ in },
      dynamicToolHandler: { _ in
        CodexDynamicToolResult(success: false, text: "No tools in this test.")
      }
    )

    let first = try await client.listModels(refreshingTransportIfOlderThan: 300)
    try installFakeCodex(at: relocatedExecutable, modelID: "gpt-after-relocation")
    let refreshed = try await client.listModels(refreshingTransportIfOlderThan: 0)

    XCTAssertEqual(first.map(\.id), ["gpt-before-relocation"])
    XCTAssertEqual(refreshed.map(\.id), ["gpt-after-relocation"])
    await client.shutdown()
  }

  func testInitializationTimeoutResetsTransportForRetry() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-initialize-reset-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let launchCount = temporaryDirectory.appendingPathComponent("launch-count")
    let executable = temporaryDirectory.appendingPathComponent("fake-codex-initialize-reset")
    let script = #"""
    #!/bin/sh
    count_file='\#(launchCount.path)'
    count=0
    if [ -f "$count_file" ]; then
      count=$(sed -n '1p' "$count_file")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    initialized=0
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          if [ "$initialized" -eq 1 ]; then
            printf '{"id":%s,"error":{"code":-32600,"message":"Already initialized"}}\n' "$request_id"
            continue
          fi
          initialized=1
          if [ "$count" -eq 1 ]; then
            sleep 10
          fi
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"model/list"'*)
          printf '{"id":%s,"result":{"data":[{"id":"gpt-recovered","displayName":"Recovered","isDefault":true}],"nextCursor":null}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      // Long enough for the relaunched fake server to answer on a busy
      // machine; the first launch still sleeps well past it.
      requestTimeoutNanoseconds: 2_000_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    do {
      _ = try await client.listModels()
      XCTFail("The first initialization should time out")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Codex did not respond to initialize before the request timed out."
      )
    }

    let models = try await client.listModels()

    XCTAssertEqual(models.map(\.id), ["gpt-recovered"])
    XCTAssertEqual(
      try String(contentsOf: launchCount, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "2"
    )
    await client.shutdown()
  }

  func testSlowThreadResumeUsesDedicatedRecoveryTimeout() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-slow-resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-slow-resume")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/resume"'*)
          sleep 1.2
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr-slow"}}}'
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      requestTimeoutNanoseconds: 1_000_000_000,
      threadResumeRequestTimeoutNanoseconds: 3_000_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let threadID = try await client.ensureThread(
      existingThreadID: "thr-slow",
      cwd: temporaryDirectory
    )

    XCTAssertEqual(threadID, "thr-slow")
    await client.shutdown()
  }

  func testTimedOutThreadResumeResetsTransportForRetry() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-resume-reset-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let marker = temporaryDirectory.appendingPathComponent("first-resume-started")
    let firstProcessID = temporaryDirectory.appendingPathComponent("first-process-id")
    let executable = temporaryDirectory.appendingPathComponent("fake-codex-resume-reset")
    let script = #"""
    #!/bin/sh
    marker='\#(marker.path)'
    first_process_id='\#(firstProcessID.path)'
    trap '' TERM
    if [ ! -f "$first_process_id" ]; then
      printf '%s\n' "$$" > "$first_process_id"
    fi
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/resume"'*)
          if [ ! -f "$marker" ]; then
            : > "$marker"
            sleep 1
          fi
          printf '{"id":%s,"result":{"thread":{"id":"thr-retry"}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      requestTimeoutNanoseconds: 5_000_000_000,
      threadResumeRequestTimeoutNanoseconds: 100_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    do {
      _ = try await client.ensureThread(
        existingThreadID: "thr-retry",
        cwd: temporaryDirectory
      )
      XCTFail("The first slow resume should time out")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "Codex took too long to reopen this task. Its connection was reset; retry once to reconnect."
      )
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    let abandonedProcessID = try XCTUnwrap(
      Int(String(contentsOf: firstProcessID, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines))
    )
    for _ in 0..<50 where Darwin.kill(Int32(abandonedProcessID), 0) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotEqual(
      Darwin.kill(Int32(abandonedProcessID), 0),
      0,
      "A timed-out app-server must not retain its task-writer lock"
    )

    let threadID = try await client.ensureThread(
      existingThreadID: "thr-retry",
      cwd: temporaryDirectory
    )

    XCTAssertEqual(threadID, "thr-retry")
    await client.shutdown()
  }

  func testTimedOutThreadResumeAutomaticallyStartsAReplacementTask() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-auto-rebind-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let marker = temporaryDirectory.appendingPathComponent("resume-started")
    let executable = temporaryDirectory.appendingPathComponent("fake-codex-auto-rebind")
    let script = #"""
    #!/bin/sh
    marker='\#(marker.path)'
    trap '' TERM
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/resume"'*)
          : > "$marker"
          sleep 1
          ;;
        *'"method":"thread/start"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-replacement"}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      requestTimeoutNanoseconds: 5_000_000_000,
      threadResumeRequestTimeoutNanoseconds: 100_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let resolution = try await client.ensureThreadRecoveringStaleSession(
      existingThreadID: "thr-stale",
      cwd: temporaryDirectory
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    XCTAssertEqual(
      resolution,
      CodexThreadResolution(threadID: "thr-replacement", replacedStaleThread: true)
    )
    await client.shutdown()
  }

  func testMissingRolloutAutomaticallyStartsAReplacementTask() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-missing-rollout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-missing-rollout")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/resume"'*)
          printf '{"id":%s,"error":{"code":-32600,"message":"no rollout found for thread id thr-phone"}}\n' "$request_id"
          ;;
        *'"method":"thread/start"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-laptop-replacement"}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let resolution = try await client.ensureThreadRecoveringStaleSession(
      existingThreadID: "thr-phone",
      cwd: temporaryDirectory
    )

    XCTAssertEqual(
      resolution,
      CodexThreadResolution(threadID: "thr-laptop-replacement", replacedStaleThread: true)
    )
    await client.shutdown()
  }

  func testManagedRemoteClientUsesSSHDaemonJSONLAdapterTransport() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    try Self.fakeAppServerScript.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: fakeSSH.path
    )
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "scarfs-macbook-air"),
      eventHandler: { _ in },
      dynamicToolHandler: { _ in
        CodexDynamicToolResult(success: false, text: "unused")
      }
    )

    let account = try await client.accountState()

    XCTAssertEqual(account, .chatGPT(email: "test@example.com", plan: "plus"))
    await client.shutdown()
  }

  func testManagedRemoteBridgeAtomicallyAdmitsOneConcurrentAttemptAcrossFreshHosts() async throws {
    let temporaryDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cga-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let codexHome = temporaryDirectory.appendingPathComponent("codex-home", isDirectory: true)
    let controlDirectory = codexHome
      .appendingPathComponent("app-server-control", isDirectory: true)
    try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
    let socketPath = controlDirectory.appendingPathComponent("app-server-control.sock")
    let countPath = temporaryDirectory.appendingPathComponent("physical-start-count")
    let acceptedPath = temporaryDirectory.appendingPathComponent("accepted-attempt")
    let daemonScript = temporaryDirectory.appendingPathComponent("fake-daemon.py")
    try Self.fakeManagedRemoteDaemonScript.write(
      to: daemonScript,
      atomically: true,
      encoding: .utf8
    )
    let daemon = Process()
    daemon.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3")
    daemon.arguments = [
      daemonScript.path,
      socketPath.path,
      countPath.path,
      acceptedPath.path,
      "0"
    ]
    let daemonError = Pipe()
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = daemonError
    try daemon.run()
    defer {
      if daemon.isRunning { daemon.terminate() }
      daemon.waitUntilExit()
    }
    let socketDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: socketPath.path), Date() < socketDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard FileManager.default.fileExists(atPath: socketPath.path) else {
      if daemon.isRunning { daemon.terminate() }
      let detail = String(
        decoding: daemonError.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
      )
      return XCTFail("Fixture daemon did not create its socket: \(detail)")
    }

    let adapterScript = temporaryDirectory.appendingPathComponent("adapter.py")
    try CodexAppServerClient.managedRemoteJSONLAdapter.write(
      to: adapterScript,
      atomically: true,
      encoding: .utf8
    )
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let claimRoot = temporaryDirectory.appendingPathComponent("claims", isDirectory: true)
    let launcher = #"""
    #!/bin/sh
    export CODEX_HOME='\#(codexHome.path)'
    export CELORGA_MANAGED_REMOTE_CLAIM_ROOT='\#(claimRoot.path)'
    exec /usr/local/bin/python3 '\#(adapterScript.path)'
    """#
    try launcher.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    let messageID = UUID()
    let firstIdentity = CodexTurnAttemptIdentity(messageID: messageID, attemptID: messageID)
    let secondIdentity = CodexTurnAttemptIdentity(messageID: messageID, attemptID: UUID())
    let startRecorder = CodexTurnStartRecorder()
    func makeClient() -> CodexAppServerClient {
      CodexAppServerClient(
        executableURL: nil,
        sshExecutableURL: fakeSSH,
        transport: .managedRemote(sshHost: "isolated.test"),
        requestTimeoutNanoseconds: 2_000_000_000,
        eventHandler: { event in await startRecorder.record(event) },
        dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
      )
    }
    let first = makeClient()
    let second = makeClient()
    let firstTask = Task {
      try await first.runTurn(
        threadID: "thr-atomic",
        turnID: "local-first",
        message: "one physical start",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: firstIdentity
      )
    }
    let secondTask = Task {
      try await second.runTurn(
        threadID: "thr-atomic",
        turnID: "local-second",
        message: "one physical start",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: secondIdentity
      )
    }
    var completed = 0
    var held = 0
    for task in [firstTask, secondTask] {
      do {
        let result = try await task.value
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.turnID, "turn-atomic")
        completed += 1
      } catch let error as CodexAppServerError {
        guard case .turnStartUnknown = error else {
          XCTFail("Expected a completed reconciliation or held duplicate, got \(error)")
          continue
        }
        held += 1
      }
    }
    XCTAssertEqual(completed, 1)
    XCTAssertEqual(held, 1)
    XCTAssertEqual(
      try String(contentsOf: countPath, encoding: .utf8)
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }.count,
      1
    )
    let recordedStarts = await startRecorder.starts
    XCTAssertEqual(recordedStarts.count, 1)
    XCTAssertEqual(recordedStarts.first?.threadID, "thr-atomic")
    XCTAssertEqual(recordedStarts.first?.turnID, "turn-atomic")
    let journalURLs = Self.managedRemoteJournalURLs(in: claimRoot)
    XCTAssertEqual(journalURLs.count, 1)
    let journalURL = try XCTUnwrap(journalURLs.first)
    let journal = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
    )
    XCTAssertEqual(journal["messageId"] as? String, messageID.uuidString.lowercased())
    XCTAssertEqual((journal["attempts"] as? [String: Any])?.count, 1)
    let admittedAttemptID = try XCTUnwrap(
      UUID(uuidString: try XCTUnwrap(journal["currentAttemptId"] as? String))
    )
    let drifted = makeClient()
    do {
      _ = try await drifted.runTurn(
        threadID: "thr-atomic",
        turnID: "local-drifted",
        message: "changed payload after claim",
        attachments: [],
        workspacePath: "~/different-corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(
          messageID: messageID,
          attemptID: admittedAttemptID
        )
      )
      XCTFail("A claimed attempt's exact request contract must not drift")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held contract drift, got \(error)")
      }
    }
    XCTAssertEqual(
      try String(contentsOf: countPath, encoding: .utf8)
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }.count,
      1
    )
    let rebound = makeClient()
    do {
      _ = try await rebound.runTurn(
        threadID: "thr-replacement",
        turnID: "local-rebound",
        message: "one physical start",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(
          messageID: messageID,
          attemptID: admittedAttemptID
        )
      )
      XCTFail("Replacing the native thread must not rebind message authority")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held native-thread replacement, got \(error)")
      }
    }
    await rebound.shutdown()

    try FileManager.default.removeItem(at: journalURL)
    let missingJournal = makeClient()
    do {
      _ = try await missingJournal.runTurn(
        threadID: "thr-atomic",
        turnID: "local-missing-journal",
        message: "one physical start",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(
          messageID: messageID,
          attemptID: admittedAttemptID
        )
      )
      XCTFail("A missing authority journal must fail closed")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held missing journal, got \(error)")
      }
    }
    await missingJournal.shutdown()

    try Data("not-json".utf8).write(to: journalURL)
    let corruptJournal = makeClient()
    do {
      _ = try await corruptJournal.runTurn(
        threadID: "thr-atomic",
        turnID: "local-corrupt-journal",
        message: "one physical start",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(
          messageID: messageID,
          attemptID: admittedAttemptID
        )
      )
      XCTFail("A corrupt authority journal must fail closed")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held corrupt journal, got \(error)")
      }
    }
    await corruptJournal.shutdown()

    let unrelatedMessageID = UUID()
    let missingAuthorityChild = makeClient()
    do {
      _ = try await missingAuthorityChild.runTurn(
        threadID: "thr-atomic",
        turnID: "local-missing-authority-child",
        message: "unauthorized child",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(
          messageID: unrelatedMessageID,
          attemptID: UUID(),
          predecessorAttemptID: unrelatedMessageID
        )
      )
      XCTFail("A child attempt must not create missing message authority")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held missing authority child, got \(error)")
      }
    }
    await missingAuthorityChild.shutdown()
    XCTAssertEqual(
      try String(contentsOf: countPath, encoding: .utf8)
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }.count,
      1
    )
    await drifted.shutdown()
    await first.shutdown()
    await second.shutdown()
  }

  func testManagedRemoteBridgeAdmitsOnlyOneConcurrentChildOfFailedPredecessor() async throws {
    let temporaryDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cgr-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let codexHome = temporaryDirectory.appendingPathComponent("codex-home", isDirectory: true)
    let controlDirectory = codexHome.appendingPathComponent(
      "app-server-control",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
    let socketPath = controlDirectory.appendingPathComponent("app-server-control.sock")
    let countPath = temporaryDirectory.appendingPathComponent("physical-start-count")
    let acceptedPath = temporaryDirectory.appendingPathComponent("accepted-attempt")
    let daemonScript = temporaryDirectory.appendingPathComponent("fake-daemon.py")
    try Self.fakeManagedRemoteDaemonScript.write(
      to: daemonScript,
      atomically: true,
      encoding: .utf8
    )
    let daemon = Process()
    daemon.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3")
    daemon.arguments = [
      daemonScript.path,
      socketPath.path,
      countPath.path,
      acceptedPath.path,
      "0",
      "fail-first"
    ]
    let daemonError = Pipe()
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = daemonError
    try daemon.run()
    defer {
      if daemon.isRunning { daemon.terminate() }
      daemon.waitUntilExit()
    }
    let socketDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: socketPath.path), Date() < socketDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard FileManager.default.fileExists(atPath: socketPath.path) else {
      return XCTFail("Fixture daemon did not create its socket")
    }

    let adapterScript = temporaryDirectory.appendingPathComponent("adapter.py")
    try CodexAppServerClient.managedRemoteJSONLAdapter.write(
      to: adapterScript,
      atomically: true,
      encoding: .utf8
    )
    let claimRoot = temporaryDirectory.appendingPathComponent("claims", isDirectory: true)
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let launcher = #"""
    #!/bin/sh
    export CODEX_HOME='\#(codexHome.path)'
    export CELORGA_MANAGED_REMOTE_CLAIM_ROOT='\#(claimRoot.path)'
    exec /usr/local/bin/python3 '\#(adapterScript.path)'
    """#
    try launcher.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    func makeClient() -> CodexAppServerClient {
      CodexAppServerClient(
        executableURL: nil,
        sshExecutableURL: fakeSSH,
        transport: .managedRemote(sshHost: "isolated.test"),
        requestTimeoutNanoseconds: 2_000_000_000,
        eventHandler: { _ in },
        dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
      )
    }

    let messageID = UUID()
    let predecessor = CodexTurnAttemptIdentity(messageID: messageID, attemptID: messageID)
    let initial = makeClient()
    do {
      _ = try await initial.runTurn(
        threadID: "thr-atomic",
        turnID: "local-initial",
        message: "retry only after exact failure",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: predecessor
      )
      XCTFail("The fixture's initial provider turn must fail")
    } catch let error as CodexAppServerError {
      guard case .turnFailed = error else {
        return XCTFail("Expected exact provider failure, got \(error)")
      }
    }
    await initial.shutdown()

    let firstChild = CodexTurnAttemptIdentity(
      messageID: messageID,
      attemptID: UUID(),
      predecessorAttemptID: messageID
    )
    let secondChild = CodexTurnAttemptIdentity(
      messageID: messageID,
      attemptID: UUID(),
      predecessorAttemptID: messageID
    )
    let first = makeClient()
    let second = makeClient()
    let tasks = [
      Task {
        try await first.runTurn(
          threadID: "thr-atomic",
          turnID: "local-child-one",
          message: "retry only after exact failure",
          attachments: [],
          workspacePath: "~/corpus",
          corpusAccess: .runtimeFilesystem,
          attemptIdentity: firstChild
        )
      },
      Task {
        try await second.runTurn(
          threadID: "thr-atomic",
          turnID: "local-child-two",
          message: "retry only after exact failure",
          attachments: [],
          workspacePath: "~/corpus",
          corpusAccess: .runtimeFilesystem,
          attemptIdentity: secondChild
        )
      }
    ]
    var completed = 0
    var held = 0
    for task in tasks {
      do {
        let result = try await task.value
        XCTAssertEqual(result.status, .completed)
        completed += 1
      } catch let error as CodexAppServerError {
        guard case .turnStartUnknown = error else {
          XCTFail("Expected one completed child and one held child, got \(error)")
          continue
        }
        held += 1
      }
    }
    XCTAssertEqual(completed, 1)
    XCTAssertEqual(held, 1)
    XCTAssertEqual(
      try String(contentsOf: countPath, encoding: .utf8)
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }.count,
      2
    )

    // Simulate a later field-losing writer after the accepted child became
    // current. Falling back to the deterministic initial identity must not
    // adopt any stale initial native terminal or start a third turn.
    let fieldLost = makeClient()
    do {
      _ = try await fieldLost.runTurn(
        threadID: "thr-atomic",
        turnID: "local-after-child-field-loss",
        message: "retry only after exact failure",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(
          messageID: messageID,
          attemptID: messageID
        ),
        turnStartPolicy: .reconcileOnly
      )
      XCTFail("Field loss after a child attempt must remain held")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected field-lost stale identity to remain held, got \(error)")
      }
    }
    await fieldLost.shutdown()
    XCTAssertEqual(
      try String(contentsOf: countPath, encoding: .utf8)
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }.count,
      2
    )
    let journalURLs = Self.managedRemoteJournalURLs(in: claimRoot)
    XCTAssertEqual(journalURLs.count, 1)
    let journalURL = try XCTUnwrap(journalURLs.first)
    let journal = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: journalURL)
      ) as? [String: Any]
    )
    XCTAssertEqual((journal["attempts"] as? [String: Any])?.count, 2)
    await first.shutdown()
    await second.shutdown()
  }

  func testManagedRemoteBridgeHoldsPostWriteServerErrorAcrossFieldLossAndReload() async throws {
    let temporaryDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cge-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let codexHome = temporaryDirectory.appendingPathComponent("codex-home", isDirectory: true)
    let controlDirectory = codexHome.appendingPathComponent("app-server-control", isDirectory: true)
    try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
    let socketPath = controlDirectory.appendingPathComponent("app-server-control.sock")
    let countPath = temporaryDirectory.appendingPathComponent("physical-start-count")
    let acceptedPath = temporaryDirectory.appendingPathComponent("accepted-attempt")
    let daemonScript = temporaryDirectory.appendingPathComponent("fake-daemon.py")
    try Self.fakeManagedRemoteDaemonScript.write(
      to: daemonScript,
      atomically: true,
      encoding: .utf8
    )
    let daemon = Process()
    daemon.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3")
    daemon.arguments = [
      daemonScript.path,
      socketPath.path,
      countPath.path,
      acceptedPath.path,
      "0",
      "error-first"
    ]
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = FileHandle.nullDevice
    try daemon.run()
    defer {
      if daemon.isRunning { daemon.terminate() }
      daemon.waitUntilExit()
    }
    let socketDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: socketPath.path), Date() < socketDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard FileManager.default.fileExists(atPath: socketPath.path) else {
      return XCTFail("Fixture daemon did not create its socket")
    }

    let adapterScript = temporaryDirectory.appendingPathComponent("adapter.py")
    try CodexAppServerClient.managedRemoteJSONLAdapter.write(
      to: adapterScript,
      atomically: true,
      encoding: .utf8
    )
    let claimRoot = temporaryDirectory.appendingPathComponent("claims", isDirectory: true)
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let launcher = #"""
    #!/bin/sh
    export CODEX_HOME='\#(codexHome.path)'
    export CELORGA_MANAGED_REMOTE_CLAIM_ROOT='\#(claimRoot.path)'
    exec /usr/local/bin/python3 '\#(adapterScript.path)'
    """#
    try launcher.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    func makeClient() -> CodexAppServerClient {
      CodexAppServerClient(
        executableURL: nil,
        sshExecutableURL: fakeSSH,
        transport: .managedRemote(sshHost: "isolated.test"),
        requestTimeoutNanoseconds: 1_000_000_000,
        eventHandler: { _ in },
        dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
      )
    }

    let messageID = UUID()
    let first = makeClient()
    do {
      _ = try await first.runTurn(
        threadID: "thr-atomic",
        turnID: "local-unknown",
        message: "server error after write",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(messageID: messageID, attemptID: messageID)
      )
      XCTFail("A generic post-write server error must remain unknown")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held unknown delivery, got \(error)")
      }
    }
    await first.shutdown()

    // Simulate complete loss of additive transcript fields: a fresh process
    // invents a different attempt with no predecessor.
    // The independent producer journal must still block physical replay.
    let reloaded = makeClient()
    do {
      _ = try await reloaded.runTurn(
        threadID: "thr-atomic",
        turnID: "local-after-field-loss",
        message: "server error after write",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(messageID: messageID, attemptID: UUID())
      )
      XCTFail("Field loss and reload must not bypass an unknown producer claim")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected producer-held replay, got \(error)")
      }
    }
    XCTAssertEqual(
      try String(contentsOf: countPath, encoding: .utf8)
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }.count,
      1
    )
    let journalURLs = Self.managedRemoteJournalURLs(in: claimRoot)
    XCTAssertEqual(journalURLs.count, 1)
    let journalURL = try XCTUnwrap(journalURLs.first)
    let journal = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: journalURL)
      ) as? [String: Any]
    )
    let attempts = try XCTUnwrap(journal["attempts"] as? [String: [String: Any]])
    XCTAssertEqual(attempts[messageID.uuidString.lowercased()]?["state"] as? String, "unknown")
    XCTAssertEqual(attempts.count, 1)
    await reloaded.shutdown()
  }

  func testManagedRemoteTurnRecoversAfterSSHTransportEnds() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let connectionCount = temporaryDirectory.appendingPathComponent("connection-count")
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    count_file='\#(connectionCount.path)'
    count=0
    if [ -f "$count_file" ]; then
      count=$(/usr/bin/sed -n '1p' "$count_file")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/start"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-durable"}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*)
          printf '{"id":%s,"result":{"turn":{"id":"turn-durable","status":"inProgress"}}}\n' "$request_id"
          printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-durable","turn":{"id":"turn-durable","status":"inProgress","items":[]}}}'
          exit 0
          ;;
        *'"method":"thread/read"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-durable","turns":[{"id":"turn-durable","status":"completed","items":[{"id":"agent-final","type":"agentMessage","phase":"final_answer","text":"Recovered after wake"}]}]}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      requestTimeoutNanoseconds: 5_000_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )
    let threadID = try await client.ensureThread(
      existingThreadID: nil,
      cwd: temporaryDirectory
    )

    let result = try await client.runTurn(
      threadID: threadID,
      turnID: "local-turn",
      message: "Keep working while the laptop sleeps.",
      attachments: [],
      cwd: temporaryDirectory,
      attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID())
    )

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Recovered after wake")
    XCTAssertEqual(
      try String(contentsOf: connectionCount, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "2"
    )
    await client.shutdown()
  }

  func testManagedRemoteRetryReconcilesSameMessageWithoutStartingDuplicateTurn() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-retry-reconcile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let turnStartMarker = temporaryDirectory.appendingPathComponent("turn-started")
    let messageID = UUID()
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/read"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-existing","turns":[{"id":"turn-existing","status":"completed","items":[{"id":"user-existing","type":"userMessage","clientId":"\#(messageID.uuidString.lowercased())","content":[{"type":"text","text":"same durable message"}]},{"id":"agent-final","type":"agentMessage","phase":"final_answer","text":"Already delivered once"}]}]}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*)
          : > '\#(turnStartMarker.path)'
          printf '{"id":%s,"result":{"turn":{"id":"turn-duplicate"}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      requestTimeoutNanoseconds: 2_000_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let result = try await client.runTurn(
      threadID: "thr-existing",
      turnID: "local-retry",
      message: "same durable message",
      attachments: [],
      workspacePath: "~/corpus",
      corpusAccess: .runtimeFilesystem,
      attemptIdentity: CodexTurnAttemptIdentity(messageID: messageID, attemptID: messageID),
      turnStartPolicy: .reconcileOnly
    )

    XCTAssertEqual(result.turnID, "turn-existing")
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Already delivered once")
    XCTAssertFalse(FileManager.default.fileExists(atPath: turnStartMarker.path))
    await client.shutdown()
  }

  func testManagedRemoteLostTurnStartResponseReconcilesAcceptedSameMessage() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-lost-start-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let turnStartCount = temporaryDirectory.appendingPathComponent("turn-start-count")
    let acceptedMarker = temporaryDirectory.appendingPathComponent("accepted")
    let messageID = UUID()
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"turn/start"'*)
          count=0
          if [ -f '\#(turnStartCount.path)' ]; then count=$(/usr/bin/sed -n '1p' '\#(turnStartCount.path)'); fi
          printf '%s\n' "$((count + 1))" > '\#(turnStartCount.path)'
          : > '\#(acceptedMarker.path)'
          exit 0
          ;;
        *'"method":"thread/read"'*)
          if [ -f '\#(acceptedMarker.path)' ]; then
            printf '{"id":%s,"result":{"thread":{"id":"thr-lost-start","turns":[{"id":"turn-accepted","status":"completed","items":[{"id":"user-accepted","type":"userMessage","clientId":"\#(messageID.uuidString.lowercased())","content":[{"type":"text","text":"accepted before disconnect"}]},{"id":"agent-final","type":"agentMessage","phase":"final_answer","text":"Recovered accepted turn"}]}]}}}\n' "$request_id"
          else
            printf '{"id":%s,"result":{"thread":{"id":"thr-lost-start","turns":[]}}}\n' "$request_id"
          fi
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)

    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      requestTimeoutNanoseconds: 2_000_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let result = try await client.runTurn(
      threadID: "thr-lost-start",
      turnID: "local-turn",
      message: "accepted before disconnect",
      attachments: [],
      workspacePath: "~/corpus",
      corpusAccess: .runtimeFilesystem,
      attemptIdentity: CodexTurnAttemptIdentity(messageID: messageID, attemptID: messageID)
    )

    XCTAssertEqual(result.turnID, "turn-accepted")
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Recovered accepted turn")
    XCTAssertEqual(
      try String(contentsOf: turnStartCount, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "1"
    )
    await client.shutdown()
  }

  func testManagedRemoteMissingTurnIDRemainsUnknownWithoutSecondStart() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-missing-turn-id-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let startCount = temporaryDirectory.appendingPathComponent("start-count")
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id" ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/read"'*) printf '{"id":%s,"result":{"thread":{"id":"thr-missing","turns":[]}}}\n' "$request_id" ;;
        *'"method":"turn/start"'*)
          printf '1\n' > '\#(startCount.path)'
          printf '{"id":%s,"result":{"turn":{"status":"inProgress"}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    let identity = CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID())
    let recorder = CodexTurnStartRecorder()
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      requestTimeoutNanoseconds: 1_000_000_000,
      eventHandler: { event in await recorder.record(event) },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    do {
      _ = try await client.runTurn(
        threadID: "thr-missing",
        turnID: "local-turn",
        message: "accepted but malformed",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: identity
      )
      XCTFail("A missing native turn ID must remain unknown")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held unknown delivery, got \(error)")
      }
    }
    XCTAssertEqual(
      try String(contentsOf: startCount, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "1"
    )
    let starts = await recorder.starts
    XCTAssertTrue(starts.isEmpty)
    await client.shutdown()
  }

  func testManagedRemoteMalformedStartStatusDoesNotReportVerifiedStart() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-malformed-status-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let startCount = temporaryDirectory.appendingPathComponent("start-count")
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id" ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/read"'*) printf '{"id":%s,"result":{"thread":{"id":"thr-malformed","turns":[]}}}\n' "$request_id" ;;
        *'"method":"turn/start"'*)
          printf '1\n' > '\#(startCount.path)'
          printf '{"id":%s,"result":{"turn":{"id":"turn-malformed","status":"queued"}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    let recorder = CodexTurnStartRecorder()
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      requestTimeoutNanoseconds: 1_000_000_000,
      eventHandler: { event in await recorder.record(event) },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    do {
      _ = try await client.runTurn(
        threadID: "thr-malformed",
        turnID: "local-turn",
        message: "malformed status",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID())
      )
      XCTFail("An unsupported start status must remain unknown")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held unknown delivery, got \(error)")
      }
    }
    let starts = await recorder.starts
    XCTAssertTrue(starts.isEmpty)
    XCTAssertEqual(
      try String(contentsOf: startCount, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "1"
    )
    await client.shutdown()
  }

  func testManagedRemoteDelayedVisibilityPastBoundedMissNeverStartsTwice() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-delayed-visibility-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let readCount = temporaryDirectory.appendingPathComponent("read-count")
    let startCount = temporaryDirectory.appendingPathComponent("start-count")
    let attemptID = UUID()
    let identity = CodexTurnAttemptIdentity(messageID: UUID(), attemptID: attemptID)
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id" ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/read"'*)
          count=0
          if [ -f '\#(readCount.path)' ]; then count=$(/usr/bin/sed -n '1p' '\#(readCount.path)'); fi
          count=$((count + 1)); printf '%s\n' "$count" > '\#(readCount.path)'
          if [ "$count" -ge 8 ]; then
            printf '{"id":%s,"result":{"thread":{"id":"thr-delayed","turns":[{"id":"turn-delayed","status":"completed","items":[{"type":"userMessage","clientId":"\#(attemptID.uuidString.lowercased())"},{"type":"agentMessage","phase":"final_answer","text":"Visible later"}]}]}}}\n' "$request_id"
          else
            printf '{"id":%s,"result":{"thread":{"id":"thr-delayed","turns":[]}}}\n' "$request_id"
          fi
          ;;
        *'"method":"turn/start"'*)
          count=0
          if [ -f '\#(startCount.path)' ]; then count=$(/usr/bin/sed -n '1p' '\#(startCount.path)'); fi
          printf '%s\n' "$((count + 1))" > '\#(startCount.path)'
          exit 0
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      requestTimeoutNanoseconds: 1_000_000_000,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    do {
      _ = try await client.runTurn(
        threadID: "thr-delayed",
        turnID: "local-turn",
        message: "accepted but delayed",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: identity
      )
      XCTFail("The first bounded miss must stay unknown")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held unknown delivery, got \(error)")
      }
    }

    let result = try await client.runTurn(
      threadID: "thr-delayed",
      turnID: "local-reconcile",
      message: "accepted but delayed",
      attachments: [],
      workspacePath: "~/corpus",
      corpusAccess: .runtimeFilesystem,
      attemptIdentity: identity,
      turnStartPolicy: .reconcileOnly
    )
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.turnID, "turn-delayed")
    XCTAssertEqual(result.reply, "Visible later")
    XCTAssertEqual(
      try String(contentsOf: startCount, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "1"
    )
    await client.shutdown()
  }

  func testManagedRemoteUnknownNativeStatusDoesNotUnlockRetry() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-unknown-status-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let startMarker = temporaryDirectory.appendingPathComponent("turn-started")
    let attemptID = UUID()
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id" ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/read"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-unknown","turns":[{"id":"turn-unknown","status":"queued","items":[{"type":"userMessage","clientId":"\#(attemptID.uuidString.lowercased())"}]}]}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*) : > '\#(startMarker.path)' ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    do {
      _ = try await client.runTurn(
        threadID: "thr-unknown",
        turnID: "local-turn",
        message: "same held attempt",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: attemptID),
        turnStartPolicy: .reconcileOnly
      )
      XCTFail("An unsupported native status must remain unknown")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held unknown delivery, got \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: startMarker.path))
    await client.shutdown()
  }

  func testManagedRemoteThreadReadFromDifferentThreadIsNotPositiveProof() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-wrong-thread-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let startMarker = temporaryDirectory.appendingPathComponent("turn-started")
    let attemptID = UUID()
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id" ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/read"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-other","turns":[{"id":"turn-other","status":"completed","items":[{"type":"userMessage","clientId":"\#(attemptID.uuidString.lowercased())"}]}]}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*) : > '\#(startMarker.path)' ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    do {
      _ = try await client.runTurn(
        threadID: "thr-expected",
        turnID: "local-turn",
        message: "do not adopt another thread",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: attemptID),
        turnStartPolicy: .reconcileOnly
      )
      XCTFail("A matching client ID from another thread must not prove delivery")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held unknown delivery, got \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: startMarker.path))
    await client.shutdown()
  }

  func testManagedRemoteCancellationAfterKnownStartRemainsUnknown() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-cancel-after-start-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let startedMarker = temporaryDirectory.appendingPathComponent("started")
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id" ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/read"'*) printf '{"id":%s,"result":{"thread":{"id":"thr-cancel","turns":[]}}}\n' "$request_id" ;;
        *'"method":"turn/start"'*)
          : > '\#(startedMarker.path)'
          printf '{"id":%s,"result":{"turn":{"id":"turn-cancel","status":"inProgress"}}}\n' "$request_id"
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )
    let task = Task {
      try await client.runTurn(
        threadID: "thr-cancel",
        turnID: "local-turn",
        message: "cancel locally after acceptance",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(messageID: UUID(), attemptID: UUID())
      )
    }
    let deadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: startedMarker.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: startedMarker.path))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Local cancellation after native acceptance must remain unknown")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held unknown delivery, got \(error)")
      }
    }
    await client.shutdown()
  }

  func testManagedRemoteRetryReportsNativeStartForReconciledInProgressTurn() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-active-reconcile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let readCount = temporaryDirectory.appendingPathComponent("read-count")
    let turnStartMarker = temporaryDirectory.appendingPathComponent("turn-started")
    let messageID = UUID()
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/read"'*)
          count=0
          if [ -f '\#(readCount.path)' ]; then count=$(/usr/bin/sed -n '1p' '\#(readCount.path)'); fi
          count=$((count + 1))
          printf '%s\n' "$count" > '\#(readCount.path)'
          if [ "$count" -eq 1 ]; then status=inProgress; reply=''; else status=completed; reply=',{"id":"agent-final","type":"agentMessage","phase":"final_answer","text":"Attached once"}'; fi
          printf '{"id":%s,"result":{"thread":{"id":"thr-active","turns":[{"id":"turn-active","status":"%s","items":[{"id":"user-active","type":"userMessage","clientId":"\#(messageID.uuidString.lowercased())","content":[{"type":"text","text":"same active message"}]}%s]}]}}}\n' "$request_id" "$status" "$reply"
          ;;
        *'"method":"turn/start"'*)
          : > '\#(turnStartMarker.path)'
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    let recorder = CodexTurnStartRecorder()
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      requestTimeoutNanoseconds: 2_000_000_000,
      eventHandler: { event in await recorder.record(event) },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let result = try await client.runTurn(
      threadID: "thr-active",
      turnID: "local-retry",
      message: "same active message",
      attachments: [],
      workspacePath: "~/corpus",
      corpusAccess: .runtimeFilesystem,
      attemptIdentity: CodexTurnAttemptIdentity(messageID: messageID, attemptID: messageID),
      turnStartPolicy: .reconcileOnly
    )

    let starts = await recorder.starts
    XCTAssertEqual(starts.count, 1)
    XCTAssertEqual(starts.first?.threadID, "thr-active")
    XCTAssertEqual(starts.first?.turnID, "turn-active")
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Attached once")
    XCTAssertFalse(FileManager.default.fileExists(atPath: turnStartMarker.path))
    await client.shutdown()
  }

  func testManagedRemoteDefinitiveFailureAllowsOneNewAttemptIdentity() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-managed-remote-failed-reconcile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let turnStartCount = temporaryDirectory.appendingPathComponent("turn-start-count")
    let wrongAttemptMarker = temporaryDirectory.appendingPathComponent("wrong-attempt")
    let messageID = UUID()
    let priorAttemptID = messageID
    let retryAttemptID = UUID()
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*) printf '{"id":%s,"result":{"userAgent":"fake-codex"}}\n' "$request_id" ;;
        *'"method":"initialized"'*) ;;
        *'"method":"thread/read"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-failed","turns":[{"id":"turn-failed","status":"failed","error":{"message":"remote execution failed"},"items":[{"id":"user-failed","type":"userMessage","clientId":"\#(priorAttemptID.uuidString.lowercased())","content":[]}]}]}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*)
          case "$line" in *'"clientUserMessageId":"\#(retryAttemptID.uuidString.lowercased())"'*) ;; *) : > '\#(wrongAttemptMarker.path)' ;; esac
          count=0
          if [ -f '\#(turnStartCount.path)' ]; then count=$(/usr/bin/sed -n '1p' '\#(turnStartCount.path)'); fi
          printf '%s\n' "$((count + 1))" > '\#(turnStartCount.path)'
          printf '{"id":%s,"result":{"turn":{"id":"turn-retry","status":"inProgress"}}}\n' "$request_id"
          printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-failed","turn":{"id":"turn-retry","status":"inProgress","items":[]}}}'
          printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-failed","turn":{"id":"turn-retry","status":"completed","items":[{"id":"agent-final","type":"agentMessage","phase":"final_answer","text":"Retry completed"}]}}}'
          ;;
      esac
    done
    """#
    try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    let client = CodexAppServerClient(
      executableURL: nil,
      sshExecutableURL: fakeSSH,
      transport: .managedRemote(sshHost: "remote.example"),
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let result = try await client.runTurn(
      threadID: "thr-failed",
      turnID: "local-retry",
      message: "same message, authorized retry",
      attachments: [],
      workspacePath: "~/corpus",
      corpusAccess: .runtimeFilesystem,
      attemptIdentity: CodexTurnAttemptIdentity(
        messageID: messageID,
        attemptID: retryAttemptID,
        predecessorAttemptID: priorAttemptID
      ),
      turnStartPolicy: .startIfAbsent
    )
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.reply, "Retry completed")
    XCTAssertEqual(
      try String(contentsOf: turnStartCount, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "1"
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: wrongAttemptMarker.path))
    await client.shutdown()
  }

  func testClientSteersTheExpectedActiveTurn() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-steer-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-steer")
    try Self.fakeSteerAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    try await client.steer(
      threadID: "thr-steer",
      expectedTurnID: "turn-steer",
      message: "Focus on the failing test first.",
      attachments: [
        AIChatAttachment(fileName: "example.png", mimeType: "image/png", data: Data([1, 2, 3]))
      ]
    )

    await client.shutdown()
  }

  func testExternalCodexThreadParsesAsHarnessNeutralSummaryAndTranscript() throws {
    let raw: JSONValue = .object([
      "id": .string("019f-thread"),
      "name": .string("Inspect release state"),
      "preview": .string("Check the release artifacts"),
      "cwd": .string("/tmp/org2"),
      "source": .string("vscode"),
      "modelProvider": .string("openai"),
      "createdAt": .integer(100),
      "updatedAt": .integer(120),
      "status": .object(["type": .string("notLoaded")]),
      "turns": .array([
        .object([
          "startedAt": .integer(101),
          "items": .array([
            .object([
              "type": .string("userMessage"),
              "id": .string("user-1"),
              "content": .array([
                .object(["type": .string("text"), "text": .string("What shipped?")])
              ])
            ]),
            .object([
              "type": .string("commandExecution"),
              "id": .string("tool-1")
            ]),
            .object([
              "type": .string("agentMessage"),
              "id": .string("agent-1"),
              "text": .string("Version 0.4.1 shipped.")
            ])
          ])
        ])
      ])
    ])

    let summary = try XCTUnwrap(CodexAppServerClient.externalThreadSummary(raw))
    XCTAssertEqual(summary.harness, .codex)
    XCTAssertEqual(summary.externalID, "019f-thread")
    XCTAssertEqual(summary.title, "Inspect release state")
    XCTAssertEqual(summary.workspacePath, "/tmp/org2")
    XCTAssertEqual(summary.source, "vscode")
    XCTAssertEqual(summary.status, "notLoaded")

    let messages = CodexAppServerClient.externalThreadMessages(raw)
    XCTAssertEqual(messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(messages.map(\.content), ["What shipped?", "Version 0.4.1 shipped."])
  }

  func testCodexRolloutTranscriptReaderStreamsOnlyVisibleMessages() throws {
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-rollout-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: transcript) }
    let ignoredPayload = String(repeating: "internal tool output ", count: 100_000)
    let contents = [
      #"{"timestamp":"2026-08-15T12:00:00.100Z","type":"session_meta","payload":{"id":"thread"}}"#,
      #"{"timestamp":"2026-08-15T12:00:01.100Z","type":"event_msg","payload":{"type":"user_message","client_id":"user-visible","message":"What shipped?","images":[]}}"#,
      #"{"timestamp":"2026-08-15T12:00:02.200Z","type":"response_item","payload":{"type":"function_call_output","output":"\#(ignoredPayload)"}}"#,
      #"{"timestamp":"2026-08-15T12:00:03.300Z","type":"event_msg","payload":{"type":"agent_message","message":"I’m checking now.","phase":"commentary"}}"#,
      #"{"timestamp":"2026-08-15T12:00:04.400Z","type":"event_msg","payload":{"type":"agent_message","message":"Version 0.4.1 shipped.","phase":"final_answer"}}"#,
      #"{"timestamp":"2026-08-15T12:00:05.500Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Version 0.4.1 shipped."}}"#
    ].joined(separator: "\n")
    try contents.write(to: transcript, atomically: true, encoding: .utf8)

    let messages = try CodexRolloutTranscriptReader.readMessages(at: transcript)

    XCTAssertEqual(messages.map(\.role), [.user, .assistant, .assistant])
    XCTAssertEqual(
      messages.map(\.content),
      ["What shipped?", "I’m checking now.", "Version 0.4.1 shipped."]
    )
    XCTAssertEqual(messages.map(\.id), ["user-visible", "rollout-line-4", "rollout-line-5"])
    XCTAssertEqual(messages[0].createdAt.timeIntervalSince1970, 1_786_795_201.1, accuracy: 0.001)
    XCTAssertEqual(messages[1].createdAt.timeIntervalSince1970, 1_786_795_203.3, accuracy: 0.001)
    XCTAssertEqual(messages[2].createdAt.timeIntervalSince1970, 1_786_795_204.4, accuracy: 0.001)
  }

  func testCodexRolloutTranscriptReaderReadsItemCompletedMessages() throws {
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-rollout-items-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: transcript) }
    let ignoredOutput = String(repeating: "command output ", count: 100_000)
    let contents = [
      #"{"timestamp":"2026-10-01T12:00:00.100Z","ordinal":0,"type":"session_meta","payload":{"id":"thread"}}"#,
      #"{"timestamp":"2026-10-01T12:00:00.200Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
      #"{"timestamp":"2026-10-01T12:00:01.100Z","ordinal":2,"type":"event_msg","payload":{"type":"item_completed","thread_id":"thread","turn_id":"turn-1","item":{"type":"UserMessage","id":"user-item","client_id":"user-client","content":[{"type":"text","text":"What shipped?"},{"type":"image","url":"file:///tmp/screen.png"},{"type":"text","text":"Include the date."}]}}}"#,
      #"{"timestamp":"2026-10-01T12:00:02.200Z","ordinal":3,"type":"event_msg","payload":{"type":"item_completed","thread_id":"thread","turn_id":"turn-1","item":{"type":"CommandExecution","id":"cmd","aggregated_output":"\#(ignoredOutput)"}}}"#,
      #"{"timestamp":"2026-10-01T12:00:02.300Z","ordinal":4,"type":"event_msg","payload":{"type":"item_completed","thread_id":"thread","turn_id":"turn-1","item":{"type":"Reasoning","id":"reasoning","summary":[]}}}"#,
      #"{"timestamp":"2026-10-01T12:00:03.300Z","ordinal":5,"type":"event_msg","payload":{"type":"item_completed","thread_id":"thread","turn_id":"turn-1","item":{"type":"AgentMessage","id":"msg-1","content":[{"type":"Text","text":"I’m checking now."}],"phase":"commentary"}}}"#,
      #"{"timestamp":"2026-10-01T12:00:04.400Z","ordinal":6,"type":"event_msg","payload":{"type":"item_completed","thread_id":"thread","turn_id":"turn-1","item":{"type":"AgentMessage","id":"msg-2","content":[{"type":"Text","text":"Version 0.4.1 shipped on October 1."}],"phase":"final_answer"}}}"#,
      #"{"timestamp":"2026-10-01T12:00:05.500Z","ordinal":7,"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Version 0.4.1 shipped on October 1."}}"#
    ].joined(separator: "\n")
    try contents.write(to: transcript, atomically: true, encoding: .utf8)

    let messages = try CodexRolloutTranscriptReader.readMessages(at: transcript)

    XCTAssertEqual(messages.map(\.role), [.user, .assistant, .assistant])
    XCTAssertEqual(
      messages.map(\.content),
      [
        "What shipped?\n\nInclude the date.",
        "I’m checking now.",
        "Version 0.4.1 shipped on October 1."
      ]
    )
    XCTAssertEqual(messages.map(\.id), ["user-item", "msg-1", "msg-2"])
    XCTAssertEqual(messages[0].createdAt.timeIntervalSince1970, 1_790_856_001.1, accuracy: 0.001)
  }

  func testExternalThreadReadUsesTheRolloutInsteadOfMaterializingTurns() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-external-read-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let transcript = temporaryDirectory.appendingPathComponent("rollout-thr-readable.jsonl")
    try [
      #"{"timestamp":"2026-08-15T12:00:01.100Z","type":"event_msg","payload":{"type":"user_message","message":"Load this without tool history."}}"#,
      #"{"timestamp":"2026-08-15T12:00:02.200Z","type":"event_msg","payload":{"type":"agent_message","message":"Loaded.","phase":"final_answer"}}"#
    ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-external-read")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*)
          printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
          ;;
        *'"method":"initialized"'*)
          ;;
        *'"method":"thread/read"'*)
          case "$line" in
            *'"includeTurns":false'*) ;;
            *) printf '%s\n' '{"id":2,"error":{"message":"turn history must stay excluded"}}'; continue ;;
          esac
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr-readable","name":"Readable thread","source":"cli","createdAt":100,"updatedAt":120,"path":"\#(transcript.path)","turns":[]}}}'
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let detail = try await client.readExternalThread("thr-readable")

    XCTAssertEqual(detail.thread.title, "Readable thread")
    XCTAssertEqual(detail.messages.map(\.content), ["Load this without tool history.", "Loaded."])
    await client.shutdown()
  }

  func testExternalCodexThreadListingUsesRecencyAndPaginates() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-external-list-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-external-list")
    try Self.fakeExternalThreadListAppServerScript.write(
      to: executable,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let threads = try await client.listExternalThreads(limit: 3)

    XCTAssertEqual(threads.map(\.externalID), ["thr-current", "thr-recent", "thr-older"])
    await client.shutdown()
  }

  func testExternalCodexThreadSearchUsesFullHistorySearchAndSnippet() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-codex-external-search-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let executable = temporaryDirectory.appendingPathComponent("fake-codex-external-search")
    try Self.fakeExternalThreadListAppServerScript.write(
      to: executable,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let client = CodexAppServerClient(
      executableURL: executable,
      eventHandler: { _ in },
      dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
    )

    let threads = try await client.searchExternalThreads("meeting automation", limit: 5)

    XCTAssertEqual(threads.map(\.externalID), ["thr-search-result"])
    XCTAssertEqual(threads.first?.preview, "Matched text from an older transcript")
    await client.shutdown()
  }

  func testExternalThreadSnapshotUsesOrg2StructureAndReadOnlyProvenance() {
    let summary = ExternalThreadSummary(
      harness: .codex,
      externalID: "019f-thread",
      title: "Inspect release state",
      preview: nil,
      workspacePath: "/tmp/org2",
      source: "vscode",
      modelProvider: "openai",
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 120),
      status: "notLoaded",
      isPinned: false
    )
    let detail = ExternalThreadDetail(
      thread: summary,
      messages: [
        ExternalThreadMessage(
          id: "user-1",
          role: .user,
          content: "A line\n* that must stay quoted",
          createdAt: Date(timeIntervalSince1970: 101)
        )
      ]
    )

    let snapshot = WorkspaceStore.externalThreadSnapshotText(detail)
    XCTAssertTrue(snapshot.contains("* External thread: Inspect release state"))
    XCTAssertTrue(snapshot.contains(":EXTERNAL_HARNESS: codex"))
    XCTAssertTrue(snapshot.contains("read-only snapshot imported from Codex"))
    XCTAssertTrue(snapshot.contains("*** You"))
    XCTAssertTrue(snapshot.contains(": * that must stay quoted"))
    XCTAssertEqual(
      WorkspaceStore.externalThreadSnapshotRelativePath(summary),
      "views/external-threads/inspect-release-state-019f-thread.org"
    )
  }

  func testManagedRemoteBridgeDoesNotUnlockRetryFromMalformedOrConflictingTerminalIdentity() async throws {
    for mode in ["missing-id-first", "empty-id-first", "conflicting-id-first"] {
      try await assertMalformedTerminalIdentityRemainsHeld(mode: mode)
    }
  }

  private func assertMalformedTerminalIdentityRemainsHeld(mode: String) async throws {
    let temporaryDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("cgt-\(mode)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let codexHome = temporaryDirectory.appendingPathComponent("codex-home", isDirectory: true)
    let controlDirectory = codexHome.appendingPathComponent("app-server-control", isDirectory: true)
    try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
    let socketPath = controlDirectory.appendingPathComponent("app-server-control.sock")
    let countPath = temporaryDirectory.appendingPathComponent("physical-start-count")
    let acceptedPath = temporaryDirectory.appendingPathComponent("accepted-attempt")
    let daemonScript = temporaryDirectory.appendingPathComponent("fake-daemon.py")
    try Self.fakeManagedRemoteDaemonScript.write(
      to: daemonScript,
      atomically: true,
      encoding: .utf8
    )
    let daemon = Process()
    daemon.executableURL = URL(fileURLWithPath: "/usr/local/bin/python3")
    daemon.arguments = [
      daemonScript.path,
      socketPath.path,
      countPath.path,
      acceptedPath.path,
      "0",
      mode
    ]
    daemon.standardOutput = FileHandle.nullDevice
    daemon.standardError = FileHandle.nullDevice
    try daemon.run()
    defer {
      if daemon.isRunning { daemon.terminate() }
      daemon.waitUntilExit()
    }
    let socketDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: socketPath.path), Date() < socketDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard FileManager.default.fileExists(atPath: socketPath.path) else {
      return XCTFail("Fixture daemon did not create its socket for \(mode)")
    }

    let adapterScript = temporaryDirectory.appendingPathComponent("adapter.py")
    try CodexAppServerClient.managedRemoteJSONLAdapter.write(
      to: adapterScript,
      atomically: true,
      encoding: .utf8
    )
    let claimRoot = temporaryDirectory.appendingPathComponent("claims", isDirectory: true)
    let fakeSSH = temporaryDirectory.appendingPathComponent("fake-ssh")
    let launcher = #"""
    #!/bin/sh
    export CODEX_HOME='\#(codexHome.path)'
    export CELORGA_MANAGED_REMOTE_CLAIM_ROOT='\#(claimRoot.path)'
    exec /usr/local/bin/python3 '\#(adapterScript.path)'
    """#
    try launcher.write(to: fakeSSH, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
    func makeClient() -> CodexAppServerClient {
      CodexAppServerClient(
        executableURL: nil,
        sshExecutableURL: fakeSSH,
        transport: .managedRemote(sshHost: "isolated.test"),
        requestTimeoutNanoseconds: 1_000_000_000,
        eventHandler: { _ in },
        dynamicToolHandler: { _ in CodexDynamicToolResult(success: false, text: "unused") }
      )
    }

    let messageID = UUID()
    let initialIdentity = CodexTurnAttemptIdentity(messageID: messageID, attemptID: messageID)
    let initial = makeClient()
    do {
      _ = try await initial.runTurn(
        threadID: "thr-atomic",
        turnID: "local-malformed-terminal",
        message: "terminal identity must bind",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: initialIdentity
      )
      XCTFail("Malformed terminal identity must remain unconfirmed for \(mode)")
    } catch let error as CodexAppServerError {
      if mode == "conflicting-id-first" {
        guard case .turnFailed = error else {
          return XCTFail("Expected initial exact failure before conflict, got \(error)")
        }
      } else {
        guard case .turnStartUnknown = error else {
          return XCTFail("Expected malformed terminal identity to remain unknown, got \(error)")
        }
      }
    }
    await initial.shutdown()

    if mode == "conflicting-id-first" {
      let conflictReader = makeClient()
      do {
        _ = try await conflictReader.runTurn(
          threadID: "thr-atomic",
          turnID: "local-conflicting-history",
          message: "terminal identity must bind",
          attachments: [],
          workspacePath: "~/corpus",
          corpusAccess: .runtimeFilesystem,
          attemptIdentity: initialIdentity,
          turnStartPolicy: .reconcileOnly
        )
        XCTFail("Conflicting history identity must not be accepted")
      } catch let error as CodexAppServerError {
        guard case .turnStartUnknown = error else {
          return XCTFail("Expected conflicting identity to remain unknown, got \(error)")
        }
      }
      await conflictReader.shutdown()
    }

    let child = makeClient()
    do {
      _ = try await child.runTurn(
        threadID: "thr-atomic",
        turnID: "local-unauthorized-child",
        message: "terminal identity must bind",
        attachments: [],
        workspacePath: "~/corpus",
        corpusAccess: .runtimeFilesystem,
        attemptIdentity: CodexTurnAttemptIdentity(
          messageID: messageID,
          attemptID: UUID(),
          predecessorAttemptID: messageID
        )
      )
      XCTFail("Malformed terminal identity must not unlock a child for \(mode)")
    } catch let error as CodexAppServerError {
      guard case .turnStartUnknown = error else {
        return XCTFail("Expected held child for \(mode), got \(error)")
      }
    }
    await child.shutdown()
    XCTAssertEqual(
      try String(contentsOf: countPath, encoding: .utf8)
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }.count,
      1,
      mode
    )
    let journalURLs = Self.managedRemoteJournalURLs(in: claimRoot)
    XCTAssertEqual(journalURLs.count, 1, mode)
    let journalURL = try XCTUnwrap(journalURLs.first)
    let journal = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
    )
    let attempts = try XCTUnwrap(journal["attempts"] as? [String: [String: Any]])
    XCTAssertEqual(attempts[messageID.uuidString.lowercased()]?["state"] as? String, "unknown", mode)
    XCTAssertEqual(attempts.count, 1, mode)
  }

  private static func managedRemoteJournalURLs(in root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: nil
    ) else { return [] }
    return enumerator.compactMap { value in
      guard let url = value as? URL, url.lastPathComponent == "journal.json" else { return nil }
      return url
    }
  }

  static let fakeManagedRemoteDaemonScript = #"""
  import base64
  import hashlib
  import json
  import os
  import socket
  import struct
  import sys
  import threading
  import time

  socket_path, count_path, accepted_path = sys.argv[1:4]
  required_reads = int(sys.argv[4]) if len(sys.argv) > 4 else 0
  mode = sys.argv[5] if len(sys.argv) > 5 else "completed"
  fail_first = mode in (
      "fail-first",
      "missing-id-first",
      "empty-id-first",
      "conflicting-id-first",
  )
  error_first = mode == "error-first"
  missing_id_first = mode == "missing-id-first"
  empty_id_first = mode == "empty-id-first"
  conflicting_id_first = mode == "conflicting-id-first"
  drop_response_first = mode == "drop-response-first"
  try:
      os.unlink(socket_path)
  except FileNotFoundError:
      pass
  listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  listener.bind(socket_path)
  listener.listen(8)
  state_lock = threading.Lock()
  thread_read_count = 0

  def read_until(connection, marker):
      data = b""
      while marker not in data:
          chunk = connection.recv(4096)
          if not chunk:
              raise EOFError()
          data += chunk
      return data

  def read_exact(connection, count):
      data = b""
      while len(data) < count:
          chunk = connection.recv(count - len(data))
          if not chunk:
              raise EOFError()
          data += chunk
      return data

  def read_frame(connection):
      first, second = read_exact(connection, 2)
      length = second & 0x7f
      if length == 126:
          length = struct.unpack("!H", read_exact(connection, 2))[0]
      elif length == 127:
          length = struct.unpack("!Q", read_exact(connection, 8))[0]
      mask = read_exact(connection, 4) if second & 0x80 else None
      payload = read_exact(connection, length)
      if mask:
          payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
      return first & 0x0f, payload

  def send_json(connection, value):
      payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
      length = len(payload)
      if length < 126:
          header = bytes([0x81, length])
      elif length <= 0xffff:
          header = bytes([0x81, 126]) + struct.pack("!H", length)
      else:
          header = bytes([0x81, 127]) + struct.pack("!Q", length)
      connection.sendall(header + payload)

  def handle(connection):
      global thread_read_count
      try:
          header = read_until(connection, b"\r\n\r\n")
          key_line = next(
              line for line in header.split(b"\r\n")
              if line.lower().startswith(b"sec-websocket-key:")
          )
          key = key_line.split(b":", 1)[1].strip()
          accept = base64.b64encode(hashlib.sha1(
              key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
          ).digest())
          connection.sendall(
              b"HTTP/1.1 101 Switching Protocols\r\n"
              b"Upgrade: websocket\r\nConnection: Upgrade\r\n"
              b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n"
          )
          while True:
              opcode, payload = read_frame(connection)
              if opcode == 0x8:
                  return
              if opcode != 0x1:
                  continue
              request = json.loads(payload.decode("utf-8"))
              request_id = request.get("id")
              method = request.get("method")
              if method == "initialize":
                  send_json(connection, {"id": request_id, "result": {"userAgent": "fake-codex"}})
              elif method == "initialized":
                  continue
              elif method == "account/read":
                  send_json(connection, {
                      "id": request_id,
                      "result": {
                          "account": {"type": "chatgpt", "email": "fixture@example.test"},
                          "requiresOpenaiAuth": True,
                      },
                  })
              elif method in ("thread/start", "thread/resume"):
                  send_json(connection, {
                      "id": request_id,
                      "result": {"thread": {"id": "thr-atomic"}},
                  })
              elif method == "thread/read":
                  with state_lock:
                      thread_read_count += 1
                      current_read_count = thread_read_count
                  turns = []
                  if (
                      os.path.exists(accepted_path)
                      and (not drop_response_first or current_read_count > 4)
                  ):
                      with open(accepted_path, "r", encoding="utf-8") as handle:
                          accepted = json.load(handle)
                      attempt_id = accepted["attemptId"]
                      historical_turn = {
                          "status": accepted["status"],
                          "items": [
                              {"type": "userMessage", "clientId": attempt_id},
                              {"type": "agentMessage", "phase": "final_answer", "text": "Completed once"},
                          ],
                      }
                      if "nativeTurnId" in accepted:
                          historical_turn["id"] = accepted["nativeTurnId"]
                      turns = [historical_turn]
                  send_json(connection, {
                      "id": request_id,
                      "result": {"thread": {"id": "thr-atomic", "turns": turns}},
                  })
              elif method == "turn/start":
                  while True:
                      with state_lock:
                          enough_clients_reconciled = thread_read_count >= required_reads
                      if enough_clients_reconciled:
                          break
                      time.sleep(0.01)
                  attempt_id = request["params"]["clientUserMessageId"]
                  with state_lock:
                      start_count = 0
                      if os.path.exists(count_path):
                          with open(count_path, "r", encoding="utf-8") as handle:
                              start_count = len([line for line in handle if line.strip()])
                      descriptor = os.open(count_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                      try:
                          os.write(descriptor, b"start\n")
                          os.fsync(descriptor)
                      finally:
                          os.close(descriptor)
                  status = "failed" if fail_first and start_count == 0 else "completed"
                  if error_first and start_count == 0:
                      send_json(connection, {
                          "id": request_id,
                          "error": {"code": -32603, "message": "internal error after receipt"},
                      })
                      continue
                  with open(accepted_path, "w", encoding="utf-8") as handle:
                      accepted = {
                          "attemptId": attempt_id,
                          "status": status,
                      }
                      if empty_id_first and start_count == 0:
                          accepted["nativeTurnId"] = ""
                      elif not (missing_id_first and start_count == 0):
                          accepted["nativeTurnId"] = (
                              "turn-conflict"
                              if conflicting_id_first and start_count == 0
                              else "turn-atomic"
                          )
                      json.dump(accepted, handle)
                      handle.flush()
                      os.fsync(handle.fileno())
                  if drop_response_first and start_count == 0:
                      return
                  turn = {
                      "id": "turn-atomic",
                      "status": status,
                      "items": [
                          {"type": "userMessage", "clientId": attempt_id},
                          {"type": "agentMessage", "phase": "final_answer", "text": "Completed once"},
                      ],
                  }
                  if missing_id_first and start_count == 0:
                      turn.pop("id", None)
                  elif empty_id_first and start_count == 0:
                      turn["id"] = ""
                  send_json(connection, {
                      "method": "turn/started",
                      "params": {
                          "threadId": "thr-atomic",
                          "turn": {"id": "turn-unrelated", "status": "inProgress", "items": []},
                      },
                  })
                  send_json(connection, {"id": request_id, "result": {"turn": turn}})
                  send_json(connection, {
                      "method": "turn/completed",
                      "params": {"threadId": "thr-atomic", "turn": turn},
                  })
      except (EOFError, OSError, ValueError, KeyError, json.JSONDecodeError):
          return
      finally:
          connection.close()

  while True:
      connection, _ = listener.accept()
      threading.Thread(target=handle, args=(connection,), daemon=True).start()
  """#

  private static let fakeAppServerScript = #"""
  #!/bin/sh
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*)
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
        ;;
      *'"method":"initialized"'*)
        ;;
      *'"method":"account/read"'*)
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"test@example.com","planType":"plus"},"requiresOpenaiAuth":true}}'
        ;;
      *'"method":"thread/start"'*)
        case "$line" in
          *'"name":"celorga_thread_post"'*) ;;
          *) printf '%s\n' '{"id":3,"error":{"message":"background thread-post tool missing"}}'; continue ;;
        esac
        case "$line" in
          *'"sandbox":"danger-full-access"'*) ;;
          *) printf '%s\n' '{"id":3,"error":{"message":"thread sandbox missing"}}'; continue ;;
        esac
        case "$line" in
          *'"model":"gpt-test"'*) ;;
          *) printf '%s\n' '{"id":3,"error":{"message":"thread model missing"}}'; continue ;;
        esac
        printf '%s\n' '{"id":3,"result":{"thread":{"id":"thr-test"}}}'
        ;;
      *'"method":"turn/start"'*)
        case "$line" in
          *'"type":"dangerFullAccess"'*) ;;
          *) printf '%s\n' '{"id":4,"error":{"message":"turn sandbox missing"}}'; continue ;;
        esac
        case "$line" in
          *'"model":"gpt-test"'*) ;;
          *) printf '%s\n' '{"id":4,"error":{"message":"turn model missing"}}'; continue ;;
        esac
        case "$line" in
          *'"effort":"high"'*) ;;
          *) printf '%s\n' '{"id":4,"error":{"message":"turn effort missing"}}'; continue ;;
        esac
        printf '%s\n' '{"id":4,"result":{"turn":{"id":"turn-test","status":"inProgress","items":[],"error":null}}}'
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-test","turn":{"id":"turn-test","status":"inProgress","items":[],"error":null}}}'
        printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thr-test","turnId":"turn-test","itemId":"msg-test","delta":"Working…"}}'
        printf '%s\n' '{"id":"tool-request","method":"item/tool/call","params":{"callId":"call-test","threadId":"thr-test","turnId":"turn-test","tool":"org2_workspace_read","arguments":{"turnId":"local-turn","path":"notes/example.org2"}}}'
        printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr-test","turnId":"turn-test","completedAtMs":1,"item":{"type":"agentMessage","id":"msg-test","text":"Final reply","phase":"final_answer"}}}'
        printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr-test","turnId":"turn-test","completedAtMs":1,"item":{"type":"contextCompaction","id":"compact-test"}}}'
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-test","turn":{"id":"turn-test","status":"completed","items":[],"error":null}}}'
        sleep 0.05
        printf '%s\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"thr-test","turnId":"turn-test","tokenUsage":{"last":{"inputTokens":123,"cachedInputTokens":45,"outputTokens":6}}}}'
        ;;
      *'"method":"model/list"'*)
        printf '%s\n' '{"id":5,"result":{"data":[{"id":"gpt-test","model":"gpt-test","upgrade":null,"upgradeInfo":null,"availabilityNux":null,"displayName":"GPT Test","description":"Test model","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"high","description":"Thorough"}],"defaultReasoningEffort":"low","inputModalities":["text"],"supportsPersonality":false,"additionalSpeedTiers":[],"serviceTiers":[],"defaultServiceTier":null,"isDefault":true}],"nextCursor":null}}'
        ;;
    esac
  done
  """#

  private static let fakeSteerAppServerScript = #"""
  #!/bin/sh
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*)
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
        ;;
      *'"method":"initialized"'*)
        ;;
      *'"method":"turn/steer"'*)
        case "$line" in
          *'"threadId":"thr-steer"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"wrong steer target"}}'; continue ;;
        esac
        case "$line" in
          *'"expectedTurnId":"turn-steer"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"wrong expected turn"}}'; continue ;;
        esac
        case "$line" in
          *'Focus on the failing test first.'*'"type":"image"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"steer input missing"}}'; continue ;;
        esac
        printf '%s\n' '{"id":2,"result":{"turnId":"turn-steer"}}'
        ;;
    esac
  done
  """#

  private static let fakeExternalThreadListAppServerScript = #"""
  #!/bin/sh
  while IFS= read -r line; do
    case "$line" in
      *'"method":"initialize"'*)
        printf '%s\n' '{"id":1,"result":{"userAgent":"fake-codex"}}'
        ;;
      *'"method":"initialized"'*)
        ;;
      *'"method":"thread/list"'*)
        case "$line" in
          *'"sortKey":"recency_at"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"recency sort missing"}}'; continue ;;
        esac
        case "$line" in
          *'"sortDirection":"desc"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"sort direction missing"}}'; continue ;;
        esac
        case "$line" in
          *'"useStateDbOnly":true'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"state database mode missing"}}'; continue ;;
        esac
        case "$line" in
          *'"cursor":"page-2"'*)
            printf '%s\n' '{"id":3,"result":{"data":[{"id":"thr-older","name":"Older task","source":"vscode","createdAt":50,"updatedAt":100}],"nextCursor":null}}'
            ;;
          *)
            printf '%s\n' '{"id":2,"result":{"data":[{"id":"thr-current","name":"Long-running current task","source":"appServer","createdAt":1,"updatedAt":300},{"id":"thr-recent","name":"Recent task","source":"cli","createdAt":200,"updatedAt":250}],"nextCursor":"page-2"}}'
            ;;
        esac
        ;;
      *'"method":"thread/search"'*)
        case "$line" in
          *'"searchTerm":"meeting automation"'*) ;;
          *) printf '%s\n' '{"id":2,"error":{"message":"search term missing"}}'; continue ;;
        esac
        printf '%s\n' '{"id":2,"result":{"data":[{"snippet":"Matched text from an older transcript","thread":{"id":"thr-search-result","name":"Older matching task","source":"cli","createdAt":10,"updatedAt":20}}],"nextCursor":null}}'
        ;;
    esac
  done
  """#
}

private actor AIChatContextRecorder {
  private var context: AIChatWorkspaceContext?

  func record(_ context: AIChatWorkspaceContext?) {
    self.context = context
  }

  func value() -> AIChatWorkspaceContext? {
    context
  }
}

private actor OpenClawDestinationRoutingRecorder {
  private var routing: (agentID: String, sessionKey: String)?

  func record(agentID: String, sessionKey: String) {
    routing = (agentID, sessionKey)
  }

  func value() -> (agentID: String, sessionKey: String)? {
    routing
  }
}

private actor CodexTestRecorder {
  private(set) var toolCall: CodexDynamicToolCall?
  private(set) var streamedText = ""
  private(set) var contextCompactionCount = 0

  func record(_ event: CodexAppServerEvent) {
    if case .agentMessageDelta(_, _, _, let delta) = event {
      streamedText += delta
    }
    if case .contextCompacted = event {
      contextCompactionCount += 1
    }
  }

  func record(_ call: CodexDynamicToolCall) {
    toolCall = call
  }
}
