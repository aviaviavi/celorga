import Foundation

extension WorkspaceStore {
  /// The enabled agents a usage-limited message in the selected chat can be
  /// resent to: every enabled destination except the one that hit its limit.
  /// Empty unless the message failed with a usage limit.
  func aiChatResendDestinations(
    forUsageLimitedMessage messageID: UUID
  ) -> [AIChatDestinationConfiguration] {
    guard let threadID = selectedAIChatThreadID,
          let thread = aiChatThread(withID: threadID),
          !thread.isSharedRoom,
          let message = aiChatMessages.first(where: { $0.id == messageID }),
          message.role == .user,
          message.sendFailure.flatMap(AIChatUsageLimit.init(failureText:)) != nil
    else { return [] }
    let limitedDestinationID = message.targetDestinationID ?? thread.destinationID
    return enabledAIChatDestinations.filter { $0.id != limitedDestinationID }
  }

  /// Resends a usage-limited message to another agent the person picked.
  ///
  /// Only an empty chat may change its agent, so this forks the chat to the
  /// chosen destination with the history before the message, then sends the
  /// message there. The original chat keeps its failed message and Retry.
  /// Celorga never chooses another agent on its own; this runs only from an
  /// explicit Resend action.
  @discardableResult
  public func resendUsageLimitedAIChatMessage(
    _ messageID: UUID,
    toDestinationID destinationID: String
  ) async -> UUID? {
    guard let sourceThreadID = selectedAIChatThreadID,
          let destination = aiChatResendDestinations(forUsageLimitedMessage: messageID)
            .first(where: { $0.id == destinationID }),
          let message = aiChatMessages.first(where: { $0.id == messageID })
    else { return nil }
    let context = captureAIChatCorpusContext()
    guard let forkedID = await forkAIChatThread(sourceThreadID, selectsThread: false),
          isCurrentAIChatCorpusContext(context),
          let sourceIndex = aiChatThread(withID: sourceThreadID)?.messages
            .firstIndex(where: { $0.id == messageID }),
          let forkIndex = aiChatThreads.firstIndex(where: { $0.id == forkedID })
    else { return nil }
    let fork = aiChatThreads[forkIndex]
    let configuration = preferredAIChatConfiguration(forDestinationID: destination.id)
    let model = configuration?.model
    let reasoningEffort = configuration?.reasoningEffort
    aiChatThreads[forkIndex] = fork.replacingAIChatMetadata(
      runtime: destination.runtime,
      destinationID: destination.id,
      model: .some(model),
      reasoningEffort: .some(reasoningEffort),
      roomModels: AIChatRoomModelSelection().replacingModel(model, for: destination.runtime),
      roomDestinationIDs: [destination.id],
      roomModelsByDestination: model.map { [destination.id: $0] } ?? [:],
      roomReasoningEffortsByDestination: reasoningEffort.map { [destination.id: $0] } ?? [:],
      roomDefaultDestinationID: .some(destination.id)
    )
    replaceAIChatMessages(
      Array(fork.messages.prefix(sourceIndex)),
      for: forkedID,
      shouldPersist: true
    )
    selectAIChatThread(forkedID, persistsSelection: false)
    persistSelectedAIChatThread()
    aiChatStatusText = "Resending to \(destination.title)…"
    let result = submitAIChatMessage(
      message.content,
      attachments: message.attachments,
      in: forkedID,
      context: context
    )
    _ = await awaitAIChatEnqueueAndImmediateDrain(result)
    return forkedID
  }
}
