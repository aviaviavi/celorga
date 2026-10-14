import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class CelorgaNamesTests: XCTestCase {
  // MARK: Names

  func testPropertyNamesConvertBetweenSpellings() {
    XCTAssertEqual(CelorgaNames.celorgaName("ORG2_RUN_ID"), "CELORGA_RUN_ID")
    XCTAssertEqual(CelorgaNames.legacyName("CELORGA_RUN_ID"), "ORG2_RUN_ID")
    XCTAssertEqual(CelorgaNames.celorgaName("STATUS"), "STATUS")
    XCTAssertEqual(CelorgaNames.aliases("ORG2_RUN_ID"), ["CELORGA_RUN_ID", "ORG2_RUN_ID"])
    XCTAssertEqual(CelorgaNames.aliases("CELORGA_RUN_ID"), ["CELORGA_RUN_ID", "ORG2_RUN_ID"])
    XCTAssertEqual(CelorgaNames.aliases("ID"), ["ID"])
    XCTAssertEqual(
      CelorgaNames.withAliases(["WAITING_ON", "ORG2_WAITING_ON", "CELORGA_WAITING_ON"]),
      ["WAITING_ON", "CELORGA_WAITING_ON", "ORG2_WAITING_ON"]
    )
    XCTAssertTrue(CelorgaNames.isBrandName("celorga_run_id", "ORG2_RUN_ID"))
    XCTAssertFalse(CelorgaNames.isBrandName("RUN_ID", "ORG2_RUN_ID"))
  }

  func testPropertyLookupPrefersCelorgaAndReportsTheStoredKey() {
    XCTAssertEqual(CelorgaNames.property("ORG2_RUN_ID", in: ["ORG2_RUN_ID": "legacy"]), "legacy")
    XCTAssertEqual(CelorgaNames.property("ORG2_RUN_ID", in: ["CELORGA_RUN_ID": "modern"]), "modern")
    XCTAssertEqual(
      CelorgaNames.property("ORG2_RUN_ID", in: ["CELORGA_RUN_ID": "modern", "ORG2_RUN_ID": "legacy"]),
      "modern"
    )
    XCTAssertEqual(
      CelorgaNames.property("ORG2_RUN_ID", in: ["CELORGA_RUN_ID": " ", "ORG2_RUN_ID": "legacy"]),
      "legacy"
    )
    XCTAssertEqual(CelorgaNames.property("ORG2_RUN_ID", in: ["celorga_run_id": "lower"]), "lower")
    XCTAssertNil(CelorgaNames.property("ORG2_RUN_ID", in: [:]))

    XCTAssertEqual(CelorgaNames.propertyKey("ORG2_RUN_ID", in: ["CELORGA_RUN_ID": "x"]), "CELORGA_RUN_ID")
    XCTAssertEqual(CelorgaNames.propertyKey("ORG2_RUN_ID", in: ["ORG2_RUN_ID": "x"]), "ORG2_RUN_ID")
    XCTAssertNil(CelorgaNames.propertyKey("ORG2_RUN_ID", in: ["ID": "x"]))
  }

  func testEnvironmentLookupPrefersCelorgaAndMirrorsToLegacy() {
    let environment = [
      "CELORGA_REPO_ROOT": "/modern",
      "ORG2_REPO_ROOT": "/legacy",
      "CELORGA_INDEX_HOME": "/index",
      "ORG2_WORKSPACE_OPENCLAW_URL": "http://legacy",
      "CELORGA_EMPTY_LEGACY": "set",
      "ORG2_EMPTY_LEGACY": ""
    ]
    XCTAssertEqual(CelorgaNames.environment("ORG2_REPO_ROOT", in: environment), "/modern")
    XCTAssertEqual(CelorgaNames.environment("ORG2_INDEX_HOME", in: environment), "/index")
    XCTAssertEqual(CelorgaNames.environment("ORG2_WORKSPACE_OPENCLAW_URL", in: environment), "http://legacy")
    XCTAssertNil(CelorgaNames.environment("ORG2_MISSING", in: environment))

    let mirrored = CelorgaNames.mirroredEnvironment(environment)
    XCTAssertEqual(mirrored["ORG2_REPO_ROOT"], "/legacy", "An explicit legacy value is kept")
    XCTAssertEqual(mirrored["ORG2_INDEX_HOME"], "/index")
    XCTAssertEqual(mirrored["ORG2_EMPTY_LEGACY"], "set")
    XCTAssertEqual(mirrored["CELORGA_REPO_ROOT"], "/modern")
  }

  func testMirrorCelorgaEnvironmentSetsUnsetLegacyVariables() {
    let modern = "CELORGA_NAMES_TEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    let legacy = CelorgaNames.legacyName(modern)
    setenv(modern, "value", 1)
    defer {
      unsetenv(modern)
      unsetenv(legacy)
    }
    CelorgaNames.mirrorCelorgaEnvironment()
    XCTAssertEqual(ProcessInfo.processInfo.environment[legacy], "value")
  }

  // MARK: Schemas and tools

  func testSchemaIdsMatchInEitherNamespace() {
    XCTAssertTrue(CelorgaNames.schemaMatches("org2:agent-run:v1", "org2:agent-run:v1"))
    XCTAssertTrue(CelorgaNames.schemaMatches("celorga:agent-run:v1", "org2:agent-run:v1"))
    XCTAssertTrue(CelorgaNames.schemaMatches("org2:agent-run:v1", "celorga:agent-run:v1"))
    XCTAssertFalse(CelorgaNames.schemaMatches("celorga:agent-run:v2", "org2:agent-run:v1"))
    XCTAssertFalse(CelorgaNames.schemaMatches("openorg:agent-run:v1", "org2:agent-run:v1"))
    XCTAssertFalse(CelorgaNames.schemaMatches(nil, "org2:agent-run:v1"))
    XCTAssertEqual(CelorgaNames.legacySchemaID("celorga:corpus:v1"), "org2:corpus:v1")
    XCTAssertEqual(CelorgaNames.legacySchemaID("org2:corpus:v1"), "org2:corpus:v1")
  }

  func testToolNamesAcceptBothPrefixes() {
    XCTAssertEqual(CelorgaNames.legacyToolName("celorga_workspace_read"), "org2_workspace_read")
    XCTAssertEqual(CelorgaNames.legacyToolName("org2_workspace_read"), "org2_workspace_read")
    XCTAssertEqual(CelorgaNames.celorgaToolName("org2_thread_post"), "celorga_thread_post")
  }

  // MARK: Corpus files

  func testConfigFilePrefersCelorgaJSON() throws {
    let root = try temporaryDirectory("config")
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertNil(CelorgaNames.configFile(in: root))
    XCTAssertFalse(CelorgaNames.hasConfigFile(in: root))
    XCTAssertEqual(CelorgaNames.configFilePath(in: root).lastPathComponent, "celorga.json")

    try Data("{}".utf8).write(to: root.appendingPathComponent("org2.json"))
    XCTAssertEqual(CelorgaNames.configFile(in: root)?.lastPathComponent, "org2.json")
    XCTAssertEqual(CelorgaNames.configFilePath(in: root).lastPathComponent, "org2.json")

    try Data("{}".utf8).write(to: root.appendingPathComponent("celorga.json"))
    XCTAssertEqual(CelorgaNames.configFile(in: root)?.lastPathComponent, "celorga.json")
    XCTAssertTrue(CelorgaNames.isConfigFileName("celorga.json"))
    XCTAssertTrue(CelorgaNames.isConfigFileName("org2.json"))
    XCTAssertFalse(CelorgaNames.isConfigFileName("package.json"))
  }

  func testStateDirectoryUsesCelorgaOnlyOnceItExists() throws {
    let root = try temporaryDirectory("state")
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertEqual(CelorgaNames.stateDirectory(corpusRoot: root).lastPathComponent, ".org2")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".celorga").path))

    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".org2"), withIntermediateDirectories: true
    )
    XCTAssertEqual(CelorgaNames.stateDirectoryName(corpusRoot: root), ".org2")

    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".celorga"), withIntermediateDirectories: true
    )
    XCTAssertEqual(CelorgaNames.stateDirectory(corpusRoot: root).lastPathComponent, ".celorga")
    XCTAssertEqual(CelorgaNames.stateRelativePath("runs/r.org2", corpusRoot: root), ".celorga/runs/r.org2")
  }

  func testRunRecordPathsAreOrgUnlessALegacyRecordExists() throws {
    let root = try temporaryDirectory("run-records")
    defer { try? FileManager.default.removeItem(at: root) }
    let runs = root.appendingPathComponent(".org2/runs", isDirectory: true)
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)

    XCTAssertEqual(CelorgaNames.runRecordRelativePath(runID: "new", corpusRoot: root), ".org2/runs/new.org")

    try "".write(to: runs.appendingPathComponent("old.org2"), atomically: true, encoding: .utf8)
    XCTAssertEqual(CelorgaNames.runRecordRelativePath(runID: "old", corpusRoot: root), ".org2/runs/old.org2")

    try "".write(to: runs.appendingPathComponent("old.org"), atomically: true, encoding: .utf8)
    XCTAssertEqual(CelorgaNames.runRecordRelativePath(runID: "old", corpusRoot: root), ".org2/runs/old.org")
  }

  func testStateRelativePathsNormalizeToTheLegacyLayout() {
    XCTAssertEqual(CelorgaNames.legacyStateRelativePath(".celorga/runs/a.org2"), ".org2/runs/a.org2")
    XCTAssertEqual(CelorgaNames.legacyStateRelativePath(".org2/runs/a.org2"), ".org2/runs/a.org2")
    XCTAssertEqual(CelorgaNames.legacyStateRelativePath(".celorgaish/a"), ".celorgaish/a")
    XCTAssertTrue(CelorgaNames.isStateRelativePath(".celorga/ai-chat-inbox/x.json"))
    XCTAssertTrue(CelorgaNames.isStateRelativePath(".org2/runs/x.org2"))
    XCTAssertFalse(CelorgaNames.isStateRelativePath("notes/.org2.org"))
  }

  // MARK: Readers

  func testStarterCorpusDetectionAcceptsCelorgaJSON() throws {
    let documents = try temporaryDirectory("documents")
    defer { try? FileManager.default.removeItem(at: documents) }
    let legacyWorkspace = documents.appendingPathComponent("OpenOrg", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyWorkspace, withIntermediateDirectories: true)

    XCTAssertEqual(WorkspaceStore.starterCorpusURL(inDocuments: documents).lastPathComponent, "Celorga")

    try Data("{}".utf8).write(to: legacyWorkspace.appendingPathComponent("celorga.json"))
    XCTAssertEqual(WorkspaceStore.starterCorpusURL(inDocuments: documents).lastPathComponent, "OpenOrg")

    let existing = documents.appendingPathComponent("Migrated", isDirectory: true)
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
    try Data("notes".utf8).write(to: existing.appendingPathComponent("visible.org"))
    try Data("{}".utf8).write(to: existing.appendingPathComponent("celorga.json"))
    XCTAssertEqual(
      try WorkspaceStore.prepareAutomaticStarterCorpus(preferredRoot: existing).standardizedFileURL,
      existing.standardizedFileURL
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: existing.appendingPathComponent("org2.json").path))
  }

  func testHeadingWorkLinksReadCelorgaRunID() {
    let text = """
    * TODO Modern
    :PROPERTIES:
    :CELORGA_RUN_ID: run-modern
    :END:
    * TODO Legacy
    :PROPERTIES:
    :ORG2_RUN_ID: run-legacy
    :END:
    * TODO Both
    :PROPERTIES:
    :ORG2_RUN_ID: run-legacy
    :CELORGA_RUN_ID: run-modern
    :END:
    """
    let links = HeadingWorkStatus.links(in: text, baseLine: 1)
    XCTAssertEqual(links.map(\.runID), ["run-modern", "run-legacy", "run-modern"])
  }

  func testGooglePublicationBindingReadsAndUpdatesCelorgaProperties() throws {
    let source = """
    #+TITLE: Brief
    :PROPERTIES:
    :CELORGA_PUBLISH_GOOGLE_DOCS_FILE_ID: doc-modern
    :CELORGA_PUBLISH_GOOGLE_DOCS_URL: https://docs.google.com/document/d/doc-modern/edit
    :CELORGA_PUBLISH_GOOGLE_DOCS_VERSION: 3
    :END:
    """
    let binding = try XCTUnwrap(GoogleDrivePublicationBinding.binding(for: .googleDocs, in: source, line: nil))
    XCTAssertEqual(binding.fileID, "doc-modern")
    XCTAssertEqual(binding.version, "3")

    let next = GoogleDrivePublicationBinding(
      format: .googleDocs, fileID: "doc-modern", url: binding.url, version: "4",
      publishedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let updated = try XCTUnwrap(GoogleDrivePublicationBinding.sourceText(source, upserting: next))
    XCTAssertTrue(updated.contains(":CELORGA_PUBLISH_GOOGLE_DOCS_VERSION: 4"))
    XCTAssertFalse(updated.contains(":ORG2_PUBLISH_GOOGLE_DOCS_VERSION:"))
    XCTAssertFalse(updated.contains(":ORG2_PUBLISH_GOOGLE_DOCS_FILE_ID:"))
    // A property the drawer did not have yet keeps the legacy spelling.
    XCTAssertTrue(updated.contains(":ORG2_PUBLISH_GOOGLE_DOCS_PUBLISHED_AT:"))
  }

  func testProseStateReadsCelorgaMarkerAndWritesLegacyMarker() throws {
    let rendered = OrgProseDocument.render(OrgProseState())
    XCTAssertTrue(rendered.contains("ORG2_PROSE_STATE_V1"))
    let modern = "Intro\n\n" + rendered.replacingOccurrences(of: "ORG2_PROSE_STATE_V1", with: "CELORGA_PROSE_STATE_V1")
    let document = OrgProseDocument.parse(modern)
    XCTAssertNotNil(document.blockRange)
    XCTAssertNotNil(document.state)
  }

  func testOperationJournalReadsCelorgaStateDirectoryAndSchema() async throws {
    let root = try temporaryDirectory("journal")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root
      .appendingPathComponent(".celorga/ai-chat-inbox/operations", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    XCTAssertEqual(AIChatOperationJournal.operationsDirectory(corpusRoot: root).standardizedFileURL, directory.standardizedFileURL)

    let object: [String: Any] = [
      "schema": "celorga:ai-chat-operation:v1",
      "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "createdAt": "2026-10-08T10:00:00.000Z",
      "kind": "reopen-thread",
      "threadID": "thread-a",
    ]
    try JSONSerialization.data(withJSONObject: object)
      .write(to: directory.appendingPathComponent("1.json"))

    let scan = try await AIChatOperationJournal.load(corpusRoot: root)
    XCTAssertTrue(scan.issues.isEmpty, "\(scan.issues)")
    XCTAssertEqual(scan.entries.map(\.id), ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
  }

  private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-names-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
  }
}
