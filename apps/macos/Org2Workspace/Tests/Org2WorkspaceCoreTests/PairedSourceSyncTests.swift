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
}
