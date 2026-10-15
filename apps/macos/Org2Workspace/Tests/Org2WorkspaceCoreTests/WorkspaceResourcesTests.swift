import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Issue #589: resources must resolve without SwiftPM's fatalError-ing
/// `Bundle.module`, so a packaged app launches on machines that did not build it.
final class WorkspaceResourcesTests: XCTestCase {
  func testEveryCoreResourceResolves() throws {
    let resourcesDir = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Sources/Org2WorkspaceCore/Resources")
    let names = try FileManager.default.contentsOfDirectory(atPath: resourcesDir.path)
      .filter { !$0.hasPrefix(".") }
    XCTAssertFalse(names.isEmpty)
    for name in names {
      let file = name as NSString
      XCTAssertNotNil(
        WorkspaceResources.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension),
        "\(name) must resolve through WorkspaceResources"
      )
    }
  }

  func testMissingResourceReturnsNilInsteadOfCrashing() {
    XCTAssertNil(WorkspaceResources.url(forResource: "DefinitelyMissing589", withExtension: "png"))
  }
}
