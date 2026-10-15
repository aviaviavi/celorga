import AppKit
import SwiftUI
import WebKit

struct PasteAsOrg2Result: Decodable {
  let org: String
  let warnings: [String]
}

/// Runs the shared TypeScript implementation in an ephemeral, network-denied DOM.
@MainActor
final class PasteAsOrg2Runtime: NSObject, WKNavigationDelegate {
  private var webView: WKWebView?
  private var ready: CheckedContinuation<Void, Error>?
  private var loadTimeout: Task<Void, Never>?

  func convert(text: String, html: String?, useModel: Bool) async throws -> PasteAsOrg2Result {
    guard text.utf16.count <= 200_000, (html?.utf16.count ?? 0) <= 200_000 else {
      throw PasteAsOrg2Error.message("Clipboard content exceeds 200,000 characters. Paste a smaller selection.")
    }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let rules = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "OpenOrgPasteDenyNetwork-v1",
      encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
    )
    if let rules { configuration.userContentController.add(rules) }
    let view = WKWebView(frame: .zero, configuration: configuration)
    webView = view
    view.navigationDelegate = self
    defer { loadTimeout?.cancel(); view.stopLoading(); view.navigationDelegate = nil; webView = nil }
    try await withCheckedThrowingContinuation { continuation in
      ready = continuation
      loadTimeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled else { return }
        self?.ready?.resume(throwing: PasteAsOrg2Error.message("Local converter took too long to start. Try again."))
        self?.ready = nil
      }
      view.loadHTMLString("<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'none'; connect-src 'none'\"></head><body></body></html>", baseURL: nil)
    }
    try Task.checkCancellation()
    guard let url = WorkspaceResources.url(forResource: "PasteAsOrg2", withExtension: "js") else {
      throw PasteAsOrg2Error.message("Local paste converter is missing from this build.")
    }
    let script = try String(contentsOf: url, encoding: .utf8)
    var input: [String: Any] = ["text": text, "useModel": useModel]
    if let html, !html.isEmpty { input["html"] = html }
    // Clipboard text is a structured argument, never interpolated into JavaScript or live HTML.
    let result = try await view.callAsyncJavaScript(
      script + "\nconst preview = globalThis.openOrgPastePreview(input); return JSON.stringify({org: preview.org, warnings: preview.warnings});",
      arguments: ["input": input], in: nil, contentWorld: .defaultClient
    )
    try Task.checkCancellation()
    guard let json = result as? String, let data = json.data(using: .utf8) else {
      throw PasteAsOrg2Error.message("Local converter returned an invalid preview.")
    }
    return try JSONDecoder().decode(PasteAsOrg2Result.self, from: data)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    ready?.resume(); ready = nil
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    ready?.resume(throwing: error); ready = nil
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    ready?.resume(throwing: error); ready = nil
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    ready?.resume(throwing: PasteAsOrg2Error.message("Local converter stopped. Try again.")); ready = nil
  }
}

enum PasteAsOrg2Error: LocalizedError {
  case message(String)
  var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// A one-use insertion snapshot; view identity and generation cover document switches,
/// including a different document with identical text. AppKit owns undo and publication.
@MainActor
final class PasteAsOrg2Controller: ObservableObject {
  @Published var org = ""
  @Published var warnings = [String]()
  @Published var error: String?
  @Published var isLoading = true
  @Published var useModel = false { didSet { isLoading = true; error = nil } }
  private weak var target: OrgSyntaxTextView?
  private weak var parentWindow: NSWindow?
  private var sheet: NSWindow?
  private let originalDocument: String
  private let identity: String?
  private let generation: UInt64?
  private let selection: NSRange
  let originalText: String
  let originalHTML: String?
  private var consumed = false

  init(target: OrgSyntaxTextView, text: String, html: String?) {
    self.target = target
    parentWindow = target.window
    originalDocument = target.string
    identity = target.pasteDocumentIdentity
    generation = target.pasteDocumentGeneration?()
    selection = target.selectedRange()
    originalText = text
    originalHTML = html
  }

  func present() {
    guard let parentWindow else { cancel(); return }
    let sheet = NSWindow(contentViewController: NSHostingController(rootView: PasteAsOrg2Sheet(controller: self)))
    sheet.title = "Paste as Org — Experimental"
    sheet.styleMask = [.titled, .resizable]
    sheet.setContentSize(NSSize(width: 780, height: 580))
    self.sheet = sheet
    parentWindow.beginSheet(sheet)
  }

  func refresh() async {
    isLoading = true
    error = nil
    do {
      let result = try await PasteAsOrg2Runtime().convert(text: originalText, html: originalHTML, useModel: useModel)
      guard !Task.isCancelled, !consumed else { return }
      org = result.org
      warnings = result.warnings
      isLoading = false
    } catch {
      guard !Task.isCancelled, !consumed else { return }
      self.error = error.localizedDescription
      isLoading = false
    }
  }

  @discardableResult
  func insert() -> Bool {
    guard !consumed, !isLoading, error == nil, let target,
          target.pasteAsOrgEnabled?() == true, target.isEditable,
          target.window === parentWindow, target.window != nil,
          target.pasteDocumentIdentity == identity,
          target.pasteDocumentGeneration?() == generation,
          target.string == originalDocument,
          selection.location != NSNotFound, NSMaxRange(selection) <= (target.string as NSString).length else {
      error = "The document or Experimental Features setting changed. Cancel and preview again."
      return false
    }
    // insertText performs the AppKit permission/undo transaction itself. Calling
    // shouldChangeText first registers the replacement twice with Undo.
    target.insertText(org, replacementRange: selection)
    target.undoManager?.setActionName("Paste as Org")
    cancel()
    return true
  }

  func cancel() {
    guard !consumed else { return }
    consumed = true
    if let sheet { parentWindow?.endSheet(sheet); sheet.orderOut(nil) }
    sheet = nil
    target?.pastePreviewController = nil
  }
}

private struct PasteAsOrg2Sheet: View {
  @ObservedObject var controller: PasteAsOrg2Controller
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Paste as Org").font(.title2.bold())
      Text("Experimental · Converted on this Mac. Review and edit before inserting.")
        .foregroundStyle(.secondary)
      Toggle("Use tiny local model for plain text", isOn: $controller.useModel)
        .help("Experimental structure suggestions. Semantic HTML takes precedence.")
      HSplitView {
        VStack(alignment: .leading) {
          Text("Original text").font(.headline)
          ScrollView { Text(controller.originalText.isEmpty ? "HTML clipboard content" : controller.originalText)
            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: 220)
        VStack(alignment: .leading) {
          Text("Org preview — editable").font(.headline)
          TextEditor(text: $controller.org).font(.system(.body, design: .monospaced))
            .disabled(controller.isLoading)
            .accessibilityIdentifier("pasteAsOrg2Preview")
        }.frame(minWidth: 300)
      }
      if controller.isLoading { ProgressView("Converting locally…") }
      if let error = controller.error { Text(error).foregroundStyle(.red) }
      if !controller.warnings.isEmpty {
        Text(controller.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("Cancel") { controller.cancel() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Insert reviewed Org") { controller.insert() }
          .disabled(controller.isLoading || controller.error != nil || controller.org.isEmpty)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 740, minHeight: 540)
    .task(id: controller.useModel) { await controller.refresh() }
  }
}

extension OrgSyntaxTextView {
  @objc func pasteAsOrg2(_ sender: Any?) {
    guard pasteAsOrgEnabled?() == true, isEditable, window != nil,
          pastePreviewController == nil else { return }
    let clipboard = NSPasteboard.general
    let text = clipboard.string(forType: .string) ?? ""
    let html = clipboard.string(forType: .html)
    guard !text.isEmpty || !(html ?? "").isEmpty else { NSSound.beep(); return }
    let controller = PasteAsOrg2Controller(target: self, text: text, html: html)
    pastePreviewController = controller
    controller.present()
  }
}
