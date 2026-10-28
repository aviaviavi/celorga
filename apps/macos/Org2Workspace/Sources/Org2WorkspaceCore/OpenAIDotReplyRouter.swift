import Foundation

/// Decides which Celorga chat a dot's message belongs to.
///
/// A dot has one ChatGPT conversation, shared by every Celorga chat routed to
/// it. Celorga sends a chat's later messages as replies to the dot's latest
/// message in that chat, and the dot answers inside that reply thread, so its
/// answers (including results it posts minutes later) name the message they
/// answer. A message that names no earlier message answers the latest message
/// sent outside a reply thread.
struct OpenAIDotReplyRouter {
  struct Route: Hashable, Sendable {
    let threadID: UUID
    let transcriptURL: URL
  }

  /// Looks up chats Celorga knows about beyond this process's memory, such
  /// as after a relaunch.
  struct Lookup {
    /// The chat containing the Celorga message with this ID.
    var celorgaMessage: (UUID) -> Route? = { _ in nil }
    /// The chat whose saved reply anchor is this dot message.
    var anchor: (String) -> Route? = { _ in nil }
  }

  /// Bounds memory for a dot that stays busy for a long session.
  static let capacity = 1_000

  let selfMemberID: String
  private var routesByMessageID: [String: Route] = [:]
  private var routesByRequestID: [String: Route] = [:]
  private var insertionOrder: [String] = []
  private var deliveredIDs: Set<String> = []
  private var deliveredOrder: [String] = []
  private(set) var latestRoute: Route?
  private(set) var latestRootRoute: Route?

  init(selfMemberID: String) {
    self.selfMemberID = selfMemberID
  }

  /// Records a message Celorga posted for a chat. `isReply` is false when it
  /// was sent outside a reply thread.
  mutating func recordSent(_ message: OpenAIDotMessage, requestID: String, isReply: Bool, route: Route) {
    remember(route, forKey: "m:\(message.id)")
    remember(route, forKey: "r:\(requestID.lowercased())")
    latestRoute = route
    if !isReply { latestRootRoute = route }
  }

  /// Records that a dot message was shown in a chat, so it is never shown
  /// again and replies to it follow it there.
  mutating func recordDelivered(_ messageID: String, route: Route) {
    remember(route, forKey: "m:\(messageID)")
    guard deliveredIDs.insert(messageID).inserted else { return }
    deliveredOrder.append(messageID)
    if deliveredOrder.count > Self.capacity {
      deliveredIDs.remove(deliveredOrder.removeFirst())
    }
  }

  func wasDelivered(_ messageID: String) -> Bool {
    deliveredIDs.contains(messageID)
  }

  /// The chat a dot message belongs to, or nil when it answers a message
  /// sent from outside Celorga (for example in ChatGPT on a phone).
  func route(for message: OpenAIDotMessage, lookup: Lookup = Lookup()) -> Route? {
    guard let target = message.replyTo else {
      return latestRootRoute ?? latestRoute
    }
    if let route = routesByMessageID["m:\(target.messageID)"] {
      return route
    }
    if let requestID = target.requestID?.lowercased() {
      if let route = routesByRequestID["r:\(requestID)"] {
        return route
      }
      if let id = UUID(uuidString: requestID), let route = lookup.celorgaMessage(id) {
        return route
      }
    }
    if let route = lookup.anchor(target.messageID) {
      return route
    }
    if target.memberID == selfMemberID || target.requestID != nil {
      return nil
    }
    // A reply to one of the dot's own messages that Celorga never saw.
    return latestRoute
  }

  private mutating func remember(_ route: Route, forKey key: String) {
    let isNew: Bool
    if key.hasPrefix("r:") {
      isNew = routesByRequestID.updateValue(route, forKey: key) == nil
    } else {
      isNew = routesByMessageID.updateValue(route, forKey: key) == nil
    }
    guard isNew else { return }
    insertionOrder.append(key)
    if insertionOrder.count > Self.capacity * 2 {
      let oldest = insertionOrder.removeFirst()
      routesByMessageID.removeValue(forKey: oldest)
      routesByRequestID.removeValue(forKey: oldest)
    }
  }
}
