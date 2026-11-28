import AppKit
import XCTest
@testable import Org2WorkspaceCore

final class OrgLinkContextMenuTests: XCTestCase {
  func testDestinationsCoverOrgFileThreadAndWebLinks() {
    XCTAssertEqual(
      OrgLinkContextMenu.destination(forHref: "org2-workspace://open-link?target=id%3Aabc-123"),
      .orgTarget("id:abc-123")
    )
    XCTAssertEqual(
      OrgLinkContextMenu.destination(forHref: "org2-workspace://open-file?path=%2Ftmp%2Fa.org&line=4"),
      .fileReference(AIChatFileReference(path: "/tmp/a.org", line: 4))
    )
    let thread = UUID()
    XCTAssertEqual(
      OrgLinkContextMenu.destination(forHref: AIChatThreadLinks.url(for: thread.uuidString)),
      .chatThread(thread)
    )
    XCTAssertEqual(
      OrgLinkContextMenu.destination(forHref: "https://example.com/a"),
      .web(URL(string: "https://example.com/a")!)
    )
    XCTAssertNil(OrgLinkContextMenu.destination(forHref: "org2-workspace://ask-ai?line=3"))
    XCTAssertNil(OrgLinkContextMenu.destination(forHref: "javascript:alert(1)"))
    XCTAssertNil(OrgLinkContextMenu.destination(forHref: ""))
  }

  func testMenuOffersNewTabOnlyWhereALinkCanOpenInATab() {
    let web = OrgLinkContextMenu.Destination.web(URL(string: "https://example.com")!)
    XCTAssertEqual(
      OrgLinkContextMenu.items(for: web, canOpenInNewTab: true).map(\.title),
      ["Open Link", "Open Link in New Tab", "Copy Link"]
    )
    XCTAssertEqual(
      OrgLinkContextMenu.items(for: .orgTarget("id:x"), canOpenInNewTab: false).map(\.title),
      ["Open Link", "Copy Link"]
    )
    XCTAssertEqual(
      OrgLinkContextMenu.items(for: .chatThread(UUID()), canOpenInNewTab: true).map(\.title),
      ["Open Link", "Copy Link"]
    )
    XCTAssertEqual(
      OrgLinkContextMenu.items(for: .web(URL(string: "mailto:a@b.co")!), canOpenInNewTab: true).map(\.title),
      ["Open Link", "Copy Link"]
    )
    XCTAssertEqual(OrgLinkContextMenu.Destination.orgTarget("id:x").copyText, "id:x")
    XCTAssertEqual(OrgLinkContextMenu.Destination.web(URL(string: "mailto:a@b.co")!).copyText, "a@b.co")
  }

  func testScriptReportsLinksBeforeTheEntryMenu() {
    let script = OrgLinkContextMenu.installationScript
    XCTAssertTrue(script.contains("closest('a[href]')"))
    XCTAssertTrue(script.contains("stopImmediatePropagation"))
    XCTAssertTrue(script.contains("messageHandlers.org2LinkContextMenu.postMessage"))
    XCTAssertEqual(
      OrgLinkContextMenu.request(fromMessageBody: [
        "href": "org2-workspace://open-link?target=id%3Ax", "line": 7, "x": 3, "y": 4,
      ] as [String: Any])?.line,
      7
    )
    XCTAssertNil(OrgLinkContextMenu.request(fromMessageBody: ["href": "about:blank"] as [String: Any]))
  }

  @MainActor
  func testDocumentLinkMenuPutsLinkActionsAboveEntryActionsAndOpensInANewTab() throws {
    let coordinator = OrgHTMLDocumentView.Coordinator()
    coordinator.source = EntrySource(
      file: "/tmp/link-menu.org",
      startLine: 1,
      endLineExclusive: 3,
      text: "* Entry\n[[id:abc][Link]]",
      isSubtree: false
    )
    var openedInNewTab: [AIChatFileReference] = []
    var openedInPlace: [AIChatFileReference] = []
    coordinator.openOrgFileReference = { openedInPlace.append($0) }
    coordinator.openOrgFileReferenceInNewTab = { openedInNewTab.append($0) }
    let request = try XCTUnwrap(OrgLinkContextMenu.request(fromMessageBody: [
      "href": "org2-workspace://open-file?path=%2Ftmp%2Ftarget.org&line=9", "line": 1, "x": 0, "y": 0,
    ] as [String: Any]))

    let menu = coordinator.makeLinkContextMenu(request)
    XCTAssertEqual(Array(menu.items.prefix(4).map(\.title)), ["Open Link", "Open Link in New Tab", "Copy Link", ""])
    XCTAssertTrue(menu.items.contains { $0.title == "Entry View" })

    let newTab = try XCTUnwrap(menu.items.first { $0.title == "Open Link in New Tab" })
    _ = newTab.target?.perform(newTab.action, with: newTab)
    XCTAssertEqual(openedInNewTab, [AIChatFileReference(path: "/tmp/target.org", line: 9)])
    XCTAssertTrue(openedInPlace.isEmpty)

    let outside = try XCTUnwrap(OrgLinkContextMenu.request(fromMessageBody: [
      "href": "https://example.com", "line": 0, "x": 0, "y": 0,
    ] as [String: Any]))
    XCTAssertEqual(coordinator.makeLinkContextMenu(outside).items.map(\.title), ["Open Link", "Open Link in New Tab", "Copy Link"])
  }
}
