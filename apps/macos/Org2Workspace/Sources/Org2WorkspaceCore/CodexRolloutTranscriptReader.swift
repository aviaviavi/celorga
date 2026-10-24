import Foundation

enum CodexRolloutTranscriptError: LocalizedError, Sendable {
  case pathUnavailable

  var errorDescription: String? {
    switch self {
    case .pathUnavailable:
      "Codex did not expose a readable transcript for this task."
    }
  }
}

/// Reads the human-visible transcript directly from a Codex rollout without
/// materializing tool output, world state, or other large internal records.
///
/// A long-running Codex task can have a rollout hundreds of megabytes larger
/// than its visible conversation. Asking App Server to decode every turn first
/// makes read-only browsing unnecessarily slow and memory-intensive.
///
/// Two rollout layouts are supported. Older Codex releases record visible text
/// as `user_message` and `agent_message` events. Newer releases record it as
/// `item_completed` events whose item is a `UserMessage` or `AgentMessage` with
/// a list of content parts.
struct CodexRolloutTranscriptReader: Sendable {
  private static let readChunkSize = 4 * 1_024 * 1_024
  private static let eventPrefixLimit = 512
  private static let maximumEventLineSize = 16 * 1_024 * 1_024
  private static let eventMarker = Data(#""type":"event_msg""#.utf8)
  private static let messageMarkers = [
    #""type":"user_message""#,
    #""type":"agent_message""#,
    #""type":"UserMessage""#,
    #""type":"AgentMessage""#
  ].map { Data($0.utf8) }
  private static let newlineMarker = Data([0x0A])

  static func messages(at url: URL) async throws -> [ExternalThreadMessage] {
    try await Task.detached(priority: .userInitiated) {
      try readMessages(at: url)
    }.value
  }

  nonisolated static func readMessages(at url: URL) throws -> [ExternalThreadMessage] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var legacyMessages: [ExternalThreadMessage] = []
    var itemMessages: [ExternalThreadMessage] = []
    var lineBuffer = Data()
    var discardingLine = false
    var lineNumber = 0
    let fractionalTimestampFormatter = ISO8601DateFormatter()
    fractionalTimestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.formatOptions = [.withInternetDateTime]

    func consume(_ bytes: Data.SubSequence, endsLine: Bool) {
      if !discardingLine {
        let prefixBytesNeeded = max(0, eventPrefixLimit - lineBuffer.count)
        let prefixByteCount = min(prefixBytesNeeded, bytes.count)
        if prefixByteCount > 0 {
          lineBuffer.append(contentsOf: bytes.prefix(prefixByteCount))
        }
        if lineBuffer.count >= eventPrefixLimit,
           !mayContainVisibleMessage(lineBuffer) {
          // The record and payload types appear near the start of every JSONL
          // record. Once they are absent from the prefix, stop retaining what
          // may be a multi-megabyte tool payload until its newline arrives.
          lineBuffer.removeAll(keepingCapacity: false)
          discardingLine = true
        } else {
          let remainingBytes = bytes.dropFirst(prefixByteCount)
          if lineBuffer.count + remainingBytes.count > maximumEventLineSize {
            lineBuffer.removeAll(keepingCapacity: false)
            discardingLine = true
          } else {
            lineBuffer.append(contentsOf: remainingBytes)
          }
        }
      }

      guard endsLine else { return }
      lineNumber += 1
      if !discardingLine,
         mayContainVisibleMessage(lineBuffer),
         let message = message(
           from: lineBuffer,
           lineNumber: lineNumber,
           fractionalTimestampFormatter: fractionalTimestampFormatter,
           timestampFormatter: timestampFormatter
         ) {
        if message.isItem {
          itemMessages.append(message.message)
        } else {
          legacyMessages.append(message.message)
        }
      }
      lineBuffer.removeAll(keepingCapacity: true)
      discardingLine = false
    }

    while true {
      try Task.checkCancellation()
      let reachedEnd = try autoreleasepool {
        guard let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty else {
          return true
        }
        var segmentStart = chunk.startIndex
        while let newline = chunk.range(
          of: newlineMarker,
          in: segmentStart..<chunk.endIndex
        )?.lowerBound {
          consume(chunk[segmentStart..<newline], endsLine: true)
          segmentStart = chunk.index(after: newline)
        }
        if segmentStart < chunk.endIndex {
          consume(chunk[segmentStart..<chunk.endIndex], endsLine: false)
        }
        return false
      }
      if reachedEnd { break }
    }

    if !lineBuffer.isEmpty || discardingLine {
      consume(Data.SubSequence(), endsLine: true)
    }
    // A rollout uses one layout, but prefer the item layout if a transitional
    // release ever wrote both so the transcript never shows each turn twice.
    return itemMessages.isEmpty ? legacyMessages : itemMessages
  }

  private nonisolated static func mayContainVisibleMessage(_ prefix: Data) -> Bool {
    guard prefix.range(of: eventMarker) != nil else { return false }
    return messageMarkers.contains { prefix.range(of: $0) != nil }
  }

  private nonisolated static func message(
    from data: Data,
    lineNumber: Int,
    fractionalTimestampFormatter: ISO8601DateFormatter,
    timestampFormatter: ISO8601DateFormatter
  ) -> (message: ExternalThreadMessage, isItem: Bool)? {
    guard let event = try? JSONDecoder().decode(RolloutEvent.self, from: data),
          event.type == "event_msg"
    else { return nil }

    let role: ExternalThreadMessage.Role
    let rawContent: String?
    let id: String?
    let isItem: Bool
    switch event.payload.type {
    case "user_message":
      role = .user
      rawContent = event.payload.message
      id = event.payload.clientID
      isItem = false
    case "agent_message":
      role = .assistant
      rawContent = event.payload.message
      id = event.payload.clientID
      isItem = false
    case "item_completed":
      guard let item = event.payload.item else { return nil }
      switch item.type {
      case "UserMessage":
        role = .user
      case "AgentMessage":
        role = .assistant
      default:
        return nil
      }
      rawContent = item.content?
        .filter { $0.type.lowercased() == "text" }
        .compactMap { normalized($0.text) }
        .joined(separator: "\n\n")
      id = item.id.flatMap(normalized) ?? item.clientID
      isItem = true
    default:
      return nil
    }
    guard let content = normalized(rawContent) else { return nil }

    let createdAt = fractionalTimestampFormatter.date(from: event.timestamp)
      ?? timestampFormatter.date(from: event.timestamp)
      ?? Date(timeIntervalSince1970: 0)
    let messageID = id.flatMap(normalized) ?? "rollout-line-\(lineNumber)"
    return (
      ExternalThreadMessage(id: messageID, role: role, content: content, createdAt: createdAt),
      isItem
    )
  }

  private nonisolated static func normalized(_ value: String?) -> String? {
    guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !normalized.isEmpty
    else { return nil }
    return normalized
  }

  private struct RolloutEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload

    struct Payload: Decodable {
      let type: String
      let clientID: String?
      let message: String?
      let item: Item?

      enum CodingKeys: String, CodingKey {
        case type
        case clientID = "client_id"
        case message
        case item
      }
    }

    struct Item: Decodable {
      let type: String
      let id: String?
      let clientID: String?
      let content: [ContentPart]?

      enum CodingKeys: String, CodingKey {
        case type
        case id
        case clientID = "client_id"
        case content
      }
    }

    struct ContentPart: Decodable {
      let type: String
      let text: String?
    }
  }
}
