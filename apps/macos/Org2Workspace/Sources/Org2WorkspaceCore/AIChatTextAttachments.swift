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
///
/// Every text-like file (CSV, JSON, source, Org, logs, and so on) is inlined,
/// not only pasted `text/plain`: runtimes that only understand image inputs
/// would otherwise receive a spreadsheet as an unreadable "image".
enum AIChatTextAttachments {
  static func expanding(_ message: AIChatMessage) throws -> AIChatMessage {
    guard message.role == .user, !message.attachments.isEmpty else { return message }
    var blocks: [String] = []
    var remaining: [AIChatAttachment] = []
    for attachment in message.attachments {
      if let text = try inlineText(for: attachment) {
        blocks.append("[Attached text: \(attachment.fileName)]\n\(text)\n[End attached text]")
      } else {
        remaining.append(attachment)
      }
    }
    guard !blocks.isEmpty else { return message }
    return AIChatMessage(
      id: message.id, role: message.role,
      content: ([message.content] + blocks).joined(separator: "\n\n"),
      attachments: remaining,
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

  /// Returns the decoded text for a text-like attachment, or nil when the file
  /// must travel as a binary attachment (images, PDFs, spreadsheets, archives).
  /// Pasted `text/plain` must decode; other text kinds that do not decode fall
  /// back to the binary path instead of blocking the send.
  static func inlineText(for attachment: AIChatAttachment) throws -> String? {
    let mimeType = attachment.mimeType.lowercased()
    if mimeType == "text/plain" {
      guard let text = String(data: try attachment.loadData(), encoding: .utf8) else {
        throw AIChatAttachment.DataError.unreadableBlob(attachment.fileName)
      }
      return text
    }
    switch AIChatAttachmentPresentation.previewKind(for: attachment) {
    case .text:
      return AIChatAttachmentPresentation.decodedText(data: try attachment.loadData())
    case .unsupported where mimeType.isEmpty || mimeType == "application/octet-stream":
      return AIChatAttachmentPresentation.decodedText(data: try attachment.loadData())
    case .image, .pdf, .unsupported:
      return nil
    }
  }
}
