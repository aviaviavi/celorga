import Combine
import Foundation
import UIKit
@preconcurrency import UserNotifications

/// The host corpus as seen from the phone. The phone keeps no corpus: it
/// lists, searches, and reads files through the paired host, keeps copies only
/// of files the user chose to download, and queues captures until the host
/// has stored them.
@MainActor
final class CorpusStore: ObservableObject {
  @Published private(set) var corpusName = "Host corpus"
  @Published private(set) var corpusFiles: [CorpusFile] = []
  @Published private(set) var catalogUpdatedAt: Date?
  /// Files kept on this phone for reading without the host, by host path.
  @Published private(set) var downloads: [String: MobileDownloadedFile] = [:]
  @Published private(set) var pendingCaptures: [MobileCaptureOutbox.Item] = []
  @Published private(set) var isSendingCaptures = false
  @Published private(set) var captureError: String?
  @Published private(set) var connectionError: String?
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var statusMessage: String?

  private let remote: MobileRemoteStore
  private var todoSequences: [String] = []
  private var loadedHostKey: String?
  private let documentRenderer = MobileDocumentRenderer()
  private var observers: Set<AnyCancellable> = []
  private let dueTodayNotificationIdentifierPrefix = "org2.due-today.daily"

  /// Hosts answer quickly over the tailnet; a downloaded copy is shown
  /// instead when the host does not answer within this time.
  private static let downloadedPreviewTimeout: TimeInterval = 6

  init(remote: MobileRemoteStore) {
    self.remote = remote
    for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
      NotificationCenter.default.publisher(for: name).sink { [documentRenderer] _ in
        documentRenderer.releaseResources()
      }.store(in: &observers)
    }
    remote.$activeHostID
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        Task { @MainActor in self?.hostDidChange() }
      }
      .store(in: &observers)
    remote.$isConnected
      .removeDuplicates()
      .filter { $0 }
      .sink { [weak self] _ in
        Task { @MainActor in await self?.hostDidConnect() }
      }
      .store(in: &observers)
  }

  var isPaired: Bool { remote.isPaired }

  var downloadedFiles: [MobileDownloadedFile] {
    downloads.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  var downloadedByteCount: Int64 {
    downloads.values.reduce(0) { $0 + $1.byteCount }
  }

  func isDownloaded(_ path: String) -> Bool {
    downloads[path] != nil
  }

  // MARK: Startup

  func start() {
    Self.removeLegacyLocalCorpusState()
    reloadPendingCaptures()
    loadHostState()
    Task {
      await sendPendingCaptures()
      if remote.isPaired { await refresh(showsLoading: false) }
    }
  }

  private func hostDidChange() {
    documentRenderer.releaseResources()
    loadHostState()
    Task {
      await sendPendingCaptures()
      await refresh(showsLoading: false)
    }
  }

  private func hostDidConnect() async {
    await sendPendingCaptures()
    if catalogUpdatedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
      await refresh(showsLoading: false)
    }
  }

  private var hostKey: String {
    remote.activeHostID?.uuidString ?? "unpaired"
  }

  private func loadHostState() {
    let key = hostKey
    loadedHostKey = key
    let storage = MobileHostStorage(hostKey: key)
    if let cached = storage.loadCatalog() {
      applyCatalog(cached.catalog, updatedAt: cached.updatedAt)
    } else {
      corpusName = remote.status?.corpusName ?? "Host corpus"
      corpusFiles = []
      todoSequences = []
      catalogUpdatedAt = nil
    }
    downloads = storage.loadDownloads()
  }

  /// Earlier versions read a synced corpus folder. Forget its bookmark and
  /// disposable index so nothing on the phone points at it any more.
  private static func removeLegacyLocalCorpusState() {
    let keys = ["org2.mobile.corpusBookmark", "org2.mobile.cachedRootPath"]
    for defaults in [UserDefaults.standard, MobileCaptureWriter.sharedDefaults] {
      for key in keys { defaults.removeObject(forKey: key) }
    }
    let legacyCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("org2-mobile-corpus-cache.json")
    try? FileManager.default.removeItem(at: legacyCache)
  }

  // MARK: Catalog

  func refresh(showsLoading: Bool = true) async {
    guard remote.isPaired else {
      connectionError = nil
      return
    }
    let key = hostKey
    if showsLoading { isLoading = true }
    defer { if showsLoading { isLoading = false } }
    do {
      let catalog = try await remote.corpusCatalog()
      guard key == hostKey else { return }
      let now = Date()
      applyCatalog(catalog, updatedAt: now)
      MobileHostStorage(hostKey: key).saveCatalog(catalog, updatedAt: now)
      connectionError = nil
      await refreshDownloads(catalog: catalog, hostKey: key)
      await sendPendingCaptures()
    } catch {
      guard key == hostKey else { return }
      connectionError = remote.status?.supportsCorpusAccess == false
        ? "Update Celorga on \(remote.serverName) to browse its files from this phone."
        : error.localizedDescription
    }
  }

  private func applyCatalog(_ catalog: MobileRemoteCorpusCatalog, updatedAt: Date) {
    corpusName = catalog.corpusName
    todoSequences = catalog.todoSequences
    corpusFiles = catalog.files.map {
      CorpusFile(relativePath: $0.path, modifiedAt: $0.modifiedAt, byteCount: $0.byteCount)
    }
    catalogUpdatedAt = updatedAt
  }

  // MARK: Search

  /// File names match on the phone; headings and text match on the host.
  /// Without the host, only downloaded files are searched.
  func search(_ query: String) async -> [MobileSearchEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let fileEntries = corpusFiles.map {
      MobileSearchEntry(path: $0.relativePath, title: $0.name, parent: "", line: 0, nodeID: "", body: "")
    }
    let fileMatches = await Task.detached(priority: .userInitiated) {
      MobileCorpusSearchIndex(entries: fileEntries).search(trimmed, limit: 8)
    }.value
    var hostMatches: [MobileSearchEntry] = []
    if remote.isPaired {
      do {
        hostMatches = try await remote.searchCorpus(trimmed).map {
          MobileSearchEntry(path: $0.path, title: $0.title, parent: $0.parent, line: $0.line, nodeID: $0.nodeID, body: $0.snippet)
        }
      } catch {
        guard !Task.isCancelled else { return [] }
        hostMatches = await searchDownloads(trimmed)
      }
    } else {
      hostMatches = await searchDownloads(trimmed)
    }
    var seen: Set<String> = []
    return (fileMatches + hostMatches).filter { seen.insert($0.id).inserted }
  }

  private func searchDownloads(_ query: String) async -> [MobileSearchEntry] {
    let storage = MobileHostStorage(hostKey: hostKey)
    let files = downloadedFiles.filter { ["org", "org2"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
    let sequences = todoSequences
    return await Task.detached(priority: .userInitiated) {
      guard let runtime = try? MobileDocumentRuntime() else { return [] }
      var entries: [MobileSearchEntry] = []
      for file in files {
        guard let source = try? String(contentsOf: storage.downloadURL(for: file.path), encoding: .utf8) else { continue }
        entries += (try? runtime.index(source: source, path: file.path, sequences: sequences)) ?? []
      }
      return MobileCorpusSearchIndex(entries: entries).search(query)
    }.value
  }

  // MARK: Reading

  func filePreview(path rawPath: String, line requestedLine: Int?) async throws -> CorpusFilePreview {
    let local = downloads[normalizedPath(rawPath)]
    guard remote.isPaired else {
      if let local { return try localPreview(local, line: requestedLine) }
      throw MobileCorpusError.notPaired
    }
    do {
      let fetched = try await remote.filePreview(
        path: rawPath,
        line: requestedLine,
        timeout: local == nil ? 60 : Self.downloadedPreviewTimeout
      )
      if let local {
        updateDownload(local, content: fetched.content)
      }
      return CorpusFilePreview(
        title: fetched.title,
        relativePath: fetched.relativePath,
        startLine: fetched.startLine,
        highlightedLine: fetched.highlightedLine,
        content: fetched.content
      )
    } catch {
      if let local { return try localPreview(local, line: requestedLine) }
      throw error
    }
  }

  private func localPreview(_ file: MobileDownloadedFile, line requestedLine: Int?) throws -> CorpusFilePreview {
    let url = MobileHostStorage(hostKey: hostKey).downloadURL(for: file.path)
    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
      throw MobileCorpusError.unavailable
    }
    let lineCount = content.utf8.reduce(into: 1) { count, byte in if byte == 0x0A { count += 1 } }
    return CorpusFilePreview(
      title: URL(fileURLWithPath: file.path).lastPathComponent,
      relativePath: file.path,
      startLine: 1,
      highlightedLine: requestedLine.flatMap { (1...lineCount).contains($0) ? $0 : nil },
      content: content
    )
  }

  func imageData(path: String) async throws -> Data {
    if let local = downloads[normalizedPath(path)],
       let data = try? Data(contentsOf: MobileHostStorage(hostKey: hostKey).downloadURL(for: local.path)) {
      return data
    }
    guard remote.isPaired else { throw MobileCorpusError.notPaired }
    return try await remote.imageData(path: path)
  }

  /// Copies a file (a published PDF or DOCX) into a private temporary folder
  /// for Quick Look, from the downloaded copy or straight from the host.
  func quickLookCopy(path rawPath: String) async throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-quicklook", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = URL(fileURLWithPath: rawPath).lastPathComponent
    let copy = folder.appendingPathComponent(name)
    if let local = downloads[normalizedPath(rawPath)] {
      try FileManager.default.copyItem(at: MobileHostStorage(hostKey: hostKey).downloadURL(for: local.path), to: copy)
      return copy
    }
    guard remote.isPaired else { throw MobileCorpusError.notPaired }
    let download = try await remote.downloadFile(path: rawPath)
    try download.data.write(to: copy, options: .atomic)
    return copy
  }

  func pathForDocumentLink(_ link: MobileDocumentLink) async throws -> String {
    guard let nodeID = link.nodeID else { return link.path }
    if remote.isPaired {
      do {
        return try await remote.resolveEntryID(nodeID).path
      } catch let error as MobileRemoteClientError {
        if case .server = error { throw error }
      }
    }
    // Without the host, a downloaded file can still hold the entry.
    let storage = MobileHostStorage(hostKey: hostKey)
    let marker = ":ID: \(nodeID)"
    let matches = downloadedFiles.filter { file in
      (try? String(contentsOf: storage.downloadURL(for: file.path), encoding: .utf8))?
        .split(separator: "\n")
        .contains { $0.trimmingCharacters(in: .whitespaces) == marker } == true
    }
    guard matches.count == 1 else { throw MobileCorpusError.entryUnavailable }
    return matches[0].path
  }

  func entryForDocumentLink(_ link: MobileDocumentLink, preview: CorpusFilePreview) async throws -> MobileSearchEntry? {
    let sequences = todoSequences
    return try await Task.detached(priority: .userInitiated) {
      try MobileDocumentRuntime().resolveEntry(source: preview.content, path: preview.relativePath, selector: link.selector, sequences: sequences)
    }.value
  }

  func renderedDocument(preview: CorpusFilePreview, entry: MobileSearchEntry?) async throws -> MobileRenderedDocument {
    if !ProcessInfo.processInfo.isLowPowerModeEnabled { documentRenderer.prewarm() }
    return try await documentRenderer.render(
      source: preview.content, path: preview.relativePath, entry: entry,
      sequences: todoSequences, corpusID: hostKey
    )
  }

  private func normalizedPath(_ path: String) -> String {
    var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("file:") { value.removeFirst(5) }
    if value.hasPrefix("./") { value.removeFirst(2) }
    let corpusPrefix = corpusName + "/"
    if !downloads.keys.contains(value), value.hasPrefix(corpusPrefix) {
      value.removeFirst(corpusPrefix.count)
    }
    return value
  }

  // MARK: Downloads

  /// Keeps a copy of a host file on this phone. The copy is refreshed
  /// whenever the file is opened or the file list refreshes.
  func download(path: String) async {
    guard remote.isPaired else {
      errorMessage = MobileCorpusError.notPaired.localizedDescription
      return
    }
    let key = hostKey
    do {
      let file = try await remote.downloadFile(path: path)
      guard key == hostKey else { return }
      try storeDownload(file, hostKey: key)
      statusMessage = "Downloaded \(URL(fileURLWithPath: file.relativePath).lastPathComponent)"
    } catch {
      errorMessage = "Could not download \(URL(fileURLWithPath: path).lastPathComponent): \(error.localizedDescription)"
    }
  }

  func removeDownload(path: String) {
    let storage = MobileHostStorage(hostKey: hostKey)
    storage.removeDownload(path: path)
    downloads.removeValue(forKey: path)
    storage.saveDownloads(downloads)
  }

  func removeAllDownloads() {
    let storage = MobileHostStorage(hostKey: hostKey)
    storage.removeAllDownloads()
    downloads = [:]
  }

  private func storeDownload(_ file: MobileRemoteFileDownload, hostKey key: String) throws {
    let storage = MobileHostStorage(hostKey: key)
    try storage.write(file.data, path: file.relativePath)
    downloads[file.relativePath] = MobileDownloadedFile(
      path: file.relativePath,
      byteCount: Int64(file.data.count),
      modifiedAt: file.modifiedAt,
      downloadedAt: Date(),
      isMissingOnHost: false
    )
    storage.saveDownloads(downloads)
  }

  private func updateDownload(_ file: MobileDownloadedFile, content: String) {
    let storage = MobileHostStorage(hostKey: hostKey)
    let data = Data(content.utf8)
    guard (try? Data(contentsOf: storage.downloadURL(for: file.path))) != data else { return }
    try? storage.write(data, path: file.path)
    downloads[file.path] = MobileDownloadedFile(
      path: file.path,
      byteCount: Int64(data.count),
      modifiedAt: file.modifiedAt,
      downloadedAt: Date(),
      isMissingOnHost: false
    )
    storage.saveDownloads(downloads)
  }

  /// Re-downloads files that changed on the host since they were kept.
  private func refreshDownloads(catalog: MobileRemoteCorpusCatalog, hostKey key: String) async {
    guard !downloads.isEmpty else { return }
    let hostFiles = Dictionary(catalog.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    for file in downloads.values {
      guard key == hostKey else { return }
      guard let hostFile = hostFiles[file.path] else {
        // Binary outputs are not listed; only a missing text file is flagged.
        if WorkspaceTextFile.isListed(file.path), !file.isMissingOnHost {
          downloads[file.path]?.isMissingOnHost = true
        }
        continue
      }
      if hostFile.modifiedAt == file.modifiedAt, !file.isMissingOnHost { continue }
      if let fresh = try? await remote.downloadFile(path: file.path), key == hostKey {
        try? storeDownload(fresh, hostKey: key)
      }
    }
    MobileHostStorage(hostKey: key).saveDownloads(downloads)
  }

  // MARK: Captures

  /// Queues a note for the host and sends it at once when the host is
  /// reachable. A note waits on the phone, never lost, until the host stores it.
  func saveMobileNote(title: String, body: String, attachments: [NoteAttachment] = [], scheduledDate: Date? = nil) async {
    let item = MobileCaptureWriter.noteCapture(
      title: title,
      body: body,
      attachments: attachments,
      scheduledDate: scheduledDate
    )
    await queue(item)
  }

  func sendToAIChat(_ action: AIChatApprovalAction, approval: ApprovalEntry, message: String? = nil) async {
    let text = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt = text?.isEmpty == false ? text! : defaultMessage(for: action, approval: approval)
    let item = MobileCaptureWriter.agentRequestCapture(
      action: action,
      title: approval.title,
      sourceFile: approval.file,
      sourceLine: approval.line,
      body: prompt
    )
    await queue(item)
  }

  private func queue(_ item: MobileCaptureOutbox.Item) async {
    do {
      try MobileCaptureOutbox.enqueue(item)
    } catch {
      errorMessage = "Could not save this note on the phone: \(error.localizedDescription)"
      return
    }
    reloadPendingCaptures()
    await sendPendingCaptures()
    if pendingCaptures.contains(where: { $0.entryID == item.entryID }) {
      statusMessage = remote.isPaired
        ? "Saved on this phone. It will be sent to \(remote.serverName) when it can be reached."
        : "Saved on this phone. It will be sent once you connect a host."
    } else {
      statusMessage = "Sent to \(remote.serverName)"
    }
  }

  func reloadPendingCaptures() {
    pendingCaptures = MobileCaptureOutbox.pending()
  }

  func sendPendingCaptures() async {
    reloadPendingCaptures()
    guard remote.isPaired, !isSendingCaptures, !pendingCaptures.isEmpty else { return }
    isSendingCaptures = true
    defer { isSendingCaptures = false }
    let result = await Self.sendPendingCaptures(remote: remote)
    captureError = result.error
    reloadPendingCaptures()
  }

  /// Sends the queue in order and stops at the first failure, so a later
  /// note never overtakes an earlier one. Also used by background refresh.
  @discardableResult
  static func sendPendingCaptures(remote: MobileRemoteStore) async -> (sent: Int, error: String?) {
    guard remote.isPaired else { return (0, nil) }
    var sent = 0
    for item in MobileCaptureOutbox.pending() {
      do {
        _ = try await remote.uploadCapture(item)
        MobileCaptureOutbox.remove(entryID: item.entryID)
        sent += 1
      } catch {
        return (sent, error.localizedDescription)
      }
    }
    return (sent, nil)
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

  // MARK: Notifications

  func clearNotificationBadge() {
    Task {
      try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }
  }

  /// Schedules the morning "due today" reminder from the host agenda.
  func scheduleDueTodayNotification(from agenda: [AgendaEntry]) {
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
}

extension MobileCaptureWriter {
  /// A request for an agent about an item on the phone, such as an approval
  /// to discuss.
  static func agentRequestCapture(
    action: AIChatApprovalAction,
    title: String,
    sourceFile: String,
    sourceLine: Int?,
    body: String,
    now: Date = Date()
  ) -> MobileCaptureOutbox.Item {
    let entryID = newEntryID(kind: action.rawValue, now: now)
    let createdAt = ISO8601DateFormatter().string(from: now)
    let sourceLineText = sourceLine.map(String.init) ?? ""
    let safeTitle = sanitizeProperty(title)
    let request = escapeHeadingLines(body.trimmingCharacters(in: .whitespacesAndNewlines))
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.isEmpty ? "" : "  \($0)" }
      .joined(separator: "\n")
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
    \(request)

    Source:
    - File: \(sourceFile.isEmpty ? "none" : sourceFile)
    - Line: \(sourceLineText.isEmpty ? "none" : sourceLineText)

    """
    return MobileCaptureOutbox.Item(
      entryID: entryID,
      title: "\(action.title): \(safeTitle)",
      content: content,
      attachments: [],
      createdAt: now
    )
  }
}

/// A host file kept on this phone.
struct MobileDownloadedFile: Codable, Hashable, Identifiable, Sendable {
  let path: String
  let byteCount: Int64
  let modifiedAt: Date?
  let downloadedAt: Date
  /// The host no longer lists the file; the copy stays until removed.
  var isMissingOnHost: Bool

  var id: String { path }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum WorkspaceTextFile {
  static let listedExtensions: Set<String> = [
    "org2", "org", "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml",
  ]

  static func isListed(_ path: String) -> Bool {
    listedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
  }
}

/// Per-host files on the phone: the cached file list (names and dates only)
/// and the files the user downloaded.
struct MobileHostStorage: Sendable {
  let hostKey: String

  private var root: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Celorga/Hosts", isDirectory: true)
      .appendingPathComponent(hostKey, isDirectory: true)
  }

  private var catalogURL: URL { root.appendingPathComponent("catalog.json") }
  private var manifestURL: URL { root.appendingPathComponent("downloads.json") }
  private var downloadsRoot: URL { root.appendingPathComponent("Downloads", isDirectory: true) }

  struct CachedCatalog: Codable {
    let updatedAt: Date
    let catalog: MobileRemoteCorpusCatalog
  }

  func loadCatalog() -> CachedCatalog? {
    guard let data = try? Data(contentsOf: catalogURL) else { return nil }
    return try? Self.decoder.decode(CachedCatalog.self, from: data)
  }

  func saveCatalog(_ catalog: MobileRemoteCorpusCatalog, updatedAt: Date) {
    write(CachedCatalog(updatedAt: updatedAt, catalog: catalog), to: catalogURL)
  }

  func loadDownloads() -> [String: MobileDownloadedFile] {
    guard let data = try? Data(contentsOf: manifestURL),
          let files = try? Self.decoder.decode([MobileDownloadedFile].self, from: data)
    else { return [:] }
    return Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
      .filter { FileManager.default.fileExists(atPath: downloadURL(for: $0.key).path) }
  }

  func saveDownloads(_ downloads: [String: MobileDownloadedFile]) {
    write(Array(downloads.values), to: manifestURL)
  }

  /// Host paths are corpus-relative; anything that could leave the
  /// downloads folder is flattened to its file name.
  func downloadURL(for path: String) -> URL {
    let components = path.split(separator: "/").map(String.init)
    let safe = components.contains("..") || path.hasPrefix("/")
      ? [URL(fileURLWithPath: path).lastPathComponent]
      : components
    return safe.reduce(downloadsRoot) { $0.appendingPathComponent($1) }
  }

  func write(_ data: Data, path: String) throws {
    let url = downloadURL(for: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    excludeFromBackup()
  }

  func removeDownload(path: String) {
    try? FileManager.default.removeItem(at: downloadURL(for: path))
  }

  func removeAllDownloads() {
    try? FileManager.default.removeItem(at: downloadsRoot)
    try? FileManager.default.removeItem(at: manifestURL)
  }

  private func write<Value: Encodable>(_ value: Value, to url: URL) {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard let data = try? Self.encoder.encode(value) else { return }
    try? data.write(to: url, options: .atomic)
    excludeFromBackup()
  }

  /// The host holds the canonical corpus; copies here are disposable.
  private func excludeFromBackup() {
    var url = root
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

enum MobileCorpusError: LocalizedError {
  case notPaired
  case unavailable
  case entryUnavailable

  var errorDescription: String? {
    switch self {
    case .notPaired:
      "Connect a Celorga host in Settings to read its files."
    case .unavailable:
      "That file is not available. Check the connection to your host and try again."
    case .entryUnavailable:
      "This entry is not in a file downloaded to this phone. Connect to your host and try again."
    }
  }
}
