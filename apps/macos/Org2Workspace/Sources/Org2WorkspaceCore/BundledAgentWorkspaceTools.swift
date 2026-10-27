import AppKit
import Foundation

/// Authority remains in the host. Never accept a model-selected turn ID or
/// allow a patch to bypass the broker's read/preview/hash validation.
@MainActor
final class BundledAgentWorkspaceTools {
  let turnID: String
  let corpusRoot: URL
  let cli: Org2CLI
  let broker: AIChatLocalEditBroker
  let approve: @MainActor @Sendable (String) async -> Bool
  private var previews: [String: String] = [:]
  private var reads: [String: String] = [:]
  private var editsDeclined = false

  init(
    turnID: String, corpusRoot: URL, cli: Org2CLI, broker: AIChatLocalEditBroker,
    approve: @escaping @MainActor @Sendable (String) async -> Bool
  ) {
    self.turnID = turnID
    self.corpusRoot = corpusRoot
    self.cli = cli
    self.broker = broker
    self.approve = approve
  }

  static var definitions: [JSONValue] {
    CodexAppServerClient.localEditDynamicTools.filter {
      [
        "celorga_workspace_read",
        "celorga_workspace_patch_preview",
        "celorga_workspace_patch_apply",
      ].contains($0["name"]?.stringValue ?? "")
    } + [.object([
      "name": .string("celorga_workspace_search"),
      "description": .string("Search the active corpus on disk for up to ten cited results. Read a result with celorga_workspace_read before editing; search may not include unsaved drafts."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object(["query": .object(["type": .string("string")])]),
        "required": .array([.string("query")]), "additionalProperties": .bool(false)
      ])
    ])]
  }

  func execute(_ name: String, arguments: JSONValue) async throws -> CodexDynamicToolResult {
    try Task.checkCancellation()
    guard var args = arguments.objectValue else { return failure("Arguments must be an object.") }
    let name = CelorgaNames.legacyToolName(name)
    if name == "org2_workspace_search" {
      guard let query = args["query"]?.stringValue, !query.isEmpty, query.utf8.count <= 2000 else {
        return failure("Provide a search query of 1–2000 bytes.")
      }
      let data = try await cli.run([
        "agent", "search", "--query", query, "--dir", corpusRoot.path,
        "--recursive", "--limit", "10", "--max-chars", "16000", "--format", "json"
      ])
      try Task.checkCancellation()
      return CodexDynamicToolResult(success: true, text: String(decoding: data, as: UTF8.self))
    }
    let command: String
    switch name {
    case "org2_workspace_read": command = AIChatLocalEditBroker.readCommand
    case "org2_workspace_patch_preview": command = AIChatLocalEditBroker.previewCommand
    case "org2_workspace_patch_apply": command = AIChatLocalEditBroker.applyCommand
    default: return failure("This tool is not available in the bundled agent.")
    }
    args["turnId"] = .string(turnID)
    if name == "org2_workspace_patch_apply" {
      guard !editsDeclined else { return failure("Edits were declined for this turn. Wait for a new user request.") }
      guard let id = args["previewId"]?.stringValue, let review = previews.removeValue(forKey: id) else {
        return failure("Preview this edit in the current turn before requesting approval.")
      }
      guard await approve(review) else {
        editsDeclined = true
        return failure("The user declined this edit. Do not retry it unless the user asks.")
      }
      try Task.checkCancellation()
    }
    let encoded = try JSONEncoder().encode(JSONValue.object(args))
    let result = await broker.handle(command: command, paramsJSON: String(decoding: encoded, as: UTF8.self))
    if result.ok, let payload = result.payloadJSON,
       let value = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) {
      if name == "org2_workspace_read",
         args["corpusRoot"] == nil || args["corpusRoot"]?.stringValue == corpusRoot.path,
         let sha = value["sha256"]?.stringValue, let text = value["text"]?.stringValue {
        reads[sha] = text
      }
      if name == "org2_workspace_patch_preview", let id = value["previewId"]?.stringValue {
        let edits = args["edits"]?.arrayValue ?? []
        guard edits.allSatisfy({ edit in
          edit["createsFile"]?.boolValue == true
            || edit["expectedSha256"]?.stringValue.flatMap { reads[$0] } != nil
        }) else { return failure("Read each existing file from the active corpus before previewing, so its original text can be reviewed.") }
        // Review text comes from this exact successful preview, retained locally.
        previews[id] = Self.reviewText(corpusRoot: corpusRoot, edits: edits, reads: reads)
      }
      return CodexDynamicToolResult(success: true, text: payload)
    }
    return failure(result.errorMessage ?? "The workspace tool failed.")
  }

  /// Review text for an exact successful preview: original and proposed text
  /// for each file, plus explicit rename and Trash lines.
  static func reviewText(corpusRoot: URL, edits: [JSONValue], reads: [String: String]) -> String {
    "Corpus: \(corpusRoot.path)\n\n" + edits.map { edit in
      let path = edit["path"]?.stringValue ?? ""
      let before = edit["expectedSha256"]?.stringValue.flatMap { reads[$0] } ?? "(new file)"
      if edit["trashesFile"]?.boolValue == true {
        return "MOVE TO TRASH: \(path)\n\nBEFORE\n\(before)"
      }
      if let destination = edit["moveTo"]?.stringValue {
        let after = edit["replacementText"]?.stringValue ?? before
        return "RENAME: \(path) → \(destination)\n\nBEFORE\n\(before)\n\nAFTER\n\(after)"
      }
      let after = edit["replacementText"]?.stringValue ?? ""
      return "FILE: \(path)\n\nBEFORE\n\(before)\n\nAFTER\n\(after)"
    }.joined(separator: "\n\n────────────────────\n\n")
  }

  private func failure(_ message: String) -> CodexDynamicToolResult {
    CodexDynamicToolResult(success: false, text: message)
  }

  static func review(_ text: String) async -> Bool {
    guard let app = NSApp, let window = app.keyWindow ?? app.mainWindow else { return false }
    let alert = NSAlert()
    alert.messageText = "Apply workspace edits?"
    alert.informativeText = "Review the original and proposed text below. Celorga will check that the files still match before applying."
    alert.addButton(withTitle: "Apply")
    alert.addButton(withTitle: "Cancel")
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    scroll.hasVerticalScroller = true
    let view = NSTextView(frame: scroll.bounds)
    view.isEditable = false
    view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    view.string = text
    view.isVerticallyResizable = true
    view.textContainer?.widthTracksTextView = true
    scroll.documentView = view
    alert.accessoryView = scroll
    return await withTaskCancellationHandler {
      let response = await alert.beginSheetModal(for: window)
      return !Task.isCancelled && response == .alertFirstButtonReturn
    } onCancel: {
      Task { @MainActor in
        window.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
      }
    }
  }
}
