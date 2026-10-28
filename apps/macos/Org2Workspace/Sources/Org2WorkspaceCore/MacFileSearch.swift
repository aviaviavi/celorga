import AppKit
import Foundation
import UniformTypeIdentifiers

// Search › This Mac: find files and folders anywhere under the indexed
// folders (by default the home folder and cloud drives). The search worker
// owns the index (`celorga files`); the app only queries it and acts on
// results.

public struct MacFileSearchCopy: Decodable, Sendable, Equatable, Identifiable {
  public let path: String
  public let directory: String
  public let size: Int64
  public let modifiedAt: Date
  /// True when the copy has the same bytes as the newest file; nil when not checked.
  public let identical: Bool?

  public var id: String { path }
}

public struct MacFileSearchResult: Decodable, Sendable, Equatable, Identifiable {
  public let path: String
  public let name: String
  public let directory: String
  public let kind: String
  public let `extension`: String
  public let isDirectory: Bool
  public let size: Int64
  public let modifiedAt: Date
  public let score: Double
  public let copyCount: Int
  public let copies: [MacFileSearchCopy]

  public var id: String { "mac-file:\(path)" }
  public var url: URL { URL(fileURLWithPath: path) }
  var isFolder: Bool { kind == "folder" }
}

public struct MacFileSearchIndexStatus: Decodable, Sendable, Equatable {
  public let path: String
  public let builtAt: Date?
  public let building: Bool
  public let entries: Int
  public let roots: [String]
  public let stale: Bool
}

public struct MacFileSearchPayload: Decodable, Sendable {
  public let query: String
  public let index: MacFileSearchIndexStatus
  public let results: [MacFileSearchResult]
  public let elapsedMs: Int

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    query = try container.decode(String.self, forKey: .query)
    index = try container.decode(MacFileSearchIndexStatus.self, forKey: .index)
    results = try container.decode([MacFileSearchResult].self, forKey: .results)
    elapsedMs = try container.decodeIfPresent(Int.self, forKey: .elapsedMs) ?? 0
  }

  enum CodingKeys: String, CodingKey {
    case query, index, results, elapsedMs
  }
}

public struct MacFileSearchConfig: Decodable, Sendable, Equatable {
  public let roots: [String]
  public let exclude: [String]
  public let includeHidden: Bool
}

struct MacFileSearchConfigEnvelope: Decodable, Sendable {
  let config: MacFileSearchConfig
}

/// The worker writes ISO 8601 dates with milliseconds (JavaScript `toISOString`).
enum MacFileSearchDates {
  // ISO8601DateFormatter is thread-safe.
  nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  nonisolated(unsafe) private static let whole = ISO8601DateFormatter()

  static func parse(_ text: String) -> Date? {
    fractional.date(from: text) ?? whole.date(from: text)
  }
}

extension MacFileSearchCopy {
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    directory = try container.decode(String.self, forKey: .directory)
    size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
    modifiedAt = MacFileSearchDates.parse(try container.decode(String.self, forKey: .modifiedAt)) ?? .distantPast
    identical = try container.decodeIfPresent(Bool.self, forKey: .identical)
  }

  enum CodingKeys: String, CodingKey {
    case path, directory, size, modifiedAt, identical
  }
}

extension MacFileSearchResult {
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    name = try container.decode(String.self, forKey: .name)
    directory = try container.decode(String.self, forKey: .directory)
    kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "other"
    self.extension = try container.decodeIfPresent(String.self, forKey: .extension) ?? ""
    isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
    size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
    modifiedAt = MacFileSearchDates.parse(try container.decode(String.self, forKey: .modifiedAt)) ?? .distantPast
    score = try container.decodeIfPresent(Double.self, forKey: .score) ?? 0
    copyCount = try container.decodeIfPresent(Int.self, forKey: .copyCount) ?? 0
    copies = try container.decodeIfPresent([MacFileSearchCopy].self, forKey: .copies) ?? []
  }

  enum CodingKeys: String, CodingKey {
    case path, name, directory, kind, `extension`, isDirectory, size, modifiedAt, score, copyCount, copies
  }
}

extension MacFileSearchIndexStatus {
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    builtAt = try container.decodeIfPresent(String.self, forKey: .builtAt).flatMap(MacFileSearchDates.parse)
    building = try container.decodeIfPresent(Bool.self, forKey: .building) ?? false
    entries = try container.decodeIfPresent(Int.self, forKey: .entries) ?? 0
    roots = try container.decodeIfPresent([String].self, forKey: .roots) ?? []
    stale = try container.decodeIfPresent(Bool.self, forKey: .stale) ?? false
  }

  enum CodingKeys: String, CodingKey {
    case path, builtAt, building, entries, roots, stale
  }
}

/// Display helpers shared by the rows and menus.
enum MacFileSearchDisplay {
  static func abbreviated(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }

  static func relativeDate(_ date: Date, now: Date = Date()) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: now)
  }

  static func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  static func metadata(_ result: MacFileSearchResult) -> String {
    var parts = [abbreviated(result.directory)]
    // Folders and folder-shaped documents (.numbers, .key, .app) have no single size.
    if !result.isDirectory { parts.append(size(result.size)) }
    parts.append(relativeDate(result.modifiedAt))
    return parts.joined(separator: " · ")
  }

  static func copiesLabel(_ count: Int) -> String {
    "+\(count) older cop\(count == 1 ? "y" : "ies")"
  }

  static func indexSummary(_ index: MacFileSearchIndexStatus?) -> String? {
    guard let index else { return nil }
    let count = index.entries.formatted()
    if index.building { return "Indexing… \(count) found" }
    return "\(count) files indexed"
  }

  static func orgLink(_ path: String, name: String) -> String {
    "[[file:\(path)][\(name.replacingOccurrences(of: "]", with: ")"))]]"
  }

  @MainActor private static var iconCache: [String: NSImage] = [:]

  /// File icons by type, so rendering never reads (or downloads) the file.
  /// Applications use their own icon.
  @MainActor static func icon(for result: MacFileSearchResult) -> NSImage {
    let key = result.isFolder ? "/folder" : result.kind == "app" ? result.path : "." + result.extension.lowercased()
    if let cached = iconCache[key] { return cached }
    let image: NSImage
    if result.isFolder {
      image = NSWorkspace.shared.icon(for: .folder)
    } else if result.kind == "app" {
      image = NSWorkspace.shared.icon(forFile: result.path)
    } else if let type = UTType(filenameExtension: result.extension) {
      image = NSWorkspace.shared.icon(for: type)
    } else {
      image = NSWorkspace.shared.icon(for: .data)
    }
    if iconCache.count > 500 { iconCache.removeAll() }
    iconCache[key] = image
    return image
  }
}

extension WorkspaceStore {
  /// Searches this Mac's files for `query` (empty: recent documents). While
  /// the worker is still building the index, asks again until it finishes so
  /// results fill in.
  public func runMacFileSearch(_ query: String) {
    macFileSearchGeneration &+= 1
    let generation = macFileSearchGeneration
    macFileSearchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    isSearchingMacFiles = true
    let cli = cli
    macFileSearchTask = Task { [weak self] in
      while !Task.isCancelled {
        let outcome: Result<MacFileSearchPayload, Error>
        do {
          outcome = .success(try await cli.searchMacFiles(trimmed, limit: 60))
        } catch {
          outcome = .failure(error)
        }
        guard !Task.isCancelled, let self, self.macFileSearchGeneration == generation else { return }
        switch outcome {
        case .success(let payload):
          self.macFileSearchResults = payload.results
          self.macFileSearchResultsQuery = trimmed
          self.macFileSearchIndex = payload.index
          self.macFileSearchError = nil
          guard payload.index.building else {
            self.isSearchingMacFiles = false
            return
          }
        case .failure(let error):
          if error is CancellationError { return }
          self.isSearchingMacFiles = false
          self.macFileSearchResultsQuery = trimmed
          self.macFileSearchError = "File search failed: \(error.localizedDescription)"
          return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  /// Starts loading the file index so the first search is fast.
  public func warmMacFileSearch() {
    guard cli.hasSearchService else { return }
    let cli = cli
    Task.detached(priority: .utility) { await cli.prewarmMacFileSearch() }
  }

  public func loadMacFileSearchConfig() async {
    do {
      let envelope: MacFileSearchConfigEnvelope = try await cli.runJSON(["files", "config", "--json"])
      macFileSearchConfig = envelope.config
    } catch {
      macFileSearchError = "Could not read file search folders: \(error.localizedDescription)"
    }
  }

  /// Applies a folder change through `celorga files config`; the worker
  /// notices the new config and rebuilds the index.
  public func updateMacFileSearchConfig(_ arguments: [String]) async {
    do {
      let envelope: MacFileSearchConfigEnvelope = try await cli.runJSON(["files", "config"] + arguments + ["--apply", "--json"])
      macFileSearchConfig = envelope.config
      runMacFileSearch(searchMode == .files ? searchQuery : "")
    } catch {
      macFileSearchError = "Could not change file search folders: \(error.localizedDescription)"
    }
  }

  public func addMacFileSearchFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Search This Folder"
    panel.message = "Choose folders for Search › This Mac."
    guard panel.runModal() == .OK else { return }
    let arguments = panel.urls.flatMap { ["--add-root", $0.standardizedFileURL.path] }
    guard !arguments.isEmpty else { return }
    Task { await updateMacFileSearchConfig(arguments) }
  }

  public func rebuildMacFileSearchIndex() {
    let cli = cli
    Task { [weak self] in
      _ = try? await cli.searchMacFiles("", limit: 1, rebuild: true)
      guard let self else { return }
      self.runMacFileSearch(self.searchQuery)
    }
  }

  /// Opens a result: corpus files open in Celorga, everything else in its
  /// default app (folders in Finder).
  public func openMacFileSearchResult(_ result: MacFileSearchResult) {
    if let file = corpusFiles.first(where: { $0.path == result.path }) {
      selectSearchFile(file)
      return
    }
    if NSWorkspace.shared.open(result.url) {
      statusText = "Opened \(result.name)"
    } else {
      errorText = "Could not open \(MacFileSearchDisplay.abbreviated(result.path))"
    }
  }

  public func revealMacFileInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
}
