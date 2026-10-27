import Foundation

/// Rules for agent-requested turns in a shared AI room.
///
/// An agent reply that @mentions another agent in the room asks that agent to
/// respond, and a background post (`org2 thread post --request-turn`) can name
/// agents explicitly. Each request becomes a hidden dispatch message that runs
/// through the ordinary send queue. A per-room limit caps how many requested
/// turns may run back to back before a person replies.
enum AIChatAgentTurnRequests {
  /// Text that can contain a hand-off mention. Code and verbatim spans are
  /// removed so an agent can name another agent (for example in an example
  /// command) without starting its turn.
  nonisolated static func mentionableText(_ text: String) -> String {
    var result = text
    for pattern in [fencedBlockPattern, orgBlockPattern, inlineCodePattern, orgVerbatimPattern] {
      result = pattern.stringByReplacingMatches(
        in: result,
        range: NSRange(location: 0, length: (result as NSString).length),
        withTemplate: " "
      )
    }
    return result
  }

  /// Room agents an agent reply asks to respond, in mention order. Mentions of
  /// the author, of agents outside the room, and inside code are ignored.
  nonisolated static func requestedDestinationIDs(
    inReply reply: String,
    authorDestinationID: String?,
    roomDestinationIDs: [String],
    destinations: [AIChatDestinationConfiguration]
  ) -> [String] {
    let routing = AIChatDestinationRouting(
      mentionableText(reply),
      destinations: destinations,
      allDestinationIDs: roomDestinationIDs
    )
    let room = Set(roomDestinationIDs)
    return routing.destinationIDs.filter { $0 != authorDestinationID && room.contains($0) }
  }

  /// Resolves `--request-turn` tokens (destination IDs or mentions, without
  /// `@`). Like a person's @mention, an explicit request may name any enabled
  /// agent; one outside the room joins it when its turn is queued. `all` and
  /// `both` still mean the agents already in the room.
  nonisolated static func resolveResponderTokens(
    _ tokens: [String],
    roomDestinationIDs: [String],
    destinations: [AIChatDestinationConfiguration]
  ) -> (destinationIDs: [String], unresolved: [String]) {
    let room = Set(roomDestinationIDs)
    let candidates = destinations.filter(\.isEnabled)
    let roomCandidates = candidates.filter { room.contains($0.id) }
    var resolved: [String] = []
    var unresolved: [String] = []
    for rawToken in tokens {
      var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if token.hasPrefix("@") { token.removeFirst() }
      guard !token.isEmpty else { continue }
      if token == "all" || token == "both" {
        for candidate in roomCandidates where !resolved.contains(candidate.id) {
          resolved.append(candidate.id)
        }
        continue
      }
      let match = candidates.first { $0.id.lowercased() == token }
        ?? candidates.first { $0.mention.lowercased() == token }
        ?? candidates.first { $0.id.lowercased() == "builtin.\(token)" }
      if let match {
        if !resolved.contains(match.id) { resolved.append(match.id) }
      } else if !unresolved.contains(token) {
        unresolved.append(token)
      }
    }
    return (resolved, unresolved)
  }

  /// Agent-requested turns since the latest message a person sent. A person's
  /// message (including a context-only post) resets the count.
  nonisolated static func consecutiveRequestedTurnCount(in messages: [AIChatMessage]) -> Int {
    var count = 0
    for message in messages.reversed() where message.role == .user {
      if message.provenance?.isAgentTurnRequest == true {
        count += 1
      } else if !message.isRoomDispatchCopy {
        break
      }
    }
    return count
  }

  /// How many of `requested` turns the limit still admits.
  nonisolated static func admittedCount(requested: Int, alreadyUsed: Int, limit: Int) -> Int {
    max(0, min(requested, limit - alreadyUsed))
  }

  private static let fencedBlockPattern = try! NSRegularExpression(
    pattern: #"```.*?(?:```|\z)"#,
    options: [.dotMatchesLineSeparators]
  )
  private static let orgBlockPattern = try! NSRegularExpression(
    pattern: #"(?im)^[ \t]*#\+begin_([a-z]+)\b.*?(?:^[ \t]*#\+end_\1\b[^\n]*|\z)"#,
    options: [.dotMatchesLineSeparators]
  )
  private static let inlineCodePattern = try! NSRegularExpression(
    pattern: #"`[^`\n]+`"#
  )
  private static let orgVerbatimPattern = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])([=~])(?=\S)[^\n]*?(?<=\S)\1(?![A-Za-z0-9])"#
  )
}
