import XCTest
@testable import Org2WorkspaceCore

/// Direct providers and Dots share the OpenClaw runtime family internally.
/// Chats routed to them must still be named after their own destination and
/// must never fall back to presenting or routing to OpenClaw.
final class AIChatDestinationIdentityTests: XCTestCase {
  @MainActor
  private func makeStore() throws -> (WorkspaceStore, () -> Void) {
    let suiteName = "AIChatDestinationIdentity.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let transcript = FileManager.default.temporaryDirectory
      .appendingPathComponent("org2-destination-identity-\(UUID().uuidString).json")
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: transcript,
      legacyDefaultsDomains: []
    )
    return (store, {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: transcript)
    })
  }

  @MainActor
  private func addDot(named name: String, to store: WorkspaceStore) throws -> String {
    let id = store.addAIChatDestination(adapter: .openAIDot)
    var destination = try XCTUnwrap(store.aiChatDestination(id: id))
    destination.name = name
    store.updateAIChatDestination(destination)
    return id
  }

  @MainActor
  func testDotChatIsNamedAfterItsDestinationNotOpenClaw() throws {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    let dotID = try addDot(named: "Juniper", to: store)
    store.createAIChatThread(destinationID: dotID)

    XCTAssertEqual(store.selectedAIChatRuntime, .openClaw, "precondition: Dots share the runtime family")
    XCTAssertEqual(store.selectedAIChatDestinationTitle, "Juniper")

    let unattributedReply = AIChatMessage(role: .assistant, content: "Hello")
    XCTAssertEqual(store.aiChatReplyAuthor(for: unattributedReply), "Juniper")

    store.resetAIChat()
    XCTAssertEqual(store.aiChatStatusText, "Ready for a Juniper message")
    XCTAssertFalse(store.aiChatStatusText.contains("OpenClaw"))
    XCTAssertTrue(store.activeAIChatGatewayCommands.isEmpty)
  }

  @MainActor
  func testOnlyTheGatewayAdapterReportsGatewayStatus() throws {
    let settings = OpenClawGatewaySettings.resolve()
    let gateway = AIChatDestinationConfiguration(
      id: AIChatDestinationConfiguration.openClawID,
      name: "OpenClaw",
      mention: "openclaw",
      adapter: .openClaw
    )
    let dot = AIChatDestinationConfiguration(name: "Juniper", mention: "juniper", adapter: .openAIDot)
    let provider = AIChatDestinationConfiguration(name: "Kestrel", mention: "kestrel", adapter: .anthropic)

    XCTAssertEqual(
      WorkspaceStore.aiChatIdleStatusText(destination: gateway, openClawSettings: settings),
      WorkspaceStore.aiChatStatusText(settings: settings)
    )
    XCTAssertEqual(
      WorkspaceStore.aiChatIdleStatusText(destination: dot, openClawSettings: settings),
      "Ready for a Juniper message"
    )
    XCTAssertEqual(
      WorkspaceStore.aiChatIdleStatusText(destination: provider, openClawSettings: nil),
      "Ready for a Kestrel message"
    )
  }

  @MainActor
  func testFollowUpThreadsKeepTheSelectedDestination() throws {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    let dotID = try addDot(named: "Juniper", to: store)
    store.createAIChatThread(destinationID: dotID)

    // A context, brief, or approval chat started from a Dot chat stays on it
    // instead of falling back to the built-in OpenClaw destination.
    store.prepareAIChatThread(mode: .newThread, title: "Follow up", statusText: "New context chat")
    XCTAssertEqual(store.selectedAIChatThread?.destinationID, dotID)
    XCTAssertEqual(store.aiChatStatusText, "New Juniper context chat")

    store.createAIChatThread()
    XCTAssertEqual(store.selectedAIChatThread?.destinationID, dotID)
  }

  @MainActor
  func testImplicitDefaultDestinationIsNotOpenClaw() throws {
    let (store, cleanup) = try makeStore()
    defer { cleanup() }
    let firstEnabled = try XCTUnwrap(store.enabledAIChatDestinations.first)
    XCTAssertEqual(store.defaultAIChatDestination.id, firstEnabled.id)

    let thread = store.createAIChatThread(title: "Untargeted", statusText: "")
    XCTAssertEqual(thread.destinationID, firstEnabled.id)
    XCTAssertEqual(thread.runtime, firstEnabled.runtime)
  }
}
