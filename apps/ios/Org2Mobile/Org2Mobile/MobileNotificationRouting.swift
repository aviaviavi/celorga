import Foundation

/// A tap is retained until the root navigator has accepted it. The latest tap
/// wins; stale consumers cannot acknowledge a newer destination.
enum MobileNotificationDestination: Codable, Equatable {
  case thread(UUID)
  case agenda

  static func resolve(category: String, identifier: String, userInfo: [AnyHashable: Any]) -> Self? {
    if category == "org2.thread.reply",
       let raw = userInfo["threadID"] as? String, let id = UUID(uuidString: raw) {
      return .thread(id)
    }
    if category == "org2.agenda.due-today" || identifier == "org2.due-today.daily"
      || identifier.hasPrefix("org2.due-today.daily.") {
      return .agenda
    }
    return nil
  }
}

@MainActor
struct MobileNotificationInbox {
  struct Pending: Codable, Equatable {
    let id: UUID
    let destination: MobileNotificationDestination
  }
  static let key = "Org2Mobile.notification.pendingDestination.v1"
  static let legacyKey = "Org2Mobile.remote.pendingReplyThreadID.v1"
  let defaults: UserDefaults

  func enqueue(_ destination: MobileNotificationDestination) {
    let pending = Pending(id: UUID(), destination: destination)
    guard let data = try? JSONEncoder().encode(pending) else { return }
    defaults.set(data, forKey: Self.key)
    defaults.removeObject(forKey: Self.legacyKey)
  }

  func pending() -> Pending? {
    if let data = defaults.data(forKey: Self.key),
       let pending = try? JSONDecoder().decode(Pending.self, from: data) { return pending }
    if let raw = defaults.string(forKey: Self.legacyKey), let id = UUID(uuidString: raw) {
      enqueue(.thread(id))
      return pending()
    }
    return nil
  }

  func acknowledge(_ pending: Pending) {
    guard self.pending()?.id == pending.id else { return }
    defaults.removeObject(forKey: Self.key)
  }
}

/// Remembers which assistant replies this phone has already alerted for, so a
/// reply is announced at most once whether it arrives by APNs or by polling.
///
/// The paired Mac evicts idle transcripts to metadata-only placeholders, so a
/// thread summary can omit its latest reply and later report it again. Absence
/// is therefore never treated as forgetting: each thread keeps its recently
/// seen reply IDs, and only a reply ID never seen before is new.
struct MobileReplyNotificationLedger {
  struct Reply: Hashable {
    let threadID: UUID
    let messageID: UUID

    init(threadID: UUID, messageID: UUID) {
      self.threadID = threadID
      self.messageID = messageID
    }

    /// Reads the reply identity carried by both APNs and local reply alerts.
    init?(userInfo: [AnyHashable: Any]) {
      guard let thread = (userInfo["threadID"] as? String).flatMap(UUID.init(uuidString:)),
            let message = (userInfo["messageID"] as? String).flatMap(UUID.init(uuidString:))
      else { return nil }
      self.init(threadID: thread, messageID: message)
    }
  }

  private struct Entry: Codable {
    var messageIDs: [UUID]
    var updatedAt: Date
  }

  static let key = "Org2Mobile.remote.replyNotificationLedger.v2"
  static let legacyKey = "Org2Mobile.remote.replyNotificationBaseline.v1"
  /// Set only by `reconcile`, when a complete thread list becomes the baseline.
  static let seededKey = "Org2Mobile.remote.replyNotificationLedger.seeded.v1"
  static let recentRepliesPerThread = 32
  static let threadLimit = 1_000
  static let maximumPolledAlertsPerRefresh = 3

  let defaults: UserDefaults

  /// False until a complete thread list has been reconciled. The first list
  /// only establishes what already exists and never produces alerts.
  ///
  /// Recording individual replies (an APNs banner, an opened thread) does not
  /// seed the ledger: after a reset, a ledger holding one reply would make
  /// every other thread's old reply look new. Ledgers written by earlier
  /// builds have no marker, so they baseline silently once.
  var isSeeded: Bool {
    defaults.bool(forKey: Self.seededKey)
  }

  func hasSeen(_ reply: Reply) -> Bool {
    entries()[reply.threadID.uuidString]?.messageIDs.contains(reply.messageID) == true
  }

  /// Records every latest reply and returns the ones never seen before. An
  /// unseeded ledger records the list as its baseline and returns nothing.
  func reconcile(latestReplies: [Reply], now: Date = Date()) -> [Reply] {
    let wasSeeded = isSeeded
    let known = entries()
    let unseen = latestReplies.filter {
      known[$0.threadID.uuidString]?.messageIDs.contains($0.messageID) != true
    }
    record(latestReplies, now: now)
    defaults.set(true, forKey: Self.seededKey)
    return wasSeeded ? unseen : []
  }

  func record(_ replies: [Reply], now: Date = Date()) {
    var entries = entries()
    for reply in replies {
      let key = reply.threadID.uuidString
      var entry = entries[key] ?? Entry(messageIDs: [], updatedAt: now)
      if !entry.messageIDs.contains(reply.messageID) {
        entry.messageIDs.append(reply.messageID)
        if entry.messageIDs.count > Self.recentRepliesPerThread {
          entry.messageIDs.removeFirst(entry.messageIDs.count - Self.recentRepliesPerThread)
        }
        entry.updatedAt = now
      }
      entries[key] = entry
    }
    if entries.count > Self.threadLimit {
      let retained = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }
        .prefix(Self.threadLimit)
      entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
    }
    guard let data = try? JSONEncoder().encode(entries) else { return }
    defaults.set(data, forKey: Self.key)
    defaults.removeObject(forKey: Self.legacyKey)
  }

  func reset() {
    defaults.removeObject(forKey: Self.key)
    defaults.removeObject(forKey: Self.legacyKey)
    defaults.removeObject(forKey: Self.seededKey)
  }

  private func entries() -> [String: Entry] {
    if let data = defaults.data(forKey: Self.key),
       let entries = try? JSONDecoder().decode([String: Entry].self, from: data) {
      return entries
    }
    // Earlier builds stored only the latest reply per thread.
    if let data = defaults.data(forKey: Self.legacyKey),
       let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
      return legacy.reduce(into: [:]) { entries, pair in
        guard let messageID = UUID(uuidString: pair.value) else { return }
        entries[pair.key] = Entry(messageIDs: [messageID], updatedAt: .distantPast)
      }
    }
    return [:]
  }
}
