import Foundation

/// Choice blocks let an AI reply offer answers the user clicks instead of
/// typing:
///
///     #+begin_src choices :multiple
///     Which sections should I draft?
///     - Summary
///     - Risks
///     #+end_src
///
/// The shared renderer (`parseChoicesBlock` in `src/export.ts`) draws the
/// options as buttons. A click posts the option text from the page; the host
/// accepts it only if it is an option of a choices block in that message and
/// the user has not replied since, then sends it as the user's next message.
enum AIChatChoices {
  struct Block: Equatable, Sendable {
    let prompt: String
    let options: [String]
    let multiple: Bool
  }

  /// Matches `CHOICES_MAX_OPTIONS` in the renderer.
  static let maximumOptions = 20

  /// The terminated choices blocks with at least one option, in order.
  static func blocks(in orgText: String) -> [Block] {
    var blocks: [Block] = []
    var parameters: String?
    var body: [Substring] = []
    for line in orgText.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let open = parameters {
        if trimmed.lowercased() == "#+end_src" {
          let block = parse(body: body, parameters: open)
          if !block.options.isEmpty { blocks.append(block) }
          parameters = nil
          body = []
        } else {
          body.append(line)
        }
        continue
      }
      let lower = trimmed.lowercased()
      guard lower.hasPrefix("#+begin_src") else { continue }
      let rest = trimmed.dropFirst("#+begin_src".count)
      guard rest.first?.isWhitespace == true else { continue }
      let words = rest.split(whereSeparator: \.isWhitespace)
      guard words.first?.lowercased() == "choices" else { continue }
      parameters = words.dropFirst().joined(separator: " ")
    }
    return blocks
  }

  static func parse(body: [Substring], parameters: String) -> Block {
    var prompt: [String] = []
    var options: [String] = []
    for line in body {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let option = option(in: trimmed) {
        if !options.contains(option), options.count < maximumOptions { options.append(option) }
      } else if !trimmed.isEmpty {
        prompt.append(trimmed)
      }
    }
    let words = parameters.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    var multiple = false
    if let index = words.firstIndex(of: ":multiple") {
      let value = words.indices.contains(index + 1) ? words[index + 1] : ""
      multiple = !["no", "nil", "false"].contains(value)
    }
    return Block(prompt: prompt.joined(separator: " "), options: options, multiple: multiple)
  }

  private static func option(in line: String) -> String? {
    guard let marker = line.first, marker == "-" || marker == "+" else { return nil }
    var rest = line.dropFirst()
    guard rest.first?.isWhitespace == true else { return nil }
    rest = rest.drop(while: \.isWhitespace)
    // `- [ ] Option` is accepted as a plain option.
    for box in ["[]", "[ ]", "[x]", "[X]", "[-]"] where rest.hasPrefix(box) {
      let after = rest.dropFirst(box.count)
      if after.first?.isWhitespace == true, after.contains(where: { !$0.isWhitespace }) {
        rest = after.drop(while: \.isWhitespace)
      }
      break
    }
    let option = rest.trimmingCharacters(in: .whitespaces)
    return option.isEmpty ? nil : option
  }

  /// The reply to send for `selections` clicked in `messageID`, or nil when
  /// the click should be ignored: the message is not an assistant reply in
  /// `messages`, the user has already replied after it, or the selections are
  /// not options of one of its choices blocks (or several were posted for a
  /// single-answer block).
  static func answer(
    selecting selections: [String],
    in messageID: UUID,
    messages: [AIChatMessage]
  ) -> String? {
    guard !selections.isEmpty,
          let index = messages.firstIndex(where: { $0.id == messageID }),
          messages[index].role == .assistant,
          !messages[messages.index(after: index)...].contains(where: { $0.role == .user })
    else { return nil }
    let content = AIChatMessageOrgNormalizer.normalized(messages[index].content)
    let matches = blocks(in: content).contains { block in
      (block.multiple || selections.count == 1)
        && Set(selections).count == selections.count
        && selections.allSatisfy(block.options.contains)
    }
    return matches ? selections.joined(separator: ", ") : nil
  }

  /// Decodes the page's `choice` detail: a JSON array of option strings.
  static func selections(fromDetail detail: String?) -> [String]? {
    guard let data = detail?.data(using: .utf8),
          let values = try? JSONDecoder().decode([String].self, from: data),
          !values.isEmpty
    else { return nil }
    return values
  }
}
