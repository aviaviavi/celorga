import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class MobileRemoteConditionalResponseTests: XCTestCase {
  private func jsonResponse(bytes: Int, fill: UInt8 = 0x61) -> MobileRemoteHTTPResponse {
    MobileRemoteHTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json; charset=utf-8"],
      body: Data(repeating: fill, count: bytes)
    )
  }

  func testLargeResponseCarriesStableEntityTag() {
    let first = MobileRemoteConditionalResponse.apply(to: jsonResponse(bytes: 4_096), ifNoneMatch: nil)
    let second = MobileRemoteConditionalResponse.apply(to: jsonResponse(bytes: 4_096), ifNoneMatch: nil)
    XCTAssertEqual(first.statusCode, 200)
    XCTAssertEqual(first.body.count, 4_096)
    XCTAssertNotNil(first.headers["ETag"])
    XCTAssertEqual(first.headers["ETag"], second.headers["ETag"])
  }

  func testMatchingTagReturnsEmptyNotModified() throws {
    let tag = try XCTUnwrap(
      MobileRemoteConditionalResponse.apply(to: jsonResponse(bytes: 4_096), ifNoneMatch: nil).headers["ETag"]
    )
    let response = MobileRemoteConditionalResponse.apply(to: jsonResponse(bytes: 4_096), ifNoneMatch: tag)
    XCTAssertEqual(response.statusCode, 304)
    XCTAssertTrue(response.body.isEmpty)
    XCTAssertEqual(response.headers["ETag"], tag)
    XCTAssertEqual(
      MobileRemoteConditionalResponse.apply(to: jsonResponse(bytes: 4_096), ifNoneMatch: "\"other\", W/\(tag)").statusCode,
      304
    )
  }

  func testChangedContentIsResentInFull() throws {
    let tag = try XCTUnwrap(
      MobileRemoteConditionalResponse.apply(to: jsonResponse(bytes: 4_096), ifNoneMatch: nil).headers["ETag"]
    )
    let changed = MobileRemoteConditionalResponse.apply(to: jsonResponse(bytes: 4_096, fill: 0x62), ifNoneMatch: tag)
    XCTAssertEqual(changed.statusCode, 200)
    XCTAssertEqual(changed.body.count, 4_096)
    XCTAssertNotEqual(changed.headers["ETag"], tag)
  }

  func testSmallAndUnsuccessfulResponsesAreUntouched() {
    let small = jsonResponse(bytes: 10)
    XCTAssertEqual(MobileRemoteConditionalResponse.apply(to: small, ifNoneMatch: "*"), small)
    let failure = MobileRemoteHTTPResponse.error(String(repeating: "x", count: 4_096), statusCode: 409)
    XCTAssertEqual(MobileRemoteConditionalResponse.apply(to: failure, ifNoneMatch: "*"), failure)
  }

  func testBackgroundConditionalResponseHonorsWildcard() async {
    let response = await MobileRemoteBackgroundWork().conditionalResponse(
      jsonResponse(bytes: 4_096),
      ifNoneMatch: "*"
    )
    XCTAssertEqual(response.statusCode, 304)
  }

  @MainActor
  func testRefreshGateSharesInFlightWorkAndReusesRecentResult() async {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let gate = MobileRemoteRequestRefreshGate(reuseInterval: 1.5, now: { clock })
    var started = 0
    var release: CheckedContinuation<Void, Never>?
    let work: @MainActor () async -> Void = {
      started += 1
      await withCheckedContinuation { release = $0 }
    }

    async let first: Void = gate.run(work)
    async let second: Void = gate.run(work)
    while release == nil { await Task.yield() }
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(started, 1, "Concurrent requests share one refresh")
    release?.resume()
    _ = await (first, second)

    await gate.run { started += 1 }
    XCTAssertEqual(started, 1, "A request right after a refresh reuses it")

    clock = clock.addingTimeInterval(2)
    await gate.run { started += 1 }
    XCTAssertEqual(started, 2, "An older refresh is not reused")

    gate.invalidate()
    await gate.run { started += 1 }
    XCTAssertEqual(started, 3, "Invalidation forces the next refresh")
    XCTAssertEqual(gate.runCount, 3)
  }
}
