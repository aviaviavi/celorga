import Foundation

/// A chat that mirrors a dot's whole ChatGPT conversation. See
/// `OpenAIDotMirror` for how the conversation is stored and read.
extension WorkspaceStore {
  // MARK: Opening

  /// Dot destinations whose whole conversation can be opened as a chat.
  public var openAIDotConversationDestinations: [AIChatDestinationConfiguration] {
    enabledAIChatDestinations.filter { $0.adapter == .openAIDot }
  }

  /// Opens the chat that mirrors a dot's whole ChatGPT conversation,
  /// creating it the first time.
  @discardableResult
  public func openOpenAIDotConversation(destinationID: String) -> UUID? {
    guard let destination = aiChatDestination(id: destinationID),
          destination.adapter == .openAIDot
    else {
      aiChatStatusText = "Add an OpenAI Dot destination in AI chat settings first."
      return nil
    }
    navigateToSurface(.aiChat)
    let mirrors = aiChatThreads.filter { $0.openAIDotMirrorDestinationID == destination.id }
    if let existing = mirrors.first(where: { !$0.isArchived }) ?? mirrors.first {
      if existing.isArchived {
        replaceAIChatThread(
          existing.replacingAIChatMetadata(isArchived: false, settledAt: .some(nil)),
          transcriptURL: aiChatTranscriptURL
        )
      }
      selectAIChatThread(existing.id)
      reconcileOpenAIDotMirrorWatches()
      return existing.id
    }
    let thread = createAIChatThread(
      title: destination.title,
      statusText: "Reading \(destination.title)'s conversation",
      runtime: destination.runtime,
      destinationID: destination.id
    )
    replaceAIChatThread(
      thread.replacingAIChatMetadata(
        runtimeThreadIDsByDestination: [OpenAIDotMirror.destinationKey: destination.id],
        isPinned: true
      ),
      transcriptURL: aiChatTranscriptURL
    )
    reconcileOpenAIDotMirrorWatches()
    return thread.id
  }

  // MARK: Watches

  func scheduleOpenAIDotMirrorReconcile() {
    guard !isOpenAIDotMirrorReconcileScheduled else { return }
    isOpenAIDotMirrorReconcileScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.isOpenAIDotMirrorReconcileScheduled = false
      self.reconcileOpenAIDotMirrorWatches()
    }
  }

  /// Runs one watch for each mirror chat whose dot destination is enabled,
  /// and stops watches for chats that were removed, archived, or moved to
  /// another corpus.
  func reconcileOpenAIDotMirrorWatches() {
    guard !isLoadingAIChatTranscript else { return }
    let transcriptPath = aiChatTranscriptURL.standardizedFileURL.path
    var wanted: [UUID: AIChatDestinationConfiguration] = [:]
    if !isPreparingForTermination {
      for thread in aiChatThreads where !thread.isArchived {
        guard let destinationID = thread.openAIDotMirrorDestinationID,
              let destination = aiChatDestination(id: destinationID),
              destination.isEnabled,
              destination.adapter == .openAIDot
        else { continue }
        wanted[thread.id] = destination
      }
    }
    for (threadID, watch) in openAIDotMirrorWatchesByThreadID {
      if let destination = wanted[threadID],
         watch.destinationID == destination.id,
         watch.settingsKey == OpenAIDotMirrorWatch.settingsKey(for: destination),
         watch.transcriptPath == transcriptPath {
        continue
      }
      stopOpenAIDotMirrorWatch(threadID: threadID)
    }
    for threadID in Array(openAIDotMirrorEarlierMessagesByThreadID.keys) where wanted[threadID] == nil {
      openAIDotMirrorEarlierMessagesByThreadID.removeValue(forKey: threadID)
      openAIDotMirrorHistoryStateByThreadID.removeValue(forKey: threadID)
    }
    for (threadID, destination) in wanted where openAIDotMirrorWatchesByThreadID[threadID] == nil {
      startOpenAIDotMirrorWatch(threadID: threadID, destination: destination)
    }
  }

  func stopOpenAIDotMirrorWatch(threadID: UUID) {
    openAIDotMirrorWatchesByThreadID.removeValue(forKey: threadID)?.task.cancel()
    openAIDotMirrorRoomsByThreadID.removeValue(forKey: threadID)
  }

  /// Notes activity in a mirror (such as a message sent from Celorga) so its
  /// watch checks again within seconds instead of at its quiet-time pace.
  func noteOpenAIDotMirrorActivity(threadID: UUID) {
    openAIDotMirrorActivityAtByThreadID[threadID] = Date()
    guard openAIDotMirrorWatchesByThreadID[threadID] != nil else { return }
    stopOpenAIDotMirrorWatch(threadID: threadID)
    reconcileOpenAIDotMirrorWatches()
  }

  func makeOpenAIDotClient(_ destination: AIChatDestinationConfiguration) throws -> OpenAIDotChatClient {
    if let factory = openAIDotClientFactoryForTesting {
      return try factory(destination)
    }
    return OpenAIDotChatClient(
      settings: try OpenAIDotChatClient.Settings(
        endpoint: destination.endpoint,
        dotSelector: destination.agentID
      )
    )
  }

  private func startOpenAIDotMirrorWatch(threadID: UUID, destination: AIChatDestinationConfiguration) {
    guard let client = try? makeOpenAIDotClient(destination) else { return }
    let token = UUID()
    let transcriptURL = aiChatTranscriptURL.standardizedFileURL
    let state = OpenAIDotMirrorPollState(
      token: token,
      threadID: threadID,
      transcriptURL: transcriptURL,
      context: captureAIChatCorpusContext(),
      client: client
    )
    let task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let interval = await self?.pollOpenAIDotMirror(state) else { break }
        guard interval > 0 else { continue }
        do {
          try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } catch {
          break
        }
      }
      guard let self, self.openAIDotMirrorWatchesByThreadID[threadID]?.token == token else { return }
      self.openAIDotMirrorWatchesByThreadID.removeValue(forKey: threadID)
    }
    openAIDotMirrorWatchesByThreadID[threadID] = OpenAIDotMirrorWatch(
      token: token,
      destinationID: destination.id,
      settingsKey: OpenAIDotMirrorWatch.settingsKey(for: destination),
      transcriptPath: transcriptURL.path,
      task: task
    )
  }

  private func isCurrentOpenAIDotMirrorWatch(_ state: OpenAIDotMirrorPollState) -> Bool {
    openAIDotMirrorWatchesByThreadID[state.threadID]?.token == state.token
      && isCurrentAIChatCorpusContext(state.context)
  }

  /// Checks a mirrored conversation once and adds anything new to its chat.
  /// Returns how long to wait before the next check, or nil to stop.
  func pollOpenAIDotMirror(_ state: OpenAIDotMirrorPollState) async -> TimeInterval? {
    guard isCurrentOpenAIDotMirrorWatch(state) else { return nil }
    let threadID = state.threadID
    do {
      let room: OpenAIDotRoom
      if let known = state.room {
        room = known
      } else {
        room = try await state.client.resolveRoom()
        guard isCurrentOpenAIDotMirrorWatch(state) else { return nil }
        state.room = room
        openAIDotMirrorRoomsByThreadID[threadID] = room
      }
      guard let thread = aiChatThread(threadID, transcriptURL: state.transcriptURL) else { return nil }
      var hasMore = false
      if let cursor = thread.openAIDotMirrorCursor(roomID: room.roomID) {
        let batch = try await state.client.messages(roomID: room.roomID, after: cursor)
        guard isCurrentOpenAIDotMirrorWatch(state) else { return nil }
        let added = await applyOpenAIDotMirrorMessages(
          batch.messages,
          cursor: batch.cursor,
          room: room,
          state: state,
          notifies: true
        )
        if added > 0 { openAIDotMirrorActivityAtByThreadID[threadID] = Date() }
        hasMore = batch.hasMore
      } else {
        // A new mirror (or one whose position was lost) starts from the
        // newest stretch of the conversation; earlier messages are read
        // from ChatGPT only when the reader scrolls back to them.
        let page = try await state.client.latestMessages(
          roomID: room.roomID,
          limit: OpenAIDotMirror.initialMessageCount
        )
        guard isCurrentOpenAIDotMirrorWatch(state) else { return nil }
        await applyOpenAIDotMirrorMessages(
          page.messages,
          cursor: page.messages.last?.id,
          room: room,
          state: state,
          notifies: false
        )
        if page.reachedStart, openAIDotMirrorEarlierMessagesByThreadID[threadID]?.isEmpty != false {
          var history = openAIDotMirrorHistoryStateByThreadID[threadID] ?? OpenAIDotMirrorHistoryState()
          history.reachedStart = true
          openAIDotMirrorHistoryStateByThreadID[threadID] = history
        }
      }
      state.retryDelay = 0
      if hasMore { return 0 }
      let lastActivity = openAIDotMirrorActivityAtByThreadID[threadID] ?? .distantPast
      return OpenAIDotMirror.pollInterval(sinceActivity: Date().timeIntervalSince(lastActivity))
    } catch is CancellationError {
      return nil
    } catch {
      guard isCurrentOpenAIDotMirrorWatch(state) else { return nil }
      if let dotError = error as? OpenAIDotChatError,
         case .http(let status, _) = dotError,
         status == 400 || status == 404 {
        // The saved position or the conversation itself is gone. Find the
        // conversation again and continue from its newest messages.
        state.room = nil
        clearOpenAIDotMirrorCursor(threadID: threadID, transcriptURL: state.transcriptURL)
      } else if (error as? OpenAIDotChatError)?.isTransient != true {
        // A sign-in or dot change may move the conversation; look it up again.
        state.room = nil
      }
      state.retryDelay = OpenAIDotMirror.retryInterval(after: error, previous: state.retryDelay)
      if selectedAIChatThreadID == threadID, aiChatPendingUserMessageIDs(for: threadID).isEmpty {
        let name = aiChatThread(threadID, transcriptURL: state.transcriptURL)
          .map { aiChatDestinationTitle($0.destinationID) } ?? "The dot"
        aiChatStatusText = "Couldn't check \(name)'s conversation: \(Self.aiChatSendFailureText(from: error))"
      }
      return state.retryDelay
    }
  }

  @discardableResult
  private func applyOpenAIDotMirrorMessages(
    _ incoming: [OpenAIDotMessage],
    cursor: String?,
    room: OpenAIDotRoom,
    state: OpenAIDotMirrorPollState,
    notifies: Bool
  ) async -> Int {
    // Merging into a transcript that is still on disk would drop its
    // messages, so load it first.
    guard await hydrateAIChatThreadIfNeeded(state.threadID) != nil,
          isCurrentOpenAIDotMirrorWatch(state)
    else { return 0 }
    return mergeOpenAIDotMirrorMessages(
      incoming,
      cursor: cursor,
      room: room,
      threadID: state.threadID,
      transcriptURL: state.transcriptURL,
      notifies: notifies
    )
  }

  /// Adds ChatGPT messages to a loaded mirror chat and records the newest
  /// one read. Returns how many messages were added.
  @discardableResult
  func mergeOpenAIDotMirrorMessages(
    _ incoming: [OpenAIDotMessage],
    cursor: String?,
    room: OpenAIDotRoom,
    threadID: UUID,
    transcriptURL: URL,
    notifies: Bool
  ) -> Int {
    guard !unloadedAIChatThreadIDs.contains(threadID),
          let thread = aiChatThread(threadID, transcriptURL: transcriptURL),
          thread.isOpenAIDotMirror
    else { return 0 }
    let existing = aiChatMessages(for: threadID, transcriptURL: transcriptURL)
    let merge = OpenAIDotMirror.merge(
      existing: existing,
      incoming: incoming,
      roomID: room.roomID,
      selfMemberID: room.selfMemberID
    )
    var anchors = thread.runtimeThreadIDsByDestination
    anchors[OpenAIDotMirror.roomKey] = room.roomID
    if let cursor, !cursor.isEmpty {
      anchors[OpenAIDotMirror.cursorKey] = cursor
    }
    let metadataChanged = anchors != thread.runtimeThreadIDsByDestination
    guard metadataChanged || merge.changed else { return 0 }
    if metadataChanged {
      replaceAIChatThread(
        thread.replacingAIChatMetadata(runtimeThreadIDsByDestination: anchors),
        transcriptURL: transcriptURL,
        shouldPersist: false
      )
    }
    // Always write the messages with the metadata so a save never captures
    // a thread whose messages are still being published to the view.
    updateAIChatThread(
      threadID,
      messages: merge.messages,
      notifiesForNewAssistantMessages: notifies,
      transcriptURL: transcriptURL,
      shouldPersist: true
    )
    if merge.trimmedCount > 0,
       var earlier = openAIDotMirrorEarlierMessagesByThreadID[threadID],
       !earlier.isEmpty {
      // Keep scrolled-back history continuous with what is still saved.
      let trimmed = existing.prefix(merge.trimmedCount)
      let shownIDs = Set(earlier.map(\.id))
      earlier += trimmed.filter { !shownIDs.contains($0.id) }
      openAIDotMirrorEarlierMessagesByThreadID[threadID] = earlier
    }
    return merge.addedCount
  }

  private func clearOpenAIDotMirrorCursor(threadID: UUID, transcriptURL: URL) {
    guard let thread = aiChatThread(threadID, transcriptURL: transcriptURL),
          thread.runtimeThreadIDsByDestination[OpenAIDotMirror.cursorKey] != nil
    else { return }
    var anchors = thread.runtimeThreadIDsByDestination
    anchors.removeValue(forKey: OpenAIDotMirror.cursorKey)
    anchors.removeValue(forKey: OpenAIDotMirror.roomKey)
    replaceAIChatThread(
      thread.replacingAIChatMetadata(runtimeThreadIDsByDestination: anchors),
      transcriptURL: transcriptURL,
      shouldPersist: false
    )
  }

  // MARK: Earlier messages

  /// Earlier messages read from ChatGPT for a mirror chat, oldest first.
  public func openAIDotMirrorEarlierMessages(for threadID: UUID?) -> [AIChatMessage] {
    threadID.flatMap { openAIDotMirrorEarlierMessagesByThreadID[$0] } ?? []
  }

  /// Whether the selected chat is a dot mirror with older messages in ChatGPT.
  public var selectedAIChatCanLoadEarlierOpenAIDotMessages: Bool {
    guard let threadID = selectedAIChatThreadID,
          aiChatThread(withID: threadID)?.isOpenAIDotMirror == true
    else { return false }
    return openAIDotMirrorHistoryStateByThreadID[threadID]?.reachedStart != true
  }

  public var selectedAIChatIsLoadingEarlierOpenAIDotMessages: Bool {
    selectedAIChatThreadID.flatMap { openAIDotMirrorHistoryStateByThreadID[$0]?.isLoading } ?? false
  }

  /// Reads the next stretch of earlier messages of a mirror chat from
  /// ChatGPT. They are shown above the saved messages but not saved.
  /// Returns the number of messages added.
  @discardableResult
  public func loadEarlierOpenAIDotMirrorMessages(threadID: UUID) async -> Int {
    guard let thread = aiChatThread(threadID, transcriptURL: aiChatTranscriptURL),
          let destinationID = thread.openAIDotMirrorDestinationID,
          let destination = aiChatDestination(id: destinationID)
    else { return 0 }
    var history = openAIDotMirrorHistoryStateByThreadID[threadID] ?? OpenAIDotMirrorHistoryState()
    guard !history.isLoading, !history.reachedStart else { return 0 }
    history.isLoading = true
    openAIDotMirrorHistoryStateByThreadID[threadID] = history
    let context = captureAIChatCorpusContext()
    defer {
      if isCurrentAIChatCorpusContext(context) {
        openAIDotMirrorHistoryStateByThreadID[threadID]?.isLoading = false
      }
    }
    do {
      let client = try makeOpenAIDotClient(destination)
      let room: OpenAIDotRoom
      if let known = openAIDotMirrorRoomsByThreadID[threadID] {
        room = known
      } else {
        room = try await client.resolveRoom()
        guard isCurrentAIChatCorpusContext(context) else { return 0 }
        openAIDotMirrorRoomsByThreadID[threadID] = room
      }
      var cursor = history.oldestMessageID
      var collected: [AIChatMessage] = []
      var reachedStart = false
      // The first read starts at the newest message and skips past what the
      // chat already holds; later reads continue from the oldest one read.
      var reads = 0
      while collected.count < OpenAIDotMirror.earlierPageSize, !reachedStart, reads < 20 {
        reads += 1
        let page = try await client.messages(
          roomID: room.roomID,
          before: cursor,
          limit: OpenAIDotMirror.earlierPageSize
        )
        guard isCurrentAIChatCorpusContext(context) else { return 0 }
        reachedStart = page.reachedStart
        guard let first = page.messages.first else {
          reachedStart = true
          break
        }
        cursor = first.id
        let shown = collected
          + openAIDotMirrorEarlierMessages(for: threadID)
          + aiChatMessages(for: threadID, transcriptURL: aiChatTranscriptURL)
        let older = OpenAIDotMirror.earlierMessages(
          page.messages,
          shown: shown,
          roomID: room.roomID,
          selfMemberID: room.selfMemberID
        )
        collected.insert(contentsOf: older, at: 0)
      }
      openAIDotMirrorEarlierMessagesByThreadID[threadID] = collected + openAIDotMirrorEarlierMessages(for: threadID)
      history = openAIDotMirrorHistoryStateByThreadID[threadID] ?? history
      history.oldestMessageID = cursor
      history.reachedStart = reachedStart
      history.isLoading = false
      openAIDotMirrorHistoryStateByThreadID[threadID] = history
      if selectedAIChatThreadID == threadID, collected.isEmpty, reachedStart {
        aiChatStatusText = "This is the start of \(destination.title)'s conversation"
      }
      return collected.count
    } catch is CancellationError {
      return 0
    } catch {
      guard isCurrentAIChatCorpusContext(context) else { return 0 }
      if selectedAIChatThreadID == threadID {
        aiChatStatusText = "Couldn't read earlier messages: \(Self.aiChatSendFailureText(from: error))"
      }
      return 0
    }
  }
}
