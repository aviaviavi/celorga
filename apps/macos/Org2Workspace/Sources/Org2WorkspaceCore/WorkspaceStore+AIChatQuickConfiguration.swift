import Foundation

/// Keyboard-driven choice of the selected chat's runtime, model, and
/// reasoning effort, so a new thread (⌘N) can be configured without the
/// pointer: ⌃⌘1–⌃⌘9 pick a runtime, ⌃⌘[ and ⌃⌘] step through models, and
/// ⌃⌘- and ⌃⌘= lower or raise the reasoning effort.
public enum AIChatQuickConfiguration {
  /// Runtimes reachable with ⌃⌘1 through ⌃⌘9.
  public static let maximumNumberedDestinations = 9

  /// The model after (or before) `current` in the picker's order: the
  /// destination default first, then each reported model. Wraps around.
  public static func steppedModel(current: String?, options: [String], by step: Int) -> String? {
    let choices: [String?] = [nil] + options.map(Optional.some)
    guard choices.count > 1 else { return current }
    let index = choices.firstIndex(of: current) ?? 0
    let next = ((index + step) % choices.count + choices.count) % choices.count
    return choices[next]
  }

  /// The reasoning level one step above or below the effective level,
  /// clamped to the reported range rather than wrapping from the highest
  /// level to the lowest.
  public static func steppedReasoningEffort(
    current: String?,
    defaultEffort: String?,
    options: [String],
    by step: Int
  ) -> String? {
    guard !options.isEmpty else { return current }
    let effective = current ?? defaultEffort
    guard let index = effective.flatMap({ options.firstIndex(of: $0) }) else {
      return step >= 0 ? options[0] : options[options.count - 1]
    }
    return options[min(options.count - 1, max(0, index + step))]
  }
}

extension WorkspaceStore {
  /// The runtime ⌃⌘`number` selects, counting enabled runtimes from 1.
  public func aiChatQuickDestination(number: Int) -> AIChatDestinationConfiguration? {
    let destinations = enabledAIChatDestinations
    guard number >= 1,
          number <= AIChatQuickConfiguration.maximumNumberedDestinations,
          number <= destinations.count
    else { return nil }
    return destinations[number - 1]
  }

  public func selectAIChatQuickDestination(number: Int) {
    guard let destination = aiChatQuickDestination(number: number) else { return }
    guard canChangeSelectedAIChatRuntime else {
      aiChatStatusText = "This chat's runtime can't change now"
      return
    }
    setSelectedAIChatDestination(destination.id)
    aiChatStatusText = "Next message will go to \(destination.title)"
  }

  public var canStepAIChatModel: Bool {
    canChangeSelectedAIChatConfiguration
      && selectedAIChatDestination.adapter != .openAIDot
      && !aiChatModelOptions.isEmpty
  }

  public func stepAIChatModel(by step: Int) {
    guard canStepAIChatModel else { return }
    let next = AIChatQuickConfiguration.steppedModel(
      current: selectedAIChatModel,
      options: aiChatModelOptions.map(\.id),
      by: step
    )
    setSelectedAIChatModel(next)
    aiChatStatusText = next == nil
      ? "Model: \(selectedAIChatDestination.title) default"
      : "Model: \(selectedAIChatModelLabel)"
  }

  public var canStepAIChatReasoningEffort: Bool {
    canChangeSelectedAIChatConfiguration
      && selectedAIChatDestination.supportsReasoningEffort
      && !aiChatReasoningOptions.isEmpty
  }

  public func stepAIChatReasoningEffort(by step: Int) {
    guard canStepAIChatReasoningEffort else { return }
    let next = AIChatQuickConfiguration.steppedReasoningEffort(
      current: selectedAIChatReasoningEffort,
      defaultEffort: aiChatDefaultReasoningEffort,
      options: aiChatReasoningOptions.map(\.id),
      by: step
    )
    setSelectedAIChatReasoningEffort(next)
    aiChatStatusText = "Reasoning: \(selectedAIChatReasoningLabel)"
  }
}
