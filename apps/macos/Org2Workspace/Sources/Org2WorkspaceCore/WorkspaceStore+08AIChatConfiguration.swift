import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  func reasoningOptions(
    for model: String?,
    runtime: AIChatRuntime
  ) -> [AIChatReasoningOption] {
    guard runtime == .codex else { return [] }
    let option = model.flatMap { selected in
      aiChatModelOptions.first(where: { $0.id == selected })
    } ?? aiChatModelOptions.first(where: \.isDefault)
    return option?.reasoningOptions ?? []
  }

  func defaultReasoningEffort(
    for model: String?,
    runtime: AIChatRuntime
  ) -> String? {
    guard runtime == .codex else { return nil }
    let option = model.flatMap { selected in
      aiChatModelOptions.first(where: { $0.id == selected })
    } ?? aiChatModelOptions.first(where: \.isDefault)
    return option?.defaultReasoningEffort
  }

  func preferredAIChatConfiguration(
    forDestinationID destinationID: String
  ) -> AIChatLastConfiguration? {
    let runtime = aiChatDestinationRuntime(destinationID)
    let storedConfigurations = storedAIChatConfigurations()
    if let stored = storedConfigurations[destinationID] {
      return stored
    }
    if destinationID == AIChatDestinationConfiguration.defaultID(for: runtime),
       let legacyStored = storedConfigurations[runtime.rawValue] {
      return legacyStored
    }
    if let destinationModel = aiChatDestination(id: destinationID)?.model {
      return AIChatLastConfiguration(model: destinationModel, reasoningEffort: nil)
    }
    let selectedThread = selectedAIChatThread.flatMap { thread in
      thread.destinationID == destinationID && (thread.model != nil || thread.reasoningEffort != nil)
        ? thread
        : nil
    }
    guard let previousThread = selectedThread ?? aiChatThreads.first(where: {
      $0.destinationID == destinationID && ($0.model != nil || $0.reasoningEffort != nil)
    }) else {
      return nil
    }
    let configuration = AIChatLastConfiguration(
      model: previousThread.model,
      reasoningEffort: previousThread.reasoningEffort
    )
    persistLastAIChatConfiguration(
      destinationID: destinationID,
      model: configuration.model,
      reasoningEffort: configuration.reasoningEffort
    )
    return configuration
  }

  @discardableResult
  func applyCachedAIChatConfiguration(
    for thread: AIChatThread
  ) -> Bool {
    guard let cached = aiChatConfigurationCatalogCache[thread.destinationID],
          !cached.models.isEmpty || cached.effectiveModel != nil || !cached.reasoningOptions.isEmpty
    else {
      return false
    }
    aiChatModelOptions = cached.models
    aiChatEffectiveModel = thread.model ?? cached.effectiveModel

    let selectedModel = thread.model.flatMap { selected in
      cached.models.first(where: { $0.id == selected })
    } ?? cached.effectiveModel.flatMap { effective in
      cached.models.first(where: { $0.id == effective })
    } ?? cached.models.first(where: \.isDefault)
    if thread.runtime == .codex {
      aiChatReasoningOptions = selectedModel?.reasoningOptions ?? cached.reasoningOptions
      aiChatDefaultReasoningEffort = selectedModel?.defaultReasoningEffort
        ?? cached.defaultReasoningEffort
    } else if thread.runtime == .openClaw, cached.requestedModel == thread.model {
      aiChatReasoningOptions = cached.reasoningOptions
      aiChatDefaultReasoningEffort = cached.defaultReasoningEffort
    } else {
      aiChatReasoningOptions = []
      aiChatDefaultReasoningEffort = nil
    }
    return true
  }

  func cacheAIChatConfiguration(
    destinationID: String,
    requestedModel: String?,
    models: [AIChatModelOption],
    effectiveModel: String?,
    reasoningOptions: [AIChatReasoningOption],
    defaultReasoningEffort: String?
  ) {
    guard !models.isEmpty || effectiveModel != nil || !reasoningOptions.isEmpty else { return }
    let entry = AIChatConfigurationCatalogCacheEntry(
      requestedModel: requestedModel,
      models: models,
      effectiveModel: effectiveModel,
      reasoningOptions: reasoningOptions,
      defaultReasoningEffort: defaultReasoningEffort
    )
    guard aiChatConfigurationCatalogCache[destinationID] != entry else { return }
    aiChatConfigurationCatalogCache[destinationID] = entry
    persistAIChatConfigurationCatalogCache()
  }

  func cacheAIChatModelCatalog(
    destinationID: String,
    models: [AIChatModelOption]
  ) {
    guard !models.isEmpty else { return }
    let existing = aiChatConfigurationCatalogCache[destinationID]
    cacheAIChatConfiguration(
      destinationID: destinationID,
      requestedModel: existing?.requestedModel,
      models: models,
      effectiveModel: existing?.effectiveModel ?? aiChatDestination(id: destinationID)?.model,
      reasoningOptions: existing?.reasoningOptions ?? [],
      defaultReasoningEffort: existing?.defaultReasoningEffort
    )
  }

  func cachedAutomationModelOptions(
    forDestinationID destinationID: String
  ) -> [AIChatModelOption] {
    if let models = aiChatConfigurationCatalogCache[destinationID]?.models,
       !models.isEmpty {
      return models
    }
    guard let model = aiChatDestination(id: destinationID)?.model else { return [] }
    return [AIChatModelOption(id: model, label: model, isDefault: true)]
  }

  func refreshAutomationModelOptions(
    forDestinationID destinationID: String
  ) async throws -> [AIChatModelOption] {
    let models = try await modelsForAIChatDestination(destinationID)
    cacheAIChatModelCatalog(destinationID: destinationID, models: models)
    return models
  }

  func cacheAIChatConfigurationForTesting(
    destinationID: String,
    requestedModel: String? = nil,
    models: [AIChatModelOption],
    effectiveModel: String?,
    reasoningOptions: [AIChatReasoningOption],
    defaultReasoningEffort: String?
  ) {
    cacheAIChatConfiguration(
      destinationID: destinationID,
      requestedModel: requestedModel,
      models: models,
      effectiveModel: effectiveModel,
      reasoningOptions: reasoningOptions,
      defaultReasoningEffort: defaultReasoningEffort
    )
  }

  func removeCachedAIChatConfiguration(destinationID: String) {
    guard aiChatConfigurationCatalogCache.removeValue(forKey: destinationID) != nil else { return }
    persistAIChatConfigurationCatalogCache()
  }

  private func persistAIChatConfigurationCatalogCache() {
    guard !Self.shouldIgnoreStandardDefaultsForTests(defaults),
          let data = try? JSONEncoder().encode(aiChatConfigurationCatalogCache)
    else { return }
    defaults.set(data, forKey: aiChatConfigurationCatalogCacheKey)
  }

  static func restoreAIChatConfigurationCatalogCache(
    from defaults: UserDefaults,
    key: String
  ) -> [String: AIChatConfigurationCatalogCacheEntry] {
    guard !shouldIgnoreStandardDefaultsForTests(defaults),
          let data = defaults.data(forKey: key),
          let cache = try? JSONDecoder().decode(
            [String: AIChatConfigurationCatalogCacheEntry].self,
            from: data
          )
    else {
      return [:]
    }
    return cache
  }

  private func storedAIChatConfigurations() -> [String: AIChatLastConfiguration] {
    guard !Self.shouldIgnoreStandardDefaultsForTests(defaults),
          let data = defaults.data(forKey: aiChatLastConfigurationsKey),
          let configurations = try? JSONDecoder().decode(
            [String: AIChatLastConfiguration].self,
            from: data
          )
    else {
      return [:]
    }
    return configurations
  }

  func persistLastAIChatConfiguration(
    destinationID: String,
    model: String?,
    reasoningEffort: String?
  ) {
    guard !Self.shouldIgnoreStandardDefaultsForTests(defaults) else { return }
    var configurations = storedAIChatConfigurations()
    configurations[destinationID] = AIChatLastConfiguration(
      model: model,
      reasoningEffort: reasoningEffort
    )
    guard let data = try? JSONEncoder().encode(configurations) else { return }
    defaults.set(data, forKey: aiChatLastConfigurationsKey)
  }

  nonisolated static func aiChatReasoningLabel(_ value: String) -> String {
    switch value.lowercased() {
    case "off", "none": return "Off"
    case "minimal": return "Minimal"
    case "low": return "Low"
    case "medium": return "Medium"
    case "high": return "High"
    case "xhigh": return "Extra high"
    case "max": return "Maximum"
    case "ultra": return "Ultra"
    case "adaptive": return "Adaptive"
    default: return value.capitalized
    }
  }

  public func createAIChatThread() {
    createAIChatThread(destinationID: selectedAIChatDestination.id)
  }

  public func createAIChatSharedRoom() {
    createAIChatThread(
      title: "Shared AI Room",
      statusText: "Shared room ready · @mention an agent to request a response",
      runtime: .openClaw,
      isSharedRoom: true,
      roomAudience: .thread,
      defersPersistence: true
    )
  }

  func rebuildExternalThreadDisplayCache() {
    let query = externalThreadSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else {
      filteredExternalThreads = externalThreads
      return
    }
    filteredExternalThreads = externalThreads.filter { thread in
      [thread.title, thread.preview, thread.workspacePath, thread.source]
        .compactMap { $0?.lowercased() }
        .contains { $0.contains(query) }
    }
  }

  public func openExternalThreads() {
    makeSurfacePrimary(.externalThreads)
  }

  public func refreshExternalThreads() async {
    let requestID = UUID()
    let searchQuery = externalThreadSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    externalThreadRefreshRequestID = requestID
    isRefreshingExternalThreads = true
    externalThreadError = nil
    defer {
      if externalThreadRefreshRequestID == requestID {
        externalThreadRefreshRequestID = nil
        isRefreshingExternalThreads = false
      }
    }
    do {
      let summaries = try await externalThreadSummaries(searchQuery: searchQuery)
      guard externalThreadRefreshRequestID == requestID,
            externalThreadSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == searchQuery
      else { return }
      externalThreads = summaries
      if let selectedExternalThreadID,
         !externalThreads.contains(where: { $0.id == selectedExternalThreadID }) {
        self.selectedExternalThreadID = nil
        selectedExternalThreadDetail = nil
      }
    } catch is CancellationError {
      return
    } catch {
      guard externalThreadRefreshRequestID == requestID else { return }
      externalThreadError = error.localizedDescription
    }
  }

  public func updateExternalThreadSearchQuery(_ searchQuery: String) async {
    externalThreadSearchQuery = searchQuery
    await refreshExternalThreads()
  }

  public func externalThreadSummaries(
    searchQuery: String = ""
  ) async throws -> [ExternalThreadSummary] {
    let localCodexThreadIDs = Set(aiChatThreads.compactMap { thread in
      thread.runtime == .codex || thread.isSharedRoom ? thread.runtimeThreadID : nil
    })
    let normalizedSearchQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let summaries: [ExternalThreadSummary]
    if normalizedSearchQuery.isEmpty {
      summaries = try await externalCodexClient().listExternalThreads(limit: 100)
    } else {
      summaries = try await externalCodexClient().searchExternalThreads(
        normalizedSearchQuery,
        limit: 100
      )
    }
    let filteredSummaries = summaries.filter {
      !localCodexThreadIDs.contains($0.externalID)
    }
    let summariesByID = Dictionary(uniqueKeysWithValues: filteredSummaries.map { ($0.id, $0) })
    externalThreadDetailCache = externalThreadDetailCache.filter { id, detail in
      summariesByID[id]?.updatedAt == detail.thread.updatedAt
    }
    externalThreadDetailCacheOrder.removeAll { externalThreadDetailCache[$0] == nil }
    return filteredSummaries
  }

  public func selectExternalThread(_ id: String) async {
    guard let summary = externalThreads.first(where: { $0.id == id }) else { return }
    selectedExternalThreadID = id
    selectedExternalThreadDetail = nil
    await loadExternalThread(harness: summary.harness, externalID: summary.externalID)
  }

  public func loadExternalThread(
    harness: ExternalThreadHarness,
    externalID: String
  ) async {
    let requestID = UUID()
    externalThreadLoadRequestID = requestID
    isLoadingExternalThread = true
    externalThreadError = nil
    defer {
      if externalThreadLoadRequestID == requestID {
        externalThreadLoadRequestID = nil
        isLoadingExternalThread = false
      }
    }
    do {
      let detail = try await externalThreadDetail(harness: harness, externalID: externalID)
      guard externalThreadLoadRequestID == requestID,
            selectedExternalThreadID == detail.thread.id
      else { return }
      selectedExternalThreadDetail = detail
    } catch {
      if externalThreadLoadRequestID == requestID {
        externalThreadError = error.localizedDescription
      }
    }
  }

  public func reportExternalThreadActionError(_ error: Error) {
    externalThreadError = error.localizedDescription
    statusText = "External thread action failed"
  }

  public func externalThreadDetail(
    harness: ExternalThreadHarness,
    externalID: String
  ) async throws -> ExternalThreadDetail {
    let cacheID = "\(harness.rawValue):\(externalID)"
    if let cached = externalThreadDetailCache[cacheID] {
      touchExternalThreadDetailCache(cacheID)
      return cached
    }
    let detail: ExternalThreadDetail
    switch harness {
    case .codex:
      detail = try await externalCodexClient().readExternalThread(externalID)
    }
    externalThreadDetailCache[cacheID] = detail
    touchExternalThreadDetailCache(cacheID)
    while externalThreadDetailCacheOrder.count > Self.externalThreadDetailCacheLimit {
      externalThreadDetailCache.removeValue(forKey: externalThreadDetailCacheOrder.removeFirst())
    }
    return detail
  }

  private func touchExternalThreadDetailCache(_ id: String) {
    externalThreadDetailCacheOrder.removeAll { $0 == id }
    externalThreadDetailCacheOrder.append(id)
  }

  @discardableResult
  public func saveExternalThreadToOrg2(
    _ detail: ExternalThreadDetail,
    opensDocument: Bool = true
  ) async throws -> URL {
    guard let corpusRoot else {
      throw CodexAppServerError.invalidResponse("Open a Celorga corpus before importing a thread")
    }
    let relativePath = Self.externalThreadSnapshotRelativePath(detail.thread)
    let destination = corpusRoot.appendingPathComponent(relativePath).standardizedFileURL
    guard let context = captureDocumentCorpusContext(forFile: destination.path) else {
      throw WorkspaceDocumentMutationError.outsideCorpus(
        file: destination.path,
        root: corpusRoot.path
      )
    }
    let parent = destination.deletingLastPathComponent()
    let content = await Task.detached(priority: .userInitiated) {
      Self.externalThreadSnapshotText(detail)
    }.value
    try await performDocumentMutation(
      context: context,
      files: [destination.path, parent.path]
    ) { execution in
      let authorizedParent = try execution.authorizeDescendant(parent, ofDeclaredDirectory: parent)
      try FileManager.default.createDirectory(
        at: authorizedParent,
        withIntermediateDirectories: true
      )
      let snapshot = try await execution.readSnapshot(at: destination, allowMissing: true)
      guard content != snapshot.text else { return }
      try await execution.commit(content, over: snapshot) { text, url, previous in
        try Self.commitDocumentText(
          text,
          url: url,
          previousText: previous,
          operation: "external thread snapshot"
        )
      }
    }
    guard isCurrentDocumentCorpusContext(context) else { return destination }
    invalidateCanonicalDocumentCache(for: destination.path)
    if opensDocument {
      openFile(path: destination.path, line: 1)
      statusText = "Saved external thread to \(relativePath)"
    }
    Task { @MainActor [weak self] in
      await self?.refreshCorpusFiles()
    }
    return destination
  }

  @discardableResult
  public func continueExternalThreadInOrg2(
    _ detail: ExternalThreadDetail,
    selectsThread: Bool = true
  ) async throws -> UUID {
    let snapshotURL = try await saveExternalThreadToOrg2(detail, opensDocument: false)
    let relativePath = relativePath(snapshotURL.path)
    let title = Self.normalizedAIChatThreadTitle("Continue: \(detail.thread.title)")
    let thread = createAIChatThread(
      title: title,
      statusText: "External thread ready to continue",
      runtime: .codex,
      selectsThread: selectsThread
    )
    let reference = "\(mappedPathForOpenClaw(snapshotURL.path)):1"
    let draft = AIChatContextPresentation.automaticContext(
      kind: "external \(detail.thread.harness.title) thread",
      title: detail.thread.title,
      reference: reference,
      prompt: "Continue the conversation using the imported read-only transcript as context."
    )
    cacheAIChatDraft(draft, for: thread.id)
    if selectsThread {
      publishAIChatComposerDraft(draft)
      makeSurfacePrimary(.aiChat)
      aiChatStatusText = "Imported \(relativePath) as read-only context"
      statusText = "Started a new Celorga thread from \(detail.thread.harness.title)"
    }
    return thread.id
  }

  nonisolated static func externalThreadSnapshotRelativePath(
    _ thread: ExternalThreadSummary
  ) -> String {
    let base = thread.title.lowercased().unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    let slug = String(base)
      .split(separator: "-", omittingEmptySubsequences: true)
      .prefix(10)
      .joined(separator: "-")
    let identifier = thread.externalID.prefix(12)
    return "views/external-threads/\(slug.isEmpty ? "thread" : slug)-\(identifier).org"
  }

  nonisolated static func externalThreadSnapshotText(_ detail: ExternalThreadDetail) -> String {
    let formatter = ISO8601DateFormatter()
    let thread = detail.thread
    var lines = [
      "* External thread: \(thread.title)",
      ":PROPERTIES:",
      ":ID: external-thread-\(thread.harness.rawValue)-\(thread.externalID)",
      ":KIND: external-thread",
      ":EXTERNAL_HARNESS: \(thread.harness.rawValue)",
      ":EXTERNAL_THREAD_ID: \(thread.externalID)",
      ":EXTERNAL_UPDATED_AT: \(formatter.string(from: thread.updatedAt))",
      ":IMPORTED_AT: \(formatter.string(from: Date()))",
      ":END:",
      "",
      "This is a read-only snapshot imported from \(thread.harness.title). The external task remains the source of truth.",
      ""
    ]
    if let workspacePath = thread.workspacePath {
      lines.append("Workspace: =\(workspacePath)=")
      lines.append("")
    }
    lines.append("** Conversation")
    for message in detail.messages {
      lines.append("")
      lines.append("*** \(message.role == .user ? "You" : thread.harness.title)")
      lines.append(":PROPERTIES:")
      lines.append(":MESSAGE_ID: \(message.id)")
      lines.append(":CREATED_AT: \(formatter.string(from: message.createdAt))")
      lines.append(":END:")
      lines.append(contentsOf: message.content.split(separator: "\n", omittingEmptySubsequences: false).map {
        ": \($0)"
      })
    }
    return lines.joined(separator: "\n") + "\n"
  }

  public func stopAIChatRun() async {
    guard let threadID = selectedAIChatThreadID else { return }
    _ = await stopAIChatRemoteRun(threadID: threadID)
  }

  @discardableResult
  public func stopAIChatRemoteRun(threadID: UUID) async -> Bool {
    // Captured first: a stop can drop these from the queue before they are
    // resolved, and they may never have been queued in this process.
    let untrackedSendIDs = untrackedAIChatSendIDs(in: threadID)
    let stopped = await stopTrackedAIChatRun(threadID: threadID)
    if stopped {
      releaseUntrackedAIChatSends(untrackedSendIDs, in: threadID)
    }
    return stopped
  }

  /// Persisted `sending` messages that keep the chat busy but that no task in
  /// this process drives and no fresh host reports: a lost delivery
  /// confirmation, a send from an earlier process, or an agent hand-off.
  private func untrackedAIChatSendIDs(in threadID: UUID) -> Set<UUID> {
    guard isAIChatRuntimeStateVisible(for: threadID),
          let thread = aiChatThreads.first(where: { $0.id == threadID })
    else { return [] }
    let activeMessageID = activeAIChatUserMessageIDByThreadID[threadID]
    return Set(thread.messages.lazy.filter { message in
      message.role == .user
        && message.deliveryStatus == .sending
        && message.id != activeMessageID
        && self.isAIChatMessageActiveOnRemoteHost(message, in: threadID) != true
    }.map(\.id))
  }

  /// Stopping a turn also releases sends the stop itself could not reach.
  /// Their uncertainty fence is cleared as well: a stopped attempt left
  /// `.unconfirmed` is restored to the head of the queue on the next load and
  /// holds every later message behind it again. A retry of a managed remote
  /// attempt still reconciles it rather than submitting a second turn.
  private func releaseUntrackedAIChatSends(_ messageIDs: Set<UUID>, in threadID: UUID) {
    guard !messageIDs.isEmpty else { return }
    let stoppedSendFailureText = aiChatStoppedSendFailureText(for: threadID)
    var messages = aiChatMessages(for: threadID)
    var changed = false
    for index in messages.indices where messageIDs.contains(messages[index].id) {
      let message = messages[index]
      guard message.role == .user,
            message.deliveryStatus == .sending || message.deliveryIsUnconfirmed
      else { continue }
      messages[index] = message.replacingDeliveryAttempt(
        message.effectiveDeliveryAttemptID ?? message.id,
        status: message.deliveryStatus == .sending ? .interrupted : message.deliveryStatus,
        sendFailure: message.deliveryStatus == .sending
          ? stoppedSendFailureText
          : message.sendFailure,
        attemptState: nil
      )
      changed = true
    }
    guard changed else { return }
    aiChatForeignPendingMessageIDs.subtract(messageIDs)
    aiChatDispatchedUserMessageIDs.subtract(messageIDs)
    updateAIChatThread(threadID, messages: messages, shouldPersist: true)
    if var pending = aiChatPendingUserMessageIDsByThreadID[threadID] {
      pending.removeAll { messageIDs.contains($0) }
      if pending.isEmpty {
        aiChatPendingUserMessageIDsByThreadID.removeValue(forKey: threadID)
      } else {
        aiChatPendingUserMessageIDsByThreadID[threadID] = pending
      }
    }
    syncSelectedAIChatSendState()
  }

  private func stopTrackedAIChatRun(threadID: UUID) async -> Bool {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else {
      return false
    }
    if !isAIChatThreadRunningOnCurrentHost(threadID),
       let remote = aiChatRemoteLiveTurn(for: threadID) {
      // The provider run belongs to another host's process; stopping it here
      // would only desynchronize this copy of the conversation.
      if selectedAIChatThreadID == threadID {
        aiChatStatusText = "This turn is running on \(remote.host.name); stop it there"
      }
      return false
    }
    // A room with nothing in flight here has no active destination; the
    // persisted send that keeps it busy names the agent being waited on.
    let untrackedRoomDestinationID = thread.isSharedRoom
      && activeSharedRoomDestinationByThreadID[threadID] == nil
      && codexActiveTurnsByThreadID[threadID] == nil
      ? aiChatBlockingSend(in: threadID)?.targetDestinationID
      : nil
    let activeDestinationID = activeSharedRoomDestinationByThreadID[threadID]
      ?? untrackedRoomDestinationID
      ?? thread.destinationID
    // Direct providers and dots run as one local request; stopping cancels it.
    if let activeAdapter = aiChatDestination(id: activeDestinationID)?.adapter,
       activeAdapter.isDirectProvider || activeAdapter == .openAIDot {
      guard isAIChatThreadRunning(threadID) else {
        if selectedAIChatThreadID == threadID {
          aiChatStatusText = "No active \(aiChatDestinationTitle(activeDestinationID)) request to stop"
        }
        return false
      }
      markAIChatRunStopped(
        in: threadID,
        statusText: "\(aiChatDestinationTitle(activeDestinationID)) stopped"
      )
      aiChatDrainTasksByThreadID[threadID]?.task.cancel()
      return true
    }
    let activeRuntime = thread.isSharedRoom
      ? (activeSharedRoomDestinationByThreadID[threadID].map(aiChatDestinationRuntime)
          ?? (codexActiveTurnsByThreadID[threadID] != nil ? AIChatRuntime.codex : nil)
          ?? untrackedRoomDestinationID.map(aiChatDestinationRuntime)
          ?? .openClaw)
      : thread.runtime
    if activeRuntime == .codex {
      let destinationName = aiChatDestinationTitle(activeDestinationID)
      guard let active = codexActiveTurnsByThreadID[threadID],
            let codexClient = try? codexClient(forDestinationID: activeDestinationID)
      else {
        guard isAIChatThreadRunning(threadID) else {
          if selectedAIChatThreadID == threadID {
            aiChatStatusText = "No active \(destinationName) request to stop"
          }
          return false
        }
        // Codex may still be connecting, authenticating, or creating its
        // runtime thread. Those phases do not have a turn ID yet, but they
        // are still user-cancellable work. Cancel the local drain task; the
        // app-server request cancellation handler releases the pending RPC.
        markAIChatRunStopped(
          in: threadID,
          statusText: "\(destinationName) stopped"
        )
        aiChatDrainTasksByThreadID[threadID]?.task.cancel()
        return true
      }
      do {
        if thread.isSharedRoom {
          markAIChatRunStopped(in: threadID)
        }
        try await codexClient.interrupt(
          threadID: active.runtimeThreadID,
          turnID: active.turnID
        )
        if selectedAIChatThreadID == threadID {
          aiChatStatusText = thread.isSharedRoom ? "Shared room stopped" : "Stopping Codex…"
        }
        return true
      } catch {
        if Self.codexRuntimeThreadWasStale(after: error) {
          forgetCodexRuntimeThread(
            active.runtimeThreadID,
            destinationID: activeDestinationID,
            in: threadID
          )
          markStaleCodexRunExpired(
            in: threadID,
            destinationID: activeDestinationID,
            statusText: "\(destinationName) task expired; retry or send a new message to continue"
          )
          return true
        }
        if selectedAIChatThreadID == threadID {
          aiChatStatusText = "Could not stop Codex: \(error.localizedDescription)"
        }
        return false
      }
    }
    if activeRuntime == .claude {
      guard isAIChatThreadRunning(threadID) else {
        if selectedAIChatThreadID == threadID {
          aiChatStatusText = "No active Claude Code request to stop"
        }
        return false
      }
      markAIChatRunStopped(
        in: threadID,
        statusText: thread.isSharedRoom ? "Shared room stopped" : "Claude Code stopped"
      )
      await claudeCodeClient?.interrupt(openOrgThreadID: threadID)
      aiChatDrainTasksByThreadID[threadID]?.task.cancel()
      return true
    }
    if activeRuntime == .pi {
      guard isAIChatThreadRunning(threadID) else {
        if selectedAIChatThreadID == threadID {
          aiChatStatusText = "No active Pi request to stop"
        }
        return false
      }
      markAIChatRunStopped(
        in: threadID,
        statusText: thread.isSharedRoom ? "Shared room stopped" : "Pi stopped"
      )
      await piAgentClientsByDestinationID[activeDestinationID]?.interrupt(
        openOrgThreadID: threadID
      )
      aiChatDrainTasksByThreadID[threadID]?.task.cancel()
      return true
    }
    if activeRuntime == .openCode {
      guard isAIChatThreadRunning(threadID) else {
        if selectedAIChatThreadID == threadID {
          aiChatStatusText = "No active OpenCode request to stop"
        }
        return false
      }
      markAIChatRunStopped(
        in: threadID,
        statusText: thread.isSharedRoom ? "Shared room stopped" : "OpenCode stopped"
      )
      // After a restart the client may not exist yet, but a managed remote
      // host can still be running this chat's detached turn.
      await (try? openCodeClient(forDestinationID: activeDestinationID))?.interrupt(
        openOrgThreadID: threadID
      )
      aiChatDrainTasksByThreadID[threadID]?.task.cancel()
      return true
    }
    guard let gateway = openClawGatewayClientsByThreadID[threadID] else {
      // A recovered run spends time between Gateway connections while its
      // pending turn remains durable. That is still an active run from the
      // user's perspective, and clearing the pending turn is what prevents
      // the recovery loop from immediately resurrecting it.
      guard isAIChatThreadRunning(threadID) else {
        if selectedAIChatThreadID == threadID {
          aiChatStatusText = "No active OpenClaw run to stop"
        }
        return false
      }
      if let ownerID = thread.pendingTurn?.dispatchOwnerID,
         ownerID != Self.aiChatDispatchOwnerID {
        if selectedAIChatThreadID == threadID {
          aiChatStatusText = "This OpenClaw run is active on another host"
        }
        return false
      }
      markAIChatRunStopped(in: threadID)
      return true
    }
    // Make the stop durable before waiting on the Gateway. In particular, a
    // recovered turn keeps a persisted pending-turn record; leaving it in
    // place lets the recovery loop interpret the socket close as a transient
    // disconnect and resurrect the run a few seconds later.
    markAIChatRunStopped(in: threadID)
    do {
      try await gateway.abort()
      if selectedAIChatThreadID == threadID {
        aiChatStatusText = thread.isSharedRoom ? "Shared room stopped" : "OpenClaw stopped"
      }
      return true
    } catch {
      if selectedAIChatThreadID == threadID {
        aiChatStatusText = "Stopped locally; Gateway abort failed: \(error.localizedDescription)"
      }
      return false
    }
  }

  @discardableResult
  public func sendAIChatRemoteMessage(
    _ rawText: String,
    attachments: [AIChatAttachment] = [],
    threadID: UUID,
    delivery: AIChatMessageDeliveryPreference = .automatic,
    origin: AIChatMessageProvenance? = nil
  ) -> Bool {
    sendAIChatRemoteMessageDestination(
      rawText,
      attachments: attachments,
      threadID: threadID,
      delivery: delivery,
      origin: origin
    ) != nil
  }

  @discardableResult
  public func sendAIChatRemoteMessageDestination(
    _ rawText: String,
    attachments: [AIChatAttachment] = [],
    threadID: UUID,
    delivery: AIChatMessageDeliveryPreference = .automatic,
    origin: AIChatMessageProvenance? = nil
  ) -> UUID? {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !attachments.isEmpty,
          let thread = aiChatThreads.first(where: { $0.id == threadID }),
          !thread.isSettled
    else {
      return nil
    }
    let destinationThreadID = unloadedAIChatThreadIDs.contains(threadID)
      ? threadID
      : aiChatDestinationThreadID(
          for: text,
          sourceThreadID: threadID,
          selectsFork: false
        )
    let result = submitAIChatMessage(
      text,
      attachments: attachments,
      in: destinationThreadID,
      workspaceContext: threadScopedAIChatWorkspaceContext(
        for: aiChatThreads.first(where: { $0.id == destinationThreadID }) ?? thread
      ),
      delivery: delivery,
      context: captureAIChatCorpusContext(),
      origin: origin
    )
    if case .rejected = result {
      return nil
    }
    return destinationThreadID
  }

  func scheduleAIChatInboxDrain() {
    guard !isPreparingForTermination else { return }
    Task { @MainActor [weak self] in await self?.drainAIChatInbox() }
  }

  func drainAIChatInbox() async {
    guard !isPreparingForTermination else { return }
    if let existing = aiChatInboxDrainTask {
      aiChatInboxDrainRequested = true
      await existing.task.value
      return
    }
    let token = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      repeat {
        self.aiChatInboxDrainRequested = false
        await self.performAIChatInboxDrain()
      } while self.aiChatInboxDrainRequested
    }
    aiChatInboxDrainTask = (token, task)
    await task.value
    if aiChatInboxDrainTask?.token == token { aiChatInboxDrainTask = nil }
  }

  private func performAIChatInboxDrain() async {
    let context = captureAIChatCorpusContext()
    if let aiChatTranscriptLoadTask { await aiChatTranscriptLoadTask.value }
    guard isCurrentAIChatCorpusContext(context),
          let corpusRoot,
          corpusRoot.standardizedFileURL.path == context.corpusRootPath
    else { return }
    await performAIChatOperationJournalDrain(corpusRoot: corpusRoot, context: context)
    guard isCurrentAIChatCorpusContext(context) else { return }
    await refreshSecretRequests()
    guard isCurrentAIChatCorpusContext(context) else { return }
    let directory = Self.aiChatInboxDirectory(corpusRoot: corpusRoot)
    let loads = await Task.detached(priority: .utility) {
      Self.loadAIChatInboxFiles(in: directory)
    }.value
    guard isCurrentAIChatCorpusContext(context) else { return }

    for load in loads {
      guard isCurrentAIChatCorpusContext(context) else { return }
      guard load.errorDescription == nil, let envelope = load.envelope else {
        errorText = "AI chat background delivery failed: \(load.errorDescription ?? "Invalid inbox envelope")"
        continue
      }
      let content = envelope.content.trimmingCharacters(in: .whitespacesAndNewlines)
      let authorLabel = envelope.authorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let thread = await hydrateAIChatThreadIfNeeded(envelope.threadID) else {
        guard isCurrentAIChatCorpusContext(context) else { return }
        errorText = "AI chat background delivery failed: thread \(envelope.threadID) no longer exists."
        continue
      }
      guard isCurrentAIChatCorpusContext(context) else { return }

      if envelope.isSingleAgentSend {
        if let origin = aiChatSendOriginsByThreadID[thread.id],
           !aiChatSendOrigin(origin, belongsTo: context) {
          errorText = "AI chat send retained: another corpus owns this thread's active send queue."
          continue
        }
        if let existing = thread.messages.first(where: { $0.id == envelope.id }) {
          guard existing.role == .user, existing.content == content,
                existing.targetDestinationID == envelope.destinationID,
                existing.provenance?.requestedByLabel == authorLabel
          else {
            errorText = "AI chat send retained: message ID already belongs to a different delivery."
            continue
          }
        } else {
          guard !thread.isSharedRoom, thread.destinationID == envelope.destinationID,
                let destination = aiChatDestination(id: thread.destinationID),
                destination.isEnabled, destination.runtime == thread.runtime
          else {
            errorText = "AI chat send retained: single-agent destination is unavailable or changed. Enable the original destination in Celorga; shared rooms use thread post --request-turn."
            continue
          }
          if thread.isSettled { reopenAIChatThread(thread.id) }
          let queued = enqueueAIChatMessage(
            content,
            attachments: [],
            in: thread.id,
            deliveryKind: isAIChatThreadRunning(thread.id) ? .followUp : .turn,
            context: context,
            origin: AIChatMessageProvenance(
              originClient: .inbox,
              requestedByLabel: authorLabel,
              requestedByMessageID: envelope.id
            ),
            messageID: envelope.id,
            enqueueForDispatch: false
          )
          guard case .enqueued = queued else {
            errorText = "AI chat send retained: this host could not accept the send queue entry."
            continue
          }
        }
        // Persist the user send before consuming its recovery envelope or
        // starting the existing runtime queue. A retry reuses this message ID.
        guard await persistAIChatTranscriptDurably(context: context) else { continue }
        guard isCurrentAIChatCorpusContext(context) else { return }
        do {
          try FileManager.default.removeItem(at: load.file)
        } catch {
          errorText = "AI chat send retained: \(error.localizedDescription)"
          continue
        }
        if let accepted = aiChatMessages(for: thread.id).first(where: { $0.id == envelope.id }),
           accepted.deliveryStatus == .sending,
           accepted.provenance?.executionHostRef == aiChatHostIdentity.ref,
           !aiChatForeignPendingMessageIDs.contains(envelope.id),
           !aiChatDispatchedUserMessageIDs.contains(envelope.id),
           !aiChatPendingUserMessageIDs(for: thread.id).contains(envelope.id) {
          enqueueAIChatUserMessage(envelope.id, in: thread.id)
        }
        if aiChatPendingUserMessageIDs(for: thread.id).contains(envelope.id),
           !drainingAIChatThreadIDs.contains(thread.id),
           thread.pendingTurn?.dispatchOwnerID == nil
             || thread.pendingTurn?.dispatchOwnerID == Self.aiChatDispatchOwnerID {
          Task { @MainActor [weak self] in await self?.drainAIChatSendQueue(for: thread.id) }
        }
        continue
      }

      if !thread.messages.contains(where: { $0.id == envelope.id }) {
        if thread.isSettled { reopenAIChatThread(thread.id) }
        let message = AIChatMessage(
          id: envelope.id,
          role: .assistant,
          content: content,
          createdAt: Self.aiChatInboxDate(envelope.createdAt) ?? Date(),
          authorRuntime: thread.runtime,
          authorLabel: authorLabel,
          authorAgentRef: envelope.authorAgentRef,
          source: envelope.source,
          provenance: AIChatMessageProvenance(
            originClient: .inbox,
            receivedByHostRef: aiChatHostIdentity.ref,
            receivedByHostName: aiChatHostIdentity.name
          )
        )
        let current = aiChatThreads.first(where: { $0.id == envelope.threadID }) ?? thread
        var messages = (current.messages + [message]).sorted {
          if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
          return $0.id.uuidString < $1.id.uuidString
        }
        var requestedDispatchIDs: [UUID] = []
        if let tokens = envelope.requestedResponders, !tokens.isEmpty {
          if current.isSharedRoom,
             canRequestAIChatAgentTurns(in: current.id, transcriptURL: aiChatTranscriptURL) {
            let requested = appendingAIChatAgentTurnRequests(
              to: messages,
              in: current,
              from: message,
              requesterLabel: authorLabel,
              requesterDestinationID: nil,
              responderTokens: tokens
            )
            messages = requested.messages
            requestedDispatchIDs = requested.dispatchIDs
          } else if !current.isSharedRoom {
            messages.append(AIChatMessage(
              role: .system,
              content: "\(authorLabel) asked for a turn, but only shared rooms accept agent turn requests.",
              createdAt: message.createdAt
            ))
          }
        }
        updateAIChatThread(
          current.id,
          messages: messages,
          notifiesForNewAssistantMessages: true,
          shouldPersist: false
        )
        enqueueAIChatAgentTurnRequests(requestedDispatchIDs, in: current.id)
      }

      // Delete the envelope only after this exact state generation reaches
      // the marker commit. Coalescing to a newer generation is also safe.
      guard await persistAIChatTranscriptDurably(context: context) else {
        guard isCurrentAIChatCorpusContext(context) else { return }
        continue
      }
      guard isCurrentAIChatCorpusContext(context) else { return }
      do {
        try FileManager.default.removeItem(at: load.file)
        if !thread.messages.contains(where: { $0.id == envelope.id }) {
          aiChatStatusText = "Background message from \(authorLabel)"
        }
      } catch {
        guard isCurrentAIChatCorpusContext(context) else { return }
        errorText = "AI chat background delivery failed: \(error.localizedDescription)"
      }
    }
  }

  private func performAIChatOperationJournalDrain(
    corpusRoot: URL,
    context: AIChatCorpusContextToken
  ) async {
    guard isCurrentAIChatCorpusContext(context) else { return }
    let scan: AIChatOperationJournalScan
    do {
      scan = try await AIChatOperationJournal.load(corpusRoot: corpusRoot)
    } catch {
      guard isCurrentAIChatCorpusContext(context) else { return }
      errorText = "AI chat operation journal failed: \(error.localizedDescription)"
      return
    }
    guard isCurrentAIChatCorpusContext(context) else { return }

    var retainedReasons = scan.issues.map {
      "\($0.fileURL.lastPathComponent): \($0.message)"
    }
    for (index, entry) in scan.entries.enumerated() {
      guard isCurrentAIChatCorpusContext(context) else { return }
      do {
        try applyAIChatOperation(entry.operation)
      } catch {
        retainedReasons.append("\(entry.fileURL.lastPathComponent): \(error.localizedDescription)")
        continue
      }

      // The operation file is the recovery source until the exact transcript
      // and settlement-settings generation reaches the marker commit. An
      // idempotent replay also crosses this barrier before it is dequeued.
      guard await persistAIChatTranscriptDurably(context: context) else {
        guard isCurrentAIChatCorpusContext(context) else { return }
        retainedReasons.append(
          "\(entry.fileURL.lastPathComponent): transcript state was not persisted durably"
        )
        retainedReasons.append(contentsOf: scan.entries.dropFirst(index + 1).map {
          "\($0.fileURL.lastPathComponent): waiting for the earlier durability barrier"
        })
        break
      }
      guard isCurrentAIChatCorpusContext(context) else { return }
      do {
        try AIChatOperationJournal.removeCommittedSynchronously(entry)
      } catch {
        guard isCurrentAIChatCorpusContext(context) else { return }
        retainedReasons.append("\(entry.fileURL.lastPathComponent): \(error.localizedDescription)")
      }
    }

    if isCurrentAIChatCorpusContext(context), !retainedReasons.isEmpty {
      let visibleReasons = retainedReasons.prefix(3).joined(separator: "; ")
      let additionalCount = max(0, retainedReasons.count - 3)
      let additional = additionalCount > 0 ? "; plus \(additionalCount) more" : ""
      errorText = "AI chat operation journal retained \(retainedReasons.count) file(s): \(visibleReasons)\(additional)"
    }
  }

  private func applyAIChatOperation(_ operation: AIChatOperation) throws {
    switch operation {
    case .settleThread(let rawThreadID, let settledAt):
      let threadID = try resolveAIChatOperationThreadID(rawThreadID)
      guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }),
            !aiChatThreads[index].isSettled
      else { return }
      var threads = aiChatThreads
      threads[index] = threads[index].replacingAIChatMetadata(
        isArchived: true,
        settledAt: .some(settledAt)
      )
      aiChatThreads = Self.sortedAIChatThreadsForDisplay(threads)
      lastArchivedAIChatThreadID = threadID
    case .reopenThread(let rawThreadID):
      let threadID = try resolveAIChatOperationThreadID(rawThreadID)
      guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }),
            aiChatThreads[index].isSettled
      else { return }
      var threads = aiChatThreads
      threads[index] = threads[index].replacingAIChatMetadata(
        isArchived: false,
        settledAt: .some(nil)
      )
      aiChatThreads = Self.sortedAIChatThreadsForDisplay(threads)
      if lastArchivedAIChatThreadID == threadID {
        lastArchivedAIChatThreadID = nil
      }
    case .configureRoomAgentTurns(let rawThreadID, let limit):
      let threadID = try resolveAIChatOperationThreadID(rawThreadID)
      guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }),
            aiChatThreads[index].isSharedRoom,
            aiChatThreads[index].roomAgentTurnLimit != limit
      else { return }
      aiChatThreads[index] = aiChatThreads[index].replacingAIChatMetadata(
        roomAgentTurnLimit: .some(limit)
      )
    case .configureAutoSettle(let afterSeconds):
      aiChatThreadSettlementSettings = AIChatThreadSettlementSettings(
        autoSettleAfterSeconds: afterSeconds
      )
    case .autoSettle(let evaluatedAt):
      _ = autoSettleAIChatThreads(now: evaluatedAt, shouldPersist: false)
    }
  }

  private func resolveAIChatOperationThreadID(_ rawThreadID: String) throws -> UUID {
    guard let threadID = UUID(
      uuidString: rawThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
    ) else {
      throw CocoaError(
        .validationMissingMandatoryProperty,
        userInfo: [NSLocalizedDescriptionKey: "AI chat operation thread ID is not a UUID."]
      )
    }
    guard aiChatThreads.contains(where: { $0.id == threadID }) else {
      throw CocoaError(
        .fileNoSuchFile,
        userInfo: [NSLocalizedDescriptionKey: "AI chat operation references unknown thread \(rawThreadID)."]
      )
    }
    return threadID
  }

  nonisolated private static func loadAIChatInboxFiles(in directory: URL) -> [AIChatInboxFileLoad] {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    return files
      .filter { $0.pathExtension.lowercased() == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { file in
        do {
          let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
          guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 512_000 else {
            throw CocoaError(
              .fileReadTooLarge,
              userInfo: [NSLocalizedDescriptionKey: "AI chat inbox envelope is too large or is a symbolic link."]
            )
          }
          let envelope = try JSONDecoder().decode(
            AIChatInboxMessage.self,
            from: Data(contentsOf: file, options: .mappedIfSafe)
          )
          guard CelorgaNames.schemaMatches(envelope.schema, "org2:ai-chat-inbox-message:v1")
            || envelope.isSingleAgentSend else {
            throw CocoaError(
              .fileReadCorruptFile,
              userInfo: [NSLocalizedDescriptionKey: "Unsupported AI chat inbox schema in \(file.lastPathComponent)."]
            )
          }
          if envelope.isSingleAgentSend {
            guard let destinationID = envelope.destinationID,
                  !destinationID.isEmpty, destinationID.count <= 200,
                  envelope.requestedResponders?.isEmpty ?? true,
                  envelope.authorAgentRef == nil, envelope.source == nil
            else {
              throw CocoaError(.validationMissingMandatoryProperty, userInfo: [
                NSLocalizedDescriptionKey: "Single-agent send requires a destination and cannot request room responders."
              ])
            }
          }
          let content = envelope.content.trimmingCharacters(in: .whitespacesAndNewlines)
          let authorLabel = envelope.authorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !content.isEmpty, content.count <= 200_000,
                !authorLabel.isEmpty, authorLabel.count <= 200,
                (envelope.authorAgentRef?.count ?? 0) <= 1_000,
                (envelope.source?.count ?? 0) <= 2_000,
                (envelope.requestedResponders?.count ?? 0) <= 8,
                envelope.requestedResponders?.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) ?? true
          else {
            throw CocoaError(
              .validationMissingMandatoryProperty,
              userInfo: [NSLocalizedDescriptionKey: "AI chat inbox message fields are missing or exceed their limits."]
            )
          }
          return AIChatInboxFileLoad(file: file, envelope: envelope, errorDescription: nil)
        } catch {
          return AIChatInboxFileLoad(
            file: file,
            envelope: nil,
            errorDescription: error.localizedDescription
          )
        }
      }
  }

  public func updateAIChatRemoteThreadState(
    threadID: UUID,
    isPinned: Bool?,
    isSettled: Bool?
  ) -> Bool {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else {
      return false
    }
    if let isPinned, thread.isPinned != isPinned {
      toggleAIChatThreadPin(threadID)
    }
    if let isSettled {
      let current = aiChatThreads.first(where: { $0.id == threadID }) ?? thread
      if isSettled, !current.isSettled {
        settleAIChatThread(threadID)
      } else if !isSettled, current.isSettled {
        reopenAIChatThread(threadID)
      }
    }
    return true
  }

  public func mobileRemoteWorkspaceSnapshot(refreshesCanonicalState: Bool = true) async -> MobileRemoteWorkspaceSnapshot {
    if refreshesCanonicalState {
      await refreshMobileRemoteWorkspaceCanonicalStateIfNeeded()
    }
    return currentMobileRemoteWorkspaceSnapshot()
  }

  /// Identifies the canonical inputs of the Mobile Remote workspace snapshot.
  /// The corpus watcher bumps these generations for every relevant file event.
  private var mobileRemoteWorkspaceCanonicalKey: [UInt64] {
    [
      corpusSessionGeneration,
      workspaceSurfaceDirtyGenerations[.agenda, default: 0],
      workspaceSurfaceDirtyGenerations[.approvals, default: 0],
    ]
  }

  /// Re-reads agenda, approvals, and workflows for a phone request only when
  /// the corpus changed since the last request, or after a short backstop
  /// interval. On a large corpus a full re-read takes seconds, and the phone
  /// asks for this snapshot repeatedly. Concurrent requests share one read.
  private func refreshMobileRemoteWorkspaceCanonicalStateIfNeeded() async {
    if let inFlight = mobileRemoteWorkspaceRefreshTask {
      await inFlight.value
      return
    }
    let key = mobileRemoteWorkspaceCanonicalKey
    // Without a corpus watcher (tests, or a watcher that failed to start) no
    // event would invalidate the result, so every request re-reads.
    if !corpusFileWatchers.isEmpty,
       let last = mobileRemoteWorkspaceLastRefresh,
       last.key == key,
       Date().timeIntervalSince(last.at) < Self.mobileRemoteWorkspaceRefreshBackstop {
      return
    }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.refreshAgenda(updatesStatus: false)
      await self.refreshApprovals(updatesStatus: false)
      await self.refreshAgentWorkflows(updatesStatus: false)
    }
    mobileRemoteWorkspaceRefreshTask = task
    await task.value
    mobileRemoteWorkspaceRefreshTask = nil
    // The key captured before the read: an event during the read changes the
    // live key, so the next request reads again.
    mobileRemoteWorkspaceLastRefresh = (key, Date())
  }

  /// Forces the next phone workspace request to re-read canonical state.
  public func invalidateMobileRemoteWorkspaceSnapshot() {
    mobileRemoteWorkspaceLastRefresh = nil
  }

  public func setMobileRemoteAgendaStatus(itemID: String, status rawStatus: String) async throws -> MobileRemoteWorkspaceSnapshot {
    guard let status = TodoEditStatus(rawValue: rawStatus) else {
      throw CocoaError(
        .validationMissingMandatoryProperty,
        userInfo: [NSLocalizedDescriptionKey: "Choose TODO, in progress, done, or canceled."]
      )
    }
    await refreshAgenda(updatesStatus: false)
    guard let item = currentAgendaItems().first(where: { $0.id == itemID }) else {
      return currentMobileRemoteWorkspaceSnapshot()
    }
    let target = HeadlineMutationTarget(item: item)
    let newStatus = try await setTodoStatus(status, for: target)
    optimisticallyUpdateAgendaItem(id: item.id, todo: newStatus)
    invalidateCanonicalDocumentCache(for: item.file)
    await refreshAgenda(updatesStatus: false)
    return currentMobileRemoteWorkspaceSnapshot()
  }

  public func decideMobileRemoteApproval(
    itemID: String,
    decision: String,
    note rawNote: String?,
    endStatus rawEndStatus: String?,
    expectedRunID: String? = nil,
    expectedApprovalID: String? = nil,
    expectedFingerprint: String? = nil,
    receipt rawReceipt: String? = nil
  ) async throws -> MobileRemoteWorkspaceSnapshot {
    await refreshApprovals(updatesStatus: false)
    let hasExactIdentity = expectedRunID != nil || expectedApprovalID != nil || expectedFingerprint != nil
    if rawReceipt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
       MobileRemoteApprovalDecisionRequest.normalizedReceipt(rawReceipt) == nil {
      throw CocoaError(
        .validationMissingMandatoryProperty,
        userInfo: [NSLocalizedDescriptionKey: "The decision receipt is not a short single-line key. Nothing was changed."]
      )
    }
    let receipt = MobileRemoteApprovalDecisionRequest.normalizedReceipt(rawReceipt)
    guard let item = approvalItems.first(where: { $0.id == itemID })
      ?? snoozedApprovalItems.first(where: { $0.id == itemID }) else {
      if hasExactIdentity {
        // A replay of a decision this host already recorded with the same receipt returns
        // the original outcome. Anything else is refused: an exact decision must never
        // fall through to a silent no-op.
        if let receipt,
           let expectedRunID,
           let expectedApprovalID,
           let expectedFingerprint,
           let replayed = await mobileRemoteReplayedDecisionReceipt(
             runID: expectedRunID,
             approvalID: expectedApprovalID,
             fingerprint: expectedFingerprint,
             decision: decision,
             receipt: receipt
           ) {
          return currentMobileRemoteWorkspaceSnapshot(decisionReceipt: replayed)
        }
        throw CocoaError(
          .fileWriteUnknown,
          userInfo: [NSLocalizedDescriptionKey: "This approval is no longer pending. Nothing was changed."]
        )
      }
      return currentMobileRemoteWorkspaceSnapshot()
    }
    if hasExactIdentity {
      // Exact identity: the decision applies only to the approval the caller was shown.
      guard expectedRunID == item.runId,
            expectedApprovalID == item.approvalId,
            expectedFingerprint == item.fingerprint
      else {
        throw CocoaError(
          .fileWriteUnknown,
          userInfo: [NSLocalizedDescriptionKey: "The approval changed after it was read. Nothing was changed; review it again."]
        )
      }
    }
    guard !isApprovalActionInProgress(item) else {
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [NSLocalizedDescriptionKey: "This approval is already being updated."]
      )
    }

    let normalizedDecision = decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let note = rawNote?.trimmingCharacters(in: .whitespacesAndNewlines)
    let actionKind: ApprovalActionKind = normalizedDecision == "approved" ? .approve : .reject
    beginApprovalAction(item, kind: actionKind)
    defer { endApprovalAction(item, kind: actionKind) }

    var continuationRun: AgentRunItem?
    switch normalizedDecision {
    case "approved":
      if item.isRunApproval {
        continuationRun = try await decideRunApprovalItem(item, decision: "approved", receipt: receipt)
      } else {
        try await approveAndAgentHandoff(HeadlineMutationTarget(
          file: item.file,
          line: item.line,
          title: Org2Display.cleanInline(item.title),
          idValue: item.idValue
        ))
      }
    case "rejected":
      let note = note.flatMap(Self.normalizedApprovalRejectionReason)
      if item.isRunApproval {
        continuationRun = try await decideRunApprovalItem(item, decision: "rejected", note: note, receipt: receipt)
      } else {
        let endStatus = rawEndStatus.flatMap(TodoEditStatus.init(rawValue:)) ?? .canceled
        try await rejectApproval(
          HeadlineMutationTarget(
            file: item.file,
            line: item.line,
            title: Org2Display.cleanInline(item.title),
            idValue: item.idValue
          ),
          endStatus: endStatus,
          reason: note ?? ""
        )
      }
    case "revised":
      guard item.isRunApproval else {
        throw CocoaError(
          .featureUnsupported,
          userInfo: [NSLocalizedDescriptionKey: "Revision requests are available for run-backed approvals."]
        )
      }
      guard let note, !note.isEmpty else {
        throw CocoaError(
          .validationMissingMandatoryProperty,
          userInfo: [NSLocalizedDescriptionKey: "Describe what the agent should change."]
        )
      }
      continuationRun = try await decideRunApprovalItem(item, decision: "revised", note: note)
    default:
      throw CocoaError(
        .validationMissingMandatoryProperty,
        userInfo: [NSLocalizedDescriptionKey: "Choose approve, reject, or request changes."]
      )
    }

    if let continuationRun {
      // The decision is durable now. Do not hold the phone's HTTP request through a
      // corpus refresh or an agent turn: either can outlive its response deadline.
      // Confirm only the saved decision; continuation has its own durable outcome.
      // This applies to an in-app tap as well as a spoken reply.
      approvalItems.removeAll { $0.id == item.id }
      invalidateMobileRemoteWorkspaceSnapshot()
      // A rejection only records the decision; it does not start an agent turn.
      let startsAgentTurn = Self.approvalDecisionStartsAgentTurn(
        decision: normalizedDecision,
        run: continuationRun
      )
      Task { @MainActor [weak self] in
        guard let self else { return }
        if startsAgentTurn {
          await self.continueOpenClawAfterApprovalBoundary(continuationRun)
        }
        await self.refreshApprovals(updatesStatus: false)
      }
      guard hasExactIdentity, let approvalID = item.approvalId else {
        return currentMobileRemoteWorkspaceSnapshot()
      }
      return currentMobileRemoteWorkspaceSnapshot(decisionReceipt: Self.mobileRemoteDecisionReceipt(
        run: continuationRun,
        approvalID: approvalID,
        decision: normalizedDecision,
        continuation: nil,
        receipt: receipt,
        duplicate: false
      ))
    }

    await refreshApprovals(updatesStatus: false)
    if !item.isRunApproval {
      await refreshAgenda(preserveSelection: true, updatesStatus: false)
    }
    return currentMobileRemoteWorkspaceSnapshot()
  }

  nonisolated static func mobileRemoteDecisionReceipt(
    run: AgentRunItem,
    approvalID: String,
    decision: String,
    continuation: MobileRemoteApprovalContinuation?,
    receipt: String?,
    duplicate: Bool
  ) -> MobileRemoteApprovalDecisionReceipt {
    let resolved = continuation
      ?? (run.pendingApprovalCount > 0 ? .awaitingOtherApprovals : .recorded)
    return MobileRemoteApprovalDecisionReceipt(
      runID: run.id,
      approvalID: approvalID,
      decision: decision,
      runStatus: run.status,
      pendingApprovalCount: run.pendingApprovalCount,
      continuation: resolved.rawValue,
      receipt: receipt,
      duplicate: duplicate
    )
  }

  /// Returns the original outcome when this exact approval was already decided with the
  /// same receipt and decision. A different decision, fingerprint, or receipt returns nil.
  private func mobileRemoteReplayedDecisionReceipt(
    runID: String,
    approvalID: String,
    fingerprint: String,
    decision: String,
    receipt: String
  ) async -> MobileRemoteApprovalDecisionReceipt? {
    let normalizedDecision = decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let run: AgentRunItem?
    if let mobileRemoteRunLookupForTesting {
      run = await mobileRemoteRunLookupForTesting(runID)
    } else if let corpusRoot {
      run = try? await cli.runJSON(["run", "show", runID, "--dir", corpusRoot.path, "--json"])
    } else {
      run = nil
    }
    guard let run,
          let approval = run.approvals.first(where: { $0.id == approvalID }),
          approval.fingerprint == fingerprint,
          approval.receipt == receipt,
          approval.status == normalizedDecision
    else { return nil }
    return Self.mobileRemoteDecisionReceipt(
      run: run,
      approvalID: approvalID,
      decision: normalizedDecision,
      continuation: nil,
      receipt: receipt,
      duplicate: true
    )
  }

  public func setMobileRemoteWorkflowState(
    workflowID: String,
    state: String
  ) async throws -> MobileRemoteWorkspaceSnapshot {
    await refreshAgentWorkflows(updatesStatus: false)
    guard let workflow = agentWorkflows.first(where: { $0.id == workflowID }) else {
      return currentMobileRemoteWorkspaceSnapshot()
    }
    guard ["active", "paused", "draft"].contains(state) else {
      throw CocoaError(
        .validationMissingMandatoryProperty,
        userInfo: [NSLocalizedDescriptionKey: "Choose active, paused, or draft."]
      )
    }
    guard let corpusRoot, !mutatingAgentWorkflowIDs.contains(workflow.id) else {
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [NSLocalizedDescriptionKey: "This workflow is already being updated."]
      )
    }
    mutatingAgentWorkflowIDs.insert(workflow.id)
    defer { mutatingAgentWorkflowIDs.remove(workflow.id) }
    let action = state == "active" ? "activate" : state == "paused" ? "pause" : "draft"
    _ = try await cli.run(["workflow", action, workflow.id, "--dir", corpusRoot.path, "--json"])
    await refreshAgentWorkflows(updatesStatus: false)
    return currentMobileRemoteWorkspaceSnapshot()
  }

  public func runMobileRemoteWorkflow(
    workflowID: String,
    inputs: [String: String]
  ) async throws -> UUID {
    await refreshAgentWorkflows(updatesStatus: false)
    guard let workflow = agentWorkflows.first(where: { $0.id == workflowID }) else {
      throw CocoaError(
        .fileNoSuchFile,
        userInfo: [NSLocalizedDescriptionKey: "That workflow is no longer available."]
      )
    }
    let missingInputs = workflow.inputs.filter { input in
      input.required && (inputs[input.id] ?? input.default ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard missingInputs.isEmpty else {
      throw CocoaError(
        .validationMissingMandatoryProperty,
        userInfo: [NSLocalizedDescriptionKey: "Fill in: \(missingInputs.map(\.id).joined(separator: ", "))."]
      )
    }

    guard let threadID = await prepareAndDispatchAgentAutomation(
      workflowID: workflow.id,
      title: workflow.title,
      destinationRef: workflow.destinationRef,
      inputs: inputs,
      presentsThread: false
    ) else {
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [NSLocalizedDescriptionKey: errorText ?? "The automation thread could not be started."]
      )
    }
    return threadID
  }

  private func currentMobileRemoteWorkspaceSnapshot(
    decisionReceipt: MobileRemoteApprovalDecisionReceipt? = nil
  ) -> MobileRemoteWorkspaceSnapshot {
    let agendaItems = (agenda?.overdue ?? []).flatMap { day in
      day.items.map { mobileRemoteAgendaItem($0, date: day.date) }
    } + (agenda?.days ?? []).flatMap { day in
      day.items.map { mobileRemoteAgendaItem($0, date: day.date) }
    }
    return MobileRemoteWorkspaceSnapshot(
      agenda: agendaItems,
      approvals: approvalItems.map(Self.mobileRemoteApprovalItem),
      workflows: agentWorkflows.map { workflow in
        MobileRemoteWorkflowItem(
          id: workflow.id,
          title: workflow.title,
          description: workflow.description,
          state: workflow.state,
          riskClass: workflow.riskClass,
          scheduleSummary: workflow.scheduleSummary,
          file: workflow.file,
          agentRef: workflow.agentRef,
          goalRef: workflow.goalRef,
          inputs: workflow.inputs.map {
            MobileRemoteWorkflowInput(
              id: $0.id,
              description: $0.description,
              required: $0.required,
              defaultValue: $0.default
            )
          }
        )
      },
      approvalDecisionReceipt: decisionReceipt,
      approvalHistory: Self.mobileRemoteApprovalHistory(from: agentRuns),
      snoozedApprovals: snoozedApprovalItems.map(Self.mobileRemoteApprovalItem)
    )
  }

  nonisolated static func mobileRemoteApprovalItem(_ item: ApprovalItem) -> MobileRemoteApprovalItem {
    MobileRemoteApprovalItem(
      id: item.id,
      title: item.title,
      status: item.status,
      todo: item.todo,
      level: item.level,
      file: item.file,
      line: item.line,
      sourceID: item.idValue,
      properties: item.properties,
      body: item.body,
      tags: item.tags,
      kind: item.kind,
      runID: item.runId,
      approvalID: item.approvalId,
      fingerprint: item.fingerprint,
      action: item.action,
      riskClass: item.riskClass,
      requestedRole: item.requestedRole,
      requestedFrom: item.requestedFrom,
      requestedAt: item.requestedAt,
      runGoal: item.runGoal,
      runStatus: item.runStatus,
      runDecisionEffect: item.runDecisionEffect,
      priority: item.priority,
      snoozedUntil: item.snoozedUntil
    )
  }

  /// Snoozes or wakes one approval for the paired phone, then returns a fresh snapshot.
  public func snoozeMobileRemoteApproval(
    itemID: String,
    until: Date?,
    expectedRunID: String? = nil,
    expectedApprovalID: String? = nil,
    expectedFingerprint: String? = nil
  ) async throws -> MobileRemoteWorkspaceSnapshot {
    await refreshApprovals(updatesStatus: false)
    guard let item = approvalItems.first(where: { $0.id == itemID })
      ?? snoozedApprovalItems.first(where: { $0.id == itemID }) else {
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [NSLocalizedDescriptionKey: "This approval is no longer pending. Nothing was changed."]
      )
    }
    if expectedRunID != nil || expectedApprovalID != nil || expectedFingerprint != nil {
      guard expectedRunID == item.runId,
            expectedApprovalID == item.approvalId,
            expectedFingerprint == item.fingerprint
      else {
        throw CocoaError(
          .fileWriteUnknown,
          userInfo: [NSLocalizedDescriptionKey: "The approval changed after it was read. Nothing was changed; review it again."]
        )
      }
    }
    if let until, until <= Date() {
      throw CocoaError(
        .validationMissingMandatoryProperty,
        userInfo: [NSLocalizedDescriptionKey: "Choose a snooze time in the future."]
      )
    }
    guard !isApprovalActionInProgress(item) else {
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [NSLocalizedDescriptionKey: "This approval is already being updated."]
      )
    }
    await setApprovalSnooze(item, until: until, updatesApprovalQueue: true)
    if let error = approvalActionErrorsByItemID[item.id] {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: error])
    }
    invalidateMobileRemoteWorkspaceSnapshot()
    return currentMobileRemoteWorkspaceSnapshot()
  }

  nonisolated static func mobileRemoteApprovalHistory(from runs: [AgentRunItem]) -> [MobileRemoteApprovalHistoryItem] {
    Array(runs.flatMap { run in
      run.approvals.filter { $0.status != "pending" }.map { approval in
        MobileRemoteApprovalHistoryItem(
          runID: run.id, approvalID: approval.id, title: approval.title, status: approval.status,
          decidedAt: approval.decidedAt, decidedBy: approval.decidedBy,
          decisionNote: approval.decisionNote ?? approval.note
        )
      }
    }.sorted {
      if $0.decidedAt != $1.decidedAt { return ($0.decidedAt ?? "") > ($1.decidedAt ?? "") }
      return $0.id < $1.id
    }.prefix(100))
  }

  private func currentAgendaItems() -> [AgendaItem] {
    (agenda?.overdue ?? []).flatMap(\.items) + (agenda?.days ?? []).flatMap(\.items)
  }

  private func mobileRemoteAgendaItem(_ item: AgendaItem, date: String) -> MobileRemoteAgendaItem {
    MobileRemoteAgendaItem(
      id: item.id,
      title: item.headline,
      todo: item.todo ?? "TODO",
      file: item.file,
      line: item.lineForEditor,
      date: date,
      kind: item.kind,
      tags: item.tags,
      body: item.body ?? "",
      priority: item.priority,
      time: item.time,
      effort: item.effort
    )
  }

  public func mobileRemoteFilePreview(
    path rawPath: String,
    line requestedLine: Int?
  ) async throws -> MobileRemoteFilePreview {
    let sessionGeneration = corpusSessionGeneration
    let mountedRootPaths = workspaceMountPaths().sorted()
    let authorization = MobileRemoteFilePreviewAuthorization(
      mountedRootPaths: mountedRootPaths,
      activeRootPath: corpusRoot?.standardizedFileURL.path,
      overlay: mobileRemoteFilePreviewOverlay()
    )
    let preparation = mobileRemoteFilePreviewPreparationForTesting
    let didRead = mobileRemoteFilePreviewDidReadForTesting
    let preview = try await Task.detached(priority: .userInitiated) {
      if let preparation {
        await preparation()
      }
      return try Self.loadMobileRemoteFilePreview(
        path: rawPath,
        requestedLine: requestedLine,
        authorization: authorization,
        didRead: didRead
      )
    }.value
    guard !Task.isCancelled,
          corpusSessionGeneration == sessionGeneration,
          workspaceMountPaths().sorted() == mountedRootPaths
    else {
      throw MobileRemoteFilePreviewError.invalidPath
    }
    return preview
  }

  nonisolated public static let mobileRemoteImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
  nonisolated public static let mobileRemoteImageMaxBytes = 12 * 1024 * 1024

  /// Returns the bytes of an image inside the active or mounted corpora so the
  /// iOS chat can render inline image links that are not yet synced locally.
  public func mobileRemoteImage(path rawPath: String) async throws -> MobileRemoteImage {
    let active = corpusRoot?.standardizedFileURL.path
    let mounted = workspaceMountPaths().sorted()
    let roots = (active.map { [$0] } ?? []) + mounted.filter { $0 != active }
    return try await Task.detached(priority: .userInitiated) {
      let target = try Self.mobileRemotePreviewTarget(for: rawPath, mountedRootPaths: roots)
      let ext = target.url.pathExtension.lowercased()
      guard Self.mobileRemoteImageExtensions.contains(ext) else {
        throw MobileRemoteFilePreviewError.unsupportedFile
      }
      let size = (try? target.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      guard size <= Self.mobileRemoteImageMaxBytes,
            let data = try? Data(contentsOf: target.url)
      else { throw MobileRemoteFilePreviewError.unavailable }
      let mimeType = ext == "jpg" ? "image/jpeg" : "image/\(ext)"
      return MobileRemoteImage(relativePath: target.relativePath, mimeType: mimeType, data: data)
    }.value
  }

  private func mobileRemoteFilePreviewOverlay() -> MobileRemoteFilePreviewOverlay? {
    guard let selectedFile = selectedEntrySource?.file ?? selectedLocation?.file else {
      return nil
    }
    if isLiveFileEditorSelected, let source = selectedEntrySource {
      guard source.startLine == 1, !source.isSubtree else {
        return .invalidWholeFile(file: selectedFile)
      }
      return .wholeFile(file: selectedFile, text: editableEntryText)
    }
    if isEditingEntry, let source = selectedEntrySource {
      return .sourceRange(
        file: selectedFile,
        source: source,
        replacement: sourceEditorLocalDraftText ?? editableEntryText
      )
    }
    if let block = activeEditingBlock,
       let source = selectedEntrySource,
       transientDraftBlock == nil {
      let sourceBlock = activeBlockOriginals[block.id] ?? block
      return .sourceRange(
        file: selectedFile,
        source: EntrySource(
          file: source.file,
          startLine: sourceBlock.startLine,
          endLineExclusive: sourceBlock.endLineExclusive,
          text: sourceBlock.rawText,
          isSubtree: false
        ),
        replacement: saveReplacementText(for: block)
      )
    }
    return nil
  }

  nonisolated private static func loadMobileRemoteFilePreview(
    path rawPath: String,
    requestedLine: Int?,
    authorization: MobileRemoteFilePreviewAuthorization,
    didRead: (@Sendable (Bool) -> Void)?
  ) throws -> MobileRemoteFilePreview {
    let target = try mobileRemotePreviewTarget(
      for: rawPath,
      mountedRootPaths: authorization.mountedRootPaths
    )
    guard ["org2", "org", "md", "csv"].contains(target.url.pathExtension.lowercased()) else {
      throw MobileRemoteFilePreviewError.unsupportedFile
    }
    didRead?(Thread.isMainThread)
    guard let diskText = try? String(contentsOf: target.url, encoding: .utf8) else {
      throw MobileRemoteFilePreviewError.unavailable
    }

    let text: String
    let activeRoot = authorization.activeRootPath.map {
      URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
    }
    if activeRoot == target.root.path,
       let overlay = authorization.overlay,
       URL(fileURLWithPath: overlay.file).resolvingSymlinksInPath().standardizedFileURL.path
         == target.url.path {
      switch overlay {
      case .wholeFile(_, let overlayText):
        text = overlayText
      case .sourceRange(_, let source, let replacement):
        text = try aiChatEffectiveFileText(
          diskText: diskText,
          source: source,
          replacement: replacement
        )
      case .invalidWholeFile:
        throw AIChatLocalEditError.invalidRequest(
          "the selected file editor is not a whole-file editor"
        )
      }
    } else {
      text = diskText
    }

    let highlightedLine = requestedLine.flatMap { line in
      textContainsLine(line, text: text) ? line : nil
    }
    return MobileRemoteFilePreview(
      title: target.url.lastPathComponent,
      relativePath: target.relativePath,
      startLine: 1,
      highlightedLine: highlightedLine,
      content: text
    )
  }

  nonisolated private static func mobileRemotePreviewTarget(
    for rawPath: String,
    mountedRootPaths: [String]
  ) throws -> MobileRemoteFilePreviewTarget {
    var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.hasPrefix("~/") {
      path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(String(path.dropFirst(2)))
        .path
    }
    guard !path.isEmpty else {
      throw MobileRemoteFilePreviewError.invalidPath
    }

    let roots = mountedRootPaths
      .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL }
    let candidates: [(root: URL, url: URL)]
    if path.hasPrefix("/") {
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      candidates = roots.map { ($0, url) }
    } else {
      let relative = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
      guard !relative.split(separator: "/").contains(where: { $0 == ".." }) else {
        throw MobileRemoteFilePreviewError.invalidPath
      }
      candidates = roots.flatMap { root -> [(root: URL, url: URL)] in
        var relativePaths = [relative]
        let corpusPrefix = root.lastPathComponent + "/"
        if relative.hasPrefix(corpusPrefix) {
          relativePaths.append(String(relative.dropFirst(corpusPrefix.count)))
        }
        return relativePaths.map {
          (root, root.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL)
        }
      }
    }

    for candidate in candidates {
      let rootPath = candidate.root.path
      let resolvedURL = candidate.url.resolvingSymlinksInPath().standardizedFileURL
      let candidatePath = resolvedURL.path
      guard candidatePath.hasPrefix(rootPath + "/"),
            (try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      else { continue }
      return MobileRemoteFilePreviewTarget(
        root: candidate.root,
        url: resolvedURL,
        relativePath: String(candidatePath.dropFirst(rootPath.count + 1))
      )
    }
    throw MobileRemoteFilePreviewError.invalidPath
  }

  nonisolated private static func textContainsLine(_ requestedLine: Int, text: String) -> Bool {
    guard requestedLine > 0 else { return false }
    if requestedLine == 1 { return true }
    var line = 1
    for byte in text.utf8 where byte == 0x0A {
      line += 1
      if line == requestedLine { return true }
    }
    return false
  }

  public func aiChatRemoteModelOptions(for threadID: UUID) async throws -> [AIChatModelOption] {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else {
      throw AIChatRemoteConfigurationError.threadNotFound
    }
    return try await remoteModelsForAIChatDestination(thread.destinationID)
  }

  /// The phone asks for models every time it opens a chat. Answer from the
  /// catalog this Mac already cached for the destination and refresh it in the
  /// background, so a slow harness listing (for example `opencode models`)
  /// never holds up the model menu. Only a destination without a cached
  /// catalog waits for the live listing.
  func remoteModelsForAIChatDestination(_ destinationID: String) async throws -> [AIChatModelOption] {
    if let cached = aiChatConfigurationCatalogCache[destinationID]?.models, !cached.isEmpty {
      refreshRemoteAIChatModelCatalogInBackground(destinationID)
      return cached
    }
    let models = try await modelsForAIChatDestination(destinationID)
    cacheAIChatModelCatalog(destinationID: destinationID, models: models)
    return models
  }

  private func refreshRemoteAIChatModelCatalogInBackground(_ destinationID: String) {
    guard aiChatRemoteModelCatalogRefreshes.insert(destinationID).inserted else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.aiChatRemoteModelCatalogRefreshes.remove(destinationID) }
      guard let models = try? await self.modelsForAIChatDestination(destinationID) else { return }
      self.cacheAIChatModelCatalog(destinationID: destinationID, models: models)
    }
  }

  /// Moves a new, empty single-agent chat to another destination, as the
  /// Mac's agent picker does for the selected chat. A chat that already has
  /// messages keeps its agent; mentioning another agent forks a room instead.
  public func setAIChatRemoteDestination(_ destinationID: String, threadID: UUID) throws {
    guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }) else {
      throw AIChatRemoteConfigurationError.threadNotFound
    }
    let thread = aiChatThreads[index]
    guard thread.destinationID != destinationID else { return }
    guard let destination = aiChatDestination(id: destinationID), destination.isEnabled else {
      throw AIChatRemoteConfigurationError.unknownDestination(destinationID)
    }
    guard thread.canChangeAIRuntime, !isAIChatThreadRunning(threadID) else {
      throw AIChatRemoteConfigurationError.destinationLocked
    }
    let lastConfiguration = preferredAIChatConfiguration(forDestinationID: destinationID)
    aiChatThreads[index] = thread.replacingAIChatMetadata(
      runtime: destination.runtime,
      destinationID: destinationID,
      runtimeThreadID: .some(nil),
      runtimeThreadIDsByDestination: [:],
      model: .some(lastConfiguration?.model),
      reasoningEffort: .some(lastConfiguration?.reasoningEffort)
    )
    sortAIChatThreadsForDisplay()
    scheduleAIChatTranscriptPersistenceAfterInteraction()
    if selectedAIChatThreadID == threadID {
      if !applyCachedAIChatConfiguration(for: aiChatThreads[index]) {
        aiChatModelOptions = []
        aiChatReasoningOptions = []
        aiChatEffectiveModel = nil
        aiChatDefaultReasoningEffort = nil
      }
      Task { @MainActor [weak self] in
        await self?.refreshAIChatConfiguration()
      }
    }
  }

  public func aiChatRemoteConfiguration(
    for threadID: UUID
  ) async throws -> AIChatRemoteConfiguration {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else {
      throw AIChatRemoteConfigurationError.threadNotFound
    }
    let adapter = aiChatDestination(id: thread.destinationID)?.adapter
      ?? {
        switch thread.runtime {
        case .codex: .codexLocal
        case .claude: .claudeLocal
        case .pi: .piLocal
        case .openCode: .openCodeLocal
        case .openClaw: .openClaw
        }
      }()
    switch adapter {
    case .codexLocal, .codexRemote, .codexManagedRemote:
      let models = try await remoteModelsForAIChatDestination(thread.destinationID)
      let selected = thread.model.flatMap { model in
        models.first(where: { $0.id == model })
      } ?? models.first(where: \.isDefault)
      return AIChatRemoteConfiguration(
        models: models,
        effectiveModel: selected?.id,
        reasoningEffort: thread.reasoningEffort,
        reasoningOptions: selected?.reasoningOptions ?? [],
        defaultReasoningEffort: selected?.defaultReasoningEffort
      )
    case .claudeLocal:
      let models = try await remoteModelsForAIChatDestination(thread.destinationID)
      return AIChatRemoteConfiguration(
        models: models,
        effectiveModel: thread.model,
        reasoningEffort: nil,
        reasoningOptions: [],
        defaultReasoningEffort: nil
      )
    case .piLocal, .piRemote, .openCodeLocal, .openCodeRemote:
      let models = try await remoteModelsForAIChatDestination(thread.destinationID)
      return AIChatRemoteConfiguration(
        models: models,
        effectiveModel: thread.model ?? aiChatDestination(id: thread.destinationID)?.model,
        reasoningEffort: thread.reasoningEffort,
        reasoningOptions: Self.cliHarnessReasoningOptions,
        defaultReasoningEffort: nil
      )
    case .openClaw:
      let settings = openClawSettings(
        forDestinationID: thread.destinationID,
        allowKeychainRead: true
      )
      let client = OpenClawGatewayClient(settings: settings)
      let models = try await client.listModels()
      let configuration = try await client.sessionConfiguration(sessionKey: thread.sessionKey)
      return AIChatRemoteConfiguration(
        models: models,
        effectiveModel: configuration?.model ?? thread.model,
        reasoningEffort: thread.reasoningEffort,
        reasoningOptions: configuration?.reasoningOptions ?? [],
        defaultReasoningEffort: configuration?.defaultReasoningEffort
      )
    case .openAI, .anthropic, .openRouter, .ollama:
      let models = try await remoteModelsForAIChatDestination(thread.destinationID)
      let preset = aiChatDestination(id: thread.destinationID)?.providerPreset
      return AIChatRemoteConfiguration(
        models: models,
        effectiveModel: thread.model ?? aiChatDestination(id: thread.destinationID)?.model,
        reasoningEffort: preset == nil ? nil : thread.reasoningEffort,
        reasoningOptions: preset?.reasoningOptions ?? [],
        defaultReasoningEffort: preset?.defaultReasoningEffort
      )
    case .openAIDot:
      return AIChatRemoteConfiguration(
        models: [],
        effectiveModel: nil,
        reasoningEffort: nil,
        reasoningOptions: [],
        defaultReasoningEffort: nil
      )
    }
  }

  public func setAIChatRemoteModel(
    _ model: String?,
    threadID: UUID
  ) async throws -> [AIChatModelOption] {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else {
      throw AIChatRemoteConfigurationError.threadNotFound
    }
    guard !isAIChatThreadRunning(threadID) else {
      throw AIChatRemoteConfigurationError.turnInProgress
    }

    var options = try await aiChatRemoteModelOptions(for: threadID)
    if let model, !options.contains(where: { $0.id == model }) {
      // The phone's list can come from the cached catalog; confirm against a
      // live listing before refusing a model the runtime may have added.
      options = try await modelsForAIChatDestination(thread.destinationID)
      cacheAIChatModelCatalog(destinationID: thread.destinationID, models: options)
      guard options.contains(where: { $0.id == model }) else {
        throw AIChatRemoteConfigurationError.unknownModel(model)
      }
    }

    if aiChatDestination(id: thread.destinationID)?.adapter == .openClaw {
      let settings = openClawSettings(
        forDestinationID: thread.destinationID,
        allowKeychainRead: true
      )
      let configuredAgentID = aiChatDestination(id: thread.destinationID)?.agentID ?? ""
      _ = try await OpenClawGatewayClient(settings: settings).patchSessionConfiguration(
        sessionKey: thread.sessionKey,
        agentID: OpenClawChatClient.openClawAgentHeaderValue(
          for: configuredAgentID.isEmpty ? openClawAgentID : configuredAgentID
        ),
        model: model,
        reasoningEffort: nil
      )
    }

    guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }) else {
      throw AIChatRemoteConfigurationError.threadNotFound
    }
    aiChatThreads[index] = aiChatThreads[index].replacingAIChatMetadata(
      model: .some(model),
      reasoningEffort: .some(nil)
    )
    persistLastAIChatConfiguration(
      destinationID: aiChatThreads[index].destinationID,
      model: model,
      reasoningEffort: nil
    )
    if selectedAIChatThreadID == threadID {
      aiChatModelOptions = options
      aiChatReasoningOptions = []
      aiChatEffectiveModel = model ?? options.first(where: \.isDefault)?.id
      aiChatDefaultReasoningEffort = nil
    }
    persistAIChatTranscript()
    return options
  }

  public func setAIChatRemoteReasoningEffort(
    _ reasoningEffort: String?,
    threadID: UUID
  ) async throws {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }) else {
      throw AIChatRemoteConfigurationError.threadNotFound
    }
    guard !isAIChatThreadRunning(threadID) else {
      throw AIChatRemoteConfigurationError.turnInProgress
    }

    let configuration = try await aiChatRemoteConfiguration(for: threadID)
    if let reasoningEffort,
       !configuration.reasoningOptions.contains(where: { $0.id == reasoningEffort }) {
      throw AIChatRemoteConfigurationError.unknownReasoningEffort(reasoningEffort)
    }
    if aiChatDestination(id: thread.destinationID)?.adapter == .openClaw {
      let settings = openClawSettings(
        forDestinationID: thread.destinationID,
        allowKeychainRead: true
      )
      let configuredAgentID = aiChatDestination(id: thread.destinationID)?.agentID ?? ""
      _ = try await OpenClawGatewayClient(settings: settings).patchSessionConfiguration(
        sessionKey: thread.sessionKey,
        agentID: OpenClawChatClient.openClawAgentHeaderValue(
          for: configuredAgentID.isEmpty ? openClawAgentID : configuredAgentID
        ),
        model: thread.model,
        reasoningEffort: reasoningEffort
      )
    }

    guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }) else {
      throw AIChatRemoteConfigurationError.threadNotFound
    }
    aiChatThreads[index] = aiChatThreads[index].replacingAIChatMetadata(
      reasoningEffort: .some(reasoningEffort)
    )
    persistLastAIChatConfiguration(
      destinationID: aiChatThreads[index].destinationID,
      model: aiChatThreads[index].model,
      reasoningEffort: reasoningEffort
    )
    if selectedAIChatThreadID == threadID {
      aiChatModelOptions = configuration.models
      aiChatReasoningOptions = configuration.reasoningOptions
      aiChatEffectiveModel = configuration.effectiveModel
      aiChatDefaultReasoningEffort = configuration.defaultReasoningEffort
    }
    persistAIChatTranscript()
  }

  public func sendComposedAIChatMessage(
    text rawText: String,
    delivery: AIChatMessageDeliveryPreference = .automatic
  ) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    let attachments = aiChatPendingAttachments
    guard !text.isEmpty || !attachments.isEmpty else { return }
    ensureAIChatThread()
    guard let threadID = selectedAIChatThreadID else { return }
    let context = captureAIChatCorpusContext()
    let submission = captureAIChatComposerSubmission(
      threadID: threadID,
      draft: rawText,
      attachments: attachments,
      context: context
    )
    let result = submitAIChatMessage(
      text,
      attachments: attachments,
      in: threadID,
      delivery: delivery,
      context: context
    )
    observeAIChatComposerSubmission(submission, result: result)
  }

  public func submitAIChatComposerInput(text rawText: String) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !aiChatPendingAttachments.isEmpty else { return }

    switch AIChatSlashCommands.parse(
      text,
      gatewayCommands: activeAIChatGatewayCommands,
      corpusSkills: corpusAgentSkillCommands
    ) {
    case .message(let message):
      sendComposedAIChatMessage(text: message)
    case .unknown(let name):
      guard !name.isEmpty else {
        clearAIChatDraftForSelectedThread()
        appendLocalAIChatCommand(
          text,
          result: "Type / followed by a command, or use /help to see all commands."
        )
        return
      }
      guard aiChatPendingAttachments.isEmpty else {
        appendLocalAIChatCommand(
          text,
          result: "Slash commands must be sent without attachments. Remove the attachment and try again."
        )
        return
      }
      ensureAIChatThread()
      guard let threadID = selectedAIChatThreadID else { return }
      let context = captureAIChatCorpusContext()
      let submission = captureAIChatComposerSubmission(
        threadID: threadID,
        draft: rawText,
        attachments: [],
        context: context
      )
      aiChatStatusText = "Sending /\(name) to \(selectedAIChatRuntime.title)…"
      let result = submitAIChatMessage(
        text,
        attachments: [],
        in: threadID,
        audience: selectedAIChatIsSharedRoom ? .openClaw : nil,
        context: context
      )
      observeAIChatComposerSubmission(submission, result: result)
    case .command(let command, let arguments):
      guard aiChatPendingAttachments.isEmpty else {
        appendLocalAIChatCommand(
          text,
          result: "Slash commands cannot include attachments yet. Remove the attachment and try again."
        )
        return
      }
      ensureAIChatThread()
      guard let threadID = selectedAIChatThreadID else { return }
      let context = captureAIChatCorpusContext()
      let submission = captureAIChatComposerSubmission(
        threadID: threadID,
        draft: rawText,
        attachments: [],
        context: context
      )
      aiChatStatusText = "Running /\(command.name)…"
      Task { @MainActor [weak self] in
        await self?.executeAIChatSlashCommand(
          command,
          arguments: arguments,
          rawText: text,
          threadID: threadID,
          context: context,
          submission: submission
        )
      }
    }
  }

  private func executeAIChatSlashCommand(
    _ command: AIChatSlashCommand,
    arguments: String,
    rawText: String,
    threadID: UUID,
    context: AIChatCorpusContextToken,
    submission: AIChatComposerSubmission
  ) async {
    guard isCurrentAIChatCorpusContext(context) else { return }
    guard await hydrateAIChatThreadIfNeeded(threadID) != nil,
          isCurrentAIChatCorpusContext(context)
    else { return }
    if command.origin == .openClaw || command.isAgentAssisted {
      let isSharedRoom = aiChatThreads.first(where: { $0.id == threadID })?.isSharedRoom == true
      let result = submitAIChatMessage(
        rawText,
        attachments: [],
        in: threadID,
        audience: isSharedRoom ? .openClaw : nil,
        context: context
      )
      observeAIChatComposerSubmission(submission, result: result)
      return
    }

    do {
      let result: String
      switch command.name {
      case "help":
        result = AIChatSlashCommands.helpText(
          gatewayCommands: activeAIChatGatewayCommands,
          corpusSkills: corpusAgentSkillCommands
        )
      case "search":
        result = await executeAIChatSearch(arguments)
      case "open":
        result = executeAIChatOpen(arguments)
      case "today":
        openDailyNote(.today)
        result = statusText
      case "agenda":
        makeSurfacePrimary(.agenda)
        await refreshAgenda(preserveSelection: true, updatesStatus: false)
        if let agenda {
          result = "Opened Agenda — \(agenda.totalItemCount) item\(agenda.totalItemCount == 1 ? "" : "s"), \(agenda.todayItemCount) today."
        } else {
          result = "Opened Agenda."
        }
      case "related":
        result = await executeAIChatRelated()
      case "spellcheck":
        result = await executeAIChatSpellcheck()
      case "lint":
        result = try await executeAIChatLint()
      case "export":
        result = try await executeAIChatExport(arguments)
      case "publish":
        result = try await executeAIChatPublish(arguments)
      default:
        result = "Command /\(command.name) is not implemented yet."
      }
      guard isCurrentAIChatCorpusContext(context) else { return }
      appendLocalAIChatCommand(rawText, result: result, in: threadID)
      clearAcceptedAIChatComposerSubmission(submission)
    } catch {
      guard isCurrentAIChatCorpusContext(context) else { return }
      appendLocalAIChatCommand(
        rawText,
        result: "Could not run /\(command.name): \(error.localizedDescription)",
        in: threadID
      )
      clearAcceptedAIChatComposerSubmission(submission)
    }
  }

  private func appendLocalAIChatCommand(_ command: String, result: String, in threadID: UUID? = nil) {
    ensureAIChatThread()
    guard let threadID = threadID ?? selectedAIChatThreadID else { return }
    if unloadedAIChatThreadIDs.contains(threadID) {
      hydrateAIChatThread(threadID)
      Task { @MainActor [weak self] in
        guard let self,
              await self.hydrateAIChatThreadIfNeeded(threadID) != nil
        else { return }
        self.appendLocalAIChatCommand(command, result: result, in: threadID)
      }
      return
    }
    var messages = aiChatMessages(for: threadID)
    messages.append(AIChatMessage(role: .user, content: command))
    messages.append(AIChatMessage(role: .system, content: result))
    replaceAIChatMessages(messages, for: threadID, shouldPersist: true)
    aiChatStatusText = "Ran \(command.split(whereSeparator: { $0.isWhitespace }).first ?? "command")"
  }

  private func executeAIChatSearch(_ query: String) async -> String {
    guard !query.isEmpty else { return "Usage: /search QUERY" }
    searchQuery = query
    await runSearch()
    makeSurfacePrimary(.search)
    guard !searchResults.isEmpty else { return "No corpus results for “\(query)”." }
    let rows = searchResults.prefix(8).map { result in
      "• \(relativePath(result.file)):\(result.lineForEditor) — \(result.snippet.replacingOccurrences(of: "\n", with: " "))"
    }
    let suffix = searchResults.count > rows.count ? "\n\n\(searchResults.count - rows.count) more results are open in Search." : ""
    return "Found \(searchResults.count) corpus result\(searchResults.count == 1 ? "" : "s"):\n\n\(rows.joined(separator: "\n"))\(suffix)"
  }

  private func executeAIChatOpen(_ query: String) -> String {
    guard !query.isEmpty else { return "Usage: /open PATH" }
    let normalized = query.lowercased()
    let exact = corpusFiles.filter {
      $0.relativePath.lowercased() == normalized || $0.name.lowercased() == normalized
    }
    let matches = exact.isEmpty
      ? corpusFiles.filter { $0.relativePath.lowercased().contains(normalized) }
      : exact
    guard let match = matches.first else { return "No corpus file matches “\(query)”." }
    guard matches.count == 1 else {
      return "More than one file matches “\(query)”: \(matches.prefix(8).map(\.relativePath).joined(separator: ", "))"
    }
    selectCorpusFile(match)
    return "Opened \(match.relativePath)."
  }

  private func executeAIChatRelated() async -> String {
    guard let location = selectedLocation else { return "Open a document first, then run /related." }
    await loadBacklinks(for: location)
    guard let backlinks, !backlinks.backlinks.isEmpty else { return "No backlinks found for the current document." }
    let rows = backlinks.backlinks.prefix(12).map {
      "• \(relativePath($0.file)):\($0.lineForEditor) — \($0.srcTitle)"
    }
    return "\(backlinks.backlinks.count) backlink\(backlinks.backlinks.count == 1 ? "" : "s"):\n\n\(rows.joined(separator: "\n"))"
  }

  private func executeAIChatSpellcheck() async -> String {
    guard let source = selectedEntrySource else { return "Open a document first, then run /spellcheck." }
    guard let snapshot = await analyzeSourceEditorText(source.text) else { return "The document could not be analyzed for spell checking." }
    let issues = AIChatSpellchecker.issues(
      in: source.text,
      snapshot: snapshot,
      lineOffset: max(0, source.startLine - 1)
    )
    guard !issues.isEmpty else { return "No spelling issues found in prose regions." }
    let rows = issues.map { issue -> String in
      let suggestions = issue.suggestions.isEmpty ? "" : " → \(issue.suggestions.joined(separator: ", "))"
      return "• line \(issue.line): \(issue.word)\(suggestions)"
    }
    let suffix = issues.count == 50 ? "\n\nStopped after 50 issues." : ""
    return "Found \(issues.count) possible spelling issue\(issues.count == 1 ? "" : "s"):\n\n\(rows.joined(separator: "\n"))\(suffix)"
  }

  private func executeAIChatLint() async throws -> String {
    guard let corpusRoot else { return "Open a corpus first, then run /lint." }
    let data = try await cli.run(["lint", "--dir", corpusRoot.path, "--recursive", "--format", "text"])
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? "Lint passed with no findings." : String(output.prefix(12_000))
  }

  private func executeAIChatExport(_ arguments: String) async throws -> String {
    guard let sourceFile = currentOrgSourceFile else { return "Open a document first. Usage: /export pdf|html" }
    let format = arguments.lowercased()
    guard format == "pdf" || format == "html" else { return "Usage: /export pdf|html" }
    guard await savePendingEditsBeforeExport(blockedStatus: "Save the current edit before exporting the document") else {
      return "Save the current edit before exporting the document."
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = format == "pdf" ? [.pdf] : [.html]
    panel.nameFieldStringValue = sourceFile.deletingPathExtension().lastPathComponent + ".\(format)"
    guard panel.runModal() == .OK, let destination = panel.url else { return "Export cancelled." }
    if format == "html" {
      let html = try await renderedCurrentDocumentHTML(sourceFile: sourceFile)
      try Data(html.utf8).write(to: destination, options: .atomic)
    } else {
      try await exportCurrentDocumentPDF(sourceFile: sourceFile, destination: destination)
    }
    return "Exported \(destination.lastPathComponent)."
  }

  private func executeAIChatPublish(_ arguments: String) async throws -> String {
    if arguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "document" {
      guard currentOrgSourceFile != nil else {
        return "Open an Org document first, then run /publish document."
      }
      presentDocumentPublisher()
      return "Opened Publish Document. Preview the disclosure boundary, then choose a local or Google Drive format."
    }
    guard let corpusRoot else { return "Open a corpus first, then run /publish." }
    guard let config = CelorgaNames.configFile(in: corpusRoot) else {
      return "Publishing requires celorga.json in the corpus root."
    }
    var parts = arguments.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let preview = parts.first?.lowercased() == "preview"
    if preview { parts.removeFirst() }
    var cliArguments = ["publish"]
    if let project = parts.first { cliArguments.append(project) }
    cliArguments.append(contentsOf: ["--config", config.path])
    if preview { cliArguments.append("--preview") }
    let data = try await cli.run(cliArguments)
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? (preview ? "Publish preview passed." : "Publish completed.") : String(output.prefix(12_000))
  }

  func sendAIChatMessage(
    _ text: String,
    attachments: [AIChatAttachment],
    workspaceContext: AIChatWorkspaceContext? = nil
  ) async {
    ensureAIChatThread()
    guard let sourceThreadID = selectedAIChatThreadID else { return }
    let context = captureAIChatCorpusContext()
    let result = submitAIChatMessage(
      text,
      attachments: attachments,
      in: sourceThreadID,
      workspaceContext: workspaceContext,
      context: context
    )
    _ = await awaitAIChatEnqueueAndImmediateDrain(
      result
    )
  }

  @discardableResult
  func submitAIChatMessage(
    _ text: String,
    attachments: [AIChatAttachment],
    in threadID: UUID,
    workspaceContext: AIChatWorkspaceContext? = nil,
    audience: AIChatAudience? = nil,
    delivery: AIChatMessageDeliveryPreference = .automatic,
    context: AIChatCorpusContextToken? = nil,
    origin: AIChatMessageProvenance? = nil
  ) -> AIChatEnqueueResult {
    let context = context ?? captureAIChatCorpusContext()
    guard isCurrentAIChatCorpusContext(context) else { return .rejected }
    if let existingOrigin = aiChatSendOriginsByThreadID[threadID],
       !aiChatSendOrigin(existingOrigin, belongsTo: context) {
      // Reject before cold hydration can turn a foreign-origin collision into
      // a deferred success. Remote/mobile callers treat a deferred result as
      // accepted, so discovering the collision only in enqueue would silently
      // discard an acknowledged message after hydration completes.
      return .rejected
    }
    if unloadedAIChatThreadIDs.contains(threadID) {
      hydrateAIChatThread(threadID)
      let deferred: Task<AIChatEnqueueOutcome, Never> = Task { @MainActor [weak self] in
        guard let self else { return .rejected }
        let hydrated = await self.hydrateAIChatThreadIfNeeded(threadID)
        guard self.isCurrentAIChatCorpusContext(context) else { return .superseded }
        guard hydrated != nil else { return .rejected }
        let retry = self.submitAIChatMessage(
          text,
          attachments: attachments,
          in: threadID,
          workspaceContext: workspaceContext,
          audience: audience,
          delivery: delivery,
          context: context,
          origin: origin
        )
        return await self.resolveDeferredAIChatEnqueue(retry)
      }
      return .deferred(deferred)
    }
    let destinationThreadID = aiChatDestinationThreadID(
      for: text,
      sourceThreadID: threadID,
      selectsFork: selectedAIChatThreadID == threadID
    )
    if destinationThreadID != threadID {
      return submitAIChatMessage(
        text,
        attachments: attachments,
        in: destinationThreadID,
        workspaceContext: workspaceContext,
        audience: audience,
        delivery: delivery,
        context: context,
        origin: origin
      )
    }
    // An explicit steer (for example from iOS right after the turn started)
    // can arrive before the runtime reports its live session. Keep it a steer
    // and let delivery wait for the session instead of silently queueing it.
    // In a shared room, guidance steers the agent whose turn is running: an
    // un-mentioned message goes to that agent (not the room's default), and a
    // message naming exactly that agent does too. Anything else is queued.
    repairOrphanedAIChatSends(in: threadID)
    let steeringThread = aiChatThreads.first(where: { $0.id == threadID })
    let roomSteerTargets = delivery == .steer && steeringThread?.isSharedRoom == true
      ? steeringThread.map { thread in
          let routing = AIChatDestinationRouting(
            text,
            destinations: enabledAIChatDestinations,
            allDestinationIDs: thread.roomDestinationIDs
          )
          let explicit = routing.destinationIDs.isEmpty
            ? (audience?.runtimes.map(AIChatDestinationConfiguration.defaultID(for:)) ?? [])
            : routing.destinationIDs
          return (explicitDestinationIDs: explicit, normalizedText: routing.normalizedText)
        }
      : nil
    let roomSteerDestinationID = roomSteerTargets.flatMap { targets in
      Self.sharedRoomSteerDestinationID(
        explicitDestinationIDs: targets.explicitDestinationIDs,
        runningDestinationID: activeSharedRoomDestinationByThreadID[threadID]
      )
    }
    let shouldTrySteering = delivery == .steer
      && isAIChatThreadRunning(threadID)
      && (roomSteerTargets == nil || roomSteerDestinationID != nil)
      && aiChatThreadSupportsSteering(threadID, destinationID: roomSteerDestinationID)
    if shouldTrySteering {
      let steerDestinationID = roomSteerDestinationID
        ?? steeringThread?.destinationID
        ?? AIChatDestinationConfiguration.openClawID
      let userMessage = AIChatMessage(
        role: .user,
        content: roomSteerTargets?.normalizedText ?? text,
        attachments: attachments,
        deliveryStatus: .sending,
        deliveryKind: .steer,
        audience: roomSteerDestinationID == nil
          ? audience
          : AIChatAudience(runtime: aiChatDestinationRuntime(steerDestinationID)),
        targetRuntime: roomSteerDestinationID.map(aiChatDestinationRuntime),
        audienceDestinationIDs: roomSteerDestinationID.map { [$0] } ?? [],
        targetDestinationID: roomSteerDestinationID,
        provenance: aiChatUserMessageProvenance(origin: origin, routedTo: nil, at: Date())
      )
      var messages = aiChatMessages(for: threadID)
      messages.append(userMessage)
      replaceAIChatMessages(messages, for: threadID, shouldPersist: true)
      if selectedAIChatThreadID == threadID {
        aiChatStatusText = "Steering \(aiChatDestinationTitle(steerDestinationID))…"
      }
      aiChatInFlightSteerMessageIDs.insert(userMessage.id)
      Task { @MainActor [weak self] in
        await self?.deliverAIChatSteer(
          userMessage,
          in: threadID,
          context: context
        )
      }
      return .enqueued(threadID: threadID, shouldDrain: false)
    }

    let kind: AIChatMessage.DeliveryKind = isAIChatThreadRunning(threadID)
      ? .followUp
      : .turn
    let result = enqueueAIChatMessage(
      text,
      attachments: attachments,
      in: threadID,
      workspaceContext: workspaceContext,
      deliveryKind: kind,
      audience: audience,
      context: context,
      origin: origin
    )
    if case .enqueued(threadID: let acceptedThreadID, shouldDrain: true) = result {
      Task { @MainActor [weak self] in
        await self?.drainAIChatSendQueue(for: acceptedThreadID)
      }
      // Preserve that this enqueue started the drain. Awaited foreground
      // callers may join it, while fire-and-forget callers still rely on the
      // task above to make progress.
      return .enqueued(threadID: acceptedThreadID, shouldDrain: true)
    }
    return result
  }

  /// The agent a shared-room steer reaches. Guidance without an @mention goes
  /// to the agent whose turn is running, not to the room's default agent, so
  /// "steer" works whichever participant is mid-turn. A message naming exactly
  /// one agent steers that agent only if it is the one running; anything else
  /// is queued.
  nonisolated static func sharedRoomSteerDestinationID(
    explicitDestinationIDs: [String],
    runningDestinationID: String?
  ) -> String? {
    switch explicitDestinationIDs.count {
    case 0: return runningDestinationID
    case 1: return explicitDestinationIDs[0]
    default: return nil
    }
  }

  /// Whether this thread's runtime can take live guidance at all, regardless of
  /// whether the current turn's session is ready yet.
  private func aiChatThreadSupportsSteering(_ threadID: UUID, destinationID: String? = nil) -> Bool {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }),
          let target = aiChatSteerTarget(for: thread, destinationID: destinationID),
          aiChatDestination(id: target.destinationID)?.adapter.isDirectProvider != true
    else { return false }
    switch target.runtime {
    case .codex, .openClaw:
      return true
    case .openCode:
      return !openCodeReattachedThreadIDs.contains(threadID)
    case .claude, .pi:
      return aiChatSteerHandlerForTesting != nil
    }
  }

  /// The agent a live steer reaches: the thread's own agent or, in a shared
  /// room, the agent whose turn is running. A room steer must name that
  /// agent; one addressed to another participant cannot steer this turn.
  private func aiChatSteerTarget(
    for thread: AIChatThread,
    destinationID: String?
  ) -> (destinationID: String, runtime: AIChatRuntime)? {
    guard thread.isSharedRoom else { return (thread.destinationID, thread.runtime) }
    guard let destinationID,
          activeSharedRoomDestinationByThreadID[thread.id] == destinationID
    else { return nil }
    return (
      destinationID,
      activeSharedRoomRuntimeByThreadID[thread.id] ?? aiChatDestinationRuntime(destinationID)
    )
  }

  /// Waits briefly for a just-started turn to expose a steerable session.
  private func waitForAIChatSteerReadiness(
    _ threadID: UUID,
    destinationID: String?,
    context: AIChatCorpusContextToken
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: aiChatSteerReadinessTimeout)
    // OpenCode reports its session only once its private server, providers,
    // and MCP servers are up; a managed remote turn first saves durably and
    // connects over SSH. That routinely takes longer than the deadline, and
    // turning the guidance into a queued follow-up then surprises the user.
    // Its session always arrives while this host drives the turn, so wait for
    // that turn. (`isAIChatThreadRunning` alone would also count the pending
    // steer itself and could wait forever.)
    let waitsForWholeTurn = aiChatThreads.first(where: { $0.id == threadID })
      .flatMap { aiChatSteerTarget(for: $0, destinationID: destinationID) }?
      .runtime == .openCode
    while !canSteerAIChatThread(threadID, destinationID: destinationID) {
      guard isCurrentAIChatCorpusContext(context),
            isAIChatThreadRunning(threadID),
            // A shared room moved on to another agent's turn.
            aiChatThreads.first(where: { $0.id == threadID })
              .flatMap({ aiChatSteerTarget(for: $0, destinationID: destinationID) }) != nil,
            waitsForWholeTurn
              ? drainingAIChatThreadIDs.contains(threadID)
              : clock.now < deadline,
            !Task.isCancelled
      else { return false }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return true
  }

  func canSteerAIChatThread(_ threadID: UUID, destinationID: String? = nil) -> Bool {
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }),
          let target = aiChatSteerTarget(for: thread, destinationID: destinationID)
    else {
      return false
    }
    guard aiChatDestination(id: target.destinationID)?.adapter.isDirectProvider != true else {
      return false
    }
    if let aiChatSteerReadinessForTesting { return aiChatSteerReadinessForTesting(threadID) }
    if aiChatSteerHandlerForTesting != nil { return true }
    switch target.runtime {
    case .codex:
      let hasClient = target.destinationID == AIChatDestinationConfiguration.localCodexID
        ? codexAppServerClient != nil
        : codexAppServerClientsByDestinationID[target.destinationID] != nil
      return codexActiveTurnsByThreadID[threadID] != nil && hasClient
    case .openClaw:
      return openClawGatewayClientsByThreadID[threadID] != nil
        && aiChatActiveRunIDByThreadID[threadID] != nil
    case .claude:
      return false
    case .pi:
      return false
    case .openCode:
      return openCodeClientsByDestinationID[target.destinationID] != nil
        && aiChatActiveRunIDByThreadID[threadID] != nil
        && !openCodeReattachedThreadIDs.contains(threadID)
    }
  }

  func deliverAIChatSteer(
    _ message: AIChatMessage,
    in threadID: UUID,
    context: AIChatCorpusContextToken
  ) async {
    aiChatInFlightSteerMessageIDs.insert(message.id)
    defer { aiChatInFlightSteerMessageIDs.remove(message.id) }
    guard isCurrentAIChatCorpusContext(context) else { return }
    guard aiChatThreads.contains(where: { $0.id == threadID }) else { return }
    let roomDestinationID = aiChatThreads.first(where: { $0.id == threadID })?.isSharedRoom == true
      ? message.targetDestinationID
      : nil
    guard await waitForAIChatSteerReadiness(
      threadID,
      destinationID: roomDestinationID,
      context: context
    ) else {
      guard isCurrentAIChatCorpusContext(context),
            aiChatMessages(for: threadID).contains(where: {
              $0.id == message.id && $0.deliveryStatus == .sending
            })
      else { return }
      // The turn ended (or never exposed a live session): deliver the
      // guidance as the next turn rather than dropping it.
      enqueueExistingAIChatMessageAsFollowUp(message.id, in: threadID)
      if selectedAIChatThreadID == threadID {
        aiChatStatusText = isAIChatThreadRunning(threadID)
          ? "Could not reach the live session; queued as a follow-up"
          : "The run finished; queued as a follow-up"
      }
      if !drainingAIChatThreadIDs.contains(threadID) {
        await drainAIChatSendQueue(for: threadID)
      }
      return
    }
    guard let thread = aiChatThreads.first(where: { $0.id == threadID }),
          let target = aiChatSteerTarget(for: thread, destinationID: roomDestinationID)
    else { return }
    do {
      let message = try await Task.detached {
        try AIChatTextAttachments.expanding(message)
      }.value
      guard !Task.isCancelled, isCurrentAIChatCorpusContext(context) else { return }
      if let aiChatSteerHandlerForTesting {
        try await aiChatSteerHandlerForTesting(
          target.runtime,
          threadID,
          message.content,
          message.attachments
        )
      } else {
        switch target.runtime {
        case .codex:
          guard let active = codexActiveTurnsByThreadID[threadID] else {
            throw CodexAppServerError.server(
              code: nil,
              message: "There is no active turn to steer."
            )
          }
          let codexClient = try codexClient(forDestinationID: target.destinationID)
          try await codexClient.steer(
            threadID: active.runtimeThreadID,
            expectedTurnID: active.turnID,
            message: message.content,
            attachments: message.attachments
          )
        case .openClaw:
          guard let gateway = openClawGatewayClientsByThreadID[threadID] else {
            throw OpenClawGatewayError.protocolFailure("there is no live OpenClaw run to steer")
          }
          try await gateway.steer(
            message: Self.expandingOpenClawAgentCommand(
              message,
              corpusSkills: corpusAgentSkillCommands
            ).content,
            attachments: message.attachments,
            idempotencyKey: message.id.uuidString.lowercased()
          )
        case .claude:
          throw ClaudeCodeError.invalidResponse(
            "steering is not available for Claude Code; queue a follow-up instead"
          )
        case .pi:
          throw PiAgentError.invalidResponse(
            "steering is not available for Pi; queue a follow-up instead"
          )
        case .openCode:
          guard let sessionID = aiChatActiveRunIDByThreadID[threadID] else {
            throw OpenCodeError.invalidResponse("there is no active OpenCode turn to steer")
          }
          try await openCodeClient(forDestinationID: target.destinationID).steer(
            openOrgThreadID: threadID,
            sessionID: sessionID,
            message: message.content,
            attachments: message.attachments
          )
        }
      }
      guard isCurrentAIChatCorpusContext(context) else { return }
      replaceAIChatDeliveryStatus(for: message.id, in: threadID, with: .sent)
      if selectedAIChatThreadID == threadID {
        aiChatStatusText = "Guidance sent to \(aiChatDestinationTitle(target.destinationID))"
      }
    } catch {
      guard isCurrentAIChatCorpusContext(context) else { return }
      if shouldQueueAIChatSteerAsFollowUp(after: error, runtime: target.runtime) {
        enqueueExistingAIChatMessageAsFollowUp(message.id, in: threadID)
        if selectedAIChatThreadID == threadID {
          aiChatStatusText = "The run finished; queued as a follow-up"
        }
        if !drainingAIChatThreadIDs.contains(threadID) {
          await drainAIChatSendQueue(for: threadID)
        }
        return
      }
      if target.runtime == .codex,
         Self.codexRuntimeThreadWasStale(after: error) {
        let active = codexActiveTurnsByThreadID[threadID]
        forgetCodexRuntimeThread(
          active?.runtimeThreadID,
          destinationID: target.destinationID,
          in: threadID
        )
        let staleMessage = "\(aiChatDestinationTitle(target.destinationID)) task expired before this guidance could be sent. Retry to start a new turn with this chat context."
        markStaleCodexRunExpired(
          in: threadID,
          destinationID: target.destinationID,
          statusText: "\(aiChatDestinationTitle(target.destinationID)) task expired; retry your last message to continue"
        )
        replaceAIChatMessageDelivery(
          for: message.id,
          in: threadID,
          status: .failed,
          kind: .followUp,
          sendFailure: staleMessage
        )
        return
      }
      replaceAIChatSendFailure(
        for: message.id,
        in: threadID,
        with: "Could not steer \(aiChatDestinationTitle(target.destinationID)): \(error.localizedDescription)"
      )
      if selectedAIChatThreadID == threadID {
        aiChatStatusText = "Could not steer \(aiChatDestinationTitle(target.destinationID))"
      }
    }
  }

  private func shouldQueueAIChatSteerAsFollowUp(
    after error: Error,
    runtime: AIChatRuntime
  ) -> Bool {
    switch runtime {
    case .codex:
      guard let error = error as? CodexAppServerError else { return false }
      switch error {
      case .server(_, let message):
        return message.localizedCaseInsensitiveContains("active turn")
          || message.localizedCaseInsensitiveContains("in progress")
      case .invalidResponse(let message):
        return message.localizedCaseInsensitiveContains("turn/steer")
      case .executableNotFound, .launchFailed, .disconnected, .notAuthenticated,
           .requestTimedOut, .turnStartUnknown, .turnFailed, .turnInterrupted:
        return false
      }
    case .openClaw:
      guard let error = error as? OpenClawGatewayError else { return false }
      let message: String
      switch error {
      case .protocolFailure(let detail), .gateway(_, let detail):
        message = detail
      case .invalidEndpoint, .connection, .sessionConfigurationRejected,
           .emptyResponse, .aborted, .acceptedRunTerminated, .acceptedRunRecovery:
        return false
      }
      return message.localizedCaseInsensitiveContains("active run")
        || message.localizedCaseInsensitiveContains("live run")
        || message.localizedCaseInsensitiveContains("in progress")
    case .claude:
      return false
    case .pi:
      return false
    case .openCode:
      guard let error = error as? OpenCodeError else { return false }
      switch error {
      case .invalidResponse(let message), .launchFailed(let message):
        return message.localizedCaseInsensitiveContains("active OpenCode turn")
          || message.localizedCaseInsensitiveContains("session not found")
      case .executableNotFound, .invalidSSHHost, .missingRemoteWorkspace,
           .turnFailed, .interrupted, .connectionLost, .detachedRunUnavailable:
        return false
      }
    }
  }

  nonisolated private static func codexRuntimeThreadWasStale(after error: Error) -> Bool {
    guard let error = error as? CodexAppServerError else { return false }
    switch error {
    case .server(_, let message), .invalidResponse(let message), .disconnected(let message):
      return codexRuntimeThreadStaleMessage(message)
    case .requestTimedOut(let method):
      return method == "thread/resume"
    case .executableNotFound, .launchFailed, .notAuthenticated, .turnStartUnknown,
         .turnFailed, .turnInterrupted:
      return false
    }
  }

  nonisolated private static func codexRuntimeThreadStaleMessage(_ message: String) -> Bool {
    let lowercased = message.lowercased()
    return lowercased.contains("thread not found")
      || lowercased.contains("task not found")
      || lowercased.contains("does not exist")
      || lowercased.contains("unknown thread")
      || lowercased.contains("unknown task")
  }

  private func forgetCodexRuntimeThread(
    _ runtimeThreadID: String?,
    destinationID: String,
    in threadID: UUID,
    transcriptURL: URL? = nil
  ) {
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    codexActiveTurnsByThreadID.removeValue(forKey: threadID)
    if let runtimeThreadID {
      codexLocalThreadIDsByRuntimeThreadID.removeValue(
        forKey: "\(destinationID)\u{0}\(runtimeThreadID)"
      )
    }
    guard let thread = aiChatThread(
      threadID,
      transcriptURL: targetTranscriptURL
    ) else {
      return
    }
    var runtimeThreadIDs = thread.runtimeThreadIDsByDestination
    var legacyRuntimeThreadID: String?? = nil
    var changed = false
    if let runtimeThreadID,
       runtimeThreadIDs[destinationID] == runtimeThreadID {
      runtimeThreadIDs.removeValue(forKey: destinationID)
      changed = true
    }
    if destinationID == thread.destinationID,
       let runtimeThreadID,
       thread.runtimeThreadID == runtimeThreadID {
      legacyRuntimeThreadID = .some(nil)
      changed = true
    }
    guard changed else { return }
    replaceAIChatThread(
      thread.replacingAIChatMetadata(
        runtimeThreadID: legacyRuntimeThreadID,
        runtimeThreadIDsByDestination: runtimeThreadIDs
      ),
      transcriptURL: targetTranscriptURL
    )
  }

  private func markStaleCodexRunExpired(
    in threadID: UUID,
    destinationID: String,
    transcriptURL: URL? = nil,
    statusText: String
  ) {
    let targetTranscriptURL = transcriptURL ?? aiChatTranscriptURL
    staleCodexRuntimeThreadIDs.insert(threadID)
    cancelAIChatPendingTurnRecovery(for: threadID)
    aiChatDrainTasksByThreadID.removeValue(forKey: threadID)?.task.cancel()

    let failureText = "\(aiChatDestinationTitle(destinationID)) task expired before Celorga could finish receiving it. Retry to start a new task with this chat context."
    var expiredMessageIDs = Set(aiChatPendingUserMessageIDs(for: threadID))
    if let activeMessageID = activeAIChatUserMessageIDByThreadID[threadID] {
      expiredMessageIDs.insert(activeMessageID)
    }
    var messages = aiChatMessages(for: threadID, transcriptURL: targetTranscriptURL)
    var changedMessages = false
    for index in messages.indices where expiredMessageIDs.contains(messages[index].id) {
      let message = messages[index]
      guard message.role == .user,
            message.deliveryStatus == .sending || message.sendFailure != failureText
      else {
        continue
      }
      messages[index] = message.replacingDeliveryStatus(.failed, sendFailure: failureText)
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

    removeAllPendingAIChatUserMessages(in: threadID)
    activeAIChatUserMessageIDByThreadID.removeValue(forKey: threadID)
    drainingAIChatThreadIDs.remove(threadID)
    aiChatRequestStartedAtByThreadID.removeValue(forKey: threadID)
    activeSharedRoomRuntimeByThreadID.removeValue(forKey: threadID)
    activeSharedRoomDestinationByThreadID.removeValue(forKey: threadID)
    clearAIChatCompletedRunPresentation(for: threadID)
    openClawGatewayStateByThreadID[threadID] = .disconnected
    openClawGatewayDetailByThreadID[threadID] = failureText
    if selectedAIChatThreadID == threadID,
       isActiveAIChatTranscript(targetTranscriptURL) {
      aiChatStatusText = statusText
    }
    syncSelectedAIChatSendState()
    // A turn this host lost track of earlier also ran on the expired task.
    repairOrphanedAIChatSends(in: threadID)
  }
}
