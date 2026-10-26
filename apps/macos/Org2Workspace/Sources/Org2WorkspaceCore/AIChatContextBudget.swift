import CryptoKit
import Foundation

public struct AIChatTokenUsage: Hashable, Codable, Sendable {
  public let inputTokens: Int
  public let cachedInputTokens: Int
  public let outputTokens: Int
  public let totalTokens: Int

  public init(
    inputTokens: Int = 0,
    cachedInputTokens: Int = 0,
    outputTokens: Int = 0,
    totalTokens: Int? = nil
  ) {
    self.inputTokens = max(0, inputTokens)
    self.cachedInputTokens = max(0, cachedInputTokens)
    self.outputTokens = max(0, outputTokens)
    self.totalTokens = max(
      0,
      totalTokens ?? (inputTokens + outputTokens)
    )
  }
}

public struct OpenOrgContextTelemetry: Hashable, Codable, Sendable {
  public enum Mode: String, Codable, Sendable {
    case recovery
    case delta
    case stateless
  }

  public let mode: Mode
  public let staticTokens: Int
  public let projectTokens: Int
  public let transcriptTokens: Int
  public let roomTokens: Int
  public let attachmentTokens: Int

  public init(
    mode: Mode,
    staticTokens: Int = 0,
    projectTokens: Int = 0,
    transcriptTokens: Int = 0,
    roomTokens: Int = 0,
    attachmentTokens: Int = 0
  ) {
    self.mode = mode
    self.staticTokens = max(0, staticTokens)
    self.projectTokens = max(0, projectTokens)
    self.transcriptTokens = max(0, transcriptTokens)
    self.roomTokens = max(0, roomTokens)
    self.attachmentTokens = max(0, attachmentTokens)
  }

  public var totalTokens: Int {
    staticTokens + projectTokens + transcriptTokens + roomTokens + attachmentTokens
  }
}

struct AIChatPersistentContextEnvelope: Sendable {
  let prompt: String?
  let sectionSnapshot: [String: String]
  let telemetry: OpenOrgContextTelemetry
}

struct AIChatPersistentContextKey: Hashable, Sendable {
  let transcriptPath: String
  let threadID: UUID
  let destinationID: String
  let runtimeSessionID: String
}

struct AIChatPersistentContextState: Sendable {
  private var sections: [AIChatPersistentContextKey: [String: String]] = [:]
  private var recoveryRequired: Set<AIChatPersistentContextKey> = []

  mutating func envelope(
    for key: AIChatPersistentContextKey,
    fullPrompt: (_ requiresRecovery: Bool) -> String,
    includesTranscript: Bool,
    roomPrompt: String,
    attachments: [AIChatAttachment]
  ) -> AIChatPersistentContextEnvelope {
    let staleKeys = sections.keys.filter {
      $0.transcriptPath == key.transcriptPath
        && $0.threadID == key.threadID
        && $0.destinationID == key.destinationID
        && $0 != key
    }
    for staleKey in staleKeys {
      sections.removeValue(forKey: staleKey)
      recoveryRequired.remove(staleKey)
    }
    let previousSections = sections[key]
    let forceRecovery = recoveryRequired.remove(key) != nil || previousSections == nil
    return AIChatContextBudget.persistentEnvelope(
      fullPrompt: fullPrompt(forceRecovery),
      previousSections: previousSections,
      forceRecovery: forceRecovery,
      includesTranscript: includesTranscript,
      roomPrompt: roomPrompt,
      attachments: attachments
    )
  }

  mutating func commit(
    _ envelope: AIChatPersistentContextEnvelope,
    for key: AIChatPersistentContextKey
  ) {
    commit(envelope.sectionSnapshot, for: key)
  }

  mutating func commit(
    _ sectionSnapshot: [String: String],
    for key: AIChatPersistentContextKey
  ) {
    guard !recoveryRequired.contains(key) else { return }
    sections[key] = sectionSnapshot
  }

  mutating func requireRecovery(for keys: Set<AIChatPersistentContextKey>) {
    for key in keys {
      recoveryRequired.insert(key)
      sections.removeValue(forKey: key)
    }
  }

  func keys(
    transcriptPath: String,
    threadID: UUID,
    destinationID: String
  ) -> Set<AIChatPersistentContextKey> {
    Set(sections.keys.filter {
      $0.transcriptPath == transcriptPath
        && $0.threadID == threadID
        && $0.destinationID == destinationID
    })
  }
}

enum AIChatContextBudget {
  static let statelessHistoryTokenBudget = 12_000
  static let sharedRoomSummaryTokenBudget = 1_000
  static let sharedRoomUnseenTokenBudget = 3_000
  static let recoveryTranscriptTokenBudget = 6_000

  static func estimatedTokens(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
  }

  static func estimatedAttachmentTokens(_ attachments: [AIChatAttachment]) -> Int {
    attachments.reduce(0) { total, attachment in
      // Base64 provider payloads are roughly four bytes for every three source
      // bytes. The normal text estimator then maps those bytes to tokens.
      total + Int(ceil(Double(attachment.byteCount) / 3.0))
    }
  }

  static func boundedHistory(
    _ messages: [AIChatMessage],
    tokenBudget: Int = statelessHistoryTokenBudget
  ) -> [AIChatMessage] {
    guard let currentMessage = messages.last else { return [] }
    let budget = max(1, tokenBudget)
    var selected = [currentMessage]
    var used = estimatedTokens(currentMessage.content)
      + estimatedAttachmentTokens(currentMessage.attachments)
      + 8
    guard used < budget else {
      // The budget applies to history, never to the user's current request.
      // Dropping the beginning of a large instruction is less safe than
      // omitting all earlier turns for this request.
      return selected
    }
    for message in messages.dropLast().reversed() {
      let messageTokens = estimatedTokens(message.content)
        + estimatedAttachmentTokens(message.attachments)
        + 8
      guard used + messageTokens <= budget else { break }
      selected.append(message)
      used += messageTokens
      guard used < budget else { break }
    }
    return selected.reversed()
  }

  static func boundedSuffix(_ text: String, tokenBudget: Int) -> String {
    let byteBudget = max(4, tokenBudget * 4)
    guard text.utf8.count > byteBudget else { return text }
    let marker = "[Earlier content omitted]\n\n"
    let includesMarker = marker.utf8.count < byteBudget
    let suffixBudget = includesMarker
      ? byteBudget - marker.utf8.count
      : byteBudget
    let bytes = Array(text.utf8.suffix(suffixBudget))
    let firstScalarBoundary = bytes.firstIndex(where: {
      ($0 & 0b1100_0000) != 0b1000_0000
    }) ?? bytes.endIndex
    let suffix = String(decoding: bytes[firstScalarBoundary...], as: UTF8.self)
    return includesMarker ? marker + suffix : suffix
  }

  static func persistentEnvelope(
    fullPrompt: String,
    previousSections: [String: String]?,
    forceRecovery: Bool,
    includesTranscript: Bool,
    roomPrompt: String = "",
    attachments: [AIChatAttachment] = []
  ) -> AIChatPersistentContextEnvelope {
    let sections = promptSections(fullPrompt)
    let snapshot = Dictionary(uniqueKeysWithValues: sections.compactMap { section in
      isTranscriptSection(section.key) ? nil : (section.key, sectionFingerprint(section.text))
    })
    let isRecovery = forceRecovery || previousSections == nil
    let included: [(key: String, text: String)]
    if isRecovery {
      included = sections.compactMap { section in
        guard includesTranscript || !isTranscriptSection(section.key) else { return nil }
        if isTranscriptSection(section.key) {
          return (
            section.key,
            boundedSuffix(section.text, tokenBudget: recoveryTranscriptTokenBudget)
          )
        }
        return section
      }
    } else {
      let changed = sections.filter { section in
        !isTranscriptSection(section.key)
          && previousSections?[section.key] != snapshot[section.key]
      }
      let removed = previousSections?.keys
        .filter {
          snapshot[$0] == nil && !isTranscriptSection($0) && !isRelocatedStandingSection($0)
        }
        .sorted()
        .map { key in
          (
            key: key,
            text: """
            Celorga workspace context removal

            The previously supplied section \(sectionTitle(for: key)) is no longer present. Treat that section as removed and do not rely on its earlier contents.
            """
          )
        } ?? []
      included = changed + removed
    }

    let body = included.map(\.text).joined(separator: "\n\n---\n\n")
    let prompt: String?
    if body.isEmpty {
      prompt = nil
    } else if isRecovery {
      prompt = body
    } else {
      prompt = """
      Celorga workspace context delta

      Only the application-provided sections below changed since the previous successful turn in this runtime session. Keep all other previously supplied Celorga instructions and context.

      \(body)
      """
    }

    let telemetry = telemetry(
      mode: isRecovery ? .recovery : .delta,
      sections: included,
      roomPrompt: roomPrompt,
      attachments: attachments
    )
    return AIChatPersistentContextEnvelope(
      prompt: prompt,
      sectionSnapshot: snapshot,
      telemetry: telemetry
    )
  }

  static func statelessTelemetry(
    systemPrompt: String,
    history: [AIChatMessage],
    roomPrompt: String = ""
  ) -> OpenOrgContextTelemetry {
    let sections = promptSections(systemPrompt)
    let earlierHistory = history.dropLast()
    let historyTokens = earlierHistory.reduce(0) { total, message in
      let contentTokens = message.content == roomPrompt ? 0 : estimatedTokens(message.content)
      return total + contentTokens + 8
    }
    let sectionTelemetry = telemetry(
      mode: .stateless,
      sections: sections,
      roomPrompt: roomPrompt,
      attachments: history.flatMap(\.attachments)
    )
    return OpenOrgContextTelemetry(
      mode: .stateless,
      staticTokens: sectionTelemetry.staticTokens,
      projectTokens: sectionTelemetry.projectTokens,
      transcriptTokens: historyTokens,
      roomTokens: sectionTelemetry.roomTokens,
      attachmentTokens: sectionTelemetry.attachmentTokens
    )
  }

  private static func promptSections(_ prompt: String) -> [(key: String, text: String)] {
    var occurrences: [String: Int] = [:]
    return prompt.components(separatedBy: "\n\n---\n\n").compactMap { raw in
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      let title = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Context"
      let occurrence = occurrences[title, default: 0]
      occurrences[title] = occurrence + 1
      return ("\(title)#\(occurrence)", text)
    }
  }

  private static func sectionFingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  /// Standing instructions that Codex now receives as thread developer
  /// instructions. A session that saw them in its snapshot must not be told
  /// they were removed.
  private static func isRelocatedStandingSection(_ key: String) -> Bool {
    key.hasPrefix("Celorga working rules#")
      || key.hasPrefix("Celorga response formatting contract#")
      || key.hasPrefix("Celorga agent operating guidance#")
      || key.hasPrefix("Celorga agent identity rules#")
  }

  private static func isTranscriptSection(_ key: String) -> Bool {
    key.hasPrefix("Selected AI chat thread continuation#")
  }

  private static func isProjectSection(_ key: String) -> Bool {
    key.hasPrefix("Project context#")
      || key.hasPrefix("Project notes linked to this chat#")
      || key.hasPrefix("Celorga workspace operating context#")
      || key.hasPrefix("Celorga workspace UI snapshot#")
      || key.hasPrefix("Authorized Celorga corpora#")
      || key.hasPrefix("Celorga goals and agent identity#")
      || key.hasPrefix("Connected Celorga sources#")
      || key.hasPrefix("User-selected chat agent#")
      || key.hasPrefix("Current UI selection#")
      || key.hasPrefix("Selected Org ")
      || key.hasPrefix("Computed backlinks#")
      || key.hasPrefix("Agenda snapshot#")
      || key.hasPrefix("Search context:#")
  }

  private static func telemetry(
    mode: OpenOrgContextTelemetry.Mode,
    sections: [(key: String, text: String)],
    roomPrompt: String,
    attachments: [AIChatAttachment]
  ) -> OpenOrgContextTelemetry {
    var staticTokens = 0
    var projectTokens = 0
    var transcriptTokens = 0
    for section in sections {
      let tokens = estimatedTokens(section.text)
      if isTranscriptSection(section.key) {
        transcriptTokens += tokens
      } else if isProjectSection(section.key) {
        projectTokens += tokens
      } else {
        staticTokens += tokens
      }
    }
    return OpenOrgContextTelemetry(
      mode: mode,
      staticTokens: staticTokens,
      projectTokens: projectTokens,
      transcriptTokens: transcriptTokens,
      roomTokens: estimatedTokens(roomPrompt),
      attachmentTokens: estimatedAttachmentTokens(attachments)
    )
  }

  private static func sectionTitle(for key: String) -> String {
    key.replacingOccurrences(of: #"#\d+$"#, with: "", options: .regularExpression)
  }
}
