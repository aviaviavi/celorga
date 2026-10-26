import PDFKit
import XCTest
@testable import Org2WorkspaceCore

private actor SlashCommandRequestRecorder {
  private(set) var messages: [AIChatMessage] = []

  func record(_ messages: [AIChatMessage]) -> String {
    self.messages = messages
    return "Done"
  }
}

private final class SlashDiscoveryThreadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Bool] = []

  func append(_ value: Bool) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  var snapshot: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

final class AIChatSlashCommandTests: XCTestCase {
  func testParsesKnownCommandAndArguments() {
    guard case .command(let command, let arguments) = AIChatSlashCommands.parse("/search project atlas") else {
      return XCTFail("Expected a command")
    }
    XCTAssertEqual(command.name, "search")
    XCTAssertEqual(arguments, "project atlas")
  }

  func testEscapedSlashBecomesOrdinaryMessage() {
    XCTAssertEqual(AIChatSlashCommands.parse("//help"), .message("/help"))
  }

  func testUnknownCommandIsNotOrdinaryMessage() {
    XCTAssertEqual(AIChatSlashCommands.parse("/does-not-exist"), .unknown("does-not-exist"))
  }

  func testSuggestionsNarrowByPrefix() {
    XCTAssertEqual(AIChatSlashCommands.suggestions(for: "/sp").map(\.name), ["spellcheck"])
    XCTAssertTrue(AIChatSlashCommands.suggestions(for: "/search notes").isEmpty)
  }

  func testBareSlashListsCorpusSkillsFirstWithoutTruncation() {
    let skills = ["fix-openorg-items", "setup-scarf-slack-agent"].map {
      AIChatSlashCommand(
        name: $0,
        arguments: "[ARGS]",
        summary: "Corpus skill",
        systemImage: "wand.and.stars",
        isAgentAssisted: true,
        origin: .corpusSkill
      )
    }
    let gateway = [AIChatSlashCommand(name: "triage", summary: "Gateway", systemImage: "bolt", origin: .openClaw)]

    let suggestions = AIChatSlashCommands.suggestions(for: "/", gatewayCommands: gateway, corpusSkills: skills)

    // The arrow keys index into this same list, so every command, including
    // the user's own skills, must be reachable from a bare `/`.
    XCTAssertEqual(Array(suggestions.prefix(2)).map(\.name), ["fix-openorg-items", "setup-scarf-slack-agent"])
    XCTAssertEqual(suggestions.count, AIChatSlashCommands.all.count + skills.count + gateway.count)
    XCTAssertEqual(suggestions.last?.name, "triage")
    XCTAssertGreaterThan(suggestions.count, AIChatSlashCommandSuggestionsLayout.visibleRowLimit)
    // Typing still narrows in catalog order.
    XCTAssertEqual(
      AIChatSlashCommands.suggestions(for: "/fix", gatewayCommands: gateway, corpusSkills: skills).map(\.name),
      ["fix-openorg-items"]
    )
  }

  func testPublishDocumentCommandOpensTheNativePublishingSurface() {
    guard case .command(let command, let arguments) = AIChatSlashCommands.parse("/publish document") else {
      return XCTFail("Expected the publish command")
    }
    XCTAssertEqual(command.name, "publish")
    XCTAssertEqual(arguments, "document")
    XCTAssertEqual(command.arguments, "document | preview [PROJECT]")
    XCTAssertFalse(command.isAgentAssisted)
  }

  func testCatalogKeepsAgentContextInternal() {
    XCTAssertFalse(AIChatSlashCommands.all.map(\.name).contains("context"))
    XCTAssertTrue(AIChatSlashCommands.all.first(where: { $0.name == "brief" })?.isAgentAssisted == true)
    XCTAssertTrue(AIChatSlashCommands.all.first(where: { $0.name == "lint" })?.isAgentAssisted == false)
  }

  @MainActor
  func testUnknownCommandPassesThroughToOpenClaw() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-slash-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = SlashCommandRequestRecorder()
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in await recorder.record(messages) }
    )

    store.submitAIChatComposerInput(text: "/wat")
    let deadline = Date().addingTimeInterval(3)
    while store.aiChatMessages.count < 2, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(store.aiChatMessages.map(\.role), [.user, .assistant])
    XCTAssertEqual(store.aiChatMessages.first?.content, "/wat")
    XCTAssertEqual(store.aiChatMessages.last?.content, "Done")
    let requestMessages = await recorder.messages
    XCTAssertEqual(requestMessages.first?.content, "/wat")
  }

  func testGatewayCatalogDecodesCommandsAliasesAndArguments() throws {
    let data = Data(#"""
    {
      "commands": [
        {
          "name": "triage",
          "textAliases": ["/triage", "/tr"],
          "description": "Triage the current queue",
          "category": "tools",
          "source": "plugin",
          "scope": "text",
          "acceptsArgs": true,
          "args": [
            {"name": "scope", "description": "What to triage", "type": "string", "required": true},
            {"name": "limit", "description": "Maximum count", "type": "number"}
          ]
        }
      ]
    }
    """#.utf8)

    let commands = try OpenClawGatewayCommandCatalog.decode(data)
    XCTAssertEqual(commands.count, 1)
    XCTAssertEqual(commands[0].name, "triage")
    XCTAssertEqual(commands[0].aliases, ["tr"])
    XCTAssertEqual(commands[0].arguments, "<scope> [limit]")
    XCTAssertEqual(commands[0].origin, .openClaw)
    XCTAssertEqual(
      AIChatSlashCommands.suggestions(for: "/tr", gatewayCommands: commands).map(\.name),
      ["triage"]
    )
    guard case .command(let command, let arguments) = AIChatSlashCommands.parse(
      "/tr all",
      gatewayCommands: commands
    ) else {
      return XCTFail("Expected the Gateway alias to parse")
    }
    XCTAssertEqual(command.name, "triage")
    XCTAssertEqual(arguments, "all")
  }

  func testCorpusSkillCatalogLoadsInvocableSkillsForAutocomplete() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-corpus-skills-\(UUID().uuidString)", isDirectory: true)
    let skillRoot = root.appendingPathComponent(".agents/skills", isDirectory: true)
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let setupSkill = skillRoot.appendingPathComponent("setup-scarf-slack-agent", isDirectory: true)
    try FileManager.default.createDirectory(at: setupSkill, withIntermediateDirectories: true)
    try """
    ---
    name: setup-scarf-slack-agent
    description: "Set up a customer Scarf AI Slack agent channel."
    user-invocable: true
    ---
    # Setup Scarf Slack Agent
    """.write(to: setupSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    let hiddenSkill = skillRoot.appendingPathComponent("internal-maintenance", isDirectory: true)
    try FileManager.default.createDirectory(at: hiddenSkill, withIntermediateDirectories: true)
    try """
    ---
    name: internal-maintenance
    description: Internal-only maintenance.
    user-invocable: false
    ---
    """.write(to: hiddenSkill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    let skills = CorpusAgentSkillCatalog.commands(in: root)

    XCTAssertEqual(skills.map(\.name), ["setup-scarf-slack-agent"])
    XCTAssertEqual(skills.first?.origin, .corpusSkill)
    XCTAssertEqual(skills.first?.arguments, "[ARGS]")
    XCTAssertEqual(skills.first?.summary, "Set up a customer Scarf AI Slack agent channel.")
    XCTAssertEqual(
      AIChatSlashCommands.suggestions(
        for: "/setup",
        gatewayCommands: [],
        corpusSkills: skills
      ).map(\.name),
      ["setup-scarf-slack-agent"]
    )
    XCTAssertTrue(
      AIChatSlashCommands.isGatewayCommand(
        "/setup-scarf-slack-agent C123 scarf",
        gatewayCommands: [],
        corpusSkills: skills
      )
    )
    XCTAssertTrue(
      AIChatSlashCommands.helpText(
        gatewayCommands: [],
        corpusSkills: skills
      ).contains("Agent skills")
    )
    XCTAssertFalse(skills.contains(where: { $0.name == "org2" }))
  }

  @MainActor
  func testCorpusSkillDiscoveryPreparesAndRefreshesCacheOffMainActor() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-corpus-skill-cache-\(UUID().uuidString)", isDirectory: true)
    let skillRoot = root.appendingPathComponent(".agents/skills/example", isDirectory: true)
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    defer {
      CorpusAgentSkillCatalog.removeCachedCommandsForTesting()
      try? FileManager.default.removeItem(at: root)
    }
    let skillURL = skillRoot.appendingPathComponent("SKILL.md")
    try """
    ---
    name: example
    description: First description.
    ---
    """.write(to: skillURL, atomically: true, encoding: .utf8)
    CorpusAgentSkillCatalog.removeCachedCommandsForTesting()
    let threads = SlashDiscoveryThreadRecorder()

    let prepared = await CorpusAgentSkillCatalog.prepareCommands(
      in: root,
      bundledSkillURL: nil,
      force: true,
      discoveryThreadObserver: { threads.append($0) }
    )
    XCTAssertEqual(prepared.map(\.summary), ["First description."])
    XCTAssertEqual(threads.snapshot, [false])

    try """
    ---
    name: example
    description: Updated description.
    ---
    """.write(to: skillURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(
      CorpusAgentSkillCatalog.commands(in: root, bundledSkillURL: nil).map(\.summary),
      ["First description."],
      "Autocomplete must consume the prepared in-memory catalog without rereading SKILL.md"
    )

    let refreshed = await CorpusAgentSkillCatalog.prepareCommands(
      in: root,
      bundledSkillURL: nil,
      force: true
    )
    XCTAssertEqual(refreshed.map(\.summary), ["Updated description."])
  }

  func testCorpusOrg2SkillRemainsInfrastructureInsteadOfASlashCommand() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-local-skill-\(UUID().uuidString)", isDirectory: true)
    let skillRoot = root.appendingPathComponent(".agents/skills/org2", isDirectory: true)
    try FileManager.default.createDirectory(at: skillRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    ---
    name: org2
    description: User-managed Org2 guidance.
    ---
    # Local Org2

    Preserve this local guidance.
    """.write(to: skillRoot.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    let skills = CorpusAgentSkillCatalog.commands(in: root)

    XCTAssertTrue(skills.isEmpty)
    XCTAssertEqual(
      AIChatSlashCommands.parse("/org2", gatewayCommands: [], corpusSkills: skills),
      .unknown("org2")
    )
  }

  @MainActor
  func testCorpusSkillInvocationIsForwardedToTheSelectedAgent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-corpus-skill-send-\(UUID().uuidString)", isDirectory: true)
    let skill = root.appendingPathComponent(
      ".agents/skills/setup-scarf-slack-agent",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    ---
    name: setup-scarf-slack-agent
    description: Set up a customer Scarf AI Slack agent channel.
    user-invocable: true
    ---
    """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let recorder = SlashCommandRequestRecorder()
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in await recorder.record(messages) }
    )
    store.setCorpusRoot(root, persistsDefault: false)
    await store.waitForCorpusAgentSkillRefreshForTesting()

    store.submitAIChatComposerInput(text: "/setup-scarf-slack-agent C123 scarf")
    let deadline = Date().addingTimeInterval(3)
    while store.aiChatMessages.count < 2, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(store.corpusAgentSkillCommands.map(\.name), ["setup-scarf-slack-agent"])
    XCTAssertEqual(store.aiChatMessages.first?.content, "/setup-scarf-slack-agent C123 scarf")
    let request = await recorder.messages
    XCTAssertTrue(request.first?.content.hasPrefix("/setup-scarf-slack-agent C123 scarf") == true)
    XCTAssertTrue(request.first?.content.contains("<org2-agent-skill name=\"setup-scarf-slack-agent\">") == true)
  }

  func testUnknownSlashCommandRequiresTheGatewayButEscapedSlashDoesNot() {
    XCTAssertTrue(AIChatSlashCommands.isGatewayCommand("/new-plugin-command", gatewayCommands: []))
    XCTAssertFalse(AIChatSlashCommands.isGatewayCommand("//new-plugin-command", gatewayCommands: []))
    XCTAssertFalse(AIChatSlashCommands.isGatewayCommand("/agenda", gatewayCommands: []))
  }

  func testGatewaySlashCommandSkipsWorkspaceContextEnvelope() {
    let context = AIChatWorkspaceContext(
      localCorpusRoot: "/tmp/org2",
      remoteCorpusRoot: "/workspace/org2",
      selectedSurface: "OpenClaw Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )

    XCTAssertEqual(
      WorkspaceStore.openClawGatewayMessage(
        userMessage: "/triage all",
        workspaceContext: context,
        isGatewayCommand: true
      ),
      "/triage all"
    )
    let wrappedMessage = WorkspaceStore.openClawGatewayMessage(
      userMessage: "Summarize this",
      workspaceContext: context,
      isGatewayCommand: false
    )
    XCTAssertTrue(wrappedMessage.hasPrefix("<org2-workspace-context>"))
    XCTAssertTrue(wrappedMessage.contains("Celorga response formatting contract"))
    XCTAssertTrue(wrappedMessage.contains("Celorga agent operating guidance"))
    XCTAssertTrue(wrappedMessage.contains("celorga agent capabilities"))
    XCTAssertTrue(wrappedMessage.contains("as application instructions"))
    XCTAssertTrue(wrappedMessage.contains("|-------+--------------|"))
  }

  @MainActor
  func testAgentCommandKeepsInvocationInTranscriptAndExpandsRequest() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-agent-slash-command-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = SlashCommandRequestRecorder()
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in await recorder.record(messages) }
    )

    store.submitAIChatComposerInput(text: "/brief")
    let deadline = Date().addingTimeInterval(3)
    while store.aiChatMessages.count < 2, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(store.aiChatMessages.first?.content, "/brief")
    let request = await recorder.messages
    XCTAssertEqual(request.first?.content.hasPrefix("/brief\n\nCreate a concise, cited brief"), true)
  }

  @MainActor
  func testPDFExporterProducesPDFData() async throws {
    let data = try await Org2PDFExporter().data(
      for: """
      <html><head></head><body>
      <details class="org2-properties-drawer" open><summary>Properties</summary><p>PRIVATE_METADATA</p></details>
      <h1>Org2 export <button class="org2-heading-ai-action">Ask AI</button></h1>
      <p>Plain text stays canonical.</p>
      </body></html>
      """,
      baseURL: nil
    )
    XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
    let text = try XCTUnwrap(PDFDocument(data: data)?.string)
    XCTAssertTrue(text.contains("Plain text stays canonical."))
    XCTAssertFalse(text.contains("PRIVATE_METADATA"))
    XCTAssertFalse(text.contains("Ask AI"))
  }

  func testPDFExporterAddsCleanDocumentStyleAfterAppStyles() throws {
    let prepared = Org2PDFExporter.preparedHTML(
      for: "<html><head><style>.org2-drawer { display: block; }</style></head><body>Document</body></html>"
    )

    XCTAssertTrue(prepared.contains(#"id="org2-pdf-document-style""#))
    XCTAssertTrue(prepared.contains(".org2-properties-drawer"))
    XCTAssertTrue(prepared.contains(".org2-heading-ai-action"))
    XCTAssertTrue(prepared.contains(".org2-table-controls"))
    XCTAssertTrue(prepared.contains(".org2-table-sort-button"))
    XCTAssertTrue(prepared.contains("display: none !important"))
    XCTAssertLessThan(
      try XCTUnwrap(prepared.range(of: ".org2-drawer { display: block; }")?.lowerBound),
      try XCTUnwrap(prepared.range(of: #"id="org2-pdf-document-style""#)?.lowerBound)
    )
  }

  func testPDFExporterRejectsNonPDFData() {
    XCTAssertThrowsError(try Org2PDFExporter.validated(Data("not a PDF".utf8))) { error in
      XCTAssertEqual(error as? Org2PDFExporterError, .invalidPDF)
    }
  }
}
