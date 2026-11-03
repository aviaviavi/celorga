import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

/// In a narrow pane the People/Companies header crushed its title into a
/// one-character column and the filter field into a sliver. The controls
/// now move under the title instead.
@MainActor
final class CRMHeaderLayoutTests: XCTestCase {
  func testHeaderKeepsTheFilterUsableAtEveryPaneWidth() throws {
    let suite = "CRMHeaderLayoutTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WorkspaceStore(defaults: defaults, legacyDefaultsDomains: [])

    for kind in [CRMKind.companies, .people] {
      for width in [1200.0, 620.0, 420.0] {
        let hosting = NSHostingView(rootView: PeopleCompaniesView(kind: kind).environment(store))
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
          styleMask: [.titled],
          backing: .buffered,
          defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(Self.textFields(in: hosting).first, "\(kind) at \(width)")
        let frame = field.convert(field.bounds, to: hosting)
        XCTAssertGreaterThanOrEqual(frame.width, 120, "Filter is squeezed for \(kind) at \(width)pt")
        // The header (title, filter, controls) stays compact rather than
        // growing with a wrapped title.
        let bottomFromTop = hosting.isFlipped ? frame.maxY : hosting.bounds.height - frame.minY
        XCTAssertLessThan(bottomFromTop, 150, "Header grew tall for \(kind) at \(width)pt")
        if let directory = ProcessInfo.processInfo.environment["CELORGA_CRM_SNAPSHOTS"],
           let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
          hosting.cacheDisplay(in: hosting.bounds, to: rep)
          try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(kind)-\(Int(width)).png"))
        }
        window.orderOut(nil)
      }
    }
  }

  private static func textFields(in view: NSView) -> [NSTextField] {
    var found: [NSTextField] = []
    for subview in view.subviews {
      if let field = subview as? NSTextField, field.isEditable { found.append(field) }
      found += textFields(in: subview)
    }
    return found
  }
}
