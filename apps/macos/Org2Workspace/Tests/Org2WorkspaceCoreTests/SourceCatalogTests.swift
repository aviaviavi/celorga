import XCTest
@testable import Org2WorkspaceCore

final class SourceCatalogTests: XCTestCase {
  private func profile(_ json: String) throws -> WorkspaceSourceProfileStatus {
    try JSONDecoder().decode(WorkspaceSourceProfileStatus.self, from: Data(json.utf8))
  }

  private func config(_ draft: WorkspaceSourceDraft) throws -> [String: JSONValue] {
    try XCTUnwrap(try draft.sourceConfig().objectValue)
  }

  func testCatalogCoversEveryRuntimeSourceTypeWithAFormAndSecret() {
    // Mirrors EXTERNAL_SOURCE_TYPES in src/sourceRuntime.ts.
    XCTAssertEqual(WorkspaceSourceCatalog.types.map(\.id), ["slack", "notion", "email", "google-calendar"])
    for type in WorkspaceSourceCatalog.types {
      XCTAssertFalse(type.fields.isEmpty, type.id)
      XCTAssertNotNil(type.field("since"), "\(type.id) offers the shared initial window")
      XCTAssertEqual(Set(type.fields.map(\.id)).count, type.fields.count, "\(type.id) field ids are unique")
      let secret = try? XCTUnwrap(type.secret, "\(type.id) offers a Keychain credential")
      XCTAssertFalse(secret?.environmentVariable.isEmpty ?? true)
      XCTAssertTrue(type.agentSetupPrompt.contains("celorga source add"), "\(type.id) keeps agent setup as an option")
      XCTAssertTrue(type.agentSetupPrompt.contains("Never put it in celorga.json,"))
      if !type.fields.contains(where: \.isRequired) {
        XCTAssertNil(WorkspaceSourceDraft(type: type).validationMessage, "\(type.id) defaults are valid")
      }
    }
    XCTAssertEqual(WorkspaceSourceCatalog.type("Notion")?.id, "notion")
    XCTAssertNil(WorkspaceSourceCatalog.type("discord"))
  }

  func testSourcesViewHasNoPerTypeButtons() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let contentView = try SplitSourceText.read(packageRoot.appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift"))
    for hardCoded in [#"profile.type == "email""#, #"profile.type == "notion""#, "Add Email Source", #""Connect Notion""#] {
      XCTAssertFalse(contentView.contains(hardCoded), hardCoded)
    }
    XCTAssertTrue(contentView.contains("ForEach(WorkspaceSourceCatalog.types)"))
    XCTAssertTrue(contentView.contains("SourceEditorSheet(draft: draft)"))
  }

  func testSecretRequirementFollowsTheCrawlerMode() {
    XCTAssertTrue(WorkspaceSourceCatalog.email.requiresSecret(syncArgs: []))
    XCTAssertTrue(WorkspaceSourceCatalog.notion.requiresSecret(syncArgs: ["--source", "api"]))
    XCTAssertFalse(WorkspaceSourceCatalog.notion.requiresSecret(syncArgs: ["--source", "desktop"]))
    XCTAssertFalse(WorkspaceSourceCatalog.slack.requiresSecret(syncArgs: ["--source", "bot"]))
  }

  func testSlackDraftBuildsSourceEntryWithoutTheToken() throws {
    var draft = WorkspaceSourceDraft(type: WorkspaceSourceCatalog.slack)
    draft.values["workspaceId"] = " T01 "
    draft.values["scopes"] = "eng, , design"
    draft.secret = "xoxb-secret"
    XCTAssertEqual(try config(draft), [
      "type": .string("slack"),
      "enabled": .bool(true),
      "workspaceId": .string("T01"),
      "scopes": .array([.string("eng"), .string("design")]),
      "syncArgs": .array([.string("--source"), .string("bot"), .string("--latest-only")]),
      "ingestion": .object(["since": .string("14d")]),
    ])
    let arguments = try draft.arguments(corpusRoot: "/corpus")
    XCTAssertEqual(Array(arguments.prefix(4)), ["source", "add", "slack", "--source-json"])
    XCTAssertEqual(Array(arguments.suffix(4)), ["--dir", "/corpus", "--apply", "--json"])
    XCTAssertFalse(arguments.joined().contains("xoxb-secret"))
  }

  func testNotionDraftMapsModeAndTeamspaces() throws {
    var draft = WorkspaceSourceDraft(type: WorkspaceSourceCatalog.notion)
    draft.setValue("desktop", for: "syncSource")
    draft.values["scopes"] = "Scarf"
    draft.values["since"] = ""
    let config = try config(draft)
    XCTAssertEqual(config["syncArgs"], .array([.string("--source"), .string("desktop")]))
    XCTAssertEqual(config["scopes"], .array([.string("Scarf")]))
    XCTAssertNil(config["ingestion"], "an empty optional value is omitted for a new source")
  }

  func testEmailDraftBuildsNestedAccountAndLinksPortToSecurity() throws {
    var draft = WorkspaceSourceDraft(type: WorkspaceSourceCatalog.email)
    XCTAssertEqual(draft.profileID, "mail")
    XCTAssertNotNil(draft.validationMessage)
    draft.values["host"] = "imap.example.com"
    draft.values["username"] = "avi@example.com"
    draft.values["mailboxes"] = "INBOX, Archive"
    draft.setValue("starttls", for: "security")
    XCTAssertEqual(draft.value("port"), "143")
    draft.values["port"] = "1143"
    draft.setValue("tls", for: "security")
    XCTAssertEqual(draft.value("port"), "1143", "a custom port is kept")
    draft.secret = "hunter2"
    XCTAssertFalse(draft.isVisible(try XCTUnwrap(WorkspaceSourceCatalog.email.field("smtpPort"))))
    var account = try XCTUnwrap(try config(draft)["email"]?.objectValue)
    XCTAssertNil(account["smtp"])
    draft.values["smtpHost"] = "smtp.example.com"
    account = try XCTUnwrap(try config(draft)["email"]?.objectValue)
    XCTAssertEqual(account, [
      "host": .string("imap.example.com"),
      "security": .string("tls"),
      "port": .integer(1143),
      "username": .string("avi@example.com"),
      "mailboxes": .array([.string("INBOX"), .string("Archive")]),
      "smtp": .object(["host": .string("smtp.example.com"), "port": .integer(587)]),
    ])
    XCTAssertNil(try config(draft)["syncArgs"])
    XCTAssertFalse(try draft.arguments(corpusRoot: "/c").joined().contains("hunter2"))
    draft.values["port"] = "99999"
    XCTAssertThrowsError(try draft.sourceConfig())
    draft.values["port"] = "993"
    draft.profileID = "bad name"
    XCTAssertThrowsError(try draft.arguments(corpusRoot: "/c"))
  }

  func testEditingAnExistingSlackProfilePreservesCustomSyncArgsAndClearsValues() throws {
    let existing = try profile(#"""
    {"id":"slack","type":"slack","enabled":true,"scopes":[],"workspaceId":"T01RTMAAM1B","rawZone":"raw/connectors/slack",
     "reviewZone":"views/connectors/slack","ingestionSince":"14d","ingestionLimit":5000,
     "syncArgs":["--source","bot","--auto-join=false","--latest-only","--since","14d"],"media":"metadata-only",
     "bindingPath":"/x","binary":"slacrawl","binaryAvailable":true,"configAvailable":true,"ready":true}
    """#)
    var draft = try XCTUnwrap(WorkspaceSourceDraft(editing: existing))
    XCTAssertTrue(draft.isEditing)
    XCTAssertEqual(draft.value("workspaceId"), "T01RTMAAM1B")
    XCTAssertEqual(draft.value("syncSource"), "bot")
    XCTAssertEqual(draft.value("since"), "14d")

    // Unchanged mode leaves syncArgs alone; cleared values become null removals.
    draft.values["workspaceId"] = ""
    var config = try config(draft)
    XCTAssertNil(config["type"], "updates never change the type")
    XCTAssertNil(config["syncArgs"])
    XCTAssertEqual(config["workspaceId"], .null)
    XCTAssertEqual(config["scopes"], .null)
    XCTAssertTrue(try draft.arguments(corpusRoot: "/c").contains("--update"))

    draft.setValue("desktop", for: "syncSource")
    config = try self.config(draft)
    XCTAssertEqual(config["syncArgs"], .array(["--source", "desktop", "--auto-join=false", "--latest-only", "--since", "14d"].map(JSONValue.string)))
  }

  func testEditingEmailRoundTripsTheAccount() throws {
    let existing = try profile(#"""
    {"id":"mail","type":"email","enabled":true,"scopes":[],"rawZone":"r","reviewZone":"v","ingestionLimit":5000,"syncArgs":[],
     "media":"metadata-only","bindingPath":"/x","binary":"org2","binaryAvailable":true,"configAvailable":true,"ready":true,
     "email":{"host":"imap.example.com","port":993,"security":"tls","username":"a@example.com","mailboxes":["INBOX","Sent"],
              "smtp":{"host":"smtp.example.com","port":465}}}
    """#)
    XCTAssertTrue(existing.usesStoredCredential)
    var draft = try XCTUnwrap(WorkspaceSourceDraft(editing: existing))
    XCTAssertEqual(draft.value("mailboxes"), "INBOX, Sent")
    XCTAssertEqual(draft.value("smtpPort"), "465")
    draft.values["smtpHost"] = ""
    let account = try XCTUnwrap(try config(draft)["email"]?.objectValue)
    XCTAssertNil(account["smtp"], "clearing SMTP drops it from the replaced email block")
    XCTAssertFalse(account.values.contains(.null))
  }
}
