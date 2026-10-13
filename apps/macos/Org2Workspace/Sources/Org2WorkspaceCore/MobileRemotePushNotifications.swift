import CryptoKit
import Foundation
import Security

struct MobileRemoteStoredPushRegistration: Codable, Hashable, Sendable {
  let deviceToken: String
  let environment: String
  let registeredAt: Date

  init(deviceToken: String, environment: String, registeredAt: Date = Date()) {
    self.deviceToken = deviceToken
    self.environment = environment
    self.registeredAt = registeredAt
  }
}

struct MobileRemoteStoredPushToTalkRegistration: Codable, Hashable, Sendable {
  let pushToken: String
  let environment: String
  let registeredAt: Date
  /// No audio approval pushes before this time (quiet mode or a timed snooze).
  let quietUntil: Date?

  init(pushToken: String, environment: String, registeredAt: Date = Date(), quietUntil: Date? = nil) {
    self.pushToken = pushToken
    self.environment = environment
    self.registeredAt = registeredAt
    self.quietUntil = quietUntil
  }
}

struct MobileRemotePushProviderCredentials: Sendable {
  let teamID: String
  let keyID: String
  let privateKeyPEM: String
}

struct MobileRemotePushEnvelope: Sendable {
  let messageID: UUID
  let threadID: UUID
  let title: String
  let body: String
}

struct MobileRemotePushToTalkEnvelope: Sendable {
  let messageID: UUID
  let runID: String
  let approvalID: String
  let fingerprint: String
}

final class MobileRemotePushCredentialStore: @unchecked Sendable {
  private static let teamIDKey = "Org2Workspace.mobileRemote.pushTeamID.v1"
  private static let keyIDKey = "Org2Workspace.mobileRemote.pushKeyID.v1"
  private static let privateKeyConfiguredKey = "Org2Workspace.mobileRemote.pushPrivateKeyConfigured.v1"

  private let defaults: UserDefaults
  private let service: String
  private let account = "apns-private-key"

  init(defaults: UserDefaults = .standard, credentialNamespace: String? = nil) {
    self.defaults = defaults
    service = (credentialNamespace ?? Bundle.main.bundleIdentifier ?? "org.org2.workspace") + ".mobile-remote-push"
  }

  var teamID: String {
    defaults.string(forKey: Self.teamIDKey) ?? ""
  }

  var keyID: String {
    defaults.string(forKey: Self.keyIDKey) ?? ""
  }

  var isConfigured: Bool {
    !Self.normalizedIdentifier(teamID).isEmpty
      && !Self.normalizedIdentifier(keyID).isEmpty
      && defaults.bool(forKey: Self.privateKeyConfiguredKey)
  }

  var credentials: MobileRemotePushProviderCredentials? {
    let normalizedTeamID = Self.normalizedIdentifier(teamID)
    let normalizedKeyID = Self.normalizedIdentifier(keyID)
    guard !normalizedTeamID.isEmpty,
          !normalizedKeyID.isEmpty,
          let privateKeyPEM = readPrivateKey(),
          (try? P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)) != nil
    else { return nil }
    return MobileRemotePushProviderCredentials(
      teamID: normalizedTeamID,
      keyID: normalizedKeyID,
      privateKeyPEM: privateKeyPEM
    )
  }

  func setTeamID(_ value: String) {
    defaults.set(Self.normalizedIdentifier(value), forKey: Self.teamIDKey)
  }

  func setKeyID(_ value: String) {
    defaults.set(Self.normalizedIdentifier(value), forKey: Self.keyIDKey)
  }

  func importPrivateKey(_ data: Data) throws {
    guard let value = String(data: data, encoding: .utf8),
          (try? P256.Signing.PrivateKey(pemRepresentation: value)) != nil
    else {
      throw MobileRemotePushError.invalidPrivateKey
    }
    try savePrivateKey(value)
    defaults.set(true, forKey: Self.privateKeyConfiguredKey)
  }

  func clearPrivateKey() throws {
    let status = SecItemDelete(keychainQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MobileRemotePushError.keychain(status)
    }
    defaults.set(false, forKey: Self.privateKeyConfiguredKey)
  }

  private var keychainQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
  }

  private func readPrivateKey() -> String? {
    var query = keychainQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func savePrivateKey(_ value: String) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let status = SecItemUpdate(keychainQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var addition = keychainQuery
      attributes.forEach { addition[$0.key] = $0.value }
      let added = SecItemAdd(addition as CFDictionary, nil)
      guard added == errSecSuccess else { throw MobileRemotePushError.keychain(added) }
    } else if status != errSecSuccess {
      throw MobileRemotePushError.keychain(status)
    }
  }

  private static func normalizedIdentifier(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }
}

actor MobileRemotePushSender {
  private struct CachedProviderToken {
    let value: String
    let createdAt: Date
    let credentialKey: String
  }

  private var cachedProviderToken: CachedProviderToken?
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func send(
    _ envelope: MobileRemotePushEnvelope,
    to registration: MobileRemoteStoredPushRegistration,
    credentials: MobileRemotePushProviderCredentials
  ) async throws {
    var lastError: Error?
    for attempt in 0..<3 {
      do {
        try await sendOnce(envelope, to: registration, credentials: credentials)
        return
      } catch let error as MobileRemotePushError where error.isRetryable && attempt < 2 {
        lastError = error
        try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3))
      } catch {
        throw error
      }
    }
    throw lastError ?? MobileRemotePushError.deliveryFailed("Unknown APNs failure")
  }

  func sendPushToTalk(
    _ envelope: MobileRemotePushToTalkEnvelope,
    to registration: MobileRemoteStoredPushToTalkRegistration,
    credentials: MobileRemotePushProviderCredentials
  ) async throws {
    var lastError: Error?
    for attempt in 0..<3 {
      do {
        try await sendPushToTalkOnce(envelope, to: registration, credentials: credentials)
        return
      } catch let error as MobileRemotePushError where error.isRetryable && attempt < 2 {
        lastError = error
        try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3))
      } catch {
        throw error
      }
    }
    throw lastError ?? MobileRemotePushError.deliveryFailed("Unknown APNs failure")
  }

  private func sendOnce(
    _ envelope: MobileRemotePushEnvelope,
    to registration: MobileRemoteStoredPushRegistration,
    credentials: MobileRemotePushProviderCredentials
  ) async throws {
    guard Self.isValidDeviceToken(registration.deviceToken) else {
      throw MobileRemotePushError.invalidDeviceToken
    }
    let host = registration.environment == "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com"
    guard let url = URL(string: "https://\(host)/3/device/\(registration.deviceToken)") else {
      throw MobileRemotePushError.invalidDeviceToken
    }
    let body: [String: Any] = [
      "aps": [
        "alert": ["title": envelope.title, "body": envelope.body],
        "category": "org2.thread.reply",
        "thread-id": envelope.threadID.uuidString,
        "interruption-level": "active"
      ],
      "threadID": envelope.threadID.uuidString,
      "messageID": envelope.messageID.uuidString
    ]
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("bearer \(try providerToken(credentials: credentials))", forHTTPHeaderField: "authorization")
    request.setValue("org.org2.mobile", forHTTPHeaderField: "apns-topic")
    request.setValue("alert", forHTTPHeaderField: "apns-push-type")
    request.setValue("10", forHTTPHeaderField: "apns-priority")
    // Reply alerts are useful only when they are current. Do not let APNs store
    // an undeliverable alert and surface it hours later as an apparent resend.
    request.setValue("0", forHTTPHeaderField: "apns-expiration")
    request.setValue(envelope.threadID.uuidString, forHTTPHeaderField: "apns-collapse-id")
    request.setValue(envelope.messageID.uuidString, forHTTPHeaderField: "apns-id")

    let (responseData, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw MobileRemotePushError.deliveryFailed("APNs returned an unreadable response")
    }
    guard httpResponse.statusCode == 200 else {
      let reason = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])?["reason"] as? String
      throw MobileRemotePushError.apns(status: httpResponse.statusCode, reason: reason)
    }
  }

  private func sendPushToTalkOnce(
    _ envelope: MobileRemotePushToTalkEnvelope,
    to registration: MobileRemoteStoredPushToTalkRegistration,
    credentials: MobileRemotePushProviderCredentials
  ) async throws {
    guard Self.isValidDeviceToken(registration.pushToken) else {
      throw MobileRemotePushError.invalidDeviceToken
    }
    let host = registration.environment == "sandbox"
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com"
    guard let url = URL(string: "https://\(host)/3/device/\(registration.pushToken)") else {
      throw MobileRemotePushError.invalidDeviceToken
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.httpBody = try JSONSerialization.data(withJSONObject: Self.pushToTalkPayload(envelope))
    request.setValue("bearer \(try providerToken(credentials: credentials))", forHTTPHeaderField: "authorization")
    request.setValue(Self.pushToTalkTopic, forHTTPHeaderField: "apns-topic")
    request.setValue("pushtotalk", forHTTPHeaderField: "apns-push-type")
    request.setValue("10", forHTTPHeaderField: "apns-priority")
    request.setValue("0", forHTTPHeaderField: "apns-expiration")
    request.setValue(envelope.messageID.uuidString, forHTTPHeaderField: "apns-id")

    let (responseData, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw MobileRemotePushError.deliveryFailed("APNs returned an unreadable response")
    }
    guard httpResponse.statusCode == 200 else {
      let reason = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])?["reason"] as? String
      throw MobileRemotePushError.apns(status: httpResponse.statusCode, reason: reason)
    }
  }

  /// Apple's Push to Talk topic: the app bundle identifier with the `.voip-ptt` suffix.
  static let pushToTalkTopic = "org.org2.mobile.voip-ptt"

  /// Identity only. Approval titles and actions never travel through APNs; the phone
  /// reads them from the paired host after the push wakes it.
  static func pushToTalkPayload(_ envelope: MobileRemotePushToTalkEnvelope) -> [String: Any] {
    [
      "aps": [String: Any](),
      "runID": envelope.runID,
      "approvalID": envelope.approvalID,
      "fingerprint": envelope.fingerprint
    ]
  }

  private func providerToken(credentials: MobileRemotePushProviderCredentials) throws -> String {
    let credentialKey = credentials.teamID + ":" + credentials.keyID
    if let cachedProviderToken,
       cachedProviderToken.credentialKey == credentialKey,
       Date().timeIntervalSince(cachedProviderToken.createdAt) < 50 * 60 {
      return cachedProviderToken.value
    }
    let createdAt = Date()
    let issuedAt = Int(createdAt.timeIntervalSince1970)
    let header = Self.base64URL(Data("{\"alg\":\"ES256\",\"kid\":\"\(credentials.keyID)\"}".utf8))
    let claims = Self.base64URL(Data("{\"iss\":\"\(credentials.teamID)\",\"iat\":\(issuedAt)}".utf8))
    let unsigned = header + "." + claims
    let key: P256.Signing.PrivateKey
    do {
      key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
    } catch {
      throw MobileRemotePushError.invalidPrivateKey
    }
    let signature = try key.signature(for: Data(unsigned.utf8))
    let token = unsigned + "." + Self.base64URL(signature.rawRepresentation)
    cachedProviderToken = CachedProviderToken(
      value: token,
      createdAt: createdAt,
      credentialKey: credentialKey
    )
    return token
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func isValidDeviceToken(_ token: String) -> Bool {
    !token.isEmpty && token.count <= 512 && token.allSatisfy(\.isHexDigit)
  }
}

enum MobileRemotePushError: LocalizedError {
  case invalidPrivateKey
  case invalidDeviceToken
  case keychain(OSStatus)
  case apns(status: Int, reason: String?)
  case deliveryFailed(String)

  var isRetryable: Bool {
    switch self {
    case .apns(let status, _): status == 429 || (500...599).contains(status)
    default: false
    }
  }

  var invalidatesDeviceToken: Bool {
    switch self {
    case .apns(let status, let reason):
      status == 410 || reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic" || reason == "Unregistered"
    case .invalidDeviceToken:
      true
    default:
      false
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidPrivateKey:
      "Choose a valid Apple Push Notification authentication key (.p8)."
    case .invalidDeviceToken:
      "The iPhone supplied an invalid push token."
    case .keychain(let status):
      "Could not update the push credential in Keychain (\(status))."
    case .apns(let status, let reason):
      "Apple Push Notification service rejected the request (\(status)\(reason.map { ": \($0)" } ?? ""))."
    case .deliveryFailed(let detail):
      detail
    }
  }
}
