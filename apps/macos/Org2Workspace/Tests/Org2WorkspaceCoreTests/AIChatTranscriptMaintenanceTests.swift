import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Chat-storage maintenance (saves, periodic repair, and post-commit
/// collection) must not redo full-history work on an unchanged store, while
/// still noticing changed or corrupt files and never deleting retained data.
final class AIChatTranscriptMaintenanceTests: XCTestCase {
  private var root: URL!
  private let settings = AIChatThreadSettlementSettings()

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-chat-maintenance-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    AIChatTranscriptStore.shared.setGarbageCollectionIntervalForTesting(nil)
    try? FileManager.default.removeItem(at: root)
  }

  func testUnchangedStoreMaintenanceReusesDecodedManifestsAndShardAttributes() throws {
    let url = root.appendingPathComponent("openclaw-chat.json")
    var threads = (0..<8).map { index in
      AIChatThread(title: "Thread \(index)", sessionKey: "thread-\(index)", messages: [
        AIChatMessage(role: .assistant, content: "reply \(index)")
      ])
    }
    // Four writers share one store, as a laptop, a server, and repair heads do.
    for writer in 0..<4 {
      setWriter("writer-\(writer)", for: url)
      threads[writer] = threads[writer].replacingMessages(
        threads[writer].messages + [AIChatMessage(role: .assistant, content: "from writer \(writer)")]
      )
      try flush(threads, to: url)
    }
    XCTAssertEqual(try names(in: storeURL(url).appendingPathComponent("heads")).count, 4)
    let shardFiles = try names(in: storeURL(url).appendingPathComponent("threads")).count

    let store = AIChatTranscriptStore.shared
    func maintenancePass() throws {
      XCTAssertNotNil(store.loadCommittedIfAvailable(legacyURL: url))
      XCTAssertFalse(try store.repair(legacyURL: url, apply: false).changed)
      XCTAssertTrue(AIChatTranscriptStore.collectGarbageForTesting(legacyURL: url, shouldYield: { false }))
    }
    try maintenancePass()
    let decodes = AIChatTranscriptStore.manifestDecodeCountForTesting()
    for _ in 0..<3 { try maintenancePass() }
    XCTAssertEqual(
      AIChatTranscriptStore.manifestDecodeCountForTesting(), decodes,
      "Unchanged immutable manifests are decoded once per file version"
    )

    // Each pass examines a shard file at most once, however many writer
    // heads and previous commits name it.
    let beforeCollection = AIChatTranscriptStore.shardStatCountForTesting()
    XCTAssertTrue(AIChatTranscriptStore.collectGarbageForTesting(legacyURL: url, shouldYield: { false }))
    XCTAssertLessThanOrEqual(AIChatTranscriptStore.shardStatCountForTesting() - beforeCollection, shardFiles)
    let beforeRepair = AIChatTranscriptStore.shardStatCountForTesting()
    _ = try store.repair(legacyURL: url, apply: false)
    XCTAssertLessThanOrEqual(AIChatTranscriptStore.shardStatCountForTesting() - beforeRepair, shardFiles)

    // A new commit is read once; everything else stays cached.
    setWriter("writer-0", for: url)
    threads[5] = threads[5].replacingMessages(threads[5].messages + [AIChatMessage(role: .user, content: "new")])
    try flush(threads, to: url)
    try maintenancePass()
    let afterSave = AIChatTranscriptStore.manifestDecodeCountForTesting()
    XCTAssertLessThanOrEqual(afterSave - decodes, 3, "Only the new commit and the head it supersedes are read")
    try maintenancePass()
    XCTAssertEqual(AIChatTranscriptStore.manifestDecodeCountForTesting(), afterSave)
    let loaded = try XCTUnwrap(store.loadIfAvailable(legacyURL: url))
    XCTAssertEqual(
      store.loadAllThreads(replacingMetadata: loaded.snapshot.threads, legacyURL: url)
        .first { $0.id == threads[5].id }?.messages.last?.content,
      "new"
    )
  }

  func testManifestChangedInPlaceIsReadAgainAndCorruptionIsDetected() throws {
    let url = root.appendingPathComponent("openclaw-chat.json")
    setWriter("writer-0", for: url)
    let thread = AIChatThread(title: "Thread", sessionKey: "thread", messages: [
      AIChatMessage(role: .assistant, content: "first")
    ])
    try flush([thread], to: url)
    try flush([thread.replacingMessages(thread.messages + [AIChatMessage(role: .assistant, content: "second")])], to: url)
    XCTAssertNoThrow(try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: false))
    XCTAssertEqual(
      AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: url)?.recoveryStatus, .healthy
    )

    // Flip one byte without changing the size or modification date. The
    // status-change time still differs, so the cached decode is not reused.
    let manifestURL = try currentManifestURL(url)
    let modified = try XCTUnwrap(
      try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date
    )
    let handle = try FileHandle(forUpdating: manifestURL)
    let bytes = try Data(contentsOf: manifestURL)
    let offset = UInt64(bytes.count / 2)
    try handle.seek(toOffset: offset)
    let original = bytes[bytes.index(bytes.startIndex, offsetBy: Int(offset))]
    try handle.write(contentsOf: Data([original == UInt8(ascii: " ") ? UInt8(ascii: "\t") : UInt8(ascii: " ")]))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: manifestURL.path)
    XCTAssertEqual(try Data(contentsOf: manifestURL).count, bytes.count)

    XCTAssertThrowsError(
      try AIChatTranscriptStore.shared.repair(legacyURL: url, apply: false),
      "A corrupt committed manifest must be detected, not served from cache"
    )
    let recovered = try XCTUnwrap(AIChatTranscriptStore.shared.loadCommittedIfAvailable(legacyURL: url))
    XCTAssertNotEqual(recovered.recoveryStatus, .healthy)
    XCTAssertEqual(recovered.snapshot.threads.first?.messages.first?.content, "first")
  }

  func testPostCommitCollectionRunsAtMostOncePerIntervalAndStillRunsWhenDue() throws {
    let url = root.appendingPathComponent("openclaw-chat.json")
    setWriter("writer-0", for: url)
    let store = AIChatTranscriptStore.shared
    let thread = AIChatThread(title: "Thread", sessionKey: "thread", messages: [])
    try flush([thread], to: url)
    store.setGarbageCollectionIntervalForTesting(5)
    let threadsURL = storeURL(url).appendingPathComponent("threads")
    let firstOrphan = try agedOrphan(named: "first-orphan.json", in: threadsURL)
    let fresh = threadsURL.appendingPathComponent("fresh-sync-artifact.json")
    try Data("still syncing".utf8).write(to: fresh)

    let runsBefore = AIChatTranscriptStore.garbageCollectionRunCountForTesting(legacyURL: url)
    var messages: [AIChatMessage] = []
    for index in 0..<5 {
      messages.append(AIChatMessage(role: .assistant, content: "save \(index)"))
      try flush([thread.replacingMessages(messages)], to: url)
      if index == 0 {
        // The first due collection runs right after the commit.
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstOrphan.path))
        _ = try agedOrphan(named: "second-orphan.json", in: threadsURL)
      }
    }
    XCTAssertLessThanOrEqual(
      AIChatTranscriptStore.garbageCollectionRunCountForTesting(legacyURL: url) - runsBefore, 1,
      "Saves inside the interval do not start another full collection"
    )
    let secondOrphan = threadsURL.appendingPathComponent("second-orphan.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondOrphan.path))

    // No further save arrives; the deferred collection still runs once due.
    let deadline = Date().addingTimeInterval(20)
    while FileManager.default.fileExists(atPath: secondOrphan.path), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondOrphan.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "Fresh sync artifacts keep their grace interval")
    store.waitUntilIdleForTesting()
    let loaded = try XCTUnwrap(store.loadCommittedIfAvailable(legacyURL: url))
    XCTAssertEqual(loaded.snapshot.threads.first?.messages.map(\.content), messages.map(\.content))
  }

  func testConcurrentSavesRepairAndCollectionKeepEveryMessage() throws {
    let url = root.appendingPathComponent("openclaw-chat.json")
    setWriter("writer-0", for: url)
    let store = AIChatTranscriptStore.shared
    store.setGarbageCollectionIntervalForTesting(0)
    let thread = AIChatThread(title: "Thread", sessionKey: "thread", messages: [])
    try flush([thread], to: url)

    let stop = Flag()
    let repairs = DispatchGroup()
    for _ in 0..<2 {
      repairs.enter()
      DispatchQueue.global().async {
        while !stop.value {
          // Repair may refuse while saves land; it must never corrupt them.
          _ = try? store.repair(legacyURL: url, apply: true, onlyIfChanged: true)
          _ = store.loadCommittedIfAvailable(legacyURL: url)
        }
        repairs.leave()
      }
    }
    var messages: [AIChatMessage] = []
    for index in 0..<20 {
      messages.append(AIChatMessage(role: .assistant, content: "message \(index)"))
      try store.flush(
        AIChatTranscriptSnapshot(
          threads: [thread.replacingMessages(messages)],
          selectedThreadID: thread.id,
          settlementSettings: settings,
          knownThreadIDs: [thread.id]
        ),
        legacyURL: url
      )
    }
    stop.value = true
    XCTAssertEqual(repairs.wait(timeout: .now() + 60), .success)
    store.waitUntilIdleForTesting()
    XCTAssertTrue(AIChatTranscriptStore.collectGarbageForTesting(legacyURL: url, shouldYield: { false }))

    let loaded = try XCTUnwrap(store.loadCommittedIfAvailable(legacyURL: url))
    XCTAssertEqual(loaded.recoveryStatus, .healthy)
    XCTAssertEqual(loaded.snapshot.threads.first?.messages.map(\.id), messages.map(\.id))
    XCTAssertNoThrow(try store.repair(legacyURL: url, apply: false))
  }

  func testCollectionKeepsAgedShardsOfARecentBranchTipAndRemembersInvalidTips() throws {
    let url = root.appendingPathComponent("openclaw-chat.json")
    let store = AIChatTranscriptStore.shared
    let thread = AIChatThread(title: "Thread", sessionKey: "thread", messages: [
      AIChatMessage(role: .assistant, content: "trunk")
    ])
    setWriter("writer-trunk", for: url)
    try flush([thread], to: url)
    let trunkShards = try names(in: storeURL(url).appendingPathComponent("threads"))

    // A synced branch whose writer head is gone. Loading reconciles its tip,
    // but the tip's parent is retained only as a recent branch commit, and
    // only that commit names its shard.
    setWriter("writer-branch", for: url)
    try flush([thread.replacingMessages([AIChatMessage(role: .assistant, content: "branch 1")])], to: url)
    try flush([thread.replacingMessages([AIChatMessage(role: .assistant, content: "branch 2")])], to: url)
    let branchHead = storeURL(url).appendingPathComponent("heads/writer-branch.json")
    try FileManager.default.removeItem(at: branchHead)
    let branchShards = try names(in: storeURL(url).appendingPathComponent("threads")).subtracting(trunkShards)
    XCTAssertEqual(branchShards.count, 2)

    let threadsURL = storeURL(url).appendingPathComponent("threads")
    let old = Date().addingTimeInterval(-31 * 24 * 60 * 60)
    for name in try names(in: threadsURL) {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: threadsURL.appendingPathComponent(name).path)
    }
    let orphan = try agedOrphan(named: "orphan.json", in: threadsURL)

    XCTAssertTrue(AIChatTranscriptStore.collectGarbageForTesting(legacyURL: url, shouldYield: { false }))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "Unreferenced old shards are still collected")
    XCTAssertTrue(try names(in: threadsURL).isSuperset(of: branchShards.union(trunkShards)),
      "Aged shards of recent tips and heads are retained")

    // A recent file whose lineage reads but whose commit is invalid forces
    // the exact scan. Its verdict is remembered per file version.
    let trunkHead = try JSONSerialization.jsonObject(
      with: Data(contentsOf: storeURL(url).appendingPathComponent("heads/writer-trunk.json"))
    ) as? [String: Any]
    let trunkCommit = try XCTUnwrap((trunkHead?["currentManifest"] as? String)?.replacingOccurrences(of: ".json", with: ""))
    let invalidID = UUID().uuidString.lowercased()
    let invalid: [String: Any] = [
      "schema": "org2:ai-chat-transcript-manifest:v2", "version": 2, "generation": 99,
      "commitID": invalidID, "parentCommitID": trunkCommit, "threads": "not a list",
      "settlementSettings": [:] as [String: Any],
    ]
    try JSONSerialization.data(withJSONObject: invalid)
      .write(to: storeURL(url).appendingPathComponent("manifests/\(invalidID).json"))
    let exactBefore = AIChatTranscriptStore.garbageCollectionExactScanCountForTesting()
    XCTAssertTrue(AIChatTranscriptStore.collectGarbageForTesting(legacyURL: url, shouldYield: { false }))
    XCTAssertEqual(AIChatTranscriptStore.garbageCollectionExactScanCountForTesting(), exactBefore + 1)
    let decodes = AIChatTranscriptStore.manifestDecodeCountForTesting()
    XCTAssertTrue(AIChatTranscriptStore.collectGarbageForTesting(legacyURL: url, shouldYield: { false }))
    XCTAssertEqual(AIChatTranscriptStore.manifestDecodeCountForTesting(), decodes,
      "An invalid commit is not decoded again on the next collection: \(AIChatTranscriptStore.recentManifestDecodesForTesting().suffix(3))")
    XCTAssertTrue(try names(in: threadsURL).isSuperset(of: branchShards.union(trunkShards)))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: storeURL(url).appendingPathComponent("manifests/\(invalidID).json").path
    ), "A recent invalid file is evidence and stays inside its grace interval")
    // Unseen complete commits are synced branches; the newest one is loaded.
    XCTAssertEqual(
      store.loadCommittedIfAvailable(legacyURL: url)?.snapshot.threads.first?.messages.first?.content,
      "branch 2"
    )
  }

  // MARK: Helpers

  private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
      get { lock.lock(); defer { lock.unlock() }; return storage }
      set { lock.lock(); storage = newValue; lock.unlock() }
    }
  }

  private func setWriter(_ id: String, for url: URL) {
    AIChatTranscriptStore.shared.setWriterIdentityForTesting(
      AIChatTranscriptWriterIdentity(id: id, label: id), legacyURL: url
    )
    addTeardownBlock {
      AIChatTranscriptStore.shared.setWriterIdentityForTesting(nil, legacyURL: url)
    }
  }

  private func flush(_ threads: [AIChatThread], to url: URL) throws {
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: threads.first?.id,
        settlementSettings: settings,
        knownThreadIDs: Set(threads.map(\.id))
      ),
      legacyURL: url
    )
    AIChatTranscriptStore.shared.waitUntilIdleForTesting()
  }

  private func storeURL(_ transcriptURL: URL) -> URL {
    AIChatTranscriptStore.storeDirectory(for: transcriptURL)
  }

  private func names(in directory: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") })
  }

  private func currentManifestURL(_ transcriptURL: URL) throws -> URL {
    let heads = storeURL(transcriptURL).appendingPathComponent("heads")
    let headName = try XCTUnwrap(try names(in: heads).first)
    let head = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: heads.appendingPathComponent(headName))) as? [String: Any]
    )
    return storeURL(transcriptURL).appendingPathComponent(
      "manifests/\(try XCTUnwrap(head["currentManifest"] as? String))"
    )
  }

  private func agedOrphan(named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data("unreferenced \(name)".utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-31 * 24 * 60 * 60)], ofItemAtPath: url.path
    )
    return url
  }
}
