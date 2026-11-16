import XCTest
@testable import Org2WorkspaceCore

final class OrgPlainTextTests: XCTestCase {
  func testEntryCopiesAsPlainTextWithoutOrgNotation() {
    let org = """
    ** TODO [#A] Call *Jane* about the =launch= plan [1/2] :work:urgent:
    SCHEDULED: <2026-11-16 Mon> DEADLINE: <2026-11-20 Fri>
    :PROPERTIES:
    :ID: 0d7a1c2e-1111-2222-3333-444455556666
    :END:
    :LOGBOOK:
    CLOCK: [2026-11-15 Sun 09:00]--[2026-11-15 Sun 09:30] =>  0:30
    :END:
    #+ATTR_HTML: :width 300
    # private comment
    See [[id:0d7a1c2e-aaaa][the brief]] and [[https://example.com/a_b]] for /details/.
    - [X] Draft agenda
    - [ ] Send ~invite~


    #+begin_src sh
    echo *keep* [[raw]]
    #+end_src
    *** Follow-up
    Done.
    """

    XCTAssertEqual(
      OrgPlainText.convert(org),
      """
      Call Jane about the launch plan
      See the brief and https://example.com/a_b for details.
      - [X] Draft agenda
      - [ ] Send invite

      echo *keep* [[raw]]
      Follow-up
      Done.

      """
    )
  }

  func testTitleKeywordKeepsItsValueAndFileLinksShowTheirPath() {
    let org = """
    #+TITLE: Weekly *notes*
    #+FILETAGS: :team:
    Read [[file:notes/plan.org::42]] and snake_case_name stays.
    """

    XCTAssertEqual(
      OrgPlainText.convert(org),
      "Weekly notes\nRead notes/plan.org and snake_case_name stays.\n"
    )
  }
}
