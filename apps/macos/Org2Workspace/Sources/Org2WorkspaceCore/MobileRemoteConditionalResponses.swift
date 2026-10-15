import CryptoKit
import Foundation

/// Conditional GET support for Mobile Remote. The phone polls the thread list
/// and an open thread every few seconds; when nothing changed, a 304 replaces
/// a response that can be hundreds of kilobytes on a large chat history.
public enum MobileRemoteConditionalResponse {
  /// Bodies smaller than this are cheaper to resend than to validate.
  public static let minimumBodyBytes = 1_024

  /// A strong validator derived only from the exact response bytes, so a
  /// 304 is returned only when the client already holds identical content.
  public static func entityTag(for body: Data) -> String {
    let digest = SHA256.hash(data: body)
    return "\"" + digest.prefix(16).map { String(format: "%02x", $0) }.joined() + "\""
  }

  public static func apply(
    to response: MobileRemoteHTTPResponse,
    ifNoneMatch: String?
  ) -> MobileRemoteHTTPResponse {
    guard response.statusCode == 200, response.body.count >= minimumBodyBytes else {
      return response
    }
    let tag = entityTag(for: response.body)
    var headers = response.headers
    headers["ETag"] = tag
    if let ifNoneMatch, matches(ifNoneMatch, tag: tag) {
      headers["Content-Type"] = nil
      return MobileRemoteHTTPResponse(statusCode: 304, headers: headers, body: Data())
    }
    return MobileRemoteHTTPResponse(statusCode: response.statusCode, headers: headers, body: response.body)
  }

  static func matches(_ ifNoneMatch: String, tag: String) -> Bool {
    ifNoneMatch.split(separator: ",").contains { candidate in
      var value = candidate.trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("W/") { value.removeFirst(2) }
      return value == tag || value == "*"
    }
  }
}

extension MobileRemoteBackgroundWork {
  /// Hashes off the main actor; large bodies take a measurable moment.
  public func conditionalResponse(
    _ response: MobileRemoteHTTPResponse,
    ifNoneMatch: String?
  ) async -> MobileRemoteHTTPResponse {
    guard response.statusCode == 200,
          response.body.count >= MobileRemoteConditionalResponse.minimumBodyBytes
    else {
      return response
    }
    return await Task.detached(priority: .userInitiated) {
      MobileRemoteConditionalResponse.apply(to: response, ifNoneMatch: ifNoneMatch)
    }.value
  }
}

/// Shares one in-flight refresh among concurrent callers and lets callers
/// arriving within `reuseInterval` of a completed refresh use its result.
@MainActor
public final class MobileRemoteRequestRefreshGate {
  public let reuseInterval: TimeInterval
  private let now: () -> Date
  private var inFlight: Task<Void, Never>?
  private var completedAt: Date?
  public private(set) var runCount = 0

  public init(reuseInterval: TimeInterval, now: @escaping () -> Date = Date.init) {
    self.reuseInterval = reuseInterval
    self.now = now
  }

  public func run(_ work: @escaping @MainActor () async -> Void) async {
    if let inFlight {
      await inFlight.value
      return
    }
    if let completedAt, now().timeIntervalSince(completedAt) < reuseInterval {
      return
    }
    runCount += 1
    let task = Task { @MainActor in await work() }
    inFlight = task
    await task.value
    inFlight = nil
    completedAt = now()
  }

  public func invalidate() {
    completedAt = nil
  }
}
