import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

public enum OrgDocumentDefaults {
  public static let preferredExtension = "org"
  public static let legacyExtension = "org2"

  public static func url(
    in directory: URL,
    baseName: String,
    fileManager: FileManager = .default
  ) -> URL {
    let preferred = directory.appendingPathComponent("\(baseName).\(preferredExtension)")
    if fileManager.fileExists(atPath: preferred.path) {
      return preferred
    }
    let legacy = directory.appendingPathComponent("\(baseName).\(legacyExtension)")
    return fileManager.fileExists(atPath: legacy.path) ? legacy : preferred
  }

  public static func candidateURLs(in directory: URL, baseName: String) -> [URL] {
    [preferredExtension, legacyExtension].map {
      directory.appendingPathComponent("\(baseName).\($0)")
    }
  }
}

public struct WorkspaceMissingDailyNote: Hashable, Sendable {
  public let file: String
  public let relativePath: String
  public let title: String
  public let opensHome: Bool
  let surface: WorkspaceSurface
}

public struct AIChatDeliveryReceipt: Equatable, Sendable {
  public enum State: String, Sendable {
    case rejected
    case requested
    case started
    case completed
    case failed
    case interrupted
    case unconfirmed
  }

  public let state: State
  public let messageID: UUID?
  public let deliveryAttemptID: UUID?
  public let runtimeThreadID: String?
  public let turnID: String?
  public let detail: String?

  public init(
    state: State,
    messageID: UUID? = nil,
    deliveryAttemptID: UUID? = nil,
    runtimeThreadID: String? = nil,
    turnID: String? = nil,
    detail: String? = nil
  ) {
    self.state = state
    self.messageID = messageID
    self.deliveryAttemptID = deliveryAttemptID
    self.runtimeThreadID = runtimeThreadID
    self.turnID = turnID
    self.detail = detail
  }

  /// Stable wire representation for the local control server. A native turn
  /// is reported as started only when the complete message/attempt/thread/turn
  /// binding is present; queue acceptance and partial IDs are not proof.
  public func openOrgServerRetryPayload() -> [String: Any] {
    let hasExactNativeTurnProof = messageID != nil
      && deliveryAttemptID != nil
      && runtimeThreadID?.isEmpty == false
      && turnID?.isEmpty == false
      && [.started, .completed, .failed, .interrupted].contains(state)
    var payload: [String: Any] = [
      "retryRequested": state != .rejected,
      "deliveryState": state.rawValue,
      "turnStarted": hasExactNativeTurnProof,
      "terminal": [.completed, .failed, .interrupted].contains(state)
    ]
    if let messageID {
      payload["messageID"] = messageID.uuidString.lowercased()
    }
    if let deliveryAttemptID {
      payload["deliveryAttemptID"] = deliveryAttemptID.uuidString.lowercased()
    }
    if let runtimeThreadID {
      payload["runtimeThreadID"] = runtimeThreadID
    }
    if let turnID {
      payload["turnID"] = turnID
    }
    if let detail {
      payload[state == .rejected ? "error" : "detail"] = detail
    }
    return payload
  }
}

public enum AIChatMessageSound: String, CaseIterable, Identifiable, Sendable {
  case org2 = "org2"
  case systemAlert = "system-alert"
  case basso = "Basso"
  case blow = "Blow"
  case bottle = "Bottle"
  case frog = "Frog"
  case funk = "Funk"
  case glass = "Glass"
  case hero = "Hero"
  case morse = "Morse"
  case ping = "Ping"
  case pop = "Pop"
  case purr = "Purr"
  case sosumi = "Sosumi"
  case submarine = "Submarine"
  case tink = "Tink"
  case off = "off"

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .org2:
      return "\(WorkspaceProductIdentity.displayName) (Default)"
    case .systemAlert:
      return "System Alert"
    case .off:
      return "Off"
    default:
      return rawValue
    }
  }

  var appKitSoundName: NSSound.Name? {
    switch self {
    case .org2, .systemAlert, .off:
      return nil
    default:
      return NSSound.Name(rawValue)
    }
  }
}

public enum WorkspaceAppearanceMode: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .system:
      return "System"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }

  public var colorScheme: ColorScheme? {
    switch self {
    case .system:
      return nil
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }
}

public enum WorkspaceKeyboardShortcutScope: Equatable, Sendable {
  case all
  case globalOnly
}

public struct WorkspaceTab: Identifiable, Hashable, Sendable {
  public let id: UUID
  public internal(set) var title: String
  public internal(set) var systemImage: String

  init(
    id: UUID = UUID(),
    title: String,
    systemImage: String
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
  }
}

enum WorkspacePaneFocus: Equatable, Sendable {
  case surface
  case detail
}

public enum AIChatDictationCompletionAction: Sendable {
  case insertIntoComposer
  case send
}

public struct Org2ExportNotice: Identifiable, Equatable, Sendable {
  public let id = UUID()
  public let title: String
  public let message: String

  public init(title: String, message: String) {
    self.title = title
    self.message = message
  }
}

public struct Org2EditorSaveConflict: Identifiable, Equatable, Sendable {
  public let id = UUID()
  public let file: String
  public let canOverwrite: Bool

  public init(file: String, canOverwrite: Bool) {
    self.file = file
    self.canOverwrite = canOverwrite
  }
}

struct WorkspaceInputMeterLevels: Equatable, Sendable {
  static let silent = WorkspaceInputMeterLevels(
    averageLevel: 0,
    peakLevel: 0,
    secondaryAverageLevel: 0,
    secondaryPeakLevel: 0
  )

  let averageLevel: Double
  let peakLevel: Double
  let secondaryAverageLevel: Double
  let secondaryPeakLevel: Double
}

@MainActor
final class WorkspaceInputMeterState: ObservableObject {
  @Published var levels = WorkspaceInputMeterLevels.silent

  func publish(
    primary: MeetingInputMeterSnapshot,
    secondary: MeetingInputMeterSnapshot = .silent,
    force: Bool = false
  ) {
    let current = levels
    let next = WorkspaceInputMeterLevels(
      averageLevel: Self.publishedLevel(current.averageLevel, primary.averageLevel, force: force),
      peakLevel: Self.publishedLevel(current.peakLevel, primary.peakLevel, force: force),
      secondaryAverageLevel: Self.publishedLevel(
        current.secondaryAverageLevel,
        secondary.averageLevel,
        force: force
      ),
      secondaryPeakLevel: Self.publishedLevel(
        current.secondaryPeakLevel,
        secondary.peakLevel,
        force: force
      )
    )
    guard next != current else { return }
    levels = next
  }

  func reset() {
    guard levels != .silent else { return }
    levels = .silent
  }

  private static func publishedLevel(_ current: Double, _ next: Double, force: Bool) -> Double {
    force || WorkspaceStore.shouldPublishMeetingMeterLevelChange(current: current, next: next)
      ? next
      : current
  }
}

@MainActor
final class WorkspaceTranscriptionProgressState: ObservableObject {
  @Published var progress = 0.0
  @Published var elapsedText = ""

  func publish(progress: Double, elapsedText: String) {
    if self.progress != progress {
      self.progress = progress
    }
    if self.elapsedText != elapsedText {
      self.elapsedText = elapsedText
    }
  }

  func reset() {
    publish(progress: 0, elapsedText: "")
  }
}

/// High-frequency state for a live AI turn. Keeping it off `WorkspaceStore`
/// prevents every streamed token from invalidating unrelated workspace views.
public struct AIChatLivePresentationSnapshot: Equatable, Sendable {
  public let streamingReply: String
  public let reasoning: String
  public let isStreamingReplyTruncated: Bool
  public let isReasoningTruncated: Bool

  public init(
    streamingReply: String,
    reasoning: String,
    isStreamingReplyTruncated: Bool,
    isReasoningTruncated: Bool
  ) {
    self.streamingReply = streamingReply
    self.reasoning = reasoning
    self.isStreamingReplyTruncated = isStreamingReplyTruncated
    self.isReasoningTruncated = isReasoningTruncated
  }

  public static let empty = AIChatLivePresentationSnapshot(
    streamingReply: "",
    reasoning: "",
    isStreamingReplyTruncated: false,
    isReasoningTruncated: false
  )
}

private struct AIChatChunkedLiveText {
  static let targetSegmentCharacterCount = 8 * 1_024

  private(set) var characterCount = 0
  private var sealedSegments: [String] = []
  private var activeSegment = ""
  private var activeSegmentCharacterCount = 0

  init(_ text: String = "") {
    guard !text.isEmpty else { return }
    let count = text.count
    characterCount = count
    if count >= Self.targetSegmentCharacterCount {
      sealedSegments = [text]
    } else {
      activeSegment = text
      activeSegmentCharacterCount = count
    }
  }

  var isEmpty: Bool { characterCount == 0 }

  var segmentCount: Int {
    sealedSegments.count + (activeSegment.isEmpty ? 0 : 1)
  }

  mutating func append(_ text: String) {
    guard !text.isEmpty else { return }
    let count = text.count
    characterCount += count
    if activeSegmentCharacterCount + count <= Self.targetSegmentCharacterCount {
      activeSegment.append(contentsOf: text)
      activeSegmentCharacterCount += count
      return
    }
    if !activeSegment.isEmpty {
      sealedSegments.append(activeSegment)
      activeSegment = ""
      activeSegmentCharacterCount = 0
    }
    if count >= Self.targetSegmentCharacterCount {
      // Retain an already-large provider chunk directly. Splitting it would
      // duplicate the whole payload without improving bounded tail reads.
      sealedSegments.append(text)
    } else {
      activeSegment = text
      activeSegmentCharacterCount = count
    }
  }

  func materialized() -> String {
    if sealedSegments.isEmpty { return activeSegment }
    if activeSegment.isEmpty, sealedSegments.count == 1 {
      return sealedSegments[0]
    }
    var pieces = sealedSegments
    if !activeSegment.isEmpty { pieces.append(activeSegment) }
    return pieces.joined()
  }

  func boundedSuffix(
    maximumCharacterCount: Int
  ) -> (text: String, isTruncated: Bool, visitedCharacterCount: Int) {
    let limit = max(0, maximumCharacterCount)
    guard characterCount > limit else {
      return (materialized(), false, characterCount)
    }
    guard limit > 0 else { return ("", true, 0) }

    var remaining = limit
    var reversePieces: [String] = []
    func consume(_ segment: String) {
      guard remaining > 0, !segment.isEmpty else { return }
      if let start = segment.index(
        segment.endIndex,
        offsetBy: -remaining,
        limitedBy: segment.startIndex
      ) {
        reversePieces.append(String(segment[start...]))
        remaining = 0
      } else {
        reversePieces.append(segment)
        remaining -= segment.count
      }
    }

    consume(activeSegment)
    for segment in sealedSegments.reversed() where remaining > 0 {
      consume(segment)
    }
    return (reversePieces.reversed().joined(), true, limit - remaining)
  }
}

@MainActor
final class AIChatLiveState: ObservableObject {
  nonisolated static let streamPublishIntervalNanoseconds: UInt64 = 66_000_000
  nonisolated static let maximumPresentationCharacterCount = 32 * 1_024
  nonisolated static let streamSegmentTargetCharacterCountForTesting =
    AIChatChunkedLiveText.targetSegmentCharacterCount

  @Published var gatewayStateByThreadID: [UUID: OpenClawGatewayConnectionState] = [:]
  @Published var gatewayDetailByThreadID: [UUID: String] = [:]
  @Published var activeRunIDByThreadID: [UUID: String] = [:]
  @Published var runActivitiesByThreadID: [UUID: [AIChatRunActivity]] = [:]

  private var lastEventAtByThreadID: [UUID: Date] = [:]
  private var streamingReplyByThreadID: [UUID: AIChatChunkedLiveText] = [:]
  private var reasoningByThreadID: [UUID: AIChatChunkedLiveText] = [:]
  private var presentationSnapshotByThreadID: [UUID: AIChatLivePresentationSnapshot] = [:]
  private var pendingLastEventAtByThreadID: [UUID: Date] = [:]
  private var pendingStreamingPresentationThreadIDs: Set<UUID> = []
  private var pendingReasoningPresentationThreadIDs: Set<UUID> = []
  private var streamPublishTask: Task<Void, Never>?

  private(set) var fullTextMaterializationCountForTesting = 0
  private(set) var maximumPresentationCharactersVisitedPerSnapshotForTesting = 0

  func connectionState(for threadID: UUID) -> OpenClawGatewayConnectionState {
    gatewayStateByThreadID[threadID] ?? .disconnected
  }

  func connectionDetail(for threadID: UUID) -> String? {
    gatewayDetailByThreadID[threadID]
  }

  func lastEventAt(for threadID: UUID) -> Date? {
    pendingLastEventAtByThreadID[threadID] ?? lastEventAtByThreadID[threadID]
  }

  func activeRunID(for threadID: UUID) -> String? {
    activeRunIDByThreadID[threadID]
  }

  func streamingReply(for threadID: UUID) -> String {
    guard let reply = streamingReplyByThreadID[threadID] else { return "" }
    fullTextMaterializationCountForTesting += 1
    return reply.materialized()
  }

  func reasoning(for threadID: UUID) -> String {
    guard let reasoning = reasoningByThreadID[threadID] else { return "" }
    fullTextMaterializationCountForTesting += 1
    return reasoning.materialized()
  }

  func presentationSnapshot(for threadID: UUID) -> AIChatLivePresentationSnapshot {
    presentationSnapshotByThreadID[threadID] ?? .empty
  }

  func runActivities(for threadID: UUID) -> [AIChatRunActivity] {
    runActivitiesByThreadID[threadID] ?? []
  }

  func appendStreamingDelta(_ delta: String, for threadID: UUID) {
    guard !delta.isEmpty else { return }
    streamingReplyByThreadID[threadID, default: AIChatChunkedLiveText()].append(delta)
    pendingStreamingPresentationThreadIDs.insert(threadID)
    scheduleStreamPublish()
  }

  func replaceStreamingReply(_ reply: String, for threadID: UUID, coalesced: Bool) {
    guard coalesced else {
      pendingStreamingPresentationThreadIDs.remove(threadID)
      publishStreamMutation {
        streamingReplyByThreadID[threadID] = AIChatChunkedLiveText(reply)
        refreshPresentationSnapshot(for: threadID)
      }
      return
    }
    streamingReplyByThreadID[threadID] = AIChatChunkedLiveText(reply)
    pendingStreamingPresentationThreadIDs.insert(threadID)
    scheduleStreamPublish()
  }

  func appendReasoningDelta(_ delta: String, for threadID: UUID) {
    guard !delta.isEmpty else { return }
    reasoningByThreadID[threadID, default: AIChatChunkedLiveText()].append(delta)
    pendingReasoningPresentationThreadIDs.insert(threadID)
    scheduleStreamPublish()
  }

  func replaceReasoning(_ reasoning: String, for threadID: UUID, coalesced: Bool) {
    guard coalesced else {
      pendingReasoningPresentationThreadIDs.remove(threadID)
      publishStreamMutation {
        reasoningByThreadID[threadID] = AIChatChunkedLiveText(reasoning)
        refreshPresentationSnapshot(for: threadID)
      }
      return
    }
    reasoningByThreadID[threadID] = AIChatChunkedLiveText(reasoning)
    pendingReasoningPresentationThreadIDs.insert(threadID)
    scheduleStreamPublish()
  }

  func removeStreamingReply(for threadID: UUID) {
    pendingStreamingPresentationThreadIDs.remove(threadID)
    guard streamingReplyByThreadID[threadID] != nil else { return }
    publishStreamMutation {
      streamingReplyByThreadID.removeValue(forKey: threadID)
      refreshPresentationSnapshot(for: threadID)
    }
  }

  func removeReasoning(for threadID: UUID) {
    pendingReasoningPresentationThreadIDs.remove(threadID)
    guard reasoningByThreadID[threadID] != nil else { return }
    publishStreamMutation {
      reasoningByThreadID.removeValue(forKey: threadID)
      refreshPresentationSnapshot(for: threadID)
    }
  }

  func noteEvent(at date: Date = Date(), for threadID: UUID, coalesced: Bool) {
    guard coalesced else {
      publishStreamMutation {
        lastEventAtByThreadID[threadID] = date
      }
      return
    }
    pendingLastEventAtByThreadID[threadID] = date
    scheduleStreamPublish()
  }

  var currentLastEventDates: [UUID: Date] {
    lastEventAtByThreadID.merging(pendingLastEventAtByThreadID) { _, pending in pending }
  }

  func replaceLastEventDates(_ dates: [UUID: Date]) {
    pendingLastEventAtByThreadID = [:]
    publishStreamMutation {
      lastEventAtByThreadID = dates
    }
  }

  func flushPendingStreamUpdates() {
    streamPublishTask?.cancel()
    streamPublishTask = nil
    guard !pendingLastEventAtByThreadID.isEmpty
      || !pendingStreamingPresentationThreadIDs.isEmpty
      || !pendingReasoningPresentationThreadIDs.isEmpty
    else {
      return
    }
    let eventDates = pendingLastEventAtByThreadID
    let presentationThreadIDs = pendingStreamingPresentationThreadIDs
      .union(pendingReasoningPresentationThreadIDs)
    pendingLastEventAtByThreadID = [:]
    pendingStreamingPresentationThreadIDs = []
    pendingReasoningPresentationThreadIDs = []
    publishStreamMutation {
      for (threadID, date) in eventDates {
        lastEventAtByThreadID[threadID] = date
      }
      for threadID in presentationThreadIDs {
        refreshPresentationSnapshot(for: threadID)
      }
    }
  }

  func streamingSegmentCountForTesting(_ threadID: UUID) -> Int {
    streamingReplyByThreadID[threadID]?.segmentCount ?? 0
  }

  func reasoningSegmentCountForTesting(_ threadID: UUID) -> Int {
    reasoningByThreadID[threadID]?.segmentCount ?? 0
  }

  func retainedPresentationCharacterCountForTesting(_ threadID: UUID) -> Int {
    let snapshot = presentationSnapshot(for: threadID)
    return snapshot.streamingReply.count + snapshot.reasoning.count
  }

  private func scheduleStreamPublish() {
    guard streamPublishTask == nil else { return }
    streamPublishTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.streamPublishIntervalNanoseconds)
      guard !Task.isCancelled else { return }
      self?.streamPublishTask = nil
      self?.flushPendingStreamUpdates()
    }
  }

  private func publishStreamMutation(_ mutation: () -> Void) {
    objectWillChange.send()
    mutation()
  }

  private func refreshPresentationSnapshot(for threadID: UUID) {
    let streaming = streamingReplyByThreadID[threadID]?.boundedSuffix(
      maximumCharacterCount: Self.maximumPresentationCharacterCount
    ) ?? (text: "", isTruncated: false, visitedCharacterCount: 0)
    let reasoning = reasoningByThreadID[threadID]?.boundedSuffix(
      maximumCharacterCount: Self.maximumPresentationCharacterCount
    ) ?? (text: "", isTruncated: false, visitedCharacterCount: 0)
    maximumPresentationCharactersVisitedPerSnapshotForTesting = max(
      maximumPresentationCharactersVisitedPerSnapshotForTesting,
      streaming.visitedCharacterCount + reasoning.visitedCharacterCount
    )
    guard !streaming.text.isEmpty || !reasoning.text.isEmpty else {
      presentationSnapshotByThreadID.removeValue(forKey: threadID)
      return
    }
    presentationSnapshotByThreadID[threadID] = AIChatLivePresentationSnapshot(
      streamingReply: streaming.text,
      reasoning: reasoning.text,
      isStreamingReplyTruncated: streaming.isTruncated,
      isReasoningTruncated: reasoning.isTruncated
    )
  }
}

public enum MobileRemoteFilePreviewError: LocalizedError, Equatable, Sendable {
  case invalidPath
  case unsupportedFile
  case unavailable

  public var errorDescription: String? {
    switch self {
    case .invalidPath:
      "That citation is outside the Celorga corpora available to this workspace."
    case .unsupportedFile:
      "Mobile preview is available for Org, Markdown, and CSV files."
    case .unavailable:
      "That cited file is no longer available on the Mac."
    }
  }
}

enum MobileRemoteFilePreviewOverlay: Sendable {
  case wholeFile(file: String, text: String)
  case sourceRange(file: String, source: EntrySource, replacement: String)
  case invalidWholeFile(file: String)

  var file: String {
    switch self {
    case .wholeFile(let file, _), .sourceRange(let file, _, _), .invalidWholeFile(let file):
      file
    }
  }
}

struct MobileRemoteFilePreviewAuthorization: Sendable {
  let mountedRootPaths: [String]
  let activeRootPath: String?
  let overlay: MobileRemoteFilePreviewOverlay?
}

struct MobileRemoteFilePreviewTarget: Sendable {
  let root: URL
  let url: URL
  let relativePath: String
}

enum StarterCorpusCreationError: LocalizedError {
  case notDirectory(String)
  case notEmpty(String)

  var errorDescription: String? {
    switch self {
    case .notDirectory(let path):
      "Choose a folder for the new Celorga corpus, not a file: \(path)"
    case .notEmpty(let path):
      "The starter corpus needs an empty folder. Choose a new folder, or use Open Corpus for \(path)."
    }
  }
}

struct AIChatLastConfiguration: Codable {
  let model: String?
  let reasoningEffort: String?
}

struct AIChatConfigurationCatalogCacheEntry: Codable, Equatable, Sendable {
  let requestedModel: String?
  let models: [AIChatModelOption]
  let effectiveModel: String?
  let reasoningOptions: [AIChatReasoningOption]
  let defaultReasoningEffort: String?
}

struct CanonicalDocumentCacheEntry: Sendable {
  let fileContentDigest: String?
  let document: Org2CanonicalDocument
}

enum WorkspaceCacheRecency {
  nonisolated static func recordAccess(
    _ key: String,
    order: inout [String],
    limit: Int
  ) -> [String] {
    order.removeAll { $0 == key }
    order.append(key)
    let excess = max(0, order.count - max(0, limit))
    guard excess > 0 else { return [] }
    let evicted = Array(order.prefix(excess))
    order.removeFirst(excess)
    return evicted
  }
}

struct RenderedBlocksCacheEntry: Sendable {
  let modifiedAt: Date?
  let sourceID: String
  let textDigest: String
  let blocks: [OrgEditableBlock]
  let metadata: RenderedBlocksMetadata
}

struct EntrySourceCacheEntry: Sendable {
  let modifiedAt: Date?
  let fileContentDigest: String?
  let fileFreshnessSignature: FileFreshnessSignature?
  let firstOrgID: String?
  let sourceLineIndex: OrgSourceLineIndex
  let source: EntrySource
}

struct EntrySourceLoadResult: Sendable {
  let source: EntrySource
  let fileContentDigest: String?
  let fileFreshnessSignature: FileFreshnessSignature?
  let appHTMLStylesheetSnapshot: AppHTMLStylesheetSnapshot
  let firstOrgID: String?
  let sourceLineIndex: OrgSourceLineIndex
}

/// A metadata-only file version used to avoid reading and hashing an unchanged
/// multi-megabyte document whenever the application becomes active. The
/// attribute-change timestamp and filesystem identifiers catch atomic
/// replacements and in-place sync writes even when a tool preserves mtime and
/// byte count. A content digest remains the fallback whenever this signature
/// changes or the filesystem cannot provide it.
struct FileFreshnessSignature: Equatable, Sendable {
  let fileSize: Int
  let contentModificationDate: Date?
  let attributeModificationDate: Date?
  let fileResourceIdentifier: Data?
  let generationIdentifier: Data?
}

struct AppHTMLStylesheetSnapshot: Equatable, Sendable {
  let corpusRootPath: String?
  let path: String?
  let identity: String
  let wasBuiltOnMainThread: Bool

  static let empty = AppHTMLStylesheetSnapshot(
    corpusRootPath: nil,
    path: nil,
    identity: "default",
    wasBuiltOnMainThread: false
  )
}

struct WorkspaceCacheReleaseSnapshot: Sendable {
  let scheduledCount: Int
  let completedCount: Int
  let mainThreadCount: Int
}

final class WorkspaceCacheReleaseMetrics: @unchecked Sendable {
  let lock = NSLock()
  private var scheduledCount = 0
  var completedCount = 0
  private var mainThreadCount = 0

  func recordScheduled(count: Int) {
    lock.lock()
    scheduledCount &+= count
    lock.unlock()
  }

  func recordCompleted(onMainThread: Bool) {
    lock.lock()
    completedCount &+= 1
    if onMainThread { mainThreadCount &+= 1 }
    lock.unlock()
  }

  var snapshot: WorkspaceCacheReleaseSnapshot {
    lock.lock()
    let snapshot = WorkspaceCacheReleaseSnapshot(
      scheduledCount: scheduledCount,
      completedCount: completedCount,
      mainThreadCount: mainThreadCount
    )
    lock.unlock()
    return snapshot
  }
}

class AnyWorkspaceCacheBox: @unchecked Sendable {
  let releaseMetrics: WorkspaceCacheReleaseMetrics

  init(releaseMetrics: WorkspaceCacheReleaseMetrics) {
    self.releaseMetrics = releaseMetrics
  }

  deinit {
    releaseMetrics.recordCompleted(onMainThread: Thread.isMainThread)
  }
}

/// ARC ownership carrier for a potentially full-document cache value. Values
/// are immutable, except for `OrgSourceLineIndex`, which is sealed after cache
/// publication and queried only on MainActor. A detached release sink never
/// accesses `value`; it only retains the box until its final reference can be
/// dropped away from MainActor.
final class WorkspaceCacheBox<Value: Sendable>: AnyWorkspaceCacheBox, @unchecked Sendable {
  let value: Value

  init(_ value: Value, releaseMetrics: WorkspaceCacheReleaseMetrics) {
    self.value = value
    super.init(releaseMetrics: releaseMetrics)
  }
}

/// Owns retired cache boxes across a complete MainActor turn before releasing
/// them on a utility queue. Launching a detached task directly is insufficient:
/// it can finish before the caller drops `Dictionary.updateValue` temporaries,
/// making the caller's MainActor release the final reference after all.
final class WorkspaceCacheReleaseSink: @unchecked Sendable {
  let lock = NSLock()
  private var pendingBoxes: [AnyWorkspaceCacheBox] = []
  private var isDrainAcknowledgementScheduled = false
  private let releaseQueue = DispatchQueue(
    label: "org.org2.workspace.document-cache-release",
    qos: .utility
  )

  func enqueue(_ boxes: [AnyWorkspaceCacheBox]) {
    guard !boxes.isEmpty else { return }
    boxes.forEach { $0.releaseMetrics.recordScheduled(count: 1) }
    let shouldScheduleAcknowledgement = lock.withLock { () -> Bool in
      pendingBoxes.append(contentsOf: boxes)
      guard !isDrainAcknowledgementScheduled else { return false }
      isDrainAcknowledgementScheduled = true
      return true
    }
    guard shouldScheduleAcknowledgement else { return }

    // This closure cannot run until the current MainActor turn returns, so the
    // sink is the sole remaining cache owner before the utility drain starts.
    DispatchQueue.main.async { [weak self] in
      self?.scheduleUtilityDrain()
    }
  }

  private func scheduleUtilityDrain() {
    releaseQueue.async { [weak self] in
      self?.drain()
    }
  }

  func drain() {
    let boxes = lock.withLock { () -> [AnyWorkspaceCacheBox] in
      let boxes = pendingBoxes
      pendingBoxes = []
      isDrainAcknowledgementScheduled = false
      return boxes
    }
    withExtendedLifetime(boxes) {}
  }
}

struct CorpusChangeObservation {
  let eventSerial: Int
  /// Reads the pre-turn corpus text in the background. Dispatch never waits
  /// for it: on a large corpus the read took tens of seconds and held every
  /// agent turn at "Connecting". The change summary awaits it after the turn.
  let snapshot: Task<AIChatCorpusSnapshot, Never>
}

struct CorpusFileEventClassification: Equatable, Sendable {
  let contentPaths: [String]
  let pdfPreviewPaths: [String]
  var mediaPreviewPaths: [String] = []
  let hasAgentRunStateChanges: Bool
  let hasConfigurationChanges: Bool
  let hasAIChatInboxChanges: Bool
  var hasAIChatTranscriptChanges = false
  var hasAIChatLiveChanges = false
}

struct AIChatInboxMessage: Decodable, Sendable {
  let schema: String
  let id: UUID
  let threadID: UUID
  let content: String
  let createdAt: String
  let authorLabel: String
  let authorAgentRef: String?
  let source: String?
  /// Shared-room agents (IDs or mentions) asked to respond to this post.
  let requestedResponders: [String]?
  let destinationID: String?

  var isSingleAgentSend: Bool {
    CelorgaNames.schemaMatches(schema, "org2:ai-chat-send-message:v1")
  }
}

struct AIChatInboxFileLoad: Sendable {
  let file: URL
  let envelope: AIChatInboxMessage?
  let errorDescription: String?
}

struct RenderedHTMLCacheEntry: Sendable {
  let html: String
}

struct RenderedBlocksMetadata: Sendable {
  let renderSignature: String
  let structureSignature: String
  let indexes: [OrgEditableBlock.ID: Int]
}

enum EntryRenderResult: @unchecked Sendable {
  case native([OrgEditableBlock], RenderedBlocksMetadata)
  case html(Result<String, Error>)
}

struct PendingBlockSelection {
  let file: String
  let line: Int
  let mode: PendingBlockSelectionMode
  let beginEditing: Bool
  let initialSourceUTF16Offset: Int?

  init(
    file: String,
    line: Int,
    mode: PendingBlockSelectionMode,
    beginEditing: Bool = false,
    initialSourceUTF16Offset: Int? = nil
  ) {
    self.file = file
    self.line = line
    self.mode = mode
    self.beginEditing = beginEditing
    self.initialSourceUTF16Offset = initialSourceUTF16Offset
  }
}

struct RenderedTextSelectionFragment: Sendable {
  let blockID: String
  let startLine: Int
  let endLineExclusive: Int
  let sourceRange: NSRange
  let selectsEntireEditor: Bool
  let editorText: String
  let editorToSourceUTF16Offset: Int

  init(_ fragment: OrgSyntaxTextSelectionDocumentFragment) {
    blockID = fragment.context.blockID
    startLine = fragment.context.startLine
    endLineExclusive = fragment.context.endLineExclusive
    sourceRange = fragment.sourceRange
    selectsEntireEditor = fragment.selectsEntireEditor
    editorText = fragment.editorText
    editorToSourceUTF16Offset = fragment.context.editorToSourceUTF16Offset
  }
}

struct RenderedTextSelectionPreparation: Sendable {
  let fragments: [RenderedTextSelectionFragment]
  let replacementText: String
  let source: EntrySource
  let blocks: [OrgEditableBlock]
  let sourceRevision: String?
}

struct RenderedTextSelectionWrite: Sendable {
  let file: String
  let startLine: Int
  let endLineExclusive: Int
  let replacement: String
  let expectedOriginal: String
  let allowDestructiveReplacement: Bool
  let failureStatus: String
  let updatedSource: EntrySource
  let renderedBlocks: [OrgEditableBlock]
  let renderedBlocksMetadata: RenderedBlocksMetadata
  let caretSourceUTF16Offset: Int
  let undoSnapshot: PendingFileUndoSnapshot?
}

enum RenderedTextSelectionPlanResult: Sendable {
  case success(RenderedTextSelectionWrite)
  case failure(String)
}

struct RenderedTableSavePlan: Sendable {
  let block: OrgEditableBlock
  let replacement: String
  let updatedSource: EntrySource
  let hiddenRowCount: Int
  let sourceRevision: String?
}

enum RenderedTableSavePlanResult: Sendable {
  case success(RenderedTableSavePlan)
  case failure(String)
}

enum PendingBlockSelectionMode {
  case containingOrNearest
  case nextOrNearest
}

struct TransientDraftBlock {
  let file: String
  let insertionLine: Int
  let replacementEndLineExclusive: Int
  let replacementPrefix: String
  let replacementSuffix: String
  let selectionLineOffset: Int
  let block: OrgEditableBlock
  let coveredBlocks: [OrgEditableBlock]
}

struct DeferredStableAutosave {
  let source: EntrySource
  let block: OrgEditableBlock
}

struct PendingFileUndoSnapshot: Sendable {
  let file: String
  let previous: String
}

struct CompletedFileUndoSnapshot: Sendable {
  let file: String
  let previous: String
  let next: String
}

struct RenderedCheckboxMutation: Sendable {
  let previousForUndo: String?
  let next: String
  let source: EntrySource
  let blocks: [OrgEditableBlock]
  let blockMetadata: RenderedBlocksMetadata
  let fileContentDigest: String
  let fileFreshnessSignature: FileFreshnessSignature?
  let firstOrgID: String?
  let sourceLineIndex: OrgSourceLineIndex
}

struct AIChatLocalEditDiskBaseline: Sendable {
  let existed: Bool
  let text: String
}

struct EditorPersistenceRequest: Sendable {
  let key: String
  let file: String
  let startLine: Int
  let endLineExclusive: Int
  let expectedOriginal: String
  let replacement: String
}

struct BlockEditorCheckpointTarget {
  let identity: String
  let key: String
  let file: String
  let startLine: Int
  let endLineExclusive: Int
  let expectedOriginal: String
  let replacementPrefix: String
  let replacementSuffix: String
  let transientBlock: OrgEditableBlock?
}

struct EditorPersistenceRegionState: Sendable {
  let startLine: Int
  let endLineExclusive: Int
  let committedText: String
}

struct FailedEditorPersistenceDraft {
  let source: EntrySource
  let draft: String
  let message: String
}

enum EditorPersistenceOutcome: Sendable {
  case saved(CompletedFileUndoSnapshot?, EditorPersistenceRegionState)
  case unchanged(EditorPersistenceRegionState)
  case failed(message: String, isConflict: Bool)

  var succeeded: Bool {
    switch self {
    case .saved, .unchanged:
      return true
    case .failed:
      return false
    }
  }
}

final class AgentRunProjectionBox: @unchecked Sendable {
  let filterTextByID: [AgentRunItem.ID: String]
  let runsByID: [AgentRunItem.ID: AgentRunItem]
  let countByGoalRef: [String: Int]
  let countByAgentRef: [String: Int]
  let scopeCounts: [AgentRunScope: Int]
  let scopeEntries: [AgentRunScope: [AgentRunScopeEntry]]
  let filteredScopeEntries: [AgentRunScope: [AgentRunScopeEntry]]
  let filteredScopeIDs: [AgentRunScope: [AgentRunItem.ID]]
  let filteredScopeIDSets: [AgentRunScope: Set<AgentRunItem.ID>]
  let sectionsByScope: [AgentRunScope: [RunCenterSection]]
  let sourceMeetingContextsByID: [AgentRunItem.ID: AgentRunContextItem]
  let runIDsBySourceMeetingReference: [String: [AgentRunItem.ID]]
  let wasBuiltOnMainThread: Bool
  /// True when only the filter changed and the run-derived indexes were reused.
  var reusedRunIndexes = false

  init(
    filterTextByID: [AgentRunItem.ID: String],
    runsByID: [AgentRunItem.ID: AgentRunItem],
    countByGoalRef: [String: Int],
    countByAgentRef: [String: Int],
    scopeCounts: [AgentRunScope: Int],
    scopeEntries: [AgentRunScope: [AgentRunScopeEntry]],
    filteredScopeEntries: [AgentRunScope: [AgentRunScopeEntry]],
    filteredScopeIDs: [AgentRunScope: [AgentRunItem.ID]],
    filteredScopeIDSets: [AgentRunScope: Set<AgentRunItem.ID>],
    sectionsByScope: [AgentRunScope: [RunCenterSection]],
    sourceMeetingContextsByID: [AgentRunItem.ID: AgentRunContextItem],
    runIDsBySourceMeetingReference: [String: [AgentRunItem.ID]],
    wasBuiltOnMainThread: Bool
  ) {
    self.filterTextByID = filterTextByID
    self.runsByID = runsByID
    self.countByGoalRef = countByGoalRef
    self.countByAgentRef = countByAgentRef
    self.scopeCounts = scopeCounts
    self.scopeEntries = scopeEntries
    self.filteredScopeEntries = filteredScopeEntries
    self.filteredScopeIDs = filteredScopeIDs
    self.filteredScopeIDSets = filteredScopeIDSets
    self.sectionsByScope = sectionsByScope
    self.sourceMeetingContextsByID = sourceMeetingContextsByID
    self.runIDsBySourceMeetingReference = runIDsBySourceMeetingReference
    self.wasBuiltOnMainThread = wasBuiltOnMainThread
  }
}

struct NodeBriefLookupResult: Sendable {
  let title: String
  let artifact: NodeBriefArtifact?
}

struct NodeBriefLookupInput: Sendable {
  let corpusRoot: URL
  let location: WorkspaceLocation
  let source: EntrySource?
  let explicitSourceID: String?
  let relativeFile: String
}

enum AIChatLocalEditOverlay: Sendable {
  case wholeFile(file: String, text: String, isDirty: Bool)
  case sourceRange(file: String, source: EntrySource, replacement: String, isDirty: Bool)
  case invalidWholeFile(file: String)

  var file: String {
    switch self {
    case .wholeFile(let file, _, _), .sourceRange(let file, _, _, _), .invalidWholeFile(let file):
      file
    }
  }
}

struct AIChatLocalEditPreparationIdentity: Equatable, Sendable {
  let corpusSessionGeneration: UInt64
  let selectedSourceID: String?
  let sourceDraftGeneration: UInt64
  let liveDraftGeneration: UInt64
}

/// Receives the Trash location from a synchronous document writer.
final class AIChatLocalEditTrashedURL: @unchecked Sendable {
  var value: URL?
}

struct PreparedAIChatLocalEdits: Sendable {
  let documents: [String: AIChatLocalEditDocument]
  let urls: [String: URL]
  let diskBaselines: [String: AIChatLocalEditDiskBaseline]
  let changes: [AIChatCorpusFileChange]
}

enum OrgCryptRecipientScanResult: Sendable {
  case success([OrgCryptRecipientFile])
  case failure(String)
}

struct WorkspaceNavigationSnapshot: Hashable {
  let location: WorkspaceLocation?
  let missingDailyNote: WorkspaceMissingDailyNote?
  let agentRunDetailID: AgentRunItem.ID?
  var webPageURL: URL? = nil
  let selectedSurface: WorkspaceSurface
  let activeWorkspacePane: WorkspacePaneFocus
  let selectedEntrySourceMode: EntrySourceMode
  let agendaMode: AgendaMode
  let runsAndReviewPage: RunsAndReviewPage
  let expandedWorkspaceSurface: WorkspaceSurface?
  let isWorkspaceSurfacePaneClosed: Bool
  let isWorkspaceDetailPaneClosed: Bool
  let isWorkspaceDetailPaneExpanded: Bool
  let isAIChatAssistantPresented: Bool
  let isNodeContextPanePresented: Bool
  let selectedAgendaItemID: String?
  let selectedAssignedWorkItemID: AssignedWorkItem.ID?
  let selectedApprovalItemID: ApprovalItem.ID?
  let selectedAgentRunID: AgentRunItem.ID?
  let selectedAgentWorkflowID: AgentWorkflowItem.ID?
  let selectedAgentGoalID: AgentGoalItem.ID?
  let selectedAgentProfileID: AgentProfileItem.ID?
  let selectedCorpusFileID: String?
  let selectedMeetingID: String?
  let selectedAIChatThreadID: UUID?
  let selectedExternalThreadID: String?
  let selectedWorkspaceSkillID: WorkspaceSkillItem.ID?
}

struct WorkspaceTabState {
  let navigation: WorkspaceNavigationSnapshot
  let backStack: [WorkspaceNavigationSnapshot]
  var forwardStack: [WorkspaceNavigationSnapshot] = []
  let surface: WorkspaceTabSurfaceState
  let editor: WorkspaceTabEditorState
  let documentViewportSourceLines: [String: Int]
  let documentSlidePageIndexes: [String: Int]
  let aiChatScrollPositionsByThreadID: [UUID: Double]
  let aiChatAssistantChatScrollPositionsByThreadID: [UUID: Double]
}

struct WorkspaceTabEditorState {
  let isEditingEntry: Bool
  let selection: NSRange
  let presentation: SourceEditorPresentation
  let isPreviewPaused: Bool
}

struct WorkspaceTabSurfaceState {
  let agendaFilter: String
  let agendaDateFilter: AgendaDateFilter
  let agendaAssigneeFilter: String
  let agendaStatusFilter: String
  let agendaPriorityFilter: String
  let agendaTopicFilter: String
  let agendaReadScope: WorkspaceReadScope
  let bulkSelectedAgendaItemIDs: Set<String>
  let approvalFilter: String
  let selectedApprovalItemIDsForAIContext: Set<ApprovalItem.ID>
  let bulkSelectedApprovalItemIDs: Set<ApprovalItem.ID>
  let agentRunFilter: String
  let agentRunSelectionScope: AgentRunScope
  let selectedAgentRunIDsForAIContext: Set<AgentRunItem.ID>
  let corpusFileFilter: String
  let selectedCorpusFileIDsForAIContext: Set<CorpusFile.ID>
  let searchMode: WorkspaceSearchMode
  let searchReadScope: WorkspaceReadScope
  let searchQuery: String
  let searchResults: [SearchResult]
  let aiChatSearchResults: [AIChatSearchResult]
  let workspaceFileSearchResults: [CorpusFile]
  let workspacePageSearchResults: [OrgRoamNodeReference]
  let workspaceAgentWorkSearchResults: [WorkspaceAgentWorkSearchResult]
  let searchNodes: [OrgRoamNodeReference]
  let externalThreadSearchQuery: String
  let selectedExternalThreadDetail: ExternalThreadDetail?
}

struct AIChatContextPointer: Equatable, Sendable {
  let kind: String
  let displayTitle: String
  let reference: String
  let displayReference: String
  let threadTitle: String
}

enum MeetingReadyAutomationDeliveryStatus: String, Codable, Sendable {
  case baseline
  case queued
  case failed
}

struct MeetingReadyAutomationDeliveryRecord: Hashable, Codable, Sendable {
  let eventID: String
  let meetingFile: String
  let destinationID: String
  let threadID: UUID?
  let status: MeetingReadyAutomationDeliveryStatus
  let updatedAt: Date
  let error: String?
}

public enum AIChatThreadMode: String, CaseIterable, Identifiable, Sendable {
  case newThread
  case currentThread

  public var id: String { rawValue }

  func discussionDestinationTitle(selectedThreadTitle: String?) -> String? {
    switch self {
    case .newThread: return "New thread"
    case .currentThread:
      guard let selectedThreadTitle = selectedThreadTitle?
        .split(whereSeparator: \.isNewline)
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !selectedThreadTitle.isEmpty
      else { return nil }
      let displayTitle = selectedThreadTitle.count > 52
        ? String(selectedThreadTitle.prefix(49)) + "…"
        : selectedThreadTitle
      return "Continue in \u{201c}\(displayTitle)\u{201d}"
    }
  }
}

struct AIChatBlockContextPointer: Equatable, Sendable {
  let file: String
  let startLine: Int
  let endLineExclusive: Int
  let displayTitle: String

  init?(source: EntrySource?, block: OrgEditableBlock) {
    guard let source else { return nil }
    file = source.file
    startLine = block.startLine
    endLineExclusive = block.endLineExclusive
    displayTitle = Self.displayTitle(for: block)
  }

  static func displayTitle(for block: OrgEditableBlock) -> String {
    let title: String
    switch block.rendered {
    case .heading(let heading):
      title = heading.title
    case .paragraph(let text):
      title = text
    case .listItem(_, _, _, let text):
      title = text
    case .planning(let planning):
      title = "\(planning.kind.capitalized) \(planning.value)"
    case .keyword(let key, let value):
      title = value.isEmpty ? key : "\(key): \(value)"
    case .source(let language, _):
      title = language.map { "\($0.uppercased()) code" } ?? "Code block"
    case .table:
      title = "Table"
    case .properties:
      title = "Properties"
    case .quote(let lines):
      title = lines.first ?? "Quote"
    case .horizontalRule:
      title = "Divider"
    case .blank:
      title = "Selected block"
    }
    let firstLine = title.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? title
    let cleaned = firstLine
      .trimmingCharacters(in: CharacterSet(charactersIn: " *_/=~+\t"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return "Selected block" }
    return cleaned.count > 64 ? String(cleaned.prefix(61)) + "…" : cleaned
  }
}

struct AIChatCorpusSnapshot: Sendable {
  let rootPath: String
  let files: [String: AIChatSnapshotFile]
  /// Files already modified after the turn began when the background read
  /// reached them. Their pre-turn text is unknown, so the change summary
  /// leaves them out rather than reporting a wrong diff.
  var unknownPaths: Set<String> = []

  func filtered(to relativePaths: Set<String>) -> AIChatCorpusSnapshot {
    guard !relativePaths.isEmpty else { return self }
    return AIChatCorpusSnapshot(
      rootPath: rootPath,
      files: files.filter { relativePaths.contains($0.key) },
      unknownPaths: unknownPaths.intersection(relativePaths)
    )
  }
}

struct AIChatSnapshotFile: Sendable {
  let text: String
}

enum WorkspaceUndoAction: Equatable, Sendable {
  case aiChatDraft(previous: String, next: String)
  case fileSnapshot(file: String, previous: String?, next: String?)
}

public enum QuickOpenSelectionDirection: Equatable, Sendable {
  case up
  case down
}

public enum WorkspaceQuickOpenItem: Identifiable, Hashable, Sendable {
  case file(CorpusFile)
  case chatThread(AIChatThread)
  case approval(ApprovalItem)

  public var id: String {
    switch self {
    case .file(let file):
      "file:\(file.id)"
    case .chatThread(let thread):
      "chat:\(thread.id.uuidString)"
    case .approval(let approval):
      "approval:\(approval.id)"
    }
  }
}

enum QuickOpenScrollPolicy {
  /// A new result list starts at its first result. Unchanged results keep the
  /// user's scroll position.
  static func resetsToTop(previousIDs: [String], currentIDs: [String]) -> Bool {
    !currentIDs.isEmpty && previousIDs != currentIDs
  }
}

struct QuickOpenIndexedFile: Sendable {
  let file: CorpusFile
  let normalizedRelativePath: String
}

struct QuickOpenIndexedChatThread: Sendable {
  let id: UUID
  let title: String
  let normalizedTitle: String
}

struct AIChatQuickOpenChatIndexSignature: Equatable {
  let id: UUID
  let title: String
}

struct PublishedAIChatMessagesIdentity: Equatable {
  let threadID: UUID
  let revision: UInt64
}

enum QuickOpenSearchMatch: Sendable {
  case file(CorpusFile)
  case chatThread(UUID)
  case approval(ApprovalItem)
}

/// A pending approval as Quick Open matches it: by title, then by what it
/// asks for, so "deploy" finds "Approve production deploy".
struct QuickOpenIndexedApproval: Sendable {
  let item: ApprovalItem
  let normalizedTitle: String
  let normalizedDetail: String

  init(_ item: ApprovalItem) {
    self.item = item
    normalizedTitle = WorkspaceStore.normalizedQuickOpenCandidate(item.title)
    normalizedDetail = WorkspaceStore.normalizedQuickOpenCandidate(
      [item.action, item.runGoal].compactMap { $0 }.joined(separator: " ")
    )
  }
}

struct AssignedWorkSearchRow: Sendable {
  let item: AssignedWorkItem
  let searchText: String
}

struct AIChatDestinationTurnKey: Hashable {
  let transcriptPath: String
  let threadID: UUID
  let destinationID: String
}

struct AgendaDisplayBuckets: Sendable {
  var overdue: [AgendaItem] = []
  var today: [AgendaItem] = []
  var next7: [AgendaItem] = []
  var later: [AgendaItem] = []
}

final class MutableCorpusFileTreeNode {
  var directories: [String: MutableCorpusFileTreeNode] = [:]
  var files: [CorpusFile] = []
}

struct SearchNodeIndexRow: Sendable {
  let node: OrgRoamNodeReference
  let normalizedCandidates: [String]
  let normalizedLabels: [String]
}

struct OrgRoamSearchProjection: Sendable {
  let resolver: OrgRoamLinkResolver
  let searchNodeIndexRows: [SearchNodeIndexRow]
  let wasBuiltOnMainThread: Bool
}

struct OrgRoamSearchProjectionReleaseSnapshot: Sendable {
  let scheduledCount: Int
  let completedCount: Int
  let mainThreadCount: Int
}

final class OrgRoamSearchProjectionReleaseMetrics: @unchecked Sendable {
  let lock = NSLock()
  private var scheduledCount = 0
  var completedCount = 0
  private var mainThreadCount = 0

  func recordScheduled(count: Int) {
    lock.lock()
    scheduledCount &+= count
    lock.unlock()
  }

  func recordCompleted(onMainThread: Bool) {
    lock.lock()
    completedCount &+= 1
    if onMainThread { mainThreadCount &+= 1 }
    lock.unlock()
  }

  var snapshot: OrgRoamSearchProjectionReleaseSnapshot {
    lock.lock()
    let snapshot = OrgRoamSearchProjectionReleaseSnapshot(
      scheduledCount: scheduledCount,
      completedCount: completedCount,
      mainThreadCount: mainThreadCount
    )
    lock.unlock()
    return snapshot
  }
}

/// ARC ownership carrier for a corpus-scale immutable projection. The unchecked
/// conformance is safe because both stored references are immutable, the full
/// projection graph is `Sendable`, and release metrics synchronize all mutation.
/// Keeping the graph in one box lets rejected and replaced snapshots transfer
/// their final reference to a detached release sink instead of MainActor.
final class OrgRoamSearchProjectionBox: @unchecked Sendable {
  let projection: OrgRoamSearchProjection
  let releaseMetrics: OrgRoamSearchProjectionReleaseMetrics

  init(
    projection: OrgRoamSearchProjection,
    releaseMetrics: OrgRoamSearchProjectionReleaseMetrics
  ) {
    self.projection = projection
    self.releaseMetrics = releaseMetrics
  }

  deinit {
    releaseMetrics.recordCompleted(onMainThread: Thread.isMainThread)
  }
}

/// Owns retired corpus-scale projections until the publishing MainActor turn
/// has completely returned, then releases them serially on a utility queue.
/// A directly launched detached task can finish while publisher/caller locals
/// still retain the same COW graph, leaving MainActor to drop the final owner.
final class OrgRoamSearchProjectionReleaseSink: @unchecked Sendable {
  let lock = NSLock()
  private var pendingBoxes: [OrgRoamSearchProjectionBox] = []
  private var isDrainAcknowledgementScheduled = false
  private let releaseQueue = DispatchQueue(
    label: "org.org2.workspace.roam-search-projection-release",
    qos: .utility
  )

  func enqueue(_ boxes: [OrgRoamSearchProjectionBox]) {
    guard !boxes.isEmpty else { return }
    boxes.forEach { $0.releaseMetrics.recordScheduled(count: 1) }
    let shouldScheduleAcknowledgement = lock.withLock { () -> Bool in
      pendingBoxes.append(contentsOf: boxes)
      guard !isDrainAcknowledgementScheduled else { return false }
      isDrainAcknowledgementScheduled = true
      return true
    }
    guard shouldScheduleAcknowledgement else { return }

    // This acknowledgement cannot run until the current MainActor turn has
    // returned and all publisher/caller temporaries have left their scopes.
    DispatchQueue.main.async { [weak self] in
      self?.scheduleUtilityDrain()
    }
  }

  private func scheduleUtilityDrain() {
    releaseQueue.async { [weak self] in
      self?.drain()
    }
  }

  func drain() {
    let boxes = lock.withLock { () -> [OrgRoamSearchProjectionBox] in
      let boxes = pendingBoxes
      pendingBoxes = []
      isDrainAcknowledgementScheduled = false
      return boxes
    }
    withExtendedLifetime(boxes) {}
  }
}

struct AIChatDictationOrigin: Sendable {
  let threadID: UUID
  let threadTitle: String
  let runtime: AIChatRuntime
  let workspaceContext: AIChatWorkspaceContext
  let context: AIChatCorpusContextToken
}

struct OrgIDLookupPayload: Decodable {
  let id: String
  let kind: String
  let file: String
  let line: Int
  let headingLine: Int?
}

struct OrgCryptCLIPayload: Decodable {
  let action: String
  let file: String
  let headingLine: Int
  let applied: Bool
  let changed: Bool
  let gpgProgram: String
  let recipients: [String]
  let recipientFiles: [String]
}

struct RefileMutationPayload: Decodable {
  let changed: Bool
}

struct ArchiveMutationPayload: Decodable {
  let wrote: Bool
  let archivePath: String
}

struct RoamLinkifyPayload: Decodable {
  let changedFileCount: Int
  let replacementCount: Int
  let ambiguousSkipCount: Int
  let representedSuggestionCount: Int
  let applied: Bool
}

struct DataQueryApplyPayload: Decodable {
  let changed: Bool
  let changedResultCount: Int
  let resultCount: Int
}

public enum DataNotebookRefreshFailureKind: String, Equatable, Sendable {
  case authentication
  case configuration
  case query
}

public struct DataNotebookRefreshFailure: Equatable, Sendable {
  public let kind: DataNotebookRefreshFailureKind
  public let title: String
  public let message: String

  public var needsCredentialUpdate: Bool {
    kind == .authentication || kind == .configuration
  }
}

struct SearchIndexBuildPayload: Decodable {
  let fileCount: Int
  let lineCount: Int
  let skippedFiles: Int
}

struct ApprovalPayload: Decodable {
  let count: Int
  let items: [ApprovalItem]
  let runDetails: [AgentRunItem]?
}

struct WorkspaceSearchIndex: Decodable {
  let schema: String
  let version: Int
  let rootDir: String
  let recursive: Bool
  let includeArchives: Bool
  let files: [WorkspaceSearchIndexFile]

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case version
    case rootDir
    case recursive
    case includeArchives
    case files
  }
}

struct WorkspaceSearchIndexFile: Decodable {
  let path: String
  let relativePath: String
  let modifiedMs: Int64
  let byteCount: Int64
  let lines: [String]
}

struct SplitDraftSpec {
  let insertionLineOffset: Int
  let displayLineOffset: Int
  let rawText: String
  let rendered: OrgRenderedBlock
  let replacementPrefix: String
  let replacementSuffix: String
  let selectionLineOffset: Int
}

struct SplitBlockPlan {
  let replacement: String?
  let newBlockLineOffset: Int?
  let draft: SplitDraftSpec?
}

struct PageSearchRenderedMatch: Equatable, Sendable {
  let blockID: OrgEditableBlock.ID
  let blockIndex: Int
  let occurrenceOffsetInBlock: Int
}

struct PageSearchComputation: Sendable {
  let matches: [PageSearchRenderedMatch]
  let occurrenceCount: Int
}

struct SourceBlockExecutionResult: Equatable, Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
  let timedOut: Bool
  let timeout: TimeInterval
}

public struct CreatedKnowledgeNode: Equatable, Sendable {
  public let title: String
  public let file: String
  public let id: String

  public init(title: String, file: String, id: String) {
    self.title = title
    self.file = file
    self.id = id
  }
}

public struct InlineSelectionReplacement: Equatable, Sendable {
  public let text: String
  public let selectedRange: NSRange

  public init(text: String, selectedRange: NSRange) {
    self.text = text
    self.selectedRange = selectedRange
  }
}

public enum WorkspaceCaptureKind: String, CaseIterable, Identifiable, Sendable {
  case task
  case note

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .task: "Task"
    case .note: "Note"
    }
  }
}

public enum WorkspaceCaptureAttachmentKind: String, Sendable {
  case file
  case image
  case video
  case link
}

public struct WorkspaceCaptureAttachmentDraft: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var kind: WorkspaceCaptureAttachmentKind
  public var name: String
  public var sourceURL: URL?
  public var data: Data?
  public var suggestedExtension: String

  public init(
    id: UUID = UUID(),
    kind: WorkspaceCaptureAttachmentKind,
    name: String,
    sourceURL: URL? = nil,
    data: Data? = nil,
    suggestedExtension: String = ""
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.sourceURL = sourceURL
    self.data = data
    self.suggestedExtension = suggestedExtension
  }
}

public struct WorkspaceCaptureDraft: Equatable, Sendable {
  public var kind: WorkspaceCaptureKind
  public var title: String
  public var body: String
  public var todoStatus: TodoEditStatus
  public var includeScheduled: Bool
  public var scheduledDate: Date
  public var includeDeadline: Bool
  public var deadlineDate: Date
  public var priority: String
  public var tagsText: String
  public var assignToAgent: Bool
  public var attachments: [WorkspaceCaptureAttachmentDraft]

  public init(
    kind: WorkspaceCaptureKind = .task,
    title: String = "",
    body: String = "",
    todoStatus: TodoEditStatus = .todo,
    includeScheduled: Bool = true,
    scheduledDate: Date = Date(),
    includeDeadline: Bool = false,
    deadlineDate: Date = Date(),
    priority: String = "",
    tagsText: String = "",
    assignToAgent: Bool = false,
    attachments: [WorkspaceCaptureAttachmentDraft] = []
  ) {
    self.kind = kind
    self.title = title
    self.body = body
    self.todoStatus = todoStatus
    self.includeScheduled = includeScheduled
    self.scheduledDate = scheduledDate
    self.includeDeadline = includeDeadline
    self.deadlineDate = deadlineDate
    self.priority = priority
    self.tagsText = tagsText
    self.assignToAgent = assignToAgent
    self.attachments = attachments
  }
}

public struct SimilarTodoCandidate: Identifiable, Hashable, Sendable {
  public let file: String
  public let line: Int
  public let headline: String
  public let todo: String?
  public let tags: [String]
  public let properties: [String: String]
  public let score: Double

  public init(
    file: String,
    line: Int,
    headline: String,
    todo: String?,
    tags: [String] = [],
    properties: [String: String] = [:],
    score: Double = 1
  ) {
    self.file = file
    self.line = line
    self.headline = headline
    self.todo = todo
    self.tags = tags
    self.properties = properties
    self.score = score
  }

  public var id: String {
    "\(file):\(line):\(headline)"
  }
}

struct WorkspaceCapturePasteboardContent {
  var text: String = ""
  var attachments: [WorkspaceCaptureAttachmentDraft] = []
}

struct StartWorkRunCreatePayload: Decodable, Sendable {
  let run: AgentRunItem
}

struct HeadlineMutationTarget: Sendable {
  let file: String
  let line: Int
  let title: String
  let agendaItemID: String?
  let idValue: String?

  init(file: String, line: Int, title: String, agendaItemID: String? = nil, idValue: String? = nil) {
    self.file = file
    self.line = line
    self.title = title
    self.agendaItemID = agendaItemID
    self.idValue = idValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
  }

  init(item: AgendaItem) {
    self.init(
      file: item.file,
      line: item.lineForEditor,
      title: Org2Display.cleanInline(item.headline),
      agendaItemID: item.id,
      idValue: item.properties["ID"]
    )
  }
}

struct ApprovalSelectionAnchor {
  let file: String
  let idValue: String?
  let title: String
  let visibleIndex: Int?

  init(item: ApprovalItem, visibleIndex: Int?) {
    self.file = item.file
    self.idValue = item.idValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    self.title = item.title
    self.visibleIndex = visibleIndex
  }
}

struct ApprovalCandidateSource: Sendable {
  let file: CorpusFile
  let sourceText: String
  let parseText: String
  let sourceLineOffset: Int
}

struct ApprovalCandidateSourceSlice: Equatable, Sendable {
  let sourceText: String
  let sourceLineOffset: Int
}

struct AgendaTodoShortcutMutation: Sendable {
  let status: TodoEditStatus
  let target: HeadlineMutationTarget
  let context: WorkspaceDocumentCorpusContext
}

struct AgendaSelectionAnchor {
  let file: String
  let idValue: String?
  let headline: String
  let kind: String
  let line: Int

  init(item: AgendaItem) {
    self.file = URL(fileURLWithPath: item.file).standardizedFileURL.path
    self.idValue = item.idValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    self.headline = item.headline
    self.kind = item.kind
    self.line = item.line
  }
}

struct ApprovedAgentActionResult: Sendable {
  let title: String
  let file: String
  let line: Int
  let created: Bool
}

struct ApprovalRejectionChoice {
  let endStatus: TodoEditStatus
  let reason: String
}

enum ApprovalActionKind {
  case approve
  case reject
  case externalCompletion
  case snooze
}

enum ApprovalSourceRepairRetry {
  case approve
  case reject(endStatus: TodoEditStatus, reason: String)
  case externalCompletion(summary: String)
  case requestChanges(feedback: String)
}

struct AIChatSendOrigin {
  let corpusRoot: URL?
  let transcriptURL: URL
  let workspaceContext: AIChatWorkspaceContext
  let context: AIChatCorpusContextToken
}

struct AIChatCorpusContextToken: Equatable, Sendable {
  let corpusRootPath: String?
  let corpusSessionGeneration: UInt64
  let transcriptPath: String
  let transcriptLoadGeneration: UInt64
}

enum AIChatEnqueueOutcome: Sendable {
  case rejected
  case superseded
  case enqueued(threadID: UUID, shouldDrain: Bool)
}

enum AIChatEnqueueResult {
  case rejected
  case deferred(Task<AIChatEnqueueOutcome, Never>)
  case enqueued(threadID: UUID, shouldDrain: Bool)
}

enum AIChatEnqueueFailure: LocalizedError {
  case rejected

  var errorDescription: String? {
    "The AI chat message could not be queued."
  }
}

struct AIChatComposerKey: Hashable, Sendable {
  let transcriptPath: String
  let threadID: UUID
}

struct AIChatComposerSubmission: Sendable {
  let context: AIChatCorpusContextToken
  let threadID: UUID
  let draft: String
  let attachments: [AIChatAttachment]

  var attachmentIDs: Set<UUID> {
    Set(attachments.map(\.id))
  }
}

struct WorkspaceSearchRequestContext: Equatable, Sendable {
  let requestGeneration: UInt64
  let corpusRootPath: String?
  let corpusSessionGeneration: UInt64
  let query: String
  let readScope: WorkspaceReadScope
  let transcriptPath: String
  let transcriptLoadGeneration: UInt64
}

struct RunReviewPageLoadState: Sendable {
  var corpusRootPath: String?
  var corpusSessionGeneration: UInt64
  var isLoaded: Bool
  var isDirty: Bool
  var dirtyGeneration: UInt64
}

struct CachedRunReviewPageLoadState: Sendable {
  var isLoaded: Bool
  var isDirty: Bool
  var dirtyGeneration: UInt64
}

struct RunReviewPageRefreshContext: Sendable {
  let page: RunsAndReviewPage
  let corpusRootPath: String
  let corpusSessionGeneration: UInt64
  let dirtyGeneration: UInt64
}

struct WorkspaceDocumentCorpusContext: Equatable, Sendable {
  let activeCorpusRootPath: String
  let mutationRootPath: String
  let corpusSessionGeneration: UInt64
}

struct AssignedWorkRefreshContext: Sendable {
  let requestID: UUID
  let requestGeneration: UInt64
  let corpus: WorkspaceDocumentCorpusContext
  let corpusFilesGeneration: UInt64
  let corpusFileEventSerial: Int
  let dirtyGeneration: UInt64
}

struct SimilarTodoScanContext: Sendable {
  let requestGeneration: UInt64
  let corpus: WorkspaceDocumentCorpusContext
  let corpusFilesGeneration: UInt64
  let corpusFileEventSerial: Int
  let targetFile: String
  let targetLine: Int
  let targetTitle: String
  let targetID: String?
}

struct CorpusWorkspaceCache {
  var cachedAt: Date
  var identity: CorpusIdentity?
  var agenda: AgendaPayload?
  var approvalItems: [ApprovalItem]
  var agentRuns: [AgentRunItem]
  var agentWorkflows: [AgentWorkflowItem]
  var agentGoals: [AgentGoalItem]
  var agentProfiles: [AgentProfileItem]
  var corpusFiles: [CorpusFile]
  var orgRoamLinkResolver: OrgRoamLinkResolver
  var searchNodeIndexRows: [SearchNodeIndexRow]
  var assignedWorkItems: [AssignedWorkItem]
  var meetings: [MeetingWorkspaceItem]
  var sourceProfiles: [WorkspaceSourceProfileStatus]
  var sourceRuntimeStatuses: [String: WorkspaceSourceRuntimeStatus]
  var sourceScheduleStates: [String: WorkspaceSourceScheduleState]
  var aiChatThreadRecords: [AIChatThreadRecord]
  var workspaceHealthChecks: [WorkspaceHealthCheck]
  var searchIndexStatusText: String
  var dirtySurfaces: Set<WorkspaceSurface>
  var runReviewPageLoadStates: [String: CachedRunReviewPageLoadState]
  var selectedAgendaItemID: String?
  var selectedApprovalItemID: ApprovalItem.ID?
  var selectedAgentRunID: AgentRunItem.ID?
  var selectedAgentWorkflowID: AgentWorkflowItem.ID?
  var selectedAgentGoalID: AgentGoalItem.ID?
  var selectedAgentProfileID: AgentProfileItem.ID?
  var selectedCorpusFileID: String?
  var selectedAssignedWorkItemID: AssignedWorkItem.ID?
  var selectedMeetingID: String?
  var selectedAIChatThreadRecordID: String?
}

struct PinnedCorpusFileProjection: Sendable {
  let files: [CorpusFile]
  let existingRelativePaths: [String]
  let wasBuiltOnMainThread: Bool
}

struct RecoverableMeetingRecording: Sendable {
  let paths: MeetingArtifactPaths
  let duration: TimeInterval?
  let systemAudioURL: URL?
  let systemAudioCaptureError: String?
  let captureSources: String
}

public struct WorkspaceRuntimeIdentity: Equatable, Sendable {
  public let executablePath: String
  public let bundlePath: String
  public let bundleIdentifier: String?
  public let isAppBundle: Bool

  public static var compiledBuildConfiguration: String {
#if DEBUG
    "debug"
#else
    "release"
#endif
  }

  public var buildConfiguration: String {
    Self.compiledBuildConfiguration
  }

  public var buildConfigurationLabel: String {
    buildConfiguration == "release" ? "Optimized release" : "Debug"
  }

  public var isOptimizedBuild: Bool {
    buildConfiguration == "release"
  }

  public var audioPermissionStatusLabel: String {
    isAppBundle ? "Stable app bundle" : "Debug executable"
  }

  public var audioPermissionDetailText: String {
    if isAppBundle {
      return "Screen/System Audio permission should apply to this app bundle after relaunch."
    }
    return "Screen/System Audio permission may not apply reliably to a rebuilt SwiftPM debug executable. Launch an installed OpenOrg.app bundle for stable TCC permissions."
  }

  public static func current(
    bundle: Bundle = .main
  ) -> WorkspaceRuntimeIdentity {
    WorkspaceRuntimeIdentity(
      executablePath: bundle.executableURL?.path ?? ProcessInfo.processInfo.arguments.first ?? "",
      bundlePath: bundle.bundleURL.path,
      bundleIdentifier: bundle.bundleIdentifier,
      isAppBundle: bundle.bundleURL.pathExtension.lowercased() == "app"
    )
  }
}

@MainActor
public final class SourceEditorInteractionModel: ObservableObject {
  @Published public var text: String {
    didSet { bindingGeneration &+= 1 }
  }
  @Published public var selection: NSRange
  public private(set) var documentGeneration: UInt64 = 0
  public private(set) var bindingGeneration: UInt64 = 0

  public init(
    text: String = "",
    selection: NSRange = NSRange(location: 0, length: 0)
  ) {
    self.text = text
    self.selection = selection
  }

  func reset(text: String, selection: NSRange) {
    documentGeneration &+= 1
    // The caller already owns an immutable source snapshot. Assigning it is
    // O(1) under String copy-on-write; comparing multi-megabyte contents here
    // would put navigation back on the main-thread hot path.
    self.text = text
    if self.selection != selection {
      self.selection = selection
    }
  }
}

@MainActor
@Observable
public final class WorkspaceStore {
  static let aiChatDispatchOwnerID = ProcessInfo.processInfo.hostName.lowercased()
  /// The OpenOrg host this process represents in chat provenance, presence,
  /// and turn routing.
  public internal(set) var aiChatHostIdentity = AIChatHostIdentity.desktop(
    writer: AIChatTranscriptStore.shared.writerIdentity
  )
  /// Presence records published by other hosts that share this corpus.
  public internal(set) var aiChatRemoteLiveHosts: [AIChatLiveHostRecord] = []
  @ObservationIgnored var aiChatLivePresenceTask: Task<Void, Never>?
  @ObservationIgnored var lastPublishedAIChatLiveRecord: AIChatLiveHostRecord?
  @ObservationIgnored var lastPublishedAIChatLiveTranscriptURL: URL?
  @ObservationIgnored var aiChatLiveRefreshTask: Task<Void, Never>?
  @ObservationIgnored var aiChatLiveRefreshNeeded = false
  @ObservationIgnored var aiChatHandoffHydrationRequests: Set<UUID> = []
  /// Imported `sending` messages that another host owns. They label the
  /// conversation as busy but are never dispatched by this host's queue.
  @ObservationIgnored var aiChatForeignPendingMessageIDs: Set<UUID> = []
  /// Threads whose orphaned managed-remote OpenCode turn this host is reading.
  @ObservationIgnored var adoptingOpenCodeTurnThreadIDs: Set<UUID> = []
  /// Where this machine's managed-remote OpenCode supervisors keep run records.
  @ObservationIgnored var openCodeLocalRunDirectory = OpenCodeClient.localRunDirectory()
  @ObservationIgnored var aiChatLiveHeartbeatInterval: TimeInterval = 45
  @ObservationIgnored var aiChatLiveFreshnessInterval: TimeInterval = 150
  @ObservationIgnored var aiChatHandoffTimeout: TimeInterval = 120
  @ObservationIgnored var aiChatLivePresenceTickNanoseconds: UInt64 = 1_000_000_000
  /// Continue a conversation on the host that already runs it when that host
  /// is online and has the destination enabled.
  @ObservationIgnored public var aiChatRoutesTurnsToThreadHost = true
  /// This host is finishing running turns before a restart or update; new
  /// turns go to another online host (or wait for this one to return).
  public internal(set) var isAIChatDraining = false
  /// A headless OpenOrg host that should own new local agent turns so this
  /// Mac can quit, sleep, or update without interrupting them. Nil runs turns
  /// here. Machine-local preference.
  public var aiChatPreferredExecutionHostRef: String? {
    didSet {
      guard oldValue != aiChatPreferredExecutionHostRef else { return }
      if let ref = aiChatPreferredExecutionHostRef, !ref.isEmpty {
        defaults.set(ref, forKey: Self.aiChatPreferredExecutionHostKey)
      } else {
        defaults.removeObject(forKey: Self.aiChatPreferredExecutionHostKey)
      }
    }
  }
  nonisolated static let aiChatPreferredExecutionHostKey = "Org2Workspace.aiChat.preferredExecutionHostRef.v1"
  nonisolated public static let meetingCaptureSourceSummary = "Captures microphone and system/call audio. System audio uses macOS ScreenCaptureKit permission; Celorga records audio only."
  nonisolated public static let defaultAgentHandoffAssignee = "OpenClaw"
  nonisolated public static let agendaOpenStatusFilter = "__open__"
  nonisolated public static let agendaCompletedStatusFilter = "__completed__"
  nonisolated public static let agendaUnassignedFilter = "__unassigned__"
  nonisolated public static let agendaNoPriorityFilter = "__no_priority__"
  nonisolated public static let runReviewAutoRefreshIntervalNanoseconds: UInt64 = 60_000_000_000
  nonisolated public static let defaultWorkspaceRefreshSlowNoticeNanoseconds: UInt64 = 15_000_000_000
  nonisolated static let workspaceRefreshSlowNotice = "Workspace refresh is still running. Large workspaces can take longer; press ⌘R to cancel."
  nonisolated public static let defaultEntryRenderTimeoutNanoseconds: UInt64 = 15_000_000_000
  nonisolated public static let sourceAutoSyncCheckIntervalNanoseconds: UInt64 = 60_000_000_000
  nonisolated public static let automationScheduleCheckIntervalNanoseconds: UInt64 = 60_000_000_000
  nonisolated public static let pullRequestPollIntervalSeconds: TimeInterval = 120
  /// A missing or signed-out `gh` is rechecked less often.
  nonisolated public static let pullRequestPollAttentionIntervalSeconds: TimeInterval = 900
  nonisolated public static let applicationActivationRefreshDelayNanoseconds: UInt64 = 250_000_000
  nonisolated static let workspaceSearchCandidateLimit = 200
  nonisolated static let workspaceSearchDisplayLimit = 50
  nonisolated static let workspaceSearchMergedDisplayLimit = 100
  nonisolated static let agendaRangeDays = 30

  public internal(set) var workspaceTabs: [WorkspaceTab]
  public internal(set) var selectedWorkspaceTabID: WorkspaceTab.ID

  public var selectedSurface: WorkspaceSurface = .home {
    didSet {
      guard oldValue != selectedSurface else { return }
      if isWorkspaceSurfacePaneClosed { isWorkspaceSurfacePaneClosed = false }
      if expandedWorkspaceSurface != nil { expandedWorkspaceSurface = nil }
      if isWorkspaceDetailPaneExpanded { isWorkspaceDetailPaneExpanded = false }
      scheduleRefreshForActivatedSurface(selectedSurface)
    }
  }
  public var expandedWorkspaceSurface: WorkspaceSurface?
  public var isWorkspaceSurfacePaneClosed = false
  public var isWorkspaceDetailPaneClosed = false
  public var isWorkspaceDetailPaneExpanded = false
  var activeWorkspacePane: WorkspacePaneFocus = .surface
  public var agendaMode: AgendaMode = .focus {
    didSet {
      defaults.set(agendaMode.rawValue, forKey: agendaModeKey)
      rebuildAgendaDisplayCache()
    }
  }
  public var agendaOverdueOrder: AgendaOverdueOrder = .priority {
    didSet {
      guard oldValue != agendaOverdueOrder else { return }
      defaults.set(agendaOverdueOrder.rawValue, forKey: agendaOverdueOrderKey)
      rebuildAgendaDisplayCache()
    }
  }
  public var agendaFilter = "" {
    didSet {
      guard oldValue != agendaFilter else { return }
      rebuildAgendaDisplayCache()
      rebuildAssignedWorkDisplayCache()
    }
  }
  var isUpdatingAgendaStructuredFilters = false
  public var agendaDateFilter: AgendaDateFilter = .any {
    didSet {
      guard oldValue != agendaDateFilter, !isUpdatingAgendaStructuredFilters else { return }
      rebuildAgendaDisplayCache()
    }
  }
  public var agendaAssigneeFilter = "" {
    didSet {
      guard oldValue != agendaAssigneeFilter, !isUpdatingAgendaStructuredFilters else { return }
      rebuildAgendaDisplayCache()
      rebuildAssignedWorkDisplayCache()
    }
  }
  public var agendaStatusFilter = "" {
    didSet {
      guard oldValue != agendaStatusFilter, !isUpdatingAgendaStructuredFilters else { return }
      rebuildAgendaDisplayCache()
      rebuildAssignedWorkDisplayCache()
    }
  }
  public var agendaPriorityFilter = "" {
    didSet {
      guard oldValue != agendaPriorityFilter, !isUpdatingAgendaStructuredFilters else { return }
      rebuildAgendaDisplayCache()
      rebuildAssignedWorkDisplayCache()
    }
  }
  public var agendaTopicFilter = "" {
    didSet {
      guard oldValue != agendaTopicFilter, !isUpdatingAgendaStructuredFilters else { return }
      rebuildAgendaDisplayCache()
      rebuildAssignedWorkDisplayCache()
    }
  }
  public internal(set) var agendaAssigneeFilterOptions: [String] = []
  public internal(set) var agendaStatusFilterOptions: [String] = []
  public internal(set) var agendaPriorityFilterOptions: [String] = []
  public internal(set) var agendaTopicFilterOptions: [String] = []
  public var agendaFilterFocusToken = 0
  public var agendaReadScope: WorkspaceReadScope = .activeCorpus
  public var isAgendaFilterFocused = false
  public var selectedAgendaItemID: String?
  public var bulkSelectedAgendaItemIDs: Set<String> = []
  var suppressNextAgendaSelectionActivation = false
  var projectNotes: [WorkspaceProjectNote] = []
  var projectStatus = ""
  var isRefreshingProjects = false
  var projectRefreshID = UUID()
  @ObservationIgnored var projectRefreshTask: (id: UUID, task: Task<Void, Never>)?
  var projectMutationIDs: Set<String> = []
  public var corpusRoot: URL?
  public internal(set) var mountedCorpora: [WorkspaceCorpusMount] = []
  public internal(set) var activeCorpusIdentity: CorpusIdentity?
  public internal(set) var isSwitchingCorpus = false
  public var agenda: AgendaPayload? {
    didSet {
      rebuildAgendaSearchIndex()
      rebuildAgendaDisplayCache()
    }
  }
  public internal(set) var agendaDisplaySections: [AgendaDisplaySection] = []
  /// Set when the published corpus file list has not yet been projected into
  /// the link resolver and search index.
  @ObservationIgnored var corpusFilesAwaitingProjection = false
  public internal(set) var visibleAgendaItems: [AgendaItem] = [] {
    didSet { visibleAgendaItemIDs = Set(visibleAgendaItems.map(\.id)) }
  }
  /// Membership for bulk-selection counts, rebuilt once per agenda change.
  private(set) var visibleAgendaItemIDs: Set<AgendaItem.ID> = []
  var agendaDisplayBuckets = AgendaDisplayBuckets()
  var agendaFilterTextByItemID: [AgendaItem.ID: String] = [:]
  public internal(set) var approvalItems: [ApprovalItem] = [] {
    didSet {
      rebuildApprovalSearchIndex()
      rebuildApprovalDisplayCache()
      approvalQueueChangeHandler(approvalItems)
    }
  }
  /// Pending approvals hidden until their snooze time passes. Kept apart from
  /// `approvalItems` so counts, badges, phone prompts, and digests only see awake work.
  public internal(set) var snoozedApprovalItems: [ApprovalItem] = [] {
    didSet { rebuildApprovalDisplayCache() }
  }
  /// Shows the snoozed list in place of the pending queue.
  public var showsSnoozedApprovals = false {
    didSet {
      guard oldValue != showsSnoozedApprovals else { return }
      bulkSelectedApprovalItemIDs = []
      rebuildApprovalDisplayCache()
    }
  }
  @ObservationIgnored var approvalSnoozeWakeTask: Task<Void, Never>?
  public var approvalFilter = "" {
    didSet {
      guard oldValue != approvalFilter else { return }
      rebuildApprovalDisplayCache()
    }
  }
  public var approvalFilterFocusToken = 0
  public internal(set) var visibleApprovalItems: [ApprovalItem] = []
  var approvalFilterTextByItemID: [ApprovalItem.ID: String] = [:]
  public var selectedApprovalItemID: ApprovalItem.ID?
  public var selectedApprovalItemIDsForAIContext: Set<ApprovalItem.ID> = []
  public var bulkSelectedApprovalItemIDs: Set<ApprovalItem.ID> = []
  public var runsAndReviewPage: RunsAndReviewPage = .runs
  var agentRunSelectionScope: AgentRunScope = .active
  public var isLoadingApprovals = false
  public internal(set) var hasCompletedApprovalsLoad = false
  public internal(set) var approvalLoadErrorText: String?
  public var shouldShowInitialApprovalsLoadingState: Bool {
    isLoadingApprovals && approvalItems.isEmpty && !hasCompletedApprovalsLoad
  }
  public internal(set) var agentRuns: [AgentRunItem] = [] {
    didSet {
      agentRunsRevision &+= 1
      scheduleAgentRunProjectionRefresh()
    }
  }
  public var agentRunFilter = "" {
    didSet {
      agentRunFilterTerms = Self.filterTerms(from: agentRunFilter)
      scheduleAgentRunProjectionRefresh(debounce: true)
    }
  }
  public var agentRunFilterFocusToken = 0
  public internal(set) var agentRunDisplayRevision = 0
  public var selectedAgentRunID: AgentRunItem.ID?
  public var selectedAgentRunIDsForAIContext: Set<AgentRunItem.ID> = []
  public internal(set) var presentedAgentRunID: AgentRunItem.ID?
  /// A web page opened from a link, shown in the detail pane like a document.
  public internal(set) var presentedWebPageURL: URL?
  public internal(set) var isLoadingAgentRuns = false
  public internal(set) var isRefreshingWorkspace = false
  public internal(set) var mutatingAgentRunIDs: Set<AgentRunItem.ID> = []
  /// The current step of each in-flight Reply & Resume request.
  public internal(set) var agentRunClarificationPhases: [AgentRunItem.ID: AgentRunClarificationReplyPhase] = [:]
  public internal(set) var agentWorkflows: [AgentWorkflowItem] = []
  public var selectedAgentWorkflowID: AgentWorkflowItem.ID?
  public internal(set) var isLoadingAgentWorkflows = false
  public internal(set) var mutatingAgentWorkflowIDs: Set<AgentWorkflowItem.ID> = []
  public internal(set) var automationSchedulerStatusText = "Automation scheduler is starting"
  @ObservationIgnored var hasSettledAutomationSchedulerStatus = false
  public internal(set) var automationSchedulerErrorText: String?
  /// Problems from the deterministic TODO-state detector, such as a write conflict.
  public internal(set) var workflowTodoStateStatusText: String?
  /// GitHub CLI availability or polling problems for pull-request triggers.
  public internal(set) var workflowPullRequestStatusText: String?
  public var workflowEventSourceStatusText: String? {
    let parts = [workflowTodoStateStatusText, workflowPullRequestStatusText].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }
  @ObservationIgnored var lastDueEventSources: AgentWorkflowEventSources?
  @ObservationIgnored var lastPullRequestPollAt: Date?
  @ObservationIgnored var lastPullRequestPollNeedsAttention = false
  @ObservationIgnored var isRunningWorkflowEventDetectors = false
  public internal(set) var automationOwnerHostRef: String?
  public internal(set) var agentGoals: [AgentGoalItem] = []
  public var selectedAgentGoalID: AgentGoalItem.ID?
  public internal(set) var isLoadingAgentGoals = false
  public internal(set) var mutatingAgentGoalIDs: Set<AgentGoalItem.ID> = []
  public internal(set) var agentProfiles: [AgentProfileItem] = []
  public var selectedAgentProfileID: AgentProfileItem.ID?
  public internal(set) var isLoadingAgentProfiles = false
  public internal(set) var mutatingAgentProfileIDs: Set<AgentProfileItem.ID> = []
  public internal(set) var approvingApprovalItemIDs: Set<ApprovalItem.ID> = []
  public internal(set) var rejectingApprovalItemIDs: Set<ApprovalItem.ID> = []
  public internal(set) var externallyCompletingApprovalItemIDs: Set<ApprovalItem.ID> = []
  public internal(set) var snoozingApprovalItemIDs: Set<ApprovalItem.ID> = []
  public internal(set) var repairingApprovalSourceItemIDs: Set<ApprovalItem.ID> = []
  public internal(set) var approvalActionErrorsByItemID: [ApprovalItem.ID: String] = [:]
  @ObservationIgnored var approvalSourceRepairRetriesByItemID: [ApprovalItem.ID: ApprovalSourceRepairRetry] = [:]
  public var corpusFiles: [CorpusFile] = [] {
    didSet {
      corpusFilesGeneration &+= 1
      scheduleCorpusFileProjection()
    }
  }
  public internal(set) var pinnedFileRelativePaths: [String] = []
  public internal(set) var pinnedCorpusFiles: [CorpusFile] = []
  public internal(set) var orgRoamLinkResolver = OrgRoamLinkResolver.empty
  public var selectedCorpusFileID: String?
  public var selectedCorpusFileIDsForAIContext: Set<CorpusFile.ID> = []
  public var corpusFileFilter = "" {
    didSet {
      guard oldValue != corpusFileFilter else { return }
      scheduleCorpusFileDisplayRefresh()
    }
  }
  public internal(set) var filteredCorpusFiles: [CorpusFile] = []
  public internal(set) var corpusFileTree: [CorpusFileTreeNode] = []
  public internal(set) var filteredCorpusFileTree: [CorpusFileTreeNode] = []
  public var corpusFileFilterFocusToken = 0
  public var isScanningCorpusFiles = false
  public var isQuickOpenPresented = false
  public var isKeyboardShortcutsPresented = false
  public var isCapturePanelPresented = false
  var capturePanelPresentationID = UUID()
  var browserClipImportContext: BrowserClipImportContext? {
    guard isCapturePanelPresented, let corpusRoot else { return nil }
    return BrowserClipImportContext(
      root: corpusRoot.standardizedFileURL,
      corpusGeneration: corpusSessionGeneration,
      capturePresentationID: capturePanelPresentationID
    )
  }
  public var isDailyNoteDatePickerPresented = false
  public var isNewCorpusFileSheetPresented = false
  public var newCorpusFileDefaultFolder = NewCorpusFilePlan.defaultFolder
  public var newCorpusFileError: String?
  public var dailyNotePickerDate = Date()
  public var isLaunchGuidePresented = false
  public var captureDraft = WorkspaceCaptureDraft()
  public var isSimilarTodoAssignmentPresented = false
  public var similarTodoCandidates: [SimilarTodoCandidate] = []
  public var selectedSimilarTodoCandidateIDs: Set<SimilarTodoCandidate.ID> = []
  public var similarTodoPattern = ""
  public var similarTodoAssignee = ""
  public var similarTodoStatus = "ready"
  public var assignedWorkItems: [AssignedWorkItem] = [] {
    didSet {
      assignedWorkSearchRows = assignedWorkItems.map { item in
        AssignedWorkSearchRow(item: item, searchText: Self.assignedWorkFilterText(for: item))
      }
      rebuildAgendaFilterOptions()
      rebuildAssignedWorkDisplayCache()
    }
  }
  public internal(set) var visibleAssignedWorkItems: [AssignedWorkItem] = []
  public internal(set) var assignedWorkSections: [AssignedWorkSection] = []
  public var selectedAssignedWorkItemID: AssignedWorkItem.ID?
  public var isLoadingAssignedWork = false
  public internal(set) var hasAttemptedAssignedWorkLoad = false
  public var detailScrollRequest: DetailScrollRequest?
  public var quickOpenQuery = "" {
    didSet {
      if selectedQuickOpenFileID != nil {
        selectedQuickOpenFileID = nil
      }
      scheduleQuickOpenSearch()
    }
  }
  public var selectedQuickOpenFileID: String?
  public internal(set) var quickOpenFiles: [CorpusFile] = []
  public internal(set) var quickOpenItems: [WorkspaceQuickOpenItem] = []
  public internal(set) var isFilteringQuickOpenFiles = false
  public var searchMode: WorkspaceSearchMode = .text {
    didSet {
      guard oldValue != searchMode, searchMode == .nodes else { return }
      scheduleSearchNodeDisplayRefresh(debounce: false)
    }
  }
  public var searchReadScope: WorkspaceReadScope = .activeCorpus {
    didSet {
      guard oldValue != searchReadScope else { return }
      invalidateWorkspaceSearchRequest()
    }
  }
  public var searchQuery = "" {
    didSet {
      guard oldValue != searchQuery else { return }
      invalidateWorkspaceSearchRequest()
      guard searchMode == .nodes else { return }
      scheduleSearchNodeDisplayRefresh()
    }
  }
  public var searchFocusToken = 0
  public var searchResults: [SearchResult] = [] {
    didSet { rebuildWorkspaceTextSearchDisplayCache() }
  }
  public var aiChatSearchResults: [AIChatSearchResult] = [] {
    didSet { rebuildWorkspaceTextSearchDisplayCache() }
  }
  public var workspaceFileSearchResults: [CorpusFile] = [] {
    didSet { rebuildWorkspaceTextSearchDisplayCache() }
  }
  public var workspacePageSearchResults: [OrgRoamNodeReference] = [] {
    didSet { rebuildWorkspaceTextSearchDisplayCache() }
  }
  public var workspaceAgentWorkSearchResults: [WorkspaceAgentWorkSearchResult] = [] {
    didSet { rebuildWorkspaceTextSearchDisplayCache() }
  }
  /// Every kind of workspace search result in one list, best first.
  public internal(set) var workspaceTextSearchItems: [WorkspaceTextSearchItem] = []
  /// The query the current results answer; the draft may already differ.
  var workspaceSearchRankingQuery: String?
  public internal(set) var corpusSearchResultGroups: [SearchResultGroup] = []
  public internal(set) var searchNodes: [OrgRoamNodeReference] = []
  public var renderedSearchHighlightQuery: String?
  public var isPageSearchPresented = false
  public var pageSearchQuery = "" {
    didSet {
      guard isPageSearchPresented else { return }
      schedulePageSearchRefresh(selectFirst: true)
    }
  }
  public var pageSearchFocusToken = 0
  public internal(set) var pageSearchOccurrenceCount = 0
  public internal(set) var pageSearchSelectedOccurrenceIndex: Int?
  var pageSearchRenderedMatches: [PageSearchRenderedMatch] = []
  public var meetings: [MeetingWorkspaceItem] = [] {
    didSet {
      rebuildMeetingDisplayCache()
    }
  }
  public internal(set) var meetingDisplaySections: [MeetingSection] = []
  public internal(set) var sourceProfiles: [WorkspaceSourceProfileStatus] = []
  public internal(set) var sourceRuntimeStatuses: [String: WorkspaceSourceRuntimeStatus] = [:]
  public internal(set) var sourceScheduleStates: [String: WorkspaceSourceScheduleState] = [:]
  public internal(set) var sourceOperationMessages: [String: String] = [:]
  public internal(set) var sourceOperationFailureIDs: Set<String> = []
  public internal(set) var activeSourceOperationIDs: Set<String> = []
  public internal(set) var isLoadingSources = false
  public var isSourceCredentialPresented = false
  public var sourceCredentialProfileID: String?
  /// The add/edit sheet for any catalog source type.
  public var sourceDraft: WorkspaceSourceDraft?
  public var sourceCredentialDraft = ""
  public internal(set) var processingMeetings: [MeetingProcessingItem] = []
  public var selectedMeetingID: String?
  public var meetingTitleDraft = ""
  public var meetingStatusText = WorkspaceStore.defaultMeetingStatusText()
  public internal(set) var meetingReadyAutomationSettings = MeetingReadyAutomationSettings()
  public internal(set) var meetingReadyAutomationStatusText = "Meeting automation is off"
  let meetingInputMeterState = WorkspaceInputMeterState()
  let meetingTranscriptionProgressState = WorkspaceTranscriptionProgressState()
  public var meetingTranscriptionProgress: Double { meetingTranscriptionProgressState.progress }
  public var meetingTranscriptionElapsedText: String { meetingTranscriptionProgressState.elapsedText }
  public var audioSettingsStatus = LocalWhisperTranscriber.installationStatus(
    verifyExecutableLaunch: false
  )
  public var meetingTranscriptionProvider: MeetingTranscriptionProvider = .automatic {
    didSet { persistMeetingTranscriptionValue(meetingTranscriptionProvider.rawValue, key: meetingTranscriptionProviderKey) }
  }
  public var fluidVoiceEndpointText = MeetingTranscriptionConfiguration.defaultFluidVoiceEndpoint {
    didSet { persistMeetingTranscriptionValue(fluidVoiceEndpointText, key: fluidVoiceEndpointKey) }
  }
  public var customTranscriptionCommandText = "" {
    didSet { persistMeetingTranscriptionValue(customTranscriptionCommandText, key: customTranscriptionCommandKey) }
  }
  public var whisperModelPathText = "" {
    didSet { persistMeetingTranscriptionValue(whisperModelPathText, key: whisperModelPathKey) }
  }
  public var transcriptionLanguageText = "en" {
    didSet { persistMeetingTranscriptionValue(transcriptionLanguageText, key: transcriptionLanguageKey) }
  }
  public var isInstallingFastTranscriber = false
  public var isTestingTranscriptionProvider = false
  public internal(set) var isConnectingFluidVoice = false
  public var audioSettingsStatusText = ""
  public var workspaceRuntimeIdentity = WorkspaceRuntimeIdentity.current()
  public var isCapturingSystemAudio = false
  public var meetingSystemAudioStatusText = "System audio not recording"
  /// Incremented to move keyboard focus to the end of the chat composer.
  public var aiChatComposerFocusRequest = 0
  public var aiChatMessages: [AIChatMessage] = [] {
    didSet {
      guard !isApplyingAIChatThreadMessages else { return }
      if isLoadingAIChatTranscript {
        pendingAIChatMessageMutationDuringLoad = (
          threadID: selectedAIChatThreadID,
          messages: aiChatMessages
        )
        isApplyingAIChatThreadMessages = true
        aiChatMessages = oldValue
        isApplyingAIChatThreadMessages = false
        return
      }
      updateSelectedAIChatThread(messages: aiChatMessages)
      guard shouldPersistAIChatMessages else { return }
      if aiChatSendingThreadIDs.isEmpty {
        persistAIChatTranscript()
      } else {
        scheduleAIChatTranscriptPersistenceAfterInteraction()
      }
    }
  }
  public internal(set) var aiChatThreads: [AIChatThread] = [] {
    didSet {
      guard !isApplyingIncrementalAIChatThreadMutation else { return }
      rebuildAIChatThreadDisplayCache()
      rebuildQuickOpenChatIndex()
      if isQuickOpenPresented,
         !quickOpenQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        scheduleQuickOpenSearch(debounce: false)
      }
    }
  }
  public internal(set) var visibleAIChatThreads: [AIChatThread] = []
  public internal(set) var archivedAIChatThreads: [AIChatThread] = []
  var visibleAIChatThreadSummaries: [AIChatSidebarThreadSummary] = []
  var archivedAIChatThreadSummaries: [AIChatSidebarThreadSummary] = []
  public internal(set) var aiChatThreadSettlementSettings = AIChatThreadSettlementSettings()
  public internal(set) var aiChatUnreadMessageCount = 0
  public internal(set) var selectedAIChatThreadID: UUID?
  public internal(set) var sidebarPromotedAIChatThreadID: UUID?
  public internal(set) var aiChatSelectionGeneration = 0
  public internal(set) var isLoadingAIChatTranscript = false
  public internal(set) var aiChatScrollRestorationCompletionGeneration = 0
  public internal(set) var aiChatFindRequestGeneration = 0
  public internal(set) var lastArchivedAIChatThreadID: UUID?
  public internal(set) var externalThreads: [ExternalThreadSummary] = [] {
    didSet { rebuildExternalThreadDisplayCache() }
  }
  public internal(set) var filteredExternalThreads: [ExternalThreadSummary] = []
  public internal(set) var selectedExternalThreadID: String?
  public internal(set) var selectedExternalThreadDetail: ExternalThreadDetail?
  public internal(set) var isRefreshingExternalThreads = false
  public internal(set) var isLoadingExternalThread = false
  public var externalThreadSearchQuery = "" {
    didSet {
      guard oldValue != externalThreadSearchQuery else { return }
      rebuildExternalThreadDisplayCache()
    }
  }
  public internal(set) var externalThreadError: String?
  public var aiChatIncomingMessageSoundPlayer: @MainActor () -> Void = {
    WorkspaceSound.playBundledNewMessageSound()
  }
  public var aiChatIncomingMessageHandler: @MainActor (
    _ thread: AIChatThread,
    _ messages: [AIChatMessage]
  ) -> Void = { _, _ in }
  public var approvalQueueChangeHandler: @MainActor (_ approvals: [ApprovalItem]) -> Void = { _ in }
  var mobileRemoteRunLookupForTesting: ((_ runID: String) async -> AgentRunItem?)?
  public var aiChatDraft = ""
  public var aiChatPendingAttachments: [AIChatAttachment] = []
  public var openClawAgentID = "main"
  public var openClawEndpointText = ""
  public internal(set) var openClawGatewayCommands: [AIChatSlashCommand] = []
  public internal(set) var corpusAgentSkillCommands: [AIChatSlashCommand] = []
  public internal(set) var workspaceSkills: [WorkspaceSkillItem] = []
  public var selectedWorkspaceSkillID: WorkspaceSkillItem.ID?
  public internal(set) var isRefreshingAIChatCommands = false
  public internal(set) var aiChatModelOptions: [AIChatModelOption] = []
  public internal(set) var aiChatRoomModelOptions: [AIChatRuntime: [AIChatModelOption]] = [:]
  public internal(set) var aiChatDestinationModelOptions: [String: [AIChatModelOption]] = [:]
  public internal(set) var aiChatDestinations: [AIChatDestinationConfiguration] = []
  public internal(set) var aiChatDestinationSettingsError: String?
  public internal(set) var aiChatReasoningOptions: [AIChatReasoningOption] = []
  public internal(set) var aiChatEffectiveModel: String?
  public internal(set) var aiChatDefaultReasoningEffort: String?
  public internal(set) var isRefreshingAIChatConfiguration = false
  public var agentHandoffAssignee = WorkspaceStore.defaultAgentHandoffAssignee
  public var personalAssigneeNamesText = ""
  public var openClawRemoteCorpusPath = ""
  public var aiChatCorpusAccessScope: WorkspaceReadScope = .activeCorpus {
    didSet {
      defaults.set(aiChatCorpusAccessScope.rawValue, forKey: aiChatCorpusAccessScopeKey)
    }
  }
  public var aiChatCustomInstructions = "" {
    didSet {
      defaults.set(aiChatCustomInstructions, forKey: aiChatCustomInstructionsKey)
    }
  }
  public var codexSandboxAccess: CodexSandboxAccess = .workspaceWrite {
    didSet {
      defaults.set(codexSandboxAccess.rawValue, forKey: codexSandboxAccessKey)
    }
  }
  public var aiChatMessageSound: AIChatMessageSound = .org2 {
    didSet {
      defaults.set(aiChatMessageSound.rawValue, forKey: aiChatMessageSoundKey)
      aiChatIncomingMessageSoundPlayer = Self.messageSoundPlayer(for: aiChatMessageSound)
    }
  }
  public var aiChatRepairIntervalSeconds: TimeInterval = AIChatTranscriptRepair.defaultIntervalSeconds {
    didSet {
      defaults.set(aiChatRepairIntervalSeconds, forKey: aiChatRepairIntervalKey)
      restartAIChatRepairTimer()
    }
  }
  public internal(set) var aiChatRepairError: String?
  /// How many turns agents may start for each other in a shared room before a
  /// person must reply, for every room that has not chosen its own limit.
  public var aiChatDefaultRoomAgentTurnLimit: Int = AIChatThread.defaultRoomAgentTurnLimit {
    didSet {
      let clamped = min(max(aiChatDefaultRoomAgentTurnLimit, 0), AIChatThread.maxRoomAgentTurnLimit)
      if clamped != aiChatDefaultRoomAgentTurnLimit {
        aiChatDefaultRoomAgentTurnLimit = clamped
        return
      }
      defaults.set(clamped, forKey: aiChatDefaultRoomAgentTurnLimitKey)
    }
  }
  public var appearanceMode: WorkspaceAppearanceMode = .system {
    didSet {
      defaults.set(appearanceMode.rawValue, forKey: appearanceModeKey)
    }
  }
  /// Theme used while the effective appearance is light.
  public var lightThemeID: String = WorkspaceThemeCatalog.defaultLightID {
    didSet {
      defaults.set(lightThemeID, forKey: lightThemeIDKey)
      applyThemeSelection()
    }
  }
  /// Theme used while the effective appearance is dark.
  public var darkThemeID: String = WorkspaceThemeCatalog.defaultDarkID {
    didSet {
      defaults.set(darkThemeID, forKey: darkThemeIDKey)
      applyThemeSelection()
    }
  }

  private func applyThemeSelection() {
    WorkspaceThemeCenter.shared.select(lightThemeID: lightThemeID, darkThemeID: darkThemeID)
  }
  public var experimentalFeaturesEnabled = false {
    didSet {
      defaults.set(experimentalFeaturesEnabled, forKey: experimentalFeaturesEnabledKey)
      if !experimentalFeaturesEnabled, let threadID = activeBundledAgentThreadID {
        markAIChatRunStopped(in: threadID, statusText: "Experimental features disabled")
        aiChatDrainTasksByThreadID[threadID]?.task.cancel()
      }
    }
  }
  public var automaticDailyNoteCreationDisabled = false {
    didSet {
      guard automaticDailyNoteCreationDisabled != oldValue,
            let corpusRoot
      else { return }
      persistAutomaticDailyNoteCreationPreference(for: corpusRoot)
    }
  }
  public var aiChatBriefsStartNewThread = true {
    didSet {
      defaults.set(aiChatBriefsStartNewThread, forKey: aiChatBriefsStartNewThreadKey)
    }
  }
  /// Harness/model/reasoning used to generate node briefs. Nil fields fall
  /// back to the current chat's destination and that destination's defaults.
  public var nodeBriefConfiguration = NodeBriefAIConfiguration() {
    didSet {
      guard nodeBriefConfiguration != oldValue else { return }
      if let data = try? JSONEncoder().encode(nodeBriefConfiguration) {
        defaults.set(data, forKey: nodeBriefConfigurationKey)
      }
    }
  }
  public var isNodeBriefOptionsPresented = false
  /// The TODO waiting on the Start Work dialog, if it is open.
  public var pendingStartWorkRequest: StartWorkRequest?
  /// Last Start Work choices, offered as the dialog's defaults.
  public var startWorkLastOptions = StartWorkOptions() {
    didSet {
      guard startWorkLastOptions != oldValue else { return }
      if let data = try? JSONEncoder().encode(startWorkLastOptions) {
        defaults.set(data, forKey: startWorkLastOptionsKey)
      }
    }
  }
  public internal(set) var openClawLocalEditsEnabled = false
  public internal(set) var openClawLocalEditNodeState: OpenClawLocalEditNodeState = .disabled
  public internal(set) var openClawLocalEditNodeDetail = ""
  public var openClawHasStoredToken = false
  public var aiChatStatusText = WorkspaceStore.defaultAIChatStatusText()
  public internal(set) var aiChatTranscriptRecoveryNotice: String?
  public internal(set) var codexAccountState: CodexAccountState = .unknown
  public internal(set) var isCodexSigningIn = false
  public internal(set) var codexLoginURL: URL?
  public var isRecordingAIChatVoiceNote = false
  public var isTranscribingAIChatVoiceNote = false
  let aiChatVoiceMeterState = WorkspaceInputMeterState()
  public var aiChatVoiceTranscriptionProgress = 0.0
  public var aiChatVoiceTranscriptionElapsedText = ""
  public var aiChatVoiceStatusText = "Dictate with local transcription."
  public var isOrgCryptConfigurationPresented = false
  /// Plaintext shown in the temporary "View Decrypted" sheet. It lives only
  /// in memory and is dropped when the sheet closes; the file is untouched.
  public var orgCryptPeek: OrgCryptPeek?
  /// Agent secret requests awaiting the person. The sheet's typed value is
  /// never stored here; only request metadata is.
  public internal(set) var pendingSecretRequests: [SecretRequest] = []
  public var activeSecretRequest: SecretRequest?
  public internal(set) var secretRequestErrorText: String?
  public internal(set) var isSubmittingSecretRequest = false
  var deferredSecretRequestIDs: Set<String> = []
  var secretSealerForTesting: (any SecretSealing)?
  public var isDataSourceConfigurationPresented = false
  public internal(set) var scarfMetabaseHasStoredAPIKey = false
  public var orgCryptEncryptOnSave = true {
    didSet {
      defaults.set(orgCryptEncryptOnSave, forKey: orgCryptEncryptOnSaveKey)
    }
  }
  public var orgCryptRecipientsText = ""
  public var orgCryptRecipientFilesText = ""
  public internal(set) var orgCryptManagedRecipientFiles: [OrgCryptRecipientFile] = []
  public var orgCryptUseDefaultGpgKey = true
  public var orgCryptGpgProgram = "gpg"
  public var orgCryptHasStoredPassphrase = false
  public var orgCryptStatusText = "Encrypt :crypt: subtrees with GPG."
  public var isSendingAIChatMessage = false
  public internal(set) var aiChatQueuedMessageCount = 0
  public internal(set) var aiChatSendingThreadIDs: Set<UUID> = []
  public var aiChatRequestStartedAt: Date?
  let aiChatLiveState = AIChatLiveState()
  var openClawGatewayStateByThreadID: [UUID: OpenClawGatewayConnectionState] {
    get { aiChatLiveState.gatewayStateByThreadID }
    set { aiChatLiveState.gatewayStateByThreadID = newValue }
  }
  var openClawGatewayDetailByThreadID: [UUID: String] {
    get { aiChatLiveState.gatewayDetailByThreadID }
    set { aiChatLiveState.gatewayDetailByThreadID = newValue }
  }
  var aiChatLastEventAtByThreadID: [UUID: Date] {
    get { aiChatLiveState.currentLastEventDates }
    set { aiChatLiveState.replaceLastEventDates(newValue) }
  }
  var aiChatActiveRunIDByThreadID: [UUID: String] {
    get { aiChatLiveState.activeRunIDByThreadID }
    set { aiChatLiveState.activeRunIDByThreadID = newValue }
  }
  var aiChatRunActivitiesByThreadID: [UUID: [AIChatRunActivity]] {
    get { aiChatLiveState.runActivitiesByThreadID }
    set { aiChatLiveState.runActivitiesByThreadID = newValue }
  }
  var codexStreamingItemIDByThreadID: [UUID: String] = [:]
  public var isAIChatAssistantPresented = false
  public internal(set) var aiChatScrollPosition: Double?
  public internal(set) var aiChatAssistantChatScrollPosition: Double?
  var aiChatScrollPositionsByThreadID: [UUID: Double] = [:]
  var aiChatAssistantChatScrollPositionsByThreadID: [UUID: Double] = [:]
  public internal(set) var lastCompletedAIChatScrollRestorationThreadID: UUID?
  public var aiChatThreadRecords: [AIChatThreadRecord] = []
  public var selectedAIChatThreadRecordID: String?
  public var workspaceHealthChecks: [WorkspaceHealthCheck] = []
  public var isCheckingWorkspaceHealth = false
  public var selectedLocation: WorkspaceLocation? {
    didSet {
      scheduleCurrentNodeBriefArtifactRefresh()
      guard oldValue?.file != selectedLocation?.file else { return }
      htmlFileShowsSource = false
      updateSelectedFileDataNotebookState(for: selectedLocation?.file, sourceText: nil)
    }
  }
  public internal(set) var missingDailyNote: WorkspaceMissingDailyNote?
  public internal(set) var isCreatingMissingDailyNote = false
  public var selectedEntrySource: EntrySource? {
    didSet {
      sourceEditorPreparationTask?.cancel()
      sourceEditorPreparationTask = nil
      sourceEditorPreparationGeneration &+= 1
      // Source loading builds this immutable lookup off the main actor. Any
      // local replacement that does not provide a matching index deliberately
      // clears it; opening that replacement will prepare a fresh index off-main.
      selectedEntrySourceLineIndex = nextSelectedEntrySourceLineIndex
      nextSelectedEntrySourceLineIndex = nil
      selectedEntrySourceModifiedAt = nextSelectedEntrySourceModifiedAt
      nextSelectedEntrySourceModifiedAt = nil
      if let source = selectedEntrySource {
        entrySourceRenderIdentitySequence &+= 1
        entrySourceRenderIdentities[source.id] = nextSelectedEntrySourceRenderIdentity
          ?? "revision:\(entrySourceRenderIdentitySequence)"
      }
      nextSelectedEntrySourceRenderIdentity = nil
      updateCurrentDocumentGoogleDrivePublications(for: selectedEntrySource)
      scheduleCurrentNodeBriefArtifactRefresh()
      scheduleSelectedEntityMetadata(for: selectedEntrySource)
      if let source = selectedEntrySource {
        updateSelectedFileDataNotebookState(for: source.file, sourceText: source.text)
      }
      if oldValue?.file != selectedEntrySource?.file, orgCryptPeek != nil {
        // Peeked plaintext belongs to one document; never carry it across.
        orgCryptPeek = nil
      }
      if oldValue?.id != selectedEntrySource?.id {
        cancelSlidePreviewRender(clearStatus: true)
        currentDocumentViewportSourceLine = selectedEntrySource.flatMap {
          documentViewportSourceLine(for: $0)
        }
        currentDocumentSlidePageIndex = selectedEntrySource.flatMap {
          documentSlidePageIndex(for: $0)
        }
        slidePreviewPageCount = 0
        slidePreviewNavigationRequest = nil
        slidePreviewZoomScale = selectedEntrySource.flatMap {
          slidePreviewZoomScales[Self.documentViewportKey(for: $0)]
        } ?? 1
      }
      applyDocumentPreviewPreferenceForSelectedSource()
    }
  }
  public internal(set) var selectedFileIsDataNotebook = false
  public internal(set) var selectedEntryHTML: String? {
    didSet {
      updateInferredDocumentPreviewKind(from: selectedEntryHTML)
    }
  }
  public var selectedEntryHTMLRenderIdentity: String? { selectedEntryHTMLRenderKey }
  public internal(set) var selectedEntryRenderError: String?
  public var renderedDocumentWidth: RenderedDocumentWidth = .comfortable {
    didSet {
      defaults.set(renderedDocumentWidth.rawValue, forKey: renderedDocumentWidthKey)
    }
  }
  public var renderedDocumentMargin: RenderedDocumentMargin = .standard {
    didSet {
      defaults.set(renderedDocumentMargin.rawValue, forKey: renderedDocumentMarginKey)
    }
  }
  public var propertyDrawersExpandedByDefault = true {
    didSet {
      defaults.set(propertyDrawersExpandedByDefault, forKey: propertyDrawersExpandedByDefaultKey)
      guard propertyDrawersExpandedByDefault != oldValue else { return }
      applyPropertyDrawerDefaultToLoadedHTML()
    }
  }
  public var formatOrgFilesOnSave = true {
    didSet {
      defaults.set(formatOrgFilesOnSave, forKey: formatOrgFilesOnSaveKey)
    }
  }
  /// Vim keybindings in the full-file source editor (Source, Split, Prose).
  public var sourceEditorVimModeEnabled = false {
    didSet {
      defaults.set(sourceEditorVimModeEnabled, forKey: sourceEditorVimModeKey)
    }
  }
  public var sourceEditorPresentation: SourceEditorPresentation = .source {
    didSet {
      defaults.set(sourceEditorPresentation.rawValue, forKey: sourceEditorPresentationKey)
      if sourceEditorPresentation != .split {
        cancelSourceEditorPreviewRender(clearStatus: false)
      }
    }
  }
  public internal(set) var documentPreviewPreference: OrgDocumentPreviewPreference = .automatic
  public internal(set) var documentPreviewKind: OrgDocumentPreviewKind = .document {
    didSet {
      if documentPreviewKind == .document {
        cancelSlidePreviewRender(clearStatus: false)
      } else {
        cancelSourceEditorPreviewRender(clearStatus: false)
      }
    }
  }
  public var isSourceEditorPreviewPaused = false
  public internal(set) var sourceEditorPreviewHTML: String?
  public internal(set) var sourceEditorPreviewError: String?
  public internal(set) var isRenderingSourceEditorPreview = false
  public internal(set) var slidePreviewPDF: Data?
  public internal(set) var slidePreviewError: String?
  public internal(set) var isRenderingSlidePreview = false
  public internal(set) var slidePreviewZoomScale: CGFloat = 1
  public internal(set) var slidePreviewPageCount = 0
  var slidePreviewNavigationRequest: OrgPDFPageNavigationRequest?
  public internal(set) var linkedPDFPreviewData: Data?
  public internal(set) var linkedPDFPreviewError: String?
  public internal(set) var isLoadingLinkedPDFPreview = false
  /// Bumped when the selected image or video changes on disk so the native
  /// media preview reloads without the user reselecting the file.
  public internal(set) var linkedMediaPreviewRevision = 0
  public var selectedRenderedBlocks: [OrgEditableBlock] = [] {
    didSet {
      defer {
        if !foldedRenderedBlockIDs.isEmpty {
          foldedRenderedBlockIDs = OrgRenderedFoldTree.prunedFoldedIDs(
            foldedRenderedBlockIDs,
            blocks: selectedRenderedBlocks
          )
        }
      }
      if preservesSelectedRenderedBlocksMetadataForNextAssignment {
        let metadata = nextSelectedRenderedBlocksMetadata
          ?? Self.renderedBlocksMetadata(for: selectedRenderedBlocks)
        selectedRenderedBlocksRenderSignature = metadata.renderSignature
        selectedRenderedBlocksSignature = metadata.structureSignature
        selectedRenderedBlockIndexes = metadata.indexes
        nextSelectedRenderedBlocksMetadata = nil
        preservesSelectedRenderedBlocksMetadataForNextAssignment = false
        if isPageSearchPresented {
          schedulePageSearchRefresh(selectFirst: false, debounce: false)
        }
        return
      }
      let metadata = Self.renderedBlocksMetadata(for: selectedRenderedBlocks)
      selectedRenderedBlocksRenderSignature = metadata.renderSignature
      selectedRenderedBlocksSignature = metadata.structureSignature
      selectedRenderedBlockIndexes = metadata.indexes
      if isPageSearchPresented {
        schedulePageSearchRefresh(selectFirst: false, debounce: false)
      }
    }
  }
  public internal(set) var isSelectedRenderedBlocksReady = false
  public internal(set) var selectedRenderedBlocksRenderSignature = WorkspaceStore.renderedBlocksRenderSignature(for: [])
  public private(set) var selectedRenderedBlocksSignature = WorkspaceStore.renderedBlocksSignature(for: [])
  public internal(set) var selectedRenderedBlockIndexes: [OrgEditableBlock.ID: Int] = [:]
  public var selectedEntrySourceMode: EntrySourceMode = .entry
  public let sourceEditorInteraction = SourceEditorInteractionModel()
  public var editableEntryText = "" {
    didSet {
      guard !isReplacingEditableEntryTextFromModel else { return }
      liveFileEditorDraftGeneration &+= 1
    }
  }
  private var isReplacingEditableEntryTextFromModel = false

  /// Replaces the editor mirror from navigation, loading, or a committed
  /// external mutation without manufacturing a user-dirty generation.
  func replaceEditableEntryTextFromModel(_ text: String) {
    isReplacingEditableEntryTextFromModel = true
    editableEntryText = text
    isReplacingEditableEntryTextFromModel = false
    liveFileEditorSavedDraftGeneration = liveFileEditorDraftGeneration
  }
  public var sourceEditorSelection: NSRange {
    get { sourceEditorInteraction.selection }
    set {
      if sourceEditorInteraction.selection != newValue {
        sourceEditorInteraction.selection = newValue
      }
    }
  }
  public internal(set) var currentDocumentViewportSourceLine: Int?
  public internal(set) var currentDocumentSlidePageIndex: Int?
  public var sourceEditorCommandRequest: OrgSourceEditorCommandRequest?
  public var sourceEditorDiagnostics: [Org2EditorDiagnostic] = []
  public var selectedBlockID: OrgEditableBlock.ID?
  public internal(set) var foldedRenderedBlockIDs: Set<OrgEditableBlock.ID> = []
  public var editingBlockID: OrgEditableBlock.ID?
  public var editableBlockText = ""
  public var sourceBlockRuns: [String: SourceBlockRunState] = [:] {
    didSet {
      sourceBlockRunsRenderSignature = Self.sourceBlockRunsRenderSignature(for: sourceBlockRuns)
    }
  }
  public internal(set) var sourceBlockRunsRenderSignature = WorkspaceStore.sourceBlockRunsRenderSignature(for: [:])
  public var backlinks: BacklinksPayload? {
    didSet {
      rebuildBacklinkDisplayCache()
    }
  }
  public internal(set) var entityActionItems: NodeActionItemsPayload?
  public internal(set) var isLoadingEntityActionItems = false
  public internal(set) var backlinkFileGroups: [BacklinkFileGroup] = []
  public internal(set) var relatedBacklinkNodes: [RelatedBacklinkNode] = []
  public var isNodeContextPanePresented = false
  public var nodeContextTab: NodeContextTab = .overview
  public var expandedBacklinkFileIDs: Set<String> = []
  public var isBuildingNodeBrief = false
  public internal(set) var currentNodeBriefArtifact: NodeBriefArtifact?
  public var isLoadingAgenda = false
  public var isSearching = false
  public internal(set) var isBuildingSearchIndex = false
  public internal(set) var searchIndexStatusText = ""
  public var isLoadingMeetings = false
  public var isRecordingMeeting = false {
    didSet {
      guard oldValue != isRecordingMeeting else { return }
      if isRecordingMeeting {
        meetingRecordingClock.start(at: Date())
      } else {
        meetingRecordingClock.reset()
      }
    }
  }
  public var isMeetingRecordingPaused = false {
    didSet {
      guard oldValue != isMeetingRecordingPaused else { return }
      if isMeetingRecordingPaused {
        meetingRecordingClock.pause(at: Date())
      } else {
        meetingRecordingClock.resume(at: Date())
      }
    }
  }
  /// Active (unpaused) time of the current meeting recording.
  public private(set) var meetingRecordingClock = MeetingRecordingClock()
  /// True while Stop is finalizing the recorders, before transcription starts.
  public internal(set) var isStoppingMeetingRecording = false
  public var isProcessingMeeting = false
  public var isLoadingAIChatThreadRecords = false
  public var isLoadingEntrySource = false
  public internal(set) var isRefreshingDataNotebook = false
  public internal(set) var dataNotebookRefreshFailure: DataNotebookRefreshFailure?
  public internal(set) var dataSourceConfigurationError: String?
  public var isRenderingEntrySource = false
  public var isLiveEmbedInsertPresented = false
  public var isEditingEntry = false
  public var isSavingEntry = false
  public var isSavingBlock = false
  public internal(set) var isExportingCurrentDocumentPDF = false
  public internal(set) var isExportingSlides = false
  public var isDocumentPublisherPresented = false
  public internal(set) var isPublishingDocument = false
  public internal(set) var localDocumentPublications: [LocalDocumentPublication] = []
  /// Threads whose live share page is being rendered right now.
  public internal(set) var publishingChatThreadIDs: Set<UUID> = []
  /// Guest messages from live thread links waiting for the owner's decision.
  public internal(set) var aiChatGuestSubmissions: [AIChatGuestSubmission] = []
  /// Threads whose live link on this Mac accepts guest messages.
  public internal(set) var aiChatGuestMessageThreadIDs: Set<UUID> = []
  @ObservationIgnored var isObservingAIChatGuestMessages = false
  @ObservationIgnored var chatThreadPublicationSignatures: [UUID: AIChatThreadPublicationSignature] = [:]
  @ObservationIgnored var chatThreadPublicationMonitor: Task<Void, Never>?
  /// Uses this store's CLI so a headless server renders with its configured
  /// runtime and Node path.
  @ObservationIgnored let chatThreadPublicationRenderer: AIChatThreadPublicationRenderer
  /// This Mac's pairing with a headless OpenOrg server, used to host links there.
  public let openOrgServer: OpenOrgServerConnection
  /// Where this host keeps external-source secrets: the login Keychain on the
  /// desktop, a private file on a headless server (set by the server worker).
  @ObservationIgnored public var sourceCredentialStore: any SourceCredentialStoring =
    NSClassFromString("XCTestCase") == nil ? SourceCredentialsKeychainStore() : SourceCredentialsMemoryStore()
  /// Source profiles whose credential the paired server reports holding;
  /// `nil` until checked.
  public internal(set) var serverSourceCredentialProfileIDs: Set<String>?
  /// Synced calendar events the meeting prompt and manual recordings use.
  public internal(set) var calendarMeetingEvents: [CalendarMeetingEvent] = []
  /// The meeting currently offered for recording, if any.
  public internal(set) var calendarRecordingPrompt: CalendarMeetingEvent?
  @ObservationIgnored var calendarRecordingPromptTask: Task<Void, Never>?
  @ObservationIgnored private var pendingMeetingCalendarEvent: CalendarMeetingEvent?
  /// Presents and dismisses the floating recording prompt; set by the desktop app.
  @ObservationIgnored public var calendarRecordingPromptPresenter: ((CalendarMeetingEvent?) -> Void)?
  public internal(set) var currentDocumentGoogleDrivePublications: [GoogleDrivePublicationBinding] = []
  public var exportNotice: Org2ExportNotice?
  public var editorSaveConflict: Org2EditorSaveConflict?
  public internal(set) var isLiveFileEditorAutosaving = false
  public internal(set) var liveFileEditorStatusText = ""
  public var isLoadingBacklinks = false
  public var priorityModeActive = false
  public var statusText = ""
  public var errorText: String?
  public internal(set) var canNavigateBack = false
  public internal(set) var canNavigateForward = false

  public var meetingCaptureSourceText: String {
    Self.meetingCaptureSourceSummary
  }

  public let cli: Org2CLI
  let defaults: UserDefaults
  /// Opt-in local usage log (see OpenOrgUsageLog). Disabled unless the user
  /// turns it on in Settings.
  public let usageLog: OpenOrgUsageLog
  /// Pending attribution for the next document activation, e.g. "quick_open".
  var pendingNavigationSource: String?
  var chatTurnStartTimes: [UUID: CFAbsoluteTime] = [:]
  var pendingDocumentReadyMeasurement: (path: String, startedAt: CFAbsoluteTime, source: String)?
  var fileFrecencyCache: (root: String, value: WorkspaceFileFrecency)?
  /// Bumps whenever a file visit is recorded so views ranked by frecency refresh.
  public internal(set) var fileFrecencyRevision = 0
  let fileFrecencyByCorpusKey = "org2.workspace.file-frecency-by-corpus.v1"
  let aiChatReadState: AIChatReadState
  let automaticStarterCorpusURL: URL?
  let sourceScheduleStateStore: WorkspaceSourceScheduleStateStore
  let localDocumentPublicationHost: LocalDocumentPublicationHost
  let meetingRecorder = MeetingAudioRecorder()
  let aiChatVoiceRecorder = MeetingAudioRecorder()
  let meetingSystemAudioRecorder = MeetingSystemAudioRecorder()
  let corpusKey = "Org2Workspace.corpusRoot"
  let corpusMountsKey = "Org2Workspace.corpusMounts.v1"
  let pinnedFilesByCorpusKey = "Org2Workspace.pinnedFilePathsByCorpus.v1"
  let agendaModeKey = "Org2Workspace.agendaMode"
  private let agendaOverdueOrderKey = "Org2Workspace.agendaOverdueOrder.v1"
  let openClawEndpointKey = "Org2Workspace.openClawEndpoint"
  let openClawAgentKey = "Org2Workspace.openClawAgent"
  let agentHandoffAssigneeKey = "Org2Workspace.agentHandoffAssignee"
  let personalAssigneeNamesKey = "Org2Workspace.personalAssigneeNames"
  let openClawRemoteCorpusPathKey = "Org2Workspace.openClawRemoteCorpusPath"
  let openClawRemoteCorpusPathsByCorpusKey = "Org2Workspace.openClawRemoteCorpusPathsByCorpus.v1"
  let selectedAIChatThreadsByTranscriptKey = "Org2Workspace.aiChat.selectedThreadsByTranscript.v1"
  let aiChatLastConfigurationsKey = "Org2Workspace.aiChat.lastConfigurations.v1"
  let aiChatConfigurationCatalogCacheKey = "Org2Workspace.aiChat.configurationCatalogCache.v1"
  let aiChatDestinationsKey = "Org2Workspace.aiChat.destinations.v1"
  private let aiChatCorpusAccessScopeKey = "Org2Workspace.aiChat.corpusAccessScope.v1"
  private let aiChatCustomInstructionsKey = "Org2Workspace.aiChat.customInstructions.v1"
  private let codexSandboxAccessKey = "Org2Workspace.aiChat.codexSandboxAccess.v1"
  private let aiChatMessageSoundKey = "Org2Workspace.aiChat.messageSound.v1"
  private let aiChatRepairIntervalKey = "Org2Workspace.aiChat.repairIntervalSeconds.v1"
  private let aiChatDefaultRoomAgentTurnLimitKey = "Org2Workspace.aiChat.defaultRoomAgentTurnLimit.v1"
  private let appearanceModeKey = "Org2Workspace.appearance.mode.v1"
  private let lightThemeIDKey = "Org2Workspace.appearance.lightTheme.v1"
  private let darkThemeIDKey = "Org2Workspace.appearance.darkTheme.v1"
  private let experimentalFeaturesEnabledKey = "Org2Workspace.experimentalFeatures.enabled.v1"
  let automaticDailyNoteCreationDisabledByCorpusKey =
    "Org2Workspace.dailyNotes.automaticCreationDisabledByCorpus.v1"
  let launchGuideCompletedKey = "Org2Workspace.openOrgLaunchGuideCompleted.v1"
  let aiChatBriefsStartNewThreadKey = "Org2Workspace.aiChatBriefsStartNewThread"
  private let nodeBriefConfigurationKey = "Org2Workspace.nodeBriefConfiguration"
  private let startWorkLastOptionsKey = "Org2Workspace.startWorkLastOptions"
  let openClawLocalEditsEnabledKey = "Org2Workspace.openClawLocalEditsEnabled.v1"
  let meetingReadyAutomationSettingsByCorpusKey = "Org2Workspace.meetingReadyAutomation.settingsByCorpus.v1"
  let meetingReadyAutomationDeliveriesByCorpusKey = "Org2Workspace.meetingReadyAutomation.deliveriesByCorpus.v1"
  private let meetingTranscriptionProviderKey = "Org2Workspace.meetingTranscription.provider.v1"
  private let fluidVoiceEndpointKey = "Org2Workspace.meetingTranscription.fluidVoiceEndpoint.v1"
  private let customTranscriptionCommandKey = "Org2Workspace.meetingTranscription.customCommand.v1"
  private let whisperModelPathKey = "Org2Workspace.meetingTranscription.whisperModelPath.v1"
  private let transcriptionLanguageKey = "Org2Workspace.meetingTranscription.language.v1"
  private let renderedDocumentWidthKey = "Org2Workspace.renderedDocument.width"
  private let renderedDocumentMarginKey = "Org2Workspace.renderedDocument.margin"
  private let propertyDrawersExpandedByDefaultKey = "Org2Workspace.renderedDocument.propertyDrawersExpandedByDefault.v1"
  private let formatOrgFilesOnSaveKey = "Org2Workspace.sourceEditor.formatOrgFilesOnSave.v1"
  private let sourceEditorVimModeKey = "Org2Workspace.sourceEditor.vimMode.v1"
  private let sourceEditorPresentationKey = "Org2Workspace.sourceEditor.presentation"
  let documentPreviewOverridesKey = "Org2Workspace.documentPreview.overrides.v1"
  let documentViewportSourceLinesKey = "Org2Workspace.documentViewportSourceLines.v1"
  let documentSlidePageIndexesKey = "Org2Workspace.documentSlidePageIndexes.v1"
  let orgCryptEncryptOnSaveKey = "Org2Workspace.orgCrypt.encryptOnSave"
  let orgCryptRecipientsKey = "Org2Workspace.orgCrypt.recipients"
  let orgCryptRecipientFilesKey = "Org2Workspace.orgCrypt.recipientFiles"
  let orgCryptUseDefaultGpgKeyKey = "Org2Workspace.orgCrypt.useDefaultGpgKey"
  let orgCryptUseDefaultGpgKeyMigrationKey = "Org2Workspace.orgCrypt.useDefaultGpgKeyDefaulted.v2"
  let orgCryptGpgProgramKey = "Org2Workspace.orgCrypt.gpgProgram"
  let legacyDefaultsMigrationKey = "Org2Workspace.legacyDefaultsMigrated.v1"
  private static let legacyDefaultsDomains = [
    "Org2Workspace",
    "press.avi.org2.workspace"
  ]
  nonisolated static let orgCryptPublicKeysDirectoryName = "public-keys"
  private static let canonicalParserLineLimit = 2_000
  static let canonicalDocumentCacheLimit = 12
  static let renderedBlocksCacheLimit = 12
  static let renderedHTMLCacheLimit = 24
  static let entrySourceCacheLimit = 24
  static let detailNavigationHistoryLimit = 100
  static let documentViewportSourceLinesLimit = 256
  static let workspaceUndoStackLimit = 100
  nonisolated static let workspaceUndoSnapshotMaxBytes = 2_000_000
  nonisolated static let liveFileEditorAutosaveDelayNanoseconds: UInt64 = 850_000_000
  nonisolated static let aiChatChangeSnapshotMaxFileBytes = 2_000_000
  nonisolated static let aiChatChangeSnapshotAllowedExtensions = Set([
    "org", "org2", "md", "markdown", "txt",
    "html", "htm", "xhtml",
    "json", "jsonl", "yaml", "yml", "toml",
    "csv", "tsv"
  ])
  nonisolated static let aiChatChangeSnapshotRetryDelays: [UInt64] = [
    0,
    150_000_000,
    350_000_000
  ]
  nonisolated static let nodeBriefArtifactRetryDelays: [UInt64] = [
    0,
    150_000_000,
    350_000_000,
    700_000_000,
    1_200_000_000
  ]
  nonisolated static let aiChatInterruptedSendFailureText =
    "Celorga restarted before this AI response was saved. The response may have completed outside the app, but this chat cannot recover it. Retry to send again."
  nonisolated private static let aiChatDefaultStoppedSendFailureText =
    "OpenClaw was stopped by you. Retry to start this request again."
  var aiChatTranscriptURL: URL
  let appAIChatTranscriptURL: URL
  let usesFixedAIChatTranscriptURL: Bool
  let aiChatSendHandler: (@Sendable ([AIChatMessage], String, String, AIChatWorkspaceContext?) async throws -> String)?
  let aiChatRecoveryHandler: (@Sendable (AIChatPendingTurn, String) async throws -> String)?
  let codexSendHandlerForTesting: (@Sendable ([AIChatMessage], UUID, AIChatWorkspaceContext) async throws -> String)?
  let codexLocalExecutableURLForTesting: URL?
  let codexManagedRemoteSSHExecutableURLForTesting: URL?
  let claudeSendHandlerForTesting: (@Sendable ([AIChatMessage], UUID, AIChatWorkspaceContext) async throws -> ClaudeCodeTurnResult)?
  let openClawDeviceIdentityFileURL: URL?
  var openClawSessionKey = WorkspaceStore.makeOpenClawSessionKey()
  var shouldPersistAIChatMessages = false
  var isApplyingAIChatThreadMessages = false
  var openClawBearerToken: String?
  var aiChatDraftsByComposerKey: [AIChatComposerKey: String] = [:]
  var aiChatAttachmentsByComposerKey: [AIChatComposerKey: [AIChatAttachment]] = [:]
  var aiChatDraftCachedKeys: Set<AIChatComposerKey> = []
  var aiChatAttachmentCachedKeys: Set<AIChatComposerKey> = []
  var aiChatPendingUserMessageIDsByThreadID: [UUID: [UUID]] = [:]
  var activeAIChatUserMessageIDByThreadID: [UUID: UUID] = [:]
  /// User messages this process dispatched to a runtime. One still `sending`
  /// after this host stopped driving its thread is an orphan, not a live turn.
  @ObservationIgnored var aiChatDispatchedUserMessageIDs: Set<UUID> = []
  /// Explicit retries must first reconcile their stable message UUID against
  /// managed-remote Codex history before any new turn is submitted.
  @ObservationIgnored var aiChatRetryTurnStartPolicies: [UUID: CodexTurnStartPolicy] = [:]
  /// Exact authoritative terminal attempt that a distinct retry must extend.
  /// The runtime-host journal validates this edge atomically; this local value
  /// is never sufficient authority by itself.
  @ObservationIgnored var aiChatRetryPredecessorAttemptIDs: [UUID: UUID] = [:]
  @ObservationIgnored var aiChatRetryAttemptGenerationByMessageID: [UUID: Int] = [:]
  @ObservationIgnored var aiChatUnconfirmedOutcomeGenerationByMessageID: [UUID: Int] = [:]
  /// Steers whose delivery task is still running in this process.
  @ObservationIgnored var aiChatInFlightSteerMessageIDs: Set<UUID> = []
  var drainingAIChatThreadIDs: Set<UUID> = []
  var aiChatDrainTasksByThreadID: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
  var stoppedAIChatThreadIDs: Set<UUID> = []
  var aiChatSendOriginsByThreadID: [UUID: AIChatSendOrigin] = [:]
  var aiChatRequestStartedAtByThreadID: [UUID: Date] = [:]
  var openClawGatewayClientsByThreadID: [UUID: OpenClawGatewayClient] = [:]
  var codexAppServerClient: CodexAppServerClient?
  var codexAppServerClientsByDestinationID: [String: CodexAppServerClient] = [:]
  static let codexModelCatalogMaximumAge: TimeInterval = 15 * 60
  var claudeCodeClient: ClaudeCodeClient?
  var piAgentClientsByDestinationID: [String: PiAgentClient] = [:]
  var openCodeClientsByDestinationID: [String: OpenCodeClient] = [:]
  var externalCodexAppServerClient: CodexAppServerClient?
  var externalThreadRefreshRequestID: UUID?
  var externalThreadLoadRequestID: UUID?
  var externalThreadDetailCache: [String: ExternalThreadDetail] = [:]
  var externalThreadDetailCacheOrder: [String] = []
  static let externalThreadDetailCacheLimit = 6
  var codexActiveTurnsByThreadID: [UUID: (runtimeThreadID: String, turnID: String)] = [:]
  var codexDeliveryReceiptsByMessageID: [UUID: AIChatDeliveryReceipt] = [:]
  var codexDeliveryIdentityByRuntimeThreadID: [
    String: (messageID: UUID, attemptID: UUID)
  ] = [:]
  var codexLocalThreadIDsByRuntimeThreadID: [String: UUID] = [:]
  var aiChatPersistentContextState = AIChatPersistentContextState()
  var aiChatActivePersistentContextKeyByDestinationTurn: [AIChatDestinationTurnKey: AIChatPersistentContextKey] = [:]
  var aiChatUsageByDestinationTurn: [AIChatDestinationTurnKey: AIChatTokenUsage] = [:]
  var aiChatContextByDestinationTurn: [AIChatDestinationTurnKey: OpenOrgContextTelemetry] = [:]
  var staleCodexRuntimeThreadIDs: Set<UUID> = []
  var activeSharedRoomRuntimeByThreadID: [UUID: AIChatRuntime] = [:]
  var activeSharedRoomDestinationByThreadID: [UUID: String] = [:]
  /// Runs inside the background pre-turn corpus read before it starts.
  var aiChatCorpusSnapshotGateForTesting: (@Sendable () async -> Void)?
  /// When the user sent the turn now being dispatched, for timing logs.
  var aiChatDispatchSentAtByThreadID: [UUID: Date] = [:]
  var aiChatSteerHandlerForTesting: ((
    _ runtime: AIChatRuntime,
    _ threadID: UUID,
    _ content: String,
    _ attachments: [AIChatAttachment]
  ) async throws -> Void)?
  /// Overrides whether a running thread's live session can accept guidance yet.
  var aiChatSteerReadinessForTesting: ((_ threadID: UUID) -> Bool)?
  /// How long an explicit steer waits for a just-started turn's live session
  /// (for example OpenCode's session ID) before falling back to a follow-up.
  var aiChatSteerReadinessTimeout: Duration = .seconds(45)

  func recordCodexActiveTurnForTesting(
    threadID: UUID,
    runtimeThreadID: String,
    turnID: String,
    destinationID: String = AIChatDestinationConfiguration.localCodexID
  ) {
    codexActiveTurnsByThreadID[threadID] = (runtimeThreadID, turnID)
    codexLocalThreadIDsByRuntimeThreadID["\(destinationID)\u{0}\(runtimeThreadID)"] = threadID
    openClawGatewayStateByThreadID[threadID] = .connected
    aiChatActiveRunIDByThreadID[threadID] = turnID
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else { return }
    var runtimeThreadIDs = thread.runtimeThreadIDsByDestination
    runtimeThreadIDs[destinationID] = runtimeThreadID
    replaceAIChatThread(
      thread.replacingAIChatMetadata(
        runtimeThreadID: destinationID == thread.destinationID ? .some(runtimeThreadID) : nil,
        runtimeThreadIDsByDestination: runtimeThreadIDs
      ),
      transcriptURL: aiChatTranscriptURL,
      shouldPersist: false
    )
  }
  var aiChatRecoveryTasksByThreadID: [UUID: Task<Void, Never>] = [:]
  /// Chats following a detached OpenCode turn, which cannot be steered.
  var openCodeReattachedThreadIDs: Set<UUID> = []
  /// Sends accepted on this host before this process started cannot be driven
  /// by it unless a saved pending turn is being recovered.
  let aiChatProcessStartedAt = Date()
  var aiChatRecoveryTaskTokensByThreadID: [UUID: UUID] = [:]
  var deferredAIChatTranscriptPersistenceTask: Task<Void, Never>?
  var aiChatTranscriptPersistenceGeneration: UInt64 = 0
  var lastEnqueuedAIChatTranscriptStoreGeneration: (generation: UInt64, url: URL)?
  var unloadedAIChatThreadIDs: Set<UUID> = []
  var hydratedAIChatThreadLRU: [UUID] = []
  var aiChatThreadMessageMutationCounter: UInt64 = 0
  var aiChatThreadMessageMutationVersions: [UUID: UInt64] = [:]
  var aiChatThreadMessageRevisions: [UUID: UInt64] = [:]
  var syncedAIChatRefreshTask: Task<Void, Never>?
  var aiChatRepairTask: Task<Void, Never>?
  var syncedAIChatRefreshNeeded = false
  /// Committed chat storage as of the last successful synced refresh. Mobile
  /// Remote reconciles before every thread request; when storage is unchanged
  /// that reload is skipped instead of re-decoding every manifest and
  /// discarding hydrated conversations.
  @ObservationIgnored var syncedAIChatAppliedState: SyncedAIChatAppliedState?
  @ObservationIgnored var syncedAIChatRefreshSkipCountForTesting = 0
  @ObservationIgnored var syncedAIChatRefreshKeptCountForTesting = 0
  // Metadata at the last clean local save or replica import. Message revisions
  // separately protect edits that do not change thread metadata.
  var syncedAIChatCleanMetadata: [UUID: AIChatThread] = [:]
  /// The committed source (shard digest and stored metadata) each thread was
  /// last imported from. A refresh keeps the in-memory thread, including its
  /// loaded messages, when that source is unchanged.
  var syncedAIChatAppliedSources: [UUID: SyncedAIChatThreadSource] = [:]
  var syncedAIChatCleanSettlementSettings = AIChatThreadSettlementSettings()
  var knownAIChatThreadIDsByPath: [String: Set<UUID>] = [:]
  var aiChatTranscriptMutationGeneration: UInt64 = 0
  var aiChatTranscriptPersistedMutationGeneration: UInt64 = 0
  var publishedAIChatMessagesIdentity: PublishedAIChatMessagesIdentity?
  var isApplyingPersistedAIChatThreads = false
  var isApplyingIncrementalAIChatThreadMutation = false
  var pendingAIChatMessageMutationDuringLoad: (threadID: UUID?, messages: [AIChatMessage])?
  var pendingAIChatThreadsDuringLoad: [AIChatThread] = []
  var pendingAIChatSelectionDuringLoad: UUID?
  var aiChatTranscriptWritesBlocked = false
  var aiChatThreadHydrationTasks: [UUID: Task<Void, Never>] = [:]
  var aiChatThreadHydrationTaskTokens: [UUID: UUID] = [:]
  var pendingAIChatHydrationCommits: [UUID: PendingAIChatHydrationCommit] = [:]
  var pendingAIChatHydrationCommitTasks: [UUID: Task<Void, Never>] = [:]
  var inactiveAIChatTranscriptsByPath: [String: AIChatTranscriptState] = [:]
  var inactiveAIChatTranscriptPathLRU: [String] = []
  var aiChatTranscriptLoadTask: Task<Void, Never>?
  var aiChatTranscriptLoadGeneration: UInt64 = 0
  // A non-fixed workspace starts with the fallback URL as an address only; its
  // transcript has not been read yet. Keep that state distinct from an
  // intentionally empty, loaded transcript so switching to a corpus cannot
  // persist an empty placeholder over the migration source before reading it.
  var hasAuthoritativeAIChatTranscriptState = false
  var aiChatInboxDrainTask: (token: UUID, task: Task<Void, Never>)?
  var aiChatInboxDrainRequested = false
  var aiChatTranscriptPersistenceDelayNanoseconds: UInt64 = 750_000_000
  var aiChatTranscriptLoadDelayNanosecondsForTesting: UInt64 = 0
  var aiChatThreadHydrationDelayNanosecondsForTesting: UInt64 = 0
  var aiChatThreadHydrationDidLoadForTesting: ((UUID) -> Void)?
  var aiChatDurabilityBarrierDidEnqueueForTesting: ((URL) -> Void)?
  var aiChatDeferredComposerDidResolveForTesting: (() -> Void)?
  var meetingReadyAutomationEnqueueDidResolveForTesting: ((String) -> Void)?
  var meetingTranscriptionForTesting: (@Sendable (URL) async -> MeetingTranscriptResult)?
  var aiChatDictationRecoveryDirectory = WorkspaceStore.defaultAIChatDictationRecoveryDirectory
  var aiChatFullDisplayRebuildCountForTesting = 0
  var aiChatTranscriptSaverForTesting: (() throws -> Void)?
  /// Runs while an entry save is between formatting and persisting, where a
  /// deferred editor publish can land.
  var entrySaveDidFormatHookForTesting: (@MainActor () async -> Void)?
  var editorPersistenceDelayNanosecondsForTesting: UInt64 = 0
  var editorPersistenceFailureMessageForTesting: String?
  var aiChatVisibleMessageCountCache: [UUID: (rawCount: Int, visibleCount: Int)] = [:]
  var quickOpenChatIndexSignature: [AIChatQuickOpenChatIndexSignature] = []
  var aiChatLocalEditBroker: AIChatLocalEditBroker?
  /// Moves an AI-trashed corpus file to the Trash; tests substitute a folder.
  var aiChatLocalEditFileTrasher: @Sendable (URL) throws -> URL? = { url in
    try WorkspaceStore.moveAIChatLocalEditFileToTrash(url)
  }
  var aiChatLocalEditCorpusRootsByTurnID: [String: URL] = [:]
  var aiChatReadCorpusRootsByTurnID: [String: Set<String>] = [:]
  var openClawLocalEditNode: OpenClawLocalEditNode?
  var openClawLocalEditNodeTask: Task<Void, Never>?
  var aiChatCommandCache: [String: (commands: [AIChatSlashCommand], refreshedAt: Date)] = [:]
  var aiChatActiveCommandDiscoveryID: String?
  var aiChatCommandDiscoveryGeneration = 0
  var aiChatConfigurationGeneration = 0
  @ObservationIgnored var aiChatConfigurationCatalogCache: [String: AIChatConfigurationCatalogCacheEntry] = [:]
  var aiChatConfigurationFallbackNoticesByThreadID: [UUID: String] = [:]
  var activeMeetingRecording: PendingMeetingRecording?
  var meetingRecordingRecoveryExclusionPaths: MeetingArtifactPaths?
  var activeMeetingProcessingCount = 0 {
    didSet {
      isProcessingMeeting = activeMeetingProcessingCount > 0
    }
  }
  var activeMeetingProcessingIDs: Set<String> = []
  var activeMeetingProcessingItems: [String: MeetingProcessingItem] = [:]
  var meetingReadyAutomationDeliveries: [String: MeetingReadyAutomationDeliveryRecord] = [:]
  var meetingReadyAutomationDispatchingEventIDs: Set<String> = []
  var activeAIChatVoiceNoteURL: URL?
  var activeAIChatDictationOrigin: AIChatDictationOrigin?
  var meetingMeterTask: Task<Void, Never>?
  var meetingSystemAudioRecoveryTask: Task<Void, Never>?
  var meetingSystemAudioRecoverySuppressed = false
  nonisolated static let meetingMeterPublishIntervalNanoseconds: UInt64 = 250_000_000
  nonisolated static let meetingSystemAudioRecoveryDelaysNanoseconds: [UInt64] = [
    0,
    350_000_000,
    1_000_000_000
  ]
  nonisolated static let meetingMeterPublishThreshold = 0.03
  nonisolated static let meetingTranscriptionProgressPublishIntervalNanoseconds: UInt64 = 500_000_000
  var meetingTranscriptionProgressTask: Task<Void, Never>?
  var meetingTranscriptionProgressID: UUID?
  var meetingTranscriptionProgressTitle = ""
  var meetingTranscriptionStartedAt: Date?
  var meetingTranscriptionEstimatedDuration: TimeInterval = 120
  var aiChatVoiceMeterTask: Task<Void, Never>?
  var aiChatVoiceTranscriptionProgressTask: Task<Void, Never>?
  @ObservationIgnored var aiChatAttachmentPanel: NSOpenPanel?
  @ObservationIgnored var aiChatAttachmentPreparationTail: Task<Void, Never>?
  var aiChatVoiceTranscriptionStartedAt: Date?
  var aiChatVoiceTranscriptionEstimatedDuration: TimeInterval = 8
  var pendingNodeBriefArtifactRelativePath: String?
  var pendingNodeBriefTitle: String?
  @ObservationIgnored var currentNodeBriefArtifactGeneration: UInt64 = 0
  @ObservationIgnored var currentNodeBriefArtifactTask: Task<Void, Never>?
  @ObservationIgnored var nodeBriefArtifactReadForTesting: (@Sendable (Bool) -> Void)?
  @ObservationIgnored var projectListLoaderForTesting: (@Sendable (URL) async throws -> WorkspaceProjectList)?
  var postAIChatWorkspaceRefreshTask: Task<Void, Never>?
  var corpusSessionGeneration: UInt64 = 0
  @ObservationIgnored let documentMutationLane = WorkspaceDocumentMutationLane()
  @ObservationIgnored var assignedWorkRefreshRequestGeneration: UInt64 = 0
  @ObservationIgnored var activeAssignedWorkRefreshRequestID: UUID?
  @ObservationIgnored var similarTodoScanRequestGeneration: UInt64 = 0
  @ObservationIgnored var dailyNoteNavigationGeneration: UInt64 = 0
  @ObservationIgnored var dailyNoteActivationTask: Task<Void, Never>?
  @ObservationIgnored var homeActivationTask: Task<Void, Never>?
  @ObservationIgnored var currentHomeDailyNotePath: String?
  @ObservationIgnored var dailyNoteDirectoriesByCorpusPath: [String: DailyNoteLocation] = [:]
  @ObservationIgnored var dailyNoteDirectoryTasksByCorpusPath: [
    String: (token: UUID, task: Task<DailyNoteLocation, Never>)
  ] = [:]
  @ObservationIgnored var dailyNoteDirectoryPreparationForTesting: (@Sendable (Bool) -> Void)?
  @ObservationIgnored var dailyNoteDirectoryResolverForTesting: (@Sendable (URL) -> URL)?
  @ObservationIgnored var assignedWorkScanPreparationForTesting: (@Sendable () async -> Void)?
  @ObservationIgnored var similarTodoScanPreparationForTesting: (@Sendable () async -> Void)?
  var corpusEventRefreshGeneration = 0
  var runReviewFileEventRefreshTask: Task<Void, Never>?
  var runReviewFileEventGeneration = 0
  var pendingCorpusChangedPaths: Set<String> = []
  var activeSourceSyncEventBatchCount = 0
  var sourceSyncEventBatchNeedsFallbackScan = false
  var corpusFileWatchers: [String: CorpusFileWatcher] = [:]
  var mountedCorpusEventRefreshTask: Task<Void, Never>?
  var workspaceSurfaceRefreshTasks: [
    WorkspaceSurface: (token: UUID, task: Task<Void, Never>)
  ] = [:]
  var workspaceActivationRefreshTask: Task<Void, Never>?
  var agendaClockRefreshTask: Task<Void, Never>?
  var needsFullCorpusRefreshAfterEvents = false
  var isWorkspaceRealtimeRefreshActive = false
  public internal(set) var dirtyWorkspaceSurfaces: Set<WorkspaceSurface> = []
  var workspaceSurfaceDirtyGenerations: [WorkspaceSurface: UInt64] = [:]
  var mobileRemoteWorkspaceRefreshTask: Task<Void, Never>?
  var mobileRemoteWorkspaceLastRefresh: (key: [UInt64], at: Date)?
  /// Bounds staleness from a missed file event and from date-relative agenda rows.
  static let mobileRemoteWorkspaceRefreshBackstop: TimeInterval = 30
  var corpusFileEventSerial = 0
  var recentCorpusFileEvents: [(serial: Int, path: String)] = []
  var pendingG = false
  var orgRoamLinkResolverGeneration = 0
  @ObservationIgnored var orgRoamLinkResolverRefreshTask: Task<Void, Never>?
  @ObservationIgnored var orgRoamSearchProjectionBuildCountForTesting = 0
  @ObservationIgnored var orgRoamSearchProjectionMainThreadBuildCountForTesting = 0
  @ObservationIgnored let orgRoamSearchProjectionReleaseMetrics =
    OrgRoamSearchProjectionReleaseMetrics()
  @ObservationIgnored let orgRoamSearchProjectionReleaseSink =
    OrgRoamSearchProjectionReleaseSink()
  var orgRoamSearchProjectionReleaseScheduledCountForTesting: Int {
    orgRoamSearchProjectionReleaseMetrics.snapshot.scheduledCount
  }
  var orgRoamSearchProjectionReleaseCompletedCountForTesting: Int {
    orgRoamSearchProjectionReleaseMetrics.snapshot.completedCount
  }
  var orgRoamSearchProjectionMainThreadReleaseCountForTesting: Int {
    orgRoamSearchProjectionReleaseMetrics.snapshot.mainThreadCount
  }
  @ObservationIgnored var corpusFilesGeneration: UInt64 = 0
  @ObservationIgnored var corpusFileProjectionGeneration: UInt64 = 0
  @ObservationIgnored var corpusFileProjectionTask: Task<Void, Never>?
  @ObservationIgnored var corpusFileProjectionBuildCountForTesting = 0
  @ObservationIgnored var pinnedCorpusFileProjectionGeneration: UInt64 = 0
  @ObservationIgnored var pinnedCorpusFileProjectionTask: Task<Void, Never>?
  @ObservationIgnored var pinnedCorpusFileProjectionBuildCountForTesting = 0
  @ObservationIgnored var pinnedCorpusFileProjectionMainThreadBuildCountForTesting = 0
  @ObservationIgnored var pinnedCorpusFileProjectionPublicationCountForTesting = 0
  @ObservationIgnored var pinnedCorpusFileProjectionPreparationForTesting:
    (@Sendable (URL, [String]) async -> Void)?
  @ObservationIgnored var pinnedCorpusFileProjectionDidBuildForTesting:
    (@Sendable (Bool) -> Void)?
  @ObservationIgnored var corpusFileDisplayGeneration: UInt64 = 0
  @ObservationIgnored var corpusFileDisplayTask: Task<Void, Never>?
  @ObservationIgnored var corpusFileProjection = CorpusFileCatalog.Projection.empty
  @ObservationIgnored var pendingCorpusFileUpsertsByPath: [String: CorpusFile] = [:]
  @ObservationIgnored var pendingCorpusFileDeletionPaths: Set<String> = []
  @ObservationIgnored var corpusFileCatalogMutationGeneration: UInt64 = 0
  @ObservationIgnored var corpusFileCatalogMutationTask: Task<Void, Never>?
  var quickOpenIndexedFiles: [QuickOpenIndexedFile] = []
  var quickOpenIndexedChatThreads: [QuickOpenIndexedChatThread] = []
  var quickOpenChatThreadIndexesByID: [UUID: Int] = [:]
  var quickOpenSearchTask: Task<Void, Never>?
  var quickOpenSearchGeneration = 0
  var searchNodeSearchTask: Task<Void, Never>?
  var searchNodeSearchGeneration = 0
  var pageSearchRefreshTask: Task<Void, Never>?
  var pageSearchRefreshGeneration = 0
  var searchIndexTask: Task<Void, Never>?
  var searchIndexGeneration = 0
  var workspaceSearchRequestGeneration: UInt64 = 0
  var entrySourceLoadGeneration = 0
  var entityActionItemsLoadGeneration = 0
  var entryHTMLRenderGeneration = 0
  var activeEntrySourceLoadingGeneration: Int?
  var entrySourceLoadWatchdogTask: Task<Void, Never>?
  var selectedDetailFreshnessTask: Task<Void, Never>?
  @ObservationIgnored var selectedDetailFreshnessMetadataFastPathCountForTesting = 0
  var entryHTMLRenderTask: Task<Void, Never>?
  var entryHTMLRenderWatchdogTask: Task<Void, Never>?
  @ObservationIgnored var appHTMLStylesheetSnapshot = AppHTMLStylesheetSnapshot.empty
  @ObservationIgnored var appHTMLStylesheetSnapshotGeneration: UInt64 = 0
  @ObservationIgnored var appHTMLStylesheetSnapshotTask: Task<Void, Never>?
  @ObservationIgnored var appHTMLStylesheetSnapshotBuildCountForTesting = 0
  @ObservationIgnored var appHTMLStylesheetSnapshotMainThreadBuildCountForTesting = 0
  var appHTMLStylesheetSnapshotPreparationForTesting: (@Sendable (URL) async -> Void)?
  var appHTMLStylesheetSnapshotDidBuildForTesting:
    (@Sendable (URL?, Bool) -> Void)?
  var appHTMLStylesheetSnapshotIdentityForTesting: String {
    appHTMLStylesheetSnapshot.identity
  }
  var appHTMLStylesheetSnapshotCorpusRootPathForTesting: String? {
    appHTMLStylesheetSnapshot.corpusRootPath
  }
  var entrySourceLoadTimeoutNanoseconds: UInt64 = 3_000_000_000
  var entryHTMLRenderTimeoutNanoseconds = WorkspaceStore.defaultEntryRenderTimeoutNanoseconds
  var agendaEntryRenderIdleDelayNanoseconds: UInt64 = 140_000_000
  var entrySourceLoaderForTesting: (@Sendable (String, Int, EntrySourceMode) async throws -> EntrySource)?
  var nodeActionItemsLoaderForTesting: (@Sendable (String, URL) async throws -> NodeActionItemsPayload)?
  var entryHTMLRendererForTesting: (@Sendable (String, String, Int, String?) async throws -> String)?
  var entryNativeRendererPreparationForTesting: (@Sendable () async -> Void)?
  var documentPDFRendererForTesting: ((String, URL?) async throws -> Data)?
  var documentPDFExportFileOpenerForTesting: ((URL) -> Bool)?
  var slideExportFileOpenerForTesting: ((URL) -> Bool)?
  var slidePreviewRendererForTesting: (@Sendable (String, String, Int) async throws -> Data)?
  var linkedPDFDataLoaderForTesting: (@Sendable (URL) async throws -> Data)?
  var linkedPDFLoadTask: Task<Void, Never>?
  var linkedPDFLoadGeneration = 0
  public internal(set) var workspaceRefreshMetrics: [WorkspaceRefreshMetric] = []
  @ObservationIgnored let workspaceTodoScanCache = WorkspaceTodoScanCache()
  var workspaceRefreshConcurrencyForTesting = 2
  var workspaceRefreshUsesBatchForTesting = true
  var workspaceAgentStateLoaderForTesting: (@MainActor () async throws -> WorkspaceAgentStateSnapshot)?
  var workspaceRefreshGeneration = 0
  var workspaceRefreshOperationTask: Task<Void, Never>?
  var workspaceRefreshTaskForTesting: Task<Void, Never>? { workspaceRefreshOperationTask }
  var workspaceRefreshSlowNoticeTask: Task<Void, Never>?
  var workspaceRefreshSlowNoticeNanoseconds = WorkspaceStore.defaultWorkspaceRefreshSlowNoticeNanoseconds
  var workspaceRefreshOperationForTesting: (@MainActor @Sendable () async -> Void)?
  var corpusFileScanForTesting: (@Sendable (URL) async throws -> [CorpusFile])?
  var incrementalCorpusChangePreparationForTesting: (@Sendable (URL, [String]) async -> Void)?
  var mobileRemoteFilePreviewPreparationForTesting: (@Sendable () async -> Void)?
  var mobileRemoteFilePreviewDidReadForTesting: (@Sendable (Bool) -> Void)?
  var approvalCandidateScanOperationForTesting: (@Sendable () -> Void)?
  var fluidVoiceConnectionOperationForTesting: (() async throws -> String)?
  var agentRunApprovalDecisionForTesting: ((
    _ runID: String,
    _ approvalID: String,
    _ decision: String,
    _ note: String?
  ) async throws -> AgentRunItem)?
  var agentRunApprovalSnoozeForTesting: ((
    _ runID: String,
    _ approvalID: String,
    _ until: Date?
  ) async throws -> AgentRunItem)?
  var agentRunSourceReconciliationForTesting: ((_ runID: String) async throws -> Void)?
  var agentRunListLoaderForTesting: (() async throws -> [AgentRunItem])?
  var approvalQueueLoaderForTesting: (() async throws -> (items: [ApprovalItem], runDetails: [AgentRunItem]))?
  @ObservationIgnored var activityExplanationLoaderForTesting: (([String]) async throws -> WorkspaceActivityExplanationPayload)?
  var workspaceSearchLoaderForTesting: ((String, [String]) async throws -> SearchPayload)?
  var runReviewPageRefreshOperationForTesting: ((RunsAndReviewPage) async -> Void)?
  var agentRunDetailLoaderForTesting: ((_ runID: String) async throws -> AgentRunItem)?
  var deferredAgentRunsRefreshDelayNanoseconds: UInt64 = 1_000_000_000
  var agentRunClarificationReplyForTesting: ((
    _ run: AgentRunItem,
    _ response: String
  ) async throws -> OpenClawRunContinuation)?
  var agentRunApprovalContinuationForTesting: ((
    _ run: AgentRunItem
  ) async throws -> OpenClawApprovedRunContinuation)?
  var agentRunApprovalContinuationFailureForTesting: ((
    _ run: AgentRunItem,
    _ reason: String
  ) async throws -> AgentRunItem)?
  var agentRunRevisionResumeForTesting: ((
    _ run: AgentRunItem
  ) async throws -> AgentRunItem)?
  var agentRunRevisionDispatchForTesting: ((
    _ run: AgentRunItem,
    _ approval: AgentRunApprovalItem,
    _ prompt: String,
    _ sessionKey: String
  ) async throws -> Void)?
  var agentRunExternalCompletionForTesting: ((
    _ runID: String,
    _ summary: String
  ) async throws -> AgentRunItem)?
  var todoStatusMutationForTesting: (@Sendable (
    _ status: TodoEditStatus,
    _ file: String,
    _ line: Int
  ) async throws -> String)?
  var agendaRefreshLoaderForTesting: (@MainActor ([String]) async throws -> AgendaPayload)?
  var liveFileEditorAutosaveTask: Task<Void, Never>?
  var liveFileEditorAutosaveGeneration = 0
  var liveFileEditorDraftGeneration: UInt64 = 0
  var liveFileEditorSavedDraftGeneration: UInt64 = 0
  var sourceEditorDraftGeneration: UInt64 = 0
  var sourceEditorSavedDraftGeneration: UInt64 = 0
  var editorPersistenceTail: Task<EditorPersistenceOutcome, Never>?
  var pendingEditorPersistenceTasks: [UUID: Task<EditorPersistenceOutcome, Never>] = [:]
  var pendingEditorPersistenceCountsByKey: [String: Int] = [:]
  var editorPersistenceRegionStates: [String: EditorPersistenceRegionState] = [:]
  var editorPersistenceFailuresByKey: [String: String] = [:]
  var isPreparingForTermination = false
  var sourceEditorCommandGeneration = 0
  var backlinksLoadGeneration = 0
  var backlinksLoadTask: Task<Void, Never>?
  var backlinksSelectionIdleDelayNanoseconds: UInt64 = 250_000_000
  var backlinksLoaderForTesting: (@Sendable (WorkspaceLocation) async throws -> BacklinksPayload?)?
  var workspaceNavigationBackStack: [WorkspaceNavigationSnapshot] = [] {
    didSet {
      canNavigateBack = !workspaceNavigationBackStack.isEmpty
    }
  }
  var workspaceNavigationForwardStack: [WorkspaceNavigationSnapshot] = [] {
    didSet {
      canNavigateForward = !workspaceNavigationForwardStack.isEmpty
    }
  }
  var workspaceTabStates: [WorkspaceTab.ID: WorkspaceTabState] = [:]
  var workspaceTabEditorRestoreTask: Task<Void, Never>?
  var workspaceTabEditorRestoreGeneration = 0
  var workspaceTabEditorRestoreTarget: (
    tabID: WorkspaceTab.ID,
    surface: WorkspaceSurface,
    locationIdentity: String
  )?
  var workspaceUndoStack: [WorkspaceUndoAction] = []
  var workspaceRedoStack: [WorkspaceUndoAction] = []
  var corpusWorkspaceCaches: [String: CorpusWorkspaceCache] = [:]
  var corpusFilesByPath: [String: CorpusFile] = [:]
  @ObservationIgnored let workspaceCacheReleaseMetrics = WorkspaceCacheReleaseMetrics()
  @ObservationIgnored let workspaceCacheReleaseSink = WorkspaceCacheReleaseSink()
  var workspaceCacheReleaseScheduledCountForTesting: Int {
    workspaceCacheReleaseMetrics.snapshot.scheduledCount
  }
  var workspaceCacheReleaseCompletedCountForTesting: Int {
    workspaceCacheReleaseMetrics.snapshot.completedCount
  }
  var workspaceCacheMainThreadReleaseCountForTesting: Int {
    workspaceCacheReleaseMetrics.snapshot.mainThreadCount
  }
  var canonicalDocumentCache: [String: WorkspaceCacheBox<CanonicalDocumentCacheEntry>] = [:]
  var canonicalDocumentCacheOrder: [String] = []
  var entrySourceCache: [String: WorkspaceCacheBox<EntrySourceCacheEntry>] = [:]
  var entrySourceCacheOrder: [String] = []
  var renderedBlocksCache: [String: WorkspaceCacheBox<RenderedBlocksCacheEntry>] = [:]
  var renderedBlocksCacheOrder: [String] = []
  var renderedHTMLCache: [String: WorkspaceCacheBox<RenderedHTMLCacheEntry>] = [:]
  var renderedHTMLCacheOrder: [String] = []
  var liveEmbedSourceID: String?
  var selectedEntryHTMLRenderKey: String?
  var entrySourceRenderIdentities: [String: String] = [:]
  var nextSelectedEntrySourceRenderIdentity: String?
  var nextSelectedEntrySourceModifiedAt: Date?
  var selectedEntrySourceModifiedAt: Date?
  private var entrySourceRenderIdentitySequence: UInt64 = 0
  var selectedFileMetadataGeneration = 0
  var nextSelectedEntrySourceLineIndex: OrgSourceLineIndex?
  var selectedEntrySourceLineIndex: OrgSourceLineIndex?
  var sourceEditorPreparationTask: Task<Void, Never>?
  var sourceEditorPreparationGeneration = 0
  var selectedFileDataNotebookTask: Task<Void, Never>?
  var selectedFileDataNotebookInspectionForTesting:
    (@Sendable (URL, String?) async -> Bool)?
  var selectedFileDataNotebookDidInspectForTesting: (@Sendable (Bool) -> Void)?
  var selectedGooglePublicationGeneration = 0
  var selectedGooglePublicationTask: Task<Void, Never>?
  var selectedEntityMetadataGeneration = 0
  var selectedEntityMetadataTask: Task<Void, Never>?
  var pendingBlockSelection: PendingBlockSelection?
  var transientDraftBlock: TransientDraftBlock?
  var transientDraftIDCounter = 0
  var activeBlockDrafts: [OrgEditableBlock.ID: String] = [:]
  var activeBlockOriginals: [OrgEditableBlock.ID: OrgEditableBlock] = [:]
  var activeBlockInitialSelections: [OrgEditableBlock.ID: NSRange] = [:]
  var deferredStableAutosaves: [OrgEditableBlock.ID: DeferredStableAutosave] = [:]
  var preservesSelectedRenderedBlocksMetadataForNextAssignment = false
  var nextSelectedRenderedBlocksMetadata: RenderedBlocksMetadata?
  var isRefreshingAgenda = false
  var isRefreshingAgendaForTesting: Bool { isRefreshingAgenda }
  var isRefreshingApprovals = false
  var approvalRefreshRequestedAfterCurrent = false
  var approvalRefreshFollowUpUpdatesStatus = false
  /// Bumped whenever a local approval decision lands. An approvals scan that
  /// started before the bump read pre-decision files, so its result must not
  /// resurrect the decided item; a fresh scan replaces it instead.
  var approvalMutationGeneration = 0
  var agentRunsRefreshRequestedAfterCurrent = false
  var isRefreshingAgentRuns = false
  var isRefreshingAgentWorkflows = false
  var isRefreshingAgentGoals = false
  var isRefreshingAgentProfiles = false
  var runReviewPageLoadStates: [String: RunReviewPageLoadState] = [:]
  var isRefreshingAssignedWork = false
  var isRefreshingAIChatThreadRecords = false
  var scheduledAgendaRefreshTask: Task<Void, Never>?
  var scheduledApprovalsRefreshTask: Task<Void, Never>?
  var scheduledAgentRunsRefreshTask: Task<Void, Never>?
  var agendaSelectionAnchor: AgendaSelectionAnchor?
  var approvalSelectionAnchor: ApprovalSelectionAnchor?
  var runReviewAutoRefreshTask: Task<Void, Never>?
  var isRunReviewAutoRefreshActive = false
  var sourceAutoSyncTask: Task<Void, Never>?
  var sourceAutoSyncActivationTask: Task<Void, Never>?
  var isSourceAutoSyncActive = false
  var automationSchedulerPresentedErrorText: String?
  var automationSchedulerTask: Task<Void, Never>?
  var automationSchedulerActivationTask: Task<Void, Never>?
  var isAutomationSchedulerActive = false
  var dispatchingAutomationIDs: Set<String> = []
  var automationRunIDsByThreadID: [UUID: String] = [:]
  var agendaTodoShortcutMutationTask: Task<Void, Never>?
  var pendingAgendaTodoShortcutMutations: [AgendaTodoShortcutMutation] = []
  var agendaRefreshDeferredForTodoShortcutBurst = false
  var agendaTodoShortcutMutationGeneration: UInt64 = 0
  var pendingAgendaRefreshAfterBlockEditing = false
  var assignedWorkSearchRows: [AssignedWorkSearchRow] = []
  var agentRunFilterTextByID: [AgentRunItem.ID: String] = [:]
  var agentRunsByID: [AgentRunItem.ID: AgentRunItem] = [:]
  var agentRunFilterTerms: [String] = []
  var agentRunScopeCounts: [AgentRunScope: Int] = [:]
  var agentRunScopeEntriesByScope: [AgentRunScope: [AgentRunScopeEntry]] = [:]
  var filteredAgentRunScopeEntries: [AgentRunScope: [AgentRunScopeEntry]] = [:]
  var filteredAgentRunScopeIDs: [AgentRunScope: [AgentRunItem.ID]] = [:]
  var filteredAgentRunScopeIDSets: [AgentRunScope: Set<AgentRunItem.ID>] = [:]
  var agentRunSectionsByScope: [AgentRunScope: [RunCenterSection]] = [:]
  var agentRunSourceMeetingContextsByID: [AgentRunItem.ID: AgentRunContextItem] = [:]
  var agentRunIDsBySourceMeetingReference: [String: [AgentRunItem.ID]] = [:]
  var agentRunCountByGoalRef: [String: Int] = [:]
  var agentRunCountByAgentRef: [String: Int] = [:]
  @ObservationIgnored var agentRunProjectionGeneration: UInt64 = 0
  @ObservationIgnored var agentRunProjectionTask: Task<Void, Never>?
  @ObservationIgnored var agentRunProjectionBuildCountForTesting = 0
  @ObservationIgnored var agentRunProjectionIndexReuseCountForTesting = 0
  /// Bumped on every `agentRuns` assignment. A published projection built for
  /// the current revision can be re-filtered without rebuilding its per-run
  /// search text, scope entries, and source-meeting contexts.
  @ObservationIgnored var agentRunsRevision: UInt64 = 0
  @ObservationIgnored var agentRunProjectionIndexes: (revision: UInt64, box: AgentRunProjectionBox)?
  @ObservationIgnored var agentRunProjectionMainThreadBuildCountForTesting = 0
  @ObservationIgnored var agentRunProjectionPreparationForTesting: (@Sendable () async -> Void)?
  @ObservationIgnored var agentRunProjectionDidBuildForTesting: (@Sendable (Bool) -> Void)?
  @ObservationIgnored var searchNodeIndexRows: [SearchNodeIndexRow] = []
  var sourceEditorPreviewTask: Task<Void, Never>?
  var sourceEditorPreviewGeneration = 0
  static let sourceEditorPreviewIdleDelayNanoseconds: UInt64 = 1_200_000_000
  var slidePreviewTask: Task<Void, Never>?
  var slidePreviewGeneration = 0
  static let slidePreviewIdleDelayNanoseconds: UInt64 = 1_400_000_000
  var slidePreviewSourceID: String?
  var sourceEditorLocalDraftText: String?
  @ObservationIgnored var fileUndoSnapshotReadForTesting: (@Sendable (Bool) -> Void)?
  var documentViewportSourceLines: [String: Int] = [:]
  var documentSlidePageIndexes: [String: Int] = [:]
  @ObservationIgnored var corpusAgentSkillRefreshGeneration: UInt64 = 0
  @ObservationIgnored var corpusAgentSkillRefreshTask: Task<Void, Never>?
  @ObservationIgnored var corpusAgentSkillLoadedCorpusPath: String?
  @ObservationIgnored var corpusAgentSkillRefreshCorpusPath: String?
  @ObservationIgnored var corpusAgentSkillDiscoveryForTesting: (@Sendable (Bool) -> Void)?
  @ObservationIgnored var orgCryptRecipientRefreshGeneration: UInt64 = 0
  @ObservationIgnored var orgCryptRecipientRefreshTask: Task<Void, Never>?
  @ObservationIgnored var orgCryptRecipientScanForTesting: (@Sendable (Bool) -> Void)?
  var documentPreviewOverrides: [String: String] = [:]
  var inferredDocumentPreviewKinds: [String: OrgDocumentPreviewKind] = [:]
  var slidePreviewZoomScales: [String: CGFloat] = [:]
  var slidePreviewNavigationGeneration = 0
  var editorSaveConflictSource: EntrySource?
  var editorSaveConflictDraft: String?
  var editorSaveConflictPersistenceKey: String?
  var failedEditorPersistenceDraftsByKey: [String: FailedEditorPersistenceDraft] = [:]
  public var automationHostRef: String = "desktop"
  /// The corpus's scheduler owner from `celorga.json` or `org2.json` (`automationHostRef`),
  /// read when Activity refreshes. Nil until read.
  public internal(set) var corpusAutomationHostRef: String?
  /// Context-aware actions and lifecycle hooks contributed by locked plugins.
  public internal(set) var pluginActions: [WorkspacePluginAction] = []
  public internal(set) var pluginHooks: [WorkspacePluginHook] = []
  /// Plugin proposals (from actions or hooks) waiting for a person.
  public internal(set) var pendingPluginProposals: [WorkspacePluginProposal] = []
  /// The plugin output and proposal currently under review.
  public var activePluginReview: WorkspacePluginReview?
  /// The in-app web browser surface.
  public let browser = WorkspaceBrowserModel()
  /// Show the selected HTML file's source instead of the rendered page.
  public var htmlFileShowsSource = false
  @ObservationIgnored var isDispatchingPluginHooks = false
  public internal(set) var selectedNodeEntityType: Org2EntityType?
  public internal(set) var selectedNodeHasExplicitEntityType = false
  /// Headings currently being started, keyed by "file:line", so a double
  /// click cannot create two runs for one task.
  var startingWorkHeadingKeys: Set<String> = []
  var headingWorkLinksCache: (file: String, startLine: Int, text: String, links: [HeadingWorkLink])?
  var activeBundledAgentThreadID: UUID?

  public init(
    cli: Org2CLI? = nil,
    defaults: UserDefaults = .standard,
    aiChatTranscriptURL: URL? = nil,
    aiChatFallbackTranscriptURL: URL? = nil,
    aiChatSendHandler: (@Sendable ([AIChatMessage], String, String, AIChatWorkspaceContext?) async throws -> String)? = nil,
    aiChatRecoveryHandler: (@Sendable (AIChatPendingTurn, String) async throws -> String)? = nil,
    codexSendHandlerForTesting: (@Sendable ([AIChatMessage], UUID, AIChatWorkspaceContext) async throws -> String)? = nil,
    codexLocalExecutableURLForTesting: URL? = nil,
    codexManagedRemoteSSHExecutableURLForTesting: URL? = nil,
    claudeSendHandlerForTesting: (@Sendable ([AIChatMessage], UUID, AIChatWorkspaceContext) async throws -> ClaudeCodeTurnResult)? = nil,
    legacyDefaultsDomains: [String]? = nil,
    automaticStarterCorpusURL: URL? = nil,
    localDocumentPublicationHost: LocalDocumentPublicationHost? = nil,
    openClawDeviceIdentityFileURL: URL? = nil,
    usageLogURL: URL? = nil
  ) {
    let initialWorkspaceTab = WorkspaceTab(
      title: WorkspaceSurface.home.title,
      systemImage: WorkspaceSurface.home.systemImage
    )
    workspaceTabs = [initialWorkspaceTab]
    selectedWorkspaceTabID = initialWorkspaceTab.id
    self.defaults = defaults
    self.usageLog = OpenOrgUsageLog(defaults: defaults, fileURL: usageLogURL)
    usageLog.record(.sessionStart, ["reason": "launch"])
    self.aiChatReadState = AIChatReadState(defaults: defaults)
    AIChatLocalHostRegistry.shared.register(
      AIChatHostIdentity.desktop(writer: AIChatTranscriptStore.shared.writerIdentity).ref
    )
    self.localDocumentPublicationHost = localDocumentPublicationHost
      ?? LocalDocumentPublicationHost(
        preferredAdvertisedHost: NSClassFromString("XCTestCase") == nil
          ? LocalDocumentPublicationHost.tailscaleAdvertisedHost
          : nil,
        storageDirectory: Self.localDocumentPublicationStorageDirectory()
      )
    self.automaticStarterCorpusURL = automaticStarterCorpusURL
      ?? (NSClassFromString("XCTestCase") == nil ? Self.defaultStarterCorpusURL() : nil)
    sourceScheduleStateStore = WorkspaceSourceScheduleStateStore(defaults: defaults)
    mountedCorpora = Self.shouldIgnoreStandardDefaultsForTests(defaults)
      ? []
      : Self.restoreCorpusMounts(from: defaults, key: corpusMountsKey)
    let fallbackTranscriptURL = aiChatFallbackTranscriptURL ?? Self.defaultAIChatTranscriptURL()
    usesFixedAIChatTranscriptURL = aiChatTranscriptURL != nil
    appAIChatTranscriptURL = fallbackTranscriptURL
    self.aiChatTranscriptURL = aiChatTranscriptURL ?? fallbackTranscriptURL
    self.aiChatSendHandler = aiChatSendHandler
    self.aiChatRecoveryHandler = aiChatRecoveryHandler
    self.codexSendHandlerForTesting = codexSendHandlerForTesting
    self.codexLocalExecutableURLForTesting = codexLocalExecutableURLForTesting
    self.codexManagedRemoteSSHExecutableURLForTesting = codexManagedRemoteSSHExecutableURLForTesting
    self.claudeSendHandlerForTesting = claudeSendHandlerForTesting
    self.openClawDeviceIdentityFileURL = openClawDeviceIdentityFileURL
    self.cli = cli
      ?? (try? Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
      ?? Org2CLI(repoRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    let publicationCLI = self.cli
    chatThreadPublicationRenderer = AIChatThreadPublicationRenderer { text in
      // Embeds stay references so a shared thread cannot pull in other notes.
      try await publicationCLI.renderAppHTML(
        text,
        sourcePath: FileManager.default.temporaryDirectory
          .appendingPathComponent("shared-chat-message.org").path,
        resolveEmbeds: false
      )
    }
    aiChatPreferredExecutionHostRef = defaults.string(forKey: Self.aiChatPreferredExecutionHostKey)
    openOrgServer = OpenOrgServerConnection(
      defaults: defaults,
      credentials: NSClassFromString("XCTestCase") == nil
        ? OpenOrgServerKeychainCredentials()
        : OpenOrgServerMemoryCredentials()
    )
    let settings = OpenClawGatewaySettings.resolve()
    let migrationDomains = legacyDefaultsDomains
      ?? (
        defaults === UserDefaults.standard
          && !Self.shouldIgnoreStandardDefaultsForTests(defaults)
          && Self.shouldMigrateLegacyDefaultsForCurrentBundle()
          ? Self.legacyDefaultsDomains
          : []
      )
    migrateLegacyDefaultsIfNeeded(
      legacyDomains: migrationDomains,
      defaultOpenClawEndpoint: settings.endpoint.absoluteString
    )
    agendaMode = Self.shouldIgnoreStandardDefaultsForTests(defaults)
      ? .focus
      : Self.restoreAgendaMode(from: defaults, key: agendaModeKey)
    agendaOverdueOrder = defaults.string(forKey: agendaOverdueOrderKey)
      .flatMap(AgendaOverdueOrder.init(rawValue:)) ?? .priority
    openClawEndpointText = defaults.string(forKey: openClawEndpointKey) ?? settings.endpoint.absoluteString
    openClawAgentID = defaults.string(forKey: openClawAgentKey) ?? "main"
    agentHandoffAssignee = defaults.string(forKey: agentHandoffAssigneeKey) ?? Self.defaultAgentHandoffAssignee
    personalAssigneeNamesText = defaults.string(forKey: personalAssigneeNamesKey) ?? ""
    openClawRemoteCorpusPath = defaults.string(forKey: openClawRemoteCorpusPathKey) ?? ""
    aiChatCorpusAccessScope = defaults.string(forKey: aiChatCorpusAccessScopeKey)
      .flatMap(WorkspaceReadScope.init(rawValue:)) ?? .activeCorpus
    aiChatCustomInstructions = defaults.string(forKey: aiChatCustomInstructionsKey) ?? ""
    aiChatDestinations = Self.restoreAIChatDestinations(
      from: defaults,
      key: aiChatDestinationsKey
    )
    aiChatConfigurationCatalogCache = Self.restoreAIChatConfigurationCatalogCache(
      from: defaults,
      key: aiChatConfigurationCatalogCacheKey
    )
    codexSandboxAccess = defaults.string(forKey: codexSandboxAccessKey)
      .flatMap(CodexSandboxAccess.init(rawValue:)) ?? .workspaceWrite
    aiChatMessageSound = defaults.string(forKey: aiChatMessageSoundKey)
      .flatMap(AIChatMessageSound.init(rawValue:)) ?? .org2
    let repairInterval = defaults.object(forKey: aiChatRepairIntervalKey) as? Double
      ?? AIChatTranscriptRepair.defaultIntervalSeconds
    aiChatRepairIntervalSeconds = repairInterval.isFinite && (repairInterval == 0 || (10...86_400).contains(repairInterval))
      ? repairInterval : AIChatTranscriptRepair.defaultIntervalSeconds
    aiChatIncomingMessageSoundPlayer = Self.messageSoundPlayer(for: aiChatMessageSound)
    if let storedTurnLimit = defaults.object(forKey: aiChatDefaultRoomAgentTurnLimitKey) as? Int {
      aiChatDefaultRoomAgentTurnLimit = storedTurnLimit
    }
    appearanceMode = defaults.string(forKey: appearanceModeKey)
      .flatMap(WorkspaceAppearanceMode.init(rawValue:)) ?? .system
    lightThemeID = WorkspaceThemeCatalog.theme(id: defaults.string(forKey: lightThemeIDKey), for: .light).id
    darkThemeID = WorkspaceThemeCatalog.theme(id: defaults.string(forKey: darkThemeIDKey), for: .dark).id
    applyThemeSelection()
    experimentalFeaturesEnabled = defaults.bool(forKey: experimentalFeaturesEnabledKey)
    aiChatBriefsStartNewThread = defaults.object(forKey: aiChatBriefsStartNewThreadKey) as? Bool ?? true
    if let data = defaults.data(forKey: nodeBriefConfigurationKey),
       let configuration = try? JSONDecoder().decode(NodeBriefAIConfiguration.self, from: data) {
      nodeBriefConfiguration = configuration
    }
    if let data = defaults.data(forKey: startWorkLastOptionsKey),
       let options = try? JSONDecoder().decode(StartWorkOptions.self, from: data) {
      startWorkLastOptions = options
    }
    openClawLocalEditsEnabled = defaults.bool(forKey: openClawLocalEditsEnabledKey)
    renderedDocumentWidth = defaults.string(forKey: renderedDocumentWidthKey)
      .flatMap(RenderedDocumentWidth.init(rawValue:)) ?? .comfortable
    renderedDocumentMargin = defaults.string(forKey: renderedDocumentMarginKey)
      .flatMap(RenderedDocumentMargin.init(rawValue:)) ?? .standard
    meetingTranscriptionProvider = defaults.string(forKey: meetingTranscriptionProviderKey)
      .flatMap(MeetingTranscriptionProvider.init(rawValue:)) ?? .automatic
    fluidVoiceEndpointText = defaults.string(forKey: fluidVoiceEndpointKey)
      ?? MeetingTranscriptionConfiguration.defaultFluidVoiceEndpoint
    customTranscriptionCommandText = defaults.string(forKey: customTranscriptionCommandKey) ?? ""
    whisperModelPathText = defaults.string(forKey: whisperModelPathKey) ?? ""
    transcriptionLanguageText = defaults.string(forKey: transcriptionLanguageKey) ?? "en"
    propertyDrawersExpandedByDefault = defaults.object(forKey: propertyDrawersExpandedByDefaultKey) as? Bool ?? true
    formatOrgFilesOnSave = defaults.object(forKey: formatOrgFilesOnSaveKey) as? Bool ?? true
    sourceEditorVimModeEnabled = defaults.bool(forKey: sourceEditorVimModeKey)
    sourceEditorPresentation = defaults.string(forKey: sourceEditorPresentationKey)
      .flatMap(SourceEditorPresentation.init(rawValue:)) ?? .source
    documentPreviewOverrides = Self.restoreDocumentPreviewOverrides(
      from: defaults,
      key: documentPreviewOverridesKey
    )
    documentViewportSourceLines = Self.restoreDocumentViewportSourceLines(
      from: defaults,
      key: documentViewportSourceLinesKey
    )
    documentSlidePageIndexes = Self.restoreDocumentViewportSourceLines(
      from: defaults,
      key: documentSlidePageIndexesKey,
      minimumValue: 0
    )
    orgCryptEncryptOnSave = defaults.object(forKey: orgCryptEncryptOnSaveKey) as? Bool ?? true
    orgCryptRecipientsText = OrgCryptSettings.listText(defaults.stringArray(forKey: orgCryptRecipientsKey) ?? [])
    orgCryptRecipientFilesText = OrgCryptSettings.listText(defaults.stringArray(forKey: orgCryptRecipientFilesKey) ?? [])
    orgCryptUseDefaultGpgKey = defaults.object(forKey: orgCryptUseDefaultGpgKeyKey) as? Bool ?? true
    if defaults.object(forKey: orgCryptUseDefaultGpgKeyMigrationKey) == nil {
      orgCryptUseDefaultGpgKey = true
      defaults.set(true, forKey: orgCryptUseDefaultGpgKeyKey)
      defaults.set(true, forKey: orgCryptUseDefaultGpgKeyMigrationKey)
    }
    orgCryptGpgProgram = defaults.string(forKey: orgCryptGpgProgramKey) ?? "gpg"
    if usesFixedAIChatTranscriptURL {
      if Self.shouldLoadAIChatTranscriptAsynchronously(self.aiChatTranscriptURL) {
        startAIChatTranscriptReload()
      } else {
        let loaded = loadAIChatTranscriptForWorkspace(from: self.aiChatTranscriptURL)
        aiChatTranscriptWritesBlocked = loaded.recoveryStatus.blocksWrites
        isApplyingPersistedAIChatThreads = true
        applyAIChatTranscript(loaded.transcript, shouldPersist: false)
        isApplyingPersistedAIChatThreads = false
        initializeHydratedAIChatThreadLRU()
        applyAIChatTranscriptRecoveryStatus(loaded.recoveryStatus)
        if loaded.requiresMigration { persistAIChatTranscript() }
        persistStaleLocalAIChatSendRepair(loaded.interruptedSendThreadIDs)
      }
    }
    shouldPersistAIChatMessages = true
    openClawHasStoredToken = OpenClawKeychain.containsToken()
    // One-time machine-state bootstrap. Operational crypt actions perform
    // their potentially interactive keychain access off MainActor below.
    orgCryptHasStoredPassphrase = OrgCryptKeychain.containsPassphrase()
    scarfMetabaseHasStoredAPIKey = DataSourceCredentialsKeychain.containsScarfMetabaseAPIKey()
    aiChatStatusText = Self.aiChatStatusText(settings: currentOpenClawSettings())
    restoreInterruptedAIChatSendStatusIfNeeded()
  }
}

// Observation's member macros serialize their enclosing declaration for each
// expansion. Keep stored state and initialization in the small Observable
// class above. The implementation lives in WorkspaceStore+NN*.swift
// extensions, split across files so the compiler can build them in parallel;
// keep a member private when only its own file uses it.

struct PendingMeetingRecording {
  let paths: MeetingArtifactPaths
  let capturesSystemAudio: Bool
  let systemAudioStartError: String?
}

struct AudioSettingsProcessResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

enum AudioSettingsError: LocalizedError {
  case homebrewNotFound
  case installFailed(String)
  case providerUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .homebrewNotFound:
      "Homebrew is required to install whisper.cpp automatically."
    case .installFailed(let output):
      output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Audio transcription install failed."
        : "Audio transcription install failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    case .providerUnavailable(let message):
      message
    }
  }
}

struct AIChatAttachmentPreparationResult: Sendable {
  let fileName: String
  let attachment: AIChatAttachment?
  let errorDescription: String?
}

enum AIChatAttachmentError: LocalizedError {
  case unsupportedImage(String)
  case unsupportedVideo(String)
  case notRegularFile(String)
  case tooLarge(String, maxMegabytes: Int)

  var errorDescription: String? {
    switch self {
    case .unsupportedImage(let name):
      return "\(name) is not a supported image attachment."
    case .unsupportedVideo(let name):
      return "\(name) is a video, which OpenClaw chat attachments do not support."
    case .notRegularFile(let name):
      return "\(name) is not a regular file."
    case .tooLarge(let name, let maxMegabytes):
      return "\(name) is larger than the \(maxMegabytes) MB OpenClaw attachment limit."
    }
  }
}

enum AIChatRemoteConfigurationError: LocalizedError {
  case threadNotFound
  case turnInProgress
  case unknownModel(String)
  case unknownReasoningEffort(String)

  var errorDescription: String? {
    switch self {
    case .threadNotFound:
      "The remote chat no longer exists."
    case .turnInProgress:
      "Stop the current response before changing models."
    case .unknownModel(let model):
      "The selected runtime did not report the model ‘\(model)’."
    case .unknownReasoningEffort(let effort):
      "The selected model did not report the reasoning level ‘\(effort)’."
    }
  }
}

/// A deliberately narrow decode keeps a valid daily-note override usable even
/// when an unrelated optional config section contains a value this app version
/// does not understand.
struct WorkspaceDailyNoteConfig: Decodable {
  let roam: Roam?

  struct Roam: Decodable {
    let dailiesDir: String?
    let dailyFileTemplate: String?
  }
}

struct WorkspaceOrg2Config: Decodable {
  let roam: Roam?
  let links: Links?
  let openClaw: OpenClaw?

  enum CodingKeys: String, CodingKey {
    case roam
    case links
    case openClaw
    case openclaw
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    roam = try container.decodeIfPresent(Roam.self, forKey: .roam)
    links = try container.decodeIfPresent(Links.self, forKey: .links)
    openClaw = try container.decodeIfPresent(OpenClaw.self, forKey: .openClaw)
      ?? container.decodeIfPresent(OpenClaw.self, forKey: .openclaw)
  }

  struct Roam: Decodable {
    let indexDir: String?
    let nodesDir: String?
    let dailiesDir: String?
  }

  struct Links: Decodable {
    let abbreviations: [String: String]?
    let linearTeam: String?
  }

  struct OpenClaw: Decodable {
    let threadDirs: [String]?
  }
}

enum AIChatPendingTurnUpdate {
  case preserve
  case replace(AIChatPendingTurn?)
}

struct AIChatTranscriptState: Sendable {
  let threads: [AIChatThread]
  let selectedThreadID: UUID?
  let settlementSettings: AIChatThreadSettlementSettings
}

struct AIChatWorkspaceTranscriptLoad: Sendable {
  let transcript: AIChatTranscriptState
  let unloadedThreadIDs: Set<UUID>
  let requiresMigration: Bool
  let recoveryStatus: AIChatTranscriptRecoveryStatus
  /// Threads whose stale sends were marked interrupted in memory at load.
  var interruptedSendThreadIDs: Set<UUID> = []
}

struct AIChatPreparedWorkspaceTranscriptLoad: Sendable {
  let loaded: AIChatWorkspaceTranscriptLoad
  let presentations: [AIChatPreparedMessagePresentation]
}

struct SyncedAIChatThreadSource: Equatable, Sendable {
  let shardDigest: String
  let metadata: AIChatThread
}

struct SyncedAIChatAppliedState: Equatable, Sendable {
  let transcriptPath: String
  let transcriptGeneration: UInt64
  let fingerprint: String
  /// Threads kept local during that refresh, so not yet imported.
  let protectedThreadIDs: Set<UUID>

  /// A refresh can be skipped only when storage is byte-for-byte the same
  /// and every thread held back last time is still held back; a thread that
  /// lost its protection must now import the replica it skipped.
  func allowsSkipping(
    transcriptPath: String,
    transcriptGeneration: UInt64,
    fingerprint: String?,
    protectedThreadIDs current: Set<UUID>
  ) -> Bool {
    guard let fingerprint else { return false }
    return self.transcriptPath == transcriptPath
      && self.transcriptGeneration == transcriptGeneration
      && self.fingerprint == fingerprint
      && protectedThreadIDs.isSubset(of: current)
  }
}

struct PendingAIChatHydrationCommit: Sendable {
  let thread: AIChatThread
  let messageCount: Int?
  let transcriptPath: String
  let transcriptGeneration: UInt64
  let mutationVersion: UInt64
}

struct AIChatTranscriptPayload: Codable {
  let version: Int
  let messages: [AIChatMessage]?
  let threads: [AIChatThread]?
  let selectedThreadID: UUID?
  let settlementSettings: AIChatThreadSettlementSettings?
}

enum WorkspaceEditError: LocalizedError {
  case noCorpusRoot
  case emptyTitle
  case noHeadline(file: String, line: Int)
  case invalidRange(file: String, line: Int)
  case fileChanged(file: String)
  case destructiveWriteBlocked(file: String, backup: String?, operation: String)

  var errorDescription: String? {
    switch self {
    case .noCorpusRoot:
      "No corpus selected"
    case .emptyTitle:
      "Title cannot be empty"
    case .noHeadline(let file, let line):
      "No headline found at \(file):\(line)"
    case .invalidRange(let file, let line):
      "Invalid edit range at \(file):\(line)"
    case .fileChanged(let file):
      "File changed on disk; reload \(file) before saving"
    case .destructiveWriteBlocked(let file, let backup, let operation):
      if let backup {
        "Blocked \(operation) because it would empty \(file). Recovery copy saved at \(backup)."
      } else {
        "Blocked \(operation) because it would empty \(file)."
      }
    }
  }
}

final class SourceRunOutputCollector: @unchecked Sendable {
  let lock = NSLock()
  var storage = Data()

  func set(_ data: Data) {
    lock.lock()
    storage = data
    lock.unlock()
  }

  var data: Data {
    lock.lock()
    let data = storage
    lock.unlock()
    return data
  }
}

public enum WorkspaceSurface: String, CaseIterable, Identifiable, Sendable {
  case home
  case agenda
  case savedViews
  case approvals
  case files
  case canvases
  case search
  case meetings
  case sources
  /// Raw value kept for persisted state and accessibility identifiers.
  case aiChat = "openClaw"
  case externalThreads
  case skills
  /// What is happening across the corpus: work needing you, live agent work,
  /// schedules, recent changes, and a zoomable map.
  case activity

  public var id: String { rawValue }

  /// Sidebar order. Saved Views and Canvases sit at the bottom of the
  /// Workspace section, below Review Queue and Automations.
  public static var sidebarCases: [WorkspaceSurface] {
    [.home, .activity, .agenda, .approvals, .meetings, .sources, .skills, .externalThreads, .savedViews]
  }

  /// Surfaces listed after the Agent Work pages (Review Queue, Automations).
  public static let sidebarTrailingCases: Set<WorkspaceSurface> = [.savedViews, .canvases]

  public static func sidebarCases(experimentalFeaturesEnabled: Bool) -> [WorkspaceSurface] {
    guard experimentalFeaturesEnabled else { return sidebarCases }
    return sidebarCases + [.canvases]
  }

  public var title: String {
    switch self {
    case .home: "Home"
    case .agenda: "Agenda"
    case .savedViews: "Saved Views"
    case .approvals: "Agent Work"
    case .files: "Files"
    case .canvases: "Canvases"
    case .search: "Search"
    case .meetings: "Meetings"
    case .sources: "Sources"
    case .aiChat: "AI Chat"
    case .externalThreads: "External Threads"
    case .skills: "Skills"
    case .activity: "Activity"
    }
  }

  public var systemImage: String {
    switch self {
    case .home: "house"
    case .agenda: "calendar"
    case .savedViews: "tablecells"
    case .approvals: "bolt.horizontal.circle"
    case .files: "doc.text"
    case .canvases: "rectangle.3.group"
    case .search: "magnifyingglass"
    case .meetings: "mic"
    case .sources: "arrow.triangle.2.circlepath.circle"
    case .aiChat: "sparkles"
    case .externalThreads: "rectangle.stack.badge.person.crop"
    case .skills: "wand.and.stars"
    case .activity: "map"
    }
  }

  public var commandShortcutTitle: String {
    switch self {
    case .home: "⌘1"
    case .agenda: "⌘2"
    case .savedViews: "⌥⌘V"
    case .approvals: "⌘4"
    case .files: "⌘3"
    case .canvases: "⌥⌘C"
    case .search: "⌘⇧F"
    case .meetings: "⌘5/⌘M"
    case .sources: "⌘0"
    case .aiChat: "⌘6"
    case .externalThreads: "⌥⌘E"
    case .skills: "⌘⇧K"
    case .activity: "⌥⌘N"
    }
  }
}

public enum WorkspaceSearchMode: String, CaseIterable, Identifiable, Sendable {
  case text
  case nodes

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .text: "Text"
    case .nodes: "Nodes"
    }
  }

  public var subtitle: String {
    switch self {
    case .text: "Workspace search"
    case .nodes: "Node title, alias, ID, and path search"
    }
  }

  public var placeholder: String {
    switch self {
    case .text: "Search workspace"
    case .nodes: "Search nodes by title, alias, ID, or path"
    }
  }

  public var helpText: String {
    switch self {
    case .text:
      "Search TODOs, files, chats, approvals, runs, workflows, goals, agents, pages, entries, and corpus text."
    case .nodes:
      "Live search over the local node index, including titles, aliases, IDs, and file paths."
    }
  }
}

public enum NodeContextTab: String, CaseIterable, Identifiable, Sendable {
  case overview
  case references
  case related
  case connections
  case brief

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .overview: "Overview"
    case .references: "References"
    case .related: "Related"
    case .connections: "Graph"
    case .brief: "Brief"
    }
  }
}

public struct BacklinkFileGroup: Identifiable, Hashable, Sendable {
  public let file: String
  public let relativePath: String
  public let backlinks: [BacklinkItem]

  public init(file: String, relativePath: String, backlinks: [BacklinkItem]) {
    self.file = file
    self.relativePath = relativePath
    self.backlinks = backlinks
  }

  public var id: String { file }
  public var count: Int { backlinks.count }
  public var displayTitle: String {
    URL(fileURLWithPath: relativePath).lastPathComponent
  }
}

public struct RelatedBacklinkNode: Identifiable, Hashable, Sendable {
  public let id: String
  public let idValue: String?
  public let title: String
  public let referenceCount: Int
  public let fileCount: Int
  public let primaryPath: String
  public let examples: [String]

  public init(
    id: String,
    idValue: String?,
    title: String,
    referenceCount: Int,
    fileCount: Int,
    primaryPath: String,
    examples: [String]
  ) {
    self.id = id
    self.idValue = idValue
    self.title = title
    self.referenceCount = referenceCount
    self.fileCount = fileCount
    self.primaryPath = primaryPath
    self.examples = examples
  }
}

public struct NodeBriefArtifact: Identifiable, Hashable, Sendable {
  public var id: String { relativePath }
  public let relativePath: String
  public let file: String
  public let title: String
  public let body: String
  public let modifiedAt: Date?

  public init(relativePath: String, file: String, title: String, body: String, modifiedAt: Date?) {
    self.relativePath = relativePath
    self.file = file
    self.title = title
    self.body = body
    self.modifiedAt = modifiedAt
  }
}
