import CryptoKit
import Darwin
import Foundation

struct AIChatTranscriptSnapshot: Sendable {
  let threads: [AIChatThread]
  let selectedThreadID: UUID?
  let settlementSettings: AIChatThreadSettlementSettings
  var knownThreadIDs: Set<UUID>? = nil
}

enum AIChatTranscriptRecoveryStatus: Equatable, Sendable {
  case healthy
  case recoveredPreviousManifest
  case unrecoverable(String)

  var blocksWrites: Bool {
    if case .unrecoverable = self { return true }
    return false
  }
}

struct AIChatTranscriptLoadResult: Sendable {
  let snapshot: AIChatTranscriptSnapshot
  let unloadedThreadIDs: Set<UUID>
  let recoveryStatus: AIChatTranscriptRecoveryStatus
}

/// Identifies one process that commits to a (possibly replicated) transcript
/// store. Each writer owns exactly one head file, so replication tools such as
/// Syncthing never see two machines modify the same path.
public struct AIChatTranscriptWriterIdentity: Sendable, Equatable {
  public let id: String
  public let label: String

  public init(id rawID: String, label: String) {
    let sanitized = Self.sanitized(rawID)
    self.id = sanitized.isEmpty ? UUID().uuidString.lowercased() : sanitized
    self.label = label
  }

  static func sanitized(_ raw: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    let lowered = raw.lowercased().map { allowed.contains($0) ? $0 : "-" }
    return String(String(lowered).split(separator: "-", omittingEmptySubsequences: true)
      .joined(separator: "-").prefix(96))
  }

  /// A stable per-installation identity. The ID is persisted in the calling
  /// process's defaults domain, so the desktop app and a headless server on
  /// the same Mac remain distinct writers.
  public static func persistent(
    defaults: UserDefaults = .standard,
    label: String? = nil
  ) -> AIChatTranscriptWriterIdentity {
    let key = "org2.aiChatTranscriptWriterID"
    let id: String
    if let existing = defaults.string(forKey: key), !sanitized(existing).isEmpty {
      id = existing
    } else {
      id = UUID().uuidString.lowercased()
      defaults.set(id, forKey: key)
    }
    let resolvedLabel = label
      ?? Host.current().localizedName
      ?? ProcessInfo.processInfo.hostName
    return AIChatTranscriptWriterIdentity(id: id, label: resolvedLabel)
  }
}

/// A coalescing, serial persistence service for AI chat state.
///
/// Every writer owns one head file under `heads/`. A head is that writer's
/// commit point: it references immutable, versioned manifests, each of which
/// references immutable, content-addressed thread shards and attachment blobs.
/// Readers select the newest complete head and reconcile every other head or
/// unseen immutable manifest, merging divergent revisions of one conversation
/// by message identity instead of choosing a single winner. No path is ever
/// rewritten by two machines, so synchronized replicas do not produce
/// conflict copies. The historical `migration-marker.json` is still read for
/// compatibility and is created once for older builds, but never rewritten.
final class AIChatTranscriptStore: @unchecked Sendable {
  static let shared = AIChatTranscriptStore()
  static let eagerWorkingSetLimit = 16
  static let headsDirectoryName = "heads"
  private static let garbageCollectionGraceInterval: TimeInterval = 30 * 24 * 60 * 60
  private static let manifestAncestryLimit = 32
  private static let tombstoneLimit = 512

#if DEBUG
  private final class RecoveryCandidateDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func reset() {
      lock.lock()
      value = 0
      lock.unlock()
    }

    func increment() {
      lock.lock()
      value += 1
      lock.unlock()
    }

    func read() -> Int {
      lock.lock()
      defer { lock.unlock() }
      return value
    }
  }

  private static let recoveryCandidateDecodeCounter = RecoveryCandidateDecodeCounter()
  private static let threadShardDecodeCounter = RecoveryCandidateDecodeCounter()

  static func resetRecoveryCandidateDecodeCountForTesting() {
    recoveryCandidateDecodeCounter.reset()
  }

  static func recoveryCandidateDecodeCountForTesting() -> Int {
    recoveryCandidateDecodeCounter.read()
  }

  static func resetThreadShardDecodeCountForTesting() {
    threadShardDecodeCounter.reset()
  }

  static func threadShardDecodeCountForTesting() -> Int {
    threadShardDecodeCounter.read()
  }
#endif

  private struct PendingWrite {
    let generation: UInt64
    let legacyURL: URL
    let snapshot: AIChatTranscriptSnapshot
    let bases: [UUID: AdoptedThreadBase]
  }

  private struct PersistenceWaiter {
    let generation: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private let condition = NSCondition()
  private let queue = DispatchQueue(
    label: "org.org2.workspace.ai-chat-transcript-store",
    qos: .utility
  )
  private var nextGeneration: UInt64 = 0
  private var pendingWrites: [String: PendingWrite] = [:]
  private var exactPendingWrites: [PendingWrite] = []
  private var persistedGenerations: [String: UInt64] = [:]
  private var failedGenerations: [String: (generation: UInt64, error: Error)] = [:]
  private var latestSnapshots: [String: PendingWrite] = [:]
  private var persistenceWaiters: [String: [PersistenceWaiter]] = [:]
  private var validatedStoreStates: [String: StoreState] = [:]
  private var suspendedWritePathsForTesting: Set<String> = []
  private var garbageCollectionPaths: Set<String> = []
  private var isDraining = false
  private var configuredWriterIdentity: AIChatTranscriptWriterIdentity?
  private var writerIdentityOverridesForTesting: [String: AIChatTranscriptWriterIdentity] = [:]
  /// The message list each hydrated in-memory conversation was derived from,
  /// per store. Writes use it as the common ancestor of a three-way merge so
  /// a replica's concurrent messages are kept and local deletions are honored.
  private var adoptedBases: [String: [UUID: AdoptedThreadBase]] = [:]
  private var adoptionSequence: UInt64 = 0
  private var repairFingerprints: [String: String] = [:]
  private var repairReports: [String: AIChatTranscriptRepairReport] = [:]

  private init() {}

  /// Serial with this process's saves. A machine-local advisory lock also
  /// prevents two headless invocations from replacing the same repair head.
  func repair(
    legacyURL: URL, apply: Bool, expectedRevision: String? = nil, onlyIfChanged: Bool = false
  ) throws -> AIChatTranscriptRepairReport {
    try queue.sync {
      let storeURL = Self.storeDirectory(for: legacyURL)
      let lockName = "openorg-chat-repair-\(Self.digest(Data(storeURL.resolvingSymlinksInPath().path.utf8))).lock"
      let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(lockName)
      let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
      guard descriptor >= 0 else { throw TranscriptStoreError.unsafeStorePath }
      defer { Darwin.close(descriptor) }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw TranscriptStoreError.unrecoverableStore("Another local chat repair is in progress; retry later.")
      }
      let revision = try Self.repairFingerprint(storeURL: storeURL)
      if let expectedRevision, expectedRevision != revision {
        throw TranscriptStoreError.unrecoverableStore("Chat storage changed since the repair preview; preview it again.")
      }
      if onlyIfChanged, repairFingerprints[storeURL.path] == revision {
        let prior = repairReports[storeURL.path]
        return AIChatTranscriptRepairReport(schema: "org2:ai-chat-repair:v1", applied: false,
          changed: false, checked: false, revision: revision, threadCount: prior?.threadCount ?? 0,
          mergedShardCount: 0, warnings: prior?.warnings ?? [])
      }
      let report = try Self.repairCommittedHeads(legacyURL: legacyURL, apply: apply, revision: revision)
      if apply {
        // Cache only a stable, read-only pass. A sync may arrive while a
        // repair publishes its files; never cache unexamined arriving heads
        // together with our own output and then skip them on the next poll.
        if !report.changed, try Self.repairFingerprint(storeURL: storeURL) == revision {
          repairFingerprints[storeURL.path] = revision
        } else {
          repairFingerprints.removeValue(forKey: storeURL.path)
        }
        repairReports[storeURL.path] = report
      }
      condition.lock()
      validatedStoreStates.removeValue(forKey: legacyURL.standardizedFileURL.path)
      condition.unlock()
      return report
    }
  }

  /// A cheap fingerprint of committed chat storage. It changes whenever any
  /// writer commits (head bytes), a manifest, shard, or blob arrives
  /// (directory mtimes), or a root view changes, so an unchanged value means a
  /// synced reload would read exactly the same committed state.
  func committedStateFingerprint(legacyURL: URL) -> String? {
    try? Self.repairFingerprint(storeURL: Self.storeDirectory(for: legacyURL.standardizedFileURL))
  }

  /// An inexpensive idle check confined to chat storage. Directory changes
  /// detect late shards/blobs; head bytes detect commits even with preserved mtimes.
  private static func repairFingerprint(storeURL: URL) throws -> String {
    let manager = FileManager.default
    var parts: [String] = []
    for directory in [storeURL, headsDirectory(storeURL: storeURL), manifestsDirectory(storeURL: storeURL),
                      threadsDirectory(storeURL: storeURL), attachmentsDirectory(storeURL: storeURL)] {
      guard !isSymbolicLink(directory) else { throw TranscriptStoreError.unsafeStorePath }
      let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
      parts.append("\(directory.lastPathComponent):\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1)")
    }
    let heads = (try? manager.contentsOfDirectory(at: headsDirectory(storeURL: storeURL),
      includingPropertiesForKeys: nil)) ?? []
    let roots = ["migration-marker.json", "migration-marker.previous.json", "manifest.json", "manifest.previous.json"]
      .map { storeURL.appendingPathComponent($0) }
    for url in (heads.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") } + roots)
      .sorted(by: { $0.path < $1.path }) {
      guard !isSymbolicLink(url) else { throw TranscriptStoreError.unsafeStorePath }
      if let data = try? Data(contentsOf: url) { parts.append("\(url.lastPathComponent):\(digest(data))") }
    }
    return digest(Data(parts.joined(separator: "\n").utf8))
  }

  private final class StagedRepairShards {
    var files: [URL: Data] = [:]
  }

  private static func repairCommittedHeads(
    legacyURL: URL, apply: Bool, revision: String
  ) throws -> AIChatTranscriptRepairReport {
    let storeURL = storeDirectory(for: legacyURL)
    var pointers = headPointers(storeURL: storeURL)
    var warnings: [String] = []
    let headURLs = ((try? FileManager.default.contentsOfDirectory(at: headsDirectory(storeURL: storeURL),
      includingPropertiesForKeys: nil)) ?? []).filter {
        $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".")
      }
    guard pointers.count == headURLs.count else {
      throw TranscriptStoreError.unrecoverableStore("A chat writer head is malformed; its bytes were retained.")
    }
    if pointers.isEmpty {
      pointers = ["migration-marker.json", "migration-marker.previous.json"].compactMap {
        legacyPointer(at: storeURL.appendingPathComponent($0))
      }
    }
    var manifests: [Manifest] = []
    for pointer in pointers {
      let url = manifestsDirectory(storeURL: storeURL).appendingPathComponent(pointer.currentManifest)
      guard let manifest = loadManifest(named: pointer.currentManifest,
        expectedDigest: pointer.currentDigest, storeURL: storeURL) else {
        throw TranscriptStoreError.unrecoverableStore("A committed chat version is incomplete or corrupt; repair will retry after sync. No head was changed.")
      }
      try ensureRepairUnderstands(data: Data(contentsOf: url), encoded: encoder.encode(manifest))
      for entry in manifest.threads {
        guard let shard = loadThreadShard(entry, storeURL: storeURL) else {
          throw TranscriptStoreError.missingShard(entry.metadata.id)
        }
        try ensureRepairUnderstands(data: Data(contentsOf: storeURL.appendingPathComponent(entry.shard)),
          encoded: encoder.encode(shard))
        for reference in shard.messages.flatMap(\.attachments) {
          let blob = attachmentsDirectory(storeURL: storeURL).appendingPathComponent(reference.blob)
          guard !isSymbolicLink(blob), let bytes = try? Data(contentsOf: blob),
                bytes.count == reference.byteCount, digest(bytes) == reference.digest else {
            throw TranscriptStoreError.invalidAttachmentBlob(reference.blob)
          }
        }
      }
      manifests.append(manifest)
      if let previous = pointer.previousManifest,
         loadManifest(named: previous, expectedDigest: pointer.previousDigest, storeURL: storeURL) == nil {
        warnings.append("A writer's prior manifest is unavailable; historical integrity is unverified: \(previous)")
      }
    }
    // Reconcile live commit points, not every historic snapshot: old snapshots
    // must not resurrect intentional deletions. Originals are never modified.
    let candidates = Array(Dictionary(manifests.map { ($0.commitID, $0) },
      uniquingKeysWith: { first, _ in first }).values)
    let staged = StagedRepairShards()
    guard let merged = reconciledRecoveryManifest(from: candidates, storeURL: storeURL, stagedShards: staged) else {
      if !pointers.isEmpty { throw TranscriptStoreError.unrecoverableStore("No complete chat commit can be reconciled.") }
      return AIChatTranscriptRepairReport(schema: "org2:ai-chat-repair:v1", applied: false,
        changed: false, checked: true, revision: revision, threadCount: 0, mergedShardCount: 0,
        warnings: ["No versioned writer heads; legacy transcripts were retained unchanged."])
    }
    let changed = !candidates.contains { $0.commitID == merged.commitID }
    if apply && changed {
      guard try repairFingerprint(storeURL: storeURL) == revision else {
        throw TranscriptStoreError.unrecoverableStore("Chat storage changed during repair; retry against the new commits.")
      }
      for (url, data) in staged.files { try publishRepairImmutable(data, to: url) }
      let data = try encoder.encode(merged)
      let name = "\(merged.commitID).json"
      try publishRepairImmutable(data, to: manifestsDirectory(storeURL: storeURL).appendingPathComponent(name))
      guard isComplete(merged, storeURL: storeURL) else {
        throw TranscriptStoreError.unrecoverableStore("Reconciled chat failed validation; original heads were retained.")
      }
      let repairDefaults = UserDefaults(suiteName: "org.org2.transcript-repair") ?? .standard
      let writer = AIChatTranscriptWriterIdentity.persistent(defaults: repairDefaults, label: "Deterministic chat repair")
      let previous = candidates.max { ($0.generation, $0.commitID) < ($1.generation, $1.commitID) }
      let previousURL = previous.map { manifestsDirectory(storeURL: storeURL).appendingPathComponent("\($0.commitID).json") }
      let previousBytes = try previousURL.map { try Data(contentsOf: $0) }
      let head = StoreHead(schema: StoreHead.schemaValue, version: 1, writerID: "repair-\(writer.id)",
        writerLabel: writer.label, currentManifest: name, currentDigest: digest(data),
        currentGeneration: merged.generation, previousManifest: previousURL?.lastPathComponent,
        previousDigest: previousBytes.map(digest), updatedAt: Date())
      try FileManager.default.createDirectory(at: headsDirectory(storeURL: storeURL),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try writeIfChanged(encoder.encode(head), to: headsDirectory(storeURL: storeURL)
        .appendingPathComponent("repair-\(writer.id).json"))
    }
    return AIChatTranscriptRepairReport(schema: "org2:ai-chat-repair:v1", applied: apply && changed,
      changed: changed, checked: true, revision: revision, threadCount: merged.threads.count,
      mergedShardCount: staged.files.count, warnings: warnings)
  }

  private static func publishRepairImmutable(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".repair-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if Darwin.link(temporary.path, url.path) != 0 {
      guard errno == EEXIST, !isSymbolicLink(url),
            (try? Data(contentsOf: url)) == data else {
        throw TranscriptStoreError.unrecoverableStore("An immutable chat file differs from the repair result; original bytes were retained.")
      }
    }
  }

  /// A future field must not be silently discarded by this older native engine.
  private static func ensureRepairUnderstands(data: Data, encoded: Data) throws {
    func unknown(_ original: Any, _ known: Any) -> Bool {
      if let original = original as? [String: Any], let known = known as? [String: Any] {
        return original.contains { key, value in
          guard let understood = known[key] else { return !(value is NSNull) }
          return unknown(value, understood)
        }
      }
      if let original = original as? [Any], let known = known as? [Any], original.count == known.count {
        return zip(original, known).contains { unknown($0.0, $0.1) }
      }
      return false
    }
    if try unknown(JSONSerialization.jsonObject(with: data), JSONSerialization.jsonObject(with: encoded)) {
      throw TranscriptStoreError.unrecoverableStore("Chat storage contains fields this build cannot preserve; upgrade before repairing. Original bytes were retained.")
    }
  }

  /// Sets the writer identity for this process. Call once at startup, before
  /// the first commit. Tests may override per store with
  /// `setWriterIdentityForTesting`.
  func configureWriter(_ identity: AIChatTranscriptWriterIdentity) {
    condition.lock()
    configuredWriterIdentity = identity
    condition.unlock()
  }

  var writerIdentity: AIChatTranscriptWriterIdentity {
    condition.lock()
    defer { condition.unlock() }
    return resolvedWriterIdentityLocked(key: nil)
  }

  func setWriterIdentityForTesting(_ identity: AIChatTranscriptWriterIdentity?, legacyURL: URL) {
    let key = legacyURL.standardizedFileURL.path
    condition.lock()
    writerIdentityOverridesForTesting[key] = identity
    condition.unlock()
  }

  private func resolvedWriterIdentityLocked(key: String?) -> AIChatTranscriptWriterIdentity {
    if let key, let override = writerIdentityOverridesForTesting[key] { return override }
    if let configuredWriterIdentity { return configuredWriterIdentity }
    let identity = AIChatTranscriptWriterIdentity.persistent()
    configuredWriterIdentity = identity
    return identity
  }

  /// Records the persisted revision that an in-memory conversation now
  /// mirrors. Only call this for threads the caller actually installed; a
  /// read that is discarded (for example because a local turn protects the
  /// thread) must not become the merge base.
  func recordAdoptedThreads(_ threads: [AIChatThread], legacyURL: URL) {
    guard !threads.isEmpty else { return }
    let key = legacyURL.standardizedFileURL.path
    condition.lock()
    for thread in threads {
      adoptionSequence &+= 1
      if thread.storedMessageCount != nil {
        adoptedBases[key]?.removeValue(forKey: thread.id)
      } else {
        adoptedBases[key, default: [:]][thread.id] = AdoptedThreadBase(
          messages: thread.messages,
          writtenShardDigest: nil,
          sequence: adoptionSequence
        )
      }
    }
    condition.unlock()
  }

  /// Drop merge bases for threads whose in-memory copy did not come from the
  /// persisted revision (for example an in-flight copy restored after a corpus
  /// switch). Their next write keeps every replica message.
  func forgetAdoptedThreads(_ ids: Set<UUID>, legacyURL: URL) {
    guard !ids.isEmpty else { return }
    let key = legacyURL.standardizedFileURL.path
    condition.lock()
    for id in ids {
      adoptionSequence &+= 1
      adoptedBases[key]?.removeValue(forKey: id)
    }
    condition.unlock()
  }

  func adoptedBaseMessageIDsForTesting(threadID: UUID, legacyURL: URL) -> [UUID]? {
    let key = legacyURL.standardizedFileURL.path
    condition.lock()
    defer { condition.unlock() }
    return adoptedBases[key]?[threadID]?.messages.map(\.id)
  }

  /// True when a committed store (current head layout or the historical
  /// marker/view layout) exists for this transcript.
  nonisolated static func hasCommittedStore(for legacyURL: URL) -> Bool {
    let storeURL = storeDirectory(for: legacyURL)
    let fileManager = FileManager.default
    for name in [
      "migration-marker.json", "migration-marker.previous.json", "manifest.json",
    ] where fileManager.fileExists(atPath: storeURL.appendingPathComponent(name).path) {
      return true
    }
    let heads = (try? fileManager.contentsOfDirectory(
      atPath: storeURL.appendingPathComponent(headsDirectoryName).path
    )) ?? []
    return heads.contains { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
  }

  @discardableResult
  func enqueue(_ snapshot: AIChatTranscriptSnapshot, legacyURL: URL) -> UInt64 {
    enqueue(snapshot, legacyURL: legacyURL, requiresExactCommit: false)
  }

  @discardableResult
  func enqueueDurabilityBarrier(
    _ snapshot: AIChatTranscriptSnapshot,
    legacyURL: URL
  ) -> UInt64 {
    enqueue(snapshot, legacyURL: legacyURL, requiresExactCommit: true)
  }

  private func enqueue(
    _ snapshot: AIChatTranscriptSnapshot,
    legacyURL: URL,
    requiresExactCommit: Bool
  ) -> UInt64 {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    condition.lock()
    validatedStoreStates.removeValue(forKey: key)
    nextGeneration &+= 1
    // Bind this save to what the caller had adopted when it queued the
    // snapshot, never to a replica refresh adopted later while it waits.
    var bases = adoptedBases[key] ?? [:]
    if let previous = latestSnapshots[key], persistedGenerations[key, default: 0] < previous.generation {
      for thread in previous.snapshot.threads where thread.storedMessageCount == nil {
        let current = bases[thread.id]
        guard (current?.sequence ?? 0) == (previous.bases[thread.id]?.sequence ?? 0) else { continue }
        let previousIDs = Set(thread.messages.map(\.id))
        // Earlier queued local edits are also observed by this caller. Keep
        // removed IDs in the base so a subsequent exact save can delete them.
        let removed = (previous.bases[thread.id]?.messages ?? []).filter { !previousIDs.contains($0.id) }
        bases[thread.id] = AdoptedThreadBase(messages: thread.messages + removed,
          writtenShardDigest: nil, sequence: current?.sequence ?? 0)
      }
    }
    let pending = PendingWrite(
      generation: nextGeneration,
      legacyURL: url,
      snapshot: snapshot,
      bases: bases
    )
    latestSnapshots[key] = pending
    if requiresExactCommit {
      exactPendingWrites.append(pending)
    } else {
      pendingWrites[key] = pending
    }
    let startsDrain = !isDraining
    if startsDrain { isDraining = true }
    condition.unlock()
    if startsDrain {
      queue.async { [weak self] in self?.drainWrites() }
    }
    return pending.generation
  }

  /// Waits for the exact snapshot generation (or a newer coalesced snapshot)
  /// to reach the commit marker. This never blocks the calling executor.
  func waitUntilPersisted(generation: UInt64, legacyURL: URL) async throws {
    let key = legacyURL.standardizedFileURL.path
    try await withCheckedThrowingContinuation { continuation in
      condition.lock()
      if persistedGenerations[key, default: 0] >= generation {
        condition.unlock()
        continuation.resume()
        return
      }
      if let failure = failedGenerations[key], failure.generation >= generation {
        condition.unlock()
        continuation.resume(throwing: failure.error)
        return
      }
      persistenceWaiters[key, default: []].append(PersistenceWaiter(
        generation: generation,
        continuation: continuation
      ))
      condition.unlock()
    }
  }

  /// Synchronous only for process-shutdown/test boundaries. Production
  /// interaction paths use `enqueue` + `waitUntilPersisted`.
  func flush(_ snapshot: AIChatTranscriptSnapshot, legacyURL: URL) throws {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    let generation = enqueue(snapshot, legacyURL: url)
    condition.lock()
    defer { condition.unlock() }
    while persistedGenerations[key, default: 0] < generation {
      if let failure = failedGenerations[key], failure.generation >= generation {
        throw failure.error
      }
      condition.wait()
    }
  }

  func loadIfAvailable(legacyURL: URL, preferPersisted: Bool = false) -> AIChatTranscriptLoadResult? {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    condition.lock()
    let hasPendingWrite = latestSnapshots[key].map {
      persistedGenerations[key, default: 0] < $0.generation
    } ?? false
    if preferPersisted && !hasPendingWrite { latestSnapshots.removeValue(forKey: key) }
    let pending = latestSnapshots[key]
    condition.unlock()
    if let pending {
      return Self.materializePendingSnapshot(pending.snapshot, legacyURL: url)
    }
    return loadCommittedIfAvailable(legacyURL: url)
  }

  /// Read a replica's commit even when this process has a queued local snapshot.
  /// Callers reconcile local mutations before applying the returned threads.
  func loadCommittedIfAvailable(legacyURL: URL) -> AIChatTranscriptLoadResult? {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    let state: StoreState
    let result: AIChatTranscriptLoadResult
    if let fastState = Self.loadFastStoreState(legacyURL: url) {
      let fastResult = Self.loadShardedSnapshot(legacyURL: url, state: fastState)
      let eagerIDs = fastState.current.map {
        Self.eagerThreadIDs(
          threads: $0.threads.map(\.metadata),
          selectedThreadID: $0.selectedThreadID
        )
      } ?? []
      if fastResult.unloadedThreadIDs.isDisjoint(with: eagerIDs) {
        state = fastState
        result = fastResult
      } else {
        guard let recovered = Self.loadStoreState(legacyURL: url) else { return nil }
        state = recovered
        result = Self.loadShardedSnapshot(legacyURL: url, state: recovered)
      }
    } else {
      guard let recovered = Self.loadStoreState(legacyURL: url) else { return nil }
      state = recovered
      result = Self.loadShardedSnapshot(legacyURL: url, state: recovered)
    }
    condition.lock()
    validatedStoreStates[key] = state
    condition.unlock()
    return result
  }

  func setWritesSuspendedForTesting(_ suspended: Bool, legacyURL: URL) {
    let key = legacyURL.standardizedFileURL.path
    condition.lock()
    if suspended {
      suspendedWritePathsForTesting.insert(key)
    } else {
      suspendedWritePathsForTesting.remove(key)
      condition.broadcast()
    }
    condition.unlock()
  }

  func waitUntilIdleForTesting() {
    condition.lock()
    defer { condition.unlock() }
    while isDraining { condition.wait() }
  }

  func loadThread(
    id: UUID,
    metadata: AIChatThread,
    legacyURL: URL
  ) -> AIChatThread? {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    condition.lock()
    let cached = validatedStoreStates[key]
    condition.unlock()
    if let manifest = cached?.current,
       let loaded = Self.loadThread(id: id, metadata: metadata, manifest: manifest, legacyURL: url) {
      return loaded
    }
    // A failed cached shard read may mean storage changed underneath the app.
    // Revalidate the complete commit chain once so recovery can select the
    // previous manifest instead of returning stale or partial data.
    guard let refreshed = Self.loadStoreState(legacyURL: url) else { return nil }
    condition.lock()
    validatedStoreStates[key] = refreshed
    condition.unlock()
    guard let manifest = refreshed.current else { return nil }
    return Self.loadThread(id: id, metadata: metadata, manifest: manifest, legacyURL: url)
  }

  func loadAllThreads(
    replacingMetadata metadata: [AIChatThread],
    legacyURL: URL
  ) -> [AIChatThread] {
    let url = legacyURL.standardizedFileURL
    let key = url.path
    condition.lock()
    let cached = validatedStoreStates[key]
    condition.unlock()
    let state: StoreState?
    if let cached {
      state = cached
    } else {
      state = Self.loadStoreState(legacyURL: url)
      if let state {
        condition.lock()
        validatedStoreStates[key] = state
        condition.unlock()
      }
    }
    guard let manifest = state?.current else { return metadata }
    return metadata.map { thread in
      guard thread.storedMessageCount != nil else { return thread }
      return Self.loadThread(
        id: thread.id,
        metadata: thread,
        manifest: manifest,
        legacyURL: url
      ) ?? thread
    }
  }

  nonisolated static func storeDirectory(for legacyURL: URL) -> URL {
    legacyURL.standardizedFileURL
      .deletingPathExtension()
      .appendingPathExtension("store")
  }

  private func drainWrites() {
    while true {
      condition.lock()
      let writablePending = Array(pendingWrites.values)
        .filter { !suspendedWritePathsForTesting.contains($0.legacyURL.path) }
        + exactPendingWrites.filter {
          !suspendedWritePathsForTesting.contains($0.legacyURL.path)
        }
      guard let pending = writablePending.min(by: { $0.generation < $1.generation }) else {
        if !pendingWrites.isEmpty || !exactPendingWrites.isEmpty {
          condition.wait()
          condition.unlock()
          continue
        }
        let cleanupPaths = garbageCollectionPaths
        garbageCollectionPaths.removeAll()
        condition.unlock()
        // No other writer can start while `isDraining` remains true. Re-read
        // the committed marker and collect only artifacts it no longer
        // references, then check once more for writes enqueued during cleanup.
        for key in cleanupPaths {
          let completed = Self.garbageCollect(legacyURL: URL(fileURLWithPath: key)) {
            self.condition.lock()
            defer { self.condition.unlock() }
            return !self.pendingWrites.isEmpty || !self.exactPendingWrites.isEmpty
          }
          if !completed {
            condition.lock()
            garbageCollectionPaths.insert(key)
            condition.unlock()
          }
        }
        condition.lock()
        if pendingWrites.isEmpty && exactPendingWrites.isEmpty {
          isDraining = false
          condition.broadcast()
          condition.unlock()
          return
        }
        condition.unlock()
        continue
      }
      if let exactIndex = exactPendingWrites.firstIndex(where: {
        $0.generation == pending.generation
      }) {
        exactPendingWrites.remove(at: exactIndex)
      } else if pendingWrites[pending.legacyURL.path]?.generation == pending.generation {
        pendingWrites.removeValue(forKey: pending.legacyURL.path)
      }
      let writer = resolvedWriterIdentityLocked(key: pending.legacyURL.path)
      let bases = pending.bases
      condition.unlock()

      let result = Result {
        try Self.write(pending.snapshot, legacyURL: pending.legacyURL, writer: writer, bases: bases)
      }
      var resumptions: [(CheckedContinuation<Void, Error>, Result<Void, Error>)] = []
      condition.lock()
      let key = pending.legacyURL.path
      switch result {
      case .success(let writtenBases):
        // The in-memory copy now mirrors what it just wrote, unless the caller
        // adopted a newer persisted revision while this commit was running.
        for (threadID, written) in writtenBases {
          if (adoptedBases[key]?[threadID]?.sequence ?? 0) != (bases[threadID]?.sequence ?? 0) {
            continue
          }
          adoptedBases[key, default: [:]][threadID] = AdoptedThreadBase(
            messages: written.messages,
            writtenShardDigest: written.writtenShardDigest,
            // Only an actual adoption advances the epoch. Earlier local
            // commits must not invalidate the bases of later queued edits.
            sequence: bases[threadID]?.sequence ?? 0
          )
        }
        persistedGenerations[key] = max(persistedGenerations[key, default: 0], pending.generation)
        garbageCollectionPaths.insert(key)
        if pendingWrites[key] == nil,
           !exactPendingWrites.contains(where: { $0.legacyURL.path == key }) {
          latestSnapshots.removeValue(forKey: key)
        }
        if let failure = failedGenerations[key], failure.generation <= pending.generation {
          failedGenerations.removeValue(forKey: key)
        }
      case .failure(let error):
        failedGenerations[key] = (pending.generation, error)
      }
      let persisted = persistedGenerations[key, default: 0]
      let failure = failedGenerations[key]
      var retained: [PersistenceWaiter] = []
      for waiter in persistenceWaiters[key] ?? [] {
        if persisted >= waiter.generation {
          resumptions.append((waiter.continuation, .success(())))
        } else if let failure, failure.generation >= waiter.generation {
          resumptions.append((waiter.continuation, .failure(failure.error)))
        } else {
          retained.append(waiter)
        }
      }
      persistenceWaiters[key] = retained.isEmpty ? nil : retained
      condition.broadcast()
      condition.unlock()
      for (continuation, result) in resumptions {
        continuation.resume(with: result)
      }
    }
  }

  private static func materializePendingSnapshot(
    _ snapshot: AIChatTranscriptSnapshot,
    legacyURL: URL
  ) -> AIChatTranscriptLoadResult {
    var unloaded = Set(snapshot.threads.compactMap { thread in
      thread.storedMessageCount == nil ? nil : thread.id
    })
    let eagerIDs = eagerThreadIDs(
      threads: snapshot.threads,
      selectedThreadID: snapshot.selectedThreadID
    )
    let state = loadStoreState(legacyURL: legacyURL)
    let threads = snapshot.threads.map { metadata -> AIChatThread in
      guard metadata.storedMessageCount != nil, eagerIDs.contains(metadata.id),
            let manifest = state?.current,
            let loaded = loadThread(
              id: metadata.id,
              metadata: metadata,
              manifest: manifest,
              legacyURL: legacyURL
            )
      else { return metadata }
      unloaded.remove(metadata.id)
      return loaded
    }
    let recoveryStatus = state?.recoveryStatus ?? .healthy
    return AIChatTranscriptLoadResult(
      snapshot: AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: snapshot.selectedThreadID,
        settlementSettings: snapshot.settlementSettings
      ),
      unloadedThreadIDs: unloaded,
      recoveryStatus: recoveryStatus
    )
  }

  private static func loadShardedSnapshot(
    legacyURL: URL,
    state: StoreState
  ) -> AIChatTranscriptLoadResult {
    guard let manifest = state.current else {
      return AIChatTranscriptLoadResult(
        snapshot: AIChatTranscriptSnapshot(
          threads: [],
          selectedThreadID: nil,
          settlementSettings: AIChatThreadSettlementSettings()
        ),
        unloadedThreadIDs: [],
        recoveryStatus: state.recoveryStatus
      )
    }
    let metadata = manifest.threads.map(\.metadata)
    let eagerIDs = eagerThreadIDs(
      threads: metadata,
      selectedThreadID: manifest.selectedThreadID
    )
    var unloaded = Set<UUID>()
    let storeURL = storeDirectory(for: legacyURL)
    let entriesByID = Dictionary(
      manifest.threads.map { ($0.metadata.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let threads = metadata.map { thread -> AIChatThread in
      guard eagerIDs.contains(thread.id),
            let loaded = loadThread(
              id: thread.id,
              metadata: thread,
              manifest: manifest,
              legacyURL: legacyURL
            )
      else {
        if thread.storedMessageCount != nil { unloaded.insert(thread.id) }
        return backfillingLatestAssistantMessageID(
          thread,
          entry: entriesByID[thread.id],
          storeURL: storeURL
        )
      }
      return loaded
    }
    return AIChatTranscriptLoadResult(
      snapshot: AIChatTranscriptSnapshot(
        threads: threads,
        selectedThreadID: manifest.selectedThreadID,
        settlementSettings: manifest.settlementSettings
      ),
      unloadedThreadIDs: unloaded,
      recoveryStatus: state.recoveryStatus
    )
  }

  /// Shard names are content digests, so the latest reply derived from a
  /// shard never changes. Caching by digest keeps repeated synced loads from
  /// decoding the same legacy shards again before the backfill is persisted.
  private final class LatestAssistantReplyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: UUID?] = [:]

    func value(for digest: String) -> UUID?? {
      lock.lock()
      defer { lock.unlock() }
      return values[digest]
    }

    func set(_ value: UUID?, for digest: String) {
      lock.lock()
      values[digest] = value
      lock.unlock()
    }
  }

  private static let latestAssistantReplyCache = LatestAssistantReplyCache()

  /// Remote clients key reply notifications on a thread's latest assistant
  /// reply. Placeholders written before that ID was stored would report no
  /// reply until loaded, then announce the old reply as new. Derive the ID
  /// once from the shard; the next manifest write persists it.
  private static func backfillingLatestAssistantMessageID(
    _ thread: AIChatThread,
    entry: ManifestThread?,
    storeURL: URL
  ) -> AIChatThread {
    guard thread.messages.isEmpty,
          thread.storedLatestAssistantMessageID == nil,
          (thread.storedMessageCount ?? 0) > 0,
          let entry
    else { return thread }
    let latest: UUID?
    if let cached = latestAssistantReplyCache.value(for: entry.shardDigest) {
      latest = cached
    } else {
      guard let shard = loadThreadShard(entry, storeURL: storeURL) else { return thread }
      latest = shard.messages.last(where: { stored in
        stored.message.role == .assistant
          && stored.message.content.contains(where: { !$0.isWhitespace })
      })?.message.id
      latestAssistantReplyCache.set(latest, for: entry.shardDigest)
    }
    guard let latest else { return thread }
    return thread.metadataOnly(latestAssistantMessageID: latest)
  }

  private static func eagerThreadIDs(
    threads: [AIChatThread],
    selectedThreadID: UUID?
  ) -> Set<UUID> {
    var ids = Set(threads.compactMap { thread in
      thread.id == selectedThreadID || thread.pendingTurn != nil ? thread.id : nil
    })
    for thread in threads where !thread.isSettled && ids.count < eagerWorkingSetLimit {
      ids.insert(thread.id)
    }
    return ids
  }

  private static func loadThread(
    id: UUID,
    metadata: AIChatThread,
    manifest: Manifest,
    legacyURL: URL
  ) -> AIChatThread? {
    guard let entry = manifest.threads.first(where: { $0.metadata.id == id }) else { return nil }
    let storeURL = storeDirectory(for: legacyURL)
    guard let shard = loadThreadShard(entry, storeURL: storeURL) else { return nil }
    let attachmentDirectory = attachmentsDirectory(storeURL: storeURL)
    let messages = shard.messages.map { stored in
      stored.message.replacingAttachments(
        stored.attachments.map { reference in
          AIChatAttachment(
            id: reference.id,
            fileName: reference.fileName,
            mimeType: reference.mimeType,
            blobURL: attachmentDirectory.appendingPathComponent(reference.blob),
            byteCount: reference.byteCount,
            contentDigest: reference.digest
          )
        }
      )
    }
    return metadata.hydrating(messages: messages)
  }

  private static func write(
    _ snapshot: AIChatTranscriptSnapshot,
    legacyURL: URL,
    writer: AIChatTranscriptWriterIdentity? = nil,
    bases: [UUID: AdoptedThreadBase] = [:]
  ) throws -> [UUID: AdoptedThreadBase] {
    let fileManager = FileManager.default
    let storeURL = storeDirectory(for: legacyURL)
    let threadDirectory = threadsDirectory(storeURL: storeURL)
    let attachmentDirectory = attachmentsDirectory(storeURL: storeURL)
    let manifestDirectory = manifestsDirectory(storeURL: storeURL)
    let headDirectory = headsDirectory(storeURL: storeURL)
    try fileManager.createDirectory(at: threadDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: headDirectory, withIntermediateDirectories: true)
    guard ![storeURL, threadDirectory, attachmentDirectory, manifestDirectory, headDirectory]
      .contains(where: isSymbolicLink)
    else { throw TranscriptStoreError.unsafeStorePath }
    for directory in [storeURL, threadDirectory, attachmentDirectory, manifestDirectory, headDirectory] {
      try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    let priorState = loadStoreState(legacyURL: legacyURL)
    if let priorState, priorState.recoveryStatus.blocksWrites {
      throw TranscriptStoreError.unrecoverableStore(priorState.recoveryStatus.description)
    }
    let priorManifest = priorState?.current
    let priorEntriesByID = Dictionary(
      (priorManifest?.threads ?? []).map { ($0.metadata.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var entries: [ManifestThread] = []
    var writtenBases: [UUID: AdoptedThreadBase] = [:]
    entries.reserveCapacity(snapshot.threads.count)

    for thread in snapshot.threads {
      let prior = priorEntriesByID[thread.id]
      if thread.storedMessageCount != nil {
        if let prior {
          guard isValidShard(prior, storeURL: storeURL)
          else { throw TranscriptStoreError.missingShard(thread.id) }
          // A metadata-only copy cannot describe messages it never loaded.
          // Keep a newer replica revision, or one whose message count this
          // stale copy no longer matches, instead of mislabeling its shard.
          if (snapshot.knownThreadIDs != nil && prior.metadata.updatedAt > thread.updatedAt)
              || prior.metadata.storedMessageCount != thread.storedMessageCount {
            entries.append(prior)
            continue
          }
          entries.append(ManifestThread(
            metadata: thread.metadataOnly(),
            shard: prior.shard,
            shardDigest: prior.shardDigest,
            blobs: prior.blobs,
            deletedMessageIDs: prior.deletedMessageIDs
          ))
          continue
        }
        guard thread.messageCount == 0 else {
          throw TranscriptStoreError.missingShard(thread.id)
        }
      }

      var storedMessages: [StoredMessage] = []
      var threadBlobs = Set<String>()
      storedMessages.reserveCapacity(thread.messages.count)
      for message in thread.messages {
        var references: [StoredAttachment] = []
        references.reserveCapacity(message.attachments.count)
        for attachment in message.attachments {
          let attachmentData = try attachment.loadData()
          let attachmentDigest = attachment.persistedContentDigest
          guard digest(attachmentData) == attachmentDigest,
                attachmentData.count == attachment.byteCount
          else { throw TranscriptStoreError.invalidAttachment(attachment.fileName) }
          let blobName = "\(attachmentDigest).blob"
          threadBlobs.insert(blobName)
          let blobURL = attachmentDirectory.appendingPathComponent(blobName)
          if fileManager.fileExists(atPath: blobURL.path) {
            let existing = try Data(contentsOf: blobURL, options: .mappedIfSafe)
            guard existing.count == attachment.byteCount, digest(existing) == attachmentDigest else {
              // Never replace corrupt bytes under a digest-derived identity.
              throw TranscriptStoreError.invalidAttachmentBlob(blobName)
            }
          } else {
            try attachmentData.write(to: blobURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blobURL.path)
          }
          references.append(StoredAttachment(
            id: attachment.id,
            fileName: attachment.fileName,
            mimeType: attachment.mimeType,
            blob: blobName,
            byteCount: attachment.byteCount,
            digest: attachmentDigest
          ))
        }
        storedMessages.append(StoredMessage(
          message: message.replacingAttachments([]),
          attachments: references
        ))
      }

      // Three-way merge against the persisted revision. A replica (another
      // Mac, the headless server, or `org2 thread post`) may have appended
      // messages or finished a turn in this conversation since this copy
      // was loaded. Never overwrite that work with a stale local copy.
      let base = bases[thread.id]
      let localIDs = Set(thread.messages.map(\.id))
      var tombstones = prior?.deletedMessageIDs ?? []
      if let base {
        for message in base.messages where !localIDs.contains(message.id) {
          tombstones.append(message.id)
        }
      }
      // A message this copy introduced (absent from the revision it was
      // derived from) overrides an older deletion of the same ID. Without a
      // base, the local copy is authoritative for everything it holds.
      let baseIDs = Set(base?.messages.map(\.id) ?? [])
      let reintroduced = base == nil ? localIDs : localIDs.subtracting(baseIDs)
      tombstones = boundedTombstones(tombstones.filter { !reintroduced.contains($0) })
      var metadata = thread
      if let prior, prior.shardDigest != base?.writtenShardDigest,
         let priorShard = loadThreadShard(prior, storeURL: storeURL) {
        let merged = threeWayMerge(
          local: storedMessages,
          remote: priorShard.messages,
          base: base?.messages,
          tombstones: Set(tombstones)
        )
        if merged.map(\.message) != storedMessages.map(\.message)
            || merged.map(\.attachments) != storedMessages.map(\.attachments) {
          storedMessages = merged
          threadBlobs = Set(merged.flatMap { $0.attachments.map(\.blob) })
        }
        if snapshot.knownThreadIDs != nil, prior.metadata.updatedAt > thread.updatedAt {
          // Keep the newer replica's thread settings while retaining a local
          // turn marker that still names an unresolved local message.
          var newer = prior.metadata
          if newer.pendingTurn == nil, let pendingTurn = thread.pendingTurn {
            newer = newer.replacingPendingTurn(pendingTurn)
          }
          metadata = newer
        }
      } else if !tombstones.isEmpty {
        let removed = Set(tombstones)
        storedMessages.removeAll { removed.contains($0.message.id) }
        threadBlobs = Set(storedMessages.flatMap { $0.attachments.map(\.blob) })
      }
      if let pendingTurn = metadata.pendingTurn,
         !storedMessages.contains(where: {
           $0.message.id == pendingTurn.userMessageID && $0.message.deliveryStatus == .sending
         }),
         thread.pendingTurn == nil {
        metadata = metadata.replacingPendingTurn(nil)
      }
      let mergedMetadata = metadata
        .hydrating(messages: storedMessages.map(\.message))
        .replacingUpdatedAt(max(thread.updatedAt, prior?.metadata.updatedAt ?? thread.updatedAt))

      let shardData = try encoder.encode(ThreadShard(
        schema: ThreadShard.schemaValue,
        version: 1,
        messages: storedMessages
      ))
      let shardDigest = digest(shardData)
      let shardName = "threads/\(thread.id.uuidString.lowercased())-\(shardDigest.prefix(20)).json"
      try writeIfChanged(shardData, to: storeURL.appendingPathComponent(shardName))
      entries.append(ManifestThread(
        metadata: mergedMetadata.metadataOnly(),
        shard: shardName,
        shardDigest: shardDigest,
        blobs: threadBlobs.sorted(),
        deletedMessageIDs: tombstones.isEmpty ? nil : tombstones
      ))
      writtenBases[thread.id] = AdoptedThreadBase(
        messages: thread.messages,
        writtenShardDigest: shardDigest,
        sequence: 0
      )
    }

    // A snapshot can predate a synced thread. Absence only means deletion if
    // this workspace had actually observed that ID; never erase unseen threads.
    if let knownIDs = snapshot.knownThreadIDs {
      let writtenIDs = Set(entries.map { $0.metadata.id })
      entries += (priorManifest?.threads ?? []).filter {
        !knownIDs.contains($0.metadata.id) && !writtenIDs.contains($0.metadata.id)
      }
    }

    let commitID = UUID().uuidString.lowercased()
    let manifest = Manifest(
      schema: Manifest.schemaValue,
      version: 2,
      generation: (priorManifest?.generation ?? 0) &+ 1,
      commitID: commitID,
      parentCommitID: priorManifest?.commitID,
      ancestorCommitIDs: boundedCommitIDs(
        [priorManifest?.commitID].compactMap { $0 } + (priorManifest?.ancestorCommitIDs ?? [])
      ),
      mergedCommitIDs: priorManifest?.mergedCommitIDs,
      threads: entries,
      selectedThreadID: snapshot.selectedThreadID,
      settlementSettings: snapshot.settlementSettings
    )
    let manifestData = try encoder.encode(manifest)
    let manifestName = "\(commitID).json"
    let versionedManifestURL = manifestDirectory.appendingPathComponent(manifestName)
    try writeIfChanged(manifestData, to: versionedManifestURL)

    // Recovery can synthesize a reconciled prior manifest from multiple
    // immutable sync branches. Persist that complete prior before referencing
    // it so a head never points only at an in-memory recovery result.
    let previousData = try priorManifest.map { try encoder.encode($0) }
    if let priorManifest, let previousData {
      try writeIfChanged(
        previousData,
        to: manifestDirectory.appendingPathComponent("\(priorManifest.commitID).json")
      )
    }
    let previousName = priorManifest.map { "\($0.commitID).json" }

    // This writer's head is the commit point. No other process writes it.
    let writer = writer ?? AIChatTranscriptWriterIdentity.persistent()
    let head = StoreHead(
      schema: StoreHead.schemaValue,
      version: 1,
      writerID: writer.id,
      writerLabel: writer.label,
      currentManifest: manifestName,
      currentDigest: digest(manifestData),
      currentGeneration: manifest.generation,
      previousManifest: previousName,
      previousDigest: previousData.map(digest),
      updatedAt: Date()
    )
    let headURL = headDirectory.appendingPathComponent("\(writer.id).json")
    try encoder.encode(head).write(to: headURL, options: [.atomic])
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: headURL.path)

    // Builds that predate per-writer heads read only the historical marker.
    // Create it once so they can open a new store (they also reconcile every
    // unseen immutable manifest), but never rewrite it: a shared, mutable
    // marker was the main source of synchronization conflicts.
    let markerURL = storeURL.appendingPathComponent("migration-marker.json")
    let previousMarkerURL = storeURL.appendingPathComponent("migration-marker.previous.json")
    if !fileManager.fileExists(atPath: markerURL.path),
       !fileManager.fileExists(atPath: previousMarkerURL.path) {
      let markerData = try encoder.encode(StoreMarker(
        schema: StoreMarker.schemaValue,
        version: 1,
        currentManifest: manifestName,
        currentDigest: digest(manifestData),
        previousManifest: previousName,
        previousDigest: previousData.map(digest)
      ))
      try markerData.write(to: previousMarkerURL, options: [.atomic])
      try markerData.write(to: markerURL, options: [.atomic])
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previousMarkerURL.path)
    }

    // New corpora still get a small compatibility pointer at the historical
    // path. Existing monoliths remain untouched as an offline recovery source.
    if !fileManager.fileExists(atPath: legacyURL.path) {
      try fileManager.createDirectory(
        at: legacyURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try manifestData.write(to: legacyURL, options: [.atomic])
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyURL.path)
    }
    return writtenBases
  }

  /// Merge a locally written message list with the persisted revision. `base`
  /// is the list the local copy was derived from; without one, every message
  /// that only the replica has is treated as a concurrent addition.
  private static func threeWayMerge(
    local: [StoredMessage],
    remote: [StoredMessage],
    base: [AIChatMessage]?,
    tombstones: Set<UUID>
  ) -> [StoredMessage] {
    var remoteByID: [UUID: StoredMessage] = [:]
    for message in remote { remoteByID[message.message.id] = message }
    var baseByID: [UUID: AIChatMessage] = [:]
    for message in base ?? [] { baseByID[message.id] = message }
    func matches(_ stored: StoredMessage, _ message: AIChatMessage) -> Bool {
      stored.message == message.replacingAttachments([])
        && stored.attachments.map(\.id) == message.attachments.map(\.id)
    }
    var result = local.compactMap { local -> StoredMessage? in
      if tombstones.contains(local.message.id) { return nil }
      guard let remote = remoteByID[local.message.id], remote != local else { return local }
      if let base = baseByID[local.message.id] {
        if matches(local, base) { return keepingSettledSend(local, over: remote) }
        if matches(remote, base) { return local }
      }
      return deliveryRank(remote.message) > deliveryRank(local.message) ? remote : local
    }
    let localIDs = Set(local.map(\.message.id))
    let additions = remote.filter {
      !localIDs.contains($0.message.id)
        && !tombstones.contains($0.message.id)
        && baseByID[$0.message.id] == nil
    }
    insertByCreationTime(additions, into: &result)
    return result
  }

  /// Merge two divergent persisted revisions of one conversation. Neither
  /// side is an ancestor of the other, so the union is kept; a message both
  /// sides changed keeps its most resolved delivery state.
  private static func unionMerge(
    primary: [StoredMessage],
    other: [StoredMessage],
    tombstones: Set<UUID>
  ) -> [StoredMessage] {
    var otherByID: [UUID: StoredMessage] = [:]
    for message in other { otherByID[message.message.id] = message }
    var result = primary.compactMap { message -> StoredMessage? in
      if tombstones.contains(message.message.id) { return nil }
      guard let replica = otherByID[message.message.id], replica != message else { return message }
      return deliveryRank(replica.message) > deliveryRank(message.message) ? replica : message
    }
    let primaryIDs = Set(primary.map(\.message.id))
    insertByCreationTime(
      other.filter { !primaryIDs.contains($0.message.id) && !tombstones.contains($0.message.id) },
      into: &result
    )
    return result
  }

  private static func insertByCreationTime(
    _ additions: [StoredMessage],
    into result: inout [StoredMessage]
  ) {
    for addition in additions.sorted(by: { $0.message.createdAt < $1.message.createdAt }) {
      let index = result.lastIndex(where: { $0.message.createdAt <= addition.message.createdAt })
        .map { $0 + 1 } ?? 0
      result.insert(addition, at: index)
    }
  }

  /// The other replica may descend from an older revision than this copy's
  /// base (another host wrote while it had not yet seen this copy's reply).
  /// A sent user message is terminal (only failed sends are retried), so such
  /// a replica must never reopen it: the turn would look "working" forever,
  /// and later messages would queue behind it.
  private static func keepingSettledSend(
    _ local: StoredMessage,
    over remote: StoredMessage
  ) -> StoredMessage {
    guard local.message.role == .user,
          local.message.deliveryStatus == .sent,
          remote.message.deliveryStatus != .sent
    else { return remote }
    return local
  }

  static func threeWayMergeForTesting(
    local: [AIChatMessage],
    remote: [AIChatMessage],
    base: [AIChatMessage]?
  ) -> [AIChatMessage] {
    func stored(_ messages: [AIChatMessage]) -> [StoredMessage] {
      messages.map { StoredMessage(message: $0.replacingAttachments([]), attachments: []) }
    }
    return threeWayMerge(
      local: stored(local),
      remote: stored(remote),
      base: base,
      tombstones: []
    ).map(\.message)
  }

  private static func deliveryRank(_ message: AIChatMessage) -> Int {
    guard message.role == .user else { return 0 }
    switch message.deliveryStatus {
    case .sending: return 1
    case .failed, .interrupted: return 2
    case .sent: return 3
    }
  }

  private static func boundedTombstones(_ values: [UUID]) -> [UUID] {
    var seen = Set<UUID>()
    var ordered: [UUID] = []
    for value in values where seen.insert(value).inserted { ordered.append(value) }
    return Array(ordered.suffix(tombstoneLimit))
  }

  private static func loadStoreState(legacyURL: URL) -> StoreState? {
    let storeURL = storeDirectory(for: legacyURL)
    let markerURL = storeURL.appendingPathComponent("migration-marker.json")
    let previousMarkerURL = storeURL.appendingPathComponent("migration-marker.previous.json")
    let currentViewURL = storeURL.appendingPathComponent("manifest.json")
    let previousViewURL = storeURL.appendingPathComponent("manifest.previous.json")
    let markerURLs = [markerURL, previousMarkerURL]
    let heads = headPointers(storeURL: storeURL)
    let markerExists = markerURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
      || hasHeadFiles(storeURL: storeURL)
    let legacyPrimary = legacyPointer(at: markerURL)
    let legacyPrevious = legacyPointer(at: previousMarkerURL)

    // Every writer's head is an equally valid commit point. Prefer the newest
    // complete one and reconcile the rest as synchronized branches. The
    // historical marker is authoritative only for stores without heads.
    var recoveryCandidates: [Manifest] = []
    var completeTips: [(current: Manifest, previous: Manifest?)] = []
    for pointer in heads.isEmpty ? [legacyPrimary].compactMap({ $0 }) : heads {
      if let current = loadManifestCandidate(
        named: pointer.currentManifest,
        expectedDigest: pointer.currentDigest,
        storeURL: storeURL
      ) {
        recoveryCandidates.append(current)
        if isComplete(current, storeURL: storeURL) {
          let previous = pointer.previousManifest.flatMap {
            loadManifest(named: $0, expectedDigest: pointer.previousDigest, storeURL: storeURL)
          }
          completeTips.append((current, previous))
          continue
        }
      }
      if let previousName = pointer.previousManifest,
         let previous = loadManifestCandidate(
          named: previousName,
          expectedDigest: pointer.previousDigest,
          storeURL: storeURL
         ) {
        recoveryCandidates.append(previous)
      }
    }
    if let best = completeTips.max(by: {
      ($0.current.generation, $0.current.commitID) < ($1.current.generation, $1.current.commitID)
    }) {
      return reconciledSyncedStoreState(
        primary: best.current,
        previous: best.previous,
        storeURL: storeURL
      )
    }

    for pointer in (heads.isEmpty ? [] : [legacyPrimary].compactMap({ $0 }))
      + [legacyPrevious].compactMap({ $0 }) {
      if let current = loadManifestCandidate(
        named: pointer.currentManifest,
        expectedDigest: pointer.currentDigest,
        storeURL: storeURL
      ) {
        recoveryCandidates.append(current)
      }
      if let previousName = pointer.previousManifest,
         let previous = loadManifestCandidate(
          named: previousName,
          expectedDigest: pointer.previousDigest,
          storeURL: storeURL
         ) {
        recoveryCandidates.append(previous)
      }
    }

    // A corrupt marker never authorizes falling back to the stale monolith.
    // Reconcile the redundant views and any immutable commits left behind by
    // a synced writer. A complete commit supplies the known thread set while
    // individually valid newer entries from divergent or incomplete branches
    // preserve their newer per-thread history.
    if markerExists {
      recoveryCandidates += recoveryManifestCandidates(storeURL: storeURL)
      let candidates = Dictionary(
        recoveryCandidates.map { ($0.commitID, $0) },
        uniquingKeysWith: { first, second in
          second.generation > first.generation ? second : first
        }
      ).values.sorted { $0.generation > $1.generation }
      if let recovered = reconciledRecoveryManifest(
        from: Array(candidates),
        storeURL: storeURL
      ) {
        return StoreState(
          current: recovered,
          previous: candidates.first(where: {
            $0.commitID != recovered.commitID && isComplete($0, storeURL: storeURL)
          }),
          recoveryStatus: .recoveredPreviousManifest
        )
      }
      return StoreState(
        current: nil,
        previous: nil,
        recoveryStatus: .unrecoverable(
          "AI chat storage metadata is corrupt. The stale legacy transcript was not loaded and writes are disabled."
        )
      )
    }

    if let current = loadManifest(at: currentViewURL) {
      return StoreState(
        current: current,
        previous: loadManifest(at: previousViewURL),
        recoveryStatus: .healthy
      )
    }

    // Backward-read the first sharded implementation. Its in-place shards are
    // converted to immutable entries on the next successful write.
    if let data = try? Data(contentsOf: currentViewURL, options: .mappedIfSafe),
       let legacy = try? JSONDecoder().decode(LegacyManifest.self, from: data),
       CelorgaNames.schemaMatches(legacy.schema, LegacyManifest.schemaValue) {
      let entries = legacy.threads.map { thread in
        let shard = "threads/\(thread.id.uuidString.lowercased()).json"
        let shardData = try? Data(
          contentsOf: storeURL.appendingPathComponent(shard),
          options: .mappedIfSafe
        )
        let decodedShard = shardData.flatMap { try? JSONDecoder().decode(ThreadShard.self, from: $0) }
        return ManifestThread(
          metadata: thread,
          shard: shard,
          shardDigest: shardData.map(digest) ?? "",
          blobs: decodedShard.map {
            Array(Set($0.messages.flatMap { message in message.attachments.map(\.blob) })).sorted()
          }
        )
      }
      return StoreState(
        current: Manifest(
          schema: Manifest.schemaValue,
          version: 2,
          generation: 0,
          commitID: "legacy-sharded-v1",
          parentCommitID: nil,
          ancestorCommitIDs: nil,
          mergedCommitIDs: nil,
          threads: entries,
          selectedThreadID: legacy.selectedThreadID,
          settlementSettings: legacy.settlementSettings
        ),
        previous: nil,
        recoveryStatus: .healthy
      )
    }

    let hasCommittedManifestView = FileManager.default.fileExists(atPath: currentViewURL.path)
      || FileManager.default.fileExists(atPath: previousViewURL.path)
    if hasCommittedManifestView {
      return StoreState(
        current: nil,
        previous: nil,
        recoveryStatus: .unrecoverable(
          "AI chat storage exists but no valid manifest can be recovered. Writes are disabled."
        )
      )
    }
    return nil
  }

  /// The commit marker and immutable manifest digest are the atomic commit
  /// boundary. Validate only the small eager working set on the launch path;
  /// cold shards are verified when opened. A failed eager/cold shard read
  /// falls back to the exhaustive recovery scan before any data is exposed.
  private static func loadFastStoreState(legacyURL: URL) -> StoreState? {
    let storeURL = storeDirectory(for: legacyURL)
    let heads = headPointers(storeURL: storeURL)
    let pointers = heads.isEmpty
      ? [legacyPointer(at: storeURL.appendingPathComponent("migration-marker.json"))].compactMap { $0 }
      : heads
    for pointer in pointers {
      guard let current = loadManifestCandidate(
        named: pointer.currentManifest,
        expectedDigest: pointer.currentDigest,
        storeURL: storeURL
      ) else { continue }
      let previous = pointer.previousManifest.flatMap {
        loadManifestCandidate(
          named: $0,
          expectedDigest: pointer.previousDigest,
          storeURL: storeURL
        )
      }
      return reconciledSyncedStoreState(
        primary: current,
        previous: previous,
        storeURL: storeURL
      )
    }
    return nil
  }

  private struct CommitPointer {
    let currentManifest: String
    let currentDigest: String
    let previousManifest: String?
    let previousDigest: String?
    let generation: UInt64
  }

  /// Valid writer heads, newest generation first.
  private static func headPointers(storeURL: URL) -> [CommitPointer] {
    let directory = headsDirectory(storeURL: storeURL)
    guard !isSymbolicLink(directory),
          let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
          )
    else { return [] }
    let decoder = JSONDecoder()
    return urls.compactMap { url -> CommitPointer? in
      guard url.pathExtension == "json",
            !isSymbolicLink(url),
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            let head = try? decoder.decode(StoreHead.self, from: data),
            CelorgaNames.schemaMatches(head.schema, StoreHead.schemaValue),
            head.version == 1,
            isValidDigest(head.currentDigest),
            head.previousManifest == nil || head.previousDigest.map(isValidDigest) == true
      else { return nil }
      return CommitPointer(
        currentManifest: head.currentManifest,
        currentDigest: head.currentDigest,
        previousManifest: head.previousManifest,
        previousDigest: head.previousDigest,
        generation: head.currentGeneration
      )
    }.sorted {
      if $0.generation != $1.generation { return $0.generation > $1.generation }
      return $0.currentManifest > $1.currentManifest
    }
  }

  private static func hasHeadFiles(storeURL: URL) -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(
      atPath: headsDirectory(storeURL: storeURL).path
    )) ?? []
    return names.contains { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
  }

  private static func legacyPointer(at url: URL) -> CommitPointer? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          let marker = try? JSONDecoder().decode(StoreMarker.self, from: data),
          CelorgaNames.schemaMatches(marker.schema, StoreMarker.schemaValue),
          marker.version == 1,
          isValidDigest(marker.currentDigest),
          marker.previousManifest == nil || marker.previousDigest.map(isValidDigest) == true
    else { return nil }
    return CommitPointer(
      currentManifest: marker.currentManifest,
      currentDigest: marker.currentDigest,
      previousManifest: marker.previousManifest,
      previousDigest: marker.previousDigest,
      generation: 0
    )
  }

  /// Syncthing can preserve both immutable manifest branches while choosing
  /// only one writer's mutable marker as the canonical filename. Treat every
  /// complete immutable tip as committed so a valid-but-stale marker cannot
  /// hide chats created or updated on another host.
  private static func reconciledSyncedStoreState(
    primary: Manifest,
    previous: Manifest?,
    storeURL: URL
  ) -> StoreState {
    var mergedCommitIDs = Set(primary.mergedCommitIDs ?? [])
    mergedCommitIDs.formUnion(primary.ancestorCommitIDs ?? [])
    mergedCommitIDs.insert(primary.commitID)
    if let previous { mergedCommitIDs.insert(previous.commitID) }
    let unseenCandidates = recoveryManifestCandidates(
      storeURL: storeURL,
      excludingCommitIDs: mergedCommitIDs,
      includesRootViews: false
    )
    guard !unseenCandidates.isEmpty else {
      return StoreState(current: primary, previous: previous, recoveryStatus: .healthy)
    }
    let candidatesByID = Dictionary(
      ([primary] + [previous].compactMap { $0 } + unseenCandidates)
        .map { ($0.commitID, $0) },
      uniquingKeysWith: { first, second in
        second.generation > first.generation ? second : first
      }
    )
    guard let resolved = reconciledRecoveryManifest(
      from: Array(candidatesByID.values),
      storeURL: storeURL
    ) else {
      return StoreState(current: primary, previous: previous, recoveryStatus: .healthy)
    }
    if resolved.commitID == primary.commitID {
      return StoreState(current: primary, previous: previous, recoveryStatus: .healthy)
    }
    return StoreState(current: resolved, previous: primary, recoveryStatus: .healthy)
  }

  private static func loadManifest(
    named name: String,
    expectedDigest: String?,
    storeURL: URL
  ) -> Manifest? {
    guard name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
    guard let manifest = loadManifestCandidate(
      named: name,
      expectedDigest: expectedDigest,
      storeURL: storeURL
    ),
          isComplete(manifest, storeURL: storeURL)
    else { return nil }
    return manifest
  }

  private static func loadManifestCandidate(
    named name: String,
    expectedDigest: String?,
    storeURL: URL
  ) -> Manifest? {
    guard name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
    let url = manifestsDirectory(storeURL: storeURL).appendingPathComponent(name)
    return loadManifestCandidate(at: url, expectedDigest: expectedDigest)
  }

  private static func loadManifest(at url: URL) -> Manifest? {
    let storeURL = url.deletingLastPathComponent()
    guard let manifest = loadManifestCandidate(at: url),
          isComplete(manifest, storeURL: storeURL)
    else { return nil }
    return manifest
  }

  private static func loadManifestCandidate(
    at url: URL,
    expectedDigest: String? = nil
  ) -> Manifest? {
    guard !isSymbolicLink(url),
          let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          expectedDigest == nil || digest(data) == expectedDigest,
          let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
          isStructurallyValid(manifest)
    else { return nil }
    return manifest
  }

  private static func recoveryManifestCandidates(
    storeURL: URL,
    excludingCommitIDs: Set<String> = [],
    includesRootViews: Bool = true
  ) -> [Manifest] {
    let fileManager = FileManager.default
    let manifestDirectory = manifestsDirectory(storeURL: storeURL)
    var urls = (try? fileManager.contentsOfDirectory(
      at: manifestDirectory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    let rootViews = ((try? fileManager.contentsOfDirectory(
      at: storeURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )) ?? []).filter {
      $0.lastPathComponent.hasPrefix("manifest") && $0.pathExtension == "json"
    }
    // Root views are redundant copies (or conflict copies) of immutable
    // commits. Routine reconciliation reads the immutable directory only.
    if includesRootViews { urls += rootViews }
    return urls.compactMap { url in
      if url.deletingLastPathComponent().standardizedFileURL == manifestDirectory.standardizedFileURL,
         url.pathExtension == "json",
         excludingCommitIDs.contains(url.deletingPathExtension().lastPathComponent) {
        return nil
      }
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true
      else { return nil }
      #if DEBUG
      recoveryCandidateDecodeCounter.increment()
      #endif
      guard let candidate = loadManifestCandidate(at: url),
            !excludingCommitIDs.contains(candidate.commitID)
      else { return nil }
      return candidate
    }
  }

  private static func reconciledRecoveryManifest(
    from candidates: [Manifest],
    storeURL: URL,
    stagedShards: StagedRepairShards? = nil
  ) -> Manifest? {
    let sorted = candidates.sorted {
      if $0.generation != $1.generation { return $0.generation > $1.generation }
      return $0.commitID > $1.commitID
    }
    var validatedEntries: [ManifestThread: Bool] = [:]
    func isValid(_ entry: ManifestThread) -> Bool {
      if let cached = validatedEntries[entry] { return cached }
      let valid = isValidShard(entry, storeURL: storeURL)
      validatedEntries[entry] = valid
      return valid
    }
    func isCompleteCandidate(_ manifest: Manifest) -> Bool {
      isStructurallyValid(manifest) && manifest.threads.allSatisfy(isValid)
    }
    guard let completeBase = sorted.first(where: isCompleteCandidate) else {
      return nil
    }

    var candidateEntries: [UUID: [RecoverySelectedEntry]] = [:]
    for candidate in sorted {
      for entry in candidate.threads {
        candidateEntries[entry.metadata.id, default: []].append(
          RecoverySelectedEntry(
            entry: entry,
            generation: candidate.generation,
            commitID: candidate.commitID
          )
        )
      }
    }
    var selectedEntries = candidateEntries.compactMapValues { revisions in
      revisions.sorted { prefersRecoveryEntry($0, over: $1) }.first(where: {
        isValid($0.entry)
      })
    }
    // A complete empty manifest is a valid conversation list too.

    // Two writers can extend the same conversation concurrently (a phone
    // message relayed by the server while this Mac finishes a turn). When
    // neither branch subsumes the other, keep both sides' messages instead
    // of letting the newer thread timestamp hide the other's work.
    var subsumedByCommit: [String: Set<String>] = [:]
    for candidate in sorted where subsumedByCommit[candidate.commitID] == nil {
      subsumedByCommit[candidate.commitID] = Set(
        [candidate.commitID]
          + (candidate.ancestorCommitIDs ?? [])
          + (candidate.mergedCommitIDs ?? [])
      )
    }
    let tipCommitIDs = Set(subsumedByCommit.keys.filter { commitID in
      !subsumedByCommit.contains { other, subsumed in
        other != commitID && subsumed.contains(commitID)
      }
    })
    for (threadID, selected) in selectedEntries {
      let subsumed = subsumedByCommit[selected.commitID] ?? [selected.commitID]
      var seenDigests: Set<String> = [selected.entry.shardDigest]
      let divergent = (candidateEntries[threadID] ?? []).filter { revision in
        tipCommitIDs.contains(revision.commitID)
          && !subsumed.contains(revision.commitID)
          && seenDigests.insert(revision.entry.shardDigest).inserted
          && isValid(revision.entry)
      }
      guard !divergent.isEmpty,
            let merged = unionMergedEntry(
              selected.entry,
              with: divergent.map(\.entry),
              storeURL: storeURL,
              stagedShards: stagedShards
            )
      else { continue }
      selectedEntries[threadID] = RecoverySelectedEntry(
        entry: merged,
        generation: selected.generation,
        commitID: selected.commitID
      )
    }

    let baseIDs = completeBase.threads.map { $0.metadata.id }
    let additionalIDs = selectedEntries.keys.filter { !baseIDs.contains($0) }.sorted {
      let left = selectedEntries[$0]?.entry.metadata.updatedAt ?? .distantPast
      let right = selectedEntries[$1]?.entry.metadata.updatedAt ?? .distantPast
      if left != right { return left > right }
      return $0.uuidString < $1.uuidString
    }
    let entries = (baseIDs + additionalIDs).compactMap { selectedEntries[$0]?.entry }
    let context = sorted.first ?? completeBase
    let ancestorCommitIDs = boundedCommitIDs(
      [completeBase.commitID] + (completeBase.ancestorCommitIDs ?? [])
    )
    let mergedCommitIDs = Array(Set(candidates.flatMap { candidate in
      [candidate.commitID] + (candidate.mergedCommitIDs ?? [])
    }).subtracting(ancestorCommitIDs).subtracting([completeBase.commitID])).sorted()
    let selectedThreadID = context.selectedThreadID.flatMap { id in
      selectedEntries[id] == nil ? nil : id
    } ?? completeBase.selectedThreadID.flatMap { id in
      selectedEntries[id] == nil ? nil : id
    } ?? entries.first?.metadata.id
    let matchesCompleteBase = entries.count == completeBase.threads.count
      && zip(entries, completeBase.threads).allSatisfy { recovered, base in
        recovered.metadata == base.metadata
          && recovered.shard == base.shard
          && recovered.shardDigest == base.shardDigest
          && recovered.blobs == base.blobs
      }
      && selectedThreadID == completeBase.selectedThreadID
      && context.settlementSettings == completeBase.settlementSettings
    let recordedMergedCommitIDs = Set(completeBase.mergedCommitIDs ?? [])
    let commitsNeedingRecord = Set(mergedCommitIDs).subtracting([completeBase.commitID])
    if matchesCompleteBase && recordedMergedCommitIDs.isSuperset(of: commitsNeedingRecord) {
      return completeBase
    }
    return Manifest(
      schema: Manifest.schemaValue,
      version: 2,
      generation: (sorted.map(\.generation).max() ?? completeBase.generation) &+ 1,
      commitID: "recovered-\(UUID().uuidString.lowercased())",
      parentCommitID: completeBase.commitID,
      ancestorCommitIDs: ancestorCommitIDs,
      mergedCommitIDs: mergedCommitIDs,
      threads: entries,
      selectedThreadID: selectedThreadID,
      settlementSettings: context.settlementSettings
    )
  }

  private static func prefersRecoveryEntry(
    _ candidate: RecoverySelectedEntry,
    over existing: RecoverySelectedEntry
  ) -> Bool {
    if candidate.entry.metadata.updatedAt != existing.entry.metadata.updatedAt {
      return candidate.entry.metadata.updatedAt > existing.entry.metadata.updatedAt
    }
    let candidateCount = candidate.entry.metadata.storedMessageCount ?? -1
    let existingCount = existing.entry.metadata.storedMessageCount ?? -1
    if candidateCount != existingCount { return candidateCount > existingCount }
    if candidate.generation != existing.generation {
      return candidate.generation > existing.generation
    }
    return candidate.entry.shardDigest > existing.entry.shardDigest
  }

  private static func isStructurallyValid(_ manifest: Manifest) -> Bool {
    let ancestorCommitIDs = manifest.ancestorCommitIDs ?? []
    let mergedCommitIDs = manifest.mergedCommitIDs ?? []
    guard CelorgaNames.schemaMatches(manifest.schema, Manifest.schemaValue),
          manifest.version == 2,
          !manifest.commitID.isEmpty,
          manifest.commitID == URL(fileURLWithPath: manifest.commitID).lastPathComponent,
          ancestorCommitIDs.count <= manifestAncestryLimit,
          Set(ancestorCommitIDs).count == ancestorCommitIDs.count,
          ancestorCommitIDs.allSatisfy({
            !$0.isEmpty && $0 == URL(fileURLWithPath: $0).lastPathComponent
          }),
          Set(mergedCommitIDs).count == mergedCommitIDs.count,
          mergedCommitIDs.allSatisfy({
            !$0.isEmpty && $0 == URL(fileURLWithPath: $0).lastPathComponent
          }),
          manifest.selectedThreadID == nil
            || manifest.threads.contains(where: { $0.metadata.id == manifest.selectedThreadID })
    else { return false }
    return Set(manifest.threads.map { $0.metadata.id }).count == manifest.threads.count
  }

  /// A manifest is a usable commit only when every immutable shard it names
  /// is present and independently verifies. Validating this transitively at
  /// commit selection keeps a corrupt newest shard from being mistaken for a
  /// healthy metadata-only thread and lets recovery choose the previous
  /// complete commit instead.
  private static func isComplete(_ manifest: Manifest, storeURL: URL) -> Bool {
    guard isStructurallyValid(manifest) else { return false }
    for entry in manifest.threads {
      guard isValidShard(entry, storeURL: storeURL) else { return false }
    }
    return true
  }

  /// Shards are immutable and content-addressed. Cache successful full
  /// validations keyed by the entry and the file's size and modification
  /// time, so selecting a commit does not rehash every conversation on each
  /// save while a replaced, truncated, or deleted file is still revalidated.
  private final class ShardValidationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var validated: Set<String> = []

    func contains(_ key: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return validated.contains(key)
    }

    func insert(_ key: String) {
      lock.lock()
      if validated.count > 20_000 { validated.removeAll(keepingCapacity: true) }
      validated.insert(key)
      lock.unlock()
    }
  }

  private static let shardValidationCache = ShardValidationCache()

  private static func shardValidationKey(_ entry: ManifestThread, storeURL: URL) -> String? {
    let url = storeURL.appendingPathComponent(entry.shard)
    guard let values = try? url.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
    ]),
          values.isRegularFile == true,
          let size = values.fileSize,
          let modifiedAt = values.contentModificationDate
    else { return nil }
    let count = entry.metadata.storedMessageCount.map(String.init) ?? "-"
    let blobs = entry.blobs?.joined(separator: ",") ?? "-"
    return [
      url.path, entry.shardDigest, count, blobs, String(size),
      String(modifiedAt.timeIntervalSinceReferenceDate),
    ].joined(separator: "|")
  }

  private static func isValidShard(_ entry: ManifestThread, storeURL: URL) -> Bool {
    if let key = shardValidationKey(entry, storeURL: storeURL),
       shardValidationCache.contains(key) {
      return true
    }
    return loadThreadShard(entry, storeURL: storeURL) != nil
  }

  private static func loadThreadShard(
    _ entry: ManifestThread,
    storeURL: URL
  ) -> ThreadShard? {
    #if DEBUG
    threadShardDecodeCounter.increment()
    #endif
    let threadDirectory = threadsDirectory(storeURL: storeURL)
    let shardName = URL(fileURLWithPath: entry.shard).lastPathComponent
    guard entry.shard == "threads/\(shardName)",
          isValidDigest(entry.shardDigest)
    else { return nil }
    let shardURL = storeURL.appendingPathComponent(entry.shard)
    guard isDescendant(shardURL, of: threadDirectory),
          !isSymbolicLink(shardURL),
          let data = try? Data(contentsOf: shardURL, options: .mappedIfSafe),
          digest(data) == entry.shardDigest,
          let shard = try? JSONDecoder().decode(ThreadShard.self, from: data),
          CelorgaNames.schemaMatches(shard.schema, ThreadShard.schemaValue),
          shard.version == 1,
          validateStoredReferences(shard, storeURL: storeURL)
    else { return nil }
    if let storedCount = entry.metadata.storedMessageCount {
      let visibleCount = shard.messages.lazy.filter { !$0.message.isRoomDispatchCopy }.count
      guard storedCount == visibleCount else { return nil }
    } else {
      return nil
    }
    if let blobs = entry.blobs {
      let referenced = Set(shard.messages.flatMap { $0.attachments.map(\.blob) })
      guard Set(blobs) == referenced, Set(blobs).count == blobs.count else { return nil }
    }
    if let key = shardValidationKey(entry, storeURL: storeURL) {
      shardValidationCache.insert(key)
    }
    return shard
  }

  private static func validateStoredReferences(
    _ shard: ThreadShard,
    storeURL: URL
  ) -> Bool {
    let attachmentDirectory = attachmentsDirectory(storeURL: storeURL)
    return shard.messages.allSatisfy { stored in
      stored.attachments.allSatisfy { reference in
        guard reference.byteCount >= 0,
              isValidDigest(reference.digest),
              reference.blob == "\(reference.digest).blob",
              reference.blob == URL(fileURLWithPath: reference.blob).lastPathComponent
        else { return false }
        return isDescendant(
          attachmentDirectory.appendingPathComponent(reference.blob),
          of: attachmentDirectory
        )
      }
    }
  }

  private static func isValidDigest(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (97...102).contains(byte)
    }
  }

  // Cleanup remains serialized with commits, but a newly queued durable write
  // can preempt the expensive historical-manifest scan before any deletion.
  private static func garbageCollect(
    legacyURL: URL,
    shouldYield: () -> Bool = { false }
  ) -> Bool {
    guard let state = loadStoreState(legacyURL: legacyURL),
          !state.recoveryStatus.blocksWrites,
          let current = state.current
    else { return true }
    guard !shouldYield() else { return false }
    let storeURL = storeDirectory(for: legacyURL)
    let cutoff = Date().addingTimeInterval(-garbageCollectionGraceInterval)
    let recentManifestFiles = recoveryManifestFiles(
      storeURL: storeURL,
      modifiedAfter: cutoff,
      shouldYield: shouldYield
    )
    guard !shouldYield() else { return false }
    // Every writer's head (and its previous commit) stays loadable even when
    // that writer has been offline longer than the grace interval.
    let headManifests = headPointers(storeURL: storeURL).flatMap { pointer in
      [
        loadManifestCandidate(
          named: pointer.currentManifest,
          expectedDigest: pointer.currentDigest,
          storeURL: storeURL
        ),
        pointer.previousManifest.flatMap {
          loadManifestCandidate(named: $0, expectedDigest: pointer.previousDigest, storeURL: storeURL)
        },
      ].compactMap { $0 }
    }
    let retainedManifests = [current, state.previous].compactMap { $0 }
      + recentManifestFiles.map(\.manifest)
      + headManifests
    var retainedCommitFiles = Set(retainedManifests.map { "\($0.commitID).json" })
    retainedCommitFiles.formUnion(recentManifestFiles.compactMap { file in
      file.url.deletingLastPathComponent().standardizedFileURL
        == manifestsDirectory(storeURL: storeURL).standardizedFileURL
        ? file.url.lastPathComponent
        : nil
    })
    // Historical manifests often repeat the same immutable shard. Collect
    // references incrementally and decode each legacy shard at most once,
    // rather than materializing every repeated thread entry in memory.
    var retainedShards = Set<String>()
    var retainedBlobs = Set<String>()
    var entriesWithoutBlobIndexes: [String: ManifestThread] = [:]
    for manifest in retainedManifests {
      for entry in manifest.threads {
        retainedShards.insert(entry.shard)
        if let blobs = entry.blobs {
          retainedBlobs.formUnion(blobs)
        } else {
          entriesWithoutBlobIndexes[entry.shard] = entry
        }
      }
    }
    for entry in entriesWithoutBlobIndexes.values {
      let shard = entry.shard
      let shardURL = storeURL.appendingPathComponent(shard)
      guard isDescendant(shardURL, of: threadsDirectory(storeURL: storeURL)),
            let data = try? Data(contentsOf: shardURL, options: .mappedIfSafe),
            let decoded = try? JSONDecoder().decode(ThreadShard.self, from: data)
      else { continue }
      retainedBlobs.formUnion(decoded.messages.flatMap { $0.attachments.map(\.blob) })
    }

    guard !shouldYield() else { return false }
    removeUnretainedFiles(
      in: manifestsDirectory(storeURL: storeURL),
      retaining: retainedCommitFiles,
      modifiedBefore: nil
    )
    removeUnretainedFiles(
      in: threadsDirectory(storeURL: storeURL),
      retaining: Set(retainedShards.map { URL(fileURLWithPath: $0).lastPathComponent }),
      modifiedBefore: cutoff
    )
    removeUnretainedFiles(
      in: attachmentsDirectory(storeURL: storeURL),
      retaining: retainedBlobs,
      modifiedBefore: cutoff
    )
    return true
  }

#if DEBUG
  static func collectGarbageForTesting(
    legacyURL: URL, shouldYield: () -> Bool
  ) -> Bool {
    garbageCollect(legacyURL: legacyURL, shouldYield: shouldYield)
  }
#endif

  private struct RecoveryManifestFile {
    let url: URL
    let manifest: Manifest
  }

  private struct RecoverySelectedEntry {
    let entry: ManifestThread
    let generation: UInt64
    let commitID: String
  }

  /// Persist the message union of divergent revisions as a new immutable,
  /// content-addressed shard. Identical inputs produce identical bytes on
  /// every replica, so concurrent readers converge on the same file.
  private static func unionMergedEntry(
    _ primary: ManifestThread,
    with others: [ManifestThread],
    storeURL: URL,
    stagedShards: StagedRepairShards? = nil
  ) -> ManifestThread? {
    guard let primaryShard = loadThreadShard(primary, storeURL: storeURL) else { return nil }
    var tombstones = primary.deletedMessageIDs ?? []
    var messages = primaryShard.messages
    var latest = primary.metadata.updatedAt
    for other in others {
      guard let shard = loadThreadShard(other, storeURL: storeURL) else { continue }
      tombstones += other.deletedMessageIDs ?? []
      messages = unionMerge(primary: messages, other: shard.messages, tombstones: Set(tombstones))
      latest = max(latest, other.metadata.updatedAt)
    }
    tombstones = boundedTombstones(tombstones)
    guard messages != primaryShard.messages else { return nil }
    guard let shardData = try? encoder.encode(ThreadShard(
      schema: ThreadShard.schemaValue,
      version: 1,
      messages: messages
    )) else { return nil }
    let shardDigest = digest(shardData)
    let threadID = primary.metadata.id
    let shardName = "threads/\(threadID.uuidString.lowercased())-\(shardDigest.prefix(20)).json"
    do {
      let url = storeURL.appendingPathComponent(shardName)
      if let stagedShards { stagedShards.files[url] = shardData }
      else { try writeIfChanged(shardData, to: url) }
    } catch {
      return nil
    }
    let metadata = primary.metadata
      .hydrating(messages: messages.map(\.message))
      .replacingUpdatedAt(latest)
      .metadataOnly()
    return ManifestThread(
      metadata: metadata,
      shard: shardName,
      shardDigest: shardDigest,
      blobs: Set(messages.flatMap { $0.attachments.map(\.blob) }).sorted(),
      deletedMessageIDs: tombstones.isEmpty ? nil : tombstones
    )
  }

  private static func recoveryManifestFiles(
    storeURL: URL,
    modifiedAfter cutoff: Date,
    shouldYield: () -> Bool = { false }
  ) -> [RecoveryManifestFile] {
    let fileManager = FileManager.default
    let manifestDirectory = manifestsDirectory(storeURL: storeURL)
    var urls = (try? fileManager.contentsOfDirectory(
      at: manifestDirectory,
      includingPropertiesForKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
      ],
      options: [.skipsHiddenFiles]
    )) ?? []
    urls += ((try? fileManager.contentsOfDirectory(
      at: storeURL,
      includingPropertiesForKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
      ],
      options: [.skipsHiddenFiles]
    )) ?? []).filter {
      $0.lastPathComponent.hasPrefix("manifest") && $0.pathExtension == "json"
    }
    let candidates = urls.compactMap { url -> RecoveryManifestFile? in
      guard !shouldYield() else { return nil }
      guard let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
      ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let modifiedAt = values.contentModificationDate,
            modifiedAt >= cutoff,
            let manifest = loadManifestCandidate(at: url)
      else { return nil }
      return RecoveryManifestFile(url: url, manifest: manifest)
    }
    // Keep each recently observed branch tip plus its direct parent. That is
    // enough to recover from an incomplete synced tip without retaining a
    // full 500 KB manifest for every routine local metadata save.
    let parentCommitIDs = Set(candidates.compactMap(\.manifest.parentCommitID))
    let tips = candidates.filter { !parentCommitIDs.contains($0.manifest.commitID) }
    let retainedCommitIDs = Set(tips.flatMap { file in
      [file.manifest.commitID, file.manifest.parentCommitID].compactMap { $0 }
    })
    return candidates.filter { retainedCommitIDs.contains($0.manifest.commitID) }
  }

  private static func removeUnretainedFiles(
    in directory: URL,
    retaining names: Set<String>,
    modifiedBefore cutoff: Date?
  ) {
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
      ],
      options: [.skipsHiddenFiles]
    ) else { return }
    for url in urls where !names.contains(url.lastPathComponent) {
      guard isDescendant(url, of: directory),
            let values = try? url.resourceValues(forKeys: [
              .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
            ]),
            values.isRegularFile == true || values.isSymbolicLink == true
      else { continue }
      if let cutoff {
        guard let modifiedAt = values.contentModificationDate, modifiedAt < cutoff else { continue }
      }
      try? FileManager.default.removeItem(at: url)
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func boundedCommitIDs(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values where seen.insert(value).inserted {
      result.append(value)
      if result.count == manifestAncestryLimit { break }
    }
    return result
  }

  private static func writeIfChanged(_ data: Data, to url: URL) throws {
    if let existing = try? Data(contentsOf: url, options: .mappedIfSafe), existing == data { return }
    try data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func isDescendant(_ url: URL, of directory: URL) -> Bool {
    let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
    return resolvedURL.path.hasPrefix(resolvedDirectory.path + "/")
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private static func threadsDirectory(storeURL: URL) -> URL {
    storeURL.appendingPathComponent("threads", isDirectory: true)
  }

  private static func attachmentsDirectory(storeURL: URL) -> URL {
    storeURL.appendingPathComponent("attachments", isDirectory: true)
  }

  private static func manifestsDirectory(storeURL: URL) -> URL {
    storeURL.appendingPathComponent("manifests", isDirectory: true)
  }

  private static func headsDirectory(storeURL: URL) -> URL {
    storeURL.appendingPathComponent(headsDirectoryName, isDirectory: true)
  }
}

private struct StoreState {
  let current: Manifest?
  let previous: Manifest?
  let recoveryStatus: AIChatTranscriptRecoveryStatus
}

private struct StoreMarker: Codable {
  static let schemaValue = "org2:ai-chat-transcript-store-marker:v1"
  let schema: String
  let version: Int
  let currentManifest: String
  let currentDigest: String
  let previousManifest: String?
  let previousDigest: String?
}

private struct Manifest: Codable {
  static let schemaValue = "org2:ai-chat-transcript-manifest:v2"
  let schema: String
  let version: Int
  let generation: UInt64
  let commitID: String
  let parentCommitID: String?
  let ancestorCommitIDs: [String]?
  let mergedCommitIDs: [String]?
  let threads: [ManifestThread]
  let selectedThreadID: UUID?
  let settlementSettings: AIChatThreadSettlementSettings
}

private struct ManifestThread: Codable, Hashable {
  let metadata: AIChatThread
  let shard: String
  let shardDigest: String
  let blobs: [String]?
  /// Message IDs a writer deliberately removed (for example a dequeued
  /// follow-up). Merges never resurrect them from a replica.
  var deletedMessageIDs: [UUID]? = nil
}

private struct StoreHead: Codable {
  static let schemaValue = "org2:ai-chat-transcript-head:v1"
  let schema: String
  let version: Int
  let writerID: String
  let writerLabel: String?
  let currentManifest: String
  let currentDigest: String
  let currentGeneration: UInt64
  let previousManifest: String?
  let previousDigest: String?
  let updatedAt: Date
}

struct AdoptedThreadBase: Sendable {
  let messages: [AIChatMessage]
  /// Digest of the shard this process last committed for the thread. When
  /// the persisted revision still has this digest no replica changed it.
  let writtenShardDigest: String?
  let sequence: UInt64
}

private struct LegacyManifest: Codable {
  static let schemaValue = "org2:ai-chat-transcript-manifest:v1"
  let schema: String
  let version: Int
  let threads: [AIChatThread]
  let selectedThreadID: UUID?
  let settlementSettings: AIChatThreadSettlementSettings
}

private struct ThreadShard: Codable {
  static let schemaValue = "org2:ai-chat-thread:v1"
  let schema: String
  let version: Int
  let messages: [StoredMessage]
}

private struct StoredMessage: Codable, Hashable {
  let message: AIChatMessage
  let attachments: [StoredAttachment]
}

private struct StoredAttachment: Codable, Hashable {
  let id: UUID
  let fileName: String
  let mimeType: String
  let blob: String
  let byteCount: Int
  let digest: String
}

private enum TranscriptStoreError: LocalizedError {
  case missingShard(UUID)
  case invalidAttachment(String)
  case invalidAttachmentBlob(String)
  case unrecoverableStore(String)
  case unsafeStorePath

  var errorDescription: String? {
    switch self {
    case .missingShard(let id):
      "Cannot persist metadata-only AI chat thread \(id) because its message shard is missing."
    case .invalidAttachment(let name):
      "AI chat attachment \(name) does not match its stored size or digest."
    case .invalidAttachmentBlob(let name):
      "AI chat attachment blob \(name) is corrupt; it was not overwritten."
    case .unrecoverableStore(let message):
      message
    case .unsafeStorePath:
      "AI chat storage directories must not be symbolic links."
    }
  }
}

private extension AIChatTranscriptRecoveryStatus {
  var description: String {
    switch self {
    case .healthy: "AI chat storage is healthy."
    case .recoveredPreviousManifest: "AI chat storage recovered its previous manifest."
    case .unrecoverable(let message): message
    }
  }
}
