import AppKit
import CryptoKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceStore {
  /// A committed derived store remains authoritative while it is valid. If it
  /// is completely unrecoverable, a fully validated legacy monolith may be
  /// displayed so the UI does not silently appear empty. The derived store is
  /// left byte-for-byte intact and writes remain blocked because the monolith
  /// may be older than the last committed derived generation.
  nonisolated static func visibleCanonicalAIChatTranscriptForUnrecoverableStore(
    from url: URL,
    derivedFailure: String,
    marksInterruptedSends: Bool
  ) -> AIChatWorkspaceTranscriptLoad? {
    guard let canonical = validatedCanonicalAIChatTranscript(from: url) else {
      return nil
    }
    var transcript = canonical
    if marksInterruptedSends {
      transcript = aiChatTranscriptStateByMarkingInterruptedSends(transcript)
    }
    let message = "\(derivedFailure) Celorga is displaying \(canonical.threads.count) thread(s) "
      + "from the validated legacy transcript read-only. It may be older than the damaged "
      + "derived store, which was left untouched for recovery."
    return AIChatWorkspaceTranscriptLoad(
      transcript: transcript,
      unloadedThreadIDs: [],
      requiresMigration: false,
      recoveryStatus: .unrecoverable(message)
    )
  }

  nonisolated private static func validatedCanonicalAIChatTranscript(
    from url: URL
  ) -> AIChatTranscriptState? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
          let payload = try? JSONDecoder().decode(AIChatTranscriptPayload.self, from: data),
          (1...6).contains(payload.version)
    else { return nil }

    let transcript: AIChatTranscriptState
    if let threads = payload.threads, !threads.isEmpty {
      transcript = AIChatTranscriptState(
        threads: threads,
        selectedThreadID: payload.selectedThreadID,
        settlementSettings: payload.settlementSettings ?? AIChatThreadSettlementSettings()
      )
    } else if let messages = payload.messages, !messages.isEmpty {
      transcript = aiChatTranscriptState(fromLegacyMessages: messages)
    } else {
      return nil
    }

    let threadIDs = Set(transcript.threads.map(\.id))
    guard threadIDs.count == transcript.threads.count,
          transcript.threads.allSatisfy({ $0.storedMessageCount == nil }),
          transcript.selectedThreadID == nil
            || transcript.selectedThreadID.map(threadIDs.contains) == true
    else { return nil }
    do {
      for thread in transcript.threads {
        for message in thread.messages {
          for attachment in message.attachments {
            _ = try attachment.loadData()
          }
        }
      }
    } catch {
      return nil
    }
    return transcript
  }

  func replaceAIChatMessages(_ messages: [AIChatMessage], shouldPersist: Bool) {
    let previousPersistence = shouldPersistAIChatMessages
    shouldPersistAIChatMessages = false
    isApplyingAIChatThreadMessages = true
    aiChatMessages = messages
    isApplyingAIChatThreadMessages = false
    shouldPersistAIChatMessages = previousPersistence
    if let selectedAIChatThreadID {
      publishedAIChatMessagesIdentity = aiChatMessagesIdentity(
        for: selectedAIChatThreadID
      )
    } else {
      publishedAIChatMessagesIdentity = nil
    }
    if shouldPersist {
      updateSelectedAIChatThread(messages: messages)
      persistAIChatTranscript()
    }
  }

  func migrateAIChatThreadDestinations(_ threads: [AIChatThread]) -> [AIChatThread] {
    threads.map { thread in
      var migrated = thread
      if let destinationID = Self.recoveredNamedCodexDestinationID(
        for: thread,
        destinations: aiChatDestinations
      ) {
        migrated = migrated.replacingAIChatMetadata(destinationID: destinationID)
      }
      if aiChatDestination(id: migrated.destinationID)?.adapter == .openClaw {
        let sessionKey = Self.agentScopedOpenClawSessionKey(
          migrated.sessionKey,
          agentID: openClawAgentID
        )
        if sessionKey != migrated.sessionKey {
          migrated = migrated.replacingAIChatMetadata(sessionKey: sessionKey)
        }
      }
      return migrated
    }
  }

  func applyAIChatTranscript(
    _ transcript: AIChatTranscriptState,
    shouldPersist: Bool,
    allowsMaintenanceWrites: Bool = true
  ) {
    knownAIChatThreadIDsByPath[aiChatTranscriptURL.standardizedFileURL.path, default: []]
      .formUnion(transcript.threads.map(\.id))
    hasAuthoritativeAIChatTranscriptState = true
    aiChatThreadSettlementSettings = transcript.settlementSettings
    let migratedThreads = migrateAIChatThreadDestinations(transcript.threads)
    let answeredTurnRecovery = Self.settlingAnsweredOpenCodeRemoteTurns(in: migratedThreads)
    let unresolvedSteerRecovery = Self.interruptUnresolvedAIChatSteers(
      in: answeredTurnRecovery.threads,
      inFlightSteerIDs: aiChatInFlightSteerMessageIDs
    )
    let restoredThreads = unresolvedSteerRecovery.threads
    let migratedThreadMetadata = zip(transcript.threads, migratedThreads).contains { pair in
      pair.0.sessionKey != pair.1.sessionKey
        || pair.0.destinationID != pair.1.destinationID
    }
    aiChatThreads = Self.sortedAIChatThreadsForDisplay(
      aiChatReadState.applying(to: restoredThreads, transcriptURL: aiChatTranscriptURL)
    )
    rememberCleanAIChatTranscriptMetadata()
    resetAIChatMessageRevisions(for: aiChatThreads)
    let selectedID = [restoredSelectedAIChatThreadID(), transcript.selectedThreadID]
      .compactMap { $0 }
      .first { id in aiChatThreads.contains(where: { $0.id == id }) }
      ?? aiChatThreads.first?.id
    selectedAIChatThreadID = selectedID
    if let selectedID {
      restoreAIChatComposer(for: selectedID)
    } else {
      aiChatDraft = ""
      aiChatPendingAttachments = []
    }
    let autoSettledIDs = allowsMaintenanceWrites ? autoSettleAIChatThreads(shouldPersist: false) : []
    let threads = aiChatThreads
    for thread in threads {
      let messageIDs = thread.messages.compactMap { message in
        message.role == .user
          && (message.deliveryStatus == .sending || message.deliveryIsUnconfirmed)
          && message.deliveryKind != .steer ? message.id : nil
      }
      if messageIDs.isEmpty {
        if !drainingAIChatThreadIDs.contains(thread.id) {
          aiChatPendingUserMessageIDsByThreadID.removeValue(forKey: thread.id)
        }
      } else {
        aiChatPendingUserMessageIDsByThreadID[thread.id] = messageIDs
        // Turns another host runs, and hand-offs not yet accepted here, are
        // visible as pending but are never dispatched from this queue.
        for message in thread.messages where messageIDs.contains(message.id) {
          guard let provenance = message.provenance,
                let executionHostRef = provenance.executionHostRef
          else { continue }
          if provenance.acceptedAt == nil || executionHostRef != aiChatHostIdentity.ref {
            aiChatForeignPendingMessageIDs.insert(message.id)
          }
        }
      }
    }
    let selectedThread = selectedID.flatMap { id in threads.first(where: { $0.id == id }) }
    openClawSessionKey = selectedThread?.sessionKey ?? Self.makeOpenClawSessionKey(agentID: openClawAgentID)
    replaceAIChatMessages(selectedThread?.messages ?? [], shouldPersist: false)
    syncSelectedAIChatSendState()
    if let selectedThread {
      let hasUnknownDelivery = selectedThread.messages.contains {
        $0.role == .user && $0.deliveryIsUnconfirmed
      }
      aiChatStatusText = hasUnknownDelivery
        ? "Codex delivery confirmation is pending"
        : isSendingAIChatMessage
        ? "\(aiChatDestinationTitle(selectedThread.destinationID)) is working"
        : selectedThread.runtime == .codex
          ? "Ready for a Codex message"
          : aiChatDestination(id: selectedThread.destinationID)?.adapter == .openClaw
            ? Self.aiChatStatusText(settings: currentOpenClawSettings())
            : "Ready for a \(aiChatDestinationTitle(selectedThread.destinationID)) message"
    } else {
      aiChatStatusText = Self.aiChatStatusText(settings: currentOpenClawSettings())
    }
    if shouldPersist || (allowsMaintenanceWrites && (
      migratedThreadMetadata
        || unresolvedSteerRecovery.changed
        || answeredTurnRecovery.changed
        || !autoSettledIDs.isEmpty
    )) {
      persistAIChatTranscript()
    }
  }

  /// A managed remote OpenCode reply carries an ID derived from the prompt it
  /// answers, so its presence proves that prompt was delivered. A replica
  /// that reverted the prompt to `sending` (an older revision written by
  /// another host) otherwise leaves the chat "working" forever, with every
  /// later message queued behind a turn that already finished.
  nonisolated static func settlingAnsweredOpenCodeRemoteTurns(
    in threads: [AIChatThread]
  ) -> (threads: [AIChatThread], changed: Bool) {
    var changed = false
    let settled = threads.map { thread -> AIChatThread in
      guard thread.messages.contains(where: {
        $0.role == .user && $0.deliveryStatus == .sending
      }) else { return thread }
      let assistantIDs = Set(thread.messages.lazy.filter { $0.role == .assistant }.map(\.id))
      guard !assistantIDs.isEmpty else { return thread }
      var settledIDs = Set<UUID>()
      let messages = thread.messages.map { message -> AIChatMessage in
        guard message.role == .user,
              message.deliveryStatus == .sending,
              assistantIDs.contains(openCodeRemoteReplyID(for: message.id))
        else { return message }
        settledIDs.insert(message.id)
        return message.replacingDeliveryStatus(.sent, sendFailure: nil)
      }
      guard !settledIDs.isEmpty else { return thread }
      changed = true
      var repaired = thread.replacingMessages(messages)
      if let pendingTurn = repaired.pendingTurn, settledIDs.contains(pendingTurn.userMessageID) {
        repaired = repaired.replacingPendingTurn(nil)
      }
      return repaired
    }
    return (settled, changed)
  }

  /// A steer still `sending` after a reload lost its acknowledgement, unless
  /// this process is still delivering it: a transcript refresh mid-delivery
  /// must not turn live guidance into a failure.
  nonisolated static func interruptUnresolvedAIChatSteers(
    in threads: [AIChatThread],
    inFlightSteerIDs: Set<UUID> = []
  ) -> (threads: [AIChatThread], changed: Bool) {
    var changed = false
    let recovered = threads.map { thread in
      var threadChanged = false
      let messages = thread.messages.map { message in
        guard message.role == .user,
              message.deliveryStatus == .sending,
              message.deliveryKind == .steer,
              !inFlightSteerIDs.contains(message.id)
        else { return message }
        changed = true
        threadChanged = true
        return message.replacingDeliveryStatus(
          .interrupted,
          sendFailure: "This steer was interrupted before its acknowledgement. Retry it to steer the active run again."
        )
      }
      return threadChanged ? thread.replacingMessages(messages) : thread
    }
    return (recovered, changed)
  }

  nonisolated static func recoveredNamedCodexDestinationID(
    for thread: AIChatThread,
    destinations: [AIChatDestinationConfiguration]
  ) -> String? {
    guard !thread.isSharedRoom,
          thread.runtime == .codex,
          thread.destinationID == AIChatDestinationConfiguration.localCodexID
    else { return nil }
    let namedCodexIDs = Set<String>(destinations.compactMap { destination -> String? in
      guard destination.isEnabled,
            destination.runtime == .codex,
            destination.id != AIChatDestinationConfiguration.localCodexID
      else { return nil }
      return destination.id
    })
    return thread.messages.lazy.compactMap { message in
      guard message.role == .user,
            let targetDestinationID = message.targetDestinationID,
            namedCodexIDs.contains(targetDestinationID)
      else { return nil }
      return targetDestinationID
    }.first
  }

  func restoreInterruptedAIChatSendStatusIfNeeded() {
    let interruptedCount = aiChatMessages.filter {
      $0.role == .user && $0.deliveryStatus == .interrupted
    }.count
    guard interruptedCount > 0 else { return }
    let runtime = selectedAIChatRuntime.title
    aiChatStatusText = interruptedCount == 1
      ? "\(runtime) response interrupted; retry the message"
      : "\(interruptedCount) \(runtime) responses interrupted; retry the messages"
  }

  func renderEntrySource(_ source: EntrySource, generation: Int) {
    if URL(fileURLWithPath: source.file).pathExtension.lowercased() == "csv" {
      entryHTMLRenderGeneration += 1
      entryHTMLRenderTask?.cancel()
      entryHTMLRenderTask = nil
      entryHTMLRenderWatchdogTask?.cancel()
      entryHTMLRenderWatchdogTask = nil
      selectedEntryHTML = nil
      selectedEntryRenderError = nil
      selectedEntryHTMLRenderKey = nil
      selectedRenderedBlocks = []
      isSelectedRenderedBlocksReady = false
      selectedBlockID = nil
      isRenderingEntrySource = false
      return
    }

    let renderKey = entryHTMLRenderKey(for: source)
    if selectedEntryHTMLRenderKey != renderKey {
      prepareEntryHTML(for: source)
    }
    entryHTMLRenderGeneration += 1
    let renderGeneration = entryHTMLRenderGeneration
    isRenderingEntrySource = true
    selectedEntryRenderError = nil
    scheduleEntryHTMLRenderWatchdog(
      for: source,
      generation: generation,
      renderGeneration: renderGeneration
    )

    let cachedHTML = renderedHTMLCache[renderKey]?.value.html
    if let cachedHTML {
      renderedHTMLCacheOrder.removeAll { $0 == renderKey }
      renderedHTMLCacheOrder.append(renderKey)
      selectedEntryHTML = cachedHTML
      liveEmbedSourceID = LiveEmbedPresentation.containsEmbeds(cachedHTML) ? source.id : nil
      selectedEntryHTMLRenderKey = renderKey
    }

    let renderIdleDelay = cachedHTML == nil && selectedSurface == .agenda
      ? agendaEntryRenderIdleDelayNanoseconds
      : 0
    entryHTMLRenderTask?.cancel()
    entryHTMLRenderTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if renderIdleDelay > 0 {
        do {
          try await Task.sleep(nanoseconds: renderIdleDelay)
        } catch {
          return
        }
        guard generation == self.entrySourceLoadGeneration,
              renderGeneration == self.entryHTMLRenderGeneration,
              self.selectedEntrySource?.id == source.id,
              self.selectedEntryHTMLRenderKey == renderKey
        else {
          return
        }
      }
      // Publish whichever renderer finishes first. Large native block parses
      // must not hold an already-finished HTML page behind the watchdog.
      let sourceLineOffset = max(0, source.startLine - 1)
      let stylesheetPath = self.appHTMLStylesheetPath
      let corpusRootPath = self.corpusRoot?.path
      let testHTMLRenderer = self.entryHTMLRendererForTesting
      let nativePreparation = self.entryNativeRendererPreparationForTesting
      let cli = self.cli
      let modifiedAt = self.selectedEntrySource?.id == source.id
        ? self.selectedEntrySourceModifiedAt
        : self.corpusFilesByPath[
          URL(fileURLWithPath: source.file).standardizedFileURL.path
        ]?.modifiedAt
      let cachedBlocks = self.cachedRenderedBlocks(for: source, modifiedAt: modifiedAt)
      if let cached = cachedBlocks {
        self.applyRenderedBlocks(cached.blocks, metadata: cached.metadata, for: source)
      }

      await withTaskGroup(of: EntryRenderResult.self) { group in
        if cachedBlocks == nil {
          group.addTask(priority: .userInitiated) {
            if let nativePreparation { await nativePreparation() }
            guard !Task.isCancelled else { return .native([], Self.renderedBlocksMetadata(for: [])) }
            let blocks = OrgEntryRenderer.parseEditable(source.text, baseLine: source.startLine)
            return .native(blocks, Self.renderedBlocksMetadata(for: blocks))
          }
        }
        if cachedHTML == nil {
          group.addTask(priority: .userInitiated) {
            do {
              let html: String
              if let testHTMLRenderer {
                html = try await testHTMLRenderer(
                  source.text,
                  source.file,
                  sourceLineOffset,
                  stylesheetPath
                )
              } else {
                html = try await cli.renderAppHTML(
                  source.text,
                  sourcePath: source.file,
                  sourceLineOffset: sourceLineOffset,
                  stylesheetPath: stylesheetPath,
                  corpusRootPath: corpusRootPath
                )
              }
              return .html(.success(html))
            } catch {
              return .html(.failure(error))
            }
          }
        }

        while let result = await group.next() {
          guard generation == self.entrySourceLoadGeneration,
                renderGeneration == self.entryHTMLRenderGeneration,
                self.selectedEntrySource?.id == source.id,
                self.selectedEntryHTMLRenderKey == renderKey
          else {
            group.cancelAll()
            break
          }

          switch result {
          case .native(let blocks, let blockMetadata):
            guard !Task.isCancelled else { continue }
            self.cacheRenderedBlocks(
              blocks,
              metadata: blockMetadata,
              for: source,
              modifiedAt: modifiedAt
            )
            self.applyRenderedBlocks(blocks, metadata: blockMetadata, for: source)
          case .html(.success(let html)):
            let presentedHTML = Self.applyingPropertyDrawerDefault(
              to: html,
              expanded: self.propertyDrawersExpandedByDefault
            )
            self.cacheRenderedHTML(presentedHTML, key: renderKey)
            self.selectedEntryHTML = presentedHTML
            self.liveEmbedSourceID = LiveEmbedPresentation.containsEmbeds(presentedHTML) ? source.id : nil
            self.selectedEntryRenderError = nil
          case .html(.failure(let error)):
            self.selectedEntryHTML = nil
            self.selectedEntryRenderError = error.localizedDescription
          }
        }
      }

      guard generation == self.entrySourceLoadGeneration,
            renderGeneration == self.entryHTMLRenderGeneration,
            self.selectedEntrySource?.id == source.id,
            self.selectedEntryHTMLRenderKey == renderKey
      else {
        return
      }
      self.entryHTMLRenderWatchdogTask?.cancel()
      self.entryHTMLRenderWatchdogTask = nil
      self.entryHTMLRenderTask = nil
      self.isRenderingEntrySource = false
    }
  }

  private func scheduleEntryHTMLRenderWatchdog(
    for source: EntrySource,
    generation: Int,
    renderGeneration: Int
  ) {
    entryHTMLRenderWatchdogTask?.cancel()
    let timeout = entryHTMLRenderTimeoutNanoseconds
    entryHTMLRenderWatchdogTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: timeout)
      } catch {
        return
      }
      guard let self,
            generation == self.entrySourceLoadGeneration,
            renderGeneration == self.entryHTMLRenderGeneration,
            self.selectedEntrySource?.id == source.id,
            self.selectedEntryHTML == nil,
            (self.selectedEntryRenderError == nil || !self.isSelectedRenderedBlocksReady),
            self.isRenderingEntrySource
      else { return }

      self.entryHTMLRenderGeneration += 1
      self.entryHTMLRenderTask?.cancel()
      self.entryHTMLRenderTask = nil
      self.entryHTMLRenderWatchdogTask = nil
      self.isRenderingEntrySource = false
      let seconds = max(1, Int(ceil(Double(timeout) / 1_000_000_000)))
      let message = "Preview rendering timed out after \(seconds) seconds. Retry to render the file again."
      self.selectedEntryRenderError = message
      self.statusText = "Preview rendering timed out"
      self.errorText = message
    }
  }

  var appHTMLStylesheetPath: String? {
    guard appHTMLStylesheetSnapshot.corpusRootPath == corpusRoot?.standardizedFileURL.path else {
      return nil
    }
    return appHTMLStylesheetSnapshot.path
  }

  nonisolated static func loadAppHTMLStylesheetSnapshot(
    corpusRoot: URL?
  ) -> AppHTMLStylesheetSnapshot {
    let wasBuiltOnMainThread = Thread.isMainThread
    guard let corpusRoot else { return .empty }
    let root = corpusRoot.standardizedFileURL
    let candidates = [
      root.appendingPathComponent(".celorga/app.css"),
      root.appendingPathComponent(".org2/app.css"),
      root.appendingPathComponent("org2-app.css")
    ]
    for candidate in candidates {
      guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
      else { continue }
      let digest = fileContentDigest(for: candidate) ?? "unreadable"
      return AppHTMLStylesheetSnapshot(
        corpusRootPath: root.path,
        path: candidate.path,
        identity: "\(candidate.path)|\(values.fileSize ?? 0)|\(digest)",
        wasBuiltOnMainThread: wasBuiltOnMainThread
      )
    }
    return AppHTMLStylesheetSnapshot(
      corpusRootPath: root.path,
      path: nil,
      identity: "default",
      wasBuiltOnMainThread: wasBuiltOnMainThread
    )
  }

  func publishAppHTMLStylesheetSnapshot(_ snapshot: AppHTMLStylesheetSnapshot) {
    guard snapshot.corpusRootPath == corpusRoot?.standardizedFileURL.path else { return }
    appHTMLStylesheetSnapshotBuildCountForTesting &+= 1
    if snapshot.wasBuiltOnMainThread {
      appHTMLStylesheetSnapshotMainThreadBuildCountForTesting &+= 1
    }
    guard snapshot.path != appHTMLStylesheetSnapshot.path
            || snapshot.identity != appHTMLStylesheetSnapshot.identity
    else { return }
    appHTMLStylesheetSnapshot = snapshot
  }

  func scheduleAppHTMLStylesheetSnapshotRefresh() {
    appHTMLStylesheetSnapshotTask?.cancel()
    appHTMLStylesheetSnapshotGeneration &+= 1
    let generation = appHTMLStylesheetSnapshotGeneration
    let sessionGeneration = corpusSessionGeneration
    let root = corpusRoot
    let preparation = appHTMLStylesheetSnapshotPreparationForTesting
    let didBuild = appHTMLStylesheetSnapshotDidBuildForTesting
    appHTMLStylesheetSnapshotTask = Task { @MainActor [weak self] in
      let snapshot = await Task.detached(priority: .utility) {
        if let root, let preparation {
          await preparation(root)
        }
        let snapshot = Self.loadAppHTMLStylesheetSnapshot(corpusRoot: root)
        didBuild?(root, snapshot.wasBuiltOnMainThread)
        return snapshot
      }.value
      guard let self,
            !Task.isCancelled,
            self.appHTMLStylesheetSnapshotGeneration == generation,
            self.corpusSessionGeneration == sessionGeneration,
            self.corpusRoot?.standardizedFileURL.path == root?.standardizedFileURL.path
      else { return }
      self.publishAppHTMLStylesheetSnapshot(snapshot)
      self.appHTMLStylesheetSnapshotTask = nil
    }
  }

  public var hasAppHTMLStylesheet: Bool {
    appHTMLStylesheetPath != nil
  }

  public func openAppHTMLStylesheet() {
    guard let corpusRoot else {
      statusText = "Open a corpus before customizing document styles"
      return
    }
    let stylesheetURL = CelorgaNames.stateDirectory(corpusRoot: corpusRoot)
      .appendingPathComponent("app.css")
    do {
      try FileManager.default.createDirectory(
        at: stylesheetURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if !FileManager.default.fileExists(atPath: stylesheetURL.path) {
        let template = """
        /* Celorga document overrides. This file only affects HTML read and preview views. */
        :root {
          /* --org2-content-width: 960px; */
          /* --org2-page-padding: 28px; */
          /* --org2-accent: #2f73b7; */
        }
        """
        try template.write(to: stylesheetURL, atomically: true, encoding: .utf8)
      }
      scheduleAppHTMLStylesheetSnapshotRefresh()
      NSWorkspace.shared.open(stylesheetURL)
      statusText = "Opened \(stylesheetURL.deletingLastPathComponent().lastPathComponent)/app.css"
    } catch {
      errorText = error.localizedDescription
      statusText = "Could not open document stylesheet"
    }
  }

  public func retrySelectedEntryRendering() {
    guard let source = selectedEntrySource else {
      guard let selectedLocation else { return }
      selectedEntryRenderError = nil
      scheduleEntrySourceLoad(for: selectedLocation)
      return
    }
    let key = entryHTMLRenderKey(for: source)
    releaseWorkspaceCacheBoxesOffMain(
      renderedHTMLCache.removeValue(forKey: key).map { [$0] } ?? []
    )
    renderedHTMLCacheOrder.removeAll { $0 == key }
    selectedEntryHTML = nil
    selectedEntryRenderError = nil
    selectedEntryHTMLRenderKey = key
    renderEntrySource(source, generation: entrySourceLoadGeneration)
  }

  private func prepareEntryHTML(for source: EntrySource) {
    let renderKey = entryHTMLRenderKey(for: source)
    guard selectedEntryHTMLRenderKey != renderKey else { return }
    entryHTMLRenderGeneration += 1
    selectedEntryHTML = nil
    selectedEntryRenderError = nil
    selectedEntryHTMLRenderKey = renderKey
    selectedRenderedBlocks = []
    isSelectedRenderedBlocksReady = false
    selectedBlockID = nil
  }

  private func workspaceCacheBox<Value: Sendable>(
    _ value: Value
  ) -> WorkspaceCacheBox<Value> {
    WorkspaceCacheBox(value, releaseMetrics: workspaceCacheReleaseMetrics)
  }

  func releaseWorkspaceCacheBoxesOffMain(
    _ boxes: [AnyWorkspaceCacheBox]
  ) {
    workspaceCacheReleaseSink.enqueue(boxes)
  }

  func installWorkspaceDocumentCachePayloadForTesting(
    file: String,
    payload: String
  ) {
    let url = URL(fileURLWithPath: file).standardizedFileURL
    let source = EntrySource(
      file: url.path,
      startLine: 1,
      endLineExclusive: 2,
      text: payload,
      isSubtree: false
    )
    let location = WorkspaceLocation.aiChatThreadRecord(AIChatThreadRecord(
      title: url.lastPathComponent,
      file: url.path,
      line: 1,
      zone: "test",
      modifiedAt: nil
    ))
    cacheEntrySource(
      source,
      for: location,
      mode: .page,
      modifiedAt: nil,
      fileContentDigest: "test-\(payload.utf8.count)",
      fileFreshnessSignature: nil,
      firstOrgID: nil,
      sourceLineIndex: OrgSourceLineIndex()
    )
    cacheRenderedBlocks(
      [],
      metadata: Self.renderedBlocksMetadata(for: []),
      for: source,
      modifiedAt: nil
    )
    cacheRenderedHTML(payload, key: "\(url.path)|test")
  }

  func invalidateWorkspaceDocumentCachesForTesting(file: String) {
    invalidateCanonicalDocumentCache(for: file)
  }

  var workspaceDocumentCacheCountsForTesting: (entrySources: Int, blocks: Int, html: Int) {
    (entrySourceCache.count, renderedBlocksCache.count, renderedHTMLCache.count)
  }

  private func cacheRenderedHTML(_ html: String, key: String) {
    let replaced = renderedHTMLCache.updateValue(
      workspaceCacheBox(RenderedHTMLCacheEntry(html: html)),
      forKey: key
    )
    releaseWorkspaceCacheBoxesOffMain(replaced.map { [$0] } ?? [])
    renderedHTMLCacheOrder.removeAll { $0 == key }
    renderedHTMLCacheOrder.append(key)
    var evictedBoxes: [AnyWorkspaceCacheBox] = []
    while renderedHTMLCacheOrder.count > Self.renderedHTMLCacheLimit {
      let evicted = renderedHTMLCacheOrder.removeFirst()
      if let box = renderedHTMLCache.removeValue(forKey: evicted) {
        evictedBoxes.append(box)
      }
    }
    releaseWorkspaceCacheBoxesOffMain(evictedBoxes)
  }

  nonisolated static func applyingPropertyDrawerDefault(to html: String, expanded: Bool) -> String {
    let drawer = #"<details class="org2-properties-drawer""#
    let expandedDrawer = drawer + " open"
    let normalized = html.replacingOccurrences(of: expandedDrawer, with: drawer)
    guard expanded else { return normalized }
    return normalized.replacingOccurrences(of: drawer, with: expandedDrawer)
  }

  func applyPropertyDrawerDefaultToLoadedHTML() {
    let expanded = propertyDrawersExpandedByDefault
    if let selectedEntryHTML {
      self.selectedEntryHTML = Self.applyingPropertyDrawerDefault(to: selectedEntryHTML, expanded: expanded)
    }
    if let sourceEditorPreviewHTML {
      self.sourceEditorPreviewHTML = Self.applyingPropertyDrawerDefault(
        to: sourceEditorPreviewHTML,
        expanded: expanded
      )
    }
    let replacedCache = renderedHTMLCache
    renderedHTMLCache = replacedCache.mapValues { cached in
      workspaceCacheBox(RenderedHTMLCacheEntry(
        html: Self.applyingPropertyDrawerDefault(to: cached.value.html, expanded: expanded)
      ))
    }
    releaseWorkspaceCacheBoxesOffMain(Array(replacedCache.values))
  }

  func entryHTMLRenderKey(for source: EntrySource) -> String {
    let path = URL(fileURLWithPath: source.file).standardizedFileURL.path
    // Loaded sources receive their file digest on the detached load lane;
    // edited/in-memory sources receive a monotonic revision in didSet. Never
    // hash a multi-megabyte String while building the main-thread view tree.
    let contentIdentity = entrySourceRenderIdentities[source.id]
      ?? "unregistered:\(source.startLine):\(source.endLineExclusive)"
    let stylesheetDigest = appHTMLStylesheetSnapshot.corpusRootPath
      == corpusRoot?.standardizedFileURL.path
      ? appHTMLStylesheetSnapshot.identity
      : "default"
    return "\(path)|\(source.startLine)|\(source.endLineExclusive)|\(contentIdentity)|\(stylesheetDigest)"
  }

  func applyRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    metadata: RenderedBlocksMetadata,
    for source: EntrySource
  ) {
    let visibleBlocks = blocksWithTransientDraft(blocks, for: source)
    let visibleMetadata: RenderedBlocksMetadata
    if transientDraftBlock?.file == source.file {
      visibleMetadata = Self.renderedBlocksMetadata(for: visibleBlocks)
    } else {
      visibleMetadata = metadata
    }
    if selectedRenderedBlocksRenderSignature != visibleMetadata.renderSignature {
      nextSelectedRenderedBlocksMetadata = visibleMetadata
      preservesSelectedRenderedBlocksMetadataForNextAssignment = true
      selectedRenderedBlocks = visibleBlocks
    }
    isSelectedRenderedBlocksReady = true
    if let pending = pendingBlockSelection,
       pending.file == source.file {
      let pendingBlock = blockForSelectionLine(pending.line, mode: pending.mode, in: visibleBlocks)
      selectedBlockID = pendingBlock?.id
      pendingBlockSelection = nil
      if pending.beginEditing,
         let pendingBlock,
         pendingBlock.isEditable,
         source.isEditable {
        beginEditingSource(
          for: pendingBlock,
          selection: pending.initialSourceUTF16Offset.map {
            Self.editableSelection(for: pendingBlock, sourceUTF16Offset: $0)
          }
        )
      }
    } else if let selectedBlockID,
       !visibleBlocks.contains(where: { $0.id == selectedBlockID }) {
      self.selectedBlockID = nil
    }
  }

  func blocksWithTransientDraft(_ blocks: [OrgEditableBlock], for source: EntrySource) -> [OrgEditableBlock] {
    guard let draft = transientDraftBlock, draft.file == source.file else {
      return blocks
    }
    let coveredIDs = Set(draft.coveredBlocks.map(\.id))
    var visibleBlocks = blocks.filter { $0.id != draft.block.id && !coveredIDs.contains($0.id) }
    visibleBlocks.append(draft.block)
    return Self.sortEditableBlocksForDisplay(visibleBlocks)
  }

  private func canonicalDocument(for source: EntrySource) async throws -> Org2CanonicalDocument {
    if source.isSubtree || source.startLine != 1 {
      return try await cli.parseTextJSON(
        source.text,
        sourceRanges: true,
        sourceLineOffset: max(0, source.startLine - 1),
        sourcePath: source.file
      )
    }

    return try await canonicalDocument(for: source.file)
  }

  private func canonicalDocument(for file: String) async throws -> Org2CanonicalDocument {
    let url = URL(fileURLWithPath: file).standardizedFileURL
    let fileContentDigest = await Task.detached(priority: .utility) {
      guard let sourceDigest = Self.fileContentDigest(for: url) else { return Optional<String>.none }
      var directory = url.deletingLastPathComponent()
      while true {
        if let config = CelorgaNames.configFile(in: directory) {
          return sourceDigest + ":" + (Self.fileContentDigest(for: config) ?? "unreadable")
        }
        let parent = directory.deletingLastPathComponent()
        if parent == directory { return sourceDigest }
        directory = parent
      }
    }.value
    let cacheKey = url.path
    if let fileContentDigest,
       let cached = canonicalDocumentCache[cacheKey]?.value,
       cached.fileContentDigest == fileContentDigest {
      touchCanonicalDocumentCacheKey(cacheKey)
      return cached.document
    }

    let document: Org2CanonicalDocument = try await cli.parseFileJSON(url, sourceRanges: true)
    let replaced = canonicalDocumentCache.updateValue(
      workspaceCacheBox(CanonicalDocumentCacheEntry(
        fileContentDigest: fileContentDigest,
        document: document
      )),
      forKey: cacheKey
    )
    releaseWorkspaceCacheBoxesOffMain(replaced.map { [$0] } ?? [])
    touchCanonicalDocumentCacheKey(cacheKey)
    return document
  }

  func invalidateCanonicalDocumentCache(for file: String) {
    let cacheKey = URL(fileURLWithPath: file).standardizedFileURL.path
    releaseWorkspaceCacheBoxesOffMain(
      canonicalDocumentCache.removeValue(forKey: cacheKey).map { [$0] } ?? []
    )
    canonicalDocumentCacheOrder.removeAll { $0 == cacheKey }
    invalidateEntrySourceCache(for: file)
    invalidateRenderedBlocksCache(for: file)
    invalidateRenderedHTMLCache(for: file)
  }

  private func touchCanonicalDocumentCacheKey(_ key: String) {
    var evictedBoxes: [AnyWorkspaceCacheBox] = []
    for evicted in WorkspaceCacheRecency.recordAccess(
      key,
      order: &canonicalDocumentCacheOrder,
      limit: Self.canonicalDocumentCacheLimit
    ) {
      if let box = canonicalDocumentCache.removeValue(forKey: evicted) {
        evictedBoxes.append(box)
      }
    }
    releaseWorkspaceCacheBoxesOffMain(evictedBoxes)
  }

  private func entrySourceCacheKey(for location: WorkspaceLocation, mode: EntrySourceMode) -> String {
    "\(Self.selectionIdentity(for: location))|\(mode.rawValue)"
  }

  func cacheEntrySource(
    _ source: EntrySource,
    for location: WorkspaceLocation,
    mode: EntrySourceMode,
    modifiedAt: Date?,
    fileContentDigest: String?,
    fileFreshnessSignature: FileFreshnessSignature?,
    firstOrgID: String?,
    sourceLineIndex: OrgSourceLineIndex
  ) {
    let key = entrySourceCacheKey(for: location, mode: mode)
    let replaced = entrySourceCache.updateValue(
      workspaceCacheBox(EntrySourceCacheEntry(
        modifiedAt: modifiedAt,
        fileContentDigest: fileContentDigest,
        fileFreshnessSignature: fileFreshnessSignature,
        firstOrgID: firstOrgID,
        sourceLineIndex: sourceLineIndex,
        source: source
      )),
      forKey: key
    )
    releaseWorkspaceCacheBoxesOffMain(replaced.map { [$0] } ?? [])
    entrySourceCacheOrder.removeAll { $0 == key }
    entrySourceCacheOrder.append(key)

    var evictedBoxes: [AnyWorkspaceCacheBox] = []
    while entrySourceCacheOrder.count > Self.entrySourceCacheLimit {
      let evicted = entrySourceCacheOrder.removeFirst()
      if let box = entrySourceCache.removeValue(forKey: evicted) {
        evictedBoxes.append(box)
      }
    }
    releaseWorkspaceCacheBoxesOffMain(evictedBoxes)
  }

  func cachedEntrySource(
    for location: WorkspaceLocation,
    mode: EntrySourceMode
  ) -> EntrySourceCacheEntry? {
    let key = entrySourceCacheKey(for: location, mode: mode)
    guard let cached = entrySourceCache[key]?.value else { return nil }
    let path = URL(fileURLWithPath: location.file).standardizedFileURL.path
    if let catalogFile = corpusFilesByPath[path] {
      if let catalogModifiedAt = catalogFile.modifiedAt,
         cached.modifiedAt != catalogModifiedAt {
        return nil
      }
      if let catalogByteCount = catalogFile.byteCount,
         cached.fileFreshnessSignature.map({ Int64($0.fileSize) }) != catalogByteCount {
        return nil
      }
    }
    entrySourceCacheOrder.removeAll { $0 == key }
    entrySourceCacheOrder.append(key)
    return cached
  }

  func cachedEntrySourceMatchesCurrentFileContents(
    for location: WorkspaceLocation,
    mode: EntrySourceMode
  ) async -> Bool {
    let key = entrySourceCacheKey(for: location, mode: mode)
    guard let cached = entrySourceCache[key]?.value else {
      return false
    }
    let url = URL(fileURLWithPath: location.file).standardizedFileURL
    let expectedSignature = cached.fileFreshnessSignature
    let expectedDigest = cached.fileContentDigest
    let verification: (
      matches: Bool,
      signature: FileFreshnessSignature?,
      usedMetadataFastPath: Bool
    ) = await Task.detached(priority: .utility) { () -> (
      matches: Bool,
      signature: FileFreshnessSignature?,
      usedMetadataFastPath: Bool
    ) in
      let currentSignature = Self.fileFreshnessSignature(for: url)
      if let expectedSignature,
         let currentSignature,
         expectedSignature == currentSignature {
        return (
          matches: true,
          signature: currentSignature,
          usedMetadataFastPath: true
        )
      }
      guard let expectedDigest else {
        return (
          matches: false,
          signature: currentSignature,
          usedMetadataFastPath: false
        )
      }
      return (
        matches: Self.fileContentDigest(for: url) == expectedDigest,
        signature: currentSignature,
        usedMetadataFastPath: false
      )
    }.value
    if verification.usedMetadataFastPath {
      selectedDetailFreshnessMetadataFastPathCountForTesting += 1
    }
    guard verification.matches else { return false }

    // A metadata-only change (for example chmod or touch) may leave the
    // contents intact. Retain the verified current signature so subsequent
    // activations stay on the no-I/O fast path.
    if verification.signature != expectedSignature,
       let current = entrySourceCache[key]?.value,
       current.fileContentDigest == expectedDigest {
      let replaced = entrySourceCache.updateValue(
        workspaceCacheBox(EntrySourceCacheEntry(
          modifiedAt: verification.signature?.contentModificationDate,
          fileContentDigest: current.fileContentDigest,
          fileFreshnessSignature: verification.signature,
          firstOrgID: current.firstOrgID,
          sourceLineIndex: current.sourceLineIndex,
          source: current.source
        )),
        forKey: key
      )
      releaseWorkspaceCacheBoxesOffMain(replaced.map { [$0] } ?? [])
    }
    return true
  }

  private func renderedBlocksCacheKey(for source: EntrySource) -> String {
    let path = URL(fileURLWithPath: source.file).standardizedFileURL.path
    return "\(path)|\(source.startLine)|\(source.endLineExclusive)"
  }

  func cacheRenderedBlocks(
    _ blocks: [OrgEditableBlock],
    metadata: RenderedBlocksMetadata,
    for source: EntrySource,
    modifiedAt: Date?
  ) {
    let key = renderedBlocksCacheKey(for: source)
    let replaced = renderedBlocksCache.updateValue(
      workspaceCacheBox(RenderedBlocksCacheEntry(
        modifiedAt: modifiedAt,
        sourceID: source.id,
        textDigest: entrySourceRenderIdentities[source.id] ?? "unregistered",
        blocks: blocks,
        metadata: metadata
      )),
      forKey: key
    )
    releaseWorkspaceCacheBoxesOffMain(replaced.map { [$0] } ?? [])
    renderedBlocksCacheOrder.removeAll { $0 == key }
    renderedBlocksCacheOrder.append(key)

    var evictedBoxes: [AnyWorkspaceCacheBox] = []
    while renderedBlocksCacheOrder.count > Self.renderedBlocksCacheLimit {
      let evicted = renderedBlocksCacheOrder.removeFirst()
      if let box = renderedBlocksCache.removeValue(forKey: evicted) {
        evictedBoxes.append(box)
      }
    }
    releaseWorkspaceCacheBoxesOffMain(evictedBoxes)
  }

  private func cachedRenderedBlocks(
    for source: EntrySource,
    modifiedAt: Date?
  ) -> RenderedBlocksCacheEntry? {
    let key = renderedBlocksCacheKey(for: source)
    guard let cached = renderedBlocksCache[key]?.value,
          cached.modifiedAt == modifiedAt,
          cached.sourceID == source.id,
          cached.textDigest == (entrySourceRenderIdentities[source.id] ?? "unregistered")
    else {
      return nil
    }
    renderedBlocksCacheOrder.removeAll { $0 == key }
    renderedBlocksCacheOrder.append(key)
    return cached
  }

  static func renderedBlocksSignature(for blocks: [OrgEditableBlock]) -> String {
    guard !blocks.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(blocks.count)
    for block in blocks {
      hasher.combine(block.id)
      hasher.combine(block.startLine)
      hasher.combine(block.endLineExclusive)
      hasher.combine(block.isEditable)
    }
    return "\(blocks.count):\(hasher.finalize())"
  }

  nonisolated static func renderedBlocksMetadata(
    for blocks: [OrgEditableBlock]
  ) -> RenderedBlocksMetadata {
    guard !blocks.isEmpty else {
      return RenderedBlocksMetadata(renderSignature: "empty", structureSignature: "empty", indexes: [:])
    }

    var renderHasher = Hasher()
    var structureHasher = Hasher()
    renderHasher.combine(blocks.count)
    structureHasher.combine(blocks.count)

    var indexes: [OrgEditableBlock.ID: Int] = [:]
    indexes.reserveCapacity(blocks.count)

    for (index, block) in blocks.enumerated() {
      renderHasher.combine(block.renderIdentity.id)
      renderHasher.combine(block.renderIdentity.startLine)
      renderHasher.combine(block.renderIdentity.endLineExclusive)
      renderHasher.combine(block.renderIdentity.rawUTF8Count)
      renderHasher.combine(block.renderIdentity.rawHash)
      renderHasher.combine(block.renderIdentity.renderedKind)
      renderHasher.combine(block.isEditable)

      structureHasher.combine(block.id)
      structureHasher.combine(block.startLine)
      structureHasher.combine(block.endLineExclusive)
      structureHasher.combine(block.isEditable)

      indexes[block.id] = index
    }

    return RenderedBlocksMetadata(
      renderSignature: "\(blocks.count):\(renderHasher.finalize())",
      structureSignature: "\(blocks.count):\(structureHasher.finalize())",
      indexes: indexes
    )
  }

  nonisolated static func renderedBlocksRenderSignature(for blocks: [OrgEditableBlock]) -> String {
    guard !blocks.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(blocks.count)
    for block in blocks {
      hasher.combine(block.renderIdentity.id)
      hasher.combine(block.renderIdentity.startLine)
      hasher.combine(block.renderIdentity.endLineExclusive)
      hasher.combine(block.renderIdentity.rawUTF8Count)
      hasher.combine(block.renderIdentity.rawHash)
      hasher.combine(block.renderIdentity.renderedKind)
      hasher.combine(block.isEditable)
    }
    return "\(blocks.count):\(hasher.finalize())"
  }

  nonisolated static func sourceBlockRunsRenderSignature(for runs: [String: SourceBlockRunState]) -> String {
    guard !runs.isEmpty else { return "empty" }

    var hasher = Hasher()
    hasher.combine(runs.count)
    for key in runs.keys.sorted() {
      guard let state = runs[key] else { continue }
      hasher.combine(key)
      combineSourceBlockRunSignature(state, into: &hasher)
    }
    return "\(runs.count):\(hasher.finalize())"
  }

  nonisolated static func sourceBlockRunRenderSignature(for state: SourceBlockRunState?) -> String? {
    guard let state else { return nil }
    var hasher = Hasher()
    combineSourceBlockRunSignature(state, into: &hasher)
    return hasher.finalize().description
  }

  nonisolated private static func combineSourceBlockRunSignature(
    _ state: SourceBlockRunState,
    into hasher: inout Hasher
  ) {
    hasher.combine(sourceBlockRunStatusSignature(state.status))
    hasher.combine(state.language)
    hasher.combine(state.commandLabel)
    hasher.combine(state.startedAt)
    hasher.combine(state.finishedAt)
    hasher.combine(state.duration)
    hasher.combine(state.exitCode)
    hasher.combine(state.stdout.utf8.count)
    hasher.combine(state.stdout.hashValue)
    hasher.combine(state.stderr.utf8.count)
    hasher.combine(state.stderr.hashValue)
    hasher.combine(state.message)
  }

  nonisolated private static func sourceBlockRunStatusSignature(_ status: SourceBlockRunStatus) -> String {
    switch status {
    case .running: "running"
    case .succeeded: "succeeded"
    case .failed: "failed"
    case .timedOut: "timed-out"
    case .unsupported: "unsupported"
    }
  }

  private static func renderedBlockIndexes(for blocks: [OrgEditableBlock]) -> [OrgEditableBlock.ID: Int] {
    guard !blocks.isEmpty else { return [:] }

    var indexes: [OrgEditableBlock.ID: Int] = [:]
    indexes.reserveCapacity(blocks.count)
    for (index, block) in blocks.enumerated() {
      indexes[block.id] = index
    }
    return indexes
  }

  private func invalidateRenderedBlocksCache(for file: String) {
    let path = URL(fileURLWithPath: file).standardizedFileURL.path + "|"
    let keys = renderedBlocksCache.keys.filter { $0.hasPrefix(path) }
    releaseWorkspaceCacheBoxesOffMain(keys.compactMap { renderedBlocksCache.removeValue(forKey: $0) })
    renderedBlocksCacheOrder.removeAll { key in
      key.hasPrefix(path)
    }
  }

  private func invalidateRenderedHTMLCache(for file: String) {
    let path = URL(fileURLWithPath: file).standardizedFileURL.path + "|"
    let keys = renderedHTMLCache.keys.filter { $0.hasPrefix(path) }
    releaseWorkspaceCacheBoxesOffMain(keys.compactMap { renderedHTMLCache.removeValue(forKey: $0) })
    renderedHTMLCacheOrder.removeAll { $0.hasPrefix(path) }
  }

  private func invalidateEntrySourceCache(for file: String) {
    let path = URL(fileURLWithPath: file).standardizedFileURL.path
    let keys = entrySourceCache.keys.filter { $0.contains("\u{1F}\(path)\u{1F}") }
    releaseWorkspaceCacheBoxesOffMain(keys.compactMap { entrySourceCache.removeValue(forKey: $0) })
    entrySourceCacheOrder.removeAll { key in
      key.contains("\u{1F}\(path)\u{1F}")
    }
  }

  func currentAIChatWorkspaceContext(
    localEditTurnID: String? = nil,
    includesNavigationContext: Bool = true,
    threadContinuation: AIChatThreadContinuation? = nil,
    projectContext: String = "",
    chatAgentRef: String? = nil,
    chatAgentProfile: AgentProfileItem? = nil
  ) -> AIChatWorkspaceContext {
    let source: EntrySource?
    if !includesNavigationContext {
      source = nil
    } else if (isEditingEntry || isLiveFileEditorAvailable), let selectedEntrySource {
      source = EntrySource(
        file: selectedEntrySource.file,
        startLine: selectedEntrySource.startLine,
        endLineExclusive: selectedEntrySource.endLineExclusive,
        text: editableEntryText,
        isSubtree: selectedEntrySource.isSubtree,
        isEditable: selectedEntrySource.isEditable
      )
    } else {
      source = selectedEntrySource
    }

    return AIChatWorkspaceContext(
      localCorpusRoot: corpusRoot?.standardizedFileURL.path,
      remoteCorpusRoot: effectiveOpenClawRemoteCorpusPath(),
      selectedSurface: includesNavigationContext ? selectedSurface.title : WorkspaceSurface.aiChat.title,
      selectedLocation: includesNavigationContext ? selectedLocation : nil,
      selectedEntrySource: source,
      backlinks: includesNavigationContext ? backlinks : nil,
      agenda: includesNavigationContext ? agenda : nil,
      searchQuery: includesNavigationContext ? searchQuery : "",
      searchResults: includesNavigationContext ? searchResults : [],
      agentThreadDirectories: currentOpenClawAgentThreadDirectories(),
      sourceProfiles: sourceProfiles,
      sourceRuntimeStatuses: sourceRuntimeStatuses,
      localEdit: localEditTurnID.map {
        AIChatLocalEditWorkspaceContext(
          nodeDisplayName: openClawLocalEditNodeDisplayName,
          turnID: $0
        )
      },
      authorizedCorpora: currentAIChatCorpusContexts(),
      customInstructions: aiChatCustomInstructions,
      projectContext: projectContext,
      chatAgentRef: chatAgentRef,
      chatAgentProfile: chatAgentProfile,
      threadContinuation: threadContinuation
    )
  }

  /// A conversational turn is scoped to the Org2 chat thread that owns it.
  /// The detail pane can continue showing a file, run, or approval while the
  /// user chats, but that global UI selection must not silently become context
  /// for an established (or unrelated) conversation. Explicit "Ask AI" and
  /// multi-selection context is carried in the user message itself.
  func threadScopedAIChatWorkspaceContext(
    for thread: AIChatThread,
    localEditTurnID: String? = nil,
    includesThreadContinuation: Bool = true
  ) -> AIChatWorkspaceContext {
    currentAIChatWorkspaceContext(
      localEditTurnID: localEditTurnID,
      includesNavigationContext: false,
      threadContinuation: includesThreadContinuation
        ? aiChatThreadContinuation(for: thread)
        : nil,
      projectContext: WorkspaceProjectContext.presentation(projects: projectNotes, threadID: thread.id, mappedPath: mappedPathForOpenClaw),
      chatAgentRef: thread.agentRef,
      chatAgentProfile: agentProfiles.first(where: { $0.id == thread.agentRef })
    )
  }

  func aiChatThreadContinuation(
    for thread: AIChatThread,
    excludingMessageID: UUID? = nil
  ) -> AIChatThreadContinuation {
    let maxMessages = 24
    let maxMessageCharacters = 4_000
    var remainingCharacters = 24_000
    var messages: [AIChatThreadContinuation.Message] = []

    for message in thread.messages.reversed() {
      guard message.id != excludingMessageID else { continue }
      guard messages.count < maxMessages, remainingCharacters > 0 else { break }
      var content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !message.attachments.isEmpty {
        let attachmentText = message.attachments
          .map { "[Attachment: \($0.fileName)]" }
          .joined(separator: "\n")
        content = content.isEmpty ? attachmentText : "\(content)\n\(attachmentText)"
      }
      guard !content.isEmpty else { continue }
      let allowedCharacters = min(maxMessageCharacters, remainingCharacters)
      if content.count > allowedCharacters {
        content = String(content.prefix(allowedCharacters)) + "…"
      }
      messages.append(.init(
        role: message.role.rawValue,
        content: content,
        authorLabel: message.authorLabel
      ))
      remainingCharacters -= content.count
    }

    var references: [String] = []
    var seenPaths = Set<String>()
    func appendReference(_ reference: AIChatFileReference) {
      guard references.count < 12 else { return }
      let localPath = localPathForOpenClawReference(reference.path) ?? reference.path
      let path = mappedPathForOpenClaw(localPath)
      guard seenPaths.insert(path).inserted else { return }
      references.append(reference.line.map { "\(path):\($0)" } ?? path)
    }

    if let resource = thread.resource {
      appendReference(AIChatFileReference(path: resource.file, line: resource.line))
    }
    // Only a user's explicit references establish durable thread context.
    // Assistant citations are useful in the transcript, but treating them as
    // attachments lets one mistaken answer contaminate every later turn.
    for message in thread.messages.reversed()
      where message.id != excludingMessageID
        && message.role == .user
        && references.count < 12 {
      for reference in AIChatFileReference.extract(from: message.content, limit: 12) {
        appendReference(reference)
      }
    }

    return AIChatThreadContinuation(
      id: thread.id,
      title: thread.title,
      messages: Array(messages.reversed()),
      org2References: references
    )
  }

  func workspaceContext(
    _ context: AIChatWorkspaceContext,
    localEditTurnID: String?
  ) -> AIChatWorkspaceContext {
    AIChatWorkspaceContext(
      localCorpusRoot: context.localCorpusRoot,
      remoteCorpusRoot: context.remoteCorpusRoot,
      selectedSurface: context.selectedSurface,
      selectedLocation: context.selectedLocation,
      selectedEntrySource: context.selectedEntrySource,
      backlinks: context.backlinks,
      agenda: context.agenda,
      searchQuery: context.searchQuery,
      searchResults: context.searchResults,
      agentThreadDirectories: context.agentThreadDirectories,
      sourceProfiles: context.sourceProfiles,
      sourceRuntimeStatuses: context.sourceRuntimeStatuses,
      localEdit: localEditTurnID.map {
        AIChatLocalEditWorkspaceContext(
          nodeDisplayName: openClawLocalEditNodeDisplayName,
          turnID: $0
        )
      },
      authorizedCorpora: context.authorizedCorpora,
      customInstructions: context.customInstructions,
      projectContext: context.projectContext,
      chatAgentRef: context.chatAgentRef,
      chatAgentProfile: context.chatAgentProfile,
      threadContinuation: context.threadContinuation
    )
  }

  private func currentAIChatCorpusContexts() -> [AIChatCorpusContext] {
    guard let activeRoot = corpusRoot?.standardizedFileURL else { return [] }
    let activePath = activeRoot.path
    var mounts: [WorkspaceCorpusMount]
    if aiChatCorpusAccessScope == .allCorpora {
      mounts = mountedCorpora
    } else {
      mounts = mountedCorpora.filter {
        URL(fileURLWithPath: $0.path).standardizedFileURL.path == activePath
      }
    }
    if !mounts.contains(where: {
      URL(fileURLWithPath: $0.path).standardizedFileURL.path == activePath
    }) {
      mounts.append(
        WorkspaceCorpusMount(
          path: activePath,
          corpusID: activeCorpusIdentity?.id,
          name: activeCorpusIdentity?.name ?? activeRoot.lastPathComponent,
          kind: activeCorpusIdentity?.kind
        )
      )
    }

    let remotePaths = defaults.dictionary(forKey: openClawRemoteCorpusPathsByCorpusKey)
      as? [String: String] ?? [:]
    return mounts.sorted { lhs, rhs in
      let lhsActive = URL(fileURLWithPath: lhs.path).standardizedFileURL.path == activePath
      let rhsActive = URL(fileURLWithPath: rhs.path).standardizedFileURL.path == activePath
      if lhsActive != rhsActive { return lhsActive }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }.map { mount in
      let localRoot = URL(fileURLWithPath: mount.path).standardizedFileURL.path
      let isActive = localRoot == activePath
      let configuredRemote = remotePaths[localRoot]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let remoteRoot: String?
      if isActive {
        remoteRoot = effectiveOpenClawRemoteCorpusPath()
      } else if let configuredRemote, !configuredRemote.isEmpty {
        remoteRoot = configuredRemote
      } else if openClawEndpointLooksLocal() {
        remoteRoot = localRoot
      } else {
        remoteRoot = nil
      }
      return AIChatCorpusContext(
        name: mount.name,
        kind: mount.kind,
        localRoot: localRoot,
        remoteRoot: remoteRoot,
        isActive: isActive
      )
    }
  }

  private func currentOpenClawAgentThreadDirectories() -> [String] {
    guard let corpusRoot else { return [] }
    return Self.aiChatThreadRecordDirectories(corpusRoot: corpusRoot)
      .map { mappedPathForOpenClaw($0.path) }
  }

  /// Remote corpus path agents may use in links, mapped back to the local
  /// corpus when deriving a thread's outputs.
  var aiChatOutputsRemoteCorpusPath: String? {
    effectiveOpenClawRemoteCorpusPath()
  }

  func effectiveOpenClawRemoteCorpusPath() -> String? {
    let configured = openClawRemoteCorpusPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !configured.isEmpty { return configured }
    if openClawEndpointLooksLocal() {
      return corpusRoot?.standardizedFileURL.path
    }
    return nil
  }

  private func openClawEndpointLooksLocal() -> Bool {
    guard let normalized = OpenClawGatewaySettings.normalizedEndpointString(openClawEndpointText),
          let url = URL(string: normalized),
          let host = url.host?.lowercased()
    else {
      return false
    }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  func localPathForOpenClawReference(_ rawPath: String) -> String? {
    let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }

    var candidates: [String] = []
    if let corpusRoot,
       let remoteRoot = effectiveOpenClawRemoteCorpusPath().map(Self.trimTrailingSlashes) {
      let localRoot = Self.trimTrailingSlashes(corpusRoot.standardizedFileURL.path)
      let normalizedPath = Self.trimTrailingSlashes(path)
      if normalizedPath == remoteRoot {
        candidates.append(localRoot)
      } else if path.hasPrefix(remoteRoot + "/") {
        candidates.append(localRoot + "/" + String(path.dropFirst(remoteRoot.count + 1)))
      }
    }

    if path.hasPrefix("~/") {
      candidates.append(NSHomeDirectory() + "/" + String(path.dropFirst(2)))
    } else if NSString(string: path).isAbsolutePath {
      candidates.append(path)
    } else if let corpusRoot {
      candidates.append(corpusRoot.appendingPathComponent(path).standardizedFileURL.path)
    }

    for candidate in candidates {
      let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
      if FileManager.default.fileExists(atPath: standardized) {
        return standardized
      }
    }
    return nil
  }

  static func trimTrailingSlashes(_ raw: String) -> String {
    var value = raw
    while value.count > 1 && value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }

  nonisolated static func normalizedAssigneeIdentity(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .lowercased()
  }

  nonisolated static func personalAssigneeNames(from text: String) -> Set<String> {
    Set(text
      .split(whereSeparator: { character in
        character == "," || character == ";" || character.isNewline
      })
      .map { normalizedAssigneeIdentity(String($0)) }
      .filter { !$0.isEmpty })
  }

  static func defaultAIChatStatusText() -> String {
    aiChatStatusText(settings: OpenClawGatewaySettings.resolve())
  }

  static func defaultMeetingStatusText() -> String {
    "Local transcription: \(LocalWhisperTranscriber.resolvedBackendDescription())"
  }

  nonisolated static func agentScopedOpenClawSessionKey(_ rawSessionKey: String, agentID: String) -> String {
    let agentID = OpenClawChatClient.openClawAgentHeaderValue(for: agentID)
    var components = rawSessionKey
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ":", omittingEmptySubsequences: false)
      .map(String.init)
    while components.count >= 3 && components[0].localizedCaseInsensitiveCompare("agent") == .orderedSame {
      components.removeFirst(2)
    }
    let body = components.joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedBody = body.isEmpty ? "org2-workspace:\(UUID().uuidString)" : body
    return "agent:\(agentID):\(resolvedBody)"
  }

  nonisolated static func makeOpenClawSessionKey(agentID: String = "main") -> String {
    agentScopedOpenClawSessionKey("org2-workspace:\(UUID().uuidString)", agentID: agentID)
  }

  nonisolated static func aiChatVoiceNoteURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-openclaw-voice", isDirectory: true)
      .appendingPathComponent("\(UUID().uuidString).wav")
  }

  nonisolated static func aiChatImageAttachment(from url: URL) throws -> AIChatAttachment {
    let attachment = try aiChatAttachment(from: url)
    guard attachment.mimeType.hasPrefix("image/") else {
      throw AIChatAttachmentError.unsupportedImage(attachment.fileName)
    }
    return attachment
  }

  nonisolated static func aiChatAttachment(from url: URL) throws -> AIChatAttachment {
    let standardized = url.standardizedFileURL
    let resourceValues = try standardized.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard resourceValues.isRegularFile == true else {
      throw AIChatAttachmentError.notRegularFile(standardized.lastPathComponent)
    }
    if let fileSize = resourceValues.fileSize, fileSize > aiChatAttachmentMaxBytes {
      throw AIChatAttachmentError.tooLarge(
        standardized.lastPathComponent,
        maxMegabytes: aiChatAttachmentMaxBytes / 1_000_000
      )
    }
    let data = try Data(contentsOf: standardized)
    let type = UTType(filenameExtension: standardized.pathExtension)
    let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
    return try aiChatAttachment(
      data: data,
      fileName: standardized.lastPathComponent,
      mimeType: mimeType
    )
  }

  nonisolated static func aiChatAttachment(
    data: Data,
    fileName: String,
    mimeType: String
  ) throws -> AIChatAttachment {
    guard data.count <= aiChatAttachmentMaxBytes else {
      throw AIChatAttachmentError.tooLarge(
        fileName,
        maxMegabytes: aiChatAttachmentMaxBytes / 1_000_000
      )
    }
    let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let type = UTType(mimeType: normalizedMimeType)
      ?? UTType(filenameExtension: URL(fileURLWithPath: fileName).pathExtension)
    if normalizedMimeType.hasPrefix("video/") || type?.conforms(to: .movie) == true {
      throw AIChatAttachmentError.unsupportedVideo(fileName)
    }
    return AIChatAttachment(
      fileName: fileName,
      mimeType: normalizedMimeType.isEmpty ? "application/octet-stream" : normalizedMimeType,
      data: data
    )
  }

  nonisolated private static let aiChatAttachmentMaxBytes = 20_000_000

  nonisolated static func aiChatDraftByAppendingDictation(existing: String, dictatedText: String) -> String {
    let existing = existing.trimmingCharacters(in: .whitespacesAndNewlines)
    let dictatedText = dictatedText.trimmingCharacters(in: .whitespacesAndNewlines)
    if existing.isEmpty { return dictatedText }
    if dictatedText.isEmpty { return existing }
    return "\(existing)\n\n\(dictatedText)"
  }

  nonisolated static func defaultAIChatTranscriptURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base
      .appendingPathComponent("Org2Workspace", isDirectory: true)
      .appendingPathComponent("openclaw-chat.json")
  }

  nonisolated static func aiChatTranscriptURL(corpusRoot: URL) -> URL {
    CelorgaNames.stateDirectory(corpusRoot: corpusRoot.standardizedFileURL)
      .appendingPathComponent("openclaw-chat.json")
  }

  nonisolated static func aiChatInboxDirectory(corpusRoot: URL) -> URL {
    CelorgaNames.stateDirectory(corpusRoot: corpusRoot.standardizedFileURL)
      .appendingPathComponent("ai-chat-inbox", isDirectory: true)
  }

  nonisolated static func aiChatInboxDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  nonisolated private static func loadAIChatMessages(from url: URL) -> [AIChatMessage] {
    let transcript = loadAIChatTranscript(from: url)
    let selectedID = transcript.selectedThreadID
    return selectedID
      .flatMap { id in transcript.threads.first(where: { $0.id == id })?.messages }
      ?? transcript.threads.first?.messages
      ?? []
  }

  nonisolated private static func saveAIChatMessages(_ messages: [AIChatMessage], to url: URL) throws {
    try saveAIChatTranscript(aiChatTranscriptState(fromLegacyMessages: messages), to: url)
  }

  nonisolated static func loadAIChatTranscript(
    from url: URL,
    marksInterruptedSends: Bool = true
  ) -> AIChatTranscriptState {
    guard let data = try? Data(contentsOf: url),
          let payload = try? JSONDecoder().decode(AIChatTranscriptPayload.self, from: data)
    else {
      return AIChatTranscriptState(
        threads: [],
        selectedThreadID: nil,
        settlementSettings: AIChatThreadSettlementSettings()
      )
    }
    if let threads = payload.threads {
      let transcript = AIChatTranscriptState(
        threads: threads,
        selectedThreadID: payload.selectedThreadID,
        settlementSettings: payload.settlementSettings ?? AIChatThreadSettlementSettings()
      )
      return marksInterruptedSends
        ? aiChatTranscriptStateByMarkingInterruptedSends(transcript)
        : transcript
    }
    let transcript = aiChatTranscriptState(fromLegacyMessages: payload.messages ?? [])
    return marksInterruptedSends
      ? aiChatTranscriptStateByMarkingInterruptedSends(transcript)
      : transcript
  }

  nonisolated static func aiChatTranscriptStateByMarkingInterruptedSends(
    _ transcript: AIChatTranscriptState
  ) -> AIChatTranscriptState {
    AIChatTranscriptState(
      threads: transcript.threads.map { thread in
        // Sharded transcripts intentionally keep cold threads as metadata
        // only. Their empty `messages` array does not mean the persisted shard
        // is empty, so never turn that placeholder into a hydrated thread.
        // Pending turns are eagerly hydrated by AIChatTranscriptStore and can
        // still be repaired below.
        guard thread.storedMessageCount == nil else { return thread }
        let hasRecoverablePendingTurn = thread.pendingTurn.map { pendingTurn in
          thread.messages.contains {
            $0.id == pendingTurn.userMessageID
              && $0.role == .user
              && $0.deliveryStatus == .sending
          }
        } ?? false
        if hasRecoverablePendingTurn {
          return thread
        }
        let messages = thread.messages.map { message in
          guard message.role == .user,
                message.deliveryStatus == .sending
          else {
            return message
          }
          // Another host's turn, or a hand-off nobody has started yet, was
          // not interrupted by this process restarting.
          if let provenance = message.provenance,
             let executionHostRef = provenance.executionHostRef,
             provenance.acceptedAt == nil
              || !AIChatLocalHostRegistry.shared.isLocal(executionHostRef) {
            return message
          }
          if message.deliveryIsUnconfirmed {
            return message.replacingDeliveryAttempt(
              message.deliveryAttemptID ?? message.id,
              status: .sending,
              sendFailure: aiChatUnknownSendFailureText,
              attemptState: .unconfirmed
            )
          }
          return message.replacingDeliveryStatus(
            .interrupted,
            sendFailure: aiChatInterruptedSendFailureText
          )
        }
        return thread
          .replacingMessages(messages)
          .replacingPendingTurn(nil)
      },
      selectedThreadID: transcript.selectedThreadID,
      settlementSettings: transcript.settlementSettings
    )
  }

  nonisolated private static func encodedAIChatTranscript(
    _ transcript: AIChatTranscriptState
  ) throws -> Data {
    let payload = AIChatTranscriptPayload(
      version: 6,
      messages: nil,
      threads: transcript.threads,
      selectedThreadID: transcript.selectedThreadID,
      settlementSettings: transcript.settlementSettings
    )
    return try JSONEncoder().encode(payload)
  }

  nonisolated private static func writeAIChatTranscriptData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  nonisolated private static func saveAIChatTranscript(_ transcript: AIChatTranscriptState, to url: URL) throws {
    try writeAIChatTranscriptData(encodedAIChatTranscript(transcript), to: url)
  }

  nonisolated static func aiChatTranscriptState(fromLegacyMessages messages: [AIChatMessage]) -> AIChatTranscriptState {
    guard !messages.isEmpty else {
      return AIChatTranscriptState(
        threads: [],
        selectedThreadID: nil,
        settlementSettings: AIChatThreadSettlementSettings()
      )
    }
    let createdAt = messages.first?.createdAt ?? Date()
    let updatedAt = messages.last?.createdAt ?? createdAt
    let thread = AIChatThread(
      title: aiChatThreadTitle(from: messages),
      createdAt: createdAt,
      updatedAt: updatedAt,
      sessionKey: makeOpenClawSessionKey(),
      messages: messages
    )
    return AIChatTranscriptState(
      threads: [thread],
      selectedThreadID: thread.id,
      settlementSettings: AIChatThreadSettlementSettings()
    )
  }

  nonisolated static func modificationDate(for url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  nonisolated static func fileFreshnessSignature(
    for url: URL
  ) -> FileFreshnessSignature? {
    // Construct a fresh URL so Foundation cannot reuse resource values cached
    // by an earlier file read on the same URL value.
    let currentURL = URL(fileURLWithPath: url.standardizedFileURL.path)
    let keys: Set<URLResourceKey> = [
      .fileSizeKey,
      .contentModificationDateKey,
      .attributeModificationDateKey,
      .fileResourceIdentifierKey,
      .generationIdentifierKey,
    ]
    guard let values = try? currentURL.resourceValues(forKeys: keys),
          let fileSize = values.fileSize
    else {
      return nil
    }
    let fileResourceIdentifier = (values.fileResourceIdentifier as? NSData).map {
      Data(referencing: $0)
    }
    let generationIdentifier = (values.generationIdentifier as? NSData).map {
      Data(referencing: $0)
    }
    return FileFreshnessSignature(
      fileSize: fileSize,
      contentModificationDate: values.contentModificationDate,
      attributeModificationDate: values.attributeModificationDate,
      fileResourceIdentifier: fileResourceIdentifier,
      generationIdentifier: generationIdentifier
    )
  }

  nonisolated static func fileContentDigest(for url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
      return nil
    }
    return contentDigest(for: data)
  }

  nonisolated static func contentDigest(for data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  nonisolated static func executeSourceBlock(
    _ source: OrgEditableSourceBlock,
    plan: SourceBlockRunPlan,
    workingDirectory: URL?,
    timeout: TimeInterval = 12,
    maxOutputCharacters: Int = 20_000
  ) throws -> SourceBlockExecutionResult {
    let fileManager = FileManager.default
    let tempDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("org2-source-run-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(at: tempDirectory)
    }

    let scriptURL = tempDirectory.appendingPathComponent("block.\(plan.scriptExtension)")
    try source.body.write(to: scriptURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: plan.executable)
    process.arguments = plan.arguments + [scriptURL.path]
    if let workingDirectory {
      process.currentDirectoryURL = workingDirectory
    }
    process.environment = ProcessInfo.processInfo.environment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    let stdoutCollector = SourceRunOutputCollector()
    let stderrCollector = SourceRunOutputCollector()
    let readGroup = DispatchGroup()

    try process.run()

    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stdoutCollector.set(stdout.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }
    readGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stderrCollector.set(stderr.fileHandleForReading.readDataToEndOfFile())
      readGroup.leave()
    }

    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false
    while process.isRunning {
      if Date() >= deadline {
        timedOut = true
        process.terminate()
        break
      }
      Thread.sleep(forTimeInterval: 0.03)
    }

    if timedOut {
      let terminationDeadline = Date().addingTimeInterval(1)
      while process.isRunning && Date() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.03)
      }
    }

    if process.isRunning {
      process.interrupt()
    }
    process.waitUntilExit()
    readGroup.wait()

    return SourceBlockExecutionResult(
      exitCode: process.terminationStatus,
      stdout: truncateOutput(String(data: stdoutCollector.data, encoding: .utf8) ?? "", maxCharacters: maxOutputCharacters),
      stderr: truncateOutput(String(data: stderrCollector.data, encoding: .utf8) ?? "", maxCharacters: maxOutputCharacters),
      timedOut: timedOut,
      timeout: timeout
    )
  }

  nonisolated private static func truncateOutput(_ text: String, maxCharacters: Int) -> String {
    guard text.count > maxCharacters else { return text }
    let prefix = text.prefix(maxCharacters)
    return "\(prefix)\n...[truncated \(text.count - maxCharacters) characters]"
  }

  static func aiChatStatusText(settings: OpenClawGatewaySettings) -> String {
    if settings.chatCompletionsEnabled != true {
      return "OpenClaw chat endpoint may need enabling in the local gateway config"
    }
    return "OpenClaw gateway: \(settings.endpoint.host ?? settings.endpoint.absoluteString)"
  }

  func orgCryptStatusText(settings: OrgCryptSettings) -> String {
    var parts = [settings.encryptOnSave ? "Encrypt on save" : "Manual encryption"]
    if settings.passphrase != nil || orgCryptHasStoredPassphrase {
      parts.append("passphrase configured")
    }
    if settings.useDefaultGpgKey {
      parts.append("default GPG key")
    }
    if !settings.recipients.isEmpty {
      parts.append("\(settings.recipients.count) recipient\(settings.recipients.count == 1 ? "" : "s")")
    }
    if !settings.recipientFiles.isEmpty {
      parts.append("\(settings.recipientFiles.count) recipient file\(settings.recipientFiles.count == 1 ? "" : "s")")
    }
    parts.append("GPG: \(settings.gpgProgram)")
    return parts.joined(separator: " • ")
  }

  nonisolated static func installWhisperCppAndDefaultModel() throws {
    let fileManager = FileManager.default
    let brewCandidates = [
      "/opt/homebrew/bin/brew",
      "/usr/local/bin/brew"
    ]
    guard let brew = brewCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
      throw AudioSettingsError.homebrewNotFound
    }

    let modelURL = LocalWhisperTranscriber.defaultWhisperCppModelURL
    try fileManager.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let command = [
      "\(shellQuote(brew)) install whisper-cpp",
      "mkdir -p \(shellQuote(modelURL.deletingLastPathComponent().path))",
      "curl -fL --retry 3 --continue-at - --output \(shellQuote(modelURL.path)) \(shellQuote(LocalWhisperTranscriber.defaultWhisperCppModelDownloadURL.absoluteString))"
    ].joined(separator: " && ")

    let result = runAudioSettingsShellCommand(command)
    guard result.exitCode == 0 else {
      throw AudioSettingsError.installFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }
  }

  nonisolated private static func runAudioSettingsShellCommand(_ command: String) -> AudioSettingsProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    var environment = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    if let existing = environment["PATH"], !existing.isEmpty {
      environment["PATH"] = "\(defaultPath):\(existing)"
    } else {
      environment["PATH"] = defaultPath
    }
    process.environment = environment

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    do {
      try process.run()
      let outputData = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let text = String(data: outputData, encoding: .utf8) ?? ""
      return AudioSettingsProcessResult(
        exitCode: process.terminationStatus,
        stdout: text,
        stderr: text
      )
    } catch {
      return AudioSettingsProcessResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
    }
  }

  nonisolated static func runAudioSettingsProcess(
    executable: String,
    arguments: [String]
  ) -> AudioSettingsProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
      let outputData = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let text = String(data: outputData, encoding: .utf8) ?? ""
      try? output.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
      return AudioSettingsProcessResult(
        exitCode: process.terminationStatus,
        stdout: text,
        stderr: text
      )
    } catch {
      try? output.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
      return AudioSettingsProcessResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
    }
  }

  nonisolated private static func shellQuote(_ raw: String) -> String {
    "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  func syncAgendaSelectionAfterRefresh(preserveSelection _: Bool = false) {
    let items = visibleAgendaItems
    pruneAgendaBulkSelection(visibleItems: items)
    guard !items.isEmpty else { return }

    if let selectedAgendaItemID, let item = items.first(where: { $0.id == selectedAgendaItemID }) {
      agendaSelectionAnchor = AgendaSelectionAnchor(item: item)
      if case .agenda = selectedLocation {
        // Refreshes reconcile the detail's value without navigating or
        // restarting its preview. Selection belongs to the user, not to the
        // parser/render lifecycle.
        selectedLocation = .agenda(item)
      }
      return
    }

    if let anchoredItem = agendaSelectionAnchor.flatMap({ agendaItem(matching: $0, in: items) }) {
      selectAgendaItemWithoutActivatingEntry(anchoredItem)
      if case .agenda = selectedLocation {
        selectedLocation = .agenda(anchoredItem)
      }
      return
    }

    // A transient parse, filter, sync, or line-number shift must not clear or
    // replace an existing highlight. Preserve its anchor until that same item
    // is visible again. Only establish an initial selection when none exists.
    guard selectedAgendaItemID == nil, agendaSelectionAnchor == nil else { return }
    if selectedSurface == .agenda {
      selectAgendaItem(items[0])
    }
  }

  func agendaItem(
    matching anchor: AgendaSelectionAnchor,
    in items: [AgendaItem]
  ) -> AgendaItem? {
    let sameFile = items.filter {
      URL(fileURLWithPath: $0.file).standardizedFileURL.path == anchor.file
    }
    if let idValue = anchor.idValue,
       let stableIDMatch = sameFile.first(where: {
         $0.idValue?.trimmingCharacters(in: .whitespacesAndNewlines) == idValue
       }) {
      return stableIDMatch
    }

    let semanticMatches = sameFile.filter {
      $0.headline == anchor.headline && $0.kind == anchor.kind
    }
    return semanticMatches.min {
      abs($0.line - anchor.line) < abs($1.line - anchor.line)
    }
  }

  func pruneAgendaBulkSelection(visibleItems: [AgendaItem]? = nil) {
    guard !bulkSelectedAgendaItemIDs.isEmpty else { return }
    let visibleIDs = Set((visibleItems ?? visibleAgendaItems).map(\.id))
    let prunedIDs = bulkSelectedAgendaItemIDs.intersection(visibleIDs)
    if prunedIDs != bulkSelectedAgendaItemIDs {
      bulkSelectedAgendaItemIDs = prunedIDs
    }
  }

  func updateAgendaBulkSelectionStatusText() {
    let count = bulkAgendaSelectionCount
    statusText = count == 1 ? "1 agenda item selected" : "\(count) agenda items selected"
  }

  func selectedAgendaItemsForBulkMutation() -> [AgendaItem] {
    guard !bulkSelectedAgendaItemIDs.isEmpty else { return [] }
    let items = visibleAgendaItems
    pruneAgendaBulkSelection(visibleItems: items)
    guard !bulkSelectedAgendaItemIDs.isEmpty else { return [] }
    return items.filter { bulkSelectedAgendaItemIDs.contains($0.id) }
  }

  func selectedAgendaItemForMutation() -> AgendaItem? {
    if let selectedAgendaItemID {
      return visibleAgendaItems.first(where: { $0.id == selectedAgendaItemID })
    }
    if case .agenda(let item) = selectedLocation {
      return item
    }
    return visibleAgendaItems.first
  }

  func agendaMutationOrder(_ items: [AgendaItem]) -> [AgendaItem] {
    items.sorted { lhs, rhs in
      if lhs.file == rhs.file {
        if lhs.lineForEditor == rhs.lineForEditor {
          return lhs.id < rhs.id
        }
        return lhs.lineForEditor > rhs.lineForEditor
      }
      return lhs.file < rhs.file
    }
  }

  func preserveAgendaSelectionAfterTodoMutation(
    target: HeadlineMutationTarget,
    originalVisibleIndex: Int?,
    shouldAdvanceSelection: Bool,
    originatingSurface: WorkspaceSurface
  ) {
    guard originatingSurface == .agenda, selectedSurface == .agenda else { return }
    guard let agendaItemID = target.agendaItemID else { return }
    if shouldAdvanceSelection,
       selectNextActionableAgendaItem(afterMutating: agendaItemID, originalVisibleIndex: originalVisibleIndex) {
      return
    }

    if let item = visibleAgendaItems.first(where: { $0.id == agendaItemID }) {
      preserveAgendaItemSelectionWithoutActivatingEntry(item)
    }
  }

  func preserveAgendaItemSelectionWithoutActivatingEntry(_ item: AgendaItem) {
    if selectedAgendaItemID != item.id {
      selectAgendaItemWithoutActivatingEntry(item)
    }
  }

  @discardableResult
  private func selectNextActionableAgendaItem(afterMutating mutatedID: String, originalVisibleIndex: Int?) -> Bool {
    guard let item = Self.nextActionableAgendaItem(
      afterMutating: mutatedID,
      originalVisibleIndex: originalVisibleIndex,
      in: visibleAgendaItems
    ) else {
      return false
    }
    selectAgendaItemWithoutActivatingEntry(item)
    return true
  }

  nonisolated static func nextActionableAgendaItem(
    afterMutating mutatedID: String,
    originalVisibleIndex: Int?,
    in items: [AgendaItem]
  ) -> AgendaItem? {
    guard !items.isEmpty else { return nil }
    let actionableItems = items.enumerated().filter { _, item in
      item.id != mutatedID && item.isActionable
    }
    guard !actionableItems.isEmpty else { return nil }

    let anchor = originalVisibleIndex ?? 0
    return (actionableItems.first { offset, _ in
      offset >= anchor
    } ?? actionableItems.last)?.element
  }

  nonisolated static func isTerminalTodoStatus(_ status: String) -> Bool {
    let normalized = status.uppercased()
    return normalized == "DONE" || normalized == "CANCELED" || normalized == "CANCELLED"
  }

  func syncAIChatSelectionAfterRefresh() {
    guard !aiChatThreadRecords.isEmpty,
          case .aiChatThreadRecord = selectedLocation
    else {
      return
    }
    if let selectedAIChatThreadRecordID,
       let thread = aiChatThreadRecords.first(where: { $0.id == selectedAIChatThreadRecordID }) {
      select(.aiChatThreadRecord(thread))
    }
  }

  nonisolated static func entrySource(file: String, line: Int) throws -> EntrySource {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let normalized = normalizeLineEndings(raw)
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else {
      return EntrySource(file: file, startLine: 1, endLineExclusive: 1, text: "", isSubtree: false, isEditable: false)
    }

    let targetIndex = max(0, min(lines.count - 1, line - 1))
    if let headingIndex = headingIndex(in: lines, atOrBefore: targetIndex),
       let level = headingLevel(lines[headingIndex]) {
      let endIndex = subtreeEndIndex(lines: lines, headingIndex: headingIndex, level: level)
      let text = lines[headingIndex..<endIndex].joined(separator: "\n")
      return EntrySource(
        file: file,
        startLine: headingIndex + 1,
        endLineExclusive: endIndex + 1,
        text: text,
        isSubtree: true
      )
    }

    let text = lines[targetIndex]
    return EntrySource(
      file: file,
      startLine: targetIndex + 1,
      endLineExclusive: targetIndex + 2,
      text: text,
      isSubtree: false,
      isEditable: true
    )
  }

  nonisolated static func pageSource(file: String) throws -> EntrySource {
    let url = URL(fileURLWithPath: file)
    let raw = try String(contentsOf: url, encoding: .utf8)
    let normalized = normalizeLineEndings(raw)
    let endLineExclusive = max(2, lineCount(in: normalized) + 1)
    return EntrySource(
      file: file,
      startLine: 1,
      endLineExclusive: endLineExclusive,
      text: normalized,
      isSubtree: false,
      isEditable: true
    )
  }

  nonisolated static func lineCount(in text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return text.reduce(1) { count, character in
      character == "\n" ? count + 1 : count
    }
  }

  nonisolated static func lineBreakCount(in text: String) -> Int {
    text.reduce(0) { count, character in
      character == "\n" ? count + 1 : count
    }
  }

  nonisolated static func fileText(file: String) throws -> String {
    try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
  }

  nonisolated static func writeOrgTextSafely(
    _ text: String,
    to url: URL,
    replacing previousText: String,
    operation: String,
    allowDestructiveReplacement: Bool = false
  ) throws {
    let assessment = orgFileWriteSafetyAssessment(
      url: url,
      previousText: previousText,
      nextText: text
    )
    var backupPath: String?

    if let assessment {
      let backupURL = try writeOrgRecoveryBackup(
        for: url,
        previousText: previousText,
        reason: assessment.reason
      )
      backupPath = backupURL.path
    }

    if assessment?.shouldBlock == true, !allowDestructiveReplacement {
      throw WorkspaceEditError.destructiveWriteBlocked(
        file: url.path,
        backup: backupPath,
        operation: operation
      )
    }

    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  nonisolated private static func orgFileWriteSafetyAssessment(
    url: URL,
    previousText: String,
    nextText: String
  ) -> (reason: String, shouldBlock: Bool)? {
    guard isOrgTextFile(url),
          !url.pathComponents.contains(".org2-recovery")
    else {
      return nil
    }

    let previous = normalizeLineEndings(previousText)
    let next = normalizeLineEndings(nextText)
    guard !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }

    if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return ("empty-write", true)
    }

    let previousByteCount = previous.utf8.count
    let nextByteCount = next.utf8.count
    if previousByteCount >= 8192,
       nextByteCount < max(512, previousByteCount / 20) {
      return ("large-shrink", false)
    }

    return nil
  }

  nonisolated static func isOrgTextFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ext == "org" || ext == "org2"
  }

  nonisolated static func containsOrgSyntaxSugar(_ text: String) -> Bool {
    text.contains("`")
      || text.range(of: #"(?im)^\s*#\+begin_org2\b"#, options: .regularExpression) != nil
  }

  nonisolated static func writeOrgRecoveryBackup(
    for url: URL,
    previousText: String,
    reason: String
  ) throws -> URL {
    let backupDirectory = url
      .deletingLastPathComponent()
      .appendingPathComponent(".org2-recovery", isDirectory: true)
    try FileManager.default.createDirectory(
      at: backupDirectory,
      withIntermediateDirectories: true
    )

    let sanitizedFileName = url.lastPathComponent.replacingOccurrences(
      of: #"[^A-Za-z0-9._-]+"#,
      with: "-",
      options: .regularExpression
    )
    let sanitizedReason = reason.replacingOccurrences(
      of: #"[^A-Za-z0-9._-]+"#,
      with: "-",
      options: .regularExpression
    )
    let baseName = "\(sanitizedFileName).before-\(sanitizedReason).\(orgRecoveryTimestamp())"
    var backupURL = backupDirectory.appendingPathComponent(baseName)
    var collisionIndex = 1
    while FileManager.default.fileExists(atPath: backupURL.path) {
      backupURL = backupDirectory.appendingPathComponent("\(baseName).\(collisionIndex)")
      collisionIndex += 1
    }
    try previousText.write(to: backupURL, atomically: true, encoding: .utf8)
    return backupURL
  }

  nonisolated private static func orgRecoveryTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  nonisolated static func entrySource(_ source: EntrySource, replacingText replacement: String) -> EntrySource {
    let normalized = normalizeLineEndings(replacement)
    return EntrySource(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.startLine + max(1, lineCount(in: normalized)),
      text: normalized,
      isSubtree: source.isSubtree,
      isEditable: source.isEditable
    )
  }

  nonisolated static func replacingSourceBlock(
    _ block: OrgEditableBlock,
    in source: EntrySource,
    with replacement: String
  ) throws -> EntrySource {
    try replacingSourceRange(
      in: source,
      startLine: block.startLine,
      endLineExclusive: block.endLineExclusive,
      replacement: replacement
    )
  }

  nonisolated static func replacingSourceRange(
    in source: EntrySource,
    startLine: Int,
    endLineExclusive: Int,
    replacement: String
  ) throws -> EntrySource {
    var lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let startIndex = startLine - source.startLine
    let endIndex = endLineExclusive - source.startLine
    guard startIndex >= 0,
          startIndex <= lines.count,
          endIndex >= startIndex,
          endIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: startLine)
    }

    let normalizedReplacement = normalizeLineEndings(replacement)
    let replacementLines = normalizedReplacement.isEmpty
      ? []
      : normalizedReplacement
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    lines.replaceSubrange(startIndex..<endIndex, with: replacementLines)

    return EntrySource(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.startLine + lines.count,
      text: lines.joined(separator: "\n"),
      isSubtree: source.isSubtree,
      isEditable: source.isEditable
    )
  }

  nonisolated static func sourceText(
    in source: EntrySource,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> String {
    let lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let startIndex = startLine - source.startLine
    let endIndex = endLineExclusive - source.startLine
    guard startIndex >= 0,
          startIndex <= lines.count,
          endIndex >= startIndex,
          endIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: startLine)
    }
    return lines[startIndex..<endIndex].joined(separator: "\n")
  }

  nonisolated static func sourceText(
    file: String,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> String {
    try sourceText(
      in: pageSource(file: file),
      startLine: startLine,
      endLineExclusive: endLineExclusive
    )
  }

  nonisolated static func deletingSourceRangeCleaningAdjacentBlank(
    in source: EntrySource,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> (source: EntrySource, startLine: Int, endLineExclusive: Int) {
    var lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let range = try adjustedDeletionRangeCleaningAdjacentBlank(
      in: lines,
      baseLine: source.startLine,
      file: source.file,
      startLine: startLine,
      endLineExclusive: endLineExclusive
    )
    lines.replaceSubrange(range.startIndex..<range.endIndex, with: [])

    return (
      source: EntrySource(
        file: source.file,
        startLine: source.startLine,
        endLineExclusive: source.startLine + lines.count,
        text: lines.joined(separator: "\n"),
        isSubtree: source.isSubtree,
        isEditable: source.isEditable
      ),
      startLine: range.startLine,
      endLineExclusive: range.endLineExclusive
    )
  }

  nonisolated static func deletionRange(
    for block: OrgEditableBlock,
    in source: EntrySource
  ) throws -> (startLine: Int, endLineExclusive: Int) {
    guard case .heading = block.rendered else {
      return (block.startLine, block.endLineExclusive)
    }

    let lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let headingIndex = block.startLine - source.startLine
    guard headingIndex >= 0,
          headingIndex < lines.count,
          let level = headingLevel(lines[headingIndex])
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: block.startLine)
    }

    let endIndex = subtreeEndIndex(lines: lines, headingIndex: headingIndex, level: level)
    return (
      startLine: block.startLine,
      endLineExclusive: source.startLine + endIndex
    )
  }

  nonisolated static func renderedTextSelectionPairs(
    _ fragments: [RenderedTextSelectionFragment],
    in blocks: [OrgEditableBlock]
  ) -> [(fragment: RenderedTextSelectionFragment, block: OrgEditableBlock)] {
    var seenBlockIDs = Set<String>()
    var pairs: [(fragment: RenderedTextSelectionFragment, block: OrgEditableBlock)] = []
    var blocksByID: [OrgEditableBlock.ID: OrgEditableBlock] = [:]
    var blocksByRange: [String: OrgEditableBlock] = [:]
    blocksByID.reserveCapacity(blocks.count)
    blocksByRange.reserveCapacity(blocks.count)
    for block in blocks {
      blocksByID[block.id] = block
      blocksByRange["\(block.startLine):\(block.endLineExclusive)"] = block
    }

    for fragment in fragments {
      guard let block = blocksByID[fragment.blockID]
        ?? blocksByRange["\(fragment.startLine):\(fragment.endLineExclusive)"]
      else {
        continue
      }
      guard seenBlockIDs.insert(block.id).inserted else { continue }
      pairs.append((fragment, block))
    }

    return pairs.sorted { lhs, rhs in
      if lhs.block.startLine != rhs.block.startLine {
        return lhs.block.startLine < rhs.block.startLine
      }
      return lhs.fragment.sourceRange.location < rhs.fragment.sourceRange.location
    }
  }

  nonisolated static func renderedTextSelectionReplacement(
    pairs: [(fragment: RenderedTextSelectionFragment, block: OrgEditableBlock)],
    allBlocks: [OrgEditableBlock],
    in source: EntrySource,
    replacementText: String
  ) throws -> (
    startLine: Int,
    endLineExclusive: Int,
    replacement: String,
    expectedOriginal: String,
    updatedSource: EntrySource,
    caretSourceUTF16Offset: Int,
    coversWholeDocument: Bool
  ) {
    let sortedPairs = pairs.sorted { lhs, rhs in
      if lhs.block.startLine != rhs.block.startLine {
        return lhs.block.startLine < rhs.block.startLine
      }
      return lhs.fragment.sourceRange.location < rhs.fragment.sourceRange.location
    }
    guard let firstPair = sortedPairs.first,
          let lastPair = sortedPairs.last
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: source.startLine)
    }

    let coversWholeDocument = selectionCoversWholeRenderedTextDocument(
      pairs: sortedPairs,
      allBlocks: allBlocks
    )
    let startLine = coversWholeDocument ? source.startLine : firstPair.block.startLine
    let endLineExclusive = coversWholeDocument ? source.endLineExclusive : lastPair.block.endLineExclusive
    let normalizedReplacementText = normalizeLineEndings(replacementText)
    let replacementUTF16Length = (normalizedReplacementText as NSString).length
    let replacement: String
    let caretSourceUTF16Offset: Int

    if coversWholeDocument {
      replacement = normalizedReplacementText
      caretSourceUTF16Offset = replacementUTF16Length
    } else if sortedPairs.count == 1 {
      let rawText = sourceTextForSelectionFragment(firstPair.fragment, block: firstPair.block)
      let range = clampedRange(firstPair.fragment.sourceRange, in: rawText)
      replacement = replacingSelection(
        in: rawText,
        fragment: firstPair.fragment,
        replacementText: normalizedReplacementText
      )
      caretSourceUTF16Offset = firstPair.fragment.selectsEntireEditor
        ? replacementUTF16Length
        : range.location + replacementUTF16Length
    } else {
      let firstRawText = sourceTextForSelectionFragment(firstPair.fragment, block: firstPair.block)
      let lastRawText = sourceTextForSelectionFragment(lastPair.fragment, block: lastPair.block)
      let firstRange = clampedRange(firstPair.fragment.sourceRange, in: firstRawText)
      let lastRange = clampedRange(lastPair.fragment.sourceRange, in: lastRawText)
      let firstPrefix = firstPair.fragment.selectsEntireEditor
        ? ""
        : (firstRawText as NSString).substring(to: firstRange.location)
      let lastSuffix = lastPair.fragment.selectsEntireEditor
        ? ""
        : (lastRawText as NSString).substring(from: NSMaxRange(lastRange))
      let joined = firstPrefix + normalizedReplacementText + lastSuffix
      replacement = joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : joined
      caretSourceUTF16Offset = (firstPrefix as NSString).length + replacementUTF16Length
    }

    let expectedOriginal = try sourceText(
      in: source,
      startLine: startLine,
      endLineExclusive: endLineExclusive
    )
    let updatedSource = try replacingSourceRange(
      in: source,
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      replacement: replacement
    )
    return (
      startLine: startLine,
      endLineExclusive: endLineExclusive,
      replacement: replacement,
      expectedOriginal: expectedOriginal,
      updatedSource: updatedSource,
      caretSourceUTF16Offset: caretSourceUTF16Offset,
      coversWholeDocument: coversWholeDocument
    )
  }

  nonisolated private static func editableSelection(
    for block: OrgEditableBlock,
    sourceUTF16Offset: Int
  ) -> NSRange {
    let prefixLength = editorToSourceUTF16Offset(for: block)
    let editableLength = max(0, (block.rawText as NSString).length - prefixLength)
    let location = min(max(0, sourceUTF16Offset - prefixLength), editableLength)
    return NSRange(location: location, length: 0)
  }

  nonisolated static func editorToSourceUTF16Offset(for block: OrgEditableBlock) -> Int {
    guard case .listItem = block.rendered else { return 0 }
    return listPrefixUTF16Length(in: block.rawText)
  }

  nonisolated private static func listPrefixUTF16Length(in rawText: String) -> Int {
    guard let regex = try? NSRegularExpression(
      pattern: #"^\s*(?:[-+]|[0-9]+[.)])\s+(?:\[(?: |X|x|-)\]\s*)?"#
    ) else {
      return 0
    }
    let nsText = rawText as NSString
    let match = regex.firstMatch(in: rawText, range: NSRange(location: 0, length: nsText.length))
    guard let match,
          match.range.location == 0
    else {
      return 0
    }
    return match.range.length
  }

  nonisolated private static func selectionCoversWholeRenderedTextDocument(
    pairs: [(fragment: RenderedTextSelectionFragment, block: OrgEditableBlock)],
    allBlocks: [OrgEditableBlock]
  ) -> Bool {
    guard !pairs.isEmpty,
          pairs.allSatisfy({ $0.fragment.selectsEntireEditor })
    else {
      return false
    }

    let nonBlankBlocks = allBlocks.filter { block in
      if case .blank = block.rendered { return false }
      return true
    }
    guard !nonBlankBlocks.isEmpty,
          nonBlankBlocks.allSatisfy(isRenderedTextSelectionBlock)
    else {
      return false
    }

    let selectedBlockIDs = Set(pairs.map(\.block.id))
    return nonBlankBlocks.allSatisfy { selectedBlockIDs.contains($0.id) }
  }

  nonisolated private static func isRenderedTextSelectionBlock(_ block: OrgEditableBlock) -> Bool {
    switch block.rendered {
    case .heading, .paragraph, .listItem:
      return true
    default:
      return false
    }
  }

  nonisolated static func replacingSelection(
    in rawText: String,
    fragment: RenderedTextSelectionFragment,
    replacementText: String
  ) -> String {
    if fragment.selectsEntireEditor {
      return replacementText
    }
    let range = clampedRange(fragment.sourceRange, in: rawText)
    let nsRawText = rawText as NSString
    return nsRawText.replacingCharacters(in: range, with: replacementText)
  }

  nonisolated private static func sourceTextForSelectionFragment(
    _ fragment: RenderedTextSelectionFragment,
    block: OrgEditableBlock
  ) -> String {
    let editorText = normalizeLineEndings(fragment.editorText)
    guard fragment.editorToSourceUTF16Offset > 0 else {
      return editorText
    }
    let blockRawText = normalizeLineEndings(block.rawText)
    let prefixLength = min(fragment.editorToSourceUTF16Offset, (blockRawText as NSString).length)
    return (blockRawText as NSString).substring(to: prefixLength) + editorText
  }

  nonisolated private static func clampedRange(_ range: NSRange, in text: String) -> NSRange {
    let length = (text as NSString).length
    let location = min(max(0, range.location), length)
    return NSRange(location: location, length: min(max(0, range.length), length - location))
  }

  nonisolated static func swappingSourceRanges(
    in source: EntrySource,
    firstStartLine: Int,
    firstEndLineExclusive: Int,
    secondStartLine: Int,
    secondEndLineExclusive: Int
  ) throws -> EntrySource {
    var lines = normalizeLineEndings(source.text)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let firstStartIndex = firstStartLine - source.startLine
    let firstEndIndex = firstEndLineExclusive - source.startLine
    let secondStartIndex = secondStartLine - source.startLine
    let secondEndIndex = secondEndLineExclusive - source.startLine
    guard firstStartIndex >= 0,
          firstStartIndex < firstEndIndex,
          firstEndIndex <= secondStartIndex,
          secondStartIndex < secondEndIndex,
          secondEndIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: source.file, line: firstStartLine)
    }

    let first = Array(lines[firstStartIndex..<firstEndIndex])
    let between = Array(lines[firstEndIndex..<secondStartIndex])
    let second = Array(lines[secondStartIndex..<secondEndIndex])
    lines.replaceSubrange(firstStartIndex..<secondEndIndex, with: second + between + first)

    return EntrySource(
      file: source.file,
      startLine: source.startLine,
      endLineExclusive: source.startLine + lines.count,
      text: lines.joined(separator: "\n"),
      isSubtree: source.isSubtree,
      isEditable: source.isEditable
    )
  }

  nonisolated static func textByReplacingSourceRange(
    in raw: String,
    file: String,
    startLine: Int,
    endLineExclusive: Int,
    replacement: String,
    expectedOriginal: String? = nil
  ) throws -> String {
    var lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)

    let startIndex = startLine - 1
    let endIndex = endLineExclusive - 1
    guard startIndex >= 0, startIndex <= lines.count, endIndex >= startIndex, endIndex <= lines.count else {
      throw WorkspaceEditError.invalidRange(file: file, line: startLine)
    }

    if let expectedOriginal {
      let currentOriginal = lines[startIndex..<endIndex].joined(separator: "\n")
      guard currentOriginal == normalizeLineEndings(expectedOriginal) else {
        throw WorkspaceEditError.fileChanged(file: file)
      }
    }

    let normalizedReplacement = normalizeLineEndings(replacement)
    let replacementLines = normalizedReplacement.isEmpty
      ? []
      : normalizedReplacement
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    lines.replaceSubrange(startIndex..<endIndex, with: replacementLines)

    var output = lines.joined(separator: "\n")
    if raw.hasSuffix("\n"), !output.isEmpty, !output.hasSuffix("\n") {
      output += "\n"
    }
    return output
  }

  nonisolated static func sourceRangeText(
    file: String,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> String {
    let raw = try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
    return try sourceRangeText(
      in: raw,
      file: file,
      startLine: startLine,
      endLineExclusive: endLineExclusive
    )
  }

  nonisolated static func sourceRangeText(
    in raw: String,
    file: String,
    startLine: Int,
    endLineExclusive: Int
  ) throws -> String {
    let lines = normalizeLineEndings(raw)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    let startIndex = startLine - 1
    let endIndex = endLineExclusive - 1
    guard startIndex >= 0,
          startIndex <= lines.count,
          endIndex >= startIndex,
          endIndex <= lines.count
    else {
      throw WorkspaceEditError.invalidRange(file: file, line: startLine)
    }
    return lines[startIndex..<endIndex].joined(separator: "\n")
  }

  nonisolated static func splitBlockPlan(
    for block: OrgEditableBlock,
    draft: String,
    utf16Offset: Int
  ) -> SplitBlockPlan? {
    switch block.rendered {
    case .paragraph:
      let normalizedDraft = normalizeLineEndings(draft)
      let split = splitText(normalizedDraft, atUTF16Offset: utf16Offset)
      let currentText = split.before.trimmingCharacters(in: .whitespacesAndNewlines)
      let nextText = split.after.trimmingCharacters(in: .whitespacesAndNewlines)

      if nextText.isEmpty,
         let parsedCurrent = OrgEntryRenderer.parseEditable(currentText).first,
         case .listItem(let indent, let marker, let checkbox, _) = parsedCurrent.rendered {
        let prefix = continuedListPrefix(
          draft: currentText,
          fallbackMarker: marker,
          checkbox: checkbox
        )
        return SplitBlockPlan(
          replacement: currentText,
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: lineCount(in: currentText),
            displayLineOffset: lineCount(in: currentText),
            rawText: prefix,
            rendered: .listItem(
              indent: indent,
              marker: marker,
              checkbox: checkbox == nil ? nil : .unchecked,
              text: ""
            ),
            replacementPrefix: "",
            replacementSuffix: "",
            selectionLineOffset: 0
          )
        )
      }

      if nextText.isEmpty {
        return SplitBlockPlan(
          replacement: currentText.isEmpty ? nil : currentText,
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: currentText.isEmpty ? 0 : lineCount(in: currentText),
            displayLineOffset: currentText.isEmpty ? 0 : lineCount(in: currentText),
            rawText: "",
            rendered: .paragraph(""),
            replacementPrefix: "\n",
            replacementSuffix: "",
            selectionLineOffset: 1
          )
        )
      }

      if currentText.isEmpty {
        return SplitBlockPlan(
          replacement: nextText,
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: 0,
            displayLineOffset: 0,
            rawText: "",
            rendered: .paragraph(""),
            replacementPrefix: "",
            replacementSuffix: "\n",
            selectionLineOffset: 0
          )
        )
      }

      return SplitBlockPlan(
        replacement: "\(currentText)\n\n\(nextText)",
        newBlockLineOffset: lineCount(in: currentText) + 1,
        draft: nil
      )
    case .listItem(let indent, let marker, let checkbox, _):
      let normalizedDraft = normalizeLineEndings(draft)
      let split = splitText(normalizedDraft, atUTF16Offset: utf16Offset)
      let firstBlock = split.before.trimmingCharacters(in: .newlines)
      let nextText = split.after.trimmingCharacters(in: .whitespacesAndNewlines)
      let prefix = continuedListPrefix(
        draft: normalizedDraft,
        fallbackMarker: marker,
        checkbox: checkbox
      )

      if nextText.isEmpty {
        return SplitBlockPlan(
          replacement: firstBlock.isEmpty ? nil : firstBlock,
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: firstBlock.isEmpty ? 0 : lineCount(in: firstBlock),
            displayLineOffset: firstBlock.isEmpty ? 0 : lineCount(in: firstBlock),
            rawText: prefix,
            rendered: .listItem(
              indent: indent,
              marker: marker,
              checkbox: checkbox == nil ? nil : .unchecked,
              text: ""
            ),
            replacementPrefix: "",
            replacementSuffix: "",
            selectionLineOffset: 0
          )
        )
      }

      if firstBlock.isEmpty {
        return SplitBlockPlan(
          replacement: "\(prefix)\(nextText)",
          newBlockLineOffset: nil,
          draft: SplitDraftSpec(
            insertionLineOffset: 0,
            displayLineOffset: 0,
            rawText: prefix,
            rendered: .listItem(
              indent: indent,
              marker: marker,
              checkbox: checkbox == nil ? nil : .unchecked,
              text: ""
            ),
            replacementPrefix: "",
            replacementSuffix: "",
            selectionLineOffset: 0
          )
        )
      }

      return SplitBlockPlan(
        replacement: "\(firstBlock)\n\(prefix)\(nextText)",
        newBlockLineOffset: lineCount(in: firstBlock),
        draft: nil
      )
    default:
      return nil
    }
  }
}
