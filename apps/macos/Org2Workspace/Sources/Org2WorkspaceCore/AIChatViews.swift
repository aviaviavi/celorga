import AppKit
import CryptoKit
import SwiftUI

enum AIChatMessageTimestampPresentation {
  static func displayText(
    for date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    var calendar = calendar
    calendar.timeZone = timeZone
    let time = date.formatted(
      Date.FormatStyle(
        date: .omitted,
        time: .shortened,
        locale: locale,
        calendar: calendar,
        timeZone: timeZone
      )
    )

    if calendar.isDate(date, inSameDayAs: now) {
      return "Today at \(time)"
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
      return "Yesterday at \(time)"
    }

    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
    let day: String
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
      day = date.formatted(style.month(.abbreviated).day())
    } else {
      day = date.formatted(style.month(.abbreviated).day().year())
    }
    return "\(day) at \(time)"
  }

  static func fullText(
    for date: Date,
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> String {
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    return date.formatted(
      Date.FormatStyle(
        date: .complete,
        time: .shortened,
        locale: locale,
        calendar: calendar,
        timeZone: timeZone
      )
    )
  }
}

struct AIChatPresentedContext: Identifiable, Hashable, Sendable {
  let kind: String
  let title: String
  let reference: String
  let sourceLine: String
  let automaticPrompt: String?

  init(
    kind: String,
    title: String,
    reference: String,
    sourceLine: String,
    automaticPrompt: String? = nil
  ) {
    self.kind = kind
    self.title = title
    self.reference = reference
    self.sourceLine = sourceLine
    self.automaticPrompt = automaticPrompt
  }

  var id: String { "\(kind)|\(reference)|\(title)" }

  var usesGenericTitle: Bool {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return ["page", "file", "entry", "heading", "block", "selection", "context"].contains(normalized)
  }

  var isReply: Bool {
    kind == AIChatContextPresentation.replyKind
  }

  var systemImage: String {
    if isReply { return "arrowshape.turn.up.left" }
    if automaticPrompt != nil { return "sparkles" }
    switch kind.lowercased() {
    case let value where value.contains("block"):
      return "text.quote"
    case let value where value.contains("entry") || value.contains("heading"):
      return "text.line.first.and.arrowtriangle.forward"
    case let value where value.contains("page") || value.contains("file"):
      return "doc.text"
    default:
      return "scope"
    }
  }
}

struct AIChatContextPresentation: Equatable, Sendable {
  static let automaticContextBegin = "#+begin_org2_ai_context"
  static let automaticContextEnd = "#+end_org2_ai_context"

  let contexts: [AIChatPresentedContext]
  let userText: String

  init(_ rawText: String, extractsContexts: Bool = true) {
    guard extractsContexts else {
      contexts = []
      userText = rawText
      return
    }
    var remaining = rawText.replacingOccurrences(of: "\r\n", with: "\n")
    var parsed: [AIChatPresentedContext] = []

    while !remaining.isEmpty {
      guard let (context, rest) = Self.consumeContext(from: remaining) else { break }
      parsed.append(context)
      remaining = rest
    }

    contexts = parsed
    userText = remaining
  }

  func replacingUserText(_ nextUserText: String) -> String {
    Self.serialize(contexts: contexts, userText: nextUserText)
  }

  func removing(_ context: AIChatPresentedContext) -> String {
    Self.serialize(contexts: contexts.filter { $0.id != context.id }, userText: userText)
  }

  var clipboardText: String {
    let contextLines = contexts.map { "[Context: \($0.title)]" }
    return (contextLines + (userText.isEmpty ? [] : [userText])).joined(separator: "\n")
  }

  private static func serialize(contexts: [AIChatPresentedContext], userText: String) -> String {
    guard !contexts.isEmpty else { return userText }
    return contexts.map(\.sourceLine).joined(separator: "\n\n") + "\n\n" + userText
  }

  static func automaticContext(
    kind: String,
    title: String,
    reference: String,
    prompt: String,
    userText: String = ""
  ) -> String {
    let safeTitle = title
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "”", with: "'")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
    let context = """
    Use \(kind) “\(safeTitle)” at \(reference) as context.
    \(automaticContextBegin)
    \(normalizedPrompt)
    \(automaticContextEnd)
    """
    return normalizedUserText.isEmpty ? context : "\(context)\n\n\(normalizedUserText)"
  }

  static let replyKind = "reply to message"
  static let replyTitleLimit = 64
  static let replyExcerptLimit = 1_500

  /// A context that quotes an earlier chat message. The composer shows it as a
  /// removable pill, the transcript as a reply pill, and the agent receives
  /// the quoted excerpt with the user's text.
  static func replyContext(author: String, messageID: UUID, content: String) -> String {
    let text = AIChatContextPresentation(content).userText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let snippet = truncated(firstLine.trimmingCharacters(in: .whitespaces), limit: replyTitleLimit)
    let title = snippet.isEmpty ? author : "\(author): \(snippet)"
    let excerpt = truncated(text, limit: replyExcerptLimit)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> String in
        // Escape Org block syntax so the quote cannot close its container.
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        return trimmed.hasPrefix("#+") || trimmed.hasPrefix(",#+") || trimmed.hasPrefix("*")
          ? ",\(line)"
          : String(line)
      }
      .joined(separator: "\n")
    let speaker = author == "You" ? "their own earlier message" : "this earlier message from \(author)"
    let prompt = [
      "The user is replying to \(speaker):",
      "#+begin_quote",
      excerpt.isEmpty ? "(no text)" : excerpt,
      "#+end_quote",
    ].joined(separator: "\n")
    return automaticContext(
      kind: replyKind,
      title: title,
      reference: "ai-chat-message:\(messageID.uuidString.lowercased())",
      prompt: prompt
    )
  }

  /// Puts `replyContext` first in `draft`, replacing any earlier reply.
  static func draft(_ draft: String, replyingWith replyContext: String) -> String {
    let presentation = AIChatContextPresentation(draft)
    let kept = presentation.contexts.filter { !$0.isReply }
    let rest = serialize(contexts: kept, userText: presentation.userText)
    return rest.isEmpty ? replyContext : replyContext + "\n\n" + rest
  }

  private static func truncated(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }

  private static func consumeContext(
    from remaining: String
  ) -> (context: AIChatPresentedContext, rest: String)? {
    let firstNewline = remaining.firstIndex(of: "\n")
    let header = firstNewline.map { String(remaining[..<$0]) } ?? remaining
    guard var context = parseContextLine(header) else { return nil }

    if let firstNewline {
      let afterHeader = remaining[firstNewline...]
      let automaticPrefix = "\n\(automaticContextBegin)\n"
      if afterHeader.hasPrefix(automaticPrefix) {
        let promptStart = remaining.index(firstNewline, offsetBy: automaticPrefix.count)
        let endToken = "\n\(automaticContextEnd)"
        guard let endRange = remaining.range(
          of: endToken,
          range: promptStart..<remaining.endIndex
        ) else { return nil }
        let prompt = String(remaining[promptStart..<endRange.lowerBound])
        let sourceEnd = endRange.upperBound
        context = AIChatPresentedContext(
          kind: context.kind,
          title: context.title,
          reference: context.reference,
          sourceLine: String(remaining[..<sourceEnd]),
          automaticPrompt: prompt
        )
        return (context, trimmingContextSeparator(from: remaining, after: sourceEnd))
      }
    }

    let separator = remaining.range(of: "\n\n")
    let sourceEnd = separator?.lowerBound ?? remaining.endIndex
    context = AIChatPresentedContext(
      kind: context.kind,
      title: context.title,
      reference: context.reference,
      sourceLine: String(remaining[..<sourceEnd])
    )
    let rest = separator.map { String(remaining[$0.upperBound...]) } ?? ""
    return (context, rest)
  }

  private static func trimmingContextSeparator(
    from source: String,
    after sourceEnd: String.Index
  ) -> String {
    var next = sourceEnd
    var removedNewlines = 0
    while next < source.endIndex,
          source[next] == "\n",
          removedNewlines < 2 {
      next = source.index(after: next)
      removedNewlines += 1
    }
    return String(source[next...])
  }

  private static func parseContextLine(_ line: String) -> AIChatPresentedContext? {
    guard line.hasPrefix("Use "), line.hasSuffix(" as context.") else { return nil }
    let body = String(line.dropFirst(4).dropLast(" as context.".count))
    let kind: String
    let title: String
    let reference: String
    if let quoteStart = body.range(of: " “"),
       let separator = body.range(of: "” at ", range: quoteStart.upperBound..<body.endIndex) {
      kind = String(body[..<quoteStart.lowerBound])
      title = String(body[quoteStart.upperBound..<separator.lowerBound])
      reference = String(body[separator.upperBound...])
    } else {
      guard let separator = body.range(of: " at ") else { return nil }
      kind = String(body[..<separator.lowerBound])
      reference = String(body[separator.upperBound...])
      title = kind
        .replacingOccurrences(of: "selected ", with: "", options: [.caseInsensitive, .anchored])
        .replacingOccurrences(of: "current ", with: "", options: [.caseInsensitive, .anchored])
        .capitalized
    }

    guard !kind.isEmpty, !title.isEmpty else { return nil }
    return AIChatPresentedContext(kind: kind, title: title, reference: reference, sourceLine: line)
  }
}

struct AIChatMessageOrgPresentation: Equatable, Sendable {
  let normalizedText: String
  let blocks: [OrgEditableBlock]
  let usesStructuredRendering: Bool

  nonisolated init(_ rawText: String) {
    normalizedText = AIChatMessageOrgNormalizer.normalized(rawText)
    blocks = OrgEntryRenderer.parseEditable(normalizedText)
    usesStructuredRendering = blocks.contains { block in
      switch block.rendered {
      case .paragraph:
        // Image-only and prose-plus-image replies still need the media renderer.
        // Treating all paragraphs as plain inline text silently drops previews.
        return OrgMediaAttachment.standalone(raw: block.rawText) != nil
          || OrgMediaAttachment.embedded(in: block.rawText) != nil
      case .blank:
        return false
      case .heading, .planning, .properties, .quote, .source, .table,
           .horizontalRule, .listItem, .keyword:
        return true
      }
    }
  }
}

struct AIChatMessageBodyExcerpt: Equatable, Sendable {
  static let collapsedUTF8ByteLimit = 32 * 1_024

  let text: String
  let isTruncated: Bool

  nonisolated init(_ rawText: String, utf8ByteLimit: Int?) {
    guard let utf8ByteLimit else {
      text = rawText
      isTruncated = false
      return
    }

    let resolvedLimit = max(0, utf8ByteLimit)
    var end = rawText.startIndex
    var byteCount = 0
    var truncated = false
    for character in rawText {
      let characterByteCount = String(character).utf8.count
      if byteCount + characterByteCount > resolvedLimit {
        truncated = true
        break
      }
      byteCount += characterByteCount
      end = rawText.index(after: end)
    }
    text = truncated ? String(rawText[..<end]) : rawText
    isTruncated = truncated
  }

  nonisolated static func displayedUTF8ByteCount(for rawText: String) -> Int {
    rawText.utf8.prefix(collapsedUTF8ByteLimit).count
  }
}

struct AIChatPreparedMessageBody: Equatable, Sendable {
  let sourceText: String
  let displayedText: String
  let isTruncated: Bool
  let org: AIChatMessageOrgPresentation?
  let containsInlineSyntax: Bool
}

struct AIChatMessagePresentationInput: Equatable, Sendable {
  let messageID: UUID
  let role: AIChatMessage.Role
  let rawText: String
  let responseTrace: AIChatResponseTrace?

  nonisolated init(_ message: AIChatMessage) {
    messageID = message.id
    role = message.role
    rawText = message.content
    responseTrace = message.responseTrace
  }
}

struct AIChatMessagePresentationRevision: Equatable, Hashable, Sendable {
  private struct Payload: Encodable {
    let role: AIChatMessage.Role
    let rawText: String
    let responseTrace: AIChatResponseTrace?
  }

  let bytes: [UInt8]

  nonisolated init(_ input: AIChatMessagePresentationInput) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = Payload(
      role: input.role,
      rawText: input.rawText,
      responseTrace: input.responseTrace
    )
    let data = (try? encoder.encode(payload)) ?? Data(input.rawText.utf8)
    bytes = Array(SHA256.hash(data: data))
  }
}

final class AIChatCachedMessagePresentation: Sendable {
  let revision: AIChatMessagePresentationRevision?
  let role: AIChatMessage.Role
  let rawText: String
  let responseTrace: AIChatResponseTrace?
  let context: AIChatContextPresentation
  let body: AIChatPreparedMessageBody
  let activityFeedItems: [AIChatActivityFeedItem]

  init(
    revision: AIChatMessagePresentationRevision? = nil,
    role: AIChatMessage.Role,
    rawText: String,
    responseTrace: AIChatResponseTrace?,
    context: AIChatContextPresentation,
    body: AIChatPreparedMessageBody,
    activityFeedItems: [AIChatActivityFeedItem]
  ) {
    self.revision = revision
    self.role = role
    self.rawText = rawText
    self.responseTrace = responseTrace
    self.context = context
    self.body = body
    self.activityFeedItems = activityFeedItems
  }

  var org: AIChatMessageOrgPresentation? { body.org }

  nonisolated func matches(_ input: AIChatMessagePresentationInput) -> Bool {
    guard let revision else { return false }
    return revision == AIChatMessagePresentationRevision(input)
  }

  func matches(_ message: AIChatMessage) -> Bool {
    matches(AIChatMessagePresentationInput(message))
  }
}

struct AIChatPreparedMessagePresentation: Sendable {
  let messageID: UUID
  let value: AIChatCachedMessagePresentation
  let estimatedCost: Int
}

struct AIChatResolvedMessagePresentation: Sendable {
  let revision: AIChatMessagePresentationRevision
  let value: AIChatCachedMessagePresentation
  let preparedForCacheInstall: AIChatPreparedMessagePresentation?
}

struct AIChatExpandedMessageBodyInput: Equatable, Sendable {
  static let pageCharacterLimit = 64 * 1_024

  let messageID: UUID
  let role: AIChatMessage.Role
  let sourceText: String
  let pageIndex: Int

  init(
    messageID: UUID,
    role: AIChatMessage.Role,
    sourceText: String,
    pageIndex: Int = 0
  ) {
    self.messageID = messageID
    self.role = role
    self.sourceText = sourceText
    self.pageIndex = max(0, pageIndex)
  }
}

enum AIChatMessagePresentationBuilder {
  private static let placeholderUTF8ByteLimit = 2 * 1_024

  nonisolated static func prepare(
    _ input: AIChatMessagePresentationInput,
    revision suppliedRevision: AIChatMessagePresentationRevision? = nil
  ) -> AIChatPreparedMessagePresentation {
    let revision = suppliedRevision ?? AIChatMessagePresentationRevision(input)
    let context = AIChatContextPresentation(
      input.rawText,
      extractsContexts: input.role == .user
    )
    let body = prepareBody(
      sourceText: context.userText,
      role: input.role,
      utf8ByteLimit: AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit
    )
    let activityFeedItems = input.responseTrace.map {
      AIChatActivityFeed.items(from: $0.activities)
    } ?? []
    let value = AIChatCachedMessagePresentation(
      revision: revision,
      role: input.role,
      rawText: input.rawText,
      responseTrace: input.responseTrace,
      context: context,
      body: body,
      activityFeedItems: activityFeedItems
    )
    return AIChatPreparedMessagePresentation(
      messageID: input.messageID,
      value: value,
      estimatedCost: estimatedCost(
        input: input,
        context: context,
        body: body,
        activityFeedItems: activityFeedItems
      )
    )
  }

  nonisolated static func prepareExpandedBody(
    sourceText: String,
    role: AIChatMessage.Role,
    pageIndex: Int? = nil
  ) -> AIChatPreparedMessageBody? {
    guard !Task.isCancelled else { return nil }
    let body: AIChatPreparedMessageBody
    if let pageIndex {
      let startOffset = max(0, pageIndex) * AIChatExpandedMessageBodyInput.pageCharacterLimit
      let start = sourceText.index(
        sourceText.startIndex,
        offsetBy: startOffset,
        limitedBy: sourceText.endIndex
      ) ?? sourceText.endIndex
      let end = sourceText.index(
        start,
        offsetBy: AIChatExpandedMessageBodyInput.pageCharacterLimit,
        limitedBy: sourceText.endIndex
      ) ?? sourceText.endIndex
      let preparedPage = prepareBody(
        sourceText: String(sourceText[start..<end]),
        role: role,
        utf8ByteLimit: nil
      )
      body = AIChatPreparedMessageBody(
        sourceText: sourceText,
        displayedText: preparedPage.displayedText,
        isTruncated: end < sourceText.endIndex,
        org: preparedPage.org,
        containsInlineSyntax: preparedPage.containsInlineSyntax
      )
    } else {
      body = prepareBody(sourceText: sourceText, role: role, utf8ByteLimit: nil)
    }
    guard !Task.isCancelled else { return nil }
    return body
  }

  nonisolated static func placeholder(
    _ input: AIChatMessagePresentationInput
  ) -> AIChatCachedMessagePresentation {
    if input.role == .user {
      return AIChatCachedMessagePresentation(
        role: input.role,
        rawText: input.rawText,
        responseTrace: input.responseTrace,
        context: AIChatContextPresentation("", extractsContexts: false),
        body: AIChatPreparedMessageBody(
          sourceText: "",
          displayedText: "Preparing message…",
          isTruncated: false,
          org: nil,
          containsInlineSyntax: false
        ),
        activityFeedItems: []
      )
    }
    let excerpt = AIChatMessageBodyExcerpt(
      input.rawText,
      utf8ByteLimit: placeholderUTF8ByteLimit
    )
    let exceedsCollapsedLimit = input.rawText.utf8
      .prefix(AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit + 1)
      .count > AIChatMessageBodyExcerpt.collapsedUTF8ByteLimit
    return AIChatCachedMessagePresentation(
      role: input.role,
      rawText: input.rawText,
      responseTrace: input.responseTrace,
      context: AIChatContextPresentation(input.rawText, extractsContexts: false),
      body: AIChatPreparedMessageBody(
        sourceText: input.rawText,
        displayedText: excerpt.text,
        isTruncated: exceedsCollapsedLimit,
        org: nil,
        containsInlineSyntax: false
      ),
      activityFeedItems: []
    )
  }

  private nonisolated static func prepareBody(
    sourceText: String,
    role: AIChatMessage.Role,
    utf8ByteLimit: Int?
  ) -> AIChatPreparedMessageBody {
    let excerpt = AIChatMessageBodyExcerpt(sourceText, utf8ByteLimit: utf8ByteLimit)
    let org = role == .assistant
      ? AIChatMessageOrgPresentation(excerpt.text)
      : nil
    let inlineText = org?.normalizedText ?? excerpt.text
    let containsInlineSyntax = org?.usesStructuredRendering == true
      ? false
      : OrgInlineParser.hasInlineSyntaxCandidate(inlineText)
    return AIChatPreparedMessageBody(
      sourceText: sourceText,
      displayedText: excerpt.text,
      isTruncated: excerpt.isTruncated,
      org: org,
      containsInlineSyntax: containsInlineSyntax
    )
  }

  private nonisolated static func estimatedCost(
    input: AIChatMessagePresentationInput,
    context: AIChatContextPresentation,
    body: AIChatPreparedMessageBody,
    activityFeedItems: [AIChatActivityFeedItem]
  ) -> Int {
    var cost = input.rawText.utf8.count
      + context.userText.utf8.count
      + body.displayedText.utf8.count
      + (body.org?.normalizedText.utf8.count ?? 0)
      + (input.responseTrace?.reasoning.utf8.count ?? 0)
    for contextItem in context.contexts {
      cost += contextItem.kind.utf8.count
        + contextItem.title.utf8.count
        + contextItem.reference.utf8.count
        + contextItem.sourceLine.utf8.count
        + (contextItem.automaticPrompt?.utf8.count ?? 0)
    }
    for block in body.org?.blocks ?? [] {
      cost += block.rawText.utf8.count
    }
    for item in activityFeedItems {
      cost += item.id.utf8.count
      cost += item.title.utf8.count
      cost += item.detail?.utf8.count ?? 0
      cost += item.latestDetail?.utf8.count ?? 0
      cost += 128
    }
    return cost
  }
}

actor AIChatMessagePresentationPreparationCoordinator {
  static let shared = AIChatMessagePresentationPreparationCoordinator()
  private static let maximumConcurrentWorkerCount = 2

  private struct Entry {
    let token: UUID
    let input: AIChatMessagePresentationInput
    let task: Task<AIChatPreparedMessagePresentation, Never>
  }

  private var entries: [UUID: [Entry]] = [:]
  private var workerPermitWaiters: [CheckedContinuation<Void, Never>] = []
  private var preparationCountForTesting = 0
  private var activeWorkerCountValueForTesting = 0
  private var peakConcurrentWorkerCountValueForTesting = 0
  private var activeWorkerCountsByMessageForTesting: [UUID: Int] = [:]
  private var peakWorkerCountsByMessageForTesting: [UUID: Int] = [:]
  private var pausesWorkersForTesting = false
  private var pausedWorkerContinuationsForTesting: [CheckedContinuation<Void, Never>] = []

  func prepare(
    _ input: AIChatMessagePresentationInput
  ) async -> AIChatPreparedMessagePresentation {
    await prepare(input, revision: nil)
  }

  func resolve(
    _ input: AIChatMessagePresentationInput,
    cachedCandidate: AIChatCachedMessagePresentation?
  ) async -> AIChatResolvedMessagePresentation {
    let revision = AIChatMessagePresentationRevision(input)
    if cachedCandidate?.revision == revision,
       let cachedCandidate {
      return AIChatResolvedMessagePresentation(
        revision: revision,
        value: cachedCandidate,
        preparedForCacheInstall: nil
      )
    }
    let prepared = await prepare(input, revision: revision)
    return AIChatResolvedMessagePresentation(
      revision: revision,
      value: prepared.value,
      preparedForCacheInstall: prepared
    )
  }

  private func prepare(
    _ input: AIChatMessagePresentationInput,
    revision: AIChatMessagePresentationRevision?
  ) async -> AIChatPreparedMessagePresentation {
    let token: UUID
    let task: Task<AIChatPreparedMessagePresentation, Never>
    if let existing = entries[input.messageID]?.first(where: { $0.input == input }) {
      token = existing.token
      task = existing.task
    } else {
      let previousTask = entries[input.messageID]?.last?.task
      token = UUID()
      task = Task.detached(priority: .userInitiated) {
        if let previousTask {
          _ = await previousTask.value
        }
        await self.acquireWorkerPermit(messageID: input.messageID)
        let prepared = AIChatMessagePresentationBuilder.prepare(
          input,
          revision: revision
        )
        await self.releaseWorkerPermit(messageID: input.messageID)
        return prepared
      }
      entries[input.messageID, default: []].append(Entry(
        token: token,
        input: input,
        task: task
      ))
      preparationCountForTesting += 1
    }
    let prepared = await task.value
    removeFinishedEntry(messageID: input.messageID, token: token)
    return prepared
  }

  private func removeFinishedEntry(messageID: UUID, token: UUID) {
    guard var messageEntries = entries[messageID] else { return }
    messageEntries.removeAll { $0.token == token }
    if messageEntries.isEmpty {
      entries.removeValue(forKey: messageID)
    } else {
      entries[messageID] = messageEntries
    }
  }

  private func acquireWorkerPermit(messageID: UUID) async {
    if activeWorkerCountValueForTesting >= Self.maximumConcurrentWorkerCount {
      await withCheckedContinuation { continuation in
        workerPermitWaiters.append(continuation)
      }
    } else {
      activeWorkerCountValueForTesting += 1
      peakConcurrentWorkerCountValueForTesting = max(
        peakConcurrentWorkerCountValueForTesting,
        activeWorkerCountValueForTesting
      )
    }
    let messageWorkerCount = (activeWorkerCountsByMessageForTesting[messageID] ?? 0) + 1
    activeWorkerCountsByMessageForTesting[messageID] = messageWorkerCount
    peakWorkerCountsByMessageForTesting[messageID] = max(
      peakWorkerCountsByMessageForTesting[messageID] ?? 0,
      messageWorkerCount
    )
    guard pausesWorkersForTesting else { return }
    await withCheckedContinuation { continuation in
      pausedWorkerContinuationsForTesting.append(continuation)
    }
  }

  private func releaseWorkerPermit(messageID: UUID) {
    let messageWorkerCount = max(
      0,
      (activeWorkerCountsByMessageForTesting[messageID] ?? 1) - 1
    )
    if messageWorkerCount == 0 {
      activeWorkerCountsByMessageForTesting.removeValue(forKey: messageID)
    } else {
      activeWorkerCountsByMessageForTesting[messageID] = messageWorkerCount
    }
    if workerPermitWaiters.isEmpty {
      activeWorkerCountValueForTesting -= 1
    } else {
      workerPermitWaiters.removeFirst().resume()
    }
  }

  func resetForTesting() async {
    setWorkersPausedForTesting(false)
    let pendingTasks = entries.values.flatMap { $0 }.map(\.task)
    for task in pendingTasks {
      _ = await task.value
    }
    entries.removeAll()
    preparationCountForTesting = 0
    activeWorkerCountValueForTesting = 0
    peakConcurrentWorkerCountValueForTesting = 0
    activeWorkerCountsByMessageForTesting.removeAll()
    peakWorkerCountsByMessageForTesting.removeAll()
  }

  func countForTesting() -> Int { preparationCountForTesting }
  func activeWorkerCountForTesting() -> Int { activeWorkerCountValueForTesting }
  func peakConcurrentWorkerCountForTesting() -> Int { peakConcurrentWorkerCountValueForTesting }
  func peakWorkerCountForTesting(messageID: UUID) -> Int {
    peakWorkerCountsByMessageForTesting[messageID] ?? 0
  }
  func maximumConcurrentWorkerCountForTesting() -> Int {
    Self.maximumConcurrentWorkerCount
  }

  func setWorkersPausedForTesting(_ paused: Bool) {
    pausesWorkersForTesting = paused
    guard !paused else { return }
    let continuations = pausedWorkerContinuationsForTesting
    pausedWorkerContinuationsForTesting.removeAll()
    continuations.forEach { $0.resume() }
  }
}

actor AIChatExpandedMessageBodyPreparationCoordinator {
  static let shared = AIChatExpandedMessageBodyPreparationCoordinator()

  private struct Entry {
    let token: UUID
    let input: AIChatExpandedMessageBodyInput
    let task: Task<AIChatPreparedMessageBody?, Never>
  }

  private var entries: [UUID: [Entry]] = [:]
  private var preparationCountForTesting = 0
  private var activeWorkerCountValueForTesting = 0
  private var peakConcurrentWorkerCountValueForTesting = 0
  private var pausesWorkersForTesting = false
  private var pausedWorkerContinuationsForTesting: [CheckedContinuation<Void, Never>] = []

  func prepare(
    _ input: AIChatExpandedMessageBodyInput
  ) async -> AIChatPreparedMessageBody? {
    let token: UUID
    let task: Task<AIChatPreparedMessageBody?, Never>
    if let existing = entries[input.messageID]?.first(where: { $0.input == input }) {
      token = existing.token
      task = existing.task
    } else {
      let previousTask = entries[input.messageID]?.last?.task
      token = UUID()
      task = Task.detached(priority: .userInitiated) {
        if let previousTask {
          _ = await previousTask.value
        }
        await self.workerDidStart()
        let prepared = AIChatMessagePresentationBuilder.prepareExpandedBody(
          sourceText: input.sourceText,
          role: input.role,
          pageIndex: input.pageIndex
        )
        await self.workerDidFinish()
        return prepared
      }
      entries[input.messageID, default: []].append(Entry(
        token: token,
        input: input,
        task: task
      ))
      preparationCountForTesting += 1
    }
    let prepared = await task.value
    removeFinishedEntry(messageID: input.messageID, token: token)
    return Task.isCancelled ? nil : prepared
  }

  private func removeFinishedEntry(messageID: UUID, token: UUID) {
    guard var messageEntries = entries[messageID] else { return }
    messageEntries.removeAll { $0.token == token }
    if messageEntries.isEmpty {
      entries.removeValue(forKey: messageID)
    } else {
      entries[messageID] = messageEntries
    }
  }

  private func workerDidStart() async {
    activeWorkerCountValueForTesting += 1
    peakConcurrentWorkerCountValueForTesting = max(
      peakConcurrentWorkerCountValueForTesting,
      activeWorkerCountValueForTesting
    )
    guard pausesWorkersForTesting else { return }
    await withCheckedContinuation { continuation in
      pausedWorkerContinuationsForTesting.append(continuation)
    }
  }

  private func workerDidFinish() {
    activeWorkerCountValueForTesting -= 1
  }

  func resetForTesting() async {
    setWorkersPausedForTesting(false)
    let pendingTasks = entries.values.flatMap { $0 }.map(\.task)
    pendingTasks.forEach { $0.cancel() }
    for task in pendingTasks {
      _ = await task.value
    }
    entries.removeAll()
    preparationCountForTesting = 0
    activeWorkerCountValueForTesting = 0
    peakConcurrentWorkerCountValueForTesting = 0
  }

  func countForTesting() -> Int { preparationCountForTesting }
  func activeWorkerCountForTesting() -> Int { activeWorkerCountValueForTesting }
  func peakConcurrentWorkerCountForTesting() -> Int { peakConcurrentWorkerCountValueForTesting }

  func setWorkersPausedForTesting(_ paused: Bool) {
    pausesWorkersForTesting = paused
    guard !paused else { return }
    let continuations = pausedWorkerContinuationsForTesting
    pausedWorkerContinuationsForTesting.removeAll()
    continuations.forEach { $0.resume() }
  }
}

@MainActor
enum AIChatMessagePresentationCache {
  private final class CacheKey: NSObject {
    let messageID: UUID

    init(messageID: UUID) {
      self.messageID = messageID
    }

    override var hash: Int { messageID.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? CacheKey else { return false }
      return messageID == other.messageID
    }
  }

  private static let cache: NSCache<CacheKey, AIChatCachedMessagePresentation> = {
    let cache = NSCache<CacheKey, AIChatCachedMessagePresentation>()
    cache.countLimit = 1_024
    cache.totalCostLimit = 32 * 1_024 * 1_024
    return cache
  }()

  static func presentation(for message: AIChatMessage) -> AIChatCachedMessagePresentation {
    let input = AIChatMessagePresentationInput(message)
    let key = CacheKey(messageID: input.messageID)
    if let cached = cache.object(forKey: key), cached.matches(input) {
      return cached
    }

    let prepared = AIChatMessagePresentationBuilder.prepare(input)
    install(prepared)
    return prepared.value
  }

  static func cachedPresentation(
    for input: AIChatMessagePresentationInput
  ) -> AIChatCachedMessagePresentation? {
    guard let cached = cache.object(forKey: CacheKey(messageID: input.messageID)),
          cached.matches(input)
    else { return nil }
    return cached
  }

  static func cachedPresentation(
    messageID: UUID
  ) -> AIChatCachedMessagePresentation? {
    cache.object(forKey: CacheKey(messageID: messageID))
  }

  static func install(_ prepared: AIChatPreparedMessagePresentation) {
    cache.setObject(
      prepared.value,
      forKey: CacheKey(messageID: prepared.messageID),
      cost: prepared.estimatedCost
    )
  }

  static func install(_ prepared: [AIChatPreparedMessagePresentation]) {
    for presentation in prepared {
      install(presentation)
    }
  }

  static func removeAllForTesting() {
    cache.removeAllObjects()
  }

  static func cachedPresentationForTesting(
    messageID: UUID
  ) -> AIChatCachedMessagePresentation? {
    cache.object(forKey: CacheKey(messageID: messageID))
  }
}

enum AIChatMessageOrgNormalizer {
  private nonisolated static let blockDirectiveNames = [
    "begin_src",
    "end_src",
    "begin_example",
    "end_example",
    "begin_quote",
    "end_quote"
  ]

  nonisolated static func normalized(_ rawText: String) -> String {
    // Legacy Markdown links become Org links first, so the emphasis repairs
    // below see one link syntax.
    let text = AIChatCitationNormalizer.normalized(rawText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n"))
    var lines = text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var literalBlockEnd: String?

    for index in lines.indices {
      lines[index] = normalizedBlockDirective(lines[index])
      let trimmed = lines[index].trimmingCharacters(in: .whitespaces).lowercased()
      if let end = literalBlockEnd {
        if trimmed.hasPrefix(end) { literalBlockEnd = nil }
        continue
      }
      if let kind = ["src", "example", "export", "comment"].first(where: { trimmed.hasPrefix("#+begin_" + $0) }) {
        literalBlockEnd = "#+end_" + kind
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        literalBlockEnd = String(trimmed.prefix(3))
        continue
      }
      lines[index] = normalizedMarkdownStrongEmphasis(lines[index])
      lines[index] = normalizedNestedInlineEmphasis(lines[index])

      guard index > lines.startIndex,
            isTableSeparator(lines[index]),
            let cells = tableCells(lines[lines.index(before: index)]),
            cells.count > 1
      else {
        continue
      }

      let trimmedSeparator = lines[index].trimmingCharacters(in: .whitespaces)
      let actualJoinCount = trimmedSeparator.filter { $0 == "+" }.count
      guard actualJoinCount != cells.count - 1 else { continue }

      let indentation = String(lines[index].prefix { $0 == " " || $0 == "\t" })
      let hline = "|" + cells
        .map { String(repeating: "-", count: max(3, $0.count + 2)) }
        .joined(separator: "+") + "|"
      lines[index] = indentation + hline
    }

    return lines.joined(separator: "\n")
  }

  /// Agent replies often use Markdown strong emphasis (`**bold**`). Org reads
  /// that as bold text with literal asterisks, and a Markdown table cell such
  /// as `**[label](url)**` then shows raw link syntax. Convert the Markdown
  /// span to Org bold at the chat boundary; code, verbatim, and links stay literal.
  private nonisolated static func normalizedMarkdownStrongEmphasis(_ line: String) -> String {
    guard line.contains("**") else { return line }
    var output = ""
    var cursor = line.startIndex

    while cursor < line.endIndex {
      if let protectedSpan = protectedInlineSpan(in: line, at: cursor) {
        output += line[cursor..<protectedSpan.end]
        cursor = protectedSpan.end
        continue
      }
      if let strong = markdownStrongSpan(in: line, at: cursor) {
        output += "*" + strong.content + "*"
        cursor = strong.end
        continue
      }
      output.append(line[cursor])
      cursor = line.index(after: cursor)
    }
    return output
  }

  private nonisolated static func markdownStrongSpan(
    in line: String,
    at open: String.Index
  ) -> (content: String, end: String.Index)? {
    guard line[open...].hasPrefix("**"),
          open == line.startIndex || isInlineBoundary(line[line.index(before: open)])
    else { return nil }
    let contentStart = line.index(open, offsetBy: 2)
    guard contentStart < line.endIndex,
          !line[contentStart].isWhitespace,
          line[contentStart] != "*"
    else { return nil }

    var search = contentStart
    while search < line.endIndex,
          let close = line.range(of: "**", range: search..<line.endIndex) {
      let afterClose = close.upperBound
      if close.lowerBound > contentStart,
         !line[line.index(before: close.lowerBound)].isWhitespace,
         afterClose == line.endIndex || (line[afterClose] != "*" && isInlineBoundary(line[afterClose])) {
        return (String(line[contentStart..<close.lowerBound]), afterClose)
      }
      search = line.index(after: close.lowerBound)
    }
    return nil
  }

  private nonisolated static func normalizedBlockDirective(_ line: String) -> String {
    let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
    let trimmed = line.dropFirst(indentation.count)
    let hashCount = trimmed.prefix { $0 == "#" }.count
    guard hashCount > 1 else { return line }
    let suffix = trimmed.dropFirst(hashCount)
    guard suffix.first == "+" else { return line }
    let directive = suffix.dropFirst().lowercased()
    guard blockDirectiveNames.contains(where: {
      directive == $0 || directive.hasPrefix($0 + " ") || directive.hasPrefix($0 + "\t")
    }) else { return line }
    return indentation + "#" + suffix
  }

  /// Agent replies occasionally wrap an Org verbatim/code span or a bracket
  /// link inside bold or italic emphasis even though Org2 inline spans
  /// deliberately do not nest (a link inside `*...*` would render as raw
  /// `[[target][label]]` text).
  /// Keep the language rule simple and repair that common presentation mistake
  /// at the chat boundary so both intended styles remain visible.
  private nonisolated static func normalizedNestedInlineEmphasis(_ line: String) -> String {
    var output = ""
    var cursor = line.startIndex

    while cursor < line.endIndex {
      // Links shield their bytes: a `/` in a URL never opens emphasis.
      if line[cursor...].hasPrefix("[["),
         let close = line.range(of: "]]", range: line.index(cursor, offsetBy: 2)..<line.endIndex) {
        output += line[cursor..<close.upperBound]
        cursor = close.upperBound
        continue
      }
      guard let repaired = repairedNestedInlineEmphasis(in: line, at: cursor) else {
        output.append(line[cursor])
        cursor = line.index(after: cursor)
        continue
      }
      output += repaired.text
      cursor = repaired.end
    }
    return output
  }

  private nonisolated static func repairedNestedInlineEmphasis(
    in line: String,
    at open: String.Index
  ) -> (text: String, end: String.Index)? {
    let marker = line[open]
    guard marker == "*" || marker == "/" else { return nil }
    let contentStart = line.index(after: open)
    guard contentStart < line.endIndex,
          !line[contentStart].isWhitespace,
          open == line.startIndex || isInlineBoundary(line[line.index(before: open)])
    else { return nil }

    var search = contentStart
    while search < line.endIndex, let close = line[search...].firstIndex(of: marker) {
      let afterClose = line.index(after: close)
      if !line[line.index(before: close)].isWhitespace,
         afterClose == line.endIndex || isInlineBoundary(line[afterClose]) {
        let body = String(line[contentStart..<close])
        if let repairedBody = repairedOuterEmphasisBody(body, marker: marker) {
          return (repairedBody, afterClose)
        }
      }
      search = afterClose
    }
    return nil
  }

  private enum NestedInlinePiece {
    case plain(String)
    case protected(String)
  }

  private struct ProtectedInlineSpan {
    let end: String.Index
  }

  private nonisolated static func repairedOuterEmphasisBody(
    _ body: String,
    marker: Character
  ) -> String? {
    var pieces: [NestedInlinePiece] = []
    var plainStart = body.startIndex
    var cursor = body.startIndex
    var foundProtectedSpan = false

    while cursor < body.endIndex {
      if let protectedSpan = protectedInlineSpan(in: body, at: cursor) {
        pieces.append(.plain(String(body[plainStart..<cursor])))
        pieces.append(.protected(String(body[cursor..<protectedSpan.end])))
        foundProtectedSpan = true
        cursor = protectedSpan.end
        plainStart = cursor
      } else {
        cursor = body.index(after: cursor)
      }
    }
    guard foundProtectedSpan else { return nil }
    pieces.append(.plain(String(body[plainStart...])))

    return pieces.map { piece in
      switch piece {
      case .protected(let raw):
        return raw
      case .plain(let raw):
        return emphasizedPlainSegment(raw, marker: marker)
      }
    }.joined()
  }

  private nonisolated static func protectedInlineSpan(
    in text: String,
    at open: String.Index
  ) -> ProtectedInlineSpan? {
    if text[open...].hasPrefix("[["),
       let close = text.range(of: "]]", range: text.index(open, offsetBy: 2)..<text.endIndex) {
      return ProtectedInlineSpan(end: close.upperBound)
    }
    let marker = text[open]
    guard marker == "=" || marker == "~" else { return nil }
    let contentStart = text.index(after: open)
    guard contentStart < text.endIndex,
          !text[contentStart].isWhitespace,
          open == text.startIndex || isInlineBoundary(text[text.index(before: open)])
    else { return nil }

    var search = contentStart
    while search < text.endIndex, let close = text[search...].firstIndex(of: marker) {
      let afterClose = text.index(after: close)
      if !text[text.index(before: close)].isWhitespace,
         afterClose == text.endIndex || isInlineBoundary(text[afterClose]) {
        return ProtectedInlineSpan(end: afterClose)
      }
      search = afterClose
    }
    return nil
  }

  private nonisolated static func emphasizedPlainSegment(
    _ raw: String,
    marker: Character
  ) -> String {
    guard let contentStart = raw.firstIndex(where: { !$0.isWhitespace }),
          let contentEndCharacter = raw.lastIndex(where: { !$0.isWhitespace })
    else { return raw }
    let contentEnd = raw.index(after: contentEndCharacter)
    return String(raw[..<contentStart])
      + String(marker) + String(raw[contentStart..<contentEnd]) + String(marker)
      + String(raw[contentEnd...])
  }

  private nonisolated static func isInlineBoundary(_ character: Character) -> Bool {
    if character.isWhitespace { return true }
    let isASCIIWord = character.unicodeScalars.allSatisfy { scalar in
      (65...90).contains(Int(scalar.value))
        || (97...122).contains(Int(scalar.value))
        || (48...57).contains(Int(scalar.value))
    }
    return !isASCIIWord
  }

  private nonisolated static func isTableSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return false }
    let inner = trimmed.dropFirst().dropLast()
    if inner.contains("-") && inner.allSatisfy({ $0 == "-" || $0 == "+" || $0.isWhitespace }) { return true }
    // Markdown delimiter rows (`|---|:---:|`) become Org hlines at the chat
    // boundary, so pipe tables in replies render (and chart) as tables.
    let cells = inner.split(separator: "|", omittingEmptySubsequences: false)
    return cells.count > 1 && cells.allSatisfy { cell in
      let body = cell.trimmingCharacters(in: .whitespaces)
      let dashes = body.drop { $0 == ":" }.reversed().drop { $0 == ":" }
      return dashes.count >= 3 && dashes.allSatisfy { $0 == "-" } && body.count - dashes.count <= 2
    }
  }

  private nonisolated static func tableCells(_ line: String) -> [String]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
    let cells = trimmed
      .dropFirst()
      .dropLast()
      .split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    return cells.isEmpty ? nil : cells
  }
}

private struct AIChatMediaCorpusRootKey: EnvironmentKey {
  static let defaultValue: URL? = nil
}

private struct AIChatRecognizedMentionsKey: EnvironmentKey {
  static let defaultValue: [String] = []
}

/// Resolves a Celorga chat thread ID to its title. Nil for unknown threads.
struct AIChatThreadLinkResolver: Sendable {
  var title: @MainActor @Sendable (UUID) -> String? = { _ in nil }
  var open: @MainActor @Sendable (UUID) -> Void = { _ in }
}

private struct AIChatThreadLinkResolverKey: EnvironmentKey {
  static let defaultValue = AIChatThreadLinkResolver()
}

extension EnvironmentValues {
  var aiChatMediaCorpusRoot: URL? {
    get { self[AIChatMediaCorpusRootKey.self] }
    set { self[AIChatMediaCorpusRootKey.self] = newValue }
  }

  /// Lowercased mention tokens (without `@`) that address a configured agent.
  /// Chat message documents highlight these so a real mention reads differently
  /// from literal `@` text.
  var aiChatRecognizedMentions: [String] {
    get { self[AIChatRecognizedMentionsKey.self] }
    set { self[AIChatRecognizedMentionsKey.self] = newValue }
  }

  /// Turns pasted chat thread IDs into links titled with the thread's name.
  var aiChatThreadLinks: AIChatThreadLinkResolver {
    get { self[AIChatThreadLinkResolverKey.self] }
    set { self[AIChatThreadLinkResolverKey.self] = newValue }
  }
}

struct AIChatMessageBodyView: View {
  let rawText: String
  let rendersStructuredOrg2: Bool
  let structuredPresentation: AIChatMessageOrgPresentation?

  var body: some View {
    AIChatDocumentBody(
      text: rendersStructuredOrg2
        ? (structuredPresentation?.normalizedText ?? AIChatMessageOrgNormalizer.normalized(rawText))
        : rawText,
      formatted: rendersStructuredOrg2
    )
  }
}

private struct AIChatMessageExpansionTaskKey: Equatable {
  let messageID: UUID
  let role: AIChatMessage.Role
  let createdAt: Date
  let pageIndex: Int
  let wantsFullBody: Bool
  let presentationRevision: AIChatMessagePresentationRevision?
}

@MainActor
private final class AIChatMessageAccessibilityPressView: NSView {
  var activate: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Pointer input stays with the visible SwiftUI button. This view only
    // supplies a stable native accessibility action for automation and VoiceOver.
    nil
  }

  override func accessibilityPerformPress() -> Bool {
    activate?()
    return activate != nil
  }
}

private struct AIChatMessageAccessibilityPressTarget: NSViewRepresentable {
  let identifier: String
  let label: String
  let activate: () -> Void

  func makeNSView(context: Context) -> AIChatMessageAccessibilityPressView {
    AIChatMessageAccessibilityPressView(frame: .zero)
  }

  func updateNSView(
    _ view: AIChatMessageAccessibilityPressView,
    context: Context
  ) {
    view.activate = activate
    view.setAccessibilityIdentifier(identifier)
    view.setAccessibilityLabel(label)
  }
}

private struct AIChatMessageAccessibilityMarker: NSViewRepresentable {
  let identifier: String
  let label: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.staticText)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    view.setAccessibilityIdentifier(identifier)
    view.setAccessibilityLabel(label)
  }
}

private struct AIChatMessagePresentationResolver: NSViewRepresentable {
  let input: AIChatMessagePresentationInput
  let onResolve: @MainActor (AIChatResolvedMessagePresentation) -> Void

  @MainActor
  final class Coordinator {
    private var requestGeneration = 0
    private var task: Task<Void, Never>?
    private var lastAppliedRevision: AIChatMessagePresentationRevision?

    func resolve(
      input: AIChatMessagePresentationInput,
      onResolve: @escaping @MainActor (AIChatResolvedMessagePresentation) -> Void
    ) {
      requestGeneration &+= 1
      let generation = requestGeneration
      let cachedCandidate = AIChatMessagePresentationCache.cachedPresentation(
        messageID: input.messageID
      )
      task?.cancel()
      task = Task { @MainActor in
        let resolved = await AIChatMessagePresentationPreparationCoordinator.shared.resolve(
          input,
          cachedCandidate: cachedCandidate
        )
        guard !Task.isCancelled,
              generation == requestGeneration
        else { return }
        if let prepared = resolved.preparedForCacheInstall {
          AIChatMessagePresentationCache.install(prepared)
        }
        guard lastAppliedRevision != resolved.revision else { return }
        lastAppliedRevision = resolved.revision
        onResolve(resolved)
      }
    }

    func cancel() {
      requestGeneration &+= 1
      task?.cancel()
      task = nil
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    view.setAccessibilityElement(false)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.resolve(input: input, onResolve: onResolve)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.cancel()
  }
}

private extension OrgEditableBlock {
  var isRenderedTable: Bool {
    if case .table = rendered { return true }
    return false
  }
}

@MainActor
enum AIChatNestedScrollWheelRouting {
  static func outerScrollView(
    for hitView: NSView,
    deltaX: CGFloat,
    deltaY: CGFloat
  ) -> NSScrollView? {
    guard abs(deltaY) > abs(deltaX), abs(deltaY) > 0 else { return nil }

    var scrollViews: [NSScrollView] = []
    var candidate: NSView? = hitView
    while let view = candidate {
      if let scrollView = view as? NSScrollView {
        scrollViews.append(scrollView)
      }
      candidate = view.superview
    }
    guard scrollViews.count >= 2 else { return nil }

    let innerScrollView = scrollViews[0]
    guard !innerScrollView.hasVerticalScroller else { return nil }
    return scrollViews[1]
  }
}

struct ChatBubbleView: View {

  let message: AIChatMessage
  let runtime: AIChatRuntime
  let destinationTitlesByID: [String: String]
  let compact: Bool
  let isQueued: Bool
  let isRoomResponse: Bool
  let isSearchMatch: Bool
  let isSelectedSearchMatch: Bool
  let selectedSearchMatchPageIndex: Int
  let canSteerQueuedMessage: Bool
  let steerQueuedMessage: () -> Void
  let editQueuedMessage: () -> Void
  let deleteQueuedMessage: () -> Void
  @State private var isHovering = false
  @State private var didCopy = false
  @State private var copyFeedbackTask: Task<Void, Never>?
  @State private var previewedAttachment: AIChatAttachment?
  @State private var explicitlyShowsFullBody = false
  @State private var expandedBodyPageIndex = 0
  @State private var expandedBody: AIChatPreparedMessageBody?
  @State private var expandedBodyInput: AIChatExpandedMessageBodyInput?
  @State private var asynchronouslyPreparedPresentation: AIChatCachedMessagePresentation?
  @State private var presentationRevision: AIChatMessagePresentationRevision?

  init(
    message: AIChatMessage,
    runtime: AIChatRuntime = .openClaw,
    destinationTitlesByID: [String: String] = [:],
    compact: Bool = false,
    isQueued: Bool = false,
    isRoomResponse: Bool = false,
    isSearchMatch: Bool = false,
    isSelectedSearchMatch: Bool = false,
    selectedSearchMatchPageIndex: Int = 0,
    canSteerQueuedMessage: Bool = false,
    steerQueuedMessage: @escaping () -> Void = {},
    editQueuedMessage: @escaping () -> Void = {},
    deleteQueuedMessage: @escaping () -> Void = {}
  ) {
    self.message = message
    self.runtime = runtime
    self.destinationTitlesByID = destinationTitlesByID
    self.compact = compact
    self.isQueued = isQueued
    self.isRoomResponse = isRoomResponse
    self.isSearchMatch = isSearchMatch
    self.isSelectedSearchMatch = isSelectedSearchMatch
    self.selectedSearchMatchPageIndex = max(0, selectedSearchMatchPageIndex)
    self.canSteerQueuedMessage = canSteerQueuedMessage
    self.steerQueuedMessage = steerQueuedMessage
    self.editQueuedMessage = editQueuedMessage
    self.deleteQueuedMessage = deleteQueuedMessage
    _expandedBodyPageIndex = State(initialValue: max(0, selectedSearchMatchPageIndex))
  }

  var body: some View {
    let presentationInput = AIChatMessagePresentationInput(message)
    let cachedPresentation = asynchronouslyPreparedPresentation
      ?? AIChatMessagePresentationBuilder.placeholder(presentationInput)
    let presentation = cachedPresentation.context
    let wantsFullBody = explicitlyShowsFullBody
      || (isSelectedSearchMatch && cachedPresentation.body.isTruncated)
    let expectedExpandedInput = AIChatExpandedMessageBodyInput(
      messageID: presentationInput.messageID,
      role: presentationInput.role,
      sourceText: cachedPresentation.body.sourceText,
      pageIndex: expandedBodyPageIndex
    )
    let expandedBodyMatchesCurrentPage = expandedBodyInput?.messageID == expectedExpandedInput.messageID
      && expandedBodyInput?.role == expectedExpandedInput.role
      && expandedBodyInput?.pageIndex == expectedExpandedInput.pageIndex
    let resolvedBody = wantsFullBody
      && expandedBodyMatchesCurrentPage
      ? expandedBody ?? cachedPresentation.body
      : cachedPresentation.body
    let expansionTaskKey = AIChatMessageExpansionTaskKey(
      messageID: message.id,
      role: message.role,
      createdAt: message.createdAt,
      pageIndex: expandedBodyPageIndex,
      wantsFullBody: wantsFullBody,
      presentationRevision: presentationRevision
    )
    HStack(alignment: .top, spacing: 10) {
      if message.role == .user {
        Spacer(minLength: compact ? 24 : 48)
      }

      if message.role != .user && !isRoomResponse {
        WorkspaceIconBadge(systemImage: message.role == .assistant ? "sparkles" : "gearshape", tint: roleTint, fill: background)
          .padding(.top, 1)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Text(roleTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(roleTint)
          if message.role == .system {
            Text("System")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.orange)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
          if isQueued {
            Label("Queued", systemImage: "clock")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          } else if message.role == .user,
                    message.deliveryKind == .steer,
                    message.deliveryStatus == .sending {
            Label("Steering…", systemImage: "arrow.turn.up.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text(AIChatMessageTimestampPresentation.displayText(for: message.createdAt))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .help(AIChatMessageTimestampPresentation.fullText(for: message.createdAt))
            .accessibilityLabel(
              "Sent \(AIChatMessageTimestampPresentation.fullText(for: message.createdAt))"
            )
          copyButton
        }
        if !presentation.contexts.isEmpty {
          AIChatContextPillsView(contexts: presentation.contexts)
        }
        if AIChatProgressPresentation.containsNonWhitespace(resolvedBody.displayedText) {
          AIChatMessageBodyView(
            rawText: resolvedBody.displayedText,
            rendersStructuredOrg2: message.role == .assistant,
            structuredPresentation: resolvedBody.org
          )
        }
        if cachedPresentation.body.isTruncated {
          largeMessageExpansionControl(
            resolvedBody: resolvedBody,
            wantsFullBody: wantsFullBody,
            pageIsPrepared: expandedBodyMatchesCurrentPage && expandedBody != nil
          )
        }
        if !message.attachments.isEmpty {
          AIChatMessageAttachmentsView(
            attachments: message.attachments,
            compact: compact,
            onPreview: { previewedAttachment = $0 }
          )
        }
        if isQueued {
          AIChatQueuedMessageActions(
            compact: compact,
            canSteer: canSteerQueuedMessage,
            steer: steerQueuedMessage,
            edit: editQueuedMessage,
            remove: deleteQueuedMessage
          )
        }
        if message.role == .user, let sendFailure = message.displayedSendFailure {
          AIChatSendFailureView(
            messageID: message.id,
            deliveryStatus: message.deliveryStatus,
            deliveryIsUnconfirmed: message.deliveryIsUnconfirmed,
            failureText: sendFailure,
            compact: compact
          )
        }
        if message.role == .assistant,
           let responseTrace = message.responseTrace,
           !responseTrace.isEmpty {
          Divider()
            .padding(.top, 10)
            .padding(.bottom, 2)
          AIChatProgressFeedView(
            reasoning: responseTrace.reasoning,
            activities: responseTrace.activities,
            compact: compact,
            isLive: false,
            presentedItems: cachedPresentation.activityFeedItems
          )
        }
        if message.role == .assistant, let changeSummary = message.changeSummary {
          Divider()
            .padding(.top, 10)
            .padding(.bottom, 2)
          AIChatChangeSummaryView(summary: changeSummary, compact: compact)
        }
      }
      .padding(.horizontal, 11)
      .padding(.top, 9)
      .padding(.bottom, 12)
      .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(effectiveBorderColor, lineWidth: searchBorderWidth)
      )
      .frame(maxWidth: isRoomResponse ? .infinity : nil, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .onHover { isHovering in
        withAnimation(WorkspaceMotion.quick) {
          self.isHovering = isHovering
        }
      }

      if message.role != .user && !isRoomResponse {
        Spacer(minLength: compact ? 24 : 48)
      } else {
        WorkspaceIconBadge(systemImage: "person.fill", tint: .accentColor, fill: Color.accentColor.opacity(0.12))
          .padding(.top, 1)
      }
    }
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(
      "openclaw-chat-message-\(message.id.uuidString.lowercased())"
    )
    .background {
      AIChatMessageAccessibilityMarker(
        identifier: "openclaw-chat-message-\(message.id.uuidString.lowercased())",
        label: "\(roleTitle) message"
      )
    }
    .sheet(item: $previewedAttachment) { attachment in
      AIChatAttachmentPreviewView(attachment: attachment)
    }
    .background {
      AIChatMessagePresentationResolver(input: presentationInput) { resolved in
        asynchronouslyPreparedPresentation = resolved.value
        presentationRevision = resolved.revision
      }
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
    .task(id: expansionTaskKey) {
      await synchronizeExpandedBody(
        input: presentationInput,
        wantsFullBody: wantsFullBody
      )
    }
    .onChange(of: selectedSearchMatchPageIndex) { _, pageIndex in
      guard isSelectedSearchMatch else { return }
      expandedBodyPageIndex = max(0, pageIndex)
    }
  }

  @ViewBuilder
  private func largeMessageExpansionControl(
    resolvedBody: AIChatPreparedMessageBody,
    wantsFullBody: Bool,
    pageIsPrepared: Bool
  ) -> some View {
    let messageIdentifier = message.id.uuidString.lowercased()
    if wantsFullBody && !pageIsPrepared {
      HStack(spacing: 7) {
        ProgressView()
          .controlSize(.small)
        Text(isSelectedSearchMatch
          ? "Revealing full message for the selected match…"
          : "Preparing full message…")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Preparing full message")
      .accessibilityIdentifier("openclaw-message-preparing-full-\(messageIdentifier)")
    } else if pageIsPrepared && resolvedBody.isTruncated {
      HStack(spacing: 12) {
        if expandedBodyPageIndex > 0 {
          Button("Previous part") {
            expandedBodyPageIndex -= 1
          }
          .accessibilityIdentifier("openclaw-message-previous-part-\(messageIdentifier)")
        }
        Button("Next part") {
          expandedBodyPageIndex += 1
        }
        .accessibilityIdentifier("openclaw-message-next-part-\(messageIdentifier)")
        Button("Show Less") {
          explicitlyShowsFullBody = false
          expandedBodyPageIndex = 0
        }
        .accessibilityIdentifier("openclaw-message-show-less-\(messageIdentifier)")
        .background {
          AIChatMessageAccessibilityPressTarget(
            identifier: "openclaw-message-show-less-\(messageIdentifier)",
            label: "Show collapsed message preview"
          ) {
            explicitlyShowsFullBody = false
            expandedBodyPageIndex = 0
          }
        }
      }
      .buttonStyle(.plain)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
    } else if !resolvedBody.isTruncated && isSelectedSearchMatch {
      Label("Full message shown for selected match", systemImage: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("openclaw-message-full-revealed-\(messageIdentifier)")
        .background {
          AIChatMessageAccessibilityMarker(
            identifier: "openclaw-message-full-revealed-\(messageIdentifier)",
            label: "Full message shown for selected match"
          )
        }
    } else if !resolvedBody.isTruncated {
      Button {
        explicitlyShowsFullBody = false
        expandedBodyPageIndex = 0
      } label: {
        Label("Show Less", systemImage: "chevron.up")
      }
      .buttonStyle(.plain)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .accessibilityLabel("Show collapsed message preview")
      .accessibilityIdentifier("openclaw-message-show-less-\(messageIdentifier)")
      .background {
        AIChatMessageAccessibilityPressTarget(
          identifier: "openclaw-message-show-less-\(messageIdentifier)",
          label: "Show collapsed message preview"
        ) {
          explicitlyShowsFullBody = false
          expandedBodyPageIndex = 0
        }
      }
    } else if !wantsFullBody {
      Button {
        explicitlyShowsFullBody = true
        expandedBodyPageIndex = 0
      } label: {
        Label("Show Full Message", systemImage: "chevron.down")
      }
      .buttonStyle(.plain)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .help("Show all of this large message")
      .accessibilityLabel("Show full message")
      .accessibilityIdentifier("openclaw-message-show-full-\(messageIdentifier)")
      .background {
        AIChatMessageAccessibilityPressTarget(
          identifier: "openclaw-message-show-full-\(messageIdentifier)",
          label: "Show full message"
        ) {
          explicitlyShowsFullBody = true
          expandedBodyPageIndex = 0
        }
      }
    }
  }

  @MainActor
  private func synchronizeExpandedBody(
    input: AIChatMessagePresentationInput,
    wantsFullBody: Bool
  ) async {
    guard wantsFullBody else {
      expandedBody = nil
      expandedBodyInput = nil
      return
    }

    let cachedCandidate = AIChatMessagePresentationCache.cachedPresentation(
      messageID: input.messageID
    )
    let resolved = await AIChatMessagePresentationPreparationCoordinator.shared.resolve(
      input,
      cachedCandidate: cachedCandidate
    )
    guard !Task.isCancelled,
          message.id == input.messageID,
          message.role == input.role
    else { return }
    if let prepared = resolved.preparedForCacheInstall {
      AIChatMessagePresentationCache.install(prepared)
    }
    presentationRevision = resolved.revision
    asynchronouslyPreparedPresentation = resolved.value
    let preparedPresentation = resolved.value
    guard preparedPresentation.body.isTruncated else {
      expandedBody = nil
      expandedBodyInput = nil
      return
    }

    let expandedInput = AIChatExpandedMessageBodyInput(
      messageID: input.messageID,
      role: input.role,
      sourceText: preparedPresentation.body.sourceText,
      pageIndex: expandedBodyPageIndex
    )
    let alreadyPreparedCurrentPage = expandedBodyInput?.messageID == expandedInput.messageID
      && expandedBodyInput?.role == expandedInput.role
      && expandedBodyInput?.pageIndex == expandedInput.pageIndex
      && expandedBody != nil
    guard !alreadyPreparedCurrentPage else { return }
    let prepared = await AIChatExpandedMessageBodyPreparationCoordinator.shared.prepare(
      expandedInput
    )
    guard !Task.isCancelled,
          let prepared,
          message.id == expandedInput.messageID,
          expandedBodyPageIndex == expandedInput.pageIndex,
          presentationRevision == resolved.revision
    else { return }
    expandedBody = prepared
    expandedBodyInput = expandedInput
  }

  private var copyButton: some View {
    Button {
      let input = AIChatMessageClipboard.Input(message)
      copyFeedbackTask?.cancel()
      copyFeedbackTask = Task { @MainActor in
        let copied = await AIChatMessageClipboard.copy(input)
        guard !Task.isCancelled else { return }
        didCopy = copied
        guard copied else { return }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        didCopy = false
      }
    } label: {
      Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
        .font(.caption2.weight(.semibold))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(didCopy ? Color.green : Color.secondary)
    .opacity(isHovering || didCopy ? 1 : 0.48)
    .help(didCopy ? "Copied" : "Copy message")
    .accessibilityLabel(didCopy ? "Message copied" : "Copy message")
    .onDisappear {
      copyFeedbackTask?.cancel()
      copyFeedbackTask = nil
      didCopy = false
    }
  }

  private var roleTitle: String {
    switch message.role {
    case .user:
      if !message.audienceDestinationIDs.isEmpty {
        return "You → " + message.audienceDestinationIDs
          .map(destinationTitle)
          .joined(separator: " + ")
      }
      return message.audience.map { "You → \($0.title)" } ?? "You"
    case .assistant:
      return message.authorLabel
        ?? message.authorDestinationID.map(destinationTitle)
        ?? (message.authorRuntime ?? runtime).title
    case .system:
      return message.authorLabel
        ?? message.authorDestinationID.map(destinationTitle)
        ?? message.authorRuntime?.title
        ?? WorkspaceProductIdentity.displayName
    }
  }

  private func destinationTitle(_ destinationID: String) -> String {
    if let title = destinationTitlesByID[destinationID] { return title }
    if destinationID == AIChatDestinationConfiguration.localCodexID { return "Codex" }
    if destinationID == AIChatDestinationConfiguration.openClawID { return "OpenClaw" }
    return destinationID
  }

  private var background: Color {
    switch message.role {
    case .user:
      return Color.accentColor.opacity(0.11)
    case .assistant:
      return WorkspaceDesign.surfaceBackground
    case .system:
      return Color.orange.opacity(0.10)
    }
  }

  private var borderColor: Color {
    switch message.role {
    case .user:
      return Color.accentColor.opacity(0.16)
    case .assistant:
      return WorkspaceDesign.hairline
    case .system:
      return Color.orange.opacity(0.20)
    }
  }

  private var effectiveBorderColor: Color {
    if isSelectedSearchMatch { return Color.accentColor.opacity(0.82) }
    if isSearchMatch { return Color.accentColor.opacity(0.34) }
    return borderColor
  }

  private var searchBorderWidth: CGFloat {
    isSelectedSearchMatch ? 2 : 1
  }

  private var roleTint: Color {
    switch message.role {
    case .user:
      return .accentColor
    case .assistant:
      return .secondary
    case .system:
      return .orange
    }
  }
}

struct AIChatRoomRound: Identifiable, Equatable, Sendable {
  let id: UUID
  let trigger: AIChatMessage
  let expectedDestinationIDs: [String]
  let dispatchesByDestinationID: [String: AIChatMessage]
  let responsesByDestinationID: [String: AIChatMessage]

  var expectedRuntimes: [AIChatRuntime] {
    expectedDestinationIDs.compactMap { dispatchesByDestinationID[$0]?.targetRuntime }
  }

  var completedCount: Int {
    expectedDestinationIDs.filter(isTerminal).count
  }

  var isComplete: Bool {
    !expectedDestinationIDs.isEmpty && completedCount == expectedDestinationIDs.count
  }

  func dispatch(forDestinationID destinationID: String) -> AIChatMessage? {
    dispatchesByDestinationID[destinationID]
  }

  func response(forDestinationID destinationID: String) -> AIChatMessage? {
    responsesByDestinationID[destinationID]
  }

  func dispatch(for runtime: AIChatRuntime) -> AIChatMessage? {
    expectedDestinationIDs.compactMap { dispatchesByDestinationID[$0] }
      .first(where: { $0.targetRuntime == runtime })
  }

  func response(for runtime: AIChatRuntime) -> AIChatMessage? {
    expectedDestinationIDs.compactMap { responsesByDestinationID[$0] }
      .first(where: { $0.authorRuntime == runtime })
  }

  private func isTerminal(_ destinationID: String) -> Bool {
    if responsesByDestinationID[destinationID] != nil { return true }
    guard let dispatch = dispatchesByDestinationID[destinationID] else { return false }
    return dispatch.deliveryStatus == .failed || dispatch.deliveryStatus == .interrupted
  }
}

enum AIChatRoomTranscriptItem: Identifiable, Equatable, Sendable {
  case message(AIChatMessage)
  case round(AIChatRoomRound)

  var id: UUID {
    switch self {
    case .message(let message): message.id
    case .round(let round): round.id
    }
  }

  var visibleChatBubbleMessages: [AIChatMessage] {
    switch self {
    case .message(let message):
      return [message]
    case .round(let round):
      return [round.trigger] + round.expectedDestinationIDs
        .prefix(AIChatRoomRoundView.maximumVisibleDestinationCount)
        .compactMap {
        round.response(forDestinationID: $0)
      }
    }
  }

  var visibleChatBubbleCount: Int {
    visibleChatBubbleMessages.count
  }

  var displayedContentUTF8ByteCount: Int {
    visibleChatBubbleMessages.reduce(into: 0) { total, message in
      total += AIChatMessageBodyExcerpt.displayedUTF8ByteCount(for: message.content)
    }
  }
}

enum AIChatRoomTranscriptPresentation {
  static func items(
    messages: [AIChatMessage],
    isSharedRoom: Bool
  ) -> [AIChatRoomTranscriptItem] {
    guard isSharedRoom else {
      return messages
        .filter { !$0.isRoomDispatchCopy }
        .map(AIChatRoomTranscriptItem.message)
    }

    var items: [AIChatRoomTranscriptItem] = []
    var consumed = Set<UUID>()
    var messagesByRoundID: [UUID: [AIChatMessage]] = [:]
    messagesByRoundID.reserveCapacity(messages.count / 3)
    for message in messages {
      if let roomRoundID = message.roomRoundID {
        messagesByRoundID[roomRoundID, default: []].append(message)
      }
    }
    var nextVisibleUserIndex = messages.endIndex
    var legacyGroupEndIndexes = Array(repeating: messages.endIndex, count: messages.count)
    for index in messages.indices.reversed() {
      legacyGroupEndIndexes[index] = nextVisibleUserIndex
      if messages[index].role == .user && !messages[index].isRoomDispatchCopy {
        nextVisibleUserIndex = index
      }
    }

    for (index, message) in messages.enumerated() {
      guard !consumed.contains(message.id) else { continue }
      guard !message.isRoomDispatchCopy else {
        consumed.insert(message.id)
        continue
      }
      let expectedDestinationIDs = !message.audienceDestinationIDs.isEmpty
        ? message.audienceDestinationIDs
        : legacyDestinationIDs(for: message.audience)
      guard message.role == .user, !expectedDestinationIDs.isEmpty
      else {
        consumed.insert(message.id)
        items.append(.message(message))
        continue
      }

      let groupedMessages: [AIChatMessage]
      if let roomRoundID = message.roomRoundID {
        groupedMessages = messagesByRoundID[roomRoundID] ?? [message]
      } else {
        // Legacy human rounds end at the next visible human post, but agent
        // hand-offs can finish inside that range. Their replies are separate
        // turns, not response columns belonging to the original audience.
        groupedMessages = messages[index..<legacyGroupEndIndexes[index]].filter {
          $0.roomRoundID == nil && $0.provenance?.isAgentTurnRequest != true
        }
      }
      consumed.formUnion(groupedMessages.map(\.id))

      let dispatches = groupedMessages.filter { $0.role == .user }
      let responses = groupedMessages.filter { $0.role != .user }
      var dispatchesByDestinationID: [String: AIChatMessage] = [:]
      dispatches.forEach { dispatch in
        if let destinationID = dispatch.targetDestinationID
          ?? dispatch.targetRuntime.map(AIChatDestinationConfiguration.defaultID(for:)) {
          dispatchesByDestinationID[destinationID] = dispatch
        }
      }

      var responsesByDestinationID: [String: AIChatMessage] = [:]
      var unattributedResponses: [AIChatMessage] = []
      for response in responses {
        if let destinationID = response.authorDestinationID
          ?? response.authorRuntime.map(AIChatDestinationConfiguration.defaultID(for:)) {
          responsesByDestinationID[destinationID] = response
        } else {
          unattributedResponses.append(response)
        }
      }
      let missingDestinationIDs = expectedDestinationIDs.filter {
        responsesByDestinationID[$0] == nil
      }
      for (destinationID, response) in zip(missingDestinationIDs, unattributedResponses) {
        responsesByDestinationID[destinationID] = response
      }

      items.append(.round(AIChatRoomRound(
        id: message.roomRoundID ?? message.id,
        trigger: message,
        expectedDestinationIDs: expectedDestinationIDs,
        dispatchesByDestinationID: dispatchesByDestinationID,
        responsesByDestinationID: responsesByDestinationID
      )))
    }
    return items
  }

  private static func legacyDestinationIDs(
    for audience: AIChatAudience?
  ) -> [String] {
    guard let audience else { return [] }
    if audience == .everyone {
      return [
        AIChatDestinationConfiguration.localCodexID,
        AIChatDestinationConfiguration.openClawID,
      ]
    }
    return audience.runtimes.map(AIChatDestinationConfiguration.defaultID(for:))
  }
}

struct AIChatThreadSearchMatch: Identifiable, Equatable {
  let messageID: UUID
  let scrollTargetID: UUID
  let rawMessageIndex: Int
  let anchorRawMessageIndex: Int
  let expandedBodyPageIndex: Int

  init(
    messageID: UUID,
    scrollTargetID: UUID,
    rawMessageIndex: Int = 0,
    anchorRawMessageIndex: Int? = nil,
    expandedBodyPageIndex: Int = 0
  ) {
    self.messageID = messageID
    self.scrollTargetID = scrollTargetID
    self.rawMessageIndex = rawMessageIndex
    self.anchorRawMessageIndex = anchorRawMessageIndex ?? rawMessageIndex
    self.expandedBodyPageIndex = max(0, expandedBodyPageIndex)
  }

  var id: UUID { messageID }
}

struct AIChatThreadSearchCandidate: Equatable {
  let messageID: UUID
  let scrollTargetID: UUID
  let searchableText: String
  let rawMessageIndex: Int
  let anchorRawMessageIndex: Int
}

struct AIChatThreadSearchMessageInput: Sendable {
  let messageID: UUID
  let role: AIChatMessage.Role
  let rawText: String
  let attachmentFileNames: [String]
  let isRoomDispatchCopy: Bool
  let roomRoundID: UUID?
  let beginsLegacySharedRound: Bool
  let isAgentTurnRequest: Bool

  nonisolated init(_ message: AIChatMessage) {
    messageID = message.id
    role = message.role
    rawText = message.content
    attachmentFileNames = message.attachments.map(\.fileName)
    isRoomDispatchCopy = message.isRoomDispatchCopy
    roomRoundID = message.roomRoundID
    isAgentTurnRequest = message.provenance?.isAgentTurnRequest == true
    beginsLegacySharedRound = message.role == .user
      && (!message.audienceDestinationIDs.isEmpty || message.audience != nil)
  }
}

enum AIChatThreadSearch {
  nonisolated static func candidates(
    in messages: [AIChatMessage],
    isSharedRoom: Bool
  ) -> [AIChatThreadSearchCandidate] {
    candidates(
      in: messages.map(AIChatThreadSearchMessageInput.init),
      isSharedRoom: isSharedRoom
    )
  }

  static func candidates(
    in items: [AIChatRoomTranscriptItem]
  ) -> [AIChatThreadSearchCandidate] {
    items.enumerated().flatMap { index, item -> [AIChatThreadSearchCandidate] in
      switch item {
      case .message(let message):
        return [candidate(for: message, scrollTargetID: message.id, rawMessageIndex: index)]
      case .round(let round):
        let visibleMessages = [round.trigger] + round.expectedDestinationIDs.compactMap {
          round.response(forDestinationID: $0)
        }
        return visibleMessages.map { message in
          candidate(for: message, scrollTargetID: round.id, rawMessageIndex: index)
        }
      }
    }
  }

  nonisolated static func candidates(
    in messages: [AIChatThreadSearchMessageInput],
    isSharedRoom: Bool
  ) -> [AIChatThreadSearchCandidate] {
    var explicitRoundAnchors: [UUID: Int] = [:]
    if isSharedRoom {
      for (index, message) in messages.enumerated()
      where !message.isRoomDispatchCopy && message.role == .user {
        if let roundID = message.roomRoundID,
           explicitRoundAnchors[roundID] == nil {
          explicitRoundAnchors[roundID] = index
        }
      }
    }

    var result: [AIChatThreadSearchCandidate] = []
    result.reserveCapacity(messages.count)
    var legacyRoundAnchor: (id: UUID, index: Int)?
    for (index, message) in messages.enumerated() {
      guard !Task.isCancelled else { return [] }
      guard !message.isRoomDispatchCopy else { continue }
      let scrollTargetID: UUID
      let anchorIndex: Int
      if !isSharedRoom {
        scrollTargetID = message.messageID
        anchorIndex = index
      } else if let roundID = message.roomRoundID {
        if let roundAnchor = explicitRoundAnchors[roundID] {
          scrollTargetID = roundID
          anchorIndex = roundAnchor
        } else {
          // An agent-requested round has only a hidden dispatch; its visible
          // reply is a standalone row, so there is no round row to scroll to.
          scrollTargetID = message.messageID
          anchorIndex = index
        }
      } else if message.isAgentTurnRequest {
        scrollTargetID = message.messageID
        anchorIndex = index
      } else if message.role == .user {
        if message.beginsLegacySharedRound {
          legacyRoundAnchor = (message.messageID, index)
        } else {
          legacyRoundAnchor = nil
        }
        scrollTargetID = legacyRoundAnchor?.id ?? message.messageID
        anchorIndex = legacyRoundAnchor?.index ?? index
      } else {
        scrollTargetID = legacyRoundAnchor?.id ?? message.messageID
        anchorIndex = legacyRoundAnchor?.index ?? index
      }
      result.append(candidate(
        for: message,
        scrollTargetID: scrollTargetID,
        rawMessageIndex: index,
        anchorRawMessageIndex: anchorIndex
      ))
    }
    return result
  }

  static func matches(
    query rawQuery: String,
    in items: [AIChatRoomTranscriptItem]
  ) -> [AIChatThreadSearchMatch] {
    matches(query: rawQuery, in: candidates(in: items))
  }

  static func matches(
    query rawQuery: String,
    in candidates: [AIChatThreadSearchCandidate]
  ) -> [AIChatThreadSearchMatch] {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }

    var result: [AIChatThreadSearchMatch] = []
    result.reserveCapacity(min(candidates.count, 128))
    for candidate in candidates {
      guard !Task.isCancelled else { return [] }
      guard let matchRange = candidate.searchableText.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive]
      ) else {
        continue
      }
      let matchCharacterOffset = candidate.searchableText.distance(
        from: candidate.searchableText.startIndex,
        to: matchRange.lowerBound
      )
      result.append(AIChatThreadSearchMatch(
        messageID: candidate.messageID,
        scrollTargetID: candidate.scrollTargetID,
        rawMessageIndex: candidate.rawMessageIndex,
        anchorRawMessageIndex: candidate.anchorRawMessageIndex,
        expandedBodyPageIndex: matchCharacterOffset
          / AIChatExpandedMessageBodyInput.pageCharacterLimit
      ))
    }
    return result
  }

  private static func candidate(
    for message: AIChatMessage,
    scrollTargetID: UUID,
    rawMessageIndex: Int
  ) -> AIChatThreadSearchCandidate {
    let searchableText = ([AIChatMessageClipboard.text(for: message)]
      + message.attachments.map(\.fileName))
      .joined(separator: "\n")
    return AIChatThreadSearchCandidate(
      messageID: message.id,
      scrollTargetID: scrollTargetID,
      searchableText: searchableText,
      rawMessageIndex: rawMessageIndex,
      anchorRawMessageIndex: rawMessageIndex
    )
  }

  private nonisolated static func candidate(
    for message: AIChatThreadSearchMessageInput,
    scrollTargetID: UUID,
    rawMessageIndex: Int,
    anchorRawMessageIndex: Int
  ) -> AIChatThreadSearchCandidate {
    let content: String
    if message.role == .user {
      content = AIChatContextPresentation(message.rawText).clipboardText
    } else if message.role == .assistant {
      content = AIChatMessageOrgNormalizer.normalized(message.rawText)
    } else {
      content = message.rawText
    }
    return AIChatThreadSearchCandidate(
      messageID: message.messageID,
      scrollTargetID: scrollTargetID,
      searchableText: ([content] + message.attachmentFileNames).joined(separator: "\n"),
      rawMessageIndex: rawMessageIndex,
      anchorRawMessageIndex: anchorRawMessageIndex
    )
  }
}

struct AIChatThreadFindBar: View {
  @Binding var query: String
  let selectedMatchIndex: Int?
  let matchCount: Int
  let focusRequest: Int
  let compact: Bool
  let onPrevious: () -> Void
  let onNext: () -> Void
  let onClose: () -> Void
  @FocusState private var isSearchFieldFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Find in this thread", text: $query)
        .textFieldStyle(.plain)
        .focused($isSearchFieldFocused)
        .onSubmit {
          onNext()
        }
        .accessibilityLabel("Find in current AI chat thread")
        .accessibilityIdentifier("openclaw-chat-thread-find-field")

      Text(resultSummary)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(minWidth: compact ? 58 : 72, alignment: .trailing)

      Button(action: onPrevious) {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.plain)
      .disabled(matchCount == 0)
      .help("Previous match")
      .accessibilityLabel("Previous match")

      Button(action: onNext) {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.plain)
      .disabled(matchCount == 0)
      .help("Next match")
      .accessibilityLabel("Next match")

      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("Close find")
      .accessibilityLabel("Close find")
    }
    .padding(.horizontal, compact ? 10 : 16)
    .padding(.vertical, 8)
    .background(WorkspaceDesign.barBackground)
    .onAppear(perform: focusSearchField)
    .onChange(of: focusRequest) { _, _ in
      focusSearchField()
    }
    .onExitCommand(perform: onClose)
  }

  private var resultSummary: String {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return "" }
    guard let selectedMatchIndex, matchCount > 0 else { return "No matches" }
    return "\(selectedMatchIndex + 1) of \(matchCount)"
  }

  private func focusSearchField() {
    Task { @MainActor in
      isSearchFieldFocused = true
    }
  }
}

struct AIChatRoomRoundView: View {
  nonisolated static let maximumVisibleDestinationCount = 8

  @Environment(WorkspaceStore.self) private var store
  let round: AIChatRoomRound
  let compact: Bool
  let searchMatchMessageIDs: Set<UUID>
  let selectedSearchMatchMessageID: UUID?
  let selectedSearchMatchPageIndex: Int

  init(
    round: AIChatRoomRound,
    compact: Bool,
    searchMatchMessageIDs: Set<UUID> = [],
    selectedSearchMatchMessageID: UUID? = nil,
    selectedSearchMatchPageIndex: Int = 0
  ) {
    self.round = round
    self.compact = compact
    self.searchMatchMessageIDs = searchMatchMessageIDs
    self.selectedSearchMatchMessageID = selectedSearchMatchMessageID
    self.selectedSearchMatchPageIndex = selectedSearchMatchPageIndex
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ChatBubbleView(
        message: round.trigger,
        runtime: store.selectedAIChatRuntime,
        destinationTitlesByID: store.aiChatDestinationTitlesByID,
        compact: compact,
        isQueued: store.isAIChatMessageQueued(round.trigger.id),
        isSearchMatch: searchMatchMessageIDs.contains(round.trigger.id),
        isSelectedSearchMatch: selectedSearchMatchMessageID == round.trigger.id,
        selectedSearchMatchPageIndex: selectedSearchMatchPageIndex,
        editQueuedMessage: { store.editQueuedAIChatMessage(round.trigger.id) },
        deleteQueuedMessage: { store.deleteQueuedAIChatMessage(round.trigger.id) }
      )

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 7) {
          Label("Agent round", systemImage: "person.2.fill")
            .font(.caption.weight(.semibold))
          Spacer(minLength: 8)
          Text(roundStatus)
            .font(.caption2.weight(.medium))
            .foregroundStyle(round.isComplete ? .secondary : Color.accentColor)
        }

        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 8) {
            ForEach(visibleDestinationIDs, id: \.self) { destinationID in
              agentSlot(destinationID)
                .frame(minWidth: 270, maxWidth: .infinity, alignment: .topLeading)
            }
          }
          VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleDestinationIDs, id: \.self) { destinationID in
              agentSlot(destinationID)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
          }
        }
        if omittedDestinationCount > 0 {
          Text("\(omittedDestinationCount) additional destination\(omittedDestinationCount == 1 ? "" : "s") not mounted")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("openclaw-room-round-omitted-destinations")
            .background {
              AIChatMessageAccessibilityMarker(
                identifier: "openclaw-room-round-omitted-destinations",
                label: "Additional shared-room destinations not mounted"
              )
            }
        }
      }
      .padding(9)
      .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(WorkspaceDesign.hairline)
      )
      .padding(.leading, compact ? 0 : 38)
    }
  }

  private func agentSlot(_ destinationID: String) -> some View {
    AIChatRoomAgentSlot(
      round: round,
      destinationID: destinationID,
      compact: compact,
      searchMatchMessageIDs: searchMatchMessageIDs,
      selectedSearchMatchMessageID: selectedSearchMatchMessageID,
      selectedSearchMatchPageIndex: selectedSearchMatchPageIndex,
      isActive: store.selectedAIChatActiveRoomRoundID == round.id
        && store.selectedAIChatActiveDestinationID == destinationID
    )
  }

  private var visibleDestinationIDs: [String] {
    var visible = Array(round.expectedDestinationIDs.prefix(Self.maximumVisibleDestinationCount))
    if let selectedSearchMatchMessageID,
       let selectedDestinationID = round.expectedDestinationIDs.first(where: {
         round.response(forDestinationID: $0)?.id == selectedSearchMatchMessageID
       }),
       !visible.contains(selectedDestinationID) {
      visible.append(selectedDestinationID)
    }
    return visible
  }

  private var omittedDestinationCount: Int {
    max(0, round.expectedDestinationIDs.count - visibleDestinationIDs.count)
  }

  private var roundStatus: String {
    if round.isComplete { return "Complete" }
    return "\(round.completedCount) of \(round.expectedDestinationIDs.count) complete"
  }
}

private struct AIChatRoomAgentSlot: View {
  @Environment(WorkspaceStore.self) private var store
  let round: AIChatRoomRound
  let destinationID: String
  let compact: Bool
  let searchMatchMessageIDs: Set<UUID>
  let selectedSearchMatchMessageID: UUID?
  let selectedSearchMatchPageIndex: Int
  let isActive: Bool

  private var runtime: AIChatRuntime { store.aiChatDestinationRuntime(destinationID) }
  private var destinationTitle: String { store.aiChatDestinationTitle(destinationID) }
  private var destinationSystemImage: String {
    store.aiChatDestination(id: destinationID)?.systemImage ?? runtime.systemImage
  }

  var body: some View {
    Group {
      if let response = round.response(forDestinationID: destinationID) {
        ChatBubbleView(
          message: response,
          runtime: runtime,
          destinationTitlesByID: store.aiChatDestinationTitlesByID,
          compact: true,
          isRoomResponse: true,
          isSearchMatch: searchMatchMessageIDs.contains(response.id),
          isSelectedSearchMatch: selectedSearchMatchMessageID == response.id,
          selectedSearchMatchPageIndex: selectedSearchMatchPageIndex
        )
      } else if isActive {
        VStack(alignment: .leading, spacing: 6) {
          Label(destinationTitle, systemImage: destinationSystemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          AIChatLiveTypingIndicatorView(
            liveState: store.aiChatLiveState,
            threadID: store.selectedAIChatThreadID,
            startedAt: store.aiChatRequestStartedAt,
            runtime: runtime,
            destinationTitle: destinationTitle,
            compact: true,
            onStop: { Task { await store.stopAIChatRun() } }
          )
        }
        .padding(9)
        .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      } else {
        HStack(spacing: 8) {
          if showsProgress {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: statusImage)
              .foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(destinationTitle)
              .font(.caption.weight(.semibold))
            Text(statusText)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(9)
        .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(WorkspaceDesign.hairline)
        )
      }
    }
  }

  private var deliveryStatus: AIChatMessage.DeliveryStatus? {
    round.dispatch(forDestinationID: destinationID)?.deliveryStatus
  }

  private var deliveryIsUnconfirmed: Bool {
    round.dispatch(forDestinationID: destinationID)?.deliveryOutcomeIsUnknown == true
  }

  private var showsProgress: Bool {
    deliveryStatus == .sending && !deliveryIsUnconfirmed
  }

  private var statusImage: String {
    if deliveryIsUnconfirmed { return "questionmark.circle" }
    return switch deliveryStatus {
    case .failed: "exclamationmark.triangle.fill"
    case .interrupted: "stop.circle"
    case .sent: "ellipsis"
    case .sending, nil: "clock"
    }
  }

  private var statusText: String {
    if deliveryIsUnconfirmed { return "Delivery confirmation pending" }
    return switch deliveryStatus {
    case .failed: "Could not respond"
    case .interrupted: "Stopped"
    case .sent: "Finishing response…"
    case .sending, nil: "Waiting to respond"
    }
  }
}

private struct AIChatQueuedMessageActions: View {
  let compact: Bool
  let canSteer: Bool
  let steer: () -> Void
  let edit: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Text("Waiting behind the current turn")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      if canSteer {
        Button {
          steer()
        } label: {
          if compact {
            Image(systemName: "arrow.turn.up.right")
          } else {
            Label("Steer Now", systemImage: "arrow.turn.up.right")
          }
        }
        .buttonStyle(WorkspaceActionButtonStyle())
        .help("Send this queued message to the current turn now")
      }

      Button {
        edit()
      } label: {
        if compact {
          Image(systemName: "pencil")
        } else {
          Label("Edit", systemImage: "pencil")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .help("Remove this message from the queue and put it back in the composer")

      Button {
        remove()
      } label: {
        if compact {
          Image(systemName: "xmark")
        } else {
          Label("Remove", systemImage: "xmark")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .help("Remove this message before it is sent")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(WorkspaceDesign.hairline)
    )
  }
}

enum AIChatMessageClipboard {
  struct Input: Sendable {
    let role: AIChatMessage.Role
    let content: String
    let attachmentFileNames: [String]

    nonisolated init(_ message: AIChatMessage) {
      role = message.role
      content = message.content
      attachmentFileNames = message.attachments.map(\.fileName)
    }
  }

  nonisolated static func text(for message: AIChatMessage) -> String {
    text(for: Input(message))
  }

  nonisolated static func text(for input: Input) -> String {
    if !input.content.isEmpty {
      let content = AIChatContextPresentation(
        input.content,
        extractsContexts: input.role == .user
      ).clipboardText
      return AIChatRichClipboard.alignedMessage(input.role == .assistant
        ? AIChatMessageOrgNormalizer.normalized(content)
        : content)
    }
    return input.attachmentFileNames.map { "[Attachment: \($0)]" }.joined(separator: "\n")
  }

  @MainActor
  @discardableResult
  static func copy(
    _ input: Input,
    to pasteboard: NSPasteboard = .general
  ) async -> Bool {
    let preparedText = await Task.detached(priority: .userInitiated) {
      text(for: input)
    }.value
    guard !Task.isCancelled else { return false }
    return write(preparedText, html: AIChatRichClipboard.messageHTML(preparedText), to: pasteboard)
  }

  @MainActor
  @discardableResult
  static func copy(
    _ message: AIChatMessage,
    to pasteboard: NSPasteboard = .general
  ) -> Bool {
    let text = text(for: message)
    return write(text, html: AIChatRichClipboard.messageHTML(text), to: pasteboard)
  }

  nonisolated static func codeSnippetText(lines: [String]) -> String {
    lines.joined(separator: "\n")
  }

  @MainActor
  @discardableResult
  static func copyCodeSnippet(
    lines: [String],
    to pasteboard: NSPasteboard = .general
  ) -> Bool {
    write(codeSnippetText(lines: lines), to: pasteboard)
  }

  @MainActor
  @discardableResult
  static func write(_ text: String, html: String? = nil, to pasteboard: NSPasteboard = .general) -> Bool {
    let item = NSPasteboardItem()
    guard item.setString(text, forType: .string) else { return false }
    if let html { item.setString(html, forType: .html) }
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }
}

private struct AIChatContextPillsView: View {
  @Environment(WorkspaceStore.self) private var store
  let contexts: [AIChatPresentedContext]
  var remove: ((AIChatPresentedContext) -> Void)?

  init(
    contexts: [AIChatPresentedContext],
    remove: ((AIChatPresentedContext) -> Void)? = nil
  ) {
    self.contexts = contexts
    self.remove = remove
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(contexts) { context in
          AIChatContextPill(
            context: store.resolvedAIChatContext(context),
            remove: remove
          )
        }
      }
      .padding(.vertical, 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct AIChatContextPill: View {
  @Environment(WorkspaceStore.self) private var store
  let context: AIChatPresentedContext
  let remove: ((AIChatPresentedContext) -> Void)?
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 3) {
      Button {
        store.openAIChatContext(context)
      } label: {
        HStack(spacing: 5) {
          Image(systemName: context.systemImage)
            .font(.caption2.weight(.semibold))
            .accessibilityHidden(true)
          Text(context.title)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: isHovering ? 320 : 152, alignment: .leading)
          if remove == nil, isHovering {
            Image(systemName: "arrow.up.right")
              .font(.system(size: 8, weight: .bold))
              .foregroundStyle(.secondary)
              .transition(.opacity.combined(with: .scale(scale: 0.82)))
          }
        }
        .padding(.leading, 8)
        .padding(.trailing, remove == nil || !isHovering ? 8 : 2)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open \(context.title)")
      .accessibilityLabel("Open context: \(context.title)")

      if let remove, isHovering {
        Button {
          remove(context)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .frame(width: 16, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.trailing, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.82)))
        .help("Remove \(context.title) from context")
        .accessibilityLabel("Remove \(context.title) from context")
      }
    }
    .foregroundStyle(Color.accentColor)
    .background(Color.accentColor.opacity(0.09), in: Capsule())
    .overlay(Capsule().stroke(Color.accentColor.opacity(0.18)))
    .contentShape(Capsule())
    .onHover { hovering in
      withAnimation(WorkspaceMotion.quick) {
        isHovering = hovering
      }
    }
    .animation(WorkspaceMotion.quick, value: isHovering)
  }
}

private struct AIChatSendFailureView: View {
  @Environment(WorkspaceStore.self) private var store
  let messageID: UUID
  let deliveryStatus: AIChatMessage.DeliveryStatus
  let deliveryIsUnconfirmed: Bool
  let failureText: String
  let compact: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.red)
        Text(failureText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(compact ? 4 : 5)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      Button {
        Task { await store.retryAIChatMessage(messageID) }
      } label: {
        if compact {
          Image(systemName: "arrow.clockwise")
        } else {
          Label(retryButtonTitle, systemImage: "arrow.clockwise")
        }
      }
      .buttonStyle(WorkspaceActionButtonStyle())
      .disabled(store.isSendingAIChatMessage)
      .help(retryHelpText)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.red.opacity(0.22))
    )
  }

  private var title: String {
    if isProviderAuthenticationFailure {
      return "Model provider authentication failed"
    }
    if deliveryIsUnconfirmed {
      return "Delivery status unknown"
    }
    switch deliveryStatus {
    case .interrupted:
      return "Response interrupted"
    case .sending, .sent, .failed:
      return "Message failed to send"
    }
  }

  private var isProviderAuthenticationFailure: Bool {
    failureText.localizedCaseInsensitiveContains("model provider rejected authentication")
  }

  private var retryButtonTitle: String {
    if deliveryIsUnconfirmed { return "Recheck" }
    return isProviderAuthenticationFailure ? "Retry After Fix" : "Retry"
  }

  private var retryHelpText: String {
    if deliveryIsUnconfirmed {
      return "Recheck this held attempt without starting another Codex turn"
    }
    return isProviderAuthenticationFailure
      ? "Fix the model provider on the OpenClaw gateway host, then retry this message"
      : "Retry sending this message"
  }
}

private struct AIChatMessageAttachmentsView: View {
  let attachments: [AIChatAttachment]
  let compact: Bool
  let onPreview: (AIChatAttachment) -> Void

  private var imageSize: CGFloat {
    compact ? 76 : 104
  }

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: imageSize, maximum: imageSize), spacing: 8)],
      alignment: .leading,
      spacing: 8
    ) {
      ForEach(attachments) { attachment in
        AIChatAttachmentThumbnail(
          attachment: attachment,
          size: imageSize,
          onPreview: { onPreview(attachment) }
        )
      }
    }
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
    .padding(.top, 2)
  }
}

private struct AIChatAttachmentThumbnail: View {
  let attachment: AIChatAttachment
  let size: CGFloat
  let onPreview: () -> Void

  var body: some View {
    Button(action: onPreview) {
      VStack(alignment: .leading, spacing: 4) {
        AIChatAsyncAttachmentImage(attachment: attachment) { error in
          Group {
            if error != nil {
              Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            Image(systemName: AIChatAttachmentPresentation.systemImage(for: attachment.mimeType))
              .font(.title3)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(WorkspaceDesign.hairline)
        )

        Text(attachment.fileName)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(width: size, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .help("Open \(attachment.fileName) · \(Self.byteCountText(attachment.byteCount))")
    .accessibilityLabel("Open attachment \(attachment.fileName)")
  }

  private static func byteCountText(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }
}

private struct AIChatChangeSummaryView: View {
  let summary: AIChatCorpusChangeSummary
  let compact: Bool

  private var visibleLimit: Int {
    compact ? 4 : 6
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Label(summary.title, systemImage: "doc.text.magnifyingglass")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
        Spacer(minLength: 8)
        AIChatChangeDeltaView(insertions: summary.totalInsertions, deletions: summary.totalDeletions)
      }

      ForEach(summary.files.prefix(visibleLimit)) { change in
        HStack(spacing: 7) {
          Image(systemName: iconName(for: change.status))
            .font(.caption)
            .foregroundStyle(iconColor(for: change.status))
            .frame(width: 14)
          Text(change.relativePath)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 8)
          AIChatChangeDeltaView(insertions: change.insertions, deletions: change.deletions)
        }
      }

      if summary.files.count > visibleLimit {
        Text("+\(summary.files.count - visibleLimit) more file\(summary.files.count - visibleLimit == 1 ? "" : "s")")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
  }

  private func iconName(for status: AIChatCorpusFileChange.Status) -> String {
    switch status {
    case .created:
      return "plus.circle"
    case .modified:
      return "pencil"
    case .deleted:
      return "minus.circle"
    }
  }

  private func iconColor(for status: AIChatCorpusFileChange.Status) -> Color {
    switch status {
    case .created:
      return .green
    case .modified:
      return .secondary
    case .deleted:
      return .red
    }
  }
}

private struct AIChatChangeDeltaView: View {
  let insertions: Int
  let deletions: Int

  var body: some View {
    HStack(spacing: 4) {
      if insertions > 0 {
        Text("+\(insertions)")
          .foregroundStyle(.green)
      }
      if deletions > 0 {
        Text("-\(deletions)")
          .foregroundStyle(.red)
      }
      if insertions == 0 && deletions == 0 {
        Text("0")
          .foregroundStyle(.secondary)
      }
    }
    .font(.caption.monospacedDigit().weight(.medium))
    .lineLimit(1)
  }
}

struct AIChatComposerView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var showsModelConfiguration = false
  @State private var localDraft = ""
  @State private var lastStoreDraft = ""
  @State private var selectedSlashSuggestionIndex = 0
  @State private var selectedMentionSuggestionIndex = 0
  @State private var moveComposerCursorToEndRequest = 0
  @State private var corpusSkillDiscoveryTask: Task<Void, Never>?
  let focusOnAppear: Bool
  let compact: Bool

  var body: some View {
    let presentation = AIChatContextPresentation(localDraft)
    VStack(alignment: .trailing, spacing: AIChatComposerLayout.externalSpacing) {
      let composerHeight = AIChatComposerSizing.height(for: presentation.userText, compact: compact)
      VStack(alignment: .leading, spacing: 0) {
        if !presentation.contexts.isEmpty {
          AIChatContextPillsView(contexts: presentation.contexts) { context in
            localDraft = presentation.removing(context)
          }
          .padding(.horizontal, AIChatComposerLayout.contentInset)
          .padding(.top, AIChatComposerLayout.contentInset)
          .padding(.bottom, 4)
        }

        ZStack(alignment: .topLeading) {
          if presentation.userText.isEmpty {
            Text(
              store.selectedAIChatIsSharedRoom
                ? (store.selectedAIChatRoomDefaultDestinationID.map {
                    "Message \(store.aiChatDestinationTitle($0)), or @mention another agent or file…"
                  } ?? "Add context, or @mention an agent or file…")
                : "Message \(store.selectedAIChatDestination.title), or @mention a file…"
            )
              .font(.body)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, AIChatComposerLayout.contentInset + 1)
              .padding(.vertical, 10)
          }

          AIChatComposerTextView(
            text: visibleDraftBinding,
            recognizedMentions: AIChatDestinationRouting.recognizedMentionTokens(
              destinations: store.aiChatDestinations
            ),
            focusOnAppear: focusOnAppear,
            moveCursorToEndRequest: moveComposerCursorToEndRequest,
            onReturn: handleReturn,
            onSuggestionCommand: handleSuggestionCommand,
            onDropAttachment: handleDropAttachment,
            onPasteLargeText: { text in
              store.attachAIChatAttachment(
                data: Data(text.utf8), fileName: "Pasted Text.txt", mimeType: "text/plain"
              )
            }
          )
          .padding(4)
        }
        .frame(minHeight: composerHeight, idealHeight: composerHeight, maxHeight: composerHeight)

        if !store.aiChatPendingAttachments.isEmpty {
          AIChatPendingAttachmentsView(compact: compact)
            .padding(.horizontal, AIChatComposerLayout.contentInset)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }

        footer
          .padding(.horizontal, AIChatComposerLayout.toolbarHorizontalInset)
          .padding(.top, 4)
          .padding(.bottom, AIChatComposerLayout.toolbarBottomInset)
      }
      .background(
        WorkspaceDesign.surfaceBackground,
        in: RoundedRectangle(cornerRadius: AIChatComposerLayout.cornerRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: AIChatComposerLayout.cornerRadius, style: .continuous)
          .stroke(canSend ? Color.accentColor.opacity(0.26) : WorkspaceDesign.hairline)
      )
      .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
      .animation(.easeOut(duration: 0.12), value: composerHeight)

      let slashSuggestions = AIChatSlashCommands.suggestions(
        for: presentation.userText,
        gatewayCommands: store.activeAIChatGatewayCommands,
        corpusSkills: store.corpusAgentSkillCommands
      )
      let mentionSuggestions = mentionSuggestions(for: presentation.userText)
      if !mentionSuggestions.isEmpty {
        AIChatMentionSuggestionsView(
          suggestions: mentionSuggestions,
          selectedSuggestionID: selectedMentionSuggestion(in: mentionSuggestions)?.id,
          select: completeMention
        )
      } else if !slashSuggestions.isEmpty {
        AIChatSlashCommandSuggestions(
          commands: slashSuggestions,
          selectedCommandID: selectedSlashSuggestion(in: slashSuggestions)?.id,
          select: completeSlashCommand
        )
      }

      if store.selectedAIChatIsSharedRoom {
        let summary = roomRoutingSummary(for: presentation.userText)
        Label(
          summary.title,
          systemImage: summary.invokesAgent ? "person.2.fill" : "text.bubble"
        )
          .font(.caption.weight(.medium))
          .foregroundStyle(summary.invokesAgent ? Color.accentColor : .secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 2)
      } else {
        let routing = destinationRouting(for: presentation.userText)
        if routing.destinationIDs.contains(where: { $0 != store.selectedAIChatDestination.id }) {
          Label(
            "Forks into a shared room · \(routing.summary)",
            systemImage: "arrow.triangle.branch"
          )
          .font(.caption.weight(.medium))
          .foregroundStyle(Color.accentColor)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 2)
        }
      }
    }
    .onAppear {
      localDraft = store.aiChatDraft
      lastStoreDraft = store.aiChatDraft
      cacheDraftLocally()
    }
    .onDisappear {
      corpusSkillDiscoveryTask?.cancel()
      flushDraftToStore()
    }
    .onChange(of: localDraft) {
      selectedSlashSuggestionIndex = 0
      selectedMentionSuggestionIndex = 0
      cacheDraftLocally()
      if AIChatContextPresentation(localDraft).userText == "/" {
        refreshCorpusAgentSkills()
        if store.selectedAIChatDestination.adapter == .openClaw {
          Task { await store.refreshAIChatCommands() }
        }
      }
    }
    .onChange(of: store.aiChatComposerFocusRequest) {
      moveComposerCursorToEndRequest &+= 1
    }
    .onChange(of: store.aiChatDraft) { _, newValue in
      let mergedDraft = AIChatComposerDraftSync.localDraftAfterStoreChange(
        localDraft: localDraft,
        previousStoreDraft: lastStoreDraft,
        nextStoreDraft: newValue
      )
      lastStoreDraft = newValue
      guard mergedDraft != localDraft else { return }
      localDraft = mergedDraft
    }
    .task(id: store.aiChatSelectionGeneration) {
      await store.refreshAIChatConfiguration()
    }
  }

  private var footer: some View {
    ViewThatFits(in: .horizontal) {
      composerToolbar(showsDetailedConfiguration: true)
      composerToolbar(showsDetailedConfiguration: false)
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 5) {
          attachmentButton
          compactConfigurationControls
          Spacer(minLength: 0)
        }
        HStack(spacing: 5) {
          composerStatus(compact: true)
          Spacer(minLength: 0)
          dictationButton(showsTitle: false)
          primaryActionButton
          deliveryOptionsMenu
        }
      }
    }
  }

  private func refreshCorpusAgentSkills() {
    corpusSkillDiscoveryTask?.cancel()
    guard let requestedRoot = store.corpusRoot?.standardizedFileURL else { return }
    corpusSkillDiscoveryTask = Task { @MainActor in
      _ = await CorpusAgentSkillCatalog.prepareCommands(
        in: requestedRoot,
        force: true
      )
      guard !Task.isCancelled,
            store.corpusRoot?.standardizedFileURL == requestedRoot
      else {
        return
      }
      // This call now only installs the already prepared cache entry. Directory
      // enumeration and SKILL.md reads happened on the detached loader above.
      store.refreshCorpusAgentSkills()
      corpusSkillDiscoveryTask = nil
    }
  }

  private func composerToolbar(showsDetailedConfiguration: Bool) -> some View {
    HStack(spacing: showsDetailedConfiguration ? 8 : 5) {
      attachmentButton
      if showsDetailedConfiguration {
        if store.selectedAIChatIsSharedRoom {
          roomDefaultDestinationPicker()
        } else {
          assistantPicker()
        }
      } else if !store.selectedAIChatIsSharedRoom {
        assistantPicker(iconOnly: true)
      }
      if store.showsNewThreadProjectPicker {
        newThreadProjectPicker(iconOnly: !showsDetailedConfiguration)
      }
      composerStatus(compact: !showsDetailedConfiguration)
      Spacer(minLength: 0)
      if showsDetailedConfiguration {
        if store.selectedAIChatIsSharedRoom {
          detailedConfigurationControls
        } else {
          modelConfigurationPicker
        }
      } else {
        if store.selectedAIChatIsSharedRoom {
          compactConfigurationControls
        } else {
          modelConfigurationPicker
        }
      }
      dictationButton(showsTitle: showsDetailedConfiguration)
      primaryActionButton
      deliveryOptionsMenu
    }
  }

  @ViewBuilder
  private var compactConfigurationControls: some View {
    if store.selectedAIChatIsSharedRoom {
      HStack(spacing: 2) {
        roomDefaultDestinationPicker(iconOnly: true)
        Menu {
          ForEach(store.selectedAIChatRoomDestinationIDs, id: \.self) { destinationID in
            roomModelPicker(forDestinationID: destinationID)
          }
        } label: {
          Label("Models", systemImage: "cpu")
            .font(.caption.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Shared room models")
      }
    } else {
      HStack(spacing: 2) {
        assistantPicker(iconOnly: true)
        modelConfigurationPicker
      }
    }
  }

  @ViewBuilder
  private func composerStatus(compact compactStatus: Bool) -> some View {
    if store.isSendingAIChatMessage && !compactStatus {
      Text(store.aiChatQueuedMessageCount > 1 ? "\(store.aiChatQueuedMessageCount - 1) queued" : "Sending")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }
    if store.isRecordingAIChatVoiceNote {
      HStack(spacing: 6) {
        Image(systemName: "waveform")
          .foregroundStyle(.red)
        AIChatVoiceInputMeterView(meterState: store.aiChatVoiceMeterState)
          .frame(width: compactStatus ? 42 : (compact ? 72 : 110), height: 7)
      }
      .help("Recording \(store.selectedAIChatDisplayTitle) dictation")
    } else if store.isTranscribingAIChatVoiceNote {
      if compactStatus {
        ProgressView(value: store.aiChatVoiceTranscriptionProgress)
          .progressViewStyle(.circular)
          .controlSize(.small)
          .help("Transcribing \(store.aiChatVoiceTranscriptionElapsedText)")
      } else {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 5) {
            Text("Transcribing")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
            if !store.aiChatVoiceTranscriptionElapsedText.isEmpty {
              Text(store.aiChatVoiceTranscriptionElapsedText)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.tertiary)
            }
          }
          ProgressView(value: store.aiChatVoiceTranscriptionProgress)
            .progressViewStyle(.linear)
            .frame(width: compact ? 92 : 140)
        }
        .help("Estimated local dictation transcription progress")
      }
    }
  }

  @ViewBuilder
  private var detailedConfigurationControls: some View {
    if store.selectedAIChatIsSharedRoom {
      ForEach(store.selectedAIChatRoomDestinationIDs, id: \.self) { destinationID in
        roomModelPicker(forDestinationID: destinationID)
      }
    }
  }

  @ViewBuilder
  private var attachmentButton: some View {
    Button {
      store.chooseAIChatAttachments()
    } label: {
      Label("Add attachment", systemImage: "plus")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(WorkspaceActionButtonStyle())
    .help("Attach file or image")
    .accessibilityIdentifier("ai-chat-attach-button")
  }

  @ViewBuilder
  private func dictationButton(showsTitle: Bool) -> some View {
    Button {
      flushDraftToStore()
      if store.isRecordingAIChatVoiceNote {
        Task {
          await store.stopAIChatVoiceNoteRecording(action: .insertIntoComposer)
        }
      } else {
        Task { await store.startAIChatVoiceNoteRecording() }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: store.isRecordingAIChatVoiceNote ? "stop.fill" : "mic.fill")
        if showsTitle {
          Text(store.isRecordingAIChatVoiceNote ? "Stop Dictation" : "Dictate")
        }
      }
    }
    .buttonStyle(WorkspaceActionButtonStyle())
    .disabled(!store.isRecordingAIChatVoiceNote && !store.canStartAIChatVoiceNoteRecording)
    .help(
      store.isRecordingAIChatVoiceNote
        ? "Stop dictating and place the transcript in the composer without sending"
        : "Start local voice dictation"
    )
    .accessibilityLabel(store.isRecordingAIChatVoiceNote ? "Stop Dictation" : "Dictate")
    .accessibilityIdentifier("ai-chat-dictation-button")
  }

  private var primaryActionButton: some View {
    Button {
      performPrimaryAction(delivery: .automatic)
    } label: {
      Image(systemName: primaryActionSystemImage)
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(primaryActionIsEnabled ? Color.white : WorkspaceDesign.tertiaryText)
        .frame(
          width: AIChatComposerLayout.primaryActionDiameter,
          height: AIChatComposerLayout.primaryActionDiameter
        )
        .background(
          primaryActionIsEnabled ? Color.accentColor : WorkspaceDesign.controlFill,
          in: Circle()
        )
        .contentShape(Circle())
    }
    .buttonStyle(WorkspaceQuietPressStyle())
    .disabled(!primaryActionIsEnabled)
    .accessibilityLabel(primaryActionTitle)
    .accessibilityIdentifier("ai-chat-primary-action-button")
    .help(primaryActionHelp)
  }

  @ViewBuilder
  private var deliveryOptionsMenu: some View {
    if isRunning
      && !store.isRecordingAIChatVoiceNote
    {
      Menu {
        Button {
          performPrimaryAction(delivery: .followUp)
        } label: {
          Label("Queue as Follow-up", systemImage: "clock")
        }
        .disabled(!canSend)
      } label: {
        Label("More delivery options", systemImage: "chevron.down")
      }
      .labelStyle(.iconOnly)
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Queue behind the current turn instead of steering it (⌘Return)")
    }
  }

  private var primaryActionIsEnabled: Bool {
    store.isRecordingAIChatVoiceNote || canSend
  }

  private func assistantPicker(iconOnly: Bool = false) -> some View {
    let agentName = store.selectedChatAgent?.name
      ?? (store.selectedChatAgentRef == nil ? "Default assistant" : "Unavailable agent")
    let canChangeAssistant = store.canChangeChatAgent || store.canChangeSelectedAIChatRuntime
    return Menu {
      Section("Agent") {
        Button {
          store.setSelectedChatAgent(nil)
        } label: {
          Label("Default assistant", systemImage: store.selectedChatAgentRef == nil ? "checkmark" : "person")
        }
        .disabled(!store.canChangeChatAgent)
        ForEach(store.agentProfiles) { profile in
          Button {
            store.setSelectedChatAgent(profile)
          } label: {
            let defaultSuffix = profile.preferredChatRuntime.map { " · defaults to \($0.title)" } ?? ""
            Label(
              "\(profile.name)\(defaultSuffix)",
              systemImage: profile.id == store.selectedChatAgentRef ? "checkmark" : "person.crop.circle"
            )
          }
          .disabled(!store.canChangeChatAgent)
        }
        if store.agentProfiles.isEmpty { Text("No agent profiles in this corpus") }
      }

      Section("Runtime") {
        ForEach(store.enabledAIChatDestinations) { destination in
          Button {
            store.setSelectedAIChatDestination(destination.id)
          } label: {
            HStack {
              Label(destination.title, systemImage: destination.systemImage)
              if destination.id == store.selectedAIChatDestination.id {
                Image(systemName: "checkmark")
              }
            }
          }
          .disabled(!store.canChangeSelectedAIChatRuntime)
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "person.crop.circle")
        if !iconOnly {
          Text("\(agentName) · \(store.selectedAIChatDestination.title)")
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 220, alignment: .leading)
        }
        Image(systemName: canChangeAssistant ? "chevron.up.chevron.down" : "lock.fill")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityIdentifier("ai-chat-assistant-picker")
    .accessibilityLabel("Assistant: \(agentName), runtime: \(store.selectedAIChatDestination.title)")
    .disabled(!canChangeAssistant)
    .task { await store.refreshAgentProfiles() }
    .help("Choose the agent identity, instructions, and runtime")
  }

  /// Adds a brand-new chat to projects before its first message, so the
  /// first turn already receives the project brief.
  private func newThreadProjectPicker(iconOnly: Bool) -> some View {
    let threadID = store.selectedAIChatThreadID
    let title = AIChatNewThreadProjectPicker.title(projects: store.projectNotes, threadID: threadID)
    return Menu {
      Section("Project") {
        ForEach(store.projectNotes) { project in
          Button {
            guard let threadID else { return }
            Task { await store.updateProject(project, threadID: threadID) }
          } label: {
            let isMember = threadID.map(project.contains) ?? false
            Label(project.title, systemImage: isMember ? "checkmark" : "folder")
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "folder")
        if !iconOnly {
          Text(title)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 160, alignment: .leading)
        }
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityIdentifier("ai-chat-new-thread-project-picker")
    .accessibilityLabel("Project: \(title)")
    .help("Add this new chat to a project before the first message")
  }

  /// Picks the agent that receives un-mentioned messages in a shared room.
  private func roomDefaultDestinationPicker(iconOnly: Bool = false) -> some View {
    let defaultID = store.selectedAIChatRoomDefaultDestinationID
    let defaultDestination = defaultID.flatMap { store.aiChatDestination(id: $0) }
    let title = defaultDestination.map { "Default: \($0.title)" } ?? "Default: Context only"
    return Menu {
      Section("Messages without an @mention go to") {
        ForEach(store.enabledAIChatDestinations) { destination in
          Button {
            store.setSelectedAIChatRoomDefaultDestination(destination.id)
          } label: {
            Label(
              destination.title,
              systemImage: destination.id == defaultID ? "checkmark" : destination.systemImage
            )
          }
        }
        Button {
          store.setSelectedAIChatRoomDefaultDestination(nil)
        } label: {
          Label("No agent (post context only)", systemImage: defaultID == nil ? "checkmark" : "text.bubble")
        }
      }
      let appDefault = store.aiChatDefaultRoomAgentTurnLimit
      let turnLimit = store.selectedAIChatRoomAgentTurnLimit ?? appDefault
      let selection: Int? = store.selectedAIChatRoomUsesDefaultAgentTurnLimit ? nil : turnLimit
      Section("Agents can @mention each other") {
        Picker("Agent turns in a row", selection: Binding(
          get: { selection },
          set: { store.setSelectedAIChatRoomAgentTurnLimit($0) }
        )) {
          Text("Default (\(AIChatThread.roomAgentTurnLimitTitle(appDefault)))").tag(Int?.none)
          ForEach(AIChatThread.roomAgentTurnLimitOptions(including: turnLimit), id: \.self) { limit in
            Text(AIChatThread.roomAgentTurnLimitTitle(limit)).tag(Int?.some(limit))
          }
        }
        .accessibilityIdentifier("ai-chat-room-agent-turn-limit")
        .help("How many turns agents can start for each other by @mentioning, before you need to reply.")
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: defaultDestination?.systemImage ?? "text.bubble")
        if !iconOnly {
          Text(title)
            .lineLimit(1)
            .frame(maxWidth: compact ? 125 : 165)
        }
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityIdentifier("ai-chat-room-default-picker")
    .accessibilityLabel(title)
    .help("Choose which agent gets messages that do not @mention anyone. An @mention only routes that one message.")
  }

  private func roomModelPickerTitle(
    forDestinationID destinationID: String,
    destination: AIChatDestinationConfiguration?
  ) -> String {
    var title = "\(destination?.title ?? destinationID) · \(store.selectedAIChatRoomModelLabel(forDestinationID: destinationID))"
    if let reasoning = store.selectedAIChatRoomReasoningLabel(forDestinationID: destinationID) {
      title += " · \(reasoning)"
    }
    return title
  }

  private func roomModelPicker(forDestinationID destinationID: String) -> some View {
    let options = store.aiChatDestinationModelOptions[destinationID] ?? []
    let destination = store.aiChatDestination(id: destinationID)
    let runtime = store.aiChatDestinationRuntime(destinationID)
    return Menu {
      Button {
        store.setSelectedAIChatRoomModel(nil, forDestinationID: destinationID)
      } label: {
        HStack {
          Text("Default model")
          if store.selectedAIChatRoomModel(forDestinationID: destinationID) == nil {
            Image(systemName: "checkmark")
          }
        }
      }

      if !options.isEmpty {
        Divider()
        ForEach(options) { model in
          Button {
            store.setSelectedAIChatRoomModel(model.id, forDestinationID: destinationID)
          } label: {
            HStack {
              Text(model.label)
              if store.selectedAIChatRoomModel(forDestinationID: destinationID) == model.id {
                Image(systemName: "checkmark")
              }
            }
          }
          .help(model.detail ?? model.id)
        }
      } else if store.isRefreshingAIChatConfiguration {
        Text("Loading models…")
      } else {
        Text("No models reported")
      }

      let reasoningOptions = store.selectedAIChatRoomReasoningOptions(forDestinationID: destinationID)
      if !reasoningOptions.isEmpty {
        Divider()
        Section("Reasoning") {
          Button {
            store.setSelectedAIChatRoomReasoningEffort(nil, forDestinationID: destinationID)
          } label: {
            HStack {
              Text("Default reasoning")
              if store.selectedAIChatRoomReasoningEffort(forDestinationID: destinationID) == nil {
                Image(systemName: "checkmark")
              }
            }
          }
          ForEach(reasoningOptions) { option in
            Button {
              store.setSelectedAIChatRoomReasoningEffort(option.id, forDestinationID: destinationID)
            } label: {
              HStack {
                Text(option.label)
                if store.selectedAIChatRoomReasoningEffort(forDestinationID: destinationID) == option.id {
                  Image(systemName: "checkmark")
                }
              }
            }
            .help(option.detail ?? option.label)
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: destination?.systemImage ?? runtime.systemImage)
        Text(roomModelPickerTitle(forDestinationID: destinationID, destination: destination))
          .lineLimit(1)
          .frame(maxWidth: compact ? 125 : 165)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(isRunning)
    .help("Choose the model for \(destination?.title ?? destinationID) in this shared room")
  }

  private var modelPicker: some View {
    Menu {
      Button {
        store.setSelectedAIChatModel(nil)
      } label: {
        HStack {
          Text("Default model")
          if store.selectedAIChatModel == nil {
            Image(systemName: "checkmark")
          }
        }
      }

      Divider()

      if store.isRefreshingAIChatConfiguration && store.aiChatModelOptions.isEmpty {
        Text("Loading models…")
      } else if store.aiChatModelOptions.isEmpty {
        Text("No models reported")
      } else {
        ForEach(store.aiChatModelOptions) { model in
          Button {
            store.setSelectedAIChatModel(model.id)
          } label: {
            HStack {
              Text(model.label)
              if model.id == store.selectedAIChatModel {
                Image(systemName: "checkmark")
              }
            }
          }
          .help(model.detail ?? model.id)
        }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "cpu")
        Text(store.selectedAIChatModelLabel)
          .lineLimit(1)
          .frame(maxWidth: 220)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(!store.canChangeSelectedAIChatConfiguration)
    .accessibilityIdentifier("ai-chat-model-picker")
    .accessibilityLabel("Model: \(store.selectedAIChatModelLabel)")
    .help("Choose a model for this chat, or inherit the \(store.selectedAIChatDestination.title) default")
  }

  /// A dot chooses its own model in ChatGPT, so it has nothing to configure.
  @ViewBuilder
  private var modelConfigurationPicker: some View {
    if store.selectedAIChatDestination.adapter != .openAIDot {
      modelConfigurationPickerButton
    }
  }

  private var modelConfigurationPickerButton: some View {
    Button {
      showsModelConfiguration.toggle()
    } label: {
      HStack(spacing: 5) {
        Text(store.selectedAIChatModelLabel)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: compact ? 100 : 130)
          .fixedSize(horizontal: true, vertical: false)
        if store.selectedAIChatDestination.supportsReasoningEffort {
          Text("·").foregroundStyle(.tertiary)
          Text(store.selectedAIChatReasoningLabel)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .font(.caption.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.quaternary.opacity(0.5), in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(!store.canChangeSelectedAIChatConfiguration)
    .accessibilityIdentifier("ai-chat-configuration-picker")
    .accessibilityLabel("Model: \(store.selectedAIChatModelLabel), effort: \(store.selectedAIChatReasoningLabel)")
    .help("Choose model and reasoning effort")
    .popover(isPresented: $showsModelConfiguration, arrowEdge: .bottom) {
      VStack(spacing: 16) {
        modelPicker
        if store.selectedAIChatDestination.supportsReasoningEffort {
          effortConfiguration
        }
        Divider()
        HStack {
          if store.isRefreshingAIChatConfiguration {
            ProgressView()
              .controlSize(.small)
            Text("Updating options…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            Task {
              await store.refreshAIChatConfiguration(forceModelCatalogReload: true)
            }
          } label: {
            Label("Refresh Options", systemImage: "arrow.clockwise")
          }
          .controlSize(.small)
          .disabled(store.isRefreshingAIChatConfiguration)
        }
      }
      .padding(18)
      .frame(width: 300)
    }
  }

  private var effortConfiguration: some View {
    VStack(spacing: 10) {
      HStack {
        Image(systemName: "bolt").foregroundStyle(.secondary)
        Spacer()
        Text(store.selectedAIChatReasoningLabel)
          .font(.headline)
          .foregroundStyle(.tint)
        Spacer()
        Button {
          store.setSelectedAIChatReasoningEffort(nil)
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.plain)
        .help(defaultReasoningLabel)
        .accessibilityLabel("Reset to \(defaultReasoningLabel)")
      }
      let options = store.aiChatReasoningOptions
      if options.count > 1 {
        Slider(value: Binding(
          get: {
            let selected = store.selectedAIChatReasoningEffort ?? store.aiChatDefaultReasoningEffort
            return Double(options.firstIndex(where: { $0.id == selected }) ?? 0)
          },
          set: { value in
            let index = min(options.count - 1, max(0, Int(value.rounded())))
            store.setSelectedAIChatReasoningEffort(options[index].id)
          }
        ), in: 0...Double(options.count - 1), step: 1)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(store.selectedAIChatReasoningLabel)
        HStack {
          Text(options.first?.label ?? "")
          Spacer()
          Text(options.last?.label ?? "")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      } else if let option = options.first {
        Button(option.label) { store.setSelectedAIChatReasoningEffort(option.id) }
      } else {
        Text(store.isRefreshingAIChatConfiguration
          ? "Loading reasoning options…" : "No reasoning levels reported for this model")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .disabled(!store.canChangeSelectedAIChatConfiguration)
  }

  private var defaultReasoningLabel: String {
    guard let effort = store.aiChatDefaultReasoningEffort else {
      return "Default reasoning"
    }
    let label = store.aiChatReasoningOptions.first(where: {
      $0.id == effort
    })?.label ?? effort.capitalized
    return "Default reasoning (\(label))"
  }

  private var canSend: Bool {
    !localDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !store.aiChatPendingAttachments.isEmpty
  }

  private var isRunning: Bool {
    guard let threadID = store.selectedAIChatThreadID else { return false }
    return store.isAIChatThreadRunning(threadID)
  }

  private var primaryActionTitle: String {
    if store.isRecordingAIChatVoiceNote {
      return "Finish & Send"
    }
    if isRunning {
      return "Steer"
    }
    if store.selectedAIChatIsSharedRoom,
       store.selectedAIChatRoomTargetDestinationIDs(
         for: AIChatContextPresentation(localDraft).userText
       ).isEmpty {
      return "Post"
    }
    return "Send"
  }

  private var primaryActionSystemImage: String {
    if store.isRecordingAIChatVoiceNote {
      return "arrow.up.circle.fill"
    }
    if isRunning {
      return "arrow.turn.up.right"
    }
    if store.selectedAIChatIsSharedRoom,
       store.selectedAIChatRoomTargetDestinationIDs(
         for: AIChatContextPresentation(localDraft).userText
       ).isEmpty {
      return "text.bubble.fill"
    }
    return "paperplane.fill"
  }

  private var primaryActionHelp: String {
    if store.isRecordingAIChatVoiceNote {
      return "Finish dictating and send the transcript"
    }
    if isRunning {
      return "Steer the current turn now. Press Command-Return to queue behind it instead."
    }
    return "Send message"
  }

  private var visibleDraftBinding: Binding<String> {
    Binding(
      get: { AIChatContextPresentation(localDraft).userText },
      set: { nextText in
        localDraft = AIChatContextPresentation(localDraft).replacingUserText(nextText)
      }
    )
  }

  private func sendIfPossible(
    delivery: AIChatMessageDeliveryPreference = .automatic
  ) -> Bool {
    guard canSend else { return false }
    let text = localDraft
    localDraft = ""
    moveComposerCursorToEndRequest &+= 1
    lastStoreDraft = ""
    store.cacheAIChatComposerDraft("")
    if delivery == .automatic {
      store.submitAIChatComposerInput(text: text)
    } else {
      store.sendComposedAIChatMessage(text: text, delivery: delivery)
    }
    return true
  }

  private func handleReturn(_ delivery: AIChatMessageDeliveryPreference) -> Bool {
    performPrimaryAction(delivery: delivery)
    return true
  }

  private func performPrimaryAction(
    delivery: AIChatMessageDeliveryPreference = .automatic
  ) {
    if store.isRecordingAIChatVoiceNote {
      flushDraftToStore()
      Task {
        await store.stopAIChatVoiceNoteRecording(action: .send)
      }
      return
    }
    _ = sendIfPossible(delivery: AIChatComposerKeyCommand.resolvedDelivery(
      requested: delivery,
      isRunning: isRunning,
      isSlashCommand: AIChatContextPresentation(localDraft).userText
        .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    ))
  }

  private func handleSuggestionCommand(_ command: AIChatComposerSuggestionKeyCommand) -> Bool {
    let visibleText = AIChatContextPresentation(localDraft).userText
    let mentionSuggestions = mentionSuggestions(for: visibleText)
    if !mentionSuggestions.isEmpty {
      switch command {
      case .complete:
        guard let selected = selectedMentionSuggestion(in: mentionSuggestions) else { return false }
        completeMention(selected)
      case .move(let offset):
        selectedMentionSuggestionIndex = AIChatSlashCommandSelection.movedIndex(
          selectedMentionSuggestionIndex,
          by: offset,
          count: mentionSuggestions.count
        )
      }
      return true
    }

    let suggestions = AIChatSlashCommands.suggestions(
      for: visibleText,
      gatewayCommands: store.activeAIChatGatewayCommands,
      corpusSkills: store.corpusAgentSkillCommands
    )
    guard !suggestions.isEmpty else { return false }

    switch command {
    case .complete:
      guard let selected = selectedSlashSuggestion(in: suggestions) else { return false }
      completeSlashCommand(selected)
    case .move(let offset):
      selectedSlashSuggestionIndex = AIChatSlashCommandSelection.movedIndex(
        selectedSlashSuggestionIndex,
        by: offset,
        count: suggestions.count
      )
    }
    return true
  }

  private func selectedSlashSuggestion(in suggestions: [AIChatSlashCommand]) -> AIChatSlashCommand? {
    AIChatSlashCommandSelection.selectedCommand(
      in: suggestions,
      index: selectedSlashSuggestionIndex
    )
  }

  private func completeSlashCommand(_ command: AIChatSlashCommand) {
    let commandText = command.arguments.isEmpty ? "/\(command.name)" : "/\(command.name) "
    localDraft = AIChatContextPresentation(localDraft).replacingUserText(commandText)
    moveComposerCursorToEndRequest &+= 1
  }

  private func selectedMentionSuggestion(
    in suggestions: [AIChatComposerMentionSuggestion]
  ) -> AIChatComposerMentionSuggestion? {
    guard !suggestions.isEmpty else { return nil }
    return suggestions[min(max(0, selectedMentionSuggestionIndex), suggestions.count - 1)]
  }

  private func completeMention(_ suggestion: AIChatComposerMentionSuggestion) {
    let presentation = AIChatContextPresentation(localDraft)
    switch suggestion {
    case .destination(let destination):
      localDraft = presentation.replacingUserText(
        destination.completingMention(in: presentation.userText)
      )
    case .corpusFile(let file):
      let draftWithoutMention = presentation.replacingUserText(
        AIChatMentionSuggestion.removingActiveMention(in: presentation.userText)
      )
      localDraft = store.aiChatDraftByAddingCorpusFileContext(file, to: draftWithoutMention)
    case .dailyNote(_, let file):
      let draftWithoutMention = presentation.replacingUserText(
        AIChatComposerMentionSuggestion.removingActiveDateMention(in: presentation.userText)
      )
      localDraft = store.aiChatDraftByAddingCorpusFileContext(file, to: draftWithoutMention)
    }
    moveComposerCursorToEndRequest &+= 1
  }

  private func roomRoutingSummary(for text: String) -> (title: String, invokesAgent: Bool) {
    let routing = destinationRouting(for: text)
    guard routing.destinationIDs.isEmpty else { return (routing.summary, true) }
    guard let defaultID = store.selectedAIChatRoomDefaultDestinationID else {
      return (routing.summary, false)
    }
    return ("Sends to \(store.aiChatDestinationTitle(defaultID)) · default agent", true)
  }

  private func destinationRouting(for text: String) -> AIChatDestinationRouting {
    AIChatDestinationRouting(
      text,
      destinations: store.enabledAIChatDestinations,
      allDestinationIDs: store.selectedAIChatIsSharedRoom
        ? store.selectedAIChatRoomDestinationIDs
        : store.enabledAIChatDestinations.map(\.id)
    )
  }

  private func mentionSuggestions(for text: String) -> [AIChatComposerMentionSuggestion] {
    AIChatComposerMentionSuggestion.suggestions(
      for: text,
      destinations: store.enabledAIChatDestinations,
      allDestinationIDs: store.selectedAIChatIsSharedRoom
        ? store.selectedAIChatRoomDestinationIDs
        : store.enabledAIChatDestinations.map(\.id),
      corpusFiles: store.corpusFiles,
      dailyNoteFile: { store.existingDailyNoteFile(for: $0.date) }
    )
  }

  private func cacheDraftLocally() {
    store.cacheAIChatComposerDraft(localDraft)
  }

  private func flushDraftToStore() {
    if store.aiChatDraft != localDraft {
      lastStoreDraft = localDraft
      store.publishAIChatComposerDraft(localDraft)
    } else {
      lastStoreDraft = store.aiChatDraft
    }
  }

  private func handleDropAttachment(_ payload: AIChatComposerDropPayload) -> Bool {
    switch payload {
    case .fileURLs(let urls):
      store.attachAIChatFiles(urls: urls)
    case .image(let data, let fileName, let mimeType):
      store.attachAIChatAttachment(data: data, fileName: fileName, mimeType: mimeType)
    }
    return true
  }
}

private struct AIChatVoiceInputMeterView: View {
  @ObservedObject var meterState: WorkspaceInputMeterState

  var body: some View {
    WorkspaceInputMeterView(
      averageLevel: meterState.levels.averageLevel,
      peakLevel: meterState.levels.peakLevel
    )
  }
}

enum AIChatSlashCommandSuggestionsLayout {
  /// Rows shown before the popup scrolls. The suggestion list itself is never
  /// truncated; the selected row is scrolled into view instead.
  static let visibleRowLimit = 8
  static let rowHeight: CGFloat = 30
  static var scrollHeight: CGFloat { CGFloat(visibleRowLimit) * rowHeight }
}

private struct AIChatSlashCommandSuggestions: View {
  let commands: [AIChatSlashCommand]
  let selectedCommandID: AIChatSlashCommand.ID?
  let select: (AIChatSlashCommand) -> Void

  var body: some View {
    VStack(spacing: 2) {
      if commands.count > AIChatSlashCommandSuggestionsLayout.visibleRowLimit {
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            rows
          }
          .frame(height: AIChatSlashCommandSuggestionsLayout.scrollHeight)
          .onAppear { scrollToSelection(proxy) }
          .onChange(of: selectedCommandID) { scrollToSelection(proxy) }
        }
      } else {
        rows
      }

      HStack(spacing: 10) {
        Label("Navigate", systemImage: "arrow.up.arrow.down")
        Text("Tab Complete")
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
    }
    .padding(4)
    .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius))
    .overlay(
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius)
        .stroke(WorkspaceDesign.hairline)
    )
  }

  private var rows: some View {
    VStack(spacing: 2) {
      ForEach(commands) { command in
        Button {
          select(command)
        } label: {
          HStack(spacing: 9) {
            Image(systemName: command.systemImage)
              .frame(width: 18)
              .foregroundStyle(.secondary)
            Text(command.invocation)
              .font(.callout.monospaced().weight(.medium))
            Text(command.summary)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 4)
            if let badge = badge(for: command) {
              Text(badge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
          }
          .contentShape(Rectangle())
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(
            command.id == selectedCommandID ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
          )
        }
        .buttonStyle(.plain)
        .id(command.id)
      }
    }
  }

  private func scrollToSelection(_ proxy: ScrollViewProxy) {
    guard let selectedCommandID else { return }
    proxy.scrollTo(selectedCommandID)
  }

  private func badge(for command: AIChatSlashCommand) -> String? {
    switch command.origin {
    case .openClaw: "OpenClaw"
    case .builtInSkill, .corpusSkill: "Skill"
    case .org2: command.isAgentAssisted ? "Agent" : nil
    }
  }
}

struct AIChatMentionSuggestion: Identifiable, Equatable {
  let id: String
  let title: String
  let detail: String
  let systemImage: String
  let insertion: String

  static let all: [AIChatMentionSuggestion] = suggestions(
    for: "@",
    destinations: AIChatDestinationConfiguration.defaults,
    allDestinationIDs: AIChatDestinationConfiguration.defaults.map(\.id)
  )

  static func suggestions(for text: String) -> [AIChatMentionSuggestion] {
    suggestions(
      for: text,
      destinations: AIChatDestinationConfiguration.defaults,
      allDestinationIDs: AIChatDestinationConfiguration.defaults.map(\.id)
    )
  }

  static func suggestions(
    for text: String,
    destinations: [AIChatDestinationConfiguration],
    allDestinationIDs: [String]
  ) -> [AIChatMentionSuggestion] {
    guard let activeRange = activeMentionRange(in: text) else { return [] }
    let query = String(text[activeRange]).dropFirst().lowercased()
    let enabled = destinations.filter(\.isEnabled)
    let destinationSuggestions = enabled.map { destination in
      AIChatMentionSuggestion(
        id: destination.mention,
        title: "@\(destination.mention)",
        detail: "Request a response from \(destination.name)",
        systemImage: destination.adapter.systemImage,
        insertion: "@\(destination.mention) "
      )
    }
    let destinationByID = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
    let allMentions = allDestinationIDs.compactMap { destinationByID[$0]?.mention }
    let allSuggestion = AIChatMentionSuggestion(
      id: "all",
      title: "@all",
      detail: "Request a response from every destination in this thread",
      systemImage: "person.2.fill",
      insertion: allMentions.map { "@\($0)" }.joined(separator: " ") + " "
    )
    return (destinationSuggestions + [allSuggestion]).filter { suggestion in
      suggestion.id.hasPrefix(query)
        || suggestion.title.dropFirst().lowercased().hasPrefix(query)
    }
  }

  func completingMention(in text: String) -> String {
    guard let range = Self.activeMentionRange(in: text) else { return text }
    return text.replacingCharacters(in: range, with: insertion)
  }

  static func activeMentionQuery(in text: String) -> String? {
    guard let range = activeMentionRange(in: text) else { return nil }
    return String(text[range].dropFirst())
  }

  static func removingActiveMention(in text: String) -> String {
    guard let range = activeMentionRange(in: text) else { return text }
    return text.replacingCharacters(in: range, with: "")
  }

  private static func activeMentionRange(in text: String) -> Range<String.Index>? {
    guard let atIndex = text.lastIndex(of: "@") else { return nil }
    if atIndex != text.startIndex {
      let previous = text[text.index(before: atIndex)]
      guard previous.isWhitespace else { return nil }
    }
    let suffix = text[atIndex...]
    guard suffix.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
      return nil
    }
    return atIndex..<text.endIndex
  }
}

enum AIChatComposerMentionSuggestion: Identifiable, Equatable {
  case destination(AIChatMentionSuggestion)
  case corpusFile(CorpusFile)
  /// An existing daily note resolved from `@today`, `@july 10`, and similar.
  case dailyNote(WorkspaceDateMentionCandidate, CorpusFile)

  var id: String {
    switch self {
    case .destination(let suggestion): "destination:\(suggestion.id)"
    case .corpusFile(let file): "file:\(file.id)"
    case .dailyNote(_, let file): "daily:\(file.id)"
    }
  }

  var title: String {
    switch self {
    case .destination(let suggestion): suggestion.title
    case .corpusFile(let file): file.name
    case .dailyNote(let candidate, _): candidate.title
    }
  }

  var detail: String {
    switch self {
    case .destination(let suggestion): suggestion.detail
    case .corpusFile(let file): file.relativePath
    case .dailyNote(_, let file): "Daily note · \(file.relativePath)"
    }
  }

  var systemImage: String {
    switch self {
    case .destination(let suggestion): suggestion.systemImage
    case .corpusFile: "doc.text"
    case .dailyNote: "calendar"
    }
  }

  static func removingActiveDateMention(in text: String) -> String {
    guard let match = WorkspaceDateMentions.matchAtEnd(of: text) else { return text }
    return WorkspaceDateMentions.removingMatch(match, in: text)
  }

  static func suggestions(
    for text: String,
    destinations: [AIChatDestinationConfiguration],
    allDestinationIDs: [String],
    corpusFiles: [CorpusFile],
    dailyNoteFile: (WorkspaceDateMentionCandidate) -> CorpusFile? = { _ in nil },
    now: Date = Date(),
    limit: Int = WorkspaceMentionCandidates.defaultLimit
  ) -> [AIChatComposerMentionSuggestion] {
    let dailyNoteSuggestions = WorkspaceDateMentions.matchAtEnd(of: text).map { match in
      WorkspaceDateMentions.candidates(for: match.query, now: now).compactMap { candidate in
        dailyNoteFile(candidate).map { AIChatComposerMentionSuggestion.dailyNote(candidate, $0) }
      }
    } ?? []
    guard let query = AIChatMentionSuggestion.activeMentionQuery(in: text) else {
      return Array(dailyNoteSuggestions.prefix(limit))
    }
    let destinationSuggestions = AIChatMentionSuggestion.suggestions(
      for: text,
      destinations: destinations,
      allDestinationIDs: allDestinationIDs
    )
    let dailyNotePaths = Set(dailyNoteSuggestions.compactMap { suggestion -> String? in
      if case .dailyNote(_, let file) = suggestion { return file.path }
      return nil
    })
    let matchingFiles = WorkspaceMentionCandidates.corpusFiles(
      matching: query,
      in: corpusFiles,
      excludingPaths: dailyNotePaths,
      limit: max(0, limit - destinationSuggestions.count - dailyNoteSuggestions.count)
    )
    return Array(
      (destinationSuggestions.map(AIChatComposerMentionSuggestion.destination)
        + dailyNoteSuggestions
        + matchingFiles.map(AIChatComposerMentionSuggestion.corpusFile))
        .prefix(limit)
    )
  }
}

private struct AIChatMentionSuggestionsView: View {
  let suggestions: [AIChatComposerMentionSuggestion]
  let selectedSuggestionID: AIChatComposerMentionSuggestion.ID?
  let select: (AIChatComposerMentionSuggestion) -> Void

  var body: some View {
    VStack(spacing: 2) {
      ForEach(suggestions) { suggestion in
        Button {
          select(suggestion)
        } label: {
          HStack(spacing: 9) {
            Image(systemName: suggestion.systemImage)
              .frame(width: 18)
              .foregroundStyle(.secondary)
            Text(suggestion.title)
              .font(.callout.monospaced().weight(.medium))
            Text(suggestion.detail)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 4)
          }
          .contentShape(Rectangle())
          .padding(.horizontal, 9)
          .padding(.vertical, 6)
          .background(
            suggestion.id == selectedSuggestionID ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
          )
        }
        .buttonStyle(.plain)
      }

      HStack(spacing: 10) {
        Label("Navigate", systemImage: "arrow.up.arrow.down")
        Text("Tab Complete")
      }
      .font(.caption2.weight(.medium))
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
    }
    .padding(4)
    .background(WorkspaceDesign.surfaceBackground, in: RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius))
    .overlay(
      RoundedRectangle(cornerRadius: WorkspaceDesign.cornerRadius)
        .stroke(WorkspaceDesign.hairline)
    )
  }
}

enum AIChatComposerDraftSync {
  static func localDraftAfterStoreChange(
    localDraft: String,
    previousStoreDraft: String,
    nextStoreDraft: String
  ) -> String {
    guard nextStoreDraft != localDraft else { return localDraft }
    guard localDraft != previousStoreDraft else { return nextStoreDraft }
    guard !nextStoreDraft.isEmpty else { return "" }
    guard !localDraft.isEmpty else { return nextStoreDraft }

    if nextStoreDraft.contains(localDraft) {
      return nextStoreDraft
    }

    if !previousStoreDraft.isEmpty,
       let range = nextStoreDraft.range(of: previousStoreDraft) {
      var merged = nextStoreDraft
      merged.replaceSubrange(range, with: localDraft)
      return merged
    }

    return nextStoreDraft + localDraft
  }
}

private struct AIChatPendingAttachmentsView: View {
  @Environment(WorkspaceStore.self) private var store
  let compact: Bool

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(store.aiChatPendingAttachments) { attachment in
          AIChatPendingAttachmentChip(attachment: attachment)
        }
      }
      .padding(.vertical, 1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct AIChatPendingAttachmentChip: View {
  @Environment(WorkspaceStore.self) private var store
  let attachment: AIChatAttachment
  @State private var isPreviewing = false

  var body: some View {
    HStack(spacing: 7) {
      Button {
        isPreviewing = true
      } label: {
        HStack(spacing: 7) {
          AIChatAsyncAttachmentImage(attachment: attachment) { error in
            Image(systemName: error == nil
              ? AIChatAttachmentPresentation.systemImage(for: attachment.mimeType)
              : "exclamationmark.triangle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .frame(width: 30, height: 30)
            .background(WorkspaceDesign.subtleFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
          }
          .frame(width: 30, height: 30)
          .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

          VStack(alignment: .leading, spacing: 1) {
            Text(attachment.fileName)
              .font(.caption.weight(.medium))
              .lineLimit(1)
              .truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: 150, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Preview attachment")

      Button {
        store.removeAIChatPendingAttachment(attachment)
      } label: {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Remove attachment")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(WorkspaceDesign.controlFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(WorkspaceDesign.hairline)
    )
    .help("\(attachment.fileName) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))")
    .sheet(isPresented: $isPreviewing) {
      AIChatAttachmentPreviewView(attachment: attachment)
    }
  }
}

enum AIChatComposerLayout {
  static let cornerRadius: CGFloat = 20
  static let contentInset: CGFloat = 10
  static let toolbarHorizontalInset: CGFloat = 9
  static let toolbarBottomInset: CGFloat = 9
  static let externalSpacing: CGFloat = 8
  static let primaryActionDiameter: CGFloat = 32
}

enum AIChatComposerSizing {
  static func height(for text: String, compact: Bool) -> CGFloat {
    // Both layouts reach their height cap within this prefix. Do not scan a
    // restored large draft on every keystroke after it has reached that cap.
    let visualLineCount = estimatedVisualLineCount(for: String(text.prefix(576)), compact: compact)
    let baseHeight: CGFloat = 34
    let lineHeight: CGFloat = 20
    let minHeight: CGFloat = compact ? 54 : 58
    let maxHeight: CGFloat = compact ? 150 : 190
    return min(max(baseHeight + CGFloat(max(1, visualLineCount)) * lineHeight, minHeight), maxHeight)
  }

  static func estimatedVisualLineCount(for text: String, compact: Bool) -> Int {
    guard !text.isEmpty else { return 1 }
    let wrapColumn = compact ? 42 : 72
    return text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        max(1, Int(ceil(Double(line.count + 1) / Double(wrapColumn))))
      }
      .reduce(0, +)
  }
}

enum AIChatComposerKeyCommand {
  static func isSendCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    return isReturnKey(keyCode) && relevantModifiers.isEmpty
  }

  /// Command-Return: queue behind the running turn instead of steering it.
  static func isQueueCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    return isReturnKey(keyCode)
      && (relevantModifiers == [.command] || relevantModifiers == [.command, .shift])
  }

  static func isNewlineCommand(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    return isReturnKey(keyCode) && relevantModifiers == [.shift]
  }

  /// Messages sent while a turn is running steer it by default; Command-Return
  /// queues a follow-up instead. Slash commands keep their own handling, and
  /// a runtime that cannot steer still queues.
  static func resolvedDelivery(
    requested: AIChatMessageDeliveryPreference,
    isRunning: Bool,
    isSlashCommand: Bool = false
  ) -> AIChatMessageDeliveryPreference {
    guard isRunning else { return .automatic }
    if requested == .automatic && !isSlashCommand {
      return .steer
    }
    return requested
  }

  static func suggestionCommand(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
  ) -> AIChatComposerSuggestionKeyCommand? {
    let relevantModifiers = modifiers.intersection([.command, .option, .control, .shift])
    guard relevantModifiers.isEmpty else { return nil }
    switch keyCode {
    case 36, 48, 76:
      return .complete
    case 125:
      return .move(1)
    case 126:
      return .move(-1)
    default:
      return nil
    }
  }

  private static func isReturnKey(_ keyCode: UInt16) -> Bool {
    keyCode == 36 || keyCode == 76
  }
}

enum AIChatComposerSuggestionKeyCommand: Equatable {
  case complete
  case move(Int)
}

enum AIChatComposerDropPayload: Equatable {
  case fileURLs([URL])
  case image(data: Data, fileName: String, mimeType: String)
}

enum AIChatComposerDrop {
  static func payload(from pasteboard: NSPasteboard) -> AIChatComposerDropPayload? {
    let urls = (pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) ?? []).compactMap { item -> URL? in
      guard let url = item as? NSURL else { return nil }
      return url as URL
    }
    if !urls.isEmpty {
      return .fileURLs(urls)
    }

    if let data = pasteboard.data(forType: .png) {
      return .image(data: data, fileName: "Dropped Image.png", mimeType: "image/png")
    }
    if let data = pasteboard.data(forType: .tiff) {
      return .image(data: data, fileName: "Dropped Image.tiff", mimeType: "image/tiff")
    }
    return nil
  }
}

enum AIChatAttachmentPresentation {
  static func systemImage(for mimeType: String) -> String {
    if mimeType.hasPrefix("image/") { return "photo" }
    if mimeType.hasPrefix("audio/") { return "waveform" }
    if mimeType == "application/pdf" { return "doc.richtext" }
    if mimeType.hasPrefix("text/") { return "doc.text" }
    return "doc"
  }
}

enum AIChatSlashCommandSelection {
  static func selectedCommand(
    in commands: [AIChatSlashCommand],
    index: Int
  ) -> AIChatSlashCommand? {
    guard !commands.isEmpty else { return nil }
    return commands[min(max(0, index), commands.count - 1)]
  }

  static func movedIndex(_ index: Int, by offset: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let normalizedIndex = ((index % count) + count) % count
    return ((normalizedIndex + offset) % count + count) % count
  }
}

struct AIChatComposerTextView: NSViewRepresentable {
  @Binding var text: String
  var recognizedMentions: [String] = []
  let focusOnAppear: Bool
  let moveCursorToEndRequest: Int
  let onReturn: (AIChatMessageDeliveryPreference) -> Bool
  let onSuggestionCommand: (AIChatComposerSuggestionKeyCommand) -> Bool
  let onDropAttachment: (AIChatComposerDropPayload) -> Bool
  let onPasteLargeText: (String) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder

    let textView = CommandSubmitTextView()
    textView.delegate = context.coordinator
    textView.onReturn = {
      context.coordinator.parent.onReturn($0)
    }
    textView.onSuggestionCommand = {
      context.coordinator.parent.onSuggestionCommand($0)
    }
    textView.onDropAttachment = {
      context.coordinator.parent.onDropAttachment($0)
    }
    textView.onPasteLargeText = { context.coordinator.parent.onPasteLargeText($0) }
    textView.registerForDraggedTypes([.fileURL, .png, .tiff])
    textView.string = text
    textView.font = .systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = .labelColor
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainerInset = NSSize(width: 4, height: 5)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    scrollView.documentView = textView
    context.coordinator.lastMoveCursorToEndRequest = moveCursorToEndRequest
    context.coordinator.textSynchronization = AIChatComposerTextSynchronization(
      initialModelText: text
    )
    context.coordinator.recognizedMentions = Set(recognizedMentions)
    context.coordinator.highlightMentions(in: textView)

    if focusOnAppear {
      DispatchQueue.main.async {
        textView.window?.makeFirstResponder(textView)
      }
    }

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? CommandSubmitTextView else { return }
    context.coordinator.parent = self
    textView.onReturn = {
      context.coordinator.parent.onReturn($0)
    }
    textView.onSuggestionCommand = {
      context.coordinator.parent.onSuggestionCommand($0)
    }
    textView.onDropAttachment = {
      context.coordinator.parent.onDropAttachment($0)
    }
    textView.onPasteLargeText = { context.coordinator.parent.onPasteLargeText($0) }
    let movesCursorToEnd = context.coordinator.lastMoveCursorToEndRequest != moveCursorToEndRequest
    let selectedRange = textView.selectedRange()
    // AppKit can accept another keystroke before SwiftUI presents the state
    // from the previous one. Never replace that newer native edit with its
    // delayed model echo, because doing so also restores an older selection.
    let modelUpdate = context.coordinator.textSynchronization.modelTextUpdate(
      text,
      forced: movesCursorToEnd
    )
    let textChanged = modelUpdate == .applyModelText && textView.string != text
    if textChanged {
      context.coordinator.isApplyingModelText = true
      textView.string = text
      context.coordinator.isApplyingModelText = false
    }
    if textChanged || movesCursorToEnd {
      let nextRange = AIChatComposerSelection.updatedRange(
        previous: selectedRange,
        textLength: (text as NSString).length,
        movesToEnd: movesCursorToEnd
      )
      if textView.selectedRange() != nextRange {
        textView.setSelectedRange(nextRange)
        textView.scrollRangeToVisible(nextRange)
      }
    }
    if movesCursorToEnd, let window = textView.window, window.firstResponder !== textView {
      window.makeFirstResponder(textView)
    }
    context.coordinator.lastMoveCursorToEndRequest = moveCursorToEndRequest
    let mentions = Set(recognizedMentions)
    if textChanged || mentions != context.coordinator.recognizedMentions {
      context.coordinator.recognizedMentions = mentions
      context.coordinator.highlightMentions(in: textView)
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: AIChatComposerTextView
    var lastMoveCursorToEndRequest = 0
    var textSynchronization = AIChatComposerTextSynchronization()
    var isApplyingModelText = false
    var recognizedMentions: Set<String> = []

    /// Marks recognized agent mentions with display-only attributes, so the
    /// draft stays plain text and undo, copy, and send are unaffected.
    @MainActor
    func highlightMentions(in textView: NSTextView) {
      guard let layoutManager = textView.layoutManager else { return }
      let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
      layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
      layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
      let ranges = AIChatDestinationRouting.recognizedMentionRanges(
        in: textView.string,
        recognizedTokens: recognizedMentions
      )
      for range in ranges {
        layoutManager.addTemporaryAttributes(
          [
            .foregroundColor: WorkspaceThemeCenter.shared.liveColor(.link),
            .backgroundColor: WorkspaceThemeCenter.shared.liveColor(.link, alpha: 0.14),
          ],
          forCharacterRange: range
        )
      }
    }

    init(parent: AIChatComposerTextView) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard !isApplyingModelText,
            let textView = notification.object as? NSTextView
      else { return }
      let nativeText = textView.string
      textSynchronization.nativeTextDidChange(nativeText)
      highlightMentions(in: textView)
      parent.text = nativeText
    }
  }

  final class CommandSubmitTextView: NSTextView {
    var onReturn: ((AIChatMessageDeliveryPreference) -> Bool)?
    var onSuggestionCommand: ((AIChatComposerSuggestionKeyCommand) -> Bool)?
    var onDropAttachment: ((AIChatComposerDropPayload) -> Bool)?
    var onPasteLargeText: ((String) -> Bool)?
    private var pendingLatencyTokens: [WorkspaceInteractionLatency.Token] = []

    @discardableResult
    func attachLargePaste(from pasteboard: NSPasteboard) -> Bool {
      guard let text = pasteboard.string(forType: .string),
            AIChatLargePaste.shouldAttach(text)
      else { return false }
      return onPasteLargeText?(text) == true
    }

    override func paste(_ sender: Any?) {
      if !attachLargePaste(from: .general) { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
      if !attachLargePaste(from: .general) { super.pasteAsPlainText(sender) }
    }

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      let tokens = pendingLatencyTokens
      pendingLatencyTokens.removeAll(keepingCapacity: true)
      for token in tokens {
        WorkspaceInteractionLatency.finish(token)
      }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
      if AIChatComposerDrop.payload(from: sender.draggingPasteboard) != nil {
        return .copy
      }
      return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
      if let payload = AIChatComposerDrop.payload(from: sender.draggingPasteboard),
         onDropAttachment?(payload) == true {
        return true
      }
      return super.performDragOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
      let latencyToken = WorkspaceInteractionLatency.begin(.composerKeyToDraw)
      defer {
        pendingLatencyTokens.append(latencyToken)
        needsDisplay = true
      }
      if let command = AIChatComposerKeyCommand.suggestionCommand(
        keyCode: event.keyCode,
        modifiers: event.modifierFlags
      ), onSuggestionCommand?(command) == true {
        return
      }
      if AIChatComposerKeyCommand.isQueueCommand(keyCode: event.keyCode, modifiers: event.modifierFlags),
         onReturn?(.followUp) == true {
        return
      }
      if AIChatComposerKeyCommand.isSendCommand(keyCode: event.keyCode, modifiers: event.modifierFlags),
         onReturn?(.automatic) == true {
        return
      }
      if AIChatComposerKeyCommand.isNewlineCommand(keyCode: event.keyCode, modifiers: event.modifierFlags) {
        insertText("\n", replacementRange: selectedRange())
        return
      }
      super.keyDown(with: event)
    }
  }
}

enum AIChatComposerModelTextUpdate: Equatable {
  case applyModelText
  case preserveNativeText
}

struct AIChatComposerTextSynchronization {
  private var pendingNativeTexts: [String] = []
  private var lastModelText: String?

  init(initialModelText: String? = nil) {
    lastModelText = initialModelText
  }

  mutating func nativeTextDidChange(_ text: String) {
    if pendingNativeTexts.isEmpty, let lastModelText {
      pendingNativeTexts.append(lastModelText)
    }
    guard pendingNativeTexts.last != text else { return }
    pendingNativeTexts.append(text)
  }

  mutating func modelTextUpdate(
    _ text: String,
    forced: Bool = false
  ) -> AIChatComposerModelTextUpdate {
    lastModelText = text
    if forced {
      pendingNativeTexts.removeAll(keepingCapacity: true)
      return .applyModelText
    }

    if let acknowledgedIndex = pendingNativeTexts.lastIndex(of: text) {
      pendingNativeTexts.removeFirst(acknowledgedIndex + 1)
      return .preserveNativeText
    }

    pendingNativeTexts.removeAll(keepingCapacity: true)
    return .applyModelText
  }
}

enum AIChatComposerSelection {
  static func updatedRange(
    previous: NSRange,
    textLength: Int,
    movesToEnd: Bool
  ) -> NSRange {
    guard !movesToEnd else {
      return NSRange(location: textLength, length: 0)
    }
    let location = min(previous.location, textLength)
    return NSRange(
      location: location,
      length: min(previous.length, textLength - location)
    )
  }
}

/// Observes only the high-frequency live-turn model, so token streaming does
/// not rebuild the transcript, composer, sidebar, or unrelated workspace UI.
struct AIChatLiveTypingIndicatorView: View {
  @ObservedObject var liveState: AIChatLiveState
  let threadID: UUID?
  let startedAt: Date?
  let runtime: AIChatRuntime
  let destinationTitle: String?
  let compact: Bool
  let onStop: () -> Void

  var body: some View {
    let presentationSnapshot = threadID.map(liveState.presentationSnapshot(for:)) ?? .empty
    AIChatTypingIndicatorView(
      startedAt: startedAt,
      lastEventAt: threadID.flatMap(liveState.lastEventAt(for:)),
      runtime: runtime,
      destinationTitle: destinationTitle,
      connectionState: threadID.map(liveState.connectionState(for:)) ?? .disconnected,
      connectionDetail: threadID.flatMap(liveState.connectionDetail(for:)),
      runID: threadID.flatMap(liveState.activeRunID(for:)),
      streamingReply: presentationSnapshot.streamingReply,
      streamingReplyHasOmittedPrefix: presentationSnapshot.isStreamingReplyTruncated,
      reasoning: presentationSnapshot.reasoning,
      reasoningHasOmittedPrefix: presentationSnapshot.isReasoningTruncated,
      activities: threadID.map(liveState.runActivities(for:)) ?? [],
      compact: compact,
      onStop: onStop
    )
  }
}

struct AIChatLiveTextPreparationInput: Equatable, Sendable {
  static let maximumActivityCount = 80
  static let maximumActivityDetailUTF8ByteCount = 8 * 1_024

  let rawText: String
  let showsAll: Bool
  let hasOmittedPrefix: Bool
  let reasoning: String
  let reasoningHasOmittedPrefix: Bool
  let activities: [AIChatRunActivity]

  init(
    rawText: String,
    showsAll: Bool,
    hasOmittedPrefix: Bool = false,
    reasoning: String = "",
    reasoningHasOmittedPrefix: Bool = false,
    activities: [AIChatRunActivity] = []
  ) {
    self.rawText = rawText
    self.showsAll = showsAll
    self.hasOmittedPrefix = hasOmittedPrefix
    self.reasoning = reasoning
    self.reasoningHasOmittedPrefix = reasoningHasOmittedPrefix
    self.activities = activities.suffix(Self.maximumActivityCount).map { activity in
      AIChatRunActivity(
        id: String(activity.id.prefix(256)),
        runID: String(activity.runID.prefix(256)),
        kind: activity.kind,
        title: String(activity.title.prefix(512)),
        detail: activity.detail.map {
          AIChatMessageBodyExcerpt(
            $0,
            utf8ByteLimit: Self.maximumActivityDetailUTF8ByteCount
          ).text
        },
        status: activity.status,
        updatedAt: activity.updatedAt
      )
    }
  }
}

struct AIChatPreparedLiveTextPresentation: Equatable, Sendable {
  let text: AIChatProgressPresentation.LiveTextPresentation?
  let body: AIChatPreparedMessageBody?
  let reasoning: String?
  let activityFeedItems: [AIChatActivityFeedItem]
}

private struct AIChatLiveTextPreparationTaskKey: Equatable {
  let lastEventAt: Date?
  let showsAll: Bool
  let streamingCharacterCount: Int
  let reasoningCharacterCount: Int
  let activityCount: Int
  let latestActivityUpdate: Date?
}

actor AIChatLiveTextPreparationCoordinator {
  static let shared = AIChatLiveTextPreparationCoordinator()

  private struct Entry {
    let token: UUID
    let input: AIChatLiveTextPreparationInput
    let task: Task<AIChatPreparedLiveTextPresentation?, Never>
  }

  private var entries: [UUID: [Entry]] = [:]
  private var tailTask: Task<AIChatPreparedLiveTextPresentation?, Never>?
  private var tailToken: UUID?
  private var preparationCountForTesting = 0
  private var activeWorkerCountValueForTesting = 0
  private var peakConcurrentWorkerCountValueForTesting = 0
  private var activeTokensByStream: [UUID: UUID] = [:]
  private var parserInputsForTesting: [AIChatLiveTextPreparationInput] = []
  private var pausesWorkersForTesting = false
  private var pausedWorkerContinuationsForTesting: [CheckedContinuation<Void, Never>] = []

  func prepare(
    streamID: UUID,
    input: AIChatLiveTextPreparationInput
  ) async -> AIChatPreparedLiveTextPresentation? {
    let token: UUID
    let task: Task<AIChatPreparedLiveTextPresentation?, Never>
    if let existing = entries[streamID]?.first(where: {
      $0.input == input && !$0.task.isCancelled
    }) {
      token = existing.token
      task = existing.task
    } else {
      let activeToken = activeTokensByStream[streamID]
      let retainedEntries = entries[streamID]?.filter { entry in
        if entry.token == activeToken { return true }
        entry.task.cancel()
        return false
      } ?? []
      if retainedEntries.isEmpty {
        entries.removeValue(forKey: streamID)
      } else {
        entries[streamID] = retainedEntries
      }
      let previousTask = tailTask
      token = UUID()
      task = Task.detached(priority: .userInitiated) {
        if let previousTask {
          _ = await previousTask.value
        }
        guard !Task.isCancelled else { return nil }
        await self.workerDidStart(streamID: streamID, token: token)
        guard !Task.isCancelled else {
          await self.workerDidFinish(streamID: streamID, token: token)
          return nil
        }
        await self.parserWillStart(input: input)
        let text = AIChatProgressPresentation.liveTextPresentation(
          from: input.rawText,
          showsAll: input.showsAll,
          hasOmittedPrefix: input.hasOmittedPrefix
        )
        let body = text.flatMap {
          AIChatMessagePresentationBuilder.prepareExpandedBody(
            sourceText: $0.text,
            role: .assistant
          )
        }
        let reasoning = AIChatProgressPresentation.reasoningText(
          from: input.reasoning,
          hasOmittedPrefix: input.reasoningHasOmittedPrefix
        )
        let activityFeedItems = AIChatActivityFeed.items(from: input.activities)
        let prepared = body == nil && reasoning == nil && activityFeedItems.isEmpty
          ? nil
          : AIChatPreparedLiveTextPresentation(
            text: text,
            body: body,
            reasoning: reasoning,
            activityFeedItems: activityFeedItems
          )
        await self.workerDidFinish(streamID: streamID, token: token)
        return prepared
      }
      entries[streamID, default: []].append(Entry(
        token: token,
        input: input,
        task: task
      ))
      tailTask = task
      tailToken = token
      preparationCountForTesting += 1
    }
    let prepared = await task.value
    removeFinishedEntry(streamID: streamID, token: token)
    if tailToken == token {
      tailTask = nil
      tailToken = nil
    }
    return Task.isCancelled ? nil : prepared
  }

  private func removeFinishedEntry(streamID: UUID, token: UUID) {
    guard var streamEntries = entries[streamID] else { return }
    streamEntries.removeAll { $0.token == token }
    if streamEntries.isEmpty {
      entries.removeValue(forKey: streamID)
    } else {
      entries[streamID] = streamEntries
    }
  }

  private func workerDidStart(streamID: UUID, token: UUID) async {
    activeWorkerCountValueForTesting += 1
    peakConcurrentWorkerCountValueForTesting = max(
      peakConcurrentWorkerCountValueForTesting,
      activeWorkerCountValueForTesting
    )
    activeTokensByStream[streamID] = token
    guard pausesWorkersForTesting else { return }
    await withCheckedContinuation { continuation in
      pausedWorkerContinuationsForTesting.append(continuation)
    }
  }

  private func parserWillStart(input: AIChatLiveTextPreparationInput) {
    parserInputsForTesting.append(input)
  }

  private func workerDidFinish(streamID: UUID, token: UUID) {
    activeWorkerCountValueForTesting -= 1
    if activeTokensByStream[streamID] == token {
      activeTokensByStream.removeValue(forKey: streamID)
    }
  }

  func resetForTesting() async {
    setWorkersPausedForTesting(false)
    let pendingTasks = entries.values.flatMap { $0 }.map(\.task)
    for task in pendingTasks {
      _ = await task.value
    }
    entries.removeAll()
    tailTask = nil
    tailToken = nil
    preparationCountForTesting = 0
    activeWorkerCountValueForTesting = 0
    peakConcurrentWorkerCountValueForTesting = 0
    activeTokensByStream.removeAll()
    parserInputsForTesting.removeAll()
  }

  func countForTesting() -> Int { preparationCountForTesting }
  func activeWorkerCountForTesting() -> Int { activeWorkerCountValueForTesting }
  func peakConcurrentWorkerCountForTesting() -> Int { peakConcurrentWorkerCountValueForTesting }
  func parserInputsForTestingSnapshot() -> [AIChatLiveTextPreparationInput] {
    parserInputsForTesting
  }

  func setWorkersPausedForTesting(_ paused: Bool) {
    pausesWorkersForTesting = paused
    guard !paused else { return }
    let continuations = pausedWorkerContinuationsForTesting
    pausedWorkerContinuationsForTesting.removeAll()
    continuations.forEach { $0.resume() }
  }
}

struct AIChatTypingIndicatorView: View {
  static let quietRunInterval: TimeInterval = 2 * 60
  static let stalledRunInterval: TimeInterval = 10 * 60

  /// Copy shown once a connected run has been quiet past each liveness
  /// threshold. OpenCode streams nothing while a long tool call (a build or
  /// test run) executes, so a quiet OpenCode run is reported as waiting rather
  /// than as possibly stalled.
  struct LivenessThresholdPresentation: Equatable {
    let quietTitle: String
    let quietDetail: String
    let stalledTitle: String
    let stalledDetail: String
    let stalledAnimates: Bool
  }

  static func livenessThresholdPresentation(
    runtime: AIChatRuntime,
    displayTitle: String
  ) -> LivenessThresholdPresentation {
    let quietTitle = "Waiting for \(displayTitle)"
    let quietDetail = "No new activity for 2m. It may still be working."
    if runtime == .openCode {
      return LivenessThresholdPresentation(
        quietTitle: quietTitle,
        quietDetail: quietDetail,
        stalledTitle: quietTitle,
        stalledDetail: "No new output for 10m. OpenCode is still running; long tool calls can be quiet.",
        stalledAnimates: true
      )
    }
    return LivenessThresholdPresentation(
      quietTitle: quietTitle,
      quietDetail: quietDetail,
      stalledTitle: "\(displayTitle) may be stalled",
      stalledDetail: "No new activity for 10m. The run is saved; the connection or agent may be stalled.",
      stalledAnimates: false
    )
  }

  let startedAt: Date?
  let lastEventAt: Date?
  let runtime: AIChatRuntime
  let destinationTitle: String?
  let connectionState: OpenClawGatewayConnectionState
  let connectionDetail: String?
  let runID: String?
  let streamingReply: String
  let streamingReplyHasOmittedPrefix: Bool
  let reasoning: String
  let reasoningHasOmittedPrefix: Bool
  let activities: [AIChatRunActivity]
  let compact: Bool
  let onStop: () -> Void

  @State private var showsAllStreamingProgress = false
  @State private var statusEvaluationDate = Date()
  @State private var livePresentation: AIChatPreparedLiveTextPresentation?
  @State private var livePresentationStreamID = UUID()

  init(
    startedAt: Date?,
    lastEventAt: Date? = nil,
    runtime: AIChatRuntime = .openClaw,
    destinationTitle: String? = nil,
    connectionState: OpenClawGatewayConnectionState,
    connectionDetail: String?,
    runID: String?,
    streamingReply: String,
    streamingReplyHasOmittedPrefix: Bool = false,
    reasoning: String,
    reasoningHasOmittedPrefix: Bool = false,
    activities: [AIChatRunActivity],
    compact: Bool,
    onStop: @escaping () -> Void
  ) {
    self.startedAt = startedAt
    self.lastEventAt = lastEventAt
    self.runtime = runtime
    self.destinationTitle = destinationTitle
    self.connectionState = connectionState
    self.connectionDetail = connectionDetail
    self.runID = runID
    self.streamingReply = streamingReply
    self.streamingReplyHasOmittedPrefix = streamingReplyHasOmittedPrefix
    self.reasoning = reasoning
    self.reasoningHasOmittedPrefix = reasoningHasOmittedPrefix
    self.activities = activities
    self.compact = compact
    self.onStop = onStop
  }

  var body: some View {
    let livePresentationInput = AIChatLiveTextPreparationInput(
      rawText: streamingReply,
      showsAll: showsAllStreamingProgress,
      hasOmittedPrefix: streamingReplyHasOmittedPrefix,
      reasoning: reasoning,
      reasoningHasOmittedPrefix: reasoningHasOmittedPrefix,
      activities: activities
    )
    let livePresentationTaskKey = AIChatLiveTextPreparationTaskKey(
      lastEventAt: lastEventAt,
      showsAll: showsAllStreamingProgress,
      streamingCharacterCount: streamingReply.count,
      reasoningCharacterCount: reasoning.count,
      activityCount: activities.count,
      latestActivityUpdate: activities.last?.updatedAt
    )
    let presentedActivityItems = livePresentation?.activityFeedItems ?? []
    let presentedReasoning = livePresentation?.reasoning
    HStack {
      VStack(alignment: .leading, spacing: 9) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            AIChatShimmeringStatusText(
              titleProvider: {
                statusTitle(
                  now: $0,
                  activityFeedItems: presentedActivityItems,
                  hasReasoning: presentedReasoning != nil
                )
              },
              animates: statusAnimates(now: statusEvaluationDate)
            )
            AppKitPeriodicLabel(
              font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
              color: .tertiaryLabelColor,
              textProvider: { elapsedText(now: $0) }
            )
            .frame(width: 58, height: 14, alignment: .leading)
            if canStop {
              Button(action: onStop) {
                Image(systemName: "stop.fill")
                  .font(.system(size: 7, weight: .bold))
                  .frame(width: 22, height: 22)
                  .background(Color.secondary.opacity(0.11), in: Circle())
                  .contentShape(Circle())
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .accessibilityLabel("Stop \(displayTitle) run")
              .help("Stop this \(displayTitle) run")
            }
          }
          .frame(minHeight: 20)

          if let statusDetail = statusDetail(now: statusEvaluationDate) {
            Text(statusDetail)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .help(connectionHelp(now: statusEvaluationDate))

        if let livePresentation,
           let text = livePresentation.text,
           let body = livePresentation.body {
          AIChatMessageBodyView(
            rawText: body.displayedText,
            rendersStructuredOrg2: true,
            structuredPresentation: body.org
          )
          .accessibilityIdentifier("openclaw-live-presentation-ready")
          .background {
            AIChatMessageAccessibilityMarker(
              identifier: "openclaw-live-presentation-ready",
              label: "Live response presentation ready"
            )
          }

          if text.hasEarlierText {
            Button {
              withAnimation(WorkspaceMotion.disclosure) {
                showsAllStreamingProgress.toggle()
              }
            } label: {
              Label(
                showsAllStreamingProgress ? "Show latest update" : "Show all progress",
                systemImage: showsAllStreamingProgress ? "chevron.up" : "chevron.down"
              )
            }
            .buttonStyle(.plain)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
          }
        }

        if !presentedActivityItems.isEmpty || presentedReasoning != nil {
          AIChatProgressFeedView(
            reasoning: "",
            activities: [],
            compact: compact,
            isLive: true,
            presentedItems: presentedActivityItems,
            presentedReasoning: presentedReasoning
          )
        }
      }
      .padding(10)
      .frame(maxWidth: compact ? 430 : 700, alignment: .leading)
      Spacer(minLength: compact ? 24 : 48)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: livePresentationTaskKey) {
      do {
        try await Task.sleep(for: .milliseconds(24))
      } catch {
        return
      }
      let prepared = await AIChatLiveTextPreparationCoordinator.shared.prepare(
        streamID: livePresentationStreamID,
        input: livePresentationInput
      )
      guard !Task.isCancelled else { return }
      livePresentation = prepared
    }
    .task(id: nextStatusTransition) {
      guard let nextStatusTransition else { return }
      let delay = max(0, nextStatusTransition.timeIntervalSinceNow)
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      statusEvaluationDate = Date()
    }
  }

  private var nextStatusTransition: Date? {
    guard connectionState == .connected,
          runID != nil,
          let reference = lastEventAt ?? startedAt else { return nil }
    let now = Date()
    return [Self.quietRunInterval, Self.stalledRunInterval]
      .map { reference.addingTimeInterval($0) }
      .first(where: { $0 > now })
  }

  var statusTitle: String {
    statusTitle(now: Date())
  }

  func statusTitle(now: Date) -> String {
    statusTitle(
      now: now,
      activityFeedItems: AIChatActivityFeed.items(from: activities),
      hasReasoning: hasReasoning
    )
  }

  private func statusTitle(
    now: Date,
    activityFeedItems: [AIChatActivityFeedItem],
    hasReasoning: Bool
  ) -> String {
    if connectionState == .connected, runID != nil {
      if runtime != .openCode,
         runLivenessAge(now: now) >= Self.stalledRunInterval {
        return "\(displayTitle) may be stalled"
      }
      if runLivenessAge(now: now) >= Self.quietRunInterval {
        return "Waiting for \(displayTitle)"
      }
    }
    if destinationTitle != nil {
      switch connectionState {
      case .connecting:
        return "Connecting to \(displayTitle)"
      case .reconnecting:
        return "Reconnecting to \(displayTitle)"
      case .fallbackHTTP:
        return "\(displayTitle) is working over HTTP"
      case .disconnected:
        return "\(displayTitle) connection interrupted"
      case .connected:
        if let latest = activityFeedItems.last(where: { $0.status == .running }) {
          return "Running \(latest.title.lowercased())"
        }
        if runID == nil {
          return "Starting \(displayTitle)"
        }
        if hasReasoning {
          return "\(displayTitle) is thinking"
        }
        return "\(displayTitle) is working"
      }
    }
    if runtime == .codex {
      switch connectionState {
      case .connecting:
        return "Connecting to Codex"
      case .reconnecting:
        return "Reconnecting to Codex"
      case .fallbackHTTP:
        return "Codex is working"
      case .disconnected:
        return "Codex connection interrupted"
      case .connected:
        if let latest = activityFeedItems.last(where: { $0.status == .running }) {
          return "Running \(latest.title.lowercased())"
        }
        if runID == nil {
          return "Starting Codex"
        }
        if hasReasoning {
          return "Codex is thinking"
        }
        return "Codex is working"
      }
    }
    switch connectionState {
    case .connecting:
      return "Connecting to OpenClaw"
    case .reconnecting:
      return "Reconnecting to OpenClaw"
    case .fallbackHTTP:
      return "OpenClaw is working over HTTP"
    case .disconnected:
      return "Connection interrupted"
    case .connected:
      if let latest = activityFeedItems.last(where: { $0.status == .running }) {
        return "Running \(latest.title.lowercased())"
      }
      if runID == nil {
        return "Starting OpenClaw"
      }
      if hasReasoning {
        return "OpenClaw is thinking"
      }
      return "OpenClaw is working"
    }
  }

  var canStop: Bool {
    // This view is only rendered for a locally active send. Connecting,
    // reconnecting, and disconnected recovered turns need Stop most: their
    // durable pending turn otherwise has no way to leave the recovery loop.
    true
  }

  private var displayTitle: String {
    let normalized = destinationTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalized.isEmpty ? runtime.title : normalized
  }

  private var hasReasoning: Bool {
    AIChatProgressPresentation.containsNonWhitespace(reasoning)
  }

  private var hasProgress: Bool {
    !AIChatActivityFeed.items(from: activities).isEmpty || hasReasoning
  }

  func statusDetail(now: Date) -> String? {
    switch connectionState {
    case .reconnecting:
      return normalizedConnectionDetail
        ?? "The run is saved and will reconnect without being sent twice."
    case .disconnected:
      return normalizedConnectionDetail
        ?? "The connection was interrupted; the run may still be working remotely."
    case .connected where runID != nil:
      let age = runLivenessAge(now: now)
      if age >= Self.stalledRunInterval {
        if runtime == .openCode {
          return "No new output for \(durationText(age)). OpenCode is still running; long tool calls can be quiet."
        }
        return "No new activity for \(durationText(age)). The run is saved; the connection or agent may be stalled."
      }
      if age >= Self.quietRunInterval {
        return "No new activity for \(durationText(age)). It may still be working."
      }
      return nil
    case .connecting, .connected, .fallbackHTTP:
      return nil
    }
  }

  private func statusAnimates(now: Date) -> Bool {
    guard connectionState != .disconnected else { return false }
    return connectionState != .connected
      || runID == nil
      || runtime == .openCode
      || runLivenessAge(now: now) < Self.stalledRunInterval
  }

  private var normalizedConnectionDetail: String? {
    let detail = connectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return detail.isEmpty ? nil : detail
  }

  private func runLivenessAge(now: Date) -> TimeInterval {
    guard let reference = lastEventAt ?? startedAt else { return 0 }
    return max(0, now.timeIntervalSince(reference))
  }

  private func connectionHelp(now: Date) -> String {
    var parts: [String] = []
    if let normalizedConnectionDetail { parts.append(normalizedConnectionDetail) }
    if lastEventAt != nil || startedAt != nil {
      parts.append("Last update \(durationText(runLivenessAge(now: now))) ago")
    }
    if let runID { parts.append("Run \(runID)") }
    return parts.isEmpty ? connectionState.label : parts.joined(separator: "\n")
  }

  private func durationText(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 60 * 60 { return "\(seconds / 60)m" }
    let hours = seconds / (60 * 60)
    let minutes = (seconds % (60 * 60)) / 60
    return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
  }

  private func elapsedText(now: Date) -> String {
    guard let startedAt else { return "0s" }
    let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
    if seconds < 60 { return "\(seconds)s" }
    return "\(seconds / 60)m \(seconds % 60)s"
  }
}

private struct AIChatShimmeringStatusText: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let titleProvider: (Date) -> String
  let animates: Bool

  init(
    titleProvider: @escaping (Date) -> String,
    animates: Bool = true
  ) {
    self.titleProvider = titleProvider
    self.animates = animates
  }

  var body: some View {
    HStack(spacing: 5) {
      if animates {
        CoreAnimationActivityDot(
          animates: !reduceMotion,
          colorStyle: .secondary
        )
        .frame(width: 5, height: 5)
      }

      AppKitPeriodicLabel(
        font: .systemFont(ofSize: 11, weight: .medium),
        color: .secondaryLabelColor,
        textProvider: titleProvider
      )
      .frame(minWidth: 96, idealWidth: 140, maxWidth: 180, minHeight: 14, alignment: .leading)
    }
  }
}

private struct AIChatProgressFeedView: View {
  let reasoning: String
  let activities: [AIChatRunActivity]
  let compact: Bool
  let isLive: Bool
  let presentedItems: [AIChatActivityFeedItem]?
  let reasoningHasOmittedPrefix: Bool
  let preparedReasoning: String?

  @State private var showsFullFeed = false

  init(
    reasoning: String,
    activities: [AIChatRunActivity],
    compact: Bool,
    isLive: Bool,
    presentedItems: [AIChatActivityFeedItem]? = nil,
    reasoningHasOmittedPrefix: Bool = false,
    presentedReasoning: String? = nil
  ) {
    self.reasoning = reasoning
    self.activities = activities
    self.compact = compact
    self.isLive = isLive
    self.presentedItems = presentedItems
    self.reasoningHasOmittedPrefix = reasoningHasOmittedPrefix
    preparedReasoning = presentedReasoning
  }

  private var items: [AIChatActivityFeedItem] {
    presentedItems ?? AIChatActivityFeed.items(from: activities)
  }

  private var presentedReasoning: String? {
    preparedReasoning ?? AIChatProgressPresentation.reasoningText(
      from: reasoning,
      hasOmittedPrefix: reasoningHasOmittedPrefix
    )
  }

  private var collapsedItemLimit: Int { compact ? 2 : 3 }

  private var visibleItems: [AIChatActivityFeedItem] {
    AIChatProgressFeedPresentation.visibleItems(
      items,
      isLive: isLive,
      isExpanded: showsFullFeed,
      collapsedItemLimit: collapsedItemLimit
    )
  }

  private var showsReasoning: Bool {
    AIChatProgressFeedPresentation.showsReasoning(
      isLive: isLive,
      isExpanded: showsFullFeed
    )
  }

  private var canExpand: Bool {
    AIChatProgressFeedPresentation.canExpand(
      itemCount: items.count,
      reasoningLength: presentedReasoning?.count ?? 0,
      isLive: isLive,
      collapsedItemLimit: collapsedItemLimit
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      if !isLive {
        HStack(spacing: 7) {
          Label("How it worked", systemImage: "clock.arrow.circlepath")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          if canExpand {
            expansionButton
          }
        }
      }

      if isLive, showsFullFeed, canExpand {
        expansionButton
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if showsReasoning, let presentedReasoning {
        HStack(alignment: .top, spacing: 7) {
          Image(systemName: "sparkles")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
            .frame(width: 14)
          VStack(alignment: .leading, spacing: 2) {
            Text("Approach")
              .font(.caption.weight(.medium))
            Text(presentedReasoning)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(showsFullFeed ? 8 : 2)
              .truncationMode(.tail)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !visibleItems.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(visibleItems) { item in
            AIChatActivityFeedRow(
              item: item,
              isExpanded: showsFullFeed,
              isLive: isLive
            )
          }
        }
      }

      let omittedExpandedItemCount = AIChatProgressFeedPresentation.omittedExpandedItemCount(
        itemCount: items.count,
        isExpanded: showsFullFeed
      )
      if omittedExpandedItemCount > 0 {
        Text("Showing the latest \(AIChatProgressFeedPresentation.maximumExpandedItemCount) of \(items.count) updates. Earlier updates remain in the durable run record.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      if isLive, !showsFullFeed, canExpand {
        expansionButton
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if !isLive, !showsFullFeed, items.count > collapsedItemLimit {
        Button {
          withAnimation(WorkspaceMotion.disclosure) {
            showsFullFeed = true
          }
        } label: {
          Text("Show \(items.count - collapsedItemLimit) earlier update\(items.count - collapsedItemLimit == 1 ? "" : "s")")
        }
        .buttonStyle(.plain)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tertiary)
        .help("Show the complete activity feed")
      }
    }
    .frame(maxWidth: compact ? 360 : 640, alignment: .leading)
    .clipped()
  }

  private var expansionButton: some View {
    Button {
      withAnimation(WorkspaceMotion.disclosure) {
        showsFullFeed.toggle()
      }
    } label: {
      Label(
        AIChatProgressFeedPresentation.disclosureTitle(
          isLive: isLive,
          isExpanded: showsFullFeed
        ),
        systemImage: showsFullFeed ? "chevron.down" : "chevron.right"
      )
    }
    .labelStyle(.titleAndIcon)
    .buttonStyle(.plain)
    .font(.caption2.weight(.medium))
    .foregroundStyle(.secondary)
  }
}

enum AIChatProgressFeedPresentation {
  static let maximumExpandedItemCount = 96

  static func visibleItems(
    _ items: [AIChatActivityFeedItem],
    isLive: Bool,
    isExpanded: Bool,
    collapsedItemLimit: Int
  ) -> [AIChatActivityFeedItem] {
    if isLive {
      guard !isExpanded else { return Array(items.suffix(maximumExpandedItemCount)) }
      return items.last(where: { $0.status == .running }).map { [$0] }
        ?? items.last.map { [$0] }
        ?? []
    }
    return isExpanded
      ? Array(items.suffix(maximumExpandedItemCount))
      : Array(items.suffix(collapsedItemLimit))
  }

  static func omittedExpandedItemCount(itemCount: Int, isExpanded: Bool) -> Int {
    guard isExpanded else { return 0 }
    return max(0, itemCount - maximumExpandedItemCount)
  }

  static func showsReasoning(isLive: Bool, isExpanded: Bool) -> Bool {
    !isLive || isExpanded
  }

  static func canExpand(
    itemCount: Int,
    reasoningLength: Int,
    isLive: Bool,
    collapsedItemLimit: Int
  ) -> Bool {
    if isLive {
      return itemCount > 0 || reasoningLength > 0
    }
    return itemCount > collapsedItemLimit || reasoningLength > 240
  }

  static func disclosureTitle(isLive: Bool, isExpanded: Bool) -> String {
    if isLive {
      return isExpanded ? "Hide activity" : "Show activity"
    }
    return isExpanded ? "Show less" : "Show full feed"
  }
}

private struct AIChatActivityFeedRow: View {
  let item: AIChatActivityFeedItem
  let isExpanded: Bool
  let isLive: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      activityIcon
      VStack(alignment: .leading, spacing: 2) {
        if isActive {
          HStack(spacing: 5) {
            Text(item.title)
              .font(.caption.weight(.medium))
            AppKitPeriodicLabel(
              font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
              color: .tertiaryLabelColor,
              textProvider: { "\u{00b7} \(freshnessText(now: $0))" }
            )
            .frame(minWidth: 48, idealWidth: 92, maxWidth: 112, minHeight: 14, alignment: .leading)
          }
        } else {
          Text(item.title)
            .font(.caption.weight(.medium))
        }
        if let detail = item.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(isExpanded ? 3 : 1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if isActive, let latestDetail = item.latestDetail, !latestDetail.isEmpty {
          Text(latestDetail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(isExpanded ? 3 : 2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(WorkspaceMotion.quick, value: item)
  }

  @ViewBuilder
  private var activityIcon: some View {
    if isActive {
      WorkspaceActivityIndicator(size: .mini, tint: .secondary)
        .frame(width: 14, height: 14)
        .help("This operation is still running")
    } else {
      Image(systemName: icon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 14)
    }
  }

  private var isActive: Bool {
    isLive && item.status == .running
  }

  private func freshnessText(now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(item.updatedAt)))
    if seconds < 5 { return "live" }
    if seconds < 60 { return "updated \(seconds)s ago" }
    if seconds < 60 * 60 { return "updated \(seconds / 60)m ago" }
    let hours = seconds / (60 * 60)
    return "updated \(hours)h ago"
  }

  private var icon: String {
    switch item.status {
    case .running: return "wrench.and.screwdriver"
    case .succeeded: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    }
  }
}

enum AIChatProgressPresentation {
  struct LiveTextPresentation: Equatable, Sendable {
    let text: String
    let hasEarlierText: Bool
  }

  private static let maximumReasoningLength = 1_200
  static let maximumReasoningInputUTF8ByteCount = 8 * 1_024
  static let maximumLiveNormalizationInputCharacterCount = 8 * 1_024
  private static let maximumCollapsedLiveLength = 320

  nonisolated static func liveTextPresentation(
    from raw: String,
    showsAll: Bool,
    hasOmittedPrefix: Bool = false
  ) -> LiveTextPresentation? {
    let bounded = boundedSuffix(
      raw,
      maximumCharacterCount: maximumLiveNormalizationInputCharacterCount
    )
    let readable = normalizedReadableText(bounded.text)
    guard !readable.isEmpty else { return nil }

    let paragraphs = readable.components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let latest = paragraphs.last ?? readable
    let collapsed: String
    if latest.count > maximumCollapsedLiveLength {
      collapsed = String(latest.prefix(maximumCollapsedLiveLength - 1))
        .trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    } else {
      collapsed = latest
    }
    return LiveTextPresentation(
      text: showsAll ? readable : collapsed,
      hasEarlierText: hasOmittedPrefix || bounded.wasTruncated || collapsed != readable
    )
  }

  nonisolated static func liveText(from raw: String, showsAll: Bool) -> String? {
    liveTextPresentation(from: raw, showsAll: showsAll)?.text
  }

  nonisolated static func hasEarlierLiveText(_ raw: String) -> Bool {
    liveTextPresentation(from: raw, showsAll: false)?.hasEarlierText ?? false
  }

  nonisolated static func reasoningText(
    from raw: String,
    hasOmittedPrefix: Bool = false
  ) -> String? {
    guard containsNonWhitespace(raw) else { return nil }
    let excerpt = AIChatMessageBodyExcerpt(
      raw,
      utf8ByteLimit: maximumReasoningInputUTF8ByteCount
    )
    let trimmed = excerpt.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let startsLikeStructuredPayload = trimmed.first == "{" || trimmed.first == "["
    if startsLikeStructuredPayload {
      return nil
    }
    if let data = trimmed.data(using: .utf8),
       (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
      return nil
    }

    let looksLikeEncodedPayload = trimmed.contains("\\\"content\\\"")
      || trimmed.contains("\\\"results\\\"")
      || trimmed.hasPrefix("{\\n")
      || trimmed.hasPrefix("[\\n")
    guard !looksLikeEncodedPayload else { return nil }

    let readable = normalizedReadableText(trimmed)
    guard hasOmittedPrefix
            || excerpt.isTruncated
            || readable.count > maximumReasoningLength
    else { return readable }
    return String(readable.prefix(maximumReasoningLength - 1))
      .trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
  }

  nonisolated static func containsNonWhitespace(_ raw: String) -> Bool {
    raw.contains { !$0.isWhitespace }
  }

  private nonisolated static func boundedSuffix(
    _ raw: String,
    maximumCharacterCount: Int
  ) -> (text: String, wasTruncated: Bool) {
    guard raw.count > maximumCharacterCount else { return (raw, false) }
    return (String(raw.suffix(maximumCharacterCount)), true)
  }

  private nonisolated static func normalizedReadableText(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\n[ \\t]*\\n(?:[ \\t]*\\n)+", with: "\n\n", options: .regularExpression)
  }
}
