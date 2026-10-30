import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// The Calendar surface: visible ranges, overlap layout, all-day dates,
/// agenda TODO projection, linked notes, and the store's agenda read.
@MainActor
final class WorkspaceCalendarTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.firstWeekday = 1
    return calendar
  }

  private func day(_ key: String) -> Date {
    WorkspaceCalendarDates.date(fromKey: key, calendar: calendar)!
  }

  private func instant(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  private func item(
    _ headline: String,
    todo: String? = "TODO",
    kind: String = "SCHEDULED",
    line: Int,
    priority: String? = nil,
    time: String? = nil,
    effort: String? = nil,
    warning: Bool = false
  ) throws -> AgendaItem {
    var json: [String: Any] = [
      "headline": headline,
      "kind": kind,
      "file": "/corpus/tasks.org",
      "line": line,
      "tags": [],
      "properties": [:],
    ]
    if let todo { json["todo"] = todo }
    if let priority { json["priority"] = priority }
    if let time { json["time"] = time }
    if let effort { json["effort"] = effort }
    if warning { json["deadlineWarning"] = ["due": "2026-11-02", "daysUntil": 5] }
    return try JSONDecoder().decode(AgendaItem.self, from: JSONSerialization.data(withJSONObject: json))
  }

  private func agendaDay(_ key: String, _ items: [AgendaItem]) -> AgendaDay {
    AgendaDay(date: key, weekday: "", items: items, groups: nil)
  }

  private func payload(overdue: [AgendaDay] = [], days: [AgendaDay]) -> AgendaPayload {
    AgendaPayload(
      schema: "org2:agenda:v1",
      range: AgendaRange(start: days.first?.date ?? "", end: days.last?.date ?? "", days: days.count),
      overdue: overdue,
      days: days,
      skippedFiles: 0,
      workload: nil,
      corpora: nil,
      issues: nil
    )
  }

  // MARK: Ranges

  func testScalesShowADayAWeekAndWholeWeeksOfAMonth() {
    let anchor = day("2026-10-28")
    XCTAssertEqual(WorkspaceCalendarLayout.visibleDays(scale: .day, anchor: anchor, calendar: calendar), [anchor])

    let week = WorkspaceCalendarLayout.visibleDays(scale: .week, anchor: anchor, calendar: calendar)
    XCTAssertEqual(week.map { WorkspaceCalendarDates.key(for: $0, calendar: calendar) }.first, "2026-10-25")
    XCTAssertEqual(week.count, 7)

    let month = WorkspaceCalendarLayout.visibleDays(scale: .month, anchor: anchor, calendar: calendar)
    XCTAssertEqual(month.count, 35, "October 2026 spans five Sunday-first weeks")
    XCTAssertEqual(WorkspaceCalendarDates.key(for: month.first!, calendar: calendar), "2026-09-27")
    XCTAssertEqual(WorkspaceCalendarDates.key(for: month.last!, calendar: calendar), "2026-10-31")

    let window = WorkspaceCalendarLayout.agendaWindow(for: anchor, calendar: calendar)
    XCTAssertEqual(window.from, "2026-09-27")
    XCTAssertEqual(window.to, "2026-10-31")

    let nextWeek = WorkspaceCalendarLayout.shift(anchor, scale: .week, by: 1, calendar: calendar)
    XCTAssertEqual(WorkspaceCalendarDates.key(for: nextWeek, calendar: calendar), "2026-11-04")
  }

  func testOverlappingBlocksShareColumnsOnlyWithinTheirCluster() {
    func entry(_ id: String) -> WorkspaceCalendarEntry {
      .event(CalendarMeetingEvent(calendarId: "primary", eventId: id, title: id, start: Date(), end: Date()))
    }
    let placed = WorkspaceCalendarLayout.placements([
      (entry("a"), 9 * 60, 10 * 60),
      (entry("b"), 9 * 60 + 30, 10 * 60 + 30),
      (entry("c"), 10 * 60 + 15, 11 * 60),
      (entry("d"), 13 * 60, 13 * 60 + 5),
    ])
    let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.entry.title, $0) })
    XCTAssertEqual(byID["a"]?.column, 0)
    XCTAssertEqual(byID["b"]?.column, 1)
    XCTAssertEqual(byID["a"]?.columnCount, 2)
    XCTAssertEqual(byID["c"]?.column, 0, "c starts when a has ended, so it reuses a's column")
    XCTAssertEqual(byID["c"]?.columnCount, 2, "c overlaps b, so it stays in the same cluster")
    XCTAssertEqual(byID["d"]?.columnCount, 1)
    XCTAssertEqual(byID["d"]?.endMinute, 13 * 60 + WorkspaceCalendarLayout.minimumBlockMinutes, "short blocks stay tappable")
  }

  func testAllDayEventsKeepTheirDateInEveryTimeZone() {
    let offsite = CalendarMeetingEvent(
      calendarId: "primary",
      eventId: "offsite",
      title: "Offsite",
      start: instant("2026-10-28T00:00:00Z"),
      end: instant("2026-10-30T00:00:00Z"),
      allDay: true
    )
    let span = WorkspaceCalendarDates.allDaySpan(for: offsite, calendar: calendar)
    XCTAssertEqual(WorkspaceCalendarDates.key(for: span.start, calendar: calendar), "2026-10-28")
    XCTAssertEqual(WorkspaceCalendarDates.key(for: span.end, calendar: calendar), "2026-10-30")

    let days = WorkspaceCalendarLayout.days(
      [day("2026-10-27"), day("2026-10-28"), day("2026-10-29"), day("2026-10-30")],
      events: [offsite],
      tasks: [],
      calendar: calendar
    )
    XCTAssertEqual(days.map { $0.allDay.count }, [0, 1, 1, 0])
  }

  func testTimedEventsAreClippedToEachDayAndLongOnesMoveToAllDay() {
    let lateCall = CalendarMeetingEvent(
      calendarId: "primary",
      eventId: "late",
      title: "Late call",
      start: instant("2026-10-29T06:30:00Z"),  // 23:30 PDT on Oct 28
      end: instant("2026-10-29T07:30:00Z")
    )
    let conference = CalendarMeetingEvent(
      calendarId: "primary",
      eventId: "conf",
      title: "Conference",
      start: instant("2026-10-28T16:00:00Z"),
      end: instant("2026-10-30T01:00:00Z")
    )
    let days = WorkspaceCalendarLayout.days(
      [day("2026-10-28"), day("2026-10-29")],
      events: [lateCall, conference],
      tasks: [],
      calendar: calendar
    )
    XCTAssertEqual(days[0].timed.map(\.startMinute), [23 * 60 + 30])
    XCTAssertEqual(days[0].timed.first?.endMinute, 24 * 60)
    XCTAssertEqual(days[1].timed.map(\.startMinute), [0])
    XCTAssertEqual(days[0].allDay.map(\.title), ["Conference"])
    XCTAssertEqual(days[1].allDay.map(\.title), ["Conference"])
  }

  // MARK: TODOs

  func testOverdueRepeatsCollapseToOneRowPerHeadingAndWarningsAreDropped() throws {
    let today = day("2026-10-28")
    let daily = try item("Water plants", line: 10)
    let done = try item("Send invoice", todo: "DONE", line: 20)
    let upcoming = try item("Quarterly report", kind: "DEADLINE", line: 30, priority: "A")
    let warning = try item("Quarterly report", kind: "DEADLINE", line: 30, warning: true)
    let older = try item("Renew passport", line: 40)
    let set = WorkspaceCalendarTasks.taskSet(
      from: payload(
        overdue: [agendaDay("2026-09-01", [older])],
        days: [
          agendaDay("2026-10-26", [daily, done]),
          agendaDay("2026-10-27", [daily]),
          agendaDay("2026-10-28", [daily, warning]),
          agendaDay("2026-11-02", [upcoming]),
        ]
      ),
      today: today,
      calendar: calendar
    )

    XCTAssertEqual(set.overdue.map(\.title), ["Renew passport", "Water plants"])
    XCTAssertEqual(set.overdue.last?.dayKey, "2026-10-26", "the oldest open occurrence represents the heading")
    XCTAssertEqual(
      set.tasks.map { "\($0.dayKey) \($0.title)" }.sorted(),
      ["2026-10-26 Send invoice", "2026-10-28 Water plants", "2026-11-02 Quarterly report"],
      "past open rows are only shown as overdue; completed rows stay on their day"
    )

    let merged = WorkspaceCalendarTasks.taskSet(
      from: payload(days: [agendaDay("2026-10-28", [daily])]),
      additionalOverdue: [agendaDay("2026-10-20", [older]), agendaDay("2026-10-21", [older])],
      today: today,
      calendar: calendar
    )
    XCTAssertEqual(merged.overdue.map(\.dayKey), ["2026-10-20"], "the agenda's own overdue rows are merged once")
  }

  func testTimedTodosUseTheirEffortAndUntimedOnesAreRankedByUrgency() throws {
    XCTAssertEqual(WorkspaceCalendarTasks.minutes(fromAgendaTime: "09:30"), 570)
    XCTAssertNil(WorkspaceCalendarTasks.minutes(fromAgendaTime: "25:00"))
    XCTAssertEqual(WorkspaceCalendarTasks.durationMinutes(forEffort: "1:30"), 90)
    XCTAssertEqual(WorkspaceCalendarTasks.durationMinutes(forEffort: "45min"), 45)
    XCTAssertEqual(WorkspaceCalendarTasks.durationMinutes(forEffort: "2h"), 120)
    XCTAssertEqual(WorkspaceCalendarTasks.durationMinutes(forEffort: "9h"), WorkspaceCalendarTasks.maximumDurationMinutes)
    XCTAssertEqual(WorkspaceCalendarTasks.durationMinutes(forEffort: nil), WorkspaceCalendarTasks.defaultDurationMinutes)

    let today = day("2026-10-28")
    let set = WorkspaceCalendarTasks.taskSet(
      from: payload(days: [agendaDay("2026-10-28", [
        try item("Plain", line: 1),
        try item("Due", kind: "DEADLINE", line: 2),
        try item("Urgent", line: 3, priority: "A"),
        try item("Standup prep", line: 4, time: "09:00", effort: "0:45"),
      ])]),
      today: today,
      calendar: calendar
    )
    let built = WorkspaceCalendarLayout.days([today], events: [], tasks: set.tasks, calendar: calendar)[0]
    XCTAssertEqual(built.allDay.map(\.title), ["Urgent", "Due", "Plain"])
    XCTAssertEqual(built.timed.map(\.entry.title), ["Standup prep"])
    XCTAssertEqual(built.timed.first?.startMinute, 9 * 60)
    XCTAssertEqual(built.timed.first?.endMinute, 9 * 60 + 45)
  }

  func testFoldingReservesARowForTheHiddenCount() {
    XCTAssertEqual(WorkspaceCalendarLayout.folded([1, 2, 3], limit: 3).hiddenCount, 0)
    let folded = WorkspaceCalendarLayout.folded(Array(1...20), limit: 4)
    XCTAssertEqual(folded.visible, [1, 2, 3])
    XCTAssertEqual(folded.hiddenCount, 17)
  }

  // MARK: Sources and notes

  func testSourcesFollowConfiguredProfilesWithStableColors() {
    let events = [
      CalendarMeetingEvent(calendarId: "primary", eventId: "1", title: "A", start: Date(), end: Date(), sourceProfileID: "work-calendar"),
      CalendarMeetingEvent(calendarId: "primary", eventId: "2", title: "B", start: Date(), end: Date(), sourceProfileID: "removed"),
    ]
    let sources = WorkspaceCalendarSource.sources(
      configuredProfiles: [(id: "work-calendar", enabled: true), (id: "home", enabled: true), (id: "off", enabled: false)],
      events: events
    )
    XCTAssertEqual(sources.map(\.id), ["home", "work-calendar"])
    XCTAssertEqual(sources.map(\.colorIndex), [0, 1])
    XCTAssertEqual(sources.last?.title, "Work Calendar")
    XCTAssertEqual(sources.last?.eventCount, 1)

    let unconfigured = WorkspaceCalendarSource.sources(configuredProfiles: [], events: events)
    XCTAssertEqual(unconfigured.map(\.id), ["removed", "work-calendar"])
  }

  func testLinkedNotesAreExactMatchesMostSpecificFirst() {
    let start = instant("2026-10-28T17:00:00Z")
    let event = CalendarMeetingEvent(
      calendarId: "primary",
      eventId: "evt-2",
      title: "Design Review",
      start: start,
      end: start + 1800,
      attendees: [
        CalendarMeetingAttendee(email: "me@example.com", isSelf: true),
        CalendarMeetingAttendee(email: "ada@example.com", name: "Ada Lovelace"),
        CalendarMeetingAttendee(email: "nobody@example.com"),
      ]
    )
    let meetings = [
      MeetingWorkspaceItem(title: "Design Review", file: "/c/meetings/today.org", recordedAt: "2026-10-28", modifiedAt: nil, audioArtifact: nil, transcriptArtifact: nil, transcriptionStatus: nil, idValue: nil, calendarEventID: "evt-2"),
      MeetingWorkspaceItem(title: "design  review", file: "/c/meetings/last-week.org", recordedAt: "2026-10-21", modifiedAt: nil, audioArtifact: nil, transcriptArtifact: nil, transcriptionStatus: nil, idValue: nil, calendarEventID: "evt-1"),
      MeetingWorkspaceItem(title: "Standup", file: "/c/meetings/standup.org", recordedAt: "2026-10-27", modifiedAt: nil, audioArtifact: nil, transcriptArtifact: nil, transcriptionStatus: nil, idValue: nil),
    ]
    let resolver = OrgRoamLinkResolver(nodes: [
      OrgRoamNodeReference(idValue: "review-id", title: "Design Review", file: "/c/notes/design-review.org", line: 1, isPageNode: true),
      OrgRoamNodeReference(idValue: "ada-id", title: "Ada Lovelace", file: "/c/people/ada.org", line: 1, isPageNode: true),
    ])
    let notes = WorkspaceCalendarLinks.linkedNotes(for: event, meetings: meetings, resolver: resolver)
    XCTAssertEqual(notes.map(\.kind), [.meetingNote, .titleNote, .earlierMeeting, .person])
    XCTAssertEqual(notes.map(\.file), [
      "/c/meetings/today.org",
      "/c/notes/design-review.org",
      "/c/meetings/last-week.org",
      "/c/people/ada.org",
    ])
  }

  func testLoaderKeepsDescriptionsAndTheStagedFileAndChatCitesTheRecordLine() throws {
    let corpus = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-loader-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: corpus) }
    let zone = corpus.appendingPathComponent("raw/connectors/google-calendar/work", isDirectory: true)
    try FileManager.default.createDirectory(at: zone, withIntermediateDirectories: true)
    let packet: [String: Any] = [
      "schema": "org2:source-import:v1",
      "profile": "work",
      "sourceType": "google-calendar",
      "records": [
        ["id": "google-calendar:primary:other", "rawPayload": ["calendarId": "primary", "eventId": "other", "title": "Other", "start": "2026-10-28T15:00:00.000Z", "end": "2026-10-28T15:30:00.000Z"]],
        ["id": "google-calendar:primary:evt-9", "rawPayload": [
          "calendarId": "primary", "eventId": "evt-9", "title": "Planning",
          "start": "2026-10-28T17:00:00.000Z", "end": "2026-10-28T18:00:00.000Z",
          "description": "Bring the roadmap.", "recurringEventId": "series-1",
        ]],
      ],
    ]
    let file = zone.appendingPathComponent("primary--2026-10.json")
    try JSONSerialization.data(withJSONObject: packet, options: [.prettyPrinted, .sortedKeys]).write(to: file)

    let event = try XCTUnwrap(CalendarMeetingEventLoader.load(corpusRoot: corpus).first { $0.eventId == "evt-9" })
    XCTAssertEqual(event.details, "Bring the roadmap.")
    XCTAssertEqual(event.recurringEventId, "series-1")
    XCTAssertEqual(event.sourceFile.map { URL(fileURLWithPath: $0).standardizedFileURL.path }, file.standardizedFileURL.path)

    let line = WorkspaceStore.calendarEventLine(inFile: file.path, eventID: "evt-9", calendarID: "primary")
    let text = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    XCTAssertTrue(text[line - 1].contains("google-calendar:primary:evt-9"))
  }

  // MARK: Store

  func testStoreReadsTheAgendaForTheVisibleMonthAndInvalidatesWithTheAgenda() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    final class Requests { var all: [[String]] = [] }
    let recorded = Requests()
    let task = try item("Ship calendar", line: 1)
    let today = WorkspaceCalendarDates.date(fromKey: "2026-10-28")!
    store.agendaRefreshLoaderForTesting = { arguments in
      recorded.all.append(arguments)
      let from = arguments[arguments.firstIndex(of: "--from")! + 1]
      return AgendaPayload(
        schema: nil,
        range: AgendaRange(start: from, end: from, days: 1),
        overdue: [],
        days: [AgendaDay(date: "2026-10-29", weekday: "", items: [task], groups: nil)],
        skippedFiles: nil,
        workload: nil,
        corpora: nil,
        issues: nil
      )
    }
    store.setCorpusRoot(root)
    store.calendarAnchorDate = today

    await store.refreshCalendar()
    let requests = recorded.all
    XCTAssertEqual(requests.count, 1)
    let window = WorkspaceCalendarLayout.agendaWindow(for: store.calendarAnchorDate)
    XCTAssertEqual(requests.first.map { Array($0.prefix(3)) }, ["agenda", "--dir", root.path])
    XCTAssertTrue(requests[0].contains(window.from) && requests[0].contains(window.to))
    XCTAssertEqual(store.calendarTaskSet(today: today).tasks.map(\.title), ["Ship calendar"])

    await store.refreshCalendar()
    XCTAssertEqual(recorded.all.count, 1, "the same month is not read again")
    await store.refreshCalendar(force: true)
    XCTAssertEqual(recorded.all.count, 2)

    store.calendarAnchorDate = WorkspaceCalendarDates.date(fromKey: "2026-12-10")!
    await store.refreshCalendar()
    XCTAssertEqual(recorded.all.count, 3, "paging to another month reads that month")

    let completed = try XCTUnwrap(store.calendarTaskSet(today: today).tasks.first)
    store.optimisticallyUpdateCalendarTask(completed, todo: "DONE")
    XCTAssertEqual(store.calendarTaskSet(today: today).tasks.first?.isCompleted, true)

    store.markWorkspaceSurfacesDirty([.agenda], refreshVisible: false)
    XCTAssertTrue(store.isWorkspaceSurfaceDirty(.calendar))
  }

  func testAskAIStartsAChatCitingTheEventRecordAndItsNotes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-ask-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let zone = root.appendingPathComponent("raw/connectors/google-calendar/work", isDirectory: true)
    try FileManager.default.createDirectory(at: zone, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true)
    let file = zone.appendingPathComponent("primary--2026-10.json")
    try """
    {
      "schema": "org2:source-import:v1",
      "profile": "work",
      "sourceType": "google-calendar",
      "records": [
        {
          "id": "google-calendar:primary:review-1",
          "rawPayload": {
            "calendarId": "primary",
            "eventId": "review-1",
            "title": "Design Review",
            "start": "2026-10-28T17:00:00.000Z",
            "end": "2026-10-28T18:00:00.000Z"
          }
        }
      ]
    }
    """.write(to: file, atomically: true, encoding: .utf8)
    let meeting = root.appendingPathComponent("meetings/review.org")
    try """
    :PROPERTIES:
    :KIND: meeting
    :calendar_event_id: review-1
    :END:
    #+TITLE: Meeting: Design Review
    """.write(to: meeting, atomically: true, encoding: .utf8)

    let store = try WorkspaceStore(cli: Org2CLI(repoRoot: Org2CLI.defaultRepoRoot()))
    store.setCorpusRoot(root, persistsDefault: false)
    store.openClawRemoteCorpusPath = "/remote/corpus"
    await store.refreshMeetings()
    await store.reloadCalendarMeetingEvents()
    let event = try XCTUnwrap(store.calendarMeetingEvents.first)
    XCTAssertEqual(store.calendarLinkedNotes(for: event).map(\.kind), [.meetingNote])

    await store.askAIChatAboutCalendarEvent(event)

    let contexts = AIChatContextPresentation(store.aiChatDraft).contexts
    XCTAssertEqual(contexts.map(\.kind), ["calendar event", "meeting note"])
    XCTAssertEqual(contexts.first?.reference, "/remote/corpus/raw/connectors/google-calendar/work/primary--2026-10.json:7")
    XCTAssertTrue(contexts.first?.title.hasPrefix("Design Review · ") == true)
    XCTAssertEqual(contexts.last?.reference.hasSuffix("meetings/review.org:5"), true, contexts.last?.reference ?? "")
    XCTAssertEqual(store.selectedAIChatThread?.title, "Event: Design Review")
  }

  func testEventDetailsMakeBareWebURLsClickable() throws {
    let details = """
    Where:
    https://us06web.zoom.us/j/829?pwd=abc.1
    Notes: https://docs.google.com/document/d/1CPX, then avi@scarf.sh
    """
    let links = CalendarEventDetailsText.links(in: details)
    XCTAssertEqual(links.map(\.url.absoluteString), [
      "https://us06web.zoom.us/j/829?pwd=abc.1",
      "https://docs.google.com/document/d/1CPX",
    ])

    let attributed = CalendarEventDetailsText.attributed(details)
    XCTAssertEqual(String(attributed.characters), details)
    let linkedRuns = attributed.runs.compactMap { run -> (String, URL)? in
      guard let url = run.link else { return nil }
      return (String(attributed[run.range].characters), url)
    }
    XCTAssertEqual(linkedRuns.map(\.0), [
      "https://us06web.zoom.us/j/829?pwd=abc.1",
      "https://docs.google.com/document/d/1CPX",
    ])
    XCTAssertEqual(linkedRuns.map(\.1.absoluteString), linkedRuns.map(\.0))
    XCTAssertTrue(CalendarEventDetailsText.links(in: "No links here.").isEmpty)
  }
}
