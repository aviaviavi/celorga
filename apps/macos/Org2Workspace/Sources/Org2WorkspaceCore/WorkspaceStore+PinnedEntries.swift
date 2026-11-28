import Foundation

/// A heading pinned to the sidebar. An Org `:ID:` finds it wherever it
/// moves; without one, its file and title find it, with the line as a hint.
public struct PinnedEntry: Codable, Hashable, Identifiable, Sendable {
  public var relativePath: String
  public var title: String
  public var line: Int
  public var nodeID: String?

  public init(relativePath: String, title: String, line: Int, nodeID: String? = nil) {
    self.relativePath = relativePath
    self.title = title
    self.line = line
    self.nodeID = nodeID
  }

  public var id: String {
    if let nodeID { return "id:\(nodeID)" }
    return "\(relativePath)::\(title)"
  }

  public var fileName: String {
    URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
  }
}

/// Reads Org headings well enough to find a pinned entry again.
enum PinnedEntryHeading {
  private static let todoKeywords: Set<String> = [
    "TODO", "NEXT", "DONE", "CANCELED", "CANCELLED", "WAITING", "HOLD",
    "IN-PROGRESS", "INPROGRESS", "STARTED", "BLOCKED", "SOMEDAY",
  ]

  /// The plain title of an Org heading line, or nil for other lines. The
  /// TODO keyword, priority cookie, and tags are left out.
  static func title(ofHeadingLine line: Substring) -> String? {
    guard line.first == "*" else { return nil }
    let afterStars = line.drop(while: { $0 == "*" })
    guard afterStars.first == " " || afterStars.first == "\t" else { return nil }
    var words = afterStars.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    if let first = words.first, todoKeywords.contains(first) { words.removeFirst() }
    if let first = words.first, first.hasPrefix("[#"), first.hasSuffix("]"), first.count == 4 {
      words.removeFirst()
    }
    if let last = words.last, last.count > 2, last.hasPrefix(":"), last.hasSuffix(":"),
       !last.contains(" ") {
      words.removeLast()
    }
    return Org2Display.cleanInline(words.joined(separator: " "))
  }

  /// The heading's own `:ID:`, from the property drawer right below it.
  static func nodeID(inEntry text: String) -> String? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines.dropFirst() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("*") && title(ofHeadingLine: Substring(trimmed)) != nil { return nil }
      if trimmed.uppercased().hasPrefix(":ID:") {
        let value = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
      }
      if trimmed.uppercased() == ":END:" { return nil }
    }
    return nil
  }

  /// The 1-based line of the pinned heading: the remembered line while it
  /// still holds that title, otherwise the first heading with the title.
  static func line(for entry: PinnedEntry, in source: String) -> Int? {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    if entry.line >= 1, entry.line <= lines.count,
       title(ofHeadingLine: lines[entry.line - 1]) == entry.title {
      return entry.line
    }
    return lines.firstIndex { title(ofHeadingLine: $0) == entry.title }.map { $0 + 1 }
  }
}

extension WorkspaceStore {
  public func isEntryPinned(file: String, line: Int, title: String) -> Bool {
    pinnedEntry(file: file, line: line, title: title) != nil
  }

  private func pinnedEntry(file: String, line: Int, title: String) -> PinnedEntry? {
    guard let relativePath = pinnedEntryRelativePath(for: file) else { return nil }
    let cleanTitle = Self.pinnedEntryTitle(title)
    return pinnedEntries.first {
      $0.relativePath == relativePath && ($0.line == line || $0.title == cleanTitle)
    }
  }

  /// Pins the heading at `line` of `file`, or unpins it when already pinned.
  public func togglePinnedEntry(file: String, line: Int, title: String, entryText: String? = nil) {
    if let existing = pinnedEntry(file: file, line: line, title: title) {
      unpinEntry(existing)
      return
    }
    guard let relativePath = pinnedEntryRelativePath(for: file) else {
      statusText = "Only entries inside the current corpus can be pinned"
      return
    }
    let cleanTitle = Self.pinnedEntryTitle(title)
    let entry = PinnedEntry(
      relativePath: relativePath,
      title: cleanTitle.isEmpty ? relativePath : cleanTitle,
      line: line,
      nodeID: entryText.flatMap(PinnedEntryHeading.nodeID(inEntry:))
    )
    pinnedEntries.append(entry)
    persistPinnedEntries()
    statusText = "Pinned \(entry.title)"
  }

  public func togglePinnedEntry(_ location: WorkspaceLocation) {
    togglePinnedEntry(file: location.file, line: location.lineForEditor, title: location.title)
  }

  public func isEntryPinned(_ location: WorkspaceLocation) -> Bool {
    isEntryPinned(file: location.file, line: location.lineForEditor, title: location.title)
  }

  public func unpinEntry(_ entry: PinnedEntry) {
    pinnedEntries.removeAll { $0.id == entry.id }
    persistPinnedEntries()
    statusText = "Unpinned \(entry.title)"
  }

  /// Opens a pinned heading in the entry view, finding it by its `:ID:`
  /// when the corpus index knows it, else by its title in its file.
  public func openPinnedEntry(_ entry: PinnedEntry) {
    guard let corpusRoot else { return }
    if let nodeID = entry.nodeID,
       let resolved = orgRoamLinkResolver.resolve(target: "id:\(nodeID)") {
      let reference = resolved.fileReference
      openPinnedEntryView(entry, file: reference.path, line: reference.line ?? entry.line)
      return
    }
    let path = corpusRoot.appendingPathComponent(entry.relativePath).standardizedFileURL.path
    Task { @MainActor [weak self] in
      let line = await Task.detached(priority: .userInitiated) { () -> Int? in
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return PinnedEntryHeading.line(for: entry, in: source)
      }.value
      guard let self else { return }
      guard let line else {
        self.statusText = "Could not find \(entry.title) in \(entry.relativePath)"
        return
      }
      if line != entry.line, let index = self.pinnedEntries.firstIndex(of: entry) {
        self.pinnedEntries[index].line = line
        self.persistPinnedEntries()
      }
      self.openPinnedEntryView(entry, file: path, line: line)
    }
  }

  /// The entry view of the pinned heading, as Entry View in the document's
  /// context menu opens it, rather than the whole document scrolled to it.
  private func openPinnedEntryView(_ entry: PinnedEntry, file: String, line: Int) {
    pendingNavigationSource = "sidebar"
    activateDetailLocation(
      .aiChatThreadRecord(AIChatThreadRecord(
        title: entry.title,
        file: file,
        line: line,
        zone: "entry",
        modifiedAt: nil,
        idValue: nil
      )),
      mode: .entry,
      surface: nil,
      recordsHistory: true
    )
    statusText = "Opened \(entry.title)"
  }

  func restorePinnedEntries(for corpusRoot: URL) {
    let storage = defaults.dictionary(forKey: pinnedEntriesByCorpusKey) ?? [:]
    let data = storage[corpusRoot.standardizedFileURL.path] as? Data
    pinnedEntries = data.flatMap { try? JSONDecoder().decode([PinnedEntry].self, from: $0) } ?? []
  }

  func persistPinnedEntries() {
    guard let corpusRoot else { return }
    var storage = defaults.dictionary(forKey: pinnedEntriesByCorpusKey) ?? [:]
    let key = corpusRoot.standardizedFileURL.path
    if pinnedEntries.isEmpty {
      storage.removeValue(forKey: key)
    } else {
      storage[key] = try? JSONEncoder().encode(pinnedEntries)
    }
    defaults.set(storage, forKey: pinnedEntriesByCorpusKey)
  }

  /// A renamed file keeps its pinned entries.
  func renamePinnedEntries(fromRelativePath oldPath: String, toRelativePath newPath: String) {
    guard pinnedEntries.contains(where: { $0.relativePath == oldPath }) else { return }
    for index in pinnedEntries.indices where pinnedEntries[index].relativePath == oldPath {
      pinnedEntries[index].relativePath = newPath
    }
    persistPinnedEntries()
  }

  private func pinnedEntryRelativePath(for path: String) -> String? {
    guard let corpusRoot else { return nil }
    let rootPath = corpusRoot.standardizedFileURL.path
    let filePath = URL(fileURLWithPath: path).standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard filePath.hasPrefix(prefix) else { return nil }
    return String(filePath.dropFirst(prefix.count))
  }

  nonisolated static func pinnedEntryTitle(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return PinnedEntryHeading.title(ofHeadingLine: Substring("* " + trimmed)) ?? trimmed
  }
}
