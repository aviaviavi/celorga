import AppKit
import SwiftUI
import WebKit

struct AIChatTranscriptRenderedBody: Equatable {
  let source: String
  let expanded: Bool
  let html: String
  let plainText: String?
  let contexts: [AIChatTranscriptHTML.Context]
}

struct AIChatTranscriptRenderedReasoning: Equatable {
  let source: String
  let html: String
}

@MainActor
enum AIChatTranscriptRenderedBodyCache {
  private final class Key: NSObject {
    let messageID: UUID
    let sourcePath: String
    let expanded: Bool

    init(messageID: UUID, sourcePath: String, expanded: Bool) {
      self.messageID = messageID
      self.sourcePath = sourcePath
      self.expanded = expanded
    }

    override var hash: Int {
      var hasher = Hasher()
      hasher.combine(messageID)
      hasher.combine(sourcePath)
      hasher.combine(expanded)
      return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? Key else { return false }
      return messageID == other.messageID
        && sourcePath == other.sourcePath
        && expanded == other.expanded
    }
  }

  private final class Value: NSObject {
    let body: AIChatTranscriptRenderedBody

    init(_ body: AIChatTranscriptRenderedBody) {
      self.body = body
    }
  }

  private static let cache: NSCache<Key, Value> = {
    let cache = NSCache<Key, Value>()
    cache.countLimit = 512
    cache.totalCostLimit = 64 * 1_024 * 1_024
    return cache
  }()

  static func body(
    messageID: UUID,
    source: String,
    expanded: Bool,
    sourcePath: String
  ) -> AIChatTranscriptRenderedBody? {
    let key = Key(messageID: messageID, sourcePath: sourcePath, expanded: expanded)
    guard let body = cache.object(forKey: key)?.body,
          body.source == source
    else { return nil }
    return body
  }

  static func install(
    _ body: AIChatTranscriptRenderedBody,
    messageID: UUID,
    sourcePath: String
  ) {
    let contextCost = body.contexts.reduce(0) {
      $0 + $1.title.utf8.count + $1.kind.utf8.count + 32
    }
    let cost = max(
      1,
      body.source.utf8.count
        + body.html.utf8.count
        + (body.plainText?.utf8.count ?? 0)
        + contextCost
    )
    cache.setObject(
      Value(body),
      forKey: Key(messageID: messageID, sourcePath: sourcePath, expanded: body.expanded),
      cost: cost
    )
  }

  static func removeAllForTesting() {
    cache.removeAllObjects()
  }
}

/// One DOM and one native WebKit scroll view own the entire visible transcript.
/// Selection, autoscroll while dragging, and wheel routing are WebKit behavior.
struct AIChatTranscriptDocument: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.openOrgFileReference) private var openFileReference
  @Environment(\.openWorkspaceWebLink) private var openWebLink
  @Environment(\.orgRoamLinkResolver) private var linkResolver
  @ObservedObject private var liveState: AIChatLiveState
  @State private var rendered: [UUID: AIChatTranscriptRenderedBody] = [:]
  @State private var renderedReasoning: [UUID: AIChatTranscriptRenderedReasoning] = [:]
  @State private var preparedLive: PreparedLive?
  /// One disclosure expands both the earlier reply text and the activity feed.
  @State private var showsLiveActivity = false
  @State private var previewedAttachment: AIChatAttachment?
  @State private var expandedMessageIDs: Set<UUID> = []
  @State private var copiedMessageID: UUID?
  @State private var copyFeedbackTask: Task<Void, Never>?
  let items: [AIChatRoomTranscriptItem]
  let compact: Bool
  let earlierTitle: String?
  let searchMessageID: UUID?
  let searchGeneration: Int
  let onEarlier: () -> Void
  let onPosition: (Double) -> Void

  init(
    liveState: AIChatLiveState,
    items: [AIChatRoomTranscriptItem],
    compact: Bool,
    earlierTitle: String?,
    searchMessageID: UUID?,
    searchGeneration: Int,
    onEarlier: @escaping () -> Void,
    onPosition: @escaping (Double) -> Void
  ) {
    _liveState = ObservedObject(wrappedValue: liveState)
    self.items = items
    self.compact = compact
    self.earlierTitle = earlierTitle
    self.searchMessageID = searchMessageID
    self.searchGeneration = searchGeneration
    self.onEarlier = onEarlier
    self.onPosition = onPosition
  }

  private struct RenderInput: Equatable {
    let id: UUID
    let text: String
    let formatted: Bool
    let expanded: Bool
  }
  private struct RenderKey: Equatable { let sourcePath: String; let inputs: [RenderInput] }
  private struct ReasoningInput: Equatable {
    let id: UUID
    let text: String
  }
  private struct ReasoningRenderKey: Equatable {
    let sourcePath: String
    let inputs: [ReasoningInput]
  }
  private struct LiveInput: Equatable {
    let threadID: UUID
    let startedAt: Date?
    let lastEventAt: Date?
    let runtime: AIChatRuntime
    let destinationTitle: String
    let connectionState: OpenClawGatewayConnectionState
    let connectionDetail: String?
    let runID: String?
    let preparation: AIChatLiveTextPreparationInput
  }
  private struct PreparedLive {
    let threadID: UUID
    let startedAt: Date?
    let text: String?
    let textHTML: String?
    let hasEarlierText: Bool
    let reasoning: String?
    let reasoningHTML: String?
    let activities: [AIChatActivityFeedItem]
  }
  private struct MessageSlot {
    let message: AIChatMessage
    let isRoomResponse: Bool
  }
  private var messageSlots: [MessageSlot] {
    items.flatMap { item in
      switch item {
      case .message(let message): return [MessageSlot(message: message, isRoomResponse: false)]
      case .round(let round):
        return [MessageSlot(message: round.trigger, isRoomResponse: false)]
          + round.expectedDestinationIDs.compactMap { destination in
            round.response(forDestinationID: destination).map {
              MessageSlot(message: $0, isRoomResponse: true)
            }
        }
      }
    }
  }
  private var messages: [AIChatMessage] { messageSlots.map(\.message) }
  private var sourcePath: String {
    (store.corpusRoot ?? FileManager.default.temporaryDirectory).appendingPathComponent("chat-message.org").path
  }

  private var liveInput: LiveInput? {
    guard let threadID = store.selectedAIChatThreadID else { return nil }
    guard store.isSendingAIChatMessage else {
      // A turn another OpenOrg host is running for this conversation.
      guard let remote = store.aiChatRemoteLiveTurn(for: threadID) else { return nil }
      let destination = remote.turn.destinationName
        ?? store.aiChatDestinationTitle(store.selectedAIChatActiveDestinationID)
      let runningHost = store.aiChatHarnessHostName(for: threadID) ?? remote.host.name
      return LiveInput(
        threadID: threadID,
        startedAt: remote.turn.startedAt,
        lastEventAt: remote.updatedAt,
        runtime: store.selectedAIChatActiveRuntime,
        destinationTitle: "\(destination) on \(runningHost)",
        connectionState: .connected,
        connectionDetail: "Running on \(runningHost)",
        runID: nil,
        preparation: AIChatLiveTextPreparationInput(
          rawText: remote.turn.streamingReply,
          showsAll: showsLiveActivity,
          hasOmittedPrefix: remote.turn.streamingReply.hasPrefix("…"),
          reasoning: remote.turn.reasoning,
          reasoningHasOmittedPrefix: remote.turn.reasoning.hasPrefix("…"),
          activities: remote.turn.activities
        )
      )
    }
    let snapshot = liveState.presentationSnapshot(for: threadID)
    return LiveInput(
      threadID: threadID,
      startedAt: store.aiChatRequestStartedAt,
      lastEventAt: liveState.lastEventAt(for: threadID),
      runtime: store.selectedAIChatActiveRuntime,
      destinationTitle: store.aiChatDestinationTitle(store.selectedAIChatActiveDestinationID),
      connectionState: liveState.connectionState(for: threadID),
      connectionDetail: liveState.connectionDetail(for: threadID),
      runID: liveState.activeRunID(for: threadID),
      preparation: AIChatLiveTextPreparationInput(
        rawText: snapshot.streamingReply,
        showsAll: showsLiveActivity,
        hasOmittedPrefix: snapshot.isStreamingReplyTruncated,
        reasoning: snapshot.reasoning,
        reasoningHasOmittedPrefix: snapshot.isReasoningTruncated,
        activities: liveState.runActivities(for: threadID)
      )
    )
  }

  var body: some View {
    let liveInput = liveInput
    let inputs = messages.map { message in
      RenderInput(id: message.id,
        text: message.content,
        formatted: message.role == .assistant,
        expanded: expandedMessageIDs.contains(message.id))
    }
    let reasoningInputs = messages.compactMap { message -> ReasoningInput? in
      guard let trace = message.responseTrace,
            let reasoning = AIChatProgressPresentation.reasoningText(from: trace.reasoning),
            !reasoning.isEmpty
      else { return nil }
      return ReasoningInput(id: message.id, text: reasoning)
    }
    let entries = zip(messageSlots, inputs).map { slot, input in
      let message = slot.message
      let excerpt = AIChatMessageBodyExcerpt(
        message.content,
        utf8ByteLimit: input.expanded ? nil : AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit
      )
      let resolved = rendered[message.id].flatMap {
        $0.source == input.text && $0.expanded == input.expanded ? $0 : nil
      } ?? cachedRenderedBody(input: input)
        ?? cachedPreparedBody(message: message, input: input)
      let isPreparing = message.role == .user && resolved == nil
      let fallbackPlainText = resolved == nil && !isPreparing ? excerpt.text : nil
      let plainText = resolved?.plainText ?? fallbackPlainText
      return AIChatTranscriptHTML.Entry(
        id: message.id.uuidString.lowercased(), role: message.role.rawValue,
        title: title(message), timestamp: AIChatMessageTimestampPresentation.displayText(for: message.createdAt),
        html: plainText == nil
          ? resolved?.html ?? AIChatDocumentHTML.plain(isPreparing ? "" : excerpt.text)
          : "",
        plainText: plainText,
        preparing: isPreparing,
        contexts: resolved?.contexts ?? [],
        attachments: message.attachments.map(AIChatTranscriptHTML.Attachment.init),
        failure: message.sendFailure,
        queued: store.isAIChatMessageQueued(message.id),
        canSteer: store.canSteerQueuedAIChatMessage(message.id),
        isRoomResponse: slot.isRoomResponse,
        copied: copiedMessageID == message.id,
        isTruncated: excerpt.isTruncated,
        responseTrace: message.responseTrace.flatMap { trace in
          let reasoningHTML = renderedReasoning[message.id].flatMap {
            $0.source == AIChatProgressPresentation.reasoningText(from: trace.reasoning)
              ? $0.html
              : nil
          }
          return AIChatTranscriptHTML.Trace(trace, reasoningHTML: reasoningHTML)
        },
        changeSummary: message.changeSummary.map(AIChatTranscriptHTML.ChangeSummary.init),
        startWork: AIChatTranscriptHTML.StartWork(message, corpusRoot: store.corpusRoot)
      )
    }
    AIChatTranscriptWebView(
      payload: AIChatTranscriptHTML.Payload(
        thread: store.selectedAIChatThreadID?.uuidString ?? "empty",
        entries: entries, earlier: earlierTitle,
        sending: store.isSendingAIChatMessage,
        status: store.aiChatMessages.isEmpty ? "Ask about your workspace, or request an edit to review." : store.aiChatStatusText,
        search: searchMessageID?.uuidString.lowercased(), searchGeneration: searchGeneration,
        initialPosition: store.aiChatScrollPosition(isAssistantPanel: compact) ?? 1,
        compact: compact,
        live: liveInput.map(livePayload),
        mentions: AIChatDestinationRouting.recognizedMentionTokens(destinations: store.aiChatDestinations),
        stalled: liveInput == nil
          ? store.selectedAIChatThreadID
            .flatMap(store.aiChatUnobservedTurn(for:))
            .map(AIChatTranscriptHTML.Stalled.init)
          : nil
      ), attachments: messages.flatMap(\.attachments),
      sourcePath: sourcePath, corpusRoot: store.corpusRoot,
      linkResolver: linkResolver, openFileReference: openFileReference,
      openWebLink: openWebLink,
      onAction: handleAction,
      onPosition: { thread, position in
        guard thread == store.selectedAIChatThreadID?.uuidString else { return }
        store.recordAIChatScrollPosition(position, isAssistantPanel: compact, threadID: store.selectedAIChatThreadID)
        onPosition(position)
      }
    )
    .task(id: RenderKey(sourcePath: sourcePath, inputs: inputs)) {
      let ids = Set(inputs.map(\.id))
      var nextRendered = rendered.filter { ids.contains($0.key) }
      for (message, input) in zip(messages, inputs)
      where nextRendered[input.id]?.source != input.text
        || nextRendered[input.id]?.expanded != input.expanded {
        if let cached = cachedRenderedBody(input: input)
          ?? cachedPreparedBody(message: message, input: input) {
          nextRendered[input.id] = cached
          AIChatTranscriptRenderedBodyCache.install(
            cached,
            messageID: input.id,
            sourcePath: sourcePath
          )
        }
      }
      rendered = nextRendered
      let unresolvedInputs = inputs.filter {
        nextRendered[$0.id]?.source != $0.text
          || nextRendered[$0.id]?.expanded != $0.expanded
      }
      // A cold user bubble should never wait behind formatted assistant HTML.
      // Assistant excerpts are already readable while their richer rendering finishes.
      let prioritizedInputs = unresolvedInputs.filter { !$0.formatted }
        + unresolvedInputs.filter(\.formatted)
      for input in prioritizedInputs {
        do {
          try Task.checkCancellation()
          let prepared = await Task.detached(priority: .userInitiated) {
            let excerpt = AIChatMessageBodyExcerpt(
              input.text,
              utf8ByteLimit: input.expanded ? nil : AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit
            )
            if input.formatted {
              return (AIChatMessageOrgNormalizer.normalized(excerpt.text), [AIChatTranscriptHTML.Context]())
            }
            let presentation = AIChatContextPresentation(excerpt.text)
            return (presentation.userText, presentation.contexts.map(AIChatTranscriptHTML.Context.init))
          }.value
          let html = input.formatted
            ? try await AIChatDocumentRenderCache.shared.render(prepared.0, sourcePath: sourcePath)
            : AIChatDocumentHTML.plain(prepared.0)
          try Task.checkCancellation()
          let renderedBody = AIChatTranscriptRenderedBody(
            source: input.text,
            expanded: input.expanded,
            html: html,
            plainText: input.formatted ? nil : prepared.0,
            contexts: prepared.1
          )
          AIChatTranscriptRenderedBodyCache.install(
            renderedBody,
            messageID: input.id,
            sourcePath: sourcePath
          )
          nextRendered[input.id] = renderedBody
          rendered = nextRendered
        } catch is CancellationError { return }
        catch { /* The selectable plain body remains available. */ }
      }
    }
    .task(id: ReasoningRenderKey(sourcePath: sourcePath, inputs: reasoningInputs)) {
      let ids = Set(reasoningInputs.map(\.id))
      var nextRendered = renderedReasoning.filter { ids.contains($0.key) }
      renderedReasoning = nextRendered
      for input in reasoningInputs
      where nextRendered[input.id]?.source != input.text {
        do {
          try Task.checkCancellation()
          let normalized = await Task.detached(priority: .utility) {
            AIChatMessageOrgNormalizer.normalized(input.text)
          }.value
          let html = try await AIChatDocumentRenderCache.shared.render(
            normalized,
            sourcePath: sourcePath
          )
          try Task.checkCancellation()
          nextRendered[input.id] = AIChatTranscriptRenderedReasoning(
            source: input.text,
            html: html
          )
          renderedReasoning = nextRendered
        } catch is CancellationError { return }
        catch { /* The selectable plain reasoning remains available. */ }
      }
    }
    .task(id: liveInput) {
      guard let liveInput else {
        preparedLive = nil
        showsLiveActivity = false
        return
      }
      if preparedLive?.threadID != liveInput.threadID || preparedLive?.startedAt != liveInput.startedAt {
        preparedLive = nil
      }
      do {
        try await Task.sleep(for: .milliseconds(24))
      } catch {
        return
      }
      let prepared = await AIChatLiveTextPreparationCoordinator.shared.prepare(
        streamID: liveInput.threadID,
        input: liveInput.preparation
      )
      guard !Task.isCancelled else { return }
      let text = prepared?.text?.text
      let reasoning = prepared?.reasoning
      async let textHTML = renderedProgressHTML(text)
      async let reasoningHTML = renderedProgressHTML(reasoning)
      let renderedTextHTML = await textHTML
      let renderedReasoningHTML = await reasoningHTML
      guard !Task.isCancelled else { return }
      preparedLive = PreparedLive(
        threadID: liveInput.threadID,
        startedAt: liveInput.startedAt,
        text: text,
        textHTML: renderedTextHTML,
        hasEarlierText: prepared?.text?.hasEarlierText ?? false,
        reasoning: reasoning,
        reasoningHTML: renderedReasoningHTML,
        activities: prepared?.activityFeedItems ?? []
      )
    }
    .sheet(item: $previewedAttachment) { attachment in
      AIChatAttachmentPreviewView(attachment: attachment)
    }
    .onDisappear {
      copyFeedbackTask?.cancel()
      copyFeedbackTask = nil
    }
  }

  private func cachedPreparedBody(
    message: AIChatMessage,
    input: RenderInput
  ) -> AIChatTranscriptRenderedBody? {
    guard let prepared = AIChatTranscriptHTML.cachedPreparedBody(
      for: message,
      expanded: input.expanded
    ) else { return nil }
    return AIChatTranscriptRenderedBody(
      source: input.text,
      expanded: input.expanded,
      html: prepared.html,
      plainText: prepared.plainText,
      contexts: prepared.contexts
    )
  }

  private func cachedRenderedBody(
    input: RenderInput
  ) -> AIChatTranscriptRenderedBody? {
    AIChatTranscriptRenderedBodyCache.body(
      messageID: input.id,
      source: input.text,
      expanded: input.expanded,
      sourcePath: sourcePath
    )
  }

  private func renderedProgressHTML(_ text: String?) async -> String? {
    guard let text, !text.isEmpty else { return nil }
    do {
      let normalized = await Task.detached(priority: .utility) {
        AIChatMessageOrgNormalizer.normalized(text)
      }.value
      return try await AIChatDocumentRenderCache.shared.render(
        normalized,
        sourcePath: sourcePath
      )
    } catch {
      return nil
    }
  }

  private func title(_ message: AIChatMessage) -> String {
    let base: String
    if message.role == .user {
      if !message.audienceDestinationIDs.isEmpty {
        base = "You → " + message.audienceDestinationIDs.map(store.aiChatDestinationTitle).joined(separator: " + ")
      } else {
        base = message.audience.map { "You → " + $0.title } ?? "You"
      }
    } else {
      base = message.authorLabel ?? message.authorDestinationID.map(store.aiChatDestinationTitle)
        ?? message.authorRuntime?.title ?? (message.role == .system ? WorkspaceProductIdentity.displayName : store.selectedAIChatDestinationTitle)
    }
    guard let caption = store.aiChatProvenanceCaption(for: message) else { return base }
    return "\(base) · \(caption)"
  }

  private func livePayload(_ input: LiveInput) -> AIChatTranscriptHTML.Live {
    let now = Date()
    let presentation = AIChatTypingIndicatorView(
      startedAt: input.startedAt,
      lastEventAt: input.lastEventAt,
      runtime: input.runtime,
      destinationTitle: input.destinationTitle,
      connectionState: input.connectionState,
      connectionDetail: input.connectionDetail,
      runID: input.runID,
      streamingReply: input.preparation.rawText,
      streamingReplyHasOmittedPrefix: input.preparation.hasOmittedPrefix,
      reasoning: input.preparation.reasoning,
      reasoningHasOmittedPrefix: input.preparation.reasoningHasOmittedPrefix,
      activities: input.preparation.activities,
      compact: compact,
      onStop: {}
    )
    let prepared = preparedLive?.threadID == input.threadID && preparedLive?.startedAt == input.startedAt
      ? preparedLive
      : nil
    let displayTitle = input.destinationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = displayTitle.isEmpty ? input.runtime.title : displayTitle
    let referenceDate = input.lastEventAt ?? input.startedAt
    let livenessAge = referenceDate.map { max(0, now.timeIntervalSince($0)) } ?? 0
    let thresholds = AIChatTypingIndicatorView.livenessThresholdPresentation(
      runtime: input.runtime,
      displayTitle: resolvedTitle
    )
    let animates = input.connectionState != .disconnected
      && (input.connectionState != .connected || input.runID == nil
        || thresholds.stalledAnimates
        || livenessAge < AIChatTypingIndicatorView.stalledRunInterval)
    return AIChatTranscriptHTML.Live(
      title: presentation.statusTitle(now: now),
      detail: presentation.statusDetail(now: now),
      quietTitle: thresholds.quietTitle,
      quietDetail: thresholds.quietDetail,
      stalledTitle: thresholds.stalledTitle,
      stalledDetail: thresholds.stalledDetail,
      stalledAnimates: thresholds.stalledAnimates,
      startedAtMilliseconds: input.startedAt.map { $0.timeIntervalSince1970 * 1_000 },
      lastEventAtMilliseconds: referenceDate.map { $0.timeIntervalSince1970 * 1_000 },
      usesLivenessThresholds: input.connectionState == .connected && input.runID != nil,
      animates: animates,
      text: prepared?.text,
      textHTML: prepared?.textHTML,
      hasEarlierText: prepared?.hasEarlierText ?? false,
      textExpanded: showsLiveActivity,
      reasoning: prepared?.reasoning,
      reasoningHTML: prepared?.reasoningHTML,
      activities: (prepared?.activities ?? []).map(AIChatTranscriptHTML.Activity.init),
      activityExpanded: showsLiveActivity
    )
  }

  private func handleAction(_ action: String, _ id: String?, _ detail: String?) {
    if action == "restored" { store.completeAIChatScrollRestoration(threadID: store.selectedAIChatThreadID); return }
    if action == "earlier" { onEarlier(); return }
    if action == "stop" { Task { await store.stopAIChatRun() }; return }
    if action == "recheck" {
      // The message may be a hidden room dispatch copy, so it is not in `messages`.
      if let id, let uuid = UUID(uuidString: id) { Task { await store.retryAIChatMessage(uuid) } }
      return
    }
    if action == "liveActivityToggle" || action == "liveTextToggle" { showsLiveActivity.toggle(); return }
    guard let id, let uuid = UUID(uuidString: id), let message = messages.first(where: { $0.id == uuid }) else { return }
    switch action {
    case "copy":
      let input = AIChatMessageClipboard.Input(message)
      copyFeedbackTask?.cancel()
      copyFeedbackTask = Task { @MainActor in
        guard await AIChatMessageClipboard.copy(input), !Task.isCancelled else { return }
        copiedMessageID = uuid
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        if copiedMessageID == uuid { copiedMessageID = nil }
      }
    case "attachment":
      guard let detail, let attachmentID = UUID(uuidString: detail) else { return }
      previewedAttachment = message.attachments.first { $0.id == attachmentID }
    case "expand": expandedMessageIDs.insert(uuid)
    case "collapse": expandedMessageIDs.remove(uuid)
    case "retry": Task { await store.retryAIChatMessage(uuid) }
    case "edit": store.editQueuedAIChatMessage(uuid)
    case "delete": store.deleteQueuedAIChatMessage(uuid)
    case "steer": Task { await store.steerQueuedAIChatMessage(uuid) }
    case "reply": store.beginAIChatReply(to: uuid)
    default: break
    }
  }
}

enum AIChatTranscriptHTML {
  struct PreparedBody: Equatable {
    let html: String
    let plainText: String
    let contexts: [Context]
  }

  @MainActor
  static func cachedPreparedBody(
    for message: AIChatMessage,
    expanded: Bool
  ) -> PreparedBody? {
    guard !expanded else { return nil }
    let input = AIChatMessagePresentationInput(message)
    guard let cached = AIChatMessagePresentationCache.cachedPresentation(for: input) else {
      return nil
    }
    if message.role != .user {
      guard cached.body.org?.usesStructuredRendering != true,
            !cached.body.containsInlineSyntax
      else { return nil }
    }
    return PreparedBody(
      html: AIChatDocumentHTML.plain(cached.body.displayedText),
      plainText: cached.body.displayedText,
      contexts: cached.context.contexts.map(Context.init)
    )
  }

  struct Context: Codable, Equatable {
    let title: String
    let kind: String
    let isAutomatic: Bool

    init(_ context: AIChatPresentedContext) {
      title = context.title
      kind = context.kind
      isAutomatic = context.automaticPrompt != nil
    }
  }

  struct Attachment: Codable, Equatable {
    let id: String
    let fileName: String
    let mimeType: String
    let previewURL: String?

    init(_ attachment: AIChatAttachment) {
      id = attachment.id.uuidString.lowercased()
      fileName = attachment.fileName
      mimeType = attachment.mimeType
      previewURL = OrgHTMLLocalResourceSchemeHandler
        .chatAttachmentResourceURL(for: attachment)?
        .absoluteString
    }
  }

  struct Activity: Codable, Equatable {
    let title: String
    let detail: String?
    let latestDetail: String?
    let status: String

    init(_ item: AIChatActivityFeedItem) {
      title = item.title
      detail = item.detail
      latestDetail = item.latestDetail
      status = item.status.rawValue
    }
  }

  struct Trace: Codable, Equatable {
    let reasoning: String?
    let reasoningHTML: String?
    let activities: [Activity]
    let usage: AIChatTokenUsage?
    let context: OpenOrgContextTelemetry?

    init?(_ trace: AIChatResponseTrace, reasoningHTML: String? = nil) {
      guard !trace.isEmpty else { return nil }
      reasoning = AIChatProgressPresentation.reasoningText(from: trace.reasoning)
      self.reasoningHTML = reasoningHTML
      activities = AIChatActivityFeed.items(from: trace.activities).map(Activity.init)
      usage = trace.usage
      context = trace.context
    }
  }

  struct FileChange: Codable, Equatable {
    let relativePath: String
    let status: String
    let insertions: Int
    let deletions: Int

    init(_ change: AIChatCorpusFileChange) {
      relativePath = change.relativePath
      status = change.status.rawValue
      insertions = change.insertions
      deletions = change.deletions
    }
  }

  struct ChangeSummary: Codable, Equatable {
    let title: String
    let totalInsertions: Int
    let totalDeletions: Int
    let files: [FileChange]

    init(_ summary: AIChatCorpusChangeSummary) {
      title = summary.title
      totalInsertions = summary.totalInsertions
      totalDeletions = summary.totalDeletions
      files = summary.files.map(FileChange.init)
    }
  }

  struct Live: Codable, Equatable {
    let title: String
    let detail: String?
    let quietTitle: String
    let quietDetail: String
    let stalledTitle: String
    let stalledDetail: String
    let stalledAnimates: Bool
    let startedAtMilliseconds: Double?
    let lastEventAtMilliseconds: Double?
    let usesLivenessThresholds: Bool
    let animates: Bool
    let text: String?
    let textHTML: String?
    let hasEarlierText: Bool
    let textExpanded: Bool
    let reasoning: String?
    let reasoningHTML: String?
    let activities: [Activity]
    let activityExpanded: Bool

    init(
      title: String,
      detail: String?,
      quietTitle: String,
      quietDetail: String,
      stalledTitle: String,
      stalledDetail: String,
      stalledAnimates: Bool = false,
      startedAtMilliseconds: Double?,
      lastEventAtMilliseconds: Double?,
      usesLivenessThresholds: Bool,
      animates: Bool,
      text: String?,
      textHTML: String? = nil,
      hasEarlierText: Bool,
      textExpanded: Bool,
      reasoning: String?,
      reasoningHTML: String? = nil,
      activities: [Activity],
      activityExpanded: Bool
    ) {
      self.title = title
      self.detail = detail
      self.quietTitle = quietTitle
      self.quietDetail = quietDetail
      self.stalledTitle = stalledTitle
      self.stalledDetail = stalledDetail
      self.stalledAnimates = stalledAnimates
      self.startedAtMilliseconds = startedAtMilliseconds
      self.lastEventAtMilliseconds = lastEventAtMilliseconds
      self.usesLivenessThresholds = usesLivenessThresholds
      self.animates = animates
      self.text = text
      self.textHTML = textHTML
      self.hasEarlierText = hasEarlierText
      self.textExpanded = textExpanded
      self.reasoning = reasoning
      self.reasoningHTML = reasoningHTML
      self.activities = activities
      self.activityExpanded = activityExpanded
    }
  }

  struct Entry: Codable, Equatable {
    let id: String
    let role: String
    let title: String
    let timestamp: String
    let html: String
    let plainText: String?
    let preparing: Bool
    let contexts: [Context]
    let attachments: [Attachment]
    let failure: String?
    let queued: Bool
    let canSteer: Bool
    let isRoomResponse: Bool
    let copied: Bool
    let isTruncated: Bool
    let responseTrace: Trace?
    let changeSummary: ChangeSummary?
    /// A Start work prompt, shown as a compact card with the prompt folded.
    var startWork: StartWork? = nil
  }
  struct StartWork: Codable, Equatable {
    let title: String
    let source: String?

    /// The card for a user message that is a Start work prompt. Sources inside
    /// the corpus show as corpus-relative paths.
    init?(_ message: AIChatMessage, corpusRoot: URL?) {
      guard message.role == .user,
            let summary = HeadingWorkStatus.startWorkPromptSummary(in: message.content)
      else { return nil }
      title = summary.title
      let rootPrefix = corpusRoot.map { $0.standardizedFileURL.path + "/" }
      source = summary.source.map { source in
        guard let rootPrefix, source.hasPrefix(rootPrefix) else { return source }
        return String(source.dropFirst(rootPrefix.count))
      }
    }
  }
  struct Payload: Codable, Equatable {
    let thread: String
    let entries: [Entry]
    let earlier: String?
    let sending: Bool
    let status: String
    let search: String?
    let searchGeneration: Int
    var initialPosition: Double
    let compact: Bool
    let live: Live?
    /// Lowercased agent mention tokens (without `@`) to highlight.
    var mentions: [String] = []
    /// A turn the chat counts as running with no live progress to stream.
    var stalled: Stalled? = nil
  }

  struct Stalled: Codable, Equatable {
    let title: String
    let detail: String?
    /// The message to reconcile when Recheck is offered.
    let recheck: String?

    init(title: String, detail: String?, recheck: String?) {
      self.title = title
      self.detail = detail
      self.recheck = recheck
    }

    init(_ turn: AIChatUnobservedTurn) {
      self.init(
        title: turn.title,
        detail: turn.detail,
        recheck: turn.canRecheck ? turn.messageID?.uuidString.lowercased() : nil
      )
    }
  }

  static let style = AIChatDocumentHTML.style + """
  .start-work-card { display:grid; gap:3px; min-width:220px; }
  .start-work-head { display:flex; align-items:baseline; flex-wrap:wrap; gap:4px 8px; }
  .start-work-label { font-size:10px; font-weight:700; letter-spacing:.04em; text-transform:uppercase; color:var(--org2-accent, light-dark(#1d64c4,#7db4ff)); }
  .start-work-head strong { font-weight:600; }
  .start-work-source { font:11px ui-monospace, SFMono-Regular, Menlo, monospace; color:light-dark(#777,#aaa); overflow-wrap:anywhere; }
  .start-work-toggle { justify-self:start; margin:3px 0 0 -6px; padding:2px 6px; font-size:11px; font-weight:500; color:var(--org2-link, light-dark(#1d64c4,#7db4ff)); }
  .start-work-prompt { margin-top:6px; padding-top:8px; border-top:1px solid light-dark(#dddcd7,#444642); font-size:12px; }
  [hidden] { display:none!important; }
  html { overflow-y:auto; overflow-x:hidden; }
  body { padding:16px!important; }
  #messages { display:flex; flex-direction:column; gap:12px; }
  body.compact { padding:10px!important; }
  article { display:flex; align-items:flex-start; gap:10px; min-width:0; }
  article.user { justify-content:flex-end; }
  article.room-response { display:block; }
  .message-card { width:fit-content; max-width:calc(100% - 82px); min-width:0; padding:9px 11px 12px; border:1px solid light-dark(#d8d8d3,#424442); border-radius:8px; background:light-dark(#fcfbf8,#242624); }
  article.user .message-card { background:light-dark(#eef2f9,#252d39); }
  article.room-response .message-card { box-sizing:border-box; width:100%; max-width:none; }
  article.match .message-card { outline:2px solid #609ce8; }
  .avatar { flex:0 0 32px; width:32px; height:32px; display:grid; place-items:center; border-radius:8px; color:light-dark(#5f6d7e,#c5cfdb); background:light-dark(#eef0f2,#292d31); }
  .avatar.user-avatar { color:light-dark(#1672dc,#70afff); background:light-dark(#e5f0ff,#26384e); }
  .avatar svg { width:16px; height:16px; }
  .message-header { display:flex; align-items:center; gap:6px; min-height:24px; font-size:11px; color:light-dark(#777,#aaa); margin-bottom:5px; }
  .message-header strong { color:light-dark(#666,#bbb); font-weight:600; }
  .message-header time { opacity:.7; }
  main.plain-message { white-space:pre-wrap; }
  .system-badge,.queued-badge { padding:2px 5px; border-radius:4px; font-size:10px; font-weight:600; background:light-dark(#f9ead6,#503b26); color:light-dark(#a05b08,#f0aa5b); }
  .queued-badge { color:inherit; background:light-dark(#eee,#383838); }
  button { font:inherit; color:inherit; border:0; border-radius:4px; padding:3px 6px; background:transparent; cursor:pointer; user-select:none; -webkit-user-select:none; }
  button:hover { background:light-dark(#e5e5e5,#424242); }
  .icon-button { display:grid; place-items:center; width:24px; height:24px; padding:0; opacity:.5; }
  .icon-button:hover,.icon-button.copied { opacity:1; }
  .icon-button.copied { color:#25a244; }
  .glyph { display:inline-grid; place-items:center; flex:0 0 14px; width:14px; height:14px; line-height:0; }
  .glyph svg,.icon-button svg,.detail-icon svg,.activity-icon svg,.change-icon svg { width:14px; height:14px; }
  .context-pills { display:flex; flex-wrap:wrap; gap:5px; margin-bottom:6px; }
  .context-pill.reply-pill { max-width:100%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:light-dark(#555,#bbb); background:light-dark(#f2f2f2,#2c2c2e); border-color:light-dark(#ddd,#444); }
  .context-pill { padding:3px 7px; border-radius:999px; font-size:10px; color:light-dark(#2773bd,#83bafa); background:light-dark(#eaf3fc,#27394b); border:1px solid light-dark(#bdd8f0,#34516b); }
  .message-placeholder { display:flex; align-items:center; gap:9px; min-width:215px; height:23px; padding:4px 0; color:light-dark(#777,#aaa); }
  .message-placeholder-pulse { flex:0 0 6px; width:6px; height:6px; border-radius:50%; background:currentColor; animation:pulse .85s ease-in-out infinite alternate; }
  .message-placeholder-lines { display:flex; flex-direction:column; gap:6px; }
  .message-placeholder-line { display:block; width:190px; height:7px; border-radius:999px; background:currentColor; opacity:.16; animation:placeholder-pulse 1.15s ease-in-out infinite alternate; }
  .message-placeholder-line:last-child { width:132px; animation-delay:.16s; }
  .message-card > main { min-width:0; }
  .message-card > main > :first-child { margin-top:0; }
  .message-card > main > :last-child { margin-bottom:0; }
  .attachments { display:grid; grid-template-columns:repeat(auto-fill,minmax(76px,104px)); gap:8px; margin-top:8px; }
  .attachment { text-align:left; padding:0; overflow:hidden; }
  .attachment-preview { height:72px; display:grid; place-items:center; border:1px solid light-dark(#d8d8d3,#424442); border-radius:6px; background:light-dark(#f5f4f1,#1d1f1d); }
  .attachment-preview img { display:block; width:100%; height:100%; object-fit:cover; border-radius:5px; }
  .attachment-preview svg { width:22px; height:22px; opacity:.65; }
  .attachment-name { display:block; margin-top:4px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:10px; color:light-dark(#777,#aaa); }
  .queued-actions { display:flex; align-items:center; gap:8px; margin-top:8px; font-size:11px; color:light-dark(#777,#aaa); }
  .queued-actions .spacer { flex:1; }
  .failure { display:grid; grid-template-columns:14px minmax(0,1fr) max-content; align-items:start; gap:8px; margin-top:8px; padding:7px 8px; color:light-dark(#b33820,#ffa98d); background:light-dark(#fff0ed,#3a2420); border:1px solid light-dark(#efc1b8,#704139); border-radius:6px; font-size:11px; }
  .failure > .glyph { margin-top:1px; }
  .failure-copy { min-width:0; white-space:pre-wrap; overflow-wrap:anywhere; }
  .failure button { display:inline-flex; align-items:center; justify-content:center; flex:none; min-width:max-content; white-space:nowrap; font-weight:600; line-height:1.25; }
  .expansion { margin-top:7px; font-size:11px; font-weight:500; color:light-dark(#777,#aaa); }
  .detail-block { margin-top:12px; padding-top:9px; border-top:1px solid light-dark(#dddcd7,#444642); font-size:11px; max-width:640px; }
  .detail-header { display:flex; align-items:center; gap:7px; font-weight:600; color:light-dark(#5c5c5c,#c4c4c4); }
  .detail-header .spacer { flex:1; }
  .disclosure-button { display:inline-flex; align-items:center; justify-content:flex-start; gap:5px; flex:none; min-width:max-content; white-space:nowrap; line-height:14px; }
  .disclosure-button .glyph { flex-basis:10px; width:10px; height:14px; }
  .disclosure-button .glyph svg { width:10px; height:10px; }
  .reasoning-row,.activity-row,.change-row { display:flex; align-items:flex-start; gap:7px; margin-top:7px; min-width:0; }
  .reasoning-copy,.activity-copy,.change-path { min-width:0; }
  .reasoning-title,.activity-title { display:block; font-weight:500; }
  .reasoning-text,.activity-detail { display:-webkit-box; overflow:hidden; -webkit-box-orient:vertical; -webkit-line-clamp:2; margin-top:2px; color:light-dark(#777,#aaa); font-size:10px; white-space:pre-wrap; }
  .reasoning-text.rendered { white-space:normal; }
  .reasoning-text .org2-document,.live-text .org2-document { width:100%; margin:0; padding:0; color:inherit; font:inherit; }
  .reasoning-text .org2-document > :first-child,.live-text .org2-document > :first-child { margin-top:0; }
  .reasoning-text .org2-document > :last-child,.live-text .org2-document > :last-child { margin-bottom:0; }
  .trace.expanded .reasoning-text { -webkit-line-clamp:8; }
  .activity-detail { -webkit-line-clamp:1; white-space:normal; text-overflow:ellipsis; }
  .trace.expanded .activity-detail { -webkit-line-clamp:3; }
  .activity-row.omitted { display:none; }
  .trace.expanded .activity-row.omitted { display:flex; }
  .show-earlier { margin-top:6px; padding-left:21px; font-size:10px; color:light-dark(#888,#999); font-weight:500; }
  .change-summary .detail-header { color:light-dark(#333,#ddd); }
  .change-row { align-items:center; }
  .change-path { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
  .delta { display:flex; gap:4px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-weight:600; }
  .insertions { color:#25a244; } .deletions { color:#d6483e; }
  .more-files { margin-top:7px; font-size:10px; font-weight:500; color:light-dark(#777,#aaa); }
  #earlier { display:block; margin:0 auto 12px; }
  /* Live run: one 14px icon gutter plus an 8px gap. Every icon (pulse,
     activity status, disclosure chevron) centers in the gutter and every
     label starts at the same text column. */
  #live { --live-gutter:14px; --live-gap:8px; --live-indent:calc(var(--live-gutter) + var(--live-gap)); box-sizing:border-box; width:100%; max-width:700px; padding:16px 10px 14px; color:light-dark(#777,#aaa); }
  body.compact #live { max-width:430px; padding-left:6px; padding-right:6px; }
  .live-status-row { display:flex; align-items:center; gap:var(--live-gap); max-width:calc(640px + var(--live-indent)); min-height:22px; font-size:12px; line-height:16px; user-select:none; -webkit-user-select:none; }
  .live-pulse { display:grid; place-items:center; flex:0 0 var(--live-gutter); width:var(--live-gutter); height:var(--live-gutter); }
  .live-pulse::before { content:''; display:block; width:6px; height:6px; border-radius:50%; background:currentColor; }
  #live.animating .live-pulse::before { animation:pulse .85s ease-in-out infinite alternate; }
  .live-title { flex:0 1 auto; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-weight:500; }
  #live.animating .live-title { color:transparent; background:linear-gradient(90deg,light-dark(#777,#aaa) 20%,light-dark(#333,#eee) 50%,light-dark(#777,#aaa) 80%); background-size:220% 100%; background-clip:text; -webkit-background-clip:text; animation:shimmer 1.7s linear infinite; }
  .live-elapsed { flex:none; font-size:11px; font-variant-numeric:tabular-nums; color:light-dark(#999,#888); }
  .live-stop { display:grid; place-items:center; flex:0 0 22px; width:22px; height:22px; margin-left:auto; padding:0; border-radius:50%; background:light-dark(#0000000d,#ffffff12); }
  .live-stop .glyph,.live-stop svg { width:8px; height:8px; }
  .live-detail { max-width:640px; margin:2px 0 0 var(--live-indent); font-size:11px; line-height:15px; color:light-dark(#999,#888); white-space:pre-wrap; }
  .live-text { max-width:640px; margin:6px 0 0 var(--live-indent); color:light-dark(#202020,#e7e7e7); font-size:13px; line-height:1.5; white-space:pre-wrap; }
  .live-text.rendered { white-space:normal; }
  .live-feed { max-width:calc(640px + var(--live-indent)); margin-top:8px; font-size:12px; }
  .live-feed .reasoning-row,.live-feed .activity-row { gap:var(--live-gap); margin-top:4px; }
  .live-feed > :first-child { margin-top:0; }
  .live-feed .activity-icon,.live-feed .reasoning-row > .glyph { display:grid; place-items:center; flex:0 0 var(--live-gutter); width:var(--live-gutter); height:18px; }
  .live-feed .activity-title,.live-feed .reasoning-title { line-height:18px; }
  .live-feed .activity-detail,.live-feed .reasoning-text { margin-top:0; font-size:11px; line-height:15px; }
  .live-feed.expanded .reasoning-text { -webkit-line-clamp:8; }
  .live-feed.expanded .activity-detail { -webkit-line-clamp:3; }
  .live-running-dot { display:block; width:6px; height:6px; border-radius:50%; background:currentColor; animation:pulse .85s ease-in-out infinite alternate; }
  /* Disclosures hang their chevron in the same gutter; the negative margin
     keeps the hover pill's padding from shifting the chevron right. */
  .live-text-toggle,.live-activity-toggle { gap:var(--live-gap); margin-left:-6px; padding:2px 6px; font-size:11px; font-weight:500; line-height:16px; color:light-dark(#777,#aaa); }
  .live-activity-toggle { margin-top:4px; }
  .live-text-toggle .glyph,.live-activity-toggle .glyph { flex-basis:var(--live-gutter); width:var(--live-gutter); height:16px; }
  #status { display:flex; align-items:center; gap:8px; min-height:22px; padding:16px 0; color:light-dark(#777,#aaa); font-size:11px; }
  #status.working::before { content:''; display:block; flex:0 0 5px; width:5px; height:5px; border-radius:50%; background:currentColor; animation:pulse 1.2s ease-in-out infinite; }
  #status.stalled { align-items:flex-start; }
  #status.stalled::before { margin-top:5px; }
  .stalled-copy { display:grid; gap:2px; flex:1 1 auto; min-width:0; }
  .stalled-copy strong { font-weight:600; color:light-dark(#555,#ccc); }
  .stalled-detail { overflow-wrap:anywhere; }
  #status button { display:inline-flex; align-items:center; justify-content:center; flex:none; white-space:nowrap; line-height:1.25; }
  @keyframes pulse { from { opacity:.55; transform:scale(.78); } to { opacity:1; transform:scale(1); } }
  @keyframes placeholder-pulse { from { opacity:.11; } to { opacity:.24; } }
  @keyframes shimmer { from { background-position:100% 0; } to { background-position:-120% 0; } }
  @media (prefers-reduced-motion:reduce) {
    #live.animating .live-pulse::before,.live-running-dot,.message-placeholder-pulse,.message-placeholder-line { animation:none; }
    #live.animating .live-title { color:inherit; background:none; animation:none; }
  }
  #latest { position:fixed; bottom:12px; right:14px; border:1px solid #8886; border-radius:20px; background:light-dark(#fff,#333); box-shadow:0 2px 6px #0002; }
  pre { max-height:none!important; height:auto!important; overflow-x:auto; overflow-y:hidden; white-space:pre; }
  table { max-width:100%; table-layout:fixed; }
  """

  static let script = #"""
  (() => {
    let current = null, pending = null, pendingLive = null, hasPendingLive = false, nearBottom = true, searchToken = '';
    const threadNodes = new Map(), threadNodeLimit = 8;
    const restoreThreadNodes = (root, thread) => {
      const nodes=threadNodes.get(thread);
      if(!nodes) { root.replaceChildren(); return; }
      threadNodes.delete(thread); threadNodes.set(thread,nodes);
      root.replaceChildren(...nodes);
    };
    const rememberThreadNodes = (root, thread) => {
      threadNodes.delete(thread); threadNodes.set(thread,[...root.children]);
      while(threadNodes.size>threadNodeLimit) threadNodes.delete(threadNodes.keys().next().value);
    };
    const post = (action, id, detail) => webkit.messageHandlers.transcript.postMessage({action, id:id??null, detail:detail??null, thread:current?.thread??""});
    const selected = () => { const s=getSelection(); return s && !s.isCollapsed; };
    const maxScroll = () => Math.max(0,document.documentElement.scrollHeight-innerHeight);
    const report = () => {
      const max=maxScroll(); nearBottom=max-scrollY<60;
      document.getElementById('latest').hidden=nearBottom;
      webkit.messageHandlers.transcript.postMessage({position:max>0?scrollY/max:1,thread:current?.thread});
    };
    const button = (label, action, id, detail) => {
      const b=document.createElement('button'); b.textContent=label;
      b.addEventListener('click',()=>post(action,id,detail)); return b;
    };
    const icon = name => {
      const span=document.createElement('span'); span.className='glyph'; span.setAttribute('aria-hidden','true');
      const common='viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"';
      const paths={
        copy:'<rect x="8" y="7" width="11" height="13" rx="2"/><path d="M16 7V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h3"/>',
        check:'<path d="m5 12 4 4L19 6"/>',
        reply:'<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
        sparkle:'<path d="M12 2c.7 4.7 2.9 6.9 7.5 7.5C14.9 10.1 12.7 12.3 12 17c-.7-4.7-2.9-6.9-7.5-7.5C9.1 8.9 11.3 6.7 12 2Z"/><path d="M19 15c.3 2.1 1.3 3.1 3 3.5-1.7.3-2.7 1.3-3 3.5-.3-2.2-1.3-3.2-3-3.5 1.7-.4 2.7-1.4 3-3.5Z"/>',
        person:'<circle cx="12" cy="8" r="4"/><path d="M4.5 21a7.5 7.5 0 0 1 15 0"/>',
        gear:'<circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.4 1A8 8 0 0 0 15 6l-.3-2.6h-4L10.4 6A8 8 0 0 0 8.8 7L6.5 6l-2 3.4 2 1.5a7 7 0 0 0 0 2.1l-2 1.5 2 3.4 2.3-1a8 8 0 0 0 1.6 1l.3 2.6h4L15 18a8 8 0 0 0 1.6-1l2.3 1 2-3.4-2-1.5a7 7 0 0 0 .1-1Z"/>',
        clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
        file:'<path d="M6 3h8l4 4v14H6Z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',
        searchfile:'<path d="M5 3h9l4 4v6M14 3v5h5"/><circle cx="15" cy="17" r="3"/><path d="m17.5 19.5 2 2"/>',
        success:'<circle cx="12" cy="12" r="9"/><path d="m8 12 2.5 2.5L16 9"/>',
        failed:'<path d="M12 3 2.5 20h19Z"/><path d="M12 9v4M12 17h.01"/>',
        tool:'<path d="m14.5 6.5 3-3a4 4 0 0 1-5 5L6 15l3 3 6.5-6.5a4 4 0 0 1 5-5l-3 3Z"/>',
        stop:'<rect x="7" y="7" width="10" height="10" rx="1.5" fill="currentColor" stroke="none"/>',
        chevronRight:'<path d="m9 5 7 7-7 7"/>',
        chevronDown:'<path d="m5 9 7 7 7-7"/>',
        chevronUp:'<path d="m5 15 7-7 7 7"/>'
      };
      span.innerHTML='<svg '+common+'>'+paths[name]+'</svg>'; return span;
    };
    const iconButton = (name, label, action, id, copied=false) => {
      const b=button('',action,id); b.className='icon-button'+(copied?' copied':'');
      b.setAttribute('aria-label',label); b.title=label; b.append(icon(name)); return b;
    };
    const updateDisclosure = (button, label, iconName) => {
      const copy=document.createElement('span'); copy.textContent=label;
      button.replaceChildren(icon(iconName),copy);
    };
    const appendDelta = (parent, insertions, deletions) => {
      const d=document.createElement('span'); d.className='delta';
      if(insertions>0) { const n=document.createElement('span'); n.className='insertions'; n.textContent='+'+insertions; d.append(n); }
      if(deletions>0) { const n=document.createElement('span'); n.className='deletions'; n.textContent='-'+deletions; d.append(n); }
      if(!insertions && !deletions) d.textContent='0'; parent.append(d);
    };
    const sameValue = (left,right) => {
      if(left===right) return true;
      if(left===null || right===null || typeof left!==typeof right || typeof left!=='object') return false;
      if(Array.isArray(left) || Array.isArray(right)) {
        return Array.isArray(left) && Array.isArray(right) && left.length===right.length
          && left.every((value,index)=>sameValue(value,right[index]));
      }
      const leftKeys=Object.keys(left).sort(), rightKeys=Object.keys(right).sort();
      return leftKeys.length===rightKeys.length
        && leftKeys.every((key,index)=>key===rightKeys[index] && sameValue(left[key],right[key]));
    };
    let mentionTokens=[];
    const renderedOrgBody = (html, tagName='div') => {
      const doc=new DOMParser().parseFromString(html,'text/html');
      const css=doc.querySelector('style');
      if(css && !document.getElementById('renderer-style')) { css.id='renderer-style'; document.head.prepend(css); }
      doc.querySelectorAll('script,.org2-document-header').forEach(x=>x.remove());
      window.__org2PrepareSandboxFrames?.(doc);
      const source=doc.querySelector('main') || doc.body;
      const body=document.createElement(tagName); body.className='org2-document'; body.append(...source.childNodes);
      for(const pre of body.querySelectorAll('pre')) {
        const wrap=document.createElement('div'); wrap.className='chat-code'; pre.replaceWith(wrap); wrap.append(pre);
        const b=document.createElement('button'); b.className='chat-copy-code'; b.textContent='Copy code';
        b.onclick=()=>webkit.messageHandlers.chatCopyCode.postMessage(pre.textContent.replace(/\n$/,'')); wrap.append(b);
      }
      return body;
    };
    // Start work prompts are long and the same every time. Show the task, and
    // fold the exact prompt behind a toggle that survives re-renders.
    const shownStartWorkPrompts=new Set();
    const startWorkCard = (e, prompt) => {
      const box=document.createElement('div'); box.className='start-work-card';
      const head=document.createElement('div'); head.className='start-work-head';
      const label=document.createElement('span'); label.className='start-work-label'; label.textContent='▶ Start work';
      const title=document.createElement('strong'); title.textContent=e.startWork.title;
      head.append(label,title); box.append(head);
      if(e.startWork.source) {
        const source=document.createElement('div'); source.className='start-work-source'; source.textContent=e.startWork.source; box.append(source);
      }
      prompt.classList.add('start-work-prompt'); prompt.hidden=!shownStartWorkPrompts.has(e.id);
      const toggle=document.createElement('button'); toggle.className='start-work-toggle';
      const sync=()=>{ toggle.textContent=prompt.hidden?'Show prompt':'Hide prompt'; toggle.setAttribute('aria-expanded',String(!prompt.hidden)); };
      toggle.onclick=()=>{
        prompt.hidden=!prompt.hidden;
        if(prompt.hidden) shownStartWorkPrompts.delete(e.id); else shownStartWorkPrompts.add(e.id);
        sync();
      };
      sync(); box.append(toggle,prompt);
      return box;
    };
    const plainMessageBody = text => {
      const body=document.createElement('main');
      body.className='org2-document plain-message'; body.textContent=text||'';
      return body;
    };
    const setRenderedOrgText = (node, text, html) => {
      const nextText=text||'', nextHTML=html||null;
      if(node._orgText===nextText && node._orgHTML===nextHTML) return;
      const wasRendered=node.classList.contains('rendered');
      node.classList.toggle('rendered',!!nextHTML);
      if(nextHTML) {
        node.replaceChildren(renderedOrgBody(nextHTML));
      } else if(wasRendered) {
        node.replaceChildren(); node.textContent=nextText;
      } else if(node.textContent!==nextText) {
        node.textContent=nextText;
      }
      node._orgText=nextText; node._orgHTML=nextHTML;
    };
    const makeMessage = e => {
      const a=document.createElement('article'); a.id='message-'+e.id; a.className=e.role;
      if(e.isRoomResponse) a.classList.add('room-response');
      a.setAttribute('aria-label',e.title+' message');
      if(e.role!=='user' && !e.isRoomResponse) {
        const avatar=document.createElement('span'); avatar.className='avatar'; avatar.append(icon(e.role==='assistant'?'sparkle':'gear')); a.append(avatar);
      }
      const card=document.createElement('div'); card.className='message-card';
      const header=document.createElement('header'); header.className='message-header';
      const title=document.createElement('strong'); title.textContent=e.title;
      const time=document.createElement('time'); time.textContent=e.timestamp;
      header.append(title);
      if(e.role==='system') { const badge=document.createElement('span'); badge.className='system-badge'; badge.textContent='System'; header.append(badge); }
      if(e.queued) { const q=document.createElement('span'); q.className='queued-badge'; q.textContent='Queued'; header.append(q); }
      header.append(time,iconButton(e.copied?'check':'copy',e.copied?'Copied':'Copy message','copy',e.id,e.copied));
      if(!e.queued && !e.preparing && e.role!=='system') header.append(iconButton('reply','Reply to this message','reply',e.id));
      card.append(header);
      if(e.contexts.length && !e.startWork) {
        const pills=document.createElement('div'); pills.className='context-pills';
        for(const context of e.contexts) { const pill=document.createElement('span'); const reply=context.kind==='reply to message'; pill.className='context-pill'+(reply?' reply-pill':''); pill.textContent=(reply?'↩ ':context.isAutomatic?'✦ ':'')+context.title; pills.append(pill); }
        card.append(pills);
      }
      if(e.preparing) {
        const placeholder=document.createElement('div'); placeholder.className='message-placeholder';
        placeholder.setAttribute('role','status'); placeholder.setAttribute('aria-label','Preparing message');
        const pulse=document.createElement('span'); pulse.className='message-placeholder-pulse'; pulse.setAttribute('aria-hidden','true');
        const lines=document.createElement('span'); lines.className='message-placeholder-lines'; lines.setAttribute('aria-hidden','true');
        for(let i=0;i<2;i++) { const line=document.createElement('span'); line.className='message-placeholder-line'; lines.append(line); }
        placeholder.append(pulse,lines); card.append(placeholder);
      } else {
        const messageBody=typeof e.plainText==='string' ? plainMessageBody(e.plainText) : renderedOrgBody(e.html,'main');
        window.__chatHighlightMentions?.(document, messageBody, mentionTokens);
        card.append(e.startWork ? startWorkCard(e, messageBody) : messageBody);
      }
      if(!e.preparing && e.isTruncated && !e.startWork) { const expand=button('⌄  Show Full Message','expand',e.id); expand.className='expansion'; card.append(expand); }
      if(e.attachments.length) {
        const attachments=document.createElement('div'); attachments.className='attachments';
        for(const attachment of e.attachments) {
          const b=button('','attachment',e.id,attachment.id); b.className='attachment'; b.title='Open '+attachment.fileName;
          const preview=document.createElement('span'); preview.className='attachment-preview';
          if(attachment.previewURL) {
            const image=document.createElement('img'); image.src=attachment.previewURL; image.alt='';
            image.onerror=()=>preview.replaceChildren(icon('file')); preview.append(image);
          } else preview.append(icon('file'));
          const name=document.createElement('span'); name.className='attachment-name'; name.textContent=attachment.fileName;
          b.append(preview,name); attachments.append(b);
        }
        card.append(attachments);
      }
      if(e.queued) {
        const actions=document.createElement('div'); actions.className='queued-actions';
        const label=document.createElement('span'); label.textContent='Waiting behind the current turn';
        const spacer=document.createElement('span'); spacer.className='spacer'; actions.append(label,spacer);
        if(e.canSteer) actions.append(button('Steer now','steer',e.id));
        actions.append(button('Edit','edit',e.id),button('Remove','delete',e.id)); card.append(actions);
      }
      if(e.failure) {
        const failure=document.createElement('div'); failure.className='failure'; failure.append(icon('failed'));
        const copy=document.createElement('span'); copy.className='failure-copy'; copy.textContent=e.failure; failure.append(copy,button('Retry','retry',e.id)); card.append(failure);
      }
      if(e.responseTrace) {
        const trace=document.createElement('section'); trace.className='detail-block trace';
        const head=document.createElement('div'); head.className='detail-header detail-icon'; head.append(icon('clock'));
        const label=document.createElement('span'); label.textContent='How it worked'; head.append(label);
        const canExpand=e.responseTrace.activities.length>3 || (e.responseTrace.reasoning?.length||0)>240;
        if(canExpand) {
          const spacer=document.createElement('span'); spacer.className='spacer';
          const toggle=button(''); toggle.className='disclosure-button';
          updateDisclosure(toggle,'Show full feed','chevronRight');
          toggle.onclick=()=>{ const expanded=trace.classList.toggle('expanded'); updateDisclosure(toggle,expanded?'Show less':'Show full feed',expanded?'chevronDown':'chevronRight'); };
          head.append(spacer,toggle);
        }
        trace.append(head);
        if(e.responseTrace.reasoning) {
          const row=document.createElement('div'); row.className='reasoning-row detail-icon'; row.append(icon('sparkle'));
          const copy=document.createElement('div'); copy.className='reasoning-copy';
          const title=document.createElement('span'); title.className='reasoning-title'; title.textContent='Approach';
          const value=document.createElement('div'); value.className='reasoning-text';
          setRenderedOrgText(value,e.responseTrace.reasoning,e.responseTrace.reasoningHTML);
          copy.append(title,value); row.append(copy); trace.append(row);
        }
        if(e.responseTrace.usage) {
          const usage=e.responseTrace.usage;
          const row=document.createElement('div'); row.className='activity-row';
          const image=document.createElement('span'); image.className='activity-icon'; image.append(icon('clock'));
          const copy=document.createElement('div'); copy.className='activity-copy';
          const title=document.createElement('span'); title.className='activity-title'; title.textContent='Provider tokens';
          const detail=document.createElement('span'); detail.className='activity-detail';
          detail.textContent=`${usage.inputTokens} input · ${usage.cachedInputTokens} cached · ${usage.outputTokens} output · ${usage.totalTokens} total`;
          copy.append(title,detail); row.append(image,copy); trace.append(row);
        }
        if(e.responseTrace.context) {
          const context=e.responseTrace.context;
          const total=context.staticTokens+context.projectTokens+context.transcriptTokens+context.roomTokens+context.attachmentTokens;
          const row=document.createElement('div'); row.className='activity-row';
          const image=document.createElement('span'); image.className='activity-icon'; image.append(icon('searchfile'));
          const copy=document.createElement('div'); copy.className='activity-copy';
          const title=document.createElement('span'); title.className='activity-title'; title.textContent='Celorga context';
          const detail=document.createElement('span'); detail.className='activity-detail';
          detail.textContent=`${context.mode} · ${total} estimated tokens (static ${context.staticTokens}, project ${context.projectTokens}, transcript ${context.transcriptTokens}, room ${context.roomTokens}, attachments ${context.attachmentTokens})`;
          copy.append(title,detail); row.append(image,copy); trace.append(row);
        }
        const activities=e.responseTrace.activities;
        activities.forEach((activity,index)=>{
          const row=document.createElement('div'); row.className='activity-row'+(index<activities.length-3?' omitted':'');
          const image=document.createElement('span'); image.className='activity-icon'; image.append(icon(activity.status==='failed'?'failed':activity.status==='succeeded'?'success':'tool'));
          const copy=document.createElement('div'); copy.className='activity-copy';
          const title=document.createElement('span'); title.className='activity-title'; title.textContent=activity.title;
          copy.append(title);
          const detail=activity.latestDetail||activity.detail;
          if(detail) { const value=document.createElement('span'); value.className='activity-detail'; value.textContent=detail; copy.append(value); }
          row.append(image,copy); trace.append(row);
        });
        if(activities.length>3) { const more=document.createElement('div'); more.className='show-earlier'; more.textContent='Show '+(activities.length-3)+' earlier update'+(activities.length-3===1?'':'s'); trace.append(more); }
        card.append(trace);
      }
      if(e.changeSummary) {
        const summary=e.changeSummary, section=document.createElement('section'); section.className='detail-block change-summary';
        const head=document.createElement('div'); head.className='detail-header change-icon'; head.append(icon('searchfile'));
        const title=document.createElement('span'); title.textContent=summary.title;
        const spacer=document.createElement('span'); spacer.className='spacer'; head.append(title,spacer); appendDelta(head,summary.totalInsertions,summary.totalDeletions); section.append(head);
        summary.files.slice(0,6).forEach(change=>{
          const row=document.createElement('div'); row.className='change-row';
          const image=document.createElement('span'); image.className='change-icon'; image.append(icon(change.status==='deleted'?'failed':change.status==='created'?'success':'file'));
          const path=document.createElement('span'); path.className='change-path'; path.textContent=change.relativePath;
          row.append(image,path); appendDelta(row,change.insertions,change.deletions); section.append(row);
        });
        if(summary.files.length>6) { const more=document.createElement('div'); more.className='more-files'; more.textContent='+'+(summary.files.length-6)+' more file'+(summary.files.length-6===1?'':'s'); section.append(more); }
        card.append(section);
      }
      a.append(card);
      if(e.role==='user') { const avatar=document.createElement('span'); avatar.className='avatar user-avatar'; avatar.append(icon('person')); a.append(avatar); }
      a._entry=e; return a;
    };
    const ensureLive = () => {
      const root=document.getElementById('live');
      if(root.childElementCount) return root;
      const status=document.createElement('div'); status.className='live-status-row';
      const pulse=document.createElement('span'); pulse.className='live-pulse'; pulse.setAttribute('aria-hidden','true');
      const title=document.createElement('span'); title.className='live-title';
      const elapsed=document.createElement('time'); elapsed.className='live-elapsed';
      const stop=button('','stop'); stop.className='live-stop'; stop.setAttribute('aria-label','Stop agent run'); stop.title='Stop this agent run'; stop.append(icon('stop'));
      status.append(pulse,title,elapsed,stop);
      const detail=document.createElement('div'); detail.className='live-detail';
      const text=document.createElement('div'); text.className='live-text';
      const feed=document.createElement('div'); feed.className='live-feed';
      root.append(status,detail,text,feed); return root;
    };
    const duration = milliseconds => {
      const seconds=Math.max(0,Math.floor(milliseconds/1000));
      if(seconds<60) return seconds+'s';
      return Math.floor(seconds/60)+'m '+seconds%60+'s';
    };
    const updateLiveClock = () => {
      const root=document.getElementById('live'), live=root.liveData;
      if(!live || root.hidden) return;
      const now=Date.now(), age=live.lastEventAtMilliseconds==null?0:Math.max(0,now-live.lastEventAtMilliseconds);
      let title=live.title, detail=live.detail||'', animates=live.animates;
      if(live.usesLivenessThresholds && age>=600000) { title=live.stalledTitle; detail=live.stalledDetail; animates=live.stalledAnimates===true; }
      else if(live.usesLivenessThresholds && age>=120000) { title=live.quietTitle; detail=live.quietDetail; }
      root.classList.toggle('animating',animates);
      root.querySelector('.live-title').textContent=title;
      const detailNode=root.querySelector('.live-detail'); detailNode.textContent=detail; detailNode.hidden=!detail;
      root.querySelector('.live-elapsed').textContent=duration(now-(live.startedAtMilliseconds??now));
    };
    const renderLive = live => {
      const root=ensureLive(); root.liveData=live; root.hidden=!live;
      if(!live) return;
      const text=root.querySelector('.live-text'); setRenderedOrgText(text,live.text,live.textHTML); text.hidden=!live.text;
      const feed=root.querySelector('.live-feed');
      const retainedReasoning=feed.querySelector(':scope > .reasoning-row');
      for(const child of [...feed.children]) if(child!==retainedReasoning) child.remove();
      feed.classList.toggle('expanded',live.activityExpanded);
      if(live.activityExpanded && live.reasoning) {
        const row=retainedReasoning||document.createElement('div');
        if(!retainedReasoning) {
          row.className='reasoning-row detail-icon'; row.append(icon('sparkle'));
          const copy=document.createElement('div'); copy.className='reasoning-copy';
          const title=document.createElement('span'); title.className='reasoning-title'; title.textContent='Approach';
          const value=document.createElement('div'); value.className='reasoning-text';
          copy.append(title,value); row.append(copy); feed.prepend(row);
        }
        const value=row.querySelector('.reasoning-text');
        setRenderedOrgText(value,live.reasoning,live.reasoningHTML);
      } else retainedReasoning?.remove();
      let activities=live.activities;
      if(!live.activityExpanded) { const running=activities.filter(x=>x.status==='running').slice(-1)[0]; activities=running?[running]:activities.slice(-1); }
      activities.forEach(activity=>{
        const row=document.createElement('div'); row.className='activity-row';
        const image=document.createElement('span'); image.className='activity-icon';
        if(activity.status==='running') { const dot=document.createElement('span'); dot.className='live-running-dot'; image.append(dot); }
        else image.append(icon(activity.status==='failed'?'failed':'success'));
        const copy=document.createElement('div'); copy.className='activity-copy';
        const title=document.createElement('span'); title.className='activity-title'; title.textContent=activity.title; copy.append(title);
        const detail=activity.latestDetail||activity.detail;
        if(detail) { const value=document.createElement('span'); value.className='activity-detail'; value.textContent=detail; copy.append(value); }
        row.append(image,copy); feed.append(row);
      });
      if(live.hasEarlierText || live.activities.length || live.reasoning) {
        const toggle=button('','liveActivityToggle'); toggle.className='disclosure-button live-activity-toggle';
        updateDisclosure(toggle,live.activityExpanded?'Hide activity':'Show all activity',live.activityExpanded?'chevronDown':'chevronRight'); feed.append(toggle);
      }
      feed.hidden=!feed.childElementCount; updateLiveClock();
    };
    window.__transcriptLiveUpdate = live => {
      if(selected()) { pendingLive=live; hasPendingLive=true; return; }
      const follow=nearBottom;
      if(current) current={...current,live};
      renderLive(live);
      requestAnimationFrame(()=>{ if(follow) scrollTo(0,maxScroll()); report(); });
    };
    window.__transcriptUpdate = data => {
      const changedThread=current?.thread!==data.thread;
      if(!changedThread && selected()) { pending=data; return; }
      const nextMentions=data.mentions||[];
      const mentionsChanged=!sameValue(mentionTokens,nextMentions);
      mentionTokens=nextMentions;
      if(changedThread) getSelection().removeAllRanges();
      const oldTop=scrollY, first=[...document.querySelectorAll('article')].find(x=>x.getBoundingClientRect().bottom>0);
      const anchor=first?{id:first.id,top:first.getBoundingClientRect().top}:null;
      const follow=nearBottom && !selected();
      const root=document.getElementById('messages');
      if(changedThread) restoreThreadNodes(root,data.thread);
      const wanted=new Set(data.entries.map(e=>'message-'+e.id));
      for(const child of [...root.children]) if(!wanted.has(child.id)) child.remove();
      data.entries.forEach((e,i)=>{
        let a=document.getElementById('message-'+e.id);
        if(!a || mentionsChanged || !sameValue(a._entry,e)) { const next=makeMessage(e); if(a) a.replaceWith(next); a=next; }
        if(root.children[i]!==a) root.insertBefore(a,root.children[i]||null);
        a.classList.toggle('match',data.search===e.id);
      });
      rememberThreadNodes(root,data.thread);
      const earlier=document.getElementById('earlier'); earlier.textContent=data.earlier||''; earlier.hidden=!data.earlier;
      const status=document.getElementById('status'); status.replaceChildren();
      document.body.classList.toggle('compact',data.compact);
      current=data; renderLive(data.live||null);
      const stalled=!data.live && data.stalled;
      status.classList.toggle('working',(data.sending || !!stalled) && !data.live);
      status.classList.toggle('stalled',!!stalled);
      if(stalled) {
        const copy=document.createElement('span'); copy.className='stalled-copy';
        const title=document.createElement('strong'); title.textContent=stalled.title; copy.append(title);
        if(stalled.detail) { const detail=document.createElement('span'); detail.className='stalled-detail'; detail.textContent=stalled.detail; copy.append(detail); }
        status.append(copy);
        if(stalled.recheck) status.append(button('Recheck','recheck',stalled.recheck));
        status.append(button('Stop','stop'));
      }
      else if(data.sending && !data.live) { status.append(document.createTextNode('Working…'),button('Stop','stop')); }
      else if(!data.entries.length) status.textContent=data.status;
      pending=null; hasPendingLive=false;
      if(changedThread && !data.search) scrollTo(0,maxScroll()*data.initialPosition);
      requestAnimationFrame(()=>{
        const token=data.thread+':'+data.searchGeneration+':'+data.search;
        const target=data.search && document.getElementById('message-'+data.search);
        if(target && token!==searchToken) { target.scrollIntoView({block:'center'}); searchToken=token; }
        else if(changedThread && data.search) scrollTo(0,maxScroll()*data.initialPosition);
        else if(follow) scrollTo(0,maxScroll());
        else if(anchor && document.getElementById(anchor.id)) scrollTo(0,oldTop+document.getElementById(anchor.id).getBoundingClientRect().top-anchor.top);
        report();
      });
    };
    document.addEventListener('selectionchange',()=>{
      if(selected()) return;
      if(pending) { const next=pending; pending=null; window.__transcriptUpdate(next); }
      else if(hasPendingLive) { const next=pendingLive; hasPendingLive=false; pendingLive=null; window.__transcriptLiveUpdate(next); }
    });
    document.getElementById('earlier').onclick=()=>post('earlier');
    document.getElementById('latest').onclick=()=>scrollTo(0,maxScroll());
    let scheduled=false;
    addEventListener('scroll',()=>{ if(!scheduled) { scheduled=true; requestAnimationFrame(()=>{scheduled=false; report();}); } },{passive:true});
    const resize=new ResizeObserver(()=>{ if(current && nearBottom && !selected()) scrollTo(0,maxScroll()); });
    resize.observe(document.getElementById('messages')); resize.observe(document.getElementById('live'));
    setInterval(updateLiveClock,1000);
  })();
  """#

  static let shell = """
  <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src about: org2-frame:; img-src https: http: data: org2-resource:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'"><style>\(style)</style></head><body><button id="earlier" hidden></button><div id="messages"></div><section id="live" hidden aria-label="Live agent activity"></section><div id="status"></div><button id="latest" hidden aria-label="Jump to latest message">↓</button></body></html>
  """
}

struct AIChatTranscriptWebView: NSViewRepresentable {
  let payload: AIChatTranscriptHTML.Payload
  let attachments: [AIChatAttachment]
  let sourcePath: String
  let corpusRoot: URL?
  let linkResolver: OrgRoamLinkResolver
  let openFileReference: (AIChatFileReference) -> Void
  var openWebLink = OpenWorkspaceWebLinkAction()
  let onAction: (String, String?, String?) -> Void
  let onPosition: (String, Double) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WKWebView {
    let config=WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(context.coordinator.resources, forURLScheme: OrgHTMLLocalResourceSchemeHandler.scheme)
    config.setURLSchemeHandler(context.coordinator.frames, forURLScheme: AIChatSandboxFrames.scheme)
    for name in ["transcript", "chatCopyCode"] { config.userContentController.add(context.coordinator, name: name) }
    config.userContentController.addUserScript(WKUserScript(source: AIChatSandboxFrames.script + "\n" + AIChatMentionHighlight.script + "\n" + AIChatTranscriptHTML.script + "\n" + OrgHTMLRichCopy.installationScript,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    let view=WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate=context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    view.setAccessibilityLabel("Chat transcript")
    view.setAccessibilityIdentifier(AIChatAccessibilityIdentity.transcriptScrollBridge)
    view.loadHTMLString(AIChatTranscriptHTML.shell, baseURL: URL(fileURLWithPath: sourcePath).deletingLastPathComponent())
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {
    let c=context.coordinator
    c.onAction=onAction; c.onPosition=onPosition; c.openFileReference=openFileReference; c.openWebLink=openWebLink
    c.sourcePath=sourcePath; c.corpusRoot=corpusRoot; c.linkResolver=linkResolver
    c.resources.configure(source: EntrySource(file:sourcePath,startLine:1,endLineExclusive:1,text:"",isSubtree:false),corpusRoot:corpusRoot)
    if c.attachments != attachments {
      c.attachments = attachments
      c.resources.configureChatAttachments(attachments)
    }
    var next = payload
    if let previous = c.payload, previous.thread == next.thread { next.initialPosition = previous.initialPosition }
    let previous = c.payload
    guard previous != next else { return }
    let onlyLiveChanged = previous.map { Self.documentPayloadMatches($0, next) } ?? false
    c.restorationThreadAfterDOMUpdate = previous?.thread != next.thread && next.search == nil
      ? next.thread
      : nil
    c.payload=next
    if c.loaded {
      if onlyLiveChanged { c.updateLive(view) }
      else { c.update(view) }
    }
  }
  static func documentPayloadMatches(
    _ lhs: AIChatTranscriptHTML.Payload,
    _ rhs: AIChatTranscriptHTML.Payload
  ) -> Bool {
    lhs.thread == rhs.thread
      && lhs.entries == rhs.entries
      && lhs.earlier == rhs.earlier
      && lhs.sending == rhs.sending
      && lhs.status == rhs.status
      && lhs.search == rhs.search
      && lhs.searchGeneration == rhs.searchGeneration
      && lhs.initialPosition == rhs.initialPosition
      && lhs.compact == rhs.compact
      && lhs.stalled == rhs.stalled
  }
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    AIChatDocumentWebView.dismantleNSView(view, coordinator: coordinator)
    view.configuration.userContentController.removeScriptMessageHandler(forName:"transcript")
  }
  final class Coordinator: AIChatDocumentWebView.Coordinator {
    var payload: AIChatTranscriptHTML.Payload?
    var attachments: [AIChatAttachment] = []
    var restoredThread: String?
    var restorationThreadAfterDOMUpdate: String?
    var onAction: ((String,String?,String?) -> Void)?
    var onPosition: ((String,Double) -> Void)?
    override func update(_ view: WKWebView) {
      guard let payload, let data=try? JSONEncoder().encode(payload) else { return }
      // Rewrite HTML fields before encoding: JSON escaping must remain intact.
      var object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
      object["entries"] = payload.entries.map { entry -> [String:Any] in
        var value=(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(entry))) as? [String:Any] ?? [:]
        value["html"]=OrgHTMLLocalResourceSchemeHandler.rewritingLocalImageSources(in:entry.html)
        return value
      }
      let restorationThread = restorationThreadAfterDOMUpdate
      restorationThreadAfterDOMUpdate = nil
      view.callAsyncJavaScript(
        "window.__transcriptUpdate(data)",
        arguments: ["data": object],
        in: nil,
        in: .page
      ) { [weak self] result in
        guard case .success = result, let restorationThread else { return }
        Task { @MainActor [weak self] in
          guard let self, self.payload?.thread == restorationThread else { return }
          self.completeRestoration(for: restorationThread)
        }
      }
    }
    func updateLive(_ view: WKWebView) {
      guard let payload else { return }
      let object: Any
      if let live = payload.live,
         let data = try? JSONEncoder().encode(live),
         let value = try? JSONSerialization.jsonObject(with: data) {
        object = value
      } else {
        object = NSNull()
      }
      view.callAsyncJavaScript("window.__transcriptLiveUpdate(live)",arguments:["live":object],in:nil,in:.page)
    }
    override func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.name=="transcript" else { super.userContentController(controller,didReceive:message); return }
      guard message.frameInfo.isMainFrame, let value=message.body as? [String:Any],
            let thread=value["thread"] as? String, thread==payload?.thread else { return }
      if let position=value["position"] as? Double, position.isFinite {
        completeRestoration(for: thread)
        onPosition?(thread,min(1,max(0,position)))
      }
      if let action=value["action"] as? String {
        onAction?(action, value["id"] as? String, value["detail"] as? String)
      }
    }

    private func completeRestoration(for thread: String) {
      guard restoredThread != thread else { return }
      restoredThread = thread
      onAction?("restored", nil, nil)
    }
  }
}
