import Foundation

/// One-click "Ask AI to Fix" for errors the workspace shows: a data notebook
/// refresh failure or the workspace error banner. It opens a new AI thread on
/// the selected destination, attaches the affected file as context, and sends
/// a request to diagnose the error and, where it is safe, fix it.
extension WorkspaceStore {
  nonisolated static func aiErrorDiagnosisPrompt(
    title: String?,
    message: String,
    action: String?,
    fileReference: String?
  ) -> String {
    var lines: [String] = []
    if let action, !action.isEmpty {
      lines.append("Celorga showed this error while I was trying to \(action).")
    } else {
      lines.append("Celorga showed this error.")
    }
    if let fileReference, !fileReference.isEmpty {
      lines.append("Affected file: \(fileReference)")
    }
    lines.append("")
    if let title, !title.isEmpty, title != message {
      lines.append("Error: \(title)")
    }
    lines.append("#+begin_example")
    lines.append(message)
    lines.append("#+end_example")
    lines.append("")
    lines.append(
      "Diagnose the cause from the file, its configuration, and any logs you can read. "
        + "If the fix is a small, safe change in this corpus, make it with the usual preview "
        + "and retry the failed action to confirm it. Otherwise explain the cause and the exact "
        + "next step, including anything only I can do (such as updating a credential)."
    )
    return lines.joined(separator: "\n")
  }

  nonisolated static func aiErrorDiagnosisThreadTitle(title: String?, message: String) -> String {
    let source = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
      ?? "Error"
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let short = trimmed.count > 70 ? String(trimmed.prefix(69)) + "…" : trimmed
    return "Fix: \(short)"
  }

  public var canAskAIToDiagnoseError: Bool {
    !isSendingAIChatMessage && !enabledAIChatDestinations.isEmpty
  }

  /// Starts a new AI thread that diagnoses `message` and sends it at once.
  public func askAIToDiagnoseError(
    _ rawMessage: String,
    title: String? = nil,
    action: String? = nil,
    file: String? = nil
  ) async {
    let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, canAskAIToDiagnoseError else { return }
    let threadTitle = Self.aiErrorDiagnosisThreadTitle(title: title, message: message)
    let prompt = Self.aiErrorDiagnosisPrompt(
      title: title,
      message: message,
      action: action,
      fileReference: file.map { relativePath($0) }
    )
    if let file {
      let stem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
      startNewAIThread(
        with: [AIChatContextPointer(
          kind: "affected file",
          displayTitle: Self.titleFromFileStem(stem),
          reference: "\(mappedPathForOpenClaw(file)):1",
          displayReference: "\(relativePath(file)):1",
          threadTitle: threadTitle
        )],
        title: threadTitle
      )
    } else {
      let destination = selectedAIChatDestination
      createAIChatThread(
        title: Self.normalizedAIChatThreadTitle(threadTitle),
        statusText: "New \(destination.title) chat",
        runtime: destination.runtime,
        destinationID: destination.id
      )
      setAIChatAssistantPanelPresented(true)
    }
    let draft = currentAIChatDraftForSelectedThread() + prompt
    statusText = "Asking \(selectedAIChatDestination.title) to diagnose the error"
    await sendAIChatMessage(text: draft)
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
