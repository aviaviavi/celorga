import Foundation

/// A heading pinned to the sidebar. Its Org `:ID:` finds it wherever it
/// moves; without one, its file and title do.
struct MobilePinnedEntry: Codable, Hashable, Identifiable {
  let path: String
  let title: String
  let line: Int
  let nodeID: String?

  var id: String {
    if let nodeID { return "id:\(nodeID)" }
    return "\(path)::\(title)"
  }

  var fileName: String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }

  /// The Org link the reader resolves to open this heading.
  var linkTarget: String {
    if let nodeID { return "id:\(nodeID)" }
    return "file:\(path)::*\(title)"
  }

  init(path: String, title: String, line: Int, nodeID: String?) {
    self.path = path
    self.title = title
    self.line = line
    let trimmed = nodeID?.trimmingCharacters(in: .whitespaces)
    self.nodeID = trimmed?.isEmpty == false ? trimmed : nil
  }

  init(entry: MobileSearchEntry) {
    self.init(path: entry.path, title: entry.title, line: entry.line, nodeID: entry.nodeID)
  }
}

/// Pinned files and entries, kept on this phone for each paired host.
struct MobilePins: Codable, Equatable {
  var files: [String] = []
  var entries: [MobilePinnedEntry] = []

  var isEmpty: Bool { files.isEmpty && entries.isEmpty }

  static func defaultsKey(hostKey: String) -> String {
    "org2.mobile.pins.v1.\(hostKey)"
  }

  static func load(hostKey: String, defaults: UserDefaults = .standard) -> MobilePins {
    guard let data = defaults.data(forKey: defaultsKey(hostKey: hostKey)),
          let pins = try? JSONDecoder().decode(MobilePins.self, from: data)
    else { return MobilePins() }
    return pins
  }

  func save(hostKey: String, defaults: UserDefaults = .standard) {
    if isEmpty {
      defaults.removeObject(forKey: Self.defaultsKey(hostKey: hostKey))
    } else if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.defaultsKey(hostKey: hostKey))
    }
  }
}

/// A document the sidebar opens directly: a pinned file or entry, or a
/// daily note.
enum MobileDocumentDestination: Hashable {
  case file(String)
  case entry(MobilePinnedEntry)
  case daily(Date)
}

enum MobileDailyNoteTarget: CaseIterable, Identifiable {
  case today
  case yesterday
  case tomorrow

  var id: Self { self }

  var title: String {
    switch self {
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .tomorrow: "Tomorrow"
    }
  }

  var systemImage: String { self == .today ? "sun.max" : "calendar" }

  func date(relativeTo now: Date = Date(), calendar: Calendar = .current) -> Date {
    let offset = switch self {
    case .today: 0
    case .yesterday: -1
    case .tomorrow: 1
    }
    return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) ?? now
  }

  /// The `yyyy-MM-dd` date the host's daily note endpoint expects.
  static func requestDate(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
  }
}

extension CorpusStore {
  func isPinned(path: String) -> Bool {
    pins.files.contains(path)
  }

  func togglePin(path: String) {
    if let index = pins.files.firstIndex(of: path) {
      pins.files.remove(at: index)
    } else {
      pins.files.append(path)
    }
    pins.save(hostKey: hostKey)
  }

  func isPinned(entry: MobilePinnedEntry) -> Bool {
    pins.entries.contains { $0.id == entry.id }
  }

  func togglePin(entry: MobilePinnedEntry) {
    if let index = pins.entries.firstIndex(where: { $0.id == entry.id }) {
      pins.entries.remove(at: index)
    } else {
      pins.entries.append(entry)
    }
    pins.save(hostKey: hostKey)
  }

  /// The headings of a loaded file, for choosing one to pin.
  func documentEntries(preview: CorpusFilePreview) async -> [MobileSearchEntry] {
    let sequences = todoSequences
    return await Task.detached(priority: .userInitiated) {
      let entries = try? MobileDocumentRuntime().index(
        source: preview.content,
        path: preview.relativePath,
        sequences: sequences
      )
      return (entries ?? []).filter { $0.line > 0 }
    }.value
  }
}
