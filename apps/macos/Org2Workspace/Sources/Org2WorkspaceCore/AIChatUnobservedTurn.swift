import Foundation

/// A turn a chat counts as running that has no live progress to show, such as
/// a delivery whose confirmation was lost or a send no host reports anymore.
/// The transcript presents it with Stop (and Recheck when the delivery can be
/// reconciled) so a busy chat is never left without visible activity.
public struct AIChatUnobservedTurn: Equatable, Sendable {
  /// The user message (possibly a hidden room dispatch copy) being waited on.
  public let messageID: UUID?
  public let title: String
  public let detail: String?
  /// Recheck reconciles the same attempt; it never submits another turn.
  public let canRecheck: Bool
}
