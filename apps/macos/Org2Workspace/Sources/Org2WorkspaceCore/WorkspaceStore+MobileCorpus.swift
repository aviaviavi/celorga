import Foundation

/// The host side of a phone that keeps no copy of the corpus. The phone lists,
/// searches, reads, and downloads files through these calls, and its captures
/// land in the host corpus's mobile inbox.
extension WorkspaceStore {
  /// Plain-text files the phone can list and read.
  nonisolated public static let mobileRemoteTextExtensions: Set<String> = [
    "org2", "org", "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml",
  ]
  /// Largest file the phone may download whole (published PDFs, documents).
  nonisolated public static let mobileRemoteDownloadMaxBytes = 8 * 1024 * 1024
  /// Largest captured entry text and attachment the host accepts.
  nonisolated public static let mobileCaptureMaxContentBytes = 512 * 1024
  nonisolated public static let mobileCaptureMaxAttachmentBytes = 8 * 1024 * 1024
  nonisolated static let mobileInboxFilename = "mobile-inbox.org"
  nonisolated static let legacyMobileInboxFilename = "mobile-inbox.org2"
  nonisolated static let mobileInboxAssetsDirectory = "mobile-inbox-assets"

  // MARK: Catalog

  public func mobileRemoteCorpusCatalog() async throws -> MobileRemoteCorpusCatalog {
    guard let root = corpusRoot?.standardizedFileURL else {
      throw MobileRemoteFilePreviewError.unavailable
    }
    return await Task.detached(priority: .userInitiated) {
      Self.mobileRemoteCorpusCatalog(root: root)
    }.value
  }

  nonisolated static func mobileRemoteCorpusCatalog(root: URL) -> MobileRemoteCorpusCatalog {
    let config = mobileCorpusConfig(root: root)
    let ignorePatterns = config?.ignorePatterns ?? []
    let recursive = config?.recursive ?? true
    var files: [MobileRemoteCorpusFile] = []
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
    if let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) {
      let rootPath = root.resolvingSymlinksInPath().path
      for case let url as URL in enumerator {
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(rootPath + "/") else { continue }
        let relativePath = String(resolved.dropFirst(rootPath.count + 1))
        if shouldSkipMobileCorpusPath(relativePath, name: url.lastPathComponent, ignorePatterns: ignorePatterns) {
          enumerator.skipDescendants()
          continue
        }
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if values.isDirectory == true {
          if !recursive { enumerator.skipDescendants() }
          continue
        }
        guard values.isRegularFile == true,
              mobileRemoteTextExtensions.contains(url.pathExtension.lowercased())
        else { continue }
        files.append(MobileRemoteCorpusFile(
          path: relativePath,
          byteCount: values.fileSize.map(Int64.init),
          modifiedAt: values.contentModificationDate
        ))
      }
    }
    files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    return MobileRemoteCorpusCatalog(
      corpusName: root.lastPathComponent,
      todoSequences: config?.todo?.sequences ?? [],
      files: files
    )
  }

  private struct MobileCorpusConfig: Decodable {
    struct Todo: Decodable { let sequences: [String]? }
    let todo: Todo?
    let recursive: Bool?
    let ignorePatterns: [String]?
  }

  nonisolated private static func mobileCorpusConfig(root: URL) -> MobileCorpusConfig? {
    guard let url = CelorgaNames.configFile(in: root),
          let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(MobileCorpusConfig.self, from: data)
  }

  nonisolated static func shouldSkipMobileCorpusPath(
    _ relativePath: String,
    name: String,
    ignorePatterns: [String]
  ) -> Bool {
    if name == "node_modules" || name.hasPrefix(".#") || name.hasPrefix(".syncthing.")
      || name.contains(".sync-conflict-") || name.hasSuffix(".tmp") {
      return true
    }
    return ignorePatterns.contains { mobileCorpusPath(relativePath, matches: $0) }
  }

  nonisolated static func mobileCorpusPath(_ path: String, matches pattern: String) -> Bool {
    let normalize = { (value: String) in
      value.replacingOccurrences(of: "\\", with: "/")
        .split(separator: "/", omittingEmptySubsequences: true)
        .joined(separator: "/")
    }
    let path = normalize(path)
    let pattern = normalize(pattern)
    guard pattern.contains("*") else {
      return path == pattern || path.hasPrefix(pattern + "/")
    }
    let pathSegments = path.split(separator: "/").map(String.init)
    let patternSegments = pattern.split(separator: "/").map(String.init)
    func matches(_ pathIndex: Int, _ patternIndex: Int) -> Bool {
      guard patternIndex < patternSegments.count else { return pathIndex >= pathSegments.count }
      let segment = patternSegments[patternIndex]
      if segment == "**" {
        return (pathIndex...pathSegments.count).contains { matches($0, patternIndex + 1) }
      }
      guard pathIndex < pathSegments.count else { return false }
      let regex = "^" + NSRegularExpression.escapedPattern(for: segment)
        .replacingOccurrences(of: "\\*", with: ".*") + "$"
      guard pathSegments[pathIndex].range(of: regex, options: .regularExpression) != nil else { return false }
      return matches(pathIndex + 1, patternIndex + 1)
    }
    return matches(0, 0)
  }

  // MARK: Search and links

  public func mobileRemoteCorpusSearch(query rawQuery: String, limit rawLimit: Int?) async throws -> MobileRemoteCorpusSearchResponse {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let root = corpusRoot?.standardizedFileURL else {
      throw MobileRemoteFilePreviewError.unavailable
    }
    guard !query.isEmpty else { return MobileRemoteCorpusSearchResponse(results: []) }
    let limit = max(1, min(rawLimit ?? 60, 200))
    let payload: SearchPayload = try await cli.runJSON([
      "search", query, "--dir", root.path,
      "--recursive",
      "--limit", String(limit * 3),
      "--context", "0",
      "--index", "auto",
      "--sort", "best",
      "--format", "json",
    ])
    return MobileRemoteCorpusSearchResponse(
      results: Self.mobileRemoteSearchResults(payload.results, root: root, limit: limit)
    )
  }

  /// One result per enclosing heading, in the search's ranked order.
  nonisolated static func mobileRemoteSearchResults(
    _ results: [SearchResult],
    root: URL,
    limit: Int
  ) -> [MobileRemoteCorpusSearchResult] {
    let rootPath = root.resolvingSymlinksInPath().path
    var seen: Set<String> = []
    var output: [MobileRemoteCorpusSearchResult] = []
    for result in results {
      var path = result.file
      if path.hasPrefix(rootPath + "/") { path = String(path.dropFirst(rootPath.count + 1)) }
      let line = result.headingLine ?? 0
      guard seen.insert("\(path):\(line)").inserted else { continue }
      let ancestry = result.headingAncestry ?? []
      let parent = ancestry.dropLast().map(\.title).joined(separator: " › ")
      output.append(MobileRemoteCorpusSearchResult(
        path: path,
        line: line,
        title: result.heading ?? URL(fileURLWithPath: path).lastPathComponent,
        parent: parent,
        nodeID: result.idValue ?? "",
        snippet: String(result.snippet.prefix(400))
      ))
      if output.count >= limit { break }
    }
    return output
  }

  public func mobileRemoteResolveID(_ rawID: String) async throws -> MobileRemoteResolvedLocation {
    let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let root = corpusRoot?.standardizedFileURL,
          !id.isEmpty,
          !id.contains(where: { $0.isNewline })
    else { throw MobileRemoteFilePreviewError.invalidPath }
    struct Resolution: Decodable {
      let ok: Bool?
      let file: String?
      let line: Int?
    }
    let anchor = CelorgaNames.configFile(in: root) ?? root.appendingPathComponent("index.org")
    let resolution: Resolution = try await cli.runJSON([
      "embed", "resolve", "--target", "id:\(id)", "--file", anchor.path, "--dir", root.path, "--json",
    ])
    guard resolution.ok != false, let file = resolution.file else {
      throw MobileRemoteFilePreviewError.unavailable
    }
    let target = try Self.mobileRemotePreviewTarget(for: file, mountedRootPaths: [root.path])
    return MobileRemoteResolvedLocation(path: target.relativePath, line: resolution.line ?? 1)
  }

  // MARK: Download

  public func mobileRemoteFileDownload(path rawPath: String) async throws -> MobileRemoteFileDownload {
    let active = corpusRoot?.standardizedFileURL.path
    let mounted = workspaceMountPaths().sorted()
    let roots = (active.map { [$0] } ?? []) + mounted.filter { $0 != active }
    return try await Task.detached(priority: .userInitiated) {
      let target = try Self.mobileRemotePreviewTarget(for: rawPath, mountedRootPaths: roots)
      let values = try? target.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      guard (values?.fileSize ?? 0) <= Self.mobileRemoteDownloadMaxBytes,
            let data = try? Data(contentsOf: target.url)
      else { throw MobileRemoteFilePreviewError.unavailable }
      return MobileRemoteFileDownload(
        relativePath: target.relativePath,
        modifiedAt: values?.contentModificationDate,
        data: data
      )
    }.value
  }

  // MARK: Capture

  public func mobileRemoteCaptureAttachment(_ request: MobileRemoteCaptureAttachmentRequest) async throws -> MobileRemoteCaptureResponse {
    guard let root = corpusRoot?.standardizedFileURL else {
      throw MobileRemoteFilePreviewError.unavailable
    }
    guard Self.isValidMobileCaptureEntryID(request.entryID),
          Self.isValidMobileCaptureFilename(request.filename),
          request.data.count <= Self.mobileCaptureMaxAttachmentBytes
    else { throw MobileCaptureError.invalidAttachment }
    let relativePath = "\(Self.mobileInboxAssetsDirectory)/\(request.entryID)/\(request.filename)"
    try await Task.detached(priority: .userInitiated) {
      let folder = root
        .appendingPathComponent(Self.mobileInboxAssetsDirectory, isDirectory: true)
        .appendingPathComponent(request.entryID, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try request.data.write(to: folder.appendingPathComponent(request.filename), options: .atomic)
    }.value
    return MobileRemoteCaptureResponse(accepted: true, path: relativePath, duplicate: false)
  }

  public func mobileRemoteCapture(_ request: MobileRemoteCaptureRequest) async throws -> MobileRemoteCaptureResponse {
    guard let root = corpusRoot?.standardizedFileURL else {
      throw MobileRemoteFilePreviewError.unavailable
    }
    let content = Self.normalizeLineEndings(request.content)
    guard Self.isValidMobileCaptureEntryID(request.entryID),
          content.utf8.count <= Self.mobileCaptureMaxContentBytes,
          Self.isValidMobileCaptureEntry(content, entryID: request.entryID)
    else { throw MobileCaptureError.invalidEntry }
    let inbox = Self.mobileInboxURL(root: root)
    guard let context = captureDocumentCorpusContext(forFile: inbox.path) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(file: inbox.path, root: root.path)
    }
    let duplicate: Bool = try await performDocumentMutation(context: context, files: [inbox.path]) { execution in
      let snapshot = try await execution.readSnapshot(at: inbox, allowMissing: true)
      let existing = Self.normalizeLineEndings(snapshot.text)
      if Self.mobileInbox(existing, containsEntryID: request.entryID) {
        return true
      }
      var text = existing.isEmpty ? "#+TITLE: Celorga Mobile Inbox\n" : existing
      if !text.hasSuffix("\n") { text += "\n" }
      text += "\n" + content.trimmingCharacters(in: .newlines) + "\n"
      try await execution.commit(text, over: snapshot) { text, url, previous in
        try Self.commitDocumentText(text, url: url, previousText: previous, operation: "mobile capture")
      }
      return false
    }
    invalidateCanonicalDocumentCache(for: inbox.path)
    if !duplicate { scheduleAgendaRefresh(preserveSelection: true) }
    return MobileRemoteCaptureResponse(
      accepted: true,
      path: inbox.lastPathComponent,
      duplicate: duplicate
    )
  }

  nonisolated static func mobileInboxURL(root: URL) -> URL {
    let preferred = root.appendingPathComponent(mobileInboxFilename)
    if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
    let legacy = root.appendingPathComponent(legacyMobileInboxFilename)
    return FileManager.default.fileExists(atPath: legacy.path) ? legacy : preferred
  }

  nonisolated static func mobileInbox(_ text: String, containsEntryID entryID: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      line.trimmingCharacters(in: .whitespaces) == ":ID: mobile-\(entryID)"
    }
  }

  nonisolated static func isValidMobileCaptureEntryID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 96
      && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
      && id.unicodeScalars.allSatisfy(\.isASCII)
  }

  nonisolated static func isValidMobileCaptureFilename(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 128 && !name.hasPrefix(".")
      && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
      && name != ".." && !name.contains(where: \.isNewline)
  }

  /// A capture is exactly one top-level entry that carries its own mobile ID,
  /// so a phone cannot slip several headings or an unrelated edit into the inbox.
  nonisolated static func isValidMobileCaptureEntry(_ content: String, entryID: String) -> Bool {
    let lines = content.trimmingCharacters(in: .newlines)
      .split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first, first.hasPrefix("* ") else { return false }
    let topLevelHeadings = lines.filter { $0.hasPrefix("* ") || $0 == "*" }
    guard topLevelHeadings.count == 1 else { return false }
    return mobileInbox(content, containsEntryID: entryID)
  }
}

public enum MobileCaptureError: LocalizedError, Equatable {
  case invalidEntry
  case invalidAttachment

  public var errorDescription: String? {
    switch self {
    case .invalidEntry: "The captured note could not be read."
    case .invalidAttachment: "The note attachment could not be saved."
    }
  }
}
