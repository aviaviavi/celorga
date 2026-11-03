import AppKit
import SwiftUI
import XCTest
@testable import Org2WorkspaceCore

/// Typing in the AI chat composer must only update the text and the views that
/// depend on it. Rebuilding the toolbar, and looking up the selected thread by
/// a linear search of every thread, made keystrokes queue up behind the main
/// thread in large chat histories.
@MainActor
final class AIChatComposerTypingTests: XCTestCase {
  private func findTextView(in view: NSView) -> AIChatComposerTextView.CommandSubmitTextView? {
    if let match = view as? AIChatComposerTextView.CommandSubmitTextView { return match }
    for subview in view.subviews {
      if let match = findTextView(in: subview) { return match }
    }
    return nil
  }

  private func pump(_ host: NSView, _ window: NSWindow) async {
    for _ in 0..<4 {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      window.update()
    }
  }

  private func makeStore(threadCount: Int) throws -> (WorkspaceStore, [AIChatThread], () -> Void) {
    let suiteName = "ChatComposerTyping.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent("chat.json"),
      legacyDefaultsDomains: []
    )
    store.aiChatTranscriptSaverForTesting = {}
    store.setCorpusRoot(root, persistsDefault: false)
    let threads = (0..<threadCount).map { index in
      AIChatThread(
        title: "Thread \(index)",
        runtime: .codex,
        sessionKey: "thread-\(index)",
        messages: (0..<8).map { message in
          AIChatMessage(
            role: message.isMultiple(of: 2) ? .user : .assistant,
            content: "Message \(message) in thread \(index)"
          )
        }
      )
    }
    store.applyAIChatTranscript(
      AIChatTranscriptState(
        threads: threads,
        selectedThreadID: threads[threadCount / 2].id,
        settlementSettings: .init()
      ),
      shouldPersist: false
    )
    store.selectAIChatThread(threads[threadCount / 2].id)
    return (store, threads, {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    })
  }

  func testTypingDoesNotRebuildTheComposerToolbar() async throws {
    let (store, threads, cleanup) = try makeStore(threadCount: 300)
    defer { cleanup() }
    let host = NSHostingView(rootView: AIChatComposerView(focusOnAppear: true, compact: false)
      .environment(store).frame(width: 700))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 260),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.contentView = nil; window.close() }
    await pump(host, window)
    let textView = try XCTUnwrap(findTextView(in: host))
    window.makeFirstResponder(textView)

    // The first character enables Send, so the toolbar updates once.
    var evaluations = AIChatComposerFooterMetrics.bodyEvaluationCount
    textView.insertText("h", replacementRange: textView.selectedRange())
    await pump(host, window)
    XCTAssertGreaterThan(AIChatComposerFooterMetrics.bodyEvaluationCount, evaluations)
    try await Task.sleep(for: .milliseconds(200))
    await pump(host, window)

    var perKeystroke: [Int] = []
    for character in "ello there, this is a longer message" {
      let before = AIChatComposerFooterMetrics.bodyEvaluationCount
      textView.insertText(String(character), replacementRange: textView.selectedRange())
      await pump(host, window)
      perKeystroke.append(AIChatComposerFooterMetrics.bodyEvaluationCount - before)
    }
    // Unrelated store updates (configuration and agent-profile refreshes the
    // toolbar starts on appear) may still land while typing. Before the fix
    // every keystroke rebuilt the toolbar.
    XCTAssertLessThanOrEqual(
      perKeystroke.reduce(0, +),
      3,
      "Keystrokes that leave Send enabled must not rebuild the toolbar: \(perKeystroke)"
    )
    XCTAssertEqual(textView.string, "hello there, this is a longer message")

    // Store changes still reach the toolbar directly.
    evaluations = AIChatComposerFooterMetrics.bodyEvaluationCount
    store.aiChatSendingThreadIDs.insert(threads[150].id)
    await pump(host, window)
    XCTAssertGreaterThan(AIChatComposerFooterMetrics.bodyEvaluationCount, evaluations)

    // Clearing the draft disables Send again.
    evaluations = AIChatComposerFooterMetrics.bodyEvaluationCount
    textView.selectAll(nil)
    textView.insertText("", replacementRange: textView.selectedRange())
    await pump(host, window)
    XCTAssertGreaterThan(AIChatComposerFooterMetrics.bodyEvaluationCount, evaluations)
  }

  func testSelectedThreadLookupFollowsThreadListChanges() throws {
    let (store, threads, cleanup) = try makeStore(threadCount: 50)
    defer { cleanup() }
    let selectedID = threads[25].id
    XCTAssertEqual(store.selectedAIChatThread?.id, selectedID)
    XCTAssertEqual(store.selectedChatAgentRef, nil)

    // Reordering and removing other threads must not leave a stale index.
    store.aiChatThreads.removeFirst(10)
    XCTAssertEqual(store.selectedAIChatThread?.id, selectedID)
    store.aiChatThreads.reverse()
    XCTAssertEqual(store.selectedAIChatThread?.id, selectedID)

    let index = try XCTUnwrap(store.aiChatThreads.firstIndex(where: { $0.id == selectedID }))
    store.aiChatThreads.insert(
      AIChatThread(title: "Inserted", runtime: .codex, sessionKey: "inserted"),
      at: 0
    )
    XCTAssertEqual(store.aiChatThreads[index + 1].id, selectedID)
    XCTAssertEqual(store.selectedAIChatThread?.id, selectedID)

    store.aiChatThreads.removeAll { $0.id == selectedID }
    XCTAssertNil(store.selectedAIChatThread)
    XCTAssertFalse(store.canChangeChatAgent)
  }

  func testComposerKeystrokesStayFastWithALargeChatHistory() async throws {
    let (store, _, cleanup) = try makeStore(threadCount: 500)
    defer { cleanup() }
    let host = NSHostingView(rootView: AIChatComposerView(focusOnAppear: true, compact: false)
      .environment(store).frame(width: 700))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 260),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.contentView = nil; window.close() }
    await pump(host, window)
    let textView = try XCTUnwrap(findTextView(in: host))
    window.makeFirstResponder(textView)
    textView.insertText("a", replacementRange: textView.selectedRange())
    await pump(host, window)

    var samples: [Double] = []
    for _ in 0..<30 {
      let startedAt = CACurrentMediaTime()
      textView.insertText("a", replacementRange: textView.selectedRange())
      await pump(host, window)
      samples.append((CACurrentMediaTime() - startedAt) * 1_000)
    }
    let median = samples.sorted()[samples.count / 2]
    // Debug builds on a busy machine; the regression this guards took
    // several hundred milliseconds per keystroke.
    XCTAssertLessThan(median, 120, "Median composer keystroke took \(median) ms")
  }
}
