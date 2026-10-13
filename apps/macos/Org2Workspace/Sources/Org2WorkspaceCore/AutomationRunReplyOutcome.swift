import Foundation

/// Optional explicit lifecycle receipt. Legacy automations retain their existing behavior.
/// Failure wins conflicting receipts; quoted or embedded prose is not a receipt.
enum AutomationRunReplyOutcome: Equatable {
  case completed
  case failed

  static func parse(_ reply: String) -> Self? {
    let lines = reply.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    if lines.contains("ORG2_RUN_OUTCOME: failed") { return .failed }
    if lines.contains("ORG2_RUN_OUTCOME: completed") { return .completed }
    return nil
  }
}
