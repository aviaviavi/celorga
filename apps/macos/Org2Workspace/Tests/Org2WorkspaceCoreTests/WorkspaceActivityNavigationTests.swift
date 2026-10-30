import CoreGraphics
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceActivityNavigationTests: XCTestCase {
  // MARK: Local usage log

  func testUsageLogIsOffByDefaultAndWritesNothing() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let url = temporaryLogURL()
    let log = OpenOrgUsageLog(defaults: defaults, fileURL: url)

    XCTAssertFalse(log.isEnabled)
    log.record(.documentOpen, ["source": "quick_open"])
    log.flush()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testUsageLogAppendsStructuralJSONLinesWithHashedPaths() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let url = temporaryLogURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let log = OpenOrgUsageLog(defaults: defaults, fileURL: url, now: { Date(timeIntervalSince1970: 1_800_000_000) })

    log.isEnabled = true
    XCTAssertTrue(OpenOrgUsageLog(defaults: defaults, fileURL: url).isEnabled, "the opt-in persists")
    let token = log.pathToken("notes/secret-project.org")
    log.record(.documentOpen, ["source": "link", "file": token, "same_file": false])
    log.flush()

    let lines = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    XCTAssertEqual(lines.map { $0["event"] as? String }, ["session_start", "document_open"])
    let open = try XCTUnwrap(lines.last)
    XCTAssertEqual(open["source"] as? String, "link")
    XCTAssertEqual(open["v"] as? Int, 1)
    XCTAssertNotNil(open["session"])
    let hashed = try XCTUnwrap(open["file"] as? String)
    XCTAssertEqual(hashed.count, 12)
    XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("secret-project"))
    XCTAssertEqual(log.pathToken("notes/secret-project.org"), token, "tokens are stable for revisits")

    log.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testUsageLogTokensDependOnThePerInstallSalt() {
    XCTAssertNotEqual(
      OpenOrgUsageLog.token("notes/a.org", salt: "one"),
      OpenOrgUsageLog.token("notes/a.org", salt: "two")
    )
  }

  // MARK: Frecency

  func testFrecencyRanksRecentAndFrequentFilesAndCollapsesReopens() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var frecency = WorkspaceFileFrecency()
    frecency.recordVisit("old.org", at: now.addingTimeInterval(-40 * 24 * 3600))
    frecency.recordVisit("daily.org", at: now.addingTimeInterval(-3 * 24 * 3600))
    frecency.recordVisit("daily.org", at: now.addingTimeInterval(-2 * 24 * 3600))
    frecency.recordVisit("daily.org", at: now.addingTimeInterval(-1 * 24 * 3600 - 60))
    frecency.recordVisit("fresh.org", at: now.addingTimeInterval(-60))
    frecency.recordVisit("fresh.org", at: now.addingTimeInterval(-58))

    XCTAssertEqual(frecency.visitsByPath["fresh.org"]?.count, 1, "re-opens within seconds are one visit")
    XCTAssertEqual(frecency.ranked(now: now).map(\.path), ["daily.org", "fresh.org", "old.org"])
    XCTAssertEqual(frecency.score("missing.org", now: now), 0)
    XCTAssertEqual(WorkspaceFileFrecency.quickOpenBonus(0), 0)
    XCTAssertEqual(WorkspaceFileFrecency.quickOpenBonus(10_000), 45)

    frecency.rename(from: "fresh.org", to: "renamed.org")
    XCTAssertNil(frecency.visitsByPath["fresh.org"])
    XCTAssertGreaterThan(frecency.score("renamed.org", now: now), 0)
  }

  func testQuickOpenListsRecentFilesFirstAndBoostsThemInSearch() async throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = try temporaryCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    store.corpusRoot = root
    store.corpusFiles = [
      CorpusFile(path: root.appendingPathComponent("alpha-plan.org").path, relativePath: "alpha-plan.org", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: root.appendingPathComponent("notes/plan.org").path, relativePath: "notes/plan.org", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: root.appendingPathComponent("zeta.org").path, relativePath: "zeta.org", modifiedAt: nil, byteCount: nil),
    ]
    store.recordFileVisit(relativePath: "zeta.org")

    store.presentQuickOpen()
    try await waitForCondition { store.quickOpenFiles.first?.relativePath == "zeta.org" }
    XCTAssertEqual(store.quickOpenFiles.map(\.relativePath), ["zeta.org", "alpha-plan.org", "notes/plan.org"])
    XCTAssertTrue(store.isRecentCorpusFile(store.quickOpenFiles[0]))

    // Without history "alpha-plan.org" and "notes/plan.org" tie closely; a
    // visited file wins the tie.
    store.recordFileVisit(relativePath: "notes/plan.org")
    store.quickOpenQuery = "plan"
    try await waitForCondition { !store.isFilteringQuickOpenFiles && !store.quickOpenFiles.isEmpty }
    XCTAssertEqual(store.quickOpenFiles.first?.relativePath, "notes/plan.org")

    // Frecency is per corpus.
    let otherRoot = try temporaryCorpus()
    defer { try? FileManager.default.removeItem(at: otherRoot) }
    store.corpusRoot = otherRoot
    XCTAssertEqual(store.fileFrecencyScore(relativePath: "notes/plan.org"), 0)
  }

  // MARK: Back / forward

  func testForwardHistoryReplaysBackAndClearsOnNewNavigation() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])

    store.selectedSurface = .agenda
    store.makeSurfacePrimary(.files)
    store.makeSurfacePrimary(.meetings)
    XCTAssertFalse(store.canNavigateForward)

    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.canNavigateForward)
    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .agenda)

    store.navigateForward()
    XCTAssertEqual(store.selectedSurface, .files)
    store.navigateForward()
    XCTAssertEqual(store.selectedSurface, .meetings)
    XCTAssertFalse(store.canNavigateForward)

    store.navigateBack()
    XCTAssertTrue(store.canNavigateForward)
    store.makeSurfacePrimary(.sources)
    XCTAssertFalse(store.canNavigateForward, "a new destination discards the forward branch")
    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .files)
  }

  func testForwardHistoryIsPerTab() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    let firstTab = store.selectedWorkspaceTabID
    store.selectedSurface = .agenda
    store.makeSurfacePrimary(.files)
    store.navigateBack()
    XCTAssertTrue(store.canNavigateForward)

    let secondTab = store.newWorkspaceTab()
    XCTAssertFalse(store.canNavigateForward)
    store.selectWorkspaceTab(firstTab)
    XCTAssertTrue(store.canNavigateForward)
    store.navigateForward()
    XCTAssertEqual(store.selectedSurface, .files)
    store.selectWorkspaceTab(secondTab)
    XCTAssertFalse(store.canNavigateForward)
  }

  // MARK: Link hover preview

  func testLinkPreviewExcerptsAHeadingBodyWithoutDrawersOrPlanning() {
    let text = """
    #+title: Project notes
    * TODO [#A] Ship the map :work:
    SCHEDULED: <2026-10-05 Mon>
    :PROPERTIES:
    :ID: abc
    :END:
    First line of context.

    Second paragraph.
    ** Sub task
    * Next heading
    Not included.
    """
    let preview = OrgLinkHoverPreview.make(text: text, line: 2, fileName: "notes", relativePath: "projects/notes.org")
    XCTAssertEqual(preview.title, "Ship the map")
    XCTAssertEqual(preview.location, "projects/notes.org:2")
    XCTAssertEqual(preview.excerpt, "First line of context.\n\nSecond paragraph.\n• Sub task")
    XCTAssertFalse(preview.excerpt.contains("Not included"))
    XCTAssertFalse(preview.excerpt.contains(":ID:"))

    let filePreview = OrgLinkHoverPreview.make(text: text, line: nil, fileName: "notes", relativePath: "projects/notes.org")
    XCTAssertEqual(filePreview.title, "Project notes")
    XCTAssertEqual(filePreview.location, "projects/notes.org")
  }

  func testLinkPreviewForWebLinksUsesTheKnownDescriptionWithoutFetching() throws {
    let described = try XCTUnwrap(OrgLinkHoverPreview.external(url: "https://www.example.com/guide", label: "  The\n field guide "))
    XCTAssertEqual(described.title, "The field guide")
    XCTAssertEqual(described.location, "https://www.example.com/guide")
    XCTAssertTrue(described.excerpt.contains("example.com"))
    XCTAssertTrue(described.excerpt.contains("doesn't load the page"))

    let bare = try XCTUnwrap(OrgLinkHoverPreview.external(url: "https://example.org/a/", label: "https://example.org/a"))
    XCTAssertEqual(bare.title, "example.org")
    XCTAssertEqual(try XCTUnwrap(OrgLinkHoverPreview.external(url: "http://example.net", label: nil)).title, "example.net")

    XCTAssertNil(OrgLinkHoverPreview.external(url: "id:abc-123", label: "Note"))
    XCTAssertNil(OrgLinkHoverPreview.external(url: "file:notes.org::*Plan", label: nil))
    XCTAssertNil(OrgLinkHoverPreview.external(url: "mailto:someone@example.com", label: nil))
  }

  func testLinkPreviewCacheReusesUnchangedFilesAndRefreshesEditedOnes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.org")
    try "* Plan\nFirst draft.\n".write(to: file, atomically: true, encoding: .utf8)
    let cache = OrgLinkHoverPreview.Cache(capacity: 2)

    let first = await OrgLinkHoverPreview.load(path: file.path, line: 1, relativePath: "notes.org", cache: cache)
    XCTAssertEqual(first?.excerpt, "First draft.")
    XCTAssertEqual(cache.count, 1)
    let again = await OrgLinkHoverPreview.load(path: file.path, line: 1, relativePath: "notes.org", cache: cache)
    XCTAssertEqual(again, first)
    XCTAssertEqual(cache.count, 1)

    try "* Plan\nSecond, longer draft.\n".write(to: file, atomically: true, encoding: .utf8)
    let edited = await OrgLinkHoverPreview.load(path: file.path, line: 1, relativePath: "notes.org", cache: cache)
    XCTAssertEqual(edited?.excerpt, "Second, longer draft.")

    let preview = OrgLinkHoverPreview(title: "t", location: "l", excerpt: "x")
    let revision = OrgLinkHoverPreview.Cache.Revision(size: 1, modified: nil)
    cache.store(preview, for: .init(path: "/a", line: nil, relativePath: "a"), revision: revision)
    cache.store(preview, for: .init(path: "/b", line: nil, relativePath: "b"), revision: revision)
    XCTAssertEqual(cache.count, 2, "least recently used entry is evicted at capacity")
    XCTAssertNil(cache.preview(for: .init(path: file.standardizedFileURL.path, line: 1, relativePath: "notes.org"), revision: revision))
    XCTAssertEqual(cache.preview(for: .init(path: "/b", line: nil, relativePath: "b"), revision: revision), preview)
    XCTAssertNil(cache.preview(for: .init(path: "/b", line: nil, relativePath: "b"), revision: .init(size: 2, modified: nil)))
  }

  func testLinkPreviewPayloadIsJSONEscaped() throws {
    let preview = OrgLinkHoverPreview(title: "A \"quoted\" </script>", location: "a.org", excerpt: "x\ny")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.scriptPayload.utf8)) as? [String: String])
    XCTAssertEqual(object["title"], "A \"quoted\" </script>")
    XCTAssertEqual(object["excerpt"], "x\ny")
  }

  // MARK: Heading work

  func testHeadingWorkLinksReadIDsRunsAndAgentRefs() {
    let text = """
    * TODO Write the report
    SCHEDULED: <2026-10-05 Mon>
    :PROPERTIES:
    :ID: heading-1
    :ORG2_RUN_ID: run-1
    :AGENT_REF: research
    :END:
    Body
    ** DONE Old step
    * Plain heading
    """
    let links = HeadingWorkStatus.links(in: text, baseLine: 10)
    XCTAssertEqual(links.map(\.line), [10, 18, 19])
    XCTAssertEqual(links[0], HeadingWorkLink(line: 10, todo: "TODO", idValue: "heading-1", runID: "run-1", agentRef: "research", goalRef: nil))
    XCTAssertEqual(links[1].todo, "DONE")
    XCTAssertNil(links[2].todo)
    XCTAssertNil(links[2].runID)
  }

  func testHeadingWorkStateFollowsRunAndThread() throws {
    let threadID = UUID()
    let link = HeadingWorkLink(line: 4, todo: "IN_PROGRESS", idValue: "h1", runID: "run-1")
    func badge(status: String, running: Bool, approvals: Bool = false) throws -> HeadingWorkState? {
      let run = try makeRun(id: "run-1", status: status, pendingApproval: approvals)
      return HeadingWorkStatus.badges(
        links: [link],
        runsByID: ["run-1": run],
        resourceThreadIDsByKey: ["id:h1": threadID],
        isThreadRunning: { _ in running }
      ).first?.state
    }
    XCTAssertEqual(try badge(status: "running", running: true), .working)
    XCTAssertEqual(try badge(status: "running", running: false), .yourTurn)
    XCTAssertEqual(try badge(status: "running", running: false, approvals: true), .needsYou)
    XCTAssertEqual(try badge(status: "blocked", running: false), .needsYou)
    XCTAssertEqual(try badge(status: "queued", running: false), .queued)
    XCTAssertEqual(try badge(status: "failed", running: false), .failed)
    XCTAssertEqual(try badge(status: "completed", running: false), .done)
    XCTAssertNil(try badge(status: "canceled", running: false))

    // A heading with only a live resource thread shows Working; idle shows nothing.
    let unlinked = HeadingWorkLink(line: 1, todo: "TODO", idValue: "h1", runID: nil)
    XCTAssertEqual(HeadingWorkStatus.badges(links: [unlinked], runsByID: [:], resourceThreadIDsByKey: ["id:h1": threadID], isThreadRunning: { _ in true }).first?.state, .working)
    XCTAssertTrue(HeadingWorkStatus.badges(links: [unlinked], runsByID: [:], resourceThreadIDsByKey: ["id:h1": threadID], isThreadRunning: { _ in false }).isEmpty)
  }

  func testStartWorkPromptCitesTheRunAndOnlyMentionsCLIForToolRuntimes() {
    let prompt = HeadingWorkStatus.startWorkPrompt(title: "Ship it", reference: "notes/a.org:3", runID: "run-9", keepsCLIInstructions: true)
    XCTAssertTrue(prompt.contains("Task: Ship it"))
    XCTAssertTrue(prompt.contains("Source: notes/a.org:3"))
    XCTAssertTrue(prompt.contains("celorga run complete run-9"))
    XCTAssertFalse(HeadingWorkStatus.startWorkPrompt(title: "Ship it", reference: "x", runID: "run-9", keepsCLIInstructions: false).contains("celorga run"))
  }

  func testStartWorkMessageShowsAsCompactCardWithTheFullPromptFolded() {
    let prompt = "Use selected page “Ship it” at /corpus/notes/a.org:3 as context.\n\n"
      + HeadingWorkStatus.startWorkPrompt(
        title: "Ship it", reference: "/corpus/notes/a.org:3", runID: "run-9", keepsCLIInstructions: true
      )
    XCTAssertEqual(
      HeadingWorkStatus.startWorkPromptSummary(in: prompt),
      StartWorkPromptSummary(title: "Ship it", source: "/corpus/notes/a.org:3", runID: "run-9")
    )
    XCTAssertNil(HeadingWorkStatus.startWorkPromptSummary(in: "Task: Ship it\nSource: notes/a.org:3"))

    let card = AIChatTranscriptHTML.StartWork(
      AIChatMessage(role: .user, content: prompt),
      corpusRoot: URL(fileURLWithPath: "/corpus")
    )
    XCTAssertEqual(card?.title, "Ship it")
    XCTAssertEqual(card?.source, "notes/a.org:3")
    XCTAssertNil(AIChatTranscriptHTML.StartWork(AIChatMessage(role: .assistant, content: prompt), corpusRoot: nil))

    XCTAssertTrue(AIChatTranscriptHTML.script.contains("e.startWork ? startWorkCard(e, messageBody) : messageBody"))
    XCTAssertTrue(AIChatTranscriptHTML.script.contains("'Show prompt'"))
    XCTAssertTrue(AIChatTranscriptHTML.style.contains(".start-work-card"))
  }

  func testStoreDerivesHeadingBadgesFromLoadedRuns() async throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    store.replaceAgentRunsForTesting([try makeRun(id: "run-1", status: "completed")])
    let source = EntrySource(
      file: "/tmp/work.org",
      startLine: 1,
      endLineExclusive: 6,
      text: "* DONE Task\n:PROPERTIES:\n:ORG2_RUN_ID: run-1\n:END:\n* TODO Other",
      isSubtree: false
    )
    try await waitForCondition { !store.headingWorkBadges(for: source).isEmpty }
    XCTAssertEqual(store.headingWorkBadges(for: source), [HeadingWorkBadge(line: 1, state: .done, runID: "run-1", threadID: nil)])
    XCTAssertEqual(store.headingWorkState(properties: ["ORG2_RUN_ID": "run-1"])?.state, .done)
    XCTAssertNil(store.headingWorkState(properties: [:]))

    let payload = OrgHTMLHeadingWorkScript.badgesPayload(store.headingWorkBadges(for: source))
    let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
    XCTAssertEqual(decoded.first?["state"] as? String, "done")
    XCTAssertEqual(decoded.first?["line"] as? Int, 1)
  }

  func testStartWorkCreatesARunLinksTheHeadingAndOpensItsThread() async throws {
    let root = try temporaryCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let file = root.appendingPathComponent("tasks.org")
    try "#+title: Tasks\n\n* TODO Draft the launch email\nNotes for the draft.\n* TODO Another task\n"
      .write(to: file, atomically: true, encoding: .utf8)
    let sentPrompts = SentPromptRecorder()
    let store = WorkspaceStore(
      cli: try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chats.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await sentPrompts.append(messages.last(where: { $0.role == .user })?.content ?? "")
        return "Drafted the email under the heading."
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    // The send handler stands in for the OpenClaw Gateway destination, which
    // this user chose as the default for new agent work.
    store.defaultRunDestinationID = AIChatDestinationConfiguration.openClawID
    let location = WorkspaceLocation.aiChatThreadRecord(AIChatThreadRecord(
      title: "Draft the launch email",
      file: file.path,
      line: 3,
      zone: "entry",
      modifiedAt: nil
    ))

    await store.startWork(on: location, origin: "test")

    let text = try String(contentsOf: file, encoding: .utf8)
    let link = try XCTUnwrap(HeadingWorkStatus.links(in: text, baseLine: 1).first { $0.line == 3 })
    let runID = try XCTUnwrap(link.runID, "the heading links its run")
    let idValue = try XCTUnwrap(link.idValue, "an :ID: is added for the canonical thread")
    XCTAssertTrue(text.contains("Notes for the draft."))
    XCTAssertTrue(text.contains("* TODO Another task\n"), "other headings are untouched")
    let run = try XCTUnwrap(store.agentRuns.first { $0.id == runID })
    XCTAssertEqual(run.status, "running")
    XCTAssertEqual(run.context.first?.fileReference, "tasks.org:3")
    XCTAssertEqual(WorkspaceStore.activityThreadID(in: run).map { _ in true }, true)
    let thread = try XCTUnwrap(store.aiChatThreads.first { $0.resource?.key == "id:\(idValue)" })
    XCTAssertEqual(store.selectedAIChatThreadID, thread.id)
    XCTAssertEqual(store.selectedSurface, .aiChat)

    try await waitForCondition(timeout: 8) { !store.isAIChatThreadRunning(thread.id) && !store.aiChatThreads.isEmpty }
    let prompts = await sentPrompts.values
    XCTAssertTrue(prompts.contains { $0.contains("Durable run: \(runID)") && $0.contains("Draft the launch email") })
    let source = EntrySource(file: file.path, startLine: 1, endLineExclusive: 20, text: try String(contentsOf: file, encoding: .utf8), isSubtree: false)
    try await waitForCondition(timeout: 4) { store.headingWorkBadges(for: source).first?.state == .yourTurn }

    // Starting again resumes the open run instead of creating another.
    let runCount = store.agentRuns.count
    await store.startWork(on: location, origin: "test")
    XCTAssertEqual(store.agentRuns.count, runCount)
    XCTAssertEqual(HeadingWorkStatus.links(in: try String(contentsOf: file, encoding: .utf8), baseLine: 1).first { $0.line == 3 }?.runID, runID)
  }

  func testStartWorkAsksWhereAndCanUseTheCurrentThreadWithChosenSettings() async throws {
    let root = try temporaryCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let file = root.appendingPathComponent("tasks.org")
    try "#+title: Tasks\n\n* TODO Draft the launch email\n* DONE Shipped already\n"
      .write(to: file, atomically: true, encoding: .utf8)
    let sentPrompts = SentPromptRecorder()
    let store = WorkspaceStore(
      cli: try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chats.json"),
      aiChatSendHandler: { messages, _, _, _ in
        await sentPrompts.append(messages.last(where: { $0.role == .user })?.content ?? "")
        return "On it."
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let currentID = store.createAIChatThread(destinationID: AIChatDestinationConfiguration.openClawID)
    store.selectAIChatThread(currentID)
    func location(_ title: String, line: Int) -> WorkspaceLocation {
      .aiChatThreadRecord(AIChatThreadRecord(title: title, file: file.path, line: line, zone: "entry", modifiedAt: nil))
    }

    // A closed task never opens the dialog.
    store.requestStartWork(on: location("Shipped already", line: 4), origin: "test")
    XCTAssertNil(store.pendingStartWorkRequest)

    // An open task asks where to start, offering the current thread.
    store.requestStartWork(on: location("Draft the launch email", line: 3), origin: "test")
    let request = try XCTUnwrap(store.pendingStartWorkRequest)
    XCTAssertEqual(request.title, "Draft the launch email")
    XCTAssertEqual(request.currentThreadID, currentID)
    XCTAssertNil(request.taskThreadID)
    XCTAssertTrue(store.agentRuns.isEmpty, "nothing starts until the dialog is confirmed")

    let options = StartWorkOptions(model: "test-model", reasoningEffort: "high")
    await store.startWork(
      on: request.location,
      origin: request.origin,
      options: options,
      threadTarget: .currentThread(currentID)
    )

    let thread = try XCTUnwrap(store.aiChatThreads.first { $0.id == currentID })
    XCTAssertEqual(thread.model, "test-model")
    XCTAssertEqual(thread.reasoningEffort, "high")
    XCTAssertNil(thread.resource, "the current thread is reused, not replaced")
    XCTAssertEqual(store.aiChatThreads.filter { $0.title.hasPrefix("Work:") }.count, 0)
    XCTAssertEqual(store.selectedAIChatThreadID, currentID)
    let text = try String(contentsOf: file, encoding: .utf8)
    let runID = try XCTUnwrap(HeadingWorkStatus.links(in: text, baseLine: 1).first { $0.line == 3 }?.runID)
    try await waitForCondition(timeout: 8) { !store.isAIChatThreadRunning(currentID) }
    let prompts = await sentPrompts.values
    XCTAssertTrue(prompts.contains { $0.contains("Durable run: \(runID)") })

    // The heading's badge follows the run to the chat it was started in.
    let source = EntrySource(file: file.path, startLine: 1, endLineExclusive: 10, text: text, isSubtree: false)
    try await waitForCondition(timeout: 4) { store.headingWorkBadges(for: source).first?.threadID == currentID }

    // Choosing a new thread remembers the settings for next time.
    store.confirmStartWork(request, options: options, threadTarget: .newThread)
    XCTAssertNil(store.pendingStartWorkRequest)
    XCTAssertEqual(store.startWorkLastOptions.model, "test-model")
  }

  // MARK: Activity model and map

  func testActivitySnapshotGroupsRunsApprovalsAndRecentFiles() async throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = try temporaryCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    store.corpusRoot = root
    let now = Date()
    store.corpusFiles = [
      CorpusFile(path: root.appendingPathComponent("projects/map.org").path, relativePath: "projects/map.org", modifiedAt: now.addingTimeInterval(-60), byteCount: nil),
      CorpusFile(path: root.appendingPathComponent("notes/old.org").path, relativePath: "notes/old.org", modifiedAt: now.addingTimeInterval(-10 * 24 * 3600), byteCount: nil),
    ]
    store.replaceAgentRunsForTesting([
      try makeRun(id: "running", status: "running", contextRefs: ["projects/map.org:4"]),
      try makeRun(id: "blocked", status: "blocked", contextRefs: [root.appendingPathComponent("notes/old.org").path], blockedReason: "Which customer?"),
      try makeRun(id: "done", status: "completed"),
    ])
    try await waitForCondition { store.activitySnapshot().working.count == 1 }

    let snapshot = store.activitySnapshot(now: now)
    XCTAssertEqual(snapshot.working.map(\.id), ["run:running"])
    XCTAssertEqual(snapshot.working.first?.relativePath, "projects/map.org")
    XCTAssertEqual(snapshot.needsYou.map(\.id), ["run:blocked"])
    XCTAssertEqual(snapshot.needsYou.first?.detail, "Blocked: Which customer?")
    XCTAssertEqual(snapshot.needsYou.first?.relativePath, "notes/old.org")
    XCTAssertEqual(snapshot.changed.map(\.relativePath), ["projects/map.org"])

    let areas = store.activityMapAreas(prefix: "", snapshot: snapshot, now: now)
    let projects = try XCTUnwrap(areas.first { $0.path == "projects" })
    XCTAssertEqual(projects.working, 1)
    XCTAssertEqual(projects.changedRecently, 1)
    let notes = try XCTUnwrap(areas.first { $0.path == "notes" })
    XCTAssertEqual(notes.needsYou, 1)

    let zoomed = store.activityMapAreas(prefix: "projects", snapshot: snapshot, now: now)
    XCTAssertEqual(zoomed.map(\.path), ["projects/map.org"])
    XCTAssertTrue(zoomed[0].isFile)
  }

  func testActivitySnapshotHidesStaleRunsGroupsApprovalsAndSkipsMachineFiles() async throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = try temporaryCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    store.corpusRoot = root
    let now = Date()
    let day: TimeInterval = 24 * 3600
    store.corpusFiles = [
      CorpusFile(path: root.appendingPathComponent("notes/today.org").path, relativePath: "notes/today.org", modifiedAt: now.addingTimeInterval(-60), byteCount: nil),
      CorpusFile(path: root.appendingPathComponent(".org2/runs/r.org2").path, relativePath: ".org2/runs/r.org2", modifiedAt: now.addingTimeInterval(-30), byteCount: nil),
    ]
    store.replaceAgentRunsForTesting([
      try makeRun(id: "fresh-running", status: "running", updatedAt: now.addingTimeInterval(-3600)),
      try makeRun(id: "stale-running", status: "running", updatedAt: now.addingTimeInterval(-30 * day)),
      try makeRun(id: "stale-queued", status: "queued", updatedAt: now.addingTimeInterval(-2 * day)),
      try makeRun(id: "fresh-blocked", status: "blocked", blockedReason: "Pick one", updatedAt: now.addingTimeInterval(-2 * day)),
      try makeRun(id: "stale-blocked", status: "blocked", updatedAt: now.addingTimeInterval(-20 * day)),
      try makeRun(id: "fresh-failed", status: "failed", updatedAt: now.addingTimeInterval(-day)),
      try makeRun(id: "stale-failed", status: "failed", updatedAt: now.addingTimeInterval(-10 * day)),
      try makeRun(id: "scout", status: "waiting-approval", updatedAt: now.addingTimeInterval(-40 * day)),
    ])
    let requested = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
    store.replaceApprovalItemsForTesting(["Acme / a@acme.com", "Beta / b@beta.dev", "Gamma / c@gamma.io"].map { lead in
      ApprovalItem(
        title: "Example Reviewer review: \(lead)", status: "pending", todo: nil, level: nil,
        file: root.appendingPathComponent(".org2/runs/scout.org2").path, line: 1, idValue: nil,
        properties: [:], body: "", tags: [], approvalId: "approval-\(lead)",
        requestedAt: requested, runId: "scout"
      )
    } + [
      ApprovalItem(
        title: "Send renewal follow-up", status: "pending", todo: nil, level: nil,
        file: root.appendingPathComponent(".org2/runs/renewal.org2").path, line: 1, idValue: nil,
        properties: [:], body: "", tags: [], approvalId: "approval-renewal", action: "send email",
        requestedAt: requested, runId: "renewal"
      ),
    ])
    try await waitForCondition { store.activitySnapshot(now: now).working.count == 1 }

    let snapshot = store.activitySnapshot(now: now)
    XCTAssertEqual(snapshot.working.map(\.id), ["run:fresh-running"], "Old running and queued runs are not live work")
    let needsYou = Set(snapshot.needsYou.map(\.id))
    XCTAssertEqual(needsYou, ["approvals:run:scout", "approval:run:renewal:approval-renewal", "run:fresh-blocked", "run:fresh-failed"])
    let scout = try XCTUnwrap(snapshot.needsYou.first { $0.id == "approvals:run:scout" })
    XCTAssertEqual(scout.title, "Example Reviewer review")
    XCTAssertEqual(scout.detail, "3 decisions waiting")
    XCTAssertEqual(scout.count, 3)
    XCTAssertEqual(snapshot.needsYou.first { $0.id == "approval:run:renewal:approval-renewal" }?.detail, "Approve: send email")
    XCTAssertEqual(snapshot.hiddenOlderCount, 4, "stale running, queued, blocked, and failed runs are counted, not listed")
    XCTAssertEqual(snapshot.changed.map(\.relativePath), ["notes/today.org"], "Machine state under .org2 is not a change you made")
  }

  func testActivityPolicyWindowsDependOnState() {
    let now = Date()
    let hours: (Double) -> Date = { now.addingTimeInterval(-$0 * 3600) }
    XCTAssertTrue(WorkspaceActivityPolicy.isCurrent(state: .working, updatedAt: hours(23), now: now))
    XCTAssertFalse(WorkspaceActivityPolicy.isCurrent(state: .queued, updatedAt: hours(25), now: now))
    XCTAssertTrue(WorkspaceActivityPolicy.isCurrent(state: .needsYou, updatedAt: hours(6 * 24), now: now))
    XCTAssertFalse(WorkspaceActivityPolicy.isCurrent(state: .yourTurn, updatedAt: hours(8 * 24), now: now))
    XCTAssertFalse(WorkspaceActivityPolicy.isCurrent(state: .failed, updatedAt: hours(4 * 24), now: now))
    XCTAssertTrue(WorkspaceActivityPolicy.isCurrent(state: .failed, updatedAt: nil, now: now))
    XCTAssertTrue(WorkspaceActivityPolicy.isMachineManaged(".org2/runs/a.org2"))
    XCTAssertTrue(WorkspaceActivityPolicy.isMachineManaged("notes/.cache/x.org"))
    XCTAssertFalse(WorkspaceActivityPolicy.isMachineManaged("notes/a.org"))
  }

  func testActivityThreadIDIsReadFromRunComments() throws {
    let threadID = UUID()
    let run = try makeRun(id: "r", status: "running", comments: ["AI destination: codex\nAI chat thread: \(threadID.uuidString.lowercased())"])
    XCTAssertEqual(WorkspaceStore.activityThreadID(in: run), threadID)
    XCTAssertNil(WorkspaceStore.activityThreadID(in: try makeRun(id: "s", status: "running")))
  }

  func testActivityMapAreasGroupByImmediateChildAndKeepSignaledTiles() {
    let now = Date()
    let files = (0..<30).map { index in
      CorpusFile(path: "/c/bulk/\(index).org", relativePath: "bulk/\(index).org", modifiedAt: nil, byteCount: nil)
    } + [
      CorpusFile(path: "/c/top.org", relativePath: "top.org", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: "/c/quiet/a.org", relativePath: "quiet/a.org", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: "/c/hot/a.org", relativePath: "hot/a.org", modifiedAt: nil, byteCount: nil),
    ]
    let item = WorkspaceActivityItem(id: "x", kind: .needsYou, title: "x", detail: "", relativePath: "hot/a.org", target: .run("x"))
    let areas = WorkspaceActivityMap.areas(files: files, items: [item], prefix: "", now: now, limit: 2)
    XCTAssertEqual(Set(areas.map(\.path)), ["hot", "bulk"], "limit keeps signaled tiles, then the heaviest")
    XCTAssertEqual(areas.first { $0.path == "bulk" }?.fileCount, 30)

    let all = WorkspaceActivityMap.areas(files: files, items: [], prefix: "", now: now)
    XCTAssertEqual(all.first { $0.path == "top.org" }?.isFile, true)
  }

  func testTreemapTilesTheBoundsWithoutOverlap() {
    let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
    let weights: [Double] = [6, 6, 4, 3, 2, 2, 1]
    let rects = WorkspaceActivityMap.treemap(weights: weights, in: bounds)
    XCTAssertEqual(rects.count, weights.count)
    let totalArea = rects.reduce(0) { $0 + $1.width * $1.height }
    XCTAssertEqual(totalArea, bounds.width * bounds.height, accuracy: 1)
    for (index, rect) in rects.enumerated() {
      XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect), "rect \(index) escapes the bounds")
      let expected = weights[index] / weights.reduce(0, +) * Double(bounds.width * bounds.height)
      XCTAssertEqual(Double(rect.width * rect.height), expected, accuracy: 1)
      for other in rects[(index + 1)...] {
        XCTAssertLessThan(rect.intersection(other).width * rect.intersection(other).height, 0.5)
      }
    }
    XCTAssertEqual(WorkspaceActivityMap.treemap(weights: [], in: bounds), [])
  }

  func testRelativePathFromReferenceStripsSchemesLinesAndRoot() {
    XCTAssertEqual(WorkspaceActivityMap.relativePath(fromReference: "file:notes/a.org:12", corpusRoot: "/c"), "notes/a.org")
    XCTAssertEqual(WorkspaceActivityMap.relativePath(fromReference: "notes/a.org:3-9", corpusRoot: "/c"), "notes/a.org")
    XCTAssertEqual(WorkspaceActivityMap.relativePath(fromReference: "/c/notes/a.org", corpusRoot: "/c"), "notes/a.org")
    XCTAssertNil(WorkspaceActivityMap.relativePath(fromReference: "/elsewhere/a.org", corpusRoot: "/c"))
    XCTAssertNil(WorkspaceActivityMap.relativePath(fromReference: "https://example.com/a", corpusRoot: "/c"))
    XCTAssertEqual(WorkspaceActivityMap.breadcrumbs(for: "a/b").map(\.path), ["a", "a/b"])
  }

  // MARK: Helpers

  private actor SentPromptRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
  }

  private func makeDefaults() throws -> (UserDefaults, String) {
    let suiteName = "org2-activity-navigation-\(UUID().uuidString)"
    return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
  }

  private func temporaryLogURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-usage-log-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("usage-events.jsonl")
  }

  private func temporaryCorpus() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-activity-corpus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.standardizedFileURL
  }

  private func makeRun(
    id: String,
    status: String,
    contextRefs: [String] = [],
    blockedReason: String? = nil,
    comments: [String] = [],
    pendingApproval: Bool = false,
    updatedAt: Date = Date()
  ) throws -> AgentRunItem {
    var value: [String: Any] = [
      "id": id,
      "goal": "Goal \(id)",
      "acceptanceCriteria": [],
      "status": status,
      "riskClass": "local-draft",
      "capabilities": [],
      "context": contextRefs.map { ["ref": $0] },
      "plan": [],
      "artifacts": [],
      "approvals": pendingApproval ? [[
        "id": "approval-1",
        "title": "Approve",
        "action": "publish",
        "riskClass": "external-action",
        "status": "pending",
        "requestedAt": "2026-10-01T00:00:00.000Z",
      ]] : [],
      "validations": [],
      "comments": comments.enumerated().map { index, body in [
        "id": "comment-\(index)",
        "author": "OpenOrg",
        "body": body,
        "createdAt": "2026-10-01T00:00:00.000Z",
      ] },
      "events": [],
      "createdAt": "2026-10-01T00:00:00.000Z",
      "updatedAt": ISO8601DateFormatter().string(from: updatedAt),
    ]
    if let blockedReason { value["blockedReason"] = blockedReason }
    let data = try JSONSerialization.data(withJSONObject: value)
    return try JSONDecoder().decode(AgentRunItem.self, from: data)
  }

  private func waitForCondition(
    timeout: TimeInterval = 3,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("Timed out waiting for asynchronous workspace state")
  }
}
