import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  func handleCodexWorkspaceChatReadTool(
    _ arguments: JSONValue
  ) async -> CodexDynamicToolResult {
    let values = arguments.objectValue ?? [:]
    let turnID = values["turnId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let threadIDText = values["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let maxMessages = min(100, max(1, Self.codexWorkspaceInteger(values["maxMessages"]) ?? 40))
    guard !turnID.isEmpty, let threadID = UUID(uuidString: threadIDText) else {
      return codexWorkspaceToolFailure(
        code: "INVALID_REQUEST",
        message: "Provide an active turnId and a valid threadId."
      )
    }

    do {
      _ = try aiChatLocalEditCorpus(for: turnID)
      guard let metadata = aiChatThreads.first(where: { $0.id == threadID }) else {
        return codexWorkspaceToolFailure(code: "THREAD_NOT_FOUND", message: "AI chat thread not found.")
      }
      let thread: AIChatThread
      if unloadedAIChatThreadIDs.contains(threadID) {
        let transcriptURL = aiChatTranscriptURL.standardizedFileURL
        guard let loaded = await Task.detached(priority: .utility, operation: {
          AIChatTranscriptStore.shared.loadThread(
            id: threadID,
            metadata: metadata,
            legacyURL: transcriptURL
          )
        }).value else {
          return codexWorkspaceToolFailure(
            code: "THREAD_UNAVAILABLE",
            message: "AI chat thread could not be loaded."
          )
        }
        thread = loaded
      } else {
        thread = metadata
      }
      let aroundMessageID = values["aroundMessageId"]?.stringValue.flatMap(UUID.init(uuidString:))
      return codexWorkspaceToolSuccess(Self.aiChatHistoryReadPayload(
        thread: thread,
        aroundMessageID: aroundMessageID,
        maxMessages: maxMessages
      ))
    } catch {
      return codexWorkspaceToolFailure(
        code: "CHAT_READ_FAILED",
        message: error.localizedDescription
      )
    }
  }

  func authorizedAIChatCorpusRoot(
    turnID: String,
    requestedRoot: String?
  ) throws -> URL {
    let activeRoot = try aiChatLocalEditCorpus(for: turnID)
    guard let requestedRoot = requestedRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
          !requestedRoot.isEmpty
    else { return activeRoot }
    let requestedURL = URL(fileURLWithPath: requestedRoot).standardizedFileURL
    guard aiChatReadCorpusRootsByTurnID[turnID]?.contains(requestedURL.path) == true else {
      throw AIChatLocalEditError.invalidRequest(
        "corpusRoot is not authorized for this chat turn"
      )
    }
    return requestedURL
  }

  nonisolated static func aiChatHistorySearchPayload(
    query: String,
    threads: [AIChatThread],
    limit: Int
  ) -> JSONValue {
    let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { !$0.isEmpty }
    guard !terms.isEmpty else { return .array([]) }
    var matches: [(score: Int, updatedAt: Date, value: JSONValue)] = []
    for thread in threads {
      let title = thread.title.lowercased()
      for message in thread.messages where !message.isRoomDispatchCopy {
        let searchable = "\(thread.title)\n\(message.content)".lowercased()
        guard terms.allSatisfy(searchable.contains) else { continue }
        let titleHits = terms.filter(title.contains).count
        let score = titleHits * 10 + terms.filter(message.content.lowercased().contains).count
        matches.append((score, thread.updatedAt, .object([
          "threadId": .string(thread.id.uuidString.lowercased()),
          "threadTitle": .string(thread.title),
          "messageId": .string(message.id.uuidString.lowercased()),
          "role": .string(message.role.rawValue),
          "createdAt": .string(message.createdAt.ISO8601Format()),
          "snippet": .string(boundedAIChatSearchSnippet(message.content, terms: terms)),
          "citation": .string("org2-chat:\(thread.id.uuidString.lowercased())#\(message.id.uuidString.lowercased())"),
        ])))
      }
    }
    return .array(matches.sorted {
      $0.score != $1.score ? $0.score > $1.score : $0.updatedAt > $1.updatedAt
    }.prefix(max(1, min(20, limit))).map(\.value))
  }

  nonisolated static func aiChatHistoryReadPayload(
    thread: AIChatThread,
    aroundMessageID: UUID?,
    maxMessages: Int
  ) -> JSONValue {
    let visible = thread.messages.filter { !$0.isRoomDispatchCopy }
    let count = max(1, min(100, maxMessages))
    let start: Int
    if let aroundMessageID,
       let index = visible.firstIndex(where: { $0.id == aroundMessageID }) {
      start = max(0, min(index - count / 2, visible.count - count))
    } else {
      start = max(0, visible.count - count)
    }
    let window = visible.dropFirst(start).prefix(count)
    return .object([
      "$schema": .string("org2:ai-chat-context:v1"),
      "threadId": .string(thread.id.uuidString.lowercased()),
      "title": .string(thread.title),
      "runtime": .string(thread.runtime.rawValue),
      "messageCount": .number(Double(visible.count)),
      "windowStart": .number(Double(start)),
      "messages": .array(window.map { message in
        .object([
          "id": .string(message.id.uuidString.lowercased()),
          "role": .string(message.role.rawValue),
          "createdAt": .string(message.createdAt.ISO8601Format()),
          "content": .string(String(message.content.prefix(20_000))),
        ])
      }),
    ])
  }

  nonisolated private static func boundedAIChatSearchSnippet(
    _ content: String,
    terms: [String]
  ) -> String {
    let limit = 700
    guard content.count > limit else { return content }
    let lowercased = content.lowercased()
    let firstRange = terms.compactMap { lowercased.range(of: $0) }.min {
      lowercased.distance(from: lowercased.startIndex, to: $0.lowerBound)
        < lowercased.distance(from: lowercased.startIndex, to: $1.lowerBound)
    }
    guard let firstRange else { return String(content.prefix(limit)) + "…" }
    let offset = lowercased.distance(from: lowercased.startIndex, to: firstRange.lowerBound)
    let startOffset = max(0, offset - limit / 3)
    let start = content.index(content.startIndex, offsetBy: startOffset)
    let end = content.index(start, offsetBy: min(limit, content.distance(from: start, to: content.endIndex)))
    return (startOffset > 0 ? "…" : "") + content[start..<end] + (end < content.endIndex ? "…" : "")
  }

  func codexWorkspaceToolSuccess(_ value: JSONValue) -> CodexDynamicToolResult {
    let text = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
      ?? #"{"ok":true}"#
    return CodexDynamicToolResult(success: true, text: text)
  }

  nonisolated static func codexWorkspaceInteger(_ value: JSONValue?) -> Int? {
    switch value {
    case .integer(let number): Int(exactly: number)
    case .number(let number): Int(exactly: number)
    default: nil
    }
  }

  func codexWorkspaceToolFailure(
    code: String,
    message: String
  ) -> CodexDynamicToolResult {
    let value: JSONValue = .object([
      "error": .object(["code": .string(code), "message": .string(message)])
    ])
    let text = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
      ?? message
    return CodexDynamicToolResult(success: false, text: text)
  }

  func handleCodexThreadPostTool(_ arguments: JSONValue) async -> CodexDynamicToolResult {
    guard let corpusRoot else {
      return CodexDynamicToolResult(success: false, text: "No active Celorga corpus is selected.")
    }
    let values = arguments.objectValue ?? [:]
    let threadID = values["threadId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let message = values["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let author = values["author"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !threadID.isEmpty, !message.isEmpty, !author.isEmpty else {
      return CodexDynamicToolResult(
        success: false,
        text: "threadId, message, and author are required for celorga_thread_post."
      )
    }

    var cliArguments = [
      "thread", "post", threadID,
      "--message", message,
      "--author", author,
      "--dir", corpusRoot.standardizedFileURL.path,
      "--apply",
      "--json",
    ]
    for (name, flag) in [
      ("agentRef", "--agent-ref"),
      ("source", "--source"),
      ("idempotencyKey", "--idempotency-key"),
    ] {
      let value = values[name]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !value.isEmpty { cliArguments.append(contentsOf: [flag, value]) }
    }
    for responder in values["requestTurn"]?.arrayValue ?? [] {
      let value = responder.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !value.isEmpty { cliArguments.append(contentsOf: ["--request-turn", value]) }
    }

    do {
      let output = try await cli.run(cliArguments)
      await drainAIChatInbox()
      return CodexDynamicToolResult(success: true, text: String(decoding: output, as: UTF8.self))
    } catch {
      return CodexDynamicToolResult(success: false, text: error.localizedDescription)
    }
  }

  func handleClaudeCodeEvent(
    _ event: ClaudeCodeEvent,
    threadID: UUID
  ) async {
    guard aiChatThreads.contains(where: { $0.id == threadID }) else { return }
    aiChatLastEventAtByThreadID[threadID] = Date()
    switch event {
    case .sessionStarted(let sessionID):
      openClawGatewayStateByThreadID[threadID] = .connected
      aiChatActiveRunIDByThreadID[threadID] = sessionID
      if selectedAIChatThreadID == threadID,
         canPublishAIChatRuntimeState(for: threadID) {
        aiChatStatusText = "Claude Code is working"
      }
    case .textDelta(let delta):
      aiChatLiveState.noteEvent(for: threadID, coalesced: true)
      aiChatLiveState.appendStreamingDelta(delta, for: threadID)
      if selectedAIChatThreadID == threadID,
         canPublishAIChatRuntimeState(for: threadID) {
        aiChatStatusText = "Claude Code is replying"
      }
    case .activity(let id, let title, let status):
      let activity = AIChatRunActivity(
        id: id,
        runID: aiChatActiveRunIDByThreadID[threadID] ?? "claude-code",
        kind: .tool,
        title: title,
        detail: nil,
        status: status
      )
      var activities = aiChatRunActivitiesByThreadID[threadID] ?? []
      if let index = activities.firstIndex(where: { $0.id == id }) {
        activities[index] = activity
      } else {
        activities.append(activity)
      }
      aiChatRunActivitiesByThreadID[threadID] = Array(activities.suffix(80))
    case .warning(let message):
      openClawGatewayDetailByThreadID[threadID] = message
      if selectedAIChatThreadID == threadID,
         canPublishAIChatRuntimeState(for: threadID) {
        aiChatStatusText = message
      }
    }
  }

  func handlePiAgentEvent(_ event: PiAgentEvent, threadID: UUID) async {
    switch event {
    case .sessionStarted(let sessionID):
      handleCLIChatSessionStarted(sessionID, threadID: threadID, title: "Pi")
    case .textDelta(let delta):
      handleCLIChatTextDelta(delta, threadID: threadID, title: "Pi")
    case .activity(let id, let title, let status):
      handleCLIChatActivity(id: id, title: title, status: status, threadID: threadID, runID: "pi")
    case .warning(let message):
      handleCLIChatWarning(message, threadID: threadID)
    }
  }

  func handleOpenCodeEvent(_ event: OpenCodeEvent, threadID: UUID) async {
    switch event {
    case .processStarted:
      AIChatDispatchTiming.record(
        "opencode process started",
        threadID: threadID,
        sentAt: aiChatDispatchSentAtByThreadID[threadID]
      )
      guard aiChatThreads.contains(where: { $0.id == threadID }) else { return }
      aiChatLastEventAtByThreadID[threadID] = Date()
      openClawGatewayStateByThreadID[threadID] = .connected
      if selectedAIChatThreadID == threadID, canPublishAIChatRuntimeState(for: threadID) {
        aiChatStatusText = "OpenCode is starting"
      }
    case .reasoning(let id, let text):
      guard aiChatThreads.contains(where: { $0.id == threadID }) else { return }
      aiChatLastEventAtByThreadID[threadID] = Date()
      let activity = AIChatRunActivity(
        id: id,
        runID: aiChatActiveRunIDByThreadID[threadID] ?? "opencode",
        kind: .reasoning,
        title: "Thinking",
        detail: text,
        status: .succeeded
      )
      var activities = aiChatRunActivitiesByThreadID[threadID] ?? []
      if let index = activities.firstIndex(where: { $0.id == id }) {
        activities[index] = activity
      } else {
        activities.append(activity)
      }
      aiChatRunActivitiesByThreadID[threadID] = Array(activities.suffix(80))
    case .sessionStarted(let sessionID):
      handleCLIChatSessionStarted(sessionID, threadID: threadID, title: "OpenCode")
    case .textDelta(let delta):
      handleCLIChatTextDelta(delta, threadID: threadID, title: "OpenCode")
    case .activity(let id, let title, let status):
      handleCLIChatActivity(
        id: id,
        title: title,
        status: status,
        threadID: threadID,
        runID: "opencode"
      )
    case .warning(let message):
      handleCLIChatWarning(message, threadID: threadID)
    }
  }

  private func handleCLIChatSessionStarted(
    _ sessionID: String,
    threadID: UUID,
    title: String
  ) {
    AIChatDispatchTiming.record(
      "\(title.lowercased()) first event",
      threadID: threadID,
      sentAt: aiChatDispatchSentAtByThreadID.removeValue(forKey: threadID)
    )
    guard aiChatThreads.contains(where: { $0.id == threadID }) else { return }
    aiChatLastEventAtByThreadID[threadID] = Date()
    openClawGatewayStateByThreadID[threadID] = .connected
    aiChatActiveRunIDByThreadID[threadID] = sessionID
    if selectedAIChatThreadID == threadID, canPublishAIChatRuntimeState(for: threadID) {
      aiChatStatusText = "\(title) is working"
    }
  }

  private func handleCLIChatTextDelta(_ delta: String, threadID: UUID, title: String) {
    guard aiChatThreads.contains(where: { $0.id == threadID }) else { return }
    aiChatLastEventAtByThreadID[threadID] = Date()
    aiChatLiveState.noteEvent(for: threadID, coalesced: true)
    aiChatLiveState.appendStreamingDelta(delta, for: threadID)
    if selectedAIChatThreadID == threadID, canPublishAIChatRuntimeState(for: threadID) {
      aiChatStatusText = "\(title) is replying"
    }
  }

  private func handleCLIChatActivity(
    id: String,
    title: String,
    status: AIChatRunActivity.Status,
    threadID: UUID,
    runID: String
  ) {
    guard aiChatThreads.contains(where: { $0.id == threadID }) else { return }
    aiChatLastEventAtByThreadID[threadID] = Date()
    let activity = AIChatRunActivity(
      id: id,
      runID: aiChatActiveRunIDByThreadID[threadID] ?? runID,
      kind: .tool,
      title: title,
      detail: nil,
      status: status
    )
    var activities = aiChatRunActivitiesByThreadID[threadID] ?? []
    if let index = activities.firstIndex(where: { $0.id == id }) {
      activities[index] = activity
    } else {
      activities.append(activity)
    }
    aiChatRunActivitiesByThreadID[threadID] = Array(activities.suffix(80))
  }

  private func handleCLIChatWarning(_ message: String, threadID: UUID) {
    guard aiChatThreads.contains(where: { $0.id == threadID }) else { return }
    aiChatLastEventAtByThreadID[threadID] = Date()
    openClawGatewayDetailByThreadID[threadID] = message
    if selectedAIChatThreadID == threadID, canPublishAIChatRuntimeState(for: threadID) {
      aiChatStatusText = message
    }
  }

  func handleCodexAppServerEvent(
    _ event: CodexAppServerEvent,
    destinationID: String = AIChatDestinationConfiguration.localCodexID
  ) async {
    let destinationName = aiChatDestination(id: destinationID)?.name ?? "Codex"
    switch event {
    case .connectionChanged(let isConnected, let detail):
      for threadID in aiChatSendingThreadIDs where
        aiChatThreads.first(where: { $0.id == threadID }).map({
          $0.destinationID == destinationID
            || ($0.isSharedRoom && $0.roomDestinationIDs.contains(destinationID))
        }) == true {
        if isConnected {
          // A recovered transport clears the interruption marker; otherwise
          // the rest of a healthy turn reads as "connection interrupted".
          guard openClawGatewayStateByThreadID[threadID] == .disconnected else { continue }
          openClawGatewayStateByThreadID[threadID] = .connected
          openClawGatewayDetailByThreadID[threadID] = destinationName
        } else {
          openClawGatewayStateByThreadID[threadID] = .disconnected
          openClawGatewayDetailByThreadID[threadID] = detail
        }
        aiChatLastEventAtByThreadID[threadID] = Date()
      }
    case .accountUpdated(let authMode, let plan):
      guard destinationID == AIChatDestinationConfiguration.localCodexID else { return }
      if authMode == "chatgpt" {
        let currentEmail: String?
        if case .chatGPT(let email, _) = codexAccountState {
          currentEmail = email
        } else {
          currentEmail = nil
        }
        codexAccountState = .chatGPT(email: currentEmail, plan: plan)
      } else if authMode == "apikey" {
        codexAccountState = .apiKey
      } else if let authMode {
        codexAccountState = .other(authMode)
      } else {
        codexAccountState = .signedOut
      }
    case .loginCompleted(_, let success, let error):
      guard destinationID == AIChatDestinationConfiguration.localCodexID else { return }
      isCodexSigningIn = false
      if success {
        await refreshCodexAccount()
        aiChatStatusText = "Signed in to Codex with ChatGPT"
      } else {
        codexAccountState = .unavailable(error ?? "ChatGPT sign-in failed")
        aiChatStatusText = error ?? "ChatGPT sign-in failed"
      }
    case .turnStarted(let runtimeThreadID, let turnID):
      guard let threadID = localChatThreadID(
        forRuntimeThreadID: runtimeThreadID,
        destinationID: destinationID
      ) else { return }
      let identityKey = "\(destinationID)\u{0}\(runtimeThreadID)"
      let isManagedRemote = aiChatDestination(id: destinationID)?.adapter == .codexManagedRemote
      let identity = isManagedRemote
        ? codexDeliveryIdentityByRuntimeThreadID[identityKey]
        : nil
      if let identity,
         aiChatMessages(for: threadID).contains(where: {
           $0.id == identity.messageID
             && $0.effectiveDeliveryAttemptID == identity.attemptID
         }) {
        codexDeliveryReceiptsByMessageID[identity.messageID] = AIChatDeliveryReceipt(
          state: .started,
          messageID: identity.messageID,
          deliveryAttemptID: identity.attemptID,
          runtimeThreadID: runtimeThreadID,
          turnID: turnID
        )
      }
      if stoppedAIChatThreadIDs.contains(threadID) {
        // Stop can race a successful turn/start response. The local request
        // has already been cleared, so immediately interrupt the late remote
        // turn instead of allowing invisible work to continue.
        if let client = try? codexClient(forDestinationID: destinationID) {
          try? await client.interrupt(threadID: runtimeThreadID, turnID: turnID)
        }
        return
      }
      aiChatLastEventAtByThreadID[threadID] = Date()
      codexActiveTurnsByThreadID[threadID] = (runtimeThreadID, turnID)
      if isManagedRemote, let identity {
        replaceAIChatDeliveryAttempt(
          for: identity.messageID,
          in: threadID,
          attemptID: identity.attemptID,
          status: .sending,
          sendFailure: nil,
          attemptState: .unconfirmed
        )
      }
      openClawGatewayStateByThreadID[threadID] = .connected
      aiChatActiveRunIDByThreadID[threadID] = turnID
      if selectedAIChatThreadID == threadID,
         canPublishAIChatRuntimeState(for: threadID) {
        aiChatStatusText = "\(destinationName) is working"
      }
    case .turnTerminal(let runtimeThreadID, let turnID, let status, let detail):
      guard let threadID = localChatThreadID(
        forRuntimeThreadID: runtimeThreadID,
        destinationID: destinationID
      ) else { return }
      let identityKey = "\(destinationID)\u{0}\(runtimeThreadID)"
      guard let identity = codexDeliveryIdentityByRuntimeThreadID[identityKey],
            aiChatMessages(for: threadID).contains(where: {
              $0.id == identity.messageID
                && $0.effectiveDeliveryAttemptID == identity.attemptID
            })
      else { return }
      let receiptState: AIChatDeliveryReceipt.State
      switch status {
      case .completed: receiptState = .completed
      case .failed: receiptState = .failed
      case .interrupted: receiptState = .interrupted
      case .unknown: return
      }
      codexDeliveryReceiptsByMessageID[identity.messageID] = AIChatDeliveryReceipt(
        state: receiptState,
        messageID: identity.messageID,
        deliveryAttemptID: identity.attemptID,
        runtimeThreadID: runtimeThreadID,
        turnID: turnID,
        detail: detail
      )
      codexDeliveryIdentityByRuntimeThreadID.removeValue(forKey: identityKey)
    case .agentMessageDelta(let runtimeThreadID, _, let itemID, let delta):
      guard let threadID = localChatThreadID(
        forRuntimeThreadID: runtimeThreadID,
        destinationID: destinationID
      ) else { return }
      aiChatLiveState.noteEvent(for: threadID, coalesced: true)
      let previousItemID = codexStreamingItemIDByThreadID[threadID]
      let appendableDelta = CodexStreamingText.deltaWithItemBoundary(
        delta,
        itemID: itemID,
        after: previousItemID,
        hasExistingText: previousItemID != nil
      )
      aiChatLiveState.appendStreamingDelta(appendableDelta, for: threadID)
      codexStreamingItemIDByThreadID[threadID] = itemID
      if selectedAIChatThreadID == threadID,
         canPublishAIChatRuntimeState(for: threadID) {
        let nextStatus = "\(destinationName) is replying"
        if aiChatStatusText != nextStatus {
          aiChatStatusText = nextStatus
        }
      }
    case .reasoningDelta(let runtimeThreadID, _, let delta):
      guard let threadID = localChatThreadID(
        forRuntimeThreadID: runtimeThreadID,
        destinationID: destinationID
      ) else { return }
      aiChatLiveState.noteEvent(for: threadID, coalesced: true)
      aiChatLiveState.appendReasoningDelta(delta, for: threadID)
    case .activity(
      let runtimeThreadID,
      let turnID,
      let itemID,
      let title,
      let detail,
      let status
    ):
      guard let threadID = localChatThreadID(
        forRuntimeThreadID: runtimeThreadID,
        destinationID: destinationID
      ) else { return }
      aiChatLastEventAtByThreadID[threadID] = Date()
      let activity = AIChatRunActivity(
        id: itemID,
        runID: turnID,
        kind: .tool,
        title: title,
        detail: detail,
        status: status
      )
      var activities = aiChatRunActivitiesByThreadID[threadID] ?? []
      if let index = activities.firstIndex(where: { $0.id == itemID }) {
        activities[index] = activity
      } else {
        activities.append(activity)
      }
      aiChatRunActivitiesByThreadID[threadID] = Array(activities.suffix(80))
    case .contextCompacted(let runtimeThreadID, _):
      guard let threadID = localChatThreadID(
        forRuntimeThreadID: runtimeThreadID,
        destinationID: destinationID
      ) else { return }
      requirePersistentContextRecovery(
        threadID: threadID,
        destinationID: destinationID,
        transcriptURL: aiChatSendOriginsByThreadID[threadID]?.transcriptURL
          ?? aiChatTranscriptURL
      )
    case .warning(let runtimeThreadID, let message):
      if let runtimeThreadID,
         let threadID = localChatThreadID(
           forRuntimeThreadID: runtimeThreadID,
           destinationID: destinationID
         ) {
        aiChatLastEventAtByThreadID[threadID] = Date()
        openClawGatewayDetailByThreadID[threadID] = message
        if selectedAIChatThreadID == threadID,
           canPublishAIChatRuntimeState(for: threadID) {
          aiChatStatusText = message
        }
      }
    }
  }

  private func localChatThreadID(
    forRuntimeThreadID runtimeThreadID: String,
    destinationID: String = AIChatDestinationConfiguration.localCodexID
  ) -> UUID? {
    codexLocalThreadIDsByRuntimeThreadID["\(destinationID)\u{0}\(runtimeThreadID)"]
      ?? aiChatThreads.first {
      ($0.runtime == .codex || $0.isSharedRoom)
        && $0.runtimeThreadID(forDestinationID: destinationID) == runtimeThreadID
    }?.id
  }

  func sendAIChatRequest(
    messages: [AIChatMessage],
    sessionKey: String,
    threadID: UUID,
    destinationID: String,
    localEditTurnID: String?,
    sendOrigin: AIChatSendOrigin
  ) async throws -> String {
    guard let destination = aiChatDestination(id: destinationID),
          destination.runtime == .openClaw
    else {
      throw OpenClawGatewayError.protocolFailure("the configured destination is not an OpenClaw target")
    }
    let configuredAgentID = destination.agentID.trimmingCharacters(in: .whitespacesAndNewlines)
    let agentID = OpenClawChatClient.openClawAgentHeaderValue(
      for: configuredAgentID.isEmpty ? openClawAgentID : configuredAgentID
    )
    let threadConfiguration = aiChatThread(
      threadID,
      transcriptURL: sendOrigin.transcriptURL
    )
    let workspaceContext = workspaceContext(
      sendOrigin.workspaceContext,
      localEditTurnID: localEditTurnID
    ).replacingThreadContinuation(nil)
    resetAIChatTurnTelemetry(
      threadID: threadID,
      destinationID: destinationID,
      transcriptURL: sendOrigin.transcriptURL
    )
    let expandedMessages = messages.map {
      Self.expandingOpenClawAgentCommand($0, corpusSkills: corpusAgentSkillCommands)
    }
    guard let originalUserMessage = expandedMessages.last(where: { $0.role == .user }) else {
      throw OpenClawGatewayError.protocolFailure("no user message was available")
    }
    let requestMessages = threadConfiguration?.isSharedRoom == true
      ? Self.sharedRoomRequestMessages(
          expandedMessages,
          targetDestinationName: destination.name,
          targetDestinationID: destinationID,
          destinationNamesByID: Dictionary(
            uniqueKeysWithValues: enabledAIChatDestinations.map { ($0.id, $0.name) }
          ),
          handoffMentions: threadConfiguration.map {
            aiChatRoomHandoffMentions(in: $0, excluding: destinationID)
          } ?? [],
          agentTurnLimit: threadConfiguration.map(aiChatRoomAgentTurnLimit(for:))
            ?? aiChatDefaultRoomAgentTurnLimit,
          through: originalUserMessage.id
        )
      : expandedMessages
    let latestUserMessage = requestMessages.last(where: { $0.id == originalUserMessage.id })
      ?? originalUserMessage
    let isGatewayCommand = AIChatSlashCommands.isGatewayCommand(
      latestUserMessage.content,
      gatewayCommands: openClawGatewayCommands,
      corpusSkills: corpusAgentSkillCommands
    )
    let selectedModel = threadConfiguration?.model(forDestinationID: destinationID)
    let selectedReasoningEffort = threadConfiguration?.reasoningEffort(forDestinationID: destinationID)
    if let aiChatSendHandler {
      let handlerContext = threadConfiguration.map {
        workspaceContext.replacingThreadContinuation(
          aiChatThreadContinuation(
            for: $0,
            excludingMessageID: originalUserMessage.id
          )
        )
      } ?? workspaceContext
      return try await aiChatSendHandler(requestMessages, agentID, sessionKey, handlerContext)
    }
    let contextDelivery = isGatewayCommand ? nil : persistentContextEnvelope(
      threadID: threadID,
      destinationID: destinationID,
      runtimeSessionID: sessionKey,
      transcriptURL: sendOrigin.transcriptURL,
      fullPrompt: { [self] requiresRecovery in
        let promptContext = requiresRecovery && threadConfiguration?.isSharedRoom != true
          ? workspaceContext.replacingThreadContinuation(
              threadConfiguration.map {
                aiChatThreadContinuation(
                  for: $0,
                  excludingMessageID: originalUserMessage.id
                )
              }
            )
          : workspaceContext
        return promptContext.systemPrompt(
          runtime: "openclaw",
          runtimeAgentID: agentID
        )
      },
      includesTranscript: threadConfiguration?.isSharedRoom != true,
      roomPrompt: threadConfiguration?.isSharedRoom == true ? latestUserMessage.content : "",
      attachments: latestUserMessage.attachments
    )
    let settings = openClawSettings(
      forDestinationID: destinationID,
      allowKeychainRead: true
    )
    let gateway = OpenClawGatewayClient(settings: settings)
    openClawGatewayClientsByThreadID[threadID] = gateway
    prepareAIChatRunPresentation(for: threadID)
    defer {
      openClawGatewayClientsByThreadID.removeValue(forKey: threadID)
      Task { await gateway.shutdown() }
    }

    let gatewayMessage = Self.openClawGatewayMessage(
      userMessage: latestUserMessage.content,
      workspacePrompt: contextDelivery?.envelope.prompt,
      isGatewayCommand: isGatewayCommand
    )
    let pendingTurn = AIChatPendingTurn(
      userMessageID: latestUserMessage.id,
      runID: latestUserMessage.id.uuidString.lowercased(),
      idempotencyKey: latestUserMessage.id.uuidString.lowercased(),
      dispatchOwnerID: Self.aiChatDispatchOwnerID,
      agentID: agentID,
      destinationID: destinationID,
      gatewayMessage: gatewayMessage,
      contextSectionFingerprints: contextDelivery?.envelope.sectionSnapshot
    )
    replaceAIChatPendingTurn(
      pendingTurn,
      in: threadID,
      transcriptURL: sendOrigin.transcriptURL,
      shouldPersist: true
    )
    guard await persistAIChatTranscriptDurably(context: sendOrigin.context) else {
      clearAIChatPendingTurn(
        pendingTurn.runID,
        in: threadID,
        transcriptURL: sendOrigin.transcriptURL,
        shouldPersist: false
      )
      throw OpenClawGatewayError.protocolFailure(
        "the pending turn could not be saved before dispatch"
      )
    }
    aiChatActiveRunIDByThreadID[threadID] = pendingTurn.runID

    do {
      let reply = try await gateway.send(
        message: gatewayMessage,
        attachments: latestUserMessage.attachments,
        agentID: agentID,
        sessionKey: sessionKey,
        model: selectedModel,
        reasoningEffort: selectedReasoningEffort,
        idempotencyKey: pendingTurn.runID,
        requestStartedAt: pendingTurn.startedAt
      ) { [weak self] event in
        await self?.handleOpenClawGatewayEventDurably(
          event,
          threadID: threadID,
          destinationID: destinationID,
          expectedUserMessageID: pendingTurn.userMessageID
        )
      }
      if let contextDelivery {
        commitPersistentContext(contextDelivery.envelope, for: contextDelivery.key)
      }
      return reply
    } catch let error as OpenClawGatewayError where automationRunIDsByThreadID[threadID] == nil
      && Self.shouldRetryAIChatWithDefaults(
      after: error,
      model: selectedModel,
      reasoningEffort: selectedReasoningEffort
    ) {
      let notice = clearRejectedAIChatConfiguration(
        for: threadID,
        destinationID: destinationID,
        transcriptURL: sendOrigin.transcriptURL,
        model: selectedModel,
        reasoningEffort: selectedReasoningEffort
      )
      aiChatConfigurationFallbackNoticesByThreadID[threadID] = notice
      openClawGatewayDetailByThreadID[threadID] = notice
      if isActiveAIChatSendOrigin(sendOrigin) {
        aiChatStatusText = "Saved AI settings unavailable; retrying with defaults"
      }
      do {
        let reply = try await gateway.send(
          message: gatewayMessage,
          attachments: latestUserMessage.attachments,
          agentID: agentID,
          sessionKey: sessionKey,
          model: nil,
          reasoningEffort: nil,
          idempotencyKey: pendingTurn.runID,
          requestStartedAt: pendingTurn.startedAt
        ) { [weak self] event in
          await self?.handleOpenClawGatewayEventDurably(
            event,
            threadID: threadID,
            destinationID: destinationID,
            expectedUserMessageID: pendingTurn.userMessageID
          )
        }
        if let contextDelivery {
          commitPersistentContext(contextDelivery.envelope, for: contextDelivery.key)
        }
        return reply
      } catch {
        aiChatConfigurationFallbackNoticesByThreadID.removeValue(forKey: threadID)
        if !Self.aiChatRunMayStillBeWorking(after: error) {
          clearAIChatPendingTurn(
            pendingTurn.runID,
            in: threadID,
            transcriptURL: sendOrigin.transcriptURL,
            shouldPersist: true
          )
        }
        throw error
      }
    } catch let error as OpenClawGatewayError where error.permitsHTTPFallback {
      clearAIChatPendingTurn(
        pendingTurn.runID,
        in: threadID,
        transcriptURL: sendOrigin.transcriptURL,
        shouldPersist: true
      )
      let requiresLiveGateway = selectedModel != nil || selectedReasoningEffort != nil
        || isGatewayCommand
        || latestUserMessage.attachments.contains(where: { !$0.mimeType.hasPrefix("image/") })
      if requiresLiveGateway, case .connection = error {
        // The client already retried; chat.send never left this host. Say so plainly
        // instead of blaming the thread's model setting.
        openClawGatewayStateByThreadID[threadID] = .disconnected
        openClawGatewayDetailByThreadID[threadID] = error.localizedDescription
        throw OpenClawGatewayError.gateway(
          code: "LIVE_GATEWAY_UNREACHABLE",
          message: Self.openClawNotSentMessage(error)
        )
      }
      if selectedModel != nil || selectedReasoningEffort != nil {
        openClawGatewayStateByThreadID[threadID] = .disconnected
        openClawGatewayDetailByThreadID[threadID] = error.localizedDescription
        throw OpenClawGatewayError.gateway(
          code: "LIVE_GATEWAY_REQUIRED",
          message: "Model and reasoning overrides require the live OpenClaw Gateway. \(error.localizedDescription)"
        )
      }
      if isGatewayCommand {
        openClawGatewayStateByThreadID[threadID] = .disconnected
        openClawGatewayDetailByThreadID[threadID] = error.localizedDescription
        throw OpenClawGatewayError.gateway(
          code: "LIVE_GATEWAY_REQUIRED",
          message: "OpenClaw slash commands require the live Gateway. \(error.localizedDescription)"
        )
      }
      if latestUserMessage.attachments.contains(where: { !$0.mimeType.hasPrefix("image/") }) {
        openClawGatewayStateByThreadID[threadID] = .disconnected
        openClawGatewayDetailByThreadID[threadID] = error.localizedDescription
        throw OpenClawGatewayError.gateway(
          code: "LIVE_GATEWAY_REQUIRED",
          message: "File attachments require the live OpenClaw Gateway. \(error.localizedDescription)"
        )
      }
      openClawGatewayStateByThreadID[threadID] = .fallbackHTTP
      openClawGatewayDetailByThreadID[threadID] = error.localizedDescription
      aiChatLiveState.removeStreamingReply(for: threadID)
      aiChatLiveState.removeReasoning(for: threadID)
      aiChatRunActivitiesByThreadID[threadID] = []
      if isActiveAIChatSendOrigin(sendOrigin) {
        aiChatStatusText = "Using HTTP compatibility for this turn"
      }
      resetAIChatTurnTelemetry(
        threadID: threadID,
        destinationID: destinationID,
        transcriptURL: sendOrigin.transcriptURL
      )
      let client = OpenClawChatClient(settings: settings)
      let fallbackMessages = threadConfiguration?.isSharedRoom == true
        ? requestMessages.filter { $0.id == originalUserMessage.id }
        : requestMessages
      let result = try await client.sendResult(
        messages: fallbackMessages,
        agentID: agentID,
        sessionKey: sessionKey,
        workspaceContext: sendOrigin.workspaceContext
      )
      let telemetryKey = aiChatDestinationTurnKey(
        threadID: threadID,
        destinationID: destinationID,
        transcriptURL: sendOrigin.transcriptURL
      )
      aiChatContextByDestinationTurn[telemetryKey] = result.contextTelemetry
      if let usage = result.usage { aiChatUsageByDestinationTurn[telemetryKey] = usage }
      return result.reply
    } catch {
      if !Self.aiChatRunMayStillBeWorking(after: error) {
        clearAIChatPendingTurn(
          pendingTurn.runID,
          in: threadID,
          transcriptURL: sendOrigin.transcriptURL,
          shouldPersist: true
        )
      }
      throw error
    }
  }

  nonisolated static func openCodeRunMayStillBeWorking(after error: Error) -> Bool {
    guard let error = error as? OpenCodeError, case .connectionLost = error else { return false }
    return true
  }

  /// Destinations whose saved pending turn can be resumed after a restart.
  nonisolated static func aiChatAdapterRecoversPendingTurns(
    _ adapter: AIChatDestinationAdapter?
  ) -> Bool {
    adapter == .openClaw || adapter == .openCodeRemote
  }

  nonisolated private static func aiChatRunMayStillBeWorking(after error: Error) -> Bool {
    guard let gatewayError = error as? OpenClawGatewayError else { return false }
    if case .acceptedRunRecovery = gatewayError { return true }
    return false
  }

  nonisolated static func aiChatRunWasStopped(after error: Error) -> Bool {
    guard let gatewayError = error as? OpenClawGatewayError else { return false }
    if case .aborted = gatewayError { return true }
    return false
  }

  nonisolated static func shouldRetryAIChatWithDefaults(
    after error: Error,
    model: String?,
    reasoningEffort: String?
  ) -> Bool {
    guard model != nil || reasoningEffort != nil,
          let gatewayError = error as? OpenClawGatewayError,
          case .sessionConfigurationRejected = gatewayError
    else {
      return false
    }
    return true
  }

  private func clearRejectedAIChatConfiguration(
    for threadID: UUID,
    destinationID: String,
    transcriptURL: URL,
    model: String?,
    reasoningEffort: String?
  ) -> String {
    if let thread = aiChatThread(threadID, transcriptURL: transcriptURL) {
      let replacement: AIChatThread
      if thread.isSharedRoom {
        var modelsByDestination = thread.roomModelsByDestination
        modelsByDestination.removeValue(forKey: destinationID)
        var effortsByDestination = thread.roomReasoningEffortsByDestination
        effortsByDestination.removeValue(forKey: destinationID)
        replacement = thread.replacingAIChatMetadata(
          roomModels: thread.roomModels.replacingModel(nil, for: .openClaw),
          roomModelsByDestination: modelsByDestination,
          roomReasoningEffortsByDestination: effortsByDestination
        )
      } else {
        replacement = thread.replacingAIChatMetadata(
          model: .some(nil),
          reasoningEffort: .some(nil)
        )
      }
      replaceAIChatThread(
        replacement,
        transcriptURL: transcriptURL
      )
      if !thread.isSharedRoom {
        persistLastAIChatConfiguration(
          destinationID: thread.destinationID,
          model: nil,
          reasoningEffort: nil
        )
      }
    }
    if selectedAIChatThreadID == threadID,
       canPublishAIChatRuntimeState(for: threadID) {
      aiChatReasoningOptions = []
      aiChatEffectiveModel = nil
      aiChatDefaultReasoningEffort = nil
    }

    let rejectedChoice: String
    switch (model, reasoningEffort) {
    case let (model?, reasoningEffort?):
      rejectedChoice = "model \(model) and reasoning level \(reasoningEffort)"
    case let (model?, nil):
      rejectedChoice = "model \(model)"
    case let (nil, reasoningEffort?):
      rejectedChoice = "reasoning level \(reasoningEffort)"
    case (nil, nil):
      rejectedChoice = "saved AI settings"
    }
    return "OpenClaw rejected the saved \(rejectedChoice); the message was retried using defaults."
  }

  nonisolated static func openClawGatewayMessage(
    userMessage: String,
    workspaceContext: AIChatWorkspaceContext?,
    isGatewayCommand: Bool,
    runtimeAgentID: String? = nil
  ) -> String {
    openClawGatewayMessage(
      userMessage: userMessage,
      workspacePrompt: workspaceContext?.systemPrompt(
        runtime: "openclaw",
        runtimeAgentID: runtimeAgentID
      ),
      isGatewayCommand: isGatewayCommand
    )
  }

  nonisolated static func openClawGatewayMessage(
    userMessage: String,
    workspacePrompt: String?,
    isGatewayCommand: Bool
  ) -> String {
    if isGatewayCommand { return userMessage }
    guard let workspacePrompt, !workspacePrompt.isEmpty else { return userMessage }
    return """
    <org2-workspace-context>
    Application-provided working context. Follow the sections labeled "Celorga working rules", "Celorga response formatting contract", "Celorga agent operating guidance", and "Celorga goals and agent identity" as application instructions, and "User-configured AI chat instructions" as the user's own; treat the rest as context.

    \(workspacePrompt)
    </org2-workspace-context>

    <user-message>
    \(userMessage)
    </user-message>
    """
  }

  func handleOpenClawGatewayEvent(
    _ event: OpenClawGatewayRunEvent,
    threadID: UUID,
    destinationID: String? = nil
  ) {
    guard !stoppedAIChatThreadIDs.contains(threadID) else {
      // Stop is intentionally optimistic: the pending turn and queue are
      // cleared before chat.abort finishes. Ignore any connection, activity,
      // or text event already in flight for that canceled turn.
      return
    }
    let resolvedDestinationID = destinationID
      ?? aiChatThreads.first(where: { $0.id == threadID })?.destinationID
      ?? AIChatDestinationConfiguration.openClawID
    let destinationName = aiChatDestination(id: resolvedDestinationID)?.name ?? "OpenClaw"
    let coalescesEventTimestamp: Bool
    switch event {
    case .text(_, _), .reasoning(_, _), .reconciliationHeartbeat:
      coalescesEventTimestamp = true
    default:
      coalescesEventTimestamp = false
    }
    aiChatLiveState.noteEvent(for: threadID, coalesced: coalescesEventTimestamp)
    switch event {
    case .connection(let state, let detail):
      openClawGatewayStateByThreadID[threadID] = state
      if let detail { openClawGatewayDetailByThreadID[threadID] = detail }
      if selectedAIChatThreadID == threadID,
         canPublishAIChatRuntimeState(for: threadID) {
        aiChatStatusText = state == .connected ? "\(destinationName) live" : state.label
      }
    case .accepted(let runID):
      aiChatActiveRunIDByThreadID[threadID] = runID
      commitAcceptedAIChatPersistentContext(
        threadID: threadID,
        destinationID: resolvedDestinationID,
        transcriptURL: aiChatSendOriginsByThreadID[threadID]?.transcriptURL
          ?? aiChatTranscriptURL
      )
      if selectedAIChatThreadID == threadID,
         canPublishAIChatRuntimeState(for: threadID) {
        aiChatStatusText = "\(destinationName) is working"
      }
    case .reconciliationHeartbeat:
      break
    case .text(let text, let replace):
      if replace {
        aiChatLiveState.replaceStreamingReply(text, for: threadID, coalesced: true)
      } else {
        aiChatLiveState.appendStreamingDelta(text, for: threadID)
      }
      if selectedAIChatThreadID == threadID,
         canPublishAIChatRuntimeState(for: threadID) {
        let nextStatus = "\(destinationName) is replying"
        if aiChatStatusText != nextStatus {
          aiChatStatusText = nextStatus
        }
      }
    case .reasoning(let text, let replace):
      if replace {
        aiChatLiveState.replaceReasoning(text, for: threadID, coalesced: true)
      } else {
        aiChatLiveState.appendReasoningDelta(text, for: threadID)
      }
    case .activity(let activity):
      var activities = aiChatRunActivitiesByThreadID[threadID] ?? []
      if let index = activities.firstIndex(where: { $0.id == activity.id }) {
        activities[index] = AIChatActivityFeed.merging(activities[index], with: activity)
      } else {
        activities.append(activity)
      }
      aiChatRunActivitiesByThreadID[threadID] = Array(activities.suffix(80))
      if selectedAIChatThreadID == threadID,
         canPublishAIChatRuntimeState(for: threadID),
         activity.status == .running {
        aiChatStatusText = activity.title
      }
    case .usage(let usage):
      aiChatUsageByDestinationTurn[
        aiChatDestinationTurnKey(
          threadID: threadID,
          destinationID: resolvedDestinationID,
          transcriptURL: aiChatSendOriginsByThreadID[threadID]?.transcriptURL
            ?? aiChatTranscriptURL
        )
      ] = usage
    case .contextCompacted:
      requirePersistentContextRecovery(
        threadID: threadID,
        destinationID: resolvedDestinationID,
        transcriptURL: aiChatSendOriginsByThreadID[threadID]?.transcriptURL
          ?? aiChatTranscriptURL
      )
    }
  }

  func handleOpenClawGatewayEventDurably(
    _ event: OpenClawGatewayRunEvent,
    threadID: UUID,
    destinationID: String,
    expectedUserMessageID: UUID
  ) async {
    guard let currentPendingTurn = aiChatThread(
      threadID,
      transcriptURL: aiChatSendOriginsByThreadID[threadID]?.transcriptURL
        ?? aiChatTranscriptURL
    )?.pendingTurn,
          currentPendingTurn.userMessageID == expectedUserMessageID
    else {
      // A delayed callback from a stopped or superseded run must never mutate
      // the next run's context, trace, or streaming presentation.
      return
    }

    if case .accepted(let acceptedRunID) = event,
       currentPendingTurn.runID != acceptedRunID {
      let transcriptURL = aiChatSendOriginsByThreadID[threadID]?.transcriptURL
        ?? aiChatTranscriptURL
      replaceAIChatPendingTurn(
        currentPendingTurn.replacingAcceptedRunID(acceptedRunID),
        in: threadID,
        transcriptURL: transcriptURL,
        shouldPersist: true
      )
      let context = aiChatSendOriginsByThreadID[threadID]?.context
        ?? captureAIChatCorpusContext()
      guard await persistAIChatTranscriptDurably(context: context) else {
        openClawGatewayDetailByThreadID[threadID] =
          "The accepted run identifier could not be saved for crash recovery."
        return
      }
    }
    handleOpenClawGatewayEvent(
      event,
      threadID: threadID,
      destinationID: destinationID
    )
  }

  func prepareAIChatRunPresentation(for threadID: UUID) {
    openClawGatewayStateByThreadID[threadID] = .connecting
    openClawGatewayDetailByThreadID.removeValue(forKey: threadID)
    clearAIChatCompletedRunPresentation(for: threadID)
    aiChatLastEventAtByThreadID[threadID] = Date()
  }

  func clearAIChatCompletedRunPresentation(for threadID: UUID) {
    aiChatActiveRunIDByThreadID.removeValue(forKey: threadID)
    aiChatLastEventAtByThreadID.removeValue(forKey: threadID)
    aiChatLiveState.removeStreamingReply(for: threadID)
    codexStreamingItemIDByThreadID.removeValue(forKey: threadID)
    aiChatLiveState.removeReasoning(for: threadID)
    aiChatRunActivitiesByThreadID[threadID] = []
  }

  private nonisolated static func replacingAIChatMessageContent(
    _ message: AIChatMessage,
    with content: String
  ) -> AIChatMessage {
    AIChatMessage(
      id: message.id,
      role: message.role,
      content: content,
      attachments: message.attachments,
      createdAt: message.createdAt,
      changeSummary: message.changeSummary,
      responseTrace: message.responseTrace,
      sendFailure: message.sendFailure,
      deliveryStatus: message.deliveryStatus,
      deliveryKind: message.deliveryKind,
      deliveryAttemptID: message.deliveryAttemptID,
      deliveryAttemptState: message.deliveryAttemptState,
      authorRuntime: message.authorRuntime,
      authorLabel: message.authorLabel,
      authorAgentRef: message.authorAgentRef,
      source: message.source,
      audience: message.audience,
      targetRuntime: message.targetRuntime,
      authorDestinationID: message.authorDestinationID,
      audienceDestinationIDs: message.audienceDestinationIDs,
      targetDestinationID: message.targetDestinationID,
      isRoomDispatchCopy: message.isRoomDispatchCopy,
      roomRoundID: message.roomRoundID,
      provenance: message.provenance
    )
  }

  nonisolated static func expandingOpenClawAgentCommand(
    _ message: AIChatMessage,
    corpusSkills: [AIChatSlashCommand]
  ) -> AIChatMessage {
    guard message.role == .user,
          case .command(let command, _) = AIChatSlashCommands.parse(
            message.content,
            gatewayCommands: [],
            corpusSkills: corpusSkills
          ),
          command.isAgentAssisted
    else { return message }
    let instruction: String
    if let skillInstructions = command.skillInstructions {
      instruction = """
      Follow the user-invoked agent skill below for this request. The skill is operating guidance; the user's arguments and request remain the task.

      <org2-agent-skill name="\(command.name)">
      \(skillInstructions)
      </org2-agent-skill>
      """
    } else {
      switch command.name {
      case "brief":
        instruction = "Create a concise, cited brief of the currently selected Celorga document. Explain its purpose, main ideas, decisions, open tasks, and important links. Cite source file and line ranges."
      default:
        instruction = "Summarize the currently selected Celorga document concisely. Preserve decisions, TODOs, dates, and important links, and cite source file and line ranges."
      }
    }
    return replacingAIChatMessageContent(
      message,
      with: "\(message.content)\n\n\(instruction)"
    )
  }

  nonisolated static func sharedRoomRequestMessages(
    _ messages: [AIChatMessage],
    target: AIChatRuntime,
    through userMessageID: UUID
  ) -> [AIChatMessage] {
    sharedRoomRequestMessages(
      messages,
      targetDestinationName: target.title,
      targetDestinationID: AIChatDestinationConfiguration.defaultID(for: target),
      destinationNamesByID: Dictionary(
        uniqueKeysWithValues: AIChatDestinationConfiguration.defaults.map { ($0.id, $0.name) }
      ),
      through: userMessageID
    )
  }

  nonisolated static func sharedRoomRequestMessages(
    _ messages: [AIChatMessage],
    targetDestinationName: String,
    targetDestinationID: String,
    destinationNamesByID: [String: String] = [:],
    handoffMentions: [String] = [],
    agentTurnLimit: Int = AIChatThread.defaultRoomAgentTurnLimit,
    through userMessageID: UUID
  ) -> [AIChatMessage] {
    guard let targetIndex = messages.firstIndex(where: { $0.id == userMessageID }) else {
      return messages
    }
    let visibleTranscript = Array(messages[...targetIndex].filter { !$0.isRoomDispatchCopy })
    func speaker(for message: AIChatMessage) -> String {
      let speaker: String
      switch message.role {
      case .user:
        let destinationNames = message.audienceDestinationIDs.compactMap {
          destinationNamesByID[$0]
        }
        let audienceTitle = destinationNames.isEmpty
          ? (message.audience?.title ?? "room")
          : destinationNames.joined(separator: " + ")
        let requester = message.provenance?.requestedByLabel ?? "Avi"
        speaker = "\(requester) → \(audienceTitle)"
      case .assistant:
        speaker = message.authorLabel
          ?? message.authorDestinationID.flatMap { destinationNamesByID[$0] }
          ?? message.authorRuntime?.title
          ?? "Assistant"
      case .system:
        speaker = "Celorga"
      }
      return speaker
    }
    func row(for message: AIChatMessage, compact: Bool = false) -> String? {
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !content.isEmpty else { return nil }
      let row = "\(speaker(for: message)):\n\(content)"
      guard compact else { return row }
      let flattened = row
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      return String(flattened.prefix(320))
    }
    let currentMessage = messages[targetIndex]
    let currentContent = currentMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentRequest = "\(speaker(for: currentMessage)):\n\(currentContent.isEmpty ? "[Attachment-only request]" : currentContent)"
    // A requested turn carries the requesting message verbatim as its
    // current request; do not repeat it in the history.
    let requestingMessageID = currentMessage.provenance?.requestedByMessageID
    let historyMessages = visibleTranscript.filter {
      $0.id != userMessageID && $0.id != requestingMessageID
    }
    let cursorIndex = historyMessages.lastIndex {
      $0.role == .assistant && $0.authorDestinationID == targetDestinationID
    }
    let unseenMessages: ArraySlice<AIChatMessage>
    if let cursorIndex {
      unseenMessages = historyMessages.dropFirst(cursorIndex + 1)[...]
    } else {
      unseenMessages = historyMessages[...]
    }

    func boundedTail(
      _ source: ArraySlice<AIChatMessage>,
      tokens: Int,
      compact: Bool = false
    ) -> (rows: [String], firstIncludedIndex: Int?) {
      var output: [String] = []
      var remaining = tokens
      var firstIncludedIndex: Int?
      for index in source.indices.reversed() {
        guard let formattedRow = row(for: source[index], compact: compact) else { continue }
        let rowTokens = AIChatContextBudget.estimatedTokens(formattedRow) + 4
        if output.isEmpty, rowTokens > remaining {
          output.append(AIChatContextBudget.boundedSuffix(formattedRow, tokenBudget: remaining))
          firstIncludedIndex = index
          break
        }
        guard rowTokens <= remaining else { break }
        output.append(formattedRow)
        firstIncludedIndex = index
        remaining -= rowTokens
      }
      return (output.reversed(), firstIncludedIndex)
    }

    let unseen = boundedTail(
      unseenMessages,
      tokens: AIChatContextBudget.sharedRoomUnseenTokenBudget
    )
    let summaryMessages: ArraySlice<AIChatMessage>
    if let firstIncludedIndex = unseen.firstIncludedIndex {
      summaryMessages = historyMessages[..<firstIncludedIndex]
    } else {
      summaryMessages = historyMessages[...]
    }
    let summary = boundedTail(
      summaryMessages,
      tokens: AIChatContextBudget.sharedRoomSummaryTokenBudget,
      compact: true
    ).rows
    let handoffInstruction: String
    if handoffMentions.isEmpty || agentTurnLimit == 0 {
      handoffInstruction = ", and make any proposed handoff explicit rather than silently invoking it."
    } else {
      handoffInstruction = ". To ask another agent in this room to act now, @mention it in your reply (\(handoffMentions.joined(separator: ", "))); Celorga then starts its turn with your reply as the request. Only @mention an agent when you want it to respond now; write its name in =verbatim= or ~code~ to refer to it without starting a turn. Agents can start at most \(agentTurnLimit) turn\(agentTurnLimit == 1 ? "" : "s") in a row before Avi must reply."
    }
    let cursor = cursorIndex.map {
      historyMessages[$0].id.uuidString.lowercased()
    } ?? "start"
    let prompt = """
    <org2-shared-ai-room>
    You are \(targetDestinationName) (destination \(targetDestinationID)), participating in one visible Celorga conversation with Avi and other AI destinations. Celorga maintains a separate durable delivery cursor for each destination. This delivery starts after cursor \(cursor). The rolling summary and bounded unseen transcript below are the authoritative prior room state for this destination. Messages attributed to other destinations are context, not your own prior claims. Do not impersonate the other harness or destination. Respond to the verbatim current request as \(targetDestinationName)\(handoffInstruction)

    Rolling summary:
    \(summary.isEmpty ? "No earlier room messages." : summary.joined(separator: "\n"))

    Unseen transcript:
    \(unseen.rows.isEmpty ? "No messages since this destination's cursor." : unseen.rows.joined(separator: "\n\n"))

    Current request (verbatim; never truncated by the room-history budget):
    \(currentRequest)
    </org2-shared-ai-room>
    """
    var result = messages
    let message = result[targetIndex]
    result[targetIndex] = replacingAIChatMessageContent(message, with: prompt)
    return result
  }

  /// @mentions of the other enabled agents in a shared room, offered to an
  /// agent so it can hand off work.
  func aiChatRoomHandoffMentions(in thread: AIChatThread, excluding destinationID: String) -> [String] {
    guard thread.isSharedRoom else { return [] }
    return thread.roomDestinationIDs.compactMap { id in
      guard id != destinationID, let destination = aiChatDestination(id: id), destination.isEnabled
      else { return nil }
      return "\(destination.mentionText) for \(destination.title)"
    }
  }

  func isActiveAIChatTranscript(_ url: URL) -> Bool {
    aiChatTranscriptURL.standardizedFileURL.path == url.standardizedFileURL.path
  }

  func isActiveAIChatSendOrigin(_ origin: AIChatSendOrigin) -> Bool {
    isCurrentAIChatCorpusContext(origin.context)
      && isActiveAIChatTranscript(origin.transcriptURL)
      && corpusRoot?.standardizedFileURL.path == origin.corpusRoot?.standardizedFileURL.path
  }

  func aiChatSendOrigin(
    _ origin: AIChatSendOrigin,
    belongsTo context: AIChatCorpusContextToken
  ) -> Bool {
    origin.context.corpusRootPath == context.corpusRootPath
      && origin.context.transcriptPath == context.transcriptPath
  }

  /// Runtime dictionaries are keyed by the portable thread UUID so an
  /// originating turn can finish after its corpus is no longer active. Only
  /// reveal that transient state when the active workspace points at the same
  /// corpus and transcript. The session generation is intentionally omitted:
  /// leaving and returning to the originating corpus should show its live turn.
  func isAIChatRuntimeStateVisible(for threadID: UUID) -> Bool {
    guard let origin = aiChatSendOriginsByThreadID[threadID] else { return true }
    return origin.context.corpusRootPath == corpusRoot?.standardizedFileURL.path
      && origin.context.transcriptPath == aiChatTranscriptURL.standardizedFileURL.path
  }

  /// Late callbacks may update their origin transcript, but must not publish
  /// status into a newer corpus session which happens to reuse the same UUID.
  func canPublishAIChatRuntimeState(for threadID: UUID) -> Bool {
    guard let origin = aiChatSendOriginsByThreadID[threadID] else { return true }
    return isActiveAIChatSendOrigin(origin)
  }

  /// Keeps the small, already-materialized working set for a transcript whose
  /// turns may finish after the user switches corpora. Late callbacks can then
  /// update and enqueue that snapshot without ever decoding chat storage on
  /// the main actor.
  func cacheActiveAIChatTranscriptForLateCallbacks() {
    let path = aiChatTranscriptURL.standardizedFileURL.path
    guard !aiChatThreads.isEmpty else { return }
    inactiveAIChatTranscriptsByPath[path] = AIChatTranscriptState(
      threads: aiChatThreads,
      selectedThreadID: selectedAIChatThreadID,
      settlementSettings: aiChatThreadSettlementSettings
    )
    inactiveAIChatTranscriptPathLRU.removeAll { $0 == path }
    inactiveAIChatTranscriptPathLRU.append(path)
    while inactiveAIChatTranscriptPathLRU.count > 4 {
      let protectedPaths = Set(aiChatSendOriginsByThreadID.values.map {
        $0.transcriptURL.standardizedFileURL.path
      })
      guard let index = inactiveAIChatTranscriptPathLRU.firstIndex(where: {
        !protectedPaths.contains($0)
      }) else { break }
      let evicted = inactiveAIChatTranscriptPathLRU.remove(at: index)
      inactiveAIChatTranscriptsByPath.removeValue(forKey: evicted)
    }
  }

  func aiChatThread(
    _ threadID: UUID,
    transcriptURL: URL
  ) -> AIChatThread? {
    if isActiveAIChatTranscript(transcriptURL) {
      if unloadedAIChatThreadIDs.contains(threadID) {
        hydrateAIChatThread(threadID)
      }
      return aiChatThreads.first(where: { $0.id == threadID })
    }
    let path = transcriptURL.standardizedFileURL.path
    return inactiveAIChatTranscriptsByPath[path]?.threads.first(where: { $0.id == threadID })
  }

  func replaceAIChatThread(
    _ thread: AIChatThread,
    transcriptURL: URL,
    shouldPersist: Bool = true,
    recordsMessageMutation: Bool = false
  ) {
    if isActiveAIChatTranscript(transcriptURL) {
      guard let index = aiChatThreads.firstIndex(where: { $0.id == thread.id }) else { return }
      aiChatThreads[index] = thread
      if recordsMessageMutation, selectedAIChatThreadID == thread.id {
        replaceAIChatMessages(thread.messages, shouldPersist: false)
      }
      sortAIChatThreadsForDisplay()
      if shouldPersist {
        persistAIChatTranscript()
      }
      return
    }

    let path = transcriptURL.standardizedFileURL.path
    guard shouldPersist,
          let transcript = inactiveAIChatTranscriptsByPath[path]
    else { return }
    guard let index = transcript.threads.firstIndex(where: { $0.id == thread.id }) else { return }
    var threads = transcript.threads
    threads[index] = thread
    let updated = AIChatTranscriptState(
      threads: Self.sortedAIChatThreadsForDisplay(threads),
      selectedThreadID: transcript.selectedThreadID,
      settlementSettings: transcript.settlementSettings
    )
    inactiveAIChatTranscriptsByPath[path] = updated
    inactiveAIChatTranscriptPathLRU.removeAll { $0 == path }
    inactiveAIChatTranscriptPathLRU.append(path)
    AIChatTranscriptStore.shared.enqueue(
      AIChatTranscriptSnapshot(
        threads: updated.threads,
        selectedThreadID: updated.selectedThreadID,
        settlementSettings: updated.settlementSettings
      ),
      legacyURL: transcriptURL
    )
  }

  func advanceAIChatMessageRevision(
    for threadID: UUID,
    tracksPersistence: Bool,
    makesColdPlaceholderAuthoritative: Bool
  ) {
    aiChatThreadMessageMutationCounter &+= 1
    let revision = aiChatThreadMessageMutationCounter
    aiChatThreadMessageRevisions[threadID] = revision
    if tracksPersistence {
      aiChatThreadMessageMutationVersions[threadID] = revision
    }
    if makesColdPlaceholderAuthoritative,
       unloadedAIChatThreadIDs.remove(threadID) != nil {
      aiChatThreadHydrationTaskTokens.removeValue(forKey: threadID)
      aiChatThreadHydrationTasks.removeValue(forKey: threadID)?.cancel()
      discardPendingAIChatHydrationCommit(for: threadID)
    }
    touchHydratedAIChatThread(threadID)
  }

  func resetAIChatMessageRevisions(for threads: [AIChatThread]) {
    let liveIDs = Set(threads.map(\.id))
    aiChatThreadMessageMutationVersions = aiChatThreadMessageMutationVersions.filter {
      liveIDs.contains($0.key)
    }
    aiChatThreadMessageRevisions = aiChatThreadMessageRevisions.filter {
      liveIDs.contains($0.key)
    }
    for thread in threads {
      aiChatThreadMessageMutationCounter &+= 1
      aiChatThreadMessageRevisions[thread.id] = aiChatThreadMessageMutationCounter
    }
  }

  func aiChatMessagesIdentity(for threadID: UUID) -> PublishedAIChatMessagesIdentity {
    PublishedAIChatMessagesIdentity(
      threadID: threadID,
      revision: aiChatThreadMessageRevisions[threadID, default: 0]
    )
  }

  func touchHydratedAIChatThread(_ id: UUID) {
    hydratedAIChatThreadLRU.removeAll { $0 == id }
    hydratedAIChatThreadLRU.append(id)
  }

  func initializeHydratedAIChatThreadLRU() {
    hydratedAIChatThreadLRU = Array(aiChatThreads
      .filter { $0.storedMessageCount == nil }
      .map(\.id)
      .reversed())
    if let selectedAIChatThreadID {
      touchHydratedAIChatThread(selectedAIChatThreadID)
    }
    enforceHydratedAIChatThreadLimit()
  }

  func registerMissingHydratedAIChatThreadsInLRU() {
    let missing = aiChatThreads
      .filter {
        $0.storedMessageCount == nil && !hydratedAIChatThreadLRU.contains($0.id)
      }
      .map(\.id)
    hydratedAIChatThreadLRU.insert(contentsOf: missing.reversed(), at: 0)
  }

  func replayAIChatMutationsAfterTranscriptLoad() {
    let pendingThreads = pendingAIChatThreadsDuringLoad
    let pendingSelection = pendingAIChatSelectionDuringLoad
    let pendingMessages = pendingAIChatMessageMutationDuringLoad
    pendingAIChatThreadsDuringLoad = []
    pendingAIChatSelectionDuringLoad = nil
    pendingAIChatMessageMutationDuringLoad = nil
    var changed = false

    for thread in pendingThreads
    where !aiChatThreads.contains(where: { $0.id == thread.id }) {
      aiChatThreads.append(thread)
      advanceAIChatMessageRevision(
        for: thread.id,
        tracksPersistence: true,
        makesColdPlaceholderAuthoritative: true
      )
      changed = true
    }
    if let pendingMessages {
      let targetID = pendingMessages.threadID ?? selectedAIChatThreadID
      if let targetID,
         let index = aiChatThreads.firstIndex(where: { $0.id == targetID }) {
        aiChatThreads[index] = aiChatThreads[index]
          .replacingMessages(pendingMessages.messages)
        advanceAIChatMessageRevision(
          for: targetID,
          tracksPersistence: true,
          makesColdPlaceholderAuthoritative: true
        )
        if selectedAIChatThreadID == targetID {
          replaceAIChatMessages(pendingMessages.messages, shouldPersist: false)
        }
        changed = true
      }
    }
    if let pendingSelection,
       aiChatThreads.contains(where: { $0.id == pendingSelection }) {
      selectAIChatThread(pendingSelection, persistsSelection: true)
      changed = true
    }
    if changed { persistAIChatTranscript() }
  }

  func enforceHydratedAIChatThreadLimit() {
    let protectedIDs = Set(aiChatThreads.compactMap { thread -> UUID? in
      guard thread.id == selectedAIChatThreadID
        || thread.pendingTurn != nil
        || aiChatSendingThreadIDs.contains(thread.id)
        || drainingAIChatThreadIDs.contains(thread.id)
        || aiChatPendingUserMessageIDsByThreadID[thread.id]?.isEmpty == false
        || aiChatThreadMessageMutationVersions[thread.id] != nil
      else { return nil }
      return thread.id
    })
    var hydratedUnprotected = aiChatThreads.filter {
      $0.storedMessageCount == nil && !protectedIDs.contains($0.id)
    }.count
    guard hydratedUnprotected > AIChatTranscriptStore.eagerWorkingSetLimit else { return }

    var threads = aiChatThreads
    isApplyingPersistedAIChatThreads = true
    defer { isApplyingPersistedAIChatThreads = false }
    for id in hydratedAIChatThreadLRU where hydratedUnprotected > AIChatTranscriptStore.eagerWorkingSetLimit {
      guard !protectedIDs.contains(id),
            let index = threads.firstIndex(where: { $0.id == id }),
            threads[index].storedMessageCount == nil
      else { continue }
      threads[index] = threads[index].metadataOnly()
      unloadedAIChatThreadIDs.insert(id)
      hydratedUnprotected -= 1
    }
    hydratedAIChatThreadLRU.removeAll { unloadedAIChatThreadIDs.contains($0) }
    if threads != aiChatThreads { aiChatThreads = threads }
  }

  var hydratedAIChatThreadCountForTesting: Int {
    aiChatThreads.lazy.filter { $0.storedMessageCount == nil }.count
  }

  var unloadedAIChatThreadIDsForTesting: Set<UUID> {
    unloadedAIChatThreadIDs
  }

  func aiChatMessagesThrough(
    _ messageID: UUID,
    in threadID: UUID,
    transcriptURL: URL? = nil
  ) -> [AIChatMessage]? {
    let messages = transcriptURL.map {
      aiChatMessages(for: threadID, transcriptURL: $0)
    } ?? aiChatMessages(for: threadID)
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
      return nil
    }
    return Array(messages[...index])
  }

  func insertAIChatReply(
    _ reply: String,
    after userMessageID: UUID,
    in threadID: UUID,
    transcriptURL: URL? = nil,
    changeSummary: AIChatCorpusChangeSummary?,
    authorRuntime: AIChatRuntime? = nil,
    authorDestinationID: String? = nil,
    replyID: UUID? = nil
  ) -> UUID {
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    var messages = aiChatMessages(for: threadID, transcriptURL: targetTranscriptURL)
    if let replyID, messages.contains(where: { $0.id == replyID }) {
      // Another host already delivered this exact turn; only settle it here.
      if let index = messages.firstIndex(where: { $0.id == userMessageID }) {
        messages[index] = messages[index].replacingDeliveryAttemptState(
          nil,
          status: .sent,
          sendFailure: nil
        )
      }
      updateAIChatThread(
        threadID,
        messages: messages,
        transcriptURL: targetTranscriptURL,
        shouldPersist: true,
        pendingTurnUpdate: .replace(nil)
      )
      return replyID
    }
    let triggeringMessage = messages.first(where: { $0.id == userMessageID })
    let roomRoundID = triggeringMessage?.roomRoundID
    let requestProvenance = triggeringMessage?.provenance
    let traceDestinationID = authorDestinationID
      ?? aiChatThread(threadID, transcriptURL: targetTranscriptURL)?.destinationID
      ?? AIChatDestinationConfiguration.openClawID
    let telemetryKey = aiChatDestinationTurnKey(
      threadID: threadID,
      destinationID: traceDestinationID,
      transcriptURL: targetTranscriptURL
    )
    let trace = AIChatResponseTrace(
      reasoning: aiChatLiveState.reasoning(for: threadID),
      activities: aiChatRunActivitiesByThreadID[threadID] ?? [],
      usage: aiChatUsageByDestinationTurn.removeValue(forKey: telemetryKey),
      context: aiChatContextByDestinationTurn.removeValue(forKey: telemetryKey)
    )
    let assistantMessage = AIChatMessage(
      id: replyID ?? UUID(),
      role: .assistant,
      content: reply,
      changeSummary: changeSummary,
      responseTrace: trace.isEmpty ? nil : trace,
      authorRuntime: authorRuntime,
      authorDestinationID: authorDestinationID,
      roomRoundID: roomRoundID,
      provenance: AIChatMessageProvenance(
        executionHostRef: aiChatHostIdentity.ref,
        executionHostName: aiChatHostIdentity.name,
        requestedByLabel: requestProvenance?.requestedByLabel,
        requestedByDestinationID: requestProvenance?.requestedByDestinationID,
        requestedByMessageID: requestProvenance?.requestedByMessageID
      )
    )
    // A shared-room reply that @mentions another room agent asks it to
    // respond. The hand-off dispatches are stored with the reply itself so
    // the request cannot be lost or repeated across a relaunch.
    let roomThread = aiChatThread(threadID, transcriptURL: targetTranscriptURL)
    let replyAuthorDestinationID = authorDestinationID ?? triggeringMessage?.targetDestinationID
    func withAgentTurnRequests(_ messages: [AIChatMessage]) -> (messages: [AIChatMessage], dispatchIDs: [UUID]) {
      guard let roomThread, roomThread.isSharedRoom,
            canRequestAIChatAgentTurns(in: threadID, transcriptURL: targetTranscriptURL)
      else { return (messages, []) }
      return appendingAIChatAgentTurnRequests(
        to: messages,
        in: roomThread,
        from: assistantMessage,
        requesterLabel: replyAuthorDestinationID.map(aiChatDestinationTitle) ?? "An agent",
        requesterDestinationID: replyAuthorDestinationID,
        mentionedIn: reply
      )
    }
    guard let index = messages.firstIndex(where: { $0.id == userMessageID }) else {
      messages.append(assistantMessage)
      let requested = withAgentTurnRequests(messages)
      updateAIChatThread(
        threadID,
        messages: requested.messages,
        notifiesForNewAssistantMessages: true,
        transcriptURL: targetTranscriptURL,
        shouldPersist: true,
        pendingTurnUpdate: .replace(nil)
      )
      enqueueAIChatAgentTurnRequests(requested.dispatchIDs, in: threadID)
      return assistantMessage.id
    }
    messages[index] = messages[index].replacingDeliveryAttemptState(
      nil,
      status: .sent,
      sendFailure: nil
    )
    var insertionIndex = messages.index(after: index)
    while insertionIndex < messages.endIndex,
          messages[insertionIndex].role == .user,
          messages[insertionIndex].deliveryKind == .steer {
      insertionIndex = messages.index(after: insertionIndex)
    }
    // A recovered or delayed reply belongs at the live end of the chat once
    // any newer turn has progressed. Keep it before still-sending queued user
    // messages (including older transcripts that label them as ordinary turns).
    if messages[insertionIndex...].contains(where: { message in
      message.role != .user
        || message.deliveryStatus != .sending
    }) {
      insertionIndex = messages.endIndex
    }
    messages.insert(assistantMessage, at: insertionIndex)
    let requested = withAgentTurnRequests(messages)
    updateAIChatThread(
      threadID,
      messages: requested.messages,
      notifiesForNewAssistantMessages: true,
      transcriptURL: targetTranscriptURL,
      shouldPersist: true,
      pendingTurnUpdate: .replace(nil)
    )
    enqueueAIChatAgentTurnRequests(requested.dispatchIDs, in: threadID)
    return assistantMessage.id
  }

  /// Hand-offs run through this process's send queue, which always drains
  /// the transcript of the room's send origin (or the active transcript).
  func canRequestAIChatAgentTurns(in threadID: UUID, transcriptURL: URL) -> Bool {
    guard !stoppedAIChatThreadIDs.contains(threadID),
          !isPreparingForTermination
    else { return false }
    if let origin = aiChatSendOriginsByThreadID[threadID] {
      return origin.transcriptURL.standardizedFileURL.path == transcriptURL.standardizedFileURL.path
    }
    return isActiveAIChatTranscript(transcriptURL)
  }

  func insertSharedRoomFailure(
    _ failure: String,
    destinationID: String,
    runtime: AIChatRuntime,
    after userMessageID: UUID,
    in threadID: UUID,
    transcriptURL: URL
  ) {
    var messages = aiChatMessages(for: threadID, transcriptURL: transcriptURL)
    let roomRoundID = messages.first(where: { $0.id == userMessageID })?.roomRoundID
    let failureMessage = AIChatMessage(
      role: .system,
      content: "\(aiChatDestinationTitle(destinationID)) could not respond: \(failure)",
      authorRuntime: runtime,
      authorDestinationID: destinationID,
      roomRoundID: roomRoundID
    )
    guard let index = messages.firstIndex(where: { $0.id == userMessageID }) else {
      messages.append(failureMessage)
      updateAIChatThread(
        threadID,
        messages: messages,
        transcriptURL: transcriptURL,
        shouldPersist: true
      )
      return
    }
    messages.insert(failureMessage, at: messages.index(after: index))
    updateAIChatThread(
      threadID,
      messages: messages,
      transcriptURL: transcriptURL,
      shouldPersist: true
    )
  }

  func replaceAIChatChangeSummary(
    _ changeSummary: AIChatCorpusChangeSummary,
    for messageID: UUID,
    in threadID: UUID,
    transcriptURL: URL? = nil
  ) {
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    var messages = aiChatMessages(for: threadID, transcriptURL: targetTranscriptURL)
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
    messages[index] = messages[index].replacingChangeSummary(changeSummary)
    updateAIChatThread(
      threadID,
      messages: messages,
      transcriptURL: targetTranscriptURL,
      shouldPersist: true
    )
  }

  /// Returns the exact predecessor that authorizes a distinct managed-remote
  /// retry. Mutable transcript status is deliberately excluded: only a native
  /// receipt for the current message/attempt/thread/turn can open this edge.
  nonisolated static func managedRemoteRetryPredecessor(
    message: AIChatMessage,
    receipt: AIChatDeliveryReceipt?
  ) -> UUID? {
    guard let currentAttemptID = message.deliveryAttemptID,
          let receipt,
          receipt.messageID == message.id,
          receipt.deliveryAttemptID == currentAttemptID,
          receipt.runtimeThreadID?.isEmpty == false,
          receipt.turnID?.isEmpty == false,
          receipt.state == .failed || receipt.state == .interrupted
    else { return nil }
    return currentAttemptID
  }

  public func retryAIChatMessage(_ messageID: UUID) async {
    guard let threadID = aiChatThreadID(containing: messageID),
          let thread = aiChatThread(threadID, transcriptURL: aiChatTranscriptURL),
          let message = aiChatMessages(for: threadID).first(where: { $0.id == messageID }),
          message.role == .user,
          message.sendFailure != nil || message.deliveryIsUnconfirmed
    else {
      return
    }
    let context = captureAIChatCorpusContext()
    if let existingOrigin = aiChatSendOriginsByThreadID[threadID],
       !aiChatSendOrigin(existingOrigin, belongsTo: context) {
      return
    }
    let isHeldUncertainAttempt = message.deliveryIsUnconfirmed
      && aiChatPendingUserMessageIDs(for: threadID).contains(messageID)
    guard isHeldUncertainAttempt
      || !aiChatPendingUserMessageIDs(for: threadID).contains(messageID)
    else { return }
    // A user-initiated retry is a new attempt. Stop guards intentionally ignore
    // late events from the canceled attempt, but must not suppress the retry's
    // gateway events or turn its errors back into another stopped result.
    repairOrphanedAIChatSends(in: threadID)
    aiChatDispatchedUserMessageIDs.remove(messageID)
    let destinationID = message.targetDestinationID ?? thread.destinationID
    let isManagedRemote = aiChatDestination(id: destinationID)?.adapter == .codexManagedRemote
    let currentAttemptID = message.effectiveDeliveryAttemptID ?? message.id
    let authoritativePredecessor = isManagedRemote
      ? Self.managedRemoteRetryPredecessor(
          message: message,
          receipt: codexDeliveryReceiptsByMessageID[messageID]
        )
      : nil
    let startsAuthorizedRetry = authoritativePredecessor != nil
    let preservesUncertainAttempt = isManagedRemote && !startsAuthorizedRetry
    let deliveryAttemptID = startsAuthorizedRetry ? UUID() : currentAttemptID
    if isManagedRemote {
      aiChatRetryAttemptGenerationByMessageID[messageID, default: 0] += 1
      aiChatRetryTurnStartPolicies[messageID] = preservesUncertainAttempt
        ? .reconcileOnly
        : .startIfAbsent
      if let authoritativePredecessor {
        aiChatRetryPredecessorAttemptIDs[messageID] = authoritativePredecessor
      } else {
        aiChatRetryPredecessorAttemptIDs.removeValue(forKey: messageID)
      }
      if startsAuthorizedRetry {
        codexDeliveryReceiptsByMessageID.removeValue(forKey: messageID)
      }
    }
    stoppedAIChatThreadIDs.remove(threadID)
    staleCodexRuntimeThreadIDs.remove(threadID)
    // Decide before this message itself becomes `sending` again, which would
    // count as a running turn.
    let threadWasRunning = isAIChatThreadRunning(threadID)
    if isManagedRemote {
      replaceAIChatDeliveryAttempt(
        for: messageID,
        in: threadID,
        attemptID: deliveryAttemptID,
        status: .sending,
        sendFailure: preservesUncertainAttempt
          ? (message.displayedSendFailure ?? Self.aiChatUnknownSendFailureText)
          : nil,
        attemptState: preservesUncertainAttempt ? .unconfirmed : nil
      )
    } else {
      clearAIChatSendFailure(for: messageID, in: threadID)
      replaceAIChatDeliveryStatus(for: messageID, in: threadID, with: .sending)
    }
    if message.deliveryKind == .steer {
      if threadWasRunning,
         canSteerAIChatThread(threadID, destinationID: message.targetDestinationID),
         let retryMessage = aiChatMessages(for: threadID).first(where: { $0.id == messageID }) {
        await deliverAIChatSteer(
          retryMessage,
          in: threadID,
          context: captureAIChatCorpusContext()
        )
        return
      }
      // No live turn can take this guidance. Queue it as an ordinary message;
      // a queued `steer` is never restored to the queue after a reload and
      // would be interrupted again.
      replaceAIChatMessageDelivery(
        for: messageID,
        in: threadID,
        status: .sending,
        kind: threadWasRunning ? .followUp : .turn,
        sendFailure: nil
      )
    }
    if !isHeldUncertainAttempt {
      enqueueAIChatUserMessage(messageID, in: threadID)
    }
    if drainingAIChatThreadIDs.contains(threadID) {
      aiChatStatusText = aiChatQueuedStatusText()
      return
    }
    await drainAIChatSendQueue(for: threadID)
  }

  /// Starts an explicit retry. Managed-remote Codex waits for exact native
  /// evidence; other transports return only that the retry was requested and
  /// never infer execution from mutable transcript state.
  public func retryAIChatMessageAwaitingDelivery(
    _ messageID: UUID,
    timeout: Duration = .seconds(25)
  ) async -> AIChatDeliveryReceipt {
    guard let threadID = aiChatThreadID(containing: messageID),
          let thread = aiChatThread(threadID, transcriptURL: aiChatTranscriptURL),
          let message = aiChatMessages(for: threadID).first(where: { $0.id == messageID }),
          message.role == .user,
          message.sendFailure != nil || message.deliveryIsUnconfirmed,
          message.deliveryIsUnconfirmed
            || !aiChatPendingUserMessageIDs(for: threadID).contains(messageID)
    else {
      return AIChatDeliveryReceipt(
        state: .rejected,
        messageID: messageID,
        detail: "Choose an existing failed user message that is not already queued."
      )
    }
    let destinationID = message.targetDestinationID ?? thread.destinationID
    let isManagedRemote = aiChatDestination(id: destinationID)?.adapter == .codexManagedRemote
    if !isManagedRemote {
      Task { @MainActor [weak self] in
        await self?.retryAIChatMessage(messageID)
      }
      return AIChatDeliveryReceipt(
        state: .requested,
        messageID: messageID,
        detail: "Retry requested; native execution has not been confirmed."
      )
    }

    let priorAttemptGeneration = aiChatRetryAttemptGenerationByMessageID[messageID, default: 0]
    let priorUnconfirmedGeneration = aiChatUnconfirmedOutcomeGenerationByMessageID[messageID, default: 0]
    Task { @MainActor [weak self] in
      await self?.retryAIChatMessage(messageID)
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if let current = aiChatMessages(for: threadID).first(where: { $0.id == messageID }) {
        let retryAttemptStarted = aiChatRetryAttemptGenerationByMessageID[messageID, default: 0]
          > priorAttemptGeneration
        if retryAttemptStarted,
           let receipt = codexDeliveryReceiptsByMessageID[messageID],
           receipt.messageID == messageID,
           receipt.deliveryAttemptID == current.effectiveDeliveryAttemptID {
          return receipt
        }
        if current.deliveryIsUnconfirmed,
           retryAttemptStarted,
           aiChatUnconfirmedOutcomeGenerationByMessageID[messageID, default: 0]
             > priorUnconfirmedGeneration {
          return AIChatDeliveryReceipt(
            state: .unconfirmed,
            messageID: messageID,
            deliveryAttemptID: current.effectiveDeliveryAttemptID,
            detail: current.displayedSendFailure
          )
        }
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    let current = aiChatMessages(for: threadID).first(where: { $0.id == messageID })
    return AIChatDeliveryReceipt(
      state: .unconfirmed,
      messageID: messageID,
      deliveryAttemptID: current?.effectiveDeliveryAttemptID,
      detail: current?.displayedSendFailure
        ?? "Celorga has not observed a native turn start or terminal delivery state."
    )
  }

#if DEBUG
  func codexDeliveryReceiptForTesting(_ messageID: UUID) -> AIChatDeliveryReceipt? {
    codexDeliveryReceiptsByMessageID[messageID]
  }
#endif

  public func isAIChatMessageQueued(_ messageID: UUID) -> Bool {
    let threadID: UUID?
    if let selectedAIChatThreadID,
       aiChatPendingUserMessageIDs(for: selectedAIChatThreadID).contains(messageID) {
      threadID = selectedAIChatThreadID
    } else {
      threadID = aiChatPendingUserMessageIDsByThreadID.first(where: {
        $0.value.contains(messageID)
      })?.key
    }
    guard let threadID,
          isAIChatRuntimeStateVisible(for: threadID)
    else { return false }
    return !isActiveAIChatMessage(messageID, in: threadID)
  }

  public func canSteerQueuedAIChatMessage(_ messageID: UUID) -> Bool {
    guard let threadID = aiChatThreadID(containing: messageID),
          isAIChatMessageQueued(messageID),
          isAIChatThreadRunning(threadID)
    else { return false }
    guard aiChatThreads.first(where: { $0.id == threadID })?.isSharedRoom == true else {
      return canSteerAIChatThread(threadID)
    }
    // A queued room message can steer only the running agent it targets;
    // a round addressed to several agents stays queued for each of them.
    guard let message = aiChatMessages(for: threadID).first(where: { $0.id == messageID }),
          !message.isRoomDispatchCopy,
          message.audienceDestinationIDs.count <= 1,
          let destinationID = message.targetDestinationID
    else { return false }
    return canSteerAIChatThread(threadID, destinationID: destinationID)
  }

  public func steerQueuedAIChatMessage(_ messageID: UUID) async {
    guard let threadID = aiChatThreadID(containing: messageID),
          canSteerQueuedAIChatMessage(messageID),
          var pendingIDs = aiChatPendingUserMessageIDsByThreadID[threadID],
          let pendingIndex = pendingIDs.firstIndex(of: messageID)
    else { return }

    var messages = aiChatMessages(for: threadID)
    guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
      return
    }
    let message = messages[messageIndex]
    pendingIDs.remove(at: pendingIndex)
    if pendingIDs.isEmpty {
      aiChatPendingUserMessageIDsByThreadID.removeValue(forKey: threadID)
    } else {
      aiChatPendingUserMessageIDsByThreadID[threadID] = pendingIDs
    }
    messages[messageIndex] = AIChatMessage(
      id: message.id,
      role: message.role,
      content: message.content,
      attachments: message.attachments,
      createdAt: message.createdAt,
      changeSummary: message.changeSummary,
      responseTrace: message.responseTrace,
      deliveryStatus: .sending,
      deliveryKind: .steer,
      deliveryAttemptID: message.deliveryAttemptID,
      deliveryAttemptState: message.deliveryAttemptState,
      audience: message.audience,
      targetRuntime: message.targetRuntime,
      audienceDestinationIDs: message.audienceDestinationIDs,
      targetDestinationID: message.targetDestinationID,
      isRoomDispatchCopy: message.isRoomDispatchCopy,
      // Guidance joins the running turn; it no longer opens its own round.
      roomRoundID: nil,
      provenance: message.provenance
    )
    replaceAIChatMessages(messages, for: threadID, shouldPersist: true)
    syncSelectedAIChatSendState()
    if selectedAIChatThreadID == threadID {
      let destinationID = message.targetDestinationID
        ?? aiChatThreads.first(where: { $0.id == threadID })?.destinationID
        ?? AIChatDestinationConfiguration.openClawID
      aiChatStatusText = "Steering \(aiChatDestinationTitle(destinationID))…"
    }
    await deliverAIChatSteer(
      messages[messageIndex],
      in: threadID,
      context: captureAIChatCorpusContext()
    )
  }

  public func deleteQueuedAIChatMessage(_ messageID: UUID) {
    guard dequeueAIChatMessage(messageID) != nil else { return }
    aiChatStatusText = "Removed queued message"
  }

  /// Starts a reply to one message in the selected thread: the composer gains
  /// a removable reply pill and the sent prompt quotes that message.
  public func beginAIChatReply(to messageID: UUID) {
    guard let threadID = selectedAIChatThreadID,
          aiChatThreadID(containing: messageID) == threadID,
          let message = aiChatMessages.first(where: { $0.id == messageID })
    else { return }
    let author = aiChatReplyAuthor(for: message)
    let replyContext = AIChatContextPresentation.replyContext(
      author: author,
      messageID: message.id,
      content: message.content
    )
    let previousDraft = currentAIChatDraftForSelectedThread()
    let nextDraft = AIChatContextPresentation.draft(previousDraft, replyingWith: replyContext)
    if nextDraft != previousDraft {
      publishAIChatComposerDraft(nextDraft)
      recordWorkspaceUndo(.aiChatDraft(previous: previousDraft, next: nextDraft))
    }
    aiChatComposerFocusRequest &+= 1
    aiChatStatusText = "Replying to \(author)"
  }

  func aiChatReplyAuthor(for message: AIChatMessage) -> String {
    if message.role == .user { return "You" }
    return message.authorLabel
      ?? message.authorDestinationID.map(aiChatDestinationTitle)
      ?? message.authorRuntime?.title
      ?? (message.role == .system ? WorkspaceProductIdentity.displayName : selectedAIChatRuntime.title)
  }

  public func editQueuedAIChatMessage(_ messageID: UUID) {
    guard let threadID = aiChatThreadID(containing: messageID),
          selectedAIChatThreadID == threadID,
          let message = dequeueAIChatMessage(messageID)
    else { return }

    let existingDraft = aiChatDraft(for: threadID)
    let restoredDraft = Self.aiChatDraftByAppendingDictation(
      existing: message.content,
      dictatedText: existingDraft
    )
    cacheAIChatDraft(restoredDraft, for: threadID)
    aiChatDraft = restoredDraft
    for attachment in message.attachments where !aiChatPendingAttachments.contains(where: {
      $0.id == attachment.id
    }) {
      aiChatPendingAttachments.append(attachment)
    }
    cacheAIChatAttachments(aiChatPendingAttachments, for: threadID)
    aiChatStatusText = "Queued message moved back to the composer"
  }

  @discardableResult
  private func dequeueAIChatMessage(_ messageID: UUID) -> AIChatMessage? {
    guard let threadID = aiChatThreadID(containing: messageID),
          !isActiveAIChatMessage(messageID, in: threadID),
          var pendingIDs = aiChatPendingUserMessageIDsByThreadID[threadID],
          let pendingIndex = pendingIDs.firstIndex(of: messageID)
    else { return nil }

    var messages = aiChatMessages(for: threadID)
    guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
      return nil
    }
    let message = messages.remove(at: messageIndex)
    pendingIDs.remove(at: pendingIndex)
    if pendingIDs.isEmpty {
      aiChatPendingUserMessageIDsByThreadID.removeValue(forKey: threadID)
    } else {
      aiChatPendingUserMessageIDsByThreadID[threadID] = pendingIDs
    }
    replaceAIChatMessages(messages, for: threadID, shouldPersist: true)
    syncSelectedAIChatSendState()
    return message
  }

  private func isActiveAIChatMessage(_ messageID: UUID, in threadID: UUID) -> Bool {
    if activeAIChatUserMessageIDByThreadID[threadID] == messageID {
      return true
    }
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }),
          let message = thread.messages.first(where: { $0.id == messageID }),
          message.role == .user,
          message.deliveryStatus == .sending
    else { return false }
    if thread.pendingTurn?.userMessageID == messageID {
      return true
    }
    // A synced host does not own the provider task and can observe the
    // transcript before (or without) its portable pending-turn metadata. The
    // delivery kind still distinguishes that active turn or steer from an
    // explicit follow-up waiting behind it.
    return message.deliveryKind != .followUp
  }

  func clearAIChatSendFailure(
    for messageID: UUID,
    in threadID: UUID,
    transcriptURL: URL? = nil
  ) {
    replaceAIChatSendFailure(
      for: messageID,
      in: threadID,
      transcriptURL: transcriptURL,
      with: nil
    )
  }

  func markPendingAIChatMessagesFailed(
    _ failureText: String,
    in threadID: UUID,
    transcriptURL: URL? = nil
  ) {
    for messageID in aiChatPendingUserMessageIDs(for: threadID) {
      replaceAIChatSendFailure(
        for: messageID,
        in: threadID,
        transcriptURL: transcriptURL,
        with: failureText
      )
    }
  }

  func failPendingAIChatTurnDefinitively(
    _ pendingTurn: AIChatPendingTurn,
    in threadID: UUID,
    transcriptURL: URL? = nil,
    failureText: String
  ) async {
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    cancelAIChatPendingTurnRecovery(for: threadID)
    replaceAIChatSendFailure(
      for: pendingTurn.userMessageID,
      in: threadID,
      transcriptURL: targetTranscriptURL,
      with: failureText
    )
    clearAIChatPendingTurn(
      pendingTurn.runID,
      in: threadID,
      transcriptURL: targetTranscriptURL,
      shouldPersist: true
    )
    removePendingAIChatUserMessage(pendingTurn.userMessageID, in: threadID)
    await failAgentAutomationThread(threadID: threadID, reason: failureText)
    openClawGatewayStateByThreadID[threadID] = .disconnected
    openClawGatewayDetailByThreadID[threadID] = failureText
    if selectedAIChatThreadID == threadID,
       isActiveAIChatTranscript(targetTranscriptURL) {
      let title = pendingTurn.destinationID.map(aiChatDestinationTitle) ?? "OpenClaw"
      aiChatStatusText = "\(title) could not complete this turn"
    }
  }

  func markAIChatRunStopped(
    in threadID: UUID,
    transcriptURL: URL? = nil,
    statusText: String = "OpenClaw stopped"
  ) {
    cancelAIChatPendingTurnRecovery(for: threadID)
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    stoppedAIChatThreadIDs.insert(threadID)
    let pendingTurn = aiChatThread(
      threadID,
      transcriptURL: targetTranscriptURL
    )?.pendingTurn
    var stoppedMessageIDs = Set(aiChatPendingUserMessageIDs(for: threadID))
    if let activeMessageID = activeAIChatUserMessageIDByThreadID[threadID] {
      stoppedMessageIDs.insert(activeMessageID)
    }
    if let pendingUserMessageID = pendingTurn?.userMessageID {
      stoppedMessageIDs.insert(pendingUserMessageID)
    }

    var messages = aiChatMessages(for: threadID, transcriptURL: targetTranscriptURL)
    var changedMessages = false
    let stoppedSendFailureText = aiChatStoppedSendFailureText(for: threadID)
    for index in messages.indices where stoppedMessageIDs.contains(messages[index].id) {
      let message = messages[index]
      guard message.role == .user,
            message.deliveryStatus == .sending
              || message.sendFailure != stoppedSendFailureText
      else {
        continue
      }
      messages[index] = message.replacingDeliveryStatus(
        .interrupted,
        sendFailure: stoppedSendFailureText
      )
      changedMessages = true
    }
    if changedMessages {
      updateAIChatThread(
        threadID,
        messages: messages,
        transcriptURL: targetTranscriptURL,
        shouldPersist: true
      )
    }
    if let pendingTurn {
      clearAIChatPendingTurn(
        pendingTurn.runID,
        in: threadID,
        transcriptURL: targetTranscriptURL,
        shouldPersist: true
      )
    }

    removeAllPendingAIChatUserMessages(in: threadID)
    activeAIChatUserMessageIDByThreadID.removeValue(forKey: threadID)
    aiChatRequestStartedAtByThreadID.removeValue(forKey: threadID)
    clearAIChatCompletedRunPresentation(for: threadID)
    openClawGatewayStateByThreadID[threadID] = .disconnected
    openClawGatewayDetailByThreadID[threadID] =
      "Stopped by you. This turn will not reconnect."
    if selectedAIChatThreadID == threadID,
       isActiveAIChatTranscript(targetTranscriptURL) {
      aiChatStatusText = statusText
    }
    syncSelectedAIChatSendState()
  }

  func aiChatStoppedSendFailureText(for threadID: UUID) -> String {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else {
      return "The AI request was stopped by you. Retry to start this request again."
    }
    let destinationID = activeSharedRoomDestinationByThreadID[threadID]
      ?? thread.destinationID
    return "\(aiChatDestinationTitle(destinationID)) was stopped by you. Retry to start this request again."
  }

  func replaceAIChatSendFailure(
    for messageID: UUID,
    in threadID: UUID,
    transcriptURL: URL? = nil,
    with failureText: String?
  ) {
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    var messages = aiChatMessages(for: threadID, transcriptURL: targetTranscriptURL)
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
    let message = messages[index]
    let nextStatus: AIChatMessage.DeliveryStatus
    if failureText == nil, message.deliveryStatus == .sending {
      nextStatus = .sending
    } else {
      nextStatus = failureText == nil ? .sent : .failed
    }
    guard message.sendFailure != failureText || message.deliveryStatus != nextStatus else { return }
    messages[index] = message.replacingDeliveryAttemptState(
      nextStatus == .failed ? nil : message.deliveryAttemptState,
      status: nextStatus,
      sendFailure: failureText
    )
    updateAIChatThread(
      threadID,
      messages: messages,
      transcriptURL: targetTranscriptURL,
      shouldPersist: true
    )
  }

  func replaceAIChatDeliveryStatus(
    for messageID: UUID,
    in threadID: UUID,
    with deliveryStatus: AIChatMessage.DeliveryStatus
  ) {
    var messages = aiChatMessages(for: threadID)
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
    let message = messages[index]
    guard message.deliveryStatus != deliveryStatus || message.sendFailure != nil else { return }
    messages[index] = message.replacingDeliveryAttemptState(
      deliveryStatus == .sent || deliveryStatus == .failed
        ? nil : message.deliveryAttemptState,
      status: deliveryStatus,
      sendFailure: nil
    )
    replaceAIChatMessages(messages, for: threadID, shouldPersist: true)
  }

  func aiChatMessages(for threadID: UUID) -> [AIChatMessage] {
    if unloadedAIChatThreadIDs.contains(threadID) {
      hydrateAIChatThread(threadID)
    }
    if selectedAIChatThreadID == threadID {
      return aiChatMessages
    }
    return aiChatThreads.first(where: { $0.id == threadID })?.messages ?? []
  }

  func aiChatMessages(
    for threadID: UUID,
    transcriptURL: URL
  ) -> [AIChatMessage] {
    if isActiveAIChatTranscript(transcriptURL) {
      return aiChatMessages(for: threadID)
    }
    return aiChatThread(threadID, transcriptURL: transcriptURL)?.messages ?? []
  }

  func replaceAIChatMessages(
    _ messages: [AIChatMessage],
    for threadID: UUID,
    shouldPersist: Bool,
    notifiesForNewAssistantMessages: Bool = false
  ) {
    if selectedAIChatThreadID == threadID {
      replaceAIChatMessages(messages, shouldPersist: false)
    }
    updateAIChatThread(
      threadID,
      messages: messages,
      notifiesForNewAssistantMessages: notifiesForNewAssistantMessages
    )
    if shouldPersist {
      persistAIChatTranscript()
    }
  }

  func replaceAIChatPendingTurn(
    _ pendingTurn: AIChatPendingTurn?,
    in threadID: UUID,
    transcriptURL: URL? = nil,
    shouldPersist: Bool
  ) {
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    guard let thread = aiChatThread(
      threadID,
      transcriptURL: targetTranscriptURL
    ) else { return }
    updateAIChatThread(
      threadID,
      messages: thread.messages,
      transcriptURL: targetTranscriptURL,
      shouldPersist: shouldPersist,
      pendingTurnUpdate: .replace(pendingTurn),
      recordsMessageMutation: false
    )
  }

  func clearAIChatPendingTurn(
    _ runID: String,
    in threadID: UUID,
    transcriptURL: URL? = nil,
    shouldPersist: Bool
  ) {
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    guard let pendingTurn = aiChatThread(
      threadID,
      transcriptURL: targetTranscriptURL
    )?.pendingTurn,
          pendingTurn.runID == runID || pendingTurn.historyCorrelationID == runID
    else {
      return
    }
    replaceAIChatPendingTurn(
      nil,
      in: threadID,
      transcriptURL: targetTranscriptURL,
      shouldPersist: shouldPersist
    )
  }

  func openClawSessionKey(for threadID: UUID) -> String? {
    guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }) else { return nil }
    let thread = aiChatThreads[index]
    guard thread.runtime == .openClaw else { return thread.sessionKey }
    let sessionKey = Self.agentScopedOpenClawSessionKey(thread.sessionKey, agentID: openClawAgentID)
    if sessionKey != thread.sessionKey {
      aiChatThreads[index] = thread.replacingAIChatMetadata(sessionKey: sessionKey)
      if selectedAIChatThreadID == threadID {
        openClawSessionKey = sessionKey
      }
      persistAIChatTranscript()
    }
    return sessionKey
  }

  private func aiChatThreadID(containing messageID: UUID) -> UUID? {
    if let selectedAIChatThreadID,
       aiChatMessages.contains(where: { $0.id == messageID }) {
      return selectedAIChatThreadID
    }
    return aiChatThreads.first { thread in
      thread.messages.contains(where: { $0.id == messageID })
    }?.id
  }

  func aiChatPendingUserMessageIDs(for threadID: UUID) -> [UUID] {
    aiChatPendingUserMessageIDsByThreadID[threadID] ?? []
  }

  func enqueueAIChatUserMessage(_ messageID: UUID, in threadID: UUID) {
    aiChatPendingUserMessageIDsByThreadID[threadID, default: []].append(messageID)
    syncSelectedAIChatSendState()
  }

  func removeFirstPendingAIChatUserMessage(in threadID: UUID) {
    guard var pending = aiChatPendingUserMessageIDsByThreadID[threadID], !pending.isEmpty else {
      syncSelectedAIChatSendState()
      return
    }
    pending.removeFirst()
    if pending.isEmpty {
      aiChatPendingUserMessageIDsByThreadID.removeValue(forKey: threadID)
    } else {
      aiChatPendingUserMessageIDsByThreadID[threadID] = pending
    }
    syncSelectedAIChatSendState()
  }

  func removePendingAIChatUserMessage(_ messageID: UUID, in threadID: UUID) {
    guard var pending = aiChatPendingUserMessageIDsByThreadID[threadID] else { return }
    pending.removeAll { $0 == messageID }
    if pending.isEmpty {
      aiChatPendingUserMessageIDsByThreadID.removeValue(forKey: threadID)
    } else {
      aiChatPendingUserMessageIDsByThreadID[threadID] = pending
    }
    syncSelectedAIChatSendState()
  }

  func removeAllPendingAIChatUserMessages(in threadID: UUID) {
    aiChatPendingUserMessageIDsByThreadID.removeValue(forKey: threadID)
    syncSelectedAIChatSendState()
  }

  func removeAllPendingAIChatUserMessages() {
    aiChatPendingUserMessageIDsByThreadID.removeAll()
    syncSelectedAIChatSendState()
  }

  func syncSelectedAIChatSendState() {
    let previousSendingThreadIDs = aiChatSendingThreadIDs
    aiChatSendingThreadIDs = Set(drainingAIChatThreadIDs.filter {
      isAIChatRuntimeStateVisible(for: $0)
        && !aiChatPendingUserMessageIDs(for: $0).isEmpty
    })
    noteChatTurnTransitions(from: previousSendingThreadIDs, to: aiChatSendingThreadIDs)
    guard let selectedAIChatThreadID else {
      isSendingAIChatMessage = false
      aiChatQueuedMessageCount = 0
      aiChatRequestStartedAt = nil
      return
    }
    let exposesRuntimeState = isAIChatRuntimeStateVisible(for: selectedAIChatThreadID)
    isSendingAIChatMessage = exposesRuntimeState
      && aiChatSendingThreadIDs.contains(selectedAIChatThreadID)
    aiChatQueuedMessageCount = exposesRuntimeState
      ? aiChatPendingUserMessageIDs(for: selectedAIChatThreadID).count
      : 0
    aiChatRequestStartedAt = exposesRuntimeState
      ? aiChatRequestStartedAtByThreadID[selectedAIChatThreadID]
      : nil
  }

  nonisolated static func aiChatSendFailureText(from error: Error) -> String {
    let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? "AI chat message failed to send." : message
  }

  func beginCorpusChangeObservation(
    corpusRoot requestedCorpusRoot: URL? = nil
  ) async -> CorpusChangeObservation {
    let serial = corpusFileEventSerial
    guard let corpusRoot = requestedCorpusRoot ?? corpusRoot else {
      return CorpusChangeObservation(
        eventSerial: serial,
        snapshot: Task { AIChatCorpusSnapshot(rootPath: "", files: [:]) }
      )
    }
    let root = corpusRoot.standardizedFileURL
    let startedAt = Date()
    let gate = aiChatCorpusSnapshotGateForTesting
    // Listing paths is fast (well under a second for ~10,000 files) and fixes
    // which files existed before the turn. Reading their text is not: a large
    // corpus held every turn at "Connecting" for tens of seconds. Small corpora
    // are still read before dispatch; large ones are read in the background.
    let listing = await Task.detached(priority: .userInitiated) {
      Self.aiChatCorpusSnapshotListing(corpusRoot: root)
    }.value
    let read = Task.detached(priority: .userInitiated) {
      if let gate { await gate() }
      return Self.aiChatCorpusSnapshot(
        corpusRoot: root,
        listing: listing,
        modifiedBefore: startedAt
      )
    }
    if listing.totalBytes <= Self.aiChatChangeSnapshotEagerReadMaxBytes, gate == nil {
      _ = await read.value
    }
    return CorpusChangeObservation(eventSerial: serial, snapshot: read)
  }

  func aiChatChangeSummary(
    since observation: CorpusChangeObservation,
    referencedIn reply: String,
    corpusRoot requestedCorpusRoot: URL? = nil
  ) async -> AIChatCorpusChangeSummary? {
    guard let corpusRoot = requestedCorpusRoot ?? corpusRoot else { return nil }
    let root = corpusRoot.standardizedFileURL
    let referencedPaths = aiChatReferencedChangeRelativePaths(
      in: reply,
      corpusRoot: root
    )
    let beforeAll = await observation.snapshot.value
    if self.corpusRoot?.standardizedFileURL.path != root.path {
      let afterSnapshot = await Task.detached(priority: .utility) {
        try? Self.aiChatCorpusSnapshot(corpusRoot: root)
      }.value
      guard var afterSnapshot else { return nil }
      afterSnapshot = AIChatCorpusSnapshot(
        rootPath: afterSnapshot.rootPath,
        files: afterSnapshot.files.filter { !beforeAll.unknownPaths.contains($0.key) }
      )
      return Self.aiChatChangeSummary(
        before: beforeAll,
        after: afterSnapshot
      ).map {
        attributedAIChatChangeSummary($0, referencedPaths: referencedPaths)
      }
    }
    for delay in Self.aiChatChangeSnapshotRetryDelays {
      // FSEvents can deliver several writes from one agent turn in adjacent
      // batches. Give the first batch one coalescing window so the summary and
      // incremental refresh see the whole edit set, not whichever path arrived
      // first.
      try? await Task.sleep(nanoseconds: delay > 0 ? delay : 150_000_000)
      var changedPaths = Set(recentCorpusFileEvents.lazy
        .filter { $0.serial > observation.eventSerial }
        .map(\.path))
      for relativePath in referencedPaths {
        let path = root.appendingPathComponent(relativePath).standardizedFileURL.path
        if !beforeAll.unknownPaths.contains(relativePath),
           (beforeAll.files[relativePath] != nil) != FileManager.default.fileExists(atPath: path) {
          changedPaths.insert(path)
        }
      }
      guard !changedPaths.isEmpty else { continue }
      let relativeChangedPaths = Set(changedPaths.compactMap { path -> String? in
        let prefix = root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
      }).subtracting(beforeAll.unknownPaths)
      guard !relativeChangedPaths.isEmpty else { continue }
      let afterSnapshot = await Task.detached(priority: .utility) {
        try? Self.aiChatCorpusSnapshot(corpusRoot: root, relativePaths: relativeChangedPaths)
      }.value
      guard let afterSnapshot else { continue }
      let beforeSnapshot = beforeAll.filtered(to: relativeChangedPaths)
      if let summary = Self.aiChatChangeSummary(before: beforeSnapshot, after: afterSnapshot) {
        return attributedAIChatChangeSummary(summary, referencedPaths: referencedPaths)
      }
    }
    return nil
  }

  func recordCorpusFileEvents(_ paths: [String]) {
    guard let corpusRoot else { return }
    let rootPrefix = corpusRoot.standardizedFileURL.path + "/"
    for rawPath in paths {
      let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
      guard path.hasPrefix(rootPrefix) else { continue }
      corpusFileEventSerial += 1
      recentCorpusFileEvents.append((corpusFileEventSerial, path))
    }
    if recentCorpusFileEvents.count > 4_096 {
      recentCorpusFileEvents.removeFirst(recentCorpusFileEvents.count - 2_048)
    }
  }

  nonisolated static func classifyCorpusFileEvents(
    _ paths: [String],
    corpusRoot: URL
  ) -> CorpusFileEventClassification {
    let root = corpusRoot.standardizedFileURL.path
    let rootPrefix = root + "/"
    let contentExtensions = Set(["org", "org2", "md", "csv", "canvas"])
    var contentPaths: [String] = []
    var seenContentPaths = Set<String>()
    var pdfPreviewPaths: [String] = []
    var seenPDFPreviewPaths = Set<String>()
    var mediaPreviewPaths: [String] = []
    var seenMediaPreviewPaths = Set<String>()
    var hasAgentRunStateChanges = false
    var hasConfigurationChanges = false
    var hasAIChatInboxChanges = false
    var hasAIChatTranscriptChanges = false
    var hasAIChatLiveChanges = false

    for rawPath in paths {
      let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
      guard path.hasPrefix(rootPrefix) else { continue }
      // State under .celorga/ is classified like the legacy .org2/ layout.
      let relativePath = CelorgaNames.legacyStateRelativePath(String(path.dropFirst(rootPrefix.count)))
      if CelorgaNames.isConfigFileName(relativePath)
          || relativePath == ".org2/app.css"
          || relativePath == "org2-app.css" {
        hasConfigurationChanges = true
        continue
      }
      if relativePath.hasPrefix(".org2/runs/"),
         ["org", "org2"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
        hasAgentRunStateChanges = true
        continue
      }
      if relativePath.hasPrefix(".org2/openclaw-chat.store/\(AIChatLiveHostDirectory.directoryName)/") {
        // Presence records change every second during a remote turn. They
        // never require re-reading the committed transcript.
        hasAIChatLiveChanges = true
        continue
      }
      if relativePath == ".org2/openclaw-chat.json" || relativePath.hasPrefix(".org2/openclaw-chat.store/") {
        hasAIChatTranscriptChanges = true
        continue
      }
      if relativePath.hasPrefix(".org2/ai-chat-inbox/") {
        hasAIChatInboxChanges = true
        continue
      }
      if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf",
         !isDefaultIgnoredSyncArtifactPath(path),
         seenPDFPreviewPaths.insert(path).inserted {
        pdfPreviewPaths.append(path)
        continue
      }
      // Web page assets refresh a rendered HTML file the same way.
      if isMediaFile(path) || ["html", "htm", "xhtml", "css", "js", "mjs", "svg", "json"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
         !isDefaultIgnoredSyncArtifactPath(path),
         seenMediaPreviewPaths.insert(path).inserted {
        mediaPreviewPaths.append(path)
        continue
      }
      guard contentExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
            !isDefaultIgnoredSyncArtifactPath(path),
            seenContentPaths.insert(path).inserted
      else {
        continue
      }
      contentPaths.append(path)
    }

    return CorpusFileEventClassification(
      contentPaths: contentPaths,
      pdfPreviewPaths: pdfPreviewPaths,
      mediaPreviewPaths: mediaPreviewPaths,
      hasAgentRunStateChanges: hasAgentRunStateChanges,
      hasConfigurationChanges: hasConfigurationChanges,
      hasAIChatInboxChanges: hasAIChatInboxChanges,
      hasAIChatTranscriptChanges: hasAIChatTranscriptChanges,
      hasAIChatLiveChanges: hasAIChatLiveChanges
    )
  }

  private func attributedAIChatChangeSummary(
    _ summary: AIChatCorpusChangeSummary,
    referencedIn reply: String
  ) -> AIChatCorpusChangeSummary {
    attributedAIChatChangeSummary(
      summary,
      referencedPaths: aiChatReferencedChangeRelativePaths(in: reply)
    )
  }

  private func attributedAIChatChangeSummary(
    _ summary: AIChatCorpusChangeSummary,
    referencedPaths: Set<String>
  ) -> AIChatCorpusChangeSummary {
    guard !referencedPaths.isEmpty else { return summary }
    let filteredFiles = summary.files.filter { referencedPaths.contains($0.relativePath) }
    return filteredFiles.isEmpty ? summary : AIChatCorpusChangeSummary(files: filteredFiles)
  }

  private func aiChatReferencedChangeRelativePaths(
    in reply: String,
    corpusRoot requestedCorpusRoot: URL? = nil
  ) -> Set<String> {
    guard let corpusRoot = requestedCorpusRoot ?? corpusRoot else { return [] }
    let rootPath = Self.trimTrailingSlashes(corpusRoot.standardizedFileURL.path)
    var paths = Set<String>()

    for reference in AIChatFileReference.extract(from: reply, limit: 24) {
      if let relativePath = aiChatRelativePathForReference(reference.path, corpusRootPath: rootPath) {
        paths.insert(relativePath)
      }
    }

    return paths
  }

  private func aiChatRelativePathForReference(_ rawPath: String, corpusRootPath rootPath: String) -> String? {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }

    var candidates: [String] = []
    if let localPath = localPathForOpenClawReference(path) {
      candidates.append(localPath)
    }

    if let remoteRoot = effectiveOpenClawRemoteCorpusPath().map(Self.trimTrailingSlashes) {
      let normalizedPath = Self.trimTrailingSlashes(path)
      if normalizedPath == remoteRoot {
        candidates.append(rootPath)
      } else if normalizedPath.hasPrefix(remoteRoot + "/") {
        candidates.append(rootPath + "/" + String(normalizedPath.dropFirst(remoteRoot.count + 1)))
      }
    }

    if path.hasPrefix("~/") {
      candidates.append(NSHomeDirectory() + "/" + String(path.dropFirst(2)))
    } else if NSString(string: path).isAbsolutePath {
      candidates.append(path)
    } else {
      candidates.append(rootPath + "/" + path)
    }

    for candidate in candidates {
      let normalized = Self.trimTrailingSlashes(URL(fileURLWithPath: candidate).standardizedFileURL.path)
      if normalized == rootPath {
        return ""
      }
      if normalized.hasPrefix(rootPath + "/") {
        return String(normalized.dropFirst(rootPath.count + 1))
      }
    }
    return nil
  }

  func refreshAfterAIChatChanges(_ summary: AIChatCorpusChangeSummary) async {
    guard let corpusRoot else { return }
    let root = corpusRoot.standardizedFileURL
    let changedFiles = summary.files.map { root.appendingPathComponent($0.relativePath).standardizedFileURL.path }
    let generatedBriefTitle = pendingNodeBriefTitle
    let generatedBriefRelativePath = pendingNodeBriefArtifactRelativePath.flatMap { pending in
      summary.files.contains(where: { $0.relativePath == pending }) ? pending : nil
    }
    for file in changedFiles {
      invalidateCanonicalDocumentCache(for: file)
    }

    if let selectedEntrySource,
       changedFiles.contains(URL(fileURLWithPath: selectedEntrySource.file).standardizedFileURL.path),
       let selectedLocation {
      await loadEntrySource(for: selectedLocation)
    }

    scheduleIncrementalCorpusRefresh(changedFiles)

    if let generatedBriefRelativePath {
      let artifactURL = root.appendingPathComponent(generatedBriefRelativePath).standardizedFileURL
      openNodeBriefArtifact(
        url: artifactURL,
        relativePath: generatedBriefRelativePath,
        title: generatedBriefTitle ?? artifactURL.deletingPathExtension().lastPathComponent,
        modifiedAt: nil
      )
      scheduleCurrentNodeBriefArtifactRefresh()
    }
  }

  public func setWorkspaceRealtimeRefreshActive(_ isActive: Bool) {
    guard isWorkspaceRealtimeRefreshActive != isActive else { return }
    isWorkspaceRealtimeRefreshActive = isActive
    restartAIChatRepairTimer()
    if isActive {
      workspaceActivationRefreshTask?.cancel()
      workspaceActivationRefreshTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: Self.applicationActivationRefreshDelayNanoseconds)
        guard !Task.isCancelled,
              let self,
              self.isWorkspaceRealtimeRefreshActive
        else { return }
        self.workspaceDidBecomeActive()
        self.workspaceActivationRefreshTask = nil
      }
    } else {
      workspaceActivationRefreshTask?.cancel()
      workspaceActivationRefreshTask = nil
      sourceAutoSyncActivationTask?.cancel()
      sourceAutoSyncActivationTask = nil
      automationSchedulerActivationTask?.cancel()
      automationSchedulerActivationTask = nil
      mountedCorpusEventRefreshTask?.cancel()
      mountedCorpusEventRefreshTask = nil
      workspaceSurfaceRefreshTasks.values.forEach { $0.task.cancel() }
      workspaceSurfaceRefreshTasks = [:]
    }
  }
}
