import XCTest
@testable import Org2WorkspaceCore

final class OrgLinkSearchOptionTests: XCTestCase {
  private let note = """
  #+TITLE: Atlas
  * Plan
  :PROPERTIES:
  :ID: plan-42
  :END:
  Intro.
  ** TODO [#B] Milestones [1/2] :work:
  Window opens <<Launch Window>> here.
  ** Risks
  :PROPERTIES:
  :CUSTOM_ID: risk-list
  :END:
  #+NAME: budget-table
  | a |
  * Elsewhere
  <<launch window>> outside the subtree.
  """

  func testParsesIDTargetsWithSearchOptions() {
    XCTAssertEqual(OrgLinkSearchOption.parseIDTarget("id:plan-42"), .init(id: "plan-42", search: nil))
    XCTAssertEqual(OrgLinkSearchOption.parseIDTarget("ID:plan-42::Launch Window"), .init(id: "plan-42", search: "Launch Window"))
    XCTAssertEqual(OrgLinkSearchOption.parseIDTarget("id:plan-42::12"), .init(id: "plan-42", search: "12"))
    XCTAssertNil(OrgLinkSearchOption.parseIDTarget("id:::x"))
    XCTAssertNil(OrgLinkSearchOption.parseIDTarget("file:a.org::x"))
    XCTAssertTrue(OrgLinkSearchOption.idTargetNeedsFileSearch("id:plan-42::Risks"))
    XCTAssertFalse(OrgLinkSearchOption.idTargetNeedsFileSearch("id:plan-42::12"))
    XCTAssertFalse(OrgLinkSearchOption.idTargetNeedsFileSearch("id:plan-42"))
  }

  func testIDSearchMatchesTargetsInSubtreeFirstThenFile() {
    func line(_ search: String?) -> Int? {
      OrgLinkSearchOption.line(forIDTarget: .init(id: "PLAN-42", search: search), in: note)
    }
    XCTAssertEqual(line(nil), 2)
    XCTAssertEqual(line("launch window"), 8, "dedicated target inside the ID subtree wins")
    XCTAssertEqual(line("*Milestones"), 7, "keyword, priority, cookie and tags are ignored")
    XCTAssertEqual(line("Risks"), 9, "plain text falls back to a heading title")
    XCTAssertEqual(line("#risk-list"), 11)
    XCTAssertEqual(line("budget-table"), 13)
    XCTAssertEqual(line("outside the"), 16, "plain text falls back to the first containing line")
    XCTAssertEqual(line("3"), 3)
    XCTAssertNil(line("*Missing"))
  }

  func testFileSearchUsesTheSameSemantics() {
    XCTAssertEqual(OrgLinkSearchOption.line(for: "launch window", in: note), 8)
    XCTAssertEqual(OrgLinkSearchOption.line(for: "*elsewhere", in: note), 15)
  }

  func testResolverHandlesIDSearchOptions() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-id-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("atlas.org")
    try note.write(to: file, atomically: true, encoding: .utf8)
    let node = OrgRoamNodeReference(idValue: "plan-42", title: "Plan", file: file.path, line: 2)
    let resolver = OrgRoamLinkResolver(nodes: [node])

    XCTAssertEqual(resolver.resolve(target: "id:plan-42")?.fileReference.line, 2)
    XCTAssertEqual(resolver.resolve(target: "id:plan-42::14")?.fileReference.line, 14)
    XCTAssertEqual(resolver.resolve(target: "id:plan-42::Launch Window")?.fileReference.line, 2)
    XCTAssertEqual(resolver.exactCandidates(for: "id:plan-42::Risks"), [node])
    XCTAssertNil(resolver.resolve(target: "id:other::Risks"))

    let searched = await resolver.resolveSearchingFile(target: "id:plan-42::Launch Window")
    XCTAssertEqual(searched?.fileReference, AIChatFileReference(path: file.path, line: 8))
    let unmatched = await resolver.resolveSearchingFile(target: "id:plan-42::*Nowhere")
    XCTAssertEqual(unmatched?.fileReference.line, 2, "an unmatched search lands on the ID")
  }

  func testFileLinksResolveDedicatedTargets() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-file-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.org")
    try "* Source\n".write(to: source, atomically: true, encoding: .utf8)
    try note.write(to: root.appendingPathComponent("atlas.org"), atomically: true, encoding: .utf8)

    let resolved = await OrgHTMLLinkTarget.resolve("file:atlas.org::Launch Window", relativeTo: source.path, corpusRoot: root)
    XCTAssertEqual(resolved?.line, 8)
    let custom = await OrgHTMLLinkTarget.resolve("file:atlas.org::#risk-list", relativeTo: source.path, corpusRoot: root)
    XCTAssertEqual(custom?.line, 11)
  }

  func testChatCitationNormalizerKeepsIDLineCitations() {
    let id = "8f14e45f-ceea-4c8b-9a3f-2f0d1b6c7a10"
    XCTAssertEqual(
      AIChatCitationNormalizer.normalized("See [notes](id:\(id)::42)."),
      "See [[id:\(id)::42][notes]]."
    )
    XCTAssertEqual(
      AIChatCitationNormalizer.normalized("See [[id:\(id)::42][notes]]."),
      "See [[id:\(id)::42][notes]]."
    )
  }
}
