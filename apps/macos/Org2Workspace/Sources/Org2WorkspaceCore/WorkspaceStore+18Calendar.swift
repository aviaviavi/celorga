import Foundation

extension WorkspaceStore {
  // MARK: Window

  public func showCalendarToday() {
    showCalendarDate(Date())
  }

  public func showCalendarDate(_ date: Date) {
    calendarAnchorDate = date
    Task { await refreshCalendar() }
  }

  public func shiftCalendar(scale: WorkspaceCalendarScale, by amount: Int) {
    showCalendarDate(WorkspaceCalendarLayout.shift(calendarAnchorDate, scale: scale, by: amount))
  }

  static func calendarAgendaWindowKey(for anchor: Date) -> String {
    let window = WorkspaceCalendarLayout.agendaWindow(for: anchor)
    return "\(window.from)..\(window.to)"
  }

  /// Reloads synced events and, when the visible month changed or `force` is
  /// set, the agenda for the month grid around `calendarAnchorDate`.
  public func refreshCalendar(force: Bool = false) async {
    guard let corpusRoot else {
      calendarAgenda = nil
      calendarAgendaWindow = nil
      return
    }
    await reloadCalendarMeetingEvents()
    if dirtyWorkspaceSurfaces.contains(.meetings), selectedSurface == .calendar {
      await refreshMeetings()
    }

    let window = WorkspaceCalendarLayout.agendaWindow(for: calendarAnchorDate)
    let key = "\(window.from)..\(window.to)"
    guard force || calendarAgendaWindow != key || calendarAgenda == nil else { return }
    guard !isRefreshingCalendar else { return }

    let sessionGeneration = corpusSessionGeneration
    isRefreshingCalendar = true
    let arguments = [
      "agenda", "--dir", corpusRoot.path,
      "--recursive",
      "--from", window.from,
      "--to", window.to,
      "--format", "json",
    ]
    do {
      let payload: AgendaPayload
      if let agendaRefreshLoaderForTesting {
        payload = try await agendaRefreshLoaderForTesting(arguments)
      } else {
        payload = try await cli.runJSON(arguments)
      }
      guard isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) else {
        isRefreshingCalendar = false
        return
      }
      calendarAgenda = payload
      calendarAgendaWindow = key
      calendarAgendaLoadedAt = Date()
      calendarErrorText = nil
    } catch {
      if isCurrentCorpusSession(root: corpusRoot, generation: sessionGeneration) {
        calendarErrorText = error.localizedDescription
      }
    }
    isRefreshingCalendar = false

    // The user may have paged to another month while the agenda loaded.
    if calendarErrorText == nil,
       Self.calendarAgendaWindowKey(for: calendarAnchorDate) != calendarAgendaWindow {
      await refreshCalendar()
    }
  }

  // MARK: Sources and content

  /// Configured Google Calendar sources, in a stable color order.
  public var calendarSources: [WorkspaceCalendarSource] {
    WorkspaceCalendarSource.sources(
      configuredProfiles: sourceProfiles
        .filter { $0.type == "google-calendar" }
        .map { (id: $0.id, enabled: $0.enabled) },
      events: calendarMeetingEvents
    )
  }

  public var calendarSourceProfiles: [WorkspaceSourceProfileStatus] {
    sourceProfiles.filter { $0.type == "google-calendar" && $0.enabled }
  }

  /// Events from shown sources, without declined events unless requested.
  public func calendarEvents(hiddenSourceIDs: Set<String>, showsDeclined: Bool) -> [CalendarMeetingEvent] {
    let shown = Set(calendarSources.map(\.id)).subtracting(hiddenSourceIDs)
    return calendarMeetingEvents.filter { event in
      shown.contains(event.sourceProfileID)
        && event.status != "cancelled"
        && (showsDeclined || event.selfResponse != "declined")
    }
  }

  /// Agenda items for the loaded window plus everything overdue. Overdue
  /// rows also come from the Agenda surface's own read (which starts today),
  /// so the calendar and the agenda agree on what is late.
  public func calendarTaskSet(today: Date = Date()) -> WorkspaceCalendarTaskSet {
    let agendaOverdue = (agenda?.overdue ?? []).map { day in
      AgendaDay(
        date: day.date,
        weekday: day.weekday,
        items: day.items.filter { isResultInActiveCorpus($0.corpus) },
        groups: nil
      )
    }
    return WorkspaceCalendarTasks.taskSet(from: calendarAgenda, additionalOverdue: agendaOverdue, today: today)
  }

  /// Runs Sync on every enabled Google Calendar source, then reloads events.
  public func syncCalendarSources() async {
    let profiles = calendarSourceProfiles
    guard !profiles.isEmpty, !isSyncingCalendarSources else { return }
    isSyncingCalendarSources = true
    for profile in profiles {
      await syncAndStageSource(profile)
    }
    isSyncingCalendarSources = false
    await reloadCalendarMeetingEvents()
    let failed = profiles.filter { sourceOperationFailureIDs.contains($0.id) }
    if failed.isEmpty {
      statusText = "Synced \(profiles.count) calendar\(profiles.count == 1 ? "" : "s")"
      calendarErrorText = nil
    } else {
      let message = failed
        .map { "\(WorkspaceCalendarSource.displayTitle(forProfileID: $0.id)): \(sourceOperationMessages[$0.id] ?? "sync failed")" }
        .joined(separator: "; ")
      calendarErrorText = message
      statusText = "Calendar sync needs attention"
    }
  }

  // MARK: Notes and actions

  public func calendarLinkedNotes(for event: CalendarMeetingEvent) -> [WorkspaceCalendarLinkedNote] {
    WorkspaceCalendarLinks.linkedNotes(for: event, meetings: meetings, resolver: orgRoamLinkResolver)
  }

  public func openCalendarLinkedNote(_ note: WorkspaceCalendarLinkedNote) {
    openChatFileReference(AIChatFileReference(path: note.file, line: note.line))
  }

  public func openCalendarTask(_ task: WorkspaceCalendarTask) {
    if activateCorpusIfNeeded(for: task.item.corpus, location: .agenda(task.item), surface: .calendar) {
      return
    }
    select(.agenda(task.item), surface: .calendar)
  }

  public func askAIChatAboutCalendarTask(_ task: WorkspaceCalendarTask) {
    startNewAIThread(with: [aiChatContextPointer(for: .agenda(task.item))], title: "Ask: \(task.title)")
  }

  /// Starts a chat with the event (its staged source record) and its linked
  /// notes as context, so the agent can prepare for, summarize, or follow up
  /// on the meeting.
  public func askAIChatAboutCalendarEvent(_ event: CalendarMeetingEvent) async {
    var pointers: [AIChatContextPointer] = []
    if let pointer = await calendarEventContextPointer(event) {
      pointers.append(pointer)
    }
    for note in calendarLinkedNotes(for: event) {
      pointers.append(AIChatContextPointer(
        kind: note.kind == .person ? "attendee note" : note.kind.label.lowercased(),
        displayTitle: note.title,
        reference: "\(mappedPathForOpenClaw(note.file)):\(note.line)",
        displayReference: "\(relativePath(note.file)):\(note.line)",
        threadTitle: "Event: \(event.title)"
      ))
    }
    guard !pointers.isEmpty else {
      statusText = "This event has no synced record to share"
      return
    }
    startNewAIThread(with: pointers, title: "Event: \(event.title)")
  }

  func calendarEventContextPointer(_ event: CalendarMeetingEvent) async -> AIChatContextPointer? {
    guard let file = event.sourceFile else { return nil }
    let eventID = event.eventId
    let calendarID = event.calendarId
    let line = await Task.detached(priority: .userInitiated) {
      Self.calendarEventLine(inFile: file, eventID: eventID, calendarID: calendarID)
    }.value
    return AIChatContextPointer(
      kind: "calendar event",
      displayTitle: "\(event.title) · \(WorkspaceCalendarFormat.whenLabel(for: event))",
      reference: "\(mappedPathForOpenClaw(file)):\(line)",
      displayReference: "\(relativePath(file)):\(line)",
      threadTitle: "Event: \(event.title)"
    )
  }

  /// The line of the event's record in a staged source file, so the chat
  /// cites the exact record rather than the top of a month of events.
  nonisolated static func calendarEventLine(inFile file: String, eventID: String, calendarID: String) -> Int {
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return 1 }
    let recordID = "\"google-calendar:\(calendarID):\(eventID)\""
    let quotedEventID = "\"\(eventID)\""
    var fallback: Int?
    var lineNumber = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      lineNumber += 1
      if line.contains(recordID) { return lineNumber }
      if fallback == nil, line.contains(quotedEventID) { fallback = lineNumber }
    }
    return fallback ?? 1
  }

  public func completeCalendarTask(_ task: WorkspaceCalendarTask) async {
    optimisticallyUpdateCalendarTask(task, todo: "DONE")
    await applyTodoShortcut(.done, to: .agenda(task.item))
    await refreshCalendar(force: true)
  }

  public func scheduleCalendarTask(_ task: WorkspaceCalendarTask, target: PlanningDateTarget) async {
    await applyPlanningShortcut(kind: .scheduled, target: target, to: .agenda(task.item))
    await refreshCalendar(force: true)
  }

  /// Shows a TODO change at once; the following agenda read confirms it.
  func optimisticallyUpdateCalendarTask(_ task: WorkspaceCalendarTask, todo: String) {
    guard let payload = calendarAgenda else { return }
    func update(_ days: [AgendaDay]) -> [AgendaDay] {
      days.map { day in
        AgendaDay(
          date: day.date,
          weekday: day.weekday,
          items: day.items.map { item in
            item.file == task.item.file && item.line == task.item.line ? item.replacing(todo: todo) : item
          },
          groups: day.groups
        )
      }
    }
    calendarAgenda = AgendaPayload(
      schema: payload.schema,
      range: payload.range,
      overdue: update(payload.overdue),
      days: update(payload.days),
      skippedFiles: payload.skippedFiles,
      workload: payload.workload,
      corpora: payload.corpora,
      issues: payload.issues
    )
  }
}

// MARK: - Formatting

public enum WorkspaceCalendarFormat {
  /// "Wed, Oct 28, 2:00 – 3:00 PM" or "Wed, Oct 28 (all day)".
  public static func whenLabel(for event: CalendarMeetingEvent, calendar: Calendar = .current) -> String {
    if event.allDay {
      let span = WorkspaceCalendarDates.allDaySpan(for: event, calendar: calendar)
      let formatter = DateFormatter()
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
      let lastDay = calendar.date(byAdding: .day, value: -1, to: span.end) ?? span.start
      if calendar.isDate(lastDay, inSameDayAs: span.start) {
        return "\(formatter.string(from: span.start)) (all day)"
      }
      return "\(formatter.string(from: span.start)) – \(formatter.string(from: lastDay)) (all day)"
    }
    let formatter = DateIntervalFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateTemplate = "EEEMMMdjmm"
    return formatter.string(from: event.start, to: max(event.end, event.start))
  }

  /// "2:00 PM", or "14:00", following the user's locale.
  public static func timeLabel(minute: Int, calendar: Calendar = .current, reference: Date = Date()) -> String {
    let day = calendar.startOfDay(for: reference)
    let date = calendar.date(byAdding: .minute, value: minute, to: day) ?? day
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    return formatter.string(from: date)
  }

  public static func hourLabel(_ hour: Int, calendar: Calendar = .current, reference: Date = Date()) -> String {
    let day = calendar.startOfDay(for: reference)
    let date = calendar.date(byAdding: .hour, value: hour, to: day) ?? day
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("j")
    return formatter.string(from: date)
  }

  /// Header for the visible range: "October 2026", "Oct 26 – Nov 1, 2026", or
  /// "Wednesday, October 28, 2026".
  public static func rangeTitle(scale: WorkspaceCalendarScale, anchor: Date, calendar: Calendar = .current) -> String {
    switch scale {
    case .day:
      let formatter = DateFormatter()
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMdyyyy")
      return formatter.string(from: anchor)
    case .week:
      let days = WorkspaceCalendarLayout.visibleDays(scale: .week, anchor: anchor, calendar: calendar)
      guard let first = days.first, let last = days.last else { return "" }
      let formatter = DateIntervalFormatter()
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      formatter.dateTemplate = "MMMdyyyy"
      return formatter.string(from: first, to: last)
    case .month:
      let formatter = DateFormatter()
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
      return formatter.string(from: anchor)
    }
  }
}
