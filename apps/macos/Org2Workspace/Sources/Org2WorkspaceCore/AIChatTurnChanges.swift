import Foundation

/// One-line markers in a transcript where the user's agent, model, or
/// reasoning effort changed between their turns.
///
/// Rules:
/// - Only user turns count: not hidden room dispatch copies, not steering
///   messages added to a running turn, and not turns another agent requested.
/// - A turn is compared with the previous counted turn in the same thread, so
///   the first turn never gets a marker.
/// - Single-agent threads mark an agent change using the recorded selection,
///   or the message's target agent for turns sent before selections were
///   recorded. Shared rooms only mark changes of the room's default agent and
///   that agent's model and effort; an @mention that routes one message to a
///   different agent is not a change and is never marked.
/// - Model and effort changes need a recorded selection on both turns, so old
///   transcripts never show a guessed change.
enum AIChatTurnChangeMarkers {
  struct Labels {
    var destinationTitle: (String) -> String
    var modelTitle: (_ model: String, _ destinationID: String) -> String

    init(
      destinationTitle: @escaping (String) -> String,
      modelTitle: @escaping (_ model: String, _ destinationID: String) -> String = { model, _ in model }
    ) {
      self.destinationTitle = destinationTitle
      self.modelTitle = modelTitle
    }
  }

  /// Marker text keyed by message ID. `messages` is in transcript order and
  /// may start with earlier context; markers are only returned for
  /// `markedMessageIDs` when it is given.
  static func markers(
    for messages: [AIChatMessage],
    isSharedRoom: Bool,
    labels: Labels,
    markedMessageIDs: Set<UUID>? = nil
  ) -> [UUID: String] {
    var markers: [UUID: String] = [:]
    var previousDestinationID: String?
    var previousSettings: AIChatTurnSettings?
    for message in messages where countsAsTurn(message) {
      let settings = message.provenance?.turnSettings
      let destinationID = isSharedRoom
        ? settings?.destinationID
        : (settings?.destinationID ?? message.targetDestinationID)
      guard let destinationID else { continue }
      defer {
        previousDestinationID = destinationID
        if let settings { previousSettings = settings }
      }
      guard markedMessageIDs?.contains(message.id) ?? true else { continue }
      if let previousDestinationID, previousDestinationID != destinationID {
        markers[message.id] = agentChangeText(
          destinationID: destinationID,
          settings: settings,
          isSharedRoom: isSharedRoom,
          labels: labels
        )
      } else if let settings,
                let previousSettings,
                previousSettings.destinationID == settings.destinationID,
                previousSettings.model != settings.model
                  || previousSettings.reasoningEffort != settings.reasoningEffort {
        markers[message.id] = selectionChangeText(
          destinationID: destinationID,
          settings: settings,
          modelChanged: previousSettings.model != settings.model,
          isSharedRoom: isSharedRoom,
          labels: labels
        )
      }
    }
    return markers
  }

  static func countsAsTurn(_ message: AIChatMessage) -> Bool {
    message.role == .user
      && !message.isRoomDispatchCopy
      && message.deliveryKind != .steer
      && message.provenance?.isAgentTurnRequest != true
  }

  /// The earlier messages a windowed transcript needs so its first visible
  /// turn can be compared with the turn before it. Scans back from the end of
  /// `allMessages` at most `scanLimit` messages, so a long history costs the
  /// same as a short one; past the limit the first visible turn is unmarked.
  static func precedingContext(
    before firstVisibleMessageID: UUID?,
    in allMessages: [AIChatMessage],
    scanLimit: Int = 600,
    contextLimit: Int = 200
  ) -> ArraySlice<AIChatMessage> {
    guard let firstVisibleMessageID else { return [] }
    let lowerBound = max(allMessages.startIndex, allMessages.endIndex - scanLimit)
    var index = allMessages.endIndex
    while index > lowerBound {
      index -= 1
      if allMessages[index].id == firstVisibleMessageID {
        return allMessages[max(allMessages.startIndex, index - contextLimit)..<index]
      }
    }
    return []
  }

  private static func agentChangeText(
    destinationID: String,
    settings: AIChatTurnSettings?,
    isSharedRoom: Bool,
    labels: Labels
  ) -> String {
    let agent = labels.destinationTitle(destinationID)
    var parts = [isSharedRoom ? "Default agent is now \(agent)" : "Now talking to \(agent)"]
    if let model = settings?.model {
      parts.append(labels.modelTitle(model, destinationID))
    }
    if let effort = settings?.reasoningEffort {
      parts.append(effortText(effort))
    }
    return parts.joined(separator: " · ")
  }

  private static func selectionChangeText(
    destinationID: String,
    settings: AIChatTurnSettings,
    modelChanged: Bool,
    isSharedRoom: Bool,
    labels: Labels
  ) -> String {
    let prefix = isSharedRoom ? "Switched \(labels.destinationTitle(destinationID)) to" : "Switched to"
    guard modelChanged else {
      return "\(prefix) \(settings.reasoningEffort.map(effortText) ?? "default effort")"
    }
    var parts = [settings.model.map { labels.modelTitle($0, destinationID) } ?? "the default model"]
    if let effort = settings.reasoningEffort {
      parts.append(effortText(effort))
    }
    return "\(prefix) \(parts.joined(separator: " · "))"
  }

  static func effortText(_ effort: String) -> String {
    switch effort.lowercased() {
    case "off", "none": return "reasoning off"
    default: return "\(WorkspaceStore.aiChatReasoningLabel(effort).lowercased()) effort"
    }
  }
}

extension WorkspaceStore {
  /// The selection a turn sent now records: the thread's agent, or a shared
  /// room's default agent, with that agent's chosen model and effort.
  func aiChatTurnSettings(for thread: AIChatThread) -> AIChatTurnSettings {
    let destinationID = thread.isSharedRoom
      ? aiChatRoomDefaultDestinationID(for: thread)
      : thread.destinationID
    return AIChatTurnSettings(
      destinationID: destinationID,
      model: destinationID.flatMap { thread.model(forDestinationID: $0) },
      reasoningEffort: destinationID.flatMap { thread.reasoningEffort(forDestinationID: $0) }
    )
  }

  /// A model's display name from the cached catalog, or its ID.
  func aiChatModelTitle(_ model: String, destinationID: String) -> String {
    aiChatConfigurationCatalogCache[destinationID]?.models.first(where: { $0.id == model })?.label ?? model
  }

  var aiChatTurnChangeLabels: AIChatTurnChangeMarkers.Labels {
    AIChatTurnChangeMarkers.Labels(
      destinationTitle: { self.aiChatDestinationTitle($0) },
      modelTitle: { model, destinationID in
        self.aiChatModelTitle(model, destinationID: destinationID)
      }
    )
  }
}
