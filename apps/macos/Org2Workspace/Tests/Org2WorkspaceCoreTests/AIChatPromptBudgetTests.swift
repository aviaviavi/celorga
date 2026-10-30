import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Measures what Celorga sends an agent on a representative turn so prompt
/// growth is caught. Sizes are in characters; run with `--filter
/// AIChatPromptBudgetTests` and read the `PROMPT-SIZE` lines to compare.
final class AIChatPromptBudgetTests: XCTestCase {
  /// A resumed local chat in a project, with one extra read-only corpus,
  /// short custom instructions, and a few attached corpus files.
  static func representativeContext() -> AIChatWorkspaceContext {
    let threadID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    let brief = (1...40).map {
      "- Launch checklist item \($0): confirm the fictional Example Co. rollout step and its owner."
    }.joined(separator: "\n")
    let project = WorkspaceProjectNote(
      id: "project-launch",
      title: "Example launch",
      color: "blue",
      file: "/tmp/example-corpus/projects/launch.org",
      relativePath: "projects/launch.org",
      revision: "sha256:0123456789abcdef",
      threadIDs: [threadID.uuidString.lowercased()],
      brief: brief,
      briefTruncated: false
    )
    return AIChatWorkspaceContext(
      localCorpusRoot: "/tmp/example-corpus",
      remoteCorpusRoot: nil,
      selectedSurface: "AI Chat",
      selectedLocation: nil,
      selectedEntrySource: nil,
      backlinks: nil,
      agenda: nil,
      searchQuery: "",
      searchResults: [],
      authorizedCorpora: [
        AIChatCorpusContext(name: "Example", kind: "personal", localRoot: "/tmp/example-corpus", isActive: true),
        AIChatCorpusContext(name: "Team", kind: "shared", localRoot: "/tmp/team-corpus", isActive: false)
      ],
      customInstructions: "Prefer concise answers and surface open TODOs.",
      projectContext: WorkspaceProjectContext.presentation(projects: [project], threadID: threadID),
      threadContinuation: AIChatThreadContinuation(
        id: threadID,
        title: "Launch planning",
        messages: [],
        org2References: ["projects/launch.org", "notes/rollout.org"]
      )
    )
  }

  struct Sizes {
    let standing: Int
    let turn: Int
    let claudeSystemPrompt: Int
    let codexFirstTurn: Int
    var openCodeTotal: Int { standing + turn }
  }

  static func measure() -> Sizes {
    let context = representativeContext()
    let snapshot = context.localAgentSystemPrompt(
      runtime: "opencode",
      runtimeTitle: "OpenCode",
      includesStandingInstructions: false
    )
    let turn = OpenCodeClient.turnPrompt(
      message: "What should I tackle next on the launch?",
      turnContext: snapshot
    )
    let claude = context.localAgentSystemPrompt(runtime: "claude", runtimeTitle: "Claude Code")
    let codex = CodexAppServerClient.developerInstructions(for: .clientWorkspaceTools)
      + context.codexSystemPrompt()
    return Sizes(
      standing: AIChatWorkspaceContext.localAgentStandingInstructions.count,
      turn: turn.count,
      claudeSystemPrompt: claude.count,
      codexFirstTurn: codex.count
    )
  }

  func testRepresentativeTurnStaysWithinPromptBudget() {
    let sizes = Self.measure()
    print("PROMPT-SIZE standing=\(sizes.standing) turn=\(sizes.turn) opencode-total=\(sizes.openCodeTotal) claude-system=\(sizes.claudeSystemPrompt) codex-first-turn=\(sizes.codexFirstTurn)")
    // Budgets sit a little above the measured sizes. Raise one only for
    // instructions the agent cannot get from `celorga agent capabilities`
    // or by reading the corpus.
    XCTAssertLessThanOrEqual(sizes.standing, 6_600, "standing instructions grew")
    XCTAssertLessThanOrEqual(sizes.turn, 4_100, "per-turn snapshot grew")
    XCTAssertLessThanOrEqual(sizes.openCodeTotal, 10_500)
    XCTAssertLessThanOrEqual(sizes.claudeSystemPrompt, 10_200)
    XCTAssertLessThanOrEqual(sizes.codexFirstTurn, 12_200)
  }
}
