import Foundation

enum MobileNoteSchedule: String, CaseIterable, Identifiable {
  case none
  case today
  case tomorrow
  case nextWeek
  case nextMonth
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .none: "No Schedule"
    case .today: "Today"
    case .tomorrow: "Tomorrow"
    case .nextWeek: "Next Week"
    case .nextMonth: "Next Month"
    case .custom: "Pick Date"
    }
  }

  var systemImage: String {
    switch self {
    case .none: "calendar.badge.minus"
    case .today: "calendar"
    case .tomorrow: "calendar.badge.clock"
    case .nextWeek: "calendar.badge.plus"
    case .nextMonth: "calendar.circle"
    case .custom: "calendar.badge.plus"
    }
  }

  func scheduledDate(customDate: Date, calendar: Calendar = .current) -> Date? {
    let today = calendar.startOfDay(for: Date())
    switch self {
    case .none:
      return nil
    case .today:
      return today
    case .tomorrow:
      return calendar.date(byAdding: .day, value: 1, to: today)
    case .nextWeek:
      return calendar.date(byAdding: .weekOfYear, value: 1, to: today)
    case .nextMonth:
      return calendar.date(byAdding: .month, value: 1, to: today)
    case .custom:
      return calendar.startOfDay(for: customDate)
    }
  }
}

struct NoteAttachment: Identifiable, Hashable {
  let id = UUID()
  let filename: String
  let data: Data
}

/// Builds the Org entry for a phone capture. The entry is queued on the
/// phone and sent to the paired host, which appends it to the corpus mobile
/// inbox; the phone itself holds no corpus.
enum MobileCaptureWriter {
  static let appGroupID = "group.org.org2.mobile"
  static let mobileInboxFilename = "mobile-inbox.org"
  static let mobileInboxAssetsDirectory = "mobile-inbox-assets"

  static var sharedDefaults: UserDefaults {
    UserDefaults(suiteName: appGroupID) ?? .standard
  }

  static func newEntryID(kind: String, now: Date = Date()) -> String {
    let fileStamp = ISO8601DateFormatter().string(from: now)
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: ".", with: "")
    return "\(fileStamp)-\(kind)-\(UUID().uuidString.prefix(8))"
  }

  /// A note, or a scheduled TODO when `scheduledDate` is set.
  static func noteCapture(
    title: String,
    body: String,
    attachments: [NoteAttachment] = [],
    scheduledDate: Date? = nil,
    now: Date = Date()
  ) -> MobileCaptureOutbox.Item {
    let entryID = newEntryID(kind: "note", now: now)
    let createdAt = ISO8601DateFormatter().string(from: now)
    let sanitizedTitle = sanitizeProperty(title)
    let noteTitle = sanitizedTitle.isEmpty ? "Phone note" : sanitizedTitle
    let bodyText = escapeHeadingLines(body.trimmingCharacters(in: .whitespacesAndNewlines))
    let planningLine = scheduledDate.map { "SCHEDULED: \(orgDayTimestamp($0))\n" } ?? ""
    let headingPrefix = scheduledDate == nil ? "*" : "* TODO"
    let bodySection = bodyText.isEmpty ? "" : "\n\(bodyText)\n"
    let content = """
    \(headingPrefix) \(noteTitle)
    \(planningLine):PROPERTIES:
    :ID: mobile-\(entryID)
    :KIND: mobile-note
    :STATUS: pending
    :DAILY_DATE: \(orgDayString(now))
    :CREATED_AT: \(createdAt)
    :SOURCE: org2-mobile
    :END:
    \(bodySection)\(attachmentsSection(attachments, entryID: entryID))
    """
    return MobileCaptureOutbox.Item(
      entryID: entryID,
      title: noteTitle,
      content: content,
      attachments: attachments.map { .init(filename: $0.filename, data: $0.data) },
      createdAt: now
    )
  }

  private static func attachmentsSection(_ attachments: [NoteAttachment], entryID: String) -> String {
    guard !attachments.isEmpty else { return "" }
    let links = attachments
      .map { "- [[file:\(mobileInboxAssetsDirectory)/\(entryID)/\($0.filename)][\($0.filename)]]" }
      .joined(separator: "\n")
    return "\nAttachments:\n\(links)\n"
  }

  /// Body text that starts a line with `*` would become a sibling heading in
  /// the inbox; a leading comma keeps it literal, as in Org source blocks.
  static func escapeHeadingLines(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in line.first == "*" ? ",\(line)" : String(line) }
      .joined(separator: "\n")
  }

  static func orgDayString(_ date: Date) -> String {
    orgDayFormatter.string(from: date)
  }

  static func orgDayTimestamp(_ date: Date) -> String {
    "<\(orgPlanningDayFormatter.string(from: date))>"
  }

  static func sanitizeProperty(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let orgDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let orgPlanningDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd EEE"
    return formatter
  }()
}

/// Captures waiting to reach the host. The app and the share extension both
/// queue here (in the shared app group); the app sends the queue whenever it
/// can reach the host, and an entry leaves the queue only after the host has
/// stored it.
enum MobileCaptureOutbox {
  struct Attachment: Codable, Hashable, Sendable {
    let filename: String
    let data: Data
  }

  struct Item: Codable, Hashable, Identifiable, Sendable {
    let entryID: String
    let title: String
    let content: String
    let attachments: [Attachment]
    let createdAt: Date
    var id: String { entryID }
  }

  static var directory: URL {
    let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MobileCaptureWriter.appGroupID)
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("CaptureOutbox", isDirectory: true)
  }

  static func enqueue(_ item: Item, in directory: URL = directory) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(item)
    try data.write(to: directory.appendingPathComponent("\(item.entryID).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  static func pending(in directory: URL = directory) -> [Item] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return urls
      .filter { $0.pathExtension == "json" }
      .compactMap { try? JSONDecoder().decode(Item.self, from: Data(contentsOf: $0)) }
      .sorted { $0.createdAt < $1.createdAt }
  }

  static func remove(entryID: String, in directory: URL = directory) {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(entryID).json"))
  }
}
