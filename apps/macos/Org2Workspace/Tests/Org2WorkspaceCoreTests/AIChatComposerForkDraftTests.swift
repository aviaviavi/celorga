import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

@MainActor
final class AIChatComposerForkDraftTests: XCTestCase {
  private func findTextView(in view: NSView) -> AIChatComposerTextView.CommandSubmitTextView? {
    if let match = view as? AIChatComposerTextView.CommandSubmitTextView { return match }
    for subview in view.subviews {
      if let match = findTextView(in: subview) { return match }
    }
    return nil
  }

  private func pump(_ host: NSView) async throws {
    for _ in 0..<6 {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func testMentionForkFromComposerLeavesTheSourceComposerEmpty() async throws {
    try await runScenario(sourceRunning: false)
  }

  func testMentionForkWhileSourceRunsLeavesTheSourceComposerEmpty() async throws {
    try await runScenario(sourceRunning: true)
  }

  func testSwitchingThreadsDoesNotCarryAnUnsentDraft() async throws {
    let suiteName = "ChatComposerSwitchDraft.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let otherID = store.createAIChatThread(runtime: .openClaw)
    let firstID = store.createAIChatThread(runtime: .openClaw)
    XCTAssertEqual(store.selectedAIChatThreadID, firstID)
    let host = NSHostingView(rootView: AIChatComposerView(focusOnAppear: true, compact: false)
      .environment(store).frame(width: 600))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
    window.makeKeyAndOrderFront(nil)
    defer { window.contentView = nil; window.close() }
    try await pump(host)
    let textView = try XCTUnwrap(findTextView(in: host))
    window.makeFirstResponder(textView)
    textView.insertText("unsent words", replacementRange: textView.selectedRange())
    try await pump(host)
    store.selectAIChatThread(otherID)
    try await pump(host)
    XCTAssertEqual(textView.string, "")
    store.selectAIChatThread(firstID)
    try await pump(host)
    XCTAssertEqual(textView.string, "unsent words")

    // A newly created chat (for example Discuss or an approved-run
    // continuation) must not inherit the words, where a mention would then
    // fork it while the original thread keeps the same draft.
    let newID = store.createAIChatThread(runtime: .openClaw)
    try await pump(host)
    XCTAssertEqual(store.selectedAIChatThreadID, newID)
    XCTAssertEqual(textView.string, "")
    XCTAssertEqual(store.aiChatDraft(for: firstID), "unsent words")
  }

  private func runScenario(sourceRunning: Bool) async throws {
    let suiteName = "ChatComposerForkDraft.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      aiChatSendHandler: { messages, _, _, _ in
        if messages.last(where: { $0.role == .user })?.content == "Keep working" {
          try? await Task.sleep(for: .seconds(3))
        }
        return "OpenClaw answer"
      },
      codexSendHandlerForTesting: { _, _, _ in "Codex joined" },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let sourceID = store.createAIChatThread(runtime: .openClaw)
    await store.sendAIChatMessage(text: "Start with OpenClaw")
    if sourceRunning {
      store.sendComposedAIChatMessage(text: "Keep working")
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertTrue(store.isAIChatThreadRunning(sourceID))
    }

    let composer = AIChatComposerView(focusOnAppear: true, compact: false)
      .environment(store)
      .frame(width: 600)
    let host = NSHostingView(rootView: composer)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
    window.makeKeyAndOrderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    try await pump(host)
    let textView = try XCTUnwrap(findTextView(in: host))
    window.makeFirstResponder(textView)

    textView.insertText("@codex review this ", replacementRange: textView.selectedRange())
    try await pump(host)
    textView.insertText("conversation", replacementRange: textView.selectedRange())
    let returnKey = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil,
      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
    ))
    textView.keyDown(with: returnKey)
    try await pump(host)

    let forkID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertNotEqual(forkID, sourceID)
    XCTAssertEqual(textView.string, "")

    store.selectAIChatThread(sourceID)
    try await pump(host)
    XCTAssertEqual(store.aiChatDraft, "")
    XCTAssertEqual(textView.string, "", "source composer should be empty after the fork send")
  }
}
