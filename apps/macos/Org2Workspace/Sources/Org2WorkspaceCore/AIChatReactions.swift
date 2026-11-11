import Foundation

/// How reactions reach the agent. A reaction starts no turn; the person's
/// next message in the chat carries every reaction added since their previous
/// message, as a context the transcript shows as a pill.
enum AIChatReactionDelivery {
  /// The most reactions one message carries; older ones are dropped.
  static let maximumDelivered = 12

  /// Reactions added after the person's latest message in `messages`, oldest
  /// first.
  static func pending(
    in messages: [AIChatMessage]
  ) -> [(message: AIChatMessage, reaction: AIChatMessageReaction)] {
    let cutoff = messages.last(where: { $0.role == .user && !$0.isRoomDispatchCopy })?.createdAt
      ?? .distantPast
    let pending = messages
      .filter { !$0.isRoomDispatchCopy }
      .flatMap { message in
        message.reactions
          .filter { $0.createdAt > cutoff }
          .map { (message: message, reaction: $0) }
      }
      .sorted { $0.reaction.createdAt < $1.reaction.createdAt }
    return Array(pending.suffix(maximumDelivered))
  }

  /// `text` with the pending reactions from `messages` as a leading context.
  /// Slash commands go to their runtime unchanged.
  static func text(
    _ text: String,
    deliveringReactionsIn messages: [AIChatMessage],
    author: (AIChatMessage) -> String
  ) -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") else { return text }
    let reactions = pending(in: messages).map { item in
      AIChatContextPresentation.Reaction(
        emoji: item.reaction.emoji,
        author: author(item.message),
        messageID: item.message.id,
        content: item.message.content
      )
    }
    guard let context = AIChatContextPresentation.reactionContext(reactions) else { return text }
    return AIChatContextPresentation.text(text, withReactionContext: context)
  }
}
