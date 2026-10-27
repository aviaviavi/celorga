import CryptoKit
import Foundation

public struct AIChatLocalEditWorkspaceContext: Equatable, Sendable {
  public let nodeDisplayName: String
  public let turnID: String

  public init(nodeDisplayName: String, turnID: String) {
    self.nodeDisplayName = nodeDisplayName
    self.turnID = turnID
  }

  public func systemPrompt() -> String {
    """
    Local Celorga edit node

    This chat turn can read and edit the active Mac app corpus through the paired node named "\(nodeDisplayName)". Its turnId is "\(turnID)". It may also read an additional corpus explicitly authorized in the workspace context, but writes remain scoped to the active corpus.

    For corpus reads and writes, use the OpenClaw `nodes` tool with action `invoke`, node `\(nodeDisplayName)`, and one of these typed commands. Do not edit corpus files with Gateway filesystem or shell tools during this turn.

    1. Read effective local text, including any unsaved editor draft:
       invokeCommand: \(AIChatLocalEditBroker.readCommand)
       invokeParamsJson: {"turnId":"\(turnID)","path":"relative/path.org"}
       For an additional authorized corpus, include its exact local root from the workspace context as "corpusRoot".
    2. Preview one or more whole-file replacements. Existing files require the exact sha256 returned by read:
       invokeCommand: \(AIChatLocalEditBroker.previewCommand)
       invokeParamsJson: {"turnId":"\(turnID)","edits":[{"path":"relative/path.org","expectedSha256":"<read sha256>","replacementText":"<complete replacement text>"}]}
       To create a file, omit expectedSha256 and set "createsFile":true.
       To rename or move an existing file, add "moveTo":"new/relative/path.org" with its expectedSha256; replacementText is optional and defaults to the current text.
       To move an existing file to the Trash, send {"path":"relative/path.org","expectedSha256":"<read sha256>","trashesFile":true} without replacementText.
    3. Apply the exact preview only after preview succeeds:
       invokeCommand: \(AIChatLocalEditBroker.applyCommand)
       invokeParamsJson: {"turnId":"\(turnID)","previewId":"<previewId>"}

    Always read before replacing an existing file. Preserve the complete effective document, including unsaved user text. If a stale-document error occurs, read again and rebuild the replacement. The apply result is the authoritative change set for this response.
    """
  }
}

public enum AIChatLocalEditDocumentOrigin: String, Codable, Sendable {
  case disk
  case editor
  case missing
}

public struct AIChatLocalEditDocument: Equatable, Sendable {
  public let relativePath: String
  public let text: String
  public let origin: AIChatLocalEditDocumentOrigin

  public init(
    relativePath: String,
    text: String,
    origin: AIChatLocalEditDocumentOrigin
  ) {
    self.relativePath = relativePath
    self.text = text
    self.origin = origin
  }

  public var sha256: String {
    AIChatLocalEditBroker.sha256(text)
  }
}

public struct AIChatLocalEditReplacement: Equatable, Sendable {
  public let relativePath: String
  public let expectedSHA256: String?
  public let replacementText: String
  public let createsFile: Bool
  /// Moves the existing file to the Trash instead of replacing its text.
  public let trashesFile: Bool
  /// For a file created by a rename, the path it was moved from. The source
  /// is trashed by a separate replacement in the same preview.
  public let movedFromRelativePath: String?

  public init(
    relativePath: String,
    expectedSHA256: String?,
    replacementText: String,
    createsFile: Bool,
    trashesFile: Bool = false,
    movedFromRelativePath: String? = nil
  ) {
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
    self.replacementText = replacementText
    self.createsFile = createsFile
    self.trashesFile = trashesFile
    self.movedFromRelativePath = movedFromRelativePath
  }

  /// The file's text after the edit, or nil when the edit removes it.
  public var finalText: String? {
    trashesFile ? nil : replacementText
  }
}

public struct AIChatLocalEditApplyResult: Equatable, Sendable {
  public let summary: AIChatCorpusChangeSummary

  public init(summary: AIChatCorpusChangeSummary) {
    self.summary = summary
  }
}

public struct AIChatLocalEditCommandResult: Equatable, Sendable {
  public let ok: Bool
  public let payloadJSON: String?
  public let errorCode: String?
  public let errorMessage: String?

  public init(
    ok: Bool,
    payloadJSON: String? = nil,
    errorCode: String? = nil,
    errorMessage: String? = nil
  ) {
    self.ok = ok
    self.payloadJSON = payloadJSON
    self.errorCode = errorCode
    self.errorMessage = errorMessage
  }
}

public enum AIChatLocalEditError: LocalizedError, Equatable, Sendable {
  case invalidRequest(String)
  case inactiveTurn
  case unsupportedCommand(String)
  case staleDocument(String)
  case missingDocument(String)
  case existingDocument(String)
  case expiredPreview
  case oversizedRequest

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let detail):
      return "Invalid local edit request: \(detail)"
    case .inactiveTurn:
      return "This local edit turn is no longer active."
    case .unsupportedCommand(let command):
      return "Unsupported local edit command: \(command)"
    case .staleDocument(let path):
      return "\(path) changed after it was read. Read it again before previewing or applying an edit."
    case .missingDocument(let path):
      return "\(path) does not exist. Set createsFile to true to preview creating it."
    case .existingDocument(let path):
      return "\(path) already exists and cannot be created as a new file."
    case .expiredPreview:
      return "The local edit preview expired. Preview the edit again before applying it."
    case .oversizedRequest:
      return "The local edit request is too large."
    }
  }
}

/// Owns the preview/apply transaction boundary for edits executed by the Mac app.
///
/// The broker deliberately uses whole-file replacements. The agent must read the
/// effective local document first, including an unsaved editor draft when one is
/// active, and then preview a replacement against that exact SHA-256. Applying a
/// preview rechecks every document before any writes begin.
public actor AIChatLocalEditBroker {
  public static let readCommand = "org2.workspace.read"
  public static let previewCommand = "org2.workspace.patch.preview"
  public static let applyCommand = "org2.workspace.patch.apply"
  public static let commands = [readCommand, previewCommand, applyCommand]

  public typealias DocumentReader =
    @MainActor @Sendable (String, String, String?) throws -> AIChatLocalEditDocument
  public typealias ReplacementApplier =
    @MainActor @Sendable (
      String,
      [AIChatLocalEditReplacement]
    ) async throws -> AIChatLocalEditApplyResult

  private struct ReadRequest: Decodable {
    let turnID: String
    let path: String
    let corpusRoot: String?

    enum CodingKeys: String, CodingKey {
      case turnID = "turnId"
      case path
      case corpusRoot
    }
  }

  private struct PreviewRequest: Decodable {
    let turnID: String
    let edits: [Edit]

    struct Edit: Decodable {
      let path: String
      let expectedSHA256: String?
      let replacementText: String?
      let createsFile: Bool
      let moveTo: String?
      let trashesFile: Bool

      enum CodingKeys: String, CodingKey {
        case path
        case expectedSHA256 = "expectedSha256"
        case replacementText
        case createsFile
        case moveTo
        case trashesFile
      }

      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        expectedSHA256 = try container.decodeIfPresent(String.self, forKey: .expectedSHA256)
        replacementText = try container.decodeIfPresent(String.self, forKey: .replacementText)
        createsFile = try container.decodeIfPresent(Bool.self, forKey: .createsFile) ?? false
        moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .nilIfBlank
        trashesFile = try container.decodeIfPresent(Bool.self, forKey: .trashesFile) ?? false
      }
    }

    enum CodingKeys: String, CodingKey {
      case turnID = "turnId"
      case edits
    }
  }

  private struct ApplyRequest: Decodable {
    let turnID: String
    let previewID: String

    enum CodingKeys: String, CodingKey {
      case turnID = "turnId"
      case previewID = "previewId"
    }
  }

  private struct Preview {
    let id: String
    let turnID: String
    let createdAt: Date
    let replacements: [AIChatLocalEditReplacement]
    let documentsByPath: [String: AIChatLocalEditDocument]
    let summary: AIChatCorpusChangeSummary
  }

  private struct AppliedDocumentState {
    let originalText: String?
    var finalText: String?
  }

  private let documentReader: DocumentReader
  private let replacementApplier: ReplacementApplier
  private var activeTurnIDs = Set<String>()
  private var previews: [String: Preview] = [:]
  private var appliedDocumentsByTurnID: [String: [String: AppliedDocumentState]] = [:]

  private static let maximumEditCount = 8
  private static let maximumDocumentBytes = 2_000_000
  private static let maximumTotalReplacementBytes = 4_000_000
  private static let previewLifetime: TimeInterval = 30 * 60

  public init(
    documentReader: @escaping DocumentReader,
    replacementApplier: @escaping ReplacementApplier
  ) {
    self.documentReader = documentReader
    self.replacementApplier = replacementApplier
  }

  public func beginTurn(_ turnID: String) {
    let normalized = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    activeTurnIDs.insert(normalized)
    removeExpiredPreviews()
  }

  public func endTurn(_ turnID: String) {
    activeTurnIDs.remove(turnID)
    previews = previews.filter { $0.value.turnID != turnID }
    appliedDocumentsByTurnID.removeValue(forKey: turnID)
  }

  public func consumeChangeSummary(for turnID: String) -> AIChatCorpusChangeSummary? {
    guard let documents = appliedDocumentsByTurnID.removeValue(forKey: turnID)
    else {
      return nil
    }

    let changes = documents.compactMap { path, document in
      Self.fileChange(
        path: path,
        before: document.originalText,
        after: document.finalText
      )
    }.sorted {
      $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
    guard !changes.isEmpty else {
      return nil
    }
    return AIChatCorpusChangeSummary(files: changes)
  }

  private func recordAppliedDocuments(from preview: Preview) {
    var appliedDocuments = appliedDocumentsByTurnID[preview.turnID] ?? [:]
    for replacement in preview.replacements {
      if var existing = appliedDocuments[replacement.relativePath] {
        existing.finalText = replacement.finalText
        appliedDocuments[replacement.relativePath] = existing
      } else if let document = preview.documentsByPath[replacement.relativePath] {
        appliedDocuments[replacement.relativePath] = AppliedDocumentState(
          originalText: document.origin == .missing ? nil : document.text,
          finalText: replacement.finalText
        )
      }
    }
    appliedDocumentsByTurnID[preview.turnID] = appliedDocuments
  }

  public func handle(command: String, paramsJSON: String?) async -> AIChatLocalEditCommandResult {
    do {
      switch command {
      case Self.readCommand:
        return try await handleRead(paramsJSON)
      case Self.previewCommand:
        return try await handlePreview(paramsJSON)
      case Self.applyCommand:
        return try await handleApply(paramsJSON)
      default:
        throw AIChatLocalEditError.unsupportedCommand(command)
      }
    } catch let error as AIChatLocalEditError {
      return AIChatLocalEditCommandResult(
        ok: false,
        errorCode: Self.errorCode(error),
        errorMessage: error.localizedDescription
      )
    } catch {
      return AIChatLocalEditCommandResult(
        ok: false,
        errorCode: "LOCAL_EDIT_FAILED",
        errorMessage: error.localizedDescription
      )
    }
  }

  private func handleRead(_ paramsJSON: String?) async throws -> AIChatLocalEditCommandResult {
    let request: ReadRequest = try decode(paramsJSON)
    try requireActiveTurn(request.turnID)
    let document = try await documentReader(request.turnID, request.path, request.corpusRoot)
    guard document.text.utf8.count <= Self.maximumDocumentBytes else {
      throw AIChatLocalEditError.oversizedRequest
    }
    return try successJSON([
      "path": document.relativePath,
      "text": document.text,
      "sha256": document.sha256,
      "origin": document.origin.rawValue,
      "exists": document.origin != .missing
    ])
  }

  private func handlePreview(_ paramsJSON: String?) async throws -> AIChatLocalEditCommandResult {
    let request: PreviewRequest = try decode(paramsJSON)
    try requireActiveTurn(request.turnID)
    guard !request.edits.isEmpty,
          request.edits.count <= Self.maximumEditCount,
          request.edits.reduce(0, { $0 + ($1.replacementText?.utf8.count ?? 0) }) <= Self.maximumTotalReplacementBytes
    else {
      throw AIChatLocalEditError.oversizedRequest
    }

    var replacements: [AIChatLocalEditReplacement] = []
    var changes: [AIChatCorpusFileChange] = []
    var documentsByPath: [String: AIChatLocalEditDocument] = [:]
    var seenPaths = Set<String>()

    for edit in request.edits {
      let document = try await documentReader(request.turnID, edit.path, nil)
      guard seenPaths.insert(document.relativePath).inserted else {
        throw AIChatLocalEditError.invalidRequest("duplicate path \(document.relativePath)")
      }
      guard (edit.replacementText?.utf8.count ?? 0) <= Self.maximumDocumentBytes else {
        throw AIChatLocalEditError.oversizedRequest
      }

      if edit.trashesFile || edit.moveTo != nil {
        guard !edit.createsFile, !(edit.trashesFile && edit.moveTo != nil) else {
          throw AIChatLocalEditError.invalidRequest(
            "\(document.relativePath): choose only one of createsFile, moveTo, or trashesFile"
          )
        }
        let expectedSHA256 = try Self.verifiedExistingSHA256(edit, document: document)
        documentsByPath[document.relativePath] = document
        let trash = AIChatLocalEditReplacement(
          relativePath: document.relativePath,
          expectedSHA256: expectedSHA256,
          replacementText: "",
          createsFile: false,
          trashesFile: true
        )
        guard let moveTo = edit.moveTo else {
          guard edit.replacementText == nil else {
            throw AIChatLocalEditError.invalidRequest(
              "\(document.relativePath): omit replacementText when trashesFile is true"
            )
          }
          replacements.append(trash)
          if let change = Self.fileChange(path: document.relativePath, before: document.text, after: nil) {
            changes.append(change)
          }
          continue
        }
        let destination = try await documentReader(request.turnID, moveTo, nil)
        guard destination.relativePath != document.relativePath else {
          throw AIChatLocalEditError.invalidRequest(
            "\(document.relativePath): moveTo must name a different path"
          )
        }
        guard seenPaths.insert(destination.relativePath).inserted else {
          throw AIChatLocalEditError.invalidRequest("duplicate path \(destination.relativePath)")
        }
        guard destination.origin == .missing else {
          throw AIChatLocalEditError.existingDocument(destination.relativePath)
        }
        let movedText = edit.replacementText ?? document.text
        documentsByPath[destination.relativePath] = destination
        // Write the destination before trashing the source, so a failed move
        // never leaves the text only in the Trash.
        replacements.append(AIChatLocalEditReplacement(
          relativePath: destination.relativePath,
          expectedSHA256: nil,
          replacementText: movedText,
          createsFile: true,
          movedFromRelativePath: document.relativePath
        ))
        replacements.append(trash)
        if let change = Self.fileChange(path: destination.relativePath, before: nil, after: movedText) {
          changes.append(change)
        }
        if let change = Self.fileChange(path: document.relativePath, before: document.text, after: nil) {
          changes.append(change)
        }
        continue
      }

      guard let replacementText = edit.replacementText else {
        throw AIChatLocalEditError.invalidRequest(
          "replacementText is required for \(document.relativePath)"
        )
      }
      if edit.createsFile {
        guard document.origin == .missing else {
          throw AIChatLocalEditError.existingDocument(document.relativePath)
        }
      } else {
        guard document.origin != .missing else {
          throw AIChatLocalEditError.missingDocument(document.relativePath)
        }
        guard let expectedSHA256 = edit.expectedSHA256?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !expectedSHA256.isEmpty
        else {
          throw AIChatLocalEditError.invalidRequest(
            "expectedSha256 is required for \(document.relativePath)"
          )
        }
        guard expectedSHA256 == document.sha256 else {
          throw AIChatLocalEditError.staleDocument(document.relativePath)
        }
      }

      documentsByPath[document.relativePath] = document
      let replacement = AIChatLocalEditReplacement(
        relativePath: document.relativePath,
        expectedSHA256: edit.createsFile ? nil : document.sha256,
        replacementText: replacementText,
        createsFile: edit.createsFile
      )
      replacements.append(replacement)
      if let change = Self.fileChange(
        path: document.relativePath,
        before: edit.createsFile ? nil : document.text,
        after: replacementText
      ) {
        changes.append(change)
      }
    }

    let summary = AIChatCorpusChangeSummary(files: changes)
    let preview = Preview(
      id: UUID().uuidString.lowercased(),
      turnID: request.turnID,
      createdAt: Date(),
      replacements: replacements,
      documentsByPath: documentsByPath,
      summary: summary
    )
    previews[preview.id] = preview
    trimPreviews()

    return try successJSON([
      "previewId": preview.id,
      "turnId": preview.turnID,
      "title": preview.summary.title,
      "changes": preview.summary.files.map(Self.changeDictionary)
    ])
  }

  private static func verifiedExistingSHA256(
    _ edit: PreviewRequest.Edit,
    document: AIChatLocalEditDocument
  ) throws -> String {
    guard document.origin != .missing else {
      throw AIChatLocalEditError.missingDocument(document.relativePath)
    }
    guard let expectedSHA256 = edit.expectedSHA256?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !expectedSHA256.isEmpty
    else {
      throw AIChatLocalEditError.invalidRequest(
        "expectedSha256 is required for \(document.relativePath)"
      )
    }
    guard expectedSHA256 == document.sha256 else {
      throw AIChatLocalEditError.staleDocument(document.relativePath)
    }
    return expectedSHA256
  }

  private func handleApply(_ paramsJSON: String?) async throws -> AIChatLocalEditCommandResult {
    let request: ApplyRequest = try decode(paramsJSON)
    try requireActiveTurn(request.turnID)
    removeExpiredPreviews()
    guard let preview = previews[request.previewID],
          preview.turnID == request.turnID
    else {
      throw AIChatLocalEditError.expiredPreview
    }

    for replacement in preview.replacements {
      let document = try await documentReader(request.turnID, replacement.relativePath, nil)
      if replacement.createsFile {
        guard document.origin == .missing else {
          throw AIChatLocalEditError.staleDocument(replacement.relativePath)
        }
      } else {
        guard document.origin != .missing,
              document.sha256 == replacement.expectedSHA256
        else {
          throw AIChatLocalEditError.staleDocument(replacement.relativePath)
        }
      }
    }

    let result = try await replacementApplier(request.turnID, preview.replacements)
    previews.removeValue(forKey: preview.id)
    recordAppliedDocuments(from: preview)
    return try successJSON([
      "applied": true,
      "turnId": request.turnID,
      "title": result.summary.title,
      "changes": result.summary.files.map(Self.changeDictionary)
    ])
  }

  private func requireActiveTurn(_ turnID: String) throws {
    guard activeTurnIDs.contains(turnID) else {
      throw AIChatLocalEditError.inactiveTurn
    }
  }

  private func decode<T: Decodable>(_ paramsJSON: String?) throws -> T {
    guard let paramsJSON,
          let data = paramsJSON.data(using: .utf8)
    else {
      throw AIChatLocalEditError.invalidRequest("paramsJSON is required")
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw AIChatLocalEditError.invalidRequest(error.localizedDescription)
    }
  }

  private func successJSON(_ value: [String: Any]) throws -> AIChatLocalEditCommandResult {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
      throw AIChatLocalEditError.invalidRequest("could not encode result")
    }
    return AIChatLocalEditCommandResult(ok: true, payloadJSON: json)
  }

  private func removeExpiredPreviews(now: Date = Date()) {
    previews = previews.filter {
      now.timeIntervalSince($0.value.createdAt) <= Self.previewLifetime
        && activeTurnIDs.contains($0.value.turnID)
    }
  }

  private func trimPreviews() {
    guard previews.count > 32 else { return }
    let retainedIDs = previews.values
      .sorted { $0.createdAt > $1.createdAt }
      .prefix(32)
      .map(\.id)
    previews = previews.filter { Set(retainedIDs).contains($0.key) }
  }

  private static func errorCode(_ error: AIChatLocalEditError) -> String {
    switch error {
    case .invalidRequest: "INVALID_REQUEST"
    case .inactiveTurn: "INACTIVE_TURN"
    case .unsupportedCommand: "UNSUPPORTED_COMMAND"
    case .staleDocument: "STALE_DOCUMENT"
    case .missingDocument: "MISSING_DOCUMENT"
    case .existingDocument: "EXISTING_DOCUMENT"
    case .expiredPreview: "EXPIRED_PREVIEW"
    case .oversizedRequest: "REQUEST_TOO_LARGE"
    }
  }

  nonisolated static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  nonisolated private static func changeDictionary(
    _ change: AIChatCorpusFileChange
  ) -> [String: Any] {
    [
      "path": change.relativePath,
      "status": change.status.rawValue,
      "insertions": change.insertions,
      "deletions": change.deletions
    ]
  }

  nonisolated static func fileChange(
    path: String,
    before: String?,
    after: String?
  ) -> AIChatCorpusFileChange? {
    switch (before, after) {
    case let (before?, after?):
      guard before != after else { return nil }
      let counts = lineChangeCounts(before: before, after: after)
      return AIChatCorpusFileChange(
        relativePath: path,
        status: .modified,
        insertions: counts.insertions,
        deletions: counts.deletions
      )
    case let (nil, after?):
      return AIChatCorpusFileChange(
        relativePath: path,
        status: .created,
        insertions: textLines(after).count,
        deletions: 0
      )
    case let (before?, nil):
      return AIChatCorpusFileChange(
        relativePath: path,
        status: .deleted,
        insertions: 0,
        deletions: textLines(before).count
      )
    case (nil, nil):
      return nil
    }
  }

  nonisolated private static func lineChangeCounts(
    before oldText: String,
    after newText: String
  ) -> (insertions: Int, deletions: Int) {
    let oldLines = textLines(oldText)
    let newLines = textLines(newText)
    guard !oldLines.isEmpty || !newLines.isEmpty else { return (0, 0) }
    let canRunExactDiff = oldLines.count <= 1_000_000 / max(1, newLines.count)
    let commonLineCount = canRunExactDiff
      ? longestCommonSubsequenceCount(oldLines, newLines)
      : prefixSuffixCommonLineCount(oldLines, newLines)
    return (
      insertions: max(0, newLines.count - commonLineCount),
      deletions: max(0, oldLines.count - commonLineCount)
    )
  }

  nonisolated private static func textLines(_ text: String) -> [String] {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    guard !normalized.isEmpty else { return [] }
    var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if normalized.hasSuffix("\n") { lines.removeLast() }
    return lines
  }

  nonisolated private static func longestCommonSubsequenceCount(
    _ oldLines: [String],
    _ newLines: [String]
  ) -> Int {
    guard !oldLines.isEmpty, !newLines.isEmpty else { return 0 }
    var previous = Array(repeating: 0, count: newLines.count + 1)
    var current = previous
    for oldLine in oldLines {
      current[0] = 0
      for index in newLines.indices {
        current[index + 1] = oldLine == newLines[index]
          ? previous[index] + 1
          : max(previous[index + 1], current[index])
      }
      swap(&previous, &current)
    }
    return previous[newLines.count]
  }

  nonisolated private static func prefixSuffixCommonLineCount(
    _ oldLines: [String],
    _ newLines: [String]
  ) -> Int {
    let sharedLimit = min(oldLines.count, newLines.count)
    var prefixCount = 0
    while prefixCount < sharedLimit, oldLines[prefixCount] == newLines[prefixCount] {
      prefixCount += 1
    }
    var suffixCount = 0
    while suffixCount < sharedLimit - prefixCount,
          oldLines[oldLines.count - 1 - suffixCount] == newLines[newLines.count - 1 - suffixCount] {
      suffixCount += 1
    }
    return prefixCount + suffixCount
  }
}
