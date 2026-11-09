import Foundation

/// The latest messages of one conversation, as the desktop that runs or just
/// finished its turn holds them. Sent with ``AIChatLivePresencePush`` so a
/// paired phone sees the prompt, progress, and reply before file sync
/// delivers the transcript commit that carries them.
public struct AIChatLiveThreadSnapshot: Codable, Sendable, Equatable {
  public var id: UUID
  public var title: String
  public var runtime: AIChatRuntime
  public var destinationID: String?
  public var isSharedRoom: Bool
  public var createdAt: Date
  public var updatedAt: Date
  /// The latest messages, oldest first, without attachment bytes, traces, or
  /// change summaries.
  public var messages: [AIChatMessage]

  public init(
    id: UUID,
    title: String,
    runtime: AIChatRuntime,
    destinationID: String?,
    isSharedRoom: Bool,
    createdAt: Date,
    updatedAt: Date,
    messages: [AIChatMessage]
  ) {
    self.id = id
    self.title = title
    self.runtime = runtime
    self.destinationID = destinationID
    self.isSharedRoom = isSharedRoom
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messages = messages
  }

  static let maximumMessages = 16
  static let maximumMessageCharacters = 48 * 1_024

  init(thread: AIChatThread, messages: [AIChatMessage]) {
    self.init(
      id: thread.id,
      title: thread.title,
      runtime: thread.runtime,
      destinationID: thread.destinationID,
      isSharedRoom: thread.isSharedRoom,
      createdAt: thread.createdAt,
      updatedAt: max(thread.updatedAt, messages.last?.createdAt ?? .distantPast),
      messages: messages.suffix(Self.maximumMessages).map(Self.preview)
    )
  }

  /// A display copy: the content (bounded), attachment names, and the fields
  /// the phone shows. Attachment bytes stay on the desktop.
  static func preview(_ message: AIChatMessage) -> AIChatMessage {
    AIChatMessage(
      id: message.id,
      role: message.role,
      content: AIChatLiveHostDirectory.boundedHead(message.content, maximum: maximumMessageCharacters),
      attachments: message.attachments.map {
        AIChatAttachment(id: $0.id, fileName: $0.fileName, mimeType: $0.mimeType, data: Data())
      },
      createdAt: message.createdAt,
      sendFailure: message.sendFailure,
      deliveryStatus: message.deliveryStatus,
      deliveryKind: message.deliveryKind,
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

  /// `thread` as a paired client should see it: messages the snapshot holds
  /// replace or join the committed ones (matched by ID), in creation order.
  /// Nothing here is persisted.
  func merged(into thread: AIChatThread) -> AIChatThread {
    guard !messages.isEmpty else { return thread }
    var result = thread.messages
    var indexByID: [UUID: Int] = [:]
    for (index, message) in result.enumerated() { indexByID[message.id] = index }
    for message in messages {
      if let index = indexByID[message.id] {
        result[index] = message
      } else {
        let index = result.lastIndex(where: { $0.createdAt <= message.createdAt }).map { $0 + 1 } ?? 0
        result.insert(message, at: index)
        indexByID = [:]
        for (offset, item) in result.enumerated() { indexByID[item.id] = offset }
      }
    }
    return thread.replacingMessages(result).replacingUpdatedAt(max(thread.updatedAt, updatedAt))
  }

  /// A conversation this host has not received yet, built from the snapshot.
  var thread: AIChatThread {
    AIChatThread(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      runtime: runtime,
      destinationID: destinationID,
      sessionKey: "live-preview-\(id.uuidString.lowercased())",
      messages: messages,
      isSharedRoom: isSharedRoom
    )
  }
}

/// A desktop's live state, sent over the paired OpenOrg server connection
/// (`POST /v1/live-presence`) in addition to the presence file. File sync can
/// lag or disconnect; this keeps phones paired with the server current on the
/// desktop's turns. The server uses it only to present conversations, never
/// for routing or hand-offs, and never writes it to the corpus.
public struct AIChatLivePresencePush: Codable, Sendable, Equatable {
  public static let schemaValue = "org2:ai-chat-live-push:v1"
  static let maximumTurns = 32
  static let maximumThreads = 24

  public var schema: String
  public var record: AIChatLiveHostRecord
  public var threads: [AIChatLiveThreadSnapshot]

  public init(record: AIChatLiveHostRecord, threads: [AIChatLiveThreadSnapshot]) {
    schema = Self.schemaValue
    self.record = record
    self.threads = threads
  }

  /// Compares everything except the heartbeat timestamp.
  func hasSameContent(as other: AIChatLivePresencePush) -> Bool {
    threads == other.threads && record.hasSameContent(as: other.record)
  }
}

/// A push as the server received it, timed by the server's clock so a
/// desktop with a skewed clock is neither hidden nor kept alive.
struct AIChatReceivedLivePresence: Sendable, Equatable {
  var push: AIChatLivePresencePush
  var receivedAt: Date
}

extension WorkspaceStore {
  /// Conversations a pushed snapshot keeps visible after their turn ends,
  /// until file sync delivers the commit.
  static let aiChatPushedSnapshotRetention: TimeInterval = 15 * 60

  // MARK: Desktop: forward live state to the paired server

  /// The paired server hosts phones; send it this desktop's live state.
  var shouldForwardAIChatLivePresence: Bool {
    guard aiChatHostIdentity.kind == .desktop else { return false }
    if aiChatLivePresenceForwarder != nil { return true }
    guard let pairing = openOrgServer.pairing else { return false }
    return pairing.hostRef != aiChatHostIdentity.ref
  }

  func currentAIChatLivePresencePush(record: AIChatLiveHostRecord, now: Date = Date()) -> AIChatLivePresencePush {
    let running = Set(record.turns.map(\.threadID))
    for threadID in aiChatLastForwardedLiveTurnThreadIDs.subtracting(running) {
      aiChatRecentlyFinishedLiveThreads[threadID] = now
    }
    aiChatLastForwardedLiveTurnThreadIDs = running
    aiChatRecentlyFinishedLiveThreads = aiChatRecentlyFinishedLiveThreads.filter {
      !running.contains($0.key) && now.timeIntervalSince($0.value) < Self.aiChatPushedSnapshotRetention
    }
    let ordered = record.turns.map(\.threadID)
      + aiChatRecentlyFinishedLiveThreads.sorted { $0.value > $1.value }.map(\.key)
    var seen = Set<UUID>()
    var snapshots: [AIChatLiveThreadSnapshot] = []
    for threadID in ordered where seen.insert(threadID).inserted {
      guard snapshots.count < AIChatLivePresencePush.maximumThreads,
            !unloadedAIChatThreadIDs.contains(threadID),
            let thread = aiChatThread(withID: threadID)
      else { continue }
      let messages = selectedAIChatThreadID == threadID ? aiChatMessages : thread.messages
      snapshots.append(AIChatLiveThreadSnapshot(thread: thread, messages: messages))
    }
    var bounded = record
    bounded.turns = Array(record.turns.prefix(AIChatLivePresencePush.maximumTurns))
    return AIChatLivePresencePush(record: bounded, threads: snapshots)
  }

  /// Sends live state to the paired server when it changed or a heartbeat is
  /// due. One request is in flight at a time; the newest state wins.
  func forwardAIChatLivePresenceIfNeeded(record: AIChatLiveHostRecord, force: Bool = false, now: Date = Date()) {
    guard shouldForwardAIChatLivePresence else { return }
    let push = currentAIChatLivePresencePush(record: record, now: now)
    let changed = lastForwardedAIChatLivePresence.map { !$0.hasSameContent(as: push) } ?? true
    let heartbeatDue = lastForwardedAIChatLivePresence.map {
      now.timeIntervalSince($0.record.updatedAt) >= aiChatLiveHeartbeatInterval
    } ?? true
    guard force || changed || heartbeatDue,
          aiChatLivePresenceForwardTask == nil,
          aiChatLivePresenceForwardRetryAt.map({ now >= $0 }) ?? true
    else { return }
    lastForwardedAIChatLivePresence = push
    aiChatLivePresenceForwardTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if let forwarder = self.aiChatLivePresenceForwarder {
          try await forwarder(push)
        } else {
          try await self.openOrgServer.pushLivePresence(push)
        }
        self.aiChatLivePresenceForwardRetryAt = nil
      } catch {
        // Send the full state again once the server is reachable.
        self.lastForwardedAIChatLivePresence = nil
        self.aiChatLivePresenceForwardRetryAt = Date().addingTimeInterval(15)
      }
      self.aiChatLivePresenceForwardTask = nil
    }
  }

  func waitForAIChatLivePresenceForwardForTesting() async {
    await aiChatLivePresenceForwardTask?.value
  }

  // MARK: Server: receive pushes and present them

  /// Accepts a paired desktop's live state. Returns false for a malformed
  /// push or one that claims to be this host.
  @discardableResult
  public func acceptPushedAIChatLivePresence(_ push: AIChatLivePresencePush, now: Date = Date()) -> Bool {
    let record = push.record
    guard CelorgaNames.schemaMatches(push.schema, AIChatLivePresencePush.schemaValue),
          CelorgaNames.schemaMatches(record.schema, AIChatLiveHostRecord.schemaValue),
          !record.writerID.isEmpty,
          record.writerID != AIChatTranscriptStore.shared.writerIdentity.id,
          !record.hostRef.isEmpty,
          record.hostRef != aiChatHostIdentity.ref,
          record.turns.count <= AIChatLivePresencePush.maximumTurns,
          push.threads.count <= AIChatLivePresencePush.maximumThreads,
          push.threads.allSatisfy({ $0.messages.count <= AIChatLiveThreadSnapshot.maximumMessages })
    else { return false }
    aiChatPushedLivePresence[record.writerID] = AIChatReceivedLivePresence(push: push, receivedAt: now)
    aiChatPushedLivePresence = aiChatPushedLivePresence.filter {
      now.timeIntervalSince($0.value.receivedAt) < Self.aiChatPushedSnapshotRetention
    }
    return true
  }

  private func freshPushedAIChatLivePresence(now: Date) -> [AIChatReceivedLivePresence] {
    aiChatPushedLivePresence.values.filter {
      $0.push.record.hostRef != aiChatHostIdentity.ref
        && $0.push.record.isOnline
        && now.timeIntervalSince($0.receivedAt) <= aiChatLiveFreshnessInterval
    }
  }

  /// The turn another host runs in `threadID`, from its presence file or its
  /// direct push, whichever that host wrote last. For presenting the
  /// conversation to paired clients; routing reads presence files only.
  public func aiChatObservedRemoteLiveTurn(for threadID: UUID, now: Date = Date()) -> AIChatRemoteLiveTurn? {
    let pushed = freshPushedAIChatLivePresence(now: now)
    let fileTurn = aiChatRemoteLiveTurn(for: threadID)
    if let fileTurn {
      // A newer push from the same host supersedes its synced file, which
      // may still list a turn that has ended.
      let newer = pushed.first {
        $0.push.record.hostRef == fileTurn.host.ref && $0.push.record.updatedAt >= fileTurn.updatedAt
      }
      guard let newer else { return fileTurn }
      return newer.push.record.turns.first(where: { $0.threadID == threadID }).map {
        AIChatRemoteLiveTurn(host: newer.push.record.host, turn: $0, updatedAt: newer.push.record.updatedAt)
      }
    }
    for received in pushed.sorted(by: { $0.receivedAt > $1.receivedAt }) {
      let record = received.push.record
      guard let turn = record.turns.first(where: { $0.threadID == threadID }) else { continue }
      // The host's synced file is newer and no longer lists the turn.
      if let file = aiChatRemoteLiveHosts.first(where: { $0.hostRef == record.hostRef }),
         file.updatedAt > record.updatedAt,
         file.isFresh(now: now, within: aiChatLiveFreshnessInterval) {
        continue
      }
      return AIChatRemoteLiveTurn(host: record.host, turn: turn, updatedAt: record.updatedAt)
    }
    return nil
  }

  /// The newest pushed snapshot of `threadID` still worth showing.
  func aiChatPushedThreadSnapshot(for threadID: UUID, now: Date = Date()) -> AIChatLiveThreadSnapshot? {
    aiChatPushedLivePresence.values
      .filter {
        $0.push.record.hostRef != aiChatHostIdentity.ref
          && now.timeIntervalSince($0.receivedAt) < Self.aiChatPushedSnapshotRetention
      }
      .sorted { $0.receivedAt > $1.receivedAt }
      .lazy
      .compactMap { $0.push.threads.first(where: { $0.id == threadID }) }
      .first
  }

  /// `thread` with pushed messages and another host's live prompt, as a
  /// paired client should see it.
  func aiChatThreadPresentedToRemoteClients(_ thread: AIChatThread, now: Date = Date()) -> AIChatThread {
    let presented = aiChatPushedThreadSnapshot(for: thread.id, now: now)?.merged(into: thread) ?? thread
    guard !presented.isSharedRoom,
          !isAIChatThreadRunningOnCurrentHost(thread.id),
          let remote = aiChatObservedRemoteLiveTurn(for: thread.id, now: now)
    else { return presented }
    let messages = remote.turn.messagesIncludingPrompt(presented.messages)
    guard messages.count != presented.messages.count else { return presented }
    return presented.replacingMessages(messages).replacingUpdatedAt(presented.updatedAt)
  }

  /// Conversations a paired desktop pushed that have not synchronized here.
  func aiChatPushedThreadsMissingLocally(now: Date = Date()) -> [AIChatThread] {
    let known = Set(aiChatThreads.map(\.id))
    var seen = Set<UUID>()
    return aiChatPushedLivePresence.values
      .filter { now.timeIntervalSince($0.receivedAt) < Self.aiChatPushedSnapshotRetention }
      .sorted { $0.receivedAt > $1.receivedAt }
      .flatMap(\.push.threads)
      .filter { !known.contains($0.id) && seen.insert($0.id).inserted }
      .map { aiChatThreadPresentedToRemoteClients($0.thread, now: now) }
  }

  /// Every conversation a paired client lists, with pushed state applied.
  func aiChatThreadsPresentedToRemoteClients(now: Date = Date()) -> [AIChatThread] {
    let pushedIDs = Set(aiChatPushedLivePresence.values.flatMap { $0.push.threads.map(\.id) })
    let liveIDs = aiChatRemoteRunningThreadIDs.union(
      freshPushedAIChatLivePresence(now: now).flatMap { $0.push.record.turns.map(\.threadID) }
    )
    let threads = aiChatThreads.map { thread in
      pushedIDs.contains(thread.id) || liveIDs.contains(thread.id)
        ? aiChatThreadPresentedToRemoteClients(thread, now: now)
        : thread
    }
    return aiChatPushedThreadsMissingLocally(now: now) + threads
  }
}
