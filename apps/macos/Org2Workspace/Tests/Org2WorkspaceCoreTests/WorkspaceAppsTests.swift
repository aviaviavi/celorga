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

  private func crmEntity(_ json: String) throws -> CRMEntity {
    try JSONDecoder().decode(CRMEntity.self, from: Data(json.utf8))
  }

  private func crmEntityJSON(key: String, kind: String, source: String = "note", title: String, file: String?, emails: [String] = [], domains: [String] = [], aliases: [String] = [], company: String? = nil) -> String {
    let fileJSON = file.map { "\"\($0)\"" } ?? "null"
    let companyJSON = company.map { #"{"key":"id:c","title":"\#($0)","match":"explicit"}"# } ?? "null"
    return """
    {"key":"\(key)","kind":"\(kind)","source":"\(source)","id":null,"title":"\(title)","aliases":\(aliases),"file":\(fileJSON),"line":1,
     "stage":"prospect","stageSource":"property","emails":\(emails),"domains":\(domains),"role":"CTO","owner":"","company":\(companyJSON),
     "people":[],"ledgerAccounts":[],"openTaskCount":0,"meetingCount":0}
    """
  }

  func testPeopleAndCompaniesAreQuickOpenResultsThatReplaceTheirNotes() throws {
    let root = "/corpus"
    let acme = WorkspaceCRMSearchEntity(try crmEntity(crmEntityJSON(key: "id:acme", kind: "company", title: "Acme Robotics", file: "notes/acme-robotics.org", domains: ["acme.test"])), corpusRoot: root)
    let jane = WorkspaceCRMSearchEntity(try crmEntity(crmEntityJSON(key: "id:jane", kind: "person", title: "Jane Doe", file: "notes/jane-doe.org", emails: ["jane@acme.test"], company: "Acme Robotics")), corpusRoot: root)
    let outreach = WorkspaceCRMSearchEntity(try crmEntity(crmEntityJSON(key: "ledger:outreach/acme-labs", kind: "company", source: "ledger", title: "Acme Labs", file: "notes/outreach/accounts/acme-labs.org")), corpusRoot: root)
    XCTAssertEqual(jane.subtitle, "Acme Robotics · CTO · jane@acme.test")
    XCTAssertEqual(acme.kindLabel, "Company")
    XCTAssertEqual(outreach.kindLabel, "Company (outreach only)")
    XCTAssertNil(outreach.notePath)

    let noteFile = CorpusFile(path: "/corpus/notes/acme-robotics.org", relativePath: "notes/acme-robotics.org", modifiedAt: nil, byteCount: nil)
    let otherFile = CorpusFile(path: "/corpus/notes/acme-pricing.org", relativePath: "notes/acme-pricing.org", modifiedAt: nil, byteCount: nil)
    let files = [noteFile, otherFile].map { QuickOpenIndexedFile(file: $0, normalizedRelativePath: WorkspaceStore.normalizedQuickOpenCandidate($0.relativePath)) }
    let matches = WorkspaceStore.filterQuickOpenItemsForTesting(files: files, crmEntities: [acme, jane, outreach], query: "acme")
    XCTAssertEqual(matches.first, "crm:id:acme", "the company outranks files")
    XCTAssertTrue(matches.contains("crm:ledger:outreach/acme-labs"))
    XCTAssertTrue(matches.contains("file:\(otherFile.id)"))
    XCTAssertFalse(matches.contains("file:\(noteFile.id)"), "the company replaces its own note")
    XCTAssertLessThan(matches.firstIndex(of: "crm:id:acme")!, matches.firstIndex(of: "crm:ledger:outreach/acme-labs")!)
    XCTAssertEqual(WorkspaceStore.filterQuickOpenItemsForTesting(files: [], crmEntities: [acme, jane], query: "jane@acme"), ["crm:id:jane"])
    XCTAssertEqual(WorkspaceStore.filterQuickOpenItemsForTesting(files: [], crmEntities: [acme, jane], query: "jdoe"), [], "no scattered-letter matches for names")

    // Workspace Search: a person row replaces the page row for their note.
    let page = OrgRoamNodeReference(idValue: "jane", title: "Jane Doe", file: "/corpus/notes/jane-doe.org", line: 1, isPageNode: true)
    let items = WorkspaceStore.rankedWorkspaceSearchItems(corpusResults: [], files: [], chats: [], agentWork: [], pages: [page], crm: WorkspaceStore.searchCRMEntitiesForWorkspace([acme, jane], query: "jane", limit: 25), query: "jane")
    XCTAssertEqual(items.map(\.id), ["crm:id:jane"])
    XCTAssertEqual(items.first?.category, .people)
    XCTAssertTrue(WorkspaceSearchFilter.people.includes(items[0]))
    XCTAssertFalse(WorkspaceSearchFilter.pages.includes(items[0]))
    XCTAssertFalse(WorkspaceSearchFilter.available(crmEnabled: false).contains(.people))
    XCTAssertTrue(WorkspaceSearchFilter.available(crmEnabled: true).contains(.people))
    XCTAssertEqual(WorkspaceStore.searchCRMEntitiesForWorkspace([acme, jane], query: "acme.test", limit: 25).map(\.key).sorted(), ["id:acme", "id:jane"])
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

    // People and companies are Quick Open results once the app is on.
    XCTAssertEqual(store.crmSearchEntities.count, index.people.count + index.companies.count)
    let entity = try XCTUnwrap(store.crmSearchEntities.first { $0.key == acme.key })
    store.openCRMEntity(entity)
    XCTAssertEqual(store.selectedSurface, .companies)
    XCTAssertEqual(store.crm.selectedCompanyKey, acme.key)
    store.searchFilter = .people

    store.makeSurfacePrimary(.companies)
    XCTAssertEqual(store.selectedSurface, .companies)
    await store.setWorkspaceApp("crm", enabled: false)
    XCTAssertEqual(store.selectedSurface, .home, "turning an app off leaves its page")
    XCTAssertTrue(store.crmSearchEntities.isEmpty, "people and companies leave Quick Open with the app")
    XCTAssertEqual(store.searchFilter, .all)
  }
}
