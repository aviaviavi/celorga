import XCTest
@testable import Org2WorkspaceCore

private actor RunReviewPageRefreshRecorder {
  private var pages: [RunsAndReviewPage] = []

  func record(_ page: RunsAndReviewPage) {
    pages.append(page)
  }

  func snapshot() -> [RunsAndReviewPage] {
    pages
  }
}

final class WorkspaceDisplayCacheTests: XCTestCase {
  func testCorpusFileTreePresentationProducesFlatStableRows() {
    let files = [
      CorpusFile(
        path: "/tmp/corpus/daily/2026/09/17.org",
        relativePath: "daily/2026/09/17.org",
        modifiedAt: nil,
        byteCount: 12
      ),
      CorpusFile(
        path: "/tmp/corpus/notes/alpha.org",
        relativePath: "notes/alpha.org",
        modifiedAt: nil,
        byteCount: 24
      )
    ]
    let tree = WorkspaceStore.makeCorpusFileTree(files)

    XCTAssertEqual(
      CorpusFileTreePresentation.visibleRows(in: tree, expandedDirectoryIDs: []).map(\.node.name),
      ["daily", "notes"]
    )

    let expanded = CorpusFileTreePresentation.visibleRows(
      in: tree,
      expandedDirectoryIDs: ["directory:daily", "directory:daily/2026", "directory:daily/2026/09"]
    )
    XCTAssertEqual(expanded.map(\.node.name), ["daily", "2026", "09", "17.org", "notes"])
    XCTAssertEqual(expanded.map(\.depth), [0, 1, 2, 3, 0])
    XCTAssertEqual(Set(expanded.map(\.id)).count, expanded.count)
  }

  func testCorpusFileTreePresentationStaysUniqueAcrossRapidRefreshAndCollapse() {
    for revision in 0..<500 {
      let files = (0..<20).map { index in
        CorpusFile(
          path: "/tmp/corpus/notes/group-\(index % 4)/item-\(revision)-\(index).org",
          relativePath: "notes/group-\(index % 4)/item-\(revision)-\(index).org",
          modifiedAt: nil,
          byteCount: nil
        )
      }
      let tree = WorkspaceStore.makeCorpusFileTree(files)
      let expanded: Set<String> = revision.isMultiple(of: 2)
        ? ["directory:notes", "directory:notes/group-0", "directory:notes/group-1"]
        : []
      let rows = CorpusFileTreePresentation.visibleRows(
        in: tree,
        expandedDirectoryIDs: expanded
      )
      XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
  }

  func testDynamicFileTreesDoNotUseSwiftUIOutlineGroup() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: packageRoot
        .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(source.contains("OutlineGroup("))
    XCTAssertTrue(source.contains("CorpusFileTreePresentation.visibleRows"))
  }

  @MainActor
  func testCorpusFileDisplayCacheInvalidatesForFileAndQueryChanges() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let alpha = CorpusFile(
      path: "/tmp/alpha.org2",
      relativePath: "notes/alpha.org2",
      modifiedAt: nil,
      byteCount: nil
    )
    let beta = CorpusFile(
      path: "/tmp/beta.org2",
      relativePath: "projects/beta.org2",
      modifiedAt: nil,
      byteCount: nil
    )

    store.corpusFiles = [alpha, beta]
    await store.waitForCorpusFilePublicationForTesting()
    XCTAssertEqual(store.corpusFileTree.map(\.name), ["notes", "projects"])
    XCTAssertEqual(store.corpusFileTree.map(\.descendantFileCount), [1, 1])
    store.corpusFileFilter = "alpha"
    await store.waitForCorpusFilePublicationForTesting()
    XCTAssertEqual(store.filteredCorpusFiles, [alpha])
    XCTAssertEqual(store.filteredCorpusFileTree.map(\.name), ["notes"])

    store.selectedCorpusFileIDsForAIContext = [alpha.id, beta.id]
    store.corpusFileFilter = "beta"
    await store.waitForCorpusFilePublicationForTesting()
    XCTAssertEqual(store.filteredCorpusFiles, [beta])
    XCTAssertEqual(
      store.selectedCorpusFileIDsForAIContext,
      [beta.id],
      "The store publication lane must reconcile selection without a mounted FilesView"
    )

    store.corpusFiles = [beta]
    XCTAssertTrue(store.filteredCorpusFiles.isEmpty)
    XCTAssertTrue(store.selectedCorpusFileIDsForAIContext.isEmpty)

    store.corpusFileFilter = "beta"
    await store.waitForCorpusFilePublicationForTesting()
    XCTAssertEqual(store.filteredCorpusFiles, [beta])
  }

  @MainActor
  func testCorpusAssignmentsStayFlatAcrossMultiSizeMainActorBudget() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let sizes = [2_000, 20_000, 80_000]
    let catalogs = sizes.map { size in
      (0..<size).map { index in
        CorpusFile(
          path: String(format: "/tmp/corpus/notes/%07d.org", index),
          relativePath: String(format: "notes/%07d.org", index),
          modifiedAt: nil,
          byteCount: Int64(index)
        )
      }
    }
    var assignmentNanoseconds: [UInt64] = []

    for catalog in catalogs {
      let startedAt = DispatchTime.now().uptimeNanoseconds
      store.corpusFiles = catalog
      assignmentNanoseconds.append(DispatchTime.now().uptimeNanoseconds - startedAt)
      await store.waitForCorpusFilePublicationForTesting()
    }

    for (size, elapsed) in zip(sizes, assignmentNanoseconds) {
      XCTAssertLessThan(
        elapsed,
        30_000_000,
        "Assigning \(size) corpus files blocked the main actor for more than 30 ms"
      )
    }
    XCTAssertLessThan(
      assignmentNanoseconds[2],
      max(assignmentNanoseconds[0] * 6, 10_000_000),
      "80k assignment grew with corpus size; derived projection work likely returned to the main actor"
    )
  }

  @MainActor
  func testCorpusAssignmentBurstBuildsOnlyLatestProjection() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let catalogs = (0..<24).map { revision in
      (0..<2_000).map { index in
        CorpusFile(
          path: "/tmp/corpus-\(revision)/notes/\(index).org",
          relativePath: "notes/revision-\(revision)-\(index).org",
          modifiedAt: nil,
          byteCount: Int64(index)
        )
      }
    }

    for catalog in catalogs {
      store.corpusFiles = catalog
    }
    await store.waitForCorpusFilePublicationForTesting()

    XCTAssertEqual(store.corpusFileProjectionBuildCountForTesting, 1)
    XCTAssertEqual(store.filteredCorpusFiles.first, catalogs.last?.first)
    XCTAssertEqual(store.filteredCorpusFiles.count, 500)
  }

  @MainActor
  func testAgendaDisplayCacheInvalidatesForAgendaAndQueryChanges() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.agenda = try agenda(headline: "Alpha launch", file: "/tmp/alpha.org2")
    store.agendaFilter = "alpha"
    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Alpha launch"])

    store.agenda = try agenda(headline: "Beta launch", file: "/tmp/beta.org2")
    XCTAssertTrue(store.visibleAgendaItems.isEmpty)

    store.agendaFilter = "beta launch"
    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Beta launch"])

    store.agendaStatusFilter = WorkspaceStore.agendaCompletedStatusFilter
    XCTAssertTrue(store.visibleAgendaItems.isEmpty)
    store.agendaStatusFilter = WorkspaceStore.agendaOpenStatusFilter
    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Beta launch"])
    store.agendaDateFilter = .overdue
    XCTAssertTrue(store.visibleAgendaItems.isEmpty)
    store.agendaDateFilter = .today
    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Beta launch"])
  }

  @MainActor
  func testOverdueItemsDefaultToStablePriorityOrder() throws {
    let items = try [
      agendaItem(headline: "Unprioritized old", priority: nil, line: 1),
      agendaItem(headline: "Priority C", priority: "C", line: 2),
      agendaItem(headline: "Priority A old", priority: "A", line: 3),
      agendaItem(headline: "Priority B", priority: "B", line: 4),
      agendaItem(headline: "Priority A new", priority: "A", line: 5),
      agendaItem(headline: "Unprioritized new", priority: nil, line: 6)
    ]

    XCTAssertEqual(
      WorkspaceStore.sortedOverdueItems(items, order: .priority).map(\.headline),
      ["Priority A old", "Priority A new", "Priority B", "Priority C", "Unprioritized old", "Unprioritized new"]
    )
    XCTAssertEqual(
      WorkspaceStore.sortedOverdueItems(items, order: .dueDate).map(\.headline),
      items.map(\.headline)
    )
  }

  @MainActor
  func testOverdueOrderPreferencePersists() throws {
    let suiteName = "Org2WorkspaceTests.agenda-overdue-order.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    XCTAssertEqual(first.agendaOverdueOrder, .priority)
    first.agendaOverdueOrder = .dueDate

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    XCTAssertEqual(restored.agendaOverdueOrder, .dueDate)
  }

  @MainActor
  func testRunCenterDisplayCacheInvalidatesForRunsAndQueryChanges() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let active = try agentRun(id: "run-active", goal: "Build alpha", status: "running")
    let completed = try agentRun(id: "run-completed", goal: "Ship beta", status: "completed")

    store.replaceAgentRunsForTesting([active, completed])

    XCTAssertEqual(store.agentRunCount(for: .active), 1)
    XCTAssertEqual(store.agentRunCount(for: .completed), 1)
    XCTAssertEqual(store.agentRunCount(for: .all), 2)
    XCTAssertEqual(store.agentRunEntries(for: .active).map(\.id), ["run-active"])
    XCTAssertEqual(store.agentRunIDs(for: .active), ["run-active"])
    XCTAssertEqual(store.agentRunSections(for: .active).flatMap(\.entries).map(\.id), ["run-active"])

    store.agentRunFilter = "beta"

    XCTAssertTrue(store.agentRunEntries(for: .active).isEmpty)
    XCTAssertEqual(store.agentRunEntries(for: .all).map(\.id), ["run-completed"])
    XCTAssertEqual(store.agentRunCount(for: .all), 2)
  }

  @MainActor
  func testRunCenterIndexesGoalAndAgentCountsOncePerRunRefresh() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let first = try agentRun(
      id: "run-1",
      goal: "First",
      status: "running",
      goalRef: "revenue",
      agentRef: "scout"
    )
    let second = try agentRun(
      id: "run-2",
      goal: "Second",
      status: "completed",
      goalRef: "revenue",
      agentRef: "writer"
    )

    store.replaceAgentRunsForTesting([first, second])

    XCTAssertEqual(store.agentRunCount(goalRef: "revenue"), 2)
    XCTAssertEqual(store.agentRunCount(agentRef: "scout"), 1)
    XCTAssertEqual(store.agentRunCount(agentRef: "writer"), 1)
    XCTAssertEqual(store.agentRun(for: "run-2")?.goal, "Second")
    XCTAssertTrue(store.isAgentRunVisible("run-2", in: .completed))
    XCTAssertFalse(store.isAgentRunVisible("run-2", in: .active))
  }

  @MainActor
  func testRunCenterRebuildsLargeDisplayCacheOffMainWithinRefreshBudget() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let runs = try (0..<4_205).map { index in
      try agentRun(
        id: "completed-\(index)",
        goal: "Completed outcome \(index)",
        status: "completed",
        goalRef: "goal-\(index % 20)",
        agentRef: "agent-\(index % 12)"
      )
    }
    let clock = ContinuousClock()
    let startedAt = clock.now

    store.replaceAgentRunsForTesting(runs, buildsProjectionSynchronously: false)

    let elapsed = startedAt.duration(to: clock.now)
    XCTAssertLessThan(elapsed, .milliseconds(25), "Assigning 4,205 runs must yield within an interactive frame")
    await store.waitForAgentRunProjectionForTesting()
    XCTAssertEqual(store.agentRunCount(for: .all), runs.count)
    XCTAssertEqual(store.agentRunSections(for: .all).flatMap(\.entries).count, runs.count)
    XCTAssertEqual(store.agentRunProjectionMainThreadBuildCountForTesting, 0)
  }

  @MainActor
  func testRunDetailLookupsStayIndexedAcrossALargeArchive() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let runs = try (0..<4_205).map { index in
      try agentRun(
        id: "indexed-\(index)",
        goal: "Indexed outcome \(index)",
        status: "completed"
      )
    }
    store.replaceAgentRunsForTesting(runs)
    store.selectAgentRun(try XCTUnwrap(runs.last))
    let ids = runs.map(\.id)
    let clock = ContinuousClock()
    let startedAt = clock.now
    var checksum = 0

    for index in 0..<20_000 {
      checksum &+= store.agentRun(for: ids[index % ids.count])?.id.count ?? 0
      checksum &+= store.presentedAgentRun?.id.count ?? 0
    }

    let elapsed = startedAt.duration(to: clock.now)
    XCTAssertGreaterThan(checksum, 0)
    XCTAssertEqual(store.presentedAgentRun?.id, "indexed-4204")
    XCTAssertLessThan(
      elapsed,
      .milliseconds(150),
      "Run-detail lookup regressed to scanning the complete run archive"
    )
  }

  @MainActor
  func testRunCenterFiltersLargeCachedCatalogWithinInteractiveBudget() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let runs = try (0..<4_205).map { index in
      try agentRun(
        id: "completed-\(index)",
        goal: "Completed outcome \(index)",
        status: "completed"
      )
    }
    store.replaceAgentRunsForTesting(runs)
    let clock = ContinuousClock()
    let startedAt = clock.now

    store.agentRunFilter = "outcome 4204"

    let elapsed = startedAt.duration(to: clock.now)
    XCTAssertLessThan(elapsed, .milliseconds(25), "Filtering must yield within an interactive frame")
    await store.waitForAgentRunProjectionForTesting()
    XCTAssertEqual(store.agentRunEntries(for: .all).map(\.id), ["completed-4204"])
  }

  @MainActor
  func testRunFilterKeystrokesReuseRunIndexesUntilRunsChange() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let runs = try (0..<1_200).map { index in
      try agentRun(
        id: "history-\(index)",
        goal: "Automation attempt \(index)",
        status: "completed"
      )
    }
    store.replaceAgentRunsForTesting(runs)
    XCTAssertEqual(store.agentRunProjectionIndexReuseCountForTesting, 0)

    store.agentRunFilter = "attempt 11"
    await store.waitForAgentRunProjectionForTesting()
    store.agentRunFilter = "attempt 1199"
    await store.waitForAgentRunProjectionForTesting()

    XCTAssertEqual(store.agentRunProjectionIndexReuseCountForTesting, 2, "A filter change must not rebuild per-run search text")
    XCTAssertEqual(store.agentRunEntries(for: .all).map(\.id), ["history-1199"])

    // New runs invalidate the reusable indexes.
    let added = try agentRun(id: "history-new", goal: "Automation attempt 1199 rerun", status: "completed")
    store.replaceAgentRunsForTesting(runs + [added], buildsProjectionSynchronously: false)
    await store.waitForAgentRunProjectionForTesting()
    XCTAssertEqual(store.agentRunProjectionIndexReuseCountForTesting, 2)
    XCTAssertTrue(store.agentRunEntries(for: .all).map(\.id).contains("history-new"))
  }

  @MainActor
  func testCachedRunReviewPageRevisitDoesNotRefresh() async throws {
    let root = try makeRunReviewRoot(label: "cached-revisit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let recorder = RunReviewPageRefreshRecorder()
    let run = try agentRun(id: "cached-run")
    store.setCorpusRoot(root, persistsDefault: false)
    store.replaceAgentRunsForTesting([run])
    store.runReviewPageRefreshOperationForTesting = { page in
      await recorder.record(page)
    }

    store.runsAndReviewPage = .runs
    await store.refreshSelectedRunReviewPageIfNeeded()
    store.runsAndReviewPage = .review
    store.replaceApprovalItemsForTesting([])
    await store.refreshSelectedRunReviewPageIfNeeded()
    store.runsAndReviewPage = .runs
    await store.refreshSelectedRunReviewPageIfNeeded()

    let automaticRefreshes = await recorder.snapshot()
    XCTAssertEqual(automaticRefreshes, [])
    XCTAssertEqual(store.agentRuns.map(\.id), ["cached-run"])

    await store.refreshSelectedRunReviewPage()
    let refreshesAfterExplicitRefresh = await recorder.snapshot()
    XCTAssertEqual(refreshesAfterExplicitRefresh, [.runs])
  }

  @MainActor
  func testLoadedEmptyRunReviewPageDoesNotRefetchOnSwitch() async throws {
    let root = try makeRunReviewRoot(label: "loaded-empty")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let recorder = RunReviewPageRefreshRecorder()
    store.setCorpusRoot(root, persistsDefault: false)
    store.replaceAgentRunsForTesting([])
    store.runReviewPageRefreshOperationForTesting = { page in
      await recorder.record(page)
    }

    store.runsAndReviewPage = .runs
    await store.refreshSelectedRunReviewPageIfNeeded()
    store.runsAndReviewPage = .review
    store.runsAndReviewPage = .runs
    await store.refreshSelectedRunReviewPageIfNeeded()

    XCTAssertTrue(store.agentRuns.isEmpty)
    XCTAssertTrue(store.isRunReviewPageLoadedForTesting(.runs))
    XCTAssertFalse(store.isRunReviewPageDirtyForTesting(.runs))
    let refreshedPages = await recorder.snapshot()
    XCTAssertEqual(refreshedPages, [])
  }

  @MainActor
  func testRunReviewInvalidationRefreshesEachDirtyPageWhenSelected() async throws {
    let root = try makeRunReviewRoot(label: "page-dirty")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let recorder = RunReviewPageRefreshRecorder()
    store.setCorpusRoot(root, persistsDefault: false)
    store.replaceAgentRunsForTesting([try agentRun(id: "dirty-run")])
    store.replaceApprovalItemsForTesting([])
    store.runReviewPageRefreshOperationForTesting = { page in
      await recorder.record(page)
    }

    store.handleCorpusFileEvents(
      [root.appendingPathComponent(".org2/runs/dirty-run.org2").path],
      corpusRoot: root,
      requiresFullScan: false
    )
    XCTAssertTrue(store.isRunReviewPageDirtyForTesting(.runs))
    XCTAssertTrue(store.isRunReviewPageDirtyForTesting(.review))

    store.runsAndReviewPage = .runs
    await store.refreshSelectedRunReviewPageIfNeeded()
    XCTAssertFalse(store.isRunReviewPageDirtyForTesting(.runs))
    XCTAssertTrue(store.isRunReviewPageDirtyForTesting(.review))

    store.runsAndReviewPage = .review
    await store.refreshSelectedRunReviewPageIfNeeded()
    XCTAssertFalse(store.isRunReviewPageDirtyForTesting(.review))
    let refreshedPages = await recorder.snapshot()
    XCTAssertEqual(refreshedPages, [.runs, .review])
  }

  @MainActor
  func testInjectedRunScaleSurvivesWarmShippingPageSwitches() async throws {
    let root = try makeRunReviewRoot(label: "scale-switch")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let recorder = RunReviewPageRefreshRecorder()
    let runs = try (0..<2_000).map { index in
      try agentRun(id: "scale-\(index)", goal: "Scale run \(index)", status: "completed")
    }
    store.setCorpusRoot(root, persistsDefault: false)
    store.replaceAgentRunsForTesting(runs)
    store.replaceApprovalItemsForTesting([])
    store.runReviewPageRefreshOperationForTesting = { page in
      await recorder.record(page)
    }

    store.runsAndReviewPage = .review
    await store.refreshSelectedRunReviewPageIfNeeded()
    store.runsAndReviewPage = .runs
    await store.refreshSelectedRunReviewPageIfNeeded()

    XCTAssertEqual(store.agentRuns.count, runs.count)
    XCTAssertEqual(store.agentRuns.first?.id, "scale-0")
    let refreshedPages = await recorder.snapshot()
    XCTAssertEqual(refreshedPages, [])
  }

  @MainActor
  func testExternalThreadDisplayCacheInvalidatesForThreadsAndQueryChanges() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let alpha = try externalThread(id: "alpha", title: "Alpha rollout")
    let beta = try externalThread(id: "beta", title: "Beta follow-up")

    store.replaceExternalThreadsForTesting([alpha, beta])
    store.externalThreadSearchQuery = "beta"
    XCTAssertEqual(store.filteredExternalThreads.map(\.id), ["codex:beta"])

    store.replaceExternalThreadsForTesting([alpha])
    XCTAssertTrue(store.filteredExternalThreads.isEmpty)
  }

  @MainActor
  func testSwitchingBackToCorpusRestoresCachedAgendaFilesAndRuns() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-corpus-workspace-cache-\(UUID().uuidString)", isDirectory: true)
    let alphaRoot = container.appendingPathComponent("alpha", isDirectory: true)
    let betaRoot = container.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alphaRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: betaRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let run = try agentRun()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(alphaRoot, persistsDefault: false)
    store.agenda = try agenda(
      headline: "Alpha launch",
      file: alphaRoot.appendingPathComponent("notes/alpha.org2").path
    )
    let alphaFile = CorpusFile(
      path: alphaRoot.appendingPathComponent("notes/alpha.org2").path,
      relativePath: "notes/alpha.org2",
      modifiedAt: nil,
      byteCount: nil
    )
    store.corpusFiles = [alphaFile]
    store.replaceAgentRunsForTesting([run])
    XCTAssertEqual(store.agentRuns.map(\.id), ["run-alpha"])

    store.setCorpusRoot(betaRoot, persistsDefault: false)
    XCTAssertNil(store.agenda)
    XCTAssertTrue(store.corpusFiles.isEmpty)
    XCTAssertTrue(store.agentRuns.isEmpty)

    store.workspaceRefreshOperationForTesting = {
      XCTFail("A warm corpus switch should not run a full workspace refresh")
    }
    let alphaMount = try XCTUnwrap(store.mountedCorpora.first { $0.path == alphaRoot.path })
    store.switchCorpus(to: alphaMount)
    while store.isSwitchingCorpus {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(store.agenda?.days.flatMap(\.items).map(\.headline), ["Alpha launch"])
    XCTAssertEqual(store.corpusFiles, [alphaFile])
    XCTAssertEqual(store.agentRuns.map(\.id), ["run-alpha"])
  }

  @MainActor
  func testInactiveCorpusChangeMarksRestoredCacheDirtyWithoutDiscardingIt() throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-inactive-corpus-cache-\(UUID().uuidString)", isDirectory: true)
    let alphaRoot = container.appendingPathComponent("alpha", isDirectory: true)
    let betaRoot = container.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alphaRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: betaRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(alphaRoot, persistsDefault: false)
    store.agenda = try agenda(
      headline: "Cached alpha item",
      file: alphaRoot.appendingPathComponent("notes/alpha.org2").path
    )
    store.setCorpusRoot(betaRoot, persistsDefault: false)

    let changedFile = alphaRoot.appendingPathComponent("notes/alpha.org2")
    store.handleCorpusFileEvents(
      [changedFile.path],
      corpusRoot: alphaRoot,
      requiresFullScan: false
    )
    store.setCorpusRoot(alphaRoot, persistsDefault: false)

    XCTAssertEqual(store.agenda?.days.flatMap(\.items).map(\.headline), ["Cached alpha item"])
    XCTAssertTrue(store.isWorkspaceSurfaceDirty(.agenda))
    XCTAssertTrue(store.isWorkspaceSurfaceDirty(.files))
  }

  private func agentRun(
    id: String = "run-alpha",
    goal: String = "Keep alpha warm",
    status: String = "running",
    goalRef: String? = nil,
    agentRef: String? = nil
  ) throws -> AgentRunItem {
    var object: [String: Any] = [
      "schema": "org2:agent-run:v1",
      "id": id,
      "goal": goal,
      "acceptanceCriteria": [],
      "status": status,
      "riskClass": "local-draft",
      "capabilities": [],
      "context": [],
      "plan": [],
      "artifacts": [],
      "approvals": [],
      "validations": [],
      "comments": [],
      "events": [],
      "createdAt": "2026-07-28T00:00:00.000Z",
      "updatedAt": "2026-07-28T00:01:00.000Z"
    ]
    object["goalRef"] = goalRef
    object["agentRef"] = agentRef
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(AgentRunItem.self, from: data)
  }

  private func externalThread(id: String, title: String) throws -> ExternalThreadSummary {
    ExternalThreadSummary(
      harness: .codex,
      externalID: id,
      title: title,
      preview: "Read-only transcript",
      workspacePath: "/tmp/org2",
      source: "codex",
      modelProvider: "openai",
      createdAt: Date(timeIntervalSince1970: 1_776_556_800),
      updatedAt: Date(timeIntervalSince1970: 1_776_556_800),
      status: "active",
      isPinned: false
    )
  }

  private func makeRunReviewRoot(label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-run-review-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func agenda(headline: String, file: String) throws -> AgendaPayload {
    let data = try JSONSerialization.data(withJSONObject: [
      "$schema": "org2:agenda:v1",
      "range": ["start": "2026-07-21", "end": "2026-07-28", "days": 8],
      "overdue": [],
      "days": [[
        "date": "2026-07-21",
        "weekday": "Tuesday",
        "items": [[
          "todo": "TODO",
          "headline": headline,
          "kind": "SCHEDULED",
          "file": file,
          "line": 0,
          "body": "",
          "tags": [],
          "properties": [:]
        ]]
      ]]
    ])
    return try JSONDecoder().decode(AgendaPayload.self, from: data)
  }

  private func agendaItem(headline: String, priority: String?, line: Int) throws -> AgendaItem {
    var object: [String: Any] = [
      "todo": "TODO",
      "headline": headline,
      "kind": "SCHEDULED",
      "file": "/tmp/overdue.org2",
      "line": line,
      "body": "",
      "tags": [],
      "properties": [:]
    ]
    object["priority"] = priority
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(AgendaItem.self, from: data)
  }
}
