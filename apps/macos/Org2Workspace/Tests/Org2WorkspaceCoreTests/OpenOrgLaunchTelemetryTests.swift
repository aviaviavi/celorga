import Foundation
import XCTest
@testable import Org2WorkspaceCore

final class OpenOrgLaunchTelemetryTests: XCTestCase {
  @MainActor
  func testLaunchRequestContainsOnlyDeclaredMetadata() throws {
    let request = OpenOrgLaunchTelemetry.request(version: "0.9.0", osVersion: "26.0.1", architecture: "arm64")
    XCTAssertEqual(request.url?.absoluteString, "https://org2.gateway.scarf.sh/telemetry/celorga/launch")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Celorga/0.9.0")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    // Gateway uses "version"; "$version" is reserved for bulk event imports.
    XCTAssertEqual(body, ["event": "app_launch", "version": "0.9.0", "platform": "macos",
                          "os_version": "26.0.1", "architecture": "arm64", "schema_version": "1"])
  }

  @MainActor
  func testGitHubStarPromptEventUsesTheLaunchEndpointWithItsOwnEventName() async throws {
    let suite = "OpenOrgLaunchTelemetryTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let requests = RecordedRequests()
    let sent = expectation(description: "launch and star prompt events")
    sent.expectedFulfillmentCount = 2
    sent.assertForOverFulfill = true
    let telemetry = OpenOrgLaunchTelemetry(defaults: defaults, send: { request in
      await requests.append(request)
      sent.fulfill()
    })
    launch(telemetry)
    telemetry.recordEvent(OpenOrgLaunchTelemetry.gitHubStarPromptShownEvent)
    await fulfillment(of: [sent], timeout: 1)
    let recorded = await requests.all
    XCTAssertEqual(Set(recorded.map { $0.url?.absoluteString }), ["https://org2.gateway.scarf.sh/telemetry/celorga/launch"])
    let bodies = try recorded.map { request in
      try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }
    XCTAssertEqual(Set(bodies.compactMap { $0["event"] }), ["app_launch", "github_star_prompt_shown"])
    let star = try XCTUnwrap(bodies.first { $0["event"] == "github_star_prompt_shown" })
    XCTAssertEqual(star, ["event": "github_star_prompt_shown", "version": "0.9.0", "platform": "macos",
                          "os_version": "26.0.1", "architecture": "arm64", "schema_version": "1"])
  }

  @MainActor
  func testProductEventsNeedAnEligibleLaunchAndEnabledTelemetry() async throws {
    let suite = "OpenOrgLaunchTelemetryTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let notSent = expectation(description: "ineligible product event")
    notSent.isInverted = true
    // Before any launch has been recorded.
    let unlaunched = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in notSent.fulfill() })
    unlaunched.recordEvent(OpenOrgLaunchTelemetry.gitHubStarPromptShownEvent)
    // A Preview build.
    let preview = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in notSent.fulfill() })
    preview.recordLaunch(bundleIdentifier: "org.org2.workspace.codex", version: "0.9.0", osVersion: "26.0.1",
                         architecture: "arm64", environment: [:], arguments: [])
    preview.recordEvent(OpenOrgLaunchTelemetry.gitHubStarPromptShownEvent)
    // DO_NOT_TRACK in the launch environment.
    let doNotTrack = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in notSent.fulfill() })
    doNotTrack.recordLaunch(bundleIdentifier: "org.org2.workspace", version: "0.9.0", osVersion: "26.0.1",
                            architecture: "arm64", environment: ["DO_NOT_TRACK": "1"], arguments: [])
    doNotTrack.recordEvent(OpenOrgLaunchTelemetry.gitHubStarPromptShownEvent)
    // Opted out of telemetry.
    let optedOut = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in notSent.fulfill() })
    optedOut.enabled = false
    launch(optedOut)
    optedOut.recordEvent(OpenOrgLaunchTelemetry.gitHubStarPromptShownEvent)
    await fulfillment(of: [notSent], timeout: 0.1)
  }

  @MainActor
  func testEnabledByDefaultSendsOnceEvenIfLaunchIsCalledAgain() async throws {
    let suite = "OpenOrgLaunchTelemetryTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let sent = expectation(description: "one startup event")
    sent.assertForOverFulfill = true
    let telemetry = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in sent.fulfill() })
    XCTAssertTrue(telemetry.enabled)
    launch(telemetry)
    launch(telemetry)
    await fulfillment(of: [sent], timeout: 1)
  }

  @MainActor
  func testOptOutPersistsAcrossRestartAndPreventsSubmission() async throws {
    let suite = "OpenOrgLaunchTelemetryTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let notSent = expectation(description: "disabled telemetry")
    notSent.isInverted = true
    let telemetry = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in notSent.fulfill() })
    telemetry.enabled = false
    let restarted = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in notSent.fulfill() })
    XCTAssertFalse(restarted.enabled)
    launch(restarted)
    await fulfillment(of: [notSent], timeout: 0.1)
  }

  @MainActor
  func testPreviewEnvironmentOptOutAndSmokeTestDoNotSubmit() async throws {
    let suite = "OpenOrgLaunchTelemetryTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let notSent = expectation(description: "non-production launch")
    notSent.isInverted = true
    for (bundle, environment, arguments) in [
      ("org.org2.workspace.codex", [:], []),
      ("org.org2.workspace", ["DO_NOT_TRACK": "1"], []),
      ("org.org2.workspace", ["SCARF_ANALYTICS": "false"], []),
      ("org.org2.workspace", [:], ["--smoke-test"]),
      ("org.org2.workspace", [:], ["--quit-after-launch"]),
    ] {
      let telemetry = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in notSent.fulfill() })
      telemetry.recordLaunch(bundleIdentifier: bundle, version: "0.9.0", osVersion: "26.0.1",
                             architecture: "arm64", environment: environment, arguments: arguments)
    }
    await fulfillment(of: [notSent], timeout: 0.1)
  }

  @MainActor
  func testOptOutCancelsPendingSubmissionAndFailuresAreNotRetried() async throws {
    let suite = "OpenOrgLaunchTelemetryTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let attempted = expectation(description: "single failed request")
    attempted.assertForOverFulfill = true
    let telemetry = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in
      attempted.fulfill()
      throw URLError(.notConnectedToInternet)
    })
    launch(telemetry)
    await fulfillment(of: [attempted], timeout: 1)
    launch(telemetry)
    let cancelled = expectation(description: "cancelled before sending")
    cancelled.isInverted = true
    let pending = OpenOrgLaunchTelemetry(defaults: defaults, send: { _ in cancelled.fulfill() })
    launch(pending)
    pending.enabled = false
    await fulfillment(of: [cancelled], timeout: 0.1)
  }

  @MainActor
  private func launch(_ telemetry: OpenOrgLaunchTelemetry) {
    telemetry.recordLaunch(bundleIdentifier: "org.org2.workspace", version: "0.9.0",
                           osVersion: "26.0.1", architecture: "arm64", environment: [:], arguments: [])
  }
}

private actor RecordedRequests {
  private(set) var all: [URLRequest] = []
  func append(_ request: URLRequest) { all.append(request) }
}
