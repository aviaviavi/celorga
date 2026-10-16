import Foundation

enum AIChatLargePaste {
  static func shouldAttach(_ text: String) -> Bool {
    var lines = 1
    for (index, character) in text.enumerated() {
      if index >= 7_999 { return true }
      if character == "\n" || character == "\r\n" || character == "\r" {
        lines += 1
        if lines >= 100 { return true }
      }
    }
    return false
  }
}

/// Expand only the outbound copy. Stored messages and drafts retain compact,
/// blob-backed attachments, and every runtime receives ordinary user text.
enum AIChatTextAttachments {
  static func expanding(_ message: AIChatMessage) throws -> AIChatMessage {
    guard message.role == .user else { return message }
    let textAttachments = message.attachments.filter { $0.mimeType == "text/plain" }
    guard !textAttachments.isEmpty else { return message }
    let blocks = try textAttachments.map { attachment in
      guard let text = String(data: try attachment.loadData(), encoding: .utf8) else {
        throw AIChatAttachment.DataError.unreadableBlob(attachment.fileName)
      }
      return "[Attached text: \(attachment.fileName)]\n\(text)\n[End attached text]"
    }
    return AIChatMessage(
      id: message.id, role: message.role,
      content: ([message.content] + blocks).joined(separator: "\n\n"),
      attachments: message.attachments.filter { $0.mimeType != "text/plain" },
      createdAt: message.createdAt, changeSummary: message.changeSummary,
      responseTrace: message.responseTrace, sendFailure: message.sendFailure,
      deliveryStatus: message.deliveryStatus, deliveryKind: message.deliveryKind,
      deliveryAttemptID: message.deliveryAttemptID,
      deliveryAttemptState: message.deliveryAttemptState,
      authorRuntime: message.authorRuntime, authorLabel: message.authorLabel,
      authorAgentRef: message.authorAgentRef, source: message.source,
      audience: message.audience, targetRuntime: message.targetRuntime,
      authorDestinationID: message.authorDestinationID,
      audienceDestinationIDs: message.audienceDestinationIDs,
      targetDestinationID: message.targetDestinationID,
      isRoomDispatchCopy: message.isRoomDispatchCopy, roomRoundID: message.roomRoundID,
      provenance: message.provenance
    )
  }
}
