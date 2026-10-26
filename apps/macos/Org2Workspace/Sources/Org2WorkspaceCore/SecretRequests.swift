import Foundation
import SwiftUI

/// A recipient the requested secret will be encrypted to, as resolved by
/// `celorga secret request` (see src/secretRequest.ts).
public struct SecretRequestRecipient: Codable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case recipient
    case file
  }

  public let kind: Kind
  public let value: String
  public let source: String
}

/// An agent's request for a credential, queued as `org2:secret-request:v1`.
/// It never contains a value; the person types the value into a secure sheet.
public struct SecretRequest: Identifiable, Codable, Equatable, Sendable {
  public struct Destination: Codable, Equatable, Sendable {
    public let file: String
  }

  public struct Recipients: Codable, Equatable, Sendable {
    public let defaultKey: Bool
    public let entries: [SecretRequestRecipient]
  }

  public let schema: String
  public let id: String
  public let name: String
  public let reason: String
  public let createdAt: String
  public let authorLabel: String
  public let authorAgentRef: String?
  public let threadID: String?
  public let destination: Destination
  public let recipients: Recipients
}

public struct SecretRequestScan: Sendable {
  public var requests: [SecretRequest] = []
  public var errors: [String] = []
}

public enum SecretRequestQueue {
  public static let schema = "org2:secret-request:v1"

  public static func directory(corpusRoot: URL) -> URL {
    CelorgaNames.stateDirectory(corpusRoot: corpusRoot.standardizedFileURL)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
      .appendingPathComponent("secret-requests", isDirectory: true)
  }

  public static func receiptURL(corpusRoot: URL, requestID: String) -> URL {
    directory(corpusRoot: corpusRoot)
      .appendingPathComponent("receipts", isDirectory: true)
      .appendingPathComponent("\(requestID).json")
  }

  /// Requests without a fulfillment or decline receipt, oldest first.
  public static func loadPending(corpusRoot: URL) -> SecretRequestScan {
    let fileManager = FileManager.default
    guard let files = try? fileManager.contentsOfDirectory(
      at: directory(corpusRoot: corpusRoot),
      includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return SecretRequestScan() }
    var scan = SecretRequestScan()
    for file in files where file.pathExtension.lowercased() == "json" {
      do {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 512_000 else {
          throw SecretRequestError.invalidEnvelope("\(file.lastPathComponent) is not a small regular file")
        }
        let request = try JSONDecoder().decode(SecretRequest.self, from: Data(contentsOf: file))
        try validate(request, fileName: file.lastPathComponent)
        guard !fileManager.fileExists(atPath: receiptURL(corpusRoot: corpusRoot, requestID: request.id).path) else {
          continue
        }
        scan.requests.append(request)
      } catch {
        scan.errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
      }
    }
    scan.requests.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    return scan
  }

  static func validate(_ request: SecretRequest, fileName: String) throws {
    guard CelorgaNames.schemaMatches(request.schema, schema) else {
      throw SecretRequestError.invalidEnvelope("unsupported schema")
    }
    guard let uuid = UUID(uuidString: request.id), uuid.uuidString.lowercased() == request.id,
          fileName == "\(request.id).json"
    else { throw SecretRequestError.invalidEnvelope("request ID does not match its file") }
    guard request.name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil else {
      throw SecretRequestError.invalidEnvelope("invalid secret name")
    }
    let reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
    let author = request.authorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reason.isEmpty, reason.count <= 2_000, !author.isEmpty, author.count <= 200,
          (request.authorAgentRef?.count ?? 0) <= 1_000, (request.threadID?.count ?? 0) <= 200,
          request.recipients.entries.count <= 32
    else { throw SecretRequestError.invalidEnvelope("fields are missing or exceed their limits") }
    guard isCorpusRelative(request.destination.file),
          request.destination.file.range(of: #"\.org2?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    else { throw SecretRequestError.invalidEnvelope("destination must be an .org file inside the corpus") }
    for entry in request.recipients.entries where entry.kind == .file {
      guard isCorpusRelative(entry.value) else {
        throw SecretRequestError.invalidEnvelope("recipient files must stay inside the corpus")
      }
    }
  }

  private static func isCorpusRelative(_ path: String) -> Bool {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return false }
    return !trimmed.split(separator: "/").contains("..")
  }
}

public enum SecretRequestError: LocalizedError, Equatable {
  case invalidEnvelope(String)
  case emptyValue
  case outsideCorpus

  public var errorDescription: String? {
    switch self {
    case .invalidEnvelope(let detail): "Invalid secret request: \(detail)."
    case .emptyValue: "Enter a value, or decline the request."
    case .outsideCorpus: "The secret destination is outside the active corpus."
    }
  }
}

/// The app's GPG settings that apply to sealing. Secrets are always sealed to
/// public-key recipients; a symmetric passphrase is never used.
public struct SecretSealOptions: Equatable, Sendable {
  public var gpgProgram: String
  public var gpgTimeout: TimeInterval
  public var useDefaultGpgKey: Bool
  public var recipients: [String]
  public var recipientFiles: [String]

  public init(settings: OrgCryptSettings) {
    gpgProgram = settings.gpgProgram
    gpgTimeout = settings.gpgTimeout
    useDefaultGpgKey = settings.useDefaultGpgKey
    recipients = settings.recipients
    recipientFiles = settings.recipientFiles
  }
}

public struct SecretFulfillment: Decodable, Equatable, Sendable {
  public let status: String
  public let name: String
  public let file: String
  public let headingID: String
  public let rotated: Bool
}

public protocol SecretSealing: Sendable {
  /// Seals `value` for `request`. Implementations must pass the value only
  /// through memory or a pipe, never through arguments or files.
  func fulfill(_ request: SecretRequest, value: Data, options: SecretSealOptions, corpusRoot: URL) async throws -> SecretFulfillment
  func decline(_ request: SecretRequest, corpusRoot: URL) async throws
}

/// Seals through `celorga secret fulfill`, which pipes the value to gpg and
/// writes only ciphertext. The value is sent on stdin.
public struct CLISecretSealer: SecretSealing {
  let cli: Org2CLI

  public init(cli: Org2CLI) {
    self.cli = cli
  }

  public static func fulfillArguments(requestID: String, options: SecretSealOptions, corpusRoot: URL) -> [String] {
    var arguments = [
      "secret", "fulfill", requestID, "--value-stdin", "--apply", "--json",
      "--dir", corpusRoot.standardizedFileURL.path,
      "--gpg-program", options.gpgProgram,
      "--gpg-timeout", "\(options.gpgTimeout)",
      options.useDefaultGpgKey ? "--default-recipient-self" : "--no-default-recipient-self",
    ]
    for recipient in options.recipients {
      arguments += ["--recipient", recipient]
    }
    for recipientFile in options.recipientFiles {
      arguments += ["--recipient-file", recipientFile]
    }
    return arguments
  }

  public func fulfill(_ request: SecretRequest, value: Data, options: SecretSealOptions, corpusRoot: URL) async throws -> SecretFulfillment {
    try await cli.runJSON(
      Self.fulfillArguments(requestID: request.id, options: options, corpusRoot: corpusRoot),
      standardInput: value,
      as: SecretFulfillment.self
    )
  }

  public func decline(_ request: SecretRequest, corpusRoot: URL) async throws {
    _ = try await cli.run([
      "secret", "decline", request.id, "--apply", "--json",
      "--dir", corpusRoot.standardizedFileURL.path,
    ])
  }
}

/// Native secure entry for an agent's secret request. The typed value lives
/// only in this view's state and is handed straight to the sealer.
struct SecretRequestSheet: View {
  @Environment(WorkspaceStore.self) private var store
  let request: SecretRequest
  @State private var value = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 10) {
        WorkspaceIconBadge(systemImage: "key.fill", tint: .accentColor, fill: Color.accentColor.opacity(0.10))
        VStack(alignment: .leading, spacing: 3) {
          Text("\(requester) is requesting \(request.name)")
            .font(.title3.weight(.semibold))
            .lineLimit(2)
          Text("The value is encrypted before it is saved. It does not go into the chat.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        detailRow("Reason", request.reason)
        detailRow("Requested by", requesterDetail)
        if let thread = store.secretRequestThreadTitle(request) {
          detailRow("Chat", thread)
        }
        detailRow("Saved to", "\(request.destination.file), heading \(request.name)")
        detailRow("Encrypted to", store.secretRequestRecipientSummary(request))
      }
      .font(.callout)

      SecureField("Value for \(request.name)", text: $value)
        .textFieldStyle(.roundedBorder)
        .disabled(store.isSubmittingSecretRequest)
        .onSubmit(submit)
        .accessibilityLabel("Secret value")

      if let error = store.secretRequestErrorText {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Decline", role: .destructive) {
          value = ""
          Task { await store.declineSecretRequest(request) }
        }
        .disabled(store.isSubmittingSecretRequest)
        Spacer()
        Button("Later") {
          value = ""
          store.deferSecretRequest(request)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSubmittingSecretRequest)
        Button("Encrypt and Save", action: submit)
          .keyboardShortcut(.defaultAction)
          .disabled(value.isEmpty || store.isSubmittingSecretRequest)
      }
    }
    .padding(20)
    .frame(minWidth: 480, idealWidth: 560, maxWidth: 720)
    .interactiveDismissDisabled()
    .onDisappear { value = "" }
  }

  private var requester: String {
    request.authorLabel
  }

  private var requesterDetail: String {
    if let ref = request.authorAgentRef, ref != request.authorLabel {
      return "\(request.authorLabel) (\(ref))"
    }
    return request.authorLabel
  }

  private func detailRow(_ label: String, _ text: String) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(label)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(text)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func submit() {
    guard !value.isEmpty, !store.isSubmittingSecretRequest else { return }
    let submitted = value
    Task {
      if await store.submitSecretRequest(request, value: submitted) {
        value = ""
      }
    }
  }
}
