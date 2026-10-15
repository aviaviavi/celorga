import Foundation

public struct WorkspaceSourceSchedule: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case interval
    case daily
  }

  public var enabled: Bool
  public var kind: Kind
  public var everyMinutes: Int?
  public var time: String?
  public var timezone: String

  public var fingerprint: String {
    [enabled ? "1" : "0", kind.rawValue, everyMinutes.map(String.init) ?? "", time ?? "", timezone]
      .joined(separator: "|")
  }

  public var summary: String {
    guard enabled else { return "Off" }
    switch kind {
    case .interval:
      let minutes = everyMinutes ?? 0
      if minutes.isMultiple(of: 60) {
        let hours = minutes / 60
        return "Every \(hours) hour\(hours == 1 ? "" : "s")"
      }
      return "Every \(minutes) minute\(minutes == 1 ? "" : "s")"
    case .daily:
      return "Daily at \(time ?? "00:00") · \(timezone == "local" ? "local time" : timezone)"
    }
  }
}

public enum WorkspaceSourceIntervalUnit: String, CaseIterable, Identifiable, Sendable {
  case minutes
  case hours

  public var id: String { rawValue }
  public var multiplier: Int { self == .hours ? 60 : 1 }
}

public struct WorkspaceSourceScheduleDraft: Equatable, Sendable {
  public var kind: WorkspaceSourceSchedule.Kind
  public var intervalValue: Int
  public var intervalUnit: WorkspaceSourceIntervalUnit
  public var dailyTime: Date
  public var timezone: String

  public init(
    schedule: WorkspaceSourceSchedule?,
    now: Date = Date(),
    calendar: Calendar = .current
  ) {
    kind = schedule?.kind ?? .interval
    let minutes = max(1, schedule?.everyMinutes ?? 120)
    if minutes.isMultiple(of: 60) {
      intervalValue = minutes / 60
      intervalUnit = .hours
    } else {
      intervalValue = minutes
      intervalUnit = .minutes
    }
    let parts = (schedule?.time ?? "02:00").split(separator: ":")
    let hour = parts.first.flatMap { Int($0) } ?? 2
    let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    dailyTime = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    timezone = schedule?.timezone ?? "local"
  }

  public func schedule(enabled: Bool, calendar: Calendar = .current) throws -> WorkspaceSourceSchedule {
    let normalizedTimezone = timezone.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedTimezone == "local" || TimeZone(identifier: normalizedTimezone) != nil else {
      throw ValidationError("Choose Local time or a valid time zone.")
    }
    switch kind {
    case .interval:
      guard intervalValue > 0 else {
        throw ValidationError("Sync frequency must be greater than zero.")
      }
      let (minutes, overflow) = intervalValue.multipliedReportingOverflow(by: intervalUnit.multiplier)
      guard !overflow else { throw ValidationError("Sync frequency is too large.") }
      return WorkspaceSourceSchedule(
        enabled: enabled,
        kind: .interval,
        everyMinutes: minutes,
        time: nil,
        timezone: normalizedTimezone
      )
    case .daily:
      let components = calendar.dateComponents([.hour, .minute], from: dailyTime)
      guard let hour = components.hour, let minute = components.minute else {
        throw ValidationError("Choose a valid daily sync time.")
      }
      return WorkspaceSourceSchedule(
        enabled: enabled,
        kind: .daily,
        everyMinutes: nil,
        time: String(format: "%02d:%02d", hour, minute),
        timezone: normalizedTimezone
      )
    }
  }

  public struct ValidationError: LocalizedError, Equatable {
    public var message: String

    public init(_ message: String) {
      self.message = message
    }

    public var errorDescription: String? { message }
  }
}

public struct WorkspaceSourceScheduleUpdateEnvelope: Codable, Equatable, Sendable {
  public var schema: String
  public var root: String
  public var configFile: String
  public var profile: String
  public var previous: WorkspaceSourceSchedule?
  public var schedule: WorkspaceSourceSchedule
  public var changed: Bool
  public var applied: Bool
}

public struct WorkspaceSourceProfileStatus: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var type: String
  public var enabled: Bool
  public var scopes: [String]
  public var workspaceId: String?
  public var rawZone: String
  public var reviewZone: String
  public var ingestionSince: String?
  public var ingestionLimit: Int
  public var syncArgs: [String]
  public var media: String
  public var schedule: WorkspaceSourceSchedule?
  public var binary: String
  public var binaryAvailable: Bool
  public var configPath: String?
  public var configAvailable: Bool
  public var ready: Bool
  /// Email profiles: the IMAP account summary.
  public var email: WorkspaceEmailSourceSummary?
  /// Google Calendar profiles: calendars and window.
  public var googleCalendar: WorkspaceGoogleCalendarSourceSummary?
  /// Email profiles: whether the CLI can find a password without OpenOrg's Keychain.
  public var credentialAvailable: Bool?
  public var setupError: String?

  /// Whether this source cannot sync without a secret OpenOrg keeps in Keychain.
  public var usesStoredCredential: Bool {
    sourceType?.requiresSecret(syncArgs: syncArgs) ?? false
  }

  /// `source list` supplies the same effective zones used by source ingestion.
  /// Reserve those directories so edits to imported documents still serialize
  /// with sync, without blocking unrelated notes during the crawler's network IO.
  func importResourcePaths(in corpusRoot: URL) -> [String] {
    let zones = [
      rawZone.isEmpty ? "raw/connectors/\(type)/\(id)" : rawZone,
      reviewZone.isEmpty ? "views/connectors/\(type)/\(id)" : reviewZone
    ]
    return zones.map { zone in
      let url = NSString(string: zone).isAbsolutePath
        ? URL(fileURLWithPath: zone)
        : corpusRoot.appendingPathComponent(zone)
      return url.standardizedFileURL.path
    }
  }
}

public struct WorkspaceGoogleCalendarSourceSummary: Codable, Equatable, Sendable {
  public var calendars: [String]
  public var lookaheadDays: Int
}

public struct WorkspaceEmailSourceSummary: Codable, Equatable, Sendable {
  public struct SMTP: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
  }
  public var host: String
  public var port: Int
  public var security: String
  public var username: String
  public var mailboxes: [String]
  public var smtp: SMTP?
}

public struct WorkspaceSourceScheduleState: Codable, Equatable, Sendable {
  public var scheduleFingerprint: String
  public var initializedAt: Date
  public var lastAttemptAt: Date?
  public var lastSuccessAt: Date?
  public var nextRunAt: Date?
  public var lastError: String?

  public init(
    scheduleFingerprint: String,
    initializedAt: Date,
    lastAttemptAt: Date? = nil,
    lastSuccessAt: Date? = nil,
    nextRunAt: Date? = nil,
    lastError: String? = nil
  ) {
    self.scheduleFingerprint = scheduleFingerprint
    self.initializedAt = initializedAt
    self.lastAttemptAt = lastAttemptAt
    self.lastSuccessAt = lastSuccessAt
    self.nextRunAt = nextRunAt
    self.lastError = lastError
  }
}

public enum WorkspaceSourceSchedulePlanner {
  public static func nextRun(
    after date: Date,
    schedule: WorkspaceSourceSchedule,
    localTimeZone: TimeZone = .current
  ) -> Date? {
    guard schedule.enabled else { return nil }
    switch schedule.kind {
    case .interval:
      guard let minutes = schedule.everyMinutes, minutes > 0 else { return nil }
      return date.addingTimeInterval(TimeInterval(minutes * 60))
    case .daily:
      guard let time = schedule.time else { return nil }
      let parts = time.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2,
            let hour = Int(parts[0]),
            let minute = Int(parts[1]),
            (0...23).contains(hour),
            (0...59).contains(minute)
      else { return nil }
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = schedule.timezone == "local"
        ? localTimeZone
        : (TimeZone(identifier: schedule.timezone) ?? localTimeZone)
      return calendar.nextDate(
        after: date,
        matching: DateComponents(hour: hour, minute: minute, second: 0),
        matchingPolicy: .nextTime,
        repeatedTimePolicy: .first,
        direction: .forward
      )
    }
  }

  public static func isDue(_ state: WorkspaceSourceScheduleState, at date: Date) -> Bool {
    guard let nextRunAt = state.nextRunAt else { return false }
    return nextRunAt <= date
  }
}

public final class WorkspaceSourceScheduleStateStore {
  public static let defaultPersistenceKey = "org2.workspace.source-schedule-state.v1"

  private let defaults: UserDefaults
  private let persistenceKey: String

  public init(
    defaults: UserDefaults = .standard,
    persistenceKey: String = WorkspaceSourceScheduleStateStore.defaultPersistenceKey
  ) {
    self.defaults = defaults
    self.persistenceKey = persistenceKey
  }

  public func state(corpusPath: String, profileID: String) -> WorkspaceSourceScheduleState? {
    envelope().entries[entryKey(corpusPath: corpusPath, profileID: profileID)]
  }

  public func setState(
    _ state: WorkspaceSourceScheduleState,
    corpusPath: String,
    profileID: String
  ) {
    var value = envelope()
    value.entries[entryKey(corpusPath: corpusPath, profileID: profileID)] = state
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: persistenceKey)
  }

  private func entryKey(corpusPath: String, profileID: String) -> String {
    "\(URL(fileURLWithPath: corpusPath).standardizedFileURL.path)\u{001F}\(profileID)"
  }

  private func envelope() -> PersistenceEnvelope {
    guard let data = defaults.data(forKey: persistenceKey),
          let value = try? JSONDecoder().decode(PersistenceEnvelope.self, from: data),
          value.schemaVersion == 1
    else { return PersistenceEnvelope(schemaVersion: 1, entries: [:]) }
    return value
  }

  private struct PersistenceEnvelope: Codable {
    var schemaVersion: Int
    var entries: [String: WorkspaceSourceScheduleState]
  }
}

public struct WorkspaceCrawlerCount: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var label: String
  public var value: Int
}

public struct WorkspaceCrawlerStatus: Codable, Equatable, Sendable {
  public var appId: String
  public var state: String
  public var summary: String
  public var databasePath: String?
  public var databaseBytes: UInt64
  public var lastSyncAt: String?
  public var counts: [WorkspaceCrawlerCount]

  private enum CodingKeys: String, CodingKey {
    case appId = "app_id"
    case state, summary
    case databasePath = "database_path"
    case databaseBytes = "database_bytes"
    case lastSyncAt = "last_sync_at"
    case counts
  }
}

public struct WorkspaceSourceRuntimeStatus: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var type: String?
  public var ok: Bool
  public var crawlerStatus: WorkspaceCrawlerStatus?
  public var error: String?
}

public struct WorkspaceSourceStatusEnvelope: Codable, Equatable, Sendable {
  public var schema: String
  public var root: String
  public var sources: [WorkspaceSourceRuntimeStatus]
}

public struct WorkspaceSourceImportSummary: Codable, Equatable, Sendable {
  public var apply: Bool
  public var since: String?
  public var inputCount: Int
  public var acceptedCount: Int
  public var skippedCount: Int
  public var groupCount: Int
  public var changedFileCount: Int
}

public struct WorkspaceSourceOperationResult: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var ok: Bool
  public var skipped: Bool?
  public var reason: String?
  public var message: String?
  public var recoveredStaleLock: Bool?
  public var imported: WorkspaceSourceImportSummary?
  public var error: String?

  public var isSyncInProgress: Bool {
    ok && skipped == true && reason == "sync-in-progress"
  }
}

public struct WorkspaceSourceOperationEnvelope: Codable, Equatable, Sendable {
  public var schema: String
  public var root: String
  public var applied: Bool?
  public var results: [WorkspaceSourceOperationResult]
}

public struct WorkspaceSourceNotice: Equatable, Sendable {
  public var text: String
  public var isError: Bool
}

public enum WorkspaceSourcePresentationState: Equatable, Sendable {
  case syncing
  case needsToken
  case needsSetup
  case needsAttention
  case configured

  public var title: String {
    switch self {
    case .syncing: "Syncing"
    case .needsToken: "Needs token"
    case .needsSetup: "Needs setup"
    case .needsAttention: "Needs attention"
    case .configured: "Configured"
    }
  }
}

public enum WorkspaceSourcePresentation {
  public static func notice(
    scheduleError: String?,
    operationMessage: String?,
    operationFailed: Bool
  ) -> WorkspaceSourceNotice? {
    if let operationMessage = normalized(operationMessage) {
      return WorkspaceSourceNotice(text: operationMessage, isError: operationFailed)
    }
    if let scheduleError = normalized(scheduleError) {
      return WorkspaceSourceNotice(text: scheduleError, isError: true)
    }
    return nil
  }

  public static func state(
    isRunning: Bool,
    needsToken: Bool,
    isReady: Bool,
    runtimeOK: Bool?,
    notice: WorkspaceSourceNotice?
  ) -> WorkspaceSourcePresentationState {
    if isRunning { return .syncing }
    if needsToken { return .needsToken }
    if !isReady { return .needsSetup }
    if runtimeOK == false || notice?.isError == true { return .needsAttention }
    return .configured
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// An extensible identifier for a source connector. Known kinds are conveniences rather than
/// an exhaustive enum so newer connector implementations can be persisted by older app builds.
public struct WorkspaceSourceKind: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let slack = WorkspaceSourceKind(rawValue: "slack")
  public static let notion = WorkspaceSourceKind(rawValue: "notion")
}

public enum WorkspaceSourceConnectionState: String, Codable, Sendable {
  case enabled
  case paused
}

/// Metadata used to locate credentials in a secure store. Secret material must never be placed
/// in a source connection record or its UserDefaults persistence envelope.
public struct WorkspaceCredentialReference: Codable, Equatable, Sendable {
  public var store: String
  public var service: String
  public var account: String

  public init(store: String = "keychain", service: String, account: String) {
    self.store = store
    self.service = service
    self.account = account
  }
}

public struct WorkspaceSourceActionableError: Codable, Equatable, Sendable {
  public var code: String
  public var message: String
  public var recoverySuggestion: String
  public var occurredAt: Date

  public init(code: String, message: String, recoverySuggestion: String, occurredAt: Date) {
    self.code = code
    self.message = message
    self.recoverySuggestion = recoverySuggestion
    self.occurredAt = occurredAt
  }
}

public struct WorkspaceSourceSyncStatus: Codable, Equatable, Sendable {
  public var lastCursor: String?
  public var lastSuccessAt: Date?
  public var nextRunAt: Date?
  public var bytesFetched: UInt64
  public var bytesStored: UInt64
  public var actionableError: WorkspaceSourceActionableError?

  public init(
    lastCursor: String? = nil,
    lastSuccessAt: Date? = nil,
    nextRunAt: Date? = nil,
    bytesFetched: UInt64 = 0,
    bytesStored: UInt64 = 0,
    actionableError: WorkspaceSourceActionableError? = nil
  ) {
    self.lastCursor = lastCursor
    self.lastSuccessAt = lastSuccessAt
    self.nextRunAt = nextRunAt
    self.bytesFetched = bytesFetched
    self.bytesStored = bytesStored
    self.actionableError = actionableError
  }
}

public struct WorkspaceSourceConnection: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var kind: WorkspaceSourceKind
  public var displayName: String
  public var state: WorkspaceSourceConnectionState
  public var scopes: [String]
  public var credentialReference: WorkspaceCredentialReference?
  public var syncStatus: WorkspaceSourceSyncStatus

  public init(
    id: UUID = UUID(),
    kind: WorkspaceSourceKind,
    displayName: String,
    state: WorkspaceSourceConnectionState = .enabled,
    scopes: [String] = [],
    credentialReference: WorkspaceCredentialReference? = nil,
    syncStatus: WorkspaceSourceSyncStatus = WorkspaceSourceSyncStatus()
  ) {
    self.id = id
    self.kind = kind
    self.displayName = displayName
    self.state = state
    self.scopes = scopes
    self.credentialReference = credentialReference
    self.syncStatus = syncStatus
  }
}

public enum WorkspaceExternalStorageAvailability: String, Codable, Sendable {
  case available
  case missingVolume
}

/// Persisted information for resolving a user-selected security-scoped directory. The bookmark
/// is intentionally opaque; resolving it and starting security-scoped access belongs to a later
/// app integration slice.
public struct WorkspaceExternalStorageRoot: Codable, Equatable, Sendable {
  public var bookmarkData: Data
  public var lastKnownPath: String
  public var volumeIdentifier: String?
  public var availability: WorkspaceExternalStorageAvailability

  public init(
    bookmarkData: Data,
    lastKnownPath: String,
    volumeIdentifier: String? = nil,
    availability: WorkspaceExternalStorageAvailability = .available
  ) {
    self.bookmarkData = bookmarkData
    self.lastKnownPath = lastKnownPath
    self.volumeIdentifier = volumeIdentifier
    self.availability = availability
  }
}

public enum WorkspaceSourceStorageRoot: Codable, Equatable, Sendable {
  case internalDefault
  case external(WorkspaceExternalStorageRoot)

  private enum CodingKeys: String, CodingKey { case kind, external }
  private enum Kind: String, Codable { case internalDefault, external }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .internalDefault:
      self = .internalDefault
    case .external:
      self = .external(try container.decode(WorkspaceExternalStorageRoot.self, forKey: .external))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .internalDefault:
      try container.encode(Kind.internalDefault, forKey: .kind)
    case .external(let root):
      try container.encode(Kind.external, forKey: .kind)
      try container.encode(root, forKey: .external)
    }
  }
}

public enum WorkspaceSourceRegistryError: Error, Equatable {
  case encodingFailed
}

/// Small durable registry for connector configuration and sync bookkeeping. It deliberately has
/// no scheduling, authentication, networking, bookmark resolution, or ingestion behavior.
public final class WorkspaceSourceConnectionRegistry {
  public static let defaultPersistenceKey = "org2.workspace.source-connections.v1"

  public private(set) var connections: [WorkspaceSourceConnection]
  public private(set) var storageRoot: WorkspaceSourceStorageRoot

  private let defaults: UserDefaults
  private let persistenceKey: String

  public init(
    defaults: UserDefaults = .standard,
    persistenceKey: String = WorkspaceSourceConnectionRegistry.defaultPersistenceKey
  ) {
    self.defaults = defaults
    self.persistenceKey = persistenceKey

    guard let data = defaults.data(forKey: persistenceKey),
          let envelope = try? JSONDecoder().decode(PersistenceEnvelope.self, from: data),
          envelope.schemaVersion == 1
    else {
      connections = []
      storageRoot = .internalDefault
      return
    }
    connections = envelope.connections
    storageRoot = envelope.storageRoot
  }

  public func upsert(_ connection: WorkspaceSourceConnection) throws {
    var updated = connections
    if let index = updated.firstIndex(where: { $0.id == connection.id }) {
      updated[index] = connection
    } else {
      updated.append(connection)
    }
    try persist(connections: updated, storageRoot: storageRoot)
    connections = updated
  }

  public func remove(id: UUID) throws {
    let updated = connections.filter { $0.id != id }
    try persist(connections: updated, storageRoot: storageRoot)
    connections = updated
  }

  public func setStorageRoot(_ root: WorkspaceSourceStorageRoot) throws {
    try persist(connections: connections, storageRoot: root)
    storageRoot = root
  }

  private func persist(
    connections: [WorkspaceSourceConnection],
    storageRoot: WorkspaceSourceStorageRoot
  ) throws {
    let envelope = PersistenceEnvelope(
      schemaVersion: 1,
      connections: connections,
      storageRoot: storageRoot
    )
    guard let data = try? JSONEncoder().encode(envelope) else {
      throw WorkspaceSourceRegistryError.encodingFailed
    }
    defaults.set(data, forKey: persistenceKey)
  }
}

private struct PersistenceEnvelope: Codable {
  var schemaVersion: Int
  var connections: [WorkspaceSourceConnection]
  var storageRoot: WorkspaceSourceStorageRoot
}
