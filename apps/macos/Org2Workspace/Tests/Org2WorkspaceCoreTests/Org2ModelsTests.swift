import AppKit
@preconcurrency import AVFoundation
import Combine
import Observation
import SwiftUI
import WebKit
import XCTest
@testable import Org2WorkspaceCore

@MainActor
private final class DelayedCorpusEventReceiver {
  weak var store: WorkspaceStore?
}

private struct DecodeThreadPayload: Decodable {
  let decodedOnMainThread: Bool

  init(from decoder: Decoder) throws {
    decodedOnMainThread = Thread.isMainThread
  }
}

private actor ControlledOrgHTMLFileLinkResolver {
  private var continuations: [String: CheckedContinuation<OrgHTMLResolvedFileTarget?, Never>] = [:]

  func resolve(_ target: String) async -> OrgHTMLResolvedFileTarget? {
    await withCheckedContinuation { continuation in
      continuations[target] = continuation
    }
  }

  func hasRequest(_ target: String) -> Bool {
    continuations[target] != nil
  }

  func complete(_ target: String, with result: OrgHTMLResolvedFileTarget?) {
    continuations.removeValue(forKey: target)?.resume(returning: result)
  }
}

private final class ThreadSafeTestFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var isSet = false

  var value: Bool {
    lock.withLock { isSet }
  }

  func setIfUnset() -> Bool {
    lock.withLock {
      guard !isSet else { return false }
      isSet = true
      return true
    }
  }
}

private final class ThreadSafeStringRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var values: [String] {
    lock.withLock { storage }
  }

  func append(_ value: String) {
    lock.withLock {
      storage.append(value)
    }
  }
}

private final class ThreadSafeIntRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Int] = []

  var last: Int? {
    lock.withLock { storage.last }
  }

  var count: Int {
    lock.withLock { storage.count }
  }

  func append(_ value: Int) {
    lock.withLock {
      storage.append(value)
    }
  }
}

private final class ThreadSafeBoolRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Bool] = []

  var values: [Bool] {
    lock.withLock { storage }
  }

  func append(_ value: Bool) {
    lock.withLock { storage.append(value) }
  }
}

private final class ThreadSafeCLIMetricRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Org2CLIInvocationMetric] = []

  var values: [Org2CLIInvocationMetric] {
    lock.withLock { storage }
  }

  func append(_ value: Org2CLIInvocationMetric) {
    lock.withLock { storage.append(value) }
  }
}

private final class ControlledDailyNoteDirectoryResolver: @unchecked Sendable {
  private let lock = NSLock()
  private let firstStarted = DispatchSemaphore(value: 0)
  private let releaseFirst = DispatchSemaphore(value: 0)
  private let firstDirectoryName: String
  private let laterDirectoryName: String
  private var callCount = 0
  private var hasReleasedFirst = false

  init(firstDirectoryName: String, laterDirectoryName: String) {
    self.firstDirectoryName = firstDirectoryName
    self.laterDirectoryName = laterDirectoryName
  }

  func resolve(_ root: URL) -> URL {
    let call = lock.withLock {
      callCount += 1
      return callCount
    }
    let directoryName: String
    if call == 1 {
      firstStarted.signal()
      _ = releaseFirst.wait(timeout: .now() + 5)
      directoryName = firstDirectoryName
    } else {
      directoryName = laterDirectoryName
    }
    return root.appendingPathComponent(directoryName, isDirectory: true).standardizedFileURL
  }

  func waitUntilFirstResolutionStarts(timeout: TimeInterval = 2) -> Bool {
    firstStarted.wait(timeout: .now() + timeout) == .success
  }

  func releaseFirstResolution() {
    let shouldRelease = lock.withLock {
      guard !hasReleasedFirst else { return false }
      hasReleasedFirst = true
      return true
    }
    if shouldRelease { releaseFirst.signal() }
  }
}

private actor DataNotebookInspectionGate {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    started = true
    startWaiters.forEach { $0.resume() }
    startWaiters = []
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor AgendaRefreshPublicationGate {
  private var started = false
  private var continuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    started = true
    startWaiters.forEach { $0.resume() }
    startWaiters = []
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private final class FluidVoiceTestURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  static func setRequestHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
    lock.withLock { requestHandler = handler }
  }

  static func reset() {
    lock.withLock { requestHandler = nil }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = Self.lock.withLock { Self.requestHandler }
      let (response, data) = try XCTUnwrap(handler)(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private struct AIChatTranscriptFixture: Encodable {
  let version: Int
  let messages: [AIChatMessage]?
  let threads: [AIChatThread]
  let selectedThreadID: UUID?
}

private actor AIChatRecoveryRecorder {
  private var turns: [AIChatPendingTurn] = []

  func recover(_ turn: AIChatPendingTurn) -> String {
    turns.append(turn)
    return "Recovered after relaunch"
  }

  func recordedTurns() -> [AIChatPendingTurn] {
    turns
  }
}

private actor AIChatRelaunchRecoveryRecorder {
  private var slowRecoveryStarted = false
  private var slowRecoveryContinuation: CheckedContinuation<String, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func recover(_ turn: AIChatPendingTurn) async -> String {
    guard turn.runID == "slow-recovery" else {
      return "Recovered fast turn"
    }
    slowRecoveryStarted = true
    for waiter in startWaiters {
      waiter.resume()
    }
    startWaiters = []
    return await withCheckedContinuation { continuation in
      slowRecoveryContinuation = continuation
    }
  }

  func waitUntilSlowRecoveryStarts() async {
    guard !slowRecoveryStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func finishSlowRecovery() {
    slowRecoveryContinuation?.resume(returning: "Recovered slow turn")
    slowRecoveryContinuation = nil
  }
}

private actor AIChatStoppedRecoveryRecorder {
  private var attempts = 0

  func recover(_: AIChatPendingTurn) throws -> String {
    attempts += 1
    throw OpenClawGatewayError.aborted(nil)
  }

  func attemptCount() -> Int {
    attempts
  }
}

private actor AIChatTerminalRecoveryRecorder {
  private var attempts = 0

  func recover(_: AIChatPendingTurn) throws -> String {
    attempts += 1
    throw OpenClawGatewayError.acceptedRunTerminated("OpenClaw session ended with status failed.")
  }

  func attemptCount() -> Int {
    attempts
  }
}

private actor AIChatQueuedSendRecorder {
  private var calls: [[String]] = []

  func send(messages: [AIChatMessage]) async throws -> String {
    calls.append(messages.map { "\($0.role.rawValue):\($0.content)" })
    try await Task.sleep(nanoseconds: 200_000_000)
    return "reply \(calls.count)"
  }

  func recordedCalls() -> [[String]] {
    calls
  }
}

private actor AIChatMessageSendRecorder {
  private var calls: [[AIChatMessage]] = []

  func send(messages: [AIChatMessage]) async throws -> String {
    calls.append(messages)
    return "reply \(calls.count)"
  }

  func recordedCalls() -> [[AIChatMessage]] {
    calls
  }
}

private struct RecordedAIChatWorkspaceContext: Sendable {
  let prompt: String
  let selectedLocationTitle: String?
  let continuationTitle: String?
  let continuationReferences: [String]
}

private actor AIChatWorkspaceContextRecorder {
  private var contexts: [RecordedAIChatWorkspaceContext] = []

  func send(context: AIChatWorkspaceContext?) -> String {
    contexts.append(RecordedAIChatWorkspaceContext(
      prompt: context?.systemPrompt() ?? "",
      selectedLocationTitle: context?.selectedLocation?.title,
      continuationTitle: context?.threadContinuation?.title,
      continuationReferences: context?.threadContinuation?.org2References ?? []
    ))
    return "Scoped reply"
  }

  func recordedContexts() -> [RecordedAIChatWorkspaceContext] {
    contexts
  }
}

private struct AIChatTestSendError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? {
    message
  }
}

private actor AIChatRetrySendRecorder {
  private var attempts = 0

  func send(messages: [AIChatMessage]) async throws -> String {
    attempts += 1
    if attempts == 1 {
      throw AIChatTestSendError(message: "VPN disconnected")
    }
    return "reply after reconnect"
  }

  func attemptCount() -> Int {
    attempts
  }
}

private actor AIChatSuspendedSendRecorder {
  private var started = false
  private var continuation: CheckedContinuation<String, Never>?
  private var startedContinuations: [CheckedContinuation<Void, Never>] = []

  func send(messages: [AIChatMessage]) async throws -> String {
    started = true
    for startedContinuation in startedContinuations {
      startedContinuation.resume()
    }
    startedContinuations = []
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func hasStarted() -> Bool {
    started
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startedContinuations.append(continuation)
    }
  }

  func finish(reply: String) {
    continuation?.resume(returning: reply)
    continuation = nil
  }
}

private actor AIChatSteerRecorder {
  private var messages: [(AIChatRuntime, UUID, String)] = []

  func record(runtime: AIChatRuntime, threadID: UUID, content: String) {
    messages.append((runtime, threadID, content))
  }

  func recordedContents() -> [String] {
    messages.map { $0.2 }
  }
}

final class Org2ModelsTests: XCTestCase {
  func testNodeActionItemsPayloadDecodesBoundedQueryResult() throws {
    let data = Data(#"{"$schema":"org2:node-actions:v1","target":{"id":"11111111-1111-4111-8111-111111111111","title":"Gabby","entityType":"person","file":"people/gabby.org2","line":1},"policy":{"recentDays":30,"openLimit":6,"completedLimit":3},"counts":{"open":2,"recentlyCompleted":1},"open":[{"id":"action-1","title":"Gate OSS popularity leaderboard","todo":"TODO","file":"meetings/gabby.org2","line":8,"lineEnd":10,"relationship":"meeting","meeting":{"id":"meeting-1","title":"Gabby sync","file":"meetings/gabby.org2","line":1}}],"recentlyCompleted":[]}"#.utf8)

    let payload = try JSONDecoder().decode(NodeActionItemsPayload.self, from: data)

    XCTAssertEqual(payload.schema, "org2:node-actions:v1")
    XCTAssertEqual(payload.target.title, "Gabby")
    XCTAssertEqual(payload.counts.open, 2)
    XCTAssertEqual(payload.open.first?.relationship, "meeting")
    XCTAssertEqual(payload.open.first?.meeting?.title, "Gabby sync")
  }

  func testEntityPageDetectionUsesExplicitMetadataTagsOrKnownDirectories() {
    let personSource = EntrySource(
      file: "/corpus/notes/gabby.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "#+title: Gabby\n#+ORG2_ENTITY_TYPE: person\n",
      isSubtree: false
    )
    let companySource = EntrySource(
      file: "/corpus/notes/acme.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "#+title: Acme\n#+ENTITY_TYPE: company\n",
      isSubtree: false
    )
    let projectTagSource = EntrySource(
      file: "/corpus/notes/launch.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "#+title: Launch\n#+FILETAGS: :active:type_project:\n",
      isSubtree: false
    )
    let directorySource = EntrySource(
      file: "/corpus/companies/acme.org2",
      startLine: 1,
      endLineExclusive: 2,
      text: "#+title: Acme\n",
      isSubtree: false
    )
    let ordinarySource = EntrySource(
      file: "/corpus/notes/strategy.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "#+title: Strategy\n",
      isSubtree: false
    )
    let typedSubtree = EntrySource(
      file: "/corpus/people/gabby.org2",
      startLine: 8,
      endLineExclusive: 12,
      text: "* Notes :type_person:\n",
      isSubtree: true
    )

    XCTAssertEqual(WorkspaceStore.entityType(for: personSource)?.rawValue, "person")
    XCTAssertEqual(WorkspaceStore.entityType(for: companySource)?.rawValue, "company")
    XCTAssertEqual(WorkspaceStore.entityType(for: projectTagSource)?.rawValue, "project")
    XCTAssertEqual(WorkspaceStore.entityType(for: directorySource)?.rawValue, "company")
    XCTAssertNil(WorkspaceStore.entityType(for: ordinarySource))
    XCTAssertEqual(WorkspaceStore.entityType(for: typedSubtree)?.rawValue, "person")

    XCTAssertTrue(WorkspaceStore.showsEntityActionItems(for: personSource))
    XCTAssertTrue(WorkspaceStore.showsEntityActionItems(for: companySource))
    XCTAssertTrue(WorkspaceStore.showsEntityActionItems(for: projectTagSource))
    XCTAssertTrue(WorkspaceStore.showsEntityActionItems(for: directorySource))
    XCTAssertFalse(WorkspaceStore.showsEntityActionItems(for: ordinarySource))
    XCTAssertFalse(WorkspaceStore.showsEntityActionItems(for: typedSubtree))
  }

  @MainActor
  func testEntityPageLoadsActionItemsByStableNodeID() async throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "NodeActionItems-\(UUID().uuidString)"))
    let store = WorkspaceStore(defaults: defaults)
    let root = URL(fileURLWithPath: "/tmp/org2-entity-actions")
    let source = EntrySource(
      file: root.appendingPathComponent("companies/acme.org2").path,
      startLine: 1,
      endLineExclusive: 6,
      text: "#+title: Acme\n#+ORG2_ENTITY_TYPE: company\n:PROPERTIES:\n:ID: 11111111-1111-4111-8111-111111111111\n:END:\n",
      isSubtree: false
    )
    let payloadData = Data(#"{"$schema":"org2:node-actions:v1","target":{"id":"11111111-1111-4111-8111-111111111111","title":"Acme","entityType":"company","file":"companies/acme.org2","line":1},"policy":{"recentDays":30,"openLimit":6,"completedLimit":3},"counts":{"open":0,"recentlyCompleted":0},"open":[],"recentlyCompleted":[]}"#.utf8)
    let payload = try JSONDecoder().decode(NodeActionItemsPayload.self, from: payloadData)
    let recorder = ThreadSafeStringRecorder()
    store.corpusRoot = root
    store.selectedEntrySource = source
    store.nodeActionItemsLoaderForTesting = { object, loadedRoot in
      recorder.append("\(object)|\(loadedRoot.path)")
      return payload
    }

    await store.loadEntityActionItems(for: source)

    XCTAssertEqual(recorder.values, ["id:11111111-1111-4111-8111-111111111111|/tmp/org2-entity-actions"])
    XCTAssertEqual(store.entityActionItems?.target.title, "Acme")
    XCTAssertFalse(store.isLoadingEntityActionItems)
  }

  func testSettingFileEntityTypeCanonicalizesMetadataWithoutDisturbingOtherTags() throws {
    let source = EntrySource(
      file: "/corpus/notes/acme.org2",
      startLine: 1,
      endLineExclusive: 7,
      text: "#+title: Acme\n#+FILETAGS: :customer:type_person:\n#+ENTITY_TYPE: person\n\nNotes\n",
      isSubtree: false
    )

    let updated = try XCTUnwrap(
      WorkspaceStore.sourceTextSettingEntityType(source, entityType: Org2EntityType("company"))
    )
    XCTAssertTrue(updated.contains(":ORG2_ENTITY_TYPE: company"))
    XCTAssertTrue(updated.contains("#+FILETAGS: :customer:"))
    XCTAssertFalse(updated.contains("type_person"))
    XCTAssertFalse(updated.contains("#+ENTITY_TYPE:"))

    let updatedSource = EntrySource(
      file: source.file,
      startLine: 1,
      endLineExclusive: 6,
      text: updated,
      isSubtree: false
    )
    XCTAssertEqual(WorkspaceStore.entityType(for: updatedSource)?.rawValue, "company")

    let cleared = try XCTUnwrap(
      WorkspaceStore.sourceTextSettingEntityType(updatedSource, entityType: nil)
    )
    XCTAssertFalse(cleared.contains("ORG2_ENTITY_TYPE"))
    XCTAssertTrue(cleared.contains("#+FILETAGS: :customer:"))
  }

  func testSettingSubtreeEntityTypePreservesItsDirectProperties() throws {
    let source = EntrySource(
      file: "/corpus/projects.org2",
      startLine: 8,
      endLineExclusive: 16,
      text: "* Launch :active:type_person:\nSCHEDULED: <2026-08-25 Tue>\n:PROPERTIES:\n:ID: 22222222-2222-4222-8222-222222222222\n:END:\nNotes\n",
      isSubtree: true
    )

    let updated = try XCTUnwrap(
      WorkspaceStore.sourceTextSettingEntityType(source, entityType: Org2EntityType("project"))
    )
    XCTAssertTrue(updated.hasPrefix("* Launch :active:\n"))
    XCTAssertTrue(updated.contains(":ID: 22222222-2222-4222-8222-222222222222"))
    XCTAssertTrue(updated.contains(":ORG2_ENTITY_TYPE: project"))
    XCTAssertLessThan(
      try XCTUnwrap(updated.range(of: ":ORG2_ENTITY_TYPE: project")?.lowerBound),
      try XCTUnwrap(updated.range(of: ":END:")?.lowerBound)
    )

    let updatedSource = EntrySource(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.endLineExclusive,
      text: updated,
      isSubtree: true
    )
    XCTAssertEqual(WorkspaceStore.entityType(for: updatedSource)?.rawValue, "project")

    let cleared = try XCTUnwrap(
      WorkspaceStore.sourceTextSettingEntityType(updatedSource, entityType: nil)
    )
    XCTAssertFalse(cleared.contains("ORG2_ENTITY_TYPE"))
    XCTAssertTrue(cleared.contains(":ID: 22222222-2222-4222-8222-222222222222"))
  }

  func testEntityTypeNormalizesCustomValuesForStorageAndDisplay() throws {
    let entityType = try XCTUnwrap(Org2EntityType(" Customer Segment "))

    XCTAssertEqual(entityType.rawValue, "customer_segment")
    XCTAssertEqual(entityType.title, "Customer Segment")
    XCTAssertFalse(entityType.supportsActionItems)
  }

  func testWorkspaceSoundPlaybackIsSuppressedUnderXCTest() {
    XCTAssertTrue(WorkspaceSound.isPlaybackSuppressed)
    XCTAssertNotNil(WorkspaceSound.bundledNewMessageSoundURL)
  }

  func testWorkspaceCacheRecencyRefreshesEntriesAndBoundsMemory() {
    var order = ["alpha", "beta", "gamma"]

    XCTAssertEqual(
      WorkspaceCacheRecency.recordAccess("beta", order: &order, limit: 3),
      []
    )
    XCTAssertEqual(order, ["alpha", "gamma", "beta"])
    XCTAssertEqual(
      WorkspaceCacheRecency.recordAccess("delta", order: &order, limit: 3),
      ["alpha"]
    )
    XCTAssertEqual(order, ["gamma", "beta", "delta"])
  }

  func testCorpusMountWithoutPortableIdentityUsesNeutralLocalLabel() {
    let mount = WorkspaceCorpusMount(
      path: "/tmp/notes",
      corpusID: nil,
      name: "notes",
      kind: nil
    )

    XCTAssertEqual(mount.displayKind, "Local")
  }

  private func searchResult(
    file: String,
    line: Int,
    heading: String?,
    todo: String?,
    snippet: String = "Matched text"
  ) -> SearchResult {
    SearchResult(
      file: file,
      line: line,
      lineEnd: nil,
      heading: heading,
      headingLine: line,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: todo,
      tags: [],
      snippet: snippet,
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
  }

  func testInitializeStarterCorpusCreatesPlainTextWorkspace() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-starter-corpus-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let welcomeURL = try WorkspaceStore.initializeStarterCorpus(at: root)

    XCTAssertEqual(welcomeURL.standardizedFileURL.path, root.appendingPathComponent("notes/welcome.org").path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("celorga.json").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("org2.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox.org").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("daily").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("views").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("compiled").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("workflows").path))
    let skillURL = root.appendingPathComponent(".agents/skills/org2/SKILL.md")
    XCTAssertTrue(FileManager.default.fileExists(atPath: skillURL.path))
    XCTAssertTrue(try String(contentsOf: skillURL, encoding: .utf8).contains("celorga agent capabilities"))

    let welcome = try String(contentsOf: welcomeURL, encoding: .utf8)
    XCTAssertTrue(welcome.contains("#+TITLE: Welcome to Celorga"))
    XCTAssertTrue(welcome.contains("* Your workspace"))
    XCTAssertTrue(welcome.contains("Start on Home"))
    XCTAssertTrue(welcome.contains("move or rename this folder"))
    XCTAssertTrue(welcome.contains("Open =Help → Getting Started="))

    let configData = try Data(contentsOf: root.appendingPathComponent("celorga.json"))
    let config = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
    XCTAssertEqual(config["recursive"] as? Bool, true)
    XCTAssertNotNil(config["roam"] as? [String: Any])
    let identity = try XCTUnwrap(config["corpus"] as? [String: Any])
    XCTAssertEqual(identity["schema"] as? String, "org2:corpus:v1")
    XCTAssertEqual(identity["kind"] as? String, "personal")
    XCTAssertFalse((identity["id"] as? String ?? "").isEmpty)
  }

  func testBuiltInOrg2SkillInstallerNeverOverwritesACorpusCopy() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-built-in-skill-\(UUID().uuidString)", isDirectory: true)
    let destination = root.appendingPathComponent(".agents/skills/org2/SKILL.md")
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "user-managed\n".write(to: destination, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }

    let installed = try BuiltInOrg2Skill.installIfAbsent(in: root)

    XCTAssertEqual(installed.standardizedFileURL.path, destination.standardizedFileURL.path)
    XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "user-managed\n")
  }

  func testOrgDocumentDefaultsCreatesOrgButPreservesExistingOrg2Files() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org-document-defaults-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertEqual(OrgDocumentDefaults.url(in: root, baseName: "new").lastPathComponent, "new.org")

    let legacy = root.appendingPathComponent("existing.org2")
    try "* Existing\n".write(to: legacy, atomically: true, encoding: .utf8)
    XCTAssertEqual(OrgDocumentDefaults.url(in: root, baseName: "existing"), legacy)

    let preferred = root.appendingPathComponent("existing.org")
    try "* Preferred\n".write(to: preferred, atomically: true, encoding: .utf8)
    XCTAssertEqual(OrgDocumentDefaults.url(in: root, baseName: "existing"), preferred)
  }

  func testStarterCorpusDefaultsToCelorgaAndReusesAnExistingOpenOrgWorkspace() throws {
    let documents = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-documents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: documents) }

    XCTAssertEqual(WorkspaceStore.starterCorpusURL(inDocuments: documents).lastPathComponent, "Celorga")

    // A folder named OpenOrg without a workspace in it is not reused.
    let legacy = documents.appendingPathComponent("OpenOrg", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    XCTAssertEqual(WorkspaceStore.starterCorpusURL(inDocuments: documents).lastPathComponent, "Celorga")

    try "{}\n".write(to: legacy.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)
    XCTAssertEqual(
      WorkspaceStore.starterCorpusURL(inDocuments: documents).path,
      legacy.standardizedFileURL.path
    )
  }

  func testAutomaticStarterCorpusUsesPreferredEmptyFolderAndAvoidsUnrelatedFiles() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-automatic-corpus-\(UUID().uuidString)", isDirectory: true)
    let preferred = parent.appendingPathComponent("Celorga", isDirectory: true)
    try FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)
    try "keep me\n".write(
      to: preferred.appendingPathComponent("unrelated.txt"),
      atomically: true,
      encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: parent) }

    let created = try WorkspaceStore.prepareAutomaticStarterCorpus(preferredRoot: preferred)

    XCTAssertEqual(created.lastPathComponent, "Celorga 2")
    XCTAssertTrue(FileManager.default.fileExists(atPath: created.appendingPathComponent("celorga.json").path))
    XCTAssertEqual(
      try String(contentsOf: preferred.appendingPathComponent("unrelated.txt"), encoding: .utf8),
      "keep me\n"
    )
  }

  @MainActor
  func testBootstrapCreatesStarterCorpusAndOpensHomeBeforeAgentSetup() async throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-first-run-\(UUID().uuidString)", isDirectory: true)
    let preferred = parent.appendingPathComponent("OpenOrg", isDirectory: true)
    let suiteName = "openorg-first-run-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: parent)
    }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      automaticStarterCorpusURL: preferred
    )

    await store.bootstrap()

    XCTAssertEqual(store.corpusRoot?.standardizedFileURL.path, preferred.standardizedFileURL.path)
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertTrue(store.hasWorkspaceDetailContent)
    XCTAssertTrue(store.isLaunchGuidePresented)
    XCTAssertTrue(FileManager.default.fileExists(atPath: preferred.appendingPathComponent("celorga.json").path))
    XCTAssertTrue(store.selectedLocation?.file.contains("/daily/") == true)
  }

  @MainActor
  func testLaunchGuideCanBeReopenedAndCompletedWithoutChangingCompatibilityDomain() throws {
    let suiteName = "openorg-launch-guide-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    store.presentLaunchGuide()
    XCTAssertTrue(store.isLaunchGuidePresented)
    store.dismissLaunchGuide()
    XCTAssertFalse(store.isLaunchGuidePresented)

    store.presentLaunchGuide()
    store.completeLaunchGuide()
    XCTAssertFalse(store.isLaunchGuidePresented)
    XCTAssertTrue(defaults.bool(forKey: "Org2Workspace.openOrgLaunchGuideCompleted.v1"))
  }

  @MainActor
  func testLaunchGuideConnectsSelectedAgentAndLandsOnHome() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-launch-agent-\(UUID().uuidString)", isDirectory: true)
    let suiteName = "openorg-launch-agent-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try WorkspaceStore.initializeStarterCorpus(at: root)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(root)

    store.completeLaunchGuide(destinationID: AIChatDestinationConfiguration.localClaudeID)
    await store.waitForDailyNoteNavigationForTesting()

    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertEqual(
      store.selectedAIChatThread?.destinationID,
      AIChatDestinationConfiguration.localClaudeID
    )
    XCTAssertTrue(store.aiChatDestination(id: AIChatDestinationConfiguration.localClaudeID)?.isEnabled == true)
    XCTAssertTrue(store.selectedLocation?.file.contains("/daily/") == true)
    XCTAssertTrue(defaults.bool(forKey: "Org2Workspace.openOrgLaunchGuideCompleted.v1"))
  }

  @MainActor
  func testCorpusInfoCanBeUpdatedWithoutChangingItsStableIdentity() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("openorg-corpus-info-\(UUID().uuidString)", isDirectory: true)
    let suiteName = "openorg-corpus-info-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    _ = try WorkspaceStore.initializeStarterCorpus(at: root)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(root)
    await store.refreshActiveCorpusIdentity()
    let originalID = try XCTUnwrap(store.activeCorpusIdentity?.id)

    let updated = await store.updateActiveCorpusIdentity(name: "Marc's Workspace", kind: "project")

    XCTAssertTrue(updated)
    XCTAssertEqual(store.activeCorpusIdentity?.id, originalID)
    XCTAssertEqual(store.activeCorpusIdentity?.name, "Marc's Workspace")
    XCTAssertEqual(store.activeCorpusIdentity?.kind, "project")
  }

  func testInitializeSharedStarterCorpusRecordsPortableIdentity() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-shared-corpus-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try WorkspaceStore.initializeStarterCorpus(at: root, kind: "shared")

    let configData = try Data(contentsOf: root.appendingPathComponent("celorga.json"))
    let config = try XCTUnwrap(JSONSerialization.jsonObject(with: configData) as? [String: Any])
    let identity = try XCTUnwrap(config["corpus"] as? [String: Any])
    XCTAssertEqual(identity["kind"] as? String, "shared")
    XCTAssertEqual(identity["name"] as? String, root.lastPathComponent)
    XCTAssertNotNil((identity["id"] as? String)?.range(
      of: #"^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$"#,
      options: .regularExpression
    ))
  }

  @MainActor
  func testCorpusMountsPersistAcrossStoreInstances() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-corpus-mounts-\(UUID().uuidString)", isDirectory: true)
    let personal = container.appendingPathComponent("personal", isDirectory: true)
    let shared = container.appendingPathComponent("team", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    _ = try WorkspaceStore.initializeStarterCorpus(at: personal, kind: "personal")
    _ = try WorkspaceStore.initializeStarterCorpus(at: shared, kind: "shared")
    let suiteName = "org2-corpus-mounts-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(
      [personal.standardizedFileURL.path: "/remote/personal", shared.standardizedFileURL.path: "/remote/team"],
      forKey: "Org2Workspace.openClawRemoteCorpusPathsByCorpus.v1"
    )
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(personal)
    XCTAssertEqual(store.openClawRemoteCorpusPath, "/remote/personal")
    await store.refreshActiveCorpusIdentity()
    store.setCorpusRoot(shared)
    XCTAssertEqual(store.openClawRemoteCorpusPath, "/remote/team")
    await store.refreshActiveCorpusIdentity()

    XCTAssertEqual(store.mountedCorpora.count, 2)
    XCTAssertEqual(store.activeCorpusIdentity?.kind, "shared")
    XCTAssertEqual(store.mountedCorpora.first(where: { $0.path == personal.path })?.kind, "personal")

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    XCTAssertEqual(restored.mountedCorpora.count, 2)
    let personalMount = try XCTUnwrap(restored.mountedCorpora.first(where: { $0.path == personal.path }))
    restored.switchCorpus(to: personalMount)
    XCTAssertEqual(restored.corpusRoot?.path, personal.path)
  }

  @MainActor
  func testAgendaAndSearchCanReadAllMountedCorpora() async throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-federated-reads-\(UUID().uuidString)", isDirectory: true)
    let personal = container.appendingPathComponent("personal", isDirectory: true)
    let shared = container.appendingPathComponent("team", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    _ = try WorkspaceStore.initializeStarterCorpus(at: personal, kind: "personal")
    _ = try WorkspaceStore.initializeStarterCorpus(at: shared, kind: "shared")
    let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
    try "* TODO Personal item\nSCHEDULED: <\(day)>\nPersonal federation phrase.\n".write(
      to: personal.appendingPathComponent("notes/personal.org2"), atomically: true, encoding: .utf8
    )
    try "* TODO Shared item\nSCHEDULED: <\(day)>\nShared federation phrase.\n".write(
      to: shared.appendingPathComponent("notes/shared.org2"), atomically: true, encoding: .utf8
    )
    let suiteName = "org2-federated-reads-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    store.setCorpusRoot(personal)
    await store.refreshActiveCorpusIdentity()
    store.setCorpusRoot(shared)
    await store.refreshActiveCorpusIdentity()
    store.setCorpusRoot(personal)
    store.agendaReadScope = .allCorpora
    await store.refreshAgenda()

    XCTAssertEqual(store.agenda?.corpora?.count, 2)
    XCTAssertEqual(Set(store.agenda?.days.flatMap(\.items).compactMap { $0.corpus?.kind } ?? []), Set(["personal", "shared"]))

    store.searchReadScope = .allCorpora
    store.searchQuery = "federation phrase"
    await store.runSearch()
    XCTAssertEqual(Set(store.searchResults.compactMap { $0.corpus?.kind }), Set(["personal", "shared"]))
  }

  func testInitializeStarterCorpusRefusesNonemptyFolder() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-starter-corpus-nonempty-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let existing = root.appendingPathComponent("keep-me.txt")
    try "user data\n".write(to: existing, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try WorkspaceStore.initializeStarterCorpus(at: root))
    XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "user data\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("celorga.json").path))
  }

  func testDecodesAgendaPayload() throws {
    let json = """
    {
      "$schema": "org2:agenda:v1",
      "range": { "start": "2026-06-12", "end": "2026-06-18", "days": 7 },
      "overdue": [],
      "days": [
        {
          "date": "2026-06-12",
          "weekday": "Fri",
          "items": [
            {
              "todo": "TODO",
              "headline": "Review workspace",
          "kind": "SCHEDULED",
          "file": "/tmp/project.org2",
          "line": 4,
          "body": "Body with [[id:11111111-1111-4111-8111-111111111111][clean label]].",
          "level": 1,
          "tags": ["work"],
          "properties": { "EFFORT": "30m" },
          "priority": "A",
          "time": "09:00",
          "id": "22222222-2222-4222-8222-222222222222"
        }
          ]
        }
      ],
      "skippedFiles": 0
    }
    """

    let payload = try JSONDecoder().decode(AgendaPayload.self, from: Data(json.utf8))

    XCTAssertEqual(payload.totalItemCount, 1)
    XCTAssertEqual(payload.todayItemCount, 1)
    XCTAssertEqual(payload.days[0].items[0].lineForEditor, 5)
    XCTAssertEqual(payload.days[0].items[0].properties["EFFORT"], "30m")
    XCTAssertEqual(payload.days[0].items[0].tags, ["work"])
    XCTAssertEqual(payload.days[0].items[0].priority, "A")
  }

  func testDecodesCorpusQualifiedWorkspaceReads() throws {
    let agendaJSON = """
    {
      "$schema": "org2:workspace-agenda:v1",
      "range": { "start": "2026-07-20", "end": "2026-07-20", "days": 1 },
      "overdue": [],
      "days": [{
        "date": "2026-07-20",
        "weekday": "Mon",
        "items": [{
          "todo": "TODO", "headline": "Team planning", "kind": "SCHEDULED",
          "file": "/tmp/team/notes/plan.org2", "line": 0, "tags": [], "properties": {},
          "corpus": { "schema": "org2:corpus:v1", "id": "team", "name": "Team", "kind": "shared", "root": "/tmp/team" }
        }]
      }],
      "corpora": [{ "schema": "org2:corpus:v1", "id": "team", "name": "Team", "kind": "shared", "root": "/tmp/team" }],
      "issues": []
    }
    """
    let searchJSON = """
    {
      "$schema": "org2:workspace-search:v1", "query": "plan", "mode": "line", "sort": "scan",
      "results": [{
        "file": "/tmp/team/notes/plan.org2", "line": 1, "tags": [], "snippet": "Team planning",
        "corpus": { "schema": "org2:corpus:v1", "id": "team", "name": "Team", "kind": "shared", "root": "/tmp/team" }
      }],
      "corpora": [{ "schema": "org2:corpus:v1", "id": "team", "name": "Team", "kind": "shared", "root": "/tmp/team" }],
      "issues": []
    }
    """

    let agenda = try JSONDecoder().decode(AgendaPayload.self, from: Data(agendaJSON.utf8))
    let search = try JSONDecoder().decode(SearchPayload.self, from: Data(searchJSON.utf8))

    XCTAssertEqual(agenda.days[0].items[0].corpus?.id, "team")
    XCTAssertEqual(agenda.corpora?.first?.kind, "shared")
    XCTAssertEqual(search.results[0].corpus?.root, "/tmp/team")
    XCTAssertEqual(search.issues?.count, 0)
  }

  func testAgendaPriorityPillNormalizesOrgPriorityTokens() {
    XCTAssertEqual(AgendaPriorityPill.normalizedPriority("A"), "A")
    XCTAssertEqual(AgendaPriorityPill.normalizedPriority("b"), "B")
    XCTAssertEqual(AgendaPriorityPill.normalizedPriority("[#c]"), "C")
    XCTAssertEqual(AgendaPriorityPill.normalizedPriority("  [#1]  "), "1")
    XCTAssertNil(AgendaPriorityPill.normalizedPriority(nil))
    XCTAssertNil(AgendaPriorityPill.normalizedPriority(""))
    XCTAssertNil(AgendaPriorityPill.normalizedPriority("[#AA]"))
  }

  func testAgendaPriorityPillToneUsesSubtleABCLevels() {
    XCTAssertEqual(AgendaPriorityPill.tone(for: "A"), .urgent)
    XCTAssertEqual(AgendaPriorityPill.tone(for: "B"), .elevated)
    XCTAssertEqual(AgendaPriorityPill.tone(for: "C"), .quiet)
    XCTAssertEqual(AgendaPriorityPill.tone(for: "1"), .neutral)
  }

  func testDecodesSearchAndBacklinksPayloads() throws {
    let searchJSON = """
    {
      "$schema": "org2:search:v1",
      "query": "workspace",
      "mode": "line",
      "sort": "scan",
      "results": [
        {
          "file": "/tmp/project.org2",
          "line": 8,
          "lineEnd": 8,
          "heading": "Review workspace",
          "headingLine": 4,
          "headingLevel": 1,
          "headingAncestry": [],
          "id": "22222222-2222-4222-8222-222222222222",
          "todo": "TODO",
          "tags": [],
          "snippet": "Review workspace",
          "sourceRange": { "startLine": 8, "endLine": 8 },
          "matchedLines": [{ "line": 8, "snippet": "Review workspace" }]
        }
      ]
    }
    """
    let backlinksJSON = """
    {
      "$schema": "org2:backlinks:v1",
      "id": "11111111-1111-4111-8111-111111111111",
      "backlinks": [
        {
          "srcId": null,
          "srcTitle": "Thread",
          "file": "/tmp/thread.org2",
          "line": 3,
          "context": "[[id:11111111-1111-4111-8111-111111111111][Workspace]]"
        }
      ]
    }
    """

    let search = try JSONDecoder().decode(SearchPayload.self, from: Data(searchJSON.utf8))
    let backlinks = try JSONDecoder().decode(BacklinksPayload.self, from: Data(backlinksJSON.utf8))

    XCTAssertEqual(search.results[0].lineForEditor, 8)
    XCTAssertEqual(search.results[0].title, "Review workspace")
    XCTAssertEqual(backlinks.backlinks[0].lineForEditor, 4)
  }

  func testOrg2CLIDrainsLargeJSONOutput() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-large-cli-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    let cli = dist.appendingPathComponent("cli.js")
    try """
    const payload = {
      "$schema": "org2:search:v1",
      query: "large",
      mode: "line",
      sort: "scan",
      results: [{
        file: "/tmp/large.org2",
        line: 1,
        heading: "Large",
        tags: [],
        snippet: "x".repeat(160000)
      }]
    };
    process.stdout.write(JSON.stringify(payload));
    """.write(to: cli, atomically: true, encoding: .utf8)

    let org2 = Org2CLI(repoRoot: root)
    let payload: SearchPayload = try await org2.runJSON(["search", "large"], as: SearchPayload.self)

    XCTAssertEqual(payload.results.count, 1)
    XCTAssertEqual(payload.results[0].snippet.count, 160000)
  }

  func testOrg2CLIExtractsNestedStructuredFailureMessage() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-nested-cli-error-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    process.stdout.write(JSON.stringify({
      schema: "org2:source-sync:v1",
      results: [{ id: "slack", ok: false, error: "Slack sync failed cleanly." }]
    }));
    process.exitCode = 1;
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    do {
      _ = try await Org2CLI(repoRoot: root).run(["source", "sync", "slack", "--json"])
      XCTFail("Expected command failure")
    } catch let error as Org2CLIError {
      XCTAssertEqual(error, .commandFailed(status: 1, message: "Slack sync failed cleanly."))
    }
  }

  func testDefaultRepoRootPrefersBundledRuntime() throws {
    let resources = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-bundled-runtime-\(UUID().uuidString)", isDirectory: true)
    let runtime = resources.appendingPathComponent("Org2Runtime", isDirectory: true)
    let dist = runtime.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    try "".write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let root = try Org2CLI.defaultRepoRoot(
      filePath: "/private/tmp/build/apps/macos/Org2Workspace/Sources/Org2WorkspaceCore/Org2CLI.swift",
      bundleResourceURL: resources
    )

    XCTAssertEqual(root, runtime.standardizedFileURL)
  }

  @MainActor
  func testOrg2CLIDecodesJSONAwayFromTheMainActor() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cli-decode-thread-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try #"process.stdout.write("{}");"#
      .write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let payload: DecodeThreadPayload = try await Org2CLI(repoRoot: root).runJSON([])

    XCTAssertFalse(payload.decodedOnMainThread)
  }

  func testOrg2CLIParsesCanonicalAstWithBuiltInParser() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-canonical-ast-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("canonical.org2")
    try """
    #+TITLE: Canonical Parser Test

    * TODO Review [[id:11111111-1111-4111-8111-111111111111][Alice]] :work:
    SCHEDULED: <2026-06-12 Fri>
    Body with *bold* and ~code~.
    """.write(to: note, atomically: true, encoding: .utf8)

    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try cli.parseFileJSONSync(note, sourceRanges: true)

    XCTAssertEqual(document.type, "Document")
    XCTAssertEqual(document.version, "0")
    XCTAssertEqual(document.children.count, 2)

    guard case .keywordLine(let title) = document.children[0] else {
      return XCTFail("Expected title keyword")
    }
    XCTAssertEqual(title.keyRaw, "TITLE")
    XCTAssertEqual(title.valueRaw, " Canonical Parser Test")
    XCTAssertEqual(title.sourceRange, Org2CanonicalSourceRange(startLine: 1, endLine: 1))

    guard case .headline(let headline) = document.children[1] else {
      return XCTFail("Expected headline")
    }
    XCTAssertEqual(headline.level, 1)
    XCTAssertEqual(headline.todo, "TODO")
    XCTAssertEqual(headline.tags, ["work"])
    XCTAssertEqual(headline.sourceRange, Org2CanonicalSourceRange(startLine: 3, endLine: 5))
    XCTAssertTrue(headline.title.contains(.link(Org2CanonicalLink(
      type: "Link",
      format: "bracket",
      raw: "[[id:11111111-1111-4111-8111-111111111111][Alice]]",
      targetRaw: "id:11111111-1111-4111-8111-111111111111",
      descriptionRaw: "Alice"
    ))))
    XCTAssertTrue(headline.children.contains(.planning(Org2CanonicalPlanning(
      type: "Planning",
      kind: "SCHEDULED",
      raw: "SCHEDULED: <2026-06-12 Fri>",
      sourceRange: Org2CanonicalSourceRange(startLine: 4, endLine: 4)
    ))))
  }

  func testOrg2CLIParsesCanonicalAstFromTextWithLineOffset() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try await cli.parseTextJSON(
      """
      * TODO Offset Test
      Body
      """,
      sourceRanges: true,
      sourceLineOffset: 40
    )

    XCTAssertEqual(document.children.count, 1)
    guard case .headline(let headline) = document.children[0] else {
      return XCTFail("Expected headline")
    }
    XCTAssertEqual(headline.sourceRange, Org2CanonicalSourceRange(startLine: 41, endLine: 42))
    guard case .paragraph(let paragraph) = headline.children[0] else {
      return XCTFail("Expected paragraph")
    }
    XCTAssertEqual(paragraph.sourceRange, Org2CanonicalSourceRange(startLine: 42, endLine: 42))
  }

  func testOrg2CLIAnalyzesEditorTextWithSemanticRegionsAndDiagnostics() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let snapshot = try await cli.analyzeEditorText(
      "* TODO Parent\nBody\n** Child\n",
      sourceLineOffset: 20
    )

    XCTAssertTrue(snapshot.diagnostics.isEmpty)
    XCTAssertEqual(snapshot.regions.first(where: { $0.kind == .headline && $0.level == 1 })?.startLine, 21)
    XCTAssertEqual(snapshot.regions.first(where: { $0.kind == .headline && $0.level == 2 })?.startLine, 23)

    let invalid = try await cli.analyzeEditorText("* Parent\n:PROPERTIES:\n:ID: one\n")
    XCTAssertEqual(invalid.diagnostics.first?.line, 4)
    XCTAssertTrue(invalid.diagnostics.first?.message.localizedCaseInsensitiveContains("property drawer") == true)
  }

  func testOrg2CLIRendersSafeAppHTMLFromText() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let stylesheet = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-app-style-\(UUID().uuidString).css")
    try ":root { --org2-accent: hotpink; }".write(to: stylesheet, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: stylesheet) }
    let html = try await cli.renderAppHTML(
      """
      #+HTML_HEAD: <script>globalThis.unsafeHead = true</script>
      * TODO App preview
      A [[id:preview-target][linked note]].
      """,
      sourcePath: "/tmp/app-preview.org2",
      sourceLineOffset: 30,
      stylesheetPath: stylesheet.path
    )

    XCTAssertTrue(html.contains("org2-app-document-style"))
    XCTAssertTrue(html.contains("data-org2-start-line=\"32\""))
    XCTAssertTrue(html.contains("org2-workspace://open-link?target=id%3Apreview-target"))
    XCTAssertTrue(html.contains("org2-app-user-style"))
    XCTAssertTrue(html.contains("--org2-accent: hotpink"))
    XCTAssertFalse(html.contains("globalThis.unsafeHead"))
  }

  func testOrg2CLIReusesWarmAppHTMLRendererWithinInteractiveBudget() async throws {
    let metrics = ThreadSafeCLIMetricRecorder()
    let cli = try Org2CLI(
      repoRoot: Org2CLI.defaultRepoRoot(),
      telemetryHandler: metrics.append
    )
    await cli.prewarmAppHTMLRenderer()
    let source = "* Local preview\n" + String(repeating: "A short local paragraph.\n", count: 20)
    let started = Date()

    for index in 0..<8 {
      let html = try await cli.renderAppHTML(
        source,
        sourcePath: "/tmp/warm-preview-\(index).org2"
      )
      XCTAssertTrue(html.contains("Local preview"))
    }

    let elapsed = Date().timeIntervalSince(started)
    let renderMetrics = metrics.values.filter { $0.command == "render-html-service" }
    XCTAssertEqual(renderMetrics.count, 8)
    XCTAssertTrue(renderMetrics.allSatisfy { $0.outcome == .succeeded })
    XCTAssertLessThan(
      elapsed,
      1.0,
      "Eight warm local renders took \(elapsed)s; this likely regressed to one process launch per render"
    )
  }

  func testOrg2CLIAppHTMLRenderHasHardTimeout() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-render-timeout-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try "setInterval(() => {}, 1000);\n".write(
      to: dist.appendingPathComponent("render-html.js"),
      atomically: true,
      encoding: .utf8
    )
    let cli = Org2CLI(repoRoot: root)

    do {
      _ = try await cli.renderAppHTML("* Slow\n", sourcePath: "/tmp/slow.org2", timeout: 0.05)
      XCTFail("Expected rendering to time out")
    } catch let error as Org2CLIError {
      XCTAssertEqual(error, .commandTimedOut(seconds: 1))
    }
  }

  func testOrg2CLIAppHTMLRenderServiceTimeoutDoesNotCrashHost() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-render-service-timeout-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "process.stdin.resume(); setInterval(() => {}, 1000);\n".write(
      to: dist.appendingPathComponent("render-html-service.js"),
      atomically: true,
      encoding: .utf8
    )
    let cli = Org2CLI(repoRoot: root)

    do {
      _ = try await cli.renderAppHTML(
        "* Slow service\n",
        sourcePath: "/tmp/slow-service.org2",
        timeout: 0.05
      )
      XCTFail("Expected rendering to time out")
    } catch let error as Org2CLIError {
      XCTAssertEqual(error, .commandTimedOut(seconds: 1))
    }
  }

  func testOrg2CLIAppHTMLRendererRecoversAfterCancellationBurst() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let source = "* Cancellation stress\n" + String(
      repeating: "A paragraph with [[https://example.com][a link]].\n",
      count: 400
    )

    for index in 0..<12 {
      let render = Task {
        try await cli.renderAppHTML(
          source,
          sourcePath: "/tmp/cancelled-render-\(index).org2"
        )
      }
      try await Task.sleep(nanoseconds: 2_000_000)
      render.cancel()
      _ = try? await render.value
    }

    let started = Date()
    let html = try await cli.renderAppHTML(
      "* Recovered renderer\n",
      sourcePath: "/tmp/recovered-render.org2",
      timeout: 2
    )
    XCTAssertTrue(html.contains("Recovered renderer"))
    XCTAssertLessThan(
      Date().timeIntervalSince(started),
      1.5,
      "A cancelled render left the shared service lane stranded"
    )
  }

  func testOrg2CLICancellationTerminatesRunningProcess() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cli-cancel-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try "setInterval(() => {}, 1000);\n".write(
      to: dist.appendingPathComponent("cli.js"),
      atomically: true,
      encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = Org2CLI(repoRoot: root)
    let operation = Task { try await cli.run(["hang"]) }
    try await Task.sleep(nanoseconds: 50_000_000)

    operation.cancel()

    do {
      _ = try await operation.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected: cancellation must escape instead of leaving the pipe reader blocked.
    }
  }

  func testOrg2CLIDoesNotWaitForeverWhenDescendantKeepsOutputPipeOpen() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-cli-inherited-pipe-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try """
    const { spawn } = require("node:child_process");
    spawn(process.execPath, ["-e", "setTimeout(() => {}, 3000)"], {
      detached: true,
      stdio: ["ignore", 1, 2]
    }).unref();
    process.stdout.write("ready");
    """.write(
      to: dist.appendingPathComponent("cli.js"),
      atomically: true,
      encoding: .utf8
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let cli = Org2CLI(repoRoot: root)
    let started = Date()

    _ = try await cli.run(["inherited-pipe"])

    XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
  }

  func testOrg2CLIBrokenInputPipeDoesNotTerminateHostProcess() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-render-broken-pipe-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try "process.exit(0);\n".write(
      to: dist.appendingPathComponent("render-html.js"),
      atomically: true,
      encoding: .utf8
    )
    let cli = Org2CLI(repoRoot: root)
    let input = String(repeating: "x", count: 8 * 1_024 * 1_024)

    let output = try await cli.renderAppHTML(input, sourcePath: "/tmp/broken-pipe.org2")

    XCTAssertEqual(output, "")
  }

  func testOrg2CLIRepeatedRunsReleasePipeDescriptors() throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let baseline = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count

    for _ in 0..<24 {
      _ = try cli.runSync(["version"])
    }

    let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    XCTAssertLessThanOrEqual(after, baseline + 4, "Repeated CLI runs leaked \(after - baseline) descriptors")
  }

  func testOrgHTMLLinkTargetResolvesRelativeFileAndHeading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-html-link-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.org2")
    let target = root.appendingPathComponent("target.org2")
    try "* Source\n".write(to: source, atomically: true, encoding: .utf8)
    try "* First\n* TODO Destination :work:\nBody\n".write(to: target, atomically: true, encoding: .utf8)

    let candidate = await OrgHTMLLinkTarget.resolve(
      "file:target.org2::*Destination",
      relativeTo: source.path,
      corpusRoot: root
    )
    let resolved = try XCTUnwrap(candidate)
    XCTAssertEqual(resolved.url, target.standardizedFileURL)
    XCTAssertEqual(resolved.line, 2)
  }

  @MainActor
  func testRenderedDocumentDropsStaleLinkedHeadingResolution() async throws {
    let resolver = ControlledOrgHTMLFileLinkResolver()
    let coordinator = OrgHTMLDocumentView.Coordinator()
    coordinator.source = EntrySource(
      file: "/tmp/source.org2",
      startLine: 1,
      endLineExclusive: 2,
      text: "* Source",
      isSubtree: false
    )
    coordinator.fileLinkResolver = { target, _, _ in
      await resolver.resolve(target)
    }
    var opened: [AIChatFileReference] = []
    coordinator.openOrgFileReference = { opened.append($0) }
    let firstTarget = "file:first.org2::*First"
    let secondTarget = "file:second.org2::*Second"

    coordinator.open(target: firstTarget)
    while !(await resolver.hasRequest(firstTarget)) {
      try await Task.sleep(for: .milliseconds(5))
    }
    coordinator.open(target: secondTarget)
    while !(await resolver.hasRequest(secondTarget)) {
      try await Task.sleep(for: .milliseconds(5))
    }

    await resolver.complete(
      secondTarget,
      with: OrgHTMLResolvedFileTarget(url: URL(fileURLWithPath: "/tmp/second.org2"), line: 9)
    )
    try await Task.sleep(for: .milliseconds(20))
    await resolver.complete(
      firstTarget,
      with: OrgHTMLResolvedFileTarget(url: URL(fileURLWithPath: "/tmp/first.org2"), line: 3)
    )
    try await Task.sleep(for: .milliseconds(20))

    XCTAssertEqual(opened, [AIChatFileReference(path: "/tmp/second.org2", line: 9)])
  }

  func testApprovalItemsUseCanonicalParserSignals() async throws {
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let text = """
    * TODO Review and approve launch email
    :PROPERTIES:
    :ID: approval-1
    :REVIEW_STATUS: review-required
    :END:
    Please review the response draft.

    * TODO Follow up with vendor
    :PROPERTIES:
    :WAITING_ON: Avi approval
    :END:
    Needs a human decision.

    * DONE Review and approve old note
    :PROPERTIES:
    :REVIEW_STATUS: review-required
    :END:
    Already done.

    * TODO [#B] Approve sending Mercor technographics data [[id:8f3c76e5-dd1f-4819-9738-7959b95c3649][overview]] draft
    :PROPERTIES:
    :ID: approval-priority
    :STATUS: waiting-on-avi-approval
    :END:
    Approve before sending.
    """
    let document: Org2CanonicalDocument = try await cli.parseTextJSON(text, sourceRanges: true)

    let approvals = WorkspaceStore.approvalItems(
      in: document,
      file: "/tmp/approvals.org2",
      sourceText: text
    )

    XCTAssertEqual(approvals.map(\.title), [
      "Follow up with vendor",
      "Review and approve launch email",
      "Approve sending Mercor technographics data overview draft"
    ])
    XCTAssertEqual(approvals[0].status, "Avi approval")
    XCTAssertEqual(approvals[1].status, "review-required")
    XCTAssertEqual(approvals[1].idValue, "approval-1")
    XCTAssertTrue(approvals[1].body.contains("Please review"))
    XCTAssertEqual(approvals[2].status, "waiting-on-avi-approval")
    XCTAssertEqual(approvals[2].idValue, "approval-priority")
  }

  func testApprovalCandidatePrefilterSkipsIrrelevantFiles() {
    XCTAssertFalse(WorkspaceStore.approvalCandidateTextMayContainItem("""
    * TODO Write launch email
    :PROPERTIES:
    :STATUS: ready
    :END:
    This mentions review in prose, but it is not approval gated.
    """))

    XCTAssertTrue(WorkspaceStore.approvalCandidateTextMayContainItem("""
    * TODO Review and approve launch email
    :PROPERTIES:
    :REVIEW_STATUS: review-required
    :END:
    """))

    XCTAssertTrue(WorkspaceStore.approvalCandidateTextMayContainItem("""
    * TODO [#B] Approve sending Mercor technographics overview draft
    :PROPERTIES:
    :STATUS: waiting-on-avi-approval
    :END:
    """))

    XCTAssertTrue(WorkspaceStore.approvalCandidateTextMayContainItem("""
    * TODO Follow up with vendor
    :PROPERTIES:
    :WAITING_ON: Avi approval
    :END:
    """))
  }

  func testApprovalCandidateSlicesPreserveOriginalLinesWithoutWholeFileBuffers() async throws {
    let source = """
    #+TITLE: Approval slicing

    * TODO Ordinary work
    :PROPERTIES:
    :STATUS: ready
    :END:
    Unrelated prefix.

    * TODO Review launch email
    :PROPERTIES:
    :ID: approval-slice
    :REVIEW_STATUS: review-required
    :END:
    Review this exact body.

    ** TODO Child context
    Keep this with the approval subtree.

    * TODO Unrelated suffix
    :PROPERTIES:
    :STATUS: ready
    :END:
    """
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    let slices = WorkspaceStore.approvalCandidateSourceSlices(lines)

    let slice = try XCTUnwrap(slices.first)
    XCTAssertEqual(slices.count, 1)
    XCTAssertEqual(slice.sourceLineOffset, 8)
    XCTAssertTrue(slice.sourceText.hasPrefix("* TODO Review launch email"))
    XCTAssertTrue(slice.sourceText.contains("Keep this with the approval subtree."))
    XCTAssertFalse(slice.sourceText.contains("Unrelated prefix."))
    XCTAssertFalse(slice.sourceText.contains("Unrelated suffix"))

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try await cli.parseTextJSON(
      slice.sourceText,
      sourceRanges: true,
      sourceLineOffset: slice.sourceLineOffset
    )
    let approvals = WorkspaceStore.approvalItems(
      in: document,
      file: "/tmp/approval-slice.org2",
      sourceText: slice.sourceText,
      sourceLineOffset: slice.sourceLineOffset
    )

    let approval = try XCTUnwrap(approvals.first)
    XCTAssertEqual(approvals.count, 1)
    XCTAssertEqual(approval.idValue, "approval-slice")
    XCTAssertEqual(approval.line, 9)
    XCTAssertTrue(approval.body.contains("Review this exact body."))
    XCTAssertTrue(approval.body.contains("Keep this with the approval subtree."))
  }

  func testCanonicalAstRendersEditableBlocksWithFallbackGaps() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-canonical-render-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("render.org2")
    let raw = """
    #+TITLE: Render Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body with [[id:11111111-1111-4111-8111-111111111111][Alice]]
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    #+begin_src swift
    let value = 1
    #+end_src
    -----
    - Fallback list item
    """
    try raw.write(to: note, atomically: true, encoding: .utf8)

    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try cli.parseFileJSONSync(note, sourceRanges: true)
    let blocks = OrgEntryRenderer.parseEditable(raw, canonicalDocument: document)

    XCTAssertTrue(blocks.contains {
      if case .keyword(let key, let value) = $0.rendered {
        return key == "TITLE" && value == "Render Test" && $0.displayRange == "1"
      }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .table(let table) = $0.rendered {
        return $0.displayRange == "6-8" && table.rows.count == 3
      }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .source(let language, let lines) = $0.rendered {
        return $0.displayRange == "9-11" && language == "swift" && lines == ["let value = 1"]
      }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .horizontalRule = $0.rendered {
        return $0.displayRange == "12"
      }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .listItem(_, _, _, let text) = $0.rendered {
        return $0.displayRange == "13" && text == "Fallback list item"
      }
      return false
    })
  }

  func testCanonicalAstKeepsBeginQuoteBlocksAsQuotes() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-canonical-quote-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("quote.org2")
    let raw = """
    * Follow up
    #+begin_quote
    Quoted body
    #+end_quote
    """
    try raw.write(to: note, atomically: true, encoding: .utf8)

    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let document: Org2CanonicalDocument = try cli.parseFileJSONSync(note, sourceRanges: true)
    let blocks = OrgEntryRenderer.parseEditable(raw, canonicalDocument: document)

    XCTAssertTrue(blocks.contains {
      if case .quote(let lines) = $0.rendered {
        return lines == ["Quoted body"] && $0.displayRange == "2-4"
      }
      return false
    })
    XCTAssertFalse(blocks.contains {
      if case .source = $0.rendered { return true }
      return false
    })
  }

  func testOpenClawGatewaySettingsResolveLocalConfig() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-openclaw-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let config = root.appendingPathComponent("clawdbot.json")
    try """
    {
      "gateway": {
        "port": 23456,
        "auth": { "mode": "password", "password": "test-password" },
        "http": { "endpoints": { "chatCompletions": { "enabled": true } } }
      }
    }
    """.write(to: config, atomically: true, encoding: .utf8)

    let settings = OpenClawGatewaySettings.resolve(environment: [:], configURL: config)

    XCTAssertEqual(settings.endpoint.absoluteString, "http://127.0.0.1:23456/v1/chat/completions")
    XCTAssertEqual(settings.bearerToken, "test-password")
    XCTAssertEqual(settings.chatCompletionsEnabled, true)
  }

  func testOpenClawGatewaySettingsUseUserEndpointOverride() {
    let settings = OpenClawGatewaySettings.resolve(
      environment: [:],
      configURL: URL(fileURLWithPath: "/tmp/missing-clawdbot-\(UUID().uuidString).json"),
      userEndpoint: "http://openclaw.local:18789",
      userBearerToken: "secret"
    )

    XCTAssertEqual(settings.endpoint.absoluteString, "http://openclaw.local:18789/v1/chat/completions")
    XCTAssertEqual(settings.bearerToken, "secret")
  }

  func testOpenClawGatewayExtractsVisibleTextWithoutLeakingThinkingBlocks() {
    let message: [String: Any] = [
      "role": "assistant",
      "content": [
        ["type": "thinking", "thinking": "provider-exposed thought"],
        ["type": "text", "text": "Visible answer"],
        ["type": "text", "text": "with another block"]
      ]
    ]

    XCTAssertEqual(
      OpenClawGatewayClient.messageText(message, includeThinking: false),
      "Visible answer\nwith another block"
    )
    XCTAssertEqual(
      OpenClawGatewayClient.messageText(message, includeThinking: true),
      "provider-exposed thought\nVisible answer\nwith another block"
    )
  }

  func testOpenClawGatewayStopTargetsSessionAfterReconnect() {
    let params = OpenClawGatewayClient.abortRequestParams(
      sessionKey: "agent:org2:org2-workspace:test-thread",
      agentID: "org2"
    )

    XCTAssertEqual(params["sessionKey"] as? String, "agent:org2:org2-workspace:test-thread")
    XCTAssertEqual(params["agentId"] as? String, "org2")
    XCTAssertEqual(params["preserveSideRuns"] as? Bool, true)
    XCTAssertNil(params["runId"])
  }

  func testOpenClawGatewayPatchesModelAndReasoningAsSessionOverrides() {
    let selected = OpenClawGatewayClient.sessionConfigurationPatchParams(
      sessionKey: "agent:main:org2-workspace:test-thread",
      agentID: "main",
      model: "openai/gpt-test",
      reasoningEffort: "high"
    )

    XCTAssertEqual(selected["key"] as? String, "agent:main:org2-workspace:test-thread")
    XCTAssertEqual(selected["agentId"] as? String, "main")
    XCTAssertEqual(selected["model"] as? String, "openai/gpt-test")
    XCTAssertEqual(selected["thinkingLevel"] as? String, "high")

    let inherited = OpenClawGatewayClient.sessionConfigurationPatchParams(
      sessionKey: "agent:main:org2-workspace:test-thread",
      agentID: "main",
      model: nil,
      reasoningEffort: nil
    )
    XCTAssertTrue(inherited["model"] is NSNull)
    XCTAssertTrue(inherited["thinkingLevel"] is NSNull)
  }

  func testOpenClawGatewaySkipsSessionPatchForInheritedChatConfiguration() {
    XCTAssertFalse(OpenClawGatewayClient.shouldPatchSessionConfiguration(
      model: nil,
      reasoningEffort: nil
    ))
    XCTAssertEqual(
      OpenClawGatewayClient.chatSendScopes(model: nil, reasoningEffort: nil),
      ["operator.read", "operator.write"]
    )

    XCTAssertTrue(OpenClawGatewayClient.shouldPatchSessionConfiguration(
      model: "openai/gpt-test",
      reasoningEffort: nil
    ))
    XCTAssertTrue(OpenClawGatewayClient.shouldPatchSessionConfiguration(
      model: nil,
      reasoningEffort: "high"
    ))
    XCTAssertEqual(
      OpenClawGatewayClient.chatSendScopes(
        model: "openai/gpt-test",
        reasoningEffort: "high"
      ),
      ["operator.read", "operator.write", "operator.admin"]
    )
  }

  func testAIChatRetriesOnlyRejectedExplicitSessionConfigurationWithDefaults() {
    let rejection = OpenClawGatewayError.sessionConfigurationRejected(
      code: "INVALID_REQUEST",
      message: "Unknown model openai/retired-model"
    )

    XCTAssertTrue(WorkspaceStore.shouldRetryAIChatWithDefaults(
      after: rejection,
      model: "openai/retired-model",
      reasoningEffort: "xhigh"
    ))
    XCTAssertFalse(WorkspaceStore.shouldRetryAIChatWithDefaults(
      after: rejection,
      model: nil,
      reasoningEffort: nil
    ))
    XCTAssertFalse(WorkspaceStore.shouldRetryAIChatWithDefaults(
      after: OpenClawGatewayError.connection("offline"),
      model: "openai/gpt-test",
      reasoningEffort: "high"
    ))
  }

  func testOpenClawGatewayReconcilesReplyFromRestartReplacementRun() {
    let payload: [String: Any] = [
      "messages": [
        [
          "role": "assistant",
          "timestamp": 1_000,
          "content": [["type": "text", "text": "Stale reply"]],
        ],
        [
          "role": "user",
          "timestamp": 2_000,
          "idempotencyKey": "original-run:user",
          "content": "Current request",
        ],
        [
          "role": "user",
          "timestamp": 3_000,
          "content": "[System] Continue after gateway restart.",
        ],
        [
          "role": "assistant",
          "timestamp": 4_000,
          "content": [["type": "text", "text": "Recovered reply"]],
        ],
      ],
      "sessionInfo": [
        "status": "done",
        "hasActiveRun": false,
        "endedAt": 4_100,
      ],
    ]

    XCTAssertEqual(
      OpenClawGatewayClient.chatHistoryReconciliation(
        from: payload,
        runID: "original-run",
        requestStartedAtMilliseconds: 1_900
      ),
      .completed("Recovered reply")
    )
  }

  func testOpenClawGatewayDoesNotClaimReplyWhenRequestMarkerWasTruncated() {
    let payload: [String: Any] = [
      "messages": [
        [
          "role": "assistant",
          "timestamp": 1_000,
          "content": [["type": "text", "text": "Stale reply"]],
        ],
        [
          "role": "assistant",
          "timestamp": 3_000,
          "content": [["type": "text", "text": "Fresh reply"]],
        ],
      ],
      "sessionInfo": [
        "status": "failed",
        "hasActiveRun": false,
        "endedAt": 3_100,
      ],
    ]

    XCTAssertEqual(
      OpenClawGatewayClient.chatHistoryReconciliation(
        from: payload,
        runID: "missing-from-truncated-history",
        requestStartedAtMilliseconds: 2_000
      ),
      .pending(hasActiveRun: false, activeRunIDs: [])
    )
  }

  func testOpenClawGatewayKeepsWaitingForReplacementRunWithoutAReply() {
    let payload: [String: Any] = [
      "messages": [],
      "sessionInfo": [
        "status": "running",
        "hasActiveRun": true,
        "activeRunIds": ["replacement-run"],
        "updatedAt": 3_000,
      ],
    ]

    XCTAssertEqual(
      OpenClawGatewayClient.chatHistoryReconciliation(
        from: payload,
        runID: "original-run",
        requestStartedAtMilliseconds: 2_000
      ),
      .pending(hasActiveRun: true, activeRunIDs: ["replacement-run"])
    )
    XCTAssertEqual(OpenClawGatewayClient.acceptedRunRecoveryPollTimeoutMilliseconds, 5_000)
  }

  func testOpenClawGatewayIgnoresSteerAcknowledgementWhileOriginalRunContinues() {
    let acknowledgement: [String: Any] = [
      "role": "assistant",
      "provider": "openclaw",
      "model": "gateway-injected",
      "content": [["type": "text", "text": "steered current session."]],
    ]
    let payload: [String: Any] = [
      "messages": [
        [
          "role": "user",
          "timestamp": 2_000,
          "idempotencyKey": "original-run:user",
          "content": "Current request",
        ],
        acknowledgement,
      ],
      "sessionInfo": [
        "status": "running",
        "hasActiveRun": true,
        "activeRunIds": ["original-run"],
        "updatedAt": 3_000,
      ],
    ]

    XCTAssertTrue(OpenClawGatewayClient.isSteerAcknowledgement(acknowledgement))
    XCTAssertEqual(
      OpenClawGatewayClient.chatHistoryReconciliation(
        from: payload,
        runID: "original-run",
        requestStartedAtMilliseconds: 1_900
      ),
      .pending(hasActiveRun: true, activeRunIDs: ["original-run"])
    )
  }

  func testOpenClawGatewayReturnsRealReplyAfterSteerAcknowledgement() {
    let payload: [String: Any] = [
      "messages": [
        [
          "role": "user",
          "timestamp": 2_000,
          "idempotencyKey": "original-run:user",
          "content": "Current request",
        ],
        [
          "role": "assistant",
          "provider": "openclaw",
          "model": "gateway-injected",
          "content": [["type": "text", "text": "steered current session."]],
        ],
        [
          "role": "assistant",
          "provider": "openai",
          "model": "gpt-test",
          "content": [["type": "text", "text": "Finished after steering"]],
        ],
      ],
      "sessionInfo": [
        "status": "done",
        "hasActiveRun": false,
        "endedAt": 4_100,
      ],
    ]

    XCTAssertEqual(
      OpenClawGatewayClient.chatHistoryReconciliation(
        from: payload,
        runID: "original-run",
        requestStartedAtMilliseconds: 1_900
      ),
      .completed("Finished after steering")
    )
  }

  func testOpenClawGatewayReconcilesDuplicateSendAcknowledgements() {
    XCTAssertTrue(OpenClawGatewayClient.shouldReconcileAfterSendAcknowledgement(["status": "in_flight"]))
    XCTAssertTrue(OpenClawGatewayClient.shouldReconcileAfterSendAcknowledgement(["status": "ok"]))
    XCTAssertFalse(OpenClawGatewayClient.shouldReconcileAfterSendAcknowledgement(["status": "started"]))
    XCTAssertFalse(OpenClawGatewayClient.shouldReconcileAfterSendAcknowledgement(nil))
    XCTAssertTrue(OpenClawGatewayClient.shouldReconcileAfterSendAcknowledgement(
      ["status": "started"],
      reconnectingAcceptedRun: true
    ))
    XCTAssertTrue(OpenClawGatewayClient.shouldReconcileAfterSendAcknowledgement(
      nil,
      reconnectingAcceptedRun: true
    ))
  }

  func testOpenClawGatewayDoesNotHTTPFallbackAfterRunAcceptance() {
    let error = OpenClawGatewayError.acceptedRunRecovery("gateway restarted")

    XCTAssertFalse(error.permitsHTTPFallback)
    XCTAssertEqual(
      error.localizedDescription,
      "OpenClaw accepted the run but could not reconcile its result: gateway restarted"
    )
  }

  func testDecodesOpenClawExecApprovalDetailsForReview() throws {
    let details = try OpenClawGatewayClient.execApprovalDetails(from: [
      "id": "IC_example123",
      "commandText": "send-message --to person@example.com --body 'Hello'",
      "commandPreview": "To: person@example.com\n\nHello",
      "allowedDecisions": ["allow-once", "deny"],
      "host": "gateway",
      "agentId": "default",
      "expiresAtMs": NSNumber(value: 1_721_500_000_000 as Int64),
    ])

    XCTAssertEqual(details.id, "IC_example123")
    XCTAssertEqual(details.reviewText, "To: person@example.com\n\nHello")
    XCTAssertEqual(details.allowedDecisions, ["allow-once", "deny"])
    XCTAssertEqual(details.host, "gateway")
    XCTAssertEqual(details.agentID, "default")
    XCTAssertEqual(details.expiresAtMilliseconds, 1_721_500_000_000)
  }

  func testOpenClawGatewayPreservesPairingRequestFromSocketClose() {
    let error = OpenClawGatewayClient.gatewayError(
      fromCloseReason: "pairing required: device is not approved yet (requestId: req-123)",
      deviceID: "abcdef0123456789"
    )

    XCTAssertEqual(
      error.localizedDescription,
      "pairing required: device is not approved yet (requestId: req-123) "
        + "Approve Celorga request req-123 on the Gateway (device abcdef012345), "
        + "then click Save & Request Pairing again."
    )
    XCTAssertTrue(error.permitsHTTPFallback)
  }

  func testOpenClawGatewayExplainsImmediateHandshakeClose() {
    let error = OpenClawGatewayClient.gatewayHandshakeClosedError(
      deviceID: "abcdef0123456789"
    )

    XCTAssertEqual(
      error.localizedDescription,
      "OpenClaw closed the signed device handshake before macOS delivered its final reason. "
        + "Approve the pending Celorga request for device abcdef012345 on the Gateway, "
        + "then click Save & Request Pairing again."
    )
    XCTAssertTrue(error.permitsHTTPFallback)
  }

  func testOpenClawSessionKeyIsScopedToSelectedAgent() {
    XCTAssertEqual(
      WorkspaceStore.agentScopedOpenClawSessionKey(
        "org2-workspace:3ADAB8C8-D926-4E9D-913F-040D9215DD44",
        agentID: "openclaw/org2"
      ),
      "agent:org2:org2-workspace:3ADAB8C8-D926-4E9D-913F-040D9215DD44"
    )
    XCTAssertEqual(
      WorkspaceStore.agentScopedOpenClawSessionKey(
        "agent:main:org2-workspace:existing",
        agentID: "org2"
      ),
      "agent:org2:org2-workspace:existing"
    )
    XCTAssertEqual(
      WorkspaceStore.agentScopedOpenClawSessionKey(
        "agent:org2:org2-workspace:existing",
        agentID: "openclaw/org2"
      ),
      "agent:org2:org2-workspace:existing"
    )
  }

  func testOpenClawDeviceIdentityStorageIsIsolatedByBundle() {
    XCTAssertEqual(
      OpenClawGatewayIdentityStorage.account(bundleIdentifier: "org.org2.workspace"),
      "gatewayDevicePrivateKey.org.org2.workspace"
    )
    XCTAssertEqual(
      OpenClawGatewayIdentityStorage.account(bundleIdentifier: "org.org2.workspace.codex"),
      "gatewayDevicePrivateKey.org.org2.workspace.codex"
    )
    XCTAssertNotEqual(
      OpenClawGatewayIdentityStorage.account(bundleIdentifier: "org.org2.workspace"),
      OpenClawGatewayIdentityStorage.account(bundleIdentifier: "org.org2.workspace.codex")
    )
  }

  func testOpenClawDeviceIdentityCanUsePrivateHeadlessFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-headless-identity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identityURL = root.appendingPathComponent("openclaw-device-identity.key")

    let first = try OpenClawDeviceIdentity.loadOrCreate(fileURL: identityURL)
    let second = try OpenClawDeviceIdentity.loadOrCreate(fileURL: identityURL)

    XCTAssertEqual(first.deviceID, second.deviceID)
    XCTAssertEqual(try Data(contentsOf: identityURL).count, 32)
    let attributes = try FileManager.default.attributesOfItem(atPath: identityURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testOpenClawGatewaySettingsPreserveHeadlessIdentityFile() {
    let identityURL = URL(fileURLWithPath: "/tmp/openorg-server-identity.key")
    let settings = OpenClawGatewaySettings.resolve(
      environment: [:],
      configURL: URL(fileURLWithPath: "/tmp/missing-openclaw-config.json"),
      deviceIdentityFileURL: identityURL
    )

    XCTAssertEqual(settings.deviceIdentityFileURL, identityURL)
  }

  func testLiveOpenClawGatewayWithHeadlessIdentityWhenRequested() async throws {
    guard let rawIdentityURL = ProcessInfo.processInfo.environment["OPENORG_TEST_HEADLESS_IDENTITY_FILE"] else {
      throw XCTSkip("Set OPENORG_TEST_HEADLESS_IDENTITY_FILE to run the live Gateway check.")
    }
    let settings = OpenClawGatewaySettings.resolve(
      deviceIdentityFileURL: URL(fileURLWithPath: rawIdentityURL)
    )

    let models = try await OpenClawGatewayClient(settings: settings).listModels()

    XCTAssertFalse(models.isEmpty)
  }

  func testOpenClawGatewaySettingsNormalizeBearerTokenInputs() throws {
    let missingConfig = URL(fileURLWithPath: "/tmp/missing-clawdbot-\(UUID().uuidString).json")
    let userSettings = OpenClawGatewaySettings.resolve(
      environment: [:],
      configURL: missingConfig,
      userBearerToken: "  Bearer user-secret  "
    )
    XCTAssertEqual(userSettings.bearerToken, "user-secret")

    let environmentSettings = OpenClawGatewaySettings.resolve(
      environment: ["ORG2_WORKSPACE_OPENCLAW_TOKEN": "bearer env-secret"],
      configURL: missingConfig
    )
    XCTAssertEqual(environmentSettings.bearerToken, "env-secret")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-openclaw-bearer-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let config = root.appendingPathComponent("clawdbot.json")
    try """
    {
      "gateway": {
        "auth": { "mode": "password", "password": "Bearer config-secret" }
      }
    }
    """.write(to: config, atomically: true, encoding: .utf8)

    let configSettings = OpenClawGatewaySettings.resolve(environment: [:], configURL: config)
    XCTAssertEqual(configSettings.bearerToken, "config-secret")
  }

  func testOpenClawChatErrorDistinguishesGatewayAndProviderAuthentication() {
    let gatewayError = OpenClawChatError.httpStatus(401, message: "Unauthorized")
    XCTAssertEqual(
      gatewayError.localizedDescription,
      "OpenClaw gateway rejected the saved gateway token. Open Configure, update the gateway token, save, then retry."
    )

    let providerError = OpenClawChatError.httpStatus(
      401,
      message: "403 <html><div id=\"challenge-error-text\">Enable JavaScript and cookies to continue</div></html>"
    )
    XCTAssertEqual(
      providerError.localizedDescription,
      "OpenClaw reached the gateway, but the selected agent's model provider rejected authentication. On the gateway host, re-authenticate the provider or switch the agent to a working model. Retrying alone won't help."
    )
  }

  func testOpenClawChatCompletionPayloadDecodesAssistantText() throws {
    let json = """
    {
      "choices": [
        { "message": { "role": "assistant", "content": "First" } },
        { "message": { "role": "assistant", "content": "Second" } }
      ]
    }
    """

    let payload = try JSONDecoder().decode(OpenClawChatCompletionPayload.self, from: Data(json.utf8))

    XCTAssertEqual(payload.assistantText, "First\n\nSecond")
  }

  @MainActor
  func testAIChatTranscriptPersistsLocally() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Hello OpenClaw"),
      AIChatMessage(role: .assistant, content: "Hello from the workspace")
    ]

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )

    XCTAssertEqual(restored.aiChatMessages.map(\.content), ["Hello OpenClaw", "Hello from the workspace"])

    restored.resetAIChat()
    let cleared = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    XCTAssertTrue(cleared.aiChatMessages.isEmpty)
  }

  @MainActor
  func testAIChatTranscriptPersistsImageAttachments() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-image-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-image-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let attachment = AIChatAttachment(
      fileName: "diagram.png",
      mimeType: "image/png",
      data: Data([0x89, 0x50, 0x4e, 0x47])
    )
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "What is in this?", attachments: [attachment])
    ]

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )

    XCTAssertEqual(restored.aiChatMessages.first?.attachments, [attachment])
    XCTAssertTrue(try attachment.loadedDataURLString().hasPrefix("data:image/png;base64,"))
  }

  @MainActor
  func testAIChatThreadsPersistAndSwitchLocally() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-threads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-threads-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "First thread question"),
      AIChatMessage(role: .assistant, content: "First thread reply")
    ]
    let firstThreadID = try XCTUnwrap(store.selectedAIChatThreadID)

    store.createAIChatThread(runtime: .openClaw)
    let secondThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertNotEqual(firstThreadID, secondThreadID)
    XCTAssertTrue(store.aiChatMessages.isEmpty)

    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Second thread question")
    ]

    store.selectAIChatThread(firstThreadID)
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["First thread question", "First thread reply"])

    store.selectAIChatThread(secondThreadID)
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["Second thread question"])

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    XCTAssertEqual(restored.aiChatThreads.count, 2)
    XCTAssertEqual(restored.selectedAIChatThreadID, secondThreadID)
    XCTAssertEqual(restored.aiChatMessages.map(\.content), ["Second thread question"])
  }

  @MainActor
  func testNewAIChatThreadsReuseLastSelectedModelAndReasoningAcrossStores() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-last-ai-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "org2-workspace-last-ai-settings-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("first-chat.json")
    )
    store.createAIChatThread(runtime: .openClaw)
    store.setSelectedAIChatModel("openai/gpt-5.6-sol")
    store.setSelectedAIChatReasoningEffort("xhigh")

    store.createAIChatThread(runtime: .openClaw)

    XCTAssertEqual(store.selectedAIChatModel, "openai/gpt-5.6-sol")
    XCTAssertEqual(store.selectedAIChatReasoningEffort, "xhigh")
    XCTAssertEqual(store.selectedAIChatModelLabel, "gpt-5.6-sol")
    XCTAssertEqual(store.selectedAIChatReasoningLabel, "Extra high")

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("second-chat.json")
    )
    restored.createAIChatThread(runtime: .openClaw)

    XCTAssertEqual(restored.selectedAIChatModel, "openai/gpt-5.6-sol")
    XCTAssertEqual(restored.selectedAIChatReasoningEffort, "xhigh")

    restored.setSelectedAIChatModel(nil)
    restored.createAIChatThread(runtime: .openClaw)
    XCTAssertNil(restored.selectedAIChatModel)
    XCTAssertNil(restored.selectedAIChatReasoningEffort)
  }

  func testDirectProviderModelOptionsUseDiscoveredCatalogWithoutSavedDefault() {
    let discovered = [
      AIChatModelOption(id: "claude-opus-test", label: "Claude Opus"),
      AIChatModelOption(id: "claude-sonnet-test", label: "Claude Sonnet"),
    ]

    let withoutDefault = WorkspaceStore.directProviderModelOptions(
      discovered,
      configuredModel: nil
    )
    XCTAssertEqual(withoutDefault.map(\.id), discovered.map(\.id))
    XCTAssertFalse(withoutDefault.contains(where: \.isDefault))

    let withMissingDefault = WorkspaceStore.directProviderModelOptions(
      discovered,
      configuredModel: "claude-haiku-test"
    )
    XCTAssertEqual(withMissingDefault.first?.id, "claude-haiku-test")
    XCTAssertTrue(withMissingDefault.first?.isDefault == true)
    XCTAssertEqual(withMissingDefault.dropFirst().map(\.id), discovered.map(\.id))
  }

  @MainActor
  func testAIChatConfigurationCatalogSurvivesAProviderOutageAndAppRestart() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-ai-catalog-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "org2-workspace-ai-catalog-cache-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("first-chat.json")
    )
    first.cacheAIChatConfigurationForTesting(
      destinationID: AIChatDestinationConfiguration.openClawID,
      models: [
        AIChatModelOption(
          id: "openai/gpt-5.6-sol",
          label: "GPT 5.6 Sol",
          supportsReasoning: true,
          isDefault: true
        )
      ],
      effectiveModel: "openai/gpt-5.6-sol",
      reasoningOptions: [
        AIChatReasoningOption(id: "low", label: "Low"),
        AIChatReasoningOption(id: "high", label: "High")
      ],
      defaultReasoningEffort: "high"
    )

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("second-chat.json")
    )
    restored.createAIChatThread(runtime: .openClaw)

    XCTAssertEqual(restored.aiChatModelOptions.map(\.id), ["openai/gpt-5.6-sol"])
    XCTAssertEqual(restored.aiChatReasoningOptions.map(\.id), ["low", "high"])
    XCTAssertEqual(restored.aiChatEffectiveModel, "openai/gpt-5.6-sol")
    XCTAssertEqual(restored.aiChatDefaultReasoningEffort, "high")
    XCTAssertEqual(restored.selectedAIChatModelLabel, "GPT 5.6 Sol")
    XCTAssertEqual(restored.selectedAIChatReasoningLabel, "High")
  }

  @MainActor
  func testAutomationModelPickerUsesThePersistentDestinationCatalog() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-automation-models-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "org2-workspace-automation-models-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("first-chat.json")
    )
    first.cacheAIChatConfigurationForTesting(
      destinationID: "managed-remote-codex",
      models: [
        AIChatModelOption(id: "gpt-5.6-sol", label: "GPT-5.6 Sol", isDefault: true),
        AIChatModelOption(id: "gpt-6-astra", label: "GPT-6 Astra")
      ],
      effectiveModel: "gpt-5.6-sol",
      reasoningOptions: [],
      defaultReasoningEffort: nil
    )

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("second-chat.json")
    )

    XCTAssertEqual(
      restored.cachedAutomationModelOptions(forDestinationID: "managed-remote-codex").map(\.id),
      ["gpt-5.6-sol", "gpt-6-astra"]
    )
  }

  @MainActor
  func testSelectingChatThreadNeverRewritesFullTranscriptAndStillRestoresSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-fast-chat-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-fast-chat-selection-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    store.aiChatMessages = [AIChatMessage(role: .user, content: "First thread")]
    let firstThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.createAIChatThread(runtime: .openClaw)
    store.aiChatMessages = [AIChatMessage(role: .user, content: "Second thread")]

    var fullTranscriptSaveCount = 0
    store.aiChatTranscriptPersistenceDelayNanoseconds = 20_000_000
    store.aiChatTranscriptSaverForTesting = {
      fullTranscriptSaveCount += 1
    }
    store.selectAIChatThread(firstThreadID)

    XCTAssertEqual(fullTranscriptSaveCount, 0)
    XCTAssertEqual(store.selectedAIChatThreadID, firstThreadID)
    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    XCTAssertEqual(restored.selectedAIChatThreadID, firstThreadID)
    XCTAssertEqual(restored.aiChatMessages.map(\.content), ["First thread"])
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(fullTranscriptSaveCount, 0)
  }

  @MainActor
  func testCreatingEmptyChatDefersAndCoalescesTranscriptPersistence() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-deferred-chat-create-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.aiChatTranscriptPersistenceDelayNanoseconds = 20_000_000
    var fullTranscriptSaveCount = 0
    store.aiChatTranscriptSaverForTesting = {
      fullTranscriptSaveCount += 1
    }

    store.createAIChatThread(runtime: .openClaw)
    store.createAIChatThread(runtime: .openClaw)

    XCTAssertEqual(fullTranscriptSaveCount, 0)
    try await waitForCondition(timeout: 1) {
      fullTranscriptSaveCount == 1
    }
    XCTAssertEqual(fullTranscriptSaveCount, 1)
    XCTAssertEqual(store.aiChatThreads.count, 2)
  }

  @MainActor
  func testCanonicalResourceThreadIsCreatedOnceAndPersists() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-resource-thread-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("launch.org2")
    try "* TODO Prepare launch\n:PROPERTIES:\n:ID: launch-plan\n:END:\n".write(
      to: note,
      atomically: true,
      encoding: .utf8
    )
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "Prepare launch",
      "kind": "TODO",
      "file": "\(note.path)",
      "line": 1,
      "body": null,
      "level": 1,
      "tags": [],
      "properties": {"ID": "launch-plan"},
      "id": "launch-plan"
    }
    """.utf8))

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )
    store.select(.agenda(item))
    XCTAssertTrue(store.canOpenCanonicalAIChatResourceThread)
    XCTAssertFalse(store.hasCanonicalAIChatResourceThread)

    store.openCanonicalAIChatResourceThread()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertEqual(store.aiChatThreads.count, 1)
    XCTAssertEqual(store.selectedAIChatThread?.resource?.key, "id:launch-plan")
    XCTAssertEqual(store.selectedAIChatThread?.title, "Resource: Prepare launch")

    store.openCanonicalAIChatResourceThread()
    XCTAssertEqual(store.aiChatThreads.count, 1)
    XCTAssertEqual(store.selectedAIChatThreadID, threadID)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )
    restored.select(.agenda(item))
    XCTAssertTrue(restored.hasCanonicalAIChatResourceThread)
    restored.openCanonicalAIChatResourceThread()
    XCTAssertEqual(restored.selectedAIChatThreadID, threadID)
    XCTAssertEqual(restored.aiChatThreads.count, 1)
  }

  @MainActor
  func testCanonicalResourceThreadRequiresStableHeadingIdentity() throws {
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "Unidentified task",
      "kind": "TODO",
      "file": "/tmp/unidentified.org2",
      "line": 12,
      "body": null,
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.select(.agenda(item))

    XCTAssertFalse(store.canOpenCanonicalAIChatResourceThread)
    store.openCanonicalAIChatResourceThread()
    XCTAssertTrue(store.aiChatThreads.isEmpty)
    XCTAssertTrue(store.statusText.contains("Add an ID"))
  }

  func testRenderedHTMLCopyHandlerPublishesStyledTableAndPlainText() {
    let script = OrgHTMLRichCopy.installationScript
    XCTAssertTrue(script.contains("event.clipboardData.setData('text/html'"))
    XCTAssertTrue(script.contains("event.clipboardData.setData('text/plain'"))
    XCTAssertTrue(script.contains("clone.style.borderCollapse = 'collapse'"))
    XCTAssertTrue(script.contains(".org2-table-sort-button"))
    XCTAssertTrue(script.contains("tr[hidden]"))
    XCTAssertTrue(script.contains("Array.from(clone.rows)"))
    XCTAssertTrue(script.contains("join('\\t')"))
  }

  func testAIChatThreadTitleUsesMeaningfulFirstMessageWords() {
    let title = WorkspaceStore.aiChatThreadTitle(from: [
      AIChatMessage(
        role: .user,
        content: "can you fix the alignment of the cursor with the tag above it"
      )
    ])

    XCTAssertEqual(title, "Fix alignment cursor tag above")
  }

  func testAIChatThreadTitleSkipsFillerOpenings() {
    let title = WorkspaceStore.aiChatThreadTitle(from: [
      AIChatMessage(
        role: .user,
        content: "sure let's do that to start. also while you're doing that. our thread nav is still a bit clunky."
      )
    ])

    XCTAssertEqual(title, "Thread nav still bit clunky")
  }

  @MainActor
  func testRenamingAIChatThreadDoesNotLeakStatusIntoAnotherEmptyThread() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-rename-status-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    let expectedEmptyThreadStatus = store.aiChatStatusText
    store.createAIChatThread(runtime: .openClaw)
    let firstThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.createAIChatThread(runtime: .openClaw)
    let secondThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.aiChatStatusText = "Ready for a message"

    store.selectAIChatThread(firstThreadID)
    store.renameAIChatThread(firstThreadID, title: "Renamed thread")
    store.selectAIChatThread(secondThreadID)

    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == firstThreadID })?.title,
      "Renamed thread"
    )
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == secondThreadID })?.title,
      "New Chat"
    )
    XCTAssertEqual(store.selectedAIChatThreadID, secondThreadID)
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertEqual(store.aiChatStatusText, expectedEmptyThreadStatus)
  }

  @MainActor
  func testRenamingLowerThreadDoesNotRenamePinnedFirstThread() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-rename-pinned-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.createAIChatThread(runtime: .openClaw)
    let pinnedThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.renameAIChatThread(pinnedThreadID, title: "Pinned thread")
    store.toggleAIChatThreadPin(pinnedThreadID)
    store.renameAIChatThread(pinnedThreadID, title: "Pinned thread renamed first")

    store.createAIChatThread(runtime: .openClaw)
    let lowerThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.renameAIChatThread(lowerThreadID, title: "Lower thread")
    XCTAssertEqual(store.visibleAIChatThreads.map(\.id), [pinnedThreadID, lowerThreadID])

    store.renameAIChatThread(lowerThreadID, title: "Renamed lower thread")

    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == pinnedThreadID })?.title,
      "Pinned thread renamed first"
    )
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == lowerThreadID })?.title,
      "Renamed lower thread"
    )
  }

  @MainActor
  func testNamedAIChatThreadKeepsTitleWhenPromptStartsWithPreamble() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-title-preamble-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { _, _, _, _ in "ok" }
    )
    store.createAIChatThread(runtime: .openClaw)
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.renameAIChatThread(threadID, title: "Brief: Target Node")

    await store.sendAIChatMessage(text: "Generate a concise, source-cited briefing for the selected Celorga node \"Target Node\".")

    let thread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == threadID }))
    XCTAssertEqual(thread.title, "Brief: Target Node")
  }

  @MainActor
  func testAIChatThreadsPinAndArchivePersistLocally() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-metadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-thread-metadata-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "First pinned thread")
    ]
    let firstThreadID = try XCTUnwrap(store.selectedAIChatThreadID)

    store.createAIChatThread(runtime: .openClaw)
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Second regular thread")
    ]
    let secondThreadID = try XCTUnwrap(store.selectedAIChatThreadID)

    store.toggleAIChatThreadPin(firstThreadID)
    XCTAssertEqual(Array(store.visibleAIChatThreads.map(\.id).prefix(2)), [firstThreadID, secondThreadID])

    store.archiveAIChatThread(firstThreadID)
    XCTAssertFalse(store.visibleAIChatThreads.contains(where: { $0.id == firstThreadID }))
    XCTAssertEqual(store.archivedAIChatThreads.first?.id, firstThreadID)

    store.restoreAIChatThread(firstThreadID)
    XCTAssertEqual(store.visibleAIChatThreads.first?.id, firstThreadID)
    XCTAssertEqual(store.visibleAIChatThreads.first?.isPinned, true)

    store.renameAIChatThread(firstThreadID, title: "Renamed pinned thread")
    XCTAssertEqual(store.visibleAIChatThreads.first?.title, "Renamed pinned thread")

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    XCTAssertEqual(restored.visibleAIChatThreads.first?.id, firstThreadID)
    XCTAssertEqual(restored.visibleAIChatThreads.first?.title, "Renamed pinned thread")
    XCTAssertEqual(restored.visibleAIChatThreads.first?.isPinned, true)
    XCTAssertTrue(restored.archivedAIChatThreads.isEmpty)
  }

  @MainActor
  func testArchivingSelectedAIChatThreadTargetsExactRowAndKeepsNearbySelection() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-archive-row-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )

    for title in ["First thread", "Second thread", "Third thread"] {
      store.createAIChatThread(runtime: .openClaw)
      store.aiChatMessages = [AIChatMessage(role: .user, content: title)]
    }

    let threadsBeforeArchive = store.visibleAIChatThreads
    XCTAssertGreaterThanOrEqual(threadsBeforeArchive.count, 3)
    let target = threadsBeforeArchive[1]
    let expectedReplacement = threadsBeforeArchive[2]
    store.selectAIChatThread(target.id)

    store.archiveAIChatThread(target.id)

    XCTAssertEqual(store.archivedAIChatThreads.map(\.id), [target.id])
    XCTAssertFalse(store.visibleAIChatThreads.contains(where: { $0.id == target.id }))
    XCTAssertTrue(store.visibleAIChatThreads.contains(where: { $0.id == threadsBeforeArchive[0].id }))
    XCTAssertTrue(store.visibleAIChatThreads.contains(where: { $0.id == expectedReplacement.id }))
    XCTAssertEqual(store.selectedAIChatThreadID, expectedReplacement.id)
    XCTAssertTrue(store.canUndoAIChatThreadArchive)

    store.undoLastAIChatThreadArchive()

    XCTAssertTrue(store.visibleAIChatThreads.contains(where: { $0.id == target.id }))
    XCTAssertFalse(store.canUndoAIChatThreadArchive)
  }

  @MainActor
  func testSettlingAThreadClearsAnOlderSettledSelection() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-stale-settled-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )

    for title in ["First thread", "Second thread", "Third thread"] {
      store.createAIChatThread(runtime: .openClaw)
      store.aiChatMessages = [AIChatMessage(role: .user, content: title)]
    }

    let previouslySettled = try XCTUnwrap(store.visibleAIChatThreads.last)
    store.settleAIChatThread(previouslySettled.id)
    store.selectAIChatThread(previouslySettled.id)
    XCTAssertEqual(store.selectedAIChatThreadID, previouslySettled.id)

    let newlySettled = try XCTUnwrap(store.visibleAIChatThreads.first)
    store.settleAIChatThread(newlySettled.id)

    let selectedID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertNotEqual(selectedID, previouslySettled.id)
    XCTAssertFalse(
      try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == selectedID })).isSettled
    )
  }

  @MainActor
  func testChatPaneSettleControlSettlesAndReopensTheOpenThreadInPlace() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-pane-settle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    for title in ["First thread", "Second thread"] {
      store.createAIChatThread(runtime: .openClaw)
      store.aiChatMessages = [AIChatMessage(role: .user, content: title)]
    }
    let open = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertFalse(store.selectedAIChatThreadIsSettled)

    store.toggleSelectedAIChatThreadSettlement()

    XCTAssertEqual(store.selectedAIChatThreadID, open, "Settling from the pane keeps the thread open")
    XCTAssertTrue(store.selectedAIChatThreadIsSettled)
    XCTAssertTrue(store.settledAIChatThreads.contains { $0.id == open })
    XCTAssertFalse(store.visibleAIChatThreads.contains { $0.id == open })
    XCTAssertTrue(store.canUndoAIChatThreadArchive)

    // A second click reopens the same thread instead of settling another one.
    store.toggleSelectedAIChatThreadSettlement()

    XCTAssertEqual(store.selectedAIChatThreadID, open)
    XCTAssertFalse(store.selectedAIChatThreadIsSettled)
    XCTAssertTrue(store.visibleAIChatThreads.contains { $0.id == open })
    XCTAssertEqual(store.visibleAIChatThreads.count, 2)
  }

  @MainActor
  func testSettlingAndReopeningAIChatThreadPersistsDurableState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-settle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )
    store.aiChatMessages = [AIChatMessage(role: .user, content: "Retain this history")]
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)

    store.settleAIChatThread(threadID, at: Date(timeIntervalSince1970: 1_700_000_000))

    XCTAssertTrue(store.settledAIChatThreads.contains(where: { $0.id == threadID }))
    XCTAssertFalse(store.visibleAIChatThreads.contains(where: { $0.id == threadID }))
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == threadID })?.messages.first?.content,
      "Retain this history"
    )
    store.flushDeferredAIChatTranscriptPersistence()
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )
    XCTAssertTrue(restored.settledAIChatThreads.contains(where: { $0.id == threadID }))
    let restoredMetadata = try XCTUnwrap(
      restored.aiChatThreads.first(where: { $0.id == threadID })
    )
    XCTAssertEqual(restoredMetadata.messageCount, 1)
    XCTAssertTrue(restoredMetadata.messages.isEmpty)

    restored.reopenAIChatThread(threadID)
    XCTAssertTrue(restored.visibleAIChatThreads.contains(where: { $0.id == threadID }))
    XCTAssertFalse(restored.settledAIChatThreads.contains(where: { $0.id == threadID }))
    restored.selectAIChatThread(threadID)
    await restored.waitForAIChatThreadHydrationForTesting(threadID)
    XCTAssertEqual(restored.aiChatMessages.first?.content, "Retain this history")
  }

  @MainActor
  func testSettlingThreadUpdatesTheListBeforeDeferredPersistence() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-fast-thread-settle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.createAIChatThread(runtime: .openClaw)
    store.aiChatMessages = [AIChatMessage(role: .user, content: "First")]
    let targetID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.createAIChatThread(runtime: .openClaw)
    store.aiChatMessages = [AIChatMessage(role: .user, content: "Second")]

    store.aiChatTranscriptPersistenceDelayNanoseconds = 20_000_000
    var saveCount = 0
    store.aiChatTranscriptSaverForTesting = { saveCount += 1 }

    store.settleAIChatThread(targetID)

    XCTAssertFalse(store.visibleAIChatThreads.contains(where: { $0.id == targetID }))
    XCTAssertTrue(store.settledAIChatThreads.contains(where: { $0.id == targetID }))
    XCTAssertEqual(saveCount, 0)
    try await waitForCondition(timeout: 1) { saveCount == 1 }
  }

  @MainActor
  func testAIChatAutoSettleConfigurationTimingSafetyAndPersistence() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-auto-settle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = now.addingTimeInterval(-172_800)
    let eligible = AIChatThread(
      title: "Eligible",
      createdAt: old,
      updatedAt: old,
      sessionKey: "agent:main:eligible",
      messages: [AIChatMessage(role: .user, content: "done", createdAt: old)]
    )
    let pinned = AIChatThread(
      title: "Pinned",
      createdAt: old,
      updatedAt: old,
      sessionKey: "agent:main:pinned",
      messages: [AIChatMessage(role: .user, content: "keep active", createdAt: old)],
      isPinned: true
    )
    let failed = AIChatThread(
      title: "Failed",
      createdAt: old,
      updatedAt: old,
      sessionKey: "agent:main:failed",
      messages: [
        AIChatMessage(
          role: .user,
          content: "retry me",
          createdAt: old,
          sendFailure: "offline",
          deliveryStatus: .failed
        )
      ]
    )
    let recovered = AIChatThread(
      title: "Recovered",
      createdAt: old,
      updatedAt: old,
      sessionKey: "agent:main:recovered",
      messages: [
        AIChatMessage(
          role: .user,
          content: "retry me",
          createdAt: old,
          sendFailure: "offline",
          deliveryStatus: .failed
        ),
        AIChatMessage(
          role: .assistant,
          content: "recovered",
          createdAt: old.addingTimeInterval(60)
        )
      ]
    )
    let empty = AIChatThread(
      title: "Empty",
      createdAt: old,
      updatedAt: old,
      sessionKey: "agent:main:empty"
    )
    let selected = AIChatThread(
      title: "Selected",
      createdAt: old,
      updatedAt: old,
      sessionKey: "agent:main:selected",
      messages: [AIChatMessage(role: .user, content: "currently open", createdAt: old)]
    )
    let settings = AIChatThreadSettlementSettings(autoSettleAfterSeconds: 86_400)

    XCTAssertTrue(WorkspaceStore.canAutoSettleAIChatThread(
      eligible,
      settings: settings,
      selectedThreadID: selected.id,
      now: now
    ))
    XCTAssertFalse(WorkspaceStore.canAutoSettleAIChatThread(
      pinned,
      settings: settings,
      selectedThreadID: selected.id,
      now: now
    ))
    XCTAssertFalse(WorkspaceStore.canAutoSettleAIChatThread(
      failed,
      settings: settings,
      selectedThreadID: selected.id,
      now: now
    ))
    XCTAssertTrue(WorkspaceStore.canAutoSettleAIChatThread(
      recovered,
      settings: settings,
      selectedThreadID: selected.id,
      now: now
    ))
    XCTAssertTrue(WorkspaceStore.canAutoSettleAIChatThread(
      empty,
      settings: settings,
      selectedThreadID: selected.id,
      now: now
    ))
    XCTAssertFalse(WorkspaceStore.canAutoSettleAIChatThread(
      selected,
      settings: settings,
      selectedThreadID: selected.id,
      now: now
    ))

    store.createAIChatThread(runtime: .openClaw)
    store.aiChatMessages = [AIChatMessage(role: .user, content: "old", createdAt: old)]
    let oldThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.createAIChatThread(runtime: .openClaw)
    store.aiChatMessages = [AIChatMessage(role: .user, content: "selected", createdAt: old)]

    store.setAIChatAutoSettleInterval(.oneDay)
    let autoSettled = store.autoSettleAIChatThreads(now: now)

    XCTAssertTrue(autoSettled.contains(oldThreadID))
    XCTAssertEqual(store.aiChatThreadSettlementSettings.interval, .oneDay)
    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )
    XCTAssertEqual(restored.aiChatThreadSettlementSettings.interval, .oneDay)

    restored.setAIChatAutoSettleInterval(.never)
    XCTAssertEqual(restored.aiChatThreadSettlementSettings.interval, .never)
  }

  func testLegacyArchivedAIChatThreadDecodesAsSettled() throws {
    let id = UUID()
    let decoder = JSONDecoder()
    let raw = """
    {
      "id": "\(id.uuidString)",
      "title": "Legacy archived",
      "createdAt": 700000000,
      "updatedAt": 700000100,
      "sessionKey": "agent:main:legacy",
      "messages": [],
      "isPinned": false,
      "isArchived": true,
      "unreadMessageCount": 0
    }
    """

    let thread = try decoder.decode(AIChatThread.self, from: Data(raw.utf8))

    XCTAssertTrue(thread.isSettled)
    XCTAssertEqual(thread.settledAt, thread.updatedAt)
  }

  @MainActor
  func testAwaitedAIChatSendReturnsAfterItsReplyIsInserted() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-awaited-chat-send-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "org2-workspace-awaited-chat-send-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { _, _, _, _ in "terminal reply" }
    )

    store.aiChatDraft = "foreground request"
    await store.sendAIChatMessage()

    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:foreground request",
      "assistant:terminal reply"
    ])
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatQueuedMessageCount, 0)
  }

  @MainActor
  func testAIChatThreadsTrackUnreadBackgroundRepliesAndSound() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-unread-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-thread-unread-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in
        "Background reply"
      }
    )
    var soundCount = 0
    store.aiChatIncomingMessageSoundPlayer = {
      soundCount += 1
    }
    store.selectedSurface = .agenda

    store.aiChatDraft = "Question while away"
    await store.sendAIChatMessage()

    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 1)
    XCTAssertEqual(store.aiChatUnreadMessageCount, 1)
    XCTAssertEqual(soundCount, 1)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    XCTAssertEqual(restored.aiChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 1)

    restored.makeSurfacePrimary(.aiChat)
    XCTAssertEqual(restored.aiChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 0)
    XCTAssertEqual(restored.aiChatUnreadMessageCount, 0)

    let reopened = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    XCTAssertEqual(reopened.aiChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 0)
  }

  @MainActor
  func testAIChatThreadsCanMuteIncomingSound() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-muted-sound-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-thread-muted-sound-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in
        "Quiet background reply"
      }
    )
    store.aiChatMessageSound = .off
    var soundCount = 0
    store.aiChatIncomingMessageSoundPlayer = {
      soundCount += 1
    }
    store.selectedSurface = .agenda

    store.aiChatDraft = "Question while muted"
    await store.sendAIChatMessage()

    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 1)
    XCTAssertEqual(soundCount, 0)
  }

  @MainActor
  func testAIChatGenericMessageSyncDoesNotPlayIncomingSound() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-sync-sound-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-thread-sync-sound-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    var soundCount = 0
    store.aiChatIncomingMessageSoundPlayer = {
      soundCount += 1
    }
    store.selectedSurface = .agenda

    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Known question")
    ]
    store.aiChatMessages.append(AIChatMessage(role: .assistant, content: "Known reply"))

    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.messageCount, 2)
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 0)
    XCTAssertEqual(store.aiChatUnreadMessageCount, 0)
    XCTAssertEqual(soundCount, 0)
  }

  @MainActor
  func testAIChatThreadsSoundButDoNotMarkActiveRepliesUnread() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-thread-active-unread-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-thread-active-unread-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in
        "Visible reply"
      }
    )
    var soundCount = 0
    store.aiChatIncomingMessageSoundPlayer = {
      soundCount += 1
    }
    store.makeSurfacePrimary(.aiChat)
    store.aiChatDraft = "Question in active chat"

    await store.sendAIChatMessage()

    XCTAssertEqual(store.aiChatUnreadMessageCount, 0)
    XCTAssertEqual(soundCount, 1)
  }

  @MainActor
  func testAIChatThreadsDoNotPlaySoundForExistingAssistantMessagesAfterLocalRewrite() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-existing-reply-sound-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-existing-reply-sound-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    var soundCount = 0
    store.aiChatIncomingMessageSoundPlayer = {
      soundCount += 1
    }
    store.makeSurfacePrimary(.aiChat)
    let user = AIChatMessage(role: .user, content: "Original question")
    let assistant = AIChatMessage(role: .assistant, content: "Existing reply")
    store.aiChatMessages = [user, assistant]
    XCTAssertEqual(soundCount, 0)

    store.selectedSurface = .agenda
    let insertedUser = AIChatMessage(role: .user, content: "Local inserted note")
    store.aiChatMessages = [user, insertedUser, assistant]

    XCTAssertEqual(store.aiChatUnreadMessageCount, 0)
    XCTAssertEqual(soundCount, 0)
  }

  @MainActor
  func testAIChatThreadsMigrateLegacySingleTranscriptPayload() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-legacy-threads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-legacy-threads-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let payload: [String: Any] = [
      "version": 1,
      "messages": [
        [
          "id": UUID().uuidString,
          "role": "user",
          "content": "Legacy single chat",
          "createdAt": Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: transcript)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )

    XCTAssertEqual(store.aiChatThreads.count, 1)
    XCTAssertEqual(store.aiChatThreads.first?.title, "Legacy single chat")
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["Legacy single chat"])
  }

  @MainActor
  func testAIChatTranscriptPersistsRealSendsLocally() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-send-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-send-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in "Hello from restart-safe storage" }
    )
    store.aiChatDraft = "Hello OpenClaw"
    await store.sendAIChatMessage()

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )

    XCTAssertEqual(restored.aiChatMessages.map(\.content), ["Hello OpenClaw", "Hello from restart-safe storage"])
  }

  @MainActor
  func testAIChatSendClearsPreviousStreamingReplyBeforeShowingProgress() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-stream-reset-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recorder = AIChatSuspendedSendRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.createAIChatThread(runtime: .openClaw)
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    let eventStartedAt = Date()
    store.handleOpenClawGatewayEvent(.text("Previous assistant reply", replace: true), threadID: threadID)
    XCTAssertEqual(store.selectedAIChatStreamingReply, "Previous assistant reply")
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.aiChatLastEventAt), eventStartedAt)

    store.aiChatDraft = "Follow-up question"
    let sendTask = Task { await store.sendAIChatMessage() }
    let deadline = Date().addingTimeInterval(5)
    while !(await recorder.hasStarted()) && Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    XCTAssertTrue(store.isSendingAIChatMessage)
    XCTAssertEqual(store.selectedAIChatStreamingReply, "")

    store.handleOpenClawGatewayEvent(.text("Fresh assistant reply", replace: true), threadID: threadID)
    XCTAssertEqual(store.selectedAIChatStreamingReply, "Fresh assistant reply")
    let heartbeatStartedAt = Date()
    store.handleOpenClawGatewayEvent(.reconciliationHeartbeat, threadID: threadID)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.aiChatLastEventAt), heartbeatStartedAt)
    await recorder.finish(reply: "Fresh assistant reply")
    await sendTask.value
    XCTAssertEqual(store.selectedAIChatStreamingReply, "")
  }

  @MainActor
  func testComposedAIChatMessageStaysInThreadSelectedAtSubmission() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-submit-thread-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { _, _, _, _ in "Reply for submitted thread" }
    )
    store.createAIChatThread(runtime: .openClaw)
    let firstThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.renameAIChatThread(firstThreadID, title: "First thread")
    store.createAIChatThread(runtime: .openClaw)
    let secondThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.renameAIChatThread(secondThreadID, title: "Second thread")
    store.selectAIChatThread(firstThreadID)

    store.sendComposedAIChatMessage(text: "Message for first thread")
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == firstThreadID })?.messages.map(\.content),
      ["Message for first thread"]
    )
    store.selectAIChatThread(secondThreadID)

    let deadline = Date().addingTimeInterval(5)
    while store.aiChatThreads.first(where: { $0.id == firstThreadID })?.messages.count != 2,
          Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }

    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == firstThreadID })?.messages.map(\.content),
      ["Message for first thread", "Reply for submitted thread"]
    )
    XCTAssertTrue(
      store.aiChatThreads.first(where: { $0.id == secondThreadID })?.messages.isEmpty == true
    )
    XCTAssertEqual(store.selectedAIChatThreadID, secondThreadID)
  }

  @MainActor
  func testAIChatSendFailureIsVisiblePersistedAndRetryable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-send-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-send-failure-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let recorder = AIChatRetrySendRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.aiChatDraft = "Are you reachable?"

    await store.sendAIChatMessage()

    XCTAssertEqual(store.aiChatMessages.map(\.content), ["Are you reachable?"])
    let failedMessage = try XCTUnwrap(store.aiChatMessages.first)
    XCTAssertEqual(failedMessage.sendFailure, "VPN disconnected")
    XCTAssertEqual(failedMessage.deliveryStatus, .failed)
    XCTAssertEqual(store.aiChatStatusText, "VPN disconnected")
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatQueuedMessageCount, 0)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    XCTAssertEqual(restored.aiChatMessages.first?.sendFailure, "VPN disconnected")
    XCTAssertEqual(restored.aiChatMessages.first?.deliveryStatus, .failed)

    let receipt = await store.retryAIChatMessageAwaitingDelivery(failedMessage.id)

    XCTAssertEqual(receipt.state, .requested)
    XCTAssertEqual(receipt.messageID, failedMessage.id)
    XCTAssertNil(receipt.runtimeThreadID)
    XCTAssertNil(receipt.turnID)
    let retryDeadline = Date().addingTimeInterval(3)
    while await recorder.attemptCount() < 2, Date() < retryDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let replyDeadline = Date().addingTimeInterval(3)
    while store.aiChatMessages.count < 2, Date() < replyDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let attemptCount = await recorder.attemptCount()
    XCTAssertEqual(attemptCount, 2)
    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:Are you reachable?",
      "assistant:reply after reconnect"
    ])
    XCTAssertNil(store.aiChatMessages.first?.sendFailure)
    XCTAssertEqual(store.aiChatMessages.first?.deliveryStatus, .sent)
    XCTAssertEqual(store.aiChatStatusText, "OpenClaw replied")
  }

  func testAIChatLatestDeliveryAttentionDistinguishesSendingFromFailure() {
    let sending = AIChatThread(
      title: "Sending",
      sessionKey: "agent:main:sending",
      messages: [
        AIChatMessage(
          role: .user,
          content: "In flight",
          deliveryStatus: .sending
        )
      ]
    )
    let failed = AIChatThread(
      title: "Failed",
      sessionKey: "agent:main:failed",
      messages: [
        AIChatMessage(
          role: .user,
          content: "Retry me",
          sendFailure: "Offline",
          deliveryStatus: .failed
        )
      ]
    )
    let interrupted = AIChatThread(
      title: "Interrupted",
      sessionKey: "agent:main:interrupted",
      messages: [
        AIChatMessage(
          role: .user,
          content: "Retry after restart",
          deliveryStatus: .interrupted
        )
      ]
    )

    XCTAssertTrue(sending.hasUnresolvedLatestDelivery)
    XCTAssertFalse(sending.latestDeliveryNeedsAttention)
    XCTAssertTrue(failed.latestDeliveryNeedsAttention)
    XCTAssertTrue(interrupted.latestDeliveryNeedsAttention)
  }

  func testManagedRemoteAttemptUsesOnlyStructuredFields() throws {
    let messageID = UUID()
    let attemptID = UUID()
    let held = AIChatMessage(
      id: messageID,
      role: .user,
      content: "Do this once",
      sendFailure: "Delivery is awaiting confirmation.",
      deliveryStatus: .sending,
      deliveryAttemptID: attemptID,
      deliveryAttemptState: .unconfirmed,
      targetRuntime: .codex
    )
    let encoded = try JSONEncoder().encode(held)
    var olderWriterObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    olderWriterObject.removeValue(forKey: "deliveryAttemptID")
    olderWriterObject.removeValue(forKey: "deliveryAttemptState")
    let olderWriterData = try JSONSerialization.data(withJSONObject: olderWriterObject)

    let restored = try JSONDecoder().decode(AIChatMessage.self, from: olderWriterData)

    XCTAssertEqual(restored.id, messageID)
    XCTAssertNil(restored.effectiveDeliveryAttemptID)
    XCTAssertFalse(restored.deliveryIsUnconfirmed)
    XCTAssertEqual(restored.displayedSendFailure, "Delivery is awaiting confirmation.")
  }

  @MainActor
  func testAIChatInFlightSendRestoresAsInterruptedAndRetryable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-send-interrupted-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-send-interrupted-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let recorder = AIChatSuspendedSendRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.aiChatDraft = "Please do this long running thing"

    let sendTask = Task { await store.sendAIChatMessage() }
    let deadline = Date().addingTimeInterval(5)
    while !(await recorder.hasStarted()) && Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let didStart = await recorder.hasStarted()
    XCTAssertTrue(didStart)
    XCTAssertEqual(store.aiChatMessages.first?.deliveryStatus, .sending)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in "reply after retry" }
    )
    let interrupted = try XCTUnwrap(restored.aiChatMessages.first)
    XCTAssertEqual(interrupted.content, "Please do this long running thing")
    XCTAssertEqual(interrupted.deliveryStatus, .interrupted)
    XCTAssertTrue(interrupted.sendFailure?.contains("restarted") == true)
    XCTAssertEqual(restored.aiChatStatusText, "OpenClaw response interrupted; retry the message")

    await restored.retryAIChatMessage(interrupted.id)
    XCTAssertEqual(restored.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:Please do this long running thing",
      "assistant:reply after retry"
    ])
    XCTAssertEqual(restored.aiChatMessages.first?.deliveryStatus, .sent)
    XCTAssertNil(restored.aiChatMessages.first?.sendFailure)

    await recorder.finish(reply: "late original reply")
    await sendTask.value
  }

  @MainActor
  func testLateReplyStaysAfterNewerCompletedMessages() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-chat-late-reply-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let older = AIChatMessage(
      role: .user,
      content: "Older request",
      sendFailure: "Interrupted",
      deliveryStatus: .interrupted
    )
    let thread = AIChatThread(
      title: "Late reply",
      sessionKey: "agent:main:org2-workspace:late-reply",
      messages: [
        older,
        AIChatMessage(role: .user, content: "Newer request"),
        AIChatMessage(role: .assistant, content: "Newer answer")
      ]
    )
    try JSONEncoder().encode(AIChatTranscriptFixture(
      version: 4,
      messages: nil,
      threads: [thread],
      selectedThreadID: thread.id
    )).write(to: transcript, options: .atomic)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in "Late answer" }
    )

    await store.retryAIChatMessage(older.id)

    XCTAssertEqual(store.aiChatMessages.map(\.content), [
      "Older request", "Newer request", "Newer answer", "Late answer"
    ])
  }

  @MainActor
  func testInterruptedPendingTurnDoesNotAppearRunningOrReconnect() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-chat-orphaned-turn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let stopped = AIChatMessage(
      role: .user,
      content: "Stopped request",
      deliveryStatus: .sending
    )
    let thread = AIChatThread(
      title: "Orphaned pending turn",
      sessionKey: "agent:main:org2-workspace:orphaned-turn",
      messages: [stopped],
      pendingTurn: AIChatPendingTurn(
        userMessageID: stopped.id,
        runID: "orphaned-run",
        agentID: "main",
        gatewayMessage: "Do not reconnect"
      )
    )
    try JSONEncoder().encode(AIChatTranscriptFixture(
      version: 4,
      messages: nil,
      threads: [thread],
      selectedThreadID: thread.id
    )).write(to: transcript, options: .atomic)
    let recorder = AIChatRecoveryRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript,
      aiChatRecoveryHandler: { turn, _ in await recorder.recover(turn) }
    )

    XCTAssertTrue(store.isAIChatThreadRunning(thread.id))
    store.aiChatMessages[0] = stopped.replacingDeliveryStatus(
      .interrupted,
      sendFailure: "Stopped by you"
    )
    XCTAssertNotNil(store.selectedAIChatThread?.pendingTurn)
    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))
    await store.recoverPendingAIChatTurns()
    XCTAssertNil(store.selectedAIChatThread?.pendingTurn)
    let recoveredTurns = await recorder.recordedTurns()
    XCTAssertTrue(recoveredTurns.isEmpty)
  }

  @MainActor
  func testOpenClawGatewayTurnReconnectsOnceAfterRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-durable-turn-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-durable-turn-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let userMessage = AIChatMessage(
      role: .user,
      content: "Finish this even if I quit",
      deliveryStatus: .sending
    )
    let queuedMessage = AIChatMessage(
      role: .user,
      content: "Then handle this queued follow-up",
      deliveryStatus: .sending,
      deliveryKind: .followUp
    )
    let pendingTurn = AIChatPendingTurn(
      userMessageID: userMessage.id,
      runID: "durable-run-id",
      agentID: "main",
      gatewayMessage: "Exact persisted Gateway request",
      contextSectionFingerprints: ["Celorga working rules#0": String(repeating: "a", count: 64)],
      startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let thread = AIChatThread(
      title: "Durable turn",
      sessionKey: "agent:main:org2-workspace:durable",
      messages: [userMessage, queuedMessage],
      pendingTurn: pendingTurn
    )
    let fixture = AIChatTranscriptFixture(
      version: 4,
      messages: nil,
      threads: [thread],
      selectedThreadID: thread.id
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(fixture).write(to: transcript, options: .atomic)

    let recorder = AIChatRecoveryRecorder()
    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in "Queued follow-up reply" },
      aiChatRecoveryHandler: { turn, _ in await recorder.recover(turn) }
    )

    XCTAssertEqual(restored.aiChatMessages.first?.deliveryStatus, .sending)
    XCTAssertEqual(restored.selectedAIChatThread?.pendingTurn?.runID, "durable-run-id")
    XCTAssertFalse(restored.isAIChatMessageQueued(userMessage.id))
    XCTAssertTrue(restored.isAIChatMessageQueued(queuedMessage.id))
    await restored.bootstrap()
    try await waitForCondition {
      restored.aiChatMessages.count == 4
        && restored.selectedAIChatThread?.pendingTurn == nil
    }

    XCTAssertEqual(restored.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:Finish this even if I quit",
      "assistant:Recovered after relaunch",
      "user:Then handle this queued follow-up",
      "assistant:Queued follow-up reply"
    ])
    XCTAssertEqual(restored.aiChatMessages.first?.deliveryStatus, .sent)
    XCTAssertNil(restored.selectedAIChatThread?.pendingTurn)
    let recoveredTurns = await recorder.recordedTurns()
    XCTAssertEqual(recoveredTurns.map(\.runID), ["durable-run-id"])
    XCTAssertEqual(recoveredTurns.first?.gatewayMessage, "Exact persisted Gateway request")
    XCTAssertEqual(
      recoveredTurns.first?.contextSectionFingerprints,
      ["Celorga working rules#0": String(repeating: "a", count: 64)]
    )

    let relaunchedAgain = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatRecoveryHandler: { turn, _ in await recorder.recover(turn) }
    )
    await relaunchedAgain.recoverPendingAIChatTurns()

    XCTAssertEqual(relaunchedAgain.aiChatMessages.map(\.content), [
      "Finish this even if I quit",
      "Recovered after relaunch",
      "Then handle this queued follow-up",
      "Queued follow-up reply"
    ])
    let finalRecoveredTurns = await recorder.recordedTurns()
    XCTAssertEqual(finalRecoveredTurns.count, 1)
  }

  @MainActor
  func testRelaunchRecoveryDoesNotBlockBootstrapOrOtherThreads() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-parallel-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-parallel-recovery-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let slowMessage = AIChatMessage(
      role: .user,
      content: "Keep working on the slow turn",
      deliveryStatus: .sending
    )
    let fastMessage = AIChatMessage(
      role: .user,
      content: "Recover this completed turn too",
      deliveryStatus: .sending
    )
    let slowThread = AIChatThread(
      title: "Slow recovery",
      sessionKey: "agent:main:org2-workspace:slow-recovery",
      messages: [slowMessage],
      pendingTurn: AIChatPendingTurn(
        userMessageID: slowMessage.id,
        runID: "slow-recovery",
        agentID: "main",
        gatewayMessage: "Persisted slow request"
      )
    )
    let fastThread = AIChatThread(
      title: "Fast recovery",
      sessionKey: "agent:main:org2-workspace:fast-recovery",
      messages: [fastMessage],
      pendingTurn: AIChatPendingTurn(
        userMessageID: fastMessage.id,
        runID: "fast-recovery",
        agentID: "main",
        gatewayMessage: "Persisted fast request"
      )
    )
    let fixture = AIChatTranscriptFixture(
      version: 6,
      messages: nil,
      threads: [slowThread, fastThread],
      selectedThreadID: slowThread.id
    )
    try JSONEncoder().encode(fixture).write(to: transcript, options: .atomic)

    let recorder = AIChatRelaunchRecoveryRecorder()
    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatRecoveryHandler: { turn, _ in await recorder.recover(turn) }
    )

    let bootstrapFinished = expectation(description: "bootstrap is not blocked by a recovered turn")
    Task { @MainActor in
      await restored.bootstrap()
      bootstrapFinished.fulfill()
    }
    await fulfillment(of: [bootstrapFinished], timeout: 1)
    await recorder.waitUntilSlowRecoveryStarts()

    try await waitForCondition(timeout: 1) {
      restored.aiChatThreads
        .first(where: { $0.id == fastThread.id })?
        .messages.contains(where: { $0.content == "Recovered fast turn" }) == true
    }
    XCTAssertNotNil(
      restored.aiChatThreads.first(where: { $0.id == slowThread.id })?.pendingTurn,
      "A still-running recovery remains durable while other threads finish"
    )

    await recorder.finishSlowRecovery()
    try await waitForCondition(timeout: 1) {
      restored.aiChatThreads
        .first(where: { $0.id == slowThread.id })?
        .messages.contains(where: { $0.content == "Recovered slow turn" }) == true
    }
  }

  @MainActor
  func testStoppedAIChatRecoveryDoesNotReconnectAgain() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-stopped-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let suiteName = "org2-workspace-chat-stopped-recovery-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let userMessage = AIChatMessage(
      role: .user,
      content: "Stop this recovered turn",
      deliveryStatus: .sending
    )
    let pendingTurn = AIChatPendingTurn(
      userMessageID: userMessage.id,
      runID: "stopped-recovery-run-id",
      agentID: "main",
      gatewayMessage: "Persisted request that must stay stopped"
    )
    let thread = AIChatThread(
      title: "Stopped recovery",
      sessionKey: "agent:main:org2-workspace:stopped-recovery",
      messages: [userMessage],
      pendingTurn: pendingTurn
    )
    let fixture = AIChatTranscriptFixture(
      version: 4,
      messages: nil,
      threads: [thread],
      selectedThreadID: thread.id
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(fixture).write(to: transcript, options: .atomic)

    let recorder = AIChatStoppedRecoveryRecorder()
    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatRecoveryHandler: { turn, _ in try await recorder.recover(turn) }
    )

    await restored.bootstrap()
    try await waitForCondition {
      restored.selectedAIChatThread?.pendingTurn == nil
    }

    XCTAssertNil(restored.selectedAIChatThread?.pendingTurn)
    XCTAssertEqual(restored.aiChatMessages.first?.deliveryStatus, .interrupted)
    XCTAssertEqual(
      restored.aiChatMessages.first?.sendFailure,
      "OpenClaw was stopped by you. Retry to start this request again."
    )
    XCTAssertEqual(restored.openClawGatewayConnectionState, .disconnected)
    XCTAssertEqual(restored.openClawGatewayConnectionDetail, "Stopped by you. This turn will not reconnect.")
    XCTAssertEqual(restored.aiChatStatusText, "OpenClaw stopped")
    XCTAssertFalse(restored.isAIChatThreadRunning(thread.id))
    let initialAttemptCount = await recorder.attemptCount()
    XCTAssertEqual(initialAttemptCount, 1)

    await restored.recoverPendingAIChatTurns()
    let finalAttemptCount = await recorder.attemptCount()
    XCTAssertEqual(finalAttemptCount, 1)
  }

  @MainActor
  func testTerminalAIChatRecoveryFailsOnlyAcceptedTurnAndDoesNotRetry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-terminal-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let failedMessage = AIChatMessage(
      role: .user,
      content: "This accepted run failed",
      deliveryStatus: .sending
    )
    let queuedMessage = AIChatMessage(
      role: .user,
      content: "Keep this follow-up queued",
      deliveryStatus: .sending,
      deliveryKind: .followUp
    )
    let pendingTurn = AIChatPendingTurn(
      userMessageID: failedMessage.id,
      runID: "accepted-terminal-run",
      idempotencyKey: "stable-request-key",
      agentID: "main",
      gatewayMessage: "Persisted request"
    )
    let thread = AIChatThread(
      title: "Terminal recovery",
      sessionKey: "agent:main:org2-workspace:terminal-recovery",
      messages: [failedMessage, queuedMessage],
      pendingTurn: pendingTurn
    )
    try JSONEncoder().encode(AIChatTranscriptFixture(
      version: 6,
      messages: nil,
      threads: [thread],
      selectedThreadID: thread.id
    )).write(to: transcript, options: .atomic)

    let recorder = AIChatTerminalRecoveryRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in "Follow-up succeeded" },
      aiChatRecoveryHandler: { turn, _ in try await recorder.recover(turn) }
    )

    await store.recoverPendingAIChatTurns()
    XCTAssertNil(store.selectedAIChatThread?.pendingTurn)
    XCTAssertEqual(store.aiChatMessages[0].deliveryStatus, .failed)
    XCTAssertEqual(store.aiChatMessages[1].deliveryStatus, .sent)
    XCTAssertEqual(store.aiChatMessages[2].content, "Follow-up succeeded")
    let initialAttemptCount = await recorder.attemptCount()
    XCTAssertEqual(initialAttemptCount, 1)

    await store.recoverPendingAIChatTurns()
    let finalAttemptCount = await recorder.attemptCount()
    XCTAssertEqual(finalAttemptCount, 1)
  }

  @MainActor
  func testAcceptedGatewayRunIDIsPersistedSeparatelyFromIdempotencyKey() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-accepted-id-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let userMessage = AIChatMessage(
      role: .user,
      content: "Persist the accepted ID",
      deliveryStatus: .sending
    )
    let pendingTurn = AIChatPendingTurn(
      userMessageID: userMessage.id,
      runID: "stable-request-key",
      idempotencyKey: "stable-request-key",
      agentID: "main",
      destinationID: AIChatDestinationConfiguration.openClawID,
      gatewayMessage: "Persisted request"
    )
    let thread = AIChatThread(
      title: "Accepted ID",
      sessionKey: "agent:main:org2-workspace:accepted-id",
      messages: [userMessage],
      pendingTurn: pendingTurn
    )
    try JSONEncoder().encode(AIChatTranscriptFixture(
      version: 6,
      messages: nil,
      threads: [thread],
      selectedThreadID: thread.id
    )).write(to: transcript, options: .atomic)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )

    await store.handleOpenClawGatewayEventDurably(
      .accepted(runID: "gateway-accepted-id"),
      threadID: thread.id,
      destinationID: AIChatDestinationConfiguration.openClawID,
      expectedUserMessageID: userMessage.id
    )

    XCTAssertEqual(store.selectedAIChatThread?.pendingTurn?.runID, "gateway-accepted-id")
    XCTAssertEqual(store.selectedAIChatThread?.pendingTurn?.historyCorrelationID, "stable-request-key")
    let reloaded = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )
    XCTAssertEqual(reloaded.selectedAIChatThread?.pendingTurn?.runID, "gateway-accepted-id")
    XCTAssertEqual(reloaded.selectedAIChatThread?.pendingTurn?.historyCorrelationID, "stable-request-key")
  }

  @MainActor
  func testPendingOpenClawTurnCanStopWithoutLiveGatewayConnection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-stop-offline-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let userMessage = AIChatMessage(
      role: .user,
      content: "Do not reconnect this stale request",
      deliveryStatus: .sending
    )
    let pendingTurn = AIChatPendingTurn(
      userMessageID: userMessage.id,
      runID: "offline-recovery-run-id",
      agentID: "main",
      gatewayMessage: "Persisted request"
    )
    let thread = AIChatThread(
      title: "Offline recovered turn",
      sessionKey: "agent:main:org2-workspace:offline-recovery",
      messages: [userMessage],
      pendingTurn: pendingTurn
    )
    let fixture = AIChatTranscriptFixture(
      version: 4,
      messages: nil,
      threads: [thread],
      selectedThreadID: thread.id
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(fixture).write(to: transcript, options: .atomic)

    let recorder = AIChatRetrySendRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )

    XCTAssertTrue(store.isAIChatThreadRunning(thread.id))
    let didStop = await store.stopAIChatRemoteRun(threadID: thread.id)
    XCTAssertTrue(didStop)
    XCTAssertNil(store.selectedAIChatThread?.pendingTurn)
    XCTAssertEqual(store.aiChatMessages.first?.deliveryStatus, .interrupted)
    XCTAssertEqual(
      store.aiChatMessages.first?.sendFailure,
      "OpenClaw was stopped by you. Retry to start this request again."
    )
    XCTAssertEqual(store.aiChatStatusText, "OpenClaw stopped")
    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))

    let relaunched = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )
    XCTAssertNil(relaunched.selectedAIChatThread?.pendingTurn)
    XCTAssertEqual(relaunched.aiChatMessages.first?.deliveryStatus, .interrupted)
    XCTAssertFalse(relaunched.isAIChatThreadRunning(thread.id))

    await store.retryAIChatMessage(userMessage.id)
    let firstRetryAttemptCount = await recorder.attemptCount()
    XCTAssertEqual(firstRetryAttemptCount, 1)
    XCTAssertEqual(store.aiChatMessages.first?.deliveryStatus, .failed)
    XCTAssertEqual(store.aiChatMessages.first?.sendFailure, "VPN disconnected")

    await store.retryAIChatMessage(userMessage.id)
    let secondRetryAttemptCount = await recorder.attemptCount()
    XCTAssertEqual(secondRetryAttemptCount, 2)
    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:Do not reconnect this stale request",
      "assistant:reply after reconnect"
    ])
    XCTAssertEqual(store.aiChatMessages.first?.deliveryStatus, .sent)
    XCTAssertNil(store.aiChatMessages.first?.sendFailure)
  }

  @MainActor
  func testSyncedHostCannotStopAnotherHostsPendingRun() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-remote-owner-stop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("openclaw-chat.json")
    let userMessage = AIChatMessage(
      role: .user,
      content: "Still running elsewhere",
      deliveryStatus: .sending
    )
    let pendingTurn = AIChatPendingTurn(
      userMessageID: userMessage.id,
      runID: "remote-owned-run",
      idempotencyKey: "remote-owned-key",
      dispatchOwnerID: "definitely-another-host.invalid",
      agentID: "main",
      gatewayMessage: "Persisted request"
    )
    let thread = AIChatThread(
      title: "Remote-owned run",
      sessionKey: "agent:main:org2-workspace:remote-owned",
      messages: [userMessage],
      pendingTurn: pendingTurn
    )
    try JSONEncoder().encode(AIChatTranscriptFixture(
      version: 6,
      messages: nil,
      threads: [thread],
      selectedThreadID: thread.id
    )).write(to: transcript, options: .atomic)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcript
    )

    let didStop = await store.stopAIChatRemoteRun(threadID: thread.id)
    XCTAssertFalse(didStop)
    XCTAssertEqual(store.selectedAIChatThread?.pendingTurn, pendingTurn)
    XCTAssertEqual(store.aiChatMessages.first?.deliveryStatus, .sending)
  }

  @MainActor
  func testMacApprovalsRefreshDiscussAndApproveViaStore() async throws {
    let recorder = AIChatMessageSendRecorder()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approvals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("approvals.org2")
    try """
    * TODO Send approved launch email
    :PROPERTIES:
    :STATUS: waiting
    :END:

    * TODO Review and approve launch email
    :PROPERTIES:
    :ID: approval-1
    :REVIEW_STATUS: review-required
    :PAIRED_SEND_TODO: Send approved launch email
    :END:
    Please review the launch email before sending it.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.setCorpusRoot(root, persistsDefault: false)

    await store.refreshApprovals(updatesStatus: true)

    let approval = try XCTUnwrap(store.approvalItems.first)
    XCTAssertEqual(approval.title, "Review and approve launch email")
    XCTAssertEqual(approval.status, "review-required")
    XCTAssertEqual(store.statusText, "1 approval")

    await store.discussApprovalInAIChat(approval)

    let calls = await recorder.recordedCalls()
    let sentText = try XCTUnwrap(calls.first?.last?.content)
    XCTAssertTrue(sentText.contains("OpenClaw approval thread"))
    XCTAssertTrue(sentText.contains("Please review the launch email"))
    let discussionThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    let discussionThread = try XCTUnwrap(store.aiChatThreads.first(where: { $0.id == discussionThreadID }))
    XCTAssertEqual(discussionThread.title, "Discuss: Review and approve launch email")
    let visibleDiscussion = AIChatContextPresentation(
      try XCTUnwrap(discussionThread.messages.last(where: { $0.role == .user })?.content)
    )
    XCTAssertEqual(visibleDiscussion.userText, "I need to discuss this approval item before deciding.")
    XCTAssertEqual(visibleDiscussion.contexts.map(\.title), ["Review and approve launch email"])
    XCTAssertTrue(visibleDiscussion.contexts[0].automaticPrompt?.contains("Please review the launch email") == true)
    XCTAssertFalse(visibleDiscussion.clipboardText.contains("Please review the launch email"))

    await store.approve(approval)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Send approved launch email"))
    XCTAssertTrue(updated.contains(":STATUS: approved-to-send"))
    XCTAssertTrue(updated.contains(":ASSIGNEE: OpenClaw"))
    XCTAssertTrue(updated.contains("* DONE Review and approve launch email"))
    XCTAssertTrue(updated.contains(":REVIEW_STATUS: approved"))
    XCTAssertTrue(updated.contains(":STATUS: approved"))
    XCTAssertTrue(store.approvalItems.isEmpty)
  }

  @MainActor
  func testApprovingMiddleItemKeepsSelectionOnNextApprovalAfterRefresh() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approval-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("approvals.org2")
    try """
    * TODO Approve first draft
    :PROPERTIES:
    :ID: approval-first
    :STATUS: draft-needs-review
    :END:
    First draft.

    * TODO Approve second draft
    :PROPERTIES:
    :ID: approval-second
    :STATUS: draft-needs-review
    :END:
    Second draft.

    * TODO Approve third draft
    :PROPERTIES:
    :ID: approval-third
    :STATUS: draft-needs-review
    :END:
    Third draft.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    await store.refreshApprovals()

    XCTAssertEqual(store.visibleApprovalItems.map(\.idValue), [
      "approval-first",
      "approval-second",
      "approval-third"
    ])
    let second = try XCTUnwrap(store.visibleApprovalItems.first(where: { $0.idValue == "approval-second" }))
    store.selectApprovalItem(second)

    await store.approve(second)

    XCTAssertEqual(
      store.visibleApprovalItems.first(where: { $0.id == store.selectedApprovalItemID })?.idValue,
      "approval-third"
    )

    await store.refreshApprovals()

    XCTAssertEqual(store.visibleApprovalItems.map(\.idValue), ["approval-first", "approval-third"])
    XCTAssertEqual(
      store.visibleApprovalItems.first(where: { $0.id == store.selectedApprovalItemID })?.idValue,
      "approval-third"
    )
  }

  @MainActor
  func testDiscussApprovalCanReuseCurrentAIChatThreadWhenRequested() async throws {
    let recorder = AIChatMessageSendRecorder()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approval-current-thread-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("approvals.org2")
    try """
    * TODO Review launch follow-up
    :PROPERTIES:
    :ID: approval-2
    :REVIEW_STATUS: review-required
    :END:
    Needs human review.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatThread(runtime: .openClaw)
    let originalThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Existing approval context")
    ]

    await store.refreshApprovals(updatesStatus: true)
    let approval = try XCTUnwrap(store.approvalItems.first)
    await store.discussApprovalInAIChat(
      approval,
      message: "Check this before sending.",
      threadMode: .currentThread
    )

    XCTAssertEqual(store.selectedAIChatThreadID, originalThreadID)
    XCTAssertEqual(store.aiChatThreads.count, 1)
    XCTAssertEqual(store.aiChatMessages.first?.content, "Existing approval context")
    XCTAssertTrue(store.aiChatMessages.map(\.content).contains { $0.contains("Check this before sending.") })
  }

  func testApprovalDiscussionDestinationNamesOnlyOfferAnExistingSelectedThread() {
    XCTAssertEqual(
      AIChatThreadMode.newThread.discussionDestinationTitle(selectedThreadTitle: nil),
      "New thread"
    )
    XCTAssertNil(
      AIChatThreadMode.currentThread.discussionDestinationTitle(selectedThreadTitle: nil)
    )
    XCTAssertEqual(
      AIChatThreadMode.currentThread.discussionDestinationTitle(
        selectedThreadTitle: "Example Reviewer review"
      ),
      "Continue in \u{201c}Example Reviewer review\u{201d}"
    )
  }

  @MainActor
  func testMacApprovalsIgnoreSyncthingHistorySnapshots() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approval-stversions-\(UUID().uuidString)", isDirectory: true)
    let agents = root.appendingPathComponent("agents", isDirectory: true)
    let versions = root.appendingPathComponent(".stversions/agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)

    let live = agents.appendingPathComponent("account-outreach.org2")
    let snapshot = versions.appendingPathComponent("account-outreach~20260706-100605.org2")
    let approval = """
    **** TODO Approve account-aware follow-up to Databricks / Unity Catalog
    :PROPERTIES:
    :ID: approval-databricks
    :STATUS: draft-needs-review
    :END:
    Draft text.
    """
    try approval.write(to: live, atomically: true, encoding: .utf8)
    try approval.write(to: snapshot, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)

    await store.refreshApprovals(updatesStatus: true)

    XCTAssertEqual(store.approvalItems.count, 1)
    let approvalItem = try XCTUnwrap(store.approvalItems.first)
    XCTAssertEqual(approvalItem.title, "Approve account-aware follow-up to Databricks / Unity Catalog")
    XCTAssertEqual(approvalItem.file, live.path)
    XCTAssertFalse(approvalItem.file.contains(".stversions"))
    XCTAssertEqual(store.statusText, "1 approval")
  }

  @MainActor
  func testLocalCorpusApprovalsRefreshWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rawCorpus = environment["ORG2_WORKSPACE_LOCAL_CORPUS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !rawCorpus.isEmpty
    else {
      throw XCTSkip("Set ORG2_WORKSPACE_LOCAL_CORPUS to smoke-test approvals against a local corpus.")
    }

    let root = URL(fileURLWithPath: rawCorpus).standardizedFileURL
    let defaults = UserDefaults(suiteName: "org2-workspace-local-approvals-\(UUID().uuidString)") ?? .standard
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent(".org2/local-approval-smoke-openclaw.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)

    let start = Date()
    await store.refreshApprovals(updatesStatus: true)
    let elapsed = Date().timeIntervalSince(start)

    XCTAssertNil(store.errorText)
    XCTAssertFalse(store.isLoadingApprovals)
    XCTAssertTrue(store.statusText.contains("approval"))
    print("Local corpus approvals refresh: \(store.approvalItems.count) approvals in \(String(format: "%.3f", elapsed))s")
  }

  @MainActor
  func testAIChatComposerSendsPendingImageAttachments() async throws {
    let recorder = AIChatMessageSendRecorder()
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-image-send-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let imageURL = temp.appendingPathComponent("sketch.png")
    try Data([0x89, 0x50, 0x4e, 0x47]).write(to: imageURL)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: temp.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.attachAIChatImages(urls: [imageURL])

    XCTAssertEqual(store.aiChatPendingAttachments.count, 1)

    await store.sendAIChatMessage()

    XCTAssertTrue(store.aiChatPendingAttachments.isEmpty)
    XCTAssertEqual(store.aiChatMessages.first?.attachments.first?.fileName, "sketch.png")
    let calls = await recorder.recordedCalls()
    XCTAssertEqual(calls.first?.last?.attachments.first?.mimeType, "image/png")
  }

  @MainActor
  func testAIChatComposerAcceptsDroppedFilesAndRejectsVideo() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-file-attachments-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let textURL = temp.appendingPathComponent("notes.txt")
    let videoURL = temp.appendingPathComponent("clip.mp4")
    try Data("hello".utf8).write(to: textURL)
    try Data([0x00, 0x00, 0x00, 0x18]).write(to: videoURL)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: temp.appendingPathComponent("openclaw-chat.json")
    )
    store.attachAIChatFiles(urls: [textURL, videoURL])

    XCTAssertEqual(store.aiChatPendingAttachments.map(\.fileName), ["notes.txt"])
    XCTAssertEqual(store.aiChatPendingAttachments.first?.mimeType, "text/plain")
    XCTAssertEqual(store.errorText, "clip.mp4 is a video, which OpenClaw chat attachments do not support.")
  }

  @MainActor
  func testAIChatPickerPreparesAttachmentsWithoutBlockingTheMainActor() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-picker-attachments-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let imageURL = temp.appendingPathComponent("sketch.png")
    try Data(repeating: 0x5a, count: 1_000_000).write(to: imageURL)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: temp.appendingPathComponent("openclaw-chat.json")
    )
    store.enqueueAIChatAttachmentPreparationForTesting(urls: [imageURL], imagesOnly: true)

    XCTAssertTrue(store.aiChatPendingAttachments.isEmpty)
    XCTAssertTrue(store.aiChatStatusText.hasPrefix("Attaching "))
    store.advanceAIChatTranscriptLoadGenerationForTesting()

    await store.waitForAIChatAttachmentPreparationForTesting()
    XCTAssertEqual(store.aiChatPendingAttachments.map(\.fileName), ["sketch.png"])
    XCTAssertEqual(store.aiChatPendingAttachments.first?.mimeType, "image/png")
    XCTAssertEqual(store.aiChatStatusText, "1 attachment ready")
  }

  @MainActor
  func testAIChatReplyRecordsCorpusChangeSummary() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-changes-\(UUID().uuidString)", isDirectory: true)
    let root = temp.appendingPathComponent("corpus", isDirectory: true)
    let transcript = temp.appendingPathComponent("transcript", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let notePath = root.appendingPathComponent("note.org").path
    let createdPath = root.appendingPathComponent("created.org").path
    try "Line one\n".write(toFile: notePath, atomically: true, encoding: .utf8)

    let suiteName = "org2-workspace-chat-changes-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in
        try "Line one\nLine two\n".write(toFile: notePath, atomically: true, encoding: .utf8)
        try "Alpha\nBeta\n".write(toFile: createdPath, atomically: true, encoding: .utf8)
        return "Updated the corpus"
      }
    )
    store.setCorpusRoot(root)
    store.aiChatDraft = "Update these notes"

    await store.sendAIChatMessage()

    let assistantMessage = try XCTUnwrap(store.aiChatMessages.last)
    let summary = try XCTUnwrap(assistantMessage.changeSummary)
    XCTAssertEqual(summary.title, "Edited 2 files")
    XCTAssertEqual(summary.changedFileCount, 2)
    XCTAssertEqual(summary.totalInsertions, 3)
    XCTAssertEqual(summary.totalDeletions, 0)
    XCTAssertEqual(
      summary.files,
      [
        AIChatCorpusFileChange(relativePath: "created.org", status: .created, insertions: 2, deletions: 0),
        AIChatCorpusFileChange(relativePath: "note.org", status: .modified, insertions: 1, deletions: 0)
      ]
    )

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript
    )
    XCTAssertEqual(restored.aiChatMessages.last?.changeSummary, summary)
  }

  @MainActor
  func testAIChatReplyAttributesDiffToReferencedFilesWhenBackgroundJobsAlsoWrite() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-attributed-changes-\(UUID().uuidString)", isDirectory: true)
    let root = temp.appendingPathComponent("corpus", isDirectory: true)
    let transcript = temp.appendingPathComponent("transcript", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    let agents = root.appendingPathComponent("agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)

    let target = agents.appendingPathComponent("account-outreach.org2")
    let background = agents.appendingPathComponent("MeetingBot.org2")
    try "Target one\n".write(to: target, atomically: true, encoding: .utf8)
    try "Background one\n".write(to: background, atomically: true, encoding: .utf8)

    let suiteName = "org2-workspace-chat-attributed-changes-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let targetPath = target.path
    let backgroundPath = background.path
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in
        try "Target one\nTarget two\n".write(toFile: targetPath, atomically: true, encoding: .utf8)
        try "Background one\nBackground two\n".write(toFile: backgroundPath, atomically: true, encoding: .utf8)
        return "Done. Added the scheduled review TODO in /srv/org2/agents/account-outreach.org2."
      }
    )
    store.setCorpusRoot(root)
    XCTAssertTrue(store.saveOpenClawConfiguration(
      endpoint: store.openClawEndpointText,
      agent: store.openClawAgentID,
      handoffAssignee: store.agentHandoffAssignee,
      remoteCorpusPath: "/srv/org2",
      token: "",
      clearToken: false
    ))
    store.aiChatDraft = "Create the TODO"

    await store.sendAIChatMessage()

    let summary = try XCTUnwrap(store.aiChatMessages.last?.changeSummary)
    XCTAssertEqual(summary.changedFileCount, 1)
    XCTAssertEqual(
      summary.files,
      [
        AIChatCorpusFileChange(
          relativePath: "agents/account-outreach.org2",
          status: .modified,
          insertions: 1,
          deletions: 0
        )
      ]
    )
  }

  @MainActor
  func testAIChatReplyRetriesBrieflyForDelayedCorpusChanges() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-delayed-changes-\(UUID().uuidString)", isDirectory: true)
    let root = temp.appendingPathComponent("corpus", isDirectory: true)
    let transcript = temp.appendingPathComponent("transcript", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let note = root.appendingPathComponent("agents", isDirectory: true)
      .appendingPathComponent("account-outreach.org2")
    try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "Original\n".write(to: note, atomically: true, encoding: .utf8)

    let suiteName = "org2-workspace-chat-delayed-changes-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let notePath = note.path
    let events = DelayedCorpusEventReceiver()
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 200_000_000)
          try? "Original\nAdded\n".write(toFile: notePath, atomically: true, encoding: .utf8)
          // This tests delayed change handling; CorpusFileWatcherTests cover
          // asynchronous OS delivery independently of this retry deadline.
          events.store?.handleCorpusFileEvents([notePath], corpusRoot: root, requiresFullScan: false)
        }
        return "Updated later"
      }
    )
    events.store = store
    store.setCorpusRoot(root)
    store.aiChatDraft = "Update this"

    await store.sendAIChatMessage()

    let summary = try XCTUnwrap(store.aiChatMessages.last?.changeSummary)
    XCTAssertEqual(summary.changedFileCount, 1)
    XCTAssertEqual(summary.totalInsertions, 1)
    XCTAssertEqual(summary.totalDeletions, 0)
    XCTAssertEqual(summary.files.first?.relativePath, "agents/account-outreach.org2")
  }

  @MainActor
  func testAIChatReplyLeavesLiveUIBeforeChangeSummaryFinishes() async throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-fast-terminal-ui-\(UUID().uuidString)", isDirectory: true)
    let root = temp.appendingPathComponent("corpus", isDirectory: true)
    let transcript = temp.appendingPathComponent("transcript", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    let note = root.appendingPathComponent("note.org2")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "Before\n".write(to: note, atomically: true, encoding: .utf8)

    let suiteName = "org2-workspace-chat-fast-terminal-ui-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let notePath = note.path
    let events = DelayedCorpusEventReceiver()
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      aiChatSendHandler: { _, _, _, _ in
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 250_000_000)
          try? "Before\nAfter\n".write(toFile: notePath, atomically: true, encoding: .utf8)
          // This tests delayed change handling; CorpusFileWatcherTests cover
          // asynchronous OS delivery independently of this retry deadline.
          events.store?.handleCorpusFileEvents([notePath], corpusRoot: root, requiresFullScan: false)
        }
        return "Updated note.org2"
      }
    )
    events.store = store
    store.setCorpusRoot(root)
    store.aiChatDraft = "Update the note"

    let sendTask = Task { await store.sendAIChatMessage() }
    for _ in 0..<50 where store.aiChatMessages.last?.role != .assistant {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(store.aiChatMessages.last?.content, "Updated note.org2")
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatStatusText, "OpenClaw replied")

    await sendTask.value
    XCTAssertEqual(store.aiChatMessages.last?.changeSummary?.totalInsertions, 1)
  }

  @MainActor
  func testAIChatTranscriptPersistsInCorpusStorageAcrossBootstrap() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-corpus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "org2-workspace-chat-corpus-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(root)
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Remember this corpus chat"),
      AIChatMessage(role: .assistant, content: "Stored with the corpus")
    ]
    try await store.waitForAIChatTranscriptPersistenceForTesting()

    let corpusTranscript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: corpusTranscript.path))

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    await restored.bootstrap()

    XCTAssertEqual(restored.aiChatMessages.map(\.content), ["Remember this corpus chat", "Stored with the corpus"])
  }

  @MainActor
  func testAIChatTranscriptMigratesLegacyAppSupportStorageOnBootstrap() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-migration-\(UUID().uuidString)", isDirectory: true)
    let appSupport = root.appendingPathComponent("app-support", isDirectory: true)
    try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyTranscript = appSupport.appendingPathComponent("openclaw-chat.json")
    let legacyID = UUID()
    let createdAt = Date().timeIntervalSinceReferenceDate
    try """
    {
      "messages": [
        {
          "content": "Legacy app-support chat",
          "createdAt": \(createdAt),
          "id": "\(legacyID.uuidString)",
          "role": "user"
        }
      ],
      "version": 1
    }
    """.write(to: legacyTranscript, atomically: true, encoding: .utf8)

    let suiteName = "org2-workspace-chat-migration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(root.path, forKey: "Org2Workspace.corpusRoot")
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatFallbackTranscriptURL: legacyTranscript
    )
    await restored.bootstrap()

    let corpusTranscript = root
      .appendingPathComponent(".org2", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
    XCTAssertEqual(restored.aiChatMessages.map(\.content), ["Legacy app-support chat"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: corpusTranscript.path))
    let selectedThreadID = try XCTUnwrap(restored.selectedAIChatThreadID)
    let selectedThread = try XCTUnwrap(
      restored.aiChatThreads.first(where: { $0.id == selectedThreadID })
    )
    let persistedThread = try XCTUnwrap(AIChatTranscriptStore.shared.loadThread(
      id: selectedThreadID,
      metadata: selectedThread,
      legacyURL: corpusTranscript
    ))
    XCTAssertEqual(persistedThread.messages.map(\.content), ["Legacy app-support chat"])
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: AIChatTranscriptStore.storeDirectory(for: legacyTranscript).path
    ))
  }

  @MainActor
  func testAgendaModeDefaultsToFocus() throws {
    let suiteName = "org2-workspace-agenda-mode-default-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(store.agendaMode, .focus)
    XCTAssertEqual(store.agendaReadScope, .activeCorpus)
    XCTAssertEqual(store.searchReadScope, .activeCorpus)
  }

  @MainActor
  func testAgendaModePersistsLastSelection() throws {
    let suiteName = "org2-workspace-agenda-mode-persist-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.agendaMode = .range

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(restored.agendaMode, .range)
  }

  @MainActor
  func testAgendaModeKeySelectsAssigned() throws {
    let suiteName = "org2-workspace-agenda-mode-key-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    store.setAgendaModeFromKey("4")

    XCTAssertEqual(store.agendaMode, .assigned)
  }

  @MainActor
  func testAgentHandoffAssigneeDefaultsAndPersistsSeparatelyFromOpenClawChatAgent() throws {
    let suiteName = "org2-workspace-handoff-assignee-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(store.openClawAgentID, "main")
    XCTAssertEqual(store.agentHandoffAssignee, "OpenClaw")
    XCTAssertEqual(store.personalAssigneeNamesText, "")
    XCTAssertTrue(store.aiChatBriefsStartNewThread)
    XCTAssertTrue(store.saveOpenClawConfiguration(
      endpoint: store.openClawEndpointText,
      agent: "research-agent",
      handoffAssignee: "OpenClaw",
      personalAssigneeNames: "Avi, avi@example.com",
      remoteCorpusPath: "/srv/org2",
      briefsStartNewThread: false,
      token: "",
      clearToken: false
    ))

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(restored.openClawAgentID, "research-agent")
    XCTAssertEqual(restored.agentHandoffAssignee, "OpenClaw")
    XCTAssertEqual(restored.personalAssigneeNamesText, "Avi, avi@example.com")
    XCTAssertFalse(restored.aiChatBriefsStartNewThread)
  }

  @MainActor
  func testPersonalAssigneeNamesClassifyAgendaOwnership() throws {
    let suiteName = "org2-workspace-personal-assignee-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertTrue(store.isPersonalAssignee(nil))
    XCTAssertTrue(store.isPersonalAssignee(""))
    XCTAssertFalse(store.isPersonalAssignee("Avi"))
    XCTAssertTrue(store.saveOpenClawConfiguration(
      endpoint: store.openClawEndpointText,
      agent: store.openClawAgentID,
      handoffAssignee: store.agentHandoffAssignee,
      personalAssigneeNames: "Avi; avi@example.com\nAvi Press",
      remoteCorpusPath: store.openClawRemoteCorpusPath,
      token: "",
      clearToken: false
    ))

    XCTAssertTrue(store.isPersonalAssignee("Avi"))
    XCTAssertTrue(store.isPersonalAssignee(" avi@example.com "))
    XCTAssertTrue(store.isPersonalAssignee("avi   press"))
    XCTAssertFalse(store.isPersonalAssignee("OpenClaw"))
  }

  @MainActor
  func testAgentAssigneeClassificationUsesConfiguredHandoffAssigneeOnly() throws {
    let suiteName = "org2-workspace-agent-assignee-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertFalse(store.isAgentAssignee(nil))
    XCTAssertFalse(store.isAgentAssignee(""))
    XCTAssertTrue(store.isAgentAssignee("OpenClaw"))
    XCTAssertFalse(store.isAgentAssignee("Avi"))
    XCTAssertTrue(store.saveOpenClawConfiguration(
      endpoint: store.openClawEndpointText,
      agent: store.openClawAgentID,
      handoffAssignee: "OpenClaw Worker",
      personalAssigneeNames: "Avi",
      remoteCorpusPath: store.openClawRemoteCorpusPath,
      token: "",
      clearToken: false
    ))

    XCTAssertTrue(store.isAgentAssignee("openclaw worker"))
    XCTAssertTrue(store.isAgentAssignee("OpenClaw"))
    XCTAssertFalse(store.isAgentAssignee("Avi"))
  }

  @MainActor
  func testOpenClawConfigurationMigratesFromLegacyDefaultsDomain() throws {
    let currentSuiteName = "org2-workspace-stable-defaults-\(UUID().uuidString)"
    let legacySuiteName = "org2-workspace-legacy-defaults-\(UUID().uuidString)"
    let currentDefaults = UserDefaults(suiteName: currentSuiteName)!
    let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
    defer {
      currentDefaults.removePersistentDomain(forName: currentSuiteName)
      legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }

    legacyDefaults.set("https://example.invalid/v1/chat/completions", forKey: "Org2Workspace.openClawEndpoint")
    legacyDefaults.set("openclaw/org2", forKey: "Org2Workspace.openClawAgent")
    legacyDefaults.set("OpenClaw", forKey: "Org2Workspace.agentHandoffAssignee")
    legacyDefaults.set("Avi", forKey: "Org2Workspace.personalAssigneeNames")
    legacyDefaults.set("/remote/org2", forKey: "Org2Workspace.openClawRemoteCorpusPath")

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: currentDefaults,
      legacyDefaultsDomains: [legacySuiteName]
    )

    XCTAssertEqual(store.openClawEndpointText, "https://example.invalid/v1/chat/completions")
    XCTAssertEqual(store.openClawAgentID, "openclaw/org2")
    XCTAssertEqual(store.agentHandoffAssignee, "OpenClaw")
    XCTAssertEqual(store.personalAssigneeNamesText, "Avi")
    XCTAssertEqual(store.openClawRemoteCorpusPath, "/remote/org2")
    XCTAssertTrue(currentDefaults.bool(forKey: "Org2Workspace.legacyDefaultsMigrated.v1"))
  }

  func testLegacyDefaultsMigrationRunsOnlyForProductionBundleByDefault() {
    XCTAssertTrue(WorkspaceStore.shouldMigrateLegacyDefaults(bundleIdentifier: nil))
    XCTAssertTrue(WorkspaceStore.shouldMigrateLegacyDefaults(bundleIdentifier: "org.org2.workspace"))
    XCTAssertFalse(WorkspaceStore.shouldMigrateLegacyDefaults(bundleIdentifier: "org.org2.workspace.codex"))
  }

  @MainActor
  func testLegacyDefaultsMigrationDoesNotOverwriteCurrentOpenClawConfiguration() throws {
    let currentSuiteName = "org2-workspace-current-defaults-\(UUID().uuidString)"
    let legacySuiteName = "org2-workspace-old-defaults-\(UUID().uuidString)"
    let currentDefaults = UserDefaults(suiteName: currentSuiteName)!
    let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
    defer {
      currentDefaults.removePersistentDomain(forName: currentSuiteName)
      legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }

    currentDefaults.set("https://current.example.invalid/v1/chat/completions", forKey: "Org2Workspace.openClawEndpoint")
    currentDefaults.set("current-agent", forKey: "Org2Workspace.openClawAgent")
    currentDefaults.set("/current/org2", forKey: "Org2Workspace.openClawRemoteCorpusPath")
    legacyDefaults.set("https://legacy.example.invalid/v1/chat/completions", forKey: "Org2Workspace.openClawEndpoint")
    legacyDefaults.set("legacy-agent", forKey: "Org2Workspace.openClawAgent")
    legacyDefaults.set("/legacy/org2", forKey: "Org2Workspace.openClawRemoteCorpusPath")

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: currentDefaults,
      legacyDefaultsDomains: [legacySuiteName]
    )

    XCTAssertEqual(store.openClawEndpointText, "https://current.example.invalid/v1/chat/completions")
    XCTAssertEqual(store.openClawAgentID, "current-agent")
    XCTAssertEqual(store.openClawRemoteCorpusPath, "/current/org2")
  }

  @MainActor
  func testOrgCryptConfigurationPersistsRecipientFilesAsDefaults() throws {
    let suiteName = "org2-workspace-crypt-config-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    XCTAssertTrue(store.saveOrgCryptConfiguration(
      encryptOnSave: true,
      recipientsText: "person@example.com",
      recipientFilesText: "/tmp/team.asc\nkeys/project.asc",
      useDefaultGpgKey: true,
      gpgProgram: "gpg",
      passphrase: "",
      clearPassphrase: false
    ))

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertEqual(restored.orgCryptRecipientsText, "person@example.com")
    XCTAssertEqual(restored.orgCryptRecipientFilesText, "/tmp/team.asc\nkeys/project.asc")
    XCTAssertTrue(restored.orgCryptUseDefaultGpgKey)
  }

  @MainActor
  func testOrgCryptImportsAgentPublicKeysIntoCorpusPublicKeys() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-public-keys-\(UUID().uuidString)", isDirectory: true)
    let sourceDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-public-key-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let source = sourceDirectory.appendingPathComponent("clavi.asc")
    try "PUBLIC KEY".write(to: source, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    let imported = try store.importOrgCryptAgentPublicKey(from: source)

    XCTAssertEqual(imported.relativePath, "public-keys/clavi.asc")
    XCTAssertEqual(imported.name, "clavi.asc")
    XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: imported.path), encoding: .utf8), "PUBLIC KEY")
    XCTAssertEqual(store.orgCryptManagedRecipientFiles, [imported])
    XCTAssertTrue(store.orgCryptStatusText.contains("Added clavi.asc"))
  }

  @MainActor
  func testOrgCryptManagedRecipientFilesSplitAndPersistWithManualFiles() async throws {
    let suiteName = "org2-workspace-crypt-managed-config-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-managed-public-keys-\(UUID().uuidString)", isDirectory: true)
    let publicKeys = root.appendingPathComponent("public-keys", isDirectory: true)
    try FileManager.default.createDirectory(at: publicKeys, withIntermediateDirectories: true)
    let clavi = publicKeys.appendingPathComponent("clavi.asc")
    let helper = publicKeys.appendingPathComponent("helper.asc")
    try "CLAVI".write(to: clavi, atomically: true, encoding: .utf8)
    try "HELPER".write(to: helper, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    store.setCorpusRoot(root)
    await store.waitForOrgCryptRecipientRefreshForTesting()

    XCTAssertEqual(store.orgCryptManagedRecipientFiles.map(\.relativePath), [
      "public-keys/clavi.asc",
      "public-keys/helper.asc"
    ])

    let savedRecipientFiles = "\(clavi.path)\n/tmp/team.asc\npublic-keys/helper.asc"
    XCTAssertEqual(store.selectedManagedOrgCryptRecipientFilePaths(in: savedRecipientFiles), Set([clavi.path, helper.path]))
    XCTAssertEqual(store.manualOrgCryptRecipientFilesText(from: savedRecipientFiles), "/tmp/team.asc")

    let combined = store.combinedOrgCryptRecipientFilesText(
      manualText: "/tmp/team.asc",
      selectedManagedPaths: Set([helper.path])
    )
    XCTAssertEqual(combined, "/tmp/team.asc\n\(helper.path)")
    XCTAssertTrue(store.saveOrgCryptConfiguration(
      encryptOnSave: true,
      recipientsText: "",
      recipientFilesText: combined,
      useDefaultGpgKey: true,
      gpgProgram: "gpg",
      passphrase: "",
      clearPassphrase: false
    ))

    let restored = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    XCTAssertEqual(restored.orgCryptRecipientFilesText, "/tmp/team.asc\n\(helper.path)")
  }

  @MainActor
  func testOrgCryptConfigurationDefaultsToIncludingDefaultGPGKey() throws {
    let suiteName = "org2-workspace-crypt-config-default-key-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertTrue(store.orgCryptUseDefaultGpgKey)
  }

  @MainActor
  func testOrgCryptConfigurationMigratesOldDefaultGPGKeySettingOn() throws {
    let suiteName = "org2-workspace-crypt-config-migrate-key-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "Org2Workspace.orgCrypt.useDefaultGpgKey")

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)

    XCTAssertTrue(store.orgCryptUseDefaultGpgKey)
    XCTAssertTrue(defaults.bool(forKey: "Org2Workspace.orgCrypt.useDefaultGpgKey"))
  }

  func testOpenClawChatClientNormalizesModelAndAgentNames() {
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: ""), "openclaw")
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: "openclaw"), "openclaw")
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: "org2-workspace"), "openclaw/org2-workspace")
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: "openclaw/org2-workspace"), "openclaw/org2-workspace")
    XCTAssertEqual(OpenClawChatClient.openClawModelName(for: "clawdbot:org2-workspace"), "openclaw/org2-workspace")

    XCTAssertEqual(OpenClawChatClient.openClawAgentHeaderValue(for: ""), "main")
    XCTAssertEqual(OpenClawChatClient.openClawAgentHeaderValue(for: "openclaw"), "main")
    XCTAssertEqual(OpenClawChatClient.openClawAgentHeaderValue(for: "openclaw/org2-workspace"), "org2-workspace")
  }

  func testOpenClawChatClientAllowsLongRunningAgentRequests() {
    let configuration = OpenClawChatClient.sessionConfiguration()

    XCTAssertEqual(OpenClawChatClient.requestTimeout, 7_200)
    XCTAssertEqual(OpenClawChatClient.resourceTimeout, 7_200)
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 7_200)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 7_200)
  }

  @MainActor
  func testRenderedDocumentLayoutDefaultsAndPersists() throws {
    let suiteName = "org2-workspace-rendered-layout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    XCTAssertEqual(store.renderedDocumentWidth, .comfortable)
    XCTAssertEqual(store.renderedDocumentMargin, .standard)
    XCTAssertTrue(store.propertyDrawersExpandedByDefault)
    XCTAssertEqual(store.renderedDocumentLayout.width.cssValue, "960px")
    XCTAssertEqual(store.renderedDocumentLayout.margin.cssValue, "28px")

    store.renderedDocumentWidth = .full
    store.renderedDocumentMargin = .compact
    store.propertyDrawersExpandedByDefault = false

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    XCTAssertEqual(restored.renderedDocumentWidth, .full)
    XCTAssertEqual(restored.renderedDocumentMargin, .compact)
    XCTAssertFalse(restored.propertyDrawersExpandedByDefault)
  }

  @MainActor
  func testWorkspaceAppearanceDefaultsToSystemAndPersists() throws {
    let suiteName = "org2-workspace-appearance-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    XCTAssertEqual(store.appearanceMode, .system)
    XCTAssertNil(store.appearanceMode.colorScheme)

    store.appearanceMode = .dark
    XCTAssertEqual(store.appearanceMode.colorScheme, .dark)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    XCTAssertEqual(restored.appearanceMode, .dark)
  }

  func testPropertyDrawerDefaultPresentationCanCollapseAndExpandRenderedHTML() {
    let rendered = #"<details class="org2-properties-drawer" open data-org2-start-line="2"><summary>Properties</summary></details>"#

    let collapsed = WorkspaceStore.applyingPropertyDrawerDefault(to: rendered, expanded: false)
    XCTAssertTrue(collapsed.contains(#"<details class="org2-properties-drawer" data-org2-start-line="2">"#))
    XCTAssertFalse(collapsed.contains(#"class="org2-properties-drawer" open"#))

    let expanded = WorkspaceStore.applyingPropertyDrawerDefault(to: collapsed, expanded: true)
    XCTAssertTrue(expanded.contains(#"<details class="org2-properties-drawer" open data-org2-start-line="2">"#))
  }

  func testMeetingArtifactWriterCreatesNoteAndTranscript() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-artifacts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordedAt = ISO8601DateFormatter().date(from: "2026-06-11T21:00:00Z")!
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Scarf reporting sync",
      recordedAt: recordedAt
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)
    try Data("fake system audio".utf8).write(to: paths.systemAudioURL)

    let bundle = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: 12.5,
      transcript: MeetingTranscriptResult(
        text: "We decided to publish the reporting update.",
        status: .complete,
        engine: "whisper.cpp"
      ),
      systemAudioURL: paths.systemAudioURL
    )

    let note = try String(contentsOf: bundle.noteURL, encoding: .utf8)
    let transcript = try String(contentsOf: bundle.transcriptURL, encoding: .utf8)

    XCTAssertEqual(bundle.noteURL.pathExtension, "org")
    XCTAssertTrue(bundle.transcriptURL.lastPathComponent.hasSuffix(".transcript.org"))
    XCTAssertTrue(note.contains("* Meeting: Scarf reporting sync"))
    XCTAssertTrue(note.contains(":kind: meeting"))
    XCTAssertTrue(note.contains(":audio_artifact: meetings/"))
    XCTAssertTrue(note.contains(":system_audio_artifact: meetings/"))
    XCTAssertTrue(note.contains(":transcript_artifact: meetings/"))
    XCTAssertTrue(note.contains(":capture_sources: microphone, system_audio"))
    XCTAssertTrue(note.contains(":transcription_engine: whisper.cpp"))
    XCTAssertTrue(note.contains("** Decisions"))
    XCTAssertTrue(transcript.contains("* Transcript: Scarf reporting sync"))
    XCTAssertTrue(transcript.contains(":kind: meeting_transcript"))
    XCTAssertTrue(transcript.contains(":system_audio_artifact: meetings/"))
    XCTAssertTrue(transcript.contains("We decided to publish the reporting update."))
  }

  func testLiveMeetingNoteKeepsNotesTakenDuringRecording() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-live-meeting-note-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recordedAt = ISO8601DateFormatter().date(from: "2026-10-16T17:00:00Z")!
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Pricing review",
      recordedAt: recordedAt
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)

    let item = try MeetingArtifactWriter.writeLiveMeetingNote(paths: paths, corpusRoot: root)
    XCTAssertEqual(item.file, paths.noteURL.path)
    XCTAssertEqual(item.transcriptionStatus, MeetingArtifactWriter.liveRecordingStatus)
    XCTAssertEqual(item.idValue, paths.meetingID)
    let live = try String(contentsOf: paths.noteURL, encoding: .utf8)
    XCTAssertTrue(live.contains("** Notes"))
    XCTAssertTrue(live.contains(":transcription_status: recording"))
    // The live note is never written over an existing file.
    XCTAssertThrowsError(try MeetingArtifactWriter.writeLiveMeetingNote(paths: paths, corpusRoot: root))

    // The user jots notes and adds a property while recording.
    let edited = live
      .replacingOccurrences(of: "** Notes\n", with: "** Notes\n- Ask about annual pricing\n- Pasted from chat: ship Friday\n")
      .replacingOccurrences(of: ":source: org2-workspace\n", with: ":source: org2-workspace\n:CUSTOM: kept\n")
    try edited.write(to: paths.noteURL, atomically: true, encoding: .utf8)

    _ = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: 42,
      transcript: MeetingTranscriptResult(
        text: "We agreed on annual pricing.",
        status: .complete,
        engine: "whisper.cpp"
      )
    )

    let finished = try String(contentsOf: paths.noteURL, encoding: .utf8)
    XCTAssertTrue(finished.contains("** Notes\n- Ask about annual pricing\n- Pasted from chat: ship Friday\n"))
    XCTAssertTrue(finished.contains(":CUSTOM: kept"))
    XCTAssertTrue(finished.contains(":ID: \(paths.meetingID)"))
    XCTAssertTrue(finished.contains(":transcription_status: complete"))
    XCTAssertTrue(finished.contains(":duration_seconds: 42.0"))
    XCTAssertFalse(finished.contains(":transcription_status: recording"))
    XCTAssertFalse(finished.contains("Recording in progress"))
    XCTAssertTrue(finished.contains("We agreed on annual pricing."))
    XCTAssertEqual(finished.components(separatedBy: ":transcription_status:").count, 2)
    XCTAssertEqual(finished.components(separatedBy: "** Transcript").count, 2)
    XCTAssertEqual(finished.components(separatedBy: "** Summary").count, 2)
  }

  func testMeetingNoteMergeKeepsSectionsAfterTheTranscriptAndUserHeadings() {
    let existing = """
    #+TITLE: Meeting: Sync

    * Meeting: Sync
    :PROPERTIES:
    :ID: abc
    :transcription_status: recording
    :transcription_error: stale
    :END:

    ** Notes
    *** Transcript
    My own subheading stays.

    ** Transcript
    [[file:meetings/x.transcript.org][Open transcript artifact]]

    - Recording in progress.

    ** Follow-ups
    - Email Sam
    """
    let generated = """
    #+TITLE: Meeting: Sync

    * Meeting: Sync
    :PROPERTIES:
    :ID: abc
    :transcription_status: complete
    :END:

    ** Transcript
    [[file:meetings/x.transcript.org][Open transcript artifact]]

    #+begin_quote
    ** not a heading
    #+end_quote
    """
    let merged = MeetingArtifactWriter.mergeMeetingNote(existing: existing, generated: generated)
    XCTAssertTrue(merged.contains("*** Transcript\nMy own subheading stays."))
    XCTAssertTrue(merged.contains("#+begin_quote\n** not a heading\n#+end_quote\n\n** Follow-ups\n- Email Sam\n"))
    XCTAssertFalse(merged.contains("Recording in progress"))
    XCTAssertFalse(merged.contains("transcription_error"))
    XCTAssertTrue(merged.contains(":transcription_status: complete"))
  }

  func testScansLiveNoteOfInterruptedRecordingAsRecoverable() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-live-note-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "ACME kickoff",
      recordedAt: Date()
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)
    _ = try MeetingArtifactWriter.writeLiveMeetingNote(paths: paths, corpusRoot: root)

    let recoverable = try WorkspaceStore.scanRecoverableMeetingRecordings(corpusRoot: root)

    XCTAssertEqual(recoverable.count, 1)
    XCTAssertEqual(recoverable.first?.paths.meetingID, paths.meetingID)
    XCTAssertEqual(recoverable.first?.paths.title, "ACME kickoff")
    XCTAssertEqual(recoverable.first?.paths.noteURL.standardizedFileURL, paths.noteURL.standardizedFileURL)
  }

  func testMeetingRecorderMeterNormalizesAudioPower() {
    XCTAssertEqual(MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: -80), 0)
    XCTAssertEqual(MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: 0), 1)
    XCTAssertEqual(MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: 20), 1)
    XCTAssertEqual(
      MeetingAudioRecorder.normalizedMeterLevel(fromDecibels: -30),
      0.5,
      accuracy: 0.001
    )
  }

  func testMeetingMeterPublishingSkipsSmallLevelChanges() {
    XCTAssertFalse(WorkspaceStore.shouldPublishMeetingMeterLevelChange(current: 0.50, next: 0.51))
    XCTAssertTrue(WorkspaceStore.shouldPublishMeetingMeterLevelChange(current: 0.50, next: 0.54))
    XCTAssertTrue(WorkspaceStore.shouldPublishMeetingMeterLevelChange(current: 0, next: 0.01))
    XCTAssertTrue(WorkspaceStore.shouldPublishMeetingMeterLevelChange(current: 0.94, next: 0.96))
  }

  @MainActor
  func testMeetingMeterPublishesOneIsolatedFrameWithoutInvalidatingWorkspaceStore() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let workspaceChanged = ThreadSafeTestFlag()
    var meterUpdates = 0
    withObservationTracking {
      _ = store.selectedSurface
    } onChange: {
      _ = workspaceChanged.setIfUnset()
    }
    let meterCancellable = store.meetingInputMeterState.objectWillChange.sink { meterUpdates += 1 }

    store.meetingInputMeterState.publish(
      primary: MeetingInputMeterSnapshot(
        averageLevel: 0.42,
        peakLevel: 0.74,
        averagePowerDecibels: -24,
        peakPowerDecibels: -8
      ),
      secondary: MeetingInputMeterSnapshot(
        averageLevel: 0.31,
        peakLevel: 0.65,
        averagePowerDecibels: -31,
        peakPowerDecibels: -12
      )
    )

    XCTAssertFalse(workspaceChanged.value)
    XCTAssertEqual(meterUpdates, 1)
    XCTAssertEqual(store.meetingInputMeterState.levels.averageLevel, 0.42)
    XCTAssertEqual(store.meetingInputMeterState.levels.peakLevel, 0.74)
    XCTAssertEqual(store.meetingInputMeterState.levels.secondaryAverageLevel, 0.31)
    XCTAssertEqual(store.meetingInputMeterState.levels.secondaryPeakLevel, 0.65)

    withExtendedLifetime(meterCancellable) {}
  }

  @MainActor
  func testMeetingTranscriptionProgressDoesNotInvalidateWorkspaceStore() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let workspaceChanged = ThreadSafeTestFlag()
    var progressUpdates = 0
    withObservationTracking {
      _ = store.selectedSurface
    } onChange: {
      _ = workspaceChanged.setIfUnset()
    }
    let progressCancellable = store.meetingTranscriptionProgressState.objectWillChange.sink {
      progressUpdates += 1
    }

    store.meetingTranscriptionProgressState.publish(progress: 0.42, elapsedText: "12s")

    XCTAssertFalse(workspaceChanged.value)
    XCTAssertEqual(progressUpdates, 2)
    XCTAssertEqual(store.meetingTranscriptionProgress, 0.42)
    XCTAssertEqual(store.meetingTranscriptionElapsedText, "12s")

    withExtendedLifetime(progressCancellable) {}
  }

  func testMeetingCaptureSourceDisclosesSystemAudioPermission() {
    let source = WorkspaceStore.meetingCaptureSourceSummary.lowercased()
    XCTAssertTrue(source.contains("microphone"))
    XCTAssertTrue(source.contains("system"))
    XCTAssertTrue(source.contains("screencapturekit"))
    XCTAssertTrue(source.contains("audio only"))
  }

  func testLocalWhisperInstallationStatusDetectsFastPath() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-whisper-status-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let model = root.appendingPathComponent("ggml-base.en.bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "#!/bin/sh\nexit 0\n".write(to: bin.appendingPathComponent("whisper-cli"), atomically: true, encoding: .utf8)
    try Data("fake model".utf8).write(to: model)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("whisper-cli").path)

    let status = LocalWhisperTranscriber.installationStatus(configuration: LocalWhisperConfiguration(environment: [
      "PATH": bin.path,
      "ORG2_WORKSPACE_WHISPER_MODEL": model.path
    ]))

    XCTAssertTrue(status.isWhisperCppReady)
    XCTAssertEqual(status.backendDescription, "whisper.cpp")
    XCTAssertTrue(status.whisperCppExecutablePath?.hasSuffix("whisper-cli") == true)
    XCTAssertEqual(status.whisperCppModelPath, model.path)
    XCTAssertEqual(status.statusLabel, "Fast local transcription ready")
  }

  func testLocalWhisperInstallationStatusCanSkipExecutableProbeForImmediateUIState() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-whisper-quick-status-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let executable = bin.appendingPathComponent("whisper-cli")
    let marker = root.appendingPathComponent("launched")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "#!/bin/sh\ntouch '\(marker.path)'\nexit 0\n".write(
      to: executable,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    defer { try? FileManager.default.removeItem(at: root) }

    let status = LocalWhisperTranscriber.installationStatus(
      configuration: LocalWhisperConfiguration(environment: ["PATH": bin.path]),
      verifyExecutableLaunch: false
    )

    XCTAssertEqual(status.whisperCppExecutablePath, executable.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testLocalWhisperDefaultThreadCountLeavesCapacityForForegroundWork() {
    XCTAssertEqual(LocalWhisperConfiguration.defaultThreadCount(activeProcessorCount: 1), 1)
    XCTAssertEqual(LocalWhisperConfiguration.defaultThreadCount(activeProcessorCount: 2), 1)
    XCTAssertEqual(LocalWhisperConfiguration.defaultThreadCount(activeProcessorCount: 8), 4)
    XCTAssertEqual(LocalWhisperConfiguration.defaultThreadCount(activeProcessorCount: 16), 4)

    let configured = LocalWhisperConfiguration(
      environment: ["ORG2_WORKSPACE_WHISPER_THREADS": "6"],
      bundleResourceURL: nil
    )
    XCTAssertEqual(configured.requestedThreadCount, 6)
  }

  func testLocalWhisperInstallationStatusPrefersBundledRuntimeWithoutEnvironment() throws {
    let resources = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-bundled-whisper-\(UUID().uuidString)", isDirectory: true)
    let bin = resources.appendingPathComponent("Whisper/bin", isDirectory: true)
    let model = resources.appendingPathComponent("Whisper/models/ggml-base.en.bin")
    let executable = bin.appendingPathComponent("whisper-cli")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: model.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try Data("fake bundled model".utf8).write(to: model)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    defer { try? FileManager.default.removeItem(at: resources) }

    let status = LocalWhisperTranscriber.installationStatus(configuration: LocalWhisperConfiguration(
      environment: [:],
      bundleResourceURL: resources
    ))

    XCTAssertTrue(status.isWhisperCppReady)
    XCTAssertEqual(status.backendDescription, "whisper.cpp")
    XCTAssertEqual(status.whisperCppExecutablePath, executable.path)
    XCTAssertEqual(status.whisperCppModelPath, model.path)
  }

  func testLocalWhisperStatusSkipsBundledExecutableThatCannotLaunch() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-whisper-launch-check-\(UUID().uuidString)", isDirectory: true)
    let resourcesBin = root.appendingPathComponent("resources/Whisper/bin", isDirectory: true)
    let resourcesModel = root.appendingPathComponent("resources/Whisper/models/ggml-base.en.bin")
    let pathBin = root.appendingPathComponent("path-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: resourcesBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: resourcesModel.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pathBin, withIntermediateDirectories: true)
    let broken = resourcesBin.appendingPathComponent("whisper-cli")
    let working = pathBin.appendingPathComponent("whisper-cli")
    try "#!/bin/sh\necho missing-library >&2\nexit 134\n".write(to: broken, atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: working, atomically: true, encoding: .utf8)
    try Data("fake model".utf8).write(to: resourcesModel)
    for executable in [broken, working] {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let status = LocalWhisperTranscriber.installationStatus(
      configuration: LocalWhisperConfiguration(
        environment: ["PATH": pathBin.path],
        bundleResourceURL: root.appendingPathComponent("resources")
      )
    )

    XCTAssertTrue(status.isWhisperCppReady)
    XCTAssertEqual(status.whisperCppExecutablePath, working.path)
    XCTAssertNotNil(status.whisperCppLaunchError)
  }

  func testFluidVoiceRejectsNonLoopbackEndpoint() {
    XCTAssertThrowsError(try FluidVoiceTranscriber(endpoint: "http://example.com")) { error in
      XCTAssertEqual(
        error.localizedDescription,
        FluidVoiceTranscriberError.nonLocalEndpoint.localizedDescription
      )
    }
  }

  func testFluidVoiceMergesOverlappingChunkText() {
    XCTAssertEqual(
      FluidVoiceTranscriber.mergedTranscriptSegments([
        "We should ship this on Friday.",
        "this on Friday. Then notify Gabi."
      ]),
      "We should ship this on Friday. Then notify Gabi."
    )
  }

  func testFluidVoiceChunksLongAudioAndRemovesTemporaryFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-fluid-voice-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audioURL = root.appendingPathComponent("meeting.m4a")
    try writeSilentM4A(to: audioURL)
    defer {
      FluidVoiceTestURLProtocol.reset()
      try? FileManager.default.removeItem(at: root)
    }

    let requestedPaths = ThreadSafeStringRecorder()
    FluidVoiceTestURLProtocol.setRequestHandler { request in
      let body: Data
      if let requestBody = request.httpBody {
        body = requestBody
      } else {
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var collected = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while true {
          let count = stream.read(buffer, maxLength: 4_096)
          guard count >= 0 else { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
          if count == 0 { break }
          collected.append(buffer, count: count)
        }
        body = collected
      }
      let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
      requestedPaths.append(try XCTUnwrap(payload["path"]))
      let response = try XCTUnwrap(HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      ))
      let data = try JSONSerialization.data(withJSONObject: [
        "text": "hello meeting",
        "confidence": 0.9,
        "sampleCount": 640,
        "provider": "Parakeet"
      ])
      return (response, data)
    }
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [FluidVoiceTestURLProtocol.self]
    let session = URLSession(configuration: sessionConfiguration)
    let transcriber = try FluidVoiceTranscriber(
      session: session,
      maximumChunkDuration: 0.04,
      chunkOverlap: 0.005
    )

    let result = try await transcriber.transcribe(audioURL: audioURL)

    XCTAssertEqual(result.text, "hello meeting")
    XCTAssertTrue(result.engine.contains("Fluid Voice (Parakeet"))
    XCTAssertGreaterThan(requestedPaths.values.count, 1)
    XCTAssertTrue(requestedPaths.values.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
  }

  @MainActor
  func testMeetingTranscriptionProviderSettingsPersist() throws {
    let suiteName = "org2-transcription-settings-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let store = WorkspaceStore(cli: cli, defaults: defaults)
    store.meetingTranscriptionProvider = .fluidVoice
    store.fluidVoiceEndpointText = "http://localhost:47733"
    store.whisperModelPathText = "/tmp/custom-model.bin"
    store.transcriptionLanguageText = "es"

    let restored = WorkspaceStore(cli: cli, defaults: defaults)

    XCTAssertEqual(restored.meetingTranscriptionProvider, .fluidVoice)
    XCTAssertEqual(restored.fluidVoiceEndpointText, "http://localhost:47733")
    XCTAssertEqual(restored.whisperModelPathText, "/tmp/custom-model.bin")
    XCTAssertEqual(restored.transcriptionLanguageText, "es")
  }

  @MainActor
  func testConnectingFluidVoicePublishesReadyStatusAndClearsBusyState() async throws {
    let suiteName = "org2-fluid-voice-connection-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cli = try Org2CLI(repoRoot: Org2CLI.defaultRepoRoot())
    let store = WorkspaceStore(cli: cli, defaults: defaults)
    store.fluidVoiceConnectionOperationForTesting = {
      "Fluid Voice Local API is ready."
    }

    await store.connectFluidVoice()

    XCTAssertEqual(store.audioSettingsStatusText, "Fluid Voice Local API is ready.")
    XCTAssertFalse(store.isConnectingFluidVoice)
  }

  func testTranscriptionStatusUsesBuiltInMacOSFallbackWithoutWhisper() {
    let status = LocalWhisperInstallationStatus(
      backendDescription: "macOS Speech",
      whisperCppExecutablePath: nil,
      whisperCppModelPath: nil,
      openAIWhisperExecutablePath: nil,
      overrideCommand: nil
    )

    XCTAssertTrue(status.isAnyLocalTranscriberAvailable)
    XCTAssertEqual(status.statusLabel, "Built-in macOS transcription ready")
    XCTAssertTrue(status.detailText.contains("out of the box"))
  }

  func testWhisperCppConvertsM4AAudioToWAVBeforeTranscribing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-whisper-m4a-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let model = root.appendingPathComponent("ggml-base.en.bin")
    let capturedInput = root.appendingPathComponent("captured-input.txt")
    let sourceAudio = root.appendingPathComponent("system-audio.m4a")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("fake model".utf8).write(to: model)
    try writeSilentM4A(to: sourceAudio)

    let whisperCLI = bin.appendingPathComponent("whisper-cli")
    try """
    #!/bin/sh
    input=""
    output=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -f)
          shift
          input="$1"
          ;;
        -of)
          shift
          output="$1"
          ;;
      esac
      shift
    done
    printf "%s" "$input" > '\(capturedInput.path.replacingOccurrences(of: "'", with: "'\\''"))'
    printf "system transcript" > "${output}.txt"
    exit 0
    """.write(to: whisperCLI, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisperCLI.path)

    let transcriber = LocalWhisperTranscriber(configuration: LocalWhisperConfiguration(environment: [
      "PATH": bin.path,
      "ORG2_WORKSPACE_WHISPER_MODEL": model.path
    ]))
    let result = try await transcriber.transcribe(audioURL: sourceAudio)

    XCTAssertEqual(result.text, "system transcript")
    XCTAssertEqual(result.engine, "whisper.cpp")
    let inputPath = try String(contentsOf: capturedInput, encoding: .utf8)
    XCTAssertTrue(inputPath.hasSuffix(".wav"))
    XCTAssertNotEqual(inputPath, sourceAudio.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: inputPath))
  }

  func testWorkspaceRuntimeIdentityLabelsUnbundledExecutables() {
    let identity = WorkspaceRuntimeIdentity(
      executablePath: "/tmp/Org2Workspace",
      bundlePath: "/tmp/Org2Workspace",
      bundleIdentifier: nil,
      isAppBundle: false
    )

    XCTAssertEqual(identity.audioPermissionStatusLabel, "Debug executable")
    XCTAssertTrue(identity.audioPermissionDetailText.contains("SwiftPM debug executable"))
  }

  func testMeetingTranscriptCombinesMicrophoneAndSystemAudioSections() {
    let transcript = MeetingTranscriptResult.combined(
      microphone: MeetingTranscriptResult(
        text: "I can ship that today.",
        status: .complete,
        engine: "whisper.cpp"
      ),
      systemAudio: MeetingTranscriptResult(
        text: "The customer asked for Friday.",
        status: .complete,
        engine: "whisper.cpp"
      )
    )

    XCTAssertEqual(transcript.status, .complete)
    XCTAssertTrue(transcript.text.contains("** Microphone"))
    XCTAssertTrue(transcript.text.contains("I can ship that today."))
    XCTAssertTrue(transcript.text.contains("** System Audio"))
    XCTAssertTrue(transcript.text.contains("The customer asked for Friday."))
  }

  func testSystemAudioCaptureStateRetainsOriginalFailureAndStaysStopped() {
    var state = MeetingSystemAudioCaptureState()
    state.didStart()
    XCTAssertTrue(state.isRunning)

    state.didStopUnexpectedly("ScreenCaptureKit lost the audio stream.")
    state.didStopUnexpectedly("Failed to stop a stream that is already stopped or does not exist.")
    state.didStart()

    XCTAssertFalse(state.isRunning)
    XCTAssertEqual(
      state.resolvedFailure(explicitStopFailure: "Could not stop system audio capture."),
      "ScreenCaptureKit lost the audio stream."
    )
  }

  func testSystemAudioCaptureStateCanRecoverWithoutLosingInterruption() {
    var state = MeetingSystemAudioCaptureState()
    state.didStart()
    state.didStopUnexpectedly("ScreenCaptureKit lost the audio stream.")

    XCTAssertTrue(state.needsRecovery)
    XCTAssertTrue(state.didRecover(afterInterruptionCount: state.interruptionCount))

    XCTAssertTrue(state.isRunning)
    XCTAssertFalse(state.needsRecovery)
    XCTAssertEqual(
      state.resolvedFailure(explicitStopFailure: nil),
      "ScreenCaptureKit lost the audio stream."
    )

    state.didStopNormally()
    XCTAssertFalse(state.needsRecovery)
  }

  func testSystemAudioCaptureStateRejectsAReplacementThatAlsoFailed() {
    var state = MeetingSystemAudioCaptureState()
    state.didStart()
    state.didStopUnexpectedly("The original stream stopped.")
    let interruptionCountBeforeReplacement = state.interruptionCount

    state.didStopUnexpectedly("The replacement stream stopped during startup.")

    XCTAssertFalse(state.didRecover(afterInterruptionCount: interruptionCountBeforeReplacement))
    XCTAssertTrue(state.needsRecovery)
    XCTAssertEqual(state.firstFailureDescription, "The original stream stopped.")
  }

  func testSystemAudioStartRetrySkipsPermissionFailures() {
    XCTAssertFalse(WorkspaceStore.shouldRetryMeetingSystemAudioStart(
      after: "The user declined TCCs for application, window, display capture"
    ))
    XCTAssertFalse(WorkspaceStore.shouldRetryMeetingSystemAudioStart(
      after: "Screen capture permission is not authorized"
    ))
    XCTAssertTrue(WorkspaceStore.shouldRetryMeetingSystemAudioStart(
      after: "ScreenCaptureKit connection was interrupted"
    ))
  }

  func testMeetingTranscriptRetainsCaptureFailureAlongsidePartialSystemAudio() {
    let transcript = MeetingTranscriptResult.combined(
      microphone: MeetingTranscriptResult(
        text: "The meeting continued.",
        status: .complete,
        engine: "whisper.cpp"
      ),
      systemAudio: MeetingTranscriptResult(
        text: "Only the opening was captured.",
        status: .complete,
        engine: "whisper.cpp"
      ),
      systemAudioCaptureError: "ScreenCaptureKit lost the audio stream."
    )

    XCTAssertEqual(
      transcript.errorMessage,
      "system capture: ScreenCaptureKit lost the audio stream."
    )
  }

  func testFileHasContentDistinguishesEmptyAndPartialMeetingArtifacts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-system-audio-artifact-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appendingPathComponent("empty.m4a")
    let partial = root.appendingPathComponent("partial.m4a")
    try Data().write(to: empty)
    try Data("partial media".utf8).write(to: partial)

    XCTAssertFalse(WorkspaceStore.fileHasContent(root.appendingPathComponent("missing.m4a")))
    XCTAssertFalse(WorkspaceStore.fileHasContent(empty))
    XCTAssertTrue(WorkspaceStore.fileHasContent(partial))
  }

  @MainActor
  func testDeleteMeetingRemovesNoteAndArtifacts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-delete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordedAt = ISO8601DateFormatter().date(from: "2026-06-11T21:00:00Z")!
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Delete sync",
      recordedAt: recordedAt
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)
    try Data("fake system audio".utf8).write(to: paths.systemAudioURL)
    let bundle = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: nil,
      transcript: MeetingTranscriptResult(text: "Delete me.", status: .complete, engine: "whisper.cpp"),
      systemAudioURL: paths.systemAudioURL
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshMeetings()
    let meeting = try XCTUnwrap(store.meetings.first)
    store.selectMeeting(meeting)

    await store.deleteMeeting(meeting)

    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.noteURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.audioURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.systemAudioURL?.path ?? ""))
    XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.transcriptURL.path))
    XCTAssertTrue(store.meetings.isEmpty)
    XCTAssertNil(store.selectedLocation)
  }

  @MainActor
  func testWorkspaceScansMeetingArtifacts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordedAt = ISO8601DateFormatter().date(from: "2026-06-11T21:00:00Z")!
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Planning sync",
      recordedAt: recordedAt
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)
    _ = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: nil,
      transcript: MeetingTranscriptResult(
        text: "Action item: ship the meeting recorder.",
        status: .complete,
        engine: "whisper.cpp"
      )
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshMeetings()

    XCTAssertEqual(store.meetings.count, 1)
    XCTAssertEqual(store.meetings[0].title, "Planning sync")
    XCTAssertEqual(store.meetings[0].transcriptionStatus, "complete")
    XCTAssertTrue(store.meetings[0].audioArtifact?.hasPrefix("meetings/") == true)
    XCTAssertNil(store.meetings[0].systemAudioArtifact)
    XCTAssertTrue(store.meetings[0].transcriptArtifact?.hasSuffix(".transcript.org") == true)
  }

  func testScansRecoverableMeetingAudioButExcludesActiveRecording() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-recovery-\(UUID().uuidString)", isDirectory: true)
    let meetings = root.appendingPathComponent("meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)

    let interruptedAudio = meetings.appendingPathComponent("2026-06-15-093644-alexandria.wav")
    let interruptedSystemAudio = meetings.appendingPathComponent("2026-06-15-093644-alexandria.system.m4a")
    let completedAudio = meetings.appendingPathComponent("2026-06-15-100000-finished.wav")
    let completedNote = meetings.appendingPathComponent("2026-06-15-100000-finished.org2")
    try Data("fake microphone audio".utf8).write(to: interruptedAudio)
    try Data("fake system audio".utf8).write(to: interruptedSystemAudio)
    try Data("fake completed audio".utf8).write(to: completedAudio)
    try "* Meeting: Finished\n".write(to: completedNote, atomically: true, encoding: .utf8)

    let recoverable = try WorkspaceStore.scanRecoverableMeetingRecordings(corpusRoot: root)

    XCTAssertEqual(recoverable.count, 1)
    XCTAssertEqual(recoverable[0].paths.title, "Alexandria")
    XCTAssertEqual(recoverable[0].paths.baseName, "2026-06-15-093644-alexandria")
    XCTAssertEqual(recoverable[0].paths.audioURL.standardizedFileURL, interruptedAudio.standardizedFileURL)
    XCTAssertEqual(recoverable[0].systemAudioURL?.standardizedFileURL, interruptedSystemAudio.standardizedFileURL)
    XCTAssertEqual(recoverable[0].captureSources, "recovered_audio, system_audio")
    XCTAssertFalse(WorkspaceStore.shouldRecoverMeetingRecording(
      recoverable[0].paths,
      activeRecordingPaths: recoverable[0].paths
    ))
    XCTAssertTrue(WorkspaceStore.shouldRecoverMeetingRecording(
      recoverable[0].paths,
      activeRecordingPaths: nil
    ))
  }

  @MainActor
  func testRefreshMeetingsClearsStaleTranscribingStateForCompletedArtifact() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-stale-processing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let recordedAt = ISO8601DateFormatter().date(from: "2026-06-11T21:00:00Z")!
    let paths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Company Meeting",
      recordedAt: recordedAt
    )
    try Data("fake audio".utf8).write(to: paths.audioURL)
    _ = try MeetingArtifactWriter.writeArtifacts(
      paths: paths,
      corpusRoot: root,
      duration: nil,
      transcript: MeetingTranscriptResult(
        text: "Transcript is complete.",
        status: .complete,
        engine: "whisper.cpp"
      )
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedSurface = .meetings
    store.isProcessingMeeting = true
    store.meetingStatusText = "Transcribing Company Meeting locally..."

    await store.refreshMeetings()

    XCTAssertFalse(store.isProcessingMeeting)
    XCTAssertFalse(store.meetingStatusText.hasPrefix("Transcribing "))
    XCTAssertEqual(store.meetings.first?.transcriptionStatus, "complete")
  }

  @MainActor
  func testRefreshMeetingsKeepsDuplicateTitleProcessingScopedToArtifact() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-meeting-duplicate-processing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let olderDate = ISO8601DateFormatter().date(from: "2026-07-03T15:02:04Z")!
    let activeDate = ISO8601DateFormatter().date(from: "2026-07-06T14:29:55Z")!
    let olderPaths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Dev Standup",
      recordedAt: olderDate
    )
    let activePaths = try MeetingArtifactWriter.preparePaths(
      corpusRoot: root,
      title: "Dev Standup",
      recordedAt: activeDate
    )
    try Data("older audio".utf8).write(to: olderPaths.audioURL)
    _ = try MeetingArtifactWriter.writeArtifacts(
      paths: olderPaths,
      corpusRoot: root,
      duration: nil,
      transcript: MeetingTranscriptResult(
        text: "Older transcript is complete.",
        status: .complete,
        engine: "whisper.cpp"
      )
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedSurface = .meetings
    store.beginMeetingProcessingForTesting(
      paths: activePaths,
      status: "Transcribing Dev Standup locally..."
    )

    await store.refreshMeetings()

    let olderMeeting = try XCTUnwrap(store.meetings.first)
    XCTAssertEqual(olderMeeting.title, "Dev Standup")
    XCTAssertEqual(olderMeeting.transcriptionStatus, "complete")
    XCTAssertTrue(store.isProcessingMeeting)
    XCTAssertFalse(store.isMeetingProcessing(olderMeeting))
    XCTAssertEqual(store.pendingMeetingProcessingItems.map(\.id), [activePaths.noteURL.standardizedFileURL.path])
    XCTAssertEqual(store.pendingMeetingProcessingItems.map(\.title), ["Dev Standup"])
  }

  func testAIChatComposerSizingGrowsAndCaps() {
    let emptyHeight = AIChatComposerSizing.height(for: "", compact: false)
    let shortHeight = AIChatComposerSizing.height(for: "hello", compact: false)
    let multilineHeight = AIChatComposerSizing.height(for: "one\ntwo\nthree\nfour", compact: false)
    let longHeight = AIChatComposerSizing.height(
      for: String(repeating: "long message line\n", count: 80),
      compact: false
    )
    let compactLongHeight = AIChatComposerSizing.height(
      for: String(repeating: "long message line\n", count: 80),
      compact: true
    )

    XCTAssertEqual(emptyHeight, shortHeight)
    XCTAssertGreaterThan(multilineHeight, shortHeight)
    XCTAssertEqual(longHeight, 190)
    XCTAssertEqual(compactLongHeight, 150)
  }

  func testComposerReturnSteersRunningTurnCommandReturnQueuesAndShiftReturnAddsNewline() {
    XCTAssertTrue(AIChatComposerKeyCommand.isSendCommand(keyCode: 36, modifiers: []))
    XCTAssertTrue(AIChatComposerKeyCommand.isSendCommand(keyCode: 76, modifiers: []))
    XCTAssertFalse(AIChatComposerKeyCommand.isSendCommand(keyCode: 36, modifiers: [.command]))
    XCTAssertFalse(AIChatComposerKeyCommand.isSendCommand(keyCode: 36, modifiers: [.command, .shift]))
    XCTAssertFalse(AIChatComposerKeyCommand.isSendCommand(keyCode: 49, modifiers: [.command]))

    XCTAssertTrue(AIChatComposerKeyCommand.isQueueCommand(keyCode: 36, modifiers: [.command]))
    XCTAssertTrue(AIChatComposerKeyCommand.isQueueCommand(keyCode: 76, modifiers: [.command]))
    XCTAssertTrue(AIChatComposerKeyCommand.isQueueCommand(keyCode: 36, modifiers: [.command, .shift]))
    XCTAssertTrue(AIChatComposerKeyCommand.isQueueCommand(keyCode: 76, modifiers: [.command, .shift]))
    XCTAssertFalse(AIChatComposerKeyCommand.isQueueCommand(keyCode: 36, modifiers: []))
    XCTAssertFalse(AIChatComposerKeyCommand.isQueueCommand(keyCode: 36, modifiers: [.shift]))

    XCTAssertTrue(AIChatComposerKeyCommand.isNewlineCommand(keyCode: 36, modifiers: [.shift]))
    XCTAssertTrue(AIChatComposerKeyCommand.isNewlineCommand(keyCode: 76, modifiers: [.shift]))
    XCTAssertFalse(AIChatComposerKeyCommand.isNewlineCommand(keyCode: 36, modifiers: []))
    XCTAssertFalse(AIChatComposerKeyCommand.isNewlineCommand(keyCode: 36, modifiers: [.command]))
    XCTAssertFalse(AIChatComposerKeyCommand.isNewlineCommand(keyCode: 36, modifiers: [.command, .shift]))

    XCTAssertEqual(
      AIChatComposerKeyCommand.resolvedDelivery(requested: .steer, isRunning: true),
      .steer
    )
    XCTAssertEqual(
      AIChatComposerKeyCommand.resolvedDelivery(requested: .steer, isRunning: false),
      .automatic
    )
    // Steering is the default while a turn runs; Command-Return queues.
    XCTAssertEqual(
      AIChatComposerKeyCommand.resolvedDelivery(requested: .automatic, isRunning: true),
      .steer
    )
    XCTAssertEqual(
      AIChatComposerKeyCommand.resolvedDelivery(requested: .followUp, isRunning: true),
      .followUp
    )
    XCTAssertEqual(
      AIChatComposerKeyCommand.resolvedDelivery(requested: .followUp, isRunning: false),
      .automatic
    )
    XCTAssertEqual(
      AIChatComposerKeyCommand.resolvedDelivery(requested: .automatic, isRunning: true, isSlashCommand: true),
      .automatic
    )
  }

  func testSharedRoomSteerReachesTheRunningAgentWithoutAMention() {
    // An un-mentioned steer goes to the running agent, not the room default.
    XCTAssertEqual(
      WorkspaceStore.sharedRoomSteerDestinationID(explicitDestinationIDs: [], runningDestinationID: "codex"),
      "codex"
    )
    XCTAssertEqual(
      WorkspaceStore.sharedRoomSteerDestinationID(explicitDestinationIDs: ["codex"], runningDestinationID: "codex"),
      "codex"
    )
    XCTAssertNil(
      WorkspaceStore.sharedRoomSteerDestinationID(explicitDestinationIDs: ["codex", "opencode"], runningDestinationID: "codex")
    )
    XCTAssertNil(
      WorkspaceStore.sharedRoomSteerDestinationID(explicitDestinationIDs: [], runningDestinationID: nil)
    )
  }

  func testAIChatComposerSuggestionKeyboardCommands() {
    XCTAssertEqual(AIChatComposerKeyCommand.suggestionCommand(keyCode: 36, modifiers: []), .complete)
    XCTAssertEqual(AIChatComposerKeyCommand.suggestionCommand(keyCode: 48, modifiers: []), .complete)
    XCTAssertEqual(AIChatComposerKeyCommand.suggestionCommand(keyCode: 76, modifiers: []), .complete)
    XCTAssertEqual(AIChatComposerKeyCommand.suggestionCommand(keyCode: 125, modifiers: []), .move(1))
    XCTAssertEqual(AIChatComposerKeyCommand.suggestionCommand(keyCode: 126, modifiers: []), .move(-1))
    XCTAssertNil(AIChatComposerKeyCommand.suggestionCommand(keyCode: 48, modifiers: [.command]))
    XCTAssertNil(AIChatComposerKeyCommand.suggestionCommand(keyCode: 125, modifiers: [.shift]))
    XCTAssertNil(AIChatComposerKeyCommand.suggestionCommand(keyCode: 49, modifiers: []))
  }

  func testScheduledSourceSyncRunsOnlyOnTheCorpusSchedulerOwner() {
    // org2.json/celorga.json `automationHostRef` owns scheduled source syncs.
    XCTAssertTrue(WorkspaceStore.ownsCorpusSchedules(ownerHostRef: nil, hostRef: "desktop"))
    XCTAssertTrue(WorkspaceStore.ownsCorpusSchedules(ownerHostRef: "desktop", hostRef: "desktop"))
    XCTAssertFalse(WorkspaceStore.ownsCorpusSchedules(ownerHostRef: "press-trial", hostRef: "desktop"))
    XCTAssertTrue(WorkspaceStore.ownsCorpusSchedules(ownerHostRef: "press-trial", hostRef: "press-trial"))
    XCTAssertFalse(WorkspaceStore.ownsCorpusSchedules(ownerHostRef: nil, hostRef: "press-trial"))
  }

  func testAIChatComposerCompletionMovesInsertionPointToEnd() {
    XCTAssertEqual(
      AIChatComposerSelection.updatedRange(
        previous: NSRange(location: 2, length: 0),
        textLength: 18,
        movesToEnd: true
      ),
      NSRange(location: 18, length: 0)
    )
    XCTAssertEqual(
      AIChatComposerSelection.updatedRange(
        previous: NSRange(location: 5, length: 2),
        textLength: 18,
        movesToEnd: false
      ),
      NSRange(location: 5, length: 2)
    )
  }

  func testAIChatComposerDropPrefersFileURLsOverTextInsertion() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("org2-drop-test-\(UUID().uuidString)"))
    pasteboard.clearContents()
    let first = URL(fileURLWithPath: "/tmp/first note.txt")
    let second = URL(fileURLWithPath: "/tmp/image.png")
    XCTAssertTrue(pasteboard.writeObjects([first as NSURL, second as NSURL]))

    XCTAssertEqual(
      AIChatComposerDrop.payload(from: pasteboard),
      .fileURLs([first, second])
    )
  }

  func testAIChatComposerDropAcceptsRawImageData() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("org2-image-drop-test-\(UUID().uuidString)"))
    pasteboard.clearContents()
    let png = Data([0x89, 0x50, 0x4e, 0x47])
    pasteboard.setData(png, forType: .png)

    XCTAssertEqual(
      AIChatComposerDrop.payload(from: pasteboard),
      .image(data: png, fileName: "Dropped Image.png", mimeType: "image/png")
    )
  }

  func testAIChatSlashCommandSelectionWrapsAndClamps() {
    let suggestions = AIChatSlashCommands.suggestions(for: "/")
    XCTAssertGreaterThan(suggestions.count, 2)
    XCTAssertEqual(AIChatSlashCommandSelection.selectedCommand(in: suggestions, index: 0), suggestions[0])
    XCTAssertEqual(AIChatSlashCommandSelection.selectedCommand(in: suggestions, index: 100), suggestions.last)
    XCTAssertNil(AIChatSlashCommandSelection.selectedCommand(in: [], index: 0))

    XCTAssertEqual(AIChatSlashCommandSelection.movedIndex(0, by: 1, count: 3), 1)
    XCTAssertEqual(AIChatSlashCommandSelection.movedIndex(2, by: 1, count: 3), 0)
    XCTAssertEqual(AIChatSlashCommandSelection.movedIndex(0, by: -1, count: 3), 2)
    XCTAssertEqual(AIChatSlashCommandSelection.movedIndex(4, by: 1, count: 3), 2)
    XCTAssertEqual(AIChatSlashCommandSelection.movedIndex(4, by: 1, count: 0), 0)
  }

  func testAIChatContextPresentationSeparatesMultipleContextPillsFromUserText() {
    let raw = """
    Use selected block “Launch risks” at /remote/org2/projects.org2:12-18 as context.

    Use selected page “Product plan” at /remote/org2/Product at risk.org2:1 as context.

    What should change?
    """
    let presentation = AIChatContextPresentation(raw)

    XCTAssertEqual(presentation.contexts.map(\.title), ["Launch risks", "Product plan"])
    XCTAssertEqual(presentation.contexts.map(\.kind), ["selected block", "selected page"])
    XCTAssertEqual(presentation.contexts[1].reference, "/remote/org2/Product at risk.org2:1")
    XCTAssertEqual(presentation.userText, "What should change?")
    XCTAssertEqual(presentation.clipboardText, "[Context: Launch risks]\n[Context: Product plan]\nWhat should change?")
    XCTAssertFalse(presentation.clipboardText.contains("/remote/org2"))

    XCTAssertEqual(
      presentation.removing(presentation.contexts[0]),
      "Use selected page “Product plan” at /remote/org2/Product at risk.org2:1 as context.\n\nWhat should change?"
    )
    XCTAssertEqual(
      presentation.replacingUserText("Summarize it."),
      "Use selected block “Launch risks” at /remote/org2/projects.org2:12-18 as context.\n\nUse selected page “Product plan” at /remote/org2/Product at risk.org2:1 as context.\n\nSummarize it."
    )
  }

  func testAIChatContextPresentationHidesLegacyOpaqueReference() {
    let presentation = AIChatContextPresentation(
      "Use selected page at 74717eff-8133-4b2c-a8eb-fa622adc2e0d.org2:1 as context.\n\nWhy did this fail?"
    )

    XCTAssertEqual(presentation.contexts.map(\.title), ["Page"])
    XCTAssertEqual(presentation.userText, "Why did this fail?")
    XCTAssertEqual(presentation.clipboardText, "[Context: Page]\nWhy did this fail?")
  }

  func testAIChatContextPresentationHidesAutomaticActionPromptBehindPill() throws {
    let raw = AIChatContextPresentation.automaticContext(
      kind: "approval item",
      title: "Approve Dashjoin first-touch draft",
      reference: "/remote/org2/approvals.org2:27",
      prompt: """
      OpenClaw approval thread:

      Account: Dashjoin
      Review this exact unsent Gmail draft. Nothing in this approval sends it.
      """,
      userText: "Please remove the repeated company name and revise the open drafts."
    )
    let presentation = AIChatContextPresentation(raw)

    XCTAssertEqual(presentation.contexts.map(\.title), ["Approve Dashjoin first-touch draft"])
    XCTAssertEqual(presentation.contexts.map(\.kind), ["approval item"])
    XCTAssertEqual(presentation.contexts.first?.reference, "/remote/org2/approvals.org2:27")
    XCTAssertTrue(try XCTUnwrap(presentation.contexts.first?.automaticPrompt).contains("Account: Dashjoin"))
    XCTAssertEqual(
      presentation.userText,
      "Please remove the repeated company name and revise the open drafts."
    )
    XCTAssertEqual(
      presentation.clipboardText,
      "[Context: Approve Dashjoin first-touch draft]\nPlease remove the repeated company name and revise the open drafts."
    )
    XCTAssertFalse(presentation.clipboardText.contains("OpenClaw approval thread"))

    let replacement = AIChatContextPresentation(
      presentation.replacingUserText("Use a warmer tone.")
    )
    XCTAssertEqual(replacement.contexts.first?.automaticPrompt, presentation.contexts.first?.automaticPrompt)
    XCTAssertEqual(replacement.userText, "Use a warmer tone.")
    XCTAssertEqual(
      presentation.removing(try XCTUnwrap(presentation.contexts.first)),
      "Please remove the repeated company name and revise the open drafts."
    )
  }

  @MainActor
  func testLegacyAIChatContextPillResolvesPageTitleAndOpensSource() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-context-pill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let filename = "74717eff-8133-4b2c-a8eb-fa622adc2e0d.org2"
    let file = root.appendingPathComponent(filename)
    try "#+TITLE: Scarf pricing strategy\n\n* Revenue share\n".write(
      to: file,
      atomically: true,
      encoding: .utf8
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    let context = try XCTUnwrap(AIChatContextPresentation(
      "Use selected page at \(filename):1 as context.\n\nWhat should change?"
    ).contexts.first)

    let resolved = store.resolvedAIChatContext(context)
    XCTAssertEqual(resolved.title, "Scarf pricing strategy")
    XCTAssertEqual(resolved.reference, context.reference)
    XCTAssertEqual(resolved.sourceLine, context.sourceLine)

    store.openAIChatContext(resolved)
    XCTAssertEqual(store.selectedLocation?.file, file.path)
    XCTAssertEqual(store.selectedLocation?.lineForEditor, 1)
  }

  func testOpenClawComposerDraftSyncMergesExternalDraftChangesWithoutDroppingLocalTyping() {
    XCTAssertEqual(
      AIChatComposerDraftSync.localDraftAfterStoreChange(
        localDraft: "old",
        previousStoreDraft: "old",
        nextStoreDraft: "external"
      ),
      "external"
    )
    XCTAssertEqual(
      AIChatComposerDraftSync.localDraftAfterStoreChange(
        localDraft: "local edit",
        previousStoreDraft: "",
        nextStoreDraft: "Use selected entry as context.\n\n"
      ),
      "Use selected entry as context.\n\nlocal edit"
    )
    XCTAssertEqual(
      AIChatComposerDraftSync.localDraftAfterStoreChange(
        localDraft: "draft plus local edit",
        previousStoreDraft: "draft",
        nextStoreDraft: "Use selected entry as context.\n\ndraft"
      ),
      "Use selected entry as context.\n\ndraft plus local edit"
    )
    XCTAssertEqual(
      AIChatComposerDraftSync.localDraftAfterStoreChange(
        localDraft: "local edit",
        previousStoreDraft: "",
        nextStoreDraft: ""
      ),
      ""
    )
  }

  @MainActor
  func testAIChatComposerDraftCacheDoesNotPublishStoreChangesWhileTyping() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.createAIChatThread(runtime: .openClaw)

    let draftChanged = ThreadSafeTestFlag()
    withObservationTracking {
      _ = store.aiChatDraft
    } onChange: {
      _ = draftChanged.setIfUnset()
    }

    store.cacheAIChatComposerDraft("typing into a large chat")
    store.cacheAIChatComposerDraft("typing into a large chat thread")

    XCTAssertEqual(store.aiChatDraft, "")
    XCTAssertFalse(draftChanged.value)
  }

  @MainActor
  func testAIChatComposerDraftCacheRestoresDraftsAcrossThreadSwitches() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.createAIChatThread(runtime: .openClaw)
    let firstThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.cacheAIChatComposerDraft("first local draft")

    store.createAIChatThread(runtime: .openClaw)
    let secondThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertEqual(store.aiChatDraft, "")
    store.cacheAIChatComposerDraft("second local draft")

    store.selectAIChatThread(firstThreadID)
    XCTAssertEqual(store.aiChatDraft, "first local draft")

    store.selectAIChatThread(secondThreadID)
    XCTAssertEqual(store.aiChatDraft, "second local draft")
  }

  func testAIChatVoiceDictationAppendsToDraftBeforeSend() {
    XCTAssertEqual(
      WorkspaceStore.aiChatDraftByAppendingDictation(existing: "Existing instruction", dictatedText: "Dictated note"),
      "Existing instruction\n\nDictated note"
    )
    XCTAssertEqual(
      WorkspaceStore.aiChatDraftByAppendingDictation(existing: "  ", dictatedText: " Dictated note\n"),
      "Dictated note"
    )
  }

  func testAIChatVoiceTranscriptionProgressIsEstimatedAndCapped() {
    XCTAssertEqual(WorkspaceStore.estimatedAIChatVoiceTranscriptionDuration(for: 1), 8)
    XCTAssertEqual(WorkspaceStore.estimatedAIChatVoiceTranscriptionDuration(for: 20), 80)
    XCTAssertEqual(WorkspaceStore.estimatedAIChatVoiceTranscriptionDuration(for: 100), 180)

    XCTAssertEqual(
      WorkspaceStore.aiChatVoiceTranscriptionProgress(elapsed: 0, estimatedDuration: 10),
      0.02,
      accuracy: 0.001
    )
    XCTAssertEqual(
      WorkspaceStore.aiChatVoiceTranscriptionProgress(elapsed: 5, estimatedDuration: 10),
      0.5,
      accuracy: 0.001
    )
    XCTAssertEqual(
      WorkspaceStore.aiChatVoiceTranscriptionProgress(elapsed: 20, estimatedDuration: 10),
      0.95,
      accuracy: 0.001
    )
  }

  func testMeetingTranscriptionProgressIsEstimatedAndCapped() {
    XCTAssertEqual(WorkspaceStore.estimatedMeetingTranscriptionDuration(for: nil), 120)
    XCTAssertEqual(WorkspaceStore.estimatedMeetingTranscriptionDuration(for: 10), 30)
    XCTAssertEqual(WorkspaceStore.estimatedMeetingTranscriptionDuration(for: 600), 1_200)
    XCTAssertEqual(WorkspaceStore.estimatedMeetingTranscriptionDuration(for: 4_000), 3_600)

    XCTAssertEqual(
      WorkspaceStore.meetingTranscriptionProgress(elapsed: 0, estimatedDuration: 100),
      0.02,
      accuracy: 0.001
    )
    XCTAssertEqual(
      WorkspaceStore.meetingTranscriptionProgress(elapsed: 50, estimatedDuration: 100),
      0.5,
      accuracy: 0.001
    )
    XCTAssertEqual(
      WorkspaceStore.meetingTranscriptionProgress(elapsed: 500, estimatedDuration: 100),
      0.95,
      accuracy: 0.001
    )
  }

  func testAIChatVoiceTranscriptionElapsedTextFormatsDuration() {
    XCTAssertEqual(WorkspaceStore.aiChatVoiceTranscriptionElapsedText(elapsed: 0.8), "0s")
    XCTAssertEqual(WorkspaceStore.aiChatVoiceTranscriptionElapsedText(elapsed: 12.4), "12s")
    XCTAssertEqual(WorkspaceStore.aiChatVoiceTranscriptionElapsedText(elapsed: 75.9), "1m 15s")
  }

  func testRenderedSearchHighlightQueryNormalizesSearchText() {
    XCTAssertEqual(WorkspaceStore.normalizedRenderedSearchHighlightQuery("  Alpha  "), "Alpha")
    XCTAssertEqual(WorkspaceStore.normalizedRenderedSearchHighlightQuery("\"exact phrase\""), "exact phrase")
    XCTAssertEqual(WorkspaceStore.normalizedRenderedSearchHighlightQuery("id:abc-123"), "abc-123")
    XCTAssertNil(WorkspaceStore.normalizedRenderedSearchHighlightQuery("   "))

    XCTAssertEqual(WorkspaceStore.countSearchOccurrences(in: "Needle needle NEED", query: "needle"), 2)
    XCTAssertEqual(WorkspaceStore.countSearchOccurrences(in: "aaa", query: "aa"), 1)
    XCTAssertEqual(WorkspaceStore.countSearchOccurrences(in: "anything", query: "  "), 0)
  }

  @MainActor
  func testSelectingSearchResultActivatesAndClearsRenderedHighlight() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let result = try JSONDecoder().decode(SearchResult.self, from: Data("""
    {
      "file": "/tmp/search.org",
      "line": 3,
      "tags": [],
      "snippet": "Body with Needle",
      "heading": "Search hit"
    }
    """.utf8))

    store.searchQuery = "needle"
    store.select(.search(result))

    XCTAssertEqual(store.renderedSearchHighlightQuery, "needle")
    XCTAssertTrue(store.hasRenderedSearchHighlight)

    XCTAssertTrue(store.focusPageSearch())
    XCTAssertTrue(store.isPageSearchPresented)
    XCTAssertEqual(store.pageSearchQuery, "needle")
    store.pageSearchQuery = "other"
    try await waitForCondition {
      store.renderedSearchHighlightQuery == "other"
    }
    XCTAssertEqual(store.renderedSearchHighlightQuery, "other")
    XCTAssertEqual(store.pageSearchOccurrenceCount, 0)
    XCTAssertNil(store.pageSearchSelectedOccurrenceIndex)

    store.clearRenderedSearchHighlight()
    XCTAssertNil(store.renderedSearchHighlightQuery)
    XCTAssertFalse(store.isPageSearchPresented)
    XCTAssertEqual(store.pageSearchOccurrenceCount, 0)
    XCTAssertNil(store.pageSearchSelectedOccurrenceIndex)

    store.renderedSearchHighlightQuery = "needle"
    store.isPageSearchPresented = true
    store.pageSearchQuery = "needle"
    store.select(.aiChatThreadRecord(AIChatThreadRecord(
      title: "Other",
      file: "/tmp/other.org",
      line: 1,
      zone: "corpus",
      modifiedAt: nil,
      idValue: nil
    )))
    XCTAssertNil(store.renderedSearchHighlightQuery)
    XCTAssertFalse(store.isPageSearchPresented)
    XCTAssertTrue(store.pageSearchQuery.isEmpty)
  }

  @MainActor
  func testPageSearchCountsFullFileAndNavigatesRenderedOccurrences() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("page-search.org2")
    try """
    #+TITLE: Page Search

    * First
    Alpha needle here

    * Second
    Beta Needle again
    Third needle
    """.write(to: note, atomically: true, encoding: .utf8)

    let result = SearchResult(
      file: note.path,
      line: 4,
      lineEnd: nil,
      heading: "First",
      headingLine: 3,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: nil,
      tags: [],
      snippet: "Alpha needle here",
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedSurface = .search
    store.searchQuery = "needle"
    store.select(.search(result))
    store.selectedEntrySourceMode = .page
    await store.reloadSelectedEntrySource()
    try await waitForEntryRender(store)
    try await waitForCondition {
      !store.selectedRenderedBlocks.isEmpty
    }

    XCTAssertTrue(store.focusPageSearch())
    XCTAssertEqual(store.pageSearchQuery, "needle")
    try await waitForCondition {
      store.pageSearchOccurrenceCount == 3
        && store.pageSearchSelectedOccurrenceIndex == 0
    }
    XCTAssertEqual(store.pageSearchOccurrenceCount, 3)
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 0)
    XCTAssertEqual(store.pageSearchOccurrenceSummary, "1 of 3")
    let firstSelectedBlockID = try XCTUnwrap(store.selectedBlockID)
    let firstScrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertEqual(firstScrollRequest.target, .block(firstSelectedBlockID))
    var previousScrollRequestID = firstScrollRequest.id

    // Advancing through an established query must use the cached match list rather than
    // rereading or rescanning the full document.
    try FileManager.default.removeItem(at: note)

    store.selectNextPageSearchOccurrence()
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 1)
    XCTAssertEqual(store.pageSearchOccurrenceSummary, "2 of 3")
    let secondSelectedBlockID = try XCTUnwrap(store.selectedBlockID)
    XCTAssertNotEqual(secondSelectedBlockID, firstSelectedBlockID)
    var scrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertGreaterThan(scrollRequest.id, previousScrollRequestID)
    XCTAssertEqual(scrollRequest.target, .block(secondSelectedBlockID))
    previousScrollRequestID = scrollRequest.id

    store.selectNextPageSearchOccurrence()
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 2)
    XCTAssertEqual(store.pageSearchOccurrenceSummary, "3 of 3")
    XCTAssertEqual(store.selectedBlockID, secondSelectedBlockID)
    scrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertGreaterThan(scrollRequest.id, previousScrollRequestID)
    XCTAssertEqual(scrollRequest.target, .block(secondSelectedBlockID))
    previousScrollRequestID = scrollRequest.id

    store.selectNextPageSearchOccurrence()
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 0)
    XCTAssertEqual(store.selectedBlockID, firstSelectedBlockID)
    scrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertGreaterThan(scrollRequest.id, previousScrollRequestID)
    XCTAssertEqual(scrollRequest.target, .block(firstSelectedBlockID))
    previousScrollRequestID = scrollRequest.id

    store.selectPreviousPageSearchOccurrence()
    XCTAssertEqual(store.pageSearchSelectedOccurrenceIndex, 2)
    XCTAssertEqual(store.selectedBlockID, secondSelectedBlockID)
    scrollRequest = try XCTUnwrap(store.detailScrollRequest)
    XCTAssertGreaterThan(scrollRequest.id, previousScrollRequestID)
    XCTAssertEqual(scrollRequest.target, .block(secondSelectedBlockID))

    store.pageSearchQuery = "missing"
    try await waitForCondition {
      store.renderedSearchHighlightQuery == "missing"
        && store.pageSearchOccurrenceCount == 0
    }
    XCTAssertEqual(store.pageSearchOccurrenceCount, 0)
    XCTAssertEqual(store.pageSearchOccurrenceSummary, "0 matches")
    XCTAssertNil(store.pageSearchSelectedOccurrenceIndex)
  }

  @MainActor
  func testAIChatSendQueueSerializesConsecutiveMessages() async throws {
    let recorder = AIChatQueuedSendRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-queue-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )

    store.aiChatDraft = "first"
    let firstSend = Task { await store.sendAIChatMessage() }
    try await waitForCondition {
      store.isSendingAIChatMessage
    }
    store.aiChatDraft = "second"
    let secondSend = Task { await store.sendAIChatMessage() }

    await firstSend.value
    await secondSend.value

    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:first",
      "assistant:reply 1",
      "user:second",
      "assistant:reply 2"
    ])
    let calls = await recorder.recordedCalls()
    XCTAssertEqual(calls, [
      ["user:first"],
      ["user:first", "assistant:reply 1", "user:second"]
    ])
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatQueuedMessageCount, 0)
    XCTAssertEqual(store.aiChatStatusText, "OpenClaw replied")
  }

  @MainActor
  func testEstablishedAIChatDoesNotInjectUnrelatedDetailPaneSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-context-isolation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatWorkspaceContextRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { _, _, _, context in
        await recorder.send(context: context)
      }
    )
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.createAIChatThread(runtime: .openClaw)
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.renameAIChatThread(threadID, title: "Apryse file-extension backfill")
    store.aiChatMessages = [
      AIChatMessage(
        role: .user,
        content: "Track the Apryse work in /remote/org2/notes/apryse.org2:12."
      ),
      AIChatMessage(role: .assistant, content: "The Apryse backfill is still running.")
    ]

    store.selectedSurface = .aiChat
    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Send Jesse tailored KitOps follow-up examples",
      file: root.appendingPathComponent("meetings/kitops.org2").path,
      line: 44,
      zone: "meetings",
      modifiedAt: nil,
      idValue: "kitops-follow-up"
    ))
    store.selectedEntrySource = EntrySource(
      file: root.appendingPathComponent("meetings/kitops.org2").path,
      startLine: 44,
      endLineExclusive: 47,
      text: "* TODO Send Jesse tailored KitOps follow-up examples",
      isSubtree: true
    )

    await store.sendAIChatMessage(text: "What's the latest on this one?")

    let recordedContexts = await recorder.recordedContexts()
    let context = try XCTUnwrap(recordedContexts.first)
    XCTAssertNil(context.selectedLocationTitle)
    XCTAssertEqual(context.continuationTitle, "Apryse file-extension backfill")
    XCTAssertTrue(context.prompt.contains("Thread title: Apryse file-extension backfill"))
    XCTAssertTrue(context.prompt.contains("authoritative for ambiguous conversational references"))
    XCTAssertTrue(context.prompt.contains("The Apryse backfill is still running."))
    XCTAssertFalse(context.prompt.contains("Current UI selection"))
    XCTAssertFalse(context.prompt.contains("KitOps"))
  }

  @MainActor
  func testAssistantCitationCannotBecomeDurableAIChatFileContext() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-reference-isolation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AIChatWorkspaceContextRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { _, _, _, context in
        await recorder.send(context: context)
      }
    )
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.createAIChatThread(runtime: .openClaw)
    store.aiChatMessages = [
      AIChatMessage(
        role: .user,
        content: "Use /remote/org2/notes/apryse.org2:12 for this thread."
      ),
      AIChatMessage(
        role: .assistant,
        content: "I mistakenly used [KitOps](/remote/org2/meetings/kitops.org2:44)."
      )
    ]

    await store.sendAIChatMessage(text: "Continue with Apryse.")

    let recordedContexts = await recorder.recordedContexts()
    let context = try XCTUnwrap(recordedContexts.first)
    XCTAssertEqual(context.continuationReferences, ["/remote/org2/notes/apryse.org2:12"])
    XCTAssertFalse(context.continuationReferences.contains(where: { $0.contains("kitops") }))
  }

  @MainActor
  func testInProgressMessageQueuesByDefaultAndCanSteerNow() async throws {
    let sendRecorder = AIChatSuspendedSendRecorder()
    let steerRecorder = AIChatSteerRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-steer-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await sendRecorder.send(messages: messages)
      }
    )
    store.aiChatSteerHandlerForTesting = { runtime, threadID, content, _ in
      await steerRecorder.record(runtime: runtime, threadID: threadID, content: content)
    }

    store.aiChatDraft = "first request"
    let firstSend = Task { await store.sendAIChatMessage() }
    await sendRecorder.waitUntilStarted()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)

    store.sendComposedAIChatMessage(text: "focus on the failing test")
    let queuedMessage = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertTrue(store.isAIChatMessageQueued(queuedMessage.id))
    XCTAssertTrue(store.canSteerQueuedAIChatMessage(queuedMessage.id))
    XCTAssertEqual(queuedMessage.deliveryKind, .followUp)
    let preSteerContents = await steerRecorder.recordedContents()
    XCTAssertTrue(preSteerContents.isEmpty)

    await store.steerQueuedAIChatMessage(queuedMessage.id)
    try await waitForCondition {
      store.aiChatMessages.last?.deliveryStatus == .sent
    }

    let steeredContents = await steerRecorder.recordedContents()
    XCTAssertEqual(steeredContents, ["focus on the failing test"])
    XCTAssertEqual(store.aiChatMessages.map(\.deliveryKind), [.turn, .steer])
    XCTAssertFalse(store.isAIChatMessageQueued(queuedMessage.id))
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.runtime, .openClaw)

    await sendRecorder.finish(reply: "finished with the new direction")
    await firstSend.value
    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:first request",
      "user:focus on the failing test",
      "assistant:finished with the new direction"
    ])
  }

  @MainActor
  func testExplicitInProgressSteerBypassesQueue() async throws {
    let sendRecorder = AIChatSuspendedSendRecorder()
    let steerRecorder = AIChatSteerRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-explicit-steer-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await sendRecorder.send(messages: messages)
      }
    )
    store.aiChatSteerHandlerForTesting = { runtime, threadID, content, _ in
      await steerRecorder.record(runtime: runtime, threadID: threadID, content: content)
    }

    store.aiChatDraft = "first request"
    let firstSend = Task { await store.sendAIChatMessage() }
    await sendRecorder.waitUntilStarted()

    store.sendComposedAIChatMessage(
      text: "change direction immediately",
      delivery: .steer
    )
    try await waitForCondition {
      store.aiChatMessages.last?.deliveryStatus == .sent
    }

    let steeredContents = await steerRecorder.recordedContents()
    XCTAssertEqual(steeredContents, ["change direction immediately"])
    let steerMessage = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(steerMessage.deliveryKind, .steer)
    XCTAssertFalse(store.isAIChatMessageQueued(steerMessage.id))

    await sendRecorder.finish(reply: "finished after steering")
    await firstSend.value
  }

  @MainActor
  func testExplicitSteerWaitsForLiveSessionInsteadOfQueueing() async throws {
    // iOS steers right after a turn starts, before OpenCode reports its
    // session. The guidance must wait for the session, not become a follow-up.
    let sendRecorder = AIChatSuspendedSendRecorder()
    let steerRecorder = AIChatSteerRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-early-steer-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await sendRecorder.send(messages: messages)
      }
    )
    store.aiChatSteerHandlerForTesting = { runtime, threadID, content, _ in
      await steerRecorder.record(runtime: runtime, threadID: threadID, content: content)
    }
    var sessionReady = false
    store.aiChatSteerReadinessForTesting = { _ in sessionReady }

    store.aiChatDraft = "first request"
    let firstSend = Task { await store.sendAIChatMessage() }
    await sendRecorder.waitUntilStarted()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)

    let destination = store.sendAIChatRemoteMessageDestination(
      "use the other approach",
      threadID: threadID,
      delivery: .steer
    )
    XCTAssertEqual(destination, threadID)
    let steerMessage = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(steerMessage.deliveryKind, .steer)
    XCTAssertFalse(store.isAIChatMessageQueued(steerMessage.id), "not downgraded to a follow-up")
    try await Task.sleep(for: .milliseconds(300))
    let earlyContents = await steerRecorder.recordedContents()
    XCTAssertTrue(earlyContents.isEmpty)

    sessionReady = true
    try await waitForCondition {
      store.aiChatMessages.last?.deliveryStatus == .sent
    }
    let steeredContents = await steerRecorder.recordedContents()
    XCTAssertEqual(steeredContents, ["use the other approach"])
    XCTAssertEqual(store.aiChatMessages.last?.deliveryKind, .steer)

    await sendRecorder.finish(reply: "done")
    await firstSend.value
  }

  @MainActor
  func testExplicitSteerFallsBackToFollowUpWhenSessionNeverBecomesReady() async throws {
    let sendRecorder = AIChatSuspendedSendRecorder()
    let steerRecorder = AIChatSteerRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-unready-steer-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await sendRecorder.send(messages: messages)
      }
    )
    store.aiChatSteerHandlerForTesting = { runtime, threadID, content, _ in
      await steerRecorder.record(runtime: runtime, threadID: threadID, content: content)
    }
    store.aiChatSteerReadinessForTesting = { _ in false }
    store.aiChatSteerReadinessTimeout = .milliseconds(300)

    store.aiChatDraft = "first request"
    let firstSend = Task { await store.sendAIChatMessage() }
    await sendRecorder.waitUntilStarted()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)

    _ = store.sendAIChatRemoteMessageDestination(
      "use the other approach",
      threadID: threadID,
      delivery: .steer
    )
    let steerMessage = try XCTUnwrap(store.aiChatMessages.last)
    try await waitForCondition {
      store.isAIChatMessageQueued(steerMessage.id)
    }
    XCTAssertEqual(store.aiChatMessages.last?.deliveryKind, .followUp)
    let steeredContents = await steerRecorder.recordedContents()
    XCTAssertTrue(steeredContents.isEmpty)

    // Finish the first turn, then the follow-up turn the guidance became.
    for _ in 0..<100 {
      await sendRecorder.finish(reply: "done")
      if store.aiChatMessages.filter({ $0.role == .assistant }).count == 2 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    await firstSend.value
    XCTAssertEqual(store.aiChatMessages.filter { $0.role == .assistant }.count, 2)
    XCTAssertEqual(
      store.aiChatMessages.first { $0.id == steerMessage.id }?.deliveryStatus,
      .sent,
      "the guidance was delivered as the next turn"
    )
  }

  /// The reported bug: the queue lost a running turn, so its reply was
  /// dropped and the prompt stayed `sending`. The chat looked busy forever,
  /// new messages queued behind it, and steers had no session to reach.
  @MainActor
  func testTurnLostFromQueueStillReceivesItsReplyAndTheChatSettles() async throws {
    let sendRecorder = AIChatSuspendedSendRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-lost-turn-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await sendRecorder.send(messages: messages)
      }
    )

    store.aiChatDraft = "first request"
    let firstSend = Task { await store.sendAIChatMessage() }
    await sendRecorder.waitUntilStarted()
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.forgetAIChatQueueForTesting(threadID)

    await sendRecorder.finish(reply: "first reply")
    await firstSend.value

    XCTAssertEqual(
      store.aiChatMessages.map { "\($0.role.rawValue):\($0.deliveryStatus):\($0.content)" },
      ["user:sent:first request", "assistant:sent:first reply"]
    )
    XCTAssertFalse(store.isAIChatThreadRunning(threadID))

    store.sendComposedAIChatMessage(text: "next question")
    let next = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertEqual(next.deliveryKind, .turn, "the next message is not queued behind a finished turn")
    for _ in 0..<100 where store.aiChatMessages.last?.content != "next reply" {
      await sendRecorder.finish(reply: "next reply")
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(store.aiChatMessages.last?.content, "next reply")
  }

  func testOrphanRepairInterruptsOnlyTurnsThisProcessDispatched() {
    let orphan = AIChatMessage(role: .user, content: "lost", deliveryStatus: .sending)
    let queued = AIChatMessage(
      role: .user,
      content: "queued",
      deliveryStatus: .sending,
      deliveryKind: .followUp
    )
    let answered = AIChatMessage(role: .user, content: "answered", deliveryStatus: .sent)
    let thread = AIChatThread(title: "Lost", sessionKey: "lost", messages: [answered, orphan, queued])

    let repaired = WorkspaceStore.interruptOrphanedAIChatSends(
      in: thread,
      dispatchedMessageIDs: [orphan.id, answered.id]
    )
    XCTAssertEqual(repaired?.messages.map(\.deliveryStatus), [.sent, .interrupted, .sending])
    XCTAssertEqual(repaired?.messages[1].sendFailure, WorkspaceStore.aiChatOrphanedSendFailureText)
    XCTAssertNil(WorkspaceStore.interruptOrphanedAIChatSends(in: thread, dispatchedMessageIDs: []))
  }

  func testManagedRemoteRetryRequiresExactAuthoritativeTerminalReceipt() {
    let attemptID = UUID()
    let message = AIChatMessage(
      role: .user,
      content: "retry me",
      sendFailure: "mutable model failure",
      deliveryStatus: .failed
    ).replacingDeliveryAttempt(
      attemptID,
      status: .failed,
      sendFailure: "mutable model failure",
      attemptState: nil
    )
    func receipt(
      _ state: AIChatDeliveryReceipt.State,
      attempt: UUID? = nil,
      threadID: String? = "native-thread",
      turnID: String? = "native-turn"
    ) -> AIChatDeliveryReceipt {
      AIChatDeliveryReceipt(
        state: state,
        messageID: message.id,
        deliveryAttemptID: attempt ?? attemptID,
        runtimeThreadID: threadID,
        turnID: turnID
      )
    }

    XCTAssertEqual(
      WorkspaceStore.managedRemoteRetryPredecessor(
        message: message,
        receipt: receipt(.failed)
      ),
      attemptID
    )
    XCTAssertEqual(
      WorkspaceStore.managedRemoteRetryPredecessor(
        message: message,
        receipt: receipt(.interrupted)
      ),
      attemptID
    )
    XCTAssertNil(WorkspaceStore.managedRemoteRetryPredecessor(
      message: message,
      receipt: receipt(.completed)
    ))
    XCTAssertNil(WorkspaceStore.managedRemoteRetryPredecessor(
      message: message,
      receipt: receipt(.failed, attempt: UUID())
    ))
    XCTAssertNil(WorkspaceStore.managedRemoteRetryPredecessor(
      message: message,
      receipt: receipt(.failed, turnID: nil)
    ))

    // If a writer drops the structured attempt fields, a stale native receipt
    // cannot authorize a child. The producer journal remains the fail-closed
    // authority when the message is reconciled as its deterministic initial
    // identity.
    let fieldLost = AIChatMessage(
      id: message.id,
      role: .user,
      content: message.content,
      sendFailure: "legacy writer replaced this text",
      deliveryStatus: .failed
    )
    let initialReceipt = AIChatDeliveryReceipt(
      state: .failed,
      messageID: message.id,
      deliveryAttemptID: message.id,
      runtimeThreadID: "native-thread",
      turnID: "native-turn"
    )
    XCTAssertNil(WorkspaceStore.managedRemoteRetryPredecessor(
      message: fieldLost,
      receipt: initialReceipt
    ))
    XCTAssertNil(WorkspaceStore.managedRemoteRetryPredecessor(
      message: fieldLost,
      receipt: nil
    ))
  }

  func testOpenOrgRetryPayloadRequiresAndPreservesExactNativeIdentity() throws {
    let messageID = UUID()
    let attemptID = UUID()
    let complete = AIChatDeliveryReceipt(
      state: .failed,
      messageID: messageID,
      deliveryAttemptID: attemptID,
      runtimeThreadID: "native-thread",
      turnID: "native-turn",
      detail: "provider failed"
    ).openOrgServerRetryPayload()

    XCTAssertEqual(complete["retryRequested"] as? Bool, true)
    XCTAssertEqual(complete["deliveryState"] as? String, "failed")
    XCTAssertEqual(complete["turnStarted"] as? Bool, true)
    XCTAssertEqual(complete["terminal"] as? Bool, true)
    XCTAssertEqual(complete["messageID"] as? String, messageID.uuidString.lowercased())
    XCTAssertEqual(complete["deliveryAttemptID"] as? String, attemptID.uuidString.lowercased())
    XCTAssertEqual(complete["runtimeThreadID"] as? String, "native-thread")
    XCTAssertEqual(complete["turnID"] as? String, "native-turn")
    XCTAssertEqual(complete["detail"] as? String, "provider failed")

    let partial = AIChatDeliveryReceipt(
      state: .completed,
      messageID: messageID,
      runtimeThreadID: "native-thread",
      turnID: "native-turn"
    ).openOrgServerRetryPayload()
    XCTAssertEqual(partial["turnStarted"] as? Bool, false)
    XCTAssertEqual(partial["terminal"] as? Bool, true)

    let unknown = AIChatDeliveryReceipt(
      state: .unconfirmed,
      messageID: messageID,
      deliveryAttemptID: attemptID,
      runtimeThreadID: "native-thread",
      turnID: "native-turn"
    ).openOrgServerRetryPayload()
    XCTAssertEqual(unknown["turnStarted"] as? Bool, false)
    XCTAssertEqual(unknown["terminal"] as? Bool, false)

    let requested = AIChatDeliveryReceipt(
      state: .requested,
      messageID: messageID,
      detail: "Retry requested; native execution has not been confirmed."
    ).openOrgServerRetryPayload()
    XCTAssertEqual(requested["retryRequested"] as? Bool, true)
    XCTAssertEqual(requested["deliveryState"] as? String, "requested")
    XCTAssertEqual(requested["turnStarted"] as? Bool, false)
    XCTAssertEqual(requested["terminal"] as? Bool, false)
    XCTAssertNil(requested["deliveryAttemptID"])
    XCTAssertNil(requested["runtimeThreadID"])
    XCTAssertNil(requested["turnID"])
  }

  @MainActor
  func testLocalCodexKnownStartNeverEntersManagedRemoteRecheckState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-local-codex-marker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transcript = root.appendingPathComponent("chat.json")
    let startedMarker = root.appendingPathComponent("turn-started")
    let executable = root.appendingPathComponent("fake-local-codex")
    let script = #"""
    #!/bin/sh
    while IFS= read -r line; do
      request_id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":([0-9]+).*/\1/')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"id":%s,"result":{"userAgent":"local-fixture"}}\n' "$request_id"
          ;;
        *'"method":"initialized"'*) ;;
        *'"method":"account/read"'*)
          printf '{"id":%s,"result":{"account":{"type":"chatgpt","email":"fixture@example.test"},"requiresOpenaiAuth":true}}\n' "$request_id"
          ;;
        *'"method":"thread/start"'*)
          printf '{"id":%s,"result":{"thread":{"id":"thr-local-fixture"}}}\n' "$request_id"
          ;;
        *'"method":"turn/start"'*)
          : > '\#(startedMarker.path)'
          printf '{"id":%s,"result":{"turn":{"id":"turn-local-fixture","status":"inProgress"}}}\n' "$request_id"
          sleep 1
          printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-local-fixture","turn":{"id":"turn-local-fixture","status":"completed","items":[{"id":"agent-final","type":"agentMessage","phase":"final_answer","text":"Local completed"}]}}}'
          ;;
      esac
    done
    """#
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let suiteName = "LocalCodexManagedMarkerTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      codexLocalExecutableURLForTesting: executable,
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.createAIChatThread(runtime: .codex)

    let send = Task { await store.sendAIChatMessage(text: "Keep local delivery semantics") }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: startedMarker.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: startedMarker.path))
    try await Task.sleep(for: .milliseconds(50))
    let running = try XCTUnwrap(store.aiChatMessages.first(where: { $0.role == .user }))
    XCTAssertEqual(running.deliveryStatus, .sending)
    XCTAssertFalse(running.deliveryIsUnconfirmed)
    XCTAssertNil(running.displayedSendFailure)

    await send.value
    await store.shutdownAIChatTransports()
    let stopped = try XCTUnwrap(store.aiChatMessages.first(where: { $0.role == .user }))
    XCTAssertFalse(stopped.deliveryIsUnconfirmed)
  }

  /// A transcript refresh while a steer is still being delivered must not
  /// mark it "interrupted before its acknowledgement".
  func testReloadLeavesInFlightSteerAlone() {
    let inFlight = AIChatMessage(role: .user, content: "go", deliveryStatus: .sending, deliveryKind: .steer)
    let lost = AIChatMessage(role: .user, content: "lost", deliveryStatus: .sending, deliveryKind: .steer)
    let thread = AIChatThread(title: "Steer", sessionKey: "steer", messages: [inFlight, lost])

    let result = WorkspaceStore.interruptUnresolvedAIChatSteers(
      in: [thread],
      inFlightSteerIDs: [inFlight.id]
    )
    XCTAssertEqual(result.threads[0].messages.map(\.deliveryStatus), [.sending, .interrupted])
  }

  /// Retrying an interrupted steer when no turn is running used to re-queue it
  /// still marked as a steer. Queue rebuilds skip steers, so the next reload
  /// interrupted it again and every retry "failed".
  @MainActor
  func testRetriedSteerWithoutLiveTurnSendsAsAnOrdinaryTurn() async throws {
    let sendRecorder = AIChatSuspendedSendRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-retry-steer-\(UUID().uuidString).json")
    let steer = AIChatMessage(
      role: .user,
      content: "do the confirmation",
      sendFailure: "This steer was interrupted before its acknowledgement. Retry it to steer the active run again.",
      deliveryStatus: .interrupted,
      deliveryKind: .steer
    )
    let thread = AIChatThread(
      title: "Interrupted steer",
      sessionKey: "interrupted-steer",
      messages: [
        AIChatMessage(role: .user, content: "start", deliveryStatus: .sent),
        AIChatMessage(role: .assistant, content: "started"),
        steer
      ]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [thread],
        selectedThreadID: thread.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: transcriptURL
    )
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await sendRecorder.send(messages: messages)
      }
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))

    let retry = Task { await store.retryAIChatMessage(steer.id) }
    await sendRecorder.waitUntilStarted()
    let retried = try XCTUnwrap(store.aiChatMessages.first { $0.id == steer.id })
    XCTAssertEqual(retried.deliveryKind, .turn)
    XCTAssertEqual(retried.deliveryStatus, .sending)
    XCTAssertNil(retried.sendFailure)

    await sendRecorder.finish(reply: "confirmed")
    await retry.value
    XCTAssertEqual(store.aiChatMessages.first { $0.id == steer.id }?.deliveryStatus, .sent)
    XCTAssertEqual(store.aiChatMessages.last?.content, "confirmed")
    XCTAssertFalse(store.isAIChatThreadRunning(thread.id))
  }

  func testOpenClawSteerRequestUsesSteerCommandWithoutQueueMode() throws {
    let attachment = AIChatAttachment(
      fileName: "reference.txt",
      mimeType: "text/plain",
      data: Data("hello".utf8)
    )
    let params = try OpenClawGatewayClient.steerRequestParams(
      message: "change direction",
      attachments: [attachment],
      sessionKey: "agent:main:test",
      agentID: "main",
      idempotencyKey: "steer-id"
    )

    XCTAssertNil(params["queueMode"])
    XCTAssertEqual(params["message"] as? String, "/steer change direction")
    XCTAssertEqual(params["sessionKey"] as? String, "agent:main:test")
    XCTAssertEqual(params["idempotencyKey"] as? String, "steer-id")
    XCTAssertEqual((params["attachments"] as? [[String: Any]])?.first?["type"] as? String, "file")
  }

  @MainActor
  func testDictationSendStaysBoundToItsOriginatingThread() async throws {
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-dictation-origin-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        "reply to \(messages.last?.content ?? "")"
      }
    )

    store.createAIChatThread(runtime: .openClaw)
    let originThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.publishAIChatComposerDraft("Existing origin draft")

    store.createAIChatThread(runtime: .openClaw)
    let otherThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.publishAIChatComposerDraft("Unrelated other-thread draft")

    let accepted = await store.sendAIChatDictation("Dictated follow-up", to: originThreadID)
    XCTAssertTrue(accepted)

    XCTAssertEqual(store.selectedAIChatThreadID, otherThreadID)
    XCTAssertEqual(store.aiChatDraft, "Unrelated other-thread draft")
    XCTAssertTrue(
      store.aiChatThreads.first(where: { $0.id == otherThreadID })?.messages.isEmpty == true
    )
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == originThreadID })?.messages.map(\.content),
      [
        "Existing origin draft\n\nDictated follow-up",
        "reply to Existing origin draft\n\nDictated follow-up",
      ]
    )
  }

  @MainActor
  func testDictationStopReturnsTranscriptToOriginatingThreadComposer() throws {
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-dictation-draft-origin-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL
    )

    store.createAIChatThread(runtime: .openClaw)
    let originThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.publishAIChatComposerDraft("Existing origin draft")

    store.createAIChatThread(runtime: .openClaw)
    let otherThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.publishAIChatComposerDraft("Unrelated other-thread draft")

    XCTAssertTrue(store.insertAIChatDictationIntoDraft("Dictated follow-up", in: originThreadID))
    XCTAssertEqual(store.selectedAIChatThreadID, otherThreadID)
    XCTAssertEqual(store.aiChatDraft, "Unrelated other-thread draft")

    store.selectAIChatThread(originThreadID)
    XCTAssertEqual(store.aiChatDraft, "Existing origin draft\n\nDictated follow-up")
    XCTAssertTrue(store.aiChatMessages.isEmpty)
  }

  @MainActor
  func testFailedDictationTranscriptionKeepsRecordingAndShowsError() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-dictation-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json")
    )
    store.aiChatDictationRecoveryDirectory = root.appendingPathComponent("kept", isDirectory: true)
    store.meetingTranscriptionForTesting = { _ in
      MeetingTranscriptResult(
        text: "",
        status: .failed,
        engine: "Fluid Voice",
        errorMessage: "Fluid Voice Local API is unavailable"
      )
    }
    store.createAIChatThread(runtime: .openClaw)
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    let audioURL = root.appendingPathComponent("rant.wav")
    try Data("long rant".utf8).write(to: audioURL)

    await store.finishAIChatDictationForTesting(audioURL: audioURL, duration: 90, threadID: threadID)

    XCTAssertFalse(store.isTranscribingAIChatVoiceNote)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    let kept = try FileManager.default.contentsOfDirectory(
      at: store.aiChatDictationRecoveryDirectory,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(kept.count, 1)
    XCTAssertEqual(try Data(contentsOf: kept[0]), Data("long rant".utf8))
    let error = try XCTUnwrap(store.errorText)
    XCTAssertTrue(error.contains("Fluid Voice Local API is unavailable"), error)
    XCTAssertTrue(error.contains(kept[0].lastPathComponent), error)
  }

  @MainActor
  func testSuccessfulDictationDeletesRecordingAndFillsComposer() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-dictation-success-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json")
    )
    store.aiChatDictationRecoveryDirectory = root.appendingPathComponent("kept", isDirectory: true)
    store.meetingTranscriptionForTesting = { _ in
      MeetingTranscriptResult(text: "Dictated rant", status: .complete, engine: "test")
    }
    store.createAIChatThread(runtime: .openClaw)
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    let audioURL = root.appendingPathComponent("rant.wav")
    try Data("audio".utf8).write(to: audioURL)

    await store.finishAIChatDictationForTesting(audioURL: audioURL, duration: 5, threadID: threadID)

    XCTAssertEqual(store.aiChatDraft, "Dictated rant")
    XCTAssertFalse(store.isTranscribingAIChatVoiceNote)
    XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.aiChatDictationRecoveryDirectory.path))
    XCTAssertNil(store.errorText)
  }

  @MainActor
  func testDictationFallsBackWhenConfiguredTranscriberFails() async {
    let fellBack = await WorkspaceStore.transcribeAIChatDictation(
      primary: {
        MeetingTranscriptResult(
          text: "",
          status: .failed,
          engine: "Fluid Voice",
          errorMessage: "Fluid Voice Local API is unavailable"
        )
      },
      fallback: { MeetingTranscriptResult(text: "Hello", status: .complete, engine: "whisper.cpp") }
    )
    XCTAssertEqual(fellBack.text, "Hello")
    XCTAssertEqual(fellBack.status, .complete)
    XCTAssertEqual(fellBack.engine, "whisper.cpp (fallback)")

    let bothFailed = await WorkspaceStore.transcribeAIChatDictation(
      primary: { MeetingTranscriptResult(text: "", status: .failed, engine: "Fluid Voice", errorMessage: "down") },
      fallback: { MeetingTranscriptResult(text: " ", status: .complete, engine: "macOS Speech") }
    )
    XCTAssertEqual(bothFailed.status, .failed)
    XCTAssertTrue(bothFailed.errorMessage?.contains("Fluid Voice: down") == true)

    var fallbackRan = false
    let primaryOK = await WorkspaceStore.transcribeAIChatDictation(
      primary: { MeetingTranscriptResult(text: "Hi", status: .complete, engine: "Fluid Voice") },
      fallback: {
        fallbackRan = true
        return MeetingTranscriptResult(text: "", status: .failed, engine: "x")
      }
    )
    XCTAssertEqual(primaryOK.text, "Hi")
    XCTAssertFalse(fallbackRan)
  }

  @MainActor
  func testQueuedMessagesCanReturnToComposerOrBeRemovedBeforeSending() async throws {
    let recorder = AIChatSuspendedSendRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-edit-queue-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )

    store.aiChatDraft = "first in flight"
    let firstSend = Task { await store.sendAIChatMessage() }
    await recorder.waitUntilStarted()

    store.aiChatDraft = "edit this queued message"
    var editSendReturned = false
    let editSend = Task { @MainActor in
      await store.sendAIChatMessage()
      editSendReturned = true
    }
    try await waitForCondition(timeout: 1) { editSendReturned }
    if !editSendReturned {
      if let queuedID = store.aiChatMessages.last?.id,
         store.isAIChatMessageQueued(queuedID) {
        store.deleteQueuedAIChatMessage(queuedID)
      }
      await recorder.finish(reply: "cleanup reply")
      await editSend.value
      await firstSend.value
      XCTFail("Queueing behind an active turn must return without waiting for that turn")
      return
    }
    await editSend.value
    let editMessage = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertTrue(store.isAIChatMessageQueued(editMessage.id))
    XCTAssertFalse(store.isAIChatMessageQueued(try XCTUnwrap(store.aiChatMessages.first?.id)))

    store.editQueuedAIChatMessage(editMessage.id)

    XCTAssertEqual(store.aiChatDraft, "edit this queued message")
    XCTAssertFalse(store.aiChatMessages.contains(where: { $0.id == editMessage.id }))
    XCTAssertEqual(store.aiChatQueuedMessageCount, 1)

    store.aiChatDraft = "delete this queued message"
    var deleteSendReturned = false
    let deleteSend = Task { @MainActor in
      await store.sendAIChatMessage()
      deleteSendReturned = true
    }
    try await waitForCondition(timeout: 1) { deleteSendReturned }
    if !deleteSendReturned {
      if let queuedID = store.aiChatMessages.last?.id,
         store.isAIChatMessageQueued(queuedID) {
        store.deleteQueuedAIChatMessage(queuedID)
      }
      await recorder.finish(reply: "cleanup reply")
      await deleteSend.value
      await firstSend.value
      XCTFail("Queueing behind an active turn must return without waiting for that turn")
      return
    }
    await deleteSend.value
    let deleteMessage = try XCTUnwrap(store.aiChatMessages.last)
    XCTAssertTrue(store.isAIChatMessageQueued(deleteMessage.id))

    store.deleteQueuedAIChatMessage(deleteMessage.id)

    XCTAssertFalse(store.aiChatMessages.contains(where: { $0.id == deleteMessage.id }))
    XCTAssertEqual(store.aiChatQueuedMessageCount, 1)

    await recorder.finish(reply: "first reply")
    await firstSend.value
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["first in flight", "first reply"])
  }

  @MainActor
  func testAIChatQueuedRepliesNotifyWhenInsertedBeforeLaterUserMessages() async throws {
    let recorder = AIChatQueuedSendRecorder()
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-queue-unread-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    var soundCount = 0
    store.aiChatIncomingMessageSoundPlayer = {
      soundCount += 1
    }
    store.selectedSurface = .agenda

    store.aiChatDraft = "first"
    let firstSend = Task { await store.sendAIChatMessage() }
    try await waitForCondition {
      store.isSendingAIChatMessage
    }
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)

    store.aiChatDraft = "second"
    let secondSend = Task { await store.sendAIChatMessage() }

    await firstSend.value
    await secondSend.value

    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:first",
      "assistant:reply 1",
      "user:second",
      "assistant:reply 2"
    ])
    XCTAssertEqual(store.aiChatThreads.first(where: { $0.id == threadID })?.unreadMessageCount, 2)
    XCTAssertEqual(store.aiChatUnreadMessageCount, 2)
    XCTAssertEqual(soundCount, 2)
  }

  @MainActor
  func testAIChatCanSendInAnotherThreadWhileCurrentThreadIsProcessing() async throws {
    let transcriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-parallel-threads-\(UUID().uuidString).json")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: transcriptURL,
      aiChatSendHandler: { messages, _, _, _ in
        try await Task.sleep(nanoseconds: 200_000_000)
        return "reply to \(messages.last?.content ?? "")"
      }
    )

    store.aiChatDraft = "first"
    let firstSend = Task { await store.sendAIChatMessage() }
    try await waitForCondition {
      store.isSendingAIChatMessage
    }
    let firstThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertEqual(store.aiChatSendingThreadIDs, [firstThreadID])

    store.createAIChatThread(runtime: .openClaw)

    let secondThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertNotEqual(firstThreadID, secondThreadID)
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatSendingThreadIDs, [firstThreadID])

    store.aiChatDraft = "second"
    let secondSend = Task { await store.sendAIChatMessage() }
    try await waitForCondition {
      store.isSendingAIChatMessage
    }
    XCTAssertTrue(store.aiChatSendingThreadIDs.contains(secondThreadID))

    await firstSend.value
    await secondSend.value

    store.selectAIChatThread(firstThreadID)
    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:first",
      "assistant:reply to first"
    ])

    store.selectAIChatThread(secondThreadID)
    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:second",
      "assistant:reply to second"
    ])
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatQueuedMessageCount, 0)
    XCTAssertTrue(store.aiChatSendingThreadIDs.isEmpty)
  }

  @MainActor
  func testAIChatTurnContinuesWhenSwitchingCorpora() async throws {
    let firstRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-origin-\(UUID().uuidString)", isDirectory: true)
    let secondRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-other-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: firstRoot)
      try? FileManager.default.removeItem(at: secondRoot)
    }

    let recorder = AIChatSuspendedSendRecorder()
    let suiteName = "org2-ai-chat-corpus-switch-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatFallbackTranscriptURL: firstRoot.appendingPathComponent("legacy-openclaw-chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      },
      legacyDefaultsDomains: []
    )
    store.aiChatTranscriptSaverForTesting = {}
    store.setCorpusRoot(firstRoot, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.aiChatDraft = "keep working"
    let send = Task { await store.sendAIChatMessage() }
    await recorder.waitUntilStarted()
    let originatingThreadID = try XCTUnwrap(store.selectedAIChatThreadID)

    store.setCorpusRoot(secondRoot, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()

    XCTAssertTrue(store.aiChatThreads.isEmpty)
    XCTAssertFalse(store.isSendingAIChatMessage)

    store.setCorpusRoot(firstRoot, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()

    XCTAssertEqual(store.selectedAIChatThreadID, originatingThreadID)
    XCTAssertTrue(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatMessages.first?.deliveryStatus, .sending)

    store.setCorpusRoot(secondRoot, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()

    await recorder.finish(reply: "finished in the background")
    await send.value
    XCTAssertTrue(store.aiChatThreads.isEmpty)

    store.setCorpusRoot(firstRoot, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()

    XCTAssertEqual(store.selectedAIChatThreadID, originatingThreadID)
    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:keep working",
      "assistant:finished in the background"
    ])
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatQueuedMessageCount, 0)
  }

  @MainActor
  func testActiveAlphaTurnRejectsWarmBetaSendWithSameThreadUUID() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-active-origin-collision-\(UUID().uuidString)", isDirectory: true)
    let alpha = base.appendingPathComponent("alpha", isDirectory: true)
    let beta = base.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let sharedThreadID = UUID()
    let alphaThread = AIChatThread(
      id: sharedThreadID,
      title: "Alpha thread",
      sessionKey: "alpha-thread",
      messages: []
    )
    let betaThread = AIChatThread(
      id: sharedThreadID,
      title: "Beta thread",
      sessionKey: "beta-thread",
      messages: []
    )
    let alphaTranscript = alpha.appendingPathComponent(".org2/openclaw-chat.json")
    let betaTranscript = beta.appendingPathComponent(".org2/openclaw-chat.json")
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [alphaThread],
        selectedThreadID: sharedThreadID,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: alphaTranscript
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [betaThread],
        selectedThreadID: sharedThreadID,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: betaTranscript
    )

    let recorder = AIChatSuspendedSendRecorder()
    let suiteName = "org2-ai-chat-active-origin-collision-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatFallbackTranscriptURL: base.appendingPathComponent("fallback.json"),
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      },
      legacyDefaultsDomains: []
    )

    store.setCorpusRoot(alpha, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.selectedAIChatThreadID, sharedThreadID)
    store.aiChatDraft = "alpha request"
    let alphaSend = Task { await store.sendAIChatMessage() }
    await recorder.waitUntilStarted()
    XCTAssertTrue(store.isSendingAIChatMessage)

    store.setCorpusRoot(beta, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()

    XCTAssertEqual(store.selectedAIChatThreadID, sharedThreadID)
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertFalse(store.isAIChatThreadRunning(sharedThreadID))
    XCTAssertTrue(store.aiChatSendingThreadIDs.isEmpty)
    XCTAssertEqual(store.aiChatQueuedMessageCount, 0)
    store.aiChatDraft = "beta draft must stay"
    store.attachAIChatAttachment(
      data: Data("beta attachment".utf8),
      fileName: "beta.txt",
      mimeType: "text/plain"
    )

    store.sendComposedAIChatMessage(text: "beta draft must stay")

    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertEqual(store.aiChatDraft, "beta draft must stay")
    XCTAssertEqual(store.aiChatPendingAttachments.map(\.fileName), ["beta.txt"])
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatQueuedMessageCount, 0)

    await recorder.finish(reply: "alpha completed")
    await alphaSend.value
    XCTAssertTrue(store.aiChatMessages.isEmpty)
    XCTAssertEqual(store.aiChatDraft, "beta draft must stay")
    XCTAssertEqual(store.aiChatPendingAttachments.map(\.fileName), ["beta.txt"])

    store.setCorpusRoot(alpha, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:alpha request",
      "assistant:alpha completed"
    ])
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatQueuedMessageCount, 0)
  }

  @MainActor
  func testActiveAlphaTurnRejectsColdBetaRemoteSendBeforeReportingAcceptance() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-ai-chat-active-origin-cold-remote-\(UUID().uuidString)", isDirectory: true)
    let alpha = base.appendingPathComponent("alpha", isDirectory: true)
    let beta = base.appendingPathComponent("beta", isDirectory: true)
    try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let sharedThreadID = UUID()
    let alphaThread = AIChatThread(
      id: sharedThreadID,
      title: "Alpha thread",
      sessionKey: "alpha-thread",
      messages: []
    )
    let betaSelected = AIChatThread(
      title: "Beta selected",
      sessionKey: "beta-selected",
      messages: [AIChatMessage(role: .assistant, content: "selected history")]
    )
    let betaWarm = (0..<16).map { index in
      AIChatThread(
        title: "Beta warm \(index)",
        sessionKey: "beta-warm-\(index)",
        messages: [AIChatMessage(role: .assistant, content: "warm \(index)")]
      )
    }
    let betaCold = AIChatThread(
      id: sharedThreadID,
      title: "Beta cold thread",
      sessionKey: "beta-cold-thread",
      messages: [AIChatMessage(role: .assistant, content: "beta history")]
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [alphaThread],
        selectedThreadID: sharedThreadID,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: alpha.appendingPathComponent(".org2/openclaw-chat.json")
    )
    try AIChatTranscriptStore.shared.flush(
      AIChatTranscriptSnapshot(
        threads: [betaSelected] + betaWarm + [betaCold],
        selectedThreadID: betaSelected.id,
        settlementSettings: AIChatThreadSettlementSettings()
      ),
      legacyURL: beta.appendingPathComponent(".org2/openclaw-chat.json")
    )

    let recorder = AIChatSuspendedSendRecorder()
    let suiteName = "org2-ai-chat-active-origin-cold-remote-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatFallbackTranscriptURL: base.appendingPathComponent("fallback.json"),
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      },
      legacyDefaultsDomains: []
    )

    store.setCorpusRoot(alpha, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    store.aiChatDraft = "alpha request"
    let alphaSend = Task { await store.sendAIChatMessage() }
    await recorder.waitUntilStarted()

    store.setCorpusRoot(beta, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.selectedAIChatThreadID, betaSelected.id)
    XCTAssertTrue(store.unloadedAIChatThreadIDsForTesting.contains(sharedThreadID))
    XCTAssertFalse(store.isSendingAIChatMessage)
    store.aiChatDraft = "beta local draft"
    store.attachAIChatAttachment(
      data: Data("beta local attachment".utf8),
      fileName: "beta-local.txt",
      mimeType: "text/plain"
    )
    let remoteAttachment = AIChatAttachment(
      fileName: "mobile.txt",
      mimeType: "text/plain",
      data: Data("mobile attachment".utf8)
    )

    let acceptedDestination = store.sendAIChatRemoteMessageDestination(
      "mobile request",
      attachments: [remoteAttachment],
      threadID: sharedThreadID
    )

    XCTAssertNil(acceptedDestination)
    XCTAssertTrue(store.unloadedAIChatThreadIDsForTesting.contains(sharedThreadID))
    XCTAssertEqual(store.aiChatDraft, "beta local draft")
    XCTAssertEqual(store.aiChatPendingAttachments.map(\.fileName), ["beta-local.txt"])
    XCTAssertFalse(store.isSendingAIChatMessage)
    XCTAssertEqual(store.aiChatQueuedMessageCount, 0)

    await recorder.finish(reply: "alpha completed")
    await alphaSend.value
    XCTAssertEqual(store.aiChatDraft, "beta local draft")
    XCTAssertEqual(store.aiChatPendingAttachments.map(\.fileName), ["beta-local.txt"])

    store.selectAIChatThread(sharedThreadID)
    await store.waitForAIChatThreadHydrationForTesting(sharedThreadID)
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["beta history"])
    XCTAssertTrue(store.aiChatMessages.allSatisfy(\.attachments.isEmpty))

    store.selectAIChatThread(betaSelected.id)
    XCTAssertEqual(store.aiChatDraft, "beta local draft")
    XCTAssertEqual(store.aiChatPendingAttachments.map(\.fileName), ["beta-local.txt"])

    store.setCorpusRoot(alpha, persistsDefault: false)
    await store.waitForAIChatTranscriptLoadForTesting()
    XCTAssertEqual(store.aiChatMessages.map { "\($0.role.rawValue):\($0.content)" }, [
      "user:alpha request",
      "assistant:alpha completed"
    ])
  }

  @MainActor
  func testAIChatScrollPositionPersistsAndResets() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-scroll-position-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "org2-openclaw-scroll-position-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      legacyDefaultsDomains: []
    )
    store.createAIChatThread(runtime: .openClaw)

    XCTAssertNil(store.aiChatScrollPosition)

    store.recordAIChatScrollPosition(0.42)
    XCTAssertEqual(try XCTUnwrap(store.aiChatScrollPosition), 0.42, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(store.aiChatScrollPosition(isAssistantPanel: false)), 0.42, accuracy: 0.001)

    store.recordAIChatScrollPosition(2)
    XCTAssertEqual(try XCTUnwrap(store.aiChatScrollPosition), 1, accuracy: 0.001)

    store.recordAIChatScrollPosition(0.25, isAssistantPanel: true)
    XCTAssertEqual(try XCTUnwrap(store.aiChatAssistantChatScrollPosition), 0.25, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(store.aiChatScrollPosition(isAssistantPanel: true)), 0.25, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(store.aiChatScrollPosition), 1, accuracy: 0.001)

    store.resetAIChat()
    XCTAssertNil(store.aiChatScrollPosition)
    XCTAssertNil(store.aiChatAssistantChatScrollPosition)
  }

  @MainActor
  func testReselectingPinnedAIChatThreadPreservesPositionWithoutNewGeneration() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Oldest"),
      AIChatMessage(role: .assistant, content: "Newest")
    ]
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.toggleAIChatThreadPin(threadID)
    store.recordAIChatScrollPosition(0)
    let previousGeneration = store.aiChatSelectionGeneration

    store.selectAIChatThread(threadID)

    XCTAssertEqual(store.selectedAIChatThreadID, threadID)
    XCTAssertTrue(store.selectedAIChatThread?.isPinned == true)
    XCTAssertEqual(try XCTUnwrap(store.aiChatScrollPosition), 0, accuracy: 0.001)
    XCTAssertEqual(store.aiChatSelectionGeneration, previousGeneration)
  }

  @MainActor
  func testScrollBridgeCanRecordOldThreadIdentityAfterSelectionChanges() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.aiChatMessages = [AIChatMessage(role: .assistant, content: "First")]
    let firstID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.recordAIChatScrollPosition(0.2, threadID: firstID)
    let secondID = store.createAIChatThread(runtime: .codex)

    // The still-mounted bridge reports its old coordinator identity after the
    // store has already published the new selection.
    store.recordAIChatScrollPosition(0.73, threadID: firstID)
    XCTAssertEqual(store.selectedAIChatThreadID, secondID)
    XCTAssertNil(store.aiChatScrollPosition(isAssistantPanel: false, threadID: secondID))
    XCTAssertEqual(
      try XCTUnwrap(store.aiChatScrollPosition(isAssistantPanel: false, threadID: firstID)),
      0.73,
      accuracy: 0.001
    )

    let previousCompletion = store.aiChatScrollRestorationCompletionGeneration
    store.completeAIChatScrollRestoration(threadID: secondID)
    XCTAssertEqual(store.lastCompletedAIChatScrollRestorationThreadID, secondID)
    XCTAssertEqual(
      store.aiChatScrollRestorationCompletionGeneration,
      previousCompletion + 1
    )
  }

  @MainActor
  func testAskAIChatAboutCurrentEntryInjectsMappedReference() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-ai-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "org2-workspace-ai-context-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let file = root.appendingPathComponent("daily.org2")
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.selectedEntrySource = EntrySource(
      file: file.path,
      startLine: 7,
      endLineExclusive: 11,
      text: "* Test\nbody",
      isSubtree: true
    )
    store.aiChatDraft = "What should I do next?"

    store.askAIChatAboutCurrentSelection()

    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertFalse(store.isAIChatAssistantPresented)
    let contextThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertEqual(store.aiChatThreads.count, 1)
    XCTAssertEqual(store.aiChatThreads.first?.title, "Ask: Test")
    XCTAssertEqual(
      store.aiChatDraft,
      "Use selected entry “Test” at /remote/org2/daily.org2:7 as context.\n\nWhat should I do next?"
    )
    XCTAssertEqual(store.aiChatStatusText, "Added daily.org2:7 to OpenClaw")

    store.askAIChatAboutCurrentSelection()
    XCTAssertEqual(store.selectedAIChatThreadID, contextThreadID)
    XCTAssertEqual(store.aiChatThreads.count, 1)
    XCTAssertEqual(
      store.aiChatDraft,
      "Use selected entry “Test” at /remote/org2/daily.org2:7 as context.\n\nWhat should I do next?"
    )

    store.performUndoCommand()
    XCTAssertEqual(store.aiChatDraft, "What should I do next?")
    XCTAssertEqual(store.aiChatStatusText, "Undid OpenClaw draft change")

    store.performRedoCommand()
    XCTAssertEqual(
      store.aiChatDraft,
      "Use selected entry “Test” at /remote/org2/daily.org2:7 as context.\n\nWhat should I do next?"
    )
    XCTAssertEqual(store.aiChatStatusText, "Redid OpenClaw draft change")
  }

  @MainActor
  func testAskAIChatAboutMultipleEntriesReusesEmptyContextThread() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-multiple-ai-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "org2-workspace-multiple-ai-context-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      legacyDefaultsDomains: []
    )
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.selectedEntrySource = EntrySource(
      file: root.appendingPathComponent("launch.org2").path,
      startLine: 3,
      endLineExclusive: 5,
      text: "* Launch risks\nDetails",
      isSubtree: true
    )

    store.askAIChatAboutCurrentSelection()
    store.selectedRenderedBlocks = []
    store.selectedBlockID = nil
    store.selectedEntrySource = EntrySource(
      file: root.appendingPathComponent("deploy.org2").path,
      startLine: 9,
      endLineExclusive: 11,
      text: "* Deployment checklist\nDetails",
      isSubtree: true
    )
    store.askAIChatAboutCurrentSelection()

    XCTAssertEqual(store.aiChatThreads.count, 1)
    let presentation = AIChatContextPresentation(store.aiChatDraft)
    XCTAssertEqual(presentation.contexts.map(\.title), ["Deployment checklist", "Launch risks"])
    XCTAssertEqual(presentation.contexts.map(\.reference), [
      "/remote/org2/deploy.org2:9",
      "/remote/org2/launch.org2:3"
    ])
  }

  @MainActor
  func testSelectedFilesStartFreshAIThreadWithEveryFileAsContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-file-multi-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("launch.org2")
    let secondURL = root.appendingPathComponent("pricing.org2")
    try "#+TITLE: Launch\n".write(to: firstURL, atomically: true, encoding: .utf8)
    try "#+TITLE: Pricing\n".write(to: secondURL, atomically: true, encoding: .utf8)
    let first = CorpusFile(
      path: firstURL.path,
      relativePath: "launch.org2",
      modifiedAt: nil,
      byteCount: nil
    )
    let second = CorpusFile(
      path: secondURL.path,
      relativePath: "pricing.org2",
      modifiedAt: nil,
      byteCount: nil
    )

    let suiteName = "org2-workspace-file-multi-context-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.corpusFiles = [first, second]
    store.handleCorpusFileClick(first)
    store.handleCorpusFileClick(second, modifiers: [.command])

    store.startNewAIThreadFromCorpusFileSelection(including: second)

    let presentation = AIChatContextPresentation(store.aiChatDraft)
    XCTAssertEqual(presentation.contexts.map(\.title), ["launch", "pricing"])
    XCTAssertEqual(presentation.contexts.map(\.reference), [
      "/remote/org2/launch.org2:1",
      "/remote/org2/pricing.org2:1"
    ])
    XCTAssertEqual(store.selectedAIChatThread?.title, "Context: 2 selected items")
  }

  @MainActor
  func testComposerFileMentionAddsExistingContextPillWithoutDuplication() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-composer-file-mention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appendingPathComponent("example-reviewer.org2")
    try "#+TITLE: Example Reviewer\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let file = CorpusFile(
      path: fileURL.path,
      relativePath: "agents/example-reviewer.org2",
      modifiedAt: nil,
      byteCount: nil
    )
    let suiteName = "org2-composer-file-mention-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.setCorpusRoot(root, persistsDefault: false)
    store.openClawRemoteCorpusPath = "/remote/org2"

    let firstDraft = store.aiChatDraftByAddingCorpusFileContext(
      file,
      to: "Please review this."
    )
    let firstPresentation = AIChatContextPresentation(firstDraft)
    XCTAssertEqual(firstPresentation.contexts.map(\.kind), ["selected file"])
    XCTAssertEqual(firstPresentation.contexts.map(\.title), ["example reviewer"])
    XCTAssertEqual(firstPresentation.contexts.map(\.reference), [
      "/remote/org2/example-reviewer.org2:1"
    ])
    XCTAssertEqual(firstPresentation.userText, "Please review this.")

    let duplicateDraft = store.aiChatDraftByAddingCorpusFileContext(file, to: firstDraft)
    XCTAssertEqual(duplicateDraft, firstDraft)
    XCTAssertEqual(AIChatContextPresentation(duplicateDraft).contexts.count, 1)
  }

  @MainActor
  func testAskAIChatAboutCurrentSelectionPrefersSelectedRenderedBlock() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-ai-block-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "org2-workspace-ai-block-context-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let file = root.appendingPathComponent("project.org2")
    let source = EntrySource(
      file: file.path,
      startLine: 12,
      endLineExclusive: 16,
      text: """
      * Project
      First paragraph
      Second paragraph
      """,
      isSubtree: true
    )
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.selectedEntrySource = source
    store.selectedRenderedBlocks = OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)
    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first { block in
      if case .paragraph = block.rendered {
        return block.rawText.contains("First paragraph")
      }
      return false
    })
    store.selectBlock(paragraph)

    store.askAIChatAboutCurrentSelection()

    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.selectedBlockID, paragraph.id)
    XCTAssertEqual(store.aiChatThreads.count, 1)
    XCTAssertEqual(store.aiChatThreads.first?.title, "Ask: First paragraph")
    XCTAssertEqual(
      store.aiChatDraft,
      "Use selected block “First paragraph” at /remote/org2/project.org2:13-14 as context.\n\n"
    )
    XCTAssertEqual(store.aiChatStatusText, "Added project.org2:13-14 to OpenClaw")
  }

  @MainActor
  func testAskAIFromDetailContinuesChatAlreadyOpenInOtherPane() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-ai-existing-pane-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "org2-ai-existing-pane-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      legacyDefaultsDomains: []
    )
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    let threadID = store.createAIChatThread(runtime: .codex)
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Keep this conversation")
    ]
    store.selectedEntrySource = EntrySource(
      file: root.appendingPathComponent("notes/plan.org").path,
      startLine: 4,
      endLineExclusive: 7,
      text: "* Plan\nDetails",
      isSubtree: true
    )
    store.makeSurfacePrimary(.aiChat)

    store.askAIChatAboutCurrentSelection()

    XCTAssertEqual(store.selectedAIChatThreadID, threadID)
    XCTAssertEqual(store.aiChatThreads.count, 1)
    XCTAssertEqual(store.aiChatThreads.first?.messages.count, 1)
    XCTAssertEqual(
      store.aiChatDraft,
      "Use selected entry “Plan” at /remote/org2/notes/plan.org:4 as context.\n\n"
    )
  }

  @MainActor
  func testAskAIChatAboutRenderedHTMLHeadingUsesExactSourceBlock() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-html-heading-ai-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("project.org2")
    let source = EntrySource(
      file: file.path,
      startLine: 20,
      endLineExclusive: 25,
      text: """
      * Parent
      Parent body
      ** Target heading
      Target body
      """,
      isSubtree: true
    )
    let suiteName = "org2-html-heading-ai-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      legacyDefaultsDomains: []
    )
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.selectedEntrySource = source
    store.selectedRenderedBlocks = OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)

    store.askAIChatAboutSourceHeading(at: 22)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first { $0.startLine == 22 })
    XCTAssertEqual(store.selectedBlockID, heading.id)
    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.aiChatDraft, "Use selected block “Target heading” at /remote/org2/project.org2:22 as context.\n\n")
    XCTAssertEqual(store.aiChatStatusText, "Added project.org2:22 to OpenClaw")
  }

  @MainActor
  func testAskAIChatAboutRenderedBoldSectionUsesExactSourceBlock() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-html-section-ai-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("board.org2")
    let source = EntrySource(
      file: file.path,
      startLine: 40,
      endLineExclusive: 43,
      text: "*Revenue*\n\nRevenue body",
      isSubtree: false
    )
    let suiteName = "org2-html-section-ai-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      legacyDefaultsDomains: []
    )
    store.corpusRoot = root
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.selectedEntrySource = source
    store.selectedRenderedBlocks = OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)

    store.askAIChatAboutSourceHeading(at: 40)

    let section = try XCTUnwrap(store.selectedRenderedBlocks.first { $0.startLine == 40 })
    XCTAssertEqual(store.selectedBlockID, section.id)
    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.aiChatDraft, "Use selected block “Revenue” at /remote/org2/board.org2:40 as context.\n\n")
  }

  func testAIChatFileReferenceExtractsOrgPaths() {
    let refs = AIChatFileReference.extract(from: """
    Check /srv/org2/notes/alice.org2:42 and notes/daily/2026-06-12.org.
    Also [thread](file:///srv/org2/threads/follow-up.org2#9).
    Ranges work at /srv/org2/notes/range.org2:12-18 and /srv/org2/notes/github.org2#L21-L24.
    """)

    XCTAssertEqual(refs.map(\.path), [
      "/srv/org2/notes/alice.org2",
      "notes/daily/2026-06-12.org",
      "/srv/org2/threads/follow-up.org2",
      "/srv/org2/notes/range.org2",
      "/srv/org2/notes/github.org2"
    ])
    XCTAssertEqual(refs.map(\.line), [42, nil, 9, 12, 21])
    XCTAssertEqual(refs[0].displayTitle, "alice.org2:42")
  }

  func testOrgInlineParserRendersCodeAndOrgBracketLinks() {
    let spans = OrgInlineParser.parse("Plate `8CJB731` from [[/srv/org2/personal.org:58][personal.org]].")

    XCTAssertEqual(spans, [
      .text("Plate "),
      .code("8CJB731"),
      .text(" from "),
      .link(
        label: "personal.org",
        target: "/srv/org2/personal.org:58",
        fileReference: AIChatFileReference(path: "/srv/org2/personal.org", line: 58)
      ),
      .text(".")
    ])
  }

  func testRenderedListTextRendersBacktickCodeShorthand() throws {
    let raw = "- Assign an owner using the `ASSIGNEE` property."
    let block = try XCTUnwrap(OrgEntryRenderer.parseEditable(raw).first)
    guard case .listItem(_, _, _, let fallback) = block.rendered else {
      return XCTFail("Expected list item")
    }

    let listText = OrgRenderedLineDisplayCache.listText(rawText: block.rawText, fallback: fallback)
    XCTAssertEqual(OrgInlineParser.parse(listText), [
      .text("Assign an owner using the "),
      .code("ASSIGNEE"),
      .text(" property.")
    ])
  }

  func testOrgInlineParserRendersMarkdownFileCitationsInline() {
    let spans = OrgInlineParser.parse("Found in [personal.org](/workspace/org2/personal.org:58-63).")

    XCTAssertEqual(spans, [
      .text("Found in "),
      .link(
        label: "personal.org",
        target: "/workspace/org2/personal.org:58-63",
        fileReference: AIChatFileReference(path: "/workspace/org2/personal.org", line: 58)
      ),
      .text(".")
    ])
  }

  func testOrgInlineParserResolvesRoamIDAndWikiLinks() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-roam-links-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let alpha = root.appendingPathComponent("alpha.org2")
    let beta = root.appendingPathComponent("beta.org2")
    try """
    #+TITLE: Alpha Node
    #+ROAM_ALIASES: "A Node"
    :PROPERTIES:
    :ID: alpha-123
    :END:

    * Beta Heading
    :PROPERTIES:
    :ID: beta-456
    :END:
    """.write(to: alpha, atomically: true, encoding: .utf8)
    try """
    #+TITLE: Duplicate
    :PROPERTIES:
    :ID: duplicate-1
    :END:
    """.write(to: beta, atomically: true, encoding: .utf8)

    let resolver = WorkspaceStore.buildOrgRoamLinkResolver(files: [
      CorpusFile(path: alpha.path, relativePath: "alpha.org2", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: beta.path, relativePath: "beta.org2", modifiedAt: nil, byteCount: nil)
    ])

    XCTAssertEqual(
      OrgInlineParser.parse("See [[id:beta-456][Beta]] and [[A Node]].", linkResolver: resolver),
      [
        .text("See "),
        .link(
          label: "Beta",
          target: "id:beta-456",
          fileReference: AIChatFileReference(path: alpha.path, line: 7)
        ),
        .text(" and "),
        .link(
          label: "A Node",
          target: "A Node",
          fileReference: AIChatFileReference(path: alpha.path, line: 1)
        ),
        .text(".")
      ]
    )

    XCTAssertEqual(
      OrgInlineParser.parse("See [[id:alpha-123]].", linkResolver: resolver),
      [
        .text("See "),
        .link(
          label: "Alpha Node",
          target: "id:alpha-123",
          fileReference: AIChatFileReference(path: alpha.path, line: 1)
        ),
        .text(".")
      ]
    )
  }

  func testOrgInlineParserResolvesWikiLinksToFileStemNodes() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-roam-file-stem-links-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sarah = root.appendingPathComponent("Sarah.org")
    try "Notes about Sarah\n".write(to: sarah, atomically: true, encoding: .utf8)

    let resolver = WorkspaceStore.buildOrgRoamLinkResolver(files: [
      CorpusFile(path: sarah.path, relativePath: "Sarah.org", modifiedAt: nil, byteCount: nil)
    ])

    XCTAssertEqual(
      OrgInlineParser.parse("Talk to [[Sarah]].", linkResolver: resolver),
      [
        .text("Talk to "),
        .link(
          label: "Sarah",
          target: "Sarah",
          fileReference: AIChatFileReference(path: sarah.path, line: 1)
        ),
        .text(".")
      ]
    )
  }

  func testOrgInlineRenderedTextLinkMapUsesRenderedLabelsForHitRanges() throws {
    let node = OrgRoamNodeReference(
      idValue: "alpha-123",
      title: "Alpha Node",
      file: "/tmp/alpha.org2",
      line: 7
    )
    let resolver = OrgRoamLinkResolver(nodes: [node])
    let map = OrgInlineRenderedTextLinkMap.make(
      raw: "See [[id:alpha-123]] and https://example.com/docs.",
      linkResolver: resolver
    )

    XCTAssertEqual(map.displayText, "See Alpha Node and https://example.com/docs.")
    XCTAssertEqual(map.links.map(\.label), ["Alpha Node", "https://example.com/docs"])
    XCTAssertEqual(map.links.map(\.displayRange), [
      NSRange(location: 4, length: 10),
      NSRange(location: 19, length: 24)
    ])

    let firstURL = try XCTUnwrap(map.link(atDisplayUTF16Location: 4)?.url)
    let firstReference = try XCTUnwrap(AIChatFileReference.fromDeepLinkURL(firstURL))
    XCTAssertEqual(firstReference, AIChatFileReference(path: "/tmp/alpha.org2", line: 7))
    XCTAssertEqual(map.link(atDisplayUTF16Location: 13)?.url, firstURL)
    XCTAssertNil(map.link(atDisplayUTF16Location: 3))
    XCTAssertNil(map.link(atDisplayUTF16Location: 43))
    XCTAssertEqual(map.link(atDisplayUTF16Location: 19)?.url, URL(string: "https://example.com/docs"))
  }

  func testOrgInlineAttributedLinksDescribeTheirDestinationOnHover() throws {
    let rendered = OrgInlineAttributedString.make([
      .link(
        label: "Project brief",
        target: "id:project-brief",
        fileReference: AIChatFileReference(path: "/tmp/notes/project.org2", line: 17)
      ),
      .text(" and "),
      .link(
        label: "documentation",
        target: "https://example.com/reference",
        fileReference: nil
      )
    ])
    let attributed = NSAttributedString(rendered)

    XCTAssertEqual(
      attributed.attribute(.toolTip, at: 0, effectiveRange: nil) as? String,
      "Org document\n/tmp/notes/project.org2 · line 17"
    )
    XCTAssertEqual(
      attributed.attribute(.toolTip, at: 18, effectiveRange: nil) as? String,
      "External link\nhttps://example.com/reference"
    )
  }

  func testOrgInlineLinkTooltipKeepsLongDestinationEndsVisible() {
    let target = "https://example.com/" + String(repeating: "deep-path/", count: 16) + "destination.org2"
    let tooltip = OrgInlineLinkTooltip.text(target: target, fileReference: nil)

    XCTAssertTrue(tooltip.hasPrefix("External link\nhttps://example.com/"))
    XCTAssertTrue(tooltip.contains("…"))
    XCTAssertTrue(tooltip.hasSuffix("destination.org2"))
    XCTAssertLessThanOrEqual(tooltip.split(separator: "\n").last?.count ?? .max, 96)
  }

  func testOrgInlineParserExpandsCorpusLinearLinkAbbreviations() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-linear-links-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try """
    {
      "links": {
        "linearTeam": "scarf",
        "abbreviations": {
          "linear": "https://linear.app/scarf/issue/%s"
        }
      }
    }
    """.write(
      to: root.appendingPathComponent("org2.json"),
      atomically: true,
      encoding: .utf8
    )
    let source = root.appendingPathComponent("ticket.org2")
    try """
    * APP-21273
    - [[linear:APP-21273][APP-21273: Load document export history without waiting for per-export storage checks]]
    """.write(to: source, atomically: true, encoding: .utf8)

    let resolver = WorkspaceStore.buildOrgRoamLinkResolver(
      files: [CorpusFile(
        path: source.path,
        relativePath: "ticket.org2",
        modifiedAt: nil,
        byteCount: nil
      )],
      corpusRoot: root
    )
    let raw = "[[linear:APP-21273][APP-21273: Load document export history without waiting for per-export storage checks]]"
    let expectedURL = URL(string: "https://linear.app/scarf/issue/APP-21273")

    XCTAssertEqual(OrgInlineParser.parse(raw, linkResolver: resolver), [
      .link(
        label: "APP-21273: Load document export history without waiting for per-export storage checks",
        target: expectedURL!.absoluteString,
        fileReference: nil
      )
    ])
    let renderedLink = OrgInlineRenderedTextLinkMap.make(raw: raw, linkResolver: resolver)
    XCTAssertEqual(
      renderedLink.displayText,
      "APP-21273: Load document export history without waiting for per-export storage checks"
    )
    XCTAssertEqual(renderedLink.links.first?.url, expectedURL)
  }

  func testOrgHTMLDocumentLinkRoutingExpandsConfiguredExternalLinkAbbreviation() {
    let resolver = OrgRoamLinkResolver(
      nodes: [],
      linkAbbreviations: OrgLinkAbbreviations(linearTeam: "scarf")
    )

    XCTAssertEqual(
      OrgHTMLDocumentLinkRouting.externalURL(for: "linear:APP-21287", linkResolver: resolver),
      URL(string: "https://linear.app/scarf/issue/APP-21287")
    )
    XCTAssertNil(
      OrgHTMLDocumentLinkRouting.externalURL(for: "file:notes/ticket.org2", linkResolver: resolver)
    )
  }

  func testOrgRoamLinkResolverDoesNotGuessAmbiguousWikiLinks() {
    let resolver = OrgRoamLinkResolver(nodes: [
      OrgRoamNodeReference(idValue: "one", title: "Shared", file: "/tmp/one.org2", line: 1),
      OrgRoamNodeReference(idValue: "two", title: "Shared", file: "/tmp/two.org2", line: 1)
    ])

    XCTAssertNil(resolver.resolve(target: "Shared"))
    XCTAssertEqual(
      resolver.resolve(target: "id:one"),
      OrgRoamResolvedLink(
        title: "Shared",
        fileReference: AIChatFileReference(path: "/tmp/one.org2", line: 1)
      )
    )
  }

  func testOrgRoamLinkResolverAllowsPunctuationInWikiTitles() {
    let resolver = OrgRoamLinkResolver(nodes: [
      OrgRoamNodeReference(idValue: "punctuation", title: "Project: Alpha/Beta", file: "/tmp/project.org2", line: 12)
    ])

    XCTAssertEqual(
      resolver.resolve(target: "Project: Alpha/Beta"),
      OrgRoamResolvedLink(
        title: "Project: Alpha/Beta",
        fileReference: AIChatFileReference(path: "/tmp/project.org2", line: 12)
      )
    )
  }

  func testOrgRoamLinkResolverRanksPagesBeforeEntryNodes() {
    let page = OrgRoamNodeReference(
      idValue: nil,
      title: "Sarah",
      file: "/tmp/Sarah.org",
      line: 1,
      isPageNode: true
    )
    let olderEntry = OrgRoamNodeReference(
      idValue: "older-sarah",
      title: "Sarah",
      file: "/tmp/2023-08-31.org",
      line: 12
    )
    let personalEntry = OrgRoamNodeReference(
      idValue: "personal-sarah",
      title: "Sarah",
      file: "/tmp/personal.org",
      line: 44
    )

    let resolver = OrgRoamLinkResolver(nodes: [olderEntry, personalEntry, page])

    XCTAssertEqual(resolver.searchCandidates(matching: "sarah", limit: 3).first, page)
    XCTAssertEqual(resolver.exactCandidates(for: "Sarah").first, page)
  }

  func testParagraphWikiLinkCompletionReplacesPartialLinkWithStableNodeLink() {
    let text = "Talk to [[Sar"
    let match = ParagraphWikiLinkCompletion.match(
      in: text,
      selectedRange: NSRange(location: (text as NSString).length, length: 0)
    )
    let node = OrgRoamNodeReference(
      idValue: "sarah-123",
      title: "Sarah",
      file: "/tmp/Sarah.org",
      line: 1
    )

    let edit = match.flatMap {
      ParagraphWikiLinkCompletion.replacement(in: text, match: $0, node: node)
    }

    XCTAssertEqual(edit?.text, "Talk to [[id:sarah-123][Sarah]]")
    XCTAssertEqual(edit?.selectedRange.location, ("Talk to [[id:sarah-123][Sarah]]" as NSString).length)
    XCTAssertEqual(edit?.selectedRange.length, 0)
  }

  func testParagraphWikiLinkCompletionPreservesTrailingHeadingText() {
    let text = "Wallet rec from [[sarah : Secrid"
    let match = ParagraphWikiLinkCompletion.match(
      in: text,
      selectedRange: NSRange(location: (text as NSString).length, length: 0)
    )
    let node = OrgRoamNodeReference(
      idValue: "sarah-123",
      title: "Sarah",
      file: "/tmp/Sarah.org",
      line: 1
    )

    let edit = match.flatMap {
      ParagraphWikiLinkCompletion.replacement(in: text, match: $0, node: node)
    }

    XCTAssertEqual(match?.query, "sarah")
    XCTAssertEqual(edit?.text, "Wallet rec from [[id:sarah-123][Sarah]] : Secrid")
    XCTAssertEqual(edit?.selectedRange.location, ("Wallet rec from [[id:sarah-123][Sarah]]" as NSString).length)
    XCTAssertEqual(edit?.selectedRange.length, 0)
  }

  func testOrgInlineParserFastPathsPlainTextButKeepsRelativeFileReferences() {
    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate("Plain sentence with no org syntax here."))
    XCTAssertFalse(OrgInlineText.usesAttributedRendering("Plain sentence with no org syntax here."))
    XCTAssertEqual(
      OrgInlineParser.parse("Plain sentence with no org syntax here."),
      [.text("Plain sentence with no org syntax here.")]
    )
    XCTAssertTrue(OrgInlineText.usesAttributedRendering("Review [[id:abc][Alice]] soon."))
    XCTAssertTrue(OrgInlineText.usesAttributedRendering("See agenda.org for context."))
    XCTAssertFalse(OrgInlineText.usesAttributedRendering(String(repeating: "plain text ", count: 1_000)))

    let longLinkedText = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 120)
    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(longLinkedText))
    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(
      longLinkedText,
      near: NSRange(location: 6, length: 0),
      radius: 64
    ))
    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate(
      longLinkedText,
      near: NSRange(location: (longLinkedText as NSString).length, length: 0),
      radius: 64
    ))
    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate(
      longLinkedText,
      near: NSRange(location: (longLinkedText as NSString).length + 10_000, length: 0),
      radius: 64
    ))
    let longTrailingURL = String(repeating: "plain text ", count: 400) + "see HTTPS://example.com"
    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(
      longTrailingURL,
      near: NSRange(location: (longTrailingURL as NSString).length - 8, length: 0),
      radius: 64
    ))
    let unicodeLinkedText = String(repeating: "🙂 ", count: 20) + "See [[id:abc][Alice]]."
    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(
      unicodeLinkedText,
      near: NSRange(location: (String(repeating: "🙂 ", count: 20) as NSString).length + 8, length: 0),
      radius: 32
    ))
    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate(
      unicodeLinkedText,
      near: NSRange(location: 1, length: 0),
      radius: 4
    ))

    let spans = OrgInlineParser.parse("See notes/daily/2026-06-12.org:7 for context.")
    XCTAssertEqual(spans, [
      .text("See "),
      .link(
        label: "2026-06-12.org:7",
        target: "notes/daily/2026-06-12.org",
        fileReference: AIChatFileReference(path: "notes/daily/2026-06-12.org", line: 7)
      ),
      .text(" for context.")
    ])
  }

  func testOrgInlineSyntaxCandidateCacheUsesExactText() {
    let plain = "Plain sentence with no inline syntax."
    let rich = "See [[id:abc][Alice]] and `code`."
    let longPlain = String(repeating: "plain text ", count: 20)
    let longRich = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 20)
    let plainKey = OrgInlineSyntaxCandidateCache.CacheKey(raw: plain)
    let matchingPlainKey = OrgInlineSyntaxCandidateCache.CacheKey(raw: plain)
    let differentKey = OrgInlineSyntaxCandidateCache.CacheKey(raw: plain + " ")

    XCTAssertEqual(plainKey, matchingPlainKey)
    XCTAssertEqual(plainKey.hash, matchingPlainKey.hash)
    XCTAssertNotEqual(plainKey, differentKey)
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.shouldCacheLookup(plain))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.shouldCacheLookup(rich))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.shouldCacheLookup(longPlain))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.shouldCacheLookup(longRich))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.containsSyntax(plain))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.containsSyntax(plain))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.containsSyntax(rich))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.containsSyntax(rich))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.containsSyntax(longPlain))
    XCTAssertFalse(OrgInlineSyntaxCandidateCache.containsSyntax(longPlain))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.containsSyntax(longRich))
    XCTAssertTrue(OrgInlineSyntaxCandidateCache.containsSyntax(longRich))
  }

  func testOrgInlineParserRendersMarkupAndTimestamps() {
    let spans = OrgInlineParser.parse("Review *bold* /soon/ on <2026-06-12 Fri 09:30-10:00> with ~code~.")

    XCTAssertEqual(spans, [
      .text("Review "),
      .bold("bold"),
      .text(" "),
      .italic("soon"),
      .text(" on "),
      .timestamp(OrgInlineTimestamp(
        raw: "<2026-06-12 Fri 09:30-10:00>",
        dateLabel: "Jun 12, 2026",
        timeLabel: "09:30-10:00"
      )),
      .text(" with "),
      .code("code"),
      .text(".")
    ])
  }

  @MainActor
  func testOrgInlineAttributedStringCacheKeysUseExactTextAndFont() {
    let raw = "See [[id:abc][Alice]] and `code`."
    let key = OrgInlineAttributedString.CacheKey(raw: raw, baseFont: .body)
    let matching = OrgInlineAttributedString.CacheKey(raw: raw, baseFont: .body)
    let differentRaw = OrgInlineAttributedString.CacheKey(raw: raw + " ", baseFont: .body)
    let differentFont = OrgInlineAttributedString.CacheKey(raw: raw, fontDescription: "different-font")

    XCTAssertEqual(key, matching)
    XCTAssertEqual(key.hash, matching.hash)
    XCTAssertNotEqual(key, differentRaw)
    XCTAssertNotEqual(key, differentFont)
    XCTAssertEqual(
      OrgInlineAttributedString.cached(raw: raw, baseFont: .body),
      OrgInlineAttributedString.cached(raw: raw, baseFont: .body)
    )

    let longRaw = "See [[id:abc][Alice]]. " + String(repeating: "Long rich line ", count: 300)
    let longKey = OrgInlineAttributedString.CacheKey(raw: longRaw, baseFont: .body)
    let matchingLongKey = OrgInlineAttributedString.CacheKey(raw: longRaw, baseFont: .body)
    XCTAssertEqual(longKey, matchingLongKey)
    XCTAssertEqual(longKey.hash, matchingLongKey.hash)
  }

  func testOrgInlineAttributedStringHighlightsSearchMatches() throws {
    let raw = "First Alpha, second alpha."
    let highlighted = OrgInlineAttributedString.highlightingSearchMatches(
      in: OrgInlineAttributedString.plain(raw, baseFont: .body),
      query: "alpha"
    )
    let display = String(highlighted.characters)
    let firstRange = try XCTUnwrap(display.range(of: "Alpha"))
    let secondRange = try XCTUnwrap(display.range(of: "alpha", options: [], range: firstRange.upperBound..<display.endIndex))
    let firstLower = try XCTUnwrap(AttributedString.Index(firstRange.lowerBound, within: highlighted))
    let firstUpper = try XCTUnwrap(AttributedString.Index(display.index(after: firstRange.lowerBound), within: highlighted))
    let secondLower = try XCTUnwrap(AttributedString.Index(secondRange.lowerBound, within: highlighted))
    let secondUpper = try XCTUnwrap(AttributedString.Index(display.index(after: secondRange.lowerBound), within: highlighted))

    XCTAssertNotNil(highlighted[firstLower..<firstUpper].backgroundColor)
    XCTAssertNotNil(highlighted[secondLower..<secondUpper].backgroundColor)
  }

  func testOrgInlineAttributedStringHighlightsRenderedLinkLabels() throws {
    let raw = "See [Important Node](https://example.com)."
    let attributed = OrgInlineAttributedString.make(OrgInlineParser.parse(raw), baseFont: .body)
    let highlighted = OrgInlineAttributedString.highlightingSearchMatches(in: attributed, query: "important")
    let display = String(highlighted.characters)
    let range = try XCTUnwrap(display.range(of: "Important"))
    let lower = try XCTUnwrap(AttributedString.Index(range.lowerBound, within: highlighted))
    let upper = try XCTUnwrap(AttributedString.Index(display.index(after: range.lowerBound), within: highlighted))

    XCTAssertNotNil(highlighted[lower..<upper].backgroundColor)
    XCTAssertEqual(highlighted[lower..<upper].link, URL(string: "https://example.com"))
  }

  func testOrgInlineAttributedStringRendersColorBindingsAsNonNavigatingText() throws {
    let raw = "[[color:fg=white;bg=#b42318][Blocked]]"
    let attributed = OrgInlineAttributedString.make(OrgInlineParser.parse(raw), baseFont: .body)
    let display = String(attributed.characters)
    XCTAssertEqual(display, "Blocked")
    let lower = try XCTUnwrap(AttributedString.Index(display.startIndex, within: attributed))
    let upper = try XCTUnwrap(AttributedString.Index(display.endIndex, within: attributed))

    XCTAssertNotNil(attributed[lower..<upper].foregroundColor)
    XCTAssertNotNil(attributed[lower..<upper].backgroundColor)
    XCTAssertNil(attributed[lower..<upper].link)
  }

  func testOrgSyntaxHighlighterFindsEditableDocumentTokens() {
    let raw = """
    * TODO [#A] Review [[id:11111111-1111-4111-8111-111111111111][Alice]] :work:
    SCHEDULED: <2026-06-12 Fri 09:30>
    :OWNER: agent
    Body with `code`, *emphasis*, and [Docs](https://example.com/docs).
    #+begin_src swift
    let value = 1
    #+end_src
    """

    let tokens = OrgSyntaxHighlighter.tokens(in: raw)

    assertToken(.headingStars, "*", in: raw, tokens: tokens)
    assertToken(.headingTitle, "Review [[id:11111111-1111-4111-8111-111111111111][Alice]]", in: raw, tokens: tokens)
    assertToken(.todo, "TODO", in: raw, tokens: tokens)
    assertToken(.priority, "[#A]", in: raw, tokens: tokens)
    assertToken(.link, "[[id:11111111-1111-4111-8111-111111111111][Alice]]", in: raw, tokens: tokens)
    assertToken(.linkTarget, "id:11111111-1111-4111-8111-111111111111", in: raw, tokens: tokens)
    assertToken(.link, "[Docs](https://example.com/docs)", in: raw, tokens: tokens)
    assertToken(.linkTarget, "https://example.com/docs", in: raw, tokens: tokens)
    assertToken(.tag, ":work:", in: raw, tokens: tokens)
    assertToken(.planningKeyword, "SCHEDULED", in: raw, tokens: tokens)
    assertToken(.timestamp, "<2026-06-12 Fri 09:30>", in: raw, tokens: tokens)
    assertToken(.propertyKey, "OWNER", in: raw, tokens: tokens)
    assertToken(.code, "`code`", in: raw, tokens: tokens)
    assertToken(.emphasis, "*emphasis*", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "`", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "[[", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "][", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "]]", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, "<", in: raw, tokens: tokens)
    assertToken(.syntaxDelimiter, ">", in: raw, tokens: tokens)
    assertToken(.keyword, "begin_src", in: raw, tokens: tokens)
    assertToken(.keyword, "end_src", in: raw, tokens: tokens)
  }

  func testOrgSyntaxHighlighterDifferentiatesOpenDoneAndCanceledHeadings() {
    let raw = """
    * TODO Write the draft
    ** DONE Ship the fix :work:
    ** CANCELED Old plan
    *** CANCELLED British spelling
    """
    let tokens = OrgSyntaxHighlighter.tokens(in: raw)
    assertToken(.todo, "TODO", in: raw, tokens: tokens)
    assertToken(.headingTitle, "Write the draft", in: raw, tokens: tokens)
    assertToken(.doneTodo, "DONE", in: raw, tokens: tokens)
    assertToken(.doneHeadingTitle, "Ship the fix", in: raw, tokens: tokens)
    assertToken(.canceledTodo, "CANCELED", in: raw, tokens: tokens)
    assertToken(.canceledHeadingTitle, "Old plan", in: raw, tokens: tokens)
    assertToken(.canceledTodo, "CANCELLED", in: raw, tokens: tokens)
    assertToken(.canceledHeadingTitle, "British spelling", in: raw, tokens: tokens)

    for monospaced in [true, false] {
      let storage = NSTextStorage(string: raw)
      OrgSyntaxHighlighter.apply(to: storage, monospaced: monospaced)
      let ns = raw as NSString
      func color(_ text: String) -> NSColor? {
        storage.attribute(.foregroundColor, at: ns.range(of: text).location, effectiveRange: nil) as? NSColor
      }
      func strike(_ text: String) -> Int? {
        storage.attribute(.strikethroughStyle, at: ns.range(of: text).location, effectiveRange: nil) as? Int
      }
      XCTAssertNotEqual(color("TODO"), color("DONE"))
      XCTAssertNotEqual(color("DONE"), color("CANCELED"))
      XCTAssertEqual(color("Ship the fix"), NSColor.secondaryLabelColor)
      XCTAssertEqual(color("Old plan"), NSColor.tertiaryLabelColor)
      XCTAssertNil(strike("Write the draft"))
      XCTAssertNil(strike("Ship the fix"))
      XCTAssertEqual(strike("Old plan"), NSUnderlineStyle.single.rawValue)
      XCTAssertEqual(strike("British spelling"), NSUnderlineStyle.single.rawValue)
      let titleFont = storage.attribute(.font, at: ns.range(of: "Write the draft").location, effectiveRange: nil) as? NSFont
      let doneFont = storage.attribute(.font, at: ns.range(of: "Ship the fix").location, effectiveRange: nil) as? NSFont
      XCTAssertEqual(titleFont?.pointSize, doneFont?.pointSize, "Finished headings keep their heading size")
    }
  }

  func testOrgTodoVisualStateClassifiesCustomTerminalKeywordsAsDone() {
    let sequences = [Org2TodoSequence(keywords: ["NEXT", "SHIPPED", "DROPPED"], terminal: ["SHIPPED", "DROPPED"])]
    XCTAssertNil(OrgTodoVisualState.classify(nil))
    XCTAssertEqual(OrgTodoVisualState.classify("TODO"), .open)
    XCTAssertEqual(OrgTodoVisualState.classify("NEXT", sequences: sequences), .open)
    XCTAssertEqual(OrgTodoVisualState.classify("SHIPPED", sequences: sequences), .done)
    XCTAssertEqual(OrgTodoVisualState.classify("DONE"), .done)
    XCTAssertEqual(OrgTodoVisualState.classify("CANCELED"), .canceled)
    XCTAssertEqual(OrgTodoVisualState.classify("cancelled"), .canceled)
    XCTAssertTrue(OrgTodoVisualState.canceled.strikesThroughTitle)
    XCTAssertFalse(OrgTodoVisualState.done.strikesThroughTitle)
    XCTAssertLessThan(OrgTodoVisualState.canceled.titleOpacity, OrgTodoVisualState.done.titleOpacity)
    XCTAssertLessThan(OrgTodoVisualState.done.titleOpacity, OrgTodoVisualState.open.titleOpacity)
  }

  func testOrgSyntaxHighlighterStrikesThroughCheckedListItemText() {
    let raw = """
    * [X] heading is not a list item
    - [X] shipped the fix
    - [ ] still open
      + [x] nested done
    1. [X] ordered done
      * [X] indented star item
    - [-] partially done
    """
    let tokens = OrgSyntaxHighlighter.tokens(in: raw)
    let checked = tokens.filter { $0.kind == .checkedListItem }
      .map { (raw as NSString).substring(with: $0.range) }
    XCTAssertEqual(checked, ["shipped the fix", "nested done", "ordered done", "indented star item"])

    let storage = NSTextStorage(string: raw)
    OrgSyntaxHighlighter.apply(to: storage, monospaced: false)
    let doneRange = (raw as NSString).range(of: "shipped the fix")
    let openRange = (raw as NSString).range(of: "still open")
    XCTAssertEqual(
      storage.attribute(.strikethroughStyle, at: doneRange.location, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue
    )
    XCTAssertNil(storage.attribute(.strikethroughStyle, at: openRange.location, effectiveRange: nil))
    XCTAssertNil(storage.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
  }

  func testOrgSyntaxHighlighterSkipsPlainBlockLines() {
    XCTAssertFalse(OrgSyntaxHighlighter.lineMayContainBlockSyntax("plain paragraph line"[...]))
    XCTAssertFalse(OrgSyntaxHighlighter.lineMayContainBlockSyntax("  plain indented content"[...]))
    XCTAssertFalse(OrgSyntaxHighlighter.lineMayContainBlockSyntax(""[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("* TODO Heading"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("#+TITLE: Demo"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("  :ID: abc"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("SCHEDULED: <2026-06-13>"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("  DEADLINE: <2026-06-13>"[...]))
    XCTAssertTrue(OrgSyntaxHighlighter.lineMayContainBlockSyntax("CLOSED: [2026-06-13]"[...]))
  }

  func testOrgSyntaxHighlighterSkipsPlainInlineRegexPasses() {
    XCTAssertFalse(OrgSyntaxHighlighter.textMayContainInlineSyntax(""))
    XCTAssertFalse(OrgSyntaxHighlighter.textMayContainInlineSyntax("plain paragraph text"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("See [[id:abc][Alice]]"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Read [Docs](https://example.com)"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Visit https://example.com"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Open notes/person.org"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Use `code`"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("Use =code="))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("*bold* and _underlined_"))
    XCTAssertTrue(OrgSyntaxHighlighter.textMayContainInlineSyntax("<2026-06-13>"))
  }

  func testOrgSyntaxHighlighterKeepsLineOffsetsAcrossBlankLines() {
    let raw = "Intro\n\n#+begin_quote\nSee [[id:abc][Alice]].\n#+end_quote\n"
    let tokens = OrgSyntaxHighlighter.tokens(in: raw)
    let nsRaw = raw as NSString

    let beginRange = nsRaw.range(of: "begin_quote")
    let linkRange = nsRaw.range(of: "[[id:abc][Alice]]")
    let separatorRange = nsRaw.range(of: "][")

    XCTAssertTrue(tokens.contains(OrgSyntaxHighlightToken(kind: .keyword, range: beginRange)))
    XCTAssertTrue(tokens.contains(OrgSyntaxHighlightToken(kind: .link, range: linkRange)))
    XCTAssertTrue(tokens.contains(OrgSyntaxHighlightToken(kind: .syntaxDelimiter, range: separatorRange)))
  }

  func testOrgSyntaxHighlighterVisuallyRecedesEditableDelimiters() throws {
    let raw = "See [[id:abc][Alice]] and [Docs](https://example.com/docs) and `code`."
    let storage = NSTextStorage(string: raw)
    OrgSyntaxHighlighter.apply(to: storage, monospaced: false)
    let ns = raw as NSString

    let bracketIndex = try XCTUnwrap(optionalLocation(ns.range(of: "[[")))
    let orgTargetIndex = try XCTUnwrap(optionalLocation(ns.range(of: "id:abc")))
    let linkLabelIndex = try XCTUnwrap(optionalLocation(ns.range(of: "Alice")))
    let markdownTargetIndex = try XCTUnwrap(optionalLocation(ns.range(of: "https://example.com/docs")))
    let tickIndex = try XCTUnwrap(optionalLocation(ns.range(of: "`")))
    let codeIndex = try XCTUnwrap(optionalLocation(ns.range(of: "code")))

    let bracketColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: bracketIndex, effectiveRange: nil) as? NSColor)
    let tickColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: tickIndex, effectiveRange: nil) as? NSColor)
    XCTAssertLessThan(bracketColor.alphaComponent, 0.18)
    XCTAssertLessThan(tickColor.alphaComponent, 0.18)
    let bracketFont = try XCTUnwrap(storage.attribute(.font, at: bracketIndex, effectiveRange: nil) as? NSFont)
    let tickFont = try XCTUnwrap(storage.attribute(.font, at: tickIndex, effectiveRange: nil) as? NSFont)
    XCTAssertLessThan(bracketFont.pointSize, 1)
    XCTAssertLessThan(tickFont.pointSize, 1)

    let labelColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: linkLabelIndex, effectiveRange: nil) as? NSColor)
    XCTAssertEqual(labelColor, WorkspaceThemeCenter.shared.liveColor(.link))
    let labelUnderline = storage.attribute(.underlineStyle, at: linkLabelIndex, effectiveRange: nil) as? Int
    XCTAssertEqual(labelUnderline, NSUnderlineStyle.single.rawValue)

    let orgTargetColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: orgTargetIndex, effectiveRange: nil) as? NSColor)
    let markdownTargetColor = try XCTUnwrap(storage.attribute(.foregroundColor, at: markdownTargetIndex, effectiveRange: nil) as? NSColor)
    XCTAssertLessThan(orgTargetColor.alphaComponent, 0.24)
    XCTAssertLessThan(markdownTargetColor.alphaComponent, 0.24)
    let orgTargetFont = try XCTUnwrap(storage.attribute(.font, at: orgTargetIndex, effectiveRange: nil) as? NSFont)
    let markdownTargetFont = try XCTUnwrap(storage.attribute(.font, at: markdownTargetIndex, effectiveRange: nil) as? NSFont)
    XCTAssertLessThan(orgTargetFont.pointSize, 1)
    XCTAssertLessThan(markdownTargetFont.pointSize, 1)
    let targetUnderline = storage.attribute(.underlineStyle, at: orgTargetIndex, effectiveRange: nil) as? Int
    XCTAssertEqual(targetUnderline, 0)

    let bracketUnderline = storage.attribute(.underlineStyle, at: bracketIndex, effectiveRange: nil) as? Int
    XCTAssertEqual(bracketUnderline, 0)

    let codeBackground = storage.attribute(.backgroundColor, at: codeIndex, effectiveRange: nil) as? NSColor
    XCTAssertNotNil(codeBackground)
    let tickBackground = storage.attribute(.backgroundColor, at: tickIndex, effectiveRange: nil) as? NSColor
    XCTAssertEqual(tickBackground, NSColor.clear)
  }

  func testOrgSyntaxHighlighterCollapsesHiddenLinkSyntaxWidth() {
    let raw = "for[[id:11111111-1111-4111-8111-111111111111][Crowell]]"
    let storage = NSTextStorage(string: raw)
    OrgSyntaxHighlighter.apply(to: storage, monospaced: false)

    let visibleStorage = NSTextStorage(string: "forCrowell")
    visibleStorage.setAttributes(
      OrgSyntaxHighlighter.baseTypingAttributes(monospaced: false),
      range: NSRange(location: 0, length: visibleStorage.length)
    )

    XCTAssertLessThan(abs(Self.laidOutWidth(storage) - Self.laidOutWidth(visibleStorage)), 0.5)
  }

  func testOrgSyntaxHighlighterSkipsLiveTokenizationForLargeBuffers() {
    XCTAssertTrue(OrgSyntaxHighlighter.shouldTokenizeLiveText(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldTokenizeLiveText(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1
    ))
    XCTAssertEqual(OrgSyntaxHighlighter.utf16Length(of: "a😀"), 3)
    XCTAssertEqual(OrgSyntaxHighlighter.utf16Length(of: String(repeating: "a", count: 20), upTo: 5), 5)
    XCTAssertTrue(OrgSyntaxHighlighter.shouldTokenizeLiveText(
      String(repeating: "a", count: OrgSyntaxHighlighter.liveTokenizationUTF16Limit)
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldTokenizeLiveText(
      String(repeating: "a", count: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1)
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit,
      hasHighlightedBefore: true,
      monospacedUnchanged: true
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1,
      hasHighlightedBefore: false,
      monospacedUnchanged: true
    ))
    XCTAssertFalse(OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1,
      hasHighlightedBefore: true,
      monospacedUnchanged: false
    ))
    XCTAssertTrue(OrgSyntaxHighlighter.shouldPreserveExistingAttributesAfterEdit(
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1,
      hasHighlightedBefore: true,
      monospacedUnchanged: true
    ))

    let smallStorage = NSTextStorage(string: "* TODO Small")
    OrgSyntaxHighlighter.apply(to: smallStorage, monospaced: false)
    let smallColor = smallStorage.attribute(
      .foregroundColor,
      at: 2,
      effectiveRange: nil
    ) as? NSColor
    XCTAssertEqual(smallColor, WorkspaceThemeCenter.shared.liveColor(.todo))

    let largeText = "* TODO Large\n" + String(
      repeating: "Body line with [[id:abc][Alice]] and <2026-06-12 Fri>.\n",
      count: 600
    )
    XCTAssertGreaterThan((largeText as NSString).length, OrgSyntaxHighlighter.liveTokenizationUTF16Limit)
    let largeStorage = NSTextStorage(string: largeText)
    OrgSyntaxHighlighter.apply(to: largeStorage, monospaced: false)
    let largeColor = largeStorage.attribute(
      .foregroundColor,
      at: 2,
      effectiveRange: nil
    ) as? NSColor
    XCTAssertEqual(largeColor, WorkspaceThemeCenter.shared.liveColor(.sourceText))
  }

  @MainActor
  func testSyntaxEditorPreservesLargeBufferAttributesAfterUserEdit() {
    let largeText = "* TODO Large\n" + String(
      repeating: "Body line with [[id:abc][Alice]] and <2026-06-12 Fri>.\n",
      count: 600
    )
    XCTAssertGreaterThan((largeText as NSString).length, OrgSyntaxHighlighter.liveTokenizationUTF16Limit)

    var boundText = largeText
    let editor = OrgSyntaxTextEditor(text: Binding(
      get: { boundText },
      set: { boundText = $0 }
    ))
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = largeText
    coordinator.applyHighlighting(to: textView)

    textView.textStorage?.addAttribute(
      .foregroundColor,
      value: NSColor.systemRed,
      range: NSRange(location: 0, length: 1)
    )
    textView.textStorage?.append(NSAttributedString(string: "x"))

    coordinator.markUserTextChangedForHighlighting(in: textView)
    coordinator.applyHighlightingIfNeeded(to: textView)

    let preservedColor = textView.textStorage?.attribute(
      .foregroundColor,
      at: 0,
      effectiveRange: nil
    ) as? NSColor
    XCTAssertEqual(preservedColor, NSColor.systemRed)
  }

  @MainActor
  func testSyntaxEditorSkipsPlainCaretSelectionPublishing() {
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      NSRange(location: 12, length: 0),
      previousRange: NSRange(location: 11, length: 0),
      text: "Plain paragraph text"
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      NSRange(location: 12, length: 4),
      previousRange: NSRange(location: 11, length: 0),
      text: "Plain paragraph text"
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      NSRange(location: 12, length: 0),
      previousRange: NSRange(location: 11, length: 0),
      text: "See [[id:abc][Alice]]"
    ))

    let longLinkedText = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 120)
    let farCaret = NSRange(location: (longLinkedText as NSString).length, length: 0)
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      farCaret,
      previousRange: NSRange(location: farCaret.location - 1, length: 0),
      text: longLinkedText
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.hasInlineSyntaxNearSelectionWindow(
      longLinkedText,
      selectedRange: NSRange(location: 8, length: 0),
      previousRange: NSRange(location: 9, length: 0)
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.hasInlineSyntaxNearSelectionWindow(
      longLinkedText,
      selectedRange: farCaret,
      previousRange: NSRange(location: farCaret.location - 1, length: 0)
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldPublishSelection(
      farCaret,
      previousRange: NSRange(location: 8, length: 0),
      text: longLinkedText
    ))
  }

  @MainActor
  func testSyntaxEditorOnlyOffersBoundaryDeleteAtDocumentRowStart() {
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldOfferDeleteBackwardCommand(
      selectedRange: NSRange(location: 0, length: 0)
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldOfferDeleteBackwardCommand(
      selectedRange: NSRange(location: 1, length: 0)
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldOfferDeleteBackwardCommand(
      selectedRange: NSRange(location: 0, length: 1)
    ))
  }

  @MainActor
  func testSyntaxEditorSkipsCrossEditorHierarchyTraversalDuringNormalTyping() {
    XCTAssertFalse(OrgSyntaxTextSelectionBridge.shouldTraverseForCrossEditorSelectionCleanup(
      hasActiveSelection: false,
      selectedFragmentCount: 0
    ))
    XCTAssertTrue(OrgSyntaxTextSelectionBridge.shouldTraverseForCrossEditorSelectionCleanup(
      hasActiveSelection: true,
      selectedFragmentCount: 0
    ))
    XCTAssertTrue(OrgSyntaxTextSelectionBridge.shouldTraverseForCrossEditorSelectionCleanup(
      hasActiveSelection: false,
      selectedFragmentCount: 1
    ))
  }

  @MainActor
  func testSyntaxEditorSkipsSelectionTextReadWhenUnboundOrUnchanged() {
    var boundText = "Plain paragraph text"
    var selectionRange = NSRange(location: 4, length: 0)
    let unboundEditor = OrgSyntaxTextEditor(text: .constant(boundText))
    let unboundCoordinator = OrgSyntaxTextEditor.Coordinator(parent: unboundEditor)

    XCTAssertFalse(unboundCoordinator.shouldReadTextForSelectionPublishing(
      NSRange(location: 5, length: 0)
    ))

    let boundEditor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      selection: Binding(
        get: { selectionRange },
        set: { selectionRange = $0 }
      )
    )
    let boundCoordinator = OrgSyntaxTextEditor.Coordinator(parent: boundEditor)

    XCTAssertFalse(boundCoordinator.shouldReadTextForSelectionPublishing(
      NSRange(location: 4, length: 0)
    ))
    XCTAssertTrue(boundCoordinator.shouldReadTextForSelectionPublishing(
      NSRange(location: 5, length: 0)
    ))
  }

  @MainActor
  func testSyntaxEditorPublishesMouseSelectionOnlyAfterTrackingEnds() {
    var selectionRange = NSRange(location: 0, length: 0)
    let editor = OrgSyntaxTextEditor(
      text: .constant("Select this text"),
      selection: Binding(
        get: { selectionRange },
        set: { selectionRange = $0 }
      )
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = OrgSyntaxTextView()
    textView.string = "Select this text"
    textView.isTrackingMouseSelection = true
    textView.setSelectedRange(NSRange(location: 0, length: 6))

    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    XCTAssertEqual(selectionRange, NSRange(location: 0, length: 0))

    textView.isTrackingMouseSelection = false
    coordinator.mouseSelectionDidEnd(in: textView)

    XCTAssertEqual(selectionRange, NSRange(location: 0, length: 6))
  }

  @MainActor
  func testSyntaxEditorKnownTextCacheUsesStorageLength() {
    let editor = OrgSyntaxTextEditor(text: .constant("Initial text"))
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)

    coordinator.recordKnownText("Initial text", utf16Length: 12)

    XCTAssertEqual(coordinator.knownText(matchingUTF16Length: 12), "Initial text")
    XCTAssertNil(coordinator.knownText(matchingUTF16Length: 13))
    XCTAssertNil(coordinator.knownText(matchingUTF16Length: nil))

    coordinator.recordKnownText("Updated 😀", utf16Length: 10)

    XCTAssertEqual(coordinator.knownText(matchingUTF16Length: 10), "Updated 😀")
    XCTAssertNil(coordinator.knownText(matchingUTF16Length: 9))
  }

  @MainActor
  func testSyntaxEditorDoesNotApplyStalePlainCaretSelectionWhileFocused() {
    XCTAssertEqual(
      OrgSyntaxTextEditor.clampedRange(NSRange(location: 10, length: 5), utf16Length: 12),
      NSRange(location: 10, length: 2)
    )
    XCTAssertEqual(
      OrgSyntaxTextEditor.clampedRange(NSRange(location: -3, length: 2), utf16Length: 12),
      NSRange(location: 0, length: 2)
    )

    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldApplyExternalSelection(
      requestedSelection: NSRange(location: 2, length: 0),
      currentSelection: NSRange(location: 3, length: 0),
      isFirstResponder: true,
      didApplyProgrammaticText: false
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldApplyExternalSelection(
      requestedSelection: NSRange(location: 2, length: 0),
      currentSelection: NSRange(location: 3, length: 0),
      isFirstResponder: false,
      didApplyProgrammaticText: false
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldApplyExternalSelection(
      requestedSelection: NSRange(location: 2, length: 1),
      currentSelection: NSRange(location: 3, length: 0),
      isFirstResponder: true,
      didApplyProgrammaticText: false
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldApplyExternalSelection(
      requestedSelection: NSRange(location: 2, length: 0),
      currentSelection: NSRange(location: 3, length: 0),
      isFirstResponder: true,
      didApplyProgrammaticText: true
    ))

    XCTAssertEqual(
      OrgSyntaxTextEditor.Coordinator.preferredSelectionAfterProgrammaticTextUpdate(
        requestedSelection: NSRange(location: 0, length: 0),
        currentSelection: NSRange(location: 12_000, length: 0),
        isFirstResponder: true,
        updatedUTF16Length: 20_000
      ),
      NSRange(location: 12_000, length: 0)
    )
    XCTAssertEqual(
      OrgSyntaxTextEditor.Coordinator.preferredSelectionAfterProgrammaticTextUpdate(
        requestedSelection: NSRange(location: 140, length: 0),
        currentSelection: NSRange(location: 120, length: 0),
        isFirstResponder: true,
        updatedUTF16Length: 20_000
      ),
      NSRange(location: 140, length: 0)
    )
  }

  @MainActor
  func testSyntaxEditorRestoresVisibleOriginAfterHighlighting() {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
    scrollView.hasVerticalScroller = true
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 220, height: 1_200))
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.textContainer?.containerSize = NSSize(width: 220, height: CGFloat.greatestFiniteMagnitude)
    textView.string = String(repeating: "* TODO Heading\nBody with [[id:abc][Alice]].\n", count: 80)
    scrollView.documentView = textView

    let targetOrigin = NSPoint(x: 0, y: 160)
    scrollView.contentView.scroll(to: targetOrigin)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let capturedOrigin = OrgSyntaxTextEditor.Coordinator.visibleOrigin(of: textView)
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)

    OrgSyntaxTextEditor.Coordinator.restoreVisibleOrigin(capturedOrigin, of: textView)

    XCTAssertEqual(scrollView.contentView.bounds.origin.x, targetOrigin.x, accuracy: 0.5)
    XCTAssertEqual(scrollView.contentView.bounds.origin.y, targetOrigin.y, accuracy: 0.5)
  }

  @MainActor
  func testSyntaxEditorReportsTheSourceLineAtTheViewportAnchor() throws {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    scrollView.hasVerticalScroller = true
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 2_400))
    textView.isVerticallyResizable = true
    textView.textContainer?.containerSize = NSSize(
      width: 320,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.string = (1...120).map { "Line \($0)" }.joined(separator: "\n")
    scrollView.documentView = textView
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 900))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let visibleLine = try XCTUnwrap(
      OrgSyntaxTextEditor.Coordinator.visibleSourceLine(of: textView)
    )

    XCTAssertGreaterThan(visibleLine, 20)
    XCTAssertLessThanOrEqual(visibleLine, 120)
  }

  @MainActor
  func testDocumentViewportPersistsPerFileAndSeedsSourceEditing() throws {
    let suiteName = "org2-document-viewport-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let text = (1...120).map { "Line \($0)" }.joined(separator: "\n")
    let source = EntrySource(
      file: "/tmp/remembered-page.org2",
      startLine: 1,
      endLineExclusive: 121,
      text: text,
      isSubtree: false
    )
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    store.selectedEntrySource = source
    store.recordDocumentViewportSourceLine(80)
    store.recordDocumentSlidePageIndex(4)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    restored.selectedEntrySource = source

    XCTAssertEqual(restored.currentDocumentViewportSourceLine, 80)
    XCTAssertEqual(restored.currentDocumentSlidePageIndex, 4)
    restored.beginEditingSelectedEntry()
    let expectedOffset = text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .prefix(79)
      .reduce(0) { $0 + $1.utf16.count + 1 }
    XCTAssertEqual(restored.sourceEditorSelection, NSRange(location: expectedOffset, length: 0))

    restored.recordDocumentViewportSourceLine(10_000)
    XCTAssertEqual(restored.currentDocumentViewportSourceLine, 120)
  }

  @MainActor
  func testSyntaxEditorDefersTextPublishingWithoutApplyingStaleBoundText() async throws {
    var boundText = "old"
    let liveText = OrgSyntaxTextEditorDraftBuffer()
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 20),
      onLocalTextChange: liveText.update
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = boundText

    applySyntaxEditorTextReplacement("new", in: textView, coordinator: coordinator)

    XCTAssertEqual(boundText, "old")
    XCTAssertEqual(liveText.current(fallback: ""), "new")
    XCTAssertTrue(coordinator.hasPendingTextPublishing(for: "new"))
    XCTAssertFalse(OrgSyntaxTextEditor.shouldApplyProgrammaticText(
      editorText: "new",
      boundText: "old",
      hasPendingLocalText: true
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.shouldApplyProgrammaticText(
      editorText: "new",
      boundText: "old",
      hasPendingLocalText: false
    ))

    try await waitForCondition {
      boundText == "new" && !coordinator.hasPendingTextPublishing(for: "new")
    }
    XCTAssertEqual(boundText, "new")
    XCTAssertFalse(coordinator.hasPendingTextPublishing(for: "new"))
  }

  @MainActor
  func testSyntaxEditorDefersAndCoalescesContentHeightMeasurement() async throws {
    var measuredHeight: CGFloat = 0
    var updateCount = 0
    let editor = OrgSyntaxTextEditor(
      text: .constant("A paragraph that needs layout"),
      contentHeight: Binding(
        get: { measuredHeight },
        set: {
          measuredHeight = $0
          updateCount += 1
        }
      )
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
    textView.string = "A paragraph that needs layout"

    coordinator.publishContentHeight(for: textView)
    coordinator.publishContentHeight(for: textView)

    XCTAssertEqual(measuredHeight, 0)
    try await waitForCondition {
      measuredHeight > 0
    }
    XCTAssertEqual(updateCount, 1)
  }

  @MainActor
  func testSyntaxEditorPublishesLatestDeferredTextAfterRapidEdits() async throws {
    var boundText = "old"
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 20)
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = boundText

    applySyntaxEditorTextReplacement("first", in: textView, coordinator: coordinator)
    XCTAssertTrue(coordinator.hasPendingTextPublishing(for: "first"))

    applySyntaxEditorTextReplacement("second", in: textView, coordinator: coordinator)
    XCTAssertFalse(coordinator.hasPendingTextPublishing(for: "first"))
    XCTAssertTrue(coordinator.hasPendingTextPublishing(for: "second"))

    try await waitForCondition {
      boundText == "second" && !coordinator.hasPendingTextPublishing(for: "second")
    }
    XCTAssertEqual(boundText, "second")
    XCTAssertFalse(coordinator.hasPendingTextPublishing(for: "second"))
  }

  @MainActor
  func testSyntaxEditorDefersIncrementalHighlightingUntilTypingIsIdle() async throws {
    var boundText = "* Original"
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      liveHighlighting: true,
      incrementalHighlighting: true,
      incrementalHighlightingDelayMilliseconds: 30
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = boundText

    applySyntaxEditorTextReplacement("* Updated", in: textView, coordinator: coordinator)

    XCTAssertTrue(coordinator.hasDeferredHighlighting(for: "* Updated"))
    try await waitForCondition {
      !coordinator.hasDeferredHighlighting(for: "* Updated")
    }
  }

  @MainActor
  func testSyntaxEditorSemanticAnalysisCoalescesRapidEditsAfterIdleDelay() async throws {
    var boundText = "* Original"
    let recorder = ThreadSafeStringRecorder()
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      liveHighlighting: false,
      semanticAnalysisDelayMilliseconds: 30,
      semanticAnalyzer: { text in
        recorder.append(text)
        return OrgSourceEditorSemanticSnapshot(regions: [])
      }
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = boundText

    applySyntaxEditorTextReplacement("* First", in: textView, coordinator: coordinator)
    applySyntaxEditorTextReplacement("* Latest", in: textView, coordinator: coordinator)

    XCTAssertEqual(recorder.values, [])
    try await waitForCondition {
      recorder.values == ["* Latest"]
    }
  }

  @MainActor
  func testSyntaxEditorDefersCaretOnlySelectionPublishing() async throws {
    var selection = NSRange(location: 0, length: 0)
    let editor = OrgSyntaxTextEditor(
      text: .constant("[[id:abc][Alice]] text"),
      caretPublishingDelayMilliseconds: 20,
      selection: Binding(
        get: { selection },
        set: { selection = $0 }
      )
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = "[[id:abc][Alice]] text"
    textView.setSelectedRange(NSRange(location: 4, length: 0))

    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    XCTAssertEqual(selection, NSRange(location: 0, length: 0))
    try await waitForCondition {
      selection == NSRange(location: 4, length: 0)
    }

    textView.setSelectedRange(NSRange(location: 4, length: 3))
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )
    XCTAssertEqual(selection, NSRange(location: 4, length: 3))

    textView.setSelectedRange(NSRange(location: 7, length: 0))
    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )
    XCTAssertEqual(
      selection,
      NSRange(location: 4, length: 3),
      "Replacing a selection must not synchronously invalidate the source-editor view tree"
    )
    try await waitForCondition {
      selection == NSRange(location: 7, length: 0)
    }
  }

  @MainActor
  func testSyntaxEditorPublishesDistantPlainCaretWithoutScanningForInlineSyntax() async throws {
    let text = String(repeating: "plain source line without inline syntax\n", count: 1_000)
    var selection = NSRange(location: 0, length: 0)
    let editor = OrgSyntaxTextEditor(
      text: .constant(text),
      caretPublishingDelayMilliseconds: 20,
      selection: Binding(
        get: { selection },
        set: { selection = $0 }
      )
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = text
    let distantCaret = NSRange(location: 20_000, length: 0)
    textView.setSelectedRange(distantCaret)

    coordinator.textViewDidChangeSelection(
      Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
    )

    XCTAssertEqual(selection, NSRange(location: 0, length: 0))
    try await waitForCondition {
      selection == distantCaret
    }
  }

  @MainActor
  func testSyntaxEditorAdaptivePublishingCanBypassDeferredText() {
    var boundText = "old"
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      textPublishing: .deferred(milliseconds: 2_000),
      shouldPublishTextImmediately: { $0.hasPrefix("/") }
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = boundText

    applySyntaxEditorTextReplacement("plain", in: textView, coordinator: coordinator)
    XCTAssertEqual(boundText, "old")
    XCTAssertTrue(coordinator.hasPendingTextPublishing(for: "plain"))

    applySyntaxEditorTextReplacement("/todo", in: textView, coordinator: coordinator)
    XCTAssertEqual(boundText, "/todo")
    XCTAssertFalse(coordinator.hasPendingTextPublishing(for: "/todo"))
  }

  @MainActor
  func testSyntaxEditorCanDisableLiveHighlightingDuringTyping() {
    var boundText = "old"
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      liveHighlighting: false
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let textView = NSTextView()
    textView.string = boundText

    applySyntaxEditorTextReplacement("* TODO Heading", in: textView, coordinator: coordinator)

    XCTAssertEqual(boundText, "* TODO Heading")
    XCTAssertFalse(coordinator.hasDeferredHighlighting(for: "* TODO Heading"))
  }

  @MainActor
  func testOrgSourceTextEditingContinuesListsAndIndentation() {
    let task = "- [ ] first task"
    XCTAssertEqual(
      OrgSourceTextEditing.newlineReplacement(
        in: task,
        selectedRange: NSRange(location: (task as NSString).length, length: 0)
      ),
      OrgSyntaxTextEditReplacement(
        range: NSRange(location: (task as NSString).length, length: 0),
        replacement: "\n- [ ] "
      )
    )

    let ordered = "9. ninth"
    XCTAssertEqual(
      OrgSourceTextEditing.newlineReplacement(
        in: ordered,
        selectedRange: NSRange(location: (ordered as NSString).length, length: 0)
      )?.replacement,
      "\n10. "
    )

    let indented = "  wrapped thought"
    XCTAssertEqual(
      OrgSourceTextEditing.newlineReplacement(
        in: indented,
        selectedRange: NSRange(location: (indented as NSString).length, length: 0)
      )?.replacement,
      "\n  "
    )

    let emptyTask = "- [ ] "
    XCTAssertNil(OrgSourceTextEditing.newlineReplacement(
      in: emptyTask,
      selectedRange: NSRange(location: (emptyTask as NSString).length, length: 0)
    ))
    let heading = "* Heading"
    XCTAssertNil(OrgSourceTextEditing.newlineReplacement(
      in: heading,
      selectedRange: NSRange(location: (heading as NSString).length, length: 0)
    ))
  }

  @MainActor
  func testOrgSourceTextEditingIndentsAndOutdentsListsAndHeadings() {
    let list = "- first\n  - second"
    XCTAssertEqual(
      OrgSourceTextEditing.indentationReplacement(
        in: list,
        selectedRange: NSRange(location: 0, length: (list as NSString).length),
        direction: .indent
      )?.replacement,
      "  - first\n    - second"
    )

    XCTAssertEqual(
      OrgSourceTextEditing.indentationReplacement(
        in: list,
        selectedRange: NSRange(location: (list as NSString).length, length: 0),
        direction: .outdent
      )?.replacement,
      "- second"
    )

    let heading = "* Parent\n** Child"
    XCTAssertEqual(
      OrgSourceTextEditing.indentationReplacement(
        in: heading,
        selectedRange: NSRange(location: 0, length: (heading as NSString).length),
        direction: .indent
      )?.replacement,
      "** Parent\n*** Child"
    )

    XCTAssertEqual(
      OrgSourceTextEditing.indentationReplacement(
        in: heading,
        selectedRange: NSRange(location: (heading as NSString).length, length: 0),
        direction: .outdent
      )?.replacement,
      "* Child"
    )

    XCTAssertNil(OrgSourceTextEditing.indentationReplacement(
      in: "plain paragraph",
      selectedRange: NSRange(location: 0, length: 0),
      direction: .indent
    ))
  }

  @MainActor
  func testSyntaxEditorConfiguresNativeFindBar() {
    let textView = NSTextView()

    OrgSyntaxTextEditor.configureNativeFind(in: textView)

    XCTAssertTrue(textView.usesFindBar)
    XCTAssertTrue(textView.isIncrementalSearchingEnabled)
  }

  @MainActor
  func testSyntaxEditorConsumesCommandFToPresentNativeFindBar() throws {
    let scrollView = NSScrollView()
    let textView = OrgSyntaxTextView()
    textView.string = "Find this text"
    OrgSyntaxTextEditor.configureNativeFind(in: textView)
    scrollView.documentView = textView
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = scrollView
    XCTAssertTrue(window.makeFirstResponder(textView))
    let event = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      characters: "f",
      charactersIgnoringModifiers: "f",
      isARepeat: false,
      keyCode: 3
    ))

    XCTAssertTrue(textView.performKeyEquivalent(with: event))
  }

  @MainActor
  func testSyntaxEditorConfiguresNativeSpellingAndGrammarChecking() {
    let textView = NSTextView()

    OrgSyntaxTextEditor.configureTextChecking(.spellingAndGrammar, in: textView)

    XCTAssertTrue(textView.isContinuousSpellCheckingEnabled)
    XCTAssertTrue(textView.isGrammarCheckingEnabled)
    XCTAssertNotEqual(
      textView.enabledTextCheckingTypes & NSTextCheckingResult.CheckingType.spelling.rawValue,
      0
    )
    XCTAssertNotEqual(
      textView.enabledTextCheckingTypes & NSTextCheckingResult.CheckingType.grammar.rawValue,
      0
    )

    OrgSyntaxTextEditor.configureTextChecking(.disabled, in: textView)
    XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
    XCTAssertFalse(textView.isGrammarCheckingEnabled)
    XCTAssertEqual(textView.enabledTextCheckingTypes, 0)
  }

  @MainActor
  func testSyntaxEditorDisablesContinuousTextCheckingForLargeBuffers() {
    let textView = NSTextView()

    OrgSyntaxTextEditor.configureTextChecking(
      .spellingAndGrammar,
      in: textView,
      utf16Length: OrgSyntaxTextEditor.continuousTextCheckingUTF16Limit
    )
    XCTAssertTrue(textView.isContinuousSpellCheckingEnabled)
    XCTAssertTrue(textView.isGrammarCheckingEnabled)

    OrgSyntaxTextEditor.configureTextChecking(
      .spellingAndGrammar,
      in: textView,
      utf16Length: OrgSyntaxTextEditor.continuousTextCheckingUTF16Limit + 1
    )
    XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
    XCTAssertFalse(textView.isGrammarCheckingEnabled)
    XCTAssertEqual(textView.enabledTextCheckingTypes, 0)
  }

  @MainActor
  func testSyntaxEditorUsesNoncontiguousLayoutOnlyForScrollingEditors() {
    XCTAssertTrue(OrgSyntaxTextEditor.shouldAllowNonContiguousLayout(
      showsScrollers: true,
      measuresContentHeight: false
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.shouldAllowNonContiguousLayout(
      showsScrollers: false,
      measuresContentHeight: false
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.shouldAllowNonContiguousLayout(
      showsScrollers: true,
      measuresContentHeight: true
    ))
  }

  func testSourceTextCheckingExcludesOrgSyntaxAndChecksProse() throws {
    let text = """
    * TODO Review writting
    :PROPERTIES:
    :OWNER: Avi
    :END:
    Body misspelld prose with [[https://example.com][mistakn label]].
    #+begin_src swift
    let teh = true
    #+end_src
    """
    let snapshot = OrgSourceEditorSemanticSnapshot(regions: [
      OrgSourceSemanticRegion(kind: .headline, startLine: 1, endLine: 8, level: 1, todo: "TODO"),
      OrgSourceSemanticRegion(kind: .properties, startLine: 2, endLine: 4, level: nil, todo: nil),
      OrgSourceSemanticRegion(kind: .sourceBlock, startLine: 6, endLine: 8, level: nil, todo: nil)
    ])
    let nsText = text as NSString
    let lineIndex = OrgSourceLineIndex(text: nsText)

    func isSuppressed(_ value: String) throws -> Bool {
      let range = nsText.range(of: value)
      XCTAssertNotEqual(range.location, NSNotFound)
      let storageBacked = OrgSourceTextChecking.shouldSuppress(
        in: nsText,
        range: range,
        snapshot: snapshot,
        lineIndex: lineIndex
      )
      XCTAssertEqual(
        storageBacked,
        OrgSourceTextChecking.shouldSuppress(in: text, range: range, snapshot: snapshot)
      )
      return storageBacked
    }

    XCTAssertTrue(try isSuppressed("TODO"))
    XCTAssertTrue(try isSuppressed("OWNER"))
    XCTAssertTrue(try isSuppressed("example.com"))
    XCTAssertTrue(try isSuppressed("teh"))
    XCTAssertFalse(try isSuppressed("writting"))
    XCTAssertFalse(try isSuppressed("misspelld"))
    XCTAssertFalse(try isSuppressed("mistakn"))
    XCTAssertEqual(
      OrgSourceTextChecking.excludedSemanticRanges(in: text, snapshot: snapshot).count,
      2
    )
  }

  @MainActor
  func testOrgSourceTextEditingStructuredCommandsUseSemanticHeadingRanges() throws {
    let text = """
    * Parent
    Body
    ** TODO Child
    Child body
    * Sibling
    """
    let snapshot = OrgSourceTextEditing.fallbackSemanticSnapshot(in: text)
    let parent = try XCTUnwrap(snapshot.regions.first { $0.startLine == 1 })
    let child = try XCTUnwrap(snapshot.regions.first { $0.startLine == 3 })
    XCTAssertEqual(parent.endLine, 4)
    XCTAssertEqual(child.endLine, 4)
    XCTAssertEqual(
      OrgSourceTextEditing.enclosingHeadline(in: snapshot, line: 4)?.startLine,
      3
    )

    let bodyOffset = ("* Parent\nBody" as NSString).length
    XCTAssertEqual(
      OrgSourceTextEditing.headingInsertionReplacement(
        in: text,
        selectedRange: NSRange(location: bodyOffset, length: 0),
        snapshot: snapshot
      ).replacement,
      "\n* "
    )

    let cycled = try XCTUnwrap(OrgSourceTextEditing.todoCycleReplacement(
      in: text,
      selectedRange: NSRange(location: bodyOffset, length: 0),
      snapshot: snapshot
    ))
    XCTAssertEqual(cycled.replacement, "TODO ")
    XCTAssertEqual((text as NSString).replacingCharacters(in: cycled.range, with: cycled.replacement).components(separatedBy: "\n")[0], "* TODO Parent")

    let linked = try XCTUnwrap(OrgSourceTextEditing.linkReplacement(
      in: "Alpha beta",
      selectedRange: NSRange(location: 6, length: 4),
      target: "id:beta",
      description: nil
    ))
    XCTAssertEqual(linked.replacement, "[[id:beta][beta]]")

    let nextHeading = try XCTUnwrap(OrgSourceTextEditing.headingNavigationRange(
      in: text,
      selectedRange: NSRange(location: 0, length: 0),
      direction: .nextHeading,
      snapshot: snapshot
    ))
    XCTAssertEqual(nextHeading.location, ("* Parent\nBody\n" as NSString).length)
  }

  @MainActor
  func testOrgSourceTextEditingPlanningAndPropertyCommandsStayInBuffer() throws {
    let text = "* TODO Parent\nBody"
    let snapshot = OrgSourceTextEditing.fallbackSemanticSnapshot(in: text)
    var calendar = Calendar.current
    calendar.timeZone = .current
    let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))

    let planning = try XCTUnwrap(OrgSourceTextEditing.planningReplacement(
      in: text,
      selectedRange: NSRange(location: (text as NSString).length, length: 0),
      kind: "SCHEDULED",
      date: date,
      snapshot: snapshot
    ))
    XCTAssertEqual(planning.replacement, "\nSCHEDULED: <2026-07-09 Thu>")

    let property = try XCTUnwrap(OrgSourceTextEditing.propertyReplacement(
      in: text,
      selectedRange: NSRange(location: (text as NSString).length, length: 0),
      key: "owner",
      value: "Avi",
      snapshot: snapshot
    ))
    XCTAssertEqual(property.replacement, "\n:PROPERTIES:\n:OWNER: Avi\n:END:")

    let plannedText = "* TODO Parent\nSCHEDULED: <2026-07-09 Thu>\nDEADLINE: <2026-07-10 Fri>\nBody"
    let plannedSnapshot = OrgSourceTextEditing.fallbackSemanticSnapshot(in: plannedText)
    let cleared = try XCTUnwrap(OrgSourceTextEditing.clearPlanningReplacement(
      in: plannedText,
      selectedRange: NSRange(location: (plannedText as NSString).length, length: 0),
      snapshot: plannedSnapshot
    ))
    XCTAssertEqual(
      (plannedText as NSString).replacingCharacters(in: cleared.range, with: cleared.replacement),
      "* TODO Parent\nBody"
    )
  }

  func testSourceEditorGutterModelSurfacesHeadingWorkflowMetadata() throws {
    let text = """
    * TODO [#A] Parent
    SCHEDULED: <2026-07-11 Sat>
    Body
    ** WAIT Child
    DEADLINE: <2026-07-12 Sun>
    Child body
    """
    let fallback = OrgSourceTextEditing.fallbackSemanticSnapshot(in: text)
    let snapshot = OrgSourceEditorSemanticSnapshot(
      regions: fallback.regions,
      diagnostics: [Org2EditorDiagnostic(message: "Problem", line: 6, column: 1)]
    )

    let items = OrgSourceEditorGutterModel.items(
      text: text,
      snapshot: snapshot,
      foldedHeadlineStartLines: [1]
    )

    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].utf16Offset, 0)
    XCTAssertEqual(
      items[1].utf16Offset,
      ("* TODO [#A] Parent\nSCHEDULED: <2026-07-11 Sat>\nBody\n" as NSString).length
    )
    XCTAssertEqual(items[0].title, "Parent")
    XCTAssertEqual(items[0].todo, "TODO")
    XCTAssertEqual(items[0].priority, "A")
    XCTAssertTrue(items[0].hasScheduled)
    XCTAssertFalse(items[0].hasDeadline)
    XCTAssertTrue(items[0].isFolded)
    XCTAssertEqual(items[1].todo, "WAIT")
    XCTAssertTrue(items[1].hasDeadline)
    XCTAssertTrue(items[1].hasDiagnostic)
    XCTAssertFalse(items[0].hasDiagnostic)
  }

  func testSourceEditorPriorityCommandStaysInNativeBuffer() throws {
    let text = "* TODO Parent\nBody"
    let snapshot = OrgSourceTextEditing.fallbackSemanticSnapshot(in: text)
    let insertion = try XCTUnwrap(OrgSourceTextEditing.priorityReplacement(
      in: text,
      selectedRange: NSRange(location: (text as NSString).length, length: 0),
      priority: "A",
      snapshot: snapshot
    ))
    let prioritized = (text as NSString).replacingCharacters(in: insertion.range, with: insertion.replacement)
    XCTAssertEqual(prioritized, "* TODO [#A] Parent\nBody")

    let removal = try XCTUnwrap(OrgSourceTextEditing.priorityReplacement(
      in: prioritized,
      selectedRange: NSRange(location: 0, length: 0),
      priority: nil,
      snapshot: OrgSourceTextEditing.fallbackSemanticSnapshot(in: prioritized)
    ))
    XCTAssertEqual(
      (prioritized as NSString).replacingCharacters(in: removal.range, with: removal.replacement),
      text
    )

    let literalPriorityText = "* TODO Discuss [#A] notation"
    XCTAssertNil(OrgSourceTextEditing.priorityReplacement(
      in: literalPriorityText,
      selectedRange: NSRange(location: 0, length: 0),
      priority: nil,
      snapshot: OrgSourceTextEditing.fallbackSemanticSnapshot(in: literalPriorityText)
    ))
  }

  @MainActor
  func testSourceEditorPresentationPreferencePersists() {
    let suiteName = "org2-source-editor-presentation-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    first.sourceEditorPresentation = .split
    let restored = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    XCTAssertEqual(restored.sourceEditorPresentation, .split)
  }

  @MainActor
  func testSourceEditorLivePreviewRendersLatestInMemoryBuffer() async throws {
    let suiteName = "org2-source-editor-preview-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])
    let source = EntrySource(
      file: "/tmp/source-preview.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "* Original\nBody",
      isSubtree: false
    )
    store.selectedEntrySource = source
    store.beginEditingSelectedEntry()
    store.sourceEditorPresentation = .split
    let liveDraft = "* Latest preview\nA [[https://example.com][link]]."
    store.noteSourceEditorLocalTextChanged(liveDraft)
    store.sourceEditorInteraction.text = liveDraft
    store.scheduleSourceEditorPreview(text: liveDraft, immediate: true)

    try await waitForCondition(timeout: 10) {
      store.sourceEditorPreviewHTML?.contains("Latest preview") == true
        && !store.isRenderingSourceEditorPreview
    }

    XCTAssertTrue(store.sourceEditorPreviewHTML?.contains("href=\"https://example.com\"") == true)
    XCTAssertFalse(store.sourceEditorPreviewHTML?.contains("<title>Original</title>") == true)
  }

  @MainActor
  func testSyntaxEditorIncrementallyHighlightsLargeSourceWithoutConcealingSyntax() {
    let prefix = String(repeating: "Plain body line\n", count: 2_000)
    let heading = "* TODO Large"
    let text = prefix + heading
    XCTAssertGreaterThan((text as NSString).length, OrgSyntaxHighlighter.liveTokenizationUTF16Limit)
    let storage = NSTextStorage(string: text)
    let range = (text as NSString).range(of: heading)

    OrgSyntaxHighlighter.apply(
      to: storage,
      characterRange: range,
      monospaced: true,
      concealsSyntax: false
    )

    let starColor = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    let todoColor = storage.attribute(.foregroundColor, at: range.location + 2, effectiveRange: nil) as? NSColor
    XCTAssertEqual(starColor, NSColor.tertiaryLabelColor)
    XCTAssertEqual(todoColor, WorkspaceThemeCenter.shared.liveColor(.todo))
  }

  @MainActor
  func testSyntaxEditorViewportHighlightingConvergesAndRemembersCoveredRanges() throws {
    let text = String(
      repeating: "* TODO Heading\nBody with [[id:abc][Alice]].\n",
      count: 800
    )
    XCTAssertGreaterThan(
      (text as NSString).length,
      OrgSyntaxHighlighter.liveTokenizationUTF16Limit
    )

    var boundText = text
    let editor = OrgSyntaxTextEditor(
      text: Binding(
        get: { boundText },
        set: { boundText = $0 }
      ),
      monospaced: true,
      liveHighlighting: true,
      incrementalHighlighting: true,
      concealsSyntax: false
    )
    let coordinator = OrgSyntaxTextEditor.Coordinator(parent: editor)
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    scrollView.hasVerticalScroller = true
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30_000))
    textView.isVerticallyResizable = true
    textView.textContainer?.containerSize = NSSize(
      width: 320,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.string = text
    scrollView.documentView = textView
    coordinator.applyHighlighting(to: textView)

    func applicationsUntilQuiescent(at origin: NSPoint) -> Int? {
      scrollView.contentView.scroll(to: origin)
      scrollView.reflectScrolledClipView(scrollView.contentView)
      var applications = 0
      for _ in 0..<8 {
        guard coordinator.highlightVisibleRange(in: textView) else {
          return applications
        }
        applications += 1
      }
      return nil
    }

    let initialApplications = try XCTUnwrap(applicationsUntilQuiescent(at: .zero))
    XCTAssertEqual(initialApplications, 0)
    XCTAssertFalse(coordinator.highlightVisibleRange(in: textView))
    let todoColor = textView.textStorage?.attribute(
      .foregroundColor,
      at: 2,
      effectiveRange: nil
    ) as? NSColor
    XCTAssertEqual(todoColor, WorkspaceThemeCenter.shared.liveColor(.todo))

    let scrolledApplications = try XCTUnwrap(
      applicationsUntilQuiescent(at: NSPoint(x: 0, y: 900))
    )
    XCTAssertGreaterThan(scrolledApplications, 0)
    XCTAssertEqual(try XCTUnwrap(applicationsUntilQuiescent(at: .zero)), 0)

    coordinator.invalidateHighlighting()
    XCTAssertGreaterThan(
      try XCTUnwrap(applicationsUntilQuiescent(at: .zero)),
      0
    )
  }

  @MainActor
  func testSyntaxEditorDoesNotScheduleDeferredHighlightingForLargeBuffers() {
    let largeText = String(repeating: "Body with [[id:abc][Alice]].\n", count: 2_000)
    XCTAssertGreaterThan((largeText as NSString).length, OrgSyntaxHighlighter.liveTokenizationUTF16Limit)
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: largeText,
      previousHighlightedText: nil,
      monospacedUnchanged: true
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: largeText,
      utf16Length: OrgSyntaxHighlighter.liveTokenizationUTF16Limit + 1,
      previousHighlightedText: nil,
      monospacedUnchanged: true
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "See [[id:abc][Alice]]",
      utf16Length: 22,
      previousHighlightedText: nil,
      monospacedUnchanged: true
    ))
  }

  @MainActor
  func testSyntaxEditorSkipsDeferredHighlightingForPlainTextEdits() {
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "Plain paragraph text",
      previousHighlightedText: "Plain paragraph tex",
      monospacedUnchanged: true
    ))
    XCTAssertFalse(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "Plain paragraph text",
      previousHighlightedText: nil,
      monospacedUnchanged: true
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "Plain paragraph text",
      previousHighlightedText: "See [[id:abc][Alice]]",
      monospacedUnchanged: true
    ))
    XCTAssertTrue(OrgSyntaxTextEditor.Coordinator.shouldScheduleDeferredHighlighting(
      text: "See [[id:abc][Alice]]",
      previousHighlightedText: "Plain paragraph text",
      monospacedUnchanged: true
    ))
  }

  func testInlineEditorSizingStopsAtVisibleLineCap() {
    XCTAssertEqual(
      InlineEditorSizing.endSelection(in: "abc"),
      NSRange(location: 3, length: 0)
    )
    XCTAssertEqual(
      InlineEditorSizing.endSelection(in: "a😀"),
      NSRange(location: 3, length: 0)
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(in: "", minimum: 1, maximum: 15),
      1
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(in: "one\ntwo\nthree", minimum: 1, maximum: 15),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(in: "one 😀\ntwo é\nthree", minimum: 1, maximum: 15),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(in: "one", minimum: 3, maximum: 15),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.cappedLineCount(
        in: (1...1_000).map { "line \($0)" }.joined(separator: "\n"),
        minimum: 1,
        maximum: 15
      ),
      15
    )
    XCTAssertEqual(
      InlineEditorSizing.stickyCappedLineCount(
        in: "one",
        reservedLineCount: 8,
        minimum: 1,
        maximum: 15
      ),
      8
    )
    XCTAssertEqual(
      InlineEditorSizing.stickyCappedLineCount(
        in: "one\ntwo\nthree",
        reservedLineCount: 1,
        minimum: 1,
        maximum: 15
      ),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.stickyCappedLineCount(
        in: (1...1_000).map { "line \($0)" }.joined(separator: "\n"),
        reservedLineCount: 3,
        minimum: 1,
        maximum: 15
      ),
      15
    )
    XCTAssertEqual(
      InlineEditorSizing.expandedReservedLineCount(
        in: "one",
        reservedLineCount: 8,
        minimum: 1,
        maximum: 15
      ),
      8
    )
    XCTAssertEqual(
      InlineEditorSizing.expandedReservedLineCount(
        in: "one\ntwo\nthree",
        reservedLineCount: 1,
        minimum: 1,
        maximum: 15
      ),
      3
    )
    XCTAssertEqual(
      InlineEditorSizing.expandedReservedLineCount(
        in: (1...1_000).map { "line \($0)" }.joined(separator: "\n"),
        reservedLineCount: 3,
        minimum: 1,
        maximum: 15
      ),
      15
    )

    let longLine = "extension importer; CRM sync progress; backlink plan model upgrade evaluation"
    let narrowHeight = InlineEditorSizing.wrappedTextEditorHeight(
      in: longLine,
      width: 160,
      minimumLineCount: 1
    )
    let wideHeight = InlineEditorSizing.wrappedTextEditorHeight(
      in: longLine,
      width: 900,
      minimumLineCount: 1
    )
    XCTAssertGreaterThan(narrowHeight, wideHeight)
    XCTAssertGreaterThanOrEqual(
      InlineEditorSizing.wrappedTextEditorHeight(in: "", width: 160, minimumLineCount: 2),
      47
    )
  }

  func testInlineEditorChromeKeepsStableHiddenControls() {
    XCTAssertTrue(InlineEditorChrome.rendersControls(true))
    XCTAssertTrue(InlineEditorChrome.rendersControls(false))
    XCTAssertTrue(InlineEditorChrome.rendersSavingIndicator(true))
    XCTAssertTrue(InlineEditorChrome.rendersSavingIndicator(false))
    XCTAssertEqual(InlineEditorChrome.controlsOpacity(true), 1)
    XCTAssertEqual(InlineEditorChrome.controlsOpacity(false), 0)
    XCTAssertTrue(InlineEditorChrome.allowsHitTesting(true))
    XCTAssertFalse(InlineEditorChrome.allowsHitTesting(false))
    XCTAssertEqual(InlineEditorChrome.accessoryOpacity(true), 1)
    XCTAssertEqual(InlineEditorChrome.accessoryOpacity(false), 0)
    XCTAssertEqual(InlineEditorChrome.savingIndicatorSize, 14)
    XCTAssertEqual(InlineEditorChrome.savingIndicatorOpacity(true), 1)
    XCTAssertEqual(InlineEditorChrome.savingIndicatorOpacity(false), 0)
    XCTAssertEqual(InlineEditorChrome.controlsReserveWidth, RenderedRowChrome.controlsReserveWidth)
    XCTAssertEqual(InlineEditorChrome.controlsTrailingPadding(), RenderedRowChrome.controlsReserveWidth)
    XCTAssertEqual(
      InlineEditorChrome.controlsTrailingPadding(isPersistent: false),
      InlineEditorChrome.compactControlsReserveWidth
    )
  }

  func testParagraphFocusedInlineEditorSkipsPlainText() {
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: "Plain paragraph without editable inline syntax",
      selectedRange: NSRange(location: 6, length: 0),
      showsInlineDetails: false
    ))
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: "Review [[id:abc][Alice]]",
      selectedRange: NSRange(location: 15, length: 0),
      showsInlineDetails: true
    ))
    XCTAssertTrue(ParagraphFocusedInlineEditor.shouldRender(
      text: "Review [[id:abc][Alice]]",
      selectedRange: NSRange(location: 15, length: 0),
      showsInlineDetails: false
    ))
    XCTAssertTrue(ParagraphFocusedInlineEditor.shouldRender(
      text: "Meet on <2026-06-13 Sat>",
      selectedRange: NSRange(location: 12, length: 0),
      showsInlineDetails: false
    ))

    let linkedPrefix = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 160)
    let farPlainRange = NSRange(location: (linkedPrefix as NSString).length, length: 0)
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: linkedPrefix,
      selectedRange: farPlainRange,
      showsInlineDetails: false
    ))

    let longRichParagraph = "See [[id:abc][Alice]]. " + String(
      repeating: "Long paragraph body ",
      count: 900
    )
    XCTAssertGreaterThan((longRichParagraph as NSString).length, OrgEditableInlineToken.focusedScanUTF16Limit)
    XCTAssertFalse(ParagraphFocusedInlineEditor.shouldRender(
      text: longRichParagraph,
      selectedRange: NSRange(location: 6, length: 0),
      showsInlineDetails: false
    ))
    XCTAssertNil(ParagraphFocusedInlineEditor.focusedToken(
      text: "Plain paragraph without editable inline syntax",
      selectedRange: NSRange(location: 6, length: 0),
      showsInlineDetails: false
    ))
    XCTAssertNil(ParagraphFocusedInlineEditor.focusedToken(
      text: longRichParagraph,
      selectedRange: NSRange(location: 6, length: 0),
      showsInlineDetails: false
    ))
  }

  func testParagraphFocusedInlineEditorFindsFocusedTokenOnce() {
    let raw = "See [[id:abc][Alice]] and `code`."
    let nsRaw = raw as NSString
    let aliceRange = nsRaw.range(of: "Alice")
    let codeRange = nsRaw.range(of: "code")

    let linkToken = ParagraphFocusedInlineEditor.focusedToken(
      text: raw,
      selectedRange: NSRange(location: aliceRange.location, length: 0),
      showsInlineDetails: false
    )
    if case .link(let link) = linkToken {
      XCTAssertEqual(link.label, "Alice")
      XCTAssertEqual(link.target, "id:abc")
    } else {
      XCTFail("Expected focused link token")
    }

    let hiddenToken = ParagraphFocusedInlineEditor.focusedToken(
      text: raw,
      selectedRange: NSRange(location: codeRange.location, length: 0),
      showsInlineDetails: true
    )
    XCTAssertNil(hiddenToken)
  }

  func testParagraphInlineDetailsAvailabilityMatchesEditableInlineSyntax() {
    XCTAssertFalse(ParagraphInlineDetailsAvailability.hasDetails(in: "Plain paragraph without inline fields."))
    XCTAssertFalse(ParagraphInlineDetailsAvailability.hasDetails(in: "A long ordinary note with no rich text markers"))
    XCTAssertTrue(ParagraphInlineDetailsAvailability.hasDetails(in: "Review [[id:abc][Alice]]."))
    XCTAssertTrue(ParagraphInlineDetailsAvailability.hasDetails(in: "Use `code` here."))
    XCTAssertTrue(ParagraphInlineDetailsAvailability.hasDetails(in: "Meet on <2026-06-13 Sat>."))
  }

  func testSyntaxEditorDraftBufferIdentifiesDeferredBindingEchoes() {
    let liveText = OrgSyntaxTextEditorDraftBuffer()
    XCTAssertFalse(liveText.isCurrent("Draft"))

    liveText.update("Draft")

    XCTAssertTrue(liveText.isCurrent("Draft"))
    XCTAssertFalse(liveText.isCurrent("Externally updated"))
  }

  func testParagraphSlashCommandUsesBoundedPrefixScan() {
    XCTAssertEqual(ParagraphSlashCommand.query(in: "/todo"), "todo")
    XCTAssertEqual(ParagraphSlashCommand.query(in: " \n\t/source swift"), "source")
    XCTAssertEqual(ParagraphSlashCommand.query(in: "/"), "")
    XCTAssertNil(ParagraphSlashCommand.query(in: "Body /todo"))
    XCTAssertNil(ParagraphSlashCommand.query(in: String(
      repeating: " ",
      count: ParagraphSlashCommand.leadingWhitespaceScanLimit + 1
    ) + "/todo"))
    XCTAssertNil(ParagraphSlashCommand.query(in: "/" + String(
      repeating: "x",
      count: ParagraphSlashCommand.commandScanLimit + 1
    )))

    let todoMatch = ParagraphSlashCommand.match(in: "/todo Call Bob")
    XCTAssertEqual(todoMatch.query, "todo")
    XCTAssertEqual(todoMatch.primaryKind, .todo)
    XCTAssertEqual(todoMatch.kinds.first, .todo)

    let emptyMatch = ParagraphSlashCommand.match(in: "/")
    XCTAssertEqual(emptyMatch.query, "")
    XCTAssertEqual(emptyMatch.kinds, OrgInsertBlockKind.allCases)
    XCTAssertNil(emptyMatch.primaryKind)

    let noMatch = ParagraphSlashCommand.match(in: "Body /todo")
    XCTAssertNil(noMatch.query)
    XCTAssertEqual(noMatch.kinds, [])
    XCTAssertNil(noMatch.primaryKind)

    XCTAssertTrue(ParagraphSlashCommandPanelLayout.isVisible(match: todoMatch))
    XCTAssertTrue(ParagraphSlashCommandPanelLayout.isVisible(match: emptyMatch))
    XCTAssertFalse(ParagraphSlashCommandPanelLayout.isVisible(match: noMatch))
    XCTAssertEqual(ParagraphSlashCommandPanelLayout.verticalOffset(editorHeight: 1), 38)
    XCTAssertEqual(ParagraphSlashCommandPanelLayout.verticalOffset(editorHeight: 80), 110)
    XCTAssertEqual(ParagraphFocusedInlinePanelLayout.verticalOffset(editorHeight: 1), 36)
    XCTAssertEqual(ParagraphFocusedInlinePanelLayout.verticalOffset(editorHeight: 80), 106)
  }

  func testParagraphEditorTextPublishingPolicyDefersRichTextDraftPublishing() {
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("Plain paragraph text"))
    XCTAssertTrue(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("/todo"))
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("See [[id:abc][Alice]]"))
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("Meet <2026-06-12 Fri>"))
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("Use `code`"))

    let longRichParagraph = "See [[id:abc][Alice]]. " + String(repeating: "Long paragraph body ", count: 180)
    XCTAssertFalse(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately(longRichParagraph))
    XCTAssertTrue(ParagraphEditorTextPublishingPolicy.shouldPublishImmediately("/todo " + longRichParagraph))
  }

  func testAIChatFileReferenceDeepLinkRoundTrips() throws {
    let reference = AIChatFileReference(path: "file:notes/daily.org2#L12-L16", line: nil)
    let url = try XCTUnwrap(reference.deepLinkURL)
    let restored = try XCTUnwrap(AIChatFileReference.fromDeepLinkURL(url))

    XCTAssertEqual(restored.path, "notes/daily.org2")
    XCTAssertEqual(restored.line, 12)
  }

  func testAIChatFileReferenceRecognizesRelativePDFLinks() throws {
    let reference = try XCTUnwrap(AIChatFileReference.fromLinkTarget("views/reports/brief.PDF"))

    XCTAssertEqual(reference.path, "views/reports/brief.PDF")
    XCTAssertNil(reference.line)
    XCTAssertEqual(
      AIChatFileReference.extract(from: "Review views/reports/brief.PDF before the meeting."),
      [reference]
    )
  }

  func testCorpusFileSplitsRelativePath() {
    let rootFile = CorpusFile(path: "/tmp/today.org2", relativePath: "today.org2", modifiedAt: nil, byteCount: 10)
    let nestedFile = CorpusFile(path: "/tmp/notes/people/alice.org2", relativePath: "notes/people/alice.org2", modifiedAt: nil, byteCount: 20)

    XCTAssertEqual(rootFile.directory, "")
    XCTAssertEqual(rootFile.name, "today.org2")
    XCTAssertEqual(nestedFile.directory, "notes/people")
    XCTAssertEqual(nestedFile.name, "alice.org2")
  }

  func testQuickOpenStartsNewResultListsAtTheTop() {
    // Typing replaces the results; the List would otherwise keep the old top
    // row anchored and show the new results from the middle.
    XCTAssertTrue(QuickOpenScrollPolicy.resetsToTop(
      previousIDs: ["file:a", "file:b", "file:c"],
      currentIDs: ["file:c", "file:d"]
    ))
    XCTAssertFalse(QuickOpenScrollPolicy.resetsToTop(
      previousIDs: ["file:a", "file:b"],
      currentIDs: ["file:a", "file:b"]
    ))
    XCTAssertFalse(QuickOpenScrollPolicy.resetsToTop(previousIDs: ["file:a"], currentIDs: []))
  }

  @MainActor
  func testQuickOpenSelectionMovesThroughFilteredFiles() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusFiles = [
      CorpusFile(path: "/tmp/alpha.org2", relativePath: "alpha.org2", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: "/tmp/beta.org2", relativePath: "beta.org2", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: "/tmp/notes/gamma.org2", relativePath: "notes/gamma.org2", modifiedAt: nil, byteCount: nil)
    ]

    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "alpha.org2")
    XCTAssertNil(store.selectedQuickOpenFileID)

    store.moveQuickOpenSelection(.down)
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "alpha.org2")

    store.moveQuickOpenSelection(.down)
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "beta.org2")

    store.moveQuickOpenSelection(.up)
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "alpha.org2")

    store.resetQuickOpenSelection()
    store.moveQuickOpenSelection(.up)
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "notes/gamma.org2")

    store.quickOpenQuery = "bet"
    store.resetQuickOpenSelection()
    try await waitForCondition {
      store.quickOpenFiles.map(\.relativePath) == ["beta.org2"]
    }
    XCTAssertEqual(store.selectedQuickOpenFile?.relativePath, "beta.org2")
  }

  @MainActor
  func testQuickOpenKeepsCurrentResultsWhileDebouncedSearchRuns() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.corpusFiles = [
      CorpusFile(path: "/tmp/alpha.org2", relativePath: "alpha.org2", modifiedAt: nil, byteCount: nil),
      CorpusFile(path: "/tmp/beta.org2", relativePath: "beta.org2", modifiedAt: nil, byteCount: nil),
    ]
    try await waitForCondition {
      store.quickOpenItems.count == 2
    }

    store.quickOpenQuery = "no match"

    XCTAssertEqual(store.quickOpenItems.count, 2)
    XCTAssertTrue(store.isFilteringQuickOpenFiles)
    try await waitForCondition {
      !store.isFilteringQuickOpenFiles
    }
    XCTAssertTrue(store.quickOpenItems.isEmpty)
  }

  @MainActor
  func testQuickOpenSearchesAndOpensAIChatThreadsByTitle() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.createAIChatThread(runtime: .openClaw)
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.renameAIChatThread(threadID, title: "Launch readiness review")
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "This message body uses unrelated words.")
    ]
    store.corpusFiles = [
      CorpusFile(path: "/tmp/notes.org2", relativePath: "notes.org2", modifiedAt: nil, byteCount: nil)
    ]

    store.quickOpenQuery = "launch readiness"
    try await waitForCondition {
      store.quickOpenItems.contains {
        guard case .chatThread(let thread) = $0 else { return false }
        return thread.id == threadID
      }
    }

    let item = try XCTUnwrap(store.quickOpenItems.first {
      guard case .chatThread(let thread) = $0 else { return false }
      return thread.id == threadID
    })
    store.selectQuickOpenItem(item)

    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.selectedAIChatThreadID, threadID)

    store.quickOpenQuery = "unrelated words"
    try await waitForCondition {
      !store.isFilteringQuickOpenFiles
    }
    XCTAssertFalse(store.quickOpenItems.contains {
      guard case .chatThread = $0 else { return false }
      return true
    })
  }

  @MainActor
  func testQuickOpenFilePreservesCurrentWorkspaceSurface() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let file = CorpusFile(
      path: "/tmp/quick-open-note.org2",
      relativePath: "quick-open-note.org2",
      modifiedAt: nil,
      byteCount: nil
    )
    store.selectedSurface = .agenda

    store.selectQuickOpenItem(.file(file))

    XCTAssertEqual(store.selectedSurface, .agenda)
    XCTAssertEqual(store.selectedCorpusFileID, file.id)
    XCTAssertEqual(store.selectedLocation?.file, file.path)

    store.selectCorpusFile(file)
    XCTAssertEqual(store.selectedSurface, .files)
  }

  @MainActor
  func testAIChatFileReferenceMapsRemotePathIntoDetailPane() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-link-\(UUID().uuidString)", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let note = notes.appendingPathComponent("alice.org2")
    try """
    #+TITLE: Alice

    * TODO Follow up
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.openClawRemoteCorpusPath = "/srv/org2"
    store.openChatFileReference(AIChatFileReference(path: "/srv/org2/notes/alice.org2", line: 3))

    guard case .aiChatThreadRecord(let thread) = store.selectedLocation else {
      return XCTFail("Expected selected chat file reference")
    }
    XCTAssertEqual(thread.file, note.path)
    XCTAssertEqual(thread.lineForEditor, 3)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.detailScrollRequest?.target, .sourceLine(3))
  }

  @MainActor
  func testAIChatLargePageReferenceRequestsDeepSourceLine() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-link-large-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("large.org2")
    let source = (1...1_600).map { "* Heading \($0)" }.joined(separator: "\n") + "\n"
    try source.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.openChatFileReference(AIChatFileReference(path: note.path, line: 1_400))

    XCTAssertEqual(store.selectedLocation?.lineForEditor, 1_400)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.detailScrollRequest?.target, .sourceLine(1_400))
    try await waitForCondition(timeout: 8) {
      store.selectedEntryHTML?.contains("data-org2-start-line=\"1400\"") == true
    }
  }

  @MainActor
  func testAIChatReferenceWithinActivePageJumpsWithoutReloadingSource() async throws {
    actor SourceLoads {
      private var count = 0
      private var modes: [EntrySourceMode] = []

      func record(mode: EntrySourceMode) {
        count += 1
        modes.append(mode)
      }

      func value() -> Int {
        count
      }

      func recordedModes() -> [EntrySourceMode] {
        modes
      }
    }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-same-page-link-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("talk.org2")
    let text = (1...120).map { "* Slide \($0)" }.joined(separator: "\n") + "\n"
    try text.write(to: note, atomically: true, encoding: .utf8)

    let loads = SourceLoads()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.entrySourceLoaderForTesting = { file, _, mode in
      await loads.record(mode: mode)
      return EntrySource(
        file: file,
        startLine: 1,
        endLineExclusive: 121,
        text: text,
        isSubtree: false
      )
    }

    store.openChatFileReference(AIChatFileReference(path: note.path, line: 1))
    try await waitForCondition(timeout: 8) {
      store.selectedEntrySource?.file == note.path
        && !store.isLoadingEntrySource
    }
    let loadedSource = try XCTUnwrap(store.selectedEntrySource)
    let initialLoadCount = await loads.value()
    let initialLoadModes = await loads.recordedModes()
    XCTAssertEqual(initialLoadCount, 1)
    XCTAssertEqual(initialLoadModes, [.page])

    store.openChatFileReference(AIChatFileReference(path: note.path, line: 80))
    try await Task.sleep(nanoseconds: 100_000_000)

    let finalLoadCount = await loads.value()
    XCTAssertEqual(finalLoadCount, 1)
    XCTAssertEqual(store.selectedEntrySource, loadedSource)
    XCTAssertEqual(store.selectedLocation?.lineForEditor, 1)
    XCTAssertEqual(store.detailScrollRequest?.target, .sourceLine(80))
    XCTAssertFalse(store.isLoadingEntrySource)
  }

  @MainActor
  func testAIChatReferenceWithinActivePageReloadsTimestampPreservingSyncChange() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-same-page-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("talk.org2")
    let original = "#+TITLE: Talk\n\n* Slide Alpha\n"
    let updated = "#+TITLE: Talk\n\n* Slide Bravo\n"
    XCTAssertEqual(original.utf8.count, updated.utf8.count)
    try original.write(to: note, atomically: true, encoding: .utf8)
    let originalModifiedAt = try XCTUnwrap(
      note.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    )

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.openChatFileReference(AIChatFileReference(path: note.path, line: 1))
    try await waitForCondition(timeout: 8) {
      store.selectedEntrySource?.text.contains("Slide Alpha") == true
        && !store.isLoadingEntrySource
    }

    try updated.write(to: note, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: originalModifiedAt],
      ofItemAtPath: note.path
    )
    store.openChatFileReference(AIChatFileReference(path: note.path, line: 3))

    try await waitForCondition(timeout: 8) {
      store.selectedEntrySource?.text.contains("Slide Bravo") == true
        && !store.isLoadingEntrySource
    }
    XCTAssertEqual(store.detailScrollRequest?.target, .sourceLine(3))
  }

  @MainActor
  func testAIChatFileReferenceRevealsDetailFromExpandedChat() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-link-expanded-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("alice.org2")
    try """
    #+TITLE: Alice

    * TODO Follow up
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.makeSurfacePrimary(.aiChat)
    let reference = AIChatFileReference(path: note.path, line: 3)
    store.openChatFileReference(reference)
    try await waitForCondition {
      store.selectedEntrySource != nil
    }

    store.expandSurface(.aiChat)
    XCTAssertTrue(store.isWorkspaceDetailPaneClosed)

    store.openChatFileReference(reference)

    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.selectedLocation?.file, note.path)
    XCTAssertEqual(store.selectedLocation?.lineForEditor, 3)
  }

  @MainActor
  func testDetailNavigationBackRestoresPreviousLocation() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-detail-back-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("first.org2")
    let second = root.appendingPathComponent("second.org2")
    try "#+TITLE: First\n".write(to: first, atomically: true, encoding: .utf8)
    try "#+TITLE: Second\n".write(to: second, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    let firstThread = AIChatThreadRecord(title: "First", file: first.path, line: 1, zone: "test", modifiedAt: nil)
    store.select(.aiChatThreadRecord(firstThread))
    XCTAssertFalse(store.canNavigateBack)

    store.openChatFileReference(AIChatFileReference(path: second.path, line: 1))

    XCTAssertTrue(store.canNavigateBack)
    XCTAssertEqual(store.selectedLocation?.file, second.path)

    store.navigateBack()

    XCTAssertFalse(store.canNavigateBack)
    XCTAssertEqual(store.selectedLocation?.file, first.path)
  }

  @MainActor
  func testWorkspaceNavigationBackRestoresSurfaceSequence() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))

    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertFalse(store.canNavigateBack)

    store.makeSurfacePrimary(.agenda)
    store.makeSurfacePrimary(.files)

    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.canNavigateBack)

    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .agenda)
    XCTAssertTrue(store.canNavigateBack)

    store.navigateBack()
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertFalse(store.canNavigateBack)
  }

  @MainActor
  func testWorkspaceNavigationBackRestoresDocumentAndOwningSurface() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-global-back-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("note.org2")
    let meetingNote = root.appendingPathComponent("meeting.org2")
    try "#+TITLE: Note\n".write(to: note, atomically: true, encoding: .utf8)
    try "#+TITLE: Meeting\n".write(to: meetingNote, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: 0
    ))
    store.selectMeeting(MeetingWorkspaceItem(
      title: "Meeting",
      file: meetingNote.path,
      recordedAt: nil,
      modifiedAt: nil,
      audioArtifact: nil,
      transcriptArtifact: nil,
      transcriptionStatus: nil,
      idValue: nil
    ))

    XCTAssertEqual(store.selectedSurface, .meetings)
    XCTAssertEqual(store.selectedLocation?.file, meetingNote.path)

    store.navigateBack()

    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertEqual(store.selectedLocation?.file, note.path)
  }

  @MainActor
  func testWorkspaceNavigationBackRestoresPaneLayoutChanges() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-pane-layout-back-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("note.org2")
    try "#+TITLE: Note\n".write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: 0
    ))

    store.closeDetailPane()
    XCTAssertTrue(store.isWorkspaceDetailPaneClosed)
    store.navigateBack()
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertEqual(store.selectedLocation?.file, note.path)

    store.toggleDetailPaneExpansion()
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)
    store.navigateBack()
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
    XCTAssertEqual(store.selectedLocation?.file, note.path)

    store.toggleNodeContextPane()
    XCTAssertTrue(store.isNodeContextPanePresented)
    store.navigateBack()
    XCTAssertFalse(store.isNodeContextPanePresented)

    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    store.selectEntrySourceMode(.entry)
    XCTAssertEqual(store.selectedEntrySourceMode, .entry)
    store.navigateBack()
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.selectedLocation?.file, note.path)
  }

  @MainActor
  func testWorkspaceNavigationBackRestoresChatThreadSelection() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-chat-selection-back-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )
    store.createAIChatThread(runtime: .openClaw)
    store.createAIChatThread(runtime: .openClaw)
    store.createAIChatThread(runtime: .openClaw)
    store.makeSurfacePrimary(.aiChat)
    let threads = store.visibleAIChatThreads
    XCTAssertGreaterThanOrEqual(threads.count, 3)

    store.selectAIChatThread(threads[1].id)
    store.selectAIChatThread(threads[2].id)
    XCTAssertEqual(store.selectedAIChatThreadID, threads[2].id)

    store.navigateBack()

    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.selectedAIChatThreadID, threads[1].id)
  }

  @MainActor
  func testBacklinksLoadWhenContextPaneOpens() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-cli-backlinks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("target.org2")
    let source = root.appendingPathComponent("source.org2")
    try """
    #+TITLE: Target

    * Target Heading
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:
    Body
    """.write(to: target, atomically: true, encoding: .utf8)
    try """
    #+TITLE: Source
    :PROPERTIES:
    :ID: 22222222-2222-4222-8222-222222222222
    :END:

    Link to [[id:11111111-1111-4111-8111-111111111111][Target Heading]].
    """.write(to: source, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.backlinksSelectionIdleDelayNanoseconds = 0
    store.backlinksLoaderForTesting = { location in
      XCTAssertEqual(location.file, target.path)
      XCTAssertEqual(location.lineForEditor, 3)
      return try JSONDecoder().decode(BacklinksPayload.self, from: Data("""
      {
        "$schema": "org2:backlinks:v1",
        "id": "11111111-1111-4111-8111-111111111111",
        "backlinks": [
          {
            "srcId": "22222222-2222-4222-8222-222222222222",
            "srcTitle": "Source",
            "file": "\(source.path)",
            "line": 5,
            "context": "Target Heading"
          }
        ]
      }
      """.utf8))
    }
    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Target Heading",
      file: target.path,
      line: 3,
      zone: "test",
      modifiedAt: nil
    ))
    store.toggleNodeContextPane()

    try await waitForCondition { store.backlinks?.backlinks.count == 1 }
    XCTAssertEqual(store.backlinks?.backlinks.first?.file, source.path)
  }

  @MainActor
  func testNodeContextGroupsBacklinksAndSendsBriefRequest() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "org2-workspace-node-context-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let target = root.appendingPathComponent("target.org2")
    let firstSource = root.appendingPathComponent("first.org2")
    let secondSource = root.appendingPathComponent("second.org2")
    let targetID = "11111111-1111-4111-8111-111111111111"
    try """
    #+TITLE: Target Node
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    Canonical target body.
    """.write(to: target, atomically: true, encoding: .utf8)
    try """
    #+TITLE: First Source
    :PROPERTIES:
    :ID: 22222222-2222-4222-8222-222222222222
    :END:

    * First mention
    Link to [[id:\(targetID)][Target Node]].
    * Second mention
    Another [[id:\(targetID)][Target Node]] reference.
    """.write(to: firstSource, atomically: true, encoding: .utf8)
    try """
    #+TITLE: Second Source
    :PROPERTIES:
    :ID: 33333333-3333-4333-8333-333333333333
    :END:

    See [[id:\(targetID)][Target Node]].
    """.write(to: secondSource, atomically: true, encoding: .utf8)

    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      id: targetID,
      file: "target.org2",
      line: 1
    )
    XCTAssertEqual(artifactRelativePath, "views/node-briefs/\(targetID).org")

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { messages, _, _, context in
        let prompt = try XCTUnwrap(messages.last?.content)
        XCTAssertTrue(prompt.contains("Generate a concise, source-cited briefing for the selected Celorga node \"Target Node\""))
        XCTAssertTrue(prompt.contains("Target artifact relative path: \(artifactRelativePath)"))
        XCTAssertTrue(prompt.contains("Target artifact path for the current AI runtime:"))
        XCTAssertTrue(prompt.contains(":ORG2_GENERATOR: Celorga AI chat node brief"))
        XCTAssertFalse(prompt.contains("Target artifact path for OpenClaw:"))
        XCTAssertTrue(prompt.contains(":ORG2_ARTIFACT_ROLE: view"))
        XCTAssertTrue(prompt.contains(":ORG2_REVIEW_STATUS: review-required"))
        XCTAssertTrue(prompt.contains(":ORG2_PROMPT_TEMPLATE: node-brief@v3"))
        XCTAssertTrue(prompt.contains("* Most important facts"))
        XCTAssertTrue(prompt.contains("* Active related tasks"))
        XCTAssertTrue(prompt.contains("* Recent related decisions"))
        XCTAssertTrue(prompt.contains("* Open questions"))
        XCTAssertTrue(prompt.contains("* Node health issues"))
        XCTAssertTrue(prompt.contains("* Sources"))
        XCTAssertTrue(prompt.contains("Before writing, do a current-state sweep."))
        XCTAssertTrue(prompt.contains("Do not discard completed DONE/CANCELED workflow items"))
        XCTAssertTrue(prompt.contains("waiting on reply/response"))
        XCTAssertTrue(prompt.contains("Most important facts: 3-6 bullets, including recent material state changes"))
        XCTAssertTrue(prompt.contains("Open questions: unresolved questions/unknowns/risks, including waiting-on-response states"))
        XCTAssertTrue(prompt.contains("Do not present stable IDs, artifact metadata, file paths, provenance fields, review status, schema fields, or the mere existence of a title/ID as facts or highlights."))
        XCTAssertTrue(prompt.contains("Mention metadata only in \"Node health issues\""))
        XCTAssertTrue(prompt.contains("do not run celorga brief"))
        XCTAssertFalse(prompt.contains("* Review checklist"))
        XCTAssertFalse(prompt.contains("* Reference clusters"))
        XCTAssertFalse(prompt.contains("Deterministic org2 context pack"))
        XCTAssertEqual(context?.backlinks?.backlinks.count, 3)
        XCTAssertEqual(context?.backlinks?.id, targetID)
        return "No artifact written"
      }
    )
    store.setCorpusRoot(root)
    store.select(.aiChatThreadRecord(AIChatThreadRecord(
      title: "Target Node",
      file: target.path,
      line: 1,
      zone: "node",
      modifiedAt: nil,
      idValue: targetID
    )))
    store.toggleNodeContextPane()

    try await waitForCondition {
      store.backlinks?.backlinks.count == 3
    }

    XCTAssertEqual(store.backlinkReferenceCount, 3)
    XCTAssertEqual(store.backlinkFileCount, 2)
    XCTAssertEqual(store.backlinkFileGroups.first?.file, firstSource.path)
    XCTAssertEqual(store.backlinkFileGroups.first?.count, 2)

    let firstGroup = try XCTUnwrap(store.backlinkFileGroups.first)
    store.toggleBacklinkFileGroup(firstGroup)
    XCTAssertTrue(store.expandedBacklinkFileIDs.contains(firstGroup.id))
    store.toggleBacklinkFileGroup(firstGroup)
    XCTAssertFalse(store.expandedBacklinkFileIDs.contains(firstGroup.id))

    store.createAIChatThread(runtime: .openClaw)
    let originalThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Existing unrelated chat")
    ]

    await store.briefCurrentNode()

    XCTAssertEqual(store.aiChatDraft, "")
    XCTAssertNotEqual(store.selectedAIChatThreadID, originalThreadID)
    XCTAssertEqual(store.aiChatThreads.count, 2)
    XCTAssertEqual(store.aiChatMessages.count, 2)
    XCTAssertEqual(store.aiChatMessages.last?.content, "No artifact written")
    XCTAssertEqual(
      store.aiChatThreads.first(where: { $0.id == originalThreadID })?.messages.map(\.content),
      ["Existing unrelated chat"]
    )
    XCTAssertEqual(store.statusText, "Node brief artifact was not written")
  }

  @MainActor
  func testBriefCurrentNodeCanReuseSelectedAIChatThreadWhenConfigured() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-context-current-chat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "org2-workspace-node-context-current-chat-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let target = root.appendingPathComponent("target.org2")
    let targetID = "44444444-4444-4444-8444-444444444444"
    try """
    #+TITLE: Target Node
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    Canonical target body.
    """.write(to: target, atomically: true, encoding: .utf8)

    let recorder = AIChatMessageSendRecorder()
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.setCorpusRoot(root)
    store.aiChatBriefsStartNewThread = false
    store.createAIChatThread(runtime: .openClaw)
    let originalThreadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "Existing context")
    ]
    store.select(.aiChatThreadRecord(AIChatThreadRecord(
      title: "Target Node",
      file: target.path,
      line: 1,
      zone: "node",
      modifiedAt: nil,
      idValue: targetID
    )))

    await store.briefCurrentNode()

    XCTAssertEqual(store.selectedAIChatThreadID, originalThreadID)
    XCTAssertEqual(store.aiChatThreads.count, 1)
    XCTAssertEqual(store.aiChatMessages.count, 3)
    XCTAssertEqual(store.aiChatMessages.first?.content, "Existing context")
    XCTAssertEqual(store.aiChatMessages.last?.content, "reply 1")
    let recordedCalls = await recorder.recordedCalls()
    let requestMessages = try XCTUnwrap(recordedCalls.first)
    XCTAssertEqual(requestMessages.first?.content, "Existing context")
    XCTAssertTrue(requestMessages.last?.content.contains("Generate a concise, source-cited briefing for the selected Celorga node \"Target Node\"") == true)
  }

  func testRelatedBacklinkNodesFilterGenericStructuralHeadingsAndKeepEvidence() {
    let backlinks = [
      BacklinkItem(
        srcId: "summary-id",
        srcTitle: "Summary",
        file: "/corpus/meetings/a.org2",
        line: 2,
        context: "Summary mentions [[id:scarf][Scarf]]."
      ),
      BacklinkItem(
        srcId: "raw-id",
        srcTitle: "Raw transcript",
        file: "/corpus/meetings/a.org2",
        line: 8,
        context: "Raw transcript mentions Scarf."
      ),
      BacklinkItem(
        srcId: "pilot-id",
        srcTitle: "Pilot relaunch details",
        file: "/corpus/projects/pilot.org2",
        line: 10,
        context: "Scarf pilot relaunch should include weekly usage notes."
      ),
      BacklinkItem(
        srcId: "pilot-id",
        srcTitle: "Pilot relaunch details",
        file: "/corpus/meetings/b.org2",
        line: 4,
        context: "Discussed Scarf data infrastructure during relaunch planning."
      ),
      BacklinkItem(
        srcId: "todo-id",
        srcTitle: "TODO Make org2 answer relationship questions like Scarf advisors",
        file: "/corpus/tasks.org2",
        line: 20,
        context: "Use Scarf advisors as a target workflow."
      )
    ]

    let related = WorkspaceStore.relatedBacklinkNodes(from: backlinks) { file in
      file.replacingOccurrences(of: "/corpus/", with: "")
    }

    XCTAssertEqual(related.map(\.title), [
      "Pilot relaunch details",
      "TODO Make org2 answer relationship questions like Scarf advisors"
    ])
    XCTAssertEqual(related.first?.referenceCount, 2)
    XCTAssertEqual(related.first?.fileCount, 2)
    XCTAssertEqual(related.first?.primaryPath, "meetings/b.org2:5")
    XCTAssertEqual(related.first?.examples.count, 2)
    XCTAssertTrue(WorkspaceStore.isGenericRelatedBacklinkTitle("Details"))
    XCTAssertFalse(WorkspaceStore.isGenericRelatedBacklinkTitle("Pilot relaunch details"))
  }

  func testNodeBriefArtifactBodyDropsOrgMetadata() {
    let raw = """
    #+TITLE: Node brief: Frances
    :PROPERTIES:
    :ID: node-brief-frances
    :ORG2_ARTIFACT_ROLE: view
    :END:

    * Highlights
    - Frances is our dog.
    * Sources
    - frances.org:1
    """

    XCTAssertEqual(WorkspaceStore.nodeBriefArtifactTitle(raw), "Node brief: Frances")
    XCTAssertEqual(
      WorkspaceStore.nodeBriefArtifactBody(raw),
      """
      * Highlights
      - Frances is our dog.
      * Sources
      - frances.org:1
      """
    )
  }

  @MainActor
  func testNodeBriefPreviewParsesLargeArtifactOffMainActor() async {
    let body = (0..<25_000).map { index in
      "* Heading \(index)\nBody \(index)"
    }.joined(separator: "\n")
    let artifact = NodeBriefArtifact(
      relativePath: "views/node-briefs/large.org2",
      file: "/tmp/large.org2",
      title: "Large brief",
      body: body,
      modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let revision = NodeBriefPreviewRevision(artifact)
    let threads = ThreadSafeBoolRecorder()

    let preparation = await NodeBriefPreviewBuilder.prepare(
      body: body,
      revision: revision,
      workThreadObserver: { threads.append($0) }
    )

    XCTAssertEqual(threads.values, [false])
    XCTAssertEqual(preparation.revision, revision)
    XCTAssertEqual(preparation.blocks.count, 50_000)
  }

  @MainActor
  func testBriefCurrentNodeOpensCachedArtifact() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-brief-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let targetID = "44444444-4444-4444-8444-444444444444"
    let target = root.appendingPathComponent("target.org2")
    try """
    #+TITLE: Target Node
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    Cached brief target.
    """.write(to: target, atomically: true, encoding: .utf8)

    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      id: targetID,
      file: "target.org2",
      line: 1
    )
    let artifactURL = root.appendingPathComponent(artifactRelativePath)
    try FileManager.default.createDirectory(
      at: artifactURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
    #+TITLE: Node brief: Target Node
    :PROPERTIES:
    :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
    :ORG2_ARTIFACT_ROLE: view
    :ORG2_REVIEW_STATUS: review-required
    :END:

    * Highlights
    Cached result.
    """.write(to: artifactURL, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.aiChatThreadRecord(AIChatThreadRecord(
      title: "Target Node",
      file: target.path,
      line: 1,
      zone: "node",
      modifiedAt: nil,
      idValue: targetID
    )))

    await store.briefCurrentNode()

    XCTAssertEqual(store.aiChatDraft, "")
    XCTAssertEqual(store.selectedSurface, .files)
    guard case .aiChatThreadRecord(let selected)? = store.selectedLocation else {
      XCTFail("Expected cached brief artifact to be selected")
      return
    }
    XCTAssertEqual(selected.file, artifactURL.path)
    XCTAssertEqual(selected.zone, "views/node-briefs")
    XCTAssertEqual(store.statusText, "Opened \(artifactRelativePath)")
  }

  func testNodeBriefArtifactLoadsCachedBody() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-brief-inline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let targetID = "66666666-6666-4666-8666-666666666666"
    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      id: targetID,
      file: "target.org2",
      line: 1
    )
    let artifactURL = root.appendingPathComponent(artifactRelativePath)
    try FileManager.default.createDirectory(
      at: artifactURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
    #+TITLE: Node brief: Target Node
    :PROPERTIES:
    :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
    :ORG2_ARTIFACT_ROLE: view
    :ORG2_REVIEW_STATUS: review-required
    :END:

    * Highlights
    Cached inline result.
    """.write(to: artifactURL, atomically: true, encoding: .utf8)

    let artifact = try XCTUnwrap(WorkspaceStore.nodeBriefArtifact(
      at: artifactURL,
      relativePath: artifactRelativePath
    ))
    XCTAssertEqual(artifact.relativePath, artifactRelativePath)
    XCTAssertEqual(artifact.file, artifactURL.path)
    XCTAssertEqual(artifact.title, "Node brief: Target Node")
    XCTAssertEqual(artifact.body, "* Highlights\nCached inline result.")
  }

  @MainActor
  func testNodeBriefPaneFindsLegacyArtifactWrittenFromDocumentTitle() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-brief-legacy-title-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let targetID = "c0bdbd1e-ba6e-4a67-bf1b-cfe145d0923e"
    let target = root.appendingPathComponent("maven-central.org2")
    try """
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    #+TITLE: Maven Central
    """.write(to: target, atomically: true, encoding: .utf8)

    let legacyRelativePath = WorkspaceStore.legacyNodeBriefArtifactRelativePath(
      title: "Maven Central",
      id: targetID,
      file: "maven-central.org2",
      line: 1
    )
    let legacyURL = root.appendingPathComponent(legacyRelativePath)
    try FileManager.default.createDirectory(
      at: legacyURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try """
    #+TITLE: Node brief: Maven Central
    :PROPERTIES:
    :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
    :ORG2_ARTIFACT_ROLE: view
    :ORG2_PROVENANCE: id:\(targetID), file:maven-central.org2:1
    :ORG2_REVIEW_STATUS: review-required
    :END:

    * Most important facts
    Existing Maven Central brief.
    """.write(to: legacyURL, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: target.path,
      relativePath: "maven-central.org2",
      modifiedAt: nil,
      byteCount: nil
    ))

    try await waitForCondition {
      store.selectedEntrySource?.file == target.path
        && store.currentNodeBriefArtifact?.relativePath == legacyRelativePath
    }

    XCTAssertEqual(store.currentNodeBriefArtifact?.relativePath, legacyRelativePath)
    await store.briefCurrentNode()

    guard case .aiChatThreadRecord(let selected)? = store.selectedLocation else {
      XCTFail("Expected the legacy Maven Central brief to open")
      return
    }
    XCTAssertEqual(selected.file, legacyURL.path)
    XCTAssertEqual(selected.title, "Brief: Maven Central")
    XCTAssertEqual(selected.zone, "views/openclaw/node-briefs")
  }

  @MainActor
  func testBackgroundAgendaRefreshKeepsExistingListInteractive() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-background-agenda-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    try """
    setTimeout(() => {
      process.stdout.write(JSON.stringify({
        "$schema": "org2:agenda:v1",
        "range": { "start": "2026-06-12", "end": "2026-06-18", "days": 7 },
        "overdue": [],
        "days": [{ "date": "2026-06-12", "weekday": "Fri", "items": [] }],
        "skippedFiles": 0
      }));
    }, 350);
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let note = corpus.appendingPathComponent("agenda.org2")
    try "* TODO Existing\n".write(to: note, atomically: true, encoding: .utf8)
    let existingAgenda: AgendaPayload = try JSONDecoder().decode(AgendaPayload.self, from: Data("""
    {
      "$schema": "org2:agenda:v1",
      "range": { "start": "2026-06-12", "end": "2026-06-18", "days": 7 },
      "overdue": [],
      "days": [{
        "date": "2026-06-12",
        "weekday": "Fri",
        "items": [{
          "todo": "TODO",
          "headline": "Existing",
          "kind": "SCHEDULED",
          "file": "\(note.path)",
          "line": 1,
          "body": "",
          "level": 1,
          "tags": [],
          "properties": {}
        }]
      }],
      "skippedFiles": 0
    }
    """.utf8))
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus)
    store.agenda = existingAgenda

    let refresh = Task { await store.refreshAgenda(preserveSelection: true, updatesStatus: false) }
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertFalse(store.isLoadingAgenda)
    XCTAssertEqual(store.agenda?.totalItemCount, 1)

    await refresh.value

    XCTAssertFalse(store.isLoadingAgenda)
    XCTAssertEqual(store.agenda?.totalItemCount, 0)
  }

  @MainActor
  func testBackgroundApprovalRefreshKeepsExistingListInteractive() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-background-approvals-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    let note = corpus.appendingPathComponent("approvals.org2")
    try "* TODO Review thing\n".write(to: note, atomically: true, encoding: .utf8)
    let encodedPath = String(data: try JSONEncoder().encode(note.path), encoding: .utf8)!
    try """
    const fs = require("fs");
    const state = "\(workspace.appendingPathComponent("approval-state.txt").path)";
    const count = fs.existsSync(state) ? Number(fs.readFileSync(state, "utf8")) + 1 : 1;
    fs.writeFileSync(state, String(count));
    const payload = count === 1 ? {
      count: 1,
      items: [{
        title: "Review thing",
        status: "review-required",
        todo: "TODO",
        level: 1,
        file: \(encodedPath),
        line: 1,
        idValue: "approval-1",
        properties: { ID: "approval-1", REVIEW_STATUS: "review-required" },
        body: "Existing body.",
        tags: []
      }]
    } : { count: 0, items: [] };
    setTimeout(() => {
      process.stdout.write(JSON.stringify(payload));
    }, count === 1 ? 0 : 350);
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus)
    await store.refreshApprovals(updatesStatus: true)
    XCTAssertEqual(store.approvalItems.count, 1)

    let refresh = Task { await store.refreshApprovals(updatesStatus: false) }
    try await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertFalse(store.isLoadingApprovals)
    XCTAssertEqual(store.approvalItems.count, 1)

    await refresh.value

    XCTAssertFalse(store.isLoadingApprovals)
    XCTAssertTrue(store.approvalItems.isEmpty)
  }

  @MainActor
  func testManualApprovalRefreshQueuesBehindBackgroundRefresh() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-manual-approval-refresh-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    let note = corpus.appendingPathComponent("approvals.org2")
    let state = workspace.appendingPathComponent("approval-state.txt")
    try "* TODO Review thing\n".write(to: note, atomically: true, encoding: .utf8)
    let encodedPath = String(data: try JSONEncoder().encode(note.path), encoding: .utf8)!
    try """
    const fs = require("fs");
    const state = "\(state.path)";
    const count = fs.existsSync(state) ? Number(fs.readFileSync(state, "utf8")) + 1 : 1;
    fs.writeFileSync(state, String(count));
    const payload = {
      count: 1,
      items: [{
        title: count < 3 ? "Existing approval" : "New approval",
        status: "review-required",
        todo: "TODO",
        level: 1,
        file: \(encodedPath),
        line: 1,
        idValue: "approval-1",
        properties: { ID: "approval-1", REVIEW_STATUS: "review-required" },
        body: "Review body.",
        tags: []
      }]
    };
    setTimeout(() => {
      process.stdout.write(JSON.stringify(payload));
    }, count === 2 ? 350 : 0);
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus)
    await store.refreshApprovals(updatesStatus: true)
    XCTAssertEqual(store.approvalItems.map(\.title), ["Existing approval"])

    let backgroundRefresh = Task { await store.refreshApprovals() }
    try await Task.sleep(nanoseconds: 100_000_000)
    await store.refreshApprovals(updatesStatus: true)

    XCTAssertTrue(store.isLoadingApprovals)
    XCTAssertEqual(store.statusText, "Refreshing approvals next...")

    await backgroundRefresh.value
    try await waitForCondition {
      store.approvalItems.map(\.title) == ["New approval"]
        && (try? String(contentsOf: state, encoding: .utf8)) == "3"
        && !store.isLoadingApprovals
    }
  }

  @MainActor
  func testReviewPageRefreshLoadsOnlyApprovals() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-local-approval-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    * TODO Review the new draft
    :PROPERTIES:
    :STATUS: waiting-on-approval
    :END:
    """.write(to: root.appendingPathComponent("approval.org2"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.runsAndReviewPage = .review
    var agentRunRefreshCount = 0
    store.agentRunListLoaderForTesting = {
      agentRunRefreshCount += 1
      return []
    }

    await store.refreshSelectedRunReviewPage(updatesStatus: true)

    XCTAssertEqual(store.approvalItems.map(\.title), ["Review the new draft"])
    XCTAssertEqual(agentRunRefreshCount, 0)
    XCTAssertTrue(store.agentRuns.isEmpty)
    XCTAssertTrue(store.agentGoals.isEmpty)
    XCTAssertTrue(store.agentProfiles.isEmpty)
    XCTAssertTrue(store.agentWorkflows.isEmpty)
  }

  @MainActor
  func testKnownEmptyApprovalQueueDoesNotReturnToInitialLoadingState() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-empty-approvals-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    try """
    setTimeout(() => {
      process.stdout.write(JSON.stringify({ count: 0, items: [] }));
    }, 250);
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus, persistsDefault: false)

    XCTAssertFalse(store.hasCompletedApprovalsLoad)
    store.isLoadingApprovals = true
    XCTAssertTrue(store.shouldShowInitialApprovalsLoadingState)
    store.isLoadingApprovals = false
    await store.refreshApprovals()
    XCTAssertTrue(store.hasCompletedApprovalsLoad)
    XCTAssertTrue(store.approvalItems.isEmpty)

    store.isLoadingApprovals = true
    XCTAssertFalse(store.shouldShowInitialApprovalsLoadingState)
    store.isLoadingApprovals = false
  }

  @MainActor
  func testApprovalFallbackScanDoesNotBlockMainActor() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approval-fallback-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    try "process.exit(1);\n".write(
      to: dist.appendingPathComponent("cli.js"),
      atomically: true,
      encoding: .utf8
    )
    try """
    * TODO Review fallback approval
    :PROPERTIES:
    :STATUS: review-required
    :END:
    """.write(
      to: corpus.appendingPathComponent("approval.org2"),
      atomically: true,
      encoding: .utf8
    )

    let scanStarted = ThreadSafeTestFlag()
    let releaseScan = DispatchSemaphore(value: 0)
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus, persistsDefault: false)
    store.approvalCandidateScanOperationForTesting = {
      if scanStarted.setIfUnset() {
        _ = releaseScan.wait(timeout: .now() + 2)
      }
    }

    let refresh = Task { await store.refreshApprovals() }
    let waitStartedAt = Date()
    while !scanStarted.value, Date().timeIntervalSince(waitStartedAt) < 3 {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(scanStarted.value)
    XCTAssertLessThan(Date().timeIntervalSince(waitStartedAt), 3)
    store.statusText = "Main actor remained responsive"
    XCTAssertEqual(store.statusText, "Main actor remained responsive")

    releaseScan.signal()
    await refresh.value
  }

  @MainActor
  func testBackgroundAssignedWorkRefreshKeepsExistingListInteractive() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-background-assigned-\(UUID().uuidString)", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    let note = corpus.appendingPathComponent("assigned.org2")
    try "* TODO Unassigned after refresh\n".write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(corpus)
    store.assignedWorkItems = [
      AssignedWorkItem(
        file: note.path,
        line: 1,
        headline: "Existing assigned work",
        todo: "TODO",
        assignee: "Avi",
        status: "ready"
      )
    ]

    await store.refreshAssignedWork(showsLoading: false)

    XCTAssertFalse(store.isLoadingAssignedWork)
    XCTAssertTrue(store.assignedWorkItems.isEmpty)
  }

  @MainActor
  func testEmptyAssignedWorkInitialLoadDoesNotRepeatOnAppearance() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-empty-assigned-\(UUID().uuidString)", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(corpus)

    XCTAssertFalse(store.hasAttemptedAssignedWorkLoad)
    await store.refreshAssignedWorkIfNeeded()
    XCTAssertTrue(store.hasAttemptedAssignedWorkLoad)
    XCTAssertTrue(store.assignedWorkItems.isEmpty)

    let note = corpus.appendingPathComponent("assigned.org2")
    try """
    * TODO Review assigned work
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: ready
    :END:
    """.write(to: note, atomically: true, encoding: .utf8)

    await store.refreshAssignedWorkIfNeeded()
    XCTAssertTrue(store.assignedWorkItems.isEmpty)

    await store.refreshAssignedWork(showsLoading: false)
    XCTAssertEqual(store.assignedWorkItems.map(\.headline), ["Review assigned work"])
  }

  @MainActor
  func testBackgroundAIChatThreadRefreshKeepsExistingListInteractive() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-background-openclaw-\(UUID().uuidString)", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    let agents = corpus.appendingPathComponent("agents", isDirectory: true)
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)

    let staleThread = AIChatThreadRecord(
      title: "Existing thread",
      file: agents.appendingPathComponent("old.org2").path,
      zone: "agents",
      modifiedAt: nil
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(corpus)
    store.aiChatThreadRecords = [staleThread]

    await store.refreshAIChatThreadRecords(showsLoading: false)

    XCTAssertFalse(store.isLoadingAIChatThreadRecords)
    XCTAssertTrue(store.aiChatThreadRecords.isEmpty)
  }

  @MainActor
  func testBriefCurrentNodeAutoOpensArtifactAfterAIChatWritesIt() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-brief-autoload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let targetID = "55555555-5555-4555-8555-555555555555"
    let target = root.appendingPathComponent("target.org2")
    try """
    #+TITLE: Target Node
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    Auto-open brief target.
    """.write(to: target, atomically: true, encoding: .utf8)

    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      id: targetID,
      file: "target.org2",
      line: 1
    )
    let artifactURL = root.appendingPathComponent(artifactRelativePath)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatSendHandler: { messages, _, _, _ in
        XCTAssertTrue(messages.last?.content.contains("Target artifact relative path: \(artifactRelativePath)") == true)
        try FileManager.default.createDirectory(
          at: artifactURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try """
        #+TITLE: Node brief: Target Node
        :PROPERTIES:
        :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
        :ORG2_ARTIFACT_ROLE: view
        :ORG2_REVIEW_STATUS: review-required
        :END:

        * Highlights
        Generated result.
        """.write(to: artifactURL, atomically: true, encoding: .utf8)
        return "Wrote \(artifactRelativePath)"
      }
    )
    store.setCorpusRoot(root)
    store.select(.aiChatThreadRecord(AIChatThreadRecord(
      title: "Target Node",
      file: target.path,
      line: 1,
      zone: "node",
      modifiedAt: nil,
      idValue: targetID
    )))

    await store.briefCurrentNode()

    guard case .aiChatThreadRecord(let selected)? = store.selectedLocation else {
      XCTFail("Expected generated brief artifact to be selected")
      return
    }
    XCTAssertEqual(selected.file, artifactURL.path)
    XCTAssertEqual(selected.title, "Brief: Target Node")
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.aiChatMessages.last?.changeSummary?.files.contains(where: { $0.relativePath == artifactRelativePath }) == true)
  }

  @MainActor
  func testBriefCurrentNodeAutoOpensArtifactWrittenAfterAIChatReply() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-brief-delayed-autoload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let targetID = "77777777-7777-4777-8777-777777777777"
    let target = root.appendingPathComponent("target.org2")
    try """
    #+TITLE: Target Node
    :PROPERTIES:
    :ID: \(targetID)
    :END:

    Delayed auto-open brief target.
    """.write(to: target, atomically: true, encoding: .utf8)

    let artifactRelativePath = WorkspaceStore.nodeBriefArtifactRelativePath(
      id: targetID,
      file: "target.org2",
      line: 1
    )
    let artifactURL = root.appendingPathComponent(artifactRelativePath)
    let artifactPath = artifactURL.path
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatSendHandler: { _, _, _, _ in
        Task.detached {
          try? await Task.sleep(nanoseconds: 250_000_000)
          try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: artifactPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try? """
          #+TITLE: Node brief: Target Node
          :PROPERTIES:
          :ORG2_ARTIFACT_SCHEMA: org2-artifact-metadata/v1
          :ORG2_ARTIFACT_ROLE: view
          :ORG2_REVIEW_STATUS: review-required
          :END:

          * Highlights
          Delayed generated result.
          """.write(toFile: artifactPath, atomically: true, encoding: .utf8)
        }
        return "Queued artifact write"
      }
    )
    store.setCorpusRoot(root)
    store.select(.aiChatThreadRecord(AIChatThreadRecord(
      title: "Target Node",
      file: target.path,
      line: 1,
      zone: "node",
      modifiedAt: nil,
      idValue: targetID
    )))

    await store.briefCurrentNode()

    guard case .aiChatThreadRecord(let selected)? = store.selectedLocation else {
      XCTFail("Expected delayed generated brief artifact to be selected")
      return
    }
    XCTAssertEqual(selected.file, artifactURL.path)
    XCTAssertEqual(selected.title, "Brief: Target Node")
    XCTAssertEqual(store.statusText, "Opened \(artifactRelativePath)")
  }

  @MainActor
  func testWorkspaceSearchScansCorpusRecursively() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-recursive-search-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let note = nested.appendingPathComponent("launch.org2")
    try """
    #+TITLE: Launch

    * TODO Launch checklist
    The recursive workspace search should find this nested full text phrase.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.searchQuery = "nested full text"

    await store.runSearch()

    XCTAssertEqual(store.searchResults.count, 1)
    XCTAssertEqual(store.searchResults.first?.file, note.path)
    XCTAssertEqual(store.searchResults.first?.heading, "Launch checklist")
    XCTAssertEqual(store.selectedSurface, .home)
  }

  func testWorkspaceSearchPrioritizesActiveTodosForDisplay() {
    let done = searchResult(file: "/tmp/archive.org2", line: 2, heading: "Done item", todo: "DONE")
    let plain = searchResult(file: "/tmp/note.org2", line: 3, heading: "Plain note", todo: nil)
    let active = searchResult(file: "/tmp/action.org2", line: 4, heading: "Active item", todo: "TODO")

    let displayResults = WorkspaceStore.prioritizedSearchResultsForDisplay([done, plain, active])

    XCTAssertEqual(displayResults.map(\.heading), ["Active item", "Plain note", "Done item"])
  }

  @MainActor
  func testWorkspaceTextSearchSectionsUseExplicitPriorityOrder() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let active = searchResult(file: "/tmp/action.org2", line: 4, heading: "Active item", todo: "TODO")
    let entry = searchResult(file: "/tmp/entry.org2", line: 8, heading: "Finished entry", todo: "DONE")
    let corpusText = searchResult(file: "/tmp/prose.org2", line: 2, heading: nil, todo: nil)
    let file = CorpusFile(
      path: "/tmp/project.org2",
      relativePath: "project.org2",
      modifiedAt: nil,
      byteCount: 100
    )
    let page = OrgRoamNodeReference(
      idValue: "page-id",
      title: "Project Page",
      file: file.path,
      line: 1,
      isPageNode: true
    )
    let threadID = UUID()
    let chatThread = AIChatSearchResult(
      threadID: threadID,
      messageID: nil,
      matchKind: .threadTitle,
      title: "Project chat",
      snippet: "Thread title match",
      messageCount: 2,
      updatedAt: Date()
    )
    let chatMessage = AIChatSearchResult(
      threadID: threadID,
      messageID: UUID(),
      matchKind: .messageText,
      title: "Another chat",
      snippet: "Message body match",
      messageCount: 2,
      updatedAt: Date()
    )
    let approval = WorkspaceAgentWorkSearchResult(
      id: "run-approval:run-1:approval-1",
      kind: .approval,
      recordID: "approval-1",
      parentRunID: "run-1",
      title: "Approve outreach",
      snippet: "Send the reviewed follow-up",
      status: "approved",
      sourceReference: "Run run-1"
    )

    store.searchResults = [corpusText, entry, active]
    store.workspaceFileSearchResults = [file]
    store.aiChatSearchResults = [chatMessage, chatThread]
    store.workspaceAgentWorkSearchResults = [approval]
    store.workspacePageSearchResults = [page]

    XCTAssertEqual(store.workspaceTextSearchSections.map(\.category), [
      .activeTodos,
      .files,
      .chatThreads,
      .approvals,
      .pages,
      .entries,
      .chatMessages,
      .corpusText
    ])
    XCTAssertEqual(store.workspaceTextSearchResultCount, 8)
    guard case .entry(let terminalTodo) = store.workspaceTextSearchSections[5].items[0] else {
      return XCTFail("Expected terminal TODO under Entries")
    }
    XCTAssertEqual(terminalTodo.todo, "DONE")
  }

  @MainActor
  func testWorkspaceAgentWorkSearchFindsHistoricalApprovedBoundary() throws {
    let payload = try JSONDecoder().decode(AgentRunListPayload.self, from: Data(#"""
    {
      "schema": "org2:run-list:v1",
      "runs": [{
        "id": "25eade4e-71d1-4f1c-a496-5cf5a9ef093c",
        "goal": "Prepare the customer follow-up",
        "acceptanceCriteria": [],
        "status": "running",
        "riskClass": "external-action",
        "capabilities": [],
        "context": [],
        "plan": [],
        "artifacts": [],
        "approvals": [{
          "id": "atruedev-original",
          "title": "Approve ATrueDev exhausted-credit check-in",
          "action": "send the original follow-up to gary@atruedev.com",
          "riskClass": "external-action",
          "status": "revised",
          "requestedAt": "2026-08-08T15:30:00.000Z",
          "decidedAt": "2026-08-08T15:45:00.000Z",
          "decidedBy": "Avi",
          "decisionNote": "Superseded during voice review"
        }, {
          "id": "atruedev-feedback",
          "title": "Approve revised ATrueDev feedback check-in",
          "action": "send feedback to gary@atruedev.com",
          "riskClass": "external-action",
          "status": "approved",
          "requestedAt": "2026-08-08T16:00:00.000Z",
          "decidedAt": "2026-08-08T16:01:00.000Z",
          "decidedBy": "Avi",
          "decisionNote": "Approved over voice from iOS"
        }],
        "validations": [],
        "comments": [],
        "events": [],
        "createdAt": "2026-08-08T15:00:00.000Z",
        "updatedAt": "2026-08-08T16:01:00.000Z"
      }]
    }
    """#.utf8))

    let results = WorkspaceStore.searchAgentWorkForWorkspace(
      runs: payload.runs,
      approvals: [],
      workflows: [],
      goals: [],
      profiles: [],
      query: "atruedev",
      limitPerCategory: 25
    )

    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(results.first?.kind, .approval)
    XCTAssertEqual(results.first?.title, "Approve revised ATrueDev feedback check-in")
    XCTAssertEqual(results.first?.status, "approved")
    XCTAssertEqual(results.first?.parentRunID, payload.runs.first?.id)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.replaceAgentRunsForTesting(payload.runs)
    store.selectAgentWorkSearchResult(try XCTUnwrap(results.first))
    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.runsAndReviewPage, .runs)
    XCTAssertEqual(store.selectedAgentRunID, payload.runs.first?.id)
  }

  func testWorkspaceChatSearchSeparatesThreadTitlesFromMessageText() {
    let thread = AIChatThread(
      id: UUID(),
      title: "Billing reconciliation",
      createdAt: Date(),
      updatedAt: Date(),
      sessionKey: "search-test",
      messages: [
        AIChatMessage(role: .user, content: "Review the billing reconciliation details.")
      ]
    )

    let results = WorkspaceStore.searchAIChatThreads(
      [thread],
      query: "billing",
      limit: 10
    )

    XCTAssertEqual(results.map(\.matchKind), [.threadTitle, .messageText])
    XCTAssertNil(results[0].messageID)
    XCTAssertNotNil(results[1].messageID)
  }

  func testWorkspaceChatSearchDoesNotExposeHiddenAutomaticPromptText() {
    let message = AIChatMessage(
      role: .user,
      content: AIChatContextPresentation.automaticContext(
        kind: "approval item",
        title: "Approve Dashjoin first-touch draft",
        reference: ".org2/runs/run-123.org2:40",
        prompt: "AUTOMATIC_INTERNAL_PAYLOAD Review the exact unsent Gmail draft.",
        userText: "Please revise the repetitive phrasing."
      )
    )
    let thread = AIChatThread(
      id: UUID(),
      title: "Draft revision",
      createdAt: Date(),
      updatedAt: Date(),
      sessionKey: "hidden-search-test",
      messages: [message]
    )

    let visibleResults = WorkspaceStore.searchAIChatThreads(
      [thread],
      query: "repetitive",
      limit: 10
    )
    let hiddenResults = WorkspaceStore.searchAIChatThreads(
      [thread],
      query: "AUTOMATIC_INTERNAL_PAYLOAD",
      limit: 10
    )

    XCTAssertEqual(visibleResults.map(\.matchKind), [.messageText])
    XCTAssertEqual(visibleResults.first?.snippet, "[Context: Approve Dashjoin first-touch draft] Please revise the repetitive phrasing.")
    XCTAssertTrue(hiddenResults.isEmpty)
  }

  func testWorkspaceFileAndPageSearchUseDistinctMatchSurfaces() {
    let projectFile = CorpusFile(
      path: "/tmp/projects/roadmap.org2",
      relativePath: "projects/roadmap.org2",
      modifiedAt: nil,
      byteCount: nil
    )
    let page = OrgRoamNodeReference(
      idValue: nil,
      title: "Revenue Roadmap",
      aliases: ["Growth Plan"],
      file: projectFile.path,
      line: 1,
      isPageNode: true
    )

    XCTAssertEqual(
      WorkspaceStore.searchCorpusFilesForWorkspace(
        [projectFile],
        query: "projects",
        limit: 10
      ).map(\.relativePath),
      ["projects/roadmap.org2"]
    )
    XCTAssertTrue(
      WorkspaceStore.searchPageNodesForWorkspace(
        [page],
        query: "projects",
        limit: 10
      ).isEmpty
    )
    XCTAssertEqual(
      WorkspaceStore.searchPageNodesForWorkspace(
        [page],
        query: "growth",
        limit: 10
      ).map(\.title),
      ["Revenue Roadmap"]
    )
  }

  func testWorkspaceSearchGroupsRepeatedFileResultsForDisplay() {
    let done = searchResult(file: "/tmp/accounts.org2", line: 12, heading: "Done account note", todo: "DONE")
    let active = searchResult(file: "/tmp/accounts.org2", line: 4, heading: "Active account todo", todo: "WAIT")
    let other = searchResult(file: "/tmp/meeting.org2", line: 2, heading: "Meeting note", todo: nil)
    let displayResults = WorkspaceStore.prioritizedSearchResultsForDisplay([done, other, active])

    let groups = WorkspaceStore.groupedSearchResultsForDisplay(displayResults)

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups.first?.file, "/tmp/accounts.org2")
    XCTAssertEqual(groups.first?.representative.heading, "Active account todo")
    XCTAssertEqual(groups.first?.additionalCount, 1)
    XCTAssertEqual(groups.last?.file, "/tmp/meeting.org2")
  }

  @MainActor
  func testWorkspaceSearchIncludesAIChatThreads() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.aiChatMessages = [
      AIChatMessage(role: .user, content: "How should we structure chat thread navigation?"),
      AIChatMessage(role: .assistant, content: "Nest threads under OpenClaw in the sidebar.")
    ]
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.searchQuery = "sidebar"

    await store.runSearch()

    XCTAssertTrue(store.searchResults.isEmpty)
    XCTAssertEqual(store.aiChatSearchResults.count, 1)
    XCTAssertEqual(store.aiChatSearchResults.first?.threadID, threadID)
    XCTAssertEqual(store.selectedSurface, .home)

    let result = try XCTUnwrap(store.aiChatSearchResults.first)
    store.selectAIChatSearchResult(result)

    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.selectedAIChatThreadID, threadID)
  }

  @MainActor
  func testWorkspaceSearchPromotesMatchedThreadAtTopOfSidebarUntilAnotherThreadIsSelected() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-search-promoted-thread-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("openclaw-chat.json")
    )

    let matchedThreadID = store.createAIChatThread(runtime: .openClaw)
    store.renameAIChatThread(matchedThreadID, title: "Older matched thread")
    let otherThreadID = store.createAIChatThread(runtime: .openClaw)
    store.renameAIChatThread(otherThreadID, title: "Newer active thread")
    store.settleAIChatThread(matchedThreadID)

    let result = AIChatSearchResult(
      threadID: matchedThreadID,
      messageID: nil,
      matchKind: .threadTitle,
      title: "Older matched thread",
      snippet: "Thread title match",
      messageCount: 0,
      updatedAt: Date()
    )
    store.selectAIChatSearchResult(result)

    XCTAssertEqual(store.sidebarPromotedAIChatThreadID, matchedThreadID)
    XCTAssertEqual(store.sidebarAIChatThreads.first?.id, matchedThreadID)
    XCTAssertTrue(try XCTUnwrap(store.sidebarAIChatThreads.first).isSettled)
    XCTAssertFalse(store.sidebarSettledAIChatThreads.contains(where: { $0.id == matchedThreadID }))

    store.reopenAIChatThread(matchedThreadID)

    XCTAssertEqual(store.sidebarAIChatThreads.first?.id, matchedThreadID)
    XCTAssertFalse(try XCTUnwrap(store.sidebarAIChatThreads.first).isSettled)

    store.selectAIChatThread(otherThreadID)

    XCTAssertNil(store.sidebarPromotedAIChatThreadID)
    XCTAssertEqual(store.sidebarAIChatThreads.map(\.id), store.visibleAIChatThreads.map(\.id))
  }

  @MainActor
  func testWorkspaceNodeSearchFiltersIndexedNodesAndOpensSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-node-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("alpha.org2")
    try """
    #+TITLE: Alpha Project
    #+ROAM_ALIASES: "Apollo"
    :PROPERTIES:
    :ID: alpha-id
    :END:

    * Beta Heading
    :PROPERTIES:
    :ID: beta-id
    :END:
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshCorpusFiles()

    try await waitForCondition {
      store.orgRoamLinkResolver.nodes.count == 2
    }

    store.searchMode = .nodes
    store.searchQuery = "apollo"
    try await waitForCondition {
      store.searchNodes.first?.title == "Alpha Project"
    }
    XCTAssertEqual(store.searchNodes.first?.title, "Alpha Project")

    store.searchQuery = "beta"
    try await waitForCondition {
      store.searchNodes.isEmpty
    }
    XCTAssertTrue(store.searchNodes.isEmpty)

    store.searchQuery = "alpha"
    try await waitForCondition {
      store.searchNodes.first?.title == "Alpha Project"
    }
    let alpha = try XCTUnwrap(store.searchNodes.first)
    store.selectSearchNode(alpha)

    XCTAssertEqual(store.selectedSurface, .search)
    XCTAssertEqual(store.selectedLocation?.title, "Alpha Project")
    XCTAssertEqual(store.selectedLocation?.file, note.path)
    XCTAssertEqual(store.selectedLocation?.lineForEditor, 1)
    XCTAssertNil(store.renderedSearchHighlightQuery)
  }

  @MainActor
  func testCorpusFileBrowserScansFiltersAndOpensFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-files-\(UUID().uuidString)", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    let ignored = root.appendingPathComponent("node_modules/pkg", isDirectory: true)
    let versioned = root.appendingPathComponent(".stversions/notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: versioned, withIntermediateDirectories: true)

    let alice = notes.appendingPathComponent("alice.org2")
    try """
    #+TITLE: Alice
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:

    * Note
    Body
    """.write(to: alice, atomically: true, encoding: .utf8)
    try "# Scratch\n".write(to: root.appendingPathComponent("scratch.md"), atomically: true, encoding: .utf8)
    try "ignored\n".write(to: ignored.appendingPathComponent("ignored.org2"), atomically: true, encoding: .utf8)
    try "ignored snapshot\n".write(to: versioned.appendingPathComponent("alice~20260706-100605.org2"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshCorpusFiles()

    XCTAssertEqual(store.corpusFiles.map(\.relativePath), ["notes/alice.org2", "scratch.md"])

    store.quickOpenQuery = "ali"
    try await waitForCondition {
      store.quickOpenFiles.first?.relativePath == "notes/alice.org2"
    }
    XCTAssertEqual(store.quickOpenFiles.first?.relativePath, "notes/alice.org2")

    try await waitForCondition {
      !store.isScanningCorpusFiles
    }
    store.selectCorpusFile(try XCTUnwrap(store.quickOpenFiles.first))
    try await waitForCondition {
      store.selectedEntrySource?.file == alice.path && store.selectedLocation?.idValue == "11111111-1111-4111-8111-111111111111"
    }

    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.selectedEntrySource?.startLine, 1)
  }

  @MainActor
  func testGlobalKeyboardShortcutsNavigateWorkspaceSurfaces() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "1", keyCode: 18, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .home)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "2", keyCode: 19, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .agenda)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "3", keyCode: 20, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .files)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "4", keyCode: 21, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.searchFocusToken, 0)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "F", keyCode: 3, modifiers: [.command, .shift])))
    XCTAssertEqual(store.selectedSurface, .search)
    XCTAssertEqual(store.searchFocusToken, 1)

    store.select(.aiChatThreadRecord(AIChatThreadRecord(
      title: "Current page",
      file: "/tmp/current.org",
      line: 1,
      zone: "corpus",
      modifiedAt: nil,
      idValue: nil
    )))
    let surfaceBeforePageFind = store.selectedSurface
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "f", keyCode: 3, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, surfaceBeforePageFind)
    XCTAssertTrue(store.isPageSearchPresented)
    XCTAssertEqual(store.pageSearchFocusToken, 1)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "5", keyCode: 23, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .meetings)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "2", keyCode: 19, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .agenda)
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "m", keyCode: 46, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .meetings)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "6", keyCode: 22, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .aiChat)
    let threadFindGeneration = store.aiChatFindRequestGeneration
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "f", keyCode: 3, modifiers: [.command])))
    XCTAssertEqual(store.aiChatFindRequestGeneration, threadFindGeneration + 1)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "K", keyCode: 40, modifiers: [.command, .shift])))
    XCTAssertEqual(store.selectedSurface, .skills)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "R", keyCode: 15, modifiers: [.command, .shift])))
    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.runsAndReviewPage, .review)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "a", keyCode: 0, modifiers: [.command, .option])))
    XCTAssertEqual(store.selectedSurface, .approvals)
    XCTAssertEqual(store.runsAndReviewPage, .workflows)

    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "f", keyCode: 3, modifiers: [.command, .option])))
    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "w", keyCode: 13, modifiers: [.command, .option])))
    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "p", keyCode: 35, modifiers: [.command, .option])))

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "7", keyCode: 26, modifiers: [.command, .shift])))
    XCTAssertFalse(store.isDailyNoteDatePickerPresented)
    XCTAssertEqual(store.statusText, "No corpus selected")

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "0", keyCode: 29, modifiers: [.command])))
    XCTAssertEqual(store.selectedSurface, .sources)
    XCTAssertFalse(store.isAIChatAssistantPresented)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "/", keyCode: 44, modifiers: [.command])))
    XCTAssertTrue(store.isKeyboardShortcutsPresented)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "z", keyCode: 6, modifiers: [.command])))
    XCTAssertEqual(store.statusText, "Nothing to undo")

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "Z", keyCode: 6, modifiers: [.command, .shift])))
    XCTAssertEqual(store.statusText, "Nothing to redo")

    XCTAssertFalse(store.handleGlobalKeyDown(
      keyDown(characters: "z", keyCode: 6, modifiers: [.command]),
      scope: .globalOnly
    ))
    XCTAssertFalse(store.handleGlobalKeyDown(
      keyDown(characters: "Z", keyCode: 6, modifiers: [.command, .shift]),
      scope: .globalOnly
    ))
    XCTAssertFalse(store.handleGlobalKeyDown(
      keyDown(characters: "s", keyCode: 1, modifiers: [.command]),
      scope: .globalOnly
    ))
  }

  @MainActor
  func testCommandFFollowsClickedPaneInSplitChatAndRenderedDocument() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.makeSurfacePrimary(.aiChat)
    store.select(.aiChatThreadRecord(AIChatThreadRecord(
      title: "Rendered page",
      file: "/tmp/rendered-page.org2",
      line: 1,
      zone: "test",
      modifiedAt: nil
    )))
    let commandF = keyDown(characters: "f", keyCode: 3, modifiers: [.command])

    store.activateWorkspacePane(.detail)
    let chatFindGeneration = store.aiChatFindRequestGeneration
    XCTAssertTrue(store.handleGlobalKeyDown(commandF))
    XCTAssertTrue(store.isPageSearchPresented)
    XCTAssertEqual(store.pageSearchFocusToken, 1)
    XCTAssertEqual(store.aiChatFindRequestGeneration, chatFindGeneration)

    store.activateWorkspacePane(.surface)
    XCTAssertTrue(store.handleGlobalKeyDown(commandF))
    XCTAssertEqual(store.aiChatFindRequestGeneration, chatFindGeneration + 1)
    XCTAssertEqual(store.pageSearchFocusToken, 1)
  }

  @MainActor
  func testGlobalKeyboardShortcutsIncludeRefreshAndSave() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-global-menu-keys-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))

    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "r", keyCode: 15, modifiers: [.command])))
    XCTAssertFalse(store.handleGlobalKeyDown(keyDown(characters: "s", keyCode: 1, modifiers: [.command])))

    store.setCorpusRoot(root)
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "r", keyCode: 15, modifiers: [.command])))
  }

  func testWorkspaceKeyboardEventRoutingLetsCommandShortcutsThroughTextInputs() {
    XCTAssertEqual(
      WorkspaceKeyboardEventRouting.scope(
        for: keyDown(characters: "1", keyCode: 18, modifiers: [.command]),
        textInputActive: true
      ),
      .globalOnly
    )
    XCTAssertEqual(
      WorkspaceKeyboardEventRouting.scope(
        for: keyDown(characters: "Z", keyCode: 6, modifiers: [.command, .shift]),
        textInputActive: true
      ),
      .globalOnly
    )
    XCTAssertEqual(
      WorkspaceKeyboardEventRouting.scope(
        for: keyDown(characters: "f", keyCode: 3, modifiers: [.command, .option]),
        textInputActive: true
      ),
      .globalOnly
    )
    XCTAssertNil(WorkspaceKeyboardEventRouting.scope(
      for: keyDown(characters: "j", keyCode: 38),
      textInputActive: true
    ))
    XCTAssertNil(WorkspaceKeyboardEventRouting.scope(
      for: keyDown(characters: "f", keyCode: 3, modifiers: [.command, .control]),
      textInputActive: true
    ))
    XCTAssertEqual(
      WorkspaceKeyboardEventRouting.scope(
        for: keyDown(characters: "j", keyCode: 38),
        textInputActive: false
      ),
      .all
    )

    XCTAssertTrue(WorkspaceKeyboardEventRouting.defersToNativeSourceEditor(
      keyDown(characters: "k", keyCode: 40, modifiers: [.command]),
      sourceEditorActive: true
    ))
    XCTAssertFalse(WorkspaceKeyboardEventRouting.defersToNativeSourceEditor(
      keyDown(characters: "k", keyCode: 40, modifiers: [.command]),
      sourceEditorActive: false
    ))
    XCTAssertFalse(WorkspaceKeyboardEventRouting.defersToNativeSourceEditor(
      keyDown(characters: "K", keyCode: 40, modifiers: [.command, .shift]),
      sourceEditorActive: true
    ))
    XCTAssertFalse(WorkspaceKeyboardEventRouting.defersToNativeSourceEditor(
      keyDown(characters: "p", keyCode: 35, modifiers: [.command]),
      sourceEditorActive: true
    ))
    XCTAssertTrue(WorkspaceKeyboardEventRouting.defersToNativeSourceEditor(
      keyDown(characters: "f", keyCode: 3, modifiers: [.command]),
      sourceEditorActive: true
    ))
    XCTAssertFalse(WorkspaceKeyboardEventRouting.defersToNativeSourceEditor(
      keyDown(characters: "F", keyCode: 3, modifiers: [.command, .shift]),
      sourceEditorActive: true
    ))
    XCTAssertFalse(WorkspaceKeyboardEventRouting.defersToNativeSourceEditor(
      keyDown(characters: "f", keyCode: 3, modifiers: [.command]),
      sourceEditorActive: false
    ))
  }

  @MainActor
  func testGlobalQuickOpenShortcutRequiresCorpus() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-global-keys-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "p", keyCode: 35, modifiers: [.command])))
    XCTAssertFalse(store.isQuickOpenPresented)

    store.setCorpusRoot(root)
    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "k", keyCode: 40, modifiers: [.command])))
    XCTAssertTrue(store.isQuickOpenPresented)
  }

  func testWorkspaceSurfaceShortcutTitlesMatchCommandNavigation() {
    XCTAssertEqual(WorkspaceSurface.home.commandShortcutTitle, "⌘1")
    XCTAssertEqual(WorkspaceSurface.agenda.commandShortcutTitle, "⌘2")
    XCTAssertEqual(WorkspaceSurface.savedViews.commandShortcutTitle, "⌥⌘V")
    XCTAssertEqual(WorkspaceSurface.canvases.commandShortcutTitle, "⌥⌘C")
    XCTAssertEqual(WorkspaceSurface.externalThreads.commandShortcutTitle, "⌥⌘E")
    XCTAssertEqual(WorkspaceSurface.approvals.commandShortcutTitle, "⌘4")
    XCTAssertEqual(WorkspaceSurface.files.commandShortcutTitle, "⌘3")
    XCTAssertEqual(WorkspaceSurface.search.commandShortcutTitle, "⌘⇧F")
    XCTAssertEqual(WorkspaceSurface.meetings.commandShortcutTitle, "⌘5/⌘M")
    XCTAssertEqual(WorkspaceSurface.sources.commandShortcutTitle, "⌘0")
    XCTAssertEqual(WorkspaceSurface.aiChat.commandShortcutTitle, "⌘6")
    XCTAssertEqual(WorkspaceSurface.skills.commandShortcutTitle, "⌘⇧K")
    XCTAssertEqual(
      WorkspaceSurface.sidebarCases,
      [.home, .activity, .agenda, .approvals, .meetings, .sources, .skills, .externalThreads, .savedViews]
    )
    XCTAssertEqual(
      WorkspaceSurface.sidebarCases(experimentalFeaturesEnabled: true).suffix(2),
      [.savedViews, .canvases]
    )
    for surface in WorkspaceSurface.sidebarCases(experimentalFeaturesEnabled: true) {
      XCTAssertFalse(surface.commandShortcutTitle.isEmpty, "\(surface.title) needs a shortcut")
    }
  }

  func testSidebarShortcutHintsOnlyRevealForCommandModifier() {
    XCTAssertTrue(CommandShortcutReveal.isActive(for: [.command]))
    XCTAssertTrue(CommandShortcutReveal.isActive(for: [.command, .shift]))
    XCTAssertFalse(CommandShortcutReveal.isActive(for: [.shift]))
    XCTAssertFalse(CommandShortcutReveal.isActive(for: []))
  }

  func testSidebarStartsAtItsOneQuarterMaximumWidth() {
    XCTAssertEqual(WorkspaceSidebarLayout.maximumWidth(for: 1_400), 350)
    XCTAssertEqual(WorkspaceSidebarLayout.maximumWidth(for: 800), 200)
    XCTAssertEqual(WorkspaceSidebarLayout.maximumWidth(for: 600), WorkspaceSidebarLayout.minimumWidth)
    XCTAssertEqual(
      WorkspaceSidebarLayout.defaultWidth(for: 1_400),
      WorkspaceSidebarLayout.maximumWidth(for: 1_400)
    )
    XCTAssertEqual(
      WorkspaceSidebarLayout.defaultWidth(for: 800),
      WorkspaceSidebarLayout.maximumWidth(for: 800)
    )
  }

  @MainActor
  func testDetailPaneLayoutActionsCloseExpandAndReopenOnSelection() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let thread = AIChatThreadRecord(
      title: "Current page",
      file: "/tmp/current.org2",
      line: 1,
      zone: "test",
      modifiedAt: nil
    )
    store.select(.aiChatThreadRecord(thread))
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)

    store.closeDetailPane()
    XCTAssertTrue(store.isWorkspaceDetailPaneClosed)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)

    store.toggleDetailPaneExpansion()
    XCTAssertFalse(store.isWorkspaceDetailPaneExpanded)
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)

    store.toggleDetailPaneExpansion()
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneExpanded)

    store.makeDetailPanePrimary()
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneExpanded)

    store.closeDetailPane()
    store.select(.aiChatThreadRecord(thread))
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
  }

  @MainActor
  func testAIChatAssistantRequestsUseWorkspaceSurface() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    XCTAssertFalse(store.isNodeContextPanePresented)
    let thread = AIChatThreadRecord(
      title: "Current page",
      file: "/tmp/current.org2",
      line: 1,
      zone: "test",
      modifiedAt: nil
    )

    store.select(.aiChatThreadRecord(thread))
    XCTAssertFalse(store.isNodeContextPanePresented)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)

    store.toggleNodeContextPane()
    XCTAssertTrue(store.isNodeContextPanePresented)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)

    store.selectedSurface = .agenda
    store.isWorkspaceSurfacePaneClosed = false
    store.isNodeContextPanePresented = false
    store.setAIChatAssistantPanelPresented(true)
    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertFalse(store.isAIChatAssistantPresented)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
  }

  func testWorkspaceHealthChecksReportRepoBuildAndCorpusReadiness() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-health-\(UUID().uuidString)", isDirectory: true)
    let dist = root.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try "{}".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "".write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
    try "".write(to: dist.appendingPathComponent("parse.js"), atomically: true, encoding: .utf8)

    let corpus = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    let checks = WorkspaceStore.workspaceHealthChecks(cli: Org2CLI(repoRoot: root), corpusRoot: corpus)

    XCTAssertEqual(checks.first { $0.id == "repo-root" }?.status, .ready)
    XCTAssertEqual(checks.first { $0.id == "node-build" }?.status, .ready)
    XCTAssertEqual(checks.first { $0.id == "corpus-root" }?.status, .ready)
    XCTAssertEqual(checks.first { $0.id == "corpus-config" }?.status, .warning)
    XCTAssertNotNil(checks.first { $0.id == "node-modules" }?.remediationTitle)
  }

  @MainActor
  func testGlobalDailyNoteShortcutsCreateAndOpenDailyFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-shortcuts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: "7", keyCode: 26, modifiers: [.command])))
    await store.waitForDailyNoteNavigationForTesting()

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let todayFileName = "\(formatter.string(from: Date())).\(OrgDocumentDefaults.preferredExtension)"
    let today = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent(todayFileName)
      .standardizedFileURL

    XCTAssertTrue(FileManager.default.fileExists(atPath: today.path))
    XCTAssertEqual(store.selectedCorpusFileID, today.path)
    XCTAssertEqual(store.selectedSurface, .home)

    XCTAssertTrue(store.handleGlobalKeyDown(keyDown(
      characters: "7",
      keyCode: 26,
      modifiers: [.command, .shift]
    )))
    XCTAssertTrue(store.isDailyNoteDatePickerPresented)
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.year = 2024
    components.month = 2
    components.day = 29
    store.dailyNotePickerDate = try XCTUnwrap(components.date)
    store.openDailyNoteFromDatePicker()
    XCTAssertFalse(store.isDailyNoteDatePickerPresented)
    await store.waitForDailyNoteNavigationForTesting()

    let arbitrary = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent("2024-02-29.\(OrgDocumentDefaults.preferredExtension)")
      .standardizedFileURL
    XCTAssertTrue(FileManager.default.fileExists(atPath: arbitrary.path))
    XCTAssertEqual(store.selectedCorpusFileID, arbitrary.path)
    XCTAssertEqual(store.selectedSurface, .home)
  }

  func testDailyNoteTargetsPutTodayFirstAndExposeCommandShortcuts() {
    XCTAssertEqual(DailyNoteTarget.allCases, [.today, .yesterday, .tomorrow])
    XCTAssertEqual(DailyNoteTarget.today.commandShortcutTitle, "⌘7")
    XCTAssertEqual(DailyNoteTarget.yesterday.commandShortcutTitle, "⌘8")
    XCTAssertEqual(DailyNoteTarget.tomorrow.commandShortcutTitle, "⌘9")
    XCTAssertEqual(DailyNoteTarget.datePickerCommandShortcutTitle, "⌘⇧7")
  }

  func testAgendaSurfaceIsNamedAgenda() {
    XCTAssertEqual(WorkspaceSurface.agenda.title, "Agenda")
  }

  @MainActor
  func testAgendaFilterFocusLetsTypingBypassAgendaShortcuts() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.selectedSurface = .agenda
    store.isAgendaFilterFocused = true

    XCTAssertFalse(store.handleAgendaKeyDown(keyDown(characters: "o", keyCode: 31)))
    XCTAssertFalse(store.handleAgendaKeyDown(keyDown(characters: "r", keyCode: 15)))
    XCTAssertFalse(store.handleAgendaKeyDown(keyDown(characters: "a", keyCode: 0, modifiers: [.command])))
    XCTAssertTrue(store.isAgendaFilterFocused)

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "\u{1b}", keyCode: 53)))
    XCTAssertFalse(store.isAgendaFilterFocused)
  }

  @MainActor
  func testAgendaItemSelectionClearsFilterFocusForShortcuts() throws {
    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Filtered task",
      "kind": "SCHEDULED",
      "file": "/tmp/filtered.org2",
      "line": 1,
      "body": "",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.selectedSurface = .agenda
    store.agendaFilter = "filtered"
    store.isAgendaFilterFocused = true

    store.handleAgendaItemClick(item)

    XCTAssertFalse(store.isAgendaFilterFocused)
    XCTAssertEqual(store.selectedAgendaItemID, item.id)
    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "p", keyCode: 35)))
    XCTAssertTrue(store.priorityModeActive)
  }

  @MainActor
  func testAgendaDisplayModeChangeDoesNotOpenEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-mode-no-open-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-mode.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO Today task
    SCHEDULED: <\(today)>

    * DONE Closed task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()
    store.selectedLocation = nil
    store.selectedAgendaItemID = nil

    store.agendaMode = .today
    store.syncAgendaSelectionAfterDisplayOptionsChange()

    XCTAssertNotNil(store.selectedAgendaItemID)
    XCTAssertNil(store.selectedLocation)
    XCTAssertTrue(store.consumeAgendaSelectionActivationSuppression())
    XCTAssertFalse(store.consumeAgendaSelectionActivationSuppression())
  }

  @MainActor
  func testRangeAgendaLoadsItemsBeyondTheFirstWeek() throws {
    let calendar = Calendar(identifier: .gregorian)
    let start = Date(timeIntervalSince1970: 1_776_297_600) // 2026-04-16 00:00:00 UTC
    let end = WorkspaceStore.agendaRefreshEndDate(from: start, calendar: calendar)
    XCTAssertEqual(calendar.dateComponents([.day], from: start, to: end).day, 29)

    let payload = try JSONDecoder().decode(AgendaPayload.self, from: Data("""
    {
      "$schema": "org2:agenda:v1",
      "range": { "start": "2026-04-16", "end": "2026-05-15", "days": 30 },
      "overdue": [],
      "days": [
        {
          "date": "2026-04-16",
          "weekday": "Thursday",
          "items": [{ "todo": "TODO", "headline": "Today task", "kind": "SCHEDULED", "file": "/tmp/range.org2", "line": 1, "tags": [], "properties": {} }]
        },
        {
          "date": "2026-04-22",
          "weekday": "Wednesday",
          "items": [{ "todo": "TODO", "headline": "First-week task", "kind": "SCHEDULED", "file": "/tmp/range.org2", "line": 4, "tags": [], "properties": {} }]
        },
        {
          "date": "2026-04-26",
          "weekday": "Sunday",
          "items": [{ "todo": "TODO", "headline": "Later task", "kind": "DEADLINE", "file": "/tmp/range.org2", "line": 7, "tags": [], "properties": {} }]
        }
      ],
      "skippedFiles": 0
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.agenda = payload
    store.agendaMode = .range

    XCTAssertEqual(store.agenda?.range.days, 30)
    XCTAssertEqual(store.agendaDisplaySections.map(\.label), ["Today", "Next 7 days", "Later"])
    XCTAssertEqual(store.agendaDisplaySections.first { $0.label == "Next 7 days" }?.items.map(\.headline), [
      "First-week task"
    ])
    XCTAssertEqual(store.agendaDisplaySections.first { $0.label == "Later" }?.items.map(\.headline), [
      "Later task"
    ])
  }

  @MainActor
  func testUpcomingDeadlineWarningShowsInTodayAndFocusAsADistinctRow() throws {
    let payload = try JSONDecoder().decode(AgendaPayload.self, from: Data("""
    {
      "$schema": "org2:agenda:v1",
      "range": { "start": "2026-10-09", "end": "2026-11-07", "days": 30 },
      "overdue": [],
      "days": [
        {
          "date": "2026-10-09",
          "weekday": "Friday",
          "items": [{ "todo": "TODO", "headline": "Unscheduled deadline", "kind": "DEADLINE", "file": "/tmp/warn.org", "line": 0, "tags": [], "properties": {}, "deadlineWarning": { "due": "2026-10-15", "daysUntil": 6 } }]
        },
        {
          "date": "2026-10-15",
          "weekday": "Thursday",
          "items": [{ "todo": "TODO", "headline": "Unscheduled deadline", "kind": "DEADLINE", "file": "/tmp/warn.org", "line": 0, "tags": [], "properties": {} }]
        }
      ],
      "skippedFiles": 0
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.agenda = payload

    store.agendaMode = .focus
    let focusToday = try XCTUnwrap(store.agendaDisplaySections.first { $0.label == "Today" })
    XCTAssertEqual(focusToday.items.map(\.headline), ["Unscheduled deadline"])
    XCTAssertEqual(focusToday.items.first?.planningLabel, "DEADLINE due in 6 days (2026-10-15)")

    store.agendaMode = .today
    XCTAssertEqual(store.agendaDisplaySections.first { $0.label == "Today" }?.items.count, 1)

    store.agendaMode = .range
    let warning = try XCTUnwrap(store.agendaDisplaySections.first { $0.label == "Today" }?.items.first)
    let due = try XCTUnwrap(store.agendaDisplaySections.first { $0.label == "Next 7 days" }?.items.first)
    XCTAssertNotEqual(warning.id, due.id)
    XCTAssertEqual(due.planningLabel, "DEADLINE")
    XCTAssertEqual(warning.replacing(todo: "DONE").id, warning.id)
  }

  @MainActor
  func testAgendaUppercaseJKScrollDetailPaneWithoutMovingSelection() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.selectedSurface = .agenda
    store.selectedAgendaItemID = "selected-agenda-item"

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "J", keyCode: 38, modifiers: [.shift])))
    XCTAssertEqual(store.detailScrollRequest, DetailScrollRequest(id: 1, direction: .down))
    XCTAssertEqual(store.selectedAgendaItemID, "selected-agenda-item")

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "K", keyCode: 40, modifiers: [.shift])))
    XCTAssertEqual(store.detailScrollRequest, DetailScrollRequest(id: 2, direction: .up))
    XCTAssertEqual(store.selectedAgendaItemID, "selected-agenda-item")
  }

  @MainActor
  func testCompletingAgendaItemSelectsNextActionableAgendaRowWithoutActivatingEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-done-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)

    await store.applyTodoShortcut(.done)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE Second task"))
    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    XCTAssertEqual(store.selectedAgendaItemID, third.id)
    XCTAssertTrue(store.consumeAgendaSelectionActivationSuppression())
    guard case .agenda(let selected)? = store.selectedLocation else {
      return XCTFail("Expected agenda selection")
    }
    XCTAssertEqual(selected.headline, "Second task")
  }

  @MainActor
  func testRepeatedAgendaDoneKeysAdvanceRowsInsteadOfEditingSelectedHeading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-repeated-done-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-repeated-done.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>

    * TODO Fourth task
    SCHEDULED: <\(today)>

    * TODO Fifth task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    store.selectAgendaItem(third)
    try await waitForCondition {
      store.selectedEntrySource?.file == note.path
        && store.selectedEntryHTML?.contains("Third task") == true
        && !store.isLoadingEntrySource
        && !store.isRenderingEntrySource
        && !store.selectedRenderedBlocks.isEmpty
    }

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Third task"
      }
      return false
    })
    store.selectBlock(heading)

    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertNil(store.editingBlockID)

    try await waitForCondition(timeout: 10) {
      ((try? String(contentsOf: note, encoding: .utf8)) ?? "")
        .components(separatedBy: "* DONE ")
        .count == 4
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE Third task"))
    XCTAssertTrue(updated.contains("* DONE Fourth task"))
    XCTAssertTrue(updated.contains("* DONE Fifth task"))
    XCTAssertTrue(updated.contains("* TODO First task"))
    XCTAssertTrue(updated.contains("* TODO Second task"))
    XCTAssertFalse(updated.contains("ddd"))
  }

  @MainActor
  func testAgendaRefreshCannotRestoreRowsDuringRepeatedDoneBurst() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-done-refresh-barrier-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("agenda-done-refresh-barrier.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()
    store.todoStatusMutationForTesting = { status, file, line in
      try await Task.sleep(nanoseconds: 250_000_000)
      let fileURL = URL(fileURLWithPath: file)
      var lines = try String(contentsOf: fileURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      lines[line - 1] = lines[line - 1].replacingOccurrences(
        of: " TODO ",
        with: " \(status.label) "
      )
      try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
      return status.label
    }

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First task" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(first)

    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Second task", "Third task"])
    XCTAssertEqual(store.selectedAgendaItemID, second.id)

    // This models the filesystem watcher completing an agenda query while the
    // mutation is still in flight. The stale disk row must not reappear.
    await store.refreshAgenda(preserveSelection: true, updatesStatus: false)
    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Second task", "Third task"])
    XCTAssertEqual(store.selectedAgendaItemID, second.id)

    try await waitForCondition(timeout: 10) {
      ((try? String(contentsOf: note, encoding: .utf8)) ?? "").contains("* DONE First task")
        && store.visibleAgendaItems.map(\.headline) == ["Second task", "Third task"]
    }
  }

  @MainActor
  func testAgendaRefreshStartedBeforeDoneCannotRestoreCompletedRow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-preexisting-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("agenda-preexisting-refresh.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let gate = AgendaRefreshPublicationGate()
    let blocksFirstRefresh = ThreadSafeTestFlag()
    let stalePayload = try JSONDecoder().decode(AgendaPayload.self, from: Data("""
    {
      "$schema": "org2:agenda:v1",
      "range": { "start": "\(today.prefix(10))", "end": "\(today.prefix(10))", "days": 1 },
      "overdue": [],
      "days": [{
        "date": "\(today.prefix(10))",
        "weekday": "Today",
        "items": [
          { "todo": "TODO", "headline": "First task", "kind": "SCHEDULED", "file": "\(note.path)", "line": 1, "tags": [], "properties": {} },
          { "todo": "TODO", "headline": "Second task", "kind": "SCHEDULED", "file": "\(note.path)", "line": 4, "tags": [], "properties": {} }
        ]
      }],
      "skippedFiles": 0
    }
    """.utf8))
    let freshPayload = try JSONDecoder().decode(AgendaPayload.self, from: Data("""
    {
      "$schema": "org2:agenda:v1",
      "range": { "start": "\(today.prefix(10))", "end": "\(today.prefix(10))", "days": 1 },
      "overdue": [],
      "days": [{
        "date": "\(today.prefix(10))",
        "weekday": "Today",
        "items": [
          { "todo": "TODO", "headline": "Second task", "kind": "SCHEDULED", "file": "\(note.path)", "line": 5, "tags": [], "properties": {} }
        ]
      }],
      "skippedFiles": 0
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.agendaRefreshLoaderForTesting = { _ in
      if blocksFirstRefresh.setIfUnset() {
        await gate.wait()
        return stalePayload
      }
      return freshPayload
    }
    store.todoStatusMutationForTesting = { status, file, line in
      let fileURL = URL(fileURLWithPath: file)
      var lines = try String(contentsOf: fileURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      lines[line - 1] = lines[line - 1].replacingOccurrences(
        of: " TODO ",
        with: " \(status.label) "
      )
      try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
      return status.label
    }
    store.setCorpusRoot(root)
    let staleRefresh = Task {
      await store.refreshAgenda(preserveSelection: true, updatesStatus: false)
    }
    await gate.waitUntilStarted()
    store.agenda = stalePayload

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First task" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(first)
    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Second task"])
    XCTAssertEqual(store.selectedAgendaItemID, second.id)

    try await waitForCondition(timeout: 10) {
      ((try? String(contentsOf: note, encoding: .utf8)) ?? "").contains("* DONE First task")
    }
    XCTAssertTrue(
      ((try? String(contentsOf: note, encoding: .utf8)) ?? "").contains("* DONE First task"),
      "TODO mutation did not finish: \(store.statusText) / \(store.errorText ?? "no error")"
    )
    try await Task.sleep(nanoseconds: 250_000_000)
    await gate.release()
    try await waitForCondition(timeout: 10) {
      !store.isRefreshingAgendaForTesting
    }
    XCTAssertFalse(store.isRefreshingAgendaForTesting, "Stale agenda refresh did not finish")
    await staleRefresh.value

    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["Second task"])
    XCTAssertEqual(
      store.visibleAgendaItems.first { $0.id == store.selectedAgendaItemID }?.headline,
      "Second task"
    )
    try await waitForCondition(timeout: 10) {
      store.visibleAgendaItems.map(\.headline) == ["Second task"]
    }
  }

  @MainActor
  func testAgendaDoneWhilePreviewRendersKeepsNextRowSelected() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-done-render-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("agenda-done-render-race.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.agendaEntryRenderIdleDelayNanoseconds = 0
    store.entryHTMLRendererForTesting = { _, _, _, _ in
      try? await Task.sleep(nanoseconds: 400_000_000)
      return "<html>Delayed agenda preview</html>"
    }
    await store.refreshAgenda()

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First task" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    store.selectAgendaItem(first)
    try await waitForCondition { store.isRenderingEntrySource }

    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertEqual(store.selectedAgendaItemID, second.id)
    XCTAssertFalse(store.isRenderingEntrySource)

    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(store.selectedAgendaItemID, second.id)
    XCTAssertTrue(store.visibleAgendaItems.contains { $0.id == second.id })
    XCTAssertTrue(store.handleWorkspaceKeyDown(keyDown(characters: "d", keyCode: 2)))
    XCTAssertEqual(store.selectedAgendaItemID, third.id)
  }

  @MainActor
  func testAgendaRefreshRemapsHighlightAcrossLineShiftWhilePreviewFinishes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-refresh-selection-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("agenda-refresh-selection-race.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())
    let original = """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.agendaEntryRenderIdleDelayNanoseconds = 0
    store.entryHTMLRendererForTesting = { _, _, _, _ in
      try? await Task.sleep(nanoseconds: 400_000_000)
      return "<html>Delayed agenda preview</html>"
    }
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)
    try await waitForCondition { store.isRenderingEntrySource }

    try ("Intro line\n" + original).write(to: note, atomically: true, encoding: .utf8)
    await store.refreshAgenda()

    let shiftedSecond = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    XCTAssertNotEqual(second.id, shiftedSecond.id)
    XCTAssertEqual(store.selectedAgendaItemID, shiftedSecond.id)

    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(store.selectedAgendaItemID, shiftedSecond.id)
  }

  @MainActor
  func testAgendaRefreshDoesNotReplaceHighlightWhenSelectedRowIsTemporarilyMissing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-missing-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("agenda-missing-selection.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())
    let firstOnly = """
    * TODO First task
    SCHEDULED: <\(today)>
    """
    let original = """
    \(firstOnly)

    * TODO Second task
    SCHEDULED: <\(today)>
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)
    try firstOnly.write(to: note, atomically: true, encoding: .utf8)
    await store.refreshAgenda()

    XCTAssertEqual(store.visibleAgendaItems.map(\.headline), ["First task"])
    XCTAssertEqual(store.selectedAgendaItemID, second.id)
  }

  @MainActor
  func testTransientEmptyAgendaRefreshDoesNotDiscardHighlightIntent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-transient-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("agenda-transient-empty.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())
    let original = """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)
    try "Temporary sync placeholder\n".write(to: note, atomically: true, encoding: .utf8)
    await store.refreshAgenda()
    XCTAssertTrue(store.visibleAgendaItems.isEmpty)
    XCTAssertEqual(store.selectedAgendaItemID, second.id)

    try ("Intro line\n" + original).write(to: note, atomically: true, encoding: .utf8)
    await store.refreshAgenda()
    let restoredSecond = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    XCTAssertEqual(store.selectedAgendaItemID, restoredSecond.id)
  }

  @MainActor
  func testCancelingAgendaItemSelectsNextActionableAgendaRowWithoutActivatingEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-canceled-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)

    await store.applyTodoShortcut(.canceled)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* CANCELED Second task"))
    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    XCTAssertEqual(store.selectedAgendaItemID, third.id)
    XCTAssertTrue(store.consumeAgendaSelectionActivationSuppression())
    guard case .agenda(let selected)? = store.selectedLocation else {
      return XCTFail("Expected agenda selection")
    }
    XCTAssertEqual(selected.headline, "Second task")
  }

  @MainActor
  func testAgendaLocationStatusChangeSelectsNextRowWithoutActivatingEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-location-status-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)

    await store.applyTodoShortcut(.canceled, to: .agenda(second))

    XCTAssertNil(store.errorText, "TODO mutation failed: \(store.errorText ?? store.statusText)")
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* CANCELED Second task"))
    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    XCTAssertEqual(store.selectedAgendaItemID, third.id)
    XCTAssertTrue(store.consumeAgendaSelectionActivationSuppression())
    guard case .agenda(let selected)? = store.selectedLocation else {
      return XCTFail("Expected agenda selection")
    }
    XCTAssertEqual(selected.headline, "Second task")
  }

  @MainActor
  func testNonTerminalAgendaStatusChangeStaysOnCurrentRow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-active-status-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.selectAgendaItem(second)

    await store.applyTodoShortcut(.inProgress)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* IN_PROGRESS Second task"))
    let updatedSecond = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    XCTAssertEqual(store.selectedAgendaItemID, updatedSecond.id)
    XCTAssertFalse(store.consumeAgendaSelectionActivationSuppression())
    guard case .agenda(let selected)? = store.selectedLocation else {
      return XCTFail("Expected agenda selection")
    }
    XCTAssertEqual(selected.headline, "Second task")
  }

  @MainActor
  func testBulkAgendaDoneMarksCheckedItems() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-bulk-done-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-bulk.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()
    store.selectedSurface = .agenda

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "a", keyCode: 0, modifiers: [.command])))
    XCTAssertEqual(store.bulkAgendaSelectionCount, 3)
    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "a", keyCode: 0, modifiers: [.command, .shift])))
    XCTAssertEqual(store.bulkAgendaSelectionCount, 0)

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First task" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.toggleAgendaItemBulkSelection(first)
    store.toggleAgendaItemBulkSelection(second)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 2)

    await store.applyTodoShortcut(.done)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE First task"))
    XCTAssertTrue(updated.contains("* DONE Second task"))
    XCTAssertTrue(updated.contains("* TODO Third task"))
    XCTAssertEqual(store.bulkAgendaSelectionCount, 0)
  }

  @MainActor
  func testAgendaShiftArrowsExtendBulkSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-shift-bulk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-shift-bulk.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>

    * TODO Third task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First task" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    let third = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Third task" })
    store.selectAgendaItem(second)

    store.activateWorkspacePane(.detail)
    XCTAssertFalse(store.handleWorkspaceKeyDown(keyDown(characters: "a", keyCode: 0, modifiers: [.command])))
    XCTAssertEqual(store.bulkAgendaSelectionCount, 0)
    store.activateWorkspacePane(.surface)

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(keyCode: 125, modifiers: [.shift])))
    XCTAssertTrue(store.isAgendaItemBulkSelected(second))
    XCTAssertTrue(store.isAgendaItemBulkSelected(third))
    XCTAssertFalse(store.isAgendaItemBulkSelected(first))
    XCTAssertEqual(store.selectedAgendaItemID, third.id)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 2)

    store.clearAgendaBulkSelection()
    store.selectAgendaItem(second)

    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(keyCode: 126, modifiers: [.shift])))
    XCTAssertTrue(store.isAgendaItemBulkSelected(first))
    XCTAssertTrue(store.isAgendaItemBulkSelected(second))
    XCTAssertFalse(store.isAgendaItemBulkSelected(third))
    XCTAssertEqual(store.selectedAgendaItemID, first.id)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 2)
    try await waitForCondition {
      store.selectedEntrySource?.file == note.path && !store.isLoadingEntrySource && !store.isLoadingBacklinks
    }
  }

  @MainActor
  func testAgendaCommandClickTogglesBulkSelectionForRow() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-command-click-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-command-click.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>

    * TODO Second task
    SCHEDULED: <\(today)>
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second task" })
    store.handleAgendaItemClick(second, modifiers: [.command])

    XCTAssertTrue(store.isAgendaItemBulkSelected(second))
    XCTAssertEqual(store.selectedAgendaItemID, second.id)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 1)

    store.handleAgendaItemClick(second, modifiers: [.command])
    XCTAssertFalse(store.isAgendaItemBulkSelected(second))
    XCTAssertEqual(store.selectedAgendaItemID, second.id)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 0)
    try await waitForCondition {
      store.selectedEntrySource?.file == note.path && !store.isLoadingEntrySource && !store.isLoadingBacklinks
    }
  }

  @MainActor
  func testBulkSelectedAgendaItemsStartFreshAIThreadWithEveryItemAsContext() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-multi-context-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("agenda.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    try """
    * TODO Prepare launch
    Details

    * TODO Review pricing
    Details
    """.write(to: note, atomically: true, encoding: .utf8)

    let payloadData = try JSONSerialization.data(withJSONObject: [
      "$schema": "org2:agenda:v1",
      "range": ["start": today, "end": today, "days": 1],
      "overdue": [],
      "days": [[
        "date": today,
        "weekday": "Today",
        "items": [
          [
            "todo": "TODO",
            "headline": "Prepare launch",
            "kind": "SCHEDULED",
            "file": note.path,
            "line": 0,
            "tags": [],
            "properties": [:]
          ],
          [
            "todo": "TODO",
            "headline": "Review pricing",
            "kind": "SCHEDULED",
            "file": note.path,
            "line": 3,
            "tags": [],
            "properties": [:]
          ]
        ]
      ]],
      "skippedFiles": 0
    ])
    let payload = try JSONDecoder().decode(AgendaPayload.self, from: payloadData)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.openClawRemoteCorpusPath = "/remote/org2"
    store.agenda = payload
    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Prepare launch" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Review pricing" })
    store.toggleAgendaItemBulkSelection(first)
    store.toggleAgendaItemBulkSelection(second)

    store.startNewAIThreadFromAgendaSelection(including: second)

    let presentation = AIChatContextPresentation(store.aiChatDraft)
    XCTAssertEqual(presentation.contexts.map(\.title), ["Prepare launch", "Review pricing"])
    XCTAssertEqual(presentation.contexts.map(\.reference), [
      "/remote/org2/agenda.org2:1",
      "/remote/org2/agenda.org2:4"
    ])
    XCTAssertEqual(store.selectedAIChatThread?.title, "Context: 2 selected items")
  }

  @MainActor
  func testReselectingSameAgendaItemReusesRenderedDetail() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-reselect-detail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-reselect.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let item = try XCTUnwrap(store.visibleAgendaItems.first)
    store.selectAgendaItem(item)
    try await waitForCondition {
      store.selectedEntrySource?.file == note.path
        && !store.isLoadingEntrySource
        && !store.isRenderingEntrySource
        && !store.selectedRenderedBlocks.isEmpty
    }

    let renderedBlockIDs = store.selectedRenderedBlocks.map(\.id)
    store.selectAgendaItem(item)

    XCTAssertEqual(store.selectedRenderedBlocks.map(\.id), renderedBlockIDs)
    XCTAssertFalse(store.isLoadingEntrySource)
    XCTAssertFalse(store.isRenderingEntrySource)
  }

  @MainActor
  func testReselectingSameAgendaItemRetriesStuckSourceLoad() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-reselect-loading-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-reselect-loading.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First task
    SCHEDULED: <\(today)>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let item = try XCTUnwrap(store.visibleAgendaItems.first)
    store.selectedLocation = .agenda(item)
    store.selectedEntrySourceMode = .entry
    store.selectedEntrySource = nil
    store.selectedRenderedBlocks = []
    store.isLoadingEntrySource = true
    store.isRenderingEntrySource = false

    store.selectAgendaItem(item)

    try await waitForCondition {
      store.selectedEntrySource?.file == note.path
        && !store.isLoadingEntrySource
        && !store.isRenderingEntrySource
        && !store.selectedRenderedBlocks.isEmpty
    }
  }

  @MainActor
  func testStalledEntrySourceLoadRetriesAutomatically() async throws {
    actor Attempts {
      var count = 0
      func next() -> Int {
        count += 1
        return count
      }
    }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-source-watchdog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("watchdog.org2")
    try "* TODO Recovered source\nBody\n".write(to: note, atomically: true, encoding: .utf8)
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "Recovered source",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))

    let attempts = Attempts()
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.entrySourceLoadTimeoutNanoseconds = 30_000_000
    store.entrySourceLoaderForTesting = { file, _, _ in
      if await attempts.next() == 1 {
        try await Task.sleep(nanoseconds: 300_000_000)
      }
      return EntrySource(
        file: file,
        startLine: 1,
        endLineExclusive: 3,
        text: "* TODO Recovered source\nBody",
        isSubtree: true
      )
    }

    store.select(.agenda(item))

    try await waitForCondition {
      store.selectedEntrySource?.text.contains("Recovered source") == true
        && !store.isLoadingEntrySource
    }
    XCTAssertNil(store.selectedEntryRenderError)
  }

  @MainActor
  func testRepeatedEntrySourceTimeoutStopsSpinnerAndOffersRetry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-source-timeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("timeout.org2")
    try "* TODO Timed out source\n".write(to: note, atomically: true, encoding: .utf8)
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "Timed out source",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": null,
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.entrySourceLoadTimeoutNanoseconds = 20_000_000
    store.entrySourceLoaderForTesting = { _, _, _ in
      try await Task.sleep(nanoseconds: 300_000_000)
      throw CocoaError(.fileReadUnknown)
    }

    store.select(.agenda(item))

    try await waitForCondition {
      store.selectedEntryRenderError?.contains("timed out") == true
        && !store.isLoadingEntrySource
    }
    XCTAssertEqual(store.statusText, "Source load failed")
    XCTAssertNil(store.selectedEntrySource)
  }

  @MainActor
  func testEntryRenderingAutomaticallyStopsAfterDeadline() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-render-timeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("slow-render.org2")
    try "* TODO Slow render\nBody\n".write(to: note, atomically: true, encoding: .utf8)
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "Slow render",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": null,
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.entryHTMLRenderTimeoutNanoseconds = 30_000_000
    store.entryHTMLRendererForTesting = { _, _, _, _ in
      try await Task.sleep(nanoseconds: 5_000_000_000)
      return "<html></html>"
    }

    store.select(.agenda(item))

    try await waitForCondition {
      store.selectedEntryRenderError?.localizedCaseInsensitiveContains("timed out") == true
        && !store.isRenderingEntrySource
    }
    XCTAssertEqual(store.statusText, "Preview rendering timed out")
    XCTAssertTrue(store.isSelectedRenderedBlocksReady)
    XCTAssertTrue(store.selectedRenderedBlocks.contains { $0.rawText.contains("Slow render") })
  }

  @MainActor
  func testEntryPublishesNativeDocumentBeforeEnhancedHTMLFinishes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-native-preview-first-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("native-first.org2")
    try "* Native preview\nBody\n".write(to: note, atomically: true, encoding: .utf8)
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": null,
      "headline": "Native preview",
      "kind": "NONE",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.agendaEntryRenderIdleDelayNanoseconds = 0
    store.entryHTMLRendererForTesting = { _, _, _, _ in
      try await Task.sleep(nanoseconds: 400_000_000)
      return "<html><body>Enhanced preview</body></html>"
    }

    store.select(.agenda(item))

    try await waitForCondition {
      store.isSelectedRenderedBlocksReady
        && store.selectedRenderedBlocks.contains { $0.rawText.contains("Native preview") }
    }
    XCTAssertNil(store.selectedEntryHTML)
    XCTAssertTrue(store.isRenderingEntrySource)

    try await waitForCondition {
      store.selectedEntryHTML?.contains("Enhanced preview") == true
        && !store.isRenderingEntrySource
    }
  }

  @MainActor
  func testEntryPublishesEnhancedHTMLWithoutWaitingForNativeParse() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-html-preview-first-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("html-first.org2")
    try "* HTML first\nBody\n".write(to: note, atomically: true, encoding: .utf8)
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": null,
      "headline": "HTML first",
      "kind": "NONE",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.agendaEntryRenderIdleDelayNanoseconds = 0
    store.entryHTMLRenderTimeoutNanoseconds = 40_000_000
    store.entryNativeRendererPreparationForTesting = {
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    store.entryHTMLRendererForTesting = { _, _, _, _ in
      "<html><body>Ready HTML preview</body></html>"
    }

    store.select(.agenda(item))

    try await waitForCondition {
      store.selectedEntryHTML?.contains("Ready HTML preview") == true
    }
    try await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertNil(store.selectedEntryRenderError)
    XCTAssertNotEqual(store.statusText, "Preview rendering timed out")

    try await waitForCondition {
      store.isSelectedRenderedBlocksReady && !store.isRenderingEntrySource
    }
  }

  @MainActor
  func testEntryLoadingCanBeStoppedManually() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-source-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("cancel-load.org2")
    try "* TODO Cancel load\n".write(to: note, atomically: true, encoding: .utf8)
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "Cancel load",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": null,
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.entrySourceLoaderForTesting = { _, _, _ in
      try await Task.sleep(nanoseconds: 5_000_000_000)
      throw CocoaError(.fileReadUnknown)
    }
    store.select(.agenda(item))
    try await waitForCondition { store.isLoadingEntrySource }

    store.cancelSelectedEntryLoading()

    XCTAssertFalse(store.isLoadingEntrySource)
    XCTAssertFalse(store.isRenderingEntrySource)
    XCTAssertTrue(store.selectedEntryRenderError?.localizedCaseInsensitiveContains("stopped") == true)
  }

  @MainActor
  func testChangingCorpusClearsInterruptedSourceLoadingState() throws {
    let firstRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-source-loading-first-\(UUID().uuidString)", isDirectory: true)
    let secondRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-source-loading-second-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(firstRoot)
    store.isLoadingEntrySource = true
    store.isRenderingEntrySource = true

    store.setCorpusRoot(secondRoot)

    XCTAssertFalse(store.isLoadingEntrySource)
    XCTAssertFalse(store.isRenderingEntrySource)
    XCTAssertNil(store.selectedEntrySource)
    XCTAssertTrue(store.selectedRenderedBlocks.isEmpty)
  }

  @MainActor
  func testLoadsAgendaItemWithLinkedHeadingTitle() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-linked-agenda-heading-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("linked-heading.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    ** TODOs
    *** TODO Add or update the [[id:f900674b-5d4b-4022-a5c6-805f1f40239b][AWS]] [[id:283493fe-f840-4485-93d7-b860dfcc53b7][payment]] method
    SCHEDULED: <\(today)>
    :PROPERTIES:
    :OWNER: Avi
    :END:
    [[id:f900674b-5d4b-4022-a5c6-805f1f40239b][AWS]] shows an expired [[id:283493fe-f840-4485-93d7-b860dfcc53b7][payment]] method.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let item = try XCTUnwrap(store.visibleAgendaItems.first {
      $0.headline.contains("Add or update")
    })
    store.selectAgendaItem(item)

    try await waitForCondition {
      store.selectedEntrySource?.file == note.path
        && store.selectedEntrySource?.text.contains("payment]] method") == true
        && !store.isLoadingEntrySource
        && !store.isRenderingEntrySource
        && !store.selectedRenderedBlocks.isEmpty
    }
  }

  @MainActor
  func testBulkAgentHandoffAssignsCheckedItemsWithoutChangingTodoState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agenda-bulk-agent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda-bulk-agent.org2")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd EEE"
    let today = formatter.string(from: Date())

    try """
    * TODO First agent task
    SCHEDULED: <\(today)>
    Body

    * TODO Second agent task
    SCHEDULED: <\(today)>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda()

    let first = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "First agent task" })
    let second = try XCTUnwrap(store.visibleAgendaItems.first { $0.headline == "Second agent task" })
    store.toggleAgendaItemBulkSelection(first)
    store.toggleAgendaItemBulkSelection(second)

    await store.applyAgentHandoffShortcut()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO First agent task"))
    XCTAssertTrue(updated.contains("* TODO Second agent task"))
    XCTAssertFalse(updated.contains("* DONE First agent task"))
    XCTAssertFalse(updated.contains("* DONE Second agent task"))
    XCTAssertEqual(updated.components(separatedBy: ":ASSIGNEE: OpenClaw").count - 1, 2)
    XCTAssertEqual(updated.components(separatedBy: ":STATUS: ready").count - 1, 2)
    XCTAssertEqual(updated.components(separatedBy: ":ASSIGNED_AT: <").count - 1, 2)
    XCTAssertEqual(store.bulkAgendaSelectionCount, 0)
  }

  @MainActor
  func testOpenDailyNoteCreatesAndSelectsConfiguredDailyFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-open-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.openDailyNote(.today)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let fileName = "\(formatter.string(from: Date())).org"
    let daily = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent(fileName)
      .standardizedFileURL
    await store.waitForDailyNoteNavigationForTesting()

    XCTAssertTrue(FileManager.default.fileExists(atPath: daily.path))
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertEqual(store.selectedCorpusFileID, daily.path)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.selectedLocation?.file, daily.path)
    XCTAssertEqual(store.corpusFiles.map(\.relativePath), ["dailies/\(fileName)"])
  }

  @MainActor
  func testDailyNoteDirectoryDefaultsToDailyWithoutAValidExplicitOverride() async throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-defaults-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }

    let fallbackConfigs: [Data?] = [
      nil,
      Data(#"{"roam":{"indexDir":"notes"}}"#.utf8),
      Data(#"{"roam":{"indexDir":"notes","dailiesDir":"   "}}"#.utf8),
      Data(#"{"roam":{"indexDir":"notes","dailiesDir":42}}"#.utf8),
      Data(#"{"roam":{"dailiesDir":"daily"}"#.utf8),
    ]
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))

    for (index, config) in fallbackConfigs.enumerated() {
      let root = fixtureRoot.appendingPathComponent("corpus-\(index)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      if let config {
        try config.write(to: root.appendingPathComponent("org2.json"), options: .atomic)
      }

      let directory = await store.dailyNoteDirectoryForTesting(corpusRoot: root)

      XCTAssertEqual(
        directory,
        root.appendingPathComponent("daily", isDirectory: true).standardizedFileURL,
        "Scenario \(index) must not inherit roam.indexDir or the corpus root"
      )
    }

    let nonDirectoryRoot = fixtureRoot.appendingPathComponent("corpus-file-override", isDirectory: true)
    try FileManager.default.createDirectory(at: nonDirectoryRoot, withIntermediateDirectories: true)
    try "not a directory".write(
      to: nonDirectoryRoot.appendingPathComponent("not-daily"),
      atomically: true,
      encoding: .utf8
    )
    try Data(#"{"roam":{"dailiesDir":"not-daily"}}"#.utf8).write(
      to: nonDirectoryRoot.appendingPathComponent("org2.json"),
      options: .atomic
    )

    let nonDirectoryFallback = await store.dailyNoteDirectoryForTesting(
      corpusRoot: nonDirectoryRoot
    )
    XCTAssertEqual(
      nonDirectoryFallback,
      nonDirectoryRoot.appendingPathComponent("daily", isDirectory: true).standardizedFileURL
    )
  }

  @MainActor
  func testDailyNoteDirectoryHonorsExplicitRelativeAndAbsoluteOverrides() async throws {
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-overrides-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let relativeRoot = fixtureRoot.appendingPathComponent("relative-corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: relativeRoot, withIntermediateDirectories: true)
    try Data(
      #"{"roam":{"indexDir":42,"dailiesDir":"custom/dailies"},"links":42}"#.utf8
    ).write(to: relativeRoot.appendingPathComponent("org2.json"), options: .atomic)

    let relativeDirectory = await store.dailyNoteDirectoryForTesting(corpusRoot: relativeRoot)
    XCTAssertEqual(
      relativeDirectory,
      relativeRoot.appendingPathComponent("custom/dailies", isDirectory: true).standardizedFileURL
    )

    let absoluteRoot = fixtureRoot.appendingPathComponent("absolute-corpus", isDirectory: true)
    let absoluteDirectory = absoluteRoot.appendingPathComponent("absolute-dailies", isDirectory: true)
    try FileManager.default.createDirectory(at: absoluteRoot, withIntermediateDirectories: true)
    let absoluteConfig = try JSONSerialization.data(withJSONObject: [
      "roam": ["dailiesDir": absoluteDirectory.path]
    ])
    try absoluteConfig.write(to: absoluteRoot.appendingPathComponent("org2.json"), options: .atomic)

    let resolvedAbsoluteDirectory = await store.dailyNoteDirectoryForTesting(
      corpusRoot: absoluteRoot
    )
    XCTAssertEqual(
      resolvedAbsoluteDirectory,
      absoluteDirectory.standardizedFileURL
    )
  }

  @MainActor
  func testDailyNoteDirectoryInvalidationCannotPublishAStaleDetachedResult() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-invalidation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("org2.json")
    try "{}".write(to: config, atomically: true, encoding: .utf8)

    let resolver = ControlledDailyNoteDirectoryResolver(
      firstDirectoryName: "stale-daily",
      laterDirectoryName: "fresh-daily"
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.dailyNoteDirectoryResolverForTesting = { root in resolver.resolve(root) }
    store.setCorpusRoot(root)
    let pendingResolution = Task { @MainActor in
      await store.dailyNoteDirectoryForTesting(corpusRoot: root)
    }
    await Task.yield()
    XCTAssertTrue(resolver.waitUntilFirstResolutionStarts())
    defer { resolver.releaseFirstResolution() }

    store.handleCorpusFileEvents([config.path], corpusRoot: root, requiresFullScan: false)
    resolver.releaseFirstResolution()

    let resolved = await pendingResolution.value
    XCTAssertEqual(
      resolved,
      root.appendingPathComponent("fresh-daily", isDirectory: true).standardizedFileURL
    )
    let cachedResolution = await store.dailyNoteDirectoryForTesting(corpusRoot: root)
    XCTAssertEqual(cachedResolution, resolved)
  }

  @MainActor
  func testLatestDailyOrHomeNavigationWinsWhileDirectoryResolutionIsPending() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-navigation-order-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let resolver = ControlledDailyNoteDirectoryResolver(
      firstDirectoryName: "daily",
      laterDirectoryName: "daily"
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.dailyNoteDirectoryResolverForTesting = { root in resolver.resolve(root) }
    store.setCorpusRoot(root)
    store.openDailyNote(.yesterday)
    await Task.yield()
    XCTAssertTrue(resolver.waitUntilFirstResolutionStarts())
    defer { resolver.releaseFirstResolution() }

    store.openHome()
    resolver.releaseFirstResolution()
    await store.waitForDailyNoteNavigationForTesting()

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let today = root
      .appendingPathComponent("daily", isDirectory: true)
      .appendingPathComponent("\(formatter.string(from: Date())).org")
      .standardizedFileURL
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertEqual(store.selectedLocation?.file, today.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: today.path))
  }

  @MainActor
  func testOpenDailyNotePreservesExistingOrg2DailyFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-legacy-daily-open-\(UUID().uuidString)", isDirectory: true)
    let dailies = root.appendingPathComponent("dailies", isDirectory: true)
    try FileManager.default.createDirectory(at: dailies, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let baseName = formatter.string(from: Date())
    let legacy = dailies.appendingPathComponent("\(baseName).org2")
    try "#+TITLE: Legacy daily note\n\n".write(to: legacy, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.automaticDailyNoteCreationDisabled = true
    store.openDailyNote(.today)
    await store.waitForDailyNoteNavigationForTesting()

    XCTAssertEqual(store.selectedLocation?.file, legacy.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: dailies.appendingPathComponent("\(baseName).org").path))
  }

  @MainActor
  func testDisabledAutomaticDailyNoteCreationShowsMissingStateUntilExplicitCreation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-manual-daily-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.automaticDailyNoteCreationDisabled = true
    let originalTabID = store.selectedWorkspaceTabID

    for target in DailyNoteTarget.allCases {
      store.openDailyNote(target)
      await store.waitForDailyNoteNavigationForTesting()

      let missing = try XCTUnwrap(store.missingDailyNote)
      XCTAssertNil(store.selectedLocation)
      XCTAssertTrue(store.hasWorkspaceDetailContent)
      XCTAssertEqual(store.statusText, "No daily file found")
      XCTAssertFalse(FileManager.default.fileExists(atPath: missing.file))
    }

    store.presentDailyNoteDatePicker()
    store.dailyNotePickerDate = try XCTUnwrap(Calendar.current.date(
      from: DateComponents(year: 2024, month: 2, day: 29)
    ))
    store.openDailyNoteFromDatePicker()
    await store.waitForDailyNoteNavigationForTesting()

    let missing = try XCTUnwrap(store.missingDailyNote)
    XCTAssertTrue(missing.file.hasSuffix("/daily/2024-02-29.org"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.file))

    let secondTabID = store.newWorkspaceTab()
    XCTAssertNotEqual(secondTabID, originalTabID)
    XCTAssertNil(store.missingDailyNote)
    store.selectWorkspaceTab(originalTabID)
    XCTAssertEqual(store.missingDailyNote, missing)

    store.createMissingDailyNote()
    await store.waitForDailyNoteNavigationForTesting()

    XCTAssertNil(store.missingDailyNote)
    XCTAssertFalse(store.isCreatingMissingDailyNote)
    XCTAssertEqual(store.selectedLocation?.file, missing.file)
    XCTAssertTrue(FileManager.default.fileExists(atPath: missing.file))
  }

  @MainActor
  func testDisabledAutomaticDailyNoteCreationAppliesToHome() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-manual-home-daily-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.automaticDailyNoteCreationDisabled = true
    store.openHome()
    await store.waitForDailyNoteNavigationForTesting()

    let missing = try XCTUnwrap(store.missingDailyNote)
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertNil(store.selectedLocation)
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.file))

    store.createMissingDailyNote()
    await store.waitForDailyNoteNavigationForTesting()

    XCTAssertNil(store.missingDailyNote)
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertEqual(store.selectedLocation?.file, missing.file)
    XCTAssertTrue(FileManager.default.fileExists(atPath: missing.file))
  }

  @MainActor
  func testPendingDisabledDailyNoteNavigationCannotPolluteAnotherTab() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-manual-daily-tab-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let resolver = ControlledDailyNoteDirectoryResolver(
      firstDirectoryName: "daily",
      laterDirectoryName: "daily"
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.dailyNoteDirectoryResolverForTesting = { root in resolver.resolve(root) }
    store.setCorpusRoot(root)
    store.automaticDailyNoteCreationDisabled = true
    let originalTabID = store.selectedWorkspaceTabID
    store.openDailyNote(.tomorrow)
    await Task.yield()
    XCTAssertTrue(resolver.waitUntilFirstResolutionStarts())

    let secondTabID = store.newWorkspaceTab()
    resolver.releaseFirstResolution()
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertEqual(store.selectedWorkspaceTabID, secondTabID)
    XCTAssertNil(store.missingDailyNote)
    XCTAssertNil(store.selectedLocation)
    store.selectWorkspaceTab(originalTabID)
    XCTAssertNil(store.missingDailyNote)
    XCTAssertNil(store.selectedLocation)
  }

  @MainActor
  func testAutomaticDailyNoteCreationPreferenceIsPerCorpusAndDefaultsToEnabled() throws {
    let suiteName = "org2-workspace-daily-creation-setting-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let firstRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-setting-first-\(UUID().uuidString)", isDirectory: true)
    let secondRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-setting-second-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: firstRoot)
      try? FileManager.default.removeItem(at: secondRoot)
    }

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    store.setCorpusRoot(firstRoot)
    XCTAssertFalse(store.automaticDailyNoteCreationDisabled)
    store.automaticDailyNoteCreationDisabled = true

    store.setCorpusRoot(secondRoot)
    XCTAssertFalse(store.automaticDailyNoteCreationDisabled)

    let restored = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults
    )
    restored.setCorpusRoot(firstRoot)
    XCTAssertTrue(restored.automaticDailyNoteCreationDisabled)
    restored.setCorpusRoot(secondRoot)
    XCTAssertFalse(restored.automaticDailyNoteCreationDisabled)
  }

  @MainActor
  func testSidebarFileNavigationMakesDocumentPrimaryWithoutShowingFilesSurface() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-sidebar-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("pinned.org2")
    try "#+TITLE: Pinned\n".write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.makeSurfacePrimary(.agenda)
    store.openSidebarFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))

    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertEqual(store.selectedLocation?.file, note.path)
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
  }

  @MainActor
  func testSidebarFileNavigationKeepsVisibleAIChatBesideDocument() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-sidebar-file-chat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("pinned.org2")
    try "#+TITLE: Pinned\n".write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.expandSurface(.aiChat)
    XCTAssertTrue(store.isWorkspaceDetailPaneClosed)

    store.openSidebarFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))

    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.selectedLocation?.file, note.path)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
  }

  @MainActor
  func testDailyNoteActionsPreserveVisibleChatAndDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-chat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json")
    )
    store.setCorpusRoot(root)
    store.createAIChatThread(runtime: .openClaw)
    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    store.aiChatDraft = "Keep this unsent message"

    for (key, code) in [("7", UInt16(26)), ("8", UInt16(28)), ("9", UInt16(25))] {
      store.expandSurface(.aiChat)
      XCTAssertTrue(store.isWorkspaceDetailPaneClosed)
      XCTAssertTrue(store.handleGlobalKeyDown(keyDown(characters: key, keyCode: code, modifiers: [.command])))
      await store.waitForDailyNoteNavigationForTesting()
      XCTAssertEqual(store.selectedSurface, .aiChat)
      XCTAssertEqual(store.selectedAIChatThreadID, threadID)
      XCTAssertEqual(store.aiChatDraft, "Keep this unsent message")
      XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
      XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
      XCTAssertEqual(store.activeWorkspacePane, .detail)
      XCTAssertNotNil(store.selectedLocation)
    }

    store.openDailyNoteFromSidebar(.today)
    await store.waitForDailyNoteNavigationForTesting()
    store.presentDailyNoteDatePicker()
    store.dailyNotePickerDate = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 29)))
    store.openDailyNoteFromDatePicker()
    await store.waitForDailyNoteNavigationForTesting()
    XCTAssertEqual(store.selectedSurface, .aiChat)
    XCTAssertEqual(store.selectedAIChatThreadID, threadID)
    XCTAssertEqual(store.aiChatDraft, "Keep this unsent message")
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
    XCTAssertTrue(store.selectedLocation?.file.hasSuffix("/2024-02-29.org") == true)
  }

  @MainActor
  func testDailyNoteNavigationHidesFilesAndPreservesAClosedFirstPane() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-daily-pane-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.makeSurfacePrimary(.files)
    store.openDailyNote(.today)
    await store.waitForDailyNoteNavigationForTesting()
    XCTAssertEqual(store.selectedSurface, .files)
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)

    let dailyFile = try XCTUnwrap(store.corpusFiles.first { $0.id == store.selectedCorpusFileID })
    store.activateSelectedCorpusFileFromList(dailyFile)
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)

    store.makeSurfacePrimary(.aiChat)
    store.activateSelectedCorpusFileFromList(dailyFile)
    XCTAssertEqual(store.selectedSurface, .aiChat)

    store.makeSurfacePrimary(.agenda)
    store.closeSurfacePane(.agenda)
    store.openDailyNoteFromSidebar(.yesterday)
    await store.waitForDailyNoteNavigationForTesting()
    XCTAssertEqual(store.selectedSurface, .agenda)
    XCTAssertTrue(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
  }

  @MainActor
  func testSidebarDailyNoteNavigationPreservesVisibleAgenda() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-sidebar-daily-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.makeSurfacePrimary(.agenda)
    store.openDailyNoteFromSidebar(.today)
    await store.waitForDailyNoteNavigationForTesting()

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let daily = root
      .appendingPathComponent("daily", isDirectory: true)
      .appendingPathComponent("\(formatter.string(from: Date())).org")
      .standardizedFileURL

    XCTAssertEqual(store.selectedSurface, .agenda)
    XCTAssertFalse(store.isWorkspaceSurfacePaneClosed)
    XCTAssertFalse(store.isWorkspaceDetailPaneClosed)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.selectedLocation?.file, daily.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: daily.path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: root.appendingPathComponent(daily.lastPathComponent).path
    ))
  }

  @MainActor
  func testOpenHomeCreatesTodayDailyNoteAsAIChatDetail() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.openHome()

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let fileName = "\(formatter.string(from: Date())).org"
    let daily = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent(fileName)
      .standardizedFileURL
    await store.waitForDailyNoteNavigationForTesting()

    XCTAssertTrue(FileManager.default.fileExists(atPath: daily.path))
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertEqual(store.selectedCorpusFileID, daily.path)
    XCTAssertEqual(store.selectedAIChatThreadRecordID, daily.path)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.selectedLocation?.file, daily.path)
    XCTAssertEqual(store.selectedLocation?.lineForEditor, 1)
    XCTAssertEqual(store.corpusFiles.map(\.relativePath), ["dailies/\(fileName)"])
  }

  @MainActor
  func testBootstrapRestoresAndRendersHomeDailyNoteForSavedCorpus() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-startup-home-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)
    let suiteName = "org2-workspace-startup-home-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(root.path, forKey: "Org2Workspace.corpusRoot")
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()), defaults: defaults)
    XCTAssertNil(store.corpusRoot)
    XCTAssertNil(store.selectedLocation)
    store.entryHTMLRendererForTesting = { _, _, _, _ in
      "<html><body>Startup home rendered</body></html>"
    }

    await store.bootstrap()

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let fileName = "\(formatter.string(from: Date())).org"
    let daily = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent(fileName)
      .standardizedFileURL

    XCTAssertEqual(store.corpusRoot?.path, root.standardizedFileURL.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: daily.path))
    XCTAssertEqual(store.selectedSurface, .home)
    XCTAssertTrue(store.hasWorkspaceDetailContent)
    XCTAssertEqual(store.selectedCorpusFileID, daily.path)
    XCTAssertEqual(store.selectedAIChatThreadRecordID, daily.path)
    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    XCTAssertEqual(store.selectedLocation?.file, daily.path)
    XCTAssertEqual(store.selectedLocation?.lineForEditor, 1)
    try await waitForCondition {
      store.selectedEntryHTML?.contains("Startup home rendered") == true
        && !store.isLoadingEntrySource
        && !store.isRenderingEntrySource
    }
    XCTAssertNil(store.selectedEntryRenderError)
  }

  func testAIChatWorkspaceContextMapsRemotePathsAndIncludesGraphSlice() throws {
    let localRoot = "/local/org2"
    let remoteRoot = "/srv/org2"
    let note = "\(localRoot)/notes/alice.org2"
    let backlinkFile = "\(localRoot)/threads/follow-up.org2"
    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Follow up with [[id:11111111-1111-4111-8111-111111111111][Alice]]",
      "kind": "SCHEDULED",
      "file": "\(note)",
      "line": 3,
      "body": "Fixture body",
      "level": 1,
      "tags": [],
      "properties": {},
      "id": "22222222-2222-4222-8222-222222222222"
    }
    """
    let backlinksJSON = """
    {
      "$schema": "org2:backlinks:v1",
      "id": "22222222-2222-4222-8222-222222222222",
      "backlinks": [
        {
          "srcId": null,
          "srcTitle": "Follow-up thread",
          "file": "\(backlinkFile)",
          "line": 7,
          "context": "Discuss [[id:22222222-2222-4222-8222-222222222222][Alice task]]"
        }
      ]
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let backlinks = try JSONDecoder().decode(BacklinksPayload.self, from: Data(backlinksJSON.utf8))
    let source = EntrySource(
      file: note,
      startLine: 4,
      endLineExclusive: 7,
      text: """
      * TODO Follow up with [[id:11111111-1111-4111-8111-111111111111][Alice]]
      SCHEDULED: <2026-06-12 Fri>
      Fixture body
      """,
      isSubtree: true
    )
    let sourceProfile = WorkspaceSourceProfileStatus(
      id: "team-knowledge",
      type: "knowledge-base",
      enabled: true,
      scopes: ["workspace-a"],
      workspaceId: nil,
      rawZone: "raw/connectors/knowledge/team",
      reviewZone: "views/connectors/knowledge/team",
      ingestionSince: "90d",
      ingestionLimit: 5_000,
      syncArgs: [],
      media: "metadata-only",
      schedule: nil,
      binary: "source-crawler",
      binaryAvailable: true,
      configPath: nil,
      configAvailable: true,
      ready: true
    )
    let sourceRuntime = WorkspaceSourceRuntimeStatus(
      id: "team-knowledge",
      type: "knowledge-base",
      ok: true,
      crawlerStatus: WorkspaceCrawlerStatus(
        appId: "source-crawler",
        state: "ready",
        summary: "42 pages available",
        databasePath: nil,
        databaseBytes: 1_024,
        lastSyncAt: "2026-07-21T17:00:00Z",
        counts: []
      ),
      error: nil
    )

    let context = AIChatWorkspaceContext(
      localCorpusRoot: localRoot,
      remoteCorpusRoot: remoteRoot,
      selectedSurface: "Today",
      selectedLocation: .agenda(item),
      selectedEntrySource: source,
      backlinks: backlinks,
      agenda: nil,
      searchQuery: "",
      searchResults: [],
      agentThreadDirectories: ["\(localRoot)/agents", "\(localRoot)/notes/openclaw"],
      sourceProfiles: [sourceProfile],
      sourceRuntimeStatuses: [sourceProfile.id: sourceRuntime]
    )

    let prompt = context.systemPrompt()

    XCTAssertTrue(prompt.contains("Remote corpus root for OpenClaw: \(remoteRoot)"))
    XCTAssertTrue(prompt.contains("Agent-thread directories: \(remoteRoot)/agents, \(remoteRoot)/notes/openclaw"))
    XCTAssertTrue(prompt.contains("Do not write generated Backlinks sections"))
    XCTAssertTrue(prompt.contains("OpenClaw handoff rules"))
    XCTAssertTrue(prompt.contains(":KIND: agent-thread"))
    XCTAssertTrue(prompt.contains("Context attachments"))
    XCTAssertTrue(prompt.contains("celorga agent capabilities"))
    XCTAssertTrue(prompt.contains("celorga search <query> --dir <root>"))
    XCTAssertTrue(prompt.contains("Connected Celorga sources"))
    XCTAssertTrue(prompt.contains("external-source profiles in its root celorga.json"))
    XCTAssertTrue(prompt.contains("Do not make the user explain or select source infrastructure"))
    XCTAssertTrue(prompt.contains("team-knowledge — type: knowledge-base; enabled; ready; healthy; scopes: workspace-a"))
    XCTAssertTrue(prompt.contains("\(remoteRoot)/raw/connectors/knowledge/team"))
    XCTAssertTrue(prompt.contains("last sync: 2026-07-21T17:00:00Z"))
    XCTAssertTrue(prompt.contains("Clickable citations in AI chat"))
    XCTAssertTrue(prompt.contains("[[file:\(remoteRoot)/notes/example.org::42][descriptive label]]"))
    XCTAssertTrue(prompt.contains("[[file:\(remoteRoot)/notes/example.org::42][source, lines 42–47]]"))
    XCTAssertTrue(prompt.contains("\(remoteRoot)/notes/alice.org2:4"))
    XCTAssertTrue(prompt.contains("\(remoteRoot)/threads/follow-up.org2:8"))
    XCTAssertTrue(prompt.contains("~~~org"))
    XCTAssertFalse(prompt.contains(note))
    XCTAssertFalse(prompt.contains(backlinkFile))
  }

  func testCleansOrgLinksForDisplay() {
    XCTAssertEqual(
      Org2Display.cleanInline("Include [[id:c8277d02-6536-4766-9999-709e059edb47][Slack]] support"),
      "Include Slack support"
    )
    XCTAssertEqual(
      Org2Display.cleanInline("Bare id:c8277d02-6536-4766-9999-709e059edb47"),
      "Bare id:c8277d02"
    )
  }

  func testParsesRenderedOrgBlocks() {
    let blocks = OrgEntryRenderer.parse("""
    * TODO [#A] Parent [[id:c8277d02-6536-4766-9999-709e059edb47][Slack]] :work:
    SCHEDULED: <2026-06-12 Fri>
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:
    #+begin_quote
    Quote with [[id:c8277d02-6536-4766-9999-709e059edb47][Slack]]
    #+end_quote
    #+begin_example
    Example text should render as prose
    #+end_example
    #+begin_src swift
    let value = 1
    #+end_src
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    -----
    - [ ] Open task
    - [X] Done task
    ** Child
    Body text
    """)

    guard case .heading(let heading) = blocks[0] else {
      return XCTFail("Expected heading")
    }
    XCTAssertEqual(heading.level, 1)
    XCTAssertEqual(heading.todo, "TODO")
    XCTAssertEqual(heading.priority, "A")
    XCTAssertEqual(heading.title, "Parent Slack")
    XCTAssertEqual(heading.tags, ["work"])

    XCTAssertTrue(blocks.contains(.planning(OrgPlanningBlock(kind: "SCHEDULED", value: "<2026-06-12 Fri>"))))
    XCTAssertTrue(blocks.contains(.properties([OrgPropertyRow(key: "ID", value: "11111111-1111-4111-8111-111111111111")])))
    XCTAssertTrue(blocks.contains(.quote(["Quote with Slack"])))
    XCTAssertTrue(blocks.contains(.quote(["Example text should render as prose"])))
    XCTAssertTrue(blocks.contains(.source(language: "swift", lines: ["let value = 1"])))
    XCTAssertTrue(blocks.contains(.table(OrgTableBlock(rows: [
      .cells(["Name", "Value"]),
      .separator,
      .cells(["Alice", "42"])
    ]))))
    XCTAssertTrue(blocks.contains(.horizontalRule))
    XCTAssertTrue(blocks.contains {
      if case .listItem(0, "-", .unchecked, "Open task") = $0 { return true }
      return false
    })
    XCTAssertTrue(blocks.contains {
      if case .listItem(0, "-", .checked, "Done task") = $0 { return true }
      return false
    })
  }

  func testEditableTableFormatsAndMutatesOrgTableText() {
    var table = OrgEditableTable(rawText: """
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    """)

    XCTAssertEqual(table.columnCount, 2)
    XCTAssertEqual(table.renderedBlock.headerRowIndex, 0)
    XCTAssertEqual(table.formattedRawText, """
    | Name  | Value |
    |-------+-------|
    | Alice | 42    |
    """)

    table.setCell(row: 2, column: 1, value: "43")
    table.addColumn()
    table.setCell(row: 0, column: 2, value: "Owner")
    table.setCell(row: 2, column: 2, value: "Avi")
    table.addRow(after: 2)
    table.setCell(row: 3, column: 0, value: "Bob")
    table.setCell(row: 3, column: 1, value: "12")
    table.removeColumn(1)

    XCTAssertEqual(table.formattedRawText, """
    | Name  | Owner |
    |-------+-------|
    | Alice | Avi   |
    | Bob   |       |
    """)

    XCTAssertNil(OrgEditableTable(rawText: """
    | Name | Value |
    | Alice | 42 |
    """).renderedBlock.headerRowIndex)
  }

  func testRenderedTableViewMutationPreservesRawRowsWhileFilteringAndSorting() throws {
    let raw = """
      | Name | Link |
      |------+------|
      | Zebra | [[id:zebra][Z]] |
      | Ant | [[id:ant][A]] |
      | Mouse | [[id:mouse][M]] |
      """

    let replacement = try XCTUnwrap(OrgRenderedTableViewMutation.replacement(
      rawText: raw,
      visibleBodyRowIndices: [2, 0],
      expectedBodyRowCount: 3
    ))

    XCTAssertEqual(replacement, """
      | Name | Link |
      |------+------|
      | Mouse | [[id:mouse][M]] |
      | Zebra | [[id:zebra][Z]] |
      """)
  }

  func testExplicitColorBindingsSupportForegroundBackgroundAndWholeCellMarkup() throws {
    let foreground = try XCTUnwrap(OrgColorBinding.parse(target: "color:red", label: "Urgent"))
    XCTAssertEqual(foreground.foreground?.rgb, 0xff3b30)
    XCTAssertNil(foreground.background)

    let combined = try XCTUnwrap(OrgColorBinding.parse(
      target: "color:fg=white;bg=#b42318",
      label: "Blocked"
    ))
    XCTAssertEqual(combined.foreground?.rgb, 0xf2f2f7)
    XCTAssertEqual(combined.background?.rgb, 0xb42318)
    XCTAssertNil(OrgColorBinding.parse(target: "color:chartreuse-ish", label: "Nope"))
    XCTAssertNil(OrgColorBinding.parse(target: "https://example.com", label: "Link"))

    let spans = OrgInlineParser.parse("State: [[color:bg=#fc0][Review]]")
    XCTAssertEqual(spans, [.text("State: "), .color(try XCTUnwrap(
      OrgColorBinding.parse(target: "color:bg=#fc0", label: "Review")
    ))])

    let table = OrgEditableTable(rawText: """
      | State |
      |-------|
      | [[color:fg=white;bg=#b42318][Blocked]] |
      """).renderedBlock
    guard table.rows.count == 3, case .cells(let cells) = table.rows[2] else {
      return XCTFail("Expected a rendered color-binding cell")
    }
    XCTAssertEqual(cells, ["[[color:fg=white;bg=#b42318][Blocked]]"])
  }

  func testRenderedTableViewMutationRejectsAStaleRowMapping() {
    XCTAssertNil(OrgRenderedTableViewMutation.replacement(
      rawText: """
      | Name |
      |------|
      | Ant  |
      """,
      visibleBodyRowIndices: [0],
      expectedBodyRowCount: 2
    ))
  }

  func testRenderedTableViewSnapshotValidatesWebMessagePayload() throws {
    let snapshot = try XCTUnwrap(OrgHTMLTableViewSnapshot([
      "startLine": NSNumber(value: 12),
      "endLine": NSNumber(value: 16),
      "visibleBodyRowIndices": [NSNumber(value: 2), NSNumber(value: 0)],
      "totalBodyRowCount": NSNumber(value: 3),
      "filterActive": NSNumber(value: true),
      "sortActive": NSNumber(value: true),
    ]))

    XCTAssertEqual(snapshot.startLine, 12)
    XCTAssertEqual(snapshot.visibleBodyRowIndices, [2, 0])
    XCTAssertTrue(snapshot.filterActive)
    XCTAssertTrue(snapshot.sortActive)
  }

  func testEditableTablePastesTabSeparatedGrid() {
    var table = OrgEditableTable(rawText: """
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    """)

    XCTAssertTrue(table.pasteGrid(row: 0, column: 0, rawValue: "Metric\tScore\nQuality\t9\nSpeed\t8\n"))

    XCTAssertEqual(table.formattedRawText, """
    | Metric  | Score |
    |---------+-------|
    | Quality | 9     |
    | Speed   | 8     |
    """)

    XCTAssertFalse(table.pasteGrid(row: 2, column: 1, rawValue: "single cell"))
    table.setCell(row: 2, column: 1, value: "10")
    XCTAssertEqual(table.cell(row: 2, column: 1), "10")
  }

  func testEditablePropertyDrawerFormatsAndMutatesRows() {
    var drawer = OrgEditablePropertyDrawer(rawText: """
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :owner: agent
    :EMPTY:
    :END:
    """)

    XCTAssertEqual(drawer.rows, [
      OrgEditablePropertyRow(key: "ID", value: "11111111-1111-4111-8111-111111111111"),
      OrgEditablePropertyRow(key: "owner", value: "agent"),
      OrgEditablePropertyRow(key: "EMPTY", value: "")
    ])

    drawer.setValue(at: 1, value: "openclaw")
    drawer.removeProperty(at: 2)
    drawer.addProperty(key: "status", value: "active")

    XCTAssertEqual(drawer.formattedRawText, """
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :OWNER: openclaw
    :STATUS: active
    :END:
    """)
    XCTAssertEqual(drawer.renderedRows, [
      OrgPropertyRow(key: "ID", value: "11111111-1111-4111-8111-111111111111"),
      OrgPropertyRow(key: "OWNER", value: "openclaw"),
      OrgPropertyRow(key: "STATUS", value: "active")
    ])
  }

  func testOrgPropertyDrawerRawValueCacheUsesExactText() {
    let raw = """
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :Owner: Alice
    :LINEAR_LINK: [[linear:APP-21221][APP-21221]]
    :END:
    """
    let key = OrgPropertyDrawerRawValueCache.CacheKey(rawText: raw)
    let matchingKey = OrgPropertyDrawerRawValueCache.CacheKey(rawText: raw)
    let differentKey = OrgPropertyDrawerRawValueCache.CacheKey(rawText: raw + "\n")

    XCTAssertEqual(key, matchingKey)
    XCTAssertEqual(key.hash, matchingKey.hash)
    XCTAssertNotEqual(key, differentKey)
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(nil), [:])
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw)["OWNER"], "Alice")
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw)["ID"], "11111111-1111-4111-8111-111111111111")
    XCTAssertEqual(
      OrgPropertyDrawerRawValueCache.values(raw)["LINEAR_LINK"],
      "[[linear:APP-21221][APP-21221]]"
    )
    XCTAssertEqual(
      OrgInlineRenderedTextLinkMap.make(
        raw: OrgPropertyDrawerRawValueCache.values(raw)["LINEAR_LINK"] ?? ""
      ).displayText,
      "APP-21221"
    )
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw)["PROPERTIES"], nil)
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw)["END"], nil)
    XCTAssertEqual(OrgPropertyDrawerRawValueCache.values(raw), OrgPropertyDrawerRawValueCache.values(raw))
  }

  func testEditableInlineLinkSetRewritesLinksInParagraphs() {
    let set = OrgEditableInlineLinkSet(rawText: """
    See [[id:11111111-1111-4111-8111-111111111111][Alice]], [docs](https://example.com/docs), and ~/notes/project.org2:12.
    """)

    XCTAssertEqual(set.links.map(\.kind), [.orgBracket, .markdown, .fileReference])
    XCTAssertEqual(set.links.map(\.label), ["Alice", "docs", "project.org2:12"])
    XCTAssertEqual(set.links.map(\.target), [
      "id:11111111-1111-4111-8111-111111111111",
      "https://example.com/docs",
      "~/notes/project.org2:12"
    ])

    let updatedLabel = set.replacing(link: set.links[0], label: "Alicia")
    XCTAssertTrue(updatedLabel.contains("[[id:11111111-1111-4111-8111-111111111111][Alicia]]"))

    let updatedTarget = set.replacing(link: set.links[1], target: "https://example.com/reference")
    XCTAssertTrue(updatedTarget.contains("[[https://example.com/reference][docs]]"))

    let updatedFile = set.replacing(link: set.links[2], label: "Project")
    XCTAssertTrue(updatedFile.contains("[[~/notes/project.org2:12][Project]]."))
  }

  func testEditableInlineLinkSetTrimsTrailingURLPunctuation() {
    let set = OrgEditableInlineLinkSet(rawText: "Open https://example.com/docs.")

    XCTAssertEqual(set.links.count, 1)
    XCTAssertEqual(set.links[0].target, "https://example.com/docs")
    XCTAssertEqual(
      set.replacing(link: set.links[0], label: "Docs"),
      "Open [[https://example.com/docs][Docs]]."
    )
  }

  func testEditableInlineTimestampSetRewritesTimestampsInParagraphs() {
    let set = OrgEditableInlineTimestampSet(rawText: "Meet <2026-06-12 Fri 09:00-10:00 +1w> and review [2026-06-13 Sat].")

    XCTAssertEqual(set.timestamps.count, 2)
    XCTAssertEqual(set.timestamps[0].date, "2026-06-12")
    XCTAssertEqual(set.timestamps[0].time, "09:00-10:00")
    XCTAssertEqual(set.timestamps[0].detail, "+1w")
    XCTAssertTrue(set.timestamps[0].isActive)
    XCTAssertEqual(set.timestamps[1].date, "2026-06-13")
    XCTAssertEqual(set.timestamps[1].time, "")
    XCTAssertEqual(set.timestamps[1].detail, "")
    XCTAssertFalse(set.timestamps[1].isActive)

    XCTAssertEqual(
      set.replacing(timestamp: set.timestamps[0], date: "2026-06-14", time: "11:30", detail: "+2w"),
      "Meet <2026-06-14 Sun 11:30 +2w> and review [2026-06-13 Sat]."
    )

    XCTAssertEqual(
      set.replacing(timestamp: set.timestamps[1], isActive: true),
      "Meet <2026-06-12 Fri 09:00-10:00 +1w> and review <2026-06-13 Sat>."
    )
  }

  func testEditableInlineTimestampSetAllowsPartialDateDrafts() {
    let set = OrgEditableInlineTimestampSet(rawText: "Due <2026-06-12 Fri>.")

    let updated = set.replacing(timestamp: set.timestamps[0], date: "2026-06")
    XCTAssertEqual(updated, "Due <2026-06>.")

    let partialSet = OrgEditableInlineTimestampSet(rawText: updated)
    XCTAssertEqual(partialSet.timestamps.count, 1)
    XCTAssertEqual(partialSet.timestamps[0].date, "2026-06")
  }

  func testEditableInlineMarkupSetRewritesDelimitedMarkup() {
    let set = OrgEditableInlineMarkupSet(rawText: "Use `code`, *bold*, /italic/, _under_, +gone+, ~verb~, and =lit=.")

    XCTAssertEqual(set.markups.map(\.kind), [.code, .bold, .italic, .underline, .strike, .code, .code])
    XCTAssertEqual(set.markups.map(\.text), ["code", "bold", "italic", "under", "gone", "verb", "lit"])

    XCTAssertEqual(
      set.replacing(markup: set.markups[0], text: "new code"),
      "Use `new code`, *bold*, /italic/, _under_, +gone+, ~verb~, and =lit=."
    )

    XCTAssertEqual(
      set.replacing(markup: set.markups[2], kind: .bold),
      "Use `code`, *bold*, *italic*, _under_, +gone+, ~verb~, and =lit=."
    )
  }

  func testEditableInlineMarkupSetSkipsLinksAndTimestamps() {
    let set = OrgEditableInlineMarkupSet(rawText: "See [[id:abc][*Alice*]], [*docs*](https://example.com), and <2026-06-12 Fri +1w>.")

    XCTAssertTrue(set.markups.isEmpty)
  }

  func testEditableInlineMarkupSetWrapsSelection() {
    let edit = OrgEditableInlineMarkupSet.wrappingSelection(
      in: "hello world",
      range: NSRange(location: 6, length: 5),
      kind: .bold
    )

    XCTAssertEqual(edit.text, "hello *world*")
    XCTAssertEqual(edit.selectedRange, NSRange(location: 7, length: 5))

    let inserted = OrgEditableInlineMarkupSet.wrappingSelection(
      in: "hello world",
      range: NSRange(location: 6, length: 0),
      kind: .code
    )

    XCTAssertEqual(inserted.text, "hello `code`world")
    XCTAssertEqual(inserted.selectedRange, NSRange(location: 7, length: 4))
  }

  func testEditableInlineTokenFindsFocusedTokenAtCaretOrSelection() {
    let raw = "See [[id:abc][Alice]] on <2026-06-12 Fri> with `code`."

    let linkToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: 8, length: 0))
    if case .link(let link) = linkToken {
      XCTAssertEqual(link.label, "Alice")
      XCTAssertEqual(link.target, "id:abc")
    } else {
      XCTFail("Expected focused link token")
    }

    let timestampToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: 27, length: 0))
    if case .timestamp(let timestamp) = timestampToken {
      XCTAssertEqual(timestamp.date, "2026-06-12")
    } else {
      XCTFail("Expected focused timestamp token")
    }

    let markupToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: 52, length: 0))
    if case .markup(let markup) = markupToken {
      XCTAssertEqual(markup.kind, .code)
      XCTAssertEqual(markup.text, "code")
    } else {
      XCTFail("Expected focused markup token")
    }

    let selectedToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: 5, length: 12))
    if case .link = selectedToken {
    } else {
      XCTFail("Expected selected range to focus overlapping link")
    }
  }

  func testEditableInlineTokenSkipsPlainParagraphs() {
    let raw = String(repeating: "plain text without inline org markers ", count: 200)
    let nsRaw = raw as NSString

    XCTAssertFalse(OrgInlineParser.hasInlineSyntaxCandidate(raw))
    XCTAssertEqual(OrgEditableInlineToken.boundedUTF16Length(in: raw), nsRaw.length)
    XCTAssertNil(OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: nsRaw.length / 2, length: 0)))
  }

  func testEditableInlineTokenChecksFocusedSyntaxNearSelection() {
    let raw = "See [[id:abc][Alice]]. " + String(repeating: "plain text ", count: 160)
    let nsRaw = raw as NSString
    let aliceRange = nsRaw.range(of: "Alice")
    let farPlainRange = NSRange(location: nsRaw.length, length: 0)

    XCTAssertTrue(OrgInlineParser.hasInlineSyntaxCandidate(raw))
    XCTAssertTrue(OrgEditableInlineToken.hasFocusedInlineSyntaxCandidate(
      in: raw,
      selection: NSRange(location: aliceRange.location, length: 0)
    ))
    XCTAssertFalse(OrgEditableInlineToken.hasFocusedInlineSyntaxCandidate(
      in: raw,
      selection: farPlainRange
    ))
    XCTAssertNil(OrgEditableInlineToken.focused(in: raw, selection: farPlainRange))
  }

  func testEditableInlineTokenSkipsFocusedScanForLargeParagraphs() {
    let prefix = String(repeating: "x", count: OrgEditableInlineToken.focusedScanUTF16Limit + 1)
    let raw = "\(prefix) [[id:abc][Alice]]"
    let nsRaw = raw as NSString
    let aliceRange = nsRaw.range(of: "Alice")

    XCTAssertFalse(OrgEditableInlineToken.shouldScanFocusedToken(utf16Length: nsRaw.length))
    XCTAssertNil(OrgEditableInlineToken.boundedUTF16Length(in: raw))
    XCTAssertNil(OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: aliceRange.location, length: 0)))

    let smallRaw = "See [[id:abc][Alice]]"
    let smallNSRaw = smallRaw as NSString
    let smallAliceRange = smallNSRaw.range(of: "Alice")
    let focused = OrgEditableInlineToken.focused(
      in: smallRaw,
      selection: NSRange(location: smallAliceRange.location, length: 0),
      maxUTF16Length: smallNSRaw.length
    )

    if case .link(let link) = focused {
      XCTAssertEqual(link.label, "Alice")
      XCTAssertEqual(link.target, "id:abc")
    } else {
      XCTFail("Expected focused link token when scan limit permits it")
    }
  }

  func testEditingDraftAppendsToHeadingTitlePreservingStructure() {
    let heading = OrgEditableBlock(
      startLine: 3,
      endLineExclusive: 4,
      rawText: "* TODO [#A] Parent :work:",
      rendered: .heading(OrgHeadingBlock(level: 1, todo: "TODO", priority: "A", title: "Parent", tags: ["work"]))
    )
    XCTAssertEqual(
      WorkspaceStore.editingDraft(heading, appending: "!"),
      "* TODO [#A] Parent! :work:"
    )

    let emptyTodo = OrgEditableBlock(
      startLine: 4,
      endLineExclusive: 5,
      rawText: "** TODO",
      rendered: .heading(OrgHeadingBlock(level: 2, todo: "TODO", priority: nil, title: "", tags: []))
    )
    XCTAssertEqual(
      WorkspaceStore.editingDraft(emptyTodo, appending: "Call Bob"),
      "** TODO Call Bob"
    )
  }

  func testEditableInlineTokenUsesBoundedUTF16Length() {
    XCTAssertEqual(
      OrgEditableInlineToken.boundedUTF16Length(in: "abcd", maxUTF16Length: 4),
      4
    )
    XCTAssertNil(OrgEditableInlineToken.boundedUTF16Length(in: "abcde", maxUTF16Length: 4))
    XCTAssertEqual(
      OrgEditableInlineToken.boundedUTF16Length(in: "a😀", maxUTF16Length: 3),
      3
    )
    XCTAssertNil(OrgEditableInlineToken.boundedUTF16Length(in: "a😀", maxUTF16Length: 2))
    XCTAssertNil(OrgEditableInlineToken.boundedUTF16Length(in: "", maxUTF16Length: -1))
  }

  func testEditableInlineTokenUsesLocalScanForLargeParagraphs() {
    let prefix = String(repeating: "x", count: OrgEditableInlineToken.focusedFullParseUTF16Limit + 32)
    let raw = "\(prefix) See [[id:abc][Alice]] on <2026-06-12 Fri> with `code`."
    let nsRaw = raw as NSString

    let aliceRange = nsRaw.range(of: "Alice")
    let linkToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: aliceRange.location, length: 0))
    if case .link(let link) = linkToken {
      XCTAssertEqual(link.id, "link:\(nsRaw.range(of: "[[id:abc][Alice]]").location)")
      XCTAssertEqual(link.label, "Alice")
      XCTAssertEqual(link.target, "id:abc")
    } else {
      XCTFail("Expected focused link token in large paragraph")
    }

    let timestampRange = nsRaw.range(of: "2026-06-12")
    let timestampToken = OrgEditableInlineToken.focused(
      in: raw,
      selection: NSRange(location: timestampRange.location, length: 0)
    )
    if case .timestamp(let timestamp) = timestampToken {
      XCTAssertEqual(timestamp.id, "timestamp:\(nsRaw.range(of: "<2026-06-12 Fri>").location)")
      XCTAssertEqual(timestamp.date, "2026-06-12")
    } else {
      XCTFail("Expected focused timestamp token in large paragraph")
    }

    let codeRange = nsRaw.range(of: "code")
    let markupToken = OrgEditableInlineToken.focused(in: raw, selection: NSRange(location: codeRange.location, length: 0))
    if case .markup(let markup) = markupToken {
      XCTAssertEqual(markup.id, "markup:\(nsRaw.range(of: "`code`").location)")
      XCTAssertEqual(markup.text, "code")
    } else {
      XCTFail("Expected focused markup token in large paragraph")
    }
  }

  func testRenderedEntryMoveAvailabilityUsesStableSignatures() {
    let blocks = [
      OrgEditableBlock(
        id: "heading",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "* Parent",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Parent", tags: []))
      ),
      OrgEditableBlock(
        id: "first",
        startLine: 2,
        endLineExclusive: 3,
        rawText: "First",
        rendered: .paragraph("First")
      ),
      OrgEditableBlock(
        id: "blank",
        startLine: 3,
        endLineExclusive: 4,
        rawText: "",
        rendered: .blank
      ),
      OrgEditableBlock(
        id: "last",
        startLine: 4,
        endLineExclusive: 5,
        rawText: "Last",
        rendered: .paragraph("Last")
      )
    ]
    let source = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "",
      isSubtree: true
    )
    let sourceContext = OrgRenderedEntrySourceContext(source)

    let availability = OrgRenderedEntryMoveAvailability.make(for: blocks, source: sourceContext)
    XCTAssertEqual(
      availability.signature,
      OrgRenderedEntryMoveAvailability.signature(for: blocks, source: sourceContext)
    )
    XCTAssertNil(availability.values["heading"])
    XCTAssertEqual(availability.values["first"], OrgRenderedEntryBlockMoveAvailability(up: false, down: true))
    XCTAssertNil(availability.values["blank"])
    XCTAssertEqual(availability.values["last"], OrgRenderedEntryBlockMoveAvailability(up: true, down: false))

    let readOnlySource = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "",
      isSubtree: true,
      isEditable: false
    )
    XCTAssertTrue(
      OrgRenderedEntryMoveAvailability.make(
        for: blocks,
        source: OrgRenderedEntrySourceContext(readOnlySource)
      ).values.isEmpty
    )
  }

  func testRenderedEntryMoveAvailabilityOnlyStoresVisibleRows() {
    let blocks = [
      OrgEditableBlock(
        id: "heading",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "* Parent",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Parent", tags: []))
      ),
      OrgEditableBlock(
        id: "first",
        startLine: 2,
        endLineExclusive: 3,
        rawText: "First",
        rendered: .paragraph("First")
      ),
      OrgEditableBlock(
        id: "middle",
        startLine: 3,
        endLineExclusive: 4,
        rawText: "Middle",
        rendered: .paragraph("Middle")
      ),
      OrgEditableBlock(
        id: "last",
        startLine: 4,
        endLineExclusive: 5,
        rawText: "Last",
        rendered: .paragraph("Last")
      )
    ]
    let source = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 5,
      text: "",
      isSubtree: true
    )
    let sourceContext = OrgRenderedEntrySourceContext(source)

    let availability = OrgRenderedEntryMoveAvailability.make(
      for: blocks,
      source: sourceContext,
      visibleRange: 2..<3
    )

    XCTAssertEqual(
      availability.signature,
      OrgRenderedEntryMoveAvailability.signature(for: blocks, source: sourceContext, visibleRange: 2..<3)
    )
    XCTAssertNil(availability.values["first"])
    XCTAssertEqual(availability.values["middle"], OrgRenderedEntryBlockMoveAvailability(up: true, down: true))
    XCTAssertNil(availability.values["last"])
  }

  func testRenderedEntryMoveAvailabilityWindowsLargePages() {
    let blocks = (1...1_500).map { index in
      OrgEditableBlock(
        id: "block-\(index)",
        startLine: index,
        endLineExclusive: index + 1,
        rawText: "Block \(index)",
        rendered: .paragraph("Block \(index)")
      )
    }
    let source = EntrySource(
      file: "/tmp/large.org2",
      startLine: 1,
      endLineExclusive: 1_501,
      text: "",
      isSubtree: false
    )

    let availability = OrgRenderedEntryMoveAvailability.make(
      for: blocks,
      source: OrgRenderedEntrySourceContext(source),
      visibleRange: 700..<704
    )

    XCTAssertEqual(Set(availability.values.keys), Set(["block-701", "block-702", "block-703", "block-704"]))
    XCTAssertEqual(availability.values["block-701"], OrgRenderedEntryBlockMoveAvailability(up: true, down: true))
    XCTAssertNil(availability.values["block-1"])
    XCTAssertNil(availability.values["block-1500"])
  }

  func testRenderedEntryMoveAvailabilitySignatureChangesWhenEditabilityChanges() {
    let editableBlock = OrgEditableBlock(
      id: "middle",
      startLine: 2,
      endLineExclusive: 3,
      rawText: "Middle",
      rendered: .paragraph("Middle")
    )
    let blankBlock = OrgEditableBlock(
      id: "middle",
      startLine: 2,
      endLineExclusive: 3,
      rawText: "",
      rendered: .blank
    )
    let source = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 4,
      text: "",
      isSubtree: false
    )
    let sourceContext = OrgRenderedEntrySourceContext(source)

    XCTAssertNotEqual(
      OrgRenderedEntryMoveAvailability.signature(for: [editableBlock], source: sourceContext),
      OrgRenderedEntryMoveAvailability.signature(for: [blankBlock], source: sourceContext)
    )
  }

  func testRenderedEntryWindowResetKeyIgnoresEditedSourceLength() {
    let source = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 50,
      text: "",
      isSubtree: false
    )
    let editedSource = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 54,
      text: "",
      isSubtree: false
    )
    let differentStart = EntrySource(
      file: "/tmp/test.org2",
      startLine: 4,
      endLineExclusive: 54,
      text: "",
      isSubtree: false
    )
    let readOnlySource = EntrySource(
      file: "/tmp/test.org2",
      startLine: 1,
      endLineExclusive: 54,
      text: "",
      isSubtree: false,
      isEditable: false
    )

    XCTAssertEqual(
      OrgRenderedEntryView.renderWindowResetKey(for: source),
      OrgRenderedEntryView.renderWindowResetKey(for: editedSource)
    )
    XCTAssertNotEqual(
      OrgRenderedEntryView.renderWindowResetKey(for: source),
      OrgRenderedEntryView.renderWindowResetKey(for: differentStart)
    )
    XCTAssertNotEqual(
      OrgRenderedEntryView.renderWindowResetKey(for: source),
      OrgRenderedEntryView.renderWindowResetKey(for: readOnlySource)
    )
    XCTAssertEqual(OrgRenderedEntryView.renderWindowResetKey(for: nil as EntrySource?), "none")
  }

  func testRenderedEntryWindowAnchorsDeepSelections() {
    let blocks = (1...500).map { line in
      OrgEditableBlock(
        id: "block-\(line)",
        startLine: line,
        endLineExclusive: line + 1,
        rawText: "Line \(line)",
        rendered: .paragraph("Line \(line)")
      )
    }

    let topWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: nil
    )
    XCTAssertEqual(topWindow.range.lowerBound, 0)
    XCTAssertEqual(topWindow.range.upperBound, 80)
    XCTAssertLessThan(topWindow.range.upperBound, blocks.count)
    XCTAssertFalse(topWindow.hasPrevious)
    XCTAssertTrue(topWindow.hasNext)
    XCTAssertFalse(OrgRenderedEntryView.allowsHoverChrome(blockCount: blocks.count))
    XCTAssertTrue(OrgRenderedEntryView.allowsHoverChrome(blockCount: 80))
    XCTAssertTrue(OrgRenderedEntryView.shouldAutoExpandNextFooter(visibleWindow: topWindow))

    let selectedIndex = 360
    let anchoredWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: selectedIndex
    )
    XCTAssertTrue(anchoredWindow.range.contains(selectedIndex))
    XCTAssertGreaterThan(anchoredWindow.range.lowerBound, 0)
    XCTAssertLessThan(anchoredWindow.range.upperBound, blocks.count)
    XCTAssertLessThan(anchoredWindow.range.count, topWindow.range.upperBound)
    XCTAssertTrue(anchoredWindow.hasPrevious)
    XCTAssertTrue(anchoredWindow.hasNext)
    XCTAssertFalse(OrgRenderedEntryView.shouldAutoExpandNextFooter(visibleWindow: anchoredWindow))
  }

  func testRenderedRowChromeUsesStableHiddenState() {
    XCTAssertTrue(RenderedRowChrome.rendersControls(isVisible: true))
    XCTAssertTrue(RenderedRowChrome.rendersControls(isVisible: false))
    XCTAssertEqual(RenderedRowChrome.controlsOpacity(isVisible: true), 1)
    XCTAssertEqual(RenderedRowChrome.controlsOpacity(isVisible: false), 0)
    XCTAssertTrue(RenderedRowChrome.allowsHitTesting(isVisible: true))
    XCTAssertFalse(RenderedRowChrome.allowsHitTesting(isVisible: false))
    XCTAssertTrue(RenderedRowChrome.rendersControlLayer(
      isSourceEditable: true,
      allowsHoverChrome: true,
      isSelected: false
    ))
    XCTAssertFalse(RenderedRowChrome.rendersControlLayer(
      isSourceEditable: true,
      allowsHoverChrome: false,
      isSelected: false
    ))
    XCTAssertTrue(RenderedRowChrome.rendersControlLayer(
      isSourceEditable: true,
      allowsHoverChrome: false,
      isSelected: true
    ))
    XCTAssertFalse(RenderedRowChrome.rendersControlLayer(
      isSourceEditable: false,
      allowsHoverChrome: true,
      isSelected: true
    ))
    XCTAssertEqual(
      RenderedRowChrome.contentTrailingPadding(
        isSourceEditable: true,
        allowsHoverChrome: true,
        isSelected: false
      ),
      RenderedRowChrome.controlsReserveWidth
    )
    XCTAssertEqual(
      RenderedRowChrome.contentTrailingPadding(
        isSourceEditable: true,
        allowsHoverChrome: false,
        isSelected: false
      ),
      0
    )
    XCTAssertEqual(
      RenderedRowChrome.contentTrailingPadding(
        isSourceEditable: true,
        allowsHoverChrome: false,
        isSelected: true
      ),
      RenderedRowChrome.controlsReserveWidth
    )
    XCTAssertEqual(
      RenderedRowChrome.contentTrailingPadding(
        isSourceEditable: false,
        allowsHoverChrome: true,
        isSelected: true
      ),
      0
    )
  }

  func testRenderedBlockEditingPolicyDoesNotStartInlineEditingForRichBlocksOnSingleClick() {
    let editableBlocks = [
      OrgEditableBlock(
        id: "heading",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "* TODO Heading",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: "TODO", priority: nil, title: "Heading", tags: []))
      ),
      OrgEditableBlock(
        id: "quote",
        startLine: 5,
        endLineExclusive: 8,
        rawText: "#+begin_quote\nquoted\n#+end_quote",
        rendered: .quote(["quoted"])
      ),
      OrgEditableBlock(
        id: "source",
        startLine: 8,
        endLineExclusive: 11,
        rawText: "#+begin_src sh\necho hi\n#+end_src",
        rendered: .source(language: "sh", lines: ["echo hi"])
      ),
      OrgEditableBlock(
        id: "table",
        startLine: 11,
        endLineExclusive: 13,
        rawText: "| A | B |\n| 1 | 2 |",
        rendered: .table(OrgTableBlock(rows: [
          .cells(["A", "B"]),
          .cells(["1", "2"])
        ]))
      )
    ]

    for block in editableBlocks {
      XCTAssertFalse(
        RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: block, isSourceEditable: true),
        block.id
      )
      XCTAssertFalse(
        RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: block, isSourceEditable: false),
        block.id
      )
    }
  }

  func testRenderedBlockEditingPolicyDoesNotStartInlineEditingForStructuralBlocksOnSingleClick() {
    let divider = OrgEditableBlock(
      id: "divider",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "-----",
      rendered: .horizontalRule
    )
    let blank = OrgEditableBlock(
      id: "blank",
      startLine: 2,
      endLineExclusive: 3,
      rawText: "",
      rendered: .blank
    )
    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: divider, isSourceEditable: true))
    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: blank, isSourceEditable: true))
    let properties = OrgEditableBlock(
      id: "properties",
      startLine: 3,
      endLineExclusive: 6,
      rawText: ":PROPERTIES:\n:Owner: Avi\n:END:",
      rendered: .properties([OrgPropertyRow(key: "Owner", value: "Avi")])
    )
    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: properties, isSourceEditable: true))
  }

  func testRenderedBlockEditingPolicyDoesNotStartInlineEditingForMediaParagraphsOnSingleClick() throws {
    let embedded = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "inline images [[file:images/image.png][Image]]"
    ).first)
    let standalone = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "[[file:images/image.png][Image]]"
    ).first)

    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: embedded, isSourceEditable: true))
    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: standalone, isSourceEditable: true))
  }

  func testLiveRenderedTextEditingPolicyDoesNotUseDirectEditorsForDocumentTextBlocks() throws {
    let paragraph = try XCTUnwrap(OrgEntryRenderer.parseEditable("Body with [[id:abc][Alice]].").first)
    let listItem = try XCTUnwrap(OrgEntryRenderer.parseEditable("- [ ] Task").first)
    let heading = try XCTUnwrap(OrgEntryRenderer.parseEditable("* Heading").first)
    let media = try XCTUnwrap(OrgEntryRenderer.parseEditable("[[file:images/image.png][Image]]").first)

    XCTAssertFalse(LiveRenderedTextEditingPolicy.usesDirectEditor(block: paragraph, isSourceEditable: true))
    XCTAssertFalse(LiveRenderedTextEditingPolicy.usesDirectEditor(block: listItem, isSourceEditable: true))
    XCTAssertFalse(LiveRenderedTextEditingPolicy.usesDirectEditor(block: heading, isSourceEditable: true))
    XCTAssertFalse(LiveRenderedTextEditingPolicy.usesDirectEditor(block: media, isSourceEditable: true))
    XCTAssertFalse(LiveRenderedTextEditingPolicy.usesDirectEditor(block: paragraph, isSourceEditable: false))
  }

  func testRenderedBlockDisplayPolicyCollapsesBlankButKeepsProperties() {
    let blank = OrgEditableBlock(
      id: "blank",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "",
      rendered: .blank
    )
    let properties = OrgEditableBlock(
      id: "properties",
      startLine: 2,
      endLineExclusive: 5,
      rawText: ":PROPERTIES:\n:ID: 316c31f8\n:END:",
      rendered: .properties([OrgPropertyRow(key: "ID", value: "316c31f8")])
    )
    let heading = OrgEditableBlock(
      id: "heading",
      startLine: 5,
      endLineExclusive: 6,
      rawText: "* Heading",
      rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Heading", tags: []))
    )

    XCTAssertFalse(OrgRenderedBlockDisplayPolicy.isVisible(blank))
    XCTAssertTrue(OrgRenderedBlockDisplayPolicy.isVisible(properties))
    XCTAssertTrue(OrgRenderedBlockDisplayPolicy.isVisible(heading))
    XCTAssertFalse(OrgRenderedBlockDisplayPolicy.showsRowChrome(for: blank))
    XCTAssertTrue(OrgRenderedBlockDisplayPolicy.showsRowChrome(for: properties))
    XCTAssertTrue(OrgRenderedBlockDisplayPolicy.showsRowChrome(for: heading))
  }

  func testRenderedFoldTreeHidesHeadingAndListDescendants() {
    let blocks = [
      OrgEditableBlock(
        id: "h1",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "* Parent",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Parent", tags: []))
      ),
      OrgEditableBlock(id: "p1", startLine: 2, endLineExclusive: 3, rawText: "Body", rendered: .paragraph("Body")),
      OrgEditableBlock(
        id: "h2",
        startLine: 3,
        endLineExclusive: 4,
        rawText: "** Child",
        rendered: .heading(OrgHeadingBlock(level: 2, todo: nil, priority: nil, title: "Child", tags: []))
      ),
      OrgEditableBlock(id: "p2", startLine: 4, endLineExclusive: 5, rawText: "Child body", rendered: .paragraph("Child body")),
      OrgEditableBlock(
        id: "next",
        startLine: 5,
        endLineExclusive: 6,
        rawText: "* Next",
        rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Next", tags: []))
      ),
      OrgEditableBlock(id: "list", startLine: 6, endLineExclusive: 7, rawText: "- Parent", rendered: .listItem(indent: 0, marker: "-", checkbox: nil, text: "Parent")),
      OrgEditableBlock(id: "child", startLine: 7, endLineExclusive: 8, rawText: "  - Child", rendered: .listItem(indent: 2, marker: "-", checkbox: nil, text: "Child")),
      OrgEditableBlock(id: "grand", startLine: 8, endLineExclusive: 9, rawText: "    - Grand", rendered: .listItem(indent: 4, marker: "-", checkbox: nil, text: "Grand")),
      OrgEditableBlock(id: "sibling", startLine: 9, endLineExclusive: 10, rawText: "- Sibling", rendered: .listItem(indent: 0, marker: "-", checkbox: nil, text: "Sibling"))
    ]

    XCTAssertTrue(OrgRenderedFoldTree.isFoldable(blocks[0], in: blocks))
    XCTAssertTrue(OrgRenderedFoldTree.isFoldable(blocks[5], in: blocks))
    XCTAssertFalse(OrgRenderedFoldTree.isFoldable(blocks[8], in: blocks))

    XCTAssertEqual(
      OrgRenderedFoldTree.visibleBlocks(blocks, foldedBlockIDs: ["h1"]).map(\.id),
      ["h1", "next", "list", "child", "grand", "sibling"]
    )
    XCTAssertEqual(
      OrgRenderedFoldTree.visibleBlocks(blocks, foldedBlockIDs: ["list"]).map(\.id),
      ["h1", "p1", "h2", "p2", "next", "list", "sibling"]
    )
    XCTAssertEqual(
      OrgRenderedFoldTree.foldedAncestorID(hiding: "grand", foldedBlockIDs: ["list", "child"], blocks: blocks),
      "list"
    )
  }

  @MainActor
  func testRenderedBlockViewEqualityUsesCachedRenderIdentity() {
    let longBody = String(repeating: "Long plain paragraph body.\n", count: 1_500)
    let updatedBody = longBody + "Updated"
    let initialBlock = OrgEditableBlock(
      id: "paragraph",
      startLine: 12,
      endLineExclusive: 1_512,
      rawText: longBody,
      rendered: .paragraph(longBody)
    )
    let sameBlock = OrgEditableBlock(
      id: "paragraph",
      startLine: 12,
      endLineExclusive: 1_512,
      rawText: longBody,
      rendered: .paragraph(longBody)
    )
    let updatedBlock = OrgEditableBlock(
      id: "paragraph",
      startLine: 12,
      endLineExclusive: 1_512,
      rawText: updatedBody,
      rendered: .paragraph(updatedBody)
    )

    XCTAssertEqual(initialBlock.renderIdentity, sameBlock.renderIdentity)
    XCTAssertNotEqual(initialBlock.renderIdentity, updatedBlock.renderIdentity)
    XCTAssertEqual(
      RenderedBlockView(block: initialBlock.rendered, rawText: initialBlock.rawText, editableBlock: initialBlock),
      RenderedBlockView(block: sameBlock.rendered, rawText: sameBlock.rawText, editableBlock: sameBlock)
    )
    XCTAssertNotEqual(
      RenderedBlockView(block: initialBlock.rendered, rawText: initialBlock.rawText, editableBlock: initialBlock),
      RenderedBlockView(block: updatedBlock.rendered, rawText: updatedBlock.rawText, editableBlock: updatedBlock)
    )
  }

  @MainActor
  func testRenderedEntryViewEqualityUsesRenderContext() {
    let source = EntrySource(
      file: "/tmp/render-context.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "Alpha\nBeta",
      isSubtree: false
    )
    let sourceContext = OrgRenderedEntrySourceContext(source)
    let editedTextSourceContext = OrgRenderedEntrySourceContext(EntrySource(
      file: "/tmp/render-context.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "Alpha\nBeta\nEdited",
      isSubtree: false
    ))
    let blocks = [
      OrgEditableBlock(
        id: "alpha",
        startLine: 1,
        endLineExclusive: 2,
        rawText: "Alpha",
        rendered: .paragraph("Alpha")
      ),
      OrgEditableBlock(
        id: "source",
        startLine: 2,
        endLineExclusive: 3,
        rawText: "#+begin_src sh\necho hi\n#+end_src",
        rendered: .source(language: "sh", lines: ["echo hi"])
      )
    ]
    let signature = WorkspaceStore.renderedBlocksRenderSignature(for: blocks)
    let emptyRunSignature = WorkspaceStore.sourceBlockRunsRenderSignature(for: [:])
    let runStates = [
      "/tmp/render-context.org2:source": SourceBlockRunState(
        status: .succeeded,
        language: "sh",
        commandLabel: "sh",
        stdout: "hi\n"
      )
    ]
    let runSignature = WorkspaceStore.sourceBlockRunsRenderSignature(for: runStates)
    XCTAssertNotEqual(emptyRunSignature, runSignature)
    XCTAssertNotEqual(
      runSignature,
      WorkspaceStore.sourceBlockRunsRenderSignature(for: [
        "/tmp/render-context.org2:source": SourceBlockRunState(
          status: .succeeded,
          language: "sh",
          commandLabel: "sh",
          stdout: "hi again\n"
        )
      ])
    )
    let base = OrgRenderedEntryView(
      blocks: blocks,
      blocksRenderSignature: signature,
      source: sourceContext,
      corpusRoot: nil,
      selectedBlockID: nil,
      selectedBlockIndex: nil,
      editingBlockID: nil,
      sourceBlockRunsRenderSignature: emptyRunSignature,
      sourceBlockRuns: [:]
    )

    XCTAssertEqual(
      base,
      OrgRenderedEntryView(
        blocks: blocks,
        blocksRenderSignature: signature,
        source: editedTextSourceContext,
        corpusRoot: nil,
        selectedBlockID: nil,
        selectedBlockIndex: nil,
        editingBlockID: nil,
        sourceBlockRunsRenderSignature: emptyRunSignature,
        sourceBlockRuns: [:]
      )
    )

    var updatedBlocks = blocks
    updatedBlocks[0] = OrgEditableBlock(
      id: "alpha",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "Alpha updated",
      rendered: .paragraph("Alpha updated")
    )
    XCTAssertNotEqual(
      base,
      OrgRenderedEntryView(
        blocks: updatedBlocks,
        blocksRenderSignature: WorkspaceStore.renderedBlocksRenderSignature(for: updatedBlocks),
        source: sourceContext,
        corpusRoot: nil,
        selectedBlockID: nil,
        selectedBlockIndex: nil,
        editingBlockID: nil,
        sourceBlockRunsRenderSignature: emptyRunSignature,
        sourceBlockRuns: [:]
      )
    )

    XCTAssertNotEqual(
      base,
      OrgRenderedEntryView(
        blocks: blocks,
        blocksRenderSignature: signature,
        source: sourceContext,
        corpusRoot: nil,
        selectedBlockID: "alpha",
        selectedBlockIndex: 0,
        editingBlockID: nil,
        sourceBlockRunsRenderSignature: emptyRunSignature,
        sourceBlockRuns: [:]
      )
    )

    XCTAssertEqual(
      base,
      OrgRenderedEntryView(
        blocks: blocks,
        blocksRenderSignature: signature,
        source: sourceContext,
        corpusRoot: nil,
        selectedBlockID: nil,
        selectedBlockIndex: nil,
        editingBlockID: nil,
        sourceBlockRunsRenderSignature: emptyRunSignature,
        sourceBlockRuns: [:]
      )
    )

    XCTAssertNotEqual(
      base,
      OrgRenderedEntryView(
        blocks: blocks,
        blocksRenderSignature: signature,
        source: sourceContext,
        corpusRoot: nil,
        selectedBlockID: nil,
        selectedBlockIndex: nil,
        editingBlockID: nil,
        sourceBlockRunsRenderSignature: runSignature,
        sourceBlockRuns: runStates
      )
    )
  }

  @MainActor
  func testRenderedBlockViewEqualityUsesSourceRunSignature() {
    let block = OrgEditableBlock(
      id: "source",
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_src sh\necho hi\n#+end_src",
      rendered: .source(language: "sh", lines: ["echo hi"])
    )
    let baseActions = RenderedBlockInlineActions(
      isSourceEditable: true,
      decryptSubtree: nil,
      toggleHeadingTodo: nil,
      setHeadingPriority: nil,
      setHeadingTags: nil,
      setPlanningBlock: nil,
      setPropertyValue: nil,
      toggleListItemCheckbox: nil,
      sourceBlockRunRenderSignature: "same-output",
      sourceBlockRunState: SourceBlockRunState(
        status: .succeeded,
        language: "sh",
        commandLabel: "sh",
        stdout: "hi\n"
      ),
      runSourceBlock: nil,
      copySourceBlock: nil
    )
    let changedStateSameSignature = RenderedBlockInlineActions(
      isSourceEditable: true,
      decryptSubtree: nil,
      toggleHeadingTodo: nil,
      setHeadingPriority: nil,
      setHeadingTags: nil,
      setPlanningBlock: nil,
      setPropertyValue: nil,
      toggleListItemCheckbox: nil,
      sourceBlockRunRenderSignature: "same-output",
      sourceBlockRunState: SourceBlockRunState(
        status: .succeeded,
        language: "sh",
        commandLabel: "sh",
        stdout: String(repeating: "large output\n", count: 1_000)
      ),
      runSourceBlock: nil,
      copySourceBlock: nil
    )
    let changedSignature = RenderedBlockInlineActions(
      isSourceEditable: true,
      decryptSubtree: nil,
      toggleHeadingTodo: nil,
      setHeadingPriority: nil,
      setHeadingTags: nil,
      setPlanningBlock: nil,
      setPropertyValue: nil,
      toggleListItemCheckbox: nil,
      sourceBlockRunRenderSignature: "changed-output",
      sourceBlockRunState: SourceBlockRunState(
        status: .succeeded,
        language: "sh",
        commandLabel: "sh",
        stdout: "hi again\n"
      ),
      runSourceBlock: nil,
      copySourceBlock: nil
    )

    let base = RenderedBlockView(
      block: block.rendered,
      rawText: block.rawText,
      editableBlock: block,
      inlineActions: baseActions
    )
    XCTAssertEqual(
      base,
      RenderedBlockView(
        block: block.rendered,
        rawText: block.rawText,
        editableBlock: block,
        inlineActions: changedStateSameSignature
      )
    )
    XCTAssertNotEqual(
      base,
      RenderedBlockView(
        block: block.rendered,
        rawText: block.rawText,
        editableBlock: block,
        inlineActions: changedSignature
      )
    )
  }

  func testRenderedEntryWindowExpandsAndKeepsSelectionVisible() {
    let blocks = (1...500).map { line in
      OrgEditableBlock(
        id: "block-\(line)",
        startLine: line,
        endLineExclusive: line + 1,
        rawText: "Line \(line)",
        rendered: .paragraph("Line \(line)")
      )
    }

    let selectedIndex = 360
    let anchoredWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: selectedIndex
    )
    let expandedPrevious = anchoredWindow.expanding(.previous, by: 50, totalCount: blocks.count)
    XCTAssertLessThan(expandedPrevious.lowerBound, anchoredWindow.range.lowerBound)
    XCTAssertEqual(expandedPrevious.upperBound, anchoredWindow.range.upperBound)

    let expandedNext = anchoredWindow.expanding(.next, by: 50, totalCount: blocks.count)
    XCTAssertEqual(expandedNext.lowerBound, anchoredWindow.range.lowerBound)
    XCTAssertGreaterThan(expandedNext.upperBound, anchoredWindow.range.upperBound)
    XCTAssertFalse(OrgRenderedEntryView.shouldAutoExpandNextFooter(
      visibleWindow: OrgRenderedBlockWindow(range: expandedNext, totalCount: blocks.count)
    ))

    let requestedWindow = 0..<40
    let correctedWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: requestedWindow,
      blocks: blocks,
      selectedBlockIndex: selectedIndex
    )
    XCTAssertTrue(correctedWindow.range.contains(selectedIndex))
    XCTAssertGreaterThan(correctedWindow.range.lowerBound, requestedWindow.lowerBound)
  }

  func testRenderedEntryWindowUsesSmallerPagesForLargeDocuments() {
    let blocks = (1...1_500).map { line in
      OrgEditableBlock(
        id: "block-\(line)",
        startLine: line,
        endLineExclusive: line + 1,
        rawText: "Line \(line)",
        rendered: .paragraph("Line \(line)")
      )
    }

    XCTAssertEqual(OrgRenderedEntryView.initialRenderedBlockLimit(for: 500), 80)
    XCTAssertEqual(OrgRenderedEntryView.initialRenderedBlockLimit(for: blocks.count), 48)
    XCTAssertEqual(OrgRenderedEntryView.renderedBlockPageSize(for: blocks.count), 48)

    let topWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: nil
    )
    XCTAssertEqual(topWindow.range, 0..<48)
    XCTAssertTrue(OrgRenderedEntryView.shouldAutoExpandNextFooter(visibleWindow: topWindow))

    let expandedNext = topWindow.expanding(
      .next,
      by: OrgRenderedEntryView.renderedBlockPageSize(for: blocks.count),
      totalCount: blocks.count
    )
    XCTAssertEqual(expandedNext, 0..<96)
    XCTAssertTrue(OrgRenderedEntryView.shouldAutoExpandNextFooter(
      visibleWindow: OrgRenderedBlockWindow(range: expandedNext, totalCount: blocks.count)
    ))

    let anchoredWindow = OrgRenderedEntryView.visibleWindow(
      requestedWindow: nil,
      blocks: blocks,
      selectedBlockIndex: 1_200
    )
    XCTAssertGreaterThan(anchoredWindow.range.lowerBound, 0)
    XCTAssertFalse(OrgRenderedEntryView.shouldAutoExpandNextFooter(visibleWindow: anchoredWindow))
  }

  func testProgressiveRenderFooterAutoLoadTokensGateRepeatedLoads() {
    let firstToken = ProgressiveRenderFooterAutoLoad.token(
      visibleRange: "1-48",
      totalCount: 1_500,
      direction: .next
    )
    let expandedToken = ProgressiveRenderFooterAutoLoad.token(
      visibleRange: "1-96",
      totalCount: 1_500,
      direction: .next
    )
    let previousToken = ProgressiveRenderFooterAutoLoad.token(
      visibleRange: "48-96",
      totalCount: 1_500,
      direction: .previous
    )

    XCTAssertTrue(ProgressiveRenderFooterAutoLoad.shouldTrigger(
      autoLoadsOnAppear: true,
      lastTriggeredToken: nil,
      currentToken: firstToken
    ))
    XCTAssertFalse(ProgressiveRenderFooterAutoLoad.shouldTrigger(
      autoLoadsOnAppear: false,
      lastTriggeredToken: nil,
      currentToken: firstToken
    ))
    XCTAssertFalse(ProgressiveRenderFooterAutoLoad.shouldTrigger(
      autoLoadsOnAppear: true,
      lastTriggeredToken: firstToken,
      currentToken: firstToken
    ))
    XCTAssertTrue(ProgressiveRenderFooterAutoLoad.shouldTrigger(
      autoLoadsOnAppear: true,
      lastTriggeredToken: firstToken,
      currentToken: expandedToken
    ))
    XCTAssertNotEqual(firstToken, previousToken)
  }

  @MainActor
  func testSelectedRenderedBlocksMetadataTracksAssignmentsAndMutations() throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let initialSignature = store.selectedRenderedBlocksSignature
    XCTAssertTrue(store.selectedRenderedBlockIndexes.isEmpty)
    let firstBlock = OrgEditableBlock(
      id: "first",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "First",
      rendered: .paragraph("First")
    )
    let secondBlock = OrgEditableBlock(
      id: "second",
      startLine: 2,
      endLineExclusive: 3,
      rawText: "Second",
      rendered: .paragraph("Second")
    )

    store.selectedRenderedBlocks = [firstBlock]
    let assignedSignature = store.selectedRenderedBlocksSignature
    let assignedRenderSignature = store.selectedRenderedBlocksRenderSignature

    let updatedFirstBlock = OrgEditableBlock(
      id: "first",
      startLine: 1,
      endLineExclusive: 2,
      rawText: "First updated",
      rendered: .paragraph("First updated")
    )
    store.selectedRenderedBlocks = [updatedFirstBlock]
    XCTAssertEqual(store.selectedRenderedBlocksSignature, assignedSignature)
    XCTAssertNotEqual(store.selectedRenderedBlocksRenderSignature, assignedRenderSignature)
    XCTAssertEqual(store.selectedRenderedBlockIndexes["first"], 0)

    store.selectedRenderedBlocks.append(secondBlock)

    XCTAssertNotEqual(initialSignature, assignedSignature)
    XCTAssertNotEqual(assignedSignature, store.selectedRenderedBlocksSignature)
    XCTAssertEqual(store.selectedRenderedBlockIndexes["first"], 0)
    XCTAssertEqual(store.selectedRenderedBlockIndexes["second"], 1)

    store.selectedBlockID = "second"
    XCTAssertEqual(store.selectedBlock?.id, "second")
  }

  func testRenderedLineDisplayCacheUsesRawTextAndFallbacks() {
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.headingTitle(
        rawText: "* TODO [#A] Review [[id:abc][Alice]] :work:\nBody",
        fallback: "Review Alice"
      ),
      "Review [[id:abc][Alice]]"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.headingTitle(rawText: "Not a heading", fallback: "Fallback title"),
      "Fallback title"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.headingTitle(rawText: "Not a heading", fallback: "Current title"),
      "Current title"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.listText(rawText: "  - [X] Finish task\ncontinued", fallback: "Finish task"),
      "Finish task"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.listText(rawText: "not-list", fallback: "Fallback item"),
      "Fallback item"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.keywordValue(rawText: "#+TITLE: Project Plan\nBody", fallback: "Project Plan"),
      "Project Plan"
    )
    XCTAssertEqual(
      OrgRenderedLineDisplayCache.keywordValue(rawText: "not-keyword", fallback: "Fallback value"),
      "Fallback value"
    )
  }

  func testHeadingTodoStatusCycle() {
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "TODO"), "DONE")
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "IN_PROGRESS"), "DONE")
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "DONE"), "TODO")
    XCTAssertEqual(WorkspaceStore.nextHeadingTodoStatus(after: "CANCELED"), "TODO")
    XCTAssertNil(WorkspaceStore.nextHeadingTodoStatus(after: "NOTE"))
  }

  func testEditableSourceBlockFormatsAndSwitchesKind() {
    var source = OrgEditableSourceBlock(rawText: """
    #+BEGIN_SRC swift :results output
    let value = 1
    #+END_SRC
    """)

    XCTAssertEqual(source.beginKeyword, "#+begin_src")
    XCTAssertEqual(source.endKeyword, "#+end_src")
    XCTAssertEqual(source.language, "swift")
    XCTAssertEqual(source.parameters, ":results output")
    XCTAssertEqual(source.body, "let value = 1")

    source.language = "python"
    source.parameters = ":results replace"
    source.body = "print(42)"
    XCTAssertEqual(source.formattedRawText, """
    #+begin_src python :results replace
    print(42)
    #+end_src
    """)

    source.setBeginKeyword("#+begin_example")
    XCTAssertEqual(source.language, "")
    XCTAssertEqual(source.formattedRawText, """
    #+begin_example :results replace
    print(42)
    #+end_example
    """)
  }

  func testSourceBlockLineWindowLimitsCollapsedLargeBlocks() {
    let lines = (1...120).map { "line \($0)" }

    let collapsed = SourceBlockLineWindow.make(lines: lines, isExpanded: false, limit: 80)
    XCTAssertEqual(collapsed.visibleLines.count, 80)
    XCTAssertEqual(collapsed.visibleLines.first, "line 1")
    XCTAssertEqual(collapsed.visibleLines.last, "line 80")
    XCTAssertTrue(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenLineCount, 40)

    let expanded = SourceBlockLineWindow.make(lines: lines, isExpanded: true, limit: 80)
    XCTAssertEqual(expanded.visibleLines.count, 120)
    XCTAssertTrue(expanded.isTruncated)
    XCTAssertEqual(expanded.hiddenLineCount, 0)

    let partial = SourceBlockLineWindow.make(lines: lines, visibleLimit: 100)
    XCTAssertEqual(partial.visibleLines.count, 100)
    XCTAssertEqual(partial.visibleLines.last, "line 100")
    XCTAssertTrue(partial.isTruncated)
    XCTAssertEqual(partial.hiddenLineCount, 20)
  }

  func testRenderedBlockExpansionStatePersistsVisibleLimitsByBlockKey() {
    let block = OrgEditableBlock(
      id: "source-block",
      startLine: 10,
      endLineExclusive: 13,
      rawText: "#+begin_src swift\nprint(1)\n#+end_src",
      rendered: .source(language: "swift", lines: ["print(1)"])
    )
    let key = RenderedBlockExpansionState.key(
      sourceFile: "/tmp/example.org2",
      editableBlock: block,
      renderedKind: "source",
      rawText: block.rawText
    )
    let shiftedBlock = OrgEditableBlock(
      id: "source-block",
      startLine: 11,
      endLineExclusive: 14,
      rawText: block.rawText,
      rendered: block.rendered
    )
    let shiftedKey = RenderedBlockExpansionState.key(
      sourceFile: "/tmp/example.org2",
      editableBlock: shiftedBlock,
      renderedKind: "source",
      rawText: shiftedBlock.rawText
    )

    XCTAssertEqual(RenderedBlockExpansionState.visibleLimit(for: key, default: 80), 80)
    RenderedBlockExpansionState.setVisibleLimit(240, for: key)
    XCTAssertEqual(RenderedBlockExpansionState.visibleLimit(for: key, default: 80), 240)
    XCTAssertEqual(RenderedBlockExpansionState.visibleLimit(for: shiftedKey, default: 80), 80)
  }

  func testRenderedBlockExpansionStateComputesToggleLimits() {
    XCTAssertEqual(
      RenderedBlockExpansionState.toggledLimit(
        currentLimit: 80,
        totalCount: 300,
        hiddenCount: 220,
        defaultLimit: 80,
        pageSize: 160
      ),
      240
    )
    XCTAssertEqual(
      RenderedBlockExpansionState.toggledLimit(
        currentLimit: 240,
        totalCount: 300,
        hiddenCount: 60,
        defaultLimit: 80,
        pageSize: 160
      ),
      300
    )
    XCTAssertEqual(
      RenderedBlockExpansionState.toggledLimit(
        currentLimit: 300,
        totalCount: 300,
        hiddenCount: 0,
        defaultLimit: 80,
        pageSize: 160
      ),
      80
    )
  }

  func testQuoteLineWindowLimitsLargeQuotes() {
    let lines = (1...90).map { "quote \($0)" }

    let collapsed = QuoteLineWindow.make(lines: lines, visibleLimit: 40)
    XCTAssertEqual(collapsed.visibleLines.count, 40)
    XCTAssertEqual(collapsed.visibleLines.first, "quote 1")
    XCTAssertEqual(collapsed.visibleLines.last, "quote 40")
    XCTAssertTrue(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenLineCount, 50)

    let partial = QuoteLineWindow.make(lines: lines, visibleLimit: 70)
    XCTAssertEqual(partial.visibleLines.count, 70)
    XCTAssertEqual(partial.visibleLines.last, "quote 70")
    XCTAssertTrue(partial.isTruncated)
    XCTAssertEqual(partial.hiddenLineCount, 20)

    let expanded = QuoteLineWindow.make(lines: lines, visibleLimit: 120)
    XCTAssertEqual(expanded.visibleLines.count, 90)
    XCTAssertFalse(expanded.isTruncated)
    XCTAssertEqual(expanded.hiddenLineCount, 0)

    let plainRaw = """
    #+begin_quote
    Plain quote body
    Second line
    #+end_quote
    """
    XCTAssertFalse(QuoteLineWindow.rawBodyMayContainInlineSyntax(plainRaw))
    XCTAssertEqual(
      QuoteLineWindow.displayLines(rawText: plainRaw, fallback: ["Plain quote body", "Second line"]),
      ["Plain quote body", "Second line"]
    )
    XCTAssertEqual(
      QuoteLineWindow.displayLines(rawText: plainRaw, fallback: ["Current fallback"]),
      ["Current fallback"]
    )

    let richRaw = """
    #+begin_quote
    See [[id:abc][Alice]]
    Use `code`
    #+end_quote
    """
    XCTAssertTrue(QuoteLineWindow.rawBodyMayContainInlineSyntax(richRaw))
    XCTAssertEqual(
      QuoteLineWindow.displayLines(rawText: richRaw, fallback: ["See Alice", "Use `code`"]),
      ["See [[id:abc][Alice]]", "Use `code`"]
    )
    XCTAssertEqual(
      QuoteLineWindow.displayLines(rawText: richRaw, fallback: ["Cached fallback should not win"]),
      ["See [[id:abc][Alice]]", "Use `code`"]
    )
  }

  func testSourceBlockLineWindowLeavesSmallBlocksWhole() {
    let lines = ["one", "two", "three"]

    let collapsed = SourceBlockLineWindow.make(lines: lines, isExpanded: false, limit: 80)
    XCTAssertEqual(collapsed.visibleLines, lines)
    XCTAssertFalse(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenLineCount, 0)
  }

  func testTableRowWindowLimitsCollapsedLargeTables() {
    let rows = (1...60).map { OrgTableRow.cells(["row \($0)"]) }

    let collapsed = TableRowWindow.make(rows: rows, headerRowIndex: nil, isExpanded: false, limit: 40)
    XCTAssertEqual(collapsed.visibleRows.count, 40)
    XCTAssertEqual(collapsed.visibleRows.first?.index, 0)
    XCTAssertEqual(collapsed.visibleRows.last?.index, 39)
    XCTAssertTrue(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenRowCount, 20)

    let expanded = TableRowWindow.make(rows: rows, headerRowIndex: nil, isExpanded: true, limit: 40)
    XCTAssertEqual(expanded.visibleRows.count, 60)
    XCTAssertTrue(expanded.isTruncated)
    XCTAssertEqual(expanded.hiddenRowCount, 0)

    let partial = TableRowWindow.make(rows: rows, headerRowIndex: nil, visibleLimit: 50)
    XCTAssertEqual(partial.visibleRows.count, 50)
    XCTAssertEqual(partial.visibleRows.first?.index, 0)
    XCTAssertEqual(partial.visibleRows.last?.index, 49)
    XCTAssertTrue(partial.isTruncated)
    XCTAssertEqual(partial.hiddenRowCount, 10)
  }

  func testTableRowWindowKeepsHeaderAndSeparatorVisible() {
    let rows: [OrgTableRow] = [
      .cells(["intro"]),
      .cells(["row 2"]),
      .cells(["row 3"]),
      .cells(["Header"]),
      .separator,
      .cells(["row 6"])
    ]

    let collapsed = TableRowWindow.make(rows: rows, headerRowIndex: 3, isExpanded: false, limit: 2)
    XCTAssertEqual(collapsed.visibleRows.map(\.index), [0, 1, 3, 4])
    XCTAssertTrue(collapsed.isTruncated)
    XCTAssertEqual(collapsed.hiddenRowCount, 2)
  }

  func testTableColumnWindowLimitsWideTables() {
    let collapsed = TableColumnWindow.make(columnCount: 40, visibleLimit: 12)
    XCTAssertEqual(collapsed.visibleColumns, Array(0..<12))
    XCTAssertEqual(collapsed.hiddenColumnCount, 28)

    let partial = TableColumnWindow.make(columnCount: 40, visibleLimit: 24)
    XCTAssertEqual(partial.visibleColumns.count, 24)
    XCTAssertEqual(partial.visibleColumns.last, 23)
    XCTAssertEqual(partial.hiddenColumnCount, 16)

    let complete = TableColumnWindow.make(columnCount: 5, visibleLimit: 12)
    XCTAssertEqual(complete.visibleColumns, Array(0..<5))
    XCTAssertEqual(complete.hiddenColumnCount, 0)
  }

  func testSourceBlockRunPlanSupportsCommonLanguages() {
    XCTAssertEqual(SourceBlockRunPlan.plan(for: "sh")?.executable, "/bin/sh")
    XCTAssertEqual(SourceBlockRunPlan.plan(for: "python")?.arguments, ["python3"])
    XCTAssertEqual(SourceBlockRunPlan.plan(for: "js")?.scriptExtension, "mjs")
    XCTAssertNil(SourceBlockRunPlan.plan(for: "mermaid"))
  }

  func testRenderedEntryOnlyMarksExecutableSourceBlocksRunnable() {
    let shell = OrgEditableBlock(
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_src sh\necho hi\n#+end_src",
      rendered: .source(language: "sh", lines: ["echo hi"])
    )
    let unlabeled = OrgEditableBlock(
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_src\nplain text\n#+end_src",
      rendered: .source(language: nil, lines: ["plain text"])
    )
    let unsupported = OrgEditableBlock(
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_src mermaid\ngraph TD\n#+end_src",
      rendered: .source(language: "mermaid", lines: ["graph TD"])
    )
    let quote = OrgEditableBlock(
      startLine: 1,
      endLineExclusive: 4,
      rawText: "#+begin_quote\nplain text\n#+end_quote",
      rendered: .quote(["plain text"])
    )

    XCTAssertTrue(OrgRenderedEntryView.isRunnableSourceBlock(shell))
    XCTAssertFalse(OrgRenderedEntryView.isRunnableSourceBlock(unlabeled))
    XCTAssertFalse(OrgRenderedEntryView.isRunnableSourceBlock(unsupported))
    XCTAssertFalse(OrgRenderedEntryView.isRunnableSourceBlock(quote))
  }

  func testSourceRunOutputPresentationParsesJSONBars() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"{"A":2,"B":3.5}"#),
      .bars([
        SourceRunBar(label: "A", value: 2),
        SourceRunBar(label: "B", value: 3.5)
      ])
    )

    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"[{"name":"A","value":2},{"name":"B","value":3}]"#),
      .bars([
        SourceRunBar(label: "A", value: 2),
        SourceRunBar(label: "B", value: 3)
      ])
    )
  }

  func testSourceRunOutputPresentationCacheUsesExactOutput() {
    let raw = #"{"A":2,"B":3.5}"#
    let key = SourceRunOutputPresentationCache.CacheKey(raw: raw)
    let matching = SourceRunOutputPresentationCache.CacheKey(raw: raw)
    let different = SourceRunOutputPresentationCache.CacheKey(raw: raw + "\n")

    XCTAssertEqual(key, matching)
    XCTAssertEqual(key.hash, matching.hash)
    XCTAssertNotEqual(key, different)
    XCTAssertEqual(
      SourceRunOutputPresentationCache.presentation(from: raw),
      .bars([
        SourceRunBar(label: "A", value: 2),
        SourceRunBar(label: "B", value: 3.5)
      ])
    )
    XCTAssertEqual(
      SourceRunOutputPresentationCache.presentation(from: raw),
      SourceRunOutputPresentationCache.presentation(from: raw)
    )
    XCTAssertEqual(
      SourceRunOutputPresentationCache.presentation(from: "plain output"),
      .text("plain output")
    )
  }

  func testSourceRunOutputPresentationParsesJSONObjectsAsTable() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"[{"name":"A","status":"ready","value":2},{"name":"B","status":"done","value":3}]"#),
      .table(SourceRunTable(
        columns: ["name", "status", "value"],
        rows: [
          ["A", "ready", "2"],
          ["B", "done", "3"]
        ]
      ))
    )

    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"[{"active":true,"name":"A"},{"active":false,"name":"B"}]"#),
      .table(SourceRunTable(
        columns: ["active", "name"],
        rows: [
          ["1", "A"],
          ["0", "B"]
        ]
      ))
    )
  }

  func testSourceRunOutputPresentationParsesDelimitedTables() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: """
      Name,Value
      A,2
      B,3
      """),
      .table(SourceRunTable(
        columns: ["Name", "Value"],
        rows: [
          ["A", "2"],
          ["B", "3"]
        ]
      ))
    )

    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: "Name\tValue\nA\t2\nB\t3"),
      .table(SourceRunTable(
        columns: ["Name", "Value"],
        rows: [
          ["A", "2"],
          ["B", "3"]
        ]
      ))
    )
  }

  func testSourceRunOutputPresentationParsesLineCharts() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: """
      x,y
      1,2
      2,4
      3,8
      """),
      .line(SourceRunLineChart(
        xLabel: "x",
        yLabel: "y",
        points: [
          SourceRunLinePoint(x: 1, y: 2),
          SourceRunLinePoint(x: 2, y: 4),
          SourceRunLinePoint(x: 3, y: 8)
        ]
      ))
    )

    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: #"[{"x":1,"y":2},{"x":2,"y":4}]"#),
      .line(SourceRunLineChart(
        xLabel: "x",
        yLabel: "y",
        points: [
          SourceRunLinePoint(x: 1, y: 2),
          SourceRunLinePoint(x: 2, y: 4)
        ]
      ))
    )
  }

  func testSourceRunOutputPresentationParsesPipeTable() {
    XCTAssertEqual(
      SourceRunOutputPresentation.make(from: """
      | Name | Value |
      |------+-------|
      | A    | 2     |
      | B    | 3     |
      """),
      .table(SourceRunTable(
        columns: ["Name", "Value"],
        rows: [
          ["A", "2"],
          ["B", "3"]
        ]
      ))
    )
  }

  func testExecutesSourceBlockAndCapturesOutput() throws {
    let source = OrgEditableSourceBlock(rawText: """
    #+begin_src sh
    printf hello
    #+end_src
    """)
    let plan = try XCTUnwrap(SourceBlockRunPlan.plan(for: source.language))
    let result = try WorkspaceStore.executeSourceBlock(
      source,
      plan: plan,
      workingDirectory: FileManager.default.temporaryDirectory,
      timeout: 2
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "hello")
    XCTAssertEqual(result.stderr, "")
    XCTAssertFalse(result.timedOut)
  }

  @MainActor
  func testRunsEditedSourceBlockDraftWithoutSavingFirst() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-source-draft-run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("source-draft.org2")
    try """
    #+TITLE: Source Draft

    * Code
    #+begin_src sh
    printf saved
    #+end_src
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": null,
      "headline": "Code",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let sourceBlock = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .source = $0.rendered { return true }
      return false
    })

    await store.runSourceBlock(sourceBlock, rawText: """
    #+begin_src sh
    printf draft
    #+end_src
    """)

    try await waitForCondition {
      store.sourceBlockRunState(for: sourceBlock)?.stdout == "draft"
    }
    XCTAssertEqual(store.sourceBlockRunState(for: sourceBlock)?.status, .succeeded)

    let saved = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(saved.contains("printf saved"))
    XCTAssertFalse(saved.contains("printf draft"))
  }

  @MainActor
  func testAutosavesSourceBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-source-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("source-autosave.org2")
    try """
    #+TITLE: Source Autosave

    * Code
    #+begin_src sh
    printf old
    #+end_src
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": null,
      "headline": "Code",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedSurface = .agenda
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let sourceBlock = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .source = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(sourceBlock)
    let replacement = """
    #+begin_src python :results output
    print("new")
    print("line two")
    #+end_src
    """
    store.updateEditingBlockDraft(sourceBlock, draft: replacement)
    await store.autosaveEditedBlock(sourceBlock, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("print(\"new\")\nprint(\"line two\")\n#+end_src\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertEqual(store.editableBlockText, replacement)
    XCTAssertNotNil(store.editingBlockID)
    guard case .source(let language, let lines) = store.selectedBlock?.rendered else {
      return XCTFail("Expected source block")
    }
    XCTAssertEqual(language, "python")
    XCTAssertEqual(lines, ["print(\"new\")", "print(\"line two\")"])
  }

  func testParsesEditableOrgBlocksWithSourceRanges() {
    let blocks = OrgEntryRenderer.parseEditable("""
    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    -----
    Body one
    Body two
    #+begin_src swift
    let value = 1
    #+end_src
    """, baseLine: 42)

    XCTAssertEqual(blocks.map(\.displayRange), ["42", "43", "44-46", "47", "48-49", "50-52"])
    XCTAssertEqual(blocks.map(\.rawText), [
      "* TODO Parent",
      "SCHEDULED: <2026-06-12 Fri>",
      "| Name | Value |\n|------+-------|\n| Alice | 42 |",
      "-----",
      "Body one\nBody two",
      "#+begin_src swift\nlet value = 1\n#+end_src"
    ])

    guard case .table(let table) = blocks[2].rendered else {
      return XCTFail("Expected table")
    }
    XCTAssertEqual(table.rows, [
      .cells(["Name", "Value"]),
      .separator,
      .cells(["Alice", "42"])
    ])

    guard case .horizontalRule = blocks[3].rendered else {
      return XCTFail("Expected horizontal rule")
    }

    guard case .paragraph(let paragraph) = blocks[4].rendered else {
      return XCTFail("Expected paragraph")
    }
    XCTAssertEqual(paragraph, "Body one\nBody two")
  }

  func testEditableParagraphPreservesRawInlineMarkupForEditing() {
    let blocks = OrgEntryRenderer.parseEditable("""
    Body with [[id:11111111-1111-4111-8111-111111111111][Alice]] and ~code~.
    Second /line/.
    """, baseLine: 12)

    XCTAssertEqual(blocks.count, 1)
    XCTAssertEqual(blocks[0].displayRange, "12-13")
    XCTAssertEqual(blocks[0].rawText, """
    Body with [[id:11111111-1111-4111-8111-111111111111][Alice]] and ~code~.
    Second /line/.
    """)

    guard case .paragraph(let paragraph) = blocks[0].rendered else {
      return XCTFail("Expected paragraph")
    }
    XCTAssertEqual(paragraph, "Body with Alice and ~code~.\nSecond /line/.")
  }

  func testOrgMediaAttachmentDetectsStandaloneLocalMediaLinks() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-media-\(UUID().uuidString)", isDirectory: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

    let image = assets.appendingPathComponent("diagram.png")
    let video = notes.appendingPathComponent("clip.mov")
    let note = notes.appendingPathComponent("daily.org2")
    try Data().write(to: image)
    try Data().write(to: video)
    try Data().write(to: note)

    XCTAssertFalse(OrgMediaAttachment.mayContainStandaloneMedia("Plain paragraph with no media link."))
    XCTAssertFalse(OrgMediaAttachment.mayContainStandaloneMedia("See [[file:../assets/diagram.png][System Diagram]]"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("https://example.com/image.png"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("[[file:../assets/diagram.png][System Diagram]]"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("[[https://example.com/image.png][Remote Image]]"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("https://youtu.be/dQw4w9WgXcQ"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("[Clip](clip.mov)"))
    XCTAssertTrue(OrgMediaAttachment.mayContainStandaloneMedia("assets/diagram.png"))
    XCTAssertFalse(OrgMediaAttachment.mayContainMediaTarget("A long ordinary paragraph with punctuation."))
    XCTAssertTrue(OrgMediaAttachment.mayContainMediaTarget("See IMAGE.JPEG for the latest diagram"))
    XCTAssertTrue(OrgMediaAttachment.mayContainMediaTarget("Watch https://YOUTU.BE/example"))

    let bracket = try XCTUnwrap(OrgMediaAttachment.standalone(
      raw: "[[file:../assets/diagram.png][System Diagram]]",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(bracket.kind, .image)
    XCTAssertEqual(bracket.displayName, "System Diagram")
    XCTAssertEqual(bracket.resolvedPath, image.standardizedFileURL.path)

    let markdown = try XCTUnwrap(OrgMediaAttachment.standalone(
      raw: "[Clip](clip.mov)",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(markdown.kind, .video)
    XCTAssertEqual(markdown.displayName, "Clip")
    XCTAssertEqual(markdown.resolvedPath, video.standardizedFileURL.path)

    XCTAssertNil(OrgMediaAttachment.standalone(
      raw: "See [[file:../assets/diagram.png][System Diagram]]",
      sourceFile: note.path,
      corpusRoot: root
    ))

    let embedded = try XCTUnwrap(OrgMediaAttachment.embedded(
      in: "inline images [[file:../assets/diagram.png][Image]]",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(embedded.displayText, "inline images")
    XCTAssertEqual(embedded.attachments.count, 1)
    XCTAssertEqual(embedded.attachments[0].kind, .image)
    XCTAssertEqual(embedded.attachments[0].displayName, "Image")
    XCTAssertEqual(embedded.attachments[0].resolvedPath, image.standardizedFileURL.path)

    XCTAssertNil(OrgMediaAttachment.embedded(
      in: "Not media [[id:11111111-1111-4111-8111-111111111111][Node]]",
      sourceFile: note.path,
      corpusRoot: root
    ))

    let remoteImage = try XCTUnwrap(OrgMediaAttachment.standalone(raw: "https://example.com/image.png"))
    XCTAssertEqual(remoteImage.kind, .image)
    XCTAssertEqual(remoteImage.target, "https://example.com/image.png")
    XCTAssertEqual(remoteImage.resolvedPath, nil)
    XCTAssertEqual(remoteImage.resolvedURL?.absoluteString, "https://example.com/image.png")

    let remoteVideoPage = try XCTUnwrap(OrgMediaAttachment.standalone(raw: "https://youtu.be/dQw4w9WgXcQ"))
    XCTAssertEqual(remoteVideoPage.kind, .video)
    XCTAssertEqual(remoteVideoPage.resolvedURL?.absoluteString, "https://youtu.be/dQw4w9WgXcQ")
  }

  func testRenderedInlineMediaPresentationUsesRawParagraphAndListText() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-inline-media-render-\(UUID().uuidString)", isDirectory: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let image = assets.appendingPathComponent("diagram.png")
    let note = root.appendingPathComponent("note.org2")
    try Data().write(to: image)
    try Data().write(to: note)

    let paragraphBlock = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "inline images [[file:assets/diagram.png][Image]]"
    ).first)
    let paragraphEmbedded = try XCTUnwrap(RenderedInlineMediaPresentation.embedded(
      raw: paragraphBlock.rawText,
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(paragraphEmbedded.displayText, "inline images")
    XCTAssertEqual(paragraphEmbedded.attachments.first?.resolvedPath, image.standardizedFileURL.path)

    let headingBlock = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "** inline images [[file:assets/diagram.png][Image]]"
    ).first)
    guard case .heading(let heading) = headingBlock.rendered else {
      return XCTFail("Expected heading")
    }
    let rawHeadingTitle = OrgRenderedLineDisplayCache.headingTitle(
      rawText: headingBlock.rawText,
      fallback: heading.title
    )
    let headingEmbedded = try XCTUnwrap(RenderedInlineMediaPresentation.headingTitle(
      rawTitle: rawHeadingTitle,
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(headingEmbedded.displayText, "inline images")
    XCTAssertEqual(headingEmbedded.attachments.first?.displayName, "Image")
    XCTAssertEqual(headingEmbedded.attachments.first?.resolvedPath, image.standardizedFileURL.path)

    let remoteHeadingEmbedded = try XCTUnwrap(RenderedInlineMediaPresentation.headingTitle(
      rawTitle: "inline images [[https://raw.githubusercontent.com/aviaviavi/org2/refs/heads/main/site/assets/favicon.png][Image]]",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(remoteHeadingEmbedded.displayText, "inline images")
    XCTAssertEqual(remoteHeadingEmbedded.attachments.first?.kind, .image)
    XCTAssertEqual(remoteHeadingEmbedded.attachments.first?.displayName, "Image")
    XCTAssertEqual(
      remoteHeadingEmbedded.attachments.first?.resolvedURL?.absoluteString,
      "https://raw.githubusercontent.com/aviaviavi/org2/refs/heads/main/site/assets/favicon.png"
    )

    let listBlock = try XCTUnwrap(OrgEntryRenderer.parseEditable(
      "- inline images [[file:assets/diagram.png][Image]]"
    ).first)
    guard case .listItem(_, _, _, let renderedText) = listBlock.rendered else {
      return XCTFail("Expected list item")
    }
    let rawListText = OrgRenderedLineDisplayCache.listText(rawText: listBlock.rawText, fallback: renderedText)
    let listEmbedded = try XCTUnwrap(RenderedInlineMediaPresentation.embedded(
      raw: rawListText,
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(listEmbedded.displayText, "inline images")
    XCTAssertEqual(listEmbedded.attachments.first?.resolvedPath, image.standardizedFileURL.path)
  }

  func testParagraphEditorInlineMediaPreviewUsesLiveDraftText() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-inline-media-editor-\(UUID().uuidString)", isDirectory: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let image = assets.appendingPathComponent("diagram.png")
    let note = root.appendingPathComponent("note.org2")
    try Data().write(to: image)
    try Data().write(to: note)

    let preview = try XCTUnwrap(ParagraphEditorInlineMediaPreview.embedded(
      raw: "inline images [[file:assets/diagram.png][Image]]",
      sourceFile: note.path,
      corpusRoot: root
    ))
    XCTAssertEqual(preview.displayText, "inline images")
    XCTAssertEqual(preview.attachments.first?.resolvedPath, image.standardizedFileURL.path)
    XCTAssertNil(ParagraphEditorInlineMediaPreview.embedded(
      raw: "inline images Image",
      sourceFile: note.path,
      corpusRoot: root
    ))
  }

  func testOrgCryptFindsPlaintextCryptSubtreesAndProperties() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let key = root.appendingPathComponent("keys/agent.asc")
    try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)

    let text = """
    * Public
    Body
    * Secret :crypt:
    :PROPERTIES:
    :CRYPT_RECIPIENTS: user@example.com, agent@example.com
    :CRYPT_RECIPIENT_FILE: keys/agent.asc
    :END:
    plaintext
    ** Child
    more
    * Already encrypted :crypt:
    -----BEGIN PGP MESSAGE-----
    abc
    -----END PGP MESSAGE-----
    """

    let targets = OrgCrypt.findPlaintextCryptSubtrees(in: text, file: note.path)

    XCTAssertEqual(targets.count, 1)
    XCTAssertEqual(targets[0].headingLine, 3)
    XCTAssertEqual(targets[0].bodyStartLine, 7)
    XCTAssertEqual(targets[0].endLine, 10)
    XCTAssertEqual(targets[0].recipients, ["user@example.com", "agent@example.com"])
    XCTAssertEqual(targets[0].recipientFiles, [key.standardizedFileURL.path])
  }

  func testOrgCryptArmorSummaryDetectsPGPBlocks() {
    let raw = """
    -----BEGIN PGP MESSAGE-----
    abc
    def
    -----END PGP MESSAGE-----
    """

    let summary = OrgCrypt.armorSummary(raw)

    XCTAssertEqual(summary?.lineCount, 4)
    XCTAssertEqual(summary?.payloadLineCount, 2)
    XCTAssertEqual(summary?.byteCount, Data(raw.utf8).count)
    XCTAssertNil(OrgCrypt.armorSummary("not encrypted"))
  }

  func testEncryptedRenderedBlockTargetsOwningHeadingAndDoesNotSingleClickEdit() {
    let heading = OrgEditableBlock(
      id: "heading",
      startLine: 10,
      endLineExclusive: 11,
      rawText: "* Secret :crypt:",
      rendered: .heading(OrgHeadingBlock(level: 1, todo: nil, priority: nil, title: "Secret", tags: ["crypt"]))
    )
    let armorRaw = """
    -----BEGIN PGP MESSAGE-----
    abc
    -----END PGP MESSAGE-----
    """
    let armor = OrgEditableBlock(
      id: "armor",
      startLine: 11,
      endLineExclusive: 14,
      rawText: armorRaw,
      rendered: .paragraph(armorRaw)
    )

    XCTAssertEqual(OrgRenderedCryptTarget.headingLine(for: armor, in: [heading, armor]), 10)
    XCTAssertFalse(RenderedBlockEditingPolicy.startsEditingOnSingleClick(block: armor, isSourceEditable: true))
    XCTAssertFalse(RenderedBlockInteractionPolicy.usesRowTapGestures(block: armor, isSourceEditable: true))
    XCTAssertFalse(RenderedBlockInteractionPolicy.showsRowChrome(for: armor))
  }

  func testOrgCryptEncryptionTimesOutNonInteractiveGPG() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-timeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    sleep 5
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)

    let text = """
    * Secret :crypt:
    plaintext
    """
    let settings = OrgCryptSettings(
      recipients: ["person@example.com"],
      gpgProgram: fakeGPG.path,
      gpgTimeout: 0.2
    )

    XCTAssertThrowsError(try OrgCrypt.encryptPlaintextCryptSubtrees(in: text, file: note.path, settings: settings)) { error in
      guard case OrgCryptError.gpgTimedOut = error else {
        return XCTFail("Expected gpg timeout, got \(error)")
      }
    }
  }

  func testOrgCryptUsesDefaultGPGKeyRecipientWhenConfigured() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-default-key-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let argsLog = root.appendingPathComponent("gpg-args.txt")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    let fakeGPGConf = root.appendingPathComponent("gpgconf")
    try """
    #!/bin/sh
    printf '%s\\n' "$@" > "\(argsLog.path)"
    cat >/dev/null
    printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'fake encrypted payload' '-----END PGP MESSAGE-----'
    exit 0
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try """
    #!/bin/sh
    printf '%s\\n' 'default-key:0:0:use NAME as default secret key:1:1:NAME:::"self-key'
    exit 0
    """.write(to: fakeGPGConf, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPGConf.path)

    let text = """
    * Secret :crypt:
    plaintext
    """
    let settings = OrgCryptSettings(
      gpgProgram: fakeGPG.path,
      gpgTimeout: 2,
      useDefaultGpgKey: true
    )

    let result = try OrgCrypt.encryptPlaintextCryptSubtrees(in: text, file: note.path, settings: settings)

    XCTAssertEqual(result.encryptedCount, 1)
    XCTAssertTrue(result.text.contains("fake encrypted payload"))
    let args = try String(contentsOf: argsLog, encoding: .utf8)
    XCTAssertTrue(args.contains("--encrypt\n"))
    XCTAssertTrue(args.contains("--recipient\nself-key\n"))
    XCTAssertFalse(args.contains("--default-recipient-self\n"))
  }

  func testOrgCryptUsesExplicitRecipientWhenDefaultGPGKeyIsUnavailable() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-explicit-recipient-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let argsLog = root.appendingPathComponent("gpg-args.txt")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    printf '%s\\n' "$@" > "\(argsLog.path)"
    cat >/dev/null
    printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'fake encrypted payload' '-----END PGP MESSAGE-----'
    exit 0
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)

    let text = """
    * Secret :crypt:
    plaintext
    """
    let settings = OrgCryptSettings(
      recipients: ["person@example.com"],
      gpgProgram: fakeGPG.path,
      gpgTimeout: 2,
      useDefaultGpgKey: true
    )

    let result = try OrgCrypt.encryptPlaintextCryptSubtrees(in: text, file: note.path, settings: settings)

    XCTAssertEqual(result.encryptedCount, 1)
    XCTAssertTrue(result.text.contains("fake encrypted payload"))
    let args = try String(contentsOf: argsLog, encoding: .utf8)
    XCTAssertTrue(args.contains("--encrypt\n"))
    XCTAssertTrue(args.contains("--recipient\nperson@example.com\n"))
    XCTAssertFalse(args.contains("--recipient\nself-key\n"))
  }

  func testCanonicalEditableRenderCoalescesSplitPGPArmorBlocks() throws {
    let raw = """
    * Secret :crypt:
    -----BEGIN PGP MESSAGE-----
    abc
    -----END PGP MESSAGE-----
    """
    let json = """
    {
      "type": "Document",
      "version": "test",
      "children": [
        {
          "type": "Headline",
          "level": 1,
          "todo": null,
          "tags": ["crypt"],
          "title": [{ "type": "Text", "value": "Secret" }],
          "sourceRange": { "startLine": 1, "endLine": 1 },
          "children": [
            {
              "type": "Paragraph",
              "children": [{ "type": "Text", "value": "-----BEGIN PGP MESSAGE-----" }],
              "sourceRange": { "startLine": 2, "endLine": 2 }
            },
            {
              "type": "Paragraph",
              "children": [{ "type": "Text", "value": "abc" }],
              "sourceRange": { "startLine": 3, "endLine": 3 }
            },
            {
              "type": "Paragraph",
              "children": [{ "type": "Text", "value": "-----END PGP MESSAGE-----" }],
              "sourceRange": { "startLine": 4, "endLine": 4 }
            }
          ]
        }
      ]
    }
    """
    let document = try JSONDecoder().decode(Org2CanonicalDocument.self, from: Data(json.utf8))

    let blocks = OrgEntryRenderer.parseEditable(raw, canonicalDocument: document)

    let encrypted = blocks.filter { OrgCrypt.armorSummary($0.rawText) != nil }
    XCTAssertEqual(encrypted.count, 1)
    XCTAssertEqual(encrypted.first?.startLine, 2)
    XCTAssertEqual(encrypted.first?.endLineExclusive, 5)
  }

  @MainActor
  func testRunOrgCryptDecryptRewritesSelectedFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-decrypt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    if printf '%s\\n' "$@" | grep -q -- '--decrypt'; then
      cat >/dev/null
      printf '%s\\n' 'plaintext'
      exit 0
    fi
    printf '%s\\n' 'unexpected gpg action' >&2
    exit 2
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    try """
    * Secret :crypt:
    -----BEGIN PGP MESSAGE-----
    fake encrypted payload
    -----END PGP MESSAGE-----
    * Public
    body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))

    let result = await store.runOrgCrypt(.decrypt, line: 1)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(result.succeeded)
    XCTAssertTrue(result.changed)
    XCTAssertEqual(result.headingLine, 1)
    XCTAssertTrue(updated.contains("* Secret :crypt:\nplaintext"))
    XCTAssertFalse(updated.contains("-----BEGIN PGP MESSAGE-----"))
    XCTAssertTrue(updated.contains("* Public\nbody"))
  }

  @MainActor
  func testRunOrgCryptDecryptReturnsGPGFailureMessage() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-decrypt-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' 'gpg: decryption failed: No secret key' >&2
    exit 2
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    let original = """
    * Secret :crypt:
    -----BEGIN PGP MESSAGE-----
    fake encrypted payload
    -----END PGP MESSAGE-----
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))

    let result = await store.runOrgCrypt(.decrypt, line: 1)

    XCTAssertFalse(result.succeeded)
    XCTAssertFalse(result.changed)
    XCTAssertTrue(result.message.contains("No secret key"))
    XCTAssertEqual(store.statusText, result.message)
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), original)
  }

  @MainActor
  func testSaveCurrentFileEncryptsPlaintextCryptSubtreesWithoutActiveEdit() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-save-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'fake encrypted payload' '-----END PGP MESSAGE-----'
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    try """
    * Secret :crypt:
    plaintext
    * Public
    body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptRecipientsText = "person@example.com"
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected file")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    XCTAssertFalse(store.hasActiveEdit)
    XCTAssertTrue(store.canSaveCurrentFile)

    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* Secret :crypt:\n-----BEGIN PGP MESSAGE-----"))
    XCTAssertTrue(updated.contains("fake encrypted payload"))
    XCTAssertFalse(updated.contains("* Secret :crypt:\nplaintext"))
    XCTAssertTrue(updated.contains("* Public\nbody"))
    XCTAssertEqual(store.statusText, "Encrypted 1 subtree")
  }

  @MainActor
  func testSaveCurrentFileEncryptsMultipleCryptSubtreesIncludingFinalBlock() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-save-multiple-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    input=$(cat)
    if printf '%s' "$input" | grep -q 'first secret'; then
      printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'encrypted alpha payload' '-----END PGP MESSAGE-----'
    else
      printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'encrypted beta payload' '-----END PGP MESSAGE-----'
    fi
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    let original = """
    * First :crypt:
    first secret
    * Public
    body
    * Second :crypt:
    second secret
    """ + "\n"
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptRecipientsText = "person@example.com"
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected file")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* First :crypt:\n-----BEGIN PGP MESSAGE-----\nencrypted alpha payload\n-----END PGP MESSAGE-----"))
    XCTAssertTrue(updated.contains("* Public\nbody"))
    XCTAssertTrue(updated.contains("* Second :crypt:\n-----BEGIN PGP MESSAGE-----\nencrypted beta payload\n-----END PGP MESSAGE-----\n"))
    XCTAssertFalse(updated.contains("first secret"))
    XCTAssertFalse(updated.contains("second secret"))
    XCTAssertTrue(updated.hasSuffix("\n"))
    XCTAssertEqual(store.statusText, "Encrypted 2 subtrees")
  }

  @MainActor
  func testAddingCryptTagToHeadingEncryptsSubtreeOnSave() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-crypt-heading-tag-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    let fakeGPG = root.appendingPathComponent("fake-gpg.sh")
    try """
    #!/bin/sh
    cat >/dev/null
    printf '%s\\n' '-----BEGIN PGP MESSAGE-----' 'fake encrypted payload' '-----END PGP MESSAGE-----'
    """.write(to: fakeGPG, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGPG.path)
    try """
    * Secret
    plaintext
    * Public
    body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptRecipientsText = "person@example.com"
    store.orgCryptGpgProgram = fakeGPG.path
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected file")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Secret"
      }
      return false
    })
    await store.setHeadingTags(heading, tags: ["crypt"])

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* Secret :crypt:\n-----BEGIN PGP MESSAGE-----"))
    XCTAssertTrue(updated.contains("fake encrypted payload"))
    XCTAssertFalse(updated.contains("* Secret :crypt:\nplaintext"))
    XCTAssertTrue(updated.contains("* Public\nbody"))
    XCTAssertEqual(store.statusText, "Saved and encrypted 1 subtree")
  }

  func testOrgMediaAttachmentRenderCacheUsesExactSourceContext() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-media-cache-\(UUID().uuidString)", isDirectory: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    let notes = root.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

    let image = assets.appendingPathComponent("diagram.png")
    let note = notes.appendingPathComponent("daily.org2")
    try Data().write(to: image)
    try Data().write(to: note)

    let raw = "[[file:../assets/diagram.png][System Diagram]]"
    let key = OrgMediaAttachmentRenderCache.CacheKey(raw: raw, sourceFile: note.path, corpusRoot: root)
    let matching = OrgMediaAttachmentRenderCache.CacheKey(raw: raw, sourceFile: note.path, corpusRoot: root)
    let differentSource = OrgMediaAttachmentRenderCache.CacheKey(raw: raw, sourceFile: image.path, corpusRoot: root)

    XCTAssertEqual(key, matching)
    XCTAssertEqual(key.hash, matching.hash)
    XCTAssertNotEqual(key, differentSource)

    XCTAssertFalse(OrgMediaAttachmentRenderCache.shouldAttemptStandaloneLookup(raw: "Plain paragraph"))
    XCTAssertFalse(OrgMediaAttachmentRenderCache.shouldAttemptStandaloneLookup(
      raw: "See [[file:../assets/diagram.png][System Diagram]]"
    ))
    XCTAssertTrue(OrgMediaAttachmentRenderCache.shouldAttemptStandaloneLookup(
      raw: "https://example.com/image.png"
    ))
    XCTAssertTrue(OrgMediaAttachmentRenderCache.shouldAttemptStandaloneLookup(raw: raw))

    let first = try XCTUnwrap(OrgMediaAttachmentRenderCache.standalone(raw: raw, sourceFile: note.path, corpusRoot: root))
    let second = try XCTUnwrap(OrgMediaAttachmentRenderCache.standalone(raw: raw, sourceFile: note.path, corpusRoot: root))
    XCTAssertEqual(first, second)
    XCTAssertEqual(second.resolvedPath, image.standardizedFileURL.path)

    XCTAssertNil(OrgMediaAttachmentRenderCache.standalone(raw: "Plain paragraph", sourceFile: note.path, corpusRoot: root))
    XCTAssertNil(OrgMediaAttachmentRenderCache.standalone(raw: "Plain paragraph", sourceFile: note.path, corpusRoot: root))
  }

  func testEditableMediaLinkFormatsOrgBracketLinks() throws {
    XCTAssertEqual(
      OrgEditableMediaLink(kind: .image, target: "images/diagram.png", label: "System Diagram").formattedRawText,
      "[[file:images/diagram.png][System Diagram]]"
    )

    XCTAssertEqual(
      OrgEditableMediaLink(kind: .video, target: "file:clips/demo.mp4").formattedRawText,
      "[[file:clips/demo.mp4][demo.mp4]]"
    )

    let markdown = try XCTUnwrap(OrgEditableMediaLink(rawText: "[Clip](clip.mov)"))
    XCTAssertEqual(markdown.kind, .video)
    XCTAssertEqual(markdown.target, "clip.mov")
    XCTAssertEqual(markdown.label, "Clip")
    XCTAssertEqual(markdown.formattedRawText, "[[file:clip.mov][Clip]]")

    let bracket = try XCTUnwrap(OrgEditableMediaLink(rawText: "[[file:../assets/diagram.png][Diagram]]"))
    XCTAssertEqual(bracket.kind, .image)
    XCTAssertEqual(bracket.target, "file:../assets/diagram.png")
    XCTAssertEqual(bracket.label, "Diagram")
    XCTAssertEqual(bracket.formattedRawText, "[[file:../assets/diagram.png][Diagram]]")

    let remote = try XCTUnwrap(OrgEditableMediaLink(rawText: "[[https://example.com/diagram.png][Diagram]]"))
    XCTAssertEqual(remote.kind, .image)
    XCTAssertEqual(remote.target, "https://example.com/diagram.png")
    XCTAssertEqual(remote.formattedRawText, "[[https://example.com/diagram.png][Diagram]]")

    XCTAssertEqual(
      OrgEditableMediaLink(kind: .image, target: "file:https://example.com/diagram.png", label: "Diagram").formattedRawText,
      "[[https://example.com/diagram.png][Diagram]]"
    )
  }

  func testMediaAttachmentInfersKindFromTargets() {
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "images/diagram.webp"), .image)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "https://example.com/diagram.webp?raw=1"), .image)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "file:clips/demo.webm"), .video)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "https://example.com/demo.mp4"), .video)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .video)
    XCTAssertEqual(OrgMediaAttachment.kind(forTarget: "/tmp/movie.MP4#clip"), .video)
    XCTAssertNil(OrgMediaAttachment.kind(forTarget: "notes/project.org2"))
  }

  func testRenderedMediaDoesNotAutoloadVideoPlayers() {
    XCTAssertFalse(RenderedMediaPreviewPolicy.autoloadsVideoPlayerOnAppear)
  }

  @MainActor
  func testAgentHandoffShortcutAssignsTempNoteWithoutChangingTodoState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-agent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agent.org2")
    try """
    #+TITLE: Agent Test

    * TODO Send to agent
    SCHEDULED: <2026-06-12 Fri>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Send to agent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let profile = try JSONDecoder().decode(AgentProfileItem.self, from: Data(#"""
    {
      "schema": "org2:agent-profile:v1",
      "id": "product-research",
      "name": "Product Research",
      "description": "Researches product questions",
      "status": "active",
      "responsibilities": [],
      "capabilities": [],
      "skills": [],
      "runtimeBindings": [],
      "goalRefs": ["product-quality"],
      "primaryGoalRef": "product-quality",
      "file": "/tmp/product-research.org2",
      "createdAt": "2026-06-12T00:00:00.000Z",
      "updatedAt": "2026-06-12T00:00:00.000Z"
    }
    """#.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.applyAgentHandoffShortcut(agentProfile: profile)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Send to agent"))
    XCTAssertFalse(updated.contains("* DONE Send to agent"))
    XCTAssertTrue(updated.contains(":ASSIGNEE: Product Research"))
    XCTAssertTrue(updated.contains(":AGENT_REF: product-research"))
    XCTAssertTrue(updated.contains(":GOAL_REF: product-quality"))
    XCTAssertTrue(updated.contains(":STATUS: ready"))
    XCTAssertTrue(updated.contains(":ASSIGNED_AT: <"))
  }

  @MainActor
  func testApproveAndAgentHandoffCompletesApprovalAndCreatesSendTodo() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approve-handoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("approve-handoff.org2")
    try """
    * TODO Approve reply to Maya / Oracle supplier onboarding details
    SCHEDULED: <2026-06-16 Tue>
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: draft-needs-review
    :END:

    Draft body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Approve reply to Maya / Oracle supplier onboarding details",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Draft body",
      "level": 1,
      "tags": [],
      "properties": {
        "ASSIGNEE": "Avi",
        "STATUS": "draft-needs-review"
      }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))

    await store.applyApproveAndAgentHandoffShortcut()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* DONE Approve reply to Maya / Oracle supplier onboarding details"))
    XCTAssertTrue(updated.contains(":STATUS: approved"))
    XCTAssertTrue(updated.contains(":APPROVED_AT: <"))
    XCTAssertTrue(updated.contains(":PAIRED_SEND_TODO: Send approved reply to Maya / Oracle supplier onboarding details"))
    XCTAssertTrue(updated.contains("* TODO Send approved reply to Maya / Oracle supplier onboarding details"))
    XCTAssertTrue(updated.contains(":ASSIGNEE: OpenClaw"))
    XCTAssertTrue(updated.contains(":STATUS: approved-to-send"))
    XCTAssertTrue(updated.contains(":APPROVAL_TODO: Approve reply to Maya / Oracle supplier onboarding details"))
  }

  @MainActor
  func testApproveAndAgentHandoffActivatesExistingPairedSendTodo() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approve-existing-handoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("approve-existing-handoff.org2")
    try """
    * TODO Approve reply to Maya / Oracle supplier onboarding details
    SCHEDULED: <2026-06-16 Tue>
    :PROPERTIES:
    :ASSIGNEE: Avi
    :PAIRED_SEND_TODO: Send approved reply to Maya / Oracle supplier onboarding details
    :STATUS: draft-needs-review
    :END:

    Draft body

    * TODO Send approved reply to Maya / Oracle supplier onboarding details
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: blocked
    :END:
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Approve reply to Maya / Oracle supplier onboarding details",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Draft body",
      "level": 1,
      "tags": [],
      "properties": {
        "ASSIGNEE": "Avi",
        "PAIRED_SEND_TODO": "Send approved reply to Maya / Oracle supplier onboarding details",
        "STATUS": "draft-needs-review"
      }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))

    await store.applyApproveAndAgentHandoffShortcut()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* DONE Approve reply to Maya / Oracle supplier onboarding details"))
    XCTAssertEqual(
      updated.components(separatedBy: "* TODO Send approved reply to Maya / Oracle supplier onboarding details").count - 1,
      1
    )
    XCTAssertTrue(updated.contains(":ASSIGNEE: OpenClaw"))
    XCTAssertTrue(updated.contains(":STATUS: approved-to-send"))
    XCTAssertTrue(updated.contains(":APPROVAL_TODO: Approve reply to Maya / Oracle supplier onboarding details"))
  }

  @MainActor
  func testRejectApprovalRecordsEndStatusAndReason() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-reject-approval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("reject-approval.org2")
    try """
    * TODO Approve reply to Maya / Oracle supplier onboarding details
    SCHEDULED: <2026-06-16 Tue>
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: draft-needs-review
    :END:

    Draft body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Approve reply to Maya / Oracle supplier onboarding details",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Draft body",
      "level": 1,
      "tags": [],
      "properties": {
        "ASSIGNEE": "Avi",
        "STATUS": "draft-needs-review"
      }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))

    await store.applyRejectApprovalShortcut(endStatus: .canceled, reason: "Not the right reply\nneeds a rewrite")

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* CANCELED Approve reply to Maya / Oracle supplier onboarding details"))
    XCTAssertTrue(updated.contains(":STATUS: rejected"))
    XCTAssertTrue(updated.contains(":REJECTED_AT: <"))
    XCTAssertTrue(updated.contains(":REJECTION_END_STATUS: CANCELED"))
    XCTAssertTrue(updated.contains(":REJECTION_REASON: Not the right reply needs a rewrite"))
  }

  func testApprovalRejectionReasonRequiresNonWhitespaceText() {
    XCTAssertNil(WorkspaceStore.normalizedApprovalRejectionReason(""))
    XCTAssertNil(WorkspaceStore.normalizedApprovalRejectionReason(" \n\t "))
    XCTAssertEqual(
      WorkspaceStore.normalizedApprovalRejectionReason("  Needs a rewrite\n"),
      "Needs a rewrite"
    )
  }

  @MainActor
  func testRejectApprovalItemUsesStableIDWhenLinePointsAtParent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-reject-approval-stale-line-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("reject-approval-stale-line.org2")
    try """
    * TODO Parent wrapper
    :PROPERTIES:
    :ID: parent-id
    :STATUS: waiting
    :END:

    ** TODO Approve reply to Sergio Sastre Florez badge/download count mismatch
    :PROPERTIES:
    :ID: approval-child-id
    :STATUS: draft-needs-review
    :ASSIGNEE: Avi
    :END:

    Draft body
    """.write(to: note, atomically: true, encoding: .utf8)

    let staleLineItem = ApprovalItem(
      title: "Approve reply to Sergio Sastre Florez badge/download count mismatch",
      status: "draft-needs-review",
      todo: "TODO",
      level: 2,
      file: note.path,
      line: 1,
      idValue: "approval-child-id",
      properties: [
        "ID": "approval-child-id",
        "STATUS": "draft-needs-review",
        "ASSIGNEE": "Avi"
      ],
      body: "Draft body",
      tags: []
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    await store.rejectApproval(staleLineItem, endStatus: .done, reason: "already responded")

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* TODO Parent wrapper"))
    XCTAssertFalse(updated.contains("* DONE Parent wrapper"))
    XCTAssertTrue(updated.contains("** DONE Approve reply to Sergio Sastre Florez badge/download count mismatch"))
    XCTAssertTrue(updated.contains(":STATUS: rejected"))
    XCTAssertTrue(updated.contains(":REJECTION_END_STATUS: DONE"))
    XCTAssertTrue(updated.contains(":REJECTION_REASON: already responded"))
  }

  @MainActor
  func testRejectionReasonAndDoneElsewhereNoteAreOptional() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-optional-approval-notes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("optional-approval-notes.org2")
    try """
    * TODO Approve reply to Maya
    :PROPERTIES:
    :ID: reject-without-reason
    :STATUS: draft-needs-review
    :END:

    * TODO Approve follow-up to Lee
    :PROPERTIES:
    :ID: done-elsewhere-without-note
    :STATUS: draft-needs-review
    :END:
    """.write(to: note, atomically: true, encoding: .utf8)

    func approval(_ id: String, title: String, line: Int) -> ApprovalItem {
      ApprovalItem(
        title: title,
        status: "draft-needs-review",
        todo: "TODO",
        level: 1,
        file: note.path,
        line: line,
        idValue: id,
        properties: ["ID": id, "STATUS": "draft-needs-review"],
        body: "",
        tags: []
      )
    }
    let rejected = approval("reject-without-reason", title: "Approve reply to Maya", line: 1)
    let completed = approval("done-elsewhere-without-note", title: "Approve follow-up to Lee", line: 7)
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.replaceApprovalItemsForTesting([rejected, completed])
    store.todoStatusMutationForTesting = { status, file, line in
      let fileURL = URL(fileURLWithPath: file)
      var lines = try String(contentsOf: fileURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      lines[line - 1] = lines[line - 1].replacingOccurrences(of: " TODO ", with: " \(status.label) ")
      try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
      return status.label
    }

    await store.rejectApproval(rejected, endStatus: .canceled, reason: "  \n ")
    XCTAssertNil(store.errorText, store.statusText)
    await store.completeApprovalExternally(completed, summary: " ")
    XCTAssertNil(store.errorText, store.statusText)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* CANCELED Approve reply to Maya"), updated)
    XCTAssertTrue(updated.contains(":STATUS: rejected"), updated)
    XCTAssertTrue(updated.contains(":REJECTION_END_STATUS: CANCELED"), updated)
    XCTAssertFalse(updated.contains("REJECTION_REASON"), updated)
    XCTAssertTrue(updated.contains("* DONE Approve follow-up to Lee"), updated)
    XCTAssertTrue(updated.contains(":STATUS: completed-externally"), updated)
    XCTAssertFalse(updated.contains("EXTERNAL_COMPLETION_NOTE"), updated)
    XCTAssertTrue(store.approvalItems.isEmpty)
  }

  @MainActor
  func testMarkStandaloneApprovalDoneElsewhereUsesStableIDAndRecordsAuditNote() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-external-approval-stale-line-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("external-approval-stale-line.org2")
    try """
    * TODO Parent wrapper
    :PROPERTIES:
    :ID: parent-id
    :STATUS: waiting
    :END:

    ** TODO Approve customer follow-up
    :PROPERTIES:
    :ID: approval-child-id
    :STATUS: draft-needs-review
    :ASSIGNEE: Avi
    :END:

    Draft body
    """.write(to: note, atomically: true, encoding: .utf8)

    let staleLineItem = ApprovalItem(
      title: "Approve customer follow-up",
      status: "draft-needs-review",
      todo: "TODO",
      level: 2,
      file: note.path,
      line: 1,
      idValue: "approval-child-id",
      properties: [
        "ID": "approval-child-id",
        "STATUS": "draft-needs-review",
        "ASSIGNEE": "Avi"
      ],
      body: "Draft body",
      tags: []
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.replaceApprovalItemsForTesting([staleLineItem])
    store.todoStatusMutationForTesting = { status, file, line in
      let fileURL = URL(fileURLWithPath: file)
      var lines = try String(contentsOf: fileURL, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
      lines[line - 1] = lines[line - 1].replacingOccurrences(
        of: " TODO ",
        with: " \(status.label) "
      )
      try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
      return status.label
    }

    await store.completeApprovalExternally(
      staleLineItem,
      summary: "Handled in Gmail\nby Avi"
    )

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* TODO Parent wrapper"))
    XCTAssertFalse(updated.contains("* DONE Parent wrapper"))
    XCTAssertTrue(updated.contains("** DONE Approve customer follow-up"))
    XCTAssertTrue(updated.contains(":STATUS: completed-externally"))
    XCTAssertTrue(updated.contains(":COMPLETED_EXTERNALLY_AT: <"))
    XCTAssertTrue(updated.contains(":EXTERNAL_COMPLETION_NOTE: Handled in Gmail by Avi"))
    XCTAssertFalse(store.approvalItems.contains(where: { $0.id == staleLineItem.id }))
  }

  @MainActor
  func testMarkReviewOnlyApprovalDoneElsewhereClosesReviewMetadataWithoutTodo() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-external-review-record-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("review-record.org")
    try """
    * Review record
    :PROPERTIES:
    :ID: review-record-id
    :ORG2_ARTIFACT_ROLE: view
    :ORG2_REVIEW_STATUS: review-required
    :END:

    User-provided request awaiting review.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)

    await store.refreshApprovals(updatesStatus: true)

    let item = try XCTUnwrap(store.approvalItems.first)
    XCTAssertNil(item.todo)
    XCTAssertEqual(item.idValue, "review-record-id")

    await store.completeApprovalExternally(
      item,
      summary: "Handled in the customer workflow."
    )

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertNil(store.errorText, store.statusText)
    XCTAssertTrue(updated.contains("* Review record"))
    XCTAssertFalse(updated.contains("* DONE Review record"))
    XCTAssertTrue(updated.contains(":ORG2_REVIEW_STATUS: completed-externally"))
    XCTAssertTrue(updated.contains(":STATUS: completed-externally"))
    XCTAssertTrue(updated.contains(":COMPLETED_EXTERNALLY_AT: <"))
    XCTAssertTrue(updated.contains(":EXTERNAL_COMPLETION_NOTE: Handled in the customer workflow."))
    XCTAssertTrue(store.approvalItems.isEmpty)

    await store.refreshApprovals()

    XCTAssertTrue(store.approvalItems.isEmpty)
  }

  @MainActor
  func testPriorityAndPropertyShortcutsUpdateTempNote() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-priority-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("priority.org2")
    try """
    #+TITLE: Priority Test

    * TODO Important thing :work:
    SCHEDULED: <2026-06-12 Fri>
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Important thing",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": ["work"],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))

    await store.applyPriorityShortcut("A")
    await store.applyPropertyShortcut(key: "OWNER", value: "agent")

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO [#A] Important thing :work:"))
    XCTAssertTrue(updated.contains(":OWNER: agent"))
  }

  @MainActor
  func testDetailEntryOrganizeControlsMutateSelectedTodoOutsideAgenda() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-detail-organize-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("detail.org2")
    try """
    #+TITLE: Detail

    * TODO Review from search
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let result = SearchResult(
      file: note.path,
      line: 3,
      lineEnd: nil,
      heading: "Review from search",
      headingLine: 3,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: "TODO",
      tags: [],
      snippet: "Review from search",
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedSurface = .search
    store.select(.search(result))
    await store.loadEntrySource(for: .search(result))
    try await waitForEntryRender(store)

    XCTAssertTrue(store.canOrganizeCurrentHeadline)

    await store.applyPriorityShortcut("A")
    XCTAssertEqual(store.selectedSurface, .search)
    await store.applyPlanningShortcut(kind: .deadline, target: .today)
    XCTAssertEqual(store.selectedSurface, .search)
    await store.applyTodoShortcut(.inProgress)
    XCTAssertEqual(store.selectedSurface, .search)
    await store.applyPropertyShortcut(key: "OWNER", value: "agent")
    XCTAssertEqual(store.selectedSurface, .search)

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* IN_PROGRESS [#A] Review from search"))
    XCTAssertTrue(updated.contains("DEADLINE: <\(today)"))
    XCTAssertTrue(updated.contains(":OWNER: agent"))
  }

  @MainActor
  func testApprovalContextTodoMutationDoesNotNavigateToAgenda() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-approval-context-status-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("approval.org2")
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: Date())
    try """
    * TODO Review approval draft
    SCHEDULED: <\(today)>
    :PROPERTIES:
    :STATUS: draft-needs-review
    :END:
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAgenda(updatesStatus: false)
    let item = try XCTUnwrap(store.visibleAgendaItems.first)
    store.select(.agenda(item))
    store.selectedSurface = .approvals

    await store.applyTodoShortcut(.done, to: .agenda(item))

    XCTAssertEqual(store.selectedSurface, .approvals)
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE Review approval draft"))
  }

  @MainActor
  func testSimilarTodoAssignmentBulkAssignsBacklogAndPromptsOpenClaw() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-similar-todos-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("contacts.org2")
    try """
    * TODO find valid contact for Acme
    Body

    * TODO find valid contact for Beta Inc
    Body

    * TODO Schedule Beta review
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let result = SearchResult(
      file: note.path,
      line: 1,
      lineEnd: nil,
      heading: "find valid contact for Acme",
      headingLine: 1,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: "TODO",
      tags: [],
      snippet: "find valid contact for Acme",
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
    let recorder = AIChatQueuedSendRecorder()
    let defaultsSuiteName = "org2-workspace-similar-todos-defaults-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsSuiteName)!
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatSendHandler: { messages, _, _, _ in
        try await recorder.send(messages: messages)
      }
    )
    store.setCorpusRoot(root)
    store.selectedSurface = .search
    store.select(.search(result))
    await store.loadEntrySource(for: .search(result))
    try await waitForEntryRender(store)

    await store.presentSimilarTodoAssignment()

    XCTAssertTrue(store.isSimilarTodoAssignmentPresented)
    XCTAssertEqual(store.similarTodoCandidates.map(\.headline), [
      "find valid contact for Acme",
      "find valid contact for Beta Inc"
    ])
    XCTAssertTrue(store.similarTodoPattern.contains("find valid contact for"))
    XCTAssertEqual(store.similarTodoAssignee, "OpenClaw")

    store.similarTodoAssignee = "contact-finder"
    store.similarTodoStatus = "ready"
    await store.assignSimilarTodos(askAIChat: true)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertEqual(updated.components(separatedBy: ":ASSIGNEE: contact-finder").count - 1, 2)
    XCTAssertEqual(updated.components(separatedBy: ":STATUS: ready").count - 1, 2)
    XCTAssertEqual(updated.components(separatedBy: ":ASSIGNED_AT: <").count - 1, 2)
    XCTAssertEqual(store.assignedWorkItems.map(\.headline), [
      "find valid contact for Acme",
      "find valid contact for Beta Inc"
    ])
    XCTAssertEqual(store.assignedWorkSections.map(\.label), ["contact-finder / TODO"])

    let calls = await recorder.recordedCalls()
    let prompt = try XCTUnwrap(calls.last?.last)
    XCTAssertTrue(prompt.contains("Assignee: contact-finder"))
    XCTAssertTrue(prompt.contains("\(note.path):1"))
    XCTAssertTrue(prompt.contains("\(note.path):4"))
    XCTAssertTrue(prompt.contains("Do not create a separate runner"))
  }

  @MainActor
  func testAssignedWorkSectionsGroupByAssigneeAndTodoKeyword() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-assigned-sections-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("assigned.org2")
    try """
    * TODO Draft first reply
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: draft-needs-review
    :END:

    * TODO Draft second reply
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: needs-avi
    :END:

    * DONE Send finished reply
    :PROPERTIES:
    :ASSIGNEE: Avi
    :STATUS: done
    :END:
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshCorpusFiles()
    await store.refreshAssignedWork()

    XCTAssertEqual(store.assignedWorkSections.map(\.label), [
      "Avi / DONE",
      "Avi / TODO"
    ])
    XCTAssertEqual(store.assignedWorkSections.first { $0.label == "Avi / TODO" }?.items.count, 2)

    store.agendaFilter = "second"

    XCTAssertEqual(store.assignedWorkSections.map(\.label), ["Avi / TODO"])
    XCTAssertEqual(store.assignedWorkSections[0].items.map(\.headline), ["Draft second reply"])
  }

  @MainActor
  func testPageRenderOrganizeControlsUseSelectedRenderedHeading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-organize-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("page.org2")
    try """
    * TODO First
    Body

    * TODO Second
    More
    """.write(to: note, atomically: true, encoding: .utf8)

    let result = SearchResult(
      file: note.path,
      line: 1,
      lineEnd: nil,
      heading: "First",
      headingLine: 1,
      headingLevel: 1,
      headingAncestry: nil,
      idValue: nil,
      todo: "TODO",
      tags: [],
      snippet: "First",
      sourceRange: nil,
      matchedLines: nil,
      date: nil
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedSurface = .search
    store.select(.search(result))
    store.selectedEntrySourceMode = .page
    await store.reloadSelectedEntrySource()
    try await waitForEntryRender(store)

    let second = try XCTUnwrap(store.selectedRenderedBlocks.first { block in
      if case .heading(let heading) = block.rendered {
        return heading.title == "Second"
      }
      return false
    })
    store.selectBlock(second)
    XCTAssertTrue(store.canOrganizeCurrentHeadline)

    await store.applyPriorityShortcut("B")
    await store.applyTodoShortcut(.done)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO First"))
    XCTAssertTrue(updated.contains("* DONE [#B] Second"))
  }

  @MainActor
  func testCaptureTodoUsesConfiguredDailiesDir() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-capture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.captureTodo(title: "Captured from app")

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    let daily = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent("\(formatter.string(from: Date())).\(OrgDocumentDefaults.preferredExtension)")
    let updated = try String(contentsOf: daily, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Captured from app"))
    XCTAssertTrue(updated.contains("SCHEDULED: <"))
  }

  @MainActor
  func testSubmittingEditedCaptureDraftDismissesCapturePanel() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-capture-dismiss-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)

    // Agenda "c" opens the panel with an empty task draft; the sheet then
    // edits its own copy, so the submitted draft differs from store.captureDraft.
    store.promptAndCaptureTodoShortcut()
    XCTAssertTrue(store.isCapturePanelPresented)
    var edited = store.captureDraft
    edited.title = "Typed in capture modal"

    await store.submitCaptureDraft(edited)

    XCTAssertFalse(store.isCapturePanelPresented)
    let dailies = root.appendingPathComponent("dailies", isDirectory: true)
    let captured = try FileManager.default.contentsOfDirectory(at: dailies, includingPropertiesForKeys: nil)
      .map { try String(contentsOf: $0, encoding: .utf8) }
      .joined()
    XCTAssertTrue(captured.contains("* TODO Typed in capture modal"))
  }

  @MainActor
  func testGlobalCaptureDraftWritesMetadataAndAttachments() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-global-capture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"dailiesDir":"dailies"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let source = root.appendingPathComponent("clip.txt")
    try "source text".write(to: source, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    let calendar = Calendar(identifier: .gregorian)
    let scheduled = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    let deadline = calendar.date(from: DateComponents(year: 2026, month: 6, day: 20))!

    await store.submitCaptureDraft(WorkspaceCaptureDraft(
      kind: .task,
      title: "Ship capture modal",
      body: "Handle pasted media.",
      todoStatus: .inProgress,
      includeScheduled: true,
      scheduledDate: scheduled,
      includeDeadline: true,
      deadlineDate: deadline,
      priority: "a",
      tagsText: "mac capture",
      assignToAgent: true,
      attachments: [
        WorkspaceCaptureAttachmentDraft(
          kind: .file,
          name: "clip.txt",
          sourceURL: source,
          suggestedExtension: "txt"
        )
      ]
    ))

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    let daily = root
      .appendingPathComponent("dailies", isDirectory: true)
      .appendingPathComponent("\(formatter.string(from: Date())).\(OrgDocumentDefaults.preferredExtension)")
    let updated = try String(contentsOf: daily, encoding: .utf8)
    XCTAssertTrue(updated.contains("* IN_PROGRESS [#A] Ship capture modal :capture:mac:"))
    XCTAssertTrue(updated.contains("SCHEDULED: <2026-06-15"))
    XCTAssertTrue(updated.contains("DEADLINE: <2026-06-20"))
    XCTAssertTrue(updated.contains(":CAPTURED_AT: <"))
    XCTAssertTrue(updated.contains(":ASSIGNEE: OpenClaw"))
    XCTAssertTrue(updated.contains(":STATUS: ready"))
    XCTAssertTrue(updated.contains(":ASSIGNED_AT: <"))
    XCTAssertTrue(updated.contains("Handle pasted media."))
    XCTAssertTrue(updated.contains("[[file:attachments/"))
    XCTAssertTrue(updated.contains("][clip.txt]]"))

    let attachments = root.appendingPathComponent("attachments", isDirectory: true)
    let copied = try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)
    XCTAssertEqual(copied.count, 1)
    XCTAssertEqual(try String(contentsOf: copied[0], encoding: .utf8), "source text")
  }

  @MainActor
  func testCreateKnowledgeNodeUsesConfiguredIndexDir() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-knowledge-node-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"indexDir":"knowledge"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.createKnowledgeNode(title: "Project Notes")

    let node = root
      .appendingPathComponent("knowledge", isDirectory: true)
      .appendingPathComponent("project-notes.\(OrgDocumentDefaults.preferredExtension)")
    let text = try String(contentsOf: node, encoding: .utf8)
    XCTAssertTrue(text.contains("#+TITLE: Project Notes"))
    XCTAssertTrue(text.contains(":ID: "))
  }

  func testInlineSelectionBacklinkReplacementWrapsSelectedText() {
    let text = "Ask Docker about usage"
    let range = (text as NSString).range(of: "Docker")
    let edit = WorkspaceStore.backlinkReplacementForSelectedText(in: text, range: range)

    XCTAssertEqual(edit?.text, "Ask [[Docker]] about usage")
    XCTAssertEqual(edit?.selectedRange.location, range.location)
    XCTAssertEqual(edit?.selectedRange.length, ("[[Docker]]" as NSString).length)

    let spacedRange = NSRange(location: range.location - 1, length: range.length + 2)
    let spacedEdit = WorkspaceStore.backlinkReplacementForSelectedText(in: text, range: spacedRange)
    XCTAssertEqual(spacedEdit?.text, "Ask [[Docker]] about usage")
    XCTAssertEqual(spacedEdit?.selectedRange.location, range.location)

    let nodeEdit = WorkspaceStore.nodeLinkReplacementForSelectedText(
      in: text,
      range: spacedRange,
      id: "docker-id",
      title: "Docker"
    )
    XCTAssertEqual(nodeEdit?.text, "Ask [[id:docker-id][Docker]] about usage")
    XCTAssertEqual(nodeEdit?.selectedRange.location, range.location)
  }

  @MainActor
  func testCreateKnowledgeNodeFromSelectionCreatesNodeAndIdLink() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-selection-node-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try #"{"roam":{"indexDir":"knowledge"}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)
    let source = root.appendingPathComponent("source.org2")
    try """
    #+TITLE: Source

    * Source
    Ask Docker about usage.
    """.write(to: source, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.aiChatThreadRecord(AIChatThreadRecord(
      title: "Source",
      file: source.path,
      line: 3,
      zone: "test",
      modifiedAt: nil
    )))

    let text = "Ask Docker about usage."
    let range = (text as NSString).range(of: "Docker")
    let edit = await store.createKnowledgeNodeFromSelection(text: text, range: range)

    let node = root
      .appendingPathComponent("knowledge", isDirectory: true)
      .appendingPathComponent("docker.org")
    let nodeText = try String(contentsOf: node, encoding: .utf8)
    let idMatch = try XCTUnwrap(nodeText.range(of: #":ID:\s+([A-Fa-f0-9-]+)"#, options: .regularExpression))
    let idLine = String(nodeText[idMatch])
    let id = try XCTUnwrap(idLine.split(separator: " ").last.map(String.init))

    XCTAssertEqual(edit?.text, "Ask [[id:\(id)][Docker]] about usage.")
    XCTAssertTrue(nodeText.contains("#+TITLE: Docker"))
    XCTAssertTrue(nodeText.contains("Origin: [[file:source.org2][Source]]"))
  }

  @MainActor
  func testLinkifyCurrentFileRunsRoamLinkifyOnSelectedFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-linkify-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "Org2LinkifyCurrentFile.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let node = root.appendingPathComponent("docker.org2")
    let note = root.appendingPathComponent("note.org2")
    try """
    #+TITLE: Docker
    :PROPERTIES:
    :ID: docker-id
    :END:
    """.write(to: node, atomically: true, encoding: .utf8)
    try """
    #+TITLE: Note

    * Note
    Docker usage should become linked.
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json")
    )
    store.setWorkspaceRealtimeRefreshActive(false)
    store.setCorpusRoot(root, persistsDefault: false)
    let location = WorkspaceLocation.aiChatThreadRecord(AIChatThreadRecord(
      title: "Note",
      file: note.path,
      line: 3,
      zone: "test",
      modifiedAt: nil
    ))
    store.select(location)
    await store.loadEntrySource(for: location)
    XCTAssertEqual(store.selectedEntrySource?.file, note.path)

    await store.linkifyCurrentFile()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("[[id:docker-id][Docker]] usage should become linked."))
    XCTAssertTrue(
      store.statusText.contains("Linkified note.org2"),
      "status: \(store.statusText); error: \(store.errorText ?? "none")"
    )
  }

  func testRefreshSelectedDataNotebookUsesOneAtomicBatchCommand() {
    XCTAssertEqual(
      WorkspaceStore.dataNotebookRefreshArguments(for: "/tmp/dashboard.org2"),
      [
        "query-data", "--file", "/tmp/dashboard.org2",
        "--all-results", "--apply", "--format", "json"
      ]
    )
  }

  func testDataNotebookRefreshUpdatesSelectedFileModificationDate() throws {
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let refreshedDate = Date(timeIntervalSince1970: 1_800_000_000)
    let location = WorkspaceLocation.aiChatThreadRecord(AIChatThreadRecord(
      title: "Dashboard",
      file: "/tmp/dashboard.org2",
      line: 7,
      zone: "views",
      modifiedAt: oldDate,
      idValue: "dashboard-id"
    ))

    let refreshed = WorkspaceStore.dataNotebookLocationByRefreshingModificationDate(
      location,
      file: "/tmp/../tmp/dashboard.org2",
      modifiedAt: refreshedDate
    )

    guard case .aiChatThreadRecord(let thread)? = refreshed else {
      return XCTFail("Expected the selected OpenClaw file location")
    }
    XCTAssertEqual(thread.modifiedAt, refreshedDate)
    XCTAssertEqual(thread.lineForEditor, 7)
    XCTAssertEqual(thread.idValue, "dashboard-id")

    let unrelated = WorkspaceStore.dataNotebookLocationByRefreshingModificationDate(
      location,
      file: "/tmp/another.org2",
      modifiedAt: refreshedDate
    )
    XCTAssertEqual(unrelated, location)
  }

  @MainActor
  func testSelectedFileDataNotebookDetectionDoesNotReadFromDiskOnEveryAccess() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-data-notebook-detection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let notebook = root.appendingPathComponent("dashboard.org2")
    let note = root.appendingPathComponent("note.org2")
    try "```sql results=summary\nSELECT 1\n```\n".write(to: notebook, atomically: true, encoding: .utf8)
    try "* Plain note\n".write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let threadRecorder = ThreadSafeBoolRecorder()
    store.selectedFileDataNotebookDidInspectForTesting = { isMainThread in
      threadRecorder.append(isMainThread)
    }
    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Dashboard",
      file: notebook.path,
      line: 1,
      zone: "test",
      modifiedAt: nil
    ))

    try await waitForCondition { store.selectedFileIsDataNotebook }
    XCTAssertTrue(store.selectedFileIsDataNotebook)
    try FileManager.default.removeItem(at: notebook)
    for _ in 0..<100 {
      XCTAssertTrue(store.selectedFileIsDataNotebook)
    }

    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Note",
      file: note.path,
      line: 1,
      zone: "test",
      modifiedAt: nil
    ))
    try await waitForCondition { threadRecorder.values.count >= 2 }
    XCTAssertFalse(store.selectedFileIsDataNotebook)
    XCTAssertEqual(threadRecorder.values, [false, false])
  }

  @MainActor
  func testStaleDataNotebookInspectionCannotOverwriteTheNewSelection() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-data-notebook-stale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let notebook = root.appendingPathComponent("dashboard.org2")
    let note = root.appendingPathComponent("note.org2")
    try "```sql results=summary\nSELECT 1\n```\n".write(
      to: notebook,
      atomically: true,
      encoding: .utf8
    )
    try "* Plain note\n".write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let gate = DataNotebookInspectionGate()
    let completions = ThreadSafeStringRecorder()
    let threadRecorder = ThreadSafeBoolRecorder()
    store.selectedFileDataNotebookDidInspectForTesting = { isMainThread in
      threadRecorder.append(isMainThread)
    }
    store.selectedFileDataNotebookInspectionForTesting = { url, _ in
      if url.standardizedFileURL.path == notebook.standardizedFileURL.path {
        await gate.wait()
        completions.append("notebook")
        return true
      }
      completions.append("note")
      return false
    }

    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Dashboard",
      file: notebook.path,
      line: 1,
      zone: "test",
      modifiedAt: nil
    ))
    await gate.waitUntilStarted()
    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Note",
      file: note.path,
      line: 1,
      zone: "test",
      modifiedAt: nil
    ))
    try await waitForCondition { completions.values.contains("note") }
    XCTAssertFalse(store.selectedFileIsDataNotebook)

    await gate.release()
    try await waitForCondition { completions.values.contains("notebook") }
    await Task.yield()
    XCTAssertFalse(store.selectedFileIsDataNotebook)
    XCTAssertEqual(threadRecorder.values.count, 2)
    XCTAssertTrue(threadRecorder.values.allSatisfy { !$0 })
  }

  @MainActor
  func testRefreshSelectedDataNotebookPromptsForRejectedMetabaseKey() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-data-auth-failure-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    try """
    process.stdout.write(JSON.stringify({
      ok: false,
      diagnostics: [{
        severity: "error",
        message: 'Data source profile "scarf-metabase" authentication failed (HTTP 401). Check its API key and permissions'
      }]
    }));
    process.exit(1);
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let notebook = corpus.appendingPathComponent("dashboard.org2")
    try """
    #+title: Dashboard

    ```sql results=messages
    SELECT 1
    ```
    """.write(to: notebook, atomically: true, encoding: .utf8)

    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus)
    store.selectedLocation = .aiChatThreadRecord(AIChatThreadRecord(
      title: "Dashboard",
      file: notebook.path,
      line: 1,
      zone: "test",
      modifiedAt: nil
    ))

    await store.refreshSelectedDataNotebook()

    XCTAssertEqual(store.statusText, "Metabase authentication failed")
    XCTAssertEqual(store.dataNotebookRefreshFailure?.kind, .authentication)
    XCTAssertEqual(store.dataNotebookRefreshFailure?.needsCredentialUpdate, true)
    XCTAssertTrue(store.dataNotebookRefreshFailure?.message.contains("current API key") == true)
    XCTAssertTrue(store.isDataSourceConfigurationPresented)
    XCTAssertFalse(store.saveScarfMetabaseConfiguration(apiKey: "", clearAPIKey: false))
    XCTAssertEqual(
      store.dataSourceConfigurationError,
      "Enter a new Metabase API key to replace the key that was rejected."
    )

    let queryFailure = WorkspaceStore.dataNotebookRefreshFailure(for: "DuckDB could not bind column missing")
    XCTAssertEqual(queryFailure.kind, .query)
    XCTAssertFalse(queryFailure.needsCredentialUpdate)
    XCTAssertEqual(queryFailure.message, "DuckDB could not bind column missing")
  }

  @MainActor
  func testLoadsAndSavesSelectedEntrySource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("edit.org2")
    try """
    #+TITLE: Edit Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body
    ** Child
    Child body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))

    XCTAssertEqual(store.selectedEntrySource?.startLine, 3)
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "3-7")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("** Child") == true)

    XCTAssertFalse(store.canSaveActiveEdit)
    store.beginEditingSelectedEntry()
    XCTAssertFalse(store.canSaveActiveEdit)
    store.editableEntryText = store.editableEntryText.replacingOccurrences(of: "Body", with: "Updated body")
    store.noteSourceEditorLocalTextChanged(store.editableEntryText)
    XCTAssertTrue(store.canSaveActiveEdit)
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Updated body"))
    XCTAssertTrue(updated.contains("* Sibling\nSibling body"))
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertFalse(store.canSaveActiveEdit)
  }

  @MainActor
  func testStaleEntrySourceLoadWithSameFileAndLineDoesNotReplaceSelectedAgendaItem() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-stale-entry-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("agenda.org2")
    try """
    * TODO First stale item
    SCHEDULED: <2026-06-15 Mon>

    * TODO Selected fresh item
    SCHEDULED: <2026-06-15 Mon>
    """.write(to: note, atomically: true, encoding: .utf8)

    let stale = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "First stale item",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 0,
      "body": null,
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))
    let selected = try JSONDecoder().decode(AgendaItem.self, from: Data("""
    {
      "todo": "TODO",
      "headline": "Selected fresh item",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 0,
      "body": null,
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """.utf8))

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedLocation = .agenda(selected)

    await store.loadEntrySource(for: .agenda(stale))

    XCTAssertNil(store.selectedEntrySource)
    guard case .agenda(let item)? = store.selectedLocation else {
      return XCTFail("Expected selected agenda location")
    }
    XCTAssertEqual(item.headline, "Selected fresh item")
  }

  @MainActor
  func testPageScopeEditSavesNewHeadingInDailyNote() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("2026-06-13.org2")
    try """
    #+TITLE: 2026-06-13

    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected daily note")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    XCTAssertEqual(store.selectedEntrySourceMode, .page)
    store.beginEditingCurrentScope()
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertNil(store.editingBlockID)

    store.editableEntryText += "\n* Quick note\nSome body\n"
    store.noteSourceEditorLocalTextChanged(store.editableEntryText)
    await store.saveActiveEdit()
    try await waitForEntryRender(store)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* Quick note\nSome body"))
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)
    XCTAssertTrue(store.selectedRenderedBlocks.contains {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Quick note"
      }
      return false
    })
  }

  @MainActor
  func testFileTabSelectionStartsReadOnlyUntilExplicitEdit() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-live-file-editor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("live.org2")
    try """
    #+TITLE: Live Editor

    * First
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected note")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    XCTAssertTrue(store.isLiveFileEditorSelected)
    XCTAssertTrue(store.isLiveFileEditorAvailable)
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertFalse(store.hasActiveEdit)
    XCTAssertEqual(store.editableEntryText, store.selectedEntrySource?.text)
    XCTAssertFalse(store.canSaveActiveEdit)
    XCTAssertFalse(store.canSaveLiveFileEditor)

    store.beginEditingCurrentScope()

    XCTAssertTrue(store.isEditingEntry)
    XCTAssertTrue(store.hasActiveEdit)
    XCTAssertTrue(store.canSaveCurrentFile)
  }

  @MainActor
  func testLiveFileEditorSaveKeepsLiveEditorAvailable() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-live-file-save-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("live-save.org2")
    try """
    #+TITLE: Live Save

    * First
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected note")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    store.beginEditingCurrentScope()
    XCTAssertTrue(store.isEditingEntry)

    store.editableEntryText = store.editableEntryText.replacingOccurrences(of: "Body", with: "Edited body")
    store.noteSourceEditorLocalTextChanged(store.editableEntryText)
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Edited body"))
    XCTAssertTrue(store.isLiveFileEditorAvailable)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertTrue(store.hasActiveEdit)
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)
    XCTAssertEqual(store.selectedEntrySource?.text, store.editableEntryText)
    XCTAssertTrue(store.statusText.contains("Saved"))
  }

  @MainActor
  func testPageScopeEditRefusesStaleDailyNoteWhenSyncedContentTouchesLoadedRange() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-stale-save-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("2026-06-13.org2")
    try """
    #+TITLE: 2026-06-13

    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected daily note")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    store.beginEditingCurrentScope()
    XCTAssertTrue(store.isEditingEntry)

    try """
    #+TITLE: 2026-06-13 synced

    * Phone note
    Synced from mobile.
    """.write(to: note, atomically: true, encoding: .utf8)

    store.editableEntryText += "\n* Mac note\nShould not overwrite phone note.\n"
    store.noteSourceEditorLocalTextChanged(store.editableEntryText)
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("#+TITLE: 2026-06-13 synced"))
    XCTAssertTrue(updated.contains("* Phone note\nSynced from mobile."))
    XCTAssertFalse(updated.contains("* Mac note"))
    XCTAssertEqual(store.statusText, "Save conflict: file changed on disk")
    XCTAssertTrue(store.errorText?.contains("File changed on disk") == true)
    XCTAssertEqual(store.editorSaveConflict?.file, note.path)
    XCTAssertEqual(store.editorSaveConflict?.canOverwrite, true)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertTrue(store.entryEditorHasUnsavedChanges)
    XCTAssertTrue(store.editableEntryText.contains("* Mac note"))

    await store.reloadAfterSaveConflict()

    XCTAssertNil(store.editorSaveConflict)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)
    XCTAssertTrue(store.editableEntryText.contains("* Phone note\nSynced from mobile."))
    XCTAssertFalse(store.editableEntryText.contains("* Mac note"))

    store.editableEntryText += "\n* Mac note\nPreserve this local edit.\n"
    store.noteSourceEditorLocalTextChanged(store.editableEntryText)
    try """
    #+TITLE: 2026-06-13 synced again

    * Phone note
    Synced from mobile.

    * Remote follow-up
    Written after the reload.
    """.write(to: note, atomically: true, encoding: .utf8)
    await store.saveActiveEdit()
    XCTAssertNotNil(store.editorSaveConflict)

    await store.overwriteAfterSaveConflict()

    let overwritten = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(overwritten.contains("* Phone note\nSynced from mobile."))
    XCTAssertTrue(overwritten.contains("* Mac note\nPreserve this local edit."))
    XCTAssertFalse(overwritten.contains("* Remote follow-up"))
    XCTAssertNil(store.editorSaveConflict)
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)
    XCTAssertTrue(store.statusText.contains(".org2-recovery"))

    let recoveryDirectory = root.appendingPathComponent(".org2-recovery", isDirectory: true)
    let recoveryFiles = try FileManager.default.contentsOfDirectory(
      at: recoveryDirectory,
      includingPropertiesForKeys: nil
    )
    let recoveryFile = try XCTUnwrap(recoveryFiles.first)
    let recovered = try String(contentsOf: recoveryFile, encoding: .utf8)
    XCTAssertTrue(recovered.contains("* Remote follow-up\nWritten after the reload."))
  }

  @MainActor
  func testBlankPageClickStartsParagraphDraftAtEndOfDailyNote() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-blank-click-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("2026-06-16.org2")
    try """
    #+TITLE: 2026-06-16

    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    await store.beginAppendingSectionAtEnd()

    XCTAssertFalse(store.isEditingEntry)
    XCTAssertNotNil(store.editingBlockID)
    XCTAssertEqual(store.editableBlockText, "")
    store.editableBlockText = "Meeting notes"
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Meeting notes"))
    XCTAssertFalse(store.hasActiveEdit)
  }

  @MainActor
  func testBlankPageParagraphDraftCommitsWhenReturnStartsNextDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-blank-return-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("2026-06-16.org2")
    try """
    #+TITLE: 2026-06-16

    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    await store.beginAppendingSectionAtEnd()
    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "Meeting notes"

    await store.splitEditingBlock(draft, atUTF16Offset: ("Meeting notes" as NSString).length)
    try await waitForCondition {
      (try? String(contentsOf: note, encoding: .utf8).contains("Meeting notes")) == true
        && store.hasActiveEdit
    }

    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Meeting notes"))
    XCTAssertFalse(store.hasActiveEdit)
  }

  @MainActor
  func testPageScopeSaveCompletesWhenOrgCryptEncryptionFails() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-crypt-save-failure-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("secrets.org2")
    try """
    #+TITLE: Secrets

    * Secret :crypt:
    plaintext
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.orgCryptRecipientsText = "person@example.com"
    store.orgCryptGpgProgram = "/bin/false"
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    guard let location = store.selectedLocation else {
      return XCTFail("Expected selected file")
    }
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    store.beginEditingCurrentScope()
    store.editableEntryText = store.editableEntryText.replacingOccurrences(of: "plaintext", with: "changed plaintext")
    store.noteSourceEditorLocalTextChanged(store.editableEntryText)
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("changed plaintext"))
    XCTAssertFalse(updated.contains("-----BEGIN PGP MESSAGE-----"))
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)
    XCTAssertEqual(store.statusText, "Saved, but encryption failed")
    XCTAssertTrue(store.errorText?.contains("Encryption failed") == true)
  }

  @MainActor
  func testActiveSourceEditorDefersRenderedSourceReload() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-rendered-entry-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("rendered-entry-edit.org2")
    try """
    #+TITLE: Rendered Entry Edit Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    store.beginEditingSelectedEntry()
    store.selectedRenderedBlocks = []
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    XCTAssertTrue(store.isEditingEntry)
    XCTAssertFalse(store.canSaveActiveEdit)
    XCTAssertTrue(store.selectedRenderedBlocks.isEmpty)
    XCTAssertTrue(store.editableEntryText.contains("* TODO Parent\nBody"))
  }

  @MainActor
  func testSavesRenderedBlockInPlace() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-edit.org2")
    try """
    #+TITLE: Block Edit Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body
    Second line
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    XCTAssertEqual(paragraph.displayRange, "5-6")

    store.beginEditingBlock(paragraph)
    XCTAssertTrue(store.canSaveActiveEdit)
    store.editableBlockText = "Updated body\nSecond line\nThird line"
    await store.saveActiveEdit()
    try await waitForEntryRender(store)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Updated body\nSecond line\nThird line"))
    XCTAssertTrue(updated.contains("* Sibling\nSibling body"))
    XCTAssertNil(store.editingBlockID)
    XCTAssertFalse(store.canSaveActiveEdit)
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated body\nSecond line\nThird line")
    let shiftedSibling = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Sibling"
      }
      return false
    })
    XCTAssertEqual(shiftedSibling.startLine, 8)
  }

  @MainActor
  func testSaveActiveEditUsesLatestInlineDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-save-inline-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("save-inline-draft.org2")
    try """
    #+TITLE: Save Inline Draft Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    XCTAssertEqual(store.editableBlockText, "Body")

    store.updateEditingBlockDraft(paragraph, draft: "Draft from inline editor")
    XCTAssertEqual(store.editableBlockText, "Body")
    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nDraft from inline editor\n* Sibling"))
    XCTAssertFalse(updated.contains("* TODO Parent\nBody\n* Sibling"))
    XCTAssertEqual(store.selectedBlock?.rawText, "Draft from inline editor")
    XCTAssertNil(store.editingBlockID)
  }

  @MainActor
  func testUndoRestoresLiveFileEditorAutosaveAndRedoReappliesIt() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-live-undo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("live-undo.org2")
    let original = """
    #+TITLE: Live Undo

    * Meetings
    Original body
    """
    let updated = """
    #+TITLE: Live Undo

    * Meetings
    Updated body
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)
    XCTAssertTrue(store.isLiveFileEditorSelected)

    store.noteLiveFileEditorTextChanged(updated)
    await store.saveLiveFileEditor(explicit: false)
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), updated)

    store.performUndoCommand()
    try await waitForCondition {
      (try? String(contentsOf: note, encoding: .utf8)) == original
        && store.selectedEntrySource?.text == original
    }
    XCTAssertEqual(store.statusText, "Undid edit in live-undo.org2")

    store.performRedoCommand()
    try await waitForCondition {
      (try? String(contentsOf: note, encoding: .utf8)) == updated
        && store.selectedEntrySource?.text == updated
    }
    XCTAssertEqual(store.statusText, "Redid edit in live-undo.org2")
  }

  @MainActor
  func testNavigationSerializesPendingLiveEditorWritesAndKeepsNewestDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-navigation-save-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstFile = root.appendingPathComponent("first.org2")
    let secondFile = root.appendingPathComponent("second.org2")
    let original = "* First\nOriginal"
    let firstDraft = "* First\nFirst draft"
    let newestDraft = "* First\nNewest draft"
    try original.write(to: firstFile, atomically: true, encoding: .utf8)
    try "* Second\nBody".write(to: secondFile, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json")
    )
    store.formatOrgFilesOnSave = false
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: firstFile.path,
      relativePath: firstFile.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let firstLocation = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: firstLocation)
    store.editorPersistenceDelayNanosecondsForTesting = 80_000_000

    store.noteLiveFileEditorTextChanged(firstDraft)
    let firstSave = Task { @MainActor in
      await store.saveLiveFileEditor(explicit: false)
    }
    try await Task.sleep(nanoseconds: 10_000_000)
    store.noteLiveFileEditorTextChanged(newestDraft)
    store.selectCorpusFile(CorpusFile(
      path: secondFile.path,
      relativePath: secondFile.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))

    await firstSave.value
    let navigationSaveSucceeded = await store.waitForPendingEditorPersistenceForTesting()
    XCTAssertTrue(navigationSaveSucceeded)
    XCTAssertEqual(try String(contentsOf: firstFile, encoding: .utf8), newestDraft)
    XCTAssertEqual(store.selectedLocation?.file, secondFile.path)
    XCTAssertEqual(store.selectedEntrySource?.file, secondFile.path)
  }

  @MainActor
  func testFailedOutgoingCheckpointRetainsExactDraftAfterNavigation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-navigation-failed-checkpoint-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstFile = root.appendingPathComponent("first.org2")
    let secondFile = root.appendingPathComponent("second.org2")
    let original = "* First\nOriginal"
    let exactDraft = "* First\nExact outgoing draft 😀"
    try original.write(to: firstFile, atomically: true, encoding: .utf8)
    try "* Second\nBody".write(to: secondFile, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json")
    )
    store.formatOrgFilesOnSave = false
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: firstFile.path,
      relativePath: firstFile.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let firstLocation = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: firstLocation)
    let outgoingSource = try XCTUnwrap(store.selectedEntrySource)
    store.editorPersistenceDelayNanosecondsForTesting = 50_000_000
    store.editorPersistenceFailureMessageForTesting = "injected outgoing failure"

    store.persistSourceEditorCheckpoint(exactDraft, source: outgoingSource)
    store.selectCorpusFile(CorpusFile(
      path: secondFile.path,
      relativePath: secondFile.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))

    let persistenceSucceeded = await store.waitForPendingEditorPersistenceForTesting()
    XCTAssertFalse(persistenceSucceeded)
    XCTAssertEqual(try String(contentsOf: firstFile, encoding: .utf8), original)
    XCTAssertEqual(store.selectedLocation?.file, secondFile.path)
    XCTAssertEqual(
      store.failedEditorPersistenceDraftForTesting(file: firstFile.path),
      exactDraft
    )
    XCTAssertEqual(store.editorSaveConflict?.file, firstFile.path)
    XCTAssertFalse(store.editorSaveConflict?.canOverwrite ?? true)
  }

  @MainActor
  func testTerminationWaitsForEditorPersistenceAndRefusesDataLossOnFailure() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-termination-editor-save-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let note = root.appendingPathComponent("termination.org2")
    let original = "* Termination\nOriginal"
    let savedDraft = "* Termination\nSaved before quit"
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("chat.json")
    )
    store.formatOrgFilesOnSave = false
    store.aiChatTranscriptSaverForTesting = {}
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    store.editorPersistenceDelayNanosecondsForTesting = 80_000_000
    store.noteLiveFileEditorTextChanged(savedDraft)

    let pendingSave = Task { @MainActor in
      await store.saveLiveFileEditor(explicit: false)
    }
    try await Task.sleep(nanoseconds: 10_000_000)
    let canTerminate = await store.prepareForTermination()
    XCTAssertTrue(canTerminate, store.statusText)
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)
    XCTAssertFalse(store.liveFileEditorHasUnsavedChanges)
    let terminationEditorLaneSucceeded = await store.waitForPendingEditorPersistenceForTesting()
    XCTAssertTrue(terminationEditorLaneSucceeded, store.errorText ?? "")
    await pendingSave.value
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), savedDraft)

    let failingStore = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      aiChatTranscriptURL: root.appendingPathComponent("failing-chat.json")
    )
    failingStore.formatOrgFilesOnSave = false
    failingStore.aiChatTranscriptSaverForTesting = {}
    failingStore.setCorpusRoot(root)
    failingStore.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let failingLocation = try XCTUnwrap(failingStore.selectedLocation)
    await failingStore.loadEntrySource(for: failingLocation)
    failingStore.noteLiveFileEditorTextChanged("* Termination\nMust remain in memory")
    failingStore.editorPersistenceFailureMessageForTesting = "injected disk failure"

    let canTerminateAfterFailure = await failingStore.prepareForTermination()
    XCTAssertFalse(canTerminateAfterFailure)
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), savedDraft)
    XCTAssertTrue(failingStore.liveFileEditorHasUnsavedChanges)
    XCTAssertEqual(
      failingStore.failedEditorPersistenceDraftForTesting(file: note.path),
      "* Termination\nMust remain in memory"
    )
    XCTAssertEqual(failingStore.statusText, "Could not save all editor changes before quitting")
  }

  @MainActor
  func testTerminationAllowsCleanReadOnlyTranscriptButRefusesRejectedMetadataMutation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-termination-read-only-chat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cleanSuiteName = "org2-workspace-termination-clean-read-only-\(UUID().uuidString)"
    let cleanDefaults = try XCTUnwrap(UserDefaults(suiteName: cleanSuiteName))
    defer { cleanDefaults.removePersistentDomain(forName: cleanSuiteName) }
    let cleanStore = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: cleanDefaults,
      aiChatTranscriptURL: root.appendingPathComponent("clean-chat.json"),
      legacyDefaultsDomains: []
    )
    await cleanStore.waitForAIChatTranscriptLoadForTesting()
    var cleanSaveCount = 0
    cleanStore.aiChatTranscriptSaverForTesting = { cleanSaveCount += 1 }
    cleanStore.setAIChatTranscriptWritesBlockedForTesting(true)

    XCTAssertFalse(cleanStore.hasUnpersistedAIChatTranscriptMutationForTesting)
    let cleanCanTerminate = await cleanStore.prepareForTermination()
    XCTAssertTrue(cleanCanTerminate, cleanStore.statusText)
    XCTAssertEqual(cleanSaveCount, 0, "a clean read-only transcript must not retry a known-blocked write")

    let dirtySuiteName = "org2-workspace-termination-dirty-read-only-\(UUID().uuidString)"
    let dirtyDefaults = try XCTUnwrap(UserDefaults(suiteName: dirtySuiteName))
    defer { dirtyDefaults.removePersistentDomain(forName: dirtySuiteName) }
    let dirtyStore = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: dirtyDefaults,
      aiChatTranscriptURL: root.appendingPathComponent("dirty-chat.json"),
      legacyDefaultsDomains: []
    )
    await dirtyStore.waitForAIChatTranscriptLoadForTesting()
    dirtyStore.aiChatTranscriptPersistenceDelayNanoseconds = 60_000_000_000
    dirtyStore.aiChatTranscriptSaverForTesting = {}
    let threadID = dirtyStore.createAIChatThread(runtime: .codex)
    dirtyStore.flushDeferredAIChatTranscriptPersistence()
    XCTAssertFalse(dirtyStore.hasUnpersistedAIChatTranscriptMutationForTesting)
    XCTAssertNil(dirtyStore.aiChatThreadMessageMutationVersionForTesting(threadID))

    dirtyStore.setAIChatTranscriptWritesBlockedForTesting(true)
    dirtyStore.renameAIChatThread(threadID, title: "Unsaved read-only rename")

    XCTAssertTrue(dirtyStore.hasUnpersistedAIChatTranscriptMutationForTesting)
    XCTAssertNil(
      dirtyStore.aiChatThreadMessageMutationVersionForTesting(threadID),
      "metadata dirtiness must not depend on the message-only mutation map"
    )
    let dirtyCanTerminate = await dirtyStore.prepareForTermination()
    XCTAssertFalse(dirtyCanTerminate)
    XCTAssertEqual(dirtyStore.statusText, "Could not save AI chat before quitting")
    XCTAssertTrue(dirtyStore.hasUnpersistedAIChatTranscriptMutationForTesting)
  }

  @MainActor
  func testTerminationRefusesChatMutationCreatedDuringFinalTranscriptSave() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-termination-final-chat-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suiteName = "org2-workspace-termination-final-chat-race-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    await store.waitForAIChatTranscriptLoadForTesting()
    store.aiChatTranscriptPersistenceDelayNanoseconds = 60_000_000_000
    var saveCount = 0
    var lateThreadID: UUID?
    store.aiChatTranscriptSaverForTesting = {
      saveCount += 1
      if saveCount == 1 {
        lateThreadID = store.createAIChatRemoteThread(runtime: .codex)
      }
    }

    let canTerminate = await store.prepareForTermination()
    XCTAssertFalse(canTerminate)
    let createdThreadID = try XCTUnwrap(lateThreadID)
    XCTAssertEqual(saveCount, 1)
    XCTAssertNotNil(store.aiChatThreadMessageMutationVersionForTesting(createdThreadID))
    XCTAssertTrue(store.hasUnpersistedAIChatTranscriptMutationForTesting)
    XCTAssertEqual(store.statusText, "Could not save AI chat before quitting")
  }

  @MainActor
  func testWorkspaceUndoPrefersFocusedNativeTextEditor() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    defer { window.orderOut(nil) }
    let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    textView.allowsUndo = true
    scrollView.documentView = textView
    window.contentView = scrollView
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(window.makeFirstResponder(textView))
    textView.string = "Draft"
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    textView.insertText(" updated", replacementRange: textView.selectedRange())
    XCTAssertEqual(textView.string, "Draft updated")

    XCTAssertTrue(WorkspaceStore.performNativeTextUndoIfPossible(firstResponder: textView))
    XCTAssertEqual(textView.string, "Draft")
    XCTAssertTrue(WorkspaceStore.performNativeTextRedoIfPossible(firstResponder: textView))
    XCTAssertEqual(textView.string, "Draft updated")
  }

  @MainActor
  func testUndoRestoresSavedRenderedBlockChange() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-undo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-undo.org2")
    let original = """
    #+TITLE: Block Undo

    * Parent
    Original body
    * Sibling
    Sibling body
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": null,
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Original body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.updateEditingBlockDraft(paragraph, draft: "Updated body")
    await store.saveActiveEdit()
    XCTAssertTrue((try String(contentsOf: note, encoding: .utf8)).contains("Updated body"))

    store.performUndoCommand()
    try await waitForCondition {
      (try? String(contentsOf: note, encoding: .utf8)) == original
        && store.selectedRenderedBlocks.contains { block in
          if case .paragraph(let text) = block.rendered {
            return text == "Original body"
          }
          return false
        }
    }
    XCTAssertEqual(store.statusText, "Undid edit in block-undo.org2")
  }

  @MainActor
  func testSavingRenderedBlockSchedulesAgendaRefreshWithoutBlocking() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-nonblocking-save-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    try """
    setTimeout(() => {
      process.stdout.write(JSON.stringify({
        "$schema": "org2:agenda:v1",
        "range": { "start": "2026-06-12", "end": "2026-06-18", "days": 7 },
        "overdue": [],
        "days": [{ "date": "2026-06-12", "weekday": "Fri", "items": [] }],
        "skippedFiles": 0
      }));
    }, 1800);
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let note = corpus.appendingPathComponent("nonblocking-save.org2")
    try """
    #+TITLE: Nonblocking Save Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Updated body"

    let started = Date()
    await store.saveEditedBlock(paragraph)
    let elapsed = Date().timeIntervalSince(started)

    XCTAssertLessThan(elapsed, 1.0)
    XCTAssertTrue(store.statusText.hasPrefix("Saved block"))
    XCTAssertTrue((try String(contentsOf: note, encoding: .utf8)).contains("Updated body"))

    try await waitForCondition(timeout: 5) {
      store.agenda?.totalItemCount == 0 && !store.isLoadingAgenda
    }
    XCTAssertTrue(store.statusText.hasPrefix("Saved block"))
  }

  @MainActor
  func testAutosaveDefersAgendaRefreshUntilBlockEditingEnds() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-autosave-deferred-agenda-\(UUID().uuidString)", isDirectory: true)
    let repoRoot = workspace.appendingPathComponent("repo", isDirectory: true)
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let corpus = workspace.appendingPathComponent("corpus", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    try """
    setTimeout(() => {
      process.stdout.write(JSON.stringify({
        "$schema": "org2:agenda:v1",
        "range": { "start": "2026-06-12", "end": "2026-06-18", "days": 7 },
        "overdue": [],
        "days": [{ "date": "2026-06-12", "weekday": "Fri", "items": [] }],
        "skippedFiles": 0
      }));
    }, 120);
    """.write(to: dist.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)

    let note = corpus.appendingPathComponent("autosave-deferred-agenda.org2")
    try """
    #+TITLE: Autosave Deferred Agenda Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = WorkspaceStore(cli: Org2CLI(repoRoot: repoRoot))
    store.setCorpusRoot(corpus)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.updateEditingBlockDraft(paragraph, draft: "Updated body")
    await store.autosaveEditedBlock(paragraph, replacement: "Updated body")

    XCTAssertFalse(store.isLoadingAgenda)
    XCTAssertNil(store.agenda)
    XCTAssertNotNil(store.editingBlockID)

    try await Task.sleep(nanoseconds: 350_000_000)
    XCTAssertFalse(store.isLoadingAgenda)
    XCTAssertNil(store.agenda)

    store.cancelEditingBlock()
    try await waitForCondition(timeout: 5) {
      store.agenda?.totalItemCount == 0 && !store.isLoadingAgenda
    }
  }

  @MainActor
  func testAutosavesParagraphBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-autosave.org2")
    try """
    #+TITLE: Paragraph Autosave Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    let editingBlockID = try XCTUnwrap(store.editingBlockID)
    store.editableBlockText = "Updated body\nSecond line"
    store.updateEditingBlockDraft(paragraph, draft: "Updated body\nSecond line")
    await store.autosaveEditedBlock(paragraph, replacement: "Updated body\nSecond line")

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Updated body\nSecond line\n* Sibling"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.editingBlockID, editingBlockID)
    XCTAssertEqual(store.selectedBlock?.id, editingBlockID)
    XCTAssertEqual(store.selectedBlock?.endLineExclusive, paragraph.endLineExclusive + 1)
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated body\nSecond line")
    XCTAssertEqual(store.editableBlockText, "Updated body\nSecond line")
    let shiftedSibling = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered {
        return heading.title == "Sibling"
      }
      return false
    })
    XCTAssertEqual(shiftedSibling.startLine, 6)

    let expandedParagraph = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "Updated again\nSecond line"
    store.updateEditingBlockDraft(expandedParagraph, draft: "Updated again\nSecond line")
    await store.autosaveEditedBlock(expandedParagraph, replacement: "Updated again\nSecond line")

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Updated again\nSecond line\n* Sibling"))
    XCTAssertFalse(updated.contains("Updated again\nSecond line\nSecond line"))
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated body\nSecond line")
    XCTAssertEqual(store.editingBlockID, editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated again\nSecond line")
    XCTAssertNil(store.editingBlockID)
    XCTAssertEqual(store.selectedBlock?.id, editingBlockID)
  }

  @MainActor
  func testSameRangeAutosavePreservesRenderedBlockMetadata() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-same-range-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("same-range-autosave.org2")
    try """
    #+TITLE: Same Range Autosave Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    let originalSignature = store.selectedRenderedBlocksSignature
    let originalIndexes = store.selectedRenderedBlockIndexes

    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Updated body"
    store.updateEditingBlockDraft(paragraph, draft: "Updated body")
    await store.autosaveEditedBlock(paragraph, replacement: "Updated body")

    XCTAssertEqual(store.selectedRenderedBlocksSignature, originalSignature)
    XCTAssertEqual(store.selectedRenderedBlockIndexes, originalIndexes)
    XCTAssertEqual(store.selectedBlock?.id, paragraph.id)
    XCTAssertEqual(store.selectedBlock?.rawText, "Body")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* TODO Parent\nBody\n* Sibling") == true)
    XCTAssertFalse(store.selectedEntrySource?.text.contains("Updated body") == true)
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nUpdated body\n* Sibling"))

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedRenderedBlocksSignature, originalSignature)
    XCTAssertEqual(store.selectedRenderedBlockIndexes, originalIndexes)
    XCTAssertEqual(store.selectedBlock?.id, paragraph.id)
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated body")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* TODO Parent\nUpdated body\n* Sibling") == true)
  }

  @MainActor
  func testExplicitSaveFinalizesDeferredAutosaveInEntryScope() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-entry-autosave-save-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("entry-autosave-save.org2")
    try """
    #+TITLE: Entry Autosave Save Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)
    XCTAssertEqual(store.selectedEntrySourceMode, .entry)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.updateEditingBlockDraft(paragraph, draft: "Updated body")
    await store.autosaveEditedBlock(paragraph, replacement: "Updated body")

    XCTAssertEqual(store.editingBlockID, paragraph.id)
    XCTAssertTrue(store.canSaveActiveEdit)
    XCTAssertTrue((try String(contentsOf: note, encoding: .utf8)).contains("* TODO Parent\nUpdated body\n* Sibling"))
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* TODO Parent\nBody") == true)

    await store.saveEditedBlock(paragraph)

    XCTAssertNil(store.editingBlockID)
    XCTAssertFalse(store.canSaveActiveEdit)
    XCTAssertTrue(store.statusText.hasPrefix("Saved block"))
    XCTAssertEqual(store.selectedBlock?.rawText, "Updated body")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* TODO Parent\nUpdated body") == true)
    XCTAssertNotEqual(store.statusText, "Block save failed")
  }

  @MainActor
  func testStaleAutosaveDoesNotUpdateVisibleEditorState() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-stale-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("stale-autosave.org2")
    try """
    #+TITLE: Stale Autosave Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.updateEditingBlockDraft(paragraph, draft: "Still typing")

    await store.autosaveEditedBlock(paragraph, replacement: "Stale body")

    XCTAssertEqual(store.editingBlockID, paragraph.id)
    XCTAssertEqual(store.editableBlockText, "Body")
    XCTAssertEqual(store.selectedBlock?.rawText, "Body")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("Body") == true)
    XCTAssertFalse(store.selectedEntrySource?.text.contains("Stale body") == true)
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))
    XCTAssertFalse(updated.contains("Stale body"))
  }

  @MainActor
  func testEntrySourceReloadDoesNotDiscardActiveBlockDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-reload-active-block-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("reload-active-block.org2")
    try """
    #+TITLE: Reload Active Block Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.updateEditingBlockDraft(paragraph, draft: "Still typing")

    await store.loadEntrySource(for: .agenda(item))

    XCTAssertEqual(store.editingBlockID, paragraph.id)
    XCTAssertTrue(store.canSaveActiveEdit)
    XCTAssertEqual(store.selectedBlock?.id, paragraph.id)

    await store.saveActiveEdit()

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nStill typing\n* Sibling"))
    XCTAssertFalse(updated.contains("* TODO Parent\nBody\n* Sibling"))
  }

  @MainActor
  func testWorkspaceRefreshReloadsExternallyChangedSelectedFileAndHTML() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-refresh-selected-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("board-meeting.org2")
    let original = "#+TITLE: Board Meeting\n\n* Update\nOriginal summary\n"
    let external = "#+TITLE: Board Meeting\n\n* Update\nRevised by OpenClaw\n"
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)
    XCTAssertTrue(store.selectedEntryHTML?.contains("Original summary") == true)

    try external.write(to: note, atomically: true, encoding: .utf8)
    await store.refreshWorkspace()
    try await waitForCondition {
      store.selectedEntrySource?.text == external
        && store.selectedEntryHTML?.contains("Revised by OpenClaw") == true
    }

    XCTAssertFalse(store.selectedEntryHTML?.contains("Original summary") == true)
  }

  @MainActor
  func testWorkspaceRefreshIncludesDurableAgentRuns() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-refresh-agent-runs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cli = Org2CLI(repoRoot: try Org2CLI.defaultRepoRoot())
    _ = try await cli.run([
      "run", "create",
      "--id", "global-refresh-run",
      "--goal", "Verify the global refresh contract",
      "--dir", root.path,
      "--json"
    ])

    let store = WorkspaceStore(cli: cli)
    store.setCorpusRoot(root, persistsDefault: false)
    XCTAssertTrue(store.agentRuns.isEmpty)

    await store.refreshWorkspace()

    XCTAssertEqual(store.agentRuns.map(\.id), ["global-refresh-run"])
    XCTAssertFalse(store.isRefreshingWorkspace)
  }

  @MainActor
  func testWorkspaceRefreshContinuesPastSlowNoticeAndFinishes() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.workspaceRefreshSlowNoticeNanoseconds = 30_000_000
    let (gate, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    store.workspaceRefreshOperationForTesting = {
      for await _ in gate {}
    }
    let refresh = Task { await store.refreshWorkspace() }
    try await waitForCondition { store.statusText == WorkspaceStore.workspaceRefreshSlowNotice }

    XCTAssertTrue(store.isRefreshingWorkspace)
    XCTAssertNil(store.errorText)
    XCTAssertNil(store.approvalLoadErrorText)

    continuation.finish()
    await refresh.value

    XCTAssertFalse(store.isRefreshingWorkspace)
    XCTAssertEqual(store.statusText, "Workspace refresh finished.")
    XCTAssertNil(store.errorText)
  }

  @MainActor
  func testWorkspaceRefreshSlowNoticePreservesActualFailure() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.workspaceRefreshSlowNoticeNanoseconds = 0
    let (gate, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    store.workspaceRefreshOperationForTesting = {
      for await _ in gate {}
    }
    let refresh = Task { await store.refreshWorkspace() }
    try await waitForCondition { store.statusText == WorkspaceStore.workspaceRefreshSlowNotice }
    store.errorText = "Agenda could not be loaded."

    continuation.finish()
    await refresh.value

    XCTAssertFalse(store.isRefreshingWorkspace)
    XCTAssertEqual(store.errorText, "Agenda could not be loaded.")
    XCTAssertEqual(store.statusText, "Agenda could not be loaded.")
  }

  @MainActor
  func testWorkspaceRefreshCompletionCancelsPendingSlowNotice() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.workspaceRefreshSlowNoticeNanoseconds = 30_000_000
    store.workspaceRefreshOperationForTesting = {}

    await store.refreshWorkspace()
    try await Task.sleep(nanoseconds: 60_000_000)

    XCTAssertFalse(store.isRefreshingWorkspace)
    XCTAssertNotEqual(store.statusText, WorkspaceStore.workspaceRefreshSlowNotice)
    XCTAssertNil(store.errorText)
  }

  @MainActor
  func testWorkspaceRefreshCanBeCanceledManually() async throws {
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.workspaceRefreshSlowNoticeNanoseconds = 0
    store.workspaceRefreshOperationForTesting = {
      do {
        try await Task.sleep(nanoseconds: 5_000_000_000)
      } catch {
        return
      }
    }
    let refresh = Task { await store.refreshWorkspace() }
    try await waitForCondition { store.statusText == WorkspaceStore.workspaceRefreshSlowNotice }
    XCTAssertTrue(store.isRefreshingWorkspace)
    XCTAssertNil(store.errorText)

    store.cancelWorkspaceRefresh()
    await refresh.value

    XCTAssertFalse(store.isRefreshingWorkspace)
    XCTAssertTrue(store.statusText.localizedCaseInsensitiveContains("canceled"))
  }

  @MainActor
  func testLiveFileEditorReloadDoesNotDiscardUnsavedDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-reload-live-file-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("reload-live-file.org2")
    let original = """
    #+TITLE: Reload Live File

    * Parent
    Body
    """
    let draft = """
    #+TITLE: Reload Live File

    * Parent
    Still typing
    """
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    store.beginEditingCurrentScope()
    XCTAssertTrue(store.isEditingEntry)
    store.editableEntryText = draft
    store.noteSourceEditorLocalTextChanged(store.editableEntryText)
    await store.loadEntrySource(for: location)

    XCTAssertEqual(store.editableEntryText, draft)
    XCTAssertTrue(store.hasActiveEdit)

    await store.saveActiveEdit()
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), draft)
  }

  @MainActor
  func testWorkspaceRefreshDoesNotReplaceActiveSourceEditorBuffer() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-reload-clean-source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("reload-clean-source.org2")
    let original = "* Parent\nOriginal body\n"
    let external = "* Parent\nChanged elsewhere\n"
    try original.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)
    store.beginEditingCurrentScope()
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)

    try external.write(to: note, atomically: true, encoding: .utf8)
    await store.refreshWorkspace()

    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.editableEntryText, original)
    XCTAssertEqual(store.selectedEntrySource?.text, original)
    XCTAssertFalse(store.entryEditorHasUnsavedChanges)
  }

  @MainActor
  func testAutosavesHeadingBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-autosave.org2")
    try """
    #+TITLE: Heading Autosave Test

    * TODO [#A] Parent :work:
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": ["work"],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(heading)
    let replacement = "* DONE [#B] Renamed parent :work:focus:"
    store.updateEditingBlockDraft(heading, draft: replacement)
    await store.autosaveEditedBlock(heading, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE [#B] Renamed parent :work:focus:\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, "* TODO [#A] Parent :work:")
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    guard case .heading(let renderedHeading) = store.selectedBlock?.rendered else {
      return XCTFail("Expected heading block")
    }
    XCTAssertEqual(renderedHeading.todo, "DONE")
    XCTAssertEqual(renderedHeading.priority, "B")
    XCTAssertEqual(renderedHeading.title, "Renamed parent")
    XCTAssertEqual(renderedHeading.tags, ["work", "focus"])
  }

  @MainActor
  func testAutosavesPlanningBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-planning-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("planning-autosave.org2")
    try """
    #+TITLE: Planning Autosave Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let planning = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .planning = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(planning)
    let replacement = "DEADLINE: <2026-06-15 Mon>"
    store.updateEditingBlockDraft(planning, draft: replacement)
    await store.autosaveEditedBlock(planning, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("DEADLINE: <2026-06-15 Mon>\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, "SCHEDULED: <2026-06-12 Fri>")
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    guard case .planning(let renderedPlanning) = store.selectedBlock?.rendered else {
      return XCTFail("Expected planning block")
    }
    XCTAssertEqual(renderedPlanning.kind, "DEADLINE")
    XCTAssertEqual(renderedPlanning.value, "<2026-06-15 Mon>")
  }

  @MainActor
  func testAutosavesKeywordBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-keyword-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("keyword-autosave.org2")
    try """
    * TODO Parent
    #+CAPTION: Old Caption
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let keyword = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .keyword(let key, _) = $0.rendered { return key == "CAPTION" }
      return false
    })
    store.beginEditingBlock(keyword)
    let replacement = "#+CAPTION: New Caption"
    store.updateEditingBlockDraft(keyword, draft: replacement)
    await store.autosaveEditedBlock(keyword, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\n#+CAPTION: New Caption\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, "#+CAPTION: Old Caption")
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    guard case .keyword(let key, let value) = store.selectedBlock?.rendered else {
      return XCTFail("Expected keyword block")
    }
    XCTAssertEqual(key, "CAPTION")
    XCTAssertEqual(value, "New Caption")
  }

  @MainActor
  func testAutosavesPropertyDrawerWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-property-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("property-autosave.org2")
    try """
    * TODO Parent
    :PROPERTIES:
    :OWNER: avi
    :STATUS: draft
    :END:
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": { "OWNER": "avi", "STATUS": "draft" }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let properties = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .properties = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(properties)
    let replacement = """
    :PROPERTIES:
    :OWNER: openclaw
    :STATUS: active
    :END:
    """
    store.updateEditingBlockDraft(properties, draft: replacement)
    await store.autosaveEditedBlock(properties, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains(":OWNER: openclaw\n:STATUS: active\n:END:\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, properties.rawText)
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    guard case .properties(let rows) = store.selectedBlock?.rendered else {
      return XCTFail("Expected property drawer")
    }
    XCTAssertEqual(rows, [
      OrgPropertyRow(key: "OWNER", value: "openclaw"),
      OrgPropertyRow(key: "STATUS", value: "active")
    ])
  }

  @MainActor
  func testSetsRenderedPropertyValueInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-rendered-property-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("rendered-property.org2")
    try """
    * TODO Parent
    :PROPERTIES:
    :OWNER: agent
    :ID: 11111111-1111-4111-8111-111111111111
    :END:
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {
        "OWNER": "agent",
        "ID": "11111111-1111-4111-8111-111111111111"
      }
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let properties = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .properties = $0.rendered { return true }
      return false
    })
    await store.setPropertyValue(properties, key: "OWNER", value: "avi")

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains(":OWNER: avi\n:ID: 11111111-1111-4111-8111-111111111111\n:END:\nBody"))
    try await waitForCondition {
      store.selectedRenderedBlocks.contains {
        if case .properties(let rows) = $0.rendered {
          return rows.contains(OrgPropertyRow(key: "OWNER", value: "avi"))
        }
        return false
      }
    }
    let updatedProperties = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .properties = $0.rendered { return true }
      return false
    })
    guard case .properties(let rows) = updatedProperties.rendered else {
      return XCTFail("Expected property drawer")
    }
    XCTAssertEqual(rows, [
      OrgPropertyRow(key: "OWNER", value: "avi"),
      OrgPropertyRow(key: "ID", value: "11111111-1111-4111-8111-111111111111")
    ])
  }

  @MainActor
  func testAutosavesQuoteBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-quote-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("quote-autosave.org2")
    try """
    * TODO Parent
    #+begin_quote
    Old quote
    #+end_quote
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let quote = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .quote = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(quote)
    let replacement = """
    #+begin_quote
    New quote
    With second line
    #+end_quote
    """
    store.updateEditingBlockDraft(quote, draft: replacement)
    await store.autosaveEditedBlock(quote, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("New quote\nWith second line\n#+end_quote\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertEqual(store.editableBlockText, replacement)
    XCTAssertNotNil(store.editingBlockID)
    guard case .quote(let lines) = store.selectedBlock?.rendered else {
      return XCTFail("Expected quote block")
    }
    XCTAssertEqual(lines, ["New quote", "With second line"])
  }

  @MainActor
  func testAutosavesMediaBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-media-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("media-autosave.org2")
    try """
    * TODO Parent
    [[file:images/old.png][Old image]]

    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let media = try XCTUnwrap(store.selectedRenderedBlocks.first {
      OrgEditableMediaLink(rawText: $0.rawText) != nil
    })
    store.beginEditingBlock(media)
    let replacement = "[[file:images/new.png][New image]]"
    store.updateEditingBlockDraft(media, draft: replacement)
    await store.autosaveEditedBlock(media, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\n[[file:images/new.png][New image]]\n\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, media.rawText)
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
    let editedMedia = try XCTUnwrap(OrgEditableMediaLink(rawText: store.selectedBlock?.rawText ?? ""))
    XCTAssertEqual(editedMedia.target, "file:images/new.png")
    XCTAssertEqual(editedMedia.label, "New image")
  }

  @MainActor
  func testAutosavesTableBlockWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-table-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("table-autosave.org2")
    try """
    * TODO Parent
    | Name | Value |
    |------+-------|
    | Alice | 42 |
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let table = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .table = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(table)
    let replacement = """
    | Name  | Value | Owner |
    |-------+-------+-------|
    | Alice | 43    | Avi   |
    | Bob   | 12    | Bot   |
    """
    store.updateEditingBlockDraft(table, draft: replacement)
    await store.autosaveEditedBlock(table, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("| Alice | 43    | Avi   |\n| Bob   | 12    | Bot   |\nBody"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertEqual(store.editableBlockText, replacement)
    XCTAssertNotNil(store.editingBlockID)
    guard case .table(let renderedTable) = store.selectedBlock?.rendered else {
      return XCTFail("Expected table block")
    }
    XCTAssertEqual(renderedTable.rows, [
      .cells(["Name", "Value", "Owner"]),
      .separator,
      .cells(["Alice", "43", "Avi"]),
      .cells(["Bob", "12", "Bot"])
    ])
  }

  @MainActor
  func testSplitsEditingParagraphAtCaretIntoNewEditableBlock() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-split-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-split.org2")
    try """
    #+TITLE: Block Split Test

    * TODO Parent
    Alpha beta gamma
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Alpha beta gamma",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "Alpha beta gamma" }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Alpha beta gamma"

    await store.splitEditingBlock(paragraph, atUTF16Offset: 6)
    try await waitForCondition {
      store.isEditingEntry
        && store.editingBlockID == nil
        && store.editableEntryText.contains("Alpha\n\nbeta gamma")
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha\n\nbeta gamma\n* Sibling"))
    XCTAssertEqual(
      store.sourceEditorSelection,
      NSRange(location: ("* TODO Parent\nAlpha\n\n" as NSString).length, length: 0)
    )
  }

  @MainActor
  func testSplitsEditingParagraphUsingNonPublishedInlineDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-nonpublished-split-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-nonpublished-split.org2")
    try """
    #+TITLE: Paragraph Nonpublished Split Test

    * TODO Parent
    Alpha beta gamma
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Alpha beta gamma",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "Alpha beta gamma" }
      return false
    })
    store.beginEditingBlock(paragraph)
    XCTAssertEqual(store.editableBlockText, "Alpha beta gamma")

    store.updateEditingBlockDraft(paragraph, draft: "Alpha edited beta")
    XCTAssertEqual(store.editableBlockText, "Alpha beta gamma")
    await store.splitEditingBlock(paragraph, atUTF16Offset: 6)
    try await waitForCondition {
      store.isEditingEntry
        && store.editingBlockID == nil
        && store.editableEntryText.contains("Alpha\n\nedited beta")
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha\n\nedited beta\n* Sibling"))
    XCTAssertEqual(
      store.sourceEditorSelection,
      NSRange(location: ("* TODO Parent\nAlpha\n\n" as NSString).length, length: 0)
    )
  }

  @MainActor
  func testContinuesParagraphWithUnsavedDraftBlock() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-draft.org2")
    try """
    #+TITLE: Paragraph Draft Test

    * TODO Parent
    Alpha beta
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Alpha beta",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "Alpha beta" }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Alpha beta"

    await store.splitEditingBlock(paragraph, atUTF16Offset: (store.editableBlockText as NSString).length)
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlock?.id
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("New text"))
    XCTAssertTrue(updated.contains("Alpha beta\n* Sibling"))

    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "Next paragraph"
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "Next paragraph"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha beta\n\nNext paragraph\n* Sibling"))
  }

  @MainActor
  func testReturnAfterTypingHeadingInEmptyDraftStartsEmptyDraftWithoutReusingEditorState() async throws {
    try XCTSkipIf(true, "Rendered inline text editing is retired from normal UI entry points; source editing is primary.")
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-return-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-return.org2")
    try "".write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    await store.beginAppendingSectionAtEnd()
    let originalDraft = try XCTUnwrap(store.selectedBlock)
    XCTAssertEqual(originalDraft.rawText, "")

    let typedHeading = "* testing this 123"
    store.updateEditingBlockDraft(originalDraft, draft: typedHeading)
    await store.splitEditingBlock(
      originalDraft,
      atUTF16Offset: (typedHeading as NSString).length,
      draftText: typedHeading
    )

    try await waitForCondition {
      store.selectedBlock?.rawText == ""
        && store.selectedBlock?.id != originalDraft.id
        && store.selectedRenderedBlocks.filter { $0.rawText == typedHeading }.count == 1
    }
    let nextDraft = try XCTUnwrap(store.selectedBlock)
    XCTAssertEqual(nextDraft.rawText, "")
    XCTAssertNotEqual(nextDraft.id, originalDraft.id)
    XCTAssertEqual(
      store.selectedRenderedBlocks.filter { $0.rawText == typedHeading }.count,
      1
    )

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertEqual(updated.components(separatedBy: typedHeading).count - 1, 1)
    XCTAssertTrue(updated.contains(typedHeading))
  }

  @MainActor
  func testSavesInsertedParagraphDraftPublishedFromEditor() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-insert-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-insert-draft.org2")
    try """
    #+TITLE: Paragraph Insert Draft Test

    * TODO Parent
    https://x.com/sdhilip/status/2069140867466797200?s=46&t=8JLnk5l_ZQz2KJfqZ5W_jQ
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "https://x.com/sdhilip/status/2069140867466797200?s=46&t=8JLnk5l_ZQz2KJfqZ5W_jQ",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    await store.insertBlock(after: paragraph, kind: .paragraph)
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlock?.id
    }

    let draft = try XCTUnwrap(store.selectedBlock)
    store.updateEditingBlockDraft(draft, draft: "https://altic.dev/fluid")
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "https://altic.dev/fluid"
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("""
    https://x.com/sdhilip/status/2069140867466797200?s=46&t=8JLnk5l_ZQz2KJfqZ5W_jQ

    https://altic.dev/fluid
    * Sibling
    """))
  }

  @MainActor
  func testContinuesEditingChecklistItemWithUncheckedSibling() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-list-continue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("list-continue.org2")
    try """
    #+TITLE: List Continue Test

    * TODO Parent
    - [X] Done task
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "- [X] Done task",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let task = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, .checked, let text) = $0.rendered { return text == "Done task" }
      return false
    })
    store.beginEditingBlock(task)
    store.editableBlockText = "- [X] Done task"

    await store.splitEditingBlock(task, atUTF16Offset: (store.editableBlockText as NSString).length)
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [ ] " && store.editingBlockID == store.selectedBlock?.id
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("New item"))
    XCTAssertTrue(updated.contains("- [X] Done task\n* Sibling"))
    XCTAssertEqual(store.editableBlockText, "- [ ] ")

    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "- [ ] Follow up"
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [ ] Follow up"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [X] Done task\n- [ ] Follow up\n* Sibling"))
  }

  @MainActor
  func testDeleteBackwardAtStartMergesParagraphWithPreviousParagraph() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-paragraph-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("paragraph-merge.org2")
    try """
    #+TITLE: Paragraph Merge Test

    * TODO Parent
    Alpha

    beta
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Alpha\\n\\nbeta",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let beta = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "beta" }
      return false
    })
    store.beginEditingBlock(beta)
    store.updateEditingBlockDraft(beta, draft: "beta edited")

    await store.deleteBackwardFromStartOfEditingBlock(beta, draftText: "beta edited")
    try await waitForCondition {
      store.selectedBlock?.rawText == "Alpha beta edited" && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha beta edited\n* Sibling"))
    XCTAssertFalse(updated.contains("Alpha\n\nbeta"))
  }

  @MainActor
  func testDeleteBackwardAtStartMergesListItemWithPreviousListItem() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-list-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("list-merge.org2")
    try """
    #+TITLE: List Merge Test

    * TODO Parent
    - [X] Done task
    - [ ] Follow up
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "- [X] Done task\\n- [ ] Follow up",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let followUp = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, .unchecked, let text) = $0.rendered { return text == "Follow up" }
      return false
    })
    store.beginEditingBlock(followUp)
    store.updateEditingBlockDraft(followUp, draft: "- [ ] Follow up edited")

    await store.deleteBackwardFromStartOfEditingBlock(followUp, draftText: "- [ ] Follow up edited")
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [X] Done task Follow up edited"
        && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [X] Done task Follow up edited\n* Sibling"))
    XCTAssertFalse(updated.contains("- [ ] Follow up"))
  }

  @MainActor
  func testDeleteBackwardAtStartMergesHeadingTitleIntoPreviousTextBlock() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-merge.org2")
    try """
    #+TITLE: Heading Merge Test

    * TODO Parent
    Intro paragraph
    ** Child heading
    Child body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Intro paragraph\\n** Child heading\\nChild body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let childHeading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.title == "Child heading" }
      return false
    })
    store.beginEditingBlock(childHeading)

    await store.deleteBackwardFromStartOfEditingBlock(childHeading, draftText: "** Child heading")
    try await waitForCondition {
      store.selectedBlock?.rawText == "Intro paragraph Child heading\nChild body"
        && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Intro paragraph Child heading\nChild body\n* Sibling"))
    XCTAssertFalse(updated.contains("** Child heading"))
  }

  @MainActor
  func testDeleteBackwardAtStartMergesParagraphIntoPreviousHeading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-absorb-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-absorb.org2")
    try """
    #+TITLE: Heading Absorb Test

    * TODO Parent :work:
    First body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "First body",
      "level": 1,
      "tags": ["work"],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "First body" }
      return false
    })
    store.beginEditingBlock(paragraph)

    await store.deleteBackwardFromStartOfEditingBlock(paragraph, draftText: "First body")
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO Parent First body :work:"
        && store.editingBlockID == store.selectedBlock?.id
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent First body :work:\n* Sibling"))
    XCTAssertFalse(updated.contains("* TODO Parent :work:\nFirst body"))
  }

  @MainActor
  func testDeleteBackwardAtStartDiscardsEmptyTransientParagraphDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-empty-draft-delete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("empty-draft-delete.org2")
    try """
    #+TITLE: Empty Draft Delete Test

    * TODO Parent
    Alpha beta
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Alpha beta",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph(let text) = $0.rendered { return text == "Alpha beta" }
      return false
    })
    store.beginEditingBlock(paragraph)
    await store.splitEditingBlock(paragraph, atUTF16Offset: (paragraph.rawText as NSString).length)
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlock?.id
    }

    let draft = try XCTUnwrap(store.selectedBlock)
    await store.deleteBackwardFromStartOfEditingBlock(draft, draftText: "")
    try await waitForCondition {
      store.selectedBlock?.rawText == "Alpha beta" && store.editingBlockID == nil
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Alpha beta\n* Sibling"))
    XCTAssertFalse(updated.contains("Alpha beta\n\n* Sibling"))
  }

  @MainActor
  func testAutosavesListItemWithoutLeavingInlineEditMode() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-list-autosave-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("list-autosave.org2")
    try """
    #+TITLE: List Autosave Test

    * TODO Parent
    - [ ] Open task
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "- [ ] Open task",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let task = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, .unchecked, let text) = $0.rendered { return text == "Open task" }
      return false
    })
    store.beginEditingBlock(task)
    let replacement = "- [X] Closed task"
    store.updateEditingBlockDraft(task, draft: replacement)
    await store.autosaveEditedBlock(task, replacement: replacement)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [X] Closed task\n* Sibling"))
    XCTAssertFalse(store.isEditingEntry)
    XCTAssertEqual(store.selectedBlock?.rawText, task.rawText)
    XCTAssertNotNil(store.editingBlockID)

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedBlock?.rawText, replacement)
    XCTAssertNil(store.editingBlockID)
  }

  @MainActor
  func testInsertsBlockAfterRenderedBlockInsideSelectedEntry() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-insert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-insert.org2")
    try """
    #+TITLE: Block Insert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    await store.insertBlock(after: paragraph, kind: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO " && store.editingBlockID == store.selectedBlock?.id
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("New task"))
    XCTAssertTrue(updated.contains("Body\n* Sibling"))
    guard case .heading(let selectedHeading) = store.selectedBlock?.rendered else {
      return XCTFail("Expected inserted heading to be selected")
    }
    XCTAssertEqual(selectedHeading.title, "")
    XCTAssertEqual(selectedHeading.todo, "TODO")
    XCTAssertEqual(store.editableBlockText, "** TODO ")

    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "** TODO Call Bob"
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n** TODO Call Bob\n* Sibling"))
  }

  @MainActor
  func testInsertsAndConvertsMediaBlocksAsOrgLinks() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-media-insert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("media-insert.org2")
    try """
    #+TITLE: Media Insert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })

    await store.insertBlock(after: paragraph, kind: .image)
    try await waitForCondition {
      store.selectedBlock?.rawText == "[[file:images/image.png][Image]]"
        && store.editingBlockID == store.selectedBlockID
    }
    XCTAssertEqual(store.editableBlockText, "[[file:images/image.png][Image]]")

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("images/image.png"))
    let imageDraft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(imageDraft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "[[file:images/image.png][Image]]"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n[[file:images/image.png][Image]]\n* Sibling"))

    let insertedImage = try XCTUnwrap(store.selectedBlock)
    store.beginEditingBlock(insertedImage)
    store.editableBlockText = "/video media/demo.mp4"

    await store.convertEditingBlock(insertedImage, to: .video)
    try await waitForCondition {
      store.selectedBlock?.rawText == "[[file:media/demo.mp4][demo.mp4]]"
        && store.editingBlockID == store.selectedBlockID
    }
    let videoDraft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(videoDraft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "[[file:media/demo.mp4][demo.mp4]]"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n[[file:media/demo.mp4][demo.mp4]]\n* Sibling"))
    XCTAssertFalse(updated.contains("images/image.png"))
  }

  @MainActor
  func testInsertsAndConvertsDividerBlocks() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-divider-insert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("divider-insert.org2")
    try """
    #+TITLE: Divider Insert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })

    await store.insertBlock(after: paragraph, kind: .divider)
    try await waitForCondition {
      store.selectedBlock?.rawText == "-----" && store.editingBlockID == store.selectedBlockID
    }
    guard case .horizontalRule = store.selectedBlock?.rendered else {
      return XCTFail("Expected divider draft")
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("-----"))
    let dividerDraft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(dividerDraft)
    try await waitForCondition {
      if case .horizontalRule = store.selectedBlock?.rendered {
        return store.selectedBlock?.rawText == "-----"
      }
      return false
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n-----\n* Sibling"))

    let divider = try XCTUnwrap(store.selectedBlock)
    store.beginEditingBlock(divider)
    store.editableBlockText = "/todo Replace divider"
    await store.convertEditingBlock(divider, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Replace divider" && store.editingBlockID == store.selectedBlockID
    }
    let todoDraft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(todoDraft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Replace divider"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\n** TODO Replace divider\n* Sibling"))
    XCTAssertFalse(updated.contains("-----"))
  }

  @MainActor
  func testConvertsEditingParagraphWithSlashCommand() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-convert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-convert.org2")
    try """
    #+TITLE: Block Convert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "/todo Call Bob"

    await store.convertEditingBlock(paragraph, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob" && store.editingBlockID == store.selectedBlockID
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))
    XCTAssertFalse(updated.contains("** TODO Call Bob"))
    XCTAssertEqual(store.editableBlockText, "** TODO Call Bob")

    store.cancelEditingBlock()
    XCTAssertEqual(store.selectedRenderedBlocks.first(where: { $0.id == paragraph.id })?.rawText, "Body")
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))

    store.beginEditingBlock(paragraph)
    store.editableBlockText = "/todo Call Bob"
    await store.convertEditingBlock(paragraph, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob" && store.editingBlockID == store.selectedBlockID
    }
    let draft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\n** TODO Call Bob\n* Sibling"))
    XCTAssertNil(store.editingBlockID)
  }

  @MainActor
  func testConvertsEditingParagraphUsingNonPublishedInlineDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-convert-nonpublished-draft-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("convert-nonpublished-draft.org2")
    try """
    #+TITLE: Convert Nonpublished Draft Test

    * TODO Parent
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    XCTAssertEqual(store.editableBlockText, "Body")

    store.updateEditingBlockDraft(paragraph, draft: "/todo Call Bob")
    XCTAssertEqual(store.editableBlockText, "Body")
    await store.convertEditingBlock(paragraph, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO Call Bob" && store.editingBlockID == store.selectedBlockID
    }
  }

  @MainActor
  func testEmptySlashTodoDraftDoesNotSavePlaceholderHeading() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-empty-slash-todo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("empty-slash-todo.org2")
    try """
    #+TITLE: Empty Slash TODO Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "/todo"

    await store.convertEditingBlock(paragraph, to: .todo)
    try await waitForCondition {
      store.selectedBlock?.rawText == "** TODO " && store.editingBlockID == store.selectedBlockID
    }

    let draft = try XCTUnwrap(store.selectedBlock)
    await store.saveEditedBlock(draft)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))
    XCTAssertFalse(updated.contains("New task"))
    XCTAssertFalse(updated.contains("** TODO \n"))
    XCTAssertEqual(store.selectedRenderedBlocks.first(where: { $0.id == paragraph.id })?.rawText, "Body")
  }

  @MainActor
  func testDuplicatesDeletesAndMovesRenderedBlocks() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-actions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-actions.org2")
    try """
    #+TITLE: Block Actions Test

    * TODO Parent
    Body
    - One
    - Two
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let one = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, _, let text) = $0.rendered { return text == "One" }
      return false
    })
    XCTAssertTrue(store.canMoveBlock(one, direction: .down))

    await store.moveBlock(one, direction: .down)
    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- Two\n- One\n* Sibling"))
    XCTAssertEqual(store.selectedBlock?.rawText, "- One")
    XCTAssertEqual(store.selectedBlock?.startLine, one.startLine + 1)
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "3-6")

    let movedOne = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, _, let text) = $0.rendered { return text == "One" }
      return false
    })
    await store.duplicateBlock(movedOne)
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- Two\n- One\n\n- One\n* Sibling"))
    XCTAssertEqual(store.selectedBlock?.rawText, "- One")
    XCTAssertEqual(store.selectedBlock?.startLine, movedOne.endLineExclusive + 1)
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "3-8")

    let duplicatedOne = try XCTUnwrap(store.selectedRenderedBlocks
      .filter {
        if case .listItem(_, _, _, let text) = $0.rendered { return text == "One" }
        return false
      }
      .max { $0.startLine < $1.startLine })
    await store.deleteBlock(duplicatedOne)
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- Two\n- One\n* Sibling"))
    XCTAssertFalse(updated.contains("- One\n\n- One"))
    XCTAssertEqual(store.selectedBlock?.rawText, "- One")
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "3-6")
  }

  @MainActor
  func testTogglesRenderedListItemCheckboxInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-checkbox-toggle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("checkbox-toggle.org2")
    try """
    #+TITLE: Checkbox Toggle Test

    * TODO Parent
    - [ ] Open task
    - [X] Done task
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "- [ ] Open task",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let openTask = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .listItem(_, _, .unchecked, let text) = $0.rendered { return text == "Open task" }
      return false
    })

    await store.toggleListItemCheckbox(openTask)
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [X] Open task"
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [X] Open task\n- [X] Done task"))

    let toggledTask = try XCTUnwrap(store.selectedBlock)
    await store.toggleListItemCheckbox(toggledTask)
    try await waitForCondition {
      store.selectedBlock?.rawText == "- [ ] Open task"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("- [ ] Open task\n- [X] Done task"))
  }

  @MainActor
  func testRenderedDocumentCheckboxWritesAndRejectsAStaleSourceLine() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-html-checkbox-toggle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("groceries.org")
    try """
    * Groceries
    - [ ] Sriracha
    - [ ] Ginger
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Groceries",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "- [ ] Sriracha\\n- [ ] Ginger",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    let renderCalls = ThreadSafeIntRecorder()
    store.entryHTMLRendererForTesting = { _, _, _, _ in
      renderCalls.append(1)
      return "<html><body>Stable rendered page</body></html>"
    }
    store.setCorpusRoot(root)
    store.selectedEntrySourceMode = .page
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)
    let initialHTML = store.selectedEntryHTML
    let initialRenderIdentity = store.selectedEntryHTMLRenderIdentity
    XCTAssertEqual(renderCalls.count, 1)

    await store.setRenderedDocumentCheckbox(at: 2, checked: true)
    try await waitForCondition {
      (try? String(contentsOf: note, encoding: .utf8).contains("- [X] Sriracha")) == true
    }
    XCTAssertEqual(store.statusText, "Marked complete")
    XCTAssertTrue(store.selectedEntrySource?.text.contains("- [X] Sriracha") == true)
    XCTAssertTrue(store.selectedRenderedBlocks.contains { block in
      if case .listItem(_, _, .checked, let text) = block.rendered {
        return text == "Sriracha"
      }
      return false
    })
    await store.applyIncrementalCorpusChangesForTesting([note.path])
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertEqual(store.selectedEntryHTML, initialHTML)
    XCTAssertEqual(store.selectedEntryHTMLRenderIdentity, initialRenderIdentity)
    XCTAssertEqual(renderCalls.count, 1)

    let externallyChanged = try String(contentsOf: note, encoding: .utf8)
      .replacingOccurrences(of: "- [ ] Ginger", with: "- [ ] Fresh ginger")
    try externallyChanged.write(to: note, atomically: true, encoding: .utf8)

    await store.setRenderedDocumentCheckbox(at: 3, checked: true)
    let preserved = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(preserved.contains("- [ ] Fresh ginger"))
    XCTAssertFalse(preserved.contains("- [X] Fresh ginger"))
    XCTAssertEqual(store.statusText, "Checkbox update failed")
  }

  @MainActor
  func testTogglesRenderedHeadingTodoInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-todo-toggle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-todo-toggle.org2")
    try """
    #+TITLE: Heading TODO Toggle Test

    * TODO Parent
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.todo == "TODO" }
      return false
    })

    await store.toggleHeadingTodo(heading)
    try await waitForCondition {
      store.selectedBlock?.rawText == "* DONE Parent"
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* DONE Parent\nCLOSED:"))
    XCTAssertTrue(updated.contains("\nBody\n* Sibling"))

    let doneHeading = try XCTUnwrap(store.selectedBlock)
    await store.toggleHeadingTodo(doneHeading)
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO Parent"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody\n* Sibling"))
  }

  @MainActor
  func testSetsRenderedHeadingPriorityInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-priority-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-priority.org2")
    try """
    #+TITLE: Heading Priority Test

    * TODO [#A] Parent :work:
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": ["work"],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.priority == "A" }
      return false
    })

    await store.setHeadingPriority(heading, priority: "C")
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO [#C] Parent :work:"
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO [#C] Parent :work:\nBody\n* Sibling"))

    let updatedHeading = try XCTUnwrap(store.selectedBlock)
    await store.setHeadingPriority(updatedHeading, priority: nil)
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO Parent :work:"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent :work:\nBody\n* Sibling"))
  }

  @MainActor
  func testSetsRenderedHeadingTagsInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-heading-tags-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("heading-tags.org2")
    try """
    #+TITLE: Heading Tags Test

    * TODO [#A] Parent :work:
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": ["work"],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.tags == ["work"] }
      return false
    })

    await store.setHeadingTags(heading, tags: ["work", "focus", "work", "bad tag"])
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO [#A] Parent :work:focus:"
    }

    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO [#A] Parent :work:focus:\nBody\n* Sibling"))

    let taggedHeading = try XCTUnwrap(store.selectedBlock)
    await store.setHeadingTags(taggedHeading, tags: [])
    try await waitForCondition {
      store.selectedBlock?.rawText == "* TODO [#A] Parent"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO [#A] Parent\nBody\n* Sibling"))
  }

  @MainActor
  func testSetsRenderedPlanningBlockInSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-rendered-planning-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("rendered-planning.org2")
    try """
    #+TITLE: Rendered Planning Test

    * TODO Parent
    SCHEDULED: <2026-06-12 Fri>
    Body
    * Sibling
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let planning = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .planning(let planning) = $0.rendered { return planning.kind == "SCHEDULED" }
      return false
    })

    await store.setPlanningBlock(planning, kind: "DEADLINE", value: "<2026-06-15 Mon 09:30>")
    try await waitForCondition {
      store.selectedBlock?.rawText == "DEADLINE: <2026-06-15 Mon 09:30>"
    }

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nDEADLINE: <2026-06-15 Mon 09:30>\nBody\n* Sibling"))
  }

  @MainActor
  func testSelectsRenderedBlockAndHandlesDocumentKeyboard() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-block-selection-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("block-selection.org2")
    try """
    #+TITLE: Block Selection Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading = $0.rendered { return true }
      return false
    })
    store.selectBlock(paragraph)
    XCTAssertEqual(store.selectedBlock?.id, paragraph.id)

    XCTAssertTrue(store.canSelectAdjacentBlock(.up))
    XCTAssertFalse(store.canSelectAdjacentBlock(.down))
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "k", keyCode: 40)))
    XCTAssertEqual(store.selectedBlock?.id, heading.id)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 125)))
    XCTAssertEqual(store.selectedBlock?.id, paragraph.id)

    store.selectBlock(heading)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 123)))
    XCTAssertTrue(store.foldedRenderedBlockIDs.contains(heading.id))
    XCTAssertFalse(store.canSelectAdjacentBlock(.down))
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 124)))
    XCTAssertFalse(store.foldedRenderedBlockIDs.contains(heading.id))
    XCTAssertTrue(store.canSelectAdjacentBlock(.down))

    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 123, modifiers: [.command])))
    XCTAssertEqual(store.selectedBlock?.id, heading.id)
    XCTAssertTrue(store.foldedRenderedBlockIDs.contains(heading.id))
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 124, modifiers: [.command])))
    XCTAssertTrue(store.foldedRenderedBlockIDs.isEmpty)

    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(keyCode: 53)))
    XCTAssertNil(store.selectedBlockID)

    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "\r", keyCode: 36)))
    XCTAssertNil(store.editingBlockID)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.editableEntryText, "* TODO Parent\nBody")
    XCTAssertEqual(store.sourceEditorSelection, NSRange(location: 14, length: 0))
    XCTAssertTrue(store.hasActiveEdit)
    XCTAssertFalse(store.canSaveActiveEdit)
    XCTAssertFalse(store.handleDocumentKeyDown(keyDown(characters: "\u{7F}", keyCode: 51)))

    store.cancelActiveEdit()
    XCTAssertFalse(store.hasActiveEdit)
    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "!", keyCode: 18)))
    XCTAssertNil(store.editingBlockID)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.editableEntryText, "* TODO Parent\nBody!")
    XCTAssertEqual(store.sourceEditorSelection, NSRange(location: 19, length: 0))

    store.cancelActiveEdit()
    XCTAssertNil(store.editingBlockID)
    XCTAssertFalse(store.isEditingEntry)

    store.selectBlock(heading)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "!", keyCode: 18)))
    XCTAssertNil(store.editingBlockID)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.editableEntryText, "* TODO Parent!\nBody")
    XCTAssertEqual(store.sourceEditorSelection, NSRange(location: 14, length: 0))

    store.cancelActiveEdit()
    XCTAssertNil(store.editingBlockID)
    XCTAssertFalse(store.isEditingEntry)

    store.selectBlock(paragraph)
    store.beginEditingCurrentScope()
    XCTAssertNil(store.editingBlockID)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.sourceEditorSelection, NSRange(location: 14, length: 0))

    store.cancelActiveEdit()
    XCTAssertNil(store.editingBlockID)
    XCTAssertFalse(store.isEditingEntry)

    store.selectBlock(paragraph)
    XCTAssertFalse(store.isEditingEntry)
    store.selectedSurface = .agenda
    XCTAssertTrue(store.handleAgendaKeyDown(keyDown(characters: "e", keyCode: 14)))
    XCTAssertNil(store.editingBlockID)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.sourceEditorSelection, NSRange(location: 14, length: 0))

    store.cancelActiveEdit()
    store.clearSelectedBlock()
    store.beginEditingVisibleBlock()
    XCTAssertNil(store.editingBlockID)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.sourceEditorSelection, NSRange(location: 0, length: 0))
  }

  @MainActor
  func testRenderedSelectionReplacementReopensSourceEditor() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-rendered-selection-source-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("rendered-selection.org2")
    try """
    * Parent
    Alpha beta
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": null,
      "headline": "Parent",
      "kind": "entry",
      "file": "\(note.path)",
      "line": 1,
      "body": "Alpha beta",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """
    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    let paragraphText = paragraph.rawText as NSString
    let betaRange = paragraphText.range(of: "beta")
    let fragment = OrgSyntaxTextSelectionDocumentFragment(
      context: OrgSyntaxTextSelectionContext(
        blockID: paragraph.id,
        startLine: paragraph.startLine,
        endLineExclusive: paragraph.endLineExclusive,
        editorToSourceUTF16Offset: 0
      ),
      editorRange: betaRange,
      editorUTF16Length: paragraphText.length,
      editorText: paragraph.rawText
    )

    await store.replaceRenderedTextSelection([fragment], replacementText: "BETA")

    XCTAssertNil(store.editingBlockID)
    XCTAssertTrue(store.isEditingEntry)
    XCTAssertEqual(store.editableEntryText, "* Parent\nAlpha BETA")
    XCTAssertEqual(
      store.sourceEditorSelection,
      NSRange(location: ("* Parent\nAlpha BETA" as NSString).length, length: 0)
    )
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "* Parent\nAlpha BETA")
  }

  @MainActor
  func testAppendingBelowCollapsedFinalHeadingRevealsDraftEditor() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-collapsed-append-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("collapsed-append.org2")
    try """
    * Current
    Hidden body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading = $0.rendered { return true }
      return false
    })
    store.selectBlock(heading)
    XCTAssertTrue(store.collapseSelectedRenderedBlock())
    XCTAssertTrue(store.foldedRenderedBlockIDs.contains(heading.id))

    await store.beginAppendingSectionAtEnd()

    let draftID = try XCTUnwrap(store.selectedBlockID)
    XCTAssertEqual(store.editingBlockID, draftID)
    XCTAssertFalse(store.foldedRenderedBlockIDs.contains(heading.id))
    XCTAssertTrue(OrgRenderedFoldTree.visibleBlocks(
      store.selectedRenderedBlocks,
      foldedBlockIDs: store.foldedRenderedBlockIDs
    ).contains { $0.id == draftID })
  }

  @MainActor
  func testInsertingAfterCollapsedHeadingRevealsDraftEditor() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-collapsed-insert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("collapsed-insert.org2")
    try """
    * Current
    Hidden body
    """.write(to: note, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectCorpusFile(CorpusFile(
      path: note.path,
      relativePath: note.lastPathComponent,
      modifiedAt: nil,
      byteCount: nil
    ))
    let location = try XCTUnwrap(store.selectedLocation)
    await store.loadEntrySource(for: location)
    try await waitForEntryRender(store)

    let heading = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading = $0.rendered { return true }
      return false
    })
    store.selectBlock(heading)
    XCTAssertTrue(store.collapseSelectedRenderedBlock())

    await store.insertBlock(after: heading, kind: .paragraph)

    let draftID = try XCTUnwrap(store.selectedBlockID)
    XCTAssertEqual(store.editingBlockID, draftID)
    XCTAssertFalse(store.foldedRenderedBlockIDs.contains(heading.id))
    XCTAssertTrue(OrgRenderedFoldTree.visibleBlocks(
      store.selectedRenderedBlocks,
      foldedBlockIDs: store.foldedRenderedBlockIDs
    ).contains { $0.id == draftID })
  }

  @MainActor
  func testRepeatBeginEditingActiveBlockPreservesDraft() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-repeat-edit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("repeat-edit.org2")
    try """
    * TODO Parent
    Body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 1,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.beginEditingBlock(paragraph)
    store.editableBlockText = "Body draft"
    store.updateEditingBlockDraft(paragraph, draft: "Body draft")

    store.beginEditingBlock(paragraph)

    XCTAssertEqual(store.editingBlockID, paragraph.id)
    XCTAssertEqual(store.selectedBlockID, paragraph.id)
    XCTAssertEqual(store.editableBlockText, "Body draft")

    await store.saveEditedBlock(paragraph)
    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("* TODO Parent\nBody draft"))
  }

  @MainActor
  func testInsertsBlockAfterSelectedBlockFromKeyboard() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-selected-block-insert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("selected-block-insert.org2")
    try """
    #+TITLE: Selected Block Insert Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let paragraph = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .paragraph = $0.rendered { return true }
      return false
    })
    store.selectBlock(paragraph)

    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "/", keyCode: 44)))
    try await waitForCondition {
      store.selectedBlock?.rawText == "/" && store.editingBlockID == store.selectedBlockID
    }
    XCTAssertEqual(store.editableBlockText, "/")
    var updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n* Sibling"))
    XCTAssertFalse(updated.contains("Body\n\n/\n* Sibling"))

    store.cancelEditingBlock()
    XCTAssertNil(store.selectedBlock)
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n* Sibling"))

    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "\r", keyCode: 36, modifiers: [.command])))
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlockID
    }
    XCTAssertEqual(store.editableBlockText, "")

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("New text"))
    XCTAssertTrue(updated.contains("Body\n* Sibling"))

    store.cancelEditingBlock()
    XCTAssertNil(store.selectedBlock)
    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n* Sibling"))

    store.selectBlock(paragraph)
    XCTAssertTrue(store.handleDocumentKeyDown(keyDown(characters: "\r", keyCode: 36, modifiers: [.command])))
    try await waitForCondition {
      store.selectedBlock?.rawText == "" && store.editingBlockID == store.selectedBlockID
    }

    let draft = try XCTUnwrap(store.selectedBlock)
    store.editableBlockText = "Inserted paragraph"
    await store.saveEditedBlock(draft)
    try await waitForCondition {
      store.selectedBlock?.rawText == "Inserted paragraph"
    }

    updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(updated.contains("Body\n\nInserted paragraph\n* Sibling"))
  }

  @MainActor
  func testLoadsSelectedPageSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("page.org2")
    try """
    #+TITLE: Page Test

    * TODO Parent
    Body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))

    XCTAssertEqual(store.selectedEntrySource?.startLine, 1)
    XCTAssertTrue(store.selectedEntrySource?.text.contains("#+TITLE: Page Test") == true)
    XCTAssertTrue(store.selectedEntrySource?.text.contains("* Sibling") == true)
  }

  @MainActor
  func testDeletingRenderedHeadingFromPageDeletesSubtree() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-page-heading-delete-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("page-heading-delete.org2")
    try """
    #+TITLE: Page Heading Delete Test

    * TODO Parent
    Parent body
    ** TODO Child
    Child body
    * Sibling
    Sibling body
    """.write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Parent",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 3,
      "body": "Parent body",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.select(.agenda(item))
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    let parent = try XCTUnwrap(store.selectedRenderedBlocks.first {
      if case .heading(let heading) = $0.rendered { return heading.title == "Parent" }
      return false
    })
    await store.deleteBlock(parent)

    let updated = try String(contentsOf: note, encoding: .utf8)
    XCTAssertFalse(updated.contains("* TODO Parent"))
    XCTAssertFalse(updated.contains("Parent body"))
    XCTAssertFalse(updated.contains("** TODO Child"))
    XCTAssertFalse(updated.contains("Child body"))
    XCTAssertTrue(updated.contains("* Sibling\nSibling body"))
    XCTAssertEqual(store.selectedBlock?.rawText, "* Sibling")
  }

  @MainActor
  func testLoadsAndRendersLargePageSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-large-page-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("large-page.org2")
    let body = (1...2_500)
      .map { index in
        """
        * TODO Large item \(index)
        Body \(index)
        """
      }
      .joined(separator: "\n")
    try "#+TITLE: Large Page\n\n\(body)\n".write(to: note, atomically: true, encoding: .utf8)

    let itemJSON = """
    {
      "todo": "TODO",
      "headline": "Large item 1",
      "kind": "SCHEDULED",
      "file": "\(note.path)",
      "line": 2,
      "body": "Body 1",
      "level": 1,
      "tags": [],
      "properties": {}
    }
    """

    let item = try JSONDecoder().decode(AgendaItem.self, from: Data(itemJSON.utf8))
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedEntrySourceMode = .page
    await store.loadEntrySource(for: .agenda(item))
    try await waitForEntryRender(store)

    XCTAssertEqual(store.selectedEntrySource?.startLine, 1)
    XCTAssertEqual(store.selectedEntrySource?.displayRange, "1-5003")
    XCTAssertGreaterThan(store.selectedRenderedBlocks.count, 4_000)
    XCTAssertFalse(store.isRenderingEntrySource)
  }

  @MainActor
  func testAIChatThreadRecordsUseConfiguredDirectories() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-workspace-openclaw-\(UUID().uuidString)", isDirectory: true)
    let threads = root.appendingPathComponent("threads", isDirectory: true)
    try FileManager.default.createDirectory(at: threads, withIntermediateDirectories: true)
    try #"{"openclaw":{"threadDirs":["threads"]}}"#
      .write(to: root.appendingPathComponent("org2.json"), atomically: true, encoding: .utf8)
    try """
    #+TITLE: Agent Thread

    * TODO Follow up
    :PROPERTIES:
    :ID: 11111111-1111-4111-8111-111111111111
    :END:
    """.write(to: threads.appendingPathComponent("agent-thread.org2"), atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    await store.refreshAIChatThreadRecords()

    XCTAssertEqual(store.aiChatThreadRecords.count, 1)
    XCTAssertEqual(store.aiChatThreadRecords[0].title, "Agent Thread")
    XCTAssertEqual(store.aiChatThreadRecords[0].zone, "threads")
    XCTAssertEqual(store.aiChatThreadRecords[0].idValue, "11111111-1111-4111-8111-111111111111")
  }

  @MainActor
  func testRenderedEntryContextMenuContainsAndDispatchesEntryActions() {
    let coordinator = OrgHTMLDocumentView.Coordinator()
    coordinator.source = EntrySource(
      file: "/tmp/context-menu.org2",
      startLine: 1,
      endLineExclusive: 3,
      text: "* Entry\nBody",
      isSubtree: false
    )
    coordinator.entryContextMenuLine = 1
    var copiedLine: Int?
    coordinator.performEntryAction = { action, line in
      if case .copy = action {
        copiedLine = line
      }
    }
    let menu = coordinator.makeEntryContextMenu()
    let titles = menu.items.map(\.title)

    XCTAssertTrue(titles.contains("Entry View"))
    XCTAssertTrue(titles.contains("Edit Entry"))
    XCTAssertTrue(titles.contains("Ask AI"))
    XCTAssertTrue(titles.contains("Move / Refile…"))
    XCTAssertTrue(titles.contains("Archive Entry"))
    XCTAssertTrue(titles.contains("Schedule"))
    XCTAssertTrue(titles.contains("Todo Status"))
    XCTAssertTrue(titles.contains("Encrypt / Decrypt"))
    XCTAssertTrue(titles.contains("Copy"))
    XCTAssertTrue(titles.contains("Cut"))
    XCTAssertTrue(titles.contains("Delete"))
    XCTAssertEqual(menu.items.first(where: { $0.title == "Todo Status" })?.submenu?.items.map(\.title), [
      "TODO", "In Progress", "Done", "Canceled", "", "Toggle"
    ])
    XCTAssertTrue(
      OrgHTMLDocumentView.Coordinator.entryContextMenuInstallationScript
        .contains("messageHandlers.org2EntryContextMenu.postMessage")
    )

    if let copyItem = menu.items.first(where: { $0.title == "Copy" }) {
      coordinator.performEntryContextMenuAction(tag: copyItem.tag)
    }
    XCTAssertEqual(copiedLine, 1)
  }

  @MainActor
  func testRenderedEntryContextMenuUsesNativeClickLocation() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    let webView = OrgHTMLDocumentWebView(
      frame: NSRect(x: 40, y: 50, width: 500, height: 300),
      configuration: WKWebViewConfiguration()
    )
    window.contentView?.addSubview(webView)
    let clickLocation = NSPoint(x: 90, y: 125)
    webView.recordContextMenuLocationInWindow(clickLocation)

    let resolvedLocation = try XCTUnwrap(webView.consumeContextMenuLocation())
    XCTAssertEqual(webView.convert(resolvedLocation, to: nil), clickLocation)
    XCTAssertNil(webView.consumeContextMenuLocation())
  }

  func testRenderedEntryContextMenuFallbackRespectsViewOrientation() {
    XCTAssertEqual(
      OrgHTMLDocumentView.Coordinator.fallbackEntryContextMenuPoint(
        x: 30,
        y: 45,
        viewHeight: 400,
        isFlipped: true
      ),
      NSPoint(x: 30, y: 45)
    )
    XCTAssertEqual(
      OrgHTMLDocumentView.Coordinator.fallbackEntryContextMenuPoint(
        x: 30,
        y: 45,
        viewHeight: 400,
        isFlipped: false
      ),
      NSPoint(x: 30, y: 355)
    )
  }

  func testRenderedEntrySubtreeCopyIncludesChildrenButNotNextSibling() throws {
    let text = """
    #+TITLE: Context menu

    * Parent
    Parent body
    ** Child
    Child body
    * Sibling
    Sibling body
    """
    let source = EntrySource(
      file: "/tmp/context-menu.org2",
      startLine: 1,
      endLineExclusive: 9,
      text: text,
      isSubtree: false
    )
    let blocks = OrgEntryRenderer.parseEditable(text, baseLine: 1)
    let parent = try XCTUnwrap(blocks.first { block in
      block.startLine == 3 && {
        if case .heading = block.rendered { return true }
        return false
      }()
    })

    let copied = try WorkspaceStore.renderedEntrySubtreeText(for: parent, in: source)

    XCTAssertTrue(copied.hasPrefix("* Parent\n"))
    XCTAssertTrue(copied.contains("** Child\nChild body"))
    XCTAssertFalse(copied.contains("* Sibling"))
    XCTAssertTrue(copied.hasSuffix("\n"))
  }

  @MainActor
  func testRenderedEntryTodoActionTargetsRightClickedHeadingLine() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-rendered-todo-action-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = """
    #+TITLE: Context menu

    * TODO First
    * TODO Second
    """
    let note = root.appendingPathComponent("context-menu.org2")
    try text.write(to: note, atomically: true, encoding: .utf8)
    let source = EntrySource(
      file: note.path,
      startLine: 1,
      endLineExclusive: 5,
      text: text,
      isSubtree: false
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedEntrySource = source
    store.selectedRenderedBlocks = OrgEntryRenderer.parseEditable(text, baseLine: 1)
    let mutatedLines = ThreadSafeIntRecorder()
    store.todoStatusMutationForTesting = { status, _, line in
      mutatedLines.append(line)
      return status.label
    }

    store.performRenderedEntryAction(.todo(.done), at: 4)
    try await waitForCondition { mutatedLines.last != nil }

    XCTAssertEqual(mutatedLines.last, 4)
  }

  @MainActor
  func testRenderedEntryArchiveActionMovesTheRightClickedSubtree() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-rendered-archive-action-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = """
    #+TITLE: Context menu

    * TODO Keep
    * DONE Finished
    ** Detail
    * TODO After
    """
    let note = root.appendingPathComponent("context-menu.org")
    try text.write(to: note, atomically: true, encoding: .utf8)
    let source = EntrySource(
      file: note.path,
      startLine: 1,
      endLineExclusive: 7,
      text: text,
      isSubtree: false
    )
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root)
    store.selectedEntrySource = source
    store.selectedRenderedBlocks = OrgEntryRenderer.parseEditable(text, baseLine: 1)

    store.performRenderedEntryAction(.archive, at: 4)
    let archive = URL(fileURLWithPath: WorkspaceStore.renderedEntryArchiveFile(for: note.path))
    try await waitForCondition(timeout: 20) {
      FileManager.default.fileExists(atPath: archive.path)
        && store.statusText.hasPrefix("Archived entry")
    }

    let remaining = try String(contentsOf: note, encoding: .utf8)
    XCTAssertTrue(remaining.contains("* TODO Keep"))
    XCTAssertTrue(remaining.contains("* TODO After"))
    XCTAssertFalse(remaining.contains("Finished"))
    XCTAssertFalse(remaining.contains("** Detail"))
    let archived = try String(contentsOf: archive, encoding: .utf8)
    XCTAssertTrue(archived.contains("* DONE Finished"))
    XCTAssertTrue(archived.contains("** Detail"))
    XCTAssertTrue(archived.contains(":ARCHIVE_SOURCE:"))
    XCTAssertEqual(archive.lastPathComponent, "context-menu.org_archive")
  }

  @MainActor
  private func waitForEntryRender(_ store: WorkspaceStore, timeout: TimeInterval = 10) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while store.isRenderingEntrySource && Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertFalse(store.isRenderingEntrySource)
  }

  @MainActor
  private func applySyntaxEditorTextReplacement(
    _ replacement: String,
    in textView: NSTextView,
    coordinator: OrgSyntaxTextEditor.Coordinator
  ) {
    coordinator.attach(to: textView)
    let range = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
    XCTAssertTrue(coordinator.textView(
      textView,
      shouldChangeTextIn: range,
      replacementString: replacement
    ))
    textView.textStorage?.replaceCharacters(in: range, with: replacement)
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
  }

  @MainActor
  private func waitForCondition(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(condition())
  }

  private func writeSilentM4A(to url: URL) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
    buffer.frameLength = 1_600
    try file.write(from: buffer)
  }

  private func keyDown(
    characters: String = "",
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    )!
  }

  private func assertToken(
    _ kind: OrgSyntaxHighlightKind,
    _ substring: String,
    in raw: String,
    tokens: [OrgSyntaxHighlightToken],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let range = raw.range(of: substring) else {
      XCTFail("Missing substring \(substring)", file: file, line: line)
      return
    }
    let nsRange = NSRange(range, in: raw)
    XCTAssertTrue(
      tokens.contains { $0.kind == kind && NSEqualRanges($0.range, nsRange) },
      "Missing \(kind) token for \(substring)",
      file: file,
      line: line
    )
  }

  private func optionalLocation(_ range: NSRange) -> Int? {
    range.location == NSNotFound ? nil : range.location
  }

  private static func laidOutWidth(_ storage: NSTextStorage) -> CGFloat {
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(size: NSSize(width: 10_000, height: 1_000))
    textContainer.lineFragmentPadding = 0
    layoutManager.addTextContainer(textContainer)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: textContainer)
    return layoutManager.usedRect(for: textContainer).width
  }
}
