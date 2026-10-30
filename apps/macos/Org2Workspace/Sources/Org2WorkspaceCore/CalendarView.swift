import AppKit
import SwiftUI

// MARK: - Presentation context

struct CalendarPresentation: Equatable {
  var sourceColorIndexes: [String: Int] = [:]
  var sourceTitles: [String: String] = [:]

  func color(for event: CalendarMeetingEvent) -> Color {
    CalendarPalette.color(sourceColorIndexes[event.sourceProfileID])
  }

  func title(for event: CalendarMeetingEvent) -> String {
    sourceTitles[event.sourceProfileID] ?? WorkspaceCalendarSource.displayTitle(forProfileID: event.sourceProfileID)
  }
}

private struct CalendarPresentationKey: EnvironmentKey {
  static let defaultValue = CalendarPresentation()
}

extension EnvironmentValues {
  var calendarPresentation: CalendarPresentation {
    get { self[CalendarPresentationKey.self] }
    set { self[CalendarPresentationKey.self] = newValue }
  }
}

enum CalendarPalette {
  static let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo, .brown, .cyan, .mint]

  static func color(_ index: Int?) -> Color {
    guard let index else { return .gray }
    return colors[index % colors.count]
  }

  static func taskTint(_ task: WorkspaceCalendarTask) -> Color {
    if task.isCompleted { return .green }
    if task.isOverdue { return .red }
    if task.isDeadline { return .orange }
    return WorkspaceDesign.structuralAccent
  }

  static func taskSymbol(_ task: WorkspaceCalendarTask) -> String {
    if task.isCompleted { return "checkmark.circle.fill" }
    if task.isOverdue { return "exclamationmark.circle" }
    if task.isDeadline { return "flag" }
    return "circle"
  }
}

// MARK: - Surface

struct CalendarView: View {
  static let scaleDefaultsKey = "Org2Workspace.calendar.scale.v1"

  @Environment(WorkspaceStore.self) private var store
  @AppStorage(CalendarView.scaleDefaultsKey) private var scaleRaw = WorkspaceCalendarScale.week.rawValue
  @AppStorage("Org2Workspace.calendar.showsTasks.v1") private var showsTasks = true
  @AppStorage("Org2Workspace.calendar.showsCompletedTasks.v1") private var showsCompletedTasks = false
  @AppStorage("Org2Workspace.calendar.showsDeclinedEvents.v1") private var showsDeclinedEvents = false
  @AppStorage("Org2Workspace.calendar.hiddenSources.v1") private var hiddenSourcesStorage = ""
  @State private var isOverduePresented = false

  private var scale: WorkspaceCalendarScale {
    WorkspaceCalendarScale(rawValue: scaleRaw) ?? .week
  }

  private var hiddenSourceIDs: Set<String> {
    Set(hiddenSourcesStorage.split(separator: "\n").map(String.init))
  }

  var body: some View {
    let sources = store.calendarSources
    let taskSet = showsTasks ? store.calendarTaskSet() : .empty
    let tasks = showsCompletedTasks ? taskSet.tasks : taskSet.tasks.filter { !$0.isCompleted }
    let events = store.calendarEvents(hiddenSourceIDs: hiddenSourceIDs, showsDeclined: showsDeclinedEvents)
    let dates = WorkspaceCalendarLayout.visibleDays(scale: scale, anchor: store.calendarAnchorDate)
    let days = WorkspaceCalendarLayout.days(dates, events: events, tasks: tasks)
    let presentation = CalendarPresentation(
      sourceColorIndexes: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.colorIndex) }),
      sourceTitles: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.title) })
    )

    VStack(spacing: 0) {
      HeaderBar(
        title: "Calendar",
        subtitle: WorkspaceCalendarFormat.rangeTitle(scale: scale, anchor: store.calendarAnchorDate),
        surface: .calendar
      ) {
        if store.isRefreshingCalendar || store.isSyncingCalendarSources {
          WorkspaceActivityIndicator(size: .small)
        }
        if store.hasWorkspaceDetailContent && !store.isWorkspaceDetailPaneClosed {
          Button {
            store.closeDetailPane()
          } label: {
            Label("Full Width", systemImage: "arrow.left.and.right")
          }
          .help("Close the document pane so the calendar uses the full window")
        }
        Button {
          Task { await store.syncCalendarSources() }
        } label: {
          Label("Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(store.calendarSourceProfiles.isEmpty || store.isSyncingCalendarSources)
        .help("Sync every Google Calendar source now")
        Button {
          Task { await store.refreshCalendar(force: true) }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(store.isRefreshingCalendar)
        .help("Reload synced events and agenda items")
      }

      toolbar(sources: sources, overdue: showsTasks ? taskSet.overdue : [])

      if sources.isEmpty {
        CalendarNotice(
          systemImage: "calendar.badge.plus",
          text: "Add a Google Calendar source to see your meetings here. Agenda TODOs appear either way.",
          actionTitle: "Open Sources"
        ) {
          store.makeSurfacePrimary(.sources)
        }
      }
      if let error = store.calendarErrorText {
        CalendarNotice(systemImage: "exclamationmark.triangle", text: error, tint: .orange, actionTitle: "Retry") {
          Task { await store.refreshCalendar(force: true) }
        }
      }

      Divider()

      Group {
        switch scale {
        case .day, .week:
          CalendarTimeGrid(days: days, scale: scale) { day in
            showDay(day)
          }
        case .month:
          CalendarMonthGrid(days: days, anchor: store.calendarAnchorDate) { day in
            showDay(day)
          }
        }
      }
      .environment(\.calendarPresentation, presentation)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .environment(\.calendarPresentation, presentation)
    .task {
      await store.refreshCalendar()
    }
  }

  private func toolbar(sources: [WorkspaceCalendarSource], overdue: [WorkspaceCalendarTask]) -> some View {
    HStack(spacing: 8) {
      HStack(spacing: 2) {
        Button {
          store.shiftCalendar(scale: scale, by: -1)
        } label: {
          Label("Previous", systemImage: "chevron.left")
        }
        .labelStyle(.iconOnly)
        .help("Previous \(scale.title.lowercased())")
        Button("Today") {
          store.showCalendarToday()
        }
        .help("Go to today")
        Button {
          store.shiftCalendar(scale: scale, by: 1)
        } label: {
          Label("Next", systemImage: "chevron.right")
        }
        .labelStyle(.iconOnly)
        .help("Next \(scale.title.lowercased())")
      }

      Picker("Scale", selection: $scaleRaw) {
        ForEach(WorkspaceCalendarScale.allCases) { scale in
          Text(scale.title).tag(scale.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 190)

      Spacer(minLength: 4)

      if !overdue.isEmpty {
        Button {
          isOverduePresented = true
        } label: {
          Label("\(overdue.count) overdue", systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
        }
        .help("Open TODOs planned before today")
        .popover(isPresented: $isOverduePresented, arrowEdge: .bottom) {
          CalendarEntryListPopover(
            title: "Overdue",
            subtitle: "\(overdue.count) open TODO\(overdue.count == 1 ? "" : "s") planned before today",
            entries: overdue.map(WorkspaceCalendarEntry.task)
          )
        }
      }

      Menu {
        if !sources.isEmpty {
          Section("Calendars") {
            ForEach(sources) { source in
              Toggle(isOn: sourceBinding(source.id)) {
                Label {
                  Text(source.title)
                } icon: {
                  Image(systemName: "circle.fill")
                    .foregroundStyle(CalendarPalette.color(source.colorIndex))
                }
              }
            }
          }
        }
        Section("Agenda") {
          Toggle("TODOs", isOn: $showsTasks)
          Toggle("Completed TODOs", isOn: $showsCompletedTasks)
            .disabled(!showsTasks)
        }
        Toggle("Declined events", isOn: $showsDeclinedEvents)
        Divider()
        Button("Manage Sources…") {
          store.makeSurfacePrimary(.sources)
        }
      } label: {
        Label("Show", systemImage: "line.3.horizontal.decrease.circle")
      }
      .fixedSize()
      .help("Choose which calendars and agenda items to show")
    }
    .controlSize(.small)
    .buttonStyle(WorkspaceActionButtonStyle())
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.vertical, 8)
  }

  private func sourceBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { !hiddenSourceIDs.contains(id) },
      set: { isShown in
        var hidden = hiddenSourceIDs
        if isShown { hidden.remove(id) } else { hidden.insert(id) }
        hiddenSourcesStorage = hidden.sorted().joined(separator: "\n")
      }
    )
  }

  private func showDay(_ day: Date) {
    scaleRaw = WorkspaceCalendarScale.day.rawValue
    store.showCalendarDate(day)
  }
}

private struct CalendarNotice: View {
  let systemImage: String
  let text: String
  var tint: Color = .secondary
  let actionTitle: String
  let action: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Button(actionTitle, action: action)
        .buttonStyle(WorkspaceActionButtonStyle())
        .controlSize(.small)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous))
    .padding(.horizontal, WorkspaceDesign.contentInset)
    .padding(.bottom, 8)
  }
}

// MARK: - Day and week grid

private struct CalendarTimeGrid: View {
  let days: [WorkspaceCalendarDay]
  let scale: WorkspaceCalendarScale
  let openDay: (Date) -> Void

  static let hourHeight: CGFloat = 46
  static let gutterWidth: CGFloat = 46

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Color.clear.frame(width: Self.gutterWidth, height: 1)
        ForEach(days) { day in
          CalendarDayHeader(date: day.date, isTappable: scale == .week) {
            openDay(day.date)
          }
          .frame(maxWidth: .infinity)
        }
      }
      .padding(.vertical, 6)

      if days.contains(where: { !$0.allDay.isEmpty }) {
        HStack(alignment: .top, spacing: 0) {
          Text("all-day")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: Self.gutterWidth - 6, alignment: .trailing)
            .padding(.trailing, 6)
            .padding(.top, 4)
          ForEach(days) { day in
            CalendarAllDayLane(day: day, limit: scale.allDayRowLimit)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .overlay(alignment: .leading) {
                Rectangle().fill(WorkspaceDesign.hairline).frame(width: 0.5)
              }
          }
        }
        .padding(.bottom, 4)
      }

      Divider()

      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
              ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 0) {
                  Text(hour == 0 ? "" : WorkspaceCalendarFormat.hourLabel(hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.gutterWidth - 6, alignment: .trailing)
                    .padding(.trailing, 6)
                    .offset(y: -6)
                  Rectangle()
                    .fill(WorkspaceDesign.hairline)
                    .frame(height: 0.5)
                }
                .frame(height: Self.hourHeight, alignment: .top)
                .id("hour-\(hour)")
              }
            }
            HStack(spacing: 0) {
              Color.clear.frame(width: Self.gutterWidth)
              ForEach(days) { day in
                CalendarDayColumn(day: day, hourHeight: Self.hourHeight)
              }
            }
          }
          .frame(height: Self.hourHeight * 24)
          .padding(.top, 8)
        }
        .task {
          // Start near now on today's week, otherwise at the first timed entry.
          let containsToday = days.contains { Calendar.current.isDateInToday($0.date) }
          let firstTimed = days.flatMap(\.timed).map(\.startMinute).min()
          let hour = containsToday
            ? Calendar.current.component(.hour, from: Date()) - 2
            : (firstTimed.map { $0 / 60 } ?? 8)
          try? await Task.sleep(nanoseconds: 30_000_000)
          proxy.scrollTo("hour-\(min(max(hour, 0), 16))", anchor: .top)
        }
      }
    }
  }
}

private struct CalendarDayHeader: View {
  let date: Date
  let isTappable: Bool
  let action: () -> Void

  var body: some View {
    let calendar = Calendar.current
    let isToday = calendar.isDateInToday(date)
    Button {
      if isTappable { action() }
    } label: {
      HStack(spacing: 4) {
        Text(date, format: .dateTime.weekday(.abbreviated))
          .font(.caption)
          .foregroundStyle(isToday ? Color.accentColor : .secondary)
        Text("\(calendar.component(.day, from: date))")
          .font(.callout.weight(isToday ? .bold : .medium).monospacedDigit())
          .foregroundStyle(isToday ? Color.white : WorkspaceDesign.primaryText)
          .padding(.horizontal, isToday ? 5 : 0)
          .padding(.vertical, isToday ? 1 : 0)
          .background {
            if isToday { Capsule().fill(Color.accentColor) }
          }
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isTappable ? "Show this day" : "")
  }
}

private struct CalendarAllDayLane: View {
  let day: WorkspaceCalendarDay
  let limit: Int
  @State private var isMorePresented = false

  var body: some View {
    let folded = WorkspaceCalendarLayout.folded(day.allDay, limit: limit)
    VStack(alignment: .leading, spacing: 2) {
      ForEach(folded.visible) { entry in
        CalendarChip(entry: entry)
      }
      if folded.hiddenCount > 0 {
        Button {
          isMorePresented = true
        } label: {
          Text("+\(folded.hiddenCount) more")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show every all-day item on this day")
        .popover(isPresented: $isMorePresented, arrowEdge: .bottom) {
          CalendarEntryListPopover(
            title: day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
            subtitle: "All-day events and TODOs",
            entries: day.allDay
          )
        }
      }
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 2)
  }
}

private struct CalendarDayColumn: View {
  let day: WorkspaceCalendarDay
  let hourHeight: CGFloat

  var body: some View {
    let isToday = Calendar.current.isDateInToday(day.date)
    GeometryReader { geometry in
      let width = geometry.size.width
      ZStack(alignment: .topLeading) {
        Rectangle()
          .fill(isToday ? Color.accentColor.opacity(0.04) : Color.clear)
        Rectangle()
          .fill(WorkspaceDesign.hairline)
          .frame(width: 0.5)
        ForEach(day.timed) { placed in
          let columnWidth = max(1, (width - 4) / CGFloat(placed.columnCount))
          let height = CGFloat(placed.endMinute - placed.startMinute) * hourHeight / 60
          CalendarTimedBlock(placed: placed, height: height)
            .frame(width: max(columnWidth - 2, 6), height: max(height - 2, 15))
            .offset(
              x: 2 + CGFloat(placed.column) * columnWidth,
              y: CGFloat(placed.startMinute) * hourHeight / 60 + 1
            )
        }
        if isToday {
          CalendarNowLine(hourHeight: hourHeight)
        }
      }
    }
    .frame(maxWidth: .infinity)
  }
}

private struct CalendarNowLine: View {
  let hourHeight: CGFloat
  /// Advanced once a minute by a local task, so only this line redraws.
  @State private var now = Date()

  var body: some View {
    let calendar = Calendar.current
    let minutes = now.timeIntervalSince(calendar.startOfDay(for: now)) / 60
    ZStack(alignment: .leading) {
      Rectangle()
        .fill(Color.red)
        .frame(height: 1.5)
      Circle()
        .fill(Color.red)
        .frame(width: 7, height: 7)
        .offset(x: -3.5)
    }
    .offset(y: CGFloat(minutes) * hourHeight / 60 - 0.75)
    .allowsHitTesting(false)
    .task {
      while !Task.isCancelled {
        let seconds = 60 - Calendar.current.component(.second, from: Date())
        try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
        guard !Task.isCancelled else { return }
        now = Date()
      }
    }
  }
}

private struct CalendarTimedBlock: View {
  @Environment(\.calendarPresentation) private var presentation
  let placed: WorkspaceCalendarTimedEntry
  let height: CGFloat

  var body: some View {
    let tint = tintColor
    VStack(alignment: .leading, spacing: 1) {
      HStack(alignment: .firstTextBaseline, spacing: 3) {
        if case .task(let task) = placed.entry {
          Image(systemName: CalendarPalette.taskSymbol(task))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(CalendarPalette.taskTint(task))
        }
        Text(placed.entry.title)
          .font(.caption.weight(.semibold))
          .lineLimit(height >= 44 ? 2 : 1)
          .strikethrough(isStruck)
      }
      if height >= 34 {
        Text(subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.leading, 6)
    .padding(.trailing, 3)
    .padding(.vertical, height >= 24 ? 3 : 1)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(tint.opacity(isTask ? 0.10 : 0.20), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    .overlay(alignment: .leading) {
      UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5, style: .continuous)
        .fill(tint)
        .frame(width: 3)
    }
    .overlay {
      if isTask {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(tint.opacity(0.45), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    .opacity(dimmed ? 0.55 : 1)
    .calendarEntryInteractions(placed.entry)
  }

  private var isTask: Bool {
    if case .task = placed.entry { return true }
    return false
  }

  private var tintColor: Color {
    switch placed.entry {
    case .event(let event): presentation.color(for: event)
    case .task(let task): CalendarPalette.taskTint(task)
    }
  }

  private var isStruck: Bool {
    switch placed.entry {
    case .event(let event): event.selfResponse == "declined"
    case .task(let task): task.isCompleted
    }
  }

  private var dimmed: Bool {
    switch placed.entry {
    case .event(let event): event.end < Date() || event.selfResponse == "declined"
    case .task(let task): task.isCompleted
    }
  }

  private var subtitle: String {
    let start = WorkspaceCalendarFormat.timeLabel(minute: placed.startMinute)
    switch placed.entry {
    case .event(let event):
      return [start, event.location].compactMap { $0 }.joined(separator: " · ")
    case .task(let task):
      return [start, task.item.todo].compactMap { $0 }.joined(separator: " · ")
    }
  }
}

// MARK: - Month grid

private struct CalendarMonthGrid: View {
  let days: [WorkspaceCalendarDay]
  let anchor: Date
  let openDay: (Date) -> Void

  var body: some View {
    let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        ForEach(Array((days.prefix(7)).enumerated()), id: \.offset) { _, day in
          Text(day.date, format: .dateTime.weekday(.abbreviated))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.vertical, 6)
      Divider()
      GeometryReader { geometry in
        let rowHeight = geometry.size.height / CGFloat(max(1, weeks.count))
        VStack(spacing: 0) {
          ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
            HStack(spacing: 0) {
              ForEach(week) { day in
                CalendarMonthCell(
                  day: day,
                  isInMonth: Calendar.current.isDate(day.date, equalTo: anchor, toGranularity: .month),
                  rowLimit: max(1, Int((rowHeight - 26) / 17)),
                  openDay: openDay
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .leading) {
                  Rectangle().fill(WorkspaceDesign.hairline).frame(width: 0.5)
                }
              }
            }
            .frame(height: rowHeight)
            .overlay(alignment: .bottom) {
              Rectangle().fill(WorkspaceDesign.hairline).frame(height: 0.5)
            }
          }
        }
      }
    }
  }
}

private struct CalendarMonthCell: View {
  let day: WorkspaceCalendarDay
  let isInMonth: Bool
  let rowLimit: Int
  let openDay: (Date) -> Void
  @State private var isMorePresented = false

  var body: some View {
    let calendar = Calendar.current
    let isToday = calendar.isDateInToday(day.date)
    let entries = day.allEntries
    let folded = WorkspaceCalendarLayout.folded(entries, limit: rowLimit)
    VStack(alignment: .leading, spacing: 1) {
      Button {
        openDay(day.date)
      } label: {
        Text("\(calendar.component(.day, from: day.date))")
          .font(.caption.weight(isToday ? .bold : .medium).monospacedDigit())
          .foregroundStyle(isToday ? Color.white : (isInMonth ? WorkspaceDesign.primaryText : WorkspaceDesign.tertiaryText))
          .frame(minWidth: 18, minHeight: 18)
          .background {
            if isToday { Circle().fill(Color.accentColor) }
          }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Show this day")
      .padding(.bottom, 1)

      ForEach(folded.visible) { entry in
        CalendarMonthRow(entry: entry, day: day)
      }
      if folded.hiddenCount > 0 {
        Button {
          isMorePresented = true
        } label: {
          Text("+\(folded.hiddenCount) more")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isMorePresented, arrowEdge: .bottom) {
          CalendarEntryListPopover(
            title: day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
            subtitle: "\(entries.count) item\(entries.count == 1 ? "" : "s")",
            entries: entries
          )
        }
      }
    }
    .padding(4)
    .background(isToday ? Color.accentColor.opacity(0.05) : Color.clear)
    .opacity(isInMonth ? 1 : 0.6)
  }
}

private struct CalendarMonthRow: View {
  @Environment(\.calendarPresentation) private var presentation
  let entry: WorkspaceCalendarEntry
  let day: WorkspaceCalendarDay

  var body: some View {
    HStack(spacing: 3) {
      switch entry {
      case .event(let event):
        let color = presentation.color(for: event)
        if event.allDay || event.end.timeIntervalSince(event.start) >= 86_400 {
          Text(event.title)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
          Circle().fill(color).frame(width: 6, height: 6)
          Text(event.start, format: .dateTime.hour().minute())
            .foregroundStyle(.secondary)
            .monospacedDigit()
          Text(event.title)
            .lineLimit(1)
            .strikethrough(event.selfResponse == "declined")
        }
      case .task(let task):
        Image(systemName: CalendarPalette.taskSymbol(task))
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(CalendarPalette.taskTint(task))
        Text(task.title)
          .lineLimit(1)
          .strikethrough(task.isCompleted)
          .foregroundStyle(task.isCompleted ? .secondary : .primary)
      }
    }
    .font(.caption2)
    .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
    .contentShape(Rectangle())
    .calendarEntryInteractions(entry)
  }
}

// MARK: - Chips and rows

private struct CalendarChip: View {
  @Environment(\.calendarPresentation) private var presentation
  let entry: WorkspaceCalendarEntry

  var body: some View {
    HStack(spacing: 4) {
      switch entry {
      case .event(let event):
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(presentation.color(for: event))
          .frame(width: 3, height: 12)
        Text(event.title)
          .lineLimit(1)
      case .task(let task):
        Image(systemName: CalendarPalette.taskSymbol(task))
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(CalendarPalette.taskTint(task))
        if let priority = task.item.priority {
          Text(priority)
            .font(.caption2.weight(.bold))
            .foregroundStyle(priority.uppercased() == "A" ? .red : .secondary)
        }
        Text(task.title)
          .lineLimit(1)
          .strikethrough(task.isCompleted)
          .foregroundStyle(task.isCompleted ? .secondary : .primary)
      }
    }
    .font(.caption)
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
    .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    .contentShape(Rectangle())
    .calendarEntryInteractions(entry)
  }

  private var background: Color {
    switch entry {
    case .event(let event): presentation.color(for: event).opacity(0.18)
    case .task: WorkspaceDesign.controlFill
    }
  }
}

private struct CalendarListRow: View {
  @Environment(\.calendarPresentation) private var presentation
  let entry: WorkspaceCalendarEntry

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      switch entry {
      case .event(let event):
        Circle()
          .fill(presentation.color(for: event))
          .frame(width: 8, height: 8)
      case .task(let task):
        Image(systemName: CalendarPalette.taskSymbol(task))
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(CalendarPalette.taskTint(task))
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.title)
          .font(.callout)
          .lineLimit(2)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 6)
    .contentShape(Rectangle())
  }

  private var subtitle: String {
    switch entry {
    case .event(let event):
      return WorkspaceCalendarFormat.whenLabel(for: event)
    case .task(let task):
      let date = task.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
      return [task.item.todo, task.item.kind.capitalized, date, task.item.time]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
  }
}

/// A scrollable list of entries; choosing one shows its details in place.
private struct CalendarEntryListPopover: View {
  let title: String
  let subtitle: String
  let entries: [WorkspaceCalendarEntry]
  @State private var selected: WorkspaceCalendarEntry?

  var body: some View {
    if let selected {
      CalendarEntryInspector(entry: selected) {
        self.selected = nil
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline)
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
              Button {
                selected = entry
              } label: {
                CalendarListRow(entry: entry)
              }
              .buttonStyle(.plain)
              .contextMenu { CalendarEntryMenu(entry: entry) }
              Divider().opacity(0.5)
            }
          }
        }
        .frame(maxHeight: 380)
      }
      .padding(12)
      .frame(width: 340)
    }
  }
}

// MARK: - Interactions

private struct CalendarEntryInteractions: ViewModifier {
  let entry: WorkspaceCalendarEntry
  @State private var isInspecting = false

  func body(content: Content) -> some View {
    content
      .onTapGesture { isInspecting = true }
      .popover(isPresented: $isInspecting, arrowEdge: .trailing) {
        CalendarEntryInspector(entry: entry)
      }
      .contextMenu { CalendarEntryMenu(entry: entry) }
      .help(entry.title)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
  }
}

private extension View {
  func calendarEntryInteractions(_ entry: WorkspaceCalendarEntry) -> some View {
    modifier(CalendarEntryInteractions(entry: entry))
  }
}

private struct CalendarEntryMenu: View {
  @Environment(WorkspaceStore.self) private var store
  let entry: WorkspaceCalendarEntry

  var body: some View {
    switch entry {
    case .event(let event):
      Button {
        Task { await store.askAIChatAboutCalendarEvent(event) }
      } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      let notes = store.calendarLinkedNotes(for: event)
      if let note = notes.first(where: { $0.kind != .person }) {
        Button {
          store.openCalendarLinkedNote(note)
        } label: {
          Label("Open \(note.kind.label)", systemImage: note.kind.systemImage)
        }
      }
      if let url = CalendarLinks.webURL(event.meetingUrl) {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Label("Join Call", systemImage: "video")
        }
      }
      if let url = CalendarLinks.webURL(event.htmlLink) {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
        }
      }
      Divider()
      Button("Copy Title") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(event.title, forType: .string)
      }
    case .task(let task):
      Button {
        store.askAIChatAboutCalendarTask(task)
      } label: {
        Label("Ask AI", systemImage: "sparkles")
      }
      Button {
        store.openCalendarTask(task)
      } label: {
        Label("Open TODO", systemImage: "doc.text")
      }
      if !task.isCompleted {
        Button {
          Task { await store.completeCalendarTask(task) }
        } label: {
          Label("Mark Done", systemImage: "checkmark.circle")
        }
        CalendarScheduleMenu(task: task)
      }
      Divider()
      Button("Copy Reference") {
        store.copyFileReference(path: task.item.file, line: task.item.lineForEditor)
      }
    }
  }
}

private struct CalendarScheduleMenu: View {
  @Environment(WorkspaceStore.self) private var store
  let task: WorkspaceCalendarTask

  var body: some View {
    Menu {
      Button("Today") { schedule(.today) }
      Button("Tomorrow") { schedule(.tomorrow) }
      Button("Next Monday") { schedule(.upcomingMonday) }
      Button("Next Month") { schedule(.nextMonth) }
    } label: {
      Label("Schedule", systemImage: "calendar.badge.clock")
    }
    .help("Set SCHEDULED to a new date")
  }

  private func schedule(_ target: PlanningDateTarget) {
    Task { await store.scheduleCalendarTask(task, target: target) }
  }
}

enum CalendarLinks {
  static func webURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw),
          ["https", "http"].contains(url.scheme?.lowercased() ?? "")
    else { return nil }
    return url
  }
}

// MARK: - Inspectors

private struct CalendarEntryInspector: View {
  let entry: WorkspaceCalendarEntry
  var onBack: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let onBack {
        Button(action: onBack) {
          Label("Back", systemImage: "chevron.left")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
      switch entry {
      case .event(let event):
        CalendarEventInspector(event: event)
      case .task(let task):
        CalendarTaskInspector(task: task)
      }
    }
    .padding(14)
    .frame(width: 340, alignment: .leading)
  }
}

private struct CalendarEventInspector: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.calendarPresentation) private var presentation
  @Environment(\.dismiss) private var dismiss
  let event: CalendarMeetingEvent

  var body: some View {
    let notes = store.calendarLinkedNotes(for: event)
    let attendees = event.otherAttendees
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(presentation.color(for: event))
          .frame(width: 10, height: 10)
          .padding(.top, 4)
        VStack(alignment: .leading, spacing: 3) {
          Text(event.title)
            .font(.headline)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Text(WorkspaceCalendarFormat.whenLabel(for: event))
            .font(.callout)
            .foregroundStyle(.secondary)
          Text(presentation.title(for: event))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }

      if let location = event.location, !location.isEmpty {
        Label(location, systemImage: "mappin.and.ellipse")
          .font(.callout)
          .lineLimit(2)
          .textSelection(.enabled)
      }
      if let response = responseLabel {
        Label(response.text, systemImage: response.symbol)
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 6) {
        Button {
          Task { await store.askAIChatAboutCalendarEvent(event) }
          dismiss()
        } label: {
          Label("Ask AI", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .help("Start a chat with this event and its linked notes as context")
        if let url = CalendarLinks.webURL(event.meetingUrl) {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Label("Join", systemImage: "video")
          }
          .help("Join the video call")
        }
        if canRecord {
          Button {
            Task { await store.recordCalendarMeeting(event) }
            dismiss()
          } label: {
            Label("Record", systemImage: "record.circle")
          }
          .help("Record this meeting into a meeting note")
        }
        Spacer(minLength: 0)
        if let url = CalendarLinks.webURL(event.htmlLink) {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Label("Google Calendar", systemImage: "arrow.up.right.square")
          }
          .labelStyle(.iconOnly)
          .help("Open in Google Calendar")
        }
      }
      .controlSize(.small)

      Divider()

      VStack(alignment: .leading, spacing: 4) {
        Text("Notes")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        if notes.isEmpty {
          Text("No linked notes yet. A meeting note recorded for this event, a note titled like the event, and attendees' person notes show here.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          ForEach(notes) { note in
            Button {
              store.openCalendarLinkedNote(note)
              dismiss()
            } label: {
              HStack(spacing: 7) {
                Image(systemName: note.kind.systemImage)
                  .frame(width: 14)
                  .foregroundStyle(WorkspaceDesign.structuralAccent)
                VStack(alignment: .leading, spacing: 0) {
                  Text(note.title)
                    .font(.callout)
                    .lineLimit(1)
                  Text([note.kind.label, note.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
              }
              .padding(.vertical, 2)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.relativePath(note.file))
          }
        }
      }

      if !attendees.isEmpty {
        Divider()
        VStack(alignment: .leading, spacing: 3) {
          Text("\(attendees.count) attendee\(attendees.count == 1 ? "" : "s")")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(attendeeSummary(attendees))
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if let details = event.details, !details.isEmpty {
        Divider()
        ScrollView {
          Text(CalendarEventDetailsText.attributed(details))
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 110)
      }
    }
  }

  private var canRecord: Bool {
    let now = Date()
    return CalendarRecordingPromptPolicy.isRecordable(event)
      && !store.isRecordingMeeting
      && event.end > now
      && event.start < now.addingTimeInterval(15 * 60)
  }

  private var responseLabel: (text: String, symbol: String)? {
    switch event.selfResponse {
    case "declined": ("You declined", "xmark.circle")
    case "tentative": ("You said maybe", "questionmark.circle")
    case "needsAction": ("You haven't responded", "envelope.badge")
    default: nil
    }
  }

  private func attendeeSummary(_ attendees: [CalendarMeetingAttendee]) -> String {
    let limit = 8
    let names = attendees.prefix(limit).map(\.displayName)
    let rest = attendees.count - names.count
    return names.joined(separator: ", ") + (rest > 0 ? ", and \(rest) more" : "")
  }
}

private struct CalendarTaskInspector: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  let task: WorkspaceCalendarTask

  var body: some View {
    let item = task.item
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        if let todo = item.todo {
          Text(todo)
            .font(.caption.weight(.bold))
            .foregroundStyle(CalendarPalette.taskTint(task))
        }
        if let priority = item.priority {
          Text("[#\(priority)]")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        if task.isOverdue {
          Text("Overdue")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
        }
      }
      Text(task.title)
        .font(.headline)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Text(planningLabel)
        .font(.callout)
        .foregroundStyle(.secondary)
      Text(store.relativePath(item.file))
        .font(.caption)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.middle)
      if !item.tags.isEmpty {
        Text(item.tags.map { ":\($0):" }.joined(separator: " "))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 6) {
        Button {
          store.askAIChatAboutCalendarTask(task)
          dismiss()
        } label: {
          Label("Ask AI", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .help("Start a chat with this TODO as context")
        Button {
          store.openCalendarTask(task)
          dismiss()
        } label: {
          Label("Open", systemImage: "doc.text")
        }
        .help("Open the TODO in its note")
        if !task.isCompleted {
          Button {
            Task { await store.completeCalendarTask(task) }
            dismiss()
          } label: {
            Label("Done", systemImage: "checkmark")
          }
          .help("Mark this TODO done")
          CalendarScheduleMenu(task: task)
            .fixedSize()
        }
      }
      .controlSize(.small)

      if let body = item.body {
        let preview = Org2Display.cleanBlockPreview(body, maxCharacters: 420)
        if !preview.isEmpty {
          Divider()
          Text(preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var planningLabel: String {
    let date = task.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    let time = task.startMinute.map { WorkspaceCalendarFormat.timeLabel(minute: $0) }
    let kind = task.item.kind.capitalized
    return [kind, date, time].compactMap { $0 }.joined(separator: " · ")
  }
}
