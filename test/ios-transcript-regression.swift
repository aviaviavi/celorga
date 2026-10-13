import Foundation

@main
struct MobileTranscriptRegression {
  struct Message: Identifiable { let id: Int }

  static func main() {
    let messages = (0..<1_003).map { Message(id: $0) }
    let latest = MobileRemoteTranscriptPage.make(messages: messages, endingAt: nil)
    precondition(latest == 991..<1_003)
    var page = latest
    var visited = Array(page)
    while page.lowerBound > 0 {
      page = MobileRemoteTranscriptPage.make(messages: messages, endingAt: messages[page.lowerBound - 1].id)
      precondition(page.count <= MobileRemoteTranscriptPage.messageLimit)
      visited.insert(contentsOf: page, at: 0)
    }
    precondition(visited == Array(messages.indices), "Backward paging must preserve every message exactly once")
    visited = Array(page)
    while page.upperBound < messages.count {
      page = MobileRemoteTranscriptPage.newerPage(messages: messages, after: page.upperBound)
      precondition(page.count <= MobileRemoteTranscriptPage.messageLimit)
      visited.append(contentsOf: page)
    }
    precondition(visited == Array(messages.indices), "Forward paging must preserve every message exactly once")

    let history = MobileRemoteTranscriptPage.make(messages: messages, endingAt: 87)
    let appended = messages + [Message(id: 1_003)]
    precondition(MobileRemoteTranscriptPage.make(messages: appended, endingAt: 87) == history)
    precondition(MobileRemoteTranscriptPage.make(messages: [Message](), endingAt: nil).isEmpty)
    precondition(MobileRemoteTranscriptPage.make(messages: messages, endingAt: -1) == latest)

    precondition(MobileRemoteTranscriptPage.reveal(1_000, in: messages) == .latest)
    precondition(MobileRemoteTranscriptPage.reveal(87, in: messages) == .endingAt(93))
    let revealed = MobileRemoteTranscriptPage.make(messages: messages, endingAt: 93)
    precondition(revealed.contains(87), "Jumping to an output's reply must page it into view")
    precondition(MobileRemoteTranscriptPage.reveal(5_000, in: messages) == nil)

    for text in ["", "A short reply", "* Heading\n\nA [[https://example.com][link]].", "Hello 👨‍👩‍👧‍👦"] {
      let preview = MobileRemoteTranscriptPage.preview(text)
      precondition(preview.text == text && !preview.isTruncated)
    }
    for text in [String(repeating: "x", count: 2_000_000), String(repeating: "👨‍👩‍👧‍👦", count: 10_000), String(repeating: "\n", count: 50_000), String(repeating: "\r", count: 50_000), String(repeating: "\r\n", count: 50_000)] {
      let preview = MobileRemoteTranscriptPage.preview(text)
      precondition(preview.isTruncated)
      precondition(preview.text.utf8.count <= MobileRemoteTranscriptPage.messageByteLimit)
      precondition(preview.text.filter { $0.isNewline }.count + 1 <= MobileRemoteTranscriptPage.messageLineLimit)
      precondition(text.utf8.starts(with: preview.text.utf8), "Preview must preserve original UTF-8 without replacement characters")
    }
    let exactlyFull = String(repeating: "x", count: MobileRemoteTranscriptPage.messageByteLimit)
    precondition(!MobileRemoteTranscriptPage.preview(exactlyFull).isTruncated)
    precondition(MobileRemoteTranscriptPage.preview(exactlyFull + "x").isTruncated)
    print("iOS transcript paging and rendering-budget regressions passed")
  }
}
