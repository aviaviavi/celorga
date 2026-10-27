import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  func nestedParentSendHeading(for target: HeadlineMutationTarget) throws -> (line: Int, id: String?)? {
    guard target.title.range(of: #"^Approve\b"#, options: [.regularExpression, .caseInsensitive]) != nil else {
      return nil
    }

    let raw = try String(contentsOf: URL(fileURLWithPath: target.file), encoding: .utf8)
    return Self.nestedParentSendHeading(for: target, in: raw)
  }

  nonisolated static func nestedParentSendHeading(
    for target: HeadlineMutationTarget,
    in raw: String
  ) -> (line: Int, id: String?)? {
    guard target.title.range(of: #"^Approve\b"#, options: [.regularExpression, .caseInsensitive]) != nil else {
      return nil
    }
    let normalizedRaw = raw.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalizedRaw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let targetIndex = max(0, min(lines.count - 1, target.line - 1))
    guard let childIndex = Self.headingIndex(in: lines, atOrBefore: targetIndex),
          let childLevel = Self.headingLevel(lines[childIndex]),
          childLevel > 1
    else { return nil }

    for index in stride(from: childIndex - 1, through: 0, by: -1) {
      guard let level = Self.headingLevel(lines[index]) else { continue }
      if level >= childLevel { continue }
      let properties = Self.scanPropertyDrawer(lines: lines, afterHeadingIndex: index)
      let candidateID = (properties["ID"] ?? properties["CUSTOM_ID"] ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let title = Self.headingTitle(from: lines[index])
      if title.range(of: #"^Send\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
        return nil
      }
      return (line: index + 1, id: candidateID.isEmpty ? nil : candidateID)
    }

    return nil
  }

  nonisolated static func headingTitle(from line: String) -> String {
    var rest = line.replacingOccurrences(of: #"^\*+\s+"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    rest = rest.replacingOccurrences(of: #"^[A-Z][A-Z0-9_-]*(\s+|$)"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    rest = rest.replacingOccurrences(of: #"\s+:[^\s:]+(:[^\s:]+)*:\s*$"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Org2Display.cleanInline(rest)
  }

  private func updateHeadlinePriority(file: String, line: Int, priority: String?) throws {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let output = try Self.textByUpdatingHeadlinePriority(
      raw,
      file: file,
      line: line,
      priority: priority
    )
    try Self.writeOrgTextSafely(
      output,
      to: url,
      replacing: raw,
      operation: "headline priority update"
    )
  }

  nonisolated static func textByUpdatingHeadlinePriority(
    _ raw: String,
    file: String,
    line: Int,
    priority: String?
  ) throws -> String {
    let normalizedRaw = raw.replacingOccurrences(of: "\r\n", with: "\n")
    var lines = normalizedRaw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let index = max(0, min(lines.count - 1, line - 1))

    guard index < lines.count else {
      throw WorkspaceEditError.noHeadline(file: file, line: line)
    }

    let original = lines[index]
    guard let match = original.range(of: #"^(\*+)\s+(.*)$"#, options: .regularExpression) else {
      throw WorkspaceEditError.noHeadline(file: file, line: line)
    }

    let matched = String(original[match])
    guard let separator = matched.firstIndex(of: " ") else {
      throw WorkspaceEditError.noHeadline(file: file, line: line)
    }

    let stars = String(matched[..<separator])
    var rest = String(matched[matched.index(after: separator)...])
    var tagsSuffix = ""

    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%:.-]+:)\s*$"#, options: .regularExpression) {
      tagsSuffix = String(rest[tagRange])
      rest.removeSubrange(tagRange)
      rest = rest.trimmingCharacters(in: .whitespaces)
    }

    let todoKeywords = Set(["TODO", "IN_PROGRESS", "PROG", "WAIT", "HOLD", "PAUSED", "DONE", "CANCELED", "CANCELLED"])
    var tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    var todoPrefix = ""
    if let first = tokens.first, todoKeywords.contains(first.uppercased()) {
      todoPrefix = first.uppercased()
      tokens.removeFirst()
    }
    if let first = tokens.first, first.range(of: #"^\[#([A-Za-z0-9])\]$"#, options: .regularExpression) != nil {
      tokens.removeFirst()
    }

    let title = tokens.joined(separator: " ")
    let normalizedPriority = priority.flatMap(Self.normalizePriority)
    let todoPart = todoPrefix.isEmpty ? "" : "\(todoPrefix) "
    let priorityPart = normalizedPriority.map { "[#\($0)] " } ?? ""
    lines[index] = "\(stars) \(todoPart)\(priorityPart)\(title)\(tagsSuffix)"

    return lines.joined(separator: "\n")
  }

  /// Where daily notes live: a valid `roam.dailyFileTemplate` wins over the
  /// `roam.dailiesDir/YYYY-MM-DD.org` convention.
  struct DailyNoteLocation: Sendable, Equatable {
    let directory: URL
    let template: DailyNoteTemplate?
  }

  nonisolated private static func dailyNoteLocationOffMain(corpusRoot: URL) -> DailyNoteLocation {
    let root = corpusRoot.standardizedFileURL
    let configURL = CelorgaNames.configFilePath(in: root)
    let config = (try? Data(contentsOf: configURL))
      .flatMap { try? JSONDecoder().decode(WorkspaceDailyNoteConfig.self, from: $0) }
    return DailyNoteLocation(
      directory: dailyNoteDirectoryOffMain(corpusRoot: root, config: config),
      template: config?.roam?.dailyFileTemplate.flatMap(DailyNoteTemplate.init)
    )
  }

  nonisolated private static func dailyNoteDirectoryOffMain(
    corpusRoot root: URL,
    config: WorkspaceDailyNoteConfig?
  ) -> URL {
    let defaultDirectory = root
      .appendingPathComponent("daily", isDirectory: true)
      .standardizedFileURL
    guard let config,
          let configured = config.roam?.dailiesDir?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !configured.isEmpty,
          !configured.contains("\0")
    else {
      return defaultDirectory
    }

    let directory = NSString(string: configured).isAbsolutePath
      ? URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
      : root.appendingPathComponent(configured, isDirectory: true).standardizedFileURL
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
       !isDirectory.boolValue {
      return defaultDirectory
    }
    return directory
  }

  func prepareDailyNoteDirectory(for corpusRoot: URL) {
    let root = corpusRoot.standardizedFileURL
    let key = root.path
    guard dailyNoteDirectoriesByCorpusPath[key] == nil,
          dailyNoteDirectoryTasksByCorpusPath[key] == nil
    else { return }
    let observer = dailyNoteDirectoryPreparationForTesting
    let resolver = dailyNoteDirectoryResolverForTesting
    let token = UUID()
    let task = Task.detached(priority: .utility) {
      observer?(Self.currentThreadIsMainForTesting())
      if let resolver {
        return DailyNoteLocation(directory: resolver(root), template: nil)
      }
      return Self.dailyNoteLocationOffMain(corpusRoot: root)
    }
    dailyNoteDirectoryTasksByCorpusPath[key] = (token, task)
  }

  func invalidateDailyNoteDirectory(for corpusRoot: URL) {
    let key = corpusRoot.standardizedFileURL.path
    dailyNoteDirectoriesByCorpusPath.removeValue(forKey: key)
    dailyNoteDirectoryTasksByCorpusPath.removeValue(forKey: key)?.task.cancel()
  }

  private func resolvedDailyNoteLocation(corpusRoot: URL) async -> DailyNoteLocation {
    let root = corpusRoot.standardizedFileURL
    let key = root.path
    while true {
      if let cachedDirectory = dailyNoteDirectoriesByCorpusPath[key] {
        return cachedDirectory
      }
      prepareDailyNoteDirectory(for: root)
      guard let pending = dailyNoteDirectoryTasksByCorpusPath[key] else { continue }
      let directory = await pending.task.value
      guard dailyNoteDirectoryTasksByCorpusPath[key]?.token == pending.token else {
        continue
      }
      dailyNoteDirectoryTasksByCorpusPath.removeValue(forKey: key)
      dailyNoteDirectoriesByCorpusPath[key] = directory
      return directory
    }
  }

  func dailyNotePath(corpusRoot: URL, date: Date) async -> URL {
    let location = await resolvedDailyNoteLocation(corpusRoot: corpusRoot)
    if let template = location.template {
      return template.url(for: date, corpusRoot: corpusRoot)
    }
    let directory = location.directory
    let baseName = Self.formatDate(date)
    return await Task.detached(priority: .userInitiated) {
      OrgDocumentDefaults.url(in: directory, baseName: baseName)
    }.value
  }

  /// The configured `roam.dailyFileTemplate` for the active corpus, once
  /// resolved. Nil means the `dailiesDir/YYYY-MM-DD.org` convention applies.
  public var activeDailyNoteTemplate: DailyNoteTemplate? {
    guard let corpusRoot else { return nil }
    return dailyNoteDirectoriesByCorpusPath[corpusRoot.standardizedFileURL.path]?.template
  }

  /// Re-reads daily note configuration after Settings changes celorga.json.
  /// File watching also invalidates it; this avoids waiting for the event.
  public func reloadDailyNoteConfiguration() {
    guard let corpusRoot else { return }
    invalidateDailyNoteDirectory(for: corpusRoot)
    prepareDailyNoteDirectory(for: corpusRoot)
  }

  /// The active corpus's existing daily note for `date`, read from the file
  /// catalog without touching disk so completion can call it per keystroke.
  func existingDailyNoteFile(for date: Date) -> CorpusFile? {
    guard let corpusRoot else { return nil }
    let root = corpusRoot.standardizedFileURL
    let location = dailyNoteDirectoriesByCorpusPath[root.path]
    if let template = location?.template {
      let path = template.url(for: date, corpusRoot: root).path
      return corpusFilesByPath[path] ?? corpusFiles.first { $0.path == path }
    }
    let directory = location?.directory
      ?? root.appendingPathComponent("daily", isDirectory: true).standardizedFileURL
    return Self.existingDailyNoteFile(
      baseName: Self.formatDate(date),
      in: directory,
      filesByPath: corpusFilesByPath,
      corpusFiles: corpusFiles
    )
  }

  nonisolated static func existingDailyNoteFile(
    baseName: String,
    in directory: URL,
    filesByPath: [String: CorpusFile],
    corpusFiles: [CorpusFile]
  ) -> CorpusFile? {
    let candidates = OrgDocumentDefaults.candidateURLs(in: directory, baseName: baseName)
      .map { $0.standardizedFileURL.path }
    for path in candidates {
      if let file = filesByPath[path] { return file }
    }
    // The path index is projected asynchronously after catalog changes.
    let names = Set(candidates.map { NSString(string: $0).lastPathComponent })
    let matches = corpusFiles.filter { names.contains($0.name) && candidates.contains($0.path) }
    return candidates.lazy.compactMap { path in matches.first { $0.path == path } }.first
  }

  /// Completions for an `@` mention in a document editor: date stamps and
  /// daily note links for `@date`, plus the corpus files AI chat offers for
  /// the same query. `sourceFile` is the document receiving the link.
  func dateMentionEditorOptions(
    for match: WorkspaceDateMentionMatch,
    sourceFile: String?
  ) -> [WorkspaceDateMentionOption] {
    WorkspaceDateMentions.editorOptions(
      for: match,
      sourceFile: sourceFile,
      corpusRoot: corpusRoot,
      corpusFiles: corpusFiles,
      linkResolver: orgRoamLinkResolver,
      dailyNoteFile: { existingDailyNoteFile(for: $0.date) }
    )
  }

  func dailyNoteExists(at url: URL) async -> Bool {
    await Task.detached(priority: .userInitiated) {
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && !isDirectory.boolValue
    }.value
  }

  func presentMissingDailyNote(
    at url: URL,
    corpusRoot: URL,
    opensHome: Bool,
    surface: WorkspaceSurface,
    recordsHistory: Bool
  ) {
    let missing = WorkspaceMissingDailyNote(
      file: url.standardizedFileURL.path,
      relativePath: Self.relativePath(for: url.path, root: corpusRoot),
      title: url.deletingPathExtension().lastPathComponent,
      opensHome: opensHome,
      surface: surface
    )
    if recordsHistory,
       missingDailyNote != missing,
       hasWorkspaceDetailContent || selectedSurface != surface {
      recordCurrentNavigationDestination()
    }
    clearDetailForNavigation()
    selectedSurface = surface
    selectedEntrySourceMode = .page
    selectedCorpusFileID = nil
    expandedWorkspaceSurface = nil
    isWorkspaceDetailPaneClosed = false
    isWorkspaceDetailPaneExpanded = false
    isAIChatAssistantPresented = false
    if opensHome {
      currentHomeDailyNotePath = nil
      selectedAIChatThreadRecordID = nil
      isWorkspaceSurfacePaneClosed = false
    } else if surface == .files {
      isWorkspaceSurfacePaneClosed = true
    }
    missingDailyNote = missing
    activeWorkspacePane = .detail
    statusText = "No daily file found"
  }

  func waitForDailyNoteDirectoryPreparationForTesting(corpusRoot: URL) async {
    let key = corpusRoot.standardizedFileURL.path
    prepareDailyNoteDirectory(for: corpusRoot)
    _ = await dailyNoteDirectoryTasksByCorpusPath[key]?.task.value
  }

  func dailyNoteDirectoryForTesting(corpusRoot: URL) async -> URL {
    let url = await dailyNotePath(
      corpusRoot: corpusRoot,
      date: Date(timeIntervalSince1970: 0)
    )
    return url.deletingLastPathComponent().standardizedFileURL
  }

  func waitForDailyNoteNavigationForTesting() async {
    while let task = dailyNoteActivationTask ?? homeActivationTask {
      await task.value
    }
    await awaitCorpusFilePublication()
  }

  func ensureDailyNoteExists(
    at url: URL,
    context: WorkspaceDocumentCorpusContext
  ) async throws {
    let parent = url.deletingLastPathComponent()
    try await performDocumentMutation(
      context: context,
      files: [url.path, parent.path]
    ) { execution in
      let snapshot = try await execution.readSnapshot(at: url, allowMissing: true)
      guard !snapshot.existed else { return }
      let authorizedParent = try execution.authorizeDescendant(parent, ofDeclaredDirectory: parent)
      try FileManager.default.createDirectory(
        at: authorizedParent,
        withIntermediateDirectories: true
      )
      try await execution.commit(DailyNoteTemplate.initialContent(for: url), over: snapshot) {
        text, url, previous in
        try Self.commitDocumentText(
          text,
          url: url,
          previousText: previous,
          operation: "daily note creation"
        )
      }
    }
  }

  nonisolated static func corpusFileOffMain(for url: URL, corpusRoot: URL) -> CorpusFile {
    let standardizedURL = url.standardizedFileURL
    let relativePath = relativePath(for: standardizedURL.path, root: corpusRoot)
    let values = try? standardizedURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return CorpusFile(
      path: standardizedURL.path,
      relativePath: relativePath,
      modifiedAt: values?.contentModificationDate,
      byteCount: values?.fileSize.map(Int64.init)
    )
  }

  func upsertCorpusFile(_ file: CorpusFile) {
    let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
    pendingCorpusFileDeletionPaths.remove(path)
    pendingCorpusFileUpsertsByPath[path] = file
    scheduleCorpusFileCatalogMutation()
  }

  func removeCorpusFile(atPath rawPath: String) {
    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
    pendingCorpusFileUpsertsByPath.removeValue(forKey: path)
    pendingCorpusFileDeletionPaths.insert(path)
    scheduleCorpusFileCatalogMutation()
  }

  func resetCorpusFileCatalogMutations() {
    corpusFileCatalogMutationGeneration &+= 1
    corpusFileCatalogMutationTask?.cancel()
    corpusFileCatalogMutationTask = nil
    pendingCorpusFileUpsertsByPath = [:]
    pendingCorpusFileDeletionPaths = []
  }

  /// Coalesces synchronous save/create bursts into one detached sorted-catalog
  /// update. If a full scan publishes while the update is being prepared, the
  /// delta is replayed against that newer snapshot instead of overwriting it.
  private func scheduleCorpusFileCatalogMutation() {
    guard corpusFileCatalogMutationTask == nil else { return }
    corpusFileCatalogMutationGeneration &+= 1
    let generation = corpusFileCatalogMutationGeneration

    corpusFileCatalogMutationTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self,
            !Task.isCancelled,
            self.corpusFileCatalogMutationGeneration == generation
      else { return }

      while !Task.isCancelled,
            self.corpusFileCatalogMutationGeneration == generation {
        let batchUpserts = self.pendingCorpusFileUpsertsByPath
        let batchDeletions = self.pendingCorpusFileDeletionPaths
        guard !batchUpserts.isEmpty || !batchDeletions.isEmpty else { break }

        self.pendingCorpusFileUpsertsByPath = [:]
        self.pendingCorpusFileDeletionPaths = []
        let changedPaths = batchDeletions.union(batchUpserts.keys)
        let baseFiles = self.corpusFiles
        let baseGeneration = self.corpusFilesGeneration
        let update = await Task.detached(priority: .utility) {
          CorpusFileCatalog.applying(
            changedPaths: changedPaths,
            refreshedFiles: Array(batchUpserts.values),
            to: baseFiles
          )
        }.value
        guard !Task.isCancelled,
              self.corpusFileCatalogMutationGeneration == generation
        else { return }

        guard self.corpusFilesGeneration == baseGeneration else {
          // Mutations collected after this batch always win for the same path.
          for path in changedPaths
          where self.pendingCorpusFileUpsertsByPath[path] == nil
            && !self.pendingCorpusFileDeletionPaths.contains(path) {
            if let file = batchUpserts[path] {
              self.pendingCorpusFileUpsertsByPath[path] = file
            } else {
              self.pendingCorpusFileDeletionPaths.insert(path)
            }
          }
          await Task.yield()
          continue
        }

        if update.didChange {
          self.corpusFiles = update.files
        }
        await Task.yield()
      }

      guard self.corpusFileCatalogMutationGeneration == generation else { return }
      self.corpusFileCatalogMutationTask = nil
      if !self.pendingCorpusFileUpsertsByPath.isEmpty
        || !self.pendingCorpusFileDeletionPaths.isEmpty {
        self.scheduleCorpusFileCatalogMutation()
      }
    }
  }

  nonisolated private static func knowledgeNodePathOffMain(corpusRoot: URL, title: String) -> URL {
    let config = Self.workspaceConfig(corpusRoot: corpusRoot)
    let rawBase = config?.roam?.indexDir?.trimmingCharacters(in: .whitespacesAndNewlines)
    let base: URL
    if let rawBase, !rawBase.isEmpty {
      base = NSString(string: rawBase).isAbsolutePath
        ? URL(fileURLWithPath: rawBase)
        : corpusRoot.appendingPathComponent(rawBase, isDirectory: true)
    } else {
      base = corpusRoot.appendingPathComponent("notes", isDirectory: true)
    }
    return OrgDocumentDefaults.url(in: base, baseName: Self.slug(title))
  }

  private func ensureKnowledgeNode(
    title: String,
    sourceLocation: WorkspaceLocation?
  ) async throws -> CreatedKnowledgeNode {
    guard let corpusRoot else {
      throw WorkspaceEditError.noCorpusRoot
    }
    let cleanTitle = Org2Display.cleanInline(title).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else {
      throw WorkspaceEditError.emptyTitle
    }

    let target = await Task.detached(priority: .userInitiated) {
      Self.knowledgeNodePathOffMain(corpusRoot: corpusRoot, title: cleanTitle)
    }.value
    guard let context = captureDocumentCorpusContext(forFile: target.path) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(
        file: target.path,
        root: corpusRoot.path
      )
    }
    let sourceLink: String
    if let sourceLocation {
      sourceLink = "\nOrigin: [[file:\(relativePath(sourceLocation.file))][\(sourceLocation.title)]]"
    } else {
      sourceLink = ""
    }
    let parent = target.deletingLastPathComponent()
    let id = try await performDocumentMutation(
      context: context,
      files: [target.path, parent.path]
    ) { execution in
      let authorizedParent = try execution.authorizeDescendant(parent, ofDeclaredDirectory: parent)
      try FileManager.default.createDirectory(at: authorizedParent, withIntermediateDirectories: true)
      let snapshot = try await execution.readSnapshot(at: target, allowMissing: true)
      if snapshot.existed {
        return Self.firstOrgID(in: snapshot.text) ?? UUID().uuidString
      }
      let id = UUID().uuidString
      let text = """
      #+TITLE: \(cleanTitle)

      * \(cleanTitle)
      :PROPERTIES:
      :ID: \(id)
      :ORG2_CREATED_AT: \(Self.orgDateTimestamp(Date()))
      :END:
      \(sourceLink)

      """
      try await execution.commit(text, over: snapshot) { text, url, previous in
        try Self.commitDocumentText(
          text,
          url: url,
          previousText: previous,
          operation: "knowledge node creation"
        )
      }
      return id
    }
    return CreatedKnowledgeNode(title: cleanTitle, file: target.path, id: id)
  }

  public func createKnowledgeNode(title: String) async {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }
    let cleanTitle = Org2Display.cleanInline(title).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else {
      statusText = "Knowledge node creation canceled"
      return
    }

    do {
      let node = try await ensureKnowledgeNode(title: cleanTitle, sourceLocation: selectedLocation)
      statusText = "Knowledge node ready -> \(relativePath(node.file))"
      invalidateCanonicalDocumentCache(for: node.file)
      await refreshCorpusFiles()
      searchQuery = "id:\(node.id)"
      selectedSurface = .search
      await runSearch()
    } catch {
      errorText = error.localizedDescription
      statusText = "Knowledge node creation failed"
    }
  }

  /// Presents the New File sheet. The folder defaults to the corpus notes
  /// directory (`roam.nodesDir`, then `roam.indexDir`, then `notes`).
  public func presentNewCorpusFileSheet() {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return
    }
    newCorpusFileDefaultFolder = Self.newCorpusFileDefaultFolder(corpusRoot: corpusRoot)
    newCorpusFileError = nil
    isNewCorpusFileSheetPresented = true
  }

  /// Existing corpus folders, used to suggest a location in the New File sheet.
  public var newCorpusFileFolderSuggestions: [String] {
    var folders = Set(corpusFiles.map(\.directory).filter { !$0.isEmpty && !$0.hasPrefix(".") })
    folders.insert(newCorpusFileDefaultFolder)
    return folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  nonisolated static func newCorpusFileDefaultFolder(corpusRoot: URL) -> String {
    let config = workspaceConfig(corpusRoot: corpusRoot)
    for candidate in [config?.roam?.nodesDir, config?.roam?.indexDir] {
      guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let folder = try? NewCorpusFilePlan.normalizedFolder(raw)
      else { continue }
      return folder
    }
    return NewCorpusFilePlan.defaultFolder
  }

  /// Creates a new document from the New File sheet and opens it. Returns the
  /// created file on success; on failure the sheet stays open with `errorText`.
  @discardableResult
  public func createNewCorpusFile(name: String, folder: String) async -> CorpusFile? {
    guard let corpusRoot else {
      statusText = "No corpus selected"
      return nil
    }
    do {
      let plan = try NewCorpusFilePlan.plan(name: name, folder: folder, corpusRoot: corpusRoot)
      guard let context = captureDocumentCorpusContext(forFile: plan.url.path) else {
        throw WorkspaceDocumentMutationError.outsideCorpus(file: plan.url.path, root: corpusRoot.path)
      }
      let parent = plan.url.deletingLastPathComponent()
      let content = plan.initialContent()
      try await performDocumentMutation(
        context: context,
        files: [plan.url.path, parent.path]
      ) { execution in
        let snapshot = try await execution.readSnapshot(at: plan.url, allowMissing: true)
        guard !snapshot.existed else {
          throw NewCorpusFilePlan.Failure.alreadyExists(plan.relativePath)
        }
        let authorizedParent = try execution.authorizeDescendant(parent, ofDeclaredDirectory: parent)
        try FileManager.default.createDirectory(at: authorizedParent, withIntermediateDirectories: true)
        try await execution.commit(content, over: snapshot) { text, url, previous in
          try Self.commitDocumentText(
            text,
            url: url,
            previousText: previous,
            operation: "new file creation"
          )
        }
      }
      let file = await Task.detached(priority: .userInitiated) {
        Self.corpusFileOffMain(for: plan.url, corpusRoot: corpusRoot)
      }.value
      isNewCorpusFileSheetPresented = false
      newCorpusFileError = nil
      upsertCorpusFile(file)
      openSidebarFile(file)
      statusText = "Created \(plan.relativePath)"
      return file
    } catch {
      newCorpusFileError = error.localizedDescription
      statusText = "Could not create file"
      return nil
    }
  }

  nonisolated public static func selectedText(in text: String, range: NSRange) -> String? {
    trimmedSelection(in: text, range: range)?.text
  }

  nonisolated public static func replacingSelection(
    in text: String,
    range: NSRange,
    with replacement: String
  ) -> InlineSelectionReplacement? {
    guard let swiftRange = Range(range, in: text) else { return nil }
    var output = text
    output.replaceSubrange(swiftRange, with: replacement)
    return InlineSelectionReplacement(
      text: output,
      selectedRange: NSRange(location: range.location, length: (replacement as NSString).length)
    )
  }

  nonisolated public static func backlinkReplacementForSelectedText(
    in text: String,
    range: NSRange
  ) -> InlineSelectionReplacement? {
    guard let selected = trimmedSelection(in: text, range: range) else { return nil }
    return replacingSelection(in: text, range: selected.range, with: "[[\(selected.text)]]")
  }

  nonisolated public static func nodeLinkReplacementForSelectedText(
    in text: String,
    range: NSRange,
    id: String,
    title: String
  ) -> InlineSelectionReplacement? {
    let cleanTitle = Org2Display.cleanInline(title).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { return nil }
    guard let selected = trimmedSelection(in: text, range: range) else { return nil }
    return replacingSelection(in: text, range: selected.range, with: "[[id:\(id)][\(cleanTitle)]]")
  }

  nonisolated private static func trimmedSelection(
    in text: String,
    range: NSRange
  ) -> (text: String, range: NSRange)? {
    guard range.length > 0 else { return nil }
    let ns = text as NSString
    let location = min(max(0, range.location), ns.length)
    let length = min(max(0, range.length), ns.length - location)
    guard length > 0,
          let swiftRange = Range(NSRange(location: location, length: length), in: text)
    else {
      return nil
    }

    var lower = swiftRange.lowerBound
    var upper = swiftRange.upperBound
    while lower < upper, text[lower].isWhitespace {
      lower = text.index(after: lower)
    }
    while lower < upper {
      let beforeUpper = text.index(before: upper)
      guard text[beforeUpper].isWhitespace else { break }
      upper = beforeUpper
    }
    guard lower < upper else { return nil }

    return (
      text: String(text[lower..<upper]),
      range: NSRange(lower..<upper, in: text)
    )
  }

  public func createKnowledgeNodeFromSelection(text: String, range: NSRange) async -> InlineSelectionReplacement? {
    guard let title = Self.selectedText(in: text, range: range) else {
      statusText = "Select text first"
      return nil
    }

    do {
      let node = try await ensureKnowledgeNode(title: title, sourceLocation: selectedLocation)
      invalidateCanonicalDocumentCache(for: node.file)
      await refreshCorpusFiles()
      statusText = "Created node \(relativePath(node.file))"
      return Self.nodeLinkReplacementForSelectedText(in: text, range: range, id: node.id, title: node.title)
    } catch {
      errorText = error.localizedDescription
      statusText = "Create node from selection failed"
      return nil
    }
  }

  func createKnowledgeNodeFromWikiLinkCompletion(
    text: String,
    match: ParagraphWikiLinkCompletionMatch
  ) async -> InlineSelectionReplacement? {
    let title = match.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      statusText = "Type a link title first"
      return nil
    }

    do {
      let node = try await ensureKnowledgeNode(title: title, sourceLocation: selectedLocation)
      invalidateCanonicalDocumentCache(for: node.file)
      await refreshCorpusFiles()
      statusText = "Created node \(relativePath(node.file))"
      return ParagraphWikiLinkCompletion.replacement(
        in: text,
        match: match,
        node: OrgRoamNodeReference(
          idValue: node.id,
          title: node.title,
          file: node.file,
          line: 1
        )
      )
    } catch {
      errorText = error.localizedDescription
      statusText = "Create node from link failed"
      return nil
    }
  }

  public func promptAndCreateKnowledgeNode() {
    guard corpusRoot != nil else {
      statusText = "No corpus selected"
      return
    }

    let alert = NSAlert()
    alert.messageText = "Create Knowledge Node"
    alert.informativeText = "Create a linked Org document in the corpus."
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    field.placeholderString = selectedLocation?.title ?? "New knowledge node"
    alert.accessoryView = field

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    Task { await createKnowledgeNode(title: title.isEmpty ? field.placeholderString ?? "" : title) }
  }

  nonisolated static func captureTagsSuffix(_ raw: String) -> String {
    let tags = raw
      .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
      .map { token in
        token.trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines))
      }
      .filter { !$0.isEmpty }
      .map { tag in
        tag.replacingOccurrences(of: #"[^A-Za-z0-9_@#%.-]"#, with: "_", options: .regularExpression)
      }
      .filter { !$0.isEmpty }
    guard !tags.isEmpty else { return "" }
    return " :\(Array(Set(tags)).sorted().joined(separator: ":")):"
  }

  static func captureTitleCandidate(from raw: String) -> String? {
    let firstLine = raw
      .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstLine, !firstLine.isEmpty else { return nil }
    return String(firstLine.prefix(80))
  }

  static func capturePasteboardContent(from pasteboard: NSPasteboard) -> WorkspaceCapturePasteboardContent {
    var content = WorkspaceCapturePasteboardContent()
    let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    var representedURLStrings: Set<String> = []

    for url in fileURLs {
      representedURLStrings.insert(url.absoluteString)
      if url.isFileURL {
        content.attachments.append(WorkspaceCaptureAttachmentDraft(
          kind: captureAttachmentKind(for: url),
          name: url.lastPathComponent,
          sourceURL: url,
          suggestedExtension: url.pathExtension
        ))
      } else {
        content.attachments.append(WorkspaceCaptureAttachmentDraft(
          kind: .link,
          name: url.host ?? url.absoluteString,
          sourceURL: url
        ))
      }
    }

    if let urlString = pasteboard.string(forType: .URL),
       let url = URL(string: urlString),
       !representedURLStrings.contains(url.absoluteString) {
      representedURLStrings.insert(url.absoluteString)
      content.attachments.append(WorkspaceCaptureAttachmentDraft(
        kind: .link,
        name: url.host ?? url.absoluteString,
        sourceURL: url
      ))
    }

    if fileURLs.isEmpty, let imageData = capturePasteboardImagePNGData(from: pasteboard) {
      content.attachments.append(WorkspaceCaptureAttachmentDraft(
        kind: .image,
        name: "pasted image",
        data: imageData,
        suggestedExtension: "png"
      ))
    }

    if let string = pasteboard.string(forType: .string) {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty && !representedURLStrings.contains(trimmed) {
        content.text = string
      }
    }

    return content
  }

  private static func capturePasteboardImagePNGData(from pasteboard: NSPasteboard) -> Data? {
    if let data = pasteboard.data(forType: .png) {
      return data
    }
    if let data = pasteboard.data(forType: .tiff),
       let bitmap = NSBitmapImageRep(data: data) {
      return bitmap.representation(using: .png, properties: [:])
    }
    if let image = NSImage(pasteboard: pasteboard),
       let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff) {
      return bitmap.representation(using: .png, properties: [:])
    }
    return nil
  }

  private static func captureAttachmentKind(for url: URL) -> WorkspaceCaptureAttachmentKind {
    let ext = url.pathExtension.lowercased()
    if ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "heif", "webp"].contains(ext) {
      return .image
    }
    if ["mov", "mp4", "m4v", "avi", "webm"].contains(ext) {
      return .video
    }
    return .file
  }

  nonisolated static func orgLink(target: String, label: String) -> String {
    let cleanTarget = target.replacingOccurrences(of: "]", with: "%5D")
    let cleanLabel = label
      .replacingOccurrences(of: "[", with: "(")
      .replacingOccurrences(of: "]", with: ")")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return "[[\(cleanTarget)][\(cleanLabel.isEmpty ? cleanTarget : cleanLabel)]]"
  }

  nonisolated static func captureAttachmentFileName(
    for attachment: WorkspaceCaptureAttachmentDraft
  ) -> String {
    let ext = captureAttachmentExtension(for: attachment)
    let baseName = URL(fileURLWithPath: attachment.name).deletingPathExtension().lastPathComponent
    let slug = Self.slug(baseName.isEmpty ? attachment.kind.rawValue : baseName)
    return ext.isEmpty ? slug : "\(slug).\(ext)"
  }

  nonisolated private static func captureAttachmentExtension(
    for attachment: WorkspaceCaptureAttachmentDraft
  ) -> String {
    let suggested = attachment.suggestedExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !suggested.isEmpty { return suggested }
    if let sourceURL = attachment.sourceURL {
      let ext = sourceURL.pathExtension.lowercased()
      if !ext.isEmpty { return ext }
    }
    switch attachment.kind {
    case .image:
      return "png"
    case .video:
      return "mov"
    case .file, .link:
      return ""
    }
  }

  nonisolated static func uniqueAttachmentURL(in directory: URL, fileName: String) -> URL {
    let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    let ext = URL(fileURLWithPath: fileName).pathExtension
    let stamp = captureFileTimestamp(Date())
    var candidate = directory.appendingPathComponent("\(stamp)-\(fileName)")
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      let suffix = ext.isEmpty ? "\(stamp)-\(base)-\(counter)" : "\(stamp)-\(base)-\(counter).\(ext)"
      candidate = directory.appendingPathComponent(suffix)
      counter += 1
    }
    return candidate
  }

  nonisolated private static func captureFileTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }

  nonisolated public static func workspaceHealthChecks(cli: Org2CLI, corpusRoot: URL?) -> [WorkspaceHealthCheck] {
    let fileManager = FileManager.default
    let repoRoot = cli.repoRoot.standardizedFileURL
    let dist = repoRoot.appendingPathComponent("dist", isDirectory: true)
    let cliScript = dist.appendingPathComponent("cli.js")
    let parseScript = dist.appendingPathComponent("parse.js")
    let packageFile = repoRoot.appendingPathComponent("package.json")
    let nodeModules = repoRoot.appendingPathComponent("node_modules", isDirectory: true)
    let macPackage = repoRoot.appendingPathComponent("apps/macos/Org2Workspace/Package.swift")

    var checks: [WorkspaceHealthCheck] = [
      WorkspaceHealthCheck(
        id: "repo-root",
        title: "Repo root",
        status: fileManager.fileExists(atPath: repoRoot.path) ? .ready : .blocking,
        detail: repoRoot.path
      ),
      WorkspaceHealthCheck(
        id: "node-build",
        title: "Node build",
        status: fileManager.fileExists(atPath: cliScript.path) && fileManager.fileExists(atPath: parseScript.path) ? .ready : .blocking,
        detail: fileManager.fileExists(atPath: cliScript.path) && fileManager.fileExists(atPath: parseScript.path)
          ? "dist/cli.js and dist/parse.js are available"
          : "Run npm run build from the repo root",
        remediationTitle: fileManager.fileExists(atPath: cliScript.path) && fileManager.fileExists(atPath: parseScript.path) ? nil : "Build CLI"
      ),
      WorkspaceHealthCheck(
        id: "package-json",
        title: "Package manifest",
        status: fileManager.fileExists(atPath: packageFile.path) ? .ready : .warning,
        detail: fileManager.fileExists(atPath: packageFile.path)
          ? "package.json found"
          : "Repo package.json was not found",
        remediationTitle: fileManager.fileExists(atPath: packageFile.path) ? nil : "Check repo root"
      ),
      WorkspaceHealthCheck(
        id: "node-modules",
        title: "Node dependencies",
        status: fileManager.fileExists(atPath: nodeModules.path) ? .ready : .warning,
        detail: fileManager.fileExists(atPath: nodeModules.path)
          ? "node_modules found"
          : "Run npm install before using local CLI workflows",
        remediationTitle: fileManager.fileExists(atPath: nodeModules.path) ? nil : "Install deps"
      ),
      WorkspaceHealthCheck(
        id: "mac-package",
        title: "Mac package",
        status: fileManager.fileExists(atPath: macPackage.path) ? .ready : .blocking,
        detail: fileManager.fileExists(atPath: macPackage.path)
          ? "Swift package manifest found"
          : "apps/macos/Org2Workspace/Package.swift was not found",
        remediationTitle: fileManager.fileExists(atPath: macPackage.path) ? nil : "Restore package"
      )
    ]

    if let corpusRoot {
      let config = CelorgaNames.configFilePath(in: corpusRoot, fileManager: fileManager)
      let corpusWritable = fileManager.isWritableFile(atPath: corpusRoot.path)
      checks.append(WorkspaceHealthCheck(
        id: "corpus-root",
        title: "Corpus",
        status: fileManager.fileExists(atPath: corpusRoot.path) ? .ready : .blocking,
        detail: corpusRoot.path
      ))
      checks.append(WorkspaceHealthCheck(
        id: "corpus-writable",
        title: "Corpus writable",
        status: corpusWritable ? .ready : .blocking,
        detail: corpusWritable
          ? "App can create notes and capture entries in the selected corpus"
          : "Selected corpus is not writable",
        remediationTitle: corpusWritable ? nil : "Fix permissions"
      ))
      checks.append(WorkspaceHealthCheck(
        id: "corpus-config",
        title: "Corpus config",
        status: fileManager.fileExists(atPath: config.path) ? .ready : .warning,
        detail: fileManager.fileExists(atPath: config.path)
          ? "\(config.lastPathComponent) found"
          : "No celorga.json in selected corpus; defaults will be used",
        remediationTitle: fileManager.fileExists(atPath: config.path) ? nil : "Add config"
      ))
    } else {
      checks.append(WorkspaceHealthCheck(
        id: "corpus-root",
        title: "Corpus",
        status: .blocking,
        detail: "Open a corpus to enable agenda, meetings, search, capture, and notes",
        remediationTitle: "Open Corpus"
      ))
    }

    return checks
  }

  func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  func openFile(path: String, line: Int) {
    let fileURL = URL(fileURLWithPath: path)

    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil {
      var allowed = CharacterSet.urlPathAllowed
      allowed.insert(":")
      let encodedPath = fileURL.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? fileURL.path
      if let url = URL(string: "vscode://file\(encodedPath):\(line):1") {
        NSWorkspace.shared.open(url)
        return
      }
    }

    NSWorkspace.shared.open(fileURL)
  }

  nonisolated static func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  nonisolated static func agendaRefreshEndDate(
    from start: Date,
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> Date {
    calendar.date(byAdding: .day, value: agendaRangeDays - 1, to: start) ?? start
  }

  static func isoDate(_ date: Date) -> String {
    formatDate(date)
  }

  static func dateFromISO(_ raw: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: raw)
  }

  static func dateString(for target: PlanningDateTarget) -> String {
    let calendar = Calendar(identifier: .gregorian)
    let today = Date()
    switch target {
    case .today:
      return formatDate(today)
    case .tomorrow:
      return formatDate(calendar.date(byAdding: .day, value: 1, to: today) ?? today)
    case .upcomingMonday:
      let weekday = calendar.component(.weekday, from: today)
      let delta = weekday == 2 ? 7 : ((9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7)
      return formatDate(calendar.date(byAdding: .day, value: delta, to: today) ?? today)
    case .nextMonth:
      let components = calendar.dateComponents([.year, .month], from: today)
      var next = DateComponents()
      next.year = components.year
      next.month = (components.month ?? 1) + 1
      next.day = 1
      return formatDate(calendar.date(from: next) ?? today)
    }
  }

  static func date(for target: DailyNoteTarget) -> Date {
    let calendar = Calendar(identifier: .gregorian)
    let today = Date()
    switch target {
    case .yesterday:
      return calendar.date(byAdding: .day, value: -1, to: today) ?? today
    case .today:
      return today
    case .tomorrow:
      return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
  }

  static func orgTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
    return "<\(formatter.string(from: date))>"
  }

  nonisolated static func orgDateTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd EEE"
    return "<\(formatter.string(from: date))>"
  }

  nonisolated static func similarTodoCandidates(
    to target: HeadlineMutationTarget,
    from candidates: [SimilarTodoCandidate]
  ) -> [SimilarTodoCandidate] {
    let targetTokens = assignmentSimilarityTokens(target.title)
    let scored = candidates.compactMap { candidate -> SimilarTodoCandidate? in
      guard candidate.todo.map({ !isTerminalTodoStatus($0) }) ?? false else { return nil }
      let score = assignmentSimilarityScore(targetTokens: targetTokens, candidate: candidate.headline)
      let isTarget = candidate.file == target.file && candidate.line == target.line
      guard isTarget || score >= 0.42 else { return nil }
      return SimilarTodoCandidate(
        file: candidate.file,
        line: candidate.line,
        headline: candidate.headline,
        todo: candidate.todo,
        tags: candidate.tags,
        properties: candidate.properties,
        score: isTarget ? max(1, score) : score
      )
    }
    return scored.sorted {
      if $0.score == $1.score {
        if $0.file == $1.file { return $0.line < $1.line }
        return $0.file.localizedStandardCompare($1.file) == .orderedAscending
      }
      return $0.score > $1.score
    }.prefix(75).map { $0 }
  }

  nonisolated private static func assignmentSimilarityTokens(_ title: String) -> [String] {
    title
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .filter { $0.count > 1 }
  }

  nonisolated private static func assignmentSimilarityScore(targetTokens: [String], candidate: String) -> Double {
    let target = Set(targetTokens)
    let candidateTokens = assignmentSimilarityTokens(candidate)
    let other = Set(candidateTokens)
    guard !target.isEmpty, !other.isEmpty else { return 0 }
    let overlap = target.intersection(other).count
    let union = target.union(other).count
    var prefix = 0
    for (lhs, rhs) in zip(targetTokens, candidateTokens) {
      guard lhs == rhs else { break }
      prefix += 1
    }
    return max(Double(overlap) / Double(union), Double(prefix) / Double(max(targetTokens.count, 1)))
  }

  nonisolated static func inferredAssignmentPattern(
    from candidates: [SimilarTodoCandidate],
    fallback: String
  ) -> String {
    let titles = Array(candidates.prefix(8).map(\.headline))
    guard titles.count >= 2 else { return fallback }
    let tokenized = titles.map(assignmentSimilarityTokens)
    guard var prefix = tokenized.first, !prefix.isEmpty else { return fallback }
    for tokens in tokenized.dropFirst() {
      var next: [String] = []
      for (lhs, rhs) in zip(prefix, tokens) where lhs == rhs {
        next.append(lhs)
      }
      prefix = next
      if prefix.isEmpty { break }
    }
    guard prefix.count >= 2 else { return fallback }
    return "\(prefix.joined(separator: " ")) {{target}}"
  }

  nonisolated static func aiChatAssignedBacklogPrompt(
    assignee: String,
    status: String,
    pattern: String,
    items: [SimilarTodoCandidate],
    relativePath: (String) -> String,
    mappedPath: (String) -> String
  ) -> String {
    let refs = items.map { item in
      "- \(mappedPath(item.file)):\(item.line) (\(relativePath(item.file)):\(item.line)) \(item.todo ?? "TODO") \(item.headline)"
    }.joined(separator: "\n")
    return """
    Take a pass on this assigned Celorga backlog.

    Assignee: \(assignee)
    Current assignment status: \(status)
    Repeated task pattern: \(pattern.isEmpty ? "unspecified" : pattern)

    Items:
    \(refs)

    Workflow:
    1. Inspect the repeated task shape and figure out how to complete one representative item.
    2. Apply that approach across the selected backlog items.
    3. Update each org heading as you work so progress is visible in Celorga.

    Update convention:
    - Keep ASSIGNEE: \(assignee)
    - Set STATUS to in_progress while actively working an item.
    - Set STATUS to blocked with a short BLOCKED_REASON property if you cannot complete it.
    - Set STATUS to done and mark the TODO done only when the requested work is complete.
    - Add LAST_AGENT_UPDATE with an org timestamp when you materially update an item.
    - Add concise logbook notes or body notes with evidence/source URLs where useful.

    Do not create a separate runner. Edit the org files directly and keep each item auditable.
    """
  }

  nonisolated static func normalizePriority(_ raw: String) -> String? {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return token.range(of: #"^[A-Z0-9]$"#, options: .regularExpression) == nil ? nil : token
  }

  static func parsePropertyAssignment(_ raw: String) -> (key: String, value: String)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = trimmed.firstIndex(of: "="), separator != trimmed.startIndex else {
      return nil
    }

    let key = String(trimmed[..<separator])
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
    let value = String(trimmed[trimmed.index(after: separator)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard key.range(of: #"^[A-Z0-9_@#%+.-]+$"#, options: .regularExpression) != nil else {
      return nil
    }

    return (key, value)
  }
}
