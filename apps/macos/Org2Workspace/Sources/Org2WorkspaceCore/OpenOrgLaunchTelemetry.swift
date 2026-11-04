import Combine
import Foundation

/// One best-effort launch event per production app process, plus a few named
/// product events such as the one-time GitHub star prompt. Every event goes to
/// the same Scarf endpoint and is told apart by its `event` field. No corpus or
/// installation identity is read.
@MainActor
public final class OpenOrgLaunchTelemetry: ObservableObject {
  public static let enabledKey = "OpenOrg.launchTelemetry.enabled.v1"
  public static let endpoint = URL(string: "https://org2.gateway.scarf.sh/telemetry/celorga/launch")!
  public static let launchEvent = "app_launch"
  public static let gitHubStarPromptShownEvent = "github_star_prompt_shown"

  /// The app metadata sent with each event, captured once the launch has
  /// passed the production and opt-out checks.
  private struct EventContext {
    let version: String
    let osVersion: String
    let architecture: String
  }

  @Published public var enabled: Bool {
    didSet {
      defaults.set(enabled, forKey: Self.enabledKey)
      if !enabled {
        for submission in submissions.values { submission.cancel() }
        submissions.removeAll()
      }
    }
  }

  private let defaults: UserDefaults
  private let send: @Sendable (URLRequest) async throws -> Void
  private var attemptedLaunch = false
  private var eventContext: EventContext?
  private var submissions: [UUID: Task<Void, Never>] = [:]

  public init(
    defaults: UserDefaults = .standard,
    send: @escaping @Sendable (URLRequest) async throws -> Void = OpenOrgLaunchTelemetry.submit
  ) {
    self.defaults = defaults
    self.send = send
    enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
  }

  public func recordLaunch(
    bundleIdentifier: String?,
    version: String?,
    osVersion: String,
    architecture: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments
  ) {
    guard !attemptedLaunch else { return }
    attemptedLaunch = true
    guard bundleIdentifier == "org.org2.workspace",
          let version, !version.isEmpty,
          environment["DO_NOT_TRACK"] != "1",
          environment["SCARF_ANALYTICS"]?.lowercased() != "false",
          !arguments.contains("--smoke-test"),
          !arguments.contains("--quit-after-launch") else { return }
    eventContext = EventContext(version: version, osVersion: osVersion, architecture: architecture)
    recordEvent(Self.launchEvent)
  }

  /// Sends one named event with the launch metadata. Does nothing unless this
  /// production process passed the launch checks and telemetry is enabled now.
  public func recordEvent(_ event: String) {
    guard enabled, let context = eventContext else { return }
    let request = Self.request(
      event: event,
      version: context.version,
      osVersion: context.osVersion,
      architecture: context.architecture
    )
    let send = self.send
    let id = UUID()
    submissions[id] = Task { [weak self] in
      defer { self?.submissions[id] = nil }
      guard !Task.isCancelled else { return }
      // A telemetry failure must never interrupt the app or trigger a duplicate event.
      try? await send(request)
    }
  }

  public static func request(
    event: String = launchEvent,
    version: String,
    osVersion: String,
    architecture: String
  ) -> URLRequest {
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Celorga/\(version)", forHTTPHeaderField: "User-Agent")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "event": event,
      "version": version,
      "platform": "macos",
      "os_version": osVersion,
      "architecture": architecture,
      "schema_version": "1",
    ])
    return request
  }

  public nonisolated static func submit(_ request: URLRequest) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    _ = try await session.data(for: request)
  }
}
