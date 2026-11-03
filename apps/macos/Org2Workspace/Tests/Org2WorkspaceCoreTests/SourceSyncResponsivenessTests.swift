import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor SourceSyncGate {
  private(set) var started = false
  private var continuation: CheckedContinuation<Void, Never>?

  func hold() async {
    started = true
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

final class SourceSyncResponsivenessTests: XCTestCase {
  @MainActor
  func testSourceSyncStillSerializesEditsInsideImportZones() async throws {
    let fixture = try makeFixture(sourceSyncDelayMilliseconds: 3_000)
    defer { fixture.cleanup() }
    let gate = SourceSyncGate()
    await holdSourceSync(fixture, at: gate)
    let sync = Task { await fixture.store.syncAndStageSource(fixture.profile) }
    let started = await waitUntil { await gate.started }
    XCTAssertTrue(started)

    var edits: [(Task<Void, Error>, SourceSyncGate)] = []
    for zone in [fixture.profile.rawZone, fixture.profile.reviewZone] {
      let finished = SourceSyncGate()
      let file = fixture.corpus.appendingPathComponent("\(zone)/imported.org2")
      let edit: Task<Void, Error> = try await fixture.store.documentMutationLane.enqueue(
        rootPath: fixture.corpus.path, resourcePaths: [file.path]
      ) { _ in await finished.hold() }
      edits.append((edit, finished))
    }
    try await Task.sleep(for: .milliseconds(100))
    for (_, finished) in edits {
      let startedWhileSyncPending = await finished.started
      XCTAssertFalse(startedWhileSyncPending, "Both import zones must remain reserved")
    }
    // Releasing the hook lets the CLI run; its completion, rather than a
    // two-second process-start budget, releases the import reservations.
    await gate.release()
    await sync.value
    // Release each overlapping edit as it starts, then drain both tasks.
    for (edit, finished) in edits {
      let editStarted = await waitUntil { await finished.started }
      XCTAssertTrue(editStarted)
      await finished.release()
      try await edit.value
    }
  }

  @MainActor
  func testImportReservationsUseConfiguredZonesAndDefaults() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    var profile = fixture.profile
    profile.rawZone = "staging/raw"
    profile.reviewZone = fixture.corpus.appendingPathComponent("staging/review").path
    XCTAssertEqual(profile.importResourcePaths(in: fixture.corpus), [
      fixture.corpus.appendingPathComponent("staging/raw").path,
      fixture.corpus.appendingPathComponent("staging/review").path
    ])
    profile.rawZone = ""
    profile.reviewZone = ""
    XCTAssertEqual(profile.importResourcePaths(in: fixture.corpus), [
      fixture.corpus.appendingPathComponent("raw/connectors/slack/slack").path,
      fixture.corpus.appendingPathComponent("views/connectors/slack/slack").path
    ])
  }

  @MainActor
  func testDailyNavigationCompletesWhileSourceSyncIsPending() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let gate = SourceSyncGate()
    await holdSourceSync(fixture, at: gate)
    let sync = Task { await fixture.store.syncAndStageSource(fixture.profile) }
    let started = await waitUntil { await gate.started }
    XCTAssertTrue(started)

    // Exercise the real sidebar caller for both an existing and a missing note.
    for target in [DailyNoteTarget.today, .tomorrow] {
      let date = Calendar.current.date(byAdding: .day, value: target == .today ? 0 : 1, to: Date())!
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"
      let expected = fixture.corpus.appendingPathComponent("daily/\(formatter.string(from: date)).org")
      if target == .today {
        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#+TITLE: Existing daily\n".write(to: expected, atomically: true, encoding: .utf8)
      }
      fixture.store.openDailyNoteFromSidebar(target)
      let opened = await waitUntil { fixture.store.selectedLocation?.file == expected.path }
      XCTAssertTrue(opened, "\(target) must open before the crawler finishes")
      if opened { XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path)) }
    }

    await gate.release()
    await sync.value
    await fixture.store.waitForDailyNoteNavigationForTesting()
  }

  @MainActor
  func testExplicitSaveCompletesWhileSourceSyncIsPending() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }
    let note = fixture.corpus.appendingPathComponent("notes/edit.org2")
    try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "* Original\nBody\n".write(to: note, atomically: true, encoding: .utf8)
    fixture.store.selectCorpusFile(CorpusFile(path: note.path, relativePath: "notes/edit.org2", modifiedAt: nil, byteCount: nil))
    await fixture.store.loadEntrySource(for: try XCTUnwrap(fixture.store.selectedLocation))
    fixture.store.beginEditingSelectedEntry()
    fixture.store.noteSourceEditorLocalTextChanged("* Original\nUpdated body\n")
    XCTAssertTrue(fixture.store.canSaveActiveEdit)

    let gate = SourceSyncGate()
    await holdSourceSync(fixture, at: gate)
    let sync = Task { await fixture.store.syncAndStageSource(fixture.profile) }
    let started = await waitUntil { await gate.started }
    XCTAssertTrue(started)
    var saveFinished = false
    let save = Task {
      await fixture.store.saveActiveEdit()
      saveFinished = true
    }
    let saved = await waitUntil { saveFinished }
    XCTAssertTrue(saved, "Save must finish before the crawler finishes")
    if saved {
      XCTAssertFalse(fixture.store.isSavingEntry)
      XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "* Original\nUpdated body\n")
      XCTAssertFalse(fixture.store.entryEditorHasUnsavedChanges)
    }

    await gate.release()
    await sync.value
    await save.value
  }

  @MainActor
  private func holdSourceSync(_ fixture: Fixture, at gate: SourceSyncGate) async {
    let root = fixture.corpus.path
    let raw = fixture.corpus.appendingPathComponent(fixture.profile.rawZone).path
    await fixture.store.documentMutationLane.setEventHookForTesting { event in
      if case .started(_, _, let resources) = event,
         resources.contains(root) || resources.contains(raw) {
        await gate.hold()
      }
    }
  }

  private struct Fixture {
    let workspace: URL
    let corpus: URL
    let store: WorkspaceStore
    let profile: WorkspaceSourceProfileStatus

    func cleanup() {
      try? FileManager.default.removeItem(at: workspace)
      UserDefaults(suiteName: workspace.lastPathComponent)?.removePersistentDomain(forName: workspace.lastPathComponent)
    }
  }

  @MainActor
  private func makeFixture(sourceSyncDelayMilliseconds: Int = 0) throws -> Fixture {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("org2-sync-responsive-\(UUID().uuidString)")
    let repo = workspace.appendingPathComponent("repo")
    let corpus = workspace.appendingPathComponent("corpus")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent("dist"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    // The gate pauses the real source-sync reservation; no provider is called.
    try """
    const args = process.argv.slice(2);
    if (args[0] === 'source' && args[1] === 'sync') {
      setTimeout(() => process.stdout.write(JSON.stringify({schema:'org2:source-sync:v1',root:'.',results:[{
        id:'slack',ok:true,skipped:true,reason:'sync-in-progress'
      }]})), \(sourceSyncDelayMilliseconds));
    } else if (args[0] === 'source' && args[1] === 'list') {
      process.stdout.write('[]');
    } else {
      process.stdout.write('{}');
    }
    """.write(to: repo.appendingPathComponent("dist/cli.js"), atomically: true, encoding: .utf8)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: workspace.lastPathComponent))
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repo), defaults: defaults)
    store.setCorpusRoot(corpus, persistsDefault: false)
    store.formatOrgFilesOnSave = false
    store.orgCryptEncryptOnSave = false
    store.automaticDailyNoteCreationDisabled = false
    store.entrySourceLoaderForTesting = { file, _, _ in
      let text = try String(contentsOfFile: file, encoding: .utf8)
      return EntrySource(file: file, startLine: 1, endLineExclusive: text.split(separator: "\n", omittingEmptySubsequences: false).count + 1, text: text, isSubtree: false, isEditable: true)
    }
    store.entryHTMLRendererForTesting = { _, _, _, _ in "<html><body>Fixture</body></html>" }
    let profile = WorkspaceSourceProfileStatus(id: "slack", type: "slack", enabled: true, scopes: [], workspaceId: nil,
      rawZone: "raw/connectors/slack", reviewZone: "views/connectors/slack", ingestionSince: nil, ingestionLimit: 100,
      syncArgs: [], media: "metadata-only", schedule: nil, binary: "slacrawl", binaryAvailable: true,
      configPath: nil, configAvailable: true, ready: true)
    return Fixture(workspace: workspace, corpus: corpus, store: store, profile: profile)
  }

  @MainActor
  private func waitUntil(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }
}
