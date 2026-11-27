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

  private static func zlib(_ data: Data) throws -> Data {
    var output = Data([0x78, 0x9C])
    output.append(try (data as NSData).compressed(using: .zlib) as Data)
    let checksum = MobileRemoteRawResponse.adler32(data)
    output.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: checksum >> $0) })
    return output
  }
}
