import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Server side of `POST /v1/sources/ID/sync` when the requested source is not
/// loaded yet: the reply must say why instead of always blaming config sync.
@MainActor
final class PairedSourceSyncTests: XCTestCase {
  private func makeStore(sourceListScript: String, configFile: String? = nil) throws -> (WorkspaceStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("paired-source-sync-\(UUID().uuidString)")
    let dist = root.appendingPathComponent("dist")
    let corpus = root.appendingPathComponent("corpus")
    for directory in [dist, corpus] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    if let configFile {
      try "{}\n".write(to: corpus.appendingPathComponent(configFile), atomically: true, encoding: .utf8)
    }
    let script = """
    const command = process.argv[2];
    const sub = process.argv[3];
    if (command === 'source' && sub === 'list') {
      \(sourceListScript)
    } else {
      process.stdout.write(JSON.stringify({sources:[]}));
    }
    """
    try script.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: root))
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(corpus, persistsDefault: false)
    return (store, root)
  }

  func testFailedSourceReloadReportsTheError() async throws {
    let (store, root) = try makeStore(sourceListScript: """
      process.stderr.write('Synthetic config failure: unexpected token');
      process.exit(1);
    """, configFile: "org2.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = await store.runSourceSyncForPairedClient(profileID: "team-calendar")
    XCTAssertFalse(result.ok)
    let message = try XCTUnwrap(result.message)
    XCTAssertTrue(message.contains("could not load its sources"), message)
    XCTAssertTrue(message.contains("Synthetic config failure"), message)
    XCTAssertFalse(message.contains("no source named"), message)
  }

  func testMissingSourceNamesTheLegacyConfigFileInUse() async throws {
    let (store, root) = try makeStore(sourceListScript: "process.stdout.write('[]');", configFile: "org2.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = await store.runSourceSyncForPairedClient(profileID: "team-calendar")
    XCTAssertFalse(result.ok)
    let message = try XCTUnwrap(result.message)
    XCTAssertTrue(message.contains("no source named team-calendar in org2.json"), message)
    XCTAssertFalse(message.contains("celorga.json"), message)
  }

  func testStuckSourceReloadIsReportedInsteadOfMissingSource() async throws {
    let (store, root) = try makeStore(sourceListScript: "process.stdout.write('[]');", configFile: "celorga.json")
    defer { try? FileManager.default.removeItem(at: root) }
    store.isLoadingSources = true
    let result = await store.runSourceSyncForPairedClient(profileID: "team-calendar", sourceLoadWait: .milliseconds(200))
    XCTAssertFalse(result.ok)
    let message = try XCTUnwrap(result.message)
    XCTAssertTrue(message.contains("still loading its sources"), message)
  }
  private func profile(_ json: String) throws -> WorkspaceSourceProfileStatus {
    try JSONDecoder().decode(WorkspaceSourceProfileStatus.self, from: Data(json.utf8))
  }

  /// slacrawl and notcrawl, and an email password command, may exist only on
  /// the paired server. When that server runs syncs, Run Now must not be gated
  /// on this Mac's own crawler setup or credentials.
  func testRunNowIgnoresThisMacsSetupWhenThePairedServerSyncs() throws {
    let suite = "PairedSourceSyncTests.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let slack = try profile("""
      {"id":"slack","type":"slack","enabled":true,"scopes":[],"rawZone":"raw/connectors/slack","reviewZone":"views/connectors/slack","ingestionLimit":5000,"syncArgs":[],"media":"metadata-only","binary":"slacrawl","binaryAvailable":false,"configAvailable":false,"ready":false}
      """)
    let email = try profile("""
      {"id":"clavi","type":"email","enabled":true,"scopes":[],"rawZone":"raw/connectors/email/clavi","reviewZone":"views/connectors/email/clavi","ingestionLimit":5000,"syncArgs":[],"media":"metadata-only","binary":"celorga (built-in IMAP)","binaryAvailable":true,"configAvailable":true,"ready":true,"credentialAvailable":false}
      """)

    let unpaired = WorkspaceStore(cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory), defaults: defaults, aiChatTranscriptURL: FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID()).json"), legacyDefaultsDomains: [])
    XCTAssertFalse(unpaired.sourceCanRunNow(slack))
    XCTAssertTrue(unpaired.sourceNeedsCredentialHere(email))
    XCTAssertFalse(unpaired.sourceCanRunNow(email))

    let pairing = OpenOrgServerPairing(
      endpoint: "http://127.0.0.1:48922", serverName: "Test server", hostRef: "press-trial",
      deviceID: UUID(), pairedAt: Date()
    )
    defaults.set(try MobileRemoteProtocol.encoder().encode(pairing), forKey: OpenOrgServerConnection.pairingKey)
    let paired = WorkspaceStore(cli: Org2CLI(repoRoot: FileManager.default.temporaryDirectory), defaults: defaults, aiChatTranscriptURL: FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID()).json"), legacyDefaultsDomains: [])
    paired.corpusAutomationHostRef = "press-trial"
    XCTAssertTrue(paired.connectedServerRunsSourceSyncs)
    XCTAssertTrue(paired.sourceCanRunNow(slack))
    XCTAssertFalse(paired.sourceNeedsCredentialHere(email))
    XCTAssertTrue(paired.sourceCanRunNow(email))
  }
}
