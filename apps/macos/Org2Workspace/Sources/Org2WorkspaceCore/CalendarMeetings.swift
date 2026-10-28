import Foundation

// MARK: - Google sign-in credential for sources

/// The refresh credential a Google-backed source syncs with. The app stores it
/// (Keychain, plus the paired server's private store) and passes it to the
/// sync process as JSON in the source's environment variable.
public struct GoogleSourceOAuthCredential: Codable, Equatable, Sendable {
  public static let schema = "org2:google-oauth-credential:v1"

  public var schema: String
  public var clientId: String
  public var clientSecret: String?
  public var refreshToken: String
  public var scope: String
  public var signedInAt: String

  public init(clientId: String, clientSecret: String?, refreshToken: String, scope: String, signedInAt: Date = Date()) {
    schema = Self.schema
    self.clientId = clientId
    self.clientSecret = clientSecret
    self.refreshToken = refreshToken
    self.scope = scope
    self.signedInAt = ISO8601DateFormatter().string(from: signedInAt)
  }

  public init(_ credential: GoogleDriveOAuthCredential) {
    self.init(
      clientId: credential.clientID,
      clientSecret: credential.clientSecret,
      refreshToken: credential.refreshToken,
      scope: credential.scope
    )
  }

  public func encodedString() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }

  public static func decode(_ value: String) -> GoogleSourceOAuthCredential? {
    try? JSONDecoder().decode(Self.self, from: Data(value.utf8))
  }
}

// MARK: - Synced calendar events

public struct CalendarMeetingAttendee: Codable, Equatable, Hashable, Sendable {
  public var email: String?
  public var name: String?
  public var response: String?
  public var organizer: Bool?
  public var optional: Bool?
  public var isSelf: Bool?

  enum CodingKeys: String, CodingKey {
    case email, name, response, organizer, optional
    case isSelf = "self"
  }

  public init(email: String? = nil, name: String? = nil, response: String? = nil, organizer: Bool? = nil, optional: Bool? = nil, isSelf: Bool? = nil) {
    self.email = email
    self.name = name
    self.response = response
    self.organizer = organizer
    self.optional = optional
    self.isSelf = isSelf
  }

  public var displayName: String {
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedName.isEmpty { return trimmedName }
    return email ?? "Unknown attendee"
  }
}

/// One event from a synced Google Calendar source (`org2:calendar-event:v1`,
/// the `rawPayload` of each record the CLI stages under the source's raw zone).
public struct CalendarMeetingEvent: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var calendarId: String
  public var eventId: String
  public var title: String
  public var start: Date
  public var end: Date
  public var allDay: Bool
  public var status: String
  public var location: String?
  public var htmlLink: String?
  public var meetingUrl: String?
  public var organizer: CalendarMeetingAttendee?
  public var selfResponse: String?
  public var attendees: [CalendarMeetingAttendee]
  /// The `externalSources` profile the event was synced by.
  public var sourceProfileID: String
  /// The event description as plain text.
  public var details: String?
  public var recurringEventId: String?
  /// The staged raw-zone file the event was read from.
  public var sourceFile: String?

  public var id: String { "\(calendarId):\(eventId)" }
  /// Identifies one occurrence, so a moved meeting prompts again.
  public var promptKey: String { "\(id)@\(Int(start.timeIntervalSince1970))" }

  /// Everyone except the signed-in account.
  public var otherAttendees: [CalendarMeetingAttendee] {
    attendees.filter { $0.isSelf != true }
  }

  public init(
    calendarId: String,
    eventId: String,
    title: String,
    start: Date,
    end: Date,
    allDay: Bool = false,
    status: String = "confirmed",
    location: String? = nil,
    htmlLink: String? = nil,
    meetingUrl: String? = nil,
    organizer: CalendarMeetingAttendee? = nil,
    selfResponse: String? = nil,
    attendees: [CalendarMeetingAttendee] = [],
    sourceProfileID: String = "calendar",
    details: String? = nil,
    recurringEventId: String? = nil,
    sourceFile: String? = nil
  ) {
    self.calendarId = calendarId
    self.eventId = eventId
    self.title = title
    self.start = start
    self.end = end
    self.allDay = allDay
    self.status = status
    self.location = location
    self.htmlLink = htmlLink
    self.meetingUrl = meetingUrl
    self.organizer = organizer
    self.selfResponse = selfResponse
    self.attendees = attendees
    self.sourceProfileID = sourceProfileID
    self.details = details
    self.recurringEventId = recurringEventId
    self.sourceFile = sourceFile
  }
}

public enum CalendarMeetingEventLoader {
  public static let defaultRawRoot = "raw/connectors/google-calendar"

  private struct Envelope: Decodable {
    var profile: String?
    var sourceType: String?
    var records: [Record]
  }

  private struct Record: Decodable {
    var rawPayload: Payload?
  }

  private struct Payload: Decodable {
    var schema: String?
    var calendarId: String
    var eventId: String
    var title: String?
    var start: String
    var end: String
    var allDay: Bool?
    var status: String?
    var location: String?
    var htmlLink: String?
    var meetingUrl: String?
    var organizer: CalendarMeetingAttendee?
    var selfResponse: String?
    var attendees: [CalendarMeetingAttendee]?
    var description: String?
    var recurringEventId: String?
  }

  /// Raw zones to scan: the default location for every profile plus any
  /// configured zones. Missing directories are ignored.
  public static func load(corpusRoot: URL, extraRawZones: [String] = []) -> [CalendarMeetingEvent] {
    let fileManager = FileManager.default
    var directories: [URL] = []
    let defaultRoot = corpusRoot.appendingPathComponent(defaultRawRoot, isDirectory: true)
    if let profiles = try? fileManager.contentsOfDirectory(at: defaultRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
      directories.append(contentsOf: profiles)
    }
    for zone in extraRawZones {
      let url = NSString(string: zone).isAbsolutePath ? URL(fileURLWithPath: zone) : corpusRoot.appendingPathComponent(zone)
      directories.append(url)
    }
    var seenDirectories = Set<String>()
    var events: [String: CalendarMeetingEvent] = [:]
    for directory in directories {
      let standardized = directory.standardizedFileURL.path
      guard seenDirectories.insert(standardized).inserted,
            let files = try? fileManager.contentsOfDirectory(atPath: standardized)
      else { continue }
      for name in files.sorted() where name.hasSuffix(".json") {
        let path = (standardized as NSString).appendingPathComponent(name)
        guard let data = fileManager.contents(atPath: path) else { continue }
        for var event in parse(data, fallbackProfileID: directory.lastPathComponent) {
          event.sourceFile = path
          events[event.id] = event
        }
      }
    }
    return events.values.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
  }

  public static func parse(_ data: Data, fallbackProfileID: String) -> [CalendarMeetingEvent] {
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
          envelope.sourceType == nil || envelope.sourceType == "google-calendar"
    else { return [] }
    let profileID = envelope.profile ?? fallbackProfileID
    return envelope.records.compactMap { record in
      guard let payload = record.rawPayload,
            payload.schema.map({ CelorgaNames.schemaMatches($0, "org2:calendar-event:v1") }) ?? true,
            let start = date(payload.start),
            let end = date(payload.end)
      else { return nil }
      return CalendarMeetingEvent(
        calendarId: payload.calendarId,
        eventId: payload.eventId,
        title: payload.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(no title)",
        start: start,
        end: end,
        allDay: payload.allDay ?? false,
        status: payload.status ?? "confirmed",
        location: payload.location,
        htmlLink: payload.htmlLink,
        meetingUrl: payload.meetingUrl,
        organizer: payload.organizer,
        selfResponse: payload.selfResponse,
        attendees: payload.attendees ?? [],
        sourceProfileID: profileID,
        details: payload.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
        recurringEventId: payload.recurringEventId
      )
    }
  }

  static func date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
  }
}

// MARK: - Recording prompts

public enum CalendarRecordingPromptPolicy {
  /// Prompt this long before a meeting starts.
  public static let leadTime: TimeInterval = 60
  /// Keep offering a meeting that has already started for this long.
  public static let lateWindow: TimeInterval = 10 * 60

  /// Whether this event looks like a meeting worth offering to record:
  /// timed, not cancelled or declined, and with someone else or a call link.
  public static func isRecordable(_ event: CalendarMeetingEvent) -> Bool {
    guard !event.allDay,
          event.status != "cancelled",
          event.selfResponse != "declined",
          event.end > event.start
    else { return false }
    return !event.otherAttendees.isEmpty || event.meetingUrl != nil
  }

  public static func isInPromptWindow(_ event: CalendarMeetingEvent, now: Date) -> Bool {
    now >= event.start.addingTimeInterval(-leadTime)
      && now <= event.start.addingTimeInterval(lateWindow)
      && now < event.end
  }

  /// The meeting to offer now, if any: the most recently started (or next
  /// starting) recordable event in its window that was not offered before.
  public static func candidate(
    in events: [CalendarMeetingEvent],
    now: Date,
    alreadyPrompted: Set<String>
  ) -> CalendarMeetingEvent? {
    events
      .filter { isRecordable($0) && isInPromptWindow($0, now: now) && !alreadyPrompted.contains($0.promptKey) }
      .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
  }

  /// The meeting a manual recording most likely belongs to: one in progress,
  /// or starting within five minutes.
  public static func currentMeeting(in events: [CalendarMeetingEvent], now: Date) -> CalendarMeetingEvent? {
    events
      .filter { isRecordable($0) && $0.start.addingTimeInterval(-5 * 60) <= now && now < $0.end }
      .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
  }
}

// MARK: - Meeting note metadata

/// One attendee as it appears in a meeting note, linked to a person note
/// when exactly one node matches the attendee's name or email.
public struct MeetingNoteAttendee: Equatable, Sendable {
  public var label: String
  public var email: String?
  public var linkTarget: String?
  public var notes: [String]

  public init(label: String, email: String? = nil, linkTarget: String? = nil, notes: [String] = []) {
    self.label = label
    self.email = email
    self.linkTarget = linkTarget
    self.notes = notes
  }

  public var orgListItem: String {
    let sanitizedLabel = label.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(")
    var text = linkTarget.map { "[[\($0)][\(sanitizedLabel)]]" } ?? sanitizedLabel
    if let email, linkTarget == nil || label.caseInsensitiveCompare(email) != .orderedSame {
      if email.caseInsensitiveCompare(label) != .orderedSame { text += " <\(email)>" }
    }
    if !notes.isEmpty { text += " (\(notes.joined(separator: ", ")))" }
    return "- \(text)"
  }
}

/// Calendar metadata recorded with a meeting started from (or during) a
/// synced calendar event.
public struct MeetingCalendarContext: Equatable, Sendable {
  public var event: CalendarMeetingEvent
  public var attendees: [MeetingNoteAttendee]

  public init(event: CalendarMeetingEvent, attendees: [MeetingNoteAttendee]? = nil) {
    self.event = event
    self.attendees = attendees ?? MeetingAttendeeResolver.attendees(for: event, resolver: .empty)
  }
}

public enum MeetingAttendeeResolver {
  /// Everyone invited except the signed-in account, organizer first, each
  /// linked to a person note when the corpus has exactly one match.
  public static func attendees(for event: CalendarMeetingEvent, resolver: OrgRoamLinkResolver) -> [MeetingNoteAttendee] {
    var people = event.otherAttendees
    if people.isEmpty, let organizer = event.organizer, organizer.isSelf != true {
      people = [CalendarMeetingAttendee(email: organizer.email, name: organizer.name, organizer: true)]
    }
    let ordered = people.enumerated().sorted { left, right in
      let leftRank = left.element.organizer == true ? 0 : 1
      let rightRank = right.element.organizer == true ? 0 : 1
      return (leftRank, left.offset) < (rightRank, right.offset)
    }.map(\.element)
    return ordered.map { attendee in
      var notes: [String] = []
      if attendee.organizer == true { notes.append("organizer") }
      if attendee.optional == true { notes.append("optional") }
      if attendee.response == "declined" { notes.append("declined") }
      let node = personNode(for: attendee, resolver: resolver)
      let label = node?.title.nilIfEmpty ?? attendee.displayName
      return MeetingNoteAttendee(
        label: label,
        email: attendee.email,
        linkTarget: node.flatMap { resolver.uniqueIDLinkTarget(for: $0) ?? $0.idValue.map { "id:\($0)" } },
        notes: notes
      )
    }
  }

  static func personNode(for attendee: CalendarMeetingAttendee, resolver: OrgRoamLinkResolver) -> OrgRoamNodeReference? {
    let keys = [attendee.name, attendee.email].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    for key in keys {
      let candidates = resolver.exactCandidates(for: key).filter { $0.idValue != nil }
      let unique = Dictionary(grouping: candidates, by: { $0.idValue!.lowercased() })
      if unique.count == 1 { return candidates.first(where: \.isPageNode) ?? candidates.first }
    }
    return nil
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
