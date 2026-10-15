import Foundation
import LocalAuthentication
import Security

public enum SourceCredentialsKeychain {
  public static let service = "org.org2.workspace.external-sources"

  public static func containsToken(profileID: String) -> Bool {
    var query = baseQuery(profileID: profileID)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
  }

  public static func readToken(profileID: String) -> String? {
    var query = baseQuery(profileID: profileID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data,
          let value = String(data: data, encoding: .utf8),
          !value.isEmpty
    else { return nil }
    return value
  }

  public static func saveToken(_ value: String, profileID: String) throws {
    let query = baseQuery(profileID: profileID)
    let data = Data(value.utf8)
    var addQuery = query
    addQuery[kSecValueData as String] = data
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecDuplicateItem {
      var updateQuery = query
      updateQuery[kSecUseAuthenticationContext as String] = noninteractiveAuthenticationContext()
      let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard updateStatus == errSecSuccess else { throw SourceCredentialsKeychainError.status(updateStatus) }
      return
    }
    guard status == errSecSuccess else { throw SourceCredentialsKeychainError.status(status) }
  }

  public static func deleteToken(profileID: String) throws {
    let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SourceCredentialsKeychainError.status(status)
    }
  }

  private static func baseQuery(profileID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: profileID
    ]
  }

  private static func noninteractiveAuthenticationContext() -> LAContext {
    let context = LAContext()
    context.interactionNotAllowed = true
    return context
  }
}

public enum SourceCredentialsKeychainError: LocalizedError, Equatable {
  case status(OSStatus)
  case invalidProfile

  public var errorDescription: String? {
    switch self {
    case .status(let status): "Source credential keychain operation failed with status \(status)."
    case .invalidProfile: "That source credential has an invalid source name or an empty value."
    }
  }
}

// MARK: - Credential stores

/// Where a host keeps external-source secrets (tokens, passwords, OAuth
/// refresh credentials), keyed by the `externalSources` profile ID. The
/// desktop uses its login Keychain. A headless server cannot answer Keychain
/// prompts, so it keeps credentials that a paired Mac sends it in a private
/// file in its own state directory. Neither ever writes to the corpus.
public protocol SourceCredentialStoring: AnyObject, Sendable {
  func containsCredential(profileID: String) -> Bool
  func credential(profileID: String) -> String?
  func saveCredential(_ value: String, profileID: String) throws
  func deleteCredential(profileID: String) throws
  func storedProfileIDs() -> [String]
}

public final class SourceCredentialsKeychainStore: SourceCredentialStoring, @unchecked Sendable {
  public init() {}

  public func containsCredential(profileID: String) -> Bool {
    SourceCredentialsKeychain.containsToken(profileID: profileID)
  }

  public func credential(profileID: String) -> String? {
    SourceCredentialsKeychain.readToken(profileID: profileID)
  }

  public func saveCredential(_ value: String, profileID: String) throws {
    try SourceCredentialsKeychain.saveToken(value, profileID: profileID)
  }

  public func deleteCredential(profileID: String) throws {
    try SourceCredentialsKeychain.deleteToken(profileID: profileID)
  }

  public func storedProfileIDs() -> [String] { [] }
}

/// A 0600 JSON file of source credentials in a private (0700) directory.
public final class SourceCredentialsFileStore: SourceCredentialStoring, @unchecked Sendable {
  public static let schema = "org2:source-credentials:v1"

  private struct Envelope: Codable {
    var schema: String
    var credentials: [String: Entry]
  }

  private struct Entry: Codable {
    var value: String
    var updatedAt: Date
  }

  public let fileURL: URL
  private let lock = NSLock()

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func containsCredential(profileID: String) -> Bool {
    credential(profileID: profileID) != nil
  }

  public func credential(profileID: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    let value = read().credentials[profileID]?.value
    return value?.isEmpty == false ? value : nil
  }

  public func saveCredential(_ value: String, profileID: String) throws {
    guard Self.isValidProfileID(profileID), !value.isEmpty else {
      throw SourceCredentialsKeychainError.invalidProfile
    }
    lock.lock()
    defer { lock.unlock() }
    var envelope = read()
    envelope.credentials[profileID] = Entry(value: value, updatedAt: Date())
    try write(envelope)
  }

  public func deleteCredential(profileID: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var envelope = read()
    guard envelope.credentials.removeValue(forKey: profileID) != nil else { return }
    try write(envelope)
  }

  public func storedProfileIDs() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return read().credentials.keys.sorted()
  }

  public static func isValidProfileID(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil
  }

  private func read() -> Envelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: fileURL),
          let envelope = try? decoder.decode(Envelope.self, from: data),
          CelorgaNames.schemaMatches(envelope.schema, Self.schema)
    else { return Envelope(schema: Self.schema, credentials: [:]) }
    return envelope
  }

  private func write(_ envelope: Envelope) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(envelope)
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(
      atPath: temporary.path,
      contents: data,
      attributes: [.posixPermissions: 0o600]
    ) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}

/// In-memory store for tests.
public final class SourceCredentialsMemoryStore: SourceCredentialStoring, @unchecked Sendable {
  private var values: [String: String]
  private let lock = NSLock()

  public init(_ values: [String: String] = [:]) {
    self.values = values
  }

  public func containsCredential(profileID: String) -> Bool { credential(profileID: profileID) != nil }

  public func credential(profileID: String) -> String? {
    lock.lock(); defer { lock.unlock() }
    return values[profileID]
  }

  public func saveCredential(_ value: String, profileID: String) throws {
    lock.lock(); defer { lock.unlock() }
    values[profileID] = value
  }

  public func deleteCredential(profileID: String) throws {
    lock.lock(); defer { lock.unlock() }
    values[profileID] = nil
  }

  public func storedProfileIDs() -> [String] {
    lock.lock(); defer { lock.unlock() }
    return values.keys.sorted()
  }
}
