import AppKit
import SwiftUI

/// A small floating panel that offers to record a synced calendar meeting as
/// it starts. It does not take focus from the call app, and it closes itself
/// once the meeting is recorded, dismissed, or out of its window.
@MainActor
public final class CalendarRecordingPromptPanel {
  private static var shared: CalendarRecordingPromptPanel?

  private weak var store: WorkspaceStore?
  private var panel: NSPanel?

  /// Connects the store's prompt to this panel. Desktop app only.
  public static func install(on store: WorkspaceStore) {
    let controller = shared ?? CalendarRecordingPromptPanel()
    controller.store = store
    shared = controller
    store.calendarRecordingPromptPresenter = { [weak controller] event in
      if let event { controller?.show(event) } else { controller?.close() }
    }
  }

  private func show(_ event: CalendarMeetingEvent) {
    guard let store else { return }
    let content = CalendarRecordingPromptView(
      event: event,
      record: { [weak store] join in
        Task { await store?.recordCalendarMeeting(event, joinCall: join) }
      },
      dismiss: { [weak store] in store?.dismissCalendarRecordingPrompt() }
    )
    let hosting = NSHostingView(rootView: content)
    hosting.setFrameSize(hosting.fittingSize)
    let panel = self.panel ?? makePanel()
    panel.contentView = hosting
    panel.setContentSize(hosting.fittingSize)
    if let screen = NSScreen.main ?? NSScreen.screens.first {
      let visible = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(
        x: visible.maxX - panel.frame.width - 16,
        y: visible.maxY - panel.frame.height - 16
      ))
    }
    panel.orderFrontRegardless()
    self.panel = panel
    NSSound(named: "Glass")?.play()
  }

  private func close() {
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
      styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
      backing: .buffered,
      defer: true
    )
    panel.title = "Celorga"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    return panel
  }
}

struct CalendarRecordingPromptView: View {
  let event: CalendarMeetingEvent
  let record: (_ joinCall: Bool) -> Void
  let dismiss: () -> Void

  private var timeText: String {
    let start = event.start.formatted(date: .omitted, time: .shortened)
    let end = event.end.formatted(date: .omitted, time: .shortened)
    return "\(start) – \(end)"
  }

  private var attendeeText: String? {
    let people = event.otherAttendees
    guard !people.isEmpty else { return nil }
    let names = people.prefix(3).map(\.displayName).joined(separator: ", ")
    return people.count > 3 ? "\(names) +\(people.count - 3)" : names
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "record.circle")
          .font(.title2)
          .foregroundStyle(.red)
        VStack(alignment: .leading, spacing: 3) {
          Text(event.start > Date() ? "Meeting starting" : "Meeting started")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(event.title)
            .font(.headline)
            .lineLimit(2)
          Text(timeText)
            .font(.callout)
            .foregroundStyle(.secondary)
          if let attendeeText {
            Label(attendeeText, systemImage: "person.2")
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      HStack(spacing: 8) {
        Button("Not Now", action: dismiss)
          .keyboardShortcut(.cancelAction)
        Spacer()
        if event.meetingUrl != nil {
          Button("Join & Record") { record(true) }
            .help("Open the call link and start recording")
        }
        Button("Record") { record(false) }
          .keyboardShortcut(.defaultAction)
          .help("Record this meeting; its title, time, and attendees are filled in")
      }
      .controlSize(.regular)
    }
    .padding(16)
    .frame(width: 360)
  }
}
