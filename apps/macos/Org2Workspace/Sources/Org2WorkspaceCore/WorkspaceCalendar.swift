import Foundation

// The Calendar surface: synced Google Calendar events and agenda TODOs on one
// day, week, or month grid. Everything here is a deterministic projection of
// data the app already reads (source raw zones, `celorga agenda` JSON, meeting
// notes, and the node index); the calendar owns no state of its own.

public enum WorkspaceCalendarScale: String, CaseIterable, Identifiable, Sendable {
  case day
  case week
  case month

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .day: "Day"
    case .week: "Week"
    case .month: "Month"
    }
  }

  /// Untimed rows a day shows before folding the rest into "+N more".
  public var allDayRowLimit: Int {
    switch self {
    case .day: 8
    case .week: 4
    case .month: 3
    }
  }
}

// MARK: - Calendar sources

/// One configured Google Calendar source profile, as the calendar shows it.
public struct WorkspaceCalendarSource: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let colorIndex: Int
  public let eventCount: Int

  public init(id: String, title: String, colorIndex: Int, eventCount: Int) {
    self.id = id
    self.title = title
    self.colorIndex = colorIndex
    self.eventCount = eventCount
  }

  /// "work-calendar" -> "Work Calendar".
  public static func displayTitle(forProfileID id: String) -> String {
    let words = id
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(separator: " ")
      .map { word -> String in
        guard let first = word.first else { return "" }
        return first.isLowercase ? first.uppercased() + word.dropFirst() : String(word)
      }
    let title = words.joined(separator: " ")
    return title.isEmpty ? id : title
  }

  /// Sources to show: the enabled Google Calendar profiles configured in the
  /// corpus. Synced events from a profile that is no longer configured are
  /// left out; when no profile is configured (or profiles have not loaded
  /// yet) every synced profile is shown.
  public static func sources(
    configuredProfiles: [(id: String, enabled: Bool)],
    events: [CalendarMeetingEvent]
  ) -> [WorkspaceCalendarSource] {
    var counts: [String: Int] = [:]
    for event in events { counts[event.sourceProfileID, default: 0] += 1 }
    let ids: [String]
    if configuredProfiles.isEmpty {
      ids = Array(counts.keys)
    } else {
      ids = configuredProfiles.filter(\.enabled).map(\.id)
    }
    let ordered = Array(Set(ids)).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    return ordered.enumerated().map { index, id in
      WorkspaceCalendarSource(
        id: id,
        title: displayTitle(forProfileID: id),
        colorIndex: index,
        eventCount: counts[id, default: 0]
      )
    }
  }
}

// MARK: - Tasks

/// One agenda item placed on a calendar day.
public struct WorkspaceCalendarTask: Identifiable, Hashable, Sendable {
  public let item: AgendaItem
  /// Start of the local day the item is planned for.
  public let day: Date
  public let dayKey: String
  /// Minutes after midnight, when the planning timestamp has a time.
  public let startMinute: Int?
  public let durationMinutes: Int
  public let isOverdue: Bool

  public init(
    item: AgendaItem,
    day: Date,
    dayKey: String,
    startMinute: Int?,
    durationMinutes: Int,
    isOverdue: Bool
  ) {
    self.item = item
    self.day = day
    self.dayKey = dayKey
    self.startMinute = startMinute
    self.durationMinutes = durationMinutes
    self.isOverdue = isOverdue
  }

  public var id: String { "\(item.id)#\(dayKey)" }
  /// The heading this row belongs to, independent of the date it appears on.
  public var headingKey: String { "\(item.file):\(item.line):\(item.kind)" }
  public var isCompleted: Bool { !item.isActionable }
  public var isDeadline: Bool { item.kind.uppercased().hasPrefix("DEADLINE") }
  public var title: String { Org2Display.cleanInline(item.headline) }
}

/// The agenda items a calendar window shows, plus everything overdue.
public struct WorkspaceCalendarTaskSet: Sendable {
  public let tasks: [WorkspaceCalendarTask]
  /// Open items planned before today, one row per heading, oldest first.
  public let overdue: [WorkspaceCalendarTask]

  public init(tasks: [WorkspaceCalendarTask], overdue: [WorkspaceCalendarTask]) {
    self.tasks = tasks
    self.overdue = overdue
  }

  public static let empty = WorkspaceCalendarTaskSet(tasks: [], overdue: [])
}

public enum WorkspaceCalendarTasks {
  public static let defaultDurationMinutes = 30
  public static let maximumDurationMinutes = 4 * 60

  /// Projects `celorga agenda` JSON onto calendar days.
  ///
  /// Open items planned before today are not drawn on their past day: a
  /// repeating TODO would otherwise appear on every past day in the window.
  /// They are collected once per heading in `overdue` instead, merged with the
  /// main agenda's overdue rows when those are supplied. Upcoming-deadline
  /// warning copies are dropped because the deadline has its own day.
  public static func taskSet(
    from payload: AgendaPayload?,
    additionalOverdue: [AgendaDay] = [],
    today: Date,
    calendar: Calendar = .current
  ) -> WorkspaceCalendarTaskSet {
    let todayStart = calendar.startOfDay(for: today)
    var tasks: [WorkspaceCalendarTask] = []
    var overdueByHeading: [String: WorkspaceCalendarTask] = [:]

    func consider(_ day: AgendaDay, fromOverdueSection: Bool) {
      guard let date = WorkspaceCalendarDates.date(fromKey: day.date, calendar: calendar) else { return }
      for item in day.items where item.deadlineWarning == nil {
        let isPast = date < todayStart
        let task = WorkspaceCalendarTask(
          item: item,
          day: date,
          dayKey: day.date,
          startMinute: minutes(fromAgendaTime: item.time),
          durationMinutes: durationMinutes(forEffort: item.effort),
          isOverdue: isPast && item.isActionable
        )
        if task.isOverdue {
          if let existing = overdueByHeading[task.headingKey], existing.day <= task.day { continue }
          overdueByHeading[task.headingKey] = task
        } else if !fromOverdueSection, !(isPast && item.isActionable) {
          tasks.append(task)
        }
      }
    }

    for day in payload?.overdue ?? [] { consider(day, fromOverdueSection: true) }
    for day in additionalOverdue { consider(day, fromOverdueSection: true) }
    for day in payload?.days ?? [] { consider(day, fromOverdueSection: false) }

    let overdue = overdueByHeading.values.sorted { left, right in
      if left.day != right.day { return left.day < right.day }
      return rankedBefore(left, right)
    }
    return WorkspaceCalendarTaskSet(tasks: tasks, overdue: overdue)
  }

  /// "09:30" -> 570. The runtime normalizes agenda times to HH:MM.
  public static func minutes(fromAgendaTime raw: String?) -> Int? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    let parts = raw.split(separator: ":")
    guard parts.count >= 2,
          let hour = Int(parts[0]),
          let minute = Int(parts[1].prefix(2)),
          (0...23).contains(hour),
          (0...59).contains(minute)
    else { return nil }
    return hour * 60 + minute
  }

  /// How long a timed TODO occupies the grid: its Effort ("1:30", "45min",
  /// "2h") when present, otherwise half an hour, never more than four hours.
  public static func durationMinutes(forEffort raw: String?) -> Int {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
      return defaultDurationMinutes
    }
    var minutes: Int?
    if raw.contains(":") {
      let parts = raw.split(separator: ":")
      if parts.count == 2, let hours = Int(parts[0]), let mins = Int(parts[1]) {
        minutes = hours * 60 + mins
      }
    } else {
      let digits = raw.prefix { $0.isNumber || $0 == "." }
      let unit = raw.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
      if let value = Double(digits) {
        if unit.hasPrefix("h") {
          minutes = Int(value * 60)
        } else if unit.isEmpty || unit.hasPrefix("m") {
          minutes = Int(value)
        }
      }
    }
    guard let minutes, minutes > 0 else { return defaultDurationMinutes }
    return min(max(minutes, 15), maximumDurationMinutes)
  }

  /// Most pressing first: overdue, then priority, deadlines before scheduled
  /// items, then time of day and title.
  public static func rankedBefore(_ left: WorkspaceCalendarTask, _ right: WorkspaceCalendarTask) -> Bool {
    if left.isCompleted != right.isCompleted { return !left.isCompleted }
    if left.isOverdue != right.isOverdue { return left.isOverdue }
    let leftPriority = priorityRank(left.item.priority)
    let rightPriority = priorityRank(right.item.priority)
    if leftPriority != rightPriority { return leftPriority < rightPriority }
    if left.isDeadline != right.isDeadline { return left.isDeadline }
    let leftMinute = left.startMinute ?? Int.max
    let rightMinute = right.startMinute ?? Int.max
    if leftMinute != rightMinute { return leftMinute < rightMinute }
    return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
  }

  static func priorityRank(_ priority: String?) -> Int {
    guard let scalar = priority?.uppercased().unicodeScalars.first,
          ("A"..."Z").contains(Character(scalar))
    else { return 100 }
    return Int(scalar.value) - 65
  }
}

// MARK: - Entries and layout

/// Anything drawn on the calendar.
public enum WorkspaceCalendarEntry: Identifiable, Hashable, Sendable {
  case event(CalendarMeetingEvent)
  case task(WorkspaceCalendarTask)

  public var id: String {
    switch self {
    case .event(let event): "event:\(event.id)"
    case .task(let task): "task:\(task.id)"
    }
  }

  public var title: String {
    switch self {
    case .event(let event): event.title
    case .task(let task): task.title
    }
  }
}

/// A timed entry positioned in a day column.
public struct WorkspaceCalendarTimedEntry: Identifiable, Hashable, Sendable {
  public let entry: WorkspaceCalendarEntry
  public let startMinute: Int
  public let endMinute: Int
  public let column: Int
  public let columnCount: Int

  public var id: String { entry.id }
}

/// Everything one visible day shows.
public struct WorkspaceCalendarDay: Identifiable, Sendable {
  public let date: Date
  public let key: String
  /// All-day events first, then untimed TODOs, most pressing first.
  public let allDay: [WorkspaceCalendarEntry]
  public let timed: [WorkspaceCalendarTimedEntry]

  public var id: String { key }

  /// All entries in display order: all-day, then by start time.
  public var allEntries: [WorkspaceCalendarEntry] {
    allDay + timed.sorted { ($0.startMinute, $0.column) < ($1.startMinute, $1.column) }.map(\.entry)
  }
}

public enum WorkspaceCalendarLayout {
  public static let minimumBlockMinutes = 20

  /// The local days a scale shows around `anchor`. A month shows whole weeks.
  public static func visibleDays(
    scale: WorkspaceCalendarScale,
    anchor: Date,
    calendar: Calendar = .current
  ) -> [Date] {
    let anchorDay = calendar.startOfDay(for: anchor)
    switch scale {
    case .day:
      return [anchorDay]
    case .week:
      let start = weekStart(for: anchorDay, calendar: calendar)
      return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    case .month:
      guard let month = calendar.dateInterval(of: .month, for: anchorDay) else { return [anchorDay] }
      let start = weekStart(for: month.start, calendar: calendar)
      let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end) ?? month.start
      let lastWeekStart = weekStart(for: lastDay, calendar: calendar)
      let weeks = (calendar.dateComponents([.day], from: start, to: lastWeekStart).day ?? 0) / 7 + 1
      return (0..<(weeks * 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
  }

  public static func weekStart(for date: Date, calendar: Calendar = .current) -> Date {
    calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
  }

  /// The anchor one page earlier (`by: -1`) or later (`by: 1`).
  public static func shift(
    _ anchor: Date,
    scale: WorkspaceCalendarScale,
    by amount: Int,
    calendar: Calendar = .current
  ) -> Date {
    let component: Calendar.Component
    switch scale {
    case .day: component = .day
    case .week: component = .weekOfYear
    case .month: component = .month
    }
    return calendar.date(byAdding: component, value: amount, to: anchor) ?? anchor
  }

  /// The agenda window loaded for `anchor`: its whole month grid, so moving
  /// between days and weeks of the same month needs no new agenda read.
  public static func agendaWindow(for anchor: Date, calendar: Calendar = .current) -> (from: String, to: String) {
    let days = visibleDays(scale: .month, anchor: anchor, calendar: calendar)
    let first = days.first ?? calendar.startOfDay(for: anchor)
    let last = days.last ?? first
    return (
      WorkspaceCalendarDates.key(for: first, calendar: calendar),
      WorkspaceCalendarDates.key(for: last, calendar: calendar)
    )
  }

  /// Side-by-side columns for overlapping blocks. Each cluster of
  /// transitively overlapping blocks shares one column count.
  public static func placements(
    _ slots: [(entry: WorkspaceCalendarEntry, start: Int, end: Int)]
  ) -> [WorkspaceCalendarTimedEntry] {
    let sorted = slots
      .map { (entry: $0.entry, start: $0.start, end: max($0.end, $0.start + minimumBlockMinutes)) }
      .sorted { left, right in
        if left.start != right.start { return left.start < right.start }
        if left.end != right.end { return left.end > right.end }
        return left.entry.id < right.entry.id
      }
    var result: [WorkspaceCalendarTimedEntry] = []
    var cluster: [(entry: WorkspaceCalendarEntry, start: Int, end: Int, column: Int)] = []
    var columnEnds: [Int] = []
    var clusterEnd = Int.min

    func flush() {
      let count = max(1, columnEnds.count)
      for item in cluster {
        result.append(WorkspaceCalendarTimedEntry(
          entry: item.entry,
          startMinute: item.start,
          endMinute: item.end,
          column: item.column,
          columnCount: count
        ))
      }
      cluster = []
      columnEnds = []
    }

    for slot in sorted {
      if !cluster.isEmpty, slot.start >= clusterEnd { flush() }
      let column = columnEnds.firstIndex { $0 <= slot.start } ?? columnEnds.count
      if column == columnEnds.count { columnEnds.append(slot.end) } else { columnEnds[column] = slot.end }
      cluster.append((slot.entry, slot.start, slot.end, column))
      clusterEnd = cluster.count == 1 ? slot.end : max(clusterEnd, slot.end)
    }
    flush()
    return result
  }

  /// Builds every visible day from events and tasks. Timed events lasting a
  /// full day or more are shown with the all-day events.
  public static func days(
    _ dates: [Date],
    events: [CalendarMeetingEvent],
    tasks: [WorkspaceCalendarTask],
    calendar: Calendar = .current
  ) -> [WorkspaceCalendarDay] {
    let tasksByDay = Dictionary(grouping: tasks, by: \.dayKey)
    return dates.map { date in
      let dayStart = calendar.startOfDay(for: date)
      let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
      let key = WorkspaceCalendarDates.key(for: dayStart, calendar: calendar)
      var allDayEvents: [CalendarMeetingEvent] = []
      var slots: [(entry: WorkspaceCalendarEntry, start: Int, end: Int)] = []
      for event in events {
        if event.allDay || event.end.timeIntervalSince(event.start) >= 86_400 {
          let span = WorkspaceCalendarDates.allDaySpan(for: event, calendar: calendar)
          if span.start < dayEnd && span.end > dayStart { allDayEvents.append(event) }
          continue
        }
        let start = max(event.start, dayStart)
        let end = min(event.end > event.start ? event.end : event.start.addingTimeInterval(60), dayEnd)
        guard start < end else { continue }
        let startMinute = Int(start.timeIntervalSince(dayStart) / 60)
        let endMinute = max(startMinute + 1, Int(ceil(end.timeIntervalSince(dayStart) / 60)))
        slots.append((.event(event), startMinute, min(endMinute, 24 * 60)))
      }
      let dayTasks = (tasksByDay[key] ?? []).sorted(by: WorkspaceCalendarTasks.rankedBefore)
      var untimed: [WorkspaceCalendarTask] = []
      for task in dayTasks {
        if let startMinute = task.startMinute {
          slots.append((.task(task), startMinute, min(startMinute + task.durationMinutes, 24 * 60)))
        } else {
          untimed.append(task)
        }
      }
      allDayEvents.sort { ($0.start, $0.title) < ($1.start, $1.title) }
      return WorkspaceCalendarDay(
        date: dayStart,
        key: key,
        allDay: allDayEvents.map(WorkspaceCalendarEntry.event) + untimed.map(WorkspaceCalendarEntry.task),
        timed: placements(slots)
      )
    }
  }

  /// Rows that fit in `limit`: everything when it fits, otherwise one row
  /// fewer so the last row can say how many are hidden.
  public static func folded<T>(_ items: [T], limit: Int) -> (visible: [T], hiddenCount: Int) {
    guard limit > 0 else { return ([], items.count) }
    guard items.count > limit else { return (items, 0) }
    let visible = Array(items.prefix(max(1, limit - 1)))
    return (visible, items.count - visible.count)
  }
}

// MARK: - Dates

public enum WorkspaceCalendarDates {
  public static func key(for date: Date, calendar: Calendar = .current) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
  }

  public static func date(fromKey key: String, calendar: Calendar = .current) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  /// The local days an event covers, end exclusive. All-day events are
  /// stored as UTC midnights of floating dates, so they keep their calendar
  /// date in every time zone instead of shifting by the UTC offset.
  public static func allDaySpan(for event: CalendarMeetingEvent, calendar: Calendar = .current) -> (start: Date, end: Date) {
    guard event.allDay else {
      let start = calendar.startOfDay(for: event.start)
      let lastInstant = event.end > event.start ? event.end.addingTimeInterval(-1) : event.start
      let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastInstant)) ?? start
      return (start, end)
    }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    func local(_ instant: Date) -> Date {
      let components = utc.dateComponents([.year, .month, .day], from: instant)
      return calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day))
        ?? calendar.startOfDay(for: instant)
    }
    let start = local(event.start)
    var end = local(event.end)
    if end <= start { end = calendar.date(byAdding: .day, value: 1, to: start) ?? start }
    return (start, end)
  }
}

// MARK: - Notes linked to an event

/// A corpus note related to a calendar event.
public struct WorkspaceCalendarLinkedNote: Identifiable, Hashable, Sendable {
  public enum Kind: String, Sendable {
    /// The meeting note recorded for this occurrence (`:calendar_event_id:`).
    case meetingNote
    /// A meeting note from an earlier meeting with the same title.
    case earlierMeeting
    /// A note whose title is exactly the event title.
    case titleNote
    /// An attendee's person note.
    case person

    public var label: String {
      switch self {
      case .meetingNote: "Meeting note"
      case .earlierMeeting: "Earlier meeting"
      case .titleNote: "Note"
      case .person: "Person"
      }
    }

    public var systemImage: String {
      switch self {
      case .meetingNote: "waveform.and.mic"
      case .earlierMeeting: "clock.arrow.circlepath"
      case .titleNote: "doc.text"
      case .person: "person.crop.circle"
      }
    }
  }

  public let kind: Kind
  public let title: String
  public let file: String
  public let line: Int
  public let detail: String?

  public init(kind: Kind, title: String, file: String, line: Int, detail: String? = nil) {
    self.kind = kind
    self.title = title
    self.file = file
    self.line = max(1, line)
    self.detail = detail
  }

  public var id: String { "\(kind.rawValue):\(file):\(line)" }
}

public enum WorkspaceCalendarLinks {
  public static let earlierMeetingLimit = 3
  public static let personLimit = 8

  /// Notes for an event, most specific first: its own meeting note, a note
  /// titled like the event, earlier meetings with the same title, then
  /// attendees' person notes. Every match is exact; nothing is guessed.
  public static func linkedNotes(
    for event: CalendarMeetingEvent,
    meetings: [MeetingWorkspaceItem],
    resolver: OrgRoamLinkResolver
  ) -> [WorkspaceCalendarLinkedNote] {
    var notes: [WorkspaceCalendarLinkedNote] = []
    var seenFiles = Set<String>()
    func add(_ note: WorkspaceCalendarLinkedNote) {
      let key = URL(fileURLWithPath: note.file).standardizedFileURL.path
      guard seenFiles.insert(key).inserted else { return }
      notes.append(note)
    }

    for meeting in meetings where meeting.calendarEventID == event.eventId {
      add(.init(kind: .meetingNote, title: Org2Display.cleanInline(meeting.title), file: meeting.file, line: meeting.lineForEditor, detail: recordedLabel(meeting.recordedAt)))
    }

    let normalizedTitle = normalized(event.title)
    if !normalizedTitle.isEmpty, normalizedTitle != "(no title)" {
      let titled = resolver.exactCandidates(for: event.title).filter { $0.idValue != nil }
      if Set(titled.compactMap { $0.idValue?.lowercased() }).count == 1, let node = titled.first(where: \.isPageNode) ?? titled.first {
        add(.init(kind: .titleNote, title: node.title, file: node.file, line: node.line))
      }

      let earlier = meetings
        .filter { $0.calendarEventID != event.eventId && normalized(Org2Display.cleanInline($0.title)) == normalizedTitle }
        .prefix(earlierMeetingLimit)
      for meeting in earlier {
        add(.init(kind: .earlierMeeting, title: Org2Display.cleanInline(meeting.title), file: meeting.file, line: meeting.lineForEditor, detail: recordedLabel(meeting.recordedAt)))
      }
    }

    var people = 0
    for attendee in event.otherAttendees where people < personLimit {
      guard let node = MeetingAttendeeResolver.personNode(for: attendee, resolver: resolver) else { continue }
      let before = notes.count
      add(.init(kind: .person, title: node.title, file: node.file, line: node.line, detail: attendee.email))
      if notes.count > before { people += 1 }
    }
    return notes
  }

  /// "2026-10-21T17:00:00Z" -> "Oct 21, 2026"; other values pass through.
  static func recordedLabel(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    guard let date = CalendarMeetingEventLoader.date(raw) else { return raw }
    return date.formatted(date: .abbreviated, time: .omitted)
  }

  static func normalized(_ title: String) -> String {
    title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }
}
