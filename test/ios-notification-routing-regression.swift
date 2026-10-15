import Foundation

@main
struct NotificationRoutingRegression {
  @MainActor static func main() throws {
    let suite = "org2.notification-test.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = UUID(), second = UUID()
    let inbox = MobileNotificationInbox(defaults: defaults)
    func expect(_ value: Bool, _ message: String) { precondition(value, message) }

    expect(MobileNotificationDestination.resolve(category: "org2.thread.reply", identifier: "push", userInfo: ["threadID": first.uuidString]) == .thread(first), "APNs tap")
    expect(MobileNotificationDestination.resolve(category: "org2.thread.reply", identifier: "org2.thread.reply.local", userInfo: ["threadID": first.uuidString]) == .thread(first), "Local fallback tap")
    expect(MobileNotificationDestination.resolve(category: "org2.thread.reply", identifier: "push", userInfo: ["threadID": "bad"]) == nil, "Malformed thread")
    expect(MobileNotificationDestination.resolve(category: "unknown", identifier: "push", userInfo: ["threadID": first.uuidString]) == nil, "Unknown notification")
    expect(MobileNotificationDestination.resolve(category: "org2.agenda.due-today", identifier: "new", userInfo: [:]) == .agenda, "Agenda tap")
    for id in ["org2.due-today.daily", "org2.due-today.daily.2026-09-11"] {
      expect(MobileNotificationDestination.resolve(category: "", identifier: id, userInfo: [:]) == .agenda, "Already scheduled agenda notification")
    }
    expect(inbox.pending() == nil, "No spurious startup navigation")
    inbox.enqueue(.thread(first))
    let restored = MobileNotificationInbox(defaults: UserDefaults(suiteName: suite)!)
    let cold = restored.pending()!
    expect(cold.destination == .thread(first), "Cold launch retains tap before navigator mounts")
    expect(restored.pending() == cold, "Readiness/connection checks do not consume tap")
    inbox.enqueue(.thread(second))
    restored.acknowledge(cold)
    expect(inbox.pending()?.destination == .thread(second), "Old consumer cannot clear latest tap")
    let latest = inbox.pending()!
    inbox.acknowledge(latest)
    expect(inbox.pending() == nil, "Accepted tap does not reopen on activation")
    defaults.set(first.uuidString, forKey: MobileNotificationInbox.legacyKey)
    expect(inbox.pending()?.destination == .thread(first), "Recover pending tap saved by previous app")
    expect(defaults.string(forKey: MobileNotificationInbox.legacyKey) == nil, "Legacy migration only once")
    inbox.enqueue(.agenda)
    expect(inbox.pending()?.destination == .agenda, "Agenda replaces earlier thread tap")
    try replyLedgerRegressions()
    print("Notification routing regressions passed")
  }

  static func replyLedgerRegressions() throws {
    let suite = "org2.reply-ledger-test.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    func expect(_ value: Bool, _ message: String) { precondition(value, message) }
    typealias Reply = MobileReplyNotificationLedger.Reply
    let ledger = MobileReplyNotificationLedger(defaults: defaults)
    let groceries = UUID(), other = UUID()
    let oldReply = Reply(threadID: groceries, messageID: UUID())
    let otherReply = Reply(threadID: other, messageID: UUID())

    expect(ledger.reconcile(latestReplies: [oldReply, otherReply]).isEmpty, "First list is only a baseline")
    expect(ledger.reconcile(latestReplies: [otherReply]).isEmpty, "Evicted transcript has no latest reply")
    expect(ledger.reconcile(latestReplies: [oldReply, otherReply]).isEmpty, "Rehydrated transcript does not replay its old reply")
    for _ in 0..<5 {
      _ = ledger.reconcile(latestReplies: [otherReply])
      expect(ledger.reconcile(latestReplies: [oldReply, otherReply]).isEmpty, "Repeated eviction never replays")
    }

    let newReply = Reply(threadID: groceries, messageID: UUID())
    expect(ledger.reconcile(latestReplies: [newReply, otherReply]) == [newReply], "A new reply alerts")
    expect(ledger.reconcile(latestReplies: [newReply, otherReply]).isEmpty, "A reply alerts only once")
    expect(ledger.reconcile(latestReplies: [oldReply, otherReply]).isEmpty, "Latest reply reverting to an older one does not alert")

    let pushed = Reply(userInfo: ["threadID": other.uuidString, "messageID": UUID().uuidString])!
    MobileReplyNotificationLedger(defaults: defaults).record([pushed])
    expect(ledger.reconcile(latestReplies: [newReply, pushed]).isEmpty, "Reply already shown by APNs is not polled again")
    expect(Reply(userInfo: ["threadID": other.uuidString]) == nil, "Reply identity needs a message ID")

    for _ in 0..<(MobileReplyNotificationLedger.recentRepliesPerThread + 5) {
      ledger.record([Reply(threadID: other, messageID: UUID())])
    }
    expect(!ledger.hasSeen(pushed), "Per-thread history is bounded")
    expect(ledger.hasSeen(newReply), "Bounding one thread keeps others")

    ledger.reset()
    expect(!ledger.isSeeded, "Reset forgets the baseline")
    expect(ledger.reconcile(latestReplies: [Reply(threadID: groceries, messageID: UUID())]).isEmpty, "Re-enabling notifications does not replay")

    // Re-pairing or switching hosts resets the ledger. A foreground APNs push
    // or an opened thread can record one reply before the next thread list
    // arrives; that must not make every other thread's old reply look new.
    ledger.reset()
    let history = (0..<200).map { _ in Reply(threadID: UUID(), messageID: UUID()) }
    ledger.record([history[0]])
    expect(!ledger.isSeeded, "Recording a single reply is not a thread-list baseline")
    expect(ledger.reconcile(latestReplies: history).isEmpty, "Old replies never replay after a reset")
    expect(ledger.isSeeded, "The first thread list seeds the ledger")
    let fresh = Reply(threadID: history[7].threadID, messageID: UUID())
    var afterReset = history
    afterReset[7] = fresh
    expect(ledger.reconcile(latestReplies: afterReset) == [fresh], "New replies alert after the baseline")

    // A ledger written by an earlier build, possibly after such a reset, is
    // never trusted as a baseline. Its replies stay seen, but the first list
    // after updating is silent.
    ledger.reset()
    ledger.record([history[0]])
    defaults.removeObject(forKey: MobileReplyNotificationLedger.seededKey)
    expect(!ledger.isSeeded, "A ledger without the seeded marker is not a baseline")
    expect(ledger.reconcile(latestReplies: history).isEmpty, "An earlier build's ledger does not replay")
    expect(ledger.hasSeen(history[0]), "An earlier build's replies stay seen")

    ledger.reset()
    let legacyReply = Reply(threadID: groceries, messageID: UUID())
    defaults.set(
      try JSONEncoder().encode([groceries.uuidString: legacyReply.messageID.uuidString]),
      forKey: MobileReplyNotificationLedger.legacyKey
    )
    expect(!ledger.isSeeded, "Legacy baseline is not trusted as seeded")
    expect(ledger.reconcile(latestReplies: [legacyReply]).isEmpty, "Legacy baseline migrates without replay")
    expect(defaults.data(forKey: MobileReplyNotificationLedger.legacyKey) == nil, "Legacy baseline is replaced")
    expect(ledger.hasSeen(legacyReply), "Migrated reply stays seen")
  }
}
