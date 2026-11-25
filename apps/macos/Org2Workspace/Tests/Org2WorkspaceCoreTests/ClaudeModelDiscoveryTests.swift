import Foundation
import XCTest
@testable import Org2WorkspaceCore

/// Rows shaped like Claude Code 2.1's reply to the stream-json `initialize`
/// control request.
var claudeReportedModelRowsForTesting: [[String: Any]] { [
  [
    "value": "default",
    "resolvedModel": "claude-opus-5-5",
    "displayName": "Default (recommended)",
    "description": "Use the default model (currently Opus 5.5) · $4/$20 per Mtok",
    "supportsEffort": true,
    "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]
  ],
  [
    "value": "opus",
    "resolvedModel": "claude-opus-5-5",
    "displayName": "Opus",
    "description": "Opus 5.5 · Best for everyday, complex tasks · $4/$20 per Mtok",
    "supportsEffort": true,
    "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]
  ],
  [
    "value": "opus[1m]",
    "resolvedModel": "claude-opus-5-5[1m]",
    "displayName": "Opus (1M context)",
    "description": "Opus 5.5 for long sessions · $6/$30 per Mtok",
    "supportsEffort": true,
    "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]
  ],
  [
    "value": "fable",
    "resolvedModel": "claude-fable-5-2",
    "displayName": "Fable",
    "description": "Fable 5.2 · Most capable for your hardest and longest-running tasks",
    "supportsEffort": true,
    "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"]
  ],
  [
    "value": "sonnet",
    "resolvedModel": "claude-sonnet-5-5",
    "displayName": "Sonnet",
    "description": "Sonnet 5.5 · Efficient for routine tasks",
    "supportsEffort": true,
    "supportedEffortLevels": ["low", "medium", "high"]
  ],
  [
    "value": "haiku",
    "resolvedModel": "claude-haiku-5-5",
    "displayName": "Haiku",
    "description": "Haiku 5.5 · Fastest for quick answers",
    "supportsEffort": false
  ]
] }

final class ClaudeModelDiscoveryTests: XCTestCase {
  func testReportedModelsShowVersionsDefaultAndPerModelEffort() {
    let models = ClaudeCodeClient.modelOptions(fromReportedModels: claudeReportedModelRowsForTesting)

    XCTAssertEqual(models.map(\.id), ["opus", "opus[1m]", "fable", "sonnet", "haiku"])
    XCTAssertEqual(
      models.map(\.label),
      ["Opus 5.5", "Opus 5.5 (1M context)", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"]
    )
    XCTAssertEqual(models.filter(\.isDefault).map(\.id), ["opus"])
    XCTAssertEqual(models[0].reasoningOptions.map(\.id), ["low", "medium", "high", "xhigh", "max"])
    XCTAssertEqual(models[3].reasoningOptions.map(\.id), ["low", "medium", "high"])
    XCTAssertFalse(models[4].supportsReasoning)
    XCTAssertEqual(ClaudeCodeClient.reasoningOptions(forModel: "haiku", in: models), [])
    XCTAssertEqual(
      ClaudeCodeClient.reasoningOptions(forModel: "sonnet", in: models).map(\.id),
      ["low", "medium", "high"]
    )
    XCTAssertEqual(
      ClaudeCodeClient.reasoningOptions(forModel: nil, in: models).map(\.id),
      ["low", "medium", "high", "xhigh", "max"],
      "the default chat takes the default model's levels"
    )
    XCTAssertEqual(
      ClaudeCodeClient.reasoningOptions(forModel: "claude-opus-4-1", in: models).map(\.id),
      ClaudeCodeClient.reasoningOptions.map(\.id),
      "a model Claude Code accepts but does not list keeps every level"
    )
    XCTAssertEqual(AIChatModelOption.defaultEntryTitle(in: models), "Default (Opus 5.5)")
    XCTAssertEqual(
      AIChatModelOption.defaultEntryTitle(in: ClaudeCodeClient.fallbackModelOptions),
      "Default model"
    )
  }

  func testOlderReleasesWithoutResolvedModelsOrEffortLevelsStillWork() {
    let models = ClaudeCodeClient.modelOptions(fromReportedModels: [
      [
        "value": "default",
        "displayName": "Default (recommended)",
        "description": "Use the default model (currently Sonnet 4.5) · $3/$15 per Mtok"
      ],
      ["value": "opus", "displayName": "Opus", "description": "Opus 4.5 · Most capable · $5/$25 per Mtok"],
      ["value": "sonnet", "displayName": "Sonnet 4.5", "description": "Sonnet 4.5 · Smart"],
      ["value": "haiku", "displayName": "Haiku", "description": "Fastest for quick answers"]
    ])

    XCTAssertEqual(models.map(\.label), ["Opus 4.5", "Sonnet 4.5", "Haiku"])
    XCTAssertEqual(models.filter(\.isDefault).map(\.id), ["sonnet"])
    XCTAssertEqual(
      models[0].reasoningOptions.map(\.id),
      ClaudeCodeClient.reasoningOptions.map(\.id)
    )
  }

  func testInitializeOutputWithoutModelsIsAnError() {
    let output = Data("""
    {"type":"control_response","response":{"subtype":"success","request_id":"celorga-models","response":{"commands":[]}}}

    """.utf8)
    XCTAssertThrowsError(try ClaudeCodeClient.modelOptions(fromInitializeOutput: output))
    XCTAssertThrowsError(try ClaudeCodeClient.modelOptions(fromInitializeOutput: Data()))
  }

  /// Claude Code is asked once through `initialize` and the answer is reused
  /// until it is older than the maximum age or a refresh forces a new one.
  func testListModelsAsksClaudeCodeThroughInitializeAndCachesTheAnswer() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("celorga-claude-models-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rowsData = try JSONSerialization.data(withJSONObject: claudeReportedModelRowsForTesting)
    let response = """
    {"type":"control_response","response":{"subtype":"success","request_id":"celorga-models","response":{"models":\(String(decoding: rowsData, as: UTF8.self))}}}
    """
    try response.write(to: root.appendingPathComponent("response.json"), atomically: true, encoding: .utf8)
    let executable = root.appendingPathComponent("claude")
    let script = """
    #!/bin/sh
    printf '%s\\n' "$@" > "$ORG2_CLAUDE_TEST_ROOT/arguments.txt"
    echo run >> "$ORG2_CLAUDE_TEST_ROOT/runs.txt"
    IFS= read -r line
    printf '%s' "$line" > "$ORG2_CLAUDE_TEST_ROOT/input.txt"
    printf '%s\\n' '{"type":"system","subtype":"hook_started"}'
    cat "$ORG2_CLAUDE_TEST_ROOT/response.json"
    printf '\\n'
    cat > /dev/null
    """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let client = ClaudeCodeClient(
      executableURL: executable,
      environment: ["ORG2_CLAUDE_TEST_ROOT": root.path, "PATH": "/usr/bin:/bin", "HOME": root.path]
    ) { _, _ in }

    let models = try await client.listModels(cwd: root)
    XCTAssertEqual(models.map(\.label).first, "Opus 5.5")
    XCTAssertEqual(models.first(where: \.isDefault)?.id, "opus")
    let input = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("input.txt")))
        as? [String: Any]
    )
    XCTAssertEqual(input["type"] as? String, "control_request")
    XCTAssertEqual((input["request"] as? [String: Any])?["subtype"] as? String, "initialize")
    let arguments = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
      .split(separator: "\n").map(String.init)
    XCTAssertEqual(arguments, ClaudeCodeClient.modelDiscoveryArguments())

    _ = try await client.listModels(cwd: root)
    var runs = try String(contentsOf: root.appendingPathComponent("runs.txt"), encoding: .utf8)
    XCTAssertEqual(runs.split(separator: "\n").count, 1, "a fresh catalog is reused")
    _ = try await client.listModels(cwd: root, maximumAge: 0)
    runs = try String(contentsOf: root.appendingPathComponent("runs.txt"), encoding: .utf8)
    XCTAssertEqual(runs.split(separator: "\n").count, 2, "Refresh Options asks again")
  }
}
