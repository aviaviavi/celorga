import Foundation
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatChoicesTests: XCTestCase {
  private let reply = """
  Two questions.

  #+begin_src choices
  Ship it today?
  - Yes
  - No, wait
  - [ ] Later
  #+end_src

  #+BEGIN_SRC choices :multiple
  Which sections should I draft?
  - Summary
  - Risks
  #+END_SRC

  #+begin_src choices
  Unterminated
  - Ignored
  """

  func testParsesTerminatedChoicesBlocksLikeTheRenderer() {
    XCTAssertEqual(AIChatChoices.blocks(in: reply), [
      .init(prompt: "Ship it today?", options: ["Yes", "No, wait", "Later"], multiple: false),
      .init(prompt: "Which sections should I draft?", options: ["Summary", "Risks"], multiple: true),
    ])
    XCTAssertEqual(AIChatChoices.blocks(in: "#+begin_src choices :multiple no\n- a\n#+end_src").first?.multiple, false)
    XCTAssertTrue(AIChatChoices.blocks(in: "#+begin_src choices\nNo options\n#+end_src").isEmpty)
    XCTAssertTrue(AIChatChoices.blocks(in: "#+begin_src choicesx\n- a\n#+end_src").isEmpty)
  }

  func testAnswerAcceptsOnlyOptionsOfAnUnansweredReply() {
    let question = AIChatMessage(role: .user, content: "Help me ship")
    let assistant = AIChatMessage(role: .assistant, content: reply)
    let messages = [question, assistant]

    XCTAssertEqual(AIChatChoices.answer(selecting: ["No, wait"], in: assistant.id, messages: messages), "No, wait")
    XCTAssertEqual(
      AIChatChoices.answer(selecting: ["Summary", "Risks"], in: assistant.id, messages: messages),
      "Summary, Risks"
    )
    // Not an option, several answers to a single-answer block, or a mix of blocks.
    XCTAssertNil(AIChatChoices.answer(selecting: ["Delete everything"], in: assistant.id, messages: messages))
    XCTAssertNil(AIChatChoices.answer(selecting: ["Yes", "Later"], in: assistant.id, messages: messages))
    XCTAssertNil(AIChatChoices.answer(selecting: ["Yes", "Summary"], in: assistant.id, messages: messages))
    XCTAssertNil(AIChatChoices.answer(selecting: ["Ignored"], in: assistant.id, messages: messages))
    XCTAssertNil(AIChatChoices.answer(selecting: [], in: assistant.id, messages: messages))
    // Only assistant replies offer choices.
    XCTAssertNil(AIChatChoices.answer(selecting: ["Yes"], in: question.id, messages: messages))
    // Once the user has replied, the choices are spent.
    let answered = messages + [AIChatMessage(role: .user, content: "Yes")]
    XCTAssertNil(AIChatChoices.answer(selecting: ["Yes"], in: assistant.id, messages: answered))
  }

  func testDecodesThePageDetail() {
    XCTAssertEqual(AIChatChoices.selections(fromDetail: #"["Yes","No, wait"]"#), ["Yes", "No, wait"])
    XCTAssertNil(AIChatChoices.selections(fromDetail: "[]"))
    XCTAssertNil(AIChatChoices.selections(fromDetail: "Yes"))
    XCTAssertNil(AIChatChoices.selections(fromDetail: nil))
  }

  func testAgentsAreToldAboutChoicesAndCorpusRelativeLinks() {
    let contract = AIChatWorkspaceContext.responseFormattingContract
    XCTAssertTrue(contract.contains("#+begin_src choices"))
    XCTAssertTrue(contract.contains(":multiple"))
    XCTAssertTrue(contract.contains("sends the pick as the user's next message"))
    XCTAssertTrue(contract.contains("corpus-relative [[file:notes/note.org::42][source]]"))
    // The capabilities ride inside the contract every runtime prompt carries.
    XCTAssertTrue(contract.contains("Interactive content"))
    XCTAssertTrue(contract.contains("Celorga chat capabilities"))
  }

  func testTranscriptPagePostsChoiceClicks() {
    let script = AIChatTranscriptHTML.script
    XCTAssertTrue(script.contains("post('choice',id,JSON.stringify(values))"))
    XCTAssertTrue(script.contains(":has(~ article.user)"))
  }
}
