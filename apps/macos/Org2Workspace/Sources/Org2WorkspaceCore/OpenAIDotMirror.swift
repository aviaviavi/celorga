import CryptoKit
import Foundation

/// Mirrors a dot's whole ChatGPT conversation into one Celorga chat.
///
/// The mirror shows every message in the conversation, including messages
/// sent from ChatGPT on another device and results the dot posts on its own.
/// ChatGPT stays the source of truth, so the chat keeps only the newest
/// stretch of the conversation (`retainedMessageLimit` messages) and reads
/// earlier messages from ChatGPT when the reader scrolls back. That keeps a
/// conversation with tens of thousands of messages as cheap to store, sync,
/// and render as a short chat.
///
/// Every mirrored message gets an ID derived from its ChatGPT message ID, so
/// reading the same message twice, on one Mac or on several sharing the
/// transcript, never shows it twice. Messages Celorga sent carry their
/// Celorga message ID as the ChatGPT request ID and are recognized the same way.
enum OpenAIDotMirror {
  /// Marks a chat as a mirror. The value is the dot destination's ID.
  static let destinationKey = "org2.openai-dot-mirror"
  /// The ChatGPT conversation the mirror reads.
  static let roomKey = "org2.openai-dot-mirror.room"
  /// The newest ChatGPT message the mirror has read.
  static let cursorKey = "org2.openai-dot-mirror.cursor"

  /// Messages kept in the chat after trimming.
  static let retainedMessageLimit = 200
  /// The chat is trimmed back to `retainedMessageLimit` once it holds this
  /// many messages, so trimming (and its sync traffic) happens in batches.
  static let trimThreshold = 300
  /// Messages read when a mirror starts.
  static let initialMessageCount = 100
  /// Messages read from ChatGPT each time the reader asks for earlier ones.
  static let earlierPageSize = 64

  static func messageID(roomID: String, messageID: String) -> UUID {
    let digest = SHA256.hash(data: Data("openorg-openai-dot-mirror:\(roomID):\(messageID)".utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  /// The Celorga message a ChatGPT message echoes, when Celorga sent it.
  static func celorgaMessageID(of message: OpenAIDotMessage) -> UUID? {
    message.requestID.flatMap(UUID.init(uuidString:))
  }

  /// The transcript message for one ChatGPT message, or nil when it has
  /// nothing to show.
  static func transcriptMessage(
    _ message: OpenAIDotMessage,
    roomID: String,
    selfMemberID: String
  ) -> AIChatMessage? {
    guard !message.isDeleted, message.hasVisibleContent else { return nil }
    let isUser = message.memberID == selfMemberID
    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = [isUser ? text : OpenAIDotTurnResult.orgLinks(text)]
      + message.attachments.map(\.summary)
    return AIChatMessage(
      id: messageID(roomID: roomID, messageID: message.id),
      role: isUser ? .user : .assistant,
      content: parts.filter { !$0.isEmpty }.joined(separator: "\n\n"),
      createdAt: message.createdAt ?? Date()
    )
  }

  struct Merge: Equatable {
    var messages: [AIChatMessage]
    var addedCount: Int
    var trimmedCount: Int
    var changed: Bool { addedCount > 0 || trimmedCount > 0 }
  }

  /// Adds newly read ChatGPT messages to a mirror's transcript.
  ///
  /// New messages join the live end, before any message still being sent.
  /// A message already shown, one Celorga sent, or one older than the chat's
  /// oldest message (trimmed earlier, or never part of the chat) is skipped.
  /// The result is trimmed from the front once it reaches `trimThreshold`.
  static func merge(
    existing: [AIChatMessage],
    incoming: [OpenAIDotMessage],
    roomID: String,
    selfMemberID: String,
    retainedMessageLimit: Int = retainedMessageLimit,
    trimThreshold: Int = trimThreshold
  ) -> Merge {
    var knownIDs = Set(existing.map(\.id))
    // Once the chat has been trimmed, a message older than its oldest one
    // was trimmed on purpose (here or on another Mac) and must not return.
    let oldest = existing.count >= retainedMessageLimit ? existing.first?.createdAt : nil
    var additions: [AIChatMessage] = []
    for message in incoming {
      if let celorgaID = celorgaMessageID(of: message), knownIDs.contains(celorgaID) { continue }
      guard let transcript = transcriptMessage(message, roomID: roomID, selfMemberID: selfMemberID),
            !knownIDs.contains(transcript.id)
      else { continue }
      if let oldest, let createdAt = message.createdAt, createdAt < oldest { continue }
      knownIDs.insert(transcript.id)
      additions.append(transcript)
    }
    var messages = existing
    if !additions.isEmpty {
      var liveEnd = messages.endIndex
      while liveEnd > messages.startIndex {
        let previous = messages[messages.index(before: liveEnd)]
        guard previous.role == .user, previous.deliveryStatus == .sending else { break }
        liveEnd = messages.index(before: liveEnd)
      }
      // New messages almost always belong at the live end. One read before
      // a message typed in Celorga (for example while the mirror was still
      // starting) goes before it, keeping the conversation's order.
      for addition in additions {
        var index = liveEnd
        while index > messages.startIndex,
              messages[messages.index(before: index)].createdAt > addition.createdAt {
          index = messages.index(before: index)
        }
        messages.insert(addition, at: index)
        liveEnd = messages.index(after: liveEnd)
      }
    }
    var trimmed = 0
    if messages.count >= trimThreshold {
      trimmed = messages.count - max(1, retainedMessageLimit)
      messages.removeFirst(trimmed)
    }
    return Merge(messages: messages, addedCount: additions.count, trimmedCount: trimmed)
  }

  /// Converts ChatGPT messages older than everything shown into transcript
  /// messages, skipping any already shown.
  static func earlierMessages(
    _ page: [OpenAIDotMessage],
    shown: [AIChatMessage],
    roomID: String,
    selfMemberID: String
  ) -> [AIChatMessage] {
    let shownIDs = Set(shown.map(\.id))
    let oldest = shown.first?.createdAt
    return page.compactMap { message in
      if let celorgaID = celorgaMessageID(of: message), shownIDs.contains(celorgaID) { return nil }
      guard let transcript = transcriptMessage(message, roomID: roomID, selfMemberID: selfMemberID),
            !shownIDs.contains(transcript.id)
      else { return nil }
      if let oldest, let createdAt = message.createdAt, createdAt >= oldest { return nil }
      return transcript
    }
  }

  /// How long to wait before checking the conversation again. The mirror
  /// checks every few seconds right after activity and slows while it's quiet.
  static func pollInterval(sinceActivity elapsed: TimeInterval) -> TimeInterval {
    switch elapsed {
    case ..<120: 3
    case ..<(20 * 60): 10
    default: 45
    }
  }

  /// How long to wait after a failed check. Network and server failures
  /// back off from 5 seconds; sign-in and routing failures retry every 5
  /// minutes, so the mirror recovers once Codex refreshes its sign-in.
  static func retryInterval(after error: Error, previous: TimeInterval) -> TimeInterval {
    if let error = error as? OpenAIDotChatError, error.isTransient {
      return min(300, max(5, previous * 2))
    }
    return 300
  }
}

extension AIChatThread {
  /// The dot destination this chat mirrors, if it is a dot mirror.
  public var openAIDotMirrorDestinationID: String? {
    let value = runtimeThreadIDsByDestination[OpenAIDotMirror.destinationKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false && !isSharedRoom ? value : nil
  }

  public var isOpenAIDotMirror: Bool { openAIDotMirrorDestinationID != nil }

  /// The newest ChatGPT message read, if it belongs to `roomID`.
  func openAIDotMirrorCursor(roomID: String) -> String? {
    guard runtimeThreadIDsByDestination[OpenAIDotMirror.roomKey] == roomID else { return nil }
    let cursor = runtimeThreadIDsByDestination[OpenAIDotMirror.cursorKey]
    return cursor?.isEmpty == false ? cursor : nil
  }
}

/// Reading earlier messages of a dot mirror from ChatGPT.
public struct OpenAIDotMirrorHistoryState: Equatable, Sendable {
  public var isLoading = false
  /// The conversation's first message has been read.
  public var reachedStart = false
  /// The oldest ChatGPT message read so far, where the next read continues.
  var oldestMessageID: String?

  public init() {}
}

/// A running mirror watch.
struct OpenAIDotMirrorWatch {
  let token: UUID
  let destinationID: String
  /// The destination settings the watch reads with; a change restarts it.
  let settingsKey: String
  let transcriptPath: String
  let task: Task<Void, Never>

  static func settingsKey(for destination: AIChatDestinationConfiguration) -> String {
    "\(destination.endpoint)\u{0}\(destination.agentID)"
  }
}

/// What a mirror watch remembers between checks.
@MainActor
final class OpenAIDotMirrorPollState {
  let token: UUID
  let threadID: UUID
  let transcriptURL: URL
  let context: AIChatCorpusContextToken
  let client: OpenAIDotChatClient
  var room: OpenAIDotRoom?
  var retryDelay: TimeInterval = 0

  init(
    token: UUID,
    threadID: UUID,
    transcriptURL: URL,
    context: AIChatCorpusContextToken,
    client: OpenAIDotChatClient
  ) {
    self.token = token
    self.threadID = threadID
    self.transcriptURL = transcriptURL
    self.context = context
    self.client = client
  }
}
