import Foundation
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceAppsTests: XCTestCase {
  func testPluginSurfaceDocumentIsNetworkFreeAndCannotEscapeItsElements() {
    let render = WorkspacePluginSurfaceRender(
      title: "Board <1>",
      html: "<h1>Hi</h1>",
      css: "h1{color:red}</style><script>alert(1)</script>",
      script: "console.log('</script><img src=x>')"
    )
    let html = PluginSurfaceDocument.html(for: render)
    XCTAssertTrue(html.contains("default-src 'none'"))
    XCTAssertFalse(html.contains("connect-src"))
    XCTAssertTrue(html.contains("<title>Board &lt;1&gt;</title>"))
    XCTAssertFalse(html.contains("</style><script>alert"))
    XCTAssertEqual(html.components(separatedBy: "</script>").count, 2, "only our own script element closes")
  }

  func testCRMSplitKeepsBothPanesUsable() {
    XCTAssertEqual(CRMSplitLayout.clampedListWidth(500, totalWidth: 1200), 500)
    XCTAssertEqual(CRMSplitLayout.clampedListWidth(100, totalWidth: 1200), CRMSplitLayout.minimumListWidth)
    XCTAssertEqual(CRMSplitLayout.clampedListWidth(1100, totalWidth: 1200), 1200 - CRMSplitLayout.minimumDetailWidth)
    XCTAssertEqual(CRMSplitLayout.clampedListWidth(500, totalWidth: 500), CRMSplitLayout.minimumListWidth)
  }

  func testCRMDateLabelsAreRelativeAndKeepTimes() throws {
    let calendar = Calendar.current
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 12)))
    XCTAssertEqual(CRMDate.label("2026-03-02", now: now), "Today")
    XCTAssertEqual(CRMDate.label("2026-03-03", now: now), "Tomorrow")
    XCTAssertEqual(CRMDate.label("2026-02-25", now: now), "5 days ago")
    XCTAssertTrue(CRMDate.isPast("2026-03-01", now: now))
    XCTAssertFalse(CRMDate.isPast("2026-03-02", now: now))
    XCTAssertNil(CRMDate.label(nil, now: now))
    XCTAssertNotNil(CRMDate.parse("2026-03-02T16:00:00.000Z"))
  }

  func testAppsToggleSurfacesAndPeopleAndCompaniesDecodeSharedRuntimeOutput() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("celorga-apps-\(UUID().uuidString)", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "{\n  \"agendaFiles\": [\"notes/*.org\"]\n}\n".write(to: root.appendingPathComponent("celorga.json"), atomically: true, encoding: .utf8)
    let company = "aaaaaaaa-0000-4000-8000-000000000001"
    try ":PROPERTIES:\n:ID: \(company)\n:ORG2_ENTITY_TYPE: company\n:DOMAIN: acme.test\n:CRM_STAGE: prospect\n:END:\n#+title: Acme\n\n* TODO Send pricing\nSCHEDULED: <2026-03-03 Tue>\n"
      .write(to: notes.appendingPathComponent("acme.org"), atomically: true, encoding: .utf8)
    for (index, name) in ["Jane Doe", "Raj Patel", "Mia Chen", "Leo Park"].enumerated() {
      try ":PROPERTIES:\n:ID: bbbbbbbb-0000-4000-8000-00000000000\(index)\n:ORG2_ENTITY_TYPE: person\n:EMAIL: p\(index)@acme.test\n:END:\n#+title: \(name)\n"
        .write(to: notes.appendingPathComponent("person-\(index).org"), atomically: true, encoding: .utf8)
    }

    let suiteName = "WorkspaceAppsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      cli: Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent(".test-state/chat.json"),
      legacyDefaultsDomains: []
    )
    store.setWorkspaceRealtimeRefreshActive(false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.aiChatTranscriptSaverForTesting = {}
    store.setCorpusRoot(root, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()

    await store.refreshWorkspaceApps()
    XCTAssertNil(store.workspaceAppsError)
    XCTAssertEqual(store.workspaceApps.map(\.id), ["crm", "canvases"])
    XCTAssertFalse(store.isWorkspaceAppEnabled("crm"))
    XCTAssertEqual(store.suggestedWorkspaceApp?.id, "crm")
    XCTAssertFalse(WorkspaceSurface.sidebarCases(enabledApps: store.enabledWorkspaceAppIDs).contains(.people))

    let enabled = await store.setWorkspaceApp("crm", enabled: true)
    XCTAssertTrue(enabled)
    XCTAssertTrue(store.isWorkspaceAppEnabled("crm"))
    XCTAssertNil(store.suggestedWorkspaceApp)
    XCTAssertTrue(WorkspaceSurface.sidebarCases(enabledApps: store.enabledWorkspaceAppIDs).contains(.companies))
    let config = try String(contentsOf: root.appendingPathComponent("celorga.json"), encoding: .utf8)
    XCTAssertTrue(config.contains("\"crm\""))

    let path = root.standardizedFileURL.path
    await store.crm.load(cli: store.cli, root: path, force: true)
    XCTAssertNil(store.crm.error)
    let index = try XCTUnwrap(store.crm.index)
    XCTAssertEqual(index.people.count, 4)
    let acme = try XCTUnwrap(index.companies.first)
    XCTAssertEqual(acme.title, "Acme")
    XCTAssertEqual(acme.noteID, company)
    XCTAssertEqual(acme.stage, "prospect")
    XCTAssertEqual(acme.people.count, 4)
    XCTAssertEqual(acme.nextTask?.title, "Send pricing")
    XCTAssertEqual(index.people.first?.company?.title, "Acme")

    // One list read carries every entity's activity, so selecting a row needs no CLI call.
    let preloaded = try XCTUnwrap(store.crm.details[acme.key])
    XCTAssertEqual(preloaded.tasks.map(\.title), ["Send pricing"])
    XCTAssertEqual(store.crm.details.count, index.people.count + index.companies.count)
    XCTAssertTrue(index.stages.contains("customer"))
    XCTAssertNil(acme.lastTouchAt)

    // Marking stale keeps the current data visible until the next read replaces it.
    store.crm.markStale()
    XCTAssertNotNil(store.crm.details[acme.key])
    store.crm.details = [:]
    await store.crm.loadDetail(cli: store.cli, root: path, key: acme.key)
    XCTAssertNil(store.crm.detailErrors[acme.key])
    XCTAssertEqual(store.crm.details[acme.key]?.tasks.map(\.title), ["Send pricing"])

    store.makeSurfacePrimary(.companies)
    XCTAssertEqual(store.selectedSurface, .companies)
    await store.setWorkspaceApp("crm", enabled: false)
    XCTAssertEqual(store.selectedSurface, .home, "turning an app off leaves its page")
  }
}
