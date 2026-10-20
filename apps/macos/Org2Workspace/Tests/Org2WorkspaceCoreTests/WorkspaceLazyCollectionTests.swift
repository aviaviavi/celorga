import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class WorkspaceLazyCollectionTests: XCTestCase {
  func testFiveThousandRowsStayLazyAcrossRepeatedResizeAndUseNoTableView() async throws {
    let probe = WorkspaceLazyCollectionProbe()
    let rowActionID = WorkspaceCollectionRowAccessibilityIdentity.accessibilityIdentifier(
      kind: "probe",
      id: 0
    )
    let hostingView = NSHostingView(rootView: WorkspaceLazyCollection {
      Section {
        ForEach(0..<5_000, id: \.self) { index in
          if index == 0 {
            HStack {
              Text("Row 0")
              Button("Nested action") {
                probe.nestedActionCount += 1
              }
            }
            .workspaceAccessibleCollectionRow(
              kind: "probe",
              id: index,
              label: "Row 0",
              isSelected: true,
              open: { probe.openActionCount += 1 }
            )
            .workspaceLazyRow(id: index)
            .onAppear { probe.mountedRowIDs.insert(index) }
          } else {
            Text("Row \(index)")
              .frame(height: 28)
              .workspaceLazyRow(id: index)
              .onAppear { probe.mountedRowIDs.insert(index) }
          }
        }
      } header: {
        WorkspaceLazySectionHeader {
          Text("Synthetic section")
        }
      }
    })
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.orderFrontRegardless()
    defer {
      window.contentView = nil
      window.close()
    }

    await settle(window: window, hostingView: hostingView)

    let mountedViews: [NSView] = [hostingView] + descendantViews(in: hostingView)
    XCTAssertTrue(
      mountedViews.contains { $0 is NSScrollView },
      "The reusable collection shell must publish a native scroll view"
    )
    XCTAssertFalse(
      mountedViews.contains { $0 is NSTableView },
      "The reusable collection shell must never fall back to automatic-height NSTableView rows"
    )
    XCTAssertGreaterThan(probe.mountedRowIDs.count, 0)
    XCTAssertLessThan(
      probe.mountedRowIDs.count,
      500,
      "A 5,000-row collection must realize only the viewport neighborhood"
    )

    for index in 0..<40 {
      let width: CGFloat = index.isMultiple(of: 2) ? 640 : 1_040
      let height: CGFloat = index.isMultiple(of: 3) ? 360 : 620
      window.setContentSize(NSSize(width: width, height: height))
      draw(window: window, hostingView: hostingView)
      await Task.yield()
    }
    await settle(window: window, hostingView: hostingView)

    XCTAssertLessThan(
      probe.mountedRowIDs.count,
      500,
      "Resizing must not eagerly instantiate the 5,000-row backing collection"
    )

    let rowTarget = try XCTUnwrap(
      mountedViews.first(where: {
        $0.accessibilityIdentifier() == rowActionID
      }),
      "Gesture-only rows must publish a stable native accessibility target"
    )
    XCTAssertTrue(rowTarget.isAccessibilitySelected())
    XCTAssertTrue(rowTarget.accessibilityPerformPress())
    XCTAssertEqual(probe.openActionCount, 1)

  }

  func testEveryConvertedProductionCollectionUsesTheReusableLazyShell() throws {
    let source = try String(contentsOf: contentViewSourceURL, encoding: .utf8)
    let scopes: [ConvertedCollectionScope] = [
      .init(name: "ExternalThreadsView", nextName: "ExternalThreadRow"),
      .init(name: "GoalsView", nextName: "AgentGoalRow"),
      .init(name: "AgentsView", nextName: "AgentProfileRow"),
      .init(name: "WorkflowsView", nextName: "WorkflowRow"),
      .init(name: "RunCenterView", nextName: "RunCenterSearch", expectsSectionHeader: true),
      .init(name: "ApprovalsView", nextName: "ApprovalControls"),
      .init(name: "AgendaItemListView", nextName: "AssignedAgendaListView", expectsSectionHeader: true),
      .init(name: "AssignedAgendaListView", nextName: "AgendaBulkActionBar", expectsSectionHeader: true),
      // Workspace search is one ranked list; result kinds are not sections.
      .init(
        name: "SearchView",
        nextName: "AgentWorkSearchRow",
        minimumLazyShellCount: 2
      ),
      .init(name: "MeetingsView", nextName: "MeetingTranscriptionProgressView", expectsSectionHeader: true),
    ]

    for converted in scopes {
      let scope = String(try sourceScope(
        named: converted.name,
        endingBefore: converted.nextName,
        in: source
      ))
      XCTAssertGreaterThanOrEqual(
        scope.components(separatedBy: "WorkspaceLazyCollection {").count - 1,
        converted.minimumLazyShellCount,
        "\(converted.name) must render through WorkspaceLazyCollection"
      )
      XCTAssertNil(
        scope.range(of: #"\bList\s*\{"#, options: .regularExpression),
        "\(converted.name) must not reintroduce an NSTableView-backed SwiftUI List"
      )
      if converted.expectsSectionHeader {
        XCTAssertTrue(
          scope.contains("WorkspaceLazySectionHeader"),
          "\(converted.name) must preserve its visible section semantics"
        )
      }
    }

    let runCenter = String(try sourceScope(
      named: "RunCenterView",
      endingBefore: "RunCenterSearch",
      in: source
    ))
    XCTAssertTrue(
      runCenter.contains("WorkspaceCollectionRowAccessibilityIdentity.runShowMore"),
      "The lazy Run Center must preserve its shipping pagination control"
    )
    XCTAssertTrue(
      source.contains(".accessibilityElement(children: .contain)"),
      "Gesture-only row accessibility must continue to contain nested child controls"
    )
  }

  private var contentViewSourceURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/Org2WorkspaceCore/ContentView.swift")
  }

  private func sourceScope(
    named name: String,
    endingBefore nextName: String,
    in source: String
  ) throws -> Substring {
    let start = try XCTUnwrap(
      source.range(of: "private struct \(name): View"),
      "Missing \(name) in ContentView.swift"
    )
    let end = try XCTUnwrap(
      source.range(
        of: "private struct \(nextName)",
        range: start.upperBound..<source.endIndex
      ),
      "Missing scope boundary \(nextName) after \(name)"
    )
    return source[start.lowerBound..<end.lowerBound]
  }

  private func settle(
    window: NSWindow,
    hostingView: NSView
  ) async {
    for _ in 0..<4 {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
          continuation.resume(returning: ())
        }
      }
      draw(window: window, hostingView: hostingView)
    }
  }

  private func draw(window: NSWindow, hostingView: NSView) {
    hostingView.needsLayout = true
    hostingView.layoutSubtreeIfNeeded()
    window.contentView?.needsLayout = true
    window.contentView?.layoutSubtreeIfNeeded()
    window.contentView?.displayIfNeeded()
    window.update()
    CATransaction.flush()
  }

  private func descendantViews(in view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendantViews(in: $0) }
  }

}

@MainActor
private final class WorkspaceLazyCollectionProbe {
  var mountedRowIDs = Set<Int>()
  var openActionCount = 0
  var nestedActionCount = 0
}

private struct ConvertedCollectionScope {
  let name: String
  let nextName: String
  let minimumLazyShellCount: Int
  let expectsSectionHeader: Bool

  init(
    name: String,
    nextName: String,
    minimumLazyShellCount: Int = 1,
    expectsSectionHeader: Bool = false
  ) {
    self.name = name
    self.nextName = nextName
    self.minimumLazyShellCount = minimumLazyShellCount
    self.expectsSectionHeader = expectsSectionHeader
  }
}
