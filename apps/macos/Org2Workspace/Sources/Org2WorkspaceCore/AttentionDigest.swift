import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// `celorga workspace attention --json` (`org2:attention-digest:v1`). The CLI
/// owns every decision about what needs the person; the app only schedules the
/// command, shows its notification, and records delivery.
public struct AttentionDigestPayload: Decodable, Equatable, Sendable {
  public struct Evidence: Decodable, Equatable, Sendable {
    public let kind: String
    public let ref: String
    public let path: String?
    public let line: Int?
    public let detail: String?
  }

  public struct Item: Decodable, Equatable, Identifiable, Sendable {
    public let fingerprint: String
    public let category: String
    public let title: String
    public let summary: String
    public let ref: String
    public let evidence: [Evidence]
    public let at: String?
    public let command: String?
    public let delivered: Bool
    public var id: String { fingerprint }
  }

  public struct QuietHours: Decodable, Equatable, Sendable {
    public let start: String
    public let end: String
  }

  public struct Preferences: Decodable, Equatable, Sendable {
    public let morningBrief: String?
    public let checkIntervalMinutes: Int
    public let quietHours: QuietHours?
  }

  public struct Notification: Decodable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let fingerprints: [String]
  }

  public struct Delivery: Decodable, Equatable, Sendable {
    public let revision: String?
    public let applied: Bool
    public let marked: [String]
  }

  public let schema: String
  public let generatedAt: String
  public let mode: String
  public let items: [Item]
  public let interrupt: Bool
  public let interruptReason: String
  public let notification: Notification?
  public let preferences: Preferences
  public let delivery: Delivery
}

public struct AttentionClockTime: Equatable, Sendable {
  public let hour: Int
  public let minute: Int

  public init?(_ text: String?) {
    guard let text else { return nil }
    let parts = text.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
          (0..<24).contains(hour), (0..<60).contains(minute)
    else { return nil }
    self.hour = hour
    self.minute = minute
  }

  public var minutesOfDay: Int { hour * 60 + minute }
}

/// Cadence from the corpus's `attention` preferences, as echoed by the CLI.
public struct AttentionSchedule: Equatable, Sendable {
  public var morningBrief: AttentionClockTime?
  public var checkIntervalMinutes: Int
  public var quietStart: AttentionClockTime?
  public var quietEnd: AttentionClockTime?

  public static let `default` = AttentionSchedule(
    morningBrief: AttentionClockTime("08:00"), checkIntervalMinutes: 120, quietStart: nil, quietEnd: nil
  )

  public init(morningBrief: AttentionClockTime?, checkIntervalMinutes: Int, quietStart: AttentionClockTime?, quietEnd: AttentionClockTime?) {
    self.morningBrief = morningBrief
    self.checkIntervalMinutes = checkIntervalMinutes
    self.quietStart = quietStart
    self.quietEnd = quietEnd
  }

  public init(preferences: AttentionDigestPayload.Preferences) {
    morningBrief = AttentionClockTime(preferences.morningBrief)
    checkIntervalMinutes = max(0, preferences.checkIntervalMinutes)
    quietStart = AttentionClockTime(preferences.quietHours?.start)
    quietEnd = AttentionClockTime(preferences.quietHours?.end)
  }
}

public struct AttentionScheduleState: Codable, Equatable, Sendable {
  /// Local `yyyy-MM-dd` of the last morning brief.
  public var lastBriefDay: String?
  public var lastCheckAt: Date?

  public init(lastBriefDay: String? = nil, lastCheckAt: Date? = nil) {
    self.lastBriefDay = lastBriefDay
    self.lastCheckAt = lastCheckAt
  }
}

public enum AttentionScheduleDecision: Equatable, Sendable {
  case wait
  case brief
  case check
}

/// Deterministic cadence: no checks in quiet hours, one brief per day within
/// a few hours of its time, otherwise a check every interval.
public enum AttentionScheduler {
  /// A brief missed by more than this (for example, the Mac was asleep) is skipped for the day.
  public static let briefWindowMinutes = 6 * 60

  public static func dayKey(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func minutesOfDay(_ date: Date, calendar: Calendar) -> Int {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
  }

  public static func isQuiet(_ now: Date, schedule: AttentionSchedule, calendar: Calendar) -> Bool {
    guard let start = schedule.quietStart?.minutesOfDay, let end = schedule.quietEnd?.minutesOfDay, start != end else { return false }
    let current = minutesOfDay(now, calendar: calendar)
    return start < end ? (current >= start && current < end) : (current >= start || current < end)
  }

  public static func decide(
    now: Date, schedule: AttentionSchedule, state: AttentionScheduleState, calendar: Calendar = .current
  ) -> AttentionScheduleDecision {
    if isQuiet(now, schedule: schedule, calendar: calendar) { return .wait }
    if let brief = schedule.morningBrief, state.lastBriefDay != dayKey(now, calendar: calendar) {
      let sinceBrief = minutesOfDay(now, calendar: calendar) - brief.minutesOfDay
      if sinceBrief >= 0 && sinceBrief < briefWindowMinutes { return .brief }
    }
    guard schedule.checkIntervalMinutes > 0 else { return .wait }
    if let last = state.lastCheckAt, now.timeIntervalSince(last) < Double(schedule.checkIntervalMinutes) * 60 {
      return .wait
    }
    return .check
  }

  public static func recording(
    _ decision: AttentionScheduleDecision, at now: Date, in state: AttentionScheduleState, calendar: Calendar = .current
  ) -> AttentionScheduleState {
    var next = state
    switch decision {
    case .wait: return state
    case .brief:
      next.lastBriefDay = dayKey(now, calendar: calendar)
      next.lastCheckAt = now
    case .check:
      next.lastCheckAt = now
    }
    return next
  }
}

public enum AttentionDigestCommand {
  public static func digestArguments(corpusRoot: String, mode: AttentionScheduleDecision) -> [String] {
    ["workspace", "attention", "--dir", corpusRoot, "--mode", mode == .brief ? "brief" : "check", "--json"]
  }

  /// Marks exactly the fingerprints the notification showed, guarded by the ledger revision it was derived from.
  public static func markArguments(corpusRoot: String, fingerprints: [String], revision: String?) -> [String] {
    var arguments = ["workspace", "attention", "--dir", corpusRoot, "--mark-delivered"]
    for fingerprint in fingerprints { arguments += ["--fingerprint", fingerprint] }
    arguments += ["--if-revision", revision ?? "absent", "--apply", "--json"]
    return arguments
  }
}

/// Opt-in desktop monitor. Off by default; when on, it runs the digest on the
/// configured cadence and posts one notification per interrupt.
@MainActor
public final class AttentionDigestMonitor: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  public static let enabledKey = "Org2Workspace.attention.enabled.v1"
  private static let stateKeyPrefix = "Org2Workspace.attention.state.v1:"
  nonisolated private static let notificationCategory = "celorga.attention"
  private static let tickNanoseconds: UInt64 = 60 * 1_000_000_000

  @Published public private(set) var isEnabled: Bool
  @Published public private(set) var digest: AttentionDigestPayload?
  @Published public private(set) var lastRunAt: Date?
  @Published public private(set) var statusText = "Attention notifications are off"
  @Published public private(set) var errorText: String?
  @Published public private(set) var isRunning = false

  private let defaults: UserDefaults
  private weak var store: WorkspaceStore?
  private var tickTask: Task<Void, Never>?
  private var schedule = AttentionSchedule.default
  private var window: NSWindow?

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    super.init()
  }

  /// User notifications need a real app bundle; tests and command-line hosts skip them.
  private static var canUseUserNotifications: Bool {
    Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
  }

  public func attach(to store: WorkspaceStore) {
    self.store = store
    if Self.canUseUserNotifications {
      UNUserNotificationCenter.current().delegate = self
    }
    if isEnabled { start() }
  }

  public func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    if enabled {
      if Self.canUseUserNotifications {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
      }
      start()
    } else {
      tickTask?.cancel()
      tickTask = nil
      statusText = "Attention notifications are off"
    }
  }

  public var scheduleSummary: String {
    var parts: [String] = []
    if let brief = schedule.morningBrief {
      parts.append(String(format: "Morning brief at %02d:%02d", brief.hour, brief.minute))
    } else {
      parts.append("No morning brief")
    }
    parts.append(schedule.checkIntervalMinutes > 0 ? "checks every \(schedule.checkIntervalMinutes) min" : "no periodic checks")
    if let start = schedule.quietStart, let end = schedule.quietEnd {
      parts.append(String(format: "quiet %02d:%02d–%02d:%02d", start.hour, start.minute, end.hour, end.minute))
    }
    return parts.joined(separator: ", ")
  }

  private func start() {
    guard tickTask == nil else { return }
    statusText = "Waiting for the next attention check"
    tickTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.tick()
        do { try await Task.sleep(nanoseconds: Self.tickNanoseconds) } catch { return }
      }
    }
  }

  private func stateKey(_ root: URL) -> String { Self.stateKeyPrefix + root.standardizedFileURL.path }

  private func loadState(_ root: URL) -> AttentionScheduleState {
    defaults.data(forKey: stateKey(root)).flatMap { try? JSONDecoder().decode(AttentionScheduleState.self, from: $0) }
      ?? AttentionScheduleState()
  }

  private func saveState(_ state: AttentionScheduleState, root: URL) {
    if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey(root)) }
  }

  func tick(now: Date = Date()) async {
    guard isEnabled, !isRunning, let store, let root = store.corpusRoot else { return }
    let state = loadState(root)
    let decision = AttentionScheduler.decide(now: now, schedule: schedule, state: state)
    guard decision != .wait else { return }
    saveState(AttentionScheduler.recording(decision, at: now, in: state), root: root)
    await run(decision, notify: true)
  }

  /// Runs the digest now. `notify` posts and records delivery when the CLI says to interrupt.
  public func run(_ decision: AttentionScheduleDecision = .check, notify: Bool) async {
    guard let store, let root = store.corpusRoot else {
      errorText = "Choose a corpus first"
      return
    }
    isRunning = true
    defer { isRunning = false }
    let cli = store.cli
    do {
      let payload: AttentionDigestPayload = try await cli.runJSON(
        AttentionDigestCommand.digestArguments(corpusRoot: root.path, mode: decision)
      )
      digest = payload
      schedule = AttentionSchedule(preferences: payload.preferences)
      lastRunAt = Date()
      errorText = nil
      statusText = payload.interruptReason
      if notify, payload.interrupt, let notification = payload.notification {
        post(notification)
        let _: AttentionDigestPayload = try await cli.runJSON(AttentionDigestCommand.markArguments(
          corpusRoot: root.path, fingerprints: notification.fingerprints, revision: payload.delivery.revision
        ))
      }
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func post(_ notification: AttentionDigestPayload.Notification) {
    guard Self.canUseUserNotifications else { return }
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.categoryIdentifier = Self.notificationCategory
    content.threadIdentifier = Self.notificationCategory
    let request = UNNotificationRequest(identifier: "celorga.attention.\(UUID().uuidString)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { _ in }
  }

  public nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  public nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard response.notification.request.content.categoryIdentifier == Self.notificationCategory else { return }
    await MainActor.run { self.showDigestWindow() }
  }

  public func showDigestWindow() {
    guard let store else { return }
    NSApplication.shared.activate(ignoringOtherApps: true)
    let window = self.window ?? {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: true
      )
      window.title = "Needs You"
      window.isReleasedWhenClosed = false
      window.center()
      return window
    }()
    window.contentView = NSHostingView(rootView: AttentionDigestView(monitor: self, store: store))
    window.makeKeyAndOrderFront(nil)
    self.window = window
    if digest == nil { Task { await run(.check, notify: false) } }
  }
}

struct AttentionDigestView: View {
  @ObservedObject var monitor: AttentionDigestMonitor
  let store: WorkspaceStore

  private static let categoryTitles: [String: String] = [
    "approval": "Approvals", "blocked": "Blocked", "review": "Reviews", "reply": "Replies",
    "failed": "Failed", "overdue": "Overdue", "today": "Today",
  ]
  private static let order = ["approval", "blocked", "review", "reply", "failed", "overdue", "today"]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(monitor.digest?.interruptReason ?? monitor.statusText)
          .font(.headline)
        Spacer()
        Button("Refresh") { Task { await monitor.run(.check, notify: false) } }
          .disabled(monitor.isRunning)
      }
      if let error = monitor.errorText {
        Text(error).font(.callout).foregroundStyle(.red)
      }
      if let items = monitor.digest?.items, !items.isEmpty {
        List {
          ForEach(Self.order, id: \.self) { category in
            let group = items.filter { $0.category == category }
            if !group.isEmpty {
              Section(Self.categoryTitles[category] ?? category) {
                ForEach(group) { item in row(item) }
              }
            }
          }
        }
      } else if monitor.digest != nil {
        Text("Nothing needs you.").foregroundStyle(.secondary)
        Spacer()
      } else {
        ProgressView().frame(maxWidth: .infinity)
        Spacer()
      }
    }
    .padding(12)
    .frame(minWidth: 420, minHeight: 320)
  }

  private func row(_ item: AttentionDigestPayload.Item) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(item.title).fontWeight(item.delivered ? .regular : .semibold)
          if !item.delivered { Text("New").font(.caption).foregroundStyle(.orange) }
        }
        Text(item.summary).font(.callout).foregroundStyle(.secondary)
        Text(item.ref).font(.caption.monospaced()).foregroundStyle(.tertiary)
      }
      Spacer()
      Button("Open") { open(item) }
    }
  }

  private func open(_ item: AttentionDigestPayload.Item) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    if item.ref.hasPrefix("thread:"), let id = UUID(uuidString: String(item.ref.dropFirst("thread:".count))) {
      store.openAIChatThreadLink(id)
    } else if item.category == "approval" || item.category == "review" {
      store.openReviewQueue()
    } else if let file = item.evidence.first(where: { $0.kind == "file" && $0.path != nil }) ?? item.evidence.first(where: { $0.path != nil }),
              let path = file.path {
      store.openFileInEditor(path: path, line: file.line ?? 1)
    }
    NSApplication.shared.windows.first { $0.isVisible && $0.title != "Needs You" && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
  }
}
