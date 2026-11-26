import Foundation

/// Codex Fast mode. Codex offers faster service tiers for some models
/// (`priority`, shown as Fast, and sometimes `ultrafast`); the choice applies
/// to every Codex turn, like Codex's own `/fast` toggle.
extension WorkspaceStore {
  /// The service tier id Codex uses for standard speed.
  nonisolated public static let codexStandardServiceTier = "default"

  /// Speed tiers the selected Codex chat's model offers beyond standard.
  /// Empty for other harnesses and for models without faster tiers.
  public var selectedAIChatServiceTierOptions: [AIChatServiceTierOption] {
    guard selectedAIChatDestination.runtime == .codex,
          selectedAIChatThread?.isSharedRoom != true
    else { return [] }
    let modelID = selectedAIChatModel
      ?? aiChatEffectiveModel
      ?? aiChatModelOptions.first(where: \.isDefault)?.id
    guard let modelID else { return [] }
    return aiChatModelOptions.first(where: { $0.id == modelID })?.serviceTiers ?? []
  }

  /// Whether the selected chat can switch Codex Fast mode.
  public var canChooseAIChatServiceTier: Bool {
    !selectedAIChatServiceTierOptions.isEmpty
  }

  /// The selected tier when the current model offers it; standard otherwise.
  public var selectedAIChatServiceTier: AIChatServiceTierOption? {
    guard let tier = codexServiceTier else { return nil }
    return selectedAIChatServiceTierOptions.first(where: { $0.id == tier })
  }

  /// Whether Codex Fast mode (any faster tier) is on for the selected chat.
  public var isAIChatFastModeEnabled: Bool {
    selectedAIChatServiceTier != nil
  }

  public var selectedAIChatServiceTierLabel: String {
    selectedAIChatServiceTier?.label ?? "Standard"
  }

  /// Turns a faster tier on, or returns Codex to standard speed with nil.
  public func setCodexServiceTier(_ tier: String?) {
    let next = tier.flatMap { value -> String? in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } ?? Self.codexStandardServiceTier
    guard codexServiceTier != next else { return }
    codexServiceTier = next
    let label = selectedAIChatServiceTierOptions.first(where: { $0.id == next })?.label
    aiChatStatusText = next == Self.codexStandardServiceTier
      ? "Codex will run at standard speed"
      : "Codex will use \(label ?? next) mode"
  }

  /// Toggles Fast mode, choosing the model's first faster tier.
  public func toggleAIChatFastMode() {
    if isAIChatFastModeEnabled {
      setCodexServiceTier(nil)
    } else if let tier = Self.preferredFastTier(in: selectedAIChatServiceTierOptions) {
      setCodexServiceTier(tier.id)
    }
  }

  /// The tier Fast mode turns on: `priority` when offered, else the first.
  nonisolated static func preferredFastTier(in options: [AIChatServiceTierOption]) -> AIChatServiceTierOption? {
    options.first(where: { $0.id == "priority" }) ?? options.first
  }

  /// The tier to send with a Codex turn. Nil leaves the thread and the
  /// user's Codex config alone. A faster tier the model does not offer falls
  /// back to its Fast tier when it has one; otherwise the turn runs standard.
  nonisolated static func codexTurnServiceTier(
    setting: String?,
    modelTiers: [AIChatServiceTierOption]?
  ) -> String? {
    guard let setting else { return nil }
    if setting == codexStandardServiceTier { return setting }
    guard let modelTiers else { return setting }
    if modelTiers.contains(where: { $0.id == setting }) { return setting }
    return preferredFastTier(in: modelTiers)?.id ?? codexStandardServiceTier
  }

  func codexTurnServiceTier(destinationID: String, model: String?) -> String? {
    let cached = aiChatConfigurationCatalogCache[destinationID]
    let modelID = cached?.effectiveModel(forRequestedModel: model) ?? model
    let modelTiers = modelID.flatMap { id in
      cached?.models.first(where: { $0.id == id })?.serviceTiers
    }
    return Self.codexTurnServiceTier(setting: codexServiceTier, modelTiers: modelTiers)
  }
}
