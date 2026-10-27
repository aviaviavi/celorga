import Foundation

/// One file a chat thread produced or pointed at: the agent edited it (per-turn
/// change summaries) or linked it in a reply. Derived from stored messages, so
/// every existing thread gets it without any model cooperation.
struct AIChatThreadOutputFile: Identifiable, Hashable, Sendable {
  /// Absolute, standardized local path.
  let path: String
  var editCount: Int
  var linkCount: Int
  var wasCreated: Bool
  var wasDeleted: Bool
  var lastMessageID: UUID
  var lastMessageIndex: Int
  /// A published sibling (for example the PDF next to an edited .org) that the
  /// thread never touched directly. Shown as a format, not counted as activity.
  var isSibling = false
  var exists = true
  var modifiedAt: Date?

  var id: String { path }
  var fileName: String { (path as NSString).lastPathComponent }
  var fileExtension: String { (path as NSString).pathExtension.lowercased() }
  var directory: String { (path as NSString).deletingLastPathComponent }
  var stem: String { ((fileName as NSString).deletingPathExtension) }
}

/// A source file and its published formats: sales-pipeline.org, .pdf, .csv
/// and .html are one output with several formats.
struct AIChatThreadOutputGroup: Identifiable, Hashable, Sendable {
  let directory: String
  let stem: String
  var files: [AIChatThreadOutputFile]
  var staleFormats: [String] = []

  var id: String { directory + "/" + stem }

  var primary: AIChatThreadOutputFile {
    files.first { AIChatThreadOutputs.sourceExtensions.contains($0.fileExtension) && !$0.isSibling }
      ?? files.filter { !$0.isSibling }.max { ($0.editCount, $0.linkCount) < ($1.editCount, $1.linkCount) }
      ?? files[0]
  }

  var editCount: Int { files.reduce(0) { $0 + $1.editCount } }
  var linkCount: Int { files.reduce(0) { $0 + $1.linkCount } }
  var lastMessageIndex: Int { files.filter { !$0.isSibling }.map(\.lastMessageIndex).max() ?? -1 }
  var lastMessageID: UUID? {
    files.filter { !$0.isSibling }.max { $0.lastMessageIndex < $1.lastMessageIndex }?.lastMessageID
  }
  var exists: Bool { files.contains(where: \.exists) }

  /// "edited 2× · linked 1× · missing", shared by the Mac panel and the phone.
  var activitySummary: String {
    var parts: [String] = []
    if editCount > 0 { parts.append("edited \(editCount)×") }
    if linkCount > 0 { parts.append("linked \(linkCount)×") }
    if !exists { parts.append("missing") }
    return parts.joined(separator: " · ")
  }
}

struct AIChatThreadOutputs: Equatable, Sendable {
  static let sourceExtensions: Set<String> = ["org", "org2", "md", "markdown"]
  static let publishedExtensions = ["pdf", "docx", "html", "odt"]
  /// Top-level corpus folders that collect unrelated notes. A thread that edits
  /// two daily notes is not "working in" daily/.
  static let broadCorpusFolders: Set<String> = [
    "daily", "journals", "meetings", "notes", "pages", "raw", "views", "inbox",
    "files", "attachments", "images", "drafts", "data", "runs", "artifacts",
  ]

  /// Upper bound on outputs derived per thread. Long threads can reference
  /// thousands of files; scanning, stat-ing and rendering all of them froze the
  /// app. Only the most recently touched outputs are kept.
  static let maxGroups = 100

  /// Most recently touched first.
  var groups: [AIChatThreadOutputGroup]
  /// Absolute path of the folder most of the outputs live in, when one stands out.
  var folder: String?
  let corpusRoot: String?
  /// True when older replies were not scanned because `maxGroups` was reached.
  var isTruncated = false

  static let empty = AIChatThreadOutputs(groups: [], folder: nil, corpusRoot: nil)

  var isEmpty: Bool { groups.isEmpty }
  var staleCount: Int { groups.filter { !$0.staleFormats.isEmpty }.count }

  var groupsInFolder: [AIChatThreadOutputGroup] {
    guard let folder else { return groups }
    return groups.filter { Self.path($0.directory, isInside: folder) }
  }

  var groupsOutsideFolder: [AIChatThreadOutputGroup] {
    guard let folder else { return [] }
    return groups.filter { !Self.path($0.directory, isInside: folder) }
  }

  /// Paths of every file the thread edited or linked, for highlighting in the
  /// folder browser.
  var touchedPaths: Set<String> {
    Set(groups.flatMap { $0.files.filter { !$0.isSibling }.map(\.path) })
  }

  func displayPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
    if let corpusRoot, Self.path(path, isInside: corpusRoot), path != corpusRoot {
      return String(path.dropFirst(corpusRoot.count + 1))
    }
    let home = Self.trimmed(homeDirectory)
    if Self.path(path, isInside: home) {
      return "~" + String(path.dropFirst(home.count))
    }
    return path
  }

  /// Row label for a group: relative to the working folder when inside it,
  /// otherwise a corpus- or home-relative path.
  func rowTitle(
    _ group: AIChatThreadOutputGroup,
    relativeTo folder: String?,
    homeDirectory: String = NSHomeDirectory()
  ) -> String {
    let name = group.files.count > 1 ? group.stem : group.primary.fileName
    let directory = group.directory
    if let folder, Self.path(directory, isInside: folder) {
      return directory == folder ? name : String(directory.dropFirst(folder.count + 1)) + "/" + name
    }
    if directory == corpusRoot { return name }
    return displayPath(directory, homeDirectory: homeDirectory) + "/" + name
  }

  // MARK: - Derivation

  /// Builds outputs from messages only (no file system access). Call
  /// `resolvingFileStatus()` afterwards to add existence, siblings and staleness.
  static func derive(
    messages: [AIChatMessage],
    corpusRoot rawCorpusRoot: String?,
    remoteCorpusRoot rawRemoteRoot: String? = nil,
    homeDirectory rawHome: String = NSHomeDirectory(),
    maxGroups: Int = AIChatThreadOutputs.maxGroups
  ) -> AIChatThreadOutputs {
    let corpusRoot = rawCorpusRoot.map { trimmed(standardized($0)) }
    let remoteRoot = rawRemoteRoot.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
    let home = trimmed(rawHome)
    var files: [String: AIChatThreadOutputFile] = [:]
    var groupKeys = Set<String>()
    var isTruncated = false

    /// Replies are scanned newest first, so the first sighting of a file is its
    /// latest state.
    func record(_ path: String, message: AIChatMessage, index: Int, update: (inout AIChatThreadOutputFile, Bool) -> Void) {
      guard isOutputCandidate(path) else { return }
      let isNew = files[path] == nil
      if isNew {
        let key = (path as NSString).deletingLastPathComponent + "/"
          + ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if !groupKeys.contains(key) {
          guard groupKeys.count < maxGroups else {
            isTruncated = true
            return
          }
          groupKeys.insert(key)
        }
      }
      var file = files[path] ?? AIChatThreadOutputFile(
        path: path, editCount: 0, linkCount: 0, wasCreated: false, wasDeleted: false,
        lastMessageID: message.id, lastMessageIndex: index
      )
      update(&file, isNew)
      files[path] = file
    }

    for (index, message) in messages.enumerated().reversed()
    where message.role == .assistant && !message.isRoomDispatchCopy {
      // Stop at a reply boundary once the budget is spent so counts stay
      // consistent for everything scanned.
      if isTruncated || groupKeys.count >= maxGroups {
        isTruncated = true
        break
      }
      if let corpusRoot, let summary = message.changeSummary {
        for change in summary.files {
          let path = standardized(corpusRoot + "/" + change.relativePath)
          record(path, message: message, index: index) { file, isNewest in
            file.editCount += 1
            if change.status == .created { file.wasCreated = true }
            if isNewest { file.wasDeleted = change.status == .deleted }
          }
        }
      }
      var linkedInMessage = Set<String>()
      for raw in linkedPathCandidates(in: message.content) {
        guard let path = resolve(raw, corpusRoot: corpusRoot, remoteRoot: remoteRoot, home: home),
              linkedInMessage.insert(path).inserted
        else { continue }
        record(path, message: message, index: index) { file, _ in file.linkCount += 1 }
      }
    }

    var grouped: [String: AIChatThreadOutputGroup] = [:]
    for file in files.values {
      let key = file.directory + "/" + file.stem
      if grouped[key] == nil {
        grouped[key] = AIChatThreadOutputGroup(directory: file.directory, stem: file.stem, files: [])
      }
      grouped[key]?.files.append(file)
    }
    var groups = Array(grouped.values)
    for index in groups.indices {
      groups[index].files.sort(by: formatOrder)
    }
    // Most recent first; within one reply, linked files before incidental edits.
    groups.sort {
      ($0.lastMessageIndex, $0.linkCount > 0 ? 1 : 0, $0.editCount + $0.linkCount, $1.id)
        > ($1.lastMessageIndex, $1.linkCount > 0 ? 1 : 0, $1.editCount + $1.linkCount, $0.id)
    }
    let folder = workingFolder(for: groups, corpusRoot: corpusRoot, homeDirectory: home)
    return AIChatThreadOutputs(groups: groups, folder: folder, corpusRoot: corpusRoot, isTruncated: isTruncated)
  }

  /// Adds file existence, published siblings (the PDF next to an edited .org),
  /// and "stale" formats whose source changed after they were built.
  func resolvingFileStatus(fileManager: FileManager = .default) -> AIChatThreadOutputs {
    var result = self
    for groupIndex in result.groups.indices {
      var group = result.groups[groupIndex]
      // A bare mention such as ~/avi.org2 looks like a file but is a folder.
      group.files.removeAll { file in
        let attributes = try? fileManager.attributesOfItem(atPath: file.path)
        return attributes?[.type] as? FileAttributeType == .typeDirectory
      }
      for fileIndex in group.files.indices {
        let attributes = try? fileManager.attributesOfItem(atPath: group.files[fileIndex].path)
        group.files[fileIndex].exists = attributes != nil
        group.files[fileIndex].modifiedAt = attributes?[.modificationDate] as? Date
      }
      let known = Set(group.files.map(\.fileExtension))
      if let source = group.files.first(where: { Self.sourceExtensions.contains($0.fileExtension) }) {
        for ext in Self.publishedExtensions where !known.contains(ext) {
          let path = group.directory + "/" + group.stem + "." + ext
          guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { continue }
          var sibling = AIChatThreadOutputFile(
            path: path, editCount: 0, linkCount: 0, wasCreated: false, wasDeleted: false,
            lastMessageID: source.lastMessageID, lastMessageIndex: source.lastMessageIndex
          )
          sibling.isSibling = true
          sibling.modifiedAt = attributes[.modificationDate] as? Date
          group.files.append(sibling)
        }
        group.files.sort(by: Self.formatOrder)
        if let sourceDate = group.files.first(where: { $0.path == source.path })?.modifiedAt {
          group.staleFormats = group.files.compactMap { file in
            guard Self.publishedExtensions.contains(file.fileExtension),
                  let date = file.modifiedAt,
                  sourceDate.timeIntervalSince(date) > 1
            else { return nil }
            return file.fileExtension.uppercased()
          }
        }
      }
      result.groups[groupIndex] = group
    }
    result.groups.removeAll { $0.files.isEmpty }
    result.folder = Self.workingFolder(for: result.groups, corpusRoot: corpusRoot)
    return result
  }

  /// Links are deliberate, while a turn's change summary can include unrelated
  /// writes made during it (a meeting bot, sync). Prefer the folder the linked
  /// outputs point at, then fall back to everything.
  static func workingFolder(
    for groups: [AIChatThreadOutputGroup],
    corpusRoot: String?,
    homeDirectory: String = NSHomeDirectory()
  ) -> String? {
    let linked = groups.filter { $0.linkCount > 0 }.map(\.directory)
    return workingFolder(for: linked, corpusRoot: corpusRoot, homeDirectory: homeDirectory)
      ?? workingFolder(for: groups.map(\.directory), corpusRoot: corpusRoot, homeDirectory: homeDirectory)
  }

  /// The deepest folder holding at least half of the thread's outputs (counted
  /// per source/published group), with at least two of them. Never the corpus
  /// root, the home folder, or a broad bucket such as daily/ or meetings/.
  static func workingFolder(
    for directories: [String],
    corpusRoot: String?,
    homeDirectory: String = NSHomeDirectory()
  ) -> String? {
    guard directories.count >= 2 else { return nil }
    let home = trimmed(homeDirectory)
    var counts: [String: Int] = [:]
    for directory in directories {
      var current = trimmed(directory)
      var seen = Set<String>()
      while !current.isEmpty, current != "/", seen.insert(current).inserted {
        counts[current, default: 0] += 1
        current = (current as NSString).deletingLastPathComponent
      }
    }
    let threshold = Double(directories.count) * 0.5
    let candidates = counts.filter { folder, count in
      count >= 2 && Double(count) >= threshold && isEligibleFolder(folder, corpusRoot: corpusRoot, home: home)
    }
    // Deepest wins; ties go to the folder holding more outputs, then by name.
    func depth(_ folder: String) -> Int { folder.split(separator: "/").count }
    return candidates.keys.max { (lhs: String, rhs: String) -> Bool in
      let lhsDepth = depth(lhs), rhsDepth = depth(rhs)
      if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
      let lhsCount: Int = candidates[lhs] ?? 0
      let rhsCount: Int = candidates[rhs] ?? 0
      if lhsCount != rhsCount { return lhsCount < rhsCount }
      return rhs < lhs
    }
  }

  private static func isEligibleFolder(_ folder: String, corpusRoot: String?, home: String) -> Bool {
    if path(home, isInside: folder) { return false }
    // Direct children of home (~/dev, ~/Documents) are too broad as well.
    if (folder as NSString).deletingLastPathComponent == home { return false }
    if let corpusRoot {
      if path(corpusRoot, isInside: folder) { return false }
      if (folder as NSString).deletingLastPathComponent == corpusRoot,
         broadCorpusFolders.contains((folder as NSString).lastPathComponent.lowercased()) {
        return false
      }
      if CelorgaNames.stateDirectoryNames.contains(where: { path(folder, isInside: corpusRoot + "/" + $0) }) {
        return false
      }
    }
    return true
  }

  // MARK: - Link extraction

  /// Raw path targets from Org file links and bare paths in a reply.
  static func linkedPathCandidates(in text: String) -> [String] {
    var result: [String] = []
    let nsText = text as NSString
    if let regex = try? NSRegularExpression(pattern: #"\[\[([^\]\[]+)\](?:\[[^\]]*\])?\]"#) {
      for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
        var target = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        if target.lowercased().hasPrefix("file:") {
          target = String(target.dropFirst(5))
          if target.hasPrefix("//") { target = String(target.dropFirst(2)) }
        } else if target.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
          continue // id:, https:, mailto:, …
        } else if !(target.hasPrefix("/") || target.hasPrefix("~/") || target.hasPrefix("./")) {
          continue // internal heading or fuzzy links
        }
        if let range = target.range(of: "::") { target = String(target[..<range.lowerBound]) }
        if !target.isEmpty { result.append(target) }
      }
    }
    // Web URLs such as https://example.com/a.pdf are not local paths.
    let withoutURLs = text.replacingOccurrences(
      of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s\]]+"#,
      with: " ",
      options: .regularExpression
    )
    result.append(contentsOf: AIChatFileReference.extract(from: withoutURLs, limit: 200).map(\.path))
    return result
  }

  static func resolve(_ raw: String, corpusRoot: String?, remoteRoot: String?, home: String) -> String? {
    var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.lowercased().hasPrefix("file:") {
      path = String(path.dropFirst(5))
      if path.hasPrefix("//") { path = String(path.dropFirst(2)) }
    }
    path = path.removingPercentEncoding ?? path
    guard !path.isEmpty else { return nil }
    func expandingHome(_ value: String) -> String {
      value.hasPrefix("~/") ? home + String(value.dropFirst(1)) : value
    }
    path = expandingHome(path)
    if let remoteRoot = remoteRoot.map(expandingHome), let corpusRoot,
       remoteRoot != corpusRoot, path.hasPrefix(remoteRoot + "/") {
      path = corpusRoot + String(path.dropFirst(remoteRoot.count))
    } else if !path.hasPrefix("/") {
      guard let corpusRoot else { return nil }
      path = corpusRoot + "/" + path
    }
    return standardized(path)
  }

  private static func isOutputCandidate(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    guard !name.isEmpty, !name.hasPrefix("."), !name.hasSuffix("~"), !path.contains("…"),
          !(name as NSString).pathExtension.isEmpty,
          !path.contains("/.org2/"),
          !path.contains("/.celorga/")
    else { return false }
    return true
  }

  private static func formatOrder(_ lhs: AIChatThreadOutputFile, _ rhs: AIChatThreadOutputFile) -> Bool {
    func rank(_ file: AIChatThreadOutputFile) -> Int {
      if sourceExtensions.contains(file.fileExtension) { return 0 }
      if let index = publishedExtensions.firstIndex(of: file.fileExtension) { return 1 + index }
      return 10
    }
    return (rank(lhs), lhs.fileExtension) < (rank(rhs), rhs.fileExtension)
  }

  static func path(_ path: String, isInside folder: String) -> Bool {
    path == folder || path.hasPrefix(folder + "/")
  }

  private static func standardized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private static func trimmed(_ path: String) -> String {
    var value = path
    while value.count > 1, value.hasSuffix("/") { value.removeLast() }
    return value
  }
}

extension AIChatThreadOutputs {
  /// The phone's view of the Outputs chip. Ordering, grouping, folder choice,
  /// stale detection and row titles come from the same derivation as the Mac.
  func mobileRemoteProjection(
    threadID: UUID,
    homeDirectory: String = NSHomeDirectory()
  ) -> MobileRemoteThreadOutputs {
    func file(_ file: AIChatThreadOutputFile, in group: AIChatThreadOutputGroup) -> MobileRemoteThreadOutputFile {
      var path = file.path
      var isInCorpus = false
      if let corpusRoot, Self.path(file.path, isInside: corpusRoot), file.path != corpusRoot {
        path = String(file.path.dropFirst(corpusRoot.count + 1))
        isInCorpus = true
      }
      return MobileRemoteThreadOutputFile(
        path: path,
        displayPath: displayPath(file.path, homeDirectory: homeDirectory),
        fileExtension: file.fileExtension,
        isInCorpus: isInCorpus,
        exists: file.exists,
        isSibling: file.isSibling,
        isPrimary: file.path == group.primary.path,
        isStale: group.staleFormats.contains(file.fileExtension.uppercased())
      )
    }
    let inFolder = Set(groupsInFolder.map(\.id))
    // In-folder outputs first, matching the Mac panel's sections.
    let ordered = groupsInFolder + groupsOutsideFolder
    return MobileRemoteThreadOutputs(
      threadID: threadID,
      folderName: folder.map { ($0 as NSString).lastPathComponent },
      folderDisplayPath: folder.map { displayPath($0, homeDirectory: homeDirectory) },
      isTruncated: isTruncated,
      maxGroups: Self.maxGroups,
      groups: ordered.map { group in
        let isInFolder = folder != nil && inFolder.contains(group.id)
        return MobileRemoteThreadOutputGroup(
          id: group.id,
          title: rowTitle(group, relativeTo: isInFolder ? folder : nil, homeDirectory: homeDirectory),
          isInFolder: folder == nil || isInFolder,
          exists: group.exists,
          wasCreated: group.primary.wasCreated,
          editCount: group.editCount,
          linkCount: group.linkCount,
          activitySummary: group.activitySummary,
          staleFormats: group.staleFormats,
          lastMessageID: group.lastMessageID,
          files: group.files.map { file($0, in: group) }
        )
      }
    )
  }
}
