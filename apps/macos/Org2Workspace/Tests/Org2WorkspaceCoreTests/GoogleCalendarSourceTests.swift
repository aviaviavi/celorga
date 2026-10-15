import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Google Calendar as a source synced by the connected server: credential
/// hand-off, synced events, recording prompts, and meeting attendees.
@MainActor
final class GoogleCalendarSourceTests: XCTestCase {
  private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  // MARK: Credential stores

  func testFileCredentialStoreKeepsSecretsPrivateAndListsOnlyProfileIDs() throws {
    let directory = try temporaryDirectory("source-credentials")
    let file = directory.appendingPathComponent("state/source-credentials-press.json")
    let store = SourceCredentialsFileStore(fileURL: file)
    XCTAssertFalse(store.containsCredential(profileID: "calendar"))

    try store.saveCredential("{\"refreshToken\":\"r1\"}", profileID: "calendar")
    try store.saveCredential("xoxb-1", profileID: "slack")
    XCTAssertEqual(store.credential(profileID: "calendar"), "{\"refreshToken\":\"r1\"}")
    XCTAssertEqual(store.storedProfileIDs(), ["calendar", "slack"])
    let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
    XCTAssertEqual(mode.intValue & 0o077, 0, "only the owner can read the credential file")

    // A second instance (a server restart) reads the same credentials.
    let reopened = SourceCredentialsFileStore(fileURL: file)
    XCTAssertEqual(reopened.credential(profileID: "slack"), "xoxb-1")
    try reopened.deleteCredential(profileID: "slack")
    XCTAssertNil(reopened.credential(profileID: "slack"))
    XCTAssertEqual(reopened.storedProfileIDs(), ["calendar"])

    XCTAssertThrowsError(try store.saveCredential("x", profileID: "../escape"))
    XCTAssertThrowsError(try store.saveCredential("", profileID: "calendar"))
  }

  func testServerAcceptsListsAndDeletesSourceCredentialsWithoutEchoingThem() async throws {
    let root = try temporaryDirectory("source-credential-relay")
    let suiteName = "source-credential-relay-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = try WorkspaceStore(
      cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()),
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    let credentials = SourceCredentialsFileStore(fileURL: root.appendingPathComponent("server/source-credentials.json"))
    store.sourceCredentialStore = credentials
    let coordinator = MobileRemoteCoordinator(defaults: defaults, credentialFile: root.appendingPathComponent("devices.json"))

    let body = try MobileRemoteProtocol.encoder().encode(MobileRemoteSourceCredentialRequest(credential: "{\"refreshToken\":\"secret-refresh\"}"))
    let stored = await coordinator.handleSourceRequest(
      MobileRemoteHTTPRequest(method: "PUT", path: "/v1/sources/calendar/credential", body: body),
      path: "/v1/sources/calendar/credential",
      store: store
    )
    XCTAssertEqual(stored?.statusCode, 200)
    XCTAssertFalse(String(decoding: stored?.body ?? Data(), as: UTF8.self).contains("secret-refresh"))
    XCTAssertEqual(credentials.credential(profileID: "calendar"), "{\"refreshToken\":\"secret-refresh\"}")

    let list = await coordinator.handleSourceRequest(
      MobileRemoteHTTPRequest(method: "GET", path: "/v1/sources/credentials"),
      path: "/v1/sources/credentials",
      store: store
    )
    let listed = try MobileRemoteProtocol.decoder().decode(MobileRemoteSourceCredentialList.self, from: try XCTUnwrap(list?.body))
    XCTAssertEqual(listed.profileIDs, ["calendar"])
    XCTAssertFalse(String(decoding: list?.body ?? Data(), as: UTF8.self).contains("secret-refresh"))

    let rejected = await coordinator.handleSourceRequest(
      MobileRemoteHTTPRequest(method: "PUT", path: "/v1/sources/calendar/credential", body: Data("{}".utf8)),
      path: "/v1/sources/calendar/credential",
      store: store
    )
    XCTAssertEqual(rejected?.statusCode, 400)
    let invalidID = await coordinator.handleSourceRequest(
      MobileRemoteHTTPRequest(method: "PUT", path: "/v1/sources/..%2Fx/credential", body: body),
      path: "/v1/sources/..%2Fx/credential",
      store: store
    )
    XCTAssertNil(invalidID, "invalid profile IDs fall through to not found")

    let deleted = await coordinator.handleSourceRequest(
      MobileRemoteHTTPRequest(method: "DELETE", path: "/v1/sources/calendar/credential"),
      path: "/v1/sources/calendar/credential",
      store: store
    )
    XCTAssertEqual(deleted?.statusCode, 200)
    XCTAssertNil(credentials.credential(profileID: "calendar"))
  }

  func testMacSendsCredentialsAndRunNowToThePairedServer() async throws {
    let deviceID = UUID()
    final class Box: @unchecked Sendable { var bodies: [String: Data] = [:]; let lock = NSLock() }
    let box = Box()
    let connection = OpenOrgServerConnection(
      defaults: try XCTUnwrap(UserDefaults(suiteName: "source-credential-client-\(UUID().uuidString)")),
      credentials: OpenOrgServerMemoryCredentials(),
      transport: { request in
        box.lock.withLock { box.bodies["\(request.method) \(request.path)"] = request.body ?? Data() }
        let value: Encodable
        switch (request.method, request.path) {
        case ("POST", "/v1/pair"):
          value = MobileRemotePairResponse(serverName: "press", deviceID: deviceID, accessToken: "device-token")
        case ("GET", "/v1/status"):
          value = MobileRemoteServerStatus(serverName: "press", hostRef: "press", hostKind: "server", corpusName: "avi.org2", threadCount: 0, runningThreadCount: 0)
        case ("PUT", "/v1/sources/calendar/credential"):
          value = MobileRemoteSourceCredentialResponse(profileID: "calendar", stored: true)
        case ("POST", "/v1/sources/calendar/sync"):
          value = MobileRemoteSourceSyncResponse(profileID: "calendar", ok: true, message: "Staged 4 records in 1 review packets.")
        default:
          return OpenOrgServerHTTPResponse(statusCode: 404, body: try MobileRemoteProtocol.encoder().encode(MobileRemoteErrorEnvelope(error: "Not found.")))
        }
        return OpenOrgServerHTTPResponse(statusCode: 200, body: try MobileRemoteProtocol.encoder().encode(value))
      }
    )
    try await connection.pair(endpointText: "100.64.0.9", code: "123456", deviceName: "AiroPress")
    XCTAssertEqual(connection.supportsSourceCredentials, true)
    try await connection.uploadSourceCredential(profileID: "calendar", credential: "{\"refreshToken\":\"r\"}")
    let sent = try MobileRemoteProtocol.decoder().decode(
      MobileRemoteSourceCredentialRequest.self,
      from: try XCTUnwrap(box.lock.withLock { box.bodies["PUT /v1/sources/calendar/credential"] })
    )
    XCTAssertEqual(sent.credential, "{\"refreshToken\":\"r\"}")
    let sync = try await connection.syncSource(profileID: "calendar")
    XCTAssertEqual(sync.message, "Staged 4 records in 1 review packets.")
  }

  func testOlderServersWithoutSourceSupportAreReportedBeforeSending() async throws {
    let deviceID = UUID()
    let connection = OpenOrgServerConnection(
      defaults: try XCTUnwrap(UserDefaults(suiteName: "source-credential-old-\(UUID().uuidString)")),
      credentials: OpenOrgServerMemoryCredentials(),
      transport: { request in
        let value: Encodable = request.path == "/v1/pair"
          ? MobileRemotePairResponse(serverName: "old", deviceID: deviceID, accessToken: "t")
          : MobileRemoteServerStatus(serverName: "old", corpusName: nil, threadCount: 0, runningThreadCount: 0, supportsSourceCredentials: nil)
        return OpenOrgServerHTTPResponse(statusCode: 200, body: try MobileRemoteProtocol.encoder().encode(value))
      }
    )
    try await connection.pair(endpointText: "100.64.0.9", code: "123456", deviceName: "AiroPress")
    do {
      try await connection.uploadSourceCredential(profileID: "calendar", credential: "x")
      XCTFail("an older server cannot accept source credentials")
    } catch let error as OpenOrgServerError {
      XCTAssertEqual(error, .sourcesUnsupported)
    }
  }

  // MARK: Catalog

  func testGoogleCalendarCatalogEntryUsesSignInAndWritesItsSettings() throws {
    let type = try XCTUnwrap(WorkspaceSourceCatalog.type("google-calendar"))
    XCTAssertEqual(type.secret?.signIn, .google(scope: "https://www.googleapis.com/auth/calendar.events.readonly"))
    XCTAssertEqual(type.secret?.environmentVariable, "ORG2_GOOGLE_CALENDAR_CREDENTIAL")
    var draft = WorkspaceSourceDraft(type: type)
    draft.setValue("primary, team@example.com", for: "calendars")
    draft.setValue("7", for: "lookaheadDays")
    let config = try draft.sourceConfig()
    XCTAssertEqual(config["type"]?.stringValue, "google-calendar")
    XCTAssertEqual(config["googleCalendar"]?["calendars"]?.arrayValue?.compactMap(\.stringValue), ["primary", "team@example.com"])
    XCTAssertEqual(config["googleCalendar"]?["lookaheadDays"], .integer(7))
    XCTAssertEqual(config["ingestion"]?["since"]?.stringValue, "1d")
    XCTAssertTrue(type.agentSetupPrompt.contains("Sign in with Google"))

    // Editing with a cleared optional field omits it rather than sending null.
    let status = WorkspaceSourceProfileStatus(
      id: "calendar", type: "google-calendar", enabled: true, scopes: [], rawZone: "raw/connectors/google-calendar/calendar",
      reviewZone: "views/connectors/google-calendar/calendar", ingestionSince: "1d", ingestionLimit: 5000, syncArgs: [],
      media: "metadata-only", binary: "celorga", binaryAvailable: true, configAvailable: true, ready: true,
      googleCalendar: WorkspaceGoogleCalendarSourceSummary(calendars: ["primary"], lookaheadDays: 14)
    )
    var editing = try XCTUnwrap(WorkspaceSourceDraft(editing: status))
    XCTAssertEqual(editing.value("calendars"), "primary")
    XCTAssertEqual(editing.value("lookaheadDays"), "14")
    editing.setValue("", for: "calendars")
    let edited = try editing.sourceConfig()
    XCTAssertNil(edited["googleCalendar"]?["calendars"])
    XCTAssertEqual(edited["googleCalendar"]?["lookaheadDays"], .integer(14))
  }

  // MARK: Synced events and prompts

  private func rawPacket(_ payloads: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "schema": "org2:source-import:v1",
      "profile": "calendar",
      "sourceType": "google-calendar",
      "records": payloads.map { ["id": "x", "rawPayload": $0] },
    ])
  }

  func testSyncedEventsLoadFromTheSourceRawZone() throws {
    let corpus = try temporaryDirectory("calendar-corpus")
    let zone = corpus.appendingPathComponent("raw/connectors/google-calendar/calendar", isDirectory: true)
    try FileManager.default.createDirectory(at: zone, withIntermediateDirectories: true)
    try rawPacket([[
      "schema": "org2:calendar-event:v1",
      "calendarId": "primary",
      "eventId": "standup",
      "title": "Standup",
      "start": "2026-10-15T17:00:00.000Z",
      "end": "2026-10-15T17:15:00.000Z",
      "allDay": false,
      "status": "confirmed",
      "meetingUrl": "https://meet.google.com/abc",
      "attendees": [
        ["email": "avi@example.com", "self": true, "response": "accepted"],
        ["email": "ada@example.com", "name": "Ada Lovelace", "organizer": true],
      ],
    ]]).write(to: zone.appendingPathComponent("primary--2026-10.json"))
    try Data("not json".utf8).write(to: zone.appendingPathComponent("broken.json"))

    let events = CalendarMeetingEventLoader.load(corpusRoot: corpus)
    XCTAssertEqual(events.count, 1)
    let event = try XCTUnwrap(events.first)
    XCTAssertEqual(event.title, "Standup")
    XCTAssertEqual(event.sourceProfileID, "calendar")
    XCTAssertEqual(event.start, ISO8601DateFormatter().date(from: "2026-10-15T17:00:00Z"))
    XCTAssertEqual(event.otherAttendees.map(\.displayName), ["Ada Lovelace"])
  }

  func testPromptOffersEachRecordableMeetingOnceAroundItsStart() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let ada = CalendarMeetingAttendee(email: "ada@example.com", name: "Ada")
    let me = CalendarMeetingAttendee(email: "avi@example.com", isSelf: true)
    let meeting = CalendarMeetingEvent(calendarId: "primary", eventId: "m", title: "1:1", start: start, end: start + 1800, attendees: [me, ada])
    let solo = CalendarMeetingEvent(calendarId: "primary", eventId: "focus", title: "Focus", start: start, end: start + 3600, attendees: [me])
    let declined = CalendarMeetingEvent(calendarId: "primary", eventId: "d", title: "Declined", start: start, end: start + 1800, selfResponse: "declined", attendees: [me, ada])
    let allDay = CalendarMeetingEvent(calendarId: "primary", eventId: "a", title: "Offsite", start: start, end: start + 86_400, allDay: true, attendees: [me, ada])
    let events = [solo, declined, allDay, meeting]

    XCTAssertNil(CalendarRecordingPromptPolicy.candidate(in: events, now: start - 120, alreadyPrompted: []), "not yet")
    XCTAssertEqual(CalendarRecordingPromptPolicy.candidate(in: events, now: start - 30, alreadyPrompted: [])?.eventId, "m")
    XCTAssertEqual(CalendarRecordingPromptPolicy.candidate(in: events, now: start + 300, alreadyPrompted: [])?.eventId, "m")
    XCTAssertNil(CalendarRecordingPromptPolicy.candidate(in: events, now: start + 11 * 60, alreadyPrompted: []), "too late to offer")
    XCTAssertNil(CalendarRecordingPromptPolicy.candidate(in: events, now: start, alreadyPrompted: [meeting.promptKey]), "offered once")

    var moved = meeting
    moved.start = start + 3600
    moved.end = start + 5400
    XCTAssertNotEqual(moved.promptKey, meeting.promptKey, "a rescheduled meeting is offered again")

    XCTAssertEqual(CalendarRecordingPromptPolicy.currentMeeting(in: events, now: start + 20 * 60)?.eventId, "m")
    XCTAssertNil(CalendarRecordingPromptPolicy.currentMeeting(in: events, now: start + 31 * 60))
    let videoOnly = CalendarMeetingEvent(calendarId: "primary", eventId: "v", title: "Call", start: start, end: start + 600, meetingUrl: "https://zoom.us/j/1", attendees: [])
    XCTAssertTrue(CalendarRecordingPromptPolicy.isRecordable(videoOnly))
  }

  // MARK: Meeting notes

  func testAttendeesLinkToUniquePersonNotesAndAppearInTheMeetingNote() throws {
    let resolver = OrgRoamLinkResolver(nodes: [
      OrgRoamNodeReference(idValue: "ada-id", title: "Ada Lovelace", aliases: ["ada@example.com"], file: "/c/ada.org", line: 1, isPageNode: true),
      OrgRoamNodeReference(idValue: "bo-1", title: "Bo", file: "/c/bo1.org", line: 1, isPageNode: true),
      OrgRoamNodeReference(idValue: "bo-2", title: "Bo", file: "/c/bo2.org", line: 1, isPageNode: true),
    ])
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let event = CalendarMeetingEvent(
      calendarId: "primary",
      eventId: "evt-1",
      title: "Design review",
      start: start,
      end: start + 1800,
      htmlLink: "https://calendar.google.com/event?eid=1",
      meetingUrl: "https://meet.google.com/abc",
      attendees: [
        CalendarMeetingAttendee(email: "avi@example.com", isSelf: true),
        CalendarMeetingAttendee(email: "bo@example.com", name: "Bo", optional: true),
        CalendarMeetingAttendee(email: "ada@example.com", organizer: true),
        CalendarMeetingAttendee(email: "cy@example.com", response: "declined"),
      ],
      sourceProfileID: "calendar"
    )
    let attendees = MeetingAttendeeResolver.attendees(for: event, resolver: resolver)
    XCTAssertEqual(attendees.map(\.orgListItem), [
      "- [[id:ada-id][Ada Lovelace]] <ada@example.com> (organizer)",
      "- Bo <bo@example.com> (optional)",
      "- cy@example.com (declined)",
    ])

    let corpus = try temporaryDirectory("calendar-meeting-note")
    var paths = try MeetingArtifactWriter.preparePaths(corpusRoot: corpus, title: event.title, recordedAt: start)
    let plain = MeetingArtifactWriter.buildMeetingNote(
      paths: paths,
      corpusRoot: corpus,
      duration: 60,
      transcript: MeetingTranscriptResult(text: "", status: .unavailable, engine: "none")
    )
    XCTAssertFalse(plain.contains("calendar_event_id"))
    XCTAssertFalse(plain.contains("** Attendees"))

    paths.calendar = MeetingCalendarContext(event: event, attendees: attendees)
    let note = MeetingArtifactWriter.buildMeetingNote(
      paths: paths,
      corpusRoot: corpus,
      duration: 60,
      transcript: MeetingTranscriptResult(text: "", status: .unavailable, engine: "none")
    )
    XCTAssertTrue(note.contains(":calendar_event_id: evt-1\n"))
    XCTAssertTrue(note.contains(":calendar_source: calendar\n"))
    XCTAssertTrue(note.contains(":scheduled_start: \(MeetingArtifactWriter.isoTimestamp(start))\n"))
    XCTAssertTrue(note.contains(":meeting_url: https://meet.google.com/abc\n"))
    XCTAssertTrue(note.contains(":ATTENDEES: Ada Lovelace, Bo, cy@example.com\n"))
    XCTAssertTrue(note.contains(":END:\n\n** Attendees\n- [[id:ada-id][Ada Lovelace]] <ada@example.com> (organizer)\n"))
    XCTAssertTrue(note.contains("(declined)\n\n** Summary"))
    XCTAssertFalse(note.contains("avi@example.com"), "the signed-in account is not listed as an attendee")
  }

  func testGoogleSourceCredentialRoundTripsWithoutAccessTokens() throws {
    let credential = GoogleDriveOAuthCredential(
      clientID: "client.apps.googleusercontent.com",
      clientSecret: "shh",
      accessToken: "short-lived",
      refreshToken: "refresh",
      expirationDate: Date(),
      scope: WorkspaceSourceCatalog.googleCalendarScope
    )
    let encoded = try GoogleSourceOAuthCredential(credential).encodedString()
    XCTAssertFalse(encoded.contains("short-lived"))
    let decoded = try XCTUnwrap(GoogleSourceOAuthCredential.decode(encoded))
    XCTAssertEqual(decoded.schema, "org2:google-oauth-credential:v1")
    XCTAssertEqual(decoded.clientId, "client.apps.googleusercontent.com")
    XCTAssertEqual(decoded.refreshToken, "refresh")
    XCTAssertTrue(GoogleDriveOAuthClient.grants(WorkspaceSourceCatalog.googleCalendarScope, in: "openid \(WorkspaceSourceCatalog.googleCalendarScope)"))
    XCTAssertFalse(GoogleDriveOAuthClient.grants(WorkspaceSourceCatalog.googleCalendarScope, in: GoogleDriveOAuthClient.driveFileScope))
  }
}
