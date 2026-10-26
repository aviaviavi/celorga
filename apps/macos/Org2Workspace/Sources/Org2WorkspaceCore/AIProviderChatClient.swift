import Foundation

public struct AIProviderChatSettings: Sendable {
  public let adapter: AIChatDestinationAdapter
  public let baseURL: URL
  public let apiKey: String?

  public init(
    adapter: AIChatDestinationAdapter,
    endpoint: String,
    apiKey: String?
  ) throws {
    guard adapter.isDirectProvider else {
      throw AIProviderChatError.unsupportedAdapter(adapter.rawValue)
    }
    let rawEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedEndpoint = rawEndpoint.isEmpty ? adapter.defaultEndpoint : rawEndpoint
    guard let url = URL(string: resolvedEndpoint),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host != nil
    else {
      throw AIProviderChatError.invalidEndpoint(resolvedEndpoint)
    }
    let normalizedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    if adapter.requiresAPIKey && normalizedKey?.isEmpty != false {
      throw AIProviderChatError.apiKeyRequired(adapter.title)
    }
    self.adapter = adapter
    self.baseURL = url
    self.apiKey = normalizedKey?.isEmpty == false ? normalizedKey : nil
  }
}

public struct AIProviderChatResult: Sendable {
  public let reply: String
  public let usage: AIChatTokenUsage?
  public let contextTelemetry: OpenOrgContextTelemetry

  public init(
    reply: String,
    usage: AIChatTokenUsage?,
    contextTelemetry: OpenOrgContextTelemetry
  ) {
    self.reply = reply
    self.usage = usage
    self.contextTelemetry = contextTelemetry
  }
}

public struct AIProviderChatClient: Sendable {
  public let settings: AIProviderChatSettings
  private let session: URLSession

  public init(settings: AIProviderChatSettings, session: URLSession = .shared) {
    self.settings = settings
    self.session = session
  }

  public func listModels() async throws -> [AIChatModelOption] {
    let component = settings.adapter == .ollama ? "tags" : "models"
    var request = URLRequest(url: endpoint(component))
    request.httpMethod = "GET"
    applyHeaders(to: &request)
    let object = try await send(request)
    let rows: [[String: Any]]
    if settings.adapter == .ollama {
      rows = object["models"] as? [[String: Any]] ?? []
    } else {
      rows = object["data"] as? [[String: Any]] ?? []
    }
    return rows.compactMap { row -> AIChatModelOption? in
      let id = ((row["id"] ?? row["model"] ?? row["name"]) as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !id.isEmpty else { return nil }
      let label = ((row["display_name"] ?? row["name"]) as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return AIChatModelOption(id: id, label: label?.isEmpty == false ? label! : id)
    }.sorted {
      $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
    }
  }

  public func send(
    messages: [AIChatMessage],
    model: String,
    workspaceContext: AIChatWorkspaceContext,
    destinationName: String
  ) async throws -> String {
    try await sendResult(
      messages: messages,
      model: model,
      workspaceContext: workspaceContext,
      destinationName: destinationName
    ).reply
  }

  public func sendResult(
    messages: [AIChatMessage],
    model: String,
    workspaceContext: AIChatWorkspaceContext,
    destinationName: String
  ) async throws -> AIProviderChatResult {
    let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedModel.isEmpty else { throw AIProviderChatError.modelRequired }
    let requestMessages = AIChatContextBudget.boundedHistory(messages)
    try validateAttachments(in: requestMessages)
    let statelessContext = workspaceContext.replacingThreadContinuation(nil)

    let system = """
    You are connected directly to Celorga as \(destinationName). You can discuss the supplied context, but this direct model connection has no tools, filesystem access, or permission to perform side effects. Never claim that you changed a file or external service. When the user asks for an action, explain that they should use a harness destination such as Codex, Claude Code, or OpenClaw.

    \(statelessContext.systemPrompt(runtime: settings.adapter.rawValue, runtimeAgentID: destinationName))
    """

    var request = URLRequest(url: endpoint(chatComponent))
    request.httpMethod = "POST"
    applyHeaders(to: &request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try await Task.detached(priority: .userInitiated) {
      let bodyObject = try self.requestBody(
        messages: requestMessages,
        model: normalizedModel,
        system: system
      )
      return try JSONSerialization.data(withJSONObject: bodyObject)
    }.value
    let object = try await send(request)
    let normalizedReply = try replyText(from: object)
    let roomPrompt = requestMessages.last(where: {
      $0.content.contains("<org2-shared-ai-room>")
    })?.content ?? ""
    return AIProviderChatResult(
      reply: normalizedReply,
      usage: tokenUsage(from: object),
      contextTelemetry: AIChatContextBudget.statelessTelemetry(
        systemPrompt: system,
        history: requestMessages,
        roomPrompt: roomPrompt
      )
    )
  }

  /// One stateless text-in/text-out request: the caller's system prompt and a
  /// single user message, with no workspace context, history, tools, or
  /// attachments.
  public func complete(
    system: String,
    prompt: String,
    model: String,
    maxTokens: Int = 4_096
  ) async throws -> String {
    let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedModel.isEmpty else { throw AIProviderChatError.modelRequired }
    var request = URLRequest(url: endpoint(chatComponent))
    request.httpMethod = "POST"
    applyHeaders(to: &request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let userMessage = AIChatMessage(role: .user, content: prompt)
    var body = try requestBody(messages: [userMessage], model: normalizedModel, system: system)
    if settings.adapter == .anthropic { body["max_tokens"] = maxTokens }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    try Task.checkCancellation()
    return try replyText(from: try await send(request))
  }

  private func replyText(from object: [String: Any]) throws -> String {
    let reply: String?
    switch settings.adapter {
    case .openAI, .openRouter:
      let choices = object["choices"] as? [[String: Any]]
      let message = choices?.first?["message"] as? [String: Any]
      reply = message?["content"] as? String
    case .anthropic:
      let content = object["content"] as? [[String: Any]]
      reply = content?.compactMap { block in
        guard block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
      }.joined(separator: "\n")
    case .ollama:
      reply = (object["message"] as? [String: Any])?["content"] as? String
    case .codexLocal, .claudeLocal, .piLocal, .piRemote,
         .openCodeLocal, .openCodeRemote, .codexRemote, .codexManagedRemote, .openClaw, .openAIDot:
      throw AIProviderChatError.unsupportedAdapter(settings.adapter.rawValue)
    }
    let normalizedReply = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !normalizedReply.isEmpty else { throw AIProviderChatError.emptyResponse }
    return normalizedReply
  }

  private var chatComponent: String {
    switch settings.adapter {
    case .openAI, .openRouter: "chat/completions"
    case .anthropic: "messages"
    case .ollama: "chat"
    case .codexLocal, .claudeLocal, .piLocal, .piRemote,
         .openCodeLocal, .openCodeRemote, .codexRemote, .codexManagedRemote, .openClaw, .openAIDot: ""
    }
  }

  private func endpoint(_ component: String) -> URL {
    settings.baseURL.appendingPathComponent(component)
  }

  private func applyHeaders(to request: inout URLRequest) {
    switch settings.adapter {
    case .openAI:
      request.setValue("Bearer \(settings.apiKey ?? "")", forHTTPHeaderField: "Authorization")
    case .anthropic:
      request.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    case .openRouter:
      request.setValue("Bearer \(settings.apiKey ?? "")", forHTTPHeaderField: "Authorization")
      request.setValue("https://celorga.io", forHTTPHeaderField: "HTTP-Referer")
      request.setValue("Celorga", forHTTPHeaderField: "X-Title")
    case .ollama:
      if let apiKey = settings.apiKey {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      }
    case .codexLocal, .claudeLocal, .piLocal, .piRemote,
         .openCodeLocal, .openCodeRemote, .codexRemote, .codexManagedRemote, .openClaw, .openAIDot:
      break
    }
  }

  private func requestBody(
    messages: [AIChatMessage],
    model: String,
    system: String
  ) throws -> [String: Any] {
    switch settings.adapter {
    case .openAI, .openRouter:
      return [
        "model": model,
        "messages": [["role": "system", "content": system]] + (try messages.map { try openAIMessage($0) }),
        "stream": false,
      ]
    case .anthropic:
      return [
        "model": model,
        "max_tokens": 8_192,
        "system": system,
        "messages": try messages.map { try anthropicMessage($0) },
      ]
    case .ollama:
      return [
        "model": model,
        "messages": [["role": "system", "content": system]] + (try messages.map { try ollamaMessage($0) }),
        "stream": false,
      ]
    case .codexLocal, .claudeLocal, .piLocal, .piRemote,
         .openCodeLocal, .openCodeRemote, .codexRemote, .codexManagedRemote, .openClaw, .openAIDot:
      return [:]
    }
  }

  private func openAIMessage(_ message: AIChatMessage) throws -> [String: Any] {
    let content = attributedContent(message)
    guard !message.attachments.isEmpty else {
      return ["role": providerRole(message.role), "content": content]
    }
    var parts: [[String: Any]] = [["type": "text", "text": content]]
    parts += try message.attachments.map {
      ["type": "image_url", "image_url": ["url": try $0.loadedDataURLString()]]
    }
    return ["role": providerRole(message.role), "content": parts]
  }

  private func anthropicMessage(_ message: AIChatMessage) throws -> [String: Any] {
    var content: [[String: Any]] = [["type": "text", "text": attributedContent(message)]]
    content += try message.attachments.map {
      [
        "type": "image",
        "source": [
          "type": "base64",
          "media_type": $0.mimeType,
          "data": try $0.loadData().base64EncodedString(),
        ],
      ]
    }
    return ["role": providerRole(message.role), "content": content]
  }

  private func ollamaMessage(_ message: AIChatMessage) throws -> [String: Any] {
    var result: [String: Any] = [
      "role": providerRole(message.role),
      "content": attributedContent(message),
    ]
    if !message.attachments.isEmpty {
      result["images"] = try message.attachments.map { try $0.loadData().base64EncodedString() }
    }
    return result
  }

  private func providerRole(_ role: AIChatMessage.Role) -> String {
    role == .assistant ? "assistant" : "user"
  }

  private func attributedContent(_ message: AIChatMessage) -> String {
    guard message.role == .assistant,
          let authorLabel = message.authorLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
          !authorLabel.isEmpty
    else { return message.content }
    return "[\(authorLabel)]\n\(message.content)"
  }

  private func validateAttachments(in messages: [AIChatMessage]) throws {
    if let attachment = messages.flatMap(\.attachments).first(where: {
      !$0.mimeType.lowercased().hasPrefix("image/")
    }) {
      throw AIProviderChatError.unsupportedAttachment(attachment.fileName)
    }
  }

  private func tokenUsage(from object: [String: Any]) -> AIChatTokenUsage? {
    let usage = object["usage"] as? [String: Any]
    let promptDetails = usage?["prompt_tokens_details"] as? [String: Any]
    let input = Self.integer(
      usage?["prompt_tokens"] ?? usage?["input_tokens"] ?? object["prompt_eval_count"]
    )
    let cached = Self.integer(
      promptDetails?["cached_tokens"]
        ?? usage?["cache_read_input_tokens"]
        ?? usage?["cached_input_tokens"]
    )
    let output = Self.integer(
      usage?["completion_tokens"] ?? usage?["output_tokens"] ?? object["eval_count"]
    )
    let total = Self.integer(usage?["total_tokens"])
    guard input != nil || cached != nil || output != nil || total != nil else { return nil }
    return AIChatTokenUsage(
      inputTokens: input ?? 0,
      cachedInputTokens: cached ?? 0,
      outputTokens: output ?? 0,
      totalTokens: total
    )
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private func send(_ request: URLRequest) async throws -> [String: Any] {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw AIProviderChatError.transport(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
      throw AIProviderChatError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let detail = String(data: data.prefix(2_000), encoding: .utf8)
      throw AIProviderChatError.httpStatus(http.statusCode, detail)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AIProviderChatError.invalidResponse
    }
    return object
  }
}

public enum AIProviderChatError: LocalizedError, Equatable {
  case unsupportedAdapter(String)
  case invalidEndpoint(String)
  case apiKeyRequired(String)
  case modelRequired
  case unsupportedAttachment(String)
  case invalidResponse
  case httpStatus(Int, String?)
  case emptyResponse
  case transport(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedAdapter(let adapter):
      "Unsupported direct provider adapter: \(adapter)."
    case .invalidEndpoint(let endpoint):
      "Enter a valid http:// or https:// provider base URL (received \(endpoint))."
    case .apiKeyRequired(let provider):
      "\(provider) requires an API key. Save one in this destination's settings."
    case .modelRequired:
      "Choose a model in this destination's settings before sending."
    case .unsupportedAttachment(let fileName):
      "Direct provider destinations currently support image attachments only (\(fileName) is not an image). Use Codex, Claude Code, or OpenClaw for other files."
    case .invalidResponse:
      "The provider returned an unreadable response."
    case .httpStatus(let status, let detail):
      detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? "The provider returned HTTP \(status): \(detail!)"
        : "The provider returned HTTP \(status)."
    case .emptyResponse:
      "The provider finished without returning a text response."
    case .transport(let detail):
      "Could not reach the provider: \(detail)"
    }
  }
}
