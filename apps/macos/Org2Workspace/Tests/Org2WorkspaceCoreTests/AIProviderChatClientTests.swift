import Foundation
import XCTest
@testable import Org2WorkspaceCore

private final class AIProviderTestURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: ((URLRequest) throws -> (Int, [String: Any]))?

  static func setHandler(_ handler: @escaping (URLRequest) throws -> (Int, [String: Any])) {
    lock.withLock { self.handler = handler }
  }

  static func reset() {
    lock.withLock { handler = nil }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = Self.lock.withLock { Self.handler }
      let (status, object) = try XCTUnwrap(handler)(request)
      let response = try XCTUnwrap(HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      ))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: object))
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

final class AIProviderChatClientTests: XCTestCase {
  override func tearDown() {
    AIProviderTestURLProtocol.reset()
    super.tearDown()
  }

  func testOpenAISendsBearerAuthContextAndImage() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat/completions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
      let body = try self.requestBodyData(request)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(object["model"] as? String, "gpt-test")
      let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.first?["role"] as? String, "system")
      XCTAssertTrue((messages.first?["content"] as? String)?.contains("no tools") == true)
      let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
      XCTAssertEqual(content.last?["type"] as? String, "image_url")
      let imageURL = (content.last?["image_url"] as? [String: Any])?["url"] as? String
      XCTAssertEqual(imageURL, "data:image/png;base64,AQID")
      return (200, ["choices": [["message": ["content": "OpenAI reply"]]]])
    }

    let reply = try await client(.openAI, apiKey: "secret").send(
      messages: [
        AIChatMessage(
          role: .user,
          content: "What is this?",
          attachments: [
            AIChatAttachment(
              fileName: "sample.png",
              mimeType: "image/png",
              data: Data([1, 2, 3])
            )
          ]
        )
      ],
      model: "gpt-test",
      workspaceContext: emptyContext,
      destinationName: "OpenAI"
    )

    XCTAssertEqual(reply, "OpenAI reply")
  }

  func testAnthropicUsesMessagesContractAndAPIKeyHeader() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/messages")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
      XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try self.requestBodyData(request)) as? [String: Any]
      )
      XCTAssertEqual(object["model"] as? String, "claude-test")
      XCTAssertNotNil(object["system"] as? String)
      return (200, ["content": [
        ["type": "text", "text": "First"],
        ["type": "text", "text": "Second"],
      ]])
    }

    let reply = try await client(.anthropic, apiKey: "anthropic-secret").send(
      messages: [AIChatMessage(role: .user, content: "Hello")],
      model: "claude-test",
      workspaceContext: emptyContext,
      destinationName: "Anthropic"
    )

    XCTAssertEqual(reply, "First\nSecond")
  }

  func testAnthropicListsProviderModelCatalog() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/models")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
      XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      return (200, ["data": [
        ["id": "claude-opus-test", "display_name": "Claude Opus"],
        ["id": "claude-haiku-test", "display_name": "Claude Haiku"],
      ]])
    }

    let models = try await client(.anthropic, apiKey: "anthropic-secret").listModels()

    XCTAssertEqual(models.map(\.id), ["claude-haiku-test", "claude-opus-test"])
    XCTAssertEqual(models.map(\.label), ["Claude Haiku", "Claude Opus"])
  }

  func testOpenRouterUsesCompatibleEndpointAndAttributionHeaders() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat/completions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer router-secret")
      XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), "https://celorga.io")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Celorga")
      return (200, ["choices": [["message": ["content": "Router reply"]]]])
    }

    let reply = try await client(.openRouter, apiKey: "router-secret").send(
      messages: [AIChatMessage(role: .user, content: "Hello")],
      model: "vendor/model",
      workspaceContext: emptyContext,
      destinationName: "OpenRouter"
    )

    XCTAssertEqual(reply, "Router reply")
  }

  func testStatelessRequestSendsHistoryOnceAndRecordsUsage() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try self.requestBodyData(request)) as? [String: Any]
      )
      let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
      let system = try XCTUnwrap(messages.first?["content"] as? String)
      XCTAssertFalse(system.contains("history only in continuation"))
      XCTAssertEqual(messages.filter { ($0["role"] as? String) != "system" }.count, 2)
      return (200, [
        "choices": [["message": ["content": "Measured reply"]]],
        "usage": [
          "prompt_tokens": 321,
          "completion_tokens": 19,
          "total_tokens": 340,
          "prompt_tokens_details": ["cached_tokens": 200],
        ],
      ])
    }
    let continuation = AIChatThreadContinuation(
      id: UUID(),
      title: "Duplicate history guard",
      messages: [.init(role: "user", content: "history only in continuation")],
      org2References: []
    )
    let context = AIChatWorkspaceContext(
      localCorpusRoot: nil,
      remoteCorpusRoot: nil,
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: [],
      threadContinuation: continuation
    )
    let result = try await client(.openAI, apiKey: "secret").sendResult(
      messages: [
        AIChatMessage(role: .user, content: "Earlier request"),
        AIChatMessage(role: .assistant, content: "Earlier reply"),
      ],
      model: "gpt-test",
      workspaceContext: context,
      destinationName: "OpenAI"
    )

    XCTAssertEqual(result.usage?.inputTokens, 321)
    XCTAssertEqual(result.usage?.cachedInputTokens, 200)
    XCTAssertEqual(result.usage?.outputTokens, 19)
    XCTAssertEqual(result.contextTelemetry.mode, .stateless)
  }

  func testOllamaUsesLocalChatContractAndListsInstalledModels() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      if request.url?.path.hasSuffix("/tags") == true {
        return (200, ["models": [["name": "gemma:test"], ["model": "llama:test"]]])
      }
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try self.requestBodyData(request)) as? [String: Any]
      )
      XCTAssertEqual(object["stream"] as? Bool, false)
      return (200, ["message": ["content": "Local reply"]])
    }
    let client = try client(.ollama, apiKey: nil)

    let reply = try await client.send(
      messages: [AIChatMessage(role: .user, content: "Hello")],
      model: "gemma:test",
      workspaceContext: emptyContext,
      destinationName: "Ollama"
    )
    let models = try await client.listModels()

    XCTAssertEqual(reply, "Local reply")
    XCTAssertEqual(models.map(\.id), ["gemma:test", "llama:test"])
  }

  func testHostedProviderRequiresAPIKeyWithoutMakingARequest() {
    XCTAssertThrowsError(try AIProviderChatSettings(
      adapter: .openAI,
      endpoint: "https://api.example.test/v1",
      apiKey: nil
    )) { error in
      XCTAssertEqual(error as? AIProviderChatError, .apiKeyRequired("OpenAI API"))
    }
  }

  func testRejectsNonImageAttachmentsBeforeMakingARequest() async throws {
    let client = try client(.ollama, apiKey: nil)
    do {
      _ = try await client.send(
        messages: [
          AIChatMessage(
            role: .user,
            content: "Read this",
            attachments: [
              AIChatAttachment(
                fileName: "report.pdf",
                mimeType: "application/pdf",
                data: Data([1])
              )
            ]
          )
        ],
        model: "gemma:test",
        workspaceContext: emptyContext,
        destinationName: "Ollama"
      )
      XCTFail("Expected a non-image attachment error")
    } catch {
      XCTAssertEqual(error as? AIProviderChatError, .unsupportedAttachment("report.pdf"))
    }
  }

  func testCompleteSendsOnlyTheCallersSystemAndPromptToOpenAI() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/chat/completions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
      let body = try self.requestBodyData(request)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(object["model"] as? String, "gpt-test")
      XCTAssertNil(object["tools"])
      let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.count, 2)
      XCTAssertEqual(messages[0]["role"] as? String, "system")
      XCTAssertEqual(messages[0]["content"] as? String, "Revise only.")
      XCTAssertEqual(messages[1]["role"] as? String, "user")
      XCTAssertEqual(messages[1]["content"] as? String, "Make it tighter: the fox")
      return (200, ["choices": [["message": ["content": "  a fox \n"]]]])
    }
    let reply = try await client(.openAI, apiKey: "synthetic-key").complete(
      system: "Revise only.",
      prompt: "Make it tighter: the fox",
      model: " gpt-test "
    )
    XCTAssertEqual(reply, "a fox")
  }

  func testCompleteUsesAnthropicSystemFieldAndTokenLimit() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/v1/messages")
      let body = try self.requestBodyData(request)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
      XCTAssertEqual(object["system"] as? String, "Revise only.")
      XCTAssertEqual(object["max_tokens"] as? Int, 512)
      let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.count, 1)
      return (200, ["content": [["type": "text", "text": "Revised."]]])
    }
    let reply = try await client(.anthropic, apiKey: "synthetic-key").complete(
      system: "Revise only.",
      prompt: "Passage",
      model: "claude-test",
      maxTokens: 512
    )
    XCTAssertEqual(reply, "Revised.")
  }

  func testCompleteRequiresAModelWithoutMakingARequest() async throws {
    AIProviderTestURLProtocol.setHandler { _ in
      XCTFail("No request expected")
      return (500, [:])
    }
    do {
      _ = try await client(.ollama, apiKey: nil).complete(system: "s", prompt: "p", model: "  ")
      XCTFail("Expected modelRequired")
    } catch {
      XCTAssertEqual(error as? AIProviderChatError, .modelRequired)
    }
  }

  func testDeepSeekPresetUsesOpenAICompatibleContractWithThinkingControls() async throws {
    let destination = AIChatDestinationConfiguration(preset: .deepSeek)
    XCTAssertEqual(destination.adapter, .openAI, "a preset persists as an adapter older builds decode")
    XCTAssertEqual(destination.endpoint, "https://api.deepseek.com")
    XCTAssertEqual(destination.model, "deepseek-flash")
    XCTAssertEqual(destination.providerPreset, .deepSeek)
    XCTAssertEqual(destination.adapterTitle, "DeepSeek")
    XCTAssertTrue(destination.supportsReasoningEffort)
    XCTAssertNil(AIChatDestinationConfiguration(
      name: "OpenAI", mention: "openai", adapter: .openAI, endpoint: "https://api.openai.com/v1"
    ).providerPreset)

    var bodies: [[String: Any]] = []
    let lock = NSLock()
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer deepseek-secret")
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: try self.requestBodyData(request)) as? [String: Any]
      )
      lock.withLock { bodies.append(object) }
      return (200, ["choices": [["message": [
        "reasoning_content": "Thinking it over.",
        "content": "DeepSeek reply",
      ]]]])
    }
    let client = try deepSeekClient()
    for effort in ["max", "off", nil] as [String?] {
      let reply = try await client.send(
        messages: [AIChatMessage(role: .user, content: "Summarize the launch notes.")],
        model: "deepseek-flash",
        workspaceContext: emptyContext,
        destinationName: "DeepSeek",
        reasoningEffort: effort
      )
      XCTAssertEqual(reply, "DeepSeek reply")
    }

    XCTAssertEqual(bodies.count, 3)
    XCTAssertEqual(bodies[0]["model"] as? String, "deepseek-flash")
    XCTAssertEqual((bodies[0]["thinking"] as? [String: String])?["type"], "enabled")
    XCTAssertEqual(bodies[0]["reasoning_effort"] as? String, "max")
    XCTAssertEqual((bodies[1]["thinking"] as? [String: String])?["type"], "disabled")
    XCTAssertNil(bodies[1]["reasoning_effort"])
    XCTAssertNil(bodies[2]["thinking"], "an unset effort keeps the provider default")
    XCTAssertNil(bodies[2]["reasoning_effort"])
  }

  func testDeepSeekPresetListsKnownModelsFirstWithReasoningOptions() async throws {
    AIProviderTestURLProtocol.setHandler { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/models")
      return (200, ["data": [
        ["id": "deepseek-v4-pro"],
        ["id": "deepseek-experimental"],
      ]])
    }
    let discovered = try await deepSeekClient().listModels()
    let models = AIChatProviderPreset.deepSeek.modelOptions(merging: discovered)
    XCTAssertEqual(models.map(\.id), ["deepseek-flash", "deepseek-v4-pro", "deepseek-experimental"])
    XCTAssertEqual(models[0].reasoningOptions.map(\.id), ["off", "low", "high", "max"])
    XCTAssertEqual(
      WorkspaceStore.aiChatRoomReasoningOptions(
        adapter: .openAI, selectedModel: nil, models: [], preset: .deepSeek
      ).map(\.id),
      ["off", "low", "high", "max"]
    )
    XCTAssertTrue(WorkspaceStore.aiChatRoomReasoningOptions(
      adapter: .openAI, selectedModel: nil, models: []
    ).isEmpty, "plain OpenAI-compatible destinations keep no effort control")
    XCTAssertTrue(WorkspaceStore.automationDestinationSupportsReasoning(
      AIChatDestinationConfiguration(preset: .deepSeek)
    ))
  }

  /// Saved destinations decode as one array; a preset must not introduce an
  /// adapter value an older build cannot decode, or that build would fall
  /// back to the default destination list.
  func testDeepSeekDestinationRoundTripsThroughThePersistedAdapter() throws {
    let saved = try JSONEncoder().encode([AIChatDestinationConfiguration(preset: .deepSeek)])
    let json = try XCTUnwrap(String(data: saved, encoding: .utf8))
    XCTAssertTrue(json.contains(#""adapter":"openAI""#), json)
    let restored = try JSONDecoder().decode([AIChatDestinationConfiguration].self, from: saved)
    XCTAssertEqual(restored.first?.providerPreset, .deepSeek)
  }

  private func deepSeekClient() throws -> AIProviderChatClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AIProviderTestURLProtocol.self]
    return AIProviderChatClient(
      settings: try AIProviderChatSettings(
        adapter: .openAI,
        endpoint: AIChatProviderPreset.deepSeek.defaultEndpoint,
        apiKey: "deepseek-secret"
      ),
      session: URLSession(configuration: configuration)
    )
  }

  private func client(
    _ adapter: AIChatDestinationAdapter,
    apiKey: String?
  ) throws -> AIProviderChatClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AIProviderTestURLProtocol.self]
    return AIProviderChatClient(
      settings: try AIProviderChatSettings(
        adapter: adapter,
        endpoint: "https://api.example.test/v1",
        apiKey: apiKey
      ),
      session: URLSession(configuration: configuration)
    )
  }

  private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      if count < 0 { throw try XCTUnwrap(stream.streamError) }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }

  private var emptyContext: AIChatWorkspaceContext {
    AIChatWorkspaceContext(
      localCorpusRoot: nil,
      remoteCorpusRoot: nil,
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: []
    )
  }
}
