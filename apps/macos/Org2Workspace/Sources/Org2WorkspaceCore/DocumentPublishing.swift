import CryptoKit
import Foundation
import LocalAuthentication
import Network
import Security

public enum DocumentPublishDestination: String, CaseIterable, Identifiable, Sendable {
  case localLink
  case googleDrive

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .localLink: "Local Link"
    case .googleDrive: "Google Drive"
    }
  }

  public var formats: [DocumentPublishFormat] {
    switch self {
    case .localLink:
      [.html, .pdf, .beamerSlides]
    case .googleDrive:
      [.googleDocs, .googleSlides, .googleSheets, .pdf]
    }
  }

  public var defaultFormat: DocumentPublishFormat {
    formats[0]
  }
}

public enum DocumentPublishFormat: String, CaseIterable, Hashable, Identifiable, Sendable {
  case html
  case pdf
  case beamerSlides
  case googleDocs
  case googleSlides
  case googleSheets

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .html: "Web page"
    case .pdf: "PDF"
    case .beamerSlides: "Beamer slides (PDF)"
    case .googleDocs: "Google Docs"
    case .googleSlides: "Google Slides"
    case .googleSheets: "Google Sheets"
    }
  }

  public var systemImage: String {
    switch self {
    case .html: "globe"
    case .pdf: "doc.richtext"
    case .beamerSlides: "rectangle.on.rectangle.angled"
    case .googleDocs: "doc.text"
    case .googleSlides: "rectangle.on.rectangle"
    case .googleSheets: "tablecells"
    }
  }

  public var googleCLIDestination: String? {
    switch self {
    case .googleDocs: "google-docs"
    case .googleSlides: "google-slides"
    case .googleSheets: "google-sheets"
    case .pdf: "google-drive-pdf"
    case .html, .beamerSlides: nil
    }
  }
}

public enum DocumentPublishScope: String, CaseIterable, Identifiable, Sendable {
  case document
  case subtree

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .document: "Entire document"
    case .subtree: "Current subtree"
    }
  }
}

public struct DocumentPublishRequest: Hashable, Sendable {
  public let destination: DocumentPublishDestination
  public let format: DocumentPublishFormat
  public let line: Int?
  public let googleFolderID: String?

  public init(
    destination: DocumentPublishDestination,
    format: DocumentPublishFormat,
    line: Int? = nil,
    googleFolderID: String? = nil
  ) {
    self.destination = destination
    self.format = format
    self.line = line
    let normalizedFolderID = googleFolderID?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.googleFolderID = normalizedFolderID?.isEmpty == false ? normalizedFolderID : nil
  }
}

public struct GoogleDrivePublicationBinding: Identifiable, Hashable, Sendable {
  public let format: DocumentPublishFormat
  public let fileID: String
  public let url: URL
  public let version: String?
  public let publishedAt: Date?
  public let scopeLine: Int?

  public init(
    format: DocumentPublishFormat,
    fileID: String,
    url: URL,
    version: String? = nil,
    publishedAt: Date? = nil,
    scopeLine: Int? = nil
  ) {
    self.format = format
    self.fileID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.url = url
    let normalizedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.version = normalizedVersion?.isEmpty == false ? normalizedVersion : nil
    self.publishedAt = publishedAt
    self.scopeLine = scopeLine
  }

  public var id: String {
    "\(format.rawValue):\(fileID):\(scopeLine ?? 0)"
  }

  public var scopeLabel: String {
    scopeLine.map { "Subtree at line \($0)" } ?? "Entire document"
  }

  fileprivate var propertyStem: String? {
    Self.propertyStem(for: format)
  }

  private static func propertyStem(for format: DocumentPublishFormat) -> String? {
    switch format {
    case .googleDocs: "ORG2_PUBLISH_GOOGLE_DOCS"
    case .googleSlides: "ORG2_PUBLISH_GOOGLE_SLIDES"
    case .googleSheets: "ORG2_PUBLISH_GOOGLE_SHEETS"
    case .pdf: "ORG2_PUBLISH_GOOGLE_DRIVE_PDF"
    case .html, .beamerSlides: nil
    }
  }

  static func binding(
    for format: DocumentPublishFormat,
    in sourceText: String,
    line: Int?
  ) -> GoogleDrivePublicationBinding? {
    bindings(in: sourceText, line: line).first { $0.format == format }
  }

  static func bindings(in sourceText: String, line: Int?) -> [GoogleDrivePublicationBinding] {
    let lines = normalizedLines(sourceText)
    guard let target = target(in: lines, line: line),
          let drawer = target.drawer
    else { return [] }
    let properties = propertyValues(in: lines, drawer: drawer)

    return DocumentPublishDestination.googleDrive.formats.compactMap { format in
      guard let stem = propertyStem(for: format),
            let fileID = normalizedPropertyValue(CelorgaNames.property("\(stem)_FILE_ID", in: properties)),
            let urlText = normalizedPropertyValue(CelorgaNames.property("\(stem)_URL", in: properties)),
            let url = URL(string: urlText),
            url.scheme?.lowercased() == "https",
            ["docs.google.com", "drive.google.com"].contains(url.host?.lowercased() ?? "")
      else { return nil }

      let publishedAt = normalizedPropertyValue(CelorgaNames.property("\(stem)_PUBLISHED_AT", in: properties))
        .flatMap { ISO8601DateFormatter().date(from: $0) }
      return GoogleDrivePublicationBinding(
        format: format,
        fileID: fileID,
        url: url,
        version: normalizedPropertyValue(CelorgaNames.property("\(stem)_VERSION", in: properties)),
        publishedAt: publishedAt,
        scopeLine: target.scopeLine
      )
    }
  }

  static func allBindings(in sourceText: String) -> [GoogleDrivePublicationBinding] {
    let lines = normalizedLines(sourceText)
    var bindings = bindings(in: sourceText, line: nil)
    for (index, line) in lines.enumerated() where isHeading(line) {
      bindings.append(contentsOf: self.bindings(in: sourceText, line: index + 1))
    }
    return bindings
  }

  static func sourceText(
    _ sourceText: String,
    upserting binding: GoogleDrivePublicationBinding
  ) -> String? {
    guard let stem = binding.propertyStem,
          !binding.fileID.isEmpty
    else { return nil }

    let lineEnding = sourceText.contains("\r\n") ? "\r\n" : "\n"
    var lines = normalizedLines(sourceText)
    guard let target = target(in: lines, line: binding.scopeLine) else { return nil }
    let publishedAt = ISO8601DateFormatter().string(from: binding.publishedAt ?? Date())
    var values: [(String, String?)] = [
      ("\(stem)_FILE_ID", binding.fileID),
      ("\(stem)_URL", binding.url.absoluteString),
      ("\(stem)_VERSION", binding.version),
      ("\(stem)_PUBLISHED_AT", publishedAt),
    ]
    values = values.map { key, value in
      (key, value.map(sanitizedPropertyValue))
    }

    if let drawer = target.drawer {
      var drawerEnd = drawer.upperBound
      for (key, value) in values {
        // Update a CELORGA_ spelling in place; new properties keep ORG2_.
        let existingIndex = (drawer.lowerBound + 1..<drawerEnd).first { index in
          propertyKey(in: lines[index]) == CelorgaNames.celorgaName(key)
        } ?? (drawer.lowerBound + 1..<drawerEnd).first { index in
          propertyKey(in: lines[index]) == key
        }
        if let value {
          if let existingIndex {
            let existingKey = propertyKey(in: lines[existingIndex]) ?? key
            lines[existingIndex] = ":\(existingKey): \(value)"
          } else {
            lines.insert(":\(key): \(value)", at: drawerEnd)
            drawerEnd += 1
          }
        } else if let existingIndex {
          lines.remove(at: existingIndex)
          drawerEnd -= 1
        }
      }
    } else {
      let drawerLines = [":PROPERTIES:"]
        + values.compactMap { key, value in value.map { ":\(key): \($0)" } }
        + [":END:"]
      lines.insert(contentsOf: drawerLines, at: target.insertionIndex)
    }
    return lines.joined(separator: lineEnding)
  }

  private struct PropertyTarget {
    let drawer: ClosedRange<Int>?
    let insertionIndex: Int
    let scopeLine: Int?
  }

  private static func target(in lines: [String], line: Int?) -> PropertyTarget? {
    guard !lines.isEmpty else {
      return PropertyTarget(drawer: nil, insertionIndex: 0, scopeLine: nil)
    }
    guard let line else {
      let preambleEnd = lines.firstIndex(where: isHeading) ?? lines.count
      let drawer = propertyDrawer(in: lines, searchRange: 0..<preambleEnd)
      let lastKeyword = (0..<preambleEnd).last { index in
        lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("#+")
      }
      return PropertyTarget(
        drawer: drawer,
        insertionIndex: drawer?.upperBound ?? lastKeyword.map { $0 + 1 } ?? 0,
        scopeLine: nil
      )
    }

    let targetIndex = max(0, min(lines.count - 1, line - 1))
    guard let headingIndex = stride(from: targetIndex, through: 0, by: -1)
      .first(where: { isHeading(lines[$0]) })
    else { return nil }
    var subtreeEnd = lines.count
    let headingLevel = lines[headingIndex].prefix { $0 == "*" }.count
    if headingIndex + 1 < lines.count {
      for index in (headingIndex + 1)..<lines.count where isHeading(lines[index]) {
        if lines[index].prefix(while: { $0 == "*" }).count <= headingLevel {
          subtreeEnd = index
          break
        }
      }
    }
    var insertionIndex = headingIndex + 1
    while insertionIndex < subtreeEnd,
          lines[insertionIndex].trimmingCharacters(in: .whitespaces).range(
            of: #"^(?:SCHEDULED|DEADLINE|CLOSED):"#,
            options: [.regularExpression, .caseInsensitive]
          ) != nil {
      insertionIndex += 1
    }
    let drawer = insertionIndex < subtreeEnd
      ? propertyDrawer(in: lines, searchRange: insertionIndex..<subtreeEnd, directOnly: true)
      : nil
    return PropertyTarget(
      drawer: drawer,
      insertionIndex: insertionIndex,
      scopeLine: headingIndex + 1
    )
  }

  private static func propertyDrawer(
    in lines: [String],
    searchRange: Range<Int>,
    directOnly: Bool = false
  ) -> ClosedRange<Int>? {
    for start in searchRange {
      if directOnly && start != searchRange.lowerBound { return nil }
      guard lines[start].trimmingCharacters(in: .whitespaces).uppercased() == ":PROPERTIES:"
      else { continue }
      guard start + 1 < searchRange.upperBound,
            let end = lines[(start + 1)..<searchRange.upperBound].firstIndex(where: {
              $0.trimmingCharacters(in: .whitespaces).uppercased() == ":END:"
            })
      else { return nil }
      return start...end
    }
    return nil
  }

  private static func propertyValues(
    in lines: [String],
    drawer: ClosedRange<Int>
  ) -> [String: String] {
    guard drawer.lowerBound + 1 < drawer.upperBound else { return [:] }
    var properties: [String: String] = [:]
    for index in (drawer.lowerBound + 1)..<drawer.upperBound {
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
      guard let key = propertyKey(in: trimmed),
            let separator = trimmed.dropFirst().firstIndex(of: ":")
      else { continue }
      let valueStart = trimmed.index(after: separator)
      properties[key] = String(trimmed[valueStart...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return properties
  }

  private static func propertyKey(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix(":"),
          let separator = trimmed.dropFirst().firstIndex(of: ":")
    else { return nil }
    let keyStart = trimmed.index(after: trimmed.startIndex)
    let key = String(trimmed[keyStart..<separator]).uppercased()
    return key.isEmpty ? nil : key
  }

  private static func normalizedLines(_ sourceText: String) -> [String] {
    sourceText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  private static func normalizedPropertyValue(_ value: String?) -> String? {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized?.isEmpty == false ? normalized : nil
  }

  private static func sanitizedPropertyValue(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isHeading(_ line: String) -> Bool {
    line.range(of: #"^\*+\s+"#, options: .regularExpression) != nil
  }
}

public struct DocumentPublishCLIResult: Decodable, Sendable {
  public struct Source: Decodable, Sendable {
    public let file: String
    public let selection: String
    public let sourceHash: String
    public let line: Int?
  }

  public struct Asset: Decodable, Hashable, Sendable {
    public let name: String
    public let mediaType: String
    public let bytes: Int
    public let sha256: String
  }

  public struct Artifact: Decodable, Sendable {
    public let title: String
    public let mediaType: String
    public let selection: String
    public let artifactHash: String
    public let bytes: Int
    public let projectionHash: String
    public let assets: [Asset]
  }

  public struct Disclosure: Decodable, Sendable {
    public let redactions: [String: Int]
    public let warnings: [String]
  }

  public let applied: Bool
  public let source: Source
  public let artifact: Artifact
  public let disclosure: Disclosure
  public let destination: JSONValue

  public var redactionCount: Int {
    disclosure.redactions.values.reduce(0, +)
  }

  public func destinationString(_ key: String) -> String? {
    destination[key]?.stringValue
  }
}

public struct LocalDocumentPublication: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let url: URL
  public let localURL: URL
  public let mediaType: String
  public let sourcePath: String?
  public let format: DocumentPublishFormat?
  public let createdAt: Date
  /// The AI chat thread this link mirrors, when it is a live thread share.
  public let chatThreadID: UUID?

  /// The advertised network URL used by both Open and Copy Link actions.
  public var openURL: URL { url }

  public init(
    id: String,
    title: String,
    url: URL,
    localURL: URL,
    mediaType: String = "text/html",
    sourcePath: String? = nil,
    format: DocumentPublishFormat? = nil,
    createdAt: Date = Date(),
    chatThreadID: UUID? = nil
  ) {
    self.id = id
    self.title = title
    self.url = url
    self.localURL = localURL
    self.mediaType = mediaType
    self.sourcePath = sourcePath
    self.format = format
    self.createdAt = createdAt
    self.chatThreadID = chatThreadID
  }

  static let chatThreadStableKeyPrefix = "openorg-chat-thread:"

  /// One stable key per thread keeps the same URL across republishes and launches.
  static func chatThreadStableKey(_ threadID: UUID) -> String {
    chatThreadStableKeyPrefix + threadID.uuidString.lowercased()
  }

  static func chatThreadID(fromStableKey stableKey: String?) -> UUID? {
    guard let stableKey, stableKey.hasPrefix(chatThreadStableKeyPrefix) else { return nil }
    return UUID(uuidString: String(stableKey.dropFirst(chatThreadStableKeyPrefix.count)))
  }
}

public enum DocumentPublishOutcome: Sendable {
  case localLink(publication: LocalDocumentPublication, result: DocumentPublishCLIResult)
  case googleDrive(
    format: DocumentPublishFormat,
    url: URL,
    fileID: String,
    version: String?,
    result: DocumentPublishCLIResult
  )
}

public enum DocumentPublishingError: LocalizedError, Sendable {
  case noDocument
  case busy
  case pendingEdits
  case missingGoogleCredential
  case invalidGoogleResponse
  case googlePublicationPersistenceFailed(URL, String)
  case missingWebBundle(String)
  case unsupportedFormat

  public var errorDescription: String? {
    switch self {
    case .noDocument:
      "Open an Org document before publishing."
    case .busy:
      "A document publication is already in progress."
    case .pendingEdits:
      "Save the current edit before publishing the document."
    case .missingGoogleCredential:
      "Connect Google Drive before publishing."
    case .invalidGoogleResponse:
      "Google Drive completed without returning a usable document link."
    case .googlePublicationPersistenceFailed(let url, let reason):
      "Google Drive published the artifact, but Celorga could not save its stable link in the source file: \(reason). Recover it at \(url.absoluteString)."
    case .missingWebBundle(let path):
      "Celorga completed without producing the expected web publication at \(path)."
    case .unsupportedFormat:
      "That format is not available for the selected publication destination."
    }
  }
}

public struct GoogleDriveOAuthCredential: Codable, Equatable, Sendable {
  public let clientID: String
  public let clientSecret: String?
  public let accessToken: String
  public let refreshToken: String
  public let expirationDate: Date
  public let scope: String
  public let tokenType: String

  public init(
    clientID: String,
    clientSecret: String? = nil,
    accessToken: String,
    refreshToken: String,
    expirationDate: Date,
    scope: String,
    tokenType: String = "Bearer"
  ) {
    self.clientID = clientID
    self.clientSecret = GoogleDriveOAuthConfiguration.normalizedClientSecret(clientSecret)
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expirationDate = expirationDate
    self.scope = scope
    self.tokenType = tokenType
  }

  public var grantsDriveFileScope: Bool {
    scope.split(whereSeparator: { $0.isWhitespace })
      .contains(Substring(GoogleDriveOAuthClient.driveFileScope))
  }
}

public enum GoogleDriveOAuthConfiguration {
  public static let clientIDDefaultsKey = "org.openorg.google-drive-oauth-client-id"
  public static let clientIDInfoKey = "OpenOrgGoogleOAuthClientID"
  public static let clientIDEnvironmentKey = "ORG2_GOOGLE_OAUTH_CLIENT_ID"
  public static let clientSecretInfoKey = "OpenOrgGoogleOAuthClientSecret"
  public static let clientSecretEnvironmentKey = "ORG2_GOOGLE_OAUTH_CLIENT_SECRET"

  public static func managedClientID() -> String? {
    resolvedClientID(
      managedCandidates: [
        Bundle.main.object(forInfoDictionaryKey: clientIDInfoKey) as? String,
        CelorgaNames.environment(clientIDEnvironmentKey),
      ],
      savedClientID: nil
    )
  }

  public static func managedClientSecret() -> String? {
    [
      Bundle.main.object(forInfoDictionaryKey: clientSecretInfoKey) as? String,
      CelorgaNames.environment(clientSecretEnvironmentKey),
    ].compactMap(normalizedClientSecret).first
  }

  public static func configuredClientID() -> String? {
    resolvedClientID(
      managedCandidates: [
        Bundle.main.object(forInfoDictionaryKey: clientIDInfoKey) as? String,
        CelorgaNames.environment(clientIDEnvironmentKey),
      ],
      savedClientID: UserDefaults.standard.string(forKey: clientIDDefaultsKey)
    )
  }

  public static func configuredClientSecret() -> String? {
    managedClientSecret()
  }

  static func resolvedClientID(
    managedCandidates: [String?],
    savedClientID: String?
  ) -> String? {
    let candidates = managedCandidates + [savedClientID]
    return candidates.compactMap(normalizedClientID).first
  }

  public static func savedClientID() -> String? {
    normalizedClientID(UserDefaults.standard.string(forKey: clientIDDefaultsKey))
  }

  public static var hasManagedClient: Bool {
    managedClientID() != nil && managedClientSecret() != nil
  }

  public static func managedClientPair() -> GoogleDriveOAuthDesktopClient? {
    guard let clientID = managedClientID() else { return nil }
    return try? GoogleDriveOAuthDesktopClient(
      clientID: clientID,
      clientSecret: managedClientSecret()
    )
  }

  public static func clientSecret(for credential: GoogleDriveOAuthCredential) -> String? {
    resolvedClientSecret(
      credentialClientID: credential.clientID,
      credentialClientSecret: credential.clientSecret,
      managedClientID: managedClientID(),
      managedClientSecret: managedClientSecret()
    )
  }

  static func resolvedClientSecret(
    credentialClientID: String,
    credentialClientSecret: String?,
    managedClientID: String?,
    managedClientSecret: String?
  ) -> String? {
    if let credentialClientSecret = normalizedClientSecret(credentialClientSecret) {
      return credentialClientSecret
    }
    guard normalizedClientID(credentialClientID) == normalizedClientID(managedClientID) else {
      return nil
    }
    return normalizedClientSecret(managedClientSecret)
  }

  public static func saveClientID(_ clientID: String) {
    if let normalized = normalizedClientID(clientID) {
      UserDefaults.standard.set(normalized, forKey: clientIDDefaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: clientIDDefaultsKey)
    }
  }

  public static func normalizedClientID(_ value: String?) -> String? {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalized.isEmpty ? nil : normalized
  }

  public static func normalizedClientSecret(_ value: String?) -> String? {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalized.isEmpty ? nil : normalized
  }
}

public struct GoogleDriveOAuthDesktopClient: Equatable, Sendable {
  public let clientID: String
  public let clientSecret: String?

  public init(clientID: String, clientSecret: String? = nil) throws {
    guard let normalizedClientID = GoogleDriveOAuthConfiguration.normalizedClientID(clientID) else {
      throw GoogleDriveOAuthDesktopClientError.missingClientID
    }
    self.clientID = normalizedClientID
    self.clientSecret = GoogleDriveOAuthConfiguration.normalizedClientSecret(clientSecret)
  }

  public static func decodeGoogleClientJSON(_ data: Data) throws -> GoogleDriveOAuthDesktopClient {
    struct ClientRecord: Decodable {
      let clientID: String
      let clientSecret: String?

      enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
      }
    }

    struct ClientEnvelope: Decodable {
      let installed: ClientRecord?
      let web: ClientRecord?
    }

    let envelope: ClientEnvelope
    do {
      envelope = try JSONDecoder().decode(ClientEnvelope.self, from: data)
    } catch {
      throw GoogleDriveOAuthDesktopClientError.invalidJSON
    }
    guard let installed = envelope.installed else {
      if envelope.web != nil {
        throw GoogleDriveOAuthDesktopClientError.webClientNotSupported
      }
      throw GoogleDriveOAuthDesktopClientError.missingDesktopClient
    }
    return try GoogleDriveOAuthDesktopClient(
      clientID: installed.clientID,
      clientSecret: installed.clientSecret
    )
  }
}

public enum GoogleDriveOAuthDesktopClientError: LocalizedError, Equatable, Sendable {
  case invalidJSON
  case missingDesktopClient
  case webClientNotSupported
  case missingClientID

  public var errorDescription: String? {
    switch self {
    case .invalidJSON:
      "That file is not a valid Google OAuth client JSON file."
    case .missingDesktopClient:
      "That JSON file does not contain a Google OAuth Desktop app client."
    case .webClientNotSupported:
      "That JSON file contains a Web application client. Create and download a Desktop app OAuth client instead."
    case .missingClientID:
      "The Google OAuth Desktop app client is missing its client ID."
    }
  }
}

public enum GoogleDriveOAuthCredentialKeychain {
  public static let service = "Org2Workspace.GoogleDrive"
  public static let account = "drive.file.oauth-credential"

  public static func containsCredential() -> Bool {
    SecItemCopyMatching(baseQuery() as CFDictionary, nil) == errSecSuccess
  }

  public static func readCredential(allowUserInteraction: Bool = false) -> GoogleDriveOAuthCredential? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = !allowUserInteraction
    query[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(GoogleDriveOAuthCredential.self, from: data)
  }

  public static func saveCredential(_ credential: GoogleDriveOAuthCredential) throws {
    guard !credential.accessToken.isEmpty,
          !credential.refreshToken.isEmpty,
          !credential.clientID.isEmpty
    else {
      throw GoogleDriveOAuthCredentialKeychainError.invalidCredential
    }
    let data: Data
    do {
      data = try JSONEncoder().encode(credential)
    } catch {
      throw GoogleDriveOAuthCredentialKeychainError.invalidCredential
    }
    var addition = baseQuery()
    addition[kSecValueData as String] = data
    addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(addition as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update = SecItemUpdate(
        baseQuery() as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      guard update == errSecSuccess else {
        throw GoogleDriveOAuthCredentialKeychainError.status(update)
      }
      return
    }
    guard status == errSecSuccess else {
      throw GoogleDriveOAuthCredentialKeychainError.status(status)
    }
  }

  public static func deleteCredential() throws {
    let status = SecItemDelete(baseQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw GoogleDriveOAuthCredentialKeychainError.status(status)
    }
  }

  private static func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

public enum GoogleDriveOAuthCredentialKeychainError: LocalizedError, Equatable {
  case invalidCredential
  case status(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .invalidCredential:
      "Google Drive returned an incomplete credential. Connect the account again."
    case .status(let status):
      "Could not update the Google Drive credential in Keychain (status \(status))."
    }
  }
}

public enum GoogleDriveOAuthError: LocalizedError, Sendable {
  case invalidClientID
  case missingClientSecret
  case browserOpenFailed
  case callbackServer(String)
  case callbackTimedOut
  case invalidCallback
  case stateMismatch
  case authorizationDenied(String)
  case tokenRequestFailed(Int, String?)
  case invalidTokenResponse
  case missingRefreshToken
  case scopeNotGranted
  case requestedScopeNotGranted

  public var errorDescription: String? {
    switch self {
    case .invalidClientID:
      "Enter the client ID from a Google OAuth Desktop app."
    case .missingClientSecret:
      "Google requires the client secret paired with this Desktop app client. Import the downloaded OAuth client JSON, or paste its client secret, and connect again."
    case .browserOpenFailed:
      "Celorga could not open the Google authorization page."
    case .callbackServer(let detail):
      "Celorga could not start the temporary Google authorization callback: \(detail)"
    case .callbackTimedOut:
      "Google authorization timed out. Try connecting again."
    case .invalidCallback:
      "Google returned an invalid authorization response."
    case .stateMismatch:
      "Google authorization could not be verified. Try connecting again."
    case .authorizationDenied(let detail):
      detail.isEmpty ? "Google authorization was cancelled." : "Google authorization failed: \(detail)"
    case .tokenRequestFailed(let status, let detail):
      if let detail, !detail.isEmpty {
        "Google token exchange failed (HTTP \(status)): \(detail)"
      } else {
        "Google token exchange failed (HTTP \(status))."
      }
    case .invalidTokenResponse:
      "Google returned an invalid OAuth credential."
    case .missingRefreshToken:
      "Google did not return a refresh credential. Connect the account again."
    case .scopeNotGranted:
      "Google Drive access was not granted. Connect again and approve Drive file access."
    case .requestedScopeNotGranted:
      "Google did not grant the requested access. Sign in again and approve every requested permission."
    }
  }
}

private struct GoogleDriveOAuthTokenResponse: Decodable, Sendable {
  let accessToken: String
  let expiresIn: Int
  let refreshToken: String?
  let scope: String?
  let tokenType: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case scope
    case tokenType = "token_type"
  }
}

private struct GoogleDriveOAuthErrorResponse: Decodable {
  let error: String?
  let errorDescription: String?

  enum CodingKeys: String, CodingKey {
    case error
    case errorDescription = "error_description"
  }
}

private struct GoogleDriveOAuthCallback: Sendable {
  let code: String
  let state: String
}

public struct GoogleDriveOAuthClient: Sendable {
  public static let driveFileScope = "https://www.googleapis.com/auth/drive.file"
  public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
  public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

  public typealias HTTPRequest = @Sendable (URLRequest) async throws -> (Data, URLResponse)
  public typealias OpenAuthorizationURL = @Sendable (URL) async -> Bool

  private let httpRequest: HTTPRequest

  public init(
    httpRequest: @escaping HTTPRequest = { request in
      try await URLSession.shared.data(for: request)
    }
  ) {
    self.httpRequest = httpRequest
  }

  public func authorize(
    clientID: String,
    clientSecret: String? = nil,
    scope requestedScope: String = GoogleDriveOAuthClient.driveFileScope,
    openAuthorizationURL: @escaping OpenAuthorizationURL
  ) async throws -> GoogleDriveOAuthCredential {
    guard let normalizedClientID = GoogleDriveOAuthConfiguration.normalizedClientID(clientID) else {
      throw GoogleDriveOAuthError.invalidClientID
    }

    let receiver = GoogleDriveOAuthLoopbackReceiver()
    let redirectURL = try await receiver.start()
    defer { receiver.stop() }

    let codeVerifier = try Self.randomURLSafeString(byteCount: 64)
    let codeChallenge = Self.codeChallenge(for: codeVerifier)
    let state = try Self.randomURLSafeString(byteCount: 32)
    let authorizationURL = try Self.authorizationURL(
      clientID: normalizedClientID,
      redirectURL: redirectURL,
      codeChallenge: codeChallenge,
      state: state,
      scope: requestedScope
    )
    guard await openAuthorizationURL(authorizationURL) else {
      throw GoogleDriveOAuthError.browserOpenFailed
    }

    let callback = try await receiver.waitForCallback()
    guard callback.state == state else {
      throw GoogleDriveOAuthError.stateMismatch
    }
    let normalizedClientSecret = GoogleDriveOAuthConfiguration.normalizedClientSecret(clientSecret)
    var tokenFields = [
      "client_id": normalizedClientID,
      "code": callback.code,
      "code_verifier": codeVerifier,
      "grant_type": "authorization_code",
      "redirect_uri": redirectURL.absoluteString,
    ]
    if let normalizedClientSecret {
      tokenFields["client_secret"] = normalizedClientSecret
    }
    let response = try await tokenResponse(fields: tokenFields)
    guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
      throw GoogleDriveOAuthError.missingRefreshToken
    }
    let scope = response.scope ?? requestedScope
    guard Self.grants(requestedScope, in: scope) else {
      throw requestedScope == Self.driveFileScope
        ? GoogleDriveOAuthError.scopeNotGranted
        : GoogleDriveOAuthError.requestedScopeNotGranted
    }
    return GoogleDriveOAuthCredential(
      clientID: normalizedClientID,
      clientSecret: normalizedClientSecret,
      accessToken: response.accessToken,
      refreshToken: refreshToken,
      expirationDate: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
      scope: scope,
      tokenType: response.tokenType ?? "Bearer"
    )
  }

  public func refreshingIfNeeded(
    _ credential: GoogleDriveOAuthCredential,
    now: Date = Date()
  ) async throws -> GoogleDriveOAuthCredential {
    guard credential.expirationDate.timeIntervalSince(now) <= 120 else {
      return credential
    }
    let clientSecret = GoogleDriveOAuthConfiguration.clientSecret(for: credential)
    var tokenFields = [
      "client_id": credential.clientID,
      "grant_type": "refresh_token",
      "refresh_token": credential.refreshToken,
    ]
    if let clientSecret {
      tokenFields["client_secret"] = clientSecret
    }
    let response = try await tokenResponse(fields: tokenFields)
    let scope = response.scope ?? credential.scope
    guard Self.grantsDriveFileScope(scope) else {
      throw GoogleDriveOAuthError.scopeNotGranted
    }
    return GoogleDriveOAuthCredential(
      clientID: credential.clientID,
      clientSecret: clientSecret,
      accessToken: response.accessToken,
      refreshToken: response.refreshToken ?? credential.refreshToken,
      expirationDate: now.addingTimeInterval(TimeInterval(response.expiresIn)),
      scope: scope,
      tokenType: response.tokenType ?? credential.tokenType
    )
  }

  static func authorizationURL(
    clientID: String,
    redirectURL: URL,
    codeChallenge: String,
    state: String,
    scope: String = driveFileScope
  ) throws -> URL {
    var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: scope),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "prompt", value: "consent"),
    ]
    guard let url = components?.url else {
      throw GoogleDriveOAuthError.invalidClientID
    }
    return url
  }

  static func codeChallenge(for codeVerifier: String) -> String {
    Data(SHA256.hash(data: Data(codeVerifier.utf8)))
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func randomURLSafeString(byteCount: Int) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw LocalDocumentPublicationHostError.randomNumberFailure(status)
    }
    return Data(bytes)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func grantsDriveFileScope(_ scope: String) -> Bool {
    grants(driveFileScope, in: scope)
  }

  static func grants(_ requested: String, in granted: String) -> Bool {
    let grantedScopes = Set(granted.split(whereSeparator: { $0.isWhitespace }))
    return requested.split(whereSeparator: { $0.isWhitespace }).allSatisfy(grantedScopes.contains)
  }

  private func tokenResponse(fields: [String: String]) async throws -> GoogleDriveOAuthTokenResponse {
    var request = URLRequest(url: Self.tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var components = URLComponents()
    components.queryItems = fields.sorted { $0.key < $1.key }
      .map { URLQueryItem(name: $0.key, value: $0.value) }
    request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await httpRequest(request)
    } catch {
      throw GoogleDriveOAuthError.tokenRequestFailed(0, error.localizedDescription)
    }
    guard let httpResponse = response as? HTTPURLResponse else {
      throw GoogleDriveOAuthError.invalidTokenResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let errorResponse = try? JSONDecoder().decode(GoogleDriveOAuthErrorResponse.self, from: data)
      let detail = errorResponse?.errorDescription ?? errorResponse?.error
      if httpResponse.statusCode == 400,
         detail?.localizedCaseInsensitiveContains("client_secret") == true,
         detail?.localizedCaseInsensitiveContains("missing") == true {
        throw GoogleDriveOAuthError.missingClientSecret
      }
      throw GoogleDriveOAuthError.tokenRequestFailed(httpResponse.statusCode, detail)
    }
    guard let decoded = try? JSONDecoder().decode(GoogleDriveOAuthTokenResponse.self, from: data),
          !decoded.accessToken.isEmpty,
          decoded.expiresIn > 0
    else {
      throw GoogleDriveOAuthError.invalidTokenResponse
    }
    return decoded
  }
}

private final class GoogleDriveOAuthLoopbackReceiver: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.openorg.google-oauth-loopback", qos: .userInitiated)
  private let stateLock = NSLock()
  private let connectionLock = NSLock()
  private var listener: NWListener?
  private var connections: [UUID: MobileRemoteHTTPConnection] = [:]
  private var result: Result<GoogleDriveOAuthCallback, Error>?
  private var continuation: CheckedContinuation<GoogleDriveOAuthCallback, Error>?

  func start() async throws -> URL {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let candidate: NWListener
    do {
      candidate = try NWListener(using: parameters)
    } catch {
      throw GoogleDriveOAuthError.callbackServer(error.localizedDescription)
    }
    let startup = LocalPublicationListenerStartup()
    candidate.stateUpdateHandler = { state in
      switch state {
      case .ready:
        guard let port = candidate.port?.rawValue else {
          startup.complete(.failure(.startupFailed("No callback port was assigned.")))
          return
        }
        startup.complete(.success(port))
      case .failed(let error):
        startup.complete(.failure(.startupFailed(error.localizedDescription)))
      case .cancelled:
        startup.complete(.failure(.startupFailed("The callback listener was cancelled.")))
      default:
        break
      }
    }
    candidate.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    candidate.start(queue: queue)

    do {
      let port = try await Task.detached(priority: .userInitiated) {
        try startup.wait()
      }.value
      storeListener(candidate)
      queue.asyncAfter(deadline: .now() + 300) { [weak self] in
        self?.complete(.failure(GoogleDriveOAuthError.callbackTimedOut))
      }
      guard let url = URL(string: "http://127.0.0.1:\(port)") else {
        throw GoogleDriveOAuthError.callbackServer("The callback URL was invalid.")
      }
      return url
    } catch {
      candidate.cancel()
      if let oauthError = error as? GoogleDriveOAuthError {
        throw oauthError
      }
      throw GoogleDriveOAuthError.callbackServer(error.localizedDescription)
    }
  }

  func waitForCallback() async throws -> GoogleDriveOAuthCallback {
    try await withCheckedThrowingContinuation { continuation in
      stateLock.lock()
      if let result {
        stateLock.unlock()
        continuation.resume(with: result)
      } else {
        self.continuation = continuation
        stateLock.unlock()
      }
    }
  }

  func stop() {
    stateLock.lock()
    let activeListener = listener
    listener = nil
    stateLock.unlock()
    activeListener?.cancel()

    connectionLock.lock()
    let activeConnections = Array(connections.values)
    connections = [:]
    connectionLock.unlock()
    activeConnections.forEach { $0.cancel() }
  }

  deinit {
    stop()
  }

  private func accept(_ connection: NWConnection) {
    let id = UUID()
    let remoteConnection = MobileRemoteHTTPConnection(
      connection: connection,
      handler: { [weak self] request in
        self?.response(to: request)
          ?? .error("Authorization is unavailable.", statusCode: 503)
      },
      completion: { [weak self] in self?.removeConnection(id) }
    )
    connectionLock.lock()
    connections[id] = remoteConnection
    connectionLock.unlock()
    remoteConnection.start(on: queue)
  }

  private func storeListener(_ listener: NWListener) {
    stateLock.lock()
    self.listener = listener
    stateLock.unlock()
  }

  private func removeConnection(_ id: UUID) {
    connectionLock.lock()
    connections[id] = nil
    connectionLock.unlock()
  }

  private func response(to request: MobileRemoteHTTPRequest) -> MobileRemoteHTTPResponse {
    guard request.method == "GET",
          let components = URLComponents(string: request.path),
          components.path.isEmpty || components.path == "/"
    else {
      return .error("Not found.", statusCode: 404)
    }
    let values = (components.queryItems ?? []).reduce(into: [String: String]()) { values, item in
      if values[item.name] == nil, let value = item.value {
        values[item.name] = value
      }
    }
    if let error = values["error"] {
      let detail = values["error_description"] ?? error
      complete(.failure(GoogleDriveOAuthError.authorizationDenied(detail)))
      return htmlResponse(
        title: "Google Drive was not connected",
        message: "Return to Celorga to try again."
      )
    }
    guard let code = values["code"], !code.isEmpty,
          let state = values["state"], !state.isEmpty
    else {
      complete(.failure(GoogleDriveOAuthError.invalidCallback))
      return htmlResponse(
        title: "Google Drive could not be connected",
        message: "Return to Celorga to try again."
      )
    }
    complete(.success(GoogleDriveOAuthCallback(code: code, state: state)))
    return htmlResponse(
      title: "Google Drive connected",
      message: "You can close this window and return to Celorga."
    )
  }

  private func complete(_ newResult: Result<GoogleDriveOAuthCallback, Error>) {
    stateLock.lock()
    guard result == nil else {
      stateLock.unlock()
      return
    }
    result = newResult
    let continuation = continuation
    self.continuation = nil
    stateLock.unlock()
    continuation?.resume(with: newResult)
  }

  private func htmlResponse(title: String, message: String) -> MobileRemoteHTTPResponse {
    let html = """
      <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
      <title>\(title)</title><style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;max-width:38rem;margin:12vh auto;padding:0 2rem;color:#202124}h1{font-size:1.6rem}</style></head>
      <body><h1>\(title)</h1><p>\(message)</p></body></html>
      """
    return MobileRemoteHTTPResponse(
      statusCode: 200,
      headers: [
        "Content-Type": "text/html; charset=utf-8",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
      ],
      body: Data(html.utf8)
    )
  }
}

public enum LocalDocumentPublicationHostError: LocalizedError, Sendable {
  case invalidAdvertisedHost
  case persistenceFailed(String)
  case randomNumberFailure(OSStatus)
  case startupFailed(String)
  case startupTimedOut

  public var errorDescription: String? {
    switch self {
    case .invalidAdvertisedHost:
      "Celorga could not determine a local hostname for this Mac."
    case .persistenceFailed(let message):
      "Celorga could not persist the local publication: \(message)"
    case .randomNumberFailure(let status):
      "Celorga could not create a secure publication link (status \(status))."
    case .startupFailed(let message):
      "The local publication server could not start: \(message)"
    case .startupTimedOut:
      "The local publication server did not become ready in time."
    }
  }
}

private final class LocalPublicationListenerStartup: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var result: Result<UInt16, LocalDocumentPublicationHostError>?

  func complete(_ result: Result<UInt16, LocalDocumentPublicationHostError>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    lock.unlock()
    semaphore.signal()
  }

  func wait() throws -> UInt16 {
    guard semaphore.wait(timeout: .now() + 5) == .success else {
      throw LocalDocumentPublicationHostError.startupTimedOut
    }
    lock.lock()
    let result = self.result
    lock.unlock()
    guard let result else {
      throw LocalDocumentPublicationHostError.startupFailed("No listener state was returned.")
    }
    return try result.get()
  }
}

public final class LocalDocumentPublicationHost: @unchecked Sendable {
  private struct HostedDocument: Sendable {
    let id: String
    let stableKey: String?
    let title: String
    let mediaType: String
    let sourcePath: String?
    let format: DocumentPublishFormat?
    let createdAt: Date
    /// Present only for live publications. Readers poll it to detect updates.
    let revision: String?
    let data: Data?
    let artifactURL: URL?

    func contentData() throws -> Data {
      if let data { return data }
      guard let artifactURL else { return Data() }
      return try Data(contentsOf: artifactURL)
    }
  }

  private struct PersistedDocument: Codable, Sendable {
    let id: String
    let stableKey: String?
    let title: String
    let mediaType: String
    let sourcePath: String?
    let format: String?
    let createdAt: Date
    let revision: String?
  }

  private struct PersistedState: Codable, Sendable {
    let schema: String
    let port: UInt16
    let advertisedHost: String
    let documents: [PersistedDocument]
  }

  private static let persistedStateSchema = "openorg:local-document-publications:v1"
  private let queue = DispatchQueue(label: "org.openorg.document-publishing", qos: .userInitiated)
  private let stateLock = NSLock()
  private let startupLock = NSLock()
  private let connectionLock = NSLock()
  private let bindHost: String
  /// The persisted fallback host, normally this Mac's network name.
  private let advertisedHost: String
  /// A host that takes precedence while it is available, such as this Mac's
  /// current Tailscale address. Links keep their token and port, so a link
  /// copied under either host keeps working while both remain reachable.
  private let preferredAdvertisedHost: (@Sendable () -> String?)?
  private let storageDirectory: URL?
  private var listener: NWListener?
  private var listenerShutdown: DispatchGroup?
  private var listeningPort: UInt16?
  private var persistedPort: UInt16?
  private var restorationError: LocalDocumentPublicationHostError?
  private var documents: [String: HostedDocument] = [:]
  private var connections: [UUID: MobileRemoteHTTPConnection] = [:]
  /// Guest messages for live thread links. Revoking a link clears its queue.
  let guestMessages = AIChatGuestMessageQueue()

  public init(
    bindHost: String = "0.0.0.0",
    advertisedHost: String = ProcessInfo.processInfo.hostName,
    preferredAdvertisedHost: (@Sendable () -> String?)? = nil,
    storageDirectory: URL? = nil
  ) {
    self.bindHost = bindHost
    self.preferredAdvertisedHost = preferredAdvertisedHost
    self.storageDirectory = storageDirectory?.standardizedFileURL
    let currentAdvertisedHost = advertisedHost.trimmingCharacters(in: .whitespacesAndNewlines)
    var restoredAdvertisedHost = currentAdvertisedHost
    if let storageDirectory = self.storageDirectory {
      do {
        if let restored = try Self.loadPersistedState(from: storageDirectory) {
          restoredAdvertisedHost = restored.advertisedHost
          persistedPort = restored.port
          documents = restored.documents
        }
      } catch let error as LocalDocumentPublicationHostError {
        restorationError = error
      } catch {
        restorationError = .persistenceFailed(error.localizedDescription)
      }
    }
    self.advertisedHost = restoredAdvertisedHost
  }

  public func publish(html: Data, title: String) async throws -> LocalDocumentPublication {
    try await publish(data: html, title: title, mediaType: "text/html")
  }

  public func publish(
    data: Data,
    title: String,
    mediaType: String,
    sourcePath: String? = nil,
    format: DocumentPublishFormat? = nil,
    stableKey: String? = nil,
    revision: String? = nil
  ) async throws -> LocalDocumentPublication {
    guard Self.httpURL(host: currentAdvertisedHost, port: 1, path: "/") != nil else {
      throw LocalDocumentPublicationHostError.invalidAdvertisedHost
    }
    let port = try await Task.detached(priority: .userInitiated) { [self] in
      try startIfNeededBlocking()
    }.value
    let trimmedStableKey = stableKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedStableKey = trimmedStableKey?.isEmpty == false ? trimmedStableKey : nil
    let normalizedMediaType = Self.normalizedMediaType(mediaType)
    // Chat apps unfurl pasted links from Open Graph tags; add them to any
    // published page that lacks its own.
    let data = normalizedMediaType == "text/html"
      ? SharePreviewMetadata.annotated(html: data, title: title)
      : data
    let existingDocument = normalizedStableKey.flatMap { stableKey in
      stateLock.withLock {
        let exactMatch = documents.values
          .filter { $0.stableKey == stableKey }
          .max { $0.createdAt < $1.createdAt }
        if let exactMatch { return exactMatch }

        // Publications created before stable keys were introduced still carry
        // their source and format. Adopt the newest compatible legacy match
        // so installing this update does not force one final URL change.
        return documents.values
          .filter {
            $0.stableKey == nil
              && $0.sourcePath == sourcePath
              && $0.format == format
              && $0.mediaType == normalizedMediaType
          }
          .max { $0.createdAt < $1.createdAt }
      }
    }
    let token = try existingDocument?.id ?? uniqueSecretToken()
    let candidateDocument = HostedDocument(
      id: token,
      stableKey: normalizedStableKey,
      title: title,
      mediaType: normalizedMediaType,
      sourcePath: sourcePath,
      format: format,
      createdAt: existingDocument?.createdAt ?? Date(),
      revision: revision.flatMap(Self.normalizedRevision),
      data: data,
      artifactURL: nil
    )
    _ = try publication(for: candidateDocument, port: port)
    let document = try storeDocument(candidateDocument)
    return try publication(for: document, port: port)
  }

  public func restorePublications() async throws -> [LocalDocumentPublication] {
    let (restorationError, hasDocuments) = stateLock.withLock {
      (self.restorationError, !documents.isEmpty)
    }
    if let restorationError { throw restorationError }
    guard hasDocuments else { return [] }

    let port = try await Task.detached(priority: .userInitiated) { [self] in
      try startIfNeededBlocking()
    }.value
    let restoredDocuments = stateLock.withLock {
      documents.values.sorted { $0.createdAt > $1.createdAt }
    }
    return try restoredDocuments.map { try publication(for: $0, port: port) }
  }

  public func revoke(_ publicationID: String) throws {
    stateLock.lock()
    guard let removedDocument = documents.removeValue(forKey: publicationID) else {
      stateLock.unlock()
      return
    }
    do {
      try persistStateLocked()
      stateLock.unlock()
    } catch {
      documents[publicationID] = removedDocument
      stateLock.unlock()
      throw LocalDocumentPublicationHostError.persistenceFailed(error.localizedDescription)
    }
    guestMessages.disable(shareID: publicationID)
    if let artifactURL = removedDocument.artifactURL {
      try? FileManager.default.removeItem(at: artifactURL)
    }
  }

  public func revokeAll() throws {
    stateLock.lock()
    let removedDocuments = documents
    documents = [:]
    do {
      try persistStateLocked()
      stateLock.unlock()
    } catch {
      documents = removedDocuments
      stateLock.unlock()
      throw LocalDocumentPublicationHostError.persistenceFailed(error.localizedDescription)
    }
    guestMessages.disableAll()
    for document in removedDocuments.values {
      if let artifactURL = document.artifactURL {
        try? FileManager.default.removeItem(at: artifactURL)
      }
    }
  }

  private func storeDocument(_ document: HostedDocument) throws -> HostedDocument {
    var storedDocument = document
    if let storageDirectory {
      do {
        try Self.prepareStorageDirectory(storageDirectory)
        let artifactURL = Self.artifactURL(
          storageDirectory: storageDirectory,
          publicationID: document.id,
          mediaType: document.mediaType
        )
        try document.contentData().write(to: artifactURL, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: artifactURL.path
        )
        storedDocument = HostedDocument(
          id: document.id,
          stableKey: document.stableKey,
          title: document.title,
          mediaType: document.mediaType,
          sourcePath: document.sourcePath,
          format: document.format,
          createdAt: document.createdAt,
          revision: document.revision,
          data: nil,
          artifactURL: artifactURL
        )
      } catch {
        throw LocalDocumentPublicationHostError.persistenceFailed(error.localizedDescription)
      }
    }

    stateLock.lock()
    documents[storedDocument.id] = storedDocument
    do {
      try persistStateLocked()
      stateLock.unlock()
      return storedDocument
    } catch {
      documents[storedDocument.id] = nil
      stateLock.unlock()
      if let artifactURL = storedDocument.artifactURL {
        try? FileManager.default.removeItem(at: artifactURL)
      }
      throw LocalDocumentPublicationHostError.persistenceFailed(error.localizedDescription)
    }
  }

  public func stop() {
    _ = stopListener()
  }

  /// Network.framework cancellation is asynchronous. Callers replacing a host
  /// in the same process must await port release before restoring its URL.
  func stopAndWait() async {
    guard let shutdown = stopListener() else { return }
    await withCheckedContinuation { continuation in
      shutdown.notify(queue: .global(qos: .userInitiated)) {
        continuation.resume()
      }
    }
  }

  private func stopListener() -> DispatchGroup? {
    stateLock.lock()
    let activeListener = listener
    let shutdown = listenerShutdown
    listener = nil
    listenerShutdown = nil
    listeningPort = nil
    documents = [:]
    stateLock.unlock()
    guestMessages.disableAll()
    activeListener?.cancel()

    connectionLock.lock()
    let activeConnections = Array(connections.values)
    connections = [:]
    connectionLock.unlock()
    activeConnections.forEach { $0.cancel() }
    return shutdown
  }

  deinit {
    stop()
  }

  private func startIfNeededBlocking() throws -> UInt16 {
    startupLock.lock()
    defer { startupLock.unlock() }

    stateLock.lock()
    let existingPort = listeningPort
    let requestedPort = persistedPort
    let restorationError = restorationError
    stateLock.unlock()
    if let restorationError { throw restorationError }
    if let existingPort { return existingPort }

    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host(bindHost),
      port: requestedPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
    )
    let candidate: NWListener
    do {
      candidate = try NWListener(using: parameters)
    } catch {
      throw LocalDocumentPublicationHostError.startupFailed(error.localizedDescription)
    }

    let startup = LocalPublicationListenerStartup()
    let shutdown = DispatchGroup()
    shutdown.enter()
    candidate.stateUpdateHandler = { state in
      switch state {
      case .ready:
        guard let port = candidate.port?.rawValue else {
          startup.complete(.failure(.startupFailed("No listening port was assigned.")))
          return
        }
        startup.complete(.success(port))
      case .failed(let error):
        startup.complete(.failure(.startupFailed(error.localizedDescription)))
      case .cancelled:
        shutdown.leave()
        startup.complete(.failure(.startupFailed("The listener was cancelled.")))
      default:
        break
      }
    }
    candidate.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    candidate.start(queue: queue)

    do {
      let port = try startup.wait()
      stateLock.lock()
      listener = candidate
      listenerShutdown = shutdown
      listeningPort = port
      let shouldPersistPort = persistedPort == nil
      persistedPort = port
      do {
        if shouldPersistPort {
          try persistStateLocked()
        }
        stateLock.unlock()
        return port
      } catch {
        listener = nil
        listenerShutdown = nil
        listeningPort = nil
        persistedPort = requestedPort
        stateLock.unlock()
        candidate.cancel()
        throw LocalDocumentPublicationHostError.persistenceFailed(error.localizedDescription)
      }
    } catch {
      candidate.cancel()
      throw error
    }
  }

  private func accept(_ connection: NWConnection) {
    let id = UUID()
    let remoteConnection = MobileRemoteHTTPConnection(
      connection: connection,
      handler: { [weak self] request in
        self?.response(to: request)
          ?? .error("The publication server is unavailable.", statusCode: 503)
      },
      completion: { [weak self] in self?.removeConnection(id) }
    )
    connectionLock.lock()
    connections[id] = remoteConnection
    connectionLock.unlock()
    remoteConnection.start(on: queue)
  }

  private func removeConnection(_ id: UUID) {
    connectionLock.lock()
    connections[id] = nil
    connectionLock.unlock()
  }

  func response(to request: MobileRemoteHTTPRequest) -> MobileRemoteHTTPResponse {
    let requestPath = URLComponents(string: request.path)?.path ?? request.path
    let components = requestPath.split(separator: "/", omittingEmptySubsequences: true)
    if components.first == "a", components.count >= 3, components[2] == "guest" {
      let token = String(components[1])
      guard stateLock.withLock({ documents[token] }) != nil else {
        return .error("This publication is unavailable or has been revoked.", statusCode: 404)
      }
      return AIChatGuestMessageHTTP.response(
        to: request,
        shareID: token,
        route: components.dropFirst(3).map(String.init),
        queue: guestMessages
      )
    }
    guard request.method == "GET" || request.method == "HEAD" else {
      return .error("Not found.", statusCode: 404)
    }
    guard components.first == "a",
          components.count == 2 || (components.count == 3 && components[2] == "revision")
    else {
      return .error("Not found.", statusCode: 404)
    }
    let token = String(components[1])
    stateLock.lock()
    let document = documents[token]
    stateLock.unlock()
    guard let document else {
      return .error("This publication is unavailable or has been revoked.", statusCode: 404)
    }
    if components.count == 3 {
      // Live pages poll this tiny endpoint instead of downloading themselves.
      guard let revision = document.revision else {
        return .error("Not found.", statusCode: 404)
      }
      return MobileRemoteHTTPResponse(
        statusCode: 200,
        headers: [
          "Content-Type": "text/plain; charset=utf-8",
          "Referrer-Policy": "no-referrer",
          "X-Content-Type-Options": "nosniff",
          "X-Robots-Tag": "noindex, nofollow, noarchive",
        ],
        body: request.method == "HEAD" ? Data() : Data(revision.utf8)
      )
    }
    let body: Data
    if request.method == "HEAD" {
      body = Data()
    } else {
      guard let persistedData = try? document.contentData() else {
        return .error("This publication artifact is unavailable.", statusCode: 503)
      }
      body = persistedData
    }
    let isHTML = document.mediaType == "text/html"
    return MobileRemoteHTTPResponse(
      statusCode: 200,
      headers: [
        "Content-Type": isHTML ? "text/html; charset=utf-8" : document.mediaType,
        "Content-Security-Policy": Self.contentSecurityPolicy(
          isHTML: isHTML,
          isLive: document.revision != nil
        ),
        "Content-Disposition": "inline",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
        "X-Robots-Tag": "noindex, nofollow, noarchive",
      ],
      body: body
    )
  }

  static func contentSecurityPolicy(isHTML: Bool, isLive: Bool) -> String {
    guard isHTML else {
      return "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'"
    }
    // A live page may run only its pinned scripts: the poller and the guest
    // composer, which talk to this same origin. Every other publication
    // stays script-free.
    let live = isLive
      ? " script-src '\(liveUpdateScriptHash)' '\(AIChatGuestMessageHTTP.scriptHash)'; connect-src 'self';"
      : ""
    return "default-src 'none'; img-src data:; style-src 'unsafe-inline';\(live) base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'"
  }

  /// Polls `<page>/revision` and swaps in the refreshed `#openorg-live-root`
  /// without a full reload, keeping the reader's scroll position and selection.
  static let liveUpdateScript = #"""
  (() => {
    const page = location.pathname.replace(/\/+$/, '');
    const status = () => document.getElementById('openorg-live-status');
    const revisionOf = doc => doc.querySelector('meta[name="openorg-revision"]')?.content || '';
    let revision = revisionOf(document), failures = 0;
    const setStatus = (text, state) => {
      const node = status(); if (!node) return;
      node.textContent = text; node.dataset.state = state;
    };
    const selecting = () => { const s = getSelection(); return s && !s.isCollapsed; };
    const nearBottom = () => innerHeight + scrollY >= document.documentElement.scrollHeight - 120;
    const swap = async () => {
      const response = await fetch(page, { cache: 'no-store' });
      if (!response.ok) throw new Error(String(response.status));
      const next = new DOMParser().parseFromString(await response.text(), 'text/html');
      const root = next.getElementById('openorg-live-root');
      if (!root) throw new Error('missing root');
      const stick = nearBottom();
      for (const style of next.querySelectorAll('head style[id]')) {
        const current = document.getElementById(style.id);
        if (current) current.textContent = style.textContent;
        else document.head.append(document.importNode(style, true));
      }
      document.getElementById('openorg-live-root').replaceWith(document.importNode(root, true));
      document.title = next.title;
      revision = revisionOf(next);
      if (stick) scrollTo(0, document.documentElement.scrollHeight);
    };
    const tick = async () => {
      try {
        const response = await fetch(page + '/revision', { cache: 'no-store' });
        if (response.status === 404) { setStatus('Sharing stopped', 'stopped'); return; }
        if (!response.ok) throw new Error(String(response.status));
        const next = (await response.text()).trim();
        if (next && next !== revision && !selecting()) await swap();
        failures = 0;
        setStatus('Live', 'live');
      } catch (error) {
        failures += 1;
        setStatus('Reconnecting…', 'offline');
      }
      setTimeout(tick, failures ? Math.min(30000, 3000 * 2 ** failures) : 3000);
    };
    setTimeout(tick, 3000);
  })();
  """#

  static let liveUpdateScriptHash: String = {
    let digest = SHA256.hash(data: Data(liveUpdateScript.utf8))
    return "sha256-" + Data(digest).base64EncodedString()
  }()

  /// The exact element live pages embed; its body must match the CSP hash.
  static var liveUpdateScriptElement: String {
    "<script>\(liveUpdateScript)</script>"
  }

  private static func normalizedRevision(_ revision: String) -> String? {
    let trimmed = revision.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...128).contains(trimmed.count),
          trimmed.utf8.allSatisfy({ (33...126).contains($0) })
    else { return nil }
    return trimmed
  }

  private static func normalizedMediaType(_ mediaType: String) -> String {
    switch mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "application/pdf": "application/pdf"
    default: "text/html"
    }
  }

  private func publication(
    for document: HostedDocument,
    port: UInt16
  ) throws -> LocalDocumentPublication {
    let host = currentAdvertisedHost
    guard !host.isEmpty else {
      throw LocalDocumentPublicationHostError.invalidAdvertisedHost
    }
    let path = "/a/\(document.id)"
    guard let url = Self.httpURL(host: host, port: port, path: path),
          let localURL = Self.httpURL(host: "127.0.0.1", port: port, path: path)
    else {
      throw LocalDocumentPublicationHostError.invalidAdvertisedHost
    }
    return LocalDocumentPublication(
      id: document.id,
      title: document.title,
      url: url,
      localURL: localURL,
      mediaType: document.mediaType,
      sourcePath: document.sourcePath,
      format: document.format,
      createdAt: document.createdAt,
      chatThreadID: LocalDocumentPublication.chatThreadID(fromStableKey: document.stableKey)
    )
  }

  /// The host new and refreshed links advertise right now.
  var currentAdvertisedHost: String {
    if let preferred = preferredAdvertisedHost?()?.trimmingCharacters(in: .whitespacesAndNewlines),
       !preferred.isEmpty,
       Self.httpURL(host: preferred, port: 1, path: "/") != nil {
      return preferred
    }
    return advertisedHost
  }

  /// Advertises this Mac's Tailscale address while Tailscale is connected.
  public static let tailscaleAdvertisedHost: @Sendable () -> String? = {
    MobileRemoteCoordinator.tailscaleIPv4Addresses().first
  }

  private func uniqueSecretToken() throws -> String {
    for _ in 0..<8 {
      let token = try Self.secretToken()
      stateLock.lock()
      let isAvailable = documents[token] == nil
      stateLock.unlock()
      if isAvailable { return token }
    }
    throw LocalDocumentPublicationHostError.persistenceFailed(
      "Celorga could not allocate a unique publication identifier."
    )
  }

  private func persistStateLocked() throws {
    guard let storageDirectory,
          let port = listeningPort ?? persistedPort
    else {
      return
    }
    try Self.prepareStorageDirectory(storageDirectory)
    let persistedDocuments = documents.values
      .sorted { $0.createdAt > $1.createdAt }
      .map { document in
        PersistedDocument(
          id: document.id,
          stableKey: document.stableKey,
          title: document.title,
          mediaType: document.mediaType,
          sourcePath: document.sourcePath,
          format: document.format?.rawValue,
          createdAt: document.createdAt,
          revision: document.revision
        )
      }
    let state = PersistedState(
      schema: Self.persistedStateSchema,
      port: port,
      advertisedHost: advertisedHost,
      documents: persistedDocuments
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(state)
    data.append(contentsOf: "\n".utf8)
    let manifestURL = Self.manifestURL(storageDirectory: storageDirectory)
    try data.write(to: manifestURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: manifestURL.path
    )
  }

  private static func loadPersistedState(
    from storageDirectory: URL
  ) throws -> (
    advertisedHost: String,
    port: UInt16,
    documents: [String: HostedDocument]
  )? {
    let manifestURL = manifestURL(storageDirectory: storageDirectory)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = try decoder.decode(PersistedState.self, from: Data(contentsOf: manifestURL))
    let advertisedHost = state.advertisedHost.trimmingCharacters(in: .whitespacesAndNewlines)
    guard state.schema == persistedStateSchema,
          state.port > 0,
          httpURL(host: advertisedHost, port: state.port, path: "/") != nil
    else {
      throw LocalDocumentPublicationHostError.persistenceFailed(
        "The stored publication manifest is invalid."
      )
    }

    var restoredDocuments: [String: HostedDocument] = [:]
    for record in state.documents {
      guard isValidPublicationID(record.id),
            record.mediaType == "text/html" || record.mediaType == "application/pdf"
      else {
        continue
      }
      let format = record.format.flatMap(DocumentPublishFormat.init(rawValue:))
      if record.format != nil, format == nil { continue }
      let artifactURL = artifactURL(
        storageDirectory: storageDirectory,
        publicationID: record.id,
        mediaType: record.mediaType
      )
      guard FileManager.default.fileExists(atPath: artifactURL.path) else { continue }
      restoredDocuments[record.id] = HostedDocument(
        id: record.id,
        stableKey: record.stableKey,
        title: record.title,
        mediaType: record.mediaType,
        sourcePath: record.sourcePath,
        format: format,
        createdAt: record.createdAt,
        revision: record.revision.flatMap(normalizedRevision),
        data: nil,
        artifactURL: artifactURL
      )
    }
    return (advertisedHost, state.port, restoredDocuments)
  }

  private static func prepareStorageDirectory(_ storageDirectory: URL) throws {
    let artifactDirectory = artifactDirectory(storageDirectory: storageDirectory)
    try FileManager.default.createDirectory(
      at: artifactDirectory,
      withIntermediateDirectories: true
    )
    for directory in [storageDirectory, artifactDirectory] {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
      )
    }
  }

  private static func manifestURL(storageDirectory: URL) -> URL {
    storageDirectory.appendingPathComponent("publications.json", isDirectory: false)
  }

  private static func artifactDirectory(storageDirectory: URL) -> URL {
    storageDirectory.appendingPathComponent("artifacts", isDirectory: true)
  }

  private static func artifactURL(
    storageDirectory: URL,
    publicationID: String,
    mediaType: String
  ) -> URL {
    artifactDirectory(storageDirectory: storageDirectory)
      .appendingPathComponent(
        "\(publicationID).\(mediaType == "application/pdf" ? "pdf" : "html")",
        isDirectory: false
      )
  }

  private static func isValidPublicationID(_ publicationID: String) -> Bool {
    (40...128).contains(publicationID.count)
      && publicationID.utf8.allSatisfy { byte in
        (65...90).contains(byte)
          || (97...122).contains(byte)
          || (48...57).contains(byte)
          || byte == 45
          || byte == 95
      }
  }

  private static func httpURL(host: String, port: UInt16, path: String) -> URL? {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = Int(port)
    components.path = path
    return components.url
  }

  private static func secretToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw LocalDocumentPublicationHostError.randomNumberFailure(status)
    }
    return Data(bytes)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
