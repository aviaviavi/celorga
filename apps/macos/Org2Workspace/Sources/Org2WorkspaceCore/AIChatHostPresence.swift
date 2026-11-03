import Foundation

/// The OpenOrg process that accepts and executes chat turns: a desktop app or
/// a headless server. `ref` is stable per installation; `name` is shown to
/// people ("AiroPress", "OpenOrg on press").
public struct AIChatHostIdentity: Sendable, Equatable, Hashable {
  public enum Kind: String, Codable, Sendable {
    case desktop
    case server
  }

  public let ref: String
  public let name: String
  public let kind: Kind

  public init(ref: String, name: String, kind: Kind) {
    self.ref = ref
    self.name = name
    self.kind = kind
  }

  static func desktop(writer: AIChatTranscriptWriterIdentity) -> AIChatHostIdentity {
    AIChatHostIdentity(
      ref: "desktop-\(writer.id.prefix(12))",
      name: writer.label,
      kind: .desktop
    )
  }
}

/// Host references owned by this process, readable from nonisolated
/// transcript-loading code that must not treat another host's in-flight turn
/// as an interrupted local send.
final class AIChatLocalHostRegistry: @unchecked Sendable {
  static let shared = AIChatLocalHostRegistry()
  private let lock = NSLock()
  private var refs: Set<String> = []

  func register(_ ref: String) {
    lock.lock()
    refs.insert(ref)
    lock.unlock()
  }

  func isLocal(_ ref: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return refs.contains(ref)
  }
}

/// The message that started a live turn. The presence record is small and
/// rewritten every few seconds, so it usually reaches other hosts before the
/// transcript commit that carries the same message.
public struct AIChatLiveTurnPrompt: Codable, Sendable, Equatable {
  public var content: String
  public var createdAt: Date
  public var attachmentCount: Int?
  public var provenance: AIChatMessageProvenance?

  public init(
    content: String,
    createdAt: Date,
    attachmentCount: Int? = nil,
    provenance: AIChatMessageProvenance? = nil
  ) {
    self.content = content
    self.createdAt = createdAt
    self.attachmentCount = attachmentCount
    self.provenance = provenance
  }
}

/// A live turn published by the host that is executing it. Other hosts use it
/// to show progress for conversations they do not run themselves.
public struct AIChatLiveTurnRecord: Codable, Sendable, Equatable {
  public var threadID: UUID
  public var userMessageID: UUID?
  public var destinationID: String?
  public var destinationName: String?
  public var startedAt: Date?
  public var streamingReply: String
  public var reasoning: String
  public var activities: [AIChatRunActivity]
  public var statusText: String?
  /// The message `userMessageID` names. Absent in records from older builds.
  public var userMessage: AIChatLiveTurnPrompt?

  public init(
    threadID: UUID,
    userMessageID: UUID? = nil,
    destinationID: String? = nil,
    destinationName: String? = nil,
    startedAt: Date? = nil,
    streamingReply: String = "",
    reasoning: String = "",
    activities: [AIChatRunActivity] = [],
    statusText: String? = nil,
    userMessage: AIChatLiveTurnPrompt? = nil
  ) {
    self.threadID = threadID
    self.userMessageID = userMessageID
    self.destinationID = destinationID
    self.destinationName = destinationName
    self.startedAt = startedAt
    self.streamingReply = streamingReply
    self.reasoning = reasoning
    self.activities = activities
    self.statusText = statusText
    self.userMessage = userMessage
  }

  /// The conversation as a host that does not run this turn should show it.
  /// While the transcript commit carrying the turn's prompt is still
  /// synchronizing, the prompt from this record stands in for it, so the
  /// reader never sees work start with no message that asked for it. The
  /// committed message replaces it as soon as it arrives (same ID).
  public func messagesIncludingPrompt(_ messages: [AIChatMessage]) -> [AIChatMessage] {
    guard let userMessageID,
          let userMessage,
          !messages.contains(where: { $0.id == userMessageID })
    else { return messages }
    let attachments = userMessage.attachmentCount ?? 0
    let content = userMessage.content.isEmpty && attachments > 0
      ? (attachments == 1 ? "1 attachment" : "\(attachments) attachments")
      : userMessage.content
    let prompt = AIChatMessage(
      id: userMessageID,
      role: .user,
      content: content,
      createdAt: userMessage.createdAt,
      deliveryStatus: .sending,
      targetDestinationID: destinationID,
      provenance: userMessage.provenance
    )
    // Keep creation order: the prompt belongs after every message that
    // preceded it, even if a later one has already synchronized.
    let index = messages.lastIndex(where: { $0.createdAt <= prompt.createdAt })
      .map { $0 + 1 } ?? 0
    var result = messages
    result.insert(prompt, at: index)
    return result
  }
}

/// One host's presence record, stored at
/// `.org2/openclaw-chat.store/live/<writer-id>.json`. Only that host writes
/// the file; it is small, rewritten atomically, and safe to lose.
public struct AIChatLiveHostRecord: Codable, Sendable, Equatable {
  public static let schemaValue = "org2:ai-chat-live-host:v1"

  public var schema: String
  public var writerID: String
  public var hostRef: String
  public var hostName: String
  public var hostKind: AIChatHostIdentity.Kind
  public var updatedAt: Date
  public var isOnline: Bool
  public var enabledDestinationIDs: [String]
  public var turns: [AIChatLiveTurnRecord]
  /// Enabled destinations whose latest delivery on this host failed for an
  /// authentication reason (sign-in expired, token rejected). Absent in
  /// records from older builds.
  public var authenticationNeededDestinationIDs: [String]?
  /// The host is finishing its running turns before a restart or update and
  /// accepts no new turns. Absent in records from older builds.
  public var isDraining: Bool?

  public init(
    writerID: String,
    host: AIChatHostIdentity,
    updatedAt: Date = Date(),
    isOnline: Bool = true,
    enabledDestinationIDs: [String] = [],
    turns: [AIChatLiveTurnRecord] = [],
    authenticationNeededDestinationIDs: [String]? = nil,
    isDraining: Bool? = nil
  ) {
    schema = Self.schemaValue
    self.writerID = writerID
    hostRef = host.ref
    hostName = host.name
    hostKind = host.kind
    self.updatedAt = updatedAt
    self.isOnline = isOnline
    self.enabledDestinationIDs = enabledDestinationIDs
    self.turns = turns
    self.authenticationNeededDestinationIDs = authenticationNeededDestinationIDs
    self.isDraining = isDraining
  }

  /// Fresh and accepting new turns.
  public func isRoutable(now: Date = Date(), within interval: TimeInterval) -> Bool {
    isFresh(now: now, within: interval) && isDraining != true
  }

  public var host: AIChatHostIdentity {
    AIChatHostIdentity(ref: hostRef, name: hostName, kind: hostKind)
  }

  /// Presence is advisory: a host that stopped refreshing its record (sleep,
  /// crash, lost synchronization) is treated as unavailable.
  public func isFresh(now: Date = Date(), within interval: TimeInterval) -> Bool {
    isOnline && now.timeIntervalSince(updatedAt) <= interval && updatedAt <= now.addingTimeInterval(300)
  }

  /// Compares everything except the heartbeat timestamp.
  func hasSameContent(as other: AIChatLiveHostRecord) -> Bool {
    var lhs = self
    var rhs = other
    lhs.updatedAt = .distantPast
    rhs.updatedAt = .distantPast
    return lhs == rhs
  }
}

/// A remote live turn joined with the host that runs it.
public struct AIChatRemoteLiveTurn: Sendable, Equatable {
  public let host: AIChatHostIdentity
  public let turn: AIChatLiveTurnRecord
  public let updatedAt: Date
}

enum AIChatLiveHostDirectory {
  static let directoryName = "live"
  static let maximumStreamingCharacters = 24 * 1_024
  static let maximumReasoningCharacters = 4 * 1_024
  static let maximumPromptCharacters = 8 * 1_024
  static let maximumActivities = 12

  static func boundedHead(_ text: String, maximum: Int) -> String {
    guard text.count > maximum else { return text }
    return String(text.prefix(maximum)) + "…"
  }

  static func directory(forTranscript legacyURL: URL) -> URL {
    AIChatTranscriptStore.storeDirectory(for: legacyURL)
      .appendingPathComponent(directoryName, isDirectory: true)
  }

  static func write(_ record: AIChatLiveHostRecord, transcriptURL: URL) throws {
    let directory = directory(forTranscript: transcriptURL)
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      return
    }
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let url = directory.appendingPathComponent("\(record.writerID).json")
    try encoder.encode(record).write(to: url, options: [.atomic])
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static func readAll(transcriptURL: URL, excludingWriterID: String?) -> [AIChatLiveHostRecord] {
    let directory = directory(forTranscript: transcriptURL)
    guard let urls = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return urls.compactMap { url -> AIChatLiveHostRecord? in
      guard url.pathExtension == "json",
            !url.lastPathComponent.contains(".sync-conflict-"),
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            data.count < 4 * 1_024 * 1_024,
            let record = try? decoder.decode(AIChatLiveHostRecord.self, from: data),
            CelorgaNames.schemaMatches(record.schema, AIChatLiveHostRecord.schemaValue),
            record.writerID != excludingWriterID
      else { return nil }
      return record
    }
  }

  static func boundedTail(_ text: String, maximum: Int) -> String {
    guard text.count > maximum else { return text }
    return "…" + String(text.suffix(maximum))
  }
}

/// Asks the local Syncthing instance to rescan a changed chat path
/// immediately instead of waiting for its filesystem-watcher delay (10 s by
/// default). This is a best-effort latency hint: it reads the API key from the
/// user's own Syncthing configuration at request time, never stores it, never
/// sends it anywhere but the loopback GUI address, and silently does nothing
/// when Syncthing is absent, the folder is not shared, or the hint is disabled
/// with the `OpenOrgSyncthingScanHints` default.
final class SyncthingScanHint: @unchecked Sendable {
  static let shared = SyncthingScanHint()

  private struct Target {
    let baseURL: URL
    let apiKey: String
    let folderID: String
    let folderPath: String
  }

  private let queue = DispatchQueue(label: "org.org2.workspace.syncthing-scan-hint", qos: .utility)
  private var pendingSubpaths: [String: Set<String>] = [:]
  private var scheduledRoots: Set<String> = []
  private var cachedTargets: [String: (target: Target?, loadedAt: Date)] = [:]
  var isEnabled: Bool {
    UserDefaults.standard.object(forKey: "OpenOrgSyncthingScanHints") as? Bool ?? true
  }

  /// Requests a scan of `path` (absolute) within the Syncthing folder that
  /// contains `corpusRoot`. Calls are coalesced for 250 ms.
  func scan(path: URL, corpusRoot: URL?) {
    guard isEnabled, let corpusRoot else { return }
    let root = corpusRoot.standardizedFileURL.path
    let absolute = path.standardizedFileURL.path
    queue.async { [self] in
      pendingSubpaths[root, default: []].insert(absolute)
      guard scheduledRoots.insert(root).inserted else { return }
      queue.asyncAfter(deadline: .now() + 0.25) { [self] in
        scheduledRoots.remove(root)
        let paths = pendingSubpaths.removeValue(forKey: root) ?? []
        guard let target = target(for: root) else { return }
        for path in paths where path.hasPrefix(target.folderPath + "/") {
          let subpath = String(path.dropFirst(target.folderPath.count + 1))
          request(target: target, subpath: subpath)
        }
      }
    }
  }

  private func target(for root: String) -> Target? {
    if let cached = cachedTargets[root], Date().timeIntervalSince(cached.loadedAt) < 300 {
      return cached.target
    }
    let target = Self.loadTarget(corpusRoot: root)
    cachedTargets[root] = (target, Date())
    return target
  }

  private func request(target: Target, subpath: String) {
    var components = URLComponents(
      url: target.baseURL.appendingPathComponent("rest/db/scan"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "folder", value: target.folderID),
      URLQueryItem(name: "sub", value: subpath),
    ]
    guard let url = components?.url else { return }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue(target.apiKey, forHTTPHeaderField: "X-API-Key")
    URLSession.shared.dataTask(with: request).resume()
  }

  private static func loadTarget(corpusRoot: String) -> Target? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
      home.appendingPathComponent("Library/Application Support/Syncthing/config.xml"),
      home.appendingPathComponent(".local/state/syncthing/config.xml"),
      home.appendingPathComponent(".config/syncthing/config.xml"),
    ]
    for url in candidates {
      guard let data = try? Data(contentsOf: url),
            let parsed = SyncthingConfigParser.parse(data)
      else { continue }
      let resolvedRoot = URL(fileURLWithPath: corpusRoot).resolvingSymlinksInPath().path
      guard let folder = parsed.folders.first(where: { folder in
        let path = URL(fileURLWithPath: (folder.path as NSString).expandingTildeInPath)
          .resolvingSymlinksInPath().path
        return resolvedRoot == path || resolvedRoot.hasPrefix(path + "/")
      }),
            !parsed.guiUsesTLS,
            let address = parsed.guiAddress,
            let apiKey = parsed.apiKey, !apiKey.isEmpty
      else { continue }
      let host = address.contains("://") ? address : "http://\(address)"
      guard let baseURL = URL(string: host.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")),
            let hostName = baseURL.host,
            ["127.0.0.1", "localhost", "::1", "[::1]"].contains(hostName)
      else { continue }
      let folderPath = URL(fileURLWithPath: (folder.path as NSString).expandingTildeInPath)
        .standardizedFileURL.path
      return Target(
        baseURL: baseURL,
        apiKey: apiKey,
        folderID: folder.id,
        folderPath: folderPath
      )
    }
    return nil
  }
}

private final class SyncthingConfigParser: NSObject, XMLParserDelegate {
  struct Folder {
    let id: String
    let path: String
  }

  private(set) var folders: [Folder] = []
  private(set) var guiAddress: String?
  private(set) var apiKey: String?
  private(set) var guiUsesTLS = false
  private var elementStack: [String] = []
  private var text = ""

  static func parse(_ data: Data) -> SyncthingConfigParser? {
    let delegate = SyncthingConfigParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    return parser.parse() ? delegate : nil
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?,
    attributes: [String: String] = [:]
  ) {
    // Only top-level folders; device and default-folder templates nest others.
    if elementName == "folder", elementStack == ["configuration"],
       let id = attributes["id"], !id.isEmpty,
       let path = attributes["path"], !path.isEmpty {
      folders.append(Folder(id: id, path: path))
    }
    if elementName == "gui", elementStack == ["configuration"] {
      guiUsesTLS = attributes["tls"]?.lowercased() == "true"
    }
    elementStack.append(elementName)
    text = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName: String?
  ) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if elementStack == ["configuration", "gui", "address"] { guiAddress = trimmed }
    if elementStack == ["configuration", "gui", "apikey"] { apiKey = trimmed }
    elementStack.removeLast()
    text = ""
  }
}
