import Foundation

/// Limit both row count and text volume while retaining stable history anchors.
/// Pages replace each other instead of accumulating an unbounded eager stack.
enum MobileRemoteTranscriptPage {
  static let messageLimit = 12
  static let messageByteLimit = 4 * 1_024
  static let messageLineLimit = 80

  static func make<Message: Identifiable>(messages: [Message], endingAt id: Message.ID?) -> Range<Int> {
    let end = id.flatMap { id in messages.firstIndex { $0.id == id }.map { $0 + 1 } }
      ?? messages.count
    return max(0, end - messageLimit)..<end
  }

  static func newerPage<Message>(messages: [Message], after start: Int) -> Range<Int> {
    start..<min(messages.count, start + messageLimit)
  }

  /// The page end that shows `id` with some newer context below it, for
  /// jumping from the Outputs sheet to the reply that last touched a file.
  /// `.latest` means the newest page; `nil` means the message is not loaded.
  enum Reveal<ID: Equatable>: Equatable {
    case latest
    case endingAt(ID)
  }

  static func reveal<Message: Identifiable>(_ id: Message.ID, in messages: [Message]) -> Reveal<Message.ID>? {
    guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
    let end = min(messages.count - 1, index + messageLimit / 2)
    return end == messages.count - 1 ? .latest : .endingAt(messages[end].id)
  }

  static func preview(_ content: String) -> (text: String, isTruncated: Bool) {
    // Bound work before regex parsing, attributed-string construction, and
    // layout. A line limit also bounds messages consisting mostly of newlines.
    var bytes = Array(content.utf8.prefix(messageByteLimit + 1))
    let isTruncated = bytes.count > messageByteLimit
    if isTruncated { bytes.removeLast() }
    while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    let prefix = String(decoding: bytes, as: UTF8.self)
    var lineCount = 1
    for index in prefix.indices where prefix[index].isNewline {
      if lineCount == messageLineLimit { return (String(prefix[..<index]), true) }
      lineCount += 1
    }
    return (prefix, isTruncated)
  }
}
