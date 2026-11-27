import XCTest
@testable import Org2Mobile

/// Hosts deflate large JSON for phones that ask; the phone inflates it and
/// refuses anything that does not verify.
final class MobileRemoteClientCompressionTests: XCTestCase {
  func testInflatesZlibBodiesAndPassesIdentityBodiesThrough() throws {
    let json = Data(String(repeating: #"{"title":"New Chat","runtime":"codex"},"#, count: 2_000).utf8)
    let compressed = try Self.zlib(json)
    let response = MobileRemoteRawResponse(
      statusCode: 200, entityTag: "\"tag\"", contentEncoding: "deflate", body: compressed
    )
    let decoded = try response.decoded()
    XCTAssertEqual(decoded.body, json)
    XCTAssertEqual(decoded.entityTag, "\"tag\"")
    XCTAssertNil(decoded.contentEncoding)

    let identity = MobileRemoteRawResponse(statusCode: 200, entityTag: nil, body: json)
    XCTAssertEqual(try identity.decoded().body, json)
  }

  func testRejectsCorruptOrUnknownEncodings() throws {
    var corrupt = try Self.zlib(Data("hello hello hello hello".utf8))
    corrupt[corrupt.count - 1] ^= 0xFF
    XCTAssertThrowsError(try MobileRemoteRawResponse(
      statusCode: 200, entityTag: nil, contentEncoding: "deflate", body: corrupt
    ).decoded())
    XCTAssertThrowsError(try MobileRemoteRawResponse(
      statusCode: 200, entityTag: nil, contentEncoding: "br", body: Data("x".utf8)
    ).decoded())
  }

  func testDeltaThreadListsMergeIntoTheCachedList() throws {
    func summary(_ id: UUID, _ title: String, updated: Double, settled: Bool = false, pinned: Bool = false) -> MobileRemoteThreadSummary {
      let json = """
      {"id":"\(id.uuidString)","title":"\(title)","runtime":"codex","isSharedRoom":false,
       "updatedAt":\(updated),"isSettled":\(settled),"isPinned":\(pinned),"isRunning":false,"unreadMessageCount":0}
      """
      return try! JSONDecoder().decode(MobileRemoteThreadSummary.self, from: Data(json.utf8))
    }
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let current = [summary(a, "A", updated: 30), summary(b, "B", updated: 20), summary(c, "C", updated: 10)]
    let project = try JSONDecoder().decode(MobileRemoteProjectSummary.self,
      from: Data(#"{"id":"p","title":"P","color":"blue","threadIDs":[]}"#.utf8))

    let delta = MobileRemoteThreadList(
      threads: [summary(c, "C2", updated: 40), summary(d, "D", updated: 5, pinned: true)],
      projects: nil, cursor: "e.2", isDelta: true, removedThreadIDs: [b]
    )
    let merged = MobileRemoteThreadList.merged(current: current, currentProjects: [project], response: delta)
    XCTAssertEqual(merged.threads.map(\.title), ["D", "C2", "A"], "Pinned first, then newest")
    XCTAssertEqual(merged.projects.map(\.id), ["p"], "A delta without projects keeps them")

    let full = MobileRemoteThreadList(threads: [summary(a, "A", updated: 30)], projects: [])
    let replaced = MobileRemoteThreadList.merged(current: current, currentProjects: [project], response: full)
    XCTAssertEqual(replaced.threads.map(\.title), ["A"], "A full list (or an older host) replaces the cache")
    XCTAssertTrue(replaced.projects.isEmpty)
  }

  private static func zlib(_ data: Data) throws -> Data {
    var output = Data([0x78, 0x9C])
    output.append(try (data as NSData).compressed(using: .zlib) as Data)
    let checksum = MobileRemoteRawResponse.adler32(data)
    output.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: checksum >> $0) })
    return output
  }
}
