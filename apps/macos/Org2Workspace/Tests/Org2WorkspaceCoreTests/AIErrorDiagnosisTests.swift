import Foundation
import XCTest
@testable import Org2WorkspaceCore

private actor DiagnosisSendRecorder {
  var prompts: [String] = []
  func record(_ messages: [AIChatMessage]) {
    if let prompt = messages.last(where: { $0.role == .user })?.content {
      prompts.append(prompt)
    }
  }
}

final class AIErrorDiagnosisTests: XCTestCase {
  func testPromptCarriesErrorFileAndFixRequest() {
    let prompt = WorkspaceStore.aiErrorDiagnosisPrompt(
      title: "Data refresh failed",
      message: "Error: query 12 returned HTTP 500",
      action: "refresh this data notebook",
      fileReference: "notes/revenue.org"
    )
    XCTAssertTrue(prompt.hasPrefix("Celorga showed this error while I was trying to refresh this data notebook."))
    XCTAssertTrue(prompt.contains("Affected file: notes/revenue.org"))
    XCTAssertTrue(prompt.contains("Error: Data refresh failed"))
    XCTAssertTrue(prompt.contains("#+begin_example\nError: query 12 returned HTTP 500\n#+end_example"))
    XCTAssertTrue(prompt.contains("Diagnose the cause"))
    XCTAssertEqual(
      WorkspaceStore.aiErrorDiagnosisThreadTitle(title: nil, message: "First line\nsecond"),
      "Fix: First line"
    )
  }

  @MainActor
  func testAskAIToFixStartsAndSendsANewThreadWithTheFileAsContext() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-error-diagnosis-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let suite = "AIErrorDiagnosisTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let recorder = DiagnosisSendRecorder()
    let store = WorkspaceStore(
      defaults: defaults,
      aiChatTranscriptURL: root.appendingPathComponent(".org2/openclaw-chat.json"),
      codexSendHandlerForTesting: { messages, _, _ in
        await recorder.record(messages)
        return "DIAGNOSED"
      },
      legacyDefaultsDomains: []
    )
    store.setCorpusRoot(root, persistsDefault: false)
    let original = store.createAIChatThread(runtime: .codex)
    let notebook = root.appendingPathComponent("notes/revenue-report.org")

    await store.askAIToDiagnoseError(
      "query 12 returned HTTP 500",
      title: "Data refresh failed",
      action: "refresh this data notebook",
      file: notebook.path
    )

    let threadID = try XCTUnwrap(store.selectedAIChatThreadID)
    XCTAssertNotEqual(threadID, original)
    let thread = try XCTUnwrap(store.aiChatThreads.first { $0.id == threadID })
    XCTAssertEqual(thread.title, "Fix: Data refresh failed")
    XCTAssertEqual(thread.destinationID, AIChatDestinationConfiguration.localCodexID)
    let sent = try XCTUnwrap(thread.messages.first { $0.role == .user }?.content)
    XCTAssertTrue(sent.contains("notes/revenue-report.org"), sent)
    XCTAssertTrue(sent.contains("query 12 returned HTTP 500"), sent)
    let contexts = AIChatContextPresentation(sent).contexts
    XCTAssertEqual(contexts.first?.kind, "affected file")
  }
}
