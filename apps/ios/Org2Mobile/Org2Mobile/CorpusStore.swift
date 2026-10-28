import Combine
import Foundation
import UIKit
@preconcurrency import UserNotifications

@MainActor
final class CorpusStore: ObservableObject {
  @Published private(set) var rootURL: URL?
  @Published private(set) var documents: [OrgDocument] = []
  @Published private(set) var corpusFiles: [CorpusFile] = []
  @Published private(set) var searchIndex = MobileCorpusSearchIndex()
  private var searchTodoSequences: [String] = []
  @Published private(set) var agenda: [AgendaEntry] = []
  @Published private(set) var approvals: [ApprovalEntry] = []
  @Published var isLoading = false
  @Published private(set) var isPreparingCorpus = false
  @Published var errorMessage: String?
  @Published var statusMessage: String?
  @Published var isDocumentPickerPresented = false

  private let bookmarkKey = MobileCaptureWriter.bookmarkKey
  private let cachedRootPathKey = MobileCaptureWriter.cachedRootPathKey
  private let mobileInboxAssetsDirectory = MobileCaptureWriter.mobileInboxAssetsDirectory
  private let cacheFilename = "org2-mobile-corpus-cache.json"
  private let dueTodayNotificationIdentifierPrefix = "org2.due-today.daily"
  private let headingTodoKeywords = Set(OrgTodoStatus.allCases.map(\.rawValue))
  nonisolated private static let viewableFileExtensions = Set([
    "org2", "org", "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml"
  ])
  private var cachedFileCount: Int?
  private var refreshGeneration = 0
  private var cacheHydrationGeneration = 0
  private var hasOpenedCorpusViews = false
  private var hasLoadedCorpusSnapshot = false
  private let documentRenderer = MobileDocumentRenderer()
  private let cacheWriter = MobileCorpusCacheWriter()
  private var resourceObservers: Set<AnyCancellable> = []

  init() {
    for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
      NotificationCenter.default.publisher(for: name).sink { [documentRenderer] _ in
        documentRenderer.releaseResources()
      }.store(in: &resourceObservers)
    }
  }

  var corpusName: String {
    rootURL?.lastPathComponent ?? "No corpus"
  }

  private var hasDisplayedCorpus: Bool {
    !corpusFiles.isEmpty || !documents.isEmpty || !agenda.isEmpty || !approvals.isEmpty
  }

  private var cacheURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: cacheFilename)
  }

  func startRestoringCorpus() {
    Task {
      await Task.yield()
      await restoreCorpus()
    }
  }

  func restoreCorpus() async {
    #if DEBUG
    if let debugCorpusPath = CelorgaNames.environment("ORG2_DEBUG_CORPUS_PATH"),
       !debugCorpusPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let url = URL(fileURLWithPath: debugCorpusPath, isDirectory: true)
      setRootURL(url)
      startBackgroundRefresh()
      return
    }
    #endif

    if let cachedRootPath = UserDefaults.standard.string(forKey: cachedRootPathKey),
       !cachedRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let url = URL(fileURLWithPath: cachedRootPath, isDirectory: true)
      rootURL = url
      statusMessage = "Corpus ready"
    }

    guard let data = UserDefaults.standard.data(forKey: bookmarkKey) ?? MobileCaptureWriter.sharedDefaults.data(forKey: bookmarkKey) else { return }
    restoreBookmarkedCorpus(data)
  }

  private func restoreBookmarkedCorpus(_ data: Data) {
    Task {
      await resolveSavedCorpusBookmark(data)
    }
  }

  private func resolveSavedCorpusBookmark(_ data: Data) async {
    do {
      let resolved = try await Task.detached(priority: .userInitiated) {
        let resolved = try Self.resolveCorpusBookmark(data)
        let refreshedBookmark = resolved.stale ? try? Self.bookmarkData(for: resolved.url) : nil
        return CorpusBookmarkResolution(url: resolved.url, stale: resolved.stale, refreshedBookmark: refreshedBookmark)
      }.value

      if let refreshedBookmark = resolved.refreshedBookmark {
        UserDefaults.standard.set(refreshedBookmark, forKey: bookmarkKey)
        UserDefaults.standard.synchronize()
      }

      setRootURL(resolved.url)
      startBackgroundRefresh()
    } catch {
      if !hasDisplayedCorpus {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        rootURL = nil
        clearCorpusViews()
      }
      errorMessage = "Could not reopen the corpus folder. Please select it again once to refresh Celorga's saved access."
    }
  }

  func selectCorpus(_ url: URL) async {
    do {
      try saveBookmark(for: url)
      setRootURL(url)
      await refresh()
    } catch {
      errorMessage = "Could not save access to the selected folder."
    }
  }

  func prepareCorpusViews() {
    hasOpenedCorpusViews = true
    guard let rootURL else { return }
    if !ProcessInfo.processInfo.isLowPowerModeEnabled {
      documentRenderer.prewarm()
    }
    guard !hasLoadedCorpusSnapshot, !isPreparingCorpus else { return }
    startCacheHydration(matching: rootURL)
  }

  func refresh(priority: TaskPriority = .utility, showsLoading: Bool = true) async {
    guard let rootURL else { return }
    refreshGeneration += 1
    let generation = refreshGeneration
    if showsLoading {
      isLoading = true
    }
    errorMessage = nil
    defer {
      if showsLoading, refreshGeneration == generation {
        isLoading = false
      }
    }

    do {
      let snapshot = try await Task.detached(priority: priority) {
        try Self.buildSnapshot(rootURL: rootURL)
      }.value

      guard self.rootURL == rootURL, refreshGeneration == generation else { return }

      if snapshot.discoveredFileCount == 0 && hasDisplayedCorpus {
        let cachedCount = cachedFileCount ?? documents.count
        let fileText = cachedCount == 1 ? "1 cached file" : "\(cachedCount) cached files"
        statusMessage = "Keeping \(fileText); corpus provider returned 0 files"
        return
      }

      cachedFileCount = snapshot.documents.count
      corpusFiles = snapshot.files
      searchIndex = snapshot.searchIndex
      searchTodoSequences = snapshot.todoSequences
      cacheHydrationGeneration += 1
      isPreparingCorpus = false
      saveCachedCorpus(snapshot, for: rootURL)
      if hasOpenedCorpusViews { documents = snapshot.documents }
      agenda = snapshot.agenda
      approvals = snapshot.approvals
      hasLoadedCorpusSnapshot = true
      scheduleDueTodayNotification(from: snapshot.agenda)

      let fileStatus = snapshot.documents.count == 1 ? "1 file" : "\(snapshot.documents.count) files"
      statusMessage = snapshot.skipped.isEmpty ? fileStatus : "\(fileStatus), \(snapshot.skipped.count) skipped"
      if snapshot.documents.isEmpty && !snapshot.skipped.isEmpty {
        errorMessage = "No readable org files. First skipped file: \(snapshot.skipped[0])"
      }
    } catch {
      guard self.rootURL == rootURL, refreshGeneration == generation else { return }
      errorMessage = error.localizedDescription
    }
  }

  func sendToAIChat(_ action: AIChatApprovalAction, approval: ApprovalEntry, message: String? = nil) async {
    guard rootURL != nil else { return }
    do {
      let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
      let prompt = text?.isEmpty == false ? text! : defaultMessage(for: action, approval: approval)
      try appendAIChatRequest(action: action, title: approval.title, sourceFile: approval.file, sourceLine: approval.line, body: prompt)
      statusMessage = "Added \(action.title.lowercased()) request to the corpus mobile inbox"
    } catch {
      errorMessage = "Could not write to the corpus mobile inbox. Re-select the synced corpus folder and try again."
    }
  }

  func approve(_ approval: ApprovalEntry) async {
    guard rootURL != nil else { return }
    do {
      if approval.isRunApproval {
        try appendRunApprovalDecision(approval, decision: "approved")
        statusMessage = "Queued the exact run approval decision for the agent"
        approvals.removeAll { $0.id == approval.id }
        return
      }
      let url = try approveInCorpus(approval)
      statusMessage = "Approved \(url.lastPathComponent)"
      await refresh()
    } catch let error as CorpusMutationError {
      errorMessage = error.localizedDescription
      await refresh(priority: .userInitiated, showsLoading: false)
    } catch {
      errorMessage = "Could not approve this item in the corpus. Re-select the synced corpus folder and try again."
    }
  }

  func reject(_ approval: ApprovalEntry, endStatus: OrgTodoStatus, reason: String) async {
    guard rootURL != nil else { return }
    do {
      if approval.isRunApproval {
        try appendRunApprovalDecision(approval, decision: "rejected", note: reason)
        statusMessage = "Queued the exact run rejection for the agent"
        approvals.removeAll { $0.id == approval.id }
        return
      }
      let url = try rejectInCorpus(approval, endStatus: endStatus, reason: reason)
      statusMessage = "Rejected \(url.lastPathComponent)"
      await refresh()
    } catch {
      errorMessage = "Could not reject this item in the corpus. Re-select the synced corpus folder and try again."
    }
  }

  func setTodoStatus(_ status: OrgTodoStatus, for entry: AgendaEntry) async {
    guard rootURL != nil else { return }
    do {
      let url = try setTodoStatusInCorpus(status, for: entry)
      statusMessage = "Set \(entry.title.prettyPrintedOrgLinks()) to \(status.rawValue) in \(url.lastPathComponent)"
      await refresh()
    } catch {
      errorMessage = "Could not update this agenda item. Re-select the synced corpus folder and try again."
    }
  }

  func saveMobileNote(title: String, body: String, attachments: [NoteAttachment] = [], scheduledDate: Date? = nil) async {
    guard rootURL != nil else { return }
    do {
      let inboxURL = try appendMobileNote(title: title, body: body, attachments: attachments, scheduledDate: scheduledDate)
      statusMessage = "Queued note in \(inboxURL.lastPathComponent)"
    } catch {
      errorMessage = "Could not write to the corpus mobile inbox. Re-select the synced corpus folder and try again."
    }
  }

  func filePreview(path rawPath: String, line requestedLine: Int?) async throws -> CorpusFilePreview {
    guard let rootURL else { throw CorpusFileError.noCorpus }
    return try await Task.detached(priority: .userInitiated) {
      let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
      defer {
        if hasSecurityAccess {
          rootURL.stopAccessingSecurityScopedResource()
        }
      }
      let baseURL = try Self.corpusBaseURL(for: rootURL)
      let relativePath = try Self.canonicalCorpusRelativePath(rawPath, baseURL: baseURL)
      let url = baseURL.appendingPathComponent(relativePath).standardizedFileURL
      guard try Self.isRegularFile(url) else { throw CorpusFileError.unavailable }
      let content = try String(contentsOf: url, encoding: .utf8)
      let lineCount = max(1, content.utf8.reduce(into: 1) { count, byte in
        if byte == 0x0A { count += 1 }
      })
      let highlightedLine = requestedLine.flatMap { (1...lineCount).contains($0) ? $0 : nil }
      return CorpusFilePreview(
        title: url.lastPathComponent,
        relativePath: relativePath,
        startLine: 1,
        highlightedLine: highlightedLine,
        content: content
      )
    }.value
  }

  /// Reads an image from the synced corpus for inline chat rendering.
  func imageData(path rawPath: String) async throws -> Data {
    guard let rootURL else { throw CorpusFileError.noCorpus }
    return try await Task.detached(priority: .userInitiated) {
      let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
      defer {
        if hasSecurityAccess {
          rootURL.stopAccessingSecurityScopedResource()
        }
      }
      let baseURL = try Self.corpusBaseURL(for: rootURL)
      let relativePath = try Self.canonicalCorpusRelativePath(rawPath, baseURL: baseURL)
      let url = baseURL.appendingPathComponent(relativePath).standardizedFileURL
      guard try Self.isRegularFile(url) else { throw CorpusFileError.unavailable }
      return try Data(contentsOf: url)
    }.value
  }

  /// Copies a synced corpus file (a published PDF or DOCX) into a private
  /// temporary folder so Quick Look can show it outside the security scope.
  func quickLookCopy(path rawPath: String) async throws -> URL {
    guard let rootURL else { throw CorpusFileError.noCorpus }
    return try await Task.detached(priority: .userInitiated) {
      let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
      defer {
        if hasSecurityAccess {
          rootURL.stopAccessingSecurityScopedResource()
        }
      }
      let baseURL = try Self.corpusBaseURL(for: rootURL)
      let relativePath = try Self.canonicalCorpusRelativePath(rawPath, baseURL: baseURL)
      let url = baseURL.appendingPathComponent(relativePath).standardizedFileURL
      guard try Self.isRegularFile(url) else { throw CorpusFileError.unavailable }
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("celorga-quicklook", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let copy = folder.appendingPathComponent(url.lastPathComponent)
      try FileManager.default.copyItem(at: url, to: copy)
      return copy
    }.value
  }

  func pathForDocumentLink(_ link: MobileDocumentLink) async throws -> String {
    guard let nodeID = link.nodeID else { return link.path }
    if !searchIndex.entries.contains(where: { $0.nodeID == nodeID }) { await refresh() }
    let matches = searchIndex.entries.filter { $0.nodeID == nodeID }
    guard matches.count == 1 else {
      throw NSError(domain: "MobileDocumentLink", code: 1, userInfo: [NSLocalizedDescriptionKey:
        matches.isEmpty ? "This entry ID is not available in the selected synced corpus. Refresh the corpus and try again." : "This entry ID appears more than once in the corpus."])
    }
    return matches[0].path
  }

  func entryForDocumentLink(_ link: MobileDocumentLink, preview: CorpusFilePreview) async throws -> MobileSearchEntry? {
    let sequences = searchTodoSequences
    return try await Task.detached(priority: .userInitiated) {
      try MobileDocumentRuntime().resolveEntry(source: preview.content, path: preview.relativePath, selector: link.selector, sequences: sequences)
    }.value
  }

  func renderedDocument(preview: CorpusFilePreview, entry: MobileSearchEntry?) async throws -> MobileRenderedDocument {
    try await documentRenderer.render(
      source: preview.content, path: preview.relativePath, entry: entry,
      sequences: searchTodoSequences, corpusID: rootURL?.standardizedFileURL.path ?? ""
    )
  }

  func clearNotificationBadge() {
    Task {
      try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }
  }

  private func startBackgroundRefresh() {
    Task(priority: .background) {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      await refresh(priority: .background, showsLoading: false)
    }
  }

  private func startCacheHydration(matching rootURL: URL?) {
    cacheHydrationGeneration += 1
    let generation = cacheHydrationGeneration
    isPreparingCorpus = true
    Task {
      await hydrateCachedCorpus(matching: rootURL, generation: generation)
    }
  }

  private func hydrateCachedCorpus(matching rootURL: URL?, generation: Int) async {
    let cacheURL = cacheURL
    defer {
      if cacheHydrationGeneration == generation {
        isPreparingCorpus = false
      }
    }

    guard let restored = await Task.detached(priority: .utility, operation: { () -> (CorpusCacheSnapshot, MobileCorpusSearchIndex)? in
      guard let snapshot = Self.loadValidCachedCorpus(at: cacheURL) else { return nil }
      let entries = snapshot.searchEntries ?? snapshot.files.map {
        MobileSearchEntry(path: $0.relativePath, title: $0.name, parent: "", line: 0, nodeID: "", body: "")
      }
      return (snapshot, MobileCorpusSearchIndex(entries: entries))
    }).value else {
      return
    }

    guard cacheHydrationGeneration == generation else { return }
    let (snapshot, index) = restored

    if let rootURL, snapshot.rootPath != Self.cacheRootPath(for: rootURL) {
      return
    }

    if self.rootURL == nil {
      self.rootURL = URL(fileURLWithPath: snapshot.rootPath, isDirectory: true)
    }
    restoreCachedCorpus(snapshot, index: index)
    UserDefaults.standard.set(snapshot.rootPath, forKey: cachedRootPathKey)
  }

  private func restoreCachedCorpus(for rootURL: URL) {
    startCacheHydration(matching: rootURL)
  }

  private func restoreCachedCorpus(_ snapshot: CorpusCacheSnapshot, index: MobileCorpusSearchIndex) {
    hasLoadedCorpusSnapshot = true
    documents = []
    corpusFiles = snapshot.files
    searchIndex = index
    searchTodoSequences = snapshot.todoSequences ?? []
    agenda = snapshot.agenda
    approvals = snapshot.approvals
    cachedFileCount = snapshot.fileCount
    let fileText = snapshot.fileCount == 1 ? "1 cached file" : "\(snapshot.fileCount) cached files"
    statusMessage = "Loaded \(fileText)"
  }

  private func clearCorpusViews() {
    hasLoadedCorpusSnapshot = false
    isPreparingCorpus = false
    documents = []
    corpusFiles = []
    searchIndex = MobileCorpusSearchIndex()
    searchTodoSequences = []
    agenda = []
    approvals = []
    cachedFileCount = nil
    statusMessage = nil
  }

  nonisolated private static func loadCachedCorpus(at cacheURL: URL) -> CorpusCacheSnapshot? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    return try? JSONDecoder().decode(CorpusCacheSnapshot.self, from: data)
  }

  nonisolated private static func loadValidCachedCorpus(at cacheURL: URL) -> CorpusCacheSnapshot? {
    guard let snapshot = loadCachedCorpus(at: cacheURL),
          snapshot.version == CorpusCacheSnapshot.currentVersion
    else {
      return nil
    }
    return snapshot
  }

  private func saveCachedCorpus(_ refreshSnapshot: CorpusRefreshSnapshot, for rootURL: URL) {
    let cacheSnapshot = CorpusCacheSnapshot(
      version: CorpusCacheSnapshot.currentVersion,
      rootPath: Self.cacheRootPath(for: rootURL),
      cachedAt: Date(),
      fileCount: refreshSnapshot.documents.count,
      files: refreshSnapshot.files,
      searchEntries: refreshSnapshot.searchEntries,
      todoSequences: refreshSnapshot.todoSequences,
      agenda: refreshSnapshot.agenda,
      approvals: refreshSnapshot.approvals
    )

    let destination = cacheURL
    let generation = refreshGeneration
    let writer = cacheWriter
    Task(priority: .utility) {
      await writer.save(cacheSnapshot, to: destination, generation: generation)
    }
  }

  private func setRootURL(_ url: URL) {
    if rootURL != url {
      documentRenderer.releaseResources()
      refreshGeneration += 1
      cacheHydrationGeneration += 1
      clearCorpusViews()
    }
    rootURL = url
    UserDefaults.standard.set(Self.cacheRootPath(for: url), forKey: cachedRootPathKey)
    MobileCaptureWriter.sharedDefaults.set(Self.cacheRootPath(for: url), forKey: cachedRootPathKey)
  }

  nonisolated private static func cacheRootPath(for rootURL: URL) -> String {
    rootURL.standardizedFileURL.path
  }

  nonisolated private static func buildSnapshot(rootURL: URL) throws -> CorpusRefreshSnapshot {
    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let baseURL = try corpusBaseURL(for: rootURL)
    let urls = try corpusFileURLs(in: rootURL)
    let viewerURLs = try corpusViewerFileURLs(in: rootURL)
    var parsed: [OrgDocument] = []
    var skipped: [String] = []

    for url in urls {
      do {
        parsed.append(try OrgParser.parseDocument(at: url, rootURL: baseURL))
      } catch {
        skipped.append("\(url.lastPathComponent): \(error.localizedDescription)")
      }
    }

    let runtime = try MobileDocumentRuntime()
    let sequences = mobileOrg2Config(in: baseURL)?.todo?.sequences ?? []
    let parsedText = Dictionary(parsed.map { ($0.relativePath, $0.body) }, uniquingKeysWith: { first, _ in first })
    var searchEntries: [MobileSearchEntry] = []
    for url in viewerURLs {
      let path = OrgParser.relativePath(for: url, rootURL: baseURL)
      if ["org", "org2"].contains(url.pathExtension.lowercased()) {
        do {
          let source = try parsedText[path] ?? String(contentsOf: url, encoding: .utf8)
          searchEntries += try runtime.index(source: source, path: path, sequences: sequences)
          continue
        } catch {
          skipped.append("\(url.lastPathComponent) search: \(error.localizedDescription)")
        }
      }
      searchEntries.append(MobileSearchEntry(path: path, title: url.lastPathComponent, parent: "", line: 0, nodeID: "", body: ""))
    }

    return CorpusRefreshSnapshot(
      searchIndex: MobileCorpusSearchIndex(entries: searchEntries),
      searchEntries: searchEntries,
      todoSequences: sequences,
      documents: parsed,
      files: viewerURLs.compactMap { corpusFile($0, rootURL: baseURL) },
      agenda: OrgParser.agendaEntries(from: parsed),
      approvals: (OrgParser.approvalEntries(from: parsed) + runApprovalEntries(rootURL: baseURL)).sorted {
        if $0.status != $1.status { return $0.status < $1.status }
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      },
      skipped: skipped,
      discoveredFileCount: urls.count
    )
  }

  nonisolated private static func runApprovalEntries(rootURL: URL) -> [ApprovalEntry] {
    let stateDirectoryName = CelorgaNames.stateDirectoryName(corpusRoot: rootURL)
    let directory = rootURL
      .appendingPathComponent(stateDirectoryName, isDirectory: true)
      .appendingPathComponent("runs", isDirectory: true)
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsPackageDescendants]
    ) else { return [] }

    return urls.filter { ["org", "org2"].contains($0.pathExtension.lowercased()) }.flatMap { url -> [ApprovalEntry] in
      guard let raw = try? String(contentsOf: url, encoding: .utf8),
            let begin = raw.range(of: "#+begin_src json :org2-agent-run", options: .caseInsensitive),
            let end = raw.range(of: "#+end_src", options: .caseInsensitive, range: begin.upperBound..<raw.endIndex) else {
        return []
      }
      let json = raw[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
      guard let data = json.data(using: .utf8),
            let run = try? JSONDecoder().decode(MobileAgentRun.self, from: data) else {
        return []
      }
      let file = "\(stateDirectoryName)/runs/\(url.lastPathComponent)"
      let now = Date()
      return run.approvals.filter { $0.status == "pending" }.compactMap { approval -> ApprovalEntry? in
        let entry = ApprovalEntry(
          id: "run:\(run.id):\(approval.id)",
          title: approval.title,
          status: approval.status,
          todo: nil,
          level: nil,
          file: file,
          line: 1,
          sourceID: approval.id,
          properties: [:],
          body: approval.note ?? approval.action,
          tags: [],
          kind: "run",
          runID: run.id,
          approvalID: approval.id,
          fingerprint: approval.fingerprint,
          action: approval.action,
          riskClass: approval.riskClass,
          snoozedUntil: approval.snoozedUntil
        )
        return entry.isSnoozed(at: now) ? nil : entry
      }
    }
  }

  nonisolated private static func corpusFileURLs(in rootURL: URL) throws -> [URL] {
    if try isRegularFile(rootURL) {
      return OrgParser.isCorpusFile(rootURL) ? [rootURL] : []
    }

    let baseURL = try corpusBaseURL(for: rootURL)
    let config = mobileOrg2Config(in: baseURL)
    let configuredAgendaPatterns = config.map { $0.agendaFiles ?? ["*.org"] }
    let ignorePatterns = config?.ignorePatterns ?? []
    let recursive = config?.recursive ?? true

    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    var urls: [URL] = []
    for case let url as URL in enumerator {
      let relativePath = OrgParser.relativePath(for: url, rootURL: baseURL)
      if shouldSkipCorpusPath(relativePath, url: url, ignorePatterns: ignorePatterns) {
        enumerator.skipDescendants()
        continue
      }
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { continue }
      if values.isDirectory == true, !recursive {
        enumerator.skipDescendants()
        continue
      }
      if values.isRegularFile == true {
        if let agendaPatterns = configuredAgendaPatterns {
          guard agendaPatterns.contains(where: { corpusPath(relativePath, matches: $0) }) else { continue }
        } else {
          guard isDefaultAgendaFile(url) else { continue }
        }
        urls.append(url)
      }
    }
    return urls.sorted { $0.path < $1.path }
  }

  nonisolated private static func corpusViewerFileURLs(in rootURL: URL) throws -> [URL] {
    if try isRegularFile(rootURL) {
      return [rootURL]
    }

    let baseURL = try corpusBaseURL(for: rootURL)
    let config = mobileOrg2Config(in: baseURL)
    let ignorePatterns = config?.ignorePatterns ?? []
    let recursive = config?.recursive ?? true
    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    var urls: [URL] = []
    for case let url as URL in enumerator {
      let relativePath = OrgParser.relativePath(for: url, rootURL: baseURL)
      if shouldSkipCorpusPath(relativePath, url: url, ignorePatterns: ignorePatterns) {
        enumerator.skipDescendants()
        continue
      }
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else { continue }
      if values.isDirectory == true, !recursive {
        enumerator.skipDescendants()
        continue
      }
      if values.isRegularFile == true {
        if viewableFileExtensions.contains(url.pathExtension.lowercased()) {
          urls.append(url)
        }
      }
    }
    return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  nonisolated private static func corpusFile(_ url: URL, rootURL: URL) -> CorpusFile? {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return CorpusFile(
      relativePath: OrgParser.relativePath(for: url, rootURL: rootURL),
      modifiedAt: values?.contentModificationDate,
      byteCount: values?.fileSize.map(Int64.init)
    )
  }

  nonisolated private static func canonicalCorpusRelativePath(
    _ rawPath: String,
    baseURL: URL
  ) throws -> String {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CorpusFileError.invalidPath }
    let canonicalRoot = baseURL.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"

    let expanded = NSString(string: trimmed).expandingTildeInPath
    let directCandidate = URL(fileURLWithPath: expanded)
    let candidate: URL
    if expanded.hasPrefix("/") {
      let direct = directCandidate.standardizedFileURL.resolvingSymlinksInPath()
      if direct.path.hasPrefix(rootPath) {
        candidate = direct
      } else {
        let components = direct.pathComponents
        guard let rootIndex = components.lastIndex(of: canonicalRoot.lastPathComponent),
              rootIndex + 1 < components.count
        else { throw CorpusFileError.invalidPath }
        let suffix = components[(rootIndex + 1)...].joined(separator: "/")
        candidate = canonicalRoot.appendingPathComponent(suffix).standardizedFileURL.resolvingSymlinksInPath()
      }
    } else {
      candidate = canonicalRoot.appendingPathComponent(expanded).standardizedFileURL.resolvingSymlinksInPath()
    }

    guard candidate.path.hasPrefix(rootPath) else { throw CorpusFileError.invalidPath }
    return String(candidate.path.dropFirst(rootPath.count))
  }

  nonisolated private static func mobileOrg2Config(in baseURL: URL) -> MobileOrg2Config? {
    guard let configURL = CelorgaNames.configFile(in: baseURL),
          let data = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONDecoder().decode(MobileOrg2Config.self, from: data)
  }

  nonisolated private static func shouldSkipCorpusPath(_ relativePath: String, url: URL, ignorePatterns: [String]) -> Bool {
    let name = url.lastPathComponent
    if name == ".git" || name == "node_modules" || name.hasPrefix(".#") {
      return true
    }
    if name.hasPrefix(".syncthing.") || name.contains(".sync-conflict-") || name.hasSuffix(".tmp") {
      return true
    }
    return ignorePatterns.contains { corpusPath(relativePath, matches: $0) }
  }

  nonisolated private static func isDefaultAgendaFile(_ url: URL) -> Bool {
    let extensionName = url.pathExtension.lowercased()
    return extensionName == "org" || extensionName == "org2"
  }

  nonisolated private static func corpusPath(_ path: String, matches pattern: String) -> Bool {
    let normalizedPath = normalizedCorpusPath(path)
    let normalizedPattern = normalizedCorpusPath(pattern)
    if normalizedPattern.contains("*") {
      let pathSegments = normalizedPath.split(separator: "/").map(String.init)
      let patternSegments = normalizedPattern.split(separator: "/").map(String.init)
      return matchCorpusSegments(pathSegments, patternSegments)
    }
    return normalizedPath == normalizedPattern || normalizedPath.hasPrefix("\(normalizedPattern)/")
  }

  nonisolated private static func matchCorpusSegments(
    _ pathSegments: [String],
    _ patternSegments: [String],
    pathIndex: Int = 0,
    patternIndex: Int = 0
  ) -> Bool {
    guard patternIndex < patternSegments.count else {
      return pathIndex >= pathSegments.count
    }

    let pattern = patternSegments[patternIndex]
    if pattern == "**" {
      for nextPathIndex in pathIndex...pathSegments.count {
        if matchCorpusSegments(
          pathSegments,
          patternSegments,
          pathIndex: nextPathIndex,
          patternIndex: patternIndex + 1
        ) {
          return true
        }
      }
      return false
    }

    guard pathIndex < pathSegments.count else { return false }
    guard corpusSegment(pathSegments[pathIndex], matches: pattern) else { return false }
    return matchCorpusSegments(
      pathSegments,
      patternSegments,
      pathIndex: pathIndex + 1,
      patternIndex: patternIndex + 1
    )
  }

  nonisolated private static func corpusSegment(_ segment: String, matches pattern: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: pattern)
      .replacingOccurrences(of: "\\*", with: ".*")
    let regex = "^\(escaped)$"
    return segment.range(of: regex, options: .regularExpression) != nil
  }

  nonisolated private static func normalizedCorpusPath(_ path: String) -> String {
    path.replacingOccurrences(of: "\\", with: "/")
      .split(separator: "/", omittingEmptySubsequences: true)
      .joined(separator: "/")
  }

  private func appendAIChatRequest(
    action: AIChatApprovalAction,
    title: String,
    sourceFile: String,
    sourceLine: Int?,
    body: String,
    attachments: [NoteAttachment] = []
  ) throws {
    guard let rootURL else {
      throw CocoaError(.fileNoSuchFile)
    }

    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let createdAt = ISO8601DateFormatter().string(from: Date())
    let fileStamp = createdAt
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: ".", with: "")
    let entryID = "\(fileStamp)-\(action.rawValue)-\(UUID().uuidString.prefix(8))"
    let sourceLineText = sourceLine.map(String.init) ?? ""
    let safeTitle = sanitizeProperty(title)
    let attachmentLinks = attachments
      .map { "- [[file:\(mobileInboxAssetsDirectory)/\(entryID)/\($0.filename)][\($0.filename)]]" }
      .joined(separator: "\n")
    let attachmentsSection = attachmentLinks.isEmpty ? "" : """

    Attachments:
    \(attachmentLinks)
    """

    let content = """

    * TODO Mobile \(action.title): \(safeTitle)
    :PROPERTIES:
    :ID: mobile-\(entryID)
    :KIND: mobile-openclaw-request
    :STATUS: pending
    :ACTION: \(action.rawValue)
    :CREATED_AT: \(createdAt)
    :SOURCE_FILE: \(sanitizeProperty(sourceFile))
    :SOURCE_LINE: \(sourceLineText)
    :END:

    Request:
    \(indentForOrgBody(body.trimmingCharacters(in: .whitespacesAndNewlines)))
    \(attachmentsSection)

    Source:
    - File: \(sourceFile.isEmpty ? "none" : sourceFile)
    - Line: \(sourceLineText.isEmpty ? "none" : sourceLineText)
    """

    try appendMobileInbox(content, attachments: attachments, entryID: entryID, baseURL: try preferredCorpusBaseURL(for: rootURL))
  }

  private func appendRunApprovalDecision(_ approval: ApprovalEntry, decision: String, note: String? = nil) throws {
    guard let runID = approval.runID, let approvalID = approval.approvalID else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let fingerprintArgument = approval.fingerprint.map { " --fingerprint \($0)" } ?? ""
    let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    let noteArgument = cleanNote?.isEmpty == false ? " --note \(cleanNote!)" : ""
    let body = """
    Apply this native Celorga run approval decision with the shared CLI. Verify the immutable identity and fingerprint; do not edit the run machine-state block directly.

    ORG2_RUN_ID: \(runID)
    ORG2_APPROVAL_ID: \(approvalID)
    ORG2_APPROVAL_FINGERPRINT: \(approval.fingerprint ?? "legacy-unavailable")
    ORG2_APPROVAL_DECISION: \(decision)

    Command:
    celorga run approval-decide \(runID) \(approvalID) --decision \(decision) --actor mobile\(fingerprintArgument)\(noteArgument)
    """
    try appendAIChatRequest(
      action: .decide,
      title: approval.title,
      sourceFile: approval.file,
      sourceLine: approval.line,
      body: body
    )
  }

  private func appendMobileNote(title: String, body: String, attachments: [NoteAttachment], scheduledDate: Date?) throws -> URL {
    guard let rootURL else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try MobileCaptureWriter.appendMobileNote(
      rootURL: rootURL,
      title: title,
      body: body,
      attachments: attachments,
      scheduledDate: scheduledDate
    )
  }

  private func approveInCorpus(_ approval: ApprovalEntry) throws -> URL {
    guard let rootURL else {
      throw CocoaError(.fileNoSuchFile)
    }

    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let url = try corpusFileURL(for: approval.file, rootURL: rootURL)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let sourceLines = sourceLines(in: raw)
    let lines = sourceLines.map(\.text)
    guard let headingIndex = headingIndex(in: lines, matching: approval) else {
      throw CorpusMutationError.approvalChanged
    }

    let timestamp = orgTimestamp(Date())
    let pairedSendIndex = pairedSendHeadingIndex(in: lines, approvalHeadingIndex: headingIndex)
    let pairedSendTitle = pairedSendIndex.map { headingTitle(lines[$0]) }
    var replacements: [ScopedLineReplacement] = []
    if let pairedSendIndex {
      replacements.append(try pairedSendReplacement(in: lines, headingIndex: pairedSendIndex, approvalTitle: approval.title, timestamp: timestamp))
    }
    replacements.append(
      try approvalReplacement(
        in: lines,
        headingIndex: headingIndex,
        pairedSendTitle: pairedSendTitle,
        timestamp: timestamp
      )
    )

    let output = try applyingScopedLineReplacements(replacements, to: raw, sourceLines: sourceLines)
    guard try String(contentsOf: url, encoding: .utf8) == raw else {
      throw CorpusMutationError.fileChanged
    }
    try output.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func rejectInCorpus(_ approval: ApprovalEntry, endStatus: OrgTodoStatus, reason: String) throws -> URL {
    guard let rootURL else {
      throw CocoaError(.fileNoSuchFile)
    }

    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let url = try corpusFileURL(for: approval.file, rootURL: rootURL)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let sourceLines = sourceLines(in: raw)
    let lines = sourceLines.map(\.text)
    guard let headingIndex = headingIndex(in: lines, matching: approval) else {
      throw CocoaError(.fileNoSuchFile)
    }

    let timestamp = orgTimestamp(Date())
    let pairedSendIndex = pairedSendHeadingIndex(in: lines, approvalHeadingIndex: headingIndex)
    var replacements: [ScopedLineReplacement] = []
    if let pairedSendIndex,
       let pairedReplacement = pairedSendRejectionReplacement(
        in: lines,
        headingIndex: pairedSendIndex,
        approvalTitle: approval.title,
        endStatus: endStatus,
        reason: reason,
        timestamp: timestamp
       ) {
      replacements.append(pairedReplacement)
    }
    replacements.append(
      approvalRejectionReplacement(
        in: lines,
        headingIndex: headingIndex,
        approval: approval,
        endStatus: endStatus,
        reason: reason,
        timestamp: timestamp
      )
    )

    let output = try applyingScopedLineReplacements(replacements, to: raw, sourceLines: sourceLines)
    guard try String(contentsOf: url, encoding: .utf8) == raw else {
      throw CorpusMutationError.fileChanged
    }
    try output.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func setTodoStatusInCorpus(_ status: OrgTodoStatus, for entry: AgendaEntry) throws -> URL {
    guard let rootURL else {
      throw CocoaError(.fileNoSuchFile)
    }

    let hasSecurityAccess = rootURL.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }

    let url = try corpusFileURL(for: entry.file, rootURL: rootURL)
    let raw = try String(contentsOf: url, encoding: .utf8)
    var lines = raw.components(separatedBy: .newlines)
    guard let headingIndex = headingIndex(in: lines, matching: entry) else {
      throw CocoaError(.fileNoSuchFile)
    }

    lines[headingIndex] = headingLine(lines[headingIndex], settingTodo: status.rawValue)

    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.hasSuffix("\n") {
      output += "\n"
    }
    try output.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func appendMobileInbox(
    _ content: String,
    attachments: [NoteAttachment],
    entryID: String,
    baseURL: URL
  ) throws {
    let inboxURL = MobileCaptureWriter.mobileInboxURL(baseURL: baseURL)
    if !attachments.isEmpty {
      let assetsURL = baseURL.appending(path: "\(mobileInboxAssetsDirectory)/\(entryID)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
      for attachment in attachments {
        try attachment.data.write(to: assetsURL.appending(path: attachment.filename), options: .atomic)
      }
    }

    if !FileManager.default.fileExists(atPath: inboxURL.path) {
      let header = """
      #+TITLE: Celorga Mobile Inbox

      """
      try header.write(to: inboxURL, atomically: true, encoding: .utf8)
    }

    let handle = try FileHandle(forWritingTo: inboxURL)
    defer {
      try? handle.close()
    }
    try handle.seekToEnd()
    if let data = content.data(using: .utf8) {
      try handle.write(contentsOf: data)
    }
  }

  nonisolated private static func corpusBaseURL(for rootURL: URL) throws -> URL {
    try isRegularFile(rootURL) ? rootURL.deletingLastPathComponent() : rootURL
  }

  private func preferredCorpusBaseURL(for rootURL: URL) throws -> URL {
    try Self.isRegularFile(rootURL) ? rootURL.deletingLastPathComponent() : rootURL
  }

  private func corpusFileURL(for relativePath: String, rootURL: URL) throws -> URL {
    if try Self.isRegularFile(rootURL) {
      return rootURL
    }
    return try Self.corpusBaseURL(for: rootURL).appending(path: relativePath)
  }

  nonisolated private static func isRegularFile(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    return values.isRegularFile == true
  }

  private func saveBookmark(for url: URL) throws {
    let data = try Self.bookmarkData(for: url)
    UserDefaults.standard.set(data, forKey: bookmarkKey)
    MobileCaptureWriter.saveSharedCorpusAccess(bookmark: data, rootURL: url)
    UserDefaults.standard.synchronize()
  }

  nonisolated private static func bookmarkData(for url: URL) throws -> Data {
    let hasSecurityAccess = url.startAccessingSecurityScopedResource()
    defer {
      if hasSecurityAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  nonisolated private static func resolveCorpusBookmark(_ data: Data) throws -> CorpusBookmarkResolution {
    var stale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      return CorpusBookmarkResolution(url: url, stale: stale)
    } catch {
      stale = true
      let url = try URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      return CorpusBookmarkResolution(url: url, stale: stale)
    }
  }

  private func defaultMessage(for action: AIChatApprovalAction, approval: ApprovalEntry) -> String {
    switch action {
    case .discuss:
      """
      I need to discuss this approval item before deciding.

      \(approval.whatsappText)
      """
    case .decide:
      approval.whatsappText
    }
  }

  private func sanitizeProperty(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func indentForOrgBody(_ value: String) -> String {
    value
      .components(separatedBy: .newlines)
      .map { $0.isEmpty ? "" : "  \($0)" }
      .joined(separator: "\n")
  }

  private func headingIndex(in lines: [String], matching approval: ApprovalEntry) -> Int? {
    if let line = approval.line {
      let index = line - 1
      if lines.indices.contains(index), isHeading(lines[index]), headingMatchesApproval(lines: lines, index: index, approval: approval) {
        return index
      }
    }

    if let sourceID = approval.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
      for index in lines.indices where isHeading(lines[index]) {
        let properties = propertyDrawerValues(in: lines, headingIndex: index)
        if properties["ID"] == sourceID {
          return index
        }
      }
    }

    let normalizedTitle = normalizedOrgTitle(approval.title)
    return lines.indices.first { index in
      isHeading(lines[index]) && normalizedOrgTitle(headingTitle(lines[index])) == normalizedTitle
    }
  }

  private func headingIndex(in lines: [String], matching entry: AgendaEntry) -> Int? {
    let index = entry.line - 1
    if lines.indices.contains(index),
       isHeading(lines[index]),
       headingMatchesAgendaEntry(lines[index], entry: entry) {
      return index
    }

    let normalizedTitle = normalizedOrgTitle(entry.title)
    return lines.indices.first { index in
      isHeading(lines[index]) && normalizedOrgTitle(headingTitle(lines[index])) == normalizedTitle
    }
  }

  private func headingMatchesAgendaEntry(_ line: String, entry: AgendaEntry) -> Bool {
    normalizedOrgTitle(headingTitle(line)) == normalizedOrgTitle(entry.title)
  }

  private func headingMatchesApproval(lines: [String], index: Int, approval: ApprovalEntry) -> Bool {
    if let sourceID = approval.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
      return propertyDrawerValues(in: lines, headingIndex: index)["ID"] == sourceID
    }
    return normalizedOrgTitle(headingTitle(lines[index])) == normalizedOrgTitle(approval.title)
  }

  private func upsertApprovalProperties(
    in lines: inout [String],
    headingIndex: Int,
    approvalProperties: [String: String],
    timestamp: String
  ) {
    var properties: [String: String] = [
      "STATUS": "approved",
      "APPROVED_AT": timestamp,
    ]

    for key in CelorgaNames.withAliases([
      "ORG2_REVIEW_STATUS",
      "REVIEW_STATUS",
      "REVIEW",
      "FOLLOWUP_STATUS",
      "REPLY_STATUS",
      "ACCESS_POLICY",
      "REVIEW_POLICY",
    ]) where approvalProperties[key] != nil {
      properties[key] = "approved"
    }

    for key in CelorgaNames.withAliases([
      "WAITING_ON",
      "BLOCKED_BY",
      "ORG2_WAITING_ON",
      "NEXT_ACTION",
      "ACTION_REQUIRED",
      "ORG2_NEXT_ACTION",
      "HANDOFF_SUMMARY",
      "ORG2_HANDOFF_SUMMARY",
    ]) {
      guard let value = approvalProperties[key]?.lowercased() else { continue }
      if value.contains("approval") || value.contains("approve") || value.contains("review") || value.contains("avi") {
        properties[key] = "approved"
      }
    }

    upsertProperties(properties, in: &lines, headingIndex: headingIndex)
  }

  private func approvalReplacement(
    in lines: [String],
    headingIndex: Int,
    pairedSendTitle: String?,
    timestamp: String
  ) throws -> ScopedLineReplacement {
    let currentProperties = propertyDrawerValues(in: lines, headingIndex: headingIndex)
    try validateCurrentApprovalHeading(lines: lines, headingIndex: headingIndex, properties: currentProperties)

    let range = headingMetadataRange(in: lines, headingIndex: headingIndex)
    var replacementLines = Array(lines[range])
    replacementLines[0] = headingLine(replacementLines[0], settingTodo: OrgTodoStatus.done.rawValue)
    upsertApprovalProperties(
      in: &replacementLines,
      headingIndex: 0,
      approvalProperties: currentProperties,
      timestamp: timestamp
    )
    if let pairedSendTitle {
      let pairedKey = isSendApprovalTitle(pairedSendTitle) ? "PAIRED_SEND_TODO" : "PAIRED_AGENT_TODO"
      upsertProperties([pairedKey: pairedSendTitle], in: &replacementLines, headingIndex: 0)
    }
    return ScopedLineReplacement(range: range, lines: replacementLines)
  }

  private func upsertRejectionProperties(
    in lines: inout [String],
    headingIndex: Int,
    approval: ApprovalEntry,
    endStatus: OrgTodoStatus,
    reason: String,
    timestamp: String
  ) {
    var properties: [String: String] = [
      "STATUS": "rejected",
      "REJECTED_AT": timestamp,
      "REJECTION_END_STATUS": endStatus.rawValue,
    ]
    // The reason is optional; do not write an empty property.
    let sanitizedReason = sanitizeProperty(reason)
    if !sanitizedReason.isEmpty {
      properties["REJECTION_REASON"] = sanitizedReason
    }

    for key in CelorgaNames.withAliases([
      "ORG2_REVIEW_STATUS",
      "REVIEW_STATUS",
      "REVIEW",
      "FOLLOWUP_STATUS",
      "REPLY_STATUS",
      "ACCESS_POLICY",
      "REVIEW_POLICY",
    ]) where approval.properties[key] != nil {
      properties[key] = "rejected"
    }

    upsertProperties(properties, in: &lines, headingIndex: headingIndex)
  }

  private func approvalRejectionReplacement(
    in lines: [String],
    headingIndex: Int,
    approval: ApprovalEntry,
    endStatus: OrgTodoStatus,
    reason: String,
    timestamp: String
  ) -> ScopedLineReplacement {
    let range = headingMetadataRange(in: lines, headingIndex: headingIndex)
    var replacementLines = Array(lines[range])
    replacementLines[0] = headingLine(replacementLines[0], settingTodo: endStatus.rawValue)
    upsertRejectionProperties(
      in: &replacementLines,
      headingIndex: 0,
      approval: approval,
      endStatus: endStatus,
      reason: reason,
      timestamp: timestamp
    )
    return ScopedLineReplacement(range: range, lines: replacementLines)
  }

  private func scheduleDueTodayNotification(from agenda: [AgendaEntry]) {
    #if DEBUG
    if CelorgaNames.environment("ORG2_DEBUG_SUPPRESS_NOTIFICATIONS") == "1" {
      return
    }
    #endif
    let identifierPrefix = dueTodayNotificationIdentifierPrefix
    let plans = Self.dueTodayNotificationPlans(from: agenda, identifierPrefix: identifierPrefix)
    Task {
      let center = UNUserNotificationCenter.current()
      let settings = await center.notificationSettings()
      if settings.authorizationStatus == .notDetermined {
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
      }
      let refreshedSettings = await center.notificationSettings()
      guard refreshedSettings.authorizationStatus == .authorized || refreshedSettings.authorizationStatus == .provisional else { return }

      let pendingIDs = await center.pendingNotificationRequests()
        .map(\.identifier)
        .filter { $0 == identifierPrefix || $0.hasPrefix("\(identifierPrefix).") }
      if !pendingIDs.isEmpty {
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
      }

      if plans.isEmpty {
        try? await center.setBadgeCount(0)
        return
      }

      for plan in plans {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "org2.agenda.due-today"
        content.title = "Celorga due today"
        content.body = Self.dueTodayNotificationBody(for: plan.entries)
        content.sound = .default
        content.badge = NSNumber(value: plan.entries.count)

        let trigger = UNCalendarNotificationTrigger(dateMatching: plan.dateComponents, repeats: false)
        let request = UNNotificationRequest(identifier: plan.identifier, content: content, trigger: trigger)
        try? await center.add(request)
      }
    }
  }

  private struct DueTodayNotificationPlan {
    let identifier: String
    let dateComponents: DateComponents
    let entries: [AgendaEntry]
  }

  private static func dueTodayNotificationPlans(
    from agenda: [AgendaEntry],
    now: Date = Date(),
    calendar: Calendar = .current,
    identifierPrefix: String
  ) -> [DueTodayNotificationPlan] {
    let activeAgenda = agenda.filter {
      !$0.todo.uppercased().hasPrefix("DONE") && !$0.todo.uppercased().hasPrefix("CANCEL")
    }
    let groupedByDate = Dictionary(grouping: activeAgenda, by: \.date)

    return groupedByDate.keys.sorted().compactMap { day in
      guard let dayDate = Date.org2DayFormatter.date(from: day) else { return nil }
      let notificationDate = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: dayDate) ?? dayDate
      guard notificationDate > now, let entries = groupedByDate[day], !entries.isEmpty else { return nil }

      return DueTodayNotificationPlan(
        identifier: "\(identifierPrefix).\(day)",
        dateComponents: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: notificationDate),
        entries: entries
      )
    }
  }

  nonisolated private static func dueTodayNotificationBody(for entries: [AgendaEntry]) -> String {
    let titles = entries.prefix(3).map { $0.title.prettyPrintedOrgLinks() }
    let remaining = entries.count - titles.count
    let suffix = remaining > 0 ? " and \(remaining) more" : ""
    return "\(entries.count) item\(entries.count == 1 ? "" : "s"): \(titles.joined(separator: ", "))\(suffix)"
  }

  private func pairedSendReplacement(
    in lines: [String],
    headingIndex: Int,
    approvalTitle: String,
    timestamp: String
  ) throws -> ScopedLineReplacement {
    let properties = propertyDrawerValues(in: lines, headingIndex: headingIndex)
    try validateCurrentPairedSendHeading(lines: lines, headingIndex: headingIndex, properties: properties)

    let range = headingMetadataRange(in: lines, headingIndex: headingIndex)
    var replacementLines = Array(lines[range])
    replacementLines[0] = headingLine(replacementLines[0], settingTodo: OrgTodoStatus.todo.rawValue)
    let sendTitle = headingTitle(lines[headingIndex])
    upsertProperties(
      [
        "STATUS": approvedAgentActionStatus(for: sendTitle),
        "ASSIGNEE": "OpenClaw",
        "APPROVED_AT": timestamp,
        "APPROVAL_TODO": approvalTitle,
      ],
      in: &replacementLines,
      headingIndex: 0
    )
    return ScopedLineReplacement(range: range, lines: replacementLines)
  }

  private func pairedSendRejectionReplacement(
    in lines: [String],
    headingIndex: Int,
    approvalTitle: String,
    endStatus: OrgTodoStatus,
    reason: String,
    timestamp: String
  ) -> ScopedLineReplacement? {
    let properties = propertyDrawerValues(in: lines, headingIndex: headingIndex)
    if let todo = headingTodo(lines[headingIndex]),
       OrgTodoStatus(rawValue: todo.uppercased())?.isTerminal == true {
      return nil
    }
    if sentEvidence(in: properties) != nil {
      return nil
    }

    let range = headingMetadataRange(in: lines, headingIndex: headingIndex)
    var replacementLines = Array(lines[range])
    replacementLines[0] = headingLine(replacementLines[0], settingTodo: endStatus.rawValue)
    var pairedProperties = [
      "STATUS": "rejected",
      "REJECTED_AT": timestamp,
      "REJECTION_END_STATUS": endStatus.rawValue,
      "REJECTED_APPROVAL_TODO": approvalTitle,
    ]
    let sanitizedReason = sanitizeProperty(reason)
    if !sanitizedReason.isEmpty {
      pairedProperties["REJECTION_REASON"] = sanitizedReason
    }
    upsertProperties(
      pairedProperties,
      in: &replacementLines,
      headingIndex: 0
    )
    return ScopedLineReplacement(range: range, lines: replacementLines)
  }

  private func pairedSendHeadingIndex(in lines: [String], approvalHeadingIndex: Int) -> Int? {
    let approvalProperties = propertyDrawerValues(in: lines, headingIndex: approvalHeadingIndex)
    for key in ["PAIRED_SEND_TODO", "PAIRED_AGENT_TODO", "PAIRED_TODO", "NEXT_AGENT_TODO", "SEND_TODO"] {
      guard let pairedTitle = approvalProperties[key], !pairedTitle.isEmpty else { continue }
      let normalizedPairedTitle = normalizedOrgTitle(pairedTitle)
      if let match = lines.indices.first(where: { index in
        isHeading(lines[index]) && normalizedOrgTitle(headingTitle(lines[index])) == normalizedPairedTitle
      }) {
        return match
      }
    }

    guard let approvalLevel = headingLevel(lines[approvalHeadingIndex]) else { return nil }
    var index = approvalHeadingIndex - 1
    while index >= 0 {
      if isHeading(lines[index]), let level = headingLevel(lines[index]), level < approvalLevel {
        return isApprovedAgentActionTitle(headingTitle(lines[index])) ? index : nil
      }
      index -= 1
    }

    return nil
  }

  private func isApprovalTitle(_ title: String) -> Bool {
    title.range(of: #"^Approve\b"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private func isSendApprovalTitle(_ title: String) -> Bool {
    title.range(of: #"^Send approved\b"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private func isApprovedAgentActionTitle(_ title: String) -> Bool {
    title.range(of: #"^(Send approved|Continue approved)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
  }

  private func approvedAgentActionStatus(for title: String) -> String {
    isSendApprovalTitle(title) ? "approved-to-send" : "ready-for-agent"
  }

  private func validateCurrentApprovalHeading(
    lines: [String],
    headingIndex: Int,
    properties: [String: String]
  ) throws {
    if let todo = headingTodo(lines[headingIndex]),
       OrgTodoStatus(rawValue: todo.uppercased())?.isTerminal == true {
      throw CorpusMutationError.approvalChanged
    }

    if let status = properties["STATUS"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
       ["approved", "sent", "done", "closed", "complete", "completed"].contains(status) {
      throw CorpusMutationError.approvalChanged
    }
  }

  private func validateCurrentPairedSendHeading(
    lines: [String],
    headingIndex: Int,
    properties: [String: String]
  ) throws {
    if let todo = headingTodo(lines[headingIndex]),
       OrgTodoStatus(rawValue: todo.uppercased())?.isTerminal == true {
      throw CorpusMutationError.pairedSendAlreadyClosed
    }

    if let evidence = sentEvidence(in: properties) {
      throw CorpusMutationError.pairedSendAlreadySent(evidence)
    }
  }

  private func sentEvidence(in properties: [String: String]) -> String? {
    for key in ["SENT_AT", "GMAIL_SENT_MESSAGE_ID"] {
      if properties[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        return key
      }
    }

    if let status = properties["STATUS"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
       ["sent", "bounced", "bounce", "contact-route", "contact-route-needed", "contact-route-missing"].contains(status) {
      return "STATUS=\(status)"
    }
    return nil
  }

  private func headingMetadataRange(in lines: [String], headingIndex: Int) -> Range<Int> {
    if let drawer = propertyDrawerRange(in: lines, headingIndex: headingIndex) {
      return headingIndex..<(drawer.end + 1)
    }
    return headingIndex..<(headingIndex + 1)
  }

  private func sourceLines(in raw: String) -> [SourceLine] {
    var lines: [SourceLine] = []
    var lineStart = raw.startIndex
    var index = raw.startIndex
    while index < raw.endIndex {
      if raw[index] == "\n" {
        let nextIndex = raw.index(after: index)
        var textEnd = index
        var terminatorStart = index
        if textEnd > lineStart {
          let previous = raw.index(before: textEnd)
          if raw[previous] == "\r" {
            textEnd = previous
            terminatorStart = previous
          }
        }
        lines.append(
          SourceLine(
            text: String(raw[lineStart..<textEnd]),
            range: lineStart..<nextIndex,
            terminator: String(raw[terminatorStart..<nextIndex])
          )
        )
        lineStart = nextIndex
        index = nextIndex
      } else {
        index = raw.index(after: index)
      }
    }

    if lineStart < raw.endIndex {
      var textEnd = raw.endIndex
      var terminatorStart = raw.endIndex
      let previous = raw.index(before: textEnd)
      if raw[previous] == "\r" {
        textEnd = previous
        terminatorStart = previous
      }
      lines.append(
        SourceLine(
          text: String(raw[lineStart..<textEnd]),
          range: lineStart..<raw.endIndex,
          terminator: String(raw[terminatorStart..<raw.endIndex])
        )
      )
    }
    return lines
  }

  private func applyingScopedLineReplacements(
    _ replacements: [ScopedLineReplacement],
    to raw: String,
    sourceLines: [SourceLine]
  ) throws -> String {
    let sorted = replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
    let lineEnding = sourceLines.first(where: { !$0.terminator.isEmpty })?.terminator ?? "\n"
    var previousUpperBound = 0
    var cursor = raw.startIndex
    var output = ""

    for replacement in sorted {
      guard replacement.range.lowerBound >= previousUpperBound,
            replacement.range.lowerBound >= 0,
            replacement.range.upperBound <= sourceLines.count,
            replacement.range.lowerBound < replacement.range.upperBound
      else {
        throw CorpusMutationError.invalidScopedPatch
      }

      let start = sourceLines[replacement.range.lowerBound].range.lowerBound
      let end = sourceLines[replacement.range.upperBound - 1].range.upperBound
      output += String(raw[cursor..<start])
      output += replacement.lines.joined(separator: lineEnding)
      output += sourceLines[replacement.range.upperBound - 1].terminator
      cursor = end
      previousUpperBound = replacement.range.upperBound
    }

    output += String(raw[cursor..<raw.endIndex])
    return output
  }

  private func upsertProperties(_ properties: [String: String], in lines: inout [String], headingIndex: Int) {
    guard let drawer = propertyDrawerRange(in: lines, headingIndex: headingIndex) else {
      let inserted = [":PROPERTIES:"]
        + properties.sorted { $0.key < $1.key }.map { ":\($0.key): \($0.value)" }
        + [":END:"]
      lines.insert(contentsOf: inserted, at: min(headingIndex + 1, lines.count))
      return
    }

    var pending = properties
    var index = drawer.start + 1
    while index < drawer.end {
      let key = propertyKey(in: lines[index])
      if let key, let value = pending[key] {
        lines[index] = ":\(key): \(value)"
        pending.removeValue(forKey: key)
      }
      index += 1
    }

    if !pending.isEmpty {
      let inserted = pending.sorted { $0.key < $1.key }.map { ":\($0.key): \($0.value)" }
      lines.insert(contentsOf: inserted, at: drawer.end)
    }
  }

  private func propertyDrawerValues(in lines: [String], headingIndex: Int) -> [String: String] {
    guard let drawer = propertyDrawerRange(in: lines, headingIndex: headingIndex) else { return [:] }
    var properties: [String: String] = [:]
    for index in (drawer.start + 1)..<drawer.end {
      guard let key = propertyKey(in: lines[index]) else { continue }
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      guard let secondColon = trimmed.dropFirst().firstIndex(of: ":") else { continue }
      let valueStart = trimmed.index(after: secondColon)
      properties[key] = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
    }
    return properties
  }

  private func propertyDrawerRange(in lines: [String], headingIndex: Int) -> (start: Int, end: Int)? {
    var index = headingIndex + 1
    while index < lines.count {
      if isHeading(lines[index]) { return nil }
      if lines[index].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:" {
        var end = index + 1
        while end < lines.count {
          if isHeading(lines[end]) { return nil }
          if lines[end].trimmingCharacters(in: .whitespaces).uppercased() == ":END:" {
            return (index, end)
          }
          end += 1
        }
        return nil
      }
      index += 1
    }
    return nil
  }

  private func propertyKey(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(":"),
          let secondColon = trimmed.dropFirst().firstIndex(of: ":")
    else {
      return nil
    }
    let keyStart = trimmed.index(after: trimmed.startIndex)
    let key = String(trimmed[keyStart..<secondColon]).uppercased()
    return key.isEmpty ? nil : key
  }

  private func headingLine(_ line: String, settingTodo todo: String) -> String {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return line }
    var rest = line.dropFirst(stars.count).trimmingCharacters(in: .whitespaces)
    if let first = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
       headingTodoKeywords.contains(String(first).uppercased()) {
      rest = rest.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
    }
    return "\(stars) \(todo) \(rest)"
  }

  private func isHeading(_ line: String) -> Bool {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return false }
    return line.dropFirst(stars.count).first?.isWhitespace == true
  }

  private func headingLevel(_ line: String) -> Int? {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty, line.dropFirst(stars.count).first?.isWhitespace == true else { return nil }
    return stars.count
  }

  private func headingTodo(_ line: String) -> String? {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return nil }
    let rest = line.dropFirst(stars.count).trimmingCharacters(in: .whitespaces)
    guard let first = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else {
      return nil
    }
    let todo = String(first).uppercased()
    return headingTodoKeywords.contains(todo) ? todo : nil
  }

  private func headingTitle(_ line: String) -> String {
    let stars = line.prefix { $0 == "*" }
    guard !stars.isEmpty else { return line }
    var rest = line.dropFirst(stars.count).trimmingCharacters(in: .whitespaces)
    if let first = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
       headingTodoKeywords.contains(String(first).uppercased()) {
      rest = rest.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
    }
    if rest.hasPrefix("[#"), let close = rest.firstIndex(of: "]") {
      rest = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
    }
    if let tagRange = rest.range(of: #"\s+(:[A-Za-z0-9_@#%.-]+(?::[A-Za-z0-9_@#%.-]+)*:)\s*$"#, options: .regularExpression) {
      rest.removeSubrange(tagRange)
    }
    return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizedOrgTitle(_ title: String) -> String {
    title.prettyPrintedOrgLinks()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .lowercased()
  }

  private func orgTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd EEE HH:mm"
    return "<\(formatter.string(from: date))>"
  }
}

private struct MobileOrg2Config: Decodable {
  struct Todo: Decodable { let sequences: [String]? }
  let todo: Todo?
  let agendaFiles: [String]?
  let recursive: Bool?
  let ignorePatterns: [String]?
}

private struct MobileAgentRun: Decodable {
  let id: String
  let approvals: [MobileAgentRunApproval]
}

private struct MobileAgentRunApproval: Decodable {
  let id: String
  let fingerprint: String?
  let title: String
  let action: String
  let riskClass: String
  let status: String
  let note: String?
  /// Set by `celorga run approval-snooze`; hidden here until it passes.
  let snoozedUntil: String?
}

private struct CorpusRefreshSnapshot {
  let searchIndex: MobileCorpusSearchIndex
  let searchEntries: [MobileSearchEntry]
  let todoSequences: [String]
  let documents: [OrgDocument]
  let files: [CorpusFile]
  let agenda: [AgendaEntry]
  let approvals: [ApprovalEntry]
  let skipped: [String]
  let discoveredFileCount: Int
}

private struct SourceLine {
  let text: String
  let range: Range<String.Index>
  let terminator: String
}

private struct ScopedLineReplacement {
  let range: Range<Int>
  let lines: [String]
}

private struct CorpusCacheSnapshot: Codable, Sendable {
  static let currentVersion = 2

  let version: Int
  let rootPath: String
  let cachedAt: Date
  let fileCount: Int
  let files: [CorpusFile]
  let searchEntries: [MobileSearchEntry]?
  let todoSequences: [String]?
  let agenda: [AgendaEntry]
  let approvals: [ApprovalEntry]
}

private enum CorpusFileError: LocalizedError {
  case noCorpus
  case invalidPath
  case unavailable

  var errorDescription: String? {
    switch self {
    case .noCorpus:
      "Select a synced corpus folder first."
    case .invalidPath:
      "That file is outside the selected corpus."
    case .unavailable:
      "That file is no longer available on this phone."
    }
  }
}

private struct CorpusBookmarkResolution: Sendable {
  let url: URL
  let stale: Bool
  var refreshedBookmark: Data?
}

private enum CorpusMutationError: LocalizedError {
  case approvalChanged
  case fileChanged
  case pairedSendAlreadyClosed
  case pairedSendAlreadySent(String)
  case invalidScopedPatch

  var errorDescription: String? {
    switch self {
    case .approvalChanged:
      "This approval changed on disk. Refresh and review the current entry before approving."
    case .fileChanged:
      "The file changed while Celorga was applying the approval. Refresh and try again."
    case .pairedSendAlreadyClosed:
      "The paired send task is already closed. Celorga will not reopen it from an approval."
    case .pairedSendAlreadySent(let evidence):
      "The paired send task already has sent evidence (\(evidence)). Celorga will not reopen it."
    case .invalidScopedPatch:
      "Celorga could not build a safe scoped patch for this approval."
    }
  }
}
