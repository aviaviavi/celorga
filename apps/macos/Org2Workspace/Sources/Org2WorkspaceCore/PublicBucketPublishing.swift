import Foundation
import LocalAuthentication
import Security

/// A user-owned S3-compatible bucket (Cloudflare R2, Amazon S3, and
/// compatible stores) that hosts public document links. Celorga uploads one
/// sealed artifact per link through `celorga publish document --to bucket`
/// and deletes it to revoke the link. No Celorga backend is involved and no
/// inbound connection reaches this Mac.
///
/// The configuration is machine-local and holds no secrets; the access key
/// pair lives in Keychain.
public struct PublicBucketConfiguration: Codable, Hashable, Sendable {
  public var endpoint: String
  public var bucket: String
  public var region: String
  public var publicBaseURL: String
  public var keyPrefix: String

  public static let defaultRegion = "auto"
  public static let defaultKeyPrefix = "p/"
  static let defaultsKey = "org.celorga.public-bucket.configuration"

  public init(
    endpoint: String = "",
    bucket: String = "",
    region: String = PublicBucketConfiguration.defaultRegion,
    publicBaseURL: String = "",
    keyPrefix: String = PublicBucketConfiguration.defaultKeyPrefix
  ) {
    self.endpoint = endpoint
    self.bucket = bucket
    self.region = region
    self.publicBaseURL = publicBaseURL
    self.keyPrefix = keyPrefix
  }

  /// Trims whitespace and fills the defaults the CLI would apply.
  public var normalized: PublicBucketConfiguration {
    let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
    return PublicBucketConfiguration(
      endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
      bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
      region: trimmedRegion.isEmpty ? Self.defaultRegion : trimmedRegion,
      publicBaseURL: publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      keyPrefix: keyPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// Enough to try a request. The CLI validates the values themselves; the
  /// bucket may be omitted when the endpoint is R2's per-bucket S3 API URL.
  public var isComplete: Bool {
    let value = normalized
    return !value.endpoint.isEmpty && !value.publicBaseURL.isEmpty
  }

  /// Identifies where a link's objects live, so a link is updated or revoked
  /// only against the bucket that holds it.
  public var identity: String {
    let value = normalized
    return [value.endpoint, value.bucket, value.keyPrefix].joined(separator: "\n")
  }

  public var displayName: String {
    let value = normalized
    if !value.bucket.isEmpty { return value.bucket }
    return URL(string: value.endpoint)?.lastPathComponent.nilIfEmpty ?? "Public bucket"
  }

  /// `--endpoint … --public-base-url …` options shared by every bucket command.
  public var cliArguments: [String] {
    let value = normalized
    var arguments = ["--endpoint", value.endpoint]
    if !value.bucket.isEmpty {
      arguments.append(contentsOf: ["--bucket", value.bucket])
    }
    arguments.append(contentsOf: [
      "--public-base-url", value.publicBaseURL,
      "--region", value.region,
      "--key-prefix", value.keyPrefix,
    ])
    return arguments
  }

  public static func load(defaults: UserDefaults = .standard) -> PublicBucketConfiguration? {
    guard let data = defaults.data(forKey: defaultsKey) else { return nil }
    return try? JSONDecoder().decode(PublicBucketConfiguration.self, from: data)
  }

  public static func save(_ configuration: PublicBucketConfiguration?, defaults: UserDefaults = .standard) {
    guard let configuration,
          let data = try? JSONEncoder().encode(configuration.normalized)
    else {
      defaults.removeObject(forKey: defaultsKey)
      return
    }
    defaults.set(data, forKey: defaultsKey)
  }
}

public struct PublicBucketCredentials: Codable, Hashable, Sendable {
  public var accessKeyID: String
  public var secretAccessKey: String

  public init(accessKeyID: String, secretAccessKey: String) {
    self.accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.secretAccessKey = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isComplete: Bool { !accessKeyID.isEmpty && !secretAccessKey.isEmpty }

  /// Passed to the CLI child process only; never written to arguments or disk.
  public var environment: [String: String] {
    [
      "CELORGA_BUCKET_ACCESS_KEY_ID": accessKeyID,
      "CELORGA_BUCKET_SECRET_ACCESS_KEY": secretAccessKey,
    ]
  }
}

public enum PublicBucketCredentialKeychain {
  public static let service = "Org2Workspace.PublicBucket"
  public static let account = "s3-access-key"

  public static func read(allowUserInteraction: Bool = false) -> PublicBucketCredentials? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = !allowUserInteraction
    query[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data
    else { return nil }
    return try? JSONDecoder().decode(PublicBucketCredentials.self, from: data)
  }

  public static func save(_ credentials: PublicBucketCredentials) throws {
    guard credentials.isComplete else { throw PublicBucketError.missingCredentials }
    let data = try JSONEncoder().encode(credentials)
    var addition = baseQuery
    addition[kSecValueData as String] = data
    addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(addition as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard update == errSecSuccess else { throw PublicBucketError.keychain(update) }
      return
    }
    guard status == errSecSuccess else { throw PublicBucketError.keychain(status) }
  }

  public static func delete() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PublicBucketError.keychain(status)
    }
  }

  private static var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

/// A public link this Mac created in a bucket. Kept machine-local, like local
/// links: the URL is a bearer secret and does not belong in the synced corpus.
public struct PublicBucketPublication: Codable, Identifiable, Hashable, Sendable {
  /// The unguessable object ID in the link.
  public let id: String
  public var title: String
  public var url: URL
  public var mediaType: String
  public var sourcePath: String?
  public var formatRawValue: String?
  /// Source file, scope, and format; publishing the same one again updates
  /// this link in place.
  public var stableKey: String?
  /// `PublicBucketConfiguration.identity` of the bucket holding the objects.
  public var targetIdentity: String
  public var bucketName: String
  public var createdAt: Date
  public var updatedAt: Date

  public var format: DocumentPublishFormat? {
    formatRawValue.flatMap(DocumentPublishFormat.init(rawValue:))
  }

  public init(
    id: String,
    title: String,
    url: URL,
    mediaType: String,
    sourcePath: String?,
    format: DocumentPublishFormat?,
    stableKey: String?,
    targetIdentity: String,
    bucketName: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.url = url
    self.mediaType = mediaType
    self.sourcePath = sourcePath
    self.formatRawValue = format?.rawValue
    self.stableKey = stableKey
    self.targetIdentity = targetIdentity
    self.bucketName = bucketName
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public enum PublicBucketPublicationList {
  static let defaultsKey = "org.celorga.public-bucket.publications"

  public static func load(defaults: UserDefaults = .standard) -> [PublicBucketPublication] {
    guard let data = defaults.data(forKey: defaultsKey) else { return [] }
    return (try? JSONDecoder().decode([PublicBucketPublication].self, from: data)) ?? []
  }

  public static func save(_ publications: [PublicBucketPublication], defaults: UserDefaults = .standard) {
    if publications.isEmpty {
      defaults.removeObject(forKey: defaultsKey)
    } else if let data = try? JSONEncoder().encode(publications) {
      defaults.set(data, forKey: defaultsKey)
    }
  }
}

public struct PublicBucketCheckResult: Sendable, Equatable {
  public let publiclyReadable: Bool
  public let detail: String?
}

struct PublicBucketCommandResult: Decodable {
  struct Result: Decodable {
    let publiclyReadable: Bool?
    let detail: String?
    let deletedKeys: [String]?
  }

  let applied: Bool
  let result: Result
}

public enum PublicBucketError: LocalizedError, Sendable, Equatable {
  case notConfigured
  case missingCredentials
  case invalidResponse
  case keychain(OSStatus)
  case differentBucket(String)

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      "Set up a public bucket in Settings → Sharing → Public Links first."
    case .missingCredentials:
      "Enter the bucket's access key ID and secret access key in Settings → Sharing → Public Links."
    case .invalidResponse:
      "The bucket upload finished without returning a public link."
    case .keychain(let status):
      "Could not update the bucket access key in Keychain (status \(status))."
    case .differentBucket(let name):
      "This link is stored in \(name), which is no longer the configured bucket. Configure that bucket again to stop it, or delete the object in your storage provider."
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
