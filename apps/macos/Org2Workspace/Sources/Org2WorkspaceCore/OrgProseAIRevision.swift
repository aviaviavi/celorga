import Foundation

// "Revise with AI" in Prose mode: one explicit, user-initiated text-in/text-out
// request to a direct model provider the user configured. No tools, no agent
// turn, no history, and nothing from the corpus beyond the selection and a
// bounded amount of surrounding prose. The reply becomes another version of
// the selected span; Celorga never applies or chooses it on its own.

/// The single model call a revision makes. `AIProviderChatClient` conforms;
/// tests use a stub.
protocol OrgProseRevisionProvider: Sendable {
  func complete(system: String, prompt: String, model: String, maxTokens: Int) async throws -> String
}

extension AIProviderChatClient: OrgProseRevisionProvider {}

enum OrgProseRevisionError: Error, Equatable, LocalizedError {
  case emptyInstruction
  case passageTooLong(Int)
  case emptyResponse
  case noProvider

  var errorDescription: String? {
    switch self {
    case .emptyInstruction:
      return "Describe how to revise the text."
    case .passageTooLong(let limit):
      return "The selection is too long to revise in one request (limit \(limit) characters)."
    case .emptyResponse:
      return "The model returned no revised text. Nothing was changed."
    case .noProvider:
      return "Revise with AI needs a direct model provider. Add OpenAI, Anthropic, OpenRouter, Ollama, or an OpenAI-compatible endpoint in Settings → AI Chat."
    }
  }
}

struct OrgProseRevisionRequest: Equatable, Sendable {
  static let maxPassageLength = 24_000
  static let maxInstructionLength = 2_000
  static let maxTokens = 4_096

  static let systemPrompt = """
  You revise one passage of the user's own writing. Apply the instruction to the passage and reply with only the revised passage: no preamble, explanation, alternatives, quotation marks, or code fences. Keep the passage's language and any Org markup (links, emphasis, list markers, line breaks) unless the instruction asks otherwise. The text before and after the passage is context only; never repeat, continue, or change it. You have no tools.
  """

  let instruction: String
  let passage: String
  let contextBefore: String
  let contextAfter: String

  init(instruction: String, target: OrgProseRevisionTarget) throws {
    let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw OrgProseRevisionError.emptyInstruction }
    guard target.text.utf16.count <= Self.maxPassageLength else {
      throw OrgProseRevisionError.passageTooLong(Self.maxPassageLength)
    }
    self.instruction = String(trimmed.prefix(Self.maxInstructionLength))
    self.passage = target.text
    self.contextBefore = target.contextBefore
    self.contextAfter = target.contextAfter
  }

  var userPrompt: String {
    var sections = ["Instruction:\n<instruction>\n\(instruction)\n</instruction>"]
    if !contextBefore.isEmpty {
      sections.append("Text before the passage (context only):\n<before>\n\(contextBefore)\n</before>")
    }
    sections.append("Passage to revise:\n<passage>\n\(passage)\n</passage>")
    if !contextAfter.isEmpty {
      sections.append("Text after the passage (context only):\n<after>\n\(contextAfter)\n</after>")
    }
    sections.append("Reply with only the revised passage.")
    return sections.joined(separator: "\n\n")
  }
}

enum OrgProseRevisionResponse {
  private static let quotePairs: [(Character, Character)] = [
    ("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"), ("\u{2018}", "\u{2019}"),
    ("\u{00AB}", "\u{00BB}"), ("`", "`")
  ]

  /// Removes wrappers models add despite the instructions (code fences, an
  /// echoed `<passage>` tag, wrapping quotes), then restores the original
  /// passage's leading and trailing whitespace so a revised paragraph keeps
  /// its line breaks.
  static func clean(_ raw: String, original: String) throws -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let originalCore = original.trimmingCharacters(in: .whitespacesAndNewlines)
    for _ in 0..<4 {
      let next = unwrapOnce(text, originalCore: originalCore)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if next == text { break }
      text = next
    }
    guard !text.isEmpty else { throw OrgProseRevisionError.emptyResponse }
    return leadingWhitespace(of: original) + text + trailingWhitespace(of: original)
  }

  private static func unwrapOnce(_ text: String, originalCore: String) -> String {
    if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
      var inner = String(text.dropFirst(3).dropLast(3))
      // Drop an info string such as ```org on the opening line.
      if let newline = inner.firstIndex(of: "\n") {
        let info = inner[..<newline]
        if !info.contains(where: { $0.isWhitespace }) || info.trimmingCharacters(in: .whitespaces).isEmpty {
          inner = String(inner[inner.index(after: newline)...])
        }
      }
      return inner
    }
    for tag in ["passage", "revised", "revision"] {
      let open = "<\(tag)>"
      let close = "</\(tag)>"
      if text.hasPrefix(open), text.hasSuffix(close), text.count >= open.count + close.count,
         !originalCore.hasPrefix(open) {
        return String(text.dropFirst(open.count).dropLast(close.count))
      }
    }
    for (open, close) in quotePairs {
      guard text.count >= 2, text.first == open, text.last == close,
            originalCore.first != open || originalCore.last != close
      else { continue }
      let inner = text.dropFirst().dropLast()
      // `"Yes," she said, "go."` is quoted prose, not a wrapper.
      guard !inner.contains(open), !inner.contains(close) else { continue }
      return String(inner)
    }
    return text
  }

  private static func leadingWhitespace(of text: String) -> String {
    String(text.prefix { $0.isWhitespace })
  }

  private static func trailingWhitespace(of text: String) -> String {
    String(text.reversed().prefix { $0.isWhitespace }.reversed())
  }
}

/// A resolved provider choice for one request.
struct OrgProseRevisionBackend: Sendable {
  /// Display name, such as the destination's name.
  let label: String
  /// The provider kind recorded in provenance, such as `anthropic`.
  let providerKind: String
  let model: String
  let provider: any OrgProseRevisionProvider
}

enum OrgProseReviser {
  /// Sends the one request and returns cleaned text ready to become a version.
  static func revise(
    target: OrgProseRevisionTarget,
    instruction: String,
    backend: OrgProseRevisionBackend
  ) async throws -> String {
    let request = try OrgProseRevisionRequest(instruction: instruction, target: target)
    let raw = try await backend.provider.complete(
      system: OrgProseRevisionRequest.systemPrompt,
      prompt: request.userPrompt,
      model: backend.model,
      maxTokens: OrgProseRevisionRequest.maxTokens
    )
    try Task.checkCancellation()
    return try OrgProseRevisionResponse.clean(raw, original: target.text)
  }
}

/// Which configured direct provider and model a revision uses. The last
/// choice is remembered in preferences, never in the document.
struct OrgProseRevisionPreferences {
  static let destinationKey = "Org2Workspace.prose.aiRevision.destinationID"
  static let modelKey = "Org2Workspace.prose.aiRevision.model"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  static func candidates(from destinations: [AIChatDestinationConfiguration]) -> [AIChatDestinationConfiguration] {
    destinations.filter { $0.isEnabled && $0.adapter.isDirectProvider }
  }

  /// The remembered destination if it is still available, otherwise the first.
  func preferredDestination(
    among candidates: [AIChatDestinationConfiguration]
  ) -> AIChatDestinationConfiguration? {
    let stored = defaults.string(forKey: Self.destinationKey)
    return candidates.first { $0.id == stored } ?? candidates.first
  }

  /// The remembered model when it was chosen for this destination, otherwise
  /// the destination's configured model.
  func preferredModel(for destination: AIChatDestinationConfiguration) -> String {
    if defaults.string(forKey: Self.destinationKey) == destination.id,
       let model = defaults.string(forKey: Self.modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !model.isEmpty {
      return model
    }
    return destination.model ?? ""
  }

  func remember(destinationID: String, model: String) {
    defaults.set(destinationID, forKey: Self.destinationKey)
    defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelKey)
  }

  /// Builds a live backend for a configured destination, reading its key from
  /// the Keychain the way AI chat does.
  static func backend(
    for destination: AIChatDestinationConfiguration,
    model: String
  ) throws -> OrgProseRevisionBackend {
    guard destination.adapter.isDirectProvider else { throw OrgProseRevisionError.noProvider }
    let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedModel.isEmpty else { throw AIProviderChatError.modelRequired }
    let token = AIChatDestinationCredentials.readToken(
      destinationID: destination.id,
      allowUserInteraction: true
    )
    let settings = try AIProviderChatSettings(
      adapter: destination.adapter,
      endpoint: destination.endpoint,
      apiKey: token
    )
    return OrgProseRevisionBackend(
      label: destination.title,
      providerKind: destination.adapter.rawValue,
      model: normalizedModel,
      provider: AIProviderChatClient(settings: settings)
    )
  }
}
